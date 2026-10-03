#import "ZSLowRes.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <os/lock.h>
#import <os/proc.h>
#include <ctype.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <fcntl.h>
#include <math.h>
#include <errno.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <malloc/malloc.h>

#import "UnityBundleTools.h"
#import "ZTweakLog.h"
#include "lz4.h"
#include "lz4hc.h"

#define ZSLR_BLOCK_SIZE 131072u
#define ZSLR_FORMAT_ASTC_6x6 50
#define ZSLR_FORMAT_ASTC_8x8 51
#define ZSLR_FORMAT_ASTC_10x10 52
#define ZSLR_FORMAT_ASTC_12x12 53

static volatile int g_zslrQuiet = 0;
static volatile uint32_t g_zslrTargetBlock = 0;

static uint32_t zslr_block(void) {
    uint32_t block = g_zslrTargetBlock;
    return (block == 10 || block == 12) ? block : 8;
}

static int32_t zslr_target_format(void) {
    switch (zslr_block()) {
        case 10: return ZSLR_FORMAT_ASTC_10x10;
        case 12: return ZSLR_FORMAT_ASTC_12x12;
        default: return ZSLR_FORMAT_ASTC_8x8;
    }
}
#define ZSLR_LOG(label, fmt, ...) do { if (!g_zslrQuiet) ZLog(@"[LowRes] %s: " fmt, (label), ##__VA_ARGS__); } while (0)
static volatile int g_zslrVerbose = 0;
#define ZSLR_VLOG(label, fmt, ...) do { if (g_zslrVerbose && !g_zslrQuiet) ZLog(@"[LowRes] %s: " fmt, (label), ##__VA_ARGS__); } while (0)
#define ZSLR_MB(bytes) ((unsigned long long)((bytes) / (1024ull * 1024ull)))
#define ZSLR_MS(since) ((CACurrentMediaTime() - (since)) * 1000.0)
#define ZSLR_WHY(...) do { if (why && whyLen) snprintf(why, whyLen, __VA_ARGS__); } while (0)

typedef struct {
    uint32_t compressedSize;
    uint32_t uncompressedSize;
    uint16_t flags;
    uint64_t uncompressedOffset;
    uint64_t compressedOffset;
} ZSLRBlock;

typedef struct {
    char *path;
    uint64_t offset;
    uint64_t size;
    uint32_t flags;
} ZSLRNode;

typedef struct {
    const uint8_t *file;
    size_t fileSize;
    uint32_t formatVersion;
    uint32_t headerFlags;
    char *unityVersion;
    char *unityRevision;
    size_t dataStart;
    ZSLRBlock *blocks;
    uint32_t blockCount;
    ZSLRNode *nodes;
    uint32_t nodeCount;
    uint64_t totalUncompressed;
    uint8_t *cache;
    size_t cacheCapacity;
    uint32_t cacheIndex;
} ZSLRBundle;

typedef struct {
    int64_t pathId;
    uint64_t objectStart;
    uint32_t objectSize;
    uint32_t width;
    uint32_t height;
    uint32_t completeImageSize;
    int32_t format;
    int32_t mipCount;
    int32_t colorSpace;
    uint8_t readable;
    uint64_t streamOffset;
    uint32_t streamSize;
    uint32_t imageDataLength;
    uint32_t streamPathLength;
    uint64_t streamPathPosition;
    uint64_t imageDataPosition;
    uint64_t formatPosition;
    uint64_t completeSizePosition;
    uint64_t streamOffsetPosition;
    uint64_t streamSizePosition;
    char name[96];
} ZSLRTexture;

typedef struct {
    FILE *tmp;
    char *tmpPath;
    uint8_t *raw;
    uint8_t *comp;
    size_t fill;
    uint32_t *uncompressedSizes;
    uint32_t *compressedSizes;
    uint16_t *blockFlags;
    uint32_t count;
    uint32_t capacity;
    uint64_t totalUncompressed;
    uint64_t totalCompressed;
    int failed;
} ZSLRWriter;

static int zslr_bundle_open(ZSLRBundle *bundle, const uint8_t *file, size_t size, char *err, size_t errLen);
static void zslr_bundle_close(ZSLRBundle *bundle);
static int zslr_bundle_read(ZSLRBundle *bundle, uint64_t offset, size_t length, uint8_t *dst);
static int zslr_bundle_locate(const ZSLRBundle *bundle, int *serializedIndex, int *streamIndex);

static int zslr_scan_textures(const uint8_t *cab, size_t cabLength, ZSLRTexture **textures, uint32_t *count, uint32_t *parseFailures, uint64_t *tablePos, int32_t *objectCount, char *err, size_t errLen);

static uint64_t zslr_astc_size(uint32_t width, uint32_t height, uint32_t blockX, uint32_t blockY);
static void zslr_patch_texture(uint8_t *cab, const ZSLRTexture *texture, int32_t newFormat, uint32_t newSize);

static int zslr_writer_open(ZSLRWriter *writer, const char *tmpPath);
static int zslr_writer_write(ZSLRWriter *writer, const uint8_t *data, size_t length);
static int zslr_writer_zeros(ZSLRWriter *writer, uint64_t length);
static int zslr_writer_finish(ZSLRWriter *writer, const ZSLRBundle *source, const char *outPath, char *err, size_t errLen);
static void zslr_writer_abort(ZSLRWriter *writer);


typedef int (*ZSLRTaskFn)(void *ctx, uint32_t index, void *worker);

typedef struct {
    void *user;
    int (*reserve)(void *user, uint64_t workingSetBytes);
    int (*tick)(void *user);
    int (*transcode)(void *user, const uint8_t *src, size_t srcLen, uint32_t width, uint32_t height, int srgb, uint8_t **out, size_t *outLen, char *why, size_t whyLen);
    void (*progress)(void *user, uint32_t delta);
    void (*parallel)(void *user, uint32_t count, ZSLRTaskFn task, void *ctx);
    int (*acquire)(void *user, uint64_t bytes);
    void (*release)(void *user, uint64_t bytes);
    void (*unreserve)(void *user, uint64_t bytes);
} ZSLRCodec;

typedef struct {
    uint32_t minPixels;
    uint32_t maxPixels;
    uint64_t maxResultBytes;
} ZSLRPolicy;

typedef struct {
    uint32_t texturesTotal;
    uint32_t parseFailures;
    uint32_t candidates;
    uint32_t converted;
    uint32_t rejected;
    uint64_t candidateBytes;
    uint64_t originalBytes;
    uint64_t newBytes;
    uint64_t workingSetEstimate;
    int wroteOutput;
    int noStream;
    const char *stage;
    const char *outcome;
    const char *zeroReason;
} ZSLRResult;

#define ZSLR_OK 0
#define ZSLR_ERR -1
#define ZSLR_DEFERRED 2
#define ZSLR_CANCELLED 3

static int zslr_process_bundle(const char *label, const char *srcPath, const char *outPath, int scanOnly, const ZSLRCodec *codec, const ZSLRPolicy *policy, ZSLRResult *result, char *err, size_t errLen);
static int64_t zslr_available_memory(void);
static void zslr_wait_log(const char *what);
static void zslr_pool_drain(void);

static void zslr_seterr(char *err, size_t errLen, const char *fmt, ...) {
    if (!err || errLen == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errLen, fmt, ap);
    va_end(ap);
}

static uint16_t rd_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t rd_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t rd_be64(const uint8_t *p) {
    return ((uint64_t)rd_be32(p) << 32) | rd_be32(p + 4);
}

static uint32_t rd_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t rd_le64(const uint8_t *p) {
    return (uint64_t)rd_le32(p) | ((uint64_t)rd_le32(p + 4) << 32);
}

static void wr_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void wr_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static void wr_be64(uint8_t *p, uint64_t v) {
    wr_be32(p, (uint32_t)(v >> 32));
    wr_be32(p + 4, (uint32_t)v);
}

static void wr_le64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static void wr_le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static char *zslr_dup(const uint8_t *p, size_t n) {
    char *s = (char *)malloc(n + 1);
    if (!s) return NULL;
    memcpy(s, p, n);
    s[n] = 0;
    return s;
}

static int zslr_read_cstring(const uint8_t *buf, size_t size, size_t *pos, char **out) {
    size_t start = *pos;
    size_t p = start;
    while (p < size && buf[p]) p++;
    if (p >= size) return -1;
    char *s = zslr_dup(buf + start, p - start);
    if (!s) return -1;
    *out = s;
    *pos = p + 1;
    return 0;
}

static void zslr_bundle_close(ZSLRBundle *b) {
    if (!b) return;
    free(b->unityVersion);
    free(b->unityRevision);
    free(b->blocks);
    if (b->nodes) {
        for (uint32_t i = 0; i < b->nodeCount; i++) free(b->nodes[i].path);
        free(b->nodes);
    }
    free(b->cache);
    memset(b, 0, sizeof(*b));
}

static int zslr_bundle_open(ZSLRBundle *b, const uint8_t *file, size_t size, char *err, size_t errLen) {
    memset(b, 0, sizeof(*b));
    b->file = file;
    b->fileSize = size;
    b->cacheIndex = UINT32_MAX;
    uint8_t *info = NULL;

    if (size < 48 || memcmp(file, "UnityFS", 8) != 0) {
        zslr_seterr(err, errLen, "not a UnityFS bundle");
        goto fail;
    }
    size_t pos = 8;
    b->formatVersion = rd_be32(file + pos);
    pos += 4;
    if (zslr_read_cstring(file, size, &pos, &b->unityVersion) != 0 ||
        zslr_read_cstring(file, size, &pos, &b->unityRevision) != 0) {
        zslr_seterr(err, errLen, "truncated header strings");
        goto fail;
    }
    if (size - pos < 20) {
        zslr_seterr(err, errLen, "truncated header");
        goto fail;
    }
    pos += 8;
    uint32_t compInfo = rd_be32(file + pos);
    pos += 4;
    uint32_t uncompInfo = rd_be32(file + pos);
    pos += 4;
    uint32_t flags = rd_be32(file + pos);
    pos += 4;
    b->headerFlags = flags;

    if (b->formatVersion >= 7 && (pos & 15)) pos += 16 - (pos & 15);

    size_t infoStart;
    if (flags & 0x80) {
        if (compInfo > size) {
            zslr_seterr(err, errLen, "blocks info larger than file");
            goto fail;
        }
        infoStart = size - compInfo;
        b->dataStart = pos;
    } else {
        infoStart = pos;
        if (infoStart > size || compInfo > size - infoStart) {
            zslr_seterr(err, errLen, "blocks info out of range");
            goto fail;
        }
        b->dataStart = infoStart + compInfo;
    }
    if ((flags & 0x200) && (b->dataStart & 15)) b->dataStart += 16 - (b->dataStart & 15);

    uint32_t ctype = flags & 0x3F;
    info = (uint8_t *)malloc(uncompInfo ? uncompInfo : 1);
    if (!info) {
        zslr_seterr(err, errLen, "out of memory");
        goto fail;
    }
    if (ctype == 0) {
        if (compInfo < uncompInfo) {
            zslr_seterr(err, errLen, "blocks info size mismatch");
            goto fail;
        }
        memcpy(info, file + infoStart, uncompInfo);
    } else if (ctype == 2 || ctype == 3) {
        int r = LZ4_decompress_safe((const char *)(file + infoStart), (char *)info, (int)compInfo, (int)uncompInfo);
        if (r < 0 || (uint32_t)r != uncompInfo) {
            zslr_seterr(err, errLen, "blocks info decompression failed");
            goto fail;
        }
    } else {
        zslr_seterr(err, errLen, "unsupported blocks info compression %u", ctype);
        goto fail;
    }

    size_t ip = 16;
    if (uncompInfo < 24) {
        zslr_seterr(err, errLen, "blocks info too small");
        goto fail;
    }
    b->blockCount = rd_be32(info + ip);
    ip += 4;
    if ((uint64_t)b->blockCount * 10 > uncompInfo - ip) {
        zslr_seterr(err, errLen, "blocks table out of range");
        goto fail;
    }
    b->blocks = (ZSLRBlock *)calloc(b->blockCount ? b->blockCount : 1, sizeof(ZSLRBlock));
    if (!b->blocks) {
        zslr_seterr(err, errLen, "out of memory");
        goto fail;
    }
    uint64_t uOff = 0;
    uint64_t cOff = b->dataStart;
    for (uint32_t i = 0; i < b->blockCount; i++) {
        ZSLRBlock *bl = &b->blocks[i];
        bl->uncompressedSize = rd_be32(info + ip);
        bl->compressedSize = rd_be32(info + ip + 4);
        bl->flags = rd_be16(info + ip + 8);
        ip += 10;
        bl->uncompressedOffset = uOff;
        bl->compressedOffset = cOff;
        uOff += bl->uncompressedSize;
        cOff += bl->compressedSize;
        if (cOff > size) {
            zslr_seterr(err, errLen, "data block %u runs past end of file", i);
            goto fail;
        }
    }
    b->totalUncompressed = uOff;

    if (uncompInfo - ip < 4) {
        zslr_seterr(err, errLen, "node table missing");
        goto fail;
    }
    b->nodeCount = rd_be32(info + ip);
    ip += 4;
    if (b->nodeCount > 4096) {
        zslr_seterr(err, errLen, "implausible node count");
        goto fail;
    }
    b->nodes = (ZSLRNode *)calloc(b->nodeCount ? b->nodeCount : 1, sizeof(ZSLRNode));
    if (!b->nodes) {
        zslr_seterr(err, errLen, "out of memory");
        goto fail;
    }
    for (uint32_t i = 0; i < b->nodeCount; i++) {
        if (uncompInfo - ip < 21) {
            zslr_seterr(err, errLen, "node table truncated");
            goto fail;
        }
        b->nodes[i].offset = rd_be64(info + ip);
        b->nodes[i].size = rd_be64(info + ip + 8);
        b->nodes[i].flags = rd_be32(info + ip + 16);
        ip += 20;
        if (zslr_read_cstring(info, uncompInfo, &ip, &b->nodes[i].path) != 0) {
            zslr_seterr(err, errLen, "node path truncated");
            goto fail;
        }
        if (b->nodes[i].offset > b->totalUncompressed || b->nodes[i].size > b->totalUncompressed - b->nodes[i].offset) {
            zslr_seterr(err, errLen, "node %u outside data stream", i);
            goto fail;
        }
    }
    free(info);
    return 0;

fail:
    free(info);
    zslr_bundle_close(b);
    return -1;
}

static uint32_t zslr_find_block(const ZSLRBundle *b, uint64_t offset) {
    uint32_t lo = 0;
    uint32_t hi = b->blockCount;
    while (lo + 1 < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (b->blocks[mid].uncompressedOffset <= offset) lo = mid;
        else hi = mid;
    }
    return lo;
}

static int zslr_load_block(ZSLRBundle *b, uint32_t index) {
    if (b->cacheIndex == index) return 0;
    const ZSLRBlock *bl = &b->blocks[index];
    if (bl->uncompressedSize > b->cacheCapacity) {
        uint8_t *nc = (uint8_t *)realloc(b->cache, bl->uncompressedSize);
        if (!nc) return -1;
        b->cache = nc;
        b->cacheCapacity = bl->uncompressedSize;
    }
    const uint8_t *src = b->file + bl->compressedOffset;
    uint32_t type = bl->flags & 0x3F;
    if (type == 0) {
        if (bl->compressedSize < bl->uncompressedSize) return -1;
        memcpy(b->cache, src, bl->uncompressedSize);
    } else if (type == 2 || type == 3) {
        int r = LZ4_decompress_safe((const char *)src, (char *)b->cache, (int)bl->compressedSize, (int)bl->uncompressedSize);
        if (r < 0 || (uint32_t)r != bl->uncompressedSize) return -1;
    } else {
        return -1;
    }
    b->cacheIndex = index;
    return 0;
}

static int zslr_bundle_read(ZSLRBundle *b, uint64_t offset, size_t length, uint8_t *dst) {
    if (offset > b->totalUncompressed || length > b->totalUncompressed - offset) return -1;
    while (length > 0) {
        uint32_t idx = zslr_find_block(b, offset);
        const ZSLRBlock *bl = &b->blocks[idx];
        if (offset < bl->uncompressedOffset || offset >= bl->uncompressedOffset + bl->uncompressedSize) return -1;
        if (zslr_load_block(b, idx) != 0) return -1;
        size_t inBlock = (size_t)(offset - bl->uncompressedOffset);
        size_t n = bl->uncompressedSize - inBlock;
        if (n > length) n = length;
        memcpy(dst, b->cache + inBlock, n);
        dst += n;
        offset += n;
        length -= n;
    }
    return 0;
}

static int zslr_bundle_locate(const ZSLRBundle *b, int *serializedIndex, int *streamIndex) {
    int cab = -1;
    int cabCount = 0;
    *serializedIndex = -1;
    *streamIndex = -1;
    for (uint32_t i = 0; i < b->nodeCount; i++) {
        if (b->nodes[i].flags & 4) {
            cabCount++;
            if (cab < 0) cab = (int)i;
        }
    }
    if (cabCount == 0) return -1;
    if (cabCount > 1) return -2;
    size_t cabLen = strlen(b->nodes[cab].path);
    int res = -1;
    for (uint32_t i = 0; i < b->nodeCount; i++) {
        const char *p = b->nodes[i].path;
        size_t n = strlen(p);
        if (n == cabLen + 5 && strncmp(p, b->nodes[cab].path, cabLen) == 0 && strcmp(p + cabLen, ".resS") == 0) {
            res = (int)i;
            break;
        }
    }
    *serializedIndex = cab;
    *streamIndex = res;
    return res < 0 ? 1 : 0;
}

static uint64_t zslr_astc_size(uint32_t width, uint32_t height, uint32_t blockX, uint32_t blockY) {
    return (uint64_t)((width + blockX - 1) / blockX) * (uint64_t)((height + blockY - 1) / blockY) * 16u;
}

static void zslr_patch_texture(uint8_t *cab, const ZSLRTexture *t, int32_t newFormat, uint32_t newSize) {
    wr_le32(cab + t->formatPosition, (uint32_t)newFormat);
    wr_le32(cab + t->completeSizePosition, newSize);
    if (t->imageDataLength == 0) wr_le32(cab + t->streamSizePosition, newSize);
}

typedef struct {
    uint8_t level;
    uint8_t flags;
    uint32_t nameOffset;
    int32_t byteSize;
    int32_t meta;
} ZSLRNodeInfo;

typedef struct {
    ZSLRNodeInfo *nodes;
    uint32_t count;
    const uint8_t *strings;
    uint32_t stringSize;
    int active;
} ZSLRTypeTree;

typedef struct {
    const ZSLRTypeTree *tree;
    const uint8_t *buf;
    uint64_t start;
    uint64_t limit;
} ZSLRWalk;

static uint32_t zslr_subtree_end(const ZSLRTypeTree *t, uint32_t i) {
    uint32_t j = i + 1;
    while (j < t->count && t->nodes[j].level > t->nodes[i].level) j++;
    return j;
}

static uint64_t zslr_align4(const ZSLRWalk *w, uint64_t pos) {
    uint64_t rel = pos - w->start;
    rel = (rel + 3) & ~3ULL;
    return w->start + rel;
}

static int zslr_walk(const ZSLRWalk *w, uint32_t i, uint64_t *pos, int depth) {
    if (depth > 24) return -1;
    const ZSLRTypeTree *t = w->tree;
    const ZSLRNodeInfo *n = &t->nodes[i];
    uint32_t end = zslr_subtree_end(t, i);

    if (n->flags & 1) {
        if (end < i + 3) return -1;
        if (*pos > w->limit || w->limit - *pos < 4) return -1;
        uint32_t cnt = rd_le32(w->buf + *pos);
        *pos += 4;
        const ZSLRNodeInfo *d = &t->nodes[i + 2];
        uint32_t dEnd = zslr_subtree_end(t, i + 2);
        if (dEnd == i + 3 && d->byteSize > 0) {
            uint64_t bytes = (uint64_t)cnt * (uint64_t)d->byteSize;
            if (bytes > w->limit - *pos) return -1;
            *pos += bytes;
        } else {
            for (uint32_t k = 0; k < cnt; k++) {
                if (zslr_walk(w, i + 2, pos, depth + 1) < 0) return -1;
            }
        }
        if (n->meta & 0x4000) *pos = zslr_align4(w, *pos);
        if (*pos > w->limit) return -1;
        return (int)end;
    }

    if (end > i + 1) {
        uint32_t j = i + 1;
        while (j < end) {
            int next = zslr_walk(w, j, pos, depth + 1);
            if (next < 0) return -1;
            j = (uint32_t)next;
        }
        if (n->meta & 0x4000) *pos = zslr_align4(w, *pos);
        if (*pos > w->limit) return -1;
        return (int)end;
    }

    if (n->byteSize <= 0) return -1;
    if (*pos > w->limit || (uint64_t)n->byteSize > w->limit - *pos) return -1;
    *pos += (uint64_t)n->byteSize;
    if (n->meta & 0x4000) *pos = zslr_align4(w, *pos);
    if (*pos > w->limit) return -1;
    return (int)end;
}

static const char *zslr_node_name(const ZSLRTypeTree *t, uint32_t i) {
    uint32_t off = t->nodes[i].nameOffset;
    if (off & 0x80000000u) return NULL;
    if (off >= t->stringSize) return NULL;
    const uint8_t *p = t->strings + off;
    const uint8_t *e = t->strings + t->stringSize;
    const uint8_t *q = p;
    while (q < e && *q) q++;
    if (q >= e) return NULL;
    return (const char *)p;
}

static int zslr_parse_texture(const ZSLRTypeTree *t, const uint8_t *buf, uint64_t start, uint32_t size, ZSLRTexture *out) {
    ZSLRWalk w = { t, buf, start, start + size };
    memset(out, 0, sizeof(*out));
    out->objectStart = start;
    out->objectSize = size;
    if (t->count < 2 || t->nodes[0].level != 0) return -1;

    uint64_t pos = start;
    uint32_t j = 1;
    unsigned found = 0;
    int firstChild = 1;
    while (j < t->count) {
        if (t->nodes[j].level != 1) return -1;
        uint64_t at = pos;
        const char *name = zslr_node_name(t, j);
        uint32_t end = zslr_subtree_end(t, j);

        if (firstChild && t->nodes[j].byteSize == -1 && j + 1 < t->count && (t->nodes[j + 1].flags & 1)) {
            if (w.limit - at >= 4) {
                uint32_t len = rd_le32(buf + at);
                if (len <= w.limit - at - 4) {
                    size_t n = len < sizeof(out->name) - 1 ? len : sizeof(out->name) - 1;
                    memcpy(out->name, buf + at + 4, n);
                    out->name[n] = 0;
                }
            }
        }
        firstChild = 0;

        if (name) {
            if (!strcmp(name, "m_Width") && t->nodes[j].byteSize == 4 && w.limit - at >= 4) {
                out->width = rd_le32(buf + at);
                found |= 1;
            } else if (!strcmp(name, "m_Height") && t->nodes[j].byteSize == 4 && w.limit - at >= 4) {
                out->height = rd_le32(buf + at);
                found |= 2;
            } else if (!strcmp(name, "m_CompleteImageSize") && t->nodes[j].byteSize == 4 && w.limit - at >= 4) {
                out->completeImageSize = rd_le32(buf + at);
                out->completeSizePosition = at;
                found |= 4;
            } else if (!strcmp(name, "m_TextureFormat") && t->nodes[j].byteSize == 4 && w.limit - at >= 4) {
                out->format = (int32_t)rd_le32(buf + at);
                out->formatPosition = at;
                found |= 8;
            } else if (!strcmp(name, "m_MipCount") && t->nodes[j].byteSize == 4 && w.limit - at >= 4) {
                out->mipCount = (int32_t)rd_le32(buf + at);
                found |= 16;
            } else if (!strcmp(name, "m_IsReadable") && t->nodes[j].byteSize == 1 && w.limit - at >= 1) {
                out->readable = buf[at];
                found |= 32;
            } else if (!strcmp(name, "m_ColorSpace") && t->nodes[j].byteSize == 4 && w.limit - at >= 4) {
                out->colorSpace = (int32_t)rd_le32(buf + at);
                found |= 64;
            } else if (!strcmp(name, "image data") && w.limit - at >= 4) {
                out->imageDataLength = rd_le32(buf + at);
                out->imageDataPosition = at;
                found |= 128;
            } else if (!strcmp(name, "m_StreamData")) {
                if (end != j + 7 && end < j + 4) return -1;
                if (t->nodes[j + 1].byteSize != 8 || zslr_subtree_end(t, j + 1) != j + 2) return -1;
                if (t->nodes[j + 2].byteSize != 4 || zslr_subtree_end(t, j + 2) != j + 3) return -1;
                if (w.limit - at < 16) return -1;
                out->streamOffset = rd_le64(buf + at);
                out->streamOffsetPosition = at;
                out->streamSize = rd_le32(buf + at + 8);
                out->streamSizePosition = at + 8;
                out->streamPathLength = rd_le32(buf + at + 12);
                out->streamPathPosition = at + 16;
                found |= 256;
            }
        }

        int next = zslr_walk(&w, j, &pos, 0);
        if (next < 0) return -1;
        j = (uint32_t)next;
    }
    if (pos != w.limit) return -1;
    if (found != 511u) return -1;
    return 0;
}

static int zslr_scan_textures(const uint8_t *buf, size_t len, ZSLRTexture **outTextures, uint32_t *outCount, uint32_t *outFailures, uint64_t *outTablePos, int32_t *outObjectCount, char *err, size_t errLen) {
    ZSLRTypeTree *trees = NULL;
    int32_t *classIds = NULL;
    ZSLRTexture *textures = NULL;
    int32_t typeCount = 0;
    uint32_t count = 0;
    uint32_t capacity = 0;
    uint32_t failures = 0;
    int result = -1;

    *outTextures = NULL;
    *outCount = 0;
    if (outFailures) *outFailures = 0;
    if (outTablePos) *outTablePos = 0;
    if (outObjectCount) *outObjectCount = 0;

    if (len < 64) {
        zslr_seterr(err, errLen, "serialized file too small");
        return -1;
    }
    uint32_t version = rd_be32(buf + 8);
    if (version < 22) {
        zslr_seterr(err, errLen, "unsupported serialized file version %u", version);
        return -1;
    }
    if (buf[16] != 0) {
        zslr_seterr(err, errLen, "big-endian serialized file not supported");
        return -1;
    }
    uint64_t dataOffset = rd_be64(buf + 32);
    if (dataOffset > len) {
        zslr_seterr(err, errLen, "data offset out of range");
        return -1;
    }

    size_t pos = 48;
    char *unityVersion = NULL;
    if (zslr_read_cstring(buf, len, &pos, &unityVersion) != 0) {
        zslr_seterr(err, errLen, "metadata truncated");
        return -1;
    }
    free(unityVersion);
    if (len - pos < 9) {
        zslr_seterr(err, errLen, "metadata truncated");
        return -1;
    }
    pos += 4;
    uint8_t enableTypeTree = buf[pos];
    pos += 1;
    if (!enableTypeTree) {
        zslr_seterr(err, errLen, "serialized file has no type trees");
        return -1;
    }
    typeCount = (int32_t)rd_le32(buf + pos);
    pos += 4;
    if (typeCount < 0 || typeCount > 4096) {
        zslr_seterr(err, errLen, "implausible type count");
        return -1;
    }

    trees = (ZSLRTypeTree *)calloc((size_t)typeCount + 1, sizeof(ZSLRTypeTree));
    classIds = (int32_t *)calloc((size_t)typeCount + 1, sizeof(int32_t));
    if (!trees || !classIds) {
        zslr_seterr(err, errLen, "out of memory");
        goto done;
    }

    for (int32_t ti = 0; ti < typeCount; ti++) {
        if (len - pos < 7) goto truncated;
        int32_t classId = (int32_t)rd_le32(buf + pos);
        classIds[ti] = classId;
        pos += 4;
        pos += 1;
        pos += 2;
        if (classId == 114) {
            if (len - pos < 16) goto truncated;
            pos += 16;
        }
        if (len - pos < 16) goto truncated;
        pos += 16;
        if (len - pos < 8) goto truncated;
        uint32_t nodeCount = rd_le32(buf + pos);
        uint32_t stringSize = rd_le32(buf + pos + 4);
        pos += 8;
        if (nodeCount > 100000 || stringSize > (16u << 20)) {
            zslr_seterr(err, errLen, "implausible type tree size");
            goto done;
        }
        uint64_t nodeBytes = (uint64_t)nodeCount * 32u;
        if (nodeBytes > len - pos || stringSize > len - pos - nodeBytes) goto truncated;
        if (classId == 28) {
            ZSLRTypeTree *tt = &trees[ti];
            tt->nodes = (ZSLRNodeInfo *)calloc(nodeCount ? nodeCount : 1, sizeof(ZSLRNodeInfo));
            if (!tt->nodes) {
                zslr_seterr(err, errLen, "out of memory");
                goto done;
            }
            for (uint32_t k = 0; k < nodeCount; k++) {
                const uint8_t *np = buf + pos + (size_t)k * 32u;
                tt->nodes[k].level = np[2];
                tt->nodes[k].flags = np[3];
                tt->nodes[k].nameOffset = rd_le32(np + 8);
                tt->nodes[k].byteSize = (int32_t)rd_le32(np + 12);
                tt->nodes[k].meta = (int32_t)rd_le32(np + 20);
            }
            tt->count = nodeCount;
            tt->strings = buf + pos + nodeBytes;
            tt->stringSize = stringSize;
            tt->active = 1;
        }
        pos += (size_t)nodeBytes + stringSize;
        if (len - pos < 4) goto truncated;
        int32_t deps = (int32_t)rd_le32(buf + pos);
        pos += 4;
        if (deps < 0 || (uint64_t)deps * 4u > len - pos) goto truncated;
        pos += (size_t)deps * 4u;
    }

    if (len - pos < 4) goto truncated;
    int32_t objectCount = (int32_t)rd_le32(buf + pos);
    pos += 4;
    if (objectCount < 0 || objectCount > 4000000) {
        zslr_seterr(err, errLen, "implausible object count");
        goto done;
    }
    if (outTablePos) *outTablePos = (pos + 3) & ~(size_t)3;
    if (outObjectCount) *outObjectCount = objectCount;

    for (int32_t oi = 0; oi < objectCount; oi++) {
        pos = (pos + 3) & ~(size_t)3;
        if (len - pos < 24) goto truncated;
        int64_t pathId = (int64_t)rd_le64(buf + pos);
        uint64_t byteStart = rd_le64(buf + pos + 8);
        uint32_t byteSize = rd_le32(buf + pos + 16);
        int32_t typeIdx = (int32_t)rd_le32(buf + pos + 20);
        pos += 24;
        if (typeIdx < 0 || typeIdx >= typeCount) continue;
        if (!trees[typeIdx].active) continue;
        uint64_t start = dataOffset + byteStart;
        if (start > len || byteSize > len - start) {
            failures++;
            continue;
        }
        if (count == capacity) {
            uint32_t nc = capacity ? capacity * 2 : 256;
            ZSLRTexture *nt = (ZSLRTexture *)realloc(textures, (size_t)nc * sizeof(ZSLRTexture));
            if (!nt) {
                zslr_seterr(err, errLen, "out of memory");
                goto done;
            }
            textures = nt;
            capacity = nc;
        }
        if (zslr_parse_texture(&trees[typeIdx], buf, start, byteSize, &textures[count]) != 0) {
            failures++;
            continue;
        }
        textures[count].pathId = pathId;
        count++;
    }

    *outTextures = textures;
    *outCount = count;
    if (outFailures) *outFailures = failures;
    textures = NULL;
    result = 0;
    goto done;

truncated:
    zslr_seterr(err, errLen, "serialized metadata truncated");

done:
    if (trees) {
        for (int32_t i = 0; i < typeCount; i++) free(trees[i].nodes);
        free(trees);
    }
    free(classIds);
    free(textures);
    return result;
}

static int zslr_writer_open(ZSLRWriter *w, const char *tmpPath) {
    memset(w, 0, sizeof(*w));
    w->tmpPath = zslr_dup((const uint8_t *)tmpPath, strlen(tmpPath));
    w->raw = (uint8_t *)malloc(ZSLR_BLOCK_SIZE);
    w->comp = (uint8_t *)malloc((size_t)LZ4_compressBound((int)ZSLR_BLOCK_SIZE));
    if (!w->tmpPath || !w->raw || !w->comp) {
        zslr_writer_abort(w);
        return -1;
    }
    w->tmp = fopen(tmpPath, "wb");
    if (!w->tmp) {
        zslr_writer_abort(w);
        return -1;
    }
    return 0;
}

static void zslr_writer_abort(ZSLRWriter *w) {
    if (w->tmp) fclose(w->tmp);
    if (w->tmpPath) {
        unlink(w->tmpPath);
        free(w->tmpPath);
    }
    free(w->raw);
    free(w->comp);
    free(w->uncompressedSizes);
    free(w->compressedSizes);
    free(w->blockFlags);
    memset(w, 0, sizeof(*w));
    w->failed = 1;
}

static int zslr_flush_block(ZSLRWriter *w, size_t n) {
    if (n == 0) return 0;
    if (w->count == w->capacity) {
        uint32_t nc = w->capacity ? w->capacity * 2 : 256;
        uint32_t *us = (uint32_t *)realloc(w->uncompressedSizes, (size_t)nc * sizeof(uint32_t));
        if (!us) return -1;
        w->uncompressedSizes = us;
        uint32_t *cs = (uint32_t *)realloc(w->compressedSizes, (size_t)nc * sizeof(uint32_t));
        if (!cs) return -1;
        w->compressedSizes = cs;
        uint16_t *fl = (uint16_t *)realloc(w->blockFlags, (size_t)nc * sizeof(uint16_t));
        if (!fl) return -1;
        w->blockFlags = fl;
        w->capacity = nc;
    }
    int c = LZ4_compress_fast((const char *)w->raw, (char *)w->comp, (int)n, (int)n - 1, 32);
    const uint8_t *out;
    size_t outLen;
    uint16_t flags;
    if (c > 0) {
        out = w->comp;
        outLen = (size_t)c;
        flags = 3;
    } else {
        out = w->raw;
        outLen = n;
        flags = 0;
    }
    if (fwrite(out, 1, outLen, w->tmp) != outLen) return -1;
    w->uncompressedSizes[w->count] = (uint32_t)n;
    w->compressedSizes[w->count] = (uint32_t)outLen;
    w->blockFlags[w->count] = flags;
    w->count++;
    w->totalUncompressed += n;
    w->totalCompressed += outLen;
    return 0;
}

static int zslr_writer_write(ZSLRWriter *w, const uint8_t *data, size_t length) {
    if (w->failed) return -1;
    while (length > 0) {
        size_t room = ZSLR_BLOCK_SIZE - w->fill;
        size_t n = length < room ? length : room;
        memcpy(w->raw + w->fill, data, n);
        w->fill += n;
        data += n;
        length -= n;
        if (w->fill == ZSLR_BLOCK_SIZE) {
            if (zslr_flush_block(w, ZSLR_BLOCK_SIZE) != 0) {
                w->failed = 1;
                return -1;
            }
            w->fill = 0;
        }
    }
    return 0;
}

static int zslr_writer_zeros(ZSLRWriter *w, uint64_t length) {
    static const uint8_t zeros[65536] = {0};
    while (length > 0) {
        size_t n = length < sizeof(zeros) ? (size_t)length : sizeof(zeros);
        if (zslr_writer_write(w, zeros, n) != 0) return -1;
        length -= n;
    }
    return 0;
}

static int zslr_writer_finish(ZSLRWriter *w, const ZSLRBundle *src, const char *outPath, char *err, size_t errLen) {
    FILE *out = NULL;
    FILE *in = NULL;
    uint8_t *info = NULL;
    uint8_t *cinfo = NULL;
    uint8_t *copy = NULL;
    int rc = -1;

    if (w->failed) {
        zslr_seterr(err, errLen, "writer failed");
        goto done;
    }
    if (zslr_flush_block(w, w->fill) != 0) {
        zslr_seterr(err, errLen, "flush failed");
        goto done;
    }
    w->fill = 0;
    if (fclose(w->tmp) != 0) {
        w->tmp = NULL;
        zslr_seterr(err, errLen, "temp close failed");
        goto done;
    }
    w->tmp = NULL;
    if (w->totalUncompressed != src->totalUncompressed) {
        zslr_seterr(err, errLen, "stream size mismatch (%llu vs %llu)",
                    (unsigned long long)w->totalUncompressed, (unsigned long long)src->totalUncompressed);
        goto done;
    }
    if (src->formatVersion < 7) {
        zslr_seterr(err, errLen, "unsupported bundle format version %u", src->formatVersion);
        goto done;
    }

    size_t infoLen = 16 + 4 + (size_t)w->count * 10 + 4;
    for (uint32_t i = 0; i < src->nodeCount; i++) infoLen += 20 + strlen(src->nodes[i].path) + 1;
    info = (uint8_t *)calloc(infoLen, 1);
    if (!info) goto done;
    size_t ip = 16;
    wr_be32(info + ip, w->count);
    ip += 4;
    for (uint32_t i = 0; i < w->count; i++) {
        wr_be32(info + ip, w->uncompressedSizes[i]);
        wr_be32(info + ip + 4, w->compressedSizes[i]);
        wr_be16(info + ip + 8, w->blockFlags[i]);
        ip += 10;
    }
    wr_be32(info + ip, src->nodeCount);
    ip += 4;
    for (uint32_t i = 0; i < src->nodeCount; i++) {
        wr_be64(info + ip, src->nodes[i].offset);
        wr_be64(info + ip + 8, src->nodes[i].size);
        wr_be32(info + ip + 16, src->nodes[i].flags);
        ip += 20;
        size_t pl = strlen(src->nodes[i].path);
        memcpy(info + ip, src->nodes[i].path, pl + 1);
        ip += pl + 1;
    }

    int bound = LZ4_compressBound((int)infoLen);
    cinfo = (uint8_t *)malloc((size_t)bound);
    if (!cinfo) goto done;
    int cinfoLen = LZ4_compress_default((const char *)info, (char *)cinfo, (int)infoLen, bound);
    if (cinfoLen <= 0) {
        zslr_seterr(err, errLen, "blocks info compression failed");
        goto done;
    }

    size_t uvLen = strlen(src->unityVersion) + 1;
    size_t urLen = strlen(src->unityRevision) + 1;
    size_t headerLen = 8 + 4 + uvLen + urLen + 8 + 4 + 4 + 4;
    size_t headerPad = (16 - (headerLen & 15)) & 15;
    size_t infoPad = (16 - ((headerLen + headerPad + (size_t)cinfoLen) & 15)) & 15;
    uint64_t total = (uint64_t)headerLen + headerPad + (uint64_t)cinfoLen + infoPad + w->totalCompressed;

    uint8_t *head = (uint8_t *)calloc(headerLen + headerPad, 1);
    if (!head) goto done;
    size_t hp = 0;
    memcpy(head + hp, "UnityFS", 8);
    hp += 8;
    wr_be32(head + hp, src->formatVersion);
    hp += 4;
    memcpy(head + hp, src->unityVersion, uvLen);
    hp += uvLen;
    memcpy(head + hp, src->unityRevision, urLen);
    hp += urLen;
    wr_be64(head + hp, total);
    hp += 8;
    wr_be32(head + hp, (uint32_t)cinfoLen);
    hp += 4;
    wr_be32(head + hp, (uint32_t)infoLen);
    hp += 4;
    wr_be32(head + hp, 0x40u | 0x200u | 3u);
    hp += 4;

    out = fopen(outPath, "wb");
    if (!out) {
        free(head);
        zslr_seterr(err, errLen, "cannot create %s", outPath);
        goto done;
    }
    int ok = fwrite(head, 1, headerLen + headerPad, out) == headerLen + headerPad;
    free(head);
    static const uint8_t pad[16] = {0};
    ok = ok && fwrite(cinfo, 1, (size_t)cinfoLen, out) == (size_t)cinfoLen;
    ok = ok && fwrite(pad, 1, infoPad, out) == infoPad;
    if (!ok) {
        zslr_seterr(err, errLen, "write failed");
        goto done;
    }

    in = fopen(w->tmpPath, "rb");
    copy = (uint8_t *)malloc(1u << 20);
    if (!in || !copy) {
        zslr_seterr(err, errLen, "cannot reopen temp");
        goto done;
    }
    size_t n;
    uint64_t copied = 0;
    while ((n = fread(copy, 1, 1u << 20, in)) > 0) {
        if (fwrite(copy, 1, n, out) != n) {
            zslr_seterr(err, errLen, "write failed");
            goto done;
        }
        copied += n;
    }
    if (copied != w->totalCompressed) {
        zslr_seterr(err, errLen, "temp size mismatch");
        goto done;
    }
    if (fclose(out) != 0) {
        out = NULL;
        zslr_seterr(err, errLen, "close failed");
        goto done;
    }
    out = NULL;
    rc = 0;

done:
    if (out) {
        fclose(out);
        if (rc != 0) unlink(outPath);
    }
    if (in) fclose(in);
    free(info);
    free(cinfo);
    free(copy);
    if (w->tmp) {
        fclose(w->tmp);
        w->tmp = NULL;
    }
    if (w->tmpPath) {
        unlink(w->tmpPath);
        free(w->tmpPath);
        w->tmpPath = NULL;
    }
    free(w->raw);
    free(w->comp);
    free(w->uncompressedSizes);
    free(w->compressedSizes);
    free(w->blockFlags);
    w->raw = NULL;
    w->comp = NULL;
    w->uncompressedSizes = NULL;
    w->compressedSizes = NULL;
    w->blockFlags = NULL;
    return rc;
}


#define ZSLR_COPY_CHUNK (256u * 1024u)
#define ZSLR_MAX_CAB_BYTES (96u * 1024u * 1024u)

typedef struct {
    uint32_t texture;
    uint64_t spillOffset;
    size_t length;
    uint32_t newSize;
} ZSLRConverted;

typedef struct {
    uint64_t absolute;
    uint64_t originalLength;
    const uint8_t *data;
    size_t dataLength;
    uint64_t spillOffset;
    int spilled;
} ZSLRRegion;

static void pl_err(char *err, size_t errLen, const char *fmt, ...) {
    if (!err || errLen == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errLen, fmt, ap);
    va_end(ap);
}

static int pl_name_blocked(const char *name) {
    char low[96];
    size_t n = strlen(name);
    if (n >= sizeof(low)) n = sizeof(low) - 1;
    for (size_t i = 0; i < n; i++) low[i] = (char)tolower((unsigned char)name[i]);
    low[n] = 0;
    if (strstr(low, "normal") || strstr(low, "bump")) return 1;
    static const char *suffixes[] = { "_n", "_nrm", "_norm", "_nm", "_rg", "_nor" };
    for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); i++) {
        size_t sl = strlen(suffixes[i]);
        if (n >= sl && strcmp(low + n - sl, suffixes[i]) == 0) return 1;
    }
    return 0;
}

static int pl_cmp_candidates(const void *a, const void *b) {
    const ZSLRTexture *x = *(const ZSLRTexture *const *)a;
    const ZSLRTexture *y = *(const ZSLRTexture *const *)b;
    if (x->streamOffset < y->streamOffset) return -1;
    if (x->streamOffset > y->streamOffset) return 1;
    return 0;
}

static int pl_cmp_regions(const void *a, const void *b) {
    const ZSLRRegion *x = (const ZSLRRegion *)a;
    const ZSLRRegion *y = (const ZSLRRegion *)b;
    if (x->absolute < y->absolute) return -1;
    if (x->absolute > y->absolute) return 1;
    return 0;
}

static int zslr_pwrite_all(int fd, const uint8_t *p, size_t n, uint64_t off, int *errOut) {
    while (n > 0) {
        ssize_t w = pwrite(fd, p, n, (off_t)off);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errOut) *errOut = errno;
            return -1;
        }
        if (w == 0) {
            if (errOut) *errOut = EIO;
            return -1;
        }
        p += w;
        n -= (size_t)w;
        off += (uint64_t)w;
    }
    return 0;
}

static int zslr_pread_all(int fd, uint8_t *p, size_t n, uint64_t off) {
    while (n > 0) {
        ssize_t r = pread(fd, p, n, (off_t)off);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return -1;
        p += r;
        n -= (size_t)r;
        off += (uint64_t)r;
    }
    return 0;
}

static int pl_write_region(ZSLRWriter *w, const ZSLRRegion *r, int spillFd, uint8_t *chunk) {
    if (!r->spilled) return zslr_writer_write(w, r->data, r->dataLength);
    uint64_t done = 0;
    while (done < r->dataLength) {
        uint64_t left = r->dataLength - done;
        size_t n = (size_t)(left < ZSLR_COPY_CHUNK ? left : ZSLR_COPY_CHUNK);
        if (zslr_pread_all(spillFd, chunk, n, r->spillOffset + done) != 0) return -1;
        if (zslr_writer_write(w, chunk, n) != 0) return -1;
        done += n;
    }
    return 0;
}

static uint32_t zslr_src_len(const ZSLRTexture *t) {
    return t->imageDataLength ? t->imageDataLength : t->streamSize;
}

static uint64_t zslr_texture_need(const ZSLRTexture *t) {
    uint64_t ns = zslr_astc_size(t->width, t->height, zslr_block(), zslr_block());
    return (uint64_t)zslr_src_len(t) * 2u + ns * 2u;
}

static int pl_path_matches(const uint8_t *cab, size_t cabLen, const ZSLRTexture *t, const char *nodeName) {
    size_t nl = strlen(nodeName);
    if (t->streamPathLength < nl || t->streamPathLength > 512) return 0;
    if (t->streamPathPosition > cabLen || t->streamPathLength > cabLen - t->streamPathPosition) return 0;
    const uint8_t *p = cab + t->streamPathPosition;
    if (memcmp(p + t->streamPathLength - nl, nodeName, nl) != 0) return 0;
    if (t->streamPathLength == nl) return 1;
    return p[t->streamPathLength - nl - 1] == '/';
}

static int pl_copy_range(ZSLRBundle *b, ZSLRWriter *w, uint64_t from, uint64_t to, uint8_t *chunk) {
    while (from < to) {
        size_t n = (size_t)((to - from) < ZSLR_COPY_CHUNK ? (to - from) : ZSLR_COPY_CHUNK);
        if (zslr_bundle_read(b, from, n, chunk) != 0) return -1;
        if (zslr_writer_write(w, chunk, n) != 0) return -1;
        from += n;
    }
    return 0;
}

static int pl_verify(const char *outPath, const ZSLRConverted *conv, uint32_t convCount, const ZSLRTexture *textures, char *err, size_t errLen) {
    int fd = open(outPath, O_RDONLY);
    if (fd < 0) {
        pl_err(err, errLen, "verify: cannot reopen output");
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        pl_err(err, errLen, "verify: bad output size");
        return -1;
    }
    void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) {
        pl_err(err, errLen, "verify: mmap failed");
        return -1;
    }
    ZSLRBundle b;
    ZSLRTexture *tex = NULL;
    uint8_t *cab = NULL;
    uint32_t count = 0;
    int si, ri;
    int rc = -1;
    if (zslr_bundle_open(&b, (const uint8_t *)map, (size_t)st.st_size, err, errLen) != 0) {
        munmap(map, (size_t)st.st_size);
        return -1;
    }
    if (zslr_bundle_locate(&b, &si, &ri) < 0) {
        pl_err(err, errLen, "verify: nodes missing");
        goto done;
    }
    cab = (uint8_t *)malloc((size_t)b.nodes[si].size);
    if (!cab || zslr_bundle_read(&b, b.nodes[si].offset, (size_t)b.nodes[si].size, cab) != 0) {
        pl_err(err, errLen, "verify: cab read failed");
        goto done;
    }
    if (zslr_scan_textures(cab, (size_t)b.nodes[si].size, &tex, &count, NULL, NULL, NULL, err, errLen) != 0) goto done;
    for (uint32_t i = 0; i < convCount; i++) {
        const ZSLRTexture *orig = &textures[conv[i].texture];
        const ZSLRTexture *found = NULL;
        for (uint32_t k = 0; k < count; k++) {
            if (tex[k].pathId == orig->pathId) {
                found = &tex[k];
                break;
            }
        }
        int inlineOk = orig->imageDataLength ? (found && found->imageDataLength == conv[i].newSize && found->streamSize == 0)
                                             : (found && found->streamSize == conv[i].newSize && found->streamOffset == orig->streamOffset);
        if (!found || !inlineOk || found->format != zslr_target_format() ||
            found->completeImageSize != conv[i].newSize ||
            found->width != orig->width || found->height != orig->height) {
            pl_err(err, errLen, "verify: texture %lld mismatch", (long long)orig->pathId);
            goto done;
        }
    }
    rc = 0;
done:
    free(tex);
    free(cab);
    zslr_bundle_close(&b);
    munmap(map, (size_t)st.st_size);
    return rc;
}

#define ZSLR_OUT_NONE 0
#define ZSLR_OUT_SKIPPED 1
#define ZSLR_OUT_OK 2
#define ZSLR_OUT_REJECTED 3
#define ZSLR_ABORT_CANCEL 1
#define ZSLR_ABORT_READ 2
#define ZSLR_ABORT_DEFER 3
#define ZSLR_ABORT_SPILL 4

typedef struct {
    const ZSLRCodec *codec;
    ZSLRBundle *bundle;
    os_unfair_lock readLock;
    uint64_t streamBase;
    const uint8_t *cab;
    size_t cabLen;
    const ZSLRTexture *textures;
    const ZSLRTexture **cands;
    ZSLRConverted *conv;
    uint8_t *outcome;
    uint32_t candCount;
    const char *label;
    atomic_int abort;
    uint32_t failedIndex;
    int spillFd;
    int spillErrno;
    _Atomic uint64_t spillNext;
} ZSLRTranscodeCtx;

static int zslr_transcode_texture(ZSLRTranscodeCtx *c, uint32_t i, void *worker) {
    const ZSLRCodec *codec = c->codec;
    const char *label = c->label;
    uint32_t candCount = c->candCount;
    const ZSLRTexture *t = c->cands[i];
    uint32_t srcLen = zslr_src_len(t);
    uint8_t *srcBuf = (uint8_t *)malloc(srcLen);
    int readOk = 0;
    if (srcBuf) {
        if (t->imageDataLength) {
            memcpy(srcBuf, c->cab + t->imageDataPosition + 4, srcLen);
            readOk = 1;
        } else {
            os_unfair_lock_lock(&c->readLock);
            readOk = zslr_bundle_read(c->bundle, c->streamBase + t->streamOffset, srcLen, srcBuf) == 0;
            os_unfair_lock_unlock(&c->readLock);
        }
    }
    if (!readOk) {
        free(srcBuf);
        int expected = 0;
        if (atomic_compare_exchange_strong(&c->abort, &expected, ZSLR_ABORT_READ)) c->failedIndex = i;
        return 1;
    }
    uint32_t newSize = (uint32_t)zslr_astc_size(t->width, t->height, zslr_block(), zslr_block());
    uint8_t *out = NULL;
    size_t outLen = 0;
    char why[160] = {0};
    const char *texName = t->name[0] ? t->name : "<unnamed>";
    double texStart = CACurrentMediaTime();
    int tr = codec->transcode(worker, srcBuf, srcLen, t->width, t->height, t->colorSpace == 1, &out, &outLen, why, sizeof(why));
    free(srcBuf);
    if (tr == 0 && out && outLen != newSize) {
        snprintf(why, sizeof(why), "output size %zu, expected %u", outLen, newSize);
        tr = -1;
    }
    if (tr != 0 || !out) {
        free(out);
        c->outcome[i] = ZSLR_OUT_REJECTED;
        ZSLR_LOG(label, "texture %u/%u %s (path %lld, %ux%u): failed, %s (%.0f ms)", i + 1, candCount, texName, (long long)t->pathId,
                 t->width, t->height, why[0] ? why : "unknown transcode error", ZSLR_MS(texStart));
        if (codec->progress) codec->progress(codec->user, 1);
        return 0;
    }
    uint64_t at = atomic_fetch_add(&c->spillNext, (uint64_t)outLen);
    int spillErr = 0;
    if (zslr_pwrite_all(c->spillFd, out, outLen, at, &spillErr) != 0) {
        free(out);
        int expected = 0;
        if (atomic_compare_exchange_strong(&c->abort, &expected, ZSLR_ABORT_SPILL)) {
            c->failedIndex = i;
            c->spillErrno = spillErr;
        }
        return 1;
    }
    free(out);
    c->conv[i].texture = (uint32_t)(t - c->textures);
    c->conv[i].spillOffset = at;
    c->conv[i].length = outLen;
    c->conv[i].newSize = newSize;
    c->outcome[i] = ZSLR_OUT_OK;
    ZSLR_VLOG(label, "texture %u/%u %s (path %lld, %ux%u, %u -> %u bytes): converted, %s (%.0f ms)", i + 1, candCount, texName, (long long)t->pathId,
             t->width, t->height, srcLen, newSize, why, ZSLR_MS(texStart));
    if (codec->progress) codec->progress(codec->user, 1);
    return 0;
}

static int zslr_transcode_task(void *opaque, uint32_t i, void *worker) {
    ZSLRTranscodeCtx *c = (ZSLRTranscodeCtx *)opaque;
    const ZSLRCodec *codec = c->codec;
    if (c->outcome[i] == ZSLR_OUT_SKIPPED || atomic_load(&c->abort) != 0) return 0;
    if (codec->tick && codec->tick(codec->user) != 0) {
        int expected = 0;
        atomic_compare_exchange_strong(&c->abort, &expected, ZSLR_ABORT_CANCEL);
        return 1;
    }
    uint64_t need = 0;
    int acquired = 0;
    if (codec->acquire) {
        need = zslr_texture_need(c->cands[i]);
        int ar = codec->acquire(codec->user, need);
        if (ar != 0) {
            int expected = 0;
            atomic_compare_exchange_strong(&c->abort, &expected, ar == 2 ? ZSLR_ABORT_CANCEL : ZSLR_ABORT_DEFER);
            return 1;
        }
        acquired = 1;
    }
    int r = zslr_transcode_texture(c, i, worker);
    if (acquired && codec->release) codec->release(codec->user, need);
    return r;
}

typedef struct {
    uint64_t start;
    uint32_t size;
    uint32_t index;
} ZSLRObjSpan;

static int pl_cmp_spans(const void *a, const void *b) {
    const ZSLRObjSpan *x = (const ZSLRObjSpan *)a;
    const ZSLRObjSpan *y = (const ZSLRObjSpan *)b;
    if (x->start < y->start) return -1;
    if (x->start > y->start) return 1;
    return 0;
}

static int zslr_rebuild_cab(const uint8_t *cab, size_t cabLen, uint64_t tablePos, int32_t objectCount, const ZSLRTexture *textures, const ZSLRConverted *conv, uint32_t convCount, int spillFd, uint8_t *out, char *err, size_t errLen) {
    int rc = -1;
    ZSLRObjSpan *spans = NULL;
    int32_t *convFor = NULL;
    if (objectCount <= 0 || cabLen < 48) {
        pl_err(err, errLen, "rebuild: no object table");
        return -1;
    }
    uint64_t dataOffset = rd_be64(cab + 32);
    uint64_t tableEnd = tablePos + (uint64_t)objectCount * 24u;
    if (dataOffset > cabLen || tableEnd > dataOffset) {
        pl_err(err, errLen, "rebuild: object table outside metadata");
        return -1;
    }
    spans = (ZSLRObjSpan *)calloc((size_t)objectCount, sizeof(*spans));
    convFor = (int32_t *)malloc((size_t)objectCount * sizeof(int32_t));
    if (!spans || !convFor) {
        pl_err(err, errLen, "rebuild: out of memory");
        goto done;
    }
    for (int32_t i = 0; i < objectCount; i++) {
        const uint8_t *e = cab + tablePos + (uint64_t)i * 24u;
        uint64_t rel = rd_le64(e + 8);
        uint32_t size = rd_le32(e + 16);
        if (rel > cabLen - dataOffset || size > cabLen - dataOffset - rel) {
            pl_err(err, errLen, "rebuild: object %d outside data region", i);
            goto done;
        }
        spans[i].start = rel;
        spans[i].size = size;
        spans[i].index = (uint32_t)i;
        convFor[i] = -1;
    }
    qsort(spans, (size_t)objectCount, sizeof(*spans), pl_cmp_spans);
    for (int32_t i = 1; i < objectCount; i++) {
        if (spans[i].start < spans[i - 1].start + spans[i - 1].size) {
            pl_err(err, errLen, "rebuild: overlapping objects");
            goto done;
        }
    }
    for (uint32_t k = 0; k < convCount; k++) {
        const ZSLRTexture *t = &textures[conv[k].texture];
        if (!t->imageDataLength) continue;
        uint64_t rel = t->objectStart - dataOffset;
        int32_t lo = 0, hi = objectCount - 1, hit = -1;
        while (lo <= hi) {
            int32_t mid = lo + (hi - lo) / 2;
            if (spans[mid].start == rel) { hit = mid; break; }
            if (spans[mid].start < rel) lo = mid + 1;
            else hi = mid - 1;
        }
        if (hit < 0) {
            pl_err(err, errLen, "rebuild: texture %lld has no object entry", (long long)t->pathId);
            goto done;
        }
        convFor[hit] = (int32_t)k;
    }

    memcpy(out, cab, (size_t)dataOffset);
    uint64_t firstRel = spans[0].start;
    memcpy(out + dataOffset, cab + dataOffset, (size_t)firstRel);
    uint64_t cursor = dataOffset + firstRel;
    uint64_t lastEnd = dataOffset + firstRel;
    for (int32_t i = 0; i < objectCount; i++) {
        uint64_t relCursor = cursor - dataOffset;
        relCursor = (relCursor + 7) & ~7ULL;
        if (i == 0) relCursor = firstRel;
        cursor = dataOffset + relCursor;
        uint64_t newRel = relCursor;
        uint32_t newSize = spans[i].size;
        const uint8_t *src = cab + dataOffset + spans[i].start;
        if (cursor + spans[i].size > cabLen) {
            pl_err(err, errLen, "rebuild: object %u does not fit", spans[i].index);
            goto done;
        }
        if (convFor[i] < 0) {
            memcpy(out + cursor, src, spans[i].size);
        } else {
            const ZSLRConverted *cv = &conv[convFor[i]];
            const ZSLRTexture *t = &textures[cv->texture];
            uint64_t lenRel = t->imageDataPosition - t->objectStart;
            uint64_t oldDataEnd = lenRel + 4u + t->imageDataLength;
            uint64_t oldTail = (oldDataEnd + 3) & ~3ULL;
            if (oldDataEnd > spans[i].size || oldTail > spans[i].size) {
                pl_err(err, errLen, "rebuild: texture %lld image data outside object", (long long)t->pathId);
                goto done;
            }
            uint64_t newDataEnd = lenRel + 4u + cv->length;
            uint64_t newTail = (newDataEnd + 3) & ~3ULL;
            uint64_t tailLen = spans[i].size - oldTail;
            newSize = (uint32_t)(newTail + tailLen);
            if (cursor + newSize > cabLen) {
                pl_err(err, errLen, "rebuild: texture %lld object grew", (long long)t->pathId);
                goto done;
            }
            memcpy(out + cursor, src, (size_t)lenRel);
            wr_le32(out + cursor + lenRel, (uint32_t)cv->length);
            if (zslr_pread_all(spillFd, out + cursor + lenRel + 4u, cv->length, cv->spillOffset) != 0) {
                pl_err(err, errLen, "rebuild: cannot read converted texture %lld from scratch", (long long)t->pathId);
                goto done;
            }
            memcpy(out + cursor + newTail, src + oldTail, (size_t)tailLen);
        }
        uint8_t *e = out + tablePos + (uint64_t)spans[i].index * 24u;
        wr_le64(e + 8, newRel);
        wr_le32(e + 16, newSize);
        cursor += newSize;
        lastEnd = cursor;
    }
    uint64_t origLastEnd = dataOffset + spans[objectCount - 1].start + spans[objectCount - 1].size;
    if (origLastEnd < cabLen) {
        uint64_t tail = cabLen - origLastEnd;
        if (lastEnd + tail > cabLen) {
            tail = cabLen - lastEnd;
        }
        memcpy(out + lastEnd, cab + origLastEnd, (size_t)tail);
    }
    rc = 0;
done:
    free(spans);
    free(convFor);
    return rc;
}

static int zslr_process_bundle(const char *label, const char *srcPath, const char *outPath, int scanOnly, const ZSLRCodec *codec, const ZSLRPolicy *policy, ZSLRResult *result, char *err, size_t errLen) {
    memset(result, 0, sizeof(*result));
    result->stage = "open";
    result->outcome = "not evaluated";
    int fd = open(srcPath, O_RDONLY);
    if (fd < 0) {
        pl_err(err, errLen, "cannot open source (errno %d: %s)", errno, strerror(errno));
        return ZSLR_ERR;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        pl_err(err, errLen, "fstat failed (errno %d: %s)", errno, strerror(errno));
        close(fd);
        return ZSLR_ERR;
    }
    if (st.st_size < 64) {
        pl_err(err, errLen, "source too small (%lld bytes)", (long long)st.st_size);
        close(fd);
        return ZSLR_ERR;
    }
    size_t fileSize = (size_t)st.st_size;
    void *map = mmap(NULL, fileSize, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) {
        pl_err(err, errLen, "mmap failed for %zu bytes (errno %d: %s)", fileSize, errno, strerror(errno));
        return ZSLR_ERR;
    }
    ZSLR_VLOG(label, "mapped %llu bytes, parsing container", (unsigned long long)fileSize);

    int rc = ZSLR_ERR;
    ZSLRBundle b;
    int bundleOpen = 0;
    uint8_t *cab = NULL;
    ZSLRTexture *textures = NULL;
    const ZSLRTexture **cands = NULL;
    const ZSLRTexture **inl = NULL;
    uint8_t *newCab = NULL;
    uint64_t tablePos = 0;
    int32_t objectCount = 0;
    ZSLRConverted *conv = NULL;
    ZSLRRegion *regions = NULL;
    uint8_t *chunk = NULL;
    uint8_t *outcome = NULL;
    int spillFd = -1;
    uint64_t reserved = 0;
    ZSLRWriter writer;
    int writerOpen = 0;
    uint32_t texCount = 0;
    uint32_t candCount = 0;
    uint32_t convCount = 0;
    char tmpPath[1024];
    int si = -1;
    int ri = -1;
    double stageStart = CACurrentMediaTime();

    result->stage = "container";
    if (zslr_bundle_open(&b, (const uint8_t *)map, fileSize, err, errLen) != 0) goto done;
    bundleOpen = 1;
    ZSLR_VLOG(label, "container ok: format v%u, unity %s, header flags 0x%x, %u block(s), %u node(s), %llu bytes uncompressed (%.0f ms)",
             b.formatVersion, b.unityVersion, b.headerFlags, b.blockCount, b.nodeCount, (unsigned long long)b.totalUncompressed, ZSLR_MS(stageStart));
    for (uint32_t i = 0; i < b.nodeCount && i < 8; i++) {
        ZSLR_VLOG(label, "node %u: %s, %llu bytes, flags 0x%x", i, b.nodes[i].path, (unsigned long long)b.nodes[i].size, b.nodes[i].flags);
    }
    if (b.nodeCount > 8) ZSLR_VLOG(label, "%u more node(s) not listed", b.nodeCount - 8);

    result->stage = "locate nodes";
    int loc = zslr_bundle_locate(&b, &si, &ri);
    if (loc == -1) {
        pl_err(err, errLen, "no serialized node among %u node(s)", b.nodeCount);
        goto done;
    }
    if (loc == -2) {
        uint32_t serializedNodes = 0;
        for (uint32_t i = 0; i < b.nodeCount; i++) {
            if (b.nodes[i].flags & 4) serializedNodes++;
        }
        pl_err(err, errLen, "%u serialized nodes among %u node(s), multi-file bundles are not supported", serializedNodes, b.nodeCount);
        goto done;
    }
    if (loc == 1) {
        ZSLR_VLOG(label, "serialized node %s has no .resS sibling", b.nodes[si].path);
    } else {
        ZSLR_VLOG(label, "node pair: serialized %s (%llu bytes), stream %s (%llu bytes)", b.nodes[si].path, (unsigned long long)b.nodes[si].size,
                 b.nodes[ri].path, (unsigned long long)b.nodes[ri].size);
    }

    result->stage = "read serialized node";
    if (b.nodes[si].size > ZSLR_MAX_CAB_BYTES || b.nodes[si].size < 64) {
        pl_err(err, errLen, "serialized node size %llu bytes outside allowed range 64..%u", (unsigned long long)b.nodes[si].size, ZSLR_MAX_CAB_BYTES);
        goto done;
    }
    size_t cabLen = (size_t)b.nodes[si].size;
    uint64_t maxBlock = 0;
    for (uint32_t i = 0; i < b.blockCount; i++) {
        if (b.blocks[i].uncompressedSize > maxBlock) maxBlock = b.blocks[i].uncompressedSize;
    }
    result->workingSetEstimate = 2u * (uint64_t)cabLen + maxBlock + 2u * ZSLR_COPY_CHUNK + 2u * ZSLR_BLOCK_SIZE;
    if (!scanOnly && codec->reserve) {
        result->stage = "reserve memory";
        double reserveStart = CACurrentMediaTime();
        ZSLR_VLOG(label, "reserving %llu MB working set (available %lld MB)", ZSLR_MB(result->workingSetEstimate), (long long)(zslr_available_memory() / (1024 * 1024)));
        int rr = codec->reserve(codec->user, result->workingSetEstimate);
        if (rr == 2) {
            ZSLR_LOG(label, "reserve aborted: cancelled after %.1fs", ZSLR_MS(reserveStart) / 1000.0);
            rc = ZSLR_CANCELLED;
            goto done;
        }
        if (rr != 0) {
            ZSLR_LOG(label, "reserve timed out after %.1fs (available %lld MB)", ZSLR_MS(reserveStart) / 1000.0, (long long)(zslr_available_memory() / (1024 * 1024)));
            rc = ZSLR_DEFERRED;
            goto done;
        }
        reserved = result->workingSetEstimate;
        ZSLR_VLOG(label, "reserve granted after %.1fs", ZSLR_MS(reserveStart) / 1000.0);
        result->stage = "read serialized node";
    }
    stageStart = CACurrentMediaTime();
    cab = (uint8_t *)malloc(cabLen);
    if (!cab) {
        pl_err(err, errLen, "out of memory allocating %zu bytes for serialized node", cabLen);
        goto done;
    }
    if (zslr_bundle_read(&b, b.nodes[si].offset, cabLen, cab) != 0) {
        pl_err(err, errLen, "cannot decompress serialized node (offset %llu, %zu bytes)", (unsigned long long)b.nodes[si].offset, cabLen);
        goto done;
    }
    ZSLR_VLOG(label, "serialized node read: %zu bytes (%.0f ms)", cabLen, ZSLR_MS(stageStart));
    if (reserved && codec->unreserve) {
        codec->unreserve(codec->user, reserved);
        reserved = 0;
    }

    result->stage = "scan textures";
    stageStart = CACurrentMediaTime();
    if (zslr_scan_textures(cab, cabLen, &textures, &texCount, &result->parseFailures, &tablePos, &objectCount, err, errLen) != 0) goto done;
    result->texturesTotal = texCount;
    ZSLR_VLOG(label, "scan: %u Texture2D parsed, %u parse failure(s) (%.0f ms)", texCount, result->parseFailures, ZSLR_MS(stageStart));

    result->stage = "select candidates";
    cands = (const ZSLRTexture **)malloc(((size_t)texCount + 1) * sizeof(*cands));
    inl = (const ZSLRTexture **)malloc(((size_t)texCount + 1) * sizeof(*inl));
    if (!cands || !inl) {
        pl_err(err, errLen, "out of memory");
        goto done;
    }
    uint64_t resSize = ri >= 0 ? b.nodes[ri].size : 0;
    const char *resName = ri >= 0 ? b.nodes[ri].path : "";
    uint32_t inlCount = 0;
    uint32_t fFormat = 0, fMips = 0, fDims = 0, fPixels = 0, fSize = 0, fRange = 0, fName = 0, fPath = 0, fOverlap = 0;
    for (uint32_t i = 0; i < texCount; i++) {
        const ZSLRTexture *t = &textures[i];
        if (t->format != ZSLR_FORMAT_ASTC_6x6) { fFormat++; continue; }
        if (t->mipCount != 1) { fMips++; continue; }
        if (t->width == 0 || t->height == 0) { fDims++; continue; }
        uint64_t pixels = (uint64_t)t->width * t->height;
        if (pixels < policy->minPixels || pixels > policy->maxPixels) { fPixels++; continue; }
        uint64_t expected = zslr_astc_size(t->width, t->height, 6, 6);
        if (t->imageDataLength != 0) {
            if (t->streamSize != 0 || t->imageDataLength != expected || t->completeImageSize != expected) { fSize++; continue; }
            if (t->imageDataPosition < t->objectStart || t->imageDataPosition + 4u + t->imageDataLength > t->objectStart + t->objectSize) { fRange++; continue; }
            if (t->name[0] && pl_name_blocked(t->name)) { fName++; continue; }
            inl[inlCount++] = t;
            continue;
        }
        if (ri < 0) { fRange++; continue; }
        if (t->streamSize != expected || t->completeImageSize != expected) { fSize++; continue; }
        if (t->streamOffset > resSize || t->streamSize > resSize - t->streamOffset) { fRange++; continue; }
        if (t->name[0] && pl_name_blocked(t->name)) { fName++; continue; }
        if (!pl_path_matches(cab, cabLen, t, resName)) { fPath++; continue; }
        cands[candCount++] = t;
    }
    qsort(cands, candCount, sizeof(*cands), pl_cmp_candidates);
    uint32_t kept = 0;
    uint64_t lastEnd = 0;
    for (uint32_t i = 0; i < candCount; i++) {
        if (cands[i]->streamOffset < lastEnd) { fOverlap++; continue; }
        lastEnd = cands[i]->streamOffset + cands[i]->streamSize;
        cands[kept++] = cands[i];
    }
    candCount = kept;
    for (uint32_t i = 0; i < inlCount; i++) cands[candCount++] = inl[i];
    result->candidates = candCount;
    if (candCount == 0) {
        const char *names[] = { "not ASTC 6x6", "mip count not 1", "zero dimensions", "outside pixel limits", "size mismatch", "stream range invalid", "name filter", "stream path mismatch", "overlapping stream" };
        uint32_t counts[] = { fFormat, fMips, fDims, fPixels, fSize, fRange, fName, fPath, fOverlap };
        uint32_t best = 0;
        for (uint32_t i = 1; i < 9; i++) {
            if (counts[i] > counts[best]) best = i;
        }
        result->zeroReason = texCount == 0 ? "no Texture2D objects" : names[best];
    }
    ZSLR_VLOG(label, "candidates: %u of %u Texture2D (skipped: format %u, mips %u, dims %u, pixel limits %u, size mismatch %u, stream range %u, name filter %u, path mismatch %u, overlap %u; %u inline)",
             candCount, texCount, fFormat, fMips, fDims, fPixels, fSize, fRange, fName, fPath, fOverlap, inlCount);
    if (loc == 1 && candCount == 0) {
        result->noStream = 1;
        result->outcome = "no .resS node";
        rc = ZSLR_OK;
        goto done;
    }

    uint64_t peakTexture = 0;
    uint64_t projected = 0;
    for (uint32_t i = 0; i < candCount; i++) {
        const ZSLRTexture *t = cands[i];
        uint64_t need = zslr_texture_need(t);
        if (need > peakTexture) peakTexture = need;
        result->candidateBytes += zslr_src_len(t);
        projected += zslr_astc_size(t->width, t->height, zslr_block(), zslr_block());
    }
    if (candCount > 0) {
        ZSLR_VLOG(label, "projected: %llu -> %llu bytes at %ux%u, peak per-texture working set %llu MB, bundle base %llu MB", (unsigned long long)result->candidateBytes,
                 (unsigned long long)projected, zslr_block(), zslr_block(), ZSLR_MB(peakTexture), ZSLR_MB(result->workingSetEstimate));
    }

    if (scanOnly) {
        result->newBytes = projected;
        result->originalBytes = result->candidateBytes;
        result->outcome = candCount ? "scanned" : "no candidates";
        rc = ZSLR_OK;
        goto done;
    }
    if (candCount == 0) {
        result->outcome = "no candidates";
        rc = ZSLR_OK;
        goto done;
    }

    conv = (ZSLRConverted *)calloc(candCount, sizeof(*conv));
    outcome = (uint8_t *)calloc(candCount, 1);
    if (!conv || !outcome) {
        pl_err(err, errLen, "out of memory");
        goto done;
    }
    result->stage = "transcode";
    stageStart = CACurrentMediaTime();
    uint32_t capSkipped = 0;
    uint64_t planned = 0;
    for (uint32_t i = 0; i < candCount; i++) {
        const ZSLRTexture *t = cands[i];
        uint32_t newSize = (uint32_t)zslr_astc_size(t->width, t->height, zslr_block(), zslr_block());
        if (planned + newSize > policy->maxResultBytes) {
            outcome[i] = ZSLR_OUT_SKIPPED;
            capSkipped++;
            if (codec->progress) codec->progress(codec->user, 1);
            continue;
        }
        planned += newSize;
    }
    char spillPath[1100];
    snprintf(spillPath, sizeof(spillPath), "%s.spill", outPath);
    spillFd = open(spillPath, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (spillFd < 0) {
        pl_err(err, errLen, "cannot open spill file %s (errno %d: %s)", spillPath, errno, strerror(errno));
        goto done;
    }
    unlink(spillPath);
    ZSLRTranscodeCtx tctx;
    memset(&tctx, 0, sizeof(tctx));
    tctx.spillFd = spillFd;
    atomic_init(&tctx.spillNext, 0);
    tctx.codec = codec;
    tctx.bundle = &b;
    tctx.readLock = OS_UNFAIR_LOCK_INIT;
    tctx.streamBase = ri >= 0 ? b.nodes[ri].offset : 0;
    tctx.cab = cab;
    tctx.cabLen = cabLen;
    tctx.textures = textures;
    tctx.cands = cands;
    tctx.conv = conv;
    tctx.outcome = outcome;
    tctx.candCount = candCount;
    tctx.label = label;
    atomic_init(&tctx.abort, 0);
    if (codec->parallel) {
        codec->parallel(codec->user, candCount, zslr_transcode_task, &tctx);
    } else {
        for (uint32_t i = 0; i < candCount; i++) zslr_transcode_task(&tctx, i, codec->user);
    }
    int abortState = atomic_load(&tctx.abort);
    if (abortState == ZSLR_ABORT_CANCEL) {
        ZSLR_LOG(label, "cancelled during transcode of %u texture(s)", candCount);
        rc = ZSLR_CANCELLED;
        goto done;
    }
    if (abortState == ZSLR_ABORT_DEFER) {
        ZSLR_LOG(label, "deferred during transcode: not enough memory headroom");
        rc = ZSLR_DEFERRED;
        goto done;
    }
    if (abortState == ZSLR_ABORT_SPILL) {
        const ZSLRTexture *bad = cands[tctx.failedIndex];
        pl_err(err, errLen, "cannot write converted texture %lld to scratch (errno %d: %s)", (long long)bad->pathId, tctx.spillErrno, strerror(tctx.spillErrno));
        goto done;
    }
    if (abortState == ZSLR_ABORT_READ) {
        const ZSLRTexture *bad = cands[tctx.failedIndex];
        pl_err(err, errLen, "cannot read stream of texture %lld (offset %llu, %u bytes)", (long long)bad->pathId, (unsigned long long)bad->streamOffset, bad->streamSize);
        goto done;
    }
    for (uint32_t i = 0; i < candCount; i++) {
        if (outcome[i] == ZSLR_OUT_REJECTED) {
            result->rejected++;
            continue;
        }
        if (outcome[i] != ZSLR_OUT_OK) continue;
        result->originalBytes += zslr_src_len(cands[i]);
        result->newBytes += conv[i].newSize;
        if (i != convCount) {
            conv[convCount] = conv[i];
            memset(&conv[i], 0, sizeof(conv[i]));
        }
        convCount++;
    }
    if (capSkipped) {
        ZSLR_LOG(label, "result cap of %llu MB reached, %u texture(s) left unconverted", ZSLR_MB(policy->maxResultBytes), capSkipped);
    }
    result->converted = convCount;
    ZSLR_VLOG(label, "transcode pass done: %u converted, %u failed (%.1fs)", convCount, result->rejected, ZSLR_MS(stageStart) / 1000.0);
    if (convCount == 0) {
        result->outcome = "all candidates failed";
        rc = ZSLR_OK;
        goto done;
    }

    result->stage = "patch serialized node";
    for (uint32_t i = 0; i < convCount; i++) {
        zslr_patch_texture(cab, &textures[conv[i].texture], zslr_target_format(), conv[i].newSize);
    }

    result->stage = "plan rewrite";
    regions = (ZSLRRegion *)calloc((size_t)convCount + 1, sizeof(*regions));
    chunk = (uint8_t *)malloc(ZSLR_COPY_CHUNK);
    if (!regions || !chunk) {
        pl_err(err, errLen, "out of memory");
        goto done;
    }
    uint32_t rcount = 0;
    regions[rcount].absolute = b.nodes[si].offset;
    regions[rcount].originalLength = cabLen;
    regions[rcount].data = cab;
    regions[rcount].dataLength = cabLen;
    rcount++;
    uint32_t inlineConverted = 0;
    for (uint32_t i = 0; i < convCount; i++) {
        const ZSLRTexture *t = &textures[conv[i].texture];
        if (t->imageDataLength != 0) {
            inlineConverted++;
            continue;
        }
        regions[rcount].absolute = b.nodes[ri].offset + t->streamOffset;
        regions[rcount].originalLength = t->streamSize;
        regions[rcount].data = NULL;
        regions[rcount].dataLength = conv[i].length;
        regions[rcount].spilled = 1;
        regions[rcount].spillOffset = conv[i].spillOffset;
        rcount++;
    }
    if (inlineConverted > 0) {
        newCab = (uint8_t *)calloc(cabLen, 1);
        if (!newCab) {
            pl_err(err, errLen, "out of memory rebuilding serialized node");
            goto done;
        }
        if (zslr_rebuild_cab(cab, cabLen, tablePos, objectCount, textures, conv, convCount, spillFd, newCab, err, errLen) != 0) goto done;
        regions[0].data = newCab;
    }
    qsort(regions, rcount, sizeof(*regions), pl_cmp_regions);

    result->stage = "rewrite bundle";
    stageStart = CACurrentMediaTime();
    snprintf(tmpPath, sizeof(tmpPath), "%s.scratch", outPath);
    if (zslr_writer_open(&writer, tmpPath) != 0) {
        pl_err(err, errLen, "cannot open scratch file %s (errno %d: %s)", tmpPath, errno, strerror(errno));
        goto done;
    }
    writerOpen = 1;
    ZSLR_VLOG(label, "rewriting %llu bytes of stream with %u replaced region(s)", (unsigned long long)b.totalUncompressed, rcount);
    uint64_t cursor = 0;
    for (uint32_t i = 0; i < rcount; i++) {
        if (regions[i].absolute < cursor) {
            pl_err(err, errLen, "overlapping regions at %llu (cursor %llu)", (unsigned long long)regions[i].absolute, (unsigned long long)cursor);
            goto done;
        }
        if (pl_copy_range(&b, &writer, cursor, regions[i].absolute, chunk) != 0) {
            pl_err(err, errLen, "gap copy failed between %llu and %llu", (unsigned long long)cursor, (unsigned long long)regions[i].absolute);
            goto done;
        }
        if (pl_write_region(&writer, &regions[i], spillFd, chunk) != 0 ||
            zslr_writer_zeros(&writer, regions[i].originalLength - regions[i].dataLength) != 0) {
            pl_err(err, errLen, "region write failed at %llu", (unsigned long long)regions[i].absolute);
            goto done;
        }
        cursor = regions[i].absolute + regions[i].originalLength;
    }
    if (pl_copy_range(&b, &writer, cursor, b.totalUncompressed, chunk) != 0) {
        pl_err(err, errLen, "tail copy failed from %llu", (unsigned long long)cursor);
        goto done;
    }
    ZSLR_VLOG(label, "stream rewritten (%.1fs), finalizing container", ZSLR_MS(stageStart) / 1000.0);
    result->stage = "finalize container";
    stageStart = CACurrentMediaTime();
    rc = zslr_writer_finish(&writer, &b, outPath, err, errLen);
    writerOpen = 0;
    if (rc != 0) {
        rc = ZSLR_ERR;
        goto done;
    }
    ZSLR_VLOG(label, "container finalized (%.1fs), verifying", ZSLR_MS(stageStart) / 1000.0);
    result->stage = "verify";
    stageStart = CACurrentMediaTime();
    if (pl_verify(outPath, conv, convCount, textures, err, errLen) != 0) {
        unlink(outPath);
        rc = ZSLR_ERR;
        goto done;
    }
    ZSLR_VLOG(label, "verified %u converted texture(s) (%.1fs)", convCount, ZSLR_MS(stageStart) / 1000.0);
    result->wroteOutput = 1;
    result->outcome = "written";
    rc = ZSLR_OK;

done:
    if (writerOpen) zslr_writer_abort(&writer);
    if (spillFd >= 0) close(spillFd);
    if (reserved && codec->unreserve) codec->unreserve(codec->user, reserved);
    free(conv);
    free(regions);
    free(chunk);
    free(outcome);
    free(cands);
    free(inl);
    free(newCab);
    free(textures);
    free(cab);
    if (bundleOpen) zslr_bundle_close(&b);
    munmap(map, fileSize);
    return rc;
}

#pragma mark - Objective-C layer

static const uint32_t kZSLowResMinPixels = 256u * 256u;
static const uint32_t kZSLowResMaxPixels = 4096u * 4096u;
static const uint64_t kZSLowResMaxResultBytes = UINT64_MAX;
static const int64_t kZSLowResFullSpeedAbove = 300ll * 1024 * 1024;
static const int64_t kZSLowResHalfSpeedAbove = 200ll * 1024 * 1024;
static const int64_t kZSLowResPauseBelow = 110ll * 1024 * 1024;
static const int64_t kZSLowResResumeAbove = 150ll * 1024 * 1024;
static const int64_t kZSLowResSlowLaneMin = 72ll * 1024 * 1024;
static const int64_t kZSLowResReserveBytes = 96ll * 1024 * 1024;
static const int64_t kZSLowResTextureFloor = 64ll * 1024 * 1024;
static const NSTimeInterval kZSLowResMemoryWaitLimit = 30.0;
static const NSTimeInterval kZSLowResTextureWaitLimit = 40.0;
static const NSTimeInterval kZSLowResStallLimit = 45.0;
static const NSTimeInterval kZSLowResGiveUpLimit = 240.0;
static const NSUInteger kZSLowResMaxRetries = 2;
static const NSTimeInterval kZSLowResWarningPause = 8.0;
#define ZSLR_MAX_WORKERS 8
static const NSUInteger kZSLowResMaxWorkers = ZSLR_MAX_WORKERS;

typedef struct {
    NSUInteger index;
} ZSLRWorker;

typedef struct {
    ZSLRTaskFn task;
    void *ctx;
    uint32_t count;
    atomic_uint next;
    atomic_uint finished;
    atomic_int helpers;
} ZSLRJob;

static os_unfair_lock g_zslrLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_zslrJobLock = OS_UNFAIR_LOCK_INIT;
static ZSLRJob *g_zslrJobs[ZSLR_MAX_WORKERS];
static ZSLowResStatus g_zslrStatus;
static volatile BOOL g_zslrCancel = NO;
static double g_zslrWarningUntil = 0;
static BOOL g_zslrHoldPaused = NO;
static NSUInteger g_zslrMaxWorkers = 1;
static int g_zslrLastState = -1;
static double g_zslrLastWaitLog = 0;
static double g_zslrLastProgressLog = 0;
static _Atomic uint64_t g_zslrGpuBusyNs;
static _Atomic uint64_t g_zslrGpuBlocks;
static volatile uint32_t g_zslrChunkBlocks = 16384u;
static NSUInteger g_zslrNoStream = 0;
static NSMutableArray<NSDictionary *> *g_zslrItems;
static _Atomic uint64_t g_zslrBundleReserved;
static _Atomic uint64_t g_zslrTextureInflight;
static double g_zslrPausedSince = 0;
static BOOL g_zslrGaveUp = NO;
static NSMutableDictionary<NSString *, NSNumber *> *g_zslrRetries;
static NSUInteger g_zslrNextItem = 0;
static NSMutableDictionary<NSString *, NSDictionary *> *g_zslrLedger;
static NSUInteger g_zslrLedgerDirty = 0;
static os_unfair_lock g_zslrCountLock = OS_UNFAIR_LOCK_INIT;
static const NSInteger kZSLRScanCacheVersion = 4;
static double g_zslrTranscodeStart = 0;
static BOOL g_zslrWorkerActive[ZSLR_MAX_WORKERS];
static NSUInteger g_zslrWorkerSeq[ZSLR_MAX_WORKERS];
static NSUInteger g_zslrWorkerTotal[ZSLR_MAX_WORKERS];
static NSUInteger g_zslrWorkerDone[ZSLR_MAX_WORKERS];
static BOOL g_zslrPreparing = NO;
static NSArray<NSDictionary *> *g_zslrPrepared;
static NSUInteger g_zslrPreparedTextures = 0;
static NSMutableArray *g_zslrPrepareWaiters;

static int64_t zslr_available_memory(void) {
    if (@available(iOS 13.0, *)) return (int64_t)os_proc_available_memory();
    return 0;
}

static NSUInteger zslr_allowed_workers(void) {
    double now = CACurrentMediaTime();
    int64_t avail = zslr_available_memory();
    int state;
    BOOL gaveUp = NO;
    os_unfair_lock_lock(&g_zslrLock);
    NSUInteger allowed;
    if (now < g_zslrWarningUntil) {
        allowed = 0;
        state = 4;
    } else if (avail <= 0) {
        allowed = g_zslrMaxWorkers;
        state = 5;
    } else if ((g_zslrHoldPaused && avail < kZSLowResResumeAbove) || avail < kZSLowResPauseBelow) {
        g_zslrHoldPaused = YES;
        allowed = 0;
        state = 3;
    } else {
        g_zslrHoldPaused = NO;
        if (avail >= kZSLowResFullSpeedAbove) {
            allowed = g_zslrMaxWorkers;
            state = 0;
        } else if (avail >= kZSLowResHalfSpeedAbove) {
            allowed = MAX((NSUInteger)1, g_zslrMaxWorkers / 2);
            state = 1;
        } else {
            allowed = 1;
            state = 2;
        }
    }
    if (state == 3) {
        if (g_zslrPausedSince == 0) g_zslrPausedSince = now;
        double stalled = now - g_zslrPausedSince;
        if (stalled >= kZSLowResStallLimit && avail >= kZSLowResSlowLaneMin) {
            allowed = 1;
            state = 6;
        } else if (stalled >= kZSLowResGiveUpLimit && !g_zslrCancel) {
            g_zslrGaveUp = YES;
            g_zslrCancel = YES;
            gaveUp = YES;
        }
    } else if (state != 4) {
        g_zslrPausedSince = 0;
    }
    g_zslrStatus.allowedWorkers = allowed;
    g_zslrStatus.paused = (allowed == 0);
    BOOL changed = (state != g_zslrLastState);
    g_zslrLastState = state;
    NSUInteger maxWorkers = g_zslrMaxWorkers;
    os_unfair_lock_unlock(&g_zslrLock);
    if (changed) {
        static const char *names[] = { "full speed", "half speed", "single worker", "paused: low memory", "paused: memory warning cooldown", "memory reading unavailable", "single worker: low memory for too long" };
        ZLog(@"[LowRes] throttle: %s, %lu/%lu worker(s) allowed, available %lld MB", names[state], (unsigned long)allowed, (unsigned long)maxWorkers,
             (long long)(avail / (1024 * 1024)));
        if (state == 3) {
            zslr_pool_drain();
            malloc_zone_pressure_relief(NULL, 0);
        }
    }
    if (gaveUp) {
        ZLog(@"[LowRes] stopping: available memory stayed below %lld MB for %.0fs (now %lld MB), progress is saved", (long long)(kZSLowResSlowLaneMin / (1024 * 1024)),
             kZSLowResGiveUpLimit, (long long)(avail / (1024 * 1024)));
    }
    return allowed;
}

static void zslr_wait_log(const char *what) {
    double now = CACurrentMediaTime();
    os_unfair_lock_lock(&g_zslrLock);
    BOOL due = (now - g_zslrLastWaitLog) >= 5.0;
    if (due) g_zslrLastWaitLog = now;
    NSUInteger allowed = g_zslrStatus.allowedWorkers;
    os_unfair_lock_unlock(&g_zslrLock);
    if (due) {
        ZLog(@"[LowRes] waiting: %s (allowed %lu, available %lld MB)", what, (unsigned long)allowed, (long long)(zslr_available_memory() / (1024 * 1024)));
    }
}

static int zslr_codec_tick(void *user) {
    (void)user;
    return g_zslrCancel ? 1 : 0;
}

static int zslr_codec_reserve(void *user, uint64_t need) {
    (void)user;
    double deadline = CACurrentMediaTime() + kZSLowResMemoryWaitLimit;
    double nextRelief = 0;
    while (!g_zslrCancel) {
        int64_t avail = zslr_available_memory();
        if (zslr_allowed_workers() > 0) {
            uint64_t after = atomic_fetch_add(&g_zslrBundleReserved, need) + need;
            if (avail <= 0 || avail - kZSLowResReserveBytes >= (int64_t)after) return 0;
            atomic_fetch_sub(&g_zslrBundleReserved, need);
        }
        double now = CACurrentMediaTime();
        if (now > deadline) return 1;
        if (now >= nextRelief) {
            malloc_zone_pressure_relief(NULL, 0);
            nextRelief = now + 2.0;
        }
        zslr_wait_log("waiting for memory headroom before starting bundle");
        usleep(250000);
    }
    return 2;
}

static void zslr_codec_unreserve(void *user, uint64_t need) {
    (void)user;
    atomic_fetch_sub(&g_zslrBundleReserved, need);
}

static int zslr_codec_acquire(void *user, uint64_t need) {
    (void)user;
    double deadline = CACurrentMediaTime() + kZSLowResTextureWaitLimit;
    double nextRelief = 0;
    while (!g_zslrCancel) {
        int64_t avail = zslr_available_memory();
        NSUInteger allowed = zslr_allowed_workers();
        if (allowed > 0) {
            uint64_t after = atomic_fetch_add(&g_zslrTextureInflight, need) + need;
            if (avail <= 0 || avail - kZSLowResTextureFloor >= (int64_t)after) {
                return 0;
            }
            atomic_fetch_sub(&g_zslrTextureInflight, need);
        }
        double now = CACurrentMediaTime();
        if (now > deadline) return 1;
        if (now >= nextRelief) {
            malloc_zone_pressure_relief(NULL, 0);
            nextRelief = now + 2.0;
        }
        zslr_wait_log("waiting for memory headroom before texture");
        usleep(100000);
    }
    return 2;
}

static void zslr_codec_release(void *user, uint64_t need) {
    (void)user;
    atomic_fetch_sub(&g_zslrTextureInflight, need);
}

static void zslr_codec_progress(void *user, uint32_t delta) {
    ZSLRWorker *worker = (ZSLRWorker *)user;
    double now = CACurrentMediaTime();
    BOOL logLine = NO;
    NSUInteger processed = 0;
    NSUInteger total = 0;
    double rate = 0;
    double elapsed = 0;
    os_unfair_lock_lock(&g_zslrLock);
    g_zslrStatus.texturesProcessed += delta;
    if (worker && worker->index < ZSLR_MAX_WORKERS) g_zslrWorkerDone[worker->index] += delta;
    if (now - g_zslrLastProgressLog >= 10.0) {
        g_zslrLastProgressLog = now;
        processed = g_zslrStatus.texturesProcessed;
        total = g_zslrStatus.texturesTotal;
        elapsed = g_zslrTranscodeStart > 0 ? now - g_zslrTranscodeStart : 0;
        rate = elapsed > 0 ? (double)processed / elapsed : 0;
        logLine = YES;
    }
    os_unfair_lock_unlock(&g_zslrLock);
    if (logLine) {
        double gpuSeconds = (double)atomic_load(&g_zslrGpuBusyNs) / 1e9;
        double gpuBlocks = (double)atomic_load(&g_zslrGpuBlocks);
        ZLog(@"[LowRes] progress: %lu/%lu texture(s), %.1f texture(s)/s, GPU time %.1fs of %.1fs wall, %.1f blocks/ms, chunk %u blocks", (unsigned long)processed, (unsigned long)total, rate,
             gpuSeconds, elapsed, gpuSeconds > 0 ? gpuBlocks / (gpuSeconds * 1000.0) : 0.0, (unsigned)g_zslrChunkBlocks);
    }
}

static void zslr_job_drain(ZSLRJob *job, void *worker) {
    for (;;) {
        uint32_t i = atomic_fetch_add(&job->next, 1u);
        if (i >= job->count) break;
        job->task(job->ctx, i, worker);
        atomic_fetch_add(&job->finished, 1u);
    }
}

static BOOL zslr_job_help(ZSLRWorker *worker) {
    ZSLRJob *job = NULL;
    os_unfair_lock_lock(&g_zslrJobLock);
    for (int i = 0; i < ZSLR_MAX_WORKERS; i++) {
        ZSLRJob *candidate = g_zslrJobs[i];
        if (candidate && atomic_load(&candidate->next) < candidate->count) {
            atomic_fetch_add(&candidate->helpers, 1);
            job = candidate;
            break;
        }
    }
    os_unfair_lock_unlock(&g_zslrJobLock);
    if (!job) return NO;
    zslr_job_drain(job, worker);
    atomic_fetch_sub(&job->helpers, 1);
    return YES;
}

static void zslr_codec_parallel(void *user, uint32_t count, ZSLRTaskFn task, void *ctx) {
    ZSLRWorker *owner = (ZSLRWorker *)user;
    ZSLRJob job;
    job.task = task;
    job.ctx = ctx;
    job.count = count;
    atomic_init(&job.next, 0u);
    atomic_init(&job.finished, 0u);
    atomic_init(&job.helpers, 0);
    os_unfair_lock_lock(&g_zslrJobLock);
    g_zslrJobs[owner->index] = &job;
    os_unfair_lock_unlock(&g_zslrJobLock);
    zslr_job_drain(&job, owner);
    while (atomic_load(&job.finished) < count) usleep(500);
    os_unfair_lock_lock(&g_zslrJobLock);
    g_zslrJobs[owner->index] = NULL;
    os_unfair_lock_unlock(&g_zslrJobLock);
    while (atomic_load(&job.helpers) > 0) usleep(500);
}

static BOOL zslr_ledger_skips(NSDictionary *item) {
    NSString *key = item[@"key"];
    uint64_t size = [item[@"size"] unsignedLongLongValue];
    double mtime = [item[@"mtime"] doubleValue];
    os_unfair_lock_lock(&g_zslrLock);
    NSDictionary *entry = g_zslrLedger[key];
    os_unfair_lock_unlock(&g_zslrLock);
    NSString *state = entry[@"state"];
    if (!entry || [entry[@"size"] unsignedLongLongValue] != size || fabs([entry[@"mtime"] doubleValue] - mtime) >= 0.5) return NO;
    if ([entry[@"iv"] integerValue] < 1) return NO;
    if ([state isEqualToString:@"noop"]) return YES;
    if (![state isEqualToString:@"done"]) return NO;
    uint32_t target = g_zslrTargetBlock;
    NSUInteger recorded = [entry[@"block"] unsignedIntegerValue] ?: 8;
    return target == 0 || recorded == target;
}

static BOOL zslr_ledger_has_other_block(void) {
    uint32_t target = g_zslrTargetBlock;
    BOOL other = NO;
    os_unfair_lock_lock(&g_zslrLock);
    for (NSString *key in g_zslrLedger) {
        if ([key hasSuffix:@"#scan"]) continue;
        NSDictionary *entry = g_zslrLedger[key];
        if (![entry[@"state"] isEqualToString:@"done"]) continue;
        NSUInteger recorded = [entry[@"block"] unsignedIntegerValue] ?: 8;
        if (target != 0 && recorded != target) {
            other = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&g_zslrLock);
    return other;
}

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t block;
    uint32_t blocksX;
    uint32_t srgb;
    uint32_t rowOffset;
    uint32_t rowCount;
    uint32_t quality;
} ZSLRGPUParams;

static const double kZSLRChunkTargetMs = 12.0;
static const double kZSLRChunkCapMs = 24.0;
static const uint32_t kZSLRChunkMinBlocks = 1024u;
static const uint32_t kZSLRChunkMaxBlocks = 65536u;
static double g_zslrChunkCeiling = 65536.0;
static os_unfair_lock g_zslrChunkLock = OS_UNFAIR_LOCK_INIT;
static double g_zslrRateSmooth = 0;
static double g_zslrRateBest = 0;
#define ZSLR_TRANSCODE_REJECTED 1

static os_unfair_lock g_zslrMetalLock = OS_UNFAIR_LOCK_INIT;
static id<MTLDevice> g_zslrMetalDevice;
static id<MTLCommandQueue> g_zslrMetalQueue;
static id<MTLLibrary> g_zslrMetalLibrary;
static id<MTLCommandQueue> g_zslrMetalQueues[ZSLR_MAX_WORKERS];
static id<MTLComputePipelineState> g_zslrMetalPipelines[6];
static BOOL g_zslrMetalInitialized = NO;
static NSString *g_zslrMetalError;

static id<MTLComputePipelineState> zslr_metal_prepare(uint32_t block, BOOL fast, char *why, size_t whyLen) {
    NSUInteger slot = (block == 12 ? 2 : (block == 10 ? 1 : 0)) + (fast ? 3 : 0);
    os_unfair_lock_lock(&g_zslrMetalLock);
    if (!g_zslrMetalInitialized) {
        g_zslrMetalInitialized = YES;
        NSError *error = nil;
        g_zslrMetalDevice = MTLCreateSystemDefaultDevice();
        if (!g_zslrMetalDevice) {
            g_zslrMetalError = @"Metal device unavailable";
        } else {
            Dl_info info;
            memset(&info, 0, sizeof(info));
            if (!dladdr((const void *)&zslr_metal_prepare, &info) || !info.dli_fbase) {
                g_zslrMetalError = @"Unable to locate embedded Metal library";
            } else {
                unsigned long librarySize = 0;
                const void *libraryBytes = getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__DATA", "__zslrmetal", &librarySize);
                if (!libraryBytes || librarySize == 0) {
                    g_zslrMetalError = @"Embedded Metal library is missing";
                } else {
                    dispatch_data_t data = dispatch_data_create(libraryBytes, librarySize, dispatch_get_main_queue(), ^{});
                    g_zslrMetalLibrary = [g_zslrMetalDevice newLibraryWithData:data error:&error];
                    if (!g_zslrMetalLibrary) {
                        g_zslrMetalError = error.localizedDescription ?: @"Unable to load embedded Metal library";
                    } else {
                        g_zslrMetalQueue = [g_zslrMetalDevice newCommandQueue];
                        if (!g_zslrMetalQueue) g_zslrMetalError = @"Unable to create Metal command queue";
                    }
                }
            }
        }
    }
    if (!g_zslrMetalError && !g_zslrMetalPipelines[slot]) {
        NSError *error = nil;
        uint32_t nameBlock = block == 12 ? 12u : (block == 10 ? 10u : 8u);
        NSString *name = fast ? [NSString stringWithFormat:@"zslr_astc_encode_fast_%u", nameBlock] : [NSString stringWithFormat:@"zslr_astc_encode_%u", nameBlock];
        id<MTLFunction> function = [g_zslrMetalLibrary newFunctionWithName:name];
        if (!function) {
            g_zslrMetalError = @"Metal encoder function is missing";
        } else {
            MTLComputePipelineDescriptor *pipelineDescriptor = [[MTLComputePipelineDescriptor alloc] init];
            pipelineDescriptor.computeFunction = function;
            pipelineDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = YES;
            g_zslrMetalPipelines[slot] = [g_zslrMetalDevice newComputePipelineStateWithDescriptor:pipelineDescriptor options:MTLPipelineOptionNone reflection:nil error:&error];
            if (!g_zslrMetalPipelines[slot]) g_zslrMetalError = error.localizedDescription ?: @"Unable to create Metal encoder pipeline";
        }
    }
    id<MTLComputePipelineState> pipeline = (g_zslrMetalDevice && g_zslrMetalQueue) ? g_zslrMetalPipelines[slot] : nil;
    NSString *errorText = g_zslrMetalError;
    os_unfair_lock_unlock(&g_zslrMetalLock);
    if (!pipeline) ZSLR_WHY("%s", errorText.UTF8String ?: "Metal transcoder initialization failed");
    return pipeline;
}

static void zslr_note_chunk(id<MTLCommandBuffer> commandBuffer, uint32_t blocks) {
    double seconds = commandBuffer.GPUEndTime - commandBuffer.GPUStartTime;
    if (seconds <= 0.0 || blocks == 0) return;
    double ms = seconds * 1000.0;
    atomic_fetch_add(&g_zslrGpuBusyNs, (uint64_t)(seconds * 1e9));
    atomic_fetch_add(&g_zslrGpuBlocks, (uint64_t)blocks);
    os_unfair_lock_lock(&g_zslrChunkLock);
    uint32_t current = g_zslrChunkBlocks;
    if ((double)blocks >= 0.9 * (double)current) {
        double rate = (double)blocks / ms;
        g_zslrRateSmooth = g_zslrRateSmooth > 0.0 ? g_zslrRateSmooth * 0.6 + rate * 0.4 : rate;
        g_zslrRateBest = MAX(g_zslrRateBest * 0.998, g_zslrRateSmooth);
        double next = (double)current;
        if (ms > kZSLRChunkCapMs) next = (double)current * (kZSLRChunkTargetMs / ms);
        else if (ms < kZSLRChunkTargetMs || g_zslrRateSmooth < 0.9 * g_zslrRateBest) next = (double)current * 1.2;
        g_zslrChunkCeiling = MIN(g_zslrChunkCeiling * 1.01 + 1.0, (double)kZSLRChunkMaxBlocks);
        next = MIN(next, g_zslrChunkCeiling);
        g_zslrChunkBlocks = (uint32_t)MIN(MAX(next, (double)kZSLRChunkMinBlocks), (double)kZSLRChunkMaxBlocks);
    }
    os_unfair_lock_unlock(&g_zslrChunkLock);
}

static void zslr_chunk_shrink(void) {
    os_unfair_lock_lock(&g_zslrChunkLock);
    uint32_t shrunk = MAX(kZSLRChunkMinBlocks, g_zslrChunkBlocks / 4u);
    g_zslrChunkBlocks = shrunk;
    g_zslrChunkCeiling = MAX((double)shrunk * 2.0, (double)kZSLRChunkMinBlocks);
    g_zslrRateSmooth = 0;
    g_zslrRateBest = 0;
    os_unfair_lock_unlock(&g_zslrChunkLock);
}

static id<MTLCommandQueue> zslr_queue_for(void *user) {
    NSUInteger index = user ? ((ZSLRWorker *)user)->index : 0;
    if (index >= ZSLR_MAX_WORKERS) index = 0;
    os_unfair_lock_lock(&g_zslrMetalLock);
    id<MTLCommandQueue> queue = g_zslrMetalQueues[index];
    if (!queue) {
        queue = [g_zslrMetalDevice newCommandQueue] ?: g_zslrMetalQueue;
        g_zslrMetalQueues[index] = queue;
    }
    os_unfair_lock_unlock(&g_zslrMetalLock);
    return queue;
}

static MTLPixelFormat zslr_source_pixel_format(BOOL srgb) {
    return srgb ? MTLPixelFormatASTC_6x6_sRGB : MTLPixelFormatASTC_6x6_LDR;
}


static os_unfair_lock g_zslrPoolLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, NSMutableArray<id<MTLBuffer>> *> *g_zslrBufferPool;
static NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *> *g_zslrTexturePool;
static uint64_t g_zslrPoolBytes = 0;
static const uint64_t kZSLRPoolCapBytes = 48ull * 1024ull * 1024ull;

static void zslr_pool_drain(void) {
    os_unfair_lock_lock(&g_zslrPoolLock);
    NSMutableDictionary *buffers = g_zslrBufferPool;
    NSMutableDictionary *textures = g_zslrTexturePool;
    g_zslrBufferPool = nil;
    g_zslrTexturePool = nil;
    g_zslrPoolBytes = 0;
    os_unfair_lock_unlock(&g_zslrPoolLock);
    [buffers removeAllObjects];
    [textures removeAllObjects];
}

static id<MTLBuffer> zslr_pool_take_buffer(size_t length) {
    id<MTLBuffer> buffer = nil;
    os_unfair_lock_lock(&g_zslrPoolLock);
    NSMutableArray<id<MTLBuffer>> *list = g_zslrBufferPool[@(length)];
    buffer = list.lastObject;
    if (buffer) {
        [list removeLastObject];
        g_zslrPoolBytes -= MIN(g_zslrPoolBytes, (uint64_t)buffer.allocatedSize);
    }
    os_unfair_lock_unlock(&g_zslrPoolLock);
    if (buffer) return buffer;
    return [g_zslrMetalDevice newBufferWithLength:length options:MTLResourceStorageModeShared];
}

static void zslr_pool_give_buffer(id<MTLBuffer> buffer) {
    if (!buffer) return;
    uint64_t size = buffer.allocatedSize;
    NSNumber *key = @(buffer.length);
    os_unfair_lock_lock(&g_zslrPoolLock);
    if (g_zslrPoolBytes + size <= kZSLRPoolCapBytes) {
        if (!g_zslrBufferPool) g_zslrBufferPool = [NSMutableDictionary dictionary];
        NSMutableArray<id<MTLBuffer>> *list = g_zslrBufferPool[key];
        if (!list) {
            list = [NSMutableArray array];
            g_zslrBufferPool[key] = list;
        }
        [list addObject:buffer];
        g_zslrPoolBytes += size;
    }
    os_unfair_lock_unlock(&g_zslrPoolLock);
}

static NSString *zslr_texture_key(uint32_t width, uint32_t height, BOOL srgb) {
    return [NSString stringWithFormat:@"%u.%u.%d", width, height, srgb ? 1 : 0];
}

static id<MTLTexture> zslr_pool_take_texture(uint32_t width, uint32_t height, BOOL srgb) {
    NSString *key = zslr_texture_key(width, height, srgb);
    id<MTLTexture> texture = nil;
    os_unfair_lock_lock(&g_zslrPoolLock);
    NSMutableArray<id<MTLTexture>> *list = g_zslrTexturePool[key];
    texture = list.lastObject;
    if (texture) {
        [list removeLastObject];
        g_zslrPoolBytes -= MIN(g_zslrPoolBytes, (uint64_t)texture.allocatedSize);
    }
    os_unfair_lock_unlock(&g_zslrPoolLock);
    if (texture) return texture;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:zslr_source_pixel_format(srgb)
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    return [g_zslrMetalDevice newTextureWithDescriptor:descriptor];
}

static void zslr_pool_give_texture(id<MTLTexture> texture, uint32_t width, uint32_t height, BOOL srgb) {
    if (!texture) return;
    NSString *key = zslr_texture_key(width, height, srgb);
    uint64_t size = texture.allocatedSize;
    os_unfair_lock_lock(&g_zslrPoolLock);
    if (g_zslrPoolBytes + size <= kZSLRPoolCapBytes) {
        if (!g_zslrTexturePool) g_zslrTexturePool = [NSMutableDictionary dictionary];
        NSMutableArray<id<MTLTexture>> *list = g_zslrTexturePool[key];
        if (!list) {
            list = [NSMutableArray array];
            g_zslrTexturePool[key] = list;
        }
        [list addObject:texture];
        g_zslrPoolBytes += size;
    }
    os_unfair_lock_unlock(&g_zslrPoolLock);
}

static _Atomic uint32_t g_zslrPaceUs;
static _Atomic int g_zslrPaceBusy;
static dispatch_source_t g_zslrPaceTimer;
static double g_zslrPaceEwma;

static void zslr_pace_start(void) {
    if (g_zslrPaceTimer) return;
    g_zslrPaceEwma = 0;
    atomic_store(&g_zslrPaceUs, 0u);
    atomic_store(&g_zslrPaceBusy, 0);
    atomic_store(&g_zslrGpuBusyNs, 0ull);
    atomic_store(&g_zslrGpuBlocks, 0ull);
    os_unfair_lock_lock(&g_zslrChunkLock);
    g_zslrChunkBlocks = 16384u;
    g_zslrChunkCeiling = (double)kZSLRChunkMaxBlocks;
    g_zslrRateSmooth = 0;
    g_zslrRateBest = 0;
    os_unfair_lock_unlock(&g_zslrChunkLock);
}

static void zslr_pace_stop(void) {
    dispatch_source_t timer = g_zslrPaceTimer;
    g_zslrPaceTimer = nil;
    if (timer) dispatch_source_cancel(timer);
    atomic_store(&g_zslrPaceUs, 0u);
}

typedef struct {
    atomic_int failed;
    atomic_int interactivity;
    char error[160];
} ZSLRGPUState;

static int zslr_gpu_run_once(int *interactivityOut, id<MTLCommandQueue> queue, id<MTLComputePipelineState> pipeline, id<MTLTexture> sourceTexture, id<MTLBuffer> outputBuffer, id<MTLBuffer> metricBuffer,
                        uint32_t width, uint32_t height, uint32_t block, uint32_t blocksX, uint32_t blocksY, int srgb, uint32_t quality,
                        char *why, size_t whyLen) {
    NSUInteger groupWidth = MAX((NSUInteger)1, pipeline.threadExecutionWidth);
    NSUInteger groupHeight = MIN((NSUInteger)4, MAX((NSUInteger)1, pipeline.maxTotalThreadsPerThreadgroup / groupWidth));
    MTLSize threadsPerGroup = MTLSizeMake(groupWidth, groupHeight, 1);
    dispatch_group_t finished = dispatch_group_create();
    dispatch_semaphore_t gate = dispatch_semaphore_create(4);
    ZSLRGPUState state;
    atomic_init(&state.failed, 0);
    atomic_init(&state.interactivity, 0);
    state.error[0] = 0;
    ZSLRGPUState *statePtr = &state;
    int rc = 0;
    uint32_t rowOffset = 0;
    while (rowOffset < blocksY && atomic_load(&state.failed) == 0) {
        uint32_t rowsPerChunk = MAX((uint32_t)1, g_zslrChunkBlocks / MAX(blocksX, 1u));
        uint32_t rowCount = MIN(rowsPerChunk, blocksY - rowOffset);
        ZSLRGPUParams params = { width, height, block, blocksX, srgb ? 1u : 0u, rowOffset, rowCount, quality };
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = commandBuffer ? [commandBuffer computeCommandEncoder] : nil;
        if (!commandBuffer || !encoder) {
            dispatch_semaphore_signal(gate);
            ZSLR_WHY("Metal command encoding unavailable");
            rc = -1;
            break;
        }
        [encoder setComputePipelineState:pipeline];
        [encoder setTexture:sourceTexture atIndex:0];
        [encoder setBuffer:outputBuffer offset:0 atIndex:0];
        [encoder setBytes:&params length:sizeof(params) atIndex:1];
        [encoder setBuffer:metricBuffer offset:0 atIndex:2];
        MTLSize threadgroups = MTLSizeMake((blocksX + groupWidth - 1) / groupWidth,
                                           (rowCount + groupHeight - 1) / groupHeight,
                                           1);
        [encoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
        [encoder endEncoding];
        uint32_t chunkBlocks = rowCount * blocksX;
        dispatch_group_enter(finished);
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status != MTLCommandBufferStatusCompleted) {
                int expected = 0;
                if (completed.error.code == 14) atomic_store(&statePtr->interactivity, 1);
                if (atomic_compare_exchange_strong(&statePtr->failed, &expected, 1)) {
                    snprintf(statePtr->error, sizeof(statePtr->error), "%s", completed.error.localizedDescription.UTF8String ?: "unknown error");
                }
            } else {
                zslr_note_chunk(completed, chunkBlocks);
            }
            dispatch_semaphore_signal(gate);
            dispatch_group_leave(finished);
        }];
        [commandBuffer commit];
        rowOffset += rowCount;
    }
    dispatch_group_wait(finished, DISPATCH_TIME_FOREVER);
    if (rc == 0 && atomic_load(&state.failed) != 0) {
        ZSLR_WHY("Metal ASTC kernel failed: %s", state.error[0] ? state.error : "unknown error");
        rc = -1;
    }
    if (interactivityOut) *interactivityOut = atomic_load(&state.interactivity);
    return rc;
}

static int zslr_gpu_run(id<MTLCommandQueue> queue, id<MTLComputePipelineState> pipeline, id<MTLTexture> sourceTexture, id<MTLBuffer> outputBuffer, id<MTLBuffer> metricBuffer,
                        uint32_t width, uint32_t height, uint32_t block, uint32_t blocksX, uint32_t blocksY, int srgb, uint32_t quality,
                        char *why, size_t whyLen) {
    int rc = -1;
    for (int attempt = 0; attempt < 5; attempt++) {
        int interactivity = 0;
        if (why && whyLen) why[0] = 0;
        rc = zslr_gpu_run_once(&interactivity, queue, pipeline, sourceTexture, outputBuffer, metricBuffer, width, height, block, blocksX, blocksY, srgb, quality, why, whyLen);
        if (rc == 0 || !interactivity || g_zslrCancel) break;
        zslr_chunk_shrink();
        ZLog(@"[LowRes] GPU watchdog interrupted a chunk, shrinking to %u blocks and retrying %ux%u texture (attempt %d)", (unsigned)g_zslrChunkBlocks, width, height, attempt + 2);
        usleep(30000u * (useconds_t)(attempt + 1));
    }
    return rc;
}

static int zslr_codec_transcode_inner(void *user, const uint8_t *src, size_t srcLen, uint32_t width, uint32_t height, int srgb, uint8_t **out, size_t *outLen, char *why, size_t whyLen) {
    if (out) *out = NULL;
    if (outLen) *outLen = 0;
    if (why && whyLen) why[0] = 0;
    if (!src || !out || !outLen || width == 0 || height == 0) {
        ZSLR_WHY("invalid Metal transcode input");
        return -1;
    }
    uint32_t block = zslr_block();
    uint32_t quality = ZSLowResQualityDefault;
    id<MTLComputePipelineState> pipeline = zslr_metal_prepare(block, quality == 0, why, whyLen);
    if (!pipeline) return -1;

    uint32_t blocksX = (width + block - 1) / block;
    uint32_t blocksY = (height + block - 1) / block;
    size_t blockCount = (size_t)blocksX * blocksY;
    size_t encodedLen = blockCount * 16;
    size_t sourceRowBytes = (size_t)((width + 5) / 6) * 16;
    if (encodedLen == 0 || encodedLen / 16 != blockCount || sourceRowBytes * ((height + 5) / 6) != srcLen) {
        ZSLR_WHY("ASTC source or target size mismatch");
        return -1;
    }

    double phase = CACurrentMediaTime();
    id<MTLTexture> sourceTexture = zslr_pool_take_texture(width, height, srgb != 0);
    if (!sourceTexture) {
        ZSLR_WHY("Metal cannot allocate ASTC 6x6 source texture");
        return -1;
    }
    [sourceTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                     mipmapLevel:0
                       withBytes:src
                     bytesPerRow:sourceRowBytes];
    double decodeMs = ZSLR_MS(phase);

    size_t metricLen = blockCount * sizeof(float);
    id<MTLBuffer> outputBuffer = zslr_pool_take_buffer(encodedLen);
    id<MTLBuffer> metricBuffer = zslr_pool_take_buffer(metricLen);
    if (!outputBuffer || !metricBuffer) {
        zslr_pool_give_texture(sourceTexture, width, height, srgb != 0);
        zslr_pool_give_buffer(outputBuffer);
        zslr_pool_give_buffer(metricBuffer);
        ZSLR_WHY("Metal buffer allocation failed for %zu-byte output and %zu-byte metrics", encodedLen, metricLen);
        return -1;
    }

    int gpuRc = zslr_gpu_run(zslr_queue_for(user), pipeline, sourceTexture, outputBuffer, metricBuffer, width, height, block, blocksX, blocksY, srgb, quality, why, whyLen);
    zslr_pool_give_texture(sourceTexture, width, height, srgb != 0);
    if (gpuRc != 0) {
        zslr_pool_give_buffer(outputBuffer);
        zslr_pool_give_buffer(metricBuffer);
        return -1;
    }
    double encodeMs = ZSLR_MS(phase) - decodeMs;

    zslr_pool_give_buffer(metricBuffer);

    uint8_t *encoded = (uint8_t *)malloc(encodedLen);
    if (!encoded) {
        zslr_pool_give_buffer(outputBuffer);
        ZSLR_WHY("out of memory allocating %zu-byte ASTC output", encodedLen);
        return -1;
    }
    memcpy(encoded, outputBuffer.contents, encodedLen);
    zslr_pool_give_buffer(outputBuffer);
    *out = encoded;
    *outLen = encodedLen;
    ZSLR_WHY("GPU ASTC %ux%u %s encode q%u, %s, decode %.0f ms, encode %.0f ms", block, block, quality == 0 ? "fast" : "multi-mode", quality, srgb ? "sRGB" : "linear", decodeMs, encodeMs);
    return 0;
}

static int zslr_codec_transcode(void *user, const uint8_t *src, size_t srcLen, uint32_t width, uint32_t height, int srgb, uint8_t **out, size_t *outLen, char *why, size_t whyLen) {
    int rc;
    @autoreleasepool {
        rc = zslr_codec_transcode_inner(user, src, srcLen, width, height, srgb, out, outLen, why, whyLen);
    }
    return rc;
}

@implementation ZSLowRes

+ (instancetype)shared {
    static ZSLowRes *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [ZSLowRes new];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification *note) {
            os_unfair_lock_lock(&g_zslrLock);
            g_zslrWarningUntil = CACurrentMediaTime() + kZSLowResWarningPause;
            BOOL running = g_zslrStatus.running;
            os_unfair_lock_unlock(&g_zslrLock);
            malloc_zone_pressure_relief(NULL, 0);
            ZLog(@"[LowRes] memory warning received (available %lld MB), workers paused for %.0fs%@", (long long)(zslr_available_memory() / (1024 * 1024)),
                 kZSLowResWarningPause, running ? @"" : @" (idle)");
        }];
    });
    return instance;
}

+ (NSString *)stagingDirectory {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"LowRes"];
}

+ (NSString *)mergeOriginalsIntoDirectory:(NSString *)destination copied:(NSUInteger *)copiedOut {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [UnityCacheLocator unityCacheSharedDirectories].firstObject;
    BOOL isDirectory = NO;
    if (!root || ![fm fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) return @"Couldn't find the UnityCache/Shared folder.";
    NSError *error = nil;
    if (![fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:&error]) {
        return [NSString stringWithFormat:@"Couldn't create %@: %@", destination.lastPathComponent, error.localizedDescription ?: @"unknown error"];
    }
    NSUInteger copied = 0;
    NSUInteger failed = 0;
    NSString *firstFailure = nil;
    NSDirectoryEnumerator<NSString *> *walker = [fm enumeratorAtPath:root];
    NSString *rel;
    while ((rel = [walker nextObject])) {
        @autoreleasepool {
            NSString *source = [root stringByAppendingPathComponent:rel];
            NSString *target = [destination stringByAppendingPathComponent:rel];
            NSDictionary *attrs = [walker fileAttributes];
            NSString *type = attrs[NSFileType];
            if ([type isEqualToString:NSFileTypeDirectory]) {
                if (![fm fileExistsAtPath:target]) [fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:nil];
            } else if ([type isEqualToString:NSFileTypeRegular]) {
                NSDictionary *existing = [fm attributesOfItemAtPath:target error:nil];
                if (existing && [existing[NSFileSize] unsignedLongLongValue] > 0) continue;
                [fm removeItemAtPath:target error:nil];
                [fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                NSError *copyError = nil;
                if ([fm copyItemAtPath:source toPath:target error:&copyError]) {
                    copied++;
                } else {
                    failed++;
                    if (!firstFailure) firstFailure = [NSString stringWithFormat:@"%@: %@", rel, copyError.localizedDescription ?: @"unknown error"];
                }
            }
        }
    }
    if (copiedOut) *copiedOut = copied;
    ZLog(@"[LowRes] filled %lu untouched file(s) from the original Shared into %@, %lu failed", (unsigned long)copied, destination, (unsigned long)failed);
    if (failed > 0) return [NSString stringWithFormat:@"Couldn't copy %lu untouched file(s) from Shared (%@).", (unsigned long)failed, firstFailure];
    return nil;
}

+ (NSString *)restoreMissingFilesIntoDirectory:(NSString *)directory fromBackup:(NSString *)backup restored:(NSUInteger *)restoredOut {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:backup isDirectory:&isDirectory] || !isDirectory) return @"Couldn't find Shared.backup to compare against.";
    if (![fm fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) return @"Couldn't find the new Shared folder to compare.";
    NSUInteger compared = 0;
    NSUInteger restored = 0;
    NSUInteger failed = 0;
    unsigned long long restoredBytes = 0;
    NSString *firstFailure = nil;
    NSDirectoryEnumerator<NSString *> *walker = [fm enumeratorAtPath:backup];
    NSString *rel;
    while ((rel = [walker nextObject])) {
        @autoreleasepool {
            NSString *source = [backup stringByAppendingPathComponent:rel];
            NSString *target = [directory stringByAppendingPathComponent:rel];
            NSDictionary *sourceAttrs = [walker fileAttributes];
            NSString *type = sourceAttrs[NSFileType];
            NSDictionary *existing = [fm attributesOfItemAtPath:target error:nil];
            if ([type isEqualToString:NSFileTypeDirectory]) {
                if (!existing) [fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:nil];
                continue;
            }
            compared++;
            unsigned long long sourceSize = [sourceAttrs[NSFileSize] unsignedLongLongValue];
            NSError *copyError = nil;
            BOOL ok = YES;
            if ([type isEqualToString:NSFileTypeRegular]) {
                if (existing && ([existing[NSFileSize] unsignedLongLongValue] > 0 || sourceSize == 0)) continue;
                [fm removeItemAtPath:target error:nil];
                [fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                ok = [fm copyItemAtPath:source toPath:target error:&copyError];
            } else if ([type isEqualToString:NSFileTypeSymbolicLink]) {
                if (existing) continue;
                NSString *destination = [fm destinationOfSymbolicLinkAtPath:source error:&copyError];
                if (!destination) {
                    ok = NO;
                } else {
                    [fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                    ok = [fm createSymbolicLinkAtPath:target withDestinationPath:destination error:&copyError];
                }
            } else {
                continue;
            }
            if (ok) {
                restored++;
                restoredBytes += sourceSize;
                ZLog(@"[LowRes] missing from new Shared, restored from backup: %@ (%.1f MB)", rel, (double)sourceSize / 1048576.0);
            } else {
                failed++;
                if (!firstFailure) firstFailure = [NSString stringWithFormat:@"%@: %@", rel, copyError.localizedDescription ?: @"unknown error"];
                ZLog(@"[LowRes] missing from new Shared and restore FAILED: %@ (%.1f MB): %@", rel, (double)sourceSize / 1048576.0, copyError.localizedDescription ?: @"unknown error");
            }
        }
    }
    if (restoredOut) *restoredOut = restored;
    ZLog(@"[LowRes] compared %lu backup file(s) against the new Shared: %lu restored (%.1f MB), %lu failed", (unsigned long)compared, (unsigned long)restored, (double)restoredBytes / 1048576.0, (unsigned long)failed);
    if (failed > 0) return [NSString stringWithFormat:@"%lu file(s) missing from the new Shared couldn't be restored from Shared.backup (%@).", (unsigned long)failed, firstFailure];
    return nil;
}

+ (NSString *)ledgerPath {
    return [[self stagingDirectory] stringByAppendingPathComponent:@"ledger.json"];
}

+ (void)loadLedger {
    NSString *path = [self ledgerPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    g_zslrLedger = [NSMutableDictionary dictionary];
    if ([parsed isKindOfClass:NSDictionary.class]) {
        [g_zslrLedger addEntriesFromDictionary:parsed];
        ZLog(@"[LowRes] ledger loaded: %lu entr%@ from %@", (unsigned long)g_zslrLedger.count, g_zslrLedger.count == 1 ? @"y" : @"ies", path);
    } else if (data) {
        ZLog(@"[LowRes] ledger at %@ is unreadable (%lu bytes), starting fresh", path, (unsigned long)data.length);
    } else {
        ZLog(@"[LowRes] no ledger at %@, starting fresh", path);
    }
    g_zslrLedgerDirty = 0;
}

+ (void)saveLedger {
    os_unfair_lock_lock(&g_zslrLock);
    NSDictionary *copy = [g_zslrLedger copy];
    g_zslrLedgerDirty = 0;
    os_unfair_lock_unlock(&g_zslrLock);
    if (!copy) return;
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:copy options:0 error:&jsonError];
    if (!data) {
        ZLog(@"[LowRes] ledger serialization failed: %@", jsonError.localizedDescription ?: @"unknown error");
        return;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:[self stagingDirectory] withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *writeError = nil;
    if ([data writeToFile:[self ledgerPath] options:NSDataWritingAtomic error:&writeError]) {
        ZLog(@"[LowRes] ledger saved: %lu entr%@", (unsigned long)copy.count, copy.count == 1 ? @"y" : @"ies");
    } else {
        ZLog(@"[LowRes] ledger save failed: %@", writeError.localizedDescription ?: @"unknown error");
    }
}

+ (NSArray<NSDictionary *> *)enumerateBundles {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSArray<NSString *> *roots = [UnityCacheLocator unityCacheSharedDirectories];
    ZLog(@"[LowRes] enumerating %lu cache root(s)", (unsigned long)roots.count);
    for (NSString *root in roots) {
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) {
            ZLog(@"[LowRes] cache root missing or not a directory: %@", root);
            continue;
        }
        NSUInteger rootCount = 0;
        NSUInteger unreadable = 0;
        unsigned long long rootBytes = 0;
        NSDirectoryEnumerator<NSString *> *walker = [fm enumeratorAtPath:root];
        NSString *rel;
        while ((rel = [walker nextObject])) {
            if (![rel.lastPathComponent isEqualToString:@"__data"]) continue;
            NSString *full = [root stringByAppendingPathComponent:rel];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if (!attrs) {
                unreadable++;
                continue;
            }
            if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
            rootCount++;
            rootBytes += [attrs[NSFileSize] unsignedLongLongValue];
            [items addObject:@{
                @"path": full,
                @"key": rel.stringByDeletingLastPathComponent,
                @"size": attrs[NSFileSize] ?: @0,
                @"mtime": @([attrs.fileModificationDate timeIntervalSince1970]),
            }];
        }
        ZLog(@"[LowRes] cache root %@: %lu bundle(s), %llu MB, %lu unreadable", root, (unsigned long)rootCount, rootBytes / (1024ull * 1024ull), (unsigned long)unreadable);
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"size"] compare:a[@"size"]];
    }];
    return items;
}

+ (NSArray<NSDictionary *> *)countedItems:(NSArray<NSDictionary *> *)items textures:(NSUInteger *)outTextures {
    os_unfair_lock_lock(&g_zslrLock);
    if (g_zslrStatus.running) g_zslrStatus.preparing = YES;
    os_unfair_lock_unlock(&g_zslrLock);

    NSUInteger total = items.count;
    NSUInteger *counts = (NSUInteger *)calloc(total ? total : 1, sizeof(NSUInteger));
    BOOL *skipped = (BOOL *)calloc(total ? total : 1, sizeof(BOOL));
    __block NSUInteger next = 0;
    NSMutableArray<NSDictionary *> *failures = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *zeroTally = [NSMutableDictionary dictionary];
    NSUInteger poolSize = MIN((NSUInteger)4, MAX((NSUInteger)1, NSProcessInfo.processInfo.activeProcessorCount));
    ZLog(@"[LowRes] counting candidate textures across %lu bundle(s)", (unsigned long)total);
    double countStart = CACurrentMediaTime();
    g_zslrQuiet = 1;

    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
    dispatch_queue_t queue = dispatch_queue_create("zs.lowres.count", attr);
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger w = 0; w < poolSize; w++) {
        dispatch_group_async(group, queue, ^{
            char label[32];
            snprintf(label, sizeof(label), "count%lu", (unsigned long)w);
            while (!g_zslrCancel) {
                os_unfair_lock_lock(&g_zslrCountLock);
                NSUInteger i = next < total ? next++ : NSNotFound;
                os_unfair_lock_unlock(&g_zslrCountLock);
                if (i == NSNotFound) break;
                @autoreleasepool {
                    NSDictionary *item = items[i];
                    if (zslr_ledger_skips(item)) {
                        skipped[i] = YES;
                        continue;
                    }
                    NSString *scanKey = [item[@"key"] stringByAppendingString:@"#scan"];
                    uint64_t size = [item[@"size"] unsignedLongLongValue];
                    double mtime = [item[@"mtime"] doubleValue];
                    os_unfair_lock_lock(&g_zslrLock);
                    NSDictionary *cached = g_zslrLedger[scanKey];
                    os_unfair_lock_unlock(&g_zslrLock);
                    if (cached && [cached[@"v"] integerValue] == kZSLRScanCacheVersion && [cached[@"size"] unsignedLongLongValue] == size && fabs([cached[@"mtime"] doubleValue] - mtime) < 0.5 && cached[@"cands"]) {
                        counts[i] = [cached[@"cands"] unsignedIntegerValue];
                        if (counts[i] == 0 && !((NSString *)cached[@"fail"]).length) {
                            NSString *why = cached[@"why"] ?: @"unknown";
                            os_unfair_lock_lock(&g_zslrCountLock);
                            zeroTally[why] = @([zeroTally[why] unsignedIntegerValue] + 1);
                            os_unfair_lock_unlock(&g_zslrCountLock);
                        }
                        NSString *cachedFail = cached[@"fail"];
                        NSNumber *cachedPartial = cached[@"pfail"];
                        if (cachedFail.length || cachedPartial.unsignedIntegerValue > 0) {
                            NSDictionary *record = @{ @"key": item[@"key"] ?: @"?", @"size": @(size), @"fail": cachedFail ?: @"",
                                                      @"pfail": cachedPartial ?: @0, @"parsed": cached[@"parsed"] ?: @0 };
                            os_unfair_lock_lock(&g_zslrCountLock);
                            [failures addObject:record];
                            os_unfair_lock_unlock(&g_zslrCountLock);
                        }
                        continue;
                    }
                    ZSLRCodec codec = {0};
                    ZSLRPolicy policy = { kZSLowResMinPixels, kZSLowResMaxPixels, kZSLowResMaxResultBytes };
                    ZSLRResult result;
                    char err[256] = {0};
                    int rc = zslr_process_bundle(label, [item[@"path"] fileSystemRepresentation], "", 1, &codec, &policy, &result, err, sizeof(err));
                    counts[i] = rc == ZSLR_OK ? result.candidates : 0;
                    NSString *failText = nil;
                    if (rc != ZSLR_OK) {
                        failText = [NSString stringWithFormat:@"stage '%s': %s", result.stage ?: "unknown", err[0] ? err : "no detail"];
                    }
                    NSUInteger partial = rc == ZSLR_OK ? result.parseFailures : 0;
                    NSUInteger parsed = rc == ZSLR_OK ? result.texturesTotal : 0;
                    NSMutableDictionary *entry = [@{ @"v": @(kZSLRScanCacheVersion), @"size": @(size), @"mtime": @(mtime), @"cands": @(counts[i]) } mutableCopy];
                    if (failText) entry[@"fail"] = failText;
                    NSString *zeroWhy = nil;
                    if (!failText && counts[i] == 0) {
                        zeroWhy = result.zeroReason ? @(result.zeroReason) : @"unknown";
                        entry[@"why"] = zeroWhy;
                        os_unfair_lock_lock(&g_zslrCountLock);
                        zeroTally[zeroWhy] = @([zeroTally[zeroWhy] unsignedIntegerValue] + 1);
                        os_unfair_lock_unlock(&g_zslrCountLock);
                    }
                    if (partial > 0) {
                        entry[@"pfail"] = @(partial);
                        entry[@"parsed"] = @(parsed);
                    }
                    os_unfair_lock_lock(&g_zslrLock);
                    g_zslrLedger[scanKey] = entry;
                    g_zslrLedgerDirty++;
                    os_unfair_lock_unlock(&g_zslrLock);
                    if (failText || partial > 0) {
                        NSDictionary *record = @{ @"key": item[@"key"] ?: @"?", @"size": @(size), @"fail": failText ?: @"",
                                                  @"pfail": @(partial), @"parsed": @(parsed) };
                        os_unfair_lock_lock(&g_zslrCountLock);
                        [failures addObject:record];
                        os_unfair_lock_unlock(&g_zslrCountLock);
                    }
                }
            }
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    g_zslrQuiet = 0;

    if (g_zslrCancel) {
        free(counts);
        free(skipped);
        os_unfair_lock_lock(&g_zslrLock);
        g_zslrStatus.preparing = NO;
        os_unfair_lock_unlock(&g_zslrLock);
        return nil;
    }

    if (failures.count > 0) {
        [failures sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"size"] compare:a[@"size"]];
        }];
        NSUInteger failedCount = 0;
        NSUInteger partialCount = 0;
        unsigned long long failedBytes = 0;
        for (NSDictionary *record in failures) {
            unsigned long long recordSize = [record[@"size"] unsignedLongLongValue];
            NSString *fail = record[@"fail"];
            if (fail.length > 0) {
                failedCount++;
                failedBytes += recordSize;
                ZLog(@"[LowRes] bundle parse FAILED: %@ (%.1f MB) at %@", record[@"key"], (double)recordSize / 1048576.0, fail);
            } else {
                partialCount++;
                ZLog(@"[LowRes] bundle parse PARTIAL: %@ (%.1f MB): %lu Texture2D object(s) failed to parse, %lu parsed", record[@"key"], (double)recordSize / 1048576.0,
                     (unsigned long)[record[@"pfail"] unsignedIntegerValue], (unsigned long)[record[@"parsed"] unsignedIntegerValue]);
            }
        }
        if (failedCount > 0) {
            ZLog(@"[LowRes] %lu of %lu bundle(s) failed to parse, %.1f MB total", (unsigned long)failedCount, (unsigned long)total, (double)failedBytes / 1048576.0);
        }
        if (partialCount > 0) {
            ZLog(@"[LowRes] %lu bundle(s) parsed with Texture2D object failures", (unsigned long)partialCount);
        }
    }

    NSUInteger ledgerSkipped = 0;
    for (NSUInteger i = 0; i < total; i++) {
        if (skipped[i]) ledgerSkipped++;
    }
    NSUInteger zeroTotal = 0;
    for (NSNumber *n in zeroTally.allValues) zeroTotal += n.unsignedIntegerValue;
    ZLog(@"[LowRes] %lu bundle(s) skipped by ledger, %lu bundle(s) have no candidate textures", (unsigned long)ledgerSkipped, (unsigned long)zeroTotal);
    for (NSString *why in zeroTally) {
        ZLog(@"[LowRes] no candidates because %@: %lu bundle(s)", why, (unsigned long)[zeroTally[why] unsignedIntegerValue]);
    }

    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:total];
    NSUInteger grand = 0;
    for (NSUInteger i = 0; i < total; i++) {
        if (skipped[i] || counts[i] == 0) continue;
        NSMutableDictionary *copy = [items[i] mutableCopy];
        copy[@"cands"] = @(counts[i]);
        grand += counts[i];
        [result addObject:copy];
    }
    free(counts);
    free(skipped);
    ZLog(@"[LowRes] counted %lu candidate texture(s) in %.1fs", (unsigned long)grand, CACurrentMediaTime() - countStart);
    if (g_zslrLedgerDirty > 0) [self saveLedger];

    if (outTextures) *outTextures = grand;
    os_unfair_lock_lock(&g_zslrLock);
    g_zslrStatus.preparing = NO;
    os_unfair_lock_unlock(&g_zslrLock);
    return result;
}

- (BOOL)prepareWithCompletion:(void (^)(NSUInteger textures, NSUInteger bundles, BOOL ok))completion {
    os_unfair_lock_lock(&g_zslrLock);
    if (g_zslrStatus.running) {
        os_unfair_lock_unlock(&g_zslrLock);
        return NO;
    }
    if (!g_zslrPrepareWaiters) g_zslrPrepareWaiters = [NSMutableArray array];
    if (completion) [g_zslrPrepareWaiters addObject:[completion copy]];
    if (g_zslrPreparing) {
        os_unfair_lock_unlock(&g_zslrLock);
        return YES;
    }
    g_zslrPreparing = YES;
    g_zslrPrepared = nil;
    g_zslrPreparedTextures = 0;
    g_zslrCancel = NO;
    g_zslrTargetBlock = 0;
    os_unfair_lock_unlock(&g_zslrLock);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [ZSLowRes loadLedger];
        NSArray<NSDictionary *> *items = [ZSLowRes enumerateBundles];
        NSUInteger textures = 0;
        NSArray<NSDictionary *> *pending = [ZSLowRes countedItems:items textures:&textures];
        os_unfair_lock_lock(&g_zslrLock);
        g_zslrPrepared = pending;
        g_zslrPreparedTextures = textures;
        g_zslrPreparing = NO;
        NSArray *waiters = [g_zslrPrepareWaiters copy];
        [g_zslrPrepareWaiters removeAllObjects];
        os_unfair_lock_unlock(&g_zslrLock);
        NSUInteger bundles = pending.count;
        BOOL ok = pending != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (id entry in waiters) {
                void (^block)(NSUInteger, NSUInteger, BOOL) = entry;
                block(textures, bundles, ok);
            }
        });
    });
    return YES;
}

- (BOOL)startWithMode:(ZSLowResMode)mode blockSize:(NSUInteger)blockSize completion:(void (^)(ZSLowResStatus))completion {
    os_unfair_lock_lock(&g_zslrLock);
    if (g_zslrStatus.running || g_zslrPreparing) {
        os_unfair_lock_unlock(&g_zslrLock);
        ZLog(@"[LowRes] start ignored: a run or preparation is already in progress");
        return NO;
    }
    __block NSArray<NSDictionary *> *preparedItems = (mode == ZSLowResModeTranscode) ? g_zslrPrepared : nil;
    __block NSUInteger preparedTextures = g_zslrPreparedTextures;
    g_zslrPrepared = nil;
    memset(&g_zslrStatus, 0, sizeof(g_zslrStatus));
    g_zslrStatus.running = YES;
    g_zslrStatus.mode = mode;
    g_zslrTargetBlock = (blockSize == 10 || blockSize == 12) ? (uint32_t)blockSize : 8;
    g_zslrCancel = NO;
    g_zslrHoldPaused = NO;
    g_zslrWarningUntil = 0;
    g_zslrNextItem = 0;
    g_zslrLastState = -1;
    g_zslrLastWaitLog = 0;
    g_zslrLastProgressLog = 0;
    g_zslrNoStream = 0;
    g_zslrPausedSince = 0;
    g_zslrGaveUp = NO;
    g_zslrRetries = [NSMutableDictionary dictionary];
    atomic_store(&g_zslrBundleReserved, 0);
    atomic_store(&g_zslrTextureInflight, 0);
    g_zslrTranscodeStart = 0;
    memset(g_zslrWorkerActive, 0, sizeof(g_zslrWorkerActive));
    memset(g_zslrWorkerSeq, 0, sizeof(g_zslrWorkerSeq));
    memset(g_zslrWorkerTotal, 0, sizeof(g_zslrWorkerTotal));
    memset(g_zslrWorkerDone, 0, sizeof(g_zslrWorkerDone));
    g_zslrMaxWorkers = kZSLowResMaxWorkers;
    os_unfair_lock_unlock(&g_zslrLock);
    ZLog(@"[LowRes] %@ requested at ASTC %ux%u, quality %u, available memory %lld MB", mode == ZSLowResModeScan ? @"scan" : @"transcode", zslr_block(), zslr_block(), (unsigned)ZSLowResQualityDefault, (long long)(zslr_available_memory() / (1024 * 1024)));

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double runStart = CACurrentMediaTime();
        NSFileManager *fm = NSFileManager.defaultManager;
        if (mode == ZSLowResModeTranscode) zslr_pace_start();
        if (mode == ZSLowResModeTranscode) {
            NSError *dirError = nil;
            if (![fm createDirectoryAtPath:[ZSLowRes stagingDirectory] withIntermediateDirectories:YES attributes:nil error:&dirError]) {
                ZLog(@"[LowRes] cannot create staging directory %@: %@", [ZSLowRes stagingDirectory], dirError.localizedDescription ?: @"unknown error");
            } else {
                ZLog(@"[LowRes] staging directory: %@", [ZSLowRes stagingDirectory]);
            }
            if (preparedItems && zslr_ledger_has_other_block()) {
                ZLog(@"[LowRes] ledger holds bundles written at a different block size, recounting for ASTC %ux%u", zslr_block(), zslr_block());
                preparedItems = nil;
            } else if (!preparedItems) {
                [ZSLowRes loadLedger];
            }
        }
        NSArray<NSDictionary *> *items = preparedItems;
        if (!items) {
            items = [ZSLowRes enumerateBundles];
            if (mode == ZSLowResModeTranscode) {
                os_unfair_lock_lock(&g_zslrLock);
                g_zslrStatus.bundlesTotal = items.count;
                os_unfair_lock_unlock(&g_zslrLock);
                NSUInteger counted = 0;
                items = [ZSLowRes countedItems:items textures:&counted] ?: @[];
                preparedTextures = counted;
            }
        }
        if (mode == ZSLowResModeTranscode) {
            os_unfair_lock_lock(&g_zslrLock);
            g_zslrStatus.texturesTotal = preparedTextures;
            g_zslrTranscodeStart = CACurrentMediaTime();
            os_unfair_lock_unlock(&g_zslrLock);
        }
        unsigned long long totalBytes = 0;
        for (NSDictionary *entry in items) totalBytes += [entry[@"size"] unsignedLongLongValue];
        os_unfair_lock_lock(&g_zslrLock);
        g_zslrItems = [items mutableCopy];
        g_zslrStatus.bundlesTotal = items.count;
        NSUInteger workerCount = g_zslrMaxWorkers;
        os_unfair_lock_unlock(&g_zslrLock);
        ZLog(@"[LowRes] %@ started: %lu bundle(s), %llu MB total, up to %lu worker(s)", mode == ZSLowResModeScan ? @"scan" : @"transcode",
             (unsigned long)items.count, totalBytes / (1024ull * 1024ull), (unsigned long)workerCount);
        if (items.count == 0) ZLog(@"[LowRes] no bundles found, nothing to do");

        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
        dispatch_queue_t queue = dispatch_queue_create("zs.lowres.workers", attr);
        dispatch_group_t group = dispatch_group_create();
        for (NSUInteger wi = 0; wi < workerCount; wi++) {
            dispatch_group_async(group, queue, ^{
                ZSLRWorker worker;
                memset(&worker, 0, sizeof(worker));
                worker.index = wi;
                NSUInteger handled = 0;
                const char *exitReason = "queue drained";
                ZLog(@"[LowRes] worker %lu started", (unsigned long)wi);
                while (!g_zslrCancel) {
                    NSUInteger allowed = 0;
                    while (!g_zslrCancel) {
                        allowed = zslr_allowed_workers();
                        if (wi < allowed) break;
                        zslr_wait_log("worker slot throttled");
                        usleep(150000);
                    }
                    if (g_zslrCancel) break;
                    NSDictionary *item = nil;
                    NSUInteger itemIndex = 0;
                    NSUInteger itemTotal = 0;
                    os_unfair_lock_lock(&g_zslrLock);
                    if (g_zslrNextItem < g_zslrItems.count) {
                        itemIndex = g_zslrNextItem;
                        itemTotal = g_zslrItems.count;
                        item = g_zslrItems[g_zslrNextItem++];
                    }
                    if (item) g_zslrStatus.activeWorkers++;
                    os_unfair_lock_unlock(&g_zslrLock);
                    if (!item) {
                        BOOL again = NO;
                        while (!g_zslrCancel) {
                            if (zslr_job_help(&worker)) continue;
                            os_unfair_lock_lock(&g_zslrLock);
                            BOOL busy = g_zslrStatus.activeWorkers > 0;
                            again = g_zslrNextItem < g_zslrItems.count;
                            os_unfair_lock_unlock(&g_zslrLock);
                            if (again || !busy) break;
                            usleep(2000);
                        }
                        if (again) continue;
                        break;
                    }
                    @autoreleasepool {
                        [ZSLowRes processItem:item mode:mode worker:&worker index:itemIndex total:itemTotal];
                    }
                    handled++;
                    os_unfair_lock_lock(&g_zslrLock);
                    g_zslrStatus.activeWorkers--;
                    os_unfair_lock_unlock(&g_zslrLock);
                }
                if (g_zslrCancel) exitReason = "cancelled";
                ZLog(@"[LowRes] worker %lu exiting: %s, %lu bundle(s) handled", (unsigned long)wi, exitReason, (unsigned long)handled);
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        zslr_pace_stop();
        zslr_pool_drain();
        ZLog(@"[LowRes] all workers finished");
        if (mode == ZSLowResModeTranscode) [ZSLowRes saveLedger];
        if (mode == ZSLowResModeTranscode && !g_zslrCancel) {
            NSString *mergeError = [ZSLowRes mergeOriginalsIntoDirectory:[ZSLowRes stagingDirectory] copied:NULL];
            if (mergeError) ZLog(@"[LowRes] %@", mergeError);
        }

        os_unfair_lock_lock(&g_zslrLock);
        g_zslrStatus.running = NO;
        g_zslrStatus.paused = NO;
        g_zslrStatus.cancelled = g_zslrCancel;
        g_zslrItems = nil;
        ZSLowResStatus finalStatus = g_zslrStatus;
        NSUInteger noStream = g_zslrNoStream;
        os_unfair_lock_unlock(&g_zslrLock);
        ZLog(@"[LowRes] finished in %.1fs, %lu bundle(s) had no .resS node: %@", CACurrentMediaTime() - runStart, (unsigned long)noStream, [[ZSLowRes shared] summary]);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(finalStatus); });
    });
    return YES;
}

+ (void)processItem:(NSDictionary *)item mode:(ZSLowResMode)mode worker:(ZSLRWorker *)worker index:(NSUInteger)index total:(NSUInteger)total {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *path = item[@"path"];
    NSString *key = item[@"key"];
    uint64_t size = [item[@"size"] unsignedLongLongValue];
    double mtime = [item[@"mtime"] doubleValue];
    BOOL scanOnly = (mode == ZSLowResModeScan);
    char label[192];
    snprintf(label, sizeof(label), "w%lu %s", (unsigned long)worker->index, key.UTF8String ?: "?");
    double started = CACurrentMediaTime();

    ZSLR_VLOG(label, "[%lu/%lu] begin: %.1f MB, available %lld MB", (unsigned long)(index + 1), (unsigned long)total, (double)size / 1048576.0,
             (long long)(zslr_available_memory() / (1024 * 1024)));

    if (!scanOnly) {
        os_unfair_lock_lock(&g_zslrLock);
        NSDictionary *entry = g_zslrLedger[key];
        os_unfair_lock_unlock(&g_zslrLock);
        NSString *state = entry[@"state"];
        if (zslr_ledger_skips(item)) {
            os_unfair_lock_lock(&g_zslrLock);
            g_zslrStatus.bundlesSkipped++;
            g_zslrStatus.bundlesDone++;
            os_unfair_lock_unlock(&g_zslrLock);
            ZSLR_VLOG(label, "[%lu/%lu] skipped: ledger state '%s' matches size and mtime", (unsigned long)(index + 1), (unsigned long)total, state.UTF8String ?: "?");
            return;
        }
    }

    NSString *destDir = [[self stagingDirectory] stringByAppendingPathComponent:key];
    NSString *destPath = [destDir stringByAppendingPathComponent:@"__data"];
    NSString *partPath = [destDir stringByAppendingPathComponent:@"__data.part"];
    if (!scanOnly) {
        NSError *dirError = nil;
        if (![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
            ZSLR_LOG(label, "cannot create output directory: %s", dirError.localizedDescription.UTF8String ?: "unknown error");
        }
        [fm removeItemAtPath:partPath error:nil];
        [fm removeItemAtPath:[partPath stringByAppendingString:@".scratch"] error:nil];
    }

    NSUInteger slot = worker->index;
    if (!scanOnly && slot < ZSLR_MAX_WORKERS) {
        os_unfair_lock_lock(&g_zslrLock);
        g_zslrWorkerActive[slot] = YES;
        g_zslrWorkerSeq[slot] = index;
        g_zslrWorkerTotal[slot] = [item[@"cands"] unsignedIntegerValue];
        g_zslrWorkerDone[slot] = 0;
        os_unfair_lock_unlock(&g_zslrLock);
    }

    ZSLRCodec codec = { worker, zslr_codec_reserve, zslr_codec_tick, zslr_codec_transcode, zslr_codec_progress, zslr_codec_parallel,
                        zslr_codec_acquire, zslr_codec_release, zslr_codec_unreserve };
    ZSLRPolicy policy = { kZSLowResMinPixels, kZSLowResMaxPixels, kZSLowResMaxResultBytes };
    ZSLRResult result;
    char err[256] = {0};
    int rc = zslr_process_bundle(label, path.fileSystemRepresentation, partPath.fileSystemRepresentation, scanOnly ? 1 : 0, &codec, &policy, &result, err, sizeof(err));
    const char *failStage = result.stage ?: "unknown";

    BOOL changed = NO;
    NSString *ledgerState = nil;
    if (rc == ZSLR_OK && !scanOnly) {
        if (result.wroteOutput) {
            [fm removeItemAtPath:destPath error:nil];
            NSError *moveError = nil;
            if ([fm moveItemAtPath:partPath toPath:destPath error:&moveError]) {
                NSString *infoSource = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"__info"];
                NSString *infoDest = [destDir stringByAppendingPathComponent:@"__info"];
                if ([fm fileExistsAtPath:infoSource] && ![fm fileExistsAtPath:infoDest]) {
                    NSError *copyError = nil;
                    if (![fm copyItemAtPath:infoSource toPath:infoDest error:&copyError]) {
                        ZSLR_LOG(label, "__info copy failed: %s", copyError.localizedDescription.UTF8String ?: "unknown error");
                    }
                }
                changed = YES;
                ledgerState = @"done";
            } else {
                rc = ZSLR_ERR;
                failStage = "move output";
                snprintf(err, sizeof(err), "%s", moveError.localizedDescription.UTF8String ?: "move failed");
            }
        } else {
            ledgerState = @"noop";
        }
    }
    if (rc == ZSLR_ERR || rc == ZSLR_CANCELLED || rc == ZSLR_DEFERRED) {
        [fm removeItemAtPath:partPath error:nil];
        [fm removeItemAtPath:[partPath stringByAppendingString:@".scratch"] error:nil];
    }

    BOOL requeue = NO;
    os_unfair_lock_lock(&g_zslrLock);
    if (rc == ZSLR_DEFERRED && !scanOnly && !g_zslrCancel) {
        NSUInteger tries = [g_zslrRetries[key] unsignedIntegerValue];
        if (tries < kZSLowResMaxRetries) {
            g_zslrRetries[key] = @(tries + 1);
            requeue = YES;
        }
    }
    if (!scanOnly && slot < ZSLR_MAX_WORKERS) {
        if (requeue) {
            NSUInteger counted = g_zslrWorkerDone[slot];
            g_zslrStatus.texturesProcessed = g_zslrStatus.texturesProcessed > counted ? g_zslrStatus.texturesProcessed - counted : 0;
        } else if (rc != ZSLR_CANCELLED && g_zslrWorkerTotal[slot] > g_zslrWorkerDone[slot]) {
            g_zslrStatus.texturesProcessed += g_zslrWorkerTotal[slot] - g_zslrWorkerDone[slot];
        }
        g_zslrWorkerActive[slot] = NO;
    }
    if (rc == ZSLR_OK) {
        g_zslrStatus.texturesCandidate += result.candidates;
        g_zslrStatus.texturesConverted += result.converted;
        g_zslrStatus.texturesRejected += result.rejected;
        g_zslrStatus.candidateBytes += result.candidateBytes;
        g_zslrStatus.originalBytes += result.originalBytes;
        g_zslrStatus.newBytes += result.newBytes;
        if (changed) g_zslrStatus.bundlesChanged++;
        if (result.noStream) g_zslrNoStream++;
        if (ledgerState) {
            g_zslrLedger[key] = @{ @"size": @(size), @"mtime": @(mtime), @"state": ledgerState,
                                   @"before": @(result.originalBytes), @"after": @(result.newBytes), @"textures": @(result.converted), @"block": @(zslr_block()), @"iv": @1 };
            g_zslrLedgerDirty++;
        }
        g_zslrStatus.bundlesDone++;
    } else if (rc == ZSLR_DEFERRED) {
        if (requeue) {
            [g_zslrItems addObject:item];
        } else {
            g_zslrStatus.bundlesDeferred++;
            g_zslrStatus.bundlesDone++;
        }
    } else if (rc == ZSLR_CANCELLED) {
    } else {
        g_zslrStatus.bundlesFailed++;
        g_zslrStatus.bundlesDone++;
    }
    BOOL flush = g_zslrLedgerDirty >= 16;
    os_unfair_lock_unlock(&g_zslrLock);
    if (flush) [self saveLedger];

    double secs = CACurrentMediaTime() - started;
    unsigned long n = (unsigned long)(index + 1);
    unsigned long t = (unsigned long)total;
    if (rc == ZSLR_ERR) {
        ZSLR_LOG(label, "[%lu/%lu] FAILED at stage '%s': %s (%.1fs)", n, t, failStage, err[0] ? err : "no detail", secs);
    } else if (rc == ZSLR_DEFERRED) {
        ZSLR_LOG(label, "[%lu/%lu] deferred: not enough memory headroom, %s (%.1fs)", n, t, requeue ? "queued for retry" : "giving up", secs);
    } else if (rc == ZSLR_CANCELLED) {
        ZSLR_LOG(label, "[%lu/%lu] cancelled (%.1fs)", n, t, secs);
    } else if (scanOnly) {
        ZSLR_LOG(label, "[%lu/%lu] scan done: %s, %u candidate(s), %llu -> %llu projected bytes (%.1fs)", n, t, result.outcome ?: "?", result.candidates,
                 (unsigned long long)result.candidateBytes, (unsigned long long)result.newBytes, secs);
    } else if (changed) {
        ZSLR_LOG(label, "[%lu/%lu] written: %u/%u texture(s), %llu -> %llu bytes, %u failed (%.1fs)", n, t, result.converted, result.candidates,
                 (unsigned long long)result.originalBytes, (unsigned long long)result.newBytes, result.rejected, secs);
    } else {
        ZSLR_LOG(label, "[%lu/%lu] no changes: %s (%.1fs)", n, t, result.outcome ?: "?", secs);
    }
}

- (void)cancel {
    g_zslrCancel = YES;
}

- (ZSLowResStatus)status {
    os_unfair_lock_lock(&g_zslrLock);
    ZSLowResStatus copy = g_zslrStatus;
    NSUInteger best = NSNotFound;
    NSUInteger bestSeq = NSUIntegerMax;
    for (NSUInteger i = 0; i < ZSLR_MAX_WORKERS; i++) {
        if (g_zslrWorkerActive[i] && g_zslrWorkerTotal[i] > 0 && g_zslrWorkerSeq[i] < bestSeq) {
            best = i;
            bestSeq = g_zslrWorkerSeq[i];
        }
    }
    if (best != NSNotFound) {
        copy.currentBundleTotal = g_zslrWorkerTotal[best];
        copy.currentBundleProcessed = MIN(g_zslrWorkerDone[best], g_zslrWorkerTotal[best]);
    }
    double start = g_zslrTranscodeStart;
    os_unfair_lock_unlock(&g_zslrLock);
    if (copy.texturesProcessed > copy.texturesTotal) copy.texturesProcessed = copy.texturesTotal;
    copy.etaSeconds = -1;
    if (copy.running && !copy.preparing && copy.mode == ZSLowResModeTranscode && copy.texturesProcessed > 0 && start > 0) {
        double elapsed = CACurrentMediaTime() - start;
        copy.etaSeconds = elapsed / (double)copy.texturesProcessed * (double)(copy.texturesTotal - copy.texturesProcessed);
    }
    return copy;
}

static NSString *zslr_bytes(uint64_t bytes) {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleMemory];
}

- (NSString *)statusLine {
    ZSLowResStatus s = [self status];
    NSString *verb = s.mode == ZSLowResModeScan ? @"Scanning" : @"Transcoding";
    NSString *state = s.paused ? @" (paused: low memory)" : (s.allowedWorkers == 1 && g_zslrMaxWorkers > 1 ? @" (throttled)" : @"");
    return [NSString stringWithFormat:@"%@ %lu/%lu%@", verb, (unsigned long)s.bundlesDone, (unsigned long)s.bundlesTotal, state];
}

- (NSString *)summary {
    ZSLowResStatus s = [self status];
    NSMutableString *text = [NSMutableString string];
    if (s.mode == ZSLowResModeScan) {
        [text appendFormat:@"Bundles scanned: %lu\nCandidate textures: %lu\nASTC 6x6 data: %@\nProjected at %ux%u: %@\nProjected saving: %@",
            (unsigned long)s.bundlesDone, (unsigned long)s.texturesCandidate, zslr_bytes(s.candidateBytes), zslr_block(), zslr_block(), zslr_bytes(s.newBytes),
            zslr_bytes(s.candidateBytes > s.newBytes ? s.candidateBytes - s.newBytes : 0)];
    } else {
        [text appendFormat:@"Bundles processed: %lu (written %lu, skipped %lu, deferred %lu, failed %lu)\nTextures converted: %lu of %lu (failed: %lu)\nTexture data: %@ -> %@\nSaved: %@\nOutput: Documents/LowRes",
            (unsigned long)s.bundlesDone, (unsigned long)s.bundlesChanged, (unsigned long)s.bundlesSkipped, (unsigned long)s.bundlesDeferred,
            (unsigned long)s.bundlesFailed, (unsigned long)s.texturesConverted, (unsigned long)s.texturesCandidate, (unsigned long)s.texturesRejected,
            zslr_bytes(s.originalBytes), zslr_bytes(s.newBytes), zslr_bytes(s.originalBytes > s.newBytes ? s.originalBytes - s.newBytes : 0)];
    }
    if (g_zslrGaveUp) [text appendString:@"\n(stopped: available memory stayed too low, progress is saved)"];
    else if (s.cancelled) [text appendString:@"\n(cancelled)"];
    return text;
}

@end
