
#ifndef ZTweakLog_h
#define ZTweakLog_h

#import <Foundation/Foundation.h>

static NSString * const kZLogTag = @"[ZSingularity]";

#define ZLog(fmt, ...) NSLog(@"%@ " fmt, kZLogTag, ##__VA_ARGS__)

#endif

