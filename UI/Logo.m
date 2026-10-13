#import "Logo.h"
#import "Engine.h"
#import "ZTweakLog.h"
#import <CoreText/CoreText.h>

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

@interface ZSLogoPack ()
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *fontPath;
@property (nonatomic, copy, readwrite, nullable) NSString *fillPath;
@property (nonatomic, copy, readwrite, nullable) NSString *vfxPath;
@property (nonatomic, copy, readwrite, nullable) NSString *postScriptName;
@property (nonatomic, assign) BOOL fontRegistered;
@end

@implementation ZSLogoPack
@end

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

static NSString *zs_logo_meta_path(NSString *name) {
    return [zs_logo_directory(name) stringByAppendingPathComponent:@"meta.json"];
}

static NSString *zs_logo_names_index_path(void) {
    return [zs_logo_cache_directory() stringByAppendingPathComponent:@"index.json"];
}

static NSDictionary *zs_logo_read_meta(NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:zs_logo_meta_path(name)];
    if (!data) return @{};
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : @{};
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

        NSDictionary *meta = zs_logo_read_meta(name);
        NSString *directory = zs_logo_directory(name);
        NSFileManager *fm = [NSFileManager defaultManager];

        NSString *(^pathForRole)(NSString *) = ^NSString *(NSString *role) {
            NSString *file = meta[role][@"file"];
            if (![file isKindOfClass:[NSString class]] || file.length == 0) return nil;
            NSString *path = [directory stringByAppendingPathComponent:file.lastPathComponent];
            return [fm fileExistsAtPath:path] ? path : nil;
        };

        NSString *fontPath = pathForRole(kZSLogoRoleFont);
        if (!fontPath) return nil;

        ZSLogoPack *pack = [[ZSLogoPack alloc] init];
        pack.name = name;
        pack.fontPath = fontPath;
        pack.fillPath = pathForRole(kZSLogoRoleFill);
        pack.vfxPath = pathForRole(kZSLogoRoleVfx);
        zs_logo_pack_cache()[name] = pack;
        return pack;
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

NSArray<NSString *> *zs_logo_cached_names(void) {
    NSData *data = [NSData dataWithContentsOfFile:zs_logo_names_index_path()];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if ([json isKindOfClass:[NSArray class]]) {
        for (id item in json) {
            if ([item isKindOfClass:[NSString class]] && zs_logo_name_is_safe(item)) [names addObject:item];
        }
    }
    return [@[kZSLogoDefaultName] arrayByAddingObjectsFromArray:names];
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

        for (NSString *role in @[kZSLogoRoleFont, kZSLogoRoleFill, kZSLogoRoleVfx]) {
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
