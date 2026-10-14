#import "Logo.h"
#import "Engine.h"
#import "ZTweakLog.h"
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <compression.h>

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
static const CGFloat kZSLogoSVGSettleAlpha = 0.02;
static const NSUInteger kZSLogoSVGSettleMaxAttempts = 40;
static const NSTimeInterval kZSLogoSVGSettlePollInterval = 0.03;
static const NSTimeInterval kZSLogoSVGSettleCommitDelay = 0.08;
static const NSTimeInterval kZSLogoSVGSettleFadeDuration = 0.15;

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

static NSCache<NSString *, ZSLogoSVG *> *zs_logo_svg_cache(void) {
    static NSCache<NSString *, ZSLogoSVG *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 8; });
    return cache;
}

static ZSLogoSVG *zs_logo_svg_for_path(NSString *path) {
    NSString *key = zs_logo_animation_key(path);
    ZSLogoSVG *cached = [zs_logo_svg_cache() objectForKey:key];
    if (cached) return cached;

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
        @"svg{display:block;width:100%%;height:100%%;contain:layout paint style;will-change:transform;transform:translateZ(0)}"
        @"</style></head><body>%@</body></html>", markup];
    [zs_logo_svg_cache() setObject:svg forKey:key];
    return svg;
}

static NSString * const kZSLogoSVGPlaybackScript =
    @"(function(speed,paused){\n"
    @"var svg=document.querySelector('svg');\n"
    @"if(!svg)return;\n"
    @"var smil=!!svg.pauseAnimations;\n"
    @"var z=window.__zs;\n"
    @"if(!z){\n"
    @"z=window.__zs={speed:1,items:[]};\n"
    @"Array.prototype.forEach.call(svg.querySelectorAll('animate,animateTransform,animateMotion,animateColor,set'),function(el){\n"
    @"['dur','begin','end','repeatDur','min','max'].forEach(function(a){var v=el.getAttribute(a);if(v)z.items.push([el,a,v]);});});}\n"
    @"function ms(t){var m;\n"
    @"if((m=/^([+-]?\\d*\\.?\\d+)ms$/.exec(t)))return parseFloat(m[1]);\n"
    @"if((m=/^([+-]?\\d*\\.?\\d+)s$/.exec(t)))return parseFloat(m[1])*1000;\n"
    @"if((m=/^([+-]?\\d*\\.?\\d+)min$/.exec(t)))return parseFloat(m[1])*60000;\n"
    @"if((m=/^([+-]?\\d*\\.?\\d+)h$/.exec(t)))return parseFloat(m[1])*3600000;\n"
    @"if((m=/^([+-]?\\d*\\.?\\d+)$/.exec(t)))return parseFloat(m[1])*1000;\n"
    @"if((m=/^(?:(\\d+):)?(\\d+):(\\d+(?:\\.\\d+)?)$/.exec(t)))return((+m[1]||0)*3600+(+m[2])*60+parseFloat(m[3]))*1000;\n"
    @"return null;}\n"
    @"function scale(v,f){return v.split(';').map(function(t){\n"
    @"t=t.trim();var n=ms(t);\n"
    @"if(n!==null)return(n/f)+'ms';\n"
    @"var m=/^(\\S+?)\\s*([+-])\\s*(\\.?\\d[\\w.:]*)$/.exec(t);\n"
    @"if(m){var o=ms(m[3]);if(o!==null)return m[1]+m[2]+(o/f)+'ms';}\n"
    @"return t;}).join(';');}\n"
    @"var anims=document.getAnimations?document.getAnimations():[];\n"
    @"if(speed<=0){\n"
    @"anims.forEach(function(a){a.pause();a.currentTime=0;});\n"
    @"if(smil){svg.pauseAnimations();svg.setCurrentTime(0);}\n"
    @"return;}\n"
    @"if(speed!==z.speed){\n"
    @"var media=smil?svg.getCurrentTime()*z.speed:0;\n"
    @"z.items.forEach(function(i){i[0].setAttribute(i[1],speed===1?i[2]:scale(i[2],speed));});\n"
    @"z.speed=speed;\n"
    @"if(smil)svg.setCurrentTime(media/speed);}\n"
    @"anims.forEach(function(a){a.playbackRate=speed;if(paused){a.pause();}else if(a.playState==='paused'){a.play();}});\n"
    @"if(smil){if(paused){svg.pauseAnimations();}else{svg.unpauseAnimations();}}\n"
    @"})(%g,%@);";

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

static UIView *zs_logo_park_view(void) {
    static UIView *view;
    UIWindow *window = zs_logo_host_window();
    if (!view) {
        if (!window) return nil;
        view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        view.userInteractionEnabled = NO;
        view.clipsToBounds = YES;
        view.alpha = 0.02;
        view.backgroundColor = UIColor.clearColor;
    }
    if (window && view.superview != window) [window insertSubview:view atIndex:0];
    return view;
}

@interface ZSLogoSVGRenderer : NSObject <WKNavigationDelegate>
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) ZSLogoSVG *svg;
@property (nonatomic, strong, readonly) WKWebView *web;
@property (nonatomic, weak, nullable) ZSLogoEffectView *owner;
- (instancetype)initWithKey:(NSString *)key svg:(ZSLogoSVG *)svg;
- (void)mountInto:(UIView *)host;
- (void)placeWithSize:(CGSize)size center:(CGPoint)center rotation:(CGFloat)radians;
- (void)park;
- (void)teardown;
- (void)invalidate;
- (void)setSpeed:(double)speed paused:(BOOL)paused;
@end

@implementation ZSLogoSVGRenderer {
    WKWebView *_web;
    BOOL _ready;
    BOOL _applied;
    double _speed;
    BOOL _paused;
    double _appliedSpeed;
    BOOL _appliedPaused;
    BOOL _settling;
    NSUInteger _settleGeneration;
    CGSize _settleSize;
}

- (instancetype)initWithKey:(NSString *)key svg:(ZSLogoSVG *)svg {
    self = [super init];
    if (!self) return nil;
    _key = [key copy];
    _svg = svg;
    _speed = 1;
    _paused = YES;

    CGFloat major = MAX(svg.size.width, svg.size.height);
    CGFloat ratio = major > 0 ? 512.0 / major : 1;
    CGRect frame = CGRectMake(0, 0, MAX(1, round(svg.size.width * ratio)), MAX(1, round(svg.size.height * ratio)));

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.defaultWebpagePreferences.allowsContentJavaScript = NO;
    configuration.preferences.inactiveSchedulingPolicy = WKInactiveSchedulingPolicyNone;
    WKWebView *web = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
    web.navigationDelegate = self;
    web.opaque = NO;
    web.backgroundColor = UIColor.clearColor;
    web.underPageBackgroundColor = UIColor.clearColor;
    web.userInteractionEnabled = NO;
    web.allowsLinkPreview = NO;
    web.scrollView.backgroundColor = UIColor.clearColor;
    web.scrollView.scrollEnabled = NO;
    web.scrollView.bounces = NO;
    web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _web = web;

    [self park];
    [web loadHTMLString:svg.html baseURL:nil];
    return self;
}

- (WKWebView *)web {
    return _web;
}

- (void)mountInto:(UIView *)host {
    if (_web.superview == host) return;
    _web.hidden = YES;
    [host addSubview:_web];
}

- (void)placeWithSize:(CGSize)size center:(CGPoint)center rotation:(CGFloat)radians {
    BOOL resized = !CGSizeEqualToSize(_web.bounds.size, size);
    _web.transform = CGAffineTransformIdentity;
    if (resized) _web.bounds = CGRectMake(0, 0, size.width, size.height);
    _web.center = center;
    _web.transform = CGAffineTransformMakeRotation(radians);
    if (resized) [self zs_beginSettlingAtSize:size];
}

- (void)zs_beginSettlingAtSize:(CGSize)size {
    _settleGeneration++;
    _settling = YES;
    _settleSize = size;
    _web.alpha = kZSLogoSVGSettleAlpha;
    [self zs_pollSettleAttempt:0];
}

- (void)zs_pollSettleAttempt:(NSUInteger)attempt {
    if (!_settling || !_ready) return;
    NSUInteger generation = _settleGeneration;
    CGSize expected = _settleSize;
    __weak typeof(self) weakSelf = self;
    [_web evaluateJavaScript:@"window.innerWidth+','+window.innerHeight" completionHandler:^(id result, NSError *error) {
        ZSLogoSVGRenderer *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_settling || strongSelf->_settleGeneration != generation) return;
        BOOL matched = NO;
        if ([result isKindOfClass:[NSString class]]) {
            NSArray<NSString *> *parts = [(NSString *)result componentsSeparatedByString:@","];
            if (parts.count == 2) {
                matched = fabs(parts[0].doubleValue - expected.width) < 1.5 && fabs(parts[1].doubleValue - expected.height) < 1.5;
            }
        }
        if (matched || error || attempt >= kZSLogoSVGSettleMaxAttempts) {
            [strongSelf zs_finishSettlingGeneration:generation];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZSLogoSVGSettlePollInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf zs_pollSettleAttempt:attempt + 1];
        });
    }];
}

- (void)zs_finishSettlingGeneration:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZSLogoSVGSettleCommitDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ZSLogoSVGRenderer *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_settleGeneration != generation || !strongSelf->_settling) return;
        strongSelf->_settling = NO;
        [UIView animateWithDuration:kZSLogoSVGSettleFadeDuration animations:^{
            strongSelf->_web.alpha = 1;
        }];
    });
}

- (void)park {
    self.owner = nil;
    _settling = NO;
    _settleGeneration++;
    _web.alpha = 1;
    [self setSpeed:_speed paused:YES];

    UIView *host = zs_logo_park_view();
    if (!host) {
        [_web removeFromSuperview];
        return;
    }
    if (_web.superview != host) [host addSubview:_web];
    _web.hidden = NO;
    _web.transform = CGAffineTransformIdentity;
    _web.frame = CGRectMake(0, 0, _web.bounds.size.width, _web.bounds.size.height);
}

- (void)teardown {
    _web.navigationDelegate = nil;
    [_web stopLoading];
    [_web removeFromSuperview];
}

- (void)invalidate {
    _applied = NO;
    [self zs_apply];
}

- (void)setSpeed:(double)speed paused:(BOOL)paused {
    _speed = speed;
    _paused = paused;
    [self zs_apply];
}

- (void)zs_apply {
    if (!_ready) return;
    if (_applied && _appliedSpeed == _speed && _appliedPaused == _paused) return;
    _applied = YES;
    _appliedSpeed = _speed;
    _appliedPaused = _paused;
    NSString *script = [NSString stringWithFormat:kZSLogoSVGPlaybackScript, _speed, _paused ? @"true" : @"false"];
    [_web evaluateJavaScript:script completionHandler:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    _ready = YES;
    _applied = NO;
    [self zs_apply];
    if (_settling) [self zs_pollSettleAttempt:0];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    _ready = NO;
    _applied = NO;
    [webView loadHTMLString:_svg.html baseURL:nil];
}

@end

static NSMutableArray<ZSLogoSVGRenderer *> *zs_logo_svg_renderers(void) {
    static NSMutableArray<ZSLogoSVGRenderer *> *renderers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ renderers = [NSMutableArray array]; });
    return renderers;
}

static NSString *zs_logo_svg_renderer_key(NSString *path, BOOL fill) {
    return [zs_logo_animation_key(path) stringByAppendingString:fill ? @"|fill" : @"|vfx"];
}

static ZSLogoSVGRenderer *zs_logo_svg_free_renderer(NSString *key) {
    for (ZSLogoSVGRenderer *renderer in zs_logo_svg_renderers()) {
        if (!renderer.owner && [renderer.key isEqualToString:key]) return renderer;
    }
    return nil;
}

static BOOL zs_logo_svg_renderer_exists(NSString *key) {
    for (ZSLogoSVGRenderer *renderer in zs_logo_svg_renderers()) {
        if ([renderer.key isEqualToString:key]) return YES;
    }
    return NO;
}

static ZSLogoSVGRenderer *zs_logo_svg_make_renderer(NSString *key, ZSLogoSVG *svg) {
    ZSLogoSVGRenderer *renderer = [[ZSLogoSVGRenderer alloc] initWithKey:key svg:svg];
    [zs_logo_svg_renderers() addObject:renderer];
    return renderer;
}

static void zs_logo_svg_preload(NSString *path, BOOL fill) {
    NSString *key = zs_logo_svg_renderer_key(path, fill);
    if (zs_logo_svg_renderer_exists(key)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ZSLogoSVG *svg = zs_logo_svg_for_path(path);
        if (!svg) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (zs_logo_svg_renderer_exists(key)) return;
            zs_logo_svg_make_renderer(key, svg);
        });
    });
}

static void zs_logo_svg_evict_unwanted(NSSet<NSString *> *wanted) {
    NSMutableArray<ZSLogoSVGRenderer *> *pool = zs_logo_svg_renderers();
    for (ZSLogoSVGRenderer *renderer in [pool copy]) {
        if (renderer.owner || [wanted containsObject:renderer.key]) continue;
        [renderer teardown];
        [pool removeObject:renderer];
    }
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

@implementation ZSLogoEffectView {
    UIView *_clipView;
    CALayer *_clipLayer;
    ZSLogoSVGRenderer *_renderer;
    CALayer *_contentLayer;
    CALayer *_maskLayer;
    ZSLogoAnimation *_animation;
    NSString *_path;
    id _activeObserver;
    UIImage *_maskImage;
    NSAttributedString *_maskText;
    CGSize _maskSize;
    BOOL _svgPlaced;
    CGSize _placedSize;
    CGPoint _placedPosition;
    CGFloat _placedRotation;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = NO;
        self.backgroundColor = UIColor.clearColor;

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
            [weakSelf zs_resumeAfterActivation];
        }];
    }
    return self;
}

- (void)dealloc {
    if (_activeObserver) [[NSNotificationCenter defaultCenter] removeObserver:_activeObserver];
    [_renderer park];
}

- (void)zs_resumeAfterActivation {
    [_renderer invalidate];
    [self zs_applyFrames];
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
    if (zs_logo_is_svg_file(path)) {
        [self zs_loadSVGAtPath:path];
        return;
    }
    [self zs_releaseRenderer];
    ZSLogoAnimation *cached = zs_logo_cached_animation(path);
    if (cached) {
        [self zs_setAnimation:cached];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ZSLogoAnimation *decoded = zs_logo_animation_for_path(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf->_path isEqualToString:path]) return;
            [strongSelf zs_setAnimation:decoded];
        });
    });
}

- (void)zs_loadSVGAtPath:(NSString *)path {
    NSString *key = zs_logo_svg_renderer_key(path, self.fillsText);
    ZSLogoSVGRenderer *ready = zs_logo_svg_free_renderer(key);
    if (ready) {
        [self zs_attachRenderer:ready];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ZSLogoSVG *svg = zs_logo_svg_for_path(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf->_path isEqualToString:path]) return;
            if (!svg) {
                [strongSelf zs_releaseRenderer];
                [strongSelf setNeedsLayout];
                return;
            }
            [strongSelf zs_attachRenderer:zs_logo_svg_free_renderer(key) ?: zs_logo_svg_make_renderer(key, svg)];
        });
    });
}

- (void)zs_attachRenderer:(ZSLogoSVGRenderer *)renderer {
    if (_renderer != renderer) {
        [self zs_releaseRenderer];
        _renderer = renderer;
        renderer.owner = self;
    }
    _animation = nil;
    _svgPlaced = NO;
    [renderer mountInto:_clipView];
    [self setNeedsLayout];
    [self zs_applyFrames];
}

- (void)zs_releaseRenderer {
    ZSLogoSVGRenderer *renderer = _renderer;
    _renderer = nil;
    _svgPlaced = NO;
    if (renderer.owner == self) [renderer park];
}

- (void)releaseAssets {
    [self zs_releaseRenderer];
}

- (void)zs_setAnimation:(ZSLogoAnimation *)animation {
    _animation = animation;
    [self setNeedsLayout];
    [self zs_applyFrames];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self zs_applyFrames];
}

- (void)zs_applyFrames {
    [_contentLayer removeAnimationForKey:kZSLogoFrameAnimationKey];

    if (_renderer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _contentLayer.contents = nil;
        [CATransaction commit];
        [_renderer setSpeed:_layerStyle ? _layerStyle.speed : 1 paused:_animationsPaused || !self.window];
        return;
    }

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

    CGSize imageSize = _renderer ? _renderer.svg.size : _animation.size;
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

        if (_renderer) {
            _contentLayer.hidden = YES;
            CGSize size = CGSizeMake(width, height);
            if (!_svgPlaced || !CGSizeEqualToSize(_placedSize, size) ||
                !CGPointEqualToPoint(_placedPosition, position) || _placedRotation != radians) {
                [_renderer placeWithSize:size center:position rotation:radians];
                _svgPlaced = YES;
                _placedSize = size;
                _placedPosition = position;
                _placedRotation = radians;
            }
            _renderer.web.hidden = NO;
        } else {
            _contentLayer.transform = CATransform3DIdentity;
            _contentLayer.bounds = CGRectMake(0, 0, width, height);
            _contentLayer.position = position;
            _contentLayer.transform = CATransform3DMakeRotation(radians, 0, 0, 1);
            _contentLayer.hidden = NO;
        }
    } else {
        _contentLayer.hidden = YES;
        _renderer.web.hidden = YES;
        _svgPlaced = NO;
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

    if (pack.fillPath && style.fill.enabled) {
        fill = zs_logo_make_effect_view(label, style.fill, pack.fillPath, YES);
        [parent insertSubview:fill aboveSubview:label];
        zs_logo_pin_effect_view(fill, label);
        [attached addObject:fill];
    }

    if (pack.vfxPath && style.vfx.enabled) {
        ZSLogoEffectView *vfx = zs_logo_make_effect_view(label, style.vfx, pack.vfxPath, NO);
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
    NSMutableSet<NSString *> *wanted = [NSMutableSet set];
    if (pack) {
        if (pack.fillPath && pack.style.fill.enabled && zs_logo_is_svg_file(pack.fillPath)) {
            [wanted addObject:zs_logo_svg_renderer_key(pack.fillPath, YES)];
            zs_logo_svg_preload(pack.fillPath, YES);
        }
        if (pack.vfxPath && pack.style.vfx.enabled && zs_logo_is_svg_file(pack.vfxPath)) {
            [wanted addObject:zs_logo_svg_renderer_key(pack.vfxPath, NO)];
            zs_logo_svg_preload(pack.vfxPath, NO);
        }
    }
    zs_logo_svg_evict_unwanted(wanted);
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
