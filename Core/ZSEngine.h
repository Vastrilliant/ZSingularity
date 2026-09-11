
#import <Foundation/Foundation.h>
#import <stdint.h>

#pragma mark - FPS120Controller

@interface FPS120Controller : NSObject
@property (nonatomic, assign) NSInteger targetFPS;
@property (nonatomic, assign) NSInteger combatFPS;
@property (nonatomic, assign) NSInteger menuFPS;

@property (nonatomic, assign) BOOL manualOverrideActiveMenu;
@property (nonatomic, assign) BOOL manualOverrideActiveCombat;

@property (nonatomic, assign) BOOL isInBattle;

+ (instancetype)shared;

- (BOOL)start;

- (void)setManualMenuFPS:(NSInteger)fps;
- (void)clearManualMenuOverride;

- (void)setManualCombatFPS:(NSInteger)fps;
- (void)setPanelOpen:(BOOL)open;
- (void)clearManualCombatOverride;
@end

#pragma mark - Rendering: urpAsset / QualitySettings

void zs_set_texture_mip_limit(int32_t mipLimit);
void zs_set_render_scale(float scale);
void zs_apply_render_scale_for_battle_state(BOOL isBattle, BOOL force);
void zs_urp_set_bool(const char *setterName, BOOL value);
void zs_urp_set_int(const char *setterName, int32_t value);
void zs_urp_set_float(const char *setterName, float value);

int32_t zs_step_value(const int32_t *steps, int count, float sliderValue);
extern const int32_t kMSAASteps[4];

#pragma mark - Post FX (Volume system)

void zs_apply_motion_blur(void);
void zs_apply_tonemapping(void);

typedef struct {
    const char *name;
    const char *engineName;

    const char *floatField;
    float minV, maxV, defaultV;
} ZSVolumeEffectDef;

extern const ZSVolumeEffectDef kURPPostEffects[];
extern const int kURPPostEffectCount;
void zs_apply_urp_post_effect(NSString *name);

#pragma mark - Camera-level post settings (antialiasing / dithering)

void zs_camera_data_set_int(const char *setterName, int32_t value);
void zs_camera_data_set_bool(const char *setterName, BOOL value);
extern const int32_t kAAModeSteps[4];
extern const int32_t kAAQualitySteps[3];

#pragma mark - Hardcoded setting defaults

extern const NSInteger kDefaultMenuFPS;
extern const NSInteger kDefaultCombatFPS;
extern const int32_t   kDefaultTextureMipEngine;
extern const float     kDefaultRenderScalePct;
extern const float     kDefaultBattleRenderScalePct;
extern const int32_t   kDefaultMSAAIndex;
extern const BOOL      kDefaultHDR;
extern const float     kDefaultMotionBlur;
extern const int32_t   kDefaultTonemapIndex;
extern const int32_t   kDefaultAAModeIndex;
extern const int32_t   kDefaultAAQualityIndex;
extern const BOOL      kDefaultDithering;

#pragma mark - Current-value globals

extern int32_t  g_textureMip;
extern float    g_renderScale;
extern float    g_battleRenderScale;
extern int32_t  g_msaaIndex;
extern BOOL     g_hdrOn;
extern float    g_blurIntensity;
extern int32_t  g_tonemapMode;
extern int32_t  g_aaModeIndex;
extern int32_t  g_aaQualityIndex;
extern BOOL     g_ditheringOn;
extern NSInteger g_menuFPS;
extern NSInteger g_combatFPS;
extern NSMutableDictionary<NSString *, NSNumber *> *g_urpActive;
extern NSMutableDictionary<NSString *, NSNumber *> *g_urpValue;

extern NSArray<NSString *> *g_syslogBlacklist;

extern NSMutableArray<NSString *> *g_trackedAssetPaths;

extern BOOL g_experimentalSettingsEnabled;

#pragma mark - Settings persistence (single settings.json in Documents)

NSDictionary *zs_load_settings_dictionary(void);
void zs_write_settings_dictionary(NSDictionary *dict);

NSDictionary * _Nullable zs_settings_section(NSString *sectionKey);
void zs_write_settings_section(NSString *sectionKey, NSDictionary *sectionValue);

NSDictionary *zs_current_settings_dictionary(void);
void zs_persist_current_settings(void);

#pragma mark - Tracked asset paths (Hard Assets Reset)

void zs_track_asset_path(NSString *path);

NSArray<NSString *> *zs_tracked_asset_paths(void);

void zs_clear_tracked_asset_paths(void);

#pragma mark - File index (Mod Loader Pipeline caching - see UnityBundleTools.h)

extern NSDictionary *g_fileIndexSnapshot;

void zs_ensure_file_index_snapshot_loaded(void);

void zs_set_file_index_snapshot(NSDictionary * _Nullable snapshot);

#pragma mark - Apply-everything entry points

void zs_reapply_all_settings(void);

void zs_reapply_post_fx(void);

#pragma mark - Experimental settings

extern int32_t g_expPixelLightCount;
extern float   g_expLODBias;
extern BOOL    g_expLODCrossFade;
extern int32_t g_expVSyncCount;
extern int32_t g_expQualityAA;

extern BOOL    g_expCameraHDR;
extern BOOL    g_expCameraMSAA;
extern BOOL    g_expDynamicResolution;
extern BOOL    g_expOcclusionCulling;
extern BOOL    g_expDepthTexture;
extern BOOL    g_expOpaqueTexture;
extern BOOL    g_expRenderShadows;
extern BOOL    g_expPostProcessing;
extern int32_t g_expAntialiasingMode;
extern int32_t g_expAntialiasingQuality;
extern BOOL    g_expCameraDithering;
extern int32_t g_expCameraRequiresDepthOption;
extern int32_t g_expCameraRequiresColorOption;
extern int32_t g_expCameraRenderType;
extern BOOL    g_expCameraRequiresDepthTexture;
extern BOOL    g_expCameraRequiresColorTexture;
extern BOOL    g_expCameraResetHistory;
extern BOOL    g_expCameraStopNaN;
extern BOOL    g_expCameraAllowXR;
extern BOOL    g_expCameraScreenCoordOverride;
extern BOOL    g_expCameraHDROutput;
extern int32_t g_expRenderTextureMemorylessMode;
extern int32_t g_expUpscalingFilter;
extern BOOL    g_expFSROverride;
extern float   g_expFSRSharpness;
extern BOOL    g_expURPHDR;
extern int32_t g_expURPMSAA;
extern int32_t g_expMainLightMode;
extern BOOL    g_expMainLightShadows;
extern int32_t g_expMainShadowResolution;
extern int32_t g_expAdditionalLightMode;
extern int32_t g_expMaxAdditionalLights;
extern BOOL    g_expAdditionalLightShadows;
extern int32_t g_expAdditionalShadowResolution;
extern BOOL    g_expReflectionProbeBlending;
extern BOOL    g_expReflectionProbeBoxProjection;
extern BOOL    g_expReflectionProbeAtlas;
extern int32_t g_expShEvalMode;
extern int32_t g_expLightProbeSystem;
extern int32_t g_expProbeVolumeMemoryBudget;
extern int32_t g_expProbeVolumeBlendingMemoryBudget;
extern BOOL    g_expProbeVolumeStreaming;
extern BOOL    g_expProbeVolumeGPUStreaming;
extern BOOL    g_expProbeVolumeDiskStreaming;
extern BOOL    g_expProbeVolumeScenarios;
extern BOOL    g_expProbeVolumeScenarioBlending;
extern int32_t g_expProbeVolumeSHBands;
extern int32_t g_expAdditionalShadowTierLow;
extern int32_t g_expAdditionalShadowTierMedium;
extern int32_t g_expAdditionalShadowTierHigh;
extern int32_t g_expSoftShadowQuality;
extern float   g_expShadowDistance;
extern int32_t g_expShadowCascades;
extern float   g_expCascadeBorder;
extern float   g_expShadowDepthBias;
extern float   g_expShadowNormalBias;
extern BOOL    g_expSoftShadows;
extern BOOL    g_expDynamicBatching;
extern BOOL    g_expSRPBatcher;
extern int32_t g_expColorGradingMode;
extern int32_t g_expColorGradingLUTSize;
extern BOOL    g_expAdaptivePerformance;
extern int32_t g_expGPUResidentDrawerMode;
extern BOOL    g_expGPUResidentOcclusion;
extern float   g_expSmallMeshScreenPercentage;
extern int32_t g_expIntermediateTextureMode;
extern int32_t g_expStoreActionsOptimization;
extern int32_t g_expShadowCascadeOption;
extern float   g_expCascade2Split;
extern float   g_expCascade3SplitX;
extern float   g_expCascade3SplitY;
extern float   g_expCascade4SplitX;
extern float   g_expCascade4SplitY;
extern float   g_expCascade4SplitZ;
extern BOOL    g_expConservativeEnclosingSphere;
extern int32_t g_expNumIterationsEnclosingSphere;
extern int32_t g_expShaderVariantLogLevel;
extern BOOL    g_expGraphicsSRPBatching;
extern BOOL    g_expLightsUseLinearIntensity;
extern BOOL    g_expLightsUseColorTemperature;
extern float   g_expAPMaxShadowDistanceMultiplier;
extern float   g_expAPShadowmapResolutionMultiplier;
extern float   g_expAPRenderScaleMultiplier;
extern float   g_expAPDecalsDrawDistance;
extern int32_t g_expAPShadowCascadesBias;
extern int32_t g_expAPShadowQualityBias;
extern float   g_expAPLutBias;
extern int32_t g_expAPAntiAliasingQualityBias;
extern BOOL    g_expAPSkipDynamicBatching;
extern BOOL    g_expAPSkipFrontToBackSorting;
extern BOOL    g_expAPSkipTransparentObjects;

extern BOOL    g_expParticleGPUInstancing;

#define kZSParticleAlignmentPreserveOriginal 4
extern int32_t g_expParticleAlignment;

#define kZSParticleRenderModePreserveOriginal 6
extern int32_t g_expParticleRenderMode;
extern int32_t g_expParticleMeshDistribution;
extern int32_t g_expParticleSortMode;
extern float   g_expParticleLengthScale;
extern float   g_expParticleVelocityScale;
extern float   g_expParticleCameraVelocityScale;
extern float   g_expParticleNormalDirection;
extern float   g_expParticleShadowBias;
extern float   g_expParticleSortingFudge;
extern float   g_expParticleMinSize;
extern float   g_expParticleMaxSize;
extern BOOL    g_expParticleAllowRoll;
extern BOOL    g_expParticleFreeformStretching;
extern BOOL    g_expParticleRotateWithStretchDirection;
extern BOOL    g_expParticleApplyActiveColorSpace;
extern BOOL    g_expParticleMaxParticlesCapEnabled;
extern int32_t g_expParticleMaxParticlesCap;
extern int32_t g_expAnimatorCullingMode;
extern int32_t g_expAnimatorUpdateMode;
extern BOOL    g_expAnimatorApplyRootMotion;
extern BOOL    g_expAnimatorLinearVelocityBlending;
extern BOOL    g_expAnimatorAnimatePhysics;
extern BOOL    g_expAnimatorConstantClipSamplingOptimization;
extern BOOL    g_expAnimatorStabilizeFeet;
extern float   g_expAnimatorSpeed;
extern BOOL    g_expAnimatorLogWarnings;
extern BOOL    g_expAnimatorFireEvents;
extern BOOL    g_expAnimatorWriteDefaultValuesOnDisable;
extern BOOL    g_expAnimatorKeepStateOnDisable;
extern BOOL    g_expAnimatorKeepControllerStateOnDisable;

extern BOOL    g_expAutoUnloadOnMemoryWarning;
extern BOOL    g_expAutoClearPortraitCacheOnBattleExit;
extern BOOL    g_expDebugLogMemoryUsageTier;
extern BOOL    g_expAutoUnloadOnElevatedMemoryUsage;

#pragma mark - Threading / Async / Jobs

extern BOOL    g_expBurstCompilation;
extern BOOL    g_expBurstSafetyChecks;

#pragma mark - Physics / Update Loop

extern int32_t g_expRigidbodySolverIterations;
extern int32_t g_expRigidbodySolverVelocityIterations;
extern float   g_expRigidbodySleepThreshold;
extern float   g_expRigidbodyMaxAngularVelocity;
extern float   g_expRigidbodyMaxLinearVelocity;
extern int32_t g_expRigidbodyInterpolation;
extern BOOL    g_expRigidbodyDetectCollisions;
extern float   g_expRigidbody2DLinearDamping;
extern float   g_expRigidbody2DAngularDamping;
extern float   g_expRigidbody2DGravityScale;
extern int32_t g_expRigidbody2DInterpolation;
extern int32_t g_expRigidbody2DSleepMode;
extern int32_t g_expRigidbody2DCollisionDetectionMode;
extern BOOL    g_expAdaptivePhysics;

void zs_exp_load_from_dictionary(NSDictionary * _Nullable saved);
NSDictionary *zs_exp_settings_dictionary(void);
void zs_exp_apply_key(NSString * _Nullable key);
BOOL zs_exp_key_class_available(NSString * _Nullable key);
BOOL zs_urp_effect_class_available(NSString * _Nullable engineName);
void zs_exp_reset_defaults(void);
BOOL zs_apply_particle_key(NSString *key);
BOOL zs_apply_particle_max_particles_cap(void);

BOOL zs_exp_get_bool(NSString *key);
float zs_exp_get_number(NSString *key);
float zs_exp_get_default_number(NSString *key);

#pragma mark - Memory / asset cache controls

void zs_unload_unused_assets_and_collect(void);
void zs_set_auto_unload_on_memory_warning(BOOL enabled);
void zs_clear_guide_portrait_cache(void);

void zs_set_debug_log_memory_usage_tier(BOOL enabled);
void zs_set_auto_unload_on_elevated_memory_usage(BOOL enabled);
int32_t zs_last_observed_memory_usage_tier(void);

#pragma mark - Dev debug HUD

#pragma mark - Custom Greeting Text

NSString *zs_custom_greeting_text(void);
void zs_set_custom_greeting_text(NSString * _Nullable text);

#pragma mark - UID Redactor

@interface UIDRedactor : NSObject

+ (void)install;

+ (void)applyRedaction;

+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)enabled;

@end

#pragma mark - Legacy aliases used by existing UI / ZSScripts

#define g_autoUnloadOnMemoryWarning g_expAutoUnloadOnMemoryWarning
#define g_autoClearPortraitCacheOnBattleExit g_expAutoClearPortraitCacheOnBattleExit
