
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZSFontKind) {
    ZSFontKindUnknown = 0,
    ZSFontKindTrueType,
    ZSFontKindOpenType,
};

@interface ZSModsPaths : NSObject

+ (NSString *)modsRootDirectory;

+ (NSString *)modsLibraryDirectory;

+ (NSString *)modsBackupsDirectory;

+ (NSString *)modsBackupsLocalizeDirectory;

+ (NSString *)modsBackupsBanksDirectory;

+ (NSString *)modsBackupsAssetsDirectory;

+ (NSString *)modsFontsDirectory;

+ (nullable NSString *)ensuredDirectoryAtPath:(nullable NSString *)path;

+ (void)migrateLegacyDirectoryAtPath:(nullable NSString *)oldPath toPath:(nullable NSString *)newPath;

+ (ZSFontKind)fontKindForFileName:(NSString *)fileName;

+ (NSString *)displayNameForFontKind:(ZSFontKind)kind;

@end

NS_ASSUME_NONNULL_END
