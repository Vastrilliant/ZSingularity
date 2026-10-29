#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZSAstcQuality) {
    ZSAstcQualityFast = 0,
    ZSAstcQualityBalanced = 1,
    ZSAstcQualityHigh = 2,
};

typedef NS_ENUM(NSInteger, ZSAstcSource) {
    ZSAstcSourceRGBA8 = 0,
    ZSAstcSourceASTC6 = 1,
};

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t block;
    BOOL srgb;
    ZSAstcQuality quality;
    ZSAstcSource source;
    uint32_t worker;
    uint32_t threads;
} ZSAstcJob;

typedef struct {
    uint32_t blocks;
    uint32_t refined;
    double gpuMs;
    double cpuMs;
} ZSAstcStats;

typedef struct {
    double gpuSeconds;
    double blocksPerMs;
    uint32_t chunkBlocks;
} ZSAstcGpuTelemetry;

FOUNDATION_EXPORT BOOL ZSAstcBlockSupported(uint32_t block);
FOUNDATION_EXPORT int32_t ZSAstcUnityFormat(uint32_t block);
FOUNDATION_EXPORT uint64_t ZSAstcEncodedSize(uint32_t width, uint32_t height, uint32_t block);
FOUNDATION_EXPORT uint64_t ZSAstcWorkingBytes(uint32_t width, uint32_t height, uint32_t block);

FOUNDATION_EXPORT int ZSAstcEncode(const ZSAstcJob *job, const uint8_t *src, size_t srcLen, uint8_t * _Nullable * _Nonnull out, size_t *outLen, ZSAstcStats * _Nullable stats, char * _Nullable why, size_t whyLen);

FOUNDATION_EXPORT NSData * _Nullable ZSAstcEncodeRGBA8(NSData *rgba, uint32_t width, uint32_t height, uint32_t block, BOOL srgb, ZSAstcQuality quality, NSError * _Nullable * _Nullable error);

FOUNDATION_EXPORT void ZSAstcSetCancelFlag(volatile BOOL * _Nullable flag);
FOUNDATION_EXPORT void ZSAstcResetTelemetry(void);
FOUNDATION_EXPORT ZSAstcGpuTelemetry ZSAstcReadTelemetry(double wallSeconds);
FOUNDATION_EXPORT void ZSAstcDrainCaches(void);

NS_ASSUME_NONNULL_END
