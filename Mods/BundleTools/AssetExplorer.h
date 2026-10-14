#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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
    ZSAssetExplorerErrorAssetNotFound,
    ZSAssetExplorerErrorTextureUnsupported,
    ZSAssetExplorerErrorTextureDecodeFailed,
};

@interface ZSAssetExplorerBundle : NSObject
@property (nonatomic, copy) NSString *cabIdentifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, assign) BOOL nameResolved;
@end

@interface ZSAssetExplorerAsset : NSObject
@property (nonatomic, assign) int64_t pathID;
@property (nonatomic, assign) int32_t classID;
@property (nonatomic, copy) NSString *typeName;
@property (nonatomic, copy, nullable) NSString *assetName;
@property (nonatomic, assign) uint32_t objectSize;
@property (nonatomic, assign) uint64_t byteStart;
@end

@interface ZSAssetExplorerTexture : NSObject
@property (nonatomic, strong, nullable) UIImage *image;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) int32_t format;
@property (nonatomic, copy) NSString *formatName;
@end

typedef UIImage * _Nullable (^ZSAssetExplorerPageProvider)(NSInteger page, NSError * _Nullable * _Nullable error);
typedef UIImage * _Nullable (^ZSAssetExplorerLiveFrameProvider)(NSTimeInterval elapsed);
typedef NSString * _Nullable (^ZSAssetExplorerLiveDebugProvider)(NSTimeInterval elapsed);

@interface ZSAssetExplorerVisual : NSObject
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSArray<NSString *> *pageLabels;
@property (nonatomic, copy, nullable) ZSAssetExplorerPageProvider imageProvider;
@property (nonatomic, copy, nullable) ZSAssetExplorerLiveFrameProvider liveFrameProvider;
@property (nonatomic, copy, nullable) ZSAssetExplorerLiveDebugProvider liveDebugProvider;
@property (nonatomic, copy, nullable) NSString *debugText;
@property (nonatomic, assign) NSInteger livePageIndex;
@property (nonatomic, copy, nullable) NSString *text;
@property (nonatomic, copy, nullable) NSData *exportData;
@property (nonatomic, copy, nullable) NSString *fileExtension;
- (BOOL)isLivePage:(NSInteger)page;
- (nullable UIImage *)imageAtPage:(NSInteger)page error:(NSError * _Nullable * _Nullable)error;
@end

@interface ZSAssetExplorer : NSObject
+ (NSArray<ZSAssetExplorerBundle *> *)cachedBundles:(NSError **)error;
+ (void)resolveNamesForBundles:(NSArray<ZSAssetExplorerBundle *> *)bundles
                     batchSize:(NSUInteger)batchSize
                shouldContinue:(nullable BOOL (^)(void))shouldContinue
                       handler:(void (^)(NSArray<ZSAssetExplorerBundle *> *updated))handler;
+ (BOOL)loadBundleIntoMemoryAtPath:(NSString *)path error:(NSError **)error;
+ (void)unloadBundleAtPath:(NSString *)path;
+ (void)unloadAllBundles;
+ (nullable UIImage *)thumbnailForPathID:(int64_t)pathID classID:(int32_t)classID inBundleAtPath:(NSString *)path maxDimension:(CGFloat)maxDimension error:(NSError **)error;
+ (NSArray<ZSAssetExplorerAsset *> *)assetsForBundleAtPath:(NSString *)path error:(NSError **)error;
+ (nullable ZSAssetExplorerTexture *)textureForPathID:(int64_t)pathID inBundleAtPath:(NSString *)path error:(NSError **)error;
+ (BOOL)hasVisualPreviewForClassID:(int32_t)classID;
+ (BOOL)classID:(int32_t)a sharesPreviewGroupWithClassID:(int32_t)b;
+ (nullable ZSAssetExplorerVisual *)visualForPathID:(int64_t)pathID classID:(int32_t)classID inBundleAtPath:(NSString *)path error:(NSError **)error;
+ (nullable NSData *)jsonDataForPathID:(int64_t)pathID inBundleAtPath:(NSString *)path error:(NSError **)error;
+ (nullable NSString *)exportAssetAtPathID:(int64_t)pathID inBundleAtPath:(NSString *)path toDirectory:(NSString *)directory error:(NSError **)error;
+ (nullable NSString *)fullExportAssetAtPathID:(int64_t)pathID inBundleAtPath:(NSString *)path toDirectory:(NSString *)directory error:(NSError **)error;
+ (nullable NSString *)fullExportAssetAtPathID:(int64_t)pathID inBundleAtPath:(NSString *)path toDirectory:(NSString *)directory jsonOnly:(BOOL)jsonOnly error:(NSError **)error;
@end

extern NSString * const ZSFMODErrorDomain;

typedef NS_ENUM(NSInteger, ZSFMODExportFormat) {
    ZSFMODExportFormatFSB = 0,
    ZSFMODExportFormatRaw,
    ZSFMODExportFormatWAV,
};

@interface ZSFMODBankFile : NSObject
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, assign) unsigned long long fileSize;
@property (nonatomic, assign) NSInteger streamCount;
@property (nonatomic, copy, nullable) NSString *codecName;
@end

@interface ZSFMODStream : NSObject
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) NSInteger fsbIndex;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint32_t mode;
@property (nonatomic, copy) NSString *codecName;
@property (nonatomic, assign) NSInteger channels;
@property (nonatomic, assign) NSInteger frequency;
@property (nonatomic, assign) uint64_t sampleCount;
@property (nonatomic, assign) uint64_t dataOffset;
@property (nonatomic, assign) uint64_t dataSize;
@property (nonatomic, assign) uint64_t sampleHeaderOffset;
@property (nonatomic, assign) uint32_t sampleHeaderLength;
@property (nonatomic, assign) uint64_t fsbBase;
@property (nonatomic, assign) uint32_t fsbHeaderSize;
@property (nonatomic, assign) BOOL hasLoop;
@property (nonatomic, assign) uint32_t loopStart;
@property (nonatomic, assign) uint32_t loopEnd;
@property (nonatomic, assign) BOOL hasVorbisCRC;
@property (nonatomic, assign) uint32_t vorbisCRC;
@property (nonatomic, copy) NSArray<NSString *> *chunkSummaries;
@property (nonatomic, readonly) NSTimeInterval duration;
@end

@interface ZSFMODBank : NSObject
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, assign) unsigned long long fileSize;
@property (nonatomic, assign) uint32_t formatVersion;
@property (nonatomic, assign) NSInteger fsbCount;
@property (nonatomic, copy) NSArray<ZSFMODStream *> *streams;
@property (nonatomic, strong) NSData *data;
@end

@interface ZSFMODExplorer : NSObject
+ (NSString *)banksDirectory;
+ (NSArray<ZSFMODBankFile *> *)availableBanks:(NSError **)error;
+ (nullable ZSFMODBank *)openBankAtPath:(NSString *)path error:(NSError **)error;
+ (NSString *)detailTextForStream:(ZSFMODStream *)stream inBank:(ZSFMODBank *)bank;
+ (BOOL)canExportWAVForStream:(ZSFMODStream *)stream;
+ (nullable NSString *)exportStream:(ZSFMODStream *)stream inBank:(ZSFMODBank *)bank format:(ZSFMODExportFormat)format toDirectory:(NSString *)directory error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
