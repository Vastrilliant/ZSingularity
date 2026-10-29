#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZSDumpOptions : NSObject <NSCopying>
@property (nonatomic) BOOL dumpSource;
@property (nonatomic) BOOL dumpBodies;
@property (nonatomic) BOOL copyBinaries;
@property (nonatomic) BOOL scriptMethods;
@property (nonatomic) BOOL genericMethods;
@property (nonatomic) BOOL metadataUsages;
@property (nonatomic) BOOL addresses;
@property (nonatomic) BOOL stringLiterals;
@property (nonatomic) BOOL exportScripts;
@property (nonatomic) BOOL minifyJSON;
+ (instancetype)savedOptions;
- (void)save;
- (void)resetToDefaults;
@end

typedef void (^ZSDumpProgress)(NSString *stage, double fraction);
typedef void (^ZSDumpLog)(NSString *line);

@interface ZSDumper : NSObject
+ (void)dumpIL2CPPToDocumentsWithCompletion:(void (^ _Nullable)(NSURL * _Nullable outputURL, NSError * _Nullable error))completion;
+ (void)dumpWithOptions:(ZSDumpOptions *)options
               progress:(nullable ZSDumpProgress)progress
                    log:(nullable ZSDumpLog)log
             completion:(void (^ _Nullable)(NSURL * _Nullable outputURL, NSError * _Nullable error))completion;
+ (void)diffBinariesWithIPAAtURL:(NSURL *)ipaURL
                        progress:(nullable ZSDumpProgress)progress
                             log:(nullable ZSDumpLog)log
                      completion:(void (^ _Nullable)(NSURL * _Nullable outputURL, NSError * _Nullable error))completion;
+ (void)cancel;
+ (BOOL)isRunning;
+ (nullable NSDictionary *)lastSummary;
+ (nullable NSURL *)lastOutputURL;
@end

NS_ASSUME_NONNULL_END
