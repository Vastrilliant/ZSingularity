#import "ZSLowRes.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
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

#import "UnityBundleTools.h"
#import "ZTweakLog.h"
#include "lz4.h"
#include "lz4hc.h"
#include "astcenc.h"

#define ZSLR_BLOCK_SIZE 131072u
#define ZSLR_FORMAT_ASTC_6x6 50
#define ZSLR_FORMAT_ASTC_8x8 51

#define ZSLR_LOG(label, fmt, ...) ZLog(@"[LowRes] %s: " fmt, (label), ##__VA_ARGS__)
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

static int zslr_scan_textures(const uint8_t *cab, size_t cabLength, ZSLRTexture **textures, uint32_t *count, uint32_t *parseFailures, char *err, size_t errLen);

static uint64_t zslr_astc_size(uint32_t width, uint32_t height, uint32_t blockX, uint32_t blockY);
static void zslr_patch_texture(uint8_t *cab, const ZSLRTexture *texture, int32_t newFormat, uint32_t newSize);

static int zslr_writer_open(ZSLRWriter *writer, const char *tmpPath);
static int zslr_writer_write(ZSLRWriter *writer, const uint8_t *data, size_t length);
static int zslr_writer_zeros(ZSLRWriter *writer, uint64_t length);
static int zslr_writer_finish(ZSLRWriter *writer, const ZSLRBundle *source, const char *outPath, char *err, size_t errLen);
static void zslr_writer_abort(ZSLRWriter *writer);


typedef struct {
    void *user;
    int (*reserve)(void *user, uint64_t workingSetBytes);
    int (*tick)(void *user);
    int (*transcode)(void *user, const uint8_t *src, size_t srcLen, uint32_t width, uint32_t height, int srgb, uint8_t **out, size_t *outLen, char *why, size_t whyLen);
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
} ZSLRResult;

#define ZSLR_OK 0
#define ZSLR_ERR -1
#define ZSLR_DEFERRED 2
#define ZSLR_CANCELLED 3
#define ZSLR_TRANSCODE_REJECTED 1

static int zslr_process_bundle(const char *label, const char *srcPath, const char *outPath, int scanOnly, const ZSLRCodec *codec, const ZSLRPolicy *policy, ZSLRResult *result, char *err, size_t errLen);
static int64_t zslr_available_memory(void);
static void zslr_wait_log(const char *what);

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
    wr_le32(cab + t->streamSizePosition, newSize);
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

static int zslr_scan_textures(const uint8_t *buf, size_t len, ZSLRTexture **outTextures, uint32_t *outCount, uint32_t *outFailures, char *err, size_t errLen) {
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
    int c = LZ4_compress_default((const char *)w->raw, (char *)w->comp, (int)n, (int)n - 1);
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
    int cinfoLen = LZ4_compress_HC((const char *)info, (char *)cinfo, (int)infoLen, bound, LZ4HC_CLEVEL_DEFAULT);
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
    uint8_t *data;
    size_t length;
    uint32_t newSize;
} ZSLRConverted;

typedef struct {
    uint64_t absolute;
    uint64_t originalLength;
    const uint8_t *data;
    size_t dataLength;
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
    if (zslr_bundle_locate(&b, &si, &ri) != 0) {
        pl_err(err, errLen, "verify: nodes missing");
        goto done;
    }
    cab = (uint8_t *)malloc((size_t)b.nodes[si].size);
    if (!cab || zslr_bundle_read(&b, b.nodes[si].offset, (size_t)b.nodes[si].size, cab) != 0) {
        pl_err(err, errLen, "verify: cab read failed");
        goto done;
    }
    if (zslr_scan_textures(cab, (size_t)b.nodes[si].size, &tex, &count, NULL, err, errLen) != 0) goto done;
    for (uint32_t i = 0; i < convCount; i++) {
        const ZSLRTexture *orig = &textures[conv[i].texture];
        const ZSLRTexture *found = NULL;
        for (uint32_t k = 0; k < count; k++) {
            if (tex[k].pathId == orig->pathId) {
                found = &tex[k];
                break;
            }
        }
        if (!found || found->format != ZSLR_FORMAT_ASTC_8x8 || found->streamSize != conv[i].newSize ||
            found->completeImageSize != conv[i].newSize || found->streamOffset != orig->streamOffset ||
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
    ZSLR_LOG(label, "mapped %llu bytes, parsing container", (unsigned long long)fileSize);

    int rc = ZSLR_ERR;
    ZSLRBundle b;
    int bundleOpen = 0;
    uint8_t *cab = NULL;
    ZSLRTexture *textures = NULL;
    const ZSLRTexture **cands = NULL;
    ZSLRConverted *conv = NULL;
    ZSLRRegion *regions = NULL;
    uint8_t *chunk = NULL;
    uint8_t *srcBuf = NULL;
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
    ZSLR_LOG(label, "container ok: format v%u, unity %s, header flags 0x%x, %u block(s), %u node(s), %llu bytes uncompressed (%.0f ms)",
             b.formatVersion, b.unityVersion, b.headerFlags, b.blockCount, b.nodeCount, (unsigned long long)b.totalUncompressed, ZSLR_MS(stageStart));
    for (uint32_t i = 0; i < b.nodeCount && i < 8; i++) {
        ZSLR_LOG(label, "node %u: %s, %llu bytes, flags 0x%x", i, b.nodes[i].path, (unsigned long long)b.nodes[i].size, b.nodes[i].flags);
    }
    if (b.nodeCount > 8) ZSLR_LOG(label, "%u more node(s) not listed", b.nodeCount - 8);

    result->stage = "locate nodes";
    int loc = zslr_bundle_locate(&b, &si, &ri);
    if (loc == -1) {
        pl_err(err, errLen, "no serialized node among %u node(s)", b.nodeCount);
        goto done;
    }
    if (loc == -2) {
        pl_err(err, errLen, "more than one serialized node, multi-file bundles are not supported");
        goto done;
    }
    if (loc == 1) {
        ZSLR_LOG(label, "serialized node %s has no .resS sibling", b.nodes[si].path);
    } else {
        ZSLR_LOG(label, "node pair: serialized %s (%llu bytes), stream %s (%llu bytes)", b.nodes[si].path, (unsigned long long)b.nodes[si].size,
                 b.nodes[ri].path, (unsigned long long)b.nodes[ri].size);
    }

    result->stage = "read serialized node";
    if (b.nodes[si].size > ZSLR_MAX_CAB_BYTES || b.nodes[si].size < 64) {
        pl_err(err, errLen, "serialized node size %llu bytes outside allowed range 64..%u", (unsigned long long)b.nodes[si].size, ZSLR_MAX_CAB_BYTES);
        goto done;
    }
    size_t cabLen = (size_t)b.nodes[si].size;
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
    ZSLR_LOG(label, "serialized node read: %zu bytes (%.0f ms)", cabLen, ZSLR_MS(stageStart));

    result->stage = "scan textures";
    stageStart = CACurrentMediaTime();
    if (zslr_scan_textures(cab, cabLen, &textures, &texCount, &result->parseFailures, err, errLen) != 0) goto done;
    result->texturesTotal = texCount;
    ZSLR_LOG(label, "scan: %u Texture2D parsed, %u parse failure(s) (%.0f ms)", texCount, result->parseFailures, ZSLR_MS(stageStart));

    if (loc == 1) {
        uint32_t inlineCount = 0;
        for (uint32_t i = 0; i < texCount; i++) {
            if (textures[i].imageDataLength != 0) inlineCount++;
        }
        result->noStream = 1;
        result->outcome = "no .resS node";
        if (texCount == 0) {
            ZSLR_LOG(label, "no .resS node and no Texture2D objects, nothing to transcode");
        } else {
            ZSLR_LOG(label, "no .resS node: %u Texture2D (%u inline, %u with stream data), nothing to transcode", texCount, inlineCount, texCount - inlineCount);
        }
        rc = ZSLR_OK;
        goto done;
    }

    result->stage = "select candidates";
    cands = (const ZSLRTexture **)malloc(((size_t)texCount + 1) * sizeof(*cands));
    if (!cands) {
        pl_err(err, errLen, "out of memory");
        goto done;
    }
    uint64_t resSize = b.nodes[ri].size;
    uint32_t fFormat = 0, fMips = 0, fInline = 0, fDims = 0, fPixels = 0, fSize = 0, fRange = 0, fName = 0, fPath = 0, fOverlap = 0;
    for (uint32_t i = 0; i < texCount; i++) {
        const ZSLRTexture *t = &textures[i];
        if (t->format != ZSLR_FORMAT_ASTC_6x6) { fFormat++; continue; }
        if (t->mipCount != 1) { fMips++; continue; }
        if (t->imageDataLength != 0) { fInline++; continue; }
        if (t->width == 0 || t->height == 0) { fDims++; continue; }
        uint64_t pixels = (uint64_t)t->width * t->height;
        if (pixels < policy->minPixels || pixels > policy->maxPixels) { fPixels++; continue; }
        uint64_t expected = zslr_astc_size(t->width, t->height, 6, 6);
        if (t->streamSize != expected || t->completeImageSize != expected) { fSize++; continue; }
        if (t->streamOffset > resSize || t->streamSize > resSize - t->streamOffset) { fRange++; continue; }
        if (t->name[0] && pl_name_blocked(t->name)) { fName++; continue; }
        if (!pl_path_matches(cab, cabLen, t, b.nodes[ri].path)) { fPath++; continue; }
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
    result->candidates = candCount;
    ZSLR_LOG(label, "candidates: %u of %u Texture2D (skipped: format %u, mips %u, inline %u, dims %u, pixel limits %u, size mismatch %u, stream range %u, name filter %u, path mismatch %u, overlap %u)",
             candCount, texCount, fFormat, fMips, fInline, fDims, fPixels, fSize, fRange, fName, fPath, fOverlap);

    uint64_t peakTexture = 0;
    uint64_t projected = 0;
    for (uint32_t i = 0; i < candCount; i++) {
        const ZSLRTexture *t = cands[i];
        uint64_t ns = zslr_astc_size(t->width, t->height, 8, 8);
        uint64_t need = (uint64_t)t->width * t->height * 8u + (uint64_t)t->streamSize * 2u + ns;
        if (need > peakTexture) peakTexture = need;
        result->candidateBytes += t->streamSize;
        projected += ns;
    }
    uint64_t resultCap = projected < policy->maxResultBytes ? projected : policy->maxResultBytes;
    result->workingSetEstimate = peakTexture + resultCap + cabLen + ZSLR_COPY_CHUNK;
    if (candCount > 0) {
        ZSLR_LOG(label, "projected: %llu -> %llu bytes at 8x8, working set estimate %llu MB", (unsigned long long)result->candidateBytes,
                 (unsigned long long)projected, ZSLR_MB(result->workingSetEstimate));
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

    result->stage = "reserve memory";
    if (codec->reserve) {
        double reserveStart = CACurrentMediaTime();
        ZSLR_LOG(label, "reserving %llu MB working set (available %lld MB)", ZSLR_MB(result->workingSetEstimate), (long long)(zslr_available_memory() / (1024 * 1024)));
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
        ZSLR_LOG(label, "reserve granted after %.1fs", ZSLR_MS(reserveStart) / 1000.0);
    }

    conv = (ZSLRConverted *)calloc(candCount, sizeof(*conv));
    if (!conv) {
        pl_err(err, errLen, "out of memory");
        goto done;
    }
    result->stage = "transcode";
    stageStart = CACurrentMediaTime();
    uint32_t capSkipped = 0;
    uint64_t resultBytes = 0;
    for (uint32_t i = 0; i < candCount; i++) {
        const ZSLRTexture *t = cands[i];
        uint32_t newSize = (uint32_t)zslr_astc_size(t->width, t->height, 8, 8);
        if (resultBytes + newSize > policy->maxResultBytes) {
            capSkipped++;
            continue;
        }
        if (codec->tick && codec->tick(codec->user) != 0) {
            ZSLR_LOG(label, "cancelled before texture %u/%u", i + 1, candCount);
            rc = ZSLR_CANCELLED;
            goto done;
        }
        free(srcBuf);
        srcBuf = (uint8_t *)malloc(t->streamSize);
        if (!srcBuf || zslr_bundle_read(&b, b.nodes[ri].offset + t->streamOffset, t->streamSize, srcBuf) != 0) {
            pl_err(err, errLen, "cannot read stream of texture %lld (offset %llu, %u bytes)", (long long)t->pathId, (unsigned long long)t->streamOffset, t->streamSize);
            goto done;
        }
        uint8_t *out = NULL;
        size_t outLen = 0;
        char why[160] = {0};
        const char *texName = t->name[0] ? t->name : "<unnamed>";
        double texStart = CACurrentMediaTime();
        int tr = codec->transcode(codec->user, srcBuf, t->streamSize, t->width, t->height, t->colorSpace == 1, &out, &outLen, why, sizeof(why));
        if (tr == 0 && out && outLen != newSize) {
            snprintf(why, sizeof(why), "output size %zu, expected %u", outLen, newSize);
            tr = -1;
        }
        if (tr == ZSLR_TRANSCODE_REJECTED) {
            result->rejected++;
            free(out);
            ZSLR_LOG(label, "texture %u/%u %s (path %lld, %ux%u): rejected, %s (%.0f ms)", i + 1, candCount, texName, (long long)t->pathId,
                     t->width, t->height, why[0] ? why : "quality", ZSLR_MS(texStart));
            continue;
        }
        if (tr != 0 || !out) {
            free(out);
            result->rejected++;
            ZSLR_LOG(label, "texture %u/%u %s (path %lld, %ux%u): failed, %s (%.0f ms)", i + 1, candCount, texName, (long long)t->pathId,
                     t->width, t->height, why[0] ? why : "unknown transcode error", ZSLR_MS(texStart));
            continue;
        }
        conv[convCount].texture = (uint32_t)(t - textures);
        conv[convCount].data = out;
        conv[convCount].length = outLen;
        conv[convCount].newSize = newSize;
        convCount++;
        resultBytes += newSize;
        result->originalBytes += t->streamSize;
        result->newBytes += newSize;
        ZSLR_LOG(label, "texture %u/%u %s (path %lld, %ux%u, %u -> %u bytes): converted, %s (%.0f ms)", i + 1, candCount, texName, (long long)t->pathId,
                 t->width, t->height, t->streamSize, newSize, why, ZSLR_MS(texStart));
    }
    if (capSkipped) {
        ZSLR_LOG(label, "result cap of %llu MB reached, %u texture(s) left unconverted", ZSLR_MB(policy->maxResultBytes), capSkipped);
    }
    result->converted = convCount;
    ZSLR_LOG(label, "transcode pass done: %u converted, %u rejected or failed (%.1fs)", convCount, result->rejected, ZSLR_MS(stageStart) / 1000.0);
    if (convCount == 0) {
        result->outcome = "all candidates rejected";
        rc = ZSLR_OK;
        goto done;
    }

    result->stage = "patch serialized node";
    for (uint32_t i = 0; i < convCount; i++) {
        zslr_patch_texture(cab, &textures[conv[i].texture], ZSLR_FORMAT_ASTC_8x8, conv[i].newSize);
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
    for (uint32_t i = 0; i < convCount; i++) {
        const ZSLRTexture *t = &textures[conv[i].texture];
        regions[rcount].absolute = b.nodes[ri].offset + t->streamOffset;
        regions[rcount].originalLength = t->streamSize;
        regions[rcount].data = conv[i].data;
        regions[rcount].dataLength = conv[i].length;
        rcount++;
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
    ZSLR_LOG(label, "rewriting %llu bytes of stream with %u replaced region(s)", (unsigned long long)b.totalUncompressed, rcount);
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
        if (zslr_writer_write(&writer, regions[i].data, regions[i].dataLength) != 0 ||
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
    ZSLR_LOG(label, "stream rewritten (%.1fs), finalizing container", ZSLR_MS(stageStart) / 1000.0);
    result->stage = "finalize container";
    stageStart = CACurrentMediaTime();
    rc = zslr_writer_finish(&writer, &b, outPath, err, errLen);
    writerOpen = 0;
    if (rc != 0) {
        rc = ZSLR_ERR;
        goto done;
    }
    ZSLR_LOG(label, "container finalized (%.1fs), verifying", ZSLR_MS(stageStart) / 1000.0);
    result->stage = "verify";
    stageStart = CACurrentMediaTime();
    if (pl_verify(outPath, conv, convCount, textures, err, errLen) != 0) {
        unlink(outPath);
        rc = ZSLR_ERR;
        goto done;
    }
    ZSLR_LOG(label, "verified %u converted texture(s) (%.1fs)", convCount, ZSLR_MS(stageStart) / 1000.0);
    result->wroteOutput = 1;
    result->outcome = "written";
    rc = ZSLR_OK;

done:
    if (writerOpen) zslr_writer_abort(&writer);
    if (conv) {
        for (uint32_t i = 0; i < candCount; i++) free(conv[i].data);
    }
    free(conv);
    free(regions);
    free(chunk);
    free(srcBuf);
    free(cands);
    free(textures);
    free(cab);
    if (bundleOpen) zslr_bundle_close(&b);
    munmap(map, fileSize);
    return rc;
}

#pragma mark - Objective-C layer

static const uint32_t kZSLowResMinPixels = 256u * 256u;
static const uint32_t kZSLowResMaxPixels = 4096u * 4096u;
static const uint64_t kZSLowResMaxResultBytes = 256ull * 1024ull * 1024ull;
static const double kZSLowResMinPSNR = 27.0;
static const double kZSLowResRescueWindowDB = 10.0;

static const int64_t kZSLowResFullSpeedAbove = 450ll * 1024 * 1024;
static const int64_t kZSLowResHalfSpeedAbove = 300ll * 1024 * 1024;
static const int64_t kZSLowResPauseBelow = 170ll * 1024 * 1024;
static const int64_t kZSLowResResumeAbove = 230ll * 1024 * 1024;
static const int64_t kZSLowResReserveBytes = 130ll * 1024 * 1024;
static const NSTimeInterval kZSLowResMemoryWaitLimit = 30.0;
static const NSTimeInterval kZSLowResWarningPause = 8.0;
static const useconds_t kZSLowResConstrainedSleep = 25000;
static const NSUInteger kZSLowResMaxWorkers = 6;

enum {
    kZSLowResDecodeSRGB = 0,
    kZSLowResDecodeLinear = 1,
    kZSLowResEncodeOpaqueSRGB = 2,
    kZSLowResEncodeAlphaSRGB = 3,
    kZSLowResEncodeOpaqueLinear = 4,
    kZSLowResEncodeAlphaLinear = 5,
    kZSLowResRescueOffset = 4,
    kZSLowResContextKinds = 10,
};

typedef struct {
    NSUInteger index;
    struct astcenc_context *contexts[kZSLowResContextKinds];
} ZSLRWorker;

static os_unfair_lock g_zslrLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_zslrParentLock = OS_UNFAIR_LOCK_INIT;
static ZSLowResStatus g_zslrStatus;
static volatile BOOL g_zslrCancel = NO;
static double g_zslrWarningUntil = 0;
static BOOL g_zslrHoldPaused = NO;
static NSUInteger g_zslrMaxWorkers = 1;
static int g_zslrLastState = -1;
static double g_zslrLastWaitLog = 0;
static NSUInteger g_zslrNoStream = 0;
static NSArray<NSDictionary *> *g_zslrItems;
static NSUInteger g_zslrNextItem = 0;
static NSMutableDictionary<NSString *, NSDictionary *> *g_zslrLedger;
static NSUInteger g_zslrLedgerDirty = 0;
static struct astcenc_context *g_zslrParents[kZSLowResContextKinds];

static int64_t zslr_available_memory(void) {
    if (@available(iOS 13.0, *)) return (int64_t)os_proc_available_memory();
    return 0;
}

static NSUInteger zslr_allowed_workers(void) {
    double now = CACurrentMediaTime();
    int64_t avail = zslr_available_memory();
    int state;
    os_unfair_lock_lock(&g_zslrLock);
    NSUInteger allowed;
    if (now < g_zslrWarningUntil) {
        allowed = 0;
        state = 4;
    } else if (avail <= 0) {
        allowed = g_zslrMaxWorkers;
        state = 5;
    } else if (g_zslrHoldPaused && avail < kZSLowResResumeAbove) {
        allowed = 0;
        state = 3;
    } else if (avail < kZSLowResPauseBelow) {
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
    g_zslrStatus.allowedWorkers = allowed;
    g_zslrStatus.paused = (allowed == 0);
    BOOL changed = (state != g_zslrLastState);
    g_zslrLastState = state;
    NSUInteger maxWorkers = g_zslrMaxWorkers;
    os_unfair_lock_unlock(&g_zslrLock);
    if (changed) {
        static const char *names[] = { "full speed", "half speed", "single worker", "paused: low memory", "paused: memory warning cooldown", "memory reading unavailable" };
        ZLog(@"[LowRes] throttle: %s, %lu/%lu worker(s) allowed, available %lld MB", names[state], (unsigned long)allowed, (unsigned long)maxWorkers,
             (long long)(avail / (1024 * 1024)));
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
    while (!g_zslrCancel) {
        NSUInteger allowed = zslr_allowed_workers();
        if (allowed == 0) {
            zslr_wait_log("conversion paused");
            usleep(200000);
            continue;
        }
        if (allowed == 1 && g_zslrMaxWorkers > 1) usleep(kZSLowResConstrainedSleep);
        return 0;
    }
    return 1;
}

static int zslr_codec_reserve(void *user, uint64_t need) {
    (void)user;
    double deadline = CACurrentMediaTime() + kZSLowResMemoryWaitLimit;
    while (!g_zslrCancel) {
        int64_t avail = zslr_available_memory();
        if (avail <= 0) return 0;
        if (zslr_allowed_workers() > 0 && avail - kZSLowResReserveBytes >= (int64_t)need) return 0;
        if (CACurrentMediaTime() > deadline) return 1;
        zslr_wait_log("waiting for memory headroom before starting bundle");
        usleep(250000);
    }
    return 2;
}

static enum astcenc_error zslr_make_config(int kind, struct astcenc_config *config) {
    BOOL rescue = kind >= kZSLowResEncodeOpaqueSRGB + kZSLowResRescueOffset;
    int base = rescue ? kind - kZSLowResRescueOffset : kind;
    BOOL srgb = (base == kZSLowResDecodeSRGB || base == kZSLowResEncodeOpaqueSRGB || base == kZSLowResEncodeAlphaSRGB);
    enum astcenc_profile profile = srgb ? ASTCENC_PRF_LDR_SRGB : ASTCENC_PRF_LDR;
    if (base == kZSLowResDecodeSRGB || base == kZSLowResDecodeLinear) {
        return astcenc_config_init(profile, 6, 6, 1, ASTCENC_PRE_FASTEST, ASTCENC_FLG_DECOMPRESS_ONLY, config);
    }
    unsigned int flags = ASTCENC_FLG_SELF_DECOMPRESS_ONLY;
    if (base == kZSLowResEncodeAlphaSRGB || base == kZSLowResEncodeAlphaLinear) flags |= ASTCENC_FLG_USE_ALPHA_WEIGHT;
    return astcenc_config_init(profile, 8, 8, 1, rescue ? ASTCENC_PRE_MEDIUM : ASTCENC_PRE_FASTEST, flags, config);
}

static void zslr_measure(const uint8_t *ref, const uint8_t *test, size_t pixels, int hasAlpha, double *weighted, double *raw) {
    double rawSum = 0;
    double rgbSum = 0;
    double weightSum = 0;
    double alphaSum = 0;
    for (size_t i = 0; i < pixels; i++) {
        const uint8_t *r = ref + i * 4;
        const uint8_t *t = test + i * 4;
        double dr = (double)r[0] - (double)t[0];
        double dg = (double)r[1] - (double)t[1];
        double db = (double)r[2] - (double)t[2];
        double da = (double)r[3] - (double)t[3];
        double rgbErr = dr * dr + dg * dg + db * db;
        double w = hasAlpha ? (double)r[3] / 255.0 : 1.0;
        rawSum += rgbErr + da * da;
        rgbSum += w * rgbErr;
        weightSum += w;
        alphaSum += da * da;
    }
    double rawMse = rawSum / ((double)pixels * 4.0);
    double mseRGB = weightSum > 0 ? rgbSum / (3.0 * weightSum) : 0.0;
    double mseA = alphaSum / (double)pixels;
    double mse = (3.0 * mseRGB + mseA) / 4.0;
    *raw = rawMse <= 0.0 ? 99.0 : 10.0 * log10((255.0 * 255.0) / rawMse);
    *weighted = mse <= 0.0 ? 99.0 : 10.0 * log10((255.0 * 255.0) / mse);
}

static struct astcenc_context *zslr_context(ZSLRWorker *worker, int kind) {
    if (worker->contexts[kind]) return worker->contexts[kind];
    os_unfair_lock_lock(&g_zslrParentLock);
    if (!g_zslrParents[kind]) {
        struct astcenc_config config;
        if (zslr_make_config(kind, &config) == ASTCENC_SUCCESS) {
            struct astcenc_context *parent = NULL;
            if (astcenc_context_alloc(&config, 1, &parent, NULL) == ASTCENC_SUCCESS) g_zslrParents[kind] = parent;
        }
    }
    struct astcenc_context *parent = g_zslrParents[kind];
    os_unfair_lock_unlock(&g_zslrParentLock);
    if (!parent) return NULL;
    struct astcenc_context *child = NULL;
    if (astcenc_context_alloc(NULL, 1, &child, parent) != ASTCENC_SUCCESS) return NULL;
    worker->contexts[kind] = child;
    return child;
}

static void zslr_release_worker(ZSLRWorker *worker) {
    for (int i = 0; i < kZSLowResContextKinds; i++) {
        if (worker->contexts[i]) astcenc_context_free(worker->contexts[i]);
        worker->contexts[i] = NULL;
    }
}

static void zslr_release_parents(void) {
    os_unfair_lock_lock(&g_zslrParentLock);
    for (int i = 0; i < kZSLowResContextKinds; i++) {
        if (g_zslrParents[i]) astcenc_context_free(g_zslrParents[i]);
        g_zslrParents[i] = NULL;
    }
    os_unfair_lock_unlock(&g_zslrParentLock);
}

static int zslr_codec_transcode(void *user, const uint8_t *src, size_t srcLen, uint32_t width, uint32_t height, int srgb, uint8_t **out, size_t *outLen, char *why, size_t whyLen) {
    ZSLRWorker *worker = (ZSLRWorker *)user;
    size_t pixels = (size_t)width * height;
    size_t rgbaLen = pixels * 4;
    size_t encodedLen = (size_t)zslr_astc_size(width, height, 8, 8);
    uint8_t *rgba = NULL;
    uint8_t *check = NULL;
    uint8_t *encoded = NULL;
    int result = -1;
    if (why && whyLen) why[0] = 0;

    double phase = CACurrentMediaTime();
    struct astcenc_context *decoder = zslr_context(worker, srgb ? kZSLowResDecodeSRGB : kZSLowResDecodeLinear);
    if (!decoder) {
        ZSLR_WHY("cannot create ASTC decoder context");
        return -1;
    }

    rgba = (uint8_t *)malloc(rgbaLen);
    if (!rgba) {
        ZSLR_WHY("out of memory allocating %zu byte decode buffer", rgbaLen);
        return -1;
    }
    struct astcenc_swizzle swizzle = { ASTCENC_SWZ_R, ASTCENC_SWZ_G, ASTCENC_SWZ_B, ASTCENC_SWZ_A };
    void *slice = rgba;
    struct astcenc_image image = { width, height, 1, ASTCENC_TYPE_U8, &slice };
    enum astcenc_error status = astcenc_decompress_image(decoder, src, srcLen, &image, &swizzle, 0);
    astcenc_decompress_reset(decoder);
    if (status != ASTCENC_SUCCESS) {
        ZSLR_WHY("ASTC decode failed: %s", astcenc_get_error_string(status));
        goto done;
    }
    double decodeMs = ZSLR_MS(phase);

    int hasAlpha = 0;
    for (size_t i = 3; i < rgbaLen; i += 4) {
        if (rgba[i] != 255) {
            hasAlpha = 1;
            break;
        }
    }
    int kind = srgb ? (hasAlpha ? kZSLowResEncodeAlphaSRGB : kZSLowResEncodeOpaqueSRGB)
                    : (hasAlpha ? kZSLowResEncodeAlphaLinear : kZSLowResEncodeOpaqueLinear);

    encoded = (uint8_t *)malloc(encodedLen);
    check = (uint8_t *)malloc(rgbaLen);
    if (!encoded || !check) {
        ZSLR_WHY("out of memory allocating %zu byte encode buffers", encodedLen + rgbaLen);
        goto done;
    }

    double psnr = 0;
    double rawPsnr = 0;
    double encodeMs = 0;
    int passes = 0;
    for (;;) {
        int useKind = passes == 0 ? kind : kind + kZSLowResRescueOffset;
        struct astcenc_context *encoder = zslr_context(worker, useKind);
        if (!encoder) {
            ZSLR_WHY("cannot create ASTC encoder context (kind %d)", useKind);
            goto done;
        }
        phase = CACurrentMediaTime();
        status = astcenc_compress_image(encoder, &image, &swizzle, encoded, encodedLen, 0);
        astcenc_compress_reset(encoder);
        if (status != ASTCENC_SUCCESS) {
            ZSLR_WHY("ASTC 8x8 encode failed: %s", astcenc_get_error_string(status));
            goto done;
        }
        void *checkSlice = check;
        struct astcenc_image checkImage = { width, height, 1, ASTCENC_TYPE_U8, &checkSlice };
        status = astcenc_decompress_image(encoder, encoded, encodedLen, &checkImage, &swizzle, 0);
        astcenc_decompress_reset(encoder);
        if (status != ASTCENC_SUCCESS) {
            ZSLR_WHY("ASTC 8x8 verify decode failed: %s", astcenc_get_error_string(status));
            goto done;
        }
        zslr_measure(rgba, check, pixels, hasAlpha, &psnr, &rawPsnr);
        encodeMs += ZSLR_MS(phase);
        passes++;
        if (psnr >= kZSLowResMinPSNR) break;
        if (passes >= 2 || psnr < kZSLowResMinPSNR - kZSLowResRescueWindowDB) break;
    }

    if (psnr < kZSLowResMinPSNR) {
        ZSLR_WHY("PSNR %.2f dB (raw %.2f) below %.1f dB after %d pass(es) (%s, %s, decode %.0f ms, encode+check %.0f ms)", psnr, rawPsnr, kZSLowResMinPSNR,
                 passes, srgb ? "sRGB" : "linear", hasAlpha ? "alpha" : "opaque", decodeMs, encodeMs);
        result = ZSLR_TRANSCODE_REJECTED;
        goto done;
    }
    ZSLR_WHY("PSNR %.2f dB (raw %.2f), %s pass, %s, %s, decode %.0f ms, encode+check %.0f ms", psnr, rawPsnr, passes == 1 ? "fast" : "rescue",
             srgb ? "sRGB" : "linear", hasAlpha ? "alpha" : "opaque", decodeMs, encodeMs);
    *out = encoded;
    *outLen = encodedLen;
    encoded = NULL;
    result = 0;

done:
    free(rgba);
    free(check);
    free(encoded);
    return result;
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
            if (walker.level > 3) {
                [walker skipDescendants];
                continue;
            }
            if (![rel.lastPathComponent isEqualToString:@"__data"]) continue;
            NSString *full = [root stringByAppendingPathComponent:rel];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if (!attrs) {
                unreadable++;
                continue;
            }
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

- (BOOL)startWithMode:(ZSLowResMode)mode completion:(void (^)(ZSLowResStatus))completion {
    os_unfair_lock_lock(&g_zslrLock);
    if (g_zslrStatus.running) {
        os_unfair_lock_unlock(&g_zslrLock);
        ZLog(@"[LowRes] start ignored: a run is already in progress");
        return NO;
    }
    memset(&g_zslrStatus, 0, sizeof(g_zslrStatus));
    g_zslrStatus.running = YES;
    g_zslrStatus.mode = mode;
    g_zslrCancel = NO;
    g_zslrHoldPaused = NO;
    g_zslrWarningUntil = 0;
    g_zslrNextItem = 0;
    g_zslrLastState = -1;
    g_zslrLastWaitLog = 0;
    g_zslrNoStream = 0;
    g_zslrMaxWorkers = MIN(kZSLowResMaxWorkers, MAX((NSUInteger)1, NSProcessInfo.processInfo.activeProcessorCount));
    os_unfair_lock_unlock(&g_zslrLock);
    ZLog(@"[LowRes] %@ requested, available memory %lld MB", mode == ZSLowResModeScan ? @"scan" : @"transcode", (long long)(zslr_available_memory() / (1024 * 1024)));

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double runStart = CACurrentMediaTime();
        NSFileManager *fm = NSFileManager.defaultManager;
        if (mode == ZSLowResModeTranscode) {
            NSError *dirError = nil;
            if (![fm createDirectoryAtPath:[ZSLowRes stagingDirectory] withIntermediateDirectories:YES attributes:nil error:&dirError]) {
                ZLog(@"[LowRes] cannot create staging directory %@: %@", [ZSLowRes stagingDirectory], dirError.localizedDescription ?: @"unknown error");
            } else {
                ZLog(@"[LowRes] staging directory: %@", [ZSLowRes stagingDirectory]);
            }
            [ZSLowRes loadLedger];
        }
        NSArray<NSDictionary *> *items = [ZSLowRes enumerateBundles];
        unsigned long long totalBytes = 0;
        for (NSDictionary *entry in items) totalBytes += [entry[@"size"] unsignedLongLongValue];
        os_unfair_lock_lock(&g_zslrLock);
        g_zslrItems = items;
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
                    if (!item) break;
                    [ZSLowRes processItem:item mode:mode worker:&worker index:itemIndex total:itemTotal];
                    handled++;
                    os_unfair_lock_lock(&g_zslrLock);
                    g_zslrStatus.activeWorkers--;
                    os_unfair_lock_unlock(&g_zslrLock);
                }
                if (g_zslrCancel) exitReason = "cancelled";
                zslr_release_worker(&worker);
                ZLog(@"[LowRes] worker %lu exiting: %s, %lu bundle(s) handled", (unsigned long)wi, exitReason, (unsigned long)handled);
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        ZLog(@"[LowRes] all workers finished, releasing codec contexts");
        zslr_release_parents();
        if (mode == ZSLowResModeTranscode) [ZSLowRes saveLedger];

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

    ZSLR_LOG(label, "[%lu/%lu] begin: %.1f MB, available %lld MB", (unsigned long)(index + 1), (unsigned long)total, (double)size / 1048576.0,
             (long long)(zslr_available_memory() / (1024 * 1024)));

    if (!scanOnly) {
        os_unfair_lock_lock(&g_zslrLock);
        NSDictionary *entry = g_zslrLedger[key];
        os_unfair_lock_unlock(&g_zslrLock);
        NSString *state = entry[@"state"];
        if (entry && [entry[@"size"] unsignedLongLongValue] == size && fabs([entry[@"mtime"] doubleValue] - mtime) < 0.5 &&
            ([state isEqualToString:@"done"] || [state isEqualToString:@"noop"])) {
            os_unfair_lock_lock(&g_zslrLock);
            g_zslrStatus.bundlesSkipped++;
            g_zslrStatus.bundlesDone++;
            os_unfair_lock_unlock(&g_zslrLock);
            ZSLR_LOG(label, "[%lu/%lu] skipped: ledger state '%s' matches size and mtime", (unsigned long)(index + 1), (unsigned long)total, state.UTF8String ?: "?");
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

    ZSLRCodec codec = { worker, zslr_codec_reserve, zslr_codec_tick, zslr_codec_transcode };
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
    if (rc == ZSLR_ERR || rc == ZSLR_CANCELLED) {
        [fm removeItemAtPath:partPath error:nil];
        [fm removeItemAtPath:[partPath stringByAppendingString:@".scratch"] error:nil];
    }

    os_unfair_lock_lock(&g_zslrLock);
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
                                   @"before": @(result.originalBytes), @"after": @(result.newBytes), @"textures": @(result.converted) };
            g_zslrLedgerDirty++;
        }
        g_zslrStatus.bundlesDone++;
    } else if (rc == ZSLR_DEFERRED) {
        g_zslrStatus.bundlesDeferred++;
        g_zslrStatus.bundlesDone++;
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
        ZSLR_LOG(label, "[%lu/%lu] deferred: not enough memory headroom (%.1fs)", n, t, secs);
    } else if (rc == ZSLR_CANCELLED) {
        ZSLR_LOG(label, "[%lu/%lu] cancelled (%.1fs)", n, t, secs);
    } else if (scanOnly) {
        ZSLR_LOG(label, "[%lu/%lu] scan done: %s, %u candidate(s), %llu -> %llu projected bytes (%.1fs)", n, t, result.outcome ?: "?", result.candidates,
                 (unsigned long long)result.candidateBytes, (unsigned long long)result.newBytes, secs);
    } else if (changed) {
        ZSLR_LOG(label, "[%lu/%lu] written: %u/%u texture(s), %llu -> %llu bytes, %u rejected (%.1fs)", n, t, result.converted, result.candidates,
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
    os_unfair_lock_unlock(&g_zslrLock);
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
        [text appendFormat:@"Bundles scanned: %lu\nCandidate textures: %lu\nASTC 6x6 data: %@\nProjected at 8x8: %@\nProjected saving: %@",
            (unsigned long)s.bundlesDone, (unsigned long)s.texturesCandidate, zslr_bytes(s.candidateBytes), zslr_bytes(s.newBytes),
            zslr_bytes(s.candidateBytes > s.newBytes ? s.candidateBytes - s.newBytes : 0)];
    } else {
        [text appendFormat:@"Bundles processed: %lu (written %lu, skipped %lu, deferred %lu, failed %lu)\nTextures converted: %lu of %lu (rejected on quality: %lu)\nTexture data: %@ -> %@\nSaved: %@\nOutput: Documents/LowRes",
            (unsigned long)s.bundlesDone, (unsigned long)s.bundlesChanged, (unsigned long)s.bundlesSkipped, (unsigned long)s.bundlesDeferred,
            (unsigned long)s.bundlesFailed, (unsigned long)s.texturesConverted, (unsigned long)s.texturesCandidate, (unsigned long)s.texturesRejected,
            zslr_bytes(s.originalBytes), zslr_bytes(s.newBytes), zslr_bytes(s.originalBytes > s.newBytes ? s.originalBytes - s.newBytes : 0)];
    }
    if (s.cancelled) [text appendString:@"\n(cancelled)"];
    return text;
}

@end
