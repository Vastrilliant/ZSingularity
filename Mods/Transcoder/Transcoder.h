#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ZTranscoderServiceErrorDomain;

FOUNDATION_EXPORT NSError *ZTMakeTranscoderError(NSInteger code, NSString *message);

typedef NS_ENUM(NSInteger, ZTranscoderServiceErrorCode) {
    ZTranscoderServiceErrorInvalidConfig = 1,
    ZTranscoderServiceErrorCantReadModdedBundle,
    ZTranscoderServiceErrorRequestFailed,
    ZTranscoderServiceErrorAPIError,
    ZTranscoderServiceErrorRunNotFound,
    ZTranscoderServiceErrorRunFailed,
    ZTranscoderServiceErrorTimedOut,
    ZTranscoderServiceErrorOutputMissing,
};


typedef NS_ENUM(NSInteger, ZSTranscoderCodec) {
    ZSTranscoderCodecASTC6x6 = 0,
    ZSTranscoderCodecASTC8x8,
    ZSTranscoderCodecASTC10x10,
    ZSTranscoderCodecRGBA32,
};

FOUNDATION_EXPORT ZSTranscoderCodec zs_transcoder_codec(void);
FOUNDATION_EXPORT void zs_set_transcoder_codec(ZSTranscoderCodec codec);
FOUNDATION_EXPORT BOOL zs_transcoder_rgba32_passthrough(void);
FOUNDATION_EXPORT void zs_set_transcoder_rgba32_passthrough(BOOL enabled);
FOUNDATION_EXPORT BOOL zs_transcoder_parallel_enabled(void);
FOUNDATION_EXPORT void zs_set_transcoder_parallel_enabled(BOOL enabled);
FOUNDATION_EXPORT NSUInteger zs_transcoder_core_count(void);

@interface ZTranscoderConfig : NSObject
@property (nonatomic, copy, nullable) NSString *targetBundlePath;
- (ZTranscoderConfig *)normalizedConfig;
@end

@interface ZTranscoderHandle : NSObject
@property (nonatomic, copy, readonly) NSString *scratchBranch;
@property (nonatomic, copy, nullable) NSString *runID;
@property (nonatomic, copy, nullable) NSString *runURL;
@property (nonatomic, assign, readonly) BOOL alreadyComplete;
@property (nonatomic, assign) unsigned long long compressedByteSize;
@property (nonatomic, copy, nullable) NSString *warningMessage;
- (NSDictionary<NSString *, NSString *> *)dictionaryRepresentation;
+ (nullable instancetype)handleFromDictionaryRepresentation:(NSDictionary<NSString *, NSString *> *)dict;
@end

@interface ZTranscoderService : NSObject

+ (void)ztranscoderBundleAtURL:(NSURL *)moddedBundleURL
                        config:(nullable ZTranscoderConfig *)config
                      progress:(nullable void (^)(double fraction, NSString *stage))progress
                    completion:(void (^)(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error))completion;

+ (void)dispatchBundleAtURL:(NSURL *)moddedBundleURL
                   carra2Hash1:(nullable NSString *)carra2Hash1
                   carra2Hash2:(nullable NSString *)carra2Hash2
                        config:(nullable ZTranscoderConfig *)config
         previousScratchBranch:(nullable NSString *)previousScratchBranch
                uploadProgress:(nullable void (^)(int64_t bytesSent, int64_t totalBytesExpected))uploadProgress
                    completion:(void (^)(ZTranscoderHandle * _Nullable handle, NSError * _Nullable error))completion;

+ (BOOL)isUploadCompressionEnabled;
+ (void)setUploadCompressionEnabled:(BOOL)enabled;

@end

extern NSString * const ZTranscoderInstallerErrorDomain;

typedef NS_ENUM(NSInteger, ZTranscoderInstallerErrorCode) {
    ZTranscoderInstallerErrorCantReadDoctored = 1,
    ZTranscoderInstallerErrorBackupFailed,
    ZTranscoderInstallerErrorWriteFailed,
    ZTranscoderInstallerErrorNoInstallTarget,
};

@interface ZTranscoderInstaller : NSObject
+ (NSString *)bundleBackupDirectory;
+ (BOOL)installDoctoredBundleAtURL:(NSURL *)doctoredURL
                  toStockBundleURL:(NSURL *)stockBundleURL
                              error:(NSError **)error;
+ (NSInteger)restoreAllBackedUpBundlesWithError:(NSError **)error;
+ (NSInteger)restoreAllBackedUpBundlesForce:(BOOL)force error:(NSError **)error;
+ (BOOL)cacheOriginalBackForStockBundleURL:(NSURL *)stockBundleURL error:(NSError **)error;
+ (void)reconcileModdedBundles;
@end


@interface ZTLiveReloader : NSObject
+ (void)reloadBundleForCABInput:(NSString *)input
                     completion:(void (^)(BOOL success, NSString *summary))completion;
@end

NS_ASSUME_NONNULL_END
