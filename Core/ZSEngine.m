#import "ZSEngine.h"
#include <string.h>
#import "IL2CppIntrospection.h"
#import "ZTweakLog.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <math.h>
#include <stdint.h>
#import <mach/mach.h>
#import <os/proc.h>
#import "UnityBundleTools.h"
#import "Mods.h"

#pragma mark - ZSScripts

static void ZSCustomGreeting_HotFieldInvalidate(void);
static void ZSUID_HotFieldInvalidate(void);
static BOOL ZSGlobalScene_Current(int32_t *outState);
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

static NSDictionary *zs_load_file_index_dictionary(void) {
    NSString *path = zs_file_index_file_path();
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        if (error) ZLog(@"[ZSScripts] failed to parse Index.json: %@", error);
        return nil;
    }
    return (NSDictionary *)obj;
}

static void zs_write_file_index_dictionary(NSDictionary *dict) {
    NSString *path = zs_file_index_file_path();
    if (!path) return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    if (error || !data) {
        ZLog(@"[ZSScripts] failed to encode Index.json: %@", error);
        return;
    }
    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        ZLog(@"[ZSScripts] failed to write Index.json: %@", writeError);
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
@property (nonatomic, strong) NSTimer *battleStatePollTimer;
@property (nonatomic, strong) NSTimer *fpsPollTimer;
- (void)applyMenuFPS:(NSInteger)fps;
- (void)applyCombatFPS:(NSInteger)fps;
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
        expected = 30;
    } else {
        int32_t sceneState = 0;
        if (!ZSGlobalScene_Current(&sceneState)) return;
        BOOL isBattle = (sceneState == kSceneStateBattle);
        if (isBattle && self.manualOverrideActiveCombat) return;
        if (!isBattle && self.manualOverrideActiveMenu) return;
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
        if (self.targetFPS != 30) {
            self.targetFPS = 30;
            zs_set_application_target_fps(30);
        }
        return;
    }

    if (isBattle) {
        if (self.manualOverrideActiveCombat) return;
        [self applyTargetFPSIfNeeded:self.combatFPS];
    } else {
        if (self.manualOverrideActiveMenu) return;
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
        self.targetFPS = 30;
        zs_set_application_target_fps(30);
        return;
    }

    NSInteger desired = self.isInBattle ? self.combatFPS : self.menuFPS;
    self.targetFPS = desired;
    zs_set_application_target_fps((int32_t)desired);

    [self battleStatePoll];
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

static void configure_metal_layer(UIView *unityView) {
    if (!unityView) return;
    if (![unityView.layer isKindOfClass:[CAMetalLayer class]]) return;

    CAMetalLayer *metalLayer = (CAMetalLayer *)unityView.layer;
    metalLayer.framebufferOnly = YES;
}

#pragma mark - Startup

static void *background_worker(void *arg) {
    (void)arg;

    __block BOOL fpsReady = NO;
    __block BOOL metalConfigured = NO;

    while (!metalConfigured) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            UIView *unityView = zs_unity_view();
            if (unityView) {
                configure_metal_layer(unityView);
                metalConfigured = YES;
                ZLog(@"Unity view found, Metal layer configured");
            }
        });
        if (!metalConfigured) usleep(200 * 1000);
    }

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

static void zs_run_gc_collect(void) {
    void *gc = mt_class("System", "GC", "mscorlib");
    const void *collect = mt_method(gc, "Collect", 0);
    if (!collect) return;
    void *exc = NULL;
    [IL2CppBridge invokeMethod:collect onInstance:NULL args:NULL outException:&exc];
}

void zs_run_memory_cleanup(void (^completion)(BOOL ran)) {
    if (g_memoryCleanupInFlight) {
        if (completion) completion(NO);
        return;
    }
    g_memoryCleanupInFlight = YES;

    void *resources = mt_class("UnityEngine", "Resources", "CoreModule");
    const void *unload = mt_method(resources, "UnloadUnusedAssets", 0);
    if (unload) {
        void *exc = NULL;
        [IL2CppBridge invokeMethod:unload onInstance:NULL args:NULL outException:&exc];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMemoryCleanupGCDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        zs_run_gc_collect();
        g_memoryCleanupInFlight = NO;
        if (completion) completion(YES);
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

typedef struct {
    const char *ns;
    const char *klassName;
    const char *assembly;
    const char *displayName;
} ZSMemoryUsageCategoryDescriptor;

static const ZSMemoryUsageCategoryDescriptor kZSMemoryUsageCategoryDescriptors[] = {
    {"UnityEngine", "Texture2D", "CoreModule", "Textures"},
    {"UnityEngine", "Cubemap", "CoreModule", "Cubemaps"},
    {"UnityEngine", "Texture2DArray", "CoreModule", "Texture Arrays"},
    {"UnityEngine", "Texture3D", "CoreModule", "3D Textures"},
    {"UnityEngine", "RenderTexture", "CoreModule", "Render Textures"},
    {"UnityEngine", "Mesh", "CoreModule", "Meshes"},
    {"UnityEngine", "Material", "CoreModule", "Materials"},
    {"UnityEngine", "Shader", "CoreModule", "Shaders"},
    {"UnityEngine", "AudioClip", "AudioModule", "Audio Clips"},
    {"UnityEngine", "AnimationClip", "AnimationModule", "Animation Clips"},
    {"UnityEngine", "Sprite", "CoreModule", "Sprites"},
    {"UnityEngine", "Font", "TextRenderingModule", "Fonts"},
};

static void zs_append_subsystem_memory_categories(NSMutableArray<ZSMemoryUsageCategory *> *results, int64_t assetTrackedBytes) {
    int64_t totalAllocated = 0;
    int64_t totalReserved = 0;
    int64_t totalUnusedReserved = 0;
    int64_t monoUsed = 0;
    int64_t monoHeap = 0;
    int64_t graphicsDriverBytes = 0;
    int64_t tempAllocatorBytes = 0;

    BOOL hasTotalAllocated = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetTotalAllocatedMemoryLong", &totalAllocated);
    BOOL hasTotalReserved = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetTotalReservedMemoryLong", &totalReserved);
    BOOL hasUnusedReserved = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetTotalUnusedReservedMemoryLong", &totalUnusedReserved);
    BOOL hasMonoUsed = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetMonoUsedSizeLong", &monoUsed);
    BOOL hasMonoHeap = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetMonoHeapSizeLong", &monoHeap);
    BOOL hasGraphicsDriver = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetAllocatedMemoryForGraphicsDriver", &graphicsDriverBytes);
    BOOL hasTempAllocator = mt_call_static_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetTempAllocatorSize", &tempAllocatorBytes);

    if (hasMonoUsed && monoUsed > 0) {
        ZSMemoryUsageCategory *managedUsed = [ZSMemoryUsageCategory new];
        managedUsed.name = @"Managed Heap (used)";
        managedUsed.totalBytes = monoUsed;
        [results addObject:managedUsed];
    }

    if (hasMonoHeap && hasMonoUsed) {
        int64_t monoFree = monoHeap - monoUsed;
        if (monoFree > 0) {
            ZSMemoryUsageCategory *managedFree = [ZSMemoryUsageCategory new];
            managedFree.name = @"Managed Heap (reserved)";
            managedFree.totalBytes = monoFree;
            [results addObject:managedFree];
        }
    }

    if (hasGraphicsDriver && graphicsDriverBytes > 0) {
        ZSMemoryUsageCategory *gfx = [ZSMemoryUsageCategory new];
        gfx.name = @"Graphics driver (Unity)";
        gfx.totalBytes = graphicsDriverBytes;
        [results addObject:gfx];
    }

    if (hasTempAllocator && tempAllocatorBytes > 0) {
        ZSMemoryUsageCategory *temp = [ZSMemoryUsageCategory new];
        temp.name = @"Temp allocator";
        temp.totalBytes = tempAllocatorBytes;
        [results addObject:temp];
    }

    if (hasTotalAllocated && totalAllocated > 0) {
        int64_t accountedFor = assetTrackedBytes
            + (hasMonoUsed ? monoUsed : 0)
            + (hasGraphicsDriver ? graphicsDriverBytes : 0)
            + (hasTempAllocator ? tempAllocatorBytes : 0);
        int64_t nativeEngine = totalAllocated - accountedFor;
        if (nativeEngine > 0) {
            ZSMemoryUsageCategory *native = [ZSMemoryUsageCategory new];
            native.name = @"Engine";
            native.totalBytes = nativeEngine;
            [results addObject:native];
        }
    }

    if (hasUnusedReserved && totalUnusedReserved > 0) {
        ZSMemoryUsageCategory *reserved = [ZSMemoryUsageCategory new];
        reserved.name = @"Reserved (unused)";
        reserved.totalBytes = totalUnusedReserved;
        [results addObject:reserved];
    }

    int64_t residentBytes = zs_current_process_resident_memory_bytes();
    int64_t engineFootprint = hasTotalReserved ? totalReserved : totalAllocated;
    int64_t systemOverhead = (residentBytes > 0 && engineFootprint > 0) ? (residentBytes - engineFootprint) : 0;
    if (systemOverhead <= 0) return;

    task_vm_info_data_t info;
    mach_msg_type_number_t infoCount = TASK_VM_INFO_COUNT;
    int64_t internalBytes = 0, externalBytes = 0, compressedBytes = 0, purgeableBytes = 0, deviceBytes = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &infoCount) == KERN_SUCCESS) {
        internalBytes = (int64_t)info.internal;
        externalBytes = (int64_t)info.external;
        compressedBytes = (int64_t)info.compressed;
        purgeableBytes = (int64_t)info.purgeable_volatile_resident;
        deviceBytes = (int64_t)info.device;
    }

    int64_t rawSum = internalBytes + externalBytes + compressedBytes + purgeableBytes + deviceBytes;
    if (rawSum <= 0) {
        ZSMemoryUsageCategory *overhead = [ZSMemoryUsageCategory new];
        overhead.name = @"iOS";
        overhead.totalBytes = systemOverhead;
        [results addObject:overhead];
        return;
    }

    NSString *overheadNames[5] = { @"Graphics (IOSurface)", @"Compressed", @"File-backed (frameworks)", @"Purgeable / caches", @"iOS" };
    int64_t overheadRawValues[5] = { deviceBytes, compressedBytes, externalBytes, purgeableBytes, internalBytes };
    for (int i = 0; i < 5; i++) {
        if (overheadRawValues[i] <= 0) continue;
        int64_t scaled = (int64_t)llround((double)overheadRawValues[i] * (double)systemOverhead / (double)rawSum);
        if (scaled <= 0) continue;
        ZSMemoryUsageCategory *part = [ZSMemoryUsageCategory new];
        part.name = overheadNames[i];
        part.totalBytes = scaled;
        [results addObject:part];
    }
}

static NSArray<ZSMemoryUsageCategory *> *zs_scan_memory_usage_breakdown_sync(void) {
    NSMutableArray<ZSMemoryUsageCategory *> *results = [NSMutableArray new];
    NSUInteger descriptorCount = sizeof(kZSMemoryUsageCategoryDescriptors) / sizeof(kZSMemoryUsageCategoryDescriptors[0]);

    for (NSUInteger d = 0; d < descriptorCount; d++) {
        ZSMemoryUsageCategoryDescriptor descriptor = kZSMemoryUsageCategoryDescriptors[d];
        void *klass = mt_class(descriptor.ns, descriptor.klassName, descriptor.assembly);
        if (!klass) continue;

        NSUInteger count = 0;
        void *array = zs_resources_find_all_for_class(klass, &count);
        if (!array || count == 0) continue;

        int64_t categoryTotal = 0;
        NSUInteger liveCount = 0;
        for (NSUInteger i = 0; i < count; i++) {
            void *obj = zs_array_object_at(array, i);
            if (!obj) continue;
            int64_t size = 0;
            if (mt_call_static_object_int64("UnityEngine.Profiling", "Profiler", "CoreModule", "GetRuntimeMemorySizeLong", obj, &size) && size > 0) {
                categoryTotal += size;
                liveCount++;
            }
        }

        if (categoryTotal <= 0) continue;

        ZSMemoryUsageCategory *category = [ZSMemoryUsageCategory new];
        category.name = [NSString stringWithUTF8String:descriptor.displayName];
        category.totalBytes = categoryTotal;
        category.objectCount = liveCount;
        [results addObject:category];
    }

    int64_t assetTrackedBytes = 0;
    for (ZSMemoryUsageCategory *category in results) assetTrackedBytes += category.totalBytes;
    zs_append_subsystem_memory_categories(results, assetTrackedBytes);

    [results sortUsingComparator:^NSComparisonResult(ZSMemoryUsageCategory *a, ZSMemoryUsageCategory *b) {
        if (a.totalBytes == b.totalBytes) return NSOrderedSame;
        return a.totalBytes > b.totalBytes ? NSOrderedAscending : NSOrderedDescending;
    }];

    return results;
}

void zs_collect_memory_usage_breakdown(void (^completion)(NSArray<ZSMemoryUsageCategory *> *categories)) {
    if (!completion) return;
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            NSArray<ZSMemoryUsageCategory *> *results = zs_scan_memory_usage_breakdown_sync();
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(results);
            });
        }
    }];
    worker.name = @"ZSingularity.MemoryUsageScan";
    worker.qualityOfService = NSQualityOfServiceUtility;
    [worker start];
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

typedef NS_ENUM(int32_t, ZSGlobalSceneState) {
    ZSGlobalSceneStateLogin = 0,
    ZSGlobalSceneStateBattle = 1,
    ZSGlobalSceneStateMain = 2,
    ZSGlobalSceneStateStory = 3,
    ZSGlobalSceneStateDungeon = 4,
    ZSGlobalSceneStateMirrorDungeon = 5,
    ZSGlobalSceneStateRailwayDungeon = 6,
    ZSGlobalSceneStateStoryMirrorDungeon = 7,
    ZSGlobalSceneStateProjectGS = 8,
    ZSGlobalSceneStateRpg = 9,
};

static void *gZSGlobalGameManagerClass;
static void *gZSGlobalSceneStateField;

static BOOL ZSGlobalScene_Current(int32_t *outState) {
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
