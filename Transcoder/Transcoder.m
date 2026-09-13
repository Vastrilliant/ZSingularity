#import "Transcoder.h"
#import "ZTweakLog.h"
#import "ZSEngine.h"
#import "UnityBundleTools.h"
#import "ModAssetManagement.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

#pragma mark - ZTranscoderService

NSString * const ZTranscoderServiceErrorDomain = @"ZTranscoderServiceErrorDomain";
NSString * const ZTranscoderServiceHTTPStatusKey = @"ZTranscoderServiceHTTPStatusKey";
NSString * const ZTranscoderServiceResponseBodyKey = @"ZTranscoderServiceResponseBodyKey";
NSString * const ZTranscoderServiceRunURLKey = @"ZTranscoderServiceRunURLKey";

static NSString * const kBDSInputAssetName = @"input.bundle";
static NSString * const kBDSOutputAssetName = @"output.bundle";

static NSString * const kBDSOriginalAssetName = @"original.bundle";
static NSString * const kBDSReleaseTagInputKey = @"release_tag";
static NSString * const kBDSInputFormatKey = @"output_format";

static NSString * const kBDSDefaultRef = @"main";
static NSString * const kBDSDefaultWorkflowFile = @"ztranscoder.yml";
static NSString * const kBDSDefaultOutputFormat = @"ASTC_RGBA_6x6";

static const NSTimeInterval kBDSRunDiscoveryTimeout = 30.0;
static const NSTimeInterval kBDSRunDiscoveryPollInterval = 2.0;
static const NSTimeInterval kBDSRunCompletionTimeout = 600.0;
static const NSTimeInterval kBDSRunCompletionPollInterval = 5.0;

static NSString * const kSettingsSection = @"transcoder";
static NSString * const kUploadCompressionEnabledKey = @"uploadCompressionEnabled";

static NSString *bds_compressionLabel(uint8_t type) {
    switch (type) {
        case 0: return @"none";
        case 1: return @"LZMA";
        case 2: return @"LZ4";
        case 3: return @"LZ4HC";
        case 4: return @"LZHAM";
        default: return [NSString stringWithFormat:@"type-%u", type];
    }
}

static NSString *bds_uniqueTagForCAB(NSString *cabIdentifier) {
    NSString *uuid = [NSUUID UUID].UUIDString;
    if (cabIdentifier.length == 0) {
        return [NSString stringWithFormat:@"bundle-doctor/%@", uuid];
    }
    NSString *cabHash = [cabIdentifier hasPrefix:@"CAB-"] ? [cabIdentifier substringFromIndex:4] : cabIdentifier;
    NSString *cabTrunc = [cabHash substringToIndex:MIN((NSUInteger)5, cabHash.length)];
    return [NSString stringWithFormat:@"bundle-doctor/CAB-%@-%@", cabTrunc, uuid];
}

static NSString *bds_cabDisplayNameFromTag(NSString *tagName) {
    NSRange cabRange = [tagName rangeOfString:@"CAB-"];
    if (cabRange.location == NSNotFound) return nil;
    NSString *fromCAB = [tagName substringFromIndex:cabRange.location];

    NSArray<NSString *> *components = [fromCAB componentsSeparatedByString:@"-"];
    if (components.count < 2) return fromCAB;
    return [NSString stringWithFormat:@"%@-%@", components[0], components[1]];
}

static NSData *bds_prepareBundleDataForUpload(NSData *data, unsigned long long *outCompressedByteSize, NSError **error) {
    if (outCompressedByteSize) *outCompressedByteSize = 0;
    if (data.length == 0) return data;

    if (![ZTranscoderService isUploadCompressionEnabled]) {
        ZLog(@"[ZTranscoderService] upload compression disabled via Config switch - uploading %lu bytes unchanged",
             (unsigned long)data.length);
        return data;
    }

    NSString *tmpName = [NSString stringWithFormat:@"bds-upload-%@.bundle", NSUUID.UUID.UUIDString];
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName];
    NSURL *tmpURL = [NSURL fileURLWithPath:tmpPath];

    NSError *writeError = nil;
    if (![data writeToURL:tmpURL options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = writeError;
        return nil;
    }

    NSError *compressionError = nil;
    uint8_t type = [UnityBundleCAB compressionTypeForBundleAtPath:tmpPath error:&compressionError];
    if (compressionError) {
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        if (error) *error = compressionError;
        return nil;
    }

    if (type != 0 && type != 2) {
        ZLog(@"[ZTranscoderService] upload compression: leaving %@ bundle unchanged (%lu bytes)",
             bds_compressionLabel(type), (unsigned long)data.length);
        [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
        return data;
    }

    ZLog(@"[ZTranscoderService] upload compression: source is %@ (%lu bytes), recompressing as LZ4HC…",
         bds_compressionLabel(type), (unsigned long)data.length);

    NSData *compressed = [UnityBundleCAB LZ4HCDataForBundleAtPath:tmpPath error:&compressionError];
    [NSFileManager.defaultManager removeItemAtPath:tmpPath error:nil];
    if (!compressed) {
        if (error) *error = compressionError ?: [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                                                       code:ZTranscoderServiceErrorRequestFailed
                                                                   userInfo:@{NSLocalizedDescriptionKey: @"Couldn't recompress the bundle as LZ4HC for upload."}];
        return nil;
    }

    ZLog(@"[ZTranscoderService] upload compression: %lu -> %lu bytes (%.1f%% of original)",
         (unsigned long)data.length,
         (unsigned long)compressed.length,
         data.length ? (100.0 * (double)compressed.length / (double)data.length) : 0.0);
    if (outCompressedByteSize) *outCompressedByteSize = compressed.length;
    return compressed;
}

#pragma mark - ZTranscoderConfig

@implementation ZTranscoderConfig

- (ZTranscoderConfig *)normalizedConfig {
    ZTranscoderConfig *copy = [ZTranscoderConfig new];
    copy.repoOwner = self.repoOwner;
    copy.repoName = self.repoName;
    copy.authToken = self.authToken;
    copy.ref = self.ref.length > 0 ? self.ref : kBDSDefaultRef;
    copy.workflowFile = self.workflowFile.length > 0 ? self.workflowFile : kBDSDefaultWorkflowFile;
    copy.outputFormat = self.outputFormat.length > 0 ? self.outputFormat : kBDSDefaultOutputFormat;
    return copy;
}

@end

#pragma mark - ZTranscoderHandle

@implementation ZTranscoderHandle {
    NSString *_scratchBranch;
    BOOL _alreadyComplete;
}

- (instancetype)initWithScratchBranch:(NSString *)scratchBranch {
    return [self initWithScratchBranch:scratchBranch alreadyComplete:NO];
}

- (instancetype)initWithScratchBranch:(NSString *)scratchBranch alreadyComplete:(BOOL)alreadyComplete {
    if ((self = [super init])) {
        _scratchBranch = [scratchBranch copy];
        _alreadyComplete = alreadyComplete;
    }
    return self;
}

- (NSString *)scratchBranch { return _scratchBranch; }
- (BOOL)alreadyComplete { return _alreadyComplete; }

- (NSDictionary<NSString *, NSString *> *)dictionaryRepresentation {
    NSMutableDictionary<NSString *, NSString *> *d = [NSMutableDictionary dictionary];
    d[@"scratchBranch"] = self.scratchBranch;
    if (self.runID) d[@"runID"] = self.runID;
    if (self.runURL) d[@"runURL"] = self.runURL;
    return d;
}

+ (nullable instancetype)handleFromDictionaryRepresentation:(NSDictionary<NSString *, NSString *> *)dict {
    NSString *branch = dict[@"scratchBranch"];
    if (![branch isKindOfClass:NSString.class] || branch.length == 0) return nil;
    ZTranscoderHandle *handle = [[ZTranscoderHandle alloc] initWithScratchBranch:branch];
    handle.runID = [dict[@"runID"] isKindOfClass:NSString.class] ? dict[@"runID"] : nil;
    handle.runURL = [dict[@"runURL"] isKindOfClass:NSString.class] ? dict[@"runURL"] : nil;
    return handle;
}

@end

#pragma mark - BDSUploadProgressDelegate

@interface BDSUploadProgressDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, copy, nullable) void (^onProgress)(int64_t bytesSent);
@end

@implementation BDSUploadProgressDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
    didSendBodyData:(int64_t)bytesSent
     totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    if (!self.onProgress) return;
    self.onProgress(totalBytesSent);
}

@end

#pragma mark - BDSDownloadProgressDelegate

@interface BDSDownloadProgressDelegate : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy, nullable) void (^onProgress)(int64_t bytesWritten, int64_t totalBytesExpected);
@property (nonatomic, assign) int64_t knownTotalBytesExpected;
@end

@implementation BDSDownloadProgressDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (!self.onProgress) return;
    int64_t total = self.knownTotalBytesExpected > 0 ? self.knownTotalBytesExpected : totalBytesExpectedToWrite;
    self.onProgress(totalBytesWritten, total);
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
}

@end

#pragma mark - ZTranscoderService

@interface ZTranscoderService ()
+ (nullable NSData *)bds_findOriginalBundleDataForModdedBundleAtPath:(NSString *)moddedBundlePath;
+ (nullable NSData *)bds_findOriginalGameFileDataForHash1:(NSString *)hash1 hash2:(NSString *)hash2;
+ (BOOL)bds_resolveBaseCommitSHA:(NSString **)outCommitSHA
                          config:(ZTranscoderConfig *)config
                           error:(NSError **)error;
+ (BOOL)bds_createBranch:(NSString *)branchName
              atCommitSHA:(NSString *)commitSHA
                   config:(ZTranscoderConfig *)config
                    error:(NSError **)error;
+ (BOOL)bds_errorIsAlreadyExists:(NSError *)error;
+ (void)bds_deleteBranch:(NSString *)branchName config:(ZTranscoderConfig *)config;
+ (BOOL)bds_createReleaseWithTagName:(NSString *)tagName
                       targetCommitish:(NSString *)targetCommitish
                                config:(ZTranscoderConfig *)config
                  outUploadURLTemplate:(NSString **)outUploadURLTemplate
                                 error:(NSError **)error;
+ (BOOL)bds_uploadReleaseAssetData:(NSData *)data
                                name:(NSString *)name
                   uploadURLTemplate:(NSString *)uploadURLTemplate
                            progress:(nullable void (^)(int64_t bytesSent))progress
                              config:(ZTranscoderConfig *)config
                               error:(NSError **)error;
+ (nullable NSDictionary *)bds_fetchReleaseByTag:(NSString *)tagName config:(ZTranscoderConfig *)config error:(NSError **)error;
+ (BOOL)bds_releaseAtTagHasOutputAsset:(NSString *)tagName config:(ZTranscoderConfig *)config;
+ (BOOL)bds_downloadReleaseAssetNamed:(NSString *)name
                       fromReleaseTag:(NSString *)releaseTag
                               config:(ZTranscoderConfig *)config
                             progress:(nullable void (^)(int64_t bytesWritten, int64_t totalBytesExpected))progress
                                 data:(NSData **)outData
                                error:(NSError **)error;
+ (void)bds_deleteReleaseWithTag:(NSString *)tagName config:(ZTranscoderConfig *)config;
+ (void)bds_cleanupScratchSubmission:(NSString *)scratchBranch config:(ZTranscoderConfig *)config;
+ (BOOL)bds_dispatchWorkflowOnBranch:(NSString *)branchName
                                config:(ZTranscoderConfig *)config
                                 error:(NSError **)error;
+ (BOOL)bds_findRunOnBranch:(NSString *)branchName
             dispatchedAfter:(NSDate *)dispatchedAt
                      config:(ZTranscoderConfig *)config
                       runID:(NSString **)outRunID
                      runURL:(NSString **)outRunURL
                       error:(NSError **)error;
+ (BOOL)bds_waitForRunCompletion:(NSString *)runID
                            runURL:(NSString *)runURL
                            config:(ZTranscoderConfig *)config
                             error:(NSError **)error;
+ (nullable NSMutableURLRequest *)bds_requestForAbsoluteURLString:(NSString *)urlString config:(ZTranscoderConfig *)config;
+ (nullable NSMutableURLRequest *)bds_requestForPath:(NSString *)path config:(ZTranscoderConfig *)config;
+ (nullable NSData *)bds_downloadBinaryAtAbsoluteURLString:(NSString *)urlString
                                                       config:(ZTranscoderConfig *)config
                                              knownTotalBytes:(int64_t)knownTotalBytes
                                                     progress:(nullable void (^)(int64_t bytesWritten, int64_t totalBytesExpected))progress
                                                        error:(NSError **)error;
+ (nullable id)bds_getJSON:(NSString *)path config:(ZTranscoderConfig *)config error:(NSError **)error;
+ (nullable id)bds_postJSON:(NSString *)path body:(NSDictionary *)body config:(ZTranscoderConfig *)config error:(NSError **)error;
+ (BOOL)bds_deleteJSON:(NSString *)path config:(ZTranscoderConfig *)config error:(NSError **)error;
+ (nullable id)bds_performJSONRequest:(NSURLRequest *)request expectBody:(BOOL)expectBody error:(NSError **)error;
+ (NSDateFormatter *)bds_iso8601Formatter;
+ (NSError *)bds_errorWithCode:(ZTranscoderServiceErrorCode)code description:(NSString *)description;
@end

#pragma mark - ZTranscoderProcessedRelease

@implementation ZTranscoderProcessedRelease {
    NSString *_tagName;
    NSString *_cabDisplayName;
    NSString *_displayName;
    unsigned long long _byteSize;
    NSString *_uploadedAt;
    NSString *_checksum;
}

- (instancetype)initWithTagName:(NSString *)tagName
                        byteSize:(unsigned long long)byteSize
                      uploadedAt:(nullable NSString *)uploadedAt
                        checksum:(nullable NSString *)checksum {
    if ((self = [super init])) {
        _tagName = [tagName copy] ?: @"";
        _cabDisplayName = bds_cabDisplayNameFromTag(_tagName);
        _displayName = _cabDisplayName.length > 0 ? _cabDisplayName : _tagName;
        _byteSize = byteSize;
        _uploadedAt = [uploadedAt copy];
        _checksum = [checksum copy];
    }
    return self;
}

- (NSString *)tagName { return _tagName; }
- (NSString *)cabDisplayName { return _cabDisplayName; }
- (NSString *)displayName { return _displayName; }
- (unsigned long long)byteSize { return _byteSize; }
- (NSString *)uploadedAt { return _uploadedAt; }
- (NSString *)checksum { return _checksum; }

@end

#pragma mark - ZTranscoderService

@implementation ZTranscoderService

+ (BOOL)isUploadCompressionEnabled {
    NSDictionary *section = zs_settings_section(kSettingsSection);
    id stored = section[kUploadCompressionEnabledKey];

    return stored ? [stored boolValue] : NO;
}

+ (void)setUploadCompressionEnabled:(BOOL)enabled {
    NSMutableDictionary *section = [zs_settings_section(kSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kUploadCompressionEnabledKey] = @(enabled);
    zs_write_settings_section(kSettingsSection, section);
    ZLog(@"[ZTranscoderService] upload compression %@ via Config switch", enabled ? @"enabled" : @"disabled");
}

#pragma mark Public entry point

+ (void)ztranscoderBundleAtURL:(NSURL *)moddedBundleURL
                    config:(ZTranscoderConfig *)rawConfig
                  progress:(void (^)(NSString *status))progress
                completion:(void (^)(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error))completion {
    void (^report)(NSString *) = ^(NSString *status) {
        if (!progress) return;
        dispatch_async(dispatch_get_main_queue(), ^{ progress(status); });
    };
    void (^finish)(NSURL * _Nullable, NSError * _Nullable) = ^(NSURL * _Nullable url, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url, error); });
    };

    ZTranscoderConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorInvalidConfig
                                 description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;

        BOOL scoped = [moddedBundleURL startAccessingSecurityScopedResource];
        NSData *moddedData = [NSData dataWithContentsOfURL:moddedBundleURL options:0 error:&error];
        if (scoped) [moddedBundleURL stopAccessingSecurityScopedResource];
        if (!moddedData) {
            finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorCantReadModdedBundle
                                     description:error.localizedDescription ?: @"Couldn't read the modded bundle."]);
            return;
        }

        NSData *uploadData = bds_prepareBundleDataForUpload(moddedData, NULL, &error);
        if (!uploadData) {
            finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed
                                     description:error.localizedDescription ?: @"Couldn't prepare the bundle for upload."]);
            return;
        }

        NSString *scratchBranch = [NSString stringWithFormat:@"bundle-doctor/%@", [NSUUID UUID].UUIDString];
        ZLog(@"[ZTranscoderService] starting run on %@/%@, scratch branch %@",
              config.repoOwner, config.repoName, scratchBranch);

        report(@"Reading base branch\u2026");
        NSString *baseCommitSHA = nil;
        if (![self bds_resolveBaseCommitSHA:&baseCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        if (![self bds_createBranch:scratchBranch atCommitSHA:baseCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        report(@"Creating queue release\u2026");
        NSString *uploadURLTemplate = nil;
        if (![self bds_createReleaseWithTagName:scratchBranch targetCommitish:scratchBranch
                                          config:config outUploadURLTemplate:&uploadURLTemplate error:&error]) {
            [self bds_deleteBranch:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Uploading modded bundle\u2026");
        if (![self bds_uploadReleaseAssetData:uploadData name:kBDSInputAssetName
                             uploadURLTemplate:uploadURLTemplate progress:nil
                                        config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Triggering ztranscoder workflow\u2026");
        NSDate *dispatchedAt = [NSDate date];
        if (![self bds_dispatchWorkflowOnBranch:scratchBranch config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Waiting for the run to start\u2026");
        NSString *runID = nil;
        NSString *runURL = nil;
        if (![self bds_findRunOnBranch:scratchBranch dispatchedAfter:dispatchedAt config:config
                                  runID:&runID runURL:&runURL error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Waiting for the workflow to finish\u2026");
        if (![self bds_waitForRunCompletion:runID runURL:runURL config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Downloading doctored bundle\u2026");
        NSData *doctoredData = nil;
        if (![self bds_downloadReleaseAssetNamed:kBDSOutputAssetName fromReleaseTag:scratchBranch
                                           config:config progress:nil data:&doctoredData error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        report(@"Cleaning up\u2026");
        [self bds_cleanupScratchSubmission:scratchBranch config:config];

        NSString *tempName = [NSString stringWithFormat:@"doctored-%@.bundle", [NSUUID UUID].UUIDString];
        NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
        NSError *writeError = nil;
        if (![doctoredData writeToURL:tempURL options:NSDataWritingAtomic error:&writeError]) {
            finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed
                                     description:writeError.localizedDescription ?: @"Couldn't write doctored bundle to a temp file."]);
            return;
        }

        ZLog(@"[ZTranscoderService] doctored bundle ready at %@ (%lu bytes)",
              tempURL.path, (unsigned long)doctoredData.length);

        finish(tempURL, nil);
    });
}

#pragma mark - Decoupled phase API (see this file's header)

+ (nullable NSData *)bds_findOriginalBundleDataForModdedBundleAtPath:(NSString *)moddedBundlePath {
    NSError *cabError = nil;
    NSString *cab = [UnityCacheLocator cabForBundleAtPath:moddedBundlePath error:&cabError];
    if (!cab) {
        ZLog(@"[ZTranscoderService] shader-restore: couldn't read a CAB off the modded bundle (%@) - skipping.", cabError.localizedDescription);
        return nil;
    }

    NSError *locateError = nil;
    NSString *originalPath = [UnityCacheLocator locateBundlePathForCAB:cab error:&locateError];
    if (!originalPath) {
        ZLog(@"[ZTranscoderService] shader-restore: no cached original found for CAB %@ (%@) - skipping.", cab, locateError.localizedDescription);
        return nil;
    }

    NSError *readError = nil;
    NSData *originalData = [NSData dataWithContentsOfFile:originalPath options:0 error:&readError];
    if (!originalData) {

        ZLog(@"[ZTranscoderService] shader-restore: resolved original at %@ but couldn't read it (%@) - skipping.", originalPath, readError.localizedDescription);
        return nil;
    }

    ZLog(@"[ZTranscoderService] shader-restore: matched CAB %@ -> %@ (%lu bytes).", cab, originalPath, (unsigned long)originalData.length);
    return originalData;
}

+ (nullable NSData *)bds_findOriginalGameFileDataForHash1:(NSString *)hash1 hash2:(NSString *)hash2 {
    NSError *locateError = nil;
    NSString *originalPath = [UnityCacheLocator locateGameFilePathForHash1:hash1 hash2:hash2 error:&locateError];
    if (!originalPath) {
        ZLog(@"[ZTranscoderService] Carra2 dispatch: no matching game file found for hash %@/%@ (%@) - skipping original upload.",
             hash1, hash2, locateError.localizedDescription);
        return nil;
    }

    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:originalPath isDirectory:&isDir] || isDir) {
        ZLog(@"[ZTranscoderService] Carra2 dispatch: resolved target %@ isn't a regular file - skipping original upload.", originalPath);
        return nil;
    }

    NSError *readError = nil;
    NSData *originalData = [NSData dataWithContentsOfFile:originalPath options:0 error:&readError];
    if (!originalData) {
        ZLog(@"[ZTranscoderService] Carra2 dispatch: resolved target at %@ but couldn't read it (%@) - skipping.",
             originalPath, readError.localizedDescription);
        return nil;
    }

    ZLog(@"[ZTranscoderService] Carra2 dispatch: matched hash %@/%@ -> %@ (%lu bytes).",
         hash1, hash2, originalPath, (unsigned long)originalData.length);
    return originalData;
}

+ (void)dispatchBundleAtURL:(NSURL *)moddedBundleURL
                  carra2Hash1:(nullable NSString *)carra2Hash1
                  carra2Hash2:(nullable NSString *)carra2Hash2
                       config:(ZTranscoderConfig *)rawConfig
        previousScratchBranch:(nullable NSString *)previousScratchBranch
               uploadProgress:(void (^)(int64_t, int64_t))uploadProgress
                   completion:(void (^)(ZTranscoderHandle * _Nullable, NSError * _Nullable))completion {
    BOOL isCarra2 = carra2Hash1.length > 0 && carra2Hash2.length > 0;
    __block int64_t totalBytesToSend = 0;
    void (^reportProgress)(int64_t) = ^(int64_t bytesSent) {
        if (!uploadProgress) return;
        int64_t total = totalBytesToSend;
        dispatch_async(dispatch_get_main_queue(), ^{ uploadProgress(bytesSent, total); });
    };
    void (^finish)(ZTranscoderHandle * _Nullable, NSError * _Nullable) = ^(ZTranscoderHandle * _Nullable handle, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(handle, error); });
    };

    ZTranscoderConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorInvalidConfig
                                 description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;

        BOOL scoped = [moddedBundleURL startAccessingSecurityScopedResource];
        NSData *moddedData = [NSData dataWithContentsOfURL:moddedBundleURL options:0 error:&error];
        if (scoped) [moddedBundleURL stopAccessingSecurityScopedResource];
        if (!moddedData) {
            finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorCantReadModdedBundle
                                     description:error.localizedDescription ?: @"Couldn't read the modded bundle."]);
            return;
        }

        unsigned long long compressedByteSize = 0;
        NSData *uploadData = moddedData;
        if (!isCarra2) {
            uploadData = bds_prepareBundleDataForUpload(moddedData, &compressedByteSize, &error);
            if (!uploadData) {
                finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed
                                         description:error.localizedDescription ?: @"Couldn't prepare the bundle for upload."]);
                return;
            }
        } else {
            ZLog(@"[ZTranscoderService] %@ is a Carra2 mod file - leaving its bytes untouched for upload (LZ4HC recompression skipped).",
                 moddedBundleURL.lastPathComponent);
        }

        NSData *originalData = isCarra2
            ? [self bds_findOriginalGameFileDataForHash1:carra2Hash1 hash2:carra2Hash2]
            : [self bds_findOriginalBundleDataForModdedBundleAtPath:moddedBundleURL.path];

        NSString *cabIdentifier = nil;
        if (!isCarra2) {
            NSError *cabError = nil;
            cabIdentifier = [UnityBundleCAB primaryCABForBundleAtPath:moddedBundleURL.path error:&cabError];
            if (!cabIdentifier) {
                ZLog(@"[ZTranscoderService] couldn't resolve a CAB identifier for %@ (%@) - tag will just be a bare UUID.",
                     moddedBundleURL.path.lastPathComponent, cabError.localizedDescription);
            }
        }

        if (previousScratchBranch.length > 0 && [self bds_releaseAtTagHasOutputAsset:previousScratchBranch config:config]) {
            ZLog(@"[ZTranscoderService] resume hit on %@ - this entry's earlier submission already finished, skipping upload/dispatch.", previousScratchBranch);
            ZTranscoderHandle *cachedHandle = [[ZTranscoderHandle alloc] initWithScratchBranch:previousScratchBranch alreadyComplete:YES];
            cachedHandle.compressedByteSize = compressedByteSize;
            finish(cachedHandle, nil);
            return;
        }

        NSString *scratchBranch = bds_uniqueTagForCAB(cabIdentifier);
        ZLog(@"[ZTranscoderService] dispatching %@/%@, scratch branch %@ (original bundle for shader-restore: %@)",
              config.repoOwner, config.repoName, scratchBranch, originalData ? @"found" : @"not found");

        NSString *baseCommitSHA = nil;
        if (![self bds_resolveBaseCommitSHA:&baseCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        if (![self bds_createBranch:scratchBranch atCommitSHA:baseCommitSHA config:config error:&error]) {
            finish(nil, error);
            return;
        }

        NSString *uploadURLTemplate = nil;
        if (![self bds_createReleaseWithTagName:scratchBranch targetCommitish:scratchBranch
                                          config:config outUploadURLTemplate:&uploadURLTemplate error:&error]) {
            [self bds_deleteBranch:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        unsigned long long moddedBytes = uploadData.length;
        unsigned long long originalBytes = originalData.length;
        totalBytesToSend = (int64_t)(moddedBytes + originalBytes);
        void (^reportModdedProgress)(int64_t) = ^(int64_t bytesSent) {
            reportProgress(bytesSent);
        };
        void (^reportOriginalProgress)(int64_t) = ^(int64_t bytesSent) {
            reportProgress((int64_t)moddedBytes + bytesSent);
        };

        if (![self bds_uploadReleaseAssetData:uploadData name:kBDSInputAssetName
                             uploadURLTemplate:uploadURLTemplate progress:reportModdedProgress
                                        config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }
        if (!originalData) reportProgress((int64_t)moddedBytes);

        if (originalData) {
            NSError *originalUploadError = nil;
            if (![self bds_uploadReleaseAssetData:originalData name:kBDSOriginalAssetName
                                 uploadURLTemplate:uploadURLTemplate progress:reportOriginalProgress
                                            config:config error:&originalUploadError]) {
                ZLog(@"[ZTranscoderService] couldn't upload original.bundle (proceeding without shader-restore): %@",
                     originalUploadError.localizedDescription);
            }
            reportProgress((int64_t)(moddedBytes + originalBytes));
        }

        if (![self bds_dispatchWorkflowOnBranch:scratchBranch config:config error:&error]) {
            [self bds_cleanupScratchSubmission:scratchBranch config:config];
            finish(nil, error);
            return;
        }

        ZTranscoderHandle *handle = [[ZTranscoderHandle alloc] initWithScratchBranch:scratchBranch];
        handle.compressedByteSize = compressedByteSize;
        finish(handle, nil);
    });
}

+ (void)resolveRunForHandle:(ZTranscoderHandle *)handle
                       config:(ZTranscoderConfig *)rawConfig
                   completion:(void (^)(BOOL, NSError * _Nullable))completion {
    void (^finish)(BOOL, NSError * _Nullable) = ^(BOOL found, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(found, error); });
    };

    ZTranscoderConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(NO, [self bds_errorWithCode:ZTranscoderServiceErrorInvalidConfig
                                description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/workflows/%@/runs?branch=%@&event=workflow_dispatch&per_page=10",
                              config.repoOwner, config.repoName, config.workflowFile,
                              [handle.scratchBranch stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

        NSError *error = nil;
        id result = [self bds_getJSON:urlPath config:config error:&error];
        if (!result) {
            finish(NO, error);
            return;
        }

        NSArray *runs = result[@"workflow_runs"];
        if ([runs isKindOfClass:NSArray.class] && runs.count > 0) {

            NSDictionary *best = nil;
            NSDate *bestDate = nil;
            NSDateFormatter *iso = [self bds_iso8601Formatter];
            for (NSDictionary *run in runs) {
                if (![run isKindOfClass:NSDictionary.class]) continue;
                NSDate *createdAt = [iso dateFromString:run[@"created_at"] ?: @""];
                if (!best || (createdAt && (!bestDate || [createdAt compare:bestDate] == NSOrderedDescending))) {
                    best = run;
                    bestDate = createdAt;
                }
            }
            if (best) {
                handle.runID = [best[@"id"] stringValue];
                handle.runURL = best[@"html_url"];
                ZLog(@"[ZTranscoderService] resolved run id %@ for scratch branch %@", handle.runID, handle.scratchBranch);
                finish(YES, nil);
                return;
            }
        }

        finish(NO, nil);
    });
}

+ (void)fetchRunStatusForHandle:(ZTranscoderHandle *)handle
                           config:(ZTranscoderConfig *)rawConfig
                       completion:(void (^)(ZTranscoderRunStatus, double, NSError * _Nullable))completion {
    void (^finish)(ZTranscoderRunStatus, double, NSError * _Nullable) = ^(ZTranscoderRunStatus status, double percent, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(status, percent, error); });
    };

    ZTranscoderConfig *config = [rawConfig normalizedConfig];
    if (handle.runID.length == 0) {
        finish(ZTranscoderRunStatusQueued, 0.0, [self bds_errorWithCode:ZTranscoderServiceErrorRunNotFound
                                                              description:@"No run id on this handle yet - call +resolveRunForHandle:config:completion: first."]);
        return;
    }
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(ZTranscoderRunStatusQueued, 0.0, [self bds_errorWithCode:ZTranscoderServiceErrorInvalidConfig
                                                              description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *runPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/runs/%@", config.repoOwner, config.repoName, handle.runID];
        NSError *error = nil;
        id run = [self bds_getJSON:runPath config:config error:&error];
        if (!run) {
            finish(ZTranscoderRunStatusQueued, 0.0, error);
            return;
        }

        NSString *runStatus = run[@"status"];
        if ([runStatus isEqualToString:@"completed"]) {
            NSString *conclusion = run[@"conclusion"];
            if ([conclusion isEqualToString:@"success"]) {
                ZLog(@"[ZTranscoderService] run %@ completed successfully", handle.runID);
                finish(ZTranscoderRunStatusSucceeded, 1.0, nil);
            } else {
                ZLog(@"[ZTranscoderService] run %@ finished with conclusion \"%@\"", handle.runID, conclusion ?: @"unknown");
                NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
                userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"Workflow run finished with conclusion \"%@\".", conclusion ?: @"unknown"];
                if (handle.runURL) userInfo[ZTranscoderServiceRunURLKey] = handle.runURL;
                NSError *runError = [NSError errorWithDomain:ZTranscoderServiceErrorDomain code:ZTranscoderServiceErrorRunFailed userInfo:userInfo];
                finish(ZTranscoderRunStatusFailed, 0.0, runError);
            }
            return;
        }

        NSString *jobsPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/runs/%@/jobs", config.repoOwner, config.repoName, handle.runID];
        id jobsResult = [self bds_getJSON:jobsPath config:config error:nil];
        double percent = 0.0;
        NSArray *jobs = [jobsResult isKindOfClass:NSDictionary.class] ? jobsResult[@"jobs"] : nil;
        if ([jobs isKindOfClass:NSArray.class]) {
            NSInteger totalSteps = 0, completedSteps = 0;
            for (NSDictionary *job in jobs) {
                if (![job isKindOfClass:NSDictionary.class]) continue;
                NSArray *steps = job[@"steps"];
                if (![steps isKindOfClass:NSArray.class]) continue;
                for (NSDictionary *step in steps) {
                    if (![step isKindOfClass:NSDictionary.class]) continue;
                    totalSteps++;
                    if ([step[@"status"] isEqualToString:@"completed"]) completedSteps++;
                }
            }
            if (totalSteps > 0) percent = (double)completedSteps / (double)totalSteps;
        }

        ZTranscoderRunStatus status = percent > 0.0 ? ZTranscoderRunStatusInProgress : ZTranscoderRunStatusQueued;
        finish(status, percent, nil);
    });
}

+ (void)fetchDoctoredBundleForHandle:(ZTranscoderHandle *)handle
                                config:(ZTranscoderConfig *)rawConfig
                              progress:(nullable void (^)(int64_t bytesWritten, int64_t totalBytesExpected))downloadProgress
                            completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    void (^reportProgress)(int64_t, int64_t) = ^(int64_t bytesWritten, int64_t totalBytesExpected) {
        if (!downloadProgress) return;
        dispatch_async(dispatch_get_main_queue(), ^{ downloadProgress(bytesWritten, totalBytesExpected); });
    };
    void (^finish)(NSURL * _Nullable, NSError * _Nullable) = ^(NSURL * _Nullable url, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url, error); });
    };

    ZTranscoderConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorInvalidConfig
                                 description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *doctoredData = nil;
        if (![self bds_downloadReleaseAssetNamed:kBDSOutputAssetName fromReleaseTag:handle.scratchBranch
                                           config:config progress:reportProgress data:&doctoredData error:&error]) {
            finish(nil, error);
            return;
        }
        reportProgress((int64_t)doctoredData.length, (int64_t)doctoredData.length);

        [self bds_cleanupScratchSubmission:handle.scratchBranch config:config];

        NSString *tempName = [NSString stringWithFormat:@"doctored-%@.bundle", [NSUUID UUID].UUIDString];
        NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
        NSError *writeError = nil;
        if (![doctoredData writeToURL:tempURL options:NSDataWritingAtomic error:&writeError]) {
            finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed
                                     description:writeError.localizedDescription ?: @"Couldn't write doctored bundle to a temp file."]);
            return;
        }

        ZLog(@"[ZTranscoderService] doctored bundle ready at %@ (%lu bytes)", tempURL.path, (unsigned long)doctoredData.length);

        finish(tempURL, nil);
    });
}

#pragma mark - Credential check

+ (void)verifyCredentialsForConfig:(ZTranscoderConfig *)rawConfig
                          completion:(void (^)(BOOL, NSError * _Nullable))completion {
    void (^finish)(BOOL, NSError * _Nullable) = ^(BOOL valid, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(valid, error); });
    };

    ZTranscoderConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(NO, [self bds_errorWithCode:ZTranscoderServiceErrorInvalidConfig
                                description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        NSString *path = [NSString stringWithFormat:@"/repos/%@/%@", config.repoOwner, config.repoName];
        NSError *error = nil;
        id repo = [self bds_getJSON:path config:config error:&error];
        ZLog(@"[ZTranscoderService] credential verification against %@/%@: %@", config.repoOwner, config.repoName, repo != nil ? @"OK" : @"FAILED");
        finish(repo != nil, error);
    });
}

#pragma mark - Processed Bundles listing (6)

+ (void)listProcessedReleasesForConfig:(ZTranscoderConfig *)rawConfig
                              completion:(void (^)(NSArray<ZTranscoderProcessedRelease *> * _Nullable, NSError * _Nullable))completion {
    void (^finish)(NSArray<ZTranscoderProcessedRelease *> * _Nullable, NSError * _Nullable) =
        ^(NSArray<ZTranscoderProcessedRelease *> *releases, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(releases, error); });
    };

    ZTranscoderConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorInvalidConfig
                                description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        static const NSInteger kPerPage = 100;
        NSMutableArray<ZTranscoderProcessedRelease *> *results = [NSMutableArray array];
        NSInteger page = 1;
        for (;;) {
            NSString *path = [NSString stringWithFormat:@"/repos/%@/%@/releases?per_page=%ld&page=%ld",
                               config.repoOwner, config.repoName, (long)kPerPage, (long)page];
            NSError *error = nil;
            id result = [self bds_getJSON:path config:config error:&error];
            if (!result) {
                finish(nil, error);
                return;
            }
            NSArray *pageReleases = [result isKindOfClass:NSArray.class] ? result : @[];
            for (NSDictionary *release in pageReleases) {
                if (![release isKindOfClass:NSDictionary.class]) continue;
                NSArray *assets = release[@"assets"];
                if (![assets isKindOfClass:NSArray.class]) continue;

                NSDictionary *outputAsset = nil;
                for (NSDictionary *asset in assets) {
                    if ([asset isKindOfClass:NSDictionary.class] && [asset[@"name"] isEqual:kBDSOutputAssetName]) {
                        outputAsset = asset;
                        break;
                    }
                }

                if (!outputAsset) continue;

                NSString *tagName = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : @"";
                id sizeValue = outputAsset[@"size"];
                unsigned long long size = [sizeValue respondsToSelector:@selector(unsignedLongLongValue)] ? [sizeValue unsignedLongLongValue] : 0;
                NSString *uploadedAt = [outputAsset[@"created_at"] isKindOfClass:NSString.class] ? outputAsset[@"created_at"] : nil;
                NSString *digest = [outputAsset[@"digest"] isKindOfClass:NSString.class] ? outputAsset[@"digest"] : nil;

                [results addObject:[[ZTranscoderProcessedRelease alloc] initWithTagName:tagName
                                                                                  byteSize:size
                                                                                uploadedAt:uploadedAt
                                                                                  checksum:digest]];
            }
            if (pageReleases.count < kPerPage) break;
            page++;
        }

        [results sortUsingComparator:^NSComparisonResult(ZTranscoderProcessedRelease *a, ZTranscoderProcessedRelease *b) {

            if (!a.uploadedAt && !b.uploadedAt) return NSOrderedSame;
            if (!a.uploadedAt) return NSOrderedDescending;
            if (!b.uploadedAt) return NSOrderedAscending;
            return [b.uploadedAt compare:a.uploadedAt];
        }];

        ZLog(@"[ZTranscoderService] listed %lu processed release(s) for %@/%@", (unsigned long)results.count, config.repoOwner, config.repoName);
        finish(results, nil);
    });
}

#pragma mark - Processed Bundles install (9)

+ (void)downloadProcessedRelease:(ZTranscoderProcessedRelease *)release
                            config:(ZTranscoderConfig *)rawConfig
                          progress:(nullable void (^)(int64_t bytesWritten, int64_t totalBytesExpected))downloadProgress
                        completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    void (^reportProgress)(int64_t, int64_t) = ^(int64_t bytesWritten, int64_t totalBytesExpected) {
        if (!downloadProgress) return;
        int64_t total = totalBytesExpected > 0 ? totalBytesExpected : (int64_t)release.byteSize;
        dispatch_async(dispatch_get_main_queue(), ^{ downloadProgress(bytesWritten, total); });
    };
    void (^finish)(NSURL * _Nullable, NSError * _Nullable) = ^(NSURL * _Nullable url, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url, error); });
    };

    ZTranscoderConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorInvalidConfig
                                 description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *bundleData = nil;
        if (![self bds_downloadReleaseAssetNamed:kBDSOutputAssetName fromReleaseTag:release.tagName
                                           config:config progress:reportProgress data:&bundleData error:&error]) {
            finish(nil, error);
            return;
        }
        reportProgress((int64_t)bundleData.length, (int64_t)bundleData.length);

        NSString *tempName = [NSString stringWithFormat:@"processed-%@.bundle", [NSUUID UUID].UUIDString];
        NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
        NSError *writeError = nil;
        if (![bundleData writeToURL:tempURL options:NSDataWritingAtomic error:&writeError]) {
            finish(nil, [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed
                                     description:writeError.localizedDescription ?: @"Couldn't write the processed bundle to a temp file."]);
            return;
        }

        ZLog(@"[ZTranscoderService] processed release %@ downloaded to %@ (%lu bytes)", release.tagName, tempURL.path, (unsigned long)bundleData.length);

        finish(tempURL, nil);
    });
}

#pragma mark - Delete every stored release (8)

+ (void)deleteAllReleasesForConfig:(ZTranscoderConfig *)rawConfig
                          completion:(void (^)(NSInteger deletedCount, NSError * _Nullable error))completion {
    void (^finish)(NSInteger, NSError * _Nullable) = ^(NSInteger deletedCount, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(deletedCount, error); });
    };

    ZTranscoderConfig *config = [rawConfig normalizedConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        finish(0, [self bds_errorWithCode:ZTranscoderServiceErrorInvalidConfig
                                description:@"Set a GitHub repository link and Personal Access Token under Mods \u2192 Auth first."]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        static const NSInteger kPerPage = 100;
        NSMutableArray<NSDictionary *> *allReleases = [NSMutableArray array];
        NSInteger page = 1;
        for (;;) {
            NSString *path = [NSString stringWithFormat:@"/repos/%@/%@/releases?per_page=%ld&page=%ld",
                               config.repoOwner, config.repoName, (long)kPerPage, (long)page];
            NSError *error = nil;
            id result = [self bds_getJSON:path config:config error:&error];
            if (!result) {
                finish(0, error);
                return;
            }
            NSArray *pageReleases = [result isKindOfClass:NSArray.class] ? result : @[];
            for (NSDictionary *release in pageReleases) {
                if ([release isKindOfClass:NSDictionary.class]) [allReleases addObject:release];
            }
            if (pageReleases.count < kPerPage) break;
            page++;
        }

        NSInteger deletedCount = 0;
        for (NSDictionary *release in allReleases) {
            NSString *releaseID = [release[@"id"] stringValue];
            NSString *tagName = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : nil;

            if (releaseID.length > 0) {
                NSString *deletePath = [NSString stringWithFormat:@"/repos/%@/%@/releases/%@",
                                         config.repoOwner, config.repoName, releaseID];
                NSError *deleteError = nil;
                if ([self bds_deleteJSON:deletePath config:config error:&deleteError]) {
                    deletedCount++;
                } else {
                    ZLog(@"[ZTranscoderService] couldn't delete release %@ (tag %@) while clearing the proxy: %@", releaseID, tagName, deleteError);
                }
            }

            if (tagName.length > 0) {
                NSString *escapedTag = [tagName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
                NSString *tagRefPath = [NSString stringWithFormat:@"/repos/%@/%@/git/refs/tags/%@",
                                         config.repoOwner, config.repoName, escapedTag];
                NSError *tagDeleteError = nil;
                if (![self bds_deleteJSON:tagRefPath config:config error:&tagDeleteError]) {
                    ZLog(@"[ZTranscoderService] couldn't delete release tag ref %@ while clearing the proxy: %@", tagName, tagDeleteError);
                }
            }
        }

        ZLog(@"[ZTranscoderService] deleted %ld of %lu release(s) for %@/%@", (long)deletedCount, (unsigned long)allReleases.count, config.repoOwner, config.repoName);
        finish(deletedCount, nil);
    });
}

#pragma mark - Git Data API steps

+ (BOOL)bds_resolveBaseCommitSHA:(NSString **)outCommitSHA
                          config:(ZTranscoderConfig *)config
                           error:(NSError **)error {
    NSString *path = [NSString stringWithFormat:@"/repos/%@/%@/git/ref/heads/%@",
                       config.repoOwner, config.repoName, config.ref];
    id ref = [self bds_getJSON:path config:config error:error];
    if (!ref) return NO;

    NSString *commitSHA = [ref valueForKeyPath:@"object.sha"];
    if (![commitSHA isKindOfClass:[NSString class]]) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorAPIError
                                         description:@"Unexpected response resolving the base branch ref."];
        return NO;
    }

    if (outCommitSHA) *outCommitSHA = commitSHA;
    return YES;
}

+ (BOOL)bds_createBranch:(NSString *)branchName
              atCommitSHA:(NSString *)commitSHA
                   config:(ZTranscoderConfig *)config
                    error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/git/refs", config.repoOwner, config.repoName];
    NSDictionary *body = @{
        @"ref": [NSString stringWithFormat:@"refs/heads/%@", branchName],
        @"sha": commitSHA,
    };
    NSError *createError = nil;
    if ([self bds_postJSON:urlPath body:body config:config error:&createError] != nil) return YES;

    if ([self bds_errorIsAlreadyExists:createError]) {
        ZLog(@"[ZTranscoderService] scratch branch %@ already exists (racing/leftover submission for the same bundle) - reusing it.", branchName);
        return YES;
    }
    if (error) *error = createError;
    return NO;
}

+ (BOOL)bds_errorIsAlreadyExists:(NSError *)error {
    if (![error.domain isEqualToString:ZTranscoderServiceErrorDomain]) return NO;
    if (error.code != ZTranscoderServiceErrorAPIError) return NO;
    if (![error.userInfo[ZTranscoderServiceHTTPStatusKey] isEqual:@422]) return NO;
    NSString *body = error.userInfo[ZTranscoderServiceResponseBodyKey];
    return [body rangeOfString:@"already exists" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

+ (void)bds_deleteBranch:(NSString *)branchName config:(ZTranscoderConfig *)config {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/git/refs/heads/%@",
                          config.repoOwner, config.repoName, branchName];
    NSError *deleteError = nil;
    if (![self bds_deleteJSON:urlPath config:config error:&deleteError]) {

        ZLog(@"[ZTranscoderService] couldn't delete scratch branch %@: %@", branchName, deleteError);
    }
}

#pragma mark - Releases API steps (input/output transport)

+ (BOOL)bds_createReleaseWithTagName:(NSString *)tagName
                       targetCommitish:(NSString *)targetCommitish
                                config:(ZTranscoderConfig *)config
                  outUploadURLTemplate:(NSString **)outUploadURLTemplate
                                 error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/releases", config.repoOwner, config.repoName];
    NSDictionary *body = @{
        @"tag_name": tagName,
        @"target_commitish": targetCommitish,
        @"name": tagName,
        @"body": @"Scratch release for the ZTranscoder pipeline - holds one submission's input/output bundle assets. Safe to delete; +bds_cleanupScratchSubmission:config: removes it once the doctored bundle has been read back.",

        @"draft": @NO,
        @"prerelease": @YES,
    };
    NSError *createError = nil;
    id result = [self bds_postJSON:urlPath body:body config:config error:&createError];
    if (!result) {

        if ([self bds_errorIsAlreadyExists:createError]) {
            ZLog(@"[ZTranscoderService] release tagged %@ already exists (racing/leftover submission for the same bundle) - reusing it.", tagName);
            NSError *lookupError = nil;
            NSDictionary *existing = [self bds_fetchReleaseByTag:tagName config:config error:&lookupError];
            NSString *existingUploadURLTemplate = existing[@"upload_url"];
            if ([existingUploadURLTemplate isKindOfClass:NSString.class]) {
                if (outUploadURLTemplate) *outUploadURLTemplate = existingUploadURLTemplate;
                return YES;
            }
            if (error) *error = lookupError ?: [self bds_errorWithCode:ZTranscoderServiceErrorAPIError description:@"Existing release had no upload_url."];
            return NO;
        }
        if (error) *error = createError;
        return NO;
    }

    NSString *uploadURLTemplate = result[@"upload_url"];
    if (![uploadURLTemplate isKindOfClass:NSString.class]) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorAPIError description:@"Release creation didn't return an upload_url."];
        return NO;
    }
    if (outUploadURLTemplate) *outUploadURLTemplate = uploadURLTemplate;
    return YES;
}

+ (BOOL)bds_uploadReleaseAssetData:(NSData *)data
                                name:(NSString *)name
                   uploadURLTemplate:(NSString *)uploadURLTemplate
                            progress:(nullable void (^)(int64_t bytesSent))progress
                              config:(ZTranscoderConfig *)config
                               error:(NSError **)error {
    NSRange templateStart = [uploadURLTemplate rangeOfString:@"{"];
    NSString *baseURLString = templateStart.location == NSNotFound ? uploadURLTemplate
                                                                    : [uploadURLTemplate substringToIndex:templateStart.location];
    NSString *escapedName = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"%@?name=%@", baseURLString, escapedName];

    NSMutableURLRequest *request = [self bds_requestForAbsoluteURLString:urlString config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed description:@"Couldn't build the release asset upload URL."];
        return NO;
    }
    request.HTTPMethod = @"POST";
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];

    BDSUploadProgressDelegate *delegate = [BDSUploadProgressDelegate new];
    delegate.onProgress = progress;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                             delegate:delegate
                                                        delegateQueue:nil];

    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSError *transportError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionUploadTask *task = [session uploadTaskWithRequest:request fromData:data
                                                  completionHandler:^(NSData *taskData, NSURLResponse *taskResponse, NSError *taskError) {

        responseData = taskData;
        httpResponse = [taskResponse isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)taskResponse : nil;
        transportError = taskError;
        dispatch_semaphore_signal(sema);
    }];
    [task resume];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];

    if (transportError) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                          code:ZTranscoderServiceErrorRequestFailed
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: transportError.localizedDescription ?: @"Network request failed.",
                                          NSUnderlyingErrorKey: transportError,
                                      }];
        }
        return NO;
    }

    NSInteger status = httpResponse.statusCode;
    if (status < 200 || status >= 300) {
        NSString *bodyString = responseData ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"";
        if (bodyString.length > 500) bodyString = [bodyString substringToIndex:500];
        ZLog(@"[ZTranscoderService] POST %@ -> %ld: %@", urlString, (long)status, bodyString);
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                          code:ZTranscoderServiceErrorAPIError
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"GitHub API returned %ld.", (long)status],
                                          ZTranscoderServiceHTTPStatusKey: @(status),
                                          ZTranscoderServiceResponseBodyKey: bodyString,
                                      }];
        }
        return NO;
    }

    return YES;
}

+ (nullable NSDictionary *)bds_fetchReleaseByTag:(NSString *)tagName config:(ZTranscoderConfig *)config error:(NSError **)error {
    NSString *escapedTag = [tagName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/releases/tags/%@", config.repoOwner, config.repoName, escapedTag];
    id result = [self bds_getJSON:urlPath config:config error:error];
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}

+ (BOOL)bds_releaseAtTagHasOutputAsset:(NSString *)tagName config:(ZTranscoderConfig *)config {
    NSError *lookupError = nil;
    NSDictionary *release = [self bds_fetchReleaseByTag:tagName config:config error:&lookupError];
    if (!release) return NO;
    NSArray *assets = release[@"assets"];
    if (![assets isKindOfClass:NSArray.class]) return NO;
    for (NSDictionary *asset in assets) {
        if ([asset isKindOfClass:NSDictionary.class] && [asset[@"name"] isEqual:kBDSOutputAssetName]) return YES;
    }
    return NO;
}

+ (BOOL)bds_downloadReleaseAssetNamed:(NSString *)name
                       fromReleaseTag:(NSString *)releaseTag
                               config:(ZTranscoderConfig *)config
                             progress:(nullable void (^)(int64_t bytesWritten, int64_t totalBytesExpected))progress
                                 data:(NSData **)outData
                                error:(NSError **)error {
    NSDictionary *release = [self bds_fetchReleaseByTag:releaseTag config:config error:error];
    if (!release) {

        if (error && (*error).code == ZTranscoderServiceErrorAPIError &&
            [(*error).userInfo[ZTranscoderServiceHTTPStatusKey] isEqual:@404]) {
            *error = [self bds_errorWithCode:ZTranscoderServiceErrorOutputMissing
                                  description:[NSString stringWithFormat:@"Run succeeded but the release tagged %@ wasn't found afterward.", releaseTag]];
        }
        return NO;
    }

    NSArray *assets = release[@"assets"];
    NSDictionary *asset = nil;
    if ([assets isKindOfClass:NSArray.class]) {
        for (NSDictionary *candidate in assets) {
            if ([candidate isKindOfClass:NSDictionary.class] && [candidate[@"name"] isEqual:name]) {
                asset = candidate;
                break;
            }
        }
    }
    if (!asset) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorOutputMissing
                                         description:[NSString stringWithFormat:@"Run succeeded but %@ wasn't on release %@ afterward - check the workflow uploads its output there.", name, releaseTag]];
        return NO;
    }

    NSString *assetAPIURL = asset[@"url"];
    if (![assetAPIURL isKindOfClass:NSString.class]) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorAPIError description:@"Release asset had no API url."];
        return NO;
    }

    id assetSizeValue = asset[@"size"];
    int64_t knownTotalBytes = [assetSizeValue respondsToSelector:@selector(longLongValue)] ? [assetSizeValue longLongValue] : 0;

    NSData *data = [self bds_downloadBinaryAtAbsoluteURLString:assetAPIURL config:config
                                                 knownTotalBytes:knownTotalBytes progress:progress error:error];
    if (!data) return NO;
    if (outData) *outData = data;
    return YES;
}

+ (void)bds_deleteReleaseWithTag:(NSString *)tagName config:(ZTranscoderConfig *)config {
    NSError *lookupError = nil;
    NSDictionary *release = [self bds_fetchReleaseByTag:tagName config:config error:&lookupError];
    if (!release) {

        return;
    }

    NSString *releaseID = [release[@"id"] stringValue];
    if (releaseID.length > 0) {
        NSString *deletePath = [NSString stringWithFormat:@"/repos/%@/%@/releases/%@", config.repoOwner, config.repoName, releaseID];
        NSError *deleteError = nil;
        if (![self bds_deleteJSON:deletePath config:config error:&deleteError]) {
            ZLog(@"[ZTranscoderService] couldn't delete scratch release %@: %@", tagName, deleteError);
        }
    }

    NSString *escapedTag = [tagName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *tagRefPath = [NSString stringWithFormat:@"/repos/%@/%@/git/refs/tags/%@", config.repoOwner, config.repoName, escapedTag];
    NSError *tagDeleteError = nil;
    if (![self bds_deleteJSON:tagRefPath config:config error:&tagDeleteError]) {
        ZLog(@"[ZTranscoderService] couldn't delete scratch release tag ref %@: %@", tagName, tagDeleteError);
    }
}

+ (void)bds_cleanupScratchSubmission:(NSString *)scratchBranch config:(ZTranscoderConfig *)config {
    [self bds_deleteReleaseWithTag:scratchBranch config:config];
    [self bds_deleteBranch:scratchBranch config:config];
}

#pragma mark - Actions API steps

+ (BOOL)bds_dispatchWorkflowOnBranch:(NSString *)branchName
                                config:(ZTranscoderConfig *)config
                                 error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/workflows/%@/dispatches",
                          config.repoOwner, config.repoName, config.workflowFile];

    NSDictionary *body = @{
        @"ref": branchName,
        @"inputs": @{
            kBDSReleaseTagInputKey: branchName,
            kBDSInputFormatKey: config.outputFormat,
        },
    };

    return [self bds_postJSON:urlPath body:body config:config error:error] != nil;
}

+ (BOOL)bds_findRunOnBranch:(NSString *)branchName
             dispatchedAfter:(NSDate *)dispatchedAt
                      config:(ZTranscoderConfig *)config
                       runID:(NSString **)outRunID
                      runURL:(NSString **)outRunURL
                       error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/workflows/%@/runs?branch=%@&event=workflow_dispatch&per_page=10",
                          config.repoOwner, config.repoName, config.workflowFile,
                          [branchName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

    NSDate *deadline = [dispatchedAt dateByAddingTimeInterval:kBDSRunDiscoveryTimeout];
    NSDateFormatter *iso = [self bds_iso8601Formatter];

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        id result = [self bds_getJSON:urlPath config:config error:error];
        if (!result) return NO;

        NSArray *runs = result[@"workflow_runs"];
        if ([runs isKindOfClass:[NSArray class]]) {
            for (NSDictionary *run in runs) {
                NSString *createdAtString = run[@"created_at"];
                NSDate *createdAt = [iso dateFromString:createdAtString ?: @""];

                if (createdAt && [createdAt compare:[dispatchedAt dateByAddingTimeInterval:-5.0]] != NSOrderedAscending) {
                    if (outRunID) *outRunID = [run[@"id"] stringValue];
                    if (outRunURL) *outRunURL = run[@"html_url"];
                    ZLog(@"[ZTranscoderService] found dispatched run %@ on branch %@", [run[@"id"] stringValue], branchName);
                    return YES;
                }
            }
        }

        [NSThread sleepForTimeInterval:kBDSRunDiscoveryPollInterval];
    }

    if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorRunNotFound
                                     description:@"Dispatched the workflow but no matching run showed up in time."];
    ZLog(@"[ZTranscoderService] gave up looking for a dispatched run on branch %@ after %.0fs", branchName, kBDSRunDiscoveryTimeout);
    return NO;
}

+ (BOOL)bds_waitForRunCompletion:(NSString *)runID
                            runURL:(NSString *)runURL
                            config:(ZTranscoderConfig *)config
                             error:(NSError **)error {
    NSString *urlPath = [NSString stringWithFormat:@"/repos/%@/%@/actions/runs/%@", config.repoOwner, config.repoName, runID];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kBDSRunCompletionTimeout];

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        id run = [self bds_getJSON:urlPath config:config error:error];
        if (!run) return NO;

        NSString *status = run[@"status"];
        if ([status isEqualToString:@"completed"]) {
            NSString *conclusion = run[@"conclusion"];
            if ([conclusion isEqualToString:@"success"]) {
                ZLog(@"[ZTranscoderService] run %@ completed successfully (sync wait)", runID);
                return YES;
            }

            ZLog(@"[ZTranscoderService] run %@ finished with conclusion \"%@\" (sync wait)", runID, conclusion ?: @"unknown");
            if (error) {
                NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
                userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"Workflow run finished with conclusion \"%@\".", conclusion ?: @"unknown"];
                if (runURL) userInfo[ZTranscoderServiceRunURLKey] = runURL;
                *error = [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                              code:ZTranscoderServiceErrorRunFailed
                                          userInfo:userInfo];
            }
            return NO;
        }

        [NSThread sleepForTimeInterval:kBDSRunCompletionPollInterval];
    }

    if (error) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[NSLocalizedDescriptionKey] = @"Timed out waiting for the workflow run to finish.";
        if (runURL) userInfo[ZTranscoderServiceRunURLKey] = runURL;
        *error = [NSError errorWithDomain:ZTranscoderServiceErrorDomain code:ZTranscoderServiceErrorTimedOut userInfo:userInfo];
    }
    ZLog(@"[ZTranscoderService] timed out after %.0fs waiting for run %@ to finish (sync wait)", kBDSRunCompletionTimeout, runID);
    return NO;
}

#pragma mark - HTTP plumbing

+ (nullable NSMutableURLRequest *)bds_requestForAbsoluteURLString:(NSString *)urlString config:(ZTranscoderConfig *)config {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];

    [request setValue:@"ZSingularity-ZTranscoder" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", config.authToken] forHTTPHeaderField:@"Authorization"];
    return request;
}

+ (nullable NSMutableURLRequest *)bds_requestForPath:(NSString *)path config:(ZTranscoderConfig *)config {
    return [self bds_requestForAbsoluteURLString:[@"https://api.github.com" stringByAppendingString:path] config:config];
}

+ (nullable NSData *)bds_downloadBinaryAtAbsoluteURLString:(NSString *)urlString
                                                       config:(ZTranscoderConfig *)config
                                              knownTotalBytes:(int64_t)knownTotalBytes
                                                     progress:(nullable void (^)(int64_t bytesWritten, int64_t totalBytesExpected))progress
                                                        error:(NSError **)error {
    NSMutableURLRequest *request = [self bds_requestForAbsoluteURLString:urlString config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return nil;
    }
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Accept"];
    request.HTTPMethod = @"GET";

    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSError *transportError = nil;

    BDSDownloadProgressDelegate *delegate = [BDSDownloadProgressDelegate new];
    delegate.knownTotalBytesExpected = knownTotalBytes;
    delegate.onProgress = progress;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                             delegate:delegate
                                                        delegateQueue:nil];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request
                                                      completionHandler:^(NSURL *location, NSURLResponse *response, NSError *taskError) {
        httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        transportError = taskError;
        if (location) {
            NSError *readError = nil;
            responseData = [NSData dataWithContentsOfURL:location options:0 error:&readError];
            if (!responseData) {
                ZLog(@"[ZTranscoderService] couldn't read downloaded temp file at %@: %@", location, readError);
            }
        }
        dispatch_semaphore_signal(sema);
    }];
    [task resume];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];

    if (transportError) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                          code:ZTranscoderServiceErrorRequestFailed
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: transportError.localizedDescription ?: @"Network request failed.",
                                          NSUnderlyingErrorKey: transportError,
                                      }];
        }
        return nil;
    }

    NSInteger status = httpResponse.statusCode;
    if (status < 200 || status >= 300) {
        NSString *bodyString = responseData ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"";
        if (bodyString.length > 500) bodyString = [bodyString substringToIndex:500];
        ZLog(@"[ZTranscoderService] GET %@ -> %ld: %@", urlString, (long)status, bodyString);
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                          code:ZTranscoderServiceErrorAPIError
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"GitHub API returned %ld.", (long)status],
                                          ZTranscoderServiceHTTPStatusKey: @(status),
                                          ZTranscoderServiceResponseBodyKey: bodyString,
                                      }];
        }
        return nil;
    }

    if (!responseData) {

        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed
                                         description:@"Download succeeded but the temp file couldn't be read."];
        return nil;
    }

    return responseData;
}

+ (nullable id)bds_getJSON:(NSString *)path config:(ZTranscoderConfig *)config error:(NSError **)error {
    NSMutableURLRequest *request = [self bds_requestForPath:path config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return nil;
    }
    request.HTTPMethod = @"GET";
    return [self bds_performJSONRequest:request expectBody:YES error:error];
}

+ (nullable id)bds_postJSON:(NSString *)path body:(NSDictionary *)body config:(ZTranscoderConfig *)config error:(NSError **)error {
    NSMutableURLRequest *request = [self bds_requestForPath:path config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return nil;
    }
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSError *encodeError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodeError];
    if (!bodyData) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed
                                         description:encodeError.localizedDescription ?: @"Couldn't encode request body."];
        return nil;
    }
    request.HTTPBody = bodyData;

    return [self bds_performJSONRequest:request expectBody:NO error:error];
}

+ (BOOL)bds_deleteJSON:(NSString *)path config:(ZTranscoderConfig *)config error:(NSError **)error {
    NSMutableURLRequest *request = [self bds_requestForPath:path config:config];
    if (!request) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed description:@"Couldn't build request URL."];
        return NO;
    }
    request.HTTPMethod = @"DELETE";
    return [self bds_performJSONRequest:request expectBody:NO error:error] != nil;
}

static const NSTimeInterval kBDSSynchronousRequestTimeout = 45.0;

+ (nullable id)bds_performJSONRequest:(NSURLRequest *)request expectBody:(BOOL)expectBody error:(NSError **)error {
    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSError *transportError = nil;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        responseData = data;
        httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        transportError = taskError;
        dispatch_semaphore_signal(sema);
    }];
    [task resume];

    long timedOut = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBDSSynchronousRequestTimeout * NSEC_PER_SEC)));
    if (timedOut != 0) {

        [task cancel];
        if (error) {
            *error = [self bds_errorWithCode:ZTranscoderServiceErrorRequestFailed
                                  description:@"Timed out waiting for a response from GitHub."];
        }
        return nil;
    }

    if (transportError) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                          code:ZTranscoderServiceErrorRequestFailed
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: transportError.localizedDescription ?: @"Network request failed.",
                                          NSUnderlyingErrorKey: transportError,
                                      }];
        }
        return nil;
    }

    NSInteger status = httpResponse.statusCode;
    if (status < 200 || status >= 300) {
        NSString *bodyString = responseData ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"";
        if (bodyString.length > 500) bodyString = [bodyString substringToIndex:500];
        ZLog(@"[ZTranscoderService] %@ %@ -> %ld: %@", request.HTTPMethod, request.URL.path, (long)status, bodyString);
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                          code:ZTranscoderServiceErrorAPIError
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"GitHub API returned %ld.", (long)status],
                                          ZTranscoderServiceHTTPStatusKey: @(status),
                                          ZTranscoderServiceResponseBodyKey: bodyString,
                                      }];
        }
        return nil;
    }

    if (responseData.length == 0) {

        return expectBody ? @{} : @{};
    }

    NSError *parseError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&parseError];
    if (!parsed) {
        if (error) *error = [self bds_errorWithCode:ZTranscoderServiceErrorAPIError
                                         description:parseError.localizedDescription ?: @"Couldn't parse GitHub API response."];
        return nil;
    }
    return parsed;
}

+ (NSDateFormatter *)bds_iso8601Formatter {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return formatter;
}

+ (NSError *)bds_errorWithCode:(ZTranscoderServiceErrorCode)code description:(NSString *)description {
    return [NSError errorWithDomain:ZTranscoderServiceErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

@end

#pragma mark - ZTranscoderInstaller

NSString * const ZTranscoderInstallerErrorDomain = @"ZTranscoderInstallerErrorDomain";

static NSString * const kBackupSuffix = @".orig-bak";

static NSString * const kManifestFileName = @"manifest.json";

@implementation ZTranscoderInstaller

+ (NSString *)bundleBackupDirectory {
    return [ModAssetLibrary originalBundleBackupsDirectory];
}

+ (NSString *)bds_backupKeyForStockBundleURL:(NSURL *)stockBundleURL {
    NSString *path = stockBundleURL.path ?: stockBundleURL.absoluteString ?: @"";
    uint64_t hash = 1469598103934665603ULL;
    const char *bytes = path.UTF8String;
    if (bytes) {
        for (; *bytes != '\0'; bytes++) {
            hash ^= (uint64_t)(uint8_t)*bytes;
            hash *= 1099511628211ULL;
        }
    }
    return [NSString stringWithFormat:@"%@-%016llx", path.lastPathComponent ?: @"backup", hash];
}

+ (BOOL)bds_ensureBackupDirectoryExists:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    if (!dir) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve Library directory."}];
        }
        return NO;
    }
    NSError *createError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&createError]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: createError.localizedDescription ?: @"Couldn't create backup directory."}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Manifest

+ (NSString *)bds_manifestPath {
    return [[self bundleBackupDirectory] stringByAppendingPathComponent:kManifestFileName];
}

+ (NSMutableDictionary<NSString *, NSString *> *)bds_loadManifest {
    NSData *data = [NSData dataWithContentsOfFile:[self bds_manifestPath]];
    if (!data) return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return [NSMutableDictionary dictionary];
    return (NSMutableDictionary *)obj;
}

+ (BOOL)bds_writeManifest:(NSDictionary<NSString *, NSString *> *)manifest {
    NSData *data = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) return NO;
    return [data writeToFile:[self bds_manifestPath] options:NSDataWritingAtomic error:nil];
}

#pragma mark - Public API

+ (BOOL)installDoctoredBundleAtURL:(NSURL *)doctoredURL
                  toStockBundleURL:(NSURL *)stockBundleURL
                              error:(NSError **)error {
    NSData *doctoredData = [NSData dataWithContentsOfURL:doctoredURL options:0 error:error];
    if (!doctoredData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorCantReadDoctored
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the doctored bundle."}];
        }
        return NO;
    }

    if (![self bds_ensureBackupDirectoryExists:error]) return NO;

    BOOL scoped = [stockBundleURL startAccessingSecurityScopedResource];

    NSString *backupKey = [self bds_backupKeyForStockBundleURL:stockBundleURL];
    NSString *backupPath = [[self bundleBackupDirectory] stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]];
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL stockExists = [fm fileExistsAtPath:stockBundleURL.path];
    if (stockExists && ![fm fileExistsAtPath:backupPath]) {
        NSError *backupError = nil;
        if (![fm copyItemAtURL:stockBundleURL toURL:[NSURL fileURLWithPath:backupPath] error:&backupError]) {
            if (error) {
                *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                              code:ZTranscoderInstallerErrorBackupFailed
                                          userInfo:@{NSLocalizedDescriptionKey: backupError.localizedDescription ?: @"Couldn't back up the original bundle."}];
            }
            if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
            return NO;
        }

        NSMutableDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
        manifest[backupKey] = stockBundleURL.path;
        [self bds_writeManifest:manifest];
    } else if (!stockExists) {
        ZLog(@"[ZTranscoderInstaller] no existing file at %@ - nothing to back up (synthesized/never-cached destination), writing doctored bundle fresh.", stockBundleURL.path);
    }

    NSError *writeError = nil;
    if (![doctoredData writeToURL:stockBundleURL options:NSDataWritingAtomic error:&writeError]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't swap in the doctored bundle."}];
        }
        if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
        return NO;
    }

    if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];
    ZLog(@"[ZTranscoderInstaller] installed doctored bundle at %@", stockBundleURL.path);

    zs_track_asset_path(stockBundleURL.path);

    return YES;
}

+ (BOOL)bds_fileAtPath:(NSString *)pathA hasIdenticalBytesToFileAtPath:(NSString *)pathB {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:pathA] || ![fm fileExistsAtPath:pathB]) return NO;

    NSDictionary<NSFileAttributeKey, id> *attrsA = [fm attributesOfItemAtPath:pathA error:nil];
    NSDictionary<NSFileAttributeKey, id> *attrsB = [fm attributesOfItemAtPath:pathB error:nil];
    unsigned long long sizeA = [attrsA[NSFileSize] unsignedLongLongValue];
    unsigned long long sizeB = [attrsB[NSFileSize] unsignedLongLongValue];
    if (sizeA != sizeB) return NO;

    NSData *dataA = [NSData dataWithContentsOfFile:pathA];
    NSData *dataB = [NSData dataWithContentsOfFile:pathB];
    if (!dataA || !dataB) return NO;
    return [dataA isEqualToData:dataB];
}

+ (NSInteger)restoreAllBackedUpBundlesForce:(BOOL)force error:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    if (!dir || ![[NSFileManager defaultManager] fileExistsAtPath:dir]) return 0;

    NSDictionary<NSString *, NSString *> *manifest = [self bds_loadManifest];
    if (manifest.count == 0) return 0;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger restored = 0;

    for (NSString *backupKey in manifest) {
        NSString *originalPath = manifest[backupKey];
        NSString *backupPath = [dir stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]];
        if (![fm fileExistsAtPath:backupPath] || originalPath.length == 0) continue;

        if (!force && [self bds_fileAtPath:originalPath hasIdenticalBytesToFileAtPath:backupPath]) {
            continue;
        }

        NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
        if (!backupData) continue;

        NSError *writeError = nil;
        if ([backupData writeToFile:originalPath options:NSDataWritingAtomic error:&writeError]) {
            restored++;
        } else {
            ZLog(@"[ZTranscoderInstaller] couldn't restore %@ to %@: %@", backupKey, originalPath, writeError);
        }
    }

    return restored;
}

+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error {
    return [self restoreAllBackedUpBundlesForce:NO error:error];
}

+ (BOOL)cacheOriginalBackForStockBundleURL:(NSURL *)stockBundleURL error:(NSError **)error {
    NSString *dir = [self bundleBackupDirectory];
    NSString *backupKey = [self bds_backupKeyForStockBundleURL:stockBundleURL];
    NSString *backupPath = dir ? [dir stringByAppendingPathComponent:[backupKey stringByAppendingString:kBackupSuffix]] : nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (!backupPath || ![fm fileExistsAtPath:backupPath]) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"No backed-up original found for this bundle."}];
        }
        return NO;
    }

    NSData *backupData = [NSData dataWithContentsOfFile:backupPath];
    if (!backupData) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorBackupFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the backed-up original."}];
        }
        return NO;
    }

    BOOL scoped = [stockBundleURL startAccessingSecurityScopedResource];
    NSError *writeError = nil;
    BOOL wrote = [backupData writeToURL:stockBundleURL options:NSDataWritingAtomic error:&writeError];
    if (scoped) [stockBundleURL stopAccessingSecurityScopedResource];

    if (!wrote) {
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                          code:ZTranscoderInstallerErrorWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: @"Couldn't write the original bundle back."}];
        }
        return NO;
    }

    ZLog(@"[ZTranscoderInstaller] cached %@ - live bytes swapped back to the backed-up original", stockBundleURL.lastPathComponent);
    return YES;
}

@end

#pragma mark - ZTranscoderSettings

NSString * const ZTranscoderSettingsErrorDomain = @"ZTranscoderSettingsErrorDomain";

static NSString * const kKeychainService = @"com.120F.ZTranscoderService";
static NSString * const kKeychainAccount = @"githubAuthToken";

@implementation ZTranscoderSettings

#pragma mark - Shared settings.json (non-sensitive fields)

static NSDictionary *bds_load_json_dictionary(void) {
    return zs_settings_section(kSettingsSection);
}

static BOOL bds_write_json_dictionary(NSDictionary *dict, NSError **error) {
    zs_write_settings_section(kSettingsSection, dict);
    return YES;
}

#pragma mark - Keychain (authToken only)

static NSString *_Nullable bds_read_token(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);

    if (status == errSecItemNotFound) {
        return nil;
    }
    if (status != errSecSuccess) {
        ZLog(@"[ZTranscoderSettings] Keychain read failed (OSStatus %d) - see this file's header caveat on injected-dylib Keychain access", (int)status);
        return nil;
    }

    NSData *data = (__bridge_transfer NSData *)result;
    if (![data isKindOfClass:[NSData class]]) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL bds_write_token(NSString *token, NSError **error) {
    NSData *tokenData = [token dataUsingEncoding:NSUTF8StringEncoding];

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };

    NSDictionary *attributesToUpdate = @{
        (__bridge id)kSecValueData: tokenData,
    };

    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributesToUpdate);

    if (status == errSecItemNotFound) {
        NSMutableDictionary *addQuery = [query mutableCopy];
        addQuery[(__bridge id)kSecValueData] = tokenData;

        addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    }

    if (status != errSecSuccess) {
        ZLog(@"[ZTranscoderSettings] Keychain token write failed (OSStatus %d)", (int)status);
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderSettingsErrorDomain
                                          code:ZTranscoderSettingsErrorKeychainWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"Keychain write failed (OSStatus %d).", (int)status]}];
        }
        return NO;
    }
    return YES;
}

static BOOL bds_delete_token(NSError **error) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status != errSecSuccess && status != errSecItemNotFound) {
        ZLog(@"[ZTranscoderSettings] Keychain token delete failed (OSStatus %d)", (int)status);
        if (error) {
            *error = [NSError errorWithDomain:ZTranscoderSettingsErrorDomain
                                          code:ZTranscoderSettingsErrorKeychainDeleteFailed
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"Keychain delete failed (OSStatus %d).", (int)status]}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Public API

+ (BOOL)hasStoredConfig {
    return bds_load_json_dictionary().count > 0;
}

+ (ZTranscoderConfig *)loadConfig {
    NSDictionary *dict = bds_load_json_dictionary();

    ZTranscoderConfig *config = [ZTranscoderConfig new];
    config.repoOwner     = dict[@"repoOwner"];
    config.repoName      = dict[@"repoName"];
    config.ref           = dict[@"ref"];
    config.workflowFile  = dict[@"workflowFile"];
    config.outputFormat  = dict[@"outputFormat"];
    config.authToken     = bds_read_token();

    return config;
}

+ (BOOL)saveConfig:(ZTranscoderConfig *)config error:(NSError **)error {
    ZLog(@"[ZTranscoderSettings] saving transcoder config (repo=%@/%@ ref=%@ format=%@)",
         config.repoOwner, config.repoName, config.ref, config.outputFormat);
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (config.repoOwner.length > 0)    dict[@"repoOwner"] = config.repoOwner;
    if (config.repoName.length > 0)     dict[@"repoName"] = config.repoName;
    if (config.ref.length > 0)          dict[@"ref"] = config.ref;
    if (config.workflowFile.length > 0) dict[@"workflowFile"] = config.workflowFile;
    if (config.outputFormat.length > 0) dict[@"outputFormat"] = config.outputFormat;

    if (!bds_write_json_dictionary(dict, error)) {
        return NO;
    }

    if (config.authToken.length > 0) {
        return bds_write_token(config.authToken, error);
    } else {
        return bds_delete_token(error);
    }
}

+ (BOOL)clearAllWithError:(NSError **)error {
    ZLog(@"[ZTranscoderSettings] clearing all stored transcoder config and keychain token");
    zs_write_settings_section(kSettingsSection, @{});
    return bds_delete_token(error);
}

@end

