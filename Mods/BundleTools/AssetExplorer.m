#import "AssetExplorer.h"
#import "UnityBundleTools.h"
#import <Metal/Metal.h>

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

static BOOL ZSAEOpenBundle(NSString *path, ZSAEBundle **outBundle, NSError **error) {
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
    return session;
}

static ZSAEObject *ZSAEReadObject(ZSAESession *session, int64_t pathID, NSError **error) {
    NSDictionary *fields = nil;
    int32_t classID = 0;
    NSArray<NSString *> *externals = nil;
    if (!ZSAEParseSerializedFile(session.serializedData, nil, pathID, NULL, &fields, &classID, &externals, error)) return nil;
    ZSAEObject *object = [ZSAEObject new];
    object.fields = fields;
    object.classID = classID;
    object.externals = externals ?: @[];
    object.session = session;
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

static ZSAssetExplorerVisual *ZSAEBuildSpriteVisual(ZSAEContext *context, ZSAEObject *sprite, NSError **error) {
    NSDictionary *fields = sprite.fields;
    NSDictionary *source = ZSAEDict(fields[@"m_RD"]);
    ZSAEObject *sourceOwner = sprite;

    NSDictionary *atlasPointer = ZSAEDict(fields[@"m_SpriteAtlas"]);
    id key = fields[@"m_RenderDataKey"];
    if (atlasPointer && ZSAEInt(atlasPointer[@"m_PathID"]) != 0 && key) {
        ZSAEObject *atlas = ZSAEResolvePPtr(context, sprite, atlasPointer, NULL);
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

    ZSAEObject *textureObject = ZSAEResolvePPtr(context, sourceOwner, texturePointer, error);
    if (!textureObject) return nil;
    ZSAETextureRecord *record = nil;
    NSMutableData *rgba = nil;
    if (!ZSAEDecodeTextureObject(textureObject, &record, &rgba, error)) return nil;

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

    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    visual.name = ZSAEString(fields[@"m_Name"]);
    NSString *textureName = record.name.length > 0 ? record.name : @"texture";
    visual.summary = [NSString stringWithFormat:@"Sprite  •  %dx%d  •  %@  •  %@", w, h, textureName, ZSAETextureFormatName(record.format)];
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

@implementation ZSAssetExplorerBundle
@end

@implementation ZSAssetExplorerAsset
@end

@implementation ZSAssetExplorerTexture
@end

@implementation ZSAssetExplorerVisual

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

@implementation ZSAssetExplorer

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

+ (NSArray<ZSAssetExplorerBundle *> *)cachedBundles:(NSError **)error {
    NSArray<NSString *> *roots = [self zs_sharedRoots];
    if (roots.count == 0) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSharedDirectoryNotFound, @"Library/UnityCache/Shared was not found.");
        return @[];
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, ZSAssetExplorerBundle *> *byCAB = [NSMutableDictionary dictionary];
    for (NSString *root in roots) {
        NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:root];
        NSString *relativePath = nil;
        while ((relativePath = [enumerator nextObject])) {
            @autoreleasepool {
                NSDictionary *attributes = enumerator.fileAttributes;
                if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
                NSString *fullPath = [root stringByAppendingPathComponent:relativePath];
                if (![UnityBundleCAB isUnityFSBundleAtPath:fullPath]) continue;

                NSError *cabError = nil;
                NSString *cab = [UnityBundleCAB primaryCABForBundleAtPath:fullPath error:&cabError];
                if (cab.length == 0) continue;
                ZSAssetExplorerBundle *existing = byCAB[cab];
                if (existing) {
                    NSDate *oldDate = [fm attributesOfItemAtPath:existing.filePath error:nil][NSFileModificationDate];
                    NSDate *newDate = attributes[NSFileModificationDate];
                    if (newDate && (!oldDate || [newDate compare:oldDate] == NSOrderedDescending)) existing.filePath = fullPath;
                    continue;
                }

                ZSAssetExplorerBundle *bundle = [ZSAssetExplorerBundle new];
                bundle.cabIdentifier = cab;
                NSString *identifier = [cab hasPrefix:@"CAB-"] ? [cab substringFromIndex:4] : cab;
                NSUInteger count = MIN((NSUInteger)7, identifier.length);
                NSString *shortIdentifier = count > 0 ? [identifier substringToIndex:count] : identifier;
                bundle.displayName = [NSString stringWithFormat:@"CAB-%@", shortIdentifier];
                bundle.filePath = fullPath;
                byCAB[cab] = bundle;
            }
        }
    }

    NSArray<ZSAssetExplorerBundle *> *bundles = [byCAB.allValues sortedArrayUsingComparator:^NSComparisonResult(ZSAssetExplorerBundle *a, ZSAssetExplorerBundle *b) {
        NSComparisonResult result = [a.displayName caseInsensitiveCompare:b.displayName];
        if (result != NSOrderedSame) return result;
        return [a.cabIdentifier caseInsensitiveCompare:b.cabIdentifier];
    }];

    if (bundles.count == 0 && error) *error = ZSAEError(ZSAssetExplorerErrorNoBundles, @"No UnityFS AssetBundles were found in Library/UnityCache/Shared.");
    return bundles;
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

    ZSAETextureRecord *record = nil;
    BOOL parsed = ZSAEParseSerializedFile(serializedData, nil, pathID, &record, NULL, NULL, NULL, error);
    [NSFileManager.defaultManager removeItemAtPath:serializedPath error:nil];
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

+ (BOOL)hasVisualPreviewForClassID:(int32_t)classID {
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
        case 213:
            return ZSAEBuildSpriteVisual(context, object, error);
        case 687078895:
            return ZSAEBuildAtlasVisual(context, object, error);
        case 89:
        case 117:
        case 187:
        case 188:
            return ZSAEBuildSliceVisual(object, error);
        default:
            if (error) *error = ZSAEError(ZSAssetExplorerErrorTextureUnsupported, @"This asset kind can't be previewed.");
            return nil;
    }
}

+ (NSArray<ZSAssetExplorerAsset *> *)assetsForBundleAtPath:(NSString *)path error:(NSError **)error {
    NSString *serializedPath = nil;
    NSString *cab = nil;
    if (!ZSAEParseUnityFSForSerializedPath(path, &serializedPath, &cab, error)) return @[];
    if (cab.length == 0 || serializedPath.length == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:serializedPath error:nil];
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The bundle has no valid serialized CAB identifier.");
        return @[];
    }

    NSError *mapError = nil;
    NSData *serializedData = [NSData dataWithContentsOfFile:serializedPath options:NSDataReadingMappedIfSafe error:&mapError];
    if (!serializedData) {
        [[NSFileManager defaultManager] removeItemAtPath:serializedPath error:nil];
        if (error) *error = mapError ?: ZSAEError(ZSAssetExplorerErrorBundleUnreadable, @"Couldn't map the serialized file.");
        return @[];
    }

    NSArray<ZSAssetExplorerAsset *> *assets = nil;
    BOOL ok = ZSAEParseSerializedFile(serializedData, &assets, INT64_MIN, NULL, NULL, NULL, NULL, error);
    [[NSFileManager defaultManager] removeItemAtPath:serializedPath error:nil];
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

@end
