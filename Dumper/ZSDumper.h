#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZSDumper : NSObject
+ (void)dumpIL2CPPToDocumentsWithCompletion:(void (^ _Nullable)(NSURL * _Nullable outputURL, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
