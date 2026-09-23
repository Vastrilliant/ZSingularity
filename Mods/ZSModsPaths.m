
#import "ZSModsPaths.h"

static NSString * const kZSModsRootDirectoryName = @"Mods";
static NSString * const kZSModsLibraryDirectoryName = @"library";
static NSString * const kZSModsBackupsDirectoryName = @"backups";
static NSString * const kZSModsBackupsLocalizeDirectoryName = @"Localize";
static NSString * const kZSModsBackupsBanksDirectoryName = @"Banks";
static NSString * const kZSModsBackupsAssetsDirectoryName = @"Assets";
static NSString * const kZSModsFontsDirectoryName = @"Fonts";

@implementation ZSModsPaths

+ (nullable NSString *)documentsDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject;
}

+ (NSString *)modsRootDirectory {
    NSString *documentsDir = [self documentsDirectory];
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:kZSModsRootDirectoryName];
}

+ (NSString *)modsLibraryDirectory {
    NSString *root = [self modsRootDirectory];
    if (!root) return nil;
    return [root stringByAppendingPathComponent:kZSModsLibraryDirectoryName];
}

+ (NSString *)modsBackupsDirectory {
    NSString *root = [self modsRootDirectory];
    if (!root) return nil;
    return [root stringByAppendingPathComponent:kZSModsBackupsDirectoryName];
}

+ (NSString *)modsBackupsLocalizeDirectory {
    NSString *backups = [self modsBackupsDirectory];
    if (!backups) return nil;
    return [backups stringByAppendingPathComponent:kZSModsBackupsLocalizeDirectoryName];
}

+ (NSString *)modsBackupsBanksDirectory {
    NSString *backups = [self modsBackupsDirectory];
    if (!backups) return nil;
    return [backups stringByAppendingPathComponent:kZSModsBackupsBanksDirectoryName];
}

+ (NSString *)modsBackupsAssetsDirectory {
    NSString *backups = [self modsBackupsDirectory];
    if (!backups) return nil;
    return [backups stringByAppendingPathComponent:kZSModsBackupsAssetsDirectoryName];
}

+ (NSString *)modsFontsDirectory {
    NSString *root = [self modsRootDirectory];
    if (!root) return nil;
    return [root stringByAppendingPathComponent:kZSModsFontsDirectoryName];
}

+ (nullable NSString *)ensuredDirectoryAtPath:(nullable NSString *)path {
    if (!path) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
        return isDir ? path : nil;
    }
    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        return nil;
    }
    return path;
}

+ (void)migrateLegacyDirectoryAtPath:(nullable NSString *)oldPath toPath:(nullable NSString *)newPath {
    if (oldPath.length == 0 || newPath.length == 0) return;
    NSFileManager *fm = NSFileManager.defaultManager;

    BOOL oldIsDir = NO;
    if (![fm fileExistsAtPath:oldPath isDirectory:&oldIsDir] || !oldIsDir) return;
    if ([fm fileExistsAtPath:newPath]) return;

    NSString *newParent = newPath.stringByDeletingLastPathComponent;
    if (![self ensuredDirectoryAtPath:newParent]) return;

    NSError *moveErr = nil;
    if (![fm moveItemAtPath:oldPath toPath:newPath error:&moveErr]) {
        NSError *copyErr = nil;
        if ([fm copyItemAtPath:oldPath toPath:newPath error:&copyErr]) {
            [fm removeItemAtPath:oldPath error:nil];
        }
    }
}

+ (ZSFontKind)fontKindForFileName:(NSString *)fileName {
    NSString *ext = fileName.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"ttf"]) return ZSFontKindTrueType;
    if ([ext isEqualToString:@"otf"]) return ZSFontKindOpenType;
    return ZSFontKindUnknown;
}

+ (NSString *)displayNameForFontKind:(ZSFontKind)kind {
    switch (kind) {
        case ZSFontKindTrueType: return @"TrueType Font";
        case ZSFontKindOpenType: return @"OpenType Font";
        default: return @"Unknown Font";
    }
}

@end
