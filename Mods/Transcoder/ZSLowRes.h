#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define ZSLowResQualityDefault 3

typedef NS_ENUM(NSInteger, ZSLowResMode) {
    ZSLowResModeScan = 0,
    ZSLowResModeTranscode = 1,
};

typedef struct {
    BOOL running;
    BOOL paused;
    BOOL cancelled;
    ZSLowResMode mode;
    NSUInteger bundlesTotal;
    NSUInteger bundlesDone;
    NSUInteger bundlesChanged;
    NSUInteger bundlesSkipped;
    NSUInteger bundlesDeferred;
    NSUInteger bundlesFailed;
    NSUInteger texturesConverted;
    NSUInteger texturesRejected;
    NSUInteger texturesCandidate;
    uint64_t candidateBytes;
    uint64_t originalBytes;
    uint64_t newBytes;
    NSUInteger activeWorkers;
    NSUInteger allowedWorkers;
    BOOL preparing;
    NSUInteger texturesTotal;
    NSUInteger texturesProcessed;
    NSUInteger currentBundleTotal;
    NSUInteger currentBundleProcessed;
    double etaSeconds;
} ZSLowResStatus;

@interface ZSLowRes : NSObject

+ (instancetype)shared;
+ (NSString *)stagingDirectory;
+ (nullable NSString *)mergeOriginalsIntoDirectory:(NSString *)destination copied:(nullable NSUInteger *)copiedOut;
+ (nullable NSString *)restoreMissingFilesIntoDirectory:(NSString *)directory fromBackup:(NSString *)backup restored:(nullable NSUInteger *)restoredOut;

- (BOOL)prepareWithCompletion:(void (^)(NSUInteger textures, NSUInteger bundles, BOOL ok))completion;
- (BOOL)startWithMode:(ZSLowResMode)mode blockSize:(NSUInteger)blockSize completion:(nullable void (^)(ZSLowResStatus status))completion;
- (void)cancel;
- (ZSLowResStatus)status;
- (NSString *)statusLine;
- (NSString *)summary;

@end

NS_ASSUME_NONNULL_END
