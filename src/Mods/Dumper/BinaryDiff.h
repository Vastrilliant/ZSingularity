#import <Foundation/Foundation.h>
#import "Dumper.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ZSBinaryDiffErrorDomain;

typedef NS_ENUM(NSInteger, ZSBinaryDiffErrorCode) {
    ZSBinaryDiffErrorCancelled = 9,
    ZSBinaryDiffErrorInvalidInput = 30,
    ZSBinaryDiffErrorBadArchive = 31,
    ZSBinaryDiffErrorMissingEntry = 32,
    ZSBinaryDiffErrorIO = 33,
    ZSBinaryDiffErrorIdentical = 34,
    ZSBinaryDiffErrorBadBinary = 35
};

@interface ZSBinaryDiff : NSObject
+ (nullable NSURL *)diffIPAAtURL:(NSURL *)ipaURL
              installedFramework:(nullable NSString *)installedFramework
               installedMetadata:(nullable NSString *)installedMetadata
                      outputRoot:(NSString *)outputRoot
                        progress:(nullable ZSDumpProgress)progress
                             log:(nullable ZSDumpLog)log
                       cancelled:(nullable BOOL (^)(void))cancelled
                         summary:(NSDictionary * _Nullable * _Nullable)summary
                           error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
