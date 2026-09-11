
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZCrashLogger : NSObject

+ (void)install;

+ (NSString *)crashLogPath;

@end

@interface ZSyslogController : NSObject

+ (instancetype)sharedController;

- (BOOL)start;

- (void)stop;

@property (nonatomic, readonly, getter=isRunning) BOOL running;

@property (nonatomic, copy, nullable) void (^lineHandler)(NSString *line);

@end

NS_ASSUME_NONNULL_END
