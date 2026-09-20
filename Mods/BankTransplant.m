
#import "BankTransplant.h"
#import "ZTweakLog.h"
#import "ZSEngine.h"
#import <CoreFoundation/CoreFoundation.h>

NSString * const BankTransplantErrorDomain = @"BankTransplantErrorDomain";

static NSError *BTError(BankTransplantErrorCode code, NSString *message) {
    return [NSError errorWithDomain:BankTransplantErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString * const kBTBackupSuffix = @".orig-bak";
static NSString * const kBTMobileBuildsRelativePath = @"Assets/Sound/FMODBuilds/Mobile";

@interface BankTransplant ()
+ (BOOL)bt_restoreOneBackupEntry:(NSString *)backupEntryName inBackupDir:(NSString *)backupDir mobileDir:(NSString *)mobileDir force:(BOOL)force;
+ (BOOL)bt_fileAtPath:(NSString *)pathA hasIdenticalBytesToFileAtPath:(NSString *)pathB;
@end

@implementation BankTransplant

+ (NSString *)mobileFMODBuildsDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:kBTMobileBuildsRelativePath];
}

+ (NSString *)bankBackupDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityBankBackups"];
}

+ (BOOL)transplantAndSwapModdedBankAtURL:(NSURL *)moddedURL error:(NSError **)error {
    BOOL accessing = [moddedURL startAccessingSecurityScopedResource];

    NSString *fileName = moddedURL.lastPathComponent;
    NSString *mobileDir = [self mobileFMODBuildsDirectory];
    NSString *originalPath = mobileDir ? [mobileDir stringByAppendingPathComponent:fileName] : nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (!originalPath || ![fm fileExistsAtPath:originalPath]) {
        if (accessing) [moddedURL stopAccessingSecurityScopedResource];
        if (error) *error = BTError(BankTransplantErrorOriginalNotFound,
            [NSString stringWithFormat:@"No stock bank named \"%@\" found under Assets/Sound/FMODBuilds/Mobile.", fileName]);
        return NO;
    }

    if (![fm isReadableFileAtPath:moddedURL.path]) {
        if (accessing) [moddedURL stopAccessingSecurityScopedResource];
        if (error) *error = BTError(BankTransplantErrorCantReadModded,
            [NSString stringWithFormat:@"Couldn't read the picked file %@.", fileName]);
        return NO;
    }

    NSString *backupDir = [self bankBackupDirectory];
    if (!backupDir) {
        if (accessing) [moddedURL stopAccessingSecurityScopedResource];
        if (error) *error = BTError(BankTransplantErrorBackupFailed, @"Couldn't resolve the backup directory.");
        return NO;
    }
    if (![fm fileExistsAtPath:backupDir]) {
        NSError *dirErr = nil;
        if (![fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
            if (accessing) [moddedURL stopAccessingSecurityScopedResource];
            if (error) *error = BTError(BankTransplantErrorBackupFailed,
                [NSString stringWithFormat:@"Couldn't create the backup directory: %@", dirErr.localizedDescription]);
            return NO;
        }
    }
    NSString *backupPath = [backupDir stringByAppendingPathComponent:[fileName stringByAppendingString:kBTBackupSuffix]];
    if (![fm fileExistsAtPath:backupPath]) {
        NSError *copyErr = nil;
        if (![fm copyItemAtPath:originalPath toPath:backupPath error:&copyErr]) {
            if (accessing) [moddedURL stopAccessingSecurityScopedResource];
            if (error) *error = BTError(BankTransplantErrorBackupFailed,
                [NSString stringWithFormat:@"Couldn't back up %@ before touching it: %@", fileName, copyErr.localizedDescription]);
            return NO;
        }
        ZLog(@"[BankTransplant] backed up %@ -> %@", fileName, backupPath);
    }

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.swap.%@", fileName, [NSUUID UUID].UUIDString]];

    NSError *copyErr = nil;
    BOOL staged = [fm copyItemAtPath:moddedURL.path toPath:tmpPath error:&copyErr];

    if (accessing) [moddedURL stopAccessingSecurityScopedResource];

    if (!staged) {
        [fm removeItemAtPath:tmpPath error:nil];
        if (error) *error = BTError(BankTransplantErrorCantReadModded,
            [NSString stringWithFormat:@"Couldn't read the picked file %@: %@", fileName, copyErr.localizedDescription]);
        return NO;
    }

    NSError *replaceErr = nil;
    BOOL ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:originalPath]
                      withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                     backupItemName:nil
                            options:0
                   resultingItemURL:nil
                              error:&replaceErr];
    [fm removeItemAtPath:tmpPath error:nil];

    if (!ok) {
        if (error) *error = BTError(BankTransplantErrorWriteFailed,
            [NSString stringWithFormat:@"Swapping %@ in place failed: %@", fileName, replaceErr.localizedDescription]);
        return NO;
    }

    ZLog(@"[BankTransplant] swapped %@ in place with the modded file's bytes as-is", fileName);

    zs_track_asset_path(originalPath);

    return YES;
}

+ (BOOL)bt_fileAtPath:(NSString *)pathA hasIdenticalBytesToFileAtPath:(NSString *)pathB {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:pathA] || ![fm fileExistsAtPath:pathB]) return NO;

    NSDictionary<NSFileAttributeKey, id> *attrsA = [fm attributesOfItemAtPath:pathA error:nil];
    NSDictionary<NSFileAttributeKey, id> *attrsB = [fm attributesOfItemAtPath:pathB error:nil];
    unsigned long long sizeA = [attrsA[NSFileSize] unsignedLongLongValue];
    unsigned long long sizeB = [attrsB[NSFileSize] unsignedLongLongValue];
    if (sizeA != sizeB) return NO;

    NSData *dataA = [NSData dataWithContentsOfFile:pathA];
    NSData *dataB = [NSData dataWithContentsOfFile:pathB];
    if (!dataA || !dataB) return NO;
    return [dataA isEqualToData:dataB];
}

+ (BOOL)bt_restoreOneBackupEntry:(NSString *)backupEntryName inBackupDir:(NSString *)backupDir mobileDir:(NSString *)mobileDir force:(BOOL)force {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backupPath = [backupDir stringByAppendingPathComponent:backupEntryName];
    NSString *fileName = [backupEntryName substringToIndex:backupEntryName.length - kBTBackupSuffix.length];
    NSString *originalPath = [mobileDir stringByAppendingPathComponent:fileName];

    if (!force && [self bt_fileAtPath:originalPath hasIdenticalBytesToFileAtPath:backupPath]) {
        return NO;
    }

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:backupPath toPath:tmpPath error:&copyErr]) {
        ZLog(@"[BankTransplant] restore: couldn't stage %@: %@", backupEntryName, copyErr.localizedDescription);
        return NO;
    }
    NSError *replaceErr = nil;
    BOOL ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:originalPath]
                      withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                     backupItemName:nil
                            options:0
                   resultingItemURL:nil
                              error:&replaceErr];
    [fm removeItemAtPath:tmpPath error:nil];
    if (!ok) {
        ZLog(@"[BankTransplant] restore: couldn't swap %@ back in: %@", originalPath.lastPathComponent, replaceErr.localizedDescription);
    }
    return ok;
}

+ (NSInteger)restoreAllBackedUpBanksForce:(BOOL)force error:(NSError **)error {
    NSString *mobileDir = [self mobileFMODBuildsDirectory];
    NSString *backupDir = [self bankBackupDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;

    if (!backupDir || ![fm fileExistsAtPath:backupDir]) {
        return 0;
    }

    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:backupDir error:&listErr];
    if (!entries) {
        if (error) *error = listErr ?: BTError(BankTransplantErrorOriginalNotFound, @"Couldn't list the bank backup directory.");
        return -1;
    }

    NSInteger restored = 0;
    for (NSString *entry in entries) {
        if (![entry hasSuffix:kBTBackupSuffix]) continue;
        if ([self bt_restoreOneBackupEntry:entry inBackupDir:backupDir mobileDir:mobileDir force:force]) restored++;
    }

    return restored;
}

+ (NSInteger)restoreAllBackedUpBanksWithError:(NSError **)error {
    return [self restoreAllBackedUpBanksForce:NO error:error];
}

+ (NSInteger)restoreBackedUpBankNamed:(NSString *)name error:(NSError **)error {
    NSString *mobileDir = [self mobileFMODBuildsDirectory];
    NSString *backupDir = [self bankBackupDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;

    if (!backupDir || ![fm fileExistsAtPath:backupDir]) {
        return 0;
    }

    NSString *backupEntryName = [name stringByAppendingString:kBTBackupSuffix];
    NSString *backupPath = [backupDir stringByAppendingPathComponent:backupEntryName];
    if (![fm fileExistsAtPath:backupPath]) {
        return 0;
    }

    return [self bt_restoreOneBackupEntry:backupEntryName inBackupDir:backupDir mobileDir:mobileDir force:NO] ? 1 : 0;
}

+ (NSArray<NSString *> *)documentsRelativePathsOfSwappedBanks {
    NSString *mobileDir = [self mobileFMODBuildsDirectory];
    NSString *backupDir = [self bankBackupDirectory];
    if (!mobileDir || !backupDir) return @[];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:backupDir error:nil] ?: @[]) {
        if (![entry hasSuffix:kBTBackupSuffix]) continue;

        NSString *fileName = [entry substringToIndex:entry.length - kBTBackupSuffix.length];
        NSString *livePath = [mobileDir stringByAppendingPathComponent:fileName];
        NSString *backupPath = [backupDir stringByAppendingPathComponent:entry];
        if (![fm fileExistsAtPath:livePath]) continue;
        if ([fm contentsEqualAtPath:livePath andPath:backupPath]) continue;

        [result addObject:[kBTMobileBuildsRelativePath stringByAppendingPathComponent:fileName]];
    }
    return result;
}

static NSString *BTFSB5CodecName(uint32_t mode) {
    switch (mode) {
        case 0:  return @"None";
        case 1:  return @"PCM8";
        case 2:  return @"PCM16";
        case 3:  return @"PCM24";
        case 4:  return @"PCM32";
        case 5:  return @"PCM Float";
        case 6:  return @"GameCube ADPCM";
        case 7:  return @"IMA ADPCM";
        case 8:  return @"PS2/PSP VAG";
        case 9:  return @"PS Vita HEVAG";
        case 10: return @"Xbox 360 XMA";
        case 11: return @"MPEG (MP3)";
        case 12: return @"CELT";
        case 13: return @"PS4/Vita AT9";
        case 14: return @"Xbox XWMA";
        case 15: return @"Vorbis";
        default: return [NSString stringWithFormat:@"Unknown (%u)", mode];
    }
}

+ (nullable NSDictionary<NSString *, id> *)fmodHeaderInfoForBankAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;

    static const NSUInteger kScanWindow = 65536;
    NSData *window = [handle readDataOfLength:kScanWindow];
    [handle closeFile];
    if (window.length < 32) return nil;

    static const uint8_t kFSB5Magic[4] = {'F', 'S', 'B', '5'};
    NSData *needle = [NSData dataWithBytes:kFSB5Magic length:4];
    NSRange found = [window rangeOfData:needle options:0 range:NSMakeRange(0, window.length)];
    if (found.location == NSNotFound) return nil;

    NSUInteger fieldsOffset = found.location + 4;
    static const NSUInteger kFieldsSize = 6 * sizeof(uint32_t);
    if (fieldsOffset + kFieldsSize > window.length) return nil;

    uint32_t fields[6] = {0};
    [window getBytes:fields range:NSMakeRange(fieldsOffset, kFieldsSize)];

    uint32_t version    = CFSwapInt32LittleToHost(fields[0]);
    uint32_t numSamples  = CFSwapInt32LittleToHost(fields[1]);
    uint32_t mode        = CFSwapInt32LittleToHost(fields[5]);

    return @{
        @"codec": BTFSB5CodecName(mode),
        @"fsbVersion": @(version),
        @"numSamples": @(numSamples),
    };
}

@end

