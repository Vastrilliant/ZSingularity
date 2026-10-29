
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZCrashLogger : NSObject

+ (void)install;

+ (void)reinstallHandlersIfNeeded;

+ (NSString *)crashLogPath;

+ (nullable NSDictionary<NSString *, id> *)pendingCrashReport;

+ (void)clearPendingCrashReport;

+ (void)killProcessWithSIGKILL;

@end

@interface ZSyslogController : NSObject

+ (instancetype)sharedController;

- (BOOL)start;

- (void)stop;

@property (nonatomic, readonly, getter=isRunning) BOOL running;

@property (nonatomic, copy, nullable) void (^lineHandler)(NSString *line);

@property (nonatomic, copy, nullable) void (^linesHandler)(NSArray<NSString *> *lines);

@end

NS_ASSUME_NONNULL_END
