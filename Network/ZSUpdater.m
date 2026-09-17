#import "ZSUpdater.h"
#import "ZTweakLog.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import "ZSVersion.h"
#import "Transcoder.h"

#pragma mark - ZSDylibUpdater

static NSString * const kZSLiveContainerTweaksSubpath = @"Documents/Tweaks";
static NSString * const kZSInstalledDylibName = @"ZSingularity.dylib";
static const NSUInteger kZSLiveContainerHomeAscentToDocuments = 3;

static void zs_self_image_anchor(void) {}

@interface ZSDylibUpdater ()
+ (nullable NSString *)zs_selfImagePath;
@end

@implementation ZSDylibUpdater

+ (nullable NSString *)zs_selfImagePath {
    Dl_info info;
    if (dladdr((const void *)&zs_self_image_anchor, &info) && info.dli_fname) {
        return @(info.dli_fname);
    }
    return [self selfLoadedDylibPath];
}

+ (BOOL)isRunningUnderLiveContainer {
    NSString *path = [self zs_selfImagePath];
    if (!path) return NO;
    return [path rangeOfString:@"/Documents/Tweaks/"].location != NSNotFound;
}

+ (BOOL)isStandaloneInstall {
    NSString *path = [self zs_selfImagePath];
    if (!path) return NO;
    return [path rangeOfString:@"/Frameworks/"].location != NSNotFound;
}

+ (nullable NSString *)zs_liveContainerTweaksDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;

    NSString *ascended = NSHomeDirectory();
    for (NSUInteger i = 0; i < kZSLiveContainerHomeAscentToDocuments; i++) {
        ascended = [ascended stringByDeletingLastPathComponent];
    }
    NSString *sharedTweaksDir = [ascended stringByAppendingPathComponent:@"Tweaks"];
    if ([fm fileExistsAtPath:sharedTweaksDir isDirectory:&isDirectory] && isDirectory) {
        return sharedTweaksDir;
    }

    NSString *fallbackTweaksDir = [NSHomeDirectory() stringByAppendingPathComponent:kZSLiveContainerTweaksSubpath];
    if ([fm fileExistsAtPath:fallbackTweaksDir isDirectory:&isDirectory] && isDirectory) {
        return fallbackTweaksDir;
    }

    return nil;
}

+ (nullable NSString *)installedDylibPath {
    if (![self isRunningUnderLiveContainer]) return nil;

    NSString *tweaksDir = [self zs_liveContainerTweaksDirectory];
    if (!tweaksDir) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray<NSString *> *folders = [fm contentsOfDirectoryAtPath:tweaksDir error:nil];
    for (NSString *folder in folders) {
        NSString *candidate = [[tweaksDir stringByAppendingPathComponent:folder]
            stringByAppendingPathComponent:kZSInstalledDylibName];
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDirectory] && !isDirectory) {
            return candidate;
        }
    }
    return nil;
}

+ (void)replaceInstalledDylibWithData:(NSData *)data
                             completion:(void (^)(BOOL success, NSString *message))completion {
    void (^finish)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(success, message); });
    };

    if (data.length == 0) {
        finish(NO, @"Downloaded dylib was empty.");
        return;
    }

    NSString *targetPath = [self installedDylibPath];
    if (!targetPath) {
        finish(NO, @"Couldn't locate the installed dylib under Documents/Tweaks.");
        return;
    }

    [self zs_stageAndReplaceAtPath:targetPath withData:data completion:completion];
}

+ (nullable NSString *)selfLoadedDylibPath {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *imagePath = @(name);
        if ([imagePath.lastPathComponent isEqualToString:kZSInstalledDylibName]) {
            return imagePath;
        }
    }
    return nil;
}

+ (void)zs_stageAndReplaceAtPath:(NSString *)targetPath
                          withData:(NSData *)data
                        completion:(void (^)(BOOL success, NSString *message))completion {
    void (^finish)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(success, message); });
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *tempPath = [targetPath stringByAppendingPathExtension:@"incoming"];
        NSError *writeError = nil;
        if (![data writeToFile:tempPath options:NSDataWritingAtomic error:&writeError]) {
            ZLog(@"[ZSDylibUpdater] failed to stage new dylib: %@", writeError);
            finish(NO, writeError.localizedDescription ?: @"Couldn't write the new dylib to disk.");
            return;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:targetPath error:nil];

        NSError *moveError = nil;
        if (![fm moveItemAtPath:tempPath toPath:targetPath error:&moveError]) {
            ZLog(@"[ZSDylibUpdater] failed to replace installed dylib: %@", moveError);
            finish(NO, moveError.localizedDescription ?: @"Couldn't replace the installed dylib.");
            return;
        }

        ZLog(@"[ZSDylibUpdater] replaced installed dylib at %@", targetPath);
        finish(YES, @"Replaced. Relaunch the app to load the new build.");
    });
}

@end

#pragma mark - ZSUpdateChecker

#ifndef ZS_BUILD_NUMBER
#define ZS_BUILD_NUMBER 0
#endif

NSString * const kZSUpdateRepoOwner = @"Vastrilliant";
NSString * const kZSUpdateRepoName  = @"ZSingularity";

static NSString * const kZSNightlyReleaseTag = @"nightly";

static NSComparisonResult ZSCompareVersionStrings(NSString *a, NSString *b) {
    NSArray<NSString *> *partsA = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *partsB = [b componentsSeparatedByString:@"."];
    NSUInteger count = MAX(partsA.count, partsB.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger va = i < partsA.count ? partsA[i].integerValue : 0;
        NSInteger vb = i < partsB.count ? partsB[i].integerValue : 0;
        if (va != vb) return va < vb ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}

@implementation ZSReleaseInfo

- (instancetype)initWithVersion:(NSString *)version notesMarkdown:(NSString * _Nullable)notesMarkdown
             hasDownloadableDylib:(BOOL)hasDownloadableDylib
                          htmlURL:(NSString * _Nullable)htmlURL {
    if ((self = [super init])) {
        _version = [version copy];
        _notesMarkdown = [notesMarkdown copy];
        _hasDownloadableDylib = hasDownloadableDylib;
        _htmlURL = [htmlURL copy];
    }
    return self;
}

@end

#pragma mark - Shared request helpers

static NSMutableURLRequest *zs_update_gh_request(NSURL *url, NSString * _Nullable authToken, NSString * _Nullable accept) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"ZSingularity-UpdateChecker" forHTTPHeaderField:@"User-Agent"];
    [request setValue:accept ?: @"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    if (authToken.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", authToken] forHTTPHeaderField:@"Authorization"];
    }
    return request;
}

static void zs_update_gh_json_get(NSURL *url, NSString * _Nullable authToken, BOOL isRetry,
                                   void (^completion)(id _Nullable json, NSError * _Nullable error)) {
    NSMutableURLRequest *request = zs_update_gh_request(url, authToken, nil);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;

        if ((error || !data || (http && http.statusCode != 200)) && authToken.length > 0 && !isRetry) {
            zs_update_gh_json_get(url, nil, YES, completion);
            return;
        }

        if (error || !data || (http && http.statusCode != 200)) {
            NSError *finalError = error ?: [NSError errorWithDomain:@"ZSUpdateChecker" code:http ? http.statusCode : 2
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Unexpected response (%ld) from GitHub.", (long)(http ? http.statusCode : 0)]}];
            completion(nil, finalError);
            return;
        }

        NSError *jsonError = nil;
        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        completion(root, root ? nil : jsonError);
    }];
    [task resume];
}

static void zs_update_gh_data_get(NSURL *url, NSString * _Nullable authToken, NSString * _Nullable accept, BOOL isRetry,
                                   void (^completion)(NSData * _Nullable data, NSError * _Nullable error)) {
    NSMutableURLRequest *request = zs_update_gh_request(url, authToken, accept);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;

        if ((error || !data || (http && http.statusCode != 200)) && authToken.length > 0 && !isRetry) {
            zs_update_gh_data_get(url, nil, accept, YES, completion);
            return;
        }

        if (error || !data || (http && http.statusCode != 200)) {
            NSError *finalError = error ?: [NSError errorWithDomain:@"ZSUpdateChecker" code:http ? http.statusCode : 2
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Unexpected response (%ld) downloading from GitHub.", (long)(http ? http.statusCode : 0)]}];
            completion(nil, finalError);
            return;
        }

        completion(data, nil);
    }];
    [task resume];
}

static void zs_update_gh_json_list_get(NSURL *url, NSString * _Nullable authToken, BOOL isRetry,
                                        void (^completion)(id _Nullable json, BOOL hasNextPage, NSError * _Nullable error)) {
    NSMutableURLRequest *request = zs_update_gh_request(url, authToken, nil);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;

        if ((error || !data || (http && http.statusCode != 200)) && authToken.length > 0 && !isRetry) {
            zs_update_gh_json_list_get(url, nil, YES, completion);
            return;
        }

        if (error || !data || (http && http.statusCode != 200)) {
            NSError *finalError = error ?: [NSError errorWithDomain:@"ZSUpdateChecker" code:http ? http.statusCode : 2
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Unexpected response (%ld) from GitHub.", (long)(http ? http.statusCode : 0)]}];
            completion(nil, NO, finalError);
            return;
        }

        NSString *linkHeader = http.allHeaderFields[@"Link"] ?: http.allHeaderFields[@"link"];
        BOOL hasNextPage = [linkHeader containsString:@"rel=\"next\""];

        NSError *jsonError = nil;
        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        completion(root, hasNextPage, root ? nil : jsonError);
    }];
    [task resume];
}

static NSInteger zs_extract_build_number(NSString *text) {
    if (text.length == 0) return 0;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"build (\\d+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match) return 0;
    return [text substringWithRange:[match rangeAtIndex:1]].integerValue;
}

static NSString * const kZSReleasesListURLFormat = @"https://api.github.com/repos/%@/%@/releases?per_page=%lu&page=%lu";
static const NSUInteger kZSReleaseListPageSize = 30;
static const NSUInteger kZSNightlyLookupMaxPages = 5;

static NSString *zs_releases_latest_url_string(void) {
    return [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",
            kZSUpdateRepoOwner, kZSUpdateRepoName];
}

static void zs_update_find_release_by_tag(NSString *tag, NSUInteger page, NSString * _Nullable authToken,
                                           void (^completion)(id _Nullable release, NSError * _Nullable error)) {
    if (page > kZSNightlyLookupMaxPages) {
        completion(nil, [NSError errorWithDomain:@"ZSUpdateChecker" code:404
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No release found for tag %@.", tag]}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:kZSReleasesListURLFormat,
        kZSUpdateRepoOwner, kZSUpdateRepoName, (unsigned long)kZSReleaseListPageSize, (unsigned long)page];
    NSURL *url = [NSURL URLWithString:urlString];

    zs_update_gh_json_list_get(url, authToken, NO, ^(id root, BOOL hasNextPage, NSError *error) {
        NSArray *releases = [root isKindOfClass:[NSArray class]] ? root : nil;
        for (NSDictionary *release in releases) {
            if (![release isKindOfClass:[NSDictionary class]]) continue;
            NSString *tagName = release[@"tag_name"];
            if (![tagName isKindOfClass:[NSString class]] || ![tagName isEqualToString:tag]) continue;

            NSString *releaseTitle = [release[@"name"] isKindOfClass:[NSString class]] ? release[@"name"] : @"";
            if ([releaseTitle rangeOfString:@"Nightly"].location == NSNotFound) {
                ZLog(@"[ZSUpdateChecker] release tagged \"%@\" skipped - title \"%@\" doesn't contain \"Nightly\"", tag, releaseTitle);
                continue;
            }

            completion(release, nil);
            return;
        }

        if (!hasNextPage || releases.count == 0) {
            completion(nil, error ?: [NSError errorWithDomain:@"ZSUpdateChecker" code:404
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No release found for tag %@.", tag]}]);
            return;
        }

        zs_update_find_release_by_tag(tag, page + 1, authToken, completion);
    });
}

static void zs_update_fetch_non_nightly_releases(NSUInteger page, NSMutableArray<NSDictionary *> *accumulated,
                                                  NSUInteger minimumCount, NSString * _Nullable authToken,
                                                  void (^completion)(NSArray<NSDictionary *> *releases, NSError * _Nullable error)) {
    NSString *urlString = [NSString stringWithFormat:kZSReleasesListURLFormat,
        kZSUpdateRepoOwner, kZSUpdateRepoName, (unsigned long)kZSReleaseListPageSize, (unsigned long)page];
    NSURL *url = [NSURL URLWithString:urlString];

    zs_update_gh_json_list_get(url, authToken, NO, ^(id root, BOOL hasNextPage, NSError *error) {
        NSArray *releases = [root isKindOfClass:[NSArray class]] ? root : nil;
        for (NSDictionary *release in releases) {
            if (![release isKindOfClass:[NSDictionary class]]) continue;

            NSString *tagName = release[@"tag_name"];
            BOOL isNightlyTag = [tagName isKindOfClass:[NSString class]] && [tagName isEqualToString:kZSNightlyReleaseTag];

            BOOL isDraft = [release[@"draft"] isKindOfClass:[NSNumber class]] && [release[@"draft"] boolValue];
            BOOL isPrerelease = [release[@"prerelease"] isKindOfClass:[NSNumber class]] && [release[@"prerelease"] boolValue];

            if (isNightlyTag || isDraft || isPrerelease) continue;
            [accumulated addObject:release];
        }

        if (accumulated.count >= minimumCount || !hasNextPage || releases.count == 0) {
            completion(accumulated, error);
            return;
        }

        zs_update_fetch_non_nightly_releases(page + 1, accumulated, minimumCount, authToken, completion);
    });
}

@implementation ZSUpdateChecker

#pragma mark - Version check

+ (void)checkForUpdateWithMode:(ZSUpdateCheckMode)mode
                     completion:(void (^)(ZSUpdateCheckResult result, NSString * _Nullable latestVersion))completion {
    NSString *authToken = [ZTranscoderSettings loadConfig].authToken;

    void (^handleRoot)(id, NSError *) = ^(id root, NSError *error) {
        NSString *tagName = [root isKindOfClass:[NSDictionary class]] ? root[@"tag_name"] : nil;
        if (![tagName isKindOfClass:[NSString class]]) {
            ZLog(@"[ZSUpdateChecker] couldn't parse latest release tag: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(ZSUpdateCheckResultUpToDate, nil); });
            return;
        }

        NSString *body = [root[@"body"] isKindOfClass:[NSString class]] ? root[@"body"] : @"";
        NSString *remoteVersion;
        ZSUpdateCheckResult result;
        if (mode == ZSUpdateCheckModeNightlyReleases) {
            NSInteger remoteBuild = zs_extract_build_number(body);
            result = remoteBuild > ZS_BUILD_NUMBER ? ZSUpdateCheckResultUpdateAvailable : ZSUpdateCheckResultUpToDate;
            remoteVersion = [NSString stringWithFormat:@"build %ld", (long)remoteBuild];
            ZLog(@"[ZSUpdateChecker] local build=%d latest nightly build=%ld result=%ld", ZS_BUILD_NUMBER, (long)remoteBuild, (long)result);
        } else {
            remoteVersion = [tagName hasPrefix:@"v"] ? [tagName substringFromIndex:1] : tagName;
            NSString *localVersion = @ZS_VERSION_STRING;
            result = ZSCompareVersionStrings(localVersion, remoteVersion) == NSOrderedAscending
                ? ZSUpdateCheckResultUpdateAvailable
                : ZSUpdateCheckResultUpToDate;
            ZLog(@"[ZSUpdateChecker] local=%@ latest=%@ result=%ld", localVersion, remoteVersion, (long)result);
        }

        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result, remoteVersion); });
    };

    if (mode == ZSUpdateCheckModeNightlyReleases) {
        zs_update_find_release_by_tag(kZSNightlyReleaseTag, 1, authToken, handleRoot);
        return;
    }

    NSURL *url = [NSURL URLWithString:zs_releases_latest_url_string()];
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(ZSUpdateCheckResultUpToDate, nil); });
        return;
    }
    zs_update_gh_json_get(url, authToken, NO, handleRoot);
}

#pragma mark - Release info (docs panel)

+ (void)fetchReleaseInfoWithMode:(ZSUpdateCheckMode)mode
                       completion:(void (^)(ZSReleaseInfo * _Nullable, NSError * _Nullable))completion {
    NSString *authToken = [ZTranscoderSettings loadConfig].authToken;

    void (^handleRoot)(id, NSError *) = ^(id root, NSError *error) {
        if (![root isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, error); });
            return;
        }

        NSString *tagName = [root[@"tag_name"] isKindOfClass:[NSString class]] ? root[@"tag_name"] : @"?";
        NSString *notes = [root[@"body"] isKindOfClass:[NSString class]] ? root[@"body"] : nil;
        NSString *htmlURL = [root[@"html_url"] isKindOfClass:[NSString class]] ? root[@"html_url"] : nil;
        NSString *version = (mode == ZSUpdateCheckModeNightlyReleases)
            ? [NSString stringWithFormat:@"build %ld", (long)zs_extract_build_number(notes)]
            : ([tagName hasPrefix:@"v"] ? [tagName substringFromIndex:1] : tagName);

        BOOL hasDylibAsset = NO;
        NSArray *assets = [root[@"assets"] isKindOfClass:[NSArray class]] ? root[@"assets"] : nil;
        for (NSDictionary *asset in assets) {
            NSString *name = [asset isKindOfClass:[NSDictionary class]] ? asset[@"name"] : nil;
            if ([name.lowercaseString hasSuffix:@".dylib"]) { hasDylibAsset = YES; break; }
        }

        ZSReleaseInfo *info = [[ZSReleaseInfo alloc] initWithVersion:version notesMarkdown:notes
                                                  hasDownloadableDylib:hasDylibAsset
                                                               htmlURL:htmlURL];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(info, nil); });
    };

    if (mode == ZSUpdateCheckModeNightlyReleases) {
        zs_update_find_release_by_tag(kZSNightlyReleaseTag, 1, authToken, handleRoot);
        return;
    }

    NSURL *url = [NSURL URLWithString:zs_releases_latest_url_string()];
    zs_update_gh_json_get(url, authToken, NO, handleRoot);
}

+ (void)fetchReleaseInfoAtIndex:(NSUInteger)index
                             mode:(ZSUpdateCheckMode)mode
                       completion:(void (^)(ZSReleaseInfo * _Nullable, BOOL, BOOL, NSError * _Nullable))completion {
    BOOL hasNewer = index > 0;

    if (mode == ZSUpdateCheckModeNightlyReleases) {
        [self fetchReleaseInfoWithMode:mode completion:^(ZSReleaseInfo * _Nullable info, NSError * _Nullable error) {
            if (completion) completion(info, NO, NO, error);
        }];
        return;
    }

    NSString *authToken = [ZTranscoderSettings loadConfig].authToken;
    NSMutableArray<NSDictionary *> *accumulated = [NSMutableArray array];

    zs_update_fetch_non_nightly_releases(1, accumulated, index + 2, authToken, ^(NSArray<NSDictionary *> *releases, NSError * _Nullable error) {
        NSDictionary *release = releases.count > index ? releases[index] : nil;
        if (![release isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, NO, hasNewer, error); });
            return;
        }

        BOOL hasOlder = releases.count > index + 1;

        NSString *tagName = [release[@"tag_name"] isKindOfClass:[NSString class]] ? release[@"tag_name"] : @"?";
        NSString *notes = [release[@"body"] isKindOfClass:[NSString class]] ? release[@"body"] : nil;
        NSString *htmlURL = [release[@"html_url"] isKindOfClass:[NSString class]] ? release[@"html_url"] : nil;
        NSString *version = [tagName hasPrefix:@"v"] ? [tagName substringFromIndex:1] : tagName;

        BOOL hasDylibAsset = NO;
        NSArray *assets = [release[@"assets"] isKindOfClass:[NSArray class]] ? release[@"assets"] : nil;
        for (NSDictionary *asset in assets) {
            NSString *name = [asset isKindOfClass:[NSDictionary class]] ? asset[@"name"] : nil;
            if ([name.lowercaseString hasSuffix:@".dylib"]) { hasDylibAsset = YES; break; }
        }

        ZSReleaseInfo *info = [[ZSReleaseInfo alloc] initWithVersion:version notesMarkdown:notes
                                                  hasDownloadableDylib:hasDylibAsset
                                                               htmlURL:htmlURL];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(info, hasOlder, hasNewer, nil); });
    });
}

#pragma mark - Dylib download

+ (void)fetchLatestDylibDataWithMode:(ZSUpdateCheckMode)mode
                           completion:(void (^)(NSData * _Nullable, NSError * _Nullable))completion {
    NSString *authToken = [ZTranscoderSettings loadConfig].authToken;

    void (^handleRoot)(id, NSError *) = ^(id root, NSError *error) {
        NSArray *assets = [root isKindOfClass:[NSDictionary class]] && [root[@"assets"] isKindOfClass:[NSArray class]]
            ? root[@"assets"] : nil;

        NSDictionary *dylibAsset = nil;
        for (NSDictionary *asset in assets) {
            NSString *name = [asset isKindOfClass:[NSDictionary class]] ? asset[@"name"] : nil;
            if ([name.lowercaseString hasSuffix:@".dylib"]) { dylibAsset = asset; break; }
        }

        NSString *assetURLString = [dylibAsset[@"url"] isKindOfClass:[NSString class]] ? dylibAsset[@"url"] : nil;
        NSURL *assetURL = assetURLString ? [NSURL URLWithString:assetURLString] : nil;
        if (!assetURL) {
            NSError *finalError = error ?: [NSError errorWithDomain:@"ZSUpdateChecker" code:20
                userInfo:@{NSLocalizedDescriptionKey: @"The latest release doesn't have a dylib asset attached."}];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, finalError); });
            return;
        }

        zs_update_gh_data_get(assetURL, authToken, @"application/octet-stream", NO, ^(NSData *data, NSError *downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(data, downloadError); });
        });
    };

    if (mode == ZSUpdateCheckModeNightlyReleases) {
        zs_update_find_release_by_tag(kZSNightlyReleaseTag, 1, authToken, handleRoot);
        return;
    }

    NSURL *url = [NSURL URLWithString:zs_releases_latest_url_string()];
    zs_update_gh_json_get(url, authToken, NO, handleRoot);
}

@end
