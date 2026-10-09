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
@end


NS_ASSUME_NONNULL_END
