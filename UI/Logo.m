#import "Logo.h"
#import "Engine.h"
#import "ZTweakLog.h"
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <compression.h>
#import <ctype.h>
#import <stdlib.h>
#import <math.h>

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

@interface ZSLogoSVGAnimation : NSObject
@property (nonatomic, copy) NSString *attributeName;
@property (nonatomic, copy) NSString *animationType;
@property (nonatomic, copy) NSString *transformType;
@property (nonatomic, copy) NSArray<NSString *> *values;
@property (nonatomic, copy, nullable) NSString *fromValue;
@property (nonatomic, copy, nullable) NSString *toValue;
@property (nonatomic, assign) CFTimeInterval duration;
@property (nonatomic, assign) float repeatCount;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *keyTimes;
@property (nonatomic, copy, nullable) NSString *calcMode;
@end

@implementation ZSLogoSVGAnimation
@end

@interface ZSLogoSVGShape : NSObject
@property (nonatomic, strong) UIBezierPath *path;
@property (nonatomic, copy, nullable) NSString *identifier;
@property (nonatomic, strong, nullable) UIColor *fillColor;
@property (nonatomic, strong, nullable) UIColor *strokeColor;
@property (nonatomic, copy, nullable) NSString *fillGradientID;
@property (nonatomic, copy, nullable) NSString *strokeGradientID;
@property (nonatomic, copy, nullable) NSString *clipPathID;
@property (nonatomic, copy) NSString *fillRule;
@property (nonatomic, copy) NSString *lineCap;
@property (nonatomic, copy) NSString *lineJoin;
@property (nonatomic, copy) NSArray<NSNumber *> *dashArray;
@property (nonatomic, assign) CGFloat dashOffset;
@property (nonatomic, assign) CGFloat strokeWidth;
@property (nonatomic, assign) CGFloat strokeOpacity;
@property (nonatomic, assign) CGFloat fillOpacity;
@property (nonatomic, assign) CGFloat opacity;
@property (nonatomic, assign) CGFloat miterLimit;
@property (nonatomic, assign) CGAffineTransform transform;
@property (nonatomic, copy) NSArray<ZSLogoSVGAnimation *> *animations;
@end

@implementation ZSLogoSVGShape
- (instancetype)init {
    self = [super init];
    if (self) {
        _fillRule = @"nonzero";
        _lineCap = @"butt";
        _lineJoin = @"miter";
        _dashArray = @[];
        _strokeWidth = 1;
        _strokeOpacity = 1;
        _fillOpacity = 1;
        _opacity = 1;
        _miterLimit = 4;
        _transform = CGAffineTransformIdentity;
        _animations = @[];
    }
    return self;
}
@end

@interface ZSLogoSVGGradient : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *attributes;
@property (nonatomic, strong) NSMutableArray<UIColor *> *colors;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *locations;
@end

@implementation ZSLogoSVGGradient
- (instancetype)init {
    self = [super init];
    if (self) {
        _colors = [NSMutableArray array];
        _locations = [NSMutableArray array];
    }
    return self;
}
@end

@interface ZSLogoSVGState : NSObject
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *styles;
@property (nonatomic, assign) CGAffineTransform transform;
@property (nonatomic, assign) CGFloat opacity;
@property (nonatomic, assign) BOOL hidden;
@property (nonatomic, assign) BOOL insideDefs;
@property (nonatomic, copy, nullable) NSString *clipPathID;
@property (nonatomic, copy, nullable) NSString *gradientID;
@property (nonatomic, strong, nullable) ZSLogoSVGShape *shape;
@property (nonatomic, strong, nullable) NSMutableString *textBuffer;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *textAttributes;
@property (nonatomic, copy) NSString *tag;
@end

@implementation ZSLogoSVGState
@end

@interface ZSLogoSVGParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *rootAttributes;
@property (nonatomic, strong) NSMutableArray<ZSLogoSVGShape *> *shapes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZSLogoSVGGradient *> *gradients;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<ZSLogoSVGShape *> *> *clipPaths;
@property (nonatomic, strong) NSMutableArray<ZSLogoSVGState *> *stack;
@property (nonatomic, strong) NSArray<NSDictionary *> *cssRules;
@end

static NSString *zs_svg_trim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static CGFloat zs_svg_number(NSString *value, CGFloat fallback) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return fallback;
    double number = value.doubleValue;
    return isfinite(number) ? (CGFloat)number : fallback;
}

static CGFloat zs_svg_length(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0 || [value containsString:@"%"] || [value hasPrefix:@"auto"]) return 0;
    CGFloat number = zs_svg_number(value, 0);
    return number > 0 ? number : 0;
}

static CGFloat zs_svg_fraction(NSString *value, CGFloat fallback) {
    NSString *text = zs_svg_trim(value ?: @"");
    if ([text hasSuffix:@"%"] && text.length > 1) return zs_svg_number([text substringToIndex:text.length - 1], fallback * 100) / 100.0;
    return zs_svg_number(text, fallback);
}

static UIColor *zs_svg_color_alpha(UIColor *color, CGFloat alpha) {
    if (!color) return nil;
    CGFloat red = 0, green = 0, blue = 0, oldAlpha = 1;
    if (![color getRed:&red green:&green blue:&blue alpha:&oldAlpha]) {
        CGFloat white = 0;
        if ([color getWhite:&white alpha:&oldAlpha]) return [UIColor colorWithWhite:white alpha:oldAlpha * alpha];
        return color;
    }
    return [UIColor colorWithRed:red green:green blue:blue alpha:oldAlpha * alpha];
}

static UIColor *zs_svg_color(NSString *value, UIColor *currentColor) {
    NSString *text = zs_svg_trim(value ?: @"").lowercaseString;
    if (text.length == 0 || [text isEqualToString:@"none"]) return nil;
    if ([text isEqualToString:@"transparent"]) return UIColor.clearColor;
    if ([text isEqualToString:@"currentcolor"]) return currentColor ?: UIColor.blackColor;
    if ([text hasPrefix:@"#"]) {
        NSString *hex = [text substringFromIndex:1];
        if (hex.length == 3 || hex.length == 4) {
            unsigned int r = 0, g = 0, b = 0, a = 15;
            [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(0, 1)]] scanHexInt:&r];
            [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(1, 1)]] scanHexInt:&g];
            [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(2, 1)]] scanHexInt:&b];
            if (hex.length == 4) [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(3, 1)]] scanHexInt:&a];
            return [UIColor colorWithRed:(r * 17) / 255.0 green:(g * 17) / 255.0 blue:(b * 17) / 255.0 alpha:(a * 17) / 255.0];
        }
        if (hex.length == 6 || hex.length == 8) {
            unsigned long long raw = 0;
            if (![[NSScanner scannerWithString:hex] scanHexLongLong:&raw]) return nil;
            CGFloat r, g, b, a = 1;
            if (hex.length == 8) {
                r = ((raw >> 24) & 255) / 255.0;
                g = ((raw >> 16) & 255) / 255.0;
                b = ((raw >> 8) & 255) / 255.0;
                a = (raw & 255) / 255.0;
            } else {
                r = ((raw >> 16) & 255) / 255.0;
                g = ((raw >> 8) & 255) / 255.0;
                b = (raw & 255) / 255.0;
            }
            return [UIColor colorWithRed:r green:g blue:b alpha:a];
        }
        return nil;
    }
    if ([text hasPrefix:@"rgb("] || [text hasPrefix:@"rgba("]) {
        NSRange open = [text rangeOfString:@"("];
        NSRange close = [text rangeOfString:@")" options:NSBackwardsSearch];
        if (open.location == NSNotFound || close.location <= open.location) return nil;
        NSString *body = [text substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *part in [body componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", /\t\r\n"]]) if (part.length) [parts addObject:part];
        if (parts.count < 3) return nil;
        CGFloat components[4] = {0, 0, 0, 1};
        for (NSUInteger i = 0; i < MIN((NSUInteger)4, parts.count); i++) {
            NSString *part = parts[i];
            BOOL percent = [part hasSuffix:@"%"];
            if (percent) part = [part substringToIndex:part.length - 1];
            CGFloat number = zs_svg_number(part, 0);
            components[i] = i < 3 ? (percent ? number / 100.0 : number / 255.0) : (percent ? number / 100.0 : number);
            components[i] = MIN(1, MAX(0, components[i]));
        }
        return [UIColor colorWithRed:components[0] green:components[1] blue:components[2] alpha:components[3]];
    }
    static NSDictionary<NSString *, UIColor *> *named;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        named = @{
            @"black": UIColor.blackColor, @"white": UIColor.whiteColor, @"red": UIColor.redColor,
            @"green": [UIColor colorWithRed:0 green:0.5 blue:0 alpha:1], @"blue": UIColor.blueColor,
            @"yellow": UIColor.yellowColor, @"cyan": UIColor.cyanColor, @"aqua": UIColor.cyanColor,
            @"magenta": UIColor.magentaColor, @"fuchsia": UIColor.magentaColor, @"gray": UIColor.grayColor,
            @"grey": UIColor.grayColor, @"silver": [UIColor colorWithWhite:0.75 alpha:1], @"maroon": [UIColor colorWithRed:0.5 green:0 blue:0 alpha:1],
            @"olive": [UIColor colorWithRed:0.5 green:0.5 blue:0 alpha:1], @"lime": [UIColor colorWithRed:0 green:1 blue:0 alpha:1],
            @"teal": [UIColor colorWithRed:0 green:0.5 blue:0.5 alpha:1], @"navy": [UIColor colorWithRed:0 green:0 blue:0.5 alpha:1],
            @"purple": [UIColor colorWithRed:0.5 green:0 blue:0.5 alpha:1], @"orange": UIColor.orangeColor,
            @"pink": UIColor.systemPinkColor, @"rebeccapurple": [UIColor colorWithRed:102/255.0 green:51/255.0 blue:153/255.0 alpha:1],
            @"aliceblue": [UIColor colorWithRed:240/255.0 green:248/255.0 blue:1 alpha:1], @"gold": [UIColor colorWithRed:1 green:215/255.0 blue:0 alpha:1],
            @"tomato": [UIColor colorWithRed:1 green:99/255.0 blue:71/255.0 alpha:1], @"crimson": [UIColor colorWithRed:220/255.0 green:20/255.0 blue:60/255.0 alpha:1],
            @"darkred": [UIColor colorWithRed:139/255.0 green:0 blue:0 alpha:1], @"darkblue": [UIColor colorWithRed:0 green:0 blue:139/255.0 alpha:1],
            @"lightgray": [UIColor colorWithWhite:0.83 alpha:1], @"lightgrey": [UIColor colorWithWhite:0.83 alpha:1],
            @"darkgray": [UIColor colorWithWhite:0.33 alpha:1], @"darkgrey": [UIColor colorWithWhite:0.33 alpha:1],
            @"indigo": [UIColor colorWithRed:75/255.0 green:0 blue:130/255.0 alpha:1], @"violet": [UIColor colorWithRed:238/255.0 green:130/255.0 blue:238/255.0 alpha:1]
        };
    });
    return named[text];
}

static NSDictionary<NSString *, NSString *> *zs_svg_parse_declarations(NSString *text) {
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    for (NSString *declaration in [text componentsSeparatedByString:@";"]) {
        NSRange colon = [declaration rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = zs_svg_trim([declaration substringToIndex:colon.location]).lowercaseString;
        NSString *value = zs_svg_trim([declaration substringFromIndex:colon.location + 1]);
        if (key.length && value.length) result[key] = value;
    }
    return result;
}

static NSArray<NSDictionary *> *zs_svg_css_rules(NSString *markup) {
    NSMutableArray<NSDictionary *> *rules = [NSMutableArray array];
    NSRegularExpression *styleExpression = [NSRegularExpression regularExpressionWithPattern:@"<style\\b[^>]*>(.*?)</style\\s*>" options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSRegularExpression *ruleExpression = [NSRegularExpression regularExpressionWithPattern:@"([^{}]+)\\{([^{}]*)\\}" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
    for (NSTextCheckingResult *block in [styleExpression matchesInString:markup options:0 range:NSMakeRange(0, markup.length)]) {
        NSString *css = [markup substringWithRange:[block rangeAtIndex:1]];
        NSRegularExpression *comments = [NSRegularExpression regularExpressionWithPattern:@"/\\*.*?\\*/" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
        css = [comments stringByReplacingMatchesInString:css options:0 range:NSMakeRange(0, css.length) withTemplate:@""];
        for (NSTextCheckingResult *match in [ruleExpression matchesInString:css options:0 range:NSMakeRange(0, css.length)]) {
            NSString *selectorText = zs_svg_trim([css substringWithRange:[match rangeAtIndex:1]]);
            NSString *body = [css substringWithRange:[match rangeAtIndex:2]];
            if ([selectorText hasPrefix:@"@"] || !selectorText.length) continue;
            NSDictionary *declarations = zs_svg_parse_declarations(body);
            for (NSString *selector in [selectorText componentsSeparatedByString:@","]) {
                NSString *trimmed = zs_svg_trim(selector);
                if (trimmed.length) [rules addObject:@{@"selector": trimmed, @"declarations": declarations}];
            }
        }
    }
    return rules;
}

static BOOL zs_svg_selector_matches(NSString *selector, NSString *tag, NSDictionary<NSString *, NSString *> *attributes) {
    if ([selector containsString:@" "] || [selector containsString:@">"] || [selector containsString:@"+"] || [selector containsString:@"~"] || [selector containsString:@"["] || [selector containsString:@":"]) return NO;
    NSString *elementID = attributes[@"id"] ?: @"";
    NSMutableSet<NSString *> *classes = [NSMutableSet set];
    for (NSString *className in [zs_svg_trim(attributes[@"class"] ?: @"") componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) if (className.length) [classes addObject:className];
    if ([selector hasPrefix:@"#"]) return [elementID isEqualToString:[selector substringFromIndex:1]];
    if ([selector hasPrefix:@"."]) return [classes containsObject:[selector substringFromIndex:1]];
    NSRange dot = [selector rangeOfString:@"."];
    if (dot.location != NSNotFound) {
        NSString *className = [selector substringFromIndex:dot.location + 1];
        NSString *tagName = [selector substringToIndex:dot.location];
        return ([tagName isEqualToString:@"*"] || [tagName caseInsensitiveCompare:tag] == NSOrderedSame) && [classes containsObject:className];
    }
    NSRange hash = [selector rangeOfString:@"#"];
    if (hash.location != NSNotFound) return [[selector substringToIndex:hash.location] isEqualToString:tag] && [elementID isEqualToString:[selector substringFromIndex:hash.location + 1]];
    return [selector isEqualToString:@"*"] || [selector caseInsensitiveCompare:tag] == NSOrderedSame;
}

static void zs_svg_skip_separators(const char **cursor) {
    while (**cursor && (isspace((unsigned char)**cursor) || **cursor == ',')) (*cursor)++;
}

static BOOL zs_svg_read_number(const char **cursor, CGFloat *value) {
    zs_svg_skip_separators(cursor);
    if (!**cursor) return NO;
    char *end = NULL;
    double number = strtod(*cursor, &end);
    if (end == *cursor || !isfinite(number)) return NO;
    *cursor = end;
    *value = (CGFloat)number;
    return YES;
}

static BOOL zs_svg_has_number(const char *cursor) {
    zs_svg_skip_separators(&cursor);
    return *cursor && (*cursor == '+' || *cursor == '-' || *cursor == '.' || isdigit((unsigned char)*cursor));
}

static void zs_svg_add_arc(CGMutablePathRef path, CGPoint start, CGFloat rx, CGFloat ry, CGFloat rotation, BOOL largeArc, BOOL sweep, CGPoint end) {
    rx = fabs(rx);
    ry = fabs(ry);
    if (rx < 1e-8 || ry < 1e-8 || (fabs(start.x - end.x) < 1e-8 && fabs(start.y - end.y) < 1e-8)) {
        CGPathAddLineToPoint(path, NULL, end.x, end.y);
        return;
    }
    CGFloat phi = fmod(rotation, 360.0) * (CGFloat)M_PI / 180.0;
    CGFloat cosine = cos(phi), sine = sin(phi);
    CGFloat dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2;
    CGFloat xp = cosine * dx + sine * dy;
    CGFloat yp = -sine * dx + cosine * dy;
    CGFloat lambda = xp * xp / (rx * rx) + yp * yp / (ry * ry);
    if (lambda > 1) {
        CGFloat scale = sqrt(lambda);
        rx *= scale;
        ry *= scale;
    }
    CGFloat numerator = MAX(0, rx * rx * ry * ry - rx * rx * yp * yp - ry * ry * xp * xp);
    CGFloat denominator = rx * rx * yp * yp + ry * ry * xp * xp;
    CGFloat coefficient = denominator > 0 ? sqrt(numerator / denominator) : 0;
    if (largeArc == sweep) coefficient = -coefficient;
    CGFloat cxp = coefficient * (rx * yp / ry);
    CGFloat cyp = coefficient * (-ry * xp / rx);
    CGFloat cx = cosine * cxp - sine * cyp + (start.x + end.x) / 2;
    CGFloat cy = sine * cxp + cosine * cyp + (start.y + end.y) / 2;
    CGFloat ux = (xp - cxp) / rx;
    CGFloat uy = (yp - cyp) / ry;
    CGFloat vx = (-xp - cxp) / rx;
    CGFloat vy = (-yp - cyp) / ry;
    CGFloat theta = atan2(uy, ux);
    CGFloat delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    if (!sweep && delta > 0) delta -= 2 * M_PI;
    if (sweep && delta < 0) delta += 2 * M_PI;
    NSUInteger segments = MAX(1, (NSUInteger)ceil(fabs(delta) / (M_PI / 2)));
    CGFloat segmentDelta = delta / segments;
    for (NSUInteger i = 0; i < segments; i++) {
        CGFloat t0 = theta + i * segmentDelta;
        CGFloat t1 = t0 + segmentDelta;
        CGFloat k = (4.0 / 3.0) * tan((t1 - t0) / 4.0);
        CGPoint p0 = CGPointMake(cx + rx * cosine * cos(t0) - ry * sine * sin(t0), cy + rx * sine * cos(t0) + ry * cosine * sin(t0));
        CGPoint p3 = CGPointMake(cx + rx * cosine * cos(t1) - ry * sine * sin(t1), cy + rx * sine * cos(t1) + ry * cosine * sin(t1));
        CGPoint d0 = CGPointMake(-rx * cosine * sin(t0) - ry * sine * cos(t0), -rx * sine * sin(t0) + ry * cosine * cos(t0));
        CGPoint d1 = CGPointMake(-rx * cosine * sin(t1) - ry * sine * cos(t1), -rx * sine * sin(t1) + ry * cosine * cos(t1));
        CGPoint c1 = CGPointMake(p0.x + k * d0.x, p0.y + k * d0.y);
        CGPoint c2 = CGPointMake(p3.x - k * d1.x, p3.y - k * d1.y);
        CGPathAddCurveToPoint(path, NULL, c1.x, c1.y, c2.x, c2.y, p3.x, p3.y);
    }
}

static UIBezierPath *zs_svg_path_from_data(NSString *data) {
    if (![data isKindOfClass:NSString.class] || data.length == 0) return nil;
    const char *cursor = data.UTF8String;
    if (!cursor) return nil;
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat x = 0, y = 0, startX = 0, startY = 0;
    CGFloat cubicX = 0, cubicY = 0, quadX = 0, quadY = 0;
    char command = 0, previous = 0;
    while (*cursor) {
        zs_svg_skip_separators(&cursor);
        if (!*cursor) break;
        if (isalpha((unsigned char)*cursor)) command = *cursor++;
        else if (!command || !zs_svg_has_number(cursor)) break;
        BOOL relative = islower((unsigned char)command);
        char upper = (char)toupper((unsigned char)command);
        CGFloat a, b, c, d, e, f;
        if (upper == 'Z') {
            CGPathCloseSubpath(path);
            x = startX;
            y = startY;
            previous = command;
            command = 0;
            continue;
        }
        if (upper == 'M' || upper == 'L' || upper == 'T') {
            BOOL first = YES;
            do {
                if (!zs_svg_read_number(&cursor, &a) || !zs_svg_read_number(&cursor, &b)) break;
                CGFloat nx = relative ? x + a : a;
                CGFloat ny = relative ? y + b : b;
                if (upper == 'M' && first) {
                    CGPathMoveToPoint(path, NULL, nx, ny);
                    startX = nx;
                    startY = ny;
                } else if (upper == 'T') {
                    CGFloat qx = (toupper((unsigned char)previous) == 'Q' || toupper((unsigned char)previous) == 'T') ? 2 * x - quadX : x;
                    CGFloat qy = (toupper((unsigned char)previous) == 'Q' || toupper((unsigned char)previous) == 'T') ? 2 * y - quadY : y;
                    CGPathAddQuadCurveToPoint(path, NULL, qx, qy, nx, ny);
                    quadX = qx;
                    quadY = qy;
                } else {
                    CGPathAddLineToPoint(path, NULL, nx, ny);
                }
                x = nx;
                y = ny;
                previous = command;
                first = NO;
            } while (zs_svg_has_number(cursor));
            if (upper == 'M') command = relative ? 'l' : 'L';
        } else if (upper == 'H' || upper == 'V') {
            do {
                if (!zs_svg_read_number(&cursor, &a)) break;
                if (upper == 'H') x = relative ? x + a : a; else y = relative ? y + a : a;
                CGPathAddLineToPoint(path, NULL, x, y);
                previous = command;
            } while (zs_svg_has_number(cursor));
        } else if (upper == 'C') {
            do {
                if (!zs_svg_read_number(&cursor, &a) || !zs_svg_read_number(&cursor, &b) || !zs_svg_read_number(&cursor, &c) || !zs_svg_read_number(&cursor, &d) || !zs_svg_read_number(&cursor, &e) || !zs_svg_read_number(&cursor, &f)) break;
                CGPoint p1 = CGPointMake(relative ? x + a : a, relative ? y + b : b);
                CGPoint p2 = CGPointMake(relative ? x + c : c, relative ? y + d : d);
                CGPoint p3 = CGPointMake(relative ? x + e : e, relative ? y + f : f);
                CGPathAddCurveToPoint(path, NULL, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y);
                x = p3.x; y = p3.y; cubicX = p2.x; cubicY = p2.y; previous = command;
            } while (zs_svg_has_number(cursor));
        } else if (upper == 'S') {
            do {
                if (!zs_svg_read_number(&cursor, &a) || !zs_svg_read_number(&cursor, &b) || !zs_svg_read_number(&cursor, &c) || !zs_svg_read_number(&cursor, &d)) break;
                CGFloat px = (toupper((unsigned char)previous) == 'C' || toupper((unsigned char)previous) == 'S') ? 2 * x - cubicX : x;
                CGFloat py = (toupper((unsigned char)previous) == 'C' || toupper((unsigned char)previous) == 'S') ? 2 * y - cubicY : y;
                CGPoint p2 = CGPointMake(relative ? x + a : a, relative ? y + b : b);
                CGPoint p3 = CGPointMake(relative ? x + c : c, relative ? y + d : d);
                CGPathAddCurveToPoint(path, NULL, px, py, p2.x, p2.y, p3.x, p3.y);
                x = p3.x; y = p3.y; cubicX = p2.x; cubicY = p2.y; previous = command;
            } while (zs_svg_has_number(cursor));
        } else if (upper == 'Q') {
            do {
                if (!zs_svg_read_number(&cursor, &a) || !zs_svg_read_number(&cursor, &b) || !zs_svg_read_number(&cursor, &c) || !zs_svg_read_number(&cursor, &d)) break;
                CGPoint control = CGPointMake(relative ? x + a : a, relative ? y + b : b);
                CGPoint end = CGPointMake(relative ? x + c : c, relative ? y + d : d);
                CGPathAddQuadCurveToPoint(path, NULL, control.x, control.y, end.x, end.y);
                x = end.x; y = end.y; quadX = control.x; quadY = control.y; previous = command;
            } while (zs_svg_has_number(cursor));
        } else if (upper == 'A') {
            do {
                CGFloat largeValue, sweepValue;
                if (!zs_svg_read_number(&cursor, &a) || !zs_svg_read_number(&cursor, &b) || !zs_svg_read_number(&cursor, &c) || !zs_svg_read_number(&cursor, &largeValue) || !zs_svg_read_number(&cursor, &sweepValue) || !zs_svg_read_number(&cursor, &d) || !zs_svg_read_number(&cursor, &e)) break;
                CGPoint end = CGPointMake(relative ? x + d : d, relative ? y + e : e);
                zs_svg_add_arc(path, CGPointMake(x, y), a, b, c, largeValue != 0, sweepValue != 0, end);
                x = end.x; y = end.y; previous = command;
            } while (zs_svg_has_number(cursor));
        } else {
            command = 0;
        }
    }
    UIBezierPath *result = [UIBezierPath bezierPathWithCGPath:path];
    CGPathRelease(path);
    return result;
}

static CGAffineTransform zs_svg_transform(NSString *text) {
    if (!text.length) return CGAffineTransformIdentity;
    CGAffineTransform result = CGAffineTransformIdentity;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"([A-Za-z]+)\\s*\\(([^)]*)\\)" options:0 error:nil];
    for (NSTextCheckingResult *match in [expression matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        NSString *name = [[text substringWithRange:[match rangeAtIndex:1]] lowercaseString];
        NSString *body = [text substringWithRange:[match rangeAtIndex:2]];
        NSMutableArray<NSNumber *> *values = [NSMutableArray array];
        const char *cursor = body.UTF8String;
        CGFloat value = 0;
        while (zs_svg_read_number(&cursor, &value)) [values addObject:@(value)];
        CGAffineTransform next = CGAffineTransformIdentity;
        if ([name isEqualToString:@"matrix"] && values.count >= 6) {
            next = CGAffineTransformMake(values[0].doubleValue, values[1].doubleValue, values[2].doubleValue, values[3].doubleValue, values[4].doubleValue, values[5].doubleValue);
        } else if ([name isEqualToString:@"translate"] && values.count >= 1) {
            next = CGAffineTransformMakeTranslation(values[0].doubleValue, values.count > 1 ? values[1].doubleValue : 0);
        } else if ([name isEqualToString:@"scale"] && values.count >= 1) {
            next = CGAffineTransformMakeScale(values[0].doubleValue, values.count > 1 ? values[1].doubleValue : values[0].doubleValue);
        } else if ([name isEqualToString:@"rotate"] && values.count >= 1) {
            CGFloat angle = values[0].doubleValue * (CGFloat)M_PI / 180.0;
            next = CGAffineTransformMakeRotation(angle);
            if (values.count >= 3) next = CGAffineTransformConcat(CGAffineTransformMakeTranslation(values[1].doubleValue, values[2].doubleValue), CGAffineTransformConcat(next, CGAffineTransformMakeTranslation(-values[1].doubleValue, -values[2].doubleValue)));
        } else if ([name isEqualToString:@"skewx"] && values.count >= 1) {
            next.c = tan(values[0].doubleValue * (CGFloat)M_PI / 180.0);
        } else if ([name isEqualToString:@"skewy"] && values.count >= 1) {
            next.b = tan(values[0].doubleValue * (CGFloat)M_PI / 180.0);
        }
        result = CGAffineTransformConcat(result, next);
    }
    return result;
}

static UIBezierPath *zs_svg_geometry(NSString *tag, NSDictionary<NSString *, NSString *> *attributes) {
    if ([tag isEqualToString:@"path"]) return zs_svg_path_from_data(attributes[@"d"]);
    CGFloat x = zs_svg_number(attributes[@"x"], 0);
    CGFloat y = zs_svg_number(attributes[@"y"], 0);
    CGFloat width = zs_svg_number(attributes[@"width"], 0);
    CGFloat height = zs_svg_number(attributes[@"height"], 0);
    if ([tag isEqualToString:@"rect"] && width > 0 && height > 0) {
        CGFloat rx = zs_svg_number(attributes[@"rx"], zs_svg_number(attributes[@"ry"], 0));
        CGFloat ry = zs_svg_number(attributes[@"ry"], rx);
        rx = MIN(fabs(rx), width / 2); ry = MIN(fabs(ry), height / 2);
        if (rx > 0 || ry > 0) return [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, width, height) cornerRadius:MAX(rx, ry)];
        return [UIBezierPath bezierPathWithRect:CGRectMake(x, y, width, height)];
    }
    if ([tag isEqualToString:@"circle"] || [tag isEqualToString:@"ellipse"]) {
        CGFloat cx = zs_svg_number(attributes[@"cx"], 0), cy = zs_svg_number(attributes[@"cy"], 0);
        CGFloat rx = [tag isEqualToString:@"circle"] ? zs_svg_number(attributes[@"r"], 0) : zs_svg_number(attributes[@"rx"], 0);
        CGFloat ry = [tag isEqualToString:@"circle"] ? rx : zs_svg_number(attributes[@"ry"], 0);
        if (rx > 0 && ry > 0) return [UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - rx, cy - ry, rx * 2, ry * 2)];
    }
    if ([tag isEqualToString:@"line"]) {
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(zs_svg_number(attributes[@"x1"], 0), zs_svg_number(attributes[@"y1"], 0))];
        [path addLineToPoint:CGPointMake(zs_svg_number(attributes[@"x2"], 0), zs_svg_number(attributes[@"y2"], 0))];
        return path;
    }
    if ([tag isEqualToString:@"polyline"] || [tag isEqualToString:@"polygon"]) {
        NSString *points = attributes[@"points"];
        const char *cursor = points.UTF8String;
        if (!cursor) return nil;
        UIBezierPath *path = [UIBezierPath bezierPath];
        CGFloat px, py;
        BOOL first = YES;
        while (zs_svg_read_number(&cursor, &px) && zs_svg_read_number(&cursor, &py)) {
            if (first) { [path moveToPoint:CGPointMake(px, py)]; first = NO; }
            else [path addLineToPoint:CGPointMake(px, py)];
        }
        if (!first && [tag isEqualToString:@"polygon"]) [path closePath];
        return first ? nil : path;
    }
    return nil;
}

static CGPathRef zs_svg_transformed_path(CGPathRef source, CGAffineTransform transform, CGPoint offset) {
    if (!source) return NULL;
    CGPathRef intermediate = CGPathCreateCopyByTransformingPath(source, &transform);
    CGAffineTransform translation = CGAffineTransformMakeTranslation(offset.x, offset.y);
    CGPathRef result = CGPathCreateCopyByTransformingPath(intermediate, &translation);
    CGPathRelease(intermediate);
    return result;
}

static NSString *zs_svg_url_identifier(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"url\\(\\s*['\"]?#([^)'\"]+)['\"]?\\s*\\)" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
    return match ? [value substringWithRange:[match rangeAtIndex:1]] : nil;
}

static CFTimeInterval zs_svg_duration(NSString *value) {
    NSString *text = zs_svg_trim(value ?: @"").lowercaseString;
    if ([text hasSuffix:@"ms"]) return MAX(0, [text substringToIndex:text.length - 2].doubleValue / 1000.0);
    if ([text hasSuffix:@"min"]) return MAX(0, [text substringToIndex:text.length - 3].doubleValue * 60.0);
    if ([text hasSuffix:@"h"]) return MAX(0, [text substringToIndex:text.length - 1].doubleValue * 3600.0);
    if ([text hasSuffix:@"s"]) return MAX(0, [text substringToIndex:text.length - 1].doubleValue);
    return MAX(0, text.doubleValue);
}

static UIBezierPath *zs_svg_text_path(NSString *source, NSDictionary<NSString *, NSString *> *attributes, NSDictionary<NSString *, NSString *> *styles) {
    if (!source.length) return nil;
    NSMutableString *text = [source mutableCopy];
    NSRegularExpression *whitespace = [NSRegularExpression regularExpressionWithPattern:@"[\\t\\r\\n ]+" options:0 error:nil];
    [whitespace replaceMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    text = [zs_svg_trim(text) mutableCopy];
    if (!text.length) return nil;
    NSString *family = styles[@"font-family"] ?: attributes[@"font-family"] ?: @"Helvetica";
    family = [[[[family componentsSeparatedByString:@","] firstObject] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"'\""]];
    CGFloat fontSize = MAX(1, zs_svg_number(styles[@"font-size"] ?: attributes[@"font-size"], 16));
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)(family.length ? family : @"Helvetica"), fontSize, NULL);
    NSString *weight = [styles[@"font-weight"] lowercaseString] ?: @"normal";
    NSString *fontStyle = [styles[@"font-style"] lowercaseString] ?: @"normal";
    CTFontSymbolicTraits traits = 0;
    if ([weight isEqualToString:@"bold"] || [weight isEqualToString:@"bolder"] || weight.doubleValue >= 600) traits |= kCTFontBoldTrait;
    if ([fontStyle isEqualToString:@"italic"] || [fontStyle isEqualToString:@"oblique"]) traits |= kCTFontItalicTrait;
    if (traits) {
        CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(font, fontSize, NULL, traits, traits);
        if (styled) { CFRelease(font); font = styled; }
    }
    NSMutableDictionary *textAttributes = [NSMutableDictionary dictionaryWithObject:(__bridge id)font forKey:(__bridge id)kCTFontAttributeName];
    CGFloat tracking = zs_svg_number(styles[@"letter-spacing"], 0);
    if (tracking != 0) textAttributes[(__bridge id)kCTKernAttributeName] = @(tracking);
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:textAttributes];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    double lineWidth = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CGFloat x = zs_svg_number(attributes[@"x"], 0);
    CGFloat y = zs_svg_number(attributes[@"y"], 0);
    NSString *anchor = [styles[@"text-anchor"] lowercaseString] ?: @"start";
    if ([anchor isEqualToString:@"middle"]) x -= lineWidth / 2.0;
    else if ([anchor isEqualToString:@"end"]) x -= lineWidth;
    CGMutablePathRef path = CGPathCreateMutable();
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex runIndex = 0; runIndex < CFArrayGetCount(runs); runIndex++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, runIndex);
        NSDictionary *runAttributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
        CTFontRef runFont = (__bridge CTFontRef)runAttributes[(__bridge id)kCTFontAttributeName];
        if (!runFont) runFont = font;
        CFIndex glyphCount = CTRunGetGlyphCount(run);
        if (glyphCount <= 0) continue;
        CGGlyph *glyphs = calloc((size_t)glyphCount, sizeof(CGGlyph));
        CGPoint *positions = calloc((size_t)glyphCount, sizeof(CGPoint));
        if (!glyphs || !positions) { free(glyphs); free(positions); continue; }
        CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), glyphs);
        CTRunGetPositions(run, CFRangeMake(0, glyphCount), positions);
        for (CFIndex glyphIndex = 0; glyphIndex < glyphCount; glyphIndex++) {
            CGPathRef glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[glyphIndex], NULL);
            if (!glyphPath) continue;
            CGAffineTransform transform = CGAffineTransformMake(1, 0, 0, -1, x + positions[glyphIndex].x, y - positions[glyphIndex].y);
            CGPathAddPath(path, &transform, glyphPath);
            CGPathRelease(glyphPath);
        }
        free(glyphs);
        free(positions);
    }
    CFRelease(line);
    CFRelease(font);
    UIBezierPath *result = [UIBezierPath bezierPathWithCGPath:path];
    CGPathRelease(path);
    return result;
}

static ZSLogoSVGShape *zs_svg_shape_for_path(UIBezierPath *path, NSDictionary<NSString *, NSString *> *attributes, ZSLogoSVGState *state) {
    if (!path || CGPathIsEmpty(path.CGPath)) return nil;
    ZSLogoSVGShape *shape = [[ZSLogoSVGShape alloc] init];
    shape.path = path;
    shape.identifier = attributes[@"id"];
    shape.transform = state.transform;
    shape.opacity = state.opacity;
    shape.fillRule = [[state.styles[@"fill-rule"] lowercaseString] isEqualToString:@"evenodd"] ? @"evenodd" : @"nonzero";
    UIColor *currentColor = zs_svg_color(state.styles[@"color"], UIColor.blackColor) ?: UIColor.blackColor;
    NSString *fill = state.styles[@"fill"] ?: @"black";
    NSString *stroke = state.styles[@"stroke"] ?: @"none";
    shape.fillGradientID = zs_svg_url_identifier(fill);
    shape.strokeGradientID = zs_svg_url_identifier(stroke);
    if (!shape.fillGradientID) shape.fillColor = zs_svg_color(fill, currentColor);
    if (!shape.strokeGradientID) shape.strokeColor = zs_svg_color(stroke, currentColor);
    shape.fillOpacity = MIN(1, MAX(0, zs_svg_fraction(state.styles[@"fill-opacity"] ?: @"1", 1)));
    shape.strokeOpacity = MIN(1, MAX(0, zs_svg_fraction(state.styles[@"stroke-opacity"] ?: @"1", 1)));
    shape.strokeWidth = MAX(0, zs_svg_number(state.styles[@"stroke-width"], 1));
    shape.lineCap = [state.styles[@"stroke-linecap"] lowercaseString] ?: @"butt";
    shape.lineJoin = [state.styles[@"stroke-linejoin"] lowercaseString] ?: @"miter";
    shape.miterLimit = MAX(1, zs_svg_number(state.styles[@"stroke-miterlimit"], 4));
    shape.dashOffset = zs_svg_number(state.styles[@"stroke-dashoffset"], 0);
    NSMutableArray *dash = [NSMutableArray array];
    NSString *dashText = state.styles[@"stroke-dasharray"];
    if (dashText.length && ![dashText isEqualToString:@"none"]) {
        const char *cursor = dashText.UTF8String;
        CGFloat dashValue;
        while (zs_svg_read_number(&cursor, &dashValue)) [dash addObject:@(MAX(0, dashValue))];
    }
    shape.dashArray = dash;
    shape.clipPathID = zs_svg_url_identifier(state.styles[@"clip-path"]);
    return shape;
}

@implementation ZSLogoSVGParser
- (instancetype)init {
    self = [super init];
    if (self) {
        _rootAttributes = @{};
        _shapes = [NSMutableArray array];
        _gradients = [NSMutableDictionary dictionary];
        _clipPaths = [NSMutableDictionary dictionary];
        _stack = [NSMutableArray array];
        _cssRules = @[];
    }
    return self;
}

- (NSDictionary<NSString *, NSString *> *)stylesForTag:(NSString *)tag attributes:(NSDictionary<NSString *, NSString *> *)attributes parent:(NSDictionary<NSString *, NSString *> *)parent {
    NSMutableDictionary<NSString *, NSString *> *styles = [parent mutableCopy] ?: [NSMutableDictionary dictionary];
    [styles removeObjectForKey:@"opacity"];
    for (NSString *key in @[@"fill", @"stroke", @"color", @"fill-rule", @"clip-rule", @"fill-opacity", @"stroke-opacity", @"stroke-width", @"stroke-linecap", @"stroke-linejoin", @"stroke-miterlimit", @"stroke-dasharray", @"stroke-dashoffset", @"visibility", @"display", @"opacity", @"clip-path", @"stop-color", @"stop-opacity", @"font-family", @"font-size", @"font-weight", @"font-style", @"text-anchor", @"letter-spacing", @"dominant-baseline", @"baseline-shift"]) {
        if (attributes[key]) styles[key] = attributes[key];
    }
    for (NSDictionary *rule in self.cssRules) {
        if (zs_svg_selector_matches(rule[@"selector"], tag, attributes)) [styles addEntriesFromDictionary:rule[@"declarations"]];
    }
    [styles addEntriesFromDictionary:zs_svg_parse_declarations(attributes[@"style"] ?: @"")];
    if (!styles[@"fill"] && ![tag isEqualToString:@"stop"]) styles[@"fill"] = @"#000000";
    if (!styles[@"stroke"]) styles[@"stroke"] = @"none";
    if (!styles[@"color"]) styles[@"color"] = @"#000000";
    return styles;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *,NSString *> *)attributeDict {
    NSString *tag = [[(qName.length ? qName : elementName) componentsSeparatedByString:@":"] lastObject].lowercaseString;
    NSDictionary *attributes = attributeDict ?: @{};
    ZSLogoSVGState *parent = self.stack.lastObject;
    ZSLogoSVGState *state = [[ZSLogoSVGState alloc] init];
    state.tag = tag;
    state.styles = [self stylesForTag:tag attributes:attributes parent:parent.styles];
    CGAffineTransform local = zs_svg_transform(attributes[@"transform"]);
    state.transform = parent ? CGAffineTransformConcat(parent.transform, local) : local;
    CGFloat ownOpacity = zs_svg_fraction(state.styles[@"opacity"] ?: @"1", 1);
    state.opacity = (parent ? parent.opacity : 1) * MIN(1, MAX(0, ownOpacity));
    state.hidden = (parent && parent.hidden) || [[state.styles[@"display"] lowercaseString] isEqualToString:@"none"] || [[state.styles[@"visibility"] lowercaseString] isEqualToString:@"hidden"] || state.opacity <= 0;
    state.insideDefs = (parent && parent.insideDefs) || [tag isEqualToString:@"defs"] || [tag isEqualToString:@"symbol"];
    state.clipPathID = parent.clipPathID;
    if ([tag isEqualToString:@"clippath"]) state.clipPathID = attributes[@"id"];
    state.gradientID = parent.gradientID;
    if ([tag isEqualToString:@"lineargradient"] || [tag isEqualToString:@"radialgradient"]) {
        NSString *identifier = attributes[@"id"];
        if (identifier.length) {
            ZSLogoSVGGradient *gradient = [[ZSLogoSVGGradient alloc] init];
            gradient.identifier = identifier;
            gradient.type = tag;
            gradient.attributes = attributes;
            self.gradients[identifier] = gradient;
            state.gradientID = identifier;
        }
    }
    state.shape = parent.shape;
    state.textBuffer = parent.textBuffer;
    if ([tag isEqualToString:@"text"]) { state.textBuffer = [NSMutableString string]; state.textAttributes = attributes; }
    else state.textAttributes = parent.textAttributes;
    if ([tag isEqualToString:@"svg"] && self.rootAttributes.count == 0) self.rootAttributes = attributes;

    if ([tag isEqualToString:@"stop"] && state.gradientID.length) {
        ZSLogoSVGGradient *gradient = self.gradients[state.gradientID];
        CGFloat stopOpacity = zs_svg_fraction(state.styles[@"stop-opacity"] ?: @"1", 1);
        UIColor *color = zs_svg_color(state.styles[@"stop-color"] ?: @"black", zs_svg_color(state.styles[@"color"], UIColor.blackColor)) ?: UIColor.clearColor;
        [gradient.colors addObject:zs_svg_color_alpha(color, stopOpacity)];
        NSString *offsetString = attributes[@"offset"] ?: @"0";
        CGFloat offset = zs_svg_fraction(offsetString, 0);
        [gradient.locations addObject:@(MIN(1, MAX(0, offset)))];
    }

    BOOL drawable = [@[@"path", @"rect", @"circle", @"ellipse", @"line", @"polyline", @"polygon"] containsObject:tag];
    if (drawable && !state.hidden && ((state.clipPathID && parent.insideDefs) || !state.insideDefs)) {
        UIBezierPath *path = zs_svg_geometry(tag, attributes);
        if (path && !CGPathIsEmpty(path.CGPath)) {
            ZSLogoSVGShape *shape = zs_svg_shape_for_path(path, attributes, state);
            if (state.clipPathID.length && parent.insideDefs) {
                NSMutableArray *clipShapes = self.clipPaths[state.clipPathID];
                if (!clipShapes) { clipShapes = [NSMutableArray array]; self.clipPaths[state.clipPathID] = clipShapes; }
                if (shape) [clipShapes addObject:shape];
            } else if (shape) {
                [self.shapes addObject:shape];
                state.shape = shape;
            }
        }
    }

    if (([tag isEqualToString:@"animate"] || [tag isEqualToString:@"animatetransform"] || [tag isEqualToString:@"animatecolor"]) && state.shape) {
        NSString *attributeName = attributes[@"attributeName"] ?: ([tag isEqualToString:@"animatecolor"] ? @"fill" : @"");
        if (attributeName.length) {
            ZSLogoSVGAnimation *animation = [[ZSLogoSVGAnimation alloc] init];
            animation.attributeName = attributeName.lowercaseString;
            animation.animationType = tag;
            animation.transformType = attributes[@"type"] ?: @"";
            NSString *values = attributes[@"values"];
            if (values.length) {
                NSMutableArray *items = [NSMutableArray array];
                for (NSString *item in [values componentsSeparatedByString:@";"]) if (zs_svg_trim(item).length) [items addObject:zs_svg_trim(item)];
                animation.values = items;
            } else {
                NSMutableArray *items = [NSMutableArray array];
                if (attributes[@"from"]) [items addObject:attributes[@"from"]];
                if (attributes[@"to"]) [items addObject:attributes[@"to"]];
                if (!items.count && attributes[@"by"]) [items addObject:attributes[@"by"]];
                animation.values = items;
                animation.fromValue = attributes[@"from"];
                animation.toValue = attributes[@"to"];
            }
            animation.duration = zs_svg_duration(attributes[@"dur"] ?: @"0s");
            animation.repeatCount = [[attributes[@"repeatCount"] lowercaseString] isEqualToString:@"indefinite"] ? HUGE_VALF : MAX(1, zs_svg_number(attributes[@"repeatCount"], 1));
            animation.calcMode = attributes[@"calcMode"] ?: @"linear";
            NSMutableArray *times = [NSMutableArray array];
            for (NSString *part in [attributes[@"keyTimes"] componentsSeparatedByString:@";"]) if (part.length) [times addObject:@(zs_svg_number(part, 0))];
            animation.keyTimes = times.count ? times : nil;
            state.shape.animations = [state.shape.animations arrayByAddingObject:animation];
        }
    }
    [self.stack addObject:state];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    ZSLogoSVGState *state = self.stack.lastObject;
    if (state.textBuffer && string.length) [state.textBuffer appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    ZSLogoSVGState *state = self.stack.lastObject;
    ZSLogoSVGState *parent = self.stack.count > 1 ? self.stack[self.stack.count - 2] : nil;
    if ([state.tag isEqualToString:@"text"] && !state.hidden && (!state.insideDefs || (state.clipPathID.length && parent.insideDefs)) && state.textBuffer.length) {
        UIBezierPath *path = zs_svg_text_path(state.textBuffer, state.textAttributes ?: @{}, state.styles);
        ZSLogoSVGShape *shape = zs_svg_shape_for_path(path, state.textAttributes ?: @{}, state);
        if (shape) {
            if (state.clipPathID.length && parent.insideDefs) {
                NSMutableArray *clipShapes = self.clipPaths[state.clipPathID];
                if (!clipShapes) { clipShapes = [NSMutableArray array]; self.clipPaths[state.clipPathID] = clipShapes; }
                [clipShapes addObject:shape];
            } else [self.shapes addObject:shape];
        }
    }
    if (self.stack.count) [self.stack removeLastObject];
}
@end

@interface ZSLogoSVG : NSObject
@property (nonatomic, assign) CGSize size;
@property (nonatomic, assign) CGRect viewBox;
@property (nonatomic, copy) NSString *preserveAspectRatio;
@property (nonatomic, copy) NSArray<ZSLogoSVGShape *> *shapes;
@property (nonatomic, copy) NSDictionary<NSString *, ZSLogoSVGGradient *> *gradients;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<ZSLogoSVGShape *> *> *clipPaths;
@end

@implementation ZSLogoSVG
@end

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
    NSString *markup = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!markup.length || [markup rangeOfString:@"<svg" options:NSCaseInsensitiveSearch].location == NSNotFound) return nil;
    ZSLogoSVGParser *reader = [[ZSLogoSVGParser alloc] init];
    reader.cssRules = zs_svg_css_rules(markup);
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = reader;
    parser.shouldResolveExternalEntities = NO;
    if (![parser parse] || reader.rootAttributes.count == 0) return nil;
    NSDictionary *attributes = reader.rootAttributes;
    CGRect viewBox = CGRectZero;
    NSString *viewBoxText = attributes[@"viewBox"];
    if (viewBoxText.length) {
        const char *cursor = viewBoxText.UTF8String;
        CGFloat x, y, width, height;
        if (zs_svg_read_number(&cursor, &x) && zs_svg_read_number(&cursor, &y) && zs_svg_read_number(&cursor, &width) && zs_svg_read_number(&cursor, &height) && width > 0 && height > 0) viewBox = CGRectMake(x, y, width, height);
    }
    CGFloat width = zs_svg_length(attributes[@"width"]), height = zs_svg_length(attributes[@"height"]);
    if (viewBox.size.width <= 0 || viewBox.size.height <= 0) {
        CGFloat inferredWidth = width > 0 ? width : 1;
        CGFloat inferredHeight = height > 0 ? height : 1;
        viewBox = CGRectMake(0, 0, inferredWidth, inferredHeight);
    }
    CGSize size = (width > 0 && height > 0) ? CGSizeMake(width, height) : viewBox.size;
    ZSLogoSVG *svg = [[ZSLogoSVG alloc] init];
    svg.size = CGSizeMake(MAX(1, size.width), MAX(1, size.height));
    svg.viewBox = viewBox;
    svg.preserveAspectRatio = attributes[@"preserveAspectRatio"] ?: @"xMidYMid meet";
    CGPoint offset = CGPointMake(-viewBox.origin.x, -viewBox.origin.y);
    for (ZSLogoSVGShape *shape in reader.shapes) {
        CGPathRef pathRef = zs_svg_transformed_path(shape.path.CGPath, shape.transform, offset);
        if (pathRef) {
            shape.path = [UIBezierPath bezierPathWithCGPath:pathRef];
            CGPathRelease(pathRef);
            CGFloat determinant = fabs(shape.transform.a * shape.transform.d - shape.transform.b * shape.transform.c);
            CGFloat strokeScale = sqrt(MAX(0.0001, determinant));
            shape.strokeWidth *= strokeScale;
            shape.dashOffset *= strokeScale;
            if (shape.dashArray.count) {
                NSMutableArray *scaled = [NSMutableArray arrayWithCapacity:shape.dashArray.count];
                for (NSNumber *value in shape.dashArray) [scaled addObject:@(value.doubleValue * strokeScale)];
                shape.dashArray = scaled;
            }
        }
    }
    NSMutableDictionary *clips = [NSMutableDictionary dictionary];
    [reader.clipPaths enumerateKeysAndObjectsUsingBlock:^(NSString *identifier, NSArray<ZSLogoSVGShape *> *clipShapes, BOOL *stop) {
        NSMutableArray *paths = [NSMutableArray array];
        for (ZSLogoSVGShape *shape in clipShapes) {
            CGPathRef pathRef = zs_svg_transformed_path(shape.path.CGPath, shape.transform, offset);
            if (pathRef) { [paths addObject:[UIBezierPath bezierPathWithCGPath:pathRef]]; CGPathRelease(pathRef); }
        }
        clips[identifier] = paths;
    }];
    svg.shapes = [reader.shapes copy];
    svg.gradients = [reader.gradients copy];
    svg.clipPaths = clips;
    [zs_logo_svg_cache() setObject:svg forKey:key];
    return svg;
}

static NSArray<NSNumber *> *zs_svg_gradient_locations(ZSLogoSVGGradient *gradient) {
    NSUInteger count = gradient.colors.count;
    if (!count) return @[];
    NSMutableArray<NSNumber *> *locations = [gradient.locations mutableCopy];
    if (!locations.count) {
        for (NSUInteger i = 0; i < count; i++) [locations addObject:@(count > 1 ? i / (CGFloat)(count - 1) : 0)];
    }
    while (locations.count < count) [locations addObject:@1];
    while (locations.count > count) [locations removeLastObject];
    for (NSUInteger i = 1; i < locations.count; i++) locations[i] = @(MAX(locations[i].doubleValue, locations[i - 1].doubleValue));
    return locations;
}

static CGFloat zs_svg_gradient_coordinate(NSString *value, CGFloat origin, CGFloat extent, CGFloat viewportExtent, BOOL userSpace) {
    NSString *text = zs_svg_trim(value ?: @"");
    if ([text hasSuffix:@"%"] && text.length > 1) {
        CGFloat fraction = zs_svg_number([text substringToIndex:text.length - 1], 0) / 100.0;
        return userSpace ? ((fraction * viewportExtent) - origin) / MAX(1, extent) : fraction;
    }
    CGFloat number = zs_svg_number(text, 0);
    return userSpace ? (number - origin) / MAX(1, extent) : number;
}

static CAGradientLayer *zs_svg_gradient_layer(ZSLogoSVGGradient *gradient, CGRect shapeBounds, CGRect viewBoxBounds, BOOL stroke, CGFloat lineWidth, CGPathRef path, NSString *fillRule, CGFloat fillOpacity, CGFloat strokeOpacity) {
    if (!gradient || gradient.colors.count == 0 || !path) return nil;
    CGRect box = shapeBounds;
    CGFloat extra = stroke ? lineWidth / 2.0 : 0;
    box = CGRectInset(box, -extra, -extra);
    if (box.size.width <= 0) box.size.width = 1;
    if (box.size.height <= 0) box.size.height = 1;
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.frame = box;
    NSMutableArray *gradientColors = [NSMutableArray arrayWithCapacity:gradient.colors.count + 1];
    for (UIColor *color in gradient.colors) [gradientColors addObject:(__bridge id)color.CGColor];
    NSArray<NSNumber *> *gradientLocations = zs_svg_gradient_locations(gradient);
    if (gradientColors.count == 1) { [gradientColors addObject:gradientColors.firstObject]; gradientLocations = @[@0, @1]; }
    layer.colors = gradientColors;
    layer.locations = gradientLocations;
    layer.type = [gradient.type isEqualToString:@"radialgradient"] ? kCAGradientLayerRadial : kCAGradientLayerAxial;
    BOOL userSpace = [[gradient.attributes[@"gradientUnits"] lowercaseString] isEqualToString:@"userspaceonuse"];
    NSString *x1 = gradient.attributes[@"x1"] ?: @"0%", *y1 = gradient.attributes[@"y1"] ?: @"0%";
    NSString *x2 = gradient.attributes[@"x2"] ?: @"100%", *y2 = gradient.attributes[@"y2"] ?: @"0%";
    if ([gradient.type isEqualToString:@"radialgradient"]) {
        x1 = gradient.attributes[@"fx"] ?: gradient.attributes[@"cx"] ?: @"50%";
        y1 = gradient.attributes[@"fy"] ?: gradient.attributes[@"cy"] ?: @"50%";
        x2 = [gradient.attributes[@"cx"] length] ? gradient.attributes[@"cx"] : @"50%";
        y2 = [gradient.attributes[@"cy"] length] ? gradient.attributes[@"cy"] : @"50%";
    }
    CGFloat width = userSpace ? viewBoxBounds.size.width : box.size.width;
    CGFloat height = userSpace ? viewBoxBounds.size.height : box.size.height;
    CGFloat originX = box.origin.x;
    CGFloat originY = box.origin.y;
    layer.startPoint = CGPointMake(zs_svg_gradient_coordinate(x1, originX, width, viewBoxBounds.size.width, userSpace), zs_svg_gradient_coordinate(y1, originY, height, viewBoxBounds.size.height, userSpace));
    layer.endPoint = CGPointMake(zs_svg_gradient_coordinate(x2, originX, width, viewBoxBounds.size.width, userSpace), zs_svg_gradient_coordinate(y2, originY, height, viewBoxBounds.size.height, userSpace));
    if ([gradient.type isEqualToString:@"radialgradient"]) {
        NSString *radiusText = gradient.attributes[@"r"] ?: @"50%";
        CGFloat radius = [radiusText hasSuffix:@"%"] ? zs_svg_number([radiusText substringToIndex:radiusText.length - 1], 50) / 100.0 * MIN(box.size.width, box.size.height) : zs_svg_number(radiusText, 0);
        if (radius > 0) layer.endPoint = CGPointMake(layer.startPoint.x + radius / box.size.width, layer.startPoint.y + radius / box.size.height);
    }
    NSMutableArray *adjustedColors = [NSMutableArray arrayWithCapacity:gradient.colors.count + 1];
    CGFloat alpha = stroke ? strokeOpacity : fillOpacity;
    for (UIColor *color in gradient.colors) { UIColor *adjustedColor = zs_svg_color_alpha(color, alpha) ?: UIColor.clearColor; [adjustedColors addObject:(__bridge id)adjustedColor.CGColor]; }
    if (adjustedColors.count == 1) [adjustedColors addObject:adjustedColors.firstObject];
    layer.colors = adjustedColors;
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.bounds = CGRectMake(0, 0, box.size.width, box.size.height);
    mask.position = CGPointMake(box.size.width / 2.0, box.size.height / 2.0);
    CGAffineTransform shift = CGAffineTransformMakeTranslation(-box.origin.x, -box.origin.y);
    CGPathRef localPath = CGPathCreateCopyByTransformingPath(path, &shift);
    mask.path = localPath;
    CGPathRelease(localPath);
    mask.fillRule = [fillRule isEqualToString:@"evenodd"] ? kCAFillRuleEvenOdd : kCAFillRuleNonZero;
    if (stroke) {
        mask.fillColor = UIColor.clearColor.CGColor;
        mask.strokeColor = UIColor.whiteColor.CGColor;
        mask.lineWidth = lineWidth;
    } else {
        mask.fillColor = UIColor.whiteColor.CGColor;
    }
    layer.mask = mask;
    return layer;
}

static NSArray<NSString *> *zs_svg_animation_values(ZSLogoSVGAnimation *animation) {
    if (animation.values.count) return animation.values;
    if (animation.fromValue && animation.toValue) return @[animation.fromValue, animation.toValue];
    return @[];
}

static CAAnimation *zs_svg_make_animation(ZSLogoSVGAnimation *animation, ZSLogoSVGShape *shape, NSString *attribute, CGRect viewBoxBounds) {
    NSArray<NSString *> *values = zs_svg_animation_values(animation);
    if (!values.count || animation.duration <= 0 || [animation.animationType isEqualToString:@"animatemotion"]) return nil;
    NSString *keyPath = nil;
    NSMutableArray *nativeValues = [NSMutableArray array];
    if ([attribute isEqualToString:@"opacity"] || [attribute isEqualToString:@"fill-opacity"] || [attribute isEqualToString:@"stroke-opacity"]) {
        keyPath = @"opacity";
        for (NSString *value in values) [nativeValues addObject:@(zs_svg_fraction(value, 1))];
    } else if ([attribute isEqualToString:@"fill"] || [attribute isEqualToString:@"stroke"] || [attribute isEqualToString:@"stop-color"]) {
        keyPath = [attribute isEqualToString:@"stroke"] ? @"strokeColor" : @"fillColor";
        for (NSString *value in values) {
            UIColor *color = zs_svg_color(value, UIColor.blackColor);
            UIColor *resolvedColor = color ?: UIColor.clearColor;
            [nativeValues addObject:(__bridge id)resolvedColor.CGColor];
        }
    } else if ([attribute isEqualToString:@"stroke-width"]) {
        keyPath = @"lineWidth";
        for (NSString *value in values) [nativeValues addObject:@(MAX(0, zs_svg_number(value, 1)))];
    } else if ([attribute isEqualToString:@"d"]) {
        keyPath = @"path";
        for (NSString *value in values) {
            UIBezierPath *bezier = zs_svg_path_from_data(value);
            if (!bezier) continue;
            CGPathRef transformed = zs_svg_transformed_path(bezier.CGPath, shape.transform, CGPointMake(-CGRectGetMinX(viewBoxBounds), -CGRectGetMinY(viewBoxBounds)));
            if (transformed) { [nativeValues addObject:(__bridge_transfer id)transformed]; }
        }
    } else if ([attribute isEqualToString:@"transform"] || [attribute isEqualToString:@"transform.rotation"] || [attribute isEqualToString:@"transform.translation"] || [attribute isEqualToString:@"transform.scale"]) {
        if ([animation.animationType isEqualToString:@"animatetransform"]) {
            keyPath = @"transform";
            for (NSString *value in values) {
                const char *cursor = value.UTF8String;
                CGFloat nums[6] = {0, 0, 0, 0, 0, 0};
                NSUInteger count = 0;
                while (count < 6 && zs_svg_read_number(&cursor, &nums[count])) count++;
                CGAffineTransform transform = CGAffineTransformIdentity;
                NSString *type = animation.transformType.lowercaseString;
                if ([type isEqualToString:@"translate"]) transform = CGAffineTransformMakeTranslation(nums[0], count > 1 ? nums[1] : 0);
                else if ([type isEqualToString:@"scale"]) transform = CGAffineTransformMakeScale(nums[0], count > 1 ? nums[1] : nums[0]);
                else if ([type isEqualToString:@"rotate"]) transform = CGAffineTransformMakeRotation(nums[0] * (CGFloat)M_PI / 180.0);
                else if ([type isEqualToString:@"skewx"]) transform.c = tan(nums[0] * (CGFloat)M_PI / 180.0);
                else if ([type isEqualToString:@"skewy"]) transform.b = tan(nums[0] * (CGFloat)M_PI / 180.0);
                else if ([type isEqualToString:@"matrix"] && count >= 6) transform = CGAffineTransformMake(nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]);
                [nativeValues addObject:[NSValue valueWithCATransform3D:CATransform3DMakeAffineTransform(transform)]];
            }
        } else {
            keyPath = @"transform.rotation.z";
            for (NSString *value in values) [nativeValues addObject:@(zs_svg_number(value, 0) * M_PI / 180.0)];
        }
    }
    if (!keyPath || nativeValues.count == 0) return nil;
    CAKeyframeAnimation *result = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    result.values = nativeValues;
    result.duration = animation.duration;
    result.repeatCount = animation.repeatCount;
    result.removedOnCompletion = NO;
    result.fillMode = kCAFillModeBoth;
    result.calculationMode = [animation.calcMode isEqualToString:@"discrete"] ? kCAAnimationDiscrete : kCAAnimationLinear;
    if (animation.keyTimes.count == nativeValues.count) result.keyTimes = animation.keyTimes;
    result.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    return result;
}

@interface ZSLogoSVGRenderer : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) ZSLogoSVG *svg;
@property (nonatomic, weak, nullable) ZSLogoEffectView *owner;
@property (nonatomic, assign, getter=isHidden) BOOL hidden;
- (instancetype)initWithKey:(NSString *)key svg:(ZSLogoSVG *)svg;
- (void)mountInto:(UIView *)host;
- (void)placeWithSize:(CGSize)size center:(CGPoint)center rotation:(CGFloat)radians;
- (void)park;
- (void)teardown;
- (void)invalidate;
- (void)setSpeed:(double)speed paused:(BOOL)paused;
@end

@implementation ZSLogoSVGRenderer {
    BOOL _hidden;
    CALayer *_rootLayer;
    CALayer *_artworkLayer;
    BOOL _clockPaused;
    BOOL _hasSavedTime;
    CFTimeInterval _savedTime;
    double _speed;
    BOOL _paused;
    BOOL _appliedPaused;
    double _appliedSpeed;
}

- (instancetype)initWithKey:(NSString *)key svg:(ZSLogoSVG *)svg {
    self = [super init];
    if (!self) return nil;
    _key = [key copy];
    _svg = svg;
    _speed = 1;
    _paused = YES;
    _rootLayer = [CALayer layer];
    _rootLayer.anchorPoint = CGPointMake(0.5, 0.5);
    _rootLayer.masksToBounds = YES;
    _rootLayer.backgroundColor = UIColor.clearColor.CGColor;
    _artworkLayer = [CALayer layer];
    _artworkLayer.anchorPoint = CGPointMake(0, 0);
    _artworkLayer.bounds = CGRectMake(0, 0, MAX(1, svg.viewBox.size.width), MAX(1, svg.viewBox.size.height));
    _artworkLayer.position = CGPointZero;
    _artworkLayer.masksToBounds = NO;
    [_rootLayer addSublayer:_artworkLayer];

    CGRect viewBoxBounds = CGRectMake(0, 0, MAX(1, svg.viewBox.size.width), MAX(1, svg.viewBox.size.height));
    for (ZSLogoSVGShape *shape in svg.shapes) {
        CGRect bounds = CGPathGetBoundingBox(shape.path.CGPath);
        if (CGRectIsNull(bounds) || CGRectIsInfinite(bounds)) bounds = CGRectZero;
        CALayer *shapeGroup = [CALayer layer];
        shapeGroup.frame = viewBoxBounds;
        shapeGroup.opacity = shape.opacity;
        shapeGroup.masksToBounds = NO;
        CAShapeLayer *solid = [CAShapeLayer layer];
        solid.frame = viewBoxBounds;
        solid.path = shape.path.CGPath;
        solid.fillRule = [shape.fillRule isEqualToString:@"evenodd"] ? kCAFillRuleEvenOdd : kCAFillRuleNonZero;
        solid.lineWidth = shape.strokeWidth;
        solid.miterLimit = shape.miterLimit;
        solid.lineCap = [shape.lineCap isEqualToString:@"round"] ? kCALineCapRound : ([shape.lineCap isEqualToString:@"square"] ? kCALineCapSquare : kCALineCapButt);
        solid.lineJoin = [shape.lineJoin isEqualToString:@"round"] ? kCALineJoinRound : ([shape.lineJoin isEqualToString:@"bevel"] ? kCALineJoinBevel : kCALineJoinMiter);
        if (shape.dashArray.count) solid.lineDashPattern = shape.dashArray;
        solid.lineDashPhase = shape.dashOffset;
        UIColor *fillColor = zs_svg_color_alpha(shape.fillColor, shape.fillOpacity);
        UIColor *strokeColor = zs_svg_color_alpha(shape.strokeColor, shape.strokeOpacity);
        solid.fillColor = fillColor.CGColor;
        solid.strokeColor = strokeColor.CGColor;
        ZSLogoSVGGradient *fillGradient = svg.gradients[shape.fillGradientID ?: @""];
        ZSLogoSVGGradient *strokeGradient = svg.gradients[shape.strokeGradientID ?: @""];
        if (fillGradient) {
            CAGradientLayer *layer = zs_svg_gradient_layer(fillGradient, bounds, viewBoxBounds, NO, shape.strokeWidth, shape.path.CGPath, shape.fillRule, shape.fillOpacity, shape.strokeOpacity);
            if (layer) { layer.opacity = 1; [shapeGroup addSublayer:layer]; }
        }
        if (strokeGradient) {
            CAGradientLayer *layer = zs_svg_gradient_layer(strokeGradient, bounds, viewBoxBounds, YES, shape.strokeWidth, shape.path.CGPath, shape.fillRule, shape.fillOpacity, shape.strokeOpacity);
            if (layer) [shapeGroup addSublayer:layer];
        }
        BOOL needsSolid = (!fillGradient && fillColor) || (!strokeGradient && strokeColor);
        if (needsSolid) [shapeGroup addSublayer:solid];
        else if (shape.animations.count) [shapeGroup addSublayer:solid];

        NSArray<ZSLogoSVGShape *> *clipShapes = svg.clipPaths[shape.clipPathID ?: @""];
        if (clipShapes.count) {
            CGMutablePathRef clipPath = CGPathCreateMutable();
            for (ZSLogoSVGShape *clipShape in clipShapes) CGPathAddPath(clipPath, NULL, clipShape.path.CGPath);
            CAShapeLayer *mask = [CAShapeLayer layer];
            mask.frame = viewBoxBounds;
            mask.path = clipPath;
            mask.fillColor = UIColor.whiteColor.CGColor;
            mask.fillRule = kCAFillRuleNonZero;
            shapeGroup.mask = mask;
            CGPathRelease(clipPath);
        }
        [_artworkLayer addSublayer:shapeGroup];
        if (shape.animations.count) {
            NSUInteger animationIndex = 0;
            for (ZSLogoSVGAnimation *animation in shape.animations) {
                NSString *attribute = animation.attributeName;
                CALayer *target = ([attribute isEqualToString:@"opacity"] ? (CALayer *)shapeGroup : (CALayer *)solid);
                CAAnimation *native = zs_svg_make_animation(animation, shape, attribute, svg.viewBox);
                if (native) [target addAnimation:native forKey:[NSString stringWithFormat:@"zs.svg.%@.%lu", shape.identifier ?: @"shape", (unsigned long)animationIndex++]];
            }
        }
    }
    _rootLayer.speed = 0;
    _rootLayer.timeOffset = 0;
    _clockPaused = YES;
    [self zs_updateArtworkFrame];
    return self;
}

- (void)zs_updateArtworkFrame {
    CGSize size = _rootLayer.bounds.size;
    CGSize source = CGSizeMake(MAX(1, _svg.viewBox.size.width), MAX(1, _svg.viewBox.size.height));
    NSString *preserve = _svg.preserveAspectRatio.lowercaseString;
    CGFloat scaleX, scaleY;
    if ([preserve containsString:@"none"]) {
        scaleX = size.width / source.width;
        scaleY = size.height / source.height;
    } else {
        BOOL slice = [preserve containsString:@"slice"];
        CGFloat scale = slice ? MAX(size.width / source.width, size.height / source.height) : MIN(size.width / source.width, size.height / source.height);
        scaleX = scale;
        scaleY = scale;
    }
    CGSize rendered = CGSizeMake(source.width * scaleX, source.height * scaleY);
    CGFloat x = [preserve containsString:@"none"] || [preserve containsString:@"xmin"] ? 0 : ([preserve containsString:@"xmax"] ? size.width - rendered.width : (size.width - rendered.width) / 2);
    CGFloat y = [preserve containsString:@"none"] || [preserve containsString:@"ymin"] ? 0 : ([preserve containsString:@"ymax"] ? size.height - rendered.height : (size.height - rendered.height) / 2);
    _artworkLayer.transform = CATransform3DIdentity;
    _artworkLayer.bounds = CGRectMake(0, 0, source.width, source.height);
    _artworkLayer.position = CGPointMake(x, y);
    _artworkLayer.transform = CATransform3DMakeScale(scaleX, scaleY, 1);
}

- (void)mountInto:(UIView *)host {
    if (_rootLayer.superlayer == host.layer) return;
    [_rootLayer removeFromSuperlayer];
    [host.layer addSublayer:_rootLayer];
}

- (void)placeWithSize:(CGSize)size center:(CGPoint)center rotation:(CGFloat)radians {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _rootLayer.bounds = CGRectMake(0, 0, MAX(1, size.width), MAX(1, size.height));
    _rootLayer.position = center;
    _rootLayer.transform = CATransform3DMakeRotation(radians, 0, 0, 1);
    [self zs_updateArtworkFrame];
    [CATransaction commit];
}

- (void)setHidden:(BOOL)hidden {
    _hidden = hidden;
    _rootLayer.hidden = hidden;
}

- (BOOL)isHidden {
    return _hidden;
}

- (void)park {
    self.owner = nil;
    _rootLayer.hidden = YES;
    [_rootLayer removeFromSuperlayer];
    [self setSpeed:_speed paused:YES];
}

- (void)teardown {
    self.owner = nil;
    [_rootLayer removeFromSuperlayer];
}

- (void)invalidate {
    _appliedPaused = !_paused;
    [self setSpeed:_speed paused:_paused];
}

- (void)setSpeed:(double)speed paused:(BOOL)paused {
    _speed = isfinite(speed) ? MAX(0, speed) : 1;
    _paused = paused || _speed <= 0;
    if (_appliedSpeed == _speed && _appliedPaused == _paused) return;
    _appliedSpeed = _speed;
    _appliedPaused = _paused;
    if (_paused) {
        if (!_clockPaused) {
            _savedTime = [_rootLayer convertTime:CACurrentMediaTime() fromLayer:nil];
            _rootLayer.speed = 0;
            _rootLayer.timeOffset = _speed <= 0 ? 0 : _savedTime;
            _clockPaused = YES;
            _hasSavedTime = YES;
        } else if (_speed <= 0) {
            _rootLayer.timeOffset = 0;
            _savedTime = 0;
            _hasSavedTime = YES;
        }
        return;
    }
    if (_clockPaused) {
        CFTimeInterval pausedTime = _hasSavedTime ? _rootLayer.timeOffset : 0;
        _rootLayer.speed = _speed;
        _rootLayer.timeOffset = 0;
        _rootLayer.beginTime = 0;
        _rootLayer.beginTime = CACurrentMediaTime() - pausedTime / _speed;
        _clockPaused = NO;
        _hasSavedTime = NO;
    } else {
        CFTimeInterval currentTime = [_rootLayer convertTime:CACurrentMediaTime() fromLayer:nil];
        _rootLayer.speed = 0;
        _rootLayer.timeOffset = currentTime;
        _rootLayer.beginTime = 0;
        _rootLayer.speed = _speed;
        _rootLayer.beginTime = CACurrentMediaTime() - currentTime / _speed;
    }
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
            _renderer.hidden = NO;
        } else {
            _contentLayer.transform = CATransform3DIdentity;
            _contentLayer.bounds = CGRectMake(0, 0, width, height);
            _contentLayer.position = position;
            _contentLayer.transform = CATransform3DMakeRotation(radians, 0, 0, 1);
            _contentLayer.hidden = NO;
        }
    } else {
        _contentLayer.hidden = YES;
        _renderer.hidden = YES;
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
