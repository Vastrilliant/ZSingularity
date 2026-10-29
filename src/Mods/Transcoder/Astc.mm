#import "Astc.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <os/lock.h>
#include <dlfcn.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "astcenc.h"
#import "ZTweakLog.h"

#define ZSA_MAX_WORKERS 8
#define ZSA_WHY(...) do { if (why && whyLen) snprintf(why, whyLen, __VA_ARGS__); } while (0)
#define ZSA_MS(since) ((CACurrentMediaTime() - (since)) * 1000.0)

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t block;
    uint32_t blocksX;
    uint32_t srgb;
    uint32_t rowOffset;
    uint32_t rowCount;
    uint32_t count;
} ZSAParams;

static const double kZSAChunkTargetMs = 12.0;
static const double kZSAChunkCapMs = 24.0;
static const uint32_t kZSAChunkMinBlocks = 1024u;
static const uint32_t kZSAChunkMaxBlocks = 65536u;
static const uint32_t kZSAStripPixels = 1u << 20;
static const uint64_t kZSAPoolCapBytes = 48ull * 1024ull * 1024ull;
static const NSUInteger kZSAContextPoolCap = 8;

static volatile BOOL *g_zsaCancel = NULL;

static os_unfair_lock g_zsaMetalLock = OS_UNFAIR_LOCK_INIT;
static id<MTLDevice> g_zsaDevice;
static id<MTLLibrary> g_zsaLibrary;
static id<MTLCommandQueue> g_zsaQueues[ZSA_MAX_WORKERS];
static id<MTLComputePipelineState> g_zsaClassify[4];
static id<MTLComputePipelineState> g_zsaGather;
static BOOL g_zsaInitialized = NO;
static NSString *g_zsaError;

static os_unfair_lock g_zsaChunkLock = OS_UNFAIR_LOCK_INIT;
static volatile uint32_t g_zsaChunkBlocks = 16384u;
static double g_zsaChunkCeiling = 65536.0;
static double g_zsaRateSmooth = 0;
static double g_zsaRateBest = 0;
static _Atomic uint64_t g_zsaGpuBusyNs;
static _Atomic uint64_t g_zsaGpuBlocks;

static os_unfair_lock g_zsaPoolLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, NSMutableArray<id<MTLBuffer>> *> *g_zsaBufferPool;
static NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *> *g_zsaTexturePool;
static uint64_t g_zsaPoolBytes = 0;

typedef struct {
    astcenc_context *context;
    uint32_t block;
    uint32_t srgb;
    uint32_t quality;
    uint32_t threads;
} ZSAContextEntry;

static os_unfair_lock g_zsaContextLock = OS_UNFAIR_LOCK_INIT;
static ZSAContextEntry g_zsaContexts[8];
static NSUInteger g_zsaContextCount = 0;

BOOL ZSAstcBlockSupported(uint32_t block) {
    return block == 6 || block == 8 || block == 10 || block == 12;
}

int32_t ZSAstcUnityFormat(uint32_t block) {
    switch (block) {
        case 6: return 50;
        case 8: return 51;
        case 10: return 52;
        case 12: return 53;
        default: return 0;
    }
}

uint64_t ZSAstcEncodedSize(uint32_t width, uint32_t height, uint32_t block) {
    if (block == 0) return 0;
    uint64_t blocksX = ((uint64_t)width + block - 1) / block;
    uint64_t blocksY = ((uint64_t)height + block - 1) / block;
    return blocksX * blocksY * 16u;
}

uint64_t ZSAstcWorkingBytes(uint32_t width, uint32_t height, uint32_t block) {
    uint64_t encoded = ZSAstcEncodedSize(width, height, block);
    return encoded * 2u + (encoded / 16u) * 8u + (uint64_t)kZSAStripPixels * 4u + (1u << 20);
}

void ZSAstcSetCancelFlag(volatile BOOL *flag) {
    g_zsaCancel = flag;
}

void ZSAstcResetTelemetry(void) {
    atomic_store(&g_zsaGpuBusyNs, 0ull);
    atomic_store(&g_zsaGpuBlocks, 0ull);
    os_unfair_lock_lock(&g_zsaChunkLock);
    g_zsaChunkBlocks = 16384u;
    g_zsaChunkCeiling = (double)kZSAChunkMaxBlocks;
    g_zsaRateSmooth = 0;
    g_zsaRateBest = 0;
    os_unfair_lock_unlock(&g_zsaChunkLock);
}

ZSAstcGpuTelemetry ZSAstcReadTelemetry(double wallSeconds) {
    (void)wallSeconds;
    ZSAstcGpuTelemetry telemetry;
    telemetry.gpuSeconds = (double)atomic_load(&g_zsaGpuBusyNs) / 1e9;
    double blocks = (double)atomic_load(&g_zsaGpuBlocks);
    telemetry.blocksPerMs = telemetry.gpuSeconds > 0 ? blocks / (telemetry.gpuSeconds * 1000.0) : 0.0;
    telemetry.chunkBlocks = g_zsaChunkBlocks;
    return telemetry;
}

static NSUInteger zsa_slot(uint32_t block) {
    switch (block) {
        case 6: return 0;
        case 8: return 1;
        case 10: return 2;
        default: return 3;
    }
}

static id<MTLComputePipelineState> zsa_make_pipeline(NSString *name) {
    id<MTLFunction> function = [g_zsaLibrary newFunctionWithName:name];
    if (!function) {
        g_zsaError = [NSString stringWithFormat:@"Metal function %@ is missing", name];
        return nil;
    }
    NSError *error = nil;
    MTLComputePipelineDescriptor *descriptor = [[MTLComputePipelineDescriptor alloc] init];
    descriptor.computeFunction = function;
    descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = YES;
    id<MTLComputePipelineState> pipeline = [g_zsaDevice newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
    if (!pipeline) g_zsaError = error.localizedDescription ?: [NSString stringWithFormat:@"Unable to create pipeline %@", name];
    return pipeline;
}

static void zsa_metal_bootstrap(void) {
    g_zsaInitialized = YES;
    g_zsaDevice = MTLCreateSystemDefaultDevice();
    if (!g_zsaDevice) {
        g_zsaError = @"Metal device unavailable";
        return;
    }
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (!dladdr((const void *)&zsa_metal_bootstrap, &info) || !info.dli_fbase) {
        g_zsaError = @"Unable to locate embedded Metal library";
        return;
    }
    unsigned long librarySize = 0;
    const void *libraryBytes = getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__DATA", "__zsastcmetal", &librarySize);
    if (!libraryBytes || librarySize == 0) {
        g_zsaError = @"Embedded Metal library is missing";
        return;
    }
    NSError *error = nil;
    dispatch_data_t data = dispatch_data_create(libraryBytes, librarySize, dispatch_get_main_queue(), ^{});
    g_zsaLibrary = [g_zsaDevice newLibraryWithData:data error:&error];
    if (!g_zsaLibrary) {
        g_zsaError = error.localizedDescription ?: @"Unable to load embedded Metal library";
        return;
    }
    g_zsaQueues[0] = [g_zsaDevice newCommandQueue];
    if (!g_zsaQueues[0]) g_zsaError = @"Unable to create Metal command queue";
}

static BOOL zsa_metal_prepare(uint32_t block, id<MTLComputePipelineState> *classify, id<MTLComputePipelineState> *gather, char *why, size_t whyLen) {
    NSUInteger slot = zsa_slot(block);
    os_unfair_lock_lock(&g_zsaMetalLock);
    if (!g_zsaInitialized) zsa_metal_bootstrap();
    if (!g_zsaError && !g_zsaClassify[slot]) g_zsaClassify[slot] = zsa_make_pipeline([NSString stringWithFormat:@"zsa_classify_%u", block]);
    if (!g_zsaError && !g_zsaGather) g_zsaGather = zsa_make_pipeline(@"zsa_gather");
    id<MTLComputePipelineState> classifyPipeline = g_zsaError ? nil : g_zsaClassify[slot];
    id<MTLComputePipelineState> gatherPipeline = g_zsaError ? nil : g_zsaGather;
    NSString *errorText = g_zsaError;
    os_unfair_lock_unlock(&g_zsaMetalLock);
    if (!classifyPipeline || !gatherPipeline) {
        ZSA_WHY("%s", errorText.UTF8String ?: "Metal transcoder initialization failed");
        return NO;
    }
    *classify = classifyPipeline;
    *gather = gatherPipeline;
    return YES;
}

static id<MTLCommandQueue> zsa_queue_for(uint32_t worker) {
    NSUInteger index = worker < ZSA_MAX_WORKERS ? worker : 0;
    os_unfair_lock_lock(&g_zsaMetalLock);
    id<MTLCommandQueue> queue = g_zsaQueues[index];
    if (!queue) {
        queue = [g_zsaDevice newCommandQueue] ?: g_zsaQueues[0];
        g_zsaQueues[index] = queue;
    }
    os_unfair_lock_unlock(&g_zsaMetalLock);
    return queue;
}

static void zsa_note_chunk(id<MTLCommandBuffer> commandBuffer, uint32_t blocks) {
    double seconds = commandBuffer.GPUEndTime - commandBuffer.GPUStartTime;
    if (seconds <= 0.0 || blocks == 0) return;
    double ms = seconds * 1000.0;
    atomic_fetch_add(&g_zsaGpuBusyNs, (uint64_t)(seconds * 1e9));
    atomic_fetch_add(&g_zsaGpuBlocks, (uint64_t)blocks);
    os_unfair_lock_lock(&g_zsaChunkLock);
    uint32_t current = g_zsaChunkBlocks;
    if ((double)blocks >= 0.9 * (double)current) {
        double rate = (double)blocks / ms;
        g_zsaRateSmooth = g_zsaRateSmooth > 0.0 ? g_zsaRateSmooth * 0.6 + rate * 0.4 : rate;
        g_zsaRateBest = MAX(g_zsaRateBest * 0.998, g_zsaRateSmooth);
        double next = (double)current;
        if (ms > kZSAChunkCapMs) next = (double)current * (kZSAChunkTargetMs / ms);
        else if (ms < kZSAChunkTargetMs || g_zsaRateSmooth < 0.9 * g_zsaRateBest) next = (double)current * 1.2;
        g_zsaChunkCeiling = MIN(g_zsaChunkCeiling * 1.01 + 1.0, (double)kZSAChunkMaxBlocks);
        next = MIN(next, g_zsaChunkCeiling);
        g_zsaChunkBlocks = (uint32_t)MIN(MAX(next, (double)kZSAChunkMinBlocks), (double)kZSAChunkMaxBlocks);
    }
    os_unfair_lock_unlock(&g_zsaChunkLock);
}

static void zsa_chunk_shrink(void) {
    os_unfair_lock_lock(&g_zsaChunkLock);
    uint32_t shrunk = MAX(kZSAChunkMinBlocks, g_zsaChunkBlocks / 4u);
    g_zsaChunkBlocks = shrunk;
    g_zsaChunkCeiling = MAX((double)shrunk * 2.0, (double)kZSAChunkMinBlocks);
    g_zsaRateSmooth = 0;
    g_zsaRateBest = 0;
    os_unfair_lock_unlock(&g_zsaChunkLock);
}

static id<MTLBuffer> zsa_take_buffer(size_t length) {
    id<MTLBuffer> buffer = nil;
    os_unfair_lock_lock(&g_zsaPoolLock);
    NSMutableArray<id<MTLBuffer>> *list = g_zsaBufferPool[@(length)];
    buffer = list.lastObject;
    if (buffer) {
        [list removeLastObject];
        g_zsaPoolBytes -= MIN(g_zsaPoolBytes, (uint64_t)buffer.allocatedSize);
    }
    os_unfair_lock_unlock(&g_zsaPoolLock);
    if (buffer) return buffer;
    return [g_zsaDevice newBufferWithLength:length options:MTLResourceStorageModeShared];
}

static void zsa_give_buffer(id<MTLBuffer> buffer) {
    if (!buffer) return;
    uint64_t size = buffer.allocatedSize;
    NSNumber *key = @(buffer.length);
    os_unfair_lock_lock(&g_zsaPoolLock);
    if (g_zsaPoolBytes + size <= kZSAPoolCapBytes) {
        if (!g_zsaBufferPool) g_zsaBufferPool = [NSMutableDictionary dictionary];
        NSMutableArray<id<MTLBuffer>> *list = g_zsaBufferPool[key];
        if (!list) {
            list = [NSMutableArray array];
            g_zsaBufferPool[key] = list;
        }
        [list addObject:buffer];
        g_zsaPoolBytes += size;
    }
    os_unfair_lock_unlock(&g_zsaPoolLock);
}

static NSString *zsa_texture_key(MTLPixelFormat format, uint32_t width, uint32_t height) {
    return [NSString stringWithFormat:@"%lu.%u.%u", (unsigned long)format, width, height];
}

static id<MTLTexture> zsa_take_texture(MTLPixelFormat format, uint32_t width, uint32_t height) {
    NSString *key = zsa_texture_key(format, width, height);
    id<MTLTexture> texture = nil;
    os_unfair_lock_lock(&g_zsaPoolLock);
    NSMutableArray<id<MTLTexture>> *list = g_zsaTexturePool[key];
    texture = list.lastObject;
    if (texture) {
        [list removeLastObject];
        g_zsaPoolBytes -= MIN(g_zsaPoolBytes, (uint64_t)texture.allocatedSize);
    }
    os_unfair_lock_unlock(&g_zsaPoolLock);
    if (texture) return texture;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    return [g_zsaDevice newTextureWithDescriptor:descriptor];
}

static void zsa_give_texture(id<MTLTexture> texture) {
    if (!texture) return;
    NSString *key = zsa_texture_key(texture.pixelFormat, (uint32_t)texture.width, (uint32_t)texture.height);
    uint64_t size = texture.allocatedSize;
    os_unfair_lock_lock(&g_zsaPoolLock);
    if (g_zsaPoolBytes + size <= kZSAPoolCapBytes) {
        if (!g_zsaTexturePool) g_zsaTexturePool = [NSMutableDictionary dictionary];
        NSMutableArray<id<MTLTexture>> *list = g_zsaTexturePool[key];
        if (!list) {
            list = [NSMutableArray array];
            g_zsaTexturePool[key] = list;
        }
        [list addObject:texture];
        g_zsaPoolBytes += size;
    }
    os_unfair_lock_unlock(&g_zsaPoolLock);
}

static float zsa_preset(ZSAstcQuality quality) {
    switch (quality) {
        case ZSAstcQualityFast: return ASTCENC_PRE_FASTEST;
        case ZSAstcQualityHigh: return ASTCENC_PRE_MEDIUM;
        default: return 5.0f;
    }
}

static float zsa_accept_mse(ZSAstcQuality quality) {
    switch (quality) {
        case ZSAstcQualityFast: return 6.0f;
        case ZSAstcQualityHigh: return 0.75f;
        default: return INFINITY;
    }
}

static astcenc_context *zsa_take_context(uint32_t block, BOOL srgb, ZSAstcQuality quality, uint32_t threads, char *why, size_t whyLen) {
    os_unfair_lock_lock(&g_zsaContextLock);
    for (NSUInteger i = 0; i < g_zsaContextCount; i++) {
        ZSAContextEntry entry = g_zsaContexts[i];
        if (entry.block == block && entry.srgb == (srgb ? 1u : 0u) && entry.quality == (uint32_t)quality && entry.threads == threads) {
            g_zsaContexts[i] = g_zsaContexts[g_zsaContextCount - 1];
            g_zsaContextCount--;
            os_unfair_lock_unlock(&g_zsaContextLock);
            return entry.context;
        }
    }
    os_unfair_lock_unlock(&g_zsaContextLock);
    astcenc_config config;
    astcenc_error status = astcenc_config_init(srgb ? ASTCENC_PRF_LDR_SRGB : ASTCENC_PRF_LDR, block, block, 1, zsa_preset(quality), 0, &config);
    if (status != ASTCENC_SUCCESS) {
        ZSA_WHY("astcenc config failed: %s", astcenc_get_error_string(status));
        return NULL;
    }
    astcenc_context *context = NULL;
    status = astcenc_context_alloc(&config, threads, &context);
    if (status != ASTCENC_SUCCESS || !context) {
        ZSA_WHY("astcenc context failed: %s", astcenc_get_error_string(status));
        return NULL;
    }
    return context;
}

static void zsa_give_context(astcenc_context *context, uint32_t block, BOOL srgb, ZSAstcQuality quality, uint32_t threads) {
    if (!context) return;
    os_unfair_lock_lock(&g_zsaContextLock);
    if (g_zsaContextCount < kZSAContextPoolCap) {
        ZSAContextEntry entry = { context, block, srgb ? 1u : 0u, (uint32_t)quality, threads };
        g_zsaContexts[g_zsaContextCount++] = entry;
        os_unfair_lock_unlock(&g_zsaContextLock);
        return;
    }
    os_unfair_lock_unlock(&g_zsaContextLock);
    astcenc_context_free(context);
}

void ZSAstcDrainCaches(void) {
    os_unfair_lock_lock(&g_zsaPoolLock);
    NSMutableDictionary *buffers = g_zsaBufferPool;
    NSMutableDictionary *textures = g_zsaTexturePool;
    g_zsaBufferPool = nil;
    g_zsaTexturePool = nil;
    g_zsaPoolBytes = 0;
    os_unfair_lock_unlock(&g_zsaPoolLock);
    [buffers removeAllObjects];
    [textures removeAllObjects];
    os_unfair_lock_lock(&g_zsaContextLock);
    ZSAContextEntry drained[8];
    NSUInteger drainedCount = g_zsaContextCount;
    memcpy(drained, g_zsaContexts, sizeof(ZSAContextEntry) * drainedCount);
    g_zsaContextCount = 0;
    os_unfair_lock_unlock(&g_zsaContextLock);
    for (NSUInteger i = 0; i < drainedCount; i++) astcenc_context_free(drained[i].context);
}

typedef struct {
    atomic_int failed;
    atomic_int interactivity;
    char error[160];
} ZSAGPUState;

static int zsa_classify_once(int *interactivityOut, id<MTLCommandQueue> queue, id<MTLComputePipelineState> pipeline, id<MTLTexture> sourceTexture,
                             id<MTLBuffer> outputBuffer, id<MTLBuffer> metricBuffer, const ZSAParams *base, uint32_t blocksY, char *why, size_t whyLen) {
    NSUInteger groupWidth = MAX((NSUInteger)1, pipeline.threadExecutionWidth);
    NSUInteger groupHeight = MIN((NSUInteger)4, MAX((NSUInteger)1, pipeline.maxTotalThreadsPerThreadgroup / groupWidth));
    MTLSize threadsPerGroup = MTLSizeMake(groupWidth, groupHeight, 1);
    dispatch_group_t finished = dispatch_group_create();
    dispatch_semaphore_t gate = dispatch_semaphore_create(4);
    ZSAGPUState state;
    atomic_init(&state.failed, 0);
    atomic_init(&state.interactivity, 0);
    state.error[0] = 0;
    ZSAGPUState *statePtr = &state;
    int rc = 0;
    uint32_t rowOffset = 0;
    while (rowOffset < blocksY && atomic_load(&state.failed) == 0) {
        uint32_t rowsPerChunk = MAX((uint32_t)1, g_zsaChunkBlocks / MAX(base->blocksX, 1u));
        uint32_t rowCount = MIN(rowsPerChunk, blocksY - rowOffset);
        ZSAParams params = *base;
        params.rowOffset = rowOffset;
        params.rowCount = rowCount;
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = commandBuffer ? [commandBuffer computeCommandEncoder] : nil;
        if (!commandBuffer || !encoder) {
            dispatch_semaphore_signal(gate);
            ZSA_WHY("Metal command encoding unavailable");
            rc = -1;
            break;
        }
        [encoder setComputePipelineState:pipeline];
        [encoder setTexture:sourceTexture atIndex:0];
        [encoder setBuffer:outputBuffer offset:0 atIndex:0];
        [encoder setBytes:&params length:sizeof(params) atIndex:1];
        [encoder setBuffer:metricBuffer offset:0 atIndex:2];
        MTLSize threadgroups = MTLSizeMake((base->blocksX + groupWidth - 1) / groupWidth, (rowCount + groupHeight - 1) / groupHeight, 1);
        [encoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
        [encoder endEncoding];
        uint32_t chunkBlocks = rowCount * base->blocksX;
        dispatch_group_enter(finished);
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status != MTLCommandBufferStatusCompleted) {
                int expected = 0;
                if (completed.error.code == 14) atomic_store(&statePtr->interactivity, 1);
                if (atomic_compare_exchange_strong(&statePtr->failed, &expected, 1)) {
                    snprintf(statePtr->error, sizeof(statePtr->error), "%s", completed.error.localizedDescription.UTF8String ?: "unknown error");
                }
            } else {
                zsa_note_chunk(completed, chunkBlocks);
            }
            dispatch_semaphore_signal(gate);
            dispatch_group_leave(finished);
        }];
        [commandBuffer commit];
        rowOffset += rowCount;
    }
    dispatch_group_wait(finished, DISPATCH_TIME_FOREVER);
    if (rc == 0 && atomic_load(&state.failed) != 0) {
        ZSA_WHY("Metal ASTC kernel failed: %s", state.error[0] ? state.error : "unknown error");
        rc = -1;
    }
    if (interactivityOut) *interactivityOut = atomic_load(&state.interactivity);
    return rc;
}

static int zsa_classify(id<MTLCommandQueue> queue, id<MTLComputePipelineState> pipeline, id<MTLTexture> sourceTexture, id<MTLBuffer> outputBuffer,
                        id<MTLBuffer> metricBuffer, const ZSAParams *base, uint32_t blocksY, char *why, size_t whyLen) {
    int rc = -1;
    for (int attempt = 0; attempt < 5; attempt++) {
        int interactivity = 0;
        if (why && whyLen) why[0] = 0;
        rc = zsa_classify_once(&interactivity, queue, pipeline, sourceTexture, outputBuffer, metricBuffer, base, blocksY, why, whyLen);
        if (rc == 0 || !interactivity || (g_zsaCancel && *g_zsaCancel)) break;
        zsa_chunk_shrink();
        ZLog(@"[ASTC] GPU watchdog interrupted a chunk, shrinking to %u blocks and retrying %ux%u texture (attempt %d)", (unsigned)g_zsaChunkBlocks, base->width, base->height, attempt + 2);
        usleep(30000u * (useconds_t)(attempt + 1));
    }
    return rc;
}

static int zsa_gather(id<MTLCommandQueue> queue, id<MTLComputePipelineState> pipeline, id<MTLTexture> sourceTexture, id<MTLBuffer> pixelBuffer,
                      id<MTLBuffer> listBuffer, const ZSAParams *base, uint32_t count, char *why, size_t whyLen) {
    ZSAParams params = *base;
    params.count = count;
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = commandBuffer ? [commandBuffer computeCommandEncoder] : nil;
    if (!commandBuffer || !encoder) {
        ZSA_WHY("Metal command encoding unavailable");
        return -1;
    }
    NSUInteger group = MIN((NSUInteger)64, MAX((NSUInteger)1, pipeline.maxTotalThreadsPerThreadgroup));
    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:sourceTexture atIndex:0];
    [encoder setBuffer:pixelBuffer offset:0 atIndex:0];
    [encoder setBytes:&params length:sizeof(params) atIndex:1];
    [encoder setBuffer:listBuffer offset:0 atIndex:2];
    [encoder dispatchThreadgroups:MTLSizeMake((count + group - 1) / group, 1, 1) threadsPerThreadgroup:MTLSizeMake(group, 1, 1)];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        ZSA_WHY("Metal gather failed: %s", commandBuffer.error.localizedDescription.UTF8String ?: "unknown error");
        return -1;
    }
    return 0;
}

static int zsa_refine(astcenc_context *context, uint32_t threads, id<MTLBuffer> pixelBuffer, uint32_t block, uint32_t count, uint8_t *scratch, char *why, size_t whyLen) {
    astcenc_image image;
    memset(&image, 0, sizeof(image));
    void *slice = pixelBuffer.contents;
    image.dim_x = block;
    image.dim_y = count * block;
    image.dim_z = 1;
    image.data_type = ASTCENC_TYPE_U8;
    image.data = &slice;
    astcenc_swizzle swizzle = { ASTCENC_SWZ_R, ASTCENC_SWZ_G, ASTCENC_SWZ_B, ASTCENC_SWZ_A };
    size_t scratchLen = (size_t)count * 16u;
    astcenc_error status = ASTCENC_SUCCESS;
    if (threads <= 1) {
        status = astcenc_compress_image(context, &image, &swizzle, scratch, scratchLen, 0);
    } else {
        atomic_int failed;
        atomic_init(&failed, (int)ASTCENC_SUCCESS);
        atomic_int *failedPtr = &failed;
        astcenc_image *imagePtr = &image;
        astcenc_swizzle *swizzlePtr = &swizzle;
        dispatch_apply(threads, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            astcenc_error result = astcenc_compress_image(context, imagePtr, swizzlePtr, scratch, scratchLen, (unsigned int)index);
            if (result != ASTCENC_SUCCESS) atomic_store(failedPtr, (int)result);
        });
        status = (astcenc_error)atomic_load(&failed);
    }
    astcenc_compress_reset(context);
    if (status != ASTCENC_SUCCESS) {
        ZSA_WHY("astcenc compress failed: %s", astcenc_get_error_string(status));
        return -1;
    }
    return 0;
}

static int zsa_encode_inner(const ZSAstcJob *job, const uint8_t *src, size_t srcLen, uint8_t **out, size_t *outLen, ZSAstcStats *stats, char *why, size_t whyLen) {
    uint32_t width = job->width;
    uint32_t height = job->height;
    uint32_t block = job->block;
    BOOL srgb = job->srgb;
    uint32_t blocksX = (width + block - 1) / block;
    uint32_t blocksY = (height + block - 1) / block;
    size_t blockCount = (size_t)blocksX * blocksY;
    size_t encodedLen = blockCount * 16u;
    if (blockCount == 0 || encodedLen / 16u != blockCount) {
        ZSA_WHY("ASTC output size overflowed");
        return -1;
    }

    NSUInteger rowBytes;
    size_t expectedLen;
    MTLPixelFormat format;
    if (job->source == ZSAstcSourceASTC6) {
        rowBytes = (NSUInteger)((width + 5u) / 6u) * 16u;
        expectedLen = (size_t)rowBytes * ((height + 5u) / 6u);
        format = srgb ? MTLPixelFormatASTC_6x6_sRGB : MTLPixelFormatASTC_6x6_LDR;
    } else {
        rowBytes = (NSUInteger)width * 4u;
        expectedLen = (size_t)rowBytes * height;
        format = srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
    }
    if (expectedLen != srcLen) {
        ZSA_WHY("ASTC source size mismatch, got %zu expected %zu", srcLen, expectedLen);
        return -1;
    }

    id<MTLComputePipelineState> classifyPipeline = nil;
    id<MTLComputePipelineState> gatherPipeline = nil;
    if (!zsa_metal_prepare(block, &classifyPipeline, &gatherPipeline, why, whyLen)) return -1;

    double phase = CACurrentMediaTime();
    id<MTLTexture> sourceTexture = zsa_take_texture(format, width, height);
    if (!sourceTexture) {
        ZSA_WHY("Metal cannot allocate %ux%u source texture", width, height);
        return -1;
    }
    [sourceTexture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:src bytesPerRow:rowBytes];

    id<MTLBuffer> outputBuffer = zsa_take_buffer(encodedLen);
    id<MTLBuffer> metricBuffer = zsa_take_buffer(blockCount * sizeof(float));
    if (!outputBuffer || !metricBuffer) {
        zsa_give_texture(sourceTexture);
        zsa_give_buffer(outputBuffer);
        zsa_give_buffer(metricBuffer);
        ZSA_WHY("Metal buffer allocation failed for %zu-byte output", encodedLen);
        return -1;
    }

    ZSAParams params = { width, height, block, blocksX, srgb ? 1u : 0u, 0u, 0u, 0u };
    id<MTLCommandQueue> queue = zsa_queue_for(job->worker);
    int rc = zsa_classify(queue, classifyPipeline, sourceTexture, outputBuffer, metricBuffer, &params, blocksY, why, whyLen);
    if (rc != 0) {
        zsa_give_texture(sourceTexture);
        zsa_give_buffer(outputBuffer);
        zsa_give_buffer(metricBuffer);
        return -1;
    }

    uint8_t *encoded = (uint8_t *)malloc(encodedLen);
    uint32_t *refine = (uint32_t *)malloc(blockCount * sizeof(uint32_t));
    if (!encoded || !refine) {
        free(encoded);
        free(refine);
        zsa_give_texture(sourceTexture);
        zsa_give_buffer(outputBuffer);
        zsa_give_buffer(metricBuffer);
        ZSA_WHY("out of memory allocating %zu-byte ASTC output", encodedLen);
        return -1;
    }
    memcpy(encoded, outputBuffer.contents, encodedLen);
    float limit = zsa_accept_mse(job->quality) * (float)(block * block) * 3.0f;
    const float *metrics = (const float *)metricBuffer.contents;
    uint32_t refineCount = 0;
    for (size_t i = 0; i < blockCount; i++) {
        if (!(metrics[i] <= limit)) refine[refineCount++] = (uint32_t)i;
    }
    zsa_give_buffer(outputBuffer);
    zsa_give_buffer(metricBuffer);
    double gpuMs = ZSA_MS(phase);

    int result = 0;
    double cpuStart = CACurrentMediaTime();
    if (refineCount > 0) {
        uint32_t threads = job->threads;
        if (threads == 0) threads = (uint32_t)MIN((NSUInteger)4, MAX((NSUInteger)1, NSProcessInfo.processInfo.activeProcessorCount));
        uint32_t perChunk = MAX(1u, kZSAStripPixels / (block * block));
        astcenc_context *context = zsa_take_context(block, srgb, job->quality, threads, why, whyLen);
        id<MTLBuffer> pixelBuffer = zsa_take_buffer((size_t)perChunk * block * block * 4u);
        id<MTLBuffer> listBuffer = zsa_take_buffer((size_t)perChunk * sizeof(uint32_t));
        uint8_t *scratch = (uint8_t *)malloc((size_t)perChunk * 16u);
        if (!context || !pixelBuffer || !listBuffer || !scratch) {
            if (why && whyLen && why[0] == 0) ZSA_WHY("refinement resources unavailable");
            result = -1;
        }
        for (uint32_t start = 0; result == 0 && start < refineCount; start += perChunk) {
            uint32_t count = MIN(perChunk, refineCount - start);
            memcpy(listBuffer.contents, refine + start, (size_t)count * sizeof(uint32_t));
            result = zsa_gather(queue, gatherPipeline, sourceTexture, pixelBuffer, listBuffer, &params, count, why, whyLen);
            if (result != 0) break;
            result = zsa_refine(context, threads, pixelBuffer, block, count, scratch, why, whyLen);
            if (result != 0) break;
            for (uint32_t j = 0; j < count; j++) memcpy(encoded + (size_t)refine[start + j] * 16u, scratch + (size_t)j * 16u, 16u);
        }
        free(scratch);
        zsa_give_buffer(listBuffer);
        zsa_give_buffer(pixelBuffer);
        if (context) zsa_give_context(context, block, srgb, job->quality, threads);
    }
    double cpuMs = ZSA_MS(cpuStart);
    zsa_give_texture(sourceTexture);
    free(refine);
    if (result != 0) {
        free(encoded);
        return -1;
    }
    if (stats) {
        stats->blocks = (uint32_t)blockCount;
        stats->refined = refineCount;
        stats->gpuMs = gpuMs;
        stats->cpuMs = cpuMs;
    }
    *out = encoded;
    *outLen = encodedLen;
    ZSA_WHY("ASTC %ux%u q%d, %s, %u of %zu blocks refined by astcenc, gpu %.0f ms, cpu %.0f ms", block, block, (int)job->quality, srgb ? "sRGB" : "linear", refineCount, blockCount, gpuMs, cpuMs);
    return 0;
}

int ZSAstcEncode(const ZSAstcJob *job, const uint8_t *src, size_t srcLen, uint8_t **out, size_t *outLen, ZSAstcStats *stats, char *why, size_t whyLen) {
    if (out) *out = NULL;
    if (outLen) *outLen = 0;
    if (stats) memset(stats, 0, sizeof(*stats));
    if (why && whyLen) why[0] = 0;
    if (!job || !src || !out || !outLen || job->width == 0 || job->height == 0 || !ZSAstcBlockSupported(job->block)) {
        ZSA_WHY("invalid ASTC encode input");
        return -1;
    }
    int rc;
    @autoreleasepool {
        rc = zsa_encode_inner(job, src, srcLen, out, outLen, stats, why, whyLen);
    }
    return rc;
}

NSData *ZSAstcEncodeRGBA8(NSData *rgba, uint32_t width, uint32_t height, uint32_t block, BOOL srgb, ZSAstcQuality quality, NSError **error) {
    if (error) *error = nil;
    ZSAstcJob job = { width, height, block, srgb, quality, ZSAstcSourceRGBA8, 0, 0 };
    uint8_t *encoded = NULL;
    size_t encodedLen = 0;
    char why[256] = {0};
    int rc = ZSAstcEncode(&job, (const uint8_t *)rgba.bytes, rgba.length, &encoded, &encodedLen, NULL, why, sizeof(why));
    if (rc != 0 || !encoded) {
        if (error) *error = [NSError errorWithDomain:@"ZSAstcErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey: why[0] ? [NSString stringWithUTF8String:why] : @"ASTC encoding failed."}];
        return nil;
    }
    ZLog(@"[ASTC] %s", why);
    return [NSData dataWithBytesNoCopy:encoded length:encodedLen freeWhenDone:YES];
}
