#import "ZSEngine.h"
#include <string.h>
#include <strings.h>
#import "IL2CppIntrospection.h"
#import "ZTweakLog.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <math.h>
#include <stdint.h>
#include <dlfcn.h>
#include <unistd.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <dlfcn.h>
#import <QuartzCore/CAMetalLayer.h>
#import <os/proc.h>
#include <sys/sysctl.h>
#import <Security/Security.h>
#import "UnityBundleTools.h"
#import "Mods.h"

#pragma mark - ZSScripts

static void ZSCustomGreeting_HotFieldInvalidate(void);
static void ZSUID_HotFieldInvalidate(void);
BOOL ZSGlobalScene_Current(int32_t *outState);
static const int32_t kZSFontSceneStateMain = 2;
static void *ZSUID_FindActiveInstance(void *klass);
static void zs_reapply_all_settings_except_experimental(void);
static void zs_apply_persisted_particle_settings(void);
void zs_particles_load_from_dictionary(NSDictionary *particles);
NSDictionary *zs_particles_settings_dictionary(void);
BOOL zs_particle_get_bool(NSString *key);
float zs_particle_get_number(NSString *key);
float zs_particle_get_default_number(NSString *key);

#pragma mark - Generic IL2CPP class/field/type/method caches

static NSMutableDictionary<NSString *, NSValue *> *g_classCache;
static NSMutableDictionary<NSString *, NSValue *> *g_fieldOffsetCache;
static NSMutableDictionary<NSString *, NSValue *> *g_typeObjCache;
static NSMutableDictionary<NSString *, NSValue *> *g_methodCache;

static void *zs_class(const char *ns, const char *name, const char *assemblySubstring) {
    if (!g_classCache) g_classCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%s.%s@%s", ns, name, assemblySubstring];
    NSValue *cached = g_classCache[key];
    if (cached) return cached.pointerValue;

    void *klass = [IL2CppBridge classNamed:name inNamespace:ns assemblyContains:assemblySubstring];
    if (klass) g_classCache[key] = [NSValue valueWithPointer:klass];
    return klass;
}

static int32_t zs_offset(void *klass, const char *fieldName) {
    if (!klass) return -1;
    if (!g_fieldOffsetCache) g_fieldOffsetCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p.%s", klass, fieldName];
    NSValue *cached = g_fieldOffsetCache[key];
    if (cached) return (int32_t)(intptr_t)cached.pointerValue;

    int32_t off = [IL2CppBridge fieldOffsetOnClass:klass name:fieldName];
    g_fieldOffsetCache[key] = [NSValue valueWithPointer:(void *)(intptr_t)off];
    return off;
}

void *zs_type_object(void *klass) {
    if (!klass) return NULL;
    if (!g_typeObjCache) g_typeObjCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p", klass];
    NSValue *cached = g_typeObjCache[key];
    if (cached) return cached.pointerValue;

    void *typeObj = [IL2CppBridge reflectionTypeForClass:klass];
    if (typeObj) g_typeObjCache[key] = [NSValue valueWithPointer:typeObj];
    return typeObj;
}

static const void *zs_method(void *klass, const char *name, int argCount) {
    if (!klass) return NULL;
    if (!g_methodCache) g_methodCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p.%s/%d", klass, name, argCount];
    NSValue *cached = g_methodCache[key];
    if (cached) return cached.pointerValue;

    const void *method = [IL2CppBridge methodOnClass:klass name:name argCount:argCount];
    if (method) g_methodCache[key] = [NSValue valueWithPointer:(void *)method];
    return method;
}

#pragma mark - GlobalGameManager / urpAsset (render scale + extended settings)

static void *zs_get_global_game_manager_instance(void) {
    void *klass = zs_class("", "GlobalGameManager", "Assembly-CSharp");
    if (!klass) return NULL;
    const void *getInstance = zs_method(klass, "get_Instance", 0);
    if (!getInstance) return NULL;
    void *exc = NULL;
    void *instance = [IL2CppBridge invokeMethod:getInstance onInstance:NULL args:NULL outException:&exc];
    if (exc || !instance) return NULL;
    return instance;
}

static void *zs_get_urp_asset(void) {
    void *manager = zs_get_global_game_manager_instance();
    if (!manager) return NULL;
    void *klass = zs_class("", "GlobalGameManager", "Assembly-CSharp");
    int32_t off = zs_offset(klass, "urpAsset");
    if (off < 0) return NULL;
    return *(void **)((uint8_t *)manager + off);
}

static void *zs_urp_asset_class(void) {
    return zs_class("UnityEngine.Rendering.Universal", "UniversalRenderPipelineAsset", "Universal.Runtime");
}

void zs_set_render_scale(float scale) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = zs_method(zs_urp_asset_class(), "set_renderScale", 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &scale };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

void zs_urp_set_bool(const char *setterName, BOOL value) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = zs_method(zs_urp_asset_class(), setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

void zs_urp_set_int(const char *setterName, int32_t value) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = zs_method(zs_urp_asset_class(), setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

void zs_urp_set_float(const char *setterName, float value) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return;
    const void *setter = zs_method(zs_urp_asset_class(), setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:urpAsset args:args outException:&exc];
}

int32_t zs_step_value(const int32_t *steps, int count, float sliderValue) {
    int idx = (int)roundf(sliderValue);
    if (idx < 0) idx = 0;
    if (idx >= count) idx = count - 1;
    return steps[idx];
}

const int32_t kMSAASteps[4] = { 1, 2, 4, 8 };

#pragma mark - QualitySettings (texture mip limit)

void zs_set_texture_mip_limit(int32_t mipLimit) {
    void *klass = zs_class("UnityEngine", "QualitySettings", "CoreModule");
    const void *setter = zs_method(klass, "set_globalTextureMipmapLimit", 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &mipLimit };
    [IL2CppBridge invokeMethod:setter onInstance:NULL args:args outException:&exc];
}

#pragma mark - Volume system (shared by Post FX)

static void *g_volumeManagerInstance;
static void *g_volumeStackInstance;
static int g_vmTicksSinceRefresh = 999;

static void *zs_get_volume_stack(void) {
    void *vmClass = zs_class("UnityEngine.Rendering", "VolumeManager", "Core.Runtime");
    if (!vmClass) return NULL;

    BOOL needsRefresh = (!g_volumeStackInstance || g_vmTicksSinceRefresh >= 8);
    if (!needsRefresh) {
        g_vmTicksSinceRefresh++;
        return g_volumeStackInstance;
    }

    const void *getInstance = zs_method(vmClass, "get_instance", 0);
    if (!getInstance) return NULL;
    void *exc = NULL;
    void *vmInstance = [IL2CppBridge invokeMethod:getInstance onInstance:NULL args:NULL outException:&exc];
    if (exc || !vmInstance) return NULL;
    g_volumeManagerInstance = vmInstance;

    const void *getStack = zs_method(vmClass, "get_stack", 0);
    if (!getStack) return NULL;
    exc = NULL;
    void *stack = [IL2CppBridge invokeMethod:getStack onInstance:vmInstance args:NULL outException:&exc];
    if (exc || !stack) return NULL;

    g_volumeStackInstance = stack;
    g_vmTicksSinceRefresh = 0;
    return stack;
}

static void *zs_get_volume_component_ns(NSString *namespaze, NSString *assemblySubstring, const char *componentClassName) {
    void *stack = zs_get_volume_stack();
    if (!stack) return NULL;

    void *componentClass = zs_class(namespaze.UTF8String, componentClassName, assemblySubstring.UTF8String);
    if (!componentClass) return NULL;
    void *typeObj = zs_type_object(componentClass);
    if (!typeObj) return NULL;

    void *stackClass = [IL2CppBridge classOfInstance:stack];
    const void *getComponent = zs_method(stackClass, "GetComponent", 1);
    if (!getComponent) return NULL;

    void *exc = NULL;
    void *args[1] = { typeObj };
    void *component = [IL2CppBridge invokeMethod:getComponent onInstance:stack args:args outException:&exc];
    if (exc) return NULL;
    return component;
}

static void *zs_get_volume_component(const char *componentClassName) {
    return zs_get_volume_component_ns(@"UnityEngine.Rendering.Universal", @"Universal.Runtime", componentClassName);
}

static void zs_set_component_active(void *component, BOOL active) {
    if (!component) return;
    void *klass = [IL2CppBridge classOfInstance:component];
    int32_t off = zs_offset(klass, "active");
    if (off < 0) return;
    *(BOOL *)((uint8_t *)component + off) = active;
}

static void *zs_get_param_object(void *component, const char *paramFieldName) {
    if (!component) return NULL;
    void *componentClass = [IL2CppBridge classOfInstance:component];
    int32_t off = zs_offset(componentClass, paramFieldName);
    if (off < 0) return NULL;
    return *(void **)((uint8_t *)component + off);
}

static void zs_set_param_float(void *paramObj, float value) {
    if (!paramObj) return;
    void *klass = [IL2CppBridge classOfInstance:paramObj];
    int32_t off = zs_offset(klass, "m_Value");
    if (off < 0) return;
    *(float *)((uint8_t *)paramObj + off) = value;
}

static void zs_set_param_int(void *paramObj, int32_t value) {
    if (!paramObj) return;
    void *klass = [IL2CppBridge classOfInstance:paramObj];
    int32_t off = zs_offset(klass, "m_Value");
    if (off < 0) return;
    *(int32_t *)((uint8_t *)paramObj + off) = value;
}

void zs_apply_motion_blur(void) {
    void *blur = zs_get_volume_component("MotionBlur");
    if (!blur) return;
    zs_set_component_active(blur, YES);
    zs_set_param_float(zs_get_param_object(blur, "intensity"), g_blurIntensity);
}

#pragma mark - Renderer features (feature-level toggles, distinct from Volume components)

static int32_t zs_unbox_int32(void *boxed) {
    if (!boxed) return 0;
    void *klass = [IL2CppBridge classOfInstance:boxed];
    int32_t off = zs_offset(klass, "m_value");
    if (off < 0) return 0;
    return *(int32_t *)((uint8_t *)boxed + off);
}

static void *zs_get_scriptable_renderer(void) {
    void *urpAsset = zs_get_urp_asset();
    if (!urpAsset) return NULL;
    const void *getter = zs_method(zs_urp_asset_class(), "get_scriptableRenderer", 0);
    if (!getter) return NULL;
    void *exc = NULL;
    void *renderer = [IL2CppBridge invokeMethod:getter onInstance:urpAsset args:NULL outException:&exc];
    if (exc || !renderer) return NULL;
    return renderer;
}

static void *zs_get_renderer_features_list(void) {
    void *renderer = zs_get_scriptable_renderer();
    if (!renderer) return NULL;
    void *rendererClass = [IL2CppBridge classOfInstance:renderer];
    const void *getter = zs_method(rendererClass, "get_rendererFeatures", 0);
    if (!getter) return NULL;
    void *exc = NULL;
    void *list = [IL2CppBridge invokeMethod:getter onInstance:renderer args:NULL outException:&exc];
    if (exc || !list) return NULL;
    return list;
}

static void *zs_find_renderer_feature(NSString *namespaze, NSString *assemblySubstring, NSArray<NSString *> *candidateNames) {
    void *list = zs_get_renderer_features_list();
    if (!list) return NULL;
    void *listClass = [IL2CppBridge classOfInstance:list];
    const void *getCount = zs_method(listClass, "get_Count", 0);
    const void *getItem = zs_method(listClass, "get_Item", 1);
    if (!getCount || !getItem) return NULL;

    void *exc = NULL;
    void *countBoxed = [IL2CppBridge invokeMethod:getCount onInstance:list args:NULL outException:&exc];
    if (exc) return NULL;
    int32_t count = zs_unbox_int32(countBoxed);

    NSMutableArray<NSValue *> *candidateKlasses = [NSMutableArray new];
    for (NSString *name in candidateNames) {
        void *klass = zs_class(namespaze.UTF8String, name.UTF8String, assemblySubstring.UTF8String);
        if (klass) [candidateKlasses addObject:[NSValue valueWithPointer:klass]];
    }
    if (candidateKlasses.count == 0) return NULL;

    for (int32_t i = 0; i < count; i++) {
        int32_t idx = i;
        void *args[1] = { &idx };
        exc = NULL;
        void *item = [IL2CppBridge invokeMethod:getItem onInstance:list args:args outException:&exc];
        if (exc || !item) continue;
        void *itemKlass = [IL2CppBridge classOfInstance:item];
        for (NSValue *v in candidateKlasses) {
            if (v.pointerValue == itemKlass) return item;
        }
    }
    return NULL;
}

static void zs_set_feature_active(void *feature, BOOL active) {
    if (!feature) return;
    void *klass = [IL2CppBridge classOfInstance:feature];
    const void *setter = zs_method(klass, "SetActive", 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &active };
    [IL2CppBridge invokeMethod:setter onInstance:feature args:args outException:&exc];
}

#pragma mark - Extended native URP Post FX

const ZSVolumeEffectDef kURPPostEffects[] = {
    { "Chroma",            "ChromaticAberration", "intensity",   0.0f,   1.0f,   0.0f },
    { "Vignette",          "Vignette",            "intensity",   0.0f,   1.0f,   0.3f },
    { "Film Grain",        "FilmGrain",           "intensity",   0.0f,   1.0f,   0.3f },
    { "Lens Distort",      "LensDistortion",      "intensity",  -1.0f,   1.0f,   0.0f },
    { "White Balance",     "WhiteBalance",        "temperature", -100.0f, 100.0f, 0.0f },
    { "Saturation",        "ColorAdjustments",    "saturation", -100.0f, 100.0f, 0.0f },

};
const int kURPPostEffectCount = sizeof(kURPPostEffects) / sizeof(kURPPostEffects[0]);

NSMutableDictionary<NSString *, NSNumber *> *g_urpActive;
NSMutableDictionary<NSString *, NSNumber *> *g_urpValue;

static const ZSVolumeEffectDef *zs_urp_def_named(NSString *name) {
    for (int i = 0; i < kURPPostEffectCount; i++) {
        if ([name isEqualToString:[NSString stringWithUTF8String:kURPPostEffects[i].name]]) return &kURPPostEffects[i];
    }
    return NULL;
}

void zs_apply_urp_post_effect(NSString *name) {
    const ZSVolumeEffectDef *def = zs_urp_def_named(name);
    if (!def) return;
    BOOL active = g_urpActive[name].boolValue;

    float fv = def->defaultV;
    if (def->floatField) {
        NSNumber *val = g_urpValue[name];
        fv = val ? val.floatValue : def->defaultV;
    }

    BOOL isLensDistortion = (strcmp(def->engineName, "LensDistortion") == 0);
    if (isLensDistortion && fabsf(fv) < 0.0001f) {
        active = NO;
        fv = -0.01f;
    }

    void *component = zs_get_volume_component(def->engineName);
    if (component) {
        zs_set_component_active(component, active);
        if (def->floatField) {
            zs_set_param_float(zs_get_param_object(component, def->floatField), fv);
        }
    }
    NSString *rendererName = [NSString stringWithFormat:@"%sRenderer", def->engineName];
    void *feature = zs_find_renderer_feature(@"UnityEngine.Rendering.Universal", @"Universal.Runtime", @[rendererName]);
    zs_set_feature_active(feature, active);
}

int32_t g_tonemapMode = 0;

void zs_apply_tonemapping(void) {
    void *component = zs_get_volume_component("Tonemapping");
    if (!component) return;
    zs_set_component_active(component, YES);
    zs_set_param_int(zs_get_param_object(component, "mode"), g_tonemapMode);
}

#pragma mark - Camera-level post settings (antialiasing / dithering)

static void *zs_get_main_camera(void) {
    void *klass = zs_class("UnityEngine", "Camera", "CoreModule");
    if (!klass) return NULL;
    const void *getMain = zs_method(klass, "get_main", 0);
    if (!getMain) return NULL;
    void *exc = NULL;
    void *cam = [IL2CppBridge invokeMethod:getMain onInstance:NULL args:NULL outException:&exc];
    if (exc || !cam) return NULL;
    return cam;
}

static void *zs_get_camera_data(void) {
    void *cam = zs_get_main_camera();
    if (!cam) return NULL;
    void *camKlass = [IL2CppBridge classOfInstance:cam];
    void *dataKlass = zs_class("UnityEngine.Rendering.Universal", "UniversalAdditionalCameraData", "Universal.Runtime");
    if (!dataKlass) return NULL;
    void *typeObj = zs_type_object(dataKlass);
    if (!typeObj) return NULL;
    const void *getComponent = zs_method(camKlass, "GetComponent", 1);
    if (!getComponent) return NULL;
    void *exc = NULL;
    void *args[1] = { typeObj };
    void *data = [IL2CppBridge invokeMethod:getComponent onInstance:cam args:args outException:&exc];
    if (exc) return NULL;
    return data;
}

void zs_camera_data_set_int(const char *setterName, int32_t value) {
    void *data = zs_get_camera_data();
    if (!data) return;
    void *klass = [IL2CppBridge classOfInstance:data];
    const void *setter = zs_method(klass, setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:data args:args outException:&exc];
}

void zs_camera_data_set_bool(const char *setterName, BOOL value) {
    void *data = zs_get_camera_data();
    if (!data) return;
    void *klass = [IL2CppBridge classOfInstance:data];
    const void *setter = zs_method(klass, setterName, 1);
    if (!setter) return;
    void *exc = NULL;
    void *args[1] = { &value };
    [IL2CppBridge invokeMethod:setter onInstance:data args:args outException:&exc];
}

const int32_t kAAModeSteps[4]    = { 0, 1, 2, 3 };
const int32_t kAAQualitySteps[3] = { 0, 1, 2 };

#pragma mark - Hardcoded setting defaults

const NSInteger kDefaultMenuFPS          = 60;
const NSInteger kDefaultCombatFPS        = 60;
const int32_t   kDefaultTextureMipEngine = 0;
const float     kDefaultRenderScalePct   = 100.0f;
const float     kDefaultBattleRenderScalePct = 100.0f;
const int32_t   kDefaultMSAAIndex        = 0;
const BOOL      kDefaultHDR              = YES;
const float     kDefaultMotionBlur       = 0.0f;
const int32_t   kDefaultTonemapIndex     = 0;
const int32_t   kDefaultAAModeIndex      = 0;
const int32_t   kDefaultAAQualityIndex   = 1;
const BOOL      kDefaultDithering        = NO;

#pragma mark - Current-value globals

int32_t   g_textureMip     = 0;
float     g_renderScale    = 1.0f;
float     g_battleRenderScale = 1.0f;
int32_t   g_msaaIndex      = 0;
BOOL      g_hdrOn          = YES;
float     g_blurIntensity  = 0.0f;
int32_t   g_aaModeIndex    = 0;
int32_t   g_aaQualityIndex = 1;
BOOL      g_ditheringOn    = NO;
NSInteger g_menuFPS        = 60;
NSInteger g_combatFPS      = 60;
NSArray<NSString *> *g_syslogBlacklist = nil;
NSMutableArray<NSString *> *g_trackedAssetPaths = nil;
NSDictionary *g_fileIndexSnapshot = nil;
BOOL g_experimentalSettingsEnabled = NO;

#pragma mark - Battle-aware render scale switching

static float g_lastAppliedRenderScale = -1.0f;

void zs_apply_render_scale_for_battle_state(BOOL isBattle, BOOL force) {
    float scale = isBattle ? g_battleRenderScale : g_renderScale;
    if (!force && fabsf(g_lastAppliedRenderScale - scale) <= 0.0001f) return;
    g_lastAppliedRenderScale = scale;
    zs_set_render_scale(scale);
}

#pragma mark - Settings persistence (single settings.json in Documents)

static NSString *zs_settings_file_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"settings.json"];
}

static NSString *zs_file_index_file_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"Index.json"];
}

// Index.json can grow to hold thousands of cached file paths (CAB map, FMOD
// names, localization paths). Loading/writing it as one NSData blob means one
// single contiguous allocation for the whole thing - on iOS that has to be
// satisfied by one vm_allocate call, and a large-enough or unlucky-enough one
// can fail even when there's technically free memory elsewhere (address space
// fragmentation, not just total free RAM). When that allocation fails, malloc
// aborts the process outright. Both sides below stream instead of building
// one giant buffer, and the write goes through a temp file + rename so a
// crash or kill mid-write can never leave Index.json half-written/corrupt.

static NSDictionary *zs_load_file_index_dictionary(void) {
    NSString *path = zs_file_index_file_path();
    if (!path) return nil;

    // Memory-map rather than copy the file into a fresh heap buffer; the
    // pages are paged in on demand instead of requiring one upfront
    // contiguous allocation the size of the whole file.
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path
                                           options:NSDataReadingMappedIfSafe
                                             error:&readError];
    if (!data) {
        if (readError && readError.code != NSFileReadNoSuchFileError) {
            ZLog(@"[ZSScripts] failed to read Index.json: %@", readError);
        }
        return nil;
    }

    NSError *error = nil;
    id obj = nil;
    @try {
        obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    } @catch (NSException *exception) {
        ZLog(@"[ZSScripts] Index.json parse threw, treating as unreadable: %@", exception);
        return nil;
    }
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        if (error) ZLog(@"[ZSScripts] failed to parse Index.json: %@", error);
        return nil;
    }
    return (NSDictionary *)obj;
}

static void zs_write_file_index_dictionary(NSDictionary *dict) {
    NSString *path = zs_file_index_file_path();
    if (!path) return;

    if (![NSJSONSerialization isValidJSONObject:dict]) {
        ZLog(@"[ZSScripts] refusing to write Index.json: not a valid JSON object");
        return;
    }

    NSString *tmpPath = [path stringByAppendingPathExtension:@"tmp"];
    [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
    if (![NSFileManager.defaultManager createFileAtPath:tmpPath contents:nil attributes:nil]) {
        ZLog(@"[ZSScripts] failed to create temp file for Index.json");
        return;
    }

    NSOutputStream *stream = [NSOutputStream outputStreamToFileAtPath:tmpPath append:NO];
    [stream open];

    // Streams the encoded JSON out incrementally instead of materializing the
    // whole encoded document as one NSData first - the fix for the single
    // huge allocation described above.
    NSError *error = nil;
    NSInteger written = 0;
    @try {
        written = [NSJSONSerialization writeJSONObject:dict toStream:stream options:0 error:&error];
    } @catch (NSException *exception) {
        ZLog(@"[ZSScripts] Index.json encode threw: %@", exception);
        written = -1;
    }
    [stream close];

    if (written <= 0 || error) {
        if (error) ZLog(@"[ZSScripts] failed to encode Index.json: %@", error);
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        return;
    }

    NSError *moveError = nil;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    if (![NSFileManager.defaultManager moveItemAtPath:tmpPath toPath:path error:&moveError]) {
        ZLog(@"[ZSScripts] failed to move Index.json into place: %@", moveError);
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
    }
}

NSDictionary *zs_load_settings_dictionary(void) {
    NSString *path = zs_settings_file_path();
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        if (error) ZLog(@"[ZSScripts] failed to parse settings JSON: %@", error);
        return nil;
    }
    return (NSDictionary *)obj;
}

void zs_write_settings_dictionary(NSDictionary *dict) {
    NSString *path = zs_settings_file_path();
    if (!path) return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    if (error || !data) {
        ZLog(@"[ZSScripts] failed to encode settings JSON: %@", error);
        return;
    }
    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        ZLog(@"[ZSScripts] failed to write settings JSON: %@", writeError);
    }
}

NSDictionary *zs_settings_section(NSString *sectionKey) {
    NSDictionary *whole = zs_load_settings_dictionary();
    id section = whole[sectionKey];
    return [section isKindOfClass:[NSDictionary class]] ? section : nil;
}

void zs_write_settings_section(NSString *sectionKey, NSDictionary *sectionValue) {
    NSMutableDictionary *whole = [zs_load_settings_dictionary() mutableCopy] ?: [NSMutableDictionary new];
    whole[sectionKey] = sectionValue ?: @{};
    zs_write_settings_dictionary(whole);
}

#pragma mark - Tracked asset paths (Hard Assets Reset)

static void zs_ensure_tracked_asset_paths_loaded(void) {
    if (g_trackedAssetPaths) return;
    NSDictionary *modLoader = zs_settings_section(@"modLoader");
    NSArray *savedPaths = [modLoader[@"trackedAssetPaths"] isKindOfClass:[NSArray class]] ? modLoader[@"trackedAssetPaths"] : nil;
    g_trackedAssetPaths = [NSMutableArray new];
    for (id path in savedPaths) {
        if ([path isKindOfClass:[NSString class]]) [g_trackedAssetPaths addObject:path];
    }
}

void zs_track_asset_path(NSString *path) {
    if (path.length == 0) return;
    zs_ensure_tracked_asset_paths_loaded();
    if ([g_trackedAssetPaths containsObject:path]) return;
    [g_trackedAssetPaths addObject:path];

    zs_persist_current_settings();
}

NSArray<NSString *> *zs_tracked_asset_paths(void) {
    zs_ensure_tracked_asset_paths_loaded();
    return [g_trackedAssetPaths copy];
}

void zs_clear_tracked_asset_paths(void) {
    zs_ensure_tracked_asset_paths_loaded();
    [g_trackedAssetPaths removeAllObjects];
    zs_persist_current_settings();
}

#pragma mark - File index (Mod Loader Pipeline caching, stored in its own Index.json)

static void zs_ensure_file_index_snapshot_loaded_impl(void) {
    if (g_fileIndexSnapshot) return;
    g_fileIndexSnapshot = zs_load_file_index_dictionary() ?: @{};
}

void zs_ensure_file_index_snapshot_loaded(void) {
    zs_ensure_file_index_snapshot_loaded_impl();
}

void zs_set_file_index_snapshot(NSDictionary *snapshot) {
    g_fileIndexSnapshot = snapshot ?: @{};
    zs_write_file_index_dictionary(g_fileIndexSnapshot);
}

#pragma mark - Guaranteed-once settings load

void zs_ensure_settings_loaded_from_disk(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *saved = zs_load_settings_dictionary();

        NSDictionary *savedDisplay      = [saved[@"display"] isKindOfClass:[NSDictionary class]] ? saved[@"display"] : @{};
        NSDictionary *savedRendering    = [saved[@"rendering"] isKindOfClass:[NSDictionary class]] ? saved[@"rendering"] : @{};
        NSDictionary *savedAntiAliasing = [saved[@"antiAliasing"] isKindOfClass:[NSDictionary class]] ? saved[@"antiAliasing"] : @{};
        NSDictionary *savedPostFX       = [saved[@"postFX"] isKindOfClass:[NSDictionary class]] ? saved[@"postFX"] : @{};
        NSDictionary *savedDiagnostics  = [saved[@"diagnostics"] isKindOfClass:[NSDictionary class]] ? saved[@"diagnostics"] : @{};
        NSDictionary *savedConfig       = [saved[@"config"] isKindOfClass:[NSDictionary class]] ? saved[@"config"] : @{};

        NSNumber *(^num)(NSDictionary *, NSString *) = ^NSNumber *(NSDictionary *section, NSString *key) {
            id v = section[key];
            return [v isKindOfClass:[NSNumber class]] ? (NSNumber *)v : nil;
        };

        g_menuFPS      = num(savedDisplay, @"menuFPS") ? num(savedDisplay, @"menuFPS").integerValue : kDefaultMenuFPS;
        g_combatFPS    = num(savedDisplay, @"combatFPS") ? num(savedDisplay, @"combatFPS").integerValue : kDefaultCombatFPS;
        g_textureMip   = num(savedRendering, @"textureMip") ? num(savedRendering, @"textureMip").intValue : kDefaultTextureMipEngine;
        g_renderScale  = (num(savedRendering, @"renderScalePercent") ? num(savedRendering, @"renderScalePercent").floatValue : kDefaultRenderScalePct) / 100.0f;
        g_battleRenderScale = (num(savedRendering, @"battleRenderScalePercent") ? num(savedRendering, @"battleRenderScalePercent").floatValue : kDefaultBattleRenderScalePct) / 100.0f;
        g_msaaIndex    = num(savedRendering, @"msaaIndex") ? num(savedRendering, @"msaaIndex").intValue : kDefaultMSAAIndex;
        g_hdrOn        = num(savedPostFX, @"hdr") ? num(savedPostFX, @"hdr").boolValue : kDefaultHDR;
        g_blurIntensity = num(savedPostFX, @"motionBlur") ? num(savedPostFX, @"motionBlur").floatValue : kDefaultMotionBlur;
        g_tonemapMode  = num(savedPostFX, @"tonemapIndex") ? num(savedPostFX, @"tonemapIndex").intValue : kDefaultTonemapIndex;
        g_aaModeIndex  = num(savedAntiAliasing, @"aaModeIndex") ? num(savedAntiAliasing, @"aaModeIndex").intValue : kDefaultAAModeIndex;
        g_aaQualityIndex = num(savedAntiAliasing, @"aaQualityIndex") ? num(savedAntiAliasing, @"aaQualityIndex").intValue : kDefaultAAQualityIndex;
        g_ditheringOn  = num(savedAntiAliasing, @"dithering") ? num(savedAntiAliasing, @"dithering").boolValue : kDefaultDithering;
        g_experimentalSettingsEnabled = num(savedConfig, @"experimentalSettingsEnabled") ? num(savedConfig, @"experimentalSettingsEnabled").boolValue : NO;

        zs_exp_load_from_dictionary(saved[@"experimental"]);
        zs_particles_load_from_dictionary(saved[@"particles"] ?: saved[@"experimental"]);

        if (!g_urpActive) g_urpActive = [NSMutableDictionary new];
        if (!g_urpValue) g_urpValue = [NSMutableDictionary new];
        NSDictionary *savedUrp = [savedPostFX[@"urpEffects"] isKindOfClass:[NSDictionary class]] ? savedPostFX[@"urpEffects"] : nil;
        for (int i = 0; i < kURPPostEffectCount; i++) {
            const ZSVolumeEffectDef *def = &kURPPostEffects[i];
            NSString *name = [NSString stringWithUTF8String:def->name];
            g_urpActive[name] = @YES;
            if (def->floatField) {
                NSNumber *savedVal = [savedUrp[name] isKindOfClass:[NSNumber class]] ? savedUrp[name] : nil;
                g_urpValue[name] = @(savedVal ? savedVal.floatValue : def->defaultV);
            }
        }

        NSArray *savedBlacklist = [savedDiagnostics[@"syslogBlacklist"] isKindOfClass:[NSArray class]] ? savedDiagnostics[@"syslogBlacklist"] : nil;
        NSMutableArray<NSString *> *blacklist = [NSMutableArray array];
        for (id term in savedBlacklist) {
            if ([term isKindOfClass:[NSString class]]) [blacklist addObject:term];
        }
        g_syslogBlacklist = blacklist;

        zs_ensure_tracked_asset_paths_loaded();
        zs_ensure_file_index_snapshot_loaded_impl();
    });
}

NSDictionary *zs_current_settings_dictionary(void) {
    zs_ensure_settings_loaded_from_disk();
    zs_ensure_tracked_asset_paths_loaded();
    zs_ensure_file_index_snapshot_loaded_impl();

    NSMutableDictionary *urp = [NSMutableDictionary new];
    for (int i = 0; i < kURPPostEffectCount; i++) {
        if (!kURPPostEffects[i].floatField) continue;
        NSString *name = [NSString stringWithUTF8String:kURPPostEffects[i].name];
        NSNumber *v = g_urpValue[name];
        if (v) urp[name] = v;
    }
    return @{
        @"display": @{
            @"menuFPS": @(g_menuFPS),
            @"combatFPS": @(g_combatFPS),
        },
        @"rendering": @{
            @"textureMip": @(g_textureMip),
            @"renderScalePercent": @(roundf(g_renderScale * 100.0f)),
            @"battleRenderScalePercent": @(roundf(g_battleRenderScale * 100.0f)),
            @"msaaIndex": @(g_msaaIndex),
        },
        @"antiAliasing": @{
            @"aaModeIndex": @(g_aaModeIndex),
            @"aaQualityIndex": @(g_aaQualityIndex),
            @"dithering": @(g_ditheringOn),
        },
        @"postFX": @{
            @"hdr": @(g_hdrOn),
            @"motionBlur": @(g_blurIntensity),
            @"tonemapIndex": @(g_tonemapMode),
            @"urpEffects": urp,
        },
        @"experimental": zs_exp_settings_dictionary(),
        @"particles": zs_particles_settings_dictionary(),
        @"config": @{
            @"experimentalSettingsEnabled": @(g_experimentalSettingsEnabled),
        },
        @"modLoader": @{
            @"trackedAssetPaths": g_trackedAssetPaths ?: @[],
        },
        @"diagnostics": @{
            @"syslogBlacklist": g_syslogBlacklist ?: @[],
        },
    };
}

void zs_persist_current_settings(void) {
    NSMutableDictionary *whole = [zs_load_settings_dictionary() mutableCopy] ?: [NSMutableDictionary new];
    [whole addEntriesFromDictionary:zs_current_settings_dictionary()];
    zs_write_settings_dictionary(whole);
}

#pragma mark - FPS120Controller

static CADisplayLink *find_display_link(id appController) {
    CADisplayLink *found = nil;
    Class cls = [appController class];

    while (cls && !found) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && strstr(type, "CADisplayLink")) {
                id value = object_getIvar(appController, ivars[i]);
                if ([value isKindOfClass:[CADisplayLink class]]) {
                    found = (CADisplayLink *)value;
                    break;
                }
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }

    return found;
}

static CADisplayLink *g_unityDisplayLink;

static CADisplayLink *zs_refresh_unity_display_link(void) {
    id appController = [[UIApplication sharedApplication] delegate];
    if (!appController) return g_unityDisplayLink;
    CADisplayLink *link = find_display_link(appController);
    if (link) g_unityDisplayLink = link;
    return g_unityDisplayLink;
}

static BOOL zs_set_application_target_fps(int32_t fps) {
    CADisplayLink *link = zs_refresh_unity_display_link();
    if (!link) return NO;
    link.preferredFramesPerSecond = fps;
    return YES;
}

static BOOL zs_ivar_is_flag(Ivar ivar) {
    const char *type = ivar_getTypeEncoding(ivar);
    return type && (type[0] == 'B' || type[0] == 'c' || type[0] == 'C');
}

static BOOL zs_class_chain_has_display_link(Class cls) {
    for (; cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        BOOL has = NO;
        for (unsigned int i = 0; i < count && !has; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && strstr(type, "CADisplayLink")) has = YES;
        }
        free(ivars);
        if (has) return YES;
    }
    return NO;
}

static int zs_paused_name_score(const char *name) {
    if (!name) return 0;
    const char *bare = name[0] == '_' ? name + 1 : name;
    if (strcmp(bare, "paused") == 0) return 4;
    if (strcasecmp(bare, "paused") == 0) return 3;
    if (strcasestr(bare, "paused")) return 2;
    if (strcasestr(bare, "paus")) return 1;
    return 0;
}

static BOOL zs_find_paused_ivar_in_object(id object, Ivar *outIvar, int *outScore) {
    int best = 0;
    Ivar bestIvar = NULL;
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            if (!zs_ivar_is_flag(ivars[i])) continue;
            int score = zs_paused_name_score(ivar_getName(ivars[i]));
            if (score > best) {
                best = score;
                bestIvar = ivars[i];
            }
        }
        free(ivars);
    }
    if (!bestIvar) return NO;
    *outIvar = bestIvar;
    *outScore = best;
    return YES;
}

static void zs_log_ivar_names(id object, NSString *label) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            [names addObject:[NSString stringWithFormat:@"%s(%s)", name ?: "?", type ?: "?"]];
        }
        free(ivars);
    }
    ZLog(@"[ZSScripts] %@ ivars: %@", label, [names componentsJoinedByString:@", "]);
}

static BOOL zs_locate_paused_flag(id appController, id *outOwner, Ivar *outIvar) {
    Ivar ivar = NULL;
    int score = 0;
    if (zs_find_paused_ivar_in_object(appController, &ivar, &score) && score >= 3) {
        *outOwner = appController;
        *outIvar = ivar;
        return YES;
    }

    id bestOwner = nil;
    Ivar bestIvar = NULL;
    int bestScore = 0;
    BOOL bestHoldsLink = NO;
    for (Class cls = object_getClass(appController); cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id child = object_getIvar(appController, ivars[i]);
            if (!child || [child isKindOfClass:[CADisplayLink class]]) continue;
            Ivar childIvar = NULL;
            int childScore = 0;
            if (!zs_find_paused_ivar_in_object(child, &childIvar, &childScore)) continue;
            BOOL holdsLink = zs_class_chain_has_display_link(object_getClass(child));
            BOOL better = !bestOwner
                || (holdsLink && !bestHoldsLink)
                || (holdsLink == bestHoldsLink && childScore > bestScore);
            if (better) {
                bestOwner = child;
                bestIvar = childIvar;
                bestScore = childScore;
                bestHoldsLink = holdsLink;
            }
        }
        free(ivars);
    }
    if (bestOwner && (bestHoldsLink || bestScore >= 3)) {
        *outOwner = bestOwner;
        *outIvar = bestIvar;
        return YES;
    }
    if (ivar && score >= 2) {
        *outOwner = appController;
        *outIvar = ivar;
        return YES;
    }
    return NO;
}

static BOOL zs_set_paused_via_property(id appController, BOOL paused) {
    static const char *kNames[] = { "paused", "Paused" };
    for (size_t n = 0; n < sizeof(kNames) / sizeof(kNames[0]); n++) {
        objc_property_t property = NULL;
        for (Class cls = object_getClass(appController); cls && !property; cls = class_getSuperclass(cls)) {
            property = class_getProperty(cls, kNames[n]);
        }
        if (!property) continue;

        NSString *getterName = [NSString stringWithUTF8String:kNames[n]];
        NSString *setterName = [NSString stringWithFormat:@"set%@%@:", [[getterName substringToIndex:1] uppercaseString], [getterName substringFromIndex:1]];
        char *customGetter = property_copyAttributeValue(property, "G");
        char *customSetter = property_copyAttributeValue(property, "S");
        if (customGetter) getterName = [NSString stringWithUTF8String:customGetter];
        if (customSetter) setterName = [NSString stringWithUTF8String:customSetter];
        free(customGetter);
        free(customSetter);

        SEL setter = NSSelectorFromString(setterName);
        SEL getter = NSSelectorFromString(getterName);
        if (![appController respondsToSelector:setter]) continue;

        ((void (*)(id, SEL, BOOL))objc_msgSend)(appController, setter, paused);
        BOOL readBack = paused;
        if ([appController respondsToSelector:getter]) {
            readBack = ((BOOL (*)(id, SEL))objc_msgSend)(appController, getter);
        }
        ZLog(@"[ZSScripts] %s.%@ called with %@, reads back %@", class_getName(object_getClass(appController)), setterName, paused ? @"YES" : @"NO", readBack ? @"YES" : @"NO");
        return YES;
    }
    return NO;
}

BOOL zs_set_unity_app_paused(BOOL paused) {
    id appController = [[UIApplication sharedApplication] delegate];
    if (!appController) return NO;
    if (zs_set_paused_via_property(appController, paused)) return YES;
    id owner = nil;
    Ivar ivar = NULL;
    if (!zs_locate_paused_flag(appController, &owner, &ivar)) {
        static BOOL loggedLayout;
        ZLog(@"[ZSScripts] Paused ivar not found on %s", class_getName(object_getClass(appController)));
        if (!loggedLayout) {
            loggedLayout = YES;
            zs_log_ivar_names(appController, @"app controller");
        }
        return NO;
    }
    BOOL *slot = (BOOL *)((uint8_t *)(__bridge void *)owner + ivar_getOffset(ivar));
    *slot = paused;
    ZLog(@"[ZSScripts] %s.%s set to %@", class_getName(object_getClass(owner)), ivar_getName(ivar), paused ? @"YES" : @"NO");
    return YES;
}

static const int32_t kSceneStateBattle = 1;

static BOOL zs_try_read_is_in_battle(BOOL *outIsBattle) {
    int32_t sceneState = 0;
    if (!ZSGlobalScene_Current(&sceneState)) return NO;
    *outIsBattle = (sceneState == kSceneStateBattle);
    return YES;
}

static const double kParticleApplyDelaySeconds = 2.0;

static void zs_schedule_particle_apply(void) {
    static uint64_t generation;
    uint64_t token = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kParticleApplyDelaySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != generation) return;
        zs_apply_persisted_particle_settings();
    });
}

@interface FPS120Controller ()
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, assign) BOOL reducedPanelFPS;
@property (nonatomic, strong) NSTimer *battleStatePollTimer;
@property (nonatomic, strong) NSTimer *fpsPollTimer;
- (void)applyMenuFPS:(NSInteger)fps;
- (void)applyCombatFPS:(NSInteger)fps;
- (NSInteger)panelFPS;
@end

@implementation FPS120Controller

+ (instancetype)shared {
    static FPS120Controller *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        zs_ensure_settings_loaded_from_disk();
        instance = [FPS120Controller new];
        instance.menuFPS = g_menuFPS;
        instance.combatFPS = g_combatFPS;
        instance.targetFPS = instance.menuFPS;
    });
    return instance;
}

- (BOOL)start {
    if (!self.battleStatePollTimer) {
        self.battleStatePollTimer = [NSTimer timerWithTimeInterval:0.5
                                                              target:self
                                                            selector:@selector(battleStatePoll)
                                                            userInfo:nil
                                                             repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.battleStatePollTimer forMode:NSRunLoopCommonModes];
    }

    if (!self.fpsPollTimer) {
        self.fpsPollTimer = [NSTimer timerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(fpsPollTick)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.fpsPollTimer forMode:NSRunLoopCommonModes];
    }

    return zs_set_application_target_fps((int32_t)self.targetFPS);
}

- (void)fpsPollTick {
    CADisplayLink *link = zs_refresh_unity_display_link();
    if (!link) return;

    NSInteger expected;
    if (self.panelOpen) {
        expected = [self panelFPS];
    } else {
        int32_t sceneState = 0;
        if (!ZSGlobalScene_Current(&sceneState)) return;
        BOOL isBattle = (sceneState == kSceneStateBattle);
        expected = isBattle ? self.combatFPS : self.menuFPS;
    }

    NSInteger current = link.preferredFramesPerSecond;
    if (current == expected) return;

    ZLog(@"[ZSScripts] preferredFramesPerSecond is %ld, expected %ld - reapplying settings", (long)current, (long)expected);
    self.targetFPS = expected;
    zs_set_application_target_fps((int32_t)expected);
    zs_reapply_all_settings_except_experimental();
    zs_schedule_font_apply();
}

- (void)battleStatePoll {
    static int32_t lastParticleSceneState = -1;
    BOOL scheduleParticles = NO;
    int32_t currentSceneState = -1;
    if (ZSGlobalScene_Current(&currentSceneState) && currentSceneState != lastParticleSceneState) {
        lastParticleSceneState = currentSceneState;
        scheduleParticles = YES;
    }

    BOOL isBattle = NO;
    BOOL haveBattleState = zs_try_read_is_in_battle(&isBattle);
    BOOL wasInBattle = self.isInBattle;
    if (haveBattleState) self.isInBattle = isBattle;
    if (haveBattleState) zs_apply_render_scale_for_battle_state(isBattle, NO);

    if (haveBattleState && isBattle && !wasInBattle) scheduleParticles = YES;
    if (scheduleParticles) zs_schedule_particle_apply();
    if (scheduleParticles) zs_schedule_font_apply();

    if (haveBattleState && wasInBattle && !isBattle && g_autoClearPortraitCacheOnBattleExit) {
        zs_clear_guide_portrait_cache();
    }

    if (!haveBattleState) return;

    if (self.panelOpen) {
        NSInteger panelFPS = [self panelFPS];
        if (self.targetFPS != panelFPS) {
            self.targetFPS = panelFPS;
            zs_set_application_target_fps((int32_t)panelFPS);
        }
        return;
    }

    if (isBattle) {
        [self applyTargetFPSIfNeeded:self.combatFPS];
    } else {
        [self applyTargetFPSIfNeeded:self.menuFPS];
    }
}

- (void)applyTargetFPSIfNeeded:(NSInteger)desired {
    if (self.targetFPS != desired) {
        self.targetFPS = desired;
        zs_set_application_target_fps((int32_t)desired);
    }
}

- (void)applyMenuFPS:(NSInteger)fps {
    self.menuFPS = fps;
    if (!self.panelOpen && !self.isInBattle) {
        self.targetFPS = fps;
        zs_set_application_target_fps((int32_t)fps);
    }
}

- (void)setManualMenuFPS:(NSInteger)fps {
    self.manualOverrideActiveMenu = YES;
    [self applyMenuFPS:fps];
}

- (void)clearManualMenuOverride {
    self.manualOverrideActiveMenu = NO;
    if (!self.isInBattle) {
        [self applyTargetFPSIfNeeded:self.menuFPS];
    }
}

- (void)applyCombatFPS:(NSInteger)fps {
    self.combatFPS = fps;
    if (!self.panelOpen && self.isInBattle) {
        self.targetFPS = fps;
        zs_set_application_target_fps((int32_t)fps);
    }
}

- (void)setManualCombatFPS:(NSInteger)fps {
    self.manualOverrideActiveCombat = YES;
    [self applyCombatFPS:fps];
}

- (void)clearManualCombatOverride {
    self.manualOverrideActiveCombat = NO;
    if (!self.panelOpen && self.isInBattle) {
        [self applyTargetFPSIfNeeded:self.combatFPS];
    }
}

- (void)setPanelOpen:(BOOL)open {
    _panelOpen = open;
    if (open) {
        NSInteger panelFPS = [self panelFPS];
        self.targetFPS = panelFPS;
        zs_set_application_target_fps((int32_t)panelFPS);
        return;
    }

    NSInteger desired = self.isInBattle ? self.combatFPS : self.menuFPS;
    self.targetFPS = desired;
    zs_set_application_target_fps((int32_t)desired);

    [self battleStatePoll];
}

- (void)setReducedPanelFPS:(BOOL)reduced {
    if (_reducedPanelFPS == reduced) return;
    _reducedPanelFPS = reduced;
    if (!self.panelOpen) return;
    NSInteger fps = [self panelFPS];
    self.targetFPS = fps;
    zs_set_application_target_fps((int32_t)fps);
}

- (NSInteger)panelFPS {
    return self.reducedPanelFPS ? 10 : 30;
}

- (void)dealloc {
    [self.battleStatePollTimer invalidate];
    [self.fpsPollTimer invalidate];
}

@end

#pragma mark - Apply-everything entry points

static void zs_apply_persisted_particle_settings(void) {
    zs_apply_particle_key(@"ParticleAlignment");
    zs_apply_particle_key(@"ParticleRenderMode");
    zs_apply_particle_key(@"ParticleSortMode");
    zs_apply_particle_key(@"ParticleMinSize");
    zs_apply_particle_key(@"ParticleMaxSize");
    zs_apply_particle_key(@"ParticleFreeformStretching");
    zs_apply_particle_max_particles_cap();
}

static void zs_reapply_all_settings_internal(BOOL includeExperimental) {
    ZSCustomGreeting_HotFieldInvalidate();
    ZSUID_HotFieldInvalidate();

    [[FPS120Controller shared] applyMenuFPS:g_menuFPS];
    [[FPS120Controller shared] applyCombatFPS:g_combatFPS];

    zs_set_texture_mip_limit(g_textureMip);
    zs_apply_render_scale_for_battle_state([FPS120Controller shared].isInBattle, YES);
    zs_urp_set_int("set_msaaSampleCount", zs_step_value(kMSAASteps, 4, g_msaaIndex));
    zs_urp_set_bool("set_supportsHDR", g_hdrOn);

    zs_apply_motion_blur();
    zs_apply_tonemapping();
    for (NSString *name in g_urpActive) {
        if (g_urpActive[name].boolValue) zs_apply_urp_post_effect(name);
    }

    zs_camera_data_set_int("set_antialiasing", zs_step_value(kAAModeSteps, 4, g_aaModeIndex));
    zs_camera_data_set_int("set_antialiasingQuality", zs_step_value(kAAQualitySteps, 3, g_aaQualityIndex));
    zs_camera_data_set_bool("set_dithering", g_ditheringOn);

    if (includeExperimental) {
        zs_exp_apply_key(@"RenderTextureMemorylessMode");
    }

    zs_apply_persisted_particle_settings();
}

void zs_reapply_all_settings(void) {
    zs_reapply_all_settings_internal(YES);
}

static void zs_reapply_all_settings_except_experimental(void) {
    zs_reapply_all_settings_internal(NO);
}

void zs_reapply_post_fx(void) {
    zs_apply_motion_blur();
    zs_apply_tonemapping();

    for (NSString *name in g_urpActive) {
        if (g_urpActive[name].boolValue) zs_apply_urp_post_effect(name);
    }
}

#pragma mark - FPS120Controller implementation

#pragma mark - Unity view discovery

static UIView *find_unity_view(id appController) {
    UIView *found = nil;
    Class cls = [appController class];

    while (cls && !found) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && strstr(type, "UnityView")) {
                id value = object_getIvar(appController, ivars[i]);
                if ([value isKindOfClass:[UIView class]]) {
                    found = (UIView *)value;
                    break;
                }
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    return found;
}

static UIView *gZSUnityView;

UIView *zs_unity_view(void) {
    if (gZSUnityView) return gZSUnityView;
    id appController = [[UIApplication sharedApplication] delegate];
    if (!appController) return nil;
    UIView *found = find_unity_view(appController);
    if (found) gZSUnityView = found;
    return found;
}

#pragma mark - Startup

static void *background_worker(void *arg) {
    (void)arg;

    __block BOOL fpsReady = NO;

    while (!fpsReady) {
        dispatch_sync(dispatch_get_main_queue(), ^{

            fpsReady = [[FPS120Controller shared] start];
        });
        if (!fpsReady) usleep(200 * 1000);
    }
    ZLog(@"FPS120Controller started - scene-state poll and target frame rate write are live");

    __block BOOL mainSceneReady = NO;
    while (!mainSceneReady) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            int32_t sceneState = -1;
            if (ZSGlobalScene_Current(&sceneState) && sceneState == kZSFontSceneStateMain) {
                mainSceneReady = YES;
            }
        });
        if (!mainSceneReady) usleep(200 * 1000);
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        zs_schedule_font_apply();
    });

    return NULL;
}

__attribute__((constructor))
static void fps120_init(void) {
    ZLog(@"dylib loaded - starting background worker");

    zs_ensure_settings_loaded_from_disk();

    pthread_t t;
    pthread_create(&t, NULL, background_worker, NULL);
    pthread_detach(t);
}

#pragma mark - IL2CPP helpers

static NSMutableDictionary<NSString *, NSValue *> *g_mtClassCache;
static NSMutableDictionary<NSString *, NSValue *> *g_mtMethodCache;

void *mt_class(const char *ns, const char *name, const char *assemblySubstring) {
    if (!g_mtClassCache) g_mtClassCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%s.%s@%s", ns ?: "", name ?: "", assemblySubstring ?: ""];
    NSValue *cached = g_mtClassCache[key];
    if (cached) return cached.pointerValue;
    void *klass = [IL2CppBridge classNamed:name inNamespace:ns assemblyContains:assemblySubstring];
    if (klass) g_mtClassCache[key] = [NSValue valueWithPointer:klass];
    return klass;
}

const void *mt_method(void *klass, const char *name, int argCount) {
    if (!klass) return NULL;
    if (!g_mtMethodCache) g_mtMethodCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p.%s/%d", klass, name ?: "", argCount];
    NSValue *cached = g_mtMethodCache[key];
    if (cached) return cached.pointerValue;
    const void *method = [IL2CppBridge methodOnClass:klass name:name argCount:argCount];
    if (method) g_mtMethodCache[key] = [NSValue valueWithPointer:(void *)method];
    return method;
}

static BOOL mt_call_static_bool(const char *ns, const char *klassName, const char *assembly, const char *setter, BOOL value) {
    void *klass = mt_class(ns, klassName, assembly);
    const void *method = mt_method(klass, setter, 1);
    if (!method) return NO;
    void *args[1] = { &value };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:method onInstance:NULL args:args outException:&exc];
    return exc == NULL;
}

static BOOL mt_call_static_int(const char *ns, const char *klassName, const char *assembly, const char *setter, int32_t value) {
    void *klass = mt_class(ns, klassName, assembly);
    const void *method = mt_method(klass, setter, 1);
    if (!method) return NO;
    void *args[1] = { &value };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:method onInstance:NULL args:args outException:&exc];
    return exc == NULL;
}

static BOOL mt_call_static_float(const char *ns, const char *klassName, const char *assembly, const char *setter, float value) {
    void *klass = mt_class(ns, klassName, assembly);
    const void *method = mt_method(klass, setter, 1);
    if (!method) return NO;
    void *args[1] = { &value };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:method onInstance:NULL args:args outException:&exc];
    return exc == NULL;
}

static BOOL mt_call_instance_bool(void *instance, const char *setter, BOOL value) {
    if (!instance) return NO;
    const void *method = mt_method([IL2CppBridge classOfInstance:instance], setter, 1);
    if (!method) return NO;
    void *args[1] = { &value };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:method onInstance:instance args:args outException:&exc];
    return exc == NULL;
}

static BOOL mt_call_instance_int(void *instance, const char *setter, int32_t value) {
    if (!instance) return NO;
    const void *method = mt_method([IL2CppBridge classOfInstance:instance], setter, 1);
    if (!method) return NO;
    void *args[1] = { &value };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:method onInstance:instance args:args outException:&exc];
    return exc == NULL;
}

static BOOL mt_call_instance_float(void *instance, const char *setter, float value) {
    if (!instance) return NO;
    const void *method = mt_method([IL2CppBridge classOfInstance:instance], setter, 1);
    if (!method) return NO;
    void *args[1] = { &value };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:method onInstance:instance args:args outException:&exc];
    return exc == NULL;
}

static BOOL mt_get_instance_int(void *instance, const char *getter, int32_t *outValue) {
    if (!instance || !outValue) return NO;
    const void *method = mt_method([IL2CppBridge classOfInstance:instance], getter, 0);
    if (!method) return NO;
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:method onInstance:instance args:NULL outException:&exc];
    if (exc || !boxed) return NO;
    *outValue = *(int32_t *)((uint8_t *)boxed + 0x10);
    return YES;
}

static void *mt_get_static_instance(const char *ns, const char *klassName, const char *assembly, const char *getter) {
    void *klass = mt_class(ns, klassName, assembly);
    const void *method = mt_method(klass, getter, 0);
    if (!method) return NULL;
    void *exc = NULL;
    void *result = [IL2CppBridge invokeMethod:method onInstance:NULL args:NULL outException:&exc];
    return exc ? NULL : result;
}

static BOOL mt_get_static_int(const char *ns, const char *klassName, const char *assembly, const char *getter, int32_t *outValue) {
    if (!outValue) return NO;
    void *klass = mt_class(ns, klassName, assembly);
    const void *method = mt_method(klass, getter, 0);
    if (!method) return NO;
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:method onInstance:NULL args:NULL outException:&exc];
    if (exc || !boxed) return NO;
    *outValue = *(int32_t *)((uint8_t *)boxed + 0x10);
    return YES;
}

static BOOL mt_call_static_object_int64(const char *ns, const char *klassName, const char *assembly, const char *methodName, void *objArg, int64_t *outValue) {
    if (!outValue) return NO;
    void *klass = mt_class(ns, klassName, assembly);
    const void *method = mt_method(klass, methodName, 1);
    if (!method) return NO;
    void *args[1] = { objArg };
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:method onInstance:NULL args:args outException:&exc];
    if (exc || !boxed) return NO;
    *outValue = *(int64_t *)((uint8_t *)boxed + 0x10);
    return YES;
}

static BOOL mt_call_static_int64(const char *ns, const char *klassName, const char *assembly, const char *methodName, int64_t *outValue) {
    if (!outValue) return NO;
    void *klass = mt_class(ns, klassName, assembly);
    const void *method = mt_method(klass, methodName, 0);
    if (!method) return NO;
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:method onInstance:NULL args:NULL outException:&exc];
    if (exc || !boxed) return NO;
    *outValue = *(int64_t *)((uint8_t *)boxed + 0x10);
    return YES;
}

#pragma mark - Experimental state

#define EXP_DEFAULTS(X) \
X(int32_t, PixelLightCount, 4, NO) \
X(float, LODBias, 1.0f, NO) \
X(BOOL, LODCrossFade, NO, NO) \
X(int32_t, VSyncCount, 0, NO) \
X(int32_t, QualityAA, 1, NO) \
X(BOOL, CameraHDR, YES, NO) \
X(BOOL, CameraMSAA, YES, NO) \
X(BOOL, DynamicResolution, NO, NO) \
X(BOOL, OcclusionCulling, YES, NO) \
X(BOOL, DepthTexture, NO, NO) \
X(BOOL, OpaqueTexture, NO, NO) \
X(BOOL, RenderShadows, YES, NO) \
X(BOOL, PostProcessing, YES, NO) \
X(int32_t, AntialiasingMode, 3, NO) \
X(int32_t, AntialiasingQuality, 2, NO) \
X(BOOL, CameraDithering, NO, NO) \
X(int32_t, CameraRequiresDepthOption, 0, NO) \
X(int32_t, CameraRequiresColorOption, 0, NO) \
X(int32_t, CameraRenderType, 0, NO) \
X(BOOL, CameraRequiresDepthTexture, NO, NO) \
X(BOOL, CameraRequiresColorTexture, NO, NO) \
X(BOOL, CameraResetHistory, NO, NO) \
X(BOOL, CameraStopNaN, NO, NO) \
X(BOOL, CameraAllowXR, YES, NO) \
X(BOOL, CameraScreenCoordOverride, NO, NO) \
X(BOOL, CameraHDROutput, NO, NO) \
X(int32_t, RenderTextureMemorylessMode, 0, YES) \
X(int32_t, UpscalingFilter, 0, NO) \
X(BOOL, FSROverride, NO, NO) \
X(float, FSRSharpness, 0.5f, NO) \
X(BOOL, URPHDR, YES, NO) \
X(int32_t, URPMSAA, 1, NO) \
X(int32_t, MainLightMode, 1, NO) \
X(BOOL, MainLightShadows, YES, NO) \
X(int32_t, MainShadowResolution, 2048, NO) \
X(int32_t, AdditionalLightMode, 1, NO) \
X(int32_t, MaxAdditionalLights, 4, NO) \
X(BOOL, AdditionalLightShadows, NO, NO) \
X(int32_t, AdditionalShadowResolution, 512, NO) \
X(BOOL, ReflectionProbeBlending, YES, NO) \
X(BOOL, ReflectionProbeBoxProjection, NO, NO) \
X(BOOL, ReflectionProbeAtlas, YES, NO) \
X(int32_t, ShEvalMode, 0, NO) \
X(int32_t, LightProbeSystem, 0, NO) \
X(int32_t, ProbeVolumeMemoryBudget, 0, NO) \
X(int32_t, ProbeVolumeBlendingMemoryBudget, 0, NO) \
X(BOOL, ProbeVolumeStreaming, NO, NO) \
X(BOOL, ProbeVolumeGPUStreaming, NO, NO) \
X(BOOL, ProbeVolumeDiskStreaming, NO, NO) \
X(BOOL, ProbeVolumeScenarios, NO, NO) \
X(BOOL, ProbeVolumeScenarioBlending, NO, NO) \
X(int32_t, ProbeVolumeSHBands, 0, NO) \
X(int32_t, AdditionalShadowTierLow, 256, NO) \
X(int32_t, AdditionalShadowTierMedium, 512, NO) \
X(int32_t, AdditionalShadowTierHigh, 1024, NO) \
X(int32_t, SoftShadowQuality, 0, NO) \
X(float, ShadowDistance, 50.0f, NO) \
X(int32_t, ShadowCascades, 2, NO) \
X(float, CascadeBorder, 0.8f, NO) \
X(float, ShadowDepthBias, 1.5f, NO) \
X(float, ShadowNormalBias, 1.0f, NO) \
X(BOOL, SoftShadows, YES, NO) \
X(BOOL, DynamicBatching, YES, NO) \
X(BOOL, SRPBatcher, YES, NO) \
X(int32_t, ColorGradingMode, 0, NO) \
X(int32_t, ColorGradingLUTSize, 32, NO) \
X(BOOL, AdaptivePerformance, NO, NO) \
X(int32_t, GPUResidentDrawerMode, 0, NO) \
X(BOOL, GPUResidentOcclusion, NO, NO) \
X(float, SmallMeshScreenPercentage, 0.5f, NO) \
X(int32_t, IntermediateTextureMode, 0, NO) \
X(int32_t, StoreActionsOptimization, 0, NO) \
X(int32_t, ShadowCascadeOption, 2, NO) \
X(float, Cascade2Split, 0.25f, NO) \
X(float, Cascade3SplitX, 0.1f, NO) \
X(float, Cascade3SplitY, 0.3f, NO) \
X(float, Cascade4SplitX, 0.067f, NO) \
X(float, Cascade4SplitY, 0.2f, NO) \
X(float, Cascade4SplitZ, 0.467f, NO) \
X(BOOL, ConservativeEnclosingSphere, YES, NO) \
X(int32_t, NumIterationsEnclosingSphere, 64, NO) \
X(int32_t, ShaderVariantLogLevel, 0, NO) \
X(BOOL, GraphicsSRPBatching, YES, NO) \
X(BOOL, LightsUseLinearIntensity, YES, NO) \
X(BOOL, LightsUseColorTemperature, YES, NO) \
X(float, APMaxShadowDistanceMultiplier, 1.0f, NO) \
X(float, APShadowmapResolutionMultiplier, 1.0f, NO) \
X(float, APRenderScaleMultiplier, 1.0f, YES) \
X(float, APDecalsDrawDistance, 100.0f, NO) \
X(int32_t, APShadowCascadesBias, 0, NO) \
X(int32_t, APShadowQualityBias, 0, NO) \
X(float, APLutBias, 1.0f, NO) \
X(int32_t, APAntiAliasingQualityBias, 0, NO) \
X(BOOL, APSkipDynamicBatching, NO, NO) \
X(BOOL, APSkipFrontToBackSorting, NO, NO) \
X(BOOL, APSkipTransparentObjects, NO, NO) \
X(int32_t, AnimatorCullingMode, 0, NO) \
X(int32_t, AnimatorUpdateMode, 0, NO) \
X(BOOL, AnimatorApplyRootMotion, NO, NO) \
X(BOOL, AnimatorLinearVelocityBlending, NO, NO) \
X(BOOL, AnimatorAnimatePhysics, NO, NO) \
X(BOOL, AnimatorConstantClipSamplingOptimization, YES, NO) \
X(BOOL, AnimatorStabilizeFeet, NO, NO) \
X(float, AnimatorSpeed, 1.0f, NO) \
X(BOOL, AnimatorLogWarnings, YES, NO) \
X(BOOL, AnimatorFireEvents, YES, NO) \
X(BOOL, AnimatorWriteDefaultValuesOnDisable, YES, NO) \
X(BOOL, AnimatorKeepStateOnDisable, YES, NO) \
X(BOOL, AnimatorKeepControllerStateOnDisable, YES, NO) \
X(BOOL, AutoUnloadOnMemoryWarning, NO, YES) \
X(BOOL, AutoClearPortraitCacheOnBattleExit, NO, YES) \
X(BOOL, DebugLogMemoryUsageTier, NO, YES) \
X(BOOL, AutoUnloadOnElevatedMemoryUsage, NO, YES) \
X(BOOL, BurstCompilation, YES, NO) \
X(BOOL, BurstSafetyChecks, NO, NO) \
X(int32_t, RigidbodySolverIterations, 6, NO) \
X(int32_t, RigidbodySolverVelocityIterations, 1, NO) \
X(float, RigidbodySleepThreshold, 0.005f, NO) \
X(float, RigidbodyMaxAngularVelocity, 7.0f, NO) \
X(float, RigidbodyMaxLinearVelocity, 0.0f, NO) \
X(int32_t, RigidbodyInterpolation, 0, NO) \
X(BOOL, RigidbodyDetectCollisions, YES, NO) \
X(float, Rigidbody2DLinearDamping, 0.0f, NO) \
X(float, Rigidbody2DAngularDamping, 0.05f, NO) \
X(float, Rigidbody2DGravityScale, 1.0f, NO) \
X(int32_t, Rigidbody2DInterpolation, 0, NO) \
X(int32_t, Rigidbody2DSleepMode, 1, NO) \
X(int32_t, Rigidbody2DCollisionDetectionMode, 0, NO) \
X(BOOL, AdaptivePhysics, YES, NO)

#define DECL(type, name, def, persist) type g_exp##name = def;
EXP_DEFAULTS(DECL)
#undef DECL

static BOOL exp_bool(NSDictionary *d, NSString *key, BOOL def) { NSNumber *n = d[key]; return [n isKindOfClass:NSNumber.class] ? n.boolValue : def; }
static int32_t exp_int(NSDictionary *d, NSString *key, int32_t def) { NSNumber *n = d[key]; return [n isKindOfClass:NSNumber.class] ? n.intValue : def; }
static float exp_float(NSDictionary *d, NSString *key, float def) { NSNumber *n = d[key]; return [n isKindOfClass:NSNumber.class] ? n.floatValue : def; }

#define PARTICLE_DEFAULTS(X) \
X(BOOL, ParticleGPUInstancing, YES, NO) \
X(int32_t, ParticleAlignment, kZSParticleAlignmentPreserveOriginal, YES) \
X(int32_t, ParticleRenderMode, kZSParticleRenderModePreserveOriginal, YES) \
X(int32_t, ParticleMeshDistribution, 0, NO) \
X(int32_t, ParticleSortMode, 0, YES) \
X(float, ParticleLengthScale, 5.0f, NO) \
X(float, ParticleVelocityScale, 1.0f, NO) \
X(float, ParticleCameraVelocityScale, 1.0f, NO) \
X(float, ParticleNormalDirection, 1.0f, NO) \
X(float, ParticleShadowBias, 0.5f, NO) \
X(float, ParticleSortingFudge, 0.0f, NO) \
X(float, ParticleMinSize, 0.0f, YES) \
X(float, ParticleMaxSize, 0.5f, YES) \
X(BOOL, ParticleAllowRoll, YES, NO) \
X(BOOL, ParticleFreeformStretching, NO, YES) \
X(BOOL, ParticleRotateWithStretchDirection, NO, NO) \
X(BOOL, ParticleApplyActiveColorSpace, YES, NO) \
X(BOOL, ParticleMaxParticlesCapEnabled, NO, YES) \
X(int32_t, ParticleMaxParticlesCap, 300, YES)

#define PARTICLE_DECL(type, name, def, persist) type g_exp##name = def;
PARTICLE_DEFAULTS(PARTICLE_DECL)
#undef PARTICLE_DECL

void zs_particles_reset_defaults(void) {
#define PARTICLE_RESET(type, name, def, persist) g_exp##name = def;
    PARTICLE_DEFAULTS(PARTICLE_RESET)
#undef PARTICLE_RESET
}

void zs_particles_load_from_dictionary(NSDictionary *particles) {
    NSDictionary *d = [particles isKindOfClass:NSDictionary.class] ? particles : nil;
#define PARTICLE_LOAD(type, name, def, persist) do { \
    if (!(persist) || !d) { g_exp##name = def; } \
    else if (strcmp(#type, "BOOL") == 0) g_exp##name = exp_bool(d, @#name, def); \
    else if (strcmp(#type, "int32_t") == 0) g_exp##name = exp_int(d, @#name, def); \
    else g_exp##name = exp_float(d, @#name, def); \
} while(0);
    PARTICLE_DEFAULTS(PARTICLE_LOAD)
#undef PARTICLE_LOAD
}

NSDictionary *zs_particles_settings_dictionary(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
#define PARTICLE_SAVE(type, name, def, persist) if (persist) d[@#name] = @(g_exp##name);
    PARTICLE_DEFAULTS(PARTICLE_SAVE)
#undef PARTICLE_SAVE
    return d;
}

BOOL zs_particle_get_bool(NSString *key) {
    if (!key) return NO;
#define PARTICLE_GETB(type, name, def, persist) if (strcmp(#type, "BOOL") == 0 && [key isEqualToString:@#name]) return g_exp##name;
    PARTICLE_DEFAULTS(PARTICLE_GETB)
#undef PARTICLE_GETB
    return NO;
}

float zs_particle_get_number(NSString *key) {
    if (!key) return 0.0f;
#define PARTICLE_GETN(type, name, def, persist) if (strcmp(#type, "BOOL") != 0 && [key isEqualToString:@#name]) return (float)g_exp##name;
    PARTICLE_DEFAULTS(PARTICLE_GETN)
#undef PARTICLE_GETN
    return 0.0f;
}

float zs_particle_get_default_number(NSString *key) {
    if (!key) return 0.0f;
#define PARTICLE_GETDN(type, name, def, persist) if (strcmp(#type, "BOOL") != 0 && [key isEqualToString:@#name]) return (float)(def);
    PARTICLE_DEFAULTS(PARTICLE_GETDN)
#undef PARTICLE_GETDN
    return 0.0f;
}

void zs_exp_reset_defaults(void) {
#define RESET(type, name, def, persist) g_exp##name = def;
    EXP_DEFAULTS(RESET)
#undef RESET
}

void zs_exp_load_from_dictionary(NSDictionary *experimental) {
    NSDictionary *d = [experimental isKindOfClass:NSDictionary.class] ? experimental : nil;
#define LOAD(type, name, def, persist) do { \
    if (!(persist) || !d) { g_exp##name = def; } \
    else if (strcmp(#type, "BOOL") == 0) g_exp##name = exp_bool(d, @#name, def); \
    else if (strcmp(#type, "int32_t") == 0) g_exp##name = exp_int(d, @#name, def); \
    else g_exp##name = exp_float(d, @#name, def); \
} while(0);
    EXP_DEFAULTS(LOAD)
#undef LOAD
}

NSDictionary *zs_exp_settings_dictionary(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
#define SAVE(type, name, def, persist) if (persist) d[@#name] = @(g_exp##name);
    EXP_DEFAULTS(SAVE)
#undef SAVE
    return d;
}

BOOL zs_exp_get_bool(NSString *key) {
    if (!key) return NO;
#define GETB(type, name, def, persist) if (strcmp(#type, "BOOL") == 0 && [key isEqualToString:@#name]) return g_exp##name;
    EXP_DEFAULTS(GETB)
#undef GETB
    if ([key hasPrefix:@"Particle"]) return zs_particle_get_bool(key);
    return NO;
}

float zs_exp_get_number(NSString *key) {
    if (!key) return 0.0f;
#define GETN(type, name, def, persist) if (strcmp(#type, "BOOL") != 0 && [key isEqualToString:@#name]) return (float)g_exp##name;
    EXP_DEFAULTS(GETN)
#undef GETN
    if ([key hasPrefix:@"Particle"]) return zs_particle_get_number(key);
    return 0.0f;
}

float zs_exp_get_default_number(NSString *key) {
    if (!key) return 0.0f;
#define GETDN(type, name, def, persist) if (strcmp(#type, "BOOL") != 0 && [key isEqualToString:@#name]) return (float)(def);
    EXP_DEFAULTS(GETDN)
#undef GETDN
    if ([key hasPrefix:@"Particle"]) return zs_particle_get_default_number(key);
    return 0.0f;
}

#pragma mark - Existing cache helpers

static BOOL g_memoryCleanupInFlight;
static const NSTimeInterval kMemoryCleanupGCDelay = 2.0;
static const NSTimeInterval kMemoryCleanupSecondGCDelay = 1.0;

static void zs_run_gc_collect(void) {
    void *gc = mt_class("System", "GC", "mscorlib");
    const void *collect = mt_method(gc, "Collect", 0);
    if (!collect) return;
    void *exc = NULL;
    [IL2CppBridge invokeMethod:collect onInstance:NULL args:NULL outException:&exc];
}

static void zs_invoke_static_noargs(const char *ns, const char *klassName, const char *assembly, const char *methodName) {
    void *klass = mt_class(ns, klassName, assembly);
    const void *method = mt_method(klass, methodName, 0);
    if (!method) return;
    void *exc = NULL;
    [IL2CppBridge invokeMethod:method onInstance:NULL args:NULL outException:&exc];
}

static void zs_invoke_singleton_noargs(const char *ns, const char *klassName, const char *assembly, const char *methodName) {
    void *instance = mt_get_static_instance(ns, klassName, assembly, "get_Instance");
    if (!instance) return;
    const void *method = mt_method([IL2CppBridge classOfInstance:instance], methodName, 0);
    if (!method) return;
    void *exc = NULL;
    [IL2CppBridge invokeMethod:method onInstance:instance args:NULL outException:&exc];
}

static void zs_free_battle_effect_pool(void) {
    BOOL isBattle = NO;
    if (!zs_try_read_is_in_battle(&isBattle) || !isBattle) return;
    void *managerKlass = mt_class("", "BattleEffectManager", "Assembly-CSharp");
    if (!managerKlass) return;
    const void *getter = mt_method(managerKlass, "get_Instance", 0);
    if (!getter) return;
    void *exc = NULL;
    void *manager = [IL2CppBridge invokeMethod:getter onInstance:NULL args:NULL outException:&exc];
    if (exc || !manager) return;
    int32_t off = [IL2CppBridge fieldOffsetOnClass:managerKlass name:"EffectPool"];
    if (off < 0) return;
    void *pool = *(void **)((uint8_t *)manager + off);
    if (!pool) return;
    const void *freeAll = mt_method([IL2CppBridge classOfInstance:pool], "FreeAll", 0);
    if (!freeAll) return;
    exc = NULL;
    [IL2CppBridge invokeMethod:freeAll onInstance:pool args:NULL outException:&exc];
}

static void zs_release_idle_runtime_caches(void) {
    zs_invoke_singleton_noargs("Addressable", "AsyncInstancePool", "Assembly-CSharp", "ReleaseAllIdle");
    zs_invoke_singleton_noargs("Addressable", "AsyncAssetCache", "Assembly-CSharp", "ReleaseIdle");
    zs_invoke_static_noargs("RPGSystem", "RpgMemoryWatchAgent", "Assembly-CSharp", "ReleaseIdleCameraRenderTargets");
    zs_invoke_static_noargs("TMPro", "TMP_MaterialManager", "TextMeshPro", "CleanupFallbackMaterials");
    zs_invoke_static_noargs("PerformanceUtils", "IntStringCache", "Assembly-CSharp", "ClearCache");

    BOOL isBattle = NO;
    if (zs_try_read_is_in_battle(&isBattle) && !isBattle) {
        zs_clear_guide_portrait_cache();
    }

    zs_free_battle_effect_pool();
}

void zs_run_memory_cleanup(void (^completion)(BOOL ran)) {
    if (g_memoryCleanupInFlight) {
        if (completion) completion(NO);
        return;
    }
    g_memoryCleanupInFlight = YES;

    zs_release_idle_runtime_caches();

    void *resources = mt_class("UnityEngine", "Resources", "CoreModule");
    const void *unload = mt_method(resources, "UnloadUnusedAssets", 0);
    if (unload) {
        void *exc = NULL;
        [IL2CppBridge invokeMethod:unload onInstance:NULL args:NULL outException:&exc];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMemoryCleanupGCDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        zs_run_gc_collect();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMemoryCleanupSecondGCDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            zs_run_gc_collect();
            g_memoryCleanupInFlight = NO;
            if (completion) completion(YES);
        });
    });
}

void zs_unload_unused_assets_and_collect(void) {
    zs_run_memory_cleanup(nil);
}

static NSTimeInterval g_lastMemoryWarningResponseAt;
static BOOL g_memoryWarningObserverInstalled;
static const NSTimeInterval kMemoryWarningResponseCooldown = 5.0;
static void zs_install_memory_warning_observer_if_needed(void) {
    if (g_memoryWarningObserverInstalled) return;
    g_memoryWarningObserverInstalled = YES;
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (!g_expAutoUnloadOnMemoryWarning) return;
        NSTimeInterval now = CACurrentMediaTime();
        if (now - g_lastMemoryWarningResponseAt < kMemoryWarningResponseCooldown) return;
        g_lastMemoryWarningResponseAt = now;
        zs_unload_unused_assets_and_collect();
    }];
}
void zs_set_auto_unload_on_memory_warning(BOOL enabled) {
    g_expAutoUnloadOnMemoryWarning = enabled;
    if (enabled) zs_install_memory_warning_observer_if_needed();
}

#pragma mark - Application.memoryUsage poll

static int32_t g_lastMemoryUsageTier = -1;
static NSTimer *g_memoryUsagePollTimer;
static const NSTimeInterval kMemoryUsagePollInterval = 2.0;
static BOOL g_memoryUsageMethodConfirmedMissing = NO;

static void zs_poll_application_memory_usage(void) {
    if (!g_expDebugLogMemoryUsageTier && !g_expAutoUnloadOnElevatedMemoryUsage) return;
    if (g_memoryUsageMethodConfirmedMissing) return;

    int32_t tier = 0;
    if (!mt_get_static_int("UnityEngine", "Application", "CoreModule", "get_memoryUsage", &tier)) {
        g_memoryUsageMethodConfirmedMissing = YES;
        return;
    }
    if (tier == g_lastMemoryUsageTier) return;

    int32_t previousTier = g_lastMemoryUsageTier;
    g_lastMemoryUsageTier = tier;

    if (g_expDebugLogMemoryUsageTier) {
        ZLog(@"[ZSMemoryTweaks] Application.memoryUsage changed: %d -> %d", previousTier, tier);
    }

    if (g_expAutoUnloadOnElevatedMemoryUsage && tier != 0) {
        NSTimeInterval now = CACurrentMediaTime();
        if (now - g_lastMemoryWarningResponseAt < kMemoryWarningResponseCooldown) return;
        g_lastMemoryWarningResponseAt = now;
        ZLog(@"[ZSMemoryTweaks] Application.memoryUsage elevated (%d) - proactively unloading ahead of a hard OS memory warning", tier);
        zs_unload_unused_assets_and_collect();
    }
}

static void zs_install_memory_usage_poll_if_needed(void) {
    if (g_memoryUsagePollTimer) return;
    g_memoryUsagePollTimer = [NSTimer timerWithTimeInterval:kMemoryUsagePollInterval
                                                      repeats:YES
                                                        block:^(NSTimer *timer) {
        zs_poll_application_memory_usage();
    }];
    [NSRunLoop.mainRunLoop addTimer:g_memoryUsagePollTimer forMode:NSRunLoopCommonModes];
}

void zs_set_debug_log_memory_usage_tier(BOOL enabled) {
    g_expDebugLogMemoryUsageTier = enabled;
    if (enabled) zs_install_memory_usage_poll_if_needed();
}

void zs_set_auto_unload_on_elevated_memory_usage(BOOL enabled) {
    g_expAutoUnloadOnElevatedMemoryUsage = enabled;
    if (enabled) zs_install_memory_usage_poll_if_needed();
}

int32_t zs_last_observed_memory_usage_tier(void) {
    return g_lastMemoryUsageTier;
}

void *zs_resources_find_all_for_class(void *typeClass, NSUInteger *countOut) {
    if (countOut) *countOut = 0;
    if (!typeClass) return NULL;
    void *typeObj = [IL2CppBridge reflectionTypeForClass:typeClass];
    if (!typeObj) return NULL;
    void *resources = mt_class("UnityEngine", "Resources", "CoreModule");
    const void *find = mt_method(resources, "FindObjectsOfTypeAll", 1);
    if (!find) return NULL;
    void *args[1] = { typeObj }, *exc = NULL;
    void *array = [IL2CppBridge invokeMethod:find onInstance:NULL args:args outException:&exc];
    if (exc || !array) return NULL;
    uintptr_t count = *(uintptr_t *)((uint8_t *)array + 0x18);
    if (countOut) *countOut = (NSUInteger)count;
    return array;
}

void *zs_array_object_at(void *array, NSUInteger index) {
    if (!array) return NULL;
    return *(void **)((uint8_t *)array + 0x20 + index * sizeof(void *));
}

@implementation ZSMemoryUsageCategory
@end

@implementation ZSMemoryUsageGroup
@end

@interface ZSAssetScanResult : NSObject
@property (nonatomic, strong) NSMutableArray<ZSMemoryUsageCategory *> *assetCategories;
@property (nonatomic, strong) NSMutableArray<ZSMemoryUsageCategory *> *topAssets;
@property (nonatomic, strong) NSMutableArray<ZSMemoryUsageCategory *> *objectCounts;
@property (nonatomic, assign) int64_t assetTrackedBytes;
@property (nonatomic, assign) int64_t readableTextureBytes;
@property (nonatomic, assign) NSUInteger readableTextureCount;
@property (nonatomic, assign) int64_t readableMeshBytes;
@property (nonatomic, assign) NSUInteger readableMeshCount;
@property (nonatomic, assign) double scanMilliseconds;
@property (nonatomic, assign) CFTimeInterval scannedAt;
@property (nonatomic, assign) NSUInteger pageIndex;
@property (nonatomic, assign) BOOL hasNextPage;
@property (nonatomic, assign) NSUInteger pageCount;
@property (nonatomic, strong) NSMutableArray<ZSMemoryUsageCategory *> *kindOptions;
@property (nonatomic, copy) NSString *kindFilter;
@property (nonatomic, assign) int64_t estimatedGpuTextureBytes;
@end

@implementation ZSAssetScanResult
@end

typedef NS_ENUM(uint8_t, ZSAssetFamily) {
    ZSAssetFamilyGeneric = 0,
    ZSAssetFamilyTexture = 1,
    ZSAssetFamilyRenderTexture = 2,
    ZSAssetFamilyMesh = 3,
};

typedef struct {
    const char *ns;
    const char *klassName;
    const char *assembly;
    const char *displayName;
    BOOL tracked;
    ZSAssetFamily family;
} ZSMemoryUsageCategoryDescriptor;

static const ZSMemoryUsageCategoryDescriptor kZSMemoryUsageCategoryDescriptors[] = {
    {"UnityEngine", "Texture2D", "CoreModule", "Textures", YES, ZSAssetFamilyTexture},
    {"UnityEngine", "Cubemap", "CoreModule", "Cubemaps", YES, ZSAssetFamilyTexture},
    {"UnityEngine", "Texture2DArray", "CoreModule", "Texture Arrays", YES, ZSAssetFamilyTexture},
    {"UnityEngine", "Texture3D", "CoreModule", "3D Textures", YES, ZSAssetFamilyTexture},
    {"UnityEngine", "CubemapArray", "CoreModule", "Cubemap Arrays", YES, ZSAssetFamilyTexture},
    {"UnityEngine", "RenderTexture", "CoreModule", "Render Textures", YES, ZSAssetFamilyRenderTexture},
    {"UnityEngine", "Mesh", "CoreModule", "Meshes", YES, ZSAssetFamilyMesh},
    {"UnityEngine", "Material", "CoreModule", "Materials", YES, ZSAssetFamilyGeneric},
    {"UnityEngine", "Shader", "CoreModule", "Shaders", YES, ZSAssetFamilyGeneric},
    {"UnityEngine", "ComputeShader", "CoreModule", "Compute Shaders", YES, ZSAssetFamilyGeneric},
    {"UnityEngine", "TextAsset", "CoreModule", "Text Assets", YES, ZSAssetFamilyGeneric},
    {"UnityEngine", "AudioClip", "AudioModule", "Audio Clips", YES, ZSAssetFamilyGeneric},
    {"UnityEngine", "AnimationClip", "AnimationModule", "Animation Clips", YES, ZSAssetFamilyGeneric},
    {"UnityEngine", "Sprite", "CoreModule", "Sprites", YES, ZSAssetFamilyGeneric},
    {"UnityEngine", "Font", "TextRenderingModule", "Fonts", YES, ZSAssetFamilyGeneric},
    {"TMPro", "TMP_FontAsset", "Unity.TextMeshPro", "TMP Font Assets", YES, ZSAssetFamilyGeneric},
    {"UnityEngine.Video", "VideoClip", "VideoModule", "Video Clips", YES, ZSAssetFamilyGeneric},
    {"UnityEngine", "GameObject", "CoreModule", "GameObjects", NO, ZSAssetFamilyGeneric},
    {"UnityEngine", "ScriptableObject", "CoreModule", "ScriptableObjects", NO, ZSAssetFamilyGeneric},
    {"UnityEngine", "Renderer", "CoreModule", "Renderers", NO, ZSAssetFamilyGeneric},
    {"UnityEngine", "ParticleSystem", "ParticleSystemModule", "Particle Systems", NO, ZSAssetFamilyGeneric},
    {"UnityEngine", "Animator", "AnimationModule", "Animators", NO, ZSAssetFamilyGeneric},
    {"UnityEngine", "Canvas", "UIModule", "Canvases", NO, ZSAssetFamilyGeneric},
    {"UnityEngine", "Camera", "CoreModule", "Cameras", NO, ZSAssetFamilyGeneric},
    {"UnityEngine", "AudioSource", "AudioModule", "Audio Sources", NO, ZSAssetFamilyGeneric},
    {"UnityEngine", "AssetBundle", "AssetBundleModule", "Loaded Asset Bundles", NO, ZSAssetFamilyGeneric},
};

static const NSUInteger kZSTopAssetsPageSize = 20;
static const NSUInteger kZSCleanFileMaxRows = 10;

static NSUInteger g_topAssetsPage = 0;
static NSString *g_topAssetsKindFilter = nil;
static NSUInteger g_topAssetsKnownLastPage = NSUIntegerMax;
@class ZSMemoryScanSession;
static ZSMemoryScanSession *g_memoryScanSession;
static NSString *g_memoryScanStatus;

void zs_set_memory_top_assets_page(NSUInteger page) {
    if (g_topAssetsPage != page) g_memoryScanSession = nil;
    g_topAssetsPage = page;
}

void zs_set_memory_top_assets_kind_filter(NSString *kind) {
    NSString *normalized = kind.length > 0 ? [kind copy] : nil;
    if ((normalized == nil && g_topAssetsKindFilter == nil) || [normalized isEqualToString:g_topAssetsKindFilter]) return;
    g_topAssetsKindFilter = normalized;
    g_topAssetsPage = 0;
    g_topAssetsKnownLastPage = NSUIntegerMax;
    g_memoryScanSession = nil;
}

NSString *zs_memory_top_assets_kind_filter(void) {
    return g_topAssetsKindFilter;
}

NSUInteger zs_memory_top_assets_page(void) {
    return g_topAssetsPage;
}

static BOOL mt_get_instance_bool(void *instance, const char *getter, BOOL *outValue) {
    if (!instance || !outValue) return NO;
    const void *method = mt_method([IL2CppBridge classOfInstance:instance], getter, 0);
    if (!method) return NO;
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:method onInstance:instance args:NULL outException:&exc];
    if (exc || !boxed) return NO;
    *outValue = (*(uint8_t *)((uint8_t *)boxed + 0x10)) != 0;
    return YES;
}

static NSString *mt_get_instance_string(void *instance, const char *getter) {
    if (!instance) return nil;
    const void *method = mt_method([IL2CppBridge classOfInstance:instance], getter, 0);
    if (!method) return nil;
    void *exc = NULL;
    void *str = [IL2CppBridge invokeMethod:method onInstance:instance args:NULL outException:&exc];
    if (exc || !str) return nil;
    return [IL2CppBridge nsStringFromIl2CppString:str];
}

static NSString *zs_memory_bytes_string(int64_t bytes) {
    return [NSByteCountFormatter stringFromByteCount:(long long)MAX(bytes, (int64_t)0) countStyle:NSByteCountFormatterCountStyleMemory];
}

static ZSMemoryUsageCategory *zs_make_memory_row(NSString *name, int64_t bytes, NSString *detail) {
    ZSMemoryUsageCategory *row = [ZSMemoryUsageCategory new];
    row.name = name;
    row.totalBytes = bytes;
    row.detail = detail;
    return row;
}

static ZSMemoryUsageGroup *zs_make_memory_group(NSString *title, NSString *subtitle, BOOL showsChart, NSArray<ZSMemoryUsageCategory *> *categories) {
    ZSMemoryUsageGroup *group = [ZSMemoryUsageGroup new];
    group.title = title;
    group.subtitle = subtitle;
    group.showsChart = showsChart;
    group.categories = categories;
    return group;
}

static NSString *zs_memory_residency_detail(ZSMemoryUsageCategory *row) {
    if (row.totalBytes <= 0) return nil;
    double compressedShare = (double)row.compressedBytes / (double)row.totalBytes * 100.0;
    if (row.objectCount > 0) {
        return [NSString stringWithFormat:@"%.0f%% compressed · %lu regions", compressedShare, (unsigned long)row.objectCount];
    }
    return [NSString stringWithFormat:@"%.0f%% compressed", compressedShare];
}

static void zs_sort_memory_rows_descending(NSMutableArray<ZSMemoryUsageCategory *> *rows) {
    [rows sortUsingComparator:^NSComparisonResult(ZSMemoryUsageCategory *a, ZSMemoryUsageCategory *b) {
        if (a.totalBytes == b.totalBytes) return NSOrderedSame;
        return a.totalBytes > b.totalBytes ? NSOrderedAscending : NSOrderedDescending;
    }];
}

typedef struct {
    int64_t dirtyTotal;
    int64_t swappedTotal;
    int64_t untaggedDirty;
    int64_t untaggedSwapped;
    int64_t mallocDirty;
    int64_t mallocSwapped;
    int64_t virtualTotal;
    int64_t regionCount;
    double milliseconds;
} ZSVMWalkTotals;

typedef struct {
    vm_address_t address;
    natural_t depth;
    BOOL started;
    BOOL finished;
} ZSVMWalkCursor;

static const char *const kZSVMTagNames[256] = {
    [1] = "Malloc (system)",
    [2] = "Malloc small",
    [3] = "Malloc large",
    [4] = "Malloc huge",
    [5] = "sbrk heap",
    [6] = "realloc",
    [7] = "Malloc tiny",
    [8] = "Malloc large (reusable)",
    [9] = "Malloc large (reused)",
    [10] = "Analysis tool",
    [11] = "Malloc nano",
    [12] = "Malloc medium",
    [13] = "Malloc guarded",
    [20] = "Mach messages",
    [21] = "IOKit",
    [30] = "Thread stacks",
    [31] = "Guard pages",
    [32] = "Shared pmap",
    [33] = "dylib data",
    [34] = "ObjC dispatchers",
    [35] = "Unshared pmap",
    [40] = "UIKit / AppKit",
    [41] = "Foundation",
    [42] = "CoreGraphics",
    [43] = "Core services",
    [45] = "Core Data",
    [46] = "Core Data object IDs",
    [50] = "ATS fonts",
    [51] = "Core Animation (LayerKit)",
    [52] = "CG image",
    [54] = "CoreGraphics data",
    [55] = "CoreGraphics shared",
    [56] = "CoreGraphics framebuffers",
    [57] = "CoreGraphics backing stores",
    [58] = "CoreGraphics xalloc",
    [60] = "dyld",
    [61] = "dyld malloc",
    [62] = "SQLite",
    [63] = "JavaScriptCore",
    [64] = "JIT executable",
    [65] = "JIT register file",
    [66] = "GLSL",
    [67] = "OpenCL",
    [68] = "Core Image",
    [69] = "WebCore purgeable buffers",
    [70] = "ImageIO",
    [71] = "Core profile",
    [72] = "assetsd",
    [73] = "os_alloc_once",
    [74] = "libdispatch",
    [75] = "Accelerate",
    [76] = "CoreUI",
    [77] = "CoreUI file",
    [78] = "Genealogy",
    [79] = "Raw camera",
    [80] = "Corpse info",
    [81] = "ASL",
    [82] = "Swift runtime",
    [83] = "Swift metadata",
    [84] = "DHMM",
    [86] = "SceneKit",
    [87] = "Skywalk",
    [88] = "IOSurface (GPU shared)",
    [89] = "libnetwork",
    [90] = "Audio",
    [91] = "Video bitstream",
    [92] = "CoreMedia XPC",
    [93] = "CoreMedia RPC",
    [94] = "CoreMedia memory pool",
    [95] = "CoreMedia read cache",
    [96] = "CoreMedia crabs",
    [97] = "QuickLook thumbnails",
    [98] = "Accounts",
    [99] = "Sanitizer",
    [100] = "IOAccelerator (GPU)",
    [101] = "CoreMedia regwarp",
    [102] = "EAR decoder",
    [103] = "CoreUI cached image data",
    [104] = "ColorSync",
    [105] = "BTInfo",
    [106] = "CoreMedia HLS",
};

static NSString *zs_vm_anonymous_name(uint32_t tag) {
    if (tag == 0) return @"Untagged anonymous (IL2CPP Heap)";
    if (tag < 256 && kZSVMTagNames[tag]) return [NSString stringWithUTF8String:kZSVMTagNames[tag]];
    if (tag >= 240 && tag <= 255) return [NSString stringWithFormat:@"Application-specific (tag %u)", tag];
    return [NSString stringWithFormat:@"VM tag %u", tag];
}

static BOOL zs_vm_tag_is_malloc(uint32_t tag) {
    switch (tag) {
        case 1: case 2: case 3: case 4: case 6: case 7: case 8: case 9: case 11: case 12: case 13:
            return YES;
        default:
            return NO;
    }
}

static const NSUInteger kZSMallocTopRegionCount = 8;
static const int64_t kZSMallocTopRegionMinBytes = 1024 * 1024;

static void zs_malloc_track_region(NSMutableArray<ZSMemoryUsageCategory *> *regions,
                                   vm_address_t address,
                                   vm_size_t size,
                                   NSString *tagName,
                                   int64_t dirty,
                                   int64_t swapped) {
    int64_t footprintBytes = dirty + swapped;
    if (footprintBytes < kZSMallocTopRegionMinBytes) return;
    if (regions.count >= kZSMallocTopRegionCount && footprintBytes <= regions.lastObject.totalBytes) return;

    ZSMemoryUsageCategory *row = [ZSMemoryUsageCategory new];
    row.name = [NSString stringWithFormat:@"%@ @ 0x%llx", tagName, (unsigned long long)address];
    row.totalBytes = footprintBytes;
    row.residentBytes = dirty;
    row.compressedBytes = swapped;
    row.virtualBytes = (int64_t)size;

    NSUInteger index = regions.count;
    while (index > 0 && regions[index - 1].totalBytes < footprintBytes) index--;
    [regions insertObject:row atIndex:index];
    if (regions.count > kZSMallocTopRegionCount) [regions removeLastObject];
}

static BOOL zs_vm_path_is_system(NSString *path) {
    return [path hasPrefix:@"/System/"] ||
           [path hasPrefix:@"/usr/lib/"] ||
           [path hasPrefix:@"/Library/Apple/"] ||
           [path containsString:@"dyld_shared_cache"];
}

static ZSMemoryUsageCategory *zs_vm_bucket(NSMutableDictionary<NSString *, ZSMemoryUsageCategory *> *table, NSString *name) {
    ZSMemoryUsageCategory *bucket = table[name];
    if (!bucket) {
        bucket = [ZSMemoryUsageCategory new];
        bucket.name = name;
        table[name] = bucket;
    }
    return bucket;
}

static NSMutableDictionary<NSNumber *, NSString *> *g_vmFileLabelCache;

static void zs_walk_vm_regions(NSMutableDictionary<NSString *, ZSMemoryUsageCategory *> *owners,
                               NSMutableDictionary<NSString *, ZSMemoryUsageCategory *> *cleanFiles,
                               NSMutableDictionary<NSString *, ZSMemoryUsageCategory *> *mallocTags,
                               NSMutableArray<ZSMemoryUsageCategory *> *mallocRegions,
                               ZSVMWalkTotals *totals,
                               ZSVMWalkCursor *cursor,
                               NSUInteger regionBudget) {
    typedef int (*ZSRegionFilenameFn)(int, uint64_t, void *, uint32_t);
    static ZSRegionFilenameFn regionFilename;
    static dispatch_once_t regionFilenameOnce;
    dispatch_once(&regionFilenameOnce, ^{
        regionFilename = (ZSRegionFilenameFn)dlsym(RTLD_DEFAULT, "proc_regionfilename");
    });

    CFTimeInterval started = CACurrentMediaTime();
    if (!g_vmFileLabelCache) g_vmFileLabelCache = [NSMutableDictionary new];
    if (!cursor->started) {
        cursor->started = YES;
        if (g_vmFileLabelCache.count > 4096) [g_vmFileLabelCache removeAllObjects];
    }

    const int64_t pageSize = (int64_t)vm_page_size;
    const int pid = (int)getpid();
    char pathBuffer[1024];
    vm_address_t address = cursor->address;
    natural_t depth = cursor->depth;
    NSUInteger visited = 0;

    for (;;) {
        if (regionBudget > 0 && visited >= regionBudget) {
            cursor->address = address;
            cursor->depth = depth;
            totals->milliseconds += (CACurrentMediaTime() - started) * 1000.0;
            return;
        }
        visited++;

        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &address, &size, &depth, (vm_region_recurse_info_t)&info, &infoCount);
        if (kr != KERN_SUCCESS || size == 0) break;
        if (info.is_submap) {
            depth++;
            continue;
        }

        totals->regionCount++;
        totals->virtualTotal += (int64_t)size;

        int64_t reusable = (int64_t)info.pages_reusable * pageSize;
        int64_t dirty = (int64_t)info.pages_dirtied * pageSize - reusable;
        if (dirty < 0) dirty = 0;
        int64_t swapped = (int64_t)info.pages_swapped_out * pageSize;
        int64_t resident = (int64_t)info.pages_resident * pageSize;
        int64_t footprintBytes = dirty + swapped;
        BOOL fileBacked = info.external_pager != 0;

        totals->dirtyTotal += dirty;
        totals->swappedTotal += swapped;

        if (!fileBacked) {
            if (info.user_tag == 0) {
                totals->untaggedDirty += dirty;
                totals->untaggedSwapped += swapped;
            }
            if (footprintBytes > 0) {
                NSString *anonymousName = zs_vm_anonymous_name(info.user_tag);
                ZSMemoryUsageCategory *bucket = zs_vm_bucket(owners, anonymousName);
                bucket.totalBytes += footprintBytes;
                bucket.residentBytes += dirty;
                bucket.compressedBytes += swapped;
                bucket.objectCount++;

                if (zs_vm_tag_is_malloc(info.user_tag)) {
                    ZSMemoryUsageCategory *mallocBucket = zs_vm_bucket(mallocTags, anonymousName);
                    mallocBucket.totalBytes += footprintBytes;
                    mallocBucket.residentBytes += dirty;
                    mallocBucket.compressedBytes += swapped;
                    mallocBucket.virtualBytes += (int64_t)size;
                    mallocBucket.objectCount++;
                    totals->mallocDirty += dirty;
                    totals->mallocSwapped += swapped;
                    zs_malloc_track_region(mallocRegions, address, size, anonymousName, dirty, swapped);
                }
            }
            address += size;
            continue;
        }

        if (footprintBytes <= 0 && resident <= 0) {
            address += size;
            continue;
        }

        NSString *systemLabelOwners = @"System libraries (dirty data)";
        NSString *systemLabelClean = @"System libraries (shared cache)";
        NSString *ownerLabel = nil;
        NSString *cleanLabel = nil;

        Dl_info dl;
        memset(&dl, 0, sizeof(dl));
        if (dladdr((const void *)address, &dl) && dl.dli_fname) {
            NSString *fullPath = [NSString stringWithUTF8String:dl.dli_fname];
            if (fullPath.length > 0) {
                if (zs_vm_path_is_system(fullPath)) {
                    ownerLabel = systemLabelOwners;
                    cleanLabel = systemLabelClean;
                } else {
                    NSString *base = fullPath.lastPathComponent;
                    ownerLabel = [@"Image: " stringByAppendingString:base];
                    cleanLabel = ownerLabel;
                }
            }
        }

        if (!ownerLabel) {
            NSNumber *objectKey = @(info.object_id);
            NSString *cached = g_vmFileLabelCache[objectKey];
            if (!cached) {
                NSString *resolved = @"Mapped file (unnamed)";
                if (regionFilename) {
                    pathBuffer[0] = '\0';
                    int length = regionFilename(pid, (uint64_t)address, pathBuffer, (uint32_t)sizeof(pathBuffer));
                    if (length > 0 && pathBuffer[0] != '\0') {
                        NSString *fullPath = [NSString stringWithUTF8String:pathBuffer];
                        if (fullPath.length > 0) {
                            resolved = zs_vm_path_is_system(fullPath)
                                ? @"System files"
                                : [@"File: " stringByAppendingString:fullPath.lastPathComponent];
                        }
                    }
                }
                g_vmFileLabelCache[objectKey] = resolved;
                cached = resolved;
            }
            ownerLabel = cached;
            cleanLabel = cached;
        }

        if (footprintBytes > 0) {
            ZSMemoryUsageCategory *bucket = zs_vm_bucket(owners, ownerLabel);
            bucket.totalBytes += footprintBytes;
            bucket.residentBytes += dirty;
            bucket.compressedBytes += swapped;
            bucket.objectCount++;
        }

        int64_t cleanBytes = resident - dirty;
        if (cleanBytes > 0) {
            ZSMemoryUsageCategory *bucket = zs_vm_bucket(cleanFiles, cleanLabel);
            bucket.totalBytes += cleanBytes;
            bucket.objectCount++;
        }

        address += size;
    }

    cursor->address = address;
    cursor->depth = depth;
    cursor->finished = YES;
    totals->milliseconds += (CACurrentMediaTime() - started) * 1000.0;
}

typedef struct {
    BOOL hasAllocated;
    BOOL hasReserved;
    BOOL hasMono;
    BOOL hasGfx;
    BOOL hasGC;
    int64_t allocated;
    int64_t reserved;
    int64_t mono;
    int64_t gfx;
    int64_t gcHeap;
    int64_t gcUsed;
} ZSUnityMemoryFacts;

static ZSUnityMemoryFacts zs_collect_unity_memory_facts(void) {
    typedef uint64_t (*ZSGCSizeFn)(void);
    static ZSGCSizeFn gcHeapSize;
    static ZSGCSizeFn gcUsedSize;
    static dispatch_once_t gcOnce;
    dispatch_once(&gcOnce, ^{
        gcHeapSize = (ZSGCSizeFn)dlsym(RTLD_DEFAULT, "il2cpp_gc_get_heap_size");
        gcUsedSize = (ZSGCSizeFn)dlsym(RTLD_DEFAULT, "il2cpp_gc_get_used_size");
    });

    ZSUnityMemoryFacts facts;
    memset(&facts, 0, sizeof(facts));
    facts.hasAllocated = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetTotalAllocatedMemoryLong", &facts.allocated);
    facts.hasReserved = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetTotalReservedMemoryLong", &facts.reserved);
    facts.hasMono = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetMonoUsedSizeLong", &facts.mono);
    facts.hasGfx = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetAllocatedMemoryForGraphicsDriver", &facts.gfx);
    if (gcHeapSize && gcUsedSize) {
        facts.gcHeap = (int64_t)gcHeapSize();
        facts.gcUsed = (int64_t)gcUsedSize();
        facts.hasGC = facts.gcHeap > 0 && facts.gcUsed > 0;
    }
    return facts;
}

static NSString *zs_asset_detail_string(void *obj, const ZSMemoryUsageCategoryDescriptor *descriptor) {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:[NSString stringWithUTF8String:descriptor->klassName]];
    int32_t width = 0, height = 0, value = 0;
    BOOL flag = NO;

    switch (descriptor->family) {
        case ZSAssetFamilyTexture:
            if (mt_get_instance_int(obj, "get_width", &width) && mt_get_instance_int(obj, "get_height", &height)) {
                [parts addObject:[NSString stringWithFormat:@"%d×%d", width, height]];
            }
            if (mt_get_instance_int(obj, "get_mipmapCount", &value) && value > 1) {
                [parts addObject:[NSString stringWithFormat:@"%d mips", value]];
            }
            if (mt_get_instance_bool(obj, "get_isReadable", &flag) && flag) {
                [parts addObject:@"readable (CPU copy)"];
            }
            break;
        case ZSAssetFamilyRenderTexture:
            if (mt_get_instance_int(obj, "get_width", &width) && mt_get_instance_int(obj, "get_height", &height)) {
                [parts addObject:[NSString stringWithFormat:@"%d×%d", width, height]];
            }
            if (mt_get_instance_int(obj, "get_depth", &value) && value > 0) {
                [parts addObject:[NSString stringWithFormat:@"depth %d", value]];
            }
            if (mt_get_instance_int(obj, "get_antiAliasing", &value) && value > 1) {
                [parts addObject:[NSString stringWithFormat:@"%dx MSAA", value]];
            }
            break;
        case ZSAssetFamilyMesh:
            if (mt_get_instance_int(obj, "get_vertexCount", &value)) {
                [parts addObject:[NSString stringWithFormat:@"%d verts", value]];
            }
            if (mt_get_instance_bool(obj, "get_isReadable", &flag) && flag) {
                [parts addObject:@"readable (CPU copy)"];
            }
            break;
        default:
            break;
    }
    return [parts componentsJoinedByString:@" · "];
}

typedef struct {
    const void *width;
    const void *height;
    const void *mipCount;
    const void *format;
    const void *streaming;
    const void *loadedMip;
    const void *depth;
    const void *cubemapCount;
} ZSTextureMethods;

static BOOL zs_invoke_int32(const void *method, void *obj, int32_t *out) {
    if (!method || !obj || !out) return NO;
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:method onInstance:obj args:NULL outException:&exc];
    if (exc || !boxed) return NO;
    *out = *(int32_t *)((uint8_t *)boxed + 0x10);
    return YES;
}

static BOOL zs_invoke_bool(const void *method, void *obj, BOOL *out) {
    if (!method || !obj || !out) return NO;
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:method onInstance:obj args:NULL outException:&exc];
    if (exc || !boxed) return NO;
    *out = (*(uint8_t *)((uint8_t *)boxed + 0x10)) != 0;
    return YES;
}

static BOOL zs_texture_format_layout(int32_t format, int32_t *blockW, int32_t *blockH, int32_t *blockBytes, int32_t *minW, int32_t *minH) {
    *blockW = 1; *blockH = 1; *minW = 1; *minH = 1;
    switch (format) {
        case 1: case 63: *blockBytes = 1; return YES;
        case 2: case 7: case 9: case 13: case 15: case 21: case 62: *blockBytes = 2; return YES;
        case 3: *blockBytes = 3; return YES;
        case 4: case 5: case 14: case 16: case 18: case 22: case 72: *blockBytes = 4; return YES;
        case 73: *blockBytes = 6; return YES;
        case 17: case 19: case 74: *blockBytes = 8; return YES;
        case 20: *blockBytes = 16; return YES;
        case 10: case 26: case 28: case 34: case 41: case 42: case 45: case 46: case 64:
            *blockW = 4; *blockH = 4; *blockBytes = 8; return YES;
        case 12: case 24: case 25: case 27: case 29: case 43: case 44: case 47: case 65:
            *blockW = 4; *blockH = 4; *blockBytes = 16; return YES;
        case 30: case 31:
            *blockW = 8; *blockH = 4; *blockBytes = 8; *minW = 16; *minH = 8; return YES;
        case 32: case 33:
            *blockW = 4; *blockH = 4; *blockBytes = 8; *minW = 8; *minH = 8; return YES;
        case 48: case 54: case 66: *blockW = 4; *blockH = 4; *blockBytes = 16; return YES;
        case 49: case 55: case 67: *blockW = 5; *blockH = 5; *blockBytes = 16; return YES;
        case 50: case 56: case 68: *blockW = 6; *blockH = 6; *blockBytes = 16; return YES;
        case 51: case 57: case 69: *blockW = 8; *blockH = 8; *blockBytes = 16; return YES;
        case 52: case 58: case 70: *blockW = 10; *blockH = 10; *blockBytes = 16; return YES;
        case 53: case 59: case 71: *blockW = 12; *blockH = 12; *blockBytes = 16; return YES;
        default: return NO;
    }
}

static int64_t zs_estimate_texture_bytes(void *obj, const ZSMemoryUsageCategoryDescriptor *descriptor, const ZSTextureMethods *m) {
    int32_t width = 0, height = 0, format = 0, mips = 1;
    if (!zs_invoke_int32(m->width, obj, &width) || !zs_invoke_int32(m->height, obj, &height)) return 0;
    if (width <= 0 || height <= 0) return 0;
    if (!zs_invoke_int32(m->format, obj, &format)) return 0;

    int32_t blockW, blockH, blockBytes, minW, minH;
    if (!zs_texture_format_layout(format, &blockW, &blockH, &blockBytes, &minW, &minH)) return 0;

    if (!zs_invoke_int32(m->mipCount, obj, &mips) || mips < 1) mips = 1;

    int32_t firstLevel = 0;
    BOOL streaming = NO;
    if (zs_invoke_bool(m->streaming, obj, &streaming) && streaming) {
        int32_t loaded = 0;
        if (zs_invoke_int32(m->loadedMip, obj, &loaded) && loaded > 0 && loaded < mips) firstLevel = loaded;
    }

    int32_t layers = 1;
    BOOL volumeTexture = NO;
    const char *klassName = descriptor->klassName;
    if (strcmp(klassName, "Cubemap") == 0) {
        layers = 6;
    } else if (strcmp(klassName, "Texture2DArray") == 0) {
        int32_t depth = 0;
        if (zs_invoke_int32(m->depth, obj, &depth) && depth > 0) layers = depth;
    } else if (strcmp(klassName, "Texture3D") == 0) {
        int32_t depth = 0;
        if (zs_invoke_int32(m->depth, obj, &depth) && depth > 0) layers = depth;
        volumeTexture = YES;
    } else if (strcmp(klassName, "CubemapArray") == 0) {
        int32_t count = 0;
        if (zs_invoke_int32(m->cubemapCount, obj, &count) && count > 0) layers = count * 6;
    }

    int64_t total = 0;
    for (int32_t level = firstLevel; level < mips; level++) {
        int64_t w = MAX((int64_t)1, (int64_t)(width >> level));
        int64_t h = MAX((int64_t)1, (int64_t)(height >> level));
        w = MAX(w, (int64_t)minW);
        h = MAX(h, (int64_t)minH);
        int64_t blocksX = (w + blockW - 1) / blockW;
        int64_t blocksY = (h + blockH - 1) / blockH;
        int64_t slices = volumeTexture ? MAX((int64_t)1, (int64_t)(layers >> level)) : layers;
        total += blocksX * blocksY * (int64_t)blockBytes * slices;
    }
    return total;
}

typedef struct {
    void *obj;
    int64_t size;
    const ZSMemoryUsageCategoryDescriptor *descriptor;
} ZSTopAssetCandidate;

static void zs_top_assets_consider(ZSTopAssetCandidate *top,
                                   NSUInteger *count,
                                   NSUInteger capacity,
                                   void *obj,
                                   int64_t size,
                                   const ZSMemoryUsageCategoryDescriptor *descriptor) {
    if (capacity == 0) return;
    if (*count >= capacity && size <= top[*count - 1].size) return;

    NSUInteger index = *count < capacity ? *count : capacity - 1;
    while (index > 0 && top[index - 1].size < size) {
        top[index] = top[index - 1];
        index--;
    }
    top[index].obj = obj;
    top[index].size = size;
    top[index].descriptor = descriptor;
    if (*count < capacity) (*count)++;
}

static ZSMemoryUsageGroup *zs_build_footprint_group(NSDictionary<NSString *, ZSMemoryUsageCategory *> *owners,
                                                    const ZSVMWalkTotals *totals,
                                                    int64_t footprint) {
    NSMutableArray<ZSMemoryUsageCategory *> *rows = [owners.allValues mutableCopy];
    int64_t regionSum = totals->dirtyTotal + totals->swappedTotal;

    for (ZSMemoryUsageCategory *row in rows) row.detail = zs_memory_residency_detail(row);

    int64_t unaccounted = footprint - regionSum;
    if (unaccounted > (int64_t)4 * 1024 * 1024) {
        ZSMemoryUsageCategory *kernel = zs_make_memory_row(@"Kernel-accounted (no VM region)",
                                                          unaccounted,
                                                          @"GPU / IOKit ledger pages");
        [rows addObject:kernel];
    }

    zs_sort_memory_rows_descending(rows);
    NSString *subtitle = [NSString stringWithFormat:@"Footprint %@ · dirty %@ · compressed %@ · %lld regions",
                          zs_memory_bytes_string(footprint),
                          zs_memory_bytes_string(totals->dirtyTotal),
                          zs_memory_bytes_string(totals->swappedTotal),
                          (long long)totals->regionCount];
    return zs_make_memory_group(@"Process footprint by owner", subtitle, YES, rows);
}

static ZSMemoryUsageGroup *zs_build_unity_group(ZSAssetScanResult *scan, const ZSUnityMemoryFacts *facts) {
    NSMutableArray<ZSMemoryUsageCategory *> *rows = [scan.assetCategories mutableCopy];
    int64_t accounted = scan.assetTrackedBytes;

    if (facts->hasMono && facts->mono > 0) {
        NSString *detail = @"Live C# objects on the IL2CPP GC heap";
        if (facts->hasGC) {
            int64_t slack = MAX(facts->gcHeap - facts->gcUsed, (int64_t)0);
            detail = [NSString stringWithFormat:@"GC heap %@ committed · %@ slack",
                      zs_memory_bytes_string(facts->gcHeap), zs_memory_bytes_string(slack)];
        }
        [rows addObject:zs_make_memory_row(@"Managed heap (used)", facts->mono, detail)];
        accounted += facts->mono;
    }

    if (facts->hasGfx && facts->gfx > 0) {
        int64_t gfxRemainder = MAX(facts->gfx - scan.estimatedGpuTextureBytes, (int64_t)0);
        if (gfxRemainder > 0) {
            [rows addObject:zs_make_memory_row(@"Graphics driver (Unity)", gfxRemainder, @"Metal allocations not attributed to loaded textures")];
            accounted += gfxRemainder;
        }
    }

    if (facts->hasAllocated) {
        int64_t engine = facts->allocated - accounted;
        if (engine > 0) {
            [rows addObject:zs_make_memory_row(@"Engine (uncategorized native)",
                                               engine,
                                               @"Allocated minus everything above")];
        }
    }

    zs_sort_memory_rows_descending(rows);
    NSString *subtitle = @"Logical sizes reported by Unity, not physical pages";
    if (facts->hasAllocated && facts->hasReserved) {
        subtitle = [NSString stringWithFormat:@"Allocated %@ · reserved %@ · logical sizes reported by Unity",
                    zs_memory_bytes_string(facts->allocated), zs_memory_bytes_string(facts->reserved)];
    }
    return zs_make_memory_group(@"Unity allocations by subsystem", subtitle, YES, rows);
}

static ZSMemoryUsageGroup *zs_build_top_assets_group(ZSAssetScanResult *scan) {
    ZSMemoryUsageGroup *group = zs_make_memory_group(@"Heaviest loaded assets",
                                                     @"Individual objects by Profiler runtime size",
                                                     NO,
                                                     scan.topAssets);
    group.pagingEnabled = YES;
    group.pageIndex = scan.pageIndex;
    group.hasNextPage = scan.hasNextPage;
    group.pageCount = MAX(scan.pageCount, (NSUInteger)1);
    group.kindOptions = scan.kindOptions;
    group.activeKind = scan.kindFilter;
    if (scan.kindFilter.length > 0) {
        group.subtitle = [NSString stringWithFormat:@"Individual objects by Profiler runtime size · %@", scan.kindFilter];
    }
    return group;
}

static ZSMemoryUsageGroup *zs_build_diagnostics_group(ZSAssetScanResult *scan,
                                                      const ZSUnityMemoryFacts *facts,
                                                      const ZSVMWalkTotals *totals) {
    NSMutableArray<ZSMemoryUsageCategory *> *rows = [NSMutableArray new];

    int64_t untagged = totals->untaggedDirty + totals->untaggedSwapped;
    if (untagged > 0) {
        ZSMemoryUsageCategory *row = zs_make_memory_row(@"Untagged anonymous (physical)",
                                                        untagged,
                                                        [NSString stringWithFormat:@"dirty %@ · compressed %@",
                                                         zs_memory_bytes_string(totals->untaggedDirty),
                                                         zs_memory_bytes_string(totals->untaggedSwapped)]);
        [rows addObject:row];
    }

    if (facts->hasReserved && facts->reserved > 0) {
        [rows addObject:zs_make_memory_row(@"Unity total reserved (logical)", facts->reserved, @"Memory Unity's allocators hold from the OS")];
    }
    if (facts->hasAllocated && facts->allocated > 0) {
        [rows addObject:zs_make_memory_row(@"Unity total allocated (logical)", facts->allocated, @"Memory currently handed out to the engine")];
    }
    if (facts->hasReserved && facts->hasAllocated && facts->reserved > facts->allocated) {
        [rows addObject:zs_make_memory_row(@"Unity allocator slack", facts->reserved - facts->allocated, @"Reserved but unused; may overlap GC slack")];
    }
    if (facts->hasGC) {
        [rows addObject:zs_make_memory_row(@"GC heap committed", facts->gcHeap, [NSString stringWithFormat:@"%@ used", zs_memory_bytes_string(facts->gcUsed)])];
        if (facts->gcHeap > facts->gcUsed) {
            [rows addObject:zs_make_memory_row(@"GC heap slack", facts->gcHeap - facts->gcUsed, @"Committed to the GC but holding no live objects")];
        }
    }

    if (scan.readableTextureCount > 0) {
        [rows addObject:zs_make_memory_row(@"Readable textures",
                                           scan.readableTextureBytes,
                                           [NSString stringWithFormat:@"%lu textures keeping a CPU copy", (unsigned long)scan.readableTextureCount])];
    }
    if (scan.readableMeshCount > 0) {
        [rows addObject:zs_make_memory_row(@"Readable meshes",
                                           scan.readableMeshBytes,
                                           [NSString stringWithFormat:@"%lu meshes keeping a CPU copy", (unsigned long)scan.readableMeshCount])];
    }

    [rows addObject:zs_make_memory_row(@"Analyzer cost",
                                       0,
                                       [NSString stringWithFormat:@"full scan %.0f ms spread over %.0f s · VM walk %.1f ms",
                                        scan.scanMilliseconds, (double)ZS_MEMORY_SCAN_CYCLE_SECONDS, totals->milliseconds])];

    return zs_make_memory_group(@"Reservations & diagnostics", @"Not additive: several rows describe the same memory from different angles", NO, rows);
}

static ZSMemoryUsageGroup *zs_build_object_counts_group(ZSAssetScanResult *scan) {
    return zs_make_memory_group(@"Live object counts", @"Objects currently loaded by the engine", NO, scan.objectCounts);
}

static ZSMemoryUsageGroup *zs_build_clean_files_group(NSDictionary<NSString *, ZSMemoryUsageCategory *> *cleanFiles) {
    NSMutableArray<ZSMemoryUsageCategory *> *rows = [cleanFiles.allValues mutableCopy];
    zs_sort_memory_rows_descending(rows);
    if (rows.count > kZSCleanFileMaxRows) [rows removeObjectsInRange:NSMakeRange(kZSCleanFileMaxRows, rows.count - kZSCleanFileMaxRows)];
    for (ZSMemoryUsageCategory *row in rows) {
        row.detail = [NSString stringWithFormat:@"%lu regions", (unsigned long)row.objectCount];
    }
    return zs_make_memory_group(@"Clean file-backed pages",
                                @"Resident but reclaimable, so not counted toward the memory limit",
                                NO,
                                rows);
}

static kern_return_t zs_malloc_local_reader(task_t task, vm_address_t address, vm_size_t size, void **local) {
    *local = (void *)address;
    return KERN_SUCCESS;
}

static NSString *zs_malloc_zone_label(malloc_zone_t *zone, NSUInteger index) {
    const char *rawName = malloc_get_zone_name(zone);
    if (!rawName || rawName[0] == '\0') return [NSString stringWithFormat:@"Unnamed zone %lu", (unsigned long)index];
    NSString *name = [NSString stringWithUTF8String:rawName];
    NSRange suffix = [name rangeOfString:@"_0x"];
    if (suffix.location != NSNotFound && suffix.location > 0) name = [name substringToIndex:suffix.location];
    return name.length > 0 ? name : [NSString stringWithFormat:@"Unnamed zone %lu", (unsigned long)index];
}

typedef struct {
    int64_t inUse;
    int64_t held;
    int64_t blocks;
    NSUInteger zoneCount;
    double milliseconds;
} ZSMallocZoneTotals;

static NSMutableArray<ZSMemoryUsageCategory *> *zs_collect_malloc_zone_rows(ZSMallocZoneTotals *totals) {
    memset(totals, 0, sizeof(*totals));
    CFTimeInterval started = CACurrentMediaTime();
    NSMutableArray<ZSMemoryUsageCategory *> *rows = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSNumber *> *labelUse = [NSMutableDictionary new];

    vm_address_t *zones = NULL;
    unsigned zoneCount = 0;
    kern_return_t kr = malloc_get_all_zones(mach_task_self(), zs_malloc_local_reader, &zones, &zoneCount);
    if (kr != KERN_SUCCESS || !zones) {
        totals->milliseconds = (CACurrentMediaTime() - started) * 1000.0;
        return rows;
    }

    for (unsigned i = 0; i < zoneCount; i++) {
        malloc_zone_t *zone = (malloc_zone_t *)zones[i];
        if (!zone || !zone->introspect || !zone->introspect->statistics) continue;

        malloc_statistics_t stats;
        memset(&stats, 0, sizeof(stats));
        zone->introspect->statistics(zone, &stats);
        totals->zoneCount++;
        if (stats.size_in_use == 0 && stats.size_allocated == 0) continue;

        int64_t inUse = (int64_t)stats.size_in_use;
        int64_t held = MAX((int64_t)stats.size_allocated, inUse);
        totals->inUse += inUse;
        totals->held += held;
        totals->blocks += (int64_t)stats.blocks_in_use;

        NSString *label = zs_malloc_zone_label(zone, i);
        NSNumber *seen = labelUse[label];
        labelUse[label] = @(seen.unsignedIntegerValue + 1);
        if (seen) label = [NSString stringWithFormat:@"%@ #%lu", label, (unsigned long)(seen.unsignedIntegerValue + 1)];

        NSString *average = stats.blocks_in_use > 0
            ? zs_memory_bytes_string((int64_t)(stats.size_in_use / stats.blocks_in_use))
            : @"n/a";
        ZSMemoryUsageCategory *row = zs_make_memory_row(label,
                                                        inUse,
                                                        [NSString stringWithFormat:@"%u blocks · avg %@ · zone holds %@ · peak %@",
                                                         stats.blocks_in_use,
                                                         average,
                                                         zs_memory_bytes_string(held),
                                                         zs_memory_bytes_string((int64_t)stats.max_size_in_use)]);
        row.objectCount = stats.blocks_in_use;
        row.virtualBytes = held;
        [rows addObject:row];
    }

    totals->milliseconds = (CACurrentMediaTime() - started) * 1000.0;
    return rows;
}

static ZSMemoryUsageGroup *zs_build_malloc_zones_group(NSMutableArray<ZSMemoryUsageCategory *> *zoneRows,
                                                       const ZSMallocZoneTotals *zoneTotals) {
    NSMutableArray<ZSMemoryUsageCategory *> *rows = [zoneRows mutableCopy];
    int64_t freeInside = zoneTotals->held - zoneTotals->inUse;
    if (freeInside > 0) {
        [rows addObject:zs_make_memory_row(@"Free inside zones",
                                           freeInside,
                                           @"Held by the allocator, not handed out")];
    }
    zs_sort_memory_rows_descending(rows);
    NSString *subtitle = [NSString stringWithFormat:@"In use %@ · zones hold %@ · %lld blocks · %lu zones · %.1f ms",
                          zs_memory_bytes_string(zoneTotals->inUse),
                          zs_memory_bytes_string(zoneTotals->held),
                          (long long)zoneTotals->blocks,
                          (unsigned long)zoneTotals->zoneCount,
                          zoneTotals->milliseconds];
    return zs_make_memory_group(@"Malloc zones", subtitle, YES, rows);
}

static ZSMemoryUsageGroup *zs_build_malloc_attribution_group(NSDictionary<NSString *, ZSMemoryUsageCategory *> *mallocTags,
                                                             NSArray<ZSMemoryUsageCategory *> *mallocRegions,
                                                             const ZSVMWalkTotals *totals,
                                                             const ZSMallocZoneTotals *zoneTotals,
                                                             const ZSUnityMemoryFacts *facts) {
    NSMutableArray<ZSMemoryUsageCategory *> *rows = [NSMutableArray new];

    int64_t mallocFootprint = totals->mallocDirty + totals->mallocSwapped;
    [rows addObject:zs_make_memory_row(@"Malloc footprint (VM regions)",
                                       mallocFootprint,
                                       [NSString stringWithFormat:@"dirty %@ · comp. %@",
                                        zs_memory_bytes_string(totals->mallocDirty),
                                        zs_memory_bytes_string(totals->mallocSwapped)])];

    [rows addObject:zs_make_memory_row(@"Malloc in use (zones)",
                                       zoneTotals->inUse,
                                       [NSString stringWithFormat:@"%lld blocks", (long long)zoneTotals->blocks])];

    int64_t retained = mallocFootprint - zoneTotals->inUse;
    if (retained > 0) {
        [rows addObject:zs_make_memory_row(@"Retained free memory",
                                           retained,
                                           @"Freed, not returned to OS")];
    }

    if (facts->hasAllocated && facts->allocated > 0) {
        [rows addObject:zs_make_memory_row(@"Unity allocated (logical)",
                                           facts->allocated,
                                           @"Includes GPU-side assets")];
        int64_t outside = zoneTotals->inUse - facts->allocated;
        [rows addObject:zs_make_memory_row(@"Outside Unity (lower bound)",
                                           MAX(outside, (int64_t)0),
                                           outside > 0
                                               ? @"Live blocks beyond Unity's total"
                                               : @"No excess provable")];
    }

    NSMutableArray<ZSMemoryUsageCategory *> *tagRows = [mallocTags.allValues mutableCopy];
    zs_sort_memory_rows_descending(tagRows);
    for (ZSMemoryUsageCategory *tag in tagRows) {
        [rows addObject:zs_make_memory_row([@"VM: " stringByAppendingString:tag.name],
                                           tag.totalBytes,
                                           [NSString stringWithFormat:@"dirty %@ · comp. %@ · span %@",
                                            zs_memory_bytes_string(tag.residentBytes),
                                            zs_memory_bytes_string(tag.compressedBytes),
                                            zs_memory_bytes_string(tag.virtualBytes)])];
    }

    for (ZSMemoryUsageCategory *region in mallocRegions) {
        [rows addObject:zs_make_memory_row([@"Region: " stringByAppendingString:region.name],
                                           region.totalBytes,
                                           [NSString stringWithFormat:@"dirty %@ · comp. %@ · span %@",
                                            zs_memory_bytes_string(region.residentBytes),
                                            zs_memory_bytes_string(region.compressedBytes),
                                            zs_memory_bytes_string(region.virtualBytes)])];
    }

    return zs_make_memory_group(@"Malloc attribution",
                                @"Not additive: several rows describe the same memory from different angles",
                                NO,
                                rows);
}

@interface ZSTopAssetEntry : NSObject
@property (nonatomic, assign) int64_t size;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;
@end

@implementation ZSTopAssetEntry
@end

@interface ZSMemoryScanSession : NSObject
@property (nonatomic, assign) BOOL unbounded;
@property (nonatomic, assign) NSUInteger stage;
@property (nonatomic, assign) NSUInteger descriptorIndex;
@property (nonatomic, assign) NSUInteger objectCursor;
@property (nonatomic, assign) NSUInteger unitsDone;
@property (nonatomic, assign) double busyMilliseconds;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZSMemoryUsageCategory *> *owners;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZSMemoryUsageCategory *> *cleanFiles;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZSMemoryUsageCategory *> *mallocTags;
@property (nonatomic, strong) NSMutableArray<ZSMemoryUsageCategory *> *mallocRegions;
@property (nonatomic, assign) ZSVMWalkTotals totals;
@property (nonatomic, assign) ZSVMWalkCursor vmCursor;
@property (nonatomic, assign) int64_t footprint;
@property (nonatomic, strong) ZSAssetScanResult *result;
@property (nonatomic, strong) NSMutableArray<ZSTopAssetEntry *> *topEntries;
@property (nonatomic, copy) NSString *kindFilter;
@property (nonatomic, assign) BOOL kindFilterMatched;
@property (nonatomic, assign) NSUInteger requestedPage;
@property (nonatomic, assign) NSUInteger candidateCapacity;
@property (nonatomic, assign) NSUInteger totalAssets;
@property (nonatomic, assign) int64_t categoryTotal;
@property (nonatomic, assign) NSUInteger liveCount;
@end

@implementation ZSMemoryScanSession
@end

static const NSUInteger kZSMemoryScanVMRegionsPerUnit = 400;
static const NSUInteger kZSMemoryScanObjectsPerUnit = 150;

static void zs_memory_scan_session_prepare(ZSMemoryScanSession *session, BOOL unbounded) {
    session.unbounded = unbounded;
    session.stage = 0;
    session.descriptorIndex = 0;
    session.objectCursor = 0;
    session.busyMilliseconds = 0;
    session.owners = [NSMutableDictionary new];
    session.cleanFiles = [NSMutableDictionary new];
    session.mallocTags = [NSMutableDictionary new];
    session.mallocRegions = [NSMutableArray new];

    ZSVMWalkTotals totals;
    memset(&totals, 0, sizeof(totals));
    session.totals = totals;
    ZSVMWalkCursor cursor;
    memset(&cursor, 0, sizeof(cursor));
    session.vmCursor = cursor;
    session.footprint = 0;

    ZSAssetScanResult *result = [ZSAssetScanResult new];
    result.assetCategories = [NSMutableArray new];
    result.topAssets = [NSMutableArray new];
    result.objectCounts = [NSMutableArray new];
    result.kindOptions = [NSMutableArray new];
    result.kindFilter = g_topAssetsKindFilter;
    session.result = result;
    session.topEntries = [NSMutableArray new];

    session.kindFilter = g_topAssetsKindFilter;
    session.kindFilterMatched = g_topAssetsKindFilter == nil;
    NSUInteger requestedPage = g_topAssetsPage;
    if (g_topAssetsKnownLastPage != NSUIntegerMax) requestedPage = MIN(requestedPage, g_topAssetsKnownLastPage);
    session.requestedPage = requestedPage;
    session.candidateCapacity = (requestedPage + 1) * kZSTopAssetsPageSize;
    session.totalAssets = 0;
    session.categoryTotal = 0;
    session.liveCount = 0;
}

static void zs_memory_scan_finish_descriptor(ZSMemoryScanSession *session, const ZSMemoryUsageCategoryDescriptor *descriptor) {
    ZSAssetScanResult *result = session.result;
    if (session.categoryTotal > 0) {
        NSString *kindName = [NSString stringWithUTF8String:descriptor->klassName];
        BOOL kindMatchesFilter = session.kindFilter == nil || [session.kindFilter isEqualToString:kindName];
        if (kindMatchesFilter) session.kindFilterMatched = YES;

        ZSMemoryUsageCategory *kindRow = zs_make_memory_row(kindName, session.categoryTotal, nil);
        kindRow.objectCount = session.liveCount;
        [result.kindOptions addObject:kindRow];

        ZSMemoryUsageCategory *category = zs_make_memory_row([NSString stringWithUTF8String:descriptor->displayName],
                                                             session.categoryTotal,
                                                             [NSString stringWithFormat:@"%lu objects", (unsigned long)session.liveCount]);
        category.objectCount = session.liveCount;
        [result.assetCategories addObject:category];
        result.assetTrackedBytes += session.categoryTotal;
    }
    session.categoryTotal = 0;
    session.liveCount = 0;
    session.objectCursor = 0;
    session.descriptorIndex++;
}

static void zs_memory_scan_merge_candidates(ZSMemoryScanSession *session, const ZSTopAssetCandidate *candidates, NSUInteger candidateCount) {
    NSMutableArray<ZSTopAssetEntry *> *entries = session.topEntries;
    NSUInteger capacity = session.candidateCapacity;
    for (NSUInteger i = 0; i < candidateCount; i++) {
        ZSTopAssetCandidate candidate = candidates[i];
        if (entries.count >= capacity && candidate.size <= entries.lastObject.size) break;

        ZSTopAssetEntry *entry = [ZSTopAssetEntry new];
        entry.size = candidate.size;
        NSString *name = mt_get_instance_string(candidate.obj, "get_name");
        entry.name = name.length > 0 ? name : @"(unnamed)";
        entry.detail = zs_asset_detail_string(candidate.obj, candidate.descriptor);

        NSUInteger index = entries.count;
        while (index > 0 && entries[index - 1].size < candidate.size) index--;
        [entries insertObject:entry atIndex:index];
        if (entries.count > capacity) [entries removeLastObject];
    }
}

static void zs_memory_scan_process_assets(ZSMemoryScanSession *session) {
    NSUInteger descriptorCount = sizeof(kZSMemoryUsageCategoryDescriptors) / sizeof(kZSMemoryUsageCategoryDescriptors[0]);
    if (session.descriptorIndex >= descriptorCount) {
        session.stage = 2;
        return;
    }

    const ZSMemoryUsageCategoryDescriptor *descriptor = &kZSMemoryUsageCategoryDescriptors[session.descriptorIndex];
    g_memoryScanStatus = [NSString stringWithFormat:@"IL2CPP · %s", descriptor->klassName];
    void *klass = mt_class(descriptor->ns, descriptor->klassName, descriptor->assembly);
    NSUInteger count = 0;
    void *array = klass ? zs_resources_find_all_for_class(klass, &count) : NULL;

    if (!array || count == 0) {
        zs_memory_scan_finish_descriptor(session, descriptor);
        return;
    }

    if (!descriptor->tracked) {
        ZSMemoryUsageCategory *countRow = zs_make_memory_row([NSString stringWithUTF8String:descriptor->displayName], 0, nil);
        countRow.objectCount = count;
        [session.result.objectCounts addObject:countRow];
        zs_memory_scan_finish_descriptor(session, descriptor);
        return;
    }

    NSUInteger start = session.objectCursor;
    if (start >= count) {
        zs_memory_scan_finish_descriptor(session, descriptor);
        return;
    }
    NSUInteger end = session.unbounded ? count : MIN(count, start + kZSMemoryScanObjectsPerUnit);

    ZSAssetScanResult *result = session.result;
    NSString *kindName = [NSString stringWithUTF8String:descriptor->klassName];
    BOOL kindMatchesFilter = session.kindFilter == nil || [session.kindFilter isEqualToString:kindName];

    BOOL estimatesTexture = descriptor->family == ZSAssetFamilyTexture;
    ZSTextureMethods textureMethods;
    memset(&textureMethods, 0, sizeof(textureMethods));
    if (estimatesTexture) {
        textureMethods.width = mt_method(klass, "get_width", 0);
        textureMethods.height = mt_method(klass, "get_height", 0);
        textureMethods.mipCount = mt_method(klass, "get_mipmapCount", 0);
        textureMethods.format = mt_method(klass, "get_format", 0);
        textureMethods.streaming = mt_method(klass, "get_streamingMipmaps", 0);
        textureMethods.loadedMip = mt_method(klass, "get_loadedMipmapLevel", 0);
        textureMethods.depth = mt_method(klass, "get_depth", 0);
        textureMethods.cubemapCount = mt_method(klass, "get_cubemapCount", 0);
    }

    ZSTopAssetCandidate *candidates = kindMatchesFilter ? calloc(session.candidateCapacity, sizeof(ZSTopAssetCandidate)) : NULL;
    NSUInteger candidateCount = 0;

    for (NSUInteger i = start; i < end; i++) {
        void *obj = zs_array_object_at(array, i);
        if (!obj) continue;

        int64_t size = 0;
        BOOL gotProfilerSize = mt_call_static_object_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetRuntimeMemorySizeLong", obj, &size);
        if (!gotProfilerSize) size = 0;

        if (estimatesTexture) {
            int64_t estimated = zs_estimate_texture_bytes(obj, descriptor, &textureMethods);
            if (estimated > size) {
                result.estimatedGpuTextureBytes += estimated - size;
                size = estimated;
            }
        }
        if (size <= 0) continue;

        session.categoryTotal += size;
        session.liveCount++;

        if (descriptor->family == ZSAssetFamilyTexture || descriptor->family == ZSAssetFamilyMesh) {
            BOOL readable = NO;
            if (mt_get_instance_bool(obj, "get_isReadable", &readable) && readable) {
                if (descriptor->family == ZSAssetFamilyTexture) {
                    result.readableTextureBytes += size;
                    result.readableTextureCount++;
                } else {
                    result.readableMeshBytes += size;
                    result.readableMeshCount++;
                }
            }
        }

        if (kindMatchesFilter) {
            session.totalAssets++;
            if (candidates) zs_top_assets_consider(candidates, &candidateCount, session.candidateCapacity, obj, size, descriptor);
        }
    }

    if (candidates) {
        zs_memory_scan_merge_candidates(session, candidates, candidateCount);
        free(candidates);
    }

    session.objectCursor = end;
    if (end >= count) zs_memory_scan_finish_descriptor(session, descriptor);
}

static NSArray<ZSMemoryUsageGroup *> *zs_memory_scan_finalize(ZSMemoryScanSession *session) {
    if (!session.kindFilterMatched) {
        g_topAssetsKindFilter = nil;
        g_topAssetsPage = 0;
        g_topAssetsKnownLastPage = NSUIntegerMax;
        zs_memory_scan_session_prepare(session, session.unbounded);
        return nil;
    }

    ZSAssetScanResult *scan = session.result;

    [scan.kindOptions sortUsingComparator:^NSComparisonResult(ZSMemoryUsageCategory *a, ZSMemoryUsageCategory *b) {
        if (a.totalBytes == b.totalBytes) return NSOrderedSame;
        return a.totalBytes > b.totalBytes ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSUInteger totalAssets = session.totalAssets;
    NSUInteger lastPage = totalAssets > 0 ? (totalAssets - 1) / kZSTopAssetsPageSize : 0;
    NSUInteger page = MIN(session.requestedPage, lastPage);
    g_topAssetsPage = page;
    g_topAssetsKnownLastPage = lastPage;
    scan.pageCount = lastPage + 1;

    NSUInteger pageStart = page * kZSTopAssetsPageSize;
    NSUInteger pageEnd = MIN(session.topEntries.count, pageStart + kZSTopAssetsPageSize);
    for (NSUInteger i = pageStart; i < pageEnd; i++) {
        ZSTopAssetEntry *entry = session.topEntries[i];
        [scan.topAssets addObject:zs_make_memory_row(entry.name, entry.size, entry.detail)];
    }
    scan.pageIndex = page;
    scan.hasNextPage = totalAssets > (page + 1) * kZSTopAssetsPageSize;

    [scan.objectCounts sortUsingComparator:^NSComparisonResult(ZSMemoryUsageCategory *a, ZSMemoryUsageCategory *b) {
        if (a.objectCount == b.objectCount) return NSOrderedSame;
        return a.objectCount > b.objectCount ? NSOrderedAscending : NSOrderedDescending;
    }];

    scan.scannedAt = CACurrentMediaTime();
    scan.scanMilliseconds = session.busyMilliseconds;

    ZSUnityMemoryFacts facts = zs_collect_unity_memory_facts();
    ZSVMWalkTotals totals = session.totals;

    NSMutableArray<ZSMemoryUsageGroup *> *groups = [NSMutableArray new];
    ZSMallocZoneTotals zoneTotals;
    NSMutableArray<ZSMemoryUsageCategory *> *zoneRows = zs_collect_malloc_zone_rows(&zoneTotals);

    [groups addObject:zs_build_footprint_group(session.owners, &totals, session.footprint)];
    [groups addObject:zs_build_malloc_zones_group(zoneRows, &zoneTotals)];
    [groups addObject:zs_build_malloc_attribution_group(session.mallocTags, session.mallocRegions, &totals, &zoneTotals, &facts)];
    [groups addObject:zs_build_unity_group(scan, &facts)];
    [groups addObject:zs_build_top_assets_group(scan)];
    [groups addObject:zs_build_diagnostics_group(scan, &facts, &totals)];
    [groups addObject:zs_build_object_counts_group(scan)];
    [groups addObject:zs_build_clean_files_group(session.cleanFiles)];
    return groups;
}

static NSArray<ZSMemoryUsageGroup *> *zs_memory_scan_run_unit(ZSMemoryScanSession *session) {
    CFTimeInterval started = CACurrentMediaTime();
    NSArray<ZSMemoryUsageGroup *> *groups = nil;

    if (session.stage == 0) {
        g_memoryScanStatus = @"VM regions · mach_vm_region";
        ZSVMWalkTotals totals = session.totals;
        ZSVMWalkCursor cursor = session.vmCursor;
        zs_walk_vm_regions(session.owners, session.cleanFiles, session.mallocTags, session.mallocRegions, &totals, &cursor, session.unbounded ? 0 : kZSMemoryScanVMRegionsPerUnit);
        session.totals = totals;
        session.vmCursor = cursor;
        if (cursor.finished) {
            session.footprint = zs_current_process_resident_memory_bytes();
            session.stage = 1;
        }
    } else if (session.stage == 1) {
        zs_memory_scan_process_assets(session);
    } else {
        g_memoryScanStatus = @"Malloc zones · Unity Profiler";
        groups = zs_memory_scan_finalize(session);
    }

    session.busyMilliseconds += (CACurrentMediaTime() - started) * 1000.0;
    return groups;
}

void zs_memory_scan_reset(void) {
    g_memoryScanSession = nil;
    g_memoryScanStatus = nil;
}

NSString *zs_memory_scan_current_status(void) {
    return g_memoryScanStatus;
}

NSArray<ZSMemoryUsageGroup *> *zs_memory_scan_step(NSUInteger *unitsDoneOut) {
    if (!g_memoryScanSession) {
        ZSMemoryScanSession *fresh = [ZSMemoryScanSession new];
        zs_memory_scan_session_prepare(fresh, NO);
        g_memoryScanSession = fresh;
    }
    ZSMemoryScanSession *session = g_memoryScanSession;

    NSArray<ZSMemoryUsageGroup *> *groups = nil;
    @autoreleasepool {
        groups = zs_memory_scan_run_unit(session);
    }
    session.unitsDone++;
    if (unitsDoneOut) *unitsDoneOut = session.unitsDone;
    if (groups) g_memoryScanSession = nil;
    return groups;
}

void zs_collect_memory_usage_breakdown(void (^completion)(NSArray<ZSMemoryUsageGroup *> *groups)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            ZSMemoryScanSession *session = [ZSMemoryScanSession new];
            zs_memory_scan_session_prepare(session, YES);
            NSArray<ZSMemoryUsageGroup *> *results = nil;
            while (!results) results = zs_memory_scan_run_unit(session);
            g_memoryScanSession = nil;
            completion(results);
        }
    });
}

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static BOOL zs_process_has_entitlement(NSString *entitlementKey) {
    if (entitlementKey.length == 0) return NO;

    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return NO;

    CFTypeRef value = SecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)entitlementKey, NULL);
    CFRelease(task);
    if (!value) return NO;

    BOOL hasEntitlement = NO;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        hasEntitlement = CFBooleanGetValue((CFBooleanRef)value);
    } else {
        hasEntitlement = YES;
    }

    CFRelease(value);
    return hasEntitlement;
}

int64_t zs_current_process_resident_memory_bytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return 0;
    return (int64_t)info.phys_footprint;
}

ZSMemorySystemStats zs_collect_memory_system_stats(void) {
    ZSMemorySystemStats stats;
    memset(&stats, 0, sizeof(stats));

    task_vm_info_data_t info;
    mach_msg_type_number_t infoCount = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &infoCount) == KERN_SUCCESS) {
        stats.residentBytes = (int64_t)info.phys_footprint;
        stats.peakResidentBytes = (int64_t)info.resident_size_peak;
        stats.compressedBytes = (int64_t)info.compressed;
        stats.internalBytes = (int64_t)info.internal;
        stats.externalBytes = (int64_t)info.external;
        stats.reusableBytes = (int64_t)info.reusable;
        stats.virtualBytes = (int64_t)info.virtual_size;
        stats.residentSizeBytes = (int64_t)info.resident_size;
        stats.peakFootprintBytes = (int64_t)info.ledger_phys_footprint_peak;
        stats.compressedPeakBytes = (int64_t)info.compressed_peak;
        stats.compressedLifetimeBytes = (int64_t)info.compressed_lifetime;
        stats.deviceMappedBytes = (int64_t)info.device;
        stats.purgeableVolatileBytes = (int64_t)info.purgeable_volatile_resident;
        stats.regionCount = (int64_t)info.region_count;
        stats.pageSizeBytes = (int64_t)info.page_size;
    }

    stats.deviceTotalBytes = (int64_t)NSProcessInfo.processInfo.physicalMemory;

    if (@available(iOS 13.0, *)) {
        stats.availableBytes = (int64_t)os_proc_available_memory();
    } else {
        stats.availableBytes = 0;
    }

    if (stats.residentBytes > 0 && stats.availableBytes > 0) {
        stats.memoryLimitApproxBytes = stats.residentBytes + stats.availableBytes;
    }

    mach_port_t host = mach_host_self();
    vm_size_t pageSize = 0;
    host_page_size(host, &pageSize);
    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t vmCount = HOST_VM_INFO64_COUNT;
    if (pageSize > 0 && host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vmStats, &vmCount) == KERN_SUCCESS) {
        stats.systemFreeBytes = (int64_t)vmStats.free_count * (int64_t)pageSize;
        stats.systemActiveBytes = (int64_t)vmStats.active_count * (int64_t)pageSize;
        stats.systemWiredBytes = (int64_t)vmStats.wire_count * (int64_t)pageSize;
        stats.systemInactiveBytes = (int64_t)vmStats.inactive_count * (int64_t)pageSize;
        stats.systemSpeculativeBytes = (int64_t)vmStats.speculative_count * (int64_t)pageSize;
        stats.systemPurgeableBytes = (int64_t)vmStats.purgeable_count * (int64_t)pageSize;
        stats.systemFileBackedBytes = (int64_t)vmStats.external_page_count * (int64_t)pageSize;
        stats.systemAnonymousBytes = (int64_t)vmStats.internal_page_count * (int64_t)pageSize;
        stats.systemCompressorBytes = (int64_t)vmStats.compressor_page_count * (int64_t)pageSize;
        if (vmStats.compressor_page_count > 0) {
            stats.compressionRatio = (double)vmStats.total_uncompressed_pages_in_compressor / (double)vmStats.compressor_page_count;
        }
        stats.pageIns = (int64_t)vmStats.pageins;
        stats.pageOuts = (int64_t)vmStats.pageouts;
        stats.faults = (int64_t)vmStats.faults;
        stats.cowFaults = (int64_t)vmStats.cow_faults;
        stats.zeroFills = (int64_t)vmStats.zero_fill_count;
        stats.compressions = (int64_t)vmStats.compressions;
        stats.decompressions = (int64_t)vmStats.decompressions;
    }

    int freeLevel = 0;
    size_t freeLevelSize = sizeof(freeLevel);
    if (sysctlbyname("kern.memorystatus_level", &freeLevel, &freeLevelSize, NULL, 0) == 0) {
        stats.freeLevelPercent = freeLevel;
    }

    if (stats.availableBytes <= 0) {
        stats.pressureLabel = "Unknown";
    } else if (stats.availableBytes < (int64_t)50 * 1024 * 1024) {
        stats.pressureLabel = "Critical";
    } else if (stats.availableBytes < (int64_t)150 * 1024 * 1024) {
        stats.pressureLabel = "Elevated";
    } else {
        stats.pressureLabel = "Normal";
    }

    stats.hasIncreasedMemoryLimitEntitlement = zs_process_has_entitlement(@"com.apple.developer.kernel.increased-memory-limit");
    stats.hasExtendedVirtualAddressingEntitlement = zs_process_has_entitlement(@"com.apple.developer.kernel.extended-virtual-addressing");

    return stats;
}

#pragma mark - Scene-wide performance surfaces

static NSMutableDictionary<NSValue *, NSNumber *> *g_particleOriginalRenderModes;
static NSMutableDictionary<NSValue *, NSNumber *> *zs_particle_render_mode_cache(void) {
    if (!g_particleOriginalRenderModes) g_particleOriginalRenderModes = [NSMutableDictionary new];
    return g_particleOriginalRenderModes;
}

static NSMutableDictionary<NSValue *, NSNumber *> *g_particleOriginalAlignments;
static NSMutableDictionary<NSValue *, NSNumber *> *zs_particle_alignment_cache(void) {
    if (!g_particleOriginalAlignments) g_particleOriginalAlignments = [NSMutableDictionary new];
    return g_particleOriginalAlignments;
}

static void zs_apply_particle_alignment_to_object(void *obj) {
    if (!obj) return;
    NSValue *key = [NSValue valueWithPointer:obj];
    NSMutableDictionary<NSValue *, NSNumber *> *cache = zs_particle_alignment_cache();

    if (g_expParticleAlignment == kZSParticleAlignmentPreserveOriginal) {
        NSNumber *original = cache[key];
        if (original) mt_call_instance_int(obj, "set_alignment", original.intValue);
        return;
    }

    if (!cache[key]) {
        int32_t current = 0;
        if (mt_get_instance_int(obj, "get_alignment", &current)) {
            cache[key] = @(current);
        }
    }
    mt_call_instance_int(obj, "set_alignment", g_expParticleAlignment);
}

static void zs_apply_particle_render_mode_to_object(void *obj) {
    if (!obj) return;
    NSValue *key = [NSValue valueWithPointer:obj];
    NSMutableDictionary<NSValue *, NSNumber *> *cache = zs_particle_render_mode_cache();

    if (g_expParticleRenderMode == kZSParticleRenderModePreserveOriginal) {
        NSNumber *original = cache[key];
        if (original) mt_call_instance_int(obj, "set_renderMode", original.intValue);
        return;
    }

    if (!cache[key]) {
        int32_t current = 0;
        if (mt_get_instance_int(obj, "get_renderMode", &current)) {
            cache[key] = @(current);
        }
    }
    mt_call_instance_int(obj, "set_renderMode", g_expParticleRenderMode);
}

static void zs_apply_particle_settings(void) {
    void *klass = mt_class("UnityEngine", "ParticleSystemRenderer", "ParticleSystemModule");
    NSUInteger count = 0;
    void *array = zs_resources_find_all_for_class(klass, &count);
    if (!array) return;
    for (NSUInteger i = 0; i < count; i++) {
        void *obj = zs_array_object_at(array, i);
        if (obj) {
            mt_call_instance_bool(obj, "set_enableGPUInstancing", g_expParticleGPUInstancing);
            zs_apply_particle_alignment_to_object(obj);
            zs_apply_particle_render_mode_to_object(obj);
            mt_call_instance_int(obj, "set_meshDistribution", g_expParticleMeshDistribution);
            mt_call_instance_int(obj, "set_sortMode", g_expParticleSortMode);
            mt_call_instance_float(obj, "set_lengthScale", g_expParticleLengthScale);
            mt_call_instance_float(obj, "set_velocityScale", g_expParticleVelocityScale);
            mt_call_instance_float(obj, "set_cameraVelocityScale", g_expParticleCameraVelocityScale);
            mt_call_instance_float(obj, "set_normalDirection", g_expParticleNormalDirection);
            mt_call_instance_float(obj, "set_shadowBias", g_expParticleShadowBias);
            mt_call_instance_float(obj, "set_sortingFudge", g_expParticleSortingFudge);
            mt_call_instance_float(obj, "set_minParticleSize", g_expParticleMinSize);
            mt_call_instance_float(obj, "set_maxParticleSize", g_expParticleMaxSize);
            mt_call_instance_bool(obj, "set_allowRoll", g_expParticleAllowRoll);
            mt_call_instance_bool(obj, "set_freeformStretching", g_expParticleFreeformStretching);
            mt_call_instance_bool(obj, "set_rotateWithStretchDirection", g_expParticleRotateWithStretchDirection);
            mt_call_instance_bool(obj, "set_applyActiveColorSpace", g_expParticleApplyActiveColorSpace);
        }
    }
}

static void zs_apply_animator_settings(void) {
    void *klass = mt_class("UnityEngine", "Animator", "AnimationModule");
    NSUInteger count = 0;
    void *array = zs_resources_find_all_for_class(klass, &count);
    if (!array) return;
    for (NSUInteger i = 0; i < count; i++) {
        void *obj = zs_array_object_at(array, i);
        if (!obj) continue;
        mt_call_instance_int(obj, "set_cullingMode", g_expAnimatorCullingMode);
        mt_call_instance_int(obj, "set_updateMode", g_expAnimatorUpdateMode);
        mt_call_instance_bool(obj, "set_applyRootMotion", g_expAnimatorApplyRootMotion);
        mt_call_instance_bool(obj, "set_linearVelocityBlending", g_expAnimatorLinearVelocityBlending);
        mt_call_instance_bool(obj, "set_animatePhysics", g_expAnimatorAnimatePhysics);
        mt_call_instance_bool(obj, "set_allowConstantClipSamplingOptimization", g_expAnimatorConstantClipSamplingOptimization);
        mt_call_instance_bool(obj, "set_stabilizeFeet", g_expAnimatorStabilizeFeet);
        mt_call_instance_float(obj, "set_speed", g_expAnimatorSpeed);
        mt_call_instance_bool(obj, "set_logWarnings", g_expAnimatorLogWarnings);
        mt_call_instance_bool(obj, "set_fireEvents", g_expAnimatorFireEvents);
        mt_call_instance_bool(obj, "set_keepAnimatorStateOnDisable", g_expAnimatorKeepStateOnDisable);
        mt_call_instance_bool(obj, "set_keepAnimatorControllerStateOnDisable", g_expAnimatorKeepControllerStateOnDisable);
        mt_call_instance_bool(obj, "set_writeDefaultValuesOnDisable", g_expAnimatorWriteDefaultValuesOnDisable);
    }
}

static void zs_apply_camera_surface(void) {
    void *camera = mt_get_static_instance("UnityEngine", "Camera", "CoreModule", "get_main");
    if (!camera) camera = mt_get_static_instance("UnityEngine", "Camera", "CoreModule", "get_current");
    if (!camera) return;
    mt_call_instance_bool(camera, "set_allowHDR", g_expCameraHDR);
    mt_call_instance_bool(camera, "set_allowMSAA", g_expCameraMSAA);
    mt_call_instance_bool(camera, "set_allowDynamicResolution", g_expDynamicResolution);
    mt_call_instance_bool(camera, "set_useOcclusionCulling", g_expOcclusionCulling);
    mt_call_instance_int(camera, "set_depthTextureMode", g_expDepthTexture ? 1 : 0);
}

static void zs_apply_render_texture_memoryless(void) {
    void *klass = mt_class("UnityEngine", "RenderTexture", "CoreModule");
    NSUInteger count = 0;
    void *array = zs_resources_find_all_for_class(klass, &count);
    if (!array) return;
    for (NSUInteger i = 0; i < count; i++) {
        void *obj = zs_array_object_at(array, i);
        if (obj) mt_call_instance_int(obj, "set_memorylessMode", g_expRenderTextureMemorylessMode);
    }
}

static BOOL zs_particle_value_is_default(NSString *key) {
#define PARTICLE_ISDEF(type, name, def, persist) if ([key isEqualToString:@#name]) return fabs((double)g_exp##name - (double)(def)) < 1e-4;
    PARTICLE_DEFAULTS(PARTICLE_ISDEF)
#undef PARTICLE_ISDEF
    return NO;
}

static BOOL zs_particle_key_needs_restore(NSString *key) {
    if ([key isEqualToString:@"ParticleAlignment"]) return zs_particle_alignment_cache().count > 0;
    if ([key isEqualToString:@"ParticleRenderMode"]) return zs_particle_render_mode_cache().count > 0;
    return NO;
}

BOOL zs_apply_particle_key(NSString *key) {
    BOOL isDefault = zs_particle_value_is_default(key);
    if (isDefault && !zs_particle_key_needs_restore(key)) return YES;

    void *klass = mt_class("UnityEngine", "ParticleSystemRenderer", "ParticleSystemModule");
    NSUInteger count = 0;
    void *array = zs_resources_find_all_for_class(klass, &count);
    if (!array) return NO;
    BOOL handled = YES;
    for (NSUInteger i = 0; i < count; i++) {
        void *obj = zs_array_object_at(array, i);
        if (!obj) continue;
        if ([key isEqualToString:@"ParticleGPUInstancing"]) mt_call_instance_bool(obj, "set_enableGPUInstancing", g_expParticleGPUInstancing);
        else if ([key isEqualToString:@"ParticleAlignment"]) zs_apply_particle_alignment_to_object(obj);
        else if ([key isEqualToString:@"ParticleRenderMode"]) zs_apply_particle_render_mode_to_object(obj);
        else if ([key isEqualToString:@"ParticleMeshDistribution"]) mt_call_instance_int(obj, "set_meshDistribution", g_expParticleMeshDistribution);
        else if ([key isEqualToString:@"ParticleSortMode"]) mt_call_instance_int(obj, "set_sortMode", g_expParticleSortMode);
        else if ([key isEqualToString:@"ParticleLengthScale"]) mt_call_instance_float(obj, "set_lengthScale", g_expParticleLengthScale);
        else if ([key isEqualToString:@"ParticleVelocityScale"]) mt_call_instance_float(obj, "set_velocityScale", g_expParticleVelocityScale);
        else if ([key isEqualToString:@"ParticleCameraVelocityScale"]) mt_call_instance_float(obj, "set_cameraVelocityScale", g_expParticleCameraVelocityScale);
        else if ([key isEqualToString:@"ParticleNormalDirection"]) mt_call_instance_float(obj, "set_normalDirection", g_expParticleNormalDirection);
        else if ([key isEqualToString:@"ParticleShadowBias"]) mt_call_instance_float(obj, "set_shadowBias", g_expParticleShadowBias);
        else if ([key isEqualToString:@"ParticleSortingFudge"]) mt_call_instance_float(obj, "set_sortingFudge", g_expParticleSortingFudge);
        else if ([key isEqualToString:@"ParticleMinSize"]) mt_call_instance_float(obj, "set_minParticleSize", g_expParticleMinSize);
        else if ([key isEqualToString:@"ParticleMaxSize"]) mt_call_instance_float(obj, "set_maxParticleSize", g_expParticleMaxSize);
        else if ([key isEqualToString:@"ParticleAllowRoll"]) mt_call_instance_bool(obj, "set_allowRoll", g_expParticleAllowRoll);
        else if ([key isEqualToString:@"ParticleFreeformStretching"]) mt_call_instance_bool(obj, "set_freeformStretching", g_expParticleFreeformStretching);
        else if ([key isEqualToString:@"ParticleRotateWithStretchDirection"]) mt_call_instance_bool(obj, "set_rotateWithStretchDirection", g_expParticleRotateWithStretchDirection);
        else if ([key isEqualToString:@"ParticleApplyActiveColorSpace"]) mt_call_instance_bool(obj, "set_applyActiveColorSpace", g_expParticleApplyActiveColorSpace);
        else { handled = NO; break; }
    }
    if (isDefault) {
        if ([key isEqualToString:@"ParticleAlignment"]) [zs_particle_alignment_cache() removeAllObjects];
        else if ([key isEqualToString:@"ParticleRenderMode"]) [zs_particle_render_mode_cache() removeAllObjects];
    }
    return handled;
}

BOOL zs_apply_particle_max_particles_cap(void) {
    if (!g_expParticleMaxParticlesCapEnabled) return YES;
    void *klass = mt_class("UnityEngine", "ParticleSystem", "ParticleSystemModule");
    NSUInteger count = 0;
    void *array = zs_resources_find_all_for_class(klass, &count);
    if (!array) return NO;
    const void *getter = mt_method(klass, "get_maxParticles", 0);
    const void *setter = mt_method(klass, "set_maxParticles", 1);
    if (!getter || !setter) return NO;
    int32_t cap = g_expParticleMaxParticlesCap;
    NSUInteger clamped = 0;
    for (NSUInteger i = 0; i < count; i++) {
        void *obj = zs_array_object_at(array, i);
        if (!obj) continue;
        void *exc = NULL;
        void *boxed = [IL2CppBridge invokeMethod:getter onInstance:obj args:NULL outException:&exc];
        if (exc || !boxed) continue;
        int32_t current = *(int32_t *)((uint8_t *)boxed + 0x10);
        if (current <= cap) continue;
        void *args[1] = { &cap };
        exc = NULL;
        [IL2CppBridge invokeMethod:setter onInstance:obj args:args outException:&exc];
        if (!exc) clamped++;
    }
    ZLog(@"[ZSMemoryTweaks] particle maxParticles cap: clamped %lu/%lu loaded emitters to <= %d",
         (unsigned long)clamped, (unsigned long)count, cap);
    return YES;
}

static BOOL zs_particle_apply_key_internal(NSString *key) {
    if ([key isEqualToString:@"ParticleMaxParticlesCapEnabled"] || [key isEqualToString:@"ParticleMaxParticlesCap"]) {
        return zs_apply_particle_max_particles_cap();
    }
    return zs_apply_particle_key(key);
}

void zs_particle_apply_key(NSString *key) {
    @autoreleasepool {
        @try {
            BOOL applied = zs_particle_apply_key_internal(key);
            if (!applied && key.length) {
                ZLog(@"[ZSParticles] Key %@ has no safe runtime operation; state saved only", key);
            }
        } @catch (NSException *exception) {
            ZLog(@"[ZSParticles] Key %@ failed safely: %@", key, exception.reason);
        }
    }
}

BOOL zs_particle_key_class_available(NSString *key) {
    if ([key isEqualToString:@"ParticleMaxParticlesCapEnabled"] || [key isEqualToString:@"ParticleMaxParticlesCap"]) {
        return mt_class("UnityEngine", "ParticleSystem", "ParticleSystemModule") != NULL;
    }
    return mt_class("UnityEngine", "ParticleSystemRenderer", "ParticleSystemModule") != NULL;
}

static BOOL zs_apply_animator_key(NSString *key) {
    void *klass = mt_class("UnityEngine", "Animator", "AnimationModule");
    NSUInteger count = 0;
    void *array = zs_resources_find_all_for_class(klass, &count);
    if (!array) return NO;
    BOOL handled = YES;
    for (NSUInteger i = 0; i < count; i++) {
        void *obj = zs_array_object_at(array, i);
        if (!obj) continue;
        if ([key isEqualToString:@"AnimatorCullingMode"]) mt_call_instance_int(obj, "set_cullingMode", g_expAnimatorCullingMode);
        else if ([key isEqualToString:@"AnimatorUpdateMode"]) mt_call_instance_int(obj, "set_updateMode", g_expAnimatorUpdateMode);
        else if ([key isEqualToString:@"AnimatorApplyRootMotion"]) mt_call_instance_bool(obj, "set_applyRootMotion", g_expAnimatorApplyRootMotion);
        else if ([key isEqualToString:@"AnimatorLinearVelocityBlending"]) mt_call_instance_bool(obj, "set_linearVelocityBlending", g_expAnimatorLinearVelocityBlending);
        else if ([key isEqualToString:@"AnimatorAnimatePhysics"]) mt_call_instance_bool(obj, "set_animatePhysics", g_expAnimatorAnimatePhysics);
        else if ([key isEqualToString:@"AnimatorConstantClipSamplingOptimization"]) mt_call_instance_bool(obj, "set_allowConstantClipSamplingOptimization", g_expAnimatorConstantClipSamplingOptimization);
        else if ([key isEqualToString:@"AnimatorStabilizeFeet"]) mt_call_instance_bool(obj, "set_stabilizeFeet", g_expAnimatorStabilizeFeet);
        else if ([key isEqualToString:@"AnimatorSpeed"]) mt_call_instance_float(obj, "set_speed", g_expAnimatorSpeed);
        else if ([key isEqualToString:@"AnimatorLogWarnings"]) mt_call_instance_bool(obj, "set_logWarnings", g_expAnimatorLogWarnings);
        else if ([key isEqualToString:@"AnimatorFireEvents"]) mt_call_instance_bool(obj, "set_fireEvents", g_expAnimatorFireEvents);
        else if ([key isEqualToString:@"AnimatorKeepStateOnDisable"]) mt_call_instance_bool(obj, "set_keepAnimatorStateOnDisable", g_expAnimatorKeepStateOnDisable);
        else if ([key isEqualToString:@"AnimatorKeepControllerStateOnDisable"]) mt_call_instance_bool(obj, "set_keepAnimatorControllerStateOnDisable", g_expAnimatorKeepControllerStateOnDisable);
        else if ([key isEqualToString:@"AnimatorWriteDefaultValuesOnDisable"]) mt_call_instance_bool(obj, "set_writeDefaultValuesOnDisable", g_expAnimatorWriteDefaultValuesOnDisable);
        else { handled = NO; break; }
    }
    return handled;
}

static BOOL zs_apply_rigidbody_key(NSString *key) {
    void *resources = mt_class("UnityEngine", "Resources", "CoreModule");
    const void *find = mt_method(resources, "FindObjectsOfTypeAll", 1);
    if (!find) return NO;
    BOOL is3D = [key hasPrefix:@"Rigidbody"] && ![key hasPrefix:@"Rigidbody2D"];
    BOOL is2D = [key hasPrefix:@"Rigidbody2D"];
    if (!is3D && !is2D) return NO;
    const char *className = is3D ? "Rigidbody" : "Rigidbody2D";
    const char *assembly = is3D ? "PhysicsModule" : "Physics2DModule";
    void *typeClass = mt_class("UnityEngine", className, assembly);
    void *typeObj = [IL2CppBridge reflectionTypeForClass:typeClass];
    if (!typeObj) return NO;
    void *args[1] = { typeObj }, *exc = NULL;
    void *array = [IL2CppBridge invokeMethod:find onInstance:NULL args:args outException:&exc];
    if (exc || !array) return NO;
    uintptr_t count = *(uintptr_t *)((uint8_t *)array + 0x18);
    BOOL handled = YES;
    for (uintptr_t i = 0; i < count; i++) {
        void *obj = zs_array_object_at(array, (NSUInteger)i);
        if (!obj) continue;
        if ([key isEqualToString:@"RigidbodySolverIterations"]) mt_call_instance_int(obj, "set_solverIterations", g_expRigidbodySolverIterations);
        else if ([key isEqualToString:@"RigidbodySolverVelocityIterations"]) mt_call_instance_int(obj, "set_solverVelocityIterations", g_expRigidbodySolverVelocityIterations);
        else if ([key isEqualToString:@"RigidbodySleepThreshold"]) mt_call_instance_float(obj, "set_sleepThreshold", g_expRigidbodySleepThreshold);
        else if ([key isEqualToString:@"RigidbodyMaxAngularVelocity"]) mt_call_instance_float(obj, "set_maxAngularVelocity", g_expRigidbodyMaxAngularVelocity);
        else if ([key isEqualToString:@"RigidbodyMaxLinearVelocity"]) mt_call_instance_float(obj, "set_maxLinearVelocity", g_expRigidbodyMaxLinearVelocity);
        else if ([key isEqualToString:@"RigidbodyInterpolation"]) mt_call_instance_int(obj, "set_interpolation", g_expRigidbodyInterpolation);
        else if ([key isEqualToString:@"RigidbodyDetectCollisions"]) mt_call_instance_bool(obj, "set_detectCollisions", g_expRigidbodyDetectCollisions);
        else if ([key isEqualToString:@"Rigidbody2DLinearDamping"]) mt_call_instance_float(obj, "set_linearDamping", g_expRigidbody2DLinearDamping);
        else if ([key isEqualToString:@"Rigidbody2DAngularDamping"]) mt_call_instance_float(obj, "set_angularDamping", g_expRigidbody2DAngularDamping);
        else if ([key isEqualToString:@"Rigidbody2DGravityScale"]) mt_call_instance_float(obj, "set_gravityScale", g_expRigidbody2DGravityScale);
        else if ([key isEqualToString:@"Rigidbody2DInterpolation"]) mt_call_instance_int(obj, "set_interpolation", g_expRigidbody2DInterpolation);
        else if ([key isEqualToString:@"Rigidbody2DSleepMode"]) mt_call_instance_int(obj, "set_sleepMode", g_expRigidbody2DSleepMode);
        else if ([key isEqualToString:@"Rigidbody2DCollisionDetectionMode"]) mt_call_instance_int(obj, "set_collisionDetectionMode", g_expRigidbody2DCollisionDetectionMode);
        else { handled = NO; break; }
    }
    return handled;
}

#pragma mark - Settings application

static void *zs_get_burst_options(void) {
    void *klass = mt_class("Unity.Burst", "BurstCompiler", "Unity.Burst");
    if (!klass) klass = mt_class("Unity.Burst", "BurstCompiler", "Unity.Burst.dll");
    void *options = NULL;
    if (klass && [IL2CppBridge copyStaticFieldOnClass:klass name:"Options" toBuffer:&options] && options) return options;
    return NULL;
}

static void zs_apply_burst_settings(void) {
    void *options = zs_get_burst_options();
    if (!options) return;
    mt_call_instance_bool(options, "set_EnableBurstCompilation", g_expBurstCompilation);
    mt_call_instance_bool(options, "set_EnableBurstSafetyChecks", g_expBurstSafetyChecks);
}

static void zs_apply_rigidbody_settings(void) {
    void *resources = mt_class("UnityEngine", "Resources", "CoreModule");
    const void *find = mt_method(resources, "FindObjectsOfTypeAll", 1);
    if (!find) return;

    const char *classes[] = { "Rigidbody", "Rigidbody2D" };
    void *types[2] = {
        mt_class("UnityEngine", classes[0], "PhysicsModule"),
        mt_class("UnityEngine", classes[1], "Physics2DModule")
    };

    for (int c = 0; c < 2; c++) {
        if (!types[c]) continue;
        void *typeObj = [IL2CppBridge reflectionTypeForClass:types[c]];
        if (!typeObj) continue;
        void *args[1] = { typeObj };
        void *exc = NULL;
        void *array = [IL2CppBridge invokeMethod:find onInstance:NULL args:args outException:&exc];
        if (exc || !array) continue;
        uintptr_t count = *(uintptr_t *)((uint8_t *)array + 0x18);
        for (uintptr_t i = 0; i < count; i++) {
            void *obj = zs_array_object_at(array, (NSUInteger)i);
            if (!obj) continue;
            if (c == 0) {
                mt_call_instance_int(obj, "set_solverIterations", g_expRigidbodySolverIterations);
                mt_call_instance_int(obj, "set_solverVelocityIterations", g_expRigidbodySolverVelocityIterations);
                mt_call_instance_float(obj, "set_sleepThreshold", g_expRigidbodySleepThreshold);
                mt_call_instance_float(obj, "set_maxAngularVelocity", g_expRigidbodyMaxAngularVelocity);
                if (g_expRigidbodyMaxLinearVelocity > 0.0f) mt_call_instance_float(obj, "set_maxLinearVelocity", g_expRigidbodyMaxLinearVelocity);
                mt_call_instance_int(obj, "set_interpolation", g_expRigidbodyInterpolation);
                mt_call_instance_bool(obj, "set_detectCollisions", g_expRigidbodyDetectCollisions);
            } else {
                mt_call_instance_float(obj, "set_linearDamping", g_expRigidbody2DLinearDamping);
                mt_call_instance_float(obj, "set_angularDamping", g_expRigidbody2DAngularDamping);
                mt_call_instance_float(obj, "set_gravityScale", g_expRigidbody2DGravityScale);
                mt_call_instance_int(obj, "set_interpolation", g_expRigidbody2DInterpolation);
                mt_call_instance_int(obj, "set_sleepMode", g_expRigidbody2DSleepMode);
                mt_call_instance_int(obj, "set_collisionDetectionMode", g_expRigidbody2DCollisionDetectionMode);
            }
        }
    }
}

static void zs_apply_adaptive_physics_setting(void) {
    void *settingsClass = mt_class("UnityEngine.AdaptivePerformance", "AdaptivePerformanceScalerSettings", "AdaptivePerformanceModule");
    if (!settingsClass) return;
    void *settings = mt_get_static_instance("UnityEngine.AdaptivePerformance", "AdaptivePerformanceScalerSettings", "AdaptivePerformanceModule", "get_instance");
    if (!settings) settings = mt_get_static_instance("UnityEngine.AdaptivePerformance", "AdaptivePerformanceScalerSettings", "AdaptivePerformanceModule", "get_Instance");
    if (!settings) return;
    const void *getter = mt_method([IL2CppBridge classOfInstance:settings], "get_AdaptivePhysics", 0);
    if (!getter) return;
    void *exc = NULL;
    void *scaler = [IL2CppBridge invokeMethod:getter onInstance:settings args:NULL outException:&exc];
    if (exc || !scaler) return;
    mt_call_instance_bool(scaler, "set_Enabled", g_expAdaptivePhysics);
    mt_call_instance_bool(scaler, "set_enabled", g_expAdaptivePhysics);
}

static BOOL zs_key_is_urp_backed(NSString *key) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"OpaqueTexture", @"URPHDR", @"URPMSAA", @"UpscalingFilter", @"FSROverride", @"FSRSharpness",
            @"MainLightMode", @"MainLightShadows", @"MainShadowResolution", @"AdditionalLightMode",
            @"MaxAdditionalLights", @"AdditionalLightShadows", @"AdditionalShadowResolution",
            @"ReflectionProbeBlending", @"ReflectionProbeBoxProjection", @"ReflectionProbeAtlas",
            @"ShEvalMode", @"LightProbeSystem", @"ProbeVolumeMemoryBudget", @"ProbeVolumeBlendingMemoryBudget",
            @"SoftShadowQuality", @"ShadowDistance", @"ShadowCascades", @"CascadeBorder",
            @"ShadowDepthBias", @"ShadowNormalBias", @"SoftShadows", @"DynamicBatching", @"SRPBatcher",
            @"ColorGradingMode", @"ColorGradingLUTSize", @"AdaptivePerformance", @"GPUResidentDrawerMode",
            @"GPUResidentOcclusion", @"SmallMeshScreenPercentage", @"IntermediateTextureMode",
            @"StoreActionsOptimization", @"ShadowCascadeOption", @"ConservativeEnclosingSphere",
            @"NumIterationsEnclosingSphere", @"ShaderVariantLogLevel",
        ]];
    });
    return [keys containsObject:key] || [key hasPrefix:@"ProbeVolume"]
        || [key hasPrefix:@"AdditionalShadowTier"] || [key hasPrefix:@"Cascade"];
}

static BOOL zs_exp_apply_key_internal(NSString *key) {
    if (!key.length) return NO;

    if ([key isEqualToString:@"PixelLightCount"]) return mt_call_static_int("UnityEngine", "QualitySettings", "CoreModule", "set_pixelLightCount", g_expPixelLightCount);
    if ([key isEqualToString:@"LODBias"]) return mt_call_static_float("UnityEngine", "QualitySettings", "CoreModule", "set_lodBias", g_expLODBias);
    if ([key isEqualToString:@"LODCrossFade"]) return mt_call_static_bool("UnityEngine", "QualitySettings", "CoreModule", "set_enableLODCrossFade", g_expLODCrossFade);
    if ([key isEqualToString:@"VSyncCount"]) return mt_call_static_int("UnityEngine", "QualitySettings", "CoreModule", "set_vSyncCount", g_expVSyncCount);
    if ([key isEqualToString:@"QualityAA"]) return mt_call_static_int("UnityEngine", "QualitySettings", "CoreModule", "set_antiAliasing", g_expQualityAA);

    if ([key hasPrefix:@"Camera"] || [key isEqualToString:@"DynamicResolution"] || [key isEqualToString:@"OcclusionCulling"] || [key isEqualToString:@"DepthTexture"]) {
        void *camera = mt_get_static_instance("UnityEngine", "Camera", "CoreModule", "get_main");
        if (!camera) camera = mt_get_static_instance("UnityEngine", "Camera", "CoreModule", "get_current");
        if (!camera) return NO;
        if ([key isEqualToString:@"CameraHDR"]) return mt_call_instance_bool(camera, "set_allowHDR", g_expCameraHDR);
        if ([key isEqualToString:@"CameraMSAA"]) return mt_call_instance_bool(camera, "set_allowMSAA", g_expCameraMSAA);
        if ([key isEqualToString:@"DynamicResolution"]) return mt_call_instance_bool(camera, "set_allowDynamicResolution", g_expDynamicResolution);
        if ([key isEqualToString:@"OcclusionCulling"]) return mt_call_instance_bool(camera, "set_useOcclusionCulling", g_expOcclusionCulling);
        if ([key isEqualToString:@"DepthTexture"]) return mt_call_instance_int(camera, "set_depthTextureMode", g_expDepthTexture ? 1 : 0);
        return NO;
    }

    if (zs_key_is_urp_backed(key)) {
        void *urp = zs_get_urp_asset();
        if (!urp) return NO;
#define UB(k, setter, var) if ([key isEqualToString:k]) return mt_call_instance_bool(urp, setter, var)
#define UI(k, setter, var) if ([key isEqualToString:k]) return mt_call_instance_int(urp, setter, var)
#define UF(k, setter, var) if ([key isEqualToString:k]) return mt_call_instance_float(urp, setter, var)
        UB(@"OpaqueTexture", "set_supportsCameraOpaqueTexture", g_expOpaqueTexture);
        UB(@"URPHDR", "set_supportsHDR", g_expURPHDR);
        UI(@"URPMSAA", "set_msaaSampleCount", g_expURPMSAA);
        UI(@"UpscalingFilter", "set_upscalingFilter", g_expUpscalingFilter);
        UB(@"FSROverride", "set_fsrOverrideSharpness", g_expFSROverride);
        UF(@"FSRSharpness", "set_fsrSharpness", g_expFSRSharpness);
        UI(@"MainLightMode", "set_mainLightRenderingMode", g_expMainLightMode);
        UB(@"MainLightShadows", "set_supportsMainLightShadows", g_expMainLightShadows);
        UI(@"MainShadowResolution", "set_mainLightShadowmapResolution", g_expMainShadowResolution);
        UI(@"AdditionalLightMode", "set_additionalLightsRenderingMode", g_expAdditionalLightMode);
        UI(@"MaxAdditionalLights", "set_maxAdditionalLightsCount", g_expMaxAdditionalLights);
        UB(@"AdditionalLightShadows", "set_supportsAdditionalLightShadows", g_expAdditionalLightShadows);
        UI(@"AdditionalShadowResolution", "set_additionalLightsShadowmapResolution", g_expAdditionalShadowResolution);
        UB(@"ReflectionProbeBlending", "set_reflectionProbeBlending", g_expReflectionProbeBlending);
        UB(@"ReflectionProbeBoxProjection", "set_reflectionProbeBoxProjection", g_expReflectionProbeBoxProjection);
        UB(@"ReflectionProbeAtlas", "set_reflectionProbeAtlas", g_expReflectionProbeAtlas);
        UI(@"ShEvalMode", "set_shEvalMode", g_expShEvalMode);
        UI(@"LightProbeSystem", "set_lightProbeSystem", g_expLightProbeSystem);
        UI(@"ProbeVolumeMemoryBudget", "set_probeVolumeMemoryBudget", g_expProbeVolumeMemoryBudget);
        UI(@"ProbeVolumeBlendingMemoryBudget", "set_probeVolumeBlendingMemoryBudget", g_expProbeVolumeBlendingMemoryBudget);
        UB(@"ProbeVolumeStreaming", "set_supportProbeVolumeStreaming", g_expProbeVolumeStreaming);
        UB(@"ProbeVolumeGPUStreaming", "set_supportProbeVolumeGPUStreaming", g_expProbeVolumeGPUStreaming);
        UB(@"ProbeVolumeDiskStreaming", "set_supportProbeVolumeDiskStreaming", g_expProbeVolumeDiskStreaming);
        UB(@"ProbeVolumeScenarios", "set_supportProbeVolumeScenarios", g_expProbeVolumeScenarios);
        UB(@"ProbeVolumeScenarioBlending", "set_supportProbeVolumeScenarioBlending", g_expProbeVolumeScenarioBlending);
        UI(@"ProbeVolumeSHBands", "set_probeVolumeSHBands", g_expProbeVolumeSHBands);
        UI(@"AdditionalShadowTierLow", "set_additionalLightsShadowResolutionTierLow", g_expAdditionalShadowTierLow);
        UI(@"AdditionalShadowTierMedium", "set_additionalLightsShadowResolutionTierMedium", g_expAdditionalShadowTierMedium);
        UI(@"AdditionalShadowTierHigh", "set_additionalLightsShadowResolutionTierHigh", g_expAdditionalShadowTierHigh);
        UI(@"SoftShadowQuality", "set_softShadowQuality", g_expSoftShadowQuality);
        UF(@"ShadowDistance", "set_shadowDistance", g_expShadowDistance);
        UI(@"ShadowCascades", "set_shadowCascadeCount", g_expShadowCascades);
        UF(@"CascadeBorder", "set_cascadeBorder", g_expCascadeBorder);
        UF(@"ShadowDepthBias", "set_shadowDepthBias", g_expShadowDepthBias);
        UF(@"ShadowNormalBias", "set_shadowNormalBias", g_expShadowNormalBias);
        UB(@"SoftShadows", "set_supportsSoftShadows", g_expSoftShadows);
        UB(@"DynamicBatching", "set_supportsDynamicBatching", g_expDynamicBatching);
        UB(@"SRPBatcher", "set_useSRPBatcher", g_expSRPBatcher);
        UI(@"ColorGradingMode", "set_colorGradingMode", g_expColorGradingMode);
        UI(@"ColorGradingLUTSize", "set_colorGradingLutSize", g_expColorGradingLUTSize);
        UB(@"AdaptivePerformance", "set_useAdaptivePerformance", g_expAdaptivePerformance);
        UI(@"GPUResidentDrawerMode", "set_gpuResidentDrawerMode", g_expGPUResidentDrawerMode);
        UB(@"GPUResidentOcclusion", "set_gpuResidentDrawerEnableOcclusionCullingInCameras", g_expGPUResidentOcclusion);
        UF(@"SmallMeshScreenPercentage", "set_smallMeshScreenPercentage", g_expSmallMeshScreenPercentage);
        UI(@"IntermediateTextureMode", "set_intermediateTextureMode", g_expIntermediateTextureMode);
        UI(@"StoreActionsOptimization", "set_storeActionsOptimization", g_expStoreActionsOptimization);
        UI(@"ShadowCascadeOption", "set_shadowCascadeOption", g_expShadowCascadeOption);
        UB(@"ConservativeEnclosingSphere", "set_conservativeEnclosingSphere", g_expConservativeEnclosingSphere);
        UI(@"NumIterationsEnclosingSphere", "set_numIterationsEnclosingSphere", g_expNumIterationsEnclosingSphere);
        UI(@"ShaderVariantLogLevel", "set_shaderVariantLogLevel", g_expShaderVariantLogLevel);
#undef UF
#undef UI
#undef UB
        return NO;
    }

    if ([key isEqualToString:@"RenderTextureMemorylessMode"]) { zs_apply_render_texture_memoryless(); return YES; }

    if ([key isEqualToString:@"GraphicsSRPBatching"]) return mt_call_static_bool("UnityEngine.Rendering", "GraphicsSettings", "CoreModule", "set_useScriptableRenderPipelineBatching", g_expGraphicsSRPBatching);
    if ([key isEqualToString:@"LightsUseLinearIntensity"]) return mt_call_static_bool("UnityEngine.Rendering", "GraphicsSettings", "CoreModule", "set_lightsUseLinearIntensity", g_expLightsUseLinearIntensity);
    if ([key isEqualToString:@"LightsUseColorTemperature"]) return mt_call_static_bool("UnityEngine.Rendering", "GraphicsSettings", "CoreModule", "set_lightsUseColorTemperature", g_expLightsUseColorTemperature);

    if ([key hasPrefix:@"AP"]) {
        if ([key isEqualToString:@"APMaxShadowDistanceMultiplier"]) return mt_call_static_float("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_MaxShadowDistanceMultiplier", g_expAPMaxShadowDistanceMultiplier);
        if ([key isEqualToString:@"APShadowmapResolutionMultiplier"]) return mt_call_static_float("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_MainLightShadowmapResolutionMultiplier", g_expAPShadowmapResolutionMultiplier);
        if ([key isEqualToString:@"APRenderScaleMultiplier"]) return mt_call_static_float("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_RenderScaleMultiplier", g_expAPRenderScaleMultiplier);
        if ([key isEqualToString:@"APDecalsDrawDistance"]) return mt_call_static_float("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_DecalsDrawDistance", g_expAPDecalsDrawDistance);
        if ([key isEqualToString:@"APShadowCascadesBias"]) return mt_call_static_int("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_MainLightShadowCascadesCountBias", g_expAPShadowCascadesBias);
        if ([key isEqualToString:@"APShadowQualityBias"]) return mt_call_static_int("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_ShadowQualityBias", g_expAPShadowQualityBias);
        if ([key isEqualToString:@"APLutBias"]) return mt_call_static_float("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_LutBias", g_expAPLutBias);
        if ([key isEqualToString:@"APAntiAliasingQualityBias"]) return mt_call_static_int("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_AntiAliasingQualityBias", g_expAPAntiAliasingQualityBias);
        if ([key isEqualToString:@"APSkipDynamicBatching"]) return mt_call_static_bool("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_SkipDynamicBatching", g_expAPSkipDynamicBatching);
        if ([key isEqualToString:@"APSkipFrontToBackSorting"]) return mt_call_static_bool("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_SkipFrontToBackSorting", g_expAPSkipFrontToBackSorting);
        if ([key isEqualToString:@"APSkipTransparentObjects"]) return mt_call_static_bool("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule", "set_SkipTransparentObjects", g_expAPSkipTransparentObjects);
    }

    if ([key hasPrefix:@"Particle"]) return zs_particle_apply_key_internal(key);
    if ([key hasPrefix:@"Animator"]) return zs_apply_animator_key(key);
    if ([key hasPrefix:@"Rigidbody"]) return zs_apply_rigidbody_key(key);
    if ([key isEqualToString:@"BurstCompilation"] || [key isEqualToString:@"BurstSafetyChecks"]) { zs_apply_burst_settings(); return YES; }
    if ([key isEqualToString:@"AdaptivePhysics"]) { zs_apply_adaptive_physics_setting(); return YES; }

    return NO;
}

BOOL zs_exp_key_class_available(NSString *key) {
    if (!key.length) return YES;

    if ([key isEqualToString:@"PixelLightCount"] || [key isEqualToString:@"LODBias"] ||
        [key isEqualToString:@"LODCrossFade"] || [key isEqualToString:@"VSyncCount"] ||
        [key isEqualToString:@"QualityAA"]) {
        return mt_class("UnityEngine", "QualitySettings", "CoreModule") != NULL;
    }

    if ([key hasPrefix:@"Camera"] || [key isEqualToString:@"DynamicResolution"] ||
        [key isEqualToString:@"OcclusionCulling"] || [key isEqualToString:@"DepthTexture"]) {
        return mt_class("UnityEngine", "Camera", "CoreModule") != NULL;
    }

    if (zs_key_is_urp_backed(key)) {
        return zs_get_urp_asset() != NULL;
    }

    if ([key isEqualToString:@"RenderTextureMemorylessMode"]) {
        return mt_class("UnityEngine", "RenderTexture", "CoreModule") != NULL;
    }

    if ([key isEqualToString:@"GraphicsSRPBatching"] || [key isEqualToString:@"LightsUseLinearIntensity"] ||
        [key isEqualToString:@"LightsUseColorTemperature"]) {
        return mt_class("UnityEngine.Rendering", "GraphicsSettings", "CoreModule") != NULL;
    }

    if ([key hasPrefix:@"AP"]) {
        return mt_class("UnityEngine.AdaptivePerformance", "AdaptivePerformanceRenderSettings", "AdaptivePerformanceModule") != NULL;
    }

    if ([key hasPrefix:@"Particle"]) return zs_particle_key_class_available(key);

    if ([key hasPrefix:@"Animator"]) {
        return mt_class("UnityEngine", "Animator", "AnimationModule") != NULL;
    }

    if ([key hasPrefix:@"Rigidbody2D"]) {
        return mt_class("UnityEngine", "Rigidbody2D", "Physics2DModule") != NULL;
    }
    if ([key hasPrefix:@"Rigidbody"]) {
        return mt_class("UnityEngine", "Rigidbody", "PhysicsModule") != NULL;
    }

    if ([key isEqualToString:@"BurstCompilation"] || [key isEqualToString:@"BurstSafetyChecks"]) {
        void *klass = mt_class("Unity.Burst", "BurstCompiler", "Unity.Burst");
        if (!klass) klass = mt_class("Unity.Burst", "BurstCompiler", "Unity.Burst.dll");
        return klass != NULL;
    }

    if ([key isEqualToString:@"AdaptivePhysics"]) {
        return mt_class("UnityEngine.AdaptivePerformance", "AdaptivePerformanceScalerSettings", "AdaptivePerformanceModule") != NULL;
    }

    if ([key isEqualToString:@"GeneralRenderScale"] || [key isEqualToString:@"GeneralMSAA"] ||
        [key isEqualToString:@"GeneralBloom"]) {
        return zs_get_urp_asset() != NULL;
    }

    if ([key isEqualToString:@"GeneralTextureMip"]) {
        return mt_class("UnityEngine", "QualitySettings", "CoreModule") != NULL;
    }

    if ([key isEqualToString:@"GeneralAAMode"] || [key isEqualToString:@"GeneralAAQuality"] ||
        [key isEqualToString:@"GeneralDithering"]) {
        return mt_class("UnityEngine", "Camera", "CoreModule") != NULL
            && mt_class("UnityEngine.Rendering.Universal", "UniversalAdditionalCameraData", "Universal.Runtime") != NULL;
    }

    if ([key isEqualToString:@"GeneralMotionBlur"]) {
        return mt_class("UnityEngine.Rendering.Universal", "MotionBlur", "Universal.Runtime") != NULL;
    }

    if ([key isEqualToString:@"GeneralTonemap"]) {
        return mt_class("UnityEngine.Rendering.Universal", "Tonemapping", "Universal.Runtime") != NULL;
    }

    return YES;
}

BOOL zs_urp_effect_class_available(NSString *engineName) {
    if (!engineName.length) return YES;
    return mt_class("UnityEngine.Rendering.Universal", engineName.UTF8String, "Universal.Runtime") != NULL;
}

void zs_exp_apply_key(NSString *key) {
    @autoreleasepool {
        @try {
            BOOL applied = zs_exp_apply_key_internal(key);
            if (!applied && key.length) {
                ZLog(@"[ZSMemoryTweaks] Experimental key %@ has no safe runtime operation; state saved only", key);
            }
        } @catch (NSException *exception) {
            ZLog(@"[ZSMemoryTweaks] Experimental key %@ failed safely: %@", key, exception.reason);
        }
    }
}

#pragma mark - BattleResourceLoader portrait cache

void zs_clear_guide_portrait_cache(void) {
    void *klass = mt_class("", "BattleResourceLoader", "Assembly-CSharp");
    if (!klass) return;
    void *instance = NULL;
    const char *getters[] = { "get_Instance", "get_instance" };
    for (NSUInteger i = 0; i < 2 && !instance; i++) {
        const void *getter = mt_method(klass, getters[i], 0);
        if (!getter) continue;
        void *exc = NULL;
        instance = [IL2CppBridge invokeMethod:getter onInstance:NULL args:NULL outException:&exc];
        if (exc) instance = NULL;
    }
    if (!instance) return;
    int32_t off = [IL2CppBridge fieldOffsetOnClass:klass name:"_abGuidePortraitCache"];
    if (off < 0) return;
    void *dict = *(void **)((uint8_t *)instance + off);
    if (!dict) return;
    const void *clear = mt_method([IL2CppBridge classOfInstance:dict], "Clear", 0);
    if (!clear) return;
    void *exc = NULL;
    [IL2CppBridge invokeMethod:clear onInstance:dict args:NULL outException:&exc];
}

#pragma mark - Global Scene State

static void *gZSGlobalGameManagerClass;
static void *gZSGlobalSceneStateField;

BOOL ZSGlobalScene_Current(int32_t *outState) {
    if (!gZSGlobalGameManagerClass) {
        gZSGlobalGameManagerClass = [IL2CppBridge classNamed:"GlobalGameManager" inNamespace:"" assemblyContains:"Assembly-CSharp"];
        if (!gZSGlobalGameManagerClass) return NO;
    }

    void *instance = NULL;
    if (![IL2CppBridge copyStaticFieldOnClass:gZSGlobalGameManagerClass name:"_instance" toBuffer:&instance] || !instance) return NO;

    if (!gZSGlobalSceneStateField) {
        gZSGlobalSceneStateField = [IL2CppBridge fieldNamed:"sceneState" onClass:gZSGlobalGameManagerClass];
        if (!gZSGlobalSceneStateField) return NO;
    }

    int32_t state = -1;
    if (![IL2CppBridge copyInstanceFieldValue:gZSGlobalSceneStateField onInstance:instance toBuffer:&state]) return NO;

    *outState = state;
    return YES;
}

NSString *ZSGlobalSceneState_Name(int32_t state) {
    switch (state) {
        case ZSGlobalSceneStateLogin: return @"Login";
        case ZSGlobalSceneStateBattle: return @"Battle";
        case ZSGlobalSceneStateMain: return @"Main";
        case ZSGlobalSceneStateStory: return @"Story";
        case ZSGlobalSceneStateDungeon: return @"Dungeon";
        case ZSGlobalSceneStateMirrorDungeon: return @"MirrorDungeon";
        case ZSGlobalSceneStateRailwayDungeon: return @"RailwayDungeon";
        case ZSGlobalSceneStateStoryMirrorDungeon: return @"StoryMirrorDungeon";
        case ZSGlobalSceneStateProjectGS: return @"ProjectGS";
        case ZSGlobalSceneStateRpg: return @"Rpg";
        default: return @"Unknown";
    }
}

#pragma mark - Custom Greeting Text

static NSString * const kZSMiscSettingsSection = @"misc";
static NSString * const kZSCustomGreetingTextKey = @"customGreetingText";

static NSString *gZSCustomGreetingTextCache;
static BOOL gZSCustomGreetingTextCacheLoaded;

NSString *zs_custom_greeting_text(void) {
    if (!gZSCustomGreetingTextCacheLoaded) {
        NSDictionary *section = zs_settings_section(kZSMiscSettingsSection);
        id stored = section[kZSCustomGreetingTextKey];
        gZSCustomGreetingTextCache = [stored isKindOfClass:[NSString class]] ? stored : @"";
        gZSCustomGreetingTextCacheLoaded = YES;
    }
    return gZSCustomGreetingTextCache;
}

void zs_set_custom_greeting_text(NSString *text) {
    NSString *safe = [(text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableDictionary *section = [zs_settings_section(kZSMiscSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSCustomGreetingTextKey] = safe;
    zs_write_settings_section(kZSMiscSettingsSection, section);
    gZSCustomGreetingTextCache = safe;
    gZSCustomGreetingTextCacheLoaded = YES;

    ZSCustomGreeting_HotFieldInvalidate();
}

static void *gZSGreetingCardClass;
static void *gZSGreetingUnityObjectClass;
static const void *gZSGreetingFindObjectOfTypeMethod;

static void *gZSGreetingCardInstance;
static void *gZSGreetingTMPInstance;
static const void *gZSGreetingGetText;
static const void *gZSGreetingSetText;
static void *gZSGreetingLastWrittenString;

static int gZSGreetingResolveFailStreak;
static const int kZSGreetingResolveRetryThrottleTicks = 30;

static void ZSCustomGreeting_HotFieldInvalidate(void) {
    gZSGreetingCardInstance = NULL;
    gZSGreetingTMPInstance = NULL;
    gZSGreetingGetText = NULL;
    gZSGreetingSetText = NULL;
    gZSGreetingLastWrittenString = NULL;
    gZSGreetingResolveFailStreak = 0;
}

static void *ZSCustomGreeting_FindActiveInstance(void *klass) {
    if (!klass) return NULL;

    if (!gZSGreetingUnityObjectClass) {
        gZSGreetingUnityObjectClass = [IL2CppBridge classNamed:"Object" inNamespace:"UnityEngine" assemblyContains:"CoreModule"];
        if (!gZSGreetingUnityObjectClass) return NULL;
    }
    if (!gZSGreetingFindObjectOfTypeMethod) {
        gZSGreetingFindObjectOfTypeMethod = [IL2CppBridge methodOnClass:gZSGreetingUnityObjectClass name:"FindObjectOfType" argCount:2];
        if (!gZSGreetingFindObjectOfTypeMethod) return NULL;
    }

    void *typeObj = [IL2CppBridge reflectionTypeForClass:klass];
    if (!typeObj) return NULL;

    BOOL includeInactive = NO;
    void *exc = NULL;
    void *args[2] = { typeObj, &includeInactive };
    void *instance = [IL2CppBridge invokeMethod:gZSGreetingFindObjectOfTypeMethod onInstance:NULL args:args outException:&exc];
    return exc ? NULL : instance;
}

static BOOL ZSCustomGreeting_InstanceIsSelfCard(void *instance, void *klass) {
    void *field = [IL2CppBridge fieldNamed:"_isSelf" onClass:klass];
    if (!field) return NO;

    BOOL isSelf = NO;
    if (![IL2CppBridge copyInstanceFieldValue:field onInstance:instance toBuffer:&isSelf]) return NO;
    return isSelf;
}

static BOOL ZSCustomGreeting_HotFieldResolve(void) {
    if (!gZSGreetingCardClass) {
        gZSGreetingCardClass = [IL2CppBridge classNamed:"UserInfoCard"
                                             inNamespace:"MainUI"
                                        assemblyContains:"Assembly-CSharp"];
        if (!gZSGreetingCardClass) return NO;
    }

    void *card = ZSCustomGreeting_FindActiveInstance(gZSGreetingCardClass);
    if (!card) return NO;

    if (!ZSCustomGreeting_InstanceIsSelfCard(card, gZSGreetingCardClass)) return NO;

    void *field = [IL2CppBridge fieldNamed:"tmp_introduction" onClass:gZSGreetingCardClass];
    if (!field) return NO;

    void *tmp = NULL;
    if (![IL2CppBridge copyInstanceFieldValue:field onInstance:card toBuffer:&tmp] || !tmp) return NO;

    void *tmpClass = [IL2CppBridge classOfInstance:tmp];
    if (!tmpClass) return NO;

    const void *getText = [IL2CppBridge methodOnClass:tmpClass name:"get_text" argCount:0];
    const void *setText = [IL2CppBridge methodOnClass:tmpClass name:"set_text" argCount:1];
    if (!getText || !setText) return NO;

    gZSGreetingCardInstance = card;
    gZSGreetingTMPInstance = tmp;
    gZSGreetingGetText = getText;
    gZSGreetingSetText = setText;
    gZSGreetingLastWrittenString = NULL;
    return YES;
}

static void ZSCustomGreeting_ApplyText(NSString *text) {
    void *converted = [IL2CppBridge il2CppStringFromNSString:text];
    if (!converted) return;

    void *args[1] = { converted };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:gZSGreetingSetText onInstance:gZSGreetingTMPInstance args:args outException:&exc];
    if (exc) { ZSCustomGreeting_HotFieldInvalidate(); return; }
    gZSGreetingLastWrittenString = converted;
}

static int32_t gZSGreetingLastSceneState = -1;

static void ZSCustomGreeting_Tick(void) {
    NSString *customText = zs_custom_greeting_text();
    if (customText.length == 0) return;

    int32_t sceneState = ZSGlobalSceneStateMain;
    BOOL sceneStateKnown = ZSGlobalScene_Current(&sceneState);

    if (sceneStateKnown && sceneState != gZSGreetingLastSceneState) {
        gZSGreetingLastSceneState = sceneState;
        ZSCustomGreeting_HotFieldInvalidate();
    }

    if (sceneStateKnown && sceneState != ZSGlobalSceneStateMain) return;

    if (!gZSGreetingTMPInstance) {
        if (gZSGreetingResolveFailStreak > 0) {
            gZSGreetingResolveFailStreak = (gZSGreetingResolveFailStreak + 1) % kZSGreetingResolveRetryThrottleTicks;
            return;
        }
        if (!ZSCustomGreeting_HotFieldResolve()) {
            gZSGreetingResolveFailStreak = 1;
            return;
        }
    }

    void *getExc = NULL;
    void *current = [IL2CppBridge invokeMethod:gZSGreetingGetText onInstance:gZSGreetingTMPInstance args:NULL outException:&getExc];
    if (getExc) { ZSCustomGreeting_HotFieldInvalidate(); return; }

    if (current == gZSGreetingLastWrittenString) return;

    ZSCustomGreeting_ApplyText(customText);
}

@interface ZSCustomGreetingPatcher : NSObject
@property (nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation ZSCustomGreetingPatcher

+ (instancetype)shared {
    static ZSCustomGreetingPatcher *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [ZSCustomGreetingPatcher new];
    });
    return instance;
}

+ (void)install {
    static BOOL installed;
    @synchronized (self) {
        if (installed) return;
        installed = YES;

        ZSCustomGreetingPatcher *shared = [self shared];
        shared.displayLink = [CADisplayLink displayLinkWithTarget:shared selector:@selector(tick)];
        [shared.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

- (void)tick {
    ZSCustomGreeting_Tick();
}

@end

__attribute__((constructor))
static void ZSCustomGreetingPatcherConstructor(void) {
    [ZSCustomGreetingPatcher install];
}

#pragma mark - UID Redactor

static NSString * const kUIDRedactorSettingsSection = @"uidRedactor";
static NSString * const kUIDRedactorEnabledKey = @"enabled";
static NSString * const kUIDRedactorRedactedText = @"[REDACTED]";

typedef struct {
    const char *namespaze;
    const char *className;
    const char *assemblyContains;
    const char *tmpFieldName;
    BOOL multiInstance;
} ZSUIDTarget;

static const ZSUIDTarget kUIDTargets[] = {
    { "MainUI", "SettingsPanelEtc",                    "Assembly-CSharp", "tmp_accountInfo",      NO  },
    { "MainUI", "ShowIntegrateAccountCodePanel",        "Assembly-CSharp", "tmp_uid",              NO  },
    { "MainUI", "ShowIntegrateCodeUIPopup",             "Assembly-CSharp", "tmp_uid",              NO  },
    { "MainUI", "UserInfoCard",                         "Assembly-CSharp", "tmp_publicIdAlphabet", NO  },
    { "",       "LoginSceneManager",                    "Assembly-CSharp", "tmp_loginAccount",     NO  },
    { "",       "StageStatisticPopupSlotScrollViewItem","Assembly-CSharp", "tmp_uid",              YES },
    { "MainUI", "SelectIntegrateAccountItemObject",     "Assembly-CSharp", "tmp_publicId",         YES },
    { "MainUI", "AskBeforeConfirmIntegratePanel", "Assembly-CSharp", "tmp_id", NO },
};

static const size_t kUIDTargetCount = sizeof(kUIDTargets) / sizeof(kUIDTargets[0]);

static void *gUIDTargetClasses[sizeof(kUIDTargets) / sizeof(kUIDTargets[0])];
static void *gUIDUnityObjectClass;
static const void *gUIDFindObjectOfTypeMethod;
static const void *gUIDFindObjectsOfTypeMethod;

static BOOL gUIDRedactorInstalled;

static void ZSUID_RedactTMPField(void *thisPtr, const char *fieldName) {
    if (!thisPtr) return;

    void *klass = [IL2CppBridge classOfInstance:thisPtr];
    if (!klass) return;

    void *field = [IL2CppBridge fieldNamed:fieldName onClass:klass];
    if (!field) return;

    void *tmp = NULL;
    if (![IL2CppBridge copyInstanceFieldValue:field onInstance:thisPtr toBuffer:&tmp] || !tmp) return;

    void *tmpClass = [IL2CppBridge classOfInstance:tmp];
    if (!tmpClass) return;

    const void *setText = [IL2CppBridge methodOnClass:tmpClass name:"set_text" argCount:1];
    if (!setText) return;

    void *redacted = [IL2CppBridge il2CppStringFromNSString:kUIDRedactorRedactedText];
    if (!redacted) return;

    void *args[1] = { redacted };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:setText onInstance:tmp args:args outException:&exc];
}

static void *ZSUID_FindActiveInstance(void *klass) {
    if (!klass) return NULL;

    if (!gUIDUnityObjectClass) {
        gUIDUnityObjectClass = [IL2CppBridge classNamed:"Object" inNamespace:"UnityEngine" assemblyContains:"CoreModule"];
        if (!gUIDUnityObjectClass) return NULL;
    }
    if (!gUIDFindObjectOfTypeMethod) {
        gUIDFindObjectOfTypeMethod = [IL2CppBridge methodOnClass:gUIDUnityObjectClass name:"FindObjectOfType" argCount:2];
        if (!gUIDFindObjectOfTypeMethod) return NULL;
    }

    void *typeObj = [IL2CppBridge reflectionTypeForClass:klass];
    if (!typeObj) return NULL;

    BOOL includeInactive = NO;
    void *exc = NULL;
    void *args[2] = { typeObj, &includeInactive };
    void *instance = [IL2CppBridge invokeMethod:gUIDFindObjectOfTypeMethod onInstance:NULL args:args outException:&exc];
    return exc ? NULL : instance;
}

static int32_t ZSUID_UnboxInt32(void *boxed) {
    if (!boxed) return 0;
    void *klass = [IL2CppBridge classOfInstance:boxed];
    if (!klass) return 0;
    void *field = [IL2CppBridge fieldNamed:"m_value" onClass:klass];
    if (!field) return 0;
    int32_t value = 0;
    if (![IL2CppBridge copyInstanceFieldValue:field onInstance:boxed toBuffer:&value]) return 0;
    return value;
}

BOOL ZSUID_UnityObjectIsAlive(void *obj) {
    if (!obj) return NO;
    void *klass = [IL2CppBridge classOfInstance:obj];
    if (!klass) return NO;
    void *field = [IL2CppBridge fieldNamed:"m_CachedPtr" onClass:klass];
    if (!field) return YES;
    void *cachedPtr = NULL;
    if (![IL2CppBridge copyInstanceFieldValue:field onInstance:obj toBuffer:&cachedPtr]) return YES;
    return cachedPtr != NULL;
}

static void ZSUID_RedactAllActiveInstances(void *klass, const char *fieldName) {
    if (!klass) return;

    if (!gUIDUnityObjectClass) {
        gUIDUnityObjectClass = [IL2CppBridge classNamed:"Object" inNamespace:"UnityEngine" assemblyContains:"CoreModule"];
        if (!gUIDUnityObjectClass) return;
    }
    if (!gUIDFindObjectsOfTypeMethod) {
        gUIDFindObjectsOfTypeMethod = [IL2CppBridge methodOnClass:gUIDUnityObjectClass name:"FindObjectsOfType" argCount:2];
        if (!gUIDFindObjectsOfTypeMethod) return;
    }

    void *typeObj = [IL2CppBridge reflectionTypeForClass:klass];
    if (!typeObj) return;

    BOOL includeInactive = NO;
    void *exc = NULL;
    void *args[2] = { typeObj, &includeInactive };
    void *array = [IL2CppBridge invokeMethod:gUIDFindObjectsOfTypeMethod onInstance:NULL args:args outException:&exc];
    if (exc || !array) return;

    void *arrayKlass = [IL2CppBridge classOfInstance:array];
    if (!arrayKlass) return;

    const void *getLength = [IL2CppBridge methodOnClass:arrayKlass name:"get_Length" argCount:0];
    const void *getValue  = [IL2CppBridge methodOnClass:arrayKlass name:"GetValue" argCount:1];
    if (!getLength || !getValue) return;

    void *lenExc = NULL;
    void *lengthBoxed = [IL2CppBridge invokeMethod:getLength onInstance:array args:NULL outException:&lenExc];
    if (lenExc) return;
    int32_t count = ZSUID_UnboxInt32(lengthBoxed);

    for (int32_t i = 0; i < count; i++) {
        int32_t idx = i;
        void *itemExc = NULL;
        void *itemArgs[1] = { &idx };
        void *item = [IL2CppBridge invokeMethod:getValue onInstance:array args:itemArgs outException:&itemExc];
        if (!itemExc && item) ZSUID_RedactTMPField(item, fieldName);
    }
}

static const int kUIDHotResolveMaxAttempts = 3;

static void ZSUID_RedactColdTargets(void);

static void *gUIDColdInstance[sizeof(kUIDTargets) / sizeof(kUIDTargets[0])];
static void *gUIDColdTMPInstance[sizeof(kUIDTargets) / sizeof(kUIDTargets[0])];
static const void *gUIDColdSetText[sizeof(kUIDTargets) / sizeof(kUIDTargets[0])];
static void *gUIDColdLastWritten[sizeof(kUIDTargets) / sizeof(kUIDTargets[0])];
static int gUIDColdResolveAttempts[sizeof(kUIDTargets) / sizeof(kUIDTargets[0])];

static const int kUIDColdResolveMaxAttempts = 3;

static void ZSUID_ColdSingleInvalidate(size_t i) {
    gUIDColdInstance[i] = NULL;
    gUIDColdTMPInstance[i] = NULL;
    gUIDColdSetText[i] = NULL;
    gUIDColdLastWritten[i] = NULL;
    gUIDColdResolveAttempts[i] = 0;
}

static BOOL ZSUID_ColdSingleResolve(size_t i) {
    const ZSUIDTarget *target = &kUIDTargets[i];

    if (!gUIDTargetClasses[i]) {
        gUIDTargetClasses[i] = [IL2CppBridge classNamed:target->className
                                             inNamespace:target->namespaze
                                        assemblyContains:target->assemblyContains];
        if (!gUIDTargetClasses[i]) return NO;
    }

    void *instance = ZSUID_FindActiveInstance(gUIDTargetClasses[i]);
    if (!instance) return NO;

    void *field = [IL2CppBridge fieldNamed:target->tmpFieldName onClass:gUIDTargetClasses[i]];
    if (!field) return NO;

    void *tmp = NULL;
    if (![IL2CppBridge copyInstanceFieldValue:field onInstance:instance toBuffer:&tmp] || !tmp) return NO;

    void *tmpClass = [IL2CppBridge classOfInstance:tmp];
    if (!tmpClass) return NO;

    const void *getText = [IL2CppBridge methodOnClass:tmpClass name:"get_text" argCount:0];
    const void *setText = [IL2CppBridge methodOnClass:tmpClass name:"set_text" argCount:1];
    if (!getText || !setText) return NO;

    gUIDColdInstance[i] = instance;
    gUIDColdTMPInstance[i] = tmp;
    gUIDColdSetText[i] = setText;
    gUIDColdLastWritten[i] = NULL;

    void *redacted = [IL2CppBridge il2CppStringFromNSString:kUIDRedactorRedactedText];
    if (!redacted) return NO;
    void *args[1] = { redacted };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:setText onInstance:tmp args:args outException:&exc];
    if (exc) { ZSUID_ColdSingleInvalidate(i); return NO; }
    gUIDColdLastWritten[i] = redacted;
    return YES;
}

static void ZSUID_ColdSingleForceWrite(size_t i) {
    if (gUIDColdTMPInstance[i] && !ZSUID_UnityObjectIsAlive(gUIDColdTMPInstance[i])) {
        ZSUID_ColdSingleInvalidate(i);
    }

    if (!gUIDColdTMPInstance[i]) {
        if (gUIDColdResolveAttempts[i] >= kUIDColdResolveMaxAttempts) return;
        gUIDColdResolveAttempts[i]++;
        ZSUID_ColdSingleResolve(i);
        return;
    }

    void *redacted = [IL2CppBridge il2CppStringFromNSString:kUIDRedactorRedactedText];
    if (!redacted) return;
    void *args[1] = { redacted };
    void *setExc = NULL;
    [IL2CppBridge invokeMethod:gUIDColdSetText[i] onInstance:gUIDColdTMPInstance[i] args:args outException:&setExc];
    if (setExc) { ZSUID_ColdSingleInvalidate(i); return; }
    gUIDColdLastWritten[i] = redacted;
}

static void ZSUID_RedactColdSingleInstanceTargets(void) {
    for (size_t i = 0; i < kUIDTargetCount; i++) {
        if (kUIDTargets[i].multiInstance) continue;
        ZSUID_ColdSingleForceWrite(i);
    }
}

static void ZSUID_RedactColdMultiInstanceTargets(void) {
    for (size_t i = 0; i < kUIDTargetCount; i++) {
        const ZSUIDTarget *target = &kUIDTargets[i];
        if (!target->multiInstance) continue;

        if (!gUIDTargetClasses[i]) {
            gUIDTargetClasses[i] = [IL2CppBridge classNamed:target->className
                                                 inNamespace:target->namespaze
                                            assemblyContains:target->assemblyContains];
            if (!gUIDTargetClasses[i]) continue;
        }

        ZSUID_RedactAllActiveInstances(gUIDTargetClasses[i], target->tmpFieldName);
    }
}

static CFTimeInterval gUIDMultiInstanceLastRunTime;
static BOOL gUIDMultiInstanceRescanPending;
static const CFTimeInterval kUIDMultiInstanceMinInterval = 0.15;

static void ZSUID_ScheduleMultiInstanceRescan(void) {
    if (gUIDMultiInstanceRescanPending) return;
    gUIDMultiInstanceRescanPending = YES;

    CFTimeInterval elapsed = CACurrentMediaTime() - gUIDMultiInstanceLastRunTime;
    CFTimeInterval delay = elapsed >= kUIDMultiInstanceMinInterval ? 0.0 : (kUIDMultiInstanceMinInterval - elapsed);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gUIDMultiInstanceRescanPending = NO;
        gUIDMultiInstanceLastRunTime = CACurrentMediaTime();
        ZSUID_RedactColdMultiInstanceTargets();
    });
}

static void *gUIDHotPanelClass;
static void *gUIDHotPanelInstance;
static void *gUIDHotTMPClass;
static void *gUIDHotTMPInstance;
static const void *gUIDHotGetText;
static const void *gUIDHotSetText;
static void *gUIDHotLastWrittenString;

static int gUIDHotResolveAttempts;

static BOOL gUIDRedactorEnabledCache;
static BOOL gUIDRedactorEnabledCacheLoaded;

static void ZSUID_HotFieldInvalidate(void) {
    for (size_t i = 0; i < kUIDTargetCount; i++) ZSUID_ColdSingleInvalidate(i);
    gUIDHotPanelInstance = NULL;
    gUIDHotTMPInstance = NULL;
    gUIDHotGetText = NULL;
    gUIDHotSetText = NULL;
    gUIDHotLastWrittenString = NULL;
    gUIDHotResolveAttempts = 0;
}

static BOOL ZSUID_HotFieldResolve(void) {
    if (!gUIDHotPanelClass) {
        gUIDHotPanelClass = [IL2CppBridge classNamed:"LowerControlUIPanel"
                                          inNamespace:"MainUI"
                                     assemblyContains:"Assembly-CSharp"];
        if (!gUIDHotPanelClass) return NO;
    }

    void *panel = ZSUID_FindActiveInstance(gUIDHotPanelClass);
    if (!panel) return NO;

    void *field = [IL2CppBridge fieldNamed:"tmp_id" onClass:gUIDHotPanelClass];
    if (!field) return NO;

    void *tmp = NULL;
    if (![IL2CppBridge copyInstanceFieldValue:field onInstance:panel toBuffer:&tmp] || !tmp) return NO;

    void *tmpClass = [IL2CppBridge classOfInstance:tmp];
    if (!tmpClass) return NO;

    const void *getText = [IL2CppBridge methodOnClass:tmpClass name:"get_text" argCount:0];
    const void *setText = [IL2CppBridge methodOnClass:tmpClass name:"set_text" argCount:1];
    if (!getText || !setText) return NO;

    gUIDHotPanelInstance = panel;
    gUIDHotTMPClass = tmpClass;
    gUIDHotTMPInstance = tmp;
    gUIDHotGetText = getText;
    gUIDHotSetText = setText;
    gUIDHotLastWrittenString = NULL;

    void *redacted = [IL2CppBridge il2CppStringFromNSString:kUIDRedactorRedactedText];
    if (!redacted) return NO;
    void *args[1] = { redacted };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:gUIDHotSetText onInstance:gUIDHotTMPInstance args:args outException:&exc];
    if (exc) { ZSUID_HotFieldInvalidate(); return NO; }
    gUIDHotLastWrittenString = redacted;
    return YES;
}

static int32_t gUIDHotLastSceneState = -1;

static void ZSUID_HotFieldTick(void) {
    if (!gUIDRedactorEnabledCacheLoaded) {
        gUIDRedactorEnabledCache = UIDRedactor.isEnabled;
        gUIDRedactorEnabledCacheLoaded = YES;
    }
    if (!gUIDRedactorEnabledCache) return;

    int32_t sceneState = -1;
    BOOL sceneStateKnown = ZSGlobalScene_Current(&sceneState);

    if (!sceneStateKnown || sceneState != ZSGlobalSceneStateMain) {
        if (sceneStateKnown && sceneState != gUIDHotLastSceneState) {
            gUIDHotLastSceneState = sceneState;
            ZSUID_HotFieldInvalidate();
        }
        return;
    }

    if (sceneState != gUIDHotLastSceneState) {
        gUIDHotLastSceneState = sceneState;
        ZSUID_HotFieldInvalidate();
    }

    if (gUIDHotTMPInstance && !ZSUID_UnityObjectIsAlive(gUIDHotTMPInstance)) {
        ZSUID_HotFieldInvalidate();
    }

    if (!gUIDHotTMPInstance) {
        if (gUIDHotResolveAttempts >= kUIDHotResolveMaxAttempts) return;
        gUIDHotResolveAttempts++;
        if (ZSUID_HotFieldResolve()) {
            ZSUID_RedactColdSingleInstanceTargets();
            ZSUID_ScheduleMultiInstanceRescan();
        }
        return;
    }

    void *getExc = NULL;
    void *current = [IL2CppBridge invokeMethod:gUIDHotGetText onInstance:gUIDHotTMPInstance args:NULL outException:&getExc];
    if (getExc) {
        ZSUID_HotFieldInvalidate();
        return;
    }

    if (current == gUIDHotLastWrittenString) return;

    void *redacted = [IL2CppBridge il2CppStringFromNSString:kUIDRedactorRedactedText];
    if (!redacted) return;
    void *args[1] = { redacted };
    void *setExc = NULL;
    [IL2CppBridge invokeMethod:gUIDHotSetText onInstance:gUIDHotTMPInstance args:args outException:&setExc];
    if (setExc) { ZSUID_HotFieldInvalidate(); return; }
    gUIDHotLastWrittenString = redacted;
    ZSUID_RedactColdSingleInstanceTargets();
}

@interface UIDRedactor ()
@property (nonatomic, strong) CADisplayLink *hotFieldLink;
@end

@implementation UIDRedactor

+ (instancetype)shared {
    static UIDRedactor *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [UIDRedactor new];
    });
    return instance;
}

static void ZSUID_RedactColdTargets(void) {
    for (size_t i = 0; i < kUIDTargetCount; i++) {
        const ZSUIDTarget *target = &kUIDTargets[i];

        if (!gUIDTargetClasses[i]) {
            gUIDTargetClasses[i] = [IL2CppBridge classNamed:target->className
                                                 inNamespace:target->namespaze
                                            assemblyContains:target->assemblyContains];
            if (!gUIDTargetClasses[i]) continue;
        }

        if (target->multiInstance) {
            ZSUID_RedactAllActiveInstances(gUIDTargetClasses[i], target->tmpFieldName);
        } else {
            void *instance = ZSUID_FindActiveInstance(gUIDTargetClasses[i]);
            if (instance) ZSUID_RedactTMPField(instance, target->tmpFieldName);
        }
    }
}

+ (void)applyRedaction {
    if (!UIDRedactor.isEnabled) return;

    ZSUID_RedactColdTargets();

    ZSUID_HotFieldInvalidate();
    ZSUID_HotFieldResolve();
}

+ (BOOL)isEnabled {
    NSDictionary *section = zs_settings_section(kUIDRedactorSettingsSection);
    id stored = section[kUIDRedactorEnabledKey];
    return stored ? [stored boolValue] : NO;
}

+ (void)setEnabled:(BOOL)enabled {
    NSMutableDictionary *section = [zs_settings_section(kUIDRedactorSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kUIDRedactorEnabledKey] = @(enabled);
    zs_write_settings_section(kUIDRedactorSettingsSection, section);
    ZLog(@"[UIDRedactor] %@ via Config switch", enabled ? @"enabled" : @"disabled");

    gUIDRedactorEnabledCache = enabled;
    gUIDRedactorEnabledCacheLoaded = YES;

    if (enabled) {
        [self applyRedaction];
    } else {
        ZSUID_HotFieldInvalidate();
    }
}

+ (void)install {
    @synchronized (self) {
        if (gUIDRedactorInstalled) return;
        gUIDRedactorInstalled = YES;

        [self applyRedaction];

        UIDRedactor *shared = [self shared];
        shared.hotFieldLink = [CADisplayLink displayLinkWithTarget:shared selector:@selector(hotFieldTick)];
        [shared.hotFieldLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

- (void)hotFieldTick {
    ZSUID_HotFieldTick();
}

@end

static void *UIDRedactor_WaitForUnityThenInstall(void *arg) {
    (void)arg;

    __block BOOL unityReady = NO;
    while (!unityReady) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            id appController = [[UIApplication sharedApplication] delegate];
            if (appController && find_unity_view(appController)) unityReady = YES;
        });
        if (!unityReady) usleep(200 * 1000);
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        [UIDRedactor install];
    });
    return NULL;
}

__attribute__((constructor))
static void UIDRedactorConstructor(void) {
    pthread_t t;
    pthread_create(&t, NULL, UIDRedactor_WaitForUnityThenInstall, NULL);
    pthread_detach(t);
}

static NSString * const kZSEgoAutoSpeedSection = @"egoAutoSpeed";
static NSString * const kZSEgoAutoSpeedEnabledKey = @"enabled";
static const float kZSEgoAutoSpeedMultiplier = 3.5f;
static const CFTimeInterval kZSEgoAutoSpeedFindInterval = 0.1;

static BOOL gZSEgoEnabled;
static BOOL gZSEgoEnabledLoaded;
static BOOL gZSEgoInstalled;
static BOOL gZSEgoApplied;
static void *gZSEgoViewClass;
static const void *gZSEgoSetDirectorSpeed;
static const void *gZSEgoOnSetSpeed;
static void *gZSEgoLastInstance;
static CFTimeInterval gZSEgoLastFind;

static void ZSEgo_InvokeFloat(const void *method, void *instance, float value) {
    if (!method || !instance) return;
    float v = value;
    void *args[1] = { &v };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:method onInstance:instance args:args outException:&exc];
}

static BOOL ZSEgo_Resolve(void) {
    if (!gZSEgoViewClass) gZSEgoViewClass = mt_class("", "BattleSkillViewEGOBase", "Assembly-CSharp");
    if (!gZSEgoViewClass) return NO;
    if (!gZSEgoSetDirectorSpeed) gZSEgoSetDirectorSpeed = mt_method(gZSEgoViewClass, "SetPlayableDirectorSpeed", 1);
    if (!gZSEgoOnSetSpeed) gZSEgoOnSetSpeed = mt_method(gZSEgoViewClass, "OnSetSpeed", 1);
    return gZSEgoSetDirectorSpeed != NULL;
}

static void ZSEgo_Tick(void) {
    BOOL enabled = [ZSEgoAutoSpeed isEnabled];
    if (!enabled && !gZSEgoApplied) return;

    CFTimeInterval now = CACurrentMediaTime();
    if (now - gZSEgoLastFind < kZSEgoAutoSpeedFindInterval) return;
    gZSEgoLastFind = now;

    if (!ZSEgo_Resolve()) return;

    void *instance = ZSUID_FindActiveInstance(gZSEgoViewClass);

    if (!enabled) {
        if (instance) ZSEgo_InvokeFloat(gZSEgoSetDirectorSpeed, instance, 1.0f);
        gZSEgoApplied = NO;
        gZSEgoLastInstance = NULL;
        return;
    }

    if (!instance) {
        gZSEgoLastInstance = NULL;
        return;
    }

    if (instance != gZSEgoLastInstance) {
        gZSEgoLastInstance = instance;
        ZSEgo_InvokeFloat(gZSEgoOnSetSpeed, instance, kZSEgoAutoSpeedMultiplier);
        ZLog(@"[EgoAutoSpeed] applied %.1fx to new EGO view", kZSEgoAutoSpeedMultiplier);
    }
    ZSEgo_InvokeFloat(gZSEgoSetDirectorSpeed, instance, kZSEgoAutoSpeedMultiplier);
    gZSEgoApplied = YES;
}

@interface ZSEgoAutoSpeed ()
@property (nonatomic, strong) CADisplayLink *link;
@end

@implementation ZSEgoAutoSpeed

+ (instancetype)shared {
    static ZSEgoAutoSpeed *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [ZSEgoAutoSpeed new];
    });
    return instance;
}

+ (BOOL)isEnabled {
    if (!gZSEgoEnabledLoaded) {
        NSDictionary *section = zs_settings_section(kZSEgoAutoSpeedSection);
        id stored = section[kZSEgoAutoSpeedEnabledKey];
        gZSEgoEnabled = stored ? [stored boolValue] : NO;
        gZSEgoEnabledLoaded = YES;
    }
    return gZSEgoEnabled;
}

+ (void)setEnabled:(BOOL)enabled {
    NSMutableDictionary *section = [zs_settings_section(kZSEgoAutoSpeedSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSEgoAutoSpeedEnabledKey] = @(enabled);
    zs_write_settings_section(kZSEgoAutoSpeedSection, section);
    gZSEgoEnabled = enabled;
    gZSEgoEnabledLoaded = YES;
    ZLog(@"[EgoAutoSpeed] %@ via Misc switch", enabled ? @"enabled" : @"disabled");
}

+ (void)install {
    @synchronized (self) {
        if (gZSEgoInstalled) return;
        gZSEgoInstalled = YES;
        ZSEgoAutoSpeed *shared = [self shared];
        shared.link = [CADisplayLink displayLinkWithTarget:shared selector:@selector(tick)];
        [shared.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

- (void)tick {
    ZSEgo_Tick();
}

@end

static void *ZSEgoAutoSpeed_WaitForUnityThenInstall(void *arg) {
    (void)arg;

    __block BOOL unityReady = NO;
    while (!unityReady) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            id appController = [[UIApplication sharedApplication] delegate];
            if (appController && find_unity_view(appController)) unityReady = YES;
        });
        if (!unityReady) usleep(200 * 1000);
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        [ZSEgoAutoSpeed install];
    });
    return NULL;
}

__attribute__((constructor))
static void ZSEgoAutoSpeedConstructor(void) {
    pthread_t t;
    pthread_create(&t, NULL, ZSEgoAutoSpeed_WaitForUnityThenInstall, NULL);
    pthread_detach(t);
}
