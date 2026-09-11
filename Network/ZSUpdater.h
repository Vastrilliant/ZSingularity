
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZSDylibUpdater : NSObject

+ (BOOL)isRunningUnderLiveContainer;

+ (BOOL)isStandaloneInstall;

+ (nullable NSString *)installedDylibPath;

+ (void)replaceInstalledDylibWithData:(NSData *)data
                             completion:(void (^)(BOOL success, NSString *message))completion;

+ (nullable NSString *)selfLoadedDylibPath;

+ (void)replaceSelfDylibWithData:(NSData *)data
                        completion:(void (^)(BOOL success, NSString *message))completion;

@end

extern NSString * const kZSUpdateRepoOwner;
extern NSString * const kZSUpdateRepoName;

typedef NS_ENUM(NSInteger, ZSUpdateCheckResult) {
    ZSUpdateCheckResultUpToDate,
    ZSUpdateCheckResultUpdateAvailable,
};

typedef NS_ENUM(NSInteger, ZSUpdateCheckMode) {
    ZSUpdateCheckModeReleases,
    ZSUpdateCheckModeNightlyReleases,
};

@interface ZSReleaseInfo : NSObject

@property (nonatomic, copy, readonly) NSString *version;
@property (nonatomic, copy, readonly, nullable) NSString *notesMarkdown;
@property (nonatomic, assign, readonly) BOOL hasDownloadableDylib;
@property (nonatomic, copy, readonly, nullable) NSString *htmlURL;

@end

@interface ZSUpdateChecker : NSObject

+ (void)checkForUpdateWithMode:(ZSUpdateCheckMode)mode
                     completion:(void (^)(ZSUpdateCheckResult result, NSString * _Nullable latestVersion))completion;

+ (void)fetchReleaseInfoWithMode:(ZSUpdateCheckMode)mode
                       completion:(void (^)(ZSReleaseInfo * _Nullable info, NSError * _Nullable error))completion;

+ (void)fetchReleaseInfoAtIndex:(NSUInteger)index
                             mode:(ZSUpdateCheckMode)mode
                       completion:(void (^)(ZSReleaseInfo * _Nullable info, BOOL hasOlder, BOOL hasNewer, NSError * _Nullable error))completion;

+ (void)fetchLatestDylibDataWithMode:(ZSUpdateCheckMode)mode
                           completion:(void (^)(NSData * _Nullable dylibData, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
