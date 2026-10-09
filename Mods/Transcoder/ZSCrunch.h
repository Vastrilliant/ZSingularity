#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t levels;
    uint32_t faces;
    uint32_t bytesPerBlock;
    uint32_t crnFormat;
    uint32_t userdata0;
    uint32_t userdata1;
} ZSCrunchInfo;

FOUNDATION_EXPORT BOOL ZSCrunchReadInfo(NSData *data, ZSCrunchInfo *outInfo, NSString * _Nullable * _Nullable outFailure);

FOUNDATION_EXPORT NSData * _Nullable ZSCrunchUnpackLevel(NSData *data, uint32_t level, uint32_t *outWidth, uint32_t *outHeight, uint32_t *outBytesPerBlock, NSString * _Nullable * _Nullable outFailure);

NS_ASSUME_NONNULL_END
