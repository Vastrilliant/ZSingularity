#import "AssetExplorer.h"
#import "UnityBundleTools.h"
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>

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

static void ZSAETimelineCollect(ZSAEContext *context, ZSAEObject *track, NSUInteger depth, NSMutableArray<NSDictionary *> *rows, NSMutableSet<NSString *> *seen) {
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
        if (childObject && childObject.classID == 114) ZSAETimelineCollect(context, childObject, depth + 1, rows, seen);
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

static ZSAssetExplorerVisual *ZSAEBuildTimelineVisual(ZSAEContext *context, ZSAEObject *object) {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    ZSAETimelineCollect(context, object, 0, rows, seen);
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
    ZSAssetExplorerVisual *visual = [ZSAssetExplorerVisual new];
    NSString *name = ZSAEString(object.fields[@"m_Name"]);
    visual.name = name;
    visual.summary = [NSString stringWithFormat:@"%@  •  Timeline  •  %lu %@  •  %lu %@  •  %@", name.length > 0 ? name : @"Track", (unsigned long)clipCount, clipCount == 1 ? @"clip" : @"clips", (unsigned long)captured.count, captured.count == 1 ? @"track" : @"tracks", ZSAETimelineSeconds(total)];
    visual.pageLabels = @[@"Timeline"];
    visual.imageProvider = ^UIImage *(NSInteger page, NSError **providerError) {
        return ZSAERenderTimeline(captured, capturedTotal);
    };
    return visual;
}

static ZSAssetExplorerVisual *ZSAEBuildMonoBehaviourVisual(ZSAEContext *context, ZSAEObject *object, NSError **error) {
    NSDictionary *fields = object.fields;
    ZSAssetExplorerVisual *timelineVisual = ZSAEBuildTimelineVisual(context, object);
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
            return ZSAEBuildMonoBehaviourVisual(context, object, error);
        case 21:
            return ZSAEBuildMaterialVisual(context, object, error);
        case 49:
            return ZSAEBuildTextAssetVisual(object, error);
        case 128:
            return ZSAEBuildFontVisual(object, error);
        default:
            return ZSAEBuildInspectorVisual(object, error);
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
