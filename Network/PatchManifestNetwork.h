
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PatchManifestNetwork : NSObject
+ (void)install;
+ (void)uninstall;

+ (BOOL)isZeroAllEnabled;
+ (void)setZeroAllEnabled:(BOOL)enabled;
@end

NS_ASSUME_NONNULL_END

