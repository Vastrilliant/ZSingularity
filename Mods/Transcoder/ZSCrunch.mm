#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#pragma clang diagnostic ignored "-Wregister"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <math.h>
#include "Crunch/crn_decomp.h"
#pragma clang diagnostic pop

#import "ZSCrunch.h"
#import "ZTweakLog.h"

static const uint32_t kZSCrunchMaxDimension = 16384u;

static uint32_t zs_crunch_dim(uint32_t base, uint32_t level) {
    uint32_t v = level >= 31u ? 1u : (base >> level);
    return v ? v : 1u;
}

BOOL ZSCrunchReadInfo(NSData *data, ZSCrunchInfo *outInfo, NSString **outFailure) {
    if (!data || data.length < 16 || data.length > UINT32_MAX || !outInfo) {
        if (outFailure) *outFailure = @"Crunch payload is missing or too small.";
        return NO;
    }
    crnd::crn_texture_info info;
    if (!crnd::crnd_get_texture_info(data.bytes, (crnd::uint32)data.length, &info)) {
        if (outFailure) *outFailure = @"Crunch header was rejected by the decoder.";
        return NO;
    }
    outInfo->width = info.m_width;
    outInfo->height = info.m_height;
    outInfo->levels = info.m_levels;
    outInfo->faces = info.m_faces;
    outInfo->bytesPerBlock = info.m_bytes_per_block;
    outInfo->crnFormat = (uint32_t)info.m_format;
    outInfo->userdata0 = info.m_userdata0;
    outInfo->userdata1 = info.m_userdata1;
    ZLog(@"[ZSCrunch] header %ux%u levels=%u faces=%u bytesPerBlock=%u crnFormat=%u userdata0=%u userdata1=%u payload=%lu", outInfo->width, outInfo->height, outInfo->levels, outInfo->faces, outInfo->bytesPerBlock, outInfo->crnFormat, outInfo->userdata0, outInfo->userdata1, (unsigned long)data.length);
    return YES;
}

NSData *ZSCrunchUnpackLevel(NSData *data, uint32_t level, uint32_t *outWidth, uint32_t *outHeight, uint32_t *outBytesPerBlock, NSString **outFailure) {
    ZSCrunchInfo info;
    if (!ZSCrunchReadInfo(data, &info, outFailure)) return nil;
    if (info.faces != 1u) {
        if (outFailure) *outFailure = [NSString stringWithFormat:@"Crunch texture has %u faces; only 2D textures are supported.", info.faces];
        return nil;
    }
    if (level >= info.levels) {
        if (outFailure) *outFailure = [NSString stringWithFormat:@"Crunch level %u requested but the payload only has %u level(s).", level, info.levels];
        return nil;
    }
    if (info.width == 0 || info.height == 0 || info.width > kZSCrunchMaxDimension || info.height > kZSCrunchMaxDimension || (info.bytesPerBlock != 8u && info.bytesPerBlock != 16u)) {
        if (outFailure) *outFailure = [NSString stringWithFormat:@"Crunch header has unsupported geometry %ux%u with %u bytes per block.", info.width, info.height, info.bytesPerBlock];
        return nil;
    }
    uint32_t w = zs_crunch_dim(info.width, level);
    uint32_t h = zs_crunch_dim(info.height, level);
    uint32_t blocksX = MAX(1u, (w + 3u) >> 2);
    uint32_t blocksY = MAX(1u, (h + 3u) >> 2);
    uint32_t pitch = blocksX * info.bytesPerBlock;
    uint64_t total = (uint64_t)pitch * blocksY;
    if (total == 0 || total > UINT32_MAX) {
        if (outFailure) *outFailure = @"Crunch level size is out of range.";
        return nil;
    }
    NSMutableData *blocks = [NSMutableData dataWithLength:(NSUInteger)total];
    if (!blocks) {
        if (outFailure) *outFailure = @"Couldn't allocate Crunch output memory.";
        return nil;
    }
    crnd::crnd_unpack_context context = crnd::crnd_unpack_begin(data.bytes, (crnd::uint32)data.length);
    if (!context) {
        if (outFailure) *outFailure = @"Crunch decoder couldn't begin unpacking the payload.";
        return nil;
    }
    void *destinations[1] = { blocks.mutableBytes };
    bool ok = crnd::crnd_unpack_level(context, destinations, (crnd::uint32)total, pitch, level);
    crnd::crnd_unpack_end(context);
    if (!ok) {
        if (outFailure) *outFailure = [NSString stringWithFormat:@"Crunch decoder failed to unpack level %u.", level];
        return nil;
    }
    ZLog(@"[ZSCrunch] unpacked level %u as %ux%u -> %llu block bytes (pitch=%u)", level, w, h, (unsigned long long)total, pitch);
    if (outWidth) *outWidth = w;
    if (outHeight) *outHeight = h;
    if (outBytesPerBlock) *outBytesPerBlock = info.bytesPerBlock;
    return blocks;
}
