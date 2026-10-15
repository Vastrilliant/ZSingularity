#import "Logo.h"
#import "Engine.h"
#import "ZTweakLog.h"
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#import <compression.h>
#import <unistd.h>

NSString * const kZSLogoDefaultName = @"Default";
NSNotificationName const ZSLogoDidChangeNotification = @"ZSLogoDidChangeNotification";

static NSString * const kZSLogoRepoOwner = @"vastrilliant";
static NSString * const kZSLogoRepoName = @"ZSingularity";
static NSString * const kZSLogoRepoBranch = @"main";
static NSString * const kZSLogoRepoPath = @"Resources/Logos";

static NSString * const kZSLogoSettingsSection = @"logo";
static NSString * const kZSLogoSelectedKey = @"selected";

static NSString * const kZSLogoRoleFont = @"font";
static NSString * const kZSLogoRoleFill = @"fill";
static NSString * const kZSLogoRoleVfx = @"vfx";
static NSString * const kZSLogoRoleStyle = @"style";

@interface ZSLogoPack ()
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *fontPath;
@property (nonatomic, copy, readwrite, nullable) NSString *fillPath;
@property (nonatomic, copy, readwrite, nullable) NSString *vfxPath;
@property (nonatomic, copy, readwrite, nullable) NSString *stylePath;
@property (nonatomic, copy, readwrite, nullable) NSString *postScriptName;
@property (nonatomic, strong, readwrite) ZSLogoStyle *style;
@property (nonatomic, assign) BOOL fontRegistered;
@end

@implementation ZSLogoPack
@end

@implementation ZSLogoFontStyle
- (instancetype)init {
    self = [super init];
    if (self) {
        _sizeScale = 1;
        _emphasisScale = 0;
        _spacing = 0;
        _baselineOffset = 0;
        _textCase = ZSLogoTextCaseNone;
        _color = UIColor.whiteColor;
        _shadowBlur = 0;
        _shadowOffset = CGSizeZero;
        _shadowColor = UIColor.blackColor;
        _shadowOpacity = 1;
        _strokeWidth = 0;
        _strokeColor = UIColor.blackColor;
    }
    return self;
}
@end

@implementation ZSLogoLayerStyle
- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = YES;
        _speed = 1;
        _opacity = 1;
        _scale = 1;
        _offset = CGSizeZero;
        _rotation = 0;
        _blendMode = @"normal";
        _compositingFilter = nil;
        _aboveText = YES;
        _maskToText = NO;
    }
    return self;
}
@end

@implementation ZSLogoStyle
- (instancetype)init {
    self = [super init];
    if (self) {
        _font = [[ZSLogoFontStyle alloc] init];
        _fill = [[ZSLogoLayerStyle alloc] init];
        _vfx = [[ZSLogoLayerStyle alloc] init];
        _vfx.maskToText = NO;
        _fill.maskToText = YES;
    }
    return self;
}
@end

#pragma mark - Style parsing

static CGFloat zs_logo_json_number(NSDictionary *dict, NSString *key, CGFloat fallback) {
    id value = dict[key];
    if (![value isKindOfClass:[NSNumber class]]) return fallback;
    double number = [value doubleValue];
    return isfinite(number) ? (CGFloat)number : fallback;
}

static BOOL zs_logo_json_bool(NSDictionary *dict, NSString *key, BOOL fallback) {
    id value = dict[key];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static NSString *zs_logo_json_string(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    return [value isKindOfClass:[NSString class]] ? [(NSString *)value lowercaseString] : nil;
}

static CGSize zs_logo_json_pair(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    if (![value isKindOfClass:[NSArray class]] || [value count] < 2) return CGSizeZero;
    id x = value[0], y = value[1];
    if (![x isKindOfClass:[NSNumber class]] || ![y isKindOfClass:[NSNumber class]]) return CGSizeZero;
    return CGSizeMake([x doubleValue], [y doubleValue]);
}

static UIColor *zs_logo_json_color(NSDictionary *dict, NSString *key, UIColor *fallback) {
    id value = dict[key];
    if (![value isKindOfClass:[NSString class]]) return fallback;
    NSString *hex = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length != 6 && hex.length != 8) return fallback;
    unsigned long long raw = 0;
    if (![[NSScanner scannerWithString:hex] scanHexLongLong:&raw]) return fallback;
    CGFloat r, g, b, a = 1;
    if (hex.length == 8) {
        r = ((raw >> 24) & 0xFF) / 255.0;
        g = ((raw >> 16) & 0xFF) / 255.0;
        b = ((raw >> 8) & 0xFF) / 255.0;
        a = (raw & 0xFF) / 255.0;
    } else {
        r = ((raw >> 16) & 0xFF) / 255.0;
        g = ((raw >> 8) & 0xFF) / 255.0;
        b = (raw & 0xFF) / 255.0;
    }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

static CGFloat zs_logo_clamp(CGFloat value, CGFloat low, CGFloat high) {
    return MIN(MAX(value, low), high);
}

static NSDictionary<NSString *, NSString *> *zs_logo_blend_filters(void) {
    static NSDictionary *filters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        filters = @{
            @"normal": @"",
            @"multiply": @"multiplyBlendMode",
            @"screen": @"screenBlendMode",
            @"overlay": @"overlayBlendMode",
            @"softlight": @"softLightBlendMode",
            @"hardlight": @"hardLightBlendMode",
            @"colordodge": @"colorDodgeBlendMode",
            @"colorburn": @"colorBurnBlendMode",
            @"darken": @"darkenBlendMode",
            @"lighten": @"lightenBlendMode",
            @"difference": @"differenceBlendMode",
            @"exclusion": @"exclusionBlendMode",
            @"add": @"plusL",
        };
    });
    return filters;
}

static void zs_logo_parse_layer(NSDictionary *dict, ZSLogoLayerStyle *layer) {
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    layer.enabled = zs_logo_json_bool(dict, @"enabled", layer.enabled);
    layer.speed = MAX(0, zs_logo_json_number(dict, @"speed", layer.speed));
    layer.opacity = zs_logo_clamp(zs_logo_json_number(dict, @"opacity", layer.opacity), 0, 1);
    CGFloat scale = zs_logo_json_number(dict, @"scale", layer.scale);
    layer.scale = scale > 0 ? scale : 1;
    layer.offset = zs_logo_json_pair(dict, @"offset");
    layer.rotation = zs_logo_json_number(dict, @"rotation", layer.rotation);

    NSString *blend = zs_logo_json_string(dict, @"blendMode");
    NSString *filter = blend ? zs_logo_blend_filters()[blend] : nil;
    if (filter) {
        layer.blendMode = blend;
        layer.compositingFilter = filter.length > 0 ? filter : nil;
    }

    NSString *placement = zs_logo_json_string(dict, @"layer");
    if ([placement isEqualToString:@"below"]) layer.aboveText = NO;
    if ([placement isEqualToString:@"above"]) layer.aboveText = YES;
    layer.maskToText = zs_logo_json_bool(dict, @"maskToText", layer.maskToText);
}

static void zs_logo_parse_font(NSDictionary *dict, ZSLogoFontStyle *font) {
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    CGFloat size = zs_logo_json_number(dict, @"size", 0);
    font.sizeScale = size > 0 ? size : 1;
    font.emphasisScale = MAX(0, zs_logo_json_number(dict, @"emphasisScale", 0));
    font.spacing = zs_logo_json_number(dict, @"spacing", 0);
    font.baselineOffset = zs_logo_json_number(dict, @"baselineOffset", 0);

    NSString *textCase = zs_logo_json_string(dict, @"textCase");
    if ([textCase isEqualToString:@"upper"]) font.textCase = ZSLogoTextCaseUpper;
    else if ([textCase isEqualToString:@"lower"]) font.textCase = ZSLogoTextCaseLower;

    font.color = zs_logo_json_color(dict, @"color", font.color);

    font.shadowBlur = MAX(0, zs_logo_json_number(dict, @"shadow", 0));
    font.shadowOffset = zs_logo_json_pair(dict, @"shadowOffset");
    font.shadowColor = zs_logo_json_color(dict, @"shadowColor", font.shadowColor);
    font.shadowOpacity = zs_logo_clamp(zs_logo_json_number(dict, @"shadowOpacity", 1), 0, 1);

    font.strokeWidth = MAX(0, zs_logo_json_number(dict, @"stroke", 0));
    font.strokeColor = zs_logo_json_color(dict, @"strokeColor", font.strokeColor);
}

static ZSLogoStyle *zs_logo_load_style(NSString *path) {
    ZSLogoStyle *style = [[ZSLogoStyle alloc] init];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data) return style;

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        ZLog(@"[Logo] style.json is not a valid JSON object - using defaults");
        return style;
    }
    zs_logo_parse_font(json[@"font"], style.font);
    zs_logo_parse_layer(json[@"fill"], style.fill);
    zs_logo_parse_layer(json[@"vfx"], style.vfx);
    return style;
}

#pragma mark - Paths and cache

static NSString *zs_logo_cache_directory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dir = [paths.firstObject stringByAppendingPathComponent:@"ZSLogoCache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static BOOL zs_logo_name_is_safe(NSString *name) {
    if (name.length == 0 || name.length > 128) return NO;
    if ([name hasPrefix:@"."]) return NO;
    if ([name rangeOfString:@"/"].location != NSNotFound) return NO;
    if ([name rangeOfString:@"\\"].location != NSNotFound) return NO;
    return YES;
}

static NSString *zs_logo_directory(NSString *name) {
    return [zs_logo_cache_directory() stringByAppendingPathComponent:name];
}

static NSString *zs_logo_local_root(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths.firstObject stringByAppendingPathComponent:@"ZSLogos"];
}

static NSString *zs_logo_local_directory(NSString *name) {
    return [zs_logo_local_root() stringByAppendingPathComponent:name];
}

BOOL zs_logo_is_local(NSString *name) {
    if (!zs_logo_name_is_safe(name)) return NO;
    NSString *meta = [zs_logo_local_directory(name) stringByAppendingPathComponent:@"meta.json"];
    return [[NSFileManager defaultManager] fileExistsAtPath:meta];
}

static NSString *zs_logo_meta_path(NSString *name) {
    return [zs_logo_directory(name) stringByAppendingPathComponent:@"meta.json"];
}

static NSString *zs_logo_names_index_path(void) {
    return [zs_logo_cache_directory() stringByAppendingPathComponent:@"index.json"];
}

static NSDictionary *zs_logo_read_meta_in(NSString *directory) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"meta.json"]];
    if (!data) return @{};
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : @{};
}

static NSDictionary *zs_logo_read_meta(NSString *name) {
    return zs_logo_read_meta_in(zs_logo_directory(name));
}

static void zs_logo_write_meta(NSString *name, NSDictionary *meta) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
    [data writeToFile:zs_logo_meta_path(name) atomically:YES];
}

static NSMutableDictionary<NSString *, ZSLogoPack *> *zs_logo_pack_cache(void) {
    static NSMutableDictionary<NSString *, ZSLogoPack *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static ZSLogoPack *zs_logo_pack_named(NSString *name) {
    if (!zs_logo_name_is_safe(name) || [name isEqualToString:kZSLogoDefaultName]) return nil;

    @synchronized (zs_logo_pack_cache()) {
        ZSLogoPack *cached = zs_logo_pack_cache()[name];
        if (cached) return cached;

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *directory in @[zs_logo_local_directory(name), zs_logo_directory(name)]) {
            NSDictionary *meta = zs_logo_read_meta_in(directory);

            NSString *(^pathForRole)(NSString *) = ^NSString *(NSString *role) {
                NSString *file = meta[role][@"file"];
                if (![file isKindOfClass:[NSString class]] || file.length == 0) return nil;
                NSString *path = [directory stringByAppendingPathComponent:file.lastPathComponent];
                return [fm fileExistsAtPath:path] ? path : nil;
            };

            NSString *fontPath = pathForRole(kZSLogoRoleFont);
            if (!fontPath) continue;

            ZSLogoPack *pack = [[ZSLogoPack alloc] init];
            pack.name = name;
            pack.fontPath = fontPath;
            pack.fillPath = pathForRole(kZSLogoRoleFill);
            pack.vfxPath = pathForRole(kZSLogoRoleVfx);
            pack.stylePath = pathForRole(kZSLogoRoleStyle);
            pack.style = zs_logo_load_style(pack.stylePath);
            zs_logo_pack_cache()[name] = pack;
            return pack;
        }
        return nil;
    }
}

static void zs_logo_invalidate_pack(NSString *name) {
    @synchronized (zs_logo_pack_cache()) {
        [zs_logo_pack_cache() removeObjectForKey:name];
    }
}

#pragma mark - Networking

static NSURL *zs_logo_contents_url(NSString *subpath) {
    NSString *path = kZSLogoRepoPath;
    if (subpath.length > 0) path = [path stringByAppendingFormat:@"/%@", subpath];
    NSString *encodedPath = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/contents/%@?ref=%@",
                           kZSLogoRepoOwner, kZSLogoRepoName, encodedPath, kZSLogoRepoBranch];
    return [NSURL URLWithString:urlString];
}

static void zs_logo_fetch_listing(NSURL *url, void (^completion)(NSArray<NSDictionary *> * _Nullable entries)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    request.timeoutInterval = 15;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            id json = (!error && http.statusCode == 200 && data.length > 0)
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
                : nil;
            NSArray *entries = [json isKindOfClass:[NSArray class]] ? json : nil;
            if (!entries) {
                ZLog(@"[Logo] listing failed (%ld): %@", (long)http.statusCode, error.localizedDescription ?: url.absoluteString);
            }
            completion(entries);
        }];
    [task resume];
}

static void zs_logo_download_file(NSURL *url, NSString *destinationPath, void (^completion)(BOOL success)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    request.timeoutInterval = 60;

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:request
        completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (error || http.statusCode != 200 || !location) {
                ZLog(@"[Logo] download failed (%ld): %@", (long)http.statusCode, error.localizedDescription ?: url.absoluteString);
                completion(NO);
                return;
            }
            NSFileManager *fm = [NSFileManager defaultManager];
            NSURL *destination = [NSURL fileURLWithPath:destinationPath];
            [fm removeItemAtURL:destination error:nil];
            NSError *moveError = nil;
            BOOL moved = [fm moveItemAtURL:location toURL:destination error:&moveError];
            if (!moved) ZLog(@"[Logo] move failed: %@", moveError.localizedDescription);
            completion(moved);
        }];
    [task resume];
}

static NSString * const kZSLogoStyleFilename = @"style.json";
static const NSUInteger kZSLogoSVGMaxBytes = 8 * 1024 * 1024;
static const NSInteger kZSLogoTranscodeFPS = 24;
static const CGFloat kZSLogoTranscodeMaxEdge = 1536;
static const CGFloat kZSLogoTranscodeMinEdge = 64;
static const double kZSLogoTranscodeMaxLoopMs = 30000.0;
static const NSTimeInterval kZSLogoTranscodeSettleDelay = 0.03;
static const NSTimeInterval kZSLogoTranscodeStepTimeout = 10.0;
static const NSTimeInterval kZSLogoTranscodeRetryInterval = 60.0;
static const NSUInteger kZSLogoTranscodeViewportAttempts = 60;
static const uint32_t kZSLogoTranscodeVersion = 3;
static const double kZSLogoVideoBitsPerPixel = 0.3;
static const double kZSLogoVideoMinBitRate = 1000000.0;
static const double kZSLogoVideoMaxBitRate = 60000000.0;
static const NSInteger kZSLogoVideoKeyframeInterval = 48;
static const NSTimeInterval kZSLogoVideoAppendTimeout = 10.0;

static void zs_logo_transcode_pack_directory(NSString *directory);

static BOOL zs_logo_is_font_file(NSString *filename) {
    NSString *ext = filename.pathExtension.lowercaseString;
    return [ext isEqualToString:@"ttf"] || [ext isEqualToString:@"otf"];
}

static BOOL zs_logo_is_svg_file(NSString *filename) {
    return [filename.pathExtension.lowercaseString isEqualToString:@"svg"];
}

static BOOL zs_logo_is_image_file(NSString *filename) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = [NSSet setWithArray:@[@"png", @"apng", @"gif", @"webp", @"jpg", @"jpeg", @"svg"]];
    });
    return [extensions containsObject:filename.pathExtension.lowercaseString];
}

static BOOL zs_logo_is_style_file(NSString *filename) {
    return [filename.lowercaseString isEqualToString:kZSLogoStyleFilename];
}

static BOOL zs_logo_is_relevant_file(NSString *filename) {
    return zs_logo_is_font_file(filename) || zs_logo_is_image_file(filename) || zs_logo_is_style_file(filename);
}

static BOOL zs_logo_role_accepts_file(NSString *role, NSString *filename) {
    if ([role isEqualToString:kZSLogoRoleFont]) return zs_logo_is_font_file(filename);
    return zs_logo_is_image_file(filename);
}

static NSDictionary *zs_logo_parse_style_json(NSData *data) {
    if (data.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

static NSString *zs_logo_style_file(NSDictionary *json, NSString *role) {
    id section = json[role];
    if (![section isKindOfClass:[NSDictionary class]]) return nil;
    id value = section[@"file"];
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *file = [[(NSString *)value lastPathComponent] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (file.length == 0 || [file hasPrefix:@"."]) return nil;
    return file;
}

static NSDictionary<NSString *, NSString *> *zs_logo_resolve_roles(NSDictionary *json, NSArray<NSString *> *available, NSString **missingOut) {
    NSMutableDictionary<NSString *, NSString *> *lowered = [NSMutableDictionary dictionary];
    for (NSString *file in [available sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        if (!lowered[file.lowercaseString]) lowered[file.lowercaseString] = file;
    }

    NSString *(^match)(NSString *, NSString *) = ^NSString *(NSString *role, NSString *wanted) {
        NSString *found = [available containsObject:wanted] ? wanted : lowered[wanted.lowercaseString];
        return found && zs_logo_role_accepts_file(role, found) ? found : nil;
    };

    NSMutableDictionary<NSString *, NSString *> *resolved = [NSMutableDictionary dictionary];
    for (NSString *role in @[kZSLogoRoleFont, kZSLogoRoleFill, kZSLogoRoleVfx]) {
        NSString *wanted = json ? zs_logo_style_file(json, role) : nil;
        if (wanted) {
            NSString *found = match(role, wanted);
            if (found) resolved[role] = found;
            else if (missingOut && !*missingOut) *missingOut = wanted;
            continue;
        }
        if ([role isEqualToString:kZSLogoRoleFont]) {
            for (NSString *candidate in [lowered.allValues sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
                if (zs_logo_is_font_file(candidate)) {
                    resolved[role] = candidate;
                    break;
                }
            }
        }
    }
    return resolved;
}

#pragma mark - Logo list

static NSArray<NSString *> *zs_logo_remote_cached_names(void) {
    NSData *data = [NSData dataWithContentsOfFile:zs_logo_names_index_path()];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if ([json isKindOfClass:[NSArray class]]) {
        for (id item in json) {
            if ([item isKindOfClass:[NSString class]] && zs_logo_name_is_safe(item)) [names addObject:item];
        }
    }
    return names;
}

static NSArray<NSString *> *zs_logo_local_names(void) {
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:zs_logo_local_root() error:nil];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *entry in entries) {
        if (zs_logo_is_local(entry)) [names addObject:entry];
    }
    return names;
}

NSArray<NSString *> *zs_logo_cached_names(void) {
    NSMutableSet<NSString *> *all = [NSMutableSet setWithArray:zs_logo_remote_cached_names()];
    [all addObjectsFromArray:zs_logo_local_names()];
    [all removeObject:kZSLogoDefaultName];
    NSArray<NSString *> *sorted = [all.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return [@[kZSLogoDefaultName] arrayByAddingObjectsFromArray:sorted];
}

void zs_logo_refresh_names(ZSLogoNamesCompletion completion) {
    zs_logo_fetch_listing(zs_logo_contents_url(nil), ^(NSArray<NSDictionary *> *entries) {
        if (entries) {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSDictionary *entry in entries) {
                if (![entry isKindOfClass:[NSDictionary class]]) continue;
                NSString *name = entry[@"name"];
                if (![entry[@"type"] isEqual:@"dir"] || ![name isKindOfClass:[NSString class]] || !zs_logo_name_is_safe(name)) continue;
                [names addObject:name];
            }
            [names sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            NSData *data = [NSJSONSerialization dataWithJSONObject:names options:0 error:nil];
            [data writeToFile:zs_logo_names_index_path() atomically:YES];
        }
        NSArray<NSString *> *result = zs_logo_cached_names();
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

#pragma mark - Sync

static NSDictionary *zs_logo_remote_info(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"type"] isEqual:@"file"]) return nil;
    NSString *filename = entry[@"name"];
    NSString *downloadURL = entry[@"download_url"];
    if (![filename isKindOfClass:[NSString class]] || ![downloadURL isKindOfClass:[NSString class]]) return nil;
    if ([filename hasPrefix:@"."] || !zs_logo_is_relevant_file(filename)) return nil;
    return @{
        @"file": filename,
        @"sha": [entry[@"sha"] isKindOfClass:[NSString class]] ? entry[@"sha"] : @"",
        @"url": downloadURL,
    };
}

static BOOL zs_logo_meta_has_file(NSDictionary *meta, NSString *file, NSString *sha) {
    if (sha.length == 0) return NO;
    for (id value in meta.allValues) {
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        if ([value[@"file"] isEqual:file] && [value[@"sha"] isEqual:sha]) return YES;
    }
    return NO;
}

static void zs_logo_fetch_remote_file(NSString *directory, NSDictionary *info, NSDictionary *oldMeta, void (^completion)(BOOL success)) {
    NSString *destination = [directory stringByAppendingPathComponent:info[@"file"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:destination] && zs_logo_meta_has_file(oldMeta, info[@"file"], info[@"sha"])) {
        completion(YES);
        return;
    }
    NSURL *url = [NSURL URLWithString:info[@"url"]];
    if (!url) {
        completion(NO);
        return;
    }
    zs_logo_download_file(url, destination, completion);
}

static void zs_logo_sync(NSString *name, void (^completion)(BOOL success)) {
    zs_logo_fetch_listing(zs_logo_contents_url(name), ^(NSArray<NSDictionary *> *entries) {
        if (!entries) {
            completion(NO);
            return;
        }

        NSMutableDictionary<NSString *, NSDictionary *> *remote = [NSMutableDictionary dictionary];
        for (NSDictionary *entry in entries) {
            NSDictionary *info = zs_logo_remote_info(entry);
            if (info && !remote[info[@"file"]]) remote[info[@"file"]] = info;
        }

        NSString *directory = zs_logo_directory(name);
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *oldMeta = zs_logo_read_meta(name);

        void (^proceed)(NSString *, NSData *) = ^(NSString *styleName, NSData *styleData) {
            NSDictionary *json = zs_logo_parse_style_json(styleData);
            NSString *missing = nil;
            NSDictionary<NSString *, NSString *> *resolved = zs_logo_resolve_roles(json, remote.allKeys, &missing);
            if (!resolved[kZSLogoRoleFont]) {
                ZLog(@"[Logo] '%@' has no usable font%@", name, missing ? [NSString stringWithFormat:@" (style.json points to %@)", missing] : @"");
                completion(NO);
                return;
            }

            NSMutableDictionary<NSString *, NSString *> *roleFiles = [resolved mutableCopy];
            if (styleName && styleData) roleFiles[kZSLogoRoleStyle] = styleName;

            NSMutableSet<NSString *> *okFiles = [NSMutableSet set];
            if (styleName && styleData) [okFiles addObject:styleName];

            dispatch_group_t group = dispatch_group_create();
            dispatch_queue_t stateQueue = dispatch_queue_create("zs.logo.sync", DISPATCH_QUEUE_SERIAL);

            for (NSString *file in [NSSet setWithArray:roleFiles.allValues]) {
                if ([okFiles containsObject:file]) continue;
                dispatch_group_enter(group);
                zs_logo_fetch_remote_file(directory, remote[file], oldMeta, ^(BOOL success) {
                    if (success) dispatch_sync(stateQueue, ^{ [okFiles addObject:file]; });
                    dispatch_group_leave(group);
                });
            }

            dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSMutableDictionary *newMeta = [NSMutableDictionary dictionary];
                for (NSString *role in roleFiles) {
                    NSString *file = roleFiles[role];
                    if (![okFiles containsObject:file]) continue;
                    newMeta[role] = @{@"file": file, @"sha": remote[file][@"sha"] ?: @""};
                }

                BOOL success = newMeta[kZSLogoRoleFont] != nil;
                if (success) {
                    NSMutableSet<NSString *> *keep = [NSMutableSet setWithObject:@"meta.json"];
                    for (NSDictionary *item in newMeta.allValues) [keep addObject:item[@"file"]];
                    for (NSString *existing in [fm contentsOfDirectoryAtPath:directory error:nil]) {
                        if (![keep containsObject:existing]) [fm removeItemAtPath:[directory stringByAppendingPathComponent:existing] error:nil];
                    }
                    zs_logo_write_meta(name, newMeta);
                    zs_logo_invalidate_pack(name);
                    zs_logo_transcode_pack_directory(directory);
                }
                completion(success);
            });
        };

        NSString *styleName = nil;
        for (NSString *file in remote.allKeys) {
            if (zs_logo_is_style_file(file)) {
                styleName = file;
                break;
            }
        }
        if (!styleName) {
            proceed(nil, nil);
            return;
        }

        zs_logo_fetch_remote_file(directory, remote[styleName], oldMeta, ^(BOOL success) {
            NSData *data = success ? [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:styleName]] : nil;
            proceed(data ? styleName : nil, data);
        });
    });
}

#pragma mark - Selection

static NSString *gZSLogoSelectedCache;

NSString *zs_logo_selected_name(void) {
    if (!gZSLogoSelectedCache) {
        id stored = zs_settings_section(kZSLogoSettingsSection)[kZSLogoSelectedKey];
        gZSLogoSelectedCache = [stored isKindOfClass:[NSString class]] && zs_logo_name_is_safe(stored) ? stored : kZSLogoDefaultName;
    }
    return gZSLogoSelectedCache;
}

static void zs_logo_store_selected_name(NSString *name) {
    NSMutableDictionary *section = [zs_settings_section(kZSLogoSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSLogoSelectedKey] = name;
    zs_write_settings_section(kZSLogoSettingsSection, section);
    gZSLogoSelectedCache = [name copy];
}

void zs_logo_select(NSString *name, ZSLogoSelectCompletion completion) {
    void (^finish)(BOOL) = ^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                zs_logo_store_selected_name(name);
                [[NSNotificationCenter defaultCenter] postNotificationName:ZSLogoDidChangeNotification object:nil];
            }
            if (completion) completion(success);
        });
    };

    if ([name isEqualToString:kZSLogoDefaultName]) {
        finish(YES);
        return;
    }
    if (!zs_logo_name_is_safe(name)) {
        finish(NO);
        return;
    }
    if (zs_logo_is_local(name)) {
        finish(zs_logo_pack_named(name) != nil);
        return;
    }
    zs_logo_sync(name, ^(BOOL success) {
        finish(success || zs_logo_pack_named(name) != nil);
    });
}

#pragma mark - Font

static void zs_logo_restore_selected_if_needed(NSString *name) {
    static NSMutableSet<NSString *> *attempted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ attempted = [NSMutableSet set]; });
    @synchronized (attempted) {
        if ([attempted containsObject:name]) return;
        [attempted addObject:name];
    }
    zs_logo_sync(name, ^(BOOL success) {
        if (!success) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:ZSLogoDidChangeNotification object:nil];
        });
    });
}

ZSLogoPack *zs_logo_selected_pack(void) {
    NSString *name = zs_logo_selected_name();
    if ([name isEqualToString:kZSLogoDefaultName]) return nil;
    ZSLogoPack *pack = zs_logo_pack_named(name);
    if (!pack) zs_logo_restore_selected_if_needed(name);
    return pack;
}

ZSLogoStyle *zs_logo_selected_style(void) {
    return zs_logo_selected_pack().style;
}

static void zs_logo_prepare_font(ZSLogoPack *pack) {
    @synchronized (pack) {
        if (pack.fontRegistered) return;
        pack.fontRegistered = YES;

        NSURL *url = [NSURL fileURLWithPath:pack.fontPath];
        CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
        if (descriptors && CFArrayGetCount(descriptors) > 0) {
            CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, 0);
            CFStringRef postScriptName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
            if (postScriptName) {
                pack.postScriptName = [(__bridge NSString *)postScriptName copy];
                CFRelease(postScriptName);
            }
        }
        if (descriptors) CFRelease(descriptors);

        CFErrorRef error = NULL;
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
            NSError *nsError = (__bridge NSError *)error;
            ZLog(@"[Logo] font registration for '%@': %@", pack.name, nsError.localizedDescription ?: @"(already registered)");
        }
        if (error) CFRelease(error);
    }
}

UIFont *zs_logo_selected_font(CGFloat size) {
    ZSLogoPack *pack = zs_logo_selected_pack();
    if (!pack) return nil;
    zs_logo_prepare_font(pack);
    if (pack.postScriptName.length == 0) return nil;
    return [UIFont fontWithName:pack.postScriptName size:size];
}

#pragma mark - Effects

static const NSUInteger kZSLogoAnimationMaxFrames = 240;
static const double kZSLogoAnimationByteBudget = 64.0 * 1024 * 1024;
static const CGFloat kZSLogoAnimationMaxPixels = 2048;
static NSString * const kZSLogoFrameAnimationKey = @"zs.logo.frames";

@interface ZSLogoAnimation : NSObject
@property (nonatomic, strong) NSArray *frames;
@property (nonatomic, strong) NSArray<NSNumber *> *keyTimes;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) CGSize size;
@end

@implementation ZSLogoAnimation
@end

static NSCache<NSString *, ZSLogoAnimation *> *zs_logo_animation_cache(void) {
    static NSCache<NSString *, ZSLogoAnimation *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.totalCostLimit = (NSUInteger)(kZSLogoAnimationByteBudget * 2);
    });
    return cache;
}

static NSString *zs_logo_animation_key(NSString *path) {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return [NSString stringWithFormat:@"%@|%.3f|%llu", path,
            [attributes.fileModificationDate timeIntervalSince1970], attributes.fileSize];
}

static NSTimeInterval zs_logo_frame_delay(CGImageSourceRef source, size_t index) {
    NSDictionary *properties = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, index, NULL);
    NSDictionary *gif = properties[(__bridge NSString *)kCGImagePropertyGIFDictionary];
    NSDictionary *png = properties[(__bridge NSString *)kCGImagePropertyPNGDictionary];
    NSNumber *delay = gif[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime]
        ?: gif[(__bridge NSString *)kCGImagePropertyGIFDelayTime]
        ?: png[(__bridge NSString *)kCGImagePropertyAPNGUnclampedDelayTime]
        ?: png[(__bridge NSString *)kCGImagePropertyAPNGDelayTime];
    NSTimeInterval value = delay.doubleValue;
    return value >= 0.011 ? value : 0.1;
}

static ZSLogoAnimation *zs_logo_decode_animation(NSString *path) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) return nil;

    size_t count = MIN(CGImageSourceGetCount(source), (size_t)kZSLogoAnimationMaxFrames);
    NSDictionary *first = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    CGFloat width = [first[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    CGFloat height = [first[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    if (count == 0 || width <= 0 || height <= 0) {
        CFRelease(source);
        return nil;
    }

    CGFloat longest = MAX(width, height);
    CGFloat maxPixel = MIN(longest, kZSLogoAnimationMaxPixels);
    double ratio = maxPixel / longest;
    double bytes = (double)count * (width * ratio) * (height * ratio) * 4.0;
    if (bytes > kZSLogoAnimationByteBudget) {
        maxPixel = MAX(1, floor(maxPixel * sqrt(kZSLogoAnimationByteBudget / bytes)));
        ratio = maxPixel / longest;
        bytes = (double)count * (width * ratio) * (height * ratio) * 4.0;
    }

    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(ceil(maxPixel)),
    };

    NSMutableArray *frames = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *starts = [NSMutableArray arrayWithCapacity:count];
    NSTimeInterval elapsed = 0;
    for (size_t i = 0; i < count; i++) {
        @autoreleasepool {
            CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, i, (__bridge CFDictionaryRef)options);
            if (!image) continue;
            [frames addObject:(__bridge id)image];
            CGImageRelease(image);
            [starts addObject:@(elapsed)];
            elapsed += zs_logo_frame_delay(source, i);
        }
    }
    CFRelease(source);
    if (frames.count == 0) return nil;

    NSMutableArray<NSNumber *> *keyTimes = [NSMutableArray arrayWithCapacity:starts.count];
    for (NSNumber *start in starts) [keyTimes addObject:@(elapsed > 0 ? start.doubleValue / elapsed : 0)];

    ZSLogoAnimation *animation = [[ZSLogoAnimation alloc] init];
    animation.frames = frames;
    animation.keyTimes = keyTimes;
    animation.duration = elapsed;
    animation.size = CGSizeMake(width, height);
    return animation;
}

static ZSLogoAnimation *zs_logo_cached_animation(NSString *path) {
    return [zs_logo_animation_cache() objectForKey:zs_logo_animation_key(path)];
}

static ZSLogoAnimation *zs_logo_animation_for_path(NSString *path) {
    NSString *key = zs_logo_animation_key(path);
    ZSLogoAnimation *cached = [zs_logo_animation_cache() objectForKey:key];
    if (cached) return cached;

    ZSLogoAnimation *decoded = zs_logo_decode_animation(path);
    if (decoded) {
        CGSize size = decoded.size;
        NSUInteger cost = (NSUInteger)(size.width * size.height * 4.0 * decoded.frames.count);
        [zs_logo_animation_cache() setObject:decoded forKey:key cost:cost];
    }
    return decoded;
}

@interface ZSLogoEffectView : UIView
@property (nonatomic, weak) UILabel *label;
@property (nonatomic, strong) ZSLogoLayerStyle *layerStyle;
@property (nonatomic, assign) BOOL fillsText;
@property (nonatomic, assign) BOOL animationsPaused;
- (void)loadAssetAtPath:(NSString *)path;
- (void)releaseAssets;
- (void)zs_advanceBy:(NSTimeInterval)delta;
@end

@interface ZSLogoSVG : NSObject
@property (nonatomic, copy) NSString *html;
@property (nonatomic, assign) CGSize size;
@end

@implementation ZSLogoSVG
@end

@interface ZSLogoSVGRootReader : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *attributes;
@end

@implementation ZSLogoSVGRootReader
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {
    if ([elementName isEqualToString:@"svg"]) self.attributes = attributeDict ?: @{};
    [parser abortParsing];
}
@end

static CGFloat zs_logo_svg_length(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0 || [value containsString:@"%"]) return 0;
    double number = value.doubleValue;
    return (isfinite(number) && number > 0) ? (CGFloat)number : 0;
}

static NSString *zs_logo_svg_strip_noise(NSString *markup) {
    static NSArray<NSRegularExpression *> *expressions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSRegularExpressionOptions options = NSRegularExpressionDotMatchesLineSeparators;
        expressions = @[
            [NSRegularExpression regularExpressionWithPattern:@"<!--.*?-->" options:options error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"<metadata\\b.*?</metadata>" options:options error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"<sodipodi:namedview\\b[^>]*?/>" options:options error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"<sodipodi:namedview\\b.*?</sodipodi:namedview>" options:options error:nil],
        ];
    });
    NSMutableString *result = [markup mutableCopy];
    for (NSRegularExpression *expression in expressions) {
        [expression replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    }
    return result;
}

static ZSLogoSVG *zs_logo_svg_for_path(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data.length == 0 || data.length > kZSLogoSVGMaxBytes) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRange start = text ? [text rangeOfString:@"<svg"] : NSMakeRange(NSNotFound, 0);
    if (start.location == NSNotFound) return nil;

    ZSLogoSVGRootReader *reader = [[ZSLogoSVGRootReader alloc] init];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = reader;
    parser.shouldResolveExternalEntities = NO;
    [parser parse];
    NSDictionary<NSString *, NSString *> *attributes = reader.attributes;
    if (!attributes) return nil;

    CGSize boxSize = CGSizeZero;
    BOOL hasViewBox = NO;
    NSString *viewBox = attributes[@"viewBox"];
    if (viewBox.length > 0) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *part in [viewBox componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", \t\r\n"]]) {
            if (part.length > 0) [parts addObject:part];
        }
        if (parts.count == 4) {
            CGFloat w = (CGFloat)[parts[2] doubleValue];
            CGFloat h = (CGFloat)[parts[3] doubleValue];
            if (w > 0 && h > 0) {
                boxSize = CGSizeMake(w, h);
                hasViewBox = YES;
            }
        }
    }

    CGFloat width = zs_logo_svg_length(attributes[@"width"]);
    CGFloat height = zs_logo_svg_length(attributes[@"height"]);
    BOOL hasDimensions = width > 0 && height > 0;
    CGSize size = hasDimensions ? CGSizeMake(width, height) : boxSize;
    if (size.width <= 0 || size.height <= 0) size = CGSizeMake(1, 1);

    NSString *markup = [text substringFromIndex:start.location];
    if (!hasViewBox && hasDimensions) {
        markup = [markup stringByReplacingCharactersInRange:NSMakeRange(0, 4)
                                                 withString:[NSString stringWithFormat:@"<svg viewBox=\"0 0 %g %g\"", width, height]];
    }
    markup = zs_logo_svg_strip_noise(markup);

    ZSLogoSVG *svg = [[ZSLogoSVG alloc] init];
    svg.size = size;
    svg.html = [NSString stringWithFormat:
        @"<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        @"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1\">"
        @"<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:\">"
        @"<style>html,body{margin:0;padding:0;width:100%%;height:100%%;background:transparent;overflow:hidden}"
        @"svg{display:block;width:100%%;height:100%%}"
        @"</style></head><body>%@</body></html>", markup];
    return svg;
}

static NSString * const kZSLogoSVGProbeScript =
    @"(function(){\n"
    @"var out={periods:[],end:0,lead:0,anim:false};\n"
    @"var svg=document.querySelector('svg');\n"
    @"window.__zsa=[];\n"
    @"function num(v){var m=/^\\s*([+-]?\\d*\\.?\\d+)\\s*(ms|s|min|h)?\\s*$/.exec(v||'');if(!m)return NaN;var x=parseFloat(m[1]);var u=m[2];return u==='ms'?x:(u==='min'?x*60000:(u==='h'?x*3600000:x*1000));}\n"
    @"if(svg&&svg.getCurrentTime){\n"
    @"var els=svg.querySelectorAll('animate,animateTransform,animateMotion,animateColor,set');\n"
    @"for(var i=0;i<els.length;i++){\n"
    @"var el=els[i],sd=NaN,st=0;\n"
    @"try{sd=el.getSimpleDuration()*1000;}catch(e){}\n"
    @"try{st=el.getStartTime()*1000;}catch(e){}\n"
    @"if(!(sd>0)||!isFinite(sd))continue;\n"
    @"out.anim=true;\n"
    @"var rc=el.getAttribute('repeatCount'),rd=el.getAttribute('repeatDur');\n"
    @"if(rc==='indefinite'||rd==='indefinite'){out.periods.push(sd);out.lead=Math.max(out.lead,st);}\n"
    @"else{var total=sd,n=parseFloat(rc),d=num(rd);if(isFinite(n)&&n>0)total=sd*n;if(isFinite(d)&&d>0)total=d;out.end=Math.max(out.end,st+total);}\n"
    @"}}\n"
    @"var an=document.getAnimations?document.getAnimations():[];\n"
    @"for(var j=0;j<an.length;j++){\n"
    @"var a=an[j],t=null;\n"
    @"try{t=a.effect.getComputedTiming();}catch(e){}\n"
    @"if(!t||typeof t.duration!=='number'||!(t.duration>0))continue;\n"
    @"window.__zsa.push(a);\n"
    @"out.anim=true;\n"
    @"var per=t.duration*((t.direction==='alternate'||t.direction==='alternate-reverse')?2:1);\n"
    @"if(t.iterations===Infinity){out.periods.push(per);out.lead=Math.max(out.lead,t.delay||0);}\n"
    @"else if(isFinite(t.endTime)){out.end=Math.max(out.end,t.endTime);}\n"
    @"}\n"
    @"return JSON.stringify(out);\n"
    @"})()";

static NSString * const kZSLogoSVGSeekScript =
    @"(function(t,c){\n"
    @"var svg=document.querySelector('svg');\n"
    @"if(svg&&svg.pauseAnimations){svg.pauseAnimations();svg.setCurrentTime(t/1000);}\n"
    @"var a=window.__zsa||[];\n"
    @"for(var i=0;i<a.length;i++){try{a[i].pause();a[i].currentTime=t;}catch(e){}}\n"
    @"document.documentElement.style.setProperty('background-color',c,'important');\n"
    @"if(svg){svg.getBoundingClientRect();}\n"
    @"return 1;\n"
    @"})(%f,'%@')";

static NSString * const kZSLogoSVGBackgroundScript =
    @"(function(c){document.documentElement.style.setProperty('background-color',c,'important');return 1;})('%@')";

static UIWindow *zs_logo_host_window(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
            if (!fallback) fallback = window;
        }
    }
    return fallback;
}

#pragma mark - HEVC writer

static void zs_logo_matte_rows(const uint8_t *onBlack, const uint8_t *onWhite, uint8_t *out, size_t outStride, size_t width, size_t height) {
    for (size_t y = 0; y < height; y++) {
        const uint8_t *black = onBlack + y * width * 4;
        const uint8_t *white = onWhite + y * width * 4;
        uint8_t *dst = out + y * outStride;
        for (size_t x = 0; x < width; x++, black += 4, white += 4, dst += 4) {
            int difference = ((int)white[0] - (int)black[0]) + ((int)white[1] - (int)black[1]) + ((int)white[2] - (int)black[2]);
            int alpha = 255 - (difference + (difference >= 0 ? 1 : -1)) / 3;
            if (alpha < 0) alpha = 0;
            if (alpha > 255) alpha = 255;
            for (int c = 0; c < 3; c++) dst[c] = black[c] > alpha ? (uint8_t)alpha : black[c];
            dst[3] = (uint8_t)alpha;
        }
    }
}

@interface ZSLogoVideoWriter : NSObject
- (instancetype)initWithFinalPath:(NSString *)finalPath width:(size_t)width height:(size_t)height frameCount:(NSUInteger)frameCount;
- (BOOL)open;
- (BOOL)appendOnBlack:(const uint8_t *)black onWhite:(const uint8_t *)white;
- (void)finishCommitting:(BOOL)commit completion:(void (^)(BOOL ok))completion;
@end

@implementation ZSLogoVideoWriter {
    NSString *_finalPath;
    NSString *_tempPath;
    size_t _width;
    size_t _height;
    NSUInteger _expectedFrames;
    NSUInteger _frames;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_input;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
}

- (instancetype)initWithFinalPath:(NSString *)finalPath width:(size_t)width height:(size_t)height frameCount:(NSUInteger)frameCount {
    self = [super init];
    if (!self) return nil;
    _finalPath = [finalPath copy];
    _tempPath = [[finalPath stringByDeletingPathExtension] stringByAppendingString:@".tmp.mov"];
    _width = width;
    _height = height;
    _expectedFrames = frameCount;
    return self;
}

- (BOOL)open {
    NSURL *url = [NSURL fileURLWithPath:_tempPath];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    NSError *error = nil;
    _writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:&error];
    if (!_writer) {
        ZLog(@"[Logo] couldn't create the movie writer: %@", error.localizedDescription);
        return NO;
    }

    double bitRate = (double)_width * (double)_height * (double)kZSLogoTranscodeFPS * kZSLogoVideoBitsPerPixel;
    bitRate = MIN(kZSLogoVideoMaxBitRate, MAX(kZSLogoVideoMinBitRate, bitRate));
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeHEVCWithAlpha,
        AVVideoWidthKey: @(_width),
        AVVideoHeightKey: @(_height),
        AVVideoColorPropertiesKey: @{
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        },
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(bitRate),
            AVVideoExpectedSourceFrameRateKey: @(kZSLogoTranscodeFPS),
            AVVideoMaxKeyFrameIntervalKey: @(kZSLogoVideoKeyframeInterval),
            AVVideoAllowFrameReorderingKey: @NO,
        },
    };
    if (![_writer canApplyOutputSettings:settings forMediaType:AVMediaTypeVideo]) {
        ZLog(@"[Logo] this device can't encode HEVC with alpha at %zux%zu", _width, _height);
        return NO;
    }

    _input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    _input.expectsMediaDataInRealTime = NO;
    _adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_input
                                                                                  sourcePixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(_width),
        (id)kCVPixelBufferHeightKey: @(_height),
    }];
    if (![_writer canAddInput:_input]) return NO;
    [_writer addInput:_input];
    if (![_writer startWriting]) {
        ZLog(@"[Logo] movie writer failed to start: %@", _writer.error.localizedDescription);
        return NO;
    }
    [_writer startSessionAtSourceTime:kCMTimeZero];
    return YES;
}

- (BOOL)appendOnBlack:(const uint8_t *)black onWhite:(const uint8_t *)white {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + kZSLogoVideoAppendTimeout;
    while (!_input.isReadyForMoreMediaData) {
        if (_writer.status != AVAssetWriterStatusWriting || CFAbsoluteTimeGetCurrent() > deadline) return NO;
        usleep(1000);
    }

    CVPixelBufferPoolRef pool = _adaptor.pixelBufferPool;
    if (!pool) return NO;
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) != kCVReturnSuccess || !buffer) return NO;

    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    if (base) zs_logo_matte_rows(black, white, base, stride, _width, _height);
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    BOOL ok = base != NULL && [_adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake((int64_t)_frames, (int32_t)kZSLogoTranscodeFPS)];
    CVPixelBufferRelease(buffer);
    if (ok) _frames++;
    else ZLog(@"[Logo] movie writer rejected frame %lu: %@", (unsigned long)_frames, _writer.error.localizedDescription);
    return ok;
}

- (void)finishCommitting:(BOOL)commit completion:(void (^)(BOOL ok))completion {
    AVAssetWriter *writer = _writer;
    if (!writer) {
        completion(NO);
        return;
    }
    BOOL complete = commit && _frames == _expectedFrames && writer.status == AVAssetWriterStatusWriting;
    if (!complete) {
        if (commit) ZLog(@"[Logo] movie writer can't finish: %lu/%lu frames appended, status %ld, error %@", (unsigned long)_frames, (unsigned long)_expectedFrames, (long)writer.status, writer.error);
        if (writer.status == AVAssetWriterStatusWriting) [writer cancelWriting];
        [[NSFileManager defaultManager] removeItemAtPath:_tempPath error:nil];
        completion(NO);
        return;
    }
    [_input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake((int64_t)_frames, (int32_t)kZSLogoTranscodeFPS)];
    NSString *tempPath = _tempPath;
    NSString *finalPath = _finalPath;
    [writer finishWritingWithCompletionHandler:^{
        BOOL ok = writer.status == AVAssetWriterStatusCompleted;
        if (ok) {
            remove(finalPath.fileSystemRepresentation);
            ok = rename(tempPath.fileSystemRepresentation, finalPath.fileSystemRepresentation) == 0;
        } else {
            ZLog(@"[Logo] movie writer failed to finish (status %ld): %@", (long)writer.status, writer.error);
        }
        if (!ok) remove(tempPath.fileSystemRepresentation);
        completion(ok);
    }];
}

@end

#pragma mark - Transcode paths

static NSString *zs_logo_transcode_directory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dir = [paths.firstObject stringByAppendingPathComponent:@"ZSLogoTranscode"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static BOOL zs_logo_is_transcoded_path(NSString *path) {
    return [path hasPrefix:[zs_logo_transcode_directory() stringByAppendingString:@"/"]];
}

static uint64_t zs_logo_hash_string(NSString *string) {
    const char *bytes = string.UTF8String;
    uint64_t hash = 1469598103934665603ULL;
    for (const char *p = bytes; p && *p; p++) {
        hash ^= (uint8_t)*p;
        hash *= 1099511628211ULL;
    }
    return hash;
}

static NSString *zs_logo_transcode_prefix(NSString *svgPath) {
    return [NSString stringWithFormat:@"%016llx-", (unsigned long long)zs_logo_hash_string(svgPath)];
}

static NSString *zs_logo_transcoded_video_path(NSString *svgPath) {
    NSString *key = [zs_logo_animation_key(svgPath) stringByAppendingFormat:@"|v%u", kZSLogoTranscodeVersion];
    NSString *name = [NSString stringWithFormat:@"%@%016llx.mov", zs_logo_transcode_prefix(svgPath), (unsigned long long)zs_logo_hash_string(key)];
    return [zs_logo_transcode_directory() stringByAppendingPathComponent:name];
}

static NSString *zs_logo_ready_video_path(NSString *svgPath) {
    NSString *video = zs_logo_transcoded_video_path(svgPath);
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:video error:nil];
    return attributes.fileSize > 0 ? video : nil;
}

static void zs_logo_transcode_prune(NSString *svgPath, NSString *keepVideo) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *directory = zs_logo_transcode_directory();
    NSString *prefix = zs_logo_transcode_prefix(svgPath);
    NSString *keep = keepVideo.lastPathComponent;
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if (![name hasPrefix:prefix] || [name hasPrefix:keep]) continue;
        [fm removeItemAtPath:[directory stringByAppendingPathComponent:name] error:nil];
    }
}

#pragma mark - HEVC playback

@interface ZSLogoVideo : NSObject
@property (nonatomic, strong) NSArray *samples;
@property (nonatomic, strong) NSArray<NSNumber *> *keyframes;
@property (nonatomic, assign) CGSize size;
@property (nonatomic, assign) NSTimeInterval frameDuration;
- (NSUInteger)count;
- (NSUInteger)keyframeAtOrBefore:(NSUInteger)index;
- (CMVideoFormatDescriptionRef)formatDescription;
@end

@implementation ZSLogoVideo
- (NSUInteger)count {
    return self.samples.count;
}

- (NSUInteger)keyframeAtOrBefore:(NSUInteger)index {
    NSUInteger result = 0;
    for (NSNumber *key in self.keyframes) {
        if (key.unsignedIntegerValue > index) break;
        result = key.unsignedIntegerValue;
    }
    return result;
}

- (CMVideoFormatDescriptionRef)formatDescription {
    if (self.samples.count == 0) return NULL;
    return (CMVideoFormatDescriptionRef)CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)self.samples.firstObject);
}
@end

static ZSLogoVideo *zs_logo_video_load(NSString *path) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return nil;

    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
    if (!reader || !output || ![reader canAddOutput:output]) return nil;
    output.alwaysCopiesSampleData = YES;
    [reader addOutput:output];
    if (![reader startReading]) return nil;

    NSMutableArray *samples = [NSMutableArray array];
    NSMutableArray<NSNumber *> *keyframes = [NSMutableArray array];
    CMSampleBufferRef sample = NULL;
    while ((sample = [output copyNextSampleBuffer])) {
        if (CMSampleBufferGetNumSamples(sample) > 0 && CMSampleBufferGetDataBuffer(sample)) {
            BOOL sync = YES;
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
            if (attachments && CFArrayGetCount(attachments) > 0) {
                CFDictionaryRef attachment = CFArrayGetValueAtIndex(attachments, 0);
                CFBooleanRef notSync = CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_NotSync);
                if (notSync && CFBooleanGetValue(notSync)) sync = NO;
            }
            if (sync) [keyframes addObject:@(samples.count)];
            [samples addObject:(__bridge id)sample];
        }
        CFRelease(sample);
    }
    if (reader.status != AVAssetReaderStatusCompleted || samples.count == 0 || keyframes.firstObject.unsignedIntegerValue != 0) return nil;

    CGSize size = track.naturalSize;
    if (size.width <= 0 || size.height <= 0) return nil;
    float rate = track.nominalFrameRate;

    ZSLogoVideo *video = [[ZSLogoVideo alloc] init];
    video.samples = samples;
    video.keyframes = keyframes;
    video.size = size;
    video.frameDuration = rate > 0 ? 1.0 / (double)rate : 1.0 / (double)kZSLogoTranscodeFPS;
    return video;
}

static NSCache<NSString *, ZSLogoVideo *> *zs_logo_video_cache(void) {
    static NSCache<NSString *, ZSLogoVideo *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 8;
    });
    return cache;
}

static ZSLogoVideo *zs_logo_video_for_path(NSString *path) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSObject alloc] init]; });

    @synchronized (lock) {
        ZSLogoVideo *cached = [zs_logo_video_cache() objectForKey:path];
        if (cached) return cached;
        ZSLogoVideo *video = zs_logo_video_load(path);
        if (video) [zs_logo_video_cache() setObject:video forKey:path];
        return video;
    }
}

@interface ZSLogoVideoDecoder : NSObject
- (instancetype)initWithVideo:(ZSLogoVideo *)video;
- (void)decodeIndex:(NSUInteger)index completion:(void (^)(CVPixelBufferRef _Nullable buffer))completion;
- (void)invalidate;
@end

@implementation ZSLogoVideoDecoder {
    ZSLogoVideo *_video;
    dispatch_queue_t _queue;
    VTDecompressionSessionRef _session;
    NSInteger _decoded;
    BOOL _invalid;
}

- (instancetype)initWithVideo:(ZSLogoVideo *)video {
    self = [super init];
    if (!self) return nil;
    _video = video;
    _queue = dispatch_queue_create("zs.logo.decode", DISPATCH_QUEUE_SERIAL);
    _decoded = -1;
    return self;
}

- (void)dealloc {
    [self zs_closeSession];
}

- (void)zs_closeSession {
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    _decoded = -1;
}

- (BOOL)zs_openSession {
    if (_session) return YES;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, _video.formatDescription, NULL,
                                                   (__bridge CFDictionaryRef)attributes, NULL, &_session);
    if (status != noErr) {
        ZLog(@"[Logo] couldn't start the HEVC decoder (%d)", (int)status);
        _session = NULL;
        return NO;
    }
    return YES;
}

- (CVPixelBufferRef)zs_decodeSample:(NSUInteger)index {
    __block CVPixelBufferRef result = NULL;
    OSStatus status = VTDecompressionSessionDecodeFrameWithOutputHandler(_session, (__bridge CMSampleBufferRef)_video.samples[index], 0, NULL,
        ^(OSStatus outputStatus, VTDecodeInfoFlags flags, CVImageBufferRef imageBuffer, CMTime presentationTime, CMTime duration) {
            if (outputStatus == noErr && imageBuffer) result = CVPixelBufferRetain(imageBuffer);
        });
    VTDecompressionSessionWaitForAsynchronousFrames(_session);
    if (status != noErr && result) {
        CVPixelBufferRelease(result);
        result = NULL;
    }
    return result;
}

- (CVPixelBufferRef)zs_decodeTo:(NSUInteger)target {
    NSUInteger key = [_video keyframeAtOrBefore:target];
    for (int attempt = 0; attempt < 2; attempt++) {
        if (![self zs_openSession]) return NULL;

        NSUInteger start = key;
        if (_decoded >= 0 && (NSUInteger)_decoded < target && (NSUInteger)_decoded + 1 >= key) start = (NSUInteger)_decoded + 1;

        CVPixelBufferRef output = NULL;
        BOOL ok = YES;
        for (NSUInteger i = start; i <= target; i++) {
            CVPixelBufferRef buffer = [self zs_decodeSample:i];
            if (!buffer) {
                ok = NO;
                break;
            }
            if (output) CVPixelBufferRelease(output);
            output = buffer;
        }
        if (ok && output) {
            _decoded = (NSInteger)target;
            return output;
        }
        if (output) CVPixelBufferRelease(output);
        [self zs_closeSession];
    }
    return NULL;
}

- (void)decodeIndex:(NSUInteger)index completion:(void (^)(CVPixelBufferRef _Nullable buffer))completion {
    dispatch_async(_queue, ^{
        CVPixelBufferRef buffer = NULL;
        if (!self->_invalid && index < self->_video.count) buffer = [self zs_decodeTo:index];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(buffer);
            if (buffer) CVPixelBufferRelease(buffer);
        });
    });
}

- (void)invalidate {
    dispatch_async(_queue, ^{
        self->_invalid = YES;
        [self zs_closeSession];
    });
}

@end

#pragma mark - SVG to HEVC transcoding

static BOOL zs_logo_draw_snapshot(CGImageRef image, uint8_t *buffer, size_t width, size_t height) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!colorSpace) return NO;
    CGContextRef context = CGBitmapContextCreate(buffer, width, height, 8, width * 4, colorSpace,
        (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (!context) return NO;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
    CGContextRelease(context);
    return YES;
}

static uint64_t zs_logo_gcd(uint64_t a, uint64_t b) {
    while (b) {
        uint64_t t = a % b;
        a = b;
        b = t;
    }
    return a;
}

static void zs_logo_transcode_plan(NSDictionary *probe, double *durationOut, double *leadOut) {
    double duration = 0;
    double lead = 0;
    if ([probe[@"anim"] boolValue]) {
        NSArray *periods = [probe[@"periods"] isKindOfClass:[NSArray class]] ? probe[@"periods"] : @[];
        double end = [probe[@"end"] doubleValue];
        double rawLead = [probe[@"lead"] doubleValue];
        uint64_t cap = (uint64_t)kZSLogoTranscodeMaxLoopMs;
        uint64_t lcm = 0;
        BOOL overflow = NO;
        double widest = 0;
        for (id item in periods) {
            if (![item isKindOfClass:[NSNumber class]]) continue;
            double period = [item doubleValue];
            if (!(period >= 1) || !isfinite(period)) continue;
            widest = MAX(widest, period);
            uint64_t value = (uint64_t)llround(period);
            if (lcm == 0) {
                lcm = value;
            } else if (!overflow) {
                uint64_t divisor = zs_logo_gcd(lcm, value);
                uint64_t left = lcm / divisor;
                if (left > cap / value) overflow = YES;
                else lcm = left * value;
            }
        }
        double periodic = overflow ? widest : (double)lcm;
        if (end > 0 && isfinite(end)) {
            duration = periodic > 0 ? ceil(end / periodic) * periodic : end;
        } else {
            duration = periodic;
            lead = isfinite(rawLead) && rawLead > 0 ? rawLead : 0;
        }
        duration = MIN(duration, kZSLogoTranscodeMaxLoopMs);
        if (overflow) ZLog(@"[Logo] SVG loop periods don't line up within %.0fs - using the longest period", kZSLogoTranscodeMaxLoopMs / 1000.0);
    }
    *durationOut = duration;
    *leadOut = lead;
}

static void zs_logo_transcode_geometry(CGSize intrinsic, NSInteger scale, size_t *widthOut, size_t *heightOut) {
    CGFloat longer = MAX(intrinsic.width, intrinsic.height);
    CGFloat shorter = MIN(intrinsic.width, intrinsic.height);
    if (longer <= 0 || shorter <= 0) longer = shorter = 1;
    double ratio = (double)shorter / (double)longer;
    double edge = MIN((double)kZSLogoTranscodeMaxEdge, MAX((double)kZSLogoTranscodeMinEdge, ceil((double)kZSLogoTranscodeMinEdge / ratio)));
    BOOL landscape = intrinsic.width >= intrinsic.height;
    double width = landscape ? edge : edge * ratio;
    double height = landscape ? edge * ratio : edge;
    size_t unit = (size_t)MAX(scale, 1);
    if (unit % 2 != 0) unit *= 2;
    *widthOut = MAX(unit, (size_t)ceil(width / (double)unit) * unit);
    *heightOut = MAX(unit, (size_t)ceil(height / (double)unit) * unit);
}

@interface ZSLogoSVGJob : NSObject <WKNavigationDelegate>
@property (nonatomic, copy, nullable) void (^completion)(NSString * _Nullable videoPath);
- (instancetype)initWithPath:(NSString *)path svg:(ZSLogoSVG *)svg;
- (void)start;
@end

@implementation ZSLogoSVGJob {
    NSString *_path;
    ZSLogoSVG *_svg;
    NSString *_videoPath;
    UIView *_host;
    WKWebView *_web;
    BOOL _finished;
    BOOL _closing;
    NSUInteger _windowAttempts;
    NSUInteger _generation;
    NSUInteger _loadStep;
    NSUInteger _viewportAttempt;
    NSInteger _scale;
    CGSize _pointSize;
    size_t _pixelWidth;
    size_t _pixelHeight;
    NSUInteger _frameCount;
    NSUInteger _nextFrame;
    NSUInteger _enqueuedCount;
    NSUInteger _inFlight;
    BOOL _waiting;
    double _leadMs;
    ZSLogoVideoWriter *_writer;
    dispatch_queue_t _queue;
    uint8_t *_black;
    uint8_t *_white;
    CFAbsoluteTime _jobStart;
    CFAbsoluteTime _captureStart;
    CFAbsoluteTime _lastLog;
    double _snapshotSeconds;
    double _scriptSeconds;
    double _encodeSeconds;
    NSUInteger _snapshotCount;
    NSUInteger _encodedFrames;
}

- (instancetype)initWithPath:(NSString *)path svg:(ZSLogoSVG *)svg {
    self = [super init];
    if (!self) return nil;
    _path = [path copy];
    _svg = svg;
    _videoPath = zs_logo_transcoded_video_path(path);
    return self;
}

- (void)start {
    if (_finished || _closing) return;
    UIWindow *window = zs_logo_host_window();
    if (!window) {
        if (++_windowAttempts > 120) {
            [self zs_failWithReason:@"no window to render in"];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self start];
        });
        return;
    }

    _scale = MAX(1, (NSInteger)llround(UIScreen.mainScreen.scale));
    _jobStart = CFAbsoluteTimeGetCurrent();
    ZLog(@"[Logo] %@: starting transcode (%lu bytes of SVG, intrinsic %.0fx%.0f, scale %ldx)", _path.lastPathComponent, (unsigned long)_svg.html.length, _svg.size.width, _svg.size.height, (long)_scale);

    _host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    _host.userInteractionEnabled = NO;
    _host.clipsToBounds = YES;
    _host.alpha = 0.02;
    _host.backgroundColor = UIColor.clearColor;
    [window insertSubview:_host atIndex:0];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.defaultWebpagePreferences.allowsContentJavaScript = NO;
    configuration.preferences.inactiveSchedulingPolicy = WKInactiveSchedulingPolicyNone;
    _web = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 256, 256) configuration:configuration];
    _web.navigationDelegate = self;
    _web.opaque = YES;
    _web.backgroundColor = UIColor.whiteColor;
    _web.scrollView.backgroundColor = UIColor.whiteColor;
    _web.scrollView.scrollEnabled = NO;
    _web.scrollView.bounces = NO;
    _web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _web.userInteractionEnabled = NO;
    _web.allowsLinkPreview = NO;
    [_host addSubview:_web];

    _loadStep = [self zs_beginStep];
    [_web loadHTMLString:_svg.html baseURL:nil];
}

- (NSUInteger)zs_beginStep {
    NSUInteger generation = ++_generation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZSLogoTranscodeStepTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_finished || strongSelf->_generation != generation) return;
        [strongSelf zs_failWithReason:@"a render step timed out"];
    });
    return generation;
}

- (BOOL)zs_stepIsCurrent:(NSUInteger)generation {
    return !_finished && !_closing && _generation == generation;
}

- (void)zs_endStep {
    _generation++;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (![self zs_stepIsCurrent:_loadStep]) return;
    [self zs_endStep];
    ZLog(@"[Logo] %@: page loaded after %.2fs, probing animation timing", _path.lastPathComponent, CFAbsoluteTimeGetCurrent() - _jobStart);
    [self zs_probe];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self zs_failWithReason:error.localizedDescription ?: @"load failed"];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self zs_failWithReason:error.localizedDescription ?: @"load failed"];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self zs_failWithReason:@"the web content process ended"];
}

- (void)zs_probe {
    NSUInteger step = [self zs_beginStep];
    [_web evaluateJavaScript:kZSLogoSVGProbeScript completionHandler:^(id result, NSError *error) {
        if (![self zs_stepIsCurrent:step]) return;
        [self zs_endStep];

        NSDictionary *probe = nil;
        if ([result isKindOfClass:[NSString class]]) {
            id json = [NSJSONSerialization JSONObjectWithData:[(NSString *)result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) probe = json;
        }
        if (!probe) {
            [self zs_failWithReason:error.localizedDescription ?: @"couldn't read the animation timing"];
            return;
        }

        ZLog(@"[Logo] %@: probe animated=%d periods=%@ end=%.0fms lead=%.0fms", self->_path.lastPathComponent, [probe[@"anim"] boolValue], [probe[@"periods"] componentsJoinedByString:@","] ?: @"", [probe[@"end"] doubleValue], [probe[@"lead"] doubleValue]);
        double duration = 0;
        double lead = 0;
        zs_logo_transcode_plan(probe, &duration, &lead);
        self->_leadMs = lead;
        self->_frameCount = duration > 0 ? (NSUInteger)MAX(1, llround(duration * (double)kZSLogoTranscodeFPS / 1000.0)) : 1;
        zs_logo_transcode_geometry(self->_svg.size, self->_scale, &self->_pixelWidth, &self->_pixelHeight);
        self->_pointSize = CGSizeMake((CGFloat)self->_pixelWidth / (CGFloat)self->_scale, (CGFloat)self->_pixelHeight / (CGFloat)self->_scale);
        ZLog(@"[Logo] %@: plan %lu frame(s) at %zux%zu px, %ld fps, loop %.2fs, lead %.0fms", self->_path.lastPathComponent, (unsigned long)self->_frameCount, self->_pixelWidth, self->_pixelHeight, (long)kZSLogoTranscodeFPS, duration / 1000.0, lead);

        self->_web.frame = CGRectMake(0, 0, self->_pointSize.width, self->_pointSize.height);
        self->_viewportAttempt = 0;
        [self zs_waitForViewport];
    }];
}

- (void)zs_waitForViewport {
    NSUInteger step = [self zs_beginStep];
    [_web evaluateJavaScript:@"window.innerWidth+','+window.innerHeight" completionHandler:^(id result, NSError *error) {
        if (![self zs_stepIsCurrent:step]) return;
        [self zs_endStep];
        if (error) {
            [self zs_failWithReason:error.localizedDescription];
            return;
        }
        BOOL matched = NO;
        if ([result isKindOfClass:[NSString class]]) {
            NSArray<NSString *> *parts = [(NSString *)result componentsSeparatedByString:@","];
            if (parts.count == 2) {
                matched = fabs(parts[0].doubleValue - self->_pointSize.width) < 1.5 && fabs(parts[1].doubleValue - self->_pointSize.height) < 1.5;
            }
        }
        if (matched || ++self->_viewportAttempt >= kZSLogoTranscodeViewportAttempts) {
            ZLog(@"[Logo] %@: viewport %@ after %lu check(s), %.2fs since start", self->_path.lastPathComponent, matched ? @"ready" : @"never matched, continuing anyway", (unsigned long)self->_viewportAttempt + (matched ? 1 : 0), CFAbsoluteTimeGetCurrent() - self->_jobStart);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self zs_beginCapture];
            });
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_finished || self->_closing) return;
            [self zs_waitForViewport];
        });
    }];
}

- (void)zs_beginCapture {
    if (_finished || _closing) return;
    size_t bytes = _pixelWidth * _pixelHeight * 4;
    _black = malloc(bytes);
    _white = malloc(bytes);
    _writer = [[ZSLogoVideoWriter alloc] initWithFinalPath:_videoPath width:_pixelWidth height:_pixelHeight frameCount:_frameCount];
    if (!_black || !_white || ![_writer open]) {
        [self zs_failWithReason:@"couldn't start the HEVC writer"];
        return;
    }
    _queue = dispatch_queue_create("zs.logo.transcode", DISPATCH_QUEUE_SERIAL);
    _captureStart = CFAbsoluteTimeGetCurrent();
    _lastLog = _captureStart;
    ZLog(@"[Logo] %@: capture started, %.2fs of setup, %.1f MB of buffers", _path.lastPathComponent, _captureStart - _jobStart, (double)(bytes * 2) / (1024.0 * 1024.0));
    [self zs_captureNextFrame];
}

- (void)zs_runScript:(NSString *)script then:(void (^)(void))next {
    NSUInteger step = [self zs_beginStep];
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    [_web evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (![self zs_stepIsCurrent:step]) return;
        [self zs_endStep];
        if (error) {
            [self zs_failWithReason:error.localizedDescription ?: @"script failed"];
            return;
        }
        self->_scriptSeconds += CFAbsoluteTimeGetCurrent() - began;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZSLogoTranscodeSettleDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_finished || self->_closing) return;
            next();
        });
    }];
}

- (void)zs_snapshot:(void (^)(UIImage *image))next {
    NSUInteger step = [self zs_beginStep];
    WKSnapshotConfiguration *configuration = [[WKSnapshotConfiguration alloc] init];
    configuration.rect = CGRectMake(0, 0, _pointSize.width, _pointSize.height);
    configuration.snapshotWidth = @(_pointSize.width);
    configuration.afterScreenUpdates = YES;
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    [_web takeSnapshotWithConfiguration:configuration completionHandler:^(UIImage *image, NSError *error) {
        if (![self zs_stepIsCurrent:step]) return;
        [self zs_endStep];
        self->_snapshotSeconds += CFAbsoluteTimeGetCurrent() - began;
        self->_snapshotCount++;
        if (!image.CGImage) {
            [self zs_failWithReason:error.localizedDescription ?: @"snapshot failed"];
            return;
        }
        next(image);
    }];
}

- (void)zs_captureNextFrame {
    if (_finished || _closing) return;
    if (_nextFrame >= _frameCount) {
        [self zs_finishIfDrained];
        return;
    }
    if (_inFlight >= 2) {
        _waiting = YES;
        return;
    }

    NSUInteger index = _nextFrame++;
    double time = _leadMs + (double)index * 1000.0 / (double)kZSLogoTranscodeFPS;
    NSString *seek = [NSString stringWithFormat:kZSLogoSVGSeekScript, time, @"#000"];
    NSString *whiten = [NSString stringWithFormat:kZSLogoSVGBackgroundScript, @"#fff"];

    [self zs_runScript:seek then:^{
        [self zs_snapshot:^(UIImage *black) {
            [self zs_runScript:whiten then:^{
                [self zs_snapshot:^(UIImage *white) {
                    [self zs_enqueueBlack:black white:white index:index];
                    [self zs_captureNextFrame];
                }];
            }];
        }];
    }];
}

- (void)zs_enqueueBlack:(UIImage *)black white:(UIImage *)white index:(NSUInteger)index {
    _inFlight++;
    _enqueuedCount++;
    CGImageRef blackImage = CGImageRetain(black.CGImage);
    CGImageRef whiteImage = CGImageRetain(white.CGImage);
    size_t width = _pixelWidth;
    size_t height = _pixelHeight;
    ZSLogoVideoWriter *writer = _writer;
    uint8_t *blackBuffer = _black;
    uint8_t *whiteBuffer = _white;

    dispatch_async(_queue, ^{
        CFAbsoluteTime encodeBegan = CFAbsoluteTimeGetCurrent();
        BOOL ok = zs_logo_draw_snapshot(blackImage, blackBuffer, width, height) && zs_logo_draw_snapshot(whiteImage, whiteBuffer, width, height);
        CGImageRelease(blackImage);
        CGImageRelease(whiteImage);
        if (ok) ok = [writer appendOnBlack:blackBuffer onWhite:whiteBuffer];
        double spent = CFAbsoluteTimeGetCurrent() - encodeBegan;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_inFlight--;
            self->_encodeSeconds += spent;
            if (ok) {
                self->_encodedFrames++;
                [self zs_logProgress];
            }
            if (!ok) {
                [self zs_failWithReason:@"couldn't encode a frame"];
                return;
            }
            if (self->_waiting) {
                self->_waiting = NO;
                [self zs_captureNextFrame];
            } else {
                [self zs_finishIfDrained];
            }
        });
    });
}

- (void)zs_logProgress {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL last = _encodedFrames == _frameCount;
    if (!last && _encodedFrames != 1 && now - _lastLog < 2.0) return;
    _lastLog = now;
    double elapsed = now - _captureStart;
    double perFrame = elapsed / (double)_encodedFrames;
    double remaining = perFrame * (double)(_frameCount - _encodedFrames);
    double snaps = MAX(_snapshotCount, 1);
    double frames = MAX(_encodedFrames, 1);
    ZLog(@"[Logo] %@: encoded %lu/%lu (%.0f%%) in %.1fs, %.0f ms/frame (script %.0f, snapshot %.0f x2, encode %.0f), ~%.1fs left",
         _path.lastPathComponent, (unsigned long)_encodedFrames, (unsigned long)_frameCount,
         100.0 * (double)_encodedFrames / (double)_frameCount, elapsed, perFrame * 1000.0,
         _scriptSeconds / frames * 1000.0, _snapshotSeconds / snaps * 1000.0, _encodeSeconds / frames * 1000.0, remaining);
}

- (void)zs_finishIfDrained {
    if (_finished || _closing || _enqueuedCount < _frameCount || _inFlight > 0) return;
    _closing = YES;
    [self zs_teardownWeb];
    ZSLogoVideoWriter *writer = _writer;
    dispatch_async(_queue, ^{
        [writer finishCommitting:YES completion:^(BOOL ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                unsigned long long size = [[NSFileManager defaultManager] attributesOfItemAtPath:self->_videoPath error:nil].fileSize;
                ZLog(@"[Logo] %@: HEVC %@, %.1f MB, %.1fs total (%.1fs capturing)", self->_path.lastPathComponent, ok ? @"written" : @"FAILED to finalize", (double)size / (1024.0 * 1024.0), CFAbsoluteTimeGetCurrent() - self->_jobStart, CFAbsoluteTimeGetCurrent() - self->_captureStart);
                [self zs_completeWithSuccess:ok];
            });
        }];
    });
}

- (void)zs_failWithReason:(NSString *)reason {
    if (_finished || _closing) return;
    _closing = YES;
    ZLog(@"[Logo] SVG transcode failed for %@: %@", _path.lastPathComponent, reason);
    [self zs_teardownWeb];
    ZSLogoVideoWriter *writer = _writer;
    if (!writer) {
        [self zs_completeWithSuccess:NO];
        return;
    }
    dispatch_queue_t queue = _queue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_async(queue, ^{
        [writer finishCommitting:NO completion:^(BOOL ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self zs_completeWithSuccess:NO];
            });
        }];
    });
}

- (void)zs_teardownWeb {
    _web.navigationDelegate = nil;
    [_web stopLoading];
    [_web removeFromSuperview];
    [_host removeFromSuperview];
    _web = nil;
    _host = nil;
}

- (void)zs_completeWithSuccess:(BOOL)success {
    if (_finished) return;
    _finished = YES;
    [self zs_teardownWeb];
    free(_black);
    free(_white);
    _writer = nil;
    _black = NULL;
    _white = NULL;
    void (^completion)(NSString *) = self.completion;
    self.completion = nil;
    if (completion) completion(success ? _videoPath : nil);
}

@end

static NSMutableArray<NSString *> *zs_logo_transcode_queue(void) {
    static NSMutableArray<NSString *> *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = [NSMutableArray array]; });
    return queue;
}

static NSMutableDictionary<NSString *, NSDate *> *zs_logo_transcode_failures(void) {
    static NSMutableDictionary<NSString *, NSDate *> *failures;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ failures = [NSMutableDictionary dictionary]; });
    return failures;
}

static NSString *gZSLogoTranscodeActive;
static ZSLogoSVGJob *gZSLogoTranscodeJob;

static void zs_logo_transcode_pump(void);

static void zs_logo_transcode_finish_active(NSString *videoPath) {
    gZSLogoTranscodeActive = nil;
    gZSLogoTranscodeJob = nil;
    if (videoPath) [[NSNotificationCenter defaultCenter] postNotificationName:ZSLogoDidChangeNotification object:nil];
    zs_logo_transcode_pump();
}

static void zs_logo_transcode_pump(void) {
    if (gZSLogoTranscodeActive || zs_logo_transcode_queue().count == 0) return;
    NSString *path = zs_logo_transcode_queue().firstObject;
    [zs_logo_transcode_queue() removeObjectAtIndex:0];
    gZSLogoTranscodeActive = path;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ZSLogoSVG *svg = zs_logo_svg_for_path(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!svg) {
                ZLog(@"[Logo] %@ isn't a readable SVG", path.lastPathComponent);
                zs_logo_transcode_failures()[path] = [NSDate date];
                zs_logo_transcode_finish_active(nil);
                return;
            }
            ZSLogoSVGJob *job = [[ZSLogoSVGJob alloc] initWithPath:path svg:svg];
            gZSLogoTranscodeJob = job;
            job.completion = ^(NSString *videoPath) {
                if (!videoPath) {
                    zs_logo_transcode_failures()[path] = [NSDate date];
                    zs_logo_transcode_finish_active(nil);
                    return;
                }
                [zs_logo_transcode_failures() removeObjectForKey:path];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    CFAbsoluteTime loadBegan = CFAbsoluteTimeGetCurrent();
                    zs_logo_transcode_prune(path, videoPath);
                    ZSLogoVideo *video = zs_logo_video_for_path(videoPath);
                    if (video) ZLog(@"[Logo] %@: %lu frame(s) loaded into memory in %.2fs", path.lastPathComponent, (unsigned long)video.count, CFAbsoluteTimeGetCurrent() - loadBegan);
                    else ZLog(@"[Logo] couldn't read back the HEVC movie for %@", path.lastPathComponent);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        zs_logo_transcode_finish_active(video ? videoPath : nil);
                    });
                });
            };
            [job start];
        });
    });
}

static void zs_logo_transcode_svg_notify(NSString *svgPath) {
    if (svgPath.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (zs_logo_ready_video_path(svgPath)) return;
        NSDate *failedAt = zs_logo_transcode_failures()[svgPath];
        if (failedAt && -failedAt.timeIntervalSinceNow < kZSLogoTranscodeRetryInterval) return;
        if ([gZSLogoTranscodeActive isEqualToString:svgPath] || [zs_logo_transcode_queue() containsObject:svgPath]) return;
        [zs_logo_transcode_queue() addObject:svgPath];
        ZLog(@"[Logo] %@: queued for transcoding (%lu waiting, %@)", svgPath.lastPathComponent, (unsigned long)zs_logo_transcode_queue().count, gZSLogoTranscodeActive ? @"another job is running" : @"starting now");
        zs_logo_transcode_pump();
    });
}

static void zs_logo_transcode_pack_directory(NSString *directory) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *meta = zs_logo_read_meta_in(directory);
    NSString *styleFile = meta[kZSLogoRoleStyle][@"file"];
    NSString *stylePath = [styleFile isKindOfClass:[NSString class]] && styleFile.length > 0
        ? [directory stringByAppendingPathComponent:styleFile.lastPathComponent]
        : nil;
    ZSLogoStyle *style = zs_logo_load_style(stylePath);

    for (NSString *role in @[kZSLogoRoleFill, kZSLogoRoleVfx]) {
        NSString *file = meta[role][@"file"];
        if (![file isKindOfClass:[NSString class]] || !zs_logo_is_svg_file(file)) continue;
        BOOL enabled = [role isEqualToString:kZSLogoRoleFill] ? style.fill.enabled : style.vfx.enabled;
        NSString *path = [directory stringByAppendingPathComponent:file.lastPathComponent];
        if (enabled && [fm fileExistsAtPath:path]) zs_logo_transcode_svg_notify(path);
    }
}

static NSString *zs_logo_effect_asset_path(NSString *path) {
    if (path.length == 0) return nil;
    if (!zs_logo_is_svg_file(path)) return path;
    NSString *video = zs_logo_ready_video_path(path);
    if (video) return video;
    zs_logo_transcode_svg_notify(path);
    return nil;
}

static void zs_logo_svg_remove_legacy_cache(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = zs_logo_cache_directory();
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil]) {
        if (name.length != 12 || ![name hasPrefix:@"svg-"]) continue;
        if ([[name substringFromIndex:4] rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) continue;
        NSString *directory = [root stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:[directory stringByAppendingPathComponent:@"meta.plist"]]) continue;
        [fm removeItemAtPath:directory error:nil];
    }
}

@interface ZSLogoFrameClock : NSObject
+ (instancetype)shared;
- (void)addView:(ZSLogoEffectView *)view;
- (void)removeView:(ZSLogoEffectView *)view;
@end

@implementation ZSLogoFrameClock {
    NSHashTable<ZSLogoEffectView *> *_views;
    CADisplayLink *_link;
    CFTimeInterval _last;
}

+ (instancetype)shared {
    static ZSLogoFrameClock *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ZSLogoFrameClock alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) _views = [NSHashTable weakObjectsHashTable];
    return self;
}

- (void)addView:(ZSLogoEffectView *)view {
    [_views addObject:view];
    [self zs_updateLink];
}

- (void)removeView:(ZSLogoEffectView *)view {
    if (![_views containsObject:view]) return;
    [_views removeObject:view];
    [self zs_updateLink];
}

- (void)zs_updateLink {
    BOOL needed = _views.allObjects.count > 0;
    if (needed && !_link) {
        _last = 0;
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_tick:)];
        if (@available(iOS 15.0, *)) {
            _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
        } else {
            _link.preferredFramesPerSecond = 60;
        }
        [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!needed && _link) {
        [_link invalidate];
        _link = nil;
    }
}

- (void)zs_tick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    NSTimeInterval delta = _last > 0 ? MIN(now - _last, 0.25) : 0;
    _last = now;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (ZSLogoEffectView *view in _views.allObjects) [view zs_advanceBy:delta];
    [CATransaction commit];
}

@end

@implementation ZSLogoEffectView {
    UIView *_clipView;
    CALayer *_clipLayer;
    CALayer *_contentLayer;
    CALayer *_maskLayer;
    ZSLogoAnimation *_animation;
    ZSLogoVideo *_video;
    ZSLogoVideoDecoder *_decoder;
    CVPixelBufferRef _shownBuffer;
    BOOL _decoding;
    NSString *_path;
    id _activeObserver;
    UIImage *_maskImage;
    NSAttributedString *_maskText;
    CGSize _maskSize;
    NSTimeInterval _playhead;
    NSInteger _shownIndex;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = NO;
        self.backgroundColor = UIColor.clearColor;
        _shownIndex = -1;

        _clipView = [[UIView alloc] initWithFrame:CGRectZero];
        _clipView.userInteractionEnabled = NO;
        _clipView.backgroundColor = UIColor.clearColor;
        _clipLayer = _clipView.layer;
        _contentLayer = [CALayer layer];
        _contentLayer.contentsGravity = kCAGravityResize;
        [_clipLayer addSublayer:_contentLayer];
        [self addSubview:_clipView];

        __weak typeof(self) weakSelf = self;
        _activeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                            object:nil
                                                                             queue:[NSOperationQueue mainQueue]
                                                                        usingBlock:^(NSNotification *note) {
            [weakSelf zs_applyFrames];
        }];
    }
    return self;
}

- (void)dealloc {
    if (_activeObserver) [[NSNotificationCenter defaultCenter] removeObserver:_activeObserver];
    [[ZSLogoFrameClock shared] removeView:self];
    [_decoder invalidate];
    if (_shownBuffer) CVPixelBufferRelease(_shownBuffer);
}

- (void)setLayerStyle:(ZSLogoLayerStyle *)layerStyle {
    _layerStyle = layerStyle;
    self.alpha = layerStyle.opacity;
    self.layer.compositingFilter = layerStyle.compositingFilter;
    [self setNeedsLayout];
    [self zs_applyFrames];
}

- (void)setAnimationsPaused:(BOOL)animationsPaused {
    if (_animationsPaused == animationsPaused) return;
    _animationsPaused = animationsPaused;
    [self zs_applyFrames];
}

- (void)loadAssetAtPath:(NSString *)path {
    _path = [path copy];
    __weak typeof(self) weakSelf = self;

    if (zs_logo_is_transcoded_path(path)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            ZSLogoVideo *video = zs_logo_video_for_path(path);
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf->_path isEqualToString:path]) return;
                [strongSelf zs_setVideo:video];
            });
        });
        return;
    }

    ZSLogoAnimation *cached = zs_logo_cached_animation(path);
    if (cached) {
        [self zs_setAnimation:cached];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ZSLogoAnimation *decoded = zs_logo_animation_for_path(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf->_path isEqualToString:path]) return;
            [strongSelf zs_setAnimation:decoded];
        });
    });
}

- (void)zs_dropDecoder {
    [_decoder invalidate];
    _decoder = nil;
    _decoding = NO;
    if (_shownBuffer) {
        CVPixelBufferRelease(_shownBuffer);
        _shownBuffer = NULL;
    }
}

- (void)releaseAssets {
    [[ZSLogoFrameClock shared] removeView:self];
    [self zs_dropDecoder];
    _video = nil;
    _shownIndex = -1;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _contentLayer.contents = nil;
    [CATransaction commit];
}

- (void)zs_setAnimation:(ZSLogoAnimation *)animation {
    [self zs_dropDecoder];
    _video = nil;
    _animation = animation;
    [self setNeedsLayout];
    [self zs_applyFrames];
}

- (void)zs_setVideo:(ZSLogoVideo *)video {
    [self zs_dropDecoder];
    _animation = nil;
    _video = video;
    _decoder = video ? [[ZSLogoVideoDecoder alloc] initWithVideo:video] : nil;
    _playhead = 0;
    _shownIndex = -1;
    [self setNeedsLayout];
    [self zs_applyFrames];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self zs_applyFrames];
}

- (void)zs_showVideoFrame {
    ZSLogoVideo *video = _video;
    ZSLogoVideoDecoder *decoder = _decoder;
    NSUInteger count = video.count;
    if (count == 0 || !decoder || _decoding) return;
    NSUInteger index = 0;
    if (count > 1) {
        index = (NSUInteger)llround(_playhead / video.frameDuration);
        if (index >= count) index = 0;
    }
    if ((NSInteger)index == _shownIndex && _contentLayer.contents) return;

    _decoding = YES;
    __weak typeof(self) weakSelf = self;
    [decoder decodeIndex:index completion:^(CVPixelBufferRef buffer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_decoder != decoder) return;
        strongSelf->_decoding = NO;
        if (!buffer) return;
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
        if (!surface) return;
        CVPixelBufferRef previous = strongSelf->_shownBuffer;
        strongSelf->_shownBuffer = CVPixelBufferRetain(buffer);
        strongSelf->_shownIndex = (NSInteger)index;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        strongSelf->_contentLayer.contents = (__bridge id)surface;
        [CATransaction commit];
        if (previous) CVPixelBufferRelease(previous);
    }];
}

- (void)zs_advanceBy:(NSTimeInterval)delta {
    ZSLogoVideo *video = _video;
    if (!video || video.count < 2) return;
    CGFloat speed = _layerStyle ? _layerStyle.speed : 1;
    if (speed <= 0 || _animationsPaused || !self.window) return;
    NSTimeInterval total = video.frameDuration * (NSTimeInterval)video.count;
    _playhead += delta * speed;
    if (_playhead >= total) _playhead = fmod(_playhead, total);
    [self zs_showVideoFrame];
}

- (void)zs_applyVideoPlayback {
    ZSLogoVideo *video = _video;
    CGFloat speed = _layerStyle ? _layerStyle.speed : 1;
    if (speed <= 0) _playhead = 0;
    [self zs_showVideoFrame];

    BOOL animating = video.count > 1 && speed > 0 && !_animationsPaused && self.window != nil;
    if (animating) [[ZSLogoFrameClock shared] addView:self];
    else [[ZSLogoFrameClock shared] removeView:self];
}

- (void)zs_applyFrames {
    [_contentLayer removeAnimationForKey:kZSLogoFrameAnimationKey];

    if (_video) {
        [self zs_applyVideoPlayback];
        return;
    }
    [[ZSLogoFrameClock shared] removeView:self];

    ZSLogoAnimation *animation = _animation;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _contentLayer.contents = animation.frames.firstObject;
    [CATransaction commit];

    if (!animation || animation.frames.count < 2 || animation.duration <= 0) return;
    if (_layerStyle.speed <= 0 || _animationsPaused || !self.window) return;

    CAKeyframeAnimation *frames = [CAKeyframeAnimation animationWithKeyPath:@"contents"];
    frames.calculationMode = kCAAnimationDiscrete;
    frames.values = animation.frames;
    frames.keyTimes = animation.keyTimes;
    frames.duration = animation.duration / _layerStyle.speed;
    frames.repeatCount = HUGE_VALF;
    frames.removedOnCompletion = NO;
    [_contentLayer addAnimation:frames forKey:kZSLogoFrameAnimationKey];
}
- (UIImage *)zs_renderTextMask {
    UILabel *label = self.label;
    CGSize size = self.bounds.size;
    if (!label || label.attributedText.length == 0 || size.width <= 0 || size.height <= 0) return nil;

    NSMutableAttributedString *text = [label.attributedText mutableCopy];
    NSRange all = NSMakeRange(0, text.length);
    [text removeAttribute:NSShadowAttributeName range:all];
    [text removeAttribute:NSStrokeWidthAttributeName range:all];
    [text removeAttribute:NSStrokeColorAttributeName range:all];
    [text addAttribute:NSForegroundColorAttributeName value:UIColor.blackColor range:all];

    UILabel *probe = [[UILabel alloc] initWithFrame:(CGRect){CGPointZero, size}];
    probe.backgroundColor = UIColor.clearColor;
    probe.numberOfLines = label.numberOfLines;
    probe.lineBreakMode = label.lineBreakMode;
    probe.textAlignment = label.textAlignment;
    probe.attributedText = text;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [probe.layer renderInContext:context.CGContext];
    }];
}

- (UIImage *)zs_cachedTextMask {
    NSAttributedString *text = self.label.attributedText;
    CGSize size = self.bounds.size;
    if (_maskImage && CGSizeEqualToSize(_maskSize, size) && text && [_maskText isEqualToAttributedString:text]) {
        return _maskImage;
    }
    _maskImage = [self zs_renderTextMask];
    _maskSize = size;
    _maskText = [text copy];
    return _maskImage;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    ZSLogoLayerStyle *style = self.layerStyle;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _clipView.frame = bounds;

    BOOL masked = self.fillsText || style.maskToText;
    UIImage *maskImage = nil;
    if (masked) {
        maskImage = [self zs_cachedTextMask];
    } else {
        _maskImage = nil;
        _maskText = nil;
    }
    if (maskImage) {
        if (!_maskLayer) _maskLayer = [CALayer layer];
        _maskLayer.frame = _clipLayer.bounds;
        if (_maskLayer.contents != (__bridge id)maskImage.CGImage) {
            _maskLayer.contentsScale = maskImage.scale;
            _maskLayer.contents = (__bridge id)maskImage.CGImage;
        }
        if (_clipLayer.mask != _maskLayer) _clipLayer.mask = _maskLayer;
    } else if (_clipLayer.mask) {
        _clipLayer.mask = nil;
    }

    CGSize imageSize = _video ? _video.size : _animation.size;
    if (imageSize.width > 0 && imageSize.height > 0 && bounds.size.width > 0 && bounds.size.height > 0) {
        CGFloat aspect = imageSize.width / imageSize.height;
        CGFloat width, height;
        if (self.fillsText) {
            if (bounds.size.width / bounds.size.height > aspect) {
                width = bounds.size.width;
                height = width / aspect;
            } else {
                height = bounds.size.height;
                width = height * aspect;
            }
        } else {
            width = bounds.size.width;
            height = width / aspect;
        }
        width *= style.scale;
        height *= style.scale;

        CGPoint position = CGPointMake(CGRectGetMidX(bounds) + style.offset.width,
                                       CGRectGetMidY(bounds) + style.offset.height);
        CGFloat radians = style.rotation * M_PI / 180.0;

        _contentLayer.transform = CATransform3DIdentity;
        _contentLayer.bounds = CGRectMake(0, 0, width, height);
        _contentLayer.position = position;
        _contentLayer.transform = CATransform3DMakeRotation(radians, 0, 0, 1);
        _contentLayer.hidden = NO;
    } else {
        _contentLayer.hidden = YES;
    }

    [CATransaction commit];
}

@end

static const void *kZSLogoEffectsKey = &kZSLogoEffectsKey;
static BOOL gZSLogoEffectsPaused = NO;

static NSHashTable<ZSLogoEffectView *> *zs_logo_effect_views(void) {
    static NSHashTable<ZSLogoEffectView *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

void zs_logo_effects_detach(UILabel *label) {
    if (!label) return;
    NSArray<UIView *> *views = objc_getAssociatedObject(label, kZSLogoEffectsKey);
    for (UIView *view in views) {
        if ([view isKindOfClass:[ZSLogoEffectView class]]) [(ZSLogoEffectView *)view releaseAssets];
        [view removeFromSuperview];
    }
    objc_setAssociatedObject(label, kZSLogoEffectsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static ZSLogoEffectView *zs_logo_make_effect_view(UILabel *label, ZSLogoLayerStyle *style, NSString *path, BOOL fillsText) {
    ZSLogoEffectView *view = [[ZSLogoEffectView alloc] initWithFrame:CGRectZero];
    view.label = label;
    view.fillsText = fillsText;
    view.animationsPaused = gZSLogoEffectsPaused;
    view.layerStyle = style;
    [zs_logo_effect_views() addObject:view];
    [view loadAssetAtPath:path];
    return view;
}

static void zs_logo_pin_effect_view(UIView *view, UIView *label) {
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:label.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:label.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:label.bottomAnchor],
    ]];
}

void zs_logo_effects_attach(UILabel *label) {
    zs_logo_effects_detach(label);

    UIView *parent = label.superview;
    ZSLogoPack *pack = zs_logo_selected_pack();
    if (!parent || !pack) return;

    ZSLogoStyle *style = pack.style;
    NSMutableArray<UIView *> *attached = [NSMutableArray array];
    ZSLogoEffectView *fill = nil;

    NSString *fillAsset = pack.fillPath && style.fill.enabled ? zs_logo_effect_asset_path(pack.fillPath) : nil;
    if (fillAsset) {
        fill = zs_logo_make_effect_view(label, style.fill, fillAsset, YES);
        [parent insertSubview:fill aboveSubview:label];
        zs_logo_pin_effect_view(fill, label);
        [attached addObject:fill];
    }

    NSString *vfxAsset = pack.vfxPath && style.vfx.enabled ? zs_logo_effect_asset_path(pack.vfxPath) : nil;
    if (vfxAsset) {
        ZSLogoEffectView *vfx = zs_logo_make_effect_view(label, style.vfx, vfxAsset, NO);
        if (style.vfx.aboveText) {
            UIView *anchor = fill ? (UIView *)fill : (UIView *)label;
            [parent insertSubview:vfx aboveSubview:anchor];
        } else {
            [parent insertSubview:vfx belowSubview:label];
        }
        zs_logo_pin_effect_view(vfx, label);
        [attached addObject:vfx];
    }

    objc_setAssociatedObject(label, kZSLogoEffectsKey, attached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void zs_logo_prewarm(void) {
    ZSLogoPack *pack = zs_logo_selected_pack();
    if (!pack) return;

    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    if (pack.fillPath && pack.style.fill.enabled) [sources addObject:pack.fillPath];
    if (pack.vfxPath && pack.style.vfx.enabled) [sources addObject:pack.vfxPath];

    for (NSString *source in sources) {
        NSString *asset = zs_logo_effect_asset_path(source);
        if (!asset || !zs_logo_is_transcoded_path(asset)) continue;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            (void)zs_logo_video_for_path(asset);
        });
    }
}

__attribute__((constructor)) static void zs_logo_prewarm_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:ZSLogoDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            zs_logo_prewarm();
        }];
        zs_logo_prewarm();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            zs_logo_svg_remove_legacy_cache();
        });
        for (NSNumber *delay in @[@3, @10]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                zs_logo_prewarm();
            });
        }
    });
}

void zs_logo_effects_set_paused(BOOL paused) {
    gZSLogoEffectsPaused = paused;
    for (ZSLogoEffectView *view in zs_logo_effect_views().allObjects) view.animationsPaused = paused;
}

#pragma mark - Import

@interface ZSLogoSourceEntry : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) uint64_t size;
@property (nonatomic, copy) NSData *(^load)(NSString **errorOut);
@end

@implementation ZSLogoSourceEntry
@end

#pragma mark - Zip import

@interface ZSLogoZipRecord : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) uint16_t method;
@property (nonatomic, assign) uint16_t flags;
@property (nonatomic, assign) uint32_t crc;
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t uncompressedSize;
@property (nonatomic, assign) uint32_t localOffset;
@end

@implementation ZSLogoZipRecord
@end

static const NSUInteger kZSLogoZipMaxEntries = 4096;
static const uint32_t kZSLogoZipMaxEntrySize = 64 * 1024 * 1024;
static const uint64_t kZSLogoZipMaxTotalSize = 160ull * 1024 * 1024;

static uint16_t zs_zip_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t zs_zip_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint32_t zs_zip_crc32(const uint8_t *bytes, size_t length) {
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

static NSArray<ZSLogoZipRecord *> *zs_zip_records(NSData *data, NSString **errorOut) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSString *notZip = @"That file isn't a valid zip archive.";
    if (length < 22) {
        *errorOut = notZip;
        return nil;
    }

    NSInteger eocd = -1;
    NSInteger lowest = (NSInteger)length - (NSInteger)MIN((NSUInteger)(22 + 65535), length);
    for (NSInteger i = (NSInteger)length - 22; i >= lowest; i--) {
        const uint8_t *p = bytes + i;
        if (zs_zip_u32(p) == 0x06054b50 && i + 22 + zs_zip_u16(p + 20) == (NSInteger)length) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        *errorOut = notZip;
        return nil;
    }

    const uint8_t *end = bytes + eocd;
    uint16_t count = zs_zip_u16(end + 10);
    uint32_t cdSize = zs_zip_u32(end + 12);
    uint32_t cdOffset = zs_zip_u32(end + 16);
    if (count == 0xFFFF || cdSize == 0xFFFFFFFFu || cdOffset == 0xFFFFFFFFu) {
        *errorOut = @"Zip64 archives aren't supported.";
        return nil;
    }
    if ((NSUInteger)cdOffset + cdSize > length || count > kZSLogoZipMaxEntries) {
        *errorOut = notZip;
        return nil;
    }

    NSMutableArray<ZSLogoZipRecord *> *records = [NSMutableArray arrayWithCapacity:count];
    NSUInteger cursor = cdOffset;
    NSUInteger cdEnd = (NSUInteger)cdOffset + cdSize;
    for (uint16_t i = 0; i < count && cursor + 46 <= cdEnd; i++) {
        const uint8_t *p = bytes + cursor;
        if (zs_zip_u32(p) != 0x02014b50) break;

        uint16_t nameLength = zs_zip_u16(p + 28);
        uint16_t extraLength = zs_zip_u16(p + 30);
        uint16_t commentLength = zs_zip_u16(p + 32);
        NSUInteger nameStart = cursor + 46;
        if (nameStart + nameLength > cdEnd) break;

        NSString *path = [[NSString alloc] initWithBytes:bytes + nameStart length:nameLength encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithBytes:bytes + nameStart length:nameLength encoding:NSISOLatin1StringEncoding];

        ZSLogoZipRecord *record = [[ZSLogoZipRecord alloc] init];
        record.path = path ?: @"";
        record.flags = zs_zip_u16(p + 8);
        record.method = zs_zip_u16(p + 10);
        record.crc = zs_zip_u32(p + 16);
        record.compressedSize = zs_zip_u32(p + 20);
        record.uncompressedSize = zs_zip_u32(p + 24);
        record.localOffset = zs_zip_u32(p + 42);
        [records addObject:record];

        cursor = nameStart + nameLength + extraLength + commentLength;
    }
    return records;
}

static NSData *zs_zip_extract(NSData *zip, ZSLogoZipRecord *record, NSString **errorOut) {
    NSString *label = record.path.lastPathComponent;
    if (record.flags & 1) {
        *errorOut = [NSString stringWithFormat:@"%@ is encrypted.", label];
        return nil;
    }
    if (record.method != 0 && record.method != 8) {
        *errorOut = [NSString stringWithFormat:@"%@ uses an unsupported compression method.", label];
        return nil;
    }
    if (record.uncompressedSize > kZSLogoZipMaxEntrySize) {
        *errorOut = [NSString stringWithFormat:@"%@ is too large.", label];
        return nil;
    }

    const uint8_t *bytes = zip.bytes;
    NSUInteger offset = record.localOffset;
    if (offset + 30 > zip.length || zs_zip_u32(bytes + offset) != 0x04034b50) {
        *errorOut = [NSString stringWithFormat:@"%@ is corrupt.", label];
        return nil;
    }
    NSUInteger dataStart = offset + 30 + zs_zip_u16(bytes + offset + 26) + zs_zip_u16(bytes + offset + 28);
    if (dataStart + record.compressedSize > zip.length) {
        *errorOut = [NSString stringWithFormat:@"%@ is corrupt.", label];
        return nil;
    }

    NSData *result;
    if (record.method == 0) {
        result = [zip subdataWithRange:NSMakeRange(dataStart, record.compressedSize)];
    } else if (record.uncompressedSize == 0) {
        result = [NSData data];
    } else {
        NSMutableData *out = [NSMutableData dataWithLength:record.uncompressedSize];
        size_t decoded = compression_decode_buffer(out.mutableBytes, record.uncompressedSize,
                                                   bytes + dataStart, record.compressedSize,
                                                   NULL, COMPRESSION_ZLIB);
        if (decoded != record.uncompressedSize) {
            *errorOut = [NSString stringWithFormat:@"%@ is corrupt.", label];
            return nil;
        }
        result = out;
    }

    if (result.length != record.uncompressedSize || zs_zip_crc32(result.bytes, result.length) != record.crc) {
        *errorOut = [NSString stringWithFormat:@"%@ failed its integrity check.", label];
        return nil;
    }
    return result;
}

static BOOL zs_logo_font_data_is_valid(NSData *data) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if (!provider) return NO;
    CGFontRef font = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (!font) return NO;
    CGFontRelease(font);
    return YES;
}

static NSString *zs_logo_import_resolve_name(NSString *rawName, NSMutableSet<NSString *> *used, NSSet<NSString *> *remoteNames) {
    NSString *name = [rawName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    name = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"-"];
    while ([name hasPrefix:@"."]) name = [name substringFromIndex:1];
    if (name.length > 100) name = [name substringToIndex:100];
    if (name.length == 0 || [name caseInsensitiveCompare:kZSLogoDefaultName] == NSOrderedSame) name = @"Imported Logo";
    if ([remoteNames containsObject:name]) name = [name stringByAppendingString:@" (Local)"];

    NSString *candidate = name;
    NSUInteger suffix = 2;
    while ([used containsObject:candidate]) {
        candidate = [NSString stringWithFormat:@"%@ %lu", name, (unsigned long)suffix++];
    }
    [used addObject:candidate];
    return candidate;
}

static BOOL zs_logo_import_commit(NSString *name, NSDictionary<NSString *, NSArray *> *files) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = zs_logo_local_root();
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *staging = [root stringByAppendingPathComponent:[@".import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil]) return NO;

    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    for (NSString *role in files) {
        NSString *file = files[role][0];
        NSData *data = files[role][1];
        if (![data writeToFile:[staging stringByAppendingPathComponent:file] atomically:YES]) {
            [fm removeItemAtPath:staging error:nil];
            return NO;
        }
        meta[role] = @{@"file": file, @"sha": @""};
    }
    NSData *metaData = [NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
    [metaData writeToFile:[staging stringByAppendingPathComponent:@"meta.json"] atomically:YES];

    NSString *target = zs_logo_local_directory(name);
    [fm removeItemAtPath:target error:nil];
    if (![fm moveItemAtPath:staging toPath:target error:nil]) {
        [fm removeItemAtPath:staging error:nil];
        return NO;
    }
    zs_logo_invalidate_pack(name);
    zs_logo_transcode_pack_directory(target);
    return YES;
}

static NSArray<NSString *> *zs_logo_import_entries(NSArray<ZSLogoSourceEntry *> *entries, NSString *fallbackName, NSString **errorOut) {
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, ZSLogoSourceEntry *> *> *groups = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *groupNames = [NSMutableDictionary dictionary];

    for (ZSLogoSourceEntry *entry in entries) {
        if (entry.path.length == 0 || [entry.path hasSuffix:@"/"]) continue;
        NSArray<NSString *> *components = [entry.path componentsSeparatedByString:@"/"];

        BOOL skip = NO;
        for (NSString *component in components) {
            if (component.length == 0 || [component hasPrefix:@"."] || [component isEqualToString:@"__MACOSX"]) {
                skip = YES;
                break;
            }
        }
        if (skip) continue;

        NSString *filename = components.lastObject;
        if (!zs_logo_is_relevant_file(filename)) continue;

        NSArray<NSString *> *folders = [components subarrayWithRange:NSMakeRange(0, components.count - 1)];
        NSString *groupKey = [folders componentsJoinedByString:@"/"];
        groupNames[groupKey] = folders.count > 0 ? folders.lastObject : fallbackName;

        NSMutableDictionary *group = groups[groupKey];
        if (!group) {
            group = [NSMutableDictionary dictionary];
            groups[groupKey] = group;
        }
        if (!group[filename]) group[filename] = entry;
    }

    NSSet<NSString *> *remoteNames = [NSSet setWithArray:zs_logo_remote_cached_names()];
    NSMutableSet<NSString *> *usedNames = [NSMutableSet set];
    NSMutableArray<NSString *> *imported = [NSMutableArray array];
    NSString *firstError = nil;
    uint64_t totalSize = 0;

    for (NSString *groupKey in [groups.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary<NSString *, ZSLogoSourceEntry *> *group = groups[groupKey];

        NSString *styleName = nil;
        for (NSString *file in group.allKeys) {
            if (zs_logo_is_style_file(file)) {
                styleName = file;
                break;
            }
        }

        NSMutableDictionary<NSString *, NSData *> *loaded = [NSMutableDictionary dictionary];
        BOOL groupOK = YES;

        NSData *styleData = nil;
        if (styleName) {
            ZSLogoSourceEntry *styleEntry = group[styleName];
            totalSize += styleEntry.size;
            NSString *styleError = nil;
            styleData = styleEntry.size <= kZSLogoZipMaxEntrySize ? styleEntry.load(&styleError) : nil;
        }
        NSDictionary *json = zs_logo_parse_style_json(styleData);

        NSString *missing = nil;
        NSDictionary<NSString *, NSString *> *resolved = zs_logo_resolve_roles(json, group.allKeys, &missing);
        if (!resolved[kZSLogoRoleFont]) {
            if (missing) {
                firstError = firstError ?: [NSString stringWithFormat:@"style.json points to %@, which isn't in the folder.", missing];
            }
            continue;
        }

        NSMutableDictionary<NSString *, NSArray *> *files = [NSMutableDictionary dictionary];
        for (NSString *role in @[kZSLogoRoleFont, kZSLogoRoleFill, kZSLogoRoleVfx]) {
            NSString *file = resolved[role];
            if (!file) continue;
            ZSLogoSourceEntry *entry = group[file];
            BOOL isFont = [role isEqualToString:kZSLogoRoleFont];

            NSData *data = loaded[file];
            NSString *extractError = nil;
            if (!data) {
                totalSize += entry.size;
                if (totalSize > kZSLogoZipMaxTotalSize) {
                    firstError = firstError ?: @"The logo files are too large.";
                    groupOK = NO;
                    break;
                }
                data = entry.load(&extractError);
                if (data && isFont && !zs_logo_font_data_is_valid(data)) {
                    data = nil;
                    extractError = [NSString stringWithFormat:@"%@ isn't a readable font.", file];
                }
                if (data) loaded[file] = data;
            }
            if (!data) {
                if (isFont) {
                    firstError = firstError ?: extractError;
                    groupOK = NO;
                    break;
                }
                continue;
            }
            files[role] = @[file, data];
        }
        if (!groupOK) continue;
        if (styleData) files[kZSLogoRoleStyle] = @[kZSLogoStyleFilename, styleData];

        NSString *name = zs_logo_import_resolve_name(groupNames[groupKey], usedNames, remoteNames);
        if (zs_logo_import_commit(name, files)) {
            [imported addObject:name];
        } else {
            firstError = firstError ?: @"Couldn't save the logo.";
        }
    }

    if (imported.count == 0) {
        *errorOut = firstError ?: @"No logo found. Add a .ttf or .otf font, plus optional images or SVGs and a style.json that points to them, in a folder or a zip.";
        return nil;
    }
    return imported;
}

static NSArray<NSString *> *zs_logo_import_zip_sync(NSURL *zipURL, NSString **errorOut) {
    NSData *zip = [NSData dataWithContentsOfURL:zipURL options:NSDataReadingMappedIfSafe error:nil];
    if (!zip) {
        *errorOut = @"Couldn't read that file.";
        return nil;
    }

    NSString *error = nil;
    NSArray<ZSLogoZipRecord *> *records = zs_zip_records(zip, &error);
    if (!records) {
        *errorOut = error;
        return nil;
    }

    NSMutableArray<ZSLogoSourceEntry *> *entries = [NSMutableArray arrayWithCapacity:records.count];
    for (ZSLogoZipRecord *record in records) {
        ZSLogoSourceEntry *entry = [[ZSLogoSourceEntry alloc] init];
        entry.path = record.path;
        entry.size = record.uncompressedSize;
        entry.load = ^NSData *(NSString **loadError) {
            return zs_zip_extract(zip, record, loadError);
        };
        [entries addObject:entry];
    }
    return zs_logo_import_entries(entries, zipURL.lastPathComponent.stringByDeletingPathExtension, errorOut);
}

static NSArray<NSString *> *zs_logo_import_folder_sync(NSURL *folderURL, NSString **errorOut) {
    NSString *root = folderURL.path;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:root];
    if (!enumerator) {
        *errorOut = @"Couldn't read that folder.";
        return nil;
    }

    NSMutableArray<ZSLogoSourceEntry *> *entries = [NSMutableArray array];
    NSUInteger visited = 0;
    for (NSString *relative in enumerator) {
        NSString *name = relative.lastPathComponent;
        NSDictionary *attributes = enumerator.fileAttributes;
        BOOL isDirectory = [attributes.fileType isEqualToString:NSFileTypeDirectory];
        if ([name hasPrefix:@"."] || [name isEqualToString:@"__MACOSX"]) {
            if (isDirectory) [enumerator skipDescendants];
            continue;
        }
        if (++visited > kZSLogoZipMaxEntries) {
            *errorOut = @"That folder has too many files.";
            return nil;
        }
        if (![attributes.fileType isEqualToString:NSFileTypeRegular]) continue;

        NSString *fullPath = [root stringByAppendingPathComponent:relative];
        uint64_t size = attributes.fileSize;
        ZSLogoSourceEntry *entry = [[ZSLogoSourceEntry alloc] init];
        entry.path = relative;
        entry.size = size;
        entry.load = ^NSData *(NSString **loadError) {
            if (size > kZSLogoZipMaxEntrySize) {
                *loadError = [NSString stringWithFormat:@"%@ is too large.", fullPath.lastPathComponent];
                return nil;
            }
            NSData *data = [NSData dataWithContentsOfFile:fullPath options:NSDataReadingMappedIfSafe error:nil];
            if (!data) *loadError = [NSString stringWithFormat:@"Couldn't read %@.", fullPath.lastPathComponent];
            return data;
        };
        [entries addObject:entry];
    }
    return zs_logo_import_entries(entries, folderURL.lastPathComponent, errorOut);
}

static NSArray<NSString *> *zs_logo_import_item_sync(NSURL *url, NSString **errorOut) {
    __block NSArray<NSString *> *result = nil;
    __block NSString *failure = nil;
    NSError *coordinationError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *readURL) {
        NSNumber *isDirectory = nil;
        [readURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        NSString *error = nil;
        result = isDirectory.boolValue ? zs_logo_import_folder_sync(readURL, &error) : zs_logo_import_zip_sync(readURL, &error);
        failure = error;
    }];
    if (!result) *errorOut = failure ?: (coordinationError ? @"Couldn't read that item." : nil);
    return result;
}

void zs_logo_import_item(NSURL *url, ZSLogoImportCompletion completion) {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSArray<NSString *> *names = zs_logo_import_item_sync(url, &error);
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(names ?: @[], names ? nil : (error ?: @"Couldn't add that logo."));
        });
    });
}

