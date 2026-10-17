
#import "GifTint.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import "ZTweakLog.h"

static const CGFloat kZSGifContentY0 = 0.44, kZSGifContentY1 = 0.60;
static const CGFloat kZSGifContentX0 = 0.05, kZSGifContentX1 = 0.95;
static const CGFloat kZSGifPanWindowWidth = 0.45;

static CATextLayerAlignmentMode zs_ca_alignment_for(NSTextAlignment alignment) {
    switch (alignment) {
        case NSTextAlignmentCenter: return kCAAlignmentCenter;
        case NSTextAlignmentRight: return kCAAlignmentRight;
        case NSTextAlignmentJustified: return kCAAlignmentJustified;
        case NSTextAlignmentNatural: return kCAAlignmentNatural;
        case NSTextAlignmentLeft:
        default: return kCAAlignmentLeft;
    }
}

static const CGRect kZSTextTexLayerFrame  = (CGRect){{0, 0}, {480, 72}};
static const CGRect kZSIconTexLayerFrame  = (CGRect){{0, 0}, {80, 80}};
static const CGRect kZSShapeTexLayerFrame = (CGRect){{0, 0}, {400, 32}};
static const CGRect kZSSwitchTexLayerFrame = (CGRect){{0, 0}, {51, 31}};

#pragma mark - Window registration (one per registered element)

typedef NS_ENUM(NSInteger, ZSGifWindowKind) {
    ZSGifWindowKindText,
    ZSGifWindowKindIcon,
    ZSGifWindowKindShape,
    ZSGifWindowKindSwitch,
};

@interface ZSGifWindow : NSObject
@property (nonatomic, weak) UIView *ownerView;
@property (nonatomic, strong) CALayer *texLayer;
@property (nonatomic, strong) CALayer *maskLayer;
@property (nonatomic, assign) ZSGifWindowKind kind;
@property (nonatomic, assign) CGFloat panUnit;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) CGRect texLayerFrame;
@property (nonatomic, assign) BOOL atBack;
@end
@implementation ZSGifWindow
@end

static void zs_teardown_window(ZSGifWindow *w);
static void zs_reapply_window(ZSGifWindow *w);
static void zs_restore_switch_native_tint(ZSGifWindow *w);
static void zs_set_switch_texture_driven(UISwitch *sw, BOOL textureDriven);

#pragma mark - Engine: decode + per-tick contents swap only

@interface ZSGifTintEngine : NSObject
+ (instancetype)sharedEngine;
- (nullable UIImage *)currentOrFirstFrame;
- (void)addWindow:(ZSGifWindow *)window;
- (void)setEnginePaused:(BOOL)paused;
- (void)teardownAllWindows;
- (void)reconstructAllWindows;
- (void)setDisabled:(BOOL)disabled;
- (BOOL)isDisabled;
@end

@implementation ZSGifTintEngine {
    NSArray<UIImage *> *_frames;
    NSArray<NSNumber *> *_frameDurations;
    NSTimeInterval _totalDuration;

    CADisplayLink *_displayLink;
    NSTimeInterval _startTime;
    NSInteger _lastFrameIndex;
    BOOL _paused;
    BOOL _disabled;
    BOOL _decodeStarted;
    BOOL _fetchInFlight;
    CFTimeInterval _lastFetchFailure;
    NSUInteger _buildGeneration;
    uint64_t _activeGifLength;
    uint64_t _activeGifHash;
    dispatch_queue_t _buildQueue;

    NSHashTable<ZSGifWindow *> *_windows;
}

+ (instancetype)sharedEngine {
    static ZSGifTintEngine *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [ZSGifTintEngine new]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastFrameIndex = -1;
        _windows = [NSHashTable weakObjectsHashTable];
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _buildQueue = dispatch_queue_create("zs.gifTint.build", attr);
    }
    return self;
}

#pragma mark Decoding (source: full-resolution Enkephalin.gif, fetched from the repo)

static const CGFloat kZSGifPlaybackRate = 0.5;
static const NSInteger kZSGifCrossfadeSteps = 8;
static const uint32_t kZSGifCacheMagic = 0x5A474946;
static const uint32_t kZSGifCacheVersion = 1;
static const size_t kZSGifCacheHeaderBytes = 16384;
static const size_t kZSGifCacheRowAlignment = 64;

static NSString * const kZSGifRepoOwner = @"vastrilliant";
static NSString * const kZSGifRepoName = @"ZSingularity";
static NSString * const kZSGifRepoBranch = @"main";
static NSString * const kZSGifRepoPath = @"Resources/Enkephalin.gif";
static const NSTimeInterval kZSGifFetchTimeout = 120.0;
static const CFTimeInterval kZSGifFetchRetryInterval = 60.0;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t gifLength;
    uint64_t gifHash;
    uint32_t frameCount;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint64_t frameBytes;
    double cropX0;
    double cropX1;
    double cropY0;
    double cropY1;
} ZSGifCacheHeader;

static uint64_t zs_gif_fingerprint(NSData *data) {
    const uint8_t *bytes = data.bytes;
    uint64_t hash = 1469598103934665603ULL ^ (uint64_t)data.length;
    for (NSUInteger i = 0; i < data.length; i += 4096) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static NSString *zs_gif_directory(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!caches) return nil;
    NSString *dir = [caches stringByAppendingPathComponent:@"ZSGifTint"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *zs_gif_cache_path(void) {
    return [zs_gif_directory() stringByAppendingPathComponent:@"enkephalin.frames"];
}

static NSString *zs_gif_source_path(void) {
    return [zs_gif_directory() stringByAppendingPathComponent:@"Enkephalin.gif"];
}

static NSString *zs_gif_etag_path(void) {
    return [zs_gif_directory() stringByAppendingPathComponent:@"Enkephalin.gif.etag"];
}

static NSURL *zs_gif_remote_url(void) {
    NSString *urlString = [NSString stringWithFormat:@"https://raw.githubusercontent.com/%@/%@/%@/%@",
                           kZSGifRepoOwner, kZSGifRepoName, kZSGifRepoBranch, kZSGifRepoPath];
    return [NSURL URLWithString:urlString];
}

static NSData *zs_local_gif_data(void) {
    NSString *path = zs_gif_source_path();
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    return data.length > 0 ? data : nil;
}

static void zs_gif_discard_local_source(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *source = zs_gif_source_path();
    NSString *etag = zs_gif_etag_path();
    if (source) [fm removeItemAtPath:source error:nil];
    if (etag) [fm removeItemAtPath:etag error:nil];
}

typedef NS_ENUM(NSInteger, ZSGifFetchResult) {
    ZSGifFetchResultFailed,
    ZSGifFetchResultNotModified,
    ZSGifFetchResultUpdated,
};

static void zs_gif_fetch_remote(void (^completion)(ZSGifFetchResult result)) {
    NSString *sourcePath = zs_gif_source_path();
    NSString *etagPath = zs_gif_etag_path();
    NSURL *url = zs_gif_remote_url();
    if (!sourcePath || !etagPath || !url) {
        completion(ZSGifFetchResultFailed);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    request.timeoutInterval = kZSGifFetchTimeout;
    if ([[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        NSString *etag = [NSString stringWithContentsOfFile:etagPath encoding:NSUTF8StringEncoding error:nil];
        if (etag.length > 0) [request setValue:etag forHTTPHeaderField:@"If-None-Match"];
    }

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:request
        completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (!error && http.statusCode == 304) {
                completion(ZSGifFetchResultNotModified);
                return;
            }
            if (error || http.statusCode != 200 || !location) {
                ZLog(@"[ZSGifTint] download failed (%ld): %@", (long)http.statusCode, error.localizedDescription ?: url.absoluteString);
                completion(ZSGifFetchResultFailed);
                return;
            }

            NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:location error:nil];
            NSData *head = [handle readDataOfLength:4];
            [handle closeFile];
            if (head.length < 4 || memcmp(head.bytes, "GIF8", 4) != 0) {
                ZLog(@"[ZSGifTint] downloaded file is not a GIF - ignoring");
                completion(ZSGifFetchResultFailed);
                return;
            }

            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *tempPath = [sourcePath stringByAppendingString:@".tmp"];
            [fm removeItemAtPath:tempPath error:nil];
            NSError *moveError = nil;
            if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:tempPath] error:&moveError]
                || rename(tempPath.fileSystemRepresentation, sourcePath.fileSystemRepresentation) != 0) {
                ZLog(@"[ZSGifTint] couldn't store downloaded GIF: %@", moveError.localizedDescription ?: @"rename failed");
                [fm removeItemAtPath:tempPath error:nil];
                completion(ZSGifFetchResultFailed);
                return;
            }

            NSString *etag = [http valueForHTTPHeaderField:@"ETag"];
            if (etag.length > 0) {
                [etag writeToFile:etagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                [fm removeItemAtPath:etagPath error:nil];
            }
            completion(ZSGifFetchResultUpdated);
        }];
    [task resume];
}

static BOOL zs_gif_write_all(int fd, const void *bytes, size_t length, off_t offset) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t written = pwrite(fd, cursor, length, offset);
        if (written <= 0) return NO;
        cursor += written;
        offset += written;
        length -= (size_t)written;
    }
    return YES;
}

static BOOL zs_gif_build_cache(NSData *gifData, NSString *finalPath) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)gifData, (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCGImageSourceShouldCache: @NO,
    });
    if (!source) return NO;

    size_t count = CGImageSourceGetCount(source);
    if (count == 0 || count + kZSGifCrossfadeSteps > (kZSGifCacheHeaderBytes - sizeof(ZSGifCacheHeader)) / sizeof(double)) {
        CFRelease(source);
        return NO;
    }

    NSDictionary *firstProps = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    size_t fullWidth = [firstProps[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongValue];
    size_t fullHeight = [firstProps[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongValue];
    if (fullWidth == 0 || fullHeight == 0) {
        CFRelease(source);
        return NO;
    }

    size_t cropX0 = (size_t)floor(kZSGifContentX0 * fullWidth);
    size_t cropX1 = MIN(fullWidth, (size_t)ceil(kZSGifContentX1 * fullWidth));
    size_t cropY0 = (size_t)floor(kZSGifContentY0 * fullHeight);
    size_t cropY1 = MIN(fullHeight, (size_t)ceil(kZSGifContentY1 * fullHeight));
    size_t width = cropX1 - cropX0;
    size_t height = cropY1 - cropY0;
    size_t bytesPerRow = ((width * 4 + kZSGifCacheRowAlignment - 1) / kZSGifCacheRowAlignment) * kZSGifCacheRowAlignment;
    size_t frameBytes = bytesPerRow * height;

    NSString *tempPath = [finalPath stringByAppendingString:@".tmp"];
    unlink(tempPath.fileSystemRepresentation);
    int fd = open(tempPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        CFRelease(source);
        return NO;
    }

    uint8_t *scratch = calloc(1, frameBytes);
    uint8_t *firstFrame = calloc(1, frameBytes);
    uint8_t *lastFrame = calloc(1, frameBytes);
    uint8_t *blendFrame = calloc(1, frameBytes);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:count + kZSGifCrossfadeSteps];
    BOOL ok = scratch && firstFrame && lastFrame && blendFrame && colorSpace;
    size_t written = 0;

    for (size_t i = 0; ok && i < count; i++) {
        @autoreleasepool {
            CGImageRef image = CGImageSourceCreateImageAtIndex(source, i, (__bridge CFDictionaryRef)@{
                (__bridge NSString *)kCGImageSourceShouldCache: @NO,
            });
            if (!image) {
                ok = NO;
            } else {
                memset(scratch, 0, frameBytes);
                CGContextRef ctx = CGBitmapContextCreate(scratch, width, height, 8, bytesPerRow, colorSpace,
                    (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
                if (!ctx) {
                    ok = NO;
                } else {
                    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
                    CGContextDrawImage(ctx, CGRectMake(-(CGFloat)cropX0, -(CGFloat)(fullHeight - cropY1), (CGFloat)fullWidth, (CGFloat)fullHeight), image);
                    CGContextRelease(ctx);
                    ok = zs_gif_write_all(fd, scratch, frameBytes, (off_t)(kZSGifCacheHeaderBytes + written * frameBytes));
                    if (ok) {
                        if (i == 0) memcpy(firstFrame, scratch, frameBytes);
                        if (i == count - 1) memcpy(lastFrame, scratch, frameBytes);
                        written++;

                        NSTimeInterval duration = 0.06;
                        NSDictionary *props = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, i, NULL);
                        NSDictionary *gifProps = props[(__bridge NSString *)kCGImagePropertyGIFDictionary];
                        NSNumber *unclamped = gifProps[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime];
                        NSNumber *clamped = gifProps[(__bridge NSString *)kCGImagePropertyGIFDelayTime];
                        NSNumber *chosen = unclamped ?: clamped;
                        if (chosen && chosen.doubleValue > 0.0) duration = chosen.doubleValue;
                        [durations addObject:@(duration / kZSGifPlaybackRate)];
                    }
                }
                CGImageRelease(image);
            }
        }
    }
    CFRelease(source);

    if (ok && count > 1) {
        NSTimeInterval stepDuration = durations.firstObject.doubleValue > 0 ? durations.firstObject.doubleValue : 0.06;
        for (NSInteger step = 1; ok && step <= kZSGifCrossfadeSteps; step++) {
            float t = (float)step / (float)(kZSGifCrossfadeSteps + 1);
            for (size_t row = 0; row < height; row++) {
                const uint8_t *from = lastFrame + row * bytesPerRow;
                const uint8_t *to = firstFrame + row * bytesPerRow;
                uint8_t *out = blendFrame + row * bytesPerRow;
                for (size_t x = 0; x < width; x++) {
                    float toAlpha = to[x * 4 + 3] / 255.0f;
                    float fromWeight = 1.0f - t * toAlpha;
                    for (int c = 0; c < 4; c++) {
                        float v = to[x * 4 + c] * t + from[x * 4 + c] * fromWeight;
                        out[x * 4 + c] = (uint8_t)MIN(255.0f, v + 0.5f);
                    }
                }
            }
            ok = zs_gif_write_all(fd, blendFrame, frameBytes, (off_t)(kZSGifCacheHeaderBytes + written * frameBytes));
            if (ok) {
                written++;
                [durations addObject:@(stepDuration)];
            }
        }
    }

    if (ok) {
        ZSGifCacheHeader header = {
            .magic = kZSGifCacheMagic,
            .version = kZSGifCacheVersion,
            .gifLength = gifData.length,
            .gifHash = zs_gif_fingerprint(gifData),
            .frameCount = (uint32_t)written,
            .width = (uint32_t)width,
            .height = (uint32_t)height,
            .bytesPerRow = (uint32_t)bytesPerRow,
            .frameBytes = frameBytes,
            .cropX0 = kZSGifContentX0,
            .cropX1 = kZSGifContentX1,
            .cropY0 = kZSGifContentY0,
            .cropY1 = kZSGifContentY1,
        };
        double *durationValues = calloc(written, sizeof(double));
        for (size_t i = 0; i < written; i++) durationValues[i] = durations[i].doubleValue;
        ok = zs_gif_write_all(fd, &header, sizeof(header), 0)
            && zs_gif_write_all(fd, durationValues, written * sizeof(double), (off_t)sizeof(header));
        free(durationValues);
    }

    free(scratch);
    free(firstFrame);
    free(lastFrame);
    free(blendFrame);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    close(fd);

    if (!ok) {
        unlink(tempPath.fileSystemRepresentation);
        return NO;
    }
    unlink(finalPath.fileSystemRepresentation);
    return rename(tempPath.fileSystemRepresentation, finalPath.fileSystemRepresentation) == 0;
}

static BOOL zs_gif_load_cache(NSData *gifData, NSString *path, NSArray<UIImage *> **outFrames, NSArray<NSNumber *> **outDurations) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;

    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < kZSGifCacheHeaderBytes) {
        close(fd);
        return NO;
    }

    void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return NO;

    const ZSGifCacheHeader *header = map;
    BOOL valid = header->magic == kZSGifCacheMagic
        && header->version == kZSGifCacheVersion
        && header->gifLength == gifData.length
        && header->gifHash == zs_gif_fingerprint(gifData)
        && header->frameCount > 0
        && header->frameCount <= (kZSGifCacheHeaderBytes - sizeof(ZSGifCacheHeader)) / sizeof(double)
        && header->frameBytes == (uint64_t)header->bytesPerRow * header->height
        && (uint64_t)st.st_size == kZSGifCacheHeaderBytes + (uint64_t)header->frameCount * header->frameBytes
        && header->cropX0 == kZSGifContentX0 && header->cropX1 == kZSGifContentX1
        && header->cropY0 == kZSGifContentY0 && header->cropY1 == kZSGifContentY1;
    if (!valid) {
        munmap(map, (size_t)st.st_size);
        return NO;
    }

    const double *durationValues = (const double *)((const uint8_t *)map + sizeof(ZSGifCacheHeader));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:header->frameCount];
    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:header->frameCount];

    for (uint32_t i = 0; i < header->frameCount; i++) {
        const uint8_t *frameBase = (const uint8_t *)map + kZSGifCacheHeaderBytes + (size_t)i * header->frameBytes;
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, frameBase, header->frameBytes, NULL);
        CGImageRef image = provider ? CGImageCreate(header->width, header->height, 8, 32, header->bytesPerRow, colorSpace,
            (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
            provider, NULL, false, kCGRenderingIntentDefault) : NULL;
        if (provider) CGDataProviderRelease(provider);
        if (!image) {
            if (colorSpace) CGColorSpaceRelease(colorSpace);
            munmap(map, (size_t)st.st_size);
            return NO;
        }
        [frames addObject:[UIImage imageWithCGImage:image scale:1.0 orientation:UIImageOrientationUp]];
        CGImageRelease(image);
        [durations addObject:@(durationValues[i])];
    }
    if (colorSpace) CGColorSpaceRelease(colorSpace);

    *outFrames = frames;
    *outDurations = durations;
    return YES;
}

- (void)zs_applyLoadedFrames:(NSArray<UIImage *> *)frames durations:(NSArray<NSNumber *> *)durations {
    _frames = frames;
    _frameDurations = durations;
    _totalDuration = 0;
    for (NSNumber *d in durations) _totalDuration += d.doubleValue;
    _lastFrameIndex = -1;
    ZLog(@"[ZSGifTint] mapped %lu file-backed frame(s) (with crossfade padding), total loop duration %.2fs", (unsigned long)_frames.count, _totalDuration);
    [self startOrStopDisplayLinkAsNeeded];
}

- (void)zs_applyLoadedFrames:(NSArray<UIImage *> *)frames durations:(NSArray<NSNumber *> *)durations fromGifData:(NSData *)gifData {
    _activeGifLength = gifData.length;
    _activeGifHash = zs_gif_fingerprint(gifData);
    [self zs_applyLoadedFrames:frames durations:durations];
}

- (void)zs_buildFramesFromGifData:(NSData *)data cachePath:(NSString *)cachePath {
    NSUInteger generation = ++_buildGeneration;
    dispatch_async(_buildQueue, ^{
        NSArray<UIImage *> *builtFrames = nil;
        NSArray<NSNumber *> *builtDurations = nil;
        BOOL ok = zs_gif_load_cache(data, cachePath, &builtFrames, &builtDurations)
            || (zs_gif_build_cache(data, cachePath) && zs_gif_load_cache(data, cachePath, &builtFrames, &builtDurations));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_buildGeneration) return;
            if (!ok) {
                ZLog(@"[ZSGifTint] failed to build the full-resolution frame cache - accent tint disabled");
                zs_gif_discard_local_source();
                return;
            }
            [self zs_applyLoadedFrames:builtFrames durations:builtDurations fromGifData:data];
        });
    });
}

- (void)zs_refreshRemoteGifWithCachePath:(NSString *)cachePath {
    if (_fetchInFlight) return;
    _fetchInFlight = YES;
    zs_gif_fetch_remote(^(ZSGifFetchResult result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_fetchInFlight = NO;
            if (result == ZSGifFetchResultFailed) {
                if (self->_frames.count == 0 && self->_buildGeneration == 0) {
                    self->_decodeStarted = NO;
                    self->_lastFetchFailure = CACurrentMediaTime();
                }
                return;
            }
            self->_lastFetchFailure = 0;
            if (result == ZSGifFetchResultNotModified) return;

            NSData *data = zs_local_gif_data();
            if (!data) return;
            if (self->_frames.count > 0
                && data.length == self->_activeGifLength
                && zs_gif_fingerprint(data) == self->_activeGifHash) return;
            [self zs_buildFramesFromGifData:data cachePath:cachePath];
        });
    });
}

- (void)decodeFramesIfNeeded {
    if (_disabled || _decodeStarted || _frames.count > 0) return;
    if (_lastFetchFailure > 0 && CACurrentMediaTime() - _lastFetchFailure < kZSGifFetchRetryInterval) return;
    _decodeStarted = YES;

    NSString *cachePath = zs_gif_cache_path();
    if (!cachePath) {
        ZLog(@"[ZSGifTint] couldn't find a cache directory - accent tint disabled");
        _frames = @[];
        _frameDurations = @[];
        return;
    }

    _frames = @[];
    _frameDurations = @[];

    NSData *data = zs_local_gif_data();
    if (data) {
        NSArray<UIImage *> *frames = nil;
        NSArray<NSNumber *> *durations = nil;
        if (zs_gif_load_cache(data, cachePath, &frames, &durations)) {
            [self zs_applyLoadedFrames:frames durations:durations fromGifData:data];
        } else {
            [self zs_buildFramesFromGifData:data cachePath:cachePath];
        }
    }

    [self zs_refreshRemoteGifWithCachePath:cachePath];
}

- (nullable UIImage *)currentOrFirstFrame {
    [self decodeFramesIfNeeded];
    if (_lastFrameIndex >= 0 && _lastFrameIndex < (NSInteger)_frames.count) return _frames[_lastFrameIndex];
    return _frames.firstObject;
}

#pragma mark Window registration

- (void)addWindow:(ZSGifWindow *)window {
    [self decodeFramesIfNeeded];
    [_windows addObject:window];
    [self startOrStopDisplayLinkAsNeeded];
}

- (void)setEnginePaused:(BOOL)paused {
    if (_paused == paused) return;
    _paused = paused;
    [self startOrStopDisplayLinkAsNeeded];
}

- (void)teardownAllWindows {
    for (ZSGifWindow *w in _windows) {
        zs_teardown_window(w);
    }
}

- (void)reconstructAllWindows {
    [self decodeFramesIfNeeded];
    if (_disabled) return;
    for (ZSGifWindow *w in _windows) {
        zs_reapply_window(w);
    }
}

- (void)setDisabled:(BOOL)disabled {
    if (_disabled != disabled) {
        _disabled = disabled;
        if (disabled) {
            [self teardownAllWindows];
            for (ZSGifWindow *w in _windows) {
                zs_restore_switch_native_tint(w);
            }
        } else if (!_paused) {
            [self reconstructAllWindows];
        }
    }
    if (!_disabled) [self decodeFramesIfNeeded];
}

- (BOOL)isDisabled {
    return _disabled;
}

- (void)startOrStopDisplayLinkAsNeeded {
    BOOL needsLink = (_windows.count > 0) && (_frames.count > 0) && !_paused;
    if (needsLink && !_displayLink) {
        ZLog(@"[ZSGifTint] starting display link for %lu registered window(s)", (unsigned long)_windows.count);
        _startTime = CACurrentMediaTime();
        _lastFrameIndex = -1;
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!needsLink && _displayLink) {
        ZLog(@"[ZSGifTint] stopping display link, no registered windows remain");
        [_displayLink invalidate];
        _displayLink = nil;
    }
}

#pragma mark Timer-driven: advance frame + swap contents on every registered texLayer

- (void)tick:(nullable CADisplayLink *)link {
    if (_frames.count == 0 || _totalDuration <= 0) return;

    NSTimeInterval elapsed = fmod(CACurrentMediaTime() - _startTime, _totalDuration);
    NSTimeInterval cursor = 0;
    NSInteger index = 0;
    for (NSInteger i = 0; i < (NSInteger)_frameDurations.count; i++) {
        cursor += _frameDurations[i].doubleValue;
        if (elapsed < cursor) { index = i; break; }
        index = i;
    }
    if (index == _lastFrameIndex) return;
    _lastFrameIndex = index;

    UIImage *frame = _frames[index];
    if (!frame) return;
    id contents = (__bridge id)frame.CGImage;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (ZSGifWindow *w in _windows) {
        if (!w.active) continue;
        w.texLayer.contents = contents;
    }
    [CATransaction commit];
}

@end

#pragma mark - Public: preload

void zs_gif_tint_preload(void) {
    (void)[ZSGifTintEngine sharedEngine];
}

void zs_gif_tint_set_paused(BOOL paused) {
    [[ZSGifTintEngine sharedEngine] setEnginePaused:paused];
}

void zs_gif_tint_teardown_all(void) {
    [[ZSGifTintEngine sharedEngine] teardownAllWindows];
}

void zs_gif_tint_reconstruct_all(void) {
    [[ZSGifTintEngine sharedEngine] reconstructAllWindows];
}

void zs_gif_tint_set_disabled(BOOL disabled) {
    [[ZSGifTintEngine sharedEngine] setDisabled:disabled];
}

BOOL zs_gif_tint_is_disabled(void) {
    return [[ZSGifTintEngine sharedEngine] isDisabled];
}

#pragma mark - Associated-object bookkeeping shared by all three kinds

static const void *kZSGifWindowKey = &kZSGifWindowKey;

static CGFloat zs_pan_unit_for_owner(UIView *owner) {
    uintptr_t addr = (uintptr_t)(__bridge void *)owner;
    uint32_t h = (uint32_t)(addr ^ (addr >> 16));
    h ^= h >> 16; h *= 0x7feb352dU;
    h ^= h >> 15; h *= 0x846ca68bU;
    h ^= h >> 16;
    return (CGFloat)(h % 10000) / 10000.0;
}

static CGRect zs_gif_content_rect(CGFloat panUnit) {
    CGFloat range = (kZSGifContentX1 - kZSGifContentX0) - kZSGifPanWindowWidth;
    CGFloat cropWidth = kZSGifContentX1 - kZSGifContentX0;
    CGFloat x0 = panUnit * range / cropWidth;
    return CGRectMake(x0, 0.0, kZSGifPanWindowWidth / cropWidth, 1.0);
}

static ZSGifWindow *zs_register(UIView *owner, ZSGifWindowKind kind, CALayer *maskLayer, CGRect texLayerFrame, BOOL atBack) {
    ZSGifWindow *w = objc_getAssociatedObject(owner, kZSGifWindowKey);
    if (w) {
        [w.texLayer removeFromSuperlayer];
    } else {
        w = [ZSGifWindow new];
        w.panUnit = zs_pan_unit_for_owner(owner);
        objc_setAssociatedObject(owner, kZSGifWindowKey, w, OBJC_ASSOCIATION_RETAIN);
    }
    w.ownerView = owner;
    w.kind = kind;
    w.texLayerFrame = texLayerFrame;
    w.atBack = atBack;

    if ([[ZSGifTintEngine sharedEngine] isDisabled]) {
        w.texLayer = nil;
        w.maskLayer = nil;
        w.active = NO;
        [[ZSGifTintEngine sharedEngine] addWindow:w];
        return w;
    }
    w.active = YES;

    CALayer *tex = [CALayer new];
    tex.frame = texLayerFrame;
    tex.contentsRect = zs_gif_content_rect(w.panUnit);
    tex.contentsGravity = kCAGravityResizeAspectFill;
    tex.contentsScale = UIScreen.mainScreen.scale;
    tex.mask = maskLayer;
    UIImage *current = [[ZSGifTintEngine sharedEngine] currentOrFirstFrame];
    if (current) tex.contents = (__bridge id)current.CGImage;
    if (atBack) {
        [owner.layer insertSublayer:tex atIndex:0];
    } else {
        [owner.layer addSublayer:tex];
    }

    w.texLayer = tex;
    w.maskLayer = maskLayer;
    [[ZSGifTintEngine sharedEngine] addWindow:w];
    return w;
}

static void zs_unregister(UIView *owner) {
    ZSGifWindow *w = objc_getAssociatedObject(owner, kZSGifWindowKey);
    [w.texLayer removeFromSuperlayer];
    objc_setAssociatedObject(owner, kZSGifWindowKey, nil, OBJC_ASSOCIATION_RETAIN);
}

static void zs_teardown_window(ZSGifWindow *w) {
    if (!w || !w.texLayer) return;
    [w.texLayer removeFromSuperlayer];
    w.texLayer.contents = nil;
    w.texLayer.mask = nil;
    w.texLayer = nil;
    w.maskLayer = nil;
    w.active = NO;
}

void zs_set_gif_window_active(UIView *view, BOOL active) {
    if (!view) return;
    ZSGifWindow *w = objc_getAssociatedObject(view, kZSGifWindowKey);
    if (w) w.active = active;
}

#pragma mark - Text tint

static void zs_refresh_text_mask_if_registered(UILabel *label);

static void zs_safely_swizzle(Class cls, SEL origSel, SEL replSel) {
    Method original = class_getInstanceMethod(cls, origSel);
    Method replacement = class_getInstanceMethod(cls, replSel);
    if (!original || !replacement) return;

    BOOL addedOwnOverride = class_addMethod(cls, origSel,
                                             method_getImplementation(replacement),
                                             method_getTypeEncoding(replacement));
    if (addedOwnOverride) {
        class_replaceMethod(cls, replSel,
                             method_getImplementation(original),
                             method_getTypeEncoding(original));
    } else {
        method_exchangeImplementations(original, replacement);
    }
}

@interface UILabel (ZSGifTintSwizzle)
@end
@implementation UILabel (ZSGifTintSwizzle)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = self;
        SEL pairs[][2] = {
            {@selector(setText:), @selector(zs_gifTint_setText:)},
            {@selector(setAttributedText:), @selector(zs_gifTint_setAttributedText:)},
            {@selector(layoutSubviews), @selector(zs_gifTint_layoutSubviews)},
        };
        for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
            zs_safely_swizzle(cls, pairs[i][0], pairs[i][1]);
        }
    });
}

- (void)zs_gifTint_setText:(NSString *)text {
    [self zs_gifTint_setText:text];
    zs_refresh_text_mask_if_registered(self);
}

- (void)zs_gifTint_setAttributedText:(NSAttributedString *)attributedText {
    [self zs_gifTint_setAttributedText:attributedText];
    zs_refresh_text_mask_if_registered(self);
}

- (void)zs_gifTint_layoutSubviews {
    [self zs_gifTint_layoutSubviews];
    zs_refresh_text_mask_if_registered(self);
}

@end

static void zs_refresh_text_mask_if_registered(UILabel *label) {
    ZSGifWindow *w = objc_getAssociatedObject(label, kZSGifWindowKey);
    if (!w || w.kind != ZSGifWindowKindText) return;

    CATextLayer *mask = (CATextLayer *)w.maskLayer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = label.bounds;
    mask.alignmentMode = zs_ca_alignment_for(label.textAlignment);
    mask.truncationMode = kCATruncationEnd;
    mask.wrapped = (label.numberOfLines != 1);
    mask.contentsScale = UIScreen.mainScreen.scale;
    if (label.attributedText.length > 0) {
        mask.string = label.attributedText;
    } else {
        mask.string = label.text ?: @"";
        UIFont *font = label.font ?: [UIFont systemFontOfSize:[UIFont systemFontSize]];
        CTFontRef ctFont = CTFontCreateWithName((__bridge CFStringRef)font.fontName, font.pointSize, NULL);
        if (ctFont) {
            mask.font = ctFont;
            mask.fontSize = font.pointSize;
            CFRelease(ctFont);
        }
    }
    [CATransaction commit];
}

void zs_apply_gif_text_tint(UILabel *label) {
    if (!label) return;
    zs_gif_tint_preload();
    CATextLayer *mask = [CATextLayer new];
    zs_register(label, ZSGifWindowKindText, mask, kZSTextTexLayerFrame, NO);
    zs_refresh_text_mask_if_registered(label);
}

void zs_remove_gif_text_tint(UILabel *label) {
    if (!label) return;
    zs_unregister(label);
}

#pragma mark - Icon tint

void zs_apply_gif_icon_tint(UIImageView *imageView) {
    if (!imageView || !imageView.image) return;
    zs_gif_tint_preload();
    imageView.tintColor = UIColor.clearColor;

    CALayer *mask = [CALayer new];
    ZSGifWindow *w = zs_register(imageView, ZSGifWindowKindIcon, mask, kZSIconTexLayerFrame, NO);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = imageView.bounds;
    mask.contentsGravity = kCAGravityResizeAspect;
    mask.contents = (__bridge id)imageView.image.CGImage;
    [CATransaction commit];
    (void)w;
}

void zs_remove_gif_icon_tint(UIImageView *imageView) {
    if (!imageView) return;
    zs_unregister(imageView);
}

#pragma mark - Generic shape/view tint (slider capsule fill, etc.)

void zs_apply_gif_view_tint(UIView *view) {
    if (!view) return;
    zs_gif_tint_preload();
    CAShapeLayer *mask = [CAShapeLayer new];
    zs_register(view, ZSGifWindowKindShape, mask, kZSShapeTexLayerFrame, NO);
}

void zs_refresh_gif_view_tint(UIView *view, CGRect bounds) {
    if (!view) return;
    ZSGifWindow *w = objc_getAssociatedObject(view, kZSGifWindowKey);
    if (!w || w.kind != ZSGifWindowKindShape) return;

    CAShapeLayer *mask = (CAShapeLayer *)w.maskLayer;
    CAShapeLayer *sourceShape = [view.layer.mask isKindOfClass:[CAShapeLayer class]]
        ? (CAShapeLayer *)view.layer.mask : nil;

    mask.frame = bounds;
    if (sourceShape.path) {
        mask.path = sourceShape.path;
    } else {
        CGFloat r = view.layer.cornerRadius;
        mask.path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:r].CGPath;
    }
}

void zs_remove_gif_view_tint(UIView *view) {
    if (!view) return;
    zs_unregister(view);
}

#pragma mark - iOS stock toggle tint (UISwitch "on"/green track)

static void zs_refresh_switch_mask_if_registered(UISwitch *sw);

@interface UISwitch (ZSGifTintSwizzle)
@end
@implementation UISwitch (ZSGifTintSwizzle)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        zs_safely_swizzle(self, @selector(layoutSubviews), @selector(zs_gifTint_switch_layoutSubviews));
    });
}

- (void)zs_gifTint_switch_layoutSubviews {
    [self zs_gifTint_switch_layoutSubviews];
    zs_refresh_switch_mask_if_registered(self);
}

- (void)zs_gifTint_switchValueChanged {
    ZSGifWindow *w = objc_getAssociatedObject(self, kZSGifWindowKey);
    if (!w || w.kind != ZSGifWindowKindSwitch) return;

    CGFloat target = self.isOn ? 1.0 : 0.0;
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"opacity"];
    anim.fromValue = @(w.texLayer.opacity);
    anim.toValue = @(target);
    anim.duration = 0.25;
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [w.texLayer addAnimation:anim forKey:@"zs_gifTint_switchFade"];
    w.texLayer.opacity = target;
}

@end

static void zs_refresh_switch_mask_if_registered(UISwitch *sw) {
    ZSGifWindow *w = objc_getAssociatedObject(sw, kZSGifWindowKey);
    if (!w || w.kind != ZSGifWindowKindSwitch) return;

    CAShapeLayer *mask = (CAShapeLayer *)w.maskLayer;
    CGRect bounds = sw.bounds;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    w.texLayer.frame = bounds;
    mask.frame = bounds;
    mask.path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:bounds.size.height / 2.0].CGPath;
    [CATransaction commit];
}

void zs_apply_gif_switch_tint(UISwitch *sw) {
    if (!sw) return;
    zs_gif_tint_preload();

    CAShapeLayer *mask = [CAShapeLayer new];
    ZSGifWindow *w = zs_register(sw, ZSGifWindowKindSwitch, mask, kZSSwitchTexLayerFrame, YES);
    zs_set_switch_texture_driven(sw, w.texLayer != nil);
    w.texLayer.opacity = sw.isOn ? 1.0f : 0.0f;
    zs_refresh_switch_mask_if_registered(sw);

    [sw addTarget:sw action:@selector(zs_gifTint_switchValueChanged) forControlEvents:UIControlEventValueChanged];
}

static UIColor *zs_switch_native_on_tint(void) {
    return [UIColor colorWithRed:0x30 / 255.0 green:0xD1 / 255.0 blue:0x58 / 255.0 alpha:1.0];
}

static void zs_set_switch_texture_driven(UISwitch *sw, BOOL textureDriven) {
    sw.onTintColor = textureDriven ? UIColor.clearColor : zs_switch_native_on_tint();
}

static void zs_restore_switch_native_tint(ZSGifWindow *w) {
    if (!w || w.kind != ZSGifWindowKindSwitch) return;
    UISwitch *sw = (UISwitch *)w.ownerView;
    if (!sw) return;
    zs_set_switch_texture_driven(sw, NO);
}

void zs_remove_gif_switch_tint(UISwitch *sw) {
    if (!sw) return;
    sw.onTintColor = nil;
    [sw removeTarget:sw action:@selector(zs_gifTint_switchValueChanged) forControlEvents:UIControlEventValueChanged];
    zs_unregister(sw);
}

#pragma mark - Teardown / reconstruct dispatch

static void zs_reapply_window(ZSGifWindow *w) {
    if (!w || !w.ownerView || w.texLayer) return;

    CALayer *mask = nil;
    switch (w.kind) {
        case ZSGifWindowKindText: mask = [CATextLayer new]; break;
        case ZSGifWindowKindIcon: mask = [CALayer new]; break;
        case ZSGifWindowKindShape: mask = [CAShapeLayer new]; break;
        case ZSGifWindowKindSwitch: mask = [CAShapeLayer new]; break;
    }
    zs_register(w.ownerView, w.kind, mask, w.texLayerFrame, w.atBack);

    switch (w.kind) {
        case ZSGifWindowKindText:
            zs_refresh_text_mask_if_registered((UILabel *)w.ownerView);
            break;
        case ZSGifWindowKindIcon: {
            UIImageView *iv = (UIImageView *)w.ownerView;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            w.texLayer.frame = iv.bounds;
            w.texLayer.contentsGravity = kCAGravityResizeAspect;
            if (iv.image) w.texLayer.contents = (__bridge id)iv.image.CGImage;
            [CATransaction commit];
            break;
        }
        case ZSGifWindowKindShape:
            zs_refresh_gif_view_tint(w.ownerView, w.ownerView.bounds);
            break;
        case ZSGifWindowKindSwitch: {
            UISwitch *sw = (UISwitch *)w.ownerView;
            zs_set_switch_texture_driven(sw, w.texLayer != nil);
            w.texLayer.opacity = sw.isOn ? 1.0f : 0.0f;
            zs_refresh_switch_mask_if_registered(sw);
            break;
        }
    }
}
