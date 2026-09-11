
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ZSDylibSigningSettingsErrorDomain;

typedef NS_ENUM(NSInteger, ZSDylibSigningSettingsErrorCode) {
    ZSDylibSigningSettingsErrorWriteFailed = 1,
    ZSDylibSigningSettingsErrorKeychainWriteFailed,
    ZSDylibSigningSettingsErrorKeychainDeleteFailed,
    ZSDylibSigningSettingsErrorImportFailed,
};

@interface ZSDylibSigningConfig : NSObject

@property (nonatomic, copy, nullable) NSString *certificateFileName;

@property (nonatomic, copy, nullable) NSString *password;

@property (nonatomic, copy, nullable) NSString *lastVerifiedCommonName;
@property (nonatomic, copy, nullable) NSDate *lastVerifiedExpirationDate;
@end

@interface ZSDylibSigningSettings : NSObject

+ (BOOL)hasStoredConfig;

+ (ZSDylibSigningConfig *)loadConfig;

+ (BOOL)saveConfig:(ZSDylibSigningConfig *)config error:(NSError **)error;

+ (BOOL)clearAllWithError:(NSError **)error;

+ (nullable NSString *)importCertificateAtURL:(NSURL *)url error:(NSError **)error;

+ (nullable NSURL *)certificateFileURL;

@end

extern NSString * const ZSDylibSigningServiceErrorDomain;

typedef NS_ENUM(NSInteger, ZSDylibSigningServiceErrorCode) {
    ZSDylibSigningServiceErrorNoCertificateOnDisk = 1,
    ZSDylibSigningServiceErrorImportFailed,
    ZSDylibSigningServiceErrorNoIdentity,
};

@interface ZSDylibSigningService : NSObject

+ (void)verifyCertificateForConfig:(ZSDylibSigningConfig *)config
                         completion:(void (^)(BOOL valid,
                                               NSString * _Nullable commonName,
                                               NSDate * _Nullable expirationDate,
                                               NSError * _Nullable error))completion;

+ (void)signDylibAtPath:(NSString *)path
              withConfig:(ZSDylibSigningConfig *)config
              completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
