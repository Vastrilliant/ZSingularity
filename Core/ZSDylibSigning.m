#import "ZSDylibSigning.h"
#import "ZTweakLog.h"
#import "ZSEngine.h"
#import "ZSStandaloneSigner.h"
#import <Security/Security.h>

#pragma mark - ZSDylibSigningSettings

NSString * const ZSDylibSigningSettingsErrorDomain = @"ZSDylibSigningSettingsErrorDomain";

static NSString * const kKeychainService = @"com.120F.ZSDylibSigning";
static NSString * const kKeychainAccount = @"p12CertificatePassword";
static NSString * const kSettingsSection = @"dylibSigning";
static NSString * const kCertificateFileName = @"certificate.p12";

@implementation ZSDylibSigningConfig
@end

@implementation ZSDylibSigningSettings

#pragma mark - Storage location (Documents, so it's reachable via file sharing)

static NSString *zs_dylib_signing_directory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"ZSingularityDylibSigning"];
}

static NSString *_Nullable zs_dylib_signing_certificate_path(void) {
    NSString *dir = zs_dylib_signing_directory();
    if (!dir) return nil;
    return [dir stringByAppendingPathComponent:kCertificateFileName];
}

#pragma mark - Shared settings.json (non-sensitive fields)

static NSDictionary *dsc_load_json_dictionary(void) {
    return zs_settings_section(kSettingsSection);
}

static BOOL dsc_write_json_dictionary(NSDictionary *dict, NSError **error) {
    zs_write_settings_section(kSettingsSection, dict);
    return YES;
}

#pragma mark - Keychain (password only)

static NSString *_Nullable dsc_read_password(void) {
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
        ZLog(@"[ZSDylibSigningSettings] Keychain read failed (OSStatus %d) - see this file's header caveat on injected-dylib Keychain access", (int)status);
        return nil;
    }

    NSData *data = (__bridge_transfer NSData *)result;
    if (![data isKindOfClass:[NSData class]]) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL dsc_write_password(NSString *password, NSError **error) {
    NSData *passwordData = [password dataUsingEncoding:NSUTF8StringEncoding];

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };

    NSDictionary *attributesToUpdate = @{
        (__bridge id)kSecValueData: passwordData,
    };

    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributesToUpdate);

    if (status == errSecItemNotFound) {
        NSMutableDictionary *addQuery = [query mutableCopy];
        addQuery[(__bridge id)kSecValueData] = passwordData;

        addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    }

    if (status != errSecSuccess) {
        ZLog(@"[ZSDylibSigningSettings] Keychain password write failed (OSStatus %d)", (int)status);
        if (error) {
            *error = [NSError errorWithDomain:ZSDylibSigningSettingsErrorDomain
                                          code:ZSDylibSigningSettingsErrorKeychainWriteFailed
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"Keychain write failed (OSStatus %d).", (int)status]}];
        }
        return NO;
    }
    return YES;
}

static BOOL dsc_delete_password(NSError **error) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status != errSecSuccess && status != errSecItemNotFound) {
        ZLog(@"[ZSDylibSigningSettings] Keychain password delete failed (OSStatus %d)", (int)status);
        if (error) {
            *error = [NSError errorWithDomain:ZSDylibSigningSettingsErrorDomain
                                          code:ZSDylibSigningSettingsErrorKeychainDeleteFailed
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"Keychain delete failed (OSStatus %d).", (int)status]}];
        }
        return NO;
    }
    return YES;
}

#pragma mark - Public API

+ (BOOL)hasStoredConfig {
    return dsc_load_json_dictionary().count > 0;
}

+ (ZSDylibSigningConfig *)loadConfig {
    NSDictionary *dict = dsc_load_json_dictionary();

    ZSDylibSigningConfig *config = [ZSDylibSigningConfig new];
    config.certificateFileName = dict[@"certificateFileName"];
    config.lastVerifiedCommonName = dict[@"lastVerifiedCommonName"];
    NSNumber *lastVerifiedExpirationTimestamp = dict[@"lastVerifiedExpirationTimestamp"];
    if ([lastVerifiedExpirationTimestamp isKindOfClass:[NSNumber class]]) {
        config.lastVerifiedExpirationDate = [NSDate dateWithTimeIntervalSince1970:lastVerifiedExpirationTimestamp.doubleValue];
    }
    config.password = dsc_read_password();

    if (config.certificateFileName.length > 0 && ![ZSDylibSigningSettings certificateFileURL]) {
        config.certificateFileName = nil;
    }

    return config;
}

+ (BOOL)saveConfig:(ZSDylibSigningConfig *)config error:(NSError **)error {
    ZLog(@"[ZSDylibSigningSettings] saving dylib signing config (certificate=%@)", config.certificateFileName);
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (config.certificateFileName.length > 0) dict[@"certificateFileName"] = config.certificateFileName;
    if (config.lastVerifiedCommonName.length > 0) dict[@"lastVerifiedCommonName"] = config.lastVerifiedCommonName;
    if (config.lastVerifiedExpirationDate) dict[@"lastVerifiedExpirationTimestamp"] = @(config.lastVerifiedExpirationDate.timeIntervalSince1970);

    if (!dsc_write_json_dictionary(dict, error)) {
        return NO;
    }

    if (config.password.length > 0) {
        return dsc_write_password(config.password, error);
    } else {
        return dsc_delete_password(error);
    }
}

+ (BOOL)clearAllWithError:(NSError **)error {
    ZLog(@"[ZSDylibSigningSettings] clearing all stored dylib signing config, certificate, and keychain password");
    zs_write_settings_section(kSettingsSection, @{});

    NSString *certPath = zs_dylib_signing_certificate_path();
    if (certPath && [[NSFileManager defaultManager] fileExistsAtPath:certPath]) {
        NSError *removeError = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:certPath error:&removeError]) {
            ZLog(@"[ZSDylibSigningSettings] failed to remove stored certificate: %@", removeError);
        }
    }

    return dsc_delete_password(error);
}

+ (nullable NSString *)importCertificateAtURL:(NSURL *)url error:(NSError **)error {
    NSString *dir = zs_dylib_signing_directory();
    if (!dir) {
        if (error) {
            *error = [NSError errorWithDomain:ZSDylibSigningSettingsErrorDomain
                                          code:ZSDylibSigningSettingsErrorImportFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve the app's Documents directory."}];
        }
        return nil;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        ZLog(@"[ZSDylibSigningSettings] failed to create storage directory: %@", dirError);
        if (error) *error = dirError;
        return nil;
    }

    NSString *destPath = [dir stringByAppendingPathComponent:kCertificateFileName];
    [fm removeItemAtPath:destPath error:nil];

    NSError *copyError = nil;
    if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:&copyError]) {
        ZLog(@"[ZSDylibSigningSettings] failed to import certificate: %@", copyError);
        if (error) {
            *error = [NSError errorWithDomain:ZSDylibSigningSettingsErrorDomain
                                          code:ZSDylibSigningSettingsErrorImportFailed
                                      userInfo:@{NSLocalizedDescriptionKey: copyError.localizedDescription ?: @"Couldn't copy the selected file."}];
        }
        return nil;
    }

    NSString *displayName = url.lastPathComponent.length > 0 ? url.lastPathComponent : kCertificateFileName;
    return displayName;
}

+ (nullable NSURL *)certificateFileURL {
    NSString *path = zs_dylib_signing_certificate_path();
    if (!path) return nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path];
}

@end

#pragma mark - ZSDylibSigningService

NSString * const ZSDylibSigningServiceErrorDomain = @"ZSDylibSigningServiceErrorDomain";

static NSDate * zs_date_from_asn1_time_string(NSString *s, BOOL fourDigitYear) {
    NSUInteger expectedLength = fourDigitYear ? 15 : 13;
    if (s.length != expectedLength || ![s hasSuffix:@"Z"]) return nil;

    NSUInteger idx = 0;
    NSInteger year;
    if (fourDigitYear) {
        year = [[s substringWithRange:NSMakeRange(idx, 4)] integerValue];
        idx += 4;
    } else {
        NSInteger twoDigitYear = [[s substringWithRange:NSMakeRange(idx, 2)] integerValue];
        year = (twoDigitYear < 50) ? (2000 + twoDigitYear) : (1900 + twoDigitYear);
        idx += 2;
    }
    NSInteger month = [[s substringWithRange:NSMakeRange(idx, 2)] integerValue]; idx += 2;
    NSInteger day = [[s substringWithRange:NSMakeRange(idx, 2)] integerValue]; idx += 2;
    NSInteger hour = [[s substringWithRange:NSMakeRange(idx, 2)] integerValue]; idx += 2;
    NSInteger minute = [[s substringWithRange:NSMakeRange(idx, 2)] integerValue]; idx += 2;
    NSInteger second = [[s substringWithRange:NSMakeRange(idx, 2)] integerValue];

    NSDateComponents *components = [NSDateComponents new];
    components.year = year;
    components.month = month;
    components.day = day;
    components.hour = hour;
    components.minute = minute;
    components.second = second;

    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return [calendar dateFromComponents:components];
}

static NSDate * zs_x509_notAfterDate(NSData *derData) {
    const uint8_t *bytes = derData.bytes;
    NSUInteger length = derData.length;
    NSMutableArray<NSDate *> *validityDates = [NSMutableArray array];

    NSUInteger i = 0;
    while (i + 1 < length && validityDates.count < 2) {
        uint8_t tag = bytes[i];
        if (tag != 0x17 && tag != 0x18) { i++; continue; }

        uint8_t lengthByte = bytes[i + 1];
        if (lengthByte & 0x80) { i++; continue; }
        NSUInteger valueLength = lengthByte;
        NSUInteger valueStart = i + 2;
        if (valueStart + valueLength > length) { i++; continue; }

        NSString *timeString = [[NSString alloc] initWithBytes:bytes + valueStart
                                                          length:valueLength
                                                        encoding:NSASCIIStringEncoding];
        NSDate *date = zs_date_from_asn1_time_string(timeString, tag == 0x18);
        if (date) [validityDates addObject:date];
        i = valueStart + valueLength;
    }

    return validityDates.lastObject;
}

@implementation ZSDylibSigningService

+ (void)verifyCertificateForConfig:(ZSDylibSigningConfig *)config
                         completion:(void (^)(BOOL valid,
                                               NSString * _Nullable commonName,
                                               NSDate * _Nullable expirationDate,
                                               NSError * _Nullable error))completion
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        NSString *commonName = nil;
        NSDate *expirationDate = nil;
        BOOL valid = [self zs_verifySynchronouslyForConfig:config
                                                  commonName:&commonName
                                              expirationDate:&expirationDate
                                                       error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(valid, commonName, expirationDate, error);
        });
    });
}

+ (void)signDylibAtPath:(NSString *)path
              withConfig:(ZSDylibSigningConfig *)config
              completion:(void (^)(BOOL success, NSError * _Nullable error))completion
{
    NSURL *certURL = [ZSDylibSigningSettings certificateFileURL];
    if (!certURL) {
        if (completion) completion(NO, [NSError errorWithDomain:ZSDylibSigningServiceErrorDomain
                                                             code:ZSDylibSigningServiceErrorNoCertificateOnDisk
                                                         userInfo:@{NSLocalizedDescriptionKey: @"No certificate has been imported yet."}]);
        return;
    }

    NSData *p12Data = [NSData dataWithContentsOfURL:certURL];
    if (!p12Data) {
        if (completion) completion(NO, [NSError errorWithDomain:ZSDylibSigningServiceErrorDomain
                                                             code:ZSDylibSigningServiceErrorNoCertificateOnDisk
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the imported certificate file."}]);
        return;
    }

    NSString *bundleId = [NSBundle mainBundle].bundleIdentifier ?: @"com.120F.ZSingularity";
    [ZSStandaloneSigner signMachOPathArr:@[path]
                                 bundleId:bundleId
                                     cert:p12Data
                                     pass:config.password ?: @""
                        completionHandler:^(BOOL success, NSError *signError) {
        if (!success) {
            ZLog(@"[ZSDylibSigningService] failed to sign %@: %@", path, signError);
        }
        if (completion) completion(success, signError);
    }];
}

#pragma mark - Private

+ (BOOL)zs_verifySynchronouslyForConfig:(ZSDylibSigningConfig *)config
                              commonName:(NSString * _Nullable * _Nonnull)outCommonName
                          expirationDate:(NSDate * _Nullable * _Nonnull)outExpirationDate
                                   error:(NSError **)error
{
    NSURL *certURL = [ZSDylibSigningSettings certificateFileURL];
    if (!certURL) {
        if (error) {
            *error = [NSError errorWithDomain:ZSDylibSigningServiceErrorDomain
                                          code:ZSDylibSigningServiceErrorNoCertificateOnDisk
                                      userInfo:@{NSLocalizedDescriptionKey: @"No certificate has been imported yet."}];
        }
        return NO;
    }

    NSData *p12Data = [NSData dataWithContentsOfURL:certURL];
    if (!p12Data) {
        if (error) {
            *error = [NSError errorWithDomain:ZSDylibSigningServiceErrorDomain
                                          code:ZSDylibSigningServiceErrorNoCertificateOnDisk
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the imported certificate file."}];
        }
        return NO;
    }

    NSDictionary *importOptions = @{(__bridge id)kSecImportExportPassphrase: config.password ?: @""};
    CFArrayRef rawItems = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)p12Data, (__bridge CFDictionaryRef)importOptions, &rawItems);

    if (status != errSecSuccess) {
        if (rawItems) CFRelease(rawItems);
        NSString *message = (status == errSecAuthFailed)
            ? @"Incorrect password for this certificate."
            : [NSString stringWithFormat:@"Couldn't unlock the certificate (OSStatus %d).", (int)status];
        ZLog(@"[ZSDylibSigningService] SecPKCS12Import failed (OSStatus %d)", (int)status);
        if (error) {
            *error = [NSError errorWithDomain:ZSDylibSigningServiceErrorDomain
                                          code:ZSDylibSigningServiceErrorImportFailed
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return NO;
    }

    NSArray *items = (__bridge_transfer NSArray *)rawItems;
    NSDictionary *firstItem = items.firstObject;
    SecIdentityRef identity = (__bridge SecIdentityRef)firstItem[(__bridge id)kSecImportItemIdentity];
    if (!identity) {
        if (error) {
            *error = [NSError errorWithDomain:ZSDylibSigningServiceErrorDomain
                                          code:ZSDylibSigningServiceErrorNoIdentity
                                      userInfo:@{NSLocalizedDescriptionKey: @"The certificate unlocked, but no signing identity was found inside it."}];
        }
        return NO;
    }

    SecCertificateRef certificate = NULL;
    SecIdentityCopyCertificate(identity, &certificate);
    if (!certificate) {
        if (error) {
            *error = [NSError errorWithDomain:ZSDylibSigningServiceErrorDomain
                                          code:ZSDylibSigningServiceErrorNoIdentity
                                      userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the certificate embedded in the signing identity."}];
        }
        return NO;
    }

    CFStringRef commonNameRef = NULL;
    SecCertificateCopyCommonName(certificate, &commonNameRef);
    if (commonNameRef) {
        *outCommonName = (__bridge_transfer NSString *)commonNameRef;
    }

    CFDataRef derDataRef = SecCertificateCopyData(certificate);
    if (derDataRef) {
        NSData *derData = (__bridge_transfer NSData *)derDataRef;
        *outExpirationDate = zs_x509_notAfterDate(derData);
    }
    CFRelease(certificate);

    ZSDylibSigningConfig *cacheConfig = [ZSDylibSigningSettings loadConfig];
    cacheConfig.lastVerifiedCommonName = *outCommonName;
    cacheConfig.lastVerifiedExpirationDate = *outExpirationDate;
    [ZSDylibSigningSettings saveConfig:cacheConfig error:nil];

    return YES;
}

@end
