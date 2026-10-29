#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TexCompMode) {
    TexCompModeScan = 0,
    TexCompModeTranscode = 1,
};

typedef struct {
    BOOL running;
    BOOL paused;
    BOOL cancelled;
    TexCompMode mode;
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
} TexCompStatus;

@interface TexComp : NSObject

+ (instancetype)shared;
+ (NSString *)stagingDirectory;
+ (nullable NSString *)mergeOriginalsIntoDirectory:(NSString *)destination copied:(nullable NSUInteger *)copiedOut;
+ (nullable NSString *)restoreMissingFilesIntoDirectory:(NSString *)directory fromBackup:(NSString *)backup restored:(nullable NSUInteger *)restoredOut;

- (BOOL)prepareWithCompletion:(void (^)(NSUInteger textures, NSUInteger bundles, BOOL ok))completion;
- (BOOL)startWithMode:(TexCompMode)mode blockSize:(NSUInteger)blockSize completion:(nullable void (^)(TexCompStatus status))completion;
- (void)cancel;
- (TexCompStatus)status;
- (NSString *)statusLine;
- (NSString *)summary;

@end

NS_ASSUME_NONNULL_END
