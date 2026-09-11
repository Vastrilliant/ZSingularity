#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MetalHUDController : NSObject

+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)enabled;

+ (void)install;

@end

NS_ASSUME_NONNULL_END
