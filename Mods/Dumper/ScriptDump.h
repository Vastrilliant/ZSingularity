#import <Foundation/Foundation.h>
#import "Dumper.h"

NS_ASSUME_NONNULL_BEGIN

@interface ZSScriptDump : NSObject
+ (nullable NSDictionary *)generateIntoFolder:(NSString *)folder
                                      options:(ZSDumpOptions *)options
                                     progress:(nullable ZSDumpProgress)progress
                                          log:(nullable ZSDumpLog)log
                                    cancelled:(nullable BOOL (^)(void))cancelled
                                        error:(NSError * _Nullable * _Nullable)error;
+ (NSUInteger)exportScriptsIntoFolder:(NSString *)folder error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
