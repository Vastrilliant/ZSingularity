#import "Transcoder.h"
#import "ZTweakLog.h"
#import "UnityBundleTools.h"
#import "Mods.h"
#import "ZSLowRes.h"
#import "ZSCrunch.h"
#import "ZSEngine.h"
#import "IL2CppIntrospection.h"
#import <CommonCrypto/CommonDigest.h>
#import <Metal/Metal.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <lz4hc.h>
#import <objc/runtime.h>
#import <errno.h>
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

static BOOL zt_class_is_transcoded(int32_t classID) {
    return classID == kZTClassTexture2D
        || classID == kZTClassSprite
        || classID == kZTClassSpriteRenderer
        || classID == kZTClassSpriteMask
        || classID == kZTClassSpriteAtlas
        || classID == kZTClassTextAsset
        || classID == kZTClassAssetBundle;
}

static BOOL zt_class_is_transplantable(int32_t classID, BOOL layoutShared, ZTranscoderConfig *config) {
    if (![config allowsTransplantOfClass:classID]) return NO;
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

static uint16_t zt_be16(const uint8_t *p) {
    return ((uint16_t)p[0] << 8) | p[1];
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

static NSString *zt_temp_directory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@", kZSTranscoderTempPrefix, NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    return path;
}

static BOOL zt_write_all(NSFileHandle *handle, const void *bytes, NSUInteger length, NSError **error) {
    if (!handle) return NO;
    @try {
        if (length) [handle writeData:[NSData dataWithBytes:bytes length:length]];
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
        while (YES) {
            NSData *chunk = [input readDataOfLength:1024u * 1024u];
            if (chunk.length == 0) break;
            if (!zt_write_all(output, chunk.bytes, chunk.length, error)) {
                [input closeFile];
                return NO;
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

static NSString *zt_sha256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *text = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [text appendFormat:@"%02x", digest[i]];
    return text;
}

static NSString *zt_sha256_range(const uint8_t *base, uint64_t offset, uint64_t length) {
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    const size_t chunk = 1024u * 1024u;
    while (length) {
        size_t n = (size_t)MIN((uint64_t)chunk, length);
        CC_SHA256_Update(&ctx, base + offset, (CC_LONG)n);
        offset += n;
        length -= n;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *text = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [text appendFormat:@"%02x", digest[i]];
    return text;
}

static uint64_t zt_mip_dimension(uint32_t value, uint32_t mip) {
    return MAX(1u, value >> mip);
}

static BOOL zt_format_is_crunched(int32_t format) {
    return format == 28 || format == 29 || format == 64 || format == 65;
}

static BOOL zt_format_is_transplant_only(int32_t format) {
    return format == 4 || format == 45 || format == 46 || format == 47;
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
@property (nonatomic, copy) NSArray<NSValue *> *typeRanges;
@property (nonatomic, strong) NSMutableArray<NSData *> *injectedTypes;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSDictionary<NSString *, NSData *> *> *textureTrees;
@end

@implementation ZTSerializedDocument
@end

@interface ZTCarra2Item : NSObject
@property (nonatomic, assign) int64_t pathID;
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
@property (nonatomic, copy, nullable) NSData *sourceObjectData;
@end

@implementation ZTTextureReplacement
@end

static int zt_type_tree_subtree_end(const uint8_t *nodes, uint32_t count, uint32_t i) {
    uint8_t level = nodes[(size_t)i * 32u + 2u];
    uint32_t j = i + 1;
    while (j < count && nodes[(size_t)j * 32u + 2u] > level) j++;
    return (int)j;
}

static const char *zt_type_tree_name(const uint8_t *nodes, uint32_t nodeCount, const uint8_t *strings, uint32_t stringSize, uint32_t i) {
    if (i >= nodeCount || !strings) return NULL;
    uint32_t nameOffset = zt_le32(nodes + (size_t)i * 32u + 8u);
    if (nameOffset & 0x80000000u || nameOffset >= stringSize) return NULL;
    const uint8_t *p = strings + nameOffset;
    const uint8_t *end = strings + stringSize;
    const uint8_t *q = p;
    while (q < end && *q) q++;
    if (q >= end) return NULL;
    return (const char *)p;
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
        *outPayload = [NSData dataWithBytes:base + texture.imageDataPosition + 4 length:texture.imageDataLength];
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
    *outPayload = [NSData dataWithBytes:streamBase + texture.streamOffset length:texture.streamSize];
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

static BOOL zt_make_astc_replacement(ZTTextureRecord *source, NSData *payload, NSString *workDir, NSString **outPath, uint32_t *outSize, NSError **error, void (^progress)(double, NSString *)) {
    if (source.mipCount <= 0) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"Texture2D has an invalid mip count.");
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
    NSData *baseData = zt_format_is_crunched(source.format) ? payload : [payload subdataWithRange:NSMakeRange(0, (NSUInteger)baseSize)];
    NSMutableData *rgba = nil;
    NSError *decodeError = nil;
    BOOL ok = zt_decode_texture_mip(source, baseData, source.width, source.height, 0, &rgba, &decodeError);
    if (!ok && error) *error = decodeError ?: ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't decode Texture2D %@.", source.name]);
    uint64_t totalOutput = 0;
    if (ok) {
        NSError *encodeError = nil;
        NSData *astc = [ZSLowRes encodeRGBA8DataToASTC6:rgba width:source.width height:source.height sRGB:(source.colorSpace != 0) error:&encodeError];
        if (!astc) {
            if (error) *error = encodeError ?: ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't encode Texture2D %@ as ASTC 6x6.", source.name]);
            ok = NO;
        } else if (!zt_write_all(writer, astc.bytes, astc.length, error)) {
            ok = NO;
        } else {
            totalOutput = astc.length;
            if (progress) progress(1.0, [NSString stringWithFormat:@"Encoded %@ as ASTC 6x6", source.name.length ? source.name : @"<unnamed>"]);
        }
    }
    @try { [writer closeFile]; } @catch (__unused NSException *exception) {}
    if (!ok) { [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil]; return NO; }
    if (totalOutput > UINT32_MAX) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"ASTC output exceeds Unity's 32-bit Texture2D image-size field.");
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

static NSData *zt_build_texture_object_from_source(ZTTextureRecord *source, NSData *sourceObject, NSData *encodedData, uint32_t encodedSize) {
    if (!source || !sourceObject || !encodedData) return nil;
    uint64_t base = source.object.objectStart;
    NSUInteger imageField = (NSUInteger)(source.imageDataPosition - base);
    if (imageField > sourceObject.length || sourceObject.length - imageField < 4) return nil;
    NSUInteger oldImageStart = imageField + 4u;
    NSUInteger oldImageEnd = oldImageStart + source.imageDataLength;
    if (oldImageEnd > sourceObject.length) return nil;
    NSUInteger oldStreamStart = (NSUInteger)(source.streamOffsetPosition - base);
    if (oldStreamStart > sourceObject.length || oldStreamStart < oldImageEnd) return nil;
    NSMutableData *out = [NSMutableData data];
    [out appendBytes:sourceObject.bytes length:imageField];
    uint8_t imageLength[4] = {(uint8_t)encodedSize, (uint8_t)(encodedSize >> 8), (uint8_t)(encodedSize >> 16), (uint8_t)(encodedSize >> 24)};
    [out appendBytes:imageLength length:4];
    [out appendData:encodedData];
    while (out.length & 3u) { uint8_t zero = 0; [out appendBytes:&zero length:1]; }
    uint8_t streamZero[12] = {0};
    [out appendBytes:streamZero length:12];
    uint8_t emptyPathLength[4] = {0};
    [out appendBytes:emptyPathLength length:4];
    if (!zt_patch_u32_relative(out, base, source.formatPosition, 50u)) return nil;
    if (!zt_patch_u32_relative(out, base, source.mipCountPosition, 1u)) return nil;
    if (!zt_patch_u32_relative(out, base, source.completeSizePosition, encodedSize)) return nil;
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
    return [NSData dataWithBytes:(const uint8_t *)data.bytes + object.objectStart length:object.byteSize];
}

static NSData *zt_rebuilt_object_data(ZTSerializedObject *object, ZTTextureReplacement *replacement, ZTSerializedDocument *targetDoc) {
    if (replacement) {
        NSData *encoded = [NSData dataWithContentsOfFile:replacement.encodedPath];
        if (!encoded) return nil;
        NSData *sourceRawObject = replacement.sourceObjectData;
        return sourceRawObject ? zt_build_texture_object_from_source(replacement.source, sourceRawObject, encoded, replacement.encodedSize) : nil;
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
    if (addedCount > 0) {
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
        NSData *objectData = nil;
        NSString *key = [NSString stringWithFormat:@"%lld", (long long)object.pathID];
        ZTTextureReplacement *replacement = replacements[key];
        objectData = zt_rebuilt_object_data(object, replacement, targetDoc);
        if (!objectData || objectData.length > UINT32_MAX) {
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Couldn't size rebuilt object PathID=%lld.", (long long)object.pathID]);
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
        [newSizes addObject:@(objectData.length)];
        cursor += objectData.length;
        if (objectData != object.replacementObject && objectData != targetDoc.data) objectData = nil;
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
    if (headerBytes.length >= 40 && zt_be32(base + 8) >= 22u) {
        uint8_t *hb = headerBytes.mutableBytes;
        for (NSUInteger b = 0; b < 8; b++) hb[24 + b] = (uint8_t)(expectedFileSize >> (8 * (7 - b)));
        if (addedCount > 0) {
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
        NSString *key = [NSString stringWithFormat:@"%lld", (long long)object.pathID];
        ZTTextureReplacement *replacement = replacements[key];
        NSData *objectData = nil;
        objectData = zt_rebuilt_object_data(object, replacement, targetDoc);
        if (!objectData || objectData.length != [newSizes[i] unsignedIntegerValue]) {
            [out closeFile];
            if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, [NSString stringWithFormat:@"Rebuilt object PathID=%lld changed size between passes.", (long long)object.pathID]);
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
        if (!zt_write_all(out, objectData.bytes, objectData.length, error)) {
            [out closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
            return NO;
        }
        written += objectData.length;
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
    NSData *headerData = [NSData dataWithContentsOfFile:templateBundlePath];
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
    void (^emitBlock)(NSData *) = ^(NSData *data) {
        NSUInteger n = data.length;
        int bound = LZ4_compressBound((int)n);
        NSMutableData *compressed = [NSMutableData dataWithLength:(NSUInteger)MAX(bound, (int)n)];
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
            [blockOutput writeData:[compressed subdataWithRange:NSMakeRange(0, (NSUInteger)c)]];
            compressedTotal += (uint64_t)c;
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
        while (remaining) {
            NSUInteger room = (NSUInteger)kZSTranscoderBlockSize - pending.length;
            NSUInteger n = (NSUInteger)MIN((uint64_t)room, remaining);
            NSData *data = [input readDataOfLength:n];
            if (data.length != n) { blockReadFailed = YES; break; }
            [pending appendData:data];
            remaining -= n;
            if (pending.length == kZSTranscoderBlockSize) {
                emitBlock(pending);
                [pending setLength:0];
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
- (instancetype)init {
    if ((self = [super init])) {
        _inlineOnly = YES;
    }
    return self;
}
- (ZTranscoderConfig *)normalizedConfig {
    ZTranscoderConfig *copy = [ZTranscoderConfig new];
    [copy copyTranscodeOptionsFrom:self];
    copy.targetBundlePath = self.targetBundlePath;
    return copy;
}
- (void)copyTranscodeOptionsFrom:(ZTranscoderConfig *)other {
    if (!other) return;
    self.inlineOnly = other.inlineOnly;
    self.transplantSprites = other.transplantSprites;
    self.transplantSpriteAtlases = other.transplantSpriteAtlases;
    self.transplantSpriteRenderers = other.transplantSpriteRenderers;
    self.transplantSpriteMasks = other.transplantSpriteMasks;
    self.transplantTextAssets = other.transplantTextAssets;
    self.transplantAssetBundle = other.transplantAssetBundle;
}
- (BOOL)allowsTransplantOfClass:(int32_t)classID {
    switch (classID) {
        case kZTClassSprite: return self.transplantSprites;
        case kZTClassSpriteAtlas: return self.transplantSpriteAtlases;
        case kZTClassSpriteRenderer: return self.transplantSpriteRenderers;
        case kZTClassSpriteMask: return self.transplantSpriteMasks;
        case kZTClassTextAsset: return self.transplantTextAssets;
        case kZTClassAssetBundle: return self.transplantAssetBundle;
        default: return YES;
    }
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

static ZTSerializedDocument *zt_build_carra2_document(NSArray<ZTCarra2Item *> *items, ZTSerializedDocument *targetDoc, NSError **error) {
    NSMutableDictionary<NSNumber *, ZTSerializedObject *> *targetByPath = [NSMutableDictionary dictionaryWithCapacity:targetDoc.objects.count];
    for (ZTSerializedObject *object in targetDoc.objects) targetByPath[@(object.pathID)] = object;
    NSMutableData *blob = [NSMutableData data];
    NSMutableArray<ZTSerializedObject *> *objects = [NSMutableArray array];
    for (ZTCarra2Item *item in items) {
        ZTSerializedObject *target = targetByPath[@(item.pathID)];
        if (!target) {
            ZLog(@"[ZTranscoder] Carra2 object PathID=%lld (%@) does not exist in the game's bundle; skipping", (long long)item.pathID, item.name);
            continue;
        }
        while (blob.length % 8u) { uint8_t zero = 0; [blob appendBytes:&zero length:1]; }
        ZTSerializedObject *object = [ZTSerializedObject new];
        object.classID = target.classID;
        object.typeIndex = target.typeIndex;
        object.pathID = target.pathID;
        object.byteStart = blob.length;
        object.objectStart = blob.length;
        object.byteSize = (uint32_t)item.data.length;
        [blob appendData:item.data];
        [objects addObject:object];
        ZLog(@"[ZTranscoder] Carra2 object PathID=%lld (%@) maps to class=%d in the game's bundle, %lu bytes", (long long)item.pathID, item.name, target.classID, (unsigned long)item.data.length);
    }
    if (objects.count == 0) {
        if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, @"None of the Carra2 mod's objects exist in the game's bundle.");
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

static BOOL zt_process_bundle_full(NSURL *moddedURL, ZTranscoderConfig *config, NSArray<ZTCarra2Item *> *carra2Items, void (^progress)(double, NSString *), NSURL **outputURL, NSError **error) {
    BOOL carra2Mode = carra2Items != nil;
    if (!config) config = [ZTranscoderConfig new];
    NSString *inputPath = moddedURL.path;
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
            sourceDoc = zt_build_carra2_document(carra2Items, targetDoc, &archiveError);
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
    NSUInteger assetCount = 0;
    BOOL layoutShared = carra2Mode || (sourceDoc.trailer.length > 0 && [sourceDoc.trailer isEqualToData:targetDoc.trailer]);
    ZLog(@"[ZTranscoder] SerializedFile externals/script tables %@ between the mod and the original; %@", layoutShared ? @"match" : @"differ", layoutShared ? @"transplanting every changed object" : @"transplanting only texture/sprite/text classes");
    for (ZTSerializedObject *sourceObject in sourceDoc.objects) {
        BOOL present = zt_find_object(targetObjectMap, sourceObject.pathID, sourceObject.classID) != nil;
        if (zt_class_is_transplantable(sourceObject.classID, layoutShared, config) || (!present && zt_class_is_transplantable(sourceObject.classID, YES, config))) assetCount++;
    }
    NSUInteger processedAssets = 0;
    NSUInteger skippedAssets = 0;
    NSUInteger matchedAssets = 0;
    ZLog(@"[ZTranscoder] extracted %lu source Texture2D/Sprite/SpriteRenderer/SpriteMask/SpriteAtlas/TextAsset/AssetBundle object(s)", (unsigned long)assetCount);
    NSDictionary *sourceTexturesByPath = zt_texture_map(sourceDoc.textures);
    for (ZTSerializedObject *sourceObject in sourceDoc.objects) {
        BOOL presentInTarget = zt_find_object(targetObjectMap, sourceObject.pathID, sourceObject.classID) != nil;
        if (!zt_class_is_transplantable(sourceObject.classID, layoutShared, config) && !(!presentInTarget && zt_class_is_transplantable(sourceObject.classID, YES, config))) continue;
        BOOL legacyClass = zt_class_is_transcoded(sourceObject.classID);
        NSString *sourceTypeKey = (sourceObject.typeIndex >= 0 && (NSUInteger)sourceObject.typeIndex < sourceDoc.typeKeys.count) ? sourceDoc.typeKeys[(NSUInteger)sourceObject.typeIndex] : nil;
        processedAssets++;
        NSString *key = [NSString stringWithFormat:@"%d:%lld", sourceObject.classID, (long long)sourceObject.pathID];
        if (sourceObject.classID == kZTClassTexture2D) {
            ZTTextureRecord *probeTexture = sourceTexturesByPath[[NSString stringWithFormat:@"%lld", (long long)sourceObject.pathID]];
            if (config.inlineOnly && probeTexture && !probeTexture.isInline) {
                skippedAssets++;
                ZLog(@"[ZTranscoder] skipping Texture2D PathID=%lld name=%@: image data is stored in .resS, leaving it untouched", (long long)sourceObject.pathID, probeTexture.name.length ? probeTexture.name : @"<unnamed>");
                if (progress && assetCount) progress(0.1 + 0.7 * ((double)processedAssets / (double)assetCount), [NSString stringWithFormat:@"Compared asset %lu/%lu", (unsigned long)processedAssets, (unsigned long)assetCount]);
                continue;
            }
        }
        ZTSerializedObject *targetObject = zt_find_object(targetObjectMap, sourceObject.pathID, sourceObject.classID);
        BOOL isNewAsset = NO;
        if (!targetObject) {
            NSNumber *newTypeIndex = legacyClass ? targetDoc.classTypeIndex[@(sourceObject.classID)] : (sourceTypeKey ? targetDoc.typeIndexByKey[sourceTypeKey] : nil);
            if (!newTypeIndex) newTypeIndex = zt_inject_type(targetDoc, sourceDoc, sourceObject.typeIndex);
            if (!newTypeIndex) {
                skippedAssets++;
                ZLog(@"[ZTranscoder] skipping class=%d PathID=%lld (%@): its type couldn't be copied into the original bundle", sourceObject.classID, (long long)sourceObject.pathID, key);
                if (progress && assetCount) progress(0.1 + 0.7 * ((double)processedAssets / (double)assetCount), [NSString stringWithFormat:@"Compared asset %lu/%lu", (unsigned long)processedAssets, (unsigned long)assetCount]);
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
            NSData *targetPayload = nil;
            if (!zt_texture_payload(sourceTexture, sourceArchive, sourceDoc.data, &sourcePayload, error) || (!isNewAsset && !zt_texture_payload(targetTexture, targetArchive, targetDoc.data, &targetPayload, error))) {
                [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
                return NO;
            }
            NSString *sourceHash = zt_sha256(sourcePayload);
            NSString *targetHash = zt_sha256(targetPayload);
            NSData *sourceObjectData = zt_object_data(sourceObject, sourceDoc.data);
            NSData *targetObjectData = zt_object_data(targetObject, targetDoc.data);
            NSString *sourceObjectHash = zt_sha256(sourceObjectData);
            NSString *targetObjectHash = zt_sha256(targetObjectData);
            BOOL exact = !isNewAsset && sourceObjectData.length == targetObjectData.length && [sourceObjectHash isEqualToString:targetObjectHash] && [sourceHash isEqualToString:targetHash];
            ZLog(@"[ZTranscoder] Texture2D PathID=%lld name=%@ objectBytes source=%lu target=%lu imageBytes source=%lu target=%lu sourceFormat=%@ targetFormat=%@ sourceMips=%d targetMips=%d imageHash=%@ objectMatch=%@ storage=%@->%@", (long long)sourceObject.pathID, sourceTexture.name.length ? sourceTexture.name : @"<unnamed>", (unsigned long)sourceObjectData.length, (unsigned long)targetObjectData.length, (unsigned long)sourcePayload.length, (unsigned long)targetPayload.length, zt_format_name(sourceTexture.format), zt_format_name(targetTexture.format), sourceTexture.mipCount, targetTexture.mipCount, [sourceHash isEqualToString:targetHash] ? @"YES" : @"NO", exact ? @"YES" : @"NO", sourceTexture.isInline ? @"inline" : @"resS", targetTexture.isInline ? @"inline" : @"resS");
            if (sourceTexture.name.length && targetTexture.name.length && ![sourceTexture.name isEqualToString:targetTexture.name]) ZLog(@"[ZTranscoder] Texture2D PathID=%lld name differs source=%@ target=%@; retaining PathID matching", (long long)sourceObject.pathID, sourceTexture.name, targetTexture.name);
            if (exact) continue;
            if (zt_format_is_transplant_only(sourceTexture.format)) {
                if (!sourceTexture.isInline) {
                    skippedAssets++;
                    ZLog(@"[ZTranscoder] Texture2D PathID=%lld format=%@ is transplant-only and streamed from .resS; leaving it untouched", (long long)sourceObject.pathID, zt_format_name(sourceTexture.format));
                    if (progress && assetCount) progress(0.1 + 0.7 * ((double)processedAssets / (double)assetCount), [NSString stringWithFormat:@"Compared asset %lu/%lu", (unsigned long)processedAssets, (unsigned long)assetCount]);
                    continue;
                }
                if (sourceObjectData) targetObject.replacementObject = sourceObjectData;
                ZLog(@"[ZTranscoder] Texture2D PathID=%lld format=%@ is transplant-only; copied inline object without transcoding (%lu bytes)", (long long)sourceObject.pathID, zt_format_name(sourceTexture.format), (unsigned long)sourceObjectData.length);
                if (progress && assetCount) progress(0.1 + 0.7 * ((double)processedAssets / (double)assetCount), [NSString stringWithFormat:@"Compared asset %lu/%lu", (unsigned long)processedAssets, (unsigned long)assetCount]);
                continue;
            }
            ZTTextureReplacement *replacement = [ZTTextureReplacement new];
            replacement.source = sourceTexture;
            replacement.target = targetTexture;
            replacement.sourceObjectData = zt_object_data(sourceTexture.object, sourceDoc.data);
            NSString *encodedPath = nil;
            uint32_t encodedSize = 0;
            if (!zt_make_astc_replacement(sourceTexture, sourcePayload, workDir, &encodedPath, &encodedSize, error, ^(double f, NSString *stage) {
                if (progress) {
                    double base = assetCount ? ((double)(processedAssets - 1u) / (double)assetCount) : 0.0;
                    double span = assetCount ? (1.0 / (double)assetCount) : 1.0;
                    progress(0.1 + 0.7 * (base + span * f), stage);
                }
            })) {
                [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
                return NO;
            }
            replacement.encodedPath = encodedPath;
            replacement.encodedSize = encodedSize;
            replacements[[NSString stringWithFormat:@"%lld", (long long)targetObject.pathID]] = replacement;
            ZLog(@"[ZTranscoder] Texture2D PathID=%lld transcoded to ASTC 6x6: %lu -> %u bytes", (long long)sourceObject.pathID, (unsigned long)sourcePayload.length, encodedSize);
        } else {
            NSData *sourceObjectData = zt_object_data(sourceObject, sourceDoc.data);
            NSData *targetObjectData = zt_object_data(targetObject, targetDoc.data);
            if (!sourceObjectData || !targetObjectData) {
                if (error) *error = ZTMakeTranscoderError(ZTranscoderServiceErrorCantReadModdedBundle, [NSString stringWithFormat:@"Couldn't extract class=%d PathID=%lld.", sourceObject.classID, (long long)sourceObject.pathID]);
                [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
                return NO;
            }
            NSString *sourceHash = zt_sha256(sourceObjectData);
            NSString *targetHash = zt_sha256(targetObjectData);
            ZLog(@"[ZTranscoder] class=%d PathID=%lld objectBytes source=%lu target=%lu hashMatch=%@", sourceObject.classID, (long long)sourceObject.pathID, (unsigned long)sourceObjectData.length, (unsigned long)targetObjectData.length, [sourceHash isEqualToString:targetHash] ? @"YES" : @"NO");
            if (isNewAsset || sourceObjectData.length != targetObjectData.length || ![sourceHash isEqualToString:targetHash]) targetObject.replacementObject = sourceObjectData;
        }
        if (progress && assetCount) progress(0.1 + 0.7 * ((double)processedAssets / (double)assetCount), [NSString stringWithFormat:@"Compared asset %lu/%lu", (unsigned long)processedAssets, (unsigned long)assetCount]);
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
        if (progress) progress(1.0, @"Local ASTC 6x6 bundle transcode complete");
        if (outputURL) *outputURL = [NSURL fileURLWithPath:finalPath];
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
    if (progress) progress(1.0, @"Local ASTC 6x6 bundle transcode complete");
    if (outputURL) *outputURL = [NSURL fileURLWithPath:inputPath];
    [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
    (void)config;
    return YES;
}

static BOOL zt_process_bundle(NSURL *moddedURL, ZTranscoderConfig *config, void (^progress)(double, NSString *), NSURL **outputURL, NSError **error) {
    return zt_process_bundle_full(moddedURL, config, nil, progress, outputURL, error);
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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
    });
}

+ (void)dispatchBundleAtURL:(NSURL *)moddedBundleURL carra2Hash1:(NSString *)carra2Hash1 carra2Hash2:(NSString *)carra2Hash2 config:(ZTranscoderConfig *)config previousScratchBranch:(NSString *)previousScratchBranch uploadProgress:(void (^)(int64_t, int64_t))uploadProgress completion:(void (^)(ZTranscoderHandle *, NSError *))completion {
    (void)previousScratchBranch;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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
                    [workConfig copyTranscodeOptionsFrom:config];
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
            BOOL ok = zt_process_bundle_full(workURL, workConfig, carra2Items, mainProgress, &output, &error);
            if (!ok || !output) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
                return;
            }
            ZTranscoderHandle *handle = [ZTranscoderHandle new];
            handle.scratchBranch = output.path;
            handle.alreadyComplete = YES;
            handle.compressedByteSize = zt_file_size(output.path);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(handle, nil); });
        }
    });
}

+ (BOOL)isUploadCompressionEnabled { return NO; }
+ (void)setUploadCompressionEnabled:(BOOL)enabled { (void)enabled; }
@end

#pragma mark - ZTranscoderInstaller

NSString * const ZTranscoderInstallerErrorDomain = @"ZTranscoderInstallerErrorDomain";

static NSString * const kBackupSuffix = @".orig-bak";

static NSString * const kManifestFileName = @"manifest.json";

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

    return YES;
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
            continue;
        }

        NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
        if (!backupData) continue;

        NSError *writeError = nil;
        if ([backupData writeToFile:originalPath options:NSDataWritingAtomic error:&writeError]) {
            restored++;
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

    ZLog(@"[ZTranscoderInstaller] cached %@ - live bytes swapped back to the backed-up original", stockBundleURL.lastPathComponent);
    return YES;
}

@end

