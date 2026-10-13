#import "Logo.h"
#import "Engine.h"
#import "ZTweakLog.h"
#import <CoreText/CoreText.h>
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

static NSString *zs_logo_role_for_filename(NSString *filename, NSString **extensionOut) {
    NSString *stem = filename.stringByDeletingPathExtension.lowercaseString;
    NSString *ext = filename.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"ttf"] || [ext isEqualToString:@"otf"]) {
        *extensionOut = ext;
        return kZSLogoRoleFont;
    }
    if ([ext isEqualToString:@"json"] && [stem isEqualToString:@"style"]) {
        *extensionOut = ext;
        return kZSLogoRoleStyle;
    }
    if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"gif"]) {
        if ([stem isEqualToString:@"fill"]) {
            *extensionOut = ext;
            return kZSLogoRoleFill;
        }
        if ([stem isEqualToString:@"vfx"]) {
            *extensionOut = ext;
            return kZSLogoRoleVfx;
        }
    }
    return nil;
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

static void zs_logo_sync(NSString *name, void (^completion)(BOOL success)) {
    NSString *subpath = name;
    zs_logo_fetch_listing(zs_logo_contents_url(subpath), ^(NSArray<NSDictionary *> *entries) {
        if (!entries) {
            completion(NO);
            return;
        }

        NSMutableDictionary<NSString *, NSDictionary *> *remote = [NSMutableDictionary dictionary];
        for (NSDictionary *entry in entries) {
            if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"type"] isEqual:@"file"]) continue;
            NSString *filename = entry[@"name"];
            NSString *downloadURL = entry[@"download_url"];
            if (![filename isKindOfClass:[NSString class]] || ![downloadURL isKindOfClass:[NSString class]]) continue;
            NSString *ext = nil;
            NSString *role = zs_logo_role_for_filename(filename, &ext);
            if (!role || remote[role]) continue;
            remote[role] = @{
                @"file": [NSString stringWithFormat:@"%@.%@", role, ext],
                @"sha": [entry[@"sha"] isKindOfClass:[NSString class]] ? entry[@"sha"] : @"",
                @"url": downloadURL,
            };
        }

        if (!remote[kZSLogoRoleFont]) {
            ZLog(@"[Logo] '%@' has no ttf/otf font in the repo", name);
            completion(NO);
            return;
        }

        NSString *directory = zs_logo_directory(name);
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

        NSDictionary *oldMeta = zs_logo_read_meta(name);
        NSMutableDictionary *newMeta = [NSMutableDictionary dictionary];
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t stateQueue = dispatch_queue_create("zs.logo.sync", DISPATCH_QUEUE_SERIAL);
        __block BOOL fontOK = NO;

        for (NSString *role in @[kZSLogoRoleFont, kZSLogoRoleFill, kZSLogoRoleVfx, kZSLogoRoleStyle]) {
            NSDictionary *info = remote[role];
            NSString *oldFile = oldMeta[role][@"file"];
            if (!info) {
                if ([oldFile isKindOfClass:[NSString class]]) {
                    [fm removeItemAtPath:[directory stringByAppendingPathComponent:oldFile.lastPathComponent] error:nil];
                }
                continue;
            }

            NSString *destination = [directory stringByAppendingPathComponent:info[@"file"]];
            BOOL upToDate = [oldMeta[role][@"sha"] isEqual:info[@"sha"]] && [oldMeta[role][@"file"] isEqual:info[@"file"]]
                && [fm fileExistsAtPath:destination];
            if (upToDate) {
                dispatch_sync(stateQueue, ^{
                    newMeta[role] = @{@"file": info[@"file"], @"sha": info[@"sha"]};
                    if ([role isEqualToString:kZSLogoRoleFont]) fontOK = YES;
                });
                continue;
            }

            if ([oldFile isKindOfClass:[NSString class]] && ![oldFile isEqualToString:info[@"file"]]) {
                [fm removeItemAtPath:[directory stringByAppendingPathComponent:oldFile.lastPathComponent] error:nil];
            }

            NSURL *url = [NSURL URLWithString:info[@"url"]];
            if (!url) continue;
            dispatch_group_enter(group);
            zs_logo_download_file(url, destination, ^(BOOL success) {
                dispatch_sync(stateQueue, ^{
                    if (success) {
                        newMeta[role] = @{@"file": info[@"file"], @"sha": info[@"sha"]};
                        if ([role isEqualToString:kZSLogoRoleFont]) fontOK = YES;
                    }
                });
                dispatch_group_leave(group);
            });
        }

        dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BOOL success = fontOK;
            if (success) {
                zs_logo_write_meta(name, newMeta);
                zs_logo_invalidate_pack(name);
            }
            completion(success);
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

    NSString *fallbackName = zipURL.lastPathComponent.stringByDeletingPathExtension;
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSArray *> *> *groups = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *groupNames = [NSMutableDictionary dictionary];

    for (ZSLogoZipRecord *record in records) {
        if (record.path.length == 0 || [record.path hasSuffix:@"/"]) continue;
        NSArray<NSString *> *components = [record.path componentsSeparatedByString:@"/"];

        BOOL skip = NO;
        for (NSString *component in components) {
            if (component.length == 0 || [component hasPrefix:@"."] || [component isEqualToString:@"__MACOSX"]) {
                skip = YES;
                break;
            }
        }
        if (skip) continue;

        NSString *extension = nil;
        NSString *role = zs_logo_role_for_filename(components.lastObject, &extension);
        if (!role) continue;

        NSArray<NSString *> *folders = [components subarrayWithRange:NSMakeRange(0, components.count - 1)];
        NSString *groupKey = [folders componentsJoinedByString:@"/"];
        groupNames[groupKey] = folders.count > 0 ? folders.lastObject : fallbackName;

        NSMutableDictionary *group = groups[groupKey];
        if (!group) {
            group = [NSMutableDictionary dictionary];
            groups[groupKey] = group;
        }
        if (!group[role]) group[role] = @[record, extension];
    }

    NSSet<NSString *> *remoteNames = [NSSet setWithArray:zs_logo_remote_cached_names()];
    NSMutableSet<NSString *> *usedNames = [NSMutableSet set];
    NSMutableArray<NSString *> *imported = [NSMutableArray array];
    NSString *firstError = nil;
    uint64_t totalSize = 0;

    for (NSString *groupKey in [groups.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary<NSString *, NSArray *> *group = groups[groupKey];
        if (!group[kZSLogoRoleFont]) continue;

        NSMutableDictionary<NSString *, NSArray *> *files = [NSMutableDictionary dictionary];
        BOOL groupOK = YES;
        for (NSString *role in @[kZSLogoRoleFont, kZSLogoRoleFill, kZSLogoRoleVfx, kZSLogoRoleStyle]) {
            NSArray *asset = group[role];
            if (!asset) continue;
            ZSLogoZipRecord *record = asset[0];

            totalSize += record.uncompressedSize;
            if (totalSize > kZSLogoZipMaxTotalSize) {
                firstError = firstError ?: @"The zip is too large.";
                groupOK = NO;
                break;
            }

            NSString *extractError = nil;
            NSData *data = zs_zip_extract(zip, record, &extractError);
            BOOL isFont = [role isEqualToString:kZSLogoRoleFont];
            if (data && isFont && !zs_logo_font_data_is_valid(data)) {
                data = nil;
                extractError = [NSString stringWithFormat:@"%@ isn't a readable font.", record.path.lastPathComponent];
            }
            if (!data) {
                if (isFont) {
                    firstError = firstError ?: extractError;
                    groupOK = NO;
                    break;
                }
                continue;
            }
            files[role] = @[[NSString stringWithFormat:@"%@.%@", role, asset[1]], data];
        }
        if (!groupOK) continue;

        NSString *name = zs_logo_import_resolve_name(groupNames[groupKey], usedNames, remoteNames);
        if (zs_logo_import_commit(name, files)) {
            [imported addObject:name];
        } else {
            firstError = firstError ?: @"Couldn't save the logo.";
        }
    }

    if (imported.count == 0) {
        *errorOut = firstError ?: @"No logo found. The zip needs a .ttf or .otf font, plus optional fill, vfx and style.json files.";
        return nil;
    }
    return imported;
}

void zs_logo_import_zip(NSURL *zipURL, ZSLogoImportCompletion completion) {
    BOOL scoped = [zipURL startAccessingSecurityScopedResource];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSArray<NSString *> *names = zs_logo_import_zip_sync(zipURL, &error);
        if (scoped) [zipURL stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(names ?: @[], names ? nil : (error ?: @"Couldn't add that logo."));
        });
    });
}
