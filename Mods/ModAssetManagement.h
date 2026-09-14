
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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
};

typedef NS_ENUM(NSInteger, ModAssetLibraryDoctorStatus) {
    ModAssetLibraryDoctorStatusNotDispatched = 0,
    ModAssetLibraryDoctorStatusUploading,
    ModAssetLibraryDoctorStatusProcessing,
    ModAssetLibraryDoctorStatusReadyToDownload,
    ModAssetLibraryDoctorStatusFailed,
    ModAssetLibraryDoctorStatusInstalled,
};

@interface ModAssetLibraryEntry : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) unsigned long long byteSize;
@property (nonatomic, copy) NSString *dateAdded;

@property (nonatomic, assign) BOOL isAssetBundle;

@property (nonatomic, copy, nullable) NSString *cabIdentifier;

@property (nonatomic, copy, nullable) NSNumber *targetPlatform;

@property (nonatomic, copy, nullable) NSString *livePathDescription;

@property (nonatomic, copy, nullable) NSString *resolvedInstallTargetPath;

@property (nonatomic, copy, nullable) NSString *zipCacheHash1;
@property (nonatomic, copy, nullable) NSString *zipCacheHash2;

@property (nonatomic, copy, nullable) NSString *remark;

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

+ (nullable NSArray<ModAssetLibraryEntry *> *)entriesInFolder:(NSString *)folderName error:(NSError **)error;

+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs
             intoFolder:(NSString *)folderName
        rejectedFileLines:(NSArray<NSString *> * _Nullable * _Nullable)rejectedFileLines
                  error:(NSError **)error;

+ (BOOL)importLunartiqueZipURL:(NSURL *)zipURL
                    intoFolder:(NSString *)folderName
             rejectedEntryLines:(NSArray<NSString *> * _Nullable * _Nullable)rejectedEntryLines
                         error:(NSError **)error;

+ (BOOL)importCarra2URL:(NSURL *)carra2URL
              intoFolder:(NSString *)folderName
                   error:(NSError **)error;

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

NS_ASSUME_NONNULL_END
