#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZSHookID) {
    ZSHookIDSceneLoaded = 0,
    ZSHookIDFrameRate,
    ZSHookIDGreeting,
    ZSHookIDTips,
    ZSHookIDCount
};

typedef void (^ZSSceneChangedBlock)(int32_t state, int32_t previousState);

BOOL zs_hook_swizzle_instance(Class cls, SEL selector, IMP replacement, IMP _Nullable * _Nullable original);
BOOL zs_hook_il2cpp_named(const char *namespaze, const char *className, const char *assemblyContains, const char *methodName, int argCount, void *replacement, void * _Nullable * _Nullable original);
BOOL zs_hook_il2cpp_method(const void *method, void *replacement, void * _Nullable * _Nullable original);

void zs_hook_mark_armed(ZSHookID hook);
BOOL zs_hook_is_armed(ZSHookID hook);

BOOL zs_unity_is_ready(void);
void zs_on_unity_ready(dispatch_block_t block);
void zs_on_scene_changed(ZSSceneChangedBlock block);
void zs_hooks_nudge(void);

NS_ASSUME_NONNULL_END
