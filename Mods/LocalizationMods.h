
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const LocalizationTransplantErrorDomain;

typedef NS_ENUM(NSInteger, LocalizationTransplantErrorCode) {
    LocalizationTransplantErrorInvalidTarget = 1,
    LocalizationTransplantErrorLanguageFolderNotFound,
    LocalizationTransplantErrorCantReadModded,
    LocalizationTransplantErrorBackupFailed,
    LocalizationTransplantErrorWriteFailed,
    LocalizationTransplantErrorNotAPack,
};

@interface LocalizationTransplant : NSObject

+ (NSArray<NSString *> *)languageCodes;

+ (nullable NSString *)localizeDirectory;

+ (nullable NSString *)languageDirectoryForCode:(NSString *)languageCode;

+ (nullable NSString *)backupDirectory;

+ (BOOL)isJunkArchivePathComponents:(NSArray<NSString *> *)components;

+ (BOOL)isLocalizationJSONAtURL:(NSURL *)url;

+ (BOOL)isTranslationPackDirectoryAtPath:(NSString *)path;

+ (nullable NSString *)packRootFolderNameForArchiveEntryNames:(NSArray<NSString *> *)entryNames;

+ (nullable NSString *)packDirectoryInExtractedDirectoryAtPath:(NSString *)path;

+ (nullable NSString *)detectedLanguageForPackDirectoryAtPath:(NSString *)path;

+ (nullable NSString *)detectedLanguageForArchiveEntryNames:(NSArray<NSString *> *)entryNames;

+ (BOOL)prefixPackJSONFilesAtPath:(NSString *)packPath
                     withLanguage:(NSString *)languageCode
                            error:(NSError **)error;

+ (NSArray<NSString *> *)relativeTargetsForJSONNamed:(NSString *)fileName inLanguage:(NSString *)languageCode;

+ (unsigned long long)totalByteSizeAtPath:(NSString *)path;

+ (BOOL)applyModFileAtPath:(NSString *)modPath
          toRelativeTarget:(NSString *)relativeTarget
                     error:(NSError **)error;

+ (BOOL)applyPackAtPath:(NSString *)packPath
             toLanguage:(NSString *)languageCode
                  error:(NSError **)error;

+ (BOOL)restoreRelativeTarget:(NSString *)relativeTarget
   ifAppliedFromModFileAtPath:(NSString *)modPath;

+ (BOOL)restorePackForLanguage:(NSString *)languageCode
       ifAppliedFromPackAtPath:(NSString *)packPath;

+ (NSInteger)restoreAllBackupsForce:(BOOL)force error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
