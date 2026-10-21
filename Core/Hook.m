#import "Hook.h"
#import "Engine.h"
#import "IL2CppIntrospection.h"
#import "ZTweakLog.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <mach/mach.h>
#import <mach/vm_region.h>
#import <dlfcn.h>
#import <unistd.h>
#import <mach-o/dyld.h>

typedef struct {
    int32_t handle;
} ZSHookScene;

static os_unfair_lock g_hookLock = OS_UNFAIR_LOCK_INIT;
static BOOL g_armed[ZSHookIDCount];
static BOOL g_unityReady;
static BOOL g_sceneHookInstalled;
static BOOL g_startHookInstalled;
static BOOL g_fallbackStarted;
static BOOL g_unityStarted;
static int32_t g_lastSceneState = -1;
static NSMutableArray<dispatch_block_t> *g_readyBlocks;
static NSMutableArray<ZSSceneChangedBlock> *g_sceneBlocks;
static void (*g_origInternalSceneLoaded)(ZSHookScene, int32_t, const void *);
static IMP g_origStartUnity;
static BOOL g_keyboardGuardInstalled;
static IMP g_origKeyboardInitialize;
static int g_keyboardInitializeCalls;

static const NSTimeInterval kZSHookFallbackGraceSeconds = 5.0;
static const NSTimeInterval kZSHookFallbackIntervalSeconds = 0.5;
static const NSTimeInterval kZSHookFallbackMaxSeconds = 120.0;

static BOOL zs_hook_address_writable(const void *address) {
    vm_address_t addr = (vm_address_t)address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &object);
    if (kr != KERN_SUCCESS) return NO;
    if ((vm_address_t)address < addr) return NO;
    return (info.protection & VM_PROT_WRITE) != 0;
}

BOOL zs_hook_swizzle_instance(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP previous = method_getImplementation(method);
    if (previous == replacement) return YES;
    if (original) *original = previous;
    method_setImplementation(method, replacement);
    return YES;
}

BOOL zs_hook_il2cpp_method(const void *method, void *replacement, void **original) {
    if (!method || !replacement) return NO;
    void **slot = (void **)method;
    void *previous = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (!previous) return NO;
    if (previous == replacement) return YES;
    if (!zs_hook_address_writable(slot)) {
        ZLog(@"[ZSHook] MethodInfo %p is not writable, hook skipped", method);
        return NO;
    }
    if (original) *original = previous;
    __atomic_store_n(slot, replacement, __ATOMIC_RELEASE);
    return YES;
}

BOOL zs_hook_il2cpp_named(const char *namespaze, const char *className, const char *assemblyContains,
                          const char *methodName, int argCount, void *replacement, void **original) {
    void *klass = [IL2CppBridge classNamed:className inNamespace:namespaze assemblyContains:assemblyContains];
    if (!klass) return NO;
    const void *method = [IL2CppBridge methodOnClass:klass name:methodName argCount:argCount];
    if (!method) return NO;
    return zs_hook_il2cpp_method(method, replacement, original);
}

static BOOL zs_hook_decode_site(const void *function, uintptr_t *outCave, void ***outSlot) {
    const uint32_t *entry = (const uint32_t *)function;
    uint32_t e0 = entry[0], e1 = entry[1], e2 = entry[2];
    if ((e0 & 0x9F00001F) != 0x90000010) return NO;
    if ((e1 & 0xFFC003FF) != 0x91000210) return NO;
    if (e2 != 0xD61F0200) return NO;

    int64_t imm = (int64_t)((((e0 >> 5) & 0x7FFFF) << 2) | ((e0 >> 29) & 3));
    if (imm & (1 << 20)) imm -= (1 << 21);
    uintptr_t cave = (((uintptr_t)function & ~(uintptr_t)0xFFF) + (uintptr_t)(imm << 12)) + ((e1 >> 10) & 0xFFF);

    const uint32_t *c = (const uint32_t *)cave;
    uint32_t c0 = c[0], c1 = c[1];
    if ((c0 & 0x9F00001F) != 0x90000010) return NO;
    if ((c1 & 0xFFC003FF) != 0xF9400210) return NO;
    if (c[2] != 0xB4000050 || c[3] != 0xD61F0200) return NO;

    int64_t simm = (int64_t)((((c0 >> 5) & 0x7FFFF) << 2) | ((c0 >> 29) & 3));
    if (simm & (1 << 20)) simm -= (1 << 21);
    uintptr_t slot = (((cave & ~(uintptr_t)0xFFF) + (uintptr_t)(simm << 12))) + (((c1 >> 10) & 0xFFF) << 3);

    *outCave = cave;
    *outSlot = (void **)slot;
    return YES;
}

BOOL zs_hook_patched_method(const void *method, void *replacement, void **original) {
    if (!method || !replacement) return NO;
    void *function = __atomic_load_n((void **)method, __ATOMIC_ACQUIRE);
    if (!function) return NO;

    uintptr_t cave = 0;
    void **slot = NULL;
    if (!zs_hook_decode_site(function, &cave, &slot)) return NO;
    if (!zs_hook_address_writable(slot)) {
        ZLog(@"[ZSHook] hook slot %p is not writable, site skipped", slot);
        return NO;
    }

    void *continuation = (void *)(cave + 16);
    if (original) *original = continuation;
    __atomic_store_n(slot, replacement, __ATOMIC_RELEASE);
    return YES;
}

BOOL zs_hook_site_named(const char *namespaze, const char *className, const char *assemblyContains,
                        const char *methodName, int argCount, void *replacement, void **original) {
    void *klass = [IL2CppBridge classNamed:className inNamespace:namespaze assemblyContains:assemblyContains];
    if (!klass) return NO;
    const void *method = [IL2CppBridge methodOnClass:klass name:methodName argCount:argCount];
    if (!method) return NO;
    return zs_hook_patched_method(method, replacement, original);
}

void zs_hook_mark_armed(ZSHookID hook) {
    if (hook < 0 || hook >= ZSHookIDCount) return;
    BOOL first = NO;
    os_unfair_lock_lock(&g_hookLock);
    if (!g_armed[hook]) {
        g_armed[hook] = YES;
        first = YES;
    }
    os_unfair_lock_unlock(&g_hookLock);
    if (first) ZLog(@"[ZSHook] hook %ld armed", (long)hook);
}

BOOL zs_hook_is_armed(ZSHookID hook) {
    if (hook < 0 || hook >= ZSHookIDCount) return NO;
    os_unfair_lock_lock(&g_hookLock);
    BOOL armed = g_armed[hook];
    os_unfair_lock_unlock(&g_hookLock);
    return armed;
}

BOOL zs_unity_is_ready(void) {
    os_unfair_lock_lock(&g_hookLock);
    BOOL ready = g_unityReady;
    os_unfair_lock_unlock(&g_hookLock);
    return ready;
}

static void zs_hook_scene_event(void) {
    zs_hook_mark_armed(ZSHookIDSceneLoaded);

    int32_t state = -1;
    if (!ZSGlobalScene_Current(&state)) state = -1;

    NSArray<ZSSceneChangedBlock> *blocks;
    int32_t previous;
    os_unfair_lock_lock(&g_hookLock);
    previous = g_lastSceneState;
    g_lastSceneState = state;
    blocks = [g_sceneBlocks copy];
    os_unfair_lock_unlock(&g_hookLock);

    for (ZSSceneChangedBlock block in blocks) block(state, previous);
}

static void zs_hook_scene_loaded(ZSHookScene scene, int32_t mode, const void *method) {
    if (g_origInternalSceneLoaded) g_origInternalSceneLoaded(scene, mode, method);
    zs_hook_scene_event();
}

static void zs_hook_install_il2cpp(void) {
    os_unfair_lock_lock(&g_hookLock);
    BOOL done = g_sceneHookInstalled;
    os_unfair_lock_unlock(&g_hookLock);
    if (done) return;

    void *klass = [IL2CppBridge classNamed:"SceneManager"
                               inNamespace:"UnityEngine.SceneManagement"
                          assemblyContains:"CoreModule"];
    if (!klass) return;
    const void *method = [IL2CppBridge methodOnClass:klass name:"Internal_SceneLoaded" argCount:2];
    if (!method) return;

    void *original = NULL;
    if (!zs_hook_il2cpp_method(method, (void *)zs_hook_scene_loaded, &original) || !original) return;
    g_origInternalSceneLoaded = (void (*)(ZSHookScene, int32_t, const void *))original;

    os_unfair_lock_lock(&g_hookLock);
    g_sceneHookInstalled = YES;
    os_unfair_lock_unlock(&g_hookLock);
    ZLog(@"[ZSHook] SceneManager.Internal_SceneLoaded hooked");
}

static void zs_hook_fire_ready(void) {
    NSArray<dispatch_block_t> *blocks;
    os_unfair_lock_lock(&g_hookLock);
    if (g_unityReady) {
        os_unfair_lock_unlock(&g_hookLock);
        return;
    }
    g_unityReady = YES;
    blocks = [g_readyBlocks copy];
    g_readyBlocks = nil;
    os_unfair_lock_unlock(&g_hookLock);

    ZLog(@"[ZSHook] Unity is ready, running %lu deferred start block(s)", (unsigned long)blocks.count);
    for (dispatch_block_t block in blocks) dispatch_async(dispatch_get_main_queue(), block);
}

static void zs_hook_tick(void) {
    os_unfair_lock_lock(&g_hookLock);
    BOOL safe = g_unityStarted || g_fallbackStarted;
    os_unfair_lock_unlock(&g_hookLock);
    if (!safe) return;
    zs_hook_install_il2cpp();
    if (zs_unity_view()) zs_hook_fire_ready();
}

void zs_hooks_nudge(void) {
    if (NSThread.isMainThread) {
        zs_hook_tick();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ zs_hook_tick(); });
    }
}

void zs_on_unity_ready(dispatch_block_t block) {
    if (!block) return;
    dispatch_block_t copy = [block copy];
    BOOL runNow = NO;
    os_unfair_lock_lock(&g_hookLock);
    if (g_unityReady) {
        runNow = YES;
    } else {
        if (!g_readyBlocks) g_readyBlocks = [NSMutableArray new];
        [g_readyBlocks addObject:copy];
    }
    os_unfair_lock_unlock(&g_hookLock);

    if (runNow) {
        dispatch_async(dispatch_get_main_queue(), copy);
    } else {
        zs_hooks_nudge();
    }
}

void zs_on_scene_changed(ZSSceneChangedBlock block) {
    if (!block) return;
    ZSSceneChangedBlock copy = [block copy];
    os_unfair_lock_lock(&g_hookLock);
    if (!g_sceneBlocks) g_sceneBlocks = [NSMutableArray new];
    [g_sceneBlocks addObject:copy];
    os_unfair_lock_unlock(&g_hookLock);
}

static void zs_hook_start_unity(id self, SEL selector, id application) {
    if (g_origStartUnity) ((void (*)(id, SEL, id))g_origStartUnity)(self, selector, application);
    os_unfair_lock_lock(&g_hookLock);
    g_unityStarted = YES;
    os_unfair_lock_unlock(&g_hookLock);
    zs_hooks_nudge();
}

static void zs_hook_keyboard_initialize(id self, SEL selector) {
    os_unfair_lock_lock(&g_hookLock);
    int call = ++g_keyboardInitializeCalls;
    IMP original = g_origKeyboardInitialize;
    os_unfair_lock_unlock(&g_hookLock);

    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    NSUInteger count = MIN((NSUInteger)12, stack.count);
    ZLog(@"[ZSHook] KeyboardDelegate.Initialize call #%d pid=%d\n%@", call, getpid(),
         [[stack subarrayWithRange:NSMakeRange(0, count)] componentsJoinedByString:@"\n"]);

    if (!original) return;
    @try {
        ((void (*)(id, SEL))original)(self, selector);
    } @catch (NSException *exception) {
        if (![exception.name isEqualToString:NSInternalInconsistencyException]) @throw;
        ZLog(@"[ZSHook] suppressed duplicate KeyboardDelegate.Initialize (call #%d): %@", call, exception.reason);
    }
}

static void zs_hook_install_keyboard_guard(void) {
    os_unfair_lock_lock(&g_hookLock);
    if (g_keyboardGuardInstalled) {
        os_unfair_lock_unlock(&g_hookLock);
        return;
    }
    Class cls = NSClassFromString(@"KeyboardDelegate");
    IMP original = NULL;
    BOOL ok = NO;
    if (cls) {
        ok = zs_hook_swizzle_instance(object_getClass(cls), NSSelectorFromString(@"Initialize"),
                                      (IMP)zs_hook_keyboard_initialize, &original);
    }
    if (ok) {
        if (original) g_origKeyboardInitialize = original;
        g_keyboardGuardInstalled = YES;
    }
    os_unfair_lock_unlock(&g_hookLock);
    if (ok) ZLog(@"[ZSHook] KeyboardDelegate.Initialize guarded");
}

static void zs_hook_install_start_unity(void) {
    zs_hook_install_keyboard_guard();
    os_unfair_lock_lock(&g_hookLock);
    BOOL done = g_startHookInstalled;
    os_unfair_lock_unlock(&g_hookLock);
    if (done) return;

    Class cls = NSClassFromString(@"UnityAppController");
    if (!cls) return;
    IMP original = NULL;
    if (!zs_hook_swizzle_instance(cls, NSSelectorFromString(@"startUnity:"), (IMP)zs_hook_start_unity, &original)) return;
    g_origStartUnity = original;

    os_unfair_lock_lock(&g_hookLock);
    g_startHookInstalled = YES;
    os_unfair_lock_unlock(&g_hookLock);
    ZLog(@"[ZSHook] UnityAppController.startUnity: hooked");
}

static void zs_hook_start_fallback(void) {
    os_unfair_lock_lock(&g_hookLock);
    BOOL needed = !(g_unityReady && g_sceneHookInstalled) && !g_fallbackStarted;
    if (needed) g_fallbackStarted = YES;
    os_unfair_lock_unlock(&g_hookLock);
    if (!needed) return;

    ZLog(@"[ZSHook] events did not complete startup within %.0fs, falling back to polling", kZSHookFallbackGraceSeconds);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZSHookFallbackIntervalSeconds * NSEC_PER_SEC)),
                              (uint64_t)(kZSHookFallbackIntervalSeconds * NSEC_PER_SEC),
                              NSEC_PER_SEC / 10);
    __block NSTimeInterval elapsed = 0;
    dispatch_source_set_event_handler(timer, ^{
        elapsed += kZSHookFallbackIntervalSeconds;
        zs_hook_tick();
        os_unfair_lock_lock(&g_hookLock);
        BOOL complete = g_unityReady && g_sceneHookInstalled;
        os_unfair_lock_unlock(&g_hookLock);
        if (complete || elapsed >= kZSHookFallbackMaxSeconds) dispatch_source_cancel(timer);
    });
    dispatch_resume(timer);
}

static void zs_hook_image_added(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    zs_hook_install_keyboard_guard();
    dispatch_async(dispatch_get_main_queue(), ^{
        zs_hook_install_start_unity();
    });
}

__attribute__((constructor))
static void zs_hooks_constructor(void) {
    zs_hook_install_start_unity();
    _dyld_register_func_for_add_image(zs_hook_image_added);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSOperationQueue *main = NSOperationQueue.mainQueue;
    for (NSNotificationName name in @[UIApplicationDidFinishLaunchingNotification,
                                      UIApplicationDidBecomeActiveNotification,
                                      UIWindowDidBecomeVisibleNotification,
                                      UIWindowDidBecomeKeyNotification]) {
        [center addObserverForName:name object:nil queue:main usingBlock:^(NSNotification *note) {
            zs_hook_install_start_unity();
            zs_hook_tick();
        }];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        zs_hook_install_start_unity();
        zs_hook_tick();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZSHookFallbackGraceSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        zs_hook_start_fallback();
    });
}
