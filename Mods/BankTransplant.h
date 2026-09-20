
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BankTransplantErrorDomain;

typedef NS_ENUM(NSInteger, BankTransplantErrorCode) {
    BankTransplantErrorCantReadModded = 1,
    BankTransplantErrorOriginalNotFound,
    BankTransplantErrorBackupFailed,
    BankTransplantErrorWriteFailed,
};

@interface BankTransplant : NSObject

+ (NSString *)mobileFMODBuildsDirectory;

+ (NSString *)bankBackupDirectory;

+ (BOOL)transplantAndSwapModdedBankAtURL:(NSURL *)moddedURL
                                    error:(NSError **)error;

+ (NSInteger)restoreAllBackedUpBanksWithError:(NSError **)error;

+ (NSInteger)restoreAllBackedUpBanksForce:(BOOL)force error:(NSError **)error;

+ (NSInteger)restoreBackedUpBankNamed:(NSString *)name error:(NSError **)error;

+ (nullable NSDictionary<NSString *, id> *)fmodHeaderInfoForBankAtPath:(NSString *)path;

+ (NSArray<NSString *> *)documentsRelativePathsOfSwappedBanks;

@end

NS_ASSUME_NONNULL_END

