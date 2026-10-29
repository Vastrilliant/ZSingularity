#import "Updater.h"
#import "ZTweakLog.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <compression.h>
#import <sys/stat.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <libkern/OSByteOrder.h>
#import <stdio.h>
#import <errno.h>
#import <string.h>
#import "Version.h"

#pragma mark - ZSDylibUpdater

static NSString * const kZSLiveContainerTweaksSubpath = @"Documents/Tweaks";
static NSString * const kZSInstalledDylibName = @"ZSingularity.dylib";
static const NSUInteger kZSLiveContainerHomeAscentToDocuments = 3;

static NSString * const kZSTweakFolderName = @"ZSingularity";

static BOOL zs_dylib_command_names_tweak(const struct dylib_command *command) {
    uint32_t offset = command->dylib.name.offset;
    if (offset < sizeof(struct dylib_command) || offset >= command->cmdsize) return NO;
    const char *name = (const char *)command + offset;
    size_t available = command->cmdsize - offset;
    size_t length = strnlen(name, available);
    if (length == available) return NO;
    NSString *loadedName = [[NSString alloc] initWithBytes:name length:length encoding:NSUTF8StringEncoding];
    return [loadedName.lastPathComponent isEqualToString:kZSInstalledDylibName];
}

static void zs_weaken_slice(uint8_t *slice, size_t size, NSInteger *patched, NSInteger *alreadyWeak) {
    if (size < sizeof(struct mach_header_64)) return;
    struct mach_header_64 *header = (struct mach_header_64 *)slice;
    if (header->magic != MH_MAGIC_64) return;
    size_t offset = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (offset + sizeof(struct load_command) > size) break;
        struct load_command *command = (struct load_command *)(slice + offset);
        if (command->cmdsize < sizeof(struct load_command) || offset + command->cmdsize > size) break;
        if ((command->cmd == LC_LOAD_DYLIB || command->cmd == LC_LOAD_WEAK_DYLIB) &&
            command->cmdsize >= sizeof(struct dylib_command) &&
            zs_dylib_command_names_tweak((struct dylib_command *)command)) {
            if (command->cmd == LC_LOAD_DYLIB) {
                command->cmd = LC_LOAD_WEAK_DYLIB;
                (*patched)++;
            } else {
                (*alreadyWeak)++;
            }
        }
        offset += command->cmdsize;
    }
}

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
    NSString *containerInfoPath = [NSHomeDirectory() stringByAppendingPathComponent:@"LCContainerInfo.plist"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:containerInfoPath]) return YES;
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

    if ([self isStandaloneInstall]) {
        NSString *embeddedPath = [self zs_selfImagePath];
        BOOL embeddedIsDirectory = NO;
        if (embeddedPath.length > 0 &&
            [[NSFileManager defaultManager] fileExistsAtPath:embeddedPath isDirectory:&embeddedIsDirectory] &&
            !embeddedIsDirectory) {
            return embeddedPath;
        }
    }

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

    if ([self isRunningUnderLiveContainer] && [self isStandaloneInstall]) {
        NSString *tweaksDir = [self zs_liveContainerTweaksDirectory];
        NSString *embeddedPath = [self zs_selfImagePath];
        if (tweaksDir.length > 0 && embeddedPath.length > 0) {
            [self zs_relocateToTweaksDirectory:tweaksDir embeddedPath:embeddedPath data:data completion:completion];
            return;
        }
    }

    NSString *targetPath = [self installedDylibPath];
    if (!targetPath) {
        finish(NO, @"Couldn't locate the installed dylib.");
        return;
    }

    [self zs_stageAndReplaceAtPath:targetPath withData:data completion:completion];
}

+ (BOOL)zs_weakenExecutableLoadCommandAtPath:(NSString *)executablePath message:(NSString **)message {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableData *buffer = [NSMutableData dataWithContentsOfFile:executablePath options:0 error:nil];
    if (buffer.length < sizeof(uint32_t)) {
        if (message) *message = @"Couldn't read the app executable.";
        return NO;
    }

    uint8_t *bytes = buffer.mutableBytes;
    size_t length = buffer.length;
    uint32_t rawMagic = *(uint32_t *)bytes;
    NSInteger patched = 0;
    NSInteger alreadyWeak = 0;

    if (rawMagic == MH_MAGIC_64) {
        zs_weaken_slice(bytes, length, &patched, &alreadyWeak);
    } else if (OSSwapBigToHostInt32(rawMagic) == FAT_MAGIC && length >= sizeof(struct fat_header)) {
        struct fat_header *fat = (struct fat_header *)bytes;
        uint32_t archCount = OSSwapBigToHostInt32(fat->nfat_arch);
        for (uint32_t i = 0; i < archCount; i++) {
            size_t archOffset = sizeof(struct fat_header) + i * sizeof(struct fat_arch);
            if (archOffset + sizeof(struct fat_arch) > length) break;
            struct fat_arch *arch = (struct fat_arch *)(bytes + archOffset);
            size_t sliceOffset = OSSwapBigToHostInt32(arch->offset);
            size_t sliceSize = OSSwapBigToHostInt32(arch->size);
            if (sliceOffset > length || sliceSize > length - sliceOffset) continue;
            zs_weaken_slice(bytes + sliceOffset, sliceSize, &patched, &alreadyWeak);
        }
    } else {
        if (message) *message = @"Unsupported app executable format.";
        return NO;
    }

    if (patched == 0 && alreadyWeak == 0) {
        if (message) *message = @"The app executable doesn't load the tweak directly, so it was left in place.";
        return NO;
    }
    if (patched == 0) {
        ZLog(@"[ZSDylibUpdater] executable already loads the tweak weakly");
        return YES;
    }

    NSDictionary *attributes = [fm attributesOfItemAtPath:executablePath error:nil];
    NSString *tempPath = [executablePath stringByAppendingPathExtension:@"zsnew"];
    NSError *writeError = nil;
    if (![buffer writeToFile:tempPath options:NSDataWritingAtomic error:&writeError]) {
        if (message) *message = writeError.localizedDescription ?: @"Couldn't write the patched executable.";
        return NO;
    }
    NSNumber *permissions = attributes[NSFilePosixPermissions];
    [fm setAttributes:@{NSFilePosixPermissions: permissions ?: @(0755)} ofItemAtPath:tempPath error:nil];
    if (rename(tempPath.fileSystemRepresentation, executablePath.fileSystemRepresentation) != 0) {
        [fm removeItemAtPath:tempPath error:nil];
        if (message) *message = [NSString stringWithFormat:@"Couldn't replace the app executable (errno %d).", errno];
        return NO;
    }

    ZLog(@"[ZSDylibUpdater] converted %ld load command(s) for %@ to weak in %@", (long)patched, kZSInstalledDylibName, executablePath.lastPathComponent);
    return YES;
}

+ (void)zs_relocateToTweaksDirectory:(NSString *)tweaksDir
                        embeddedPath:(NSString *)embeddedPath
                                data:(NSData *)data
                          completion:(void (^)(BOOL success, NSString *message))completion {
    void (^finish)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(success, message); });
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];

        NSString *destinationFolder = nil;
        for (NSString *folder in [fm contentsOfDirectoryAtPath:tweaksDir error:nil]) {
            NSString *folderPath = [tweaksDir stringByAppendingPathComponent:folder];
            NSString *candidate = [folderPath stringByAppendingPathComponent:kZSInstalledDylibName];
            BOOL isDirectory = NO;
            if ([fm fileExistsAtPath:candidate isDirectory:&isDirectory] && !isDirectory) {
                destinationFolder = folderPath;
                break;
            }
        }
        if (!destinationFolder) destinationFolder = [tweaksDir stringByAppendingPathComponent:kZSTweakFolderName];

        NSError *directoryError = nil;
        if (![fm createDirectoryAtPath:destinationFolder withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            finish(NO, directoryError.localizedDescription ?: @"Couldn't create the Tweaks folder.");
            return;
        }

        NSString *destinationPath = [destinationFolder stringByAppendingPathComponent:kZSInstalledDylibName];
        BOOL destinationExisted = [fm fileExistsAtPath:destinationPath];
        NSString *incomingPath = [destinationPath stringByAppendingPathExtension:@"incoming"];
        NSError *writeError = nil;
        if (![data writeToFile:incomingPath options:NSDataWritingAtomic error:&writeError]) {
            finish(NO, writeError.localizedDescription ?: @"Couldn't write the new dylib to disk.");
            return;
        }
        if (rename(incomingPath.fileSystemRepresentation, destinationPath.fileSystemRepresentation) != 0) {
            int renameErrno = errno;
            [fm removeItemAtPath:incomingPath error:nil];
            finish(NO, [NSString stringWithFormat:@"Couldn't place the new dylib in the Tweaks folder (errno %d).", renameErrno]);
            return;
        }

        NSString *executablePath = NSBundle.mainBundle.executablePath;
        NSString *patchMessage = nil;
        if (executablePath.length == 0 || ![self zs_weakenExecutableLoadCommandAtPath:executablePath message:&patchMessage]) {
            if (!destinationExisted) [fm removeItemAtPath:destinationPath error:nil];
            finish(NO, patchMessage ?: @"Couldn't locate the app executable.");
            return;
        }

        NSError *removeError = nil;
        if (![fm removeItemAtPath:embeddedPath error:&removeError]) {
            ZLog(@"[ZSDylibUpdater] couldn't remove embedded dylib %@: %@", embeddedPath, removeError);
        }

        ZLog(@"[ZSDylibUpdater] relocated update to %@", destinationPath);
        finish(YES, @"Installed to the LiveContainer Tweaks folder. Make sure that tweak folder is enabled for this app, then relaunch.");
    });
}

+ (BOOL)applyRequiredInfoPlistKeysIfNeeded {
    if (![self isRunningUnderLiveContainer]) return NO;

    NSString *plistPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSData *plistData = [NSData dataWithContentsOfFile:plistPath];
    if (plistData.length == 0) return NO;

    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    NSError *parseError = nil;
    NSMutableDictionary *info = [NSPropertyListSerialization propertyListWithData:plistData
                                                                          options:NSPropertyListMutableContainers
                                                                           format:&format
                                                                            error:&parseError];
    if (![info isKindOfClass:[NSMutableDictionary class]]) {
        ZLog(@"[ZSDylibUpdater] couldn't parse Info.plist: %@", parseError);
        return NO;
    }

    NSArray<NSString *> *requiredKeys = @[
        @"CADisableMinimumFrameDurationOnPhone",
        @"CADisableMinimumFrameDuration",
        @"LSSupportsGameMode",
        @"LSSupportsOpeningDocumentsInPlace",
        @"UIFileSharingEnabled",
    ];

    NSMutableArray<NSString *> *changedKeys = [NSMutableArray array];
    for (NSString *key in requiredKeys) {
        id value = info[key];
        BOOL enabled = [value isKindOfClass:[NSNumber class]] && [value boolValue];
        if (enabled) continue;
        info[key] = @YES;
        [changedKeys addObject:key];
    }
    if (changedKeys.count == 0) return NO;

    NSError *serializeError = nil;
    NSData *updatedData = [NSPropertyListSerialization dataWithPropertyList:info
                                                                     format:format
                                                                    options:0
                                                                      error:&serializeError];
    if (updatedData.length == 0) {
        ZLog(@"[ZSDylibUpdater] couldn't serialize Info.plist: %@", serializeError);
        return NO;
    }

    NSError *writeError = nil;
    if (![updatedData writeToFile:plistPath options:NSDataWritingAtomic error:&writeError]) {
        ZLog(@"[ZSDylibUpdater] couldn't write Info.plist: %@", writeError);
        return NO;
    }

    ZLog(@"[ZSDylibUpdater] wrote missing Info.plist keys: %@", [changedKeys componentsJoinedByString:@", "]);
    return YES;
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

static NSMutableURLRequest *zs_update_gh_request(NSURL *url, NSString * _Nullable accept) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"ZSingularity-UpdateChecker" forHTTPHeaderField:@"User-Agent"];
    [request setValue:accept ?: @"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    return request;
}

static void zs_update_gh_json_get(NSURL *url, void (^completion)(id _Nullable json, NSError * _Nullable error)) {
    NSMutableURLRequest *request = zs_update_gh_request(url, nil);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
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

static void zs_update_gh_data_get(NSURL *url, NSString * _Nullable accept,
                                   void (^completion)(NSData * _Nullable data, NSError * _Nullable error)) {
    NSMutableURLRequest *request = zs_update_gh_request(url, accept);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
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

static void zs_update_gh_json_list_get(NSURL *url,
                                        void (^completion)(id _Nullable json, BOOL hasNextPage, NSError * _Nullable error)) {
    NSMutableURLRequest *request = zs_update_gh_request(url, nil);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
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

static void zs_update_find_release_by_tag(NSString *tag, NSUInteger page,
                                           void (^completion)(id _Nullable release, NSError * _Nullable error)) {
    if (page > kZSNightlyLookupMaxPages) {
        completion(nil, [NSError errorWithDomain:@"ZSUpdateChecker" code:404
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No release found for tag %@.", tag]}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:kZSReleasesListURLFormat,
        kZSUpdateRepoOwner, kZSUpdateRepoName, (unsigned long)kZSReleaseListPageSize, (unsigned long)page];
    NSURL *url = [NSURL URLWithString:urlString];

    zs_update_gh_json_list_get(url, ^(id root, BOOL hasNextPage, NSError *error) {
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

        zs_update_find_release_by_tag(tag, page + 1, completion);
    });
}

static void zs_update_fetch_non_nightly_releases(NSUInteger page, NSMutableArray<NSDictionary *> *accumulated,
                                                  NSUInteger minimumCount,
                                                  void (^completion)(NSArray<NSDictionary *> *releases, NSError * _Nullable error)) {
    NSString *urlString = [NSString stringWithFormat:kZSReleasesListURLFormat,
        kZSUpdateRepoOwner, kZSUpdateRepoName, (unsigned long)kZSReleaseListPageSize, (unsigned long)page];
    NSURL *url = [NSURL URLWithString:urlString];

    zs_update_gh_json_list_get(url, ^(id root, BOOL hasNextPage, NSError *error) {
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

        zs_update_fetch_non_nightly_releases(page + 1, accumulated, minimumCount, completion);
    });
}

@implementation ZSUpdateChecker

#pragma mark - Version check

+ (void)checkForUpdateWithMode:(ZSUpdateCheckMode)mode
                     completion:(void (^)(ZSUpdateCheckResult result, NSString * _Nullable latestVersion))completion {

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
        zs_update_find_release_by_tag(kZSNightlyReleaseTag, 1, handleRoot);
        return;
    }

    NSURL *url = [NSURL URLWithString:zs_releases_latest_url_string()];
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(ZSUpdateCheckResultUpToDate, nil); });
        return;
    }
    zs_update_gh_json_get(url, handleRoot);
}

#pragma mark - Release info (docs panel)

+ (void)fetchReleaseInfoWithMode:(ZSUpdateCheckMode)mode
                       completion:(void (^)(ZSReleaseInfo * _Nullable, NSError * _Nullable))completion {

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
        zs_update_find_release_by_tag(kZSNightlyReleaseTag, 1, handleRoot);
        return;
    }

    NSURL *url = [NSURL URLWithString:zs_releases_latest_url_string()];
    zs_update_gh_json_get(url, handleRoot);
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

    NSMutableArray<NSDictionary *> *accumulated = [NSMutableArray array];

    zs_update_fetch_non_nightly_releases(1, accumulated, index + 2, ^(NSArray<NSDictionary *> *releases, NSError * _Nullable error) {
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

        zs_update_gh_data_get(assetURL, @"application/octet-stream", ^(NSData *data, NSError *downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(data, downloadError); });
        });
    };

    if (mode == ZSUpdateCheckModeNightlyReleases) {
        zs_update_find_release_by_tag(kZSNightlyReleaseTag, 1, handleRoot);
        return;
    }

    NSURL *url = [NSURL URLWithString:zs_releases_latest_url_string()];
    zs_update_gh_json_get(url, handleRoot);
}

@end

#pragma mark - ZSLiveContainerPatcher

static NSString * const kZSPatchErrorDomain = @"ZSLiveContainerPatcher";
static NSString * const kZSPatchAppexName = @"ZSRamDonor.appex";
static NSString * const kZSPatchDefaultExecutable = @"ZSRamDonor";

static NSError *zs_patch_error(NSString *message) {
    return [NSError errorWithDomain:kZSPatchErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static uint16_t zs_patch_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t zs_patch_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint32_t zs_patch_crc32(const uint8_t *bytes, size_t length) {
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

@interface ZSPatchZipEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSData *nameBytes;
@property (nonatomic, assign) uint16_t versionMadeBy;
@property (nonatomic, assign) uint16_t flags;
@property (nonatomic, assign) uint16_t method;
@property (nonatomic, assign) uint16_t dosTime;
@property (nonatomic, assign) uint16_t dosDate;
@property (nonatomic, assign) uint16_t internalAttributes;
@property (nonatomic, assign) uint32_t crc;
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t size;
@property (nonatomic, assign) uint32_t externalAttributes;
@property (nonatomic, assign) uint32_t localOffset;
@end

@implementation ZSPatchZipEntry
@end

static NSArray<ZSPatchZipEntry *> *zs_patch_read_entries(NSData *data, NSError **error) {
    const uint8_t *bytes = data.bytes;
    NSInteger length = (NSInteger)data.length;
    if (length < 22) {
        if (error) *error = zs_patch_error(@"File is too small to be a zip archive.");
        return nil;
    }

    NSInteger lowest = MAX((NSInteger)0, length - 22 - 65535);
    NSInteger eocd = -1;
    for (NSInteger i = length - 22; i >= lowest; i--) {
        if (zs_patch_u32(bytes + i) != 0x06054b50) continue;
        if (i + 22 + zs_patch_u16(bytes + i + 20) != length) continue;
        eocd = i;
        break;
    }
    if (eocd < 0) {
        if (error) *error = zs_patch_error(@"No central directory found, this isn't a valid zip archive.");
        return nil;
    }

    const uint8_t *tail = bytes + eocd;
    uint16_t count = zs_patch_u16(tail + 10);
    uint32_t cdSize = zs_patch_u32(tail + 12);
    uint32_t cdOffset = zs_patch_u32(tail + 16);
    if (count == 0xFFFF || cdSize == 0xFFFFFFFFu || cdOffset == 0xFFFFFFFFu) {
        if (error) *error = zs_patch_error(@"ZIP64 archives aren't supported.");
        return nil;
    }
    if ((uint64_t)cdOffset + cdSize > (uint64_t)length) {
        if (error) *error = zs_patch_error(@"The zip's central directory runs past the end of the file.");
        return nil;
    }

    NSMutableArray<ZSPatchZipEntry *> *entries = [NSMutableArray arrayWithCapacity:count];
    NSUInteger cursor = cdOffset;
    NSUInteger cdEnd = (NSUInteger)cdOffset + cdSize;
    for (uint16_t i = 0; i < count; i++) {
        if (cursor + 46 > cdEnd) break;
        const uint8_t *p = bytes + cursor;
        if (zs_patch_u32(p) != 0x02014b50) break;

        uint16_t nameLength = zs_patch_u16(p + 28);
        uint16_t extraLength = zs_patch_u16(p + 30);
        uint16_t commentLength = zs_patch_u16(p + 32);
        if (cursor + 46 + nameLength > cdEnd) break;

        ZSPatchZipEntry *entry = [ZSPatchZipEntry new];
        entry.versionMadeBy = zs_patch_u16(p + 4);
        entry.flags = zs_patch_u16(p + 8);
        entry.method = zs_patch_u16(p + 10);
        entry.dosTime = zs_patch_u16(p + 12);
        entry.dosDate = zs_patch_u16(p + 14);
        entry.crc = zs_patch_u32(p + 16);
        entry.compressedSize = zs_patch_u32(p + 20);
        entry.size = zs_patch_u32(p + 24);
        entry.internalAttributes = zs_patch_u16(p + 36);
        entry.externalAttributes = zs_patch_u32(p + 38);
        entry.localOffset = zs_patch_u32(p + 42);
        if (entry.compressedSize == 0xFFFFFFFFu || entry.size == 0xFFFFFFFFu || entry.localOffset == 0xFFFFFFFFu) {
            if (error) *error = zs_patch_error(@"ZIP64 entries aren't supported.");
            return nil;
        }

        NSData *nameBytes = [NSData dataWithBytes:(p + 46) length:nameLength];
        NSString *name = [[NSString alloc] initWithData:nameBytes encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithData:nameBytes encoding:NSISOLatin1StringEncoding];
        entry.nameBytes = nameBytes;
        entry.name = name ?: @"";
        [entries addObject:entry];

        cursor += 46 + nameLength + extraLength + commentLength;
    }

    if (entries.count != count) {
        if (error) *error = zs_patch_error(@"The zip's central directory is corrupt.");
        return nil;
    }
    return entries;
}

static BOOL zs_patch_payload_start(NSData *data, ZSPatchZipEntry *entry, NSUInteger *outStart) {
    uint64_t offset = entry.localOffset;
    if (offset + 30 > data.length) return NO;
    const uint8_t *p = (const uint8_t *)data.bytes + offset;
    if (zs_patch_u32(p) != 0x04034b50) return NO;
    uint64_t start = offset + 30 + zs_patch_u16(p + 26) + zs_patch_u16(p + 28);
    if (start + entry.compressedSize > data.length) return NO;
    *outStart = (NSUInteger)start;
    return YES;
}

static NSData *zs_patch_entry_data(NSData *data, ZSPatchZipEntry *entry, NSError **error) {
    NSUInteger start = 0;
    if (!zs_patch_payload_start(data, entry, &start)) {
        if (error) *error = zs_patch_error([NSString stringWithFormat:@"\"%@\" is corrupt, its data lies outside the archive.", entry.name]);
        return nil;
    }
    if (entry.flags & 0x0001) {
        if (error) *error = zs_patch_error([NSString stringWithFormat:@"\"%@\" is encrypted.", entry.name]);
        return nil;
    }

    const uint8_t *payload = (const uint8_t *)data.bytes + start;
    NSData *result = nil;
    if (entry.method == 0) {
        result = [NSData dataWithBytes:payload length:entry.compressedSize];
    } else if (entry.method == 8) {
        NSMutableData *out = [NSMutableData dataWithLength:entry.size];
        if (entry.size > 0) {
            size_t decoded = compression_decode_buffer(out.mutableBytes, entry.size, payload, entry.compressedSize, NULL, COMPRESSION_ZLIB);
            if (decoded != entry.size) {
                if (error) *error = zs_patch_error([NSString stringWithFormat:@"Couldn't decompress \"%@\".", entry.name]);
                return nil;
            }
        }
        result = out;
    } else {
        if (error) *error = zs_patch_error([NSString stringWithFormat:@"\"%@\" uses unsupported zip compression method %u.", entry.name, entry.method]);
        return nil;
    }

    if (zs_patch_crc32(result.bytes, result.length) != entry.crc) {
        if (error) *error = zs_patch_error([NSString stringWithFormat:@"\"%@\" failed its checksum.", entry.name]);
        return nil;
    }
    return result;
}

@interface ZSPatchZipWriter : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (BOOL)copyEntry:(ZSPatchZipEntry *)entry fromData:(NSData *)source;
- (BOOL)addEntryNamed:(NSString *)name data:(NSData *)data mode:(uint16_t)mode;
- (BOOL)finish;
@end

@implementation ZSPatchZipWriter {
    FILE *_file;
    BOOL _failed;
    NSMutableArray<ZSPatchZipEntry *> *_records;
    uint16_t _dosTime;
    uint16_t _dosDate;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _file = fopen(path.fileSystemRepresentation, "wb");
        _failed = (_file == NULL);
        _records = [NSMutableArray array];
        time_t now = time(NULL);
        struct tm local;
        localtime_r(&now, &local);
        _dosTime = (uint16_t)((local.tm_hour << 11) | (local.tm_min << 5) | (local.tm_sec / 2));
        _dosDate = (uint16_t)(((MAX(local.tm_year - 80, 0)) << 9) | ((local.tm_mon + 1) << 5) | local.tm_mday);
    }
    return self;
}

- (void)dealloc {
    if (_file) fclose(_file);
}

- (void)writeU16:(uint16_t)value {
    uint8_t b[2] = { (uint8_t)(value & 0xFF), (uint8_t)(value >> 8) };
    if (fwrite(b, 1, 2, _file) != 2) _failed = YES;
}

- (void)writeU32:(uint32_t)value {
    uint8_t b[4] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF), (uint8_t)((value >> 16) & 0xFF), (uint8_t)(value >> 24) };
    if (fwrite(b, 1, 4, _file) != 4) _failed = YES;
}

- (void)writeBytes:(const void *)bytes length:(size_t)length {
    if (length > 0 && fwrite(bytes, 1, length, _file) != length) _failed = YES;
}

- (BOOL)writeEntry:(ZSPatchZipEntry *)entry payload:(const void *)payload {
    if (_failed || !_file || _records.count >= 0xFFFE || entry.nameBytes.length > 0xFFFF) return NO;
    long position = ftell(_file);
    if (position < 0 || (uint64_t)position >= 0xFFFFFFFFu) return NO;

    ZSPatchZipEntry *record = [ZSPatchZipEntry new];
    record.name = entry.name;
    record.nameBytes = entry.nameBytes;
    record.versionMadeBy = entry.versionMadeBy;
    record.flags = entry.flags & (uint16_t)~0x0008;
    record.method = entry.method;
    record.dosTime = entry.dosTime;
    record.dosDate = entry.dosDate;
    record.internalAttributes = entry.internalAttributes;
    record.crc = entry.crc;
    record.compressedSize = entry.compressedSize;
    record.size = entry.size;
    record.externalAttributes = entry.externalAttributes;
    record.localOffset = (uint32_t)position;

    [self writeU32:0x04034B50];
    [self writeU16:20];
    [self writeU16:record.flags];
    [self writeU16:record.method];
    [self writeU16:record.dosTime];
    [self writeU16:record.dosDate];
    [self writeU32:record.crc];
    [self writeU32:record.compressedSize];
    [self writeU32:record.size];
    [self writeU16:(uint16_t)record.nameBytes.length];
    [self writeU16:0];
    [self writeBytes:record.nameBytes.bytes length:record.nameBytes.length];
    [self writeBytes:payload length:record.compressedSize];
    if (_failed) return NO;
    [_records addObject:record];
    return YES;
}

- (BOOL)copyEntry:(ZSPatchZipEntry *)entry fromData:(NSData *)source {
    NSUInteger start = 0;
    if (!zs_patch_payload_start(source, entry, &start)) return NO;
    return [self writeEntry:entry payload:(const uint8_t *)source.bytes + start];
}

- (BOOL)addEntryNamed:(NSString *)name data:(NSData *)data mode:(uint16_t)mode {
    if (data.length >= 0xFFFFFFFFu) return NO;

    uint16_t method = 0;
    NSData *payload = data;
    if (data.length > 64) {
        NSMutableData *packed = [NSMutableData dataWithLength:data.length];
        size_t written = compression_encode_buffer(packed.mutableBytes, packed.length, data.bytes, data.length, NULL, COMPRESSION_ZLIB);
        if (written > 0 && written < data.length) {
            packed.length = written;
            payload = packed;
            method = 8;
        }
    }

    ZSPatchZipEntry *entry = [ZSPatchZipEntry new];
    entry.name = name;
    entry.nameBytes = [name dataUsingEncoding:NSUTF8StringEncoding];
    entry.versionMadeBy = 0x031E;
    entry.flags = 0x0800;
    entry.method = method;
    entry.dosTime = _dosTime;
    entry.dosDate = _dosDate;
    entry.internalAttributes = 0;
    entry.crc = zs_patch_crc32(data.bytes, data.length);
    entry.compressedSize = (uint32_t)payload.length;
    entry.size = (uint32_t)data.length;
    entry.externalAttributes = ((uint32_t)(S_IFREG | mode)) << 16;
    return [self writeEntry:entry payload:payload.bytes];
}

- (BOOL)finish {
    if (_failed || !_file) return NO;
    long centralStart = ftell(_file);
    if (centralStart < 0) return NO;
    for (ZSPatchZipEntry *record in _records) {
        [self writeU32:0x02014B50];
        [self writeU16:record.versionMadeBy];
        [self writeU16:20];
        [self writeU16:record.flags];
        [self writeU16:record.method];
        [self writeU16:record.dosTime];
        [self writeU16:record.dosDate];
        [self writeU32:record.crc];
        [self writeU32:record.compressedSize];
        [self writeU32:record.size];
        [self writeU16:(uint16_t)record.nameBytes.length];
        [self writeU16:0];
        [self writeU16:0];
        [self writeU16:0];
        [self writeU16:record.internalAttributes];
        [self writeU32:record.externalAttributes];
        [self writeU32:record.localOffset];
        [self writeBytes:record.nameBytes.bytes length:record.nameBytes.length];
    }
    long centralEnd = ftell(_file);
    if (centralEnd < 0 || _failed) return NO;
    [self writeU32:0x06054B50];
    [self writeU16:0];
    [self writeU16:0];
    [self writeU16:(uint16_t)_records.count];
    [self writeU16:(uint16_t)_records.count];
    [self writeU32:(uint32_t)(centralEnd - centralStart)];
    [self writeU32:(uint32_t)centralStart];
    [self writeU16:0];
    BOOL ok = !_failed && fflush(_file) == 0;
    fclose(_file);
    _file = NULL;
    return ok;
}

@end

@implementation ZSLiveContainerPatcher

+ (nullable NSDictionary<NSString *, NSArray *> *)zs_appexFilesFromZipData:(NSData *)zipData error:(NSError **)error {
    NSArray<ZSPatchZipEntry *> *entries = zs_patch_read_entries(zipData, error);
    if (!entries) return nil;

    NSString *marker = [kZSPatchAppexName stringByAppendingString:@"/"];
    NSMutableDictionary<NSString *, NSArray *> *files = [NSMutableDictionary dictionary];
    for (ZSPatchZipEntry *entry in entries) {
        NSString *name = entry.name;
        if ([name hasSuffix:@"/"] || [name hasPrefix:@"__MACOSX/"]) continue;
        NSRange range = [name rangeOfString:marker];
        if (range.location == NSNotFound) continue;
        NSString *relative = [name substringFromIndex:NSMaxRange(range)];
        if (relative.length == 0 || [relative hasPrefix:@"_CodeSignature/"]) continue;

        NSData *payload = zs_patch_entry_data(zipData, entry, error);
        if (!payload) return nil;
        uint16_t mode = (uint16_t)((entry.externalAttributes >> 16) & 0777);
        files[relative] = @[payload, @(mode)];
    }
    return files;
}

+ (BOOL)zs_patchIPAAtURL:(NSURL *)ipaURL
            appexZipData:(NSData *)appexZipData
               outputURL:(NSURL *)outputURL
            hostBundleID:(NSString * _Nullable * _Nonnull)outHostID
                   error:(NSError **)error {
    NSDictionary<NSString *, NSArray *> *appexFiles = [self zs_appexFilesFromZipData:appexZipData error:error];
    if (!appexFiles) return NO;
    if (!appexFiles[@"Info.plist"]) {
        if (error) *error = zs_patch_error(@"The downloaded ZSRamDonor.appex doesn't contain an Info.plist.");
        return NO;
    }

    NSData *ipaData = [NSData dataWithContentsOfURL:ipaURL options:NSDataReadingMappedIfSafe error:error];
    if (!ipaData) return NO;
    NSArray<ZSPatchZipEntry *> *ipaEntries = zs_patch_read_entries(ipaData, error);
    if (!ipaEntries) return NO;

    NSString *appPrefix = nil;
    ZSPatchZipEntry *hostPlistEntry = nil;
    for (ZSPatchZipEntry *entry in ipaEntries) {
        NSArray<NSString *> *parts = [entry.name componentsSeparatedByString:@"/"];
        if (parts.count >= 3 && [parts[0] isEqualToString:@"Payload"] && [parts[1] hasSuffix:@".app"] && [parts[2] isEqualToString:@"Info.plist"]) {
            appPrefix = [@"Payload/" stringByAppendingString:parts[1]];
            hostPlistEntry = entry;
            break;
        }
    }
    if (!appPrefix || !hostPlistEntry) {
        if (error) *error = zs_patch_error(@"Couldn't find the .app bundle inside the IPA.");
        return NO;
    }

    NSData *hostPlistData = zs_patch_entry_data(ipaData, hostPlistEntry, error);
    if (!hostPlistData) return NO;
    NSDictionary *hostPlist = [NSPropertyListSerialization propertyListWithData:hostPlistData options:NSPropertyListImmutable format:NULL error:nil];
    NSString *hostID = [hostPlist isKindOfClass:[NSDictionary class]] ? hostPlist[@"CFBundleIdentifier"] : nil;
    if (![hostID isKindOfClass:[NSString class]] || hostID.length == 0) {
        if (error) *error = zs_patch_error(@"The IPA's Info.plist has no CFBundleIdentifier.");
        return NO;
    }
    NSString *donorID = [hostID stringByAppendingString:@".ZSRamDonor"];

    NSMutableDictionary *appexPlist = [NSPropertyListSerialization propertyListWithData:appexFiles[@"Info.plist"][0]
                                                                                 options:NSPropertyListMutableContainersAndLeaves
                                                                                  format:NULL
                                                                                   error:nil];
    if (![appexPlist isKindOfClass:[NSMutableDictionary class]]) {
        if (error) *error = zs_patch_error(@"The downloaded ZSRamDonor.appex has an unreadable Info.plist.");
        return NO;
    }
    appexPlist[@"CFBundleIdentifier"] = donorID;
    NSString *displayName = appexPlist[@"CFBundleDisplayName"];
    if (![displayName isKindOfClass:[NSString class]] || displayName.length == 0) {
        NSString *bundleName = appexPlist[@"CFBundleName"];
        appexPlist[@"CFBundleDisplayName"] = ([bundleName isKindOfClass:[NSString class]] && bundleName.length > 0) ? bundleName : kZSPatchDefaultExecutable;
    }
    NSString *executable = [appexPlist[@"CFBundleExecutable"] isKindOfClass:[NSString class]] ? appexPlist[@"CFBundleExecutable"] : kZSPatchDefaultExecutable;
    NSData *patchedPlist = [NSPropertyListSerialization dataWithPropertyList:appexPlist format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!patchedPlist) return NO;

    NSMutableDictionary<NSString *, NSArray *> *finalFiles = [appexFiles mutableCopy];
    finalFiles[@"Info.plist"] = @[patchedPlist, @(0644)];
    if (!finalFiles[executable]) {
        if (error) *error = zs_patch_error([NSString stringWithFormat:@"The downloaded ZSRamDonor.appex has no executable named %@.", executable]);
        return NO;
    }

    NSString *targetPrefix = [NSString stringWithFormat:@"%@/PlugIns/%@/", appPrefix, kZSPatchAppexName];
    ZSPatchZipWriter *writer = [[ZSPatchZipWriter alloc] initWithPath:outputURL.path];
    for (ZSPatchZipEntry *entry in ipaEntries) {
        if ([entry.name hasPrefix:targetPrefix]) continue;
        if (![writer copyEntry:entry fromData:ipaData]) {
            if (error) *error = zs_patch_error([NSString stringWithFormat:@"Couldn't copy \"%@\" into the patched IPA.", entry.name]);
            return NO;
        }
    }

    for (NSString *relative in [finalFiles.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *payload = finalFiles[relative][0];
        uint16_t mode = (uint16_t)[finalFiles[relative][1] unsignedShortValue];
        if ([relative isEqualToString:executable]) mode = 0755;
        else if (mode == 0) mode = 0644;
        if (![writer addEntryNamed:[targetPrefix stringByAppendingString:relative] data:payload mode:mode]) {
            if (error) *error = zs_patch_error([NSString stringWithFormat:@"Couldn't add \"%@\" to the patched IPA.", relative]);
            return NO;
        }
    }

    if (![writer finish]) {
        if (error) *error = zs_patch_error(@"Couldn't finish writing the patched IPA, the device may be out of space.");
        return NO;
    }

    *outHostID = hostID;
    return YES;
}

+ (void)patchIPAAtURL:(NSURL *)ipaURL
           completion:(void (^)(NSURL * _Nullable, NSString * _Nullable, NSError * _Nullable))completion {
    void (^finish)(NSURL *, NSString *, NSError *) = ^(NSURL *patchedURL, NSString *hostID, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(patchedURL, hostID, error); });
    };

    zs_update_find_release_by_tag(kZSNightlyReleaseTag, 1, ^(id release, NSError *releaseError) {
        NSArray *assets = [release isKindOfClass:[NSDictionary class]] && [release[@"assets"] isKindOfClass:[NSArray class]] ? release[@"assets"] : nil;

        NSDictionary *appexAsset = nil;
        for (NSDictionary *asset in assets) {
            NSString *name = [asset isKindOfClass:[NSDictionary class]] ? asset[@"name"] : nil;
            if ([name isKindOfClass:[NSString class]] && [name.lowercaseString hasSuffix:@".appex.zip"]) { appexAsset = asset; break; }
        }

        NSString *assetURLString = [appexAsset[@"url"] isKindOfClass:[NSString class]] ? appexAsset[@"url"] : nil;
        NSURL *assetURL = assetURLString ? [NSURL URLWithString:assetURLString] : nil;
        if (!assetURL) {
            finish(nil, nil, releaseError ?: zs_patch_error(@"The nightly release doesn't have a ZSRamDonor.appex.zip asset attached."));
            return;
        }

        zs_update_gh_data_get(assetURL, @"application/octet-stream", ^(NSData *appexZipData, NSError *downloadError) {
            if (!appexZipData) {
                finish(nil, nil, downloadError ?: zs_patch_error(@"Couldn't download ZSRamDonor.appex from the nightly release."));
                return;
            }

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSFileManager *fm = [NSFileManager defaultManager];
                NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"ZSPatchLC-" stringByAppendingString:[NSUUID UUID].UUIDString]];
                NSError *directoryError = nil;
                if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
                    finish(nil, nil, directoryError);
                    return;
                }

                NSString *stem = ipaURL.lastPathComponent.stringByDeletingPathExtension;
                if (stem.length == 0) stem = @"Patched";
                NSURL *outputURL = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[stem stringByAppendingString:@"-Patched.ipa"]]];

                NSString *hostID = nil;
                NSError *patchError = nil;
                BOOL ok = [self zs_patchIPAAtURL:ipaURL appexZipData:appexZipData outputURL:outputURL hostBundleID:&hostID error:&patchError];
                if (!ok) {
                    [fm removeItemAtPath:directory error:nil];
                    ZLog(@"[LiveContainerPatcher] patch failed: %@", patchError.localizedDescription);
                    finish(nil, nil, patchError ?: zs_patch_error(@"Unknown error."));
                    return;
                }

                ZLog(@"[LiveContainerPatcher] patched %@ (host bundle id %@, donor bundle id %@.ZSRamDonor)", ipaURL.lastPathComponent, hostID, hostID);
                finish(outputURL, hostID, nil);
            });
        });
    });
}

@end
