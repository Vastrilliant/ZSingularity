#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZSFontKind) {
    ZSFontKindUnknown = 0,
    ZSFontKindTrueType,
    ZSFontKindOpenType,
};

typedef NS_ENUM(NSInteger, ZSFontRole) {
    ZSFontRoleNone = 0,
    ZSFontRoleTitle,
    ZSFontRoleContext,
    ZSFontRoleKanjiHanzi,
};

@interface ZSModsPaths : NSObject

+ (NSString *)modsRootDirectory;

+ (NSString *)modsLibraryDirectory;

+ (NSString *)modsBackupsDirectory;

+ (NSString *)modsBackupsLocalizeDirectory;

+ (NSString *)modsBackupsBanksDirectory;

+ (NSString *)modsBackupsAssetsDirectory;

+ (NSString *)modsFontsDirectory;

+ (nullable NSString *)ensuredDirectoryAtPath:(nullable NSString *)path;

+ (void)migrateLegacyDirectoryAtPath:(nullable NSString *)oldPath toPath:(nullable NSString *)newPath;

+ (ZSFontKind)fontKindForFileName:(NSString *)fileName;

+ (NSString *)displayNameForFontKind:(ZSFontKind)kind;

+ (NSString *)displayNameForFontRole:(ZSFontRole)role;

@end

extern NSString * const BankTransplantErrorDomain;

typedef NS_ENUM(NSInteger, BankTransplantErrorCode) {
    BankTransplantErrorCantReadModded = 1,
    BankTransplantErrorOriginalNotFound,
    BankTransplantErrorBackupFailed,
    BankTransplantErrorWriteFailed,
};

@interface BankTransplant : NSObject

+ (NSString *)mobileFMODBuildsDirectory;

+ (NSString *)bankBackupDirectory;

+ (BOOL)transplantAndSwapModdedBankAtURL:(NSURL *)moddedURL
                                    error:(NSError **)error;

+ (NSInteger)restoreAllBackedUpBanksWithError:(NSError **)error;

+ (NSInteger)restoreAllBackedUpBanksForce:(BOOL)force error:(NSError **)error;

+ (NSInteger)restoreBackedUpBankNamed:(NSString *)name error:(NSError **)error;

+ (nullable NSDictionary<NSString *, id> *)fmodHeaderInfoForBankAtPath:(NSString *)path;

+ (NSArray<NSString *> *)documentsRelativePathsOfSwappedBanks;

@end

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

+ (NSArray<NSString *> *)documentsRelativePathsOfSwappedFiles;

@end

extern NSString * const LunartiqueModArchiveErrorDomain;

typedef NS_ENUM(NSInteger, LunartiqueModArchiveErrorCode) {
    LunartiqueModArchiveErrorCantReadFile = 1,
    LunartiqueModArchiveErrorNotAZip,
    LunartiqueModArchiveErrorNoMatchingTree,
    LunartiqueModArchiveErrorUnsupportedCompression,
    LunartiqueModArchiveErrorCorruptEntry,
    LunartiqueModArchiveErrorExtractionFailed,
};

@interface LunartiqueModEntry : NSObject
@property (nonatomic, copy, readonly) NSString *cacheHash1;
@property (nonatomic, copy, readonly) NSString *cacheHash2;
@property (nonatomic, copy, readonly) NSString *dataEntryName;
@end

@interface LunartiqueModArchive : NSObject

+ (BOOL)isLunartiqueFormatZipAtURL:(NSURL *)zipURL error:(NSError * _Nullable * _Nullable)error;

+ (nullable NSArray<LunartiqueModEntry *> *)matchedEntriesInZipAtURL:(NSURL *)zipURL error:(NSError **)error;

+ (BOOL)extractDataForEntry:(LunartiqueModEntry *)entry
                   fromZipAtURL:(NSURL *)zipURL
                        dataURL:(NSURL * _Nullable * _Nonnull)outDataURL
                          error:(NSError **)error;

+ (nullable NSArray<NSString *> *)matchedBankEntryNamesInZipAtURL:(NSURL *)zipURL error:(NSError **)error;

+ (nullable NSArray<NSString *> *)allEntryNamesInZipAtURL:(NSURL *)zipURL error:(NSError **)error;

+ (BOOL)extractAllEntriesOfZipAtURL:(NSURL *)zipURL
                     toDirectoryURL:(NSURL *)directoryURL
                              error:(NSError **)error;

+ (BOOL)extractBankEntryNamed:(NSString *)entryName
                   fromZipAtURL:(NSURL *)zipURL
                        bankURL:(NSURL * _Nullable * _Nonnull)outBankURL
                          error:(NSError **)error;

@end

@interface Carra2ArchiveInfo : NSObject
@property (nonatomic, copy, readonly) NSString *hash1;
@property (nonatomic, copy, readonly) NSString *hash2;
@end

@interface Carra2ModArchive : NSObject

+ (nullable Carra2ArchiveInfo *)archiveInfoForZipAtURL:(NSURL *)zipURL error:(NSError **)error;

@end

extern NSString * const ModAssetLibraryErrorDomain;
extern NSString * const ModAssetLibraryOverlapPhrase;

typedef NS_ENUM(NSInteger, ModAssetLibraryErrorCode) {
    ModAssetLibraryErrorInvalidFolderName = 1,
    ModAssetLibraryErrorFolderAlreadyExists,
    ModAssetLibraryErrorFolderNotFound,
    ModAssetLibraryErrorCopyFailed,
    ModAssetLibraryErrorManifestReadFailed,
    ModAssetLibraryErrorManifestWriteFailed,
    ModAssetLibraryErrorDeleteFailed,
    ModAssetLibraryErrorEntryNotFound,
    ModAssetLibraryErrorCABNotIndexed,
    ModAssetLibraryErrorTargetOverlap,
};

typedef NS_ENUM(NSInteger, ModAssetLibraryDoctorStatus) {
    ModAssetLibraryDoctorStatusNotDispatched = 0,
    ModAssetLibraryDoctorStatusUploading,
    ModAssetLibraryDoctorStatusProcessing,
    ModAssetLibraryDoctorStatusReadyToDownload,
    ModAssetLibraryDoctorStatusFailed,
    ModAssetLibraryDoctorStatusInstalled,
};

typedef NS_ENUM(NSInteger, ModAssetLibraryLocalizationKind) {
    ModAssetLibraryLocalizationKindNone = 0,
    ModAssetLibraryLocalizationKindJSON,
    ModAssetLibraryLocalizationKindPack,
};

@interface ModAssetLibraryEntry : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) unsigned long long byteSize;
@property (nonatomic, copy) NSString *dateAdded;

@property (nonatomic, assign) BOOL isAssetBundle;

@property (nonatomic, assign) ZSFontRole fontRole;

@property (nonatomic, copy, nullable) NSString *cabIdentifier;

@property (nonatomic, copy, nullable) NSNumber *targetPlatform;

@property (nonatomic, copy, nullable) NSString *livePathDescription;

@property (nonatomic, copy, nullable) NSString *resolvedInstallTargetPath;

@property (nonatomic, copy, nullable) NSString *zipCacheHash1;
@property (nonatomic, copy, nullable) NSString *zipCacheHash2;

@property (nonatomic, copy, nullable) NSString *remark;

@property (nonatomic, assign) ModAssetLibraryLocalizationKind localizationKind;

@property (nonatomic, copy, nullable) NSString *localizationLanguage;

@property (nonatomic, copy, nullable) NSString *localizationRelativePath;

@property (nonatomic, copy, nullable) NSString *cachedFromFolder;

@property (nonatomic, copy, nullable) NSString *currentFolder;

@property (nonatomic, assign) ModAssetLibraryDoctorStatus doctorStatus;

@property (nonatomic, assign) int64_t doctorUploadProgress;
@property (nonatomic, assign) int64_t doctorUploadTotalBytes;
@property (nonatomic, assign) double doctorProcessProgress;

@property (nonatomic, assign) int64_t doctorDownloadProgress;
@property (nonatomic, assign) unsigned long long doctorDispatchCompressedByteSize;
@property (nonatomic, copy, nullable) NSString *doctorScratchBranch;
@property (nonatomic, copy, nullable) NSString *doctorRunID;
@property (nonatomic, copy, nullable) NSString *doctorRunURL;
@property (nonatomic, copy, nullable) NSString *doctorLastError;
@property (nonatomic, copy, nullable) NSString *doctorTranscodeCodec;
@end

@interface ModAssetLibrary : NSObject

+ (NSString *)liveGamePathDescriptionForInstalledURL:(NSURL *)installedURL;

+ (NSString *)modLibraryRootDirectory;

+ (NSString *)originalBundleBackupsDirectory;

+ (NSArray<NSString *> *)folderNames;

+ (BOOL)createFolderNamed:(NSString *)name error:(NSError **)error;

+ (nullable NSString *)createUniqueSubFolderNamed:(NSString *)desiredName
                                       insideFolder:(NSString *)parentFolder
                                              error:(NSError **)error;

+ (NSArray<NSString *> *)subFolderNamesInFolder:(NSString *)parentFolder;

+ (nullable ModAssetLibraryEntry *)activeEntryOverlappingEntry:(ModAssetLibraryEntry *)candidate;

+ (nullable ModAssetLibraryEntry *)activeEntryOverlappingBankNamed:(NSString *)bankFileName;

+ (NSString *)displayNameForEntry:(ModAssetLibraryEntry *)entry;

+ (NSString *)overlapRejectionLineForName:(NSString *)name existingEntry:(ModAssetLibraryEntry *)existing;

+ (NSString *)overlapReasonForExistingEntry:(ModAssetLibraryEntry *)existing;

+ (nullable NSArray<ModAssetLibraryEntry *> *)entriesInFolder:(NSString *)folderName error:(NSError **)error;

+ (nullable ModAssetLibraryEntry *)fontEntryOccupyingRole:(ZSFontRole)role;

+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs
             intoFolder:(NSString *)folderName
              fontRoles:(nullable NSDictionary<NSString *, NSNumber *> *)fontRoles
        rejectedFileLines:(NSArray<NSString *> * _Nullable * _Nullable)rejectedFileLines
                  error:(NSError **)error;

+ (BOOL)importLunartiqueZipURL:(NSURL *)zipURL
                    intoFolder:(NSString *)folderName
             rejectedEntryLines:(NSArray<NSString *> * _Nullable * _Nullable)rejectedEntryLines
                         error:(NSError **)error;

+ (void)importLocalizationJSONURLs:(NSArray<NSURL *> *)jsonURLs
                          language:(NSString *)languageCode
                        intoFolder:(NSString *)folderName
                      summaryLines:(NSMutableArray<NSString *> *)summaryLines;

+ (void)importLocalizationPackFolderURL:(NSURL *)folderURL
                               language:(NSString *)languageCode
                             intoFolder:(NSString *)folderName
                           summaryLines:(NSMutableArray<NSString *> *)summaryLines;

+ (void)importLocalizationPackZipURL:(NSURL *)zipURL
                            language:(NSString *)languageCode
                          intoFolder:(NSString *)folderName
                        summaryLines:(NSMutableArray<NSString *> *)summaryLines;

+ (BOOL)importCarra2URL:(NSURL *)carra2URL
              intoFolder:(NSString *)folderName
                   error:(NSError **)error;

+ (BOOL)activateFontForEntry:(ModAssetLibraryEntry *)entry error:(NSError **)error;

+ (void)deactivateFontForEntry:(ModAssetLibraryEntry *)entry;

+ (BOOL)removeEntry:(ModAssetLibraryEntry *)entry fromFolder:(NSString *)folderName error:(NSError **)error;

+ (nullable ModAssetLibraryEntry *)moveEntry:(ModAssetLibraryEntry *)entry
                                   fromFolder:(NSString *)fromFolder
                                     toFolder:(NSString *)toFolder
                          replacementBytesURL:(nullable NSURL *)replacementBytesURL
                                        error:(NSError **)error;

+ (nullable ModAssetLibraryEntry *)replaceEntry:(ModAssetLibraryEntry *)entry
                                        inFolder:(NSString *)folderName
                       withDownloadedBundleAtURL:(NSURL *)bundleURL
                                           error:(NSError **)error;

+ (nullable ModAssetLibraryEntry *)updateDoctorStateForEntry:(ModAssetLibraryEntry *)entry
                                                      inFolder:(NSString *)folderName
                                                    applyBlock:(void (NS_NOESCAPE ^)(ModAssetLibraryEntry *entryToMutate))applyBlock
                                                         error:(NSError **)error;

+ (BOOL)deleteFolderNamed:(NSString *)folderName error:(NSError **)error;

+ (BOOL)renameFolderNamed:(NSString *)folderName to:(NSString *)newName error:(NSError **)error;

+ (nullable NSString *)remarkForFolder:(NSString *)folderName;

+ (BOOL)setRemark:(nullable NSString *)remark forFolder:(NSString *)folderName error:(NSError **)error;

+ (BOOL)deleteAllFoldersWithError:(NSError **)error;

@end

void zs_schedule_font_apply(void);

NS_ASSUME_NONNULL_END
