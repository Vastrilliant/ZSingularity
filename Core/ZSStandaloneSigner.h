#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ZSStandaloneSignerErrorDomain;

@interface ZSStandaloneSigner : NSObject

+ (NSProgress *)signMachOPathArr:(NSArray<NSString *> *)machoPathArr
                         bundleId:(NSString *)bundleId
                             cert:(NSData *)cert
                             pass:(NSString *)pass
                completionHandler:(void (^)(BOOL success, NSError * _Nullable error))completionHandler;

@end

NS_ASSUME_NONNULL_END
