#import "Transcoder.h"
#import "ZTweakLog.h"
#import "UnityBundleTools.h"
#import "Mods.h"
#import "Astc.h"
#import "Crunch.h"
#import "Engine.h"
#import "IL2CppIntrospection.h"
#import <Metal/Metal.h>
#import <os/lock.h>
#import <os/proc.h>
#include <stdatomic.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <lz4hc.h>
#import <objc/runtime.h>
#import <errno.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

NSString * const ZTranscoderServiceErrorDomain = @"ZTranscoderServiceErrorDomain";

static NSString * const kZSTranscoderTempPrefix = @"zst-local-transcoder-";
static const uint32_t kZSTranscoderBlockSize = 131072u;
static const uint32_t kZSTranscoderUnityFSFlagsPaddingAtStart = 0x200u;
static const uint32_t kZSTranscoderUnityFSFlagsInfoAtEnd = 0x80u;
static const uint32_t kZSTranscoderUnityFSCompressionMask = 0x3fu;
static const uint32_t kZSTranscoderMaxTextureDimension = 16384u;
static const int32_t kZTClassTexture2D = 28;
static const int32_t kZTClassSprite = 213;
static const int32_t kZTClassSpriteRenderer = 212;
static const int32_t kZTClassSpriteMask = 331;
static const int32_t kZTClassSpriteAtlas = 687078895;
static const int32_t kZTClassTextAsset = 49;
static const int32_t kZTClassAssetBundle = 142;
static const int32_t kZTClassShader = 48;
static const uint32_t kZTTargetPlatformIOS = 9u;

static BOOL zt_class_is_transcoded(int32_t classID) {
    return classID == kZTClassTexture2D
        || classID == kZTClassSprite
        || classID == kZTClassSpriteRenderer
        || classID == kZTClassSpriteMask
        || classID == kZTClassSpriteAtlas
        || classID == kZTClassTextAsset
        || classID == kZTClassAssetBundle;
}

static BOOL zt_class_transplant_enabled(int32_t classID) {
    switch (classID) {
        case kZTClassSprite:
        case kZTClassSpriteAtlas:
        case kZTClassSpriteRenderer:
        case kZTClassSpriteMask:
        case kZTClassTextAsset:
        case kZTClassAssetBundle:
            return NO;
        default:
            return YES;
    }
}

static BOOL zt_class_is_transplantable(int32_t classID, BOOL layoutShared) {
    if (!zt_class_transplant_enabled(classID)) return NO;
    if (zt_class_is_transcoded(classID)) return YES;
    if (!layoutShared) return NO;
    switch (classID) {
        case 0:
        case 48:
        case 72:
        case 115:
        case 142:
        case 150:
        case 200:
            return NO;
        default:
            return YES;
    }
}

NSError *ZTMakeTranscoderError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown transcoder error."}];
}

static uint32_t zt_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static uint64_t zt_be64(const uint8_t *p) {
    uint64_t hi = zt_be32(p);
    uint64_t lo = zt_be32(p + 4);
    return (hi << 32) | lo;
}

static uint32_t zt_le32(const uint8_t *p) {
    return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t zt_le64(const uint8_t *p) {
    uint64_t lo = zt_le32(p);
    uint64_t hi = zt_le32(p + 4);
    return lo | (hi << 32);
}

static void zt_put_be32(NSMutableData *data, uint32_t value) {
    uint8_t b[4] = {(uint8_t)(value >> 24), (uint8_t)(value >> 16), (uint8_t)(value >> 8), (uint8_t)value};
    [data appendBytes:b length:4];
}

static void zt_put_be64(NSMutableData *data, uint64_t value) {
    uint8_t b[8] = {
        (uint8_t)(value >> 56), (uint8_t)(value >> 48), (uint8_t)(value >> 40), (uint8_t)(value >> 32),
        (uint8_t)(value >> 24), (uint8_t)(value >> 16), (uint8_t)(value >> 8), (uint8_t)value
    };
    [data appendBytes:b length:8];
}

static void zt_put_be16(NSMutableData *data, uint16_t value) {
    uint8_t b[2] = {(uint8_t)(value >> 8), (uint8_t)value};
    [data appendBytes:b length:2];
}

static uint64_t zt_align_up(uint64_t value, uint64_t alignment) {
    if (alignment <= 1) return value;
    uint64_t mask = alignment - 1;
    if (value > UINT64_MAX - mask) return UINT64_MAX;
    return (value + mask) & ~mask;
}

#define ZT_MAX_SLOTS 16
static const uint64_t kZTWorkerMemoryFloor = 160ull * 1024ull * 1024ull;

typedef uint64_t (^ZTEstimateBlock)(NSUInteger index);
typedef BOOL (^ZTWorkBlock)(NSUInteger index, uint32_t worker, uint32_t threads);

typedef struct {
    _Atomic(NSUInteger) next;
    _Atomic(int) stop;
    _Atomic(NSUInteger) live;
    NSUInteger count;
    NSUInteger cap;
    uint32_t threads;
} ZTRunState;

static os_unfair_lock g_ztSlotLock = OS_UNFAIR_LOCK_INIT;
static BOOL g_ztSlotBusy[ZT_MAX_SLOTS];

static NSUInteger zt_slot_total(void) {
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    return MIN((NSUInteger)ZT_MAX_SLOTS, MAX((NSUInteger)1, cores));
}

static dispatch_semaphore_t zt_slot_semaphore(void) {
    static dispatch_semaphore_t semaphore;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        semaphore = dispatch_semaphore_create((long)zt_slot_total());
        ZLog(@"[ZTranscoder] worker pool sized to %lu worker(s)", (unsigned long)zt_slot_total());
    });
    return semaphore;
}

static int zt_slot_take(BOOL wait) {
    dispatch_time_t when = wait ? DISPATCH_TIME_FOREVER : DISPATCH_TIME_NOW;
    if (dispatch_semaphore_wait(zt_slot_semaphore(), when) != 0) return -1;
    int slot = -1;
    os_unfair_lock_lock(&g_ztSlotLock);
    for (int i = 0; i < ZT_MAX_SLOTS; i++) {
        if (!g_ztSlotBusy[i]) {
            g_ztSlotBusy[i] = YES;
            slot = i;
            break;
        }
    }
    os_unfair_lock_unlock(&g_ztSlotLock);
    return slot;
}

static void zt_slot_give(int slot) {
    if (slot < 0) return;
    os_unfair_lock_lock(&g_ztSlotLock);
    g_ztSlotBusy[slot] = NO;
    os_unfair_lock_unlock(&g_ztSlotLock);
    dispatch_semaphore_signal(zt_slot_semaphore());
}

static BOOL zt_memory_allows(uint64_t need) {
    int64_t available = (int64_t)os_proc_available_memory();
    return available <= 0 || (uint64_t)available >= need + kZTWorkerMemoryFloor;
}

static NSOperationQueue *zt_job_queue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [NSOperationQueue new];
        queue.name = @"zs.transcoder.jobs";
        queue.qualityOfService = NSQualityOfServiceUserInitiated;
    });
    queue.maxConcurrentOperationCount = zs_transcoder_parallel_enabled() ? (NSInteger)zt_slot_total() : 1;
    return queue;
}

static void zt_run_worker(ZTRunState *state, dispatch_group_t group, ZTEstimateBlock estimate, ZTWorkBlock work, int slot);

static void zt_run_spawn(ZTRunState *state, dispatch_group_t group, ZTEstimateBlock estimate, ZTWorkBlock work, int slot) {
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        zt_run_worker(state, group, estimate, work, slot);
    });
}

static void zt_run_worker(ZTRunState *state, dispatch_group_t group, ZTEstimateBlock estimate, ZTWorkBlock work, int slot) {
    uint32_t threads = state->threads;
    ZLog(@"[ZTranscoder] worker %d started", slot);
    NSUInteger handled = 0;
    for (;;) {
        if (atomic_load(&state->stop)) break;
        NSUInteger peek = atomic_load(&state->next);
        if (peek >= state->count) break;
        NSUInteger live = atomic_load(&state->live);
        if (live < state->cap && state->count - peek > live) {
            uint64_t need = estimate ? estimate(peek) : 0;
            if (zt_memory_allows(need)) {
                int extra = zt_slot_take(NO);
                if (extra >= 0) {
                    NSUInteger expected = live;
                    if (atomic_compare_exchange_strong(&state->live, &expected, live + 1)) {
                        zt_run_spawn(state, group, estimate, work, extra);
                    } else {
                        zt_slot_give(extra);
                    }
                }
            }
        }
        NSUInteger index = atomic_fetch_add(&state->next, 1);
        if (index >= state->count) break;
        BOOL ok = NO;
        @autoreleasepool {
            ok = work(index, (uint32_t)slot, threads);
        }
        handled++;
        if (!ok) atomic_store(&state->stop, 1);
    }
    atomic_fetch_sub(&state->live, 1);
    ZLog(@"[ZTranscoder] worker %d exiting, %lu texture(s) handled", slot, (unsigned long)handled);
    zt_slot_give(slot);
}

static void zt_parallel_run(NSUInteger count, BOOL parallel, ZTEstimateBlock estimate, ZTWorkBlock work) {
    if (count == 0) return;
    int slot = zt_slot_take(YES);
    ZTRunState state;
    atomic_init(&state.next, 0);
    atomic_init(&state.stop, 0);
    atomic_init(&state.live, 1);
    state.count = count;
    state.cap = parallel ? MIN(count, zt_slot_total()) : 1;
    state.threads = parallel ? (zt_slot_total() > 1 ? 1u : 0u) : 1u;
    ZLog(@"[ZTranscoder] transcoding %lu texture(s) with up to %lu worker(s)%@", (unsigned long)count, (unsigned long)state.cap, parallel ? @"" : @" (parallel processing disabled)");
    dispatch_group_t group = dispatch_group_create();
    zt_run_worker(&state, group, estimate, work, slot);
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

static NSString *zt_temp_directory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@", kZSTranscoderTempPrefix, NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    return path;
}

static BOOL zt_write_all(NSFileHandle *handle, const void *bytes, NSUInteger length, NSError **error) {
    if (!handle) return NO;
    @try {
        if (length) [handle writeData:[NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO]];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, exception.reason ?: @"File write failed.");
        return NO;
    }
}

static BOOL zt_copy_range_to_handle(NSFileHandle *handle, const uint8_t *base, uint64_t offset, uint64_t length, NSError **error) {
    if (!handle || (!base && length)) return NO;
    const size_t chunk = 1024u * 1024u;
    while (length) {
        size_t n = (size_t)MIN((uint64_t)chunk, length);
        if (!zt_write_all(handle, base + offset, n, error)) return NO;
        offset += n;
        length -= n;
    }
    return YES;
}

static BOOL zt_copy_file_to_handle(NSFileHandle *output, NSString *path, NSError **error) {
    NSFileHandle *input = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!input) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Couldn't open temporary asset at %@.", path]);
        return NO;
    }
    @try {
        BOOL finished = NO;
        while (!finished) {
            @autoreleasepool {
                NSData *chunk = [input readDataOfLength:1024u * 1024u];
                if (chunk.length == 0) {
                    finished = YES;
                } else if (!zt_write_all(output, chunk.bytes, chunk.length, error)) {
                    [input closeFile];
                    return NO;
                }
            }
        }
    } @catch (NSException *exception) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, exception.reason ?: @"Temporary asset read failed.");
        [input closeFile];
        return NO;
    }
    [input closeFile];
    return YES;
}

static uint64_t zt_file_size(NSString *path) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [attrs[NSFileSize] unsignedLongLongValue];
}

static BOOL zt_format_is_crunched(int32_t format) {
    return format == 28 || format == 29 || format == 64 || format == 65;
}

static NSString *zt_format_name(int32_t format) {
    switch (format) {
        case 3: return @"RGB24";
        case 4: return @"RGBA32";
        case 10: return @"DXT1";
        case 12: return @"DXT5";
        case 28: return @"DXT1 Crunched";
        case 29: return @"DXT5 Crunched";
        case 34: return @"ETC RGB4";
        case 45: return @"ETC2 RGB";
        case 46: return @"ETC2 RGBA1";
        case 47: return @"ETC2 RGBA8";
        case 48: case 54: return @"ASTC 4x4";
        case 49: case 55: return @"ASTC 5x5";
        case 50: case 56: return @"ASTC 6x6";
        case 51: case 57: return @"ASTC 8x8";
        case 52: case 58: return @"ASTC 10x10";
        case 53: case 59: return @"ASTC 12x12";
        case 63: return @"R8";
        case 64: return @"ETC Crunched";
        case 65: return @"ETC2 RGBA8 Crunched";
        default: return [NSString stringWithFormat:@"Format %d", format];
    }
}

@interface ZTSerializedObject : NSObject
@property (nonatomic, assign) int32_t classID;
@property (nonatomic, assign) int32_t typeIndex;
@property (nonatomic, assign) int64_t pathID;
@property (nonatomic, assign) uint64_t byteStart;
@property (nonatomic, assign) uint32_t byteSize;
@property (nonatomic, assign) uint64_t objectStart;
@property (nonatomic, strong, nullable) NSData *replacementObject;
@end

@implementation ZTSerializedObject
@end

@interface ZTTextureRecord : NSObject
@property (nonatomic, strong) ZTSerializedObject *object;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;
@property (nonatomic, assign) uint32_t completeImageSize;
@property (nonatomic, assign) int32_t format;
@property (nonatomic, assign) int32_t mipCount;
@property (nonatomic, assign) int32_t colorSpace;
@property (nonatomic, assign) BOOL readable;
@property (nonatomic, assign) uint32_t imageDataLength;
@property (nonatomic, assign) uint64_t imageDataPosition;
@property (nonatomic, assign) uint64_t formatPosition;
@property (nonatomic, assign) uint64_t completeSizePosition;
@property (nonatomic, assign) uint64_t mipCountPosition;
@property (nonatomic, assign) uint64_t streamOffsetPosition;
@property (nonatomic, assign) uint64_t streamSizePosition;
@property (nonatomic, assign) uint64_t streamPathPosition;
@property (nonatomic, assign) uint64_t streamOffset;
@property (nonatomic, assign) uint32_t streamSize;
@property (nonatomic, assign) uint32_t streamPathLength;
@property (nonatomic, copy) NSString *streamPath;
@end

@implementation ZTTextureRecord
- (BOOL)isStreamed { return self.imageDataLength == 0 && self.streamSize > 0; }
- (BOOL)isInline { return self.imageDataLength > 0; }
@end

@interface ZTSerializedDocument : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) uint64_t dataOffset;
@property (nonatomic, assign) uint64_t objectTableOffset;
@property (nonatomic, assign) uint64_t objectCountOffset;
@property (nonatomic, copy) NSArray<ZTSerializedObject *> *objects;
@property (nonatomic, copy) NSArray<ZTTextureRecord *> *textures;
@property (nonatomic, assign) uint32_t parseFailures;
@property (nonatomic, assign) NSUInteger originalObjectCount;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *classTypeIndex;
@property (nonatomic, copy) NSArray<NSString *> *typeKeys;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *typeIndexByKey;
@property (nonatomic, copy) NSData *trailer;
@property (nonatomic, assign) uint64_t typeCountOffset;
@property (nonatomic, assign) uint64_t targetPlatformOffset;
@property (nonatomic, assign) uint32_t targetPlatform;
@property (nonatomic, assign) BOOL rewritesPlatform;
@property (nonatomic, assign) uint32_t outputPlatform;
@property (nonatomic, copy) NSArray<NSValue *> *typeRanges;
@property (nonatomic, strong) NSMutableArray<NSData *> *injectedTypes;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSDictionary<NSString *, NSData *> *> *textureTrees;
@end

@implementation ZTSerializedDocument
@end

@interface ZTCarra2Item : NSObject
@property (nonatomic, assign) int64_t pathID;
@property (nonatomic, assign) int32_t typeHint;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSData *data;
@end

@implementation ZTCarra2Item
@end

@interface ZTTextureReplacement : NSObject
@property (nonatomic, strong) ZTTextureRecord *source;
@property (nonatomic, strong) ZTTextureRecord *target;
@property (nonatomic, copy) NSString *encodedPath;
@property (nonatomic, assign) uint32_t encodedSize;
@property (nonatomic, assign) uint64_t targetStreamOffset;
@property (nonatomic, copy, nullable) NSData *replacementObject;
@property (nonatomic, strong, nullable) ZTTextureRecord *baseTexture;
@property (nonatomic, copy, nullable) NSData *baseObjectData;
@property (nonatomic, assign) int32_t outputFormat;
@property (nonatomic, assign) int32_t outputMipCount;
@end

@implementation ZTTextureReplacement
@end

static NSString * const kZSTranscoderSettingsSection = @"transcoder";
static NSString * const kZSTranscoderCodecKey = @"codec";
static NSString * const kZSTranscoderRGBA32PassthroughKey = @"rgba32Passthrough";
static NSString * const kZSTranscoderParallelKey = @"parallel";

ZSTranscoderCodec zs_transcoder_codec(void) {
    id stored = zs_settings_section(kZSTranscoderSettingsSection)[kZSTranscoderCodecKey];
    NSInteger value = [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : ZSTranscoderCodecASTC6x6;
    return (value >= ZSTranscoderCodecASTC6x6 && value <= ZSTranscoderCodecRGBA32) ? (ZSTranscoderCodec)value : ZSTranscoderCodecASTC6x6;
}

void zs_set_transcoder_codec(ZSTranscoderCodec codec) {
    NSMutableDictionary *section = [zs_settings_section(kZSTranscoderSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSTranscoderCodecKey] = @(codec);
    zs_write_settings_section(kZSTranscoderSettingsSection, section);
}

BOOL zs_transcoder_rgba32_passthrough(void) {
    id stored = zs_settings_section(kZSTranscoderSettingsSection)[kZSTranscoderRGBA32PassthroughKey];
    return [stored respondsToSelector:@selector(boolValue)] ? [stored boolValue] : NO;
}

void zs_set_transcoder_rgba32_passthrough(BOOL enabled) {
    NSMutableDictionary *section = [zs_settings_section(kZSTranscoderSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSTranscoderRGBA32PassthroughKey] = @(enabled);
    zs_write_settings_section(kZSTranscoderSettingsSection, section);
}

BOOL zs_transcoder_parallel_enabled(void) {
    id stored = zs_settings_section(kZSTranscoderSettingsSection)[kZSTranscoderParallelKey];
    return [stored respondsToSelector:@selector(boolValue)] ? [stored boolValue] : YES;
}

void zs_set_transcoder_parallel_enabled(BOOL enabled) {
    NSMutableDictionary *section = [zs_settings_section(kZSTranscoderSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSTranscoderParallelKey] = @(enabled);
    zs_write_settings_section(kZSTranscoderSettingsSection, section);
}

NSUInteger zs_transcoder_core_count(void) {
    return zt_slot_total();
}

typedef struct {
    int32_t format;
    uint32_t block;
    BOOL passthroughRGBA32;
    BOOL parallel;
} ZTTarget;

static ZTTarget zt_current_target(void) {
    ZTTarget target = {0};
    switch (zs_transcoder_codec()) {
        case ZSTranscoderCodecASTC8x8: target.block = 8u; break;
        case ZSTranscoderCodecASTC10x10: target.block = 10u; break;
        case ZSTranscoderCodecRGBA32: target.block = 0u; break;
        default: target.block = 6u; break;
    }
    target.format = target.block ? ZSAstcUnityFormat(target.block) : 4;
    target.passthroughRGBA32 = target.block != 0u && zs_transcoder_rgba32_passthrough();
    target.parallel = zs_transcoder_parallel_enabled();
    return target;
}

static NSString *zt_target_name(ZTTarget target) {
    return target.block ? [NSString stringWithFormat:@"ASTC %ux%u", target.block, target.block] : @"RGBA32";
}

static BOOL zt_texture_is_untouched(ZTTextureRecord *texture, ZTTarget target) {
    return texture.format == target.format || (target.passthroughRGBA32 && texture.format == 4);
}

static int zt_type_tree_subtree_end(const uint8_t *nodes, uint32_t count, uint32_t i) {
    uint8_t level = nodes[(size_t)i * 32u + 2u];
    uint32_t j = i + 1;
    while (j < count && nodes[(size_t)j * 32u + 2u] > level) j++;
    return (int)j;
}

static const char *zt_type_tree_string(const uint8_t *nodes, uint32_t nodeCount, const uint8_t *strings, uint32_t stringSize, uint32_t i, uint32_t fieldOffset) {
    if (i >= nodeCount || !strings) return NULL;
    uint32_t nameOffset = zt_le32(nodes + (size_t)i * 32u + fieldOffset);
    if (nameOffset & 0x80000000u || nameOffset >= stringSize) return NULL;
    const uint8_t *p = strings + nameOffset;
    const uint8_t *end = strings + stringSize;
    const uint8_t *q = p;
    while (q < end && *q) q++;
    if (q >= end) return NULL;
    return (const char *)p;
}

static const char *zt_type_tree_name(const uint8_t *nodes, uint32_t nodeCount, const uint8_t *strings, uint32_t stringSize, uint32_t i) {
    return zt_type_tree_string(nodes, nodeCount, strings, stringSize, i, 8u);
}

static uint64_t zt_align4_from(uint64_t start, uint64_t pos) {
    uint64_t rel = pos - start;
    return start + ((rel + 3u) & ~3ULL);
}

static int zt_walk_tree(const uint8_t *nodes, uint32_t nodeCount, const uint8_t *buf, uint64_t start, uint64_t limit, uint32_t i, uint64_t *pos, int depth) {
    if (depth > 24 || i >= nodeCount || *pos > limit) return -1;
    uint8_t level = nodes[(size_t)i * 32u + 2u];
    uint8_t flags = nodes[(size_t)i * 32u + 3u];
    int32_t byteSize = (int32_t)zt_le32(nodes + (size_t)i * 32u + 12u);
    int32_t meta = (int32_t)zt_le32(nodes + (size_t)i * 32u + 20u);
    int end = zt_type_tree_subtree_end(nodes, nodeCount, i);
    if (flags & 1u) {
        if (end < (int)i + 3 || limit - *pos < 4) return -1;
        uint32_t count = zt_le32(buf + *pos);
        *pos += 4;
        uint32_t dataNode = i + 2;
        int dataEnd = zt_type_tree_subtree_end(nodes, nodeCount, dataNode);
        int32_t dataSize = (int32_t)zt_le32(nodes + (size_t)dataNode * 32u + 12u);
        if (dataEnd == (int)dataNode + 1 && dataSize > 0) {
            uint64_t bytes = (uint64_t)count * (uint64_t)dataSize;
            if (bytes > limit - *pos) return -1;
            *pos += bytes;
        } else {
            for (uint32_t k = 0; k < count; k++) {
                if (zt_walk_tree(nodes, nodeCount, buf, start, limit, dataNode, pos, depth + 1) < 0) return -1;
            }
        }
        if (meta & 0x4000) *pos = zt_align4_from(start, *pos);
        return *pos <= limit ? end : -1;
    }
    if (end > (int)i + 1) {
        uint32_t j = i + 1;
        while (j < (uint32_t)end) {
            int next = zt_walk_tree(nodes, nodeCount, buf, start, limit, j, pos, depth + 1);
            if (next < 0) return -1;
            j = (uint32_t)next;
        }
        if (meta & 0x4000) *pos = zt_align4_from(start, *pos);
        return *pos <= limit ? end : -1;
    }
    if (byteSize <= 0 || (uint64_t)byteSize > limit - *pos) return -1;
    *pos += (uint64_t)byteSize;
    if (meta & 0x4000) *pos = zt_align4_from(start, *pos);
    return *pos <= limit ? end : -1;
}

static BOOL zt_read_cstring(NSData *data, NSUInteger *pos, NSString **outString) {
    if (!data || !pos || *pos >= data.length) return NO;
    const uint8_t *bytes = data.bytes;
    NSUInteger i = *pos;
    while (i < data.length && bytes[i]) i++;
    if (i >= data.length) return NO;
    NSString *string = [[NSString alloc] initWithBytes:bytes + *pos length:i - *pos encoding:NSUTF8StringEncoding];
    if (!string) string = @"";
    *pos = i + 1;
    if (outString) *outString = string;
    return YES;
}

static BOOL zt_parse_texture(const uint8_t *buf, ZTSerializedObject *object, const uint8_t *nodes, uint32_t nodeCount, const uint8_t *strings, uint32_t stringSize, ZTTextureRecord **outTexture) {
    if (!buf || !nodes || !outTexture || nodeCount < 2) return NO;
    ZTTextureRecord *texture = [ZTTextureRecord new];
    texture.object = object;
    uint64_t start = object.objectStart;
    uint64_t limit = start + object.byteSize;
    uint64_t pos = start;
    uint32_t i = 1;
    unsigned found = 0;
    while (i < nodeCount) {
        uint64_t at = pos;
        const char *name = zt_type_tree_name(nodes, nodeCount, strings, stringSize, i);
        int end = zt_type_tree_subtree_end(nodes, nodeCount, i);
        if (name) {
            int32_t byteSize = (int32_t)zt_le32(nodes + (size_t)i * 32u + 12u);
            if (!strcmp(name, "m_Name")) {
                if (limit - at < 4) return NO;
                uint32_t len = zt_le32(buf + at);
                if (len > limit - at - 4) return NO;
                NSUInteger n = MIN((NSUInteger)len, (NSUInteger)127);
                texture.name = n ? [[NSString alloc] initWithBytes:buf + at + 4 length:n encoding:NSUTF8StringEncoding] : @"";
                if (!texture.name) texture.name = @"";
            } else if (!strcmp(name, "m_Width") && byteSize == 4 && limit - at >= 4) {
                texture.width = zt_le32(buf + at);
                found |= 1;
            } else if (!strcmp(name, "m_Height") && byteSize == 4 && limit - at >= 4) {
                texture.height = zt_le32(buf + at);
                found |= 2;
            } else if (!strcmp(name, "m_CompleteImageSize") && byteSize == 4 && limit - at >= 4) {
                texture.completeImageSize = zt_le32(buf + at);
                texture.completeSizePosition = at;
                found |= 4;
            } else if (!strcmp(name, "m_TextureFormat") && byteSize == 4 && limit - at >= 4) {
                texture.format = (int32_t)zt_le32(buf + at);
                texture.formatPosition = at;
                found |= 8;
            } else if (!strcmp(name, "m_MipCount") && byteSize == 4 && limit - at >= 4) {
                texture.mipCount = (int32_t)zt_le32(buf + at);
                texture.mipCountPosition = at;
                found |= 16;
            } else if (!strcmp(name, "m_IsReadable") && byteSize == 1 && limit - at >= 1) {
                texture.readable = buf[at] != 0;
                found |= 32;
            } else if (!strcmp(name, "m_ColorSpace") && byteSize == 4 && limit - at >= 4) {
                texture.colorSpace = (int32_t)zt_le32(buf + at);
                found |= 64;
            } else if (!strcmp(name, "image data") && limit - at >= 4) {
                texture.imageDataLength = zt_le32(buf + at);
                texture.imageDataPosition = at;
                found |= 128;
            } else if (!strcmp(name, "m_StreamData")) {
                if (end != (int)i + 7 || limit - at < 16) return NO;
                uint32_t streamPathLength = zt_le32(buf + at + 12);
                if (limit - at < 16u + streamPathLength) return NO;
                texture.streamOffset = zt_le64(buf + at);
                texture.streamOffsetPosition = at;
                texture.streamSize = zt_le32(buf + at + 8);
                texture.streamSizePosition = at + 8;
                texture.streamPathLength = streamPathLength;
                texture.streamPathPosition = at + 16;
                if (streamPathLength) {
                    texture.streamPath = [[NSString alloc] initWithBytes:buf + at + 16 length:streamPathLength encoding:NSUTF8StringEncoding] ?: @"";
                } else {
                    texture.streamPath = @"";
                }
                found |= 256;
            }
        }
        int next = zt_walk_tree(nodes, nodeCount, buf, start, limit, i, &pos, 0);
        if (next < 0) return NO;
        i = (uint32_t)next;
    }
    if (pos != limit || found != 511u || texture.width == 0 || texture.height == 0 || texture.mipCount <= 0) return NO;
    *outTexture = texture;
    return YES;
}

static ZTSerializedDocument *zt_parse_serialized(NSData *data, NSError **error) {
    if (!data || data.length < 64) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"SerializedFile is too small.");
        return nil;
    }
    const uint8_t *buf = data.bytes;
    uint32_t version = zt_be32(buf + 8);
    if (version != 22) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Unsupported SerializedFile version %u.", version]);
        return nil;
    }
    if (buf[16] != 0) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Big-endian SerializedFile is unsupported.");
        return nil;
    }
    uint64_t dataOffset = zt_be64(buf + 32);
    if (dataOffset > data.length) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"SerializedFile data offset is out of range.");
        return nil;
    }
    NSUInteger pos = 48;
    NSString *unityVersion = nil;
    if (!zt_read_cstring(data, &pos, &unityVersion) || data.length - pos < 9) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"SerializedFile metadata is truncated.");
        return nil;
    }
    uint64_t targetPlatformOffset = pos;
    uint32_t targetPlatform = zt_le32(buf + pos);
    pos += 4;
    uint8_t enableTypeTree = buf[pos++];
    if (!enableTypeTree) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"SerializedFile has no type trees.");
        return nil;
    }
    uint64_t typeCountOffset = pos;
    int32_t typeCount = (int32_t)zt_le32(buf + pos);
    pos += 4;
    if (typeCount <= 0 || typeCount > 4096) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"SerializedFile has an implausible type count.");
        return nil;
    }
    typedef struct { uint8_t *nodes; uint32_t count; uint8_t *strings; uint32_t stringSize; BOOL active; } ZTTree;
    ZTTree *trees = calloc((size_t)typeCount, sizeof(ZTTree));
    int32_t *classIDs = calloc((size_t)typeCount, sizeof(int32_t));
    if (!trees || !classIDs) {
        free(trees); free(classIDs);
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Couldn't allocate SerializedFile type metadata.");
        return nil;
    }
    BOOL ok = YES;
    NSMutableArray<NSString *> *typeKeys = [NSMutableArray arrayWithCapacity:(NSUInteger)typeCount];
    NSMutableArray<NSValue *> *typeRanges = [NSMutableArray arrayWithCapacity:(NSUInteger)typeCount];
    NSMutableDictionary<NSNumber *, NSDictionary<NSString *, NSData *> *> *textureTrees = [NSMutableDictionary dictionary];
    for (int32_t ti = 0; ti < typeCount && ok; ti++) {
        NSUInteger typeStart = pos;
        if (data.length - pos < 7) { ok = NO; break; }
        int32_t classID = (int32_t)zt_le32(buf + pos);
        classIDs[ti] = classID;
        pos += 4 + 1 + 2;
        NSMutableString *typeKey = [NSMutableString stringWithFormat:@"%d:", classID];
        if (classID == 114) {
            if (data.length - pos < 16) { ok = NO; break; }
            for (NSUInteger h = 0; h < 16; h++) [typeKey appendFormat:@"%02x", buf[pos + h]];
            [typeKey appendString:@":"];
            pos += 16;
        }
        if (data.length - pos < 24) { ok = NO; break; }
        for (NSUInteger h = 0; h < 16; h++) [typeKey appendFormat:@"%02x", buf[pos + h]];
        [typeKeys addObject:typeKey];
        pos += 16;
        uint32_t nodeCount = zt_le32(buf + pos);
        uint32_t stringSize = zt_le32(buf + pos + 4);
        pos += 8;
        uint64_t nodeBytes = (uint64_t)nodeCount * 32u;
        if (nodeCount > 100000 || stringSize > (16u << 20) || nodeBytes > data.length - pos || stringSize > data.length - pos - nodeBytes) { ok = NO; break; }
        if (classID == 28) {
            trees[ti].nodes = malloc((size_t)nodeBytes);
            if (!trees[ti].nodes) { ok = NO; break; }
            memcpy(trees[ti].nodes, buf + pos, (size_t)nodeBytes);
            trees[ti].count = nodeCount;
            trees[ti].strings = (uint8_t *)(buf + pos + nodeBytes);
            trees[ti].stringSize = stringSize;
            trees[ti].active = YES;
        }
        if (classID == 28 || classID == kZTClassSprite || classID == kZTClassSpriteAtlas) {
            textureTrees[@(ti)] = @{@"nodes": [NSData dataWithBytes:buf + pos length:(NSUInteger)nodeBytes], @"strings": [NSData dataWithBytes:buf + pos + nodeBytes length:stringSize]};
        }
        pos += (size_t)nodeBytes + stringSize;
        if (data.length - pos < 4) { ok = NO; break; }
        int32_t deps = (int32_t)zt_le32(buf + pos);
        pos += 4;
        if (deps < 0 || (uint64_t)deps * 4u > data.length - pos) { ok = NO; break; }
        pos += (size_t)deps * 4u;
        [typeRanges addObject:[NSValue valueWithRange:NSMakeRange(typeStart, pos - typeStart)]];
    }
    if (!ok || data.length - pos < 4) {
        for (int32_t i = 0; i < typeCount; i++) free(trees[i].nodes);
        free(trees); free(classIDs);
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"SerializedFile type metadata is truncated or malformed.");
        return nil;
    }
    uint64_t objectCountOffset = pos;
    int32_t objectCount = (int32_t)zt_le32(buf + pos);
    pos += 4;
    if (objectCount < 0 || objectCount > 4000000) {
        for (int32_t i = 0; i < typeCount; i++) free(trees[i].nodes);
        free(trees); free(classIDs);
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"SerializedFile object count is implausible.");
        return nil;
    }
    NSUInteger tablePos = (pos + 3u) & ~3u;
    if (dataOffset < tablePos || dataOffset > data.length) {
        for (int32_t i = 0; i < typeCount; i++) free(trees[i].nodes);
        free(trees); free(classIDs);
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"SerializedFile object table exceeds data offset.");
        return nil;
    }
    NSMutableArray<ZTSerializedObject *> *objects = [NSMutableArray arrayWithCapacity:(NSUInteger)objectCount];
    NSMutableArray<ZTTextureRecord *> *textures = [NSMutableArray array];
    uint32_t failures = 0;
    pos = tablePos;
    for (int32_t oi = 0; oi < objectCount; oi++) {
        pos = (pos + 3u) & ~3u;
        if (data.length - pos < 24) { failures++; break; }
        ZTSerializedObject *object = [ZTSerializedObject new];
        object.pathID = (int64_t)zt_le64(buf + pos);
        object.byteStart = zt_le64(buf + pos + 8);
        object.byteSize = zt_le32(buf + pos + 16);
        object.typeIndex = (int32_t)zt_le32(buf + pos + 20);
        if (object.typeIndex >= 0 && object.typeIndex < typeCount) object.classID = classIDs[object.typeIndex];
        object.objectStart = dataOffset + object.byteStart;
        if (object.objectStart > data.length || object.byteSize > data.length - object.objectStart) failures++;
        [objects addObject:object];
        if (object.classID == 28 && object.typeIndex >= 0 && object.typeIndex < typeCount && trees[object.typeIndex].active && object.objectStart <= data.length && object.byteSize <= data.length - object.objectStart) {
            ZTTextureRecord *texture = nil;
            if (zt_parse_texture(buf, object, trees[object.typeIndex].nodes, trees[object.typeIndex].count, trees[object.typeIndex].strings, trees[object.typeIndex].stringSize, &texture)) {
                [textures addObject:texture];
            } else {
                failures++;
            }
        }
        pos += 24;
    }
    if (failures || pos > dataOffset) {
        for (int32_t i = 0; i < typeCount; i++) free(trees[i].nodes);
        free(trees); free(classIDs);
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"SerializedFile object parsing failed for %u object(s).", failures]);
        return nil;
    }
    ZTSerializedDocument *document = [ZTSerializedDocument new];
    document.data = data;
    document.dataOffset = dataOffset;
    document.objectTableOffset = tablePos;
    document.objectCountOffset = objectCountOffset;
    document.objects = objects;
    document.textures = textures;
    document.parseFailures = failures;
    document.originalObjectCount = objects.count;
    NSMutableDictionary<NSNumber *, NSNumber *> *classTypeIndex = [NSMutableDictionary dictionary];
    for (int32_t i = 0; i < typeCount; i++) {
        if (classIDs[i] == 114) continue;
        NSNumber *classKey = @(classIDs[i]);
        if (!classTypeIndex[classKey]) classTypeIndex[classKey] = @(i);
    }
    document.classTypeIndex = classTypeIndex;
    document.typeKeys = typeKeys;
    document.typeRanges = typeRanges;
    document.typeCountOffset = typeCountOffset;
    document.targetPlatformOffset = targetPlatformOffset;
    document.targetPlatform = targetPlatform;
    document.injectedTypes = [NSMutableArray array];
    document.textureTrees = textureTrees;
    NSMutableDictionary<NSString *, NSNumber *> *typeIndexByKey = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < typeKeys.count; i++) if (!typeIndexByKey[typeKeys[i]]) typeIndexByKey[typeKeys[i]] = @(i);
    document.typeIndexByKey = typeIndexByKey;
    uint64_t trailerStart = tablePos + (uint64_t)objectCount * 24u;
    document.trailer = trailerStart <= dataOffset ? [data subdataWithRange:NSMakeRange((NSUInteger)trailerStart, (NSUInteger)(dataOffset - trailerStart))] : [NSData data];
    for (int32_t i = 0; i < typeCount; i++) free(trees[i].nodes);
    free(trees); free(classIDs);
    return document;
}

static UnityBundleNode *zt_resS_node(UnityBundleArchive *archive, NSError **error) {
    UnityBundleNode *resS = nil;
    for (UnityBundleNode *node in archive.nodes) {
        if ([node.path hasSuffix:@".resS"]) {
            if (resS) {
                if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Bundle contains multiple .resS nodes.");
                return nil;
            }
            resS = node;
        }
    }
    if (!resS) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Bundle has no .resS node.");
        return nil;
    }
    return resS;
}

static BOOL zt_texture_payload(ZTTextureRecord *texture, UnityBundleArchive *archive, NSData *serializedData, NSData **outPayload, NSError **error) {
    if (!texture || !serializedData || !outPayload) return NO;
    const uint8_t *base = serializedData.bytes;
    if (texture.isInline) {
        if ((uint64_t)texture.imageDataPosition + 4u + texture.imageDataLength > serializedData.length) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Inline Texture2D image data exceeds its SerializedFile object.");
            return NO;
        }
        *outPayload = [NSData dataWithBytesNoCopy:(void *)(base + texture.imageDataPosition + 4) length:texture.imageDataLength freeWhenDone:NO];
        return YES;
    }
    if (!archive) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"A streamed Texture2D has no resource stream to read from.");
        return NO;
    }
    UnityBundleNode *resS = zt_resS_node(archive, error);
    if (!resS || texture.streamOffset > (uint64_t)resS.size || texture.streamSize > (uint64_t)resS.size - texture.streamOffset) return NO;
    if (texture.streamPath.length > 0 && ![[resS.path lastPathComponent] isEqualToString:texture.streamPath.lastPathComponent]) {
        ZLog(@"[ZTranscoder] streamed path mismatch: object path=%@ node=%@", texture.streamPath, resS.path);
    }
    const uint8_t *streamBase = archive.data.bytes + resS.offset;
    *outPayload = [NSData dataWithBytesNoCopy:(void *)(streamBase + texture.streamOffset) length:texture.streamSize freeWhenDone:NO];
    return YES;
}

static BOOL zt_write_u32_at(NSMutableData *data, NSUInteger offset, uint32_t value) {
    if (offset > data.length || data.length - offset < 4) return NO;
    uint8_t b[4] = {(uint8_t)value, (uint8_t)(value >> 8), (uint8_t)(value >> 16), (uint8_t)(value >> 24)};
    memcpy((uint8_t *)data.mutableBytes + offset, b, 4);
    return YES;
}

static void zt_expand565(uint16_t color, uint8_t *rgb) {
    uint8_t r = (uint8_t)((color >> 11) & 31);
    uint8_t g = (uint8_t)((color >> 5) & 63);
    uint8_t b = (uint8_t)(color & 31);
    rgb[0] = (uint8_t)((r << 3) | (r >> 2));
    rgb[1] = (uint8_t)((g << 2) | (g >> 4));
    rgb[2] = (uint8_t)((b << 3) | (b >> 2));
}

static void zt_build_bc1_palette(const uint8_t *block, BOOL forceFourColor, uint8_t palette[4][4]) {
    uint16_t c0 = (uint16_t)(block[0] | (block[1] << 8));
    uint16_t c1 = (uint16_t)(block[2] | (block[3] << 8));
    zt_expand565(c0, palette[0]);
    zt_expand565(c1, palette[1]);
    palette[0][3] = 255;
    palette[1][3] = 255;
    palette[2][3] = 255;
    palette[3][3] = 255;
    if (c0 > c1 || forceFourColor) {
        for (int ch = 0; ch < 3; ch++) {
            palette[2][ch] = (uint8_t)((2 * palette[0][ch] + palette[1][ch]) / 3);
            palette[3][ch] = (uint8_t)((palette[0][ch] + 2 * palette[1][ch]) / 3);
        }
    } else {
        for (int ch = 0; ch < 3; ch++) palette[2][ch] = (uint8_t)((palette[0][ch] + palette[1][ch]) / 2);
        palette[3][0] = palette[3][1] = palette[3][2] = 0;
        palette[3][3] = 0;
    }
}

static BOOL zt_decode_dxt(NSData *pixels, uint8_t *dst, uint32_t width, uint32_t height, BOOL dxt5) {
    size_t blocksWide = ((size_t)width + 3u) / 4u;
    size_t blocksHigh = ((size_t)height + 3u) / 4u;
    size_t blockSize = dxt5 ? 16u : 8u;
    size_t needed = blocksWide * blocksHigh * blockSize;
    if (pixels.length < needed) return NO;
    const uint8_t *src = pixels.bytes;
    for (size_t by = 0; by < blocksHigh; by++) {
        for (size_t bx = 0; bx < blocksWide; bx++) {
            const uint8_t *block = src + (by * blocksWide + bx) * blockSize;
            const uint8_t *colorBlock = dxt5 ? block + 8 : block;
            uint8_t palette[4][4];
            zt_build_bc1_palette(colorBlock, dxt5, palette);
            uint32_t colorBits = (uint32_t)colorBlock[4] | ((uint32_t)colorBlock[5] << 8) | ((uint32_t)colorBlock[6] << 16) | ((uint32_t)colorBlock[7] << 24);
            uint8_t alphas[8] = {0};
            uint64_t alphaBits = 0;
            if (dxt5) {
                uint8_t a0 = block[0];
                uint8_t a1 = block[1];
                alphas[0] = a0;
                alphas[1] = a1;
                if (a0 > a1) {
                    for (int i = 1; i <= 6; i++) alphas[i + 1] = (uint8_t)(((7 - i) * a0 + i * a1) / 7);
                } else {
                    for (int i = 1; i <= 4; i++) alphas[i + 1] = (uint8_t)(((5 - i) * a0 + i * a1) / 5);
                    alphas[6] = 0;
                    alphas[7] = 255;
                }
                for (int i = 0; i < 6; i++) alphaBits |= ((uint64_t)block[2 + i]) << (8 * i);
            }
            for (int py = 0; py < 4; py++) {
                size_t y = by * 4u + (size_t)py;
                if (y >= height) break;
                for (int px = 0; px < 4; px++) {
                    size_t x = bx * 4u + (size_t)px;
                    if (x >= width) break;
                    int pixel = py * 4 + px;
                    uint32_t index = (colorBits >> (2 * pixel)) & 3u;
                    uint8_t *out = dst + (y * (size_t)width + x) * 4u;
                    memcpy(out, palette[index], 4);
                    if (dxt5) out[3] = alphas[(alphaBits >> (3 * pixel)) & 7u];
                }
            }
        }
    }
    return YES;
}

static id<MTLDevice> g_zstDecodeDevice;
static id<MTLCommandQueue> g_zstDecodeQueue;
static id<MTLComputePipelineState> g_zstDecodePipeline;
static dispatch_once_t g_zstDecodeOnce;
static NSString *g_zstDecodeError;

static BOOL zt_prepare_compressed_decoder(void) {
    dispatch_once(&g_zstDecodeOnce, ^{
        g_zstDecodeDevice = MTLCreateSystemDefaultDevice();
        if (!g_zstDecodeDevice) {
            g_zstDecodeError = @"Metal device unavailable for compressed texture decoding.";
            return;
        }
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void zst_decode_copy(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) { if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return; constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge); dst.write(src.sample(s, float2(gid) + 0.5), gid); }\n";
        NSError *error = nil;
        id<MTLLibrary> library = [g_zstDecodeDevice newLibraryWithSource:source options:nil error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"zst_decode_copy"];
        g_zstDecodeQueue = [g_zstDecodeDevice newCommandQueue];
        g_zstDecodePipeline = function ? [g_zstDecodeDevice newComputePipelineStateWithFunction:function error:&error] : nil;
        if (!g_zstDecodeQueue || !g_zstDecodePipeline) g_zstDecodeError = error.localizedDescription ?: @"Couldn't create compressed texture decoder.";
    });
    return g_zstDecodeDevice && g_zstDecodeQueue && g_zstDecodePipeline;
}

static BOOL zt_metal_decode(MTLPixelFormat pixelFormat, uint32_t blockWidth, uint32_t blockBytes, NSData *pixels, uint32_t width, uint32_t height, NSMutableData *rgba, NSError **error) {
    if (!zt_prepare_compressed_decoder()) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, g_zstDecodeError ?: @"Compressed texture decoder unavailable.");
        return NO;
    }
    uint32_t blocksWide = (width + blockWidth - 1u) / blockWidth;
    uint32_t blockHeight = blockWidth;
    uint32_t blocksHigh = (height + blockHeight - 1u) / blockHeight;
    size_t needed = (size_t)blocksWide * blocksHigh * blockBytes;
    if (pixels.length < needed) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Compressed texture data is shorter than its dimensions require.");
        return NO;
    }
    MTLTextureDescriptor *srcDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat width:width height:height mipmapped:NO];
    srcDesc.usage = MTLTextureUsageShaderRead;
    MTLTextureDescriptor *dstDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
    dstDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> source = [g_zstDecodeDevice newTextureWithDescriptor:srcDesc];
    id<MTLTexture> destination = [g_zstDecodeDevice newTextureWithDescriptor:dstDesc];
    if (!source || !destination) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Metal could not allocate compressed texture decoder resources.");
        return NO;
    }
    [source replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:(NSUInteger)blocksWide * blockBytes];
    id<MTLCommandBuffer> command = [g_zstDecodeQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:g_zstDecodePipeline];
    [encoder setTexture:source atIndex:0];
    [encoder setTexture:destination atIndex:1];
    MTLSize group = MTLSizeMake(16, 16, 1);
    MTLSize groups = MTLSizeMake((width + 15u) / 16u, (height + 15u) / 16u, 1);
    [encoder dispatchThreadgroups:groups threadsPerThreadgroup:group];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, command.error.localizedDescription ?: @"Metal failed to decode compressed texture data.");
        return NO;
    }
    [destination getBytes:rgba.mutableBytes bytesPerRow:(NSUInteger)width * 4u fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    return YES;
}

static BOOL zt_decode_crunched(int32_t format, NSData *payload, uint32_t width, uint32_t height, int32_t mipLevel, NSMutableData *rgba, NSError **error) {
    NSString *failure = nil;
    uint32_t levelWidth = 0, levelHeight = 0, bytesPerBlock = 0;
    NSData *blocks = ZSCrunchUnpackLevel(payload, (uint32_t)mipLevel, &levelWidth, &levelHeight, &bytesPerBlock, &failure);
    if (!blocks) {
        ZLog(@"[ZTranscoder] Crunch decode failed for %@ mip %d: %@", zt_format_name(format), mipLevel, failure ?: @"unknown");
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Crunch decode failed: %@", failure ?: @"unknown error"]);
        return NO;
    }
    if (levelWidth != width || levelHeight != height) {
        ZLog(@"[ZTranscoder] Crunch level %d is %ux%u but the texture expects %ux%u", mipLevel, levelWidth, levelHeight, width, height);
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Crunch level %d is %ux%u, expected %ux%u.", mipLevel, levelWidth, levelHeight, width, height]);
        return NO;
    }
    BOOL ok = NO;
    switch (format) {
        case 28:
            ok = bytesPerBlock == 8u && zt_decode_dxt(blocks, rgba.mutableBytes, width, height, NO);
            break;
        case 29:
            ok = bytesPerBlock == 16u && zt_decode_dxt(blocks, rgba.mutableBytes, width, height, YES);
            break;
        case 64:
            ok = bytesPerBlock == 8u && zt_metal_decode(MTLPixelFormatETC2_RGB8, 4, 8, blocks, width, height, rgba, error);
            break;
        case 65:
            ok = bytesPerBlock == 16u && zt_metal_decode(MTLPixelFormatEAC_RGBA8, 4, 16, blocks, width, height, rgba, error);
            break;
        default:
            break;
    }
    ZLog(@"[ZTranscoder] Crunch %@ mip %d decoded to RGBA %ux%u ok=%@ (bytesPerBlock=%u)", zt_format_name(format), mipLevel, width, height, ok ? @"YES" : @"NO", bytesPerBlock);
    if (!ok && error && !*error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Crunch block layout (%u bytes) doesn't match %@.", bytesPerBlock, zt_format_name(format)]);
    return ok;
}

static BOOL zt_decode_texture_mip(ZTTextureRecord *texture, NSData *payload, uint32_t width, uint32_t height, int32_t mipLevel, NSMutableData **outRGBA, NSError **error) {
    if (!texture || !payload || width == 0 || height == 0 || width > kZSTranscoderMaxTextureDimension || height > kZSTranscoderMaxTextureDimension) return NO;
    size_t pixelCount = (size_t)width * height;
    NSMutableData *rgba = [NSMutableData dataWithLength:pixelCount * 4u];
    if (!rgba) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Couldn't allocate RGBA decode memory.");
        return NO;
    }
    const uint8_t *src = payload.bytes;
    BOOL ok = NO;
    switch (texture.format) {
        case 3:
            if (payload.length >= pixelCount * 3u) {
                uint8_t *dst = rgba.mutableBytes;
                for (size_t i = 0; i < pixelCount; i++) {
                    dst[i * 4] = src[i * 3];
                    dst[i * 4 + 1] = src[i * 3 + 1];
                    dst[i * 4 + 2] = src[i * 3 + 2];
                    dst[i * 4 + 3] = 255;
                }
                ok = YES;
            }
            break;
        case 4:
            if (payload.length >= pixelCount * 4u) { memcpy(rgba.mutableBytes, src, pixelCount * 4u); ok = YES; }
            break;
        case 10:
        case 12:
            ok = zt_decode_dxt(payload, rgba.mutableBytes, width, height, texture.format == 12);
            break;
        case 34:
        case 45:
            ok = zt_metal_decode(MTLPixelFormatETC2_RGB8, 4, 8, payload, width, height, rgba, error);
            break;
        case 46:
            ok = zt_metal_decode(MTLPixelFormatETC2_RGB8A1, 4, 8, payload, width, height, rgba, error);
            break;
        case 47:
            ok = zt_metal_decode(MTLPixelFormatEAC_RGBA8, 4, 16, payload, width, height, rgba, error);
            break;
        case 48: case 54:
            ok = zt_metal_decode(MTLPixelFormatASTC_4x4_LDR, 4, 16, payload, width, height, rgba, error);
            break;
        case 49: case 55:
            ok = zt_metal_decode(MTLPixelFormatASTC_5x5_LDR, 5, 16, payload, width, height, rgba, error);
            break;
        case 50: case 56:
            ok = zt_metal_decode(MTLPixelFormatASTC_6x6_LDR, 6, 16, payload, width, height, rgba, error);
            break;
        case 51: case 57:
            ok = zt_metal_decode(MTLPixelFormatASTC_8x8_LDR, 8, 16, payload, width, height, rgba, error);
            break;
        case 52: case 58:
            ok = zt_metal_decode(MTLPixelFormatASTC_10x10_LDR, 10, 16, payload, width, height, rgba, error);
            break;
        case 53: case 59:
            ok = zt_metal_decode(MTLPixelFormatASTC_12x12_LDR, 12, 16, payload, width, height, rgba, error);
            break;
        case 63:
            if (payload.length >= pixelCount) {
                uint8_t *dst = rgba.mutableBytes;
                for (size_t i = 0; i < pixelCount; i++) dst[i * 4] = dst[i * 4 + 1] = dst[i * 4 + 2] = src[i], dst[i * 4 + 3] = 255;
                ok = YES;
            }
            break;
        default:
            if (zt_format_is_crunched(texture.format)) ok = zt_decode_crunched(texture.format, payload, width, height, mipLevel, rgba, error);
            break;
    }
    if (!ok && error && !*error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Unsupported or malformed Texture2D format %@ (%d).", zt_format_name(texture.format), texture.format]);
    if (ok && texture.format != 28 && texture.format != 29 && texture.format != 64 && texture.format != 65) *outRGBA = rgba;
    else *outRGBA = rgba;
    return ok;
}

static uint64_t zt_expected_mip_size(int32_t format, uint32_t width, uint32_t height) {
    uint64_t w = width, h = height;
    switch (format) {
        case 3: return w * h * 3u;
        case 4: return w * h * 4u;
        case 10: case 28: case 34: case 45: return ((w + 3u) / 4u) * ((h + 3u) / 4u) * (format == 10 || format == 28 ? 8u : 8u);
        case 12: case 29: case 47: case 65: return ((w + 3u) / 4u) * ((h + 3u) / 4u) * (format == 12 || format == 29 ? 16u : 16u);
        case 46: return ((w + 3u) / 4u) * ((h + 3u) / 4u) * 8u;
        case 48: case 54: return ((w + 3u) / 4u) * ((h + 3u) / 4u) * 16u;
        case 49: case 55: return ((w + 4u) / 5u) * ((h + 4u) / 5u) * 16u;
        case 50: case 56: return ((w + 5u) / 6u) * ((h + 5u) / 6u) * 16u;
        case 51: case 57: return ((w + 7u) / 8u) * ((h + 7u) / 8u) * 16u;
        case 52: case 58: return ((w + 9u) / 10u) * ((h + 9u) / 10u) * 16u;
        case 53: case 59: return ((w + 11u) / 12u) * ((h + 11u) / 12u) * 16u;
        case 63: return w * h;
        default: return 0;
    }
}

static BOOL zt_decode_base_level(ZTTextureRecord *texture, NSData *payload, NSMutableData **outRGBA, NSError **error) {
    if (!texture || !payload) return NO;
    if (!zt_format_is_crunched(texture.format)) {
        uint64_t baseSize = zt_expected_mip_size(texture.format, texture.width, texture.height);
        if (baseSize == 0 || baseSize > payload.length) return NO;
    }
    return zt_decode_texture_mip(texture, payload, texture.width, texture.height, 0, outRGBA, error);
}

typedef struct {
    int32_t start;
    int32_t count;
} ZTResizeSpan;

static BOOL zt_build_resize_spans(uint32_t srcSize, uint32_t dstSize, ZTResizeSpan **outSpans, float **outWeights, uint32_t *outStride) {
    double scale = (double)srcSize / (double)dstSize;
    double support = MAX(1.0, scale);
    uint32_t stride = (uint32_t)ceil(support * 2.0) + 3u;
    ZTResizeSpan *spans = calloc(dstSize, sizeof(ZTResizeSpan));
    float *weights = calloc((size_t)dstSize * stride, sizeof(float));
    if (!spans || !weights) {
        free(spans);
        free(weights);
        return NO;
    }
    for (uint32_t i = 0; i < dstSize; i++) {
        double center = ((double)i + 0.5) * scale;
        int64_t lo = (int64_t)floor(center - support);
        int64_t hi = (int64_t)ceil(center + support);
        if (lo < 0) lo = 0;
        if (hi > (int64_t)srcSize - 1) hi = (int64_t)srcSize - 1;
        float *row = weights + (size_t)i * stride;
        uint32_t count = 0;
        double total = 0.0;
        for (int64_t j = lo; j <= hi && count < stride; j++) {
            double d = fabs(((double)j + 0.5 - center) / support);
            double v = d < 1.0 ? 1.0 - d : 0.0;
            row[count++] = (float)v;
            total += v;
        }
        if (total <= 0.0) {
            int64_t nearest = (int64_t)floor(center);
            if (nearest < 0) nearest = 0;
            if (nearest > (int64_t)srcSize - 1) nearest = (int64_t)srcSize - 1;
            lo = nearest;
            row[0] = 1.0f;
            count = 1;
            total = 1.0;
        }
        for (uint32_t k = 0; k < count; k++) row[k] = (float)((double)row[k] / total);
        spans[i].start = (int32_t)lo;
        spans[i].count = (int32_t)count;
    }
    *outSpans = spans;
    *outWeights = weights;
    *outStride = stride;
    return YES;
}

static NSMutableData *zt_resize_rgba(NSData *rgba, uint32_t srcWidth, uint32_t srcHeight, uint32_t dstWidth, uint32_t dstHeight) {
    if (!rgba || srcWidth == 0 || srcHeight == 0 || dstWidth == 0 || dstHeight == 0) return nil;
    if (rgba.length < (size_t)srcWidth * srcHeight * 4u) return nil;
    ZTResizeSpan *hSpans = NULL, *vSpans = NULL;
    float *hWeights = NULL, *vWeights = NULL;
    uint32_t hStride = 0, vStride = 0;
    if (!zt_build_resize_spans(srcWidth, dstWidth, &hSpans, &hWeights, &hStride)) return nil;
    if (!zt_build_resize_spans(srcHeight, dstHeight, &vSpans, &vWeights, &vStride)) {
        free(hSpans);
        free(hWeights);
        return nil;
    }
    const size_t lane = 5u;
    size_t rowFloats = (size_t)dstWidth * lane;
    float *cache = malloc((size_t)vStride * rowFloats * sizeof(float));
    float *accumulator = malloc(rowFloats * sizeof(float));
    int64_t *tags = malloc((size_t)vStride * sizeof(int64_t));
    NSMutableData *output = [NSMutableData dataWithLength:(size_t)dstWidth * dstHeight * 4u];
    if (!cache || !accumulator || !tags || !output) {
        free(hSpans); free(hWeights); free(vSpans); free(vWeights);
        free(cache); free(accumulator); free(tags);
        return nil;
    }
    for (uint32_t i = 0; i < vStride; i++) tags[i] = -1;
    const float bias = 0.004f;
    const uint8_t *src = rgba.bytes;
    uint8_t *dst = output.mutableBytes;
    for (uint32_t y = 0; y < dstHeight; y++) {
        memset(accumulator, 0, rowFloats * sizeof(float));
        ZTResizeSpan vs = vSpans[y];
        const float *vw = vWeights + (size_t)y * vStride;
        for (int32_t k = 0; k < vs.count; k++) {
            float wv = vw[k];
            if (wv == 0.0f) continue;
            int64_t srcRow = (int64_t)vs.start + k;
            size_t slot = (size_t)(srcRow % (int64_t)vStride);
            float *cached = cache + slot * rowFloats;
            if (tags[slot] != srcRow) {
                const uint8_t *rowPixels = src + (size_t)srcRow * srcWidth * 4u;
                for (uint32_t x = 0; x < dstWidth; x++) {
                    ZTResizeSpan hs = hSpans[x];
                    const float *hw = hWeights + (size_t)x * hStride;
                    float r = 0, g = 0, b = 0, a = 0, n = 0;
                    for (int32_t j = 0; j < hs.count; j++) {
                        float w = hw[j];
                        if (w == 0.0f) continue;
                        const uint8_t *px = rowPixels + (size_t)(hs.start + j) * 4u;
                        float alpha = (float)px[3] * (1.0f / 255.0f);
                        float cw = w * (alpha + bias);
                        r += cw * (float)px[0];
                        g += cw * (float)px[1];
                        b += cw * (float)px[2];
                        a += w * alpha;
                        n += cw;
                    }
                    float *cell = cached + (size_t)x * lane;
                    cell[0] = r; cell[1] = g; cell[2] = b; cell[3] = a; cell[4] = n;
                }
                tags[slot] = srcRow;
            }
            for (size_t f = 0; f < rowFloats; f++) accumulator[f] += wv * cached[f];
        }
        uint8_t *outRow = dst + (size_t)y * dstWidth * 4u;
        for (uint32_t x = 0; x < dstWidth; x++) {
            const float *cell = accumulator + (size_t)x * lane;
            float n = cell[4] > 0.0f ? cell[4] : 1.0f;
            float values[4] = { cell[0] / n, cell[1] / n, cell[2] / n, cell[3] * 255.0f };
            for (int c = 0; c < 4; c++) {
                float v = values[c];
                if (v < 0.0f) v = 0.0f;
                if (v > 255.0f) v = 255.0f;
                outRow[(size_t)x * 4u + (size_t)c] = (uint8_t)(v + 0.5f);
            }
        }
    }
    free(hSpans); free(hWeights); free(vSpans); free(vWeights);
    free(cache); free(accumulator); free(tags);
    return output;
}

static BOOL zt_make_astc_replacement(ZTTextureRecord *source, ZTTextureRecord *destination, NSData *payload, NSString *workDir, NSString **outPath, uint32_t *outSize, NSError **error, void (^progress)(double, NSString *), uint32_t worker, uint32_t threads, ZTTarget target) {
    if (source.mipCount <= 0) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Texture2D has an invalid mip count.");
        return NO;
    }
    if (destination.width == 0 || destination.height == 0 || destination.width > kZSTranscoderMaxTextureDimension || destination.height > kZSTranscoderMaxTextureDimension) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Texture2D %@ has unsupported output dimensions %ux%u.", source.name, destination.width, destination.height]);
        return NO;
    }
    uint64_t baseSize = 0;
    if (zt_format_is_crunched(source.format)) {
        if (payload.length != source.completeImageSize) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Crunched Texture2D %@ payload size mismatch: object=%u payload=%lu.", source.name, source.completeImageSize, (unsigned long)payload.length]);
            return NO;
        }
    } else {
        baseSize = zt_expected_mip_size(source.format, source.width, source.height);
        if (baseSize == 0 || baseSize > payload.length) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Texture2D %@ has an invalid payload size for its base level (%@).", source.name, zt_format_name(source.format)]);
            return NO;
        }
    }
    NSString *outputPath = [workDir stringByAppendingPathComponent:[NSString stringWithFormat:@"texture-%lld.astc", (long long)source.object.pathID]];
    NSFileHandle *writer = [NSFileHandle fileHandleForWritingAtPath:outputPath];
    if (!writer) {
        [[NSFileManager defaultManager] createFileAtPath:outputPath contents:nil attributes:nil];
        writer = [NSFileHandle fileHandleForWritingAtPath:outputPath];
    }
    if (!writer) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Couldn't create temporary ASTC output for %@.", source.name]);
        return NO;
    }
    NSMutableData *rgba = nil;
    NSError *decodeError = nil;
    uint32_t outWidth = destination.width;
    uint32_t outHeight = destination.height;
    BOOL copyBase = !zt_format_is_crunched(source.format) && zt_texture_is_untouched(source, target) && source.width == outWidth && source.height == outHeight;
    NSData *baseCopy = copyBase ? [payload subdataWithRange:NSMakeRange(0, (NSUInteger)baseSize)] : nil;
    BOOL ok = YES;
    if (!copyBase) {
        ok = zt_decode_base_level(source, payload, &rgba, &decodeError);
        if (!ok && error) *error = decodeError ?: ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't decode Texture2D %@.", source.name]);
    }
    if (ok && !copyBase && (source.width != outWidth || source.height != outHeight)) {
        NSMutableData *resized = zt_resize_rgba(rgba, source.width, source.height, outWidth, outHeight);
        if (resized) {
            ZLog(@"[ZTranscoder] Texture2D PathID=%lld resized %ux%u -> %ux%u to match the original", (long long)source.object.pathID, source.width, source.height, outWidth, outHeight);
            rgba = resized;
        } else {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't resize Texture2D %@ from %ux%u to %ux%u.", source.name, source.width, source.height, outWidth, outHeight]);
            ok = NO;
        }
    }
    uint64_t totalOutput = 0;
    if (ok) {
        NSData *astc = nil;
        char encodeWhy[256] = {0};
        NSString *targetName = zt_target_name(target);
        if (copyBase) {
            astc = baseCopy;
        } else if (target.block == 0u) {
            uint64_t expectedLength = (uint64_t)outWidth * (uint64_t)outHeight * 4u;
            if ((uint64_t)rgba.length == expectedLength) {
                astc = rgba;
            } else {
                snprintf(encodeWhy, sizeof(encodeWhy), "decoded pixel buffer is %lu bytes, expected %llu", (unsigned long)rgba.length, (unsigned long long)expectedLength);
            }
        } else {
            ZSAstcJob astcJob = { outWidth, outHeight, target.block, destination.colorSpace != 0, ZSAstcQualityHigh, ZSAstcSourceRGBA8, worker, threads };
            uint8_t *encodedBytes = NULL;
            size_t encodedLength = 0;
            int encodeResult = ZSAstcEncode(&astcJob, (const uint8_t *)rgba.bytes, rgba.length, &encodedBytes, &encodedLength, NULL, encodeWhy, sizeof(encodeWhy));
            astc = (encodeResult == 0 && encodedBytes) ? [NSData dataWithBytesNoCopy:encodedBytes length:encodedLength freeWhenDone:YES] : nil;
            if (astc) ZLog(@"[ASTC] %s", encodeWhy);
        }
        rgba = nil;
        if (!astc) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, encodeWhy[0] ? [NSString stringWithFormat:@"Couldn't encode Texture2D %@ as %@: %s", source.name, targetName, encodeWhy] : [NSString stringWithFormat:@"Couldn't encode Texture2D %@ as %@.", source.name, targetName]);
            ok = NO;
        } else if (!zt_write_all(writer, astc.bytes, astc.length, error)) {
            ok = NO;
        } else {
            totalOutput = astc.length;
            if (progress) progress(1.0, [NSString stringWithFormat:@"%@ %@", copyBase ? @"Kept" : [NSString stringWithFormat:@"Encoded as %@:", targetName], destination.name.length ? destination.name : (source.name.length ? source.name : @"<unnamed>")]);
        }
    }
    @try { [writer closeFile]; } @catch (__unused NSException *exception) {}
    if (!ok) { [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil]; return NO; }
    if (totalOutput > UINT32_MAX) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"Texture output exceeds Unity's 32-bit Texture2D image-size field.");
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
        return NO;
    }
    if (outPath) *outPath = outputPath;
    if (outSize) *outSize = (uint32_t)totalOutput;
    return YES;
}

static BOOL zt_patch_u32_relative(NSMutableData *data, uint64_t base, uint64_t absolutePosition, uint32_t value) {
    if (absolutePosition < base || absolutePosition - base > data.length || data.length - (NSUInteger)(absolutePosition - base) < 4) return NO;
    return zt_write_u32_at(data, (NSUInteger)(absolutePosition - base), value);
}

static BOOL zt_texture_overwrite_layout(ZTTextureRecord *base, NSUInteger baseLength, uint32_t encodedSize, NSUInteger *outImageField, NSUInteger *outTailStart, NSUInteger *outTotal) {
    if (!base) return NO;
    uint64_t origin = base.object.objectStart;
    if (base.imageDataPosition < origin || base.streamOffsetPosition < origin) return NO;
    NSUInteger imageField = (NSUInteger)(base.imageDataPosition - origin);
    if (imageField > baseLength || baseLength - imageField < 4) return NO;
    NSUInteger oldImageStart = imageField + 4u;
    NSUInteger oldImageEnd = oldImageStart + base.imageDataLength;
    if (oldImageEnd > baseLength) return NO;
    NSUInteger oldStreamStart = (NSUInteger)(base.streamOffsetPosition - origin);
    if (oldStreamStart > baseLength || oldStreamStart < oldImageEnd) return NO;
    NSUInteger streamEnd = oldStreamStart + 16u + base.streamPathLength;
    if (streamEnd > baseLength) return NO;
    NSUInteger tailStart = MIN((streamEnd + 3u) & ~(NSUInteger)3u, baseLength);
    NSUInteger total = (imageField + 4u + (NSUInteger)encodedSize + 3u) & ~(NSUInteger)3u;
    total += 16u;
    if (tailStart < baseLength) total += baseLength - tailStart;
    uint64_t positions[3] = { base.formatPosition, base.mipCountPosition, base.completeSizePosition };
    for (int i = 0; i < 3; i++) {
        if (positions[i] < origin || positions[i] - origin > total || total - (NSUInteger)(positions[i] - origin) < 4) return NO;
    }
    if (outImageField) *outImageField = imageField;
    if (outTailStart) *outTailStart = tailStart;
    if (outTotal) *outTotal = total;
    return YES;
}

static NSData *zt_build_texture_object_overwrite(ZTTextureRecord *base, NSData *baseObject, int32_t format, int32_t mipCount, NSData *encodedData, uint32_t encodedSize) {
    if (!base || !baseObject || !encodedData || encodedData.length != encodedSize) return nil;
    NSUInteger imageField = 0, tailStart = 0, total = 0;
    if (!zt_texture_overwrite_layout(base, baseObject.length, encodedSize, &imageField, &tailStart, &total)) return nil;
    uint64_t origin = base.object.objectStart;
    NSMutableData *out = [NSMutableData dataWithCapacity:total];
    [out appendBytes:baseObject.bytes length:imageField];
    uint8_t imageLength[4] = {(uint8_t)encodedSize, (uint8_t)(encodedSize >> 8), (uint8_t)(encodedSize >> 16), (uint8_t)(encodedSize >> 24)};
    [out appendBytes:imageLength length:4];
    [out appendData:encodedData];
    while (out.length & 3u) { uint8_t zero = 0; [out appendBytes:&zero length:1]; }
    uint8_t streamZero[12] = {0};
    [out appendBytes:streamZero length:12];
    uint8_t emptyPathLength[4] = {0};
    [out appendBytes:emptyPathLength length:4];
    if (tailStart < baseObject.length) [out appendBytes:(const uint8_t *)baseObject.bytes + tailStart length:baseObject.length - tailStart];
    if (!zt_patch_u32_relative(out, origin, base.formatPosition, (uint32_t)format)) return nil;
    if (!zt_patch_u32_relative(out, origin, base.mipCountPosition, (uint32_t)mipCount)) return nil;
    if (!zt_patch_u32_relative(out, origin, base.completeSizePosition, encodedSize)) return nil;
    return out;
}

static NSNumber *zt_inject_type(ZTSerializedDocument *target, ZTSerializedDocument *source, int32_t sourceTypeIndex) {
    if (sourceTypeIndex < 0 || (NSUInteger)sourceTypeIndex >= source.typeKeys.count || source.typeRanges.count != source.typeKeys.count) return nil;
    NSString *key = source.typeKeys[(NSUInteger)sourceTypeIndex];
    NSNumber *existing = target.typeIndexByKey[key];
    if (existing) return existing;
    NSRange range = source.typeRanges[(NSUInteger)sourceTypeIndex].rangeValue;
    if (range.location > source.data.length || range.length > source.data.length - range.location) return nil;
    NSUInteger newIndex = target.typeKeys.count;
    [target.injectedTypes addObject:[source.data subdataWithRange:range]];
    target.typeKeys = [target.typeKeys arrayByAddingObject:key];
    NSMutableDictionary<NSString *, NSNumber *> *byKey = [target.typeIndexByKey mutableCopy];
    byKey[key] = @(newIndex);
    target.typeIndexByKey = byKey;
    int32_t classID = (int32_t)strtol(key.UTF8String, NULL, 10);
    if (classID != 114 && !target.classTypeIndex[@(classID)]) {
        NSMutableDictionary<NSNumber *, NSNumber *> *byClass = [target.classTypeIndex mutableCopy];
        byClass[@(classID)] = @(newIndex);
        target.classTypeIndex = byClass;
    }
    return @(newIndex);
}

static ZTSerializedObject *zt_find_object(NSDictionary<NSString *, ZTSerializedObject *> *map, int64_t pathID, int32_t classID) {
    return map[[NSString stringWithFormat:@"%d:%lld", classID, (long long)pathID]];
}

static NSDictionary<NSString *, ZTTextureRecord *> *zt_texture_map(NSArray<ZTTextureRecord *> *textures) {
    NSMutableDictionary *map = [NSMutableDictionary dictionaryWithCapacity:textures.count];
    for (ZTTextureRecord *texture in textures) map[[NSString stringWithFormat:@"%lld", (long long)texture.object.pathID]] = texture;
    return map;
}

static NSData *zt_object_data(ZTSerializedObject *object, NSData *data) {
    if (object.objectStart > data.length || object.byteSize > data.length - object.objectStart) return nil;
    return [NSData dataWithBytesNoCopy:(void *)((const uint8_t *)data.bytes + object.objectStart) length:object.byteSize freeWhenDone:NO];
}

static BOOL zt_rebuilt_object_size(ZTSerializedObject *object, ZTTextureReplacement *replacement, ZTSerializedDocument *targetDoc, uint64_t *outSize) {
    if (replacement) {
        if (!replacement.baseObjectData || !replacement.encodedPath) return NO;
        NSUInteger total = 0;
        if (!zt_texture_overwrite_layout(replacement.baseTexture, replacement.baseObjectData.length, replacement.encodedSize, NULL, NULL, &total)) return NO;
        *outSize = total;
        return YES;
    }
    if (object.replacementObject) {
        *outSize = object.replacementObject.length;
        return YES;
    }
    if (object.objectStart > targetDoc.data.length || object.byteSize > targetDoc.data.length - object.objectStart) return NO;
    *outSize = object.byteSize;
    return YES;
}

static NSData *zt_rebuilt_object_data(ZTSerializedObject *object, ZTTextureReplacement *replacement, ZTSerializedDocument *targetDoc) {
    if (replacement) {
        NSData *encoded = [NSData dataWithContentsOfFile:replacement.encodedPath options:NSDataReadingMappedIfSafe error:nil];
        if (!encoded) return nil;
        return replacement.baseObjectData ? zt_build_texture_object_overwrite(replacement.baseTexture, replacement.baseObjectData, replacement.outputFormat, replacement.outputMipCount, encoded, replacement.encodedSize) : nil;
    }
    if (object.replacementObject) return object.replacementObject;
    return zt_object_data(object, targetDoc.data);
}

static BOOL zt_rebuild_serialized_correctly(ZTSerializedDocument *targetDoc, NSDictionary<NSString *, ZTTextureReplacement *> *replacements, NSString *outputPath, NSError **error) {
    if (![[NSFileManager defaultManager] createFileAtPath:outputPath contents:nil attributes:nil]) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Couldn't create replacement SerializedFile at %@.", outputPath]);
        return NO;
    }
    NSMutableArray<NSNumber *> *newStarts = [NSMutableArray arrayWithCapacity:targetDoc.objects.count];
    NSMutableArray<NSNumber *> *newSizes = [NSMutableArray arrayWithCapacity:targetDoc.objects.count];
    const uint8_t *headerSource = targetDoc.data.bytes;
    NSUInteger addedCount = targetDoc.objects.count > targetDoc.originalObjectCount ? targetDoc.objects.count - targetDoc.originalObjectCount : 0;
    uint64_t originalTableEnd = targetDoc.objectTableOffset + (uint64_t)targetDoc.originalObjectCount * 24u;
    NSMutableData *injectedBytes = [NSMutableData data];
    for (NSData *typeData in targetDoc.injectedTypes) [injectedBytes appendData:typeData];
    uint64_t newTableOffset = targetDoc.objectTableOffset;
    if (injectedBytes.length) newTableOffset = (targetDoc.objectCountOffset + injectedBytes.length + 4u + 3u) & ~3ULL;
    uint64_t newDataOffset = targetDoc.dataOffset;
    if (addedCount > 0 || injectedBytes.length > 0) {
        if (targetDoc.data.length < 40 || zt_be32(headerSource + 8) < 22u || originalTableEnd > targetDoc.dataOffset) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"SerializedFile layout doesn't support adding objects.");
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
        uint64_t trailingLength = targetDoc.dataOffset - originalTableEnd;
        uint64_t grown = zt_align_up(newTableOffset + (uint64_t)targetDoc.objects.count * 24u + trailingLength, 16u);
        if (grown != UINT64_MAX && grown > newDataOffset) newDataOffset = grown;
    }
    uint64_t cursor = newDataOffset;
    uint64_t originalObjectsEnd = targetDoc.dataOffset;
    for (ZTSerializedObject *object in targetDoc.objects) {
        uint64_t objectEnd = object.objectStart + object.byteSize;
        if (objectEnd > originalObjectsEnd) originalObjectsEnd = objectEnd;
        uint64_t relativeCursor = zt_align_up(cursor - newDataOffset, 8u);
        cursor = relativeCursor == UINT64_MAX ? UINT64_MAX : newDataOffset + relativeCursor;
        if (cursor == UINT64_MAX || cursor < newDataOffset) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"SerializedFile output offset overflowed.");
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
        [newStarts addObject:@(cursor - newDataOffset)];
        NSString *key = [NSString stringWithFormat:@"%lld", (long long)object.pathID];
        ZTTextureReplacement *replacement = replacements[key];
        uint64_t objectSize = 0;
        if (!zt_rebuilt_object_size(object, replacement, targetDoc, &objectSize) || objectSize > UINT32_MAX) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Couldn't size rebuilt object PathID=%lld.", (long long)object.pathID]);
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
        [newSizes addObject:@(objectSize)];
        cursor += objectSize;
    }
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:outputPath];
    if (!out) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"Couldn't open rebuilt SerializedFile for writing.");
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
        return NO;
    }
    const uint8_t *base = targetDoc.data.bytes;
    uint64_t tableEnd = originalTableEnd;
    uint64_t tailLength = (originalObjectsEnd < targetDoc.data.length) ? (uint64_t)targetDoc.data.length - originalObjectsEnd : 0;
    uint64_t expectedFileSize = cursor + tailLength;
    NSMutableData *headerBytes = nil;
    uint64_t countPosition = targetDoc.objectCountOffset;
    if (injectedBytes.length) {
        headerBytes = [NSMutableData dataWithBytes:base length:(NSUInteger)targetDoc.objectCountOffset];
        [headerBytes appendData:injectedBytes];
        countPosition = headerBytes.length;
        uint8_t zeroCount[4] = {0};
        [headerBytes appendBytes:zeroCount length:4];
        while (headerBytes.length < newTableOffset) { uint8_t zero = 0; [headerBytes appendBytes:&zero length:1]; }
        if (targetDoc.typeCountOffset + 4u <= headerBytes.length) {
            uint8_t *typeCountBytes = (uint8_t *)headerBytes.mutableBytes + targetDoc.typeCountOffset;
            uint32_t newTypeCount = zt_le32(typeCountBytes) + (uint32_t)targetDoc.injectedTypes.count;
            for (NSUInteger b = 0; b < 4; b++) typeCountBytes[b] = (uint8_t)(newTypeCount >> (8 * b));
        }
    } else {
        headerBytes = [NSMutableData dataWithBytes:base length:(NSUInteger)targetDoc.objectTableOffset];
    }
    if (countPosition + 4u <= headerBytes.length) {
        uint8_t *countBytes = (uint8_t *)headerBytes.mutableBytes + countPosition;
        uint32_t newObjectCount = (uint32_t)targetDoc.objects.count;
        for (NSUInteger b = 0; b < 4; b++) countBytes[b] = (uint8_t)(newObjectCount >> (8 * b));
    }
    if (targetDoc.rewritesPlatform && targetDoc.targetPlatformOffset + 4u <= headerBytes.length) {
        uint8_t *platformBytes = (uint8_t *)headerBytes.mutableBytes + targetDoc.targetPlatformOffset;
        for (NSUInteger b = 0; b < 4; b++) platformBytes[b] = (uint8_t)(targetDoc.outputPlatform >> (8 * b));
    }
    if (headerBytes.length >= 40 && zt_be32(base + 8) >= 22u) {
        uint8_t *hb = headerBytes.mutableBytes;
        for (NSUInteger b = 0; b < 8; b++) hb[24 + b] = (uint8_t)(expectedFileSize >> (8 * (7 - b)));
        if (addedCount > 0 || injectedBytes.length > 0) {
            uint32_t metadataSize = zt_be32(base + 20) + (uint32_t)(addedCount * 24u) + (uint32_t)(newTableOffset - targetDoc.objectTableOffset);
            for (NSUInteger b = 0; b < 4; b++) hb[20 + b] = (uint8_t)(metadataSize >> (8 * (3 - b)));
            for (NSUInteger b = 0; b < 8; b++) hb[32 + b] = (uint8_t)(newDataOffset >> (8 * (7 - b)));
        }
    } else if (headerBytes.length >= 8) {
        uint8_t *hb = headerBytes.mutableBytes;
        for (NSUInteger b = 0; b < 4; b++) hb[4 + b] = (uint8_t)(expectedFileSize >> (8 * (3 - b)));
    }
    if (!zt_write_all(out, headerBytes.bytes, headerBytes.length, error)) {
        [out closeFile];
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
        return NO;
    }
    for (NSUInteger i = 0; i < targetDoc.objects.count; i++) {
        ZTSerializedObject *object = targetDoc.objects[i];
        uint8_t entry[24] = {0};
        uint64_t pathID = (uint64_t)object.pathID;
        uint64_t byteStart = [newStarts[i] unsignedLongLongValue];
        uint32_t byteSize = [newSizes[i] unsignedIntValue];
        for (NSUInteger b = 0; b < 8; b++) entry[b] = (uint8_t)(pathID >> (8 * b));
        for (NSUInteger b = 0; b < 8; b++) entry[8 + b] = (uint8_t)(byteStart >> (8 * b));
        for (NSUInteger b = 0; b < 4; b++) entry[16 + b] = (uint8_t)(byteSize >> (8 * b));
        uint32_t typeIndex = (uint32_t)object.typeIndex;
        for (NSUInteger b = 0; b < 4; b++) entry[20 + b] = (uint8_t)(typeIndex >> (8 * b));
        if (!zt_write_all(out, entry, sizeof(entry), error)) {
            [out closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
    }
    uint64_t written = newTableOffset + targetDoc.objects.count * 24u;
    if (written > newDataOffset) {
        [out closeFile];
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"SerializedFile object table exceeds data offset after rebuild.");
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
        return NO;
    }
    if (targetDoc.dataOffset > tableEnd) {
        if (!zt_copy_range_to_handle(out, base, tableEnd, targetDoc.dataOffset - tableEnd, error)) {
            [out closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
        written += targetDoc.dataOffset - tableEnd;
    }
    while (written < newDataOffset) {
        uint8_t zero = 0;
        if (!zt_write_all(out, &zero, 1, error)) {
            [out closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
        written++;
    }
    for (NSUInteger i = 0; i < targetDoc.objects.count; i++) {
        ZTSerializedObject *object = targetDoc.objects[i];
        uint64_t desiredStart = [newStarts[i] unsignedLongLongValue] + newDataOffset;
        while (written < desiredStart) {
            uint8_t zero = 0;
            if (!zt_write_all(out, &zero, 1, error)) {
                [out closeFile];
                [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
                return NO;
            }
            written++;
        }
        BOOL objectFailed = NO;
        @autoreleasepool {
            NSString *key = [NSString stringWithFormat:@"%lld", (long long)object.pathID];
            ZTTextureReplacement *replacement = replacements[key];
            NSData *objectData = zt_rebuilt_object_data(object, replacement, targetDoc);
            if (!objectData || objectData.length != [newSizes[i] unsignedIntegerValue]) {
                [out closeFile];
                if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Rebuilt object PathID=%lld changed size between passes.", (long long)object.pathID]);
                objectFailed = YES;
            } else if (!zt_write_all(out, objectData.bytes, objectData.length, error)) {
                [out closeFile];
                objectFailed = YES;
            } else {
                written += objectData.length;
            }
        }
        if (objectFailed) {
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
    }
    if (tailLength > 0) {
        if (!zt_copy_range_to_handle(out, base, originalObjectsEnd, tailLength, error)) {
            [out closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
        written += tailLength;
    }
    @try { [out closeFile]; } @catch (__unused NSException *exception) {}
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:outputPath error:nil];
    uint64_t finalSize = [attrs[NSFileSize] unsignedLongLongValue];
    if (finalSize != written) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"SerializedFile output size did not match the bytes written.");
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
        return NO;
    }
    ZLog(@"[ZTranscoder] rebuilt SerializedFile: objects=%lu dataOffset=%llu output=%llu", (unsigned long)targetDoc.objects.count, (unsigned long long)newDataOffset, (unsigned long long)finalSize);
    return YES;
}

static BOOL zt_write_unityfs(NSString *templateBundlePath, UnityBundleArchive *originalArchive, NSString *serializedPath, NSString *outputPath, NSError **error) {
    NSData *headerData = nil;
    NSFileHandle *headerHandle = [NSFileHandle fileHandleForReadingAtPath:templateBundlePath];
    if (headerHandle) {
        @try { headerData = [headerHandle readDataOfLength:4096u]; } @catch (__unused NSException *exception) { headerData = nil; }
        [headerHandle closeFile];
    }
    if (!headerData || headerData.length < 48 || memcmp(headerData.bytes, "UnityFS", 7) != 0) {
        if (error && !*error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"Template bundle has an invalid UnityFS header.");
        return NO;
    }
    const uint8_t *bytes = headerData.bytes;
    NSUInteger pos = 8;
    uint32_t formatVersion = zt_be32(bytes + pos); pos += 4;
    NSUInteger versionStart = pos;
    while (pos < headerData.length && bytes[pos]) pos++;
    if (pos >= headerData.length) return NO;
    NSString *unityVersion = [[NSString alloc] initWithBytes:bytes + versionStart length:pos - versionStart encoding:NSUTF8StringEncoding] ?: @"";
    pos++;
    NSUInteger revisionStart = pos;
    while (pos < headerData.length && bytes[pos]) pos++;
    if (pos >= headerData.length) return NO;
    NSString *unityRevision = [[NSString alloc] initWithBytes:bytes + revisionStart length:pos - revisionStart encoding:NSUTF8StringEncoding] ?: @"";
    pos++;
    if (headerData.length - pos < 20) return NO;
    uint64_t oldArchiveSize = zt_be64(bytes + pos); (void)oldArchiveSize; pos += 8;
    uint32_t oldCompressedInfoSize = zt_be32(bytes + pos); (void)oldCompressedInfoSize; pos += 4;
    uint32_t oldUncompressedInfoSize = zt_be32(bytes + pos); (void)oldUncompressedInfoSize; pos += 4;
    uint32_t flags = zt_be32(bytes + pos); pos += 4;
    uint32_t compression = flags & kZSTranscoderUnityFSCompressionMask;
    if (compression != UnityBundleCABCompressionNone && compression != UnityBundleCABCompressionLZ4 && compression != UnityBundleCABCompressionLZ4HC) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"UnityFS template uses unsupported compression type %u.", compression]);
        return NO;
    }
    if (originalArchive.nodes.count != 2) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"The input bundle does not contain exactly the expected serialized + .resS node pair.");
        return NO;
    }
    NSString *cabPath = nil;
    for (UnityBundleNode *node in originalArchive.nodes) if (node.flags & 4u) cabPath = node.path;
    if (!cabPath) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"The UnityFS template does not expose a serialized CAB node.");
        return NO;
    }
    UnityBundleNode *originalResS = nil;
    for (UnityBundleNode *node in originalArchive.nodes) if ([node.path hasSuffix:@".resS"]) originalResS = node;
    if (!originalResS || originalResS.offset < 0 || originalResS.size < 0 || (uint64_t)originalResS.offset > originalArchive.data.length || (uint64_t)originalResS.size > originalArchive.data.length - (uint64_t)originalResS.offset) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"The UnityFS template has no readable .resS node.");
        return NO;
    }
    NSString *blockDataPath = [[outputPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:[NSString stringWithFormat:@"blocks-%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createFileAtPath:blockDataPath contents:nil attributes:nil];
    NSFileHandle *blockOutput = [NSFileHandle fileHandleForWritingAtPath:blockDataPath];
    NSMutableData *blockUsizes = [NSMutableData data];
    NSMutableData *blockCsizes = [NSMutableData data];
    NSMutableData *blockFlags = [NSMutableData data];
    uint64_t serializedLength = zt_file_size(serializedPath);
    uint64_t resSLength = (uint64_t)originalResS.size;
    __block uint64_t compressedTotal = 0;
    BOOL blockReadFailed = NO;
    NSMutableData *pending = [NSMutableData dataWithCapacity:kZSTranscoderBlockSize];
    NSMutableData *compressed = [NSMutableData dataWithLength:(NSUInteger)LZ4_compressBound((int)kZSTranscoderBlockSize)];
    void (^emitBlock)(NSData *) = ^(NSData *data) {
        @autoreleasepool {
            NSUInteger n = data.length;
            int bound = LZ4_compressBound((int)n);
            int c = 0;
            if (compression == UnityBundleCABCompressionLZ4HC) c = LZ4_compress_HC(data.bytes, compressed.mutableBytes, (int)n, bound, LZ4HC_CLEVEL_DEFAULT);
            else if (compression == UnityBundleCABCompressionLZ4) c = LZ4_compress_default(data.bytes, compressed.mutableBytes, (int)n, bound);
            if (c <= 0 || c >= (int)n) {
                zt_put_be32(blockUsizes, (uint32_t)n);
                zt_put_be32(blockCsizes, (uint32_t)n);
                zt_put_be16(blockFlags, 0);
                [blockOutput writeData:data];
                compressedTotal += n;
            } else {
                uint16_t fl = compression == UnityBundleCABCompressionLZ4HC ? 3u : 2u;
                zt_put_be32(blockUsizes, (uint32_t)n);
                zt_put_be32(blockCsizes, (uint32_t)c);
                zt_put_be16(blockFlags, fl);
                [blockOutput writeData:[NSData dataWithBytesNoCopy:compressed.mutableBytes length:(NSUInteger)c freeWhenDone:NO]];
                compressedTotal += (uint64_t)c;
            }
        }
    };
    for (UnityBundleNode *node in originalArchive.nodes) {
        if (node == originalResS) {
            const uint8_t *resSBytes = (const uint8_t *)originalArchive.data.bytes + (uint64_t)originalResS.offset;
            uint64_t consumed = 0;
            while (consumed < resSLength) {
                NSUInteger room = (NSUInteger)kZSTranscoderBlockSize - pending.length;
                NSUInteger n = (NSUInteger)MIN((uint64_t)room, resSLength - consumed);
                [pending appendBytes:resSBytes + consumed length:n];
                consumed += n;
                if (pending.length == kZSTranscoderBlockSize) {
                    emitBlock(pending);
                    [pending setLength:0];
                }
            }
            continue;
        }
        uint64_t nodeSize = serializedLength;
        NSFileHandle *input = [NSFileHandle fileHandleForReadingAtPath:serializedPath];
        if (!input) {
            [blockOutput closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:blockDataPath error:nil];
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Couldn't open rebuilt node %@.", node.path]);
            return NO;
        }
        uint64_t remaining = nodeSize;
        while (remaining && !blockReadFailed) {
            @autoreleasepool {
                NSUInteger room = (NSUInteger)kZSTranscoderBlockSize - pending.length;
                NSUInteger n = (NSUInteger)MIN((uint64_t)room, remaining);
                NSData *data = [input readDataOfLength:n];
                if (data.length != n) {
                    blockReadFailed = YES;
                } else {
                    [pending appendData:data];
                    remaining -= n;
                    if (pending.length == kZSTranscoderBlockSize) {
                        emitBlock(pending);
                        [pending setLength:0];
                    }
                }
            }
        }
        [input closeFile];
        if (blockReadFailed) break;
    }
    if (!blockReadFailed && pending.length) {
        emitBlock(pending);
        [pending setLength:0];
    }
    if (blockReadFailed) {
        [blockOutput closeFile]; [[NSFileManager defaultManager] removeItemAtPath:blockDataPath error:nil];
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"UnityFS block generation failed while reading a rebuilt node.");
        return NO;
    }
    [blockOutput closeFile];
    uint32_t blockCount = (uint32_t)(blockUsizes.length / 4u);
    NSMutableData *info = [NSMutableData dataWithLength:16];
    zt_put_be32(info, blockCount);
    for (uint32_t i = 0; i < blockCount; i++) {
        const uint8_t *us = blockUsizes.bytes + (size_t)i * 4u;
        const uint8_t *cs = blockCsizes.bytes + (size_t)i * 4u;
        const uint8_t *fl = blockFlags.bytes + (size_t)i * 2u;
        [info appendBytes:us length:4]; [info appendBytes:cs length:4]; [info appendBytes:fl length:2];
    }
    zt_put_be32(info, 2u);
    uint64_t nodeOffset = 0;
    for (NSUInteger i = 0; i < originalArchive.nodes.count; i++) {
        UnityBundleNode *node = originalArchive.nodes[i];
        uint64_t size = node == originalResS ? resSLength : serializedLength;
        zt_put_be64(info, nodeOffset);
        zt_put_be64(info, size);
        zt_put_be32(info, node.flags);
        NSData *pathData = [node.path dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        [info appendData:pathData];
        uint8_t nul = 0; [info appendBytes:&nul length:1];
        nodeOffset += size;
    }
    int infoBound = LZ4_compressBound((int)info.length);
    NSMutableData *compressedInfo = [NSMutableData dataWithLength:(NSUInteger)MAX(infoBound, (int)info.length)];
    int infoCompressedLength = 0;
    if (compression == UnityBundleCABCompressionLZ4HC) infoCompressedLength = LZ4_compress_HC(info.bytes, compressedInfo.mutableBytes, (int)info.length, infoBound, LZ4HC_CLEVEL_DEFAULT);
    else if (compression == UnityBundleCABCompressionLZ4) infoCompressedLength = LZ4_compress_default(info.bytes, compressedInfo.mutableBytes, (int)info.length, infoBound);
    else { infoCompressedLength = (int)info.length; memcpy(compressedInfo.mutableBytes, info.bytes, info.length); }
    if (infoCompressedLength <= 0) {
        [[NSFileManager defaultManager] removeItemAtPath:blockDataPath error:nil];
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"UnityFS blocks-info compression failed.");
        return NO;
    }
    compressedInfo.length = (NSUInteger)infoCompressedLength;
    NSMutableData *header = [NSMutableData data];
    [header appendBytes:"UnityFS" length:7]; uint8_t nul=0; [header appendBytes:&nul length:1];
    zt_put_be32(header, formatVersion);
    [header appendData:[unityVersion dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]]; [header appendBytes:&nul length:1];
    [header appendData:[unityRevision dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]]; [header appendBytes:&nul length:1];
    uint64_t headerBaseLength = header.length + 8 + 4 + 4 + 4;
    (void)headerBaseLength;
    uint64_t archiveSize = 0;
    uint64_t headerEnd = zt_align_up(header.length + 20u, 16u);
    if (flags & kZSTranscoderUnityFSFlagsInfoAtEnd) archiveSize = headerEnd + compressedTotal + compressedInfo.length;
    else {
        uint64_t dataStart = headerEnd + compressedInfo.length;
        if (flags & kZSTranscoderUnityFSFlagsPaddingAtStart) dataStart = zt_align_up(dataStart, 16u);
        archiveSize = dataStart + compressedTotal;
    }
    zt_put_be64(header, archiveSize);
    zt_put_be32(header, (uint32_t)compressedInfo.length);
    zt_put_be32(header, (uint32_t)info.length);
    zt_put_be32(header, flags);
    while (header.length < headerEnd) [header appendBytes:"\0" length:1];
    if (![[NSFileManager defaultManager] createFileAtPath:outputPath contents:nil attributes:nil]) {
        [[NSFileManager defaultManager] removeItemAtPath:blockDataPath error:nil];
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Couldn't create output UnityFS bundle at %@.", outputPath]);
        return NO;
    }
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:outputPath];
    [out writeData:header];
    if (flags & kZSTranscoderUnityFSFlagsInfoAtEnd) {
        if (!zt_copy_file_to_handle(out, blockDataPath, error)) {
            [out closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:blockDataPath error:nil];
            return NO;
        }
        [out writeData:compressedInfo];
    } else {
        [out writeData:compressedInfo];
        uint64_t desiredDataStart = headerEnd + compressedInfo.length;
        if (flags & kZSTranscoderUnityFSFlagsPaddingAtStart) desiredDataStart = zt_align_up(desiredDataStart, 16u);
        while ((uint64_t)out.offsetInFile < desiredDataStart) [out writeData:[NSData dataWithBytes:"\0" length:1]];
        if (!zt_copy_file_to_handle(out, blockDataPath, error)) {
            [out closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:blockDataPath error:nil];
            return NO;
        }
    }
    [out closeFile];
    [[NSFileManager defaultManager] removeItemAtPath:blockDataPath error:nil];
    return YES;
}

@implementation ZTranscoderConfig
- (ZTranscoderConfig *)normalizedConfig {
    ZTranscoderConfig *copy = [ZTranscoderConfig new];
    copy.targetBundlePath = self.targetBundlePath;
    return copy;
}
@end

@interface ZTranscoderHandle ()
@property (nonatomic, copy, readwrite) NSString *scratchBranch;
@property (nonatomic, assign, readwrite) BOOL alreadyComplete;
@end

@implementation ZTranscoderHandle
- (NSDictionary<NSString *,NSString *> *)dictionaryRepresentation {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (self.scratchBranch.length) dict[@"scratchBranch"] = self.scratchBranch;
    if (self.runID.length) dict[@"runID"] = self.runID;
    if (self.runURL.length) dict[@"runURL"] = self.runURL;
    dict[@"alreadyComplete"] = self.alreadyComplete ? @"1" : @"0";
    return dict;
}
+ (instancetype)handleFromDictionaryRepresentation:(NSDictionary<NSString *,NSString *> *)dict {
    NSString *path = [dict[@"scratchBranch"] isKindOfClass:NSString.class] ? dict[@"scratchBranch"] : nil;
    if (!path.length) return nil;
    ZTranscoderHandle *handle = [ZTranscoderHandle new];
    handle.scratchBranch = path;
    handle.runID = [dict[@"runID"] isKindOfClass:NSString.class] ? dict[@"runID"] : nil;
    handle.runURL = [dict[@"runURL"] isKindOfClass:NSString.class] ? dict[@"runURL"] : nil;
    handle.alreadyComplete = [dict[@"alreadyComplete"] integerValue] != 0 || [NSFileManager.defaultManager fileExistsAtPath:path];
    return handle;
}
@end

static BOOL zt_verify_target(NSString *moddedPath, ZTranscoderConfig *config, NSString **outTargetPath, NSString **outCAB, NSError **error) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:moddedPath]) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Provided mod bundle does not exist: %@", moddedPath]);
        return NO;
    }
    if (config.targetBundlePath.length > 0) {
        NSString *candidate = config.targetBundlePath;
        if (![candidate hasPrefix:@"/"]) candidate = [NSHomeDirectory() stringByAppendingPathComponent:candidate];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDir] && !isDir) {
            ZLog(@"[ZTranscoder] explicit target bundle path verified: %@", candidate);
            if (outTargetPath) *outTargetPath = candidate;
            if (outCAB) *outCAB = [UnityBundleCAB primaryCABForBundleAtPath:candidate error:nil];
            return YES;
        }
        ZLog(@"[ZTranscoder] explicit target bundle path does not exist: %@", candidate);
    }
    NSError *cabError = nil;
    NSString *cab = [UnityBundleCAB primaryCABForBundleAtPath:moddedPath error:&cabError];
    if (!cab) {
        if (error) *error = cabError ?: ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Couldn't determine the mod bundle CAB identifier.");
        return NO;
    }
    NSError *targetError = nil;
    NSString *target = [UnityCacheLocator locateBundlePathForCAB:cab error:&targetError];
    if (!target || ![[NSFileManager defaultManager] fileExistsAtPath:target]) {
        if (error) *error = targetError ?: ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"The game's stock bundle for %@ could not be located.", cab]);
        return NO;
    }
    ZLog(@"[ZTranscoder] target resolved by CAB fallback: %@ -> %@", cab, target);
    if (outTargetPath) *outTargetPath = target;
    if (outCAB) *outCAB = cab;
    return YES;
}

static ZTSerializedDocument *zt_build_carra2_document(NSArray<ZTCarra2Item *> *items, ZTSerializedDocument *targetDoc, NSUInteger *outSkipped, NSError **error) {
    NSMutableDictionary<NSNumber *, ZTSerializedObject *> *targetByPath = [NSMutableDictionary dictionaryWithCapacity:targetDoc.objects.count];
    for (ZTSerializedObject *object in targetDoc.objects) targetByPath[@(object.pathID)] = object;
    NSUInteger hintsChecked = 0;
    NSUInteger hintsMatched = 0;
    for (ZTCarra2Item *item in items) {
        ZTSerializedObject *existing = targetByPath[@(item.pathID)];
        if (!existing || item.typeHint < 0) continue;
        hintsChecked++;
        if (item.typeHint == existing.typeIndex) hintsMatched++;
    }
    BOOL hintsTrusted = hintsChecked > 0 && hintsChecked == hintsMatched;
    NSUInteger skipped = 0;
    ZLog(@"[ZTranscoder] Carra2 type tags %@ the game's type table (%lu of %lu existing object(s) agree)", hintsTrusted ? @"match" : @"do not match", (unsigned long)hintsMatched, (unsigned long)hintsChecked);
    NSMutableData *blob = [NSMutableData data];
    NSMutableArray<ZTSerializedObject *> *objects = [NSMutableArray array];
    for (ZTCarra2Item *item in items) {
        ZTSerializedObject *target = targetByPath[@(item.pathID)];
        int32_t objectClassID = 0;
        int32_t objectTypeIndex = 0;
        if (target) {
            objectClassID = target.classID;
            objectTypeIndex = target.typeIndex;
        } else {
            BOOL usableHint = hintsTrusted && item.typeHint >= 0 && (NSUInteger)item.typeHint < targetDoc.typeKeys.count;
            if (!usableHint) {
                skipped++;
                ZLog(@"[ZTranscoder] Carra2 object PathID=%lld (%@) is new, but its type couldn't be matched to the game's bundle; skipping", (long long)item.pathID, item.name);
                continue;
            }
            objectTypeIndex = item.typeHint;
            objectClassID = (int32_t)[[targetDoc.typeKeys[(NSUInteger)objectTypeIndex] componentsSeparatedByString:@":"].firstObject intValue];
            ZLog(@"[ZTranscoder] Carra2 object PathID=%lld (%@) is new; adding it to the game's bundle as class=%d", (long long)item.pathID, item.name, objectClassID);
        }
        while (blob.length % 8u) { uint8_t zero = 0; [blob appendBytes:&zero length:1]; }
        ZTSerializedObject *object = [ZTSerializedObject new];
        object.classID = objectClassID;
        object.typeIndex = objectTypeIndex;
        object.pathID = item.pathID;
        object.byteStart = blob.length;
        object.objectStart = blob.length;
        object.byteSize = (uint32_t)item.data.length;
        [blob appendData:item.data];
        [objects addObject:object];
        ZLog(@"[ZTranscoder] Carra2 object PathID=%lld (%@) is class=%d, %lu bytes", (long long)item.pathID, item.name, objectClassID, (unsigned long)item.data.length);
    }
    if (outSkipped) *outSkipped = skipped;
    if (objects.count == 0) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"None of the Carra2 mod's objects could be applied to the game's bundle.");
        return nil;
    }
    NSData *data = [blob copy];
    NSMutableArray<ZTTextureRecord *> *textures = [NSMutableArray array];
    for (ZTSerializedObject *object in objects) {
        if (object.classID != kZTClassTexture2D) continue;
        NSDictionary<NSString *, NSData *> *tree = targetDoc.textureTrees[@(object.typeIndex)];
        NSData *nodes = tree[@"nodes"];
        NSData *strings = tree[@"strings"];
        ZTTextureRecord *texture = nil;
        if (!nodes.length || !zt_parse_texture(data.bytes, object, nodes.bytes, (uint32_t)(nodes.length / 32u), strings.bytes, (uint32_t)strings.length, &texture)) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Carra2 Texture2D PathID=%lld doesn't match the game's Texture2D layout.", (long long)object.pathID]);
            return nil;
        }
        [textures addObject:texture];
    }
    ZTSerializedDocument *document = [ZTSerializedDocument new];
    document.data = data;
    document.dataOffset = 0;
    document.objects = objects;
    document.textures = textures;
    document.originalObjectCount = objects.count;
    document.classTypeIndex = targetDoc.classTypeIndex;
    document.typeKeys = targetDoc.typeKeys;
    document.typeIndexByKey = targetDoc.typeIndexByKey;
    document.typeRanges = targetDoc.typeRanges;
    document.trailer = targetDoc.trailer;
    document.injectedTypes = [NSMutableArray array];
    document.textureTrees = targetDoc.textureTrees;
    return document;
}

static BOOL zt_texture_has_pixel_data(ZTTextureRecord *texture) {
    return texture.isInline || texture.isStreamed;
}

static void zt_restore_shaders(ZTSerializedDocument *doc, ZTSerializedDocument *originalDoc, NSUInteger *outTotal, NSUInteger *outRestored) {
    NSMutableDictionary<NSNumber *, ZTSerializedObject *> *originalShaders = [NSMutableDictionary dictionary];
    for (ZTSerializedObject *object in originalDoc.objects) {
        if (object.classID == kZTClassShader) originalShaders[@(object.pathID)] = object;
    }
    NSUInteger total = 0;
    NSUInteger restored = 0;
    for (ZTSerializedObject *object in doc.objects) {
        if (object.classID != kZTClassShader) continue;
        total++;
        ZTSerializedObject *original = originalShaders[@(object.pathID)];
        if (!original) {
            ZLog(@"[ZTranscoder] Shader PathID=%lld not found in the original bundle; leaving this object's bytes as-is", (long long)object.pathID);
            continue;
        }
        NSData *originalBytes = zt_object_data(original, originalDoc.data);
        if (!originalBytes) {
            ZLog(@"[ZTranscoder] Shader PathID=%lld could not be read from the original bundle; leaving this object's bytes as-is", (long long)object.pathID);
            continue;
        }
        NSString *originalTypeKey = (original.typeIndex >= 0 && (NSUInteger)original.typeIndex < originalDoc.typeKeys.count) ? originalDoc.typeKeys[(NSUInteger)original.typeIndex] : nil;
        NSString *currentTypeKey = (object.typeIndex >= 0 && (NSUInteger)object.typeIndex < doc.typeKeys.count) ? doc.typeKeys[(NSUInteger)object.typeIndex] : nil;
        int32_t newTypeIndex = object.typeIndex;
        if (originalTypeKey && ![originalTypeKey isEqualToString:currentTypeKey]) {
            NSNumber *adopted = doc.typeIndexByKey[originalTypeKey] ?: zt_inject_type(doc, originalDoc, original.typeIndex);
            if (!adopted) {
                ZLog(@"[ZTranscoder] Shader PathID=%lld: the original's type couldn't be adopted; leaving this object's bytes as-is", (long long)object.pathID);
                continue;
            }
            newTypeIndex = adopted.intValue;
        }
        object.typeIndex = newTypeIndex;
        object.replacementObject = originalBytes;
        restored++;
    }
    if (outTotal) *outTotal = total;
    if (outRestored) *outRestored = restored;
}

static BOOL zt_verify_rebuilt_serialized(NSString *path, ZTSerializedDocument *expected, ZTTarget target, NSUInteger *outTextureCount, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSError *parseError = nil;
    ZTSerializedDocument *rebuilt = data ? zt_parse_serialized(data, &parseError) : nil;
    if (!rebuilt) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"The rebuilt SerializedFile could not be read back: %@", parseError.localizedDescription ?: @"unknown error"]);
        return NO;
    }
    if (rebuilt.targetPlatform != kZTTargetPlatformIOS) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"The rebuilt SerializedFile still targets platform %u; expected %u.", rebuilt.targetPlatform, kZTTargetPlatformIOS]);
        return NO;
    }
    if (rebuilt.objects.count != expected.objects.count) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"The rebuilt SerializedFile has %lu object(s); expected %lu.", (unsigned long)rebuilt.objects.count, (unsigned long)expected.objects.count]);
        return NO;
    }
    NSUInteger remaining = 0;
    for (ZTTextureRecord *texture in rebuilt.textures) {
        if (zt_texture_has_pixel_data(texture) && !zt_texture_is_untouched(texture, target)) remaining++;
    }
    if (remaining) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"The rebuilt SerializedFile still contains %lu texture(s) in a format that should have been converted.", (unsigned long)remaining]);
        return NO;
    }
    if (outTextureCount) *outTextureCount = rebuilt.textures.count;
    return YES;
}

static BOOL zt_transcode_modded_bundle_in(NSString *workDir, NSString *inputPath, ZTranscoderConfig *config, void (^progress)(double, NSString *), NSError **error) {
    ZTTarget target = zt_current_target();
    ZLog(@"[ZTranscoder] target codec=%@ rgba32Passthrough=%d parallel=%d", zt_target_name(target), target.passthroughRGBA32, target.parallel);
    if (progress) progress(0.0, @"Reading the mod bundle");
    NSError *archiveError = nil;
    UnityBundleArchive *sourceArchive = [UnityBundleCAB decompressedArchiveAtPath:inputPath error:&archiveError];
    if (!sourceArchive) {
        if (error) *error = archiveError ?: ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Couldn't read the mod bundle.");
        return NO;
    }
    if (sourceArchive.nodes.count != 2) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"The mod bundle does not contain exactly the expected serialized + .resS node pair.");
        return NO;
    }
    UnityBundleNode *sourceCABNode = nil;
    for (UnityBundleNode *node in sourceArchive.nodes) if (node.flags & 4u) sourceCABNode = node;
    if (!sourceCABNode || sourceCABNode.offset < 0 || sourceCABNode.size < 0 || (uint64_t)sourceCABNode.offset > sourceArchive.data.length || (uint64_t)sourceCABNode.size > sourceArchive.data.length - (uint64_t)sourceCABNode.offset) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"The mod bundle has no readable serialized CAB node.");
        return NO;
    }
    NSData *sourceView = [NSData dataWithBytesNoCopy:(void *)((uint8_t *)sourceArchive.data.bytes + sourceCABNode.offset) length:(NSUInteger)sourceCABNode.size freeWhenDone:NO];
    ZTSerializedDocument *doc = zt_parse_serialized(sourceView, &archiveError);
    if (!doc) {
        if (error) *error = archiveError ?: ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Couldn't parse the mod's SerializedFile.");
        return NO;
    }
    ZLog(@"[ZTranscoder] mod objects=%lu Texture2D=%lu TargetPlatform=%u", (unsigned long)doc.objects.count, (unsigned long)doc.textures.count, doc.targetPlatform);
    doc.rewritesPlatform = YES;
    doc.outputPlatform = kZTTargetPlatformIOS;

    NSUInteger shadersTotal = 0;
    NSUInteger shadersRestored = 0;
    if (progress) progress(0.05, @"Locating the original bundle");
    NSString *targetPath = nil;
    NSString *cab = nil;
    NSError *targetError = nil;
    BOOL haveTarget = zt_verify_target(inputPath, config, &targetPath, &cab, &targetError) && targetPath.length > 0;
    if (haveTarget) {
        UnityBundleArchive *targetArchive = [UnityBundleCAB decompressedArchiveAtPath:targetPath error:&targetError];
        UnityBundleNode *targetCABNode = nil;
        if (targetArchive) for (UnityBundleNode *node in targetArchive.nodes) if (node.flags & 4u) targetCABNode = node;
        ZTSerializedDocument *originalDoc = nil;
        if (targetCABNode && targetCABNode.offset >= 0 && targetCABNode.size >= 0 && (uint64_t)targetCABNode.offset <= targetArchive.data.length && (uint64_t)targetCABNode.size <= targetArchive.data.length - (uint64_t)targetCABNode.offset) {
            NSData *targetView = [NSData dataWithBytesNoCopy:(void *)((uint8_t *)targetArchive.data.bytes + targetCABNode.offset) length:(NSUInteger)targetCABNode.size freeWhenDone:NO];
            originalDoc = zt_parse_serialized(targetView, &targetError);
        }
        if (originalDoc) {
            zt_restore_shaders(doc, originalDoc, &shadersTotal, &shadersRestored);
            ZLog(@"[ZTranscoder] original %@ loaded for shader restore: %lu/%lu shader(s) restored", targetPath.lastPathComponent, (unsigned long)shadersRestored, (unsigned long)shadersTotal);
        } else {
            ZLog(@"[ZTranscoder] the original bundle could not be read (%@); shaders will not be restored", targetError.localizedDescription ?: @"unknown error");
        }
    } else {
        ZLog(@"[ZTranscoder] no original bundle could be located (%@); shaders will not be restored", targetError.localizedDescription ?: @"unknown error");
    }

    NSMutableArray<ZTTextureRecord *> *pending = [NSMutableArray array];
    for (ZTTextureRecord *texture in doc.textures) {
        if (zt_texture_is_untouched(texture, target)) continue;
        if (!zt_texture_has_pixel_data(texture)) {
            ZLog(@"[ZTranscoder] Texture2D PathID=%lld name=%@ has no pixel data; leaving it untouched", (long long)texture.object.pathID, texture.name.length ? texture.name : @"<unnamed>");
            continue;
        }
        [pending addObject:texture];
    }
    NSMutableDictionary<NSString *, ZTTextureReplacement *> *replacements = [NSMutableDictionary dictionaryWithCapacity:pending.count];
    __block NSUInteger completed = 0;
    __block BOOL failed = NO;
    __block NSError *failure = nil;
    os_unfair_lock resultLock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock *resultLockPtr = &resultLock;
    zt_parallel_run(pending.count, target.parallel, ^uint64_t(NSUInteger index) {
        ZTTextureRecord *texture = pending[index];
        return (uint64_t)texture.width * (uint64_t)texture.height * 8u + texture.imageDataLength + texture.streamSize;
    }, ^BOOL(NSUInteger index, uint32_t worker, uint32_t threads) {
        ZTTextureRecord *texture = pending[index];
        NSData *payload = nil;
        NSError *localError = nil;
        if (!zt_texture_payload(texture, sourceArchive, doc.data, &payload, &localError)) {
            os_unfair_lock_lock(resultLockPtr);
            if (!failed) { failed = YES; failure = localError; }
            os_unfair_lock_unlock(resultLockPtr);
            return NO;
        }
        NSData *objectData = zt_object_data(texture.object, doc.data);
        if (!objectData) {
            os_unfair_lock_lock(resultLockPtr);
            if (!failed) { failed = YES; failure = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't extract Texture2D PathID=%lld.", (long long)texture.object.pathID]); }
            os_unfair_lock_unlock(resultLockPtr);
            return NO;
        }
        NSString *encodedPath = nil;
        uint32_t encodedSize = 0;
        NSError *transcodeError = nil;
        BOOL transcoded = zt_make_astc_replacement(texture, texture, payload, workDir, &encodedPath, &encodedSize, &transcodeError, nil, worker, threads, target);
        if (!transcoded) {
            os_unfair_lock_lock(resultLockPtr);
            if (!failed) { failed = YES; failure = transcodeError; }
            os_unfair_lock_unlock(resultLockPtr);
            return NO;
        }
        ZTTextureReplacement *replacement = [ZTTextureReplacement new];
        replacement.source = texture;
        replacement.target = texture;
        replacement.baseTexture = texture;
        replacement.baseObjectData = objectData;
        replacement.outputFormat = target.format;
        replacement.outputMipCount = 1;
        replacement.encodedPath = encodedPath;
        replacement.encodedSize = encodedSize;
        os_unfair_lock_lock(resultLockPtr);
        replacements[[NSString stringWithFormat:@"%lld", (long long)texture.object.pathID]] = replacement;
        completed++;
        double fraction = (double)completed / (double)pending.count;
        os_unfair_lock_unlock(resultLockPtr);
        ZLog(@"[ZTranscoder] worker %u: Texture2D '%@' PathID=%lld %ux%u: %@ (%d) -> %@ (%d), %lu -> %u bytes", worker, texture.name.length ? texture.name : @"<unnamed>", (long long)texture.object.pathID, texture.width, texture.height, zt_format_name(texture.format), texture.format, zt_target_name(target), target.format, (unsigned long)payload.length, encodedSize);
        if (progress) progress(0.1 + 0.75 * fraction, [NSString stringWithFormat:@"Encoded %@ as %@", texture.name.length ? texture.name : @"<unnamed>", zt_target_name(target)]);
        return YES;
    });
    if (failed) {
        if (error) *error = failure;
        return NO;
    }

    if (progress) progress(0.85, @"Rebuilding the SerializedFile");
    NSString *serializedOutput = [workDir stringByAppendingPathComponent:@"target.cab"];
    if (!zt_rebuild_serialized_correctly(doc, replacements, serializedOutput, error)) return NO;
    NSUInteger verifiedTextures = 0;
    if (!zt_verify_rebuilt_serialized(serializedOutput, doc, target, &verifiedTextures, error)) return NO;
    ZLog(@"[ZTranscoder] verify: Texture2D=%lu, TargetPlatform=%u, all converted-source formats removed", (unsigned long)verifiedTextures, kZTTargetPlatformIOS);

    if (progress) progress(0.9, @"Writing the UnityFS bundle");
    NSString *bundleOutput = [workDir stringByAppendingPathComponent:@"output.bundle"];
    if (!zt_write_unityfs(inputPath, sourceArchive, serializedOutput, bundleOutput, error)) return NO;
    if (zt_file_size(bundleOutput) == 0) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"UnityFS output bundle is empty.");
        return NO;
    }
    ZLog(@"[ZTranscoder] converted %lu/%lu textures; retargeted %u -> %u; restored %lu/%lu shader(s); wrote %llu bytes", (unsigned long)replacements.count, (unsigned long)doc.textures.count, doc.targetPlatform, kZTTargetPlatformIOS, (unsigned long)shadersRestored, (unsigned long)shadersTotal, (unsigned long long)zt_file_size(bundleOutput));

    NSString *replacementInput = [inputPath stringByAppendingString:@".zst-out"];
    [[NSFileManager defaultManager] removeItemAtPath:replacementInput error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:bundleOutput toPath:replacementInput error:error]) return NO;
    NSURL *inputURL = [NSURL fileURLWithPath:inputPath];
    NSURL *replacementURL = [NSURL fileURLWithPath:replacementInput];
    if (![[NSFileManager defaultManager] replaceItemAtURL:inputURL withItemAtURL:replacementURL backupItemName:nil options:NSFileManagerItemReplacementUsingNewMetadataOnly resultingItemURL:nil error:error]) {
        [[NSFileManager defaultManager] removeItemAtPath:replacementInput error:nil];
        return NO;
    }
    ZLog(@"[ZTranscoder] replaced input bundle with locally transcoded output %@", inputPath);
    if (progress) progress(1.0, @"Local bundle transcode complete");
    return YES;
}

static BOOL zt_process_modded_bundle(NSURL *moddedURL, ZTranscoderConfig *config, void (^progress)(double, NSString *), NSURL **outputURL, NSError **error) {
    NSString *inputPath = moddedURL.path;
    ZLog(@"[ZTranscoder] starting local transcode of %@", inputPath);
    if (![[NSFileManager defaultManager] fileExistsAtPath:inputPath]) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Provided mod bundle does not exist: %@", inputPath]);
        return NO;
    }
    NSString *workDir = zt_temp_directory();
    if (!workDir) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"Couldn't create the on-device transcoder workspace.");
        return NO;
    }
    BOOL ok = zt_transcode_modded_bundle_in(workDir, inputPath, config, progress, error);
    [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
    if (ok && outputURL) *outputURL = [NSURL fileURLWithPath:inputPath];
    return ok;
}

static BOOL zt_process_bundle_full(NSURL *moddedURL, ZTranscoderConfig *config, NSArray<ZTCarra2Item *> *carra2Items, void (^progress)(double, NSString *), NSURL **outputURL, NSUInteger *outSkippedObjects, NSError **error) {
    BOOL carra2Mode = carra2Items != nil;
    if (!config) config = [ZTranscoderConfig new];
    if (!carra2Mode) return zt_process_modded_bundle(moddedURL, config, progress, outputURL, error);
    ZTTarget target = zt_current_target();
    ZLog(@"[ZTranscoder] target codec=%@ rgba32Passthrough=%d parallel=%d", zt_target_name(target), target.passthroughRGBA32, target.parallel);
    NSString *inputPath = moddedURL.path;
    NSUInteger buildSkipped = 0;
    ZLog(@"[ZTranscoder] starting local visual-mod transcode for %@", inputPath);
    NSString *targetPath = nil;
    NSString *cab = nil;
    if (!zt_verify_target(inputPath, config, &targetPath, &cab, error)) return NO;
    ZLog(@"[ZTranscoder] verified target CAB=%@ path=%@", cab, targetPath);
    NSString *workDir = zt_temp_directory();
    if (!workDir) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"Couldn't create the on-device transcoder workspace.");
        return NO;
    }
    NSString *originalCopy = [workDir stringByAppendingPathComponent:@"original.bundle"];
    if (![[NSFileManager defaultManager] copyItemAtPath:targetPath toPath:originalCopy error:error]) {
        if (error && !*error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Couldn't copy the original game bundle into the transcoder workspace.");
        [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
        return NO;
    }
    ZLog(@"[ZTranscoder] copied original game bundle to %@", originalCopy);
    NSError *archiveError = nil;
    UnityBundleArchive *sourceArchive = nil;
    if (!carra2Mode) {
        sourceArchive = [UnityBundleCAB decompressedArchiveAtPath:inputPath error:&archiveError];
        if (!sourceArchive) { if (error) *error = archiveError; [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil]; return NO; }
    }
    UnityBundleArchive *targetArchive = [UnityBundleCAB decompressedArchiveAtPath:originalCopy error:&archiveError];
    if (!targetArchive) { if (error) *error = archiveError; [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil]; return NO; }
    UnityBundleNode *sourceCABNode = nil;
    UnityBundleNode *targetCABNode = nil;
    UnityBundleNode *sourceResS = carra2Mode ? nil : zt_resS_node(sourceArchive, error);
    UnityBundleNode *targetResS = zt_resS_node(targetArchive, error);
    if (!carra2Mode) for (UnityBundleNode *node in sourceArchive.nodes) if (node.flags & 4u) sourceCABNode = node;
    for (UnityBundleNode *node in targetArchive.nodes) if (node.flags & 4u) targetCABNode = node;
    if ((!carra2Mode && (!sourceCABNode || !sourceResS)) || !targetCABNode || !targetResS) {
        [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
        return NO;
    }
    NSData *targetSerializedView = [NSData dataWithBytesNoCopy:(void *)((uint8_t *)targetArchive.data.bytes + targetCABNode.offset) length:(NSUInteger)targetCABNode.size freeWhenDone:NO];
    ZTSerializedDocument *targetDoc = zt_parse_serialized(targetSerializedView, &archiveError);
    ZTSerializedDocument *sourceDoc = nil;
    if (targetDoc) {
        if (carra2Mode) {
            sourceDoc = zt_build_carra2_document(carra2Items, targetDoc, &buildSkipped, &archiveError);
        } else {
            NSData *sourceSerializedView = [NSData dataWithBytesNoCopy:(void *)((uint8_t *)sourceArchive.data.bytes + sourceCABNode.offset) length:(NSUInteger)sourceCABNode.size freeWhenDone:NO];
            sourceDoc = zt_parse_serialized(sourceSerializedView, &archiveError);
        }
    }
    if (!sourceDoc || !targetDoc) {
        if (error) *error = archiveError ?: ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Couldn't parse source or original SerializedFile.");
        [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
        return NO;
    }
    ZLog(@"[ZTranscoder] source objects=%lu Texture2D=%lu, target objects=%lu Texture2D=%lu", (unsigned long)sourceDoc.objects.count, (unsigned long)sourceDoc.textures.count, (unsigned long)targetDoc.objects.count, (unsigned long)targetDoc.textures.count);
    NSDictionary *targetObjectMap = ^NSDictionary *(void) {
        NSMutableDictionary *map = [NSMutableDictionary dictionaryWithCapacity:targetDoc.objects.count];
        for (ZTSerializedObject *object in targetDoc.objects) map[[NSString stringWithFormat:@"%d:%lld", object.classID, (long long)object.pathID]] = object;
        return map;
    }();
    NSMutableDictionary *targetTextureMap = [zt_texture_map(targetDoc.textures) mutableCopy];
    NSMutableArray<ZTSerializedObject *> *addedObjects = [NSMutableArray array];
    NSMutableArray<ZTTextureRecord *> *addedTextures = [NSMutableArray array];
    NSMutableDictionary<NSString *, ZTTextureReplacement *> *replacements = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *encodeTasks = [NSMutableArray array];
    NSUInteger assetCount = 0;
    BOOL layoutShared = carra2Mode || (sourceDoc.trailer.length > 0 && [sourceDoc.trailer isEqualToData:targetDoc.trailer]);
    ZLog(@"[ZTranscoder] SerializedFile externals/script tables %@ between the mod and the original; %@", layoutShared ? @"match" : @"differ", layoutShared ? @"transplanting every changed object" : @"transplanting only texture/sprite/text classes");
    for (ZTSerializedObject *sourceObject in sourceDoc.objects) {
        BOOL present = zt_find_object(targetObjectMap, sourceObject.pathID, sourceObject.classID) != nil;
        if (zt_class_is_transplantable(sourceObject.classID, layoutShared) || (!present && (carra2Mode || zt_class_is_transplantable(sourceObject.classID, YES)))) assetCount++;
    }
    NSUInteger processedAssets = 0;
    NSUInteger skippedAssets = 0;
    NSUInteger matchedAssets = 0;
    ZLog(@"[ZTranscoder] extracted %lu source Texture2D/Sprite/SpriteRenderer/SpriteMask/SpriteAtlas/TextAsset/AssetBundle object(s)", (unsigned long)assetCount);
    NSDictionary *sourceTexturesByPath = zt_texture_map(sourceDoc.textures);
    for (ZTSerializedObject *sourceObject in sourceDoc.objects) {
        BOOL presentInTarget = zt_find_object(targetObjectMap, sourceObject.pathID, sourceObject.classID) != nil;
        if (!zt_class_is_transplantable(sourceObject.classID, layoutShared) && !(!presentInTarget && (carra2Mode || zt_class_is_transplantable(sourceObject.classID, YES)))) continue;
        BOOL legacyClass = zt_class_is_transcoded(sourceObject.classID);
        BOOL wholesaleClass = sourceObject.classID == kZTClassTexture2D || sourceObject.classID == kZTClassSprite || sourceObject.classID == kZTClassSpriteAtlas;
        NSString *sourceTypeKey = (sourceObject.typeIndex >= 0 && (NSUInteger)sourceObject.typeIndex < sourceDoc.typeKeys.count) ? sourceDoc.typeKeys[(NSUInteger)sourceObject.typeIndex] : nil;
        processedAssets++;
        NSString *key = [NSString stringWithFormat:@"%d:%lld", sourceObject.classID, (long long)sourceObject.pathID];
        if (sourceObject.classID == kZTClassTexture2D) {
            ZTTextureRecord *probeTexture = sourceTexturesByPath[[NSString stringWithFormat:@"%lld", (long long)sourceObject.pathID]];
            if (probeTexture && !probeTexture.isInline && !sourceArchive) {
                skippedAssets++;
                ZLog(@"[ZTranscoder] Texture2D PathID=%lld name=%@ has no readable pixel data in this mod (no resource stream was supplied); leaving the original untouched", (long long)sourceObject.pathID, probeTexture.name.length ? probeTexture.name : @"<unnamed>");
                if (progress && assetCount) progress(0.1 + 0.1 * ((double)processedAssets / (double)assetCount), [NSString stringWithFormat:@"Compared asset %lu/%lu", (unsigned long)processedAssets, (unsigned long)assetCount]);
                continue;
            }
        }
        ZTSerializedObject *targetObject = zt_find_object(targetObjectMap, sourceObject.pathID, sourceObject.classID);
        BOOL isNewAsset = NO;
        if (!targetObject) {
            NSNumber *newTypeIndex = (legacyClass && !wholesaleClass) ? targetDoc.classTypeIndex[@(sourceObject.classID)] : (sourceTypeKey ? targetDoc.typeIndexByKey[sourceTypeKey] : nil);
            if (!newTypeIndex) newTypeIndex = zt_inject_type(targetDoc, sourceDoc, sourceObject.typeIndex);
            if (!newTypeIndex) {
                skippedAssets++;
                ZLog(@"[ZTranscoder] skipping class=%d PathID=%lld (%@): its type couldn't be copied into the original bundle", sourceObject.classID, (long long)sourceObject.pathID, key);
                if (progress && assetCount) progress(0.1 + 0.1 * ((double)processedAssets / (double)assetCount), [NSString stringWithFormat:@"Compared asset %lu/%lu", (unsigned long)processedAssets, (unsigned long)assetCount]);
                continue;
            }
            ZTSerializedObject *addedObject = [ZTSerializedObject new];
            addedObject.classID = sourceObject.classID;
            addedObject.typeIndex = newTypeIndex.intValue;
            addedObject.pathID = sourceObject.pathID;
            [addedObjects addObject:addedObject];
            targetObject = addedObject;
            isNewAsset = YES;
            ZLog(@"[ZTranscoder] adding class=%d PathID=%lld (%@) to the bundle: not present in the original", sourceObject.classID, (long long)sourceObject.pathID, key);
        }
        if (wholesaleClass && !isNewAsset && sourceTypeKey) {
            NSString *currentTypeKey = (targetObject.typeIndex >= 0 && (NSUInteger)targetObject.typeIndex < targetDoc.typeKeys.count) ? targetDoc.typeKeys[(NSUInteger)targetObject.typeIndex] : nil;
            if (![sourceTypeKey isEqualToString:currentTypeKey]) {
                NSNumber *adoptedTypeIndex = targetDoc.typeIndexByKey[sourceTypeKey] ?: zt_inject_type(targetDoc, sourceDoc, sourceObject.typeIndex);
                if (adoptedTypeIndex) targetObject.typeIndex = adoptedTypeIndex.intValue;
            }
        }
        if (!legacyClass && !isNewAsset) {
            NSString *targetTypeKey = (targetObject.typeIndex >= 0 && (NSUInteger)targetObject.typeIndex < targetDoc.typeKeys.count) ? targetDoc.typeKeys[(NSUInteger)targetObject.typeIndex] : nil;
            if (!sourceTypeKey || ![sourceTypeKey isEqualToString:targetTypeKey]) {
                skippedAssets++;
                ZLog(@"[ZTranscoder] skipping class=%d PathID=%lld: its serialized layout differs between the mod and the original", sourceObject.classID, (long long)sourceObject.pathID);
                continue;
            }
        }
        matchedAssets++;
        if (sourceObject.classID == kZTClassTexture2D) {
            ZTTextureRecord *sourceTexture = sourceTexturesByPath[[NSString stringWithFormat:@"%lld", (long long)sourceObject.pathID]];
            ZTTextureRecord *targetTexture = targetTextureMap[[NSString stringWithFormat:@"%lld", (long long)targetObject.pathID]];
            if (isNewAsset && sourceTexture) {
                ZTTextureRecord *syntheticTexture = [ZTTextureRecord new];
                syntheticTexture.object = targetObject;
                syntheticTexture.name = sourceTexture.name;
                syntheticTexture.format = sourceTexture.format;
                syntheticTexture.mipCount = sourceTexture.mipCount;
                syntheticTexture.width = sourceTexture.width;
                syntheticTexture.height = sourceTexture.height;
                syntheticTexture.imageDataLength = sourceTexture.isInline ? sourceTexture.imageDataLength : 0;
                syntheticTexture.streamSize = sourceTexture.isStreamed ? MAX(sourceTexture.streamSize, 1u) : 0;
                [addedTextures addObject:syntheticTexture];
                targetTextureMap[[NSString stringWithFormat:@"%lld", (long long)targetObject.pathID]] = syntheticTexture;
                targetTexture = syntheticTexture;
            }
            if (!sourceTexture || !targetTexture) {
                if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Texture2D PathID=%lld could not be parsed from both bundles.", (long long)sourceObject.pathID]);
                [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
                return NO;
            }
            NSData *sourcePayload = nil;
            if (!zt_texture_payload(sourceTexture, sourceArchive, sourceDoc.data, &sourcePayload, error)) {
                [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
                return NO;
            }
            NSData *sourceObjectData = zt_object_data(sourceObject, sourceDoc.data);
            NSData *targetObjectData = zt_object_data(targetObject, targetDoc.data);
            if (!isNewAsset && !targetObjectData) {
                if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't extract the original Texture2D PathID=%lld.", (long long)sourceObject.pathID]);
                [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
                return NO;
            }
            NSString *replacementKey = [NSString stringWithFormat:@"%lld", (long long)targetObject.pathID];
            if (zt_texture_is_untouched(sourceTexture, target) && sourceTexture.isInline && sourceObjectData) {
                targetObject.replacementObject = sourceObjectData;
                ZLog(@"[ZTranscoder] Texture2D PathID=%lld is %@; copied from the mod without re-encoding", (long long)sourceObject.pathID, zt_format_name(sourceTexture.format));
                if (progress && assetCount) progress(0.1 + 0.1 * ((double)processedAssets / (double)assetCount), [NSString stringWithFormat:@"Compared asset %lu/%lu", (unsigned long)processedAssets, (unsigned long)assetCount]);
                continue;
            }
            ZTTextureRecord *layoutTexture = sourceTexture;
            NSData *layoutObjectData = sourceObjectData;
            ZTTextureReplacement *replacement = [ZTTextureReplacement new];
            replacement.source = sourceTexture;
            replacement.target = targetTexture;
            replacement.baseTexture = layoutTexture;
            replacement.baseObjectData = layoutObjectData;
            replacement.outputFormat = zt_texture_is_untouched(sourceTexture, target) ? sourceTexture.format : target.format;
            replacement.outputMipCount = 1;
            [encodeTasks addObject:@{ @"replacement": replacement, @"source": sourceTexture, @"layout": layoutTexture, @"payload": sourcePayload, @"key": replacementKey }];
        } else {
            NSData *sourceObjectData = zt_object_data(sourceObject, sourceDoc.data);
            NSData *targetObjectData = zt_object_data(targetObject, targetDoc.data);
            if (!sourceObjectData || !targetObjectData) {
                if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't extract class=%d PathID=%lld.", sourceObject.classID, (long long)sourceObject.pathID]);
                [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
                return NO;
            }
            BOOL bytesMatch = [sourceObjectData isEqualToData:targetObjectData];
            ZLog(@"[ZTranscoder] class=%d PathID=%lld objectBytes source=%lu target=%lu bytesMatch=%@", sourceObject.classID, (long long)sourceObject.pathID, (unsigned long)sourceObjectData.length, (unsigned long)targetObjectData.length, bytesMatch ? @"YES" : @"NO");
            if (isNewAsset || !bytesMatch) targetObject.replacementObject = sourceObjectData;
        }
        if (progress && assetCount) progress(0.1 + 0.1 * ((double)processedAssets / (double)assetCount), [NSString stringWithFormat:@"Compared asset %lu/%lu", (unsigned long)processedAssets, (unsigned long)assetCount]);
    }
    if (encodeTasks.count > 0) {
        NSUInteger encodeTotal = encodeTasks.count;
        __block BOOL encodeFailed = NO;
        __block NSError *encodeFailure = nil;
        __block NSUInteger encodeDone = 0;
        os_unfair_lock encodeLock = OS_UNFAIR_LOCK_INIT;
        os_unfair_lock *encodeLockPtr = &encodeLock;
        zt_parallel_run(encodeTotal, target.parallel, ^uint64_t(NSUInteger index) {
            ZTTextureRecord *layout = encodeTasks[index][@"layout"];
            NSData *payload = encodeTasks[index][@"payload"];
            return (uint64_t)layout.width * (uint64_t)layout.height * 8u + payload.length;
        }, ^BOOL(NSUInteger index, uint32_t worker, uint32_t threads) {
            NSDictionary *task = encodeTasks[index];
            ZTTextureRecord *taskSource = task[@"source"];
            ZTTextureRecord *taskLayout = task[@"layout"];
            NSData *taskPayload = task[@"payload"];
            ZTTextureReplacement *taskReplacement = task[@"replacement"];
            NSString *encodedPath = nil;
            uint32_t encodedSize = 0;
            NSError *transcodeError = nil;
            BOOL transcoded = zt_make_astc_replacement(taskSource, taskLayout, taskPayload, workDir, &encodedPath, &encodedSize, &transcodeError, nil, worker, threads, target);
            if (!transcoded) {
                os_unfair_lock_lock(encodeLockPtr);
                if (!encodeFailed) { encodeFailed = YES; encodeFailure = transcodeError; }
                os_unfair_lock_unlock(encodeLockPtr);
                return NO;
            }
            taskReplacement.encodedPath = encodedPath;
            taskReplacement.encodedSize = encodedSize;
            os_unfair_lock_lock(encodeLockPtr);
            encodeDone++;
            double fraction = (double)encodeDone / (double)encodeTotal;
            os_unfair_lock_unlock(encodeLockPtr);
            ZLog(@"[ZTranscoder] worker %u: Texture2D PathID=%lld pixel data written as %@ at %ux%u: %lu -> %u bytes", worker, (long long)taskSource.object.pathID, zt_target_name(target), taskLayout.width, taskLayout.height, (unsigned long)taskPayload.length, encodedSize);
            if (progress) progress(0.2 + 0.6 * fraction, [NSString stringWithFormat:@"Encoded %@ as %@", taskLayout.name.length ? taskLayout.name : (taskSource.name.length ? taskSource.name : @"<unnamed>"), zt_target_name(target)]);
            return YES;
        });
        if (encodeFailed) {
            if (error) *error = encodeFailure;
            [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
            return NO;
        }
        for (NSDictionary *task in encodeTasks) replacements[task[@"key"]] = task[@"replacement"];
    }
    ZLog(@"[ZTranscoder] asset matching finished: matched=%lu skipped=%lu replacementTextures=%lu", (unsigned long)matchedAssets, (unsigned long)skippedAssets, (unsigned long)replacements.count);
    if (addedObjects.count) {
        targetDoc.objects = [[targetDoc.objects arrayByAddingObjectsFromArray:addedObjects] sortedArrayUsingComparator:^NSComparisonResult(ZTSerializedObject *a, ZTSerializedObject *b) {
            return a.pathID < b.pathID ? NSOrderedAscending : (a.pathID > b.pathID ? NSOrderedDescending : NSOrderedSame);
        }];
        targetDoc.textures = [targetDoc.textures arrayByAddingObjectsFromArray:addedTextures];
        ZLog(@"[ZTranscoder] added %lu object(s) missing from the original bundle (%lu Texture2D)", (unsigned long)addedObjects.count, (unsigned long)addedTextures.count);
    }
    if (matchedAssets == 0) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"None of the mod's Texture2D/Sprite/SpriteRenderer/SpriteMask/SpriteAtlas/TextAsset/AssetBundle assets exist in the original bundle.");
        [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
        return NO;
    }
    NSString *serializedOutput = [workDir stringByAppendingPathComponent:@"target.cab"];
    if (!zt_rebuild_serialized_correctly(targetDoc, replacements, serializedOutput, error)) { [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil]; return NO; }
    ZLog(@"[ZTranscoder] rebuilt SerializedFile node: original=%lld new=%llu", (long long)targetCABNode.size, (unsigned long long)zt_file_size(serializedOutput));
    NSString *bundleOutput = [workDir stringByAppendingPathComponent:@"modded.bundle"];
    if (!zt_write_unityfs(originalCopy, targetArchive, serializedOutput, bundleOutput, error)) { [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil]; return NO; }
    if (zt_file_size(bundleOutput) == 0) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"UnityFS output bundle is empty.");
        [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
        return NO;
    }
    ZLog(@"[ZTranscoder] final UnityFS output=%llu bytes targetOriginal=%llu bytes resS=%lld bytes (unchanged)", (unsigned long long)zt_file_size(bundleOutput), (unsigned long long)zt_file_size(originalCopy), (long long)targetResS.size);
    if (carra2Mode) {
        NSString *outDir = zt_temp_directory();
        NSString *finalPath = outDir ? [outDir stringByAppendingPathComponent:@"modded.bundle"] : nil;
        if (!finalPath || ![[NSFileManager defaultManager] copyItemAtPath:bundleOutput toPath:finalPath error:error]) {
            if (error && !*error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"Couldn't write the transcoded Carra2 bundle.");
            [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
            return NO;
        }
        ZLog(@"[ZTranscoder] built transcoded bundle for the Carra2 mod at %@", finalPath);
        if (progress) progress(1.0, @"Local bundle transcode complete");
        if (outputURL) *outputURL = [NSURL fileURLWithPath:finalPath];
        if (outSkippedObjects) *outSkippedObjects = buildSkipped + skippedAssets;
        [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
        (void)config;
        return YES;
    }
    NSString *replacementInput = [inputPath stringByAppendingString:@".zst-out"];
    [[NSFileManager defaultManager] removeItemAtPath:replacementInput error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:bundleOutput toPath:replacementInput error:error]) { [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil]; return NO; }
    NSURL *inputURL = [NSURL fileURLWithPath:inputPath];
    NSURL *replacementURL = [NSURL fileURLWithPath:replacementInput];
    if (![[NSFileManager defaultManager] replaceItemAtURL:inputURL withItemAtURL:replacementURL backupItemName:nil options:NSFileManagerItemReplacementUsingNewMetadataOnly resultingItemURL:nil error:error]) {
        [[NSFileManager defaultManager] removeItemAtPath:replacementInput error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
        return NO;
    }
    ZLog(@"[ZTranscoder] replaced input bundle with locally transcoded output %@", inputPath);
    if (progress) progress(1.0, @"Local bundle transcode complete");
    if (outputURL) *outputURL = [NSURL fileURLWithPath:inputPath];
    [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
    (void)config;
    return YES;
}

static BOOL zt_process_bundle(NSURL *moddedURL, ZTranscoderConfig *config, void (^progress)(double, NSString *), NSURL **outputURL, NSError **error) {
    return zt_process_bundle_full(moddedURL, config, nil, progress, outputURL, NULL, error);
}

static NSData *zt_read_prefix(NSString *path, NSUInteger length) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    NSData *data = nil;
    @try { data = [handle readDataOfLength:length]; } @catch (__unused NSException *exception) { data = nil; }
    [handle closeFile];
    return data;
}

static BOOL zt_file_is_unityfs(NSString *path) {
    NSData *prefix = zt_read_prefix(path, 8);
    if (prefix.length < 8) return NO;
    return memcmp(prefix.bytes, "UnityFS\0", 8) == 0;
}

static BOOL zt_file_is_zip(NSString *path) {
    NSData *prefix = zt_read_prefix(path, 4);
    if (prefix.length < 4) return NO;
    const uint8_t *b = prefix.bytes;
    return b[0] == 'P' && b[1] == 'K' && (b[2] == 3 || b[2] == 5) && (b[3] == 4 || b[3] == 6);
}

static NSString *zt_hex_prefix(NSString *path, NSUInteger length) {
    NSData *prefix = zt_read_prefix(path, length);
    if (!prefix.length) return @"<empty>";
    NSMutableString *hex = [NSMutableString stringWithCapacity:prefix.length * 2];
    const uint8_t *b = prefix.bytes;
    for (NSUInteger i = 0; i < prefix.length; i++) [hex appendFormat:@"%02x", b[i]];
    return hex;
}

static BOOL zt_is_hex32(NSString *value) {
    if (value.length != 32) return NO;
    for (NSUInteger i = 0; i < 32; i++) {
        unichar c = [value characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return NO;
    }
    return YES;
}

static BOOL zt_parse_path_id(NSString *fileName, int64_t *outPathID) {
    NSString *base = fileName;
    NSString *extension = fileName.pathExtension;
    if (extension.length > 0) {
        BOOL numericExtension = YES;
        for (NSUInteger i = 0; i < extension.length; i++) {
            unichar c = [extension characterAtIndex:i];
            if (c < '0' || c > '9') { numericExtension = NO; break; }
        }
        if (numericExtension) base = fileName.stringByDeletingPathExtension;
    }
    if (base.length == 0) return NO;
    NSUInteger start = [base hasPrefix:@"-"] ? 1u : 0u;
    if (base.length <= start) return NO;
    for (NSUInteger i = start; i < base.length; i++) {
        unichar c = [base characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    errno = 0;
    long long value = strtoll(base.UTF8String, NULL, 10);
    if (errno == ERANGE) return NO;
    if (outPathID) *outPathID = (int64_t)value;
    return YES;
}

static NSData *zt_decode_carra2_blob(NSData *raw, NSString *name, NSError **error) {
    if (raw.length >= 6 && memcmp(raw.bytes, "\xfd" "7zXZ\0", 6) == 0) {
        NSError *decodeError = nil;
        NSData *decoded = [raw decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmLZMA error:&decodeError];
        if (!decoded.length) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't decompress Carra2 entry %@: %@", name, decodeError.localizedDescription ?: @"unknown error"]);
            return nil;
        }
        return decoded;
    }
    return raw;
}

static BOOL zt_load_carra2(NSURL *archiveURL, NSString **outBundlePath, NSArray<ZTCarra2Item *> **outItems, NSString **outHash1, NSString **outHash2, NSError **error) {
    NSString *stageDir = zt_temp_directory();
    if (!stageDir) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"Couldn't create a workspace to unpack the Carra2 mod.");
        return NO;
    }
    NSString *extractDir = [stageDir stringByAppendingPathComponent:@"carra2"];
    ZLog(@"[ZTranscoder] unpacking Carra2 archive %@ into %@", archiveURL.lastPathComponent, extractDir);
    NSError *extractError = nil;
    if (![LunartiqueModArchive extractAllEntriesOfZipAtURL:archiveURL toDirectoryURL:[NSURL fileURLWithPath:extractDir isDirectory:YES] error:&extractError]) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't unpack the Carra2 mod: %@", extractError.localizedDescription ?: @"unknown error"]);
        [NSFileManager.defaultManager removeItemAtPath:stageDir error:nil];
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSMutableArray<NSString *> *bundleCandidates = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:extractDir];
    for (NSString *relative in enumerator) {
        NSString *full = [extractDir stringByAppendingPathComponent:relative];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;
        BOOL unityfs = zt_file_is_unityfs(full);
        ZLog(@"[ZTranscoder] Carra2 entry %@ size=%llu unityfs=%@ magic=%@", relative, zt_file_size(full), unityfs ? @"YES" : @"NO", zt_hex_prefix(full, 8));
        [files addObject:relative];
        if (unityfs) [bundleCandidates addObject:relative];
    }

    NSString *hash1 = nil, *hash2 = nil;
    for (NSString *relative in files) {
        NSArray<NSString *> *components = [relative componentsSeparatedByString:@"/"];
        if (components.count >= 3 && zt_is_hex32(components[0]) && zt_is_hex32(components[1])) {
            hash1 = components[0].lowercaseString;
            hash2 = components[1].lowercaseString;
            break;
        }
    }
    if (outHash1) *outHash1 = hash1;
    if (outHash2) *outHash2 = hash2;

    if (bundleCandidates.count > 0) {
        NSString *best = bundleCandidates.firstObject;
        unsigned long long bestSize = 0;
        for (NSString *relative in bundleCandidates) {
            unsigned long long size = zt_file_size([extractDir stringByAppendingPathComponent:relative]);
            BOOL isData = [relative.lastPathComponent isEqualToString:@"__data"];
            BOOL bestIsData = [best.lastPathComponent isEqualToString:@"__data"];
            if ((isData && !bestIsData) || (isData == bestIsData && size > bestSize)) { best = relative; bestSize = size; }
        }
        NSString *stagedBundle = [stageDir stringByAppendingPathComponent:@"payload.bundle"];
        NSError *moveError = nil;
        if (![fm moveItemAtPath:[extractDir stringByAppendingPathComponent:best] toPath:stagedBundle error:&moveError]) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Couldn't stage the Carra2 bundle: %@", moveError.localizedDescription ?: @"unknown error"]);
            [fm removeItemAtPath:stageDir error:nil];
            return NO;
        }
        [fm removeItemAtPath:extractDir error:nil];
        ZLog(@"[ZTranscoder] Carra2 archive carries a whole Unity bundle (%@); staged as %@", best, stagedBundle);
        if (outBundlePath) *outBundlePath = stagedBundle;
        if (outItems) *outItems = nil;
        return YES;
    }

    NSMutableDictionary<NSNumber *, ZTCarra2Item *> *itemsByPath = [NSMutableDictionary dictionary];
    for (NSString *relative in files) {
        int64_t pathID = 0;
        if (!zt_parse_path_id(relative.lastPathComponent, &pathID)) {
            ZLog(@"[ZTranscoder] Carra2 entry %@ is not named after a PathID; ignoring", relative);
            continue;
        }
        NSData *raw = [NSData dataWithContentsOfFile:[extractDir stringByAppendingPathComponent:relative] options:NSDataReadingMappedIfSafe error:nil];
        if (!raw.length) continue;
        NSError *decodeError = nil;
        NSData *decoded = zt_decode_carra2_blob(raw, relative, &decodeError);
        if (!decoded) {
            if (error) *error = decodeError;
            [fm removeItemAtPath:stageDir error:nil];
            return NO;
        }
        ZTCarra2Item *item = [ZTCarra2Item new];
        item.pathID = pathID;
        NSString *typeExtension = relative.lastPathComponent.pathExtension;
        BOOL numericExtension = typeExtension.length > 0 && [typeExtension rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
        item.typeHint = numericExtension ? (int32_t)typeExtension.integerValue : -1;
        item.name = relative.lastPathComponent;
        item.data = decoded;
        if (itemsByPath[@(pathID)]) ZLog(@"[ZTranscoder] Carra2 entry %@ repeats PathID=%lld; the later file wins", relative, (long long)pathID);
        itemsByPath[@(pathID)] = item;
        ZLog(@"[ZTranscoder] Carra2 entry %@ -> PathID=%lld, %lu -> %lu bytes", relative, (long long)pathID, (unsigned long)raw.length, (unsigned long)decoded.length);
    }
    [fm removeItemAtPath:extractDir error:nil];
    if (itemsByPath.count == 0) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"The Carra2 mod has no entries named after an asset PathID (%lu file(s): %@).", (unsigned long)files.count, [[files subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)6, files.count))] componentsJoinedByString:@", "]]);
        [fm removeItemAtPath:stageDir error:nil];
        return NO;
    }
    if (outBundlePath) *outBundlePath = nil;
    if (outItems) *outItems = itemsByPath.allValues;
    [fm removeItemAtPath:stageDir error:nil];
    return YES;
}

@implementation ZTranscoderService
+ (void)ztranscoderBundleAtURL:(NSURL *)moddedBundleURL config:(ZTranscoderConfig *)config progress:(void (^)(double, NSString *))progress completion:(void (^)(NSURL *, NSError *))completion {
    [zt_job_queue() addOperationWithBlock:^{
        @autoreleasepool {
            NSURL *output = nil;
            NSError *error = nil;
            void (^mainProgress)(double, NSString *) = progress ? ^(double fraction, NSString *stage) {
                dispatch_async(dispatch_get_main_queue(), ^{ progress(fraction, stage); });
            } : nil;
            if (mainProgress) mainProgress(0.0, @"Verifying the mod bundle and locating the stock target");
            BOOL ok = zt_process_bundle(moddedBundleURL, config, mainProgress, &output, &error);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok ? output : nil, error); });
        }
    }];
}

+ (void)dispatchBundleAtURL:(NSURL *)moddedBundleURL carra2Hash1:(NSString *)carra2Hash1 carra2Hash2:(NSString *)carra2Hash2 config:(ZTranscoderConfig *)config previousScratchBranch:(NSString *)previousScratchBranch uploadProgress:(void (^)(int64_t, int64_t))uploadProgress completion:(void (^)(ZTranscoderHandle *, NSError *))completion {
    (void)previousScratchBranch;
    [zt_job_queue() addOperationWithBlock:^{
        @autoreleasepool {
            NSURL *workURL = moddedBundleURL;
            NSArray<ZTCarra2Item *> *carra2Items = nil;
            ZTranscoderConfig *workConfig = config;
            BOOL isArchive = carra2Hash1.length > 0 || (!zt_file_is_unityfs(moddedBundleURL.path) && zt_file_is_zip(moddedBundleURL.path));
            if (isArchive) {
                NSString *stagedPath = nil;
                NSString *hash1 = carra2Hash1;
                NSString *hash2 = carra2Hash2;
                NSError *loadError = nil;
                if (!zt_load_carra2(moddedBundleURL, &stagedPath, &carra2Items, &hash1, &hash2, &loadError)) {
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, loadError); });
                    return;
                }
                if (stagedPath) {
                    workURL = [NSURL fileURLWithPath:stagedPath];
                } else {
                    workConfig = [ZTranscoderConfig new];
                    workConfig.targetBundlePath = config.targetBundlePath;
                    BOOL targetExists = NO;
                    if (workConfig.targetBundlePath.length > 0) {
                        NSString *candidate = workConfig.targetBundlePath;
                        if (![candidate hasPrefix:@"/"]) candidate = [NSHomeDirectory() stringByAppendingPathComponent:candidate];
                        BOOL isDir = NO;
                        targetExists = [NSFileManager.defaultManager fileExistsAtPath:candidate isDirectory:&isDir] && !isDir;
                    }
                    if (!targetExists && hash1.length && hash2.length) {
                        NSError *locateError = nil;
                        NSString *located = [UnityCacheLocator locateGameFilePathForHash1:hash1 hash2:hash2 error:&locateError];
                        if (located.length) {
                            workConfig.targetBundlePath = located;
                            targetExists = YES;
                            ZLog(@"[ZTranscoder] Carra2 target resolved from hashes %@/%@: %@", hash1, hash2, located);
                        }
                    }
                    if (!targetExists) {
                        NSError *noTarget = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"The game's bundle for this Carra2 mod could not be located.");
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, noTarget); });
                        return;
                    }
                }
            }
            NSURL *output = nil;
            NSError *error = nil;
            void (^mainProgress)(double, NSString *) = ^(double fraction, NSString *stage) {
                if (!uploadProgress) return;
                uint64_t total = zt_file_size(workURL.path);
                if (total > INT64_MAX) total = INT64_MAX;
                dispatch_async(dispatch_get_main_queue(), ^{ uploadProgress((int64_t)((double)total * fraction), (int64_t)total); });
            };
            mainProgress(0.0, @"Verifying the mod and locating the stock target");
            NSUInteger skippedObjects = 0;
            BOOL ok = zt_process_bundle_full(workURL, workConfig, carra2Items, mainProgress, &output, &skippedObjects, &error);
            if (!ok || !output) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
                return;
            }
            ZTranscoderHandle *handle = [ZTranscoderHandle new];
            handle.scratchBranch = output.path;
            handle.alreadyComplete = YES;
            handle.compressedByteSize = zt_file_size(output.path);
            if (skippedObjects > 0) handle.warningMessage = [NSString stringWithFormat:@"%lu of this mod's %lu objects couldn't be applied and were skipped. The mod may not display correctly.", (unsigned long)skippedObjects, (unsigned long)carra2Items.count];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(handle, nil); });
        }
    }];
}

+ (BOOL)isUploadCompressionEnabled { return NO; }
+ (void)setUploadCompressionEnabled:(BOOL)enabled { (void)enabled; }
@end

#pragma mark - ZTranscoderInstaller

NSString * const ZTranscoderInstallerErrorDomain = @"ZTranscoderInstallerErrorDomain";

static NSString * const kBackupSuffix = @".orig-bak";

static NSString * const kManifestFileName = @"manifest.json";

static NSString *zt_cab_for_bundle_file(NSString *path) {
    if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    NSString *cab = [UnityBundleCAB primaryCABForBundleAtPath:path error:nil];
    return cab.length > 0 ? cab : nil;
}

static void zt_set_modded(NSString *cab, BOOL modded) {
    if (cab.length > 0) zs_set_bundle_modded(cab, modded);
}

static NSString *zt_cab_for_installed_bundle(NSString *path) {
    NSString *cab = zt_cab_for_bundle_file(path);
    if (cab.length > 0) return cab;
    return [ZSFileIndex persistedCABForPath:path];
}

static BOOL zt_files_have_identical_bytes(NSString *pathA, NSString *pathB) {
    struct stat statA, statB;
    if (stat(pathA.fileSystemRepresentation, &statA) != 0 || stat(pathB.fileSystemRepresentation, &statB) != 0) return NO;
    if (statA.st_size != statB.st_size) return NO;
    int fdA = open(pathA.fileSystemRepresentation, O_RDONLY);
    if (fdA < 0) return NO;
    int fdB = open(pathB.fileSystemRepresentation, O_RDONLY);
    if (fdB < 0) { close(fdA); return NO; }
    const size_t chunk = 256 * 1024;
    uint8_t *bufA = malloc(chunk);
    uint8_t *bufB = malloc(chunk);
    BOOL identical = (bufA && bufB);
    while (identical) {
        ssize_t readA = read(fdA, bufA, chunk);
        ssize_t readB = read(fdB, bufB, chunk);
        if (readA != readB || readA < 0) { identical = NO; break; }
        if (readA == 0) break;
        if (memcmp(bufA, bufB, (size_t)readA) != 0) identical = NO;
    }
    free(bufA);
    free(bufB);
    close(fdA);
    close(fdB);
    return identical;
}

@implementation ZTranscoderInstaller

+ (NSString *)bundleBackupDirectory {
    return [ModAssetLibrary originalBundleBackupsDirectory];
}

+ (NSString *)bds_backupKeyForStockBundleURL:(NSURL *)stockBundleURL {
    NSString *path = stockBundleURL.path ?: stockBundleURL.absoluteString ?: @"";
    uint64_t hash = 1469598103934665603ULL;
    const char *bytes = path.UTF8String;
    if (bytes) {
        for (; *bytes != '\0'; bytes++) {
            hash ^= (uint64_t)(uint8_t)*bytes;
            hash *= 1099511628211ULL;
        }
    }
    return [NSString stringWithFormat:@"%@-%016llx", path.lastPathComponent ?: @"backup", hash];
}

+ (BOOL)bds_ensureBackupDirectoryExists:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    if (!dir) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve Library directory."}];
        }
        return NO;
    }
    NSError *createError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&createError]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: createError.localizedDescription ?: @"Couldn't create backup directory."}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Manifest

+ (NSString *)bds_manifestPath {
    return [[self bundleBackupDirectory] stringByAppendingPathComponent:kManifestFileName];
}

+ (NSMutableDictionary<NSString *, NSString *> *)bds_loadManifest {
    NSData *data = [NSData dataWithContentsOfFile:[self bds_manifestPath]];
    if (!data) return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return [NSMutableDictionary dictionary];
    return (NSMutableDictionary *)obj;
}

+ (BOOL)bds_writeManifest:(NSDictionary<NSString *, NSString *> *)manifest {
    NSData *data = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) return NO;
    return [data writeToFile:[self bds_manifestPath] options:NSDataWritingAtomic error:nil];
}

#pragma mark - Public API

+ (BOOL)installDoctoredBundleAtURL:(NSURL *)doctoredURL
                  toStockBundleURL:(NSURL *)stockBundleURL
                              error:(NSError **)error {
    NSData *doctoredData = [NSData dataWithContentsOfURL:doctoredURL options:0 error:error];
    if (!doctoredData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorCantReadDoctored
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the doctored bundle."}];
        }
        return NO;
    }

    if (![self bds_ensureBackupDirectoryExists:error]) return NO;

    BOOL scoped = [stockBundleURL startAccessingSecurityScopedResource];

    NSString *backupKey = [self bds_backupKeyForStockBundleURL:stockBundleURL];
    NSString *backupPath = [[self bundleBackupDirectory] stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]];
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL stockExists = [fm fileExistsAtPath:stockBundleURL.path];
    if (stockExists && ![fm fileExistsAtPath:backupPath]) {
        NSError *backupError = nil;
        if (![fm copyItemAtURL:stockBundleURL toURL:[NSURL fileURLWithPath:backupPath] error:&backupError]) {
            if (error) {
                *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                              code:ZTranscoderInstallerErrorBackupFailed
                                          userInfo:@{NSLocalizedDescriptionKey: backupError.localizedDescription ?: @"Couldn't back up the original bundle."}];
            }
            if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
            return NO;
        }

        NSMutableDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
        manifest[backupKey] = stockBundleURL.path;
        [self bds_writeManifest:manifest];
    } else if (!stockExists) {
        ZLog(@"[ZTranscoderInstaller] no existing file at %@ - nothing to back up (synthesized/never-cached destination), writing doctored bundle fresh.", stockBundleURL.path);
    }

    NSError *writeError = nil;
    if (![doctoredData writeToURL:stockBundleURL options:NSDataWritingAtomic error:&writeError]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't swap in the doctored bundle."}];
        }
        if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
        return NO;
    }

    if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
    ZLog(@"[ZTranscoderInstaller] installed doctored bundle at %@", stockBundleURL.path);

    zs_track_asset_path(stockBundleURL.path);

    NSMutableOrderedSet<NSString *> *moddedCABs = [NSMutableOrderedSet orderedSet];
    NSString *doctoredCAB = zt_cab_for_bundle_file(doctoredURL.path);
    NSString *installedCAB = zt_cab_for_installed_bundle(stockBundleURL.path);
    NSString *backupCAB = [fm fileExistsAtPath:backupPath] ? zt_cab_for_bundle_file(backupPath) : nil;
    if (doctoredCAB.length > 0) [moddedCABs addObject:doctoredCAB];
    if (installedCAB.length > 0) [moddedCABs addObject:installedCAB];
    if (backupCAB.length > 0) [moddedCABs addObject:backupCAB];
    if (moddedCABs.count == 0) {
        ZLog(@"[ZTranscoderInstaller] installed %@ but couldn't resolve its CAB, so it was not recorded in moddedBundles", stockBundleURL.path.lastPathComponent);
    }
    for (NSString *cab in moddedCABs) {
        zt_set_modded(cab, YES);
        ZLog(@"[ZTranscoderInstaller] recorded %@ in moddedBundles", cab);
    }

    return YES;
}

+ (void)reconcileModdedBundles {
    NSString *dir = [self bundleBackupDirectory];
    if (!dir) return;

    NSDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableOrderedSet<NSString *> *toAdd = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *toRemove = [NSMutableOrderedSet orderedSet];
    for (NSString *backupKey in manifest) {
        NSString *livePath = manifest[backupKey];
        if (![livePath isKindOfClass:[NSString class]] || livePath.length == 0) continue;
        NSString *backupPath = [dir stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]];
        if (![fm fileExistsAtPath:backupPath]) continue;
        if (![fm fileExistsAtPath:livePath]) continue;

        NSString *backupCAB = zt_cab_for_bundle_file(backupPath);
        NSString *liveCAB = zt_cab_for_installed_bundle(livePath);
        NSMutableOrderedSet<NSString *> *target = zt_files_have_identical_bytes(livePath, backupPath) ? toRemove : toAdd;
        if (backupCAB.length > 0) [target addObject:backupCAB];
        if (liveCAB.length > 0) [target addObject:liveCAB];
    }
    [toRemove minusOrderedSet:toAdd];
    zs_apply_modded_bundle_changes(toAdd.array, toRemove.array);
}

+ (BOOL)bds_fileAtPath:(NSString *)pathA hasIdenticalBytesToFileAtPath:(NSString *)pathB {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:pathA] || ![fm fileExistsAtPath:pathB]) return NO;

    NSDictionary<NSFileAttributeKey, id> *attrsA = [fm attributesOfItemAtPath:pathA error:nil];
    NSDictionary<NSFileAttributeKey, id> *attrsB = [fm attributesOfItemAtPath:pathB error:nil];
    unsigned long long sizeA = [attrsA[NSFileSize] unsignedLongLongValue];
    unsigned long long sizeB = [attrsB[NSFileSize] unsignedLongLongValue];
    if (sizeA != sizeB) return NO;

    NSData *dataA = [NSData dataWithContentsOfFile:pathA];
    NSData *dataB = [NSData dataWithContentsOfFile:pathB];
    if (!dataA || !dataB) return NO;
    return [dataA isEqualToData:dataB];
}

+ (NSInteger)restoreAllBackedUpBundlesForce:(BOOL)force error:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    if (!dir || ![[NSFileManager defaultManager] fileExistsAtPath:dir]) return 0;

    NSDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
    if (manifest.count == 0) return 0;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger restored = 0;

    for (NSString *backupKey in manifest) {
        NSString *originalPath = manifest[backupKey];
        NSString *backupPath = [dir stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]];
        if (![fm fileExistsAtPath:backupPath] || originalPath.length == 0) continue;

        if (!force && [self bds_fileAtPath:originalPath hasIdenticalBytesToFileAtPath:backupPath]) {
            zt_set_modded(zt_cab_for_bundle_file(backupPath), NO);
            continue;
        }

        NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
        if (!backupData) continue;

        NSString *liveCAB = zt_cab_for_bundle_file(originalPath);
        NSError *writeError = nil;
        if ([backupData writeToFile:originalPath options:NSDataWritingAtomic error:&writeError]) {
            restored++;
            zt_set_modded(liveCAB, NO);
            zt_set_modded(zt_cab_for_bundle_file(backupPath), NO);
        } else {
            ZLog(@"[ZTranscoderInstaller] couldn't restore %@ to %@: %@", backupKey, originalPath, writeError);
        }
    }

    return restored;
}

+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error {
    return [self restoreAllBackedUpBundlesForce:NO error:error];
}

+ (BOOL)cacheOriginalBackForStockBundleURL:(NSURL *)stockBundleURL error:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    NSString *backupKey = [self bds_backupKeyForStockBundleURL:stockBundleURL];
    NSString *backupPath = dir ? [dir stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]] : nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (!backupPath || ![fm fileExistsAtPath:backupPath]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"No backed-up original found for this bundle."}];
        }
        return NO;
    }

    NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
    if (!backupData) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the backed-up original."}];
        }
        return NO;
    }

    NSString *liveCAB = zt_cab_for_bundle_file(stockBundleURL.path);
    BOOL scoped = [stockBundleURL startAccessingSecurityScopedResource];
    NSError *writeError = nil;
    BOOL wrote = [backupData writeToURL:stockBundleURL options:NSDataWritingAtomic error:&writeError];
    if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];

    if (!wrote) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't write the original bundle back."}];
        }
        return NO;
    }

    zt_set_modded(liveCAB, NO);
    zt_set_modded(zt_cab_for_bundle_file(backupPath), NO);

    ZLog(@"[ZTranscoderInstaller] cached %@ - live bytes swapped back to the backed-up original", stockBundleURL.lastPathComponent);
    return YES;
}

@end

@interface ZTLiveItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;
@property (nonatomic, assign) int32_t format;
@property (nonatomic, assign) int32_t mipCount;
@property (nonatomic, strong) NSData *payload;
@end

@implementation ZTLiveItem
@end

@interface ZTLiveJob : NSObject
@property (nonatomic, copy) NSString *cab;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) UnityBundleArchive *archive;
@property (nonatomic, strong) ZTSerializedDocument *document;
@property (nonatomic, copy) NSArray<ZTLiveItem *> *items;
@property (nonatomic, assign) NSUInteger skipped;
@end

@implementation ZTLiveJob
@end

typedef struct {
    void *texture2D;
    const void *getName;
    const void *getWidth;
    const void *getHeight;
    const void *getMips;
    const void *getFormat;
    const void *getGraphicsFormat;
    const void *ctor;
    const void *loadRaw;
    const void *apply;
    const void *copy;
    const void *destroy;
} ZTLiveApi;

static const void *zt_live_find_method(void *klass, const char *name, uint32_t argc, void *const *paramClasses) {
    if (!klass) return NULL;
    void *iter = NULL;
    const void *method = NULL;
    while ((method = [IL2CppBridge nextMethodOnClass:klass iterator:&iter])) {
        const char *methodName = [IL2CppBridge nameOfMethod:method];
        if (!methodName || strcmp(methodName, name) != 0) continue;
        if ([IL2CppBridge paramCountOfMethod:method] != argc) continue;
        BOOL match = YES;
        for (uint32_t i = 0; i < argc && match; i++) {
            if (!paramClasses[i]) continue;
            const void *type = [IL2CppBridge paramTypeForMethod:method index:i];
            match = type && [IL2CppBridge classFromType:type] == paramClasses[i];
        }
        if (match) return method;
    }
    return NULL;
}

static BOOL zt_live_resolve_api(ZTLiveApi *api) {
    memset(api, 0, sizeof(*api));
    api->texture2D = mt_class("UnityEngine", "Texture2D", "CoreModule");
    void *textureClass = mt_class("UnityEngine", "Texture", "CoreModule");
    void *objectClass = mt_class("UnityEngine", "Object", "CoreModule");
    void *graphicsClass = mt_class("UnityEngine", "Graphics", "CoreModule");
    void *formatClass = mt_class("UnityEngine", "TextureFormat", "CoreModule");
    void *intClass = mt_class("System", "Int32", "mscorlib");
    void *boolClass = mt_class("System", "Boolean", "mscorlib");
    if (!api->texture2D || !textureClass || !objectClass || !graphicsClass || !formatClass || !intClass || !boolClass) {
        ZLog(@"[ZTLiveReload] missing IL2CPP classes tex2D=%p tex=%p obj=%p gfx=%p fmt=%p int=%p bool=%p", api->texture2D, textureClass, objectClass, graphicsClass, formatClass, intClass, boolClass);
        return NO;
    }
    api->getName = mt_method(api->texture2D, "get_name", 0);
    api->getWidth = mt_method(api->texture2D, "get_width", 0);
    api->getHeight = mt_method(api->texture2D, "get_height", 0);
    api->getMips = mt_method(api->texture2D, "get_mipmapCount", 0);
    api->getFormat = mt_method(api->texture2D, "get_format", 0);
    api->getGraphicsFormat = mt_method(api->texture2D, "get_graphicsFormat", 0);
    void *ctorParams[5] = { intClass, intClass, formatClass, intClass, boolClass };
    api->ctor = zt_live_find_method(api->texture2D, ".ctor", 5, ctorParams);
    void *rawParams[2] = { NULL, intClass };
    api->loadRaw = zt_live_find_method(api->texture2D, "LoadRawTextureData", 2, rawParams);
    api->apply = mt_method(api->texture2D, "Apply", 2);
    void *copyParams[6] = { textureClass, intClass, intClass, textureClass, intClass, intClass };
    api->copy = zt_live_find_method(graphicsClass, "CopyTexture", 6, copyParams);
    void *destroyParams[1] = { objectClass };
    api->destroy = zt_live_find_method(objectClass, "DestroyImmediate", 1, destroyParams);
    BOOL ok = api->getName && api->getWidth && api->getHeight && api->getMips && api->getFormat && api->getGraphicsFormat && api->ctor && api->loadRaw && api->apply && api->copy && api->destroy;
    if (!ok) {
        ZLog(@"[ZTLiveReload] missing IL2CPP methods name=%p w=%p h=%p mips=%p fmt=%p gfx=%p ctor=%p raw=%p apply=%p copy=%p destroy=%p", api->getName, api->getWidth, api->getHeight, api->getMips, api->getFormat, api->getGraphicsFormat, api->ctor, api->loadRaw, api->apply, api->copy, api->destroy);
    }
    return ok;
}

static BOOL zt_live_get_int(void *obj, const void *method, int32_t *outValue) {
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:method onInstance:obj args:NULL outException:&exc];
    if (exc || !boxed) return NO;
    *outValue = *(int32_t *)((uint8_t *)boxed + 0x10);
    return YES;
}

static NSString *zt_live_get_name(void *obj, const void *method) {
    void *exc = NULL;
    void *str = [IL2CppBridge invokeMethod:method onInstance:obj args:NULL outException:&exc];
    if (exc || !str) return nil;
    return [IL2CppBridge nsStringFromIl2CppString:str];
}

static void *zt_live_make_temp(ZTLiveApi *api, ZTLiveItem *item, BOOL linear) {
    void *object = [IL2CppBridge newObjectForClass:api->texture2D];
    if (!object) return NULL;
    int32_t width = (int32_t)item.width;
    int32_t height = (int32_t)item.height;
    int32_t format = item.format;
    int32_t mips = item.mipCount;
    uint8_t linearFlag = linear ? 1 : 0;
    void *args[5] = { &width, &height, &format, &mips, &linearFlag };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:api->ctor onInstance:object args:args outException:&exc];
    return exc ? NULL : object;
}

static void zt_live_destroy(ZTLiveApi *api, void *object) {
    if (!object) return;
    void *args[1] = { object };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:api->destroy onInstance:NULL args:args outException:&exc];
}

static BOOL zt_live_patch(ZTLiveApi *api, void *live, ZTLiveItem *item, NSString **outReason) {
    int32_t liveGraphics = 0;
    if (!zt_live_get_int(live, api->getGraphicsFormat, &liveGraphics)) {
        if (outReason) *outReason = @"couldn't read the live graphics format";
        return NO;
    }
    void *temp = zt_live_make_temp(api, item, NO);
    int32_t tempGraphics = 0;
    if (temp && zt_live_get_int(temp, api->getGraphicsFormat, &tempGraphics) && tempGraphics != liveGraphics) {
        zt_live_destroy(api, temp);
        temp = zt_live_make_temp(api, item, YES);
        tempGraphics = 0;
        if (temp) zt_live_get_int(temp, api->getGraphicsFormat, &tempGraphics);
    }
    if (!temp) {
        if (outReason) *outReason = @"couldn't create the staging texture";
        return NO;
    }
    if (tempGraphics != liveGraphics) {
        zt_live_destroy(api, temp);
        if (outReason) *outReason = [NSString stringWithFormat:@"graphics format mismatch live=%d staged=%d", liveGraphics, tempGraphics];
        return NO;
    }
    void *exc = NULL;
    void *dataPointer = (void *)item.payload.bytes;
    int32_t dataSize = (int32_t)item.payload.length;
    void *loadArgs[2] = { &dataPointer, &dataSize };
    [IL2CppBridge invokeMethod:api->loadRaw onInstance:temp args:loadArgs outException:&exc];
    if (exc) {
        zt_live_destroy(api, temp);
        if (outReason) *outReason = @"LoadRawTextureData threw";
        return NO;
    }
    uint8_t updateMips = 0;
    uint8_t makeUnreadable = 1;
    void *applyArgs[2] = { &updateMips, &makeUnreadable };
    [IL2CppBridge invokeMethod:api->apply onInstance:temp args:applyArgs outException:&exc];
    if (exc) {
        zt_live_destroy(api, temp);
        if (outReason) *outReason = @"Apply threw";
        return NO;
    }
    BOOL copied = YES;
    for (int32_t mip = 0; mip < item.mipCount && copied; mip++) {
        int32_t element = 0;
        int32_t level = mip;
        void *copyArgs[6] = { temp, &element, &level, live, &element, &level };
        [IL2CppBridge invokeMethod:api->copy onInstance:NULL args:copyArgs outException:&exc];
        if (exc) copied = NO;
    }
    zt_live_destroy(api, temp);
    if (!copied) {
        if (outReason) *outReason = @"Graphics.CopyTexture threw";
        return NO;
    }
    return YES;
}

static NSString *zt_live_resolve_cab(NSString *input, NSString **outPath, NSString **outError) {
    NSString *trimmed = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        if (outError) *outError = @"Usage: /reload CAB-XXXXX";
        return nil;
    }
    NSString *needle = trimmed.lowercaseString;
    if (![needle hasPrefix:@"cab-"]) needle = [@"cab-" stringByAppendingString:needle];
    NSDictionary<NSString *, NSArray<NSString *> *> *map = [ZSFileIndex persistedCABMap];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (NSString *cab in map) {
        if ([cab isKindOfClass:[NSString class]] && [cab.lowercaseString hasPrefix:needle]) [hits addObject:cab];
    }
    if (hits.count > 1) {
        NSArray<NSString *> *exact = [hits filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *cab, NSDictionary *bindings) {
            return [cab.lowercaseString isEqualToString:needle];
        }]];
        if (exact.count == 1) hits = [exact mutableCopy];
    }
    if (hits.count > 1) {
        if (outError) *outError = [NSString stringWithFormat:@"%lu bundles match %@, add more characters", (unsigned long)hits.count, trimmed];
        return nil;
    }
    NSString *cab = hits.firstObject;
    NSString *path = cab ? [ZSFileIndex persistedPathsForCAB:cab].firstObject : nil;
    if (path.length == 0) {
        NSError *locateError = nil;
        NSString *located = [UnityCacheLocator locateBundlePathForCAB:trimmed error:&locateError];
        if (located.length > 0) {
            cab = trimmed;
            path = located;
        }
    }
    if (path.length == 0 || cab.length == 0) {
        if (outError) *outError = [NSString stringWithFormat:@"No bundle found for %@", trimmed];
        return nil;
    }
    if (outPath) *outPath = path;
    return cab;
}

static NSString *zt_live_texture_name(ZTTextureRecord *texture, NSData *serialized) {
    if (texture.name.length > 0) return texture.name;
    uint64_t start = texture.object.objectStart;
    uint64_t limit = start + texture.object.byteSize;
    if (limit > serialized.length || limit - start < 4) return nil;
    const uint8_t *buf = serialized.bytes;
    uint32_t length = zt_le32(buf + start);
    if (length == 0 || length > 255 || length > limit - start - 4) return nil;
    return [[NSString alloc] initWithBytes:buf + start + 4 length:length encoding:NSUTF8StringEncoding];
}

static ZTLiveJob *zt_live_build_job(NSString *input, NSString **outError) {
    NSString *path = nil;
    NSString *resolveError = nil;
    NSString *cab = zt_live_resolve_cab(input, &path, &resolveError);
    if (!cab) {
        if (outError) *outError = resolveError;
        return nil;
    }
    ZLog(@"[ZTLiveReload] resolved %@ -> %@", input, path);
    NSError *error = nil;
    UnityBundleArchive *archive = [UnityBundleCAB decompressedArchiveAtPath:path error:&error];
    if (!archive) {
        ZLog(@"[ZTLiveReload] couldn't open %@: %@", path, error.localizedDescription);
        if (outError) *outError = @"Couldn't read the bundle";
        return nil;
    }
    UnityBundleNode *cabNode = nil;
    for (UnityBundleNode *node in archive.nodes) if (node.flags & 4u) cabNode = node;
    if (!cabNode) {
        if (outError) *outError = @"Bundle has no SerializedFile";
        return nil;
    }
    NSData *serialized = [NSData dataWithBytesNoCopy:(void *)((uint8_t *)archive.data.bytes + cabNode.offset) length:(NSUInteger)cabNode.size freeWhenDone:NO];
    ZTSerializedDocument *document = zt_parse_serialized(serialized, &error);
    if (!document) {
        ZLog(@"[ZTLiveReload] couldn't parse SerializedFile: %@", error.localizedDescription);
        if (outError) *outError = @"Couldn't parse the bundle";
        return nil;
    }
    NSMutableArray<ZTLiveItem *> *items = [NSMutableArray array];
    NSUInteger skipped = 0;
    for (ZTTextureRecord *texture in document.textures) {
        NSString *textureName = zt_live_texture_name(texture, serialized);
        if (textureName.length == 0 || !zt_texture_has_pixel_data(texture) || zt_format_is_crunched(texture.format) || texture.width == 0 || texture.height == 0 || texture.mipCount <= 0) {
            ZLog(@"[ZTLiveReload] skip pathID=%lld name='%@' format=%d size=%ux%u mips=%d", (long long)texture.object.pathID, textureName, texture.format, texture.width, texture.height, texture.mipCount);
            skipped++;
            continue;
        }
        NSData *payload = nil;
        NSError *payloadError = nil;
        if (!zt_texture_payload(texture, archive, serialized, &payload, &payloadError) || payload.length == 0) {
            ZLog(@"[ZTLiveReload] no payload for '%@': %@", textureName, payloadError.localizedDescription);
            skipped++;
            continue;
        }
        if (texture.completeImageSize > 0 && payload.length != texture.completeImageSize) {
            ZLog(@"[ZTLiveReload] payload size mismatch for '%@' payload=%lu expected=%u", textureName, (unsigned long)payload.length, texture.completeImageSize);
            skipped++;
            continue;
        }
        ZTLiveItem *item = [ZTLiveItem new];
        item.name = textureName;
        item.width = texture.width;
        item.height = texture.height;
        item.format = texture.format;
        item.mipCount = texture.mipCount;
        item.payload = payload;
        [items addObject:item];
    }
    ZLog(@"[ZTLiveReload] %@ has %lu Texture2D, %lu usable, %lu skipped", cab, (unsigned long)document.textures.count, (unsigned long)items.count, (unsigned long)skipped);
    if (items.count == 0) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ has no reloadable textures", cab];
        return nil;
    }
    ZTLiveJob *job = [ZTLiveJob new];
    job.cab = cab;
    job.path = path;
    job.archive = archive;
    job.document = document;
    job.items = items;
    job.skipped = skipped;
    return job;
}

static BOOL zt_live_apply_job(ZTLiveJob *job, NSString **outSummary) {
    ZTLiveApi api;
    if (!zt_live_resolve_api(&api)) {
        if (outSummary) *outSummary = @"Reload failed: IL2CPP texture API unavailable";
        return NO;
    }
    NSMutableDictionary<NSString *, NSMutableArray<ZTLiveItem *> *> *byName = [NSMutableDictionary dictionary];
    for (ZTLiveItem *item in job.items) {
        NSMutableArray<ZTLiveItem *> *bucket = byName[item.name];
        if (!bucket) {
            bucket = [NSMutableArray array];
            byName[item.name] = bucket;
        }
        [bucket addObject:item];
    }
    NSUInteger liveCount = 0;
    void *array = zs_resources_find_all_for_class(api.texture2D, &liveCount);
    if (!array) {
        if (outSummary) *outSummary = @"Reload failed: couldn't enumerate live textures";
        return NO;
    }
    NSMutableSet<NSString *> *patchedNames = [NSMutableSet set];
    NSUInteger patched = 0;
    NSUInteger mismatched = 0;
    NSUInteger failed = 0;
    for (NSUInteger i = 0; i < liveCount; i++) {
        void *live = zs_array_object_at(array, i);
        if (!live) continue;
        NSString *name = zt_live_get_name(live, api.getName);
        NSArray<ZTLiveItem *> *bucket = name.length > 0 ? byName[name] : nil;
        if (!bucket) continue;
        int32_t width = 0, height = 0, mips = 0, format = 0;
        if (!zt_live_get_int(live, api.getWidth, &width) || !zt_live_get_int(live, api.getHeight, &height) || !zt_live_get_int(live, api.getMips, &mips) || !zt_live_get_int(live, api.getFormat, &format)) {
            failed++;
            continue;
        }
        ZTLiveItem *match = nil;
        for (ZTLiveItem *candidate in bucket) {
            if ((int32_t)candidate.width == width && (int32_t)candidate.height == height && candidate.format == format && candidate.mipCount == mips) {
                match = candidate;
                break;
            }
        }
        if (!match) {
            ZTLiveItem *first = bucket.firstObject;
            ZLog(@"[ZTLiveReload] '%@' live=%dx%d fmt=%d mips=%d bundle=%ux%u fmt=%d mips=%d - skipped", name, width, height, format, mips, first.width, first.height, first.format, first.mipCount);
            mismatched++;
            continue;
        }
        NSString *reason = nil;
        if (zt_live_patch(&api, live, match, &reason)) {
            patched++;
            [patchedNames addObject:name];
            ZLog(@"[ZTLiveReload] patched '%@' %dx%d fmt=%d mips=%d bytes=%lu", name, width, height, format, mips, (unsigned long)match.payload.length);
        } else {
            failed++;
            ZLog(@"[ZTLiveReload] failed '%@': %@", name, reason);
        }
    }
    NSUInteger notLoaded = byName.count > patchedNames.count ? byName.count - patchedNames.count : 0;
    ZLog(@"[ZTLiveReload] %@ done: live=%lu patched=%lu notLoaded=%lu mismatched=%lu failed=%lu", job.cab, (unsigned long)liveCount, (unsigned long)patched, (unsigned long)notLoaded, (unsigned long)mismatched, (unsigned long)failed);
    NSMutableString *summary = [NSMutableString stringWithFormat:@"Reloaded %lu texture%@ from %@", (unsigned long)patched, patched == 1 ? @"" : @"s", [job.cab substringToIndex:MIN(job.cab.length, (NSUInteger)9)]];
    if (notLoaded > 0) [summary appendFormat:@", %lu not loaded", (unsigned long)notLoaded];
    if (mismatched > 0) [summary appendFormat:@", %lu mismatched", (unsigned long)mismatched];
    if (failed > 0) [summary appendFormat:@", %lu failed", (unsigned long)failed];
    if (outSummary) *outSummary = summary;
    return patched > 0;
}

@implementation ZTLiveReloader

+ (void)reloadBundleForCABInput:(NSString *)input completion:(void (^)(BOOL, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *buildError = nil;
        ZTLiveJob *job = zt_live_build_job(input, &buildError);
        if (!job) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, buildError ?: @"Reload failed");
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *summary = nil;
            BOOL success = zt_live_apply_job(job, &summary);
            if (completion) completion(success, summary);
        });
    });
}

@end
