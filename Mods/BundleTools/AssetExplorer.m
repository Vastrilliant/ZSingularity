#import "AssetExplorer.h"
#import "UnityBundleTools.h"

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
    NSString *path;
    uint64_t offset;
    uint64_t size;
    uint32_t flags;
} ZSAENode;

typedef struct {
    const uint8_t *base;
    uint64_t start;
    uint64_t limit;
    uint64_t pos;
} ZSAEReader;

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

static BOOL ZSAEParseUnityFSForSerializedPath(NSString *path, NSString **outSerializedPath, NSString **outCAB, NSError **error) {
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
    uint64_t headerEnd = cursor.pos;
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
    ZSAEBlock *blocks = calloc(blockCount ? blockCount : 1, sizeof(ZSAEBlock));
    if (!blocks) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"Couldn't allocate the UnityFS block table.");
        return NO;
    }

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
        free(blocks);
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS block table is truncated or overflows.");
        return NO;
    }

    uint32_t nodeCount = 0;
    if (!ZSAEReadU32BE(&infoCursor, &nodeCount) || nodeCount > 4096) {
        free(blocks);
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS node table is invalid.");
        return NO;
    }

    ZSAENode *nodes = calloc(nodeCount ? nodeCount : 1, sizeof(ZSAENode));
    if (!nodes) {
        free(blocks);
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"Couldn't allocate the UnityFS node table.");
        return NO;
    }

    for (uint32_t i = 0; i < nodeCount; i++) {
        uint64_t nodeOffset = 0;
        uint64_t nodeSize = 0;
        uint32_t nodeFlags = 0;
        if (!ZSAEReadU64BE(&infoCursor, &nodeOffset) ||
            !ZSAEReadU64BE(&infoCursor, &nodeSize) ||
            !ZSAEReadU32BE(&infoCursor, &nodeFlags) ||
            !ZSAEReadCString(&infoCursor, &nodes[i].path)) {
            ok = NO;
            break;
        }
        nodes[i].offset = nodeOffset;
        nodes[i].size = nodeSize;
        nodes[i].flags = nodeFlags;
        if (nodeOffset > uncompressedOffset || nodeSize > uncompressedOffset - nodeOffset) {
            ok = NO;
            break;
        }
    }
    if (!ok) {
        free(nodes);
        free(blocks);
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS node table is invalid.");
        return NO;
    }

    NSInteger cabIndex = NSNotFound;
    for (uint32_t i = 0; i < nodeCount; i++) {
        if ((nodes[i].flags & 4) != 0 && [nodes[i].path hasPrefix:@"CAB-"]) {
            cabIndex = (NSInteger)i;
            break;
        }
    }
    if (cabIndex == NSNotFound) {
        free(nodes);
        free(blocks);
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"No serialized CAB node was found in the bundle.");
        return NO;
    }

    uint64_t dataStart = infoAtEnd ? headerEnd : headerEnd + compressedInfoSize;
    if (!infoAtEnd && (flags & 0x200) != 0) dataStart = (dataStart + 15) & ~15ULL;
    if (dataStart < headerEnd || dataStart > fileData.length) {
        free(nodes);
        free(blocks);
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS data start is outside the file.");
        return NO;
    }
    uint64_t compressedOffset = dataStart;
    for (uint32_t i = 0; i < blockCount; i++) {
        blocks[i].compressedOffset = compressedOffset;
        if (UINT64_MAX - compressedOffset < blocks[i].compressedSize) {
            free(nodes);
            free(blocks);
            if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS compressed block table overflows.");
            return NO;
        }
        compressedOffset += blocks[i].compressedSize;
    }
    if (compressedOffset > fileData.length) {
        free(nodes);
        free(blocks);
        if (error) *error = ZSAEError(ZSAssetExplorerErrorBundleMalformed, @"The UnityFS data blocks run past the end of the file.");
        return NO;
    }

    NSString *serializedPath = nil;
    BOOL reconstructed = ZSAEReadFileNodeData(fileData,
                                               nodes[cabIndex].offset, nodes[cabIndex].size,
                                               blocks, blockCount,
                                               &serializedPath, error);
    NSString *cab = [nodes[cabIndex].path copy];

    free(nodes);
    free(blocks);

    if (!reconstructed || serializedPath.length == 0) return NO;
    if (outSerializedPath) *outSerializedPath = serializedPath;
    if (outCAB) *outCAB = cab;
    return YES;
}

static BOOL ZSAEParseSerializedFile(NSData *data, NSArray<ZSAssetExplorerAsset *> **outAssets, NSError **error) {
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

    NSMutableArray<ZSAssetExplorerAsset *> *assets = [NSMutableArray arrayWithCapacity:(NSUInteger)objectCount];
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

    for (int32_t i = 0; i < typeCount; i++) free(types[i].nodes);
    free(types);

    if (!parseOK) {
        if (error) *error = ZSAEError(ZSAssetExplorerErrorSerializedFileMalformed, @"The serialized object table is truncated.");
        return NO;
    }

    if (outAssets) *outAssets = [assets copy];
    return YES;
}

@implementation ZSAssetExplorerBundle
@end

@implementation ZSAssetExplorerAsset
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
    BOOL ok = ZSAEParseSerializedFile(serializedData, &assets, error);
    [[NSFileManager defaultManager] removeItemAtPath:serializedPath error:nil];
    if (!ok) return @[];
    return assets ?: @[];
}

@end
