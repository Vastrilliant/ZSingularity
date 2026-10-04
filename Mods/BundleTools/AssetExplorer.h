#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ZSAssetExplorerErrorDomain;

typedef NS_ENUM(NSInteger, ZSAssetExplorerErrorCode) {
    ZSAssetExplorerErrorSharedDirectoryNotFound = 1,
    ZSAssetExplorerErrorNoBundles,
    ZSAssetExplorerErrorBundleUnreadable,
    ZSAssetExplorerErrorBundleMalformed,
    ZSAssetExplorerErrorSerializedFileMalformed,
    ZSAssetExplorerErrorUnsupportedCompression,
    ZSAssetExplorerErrorUnsupportedSerializedFile,
};

@interface ZSAssetExplorerBundle : NSObject
@property (nonatomic, copy) NSString *cabIdentifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *filePath;
@end

@interface ZSAssetExplorerAsset : NSObject
@property (nonatomic, assign) int64_t pathID;
@property (nonatomic, assign) int32_t classID;
@property (nonatomic, copy) NSString *typeName;
@property (nonatomic, copy, nullable) NSString *assetName;
@property (nonatomic, assign) uint32_t objectSize;
@end

@interface ZSAssetExplorer : NSObject
+ (NSArray<ZSAssetExplorerBundle *> *)cachedBundles:(NSError **)error;
+ (NSArray<ZSAssetExplorerAsset *> *)assetsForBundleAtPath:(NSString *)path error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
