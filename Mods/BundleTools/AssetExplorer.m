#import "AssetExplorer.h"
#import "UnityBundleTools.h"
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>
#import <AVFoundation/AVFoundation.h>
#import <compression.h>
#import <unistd.h>
#import <os/proc.h>
#import <sys/stat.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

NSString * const ZSAssetExplorerErrorDomain = @"ZSAssetExplorerErrorDomain";

typedef struct {
    const uint8_t *base;
    size_t size;
    size_t pos;
} ZSAECursor;

typedef struct {
    uint8_t level;
    uint8_t flags;
    uint32_t typeOffset;
    uint32_t nameOffset;
    int32_t byteSize;
    int32_t metaFlags;
} ZSAETypeNode;

typedef struct {
    ZSAETypeNode *nodes;
    uint32_t count;
    const uint8_t *strings;
    uint32_t stringSize;
    int32_t classID;
    NSString *typeName;
    BOOL hasName;
} ZSAETypeTree;

typedef struct {
    uint32_t uncompressedSize;
    uint32_t compressedSize;
    uint16_t flags;
    uint64_t uncompressedOffset;
    uint64_t compressedOffset;
} ZSAEBlock;

typedef struct {
    const uint8_t *base;
    uint64_t start;
    uint64_t limit;
    uint64_t pos;
} ZSAEReader;

@interface ZSAEBundleNode : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) uint64_t offset;
@property (nonatomic, assign) uint64_t size;
@property (nonatomic, assign) uint32_t flags;
@end

@implementation ZSAEBundleNode
@end

@interface ZSAEBundle : NSObject
@property (nonatomic, strong) NSData *fileData;
@property (nonatomic, strong) NSData *blockData;
@property (nonatomic, assign) uint32_t blockCount;
@property (nonatomic, assign) uint64_t uncompressedSize;
@property (nonatomic, strong) NSArray<ZSAEBundleNode *> *nodes;
@property (nonatomic, strong) NSData *residentData;
@property (nonatomic, strong) id residentSession;
@end

@implementation ZSAEBundle
@end

@interface ZSAETextureRecord : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) int32_t width;
@property (nonatomic, assign) int32_t height;
@property (nonatomic, assign) int32_t format;
@property (nonatomic, assign) int32_t mipCount;
@property (nonatomic, assign) uint32_t completeImageSize;
@property (nonatomic, strong) NSData *inlineData;
@property (nonatomic, assign) uint64_t streamOffset;
@property (nonatomic, assign) uint64_t streamSize;
@property (nonatomic, copy) NSString *streamPath;
@end

@implementation ZSAETextureRecord
@end

static NSError *ZSAEError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ZSAssetExplorerErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error."}];
}

static BOOL ZSAENeed(ZSAECursor *cursor, size_t length) {
    return cursor->pos <= cursor->size && length <= cursor->size - cursor->pos;
}

static BOOL ZSAEReadU16BE(ZSAECursor *cursor, uint16_t *out) {
    if (!ZSAENeed(cursor, 2)) return NO;
    *out = (uint16_t)(((uint16_t)cursor->base[cursor->pos] << 8) | cursor->base[cursor->pos + 1]);
    cursor->pos += 2;
    return YES;
}

static BOOL ZSAEReadU32BE(ZSAECursor *cursor, uint32_t *out) {
    if (!ZSAENeed(cursor, 4)) return NO;
    *out = ((uint32_t)cursor->base[cursor->pos] << 24) |
           ((uint32_t)cursor->base[cursor->pos + 1] << 16) |
           ((uint32_t)cursor->base[cursor->pos + 2] << 8) |
           (uint32_t)cursor->base[cursor->pos + 3];
    cursor->pos += 4;
    return YES;
}

static BOOL ZSAEReadU64BE(ZSAECursor *cursor, uint64_t *out) {
    if (!ZSAENeed(cursor, 8)) return NO;
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value = (value << 8) | cursor->base[cursor->pos + i];
    cursor->pos += 8;
    *out = value;
    return YES;
}

static BOOL ZSAESkip(ZSAECursor *cursor, size_t length) {
    if (!ZSAENeed(cursor, length)) return NO;
    cursor->pos += length;
    return YES;
}

static BOOL ZSAEReadCString(ZSAECursor *cursor, NSString **out) {
    size_t start = cursor->pos;
    while (cursor->pos < cursor->size && cursor->base[cursor->pos] != 0) cursor->pos++;
    if (cursor->pos >= cursor->size) return NO;
    NSString *value = [[NSString alloc] initWithBytes:cursor->base + start
                                                 length:cursor->pos - start
                                               encoding:NSUTF8StringEncoding];
    cursor->pos++;
    if (!value) value = [[NSString alloc] initWithBytes:cursor->base + start
                                                  length:cursor->pos - start - 1
                                                encoding:NSASCIIStringEncoding];
    if (!value) return NO;
    if (out) *out = value;
    return YES;
}

static uint32_t ZSAEReadU32LEBytes(const uint8_t *base) {
    return ((uint32_t)base[0]) |
           ((uint32_t)base[1] << 8) |
           ((uint32_t)base[2] << 16) |
           ((uint32_t)base[3] << 24);
}

static uint64_t ZSAEReadU64LEBytes(const uint8_t *base) {
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value |= ((uint64_t)base[i] << (i * 8));
    return value;
}

static uint64_t ZSAEReadU64BEBytes(const uint8_t *base) {
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value = (value << 8) | base[i];
    return value;
}

static int32_t ZSAEReadI32LEBytes(const uint8_t *base) {
    return (int32_t)ZSAEReadU32LEBytes(base);
}

static NSDictionary<NSNumber *, NSString *> *ZSAECommonStrings(void) {
    static NSDictionary<NSNumber *, NSString *> *strings;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        strings = @{
            @0: @"AABB", @5: @"AnimationClip", @19: @"AnimationCurve", @34: @"AnimationState",
            @49: @"Array", @55: @"Base", @60: @"BitField", @69: @"bitset", @76: @"bool",
            @81: @"char", @86: @"ColorRGBA", @96: @"Component", @106: @"data", @111: @"deque",
            @117: @"double", @124: @"dynamic_array", @138: @"FastPropertyName", @155: @"first",
            @161: @"float", @167: @"Font", @172: @"GameObject", @183: @"Generic Mono",
            @196: @"GradientNEW", @208: @"GUID", @213: @"GUIStyle", @222: @"int", @226: @"list",
            @231: @"long long", @241: @"map", @245: @"Matrix4x4f", @256: @"MdFour", @263: @"MonoBehaviour",
            @277: @"MonoScript", @288: @"m_ByteSize", @299: @"m_Curve", @307: @"m_EditorClassIdentifier",
            @331: @"m_EditorHideFlags", @349: @"m_Enabled", @359: @"m_ExtensionPtr", @374: @"m_GameObject",
            @387: @"m_Index", @395: @"m_IsArray", @405: @"m_IsStatic", @416: @"m_MetaFlag", @427: @"m_Name",
            @434: @"m_ObjectHideFlags", @452: @"m_PrefabInternal", @469: @"m_PrefabParentObject", @490: @"m_Script",
            @499: @"m_StaticEditorFlags", @519: @"m_Type", @526: @"m_Version", @536: @"Object", @543: @"pair",
            @548: @"PPtr<Component>", @564: @"PPtr<GameObject>", @581: @"PPtr<Material>", @596: @"PPtr<MonoBehaviour>",
            @616: @"PPtr<MonoScript>", @633: @"PPtr<Object>", @646: @"PPtr<Prefab>", @659: @"PPtr<Sprite>",
            @672: @"PPtr<TextAsset>", @688: @"PPtr<Texture>", @702: @"PPtr<Texture2D>", @718: @"PPtr<Transform>",
            @734: @"Prefab", @741: @"Quaternionf", @753: @"Rectf", @759: @"RectInt", @767: @"RectOffset",
            @778: @"second", @785: @"set", @789: @"short", @795: @"size", @800: @"SInt16", @807: @"SInt32",
            @814: @"SInt64", @821: @"SInt8", @827: @"staticvector", @840: @"string", @847: @"TextAsset",
            @857: @"TextMesh", @866: @"Texture", @874: @"Texture2D", @884: @"Transform", @894: @"TypelessData",
            @907: @"UInt16", @914: @"UInt32", @921: @"UInt64", @928: @"UInt8", @934: @"unsigned int",
            @947: @"unsigned long long", @966: @"unsigned short", @981: @"vector", @988: @"Vector2f",
            @997: @"Vector3f", @1006: @"Vector4f", @1015: @"m_ScriptingClassIdentifier", @1042: @"Gradient",
            @1051: @"Type*", @1057: @"int2_storage", @1070: @"int3_storage", @1083: @"BoundsInt",
            @1093: @"m_CorrespondingSourceObject", @1121: @"m_PrefabInstance", @1138: @"m_PrefabAsset",
            @1152: @"FileSize", @1161: @"Hash128", @1169: @"RenderingLayerMask"
        };
    });
    return strings;
}

static NSString *ZSAEStringFromOffset(const uint8_t *strings, uint32_t stringSize, uint32_t offset) {
    if (offset & 0x80000000u) {
        return ZSAECommonStrings()[@(offset & 0x7FFFFFFFu)];
    }
    if (offset >= stringSize) return nil;
    const uint8_t *start = strings + offset;
    const uint8_t *end = memchr(start, 0, stringSize - offset);
    if (!end) return nil;
    return [[NSString alloc] initWithBytes:start length:(NSUInteger)(end - start) encoding:NSUTF8StringEncoding];
}

static uint32_t ZSAESubtreeEnd(const ZSAETypeTree *tree, uint32_t index) {
    if (!tree || index >= tree->count) return index;
    uint32_t level = tree->nodes[index].level;
    uint32_t end = index + 1;
    while (end < tree->count && tree->nodes[end].level > level) end++;
    return end;
}

static uint64_t ZSAEAlign4(uint64_t position, uint64_t start) {
    return start + (((position - start) + 3) & ~3ULL);
}

static BOOL ZSAEReaderCanRead(const ZSAEReader *reader, uint64_t size) {
    return reader->pos <= reader->limit && size <= reader->limit - reader->pos;
}

static BOOL ZSAEReadU32LE(ZSAEReader *reader, uint32_t *out) {
    if (!ZSAEReaderCanRead(reader, 4)) return NO;
    *out = ZSAEReadU32LEBytes(reader->base + reader->pos);
    reader->pos += 4;
    return YES;
}

static BOOL ZSAEReadStringValue(ZSAEReader *reader, NSString **out) {
    uint32_t length = 0;
    if (!ZSAEReadU32LE(reader, &length)) return NO;
    if (!ZSAEReaderCanRead(reader, length)) return NO;
    const uint8_t *bytes = reader->base + reader->pos;
    NSString *value = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (!value) value = [[NSString alloc] initWithBytes:bytes length:length encoding:NSWindowsCP1252StringEncoding];
    reader->pos += length;
    uint64_t aligned = ZSAEAlign4(reader->pos, reader->start);
    reader->pos = aligned > reader->limit ? reader->limit : aligned;
    if (out) *out = value;
    return YES;
}

static BOOL ZSAEWalkNode(const ZSAETypeTree *tree, ZSAEReader *reader, uint32_t index, NSString **foundName, NSUInteger *budget, NSUInteger depth) {
    if (!tree || index >= tree->count || !reader || !budget || depth > 48 || *budget == 0) return NO;
    (*budget)--;

    const ZSAETypeNode *node = &tree->nodes[index];
    uint32_t end = ZSAESubtreeEnd(tree, index);
    NSString *nodeType = ZSAEStringFromOffset(tree->strings, tree->stringSize, node->typeOffset);
    NSString *nodeName = ZSAEStringFromOffset(tree->strings, tree->stringSize, node->nameOffset);

    if ([nodeType isEqualToString:@"string"]) {
        NSString *value = nil;
        if (!ZSAEReadStringValue(reader, &value)) return NO;
        if ([nodeName isEqualToString:@"m_Name"] && value.length > 0 && *foundName == nil) *foundName = value;
        if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
        return reader->pos <= reader->limit;
    }

    if (node->flags & 1) {
        uint32_t count = 0;
        if (!ZSAEReadU32LE(reader, &count)) return NO;
        uint32_t elementIndex = index + 2;
        if (elementIndex >= end) return NO;
        uint32_t elementEnd = ZSAESubtreeEnd(tree, elementIndex);
        if (elementEnd == elementIndex + 1 && tree->nodes[elementIndex].byteSize > 0) {
            uint64_t bytes = (uint64_t)count * (uint64_t)tree->nodes[elementIndex].byteSize;
            if (!ZSAEReaderCanRead(reader, bytes)) return NO;
            reader->pos += bytes;
        } else {
            if (count > 2000000) return NO;
            for (uint32_t i = 0; i < count; i++) {
                if (!ZSAEWalkNode(tree, reader, elementIndex, foundName, budget, depth + 1)) return NO;
                if (*foundName) return YES;
            }
        }
        if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
        return reader->pos <= reader->limit;
    }

    if (end > index + 1) {
        uint32_t child = index + 1;
        while (child < end) {
            if (!ZSAEWalkNode(tree, reader, child, foundName, budget, depth + 1)) return NO;
            if (*foundName) return YES;
            child = ZSAESubtreeEnd(tree, child);
        }
        if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
        return reader->pos <= reader->limit;
    }

    if (node->byteSize < 0) return NO;
    if (!ZSAEReaderCanRead(reader, (uint64_t)node->byteSize)) return NO;
    reader->pos += (uint64_t)node->byteSize;
    if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
    return reader->pos <= reader->limit;
}

static BOOL ZSAESkipNode(const ZSAETypeTree *tree, ZSAEReader *reader, uint32_t index, NSUInteger *budget, NSUInteger depth) {
    if (!tree || index >= tree->count || !reader || !budget || depth > 48 || *budget == 0) return NO;
    (*budget)--;

    const ZSAETypeNode *node = &tree->nodes[index];
    uint32_t end = ZSAESubtreeEnd(tree, index);
    NSString *nodeType = ZSAEStringFromOffset(tree->strings, tree->stringSize, node->typeOffset);

    if ([nodeType isEqualToString:@"string"]) {
        if (!ZSAEReadStringValue(reader, NULL)) return NO;
        if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
        return reader->pos <= reader->limit;
    }

    if ([nodeType isEqualToString:@"TypelessData"]) {
        uint32_t size = 0;
        if (!ZSAEReadU32LE(reader, &size)) return NO;
        if (!ZSAEReaderCanRead(reader, size)) return NO;
        reader->pos += size;
        if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
        return reader->pos <= reader->limit;
    }

    if (node->flags & 1) {
        uint32_t count = 0;
        if (!ZSAEReadU32LE(reader, &count)) return NO;
        uint32_t elementIndex = index + 2;
        if (elementIndex >= end) return NO;
        uint32_t elementEnd = ZSAESubtreeEnd(tree, elementIndex);
        if (elementEnd == elementIndex + 1 && tree->nodes[elementIndex].byteSize > 0) {
            uint64_t bytes = (uint64_t)count * (uint64_t)tree->nodes[elementIndex].byteSize;
            if (!ZSAEReaderCanRead(reader, bytes)) return NO;
            reader->pos += bytes;
        } else {
            if (count > 2000000) return NO;
            for (uint32_t i = 0; i < count; i++) {
                if (!ZSAESkipNode(tree, reader, elementIndex, budget, depth + 1)) return NO;
            }
        }
        if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
        return reader->pos <= reader->limit;
    }

    if (end > index + 1) {
        uint32_t child = index + 1;
        while (child < end) {
            if (!ZSAESkipNode(tree, reader, child, budget, depth + 1)) return NO;
            child = ZSAESubtreeEnd(tree, child);
        }
        if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
        return reader->pos <= reader->limit;
    }

    if (node->byteSize < 0) return NO;
    if (!ZSAEReaderCanRead(reader, (uint64_t)node->byteSize)) return NO;
    reader->pos += (uint64_t)node->byteSize;
    if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
    return reader->pos <= reader->limit;
}

static BOOL ZSAEReadScalar(ZSAEReader *reader, const ZSAETypeNode *node, uint64_t *out) {
    int32_t size = node->byteSize;
    if (size != 1 && size != 2 && size != 4 && size != 8) return NO;
    if (!ZSAEReaderCanRead(reader, (uint64_t)size)) return NO;
    uint64_t value = 0;
    for (int32_t i = 0; i < size; i++) value |= ((uint64_t)reader->base[reader->pos + (uint64_t)i]) << (8 * i);
    reader->pos += (uint64_t)size;
    if (node->metaFlags & 0x4000) reader->pos = ZSAEAlign4(reader->pos, reader->start);
    if (out) *out = value;
    return reader->pos <= reader->limit;
}

static BOOL ZSAEExtractTexture(const ZSAETypeTree *tree, const uint8_t *bytes, uint64_t objectStart, uint64_t objectEnd, ZSAETextureRecord *record) {
    ZSAEReader reader = { bytes, objectStart, objectEnd, objectStart };
    NSUInteger budget = 4000000;
    uint32_t rootEnd = ZSAESubtreeEnd(tree, 0);
    uint32_t child = 1;
    while (child < rootEnd) {
        const ZSAETypeNode *node = &tree->nodes[child];
        uint32_t childEnd = ZSAESubtreeEnd(tree, child);
        NSString *name = ZSAEStringFromOffset(tree->strings, tree->stringSize, node->nameOffset);
        NSString *type = ZSAEStringFromOffset(tree->strings, tree->stringSize, node->typeOffset);
        BOOL scalar = childEnd == child + 1 && !(node->flags & 1) && node->byteSize > 0;

        if ([type isEqualToString:@"string"]) {
            NSString *value = nil;
            if (!ZSAEReadStringValue(&reader, &value)) return NO;
            if (node->metaFlags & 0x4000) reader.pos = ZSAEAlign4(reader.pos, reader.start);
            if ([name isEqualToString:@"m_Name"] && value.length > 0) record.name = value;
        } else if ([type isEqualToString:@"TypelessData"]) {
            uint32_t size = 0;
            if (!ZSAEReadU32LE(&reader, &size) || !ZSAEReaderCanRead(&reader, size)) return NO;
            if ([name isEqualToString:@"image data"] && size > 0) {
                record.inlineData = [NSData dataWithBytes:bytes + reader.pos length:size];
            }
            reader.pos += size;
            if (node->metaFlags & 0x4000) reader.pos = ZSAEAlign4(reader.pos, reader.start);
            if (reader.pos > reader.limit) return NO;
        } else if ([name isEqualToString:@"m_StreamData"] && childEnd > child + 1) {
            uint32_t sub = child + 1;
            while (sub < childEnd) {
                const ZSAETypeNode *subNode = &tree->nodes[sub];
                uint32_t subEnd = ZSAESubtreeEnd(tree, sub);
                NSString *subName = ZSAEStringFromOffset(tree->strings, tree->stringSize, subNode->nameOffset);
                NSString *subType = ZSAEStringFromOffset(tree->strings, tree->stringSize, subNode->typeOffset);
                if ([subType isEqualToString:@"string"]) {
                    NSString *value = nil;
                    if (!ZSAEReadStringValue(&reader, &value)) return NO;
                    if (subNode->metaFlags & 0x4000) reader.pos = ZSAEAlign4(reader.pos, reader.start);
                    if ([subName isEqualToString:@"path"]) record.streamPath = value;
                } else if (subEnd == sub + 1 && !(subNode->flags & 1) && subNode->byteSize > 0) {
                    uint64_t value = 0;
                    if (!ZSAEReadScalar(&reader, subNode, &value)) return NO;
                    if ([subName isEqualToString:@"offset"]) record.streamOffset = value;
                    else if ([subName isEqualToString:@"size"]) record.streamSize = value;
                } else if (!ZSAESkipNode(tree, &reader, sub, &budget, 1)) {
                    return NO;
                }
                sub = subEnd;
            }
        } else if (scalar) {
            uint64_t value = 0;
            if (!ZSAEReadScalar(&reader, node, &value)) return NO;
            if ([name isEqualToString:@"m_Width"]) record.width = (int32_t)value;
            else if ([name isEqualToString:@"m_Height"]) record.height = (int32_t)value;
            else if ([name isEqualToString:@"m_CompleteImageSize"]) record.completeImageSize = (uint32_t)value;
            else if ([name isEqualToString:@"m_TextureFormat"]) record.format = (int32_t)value;
            else if ([name isEqualToString:@"m_MipCount"]) record.mipCount = (int32_t)value;
        } else if (!ZSAESkipNode(tree, &reader, child, &budget, 0)) {
            return NO;
        }
        child = childEnd;
    }
    return YES;
}

static BOOL ZSAEReadFileNodeData(NSData *fileData, uint64_t nodeOffset, uint64_t nodeSize,
                                 const ZSAEBlock *blocks, uint32_t blockCount,
                                 NSString **outPath, NSError **error) {
    if (nodeSize == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"Serialized CAB node is empty.");
        return NO;
    }

    NSString *tempName = [NSString stringWithFormat:@"ZSAssetExplorer-%@", NSUUID.UUID.UUIDString];
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempName];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createFileAtPath:tempPath contents:nil attributes:nil]) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't create temporary bundle storage.");
        return NO;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:tempPath];
    if (!handle) {
        [fm removeItemAtPath:tempPath error:nil];
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't open temporary bundle storage.");
        return NO;
    }

    BOOL ok = YES;
    uint64_t nodeEnd = nodeOffset + nodeSize;
    if (nodeEnd < nodeOffset) ok = NO;

    const uint8_t *fileBytes = fileData.bytes;
    for (uint32_t i = 0; ok && i < blockCount; i++) {
        const ZSAEBlock *block = &blocks[i];
        uint64_t blockEnd = block->uncompressedOffset + block->uncompressedSize;
        if (blockEnd <= nodeOffset || block->uncompressedOffset >= nodeEnd) continue;
        if (block->compressedOffset > fileData.length || block->compressedSize > fileData.length - block->compressedOffset) {
            ok = NO;
            break;
        }

        NSMutableData *decompressed = [NSMutableData dataWithLength:block->uncompressedSize];
        if (!decompressed) {
            ok = NO;
            break;
        }

        const uint8_t *src = fileBytes + block->compressedOffset;
        uint8_t *dst = decompressed.mutableBytes;
        uint8_t compression = (uint8_t)(block->flags & 0x3F);
        if (compression == UnityBundleCABCompressionNone) {
            if (block->compressedSize != block->uncompressedSize) {
                ok = NO;
                break;
            }
            memcpy(dst, src, block->uncompressedSize);
        } else if (compression == UnityBundleCABCompressionLZ4 || compression == UnityBundleCABCompressionLZ4HC) {
            int written = LZ4BlockDecompress(src, block->compressedSize, dst, block->uncompressedSize);
            if (written < 0 || (uint32_t)written != block->uncompressedSize) {
                ok = NO;
                break;
            }
        } else {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorUnsupportedCompression, @"This bundle uses a compression type the Asset Explorer cannot decode.");
            ok = NO;
            break;
        }

        uint64_t copyStart = MAX(nodeOffset, block->uncompressedOffset);
        uint64_t copyEnd = MIN(nodeEnd, blockEnd);
        NSUInteger localStart = (NSUInteger)(copyStart - block->uncompressedOffset);
        NSUInteger localLength = (NSUInteger)(copyEnd - copyStart);
        NSData *chunk = [NSData dataWithBytes:dst + localStart length:localLength];
        @try {
            [handle writeData:chunk];
        } @catch (__unused NSException *exception) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't write temporary serialized file data.");
            ok = NO;
        }
    }

    @try {
        [handle closeFile];
    } @catch (__unused NSException *exception) {
    }

    if (!ok) {
        [fm removeItemAtPath:tempPath error:nil];
        if (error && !*error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"Couldn't reconstruct the serialized file from the bundle.");
        return NO;
    }

    NSDictionary *attributes = [fm attributesOfItemAtPath:tempPath error:nil];
    NSNumber *size = attributes[NSFileSize];
    if (!size || size.unsignedLongLongValue != nodeSize) {
        [fm removeItemAtPath:tempPath error:nil];
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The reconstructed serialized file has an unexpected size.");
        return NO;
    }

    if (outPath) *outPath = tempPath;
    return YES;
}

static NSMutableDictionary<NSString *, ZSAEBundle *> *ZSAEResidentBundles(void) {
    static NSMutableDictionary<NSString *, ZSAEBundle *> *bundles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundles = [NSMutableDictionary dictionary];
    });
    return bundles;
}

static ZSAEBundle *ZSAEResidentBundleForPath(NSString *path) {
    if (path.length == 0) return nil;
    NSMutableDictionary<NSString *, ZSAEBundle *> *bundles = ZSAEResidentBundles();
    @synchronized (bundles) {
        return bundles[path];
    }
}

static NSData *ZSAEResidentNodeData(ZSAEBundle *bundle, ZSAEBundleNode *node) {
    NSData *resident = bundle.residentData;
    if (!resident || !node || node.size == 0) return nil;
    if (node.offset > resident.length || node.size > resident.length - node.offset) return nil;
    return [NSData dataWithBytesNoCopy:(void *)((const uint8_t *)resident.bytes + node.offset) length:(NSUInteger)node.size freeWhenDone:NO];
}

static BOOL ZSAEOpenBundle(NSString *path, ZSAEBundle **outBundle, NSError **error) {
    ZSAEBundle *residentBundle = ZSAEResidentBundleForPath(path);
    if (residentBundle) {
        if (outBundle) *outBundle = residentBundle;
        return YES;
    }

    NSError *readError = nil;
    NSData *fileData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&readError];
    if (!fileData) {
        if (error) *error = readError ?: ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't read the bundle.");
        return NO;
    }

    if (fileData.length < 32 || memcmp(fileData.bytes, "UnityFS\0", 8) != 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The file is not a UnityFS AssetBundle.");
        return NO;
    }

    ZSAECursor cursor = { fileData.bytes, fileData.length, 8 };
    uint32_t formatVersion = 0;
    NSString *unityVersion = nil;
    NSString *unityRevision = nil;
    uint64_t archiveSize = 0;
    uint32_t compressedInfoSize = 0;
    uint32_t uncompressedInfoSize = 0;
    uint32_t flags = 0;
    if (!ZSAEReadU32BE(&cursor, &formatVersion) ||
        !ZSAEReadCString(&cursor, &unityVersion) ||
        !ZSAEReadCString(&cursor, &unityRevision) ||
        !ZSAEReadU64BE(&cursor, &archiveSize) ||
        !ZSAEReadU32BE(&cursor, &compressedInfoSize) ||
        !ZSAEReadU32BE(&cursor, &uncompressedInfoSize) ||
        !ZSAEReadU32BE(&cursor, &flags)) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS header is truncated.");
        return NO;
    }
    if (formatVersion != 6 && formatVersion != 7 && formatVersion != 8) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorUnsupportedSerializedFile, [NSString stringWithFormat:@"UnityFS format version %u is not supported.", formatVersion]);
        return NO;
    }
    (void)unityVersion;
    (void)unityRevision;
    (void)archiveSize;

    BOOL infoAtEnd = (flags & 0x80) != 0;
    uint64_t headerEnd = ((uint64_t)cursor.pos + 15) & ~15ULL;
    if (headerEnd > fileData.length) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS header is truncated.");
        return NO;
    }
    if (compressedInfoSize > fileData.length) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS blocks-info range is invalid.");
        return NO;
    }
    uint64_t infoStart = infoAtEnd ? fileData.length - compressedInfoSize : headerEnd;
    if (infoStart > fileData.length || compressedInfoSize > fileData.length - infoStart) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS blocks-info range is invalid.");
        return NO;
    }

    NSData *blocksInfo = nil;
    const uint8_t *infoBytes = (const uint8_t *)fileData.bytes + infoStart;
    uint8_t infoCompression = (uint8_t)(flags & 0x3F);
    if (infoCompression == UnityBundleCABCompressionNone) {
        if (compressedInfoSize != uncompressedInfoSize) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The uncompressed blocks-info size does not match its stored size.");
            return NO;
        }
        blocksInfo = [NSData dataWithBytes:infoBytes length:compressedInfoSize];
    } else if (infoCompression == UnityBundleCABCompressionLZ4 || infoCompression == UnityBundleCABCompressionLZ4HC) {
        NSMutableData *expanded = [NSMutableData dataWithLength:uncompressedInfoSize];
        if (!expanded) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"Couldn't allocate UnityFS blocks-info storage.");
            return NO;
        }
        int written = LZ4BlockDecompress(infoBytes, compressedInfoSize, expanded.mutableBytes, uncompressedInfoSize);
        if (written < 0 || (uint32_t)written != uncompressedInfoSize) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"Couldn't decompress the UnityFS blocks-info.");
            return NO;
        }
        blocksInfo = expanded;
    } else {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorUnsupportedCompression, @"The Asset Explorer only supports uncompressed and LZ4/LZ4HC UnityFS blocks.");
        return NO;
    }

    ZSAECursor infoCursor = { blocksInfo.bytes, blocksInfo.length, 0 };
    if (!ZSAESkip(&infoCursor, 16)) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS blocks-info hash is truncated.");
        return NO;
    }

    uint32_t blockCount = 0;
    if (!ZSAEReadU32BE(&infoCursor, &blockCount) || blockCount > 200000) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS block table is invalid.");
        return NO;
    }
    NSMutableData *blockData = [NSMutableData dataWithLength:(NSUInteger)blockCount * sizeof(ZSAEBlock)];
    ZSAEBlock *blocks = blockData.mutableBytes;

    uint64_t uncompressedOffset = 0;
    BOOL ok = YES;
    for (uint32_t i = 0; i < blockCount; i++) {
        uint32_t uncompressedSize = 0;
        uint32_t compressedSize = 0;
        uint16_t blockFlags = 0;
        if (!ZSAEReadU32BE(&infoCursor, &uncompressedSize) ||
            !ZSAEReadU32BE(&infoCursor, &compressedSize) ||
            !ZSAEReadU16BE(&infoCursor, &blockFlags)) {
            ok = NO;
            break;
        }
        blocks[i].uncompressedSize = uncompressedSize;
        blocks[i].compressedSize = compressedSize;
        blocks[i].flags = blockFlags;
        blocks[i].uncompressedOffset = uncompressedOffset;
        if (UINT64_MAX - uncompressedOffset < uncompressedSize) {
            ok = NO;
            break;
        }
        uncompressedOffset += uncompressedSize;
    }
    if (!ok) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS block table is truncated or overflows.");
        return NO;
    }

    uint32_t nodeCount = 0;
    if (!ZSAEReadU32BE(&infoCursor, &nodeCount) || nodeCount > 4096) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS node table is invalid.");
        return NO;
    }

    NSMutableArray<ZSAEBundleNode *> *nodes = [NSMutableArray arrayWithCapacity:nodeCount];
    for (uint32_t i = 0; i < nodeCount; i++) {
        uint64_t nodeOffset = 0;
        uint64_t nodeSize = 0;
        uint32_t nodeFlags = 0;
        NSString *nodePath = nil;
        if (!ZSAEReadU64BE(&infoCursor, &nodeOffset) ||
            !ZSAEReadU64BE(&infoCursor, &nodeSize) ||
            !ZSAEReadU32BE(&infoCursor, &nodeFlags) ||
            !ZSAEReadCString(&infoCursor, &nodePath)) {
            ok = NO;
            break;
        }
        if (nodeOffset > uncompressedOffset || nodeSize > uncompressedOffset - nodeOffset) {
            ok = NO;
            break;
        }
        ZSAEBundleNode *node = [ZSAEBundleNode new];
        node.path = nodePath ?: @"";
        node.offset = nodeOffset;
        node.size = nodeSize;
        node.flags = nodeFlags;
        [nodes addObject:node];
    }
    if (!ok) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS node table is invalid.");
        return NO;
    }

    uint64_t dataStart = infoAtEnd ? headerEnd : headerEnd + compressedInfoSize;
    if (!infoAtEnd && (flags & 0x200) != 0) dataStart = (dataStart + 15) & ~15ULL;
    if (dataStart < headerEnd || dataStart > fileData.length) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS data start is outside the file.");
        return NO;
    }
    uint64_t compressedOffset = dataStart;
    for (uint32_t i = 0; i < blockCount; i++) {
        blocks[i].compressedOffset = compressedOffset;
        if (UINT64_MAX - compressedOffset < blocks[i].compressedSize) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS compressed block table overflows.");
            return NO;
        }
        compressedOffset += blocks[i].compressedSize;
    }
    if (compressedOffset > fileData.length) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS data blocks run past the end of the file.");
        return NO;
    }

    ZSAEBundle *bundle = [ZSAEBundle new];
    bundle.fileData = fileData;
    bundle.blockData = blockData;
    bundle.blockCount = blockCount;
    bundle.uncompressedSize = uncompressedOffset;
    bundle.nodes = nodes;
    if (outBundle) *outBundle = bundle;
    return YES;
}

static ZSAEBundleNode *ZSAEFindSerializedNode(ZSAEBundle *bundle) {
    for (ZSAEBundleNode *node in bundle.nodes) {
        if ((node.flags & 4) != 0 && [node.path hasPrefix:@"CAB-"]) return node;
    }
    return nil;
}

static BOOL ZSAEDecodeBlock(NSData *fileData, const ZSAEBlock *block, uint8_t *dst, NSError **error) {
    if (block->compressedOffset > fileData.length || block->compressedSize > fileData.length - block->compressedOffset) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"A UnityFS data block lies outside the file.");
        return NO;
    }
    const uint8_t *src = (const uint8_t *)fileData.bytes + block->compressedOffset;
    uint8_t compression = (uint8_t)(block->flags & 0x3F);
    if (compression == UnityBundleCABCompressionNone) {
        if (block->compressedSize != block->uncompressedSize) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"A stored UnityFS block has mismatched sizes.");
            return NO;
        }
        memcpy(dst, src, block->uncompressedSize);
        return YES;
    }
    if (compression == UnityBundleCABCompressionLZ4 || compression == UnityBundleCABCompressionLZ4HC) {
        int written = LZ4BlockDecompress(src, block->compressedSize, dst, block->uncompressedSize);
        if (written < 0 || (uint32_t)written != block->uncompressedSize) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"A UnityFS data block failed to decompress.");
            return NO;
        }
        return YES;
    }
    if (error) *error = ZSAEError(ZSAssetExplorerErrorUnsupportedCompression, @"This bundle uses a compression type the Asset Explorer cannot decode.");
    return NO;
}

static NSData *ZSAEReadBundleRange(ZSAEBundle *bundle, uint64_t start, uint64_t length, NSError **error) {
    uint64_t end = start + length;
    if (length == 0 || length > (1ULL << 31) || end < start || end > bundle.uncompressedSize) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The texture's stream range lies outside the bundle.");
        return nil;
    }

    NSData *resident = bundle.residentData;
    if (resident && end <= resident.length) {
        return [resident subdataWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)length)];
    }

    NSMutableData *result = [NSMutableData dataWithLength:(NSUInteger)length];
    if (!result) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't allocate memory for the texture data.");
        return nil;
    }
    uint8_t *out = result.mutableBytes;
    const ZSAEBlock *blocks = bundle.blockData.bytes;

    for (uint32_t i = 0; i < bundle.blockCount; i++) {
        const ZSAEBlock *block = &blocks[i];
        uint64_t blockEnd = block->uncompressedOffset + block->uncompressedSize;
        if (blockEnd <= start || block->uncompressedOffset >= end) continue;

        NSMutableData *decompressed = [NSMutableData dataWithLength:block->uncompressedSize];
        if (!decompressed || !ZSAEDecodeBlock(bundle.fileData, block, decompressed.mutableBytes, error)) {
            if (error && !*error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"Couldn't read the texture's stream data.");
            return nil;
        }

        uint64_t copyStart = MAX(start, block->uncompressedOffset);
        uint64_t copyEnd = MIN(end, blockEnd);
        memcpy(out + (copyStart - start),
               (const uint8_t *)decompressed.bytes + (copyStart - block->uncompressedOffset),
               (size_t)(copyEnd - copyStart));
    }
    return result;
}

static BOOL ZSAEParseUnityFSForSerializedPath(NSString *path, NSString **outSerializedPath, NSString **outCAB, NSError **error) {
    ZSAEBundle *bundle = nil;
    if (!ZSAEOpenBundle(path, &bundle, error)) return NO;

    ZSAEBundleNode *cabNode = ZSAEFindSerializedNode(bundle);
    if (!cabNode) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"No serialized CAB node was found in the bundle.");
        return NO;
    }

    NSString *serializedPath = nil;
    BOOL reconstructed = ZSAEReadFileNodeData(bundle.fileData,
                                               cabNode.offset, cabNode.size,
                                               bundle.blockData.bytes, bundle.blockCount,
                                               &serializedPath, error);
    if (!reconstructed || serializedPath.length == 0) return NO;
    if (outSerializedPath) *outSerializedPath = serializedPath;
    if (outCAB) *outCAB = [cabNode.path copy];
    return YES;
}

static BOOL ZSAETypeIsSigned(NSString *type) {
    return [type isEqualToString:@"int"] || [type isEqualToString:@"SInt8"] || [type isEqualToString:@"SInt16"] ||
           [type isEqualToString:@"SInt32"] || [type isEqualToString:@"SInt64"] || [type isEqualToString:@"short"] ||
           [type isEqualToString:@"long long"] || [type isEqualToString:@"char"];
}

static id ZSAEReadValue(const ZSAETypeTree *tree, ZSAEReader *reader, uint32_t index, NSUInteger *budget, NSUInteger depth) {
    if (!tree || index >= tree->count || !reader || !budget || depth > 48 || *budget == 0) return nil;
    (*budget)--;

    const ZSAETypeNode *node = &tree->nodes[index];
    uint32_t end = ZSAESubtreeEnd(tree, index);
    NSString *nodeType = ZSAEStringFromOffset(tree->strings, tree->stringSize, node->typeOffset);
    BOOL align = (node->metaFlags & 0x4000) != 0;
    id result = nil;

    if ([nodeType isEqualToString:@"string"]) {
        NSString *value = nil;
        if (!ZSAEReadStringValue(reader, &value)) return nil;
        result = value ?: @"";
    } else if ([nodeType isEqualToString:@"TypelessData"]) {
        uint32_t size = 0;
        if (!ZSAEReadU32LE(reader, &size) || !ZSAEReaderCanRead(reader, size)) return nil;
        result = [NSData dataWithBytes:reader->base + reader->pos length:size];
        reader->pos += size;
    } else if (node->flags & 1) {
        uint32_t count = 0;
        if (!ZSAEReadU32LE(reader, &count)) return nil;
        uint32_t elementIndex = index + 2;
        if (elementIndex >= end) return nil;
        uint32_t elementEnd = ZSAESubtreeEnd(tree, elementIndex);
        if (elementEnd == elementIndex + 1 && tree->nodes[elementIndex].byteSize > 0) {
            uint64_t bytes = (uint64_t)count * (uint64_t)tree->nodes[elementIndex].byteSize;
            if (!ZSAEReaderCanRead(reader, bytes)) return nil;
            result = bytes <= (64u << 20) ? [NSData dataWithBytes:reader->base + reader->pos length:(NSUInteger)bytes] : [NSData data];
            reader->pos += bytes;
        } else {
            if (count > 2000000) return nil;
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:MIN((NSUInteger)count, (NSUInteger)4096)];
            for (uint32_t i = 0; i < count; i++) {
                id item = ZSAEReadValue(tree, reader, elementIndex, budget, depth + 1);
                if (!item) return nil;
                [items addObject:item];
            }
            result = items;
        }
    } else if (end > index + 1) {
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        uint32_t child = index + 1;
        while (child < end) {
            NSString *name = ZSAEStringFromOffset(tree->strings, tree->stringSize, tree->nodes[child].nameOffset);
            id value = ZSAEReadValue(tree, reader, child, budget, depth + 1);
            if (!value) return nil;
            if (name.length > 0 && !fields[name]) fields[name] = value;
            child = ZSAESubtreeEnd(tree, child);
        }
        result = (fields.count == 1 && fields[@"Array"]) ? fields[@"Array"] : fields;
    } else {
        int32_t size = node->byteSize;
        if (size < 0 || !ZSAEReaderCanRead(reader, (uint64_t)size)) return nil;
        const uint8_t *raw = reader->base + reader->pos;
        if (size == 0) {
            result = @0;
        } else if ([nodeType isEqualToString:@"float"] && size == 4) {
            float number = 0;
            memcpy(&number, raw, 4);
            result = @(number);
        } else if ([nodeType isEqualToString:@"double"] && size == 8) {
            double number = 0;
            memcpy(&number, raw, 8);
            result = @(number);
        } else if (size <= 8) {
            uint64_t value = 0;
            for (int32_t i = 0; i < size; i++) value |= ((uint64_t)raw[i]) << (8 * i);
            if (ZSAETypeIsSigned(nodeType)) {
                int shift = 64 - 8 * size;
                result = @((int64_t)(value << shift) >> shift);
            } else {
                result = @(value);
            }
        } else {
            result = [NSData dataWithBytes:raw length:(NSUInteger)size];
        }
        reader->pos += (uint64_t)size;
    }

    if (align) {
        uint64_t aligned = ZSAEAlign4(reader->pos, reader->start);
        reader->pos = aligned > reader->limit ? reader->limit : aligned;
    }
    return reader->pos <= reader->limit ? result : nil;
}

static __thread uint64_t gZSAELastObjectStart;
static __thread uint64_t gZSAELastObjectSize;

static BOOL ZSAEParseSerializedFile(NSData *data, NSArray<ZSAssetExplorerAsset *> **outAssets, int64_t wantedPathID, ZSAETextureRecord **outRecord, NSDictionary **outObject, int32_t *outObjectClassID, NSArray<NSString *> **outExternals, NSError **error) {
    const uint8_t *bytes = data.bytes;
    size_t length = data.length;
    if (!bytes || length < 48) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"The serialized file is too small.");
        return NO;
    }

    uint32_t version = ((uint32_t)bytes[8] << 24) | ((uint32_t)bytes[9] << 16) | ((uint32_t)bytes[10] << 8) | bytes[11];
    if (version < 22) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorUnsupportedSerializedFile, [NSString stringWithFormat:@"Serialized file version %u is not supported.", version]);
        return NO;
    }
    uint8_t endianness = bytes[16];
    if (endianness != 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorUnsupportedSerializedFile, @"Big-endian serialized files are not supported.");
        return NO;
    }

    uint64_t dataOffset = 0;
    for (int i = 0; i < 8; i++) dataOffset = (dataOffset << 8) | bytes[32 + i];
    if (dataOffset > length) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"The serialized data offset is outside the file.");
        return NO;
    }

    size_t pos = 48;
    while (pos < length && bytes[pos] != 0) pos++;
    if (pos >= length) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"The serialized file metadata is truncated.");
        return NO;
    }
    pos++;
    if (length - pos < 9) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"The serialized file metadata is truncated.");
        return NO;
    }
    pos += 4;
    uint8_t enableTypeTree = bytes[pos++];
    if (!enableTypeTree) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorUnsupportedSerializedFile, @"This serialized file has no embedded TypeTrees.");
        return NO;
    }

    int32_t typeCount = ZSAEReadI32LEBytes(bytes + pos);
    pos += 4;
    if (typeCount <= 0 || typeCount > 4096) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"The serialized type table is invalid.");
        return NO;
    }

    ZSAETypeTree *types = calloc((size_t)typeCount, sizeof(ZSAETypeTree));
    if (!types) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"Couldn't allocate the serialized type table.");
        return NO;
    }

    BOOL parseOK = YES;
    for (int32_t i = 0; i < typeCount; i++) {
        if (length - pos < 7) { parseOK = NO; break; }
        int32_t classID = ZSAEReadI32LEBytes(bytes + pos);
        pos += 4;
        pos += 3;
        if (classID == 114) {
            if (length - pos < 16) { parseOK = NO; break; }
            pos += 16;
        }
        if (length - pos < 16) { parseOK = NO; break; }
        pos += 16;
        if (length - pos < 8) { parseOK = NO; break; }
        uint32_t nodeCount = ZSAEReadU32LEBytes(bytes + pos);
        uint32_t stringSize = ZSAEReadU32LEBytes(bytes + pos + 4);
        pos += 8;
        if (nodeCount == 0 || nodeCount > 100000 || stringSize > (16u << 20)) { parseOK = NO; break; }
        size_t nodeBytes = (size_t)nodeCount * 32u;
        if (nodeBytes > length - pos || stringSize > length - pos - nodeBytes) { parseOK = NO; break; }

        types[i].nodes = calloc(nodeCount, sizeof(ZSAETypeNode));
        if (!types[i].nodes) { parseOK = NO; break; }
        types[i].count = nodeCount;
        types[i].strings = bytes + pos + nodeBytes;
        types[i].stringSize = stringSize;
        types[i].classID = classID;

        const uint8_t *nodeBytesBase = bytes + pos;
        for (uint32_t n = 0; n < nodeCount; n++) {
            const uint8_t *node = nodeBytesBase + ((size_t)n * 32u);
            types[i].nodes[n].level = node[2];
            types[i].nodes[n].flags = node[3];
            types[i].nodes[n].typeOffset = ZSAEReadU32LEBytes(node + 4);
            types[i].nodes[n].nameOffset = ZSAEReadU32LEBytes(node + 8);
            types[i].nodes[n].byteSize = ZSAEReadI32LEBytes(node + 12);
            types[i].nodes[n].metaFlags = ZSAEReadI32LEBytes(node + 20);
        }

        types[i].typeName = ZSAEStringFromOffset(types[i].strings, stringSize, types[i].nodes[0].typeOffset) ?: [NSString stringWithFormat:@"Class %d", classID];
        for (uint32_t n = 0; n < nodeCount; n++) {
            NSString *name = ZSAEStringFromOffset(types[i].strings, stringSize, types[i].nodes[n].nameOffset);
            if ([name isEqualToString:@"m_Name"]) {
                types[i].hasName = YES;
                break;
            }
        }

        pos += nodeBytes + stringSize;
        if (length - pos < 4) { parseOK = NO; break; }
        int32_t dependencies = ZSAEReadI32LEBytes(bytes + pos);
        pos += 4;
        if (dependencies < 0 || (uint64_t)dependencies * 4 > length - pos) { parseOK = NO; break; }
        pos += (size_t)dependencies * 4u;
    }

    if (!parseOK || length - pos < 4) {
        for (int32_t i = 0; i < typeCount; i++) free(types[i].nodes);
        free(types);
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"The serialized TypeTree metadata is malformed.");
        return NO;
    }

    int32_t objectCount = ZSAEReadI32LEBytes(bytes + pos);
    pos += 4;
    if (objectCount < 0 || objectCount > 4000000) {
        for (int32_t i = 0; i < typeCount; i++) free(types[i].nodes);
        free(types);
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"The serialized object table is invalid.");
        return NO;
    }

    NSMutableArray<ZSAssetExplorerAsset *> *assets = [NSMutableArray arrayWithCapacity:(outRecord || outObject) ? 0 : (NSUInteger)objectCount];
    BOOL textureProblem = NO;
    BOOL objectFound = NO;
    BOOL objectProblem = NO;
    for (int32_t i = 0; i < objectCount; i++) {
        pos = (pos + 3) & ~((size_t)3);
        if (length - pos < 24) {
            parseOK = NO;
            break;
        }
        int64_t pathID = (int64_t)ZSAEReadU64LEBytes(bytes + pos);
        uint64_t byteStart = ZSAEReadU64LEBytes(bytes + pos + 8);
        uint32_t byteSize = ZSAEReadU32LEBytes(bytes + pos + 16);
        int32_t typeIndex = ZSAEReadI32LEBytes(bytes + pos + 20);
        pos += 24;
        if (typeIndex < 0 || typeIndex >= typeCount) continue;

        ZSAETypeTree *tree = &types[typeIndex];
        if (outObject) {
            if (objectFound || pathID != wantedPathID) continue;
            objectFound = YES;
            uint64_t objectStart = dataOffset + byteStart;
            if (byteStart > length - dataOffset || objectStart > length || byteSize > length - objectStart) {
                objectProblem = YES;
                continue;
            }
            gZSAELastObjectStart = objectStart;
            gZSAELastObjectSize = byteSize;
            ZSAEReader objectReader = { bytes, objectStart, objectStart + byteSize, objectStart };
            NSUInteger objectBudget = 4000000;
            id value = ZSAEReadValue(tree, &objectReader, 0, &objectBudget, 0);
            if ([value isKindOfClass:[NSDictionary class]]) {
                *outObject = value;
                if (outObjectClassID) *outObjectClassID = tree->classID;
            } else {
                objectProblem = YES;
            }
            continue;
        }
        if (outRecord) {
            if (pathID != wantedPathID) continue;
            uint64_t objectStart = dataOffset + byteStart;
            if (tree->classID != 28 || byteStart > length - dataOffset || objectStart > length || byteSize > length - objectStart) {
                textureProblem = YES;
                break;
            }
            ZSAETextureRecord *record = [ZSAETextureRecord new];
            if (!ZSAEExtractTexture(tree, bytes, objectStart, objectStart + byteSize, record)) {
                textureProblem = YES;
                break;
            }
            *outRecord = record;
            break;
        }
        ZSAssetExplorerAsset *asset = [ZSAssetExplorerAsset new];
        asset.pathID = pathID;
        asset.classID = tree->classID;
        asset.typeName = tree->typeName ?: [NSString stringWithFormat:@"Class %d", tree->classID];
        asset.objectSize = byteSize;
        asset.byteStart = byteStart;

        if (tree->hasName && byteStart <= length - dataOffset) {
            uint64_t objectStart = dataOffset + byteStart;
            if (objectStart <= length && byteSize <= length - objectStart) {
                ZSAEReader reader = { bytes, objectStart, objectStart + byteSize, objectStart };
                NSUInteger budget = 500000;
                NSString *name = nil;
                ZSAEWalkNode(tree, &reader, 0, &name, &budget, 0);
                if (name.length > 0) asset.assetName = name;
            }
        }

        [assets addObject:asset];
    }

    if (outObject && *outObject && outExternals) {
        NSMutableArray<NSString *> *externals = [NSMutableArray array];
        size_t cursor = pos;
        if (length - cursor >= 4) {
            int32_t scriptCount = ZSAEReadI32LEBytes(bytes + cursor);
            cursor += 4;
            if (scriptCount >= 0 && (uint64_t)scriptCount * 12u <= length - cursor) {
                cursor += (size_t)scriptCount * 12u;
                if (length - cursor >= 4) {
                    int32_t externalCount = ZSAEReadI32LEBytes(bytes + cursor);
                    cursor += 4;
                    for (int32_t e = 0; e < externalCount && e < 4096; e++) {
                        while (cursor < length && bytes[cursor] != 0) cursor++;
                        if (cursor >= length) break;
                        cursor++;
                        if (length - cursor < 20) break;
                        cursor += 20;
                        size_t pathStart = cursor;
                        while (cursor < length && bytes[cursor] != 0) cursor++;
                        if (cursor >= length) break;
                        NSString *externalPath = [[NSString alloc] initWithBytes:bytes + pathStart length:cursor - pathStart encoding:NSUTF8StringEncoding];
                        cursor++;
                        [externals addObject:externalPath ?: @""];
                    }
                }
            }
        }
        *outExternals = externals;
    }

    for (int32_t i = 0; i < typeCount; i++) free(types[i].nodes);
    free(types);

    if (outObject) {
        if (objectProblem || !*outObject) {
            if (error) *error = ZSAEError(objectFound ? ZSAssetExplorerErrorTextureDecodeFailed : ZSAssetExplorerErrorAssetNotFound,
                                          objectFound ? @"This object couldn't be read." : @"The asset wasn't found in the bundle.");
            return NO;
        }
        return YES;
    }

    if (outRecord) {
        if (textureProblem) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"This object isn't a readable Texture2D.");
            return NO;
        }
        if (!*outRecord) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"The texture wasn't found in the bundle.");
            return NO;
        }
        return YES;
    }

    if (!parseOK) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"The serialized object table is truncated.");
        return NO;
    }

    if (outAssets) *outAssets = [assets copy];
    return YES;
}

static NSString *ZSAETextureFormatName(int32_t format) {
    switch (format) {
        case 1: return @"Alpha8";
        case 2: return @"ARGB4444";
        case 3: return @"RGB24";
        case 4: return @"RGBA32";
        case 5: return @"ARGB32";
        case 7: return @"RGB565";
        case 9: return @"R16";
        case 10: return @"DXT1";
        case 12: return @"DXT5";
        case 13: return @"RGBA4444";
        case 14: return @"BGRA32";
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

static void ZSAEExpand565(uint16_t color, uint8_t *rgb) {
    uint8_t r = (uint8_t)((color >> 11) & 31);
    uint8_t g = (uint8_t)((color >> 5) & 63);
    uint8_t b = (uint8_t)(color & 31);
    rgb[0] = (uint8_t)((r << 3) | (r >> 2));
    rgb[1] = (uint8_t)((g << 2) | (g >> 4));
    rgb[2] = (uint8_t)((b << 3) | (b >> 2));
}

static void ZSAEBuildBC1Palette(const uint8_t *block, BOOL forceFourColor, uint8_t palette[4][4]) {
    uint16_t c0 = (uint16_t)(block[0] | (block[1] << 8));
    uint16_t c1 = (uint16_t)(block[2] | (block[3] << 8));
    ZSAEExpand565(c0, palette[0]);
    ZSAEExpand565(c1, palette[1]);
    palette[0][3] = 255;
    palette[1][3] = 255;
    palette[2][3] = 255;
    if (c0 > c1 || forceFourColor) {
        for (int ch = 0; ch < 3; ch++) {
            palette[2][ch] = (uint8_t)((2 * palette[0][ch] + palette[1][ch]) / 3);
            palette[3][ch] = (uint8_t)((palette[0][ch] + 2 * palette[1][ch]) / 3);
        }
        palette[3][3] = 255;
    } else {
        for (int ch = 0; ch < 3; ch++) {
            palette[2][ch] = (uint8_t)((palette[0][ch] + palette[1][ch]) / 2);
            palette[3][ch] = 0;
        }
        palette[3][3] = 0;
    }
}

static void ZSAEDecodeDXT(const uint8_t *src, uint8_t *dst, int32_t width, int32_t height, BOOL dxt5) {
    size_t blocksWide = ((size_t)width + 3) / 4;
    size_t blocksHigh = ((size_t)height + 3) / 4;
    size_t blockSize = dxt5 ? 16 : 8;
    for (size_t by = 0; by < blocksHigh; by++) {
        for (size_t bx = 0; bx < blocksWide; bx++) {
            const uint8_t *block = src + (by * blocksWide + bx) * blockSize;
            const uint8_t *colorBlock = dxt5 ? block + 8 : block;
            uint8_t palette[4][4];
            ZSAEBuildBC1Palette(colorBlock, dxt5, palette);
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
                size_t y = by * 4 + (size_t)py;
                if (y >= (size_t)height) break;
                for (int px = 0; px < 4; px++) {
                    size_t x = bx * 4 + (size_t)px;
                    if (x >= (size_t)width) break;
                    int pixel = py * 4 + px;
                    uint32_t index = (colorBits >> (2 * pixel)) & 3;
                    uint8_t *out = dst + (y * (size_t)width + x) * 4;
                    out[0] = palette[index][0];
                    out[1] = palette[index][1];
                    out[2] = palette[index][2];
                    out[3] = dxt5 ? alphas[(alphaBits >> (3 * pixel)) & 7] : palette[index][3];
                }
            }
        }
    }
}

static id<MTLDevice> g_zsaeDevice;
static id<MTLCommandQueue> g_zsaeQueue;
static id<MTLComputePipelineState> g_zsaePipeline;

static NSString *ZSAEMetalPrepare(void) {
    static dispatch_once_t onceToken;
    static NSString *failure;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            failure = @"Metal isn't available on this device.";
            return;
        }
        NSString *source =
            @"#include <metal_stdlib>\n"
            @"using namespace metal;\n"
            @"kernel void zsae_copy(texture2d<float, access::sample> src [[texture(0)]],\n"
            @"                      texture2d<float, access::write> dst [[texture(1)]],\n"
            @"                      uint2 gid [[thread_position_in_grid]]) {\n"
            @"    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
            @"    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);\n"
            @"    float4 c = src.sample(s, float2(gid) + 0.5);\n"
            @"    dst.write(c, gid);\n"
            @"}\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"zsae_copy"];
        if (!function) {
            failure = [NSString stringWithFormat:@"Couldn't build the texture decoder: %@", error.localizedDescription ?: @"unknown error"];
            return;
        }
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!pipeline || !queue) {
            failure = @"Couldn't create the texture decoder pipeline.";
            return;
        }
        g_zsaeDevice = device;
        g_zsaeQueue = queue;
        g_zsaePipeline = pipeline;
    });
    return failure;
}

static BOOL ZSAEMetalDecode(MTLPixelFormat pixelFormat, NSUInteger blockWidth, NSUInteger blockHeight, NSUInteger blockBytes,
                            int32_t width, int32_t height, NSData *pixels, uint8_t *dst, NSString **failure) {
    NSString *prepareFailure = ZSAEMetalPrepare();
    if (prepareFailure) {
        if (failure) *failure = prepareFailure;
        return NO;
    }

    NSUInteger blocksWide = ((NSUInteger)width + blockWidth - 1) / blockWidth;
    NSUInteger blocksHigh = ((NSUInteger)height + blockHeight - 1) / blockHeight;
    NSUInteger needed = blocksWide * blocksHigh * blockBytes;
    if (pixels.length < needed) {
        if (failure) *failure = @"The texture data is shorter than its dimensions require.";
        return NO;
    }

    @autoreleasepool {
        MTLTextureDescriptor *sourceDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                                    width:(NSUInteger)width
                                                                                                   height:(NSUInteger)height
                                                                                                mipmapped:NO];
        sourceDescriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> source = [g_zsaeDevice newTextureWithDescriptor:sourceDescriptor];

        MTLTextureDescriptor *destDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                  width:(NSUInteger)width
                                                                                                 height:(NSUInteger)height
                                                                                              mipmapped:NO];
        destDescriptor.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        id<MTLTexture> dest = [g_zsaeDevice newTextureWithDescriptor:destDescriptor];
        if (!source || !dest) {
            if (failure) *failure = @"This device can't decode that texture format.";
            return NO;
        }

        [source replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
                  mipmapLevel:0
                    withBytes:pixels.bytes
                  bytesPerRow:blocksWide * blockBytes];

        id<MTLCommandBuffer> commandBuffer = [g_zsaeQueue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:g_zsaePipeline];
        [encoder setTexture:source atIndex:0];
        [encoder setTexture:dest atIndex:1];
        MTLSize group = MTLSizeMake(16, 16, 1);
        MTLSize groups = MTLSizeMake(((NSUInteger)width + 15) / 16, ((NSUInteger)height + 15) / 16, 1);
        [encoder dispatchThreadgroups:groups threadsPerThreadgroup:group];
        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
            if (failure) *failure = @"The GPU failed to decode the texture.";
            return NO;
        }

        [dest getBytes:dst
           bytesPerRow:(NSUInteger)width * 4
            fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
           mipmapLevel:0];
    }
    return YES;
}

static BOOL ZSAEDecodeTexture(ZSAETextureRecord *record, NSData *pixels, NSMutableData **outRGBA, NSError **error) {
    int32_t width = record.width;
    int32_t height = record.height;
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"The texture has invalid dimensions.");
        return NO;
    }

    size_t pixelCount = (size_t)width * (size_t)height;
    NSMutableData *rgba = [NSMutableData dataWithLength:pixelCount * 4];
    if (!rgba) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"Couldn't allocate memory for the decoded texture.");
        return NO;
    }
    uint8_t *dst = rgba.mutableBytes;
    const uint8_t *src = pixels.bytes;
    size_t length = pixels.length;
    int32_t format = record.format;
    NSString *failure = nil;
    BOOL unsupported = NO;
    BOOL ok = NO;

    switch (format) {
        case 1:
            if (length >= pixelCount) {
                for (size_t i = 0; i < pixelCount; i++) {
                    dst[i * 4] = 255;
                    dst[i * 4 + 1] = 255;
                    dst[i * 4 + 2] = 255;
                    dst[i * 4 + 3] = src[i];
                }
                ok = YES;
            }
            break;
        case 3:
            if (length >= pixelCount * 3) {
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
            if (length >= pixelCount * 4) {
                memcpy(dst, src, pixelCount * 4);
                ok = YES;
            }
            break;
        case 5:
            if (length >= pixelCount * 4) {
                for (size_t i = 0; i < pixelCount; i++) {
                    dst[i * 4] = src[i * 4 + 1];
                    dst[i * 4 + 1] = src[i * 4 + 2];
                    dst[i * 4 + 2] = src[i * 4 + 3];
                    dst[i * 4 + 3] = src[i * 4];
                }
                ok = YES;
            }
            break;
        case 14:
            if (length >= pixelCount * 4) {
                for (size_t i = 0; i < pixelCount; i++) {
                    dst[i * 4] = src[i * 4 + 2];
                    dst[i * 4 + 1] = src[i * 4 + 1];
                    dst[i * 4 + 2] = src[i * 4];
                    dst[i * 4 + 3] = src[i * 4 + 3];
                }
                ok = YES;
            }
            break;
        case 63:
            if (length >= pixelCount) {
                for (size_t i = 0; i < pixelCount; i++) {
                    dst[i * 4] = src[i];
                    dst[i * 4 + 1] = src[i];
                    dst[i * 4 + 2] = src[i];
                    dst[i * 4 + 3] = 255;
                }
                ok = YES;
            }
            break;
        case 10:
        case 12: {
            size_t blocks = (((size_t)width + 3) / 4) * (((size_t)height + 3) / 4);
            if (length >= blocks * (format == 12 ? 16 : 8)) {
                ZSAEDecodeDXT(src, dst, width, height, format == 12);
                ok = YES;
            }
            break;
        }
        case 34:
        case 45:
            ok = ZSAEMetalDecode(MTLPixelFormatETC2_RGB8, 4, 4, 8, width, height, pixels, dst, &failure);
            break;
        case 46:
            ok = ZSAEMetalDecode(MTLPixelFormatETC2_RGB8A1, 4, 4, 8, width, height, pixels, dst, &failure);
            break;
        case 47:
            ok = ZSAEMetalDecode(MTLPixelFormatEAC_RGBA8, 4, 4, 16, width, height, pixels, dst, &failure);
            break;
        case 48: case 54:
            ok = ZSAEMetalDecode(MTLPixelFormatASTC_4x4_LDR, 4, 4, 16, width, height, pixels, dst, &failure);
            break;
        case 49: case 55:
            ok = ZSAEMetalDecode(MTLPixelFormatASTC_5x5_LDR, 5, 5, 16, width, height, pixels, dst, &failure);
            break;
        case 50: case 56:
            ok = ZSAEMetalDecode(MTLPixelFormatASTC_6x6_LDR, 6, 6, 16, width, height, pixels, dst, &failure);
            break;
        case 51: case 57:
            ok = ZSAEMetalDecode(MTLPixelFormatASTC_8x8_LDR, 8, 8, 16, width, height, pixels, dst, &failure);
            break;
        case 52: case 58:
            ok = ZSAEMetalDecode(MTLPixelFormatASTC_10x10_LDR, 10, 10, 16, width, height, pixels, dst, &failure);
            break;
        case 53: case 59:
            ok = ZSAEMetalDecode(MTLPixelFormatASTC_12x12_LDR, 12, 12, 16, width, height, pixels, dst, &failure);
            break;
        case 28:
        case 29:
        case 64:
        case 65:
            unsupported = YES;
            failure = [NSString stringWithFormat:@"%@ textures use Crunch compression, which the Asset Explorer can't decode yet.", ZSAETextureFormatName(format)];
            break;
        default:
            unsupported = YES;
            failure = [NSString stringWithFormat:@"%@ textures can't be previewed yet.", ZSAETextureFormatName(format)];
            break;
    }

    if (!ok) {
        if (error) {
            *error = ZSAEError(unsupported ? ZSAssetExplorerErrorTextureUnsupported : ZSAssetExplorerErrorTextureDecodeFailed,
                               failure ?: @"The texture data is shorter than its dimensions require.");
        }
        return NO;
    }

    if (outRGBA) *outRGBA = rgba;
    return YES;
}

static UIImage *ZSAEImageFromTopDownRGBA(NSData *topDown, int32_t width, int32_t height) {
    size_t rowBytes = (size_t)width * 4;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)topDown);
    CGImageRef cgImage = CGImageCreate((size_t)width, (size_t)height, 8, 32, rowBytes, colorSpace,
                                       kCGBitmapByteOrderDefault | kCGImageAlphaLast,
                                       provider, NULL, false, kCGRenderingIntentDefault);
    UIImage *image = cgImage ? [UIImage imageWithCGImage:cgImage scale:1 orientation:UIImageOrientationUp] : nil;
    if (cgImage) CGImageRelease(cgImage);
    if (provider) CGDataProviderRelease(provider);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    return image;
}

static UIImage *ZSAEImageFromRGBA(NSData *rgba, int32_t width, int32_t height) {
    size_t rowBytes = (size_t)width * 4;
    NSMutableData *flipped = [NSMutableData dataWithLength:rowBytes * (size_t)height];
    if (!flipped) return nil;
    const uint8_t *src = rgba.bytes;
    uint8_t *dst = flipped.mutableBytes;
    for (int32_t y = 0; y < height; y++) {
        memcpy(dst + (size_t)y * rowBytes, src + (size_t)(height - 1 - y) * rowBytes, rowBytes);
    }
    return ZSAEImageFromTopDownRGBA(flipped, width, height);
}

@interface ZSAESession : NSObject
@property (nonatomic, strong) ZSAEBundle *bundle;
@property (nonatomic, strong) NSData *serializedData;
@property (nonatomic, copy) NSString *serializedPath;
@property (nonatomic, copy) NSString *bundlePath;
@end

@implementation ZSAESession
- (void)dealloc {
    if (_serializedPath.length > 0) [[NSFileManager defaultManager] removeItemAtPath:_serializedPath error:nil];
}
@end

@interface ZSAEObject : NSObject
@property (nonatomic, strong) NSDictionary *fields;
@property (nonatomic, assign) int32_t classID;
@property (nonatomic, copy) NSArray<NSString *> *externals;
@property (nonatomic, strong) ZSAESession *session;
@property (nonatomic, assign) int64_t pathID;
@property (nonatomic, assign) uint64_t rawStart;
@property (nonatomic, assign) uint64_t rawSize;
@end

@implementation ZSAEObject
@end

@interface ZSAEContext : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZSAESession *> *sessions;
@property (nonatomic, copy) NSArray<ZSAssetExplorerBundle *> *cachedBundles;
@end

@implementation ZSAEContext
@end

static int64_t ZSAEInt(id value) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value longLongValue] : 0;
}

static double ZSAEDouble(id value) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value doubleValue] : 0;
}

static NSDictionary *ZSAEDict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *ZSAEArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSString *ZSAEString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static ZSAESession *ZSAEOpenSession(NSString *bundlePath, NSError **error) {
    ZSAEBundle *bundle = nil;
    if (!ZSAEOpenBundle(bundlePath, &bundle, error)) return nil;

    if (bundle.residentSession) return bundle.residentSession;

    ZSAEBundleNode *cabNode = ZSAEFindSerializedNode(bundle);
    if (!cabNode) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"No serialized CAB node was found in the bundle.");
        return nil;
    }

    NSString *serializedPath = nil;
    if (!ZSAEReadFileNodeData(bundle.fileData, cabNode.offset, cabNode.size,
                              bundle.blockData.bytes, bundle.blockCount,
                              &serializedPath, error) || serializedPath.length == 0) {
        return nil;
    }

    NSError *mapError = nil;
    NSData *serializedData = [NSData dataWithContentsOfFile:serializedPath options:NSDataReadingMappedIfSafe error:&mapError];
    if (!serializedData) {
        [NSFileManager.defaultManager removeItemAtPath:serializedPath error:nil];
        if (error) *error = mapError ?: ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't map the serialized file.");
        return nil;
    }

    ZSAESession *session = [ZSAESession new];
    session.bundle = bundle;
    session.serializedData = serializedData;
    session.serializedPath = serializedPath;
    session.bundlePath = bundlePath;
    return session;
}

static BOOL ZSAELoadResidentBundle(NSString *path, NSError **error) {
    if (ZSAEResidentBundleForPath(path)) return YES;

    ZSAEBundle *bundle = nil;
    if (!ZSAEOpenBundle(path, &bundle, error)) return NO;

    ZSAEBundleNode *cabNode = ZSAEFindSerializedNode(bundle);
    if (!cabNode) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"No serialized CAB node was found in the bundle.");
        return NO;
    }

    if (bundle.uncompressedSize == 0 || bundle.uncompressedSize > (uint64_t)NSUIntegerMax) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The bundle has no loadable data.");
        return NO;
    }

    size_t available = os_proc_available_memory();
    if (available > 0 && bundle.uncompressedSize > (uint64_t)available / 10 * 6) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Not enough free memory to keep this bundle resident.");
        return NO;
    }

    NSMutableData *all = [NSMutableData dataWithLength:(NSUInteger)bundle.uncompressedSize];
    if (!all) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't allocate memory for the bundle.");
        return NO;
    }

    const ZSAEBlock *blocks = bundle.blockData.bytes;
    uint8_t *destination = all.mutableBytes;
    for (uint32_t i = 0; i < bundle.blockCount; i++) {
        const ZSAEBlock *block = &blocks[i];
        if (block->uncompressedSize == 0) continue;
        if (!ZSAEDecodeBlock(bundle.fileData, block, destination + block->uncompressedOffset, error)) return NO;
    }

    bundle.residentData = all;
    NSData *serializedData = ZSAEResidentNodeData(bundle, cabNode);
    if (!serializedData) {
        bundle.residentData = nil;
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The serialized CAB node lies outside the bundle.");
        return NO;
    }

    ZSAESession *session = [ZSAESession new];
    session.bundle = bundle;
    session.serializedData = serializedData;
    session.bundlePath = path;
    bundle.residentSession = session;

    NSMutableDictionary<NSString *, ZSAEBundle *> *bundles = ZSAEResidentBundles();
    @synchronized (bundles) {
        bundles[path] = bundle;
    }
    return YES;
}

static void ZSAEUnloadResidentBundle(NSString *path) {
    if (path.length == 0) return;
    NSMutableDictionary<NSString *, ZSAEBundle *> *bundles = ZSAEResidentBundles();
    ZSAEBundle *bundle = nil;
    @synchronized (bundles) {
        bundle = bundles[path];
        [bundles removeObjectForKey:path];
    }
    bundle.residentSession = nil;
}

static ZSAEObject *ZSAEReadObject(ZSAESession *session, int64_t pathID, NSError **error) {
    NSDictionary *fields = nil;
    int32_t classID = 0;
    NSArray<NSString *> *externals = nil;
    gZSAELastObjectStart = 0;
    gZSAELastObjectSize = 0;
    if (!ZSAEParseSerializedFile(session.serializedData, nil, pathID, NULL, &fields, &classID, &externals, error)) return nil;
    ZSAEObject *object = [ZSAEObject new];
    object.rawStart = gZSAELastObjectStart;
    object.rawSize = gZSAELastObjectSize;
    object.fields = fields;
    object.classID = classID;
    object.externals = externals ?: @[];
    object.session = session;
    object.pathID = pathID;
    return object;
}

static ZSAEObject *ZSAEResolvePPtr(ZSAEContext *context, ZSAEObject *owner, id pointer, NSError **error) {
    NSDictionary *reference = ZSAEDict(pointer);
    int64_t pathID = ZSAEInt(reference[@"m_PathID"]);
    int64_t fileID = ZSAEInt(reference[@"m_FileID"]);
    if (!reference || pathID == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"The asset has an empty reference.");
        return nil;
    }

    ZSAESession *session = owner.session;
    if (fileID != 0) {
        NSArray<NSString *> *externals = owner.externals;
        if (fileID < 1 || fileID > (int64_t)externals.count) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"The asset points to an unknown external file.");
            return nil;
        }
        NSString *cab = externals[(NSUInteger)(fileID - 1)].lastPathComponent;
        if (!context.cachedBundles) context.cachedBundles = [ZSAssetExplorer cachedBundles:nil] ?: @[];
        NSString *bundlePath = nil;
        for (ZSAssetExplorerBundle *candidate in context.cachedBundles) {
            if ([candidate.cabIdentifier caseInsensitiveCompare:cab] == NSOrderedSame) {
                bundlePath = candidate.filePath;
                break;
            }
        }
        if (bundlePath.length == 0) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, [NSString stringWithFormat:@"This asset depends on %@, which isn't in the cache.", cab]);
            return nil;
        }
        session = context.sessions[bundlePath];
        if (!session) {
            session = ZSAEOpenSession(bundlePath, error);
            if (!session) return nil;
            context.sessions[bundlePath] = session;
        }
    }
    return ZSAEReadObject(session, pathID, error);
}

static NSData *ZSAELoadPixels(ZSAESession *session, NSData *inlineData, NSString *streamPath, uint64_t streamOffset, uint64_t streamSize, NSError **error) {
    if (inlineData.length > 0) return inlineData;
    if (streamSize == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"The asset has no pixel data.");
        return nil;
    }
    ZSAEBundle *bundle = session.bundle;
    NSString *streamName = streamPath.lastPathComponent;
    ZSAEBundleNode *streamNode = nil;
    for (ZSAEBundleNode *node in bundle.nodes) {
        if (streamName.length > 0 && [node.path isEqualToString:streamName]) {
            streamNode = node;
            break;
        }
    }
    if (!streamNode) {
        for (ZSAEBundleNode *node in bundle.nodes) {
            if ((node.flags & 4) == 0 && [node.path hasSuffix:@".resS"]) {
                streamNode = node;
                break;
            }
        }
    }
    if (!streamNode || streamOffset > streamNode.size || streamSize > streamNode.size - streamOffset) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The streamed pixel data wasn't found in the bundle.");
        return nil;
    }
    return ZSAEReadBundleRange(bundle, streamNode.offset + streamOffset, streamSize, error);
}

static BOOL ZSAEDecodeTextureObject(ZSAEObject *object, ZSAETextureRecord **outRecord, NSMutableData **outRGBA, NSError **error) {
    if (object.classID != 28) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"The referenced object isn't a Texture2D.");
        return NO;
    }
    NSDictionary *fields = object.fields;
    ZSAETextureRecord *record = [ZSAETextureRecord new];
    record.name = ZSAEString(fields[@"m_Name"]);
    record.width = (int32_t)ZSAEInt(fields[@"m_Width"]);
    record.height = (int32_t)ZSAEInt(fields[@"m_Height"]);
    record.format = (int32_t)ZSAEInt(fields[@"m_TextureFormat"]);
    record.mipCount = (int32_t)ZSAEInt(fields[@"m_MipCount"]);
    NSData *inlineData = [fields[@"image data"] isKindOfClass:[NSData class]] ? fields[@"image data"] : nil;
    NSDictionary *stream = ZSAEDict(fields[@"m_StreamData"]);
    NSData *pixels = ZSAELoadPixels(object.session, inlineData, ZSAEString(stream[@"path"]),
                                    (uint64_t)ZSAEInt(stream[@"offset"]), (uint64_t)ZSAEInt(stream[@"size"]), error);
    if (!pixels) return NO;
    NSMutableData *rgba = nil;
    if (!ZSAEDecodeTexture(record, pixels, &rgba, error)) return NO;
    if (outRecord) *outRecord = record;
    if (outRGBA) *outRGBA = rgba;
    return YES;
}

static BOOL ZSAEFormatLayout(int32_t format, uint64_t *blockWidth, uint64_t *blockHeight, uint64_t *blockBytes) {
    uint64_t width = 4, height = 4, bytes = 16;
    switch (format) {
        case 1: case 63: width = 1; height = 1; bytes = 1; break;
        case 3: width = 1; height = 1; bytes = 3; break;
        case 4: case 5: case 14: width = 1; height = 1; bytes = 4; break;
        case 10: case 34: case 45: case 46: bytes = 8; break;
        case 12: case 47: case 48: case 54: break;
        case 49: case 55: width = 5; height = 5; break;
        case 50: case 56: width = 6; height = 6; break;
        case 51: case 57: width = 8; height = 8; break;
        case 52: case 58: width = 10; height = 10; break;
        case 53: case 59: width = 12; height = 12; break;
        default: return NO;
    }
    if (blockWidth) *blockWidth = width;
    if (blockHeight) *blockHeight = height;
    if (blockBytes) *blockBytes = bytes;
    return YES;
}

static uint64_t ZSAEDataSize(int32_t format, int32_t width, int32_t height, int32_t depth, int32_t mips, BOOL volume) {
    uint64_t blockWidth = 0, blockHeight = 0, blockBytes = 0;
    if (!ZSAEFormatLayout(format, &blockWidth, &blockHeight, &blockBytes)) return 0;
    if (mips < 1) mips = 1;
    uint64_t total = 0;
    for (int32_t level = 0; level < mips && level < 24; level++) {
        uint64_t levelWidth = (uint64_t)MAX(width >> level, 1);
        uint64_t levelHeight = (uint64_t)MAX(height >> level, 1);
        uint64_t blocks = ((levelWidth + blockWidth - 1) / blockWidth) * ((levelHeight + blockHeight - 1) / blockHeight) * blockBytes;
        uint64_t layers = volume ? (uint64_t)MAX(depth >> level, 1) : (uint64_t)MAX(depth, 1);
        total += blocks * layers;
    }
    return total;
}

static BOOL ZSAEFormatMatches(int32_t format, int32_t width, int32_t height, int32_t depth, int32_t mips, BOOL volume, uint64_t length) {
    uint64_t full = ZSAEDataSize(format, width, height, depth, mips, volume);
    if (full != 0 && full == length) return YES;
    uint64_t base = ZSAEDataSize(format, width, height, depth, 1, volume);
    return base != 0 && base == length;
}

static int32_t ZSAEInferFormat(int32_t raw, int32_t width, int32_t height, int32_t depth, int32_t mips, BOOL volume, uint64_t length) {
    static const int32_t candidates[] = {48, 49, 50, 51, 52, 53, 47, 46, 45, 34, 4, 14, 5, 3, 63, 1, 12, 10};
    int32_t hinted = 0;
    switch (raw) {
        case 1: case 5: hinted = 63; break;
        case 3: case 7: hinted = 3; break;
        case 4: case 8: hinted = 4; break;
        case 57: case 59: hinted = 14; break;
        default: break;
    }
    int32_t ordered[2] = { hinted, raw };
    for (int i = 0; i < 2; i++) {
        if (ordered[i] > 0 && ZSAEFormatMatches(ordered[i], width, height, depth, mips, volume, length)) return ordered[i];
    }
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if (ZSAEFormatMatches(candidates[i], width, height, depth, mips, volume, length)) return candidates[i];
    }
    return 0;
}

static NSData *ZSAETopDownCrop(NSData *bottomUp, int32_t textureWidth, int32_t x, int32_t y, int32_t width, int32_t height) {
    size_t rowBytes = (size_t)width * 4;
    NSMutableData *output = [NSMutableData dataWithLength:rowBytes * (size_t)height];
    if (!output) return nil;
    const uint8_t *source = bottomUp.bytes;
    uint8_t *destination = output.mutableBytes;
    for (int32_t row = 0; row < height; row++) {
        const uint8_t *from = source + ((size_t)(y + height - 1 - row) * (size_t)textureWidth + (size_t)x) * 4;
        memcpy(destination + (size_t)row * rowBytes, from, rowBytes);
    }
    return output;
}

static NSData *ZSAETransformTopDown(NSData *source, int32_t *width, int32_t *height, int rotation) {
    if (rotation < 1 || rotation > 4) return source;
    int32_t w = *width;
    int32_t h = *height;
    int32_t outWidth = rotation == 3 ? h : w;
    int32_t outHeight = rotation == 3 ? w : h;
    NSMutableData *output = [NSMutableData dataWithLength:(size_t)outWidth * (size_t)outHeight * 4];
    if (!output) return source;
    const uint32_t *from = source.bytes;
    uint32_t *to = output.mutableBytes;
    for (int32_t y = 0; y < outHeight; y++) {
        for (int32_t x = 0; x < outWidth; x++) {
            int32_t sx = 0, sy = 0;
            switch (rotation) {
                case 1: sx = w - 1 - x; sy = y; break;
                case 2: sx = x; sy = h - 1 - y; break;
                case 3: sx = y; sy = h - 1 - x; break;
                default: sx = w - 1 - x; sy = h - 1 - y; break;
            }
            to[(size_t)y * (size_t)outWidth + (size_t)x] = from[(size_t)sy * (size_t)w + (size_t)sx];
        }
    }
    *width = outWidth;
    *height = outHeight;
    return output;
}

static NSString *ZSAECubeFaceName(NSInteger face) {
    static NSString * const names[6] = {@"+X", @"-X", @"+Y", @"-Y", @"+Z", @"-Z"};
    return names[((face % 6) + 6) % 6];
}

static UIImage *ZSAEFaceSheet(NSArray<NSData *> *faces, int32_t width, int32_t height) {
    int32_t step = MAX(1, (MAX(width, height) + 511) / 512);
    int32_t cellWidth = (width + step - 1) / step;
    int32_t cellHeight = (height + step - 1) / step;
    int32_t gap = 6;
    int32_t sheetWidth = cellWidth * 3 + gap * 2;
    int32_t sheetHeight = cellHeight * 2 + gap;
    NSMutableData *sheet = [NSMutableData dataWithLength:(size_t)sheetWidth * (size_t)sheetHeight * 4];
    if (!sheet) return nil;
    uint32_t *destination = sheet.mutableBytes;
    for (NSUInteger face = 0; face < faces.count && face < 6; face++) {
        const uint32_t *source = faces[face].bytes;
        int32_t originX = (int32_t)(face % 3) * (cellWidth + gap);
        int32_t originY = (int32_t)(face / 3) * (cellHeight + gap);
        for (int32_t y = 0; y < cellHeight; y++) {
            int32_t sourceRow = height - 1 - MIN(y * step, height - 1);
            for (int32_t x = 0; x < cellWidth; x++) {
                int32_t sourceColumn = MIN(x * step, width - 1);
                destination[(size_t)(originY + y) * (size_t)sheetWidth + (size_t)(originX + x)] = source[(size_t)sourceRow * (size_t)width + (size_t)sourceColumn];
            }
        }
    }
    return ZSAEImageFromTopDownRGBA(sheet, sheetWidth, sheetHeight);
}

@interface ZSAESpriteImage : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, assign) int32_t width;
@property (nonatomic, assign) int32_t height;
@property (nonatomic, assign) double offsetX;
@property (nonatomic, assign) double offsetY;
@property (nonatomic, assign) double rectWidth;
@property (nonatomic, assign) double rectHeight;
@property (nonatomic, assign) double pivotX;
@property (nonatomic, assign) double pivotY;
@property (nonatomic, assign) double pixelsPerUnit;
@property (nonatomic, copy) NSString *textureName;
@property (nonatomic, copy) NSString *formatName;
@end

@implementation ZSAESpriteImage
@end

static NSString *ZSAESpriteGroupKey(ZSAEObject *sprite) {
    NSDictionary *fields = sprite.fields;
    NSDictionary *atlasPointer = ZSAEDict(fields[@"m_SpriteAtlas"]);
    if (atlasPointer && ZSAEInt(atlasPointer[@"m_PathID"]) != 0 && fields[@"m_RenderDataKey"]) {
        return [NSString stringWithFormat:@"a:%lld:%lld", (long long)ZSAEInt(atlasPointer[@"m_FileID"]), (long long)ZSAEInt(atlasPointer[@"m_PathID"])];
    }
    NSDictionary *texturePointer = ZSAEDict(ZSAEDict(fields[@"m_RD"])[@"texture"]);
    return [NSString stringWithFormat:@"t:%lld:%lld", (long long)ZSAEInt(texturePointer[@"m_FileID"]), (long long)ZSAEInt(texturePointer[@"m_PathID"])];
}

static ZSAESpriteImage *ZSAEMakeSpriteImage(ZSAEContext *context, ZSAEObject *sprite, NSMutableDictionary *cache, NSError **error) {
    NSDictionary *fields = sprite.fields;
    NSDictionary *source = ZSAEDict(fields[@"m_RD"]);
    ZSAEObject *sourceOwner = sprite;
    NSMutableDictionary *atlasCache = cache[@"atlases"];
    NSMutableDictionary *textureCache = cache[@"textures"];

    NSDictionary *atlasPointer = ZSAEDict(fields[@"m_SpriteAtlas"]);
    id key = fields[@"m_RenderDataKey"];
    if (atlasPointer && ZSAEInt(atlasPointer[@"m_PathID"]) != 0 && key) {
        NSString *atlasKey = [NSString stringWithFormat:@"%p:%lld:%lld", sprite.session, (long long)ZSAEInt(atlasPointer[@"m_FileID"]), (long long)ZSAEInt(atlasPointer[@"m_PathID"])];
        ZSAEObject *atlas = atlasCache[atlasKey];
        if (!atlas) {
            atlas = ZSAEResolvePPtr(context, sprite, atlasPointer, NULL);
            if (atlas && atlasCache) {
                if (atlasCache.count >= 3) [atlasCache removeAllObjects];
                atlasCache[atlasKey] = atlas;
            }
        }
        for (id entry in ZSAEArray(atlas.fields[@"m_RenderDataMap"])) {
            NSDictionary *pair = ZSAEDict(entry);
            if (pair && [pair[@"first"] isEqual:key]) {
                NSDictionary *data = ZSAEDict(pair[@"second"]);
                if (data) {
                    source = data;
                    sourceOwner = atlas;
                }
                break;
            }
        }
    }

    NSDictionary *texturePointer = ZSAEDict(source[@"texture"]);
    NSDictionary *rect = ZSAEDict(source[@"textureRect"]);
    if (!texturePointer || !rect || ZSAEInt(texturePointer[@"m_PathID"]) == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"This sprite's texture isn't available. It may be packed into a SpriteAtlas that isn't cached.");
        return nil;
    }

    NSString *textureKey = [NSString stringWithFormat:@"%p:%lld:%lld", sourceOwner.session, (long long)ZSAEInt(texturePointer[@"m_FileID"]), (long long)ZSAEInt(texturePointer[@"m_PathID"])];
    ZSAETextureRecord *record = nil;
    NSMutableData *rgba = nil;
    NSArray *cachedTexture = textureCache[textureKey];
    if (cachedTexture.count == 2) {
        record = cachedTexture[0];
        rgba = cachedTexture[1];
    } else {
        ZSAEObject *textureObject = ZSAEResolvePPtr(context, sourceOwner, texturePointer, error);
        if (!textureObject) return nil;
        if (!ZSAEDecodeTextureObject(textureObject, &record, &rgba, error)) return nil;
        if (textureCache) {
            if (textureCache.count >= 2) [textureCache removeAllObjects];
            textureCache[textureKey] = @[record, rgba];
        }
    }

    int32_t textureWidth = record.width;
    int32_t textureHeight = record.height;
    int32_t x = (int32_t)floor(ZSAEDouble(rect[@"x"]));
    int32_t y = (int32_t)floor(ZSAEDouble(rect[@"y"]));
    int32_t w = (int32_t)ceil(ZSAEDouble(rect[@"width"]));
    int32_t h = (int32_t)ceil(ZSAEDouble(rect[@"height"]));
    x = MAX(0, MIN(x, textureWidth - 1));
    y = MAX(0, MIN(y, textureHeight - 1));
    w = MAX(1, MIN(w, textureWidth - x));
    h = MAX(1, MIN(h, textureHeight - y));

    NSData *crop = ZSAETopDownCrop(rgba, textureWidth, x, y, w, h);
    if (!crop) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"Couldn't allocate memory for the sprite.");
        return nil;
    }
    uint32_t settings = (uint32_t)ZSAEInt(source[@"settingsRaw"]);
    int rotation = (settings & 1) ? (int)((settings >> 2) & 0xF) : 0;
    crop = ZSAETransformTopDown(crop, &w, &h, rotation);

    UIImage *image = ZSAEImageFromTopDownRGBA(crop, w, h);
    if (!image) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"Couldn't build an image from the sprite.");
        return nil;
    }

    NSDictionary *spriteRect = ZSAEDict(fields[@"m_Rect"]);
    NSDictionary *pivot = ZSAEDict(fields[@"m_Pivot"]);
    NSDictionary *offset = ZSAEDict(source[@"textureRectOffset"]);
    double ppu = ZSAEDouble(fields[@"m_PixelsToUnits"]);

    ZSAESpriteImage *result = [ZSAESpriteImage new];
    result.image = image;
    result.width = w;
    result.height = h;
    result.rectWidth = spriteRect ? ZSAEDouble(spriteRect[@"width"]) : (double)w;
    result.rectHeight = spriteRect ? ZSAEDouble(spriteRect[@"height"]) : (double)h;
    if (result.rectWidth <= 0) result.rectWidth = (double)w;
    if (result.rectHeight <= 0) result.rectHeight = (double)h;
    result.offsetX = offset ? ZSAEDouble(offset[@"x"]) : 0;
    result.offsetY = offset ? ZSAEDouble(offset[@"y"]) : 0;
    result.pivotX = pivot ? ZSAEDouble(pivot[@"x"]) : 0.5;
    result.pivotY = pivot ? ZSAEDouble(pivot[@"y"]) : 0.5;
    result.pixelsPerUnit = ppu > 0 ? ppu : 100;
    result.textureName = record.name.length > 0 ? record.name : @"texture";
    result.formatName = ZSAETextureFormatName(record.format);
    return result;
}

static ZSAssetExplorerVisual *ZSAEBuildSpriteVisual(ZSAEContext *context, ZSAEObject *sprite, NSError **error) {
    ZSAESpriteImage *result = ZSAEMakeSpriteImage(context, sprite, nil, error);
    if (!result) return nil;
    UIImage *image = result.image;
    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = ZSAEString(sprite.fields[@"m_Name"]);
    visual.summary = [NSString stringWithFormat:@"Sprite  •  %dx%d  •  %@  •  %@", result.width, result.height, result.textureName, result.formatName];
    visual.pageLabels = @[@"Sprite"];
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        return image;
    };
    return visual;
}

static ZSAssetExplorerVisual *ZSAEBuildAtlasVisual(ZSAEContext *context, ZSAEObject *atlas, NSError **error) {
    NSMutableArray<NSDictionary *> *collected = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id entry in ZSAEArray(atlas.fields[@"m_RenderDataMap"])) {
        NSDictionary *data = ZSAEDict(ZSAEDict(entry)[@"second"]);
        NSDictionary *pointer = ZSAEDict(data[@"texture"]);
        if (!pointer || ZSAEInt(pointer[@"m_PathID"]) == 0) continue;
        NSString *identity = [NSString stringWithFormat:@"%lld:%lld", ZSAEInt(pointer[@"m_FileID"]), ZSAEInt(pointer[@"m_PathID"])];
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        [collected addObject:pointer];
    }
    if (collected.count == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"This atlas has no packed texture pages in the bundle.");
        return nil;
    }

    NSArray<NSDictionary *> *pages = [collected copy];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSUInteger i = 0; i < pages.count; i++) [labels addObject:[NSString stringWithFormat:@"Page %lu", (unsigned long)(i + 1)]];
    NSUInteger spriteCount = ZSAEArray(atlas.fields[@"m_PackedSprites"]).count;

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = ZSAEString(atlas.fields[@"m_Name"]);
    visual.summary = [NSString stringWithFormat:@"SpriteAtlas  •  %lu sprite%@  •  %lu page%@",
                      (unsigned long)spriteCount, spriteCount == 1 ? @"" : @"s",
                      (unsigned long)pages.count, pages.count == 1 ? @"" : @"s"];
    visual.pageLabels = labels;
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        if (page < 0 || page >= (NSInteger)pages.count) return nil;
        ZSAEObject *textureObject = ZSAEResolvePPtr(context, atlas, pages[(NSUInteger)page], providerError);
        if (!textureObject) return nil;
        ZSAETextureRecord *record = nil;
        NSMutableData *rgba = nil;
        if (!ZSAEDecodeTextureObject(textureObject, &record, &rgba, providerError)) return nil;
        return ZSAEImageFromRGBA(rgba, record.width, record.height);
    };
    return visual;
}

static ZSAssetExplorerVisual *ZSAEBuildSliceVisual(ZSAEObject *object, NSError **error) {
    NSDictionary *fields = object.fields;
    int32_t classID = object.classID;
    int32_t width = (int32_t)ZSAEInt(fields[@"m_Width"]);
    int32_t height = (int32_t)ZSAEInt(fields[@"m_Height"]);
    if (height <= 0) height = width;
    int32_t mips = (int32_t)ZSAEInt(fields[@"m_MipCount"]);
    BOOL volume = classID == 117;
    int32_t depth = 6;
    if (classID == 187 || classID == 117) depth = (int32_t)ZSAEInt(fields[@"m_Depth"]);
    else if (classID == 188) depth = (int32_t)ZSAEInt(fields[@"m_CubemapCount"]) * 6;
    if (width <= 0 || width > 16384 || height <= 0 || height > 16384 || depth <= 0 || depth > 4096) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"The texture has invalid dimensions.");
        return nil;
    }

    NSData *inlineData = [fields[@"image data"] isKindOfClass:[NSData class]] ? fields[@"image data"] : nil;
    NSDictionary *stream = ZSAEDict(fields[@"m_StreamData"]);
    NSData *pixels = ZSAELoadPixels(object.session, inlineData, ZSAEString(stream[@"path"]),
                                    (uint64_t)ZSAEInt(stream[@"offset"]), (uint64_t)ZSAEInt(stream[@"size"]), error);
    if (!pixels) return nil;

    int32_t format = 0;
    if (classID == 89) format = (int32_t)ZSAEInt(fields[@"m_TextureFormat"]);
    else format = ZSAEInferFormat((int32_t)ZSAEInt(fields[@"m_Format"]), width, height, depth, mips, volume, pixels.length);
    if (format == 0 || !ZSAEFormatLayout(format, NULL, NULL, NULL)) {
        if (error) {
            *error = ZSAEError(ZSAssetExplorerErrorTextureUnsupported,
                               classID == 89 ? [NSString stringWithFormat:@"%@ textures can't be previewed yet.", ZSAETextureFormatName((int32_t)ZSAEInt(fields[@"m_TextureFormat"]))]
                                             : @"The pixel format of this texture couldn't be determined.");
        }
        return nil;
    }

    uint64_t stride = volume ? ZSAEDataSize(format, width, height, 1, 1, NO) : (uint64_t)pixels.length / (uint64_t)depth;
    if (stride == 0 || stride * (uint64_t)depth > (uint64_t)pixels.length) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"The texture data is shorter than its dimensions require.");
        return nil;
    }

    BOOL hasSheet = classID == 89;
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    if (hasSheet) [labels addObject:@"All faces"];
    for (int32_t i = 0; i < depth; i++) {
        if (classID == 89) [labels addObject:ZSAECubeFaceName(i)];
        else if (classID == 188) [labels addObject:[NSString stringWithFormat:@"Cube %d  %@", i / 6 + 1, ZSAECubeFaceName(i)]];
        else if (classID == 187) [labels addObject:[NSString stringWithFormat:@"Slice %d", i + 1]];
        else [labels addObject:[NSString stringWithFormat:@"Layer %d", i + 1]];
    }

    NSString *kindName = classID == 89 ? @"Cubemap" : (classID == 187 ? @"Texture2DArray" : (classID == 117 ? @"Texture3D" : @"CubemapArray"));
    NSString *dimensions = volume ? [NSString stringWithFormat:@"%dx%dx%d", width, height, depth] : [NSString stringWithFormat:@"%dx%d", width, height];

    NSMutableData *(^decodeSlice)(NSInteger, NSError **) = ^NSMutableData *(NSInteger slice, NSError **sliceError) {
        uint64_t offset = (uint64_t)MAX(slice, 0) * stride;
        if (slice < 0 || offset + stride > (uint64_t)pixels.length) {
            if (sliceError) *sliceError = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"That slice is outside the texture data.");
            return nil;
        }
        NSData *data = [pixels subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)stride)];
        ZSAETextureRecord *record = [ZSAETextureRecord new];
        record.width = width;
        record.height = height;
        record.format = format;
        NSMutableData *rgba = nil;
        if (!ZSAEDecodeTexture(record, data, &rgba, sliceError)) return nil;
        return rgba;
    };

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = ZSAEString(fields[@"m_Name"]);
    visual.summary = [NSString stringWithFormat:@"%@  •  %@  •  %@", kindName, dimensions, ZSAETextureFormatName(format)];
    visual.pageLabels = labels;
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        if (hasSheet && page == 0) {
            NSMutableArray<NSData *> *faces = [NSMutableArray array];
            for (NSInteger face = 0; face < 6; face++) {
                NSMutableData *rgba = decodeSlice(face, providerError);
                if (!rgba) return nil;
                [faces addObject:rgba];
            }
            return ZSAEFaceSheet(faces, width, height);
        }
        NSMutableData *rgba = decodeSlice(hasSheet ? page - 1 : page, providerError);
        if (!rgba) return nil;
        return ZSAEImageFromRGBA(rgba, width, height);
    };
    return visual;
}

static NSString *ZSAEHexDump(NSData *data, NSUInteger limit) {
    NSUInteger count = MIN(data.length, limit);
    const uint8_t *bytes = data.bytes;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < count; i += 16) {
        [out appendFormat:@"%08lX  ", (unsigned long)i];
        NSMutableString *ascii = [NSMutableString string];
        for (NSUInteger j = 0; j < 16; j++) {
            if (i + j < count) {
                uint8_t c = bytes[i + j];
                [out appendFormat:@"%02X ", c];
                [ascii appendFormat:@"%c", (c >= 32 && c < 127) ? c : '.'];
            } else {
                [out appendString:@"   "];
            }
        }
        [out appendFormat:@" %@\n", ascii];
    }
    if (data.length > count) [out appendFormat:@"… %lu more bytes\n", (unsigned long)(data.length - count)];
    return out;
}

static NSString *ZSAEEscapedPreview(NSString *value, NSUInteger limit) {
    NSString *clipped = value.length > limit ? [[value substringToIndex:limit] stringByAppendingString:@"…"] : value;
    clipped = [clipped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    clipped = [clipped stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    return [NSString stringWithFormat:@"\"%@\"", clipped];
}

static BOOL ZSAEIsPPtr(NSDictionary *dictionary) {
    return dictionary.count == 2 && dictionary[@"m_FileID"] && dictionary[@"m_PathID"];
}

static NSString *ZSAEPPtrText(NSDictionary *pointer) {
    int64_t pathID = ZSAEInt(pointer[@"m_PathID"]);
    if (pathID == 0) return @"None";
    int64_t fileID = ZSAEInt(pointer[@"m_FileID"]);
    if (fileID == 0) return [NSString stringWithFormat:@"PathID %lld", (long long)pathID];
    return [NSString stringWithFormat:@"PathID %lld (external file %lld)", (long long)pathID, (long long)fileID];
}

static NSString *ZSAEScalarText(id value) {
    if ([value isKindOfClass:[NSString class]]) return ZSAEEscapedPreview(value, 400);
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    if ([value isKindOfClass:[NSData class]]) {
        NSData *data = value;
        if (data.length == 0) return @"<empty>";
        if (data.length > 16) return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)data.length];
        const uint8_t *bytes = data.bytes;
        NSMutableString *hex = [NSMutableString stringWithString:@"<"];
        for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:i == 0 ? @"%02X" : @" %02X", bytes[i]];
        [hex appendString:@">"];
        return hex;
    }
    return [value description] ?: @"";
}

static NSArray<NSString *> *ZSAESortedKeys(NSDictionary *dictionary) {
    return [dictionary.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL aName = [a isEqualToString:@"m_Name"];
        BOOL bName = [b isEqualToString:@"m_Name"];
        if (aName != bName) return aName ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
}

static NSString *ZSAEInlineText(id value) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = value;
        if (dictionary.count == 0) return @"{}";
        if (ZSAEIsPPtr(dictionary)) return ZSAEPPtrText(dictionary);
        if (dictionary.count > 4) return nil;
        NSArray<NSString *> *order = dictionary[@"r"] ? @[@"r", @"g", @"b", @"a"] : @[@"x", @"y", @"z", @"w"];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *key in order) {
            id component = dictionary[key];
            if (!component) continue;
            if (![component isKindOfClass:[NSNumber class]]) return nil;
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, [(NSNumber *)component stringValue]]];
        }
        if (parts.count != dictionary.count) return nil;
        return [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@", "]];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = value;
        if (array.count == 0) return @"[]";
        if (array.count > 16) return nil;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in array) {
            if (![item isKindOfClass:[NSNumber class]]) return nil;
            [parts addObject:[(NSNumber *)item stringValue]];
        }
        return [NSString stringWithFormat:@"[%@]", [parts componentsJoinedByString:@", "]];
    }
    return ZSAEScalarText(value);
}

static void ZSAEEmitValue(NSMutableString *out, NSString *label, id value, NSUInteger depth) {
    if (out.length > 400000) return;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSString *inlineText = ZSAEInlineText(value);
    if (inlineText) {
        [out appendFormat:@"%@%@: %@\n", pad, label, inlineText];
        return;
    }
    if (depth >= 10) {
        [out appendFormat:@"%@%@: …\n", pad, label];
        return;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = value;
        [out appendFormat:@"%@%@:\n", pad, label];
        for (NSString *key in ZSAESortedKeys(dictionary)) ZSAEEmitValue(out, key, dictionary[key], depth + 1);
    } else if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = value;
        [out appendFormat:@"%@%@ (%lu):\n", pad, label, (unsigned long)array.count];
        NSUInteger shown = MIN(array.count, (NSUInteger)64);
        for (NSUInteger i = 0; i < shown; i++) {
            ZSAEEmitValue(out, [NSString stringWithFormat:@"[%lu]", (unsigned long)i], array[i], depth + 1);
        }
        if (array.count > shown) [out appendFormat:@"%@  … %lu more\n", pad, (unsigned long)(array.count - shown)];
    } else {
        [out appendFormat:@"%@%@: %@\n", pad, label, ZSAEScalarText(value)];
    }
}

static ZSAssetExplorerVisual *ZSAEBuildInspectorVisual(ZSAEObject *object, NSError **error) {
    NSDictionary *fields = object.fields;
    if (fields.count == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"This object has no readable fields.");
        return nil;
    }
    NSMutableString *text = [NSMutableString string];
    for (NSString *key in ZSAESortedKeys(fields)) ZSAEEmitValue(text, key, fields[key], 0);
    if (text.length > 400000) [text appendString:@"\n… output truncated"];

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = ZSAEString(fields[@"m_Name"]);
    visual.summary = visual.name.length > 0 ? visual.name : @"Properties";
    visual.pageLabels = @[@"Properties"];
    visual.text = text;
    visual.exportData = [text dataUsingEncoding:NSUTF8StringEncoding];
    visual.fileExtension = @"txt";
    return visual;
}

static ZSAssetExplorerVisual *ZSAEBuildTextAssetVisual(ZSAEObject *object, NSError **error) {
    NSDictionary *fields = object.fields;
    id script = fields[@"m_Script"];
    NSString *content = nil;
    NSData *rawData = nil;
    if ([script isKindOfClass:[NSString class]]) {
        content = script;
        rawData = [content dataUsingEncoding:NSUTF8StringEncoding];
    } else if ([script isKindOfClass:[NSData class]]) {
        rawData = script;
        content = [[NSString alloc] initWithData:rawData encoding:NSUTF8StringEncoding];
    }
    if (!content && rawData.length == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"This text asset is empty.");
        return nil;
    }

    BOOL binary = NO;
    if (content) {
        NSUInteger sample = MIN(content.length, (NSUInteger)4096);
        NSUInteger control = 0;
        for (NSUInteger i = 0; i < sample; i++) {
            unichar c = [content characterAtIndex:i];
            if (c < 32 && c != '\t' && c != '\n' && c != '\r') control++;
        }
        binary = sample > 0 && control * 50 > sample;
    } else {
        binary = YES;
    }

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = ZSAEString(fields[@"m_Name"]);
    visual.pageLabels = @[@"Text"];
    if (binary) {
        NSData *bytes = content ? [content dataUsingEncoding:NSWindowsCP1252StringEncoding allowLossyConversion:YES] : rawData;
        visual.text = ZSAEHexDump(bytes, 4096);
        visual.exportData = bytes;
        visual.fileExtension = @"bytes";
        visual.summary = [NSString stringWithFormat:@"%@  •  binary  •  %@", visual.name.length > 0 ? visual.name : @"TextAsset",
                          [NSByteCountFormatter stringFromByteCount:(long long)bytes.length countStyle:NSByteCountFormatterCountStyleFile]];
        return visual;
    }

    NSString *trimmed = [content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    unichar first = trimmed.length > 0 ? [trimmed characterAtIndex:0] : 0;
    NSString *extension = (first == '{' || first == '[') ? @"json" : (first == '<' ? @"xml" : @"txt");
    NSString *display = content;
    if (display.length > 200000) {
        display = [[display substringToIndex:200000] stringByAppendingString:@"\n\n… truncated, share to export the full text"];
    }
    visual.text = display;
    visual.exportData = [content dataUsingEncoding:NSUTF8StringEncoding];
    visual.fileExtension = extension;
    visual.summary = [NSString stringWithFormat:@"%@  •  %lu characters", visual.name.length > 0 ? visual.name : @"TextAsset", (unsigned long)content.length];
    return visual;
}

static ZSAssetExplorerVisual *ZSAEBuildFontVisual(ZSAEObject *object, NSError **error) {
    NSDictionary *fields = object.fields;
    NSData *fontData = [fields[@"m_FontData"] isKindOfClass:[NSData class]] ? fields[@"m_FontData"] : nil;
    if (fontData.length == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"This font has no embedded font file.");
        return nil;
    }
    CTFontDescriptorRef rawDescriptor = CTFontManagerCreateFontDescriptorFromData((__bridge CFDataRef)fontData);
    if (!rawDescriptor) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"The embedded font file couldn't be loaded.");
        return nil;
    }
    id descriptorObject = CFBridgingRelease(rawDescriptor);
    NSString *fullName = CFBridgingRelease(CTFontDescriptorCopyAttribute(rawDescriptor, kCTFontDisplayNameAttribute));
    NSString *assetName = ZSAEString(fields[@"m_Name"]);
    NSString *title = fullName.length > 0 ? fullName : (assetName.length > 0 ? assetName : @"Font");

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = assetName;
    visual.summary = [NSString stringWithFormat:@"Font  •  %@  •  %@", title,
                      [NSByteCountFormatter stringFromByteCount:(long long)fontData.length countStyle:NSByteCountFormatterCountStyleFile]];
    visual.pageLabels = @[@"Specimen"];
    visual.exportData = nil;
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        CTFontDescriptorRef descriptor = (__bridge CTFontDescriptorRef)descriptorObject;
        NSArray<NSArray *> *rows = @[
            @[@56, @"ABCDEFGHIJKLM"],
            @[@56, @"NOPQRSTUVWXYZ"],
            @[@56, @"abcdefghijklm"],
            @[@56, @"nopqrstuvwxyz"],
            @[@56, @"0123456789 !?&@#%"],
            @[@30, @"The quick brown fox jumps over the lazy dog."],
            @[@18, @"The quick brown fox jumps over the lazy dog."],
        ];
        CGFloat width = 1100;
        CGFloat margin = 40;
        NSMutableArray<NSAttributedString *> *lines = [NSMutableArray array];
        UIFont *captionFont = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
        [lines addObject:[[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: captionFont,
                                                                                        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55]}]];
        for (NSArray *row in rows) {
            CGFloat size = [row[0] doubleValue];
            UIFont *font = CFBridgingRelease(CTFontCreateWithFontDescriptor(descriptor, size, NULL));
            if (!font) continue;
            [lines addObject:[[NSAttributedString alloc] initWithString:row[1] attributes:@{NSFontAttributeName: font,
                                                                                            NSForegroundColorAttributeName: UIColor.whiteColor}]];
        }
        NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
        CGFloat total = margin * 2;
        for (NSAttributedString *line in lines) {
            CGRect bounds = [line boundingRectWithSize:CGSizeMake(width - margin * 2, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin context:nil];
            CGFloat height = ceil(bounds.size.height);
            [heights addObject:@(height)];
            total += height + 16;
        }
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = YES;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(width, total) format:format];
        return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor colorWithWhite:0.12 alpha:1] setFill];
            UIRectFill(CGRectMake(0, 0, width, total));
            CGFloat y = margin;
            for (NSUInteger i = 0; i < lines.count; i++) {
                CGFloat height = heights[i].doubleValue;
                [lines[i] drawInRect:CGRectMake(margin, y, width - margin * 2, height)];
                y += height + 16;
            }
        }];
    };
    return visual;
}

@interface ZSAEVideoTempFile : NSObject
@property (nonatomic, copy) NSString *path;
@end

@implementation ZSAEVideoTempFile
- (void)dealloc {
    if (_path.length > 0) [[NSFileManager defaultManager] removeItemAtPath:_path error:nil];
}
@end

static NSString *ZSAEVideoExtension(NSData *data) {
    const uint8_t *b = data.bytes;
    if (data.length >= 12 && memcmp(b + 4, "ftyp", 4) == 0) return memcmp(b + 8, "qt  ", 4) == 0 ? @"mov" : @"mp4";
    if (data.length >= 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) return @"webm";
    if (data.length >= 12 && memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "AVI ", 4) == 0) return @"avi";
    if (data.length >= 4 && memcmp(b, "OggS", 4) == 0) return @"ogv";
    return @"mp4";
}

static NSData *ZSAEVideoClipData(ZSAEObject *object, NSString **outExtension, NSError **error) {
    NSDictionary *resource = ZSAEDict(object.fields[@"m_ExternalResources"]);
    uint64_t offset = (uint64_t)ZSAEInt(resource[@"m_Offset"]);
    uint64_t size = (uint64_t)ZSAEInt(resource[@"m_Size"]);
    if (size == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"This video clip has no video data.");
        return nil;
    }
    if (size > 600ull * 1024ull * 1024ull) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"This video clip is too large to load.");
        return nil;
    }
    NSData *data = ZSAELoadPixels(object.session, nil, ZSAEString(resource[@"m_Source"]), offset, size, error);
    if (data.length < 12) {
        if (error && !*error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The video data wasn't found in the bundle.");
        return nil;
    }
    if (outExtension) *outExtension = ZSAEVideoExtension(data);
    return data;
}

static ZSAssetExplorerVisual *ZSAEBuildVideoClipVisual(ZSAEObject *object, NSError **error) {
    NSDictionary *fields = object.fields;
    NSString *extension = nil;
    NSData *video = ZSAEVideoClipData(object, &extension, error);
    if (!video) return nil;

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSAEVideo-%@.%@", NSUUID.UUID.UUIDString, extension]];
    if (![video writeToFile:path atomically:NO]) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't stage the video for playback.");
        return nil;
    }
    ZSAEVideoTempFile *holder = [ZSAEVideoTempFile new];
    holder.path = path;
    NSData *mapped = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] ?: video;
    video = nil;

    NSString *name = ZSAEString(fields[@"m_Name"]);
    NSUInteger byteCount = mapped.length;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    BOOL playable = asset.playable && track != nil;
    double duration = playable ? CMTimeGetSeconds(asset.duration) : 0;
    double nominalRate = track ? track.nominalFrameRate : 0;
    CGSize natural = track ? CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform) : CGSizeZero;
#pragma clang diagnostic pop

    double fps = ZSAEDouble(fields[@"m_FrameRate"]);
    if (fps <= 0) fps = nominalRate;
    if (fps <= 0) fps = 30;
    int64_t frameCount = ZSAEInt(fields[@"m_FrameCount"]);
    if (!(duration > 0) && frameCount > 0) duration = (double)frameCount / fps;

    if (!playable || !(duration > 0) || isnan(duration) || isinf(duration)) {
        ZSAssetExplorerVisual *fallback = ZSAEBuildInspectorVisual(object, error);
        if (fallback) fallback.summary = [NSString stringWithFormat:@"%@  •  VideoClip  •  .%@ can't be previewed on iOS", name.length > 0 ? name : @"Video", extension];
        return fallback;
    }

    NSInteger width = (NSInteger)ZSAEInt(fields[@"Width"]);
    NSInteger height = (NSInteger)ZSAEInt(fields[@"Height"]);
    if (width <= 0 || height <= 0) {
        width = (NSInteger)fabs(natural.width);
        height = (NSInteger)fabs(natural.height);
    }

    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(1280, 1280);
    CMTime tolerance = CMTimeMakeWithSeconds(0.5 / fps, 600);
    generator.requestedTimeToleranceBefore = tolerance;
    generator.requestedTimeToleranceAfter = tolerance;

    double totalDuration = duration;
    UIImage *(^frameAt)(double) = ^UIImage *(double seconds) {
        if (!holder) return nil;
        double t = MIN(MAX(seconds, 0), MAX(totalDuration - 0.001, 0));
        CGImageRef cgImage = NULL;
        @synchronized (generator) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            cgImage = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(t, 600) actualTime:NULL error:NULL];
#pragma clang diagnostic pop
        }
        if (!cgImage) return nil;
        UIImage *image = [UIImage imageWithCGImage:cgImage];
        CGImageRelease(cgImage);
        return image;
    };

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = name;
    visual.summary = [NSString stringWithFormat:@"%@  •  Video  •  %ldx%ld  •  %.2fs  •  %.0f fps  •  %@", name.length > 0 ? name : @"VideoClip",
                      (long)width, (long)height, totalDuration, fps,
                      [NSByteCountFormatter stringFromByteCount:(long long)byteCount countStyle:NSByteCountFormatterCountStyleFile]];
    visual.pageLabels = @[@"Video"];
    visual.livePageIndex = 0;
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        UIImage *image = frameAt(0);
        if (!image && providerError) *providerError = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"Couldn't decode a frame from this video.");
        return image;
    };
    visual.liveFrameProvider = ^UIImage *(NSTimeInterval elapsed) {
        return frameAt(fmod(elapsed, totalDuration));
    };
    visual.exportData = mapped;
    visual.fileExtension = extension;
    return visual;
}

static NSArray<NSDictionary *> *ZSAENamedPairs(id list) {
    NSMutableArray<NSDictionary *> *pairs = [NSMutableArray array];
    for (id item in ZSAEArray(list) ?: @[]) {
        NSDictionary *pair = ZSAEDict(item);
        id first = pair[@"first"];
        NSString *name = ZSAEString(first) ?: ZSAEString(ZSAEDict(first)[@"name"]);
        if (name.length == 0 || !pair[@"second"]) continue;
        [pairs addObject:@{@"name": name, @"value": pair[@"second"]}];
    }
    return [pairs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
}

static NSString *ZSAEColorText(NSDictionary *color) {
    double r = ZSAEDouble(color[@"r"]);
    double g = ZSAEDouble(color[@"g"]);
    double b = ZSAEDouble(color[@"b"]);
    double a = ZSAEDouble(color[@"a"]);
    int ri = (int)lround(MAX(0, MIN(1, r)) * 255);
    int gi = (int)lround(MAX(0, MIN(1, g)) * 255);
    int bi = (int)lround(MAX(0, MIN(1, b)) * 255);
    int ai = (int)lround(MAX(0, MIN(1, a)) * 255);
    return [NSString stringWithFormat:@"(%.3g, %.3g, %.3g, %.3g)  #%02X%02X%02X%02X", r, g, b, a, ri, gi, bi, ai];
}

static ZSAssetExplorerVisual *ZSAEBuildMaterialVisual(ZSAEContext *context, ZSAEObject *material, NSError **error) {
    NSDictionary *fields = material.fields;
    NSDictionary *saved = ZSAEDict(fields[@"m_SavedProperties"]);
    if (!saved) return ZSAEBuildInspectorVisual(material, error);

    NSMutableString *text = [NSMutableString string];
    NSString *shaderName = nil;
    ZSAEObject *shader = ZSAEResolvePPtr(context, material, fields[@"m_Shader"], nil);
    if (shader) {
        NSDictionary *parsed = ZSAEDict(shader.fields[@"m_ParsedForm"]);
        shaderName = ZSAEString(parsed[@"m_Name"]);
        if (shaderName.length == 0) shaderName = ZSAEString(shader.fields[@"m_Name"]);
    }
    NSDictionary *shaderPointer = ZSAEDict(fields[@"m_Shader"]);
    [text appendFormat:@"Shader: %@\n", shaderName.length > 0 ? shaderName : (shaderPointer ? ZSAEPPtrText(shaderPointer) : @"Unknown")];
    NSString *keywords = ZSAEString(fields[@"m_ShaderKeywords"]);
    if (keywords.length > 0) [text appendFormat:@"Keywords: %@\n", keywords];
    NSArray *keywordList = ZSAEArray(fields[@"m_ValidKeywords"]);
    if (keywords.length == 0 && keywordList.count > 0) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (id keyword in keywordList) if (ZSAEString(keyword)) [names addObject:keyword];
        if (names.count > 0) [text appendFormat:@"Keywords: %@\n", [names componentsJoinedByString:@" "]];
    }
    if (fields[@"m_CustomRenderQueue"]) [text appendFormat:@"Render queue: %lld\n", (long long)ZSAEInt(fields[@"m_CustomRenderQueue"])];

    NSArray<NSDictionary *> *textures = ZSAENamedPairs(saved[@"m_TexEnvs"]);
    NSUInteger textureCount = 0;
    NSMutableString *textureText = [NSMutableString string];
    NSUInteger resolved = 0;
    for (NSDictionary *entry in textures) {
        NSDictionary *value = ZSAEDict(entry[@"value"]);
        NSDictionary *pointer = ZSAEDict(value[@"m_Texture"]);
        if (!pointer || ZSAEInt(pointer[@"m_PathID"]) == 0) continue;
        textureCount++;
        NSString *label = ZSAEPPtrText(pointer);
        if (resolved < 8) {
            resolved++;
            ZSAEObject *texture = ZSAEResolvePPtr(context, material, pointer, nil);
            NSString *textureName = ZSAEString(texture.fields[@"m_Name"]);
            if (textureName.length > 0) label = [NSString stringWithFormat:@"%@  (%@)", textureName, label];
        }
        NSDictionary *scale = ZSAEDict(value[@"m_Scale"]);
        NSDictionary *offset = ZSAEDict(value[@"m_Offset"]);
        [textureText appendFormat:@"  %@  →  %@\n", entry[@"name"], label];
        if (scale || offset) {
            [textureText appendFormat:@"      scale %.4g, %.4g   offset %.4g, %.4g\n",
             ZSAEDouble(scale[@"x"]), ZSAEDouble(scale[@"y"]), ZSAEDouble(offset[@"x"]), ZSAEDouble(offset[@"y"])];
        }
    }
    if (textureCount > 0) [text appendFormat:@"\nTextures (%lu)\n%@", (unsigned long)textureCount, textureText];

    NSArray<NSDictionary *> *floats = ZSAENamedPairs(saved[@"m_Floats"]);
    if (floats.count > 0) {
        [text appendFormat:@"\nFloats (%lu)\n", (unsigned long)floats.count];
        for (NSDictionary *entry in floats) [text appendFormat:@"  %@ = %@\n", entry[@"name"], ZSAEScalarText(entry[@"value"])];
    }
    NSArray<NSDictionary *> *ints = ZSAENamedPairs(saved[@"m_Ints"]);
    if (ints.count > 0) {
        [text appendFormat:@"\nInts (%lu)\n", (unsigned long)ints.count];
        for (NSDictionary *entry in ints) [text appendFormat:@"  %@ = %@\n", entry[@"name"], ZSAEScalarText(entry[@"value"])];
    }
    NSArray<NSDictionary *> *colors = ZSAENamedPairs(saved[@"m_Colors"]);
    if (colors.count > 0) {
        [text appendFormat:@"\nColors (%lu)\n", (unsigned long)colors.count];
        for (NSDictionary *entry in colors) {
            NSDictionary *color = ZSAEDict(entry[@"value"]);
            [text appendFormat:@"  %@ = %@\n", entry[@"name"], color ? ZSAEColorText(color) : ZSAEScalarText(entry[@"value"])];
        }
    }

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = ZSAEString(fields[@"m_Name"]);
    NSString *label = visual.name.length > 0 ? visual.name : @"Material";
    visual.summary = shaderName.length > 0 ? [NSString stringWithFormat:@"%@  •  %@", label, shaderName] : label;
    visual.pageLabels = @[@"Material"];
    visual.text = text;
    visual.exportData = [text dataUsingEncoding:NSUTF8StringEncoding];
    visual.fileExtension = @"txt";
    return visual;
}

static NSString *ZSAEClassLabel(int32_t classID) {
    switch (classID) {
        case 1: return @"GameObject";
        case 4: return @"Transform";
        case 20: return @"Camera";
        case 23: return @"MeshRenderer";
        case 33: return @"MeshFilter";
        case 50: return @"Rigidbody2D";
        case 58: return @"CircleCollider2D";
        case 60: return @"PolygonCollider2D";
        case 61: return @"BoxCollider2D";
        case 64: return @"MeshCollider";
        case 65: return @"BoxCollider";
        case 82: return @"AudioSource";
        case 95: return @"Animator";
        case 114: return @"MonoBehaviour";
        case 120: return @"LineRenderer";
        case 198: return @"ParticleSystem";
        case 199: return @"ParticleSystemRenderer";
        case 210: return @"SortingGroup";
        case 212: return @"SpriteRenderer";
        case 222: return @"CanvasRenderer";
        case 223: return @"Canvas";
        case 224: return @"RectTransform";
        case 225: return @"CanvasGroup";
        default: return [NSString stringWithFormat:@"Class %d", classID];
    }
}

typedef struct {
    uint32_t i0, i1, i2;
    uint32_t sub;
    float depth;
} ZSAEMeshTri;

static int ZSAEMeshTriCompare(const void *a, const void *b) {
    float da = ((const ZSAEMeshTri *)a)->depth;
    float db = ((const ZSAEMeshTri *)b)->depth;
    return da < db ? 1 : (da > db ? -1 : 0);
}

@interface ZSAEMeshData : NSObject {
@public
    float lo[3];
    float hi[3];
}
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSUInteger vertexCount;
@property (nonatomic, strong) NSData *positions;
@property (nonatomic, strong) NSData *uvs;
@property (nonatomic, strong) NSArray<NSData *> *triangles;
@end

@implementation ZSAEMeshData
@end

static float ZSAEHalfToFloat(uint16_t half) {
    uint32_t sign = (half >> 15) & 1u;
    uint32_t exponent = (half >> 10) & 0x1Fu;
    uint32_t mantissa = half & 0x3FFu;
    float value;
    if (exponent == 0) value = ldexpf((float)mantissa, -24);
    else if (exponent == 31) value = mantissa ? NAN : INFINITY;
    else value = ldexpf((float)(mantissa | 0x400u), (int)exponent - 25);
    return sign ? -value : value;
}

static NSUInteger ZSAEMeshFormatSize(int64_t format) {
    switch (format) {
        case 0: case 10: case 11: return 4;
        case 1: case 4: case 5: case 8: case 9: return 2;
        default: return 1;
    }
}

static float ZSAEMeshReadComponent(const uint8_t *p, int64_t format) {
    switch (format) {
        case 0: { float v; memcpy(&v, p, 4); return v; }
        case 1: { uint16_t v; memcpy(&v, p, 2); return ZSAEHalfToFloat(v); }
        case 2: return (float)p[0] / 255.0f;
        case 3: return MAX((float)(int8_t)p[0] / 127.0f, -1.0f);
        case 4: { uint16_t v; memcpy(&v, p, 2); return (float)v / 65535.0f; }
        case 5: { int16_t v; memcpy(&v, p, 2); return MAX((float)v / 32767.0f, -1.0f); }
        case 6: return (float)p[0];
        case 7: return (float)(int8_t)p[0];
        case 8: { uint16_t v; memcpy(&v, p, 2); return (float)v; }
        case 9: { int16_t v; memcpy(&v, p, 2); return (float)v; }
        case 10: { uint32_t v; memcpy(&v, p, 4); return (float)v; }
        case 11: { int32_t v; memcpy(&v, p, 4); return (float)v; }
        default: return 0;
    }
}

static NSData *ZSAEMeshReadChannel(NSData *blob, NSDictionary *channel, NSUInteger vertexCount, NSUInteger streamOffset, NSUInteger stride, NSUInteger components) {
    int64_t format = ZSAEInt(channel[@"format"]);
    NSUInteger dimension = (NSUInteger)(ZSAEInt(channel[@"dimension"]) & 0xF);
    NSUInteger offset = (NSUInteger)ZSAEInt(channel[@"offset"]);
    NSUInteger componentSize = ZSAEMeshFormatSize(format);
    if (dimension == 0 || vertexCount == 0) return nil;
    NSUInteger last = streamOffset + (vertexCount - 1) * stride + offset + dimension * componentSize;
    if (last > blob.length) return nil;

    NSMutableData *output = [NSMutableData dataWithLength:vertexCount * components * sizeof(float)];
    float *out = output.mutableBytes;
    const uint8_t *base = blob.bytes;
    NSUInteger usable = MIN(dimension, components);
    for (NSUInteger i = 0; i < vertexCount; i++) {
        const uint8_t *vertex = base + streamOffset + i * stride + offset;
        for (NSUInteger c = 0; c < usable; c++) out[i * components + c] = ZSAEMeshReadComponent(vertex + c * componentSize, format);
    }
    return output;
}

static BOOL ZSAEMeshReadIndex(NSData *data, NSUInteger byteOffset, NSUInteger size, uint32_t *out) {
    if (byteOffset + size > data.length) return NO;
    const uint8_t *p = (const uint8_t *)data.bytes + byteOffset;
    if (size == 2) {
        uint16_t v;
        memcpy(&v, p, 2);
        *out = v;
    } else {
        uint32_t v;
        memcpy(&v, p, 4);
        *out = v;
    }
    return YES;
}

static ZSAEMeshData *ZSAEParseMesh(ZSAEObject *meshObject, NSString **reason) {
    NSDictionary *fields = meshObject.fields;
    NSDictionary *vertexData = ZSAEDict(fields[@"m_VertexData"]);
    NSUInteger vertexCount = (NSUInteger)MAX(ZSAEInt(vertexData[@"m_VertexCount"]), 0);
    NSData *blob = nil;
    for (id value in vertexData.allValues) {
        if ([value isKindOfClass:[NSData class]] && [(NSData *)value length] > 0) {
            blob = value;
            break;
        }
    }
    NSArray *channels = ZSAEArray(vertexData[@"m_Channels"]);
    if (vertexCount == 0 || !blob || channels.count == 0) {
        if (reason) *reason = @"mesh uses compressed or unsupported vertex data";
        return nil;
    }

    NSUInteger strides[8] = {0};
    for (id entry in channels) {
        NSDictionary *channel = ZSAEDict(entry);
        int64_t stream = ZSAEInt(channel[@"stream"]);
        NSUInteger dimension = (NSUInteger)(ZSAEInt(channel[@"dimension"]) & 0xF);
        if (!channel || stream < 0 || stream >= 8 || dimension == 0) continue;
        NSUInteger end = (NSUInteger)ZSAEInt(channel[@"offset"]) + ZSAEMeshFormatSize(ZSAEInt(channel[@"format"])) * dimension;
        strides[stream] = MAX(strides[stream], end);
    }
    NSUInteger streamOffsets[8] = {0};
    NSUInteger running = 0;
    for (int s = 0; s < 8; s++) {
        streamOffsets[s] = running;
        if (strides[s] > 0) {
            running += strides[s] * vertexCount;
            running = (running + 15u) & ~(NSUInteger)15u;
        }
    }

    NSDictionary *positionChannel = channels.count > 0 ? ZSAEDict(channels[0]) : nil;
    int64_t positionStream = ZSAEInt(positionChannel[@"stream"]);
    if (!positionChannel || positionStream < 0 || positionStream >= 8) {
        if (reason) *reason = @"mesh has no position channel";
        return nil;
    }
    NSData *positions = ZSAEMeshReadChannel(blob, positionChannel, vertexCount, streamOffsets[positionStream], strides[positionStream], 3);
    if (!positions) {
        if (reason) *reason = @"mesh vertex data is truncated";
        return nil;
    }

    NSData *uvs = nil;
    if (channels.count > 4) {
        NSDictionary *uvChannel = ZSAEDict(channels[4]);
        int64_t uvStream = ZSAEInt(uvChannel[@"stream"]);
        if (uvChannel && (ZSAEInt(uvChannel[@"dimension"]) & 0xF) >= 2 && uvStream >= 0 && uvStream < 8) {
            uvs = ZSAEMeshReadChannel(blob, uvChannel, vertexCount, streamOffsets[uvStream], strides[uvStream], 2);
        }
    }

    ZSAEMeshData *mesh = [ZSAEMeshData new];
    mesh.name = ZSAEString(fields[@"m_Name"]);
    mesh.vertexCount = vertexCount;
    mesh.positions = positions;
    mesh.uvs = uvs;

    const float *pos = positions.bytes;
    for (int a = 0; a < 3; a++) {
        mesh->lo[a] = INFINITY;
        mesh->hi[a] = -INFINITY;
    }
    for (NSUInteger i = 0; i < vertexCount; i++) {
        for (int a = 0; a < 3; a++) {
            float v = pos[i * 3 + a];
            if (!isfinite(v)) continue;
            mesh->lo[a] = MIN(mesh->lo[a], v);
            mesh->hi[a] = MAX(mesh->hi[a], v);
        }
    }
    for (int a = 0; a < 3; a++) {
        if (!isfinite(mesh->lo[a]) || !isfinite(mesh->hi[a])) {
            if (reason) *reason = @"mesh has invalid vertex positions";
            return nil;
        }
    }

    NSData *indexData = [fields[@"m_IndexBuffer"] isKindOfClass:[NSData class]] ? fields[@"m_IndexBuffer"] : nil;
    NSUInteger indexSize = 2;
    if (fields[@"m_IndexFormat"]) indexSize = ZSAEInt(fields[@"m_IndexFormat"]) == 1 ? 4 : 2;
    else if (fields[@"m_Use16BitIndices"]) indexSize = ZSAEInt(fields[@"m_Use16BitIndices"]) != 0 ? 2 : 4;
    NSArray *subMeshes = ZSAEArray(fields[@"m_SubMeshes"]);
    if (indexData.length == 0 || subMeshes.count == 0) {
        if (reason) *reason = @"mesh has no index data";
        return nil;
    }

    const NSUInteger kMaxTriangles = 40000;
    NSUInteger total = 0;
    NSMutableArray<NSData *> *triangles = [NSMutableArray arrayWithCapacity:subMeshes.count];
    for (id entry in subMeshes) {
        NSDictionary *sub = ZSAEDict(entry);
        NSMutableData *tris = [NSMutableData data];
        if (sub) {
            NSUInteger first = (NSUInteger)MAX(ZSAEInt(sub[@"firstByte"]), 0);
            NSUInteger count = (NSUInteger)MAX(ZSAEInt(sub[@"indexCount"]), 0);
            int64_t topology = ZSAEInt(sub[@"topology"]);
            int64_t baseVertex = ZSAEInt(sub[@"baseVertex"]);
            NSUInteger step = topology == 2 ? 4 : 3;
            for (NSUInteger k = 0; k + (topology == 1 ? 3 : step) <= count && total < kMaxTriangles; k += (topology == 1 ? 1 : step)) {
                uint32_t raw[4] = {0, 0, 0, 0};
                NSUInteger need = topology == 2 ? 4 : 3;
                BOOL ok = YES;
                for (NSUInteger n = 0; n < need; n++) {
                    if (!ZSAEMeshReadIndex(indexData, first + (k + n) * indexSize, indexSize, &raw[n])) { ok = NO; break; }
                    int64_t shifted = (int64_t)raw[n] + baseVertex;
                    if (shifted < 0 || (NSUInteger)shifted >= vertexCount) { ok = NO; break; }
                    raw[n] = (uint32_t)shifted;
                }
                if (!ok) continue;
                uint32_t tri[6];
                NSUInteger triCount = 0;
                if (topology == 0) {
                    tri[0] = raw[0]; tri[1] = raw[1]; tri[2] = raw[2];
                    triCount = 1;
                } else if (topology == 1) {
                    if (raw[0] == raw[1] || raw[1] == raw[2] || raw[0] == raw[2]) continue;
                    if (k & 1) { tri[0] = raw[1]; tri[1] = raw[0]; tri[2] = raw[2]; }
                    else { tri[0] = raw[0]; tri[1] = raw[1]; tri[2] = raw[2]; }
                    triCount = 1;
                } else if (topology == 2) {
                    tri[0] = raw[0]; tri[1] = raw[1]; tri[2] = raw[2];
                    tri[3] = raw[0]; tri[4] = raw[2]; tri[5] = raw[3];
                    triCount = 2;
                }
                [tris appendBytes:tri length:triCount * 3 * sizeof(uint32_t)];
                total += triCount;
            }
        }
        [triangles addObject:tris];
    }
    if (total == 0) {
        if (reason) *reason = @"mesh has no renderable triangles";
        return nil;
    }
    mesh.triangles = triangles;
    return mesh;
}

static UIImage *ZSAEMeshDownscale(UIImage *image, CGFloat maxDimension) {
    CGFloat longest = MAX(image.size.width, image.size.height);
    if (longest <= maxDimension || longest <= 0) return image;
    CGFloat factor = maxDimension / longest;
    CGSize target = CGSizeMake(MAX(1, floor(image.size.width * factor)), MAX(1, floor(image.size.height * factor)));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

static NSDictionary *ZSAEMeshMaterialEntry(ZSAEContext *context, ZSAEObject *owner, id pointer, NSMutableDictionary *cache) {
    ZSAEObject *material = ZSAEResolvePPtr(context, owner, pointer, NULL);
    if (!material || material.classID != 21) return nil;
    NSDictionary *saved = ZSAEDict(material.fields[@"m_SavedProperties"]);
    NSArray<NSDictionary *> *pairs = ZSAENamedPairs(saved[@"m_TexEnvs"]);

    BOOL (^hasTexture)(NSDictionary *) = ^BOOL(NSDictionary *pair) {
        return ZSAEInt(ZSAEDict(ZSAEDict(pair[@"value"])[@"m_Texture"])[@"m_PathID"]) != 0;
    };
    NSDictionary *chosen = nil;
    NSArray<NSString *> *preferred = @[@"_MainTex", @"_BaseMap", @"_BaseColorMap", @"_Tex", @"_Diffuse", @"_Albedo", @"_Texture"];
    for (NSString *wanted in preferred) {
        for (NSDictionary *pair in pairs) {
            if ([pair[@"name"] isEqualToString:wanted] && hasTexture(pair)) { chosen = pair; break; }
        }
        if (chosen) break;
    }
    if (!chosen) {
        for (NSDictionary *pair in pairs) {
            if (hasTexture(pair)) { chosen = pair; break; }
        }
    }
    if (!chosen) return nil;

    NSDictionary *value = ZSAEDict(chosen[@"value"]);
    ZSAEObject *textureObject = ZSAEResolvePPtr(context, material, value[@"m_Texture"], NULL);
    if (!textureObject || textureObject.classID != 28) return nil;

    NSString *key = [NSString stringWithFormat:@"%p:%lld", textureObject.session, (long long)textureObject.pathID];
    UIImage *image = cache[key];
    NSString *textureName = ZSAEString(textureObject.fields[@"m_Name"]) ?: @"";
    if (!image) {
        ZSAETextureRecord *record = nil;
        NSMutableData *rgba = nil;
        if (!ZSAEDecodeTextureObject(textureObject, &record, &rgba, NULL)) return nil;
        UIImage *full = ZSAEImageFromRGBA(rgba, record.width, record.height);
        if (!full) return nil;
        image = ZSAEMeshDownscale(full, 1024);
        cache[key] = image;
    }

    NSDictionary *scale = ZSAEDict(value[@"m_Scale"]);
    NSDictionary *offset = ZSAEDict(value[@"m_Offset"]);
    double sx = scale ? ZSAEDouble(scale[@"x"]) : 1;
    double sy = scale ? ZSAEDouble(scale[@"y"]) : 1;
    if (sx == 0) sx = 1;
    if (sy == 0) sy = 1;
    return @{@"image": image, @"name": textureName, @"tf": @[@(sx), @(sy), @(ZSAEDouble(offset[@"x"])), @(ZSAEDouble(offset[@"y"]))]};
}

static CGAffineTransform ZSAEMeshAffine(CGPoint t0, CGPoint t1, CGPoint t2, CGPoint p0, CGPoint p1, CGPoint p2, BOOL *ok) {
    double dx1 = t1.x - t0.x, dy1 = t1.y - t0.y;
    double dx2 = t2.x - t0.x, dy2 = t2.y - t0.y;
    double det = dx1 * dy2 - dx2 * dy1;
    if (fabs(det) < 1e-9) {
        *ok = NO;
        return CGAffineTransformIdentity;
    }
    double sx1 = p1.x - p0.x, sy1 = p1.y - p0.y;
    double sx2 = p2.x - p0.x, sy2 = p2.y - p0.y;
    double a = (sx1 * dy2 - sx2 * dy1) / det;
    double c = (sx2 * dx1 - sx1 * dx2) / det;
    double b = (sy1 * dy2 - sy2 * dy1) / det;
    double d = (sy2 * dx1 - sy1 * dx2) / det;
    double tx = p0.x - a * t0.x - c * t0.y;
    double ty = p0.y - b * t0.x - d * t0.y;
    *ok = YES;
    return CGAffineTransformMake(a, b, c, d, tx, ty);
}

static UIImage *ZSAERenderMeshUVMap(ZSAEMeshData *mesh, NSArray *entries, NSError **error) {
    UIImage *base = nil;
    for (id entry in entries) {
        if ([entry isKindOfClass:[NSDictionary class]]) {
            base = entry[@"image"];
            if (base) break;
        }
    }
    if (!mesh.uvs) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"This mesh has no UV coordinates.");
        return nil;
    }
    CGSize size = base ? base.size : CGSizeMake(1024, 1024);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    const float *uv = mesh.uvs.bytes;
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        [[UIColor colorWithWhite:0.1 alpha:1] setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, size.width, size.height));
        if (base) [base drawInRect:CGRectMake(0, 0, size.width, size.height)];
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.85].CGColor);
        CGContextSetLineWidth(ctx, 1);
        for (NSData *tris in mesh.triangles) {
            const uint32_t *idx = tris.bytes;
            NSUInteger count = tris.length / (3 * sizeof(uint32_t));
            for (NSUInteger t = 0; t < count; t++) {
                CGPoint pts[3];
                for (int n = 0; n < 3; n++) {
                    uint32_t i = idx[t * 3 + n];
                    pts[n] = CGPointMake(uv[i * 2] * size.width, (1.0f - uv[i * 2 + 1]) * size.height);
                }
                CGContextMoveToPoint(ctx, pts[0].x, pts[0].y);
                CGContextAddLineToPoint(ctx, pts[1].x, pts[1].y);
                CGContextAddLineToPoint(ctx, pts[2].x, pts[2].y);
                CGContextClosePath(ctx);
                CGContextStrokePath(ctx);
            }
        }
    }];
}

static UIImage *ZSAERenderMesh(ZSAEMeshData *mesh, NSArray *entries, NSInteger page, NSError **error) {
    if (page == 4) return ZSAERenderMeshUVMap(mesh, entries, error);

    int axisU = 0, axisV = 1, axisD = 2;
    if (page == 1) { axisU = 2; axisV = 1; axisD = 0; }
    else if (page == 2) { axisU = 0; axisV = 2; axisD = 1; }
    BOOL wire = page == 3;

    float loU = mesh->lo[axisU], loV = mesh->lo[axisV];
    float extentU = mesh->hi[axisU] - loU;
    float extentV = mesh->hi[axisV] - loV;
    float longest = MAX(extentU, extentV);
    if (!(longest > 1e-6f)) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"This mesh has no extent in this view.");
        return nil;
    }
    CGFloat margin = 32;
    CGFloat scale = 960.0 / longest;
    CGSize size = CGSizeMake(MAX(ceil(extentU * scale), 4) + margin * 2, MAX(ceil(extentV * scale), 4) + margin * 2);

    const float *pos = mesh.positions.bytes;
    const float *uv = mesh.uvs.bytes;

    NSUInteger triCount = 0;
    for (NSData *tris in mesh.triangles) triCount += tris.length / (3 * sizeof(uint32_t));
    ZSAEMeshTri *list = malloc(MAX(triCount, 1) * sizeof(ZSAEMeshTri));
    if (!list) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"Couldn't allocate memory for the mesh preview.");
        return nil;
    }
    NSUInteger n = 0;
    for (NSUInteger s = 0; s < mesh.triangles.count; s++) {
        const uint32_t *idx = mesh.triangles[s].bytes;
        NSUInteger count = mesh.triangles[s].length / (3 * sizeof(uint32_t));
        for (NSUInteger t = 0; t < count; t++) {
            ZSAEMeshTri tri;
            tri.i0 = idx[t * 3];
            tri.i1 = idx[t * 3 + 1];
            tri.i2 = idx[t * 3 + 2];
            tri.sub = (uint32_t)s;
            tri.depth = (pos[tri.i0 * 3 + axisD] + pos[tri.i1 * 3 + axisD] + pos[tri.i2 * 3 + axisD]) / 3.0f;
            list[n++] = tri;
        }
    }
    qsort(list, n, sizeof(ZSAEMeshTri), ZSAEMeshTriCompare);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    CGFloat height = size.height;
    UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        [[UIColor colorWithWhite:0.1 alpha:1] setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, size.width, size.height));
        CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);

        CGPoint (^project)(uint32_t) = ^CGPoint(uint32_t i) {
            return CGPointMake(margin + (pos[i * 3 + axisU] - loU) * scale, height - margin - (pos[i * 3 + axisV] - loV) * scale);
        };

        for (NSUInteger k = 0; k < n; k++) {
            ZSAEMeshTri tri = list[k];
            CGPoint p[3] = { project(tri.i0), project(tri.i1), project(tri.i2) };
            uint32_t ids[3] = { tri.i0, tri.i1, tri.i2 };

            if (wire) {
                CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.9 alpha:0.7].CGColor);
                CGContextSetLineWidth(ctx, 1);
                CGContextMoveToPoint(ctx, p[0].x, p[0].y);
                CGContextAddLineToPoint(ctx, p[1].x, p[1].y);
                CGContextAddLineToPoint(ctx, p[2].x, p[2].y);
                CGContextClosePath(ctx);
                CGContextStrokePath(ctx);
                continue;
            }

            CGPoint centroid = CGPointMake((p[0].x + p[1].x + p[2].x) / 3.0, (p[0].y + p[1].y + p[2].y) / 3.0);
            CGPoint grown[3];
            for (int v = 0; v < 3; v++) {
                CGFloat dx = p[v].x - centroid.x, dy = p[v].y - centroid.y;
                CGFloat length = hypot(dx, dy);
                grown[v] = length > 1e-6 ? CGPointMake(p[v].x + dx / length * 0.6, p[v].y + dy / length * 0.6) : p[v];
            }

            NSDictionary *entry = nil;
            if (entries.count > 0) {
                id candidate = entries[MIN((NSUInteger)tri.sub, entries.count - 1)];
                if ([candidate isKindOfClass:[NSDictionary class]]) entry = candidate;
            }
            UIImage *image = entry[@"image"];

            CGContextSaveGState(ctx);
            CGContextMoveToPoint(ctx, grown[0].x, grown[0].y);
            CGContextAddLineToPoint(ctx, grown[1].x, grown[1].y);
            CGContextAddLineToPoint(ctx, grown[2].x, grown[2].y);
            CGContextClosePath(ctx);

            BOOL drawn = NO;
            if (image && uv) {
                NSArray<NSNumber *> *tf = entry[@"tf"];
                double sx = tf[0].doubleValue, sy = tf[1].doubleValue, ox = tf[2].doubleValue, oy = tf[3].doubleValue;
                CGPoint t[3];
                for (int v = 0; v < 3; v++) {
                    double u = uv[ids[v] * 2] * sx + ox;
                    double w = uv[ids[v] * 2 + 1] * sy + oy;
                    t[v] = CGPointMake(u * image.size.width, (1.0 - w) * image.size.height);
                }
                BOOL ok = NO;
                CGAffineTransform transform = ZSAEMeshAffine(t[0], t[1], t[2], p[0], p[1], p[2], &ok);
                if (ok) {
                    CGContextClip(ctx);
                    CGContextConcatCTM(ctx, transform);
                    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
                    drawn = YES;
                }
            }
            if (!drawn) {
                float ax = pos[ids[1] * 3] - pos[ids[0] * 3], ay = pos[ids[1] * 3 + 1] - pos[ids[0] * 3 + 1], az = pos[ids[1] * 3 + 2] - pos[ids[0] * 3 + 2];
                float bx = pos[ids[2] * 3] - pos[ids[0] * 3], by = pos[ids[2] * 3 + 1] - pos[ids[0] * 3 + 1], bz = pos[ids[2] * 3 + 2] - pos[ids[0] * 3 + 2];
                float normal[3] = { ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx };
                float magnitude = sqrtf(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
                float facing = magnitude > 1e-9f ? fabsf(normal[axisD]) / magnitude : 0.5f;
                CGFloat shade = 0.3 + 0.6 * facing;
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:shade * 0.8 green:shade * 0.88 blue:shade alpha:1].CGColor);
                CGContextFillPath(ctx);
            }
            CGContextRestoreGState(ctx);
        }
    }];
    free(list);
    return result;
}

static ZSAEObject *ZSAEMeshComponent(ZSAEContext *context, ZSAEObject *gameObject, int32_t classA, int32_t classB) {
    for (id entry in ZSAEArray(gameObject.fields[@"m_Component"])) {
        NSDictionary *wrapper = ZSAEDict(entry);
        NSDictionary *pointer = ZSAEDict(wrapper[@"component"]) ?: (ZSAEDict(wrapper[@"second"]) ?: wrapper);
        if (!pointer || ZSAEInt(pointer[@"m_PathID"]) == 0) continue;
        ZSAEObject *candidate = ZSAEResolvePPtr(context, gameObject, pointer, NULL);
        if (candidate && (candidate.classID == classA || candidate.classID == classB)) return candidate;
    }
    return nil;
}

static NSString *ZSAEMeshOBJText(ZSAEMeshData *mesh) {
    NSMutableString *text = [NSMutableString stringWithCapacity:mesh.vertexCount * 48];
    [text appendFormat:@"o %@\n", mesh.name.length > 0 ? mesh.name : @"Mesh"];
    const float *pos = mesh.positions.bytes;
    const float *uv = mesh.uvs.bytes;
    for (NSUInteger i = 0; i < mesh.vertexCount; i++) [text appendFormat:@"v %g %g %g\n", pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]];
    if (uv) for (NSUInteger i = 0; i < mesh.vertexCount; i++) [text appendFormat:@"vt %g %g\n", uv[i * 2], uv[i * 2 + 1]];
    for (NSUInteger s = 0; s < mesh.triangles.count; s++) {
        [text appendFormat:@"g submesh_%lu\n", (unsigned long)s];
        const uint32_t *idx = mesh.triangles[s].bytes;
        NSUInteger count = mesh.triangles[s].length / (3 * sizeof(uint32_t));
        for (NSUInteger t = 0; t < count; t++) {
            unsigned a = idx[t * 3] + 1, b = idx[t * 3 + 1] + 1, c = idx[t * 3 + 2] + 1;
            if (uv) [text appendFormat:@"f %u/%u %u/%u %u/%u\n", a, a, b, b, c, c];
            else [text appendFormat:@"f %u %u %u\n", a, b, c];
        }
    }
    return text;
}

static ZSAssetExplorerVisual *ZSAEBuildMeshVisual(ZSAEContext *context, ZSAEObject *object, NSError **error) {
    NSString *kind = object.classID == 23 ? @"MeshRenderer" : (object.classID == 137 ? @"SkinnedMeshRenderer" : (object.classID == 33 ? @"MeshFilter" : @"Mesh"));
    ZSAEObject *renderer = nil;
    ZSAEObject *meshObject = nil;

    if (object.classID == 43) {
        meshObject = object;
    } else if (object.classID == 137) {
        renderer = object;
        meshObject = ZSAEResolvePPtr(context, object, object.fields[@"m_Mesh"], NULL);
    } else if (object.classID == 33) {
        meshObject = ZSAEResolvePPtr(context, object, object.fields[@"m_Mesh"], NULL);
        ZSAEObject *gameObject = ZSAEResolvePPtr(context, object, object.fields[@"m_GameObject"], NULL);
        if (gameObject) renderer = ZSAEMeshComponent(context, gameObject, 23, 137);
    } else {
        renderer = object;
        ZSAEObject *gameObject = ZSAEResolvePPtr(context, object, object.fields[@"m_GameObject"], NULL);
        ZSAEObject *filter = gameObject ? ZSAEMeshComponent(context, gameObject, 33, 33) : nil;
        if (filter) meshObject = ZSAEResolvePPtr(context, filter, filter.fields[@"m_Mesh"], NULL);
    }

    NSString *reason = nil;
    ZSAEMeshData *mesh = nil;
    if (!meshObject || meshObject.classID != 43) reason = @"no mesh is assigned or it isn't available in the cache";
    else mesh = ZSAEParseMesh(meshObject, &reason);
    if (!mesh) {
        ZSAssetExplorerVisual *fallback = ZSAEBuildInspectorVisual(object, error);
        if (fallback) fallback.summary = [NSString stringWithFormat:@"%@  •  %@  •  can't be previewed: %@", fallback.name.length > 0 ? fallback.name : kind, kind, reason ?: @"unsupported mesh"];
        return fallback;
    }

    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    NSMutableArray *entries = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *textureNames = [NSMutableOrderedSet orderedSet];
    if (renderer) {
        for (id pointer in ZSAEArray(renderer.fields[@"m_Materials"])) {
            NSDictionary *entry = ZSAEMeshMaterialEntry(context, renderer, pointer, cache);
            [entries addObject:entry ?: (id)[NSNull null]];
            NSString *textureName = entry[@"name"];
            if (textureName.length > 0) [textureNames addObject:textureName];
        }
    }

    NSString *gameObjectName = nil;
    if (renderer) {
        ZSAEObject *gameObject = ZSAEResolvePPtr(context, renderer, renderer.fields[@"m_GameObject"], NULL);
        gameObjectName = ZSAEString(gameObject.fields[@"m_Name"]);
    }
    NSString *label = gameObjectName.length > 0 ? gameObjectName : (mesh.name.length > 0 ? mesh.name : kind);
    NSUInteger triangleCount = 0;
    for (NSData *tris in mesh.triangles) triangleCount += tris.length / (3 * sizeof(uint32_t));

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = label;
    visual.summary = [NSString stringWithFormat:@"%@  •  %@  •  %lu vertices  •  %lu triangles  •  %lu submesh%@  •  %@", label, kind,
                      (unsigned long)mesh.vertexCount, (unsigned long)triangleCount,
                      (unsigned long)mesh.triangles.count, mesh.triangles.count == 1 ? @"" : @"es",
                      textureNames.count > 0 ? [textureNames.array componentsJoinedByString:@", "] : @"no texture"];
    visual.pageLabels = @[@"Front", @"Side", @"Top", @"Wireframe", @"UV Map"];
    NSArray *frozen = [entries copy];
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        return ZSAERenderMesh(mesh, frozen, page, providerError);
    };
    NSString *obj = ZSAEMeshOBJText(mesh);
    visual.exportData = [obj dataUsingEncoding:NSUTF8StringEncoding];
    visual.fileExtension = @"obj";
    return visual;
}

@interface ZSAEGraphState : NSObject
@property (nonatomic, strong) ZSAEContext *context;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property (nonatomic, strong) NSMutableString *outline;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZSAEObject *> *sprites;
@property (nonatomic, assign) NSUInteger reads;
@property (nonatomic, assign) NSUInteger nodes;
@property (nonatomic, assign) BOOL truncated;
@end

@implementation ZSAEGraphState
@end

static ZSAEObject *ZSAEGraphRead(ZSAEGraphState *state, ZSAEObject *owner, id pointer) {
    if (state.reads >= 6000) {
        state.truncated = YES;
        return nil;
    }
    state.reads++;
    return ZSAEResolvePPtr(state.context, owner, pointer, NULL);
}

static void ZSAEWalkGameObject(ZSAEGraphState *state, ZSAEObject *go, CGAffineTransform parent, double parentZ, NSUInteger depth, BOOL isRoot) {
    if (state.nodes >= 1500 || depth > 32) {
        state.truncated = YES;
        return;
    }
    state.nodes++;

    NSDictionary *fields = go.fields;
    NSString *name = ZSAEString(fields[@"m_Name"]);
    if (name.length == 0) name = @"GameObject";
    BOOL active = fields[@"m_IsActive"] ? ZSAEInt(fields[@"m_IsActive"]) != 0 : YES;

    ZSAEObject *transform = nil;
    NSMutableArray<ZSAEObject *> *others = [NSMutableArray array];
    for (id entry in ZSAEArray(fields[@"m_Component"])) {
        NSDictionary *pair = ZSAEDict(entry);
        id pointer = pair[@"component"] ?: pair[@"second"];
        if (!pointer) continue;
        ZSAEObject *component = ZSAEGraphRead(state, go, pointer);
        if (!component) continue;
        if (component.classID == 4 || component.classID == 224) {
            if (!transform) transform = component;
        } else {
            [others addObject:component];
        }
    }

    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    if (transform) [labels addObject:ZSAEClassLabel(transform.classID)];
    for (ZSAEObject *component in others) [labels addObject:ZSAEClassLabel(component.classID)];
    NSString *pad = [@"" stringByPaddingToLength:MIN(depth, (NSUInteger)32) * 2 withString:@" " startingAtIndex:0];
    [state.outline appendFormat:@"%@%@%@  [%@]\n", pad, name, active ? @"" : @"  (inactive)", [labels componentsJoinedByString:@", "]];

    CGAffineTransform local = CGAffineTransformIdentity;
    double localZ = 0;
    if (transform && !isRoot) {
        NSDictionary *position = ZSAEDict(transform.fields[@"m_LocalPosition"]);
        NSDictionary *rotation = ZSAEDict(transform.fields[@"m_LocalRotation"]);
        NSDictionary *scale = ZSAEDict(transform.fields[@"m_LocalScale"]);
        double sx = scale ? ZSAEDouble(scale[@"x"]) : 1;
        double sy = scale ? ZSAEDouble(scale[@"y"]) : 1;
        double qx = ZSAEDouble(rotation[@"x"]);
        double qy = ZSAEDouble(rotation[@"y"]);
        double qz = ZSAEDouble(rotation[@"z"]);
        double qw = rotation ? ZSAEDouble(rotation[@"w"]) : 1;
        double angle = atan2(2.0 * (qw * qz + qx * qy), 1.0 - 2.0 * (qy * qy + qz * qz));
        local = CGAffineTransformMakeScale(sx, sy);
        local = CGAffineTransformConcat(local, CGAffineTransformMakeRotation(angle));
        local = CGAffineTransformConcat(local, CGAffineTransformMakeTranslation(ZSAEDouble(position[@"x"]), ZSAEDouble(position[@"y"])));
        localZ = ZSAEDouble(position[@"z"]);
    }
    CGAffineTransform world = CGAffineTransformConcat(local, parent);
    double worldZ = parentZ + localZ;
    if (!active && !isRoot) return;

    for (ZSAEObject *component in others) {
        if (component.classID != 212) continue;
        NSDictionary *componentFields = component.fields;
        if (componentFields[@"m_Enabled"] && ZSAEInt(componentFields[@"m_Enabled"]) == 0) continue;
        NSDictionary *spritePointer = ZSAEDict(componentFields[@"m_Sprite"]);
        if (!spritePointer || ZSAEInt(spritePointer[@"m_PathID"]) == 0) continue;
        NSString *key = [NSString stringWithFormat:@"%p:%lld:%lld", go.session, (long long)ZSAEInt(spritePointer[@"m_FileID"]), (long long)ZSAEInt(spritePointer[@"m_PathID"])];
        ZSAEObject *sprite = state.sprites[key];
        if (!sprite) {
            ZSAEObject *resolved = ZSAEGraphRead(state, component, spritePointer);
            if (resolved && resolved.classID == 213) {
                sprite = resolved;
                state.sprites[key] = sprite;
            }
        }
        if (!sprite) continue;
        NSDictionary *color = ZSAEDict(componentFields[@"m_Color"]);
        [state.items addObject:@{
            @"key": key,
            @"sprite": sprite,
            @"transform": [NSValue valueWithCGAffineTransform:world],
            @"z": @(worldZ),
            @"r": @(color ? ZSAEDouble(color[@"r"]) : 1.0),
            @"g": @(color ? ZSAEDouble(color[@"g"]) : 1.0),
            @"b": @(color ? ZSAEDouble(color[@"b"]) : 1.0),
            @"a": @(color ? ZSAEDouble(color[@"a"]) : 1.0),
            @"flipX": @(ZSAEInt(componentFields[@"m_FlipX"]) != 0),
            @"flipY": @(ZSAEInt(componentFields[@"m_FlipY"]) != 0),
            @"layer": @(ZSAEInt(componentFields[@"m_SortingLayer"])),
            @"order": @(ZSAEInt(componentFields[@"m_SortingOrder"])),
            @"index": @(state.items.count),
        }];
    }

    if (!transform) return;
    for (id childPointer in ZSAEArray(transform.fields[@"m_Children"])) {
        ZSAEObject *childTransform = ZSAEGraphRead(state, transform, childPointer);
        if (!childTransform) continue;
        ZSAEObject *childObject = ZSAEGraphRead(state, childTransform, childTransform.fields[@"m_GameObject"]);
        if (!childObject || childObject.classID != 1) continue;
        ZSAEWalkGameObject(state, childObject, world, worldZ, depth + 1, NO);
    }
}

static UIImage *ZSAETintedImage(UIImage *image, double r, double g, double b) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    CGRect rect = CGRectMake(0, 0, image.size.width, image.size.height);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size format:format];
    UIColor *tint = [UIColor colorWithRed:MAX(0, MIN(1, r)) green:MAX(0, MIN(1, g)) blue:MAX(0, MIN(1, b)) alpha:1];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:rect];
        [tint setFill];
        UIRectFillUsingBlendMode(rect, kCGBlendModeMultiply);
        [image drawInRect:rect blendMode:kCGBlendModeDestinationIn alpha:1];
    }];
}

static UIImage *ZSAERenderComposite(ZSAEContext *context, NSArray<NSDictionary *> *items, NSError **error) {
    NSMutableDictionary<NSString *, ZSAEObject *> *distinct = [NSMutableDictionary dictionary];
    for (NSDictionary *item in items) distinct[item[@"key"]] = item[@"sprite"];
    NSArray<NSString *> *keys = [distinct.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSComparisonResult result = [ZSAESpriteGroupKey(distinct[a]) compare:ZSAESpriteGroupKey(distinct[b])];
        return result != NSOrderedSame ? result : [a compare:b];
    }];

    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    cache[@"atlases"] = [NSMutableDictionary dictionary];
    cache[@"textures"] = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, ZSAESpriteImage *> *images = [NSMutableDictionary dictionary];
    NSError *firstError = nil;
    for (NSString *key in keys) {
        NSError *spriteError = nil;
        ZSAESpriteImage *result = ZSAEMakeSpriteImage(context, distinct[key], cache, &spriteError);
        if (result) images[key] = result;
        else if (!firstError) firstError = spriteError;
    }
    if (images.count == 0) {
        if (error) *error = firstError ?: ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"None of the sprites in this object could be decoded.");
        return nil;
    }

    NSArray<NSDictionary *> *ordered = [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        int64_t layerA = ZSAEInt(a[@"layer"]);
        int64_t layerB = ZSAEInt(b[@"layer"]);
        if (layerA != layerB) return layerA < layerB ? NSOrderedAscending : NSOrderedDescending;
        int64_t orderA = ZSAEInt(a[@"order"]);
        int64_t orderB = ZSAEInt(b[@"order"]);
        if (orderA != orderB) return orderA < orderB ? NSOrderedAscending : NSOrderedDescending;
        double zA = ZSAEDouble(a[@"z"]);
        double zB = ZSAEDouble(b[@"z"]);
        if (zA != zB) return zA > zB ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"index"] compare:b[@"index"]];
    }];

    double minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY, maxPPU = 1;
    NSMutableArray<NSDictionary *> *drawable = [NSMutableArray array];
    for (NSDictionary *item in ordered) {
        ZSAESpriteImage *sprite = images[item[@"key"]];
        if (!sprite) continue;
        CGAffineTransform world = [item[@"transform"] CGAffineTransformValue];
        double x0 = (sprite.offsetX - sprite.pivotX * sprite.rectWidth) / sprite.pixelsPerUnit;
        double y0 = (sprite.offsetY - sprite.pivotY * sprite.rectHeight) / sprite.pixelsPerUnit;
        double qw = sprite.width / sprite.pixelsPerUnit;
        double qh = sprite.height / sprite.pixelsPerUnit;
        double fx = [item[@"flipX"] boolValue] ? -1 : 1;
        double fy = [item[@"flipY"] boolValue] ? -1 : 1;
        BOOL valid = YES;
        double cornersX[2] = {x0, x0 + qw};
        double cornersY[2] = {y0, y0 + qh};
        for (int i = 0; i < 2; i++) {
            for (int j = 0; j < 2; j++) {
                CGPoint point = CGPointApplyAffineTransform(CGPointMake(cornersX[i] * fx, cornersY[j] * fy), world);
                if (!isfinite(point.x) || !isfinite(point.y)) { valid = NO; continue; }
                minX = MIN(minX, point.x);
                maxX = MAX(maxX, point.x);
                minY = MIN(minY, point.y);
                maxY = MAX(maxY, point.y);
            }
        }
        if (!valid) continue;
        maxPPU = MAX(maxPPU, sprite.pixelsPerUnit);
        [drawable addObject:item];
    }

    double boundsWidth = maxX - minX;
    double boundsHeight = maxY - minY;
    if (drawable.count == 0 || !(boundsWidth > 0) || !(boundsHeight > 0)) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"The sprites in this object have no visible area.");
        return nil;
    }

    double scale = MIN(2048.0 / MAX(boundsWidth, boundsHeight), maxPPU);
    CGFloat pad = 8;
    CGFloat canvasWidth = MAX(16, ceil(boundsWidth * scale) + pad * 2);
    CGFloat canvasHeight = MAX(16, ceil(boundsHeight * scale) + pad * 2);
    CGAffineTransform worldToPixel = CGAffineTransformMake(scale, 0, 0, -scale, -minX * scale + pad, maxY * scale + pad);

    NSMutableDictionary<NSString *, UIImage *> *tinted = [NSMutableDictionary dictionary];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(canvasWidth, canvasHeight) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef cg = rendererContext.CGContext;
        CGContextSetInterpolationQuality(cg, kCGInterpolationHigh);
        for (NSDictionary *item in drawable) {
            ZSAESpriteImage *sprite = images[item[@"key"]];
            double alpha = MAX(0, MIN(1, ZSAEDouble(item[@"a"])));
            if (alpha <= 0) continue;
            UIImage *image = sprite.image;
            double r = ZSAEDouble(item[@"r"]);
            double g = ZSAEDouble(item[@"g"]);
            double b = ZSAEDouble(item[@"b"]);
            if (r < 0.999 || g < 0.999 || b < 0.999) {
                NSString *tintKey = [NSString stringWithFormat:@"%@:%.3f:%.3f:%.3f", item[@"key"], r, g, b];
                UIImage *cachedTint = tinted[tintKey];
                if (!cachedTint) {
                    cachedTint = ZSAETintedImage(image, r, g, b);
                    if (cachedTint) tinted[tintKey] = cachedTint;
                }
                if (cachedTint) image = cachedTint;
            }
            double x0 = (sprite.offsetX - sprite.pivotX * sprite.rectWidth) / sprite.pixelsPerUnit;
            double y0 = (sprite.offsetY - sprite.pivotY * sprite.rectHeight) / sprite.pixelsPerUnit;
            CGAffineTransform transform = CGAffineTransformMake(1.0 / sprite.pixelsPerUnit, 0, 0, -1.0 / sprite.pixelsPerUnit, x0, y0 + sprite.height / sprite.pixelsPerUnit);
            transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale([item[@"flipX"] boolValue] ? -1 : 1, [item[@"flipY"] boolValue] ? -1 : 1));
            transform = CGAffineTransformConcat(transform, [item[@"transform"] CGAffineTransformValue]);
            transform = CGAffineTransformConcat(transform, worldToPixel);
            CGContextSaveGState(cg);
            CGContextConcatCTM(cg, transform);
            [image drawInRect:CGRectMake(0, 0, sprite.width, sprite.height) blendMode:kCGBlendModeNormal alpha:alpha];
            CGContextRestoreGState(cg);
        }
    }];
}

static ZSAssetExplorerVisual *ZSAEBuildGameObjectVisual(ZSAEContext *context, ZSAEObject *object, NSError **error) {
    ZSAEGraphState *state = [ZSAEGraphState new];
    state.context = context;
    state.items = [NSMutableArray array];
    state.outline = [NSMutableString string];
    state.sprites = [NSMutableDictionary dictionary];
    ZSAEWalkGameObject(state, object, CGAffineTransformIdentity, 0, 0, YES);

    NSString *name = ZSAEString(object.fields[@"m_Name"]);
    NSString *label = name.length > 0 ? name : @"GameObject";
    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = name;

    if (state.items.count == 0) {
        if (state.truncated) [state.outline appendString:@"… hierarchy truncated\n"];
        visual.summary = [NSString stringWithFormat:@"%@  •  %lu object%@", label, (unsigned long)state.nodes, state.nodes == 1 ? @"" : @"s"];
        visual.pageLabels = @[@"Hierarchy"];
        visual.text = state.outline;
        visual.exportData = [state.outline dataUsingEncoding:NSUTF8StringEncoding];
        visual.fileExtension = @"txt";
        return visual;
    }

    NSArray<NSDictionary *> *items = [state.items copy];
    visual.summary = [NSString stringWithFormat:@"%@  •  %lu sprite%@  •  %lu object%@%@", label,
                      (unsigned long)items.count, items.count == 1 ? @"" : @"s",
                      (unsigned long)state.nodes, state.nodes == 1 ? @"" : @"s", state.truncated ? @"  •  truncated" : @""];
    visual.pageLabels = @[@"Composite"];
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        return ZSAERenderComposite(context, items, providerError);
    };
    return visual;
}

static void ZSAETimelineCollect(ZSAEContext *context, ZSAEObject *track, int64_t trackPathID, NSUInteger depth, NSMutableArray<NSDictionary *> *rows, NSMutableSet<NSString *> *seen) {
    NSDictionary *fields = track.fields;
    NSArray *clipList = ZSAEArray(fields[@"m_Clips"]);
    if (!clipList || !fields[@"m_Muted"] || rows.count >= 64) return;

    NSMutableArray<NSDictionary *> *clips = [NSMutableArray array];
    NSUInteger index = 0;
    for (id entry in clipList) {
        NSDictionary *clip = ZSAEDict(entry);
        index++;
        if (!clip || clip[@"m_Start"] == nil) continue;
        NSString *clipName = ZSAEString(clip[@"m_DisplayName"]);
        if (clipName.length == 0) clipName = [NSString stringWithFormat:@"Clip %lu", (unsigned long)index];
        double duration = ZSAEDouble(clip[@"m_Duration"]);
        double start = ZSAEDouble(clip[@"m_Start"]);
        if (!isfinite(start) || !isfinite(duration) || duration < 0) continue;
        [clips addObject:@{
            @"s": @(start),
            @"d": @(duration),
            @"n": clipName,
            @"ei": @(isfinite(ZSAEDouble(clip[@"m_EaseInDuration"])) ? ZSAEDouble(clip[@"m_EaseInDuration"]) : 0),
            @"eo": @(isfinite(ZSAEDouble(clip[@"m_EaseOutDuration"])) ? ZSAEDouble(clip[@"m_EaseOutDuration"]) : 0),
            @"asset": ZSAEDict(clip[@"m_Asset"]) ?: @{},
            @"ci": @(isfinite(ZSAEDouble(clip[@"m_ClipIn"])) ? ZSAEDouble(clip[@"m_ClipIn"]) : 0),
            @"ts": @((clip[@"m_TimeScale"] && isfinite(ZSAEDouble(clip[@"m_TimeScale"])) && ZSAEDouble(clip[@"m_TimeScale"]) != 0) ? ZSAEDouble(clip[@"m_TimeScale"]) : 1),
            @"pre": @(ZSAEInt(clip[@"m_PreExtrapolationMode"])),
            @"post": @(ZSAEInt(clip[@"m_PostExtrapolationMode"])),
        }];
    }

    NSDictionary *infinite = ZSAEDict(fields[@"m_InfiniteClip"]);
    BOOL hasInfinite = infinite && ZSAEInt(infinite[@"m_PathID"]) != 0;
    NSString *trackName = ZSAEString(fields[@"m_Name"]);
    if (clips.count > 0 || hasInfinite || depth == 0) {
        [rows addObject:@{
            @"name": trackName.length > 0 ? trackName : @"Track",
            @"clips": clips,
            @"muted": @(ZSAEInt(fields[@"m_Muted"]) != 0),
            @"infinite": @(hasInfinite),
            @"depth": @(depth),
            @"object": track,
            @"pathID": @(trackPathID),
            @"infinitePtr": infinite ?: @{},
        }];
    }

    if (depth >= 4) return;
    for (id child in ZSAEArray(fields[@"m_Children"])) {
        NSDictionary *reference = ZSAEDict(child);
        if (!reference || ZSAEInt(reference[@"m_PathID"]) == 0) continue;
        NSString *identity = [NSString stringWithFormat:@"%lld:%lld", (long long)ZSAEInt(reference[@"m_FileID"]), (long long)ZSAEInt(reference[@"m_PathID"])];
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        ZSAEObject *childObject = ZSAEResolvePPtr(context, track, reference, NULL);
        if (childObject && childObject.classID == 114) ZSAETimelineCollect(context, childObject, ZSAEInt(reference[@"m_PathID"]), depth + 1, rows, seen);
    }
}

static double ZSAETimelineTickStep(double total) {
    static const double steps[] = {0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600};
    for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
        if (total / steps[i] <= 12) return steps[i];
    }
    return 1200;
}

static NSString *ZSAETimelineSeconds(double value) {
    if (value == floor(value)) return [NSString stringWithFormat:@"%.0fs", value];
    return [NSString stringWithFormat:@"%.2fs", value];
}

static UIImage *ZSAERenderTimeline(NSArray<NSDictionary *> *rows, double total) {
    const CGFloat margin = 24;
    const CGFloat contentWidth = 1200;
    const CGFloat axisHeight = 34;
    const CGFloat headerHeight = 26;
    const CGFloat laneHeight = 38;
    const CGFloat clipHeight = 32;
    const CGFloat rowGap = 14;
    const NSUInteger maxClipsPerRow = 300;
    double span = total * 1.02;
    CGFloat pps = contentWidth / span;

    NSMutableArray<NSArray<NSNumber *> *> *laneAssignments = [NSMutableArray array];
    NSMutableArray<NSNumber *> *laneCounts = [NSMutableArray array];
    CGFloat totalHeight = axisHeight + margin;
    for (NSDictionary *row in rows) {
        NSArray *clips = row[@"clips"];
        NSUInteger limit = MIN(clips.count, maxClipsPerRow);
        NSMutableArray<NSNumber *> *assignments = [NSMutableArray arrayWithCapacity:limit];
        NSMutableArray<NSNumber *> *laneEnds = [NSMutableArray array];
        NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:limit];
        for (NSUInteger i = 0; i < limit; i++) {
            [order addObject:@(i)];
            [assignments addObject:@0];
        }
        [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            double sa = [clips[a.unsignedIntegerValue][@"s"] doubleValue];
            double sb = [clips[b.unsignedIntegerValue][@"s"] doubleValue];
            return sa < sb ? NSOrderedAscending : (sa > sb ? NSOrderedDescending : NSOrderedSame);
        }];
        for (NSNumber *clipIndex in order) {
            NSDictionary *clip = clips[clipIndex.unsignedIntegerValue];
            double start = [clip[@"s"] doubleValue];
            double end = start + [clip[@"d"] doubleValue];
            NSUInteger lane = NSNotFound;
            for (NSUInteger l = 0; l < laneEnds.count; l++) {
                if (laneEnds[l].doubleValue <= start + 1e-6) {
                    lane = l;
                    break;
                }
            }
            if (lane == NSNotFound) {
                lane = laneEnds.count;
                [laneEnds addObject:@(end)];
            } else {
                laneEnds[lane] = @(end);
            }
            assignments[clipIndex.unsignedIntegerValue] = @(lane);
        }
        NSUInteger laneCount = MAX((NSUInteger)1, laneEnds.count);
        [laneAssignments addObject:assignments];
        [laneCounts addObject:@(laneCount)];
        totalHeight += headerHeight + laneCount * laneHeight + rowGap;
    }

    CGSize size = CGSizeMake(contentWidth + margin * 2, totalHeight);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

    UIFont *tickFont = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    UIFont *headerFont = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    UIFont *clipFont = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    UIFont *clipSubFont = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef ctx = rendererContext.CGContext;
        [[UIColor colorWithWhite:0.09 alpha:1] setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, size.width, size.height));

        double tickStep = ZSAETimelineTickStep(span);
        NSDictionary *tickAttributes = @{NSFontAttributeName: tickFont, NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.5]};
        for (double t = 0; t <= span + 1e-9; t += tickStep) {
            CGFloat x = margin + t * pps;
            [[UIColor colorWithWhite:1 alpha:0.08] setFill];
            CGContextFillRect(ctx, CGRectMake(x, axisHeight - 6, 1, size.height - axisHeight + 6));
            [ZSAETimelineSeconds(t) drawAtPoint:CGPointMake(x + 3, 6) withAttributes:tickAttributes];
        }
        [[UIColor colorWithWhite:1 alpha:0.2] setFill];
        CGContextFillRect(ctx, CGRectMake(margin, axisHeight - 6, contentWidth, 1));

        CGFloat y = axisHeight;
        for (NSUInteger r = 0; r < rows.count; r++) {
            NSDictionary *row = rows[r];
            NSArray *clips = row[@"clips"];
            BOOL muted = [row[@"muted"] boolValue];
            NSUInteger depth = [row[@"depth"] unsignedIntegerValue];
            UIColor *base = [UIColor colorWithHue:fmod(0.58 + 0.13 * r, 1.0) saturation:0.55 brightness:muted ? 0.45 : 0.85 alpha:1];

            NSString *title = row[@"name"];
            NSString *meta = [NSString stringWithFormat:@"%@%@%@", [row[@"infinite"] boolValue] ? @"  •  infinite clip" : @"", muted ? @"  •  muted" : @"", clips.count > maxClipsPerRow ? [NSString stringWithFormat:@"  •  showing %lu of %lu", (unsigned long)maxClipsPerRow, (unsigned long)clips.count] : @""];
            NSString *headerText = [NSString stringWithFormat:@"%@%@", title, meta];
            CGFloat indent = MIN(depth, (NSUInteger)4) * 14;
            [base setFill];
            CGContextFillRect(ctx, CGRectMake(margin + indent, y + 5, 3, 14));
            [headerText drawAtPoint:CGPointMake(margin + indent + 10, y + 4) withAttributes:@{NSFontAttributeName: headerFont, NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:muted ? 0.45 : 0.9]}];
            y += headerHeight;

            NSArray<NSNumber *> *assignments = laneAssignments[r];
            NSUInteger laneCount = laneCounts[r].unsignedIntegerValue;
            for (NSUInteger l = 0; l < laneCount; l++) {
                [[UIColor colorWithWhite:1 alpha:0.035] setFill];
                CGContextFillRect(ctx, CGRectMake(margin, y + l * laneHeight, contentWidth, laneHeight - 3));
            }

            for (NSUInteger i = 0; i < assignments.count; i++) {
                NSDictionary *clip = clips[i];
                double start = [clip[@"s"] doubleValue];
                double duration = [clip[@"d"] doubleValue];
                CGFloat x = margin + start * pps;
                CGFloat w = MAX(duration * pps, 2);
                CGFloat cy = y + assignments[i].unsignedIntegerValue * laneHeight + 1;
                CGRect rect = CGRectMake(x, cy, w, clipHeight);
                UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:4];
                [[base colorWithAlphaComponent:muted ? 0.35 : 0.8] setFill];
                [path fill];

                CGContextSaveGState(ctx);
                [path addClip];
                for (NSUInteger j = 0; j < assignments.count; j++) {
                    if (j == i) continue;
                    NSDictionary *other = clips[j];
                    double os = [other[@"s"] doubleValue];
                    double oe = os + [other[@"d"] doubleValue];
                    double lo = MAX(start, os);
                    double hi = MIN(start + duration, oe);
                    if (hi - lo > 1e-6) {
                        [[UIColor colorWithWhite:1 alpha:0.28] setFill];
                        CGContextFillRect(ctx, CGRectMake(margin + lo * pps, cy, MAX((hi - lo) * pps, 1), clipHeight));
                    }
                }
                double easeIn = MIN([clip[@"ei"] doubleValue], duration);
                double easeOut = MIN([clip[@"eo"] doubleValue], duration);
                [[UIColor colorWithWhite:0 alpha:0.35] setFill];
                if (easeIn > 0) {
                    UIBezierPath *tri = [UIBezierPath bezierPath];
                    [tri moveToPoint:CGPointMake(x, cy)];
                    [tri addLineToPoint:CGPointMake(x + easeIn * pps, cy)];
                    [tri addLineToPoint:CGPointMake(x, cy + clipHeight)];
                    [tri closePath];
                    [tri fill];
                }
                if (easeOut > 0) {
                    UIBezierPath *tri = [UIBezierPath bezierPath];
                    [tri moveToPoint:CGPointMake(x + w, cy)];
                    [tri addLineToPoint:CGPointMake(x + w - easeOut * pps, cy)];
                    [tri addLineToPoint:CGPointMake(x + w, cy + clipHeight)];
                    [tri closePath];
                    [tri fill];
                }
                CGContextRestoreGState(ctx);

                [[UIColor colorWithWhite:1 alpha:0.4] setStroke];
                path.lineWidth = 1;
                [path stroke];

                if (w > 28) {
                    CGContextSaveGState(ctx);
                    CGContextClipToRect(ctx, CGRectInset(rect, 4, 0));
                    [clip[@"n"] drawAtPoint:CGPointMake(x + 5, cy + 3) withAttributes:@{NSFontAttributeName: clipFont, NSForegroundColorAttributeName: UIColor.whiteColor}];
                    NSString *range = [NSString stringWithFormat:@"%@ → %@", ZSAETimelineSeconds(start), ZSAETimelineSeconds(start + duration)];
                    [range drawAtPoint:CGPointMake(x + 5, cy + 18) withAttributes:@{NSFontAttributeName: clipSubFont, NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.75]}];
                    CGContextRestoreGState(ctx);
                }
            }
            y += laneCount * laneHeight + rowGap;
        }
    }];
}

typedef struct {
    float t;
    float c[4];
} ZSAEAnimKey;

enum {
    ZSAEChPX = 0, ZSAEChPY, ZSAEChPZ,
    ZSAEChQX, ZSAEChQY, ZSAEChQZ, ZSAEChQW,
    ZSAEChSX, ZSAEChSY,
    ZSAEChEZ,
    ZSAEChR, ZSAEChG, ZSAEChB, ZSAEChA,
    ZSAEChActive, ZSAEChEnabled,
    ZSAEChCount
};

typedef struct {
    double v[ZSAEChCount];
    uint16_t mask;
    int32_t sprite;
} ZSAENodeState;

typedef struct {
    int32_t sprite;
    CGAffineTransform world;
    double z;
    float r, g, b, a;
    BOOL flipX;
    BOOL flipY;
    int32_t layer;
    int32_t order;
    int32_t index;
} ZSAEAnimItem;

@interface ZSAEAnimCurve : NSObject
@property (nonatomic, assign) uint32_t pathHash;
@property (nonatomic, assign) uint32_t attribute;
@property (nonatomic, assign) int32_t typeID;
@property (nonatomic, assign) int32_t component;
@property (nonatomic, assign) BOOL pptr;
@property (nonatomic, strong) NSData *keys;
@end

@implementation ZSAEAnimCurve
@end

@interface ZSAEAnimClip : NSObject
@property (nonatomic, strong) ZSAEObject *owner;
@property (nonatomic, copy) NSArray<ZSAEAnimCurve *> *curves;
@property (nonatomic, copy) NSArray<NSDictionary *> *spriteCurves;
@property (nonatomic, copy) NSArray<NSDictionary *> *pptrMapping;
@property (nonatomic, assign) double span;
@property (nonatomic, assign) BOOL loop;
@end

@implementation ZSAEAnimClip
@end

@interface ZSAEAnimBound : NSObject
@property (nonatomic, assign) int32_t node;
@property (nonatomic, assign) int32_t channel;
@property (nonatomic, strong) NSData *keys;
@end

@implementation ZSAEAnimBound
@end

@interface ZSAEAnimSpriteBound : NSObject
@property (nonatomic, assign) int32_t node;
@property (nonatomic, strong) NSData *times;
@property (nonatomic, strong) NSData *sprites;
@end

@implementation ZSAEAnimSpriteBound
@end

@interface ZSAEAnimTrackClip : NSObject
@property (nonatomic, strong) ZSAEAnimClip *clip;
@property (nonatomic, assign) double start;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double clipIn;
@property (nonatomic, assign) double timeScale;
@property (nonatomic, assign) int preMode;
@property (nonatomic, assign) int postMode;
@property (nonatomic, copy) NSArray<ZSAEAnimBound *> *bounds;
@property (nonatomic, copy) NSArray<ZSAEAnimSpriteBound *> *spriteBounds;
@end

@implementation ZSAEAnimTrackClip
@end

@interface ZSAEAnimTrackPlay : NSObject
@property (nonatomic, strong) ZSAEAnimTrackClip *base;
@property (nonatomic, copy) NSArray<ZSAEAnimTrackClip *> *clips;
@end

@implementation ZSAEAnimTrackPlay
@end

@interface ZSAEAnimNode : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) NSInteger parent;
@property (nonatomic, assign) NSInteger root;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL excluded;
@property (nonatomic, assign) double px, py, pz, qx, qy, qz, qw, sx, sy;
@property (nonatomic, assign) BOOL hasRenderer;
@property (nonatomic, assign) BOOL rendererEnabled;
@property (nonatomic, assign) BOOL flipX;
@property (nonatomic, assign) BOOL flipY;
@property (nonatomic, assign) int32_t layer;
@property (nonatomic, assign) int32_t order;
@property (nonatomic, assign) double cr, cg, cb, ca;
@property (nonatomic, assign) int32_t baseSprite;
@end

@implementation ZSAEAnimNode
@end

@interface ZSAEAnimRoot : NSObject
@property (nonatomic, assign) NSInteger firstNode;
@property (nonatomic, assign) BOOL used;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *hashToNode;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *pathToNode;
@end

@implementation ZSAEAnimRoot
@end

@interface ZSAEAnimScene : NSObject
@property (nonatomic, strong) NSMutableArray<ZSAEAnimNode *> *nodes;
@property (nonatomic, strong) NSMutableArray<ZSAEAnimRoot *> *roots;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *rootIndexByKey;
@property (nonatomic, strong) NSMutableArray<ZSAEAnimTrackPlay *> *tracks;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *spriteRefs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *spriteIndexByKey;
@property (nonatomic, strong) NSMutableArray *sprites;
@property (nonatomic, strong) NSCache *tintCache;
@property (nonatomic, assign) CGSize canvasSize;
@property (nonatomic, assign) CGAffineTransform worldToPixel;
@property (nonatomic, assign) NSUInteger reads;
@property (nonatomic, assign) BOOL truncated;
@property (nonatomic, copy) NSString *debugFrame;
@end

@implementation ZSAEAnimScene
@end

static uint32_t ZSAECRC32(const char *text) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
    });
    uint32_t crc = 0xFFFFFFFFu;
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) crc = table[(crc ^ *p) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

static int ZSAEAnimChannelFor(int32_t typeID, uint32_t attribute, int32_t component) {
    static uint32_t hashR, hashG, hashB, hashA, hashEnabled, hashActive;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hashR = ZSAECRC32("m_Color.r");
        hashG = ZSAECRC32("m_Color.g");
        hashB = ZSAECRC32("m_Color.b");
        hashA = ZSAECRC32("m_Color.a");
        hashEnabled = ZSAECRC32("m_Enabled");
        hashActive = ZSAECRC32("m_IsActive");
    });
    if (typeID == 4) {
        if (attribute == 1 && component >= 0 && component <= 2) return ZSAEChPX + component;
        if (attribute == 2 && component >= 0 && component <= 3) return ZSAEChQX + component;
        if (attribute == 3 && component >= 0 && component <= 1) return ZSAEChSX + component;
        if (attribute == 4 && component == 2) return ZSAEChEZ;
        return -1;
    }
    if (typeID == 212) {
        if (attribute == hashR) return ZSAEChR;
        if (attribute == hashG) return ZSAEChG;
        if (attribute == hashB) return ZSAEChB;
        if (attribute == hashA) return ZSAEChA;
        if (attribute == hashEnabled) return ZSAEChEnabled;
        return -1;
    }
    if (typeID == 1 && attribute == hashActive) return ZSAEChActive;
    return -1;
}

static float ZSAEAnimCurveEval(NSData *keyData, double time) {
    const ZSAEAnimKey *keys = (const ZSAEAnimKey *)keyData.bytes;
    NSInteger count = (NSInteger)(keyData.length / sizeof(ZSAEAnimKey));
    if (!keys || count <= 0) return 0;
    if (time <= keys[0].t) return keys[0].c[3];
    NSInteger lo = 0;
    NSInteger hi = count - 1;
    while (lo < hi) {
        NSInteger mid = (lo + hi + 1) / 2;
        if (keys[mid].t <= time) lo = mid;
        else hi = mid - 1;
    }
    const ZSAEAnimKey *key = &keys[lo];
    if (lo == count - 1) return key->c[3];
    float dt = (float)(time - key->t);
    return ((key->c[0] * dt + key->c[1]) * dt + key->c[2]) * dt + key->c[3];
}

static NSUInteger ZSAEAnimStreamCurveTotal(id value) {
    uint64_t raw = (uint64_t)MAX((int64_t)0, ZSAEInt(value));
    return (NSUInteger)((raw & 0xFFFFu) + ((raw >> 16) & 0xFFFFu));
}

static ZSAEAnimClip *ZSAEDecodeAnimClip(ZSAEObject *clipObject, NSString **diag) {
    NSDictionary *fields = clipObject.fields;
    NSDictionary *muscle = ZSAEDict(fields[@"m_MuscleClip"]);
    NSDictionary *container = ZSAEDict(muscle[@"m_Clip"]);
    NSDictionary *clipData = ZSAEDict(container[@"data"]) ?: container;
    NSDictionary *streamed = ZSAEDict(clipData[@"m_StreamedClip"]);
    NSDictionary *dense = ZSAEDict(clipData[@"m_DenseClip"]);
    NSDictionary *constant = ZSAEDict(clipData[@"m_ConstantClip"]);
    NSDictionary *bindingConstant = ZSAEDict(fields[@"m_ClipBindingConstant"]);

    NSUInteger expectedStream = ZSAEAnimStreamCurveTotal(streamed[@"curveCount"]);
    NSUInteger expectedDense = (NSUInteger)MAX((int64_t)0, ZSAEInt(dense[@"m_CurveCount"]));
    NSData *expectedConstantData = [constant[@"data"] isKindOfClass:[NSData class]] ? constant[@"data"] : nil;
    NSUInteger expectedTotal = expectedStream + expectedDense + expectedConstantData.length / sizeof(float);

    NSMutableArray<NSDictionary *> *skipSlots = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *countSlots = [NSMutableArray array];
    for (id entry in ZSAEArray(bindingConstant[@"genericBindings"])) {
        NSDictionary *binding = ZSAEDict(entry);
        if (!binding) continue;
        if (ZSAEInt(binding[@"isPPtrCurve"]) != 0) {
            [countSlots addObject:@{@"p": @((uint32_t)ZSAEInt(binding[@"path"])), @"a": @((uint32_t)ZSAEInt(binding[@"attribute"])), @"t": @(-1), @"c": @0, @"x": @YES}];
            continue;
        }
        int32_t typeID = (int32_t)ZSAEInt(binding[@"typeID"]);
        uint32_t attribute = (uint32_t)ZSAEInt(binding[@"attribute"]);
        uint32_t pathHash = (uint32_t)ZSAEInt(binding[@"path"]);
        int components = 1;
        if (typeID == 4) {
            if (attribute == 2) components = 4;
            else if (attribute == 1 || attribute == 3 || attribute == 4) components = 3;
        }
        for (int c = 0; c < components; c++) {
            NSDictionary *slot = @{@"p": @(pathHash), @"a": @(attribute), @"t": @(typeID), @"c": @(c)};
            [skipSlots addObject:slot];
            [countSlots addObject:slot];
        }
    }
    NSArray<NSDictionary *> *slots = (skipSlots.count != expectedTotal && countSlots.count == expectedTotal) ? countSlots : skipSlots;

    NSMutableArray<ZSAEAnimCurve *> *curves = [NSMutableArray array];
    void (^addCurve)(NSUInteger, NSData *) = ^(NSUInteger slotIndex, NSData *keys) {
        if (slotIndex >= slots.count || keys.length == 0) return;
        NSDictionary *slot = slots[slotIndex];
        ZSAEAnimCurve *curve = [ZSAEAnimCurve new];
        curve.pathHash = (uint32_t)ZSAEInt(slot[@"p"]);
        curve.attribute = (uint32_t)ZSAEInt(slot[@"a"]);
        curve.typeID = (int32_t)ZSAEInt(slot[@"t"]);
        curve.component = (int32_t)ZSAEInt(slot[@"c"]);
        curve.pptr = [slot[@"x"] boolValue];
        curve.keys = keys;
        [curves addObject:curve];
    };

    double lastTime = 0;
    NSUInteger streamCount = expectedStream;
    NSData *streamData = [streamed[@"data"] isKindOfClass:[NSData class]] ? streamed[@"data"] : nil;
    if (streamData.length > 0) {
        NSMutableDictionary<NSNumber *, NSMutableData *> *perCurve = [NSMutableDictionary dictionary];
        const uint8_t *bytes = (const uint8_t *)streamData.bytes;
        size_t length = streamData.length;
        size_t pos = 0;
        while (pos + 8 <= length) {
            float frameTime = 0;
            int32_t keyCount = 0;
            memcpy(&frameTime, bytes + pos, 4);
            memcpy(&keyCount, bytes + pos + 4, 4);
            pos += 8;
            if (keyCount < 0 || (size_t)keyCount > (length - pos) / 20) break;
            BOOL finite = isfinite(frameTime);
            float keyTime = finite ? frameTime : (frameTime < 0 ? 0 : -1);
            for (int32_t k = 0; k < keyCount; k++) {
                int32_t curveIndex = 0;
                ZSAEAnimKey key;
                memcpy(&curveIndex, bytes + pos, 4);
                memcpy(key.c, bytes + pos + 4, 16);
                pos += 20;
                if (keyTime < 0 || curveIndex < 0) continue;
                key.t = keyTime;
                NSNumber *slotKey = @(curveIndex);
                NSMutableData *data = perCurve[slotKey];
                if (!data) {
                    data = [NSMutableData data];
                    perCurve[slotKey] = data;
                }
                [data appendBytes:&key length:sizeof(key)];
            }
            if (finite && frameTime > lastTime) lastTime = frameTime;
        }
        for (NSNumber *slotKey in perCurve) addCurve((NSUInteger)slotKey.integerValue, perCurve[slotKey]);
    }

    NSUInteger denseCurves = (NSUInteger)ZSAEInt(dense[@"m_CurveCount"]);
    NSUInteger denseFrames = (NSUInteger)MAX((int64_t)0, ZSAEInt(dense[@"m_FrameCount"]));
    double rate = ZSAEDouble(dense[@"m_SampleRate"]);
    double begin = ZSAEDouble(dense[@"m_BeginTime"]);
    NSData *samples = [dense[@"m_SampleArray"] isKindOfClass:[NSData class]] ? dense[@"m_SampleArray"] : nil;
    if (denseCurves > 0 && denseFrames > 0 && rate > 0 && samples.length >= denseCurves * denseFrames * sizeof(float)) {
        const float *values = (const float *)samples.bytes;
        for (NSUInteger c = 0; c < denseCurves; c++) {
            NSMutableData *keys = [NSMutableData dataWithCapacity:denseFrames * sizeof(ZSAEAnimKey)];
            for (NSUInteger f = 0; f < denseFrames; f++) {
                float value = values[f * denseCurves + c];
                float next = f + 1 < denseFrames ? values[(f + 1) * denseCurves + c] : value;
                ZSAEAnimKey key;
                key.t = (float)(begin + (double)f / rate);
                key.c[0] = 0;
                key.c[1] = 0;
                key.c[2] = (float)((next - value) * rate);
                key.c[3] = value;
                [keys appendBytes:&key length:sizeof(key)];
            }
            addCurve(streamCount + c, keys);
        }
        lastTime = MAX(lastTime, begin + (double)(denseFrames - 1) / rate);
    }

    NSData *constantData = [constant[@"data"] isKindOfClass:[NSData class]] ? constant[@"data"] : nil;
    NSUInteger constantCount = constantData.length / sizeof(float);
    const float *constantValues = (const float *)constantData.bytes;
    for (NSUInteger i = 0; i < constantCount; i++) {
        ZSAEAnimKey key;
        key.t = 0;
        key.c[0] = 0;
        key.c[1] = 0;
        key.c[2] = 0;
        key.c[3] = constantValues[i];
        addCurve(streamCount + denseCurves + i, [NSData dataWithBytes:&key length:sizeof(key)]);
    }

    NSMutableArray<NSDictionary *> *spriteCurves = [NSMutableArray array];
    for (id entry in ZSAEArray(fields[@"m_PPtrCurves"])) {
        NSDictionary *pointerCurve = ZSAEDict(entry);
        NSString *attribute = ZSAEString(pointerCurve[@"attribute"]);
        if (!pointerCurve || ![attribute isEqualToString:@"m_Sprite"]) continue;
        NSMutableArray<NSNumber *> *times = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *values = [NSMutableArray array];
        for (id keyEntry in ZSAEArray(pointerCurve[@"curve"])) {
            NSDictionary *keyframe = ZSAEDict(keyEntry);
            NSDictionary *value = ZSAEDict(keyframe[@"value"]);
            if (!value) continue;
            double keyTime = ZSAEDouble(keyframe[@"time"]);
            [times addObject:@(keyTime)];
            [values addObject:value];
            lastTime = MAX(lastTime, keyTime);
        }
        if (times.count == 0) continue;
        [spriteCurves addObject:@{@"path": ZSAEString(pointerCurve[@"path"]) ?: @"", @"times": times, @"values": values}];
    }

    if (diag) {
        NSUInteger pptrCurveCount = 0;
        for (ZSAEAnimCurve *curve in curves) if (curve.pptr) pptrCurveCount++;
        *diag = [NSString stringWithFormat:@"clip %@ mc=%d cl=%d bind=%lu map=%lu raw=0x%llx exp=%lu+%lu+%lu slots=%lu/%lu use=%@ sd=%lu cur=%lu pp=%lu ed=%lu",
                 ZSAEString(fields[@"m_Name"]) ?: @"?", muscle ? 1 : 0, clipData ? 1 : 0,
                 (unsigned long)ZSAEArray(bindingConstant[@"genericBindings"]).count, (unsigned long)ZSAEArray(bindingConstant[@"pptrCurveMapping"]).count,
                 (unsigned long long)ZSAEInt(streamed[@"curveCount"]), (unsigned long)expectedStream, (unsigned long)expectedDense, (unsigned long)(expectedConstantData.length / sizeof(float)),
                 (unsigned long)skipSlots.count, (unsigned long)countSlots.count, slots == countSlots ? @"cnt" : @"skp",
                 (unsigned long)(streamData.length / 4), (unsigned long)curves.count, (unsigned long)pptrCurveCount, (unsigned long)spriteCurves.count];
    }
    if (curves.count == 0 && spriteCurves.count == 0) return nil;

    double span = ZSAEDouble(muscle[@"m_StopTime"]) - ZSAEDouble(muscle[@"m_StartTime"]);
    if (!(span > 1e-6)) span = lastTime;
    NSMutableArray<NSDictionary *> *pptrMapping = [NSMutableArray array];
    for (id entry in ZSAEArray(bindingConstant[@"pptrCurveMapping"])) {
        NSDictionary *pointer = ZSAEDict(entry);
        [pptrMapping addObject:pointer ?: @{}];
    }

    ZSAEAnimClip *clip = [ZSAEAnimClip new];
    clip.owner = clipObject;
    clip.pptrMapping = pptrMapping;
    clip.curves = curves;
    clip.spriteCurves = spriteCurves;
    clip.span = span;
    clip.loop = ZSAEInt(muscle[@"m_LoopTime"]) != 0;
    return clip;
}

static ZSAEAnimClip *ZSAEAnimLoadClip(ZSAEContext *context, ZSAEObject *owner, id pointer, NSMutableDictionary<NSString *, id> *cache, NSMutableArray<NSString *> *log) {
    NSDictionary *reference = ZSAEDict(pointer);
    if (!reference || ZSAEInt(reference[@"m_PathID"]) == 0) return nil;
    NSString *key = [NSString stringWithFormat:@"%p:%lld:%lld", owner.session, (long long)ZSAEInt(reference[@"m_FileID"]), (long long)ZSAEInt(reference[@"m_PathID"])];
    id cached = cache[key];
    if (cached) return [cached isKindOfClass:[ZSAEAnimClip class]] ? cached : nil;
    ZSAEObject *clipObject = ZSAEResolvePPtr(context, owner, reference, NULL);
    NSString *diag = nil;
    ZSAEAnimClip *clip = (clipObject && clipObject.classID == 74) ? ZSAEDecodeAnimClip(clipObject, &diag) : nil;
    if (!diag) diag = [NSString stringWithFormat:@"clip pid=%lld unresolved=%d cls=%d", (long long)ZSAEInt(reference[@"m_PathID"]), clipObject ? 0 : 1, clipObject ? (int)clipObject.classID : -1];
    if (log && log.count < 24) [log addObject:[diag stringByAppendingString:clip ? @"" : @" NIL"]];
    cache[key] = clip ?: (id)[NSNull null];
    return clip;
}

static int32_t ZSAEAnimRegisterSprite(ZSAEAnimScene *scene, ZSAEObject *owner, id pointer) {
    NSDictionary *reference = ZSAEDict(pointer);
    if (!reference || ZSAEInt(reference[@"m_PathID"]) == 0) return -1;
    NSString *key = [NSString stringWithFormat:@"%p:%lld:%lld", owner.session, (long long)ZSAEInt(reference[@"m_FileID"]), (long long)ZSAEInt(reference[@"m_PathID"])];
    NSNumber *existing = scene.spriteIndexByKey[key];
    if (existing) return (int32_t)existing.integerValue;
    if (scene.spriteRefs.count >= 480) return -1;
    int32_t index = (int32_t)scene.spriteRefs.count;
    scene.spriteIndexByKey[key] = @(index);
    [scene.spriteRefs addObject:@{@"owner": owner, @"pptr": reference}];
    return index;
}

static ZSAEObject *ZSAEAnimRead(ZSAEAnimScene *scene, ZSAEContext *context, ZSAEObject *owner, id pointer) {
    if (scene.reads >= 40000) {
        scene.truncated = YES;
        return nil;
    }
    scene.reads++;
    return ZSAEResolvePPtr(context, owner, pointer, NULL);
}

static void ZSAEAnimBuildNodes(ZSAEContext *context, ZSAEAnimScene *scene, ZSAEObject *go, NSInteger parent, NSInteger rootIndex, NSString *parentPath, NSUInteger depth, NSMutableDictionary<NSNumber *, NSNumber *> *hashMap, NSMutableDictionary<NSString *, NSNumber *> *pathMap) {
    if (scene.nodes.count >= 4000 || depth > 40) {
        scene.truncated = YES;
        return;
    }
    NSDictionary *fields = go.fields;
    NSString *name = ZSAEString(fields[@"m_Name"]) ?: @"";
    NSString *path = depth == 0 ? @"" : (parentPath.length > 0 ? [NSString stringWithFormat:@"%@/%@", parentPath, name] : name);

    ZSAEAnimNode *node = [ZSAEAnimNode new];
    node.name = name;
    node.path = path;
    node.parent = parent;
    node.root = rootIndex;
    node.active = fields[@"m_IsActive"] ? ZSAEInt(fields[@"m_IsActive"]) != 0 : YES;
    node.qw = 1;
    node.sx = 1;
    node.sy = 1;
    node.cr = 1;
    node.cg = 1;
    node.cb = 1;
    node.ca = 1;
    node.rendererEnabled = YES;
    node.baseSprite = -1;

    ZSAEObject *transform = nil;
    for (id entry in ZSAEArray(fields[@"m_Component"])) {
        NSDictionary *pair = ZSAEDict(entry);
        id pointer = pair[@"component"] ?: pair[@"second"];
        if (!pointer) continue;
        ZSAEObject *component = ZSAEAnimRead(scene, context, go, pointer);
        if (!component) continue;
        if ((component.classID == 4 || component.classID == 224) && !transform) {
            transform = component;
        } else if (component.classID == 212 && !node.hasRenderer) {
            NSDictionary *componentFields = component.fields;
            NSDictionary *color = ZSAEDict(componentFields[@"m_Color"]);
            node.hasRenderer = YES;
            node.rendererEnabled = componentFields[@"m_Enabled"] ? ZSAEInt(componentFields[@"m_Enabled"]) != 0 : YES;
            node.flipX = ZSAEInt(componentFields[@"m_FlipX"]) != 0;
            node.flipY = ZSAEInt(componentFields[@"m_FlipY"]) != 0;
            node.layer = (int32_t)ZSAEInt(componentFields[@"m_SortingLayer"]);
            node.order = (int32_t)ZSAEInt(componentFields[@"m_SortingOrder"]);
            if (color) {
                node.cr = ZSAEDouble(color[@"r"]);
                node.cg = ZSAEDouble(color[@"g"]);
                node.cb = ZSAEDouble(color[@"b"]);
                node.ca = ZSAEDouble(color[@"a"]);
            }
            node.baseSprite = ZSAEAnimRegisterSprite(scene, component, componentFields[@"m_Sprite"]);
        }
    }

    if (transform) {
        NSDictionary *position = ZSAEDict(transform.fields[@"m_LocalPosition"]);
        NSDictionary *rotation = ZSAEDict(transform.fields[@"m_LocalRotation"]);
        NSDictionary *scale = ZSAEDict(transform.fields[@"m_LocalScale"]);
        node.px = ZSAEDouble(position[@"x"]);
        node.py = ZSAEDouble(position[@"y"]);
        node.pz = ZSAEDouble(position[@"z"]);
        if (rotation) {
            node.qx = ZSAEDouble(rotation[@"x"]);
            node.qy = ZSAEDouble(rotation[@"y"]);
            node.qz = ZSAEDouble(rotation[@"z"]);
            node.qw = ZSAEDouble(rotation[@"w"]);
        }
        if (scale) {
            node.sx = ZSAEDouble(scale[@"x"]);
            node.sy = ZSAEDouble(scale[@"y"]);
        }
    }

    NSInteger index = (NSInteger)scene.nodes.count;
    [scene.nodes addObject:node];
    NSNumber *hashKey = @(ZSAECRC32(path.UTF8String ?: ""));
    if (!hashMap[hashKey]) hashMap[hashKey] = @(index);
    if (!pathMap[path]) pathMap[path] = @(index);

    if (!transform) return;
    for (id childPointer in ZSAEArray(transform.fields[@"m_Children"])) {
        ZSAEObject *childTransform = ZSAEAnimRead(scene, context, transform, childPointer);
        if (!childTransform) continue;
        ZSAEObject *childObject = ZSAEAnimRead(scene, context, childTransform, childTransform.fields[@"m_GameObject"]);
        if (!childObject || childObject.classID != 1) continue;
        ZSAEAnimBuildNodes(context, scene, childObject, index, rootIndex, path, depth + 1, hashMap, pathMap);
    }
}

static NSInteger ZSAEAnimEnsureRoot(ZSAEContext *context, ZSAEAnimScene *scene, ZSAEObject *go, NSString *key) {
    NSNumber *existing = scene.rootIndexByKey[key];
    if (existing) return existing.integerValue;
    NSInteger rootIndex = (NSInteger)scene.roots.count;
    ZSAEAnimRoot *root = [ZSAEAnimRoot new];
    root.firstNode = (NSInteger)scene.nodes.count;
    NSMutableDictionary<NSNumber *, NSNumber *> *hashMap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *pathMap = [NSMutableDictionary dictionary];
    [scene.roots addObject:root];
    scene.rootIndexByKey[key] = @(rootIndex);
    ZSAEAnimBuildNodes(context, scene, go, -1, rootIndex, @"", 0, hashMap, pathMap);
    root.hashToNode = hashMap;
    root.pathToNode = pathMap;
    return rootIndex;
}

static ZSAEAnimNode *ZSAEAnimBlankNode(NSString *name, NSInteger parent, NSInteger rootIndex) {
    ZSAEAnimNode *node = [ZSAEAnimNode new];
    node.name = name;
    node.path = name;
    node.parent = parent;
    node.root = rootIndex;
    node.active = YES;
    node.qw = 1;
    node.sx = 1;
    node.sy = 1;
    node.cr = 1;
    node.cg = 1;
    node.cb = 1;
    node.ca = 1;
    node.rendererEnabled = YES;
    node.baseSprite = -1;
    return node;
}

static NSInteger ZSAEAnimEnsureSyntheticRoot(ZSAEAnimScene *scene, NSString *key) {
    NSNumber *existing = scene.rootIndexByKey[key];
    if (existing) return existing.integerValue;
    NSInteger rootIndex = (NSInteger)scene.roots.count;
    ZSAEAnimRoot *root = [ZSAEAnimRoot new];
    root.firstNode = (NSInteger)scene.nodes.count;
    [scene.nodes addObject:ZSAEAnimBlankNode(@"", -1, rootIndex)];
    root.hashToNode = @{@0: @(root.firstNode)};
    root.pathToNode = @{@"": @(root.firstNode)};
    [scene.roots addObject:root];
    scene.rootIndexByKey[key] = @(rootIndex);
    return rootIndex;
}

static void ZSAEAnimSynthesizeNodes(ZSAEAnimScene *scene, NSInteger rootIndex, NSSet<NSNumber *> *hashes, NSSet<NSNumber *> *spriteHashes, int32_t order) {
    ZSAEAnimRoot *root = scene.roots[(NSUInteger)rootIndex];
    NSMutableDictionary<NSNumber *, NSNumber *> *hashMap = [root.hashToNode mutableCopy];
    NSMutableDictionary<NSString *, NSNumber *> *pathMap = [root.pathToNode mutableCopy];
    for (NSNumber *hash in hashes) {
        NSNumber *index = hashMap[hash];
        if (!index) {
            if (scene.nodes.count >= 4000) {
                scene.truncated = YES;
                continue;
            }
            NSString *name = [NSString stringWithFormat:@"%08x", hash.unsignedIntValue];
            index = @(scene.nodes.count);
            [scene.nodes addObject:ZSAEAnimBlankNode(name, root.firstNode, rootIndex)];
            hashMap[hash] = index;
            pathMap[name] = index;
        }
        if ([spriteHashes containsObject:hash]) {
            ZSAEAnimNode *node = scene.nodes[index.unsignedIntegerValue];
            if (!node.hasRenderer) {
                node.hasRenderer = YES;
                node.order = order;
            }
        }
    }
    root.hashToNode = hashMap;
    root.pathToNode = pathMap;
}

static ZSAEObject *ZSAEAnimBoundTarget(ZSAEContext *context, ZSAEAnimScene *scene, NSArray<ZSAEObject *> *directors, int64_t trackPathID, NSString **rootKey) {
    for (ZSAEObject *director in directors) {
        for (id entry in ZSAEArray(director.fields[@"m_SceneBindings"])) {
            NSDictionary *pair = ZSAEDict(entry);
            NSDictionary *keyPointer = ZSAEDict(pair[@"key"] ?: pair[@"first"]);
            if (!keyPointer || ZSAEInt(keyPointer[@"m_PathID"]) != trackPathID) continue;
            NSDictionary *valuePointer = ZSAEDict(pair[@"value"] ?: pair[@"second"]);
            if (!valuePointer) continue;
            ZSAEObject *target = ZSAEAnimRead(scene, context, director, valuePointer);
            if (!target) continue;
            ZSAEObject *go = nil;
            NSDictionary *goPointer = nil;
            ZSAEObject *goOwner = nil;
            if (target.classID == 1) {
                go = target;
                goPointer = valuePointer;
                goOwner = director;
            } else {
                goPointer = ZSAEDict(target.fields[@"m_GameObject"]);
                goOwner = target;
                go = goPointer ? ZSAEAnimRead(scene, context, target, goPointer) : nil;
            }
            if (!go || go.classID != 1 || !goPointer) continue;
            *rootKey = [NSString stringWithFormat:@"%p:%lld:%lld", goOwner.session, (long long)ZSAEInt(goPointer[@"m_FileID"]), (long long)ZSAEInt(goPointer[@"m_PathID"])];
            return go;
        }
    }
    return nil;
}

static void ZSAEAnimBindClip(ZSAEAnimScene *scene, ZSAEAnimRoot *root, ZSAEAnimTrackClip *trackClip, NSUInteger *boundCount, NSUInteger *mappableCount) {
    ZSAEAnimClip *clip = trackClip.clip;
    NSMutableArray<ZSAEAnimBound *> *bounds = [NSMutableArray array];
    NSMutableArray<ZSAEAnimSpriteBound *> *spriteBounds = [NSMutableArray array];
    for (ZSAEAnimCurve *curve in clip.curves) {
        if (curve.pptr) {
            (*mappableCount)++;
            NSNumber *pptrNode = root.hashToNode[@(curve.pathHash)];
            NSUInteger keyCount = curve.keys.length / sizeof(ZSAEAnimKey);
            if (!pptrNode || keyCount == 0 || clip.pptrMapping.count == 0) continue;
            const ZSAEAnimKey *keys = (const ZSAEAnimKey *)curve.keys.bytes;
            NSMutableData *timeData = [NSMutableData dataWithCapacity:keyCount * sizeof(double)];
            NSMutableData *spriteData = [NSMutableData dataWithCapacity:keyCount * sizeof(int32_t)];
            for (NSUInteger k = 0; k < keyCount; k++) {
                double time = keys[k].t;
                long long mapped = llroundf(keys[k].c[3]);
                int32_t sprite = -1;
                if (mapped >= 0 && (NSUInteger)mapped < clip.pptrMapping.count) sprite = ZSAEAnimRegisterSprite(scene, clip.owner, clip.pptrMapping[(NSUInteger)mapped]);
                [timeData appendBytes:&time length:sizeof(time)];
                [spriteData appendBytes:&sprite length:sizeof(sprite)];
            }
            ZSAEAnimSpriteBound *pptrBound = [ZSAEAnimSpriteBound new];
            pptrBound.node = (int32_t)pptrNode.integerValue;
            pptrBound.times = timeData;
            pptrBound.sprites = spriteData;
            [spriteBounds addObject:pptrBound];
            (*boundCount)++;
            continue;
        }
        int channel = ZSAEAnimChannelFor(curve.typeID, curve.attribute, curve.component);
        if (channel < 0) continue;
        (*mappableCount)++;
        NSNumber *node = root.hashToNode[@(curve.pathHash)];
        if (!node) continue;
        ZSAEAnimBound *bound = [ZSAEAnimBound new];
        bound.node = (int32_t)node.integerValue;
        bound.channel = channel;
        bound.keys = curve.keys;
        [bounds addObject:bound];
        (*boundCount)++;
    }
    for (NSDictionary *spriteCurve in clip.spriteCurves) {
        NSString *path = spriteCurve[@"path"];
        NSNumber *node = root.pathToNode[path] ?: root.hashToNode[@(ZSAECRC32(path.UTF8String ?: ""))];
        if (!node && path.length > 0) {
            NSString *leaf = path.lastPathComponent;
            NSNumber *best = nil;
            NSUInteger bestIndex = NSUIntegerMax;
            for (NSString *candidatePath in root.pathToNode) {
                if (![candidatePath.lastPathComponent isEqualToString:leaf]) continue;
                NSNumber *candidate = root.pathToNode[candidatePath];
                if (candidate.unsignedIntegerValue < bestIndex) {
                    bestIndex = candidate.unsignedIntegerValue;
                    best = candidate;
                }
            }
            node = best;
        }
        if (!node) continue;
        NSArray<NSNumber *> *times = spriteCurve[@"times"];
        NSArray<NSDictionary *> *values = spriteCurve[@"values"];
        NSMutableData *timeData = [NSMutableData dataWithCapacity:times.count * sizeof(double)];
        NSMutableData *spriteData = [NSMutableData dataWithCapacity:times.count * sizeof(int32_t)];
        for (NSUInteger i = 0; i < times.count && i < values.count; i++) {
            double time = times[i].doubleValue;
            int32_t sprite = ZSAEAnimRegisterSprite(scene, clip.owner, values[i]);
            [timeData appendBytes:&time length:sizeof(time)];
            [spriteData appendBytes:&sprite length:sizeof(sprite)];
        }
        ZSAEAnimSpriteBound *spriteBound = [ZSAEAnimSpriteBound new];
        spriteBound.node = (int32_t)node.integerValue;
        spriteBound.times = timeData;
        spriteBound.sprites = spriteData;
        [spriteBounds addObject:spriteBound];
        (*mappableCount)++;
        (*boundCount)++;
    }
    trackClip.bounds = bounds;
    trackClip.spriteBounds = spriteBounds;
}

static void ZSAEAnimApplyValue(ZSAENodeState *state, int channel, double value, double weight) {
    if ((state->mask & (1u << channel)) && weight < 1) state->v[channel] += (value - state->v[channel]) * weight;
    else state->v[channel] = value;
    state->mask |= (uint16_t)(1u << channel);
}

static void ZSAEAnimApplyClip(ZSAEAnimTrackClip *trackClip, double local, double weight, ZSAENodeState *states) {
    ZSAEAnimClip *clip = trackClip.clip;
    if (clip.loop && clip.span > 1e-6) {
        local = fmod(local, clip.span);
        if (local < 0) local += clip.span;
    }
    for (ZSAEAnimBound *bound in trackClip.bounds) {
        ZSAEAnimApplyValue(&states[bound.node], bound.channel, ZSAEAnimCurveEval(bound.keys, local), weight);
    }
    for (ZSAEAnimSpriteBound *spriteBound in trackClip.spriteBounds) {
        const double *times = (const double *)spriteBound.times.bytes;
        const int32_t *sprites = (const int32_t *)spriteBound.sprites.bytes;
        NSInteger count = (NSInteger)(spriteBound.sprites.length / sizeof(int32_t));
        if (count <= 0) continue;
        NSInteger pick = 0;
        for (NSInteger k = 0; k < count; k++) {
            if (times[k] <= local) pick = k;
            else break;
        }
        if (sprites[pick] >= 0) states[spriteBound.node].sprite = sprites[pick];
    }
}

static double ZSAEAnimExtrapolate(ZSAEAnimTrackClip *trackClip, double time, BOOL post) {
    double scale = trackClip.timeScale;
    double span = trackClip.duration * scale;
    int mode = post ? trackClip.postMode : trackClip.preMode;
    double position = (time - trackClip.start) * scale;
    if ((mode == 2 || mode == 3) && span > 1e-6) {
        if (mode == 2) {
            position = fmod(position, span);
            if (position < 0) position += span;
        } else {
            double period = span * 2;
            position = fmod(position, period);
            if (position < 0) position += period;
            if (position > span) position = period - position;
        }
        return position + trackClip.clipIn;
    }
    if (mode == 4) return position + trackClip.clipIn;
    return post ? span + trackClip.clipIn : trackClip.clipIn;
}

static double ZSAEAnimAngle(const ZSAENodeState *state) {
    if (state->mask & (1u << ZSAEChEZ)) return state->v[ZSAEChEZ] * M_PI / 180.0;
    double qx = state->v[ZSAEChQX];
    double qy = state->v[ZSAEChQY];
    double qz = state->v[ZSAEChQZ];
    double qw = state->v[ZSAEChQW];
    double norm = sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
    if (norm < 1e-9) return 0;
    qx /= norm;
    qy /= norm;
    qz /= norm;
    qw /= norm;
    return atan2(2.0 * (qw * qz + qx * qy), 1.0 - 2.0 * (qy * qy + qz * qz));
}

static NSUInteger ZSAEAnimEvaluate(ZSAEAnimScene *scene, double time, ZSAEAnimItem *items) {
    NSArray<ZSAEAnimNode *> *nodes = scene.nodes;
    NSUInteger count = nodes.count;
    if (count == 0) return 0;
    ZSAENodeState *states = calloc(count, sizeof(ZSAENodeState));
    CGAffineTransform *worlds = calloc(count, sizeof(CGAffineTransform));
    double *worldZ = calloc(count, sizeof(double));
    BOOL *visible = calloc(count, sizeof(BOOL));
    if (!states || !worlds || !worldZ || !visible) {
        free(states);
        free(worlds);
        free(worldZ);
        free(visible);
        return 0;
    }

    for (NSUInteger i = 0; i < count; i++) {
        ZSAEAnimNode *node = nodes[i];
        ZSAENodeState *state = &states[i];
        state->v[ZSAEChPX] = node.px;
        state->v[ZSAEChPY] = node.py;
        state->v[ZSAEChPZ] = node.pz;
        state->v[ZSAEChQX] = node.qx;
        state->v[ZSAEChQY] = node.qy;
        state->v[ZSAEChQZ] = node.qz;
        state->v[ZSAEChQW] = node.qw;
        state->v[ZSAEChSX] = node.sx;
        state->v[ZSAEChSY] = node.sy;
        state->v[ZSAEChR] = node.cr;
        state->v[ZSAEChG] = node.cg;
        state->v[ZSAEChB] = node.cb;
        state->v[ZSAEChA] = node.ca;
        state->v[ZSAEChActive] = node.active ? 1 : 0;
        state->v[ZSAEChEnabled] = node.rendererEnabled ? 1 : 0;
        state->sprite = node.baseSprite;
    }

    for (ZSAEAnimTrackPlay *track in scene.tracks) {
        if (track.base) ZSAEAnimApplyClip(track.base, time, 1.0, states);
        NSArray<ZSAEAnimTrackClip *> *clips = track.clips;
        NSUInteger clipTotal = clips.count;
        BOOL anyActive = NO;
        for (NSUInteger i = 0; i < clipTotal; i++) {
            ZSAEAnimTrackClip *trackClip = clips[i];
            if (time < trackClip.start || time >= trackClip.start + trackClip.duration) continue;
            anyActive = YES;
            double weight = 1;
            for (NSUInteger j = 0; j < i; j++) {
                ZSAEAnimTrackClip *other = clips[j];
                double otherEnd = other.start + other.duration;
                if (other.start < trackClip.start && otherEnd > time) {
                    double overlap = otherEnd - trackClip.start;
                    if (overlap > 1e-6) weight = MIN(weight, MAX(0.0, MIN(1.0, (time - trackClip.start) / overlap)));
                }
            }
            ZSAEAnimApplyClip(trackClip, (time - trackClip.start) * trackClip.timeScale + trackClip.clipIn, weight, states);
        }
        if (!anyActive && clipTotal > 0) {
            NSInteger previous = -1;
            double previousEnd = -INFINITY;
            for (NSUInteger i = 0; i < clipTotal; i++) {
                double end = clips[i].start + clips[i].duration;
                if (end <= time && end >= previousEnd) {
                    previous = (NSInteger)i;
                    previousEnd = end;
                }
            }
            if (previous >= 0) {
                ZSAEAnimTrackClip *trackClip = clips[(NSUInteger)previous];
                if (trackClip.postMode != 0) ZSAEAnimApplyClip(trackClip, ZSAEAnimExtrapolate(trackClip, time, YES), 1.0, states);
            } else {
                ZSAEAnimTrackClip *trackClip = clips[0];
                if (trackClip.preMode != 0) ZSAEAnimApplyClip(trackClip, ZSAEAnimExtrapolate(trackClip, time, NO), 1.0, states);
            }
        }
    }

    NSUInteger emitted = 0;
    NSUInteger spriteCount = scene.sprites.count;
    NSUInteger rendererCount = 0;
    NSUInteger spriteSet = 0;
    NSUInteger hiddenCount = 0;
    NSUInteger missingCount = 0;
    NSMutableString *spriteList = [NSMutableString string];
    for (NSUInteger i = 0; i < count; i++) {
        ZSAEAnimNode *node = nodes[i];
        ZSAENodeState *state = &states[i];
        NSInteger parent = node.parent;
        BOOL parentVisible = parent >= 0 ? visible[parent] : YES;
        visible[i] = parentVisible && !node.excluded && state->v[ZSAEChActive] > 0.5;
        if (node.hasRenderer) {
            rendererCount++;
            if (!visible[i]) hiddenCount++;
            if (state->sprite >= 0) {
                spriteSet++;
                if (spriteList.length < 90) [spriteList appendFormat:@" n%lu=s%d", (unsigned long)i, state->sprite];
            }
        }

        double angle = ZSAEAnimAngle(state);
        CGAffineTransform local = CGAffineTransformMakeScale(state->v[ZSAEChSX], state->v[ZSAEChSY]);
        local = CGAffineTransformConcat(local, CGAffineTransformMakeRotation(angle));
        local = CGAffineTransformConcat(local, CGAffineTransformMakeTranslation(state->v[ZSAEChPX], state->v[ZSAEChPY]));
        worlds[i] = parent >= 0 ? CGAffineTransformConcat(local, worlds[parent]) : local;
        worldZ[i] = (parent >= 0 ? worldZ[parent] : 0) + state->v[ZSAEChPZ];

        if (!visible[i] || !node.hasRenderer || state->v[ZSAEChEnabled] <= 0.5) continue;
        if (state->sprite < 0 || (NSUInteger)state->sprite >= spriteCount) continue;
        if (![scene.sprites[(NSUInteger)state->sprite] isKindOfClass:[ZSAESpriteImage class]]) {
            missingCount++;
            continue;
        }

        ZSAEAnimItem *item = &items[emitted++];
        item->sprite = state->sprite;
        item->world = worlds[i];
        item->z = worldZ[i];
        item->r = (float)state->v[ZSAEChR];
        item->g = (float)state->v[ZSAEChG];
        item->b = (float)state->v[ZSAEChB];
        item->a = (float)state->v[ZSAEChA];
        item->flipX = node.flipX;
        item->flipY = node.flipY;
        item->layer = node.layer;
        item->order = node.order;
        item->index = (int32_t)i;
    }

    scene.debugFrame = [NSString stringWithFormat:@"t=%.2f nodes=%lu rend=%lu set=%lu hid=%lu miss=%lu shown=%lu |%@", time, (unsigned long)count, (unsigned long)rendererCount, (unsigned long)spriteSet, (unsigned long)hiddenCount, (unsigned long)missingCount, (unsigned long)emitted, spriteList];
    free(states);
    free(worlds);
    free(worldZ);
    free(visible);
    return emitted;
}

static int ZSAEAnimItemCompare(const void *a, const void *b) {
    const ZSAEAnimItem *x = (const ZSAEAnimItem *)a;
    const ZSAEAnimItem *y = (const ZSAEAnimItem *)b;
    if (x->layer != y->layer) return x->layer < y->layer ? -1 : 1;
    if (x->order != y->order) return x->order < y->order ? -1 : 1;
    if (x->z != y->z) return x->z > y->z ? -1 : 1;
    if (x->index != y->index) return x->index < y->index ? -1 : 1;
    return 0;
}

static BOOL ZSAEAnimItemBounds(ZSAEAnimScene *scene, const ZSAEAnimItem *item, double *minX, double *minY, double *maxX, double *maxY) {
    ZSAESpriteImage *sprite = scene.sprites[(NSUInteger)item->sprite];
    double x0 = (sprite.offsetX - sprite.pivotX * sprite.rectWidth) / sprite.pixelsPerUnit;
    double y0 = (sprite.offsetY - sprite.pivotY * sprite.rectHeight) / sprite.pixelsPerUnit;
    double qw = sprite.width / sprite.pixelsPerUnit;
    double qh = sprite.height / sprite.pixelsPerUnit;
    double fx = item->flipX ? -1 : 1;
    double fy = item->flipY ? -1 : 1;
    double xs[2] = {x0, x0 + qw};
    double ys[2] = {y0, y0 + qh};
    BOOL any = NO;
    for (int i = 0; i < 2; i++) {
        for (int j = 0; j < 2; j++) {
            CGPoint point = CGPointApplyAffineTransform(CGPointMake(xs[i] * fx, ys[j] * fy), item->world);
            if (!isfinite(point.x) || !isfinite(point.y) || fabs(point.x) > 1e5 || fabs(point.y) > 1e5) continue;
            *minX = MIN(*minX, point.x);
            *maxX = MAX(*maxX, point.x);
            *minY = MIN(*minY, point.y);
            *maxY = MAX(*maxY, point.y);
            any = YES;
        }
    }
    return any;
}

static UIImage *ZSAEAnimRender(ZSAEAnimScene *scene, double time) {
    NSUInteger capacity = scene.nodes.count;
    if (capacity == 0) return nil;
    ZSAEAnimItem *items = calloc(capacity, sizeof(ZSAEAnimItem));
    if (!items) return nil;
    NSUInteger count = ZSAEAnimEvaluate(scene, time, items);
    qsort(items, count, sizeof(ZSAEAnimItem), ZSAEAnimItemCompare);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:scene.canvasSize format:format];
    CGAffineTransform worldToPixel = scene.worldToPixel;
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef cg = rendererContext.CGContext;
        CGContextSetInterpolationQuality(cg, kCGInterpolationMedium);
        for (NSUInteger i = 0; i < count; i++) {
            ZSAEAnimItem item = items[i];
            double alpha = MAX(0.0, MIN(1.0, (double)item.a));
            if (alpha <= 0) continue;
            ZSAESpriteImage *sprite = scene.sprites[(NSUInteger)item.sprite];
            UIImage *picture = sprite.image;
            if (item.r < 0.999f || item.g < 0.999f || item.b < 0.999f) {
                NSString *tintKey = [NSString stringWithFormat:@"%d:%d:%d:%d", item.sprite, (int)(MAX(0.f, MIN(1.f, item.r)) * 16), (int)(MAX(0.f, MIN(1.f, item.g)) * 16), (int)(MAX(0.f, MIN(1.f, item.b)) * 16)];
                UIImage *tinted = [scene.tintCache objectForKey:tintKey];
                if (!tinted) {
                    tinted = ZSAETintedImage(picture, item.r, item.g, item.b);
                    if (tinted) [scene.tintCache setObject:tinted forKey:tintKey];
                }
                if (tinted) picture = tinted;
            }
            double x0 = (sprite.offsetX - sprite.pivotX * sprite.rectWidth) / sprite.pixelsPerUnit;
            double y0 = (sprite.offsetY - sprite.pivotY * sprite.rectHeight) / sprite.pixelsPerUnit;
            CGAffineTransform transform = CGAffineTransformMake(1.0 / sprite.pixelsPerUnit, 0, 0, -1.0 / sprite.pixelsPerUnit, x0, y0 + sprite.height / sprite.pixelsPerUnit);
            transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(item.flipX ? -1 : 1, item.flipY ? -1 : 1));
            transform = CGAffineTransformConcat(transform, item.world);
            transform = CGAffineTransformConcat(transform, worldToPixel);
            CGContextSaveGState(cg);
            CGContextConcatCTM(cg, transform);
            [picture drawInRect:CGRectMake(0, 0, sprite.width, sprite.height) blendMode:kCGBlendModeNormal alpha:alpha];
            CGContextRestoreGState(cg);
        }
    }];
    free(items);
    return image;
}

static NSString *ZSAEDebugJoin(NSArray<NSString *> *lines) {
    if (lines.count <= 40) return [lines componentsJoinedByString:@"\n"];
    NSMutableArray<NSString *> *limited = [NSMutableArray arrayWithArray:[lines subarrayWithRange:NSMakeRange(0, 39)]];
    [limited addObject:lines.lastObject];
    return [limited componentsJoinedByString:@"\n"];
}

static ZSAssetExplorerVisual *ZSAEBuildAnimationVisual(ZSAEContext *context, ZSAEObject *object, NSArray<NSDictionary *> *rows, double total, NSString *title, NSMutableArray<NSString *> *lines, NSString **failure) {
    ZSAEAnimScene *scene = [ZSAEAnimScene new];
    scene.nodes = [NSMutableArray array];
    scene.roots = [NSMutableArray array];
    scene.rootIndexByKey = [NSMutableDictionary dictionary];
    scene.tracks = [NSMutableArray array];
    scene.spriteRefs = [NSMutableArray array];
    scene.spriteIndexByKey = [NSMutableDictionary dictionary];
    scene.sprites = [NSMutableArray array];
    scene.tintCache = [[NSCache alloc] init];
    scene.tintCache.countLimit = 96;

    NSArray<ZSAssetExplorerAsset *> *assets = nil;
    ZSAEParseSerializedFile(object.session.serializedData, &assets, INT64_MIN, NULL, NULL, NULL, NULL, NULL);
    NSMutableArray<ZSAEObject *> *directors = [NSMutableArray array];
    NSMutableArray<ZSAEObject *> *animators = [NSMutableArray array];
    for (ZSAssetExplorerAsset *asset in assets) {
        if (asset.classID == 320 && directors.count < 8) {
            ZSAEObject *director = ZSAEReadObject(object.session, asset.pathID, NULL);
            if (director) [directors addObject:director];
        } else if (asset.classID == 95 && animators.count < 6) {
            ZSAEObject *animator = ZSAEReadObject(object.session, asset.pathID, NULL);
            if (animator) [animators addObject:animator];
        }
    }

    [lines addObject:[NSString stringWithFormat:@"rows=%lu total=%.2fs dir=%lu anim=%lu assets=%lu", (unsigned long)rows.count, total, (unsigned long)directors.count, (unsigned long)animators.count, (unsigned long)assets.count]];
    NSMutableDictionary<NSString *, id> *clipCache = [NSMutableDictionary dictionary];
    NSUInteger rowNumber = 0;
    NSUInteger decodedClips = 0;
    NSUInteger animationTracks = 0;
    NSUInteger unboundTracks = 0;
    NSUInteger boundCount = 0;
    NSUInteger mappableCount = 0;
    NSMutableSet<NSNumber *> *usedRoots = [NSMutableSet set];

    for (NSDictionary *row in rows) {
        if ([row[@"muted"] boolValue]) continue;
        ZSAEObject *trackObject = row[@"object"];
        if (!trackObject) continue;
        int64_t trackPathID = [row[@"pathID"] longLongValue];

        NSMutableArray<ZSAEAnimTrackClip *> *trackClips = [NSMutableArray array];
        for (NSDictionary *entry in row[@"clips"]) {
            NSDictionary *assetPointer = entry[@"asset"];
            if (ZSAEInt(assetPointer[@"m_PathID"]) == 0) continue;
            ZSAEObject *playable = ZSAEResolvePPtr(context, trackObject, assetPointer, NULL);
            if (!playable) continue;
            ZSAEAnimClip *clip = ZSAEAnimLoadClip(context, playable, playable.fields[@"m_Clip"], clipCache, lines);
            if (!clip) continue;
            ZSAEAnimTrackClip *trackClip = [ZSAEAnimTrackClip new];
            trackClip.clip = clip;
            trackClip.start = [entry[@"s"] doubleValue];
            trackClip.duration = [entry[@"d"] doubleValue];
            trackClip.clipIn = [entry[@"ci"] doubleValue];
            trackClip.timeScale = [entry[@"ts"] doubleValue];
            trackClip.preMode = (int)[entry[@"pre"] integerValue];
            trackClip.postMode = (int)[entry[@"post"] integerValue];
            [trackClips addObject:trackClip];
            decodedClips++;
        }
        [trackClips sortUsingComparator:^NSComparisonResult(ZSAEAnimTrackClip *a, ZSAEAnimTrackClip *b) {
            return a.start < b.start ? NSOrderedAscending : (a.start > b.start ? NSOrderedDescending : NSOrderedSame);
        }];

        ZSAEAnimTrackClip *baseClip = nil;
        NSDictionary *infinitePointer = row[@"infinitePtr"];
        if (ZSAEInt(infinitePointer[@"m_PathID"]) != 0) {
            ZSAEAnimClip *clip = ZSAEAnimLoadClip(context, trackObject, infinitePointer, clipCache, lines);
            if (clip) {
                baseClip = [ZSAEAnimTrackClip new];
                baseClip.clip = clip;
                baseClip.timeScale = 1;
                decodedClips++;
            }
        }
        rowNumber++;
        if (rowNumber <= 12) {
            NSMutableString *timing = [NSMutableString string];
            for (NSUInteger k = 0; k < trackClips.count && k < 2; k++) {
                ZSAEAnimTrackClip *timed = trackClips[k];
                [timing appendFormat:@" c%lu=%.2f+%.2f ts%.2f ci%.2f", (unsigned long)k, timed.start, timed.duration, timed.timeScale, timed.clipIn];
            }
            [lines addObject:[NSString stringWithFormat:@"T%lu %@ clips=%lu/%lu base=%d inf=%lld%@", (unsigned long)rowNumber, row[@"name"], (unsigned long)trackClips.count, (unsigned long)[row[@"clips"] count], baseClip ? 1 : 0, (long long)ZSAEInt(infinitePointer[@"m_PathID"]), timing]];
        }
        if (trackClips.count == 0 && !baseClip) continue;
        animationTracks++;

        NSMutableSet<NSNumber *> *hashes = [NSMutableSet set];
        NSMutableSet<NSNumber *> *spriteHashes = [NSMutableSet set];
        for (ZSAEAnimTrackClip *trackClip in trackClips) {
            for (ZSAEAnimCurve *curve in trackClip.clip.curves) {
                [hashes addObject:@(curve.pathHash)];
                if (curve.pptr) [spriteHashes addObject:@(curve.pathHash)];
            }
        }
        for (ZSAEAnimCurve *curve in baseClip.clip.curves) {
            [hashes addObject:@(curve.pathHash)];
            if (curve.pptr) [spriteHashes addObject:@(curve.pathHash)];
        }

        NSString *rootKey = nil;
        ZSAEObject *rootObject = ZSAEAnimBoundTarget(context, scene, directors, trackPathID, &rootKey);
        NSInteger rootIndex = -1;
        if (rootObject && rootKey) {
            rootIndex = ZSAEAnimEnsureRoot(context, scene, rootObject, rootKey);
        } else {
            NSInteger bestScore = 0;
            for (ZSAEObject *animator in animators) {
                NSDictionary *goPointer = ZSAEDict(animator.fields[@"m_GameObject"]);
                ZSAEObject *go = goPointer ? ZSAEAnimRead(scene, context, animator, goPointer) : nil;
                if (!go || go.classID != 1) continue;
                NSString *candidateKey = [NSString stringWithFormat:@"%p:%lld:%lld", animator.session, (long long)ZSAEInt(goPointer[@"m_FileID"]), (long long)ZSAEInt(goPointer[@"m_PathID"])];
                NSInteger candidateIndex = ZSAEAnimEnsureRoot(context, scene, go, candidateKey);
                ZSAEAnimRoot *candidate = scene.roots[(NSUInteger)candidateIndex];
                NSInteger score = 0;
                for (NSNumber *hash in hashes) if (candidate.hashToNode[hash]) score++;
                if (animators.count == 1 && score == 0) score = 1;
                if (score > bestScore) {
                    bestScore = score;
                    rootIndex = candidateIndex;
                }
            }
        }
        BOOL synthetic = NO;
        if (rootIndex < 0 && hashes.count > 0) {
            rootIndex = ZSAEAnimEnsureSyntheticRoot(scene, @"synthetic");
            ZSAEAnimSynthesizeNodes(scene, rootIndex, hashes, spriteHashes, (int32_t)animationTracks);
            synthetic = YES;
        }
        if (rootIndex < 0) {
            unboundTracks++;
            if (rowNumber <= 12) [lines addObject:[NSString stringWithFormat:@"T%lu rig=none hashes=%lu", (unsigned long)rowNumber, (unsigned long)hashes.count]];
            continue;
        }
        ZSAEAnimRoot *root = scene.roots[(NSUInteger)rootIndex];
        [usedRoots addObject:@(rootIndex)];

        ZSAEAnimTrackPlay *play = [ZSAEAnimTrackPlay new];
        for (ZSAEAnimTrackClip *trackClip in trackClips) ZSAEAnimBindClip(scene, root, trackClip, &boundCount, &mappableCount);
        if (baseClip) {
            ZSAEAnimBindClip(scene, root, baseClip, &boundCount, &mappableCount);
            play.base = baseClip;
        }
        play.clips = trackClips;
        [scene.tracks addObject:play];
        if (rowNumber <= 12) {
            NSMutableArray<ZSAEAnimTrackClip *> *bindList = [NSMutableArray arrayWithArray:trackClips];
            if (baseClip) [bindList addObject:baseClip];
            NSUInteger spriteBoundTotal = 0;
            NSUInteger floatBoundTotal = 0;
            NSString *firstSprite = @"";
            for (ZSAEAnimTrackClip *bound in bindList) {
                floatBoundTotal += bound.bounds.count;
                for (ZSAEAnimSpriteBound *spriteBound in bound.spriteBounds) {
                    NSUInteger keyTotal = spriteBound.times.length / sizeof(double);
                    if (spriteBoundTotal == 0 && keyTotal > 0) {
                        const double *times = (const double *)spriteBound.times.bytes;
                        const int32_t *picks = (const int32_t *)spriteBound.sprites.bytes;
                        firstSprite = [NSString stringWithFormat:@" sb0 n%d k=%lu t=%g..%g s=%d..%d", spriteBound.node, (unsigned long)keyTotal, times[0], times[keyTotal - 1], picks[0], picks[keyTotal - 1]];
                    }
                    spriteBoundTotal++;
                }
            }
            [lines addObject:[NSString stringWithFormat:@"T%lu rig=%@ root=%ld hashes=%lu spr=%lu flt=%lu%@", (unsigned long)rowNumber, synthetic ? @"synth" : @"real", (long)rootIndex, (unsigned long)hashes.count, (unsigned long)spriteBoundTotal, (unsigned long)floatBoundTotal, firstSprite]];
        }
    }

    if (scene.tracks.count == 0) {
        if (animationTracks == 0) *failure = decodedClips == 0 ? @"No animation clip data could be decoded" : @"No animation tracks found";
        else *failure = @"No Animator or director binding found in this bundle";
        return nil;
    }
    if (boundCount == 0) {
        *failure = @"Clip curves don't match the rig's transform paths";
        return nil;
    }

    NSUInteger animatedCurves = 0;
    NSUInteger spriteSwaps = 0;
    for (ZSAEAnimTrackPlay *play in scene.tracks) {
        NSMutableArray<ZSAEAnimTrackClip *> *allClips = [NSMutableArray arrayWithArray:play.clips];
        if (play.base) [allClips addObject:play.base];
        for (ZSAEAnimTrackClip *candidate in allClips) {
            for (ZSAEAnimBound *bound in candidate.bounds) if (bound.keys.length > sizeof(ZSAEAnimKey)) animatedCurves++;
            for (ZSAEAnimSpriteBound *spriteBound in candidate.spriteBounds) if (spriteBound.sprites.length > sizeof(int32_t)) spriteSwaps++;
        }
    }
    NSString *motionSummary = (animatedCurves + spriteSwaps == 0) ? @"  •  no motion data" :
        [NSString stringWithFormat:@"  •  %lu animated  •  %lu sprite swaps", (unsigned long)animatedCurves, (unsigned long)spriteSwaps];

    for (NSUInteger r = 0; r < scene.roots.count; r++) {
        if ([usedRoots containsObject:@(r)]) continue;
        for (ZSAEAnimNode *node in scene.nodes) if (node.root == (NSInteger)r) node.excluded = YES;
    }

    NSUInteger refCount = scene.spriteRefs.count;
    NSMutableArray<id> *spriteObjects = [NSMutableArray arrayWithCapacity:refCount];
    for (NSUInteger i = 0; i < refCount; i++) {
        NSDictionary *ref = scene.spriteRefs[i];
        ZSAEObject *sprite = ZSAEAnimRead(scene, context, ref[@"owner"], ref[@"pptr"]);
        [spriteObjects addObject:(sprite && sprite.classID == 213) ? sprite : (id)[NSNull null]];
        [scene.sprites addObject:[NSNull null]];
    }
    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:refCount];
    for (NSUInteger i = 0; i < refCount; i++) if ([spriteObjects[i] isKindOfClass:[ZSAEObject class]]) [order addObject:@(i)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [ZSAESpriteGroupKey(spriteObjects[a.unsignedIntegerValue]) compare:ZSAESpriteGroupKey(spriteObjects[b.unsignedIntegerValue])];
    }];
    NSMutableDictionary *spriteCache = [NSMutableDictionary dictionary];
    spriteCache[@"atlases"] = [NSMutableDictionary dictionary];
    spriteCache[@"textures"] = [NSMutableDictionary dictionary];
    NSUInteger decodedSprites = 0;
    NSString *firstSpriteError = nil;
    for (NSNumber *index in order) {
        NSError *spriteError = nil;
        ZSAESpriteImage *image = ZSAEMakeSpriteImage(context, spriteObjects[index.unsignedIntegerValue], spriteCache, &spriteError);
        if (image) {
            scene.sprites[index.unsignedIntegerValue] = image;
            decodedSprites++;
        } else if (!firstSpriteError) {
            firstSpriteError = spriteError.localizedDescription ?: @"nil";
        }
    }
    [lines addObject:[NSString stringWithFormat:@"nodes=%lu roots=%lu refs=%lu objs=%lu dec=%lu bound=%lu/%lu swaps=%lu anim=%lu%@", (unsigned long)scene.nodes.count, (unsigned long)scene.roots.count, (unsigned long)refCount, (unsigned long)order.count, (unsigned long)decodedSprites, (unsigned long)boundCount, (unsigned long)mappableCount, (unsigned long)spriteSwaps, (unsigned long)animatedCurves, firstSpriteError ? [NSString stringWithFormat:@" err=%@", firstSpriteError] : @""]];
    if (decodedSprites == 0) {
        *failure = @"None of the sprites could be decoded";
        return nil;
    }

    double minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
    double maxPPU = 1;
    ZSAEAnimItem *probe = calloc(scene.nodes.count, sizeof(ZSAEAnimItem));
    if (!probe) {
        *failure = @"Out of memory";
        return nil;
    }
    const int samples = 24;
    for (int s = 0; s < samples; s++) {
        double sampleTime = total * (double)s / (double)(samples - 1);
        NSUInteger emitted = ZSAEAnimEvaluate(scene, sampleTime, probe);
        for (NSUInteger i = 0; i < emitted; i++) {
            if (ZSAEAnimItemBounds(scene, &probe[i], &minX, &minY, &maxX, &maxY)) {
                ZSAESpriteImage *sprite = scene.sprites[(NSUInteger)probe[i].sprite];
                maxPPU = MAX(maxPPU, sprite.pixelsPerUnit);
            }
        }
    }
    free(probe);
    double boundsWidth = maxX - minX;
    double boundsHeight = maxY - minY;
    if (!(boundsWidth > 0) || !(boundsHeight > 0)) {
        *failure = @"No sprite is visible during the timeline";
        return nil;
    }
    double scale = MIN(768.0 / MAX(boundsWidth, boundsHeight), maxPPU);
    CGFloat pad = 8;
    scene.canvasSize = CGSizeMake(MAX(16, ceil(boundsWidth * scale) + pad * 2), MAX(16, ceil(boundsHeight * scale) + pad * 2));
    scene.worldToPixel = CGAffineTransformMake(scale, 0, 0, -scale, -minX * scale + pad, maxY * scale + pad);

    double loopLength = total + 0.5;
    [lines addObject:[NSString stringWithFormat:@"bounds=%.2fx%.2f ppu=%.0f canvas=%.0fx%.0f loop=%.2f", boundsWidth, boundsHeight, maxPPU, scene.canvasSize.width, scene.canvasSize.height, loopLength]];
    NSString *staticDebug = ZSAEDebugJoin(lines);
    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = title;
    visual.debugText = staticDebug;
    visual.liveDebugProvider = ^NSString *(NSTimeInterval elapsed) {
        return [NSString stringWithFormat:@"%@\n%@", staticDebug, scene.debugFrame ?: @""];
    };
    visual.summary = [NSString stringWithFormat:@"%@  •  Animation  •  %lu %@  •  %lu %@  •  %@  •  %lu/%lu curves bound%@%@", title.length > 0 ? title : @"Track",
                      (unsigned long)scene.tracks.count, scene.tracks.count == 1 ? @"track" : @"tracks",
                      (unsigned long)decodedSprites, decodedSprites == 1 ? @"sprite" : @"sprites",
                      ZSAETimelineSeconds(total), (unsigned long)boundCount, (unsigned long)mappableCount,
                      unboundTracks > 0 ? [NSString stringWithFormat:@"  •  %lu unbound", (unsigned long)unboundTracks] : @"",
                      motionSummary];
    visual.pageLabels = @[@"Animation", @"Timeline"];
    visual.livePageIndex = 0;
    NSArray<NSDictionary *> *capturedRows = [rows copy];
    double capturedTotal = total;
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        if (page == 1) return ZSAERenderTimeline(capturedRows, capturedTotal);
        return ZSAEAnimRender(scene, 0);
    };
    visual.liveFrameProvider = ^UIImage *(NSTimeInterval elapsed) {
        double position = fmod(elapsed, loopLength);
        return ZSAEAnimRender(scene, MIN(position, capturedTotal));
    };
    return visual;
}

static ZSAssetExplorerVisual *ZSAEBuildTimelineVisual(ZSAEContext *context, ZSAEObject *object, int64_t pathID) {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray *trackPointers = ZSAEArray(object.fields[@"m_Tracks"]);
    if (trackPointers) {
        for (id pointer in trackPointers) {
            NSDictionary *reference = ZSAEDict(pointer);
            if (!reference || ZSAEInt(reference[@"m_PathID"]) == 0) continue;
            NSString *identity = [NSString stringWithFormat:@"%lld:%lld", (long long)ZSAEInt(reference[@"m_FileID"]), (long long)ZSAEInt(reference[@"m_PathID"])];
            if ([seen containsObject:identity]) continue;
            [seen addObject:identity];
            ZSAEObject *trackObject = ZSAEResolvePPtr(context, object, reference, NULL);
            if (trackObject && trackObject.classID == 114) ZSAETimelineCollect(context, trackObject, ZSAEInt(reference[@"m_PathID"]), 0, rows, seen);
        }
    } else {
        ZSAETimelineCollect(context, object, pathID, 0, rows, seen);
    }
    if (rows.count == 0) return nil;

    double total = 0;
    NSUInteger clipCount = 0;
    for (NSDictionary *row in rows) {
        for (NSDictionary *clip in row[@"clips"]) {
            total = MAX(total, [clip[@"s"] doubleValue] + [clip[@"d"] doubleValue]);
            clipCount++;
        }
    }
    if (clipCount == 0) return nil;
    if (total <= 0) total = 1;

    NSArray<NSDictionary *> *captured = [rows copy];
    double capturedTotal = total;
    NSString *name = ZSAEString(object.fields[@"m_Name"]);
    NSString *failure = nil;
    NSMutableArray<NSString *> *debugLines = [NSMutableArray array];
    ZSAssetExplorerVisual *animated = ZSAEBuildAnimationVisual(context, object, captured, total, name, debugLines, &failure);
    if (animated) return animated;
    if (failure.length > 0) [debugLines addObject:[NSString stringWithFormat:@"FAIL %@", failure]];
    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = name;
    visual.summary = [NSString stringWithFormat:@"%@  •  Timeline  •  %lu %@  •  %lu %@  •  %@", name.length > 0 ? name : @"Track", (unsigned long)clipCount, clipCount == 1 ? @"clip" : @"clips", (unsigned long)captured.count, captured.count == 1 ? @"track" : @"tracks", ZSAETimelineSeconds(total)];
    if (failure.length > 0) visual.summary = [visual.summary stringByAppendingFormat:@"  •  No playback: %@", failure];
    visual.pageLabels = @[@"Timeline"];
    visual.debugText = ZSAEDebugJoin(debugLines);
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        return ZSAERenderTimeline(captured, capturedTotal);
    };
    return visual;
}

static ZSAssetExplorerVisual *ZSAEBuildMonoBehaviourVisual(ZSAEContext *context, ZSAEObject *object, int64_t pathID, NSError **error) {
    NSDictionary *fields = object.fields;
    ZSAssetExplorerVisual *timelineVisual = ZSAEBuildTimelineVisual(context, object, pathID);
    if (timelineVisual) return timelineVisual;
    NSMutableArray<ZSAEObject *> *targets = [NSMutableArray array];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    __block NSUInteger attempts = 0;

    void (^consider)(id, NSString *) = ^(id pointer, NSString *label) {
        NSDictionary *reference = ZSAEDict(pointer);
        if (!reference || !ZSAEIsPPtr(reference) || ZSAEInt(reference[@"m_PathID"]) == 0 || attempts >= 16) return;
        NSString *identity = [NSString stringWithFormat:@"%lld:%lld", (long long)ZSAEInt(reference[@"m_FileID"]), (long long)ZSAEInt(reference[@"m_PathID"])];
        if ([seen containsObject:identity]) return;
        [seen addObject:identity];
        attempts++;
        ZSAEObject *target = ZSAEResolvePPtr(context, object, reference, NULL);
        if (!target || (target.classID != 213 && target.classID != 28)) return;
        NSString *targetName = ZSAEString(target.fields[@"m_Name"]);
        [targets addObject:target];
        [labels addObject:targetName.length > 0 ? [NSString stringWithFormat:@"%@  %@", label, targetName] : label];
    };

    NSArray<NSArray<NSString *> *> *keys = @[
        @[@"m_Sprite", @"Sprite"], @[@"m_OverrideSprite", @"Override sprite"], @[@"sprite", @"Sprite"],
        @[@"m_Texture", @"Texture"], @[@"texture", @"Texture"], @[@"spriteSheet", @"Sprite sheet"],
        @[@"m_Icon", @"Icon"], @[@"icon", @"Icon"], @[@"m_Image", @"Image"], @[@"atlas", @"Atlas"],
    ];
    for (NSArray<NSString *> *entry in keys) consider(fields[entry[0]], entry[1]);
    NSArray *atlasTextures = ZSAEArray(fields[@"m_AtlasTextures"]);
    for (NSUInteger i = 0; i < atlasTextures.count && i < 8; i++) {
        consider(atlasTextures[i], [NSString stringWithFormat:@"Atlas %lu", (unsigned long)(i + 1)]);
    }

    if (targets.count == 0) return ZSAEBuildInspectorVisual(object, error);

    NSArray<ZSAEObject *> *resolved = [targets copy];
    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    NSString *name = ZSAEString(fields[@"m_Name"]);
    visual.name = name;
    NSString *head = name.length > 0 ? name : @"MonoBehaviour";
    visual.summary = [NSString stringWithFormat:@"%@  •  %@%@", head, labels.firstObject, labels.count > 1 ? [NSString stringWithFormat:@"  •  %lu images", (unsigned long)labels.count] : @""];
    visual.pageLabels = [labels copy];
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        if (page < 0 || page >= (NSInteger)resolved.count) return nil;
        ZSAEObject *target = resolved[(NSUInteger)page];
        if (target.classID == 213) {
            ZSAESpriteImage *result = ZSAEMakeSpriteImage(context, target, nil, providerError);
            return result.image;
        }
        ZSAETextureRecord *record = nil;
        NSMutableData *rgba = nil;
        if (!ZSAEDecodeTextureObject(target, &record, &rgba, providerError)) return nil;
        return ZSAEImageFromRGBA(rgba, record.width, record.height);
    };
    return visual;
}

static BOOL ZSAEIsImageClass(int32_t classID) {
    switch (classID) {
        case 28:
        case 89:
        case 117:
        case 187:
        case 188:
        case 213:
        case 687078895:
            return YES;
        default:
            return NO;
    }
}

#define ZSAE_PS_MAXKEYS 16
#define ZSAE_PS_MAXPARTICLES 2048
#define ZSAE_PS_MAXBURSTS 8

typedef struct {
    float t, v, inS, outS;
} ZSAEPSKey;

typedef struct {
    int count;
    ZSAEPSKey keys[ZSAE_PS_MAXKEYS];
} ZSAEPSCurve;

typedef struct {
    int state;
    float scalar;
    ZSAEPSCurve maxC;
    ZSAEPSCurve minC;
} ZSAEPSMinMax;

typedef struct {
    int mode;
    int colorCount;
    int alphaCount;
    float ct[8];
    float cr[8], cg[8], cb[8];
    float at[8];
    float av[8];
} ZSAEPSGradient;

typedef struct {
    int state;
    float minColor[4];
    float maxColor[4];
    ZSAEPSGradient minG;
    ZSAEPSGradient maxG;
} ZSAEPSColor;

typedef struct {
    float time;
    ZSAEPSMinMax count;
    int cycles;
    float interval;
    float probability;
} ZSAEPSBurst;

typedef struct {
    float duration;
    int looping;
    float simSpeed;
    float startDelay;
    uint32_t seed;

    ZSAEPSMinMax startLifetime;
    ZSAEPSMinMax startSpeed;
    ZSAEPSMinMax startSizeX;
    ZSAEPSMinMax startSizeY;
    ZSAEPSMinMax startRotation;
    ZSAEPSMinMax gravity;
    ZSAEPSColor startColor;
    float randomizeRotationDirection;
    int size3D;
    int maxParticles;

    int emissionEnabled;
    ZSAEPSMinMax rate;
    int burstCount;
    ZSAEPSBurst bursts[ZSAE_PS_MAXBURSTS];

    int shapeEnabled;
    int shapeType;
    float angle;
    float radius;
    float radiusThickness;
    float arc;
    float length;
    float donutRadius;
    float box[3];
    float shapePos[3];
    float shapeRot[4];
    float shapeScale[3];
    float randomDirection;
    float sphericalDirection;
    float randomPosition;

    int velEnabled;
    ZSAEPSMinMax velX, velY, velZ;
    ZSAEPSMinMax speedModifier;
    int velWorld;

    int forceEnabled;
    ZSAEPSMinMax forceX, forceY, forceZ;
    int forceWorld;

    int sizeEnabled;
    int sizeSeparate;
    ZSAEPSMinMax sizeX, sizeY;

    int rotEnabled;
    ZSAEPSMinMax rotSpeed;

    int colorEnabled;
    ZSAEPSColor colorOverLife;

    int uvEnabled;
    int tilesX, tilesY;
    int uvAnimType;
    int uvRow;
    int uvRandomRow;
    float uvCycles;
    ZSAEPSMinMax uvFrame;
    ZSAEPSMinMax uvStart;

    int renderMode;
    float lengthScale;
    float velocityScale;
    int additive;
    float tint[4];

    float emitterRot[4];
} ZSAEPSParams;

typedef struct {
    float pos[3];
    float vel[3];
    float age, life;
    float sizeX, sizeY;
    float rot;
    float color[4];
    float rVel, rForce, rSize, rRot, rColor, rFrame, rSpeed, rRow;
    float sysT;
} ZSAEPSParticle;

typedef struct {
    ZSAEPSParams P;
    ZSAEPSParticle parts[ZSAE_PS_MAXPARTICLES];
    int count;
    double time;
    double emitAccum;
    uint64_t rng;
} ZSAEPSSim;

typedef struct {
    float cx, cy;
    float sdx, sdy, tdx, tdy;
    float minX, maxX, minY, maxY;
    float r, g, b, a;
    float u0, v0, du, dv;
} ZSAEPSQuad;

static float ZSAEPSRand(uint64_t *state) {
    uint64_t x = *state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *state = x;
    uint64_t r = x * 2685821657736338717ULL;
    return (float)((r >> 40) & 0xFFFFFF) / 16777216.0f;
}

static float ZSAEPSClamp(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static float ZSAEPSLerp(float a, float b, float t) {
    return a + (b - a) * t;
}

static float ZSAEPSKeysEval(const ZSAEPSKey *keys, int n, float t) {
    if (n <= 0) return 1.0f;
    if (n == 1 || t <= keys[0].t) return keys[0].v;
    if (t >= keys[n - 1].t) return keys[n - 1].v;
    int i = 0;
    while (i < n - 2 && t >= keys[i + 1].t) i++;
    const ZSAEPSKey *k0 = &keys[i];
    const ZSAEPSKey *k1 = &keys[i + 1];
    float dt = k1->t - k0->t;
    if (dt <= 1e-6f) return k1->v;
    if (!isfinite(k0->outS) || !isfinite(k1->inS)) return k0->v;
    float u = (t - k0->t) / dt;
    float u2 = u * u;
    float u3 = u2 * u;
    float m0 = k0->outS * dt;
    float m1 = k1->inS * dt;
    return (2 * u3 - 3 * u2 + 1) * k0->v + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * k1->v + (u3 - u2) * m1;
}

static float ZSAEPSCurveEval(const ZSAEPSCurve *c, float t) {
    return ZSAEPSKeysEval(c->keys, c->count, t);
}

static float ZSAEPSMinMaxEval(const ZSAEPSMinMax *m, float t, float rnd) {
    t = ZSAEPSClamp(t, 0, 1);
    switch (m->state) {
        case 1:
            return m->scalar * ZSAEPSCurveEval(&m->maxC, t);
        case 2: {
            float a = ZSAEPSCurveEval(&m->minC, t);
            float b = ZSAEPSCurveEval(&m->maxC, t);
            return m->scalar * ZSAEPSLerp(a, b, rnd);
        }
        case 3: {
            float a = ZSAEPSCurveEval(&m->minC, 0);
            float b = ZSAEPSCurveEval(&m->maxC, 0);
            return m->scalar * ZSAEPSLerp(a, b, rnd);
        }
        default:
            return m->scalar;
    }
}

static void ZSAEPSGradientEval(const ZSAEPSGradient *g, float t, float out[4]) {
    t = ZSAEPSClamp(t, 0, 1);
    int cn = g->colorCount;
    if (cn <= 0) {
        out[0] = out[1] = out[2] = 1;
    } else if (cn == 1 || t <= g->ct[0]) {
        out[0] = g->cr[0]; out[1] = g->cg[0]; out[2] = g->cb[0];
    } else if (t >= g->ct[cn - 1]) {
        out[0] = g->cr[cn - 1]; out[1] = g->cg[cn - 1]; out[2] = g->cb[cn - 1];
    } else {
        int i = 0;
        while (i < cn - 2 && t >= g->ct[i + 1]) i++;
        if (g->mode == 1) {
            int j = i + 1;
            out[0] = g->cr[j]; out[1] = g->cg[j]; out[2] = g->cb[j];
        } else {
            float span = g->ct[i + 1] - g->ct[i];
            float u = span > 1e-6f ? (t - g->ct[i]) / span : 1.0f;
            out[0] = ZSAEPSLerp(g->cr[i], g->cr[i + 1], u);
            out[1] = ZSAEPSLerp(g->cg[i], g->cg[i + 1], u);
            out[2] = ZSAEPSLerp(g->cb[i], g->cb[i + 1], u);
        }
    }
    int an = g->alphaCount;
    if (an <= 0) {
        out[3] = 1;
    } else if (an == 1 || t <= g->at[0]) {
        out[3] = g->av[0];
    } else if (t >= g->at[an - 1]) {
        out[3] = g->av[an - 1];
    } else {
        int i = 0;
        while (i < an - 2 && t >= g->at[i + 1]) i++;
        if (g->mode == 1) {
            out[3] = g->av[i + 1];
        } else {
            float span = g->at[i + 1] - g->at[i];
            float u = span > 1e-6f ? (t - g->at[i]) / span : 1.0f;
            out[3] = ZSAEPSLerp(g->av[i], g->av[i + 1], u);
        }
    }
}

static void ZSAEPSColorEval(const ZSAEPSColor *c, float t, float rnd, float out[4]) {
    switch (c->state) {
        case 1:
            ZSAEPSGradientEval(&c->maxG, t, out);
            break;
        case 2:
            for (int i = 0; i < 4; i++) out[i] = ZSAEPSLerp(c->minColor[i], c->maxColor[i], rnd);
            break;
        case 3: {
            float a[4], b[4];
            ZSAEPSGradientEval(&c->minG, t, a);
            ZSAEPSGradientEval(&c->maxG, t, b);
            for (int i = 0; i < 4; i++) out[i] = ZSAEPSLerp(a[i], b[i], rnd);
            break;
        }
        case 4:
            ZSAEPSGradientEval(&c->maxG, rnd, out);
            break;
        default:
            for (int i = 0; i < 4; i++) out[i] = c->maxColor[i];
            break;
    }
}

static void ZSAEPSRotate(const float q[4], const float v[3], float out[3]) {
    float cx = q[1] * v[2] - q[2] * v[1] + q[3] * v[0];
    float cy = q[2] * v[0] - q[0] * v[2] + q[3] * v[1];
    float cz = q[0] * v[1] - q[1] * v[0] + q[3] * v[2];
    out[0] = v[0] + 2 * (q[1] * cz - q[2] * cy);
    out[1] = v[1] + 2 * (q[2] * cx - q[0] * cz);
    out[2] = v[2] + 2 * (q[0] * cy - q[1] * cx);
}

static void ZSAEPSQuatMul(const float a[4], const float b[4], float out[4]) {
    out[0] = a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1];
    out[1] = a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0];
    out[2] = a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3];
    out[3] = a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2];
}

static void ZSAEPSQuatFromEuler(float xDeg, float yDeg, float zDeg, float out[4]) {
    float d2r = 0.01745329252f * 0.5f;
    float sx = sinf(xDeg * d2r), cx = cosf(xDeg * d2r);
    float sy = sinf(yDeg * d2r), cy = cosf(yDeg * d2r);
    float sz = sinf(zDeg * d2r), cz = cosf(zDeg * d2r);
    float qx[4] = { sx, 0, 0, cx };
    float qy[4] = { 0, sy, 0, cy };
    float qz[4] = { 0, 0, sz, cz };
    float t[4];
    ZSAEPSQuatMul(qy, qx, t);
    ZSAEPSQuatMul(t, qz, out);
}

static void ZSAEPSNormalize(float v[3]) {
    float l = sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l > 1e-6f) {
        v[0] /= l; v[1] /= l; v[2] /= l;
    }
}

static void ZSAEPSRandomUnit(uint64_t *rng, float out[3]) {
    float z = ZSAEPSRand(rng) * 2 - 1;
    float phi = ZSAEPSRand(rng) * 6.2831853f;
    float r = sqrtf(fmaxf(0, 1 - z * z));
    out[0] = r * cosf(phi);
    out[1] = r * sinf(phi);
    out[2] = z;
}

static void ZSAEPSShapeSample(ZSAEPSSim *S, float pos[3], float dir[3]) {
    const ZSAEPSParams *P = &S->P;
    uint64_t *rng = &S->rng;
    pos[0] = pos[1] = pos[2] = 0;
    dir[0] = 0; dir[1] = 0; dir[2] = 1;
    if (!P->shapeEnabled) return;

    float radius = fmaxf(P->radius, 0);
    float thickness = ZSAEPSClamp(P->radiusThickness, 0, 1);
    float arc = ZSAEPSClamp(P->arc, 0, 360) * 0.01745329252f;
    float angle = ZSAEPSClamp(P->angle, 0, 89.9f) * 0.01745329252f;

    switch (P->shapeType) {
        case 0: case 1: case 2: case 3: {
            float t = (P->shapeType == 1 || P->shapeType == 3) ? 0 : thickness;
            float inner = 1 - t;
            float r = radius * cbrtf(ZSAEPSLerp(inner * inner * inner, 1, ZSAEPSRand(rng)));
            ZSAEPSRandomUnit(rng, dir);
            if ((P->shapeType == 2 || P->shapeType == 3) && dir[2] < 0) dir[2] = -dir[2];
            pos[0] = dir[0] * r; pos[1] = dir[1] * r; pos[2] = dir[2] * r;
            break;
        }
        case 4: case 7: case 8: case 9: {
            float t = (P->shapeType == 7 || P->shapeType == 9) ? 0 : thickness;
            float inner = 1 - t;
            float r = radius * sqrtf(ZSAEPSLerp(inner * inner, 1, ZSAEPSRand(rng)));
            float phi = arc * ZSAEPSRand(rng);
            float theta = radius > 1e-4f ? angle * (r / radius) : angle * ZSAEPSRand(rng);
            float zOff = (P->shapeType == 8 || P->shapeType == 9) ? P->length * ZSAEPSRand(rng) : 0;
            pos[0] = r * cosf(phi); pos[1] = r * sinf(phi); pos[2] = zOff;
            dir[0] = sinf(theta) * cosf(phi); dir[1] = sinf(theta) * sinf(phi); dir[2] = cosf(theta);
            break;
        }
        case 5: {
            for (int i = 0; i < 3; i++) pos[i] = (ZSAEPSRand(rng) - 0.5f) * P->box[i];
            break;
        }
        case 15: {
            float a0 = P->box[1] * P->box[2], a1 = P->box[0] * P->box[2], a2 = P->box[0] * P->box[1];
            float pick = ZSAEPSRand(rng) * (a0 + a1 + a2);
            int axis = pick < a0 ? 0 : (pick < a0 + a1 ? 1 : 2);
            for (int i = 0; i < 3; i++) pos[i] = (ZSAEPSRand(rng) - 0.5f) * P->box[i];
            pos[axis] = (ZSAEPSRand(rng) < 0.5f ? -0.5f : 0.5f) * P->box[axis];
            break;
        }
        case 16: {
            int axis = (int)(ZSAEPSRand(rng) * 3) % 3;
            for (int i = 0; i < 3; i++) pos[i] = (ZSAEPSRand(rng) < 0.5f ? -0.5f : 0.5f) * P->box[i];
            pos[axis] = (ZSAEPSRand(rng) - 0.5f) * P->box[axis];
            break;
        }
        case 10: case 11: {
            float t = P->shapeType == 11 ? 0 : thickness;
            float inner = 1 - t;
            float r = radius * sqrtf(ZSAEPSLerp(inner * inner, 1, ZSAEPSRand(rng)));
            float phi = arc * ZSAEPSRand(rng);
            pos[0] = r * cosf(phi); pos[1] = r * sinf(phi); pos[2] = 0;
            dir[0] = cosf(phi); dir[1] = sinf(phi); dir[2] = 0;
            break;
        }
        case 12: {
            pos[0] = ZSAEPSLerp(-radius, radius, ZSAEPSRand(rng));
            dir[0] = 0; dir[1] = 1; dir[2] = 0;
            break;
        }
        case 17: {
            float phi = arc * ZSAEPSRand(rng);
            float psi = ZSAEPSRand(rng) * 6.2831853f;
            float d = P->donutRadius * (thickness > 0 ? sqrtf(ZSAEPSRand(rng)) : 1);
            float ring = radius + d * cosf(psi);
            pos[0] = ring * cosf(phi); pos[1] = ring * sinf(phi); pos[2] = d * sinf(psi);
            dir[0] = cosf(phi); dir[1] = sinf(phi); dir[2] = 0;
            break;
        }
        case 18: {
            pos[0] = (ZSAEPSRand(rng) - 0.5f) * P->box[0];
            pos[1] = (ZSAEPSRand(rng) - 0.5f) * P->box[1];
            break;
        }
        default: {
            float r = 0.5f * cbrtf(ZSAEPSRand(rng));
            ZSAEPSRandomUnit(rng, dir);
            pos[0] = dir[0] * r; pos[1] = dir[1] * r; pos[2] = dir[2] * r;
            break;
        }
    }

    for (int i = 0; i < 3; i++) pos[i] *= P->shapeScale[i];
    float rp[3], rd[3];
    ZSAEPSRotate(P->shapeRot, pos, rp);
    ZSAEPSRotate(P->shapeRot, dir, rd);
    for (int i = 0; i < 3; i++) {
        pos[i] = rp[i] + P->shapePos[i];
        dir[i] = rd[i];
    }

    if (P->randomDirection > 0) {
        float rnd[3];
        ZSAEPSRandomUnit(rng, rnd);
        for (int i = 0; i < 3; i++) dir[i] = ZSAEPSLerp(dir[i], rnd[i], P->randomDirection);
    }
    if (P->sphericalDirection > 0) {
        float sph[3] = { pos[0], pos[1], pos[2] };
        ZSAEPSNormalize(sph);
        for (int i = 0; i < 3; i++) dir[i] = ZSAEPSLerp(dir[i], sph[i], P->sphericalDirection);
    }
    ZSAEPSNormalize(dir);
    if (P->randomPosition > 0) {
        float rnd[3];
        ZSAEPSRandomUnit(rng, rnd);
        float m = P->randomPosition * ZSAEPSRand(rng);
        for (int i = 0; i < 3; i++) pos[i] += rnd[i] * m;
    }
}

static void ZSAEPSAdvance(ZSAEPSSim *S, ZSAEPSParticle *p, float dt, float sysT) {
    const ZSAEPSParams *P = &S->P;
    float nt = p->life > 1e-4f ? ZSAEPSClamp(p->age / p->life, 0, 1) : 1;

    float gravity = ZSAEPSMinMaxEval(&P->gravity, sysT, p->rForce);
    float ax = 0, ay = -9.81f * gravity, az = 0;

    if (P->forceEnabled) {
        float f[3] = {
            ZSAEPSMinMaxEval(&P->forceX, nt, p->rForce),
            ZSAEPSMinMaxEval(&P->forceY, nt, p->rForce),
            ZSAEPSMinMaxEval(&P->forceZ, nt, p->rForce)
        };
        if (!P->forceWorld) {
            float r[3];
            ZSAEPSRotate(P->emitterRot, f, r);
            f[0] = r[0]; f[1] = r[1]; f[2] = r[2];
        }
        ax += f[0]; ay += f[1]; az += f[2];
    }

    p->vel[0] += ax * dt;
    p->vel[1] += ay * dt;
    p->vel[2] += az * dt;

    float mx = p->vel[0], my = p->vel[1], mz = p->vel[2];
    float speedMod = 1;
    if (P->velEnabled) {
        float e[3] = {
            ZSAEPSMinMaxEval(&P->velX, nt, p->rVel),
            ZSAEPSMinMaxEval(&P->velY, nt, p->rVel),
            ZSAEPSMinMaxEval(&P->velZ, nt, p->rVel)
        };
        if (!P->velWorld) {
            float r[3];
            ZSAEPSRotate(P->emitterRot, e, r);
            e[0] = r[0]; e[1] = r[1]; e[2] = r[2];
        }
        mx += e[0]; my += e[1]; mz += e[2];
        speedMod = ZSAEPSMinMaxEval(&P->speedModifier, nt, p->rSpeed);
    }

    p->pos[0] += mx * speedMod * dt;
    p->pos[1] += my * speedMod * dt;
    p->pos[2] += mz * speedMod * dt;

    if (P->rotEnabled) p->rot += ZSAEPSMinMaxEval(&P->rotSpeed, nt, p->rRot) * dt;
    p->age += dt;
}

static void ZSAEPSSpawn(ZSAEPSSim *S, float sysT, float advance) {
    const ZSAEPSParams *P = &S->P;
    if (S->count >= P->maxParticles || S->count >= ZSAE_PS_MAXPARTICLES) return;
    ZSAEPSParticle *p = &S->parts[S->count];
    memset(p, 0, sizeof(*p));
    uint64_t *rng = &S->rng;

    p->rVel = ZSAEPSRand(rng);
    p->rForce = ZSAEPSRand(rng);
    p->rSize = ZSAEPSRand(rng);
    p->rRot = ZSAEPSRand(rng);
    p->rColor = ZSAEPSRand(rng);
    p->rFrame = ZSAEPSRand(rng);
    p->rSpeed = ZSAEPSRand(rng);
    p->rRow = ZSAEPSRand(rng);
    p->sysT = sysT;

    p->life = fmaxf(0.02f, ZSAEPSMinMaxEval(&P->startLifetime, sysT, ZSAEPSRand(rng)));
    float speed = ZSAEPSMinMaxEval(&P->startSpeed, sysT, ZSAEPSRand(rng));
    p->sizeX = ZSAEPSMinMaxEval(&P->startSizeX, sysT, ZSAEPSRand(rng));
    p->sizeY = P->size3D ? ZSAEPSMinMaxEval(&P->startSizeY, sysT, ZSAEPSRand(rng)) : p->sizeX;
    p->rot = ZSAEPSMinMaxEval(&P->startRotation, sysT, ZSAEPSRand(rng));
    if (P->randomizeRotationDirection > ZSAEPSRand(rng)) p->rot = -p->rot;
    ZSAEPSColorEval(&P->startColor, sysT, ZSAEPSRand(rng), p->color);

    float pos[3], dir[3];
    ZSAEPSShapeSample(S, pos, dir);
    float wp[3], wd[3];
    ZSAEPSRotate(P->emitterRot, pos, wp);
    ZSAEPSRotate(P->emitterRot, dir, wd);
    for (int i = 0; i < 3; i++) {
        p->pos[i] = wp[i];
        p->vel[i] = wd[i] * speed;
    }
    S->count++;
    if (advance > 0) ZSAEPSAdvance(S, p, advance, sysT);
}

static void ZSAEPSReset(ZSAEPSSim *S, uint64_t seed) {
    S->count = 0;
    S->time = 0;
    S->emitAccum = 0;
    S->rng = seed ? seed : 0x9E3779B97F4A7C15ULL;
    for (int i = 0; i < 4; i++) ZSAEPSRand(&S->rng);
}

static void ZSAEPSStep(ZSAEPSSim *S, float realDt) {
    const ZSAEPSParams *P = &S->P;
    float dt = realDt * (P->simSpeed > 0 ? P->simSpeed : 1);
    if (dt <= 0) return;
    float duration = fmaxf(P->duration, 0.05f);

    float gravityT = (float)fmod(fmax(S->time - P->startDelay, 0), duration) / duration;
    int alive = 0;
    for (int i = 0; i < S->count; i++) {
        ZSAEPSParticle *p = &S->parts[i];
        if (p->age + dt >= p->life) continue;
        ZSAEPSAdvance(S, p, dt, gravityT);
        if (alive != i) S->parts[alive] = *p;
        alive++;
    }
    S->count = alive;

    double te0 = S->time - P->startDelay;
    double te1 = te0 + dt;
    S->time += dt;

    if (!P->emissionEnabled || te1 <= 0) return;

    double from = te0 < 0 ? 0 : te0;
    double firstCycle = floor(from / duration);
    double lastCycle = floor(te1 / duration);
    if (!P->looping) {
        if (from >= duration) return;
        if (te1 > duration) te1 = duration;
        firstCycle = 0;
        lastCycle = 0;
    }

    double span = te1 - from;
    float midLocal = (float)fmod((from + te1) * 0.5, duration);
    float sysT = ZSAEPSClamp(midLocal / duration, 0, 1);
    float rate = fmaxf(0, ZSAEPSMinMaxEval(&P->rate, sysT, 0.5f));
    S->emitAccum += rate * span;
    int n = (int)S->emitAccum;
    S->emitAccum -= n;
    if (n > 256) n = 256;
    for (int i = 0; i < n; i++) {
        float off = realDt * ZSAEPSRand(&S->rng);
        ZSAEPSSpawn(S, sysT, off);
    }

    for (int b = 0; b < P->burstCount; b++) {
        const ZSAEPSBurst *burst = &P->bursts[b];
        int cycles = burst->cycles <= 0 ? 64 : burst->cycles;
        for (double c = firstCycle; c <= lastCycle; c += 1) {
            for (int k = 0; k < cycles; k++) {
                double local = burst->time + k * fmax(burst->interval, 0.01f);
                if (local >= duration) break;
                double T = c * duration + local;
                if (T < from || T >= te1) continue;
                if (burst->probability < 1 && ZSAEPSRand(&S->rng) > burst->probability) continue;
                float cnt = ZSAEPSMinMaxEval(&burst->count, ZSAEPSClamp((float)local / duration, 0, 1), ZSAEPSRand(&S->rng));
                int count = (int)(cnt + 0.5f);
                if (count > 512) count = 512;
                for (int i = 0; i < count; i++) ZSAEPSSpawn(S, ZSAEPSClamp((float)local / duration, 0, 1), 0);
            }
        }
    }
}

static int ZSAEPSFillQuad(ZSAEPSQuad *q, float cx, float cy, float ax, float ay, float bx, float by) {
    float det = ax * by - ay * bx;
    if (fabsf(det) < 1e-6f) return 0;
    float inv = 1.0f / det;
    q->cx = cx;
    q->cy = cy;
    q->sdx = by * inv;
    q->sdy = -bx * inv;
    q->tdx = -ay * inv;
    q->tdy = ax * inv;
    float ex = fabsf(ax) + fabsf(bx);
    float ey = fabsf(ay) + fabsf(by);
    q->minX = cx - ex;
    q->maxX = cx + ex;
    q->minY = cy - ey;
    q->maxY = cy + ey;
    return 1;
}

static int ZSAEPSBuildQuads(const ZSAEPSSim *S, ZSAEPSQuad *quads, int capacity, int width, int height, float centerX, float centerY, float scale) {
    const ZSAEPSParams *P = &S->P;
    int n = 0;
    float halfW = width * 0.5f;
    float halfH = height * 0.5f;
    int tx = P->tilesX > 0 ? P->tilesX : 1;
    int ty = P->tilesY > 0 ? P->tilesY : 1;
    int total = P->uvEnabled ? (P->uvAnimType == 1 ? tx : tx * ty) : 1;

    for (int i = 0; i < S->count && n < capacity; i++) {
        const ZSAEPSParticle *p = &S->parts[i];
        float nt = p->life > 1e-4f ? ZSAEPSClamp(p->age / p->life, 0, 1) : 1;

        float sx = p->sizeX;
        float sy = p->sizeY;
        if (P->sizeEnabled) {
            float mx = ZSAEPSMinMaxEval(&P->sizeX, nt, p->rSize);
            float my = P->sizeSeparate ? ZSAEPSMinMaxEval(&P->sizeY, nt, p->rSize) : mx;
            sx *= mx;
            sy *= my;
        }
        if (sx <= 1e-5f || sy <= 1e-5f) continue;

        float color[4] = { p->color[0], p->color[1], p->color[2], p->color[3] };
        if (P->colorEnabled) {
            float c[4];
            ZSAEPSColorEval(&P->colorOverLife, nt, p->rColor, c);
            for (int k = 0; k < 4; k++) color[k] *= c[k];
        }
        for (int k = 0; k < 4; k++) color[k] *= P->tint[k];
        if (color[3] <= 0.002f) continue;

        float cx = halfW + (p->pos[0] - centerX) * scale;
        float cy = halfH - (p->pos[1] - centerY) * scale;
        ZSAEPSQuad *q = &quads[n];
        int ok = 0;

        if (P->renderMode == 1) {
            float vx = p->vel[0];
            float vy = p->vel[1];
            float speed = sqrtf(vx * vx + vy * vy);
            if (speed > 1e-4f) {
                float dx = vx / speed;
                float dy = vy / speed;
                float len = sy * P->lengthScale + speed * P->velocityScale;
                float hh = sx * 0.5f * scale;
                float hw = fmaxf(len * 0.5f * scale, hh);
                ok = ZSAEPSFillQuad(q, cx, cy, hw * dx, -hw * dy, hh * dy, hh * dx);
            }
        }
        if (!ok) {
            float ca = cosf(p->rot);
            float sa = sinf(p->rot);
            float hw = sx * 0.5f * scale;
            float hh = sy * 0.5f * scale;
            ok = ZSAEPSFillQuad(q, cx, cy, hw * ca, -hw * sa, -hh * sa, -hh * ca);
        }
        if (!ok) continue;
        if (q->maxX < 0 || q->minX > width || q->maxY < 0 || q->minY > height) continue;

        q->r = color[0];
        q->g = color[1];
        q->b = color[2];
        q->a = ZSAEPSClamp(color[3], 0, 1);
        q->u0 = 0;
        q->v0 = 0;
        q->du = 1;
        q->dv = 1;
        if (P->uvEnabled && total > 1) {
            float curve = ZSAEPSMinMaxEval(&P->uvFrame, nt, p->rFrame);
            float start = ZSAEPSMinMaxEval(&P->uvStart, 0, p->rFrame);
            float framePos = curve * (P->uvCycles > 0 ? P->uvCycles : 1) + start;
            framePos -= floorf(framePos);
            int frame = (int)(framePos * total);
            if (frame >= total) frame = total - 1;
            int col, row;
            if (P->uvAnimType == 1) {
                col = frame;
                row = P->uvRandomRow ? (int)(p->rRow * ty) % ty : P->uvRow;
                if (row < 0) row = 0;
                if (row >= ty) row = ty - 1;
            } else {
                col = frame % tx;
                row = frame / tx;
            }
            q->du = 1.0f / tx;
            q->dv = 1.0f / ty;
            q->u0 = col * q->du;
            q->v0 = row * q->dv;
        }
        n++;
    }
    return n;
}

static void ZSAEPSRasterBand(uint8_t *pixels, int width, int y0, int y1, const ZSAEPSQuad *quads, int count,
                             const uint8_t *tex, int tw, int th, int additive) {
    for (int qi = 0; qi < count; qi++) {
        const ZSAEPSQuad *q = &quads[qi];
        if (q->maxY < y0 || q->minY >= y1) continue;
        int ys = (int)floorf(fmaxf(q->minY, (float)y0));
        int ye = (int)ceilf(fminf(q->maxY, (float)y1));
        int xs = (int)floorf(fmaxf(q->minX, 0));
        int xe = (int)ceilf(fminf(q->maxX, (float)width));
        for (int y = ys; y < ye; y++) {
            float dy = (y + 0.5f) - q->cy;
            uint8_t *row = pixels + (size_t)y * (size_t)width * 4;
            for (int x = xs; x < xe; x++) {
                float dx = (x + 0.5f) - q->cx;
                float s = dx * q->sdx + dy * q->sdy;
                float t = dx * q->tdx + dy * q->tdy;
                if (s < -1 || s > 1 || t < -1 || t > 1) continue;
                float sr, sg, sb, sa;
                if (tex) {
                    float u = q->u0 + (s + 1) * 0.5f * q->du;
                    float v = q->v0 + (1 - t) * 0.5f * q->dv;
                    float fx = u * tw - 0.5f;
                    float fy = v * th - 0.5f;
                    int ix = (int)floorf(fx);
                    int iy = (int)floorf(fy);
                    float wx = fx - ix;
                    float wy = fy - iy;
                    int x0 = ix < 0 ? 0 : (ix >= tw ? tw - 1 : ix);
                    int x1 = ix + 1 < 0 ? 0 : (ix + 1 >= tw ? tw - 1 : ix + 1);
                    int y0i = iy < 0 ? 0 : (iy >= th ? th - 1 : iy);
                    int y1i = iy + 1 < 0 ? 0 : (iy + 1 >= th ? th - 1 : iy + 1);
                    const uint8_t *p00 = tex + ((size_t)y0i * tw + x0) * 4;
                    const uint8_t *p10 = tex + ((size_t)y0i * tw + x1) * 4;
                    const uint8_t *p01 = tex + ((size_t)y1i * tw + x0) * 4;
                    const uint8_t *p11 = tex + ((size_t)y1i * tw + x1) * 4;
                    float w00 = (1 - wx) * (1 - wy), w10 = wx * (1 - wy), w01 = (1 - wx) * wy, w11 = wx * wy;
                    float a = (p00[3] * w00 + p10[3] * w10 + p01[3] * w01 + p11[3] * w11) * (1.0f / 255.0f);
                    float rr = (p00[0] * p00[3] * w00 + p10[0] * p10[3] * w10 + p01[0] * p01[3] * w01 + p11[0] * p11[3] * w11) * (1.0f / (255.0f * 255.0f));
                    float gg = (p00[1] * p00[3] * w00 + p10[1] * p10[3] * w10 + p01[1] * p01[3] * w01 + p11[1] * p11[3] * w11) * (1.0f / (255.0f * 255.0f));
                    float bb = (p00[2] * p00[3] * w00 + p10[2] * p10[3] * w10 + p01[2] * p01[3] * w01 + p11[2] * p11[3] * w11) * (1.0f / (255.0f * 255.0f));
                    if (a > 1e-4f) {
                        sr = rr / a; sg = gg / a; sb = bb / a;
                    } else {
                        sr = sg = sb = 0;
                    }
                    sa = a;
                } else {
                    float r2 = s * s + t * t;
                    if (r2 >= 1) continue;
                    float f = 1 - r2;
                    sr = sg = sb = 1;
                    sa = f * f;
                }
                sr *= q->r; sg *= q->g; sb *= q->b; sa *= q->a;
                uint8_t *d = row + (size_t)x * 4;
                if (additive) {
                    float k = sa * 255.0f;
                    float rr = d[0] + sr * k;
                    float gg = d[1] + sg * k;
                    float bb = d[2] + sb * k;
                    d[0] = rr > 255 ? 255 : (uint8_t)rr;
                    d[1] = gg > 255 ? 255 : (uint8_t)gg;
                    d[2] = bb > 255 ? 255 : (uint8_t)bb;
                } else {
                    float inv = 1 - sa;
                    float rr = sr * 255.0f * sa + d[0] * inv;
                    float gg = sg * 255.0f * sa + d[1] * inv;
                    float bb = sb * 255.0f * sa + d[2] * inv;
                    d[0] = rr > 255 ? 255 : (uint8_t)rr;
                    d[1] = gg > 255 ? 255 : (uint8_t)gg;
                    d[2] = bb > 255 ? 255 : (uint8_t)bb;
                }
                d[3] = 255;
            }
        }
    }
}

static float ZSAEPSFloat(id value, float fallback) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value floatValue] : fallback;
}

static int ZSAEPSBool(id value, int fallback) {
    return [value isKindOfClass:[NSNumber class]] ? ([(NSNumber *)value longLongValue] != 0) : fallback;
}

static float ZSAEPSScalarOrValue(id value, float fallback) {
    NSDictionary *dictionary = ZSAEDict(value);
    if (dictionary) return ZSAEPSFloat(dictionary[@"value"], fallback);
    return ZSAEPSFloat(value, fallback);
}

static void ZSAEPSLoadVec3(id value, float out[3], float fallback) {
    NSDictionary *dictionary = ZSAEDict(value);
    out[0] = ZSAEPSFloat(dictionary[@"x"], fallback);
    out[1] = ZSAEPSFloat(dictionary[@"y"], fallback);
    out[2] = ZSAEPSFloat(dictionary[@"z"], fallback);
}

static void ZSAEPSLoadCurve(id value, ZSAEPSCurve *out) {
    out->count = 0;
    NSArray *keys = ZSAEArray(ZSAEDict(value)[@"m_Curve"]);
    NSUInteger count = keys.count;
    if (count == 0) return;
    ZSAEPSKey *full = calloc(count, sizeof(ZSAEPSKey));
    if (!full) return;
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *key = ZSAEDict(keys[i]);
        full[i].t = (float)ZSAEDouble(key[@"time"]);
        full[i].v = (float)ZSAEDouble(key[@"value"]);
        full[i].inS = (float)ZSAEDouble(key[@"inSlope"]);
        full[i].outS = (float)ZSAEDouble(key[@"outSlope"]);
    }
    if (count <= ZSAE_PS_MAXKEYS) {
        memcpy(out->keys, full, count * sizeof(ZSAEPSKey));
        out->count = (int)count;
    } else {
        float t0 = full[0].t;
        float t1 = full[count - 1].t;
        for (int i = 0; i < ZSAE_PS_MAXKEYS; i++) {
            float t = t0 + (t1 - t0) * (float)i / (float)(ZSAE_PS_MAXKEYS - 1);
            out->keys[i].t = t;
            out->keys[i].v = ZSAEPSKeysEval(full, (int)count, t);
        }
        for (int i = 0; i < ZSAE_PS_MAXKEYS; i++) {
            int a = i > 0 ? i - 1 : i;
            int b = i < ZSAE_PS_MAXKEYS - 1 ? i + 1 : i;
            float span = out->keys[b].t - out->keys[a].t;
            float slope = span > 1e-6f ? (out->keys[b].v - out->keys[a].v) / span : 0;
            out->keys[i].inS = slope;
            out->keys[i].outS = slope;
        }
        out->count = ZSAE_PS_MAXKEYS;
    }
    free(full);
}

static void ZSAEPSLoadMinMax(id value, ZSAEPSMinMax *out, float fallback) {
    memset(out, 0, sizeof(*out));
    out->scalar = fallback;
    NSDictionary *dictionary = ZSAEDict(value);
    if (!dictionary) return;
    out->state = (int)ZSAEInt(dictionary[@"minMaxState"]);
    if (dictionary[@"scalar"]) out->scalar = (float)ZSAEDouble(dictionary[@"scalar"]);
    ZSAEPSLoadCurve(dictionary[@"maxCurve"], &out->maxC);
    ZSAEPSLoadCurve(dictionary[@"minCurve"], &out->minC);
}

static void ZSAEPSColorValue(id value, float out[4]) {
    out[0] = out[1] = out[2] = out[3] = 1;
    NSDictionary *dictionary = ZSAEDict(value);
    if (dictionary) {
        if (dictionary[@"r"]) {
            out[0] = ZSAEPSFloat(dictionary[@"r"], 1);
            out[1] = ZSAEPSFloat(dictionary[@"g"], 1);
            out[2] = ZSAEPSFloat(dictionary[@"b"], 1);
            out[3] = ZSAEPSFloat(dictionary[@"a"], 1);
            return;
        }
        value = dictionary[@"rgba"];
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        uint32_t packed = (uint32_t)[(NSNumber *)value unsignedLongLongValue];
        out[0] = (float)(packed & 0xFF) / 255.0f;
        out[1] = (float)((packed >> 8) & 0xFF) / 255.0f;
        out[2] = (float)((packed >> 16) & 0xFF) / 255.0f;
        out[3] = (float)((packed >> 24) & 0xFF) / 255.0f;
    }
}

static void ZSAEPSLoadGradient(id value, ZSAEPSGradient *gradient) {
    memset(gradient, 0, sizeof(*gradient));
    NSDictionary *dictionary = ZSAEDict(value);
    if (!dictionary) {
        gradient->colorCount = 1;
        gradient->alphaCount = 1;
        gradient->cr[0] = gradient->cg[0] = gradient->cb[0] = 1;
        gradient->av[0] = 1;
        return;
    }
    gradient->mode = (int)ZSAEInt(dictionary[@"m_Mode"]);
    int colorCount = dictionary[@"m_NumColorKeys"] ? (int)ZSAEInt(dictionary[@"m_NumColorKeys"]) : 2;
    int alphaCount = dictionary[@"m_NumAlphaKeys"] ? (int)ZSAEInt(dictionary[@"m_NumAlphaKeys"]) : 2;
    colorCount = MAX(1, MIN(colorCount, 8));
    alphaCount = MAX(1, MIN(alphaCount, 8));
    gradient->colorCount = colorCount;
    gradient->alphaCount = alphaCount;
    for (int i = 0; i < colorCount; i++) {
        float c[4];
        ZSAEPSColorValue(dictionary[[NSString stringWithFormat:@"key%d", i]], c);
        gradient->cr[i] = c[0];
        gradient->cg[i] = c[1];
        gradient->cb[i] = c[2];
        gradient->ct[i] = ZSAEPSClamp((float)ZSAEDouble(dictionary[[NSString stringWithFormat:@"ctime%d", i]]) / 65535.0f, 0, 1);
    }
    for (int i = 0; i < alphaCount; i++) {
        float c[4];
        ZSAEPSColorValue(dictionary[[NSString stringWithFormat:@"key%d", i]], c);
        gradient->av[i] = c[3];
        gradient->at[i] = ZSAEPSClamp((float)ZSAEDouble(dictionary[[NSString stringWithFormat:@"atime%d", i]]) / 65535.0f, 0, 1);
    }
}

static void ZSAEPSLoadColor(id value, ZSAEPSColor *out) {
    memset(out, 0, sizeof(*out));
    for (int i = 0; i < 4; i++) out->minColor[i] = out->maxColor[i] = 1;
    NSDictionary *dictionary = ZSAEDict(value);
    ZSAEPSLoadGradient(dictionary[@"maxGradient"], &out->maxG);
    ZSAEPSLoadGradient(dictionary[@"minGradient"], &out->minG);
    if (!dictionary) return;
    out->state = (int)ZSAEInt(dictionary[@"minMaxState"]);
    ZSAEPSColorValue(dictionary[@"minColor"], out->minColor);
    ZSAEPSColorValue(dictionary[@"maxColor"], out->maxColor);
}

static void ZSAEPSExtract(NSDictionary *ps, NSDictionary *renderer, ZSAEPSParams *P) {
    memset(P, 0, sizeof(*P));
    P->duration = MAX(0.05f, ZSAEPSFloat(ps[@"lengthInSec"], 5));
    P->looping = ZSAEPSBool(ps[@"looping"], 1);
    P->simSpeed = MAX(0.01f, ZSAEPSFloat(ps[@"simulationSpeed"], 1));
    P->seed = (uint32_t)ZSAEInt(ps[@"randomSeed"]);

    ZSAEPSMinMax delay;
    ZSAEPSLoadMinMax(ps[@"startDelay"], &delay, 0);
    P->startDelay = MAX(0, ZSAEPSMinMaxEval(&delay, 0, 1));

    NSDictionary *initial = ZSAEDict(ps[@"InitialModule"]);
    ZSAEPSLoadMinMax(initial[@"startLifetime"], &P->startLifetime, 5);
    ZSAEPSLoadMinMax(initial[@"startSpeed"], &P->startSpeed, 5);
    ZSAEPSLoadMinMax(initial[@"startSize"], &P->startSizeX, 1);
    ZSAEPSLoadMinMax(initial[@"startSizeY"], &P->startSizeY, 1);
    ZSAEPSLoadMinMax(initial[@"startRotation"], &P->startRotation, 0);
    ZSAEPSLoadMinMax(initial[@"gravityModifier"], &P->gravity, 0);
    ZSAEPSLoadColor(initial[@"startColor"], &P->startColor);
    P->randomizeRotationDirection = ZSAEPSFloat(initial[@"randomizeRotationDirection"], 0);
    P->size3D = ZSAEPSBool(initial[@"size3D"], 0);
    P->maxParticles = MAX(1, MIN((int)ZSAEInt(initial[@"maxNumParticles"] ?: @1000), ZSAE_PS_MAXPARTICLES));

    NSDictionary *emission = ZSAEDict(ps[@"EmissionModule"]);
    P->emissionEnabled = ZSAEPSBool(emission[@"enabled"], emission != nil);
    ZSAEPSLoadMinMax(emission[@"rateOverTime"], &P->rate, 10);
    NSArray *bursts = ZSAEArray(emission[@"m_Bursts"]);
    if (bursts.count > 0) {
        for (NSUInteger i = 0; i < bursts.count && P->burstCount < ZSAE_PS_MAXBURSTS; i++) {
            NSDictionary *entry = ZSAEDict(bursts[i]);
            if (!entry) continue;
            ZSAEPSBurst *burst = &P->bursts[P->burstCount++];
            burst->time = ZSAEPSFloat(entry[@"time"], 0);
            ZSAEPSLoadMinMax(entry[@"countCurve"], &burst->count, 30);
            burst->cycles = (int)ZSAEInt(entry[@"cycleCount"] ?: @1);
            burst->interval = MAX(0.01f, ZSAEPSFloat(entry[@"repeatInterval"], 0.01f));
            burst->probability = ZSAEPSFloat(entry[@"probability"], 1);
        }
    } else {
        int legacy = MIN((int)ZSAEInt(emission[@"m_BurstCount"]), 4);
        for (int i = 0; i < legacy; i++) {
            ZSAEPSBurst *burst = &P->bursts[P->burstCount++];
            burst->time = ZSAEPSFloat(emission[[NSString stringWithFormat:@"time%d", i]], 0);
            burst->count.state = 0;
            burst->count.scalar = ZSAEPSFloat(emission[[NSString stringWithFormat:@"cnt%d", i]], 30);
            burst->cycles = 1;
            burst->interval = 0.01f;
            burst->probability = 1;
        }
    }

    NSDictionary *shape = ZSAEDict(ps[@"ShapeModule"]);
    P->shapeEnabled = ZSAEPSBool(shape[@"enabled"], 0);
    P->shapeType = (int)ZSAEInt(shape[@"type"]);
    P->angle = ZSAEPSFloat(shape[@"angle"], 25);
    P->radius = ZSAEPSScalarOrValue(shape[@"radius"], 1);
    P->radiusThickness = ZSAEPSFloat(shape[@"radiusThickness"], 1);
    P->arc = ZSAEPSScalarOrValue(shape[@"arc"], 360);
    P->length = ZSAEPSFloat(shape[@"length"], 5);
    P->donutRadius = ZSAEPSFloat(shape[@"donutRadius"], 0.2f);
    P->box[0] = ZSAEPSFloat(shape[@"boxX"], 1);
    P->box[1] = ZSAEPSFloat(shape[@"boxY"], 1);
    P->box[2] = ZSAEPSFloat(shape[@"boxZ"], 1);
    ZSAEPSLoadVec3(shape[@"m_Position"], P->shapePos, 0);
    float euler[3];
    ZSAEPSLoadVec3(shape[@"m_Rotation"], euler, 0);
    ZSAEPSQuatFromEuler(euler[0], euler[1], euler[2], P->shapeRot);
    ZSAEPSLoadVec3(shape[@"m_Scale"], P->shapeScale, 1);
    P->randomDirection = ZSAEPSFloat(shape[@"randomDirectionAmount"], 0);
    P->sphericalDirection = ZSAEPSFloat(shape[@"sphericalDirectionAmount"], 0);
    P->randomPosition = ZSAEPSFloat(shape[@"randomPositionAmount"], 0);

    NSDictionary *velocity = ZSAEDict(ps[@"VelocityModule"]);
    P->velEnabled = ZSAEPSBool(velocity[@"enabled"], 0);
    ZSAEPSLoadMinMax(velocity[@"x"], &P->velX, 0);
    ZSAEPSLoadMinMax(velocity[@"y"], &P->velY, 0);
    ZSAEPSLoadMinMax(velocity[@"z"], &P->velZ, 0);
    ZSAEPSLoadMinMax(velocity[@"speedModifier"], &P->speedModifier, 1);
    P->velWorld = ZSAEPSBool(velocity[@"inWorldSpace"], 0);

    NSDictionary *force = ZSAEDict(ps[@"ForceModule"]);
    P->forceEnabled = ZSAEPSBool(force[@"enabled"], 0);
    ZSAEPSLoadMinMax(force[@"x"], &P->forceX, 0);
    ZSAEPSLoadMinMax(force[@"y"], &P->forceY, 0);
    ZSAEPSLoadMinMax(force[@"z"], &P->forceZ, 0);
    P->forceWorld = ZSAEPSBool(force[@"inWorldSpace"], 0);

    NSDictionary *size = ZSAEDict(ps[@"SizeModule"]);
    P->sizeEnabled = ZSAEPSBool(size[@"enabled"], 0);
    P->sizeSeparate = ZSAEPSBool(size[@"separateAxes"], 0);
    ZSAEPSLoadMinMax(size[@"curve"], &P->sizeX, 1);
    ZSAEPSLoadMinMax(size[@"y"], &P->sizeY, 1);

    NSDictionary *rotation = ZSAEDict(ps[@"RotationModule"]);
    P->rotEnabled = ZSAEPSBool(rotation[@"enabled"], 0);
    ZSAEPSLoadMinMax(rotation[@"curve"], &P->rotSpeed, 0);

    NSDictionary *color = ZSAEDict(ps[@"ColorModule"]);
    P->colorEnabled = ZSAEPSBool(color[@"enabled"], 0);
    ZSAEPSLoadColor(color[@"gradient"], &P->colorOverLife);

    NSDictionary *uv = ZSAEDict(ps[@"UVModule"]);
    P->uvEnabled = ZSAEPSBool(uv[@"enabled"], 0) && ZSAEInt(uv[@"mode"]) == 0;
    P->tilesX = MAX(1, (int)ZSAEInt(uv[@"tilesX"] ?: @1));
    P->tilesY = MAX(1, (int)ZSAEInt(uv[@"tilesY"] ?: @1));
    P->uvAnimType = (int)ZSAEInt(uv[@"animationType"]);
    P->uvRow = (int)ZSAEInt(uv[@"rowIndex"]);
    P->uvRandomRow = ZSAEPSBool(uv[@"randomRow"], 0) || ZSAEInt(uv[@"rowMode"]) == 1;
    P->uvCycles = ZSAEPSFloat(uv[@"cycles"], 1);
    ZSAEPSLoadMinMax(uv[@"frameOverTime"], &P->uvFrame, 1);
    ZSAEPSLoadMinMax(uv[@"startFrame"], &P->uvStart, 0);

    P->renderMode = (int)ZSAEInt(renderer[@"m_RenderMode"]);
    P->lengthScale = ZSAEPSFloat(renderer[@"m_LengthScale"], 2);
    P->velocityScale = ZSAEPSFloat(renderer[@"m_VelocityScale"], 0);

    for (int i = 0; i < 4; i++) P->tint[i] = 1;
    P->emitterRot[3] = 1;
}

static NSData *ZSAEPSPrepareTexture(NSData *bottomUp, int32_t width, int32_t height, int32_t maxSide, int32_t *outWidth, int32_t *outHeight) {
    if (width <= 0 || height <= 0 || bottomUp.length < (NSUInteger)width * (NSUInteger)height * 4) return nil;
    int32_t factor = 1;
    while (width / factor > maxSide || height / factor > maxSide) factor++;
    int32_t tw = MAX(1, width / factor);
    int32_t th = MAX(1, height / factor);
    NSMutableData *output = [NSMutableData dataWithLength:(NSUInteger)tw * (NSUInteger)th * 4];
    if (!output) return nil;
    const uint8_t *source = bottomUp.bytes;
    uint8_t *destination = output.mutableBytes;
    for (int32_t y = 0; y < th; y++) {
        for (int32_t x = 0; x < tw; x++) {
            uint32_t sumR = 0, sumG = 0, sumB = 0, sumA = 0, samples = 0;
            for (int32_t j = 0; j < factor; j++) {
                int32_t topRow = y * factor + j;
                if (topRow >= height) break;
                const uint8_t *row = source + (size_t)(height - 1 - topRow) * (size_t)width * 4;
                for (int32_t i = 0; i < factor; i++) {
                    int32_t column = x * factor + i;
                    if (column >= width) break;
                    const uint8_t *pixel = row + (size_t)column * 4;
                    uint32_t a = pixel[3];
                    sumR += pixel[0] * a;
                    sumG += pixel[1] * a;
                    sumB += pixel[2] * a;
                    sumA += a;
                    samples++;
                }
            }
            uint8_t *target = destination + ((size_t)y * (size_t)tw + (size_t)x) * 4;
            if (sumA > 0) {
                target[0] = (uint8_t)(sumR / sumA);
                target[1] = (uint8_t)(sumG / sumA);
                target[2] = (uint8_t)(sumB / sumA);
                target[3] = (uint8_t)(sumA / MAX(samples, 1u));
            } else {
                target[0] = target[1] = target[2] = target[3] = 0;
            }
        }
    }
    if (outWidth) *outWidth = tw;
    if (outHeight) *outHeight = th;
    return output;
}

static int ZSAEPSCompareFloat(const void *a, const void *b) {
    float x = *(const float *)a;
    float y = *(const float *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static BOOL ZSAEPSNameImpliesAdditive(NSString *name) {
    if (name.length == 0) return NO;
    static NSRegularExpression *lower;
    static NSRegularExpression *camel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lower = [NSRegularExpression regularExpressionWithPattern:@"(?<![a-z])add(itive)?(?![a-z])" options:NSRegularExpressionCaseInsensitive error:nil];
        camel = [NSRegularExpression regularExpressionWithPattern:@"(?<=[a-z])Add(itive)?(?![a-z])" options:0 error:nil];
    });
    NSRange range = NSMakeRange(0, name.length);
    return [lower numberOfMatchesInString:name options:0 range:range] > 0 || [camel numberOfMatchesInString:name options:0 range:range] > 0;
}

@interface ZSAEParticleSession : NSObject {
    ZSAEPSSim *_sim;
    ZSAEPSQuad *_quads;
    BOOL _started;
    double _epoch;
    double _simClock;
    double _lastElapsed;
    double _cost;
    NSUInteger _frames;
    float _quality;
}
@property (nonatomic, strong) NSData *texture;
@property (nonatomic, assign) int32_t textureWidth;
@property (nonatomic, assign) int32_t textureHeight;
@property (nonatomic, assign) float centerX;
@property (nonatomic, assign) float centerY;
@property (nonatomic, assign) float extent;
@property (nonatomic, assign) double loopDuration;
@property (nonatomic, assign) double warmup;
@property (nonatomic, assign) double stillTime;
@property (nonatomic, assign) int32_t baseSize;
- (instancetype)initWithParams:(const ZSAEPSParams *)params;
- (const ZSAEPSParams *)params;
- (void)computeFraming;
- (UIImage *)frameAtElapsed:(NSTimeInterval)elapsed;
- (UIImage *)stillFrame;
@end

@implementation ZSAEParticleSession

- (instancetype)initWithParams:(const ZSAEPSParams *)params {
    self = [super init];
    if (!self) return nil;
    _sim = calloc(1, sizeof(ZSAEPSSim));
    _quads = calloc(ZSAE_PS_MAXPARTICLES, sizeof(ZSAEPSQuad));
    if (!_sim || !_quads) return nil;
    _sim->P = *params;
    _quality = 1;
    _baseSize = 384;
    _extent = 2;
    return self;
}

- (void)dealloc {
    free(_sim);
    free(_quads);
}

- (const ZSAEPSParams *)params {
    return &_sim->P;
}

- (uint64_t)seedValue {
    uint64_t seed = _sim->P.seed ? (uint64_t)_sim->P.seed : 0x2545F4914F6CDD1DULL;
    return seed * 0x9E3779B97F4A7C15ULL + 0x1234567ULL;
}

- (void)primeSimulation:(ZSAEPSSim *)sim {
    ZSAEPSReset(sim, [self seedValue]);
    if (sim->P.looping && _warmup > 0) {
        double clock = 0;
        while (clock < _warmup) {
            ZSAEPSStep(sim, 1.0f / 30.0f);
            clock += 1.0 / 30.0;
        }
    }
}

- (void)computeFraming {
    const ZSAEPSParams *P = &_sim->P;
    double maxLife = 0;
    {
        float samples[9] = { 0, 0.125f, 0.25f, 0.375f, 0.5f, 0.625f, 0.75f, 0.875f, 1 };
        for (int i = 0; i < 9; i++) {
            maxLife = MAX(maxLife, (double)ZSAEPSMinMaxEval(&P->startLifetime, samples[i], 1));
            maxLife = MAX(maxLife, (double)ZSAEPSMinMaxEval(&P->startLifetime, samples[i], 0));
        }
    }
    maxLife = MAX(0.2, MIN(maxLife, 12.0));
    _warmup = P->looping ? MIN(maxLife, 6.0) : 0;
    _loopDuration = P->looping ? 0 : (P->startDelay + P->duration + maxLife + 0.6);

    double observe = P->looping ? MIN(MAX(P->duration, 3.0), 8.0) : _loopDuration;
    ZSAEPSSim *probe = calloc(1, sizeof(ZSAEPSSim));
    if (!probe) return;
    probe->P = *P;
    [self primeSimulation:probe];

    NSUInteger capacity = 60000;
    float *xs = malloc(capacity * sizeof(float));
    float *ys = malloc(capacity * sizeof(float));
    NSUInteger used = 0;
    double sizeSum = 0;
    NSUInteger sizeCount = 0;
    int peak = 0;
    double peakTime = 0;
    if (xs && ys) {
        double clock = 0;
        while (clock < observe) {
            ZSAEPSStep(probe, 1.0f / 30.0f);
            clock += 1.0 / 30.0;
            if (probe->count > peak) {
                peak = probe->count;
                peakTime = clock;
            }
            for (int i = 0; i < probe->count && used < capacity; i++) {
                xs[used] = probe->parts[i].pos[0];
                ys[used] = probe->parts[i].pos[1];
                used++;
                sizeSum += MAX(probe->parts[i].sizeX, probe->parts[i].sizeY);
                sizeCount++;
            }
        }
    }
    _stillTime = peakTime;

    if (used > 8) {
        qsort(xs, used, sizeof(float), ZSAEPSCompareFloat);
        qsort(ys, used, sizeof(float), ZSAEPSCompareFloat);
        NSUInteger lo = (NSUInteger)((double)used * 0.01);
        NSUInteger hi = MIN(used - 1, (NSUInteger)((double)used * 0.99));
        float minX = xs[lo], maxX = xs[hi], minY = ys[lo], maxY = ys[hi];
        float pad = sizeCount > 0 ? (float)(sizeSum / (double)sizeCount) * 0.6f : 0.2f;
        _centerX = (minX + maxX) * 0.5f;
        _centerY = (minY + maxY) * 0.5f;
        _extent = MAX(MAX(maxX - minX, maxY - minY) * 0.5f + pad, 0.3f);
    }
    free(xs);
    free(ys);
    free(probe);
}

- (void)restartSimulation {
    [self primeSimulation:_sim];
    _simClock = 0;
}

- (void)advanceTo:(double)local {
    if (local - _simClock > 0.25) _simClock = local - 0.25;
    int guard = 0;
    while (_simClock < local - 1e-6 && guard++ < 64) {
        float dt = (float)MIN(1.0 / 60.0, local - _simClock);
        ZSAEPSStep(_sim, dt);
        _simClock += dt;
    }
}

- (UIImage *)renderCurrent {
    int32_t size = (int32_t)lroundf((float)_baseSize * _quality);
    size = MAX(128, size & ~1);
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)size * (NSUInteger)size * 4];
    if (!buffer) return nil;
    uint8_t *pixels = buffer.mutableBytes;
    for (size_t i = 0; i < (size_t)size * (size_t)size; i++) {
        pixels[i * 4] = 22;
        pixels[i * 4 + 1] = 22;
        pixels[i * 4 + 2] = 28;
        pixels[i * 4 + 3] = 255;
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    float viewExtent = _extent * 1.12f;
    float scale = (float)size * 0.5f / viewExtent;
    int count = ZSAEPSBuildQuads(_sim, _quads, ZSAE_PS_MAXPARTICLES, size, size, _centerX, _centerY, scale);
    const uint8_t *texture = _texture.length > 0 ? _texture.bytes : NULL;
    int32_t texWidth = _textureWidth;
    int32_t texHeight = _textureHeight;
    int additive = _sim->P.additive;
    ZSAEPSQuad *quads = _quads;
    const int bands = 8;
    int bandHeight = (size + bands - 1) / bands;
    dispatch_apply(bands, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t band) {
        int y0 = (int)band * bandHeight;
        int y1 = MIN((int)size, y0 + bandHeight);
        if (y0 >= y1) return;
        ZSAEPSRasterBand(pixels, size, y0, y1, quads, count, texture, texWidth, texHeight, additive);
    });

    double cost = CFAbsoluteTimeGetCurrent() - started;
    _cost = _frames == 0 ? cost : _cost * 0.8 + cost * 0.2;
    _frames++;
    if (_frames % 8 == 0) {
        if (_cost > 0.024 && _quality > 0.4f) _quality *= 0.85f;
        else if (_cost < 0.008 && _quality < 1.0f) _quality = MIN(1.0f, _quality * 1.08f);
    }
    return ZSAEImageFromTopDownRGBA(buffer, size, size);
}

- (UIImage *)frameAtElapsed:(NSTimeInterval)elapsed {
    @synchronized(self) {
        if (!_started || elapsed < _lastElapsed) {
            _started = YES;
            _epoch = elapsed;
            [self restartSimulation];
        }
        _lastElapsed = elapsed;
        double local = elapsed - _epoch;
        if (_loopDuration > 0 && local >= _loopDuration) {
            _epoch += floor(local / _loopDuration) * _loopDuration;
            local = elapsed - _epoch;
            [self restartSimulation];
        }
        [self advanceTo:local];
        return [self renderCurrent];
    }
}

- (UIImage *)stillFrame {
    @synchronized(self) {
        ZSAEPSSim *scratch = calloc(1, sizeof(ZSAEPSSim));
        if (!scratch) return nil;
        scratch->P = _sim->P;
        [self primeSimulation:scratch];
        double clock = 0;
        while (clock < _stillTime) {
            ZSAEPSStep(scratch, 1.0f / 60.0f);
            clock += 1.0 / 60.0;
        }
        ZSAEPSSim *original = _sim;
        float savedQuality = _quality;
        _sim = scratch;
        _quality = 1;
        UIImage *image = [self renderCurrent];
        _quality = savedQuality;
        _sim = original;
        free(scratch);
        return image;
    }
}

@end

static NSString *ZSAEPSRenderModeName(int mode) {
    switch (mode) {
        case 1: return @"Stretched";
        case 2: return @"Horizontal";
        case 3: return @"Vertical";
        case 4: return @"Mesh";
        case 5: return @"No render";
        default: return @"Billboard";
    }
}

static void ZSAEPSScanComponents(ZSAEContext *context, ZSAEObject *gameObject, int64_t skipPathID, BOOL (^visit)(ZSAEObject *)) {
    for (id entry in ZSAEArray(gameObject.fields[@"m_Component"])) {
        NSDictionary *wrapper = ZSAEDict(entry);
        NSDictionary *pointer = ZSAEDict(wrapper[@"component"]) ?: (ZSAEDict(wrapper[@"second"]) ?: wrapper);
        if (!pointer || ZSAEInt(pointer[@"m_PathID"]) == 0) continue;
        if (ZSAEInt(pointer[@"m_FileID"]) == 0 && ZSAEInt(pointer[@"m_PathID"]) == skipPathID) continue;
        ZSAEObject *candidate = ZSAEResolvePPtr(context, gameObject, pointer, NULL);
        if (candidate && visit(candidate)) return;
    }
}

static ZSAssetExplorerVisual *ZSAEBuildParticleVisual(ZSAEContext *context, ZSAEObject *object, int64_t pathID, NSError **error) {
    ZSAEObject *psObject = object.classID == 198 ? object : nil;
    ZSAEObject *rendererObject = object.classID == 199 ? object : nil;
    ZSAEObject *transformObject = nil;

    ZSAEObject *gameObject = ZSAEResolvePPtr(context, object, object.fields[@"m_GameObject"], NULL);
    if (gameObject) {
        __block ZSAEObject *foundPS = psObject;
        __block ZSAEObject *foundRenderer = rendererObject;
        __block ZSAEObject *foundTransform = nil;
        ZSAEPSScanComponents(context, gameObject, pathID, ^BOOL(ZSAEObject *candidate) {
            if (!foundPS && candidate.classID == 198) foundPS = candidate;
            else if (!foundRenderer && candidate.classID == 199) foundRenderer = candidate;
            else if (!foundTransform && (candidate.classID == 4 || candidate.classID == 224)) foundTransform = candidate;
            return foundPS && foundRenderer && foundTransform;
        });
        psObject = foundPS;
        rendererObject = foundRenderer;
        transformObject = foundTransform;
    }
    if (!psObject) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"No ParticleSystem was found on this object's GameObject.");
        return nil;
    }

    ZSAEPSParams *params = calloc(1, sizeof(ZSAEPSParams));
    if (!params) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"Couldn't allocate memory for the particle preview.");
        return nil;
    }
    ZSAEPSExtract(psObject.fields, rendererObject.fields, params);

    float accumulated[4] = { 0, 0, 0, 1 };
    ZSAEObject *cursor = transformObject;
    for (int depth = 0; cursor && depth < 16; depth++) {
        NSDictionary *rotation = ZSAEDict(cursor.fields[@"m_LocalRotation"]);
        if (rotation) {
            float local[4] = {
                ZSAEPSFloat(rotation[@"x"], 0), ZSAEPSFloat(rotation[@"y"], 0),
                ZSAEPSFloat(rotation[@"z"], 0), ZSAEPSFloat(rotation[@"w"], 1)
            };
            float combined[4];
            ZSAEPSQuatMul(local, accumulated, combined);
            memcpy(accumulated, combined, sizeof(accumulated));
        }
        NSDictionary *father = ZSAEDict(cursor.fields[@"m_Father"]);
        if (!father || ZSAEInt(father[@"m_PathID"]) == 0) break;
        cursor = ZSAEResolvePPtr(context, cursor, father, NULL);
    }
    float length = sqrtf(accumulated[0] * accumulated[0] + accumulated[1] * accumulated[1] + accumulated[2] * accumulated[2] + accumulated[3] * accumulated[3]);
    if (length > 1e-4f) {
        for (int i = 0; i < 4; i++) params->emitterRot[i] = accumulated[i] / length;
    }

    NSString *materialName = nil;
    NSString *textureNote = @"no texture";
    ZSAEObject *textureObject = nil;
    ZSAEObject *material = nil;
    for (id pointer in ZSAEArray(rendererObject.fields[@"m_Materials"])) {
        NSDictionary *reference = ZSAEDict(pointer);
        if (!reference || ZSAEInt(reference[@"m_PathID"]) == 0) continue;
        material = ZSAEResolvePPtr(context, rendererObject, reference, NULL);
        if (material && material.classID == 21) break;
        material = nil;
    }
    if (material) {
        NSDictionary *fields = material.fields;
        materialName = ZSAEString(fields[@"m_Name"]);
        NSDictionary *saved = ZSAEDict(fields[@"m_SavedProperties"]);
        NSMutableDictionary<NSString *, NSNumber *> *floats = [NSMutableDictionary dictionary];
        for (id pair in ZSAEArray(saved[@"m_Floats"])) {
            NSString *key = ZSAEString(ZSAEDict(pair)[@"first"]);
            id number = ZSAEDict(pair)[@"second"];
            if (key && [number isKindOfClass:[NSNumber class]]) floats[key] = number;
        }
        NSMutableDictionary<NSString *, id> *colors = [NSMutableDictionary dictionary];
        for (id pair in ZSAEArray(saved[@"m_Colors"])) {
            NSString *key = ZSAEString(ZSAEDict(pair)[@"first"]);
            id value = ZSAEDict(pair)[@"second"];
            if (key && value) colors[key] = value;
        }
        NSMutableArray<NSString *> *textureKeys = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSDictionary *> *texturePointers = [NSMutableDictionary dictionary];
        for (id pair in ZSAEArray(saved[@"m_TexEnvs"])) {
            NSString *key = ZSAEString(ZSAEDict(pair)[@"first"]);
            NSDictionary *pointer = ZSAEDict(ZSAEDict(ZSAEDict(pair)[@"second"])[@"m_Texture"]);
            if (key && pointer && ZSAEInt(pointer[@"m_PathID"]) != 0) {
                [textureKeys addObject:key];
                texturePointers[key] = pointer;
            }
        }

        NSString *chosen = nil;
        for (NSString *candidate in @[@"_MainTex", @"_BaseMap", @"_BaseColorMap", @"_BaseTex", @"_Tex", @"_ParticleTexture", @"_MainTexture", @"_DiffuseTex", @"_Diffuse", @"_AlbedoMap", @"_Albedo"]) {
            if (texturePointers[candidate]) { chosen = candidate; break; }
        }
        if (!chosen) {
            for (NSString *candidate in textureKeys) {
                NSString *lowered = candidate.lowercaseString;
                BOOL ignored = NO;
                for (NSString *word in @[@"noise", @"mask", @"bump", @"normal", @"dissolve", @"distort", @"ramp", @"emission"]) {
                    if ([lowered containsString:word]) { ignored = YES; break; }
                }
                if (!ignored) { chosen = candidate; break; }
            }
        }

        BOOL additive = NO;
        NSNumber *destination = floats[@"_DstBlend"] ?: floats[@"_DstBlendFactor"];
        if (destination && fabs(destination.doubleValue - 1.0) < 0.01) additive = YES;
        if (!additive && ZSAEPSNameImpliesAdditive(materialName)) additive = YES;
        if (!additive) {
            NSDictionary *shaderPointer = ZSAEDict(fields[@"m_Shader"]);
            if (shaderPointer && ZSAEInt(shaderPointer[@"m_FileID"]) == 0 && ZSAEInt(shaderPointer[@"m_PathID"]) != 0) {
                ZSAEObject *shader = ZSAEResolvePPtr(context, material, shaderPointer, NULL);
                NSString *shaderName = ZSAEString(ZSAEDict(shader.fields[@"m_ParsedForm"])[@"m_Name"]) ?: ZSAEString(shader.fields[@"m_Name"]);
                if (ZSAEPSNameImpliesAdditive(shaderName)) additive = YES;
            }
        }
        params->additive = additive;

        for (NSString *candidate in @[@"_TintColor", @"_Color", @"_BaseColor", @"_MainColor", @"_Tint"]) {
            id value = colors[candidate];
            if (!value) continue;
            float tint[4];
            ZSAEPSColorValue(value, tint);
            float boost = [candidate isEqualToString:@"_TintColor"] ? 2.0f : 1.0f;
            for (int i = 0; i < 4; i++) params->tint[i] = tint[i] * boost;
            break;
        }

        if (chosen) {
            textureObject = ZSAEResolvePPtr(context, material, texturePointers[chosen], NULL);
        }
    }

    ZSAEParticleSession *session = [[ZSAEParticleSession alloc] initWithParams:params];
    free(params);
    if (!session) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"Couldn't allocate memory for the particle preview.");
        return nil;
    }

    BOOL hasTexturePage = NO;
    if (textureObject) {
        ZSAETextureRecord *record = nil;
        NSMutableData *rgba = nil;
        NSError *textureError = nil;
        if (ZSAEDecodeTextureObject(textureObject, &record, &rgba, &textureError)) {
            const ZSAEPSParams *built = [session params];
            int32_t maxSide = (built->uvEnabled && (built->tilesX > 1 || built->tilesY > 1)) ? 512 : 256;
            int32_t tw = 0, th = 0;
            NSData *prepared = ZSAEPSPrepareTexture(rgba, record.width, record.height, maxSide, &tw, &th);
            if (prepared) {
                session.texture = prepared;
                session.textureWidth = tw;
                session.textureHeight = th;
                hasTexturePage = YES;
                textureNote = [NSString stringWithFormat:@"%@ %dx%d", record.name.length > 0 ? record.name : @"texture", record.width, record.height];
            }
        } else if (textureError.localizedDescription.length > 0) {
            textureNote = @"texture unsupported";
        }
    }
    [session computeFraming];

    const ZSAEPSParams *built = [session params];
    NSMutableString *summary = [NSMutableString stringWithFormat:@"ParticleSystem  •  %.1fs %@  •  %@  •  max %d  •  %@",
                                built->duration, built->looping ? @"loop" : @"once", built->additive ? @"Additive" : @"Alpha",
                                built->maxParticles, ZSAEPSRenderModeName(built->renderMode)];
    if (built->uvEnabled && (built->tilesX > 1 || built->tilesY > 1)) [summary appendFormat:@"  •  %dx%d sheet", built->tilesX, built->tilesY];
    [summary appendFormat:@"  •  %@", textureNote];

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = ZSAEString(gameObject.fields[@"m_Name"]) ?: ZSAEString(psObject.fields[@"m_Name"]);
    visual.summary = summary;
    visual.pageLabels = hasTexturePage ? @[@"Simulation", @"Texture"] : @[@"Simulation"];
    visual.livePageIndex = 0;
    visual.liveFrameProvider = ^UIImage *(NSTimeInterval elapsed) {
        return [session frameAtElapsed:elapsed];
    };
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        if (page == 0) return [session stillFrame];
        if (page == 1 && textureObject) {
            ZSAETextureRecord *record = nil;
            NSMutableData *rgba = nil;
            if (!ZSAEDecodeTextureObject(textureObject, &record, &rgba, providerError)) return nil;
            return ZSAEImageFromRGBA(rgba, record.width, record.height);
        }
        return nil;
    };
    return visual;
}

@implementation ZSAssetExplorerBundle
@end

@implementation ZSAssetExplorerAsset
@end

@implementation ZSAssetExplorerTexture
@end

@implementation ZSAssetLocation
@end

static id ZSAEJSONSafeValue(id value, NSUInteger depth, NSUInteger *budget) {
    if (!value || *budget == 0) return [NSNull null];
    (*budget)--;
    if (depth > 64) return @"…";
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *number = value;
        const char *type = number.objCType;
        if (type && (type[0] == 'f' || type[0] == 'd')) {
            double d = number.doubleValue;
            if (isnan(d)) return @"NaN";
            if (isinf(d)) return d > 0 ? @"Infinity" : @"-Infinity";
        }
        return number;
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSData *data = value;
        if (data.length == 0) return @"";
        if (data.length > 64) return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)data.length];
        const uint8_t *bytes = data.bytes;
        NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
        for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
        return hex;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = value;
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dictionary.count];
        for (id key in dictionary) {
            NSString *name = [key isKindOfClass:[NSString class]] ? key : [key description];
            result[name] = ZSAEJSONSafeValue(dictionary[key], depth + 1, budget);
        }
        return result;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = value;
        NSUInteger limit = MIN(array.count, (NSUInteger)20000);
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:limit + 1];
        for (NSUInteger i = 0; i < limit; i++) [result addObject:ZSAEJSONSafeValue(array[i], depth + 1, budget)];
        if (array.count > limit) [result addObject:[NSString stringWithFormat:@"… %lu more items", (unsigned long)(array.count - limit)]];
        return result;
    }
    return [value description] ?: @"";
}

@implementation ZSAssetExplorerVisual

- (BOOL)isLivePage:(NSInteger)page {
    return self.liveFrameProvider != nil && page == self.livePageIndex;
}

- (UIImage *)imageAtPage:(NSInteger)page error:(NSError **)error {
    if (page < 0 || page >= (NSInteger)self.pageLabels.count || !self.imageProvider) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"That page doesn't exist.");
        return nil;
    }
    UIImage *image = self.imageProvider(page, error);
    if (!image && error && !*error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"Couldn't build an image for this page.");
    return image;
}

@end

static NSString *ZSAEReadAssetBundleName(NSString *path) {
    ZSAEBundle *bundle = nil;
    if (!ZSAEOpenBundle(path, &bundle, NULL)) return nil;

    ZSAEBundleNode *cabNode = ZSAEFindSerializedNode(bundle);
    if (!cabNode || cabNode.size < 64) return nil;

    NSData *head = ZSAEReadBundleRange(bundle, cabNode.offset, 48, NULL);
    if (head.length < 48) return nil;
    const uint8_t *headBytes = head.bytes;
    uint64_t dataOffset = ZSAEReadU64BEBytes(headBytes + 32);
    if (dataOffset < 48 || dataOffset > cabNode.size || dataOffset > (16ULL << 20)) return nil;

    NSData *metadata = ZSAEReadBundleRange(bundle, cabNode.offset, dataOffset, NULL);
    if (!metadata) return nil;

    NSArray<ZSAssetExplorerAsset *> *assets = nil;
    if (!ZSAEParseSerializedFile(metadata, &assets, INT64_MIN, NULL, NULL, NULL, NULL, NULL)) return nil;

    ZSAssetExplorerAsset *bundleAsset = nil;
    for (ZSAssetExplorerAsset *asset in assets) {
        if (asset.classID == 142) {
            bundleAsset = asset;
            break;
        }
    }
    if (!bundleAsset || bundleAsset.objectSize < 5) return nil;

    uint64_t objectStart = cabNode.offset + dataOffset + bundleAsset.byteStart;
    uint64_t readLength = MIN((uint64_t)bundleAsset.objectSize, (uint64_t)1028);
    if (objectStart + readLength > cabNode.offset + cabNode.size) return nil;

    NSData *objectHead = ZSAEReadBundleRange(bundle, objectStart, readLength, NULL);
    if (objectHead.length < 5) return nil;
    const uint8_t *bytes = objectHead.bytes;
    int32_t nameLength = ZSAEReadI32LEBytes(bytes);
    if (nameLength <= 0 || (uint64_t)nameLength > objectHead.length - 4) return nil;
    return [[NSString alloc] initWithBytes:bytes + 4 length:(NSUInteger)nameLength encoding:NSUTF8StringEncoding];
}

static NSString *ZSAENameCachePath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return caches ? [caches stringByAppendingPathComponent:@"ZSAssetExplorerBundleNames.plist"] : nil;
}

static NSObject *ZSAENameCacheLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, NSDictionary *> *ZSAENameCache(void) {
    static NSMutableDictionary<NSString *, NSDictionary *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = ZSAENameCachePath();
        NSDictionary *stored = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        cache = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    });
    return cache;
}

static void ZSAESaveNameCache(void) {
    NSString *path = ZSAENameCachePath();
    if (!path) return;
    NSDictionary *snapshot = nil;
    @synchronized (ZSAENameCacheLock()) {
        snapshot = [ZSAENameCache() copy];
    }
    [snapshot writeToFile:path atomically:YES];
}

static NSString *ZSAEFileSignature(NSString *path) {
    struct stat st;
    if (path.length == 0 || stat(path.fileSystemRepresentation, &st) != 0) return nil;
    return [NSString stringWithFormat:@"%lld:%ld", (long long)st.st_size, (long)st.st_mtime];
}

static BOOL ZSAEApplyCachedName(ZSAssetExplorerBundle *bundle) {
    NSString *signature = ZSAEFileSignature(bundle.filePath);
    if (!signature) return NO;
    NSDictionary *entry = nil;
    @synchronized (ZSAENameCacheLock()) {
        entry = ZSAENameCache()[bundle.cabIdentifier];
    }
    if (![entry[@"sig"] isEqualToString:signature]) return NO;
    NSString *name = entry[@"name"];
    if ([name isKindOfClass:[NSString class]] && name.length > 0) bundle.displayName = name;
    bundle.nameResolved = YES;
    return YES;
}

static NSData *ZSAEJSONDataForObject(ZSAEObject *object, NSError **error) {
    NSDictionary *fields = object.fields;
    if (fields.count == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"This object has no readable fields.");
        return nil;
    }
    NSUInteger budget = 600000;
    id safe = ZSAEJSONSafeValue(fields, 0, &budget);
    NSJSONWritingOptions options = NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys;
    if (@available(iOS 13.0, *)) options |= NSJSONWritingWithoutEscapingSlashes;
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:safe options:options error:&jsonError];
    if (!data) {
        if (error) *error = jsonError ?: ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"Couldn't serialize this asset to JSON.");
        return nil;
    }
    return data;
}

static uint32_t ZSAEZipCRC32(const uint8_t *bytes, size_t length) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
    });
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < length; i++) crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

@interface ZSAEZipRecord : NSObject
@property (nonatomic, copy) NSData *name;
@property (nonatomic, assign) uint16_t method;
@property (nonatomic, assign) uint32_t crc;
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t size;
@property (nonatomic, assign) uint32_t offset;
@end

@implementation ZSAEZipRecord
@end

@interface ZSAEZipWriter : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (BOOL)addEntryNamed:(NSString *)name data:(NSData *)data;
- (BOOL)finish;
@end

@implementation ZSAEZipWriter {
    FILE *_file;
    NSMutableArray<ZSAEZipRecord *> *_records;
    NSMutableSet<NSString *> *_names;
    uint16_t _dosTime;
    uint16_t _dosDate;
    BOOL _failed;
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _file = fopen(path.fileSystemRepresentation, "wb");
        _records = [NSMutableArray array];
        _names = [NSMutableSet set];
        NSDateComponents *c = [[NSCalendar currentCalendar] components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:[NSDate date]];
        NSInteger year = MAX(1980, c.year);
        _dosDate = (uint16_t)(((year - 1980) << 9) | (c.month << 5) | c.day);
        _dosTime = (uint16_t)((c.hour << 11) | (c.minute << 5) | (c.second / 2));
        if (!_file) _failed = YES;
    }
    return self;
}

- (void)dealloc {
    if (_file) fclose(_file);
}

- (void)writeU16:(uint16_t)value {
    uint8_t b[2] = { (uint8_t)(value & 0xFF), (uint8_t)(value >> 8) };
    if (fwrite(b, 1, 2, _file) != 2) _failed = YES;
}

- (void)writeU32:(uint32_t)value {
    uint8_t b[4] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF), (uint8_t)((value >> 16) & 0xFF), (uint8_t)(value >> 24) };
    if (fwrite(b, 1, 4, _file) != 4) _failed = YES;
}

- (BOOL)addEntryNamed:(NSString *)name data:(NSData *)data {
    if (_failed || !_file || name.length == 0 || data.length >= 0xFFFFFFFFu || _records.count >= 65000) return NO;
    NSString *unique = name;
    NSUInteger counter = 1;
    while ([_names containsObject:unique.lowercaseString]) {
        NSString *extension = name.pathExtension;
        NSString *stem = extension.length > 0 ? [name stringByDeletingPathExtension] : name;
        unique = extension.length > 0 ? [NSString stringWithFormat:@"%@_%lu.%@", stem, (unsigned long)counter, extension] : [NSString stringWithFormat:@"%@_%lu", stem, (unsigned long)counter];
        counter++;
    }
    [_names addObject:unique.lowercaseString];

    NSData *nameData = [unique dataUsingEncoding:NSUTF8StringEncoding];
    if (nameData.length == 0 || nameData.length > 0xFFFF) return NO;

    uint16_t method = 0;
    NSData *payload = data;
    if (data.length > 64) {
        NSMutableData *packed = [NSMutableData dataWithLength:data.length];
        size_t written = compression_encode_buffer(packed.mutableBytes, packed.length, data.bytes, data.length, NULL, COMPRESSION_ZLIB);
        if (written > 0 && written < data.length) {
            packed.length = written;
            payload = packed;
            method = 8;
        }
    }

    ZSAEZipRecord *record = [ZSAEZipRecord new];
    record.name = nameData;
    record.method = method;
    record.crc = ZSAEZipCRC32(data.bytes, data.length);
    record.compressedSize = (uint32_t)payload.length;
    record.size = (uint32_t)data.length;
    long position = ftell(_file);
    if (position < 0 || (uint64_t)position >= 0xFFFFFFFFu) return NO;
    record.offset = (uint32_t)position;

    [self writeU32:0x04034B50];
    [self writeU16:20];
    [self writeU16:0x0800];
    [self writeU16:method];
    [self writeU16:_dosTime];
    [self writeU16:_dosDate];
    [self writeU32:record.crc];
    [self writeU32:record.compressedSize];
    [self writeU32:record.size];
    [self writeU16:(uint16_t)nameData.length];
    [self writeU16:0];
    if (fwrite(nameData.bytes, 1, nameData.length, _file) != nameData.length) _failed = YES;
    if (payload.length > 0 && fwrite(payload.bytes, 1, payload.length, _file) != payload.length) _failed = YES;
    if (_failed) return NO;
    [_records addObject:record];
    return YES;
}

- (BOOL)finish {
    if (_failed || !_file) return NO;
    long centralStart = ftell(_file);
    if (centralStart < 0) return NO;
    for (ZSAEZipRecord *record in _records) {
        [self writeU32:0x02014B50];
        [self writeU16:20];
        [self writeU16:20];
        [self writeU16:0x0800];
        [self writeU16:record.method];
        [self writeU16:_dosTime];
        [self writeU16:_dosDate];
        [self writeU32:record.crc];
        [self writeU32:record.compressedSize];
        [self writeU32:record.size];
        [self writeU16:(uint16_t)record.name.length];
        [self writeU16:0];
        [self writeU16:0];
        [self writeU16:0];
        [self writeU16:0];
        [self writeU32:0];
        [self writeU32:record.offset];
        if (fwrite(record.name.bytes, 1, record.name.length, _file) != record.name.length) _failed = YES;
    }
    long centralEnd = ftell(_file);
    if (centralEnd < 0 || _failed) return NO;
    [self writeU32:0x06054B50];
    [self writeU16:0];
    [self writeU16:0];
    [self writeU16:(uint16_t)_records.count];
    [self writeU16:(uint16_t)_records.count];
    [self writeU32:(uint32_t)(centralEnd - centralStart)];
    [self writeU32:(uint32_t)centralStart];
    [self writeU16:0];
    BOOL ok = !_failed && fflush(_file) == 0;
    fclose(_file);
    _file = NULL;
    return ok;
}

@end

static NSString *ZSAESafeFileComponent(NSString *text) {
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-_. "];
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        [safe appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    NSString *trimmed = [safe stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@". "]];
    if (trimmed.length > 80) trimmed = [trimmed substringToIndex:80];
    return trimmed;
}

static NSString *ZSAEClassFolderName(int32_t classID) {
    static NSDictionary<NSNumber *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @1: @"GameObject", @4: @"Transform", @21: @"Material", @23: @"MeshRenderer", @28: @"Texture2D",
            @33: @"MeshFilter", @43: @"Mesh", @48: @"Shader", @49: @"TextAsset", @74: @"AnimationClip",
            @82: @"AudioSource", @83: @"AudioClip", @89: @"CubeMap", @91: @"AnimatorController", @95: @"Animator",
            @111: @"Animation", @114: @"MonoBehaviour", @115: @"MonoScript", @117: @"Texture3D", @128: @"Font",
            @137: @"SkinnedMeshRenderer", @329: @"VideoClip", @198: @"ParticleSystem", @199: @"ParticleSystemRenderer", @213: @"Sprite",
            @212: @"SpriteRenderer", @187: @"Texture2DArray", @188: @"CubemapArray", @687078895: @"SpriteAtlas",
        };
    });
    return names[@(classID)] ?: [NSString stringWithFormat:@"Class_%d", classID];
}

static NSData *ZSAERawDataForObject(ZSAEObject *object) {
    NSData *serialized = object.session.serializedData;
    if (object.rawSize == 0 || object.rawStart > serialized.length || object.rawSize > serialized.length - object.rawStart) return nil;
    return [serialized subdataWithRange:NSMakeRange((NSUInteger)object.rawStart, (NSUInteger)object.rawSize)];
}

static NSData *ZSAEFontFileData(ZSAEObject *object, NSString **outExtension) {
    NSData *fontData = [object.fields[@"m_FontData"] isKindOfClass:[NSData class]] ? object.fields[@"m_FontData"] : nil;
    if (fontData.length < 4) return nil;
    const uint8_t *b = fontData.bytes;
    BOOL isOTF = b[0] == 'O' && b[1] == 'T' && b[2] == 'T' && b[3] == 'O';
    if (outExtension) *outExtension = isOTF ? @"otf" : @"ttf";
    return fontData;
}

static NSData *ZSAEMediaDataForObject(ZSAEContext *context, ZSAEObject *object, NSString **outExtension) {
    switch (object.classID) {
        case 28: {
            ZSAETextureRecord *record = nil;
            NSMutableData *rgba = nil;
            if (!ZSAEDecodeTextureObject(object, &record, &rgba, NULL)) return nil;
            UIImage *image = ZSAEImageFromRGBA(rgba, record.width, record.height);
            NSData *png = image ? UIImagePNGRepresentation(image) : nil;
            if (png.length > 0 && outExtension) *outExtension = @"png";
            return png.length > 0 ? png : nil;
        }
        case 213: {
            ZSAssetExplorerVisual *visual = ZSAEBuildSpriteVisual(context, object, NULL);
            UIImage *image = [visual imageAtPage:0 error:NULL];
            NSData *png = image ? UIImagePNGRepresentation(image) : nil;
            if (png.length > 0 && outExtension) *outExtension = @"png";
            return png.length > 0 ? png : nil;
        }
        case 49: {
            ZSAssetExplorerVisual *visual = ZSAEBuildTextAssetVisual(object, NULL);
            if (visual.exportData.length == 0) return nil;
            if (outExtension) *outExtension = visual.fileExtension.length > 0 ? visual.fileExtension : @"txt";
            return visual.exportData;
        }
        case 128:
            return ZSAEFontFileData(object, outExtension);
        case 329:
            return ZSAEVideoClipData(object, outExtension, NULL);
        default:
            return nil;
    }
}

static NSString *ZSAEObjectBaseName(ZSAEObject *object) {
    NSString *name = ZSAESafeFileComponent(ZSAEString(object.fields[@"m_Name"]) ?: @"");
    NSString *type = ZSAEClassFolderName(object.classID);
    if (name.length == 0) name = type;
    return [NSString stringWithFormat:@"%@_%lld", name, (long long)object.pathID];
}

static void ZSAECollectPPtrs(id value, NSMutableArray<NSDictionary *> *out, NSUInteger depth) {
    if (depth > 64) return;
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = value;
        if (ZSAEIsPPtr(dictionary)) {
            if (ZSAEInt(dictionary[@"m_PathID"]) != 0) [out addObject:dictionary];
            return;
        }
        for (id child in dictionary.allValues) ZSAECollectPPtrs(child, out, depth + 1);
    } else if ([value isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)value) ZSAECollectPPtrs(child, out, depth + 1);
    }
}

static NSString *ZSAEBundleFolderName(ZSAEContext *context, NSString *bundlePath) {
    if (!context.cachedBundles) context.cachedBundles = [ZSAssetExplorer cachedBundles:nil] ?: @[];
    for (ZSAssetExplorerBundle *candidate in context.cachedBundles) {
        if ([candidate.filePath isEqualToString:bundlePath] && candidate.cabIdentifier.length > 0) return ZSAESafeFileComponent(candidate.cabIdentifier);
    }
    return @"Bundle";
}

static NSString *ZSAEBaseNameForUnresolved(ZSAEObject *object) {
    return [NSString stringWithFormat:@"%@/%@", ZSAEClassFolderName(object.classID), ZSAEObjectBaseName(object)];
}

static NSString *ZSAEObjectKey(ZSAEObject *object) {
    return [NSString stringWithFormat:@"%@|%lld", object.session.bundlePath ?: @"", (long long)object.pathID];
}



typedef struct {
    uint64_t hash;
    int64_t pathID;
    int32_t classID;
    int32_t reserved;
} ZSAEIndexRecord;

static uint64_t ZSAEHashName(NSString *name) {
    const char *utf8 = [name lowercaseString].UTF8String;
    uint64_t hash = 1469598103934665603ULL;
    if (!utf8) return hash;
    for (const unsigned char *c = (const unsigned char *)utf8; *c; c++) {
        hash ^= *c;
        hash *= 1099511628211ULL;
    }
    return hash;
}

static NSObject *ZSAEIndexLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *ZSAEIndexPath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return caches ? [caches stringByAppendingPathComponent:@"ZSAssetNameIndex.plist"] : nil;
}

static NSMutableDictionary<NSString *, NSDictionary *> *ZSAEIndexStore(void) {
    static NSMutableDictionary<NSString *, NSDictionary *> *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = ZSAEIndexPath();
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL] : nil;
        store = [plist isKindOfClass:[NSMutableDictionary class]] ? plist : [NSMutableDictionary dictionary];
    });
    return store;
}

static BOOL gZSAEIndexBuilding = NO;

static void ZSAESaveIndex(void) {
    NSString *path = ZSAEIndexPath();
    if (!path) return;
    NSDictionary *snapshot = nil;
    @synchronized (ZSAEIndexLock()) {
        snapshot = [ZSAEIndexStore() copy];
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:snapshot format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (data) [data writeToFile:path atomically:YES];
}

static BOOL ZSAEIsIndexedClass(int32_t classID) {
    return classID == 28 || classID == 213 || classID == 687078895;
}

static NSData *ZSAEScanIndexRecords(NSString *path) {
    ZSAEBundle *bundle = nil;
    if (!ZSAEOpenBundle(path, &bundle, NULL)) return nil;

    ZSAEBundleNode *cabNode = ZSAEFindSerializedNode(bundle);
    if (!cabNode || cabNode.size < 64) return nil;

    NSData *head = ZSAEReadBundleRange(bundle, cabNode.offset, 48, NULL);
    if (head.length < 48) return nil;
    uint64_t dataOffset = ZSAEReadU64BEBytes((const uint8_t *)head.bytes + 32);
    if (dataOffset < 48 || dataOffset > cabNode.size || dataOffset > (16ULL << 20)) return nil;

    NSData *metadata = ZSAEReadBundleRange(bundle, cabNode.offset, dataOffset, NULL);
    if (!metadata) return nil;

    NSArray<ZSAssetExplorerAsset *> *assets = nil;
    if (!ZSAEParseSerializedFile(metadata, &assets, INT64_MIN, NULL, NULL, NULL, NULL, NULL)) return nil;

    NSMutableArray<ZSAssetExplorerAsset *> *wanted = [NSMutableArray array];
    for (ZSAssetExplorerAsset *asset in assets) {
        if (!ZSAEIsIndexedClass(asset.classID) || asset.objectSize < 5) continue;
        uint64_t objectStart = cabNode.offset + dataOffset + asset.byteStart;
        uint64_t readLength = MIN((uint64_t)asset.objectSize, (uint64_t)260);
        if (objectStart + readLength > cabNode.offset + cabNode.size) continue;
        [wanted addObject:asset];
    }
    [wanted sortUsingComparator:^NSComparisonResult(ZSAssetExplorerAsset *a, ZSAssetExplorerAsset *b) {
        if (a.byteStart < b.byteStart) return NSOrderedAscending;
        if (a.byteStart > b.byteStart) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableData *records = [NSMutableData dataWithCapacity:wanted.count * sizeof(ZSAEIndexRecord)];
    NSUInteger i = 0;
    while (i < wanted.count) {
        uint64_t groupStart = cabNode.offset + dataOffset + wanted[i].byteStart;
        uint64_t groupEnd = groupStart + MIN((uint64_t)wanted[i].objectSize, (uint64_t)260);
        NSUInteger j = i + 1;
        while (j < wanted.count) {
            uint64_t start = cabNode.offset + dataOffset + wanted[j].byteStart;
            uint64_t end = start + MIN((uint64_t)wanted[j].objectSize, (uint64_t)260);
            if (start > groupEnd + 65536 || end - groupStart > (4ULL << 20)) break;
            groupEnd = MAX(groupEnd, end);
            j++;
        }

        NSData *blob = ZSAEReadBundleRange(bundle, groupStart, groupEnd - groupStart, NULL);
        if (blob) {
            const uint8_t *bytes = blob.bytes;
            for (NSUInteger k = i; k < j; k++) {
                uint64_t offset = cabNode.offset + dataOffset + wanted[k].byteStart - groupStart;
                uint64_t available = MIN((uint64_t)wanted[k].objectSize, (uint64_t)260);
                if (offset + available > blob.length || available < 5) continue;
                int32_t nameLength = ZSAEReadI32LEBytes(bytes + offset);
                if (nameLength <= 0 || (uint64_t)nameLength > available - 4) continue;
                NSString *name = [[NSString alloc] initWithBytes:bytes + offset + 4 length:(NSUInteger)nameLength encoding:NSUTF8StringEncoding];
                if (name.length == 0) continue;
                ZSAEIndexRecord record = { ZSAEHashName(name), wanted[k].pathID, wanted[k].classID, 0 };
                [records appendBytes:&record length:sizeof(record)];
            }
        }
        i = j;
    }
    return records;
}

@implementation ZSAssetExplorer

+ (void)resolveNamesForBundles:(NSArray<ZSAssetExplorerBundle *> *)bundles
                     batchSize:(NSUInteger)batchSize
                shouldContinue:(BOOL (^)(void))shouldContinue
                       handler:(void (^)(NSArray<ZSAssetExplorerBundle *> *))handler {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.120F.AssetExplorerNames", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_sync(queue, ^{
        NSMutableArray<ZSAssetExplorerBundle *> *working = [bundles mutableCopy];
        NSUInteger sinceDelivery = 0;

        for (NSUInteger i = 0; i < working.count; i++) {
            ZSAssetExplorerBundle *original = working[i];
            if (original.nameResolved) continue;
            if (shouldContinue && !shouldContinue()) break;

            @autoreleasepool {
                NSString *name = ZSAEReadAssetBundleName(original.filePath);
                NSString *signature = ZSAEFileSignature(original.filePath);

                ZSAssetExplorerBundle *updated = [ZSAssetExplorerBundle new];
                updated.cabIdentifier = original.cabIdentifier;
                updated.filePath = original.filePath;
                updated.displayName = name.length > 0 ? name : original.displayName;
                updated.nameResolved = YES;
                working[i] = updated;

                if (signature) {
                    @synchronized (ZSAENameCacheLock()) {
                        ZSAENameCache()[original.cabIdentifier] = @{@"name": name ?: @"", @"sig": signature};
                    }
                }
            }

            sinceDelivery++;
            if (batchSize > 0 && sinceDelivery >= batchSize) {
                ZSAESaveNameCache();
                handler([working copy]);
                sinceDelivery = 0;
            }
        }

        if (sinceDelivery > 0) {
            ZSAESaveNameCache();
            handler([working copy]);
        }
    });
}

+ (NSArray<NSString *> *)zs_sharedRoots {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (library.length > 0) {
        NSString *exact = [library stringByAppendingPathComponent:@"UnityCache/Shared"];
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:exact isDirectory:&isDirectory] && isDirectory) {
            [roots addObject:exact];
        }
    }
    for (NSString *root in [UnityCacheLocator unityCacheSharedDirectories]) {
        if (root.length > 0 && ![roots containsObject:root]) [roots addObject:root];
    }
    return roots;
}

+ (NSArray<ZSAssetExplorerBundle *> *)zs_bundlesFromIndexedCABMap:(NSDictionary<NSString *, NSArray<NSString *> *> *)map {
    NSMutableArray<ZSAssetExplorerBundle *> *bundles = [NSMutableArray arrayWithCapacity:map.count];
    for (NSString *cab in map) {
        NSArray<NSString *> *paths = map[cab];
        if (![cab isKindOfClass:[NSString class]] || ![paths isKindOfClass:[NSArray class]]) continue;
        NSString *livePath = nil;
        for (NSString *path in paths) {
            if ([path isKindOfClass:[NSString class]] && access(path.fileSystemRepresentation, F_OK) == 0) {
                livePath = path;
                break;
            }
        }
        if (!livePath) continue;

        ZSAssetExplorerBundle *bundle = [ZSAssetExplorerBundle new];
        bundle.cabIdentifier = cab;
        NSString *identifier = [cab hasPrefix:@"CAB-"] ? [cab substringFromIndex:4] : cab;
        NSUInteger count = MIN((NSUInteger)7, identifier.length);
        NSString *shortIdentifier = count > 0 ? [identifier substringToIndex:count] : identifier;
        bundle.displayName = [NSString stringWithFormat:@"CAB-%@", shortIdentifier];
        bundle.filePath = livePath;
        ZSAEApplyCachedName(bundle);
        [bundles addObject:bundle];
    }

    return [bundles sortedArrayUsingComparator:^NSComparisonResult(ZSAssetExplorerBundle *a, ZSAssetExplorerBundle *b) {
        NSComparisonResult result = [a.displayName caseInsensitiveCompare:b.displayName];
        if (result != NSOrderedSame) return result;
        return [a.cabIdentifier caseInsensitiveCompare:b.cabIdentifier];
    }];
}

+ (NSArray<ZSAssetExplorerBundle *> *)cachedBundles:(NSError **)error {
    NSDictionary<NSString *, NSArray<NSString *> *> *indexed = [ZSFileIndex persistedCABMap];
    if (indexed.count == 0) {
        [ZSFileIndex ensureIndexUpToDate];
        indexed = [ZSFileIndex persistedCABMap];
    }

    NSArray<ZSAssetExplorerBundle *> *bundles = [self zs_bundlesFromIndexedCABMap:indexed ?: @{}];
    if (bundles.count > 0) return bundles;

    if (indexed.count > 0) {
        [ZSFileIndex forceReindex];
        indexed = [ZSFileIndex persistedCABMap];
        bundles = [self zs_bundlesFromIndexedCABMap:indexed ?: @{}];
        if (bundles.count > 0) return bundles;
    }

    if (error) {
        if ([self zs_sharedRoots].count == 0) {
            *error = ZSAEError(ZSAssetExplorerErrorSharedDirectoryNotFound, @"Library/UnityCache/Shared was not found.");
        } else {
            *error = ZSAEError(ZSAssetExplorerErrorNoBundles, @"No UnityFS AssetBundles were found in Library/UnityCache/Shared.");
        }
    }
    return @[];
}

+ (ZSAssetExplorerTexture *)textureForPathID:(int64_t)pathID inBundleAtPath:(NSString *)path error:(NSError **)error {
    ZSAEBundle *bundle = nil;
    if (!ZSAEOpenBundle(path, &bundle, error)) return nil;

    ZSAEBundleNode *cabNode = ZSAEFindSerializedNode(bundle);
    if (!cabNode) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"No serialized CAB node was found in the bundle.");
        return nil;
    }

    NSString *serializedPath = nil;
    NSData *serializedData = ZSAEResidentNodeData(bundle, cabNode);
    if (!serializedData) {
        if (!ZSAEReadFileNodeData(bundle.fileData, cabNode.offset, cabNode.size,
                                  bundle.blockData.bytes, bundle.blockCount,
                                  &serializedPath, error) || serializedPath.length == 0) {
            return nil;
        }

        NSError *mapError = nil;
        serializedData = [NSData dataWithContentsOfFile:serializedPath options:NSDataReadingMappedIfSafe error:&mapError];
        if (!serializedData) {
            [NSFileManager.defaultManager removeItemAtPath:serializedPath error:nil];
            if (error) *error = mapError ?: ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't map the serialized file.");
            return nil;
        }
    }

    ZSAETextureRecord *record = nil;
    BOOL parsed = ZSAEParseSerializedFile(serializedData, nil, pathID, &record, NULL, NULL, NULL, error);
    if (serializedPath.length > 0) [NSFileManager.defaultManager removeItemAtPath:serializedPath error:nil];
    if (!parsed || !record) return nil;

    NSData *pixels = record.inlineData;
    if (pixels.length == 0) {
        if (record.streamSize == 0) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"The texture has no pixel data.");
            return nil;
        }
        NSString *streamName = record.streamPath.lastPathComponent;
        ZSAEBundleNode *streamNode = nil;
        for (ZSAEBundleNode *node in bundle.nodes) {
            if (streamName.length > 0 && [node.path isEqualToString:streamName]) {
                streamNode = node;
                break;
            }
        }
        if (!streamNode) {
            for (ZSAEBundleNode *node in bundle.nodes) {
                if ((node.flags & 4) == 0 && [node.path hasSuffix:@".resS"]) {
                    streamNode = node;
                    break;
                }
            }
        }
        if (!streamNode || record.streamOffset > streamNode.size || record.streamSize > streamNode.size - record.streamOffset) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The texture's streamed data wasn't found in the bundle.");
            return nil;
        }
        pixels = ZSAEReadBundleRange(bundle, streamNode.offset + record.streamOffset, record.streamSize, error);
        if (!pixels) return nil;
    }

    NSMutableData *rgba = nil;
    if (!ZSAEDecodeTexture(record, pixels, &rgba, error)) return nil;

    UIImage *image = ZSAEImageFromRGBA(rgba, record.width, record.height);
    if (!image) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureDecodeFailed, @"Couldn't build an image from the decoded texture.");
        return nil;
    }

    ZSAssetExplorerTexture *texture = [ZSAssetExplorerTexture new];
    texture.image = image;
    texture.name = record.name;
    texture.width = record.width;
    texture.height = record.height;
    texture.format = record.format;
    texture.formatName = ZSAETextureFormatName(record.format);
    return texture;
}

+ (BOOL)loadBundleIntoMemoryAtPath:(NSString *)path error:(NSError **)error {
    return ZSAELoadResidentBundle(path, error);
}

+ (void)unloadBundleAtPath:(NSString *)path {
    ZSAEUnloadResidentBundle(path);
}

+ (void)unloadAllBundles {
    NSMutableDictionary<NSString *, ZSAEBundle *> *bundles = ZSAEResidentBundles();
    NSArray<NSString *> *paths = nil;
    @synchronized (bundles) {
        paths = bundles.allKeys;
    }
    for (NSString *path in paths) ZSAEUnloadResidentBundle(path);
}

+ (UIImage *)thumbnailForPathID:(int64_t)pathID classID:(int32_t)classID inBundleAtPath:(NSString *)path maxDimension:(CGFloat)maxDimension error:(NSError **)error {
    ZSAssetExplorerVisual *visual = [self visualForPathID:pathID classID:classID inBundleAtPath:path error:error];
    if (!visual || visual.text.length > 0) return nil;
    UIImage *image = [visual imageAtPage:0 error:error];
    if (!image) return nil;
    CGFloat longest = MAX(image.size.width, image.size.height);
    if (maxDimension <= 0 || longest <= maxDimension || longest <= 0) return image;
    CGFloat factor = maxDimension / longest;
    CGSize target = CGSizeMake(MAX(1, floor(image.size.width * factor)), MAX(1, floor(image.size.height * factor)));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

+ (BOOL)hasVisualPreviewForClassID:(int32_t)classID {
    return classID >= 0;
}

+ (BOOL)classID:(int32_t)a sharesPreviewGroupWithClassID:(int32_t)b {
    BOOL aImage = ZSAEIsImageClass(a);
    BOOL bImage = ZSAEIsImageClass(b);
    if (aImage || bImage) return aImage && bImage;
    return a == b;
}

+ (ZSAssetExplorerVisual *)visualForPathID:(int64_t)pathID classID:(int32_t)classID inBundleAtPath:(NSString *)path error:(NSError **)error {
    if (classID == 28) {
        ZSAssetExplorerTexture *texture = [self textureForPathID:pathID inBundleAtPath:path error:error];
        if (!texture) return nil;
        UIImage *image = texture.image;
        ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
        visual.name = texture.name;
        visual.summary = [NSString stringWithFormat:@"%@  •  %ldx%ld  •  %@", texture.name.length > 0 ? texture.name : @"Texture2D",
                          (long)texture.width, (long)texture.height, texture.formatName];
        visual.pageLabels = @[@"Texture"];
        visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
            return image;
        };
        return visual;
    }

    ZSAEContext *context = [ZSAEContext new];
    context.sessions = [NSMutableDictionary dictionary];
    ZSAESession *session = ZSAEOpenSession(path, error);
    if (!session) return nil;
    context.sessions[path] = session;

    ZSAEObject *object = ZSAEReadObject(session, pathID, error);
    if (!object) return nil;

    switch (object.classID) {
        case 198:
        case 199:
            return ZSAEBuildParticleVisual(context, object, pathID, error);
        case 213:
            return ZSAEBuildSpriteVisual(context, object, error);
        case 687078895:
            return ZSAEBuildAtlasVisual(context, object, error);
        case 89:
        case 117:
        case 187:
        case 188:
            return ZSAEBuildSliceVisual(object, error);
        case 1:
            return ZSAEBuildGameObjectVisual(context, object, error);
        case 114:
            return ZSAEBuildMonoBehaviourVisual(context, object, pathID, error);
        case 21:
            return ZSAEBuildMaterialVisual(context, object, error);
        case 49:
            return ZSAEBuildTextAssetVisual(object, error);
        case 128:
            return ZSAEBuildFontVisual(object, error);
        case 329:
            return ZSAEBuildVideoClipVisual(object, error);
        case 23:
        case 33:
        case 43:
        case 137:
            return ZSAEBuildMeshVisual(context, object, error);
        default:
            return ZSAEBuildInspectorVisual(object, error);
    }
}

+ (NSData *)jsonDataForPathID:(int64_t)pathID inBundleAtPath:(NSString *)path error:(NSError **)error {
    ZSAESession *session = ZSAEOpenSession(path, error);
    if (!session) return nil;
    ZSAEObject *object = ZSAEReadObject(session, pathID, error);
    if (!object) return nil;
    return ZSAEJSONDataForObject(object, error);
}

+ (NSString *)exportAssetAtPathID:(int64_t)pathID inBundleAtPath:(NSString *)path toDirectory:(NSString *)directory error:(NSError **)error {
    ZSAEContext *context = [ZSAEContext new];
    context.sessions = [NSMutableDictionary dictionary];
    ZSAESession *session = ZSAEOpenSession(path, error);
    if (!session) return nil;
    context.sessions[path] = session;
    ZSAEObject *object = ZSAEReadObject(session, pathID, error);
    if (!object) return nil;

    NSString *extension = nil;
    NSData *data = ZSAEMediaDataForObject(context, object, &extension);
    if (data.length == 0) {
        data = ZSAERawDataForObject(object);
        extension = @"asset";
    }
    if (data.length == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorAssetNotFound, @"The asset's data couldn't be read.");
        return nil;
    }

    NSString *fileName = [ZSAEObjectBaseName(object) stringByAppendingPathExtension:extension];
    NSString *outputPath = [directory stringByAppendingPathComponent:fileName];
    if (![data writeToFile:outputPath atomically:YES]) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't write the exported file.");
        return nil;
    }
    return outputPath;
}

+ (NSString *)fullExportAssetAtPathID:(int64_t)pathID inBundleAtPath:(NSString *)path toDirectory:(NSString *)directory error:(NSError **)error {
    return [self fullExportAssetAtPathID:pathID inBundleAtPath:path toDirectory:directory jsonOnly:NO error:error];
}

+ (NSString *)fullExportAssetAtPathID:(int64_t)pathID inBundleAtPath:(NSString *)path toDirectory:(NSString *)directory jsonOnly:(BOOL)jsonOnly error:(NSError **)error {
    ZSAEContext *context = [ZSAEContext new];
    context.sessions = [NSMutableDictionary dictionary];
    ZSAESession *session = ZSAEOpenSession(path, error);
    if (!session) return nil;
    context.sessions[path] = session;
    ZSAEObject *root = ZSAEReadObject(session, pathID, error);
    if (!root) return nil;

    NSString *zipName = jsonOnly ? [ZSAEObjectBaseName(root) stringByAppendingString:@"_json"] : ZSAEObjectBaseName(root);
    NSString *zipPath = [directory stringByAppendingPathComponent:[zipName stringByAppendingPathExtension:@"zip"]];
    ZSAEZipWriter *zip = [[ZSAEZipWriter alloc] initWithPath:zipPath];

    const NSUInteger kMaxObjects = 1500;
    NSMutableArray<ZSAEObject *> *queue = [NSMutableArray arrayWithObject:root];
    NSMutableSet<NSString *> *visited = [NSMutableSet setWithObject:ZSAEObjectKey(root)];
    NSMutableArray<NSDictionary *> *manifestObjects = [NSMutableArray array];
    NSMutableArray<NSString *> *unresolved = [NSMutableArray array];
    NSMutableSet<NSString *> *unresolvedSeen = [NSMutableSet set];
    BOOL truncated = NO;
    NSUInteger cursor = 0;

    while (cursor < queue.count) {
        @autoreleasepool {
            ZSAEObject *object = queue[cursor++];
            NSString *folder = [NSString stringWithFormat:@"%@/%@", ZSAEBundleFolderName(context, object.session.bundlePath), ZSAEClassFolderName(object.classID)];
            NSString *base = ZSAEObjectBaseName(object);
            NSMutableArray<NSString *> *files = [NSMutableArray array];

            if (jsonOnly) {
                NSData *json = ZSAEJSONDataForObject(object, NULL);
                if (json.length > 0) {
                    NSString *entry = [NSString stringWithFormat:@"%@/%@.json", folder, base];
                    if ([zip addEntryNamed:entry data:json]) [files addObject:entry];
                }
            } else {
                NSString *mediaExtension = nil;
                NSData *media = ZSAEMediaDataForObject(context, object, &mediaExtension);
                if (media.length > 0) {
                    NSString *entry = [NSString stringWithFormat:@"%@/%@.%@", folder, base, mediaExtension];
                    if ([zip addEntryNamed:entry data:media]) [files addObject:entry];
                }
                NSData *raw = ZSAERawDataForObject(object);
                if (raw.length > 0) {
                    NSString *entry = [NSString stringWithFormat:@"%@/%@.asset", folder, base];
                    if ([zip addEntryNamed:entry data:raw]) [files addObject:entry];
                }
            }

            NSMutableArray<NSDictionary *> *pointers = [NSMutableArray array];
            ZSAECollectPPtrs(object.fields, pointers, 0);
            NSMutableArray<NSDictionary *> *references = [NSMutableArray array];
            NSMutableSet<NSString *> *localSeen = [NSMutableSet set];
            NSMutableSet<NSString *> *pointerSeen = [NSMutableSet set];
            for (NSDictionary *pointer in pointers) {
                NSString *identity = [NSString stringWithFormat:@"%lld:%lld", (long long)ZSAEInt(pointer[@"m_FileID"]), (long long)ZSAEInt(pointer[@"m_PathID"])];
                if ([pointerSeen containsObject:identity]) continue;
                [pointerSeen addObject:identity];
                NSError *resolveError = nil;
                ZSAEObject *target = ZSAEResolvePPtr(context, object, pointer, &resolveError);
                if (!target) {
                    NSString *reason = resolveError.localizedDescription ?: @"Unresolved reference.";
                    NSString *line = [NSString stringWithFormat:@"%@ (PathID %lld): %@", ZSAEBaseNameForUnresolved(object), (long long)ZSAEInt(pointer[@"m_PathID"]), reason];
                    if (![unresolvedSeen containsObject:line]) {
                        [unresolvedSeen addObject:line];
                        [unresolved addObject:line];
                    }
                    continue;
                }
                NSString *key = ZSAEObjectKey(target);
                if (![localSeen containsObject:key]) {
                    [localSeen addObject:key];
                    [references addObject:@{@"bundle": ZSAEBundleFolderName(context, target.session.bundlePath), @"type": ZSAEClassFolderName(target.classID), @"pathID": @(target.pathID)}];
                }
                if ([visited containsObject:key]) continue;
                if (queue.count >= kMaxObjects) { truncated = YES; continue; }
                [visited addObject:key];
                [queue addObject:target];
            }

            [manifestObjects addObject:@{
                @"bundle": ZSAEBundleFolderName(context, object.session.bundlePath),
                @"type": ZSAEClassFolderName(object.classID),
                @"classID": @(object.classID),
                @"pathID": @(object.pathID),
                @"name": ZSAEString(object.fields[@"m_Name"]) ?: (id)[NSNull null],
                @"isRoot": @(object == root),
                @"files": files,
                @"references": references,
            }];
        }
    }

    NSDictionary *manifest = @{
        @"root": @{@"bundle": ZSAEBundleFolderName(context, root.session.bundlePath), @"type": ZSAEClassFolderName(root.classID), @"pathID": @(root.pathID)},
        @"objectCount": @(manifestObjects.count),
        @"truncated": @(truncated),
        @"unresolvedReferences": unresolved,
        @"objects": manifestObjects,
    };
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (manifestData.length > 0) [zip addEntryNamed:@"manifest.json" data:manifestData];

    if (![zip finish]) {
        [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't write the zip archive.");
        return nil;
    }
    return zipPath;
}

+ (NSArray<ZSAssetExplorerAsset *> *)assetsForBundleAtPath:(NSString *)path error:(NSError **)error {
    NSString *serializedPath = nil;
    NSString *cab = nil;
    NSData *serializedData = nil;
    ZSAEBundle *residentBundle = ZSAEResidentBundleForPath(path);
    ZSAEBundleNode *residentNode = residentBundle ? ZSAEFindSerializedNode(residentBundle) : nil;
    if (residentNode) serializedData = ZSAEResidentNodeData(residentBundle, residentNode);

    if (serializedData) {
        cab = residentNode.path;
        if (cab.length == 0) {
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The bundle has no valid serialized CAB identifier.");
            return @[];
        }
    } else {
        if (!ZSAEParseUnityFSForSerializedPath(path, &serializedPath, &cab, error)) return @[];
        if (cab.length == 0 || serializedPath.length == 0) {
            if (serializedPath.length > 0) [[NSFileManager defaultManager] removeItemAtPath:serializedPath error:nil];
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The bundle has no valid serialized CAB identifier.");
            return @[];
        }

        NSError *mapError = nil;
        serializedData = [NSData dataWithContentsOfFile:serializedPath options:NSDataReadingMappedIfSafe error:&mapError];
        if (!serializedData) {
            [[NSFileManager defaultManager] removeItemAtPath:serializedPath error:nil];
            if (error) *error = mapError ?: ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't map the serialized file.");
            return @[];
        }
    }

    NSArray<ZSAssetExplorerAsset *> *assets = nil;
    BOOL ok = ZSAEParseSerializedFile(serializedData, &assets, INT64_MIN, NULL, NULL, NULL, NULL, error);
    if (serializedPath.length > 0) [[NSFileManager defaultManager] removeItemAtPath:serializedPath error:nil];
    if (!ok) return @[];
    return [(assets ?: @[]) sortedArrayUsingComparator:^NSComparisonResult(ZSAssetExplorerAsset *a, ZSAssetExplorerAsset *b) {
        NSString *nameA = a.assetName.length > 0 ? a.assetName : (a.typeName ?: @"");
        NSString *nameB = b.assetName.length > 0 ? b.assetName : (b.typeName ?: @"");
        NSComparisonResult result = [nameA compare:nameB options:NSCaseInsensitiveSearch | NSNumericSearch];
        if (result != NSOrderedSame) return result;
        result = [(a.typeName ?: @"") caseInsensitiveCompare:(b.typeName ?: @"")];
        if (result != NSOrderedSame) return result;
        if (a.pathID < b.pathID) return NSOrderedAscending;
        if (a.pathID > b.pathID) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

+ (BOOL)isNameIndexBuilding {
    @synchronized (ZSAEIndexLock()) {
        return gZSAEIndexBuilding;
    }
}

+ (NSUInteger)indexedBundleCount {
    @synchronized (ZSAEIndexLock()) {
        return ZSAEIndexStore().count;
    }
}

+ (void)buildNameIndexWithProgress:(void (^)(NSUInteger, NSUInteger))progress completion:(void (^)(BOOL))completion {
    @synchronized (ZSAEIndexLock()) {
        if (gZSAEIndexBuilding) return;
        gZSAEIndexBuilding = YES;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSArray<ZSAssetExplorerBundle *> *bundles = [ZSAssetExplorer cachedBundles:&error];
        NSUInteger total = bundles.count;
        NSMutableSet<NSString *> *liveCABs = [NSMutableSet setWithCapacity:total];
        NSUInteger done = 0;

        for (ZSAssetExplorerBundle *bundle in bundles) {
            @autoreleasepool {
                [liveCABs addObject:bundle.cabIdentifier];
                NSString *signature = ZSAEFileSignature(bundle.filePath);
                NSDictionary *existing = nil;
                @synchronized (ZSAEIndexLock()) {
                    existing = ZSAEIndexStore()[bundle.cabIdentifier];
                }
                BOOL fresh = signature && [existing[@"sig"] isEqualToString:signature];
                if (!fresh && signature) {
                    NSData *records = ZSAEScanIndexRecords(bundle.filePath);
                    if (records) {
                        NSString *name = ZSAEReadAssetBundleName(bundle.filePath);
                        @synchronized (ZSAENameCacheLock()) {
                            ZSAENameCache()[bundle.cabIdentifier] = @{@"name": name ?: @"", @"sig": signature};
                        }
                        NSDictionary *entry = @{
                            @"sig": signature,
                            @"path": bundle.filePath ?: @"",
                            @"b": name.length > 0 ? name : bundle.displayName,
                            @"r": records,
                        };
                        @synchronized (ZSAEIndexLock()) {
                            ZSAEIndexStore()[bundle.cabIdentifier] = entry;
                        }
                    }
                }
                done++;
                if (progress && (done % 20 == 0 || done == total)) {
                    NSUInteger snapshotDone = done;
                    dispatch_async(dispatch_get_main_queue(), ^{ progress(snapshotDone, total); });
                }
                if (done % 150 == 0) {
                    ZSAESaveIndex();
                    ZSAESaveNameCache();
                }
            }
        }

        BOOL success = total > 0;
        if (success) {
            @synchronized (ZSAEIndexLock()) {
                NSMutableDictionary *store = ZSAEIndexStore();
                for (NSString *cab in store.allKeys) {
                    if (![liveCABs containsObject:cab]) [store removeObjectForKey:cab];
                }
            }
            ZSAESaveIndex();
            ZSAESaveNameCache();
        }

        @synchronized (ZSAEIndexLock()) {
            gZSAEIndexBuilding = NO;
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
    });
}

+ (NSArray<ZSAssetLocation *> *)locationsForAssetName:(NSString *)name classIDs:(NSArray<NSNumber *> *)classIDs {
    if (name.length == 0) return @[];
    uint64_t hash = ZSAEHashName(name);
    NSDictionary<NSString *, NSDictionary *> *snapshot = nil;
    @synchronized (ZSAEIndexLock()) {
        snapshot = [ZSAEIndexStore() copy];
    }

    NSMutableArray<ZSAssetLocation *> *results = [NSMutableArray array];
    for (NSString *cab in snapshot) {
        NSData *records = snapshot[cab][@"r"];
        if (![records isKindOfClass:[NSData class]]) continue;
        const ZSAEIndexRecord *items = records.bytes;
        NSUInteger count = records.length / sizeof(ZSAEIndexRecord);
        for (NSUInteger i = 0; i < count; i++) {
            if (items[i].hash != hash) continue;
            if (classIDs.count > 0 && ![classIDs containsObject:@(items[i].classID)]) continue;
            ZSAssetLocation *location = [ZSAssetLocation new];
            location.cabIdentifier = cab;
            NSString *bundleName = snapshot[cab][@"b"];
            location.bundleName = [bundleName isKindOfClass:[NSString class]] ? bundleName : cab;
            NSString *filePath = snapshot[cab][@"path"];
            location.filePath = [filePath isKindOfClass:[NSString class]] ? filePath : @"";
            location.classID = items[i].classID;
            location.pathID = items[i].pathID;
            [results addObject:location];
        }
    }
    [results sortUsingComparator:^NSComparisonResult(ZSAssetLocation *a, ZSAssetLocation *b) {
        NSComparisonResult order = [a.bundleName caseInsensitiveCompare:b.bundleName];
        if (order != NSOrderedSame) return order;
        return [a.cabIdentifier caseInsensitiveCompare:b.cabIdentifier];
    }];
    return results;
}

@end



#pragma mark FMOD bank core

typedef struct {
    uint64_t base;
    uint32_t version;
    uint32_t numSamples;
    uint32_t sampleHeaderSize;
    uint32_t nameTableSize;
    uint32_t dataSize;
    uint32_t mode;
    uint32_t headerSize;
} ZSFMODFSB;

typedef struct {
    uint64_t headerOffset;
    uint32_t headerLength;
    uint32_t frequency;
    uint32_t channels;
    uint64_t sampleCount;
    uint64_t dataOffset;
    uint32_t loopStart;
    uint32_t loopEnd;
    int hasLoop;
    uint32_t vorbisCRC;
    int hasVorbisCRC;
    uint32_t chunkCount;
    uint32_t chunkTypes[8];
    uint32_t chunkSizes[8];
} ZSFMODSampleHeader;

static const uint32_t kZSFMODFrequencies[10] = {4000, 8000, 11000, 11025, 16000, 22050, 24000, 32000, 44100, 48000};

static inline uint32_t zsfmod_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline uint64_t zsfmod_u64(const uint8_t *p) {
    return (uint64_t)zsfmod_u32(p) | ((uint64_t)zsfmod_u32(p + 4) << 32);
}

static int zsfmod_read_fsb(const uint8_t *p, uint64_t size, uint64_t at, ZSFMODFSB *out) {
    if (at + 60 > size || memcmp(p + at, "FSB5", 4) != 0) return 0;
    out->base = at;
    out->version = zsfmod_u32(p + at + 4);
    out->numSamples = zsfmod_u32(p + at + 8);
    out->sampleHeaderSize = zsfmod_u32(p + at + 12);
    out->nameTableSize = zsfmod_u32(p + at + 16);
    out->dataSize = zsfmod_u32(p + at + 20);
    out->mode = zsfmod_u32(p + at + 24);
    out->headerSize = out->version == 0 ? 64 : 60;
    uint64_t total = (uint64_t)out->headerSize + out->sampleHeaderSize + out->nameTableSize + out->dataSize;
    if (at + total > size) return 0;
    if ((uint64_t)out->numSamples * 8 > out->sampleHeaderSize) return 0;
    return 1;
}

static uint64_t zsfmod_fsb_total(const ZSFMODFSB *fsb) {
    return (uint64_t)fsb->headerSize + fsb->sampleHeaderSize + fsb->nameTableSize + fsb->dataSize;
}

static int zsfmod_collect_fsbs(const uint8_t *p, uint64_t size, ZSFMODFSB *out, int cap, uint32_t *bankVersion) {
    if (bankVersion) *bankVersion = 0;
    if (size < 12 || memcmp(p, "RIFF", 4) != 0) return -1;
    int count = 0;
    uint64_t pos = 12;
    while (pos + 8 <= size) {
        uint64_t chunkSize = zsfmod_u32(p + pos + 4);
        uint64_t body = pos + 8;
        uint64_t end = body + chunkSize;
        if (end > size) end = size;
        if (memcmp(p + pos, "FMT ", 4) == 0 && chunkSize >= 4 && body + 4 <= size) {
            if (bankVersion) *bankVersion = zsfmod_u32(p + body);
        } else if (memcmp(p + pos, "SND ", 4) == 0) {
            uint64_t cursor = body;
            while (cursor + 60 <= end && count < cap) {
                uint64_t found = UINT64_MAX;
                for (uint64_t q = cursor; q + 4 <= end && q < cursor + 64; q++) {
                    if (memcmp(p + q, "FSB5", 4) == 0) { found = q; break; }
                }
                if (found == UINT64_MAX) break;
                ZSFMODFSB fsb;
                if (!zsfmod_read_fsb(p, end, found, &fsb)) break;
                out[count++] = fsb;
                cursor = found + zsfmod_fsb_total(&fsb);
            }
        }
        pos = end;
    }
    return count;
}

static int zsfmod_read_sample_header(const uint8_t *p, uint64_t size, const ZSFMODFSB *fsb, uint64_t at, ZSFMODSampleHeader *out) {
    uint64_t limit = fsb->base + fsb->headerSize + fsb->sampleHeaderSize;
    if (limit > size) limit = size;
    if (at + 8 > limit) return 0;
    memset(out, 0, sizeof(*out));
    uint64_t raw = zsfmod_u64(p + at);
    out->headerOffset = at;
    uint32_t frequencyIndex = (uint32_t)((raw >> 1) & 0xF);
    out->frequency = frequencyIndex > 9 ? 0 : kZSFMODFrequencies[frequencyIndex];
    out->channels = (uint32_t)((raw >> 5) & 1) + 1;
    out->dataOffset = ((raw >> 6) & 0x0FFFFFFFULL) * 16;
    out->sampleCount = (raw >> 34) & 0x3FFFFFFFULL;
    int more = (int)(raw & 1);
    uint64_t cursor = at + 8;
    while (more) {
        if (cursor + 4 > limit) return 0;
        uint32_t header = zsfmod_u32(p + cursor);
        more = (int)(header & 1);
        uint32_t chunkSize = (header >> 1) & 0xFFFFFF;
        uint32_t chunkType = header >> 25;
        if (cursor + 4 + chunkSize > limit) return 0;
        const uint8_t *data = p + cursor + 4;
        if (out->chunkCount < 8) {
            out->chunkTypes[out->chunkCount] = chunkType;
            out->chunkSizes[out->chunkCount] = chunkSize;
            out->chunkCount++;
        }
        if (chunkType == 1 && chunkSize >= 1) {
            out->channels = data[0];
        } else if (chunkType == 2 && chunkSize >= 4) {
            out->frequency = zsfmod_u32(data);
        } else if (chunkType == 3 && chunkSize >= 8) {
            out->loopStart = zsfmod_u32(data);
            out->loopEnd = zsfmod_u32(data + 4);
            out->hasLoop = 1;
        } else if (chunkType == 11 && chunkSize >= 4) {
            out->vorbisCRC = zsfmod_u32(data);
            out->hasVorbisCRC = 1;
        }
        cursor += 4 + chunkSize;
    }
    out->headerLength = (uint32_t)(cursor - at);
    return 1;
}

#pragma mark FMOD bank explorer

NSString * const ZSFMODErrorDomain = @"ZSFMODErrorDomain";

static NSError *ZSFMODMakeError(NSString *message) {
    return [NSError errorWithDomain:ZSFMODErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *ZSFMODCodecName(uint32_t mode) {
    switch (mode) {
        case 0:  return @"None";
        case 1:  return @"PCM8";
        case 2:  return @"PCM16";
        case 3:  return @"PCM24";
        case 4:  return @"PCM32";
        case 5:  return @"PCM Float";
        case 6:  return @"GameCube ADPCM";
        case 7:  return @"IMA ADPCM";
        case 8:  return @"PS2/PSP VAG";
        case 9:  return @"PS Vita HEVAG";
        case 10: return @"Xbox 360 XMA";
        case 11: return @"MPEG (MP3)";
        case 12: return @"CELT";
        case 13: return @"PS4/Vita AT9";
        case 14: return @"Xbox XWMA";
        case 15: return @"Vorbis";
        default: return [NSString stringWithFormat:@"Unknown (%u)", mode];
    }
}

static NSString *ZSFMODChunkName(uint32_t type) {
    switch (type) {
        case 1:  return @"Channels";
        case 2:  return @"Frequency";
        case 3:  return @"Loop";
        case 4:  return @"XMA seek";
        case 6:  return @"DSP coefficients";
        case 7:  return @"XWMA data";
        case 11: return @"Vorbis data";
        default: return [NSString stringWithFormat:@"Chunk %u", type];
    }
}

static void ZSFMODPutU16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[2] = {(uint8_t)(value & 0xFF), (uint8_t)(value >> 8)};
    [data appendBytes:bytes length:2];
}

static void ZSFMODPutU32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[4] = {(uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF), (uint8_t)((value >> 16) & 0xFF), (uint8_t)(value >> 24)};
    [data appendBytes:bytes length:4];
}

static void ZSFMODWriteU32(uint8_t *target, uint32_t value) {
    target[0] = (uint8_t)(value & 0xFF);
    target[1] = (uint8_t)((value >> 8) & 0xFF);
    target[2] = (uint8_t)((value >> 16) & 0xFF);
    target[3] = (uint8_t)(value >> 24);
}

static NSString *ZSFMODChannelText(NSInteger channels) {
    if (channels == 1) return @"1 (mono)";
    if (channels == 2) return @"2 (stereo)";
    return [NSString stringWithFormat:@"%ld", (long)channels];
}

@implementation ZSFMODBankFile
@end

@implementation ZSFMODStream
- (NSTimeInterval)duration {
    return self.frequency > 0 ? (NSTimeInterval)self.sampleCount / (NSTimeInterval)self.frequency : 0;
}
@end

@implementation ZSFMODBank
@end

@implementation ZSFMODExplorer

+ (NSString *)banksDirectory {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"Assets/Sound/FMODBuilds/Mobile"];
}

+ (NSArray<ZSFMODBankFile *> *)availableBanks:(NSError **)error {
    NSString *directory = [self banksDirectory];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
        if (error) *error = ZSFMODMakeError(@"FMOD bank folder not found.");
        return @[];
    }
    NSArray<NSString *> *names = [fileManager contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    NSMutableArray<ZSFMODBankFile *> *banks = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"bank"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        struct stat fileStat;
        if (stat(path.fileSystemRepresentation, &fileStat) != 0 || !S_ISREG(fileStat.st_mode)) continue;

        ZSFMODBankFile *bank = [[ZSFMODBankFile alloc] init];
        bank.fileName = name;
        bank.filePath = path;
        bank.fileSize = (unsigned long long)fileStat.st_size;
        bank.streamCount = 0;

        @autoreleasepool {
            NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
            if (data.length > 0) {
                ZSFMODFSB fsbs[64];
                uint32_t version = 0;
                int count = zsfmod_collect_fsbs(data.bytes, data.length, fsbs, 64, &version);
                NSInteger total = 0;
                for (int i = 0; i < count; i++) total += fsbs[i].numSamples;
                bank.streamCount = total;
                if (count > 0) bank.codecName = ZSFMODCodecName(fsbs[0].mode);
            }
        }
        [banks addObject:bank];
    }
    if (banks.count == 0 && error) *error = ZSFMODMakeError(@"No .bank files found.");
    return banks;
}

+ (ZSFMODBank *)openBankAtPath:(NSString *)path error:(NSError **)error {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&readError];
    if (!data) {
        if (error) *error = readError ?: ZSFMODMakeError(@"Couldn't read the bank file.");
        return nil;
    }
    const uint8_t *bytes = data.bytes;
    uint64_t size = data.length;

    ZSFMODFSB fsbs[64];
    uint32_t version = 0;
    int count = zsfmod_collect_fsbs(bytes, size, fsbs, 64, &version);
    if (count < 0) {
        if (error) *error = ZSFMODMakeError(@"Not an FMOD bank (RIFF header missing).");
        return nil;
    }

    NSMutableArray<ZSFMODStream *> *streams = [NSMutableArray array];
    NSInteger globalIndex = 0;
    for (int fsbIndex = 0; fsbIndex < count; fsbIndex++) {
        const ZSFMODFSB *fsb = &fsbs[fsbIndex];
        uint64_t cursor = fsb->base + fsb->headerSize;
        uint64_t nameTable = cursor + fsb->sampleHeaderSize;
        uint64_t dataStart = nameTable + fsb->nameTableSize;

        NSMutableArray<ZSFMODStream *> *fsbStreams = [NSMutableArray arrayWithCapacity:fsb->numSamples];
        NSMutableArray<NSNumber *> *relativeOffsets = [NSMutableArray arrayWithCapacity:fsb->numSamples];
        for (uint32_t k = 0; k < fsb->numSamples; k++) {
            ZSFMODSampleHeader header;
            if (!zsfmod_read_sample_header(bytes, size, fsb, cursor, &header)) break;
            cursor += header.headerLength;

            ZSFMODStream *stream = [[ZSFMODStream alloc] init];
            stream.index = globalIndex++;
            stream.fsbIndex = fsbIndex;
            stream.mode = fsb->mode;
            stream.codecName = ZSFMODCodecName(fsb->mode);
            stream.channels = header.channels;
            stream.frequency = header.frequency;
            stream.sampleCount = header.sampleCount;
            stream.dataOffset = dataStart + header.dataOffset;
            stream.sampleHeaderOffset = header.headerOffset;
            stream.sampleHeaderLength = header.headerLength;
            stream.fsbBase = fsb->base;
            stream.fsbHeaderSize = fsb->headerSize;
            stream.hasLoop = header.hasLoop;
            stream.loopStart = header.loopStart;
            stream.loopEnd = header.loopEnd;
            stream.hasVorbisCRC = header.hasVorbisCRC;
            stream.vorbisCRC = header.vorbisCRC;

            NSMutableArray<NSString *> *chunks = [NSMutableArray array];
            for (uint32_t c = 0; c < header.chunkCount; c++) {
                [chunks addObject:[NSString stringWithFormat:@"%@ (%u bytes)", ZSFMODChunkName(header.chunkTypes[c]), header.chunkSizes[c]]];
            }
            stream.chunkSummaries = chunks;

            NSString *name = nil;
            if ((uint64_t)(k + 1) * 4 <= fsb->nameTableSize) {
                uint64_t entry = zsfmod_u32(bytes + nameTable + (uint64_t)k * 4);
                uint64_t nameStart = nameTable + entry;
                if (nameStart < dataStart) {
                    const uint8_t *start = bytes + nameStart;
                    const uint8_t *terminator = memchr(start, 0, (size_t)(dataStart - nameStart));
                    size_t length = terminator ? (size_t)(terminator - start) : (size_t)(dataStart - nameStart);
                    if (length > 0) name = [[NSString alloc] initWithBytes:start length:length encoding:NSUTF8StringEncoding];
                }
            }
            stream.name = name.length > 0 ? name : [NSString stringWithFormat:@"stream_%ld", (long)stream.index];

            [fsbStreams addObject:stream];
            [relativeOffsets addObject:@(header.dataOffset)];
        }

        for (NSUInteger k = 0; k < fsbStreams.count; k++) {
            uint64_t start = relativeOffsets[k].unsignedLongLongValue;
            uint64_t end = fsb->dataSize;
            if (k + 1 < fsbStreams.count) {
                uint64_t next = relativeOffsets[k + 1].unsignedLongLongValue;
                if (next > start && next <= fsb->dataSize) end = next;
            }
            fsbStreams[k].dataSize = end > start ? end - start : 0;
        }
        [streams addObjectsFromArray:fsbStreams];
    }

    ZSFMODBank *bank = [[ZSFMODBank alloc] init];
    bank.filePath = path;
    bank.fileName = path.lastPathComponent;
    bank.fileSize = size;
    bank.formatVersion = version;
    bank.fsbCount = count;
    bank.streams = streams;
    bank.data = data;
    return bank;
}

+ (NSString *)detailTextForStream:(ZSFMODStream *)stream inBank:(ZSFMODBank *)bank {
    NSMutableString *text = [NSMutableString string];
    void (^line)(NSString *, NSString *) = ^(NSString *label, NSString *value) {
        [text appendFormat:@"%-14s %@\n", label.UTF8String, value];
    };
    NSTimeInterval duration = stream.duration;
    NSInteger minutes = (NSInteger)(duration / 60);
    double seconds = duration - minutes * 60;

    line(@"Name", stream.name);
    line(@"Bank", bank.fileName);
    line(@"Bank version", [NSString stringWithFormat:@"%u", bank.formatVersion]);
    line(@"Stream", [NSString stringWithFormat:@"%ld of %lu", (long)stream.index + 1, (unsigned long)bank.streams.count]);
    line(@"FSB", [NSString stringWithFormat:@"%ld of %ld", (long)stream.fsbIndex + 1, (long)bank.fsbCount]);
    line(@"Codec", stream.codecName);
    line(@"Channels", ZSFMODChannelText(stream.channels));
    line(@"Sample rate", [NSString stringWithFormat:@"%ld Hz", (long)stream.frequency]);
    line(@"Samples", [NSString stringWithFormat:@"%llu", (unsigned long long)stream.sampleCount]);
    line(@"Duration", [NSString stringWithFormat:@"%02ld:%06.3f", (long)minutes, seconds]);
    line(@"Data size", [NSString stringWithFormat:@"%llu bytes (%@)", (unsigned long long)stream.dataSize, [NSByteCountFormatter stringFromByteCount:(long long)stream.dataSize countStyle:NSByteCountFormatterCountStyleFile]]);
    if (duration > 0) {
        line(@"Bitrate", [NSString stringWithFormat:@"%.1f kbps", (double)stream.dataSize * 8.0 / duration / 1000.0]);
    }
    line(@"Data offset", [NSString stringWithFormat:@"0x%llX", (unsigned long long)stream.dataOffset]);
    line(@"Header offset", [NSString stringWithFormat:@"0x%llX", (unsigned long long)stream.sampleHeaderOffset]);
    line(@"Loop", stream.hasLoop ? [NSString stringWithFormat:@"%u - %u", stream.loopStart, stream.loopEnd] : @"none");
    if (stream.hasVorbisCRC) line(@"Vorbis CRC32", [NSString stringWithFormat:@"%08X", stream.vorbisCRC]);
    if (stream.chunkSummaries.count > 0) line(@"Extra chunks", [stream.chunkSummaries componentsJoinedByString:@", "]);
    if (stream.mode == 15) {
        [text appendString:@"\nVorbis streams in FMOD banks carry no codebook, so they can't be decoded here. Export the .fsb to open it in FMOD tools or vgmstream.\n"];
    }
    return text;
}

+ (BOOL)canExportWAVForStream:(ZSFMODStream *)stream {
    return stream.mode >= 1 && stream.mode <= 5 && stream.channels > 0 && stream.frequency > 0;
}

+ (NSString *)safeFileNameForStream:(ZSFMODStream *)stream {
    NSMutableString *name = [stream.name mutableCopy];
    for (NSString *bad in @[@"/", @"\\", @":", @"*", @"?", @"\"", @"<", @">", @"|"]) {
        [name replaceOccurrencesOfString:bad withString:@"_" options:0 range:NSMakeRange(0, name.length)];
    }
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 ? trimmed : [NSString stringWithFormat:@"stream_%ld", (long)stream.index];
}

+ (NSString *)exportStream:(ZSFMODStream *)stream inBank:(ZSFMODBank *)bank format:(ZSFMODExportFormat)format toDirectory:(NSString *)directory error:(NSError **)error {
    uint64_t size = bank.data.length;
    if (stream.dataOffset + stream.dataSize > size || stream.sampleHeaderOffset + stream.sampleHeaderLength > size) {
        if (error) *error = ZSFMODMakeError(@"Stream data lies outside the bank file.");
        return nil;
    }
    const uint8_t *bytes = bank.data.bytes;
    NSData *payload = [NSData dataWithBytes:bytes + stream.dataOffset length:(NSUInteger)stream.dataSize];
    NSMutableData *output = nil;
    NSString *extension = nil;

    if (format == ZSFMODExportFormatRaw) {
        output = [payload mutableCopy];
        extension = @"raw";
    } else if (format == ZSFMODExportFormatWAV) {
        if (![self canExportWAVForStream:stream]) {
            if (error) *error = ZSFMODMakeError([NSString stringWithFormat:@"%@ streams can't be written as WAV. Export the .fsb instead.", stream.codecName]);
            return nil;
        }
        uint16_t bits = stream.mode == 1 ? 8 : (stream.mode == 2 ? 16 : (stream.mode == 3 ? 24 : 32));
        uint16_t tag = stream.mode == 5 ? 3 : 1;
        uint32_t channels = (uint32_t)stream.channels;
        uint32_t rate = (uint32_t)stream.frequency;
        uint16_t blockAlign = (uint16_t)(channels * bits / 8);
        output = [NSMutableData dataWithCapacity:44 + payload.length];
        [output appendBytes:"RIFF" length:4];
        ZSFMODPutU32(output, (uint32_t)(36 + payload.length));
        [output appendBytes:"WAVEfmt " length:8];
        ZSFMODPutU32(output, 16);
        ZSFMODPutU16(output, tag);
        ZSFMODPutU16(output, (uint16_t)channels);
        ZSFMODPutU32(output, rate);
        ZSFMODPutU32(output, rate * blockAlign);
        ZSFMODPutU16(output, blockAlign);
        ZSFMODPutU16(output, bits);
        [output appendBytes:"data" length:4];
        ZSFMODPutU32(output, (uint32_t)payload.length);
        [output appendData:payload];
        extension = @"wav";
    } else {
        NSMutableData *header = [NSMutableData dataWithBytes:bytes + stream.fsbBase length:stream.fsbHeaderSize];
        NSMutableData *sampleHeader = [NSMutableData dataWithBytes:bytes + stream.sampleHeaderOffset length:stream.sampleHeaderLength];
        if (sampleHeader.length < 8) {
            if (error) *error = ZSFMODMakeError(@"Sample header is truncated.");
            return nil;
        }
        uint8_t *sh = sampleHeader.mutableBytes;
        uint64_t raw = zsfmod_u64(sh);
        raw &= ~(0x0FFFFFFFULL << 6);
        for (int i = 0; i < 8; i++) sh[i] = (uint8_t)((raw >> (8 * i)) & 0xFF);

        NSData *nameData = [stream.name dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSMutableData *nameTable = [NSMutableData data];
        ZSFMODPutU32(nameTable, 4);
        [nameTable appendData:nameData];
        uint8_t zero = 0;
        [nameTable appendBytes:&zero length:1];
        NSUInteger prefix = header.length + sampleHeader.length + nameTable.length;
        NSUInteger namePad = (32 - (prefix % 32)) % 32;
        if (namePad > 0) [nameTable increaseLengthBy:namePad];

        NSMutableData *paddedPayload = [payload mutableCopy];
        NSUInteger dataPad = (32 - (paddedPayload.length % 32)) % 32;
        if (dataPad > 0) [paddedPayload increaseLengthBy:dataPad];

        uint8_t *h = header.mutableBytes;
        ZSFMODWriteU32(h + 8, 1);
        ZSFMODWriteU32(h + 12, (uint32_t)sampleHeader.length);
        ZSFMODWriteU32(h + 16, (uint32_t)nameTable.length);
        ZSFMODWriteU32(h + 20, (uint32_t)paddedPayload.length);

        output = [NSMutableData dataWithCapacity:header.length + sampleHeader.length + nameTable.length + paddedPayload.length];
        [output appendData:header];
        [output appendData:sampleHeader];
        [output appendData:nameTable];
        [output appendData:paddedPayload];
        extension = @"fsb";
    }

    NSString *path = [directory stringByAppendingPathComponent:[[self safeFileNameForStream:stream] stringByAppendingPathExtension:extension]];
    NSError *writeError = nil;
    if (![output writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = writeError ?: ZSFMODMakeError(@"Couldn't write the export.");
        return nil;
    }
    return path;
}

@end
