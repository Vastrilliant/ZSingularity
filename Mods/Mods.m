#import "Mods.h"
#import "ZTweakLog.h"
#import "ZSEngine.h"
#import "IL2CppIntrospection.h"
#import "UnityBundleTools.h"
#import <CoreFoundation/CoreFoundation.h>
#import <compression.h>

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

+ (NSString *)displayNameForFontRole:(ZSFontRole)role {
    switch (role) {
        case ZSFontRoleTitle: return @"Title";
        case ZSFontRoleContext: return @"Context";
        case ZSFontRoleKanjiHanzi: return @"Kanji/Hanzi";
        default: return @"None";
    }
}

@end

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

+ (nullable NSString *)bt_legacyBankBackupDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityBankBackups"];
}

+ (NSString *)bankBackupDirectory {
    NSString *newDir = [ZSModsPaths modsBackupsBanksDirectory];
    [ZSModsPaths migrateLegacyDirectoryAtPath:[self bt_legacyBankBackupDirectory] toPath:newDir];
    return newDir;
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

NSString * const LocalizationTransplantErrorDomain = @"LocalizationTransplantErrorDomain";

static NSError *LTError(LocalizationTransplantErrorCode code, NSString *message) {
    return [NSError errorWithDomain:LocalizationTransplantErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString * const kLTBackupSuffix = @".orig-bak";
static NSString * const kLTMarkerSuffix = @".applied";
static NSString * const kLTFileBackupsDirectoryName = @"files";
static NSString * const kLTPackBackupsDirectoryName = @"packs";
static NSString * const kLTLocalizeRelativePath = @"Assets/Resources_moved/Localize";

static NSArray<NSString *> *LTLanguageCodes(void) {
    static NSArray<NSString *> *codes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        codes = @[@"en", @"jp", @"kr"];
    });
    return codes;
}

static BOOL LTIsValidLanguageCode(NSString *code) {
    return code.length > 0 && [LTLanguageCodes() containsObject:code];
}

static NSSet<NSString *> *LTKnownPackFolderNames(void) {
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[
            @"battleannouncerdlg",
            @"battleannouncersdlg",
            @"bgmlyrics",
            @"egovoicedig",
            @"egovoicedlg",
            @"personalityvoicedlg",
            @"rpgsystem",
            @"storydata",
        ]];
    });
    return names;
}

static NSString *LTLanguageCodeForFileName(NSString *fileName) {
    NSString *lower = fileName.lowercaseString;
    for (NSString *code in LTLanguageCodes()) {
        if ([lower hasPrefix:[code stringByAppendingString:@"_"]]) return code;
    }
    return nil;
}

static NSString *LTNameWithoutLanguagePrefix(NSString *fileName) {
    NSString *lower = fileName.lowercaseString;
    NSString *code = LTLanguageCodeForFileName(fileName);
    return code ? [lower substringFromIndex:code.length + 1] : lower;
}

static NSString *LTDetectLanguage(NSArray<NSString *> *paths) {
    NSCountedSet<NSString *> *tally = [NSCountedSet set];
    NSUInteger jsonCount = 0;
    for (NSString *path in paths) {
        NSString *leaf = path.lastPathComponent;
        if ([leaf.pathExtension caseInsensitiveCompare:@"json"] != NSOrderedSame) continue;
        if ([leaf hasPrefix:@"._"]) continue;
        jsonCount++;
        NSString *code = LTLanguageCodeForFileName(leaf);
        if (code) [tally addObject:code];
    }
    NSString *best = nil;
    NSUInteger bestCount = 0;
    for (NSString *code in LTLanguageCodes()) {
        NSUInteger count = [tally countForObject:code];
        if (count > bestCount) {
            best = code;
            bestCount = count;
        }
    }
    if (bestCount * 2 <= jsonCount) return nil;
    return best;
}

static BOOL LTRelativeTargetIsSafe(NSString *relativeTarget) {
    NSArray<NSString *> *components = relativeTarget.pathComponents;
    if (components.count < 2) return NO;
    if (!LTIsValidLanguageCode(components.firstObject)) return NO;
    for (NSString *component in components) {
        if ([component isEqualToString:@".."] || [component isEqualToString:@"/"]) return NO;
    }
    return YES;
}

static NSString *LTFileBackupPath(NSString *relativeTarget) {
    NSString *base = [LocalizationTransplant backupDirectory];
    if (!base) return nil;
    NSString *filesRoot = [base stringByAppendingPathComponent:kLTFileBackupsDirectoryName];
    return [[filesRoot stringByAppendingPathComponent:relativeTarget] stringByAppendingString:kLTBackupSuffix];
}

static NSString *LTPackBackupPath(NSString *languageCode) {
    NSString *base = [LocalizationTransplant backupDirectory];
    if (!base) return nil;
    NSString *packsRoot = [base stringByAppendingPathComponent:kLTPackBackupsDirectoryName];
    return [packsRoot stringByAppendingPathComponent:[languageCode stringByAppendingString:kLTBackupSuffix]];
}

static NSString *LTPackMarkerPath(NSString *languageCode) {
    NSString *base = [LocalizationTransplant backupDirectory];
    if (!base) return nil;
    NSString *packsRoot = [base stringByAppendingPathComponent:kLTPackBackupsDirectoryName];
    return [packsRoot stringByAppendingPathComponent:[languageCode stringByAppendingString:kLTMarkerSuffix]];
}

static NSString *LTPackFingerprint(NSString *packPath) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger fileCount = 0;
    unsigned long long byteCount = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:packPath];
    for (NSString *relative in enumerator) {
        (void)relative;
        NSDictionary *attributes = enumerator.fileAttributes;
        if ([attributes.fileType isEqualToString:NSFileTypeRegular]) {
            fileCount++;
            byteCount += attributes.fileSize;
        }
    }
    return [NSString stringWithFormat:@"%lu:%llu", (unsigned long)fileCount, byteCount];
}

@interface LocalizationTransplant ()
+ (BOOL)lt_dataLooksLikeLocalizationJSON:(NSData *)head;
+ (nullable NSString *)lt_originalSourcePathForRelativeTarget:(NSString *)relativeTarget;
+ (BOOL)lt_ensureFileBackupForRelativeTarget:(NSString *)relativeTarget error:(NSError **)error;
+ (BOOL)lt_ensurePackBackupForLanguage:(NSString *)languageCode error:(NSError **)error;
+ (BOOL)lt_placeFileAtPath:(NSString *)sourcePath atPath:(NSString *)destPath error:(NSError **)error;
+ (BOOL)lt_replaceDirectoryAtPath:(NSString *)destDir withCopyOfDirectoryAtPath:(NSString *)sourceDir error:(NSError **)error;
+ (BOOL)lt_mergeDirectoryAtPath:(NSString *)destDir withContentsOfDirectoryAtPath:(NSString *)sourceDir error:(NSError **)error;
+ (BOOL)lt_restoreFileBackupAtPath:(NSString *)backupPath toRelativeTarget:(NSString *)relativeTarget force:(BOOL)force;
+ (NSInteger)lt_restoreFileBackupsForLanguage:(NSString *)languageCode force:(BOOL)force;
+ (BOOL)lt_restorePackBackupForLanguage:(NSString *)languageCode force:(BOOL)force;
@end

@implementation LocalizationTransplant

+ (NSArray<NSString *> *)languageCodes {
    return LTLanguageCodes();
}

+ (nullable NSString *)localizeDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:kLTLocalizeRelativePath];
}

+ (nullable NSString *)languageDirectoryForCode:(NSString *)languageCode {
    if (!LTIsValidLanguageCode(languageCode)) return nil;
    NSString *localizeDir = [self localizeDirectory];
    return localizeDir ? [localizeDir stringByAppendingPathComponent:languageCode] : nil;
}

+ (nullable NSString *)lt_legacyBackupDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityLocalizeBackups"];
}

+ (nullable NSString *)backupDirectory {
    NSString *newDir = [ZSModsPaths modsBackupsLocalizeDirectory];
    [ZSModsPaths migrateLegacyDirectoryAtPath:[self lt_legacyBackupDirectory] toPath:newDir];
    return newDir;
}

+ (BOOL)isJunkArchivePathComponents:(NSArray<NSString *> *)components {
    if (components.count == 0) return NO;
    if ([components.firstObject isEqualToString:@"__MACOSX"]) return YES;
    for (NSString *component in components) {
        if ([component isEqualToString:@".DS_Store"] || [component hasPrefix:@"._"]) return YES;
    }
    return NO;
}

+ (BOOL)lt_dataLooksLikeLocalizationJSON:(NSData *)head {
    const uint8_t *bytes = head.bytes;
    NSUInteger length = head.length;
    NSUInteger i = 0;
    if (length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) i = 3;

    while (i < length && (bytes[i] == ' ' || bytes[i] == '\t' || bytes[i] == '\r' || bytes[i] == '\n')) i++;
    if (i < length && bytes[i] == '{') {
        i++;
        while (i < length && (bytes[i] == ' ' || bytes[i] == '\t' || bytes[i] == '\r' || bytes[i] == '\n')) i++;
    }
    if (i < length && bytes[i] == '"') i++;

    static const char kKey[] = "dataList";
    const NSUInteger keyLength = sizeof(kKey) - 1;
    return i + keyLength <= length && memcmp(bytes + i, kKey, keyLength) == 0;
}

+ (BOOL)isLocalizationJSONAtURL:(NSURL *)url {
    if ([url.pathExtension caseInsensitiveCompare:@"json"] != NSOrderedSame) return NO;

    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path];
    NSData *head = [handle readDataOfLength:256];
    [handle closeFile];
    if (accessing) [url stopAccessingSecurityScopedResource];

    if (head.length == 0) return NO;
    return [self lt_dataLooksLikeLocalizationJSON:head];
}

+ (BOOL)isTranslationPackDirectoryAtPath:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) return NO;

    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:nil] ?: @[];
    NSUInteger knownFolderCount = 0;
    for (NSString *child in children) {
        BOOL childIsDirectory = NO;
        NSString *childPath = [path stringByAppendingPathComponent:child];
        if (![fm fileExistsAtPath:childPath isDirectory:&childIsDirectory] || !childIsDirectory) continue;
        if ([LTKnownPackFolderNames() containsObject:child.lowercaseString]) knownFolderCount++;
    }
    return knownFolderCount >= 2;
}

+ (nullable NSString *)packRootFolderNameForArchiveEntryNames:(NSArray<NSString *> *)entryNames {
    NSMutableOrderedSet<NSString *> *topLevel = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *knownFound = [NSMutableSet set];
    BOOL hasRootFile = NO;

    for (NSString *name in entryNames) {
        NSString *normalized = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        BOOL isDirectoryEntry = [normalized hasSuffix:@"/"];

        NSMutableArray<NSString *> *components = [NSMutableArray array];
        for (NSString *component in [normalized componentsSeparatedByString:@"/"]) {
            if (component.length == 0 || [component isEqualToString:@"."]) continue;
            if ([component isEqualToString:@".."]) return nil;
            [components addObject:component];
        }
        if (components.count == 0 || [self isJunkArchivePathComponents:components]) continue;

        [topLevel addObject:components[0]];
        if (components.count == 1 && !isDirectoryEntry) hasRootFile = YES;
        if (components.count >= 3 || (components.count == 2 && isDirectoryEntry)) {
            NSString *lowered = components[1].lowercaseString;
            if ([LTKnownPackFolderNames() containsObject:lowered]) [knownFound addObject:lowered];
        }
    }

    if (hasRootFile || topLevel.count != 1 || knownFound.count < 2) return nil;
    return topLevel.firstObject;
}

+ (nullable NSString *)packDirectoryInExtractedDirectoryAtPath:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:nil] ?: @[];
    if (children.count != 1) return nil;

    NSString *candidate = [path stringByAppendingPathComponent:children.firstObject];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:candidate isDirectory:&isDirectory] || !isDirectory) return nil;
    return [self isTranslationPackDirectoryAtPath:candidate] ? candidate : nil;
}

+ (nullable NSString *)detectedLanguageForPackDirectoryAtPath:(NSString *)path {
    NSMutableArray<NSString *> *relativePaths = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:path];
    for (NSString *relative in enumerator) {
        [relativePaths addObject:relative];
    }
    return LTDetectLanguage(relativePaths);
}

+ (nullable NSString *)detectedLanguageForArchiveEntryNames:(NSArray<NSString *> *)entryNames {
    return LTDetectLanguage(entryNames);
}

+ (BOOL)prefixPackJSONFilesAtPath:(NSString *)packPath
                     withLanguage:(NSString *)languageCode
                            error:(NSError **)error {
    if (!LTIsValidLanguageCode(languageCode)) {
        if (error) *error = LTError(LocalizationTransplantErrorInvalidTarget, @"Unknown language folder.");
        return NO;
    }
    if ([self detectedLanguageForPackDirectoryAtPath:packPath]) return YES;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *prefix = [languageCode.uppercaseString stringByAppendingString:@"_"];

    NSMutableArray<NSString *> *jsonRelativePaths = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:packPath];
    for (NSString *relative in enumerator) {
        if ([relative.pathExtension caseInsensitiveCompare:@"json"] != NSOrderedSame) continue;
        if ([self isJunkArchivePathComponents:relative.pathComponents]) continue;
        if (![enumerator.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;
        [jsonRelativePaths addObject:relative];
    }

    for (NSString *relative in jsonRelativePaths) {
        NSString *sourcePath = [packPath stringByAppendingPathComponent:relative];
        NSString *renamedLeaf = [prefix stringByAppendingString:relative.lastPathComponent];
        NSString *destPath = [sourcePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:renamedLeaf];

        NSError *moveErr = nil;
        if (![fm moveItemAtPath:sourcePath toPath:destPath error:&moveErr]) {
            if (error) *error = LTError(LocalizationTransplantErrorWriteFailed,
                [NSString stringWithFormat:@"Couldn't add the \"%@\" prefix to %@: %@",
                    prefix, relative.lastPathComponent, moveErr.localizedDescription]);
            return NO;
        }
    }
    ZLog(@"[LocalizationTransplant] prefixed %lu .json files with \"%@\"", (unsigned long)jsonRelativePaths.count, prefix);
    return YES;
}

+ (NSArray<NSString *> *)relativeTargetsForJSONNamed:(NSString *)fileName inLanguage:(NSString *)languageCode {
    NSString *localizeDir = [self localizeDirectory];
    if (!localizeDir || !LTIsValidLanguageCode(languageCode)) return @[];

    NSString *wanted = [[languageCode stringByAppendingString:@"_"] stringByAppendingString:LTNameWithoutLanguagePrefix(fileName)];

    NSArray<NSString *> *(^lookup)(void) = ^NSArray<NSString *> *{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray<NSString *> *matches = [NSMutableArray array];
        for (NSString *relativeTarget in [ZSFileIndex cachedLocalizationPathsInLanguage:languageCode] ?: @[]) {
            NSString *leaf = relativeTarget.lastPathComponent;
            if ([leaf.pathExtension caseInsensitiveCompare:@"json"] != NSOrderedSame) continue;
            if (![leaf.lowercaseString isEqualToString:wanted]) continue;
            if ([fm fileExistsAtPath:[localizeDir stringByAppendingPathComponent:relativeTarget]]) [matches addObject:relativeTarget];
        }
        return matches;
    };

    if (![ZSFileIndex cachedLocalizationPathsInLanguage:languageCode]) [ZSFileIndex ensureLocalizationIndexUpToDate];
    NSArray<NSString *> *matches = lookup();
    if (matches.count == 0) {
        [ZSFileIndex ensureLocalizationIndexUpToDate];
        matches = lookup();
    }
    return matches;
}

+ (unsigned long long)totalByteSizeAtPath:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) return 0;
    if (!isDirectory) return [[fm attributesOfItemAtPath:path error:nil] fileSize];

    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    for (NSString *relative in enumerator) {
        (void)relative;
        NSDictionary *attributes = enumerator.fileAttributes;
        if ([attributes.fileType isEqualToString:NSFileTypeRegular]) total += attributes.fileSize;
    }
    return total;
}

+ (nullable NSString *)lt_originalSourcePathForRelativeTarget:(NSString *)relativeTarget {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *components = relativeTarget.pathComponents;
    NSString *languageCode = components.firstObject;
    NSString *packBackup = LTPackBackupPath(languageCode);

    NSString *candidate = nil;
    if (packBackup && [fm fileExistsAtPath:packBackup]) {
        NSString *rest = [[components subarrayWithRange:NSMakeRange(1, components.count - 1)] componentsJoinedByString:@"/"];
        candidate = [packBackup stringByAppendingPathComponent:rest];
    } else {
        candidate = [[self localizeDirectory] stringByAppendingPathComponent:relativeTarget];
    }
    return [fm fileExistsAtPath:candidate] ? candidate : nil;
}

+ (BOOL)lt_ensureFileBackupForRelativeTarget:(NSString *)relativeTarget error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backupPath = LTFileBackupPath(relativeTarget);
    if (!backupPath) {
        if (error) *error = LTError(LocalizationTransplantErrorBackupFailed, @"Couldn't resolve the backup directory.");
        return NO;
    }
    if ([fm fileExistsAtPath:backupPath]) return YES;

    NSString *source = [self lt_originalSourcePathForRelativeTarget:relativeTarget];
    if (!source) return YES;

    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:backupPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        if (error) *error = LTError(LocalizationTransplantErrorBackupFailed,
            [NSString stringWithFormat:@"Couldn't create the backup directory: %@", dirErr.localizedDescription]);
        return NO;
    }

    NSError *copyErr = nil;
    if (![fm copyItemAtPath:source toPath:backupPath error:&copyErr]) {
        [fm removeItemAtPath:backupPath error:nil];
        if (error) *error = LTError(LocalizationTransplantErrorBackupFailed,
            [NSString stringWithFormat:@"Couldn't back up %@ before touching it: %@", relativeTarget.lastPathComponent, copyErr.localizedDescription]);
        return NO;
    }
    ZLog(@"[LocalizationTransplant] backed up %@ -> %@", relativeTarget, backupPath);
    return YES;
}

+ (BOOL)lt_ensurePackBackupForLanguage:(NSString *)languageCode error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *packBackup = LTPackBackupPath(languageCode);
    if (!packBackup) {
        if (error) *error = LTError(LocalizationTransplantErrorBackupFailed, @"Couldn't resolve the backup directory.");
        return NO;
    }
    if ([fm fileExistsAtPath:packBackup]) return YES;

    [self lt_restoreFileBackupsForLanguage:languageCode force:NO];

    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:packBackup.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        if (error) *error = LTError(LocalizationTransplantErrorBackupFailed,
            [NSString stringWithFormat:@"Couldn't create the backup directory: %@", dirErr.localizedDescription]);
        return NO;
    }

    NSString *partialPath = [packBackup stringByAppendingString:@".partial"];
    [fm removeItemAtPath:partialPath error:nil];

    NSError *copyErr = nil;
    NSString *languageDir = [self languageDirectoryForCode:languageCode];
    NSError *moveErr = nil;
    if (![fm copyItemAtPath:languageDir toPath:partialPath error:&copyErr]
        || ![fm moveItemAtPath:partialPath toPath:packBackup error:&moveErr]) {
        [fm removeItemAtPath:partialPath error:nil];
        if (error) *error = LTError(LocalizationTransplantErrorBackupFailed,
            [NSString stringWithFormat:@"Couldn't back up the \"%@\" language folder before touching it: %@",
                languageCode, (copyErr ?: moveErr).localizedDescription]);
        return NO;
    }
    ZLog(@"[LocalizationTransplant] backed up the \"%@\" language folder -> %@", languageCode, packBackup);
    return YES;
}

+ (BOOL)lt_placeFileAtPath:(NSString *)sourcePath atPath:(NSString *)destPath error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:destPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        if (error) *error = LTError(LocalizationTransplantErrorWriteFailed,
            [NSString stringWithFormat:@"Couldn't create the folder for %@: %@", destPath.lastPathComponent, dirErr.localizedDescription]);
        return NO;
    }

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.loc.%@", destPath.lastPathComponent, [NSUUID UUID].UUIDString]];

    NSError *copyErr = nil;
    if (![fm copyItemAtPath:sourcePath toPath:tmpPath error:&copyErr]) {
        [fm removeItemAtPath:tmpPath error:nil];
        if (error) *error = LTError(LocalizationTransplantErrorCantReadModded,
            [NSString stringWithFormat:@"Couldn't read %@: %@", sourcePath.lastPathComponent, copyErr.localizedDescription]);
        return NO;
    }

    NSError *placeErr = nil;
    BOOL ok;
    if ([fm fileExistsAtPath:destPath]) {
        ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:destPath]
                    withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                   backupItemName:nil
                          options:0
                 resultingItemURL:nil
                            error:&placeErr];
    } else {
        ok = [fm moveItemAtPath:tmpPath toPath:destPath error:&placeErr];
    }
    [fm removeItemAtPath:tmpPath error:nil];

    if (!ok) {
        if (error) *error = LTError(LocalizationTransplantErrorWriteFailed,
            [NSString stringWithFormat:@"Swapping %@ in place failed: %@", destPath.lastPathComponent, placeErr.localizedDescription]);
        return NO;
    }
    return YES;
}

+ (BOOL)lt_replaceDirectoryAtPath:(NSString *)destDir withCopyOfDirectoryAtPath:(NSString *)sourceDir error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *stagedPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"zs-loc-stage-%@", [NSUUID UUID].UUIDString]];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:sourceDir toPath:stagedPath error:&copyErr]) {
        [fm removeItemAtPath:stagedPath error:nil];
        if (error) *error = LTError(LocalizationTransplantErrorCantReadModded,
            [NSString stringWithFormat:@"Couldn't read %@: %@", sourceDir.lastPathComponent, copyErr.localizedDescription]);
        return NO;
    }

    BOOL destExists = [fm fileExistsAtPath:destDir];
    NSString *sidelinedPath = [destDir stringByAppendingString:@".zs-old"];
    if (destExists) {
        [fm removeItemAtPath:sidelinedPath error:nil];
        NSError *sidelineErr = nil;
        if (![fm moveItemAtPath:destDir toPath:sidelinedPath error:&sidelineErr]) {
            [fm removeItemAtPath:stagedPath error:nil];
            if (error) *error = LTError(LocalizationTransplantErrorWriteFailed,
                [NSString stringWithFormat:@"Couldn't move the current \"%@\" folder aside: %@", destDir.lastPathComponent, sidelineErr.localizedDescription]);
            return NO;
        }
    } else {
        [fm createDirectoryAtPath:destDir.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSError *moveErr = nil;
    if (![fm moveItemAtPath:stagedPath toPath:destDir error:&moveErr]) {
        if (destExists) [fm moveItemAtPath:sidelinedPath toPath:destDir error:nil];
        [fm removeItemAtPath:stagedPath error:nil];
        if (error) *error = LTError(LocalizationTransplantErrorWriteFailed,
            [NSString stringWithFormat:@"Swapping the \"%@\" folder in place failed: %@", destDir.lastPathComponent, moveErr.localizedDescription]);
        return NO;
    }

    if (destExists) [fm removeItemAtPath:sidelinedPath error:nil];
    return YES;
}

+ (BOOL)lt_mergeDirectoryAtPath:(NSString *)destDir withContentsOfDirectoryAtPath:(NSString *)sourceDir error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;

    BOOL destIsDirectory = NO;
    if (![fm fileExistsAtPath:destDir isDirectory:&destIsDirectory] || !destIsDirectory) {
        NSError *dirErr = nil;
        if (![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
            if (error) *error = LTError(LocalizationTransplantErrorWriteFailed,
                [NSString stringWithFormat:@"Couldn't create the \"%@\" folder: %@", destDir.lastPathComponent, dirErr.localizedDescription]);
            return NO;
        }
    }

    NSError *listErr = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:sourceDir error:&listErr];
    if (!entries) {
        if (error) *error = LTError(LocalizationTransplantErrorCantReadModded,
            [NSString stringWithFormat:@"Couldn't read %@: %@", sourceDir.lastPathComponent, listErr.localizedDescription]);
        return NO;
    }

    for (NSString *entryName in entries) {
        if ([entryName isEqualToString:@".DS_Store"] || [entryName hasPrefix:@"._"]) continue;

        NSString *sourceItemPath = [sourceDir stringByAppendingPathComponent:entryName];
        NSString *destItemPath = [destDir stringByAppendingPathComponent:entryName];

        BOOL sourceItemIsDirectory = NO;
        [fm fileExistsAtPath:sourceItemPath isDirectory:&sourceItemIsDirectory];

        if (sourceItemIsDirectory) {
            if (![self lt_mergeDirectoryAtPath:destItemPath withContentsOfDirectoryAtPath:sourceItemPath error:error]) return NO;
            continue;
        }

        if (![self lt_placeFileAtPath:sourceItemPath atPath:destItemPath error:error]) return NO;
    }

    return YES;
}

+ (BOOL)applyModFileAtPath:(NSString *)modPath toRelativeTarget:(NSString *)relativeTarget error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;

    if (!LTRelativeTargetIsSafe(relativeTarget)) {
        if (error) *error = LTError(LocalizationTransplantErrorInvalidTarget, @"The target path inside the Localize folder isn't valid.");
        return NO;
    }

    NSString *localizeDir = [self localizeDirectory];
    NSString *languageCode = relativeTarget.pathComponents.firstObject;
    NSString *languageDir = [self languageDirectoryForCode:languageCode];
    BOOL languageIsDirectory = NO;
    if (!localizeDir || !languageDir || ![fm fileExistsAtPath:languageDir isDirectory:&languageIsDirectory] || !languageIsDirectory) {
        if (error) *error = LTError(LocalizationTransplantErrorLanguageFolderNotFound,
            [NSString stringWithFormat:@"No \"%@\" language folder found under Assets/Resources_moved/Localize.", languageCode]);
        return NO;
    }

    if (![fm isReadableFileAtPath:modPath]) {
        if (error) *error = LTError(LocalizationTransplantErrorCantReadModded,
            [NSString stringWithFormat:@"Couldn't read %@.", modPath.lastPathComponent]);
        return NO;
    }

    if (![self lt_ensureFileBackupForRelativeTarget:relativeTarget error:error]) return NO;

    NSString *targetPath = [localizeDir stringByAppendingPathComponent:relativeTarget];
    if (![self lt_placeFileAtPath:modPath atPath:targetPath error:error]) return NO;

    zs_track_asset_path(targetPath);
    [ZSFileIndex ensureLocalizationIndexUpToDate];
    ZLog(@"[LocalizationTransplant] swapped %@ in place with the modded file's bytes as-is", relativeTarget);
    return YES;
}

+ (BOOL)applyPackAtPath:(NSString *)packPath toLanguage:(NSString *)languageCode error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *languageDir = [self languageDirectoryForCode:languageCode];
    BOOL languageIsDirectory = NO;
    if (!languageDir || ![fm fileExistsAtPath:languageDir isDirectory:&languageIsDirectory] || !languageIsDirectory) {
        if (error) *error = LTError(LocalizationTransplantErrorLanguageFolderNotFound,
            [NSString stringWithFormat:@"No \"%@\" language folder found under Assets/Resources_moved/Localize.", languageCode]);
        return NO;
    }

    if (![self isTranslationPackDirectoryAtPath:packPath]) {
        if (error) *error = LTError(LocalizationTransplantErrorNotAPack, @"This folder doesn't look like a localization pack.");
        return NO;
    }

    if (![self lt_ensurePackBackupForLanguage:languageCode error:error]) return NO;
    if (![self lt_mergeDirectoryAtPath:languageDir withContentsOfDirectoryAtPath:packPath error:error]) return NO;

    NSString *markerPath = LTPackMarkerPath(languageCode);
    if (markerPath) {
        [LTPackFingerprint(packPath) writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    zs_track_asset_path(languageDir);
    [ZSFileIndex ensureLocalizationIndexUpToDate];
    ZLog(@"[LocalizationTransplant] merged %@ into the \"%@\" language folder", packPath.lastPathComponent, languageCode);
    return YES;
}

+ (BOOL)lt_restoreFileBackupAtPath:(NSString *)backupPath toRelativeTarget:(NSString *)relativeTarget force:(BOOL)force {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!LTRelativeTargetIsSafe(relativeTarget)) return NO;

    NSString *localizeDir = [self localizeDirectory];
    NSString *languageDir = [self languageDirectoryForCode:relativeTarget.pathComponents.firstObject];
    BOOL languageIsDirectory = NO;
    if (!localizeDir || !languageDir || ![fm fileExistsAtPath:languageDir isDirectory:&languageIsDirectory] || !languageIsDirectory) return NO;

    NSString *targetPath = [localizeDir stringByAppendingPathComponent:relativeTarget];
    if (!force && [fm contentsEqualAtPath:targetPath andPath:backupPath]) return NO;

    NSError *placeErr = nil;
    if (![self lt_placeFileAtPath:backupPath atPath:targetPath error:&placeErr]) {
        ZLog(@"[LocalizationTransplant] restore: couldn't swap %@ back in: %@", relativeTarget, placeErr.localizedDescription);
        return NO;
    }
    return YES;
}

+ (NSInteger)lt_restoreFileBackupsForLanguage:(NSString *)languageCode force:(BOOL)force {
    NSString *base = [self backupDirectory];
    if (!base) return 0;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *languageBackupRoot = [[base stringByAppendingPathComponent:kLTFileBackupsDirectoryName] stringByAppendingPathComponent:languageCode];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:languageBackupRoot isDirectory:&isDirectory] || !isDirectory) return 0;

    NSInteger restored = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:languageBackupRoot];
    for (NSString *relative in enumerator) {
        if (![relative hasSuffix:kLTBackupSuffix]) continue;

        NSString *backupPath = [languageBackupRoot stringByAppendingPathComponent:relative];
        BOOL backupIsDirectory = NO;
        if (![fm fileExistsAtPath:backupPath isDirectory:&backupIsDirectory] || backupIsDirectory) continue;

        NSString *withoutSuffix = [relative substringToIndex:relative.length - kLTBackupSuffix.length];
        NSString *relativeTarget = [languageCode stringByAppendingPathComponent:withoutSuffix];
        if ([self lt_restoreFileBackupAtPath:backupPath toRelativeTarget:relativeTarget force:force]) restored++;
    }
    return restored;
}

+ (BOOL)lt_restorePackBackupForLanguage:(NSString *)languageCode force:(BOOL)force {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *packBackup = LTPackBackupPath(languageCode);
    NSString *languageDir = [self languageDirectoryForCode:languageCode];
    if (!packBackup || !languageDir || ![fm fileExistsAtPath:packBackup]) return NO;

    NSString *markerPath = LTPackMarkerPath(languageCode);
    if (!force && [fm contentsEqualAtPath:languageDir andPath:packBackup]) {
        if (markerPath) [fm removeItemAtPath:markerPath error:nil];
        return NO;
    }

    NSError *replaceErr = nil;
    if (![self lt_replaceDirectoryAtPath:languageDir withCopyOfDirectoryAtPath:packBackup error:&replaceErr]) {
        ZLog(@"[LocalizationTransplant] restore: couldn't swap the \"%@\" language folder back in: %@", languageCode, replaceErr.localizedDescription);
        return NO;
    }
    if (markerPath) [fm removeItemAtPath:markerPath error:nil];
    [ZSFileIndex ensureLocalizationIndexUpToDate];
    return YES;
}

+ (BOOL)restoreRelativeTarget:(NSString *)relativeTarget ifAppliedFromModFileAtPath:(NSString *)modPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!LTRelativeTargetIsSafe(relativeTarget)) return NO;

    NSString *localizeDir = [self localizeDirectory];
    NSString *backupPath = LTFileBackupPath(relativeTarget);
    if (!localizeDir || !backupPath || ![fm fileExistsAtPath:backupPath]) {
        ZLog(@"[LocalizationTransplant] no backup for %@ - nothing to restore", relativeTarget);
        return NO;
    }

    NSString *targetPath = [localizeDir stringByAppendingPathComponent:relativeTarget];
    if (![fm contentsEqualAtPath:targetPath andPath:modPath]) {
        ZLog(@"[LocalizationTransplant] %@ no longer matches this mod - leaving it as is", relativeTarget);
        return NO;
    }
    return [self lt_restoreFileBackupAtPath:backupPath toRelativeTarget:relativeTarget force:YES];
}

+ (BOOL)restorePackForLanguage:(NSString *)languageCode ifAppliedFromPackAtPath:(NSString *)packPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!LTIsValidLanguageCode(languageCode)) return NO;

    NSString *markerPath = LTPackMarkerPath(languageCode);
    NSString *appliedFingerprint = markerPath
        ? [NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:nil]
        : nil;
    if (appliedFingerprint.length == 0 || ![fm fileExistsAtPath:packPath]) {
        ZLog(@"[LocalizationTransplant] no pack is applied to the \"%@\" language folder - nothing to restore", languageCode);
        return NO;
    }
    if (![appliedFingerprint isEqualToString:LTPackFingerprint(packPath)]) {
        ZLog(@"[LocalizationTransplant] the \"%@\" language folder holds a different pack - leaving it as is", languageCode);
        return NO;
    }
    return [self lt_restorePackBackupForLanguage:languageCode force:YES];
}

+ (NSInteger)restoreAllBackupsForce:(BOOL)force error:(NSError **)error {
    NSInteger restored = 0;
    for (NSString *languageCode in LTLanguageCodes()) {
        restored += [self lt_restoreFileBackupsForLanguage:languageCode force:force];
    }
    for (NSString *languageCode in LTLanguageCodes()) {
        if ([self lt_restorePackBackupForLanguage:languageCode force:force]) restored++;
    }
    return restored;
}

+ (NSArray<NSString *> *)documentsRelativePathsOfSwappedFiles {
    NSString *localizeDir = [self localizeDirectory];
    NSString *base = [self backupDirectory];
    if (!localizeDir || !base) return @[];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];

    NSString *filesRoot = [base stringByAppendingPathComponent:kLTFileBackupsDirectoryName];
    NSDirectoryEnumerator *fileBackups = [fm enumeratorAtPath:filesRoot];
    for (NSString *relative in fileBackups) {
        if (![relative hasSuffix:kLTBackupSuffix]) continue;
        if (![fileBackups.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;

        NSString *relativeTarget = [relative substringToIndex:relative.length - kLTBackupSuffix.length];
        NSString *livePath = [localizeDir stringByAppendingPathComponent:relativeTarget];
        NSString *backupPath = [filesRoot stringByAppendingPathComponent:relative];
        if (![fm fileExistsAtPath:livePath]) continue;
        if ([fm contentsEqualAtPath:livePath andPath:backupPath]) continue;

        [result addObject:[kLTLocalizeRelativePath stringByAppendingPathComponent:relativeTarget]];
    }

    for (NSString *languageCode in LTLanguageCodes()) {
        NSString *packBackup = LTPackBackupPath(languageCode);
        NSString *languageDir = [self languageDirectoryForCode:languageCode];
        if (!packBackup || !languageDir || ![fm fileExistsAtPath:packBackup]) continue;

        NSDirectoryEnumerator *packFiles = [fm enumeratorAtPath:packBackup];
        for (NSString *relative in packFiles) {
            if (![packFiles.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;

            NSString *livePath = [languageDir stringByAppendingPathComponent:relative];
            NSString *backupPath = [packBackup stringByAppendingPathComponent:relative];
            if (![fm fileExistsAtPath:livePath]) continue;
            if ([fm contentsEqualAtPath:livePath andPath:backupPath]) continue;

            NSString *relativeTarget = [languageCode stringByAppendingPathComponent:relative];
            [result addObject:[kLTLocalizeRelativePath stringByAppendingPathComponent:relativeTarget]];
        }
    }

    return result.array;
}

@end

#pragma mark - LunartiqueModArchive

NSString * const LunartiqueModArchiveErrorDomain = @"LunartiqueModArchiveErrorDomain";

static NSError *LMAError(LunartiqueModArchiveErrorCode code, NSString *message) {
    return [NSError errorWithDomain:LunartiqueModArchiveErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation LunartiqueModEntry
- (instancetype)initWithHash1:(NSString *)h1 hash2:(NSString *)h2 dataEntryName:(NSString *)dataName {
    if ((self = [super init])) {
        _cacheHash1 = [h1 copy];
        _cacheHash2 = [h2 copy];
        _dataEntryName = [dataName copy];
    }
    return self;
}
@end

@interface LMACDRecord : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint16_t method;
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t uncompressedSize;
@property (nonatomic, assign) uint32_t localHeaderOffset;
@end

@implementation LMACDRecord
@end

@implementation LunartiqueModArchive

#pragma mark - Byte helpers (all ZIP fields are little-endian)

static uint16_t lma_read_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}
static uint32_t lma_read_u32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24));
}

#pragma mark - End Of Central Directory

static const uint32_t kEOCDSignature = 0x06054b50;
static const uint32_t kCDFileHeaderSignature = 0x02014b50;
static const uint32_t kLocalFileHeaderSignature = 0x04034b50;

+ (nullable NSData *)lma_mappedDataForZipAtURL:(NSURL *)zipURL error:(NSError **)error {
    NSError *readErr = nil;
    NSData *data = [NSData dataWithContentsOfURL:zipURL options:NSDataReadingMappedIfSafe error:&readErr];
    if (!data) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCantReadFile,
            [NSString stringWithFormat:@"Couldn't read %@: %@", zipURL.lastPathComponent, readErr.localizedDescription ?: @"unknown error"]);
        return nil;
    }
    return data;
}

+ (BOOL)lma_findEOCDInData:(NSData *)data cdOffset:(uint32_t *)outCDOffset cdSize:(uint32_t *)outCDSize entryCount:(uint16_t *)outCount error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (length < 22) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNotAZip, @"File is too small to be a zip.");
        return NO;
    }

    NSUInteger searchWindow = MIN((NSUInteger)(22 + 65535), length);
    NSUInteger start = length - searchWindow;

    for (NSInteger i = (NSInteger)(length - 22); i >= (NSInteger)start; i--) {
        const uint8_t *p = bytes + i;
        if (lma_read_u32(p) == kEOCDSignature) {
            uint16_t commentLen = lma_read_u16(p + 20);
            if (i + 22 + commentLen != (NSInteger)length) continue;
            if (outCDOffset) *outCDOffset = lma_read_u32(p + 16);
            if (outCDSize) *outCDSize = lma_read_u32(p + 12);
            if (outCount) *outCount = lma_read_u16(p + 10);
            return YES;
        }
    }

    if (error) *error = LMAError(LunartiqueModArchiveErrorNotAZip, @"No End Of Central Directory record found - not a valid zip.");
    return NO;
}

#pragma mark - Central Directory walk

+ (nullable NSArray<LMACDRecord *> *)lma_centralDirectoryRecordsForData:(NSData *)data error:(NSError **)error {
    uint32_t cdOffset = 0, cdSize = 0;
    uint16_t count = 0;
    if (![self lma_findEOCDInData:data cdOffset:&cdOffset cdSize:&cdSize entryCount:&count error:error]) return nil;

    NSUInteger length = data.length;
    if ((NSUInteger)cdOffset + cdSize > length) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNotAZip, @"Central Directory offset/size runs past end of file - corrupt or ZIP64 (unsupported).");
        return nil;
    }

    const uint8_t *bytes = data.bytes;
    NSMutableArray<LMACDRecord *> *records = [NSMutableArray arrayWithCapacity:count];
    NSUInteger cursor = cdOffset;
    NSUInteger cdEnd = (NSUInteger)cdOffset + cdSize;

    for (uint16_t i = 0; i < count && cursor + 46 <= cdEnd; i++) {
        const uint8_t *p = bytes + cursor;
        if (lma_read_u32(p) != kCDFileHeaderSignature) break;

        uint16_t method = lma_read_u16(p + 10);
        uint32_t compSize = lma_read_u32(p + 20);
        uint32_t uncompSize = lma_read_u32(p + 24);
        uint16_t nameLen = lma_read_u16(p + 28);
        uint16_t extraLen = lma_read_u16(p + 30);
        uint16_t commentLen = lma_read_u16(p + 32);
        uint32_t localOffset = lma_read_u32(p + 42);

        NSUInteger nameStart = cursor + 46;
        if (nameStart + nameLen > cdEnd) break;
        NSString *name = [[NSString alloc] initWithBytes:(bytes + nameStart) length:nameLen encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithBytes:(bytes + nameStart) length:nameLen encoding:NSISOLatin1StringEncoding];

        LMACDRecord *rec = [LMACDRecord new];
        rec.name = name ?: @"";
        rec.method = method;
        rec.compressedSize = compSize;
        rec.uncompressedSize = uncompSize;
        rec.localHeaderOffset = localOffset;
        [records addObject:rec];

        cursor = nameStart + nameLen + extraLen + commentLen;
    }

    return records;
}

#pragma mark - Matching "Installation/<hex32>/<hex32>/__data"

static BOOL lma_isHex32(NSString *s) {
    if (s.length != 32) return NO;
    for (NSUInteger i = 0; i < 32; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!isHex) return NO;
    }
    return YES;
}

+ (nullable NSArray<LunartiqueModEntry *> *)matchedEntriesInZipAtURL:(NSURL *)zipURL error:(NSError **)error {
    NSData *data = [self lma_mappedDataForZipAtURL:zipURL error:error];
    if (!data) return nil;

    NSArray<LMACDRecord *> *records = [self lma_centralDirectoryRecordsForData:data error:error];
    if (!records) return nil;

    NSMutableArray<LunartiqueModEntry *> *matches = [NSMutableArray array];
    for (LMACDRecord *rec in records) {
        NSString *normalized = [rec.name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        NSArray<NSString *> *comps = [normalized componentsSeparatedByString:@"/"];
        if (comps.count < 4) continue;
        NSString *last = comps.lastObject;
        if (![last isEqualToString:@"__data"]) continue;

        NSUInteger hash1Index = comps.count - 3;
        NSString *hash2 = comps[comps.count - 2];
        NSString *hash1 = comps[hash1Index];
        if (!lma_isHex32(hash1) || !lma_isHex32(hash2)) continue;

        BOOL underInstallation = NO;
        for (NSUInteger i = 0; i < hash1Index; i++) {
            if ([comps[i] caseInsensitiveCompare:@"Installation"] == NSOrderedSame) { underInstallation = YES; break; }
        }
        if (!underInstallation) continue;

        LunartiqueModEntry *entry = [[LunartiqueModEntry alloc] initWithHash1:hash1.lowercaseString
                                                                          hash2:hash2.lowercaseString
                                                                  dataEntryName:rec.name];
        [matches addObject:entry];
    }

    if (matches.count == 0) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNoMatchingTree,
            @"No Installation/<hash>/<hash>/__data entry found - doesn't match the Lunartique format's file tree.");
        return @[];
    }

    return matches;
}

+ (BOOL)isLunartiqueFormatZipAtURL:(NSURL *)zipURL error:(NSError * _Nullable * _Nullable)error {
    NSError *innerErr = nil;
    NSArray<LunartiqueModEntry *> *matches = [self matchedEntriesInZipAtURL:zipURL error:&innerErr];
    if (!matches) {
        if (error) *error = innerErr;
        return NO;
    }
    if (matches.count == 0) {
        if (error) *error = innerErr ?: LMAError(LunartiqueModArchiveErrorNoMatchingTree, @"No matching Installation tree found.");
        return NO;
    }
    return YES;
}

#pragma mark - Extraction

+ (BOOL)lma_dataRangeForRecord:(LMACDRecord *)rec inData:(NSData *)data start:(NSUInteger *)outStart error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger off = rec.localHeaderOffset;
    if (off + 30 > length) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry, @"Local file header offset runs past end of file.");
        return NO;
    }
    const uint8_t *p = bytes + off;
    if (lma_read_u32(p) != kLocalFileHeaderSignature) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry, @"Local file header signature mismatch.");
        return NO;
    }
    uint16_t nameLen = lma_read_u16(p + 26);
    uint16_t extraLen = lma_read_u16(p + 28);
    NSUInteger dataStart = off + 30 + nameLen + extraLen;
    if (dataStart + rec.compressedSize > length) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry, @"Entry data runs past end of file.");
        return NO;
    }
    *outStart = dataStart;
    return YES;
}

+ (nullable NSData *)lma_inflatedDataForRecord:(LMACDRecord *)rec inData:(NSData *)data error:(NSError **)error {
    NSUInteger dataStart = 0;
    if (![self lma_dataRangeForRecord:rec inData:data start:&dataStart error:error]) return nil;

    NSData *compressed = [data subdataWithRange:NSMakeRange(dataStart, rec.compressedSize)];

    if (rec.method == 0) {
        return compressed;
    }
    if (rec.method != 8) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorUnsupportedCompression,
            [NSString stringWithFormat:@"\"%@\" uses zip compression method %u - only stored(0)/deflate(8) are supported.", rec.name, rec.method]);
        return nil;
    }

    if (rec.uncompressedSize == 0) return [NSData data];

    NSMutableData *out = [NSMutableData dataWithLength:rec.uncompressedSize];

    size_t decoded = compression_decode_buffer(out.mutableBytes, rec.uncompressedSize,
                                                compressed.bytes, compressed.length,
                                                NULL, COMPRESSION_ZLIB);
    if (decoded != rec.uncompressedSize) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry,
            [NSString stringWithFormat:@"Deflate decode of \"%@\" produced %zu bytes, expected %u.", rec.name, decoded, rec.uncompressedSize]);
        return nil;
    }
    return out;
}

+ (nullable LMACDRecord *)lma_recordNamed:(NSString *)name inRecords:(NSArray<LMACDRecord *> *)records {
    for (LMACDRecord *rec in records) {
        if ([rec.name isEqualToString:name]) return rec;
    }
    return nil;
}

+ (BOOL)extractDataForEntry:(LunartiqueModEntry *)entry
                   fromZipAtURL:(NSURL *)zipURL
                        dataURL:(NSURL * _Nullable * _Nonnull)outDataURL
                          error:(NSError **)error {
    *outDataURL = nil;

    NSData *data = [self lma_mappedDataForZipAtURL:zipURL error:error];
    if (!data) return NO;

    NSArray<LMACDRecord *> *records = [self lma_centralDirectoryRecordsForData:data error:error];
    if (!records) return NO;

    LMACDRecord *dataRec = [self lma_recordNamed:entry.dataEntryName inRecords:records];
    if (!dataRec) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry,
            [NSString stringWithFormat:@"\"%@\" no longer found in the zip's Central Directory.", entry.dataEntryName]);
        return NO;
    }

    NSError *inflateErr = nil;
    NSData *dataBytes = [self lma_inflatedDataForRecord:dataRec inData:data error:&inflateErr];
    if (!dataBytes) {
        if (error) *error = inflateErr;
        return NO;
    }

    NSURL *tmpDir = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *dataOut = [tmpDir URLByAppendingPathComponent:[NSString stringWithFormat:@"lunartique-%@-data", NSUUID.UUID.UUIDString]];
    NSError *writeErr = nil;
    if (![dataBytes writeToURL:dataOut options:NSDataWritingAtomic error:&writeErr]) {
        if (error) *error = writeErr ?: LMAError(LunartiqueModArchiveErrorExtractionFailed, @"Couldn't write extracted __data to a temp file.");
        return NO;
    }
    *outDataURL = dataOut;

    return YES;
}

+ (nullable NSArray<NSString *> *)matchedBankEntryNamesInZipAtURL:(NSURL *)zipURL error:(NSError **)error {
    NSData *data = [self lma_mappedDataForZipAtURL:zipURL error:error];
    if (!data) return nil;

    NSArray<LMACDRecord *> *records = [self lma_centralDirectoryRecordsForData:data error:error];
    if (!records) return nil;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (LMACDRecord *rec in records) {
        NSString *normalized = [rec.name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if ([normalized.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) {
            [names addObject:rec.name];
        }
    }
    return names;
}

+ (BOOL)extractBankEntryNamed:(NSString *)entryName
                   fromZipAtURL:(NSURL *)zipURL
                        bankURL:(NSURL * _Nullable * _Nonnull)outBankURL
                          error:(NSError **)error {
    *outBankURL = nil;

    NSData *data = [self lma_mappedDataForZipAtURL:zipURL error:error];
    if (!data) return NO;

    NSArray<LMACDRecord *> *records = [self lma_centralDirectoryRecordsForData:data error:error];
    if (!records) return NO;

    LMACDRecord *rec = [self lma_recordNamed:entryName inRecords:records];
    if (!rec) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry,
            [NSString stringWithFormat:@"\"%@\" no longer found in the zip's Central Directory.", entryName]);
        return NO;
    }

    NSError *inflateErr = nil;
    NSData *bankBytes = [self lma_inflatedDataForRecord:rec inData:data error:&inflateErr];
    if (!bankBytes) {
        if (error) *error = inflateErr;
        return NO;
    }

    NSURL *tmpDir = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *bankOut = [tmpDir URLByAppendingPathComponent:[NSString stringWithFormat:@"lunartique-%@-%@", NSUUID.UUID.UUIDString, entryName.lastPathComponent]];
    NSError *writeErr = nil;
    if (![bankBytes writeToURL:bankOut options:NSDataWritingAtomic error:&writeErr]) {
        if (error) *error = writeErr ?: LMAError(LunartiqueModArchiveErrorExtractionFailed, @"Couldn't write extracted bank to a temp file.");
        return NO;
    }
    *outBankURL = bankOut;
    return YES;
}

+ (nullable NSArray<NSString *> *)allEntryNamesInZipAtURL:(NSURL *)zipURL error:(NSError **)error {
    NSData *data = [self lma_mappedDataForZipAtURL:zipURL error:error];
    if (!data) return nil;

    NSArray<LMACDRecord *> *records = [self lma_centralDirectoryRecordsForData:data error:error];
    if (!records) return nil;

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:records.count];
    for (LMACDRecord *rec in records) [names addObject:rec.name];
    return names;
}

+ (BOOL)extractAllEntriesOfZipAtURL:(NSURL *)zipURL
                     toDirectoryURL:(NSURL *)directoryURL
                              error:(NSError **)error {
    NSData *data = [self lma_mappedDataForZipAtURL:zipURL error:error];
    if (!data) return NO;

    NSArray<LMACDRecord *> *records = [self lma_centralDirectoryRecordsForData:data error:error];
    if (!records) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *rootPath = directoryURL.path;
    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        if (error) *error = dirErr ?: LMAError(LunartiqueModArchiveErrorExtractionFailed, @"Couldn't create a temp folder to extract into.");
        return NO;
    }

    for (LMACDRecord *rec in records) {
        NSString *normalized = [rec.name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        BOOL isDirectoryEntry = [normalized hasSuffix:@"/"];

        NSMutableArray<NSString *> *components = [NSMutableArray array];
        for (NSString *component in [normalized componentsSeparatedByString:@"/"]) {
            if (component.length == 0 || [component isEqualToString:@"."]) continue;
            if ([component isEqualToString:@".."]) {
                if (error) *error = LMAError(LunartiqueModArchiveErrorCorruptEntry,
                    [NSString stringWithFormat:@"\"%@\" tries to escape the extraction folder.", rec.name]);
                return NO;
            }
            [components addObject:component];
        }
        if (components.count == 0 || [LocalizationTransplant isJunkArchivePathComponents:components]) continue;

        NSString *destPath = [rootPath stringByAppendingPathComponent:[components componentsJoinedByString:@"/"]];
        if (isDirectoryEntry) {
            [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }

        NSError *parentErr = nil;
        if (![fm createDirectoryAtPath:destPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&parentErr]) {
            if (error) *error = parentErr ?: LMAError(LunartiqueModArchiveErrorExtractionFailed, @"Couldn't create a folder while extracting.");
            return NO;
        }

        NSError *inflateErr = nil;
        NSData *bytes = [self lma_inflatedDataForRecord:rec inData:data error:&inflateErr];
        if (!bytes) {
            if (error) *error = inflateErr;
            return NO;
        }

        NSError *writeErr = nil;
        if (![bytes writeToFile:destPath options:0 error:&writeErr]) {
            if (error) *error = writeErr ?: LMAError(LunartiqueModArchiveErrorExtractionFailed,
                [NSString stringWithFormat:@"Couldn't write \"%@\" while extracting.", rec.name]);
            return NO;
        }
    }
    return YES;
}

@end

#pragma mark - Carra2ModArchive

@implementation Carra2ArchiveInfo
- (instancetype)initWithHash1:(NSString *)h1 hash2:(NSString *)h2 {
    if ((self = [super init])) {
        _hash1 = [h1 copy];
        _hash2 = [h2 copy];
    }
    return self;
}
@end

@implementation Carra2ModArchive

+ (nullable Carra2ArchiveInfo *)archiveInfoForZipAtURL:(NSURL *)zipURL error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfURL:zipURL options:NSDataReadingMappedIfSafe error:error];
    if (!data) return nil;

    NSUInteger length = data.length;
    if (length < 22) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNotAZip, @"File is too small to be a zip.");
        return nil;
    }
    const uint8_t *bytes = data.bytes;

    NSUInteger searchWindow = MIN((NSUInteger)(22 + 65535), length);
    NSUInteger start = length - searchWindow;
    uint32_t cdOffset = 0, cdSize = 0;
    uint16_t count = 0;
    BOOL foundEOCD = NO;
    for (NSInteger i = (NSInteger)(length - 22); i >= (NSInteger)start; i--) {
        const uint8_t *p = bytes + i;
        if (lma_read_u32(p) == kEOCDSignature) {
            uint16_t commentLen = lma_read_u16(p + 20);
            if (i + 22 + commentLen != (NSInteger)length) continue;
            cdOffset = lma_read_u32(p + 16);
            cdSize = lma_read_u32(p + 12);
            count = lma_read_u16(p + 10);
            foundEOCD = YES;
            break;
        }
    }
    if (!foundEOCD) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNotAZip, @"No End Of Central Directory record found - not a valid zip.");
        return nil;
    }
    if ((NSUInteger)cdOffset + cdSize > length) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNotAZip,
            @"Central Directory offset/size runs past end of file - corrupt or ZIP64 (unsupported).");
        return nil;
    }

    NSUInteger cursor = cdOffset;
    NSUInteger cdEnd = (NSUInteger)cdOffset + cdSize;
    NSString *matchedHash1 = nil, *matchedHash2 = nil;

    for (uint16_t i = 0; i < count && cursor + 46 <= cdEnd; i++) {
        const uint8_t *p = bytes + cursor;
        if (lma_read_u32(p) != kCDFileHeaderSignature) break;

        uint16_t nameLen = lma_read_u16(p + 28);
        uint16_t extraLen = lma_read_u16(p + 30);
        uint16_t commentLen = lma_read_u16(p + 32);

        NSUInteger nameStart = cursor + 46;
        if (nameStart + nameLen > cdEnd) break;
        NSString *name = [[NSString alloc] initWithBytes:(bytes + nameStart) length:nameLen encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithBytes:(bytes + nameStart) length:nameLen encoding:NSISOLatin1StringEncoding];

        NSString *normalized = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        NSArray<NSString *> *comps = [normalized componentsSeparatedByString:@"/"];
        if (!matchedHash1 && comps.count >= 2 && lma_isHex32(comps[0]) && lma_isHex32(comps[1])) {
            matchedHash1 = comps[0].lowercaseString;
            matchedHash2 = comps[1].lowercaseString;
            break;
        }

        cursor = nameStart + nameLen + extraLen + commentLen;
    }

    if (!matchedHash1 || !matchedHash2) {
        if (error) *error = LMAError(LunartiqueModArchiveErrorNoMatchingTree,
            @"No <hash>/<hash>/... entry found - doesn't match the Carra2 format's file tree.");
        return nil;
    }

    return [[Carra2ArchiveInfo alloc] initWithHash1:matchedHash1 hash2:matchedHash2];
}

@end

#pragma mark - ModAssetLibrary

NSString * const ModAssetLibraryErrorDomain = @"ModAssetLibraryErrorDomain";
NSString * const ModAssetLibraryOverlapPhrase = @"same game file as";
static NSString * const kMALStoredBundlesFolderName = @"Stored Bundles";
static NSString * const kMALManifestFileName = @"manifest.json";
static NSString * const kMALFolderRemarkFileName = @"remark.txt";
static NSString * const kMALOriginalBundleBackupsDirectoryName = @".OriginalBundleBackups";

static NSError *MALError(ModAssetLibraryErrorCode code, NSString *message) {
    return [NSError errorWithDomain:ModAssetLibraryErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static ZSFontRole MALFontRoleFromValue(id value) {
    if (![value isKindOfClass:NSNumber.class]) return ZSFontRoleNone;
    NSInteger raw = [value integerValue];
    if (raw < ZSFontRoleTitle || raw > ZSFontRoleKanjiHanzi) return ZSFontRoleNone;
    return (ZSFontRole)raw;
}

@implementation ModAssetLibraryEntry

- (NSDictionary<NSString *, id> *)mal_dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"fileName"] = self.fileName;
    d[@"path"] = self.path;
    d[@"byteSize"] = @(self.byteSize);
    d[@"dateAdded"] = self.dateAdded;
    if (self.livePathDescription) d[@"livePathDescription"] = self.livePathDescription;
    if (self.resolvedInstallTargetPath) d[@"resolvedInstallTargetPath"] = self.resolvedInstallTargetPath;
    if (self.zipCacheHash1) d[@"zipCacheHash1"] = self.zipCacheHash1;
    if (self.zipCacheHash2) d[@"zipCacheHash2"] = self.zipCacheHash2;
    if (self.remark.length > 0) d[@"remark"] = self.remark;
    if (self.localizationKind != ModAssetLibraryLocalizationKindNone) d[@"localizationKind"] = @(self.localizationKind);
    if (self.localizationLanguage.length > 0) d[@"localizationLanguage"] = self.localizationLanguage;
    if (self.localizationRelativePath.length > 0) d[@"localizationRelativePath"] = self.localizationRelativePath;
    if (self.cachedFromFolder.length > 0) d[@"cachedFromFolder"] = self.cachedFromFolder;
    if (self.isAssetBundle) d[@"isAssetBundle"] = @YES;
    if (self.fontRole != ZSFontRoleNone) d[@"fontRole"] = @(self.fontRole);
    if (self.cabIdentifier) d[@"cabIdentifier"] = self.cabIdentifier;
    if (self.targetPlatform) d[@"targetPlatform"] = self.targetPlatform;

    if (self.doctorStatus != ModAssetLibraryDoctorStatusNotDispatched) d[@"doctorStatus"] = @(self.doctorStatus);
    if (self.doctorUploadProgress != 0) d[@"doctorUploadProgress"] = @(self.doctorUploadProgress);
    if (self.doctorUploadTotalBytes != 0) d[@"doctorUploadTotalBytes"] = @(self.doctorUploadTotalBytes);
    if (self.doctorProcessProgress != 0.0) d[@"doctorProcessProgress"] = @(self.doctorProcessProgress);
    if (self.doctorDownloadProgress != 0) d[@"doctorDownloadProgress"] = @(self.doctorDownloadProgress);
    if (self.doctorDispatchCompressedByteSize != 0) d[@"doctorDispatchCompressedByteSize"] = @(self.doctorDispatchCompressedByteSize);
    if (self.doctorScratchBranch) d[@"doctorScratchBranch"] = self.doctorScratchBranch;
    if (self.doctorRunID) d[@"doctorRunID"] = self.doctorRunID;
    if (self.doctorRunURL) d[@"doctorRunURL"] = self.doctorRunURL;
    if (self.doctorLastError) d[@"doctorLastError"] = self.doctorLastError;
    if (self.doctorTranscodeCodec) d[@"doctorTranscodeCodec"] = self.doctorTranscodeCodec;
    return d;
}

+ (nullable instancetype)mal_fromDictionary:(NSDictionary<NSString *, id> *)d {
    if (![d[@"fileName"] isKindOfClass:NSString.class] || ![d[@"path"] isKindOfClass:NSString.class]) return nil;
    ModAssetLibraryEntry *e = [ModAssetLibraryEntry new];
    e.fileName = d[@"fileName"];
    e.path = d[@"path"];
    e.byteSize = [d[@"byteSize"] unsignedLongLongValue];
    e.dateAdded = [d[@"dateAdded"] isKindOfClass:NSString.class] ? d[@"dateAdded"] : @"";
    e.livePathDescription = [d[@"livePathDescription"] isKindOfClass:NSString.class] ? d[@"livePathDescription"] : nil;
    e.resolvedInstallTargetPath = [d[@"resolvedInstallTargetPath"] isKindOfClass:NSString.class] ? d[@"resolvedInstallTargetPath"] : nil;
    e.zipCacheHash1 = [d[@"zipCacheHash1"] isKindOfClass:NSString.class] ? d[@"zipCacheHash1"] : nil;
    e.zipCacheHash2 = [d[@"zipCacheHash2"] isKindOfClass:NSString.class] ? d[@"zipCacheHash2"] : nil;
    e.remark = [d[@"remark"] isKindOfClass:NSString.class] ? d[@"remark"] : nil;
    e.cachedFromFolder = [d[@"cachedFromFolder"] isKindOfClass:NSString.class] ? d[@"cachedFromFolder"] : nil;
    NSInteger rawLocalizationKind = [d[@"localizationKind"] isKindOfClass:NSNumber.class] ? [d[@"localizationKind"] integerValue] : 0;
    e.localizationKind = (rawLocalizationKind == ModAssetLibraryLocalizationKindJSON || rawLocalizationKind == ModAssetLibraryLocalizationKindPack)
        ? (ModAssetLibraryLocalizationKind)rawLocalizationKind : ModAssetLibraryLocalizationKindNone;
    e.localizationLanguage = [d[@"localizationLanguage"] isKindOfClass:NSString.class] ? d[@"localizationLanguage"] : nil;
    e.localizationRelativePath = [d[@"localizationRelativePath"] isKindOfClass:NSString.class] ? d[@"localizationRelativePath"] : nil;

    e.isAssetBundle = [d[@"isAssetBundle"] isKindOfClass:NSNumber.class] && [d[@"isAssetBundle"] boolValue];
    e.fontRole = MALFontRoleFromValue(d[@"fontRole"]);
    e.cabIdentifier = [d[@"cabIdentifier"] isKindOfClass:NSString.class] ? d[@"cabIdentifier"] : nil;
    e.targetPlatform = [d[@"targetPlatform"] isKindOfClass:NSNumber.class] ? d[@"targetPlatform"] : nil;

    id rawStatus = d[@"doctorStatus"];
    NSInteger status = [rawStatus isKindOfClass:NSNumber.class] ? [rawStatus integerValue] : ModAssetLibraryDoctorStatusNotDispatched;
    e.doctorStatus = (status >= ModAssetLibraryDoctorStatusNotDispatched && status <= ModAssetLibraryDoctorStatusInstalled)
        ? (ModAssetLibraryDoctorStatus)status : ModAssetLibraryDoctorStatusNotDispatched;
    e.doctorUploadProgress = [d[@"doctorUploadProgress"] isKindOfClass:NSNumber.class] ? [d[@"doctorUploadProgress"] longLongValue] : 0;
    e.doctorUploadTotalBytes = [d[@"doctorUploadTotalBytes"] isKindOfClass:NSNumber.class] ? [d[@"doctorUploadTotalBytes"] longLongValue] : 0;
    e.doctorProcessProgress = [d[@"doctorProcessProgress"] isKindOfClass:NSNumber.class] ? [d[@"doctorProcessProgress"] doubleValue] : 0.0;
    e.doctorDownloadProgress = [d[@"doctorDownloadProgress"] isKindOfClass:NSNumber.class] ? [d[@"doctorDownloadProgress"] longLongValue] : 0;
    e.doctorDispatchCompressedByteSize = [d[@"doctorDispatchCompressedByteSize"] isKindOfClass:NSNumber.class] ? [d[@"doctorDispatchCompressedByteSize"] unsignedLongLongValue] : 0;
    e.doctorScratchBranch = [d[@"doctorScratchBranch"] isKindOfClass:NSString.class] ? d[@"doctorScratchBranch"] : nil;
    e.doctorRunID = [d[@"doctorRunID"] isKindOfClass:NSString.class] ? d[@"doctorRunID"] : nil;
    e.doctorRunURL = [d[@"doctorRunURL"] isKindOfClass:NSString.class] ? d[@"doctorRunURL"] : nil;
    e.doctorLastError = [d[@"doctorLastError"] isKindOfClass:NSString.class] ? d[@"doctorLastError"] : nil;
    e.doctorTranscodeCodec = [d[@"doctorTranscodeCodec"] isKindOfClass:NSString.class] ? d[@"doctorTranscodeCodec"] : nil;
    return e;
}

@end

@interface ModAssetLibrary ()
+ (nullable NSString *)mal_legacyModLibraryRootDirectory;
+ (NSString *)mal_manifestPathForFolder:(NSString *)folderName;
+ (NSString *)mal_remarkPathForFolder:(NSString *)folderName;
+ (BOOL)mal_writeEntries:(NSArray<ModAssetLibraryEntry *> *)entries toFolder:(NSString *)folderName error:(NSError **)error;
+ (NSString *)mal_uniqueFileNameFor:(NSString *)desired inFolder:(NSString *)folderPath;
+ (NSString *)mal_uniqueFolderNameFor:(NSString *)desired inParentFolder:(NSString *)parentPath;
+ (nullable NSString *)mal_livePathDescriptionForFileName:(NSString *)fileName;
+ (void)mal_reconcileEntryPaths:(NSArray<ModAssetLibraryEntry *> *)entries folderName:(NSString *)folderName;
+ (NSString *)mal_gameBundleRelativePath:(NSString *)path;
+ (BOOL)mal_folderIsStored:(nullable NSString *)folderName;
+ (nullable NSString *)mal_normalizedTargetPath:(nullable NSString *)path;
+ (nullable NSString *)mal_targetKeyForEntry:(ModAssetLibraryEntry *)entry;
+ (nullable ModAssetLibraryEntry *)mal_activeEntryForTargetPath:(nullable NSString *)targetPath
                                                   pendingFolder:(nullable NSString *)pendingFolder
                                                  pendingEntries:(nullable NSArray<ModAssetLibraryEntry *> *)pendingEntries
                                                   excludingPath:(nullable NSString *)excludedEntryPath;
@end

@implementation ModAssetLibrary

+ (NSString *)liveGamePathDescriptionForInstalledURL:(NSURL *)installedURL {
    return [self mal_sandboxRelativePath:installedURL.path];
}

+ (nullable NSString *)mal_legacyModLibraryRootDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityModsLibrary"];
}

+ (NSString *)modLibraryRootDirectory {
    NSString *newDir = [ZSModsPaths modsLibraryDirectory];
    NSString *legacyDir = [self mal_legacyModLibraryRootDirectory];

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL legacyIsDir = NO;
    BOOL legacyExists = legacyDir.length > 0 && [fm fileExistsAtPath:legacyDir isDirectory:&legacyIsDir] && legacyIsDir;
    if (legacyExists && ![fm fileExistsAtPath:newDir]) {

        NSString *legacyBackups = [legacyDir stringByAppendingPathComponent:kMALOriginalBundleBackupsDirectoryName];
        BOOL legacyBackupsIsDir = NO;
        BOOL legacyBackupsExists = [fm fileExistsAtPath:legacyBackups isDirectory:&legacyBackupsIsDir] && legacyBackupsIsDir;
        NSString *stagedBackups = nil;
        if (legacyBackupsExists) {
            stagedBackups = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
            [fm moveItemAtPath:legacyBackups toPath:stagedBackups error:nil];
        }

        [ZSModsPaths migrateLegacyDirectoryAtPath:legacyDir toPath:newDir];

        if (stagedBackups) {
            NSString *newAssetsBackups = [ZSModsPaths modsBackupsAssetsDirectory];
            [ZSModsPaths migrateLegacyDirectoryAtPath:stagedBackups toPath:newAssetsBackups];
            [fm removeItemAtPath:stagedBackups error:nil];
        }
    }
    return newDir;
}

+ (NSString *)mal_manifestPathForFolder:(NSString *)folderName {
    return [[[self modLibraryRootDirectory] stringByAppendingPathComponent:folderName]
                stringByAppendingPathComponent:kMALManifestFileName];
}

+ (NSString *)mal_remarkPathForFolder:(NSString *)folderName {
    return [[[self modLibraryRootDirectory] stringByAppendingPathComponent:folderName]
                stringByAppendingPathComponent:kMALFolderRemarkFileName];
}

+ (NSString *)originalBundleBackupsDirectory {
    return [ZSModsPaths modsBackupsAssetsDirectory];
}

+ (NSArray<NSString *> *)folderNames {
    NSString *root = [self modLibraryRootDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!root || ![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) return @[];

    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    for (NSString *entry in entries) {
        NSString *full = [root stringByAppendingPathComponent:entry];
        BOOL entryIsDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&entryIsDir] && entryIsDir) {
            [folders addObject:entry];
        }
    }
    return [folders sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

+ (BOOL)createFolderNamed:(NSString *)name error:(NSError **)error {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed containsString:@"/"]) {
        if (error) *error = MALError(ModAssetLibraryErrorInvalidFolderName,
            @"Folder name can't be empty or contain \"/\".");
        return NO;
    }

    NSString *root = [self modLibraryRootDirectory];
    if (!root) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound, @"Couldn't resolve the mods library directory.");
        return NO;
    }
    NSString *folderPath = [root stringByAppendingPathComponent:trimmed];

    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:folderPath]) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderAlreadyExists,
            [NSString stringWithFormat:@"A folder named \"%@\" already exists.", trimmed]);
        return NO;
    }

    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        if (error) *error = dirErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Couldn't create the folder.");
        return NO;
    }

    NSError *writeErr = nil;
    if (![self mal_writeEntries:@[] toFolder:trimmed error:&writeErr]) {
        if (error) *error = writeErr;
        return NO;
    }
    ZLog(@"[ModAssetLibrary] created folder \"%@\"", trimmed);
    return YES;
}

+ (nullable NSString *)createUniqueSubFolderNamed:(NSString *)desiredName
                                       insideFolder:(NSString *)parentFolder
                                              error:(NSError **)error {
    NSString *trimmed = [desiredName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed containsString:@"/"]
        || [trimmed isEqualToString:@"."] || [trimmed isEqualToString:@".."]) {
        if (error) *error = MALError(ModAssetLibraryErrorInvalidFolderName,
            @"Folder name can't be empty, \".\", \"..\", or contain \"/\".");
        return nil;
    }

    NSString *root = [self modLibraryRootDirectory];
    if (!root) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound, @"Couldn't resolve the mods library directory.");
        return nil;
    }

    NSString *parentPath = [root stringByAppendingPathComponent:parentFolder];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL parentIsDir = NO;
    if (![fm fileExistsAtPath:parentPath isDirectory:&parentIsDir] || !parentIsDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\".", parentFolder]);
        return nil;
    }

    NSString *uniqueLeaf = [self mal_uniqueFolderNameFor:trimmed inParentFolder:parentPath];
    NSString *relativeName = [parentFolder stringByAppendingPathComponent:uniqueLeaf];
    NSString *folderPath = [root stringByAppendingPathComponent:relativeName];

    NSError *dirErr = nil;
    if (![fm createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        if (error) *error = dirErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Couldn't create the folder.");
        return nil;
    }

    NSError *writeErr = nil;
    if (![self mal_writeEntries:@[] toFolder:relativeName error:&writeErr]) {
        [fm removeItemAtPath:folderPath error:nil];
        if (error) *error = writeErr;
        return nil;
    }
    ZLog(@"[ModAssetLibrary] created subfolder \"%@\" inside \"%@\"", relativeName, parentFolder);
    return relativeName;
}

+ (NSArray<NSString *> *)subFolderNamesInFolder:(NSString *)parentFolder {
    NSString *root = [self modLibraryRootDirectory];
    NSString *parentPath = root ? [root stringByAppendingPathComponent:parentFolder] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!parentPath || ![fm fileExistsAtPath:parentPath isDirectory:&isDir] || !isDir) return @[];

    NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:parentPath error:nil] ?: @[];
    NSMutableArray<NSString *> *subFolders = [NSMutableArray array];
    for (NSString *item in contents) {
        NSString *itemPath = [parentPath stringByAppendingPathComponent:item];
        BOOL itemIsDir = NO;
        if (![fm fileExistsAtPath:itemPath isDirectory:&itemIsDir] || !itemIsDir) continue;
        NSString *manifestPath = [itemPath stringByAppendingPathComponent:kMALManifestFileName];
        if ([fm fileExistsAtPath:manifestPath]) {
            [subFolders addObject:[parentFolder stringByAppendingPathComponent:item]];
        }
    }
    return [subFolders sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

+ (nullable NSArray<ModAssetLibraryEntry *> *)entriesInFolder:(NSString *)folderName error:(NSError **)error {
    NSString *manifestPath = [self mal_manifestPathForFolder:folderName];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:manifestPath]) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\".", folderName]);
        return nil;
    }

    NSData *data = [NSData dataWithContentsOfFile:manifestPath];
    NSArray *raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![raw isKindOfClass:NSArray.class]) {
        if (error) *error = MALError(ModAssetLibraryErrorManifestReadFailed,
            [NSString stringWithFormat:@"%@'s manifest.json is missing or unreadable.", folderName]);
        return nil;
    }

    NSMutableArray<ModAssetLibraryEntry *> *entries = [NSMutableArray array];
    for (id d in raw) {
        if (![d isKindOfClass:NSDictionary.class]) continue;
        ModAssetLibraryEntry *e = [ModAssetLibraryEntry mal_fromDictionary:d];
        if (e) {
            e.currentFolder = folderName;
            [entries addObject:e];
        }
    }

    [self mal_reconcileEntryPaths:entries folderName:folderName];
    return entries;
}

+ (void)mal_reconcileEntryPaths:(NSArray<ModAssetLibraryEntry *> *)entries folderName:(NSString *)folderName {
    NSString *root = [self modLibraryRootDirectory];
    if (!root || entries.count == 0) return;
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    NSString *folderPath = [root stringByAppendingPathComponent:folderName];

    NSArray<NSString *> *folderNameComponents = folderName.pathComponents;
    BOOL didRepair = NO;
    for (ModAssetLibraryEntry *e in entries) {
        if (e.path.length == 0 || ![e.path hasPrefix:rootPrefix]) continue;

        NSString *afterRoot = [e.path substringFromIndex:rootPrefix.length];
        NSArray<NSString *> *afterRootComponents = afterRoot.pathComponents;
        if (afterRootComponents.count <= folderNameComponents.count) continue;

        NSArray<NSString *> *restComponents = [afterRootComponents subarrayWithRange:
            NSMakeRange(folderNameComponents.count, afterRootComponents.count - folderNameComponents.count)];
        NSString *rest = [@"/" stringByAppendingString:[restComponents componentsJoinedByString:@"/"]];
        NSString *expectedPath = [folderPath stringByAppendingString:rest];
        if (![expectedPath isEqualToString:e.path]) {
            e.path = expectedPath;
            didRepair = YES;
        }
    }

    if (didRepair) {
        NSError *writeErr = nil;
        if (![self mal_writeEntries:entries toFolder:folderName error:&writeErr]) {
            ZLog(@"[ModAssetLibrary] reconciled stale entry paths in \"%@\" in memory, but couldn't persist the fix: %@",
                 folderName, writeErr.localizedDescription);
        }
    }
}

+ (BOOL)mal_writeEntries:(NSArray<ModAssetLibraryEntry *> *)entries toFolder:(NSString *)folderName error:(NSError **)error {
    NSMutableArray<NSDictionary *> *raw = [NSMutableArray arrayWithCapacity:entries.count];
    for (ModAssetLibraryEntry *e in entries) [raw addObject:[e mal_dictionaryRepresentation]];

    NSError *serErr = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingPrettyPrinted error:&serErr];
    if (!data) {
        if (error) *error = serErr ?: MALError(ModAssetLibraryErrorManifestWriteFailed, @"Couldn't serialize manifest.json.");
        return NO;
    }

    NSString *manifestPath = [self mal_manifestPathForFolder:folderName];
    NSError *writeErr = nil;
    if (![data writeToFile:manifestPath options:NSDataWritingAtomic error:&writeErr]) {
        if (error) *error = writeErr ?: MALError(ModAssetLibraryErrorManifestWriteFailed, @"Couldn't write manifest.json.");
        return NO;
    }
    return YES;
}

+ (NSString *)mal_uniqueFileNameFor:(NSString *)desired inFolder:(NSString *)folderPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *candidate = desired;
    NSString *stem = desired.stringByDeletingPathExtension;
    NSString *ext = desired.pathExtension;
    NSInteger n = 2;
    while ([fm fileExistsAtPath:[folderPath stringByAppendingPathComponent:candidate]]) {
        candidate = ext.length > 0
            ? [NSString stringWithFormat:@"%@ %ld.%@", stem, (long)n, ext]
            : [NSString stringWithFormat:@"%@ %ld", stem, (long)n];
        n++;
    }
    return candidate;
}

+ (NSString *)mal_uniqueFolderNameFor:(NSString *)desired inParentFolder:(NSString *)parentPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *candidate = desired;
    NSInteger n = 2;
    while ([fm fileExistsAtPath:[parentPath stringByAppendingPathComponent:candidate]]) {
        candidate = [NSString stringWithFormat:@"%@ %ld", desired, (long)n];
        n++;
    }
    return candidate;
}

+ (NSString *)mal_libraryRelativePath:(NSString *)path {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (libraryDir && [path hasPrefix:libraryDir]) {
        NSString *relative = [path substringFromIndex:libraryDir.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        return [@"Library/" stringByAppendingString:relative];
    }
    return [self mal_sandboxRelativePath:path];
}

+ (NSString *)mal_sandboxRelativePath:(NSString *)path {
    NSString *home = NSHomeDirectory();
    if (home && [path hasPrefix:home]) {
        NSString *relative = [path substringFromIndex:home.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        return relative;
    }
    return path;
}

+ (NSString *)mal_gameBundleRelativePath:(NSString *)path {
    NSString *appBundleDir = NSBundle.mainBundle.bundlePath;
    if (appBundleDir.length > 0 && [path hasPrefix:appBundleDir]) {
        NSString *relative = [path substringFromIndex:appBundleDir.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        return [appBundleDir.lastPathComponent stringByAppendingPathComponent:relative];
    }
    return path;
}

+ (nullable NSString *)mal_livePathDescriptionForFileName:(NSString *)fileName {
    if ([fileName.pathExtension caseInsensitiveCompare:@"bank"] != NSOrderedSame) return nil;
    NSString *bankDir = [BankTransplant mobileFMODBuildsDirectory];
    NSString *path = bankDir ? [bankDir stringByAppendingPathComponent:fileName] : fileName;
    return [self mal_libraryRelativePath:path];
}

+ (BOOL)mal_folderIsStored:(nullable NSString *)folderName {
    if (folderName.length == 0) return NO;
    if ([folderName isEqualToString:kMALStoredBundlesFolderName]) return YES;
    return [folderName hasPrefix:[kMALStoredBundlesFolderName stringByAppendingString:@"/"]];
}

+ (nullable NSString *)mal_normalizedTargetPath:(nullable NSString *)path {
    if (path.length == 0) return nil;
    NSString *normalized = [self mal_sandboxRelativePath:path];
    while ([normalized hasPrefix:@"/"]) normalized = [normalized substringFromIndex:1];
    while (normalized.length > 1 && [normalized hasSuffix:@"/"]) normalized = [normalized substringToIndex:normalized.length - 1];
    return normalized.length > 0 ? normalized : nil;
}

+ (nullable NSString *)mal_targetKeyForEntry:(ModAssetLibraryEntry *)entry {
    NSString *raw = entry.resolvedInstallTargetPath.length > 0 ? entry.resolvedInstallTargetPath : entry.livePathDescription;
    return [self mal_normalizedTargetPath:raw];
}

+ (nullable ModAssetLibraryEntry *)mal_activeEntryForTargetPath:(nullable NSString *)targetPath
                                                   pendingFolder:(nullable NSString *)pendingFolder
                                                  pendingEntries:(nullable NSArray<ModAssetLibraryEntry *> *)pendingEntries
                                                   excludingPath:(nullable NSString *)excludedEntryPath {
    NSString *key = [self mal_normalizedTargetPath:targetPath];
    if (key.length == 0) return nil;

    for (ModAssetLibraryEntry *existing in pendingEntries) {
        if (excludedEntryPath.length > 0 && [existing.path isEqualToString:excludedEntryPath]) continue;
        NSString *existingKey = [self mal_targetKeyForEntry:existing];
        if (existingKey.length > 0 && [existingKey caseInsensitiveCompare:key] == NSOrderedSame) {
            if (existing.currentFolder.length == 0) existing.currentFolder = pendingFolder;
            return existing;
        }
    }

    for (NSString *folder in [self folderNames]) {
        if ([self mal_folderIsStored:folder]) continue;
        if (pendingFolder.length > 0 && [folder isEqualToString:pendingFolder]) continue;
        NSArray<ModAssetLibraryEntry *> *folderEntries = [self entriesInFolder:folder error:nil];
        for (ModAssetLibraryEntry *existing in folderEntries) {
            if (excludedEntryPath.length > 0 && [existing.path isEqualToString:excludedEntryPath]) continue;
            NSString *existingKey = [self mal_targetKeyForEntry:existing];
            if (existingKey.length > 0 && [existingKey caseInsensitiveCompare:key] == NSOrderedSame) {
                return existing;
            }
        }
    }
    return nil;
}

+ (nullable ModAssetLibraryEntry *)activeEntryOverlappingEntry:(ModAssetLibraryEntry *)candidate {
    NSString *target = candidate.resolvedInstallTargetPath.length > 0 ? candidate.resolvedInstallTargetPath : candidate.livePathDescription;
    return [self mal_activeEntryForTargetPath:target pendingFolder:nil pendingEntries:nil excludingPath:candidate.path];
}

+ (nullable ModAssetLibraryEntry *)activeEntryOverlappingBankNamed:(NSString *)bankFileName {
    NSString *target = [self mal_livePathDescriptionForFileName:bankFileName];
    return [self mal_activeEntryForTargetPath:target pendingFolder:nil pendingEntries:nil excludingPath:nil];
}

+ (NSString *)displayNameForEntry:(ModAssetLibraryEntry *)entry {
    if ([entry.fileName isEqualToString:@"__data"]) {
        NSString *parentName = entry.path.stringByDeletingLastPathComponent.lastPathComponent;
        if (parentName.length > 0) return parentName;
    }
    return entry.fileName.length > 0 ? entry.fileName : @"unnamed mod";
}

+ (NSString *)overlapReasonForExistingEntry:(ModAssetLibraryEntry *)existing {
    NSString *folder = existing.currentFolder.length > 0 ? existing.currentFolder : @"the library";
    return [NSString stringWithFormat:@"it points to the %@ \"%@\" in \"%@\"",
            ModAssetLibraryOverlapPhrase, [self displayNameForEntry:existing], folder];
}

+ (NSString *)overlapRejectionLineForName:(NSString *)name existingEntry:(ModAssetLibraryEntry *)existing {
    return [NSString stringWithFormat:@"%@: rejected - %@", name, [self overlapReasonForExistingEntry:existing]];
}

static NSString *MALCABRejectionLine(NSString *displayName) {
    return [NSString stringWithFormat:@"%@: rejected - its CAB identifier could not be found, meaning it's either malformed or outdated", displayName];
}

+ (void)mal_collectFolderNamesFrom:(NSString *)folderName into:(NSMutableArray<NSString *> *)collected {
    [collected addObject:folderName];
    for (NSString *subFolder in [self subFolderNamesInFolder:folderName]) {
        [self mal_collectFolderNamesFrom:subFolder into:collected];
    }
}

+ (nullable ModAssetLibraryEntry *)fontEntryOccupyingRole:(ZSFontRole)role {
    if (role == ZSFontRoleNone) return nil;
    NSMutableArray<NSString *> *allFolders = [NSMutableArray array];
    for (NSString *folder in [self folderNames]) [self mal_collectFolderNamesFrom:folder into:allFolders];
    for (NSString *folder in allFolders) {
        for (ModAssetLibraryEntry *entry in [self entriesInFolder:folder error:nil]) {
            if (entry.fontRole == role && [ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) return entry;
        }
    }
    return nil;
}

+ (BOOL)activateFontForEntry:(ModAssetLibraryEntry *)entry error:(NSError **)error {
    [self deactivateFontForEntry:entry];
    NSString *fontsDir = [ZSModsPaths ensuredDirectoryAtPath:[ZSModsPaths modsFontsDirectory]];
    if (!fontsDir) {
        if (error) *error = MALError(ModAssetLibraryErrorCopyFailed, @"Couldn't prepare the Fonts directory.");
        return NO;
    }
    NSString *destName = [self mal_uniqueFileNameFor:entry.fileName inFolder:fontsDir];
    NSString *destPath = [fontsDir stringByAppendingPathComponent:destName];
    NSError *copyErr = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:entry.path toPath:destPath error:&copyErr]) {
        if (error) *error = copyErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Couldn't activate the font file.");
        return NO;
    }
    entry.livePathDescription = [self mal_sandboxRelativePath:destPath];
    return YES;
}

+ (void)deactivateFontForEntry:(ModAssetLibraryEntry *)entry {
    NSString *fontsDir = [ZSModsPaths modsFontsDirectory];
    NSString *fontFileName = entry.livePathDescription.lastPathComponent;
    if (fontsDir.length == 0 || fontFileName.length == 0) return;
    [NSFileManager.defaultManager removeItemAtPath:[fontsDir stringByAppendingPathComponent:fontFileName] error:nil];
}

+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs
             intoFolder:(NSString *)folderName
              fontRoles:(nullable NSDictionary<NSString *, NSNumber *> *)fontRoles
        rejectedFileLines:(NSArray<NSString *> * _Nullable * _Nullable)rejectedFileLines
                  error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = [root stringByAppendingPathComponent:folderName];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!root || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\" - create it first.", folderName]);
        return NO;
    }

    NSError *entriesErr = nil;
    NSMutableArray<ModAssetLibraryEntry *> *entries =
        [([self entriesInFolder:folderName error:&entriesErr] ?: @[]) mutableCopy];

    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *now = [iso stringFromDate:[NSDate date]];

    BOOL enforceOverlap = ![self mal_folderIsStored:folderName];
    NSMutableArray<NSString *> *rejectedLines = [NSMutableArray array];
    NSMutableSet<NSNumber *> *claimedFontRoles = [NSMutableSet set];
    NSInteger importedCount = 0;
    for (NSURL *url in moddedURLs) {
        BOOL accessing = [url startAccessingSecurityScopedResource];

        BOOL isBundle = [UnityBundleCAB isUnityFSBundleAtPath:url.path];

        NSString *cabID = nil;
        NSNumber *targetPlatformNumber = nil;
        NSString *resolvedTargetPath = nil;
        if (isBundle) {
            NSError *cabErr = nil;
            cabID = [UnityBundleCAB primaryCABForBundleAtPath:url.path error:&cabErr];
            if (cabID.length == 0) {
                cabID = nil;
                ZLog(@"[ModAssetLibrary] %@ has a UnityFS header but its CAB id couldn't be read (%@) - rejecting.",
                     url.lastPathComponent, cabErr.localizedDescription);
                if (accessing) [url stopAccessingSecurityScopedResource];
                [rejectedLines addObject:MALCABRejectionLine(url.lastPathComponent)];
                continue;
            }
            int32_t platform = 0;
            NSError *platformErr = nil;
            if ([UnityBundleCAB targetPlatform:&platform forBundleAtPath:url.path error:&platformErr]) {
                targetPlatformNumber = @(platform);
            } else {
                ZLog(@"[ModAssetLibrary] couldn't read a target platform for %@: %@",
                     url.lastPathComponent, platformErr.localizedDescription);
            }

            NSError *locateErr = nil;
            NSString *matchPath = [UnityCacheLocator locateBundlePathForCAB:cabID error:&locateErr];
            if (matchPath) {
                resolvedTargetPath = [self mal_sandboxRelativePath:matchPath];
            } else {
                ZLog(@"[ModAssetLibrary] no index match for %@'s CAB (%@) - rejecting: %@",
                     url.lastPathComponent, cabID, locateErr.localizedDescription);
                if (accessing) [url stopAccessingSecurityScopedResource];
                [rejectedLines addObject:MALCABRejectionLine(url.lastPathComponent)];
                continue;
            }
        }

        if (enforceOverlap) {
            NSString *overlapTarget = isBundle ? resolvedTargetPath : [self mal_livePathDescriptionForFileName:url.lastPathComponent];
            ModAssetLibraryEntry *overlapping = [self mal_activeEntryForTargetPath:overlapTarget
                                                                     pendingFolder:folderName
                                                                    pendingEntries:entries
                                                                     excludingPath:nil];
            if (overlapping) {
                if (accessing) [url stopAccessingSecurityScopedResource];
                ZLog(@"[ModAssetLibrary] %@ overlaps an existing entry (%@) - rejecting.",
                     url.lastPathComponent, overlapTarget);
                [rejectedLines addObject:[self overlapRejectionLineForName:url.lastPathComponent existingEntry:overlapping]];
                continue;
            }
        }

        BOOL isFont = [ZSModsPaths fontKindForFileName:url.lastPathComponent] != ZSFontKindUnknown;
        ZSFontRole fontRole = ZSFontRoleNone;
        if (isFont) {
            fontRole = MALFontRoleFromValue(fontRoles[url.path]);
            NSString *fontRejection = nil;
            if (fontRole == ZSFontRoleNone) {
                fontRejection = [NSString stringWithFormat:@"%@: rejected - no font role was chosen", url.lastPathComponent];
            } else if ([claimedFontRoles containsObject:@(fontRole)]) {
                fontRejection = [NSString stringWithFormat:@"%@: rejected - %@ is already assigned to another font in this batch",
                                 url.lastPathComponent, [ZSModsPaths displayNameForFontRole:fontRole]];
            } else {
                ModAssetLibraryEntry *occupant = [self fontEntryOccupyingRole:fontRole];
                if (occupant) {
                    fontRejection = [NSString stringWithFormat:@"%@: rejected - %@ is already assigned to \"%@\"",
                                     url.lastPathComponent, [ZSModsPaths displayNameForFontRole:fontRole], [self displayNameForEntry:occupant]];
                }
            }
            if (fontRejection) {
                if (accessing) [url stopAccessingSecurityScopedResource];
                [rejectedLines addObject:fontRejection];
                continue;
            }
        }

        NSString *destPath = nil;
        NSString *destName = nil;
        if (cabID) {

            NSString *cabFolderName = [self mal_uniqueFolderNameFor:cabID inParentFolder:folderPath];
            NSString *cabFolderPath = [folderPath stringByAppendingPathComponent:cabFolderName];
            NSError *mkdirErr = nil;
            if ([fm createDirectoryAtPath:cabFolderPath withIntermediateDirectories:YES attributes:nil error:&mkdirErr]) {
                destName = @"__data";
                destPath = [cabFolderPath stringByAppendingPathComponent:destName];
            } else {
                ZLog(@"[ModAssetLibrary] couldn't create CAB subfolder \"%@\" for %@: %@ - importing flat instead.",
                     cabFolderName, url.lastPathComponent, mkdirErr.localizedDescription);
            }
        }
        if (!destPath) {
            destName = [self mal_uniqueFileNameFor:url.lastPathComponent inFolder:folderPath];
            destPath = [folderPath stringByAppendingPathComponent:destName];
        }

        NSError *copyErr = nil;
        BOOL copied = [fm copyItemAtPath:url.path toPath:destPath error:&copyErr];
        if (accessing) [url stopAccessingSecurityScopedResource];
        if (!copied) {
            ZLog(@"[ModAssetLibrary] couldn't copy %@ into \"%@\": %@", url.lastPathComponent, folderName, copyErr.localizedDescription);
            continue;
        }

        NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:destPath error:nil];

        ModAssetLibraryEntry *entry = [ModAssetLibraryEntry new];
        entry.fileName = destName;
        entry.path = destPath;
        entry.byteSize = attrs.fileSize;
        entry.dateAdded = now;
        entry.isAssetBundle = isBundle;
        entry.fontRole = fontRole;
        entry.cabIdentifier = cabID;
        entry.targetPlatform = targetPlatformNumber;

        entry.livePathDescription = [self mal_livePathDescriptionForFileName:destName];
        entry.resolvedInstallTargetPath = resolvedTargetPath;

        if (isFont) {
            [claimedFontRoles addObject:@(fontRole)];
            NSError *fontErr = nil;
            if (![self activateFontForEntry:entry error:&fontErr]) {
                ZLog(@"[ModAssetLibrary] couldn't activate font %@: %@", destName, fontErr.localizedDescription);
            }
        }

        [entries addObject:entry];
        importedCount++;
    }

    if (rejectedFileLines) *rejectedFileLines = rejectedLines.count > 0 ? [rejectedLines copy] : nil;

    if (importedCount == 0) {
        if (error) {
            *error = rejectedLines.count > 0
                ? MALError(ModAssetLibraryErrorCABNotIndexed, @"Every file was rejected - see rejectedFileLines for per-file reasons.")
                : MALError(ModAssetLibraryErrorCopyFailed, @"No file(s) could be imported - see syslog for per-file errors.");
        }
        return NO;
    }

    BOOL wrote = [self mal_writeEntries:entries toFolder:folderName error:error];
    if (wrote) {
        ZLog(@"[ModAssetLibrary] imported %ld file(s) into \"%@\" (%lu rejected)",
             (long)importedCount, folderName, (unsigned long)rejectedLines.count);
    }
    return wrote;
}

+ (BOOL)importLunartiqueZipURL:(NSURL *)zipURL
                    intoFolder:(NSString *)folderName
             rejectedEntryLines:(NSArray<NSString *> * _Nullable * _Nullable)rejectedEntryLines
                         error:(NSError **)error {
    NSError *formatErr = nil;
    NSArray<LunartiqueModEntry *> *matches = [LunartiqueModArchive matchedEntriesInZipAtURL:zipURL error:&formatErr];
    if (matches.count == 0) {
        if (error) *error = formatErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Not a Lunartique-format mod zip.");
        return NO;
    }

    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!folderPath || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\" - create it first.", folderName]);
        return NO;
    }

    NSError *entriesErr = nil;
    NSMutableArray<ModAssetLibraryEntry *> *entries =
        [([self entriesInFolder:folderName error:&entriesErr] ?: @[]) mutableCopy];

    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *now = [iso stringFromDate:[NSDate date]];

    BOOL enforceOverlap = ![self mal_folderIsStored:folderName];
    NSMutableArray<NSString *> *rejectedLines = [NSMutableArray array];
    NSInteger importedCount = 0;
    for (LunartiqueModEntry *lmaEntry in matches) {
        NSURL *dataURL = nil;
        NSError *extractErr = nil;
        if (![LunartiqueModArchive extractDataForEntry:lmaEntry fromZipAtURL:zipURL dataURL:&dataURL error:&extractErr]) {
            ZLog(@"[ModAssetLibrary] couldn't extract %@ from %@: %@", lmaEntry.dataEntryName, zipURL.lastPathComponent, extractErr.localizedDescription);
            continue;
        }

        BOOL isBundle = [UnityBundleCAB isUnityFSBundleAtPath:dataURL.path];
        if (!isBundle) {
            ZLog(@"[ModAssetLibrary] Lunartique entry %@ extracted fine but doesn't look like a UnityFS bundle - rejecting.", lmaEntry.dataEntryName);
            [rejectedLines addObject:MALCABRejectionLine(lmaEntry.dataEntryName)];
            continue;
        }

        NSError *cabErr = nil;
        NSString *cabID = [UnityBundleCAB primaryCABForBundleAtPath:dataURL.path error:&cabErr];
        if (cabID.length == 0) {
            ZLog(@"[ModAssetLibrary] Lunartique entry %@ has a UnityFS header but its CAB id couldn't be read (%@) - rejecting.",
                 lmaEntry.dataEntryName, cabErr.localizedDescription);
            [rejectedLines addObject:MALCABRejectionLine(lmaEntry.dataEntryName)];
            continue;
        }
        int32_t platform = 0;
        NSError *platformErr = nil;
        NSNumber *targetPlatformNumber = nil;
        if ([UnityBundleCAB targetPlatform:&platform forBundleAtPath:dataURL.path error:&platformErr]) {
            targetPlatformNumber = @(platform);
        }

        NSError *locateErr = nil;
        NSString *matchPath = [UnityCacheLocator locateBundlePathForCAB:cabID error:&locateErr];
        if (!matchPath) {
            ZLog(@"[ModAssetLibrary] no index match for Lunartique entry %@'s CAB (%@) - rejecting: %@",
                 lmaEntry.dataEntryName, cabID, locateErr.localizedDescription);
            [rejectedLines addObject:MALCABRejectionLine(lmaEntry.dataEntryName)];
            continue;
        }
        NSString *resolvedTargetPath = [self mal_sandboxRelativePath:matchPath];

        if (enforceOverlap) {
            ModAssetLibraryEntry *overlapping = [self mal_activeEntryForTargetPath:resolvedTargetPath
                                                                     pendingFolder:folderName
                                                                    pendingEntries:entries
                                                                     excludingPath:nil];
            if (overlapping) {
                ZLog(@"[ModAssetLibrary] Lunartique entry %@ overlaps an existing entry (%@) - rejecting.",
                     lmaEntry.dataEntryName, resolvedTargetPath);
                [rejectedLines addObject:[self overlapRejectionLineForName:lmaEntry.dataEntryName existingEntry:overlapping]];
                continue;
            }
        }

        NSString *destPath = nil;
        NSString *destName = nil;

        NSString *subFolderName = [self mal_uniqueFolderNameFor:cabID inParentFolder:folderPath];
        NSString *subFolderPath = [folderPath stringByAppendingPathComponent:subFolderName];
        NSError *mkdirErr = nil;
        if ([fm createDirectoryAtPath:subFolderPath withIntermediateDirectories:YES attributes:nil error:&mkdirErr]) {
            destName = @"__data";
            destPath = [subFolderPath stringByAppendingPathComponent:destName];
        } else {
            ZLog(@"[ModAssetLibrary] couldn't create subfolder \"%@\" for Lunartique entry %@: %@ - skipping.",
                 subFolderName, lmaEntry.dataEntryName, mkdirErr.localizedDescription);
            continue;
        }

        NSError *copyErr = nil;
        BOOL copied = [fm copyItemAtPath:dataURL.path toPath:destPath error:&copyErr];
        if (!copied) {
            ZLog(@"[ModAssetLibrary] couldn't copy extracted %@ into \"%@\": %@", lmaEntry.dataEntryName, folderName, copyErr.localizedDescription);
            continue;
        }

        NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:destPath error:nil];

        ModAssetLibraryEntry *entry = [ModAssetLibraryEntry new];
        entry.fileName = destName;
        entry.path = destPath;
        entry.byteSize = attrs.fileSize;
        entry.dateAdded = now;
        entry.isAssetBundle = isBundle;
        entry.cabIdentifier = cabID;
        entry.targetPlatform = targetPlatformNumber;
        entry.zipCacheHash1 = lmaEntry.cacheHash1;
        entry.zipCacheHash2 = lmaEntry.cacheHash2;
        entry.resolvedInstallTargetPath = resolvedTargetPath;

        entry.livePathDescription = nil;
        [entries addObject:entry];
        importedCount++;
    }

    NSError *bankScanErr = nil;
    NSArray<NSString *> *bankEntryNames = [LunartiqueModArchive matchedBankEntryNamesInZipAtURL:zipURL error:&bankScanErr] ?: @[];
    for (NSString *bankEntryName in bankEntryNames) {
        if (enforceOverlap) {
            ModAssetLibraryEntry *overlapping = [self mal_activeEntryForTargetPath:[self mal_livePathDescriptionForFileName:bankEntryName.lastPathComponent]
                                                                     pendingFolder:folderName
                                                                    pendingEntries:entries
                                                                     excludingPath:nil];
            if (overlapping) {
                ZLog(@"[ModAssetLibrary] bank %@ from Lunartique zip overlaps an existing entry - rejecting.", bankEntryName);
                [rejectedLines addObject:[self overlapRejectionLineForName:bankEntryName.lastPathComponent existingEntry:overlapping]];
                continue;
            }
        }
        NSURL *bankURL = nil;
        NSError *bankExtractErr = nil;
        if (![LunartiqueModArchive extractBankEntryNamed:bankEntryName fromZipAtURL:zipURL bankURL:&bankURL error:&bankExtractErr]) {
            ZLog(@"[ModAssetLibrary] couldn't extract bank %@ from %@: %@", bankEntryName, zipURL.lastPathComponent, bankExtractErr.localizedDescription);
            continue;
        }

        NSString *destName = [self mal_uniqueFileNameFor:bankEntryName.lastPathComponent inFolder:folderPath];
        NSString *destPath = [folderPath stringByAppendingPathComponent:destName];
        NSError *copyErr = nil;
        if (![fm copyItemAtPath:bankURL.path toPath:destPath error:&copyErr]) {
            ZLog(@"[ModAssetLibrary] couldn't copy extracted bank %@ into \"%@\": %@", bankEntryName, folderName, copyErr.localizedDescription);
            continue;
        }

        NSDictionary<NSFileAttributeKey, id> *bankAttrs = [fm attributesOfItemAtPath:destPath error:nil];
        ModAssetLibraryEntry *bankEntry = [ModAssetLibraryEntry new];
        bankEntry.fileName = destName;
        bankEntry.path = destPath;
        bankEntry.byteSize = bankAttrs.fileSize;
        bankEntry.dateAdded = now;
        bankEntry.isAssetBundle = NO;
        bankEntry.livePathDescription = [self mal_livePathDescriptionForFileName:destName];
        [entries addObject:bankEntry];
        importedCount++;
    }

    if (rejectedEntryLines) *rejectedEntryLines = rejectedLines.count > 0 ? [rejectedLines copy] : nil;

    if (importedCount == 0) {
        if (error) {
            *error = rejectedLines.count > 0
                ? MALError(ModAssetLibraryErrorCABNotIndexed, @"Every bundle in the Lunartique zip was rejected - see rejectedEntryLines for per-entry reasons.")
                : MALError(ModAssetLibraryErrorCopyFailed, @"No bundle(s) could be extracted from the Lunartique zip - see syslog for per-entry errors.");
        }
        return NO;
    }

    BOOL wrote = [self mal_writeEntries:entries toFolder:folderName error:error];
    if (wrote) {
        ZLog(@"[ModAssetLibrary] imported %ld bundle(s) from Lunartique zip \"%@\" into \"%@\" (%lu rejected)",
             (long)importedCount, zipURL.lastPathComponent, folderName, (unsigned long)rejectedLines.count);
    }
    return wrote;
}

+ (BOOL)mal_appendEntry:(ModAssetLibraryEntry *)entry toFolder:(NSString *)folderName error:(NSError **)error {
    NSMutableArray<ModAssetLibraryEntry *> *entries =
        [([self entriesInFolder:folderName error:nil] ?: @[]) mutableCopy];
    [entries addObject:entry];
    return [self mal_writeEntries:entries toFolder:folderName error:error];
}

+ (nullable NSString *)mal_localizationFolderPathForFolder:(NSString *)folderName {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    BOOL isDir = NO;
    if (!folderPath || ![NSFileManager.defaultManager fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) return nil;
    return folderPath;
}

static NSString *MALTimestampNow(void) {
    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return [iso stringFromDate:[NSDate date]];
}

+ (void)importLocalizationJSONURLs:(NSArray<NSURL *> *)jsonURLs
                          language:(NSString *)languageCode
                        intoFolder:(NSString *)folderName
                      summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    NSString *folderPath = [self mal_localizationFolderPathForFolder:folderName];
    if (!folderPath) {
        for (NSURL *url in jsonURLs) {
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - no folder named \"%@\"", url.lastPathComponent, folderName]];
        }
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *now = MALTimestampNow();

    for (NSURL *url in jsonURLs) {
        NSString *displayName = url.lastPathComponent;

        if (![LocalizationTransplant isLocalizationJSONAtURL:url]) {
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - not a localization .json file (it must start with dataList)", displayName]];
            continue;
        }

        NSArray<NSString *> *targets = [LocalizationTransplant relativeTargetsForJSONNamed:displayName inLanguage:languageCode];
        if (targets.count != 1) {
            NSString *reason = targets.count == 0
                ? [NSString stringWithFormat:@"no file matching this name was found in the \"%@\" folder", languageCode]
                : [NSString stringWithFormat:@"it matches %lu files in the \"%@\" folder", (unsigned long)targets.count, languageCode];
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - %@", displayName, reason]];
            continue;
        }
        NSString *relativeTarget = targets.firstObject;

        if (![self mal_folderIsStored:folderName]) {
            NSString *overlapTarget = [self mal_sandboxRelativePath:[[LocalizationTransplant localizeDirectory] stringByAppendingPathComponent:relativeTarget]];
            ModAssetLibraryEntry *overlapping = [self mal_activeEntryForTargetPath:overlapTarget
                                                                     pendingFolder:nil
                                                                    pendingEntries:nil
                                                                     excludingPath:nil];
            if (overlapping) {
                [summaryLines addObject:[self overlapRejectionLineForName:displayName existingEntry:overlapping]];
                continue;
            }
        }

        NSString *destName = [self mal_uniqueFileNameFor:displayName inFolder:folderPath];
        NSString *destPath = [folderPath stringByAppendingPathComponent:destName];

        BOOL accessing = [url startAccessingSecurityScopedResource];
        NSError *copyErr = nil;
        BOOL copied = [fm copyItemAtPath:url.path toPath:destPath error:&copyErr];
        if (accessing) [url stopAccessingSecurityScopedResource];
        if (!copied) {
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - couldn't copy it into the library: %@", displayName, copyErr.localizedDescription ?: @"unknown error"]];
            continue;
        }

        NSError *applyErr = nil;
        if (![LocalizationTransplant applyModFileAtPath:destPath toRelativeTarget:relativeTarget error:&applyErr]) {
            [fm removeItemAtPath:destPath error:nil];
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - %@", displayName, applyErr.localizedDescription ?: @"swap failed"]];
            continue;
        }

        NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:destPath error:nil];
        ModAssetLibraryEntry *entry = [ModAssetLibraryEntry new];
        entry.fileName = destName;
        entry.path = destPath;
        entry.byteSize = attrs.fileSize;
        entry.dateAdded = now;
        entry.localizationKind = ModAssetLibraryLocalizationKindJSON;
        entry.localizationLanguage = languageCode;
        entry.localizationRelativePath = relativeTarget;
        NSString *localizeDir = [LocalizationTransplant localizeDirectory];
        entry.livePathDescription = [self mal_sandboxRelativePath:[localizeDir stringByAppendingPathComponent:relativeTarget]];

        NSError *writeErr = nil;
        if ([self mal_appendEntry:entry toFolder:folderName error:&writeErr]) {
            [summaryLines addObject:[NSString stringWithFormat:@"%@: swapped", displayName]];
        } else {
            [summaryLines addObject:[NSString stringWithFormat:@"%@: swapped, but couldn't be added to the library - %@", displayName, writeErr.localizedDescription ?: @"unknown error"]];
        }
    }
}

+ (void)mal_importLocalizationPackFromDirectoryAtPath:(NSString *)sourcePath
                                          displayName:(NSString *)displayName
                                             language:(NSString *)languageCode
                                           intoFolder:(NSString *)folderName
                                         summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    NSString *folderPath = [self mal_localizationFolderPathForFolder:folderName];
    if (!folderPath) {
        [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - no folder named \"%@\"", displayName, folderName]];
        return;
    }
    if (![LocalizationTransplant isTranslationPackDirectoryAtPath:sourcePath]) {
        [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - unknown folder, it doesn't look like a localization pack", displayName]];
        return;
    }

    if (![self mal_folderIsStored:folderName]) {
        NSString *overlapTarget = [self mal_sandboxRelativePath:[LocalizationTransplant languageDirectoryForCode:languageCode]];
        ModAssetLibraryEntry *overlapping = [self mal_activeEntryForTargetPath:overlapTarget
                                                                 pendingFolder:nil
                                                                pendingEntries:nil
                                                                 excludingPath:nil];
        if (overlapping) {
            [summaryLines addObject:[self overlapRejectionLineForName:displayName existingEntry:overlapping]];
            return;
        }
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *destName = [self mal_uniqueFolderNameFor:sourcePath.lastPathComponent inParentFolder:folderPath];
    NSString *destPath = [folderPath stringByAppendingPathComponent:destName];

    NSError *copyErr = nil;
    if (![fm copyItemAtPath:sourcePath toPath:destPath error:&copyErr]) {
        [fm removeItemAtPath:destPath error:nil];
        [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - couldn't copy it into the library: %@", displayName, copyErr.localizedDescription ?: @"unknown error"]];
        return;
    }

    NSError *prefixErr = nil;
    if (![LocalizationTransplant prefixPackJSONFilesAtPath:destPath withLanguage:languageCode error:&prefixErr]) {
        [fm removeItemAtPath:destPath error:nil];
        [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - %@", displayName, prefixErr.localizedDescription ?: @"couldn't add the language prefix"]];
        return;
    }

    NSError *applyErr = nil;
    if (![LocalizationTransplant applyPackAtPath:destPath toLanguage:languageCode error:&applyErr]) {
        [fm removeItemAtPath:destPath error:nil];
        [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - %@", displayName, applyErr.localizedDescription ?: @"swap failed"]];
        return;
    }

    ModAssetLibraryEntry *entry = [ModAssetLibraryEntry new];
    entry.fileName = destName;
    entry.path = destPath;
    entry.byteSize = [LocalizationTransplant totalByteSizeAtPath:destPath];
    entry.dateAdded = MALTimestampNow();
    entry.localizationKind = ModAssetLibraryLocalizationKindPack;
    entry.localizationLanguage = languageCode;
    entry.livePathDescription = [self mal_sandboxRelativePath:[LocalizationTransplant languageDirectoryForCode:languageCode]];

    NSError *writeErr = nil;
    if ([self mal_appendEntry:entry toFolder:folderName error:&writeErr]) {
        [summaryLines addObject:[NSString stringWithFormat:@"%@: swapped", displayName]];
    } else {
        [summaryLines addObject:[NSString stringWithFormat:@"%@: swapped, but couldn't be added to the library - %@", displayName, writeErr.localizedDescription ?: @"unknown error"]];
    }
}

+ (void)importLocalizationPackFolderURL:(NSURL *)folderURL
                               language:(NSString *)languageCode
                             intoFolder:(NSString *)folderName
                           summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    BOOL accessing = [folderURL startAccessingSecurityScopedResource];
    [self mal_importLocalizationPackFromDirectoryAtPath:folderURL.path
                                             displayName:folderURL.lastPathComponent
                                                language:languageCode
                                              intoFolder:folderName
                                            summaryLines:summaryLines];
    if (accessing) [folderURL stopAccessingSecurityScopedResource];
}

+ (void)importLocalizationPackZipURL:(NSURL *)zipURL
                            language:(NSString *)languageCode
                          intoFolder:(NSString *)folderName
                        summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    NSString *displayName = zipURL.lastPathComponent;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *tempRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"zs-loc-zip-%@", [NSUUID UUID].UUIDString]];

    BOOL accessing = [zipURL startAccessingSecurityScopedResource];
    NSError *extractErr = nil;
    BOOL extracted = [LunartiqueModArchive extractAllEntriesOfZipAtURL:zipURL
                                                        toDirectoryURL:[NSURL fileURLWithPath:tempRoot isDirectory:YES]
                                                                 error:&extractErr];
    if (accessing) [zipURL stopAccessingSecurityScopedResource];

    if (!extracted) {
        [fm removeItemAtPath:tempRoot error:nil];
        [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - couldn't unzip it: %@", displayName, extractErr.localizedDescription ?: @"unknown error"]];
        return;
    }

    NSString *packDir = [LocalizationTransplant packDirectoryInExtractedDirectoryAtPath:tempRoot];
    if (!packDir) {
        [fm removeItemAtPath:tempRoot error:nil];
        [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - unknown file, it isn't a localization pack", displayName]];
        return;
    }

    [self mal_importLocalizationPackFromDirectoryAtPath:packDir
                                             displayName:displayName
                                                language:languageCode
                                              intoFolder:folderName
                                            summaryLines:summaryLines];
    [fm removeItemAtPath:tempRoot error:nil];
}

+ (BOOL)importCarra2URL:(NSURL *)carra2URL
              intoFolder:(NSString *)folderName
                   error:(NSError **)error {
    BOOL accessing = [carra2URL startAccessingSecurityScopedResource];
    NSError *formatErr = nil;
    Carra2ArchiveInfo *info = [Carra2ModArchive archiveInfoForZipAtURL:carra2URL error:&formatErr];
    if (!info) {
        if (accessing) [carra2URL stopAccessingSecurityScopedResource];
        if (error) *error = formatErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Not a Carra2-format mod file.");
        return NO;
    }

    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!folderPath || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (accessing) [carra2URL stopAccessingSecurityScopedResource];
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\" - create it first.", folderName]);
        return NO;
    }

    NSError *locateErr = nil;
    NSString *matchPath = [UnityCacheLocator locateGameFilePathForHash1:info.hash1 hash2:info.hash2 error:&locateErr];
    if (!matchPath) {
        if (accessing) [carra2URL stopAccessingSecurityScopedResource];
        ZLog(@"[ModAssetLibrary] no match in the game's own files for Carra2 %@'s hash %@/%@ - rejecting: %@",
             carra2URL.lastPathComponent, info.hash1, info.hash2, locateErr.localizedDescription);
        if (error) *error = MALError(ModAssetLibraryErrorCABNotIndexed,
            [NSString stringWithFormat:@"%@: rejected - no matching bundle found in the game's own files for hash %@/%@",
                carra2URL.lastPathComponent, info.hash1, info.hash2]);
        return NO;
    }
    NSString *resolvedTargetPath = [self mal_libraryRelativePath:matchPath];

    if (![self mal_folderIsStored:folderName]) {
        ModAssetLibraryEntry *overlapping = [self mal_activeEntryForTargetPath:resolvedTargetPath
                                                                 pendingFolder:nil
                                                                pendingEntries:nil
                                                                 excludingPath:nil];
        if (overlapping) {
            if (accessing) [carra2URL stopAccessingSecurityScopedResource];
            ZLog(@"[ModAssetLibrary] Carra2 %@ overlaps an existing entry (%@) - rejecting.",
                 carra2URL.lastPathComponent, resolvedTargetPath);
            if (error) *error = MALError(ModAssetLibraryErrorTargetOverlap, [self overlapReasonForExistingEntry:overlapping]);
            return NO;
        }
    }

    NSError *entriesErr = nil;
    NSMutableArray<ModAssetLibraryEntry *> *entries =
        [([self entriesInFolder:folderName error:&entriesErr] ?: @[]) mutableCopy];

    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *now = [iso stringFromDate:[NSDate date]];

    NSString *destName = [self mal_uniqueFileNameFor:carra2URL.lastPathComponent inFolder:folderPath];
    NSString *destPath = [folderPath stringByAppendingPathComponent:destName];

    NSError *copyErr = nil;
    BOOL copied = [fm copyItemAtPath:carra2URL.path toPath:destPath error:&copyErr];
    if (accessing) [carra2URL stopAccessingSecurityScopedResource];
    if (!copied) {
        if (error) *error = copyErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Couldn't copy the Carra2 file into the mod library.");
        return NO;
    }

    NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:destPath error:nil];

    ModAssetLibraryEntry *entry = [ModAssetLibraryEntry new];
    entry.fileName = destName;
    entry.path = destPath;
    entry.byteSize = attrs.fileSize;
    entry.dateAdded = now;
    entry.isAssetBundle = NO;
    entry.zipCacheHash1 = info.hash1;
    entry.zipCacheHash2 = info.hash2;
    entry.resolvedInstallTargetPath = resolvedTargetPath;
    entry.livePathDescription = resolvedTargetPath;
    [entries addObject:entry];

    BOOL wrote = [self mal_writeEntries:entries toFolder:folderName error:error];
    if (wrote) {
        ZLog(@"[ModAssetLibrary] imported Carra2 file \"%@\" into \"%@\", targeting %@",
             carra2URL.lastPathComponent, folderName, resolvedTargetPath);
    }
    return wrote;
}

+ (BOOL)removeEntry:(ModAssetLibraryEntry *)entry fromFolder:(NSString *)folderName error:(NSError **)error {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *current = [self entriesInFolder:folderName error:&entriesErr];
    if (!current) {
        if (error) *error = entriesErr;
        return NO;
    }

    NSMutableArray<ModAssetLibraryEntry *> *remaining = [NSMutableArray arrayWithCapacity:current.count];
    for (ModAssetLibraryEntry *e in current) {
        if (![e.path isEqualToString:entry.path]) [remaining addObject:e];
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:entry.path error:nil];

    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSString *entryDir = entry.path.stringByDeletingLastPathComponent;
    if (folderPath && ![entryDir isEqualToString:folderPath]) {
        NSArray<NSString *> *remainingInDir = [fm contentsOfDirectoryAtPath:entryDir error:nil];
        if (remainingInDir.count == 0) {
            [fm removeItemAtPath:entryDir error:nil];
        }
    }

    BOOL ok = [self mal_writeEntries:remaining toFolder:folderName error:error];
    if (ok) {
        ZLog(@"[ModAssetLibrary] removed \"%@\" from \"%@\"", entry.fileName, folderName);
    }
    return ok;
}

+ (nullable ModAssetLibraryEntry *)moveEntry:(ModAssetLibraryEntry *)entry
                                   fromFolder:(NSString *)fromFolder
                                     toFolder:(NSString *)toFolder
                          replacementBytesURL:(nullable NSURL *)replacementBytesURL
                                        error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *toFolderPath = root ? [root stringByAppendingPathComponent:toFolder] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL toIsDir = NO;
    if (!toFolderPath || ![fm fileExistsAtPath:toFolderPath isDirectory:&toIsDir] || !toIsDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\" - create it first.", toFolder]);
        return nil;
    }

    if ([self mal_folderIsStored:fromFolder] && ![self mal_folderIsStored:toFolder]) {
        ModAssetLibraryEntry *overlapping = [self activeEntryOverlappingEntry:entry];
        if (overlapping) {
            if (error) *error = MALError(ModAssetLibraryErrorTargetOverlap,
                [NSString stringWithFormat:@"\"%@\" can't be restored: %@.",
                    [self displayNameForEntry:entry], [self overlapReasonForExistingEntry:overlapping]]);
            return nil;
        }
    }

    NSError *fromEntriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *fromEntries = [self entriesInFolder:fromFolder error:&fromEntriesErr];
    if (!fromEntries) {
        if (error) *error = fromEntriesErr;
        return nil;
    }
    BOOL foundInSource = NO;
    for (ModAssetLibraryEntry *e in fromEntries) {
        if ([e.path isEqualToString:entry.path]) { foundInSource = YES; break; }
    }
    if (!foundInSource) {
        if (error) *error = MALError(ModAssetLibraryErrorEntryNotFound,
            [NSString stringWithFormat:@"\"%@\" is no longer in \"%@\".", entry.fileName, fromFolder]);
        return nil;
    }

    NSString *destPath = nil;
    NSString *destName = entry.fileName;
    if (entry.isAssetBundle && entry.cabIdentifier.length > 0) {
        NSString *cabFolderName = [self mal_uniqueFolderNameFor:entry.cabIdentifier inParentFolder:toFolderPath];
        NSString *cabFolderPath = [toFolderPath stringByAppendingPathComponent:cabFolderName];
        NSError *mkdirErr = nil;
        if (![fm createDirectoryAtPath:cabFolderPath withIntermediateDirectories:YES attributes:nil error:&mkdirErr]) {
            if (error) *error = mkdirErr ?: MALError(ModAssetLibraryErrorCopyFailed, @"Couldn't create the destination folder.");
            return nil;
        }
        destName = @"__data";
        destPath = [cabFolderPath stringByAppendingPathComponent:destName];
    } else {
        destName = [self mal_uniqueFileNameFor:entry.fileName inFolder:toFolderPath];
        destPath = [toFolderPath stringByAppendingPathComponent:destName];
    }

    NSError *copyErr = nil;
    NSString *sourceForBytes = replacementBytesURL ? replacementBytesURL.path : entry.path;
    BOOL copied = [fm copyItemAtPath:sourceForBytes toPath:destPath error:&copyErr];
    if (!copied) {
        if (error) *error = copyErr ?: MALError(ModAssetLibraryErrorCopyFailed,
            [NSString stringWithFormat:@"Couldn't move \"%@\" into \"%@\".", entry.fileName, toFolder]);
        return nil;
    }

    NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:destPath error:nil];

    ModAssetLibraryEntry *movedEntry = [ModAssetLibraryEntry new];
    movedEntry.fileName = destName;
    movedEntry.path = destPath;
    movedEntry.byteSize = attrs.fileSize;
    movedEntry.dateAdded = entry.dateAdded;
    movedEntry.livePathDescription = entry.livePathDescription;
    movedEntry.resolvedInstallTargetPath = entry.resolvedInstallTargetPath;
    movedEntry.remark = entry.remark;
    movedEntry.isAssetBundle = entry.isAssetBundle;
    movedEntry.fontRole = entry.fontRole;
    movedEntry.cabIdentifier = entry.cabIdentifier;
    movedEntry.targetPlatform = entry.targetPlatform;
    movedEntry.cachedFromFolder = entry.cachedFromFolder;
    movedEntry.localizationKind = entry.localizationKind;
    movedEntry.localizationLanguage = entry.localizationLanguage;
    movedEntry.localizationRelativePath = entry.localizationRelativePath;
    movedEntry.currentFolder = toFolder;
    movedEntry.doctorStatus = entry.doctorStatus;
    movedEntry.doctorUploadProgress = entry.doctorUploadProgress;
    movedEntry.doctorUploadTotalBytes = entry.doctorUploadTotalBytes;
    movedEntry.doctorProcessProgress = entry.doctorProcessProgress;
    movedEntry.doctorDownloadProgress = entry.doctorDownloadProgress;
    movedEntry.doctorDispatchCompressedByteSize = entry.doctorDispatchCompressedByteSize;
    movedEntry.doctorScratchBranch = entry.doctorScratchBranch;
    movedEntry.doctorRunID = entry.doctorRunID;
    movedEntry.doctorRunURL = entry.doctorRunURL;
    movedEntry.doctorLastError = entry.doctorLastError;
    movedEntry.doctorTranscodeCodec = entry.doctorTranscodeCodec;

    NSMutableArray<ModAssetLibraryEntry *> *toEntries =
        [([self entriesInFolder:toFolder error:nil] ?: @[]) mutableCopy];
    [toEntries addObject:movedEntry];
    NSError *toWriteErr = nil;
    if (![self mal_writeEntries:toEntries toFolder:toFolder error:&toWriteErr]) {
        [fm removeItemAtPath:destPath error:nil];
        if (error) *error = toWriteErr;
        return nil;
    }

    NSMutableArray<ModAssetLibraryEntry *> *remainingInSource = [NSMutableArray arrayWithCapacity:fromEntries.count];
    for (ModAssetLibraryEntry *e in fromEntries) {
        if (![e.path isEqualToString:entry.path]) [remainingInSource addObject:e];
    }
    [fm removeItemAtPath:entry.path error:nil];
    NSString *fromFolderPath = root ? [root stringByAppendingPathComponent:fromFolder] : nil;
    NSString *entryDir = entry.path.stringByDeletingLastPathComponent;
    if (fromFolderPath && ![entryDir isEqualToString:fromFolderPath]) {
        NSArray<NSString *> *remainingInDir = [fm contentsOfDirectoryAtPath:entryDir error:nil];
        if (remainingInDir.count == 0) [fm removeItemAtPath:entryDir error:nil];
    }
    NSError *fromWriteErr = nil;
    if (![self mal_writeEntries:remainingInSource toFolder:fromFolder error:&fromWriteErr]) {
        ZLog(@"[ModAssetLibrary] moved %@ into \"%@\" but couldn't drop its old row from \"%@\": %@ (file now tracked in both folders' manifests until this is retried)",
             entry.fileName, toFolder, fromFolder, fromWriteErr.localizedDescription);
    } else {
        ZLog(@"[ModAssetLibrary] moved \"%@\" from \"%@\" to \"%@\"%@", entry.fileName, fromFolder, toFolder,
             replacementBytesURL ? @" (with replacement bytes)" : @"");
    }

    return movedEntry;
}

+ (nullable ModAssetLibraryEntry *)replaceEntry:(ModAssetLibraryEntry *)entry
                                        inFolder:(NSString *)folderName
                       withDownloadedBundleAtURL:(NSURL *)bundleURL
                                           error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!folderPath || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\" - create it first.", folderName]);
        return nil;
    }

    NSError *entriesErr = nil;
    NSMutableArray<ModAssetLibraryEntry *> *entries =
        [([self entriesInFolder:folderName error:&entriesErr] ?: @[]) mutableCopy];
    if (!entries) {
        if (error) *error = entriesErr;
        return nil;
    }
    NSInteger existingIndex = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)entries.count; i++) {
        if ([entries[i].path isEqualToString:entry.path]) { existingIndex = i; break; }
    }
    if (existingIndex == NSNotFound) {
        if (error) *error = MALError(ModAssetLibraryErrorEntryNotFound,
            [NSString stringWithFormat:@"\"%@\" is no longer in the mods library.", entry.fileName]);
        return nil;
    }

    NSError *cabErr = nil;
    NSString *cabID = [UnityBundleCAB primaryCABForBundleAtPath:bundleURL.path error:&cabErr];
    if (cabID.length == 0) {
        cabID = nil;
        ZLog(@"[ModAssetLibrary] downloaded bundle replacing %@ has no readable CAB id (%@) - importing flat.",
             entry.fileName, cabErr.localizedDescription);
    }

    int32_t platform = 0;
    NSNumber *targetPlatformNumber = nil;
    NSError *platformErr = nil;
    if ([UnityBundleCAB targetPlatform:&platform forBundleAtPath:bundleURL.path error:&platformErr]) {
        targetPlatformNumber = @(platform);
    } else {
        ZLog(@"[ModAssetLibrary] couldn't read a target platform for the downloaded bundle replacing %@: %@",
             entry.fileName, platformErr.localizedDescription);
    }

    NSString *destPath = nil;
    NSString *destName = nil;
    if (cabID) {
        NSString *cabFolderName = [self mal_uniqueFolderNameFor:cabID inParentFolder:folderPath];
        NSString *cabFolderPath = [folderPath stringByAppendingPathComponent:cabFolderName];
        NSError *mkdirErr = nil;
        if ([fm createDirectoryAtPath:cabFolderPath withIntermediateDirectories:YES attributes:nil error:&mkdirErr]) {
            destName = @"__data";
            destPath = [cabFolderPath stringByAppendingPathComponent:destName];
        } else {
            ZLog(@"[ModAssetLibrary] couldn't create CAB subfolder \"%@\" replacing %@: %@ - importing flat instead.",
                 cabFolderName, entry.fileName, mkdirErr.localizedDescription);
        }
    }
    if (!destPath) {
        destName = [self mal_uniqueFileNameFor:bundleURL.lastPathComponent inFolder:folderPath];
        destPath = [folderPath stringByAppendingPathComponent:destName];
    }

    NSError *copyErr = nil;
    BOOL copied = [fm copyItemAtPath:bundleURL.path toPath:destPath error:&copyErr];
    if (!copied) {
        if (error) *error = copyErr ?: MALError(ModAssetLibraryErrorCopyFailed,
            [NSString stringWithFormat:@"Couldn't replace \"%@\" with the downloaded bundle.", entry.fileName]);
        return nil;
    }

    NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:destPath error:nil];

    ModAssetLibraryEntry *replacedEntry = [ModAssetLibraryEntry new];
    replacedEntry.fileName = destName;
    replacedEntry.path = destPath;
    replacedEntry.byteSize = attrs.fileSize;
    replacedEntry.dateAdded = entry.dateAdded;
    replacedEntry.isAssetBundle = YES;
    replacedEntry.cabIdentifier = cabID;
    replacedEntry.targetPlatform = targetPlatformNumber;
    replacedEntry.livePathDescription = entry.livePathDescription;
    replacedEntry.resolvedInstallTargetPath = entry.resolvedInstallTargetPath;
    replacedEntry.remark = entry.remark;
    replacedEntry.cachedFromFolder = entry.cachedFromFolder;
    replacedEntry.currentFolder = entry.currentFolder ?: folderName;
    replacedEntry.doctorStatus = entry.doctorStatus;
    replacedEntry.doctorUploadProgress = entry.doctorUploadProgress;
    replacedEntry.doctorUploadTotalBytes = entry.doctorUploadTotalBytes;
    replacedEntry.doctorProcessProgress = entry.doctorProcessProgress;
    replacedEntry.doctorDownloadProgress = entry.doctorDownloadProgress;
    replacedEntry.doctorDispatchCompressedByteSize = entry.doctorDispatchCompressedByteSize;
    replacedEntry.doctorScratchBranch = entry.doctorScratchBranch;
    replacedEntry.doctorRunID = entry.doctorRunID;
    replacedEntry.doctorRunURL = entry.doctorRunURL;
    replacedEntry.doctorLastError = entry.doctorLastError;
    replacedEntry.doctorTranscodeCodec = entry.doctorTranscodeCodec;

    entries[existingIndex] = replacedEntry;

    NSError *writeErr = nil;
    if (![self mal_writeEntries:entries toFolder:folderName error:&writeErr]) {
        [fm removeItemAtPath:destPath error:nil];
        if (error) *error = writeErr;
        return nil;
    }

    NSString *oldEntryDir = entry.path.stringByDeletingLastPathComponent;
    [fm removeItemAtPath:entry.path error:nil];
    if (![oldEntryDir isEqualToString:folderPath]) {
        NSArray<NSString *> *remainingInOldDir = [fm contentsOfDirectoryAtPath:oldEntryDir error:nil];
        if (remainingInOldDir.count == 0) {
            [fm removeItemAtPath:oldEntryDir error:nil];
        }
    }

    ZLog(@"[ModAssetLibrary] replaced Carra2 entry \"%@\" in \"%@\" with the downloaded bundle \"%@\"",
         entry.fileName, folderName, destName);
    return replacedEntry;
}

+ (nullable ModAssetLibraryEntry *)updateDoctorStateForEntry:(ModAssetLibraryEntry *)entry
                                                      inFolder:(NSString *)folderName
                                                    applyBlock:(void (NS_NOESCAPE ^)(ModAssetLibraryEntry *entryToMutate))applyBlock
                                                         error:(NSError **)error {
    NSError *entriesErr = nil;
    NSMutableArray<ModAssetLibraryEntry *> *current =
        [([self entriesInFolder:folderName error:&entriesErr] ?: @[]) mutableCopy];
    if (!current) {
        if (error) *error = entriesErr;
        return nil;
    }

    ModAssetLibraryEntry *match = nil;
    for (ModAssetLibraryEntry *e in current) {
        if ([e.path isEqualToString:entry.path]) { match = e; break; }
    }
    if (!match) {
        if (error) *error = MALError(ModAssetLibraryErrorEntryNotFound,
            [NSString stringWithFormat:@"\"%@\" is no longer in the mods library.", entry.fileName]);
        return nil;
    }

    if (applyBlock) applyBlock(match);

    NSError *writeErr = nil;
    if (![self mal_writeEntries:current toFolder:folderName error:&writeErr]) {
        if (error) *error = writeErr;
        return nil;
    }
    return match;
}

+ (BOOL)deleteFolderNamed:(NSString *)folderName error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!folderPath || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\".", folderName]);
        return NO;
    }

    NSError *removeErr = nil;
    if (![fm removeItemAtPath:folderPath error:&removeErr]) {
        if (error) *error = removeErr ?: MALError(ModAssetLibraryErrorDeleteFailed,
            [NSString stringWithFormat:@"Couldn't delete \"%@\".", folderName]);
        return NO;
    }
    ZLog(@"[ModAssetLibrary] deleted folder \"%@\"", folderName);
    return YES;
}

+ (BOOL)renameFolderNamed:(NSString *)folderName to:(NSString *)newName error:(NSError **)error {
    NSString *trimmed = [newName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed containsString:@"/"]) {
        if (error) *error = MALError(ModAssetLibraryErrorInvalidFolderName,
            @"Folder name can't be empty or contain \"/\".");
        return NO;
    }

    NSString *root = [self modLibraryRootDirectory];
    NSString *oldPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!oldPath || ![fm fileExistsAtPath:oldPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\".", folderName]);
        return NO;
    }

    if ([trimmed isEqualToString:folderName]) return YES;

    NSString *newPath = [root stringByAppendingPathComponent:trimmed];
    if ([fm fileExistsAtPath:newPath]) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderAlreadyExists,
            [NSString stringWithFormat:@"A folder named \"%@\" already exists.", trimmed]);
        return NO;
    }

    NSError *moveErr = nil;
    if (![fm moveItemAtPath:oldPath toPath:newPath error:&moveErr]) {
        if (error) *error = moveErr ?: MALError(ModAssetLibraryErrorDeleteFailed,
            [NSString stringWithFormat:@"Couldn't rename \"%@\".", folderName]);
        return NO;
    }
    ZLog(@"[ModAssetLibrary] renamed folder \"%@\" to \"%@\" on disk", folderName, trimmed);

    for (NSString *otherFolder in [self folderNames]) {
        if ([otherFolder isEqualToString:trimmed]) continue;
        NSError *otherEntriesErr = nil;
        NSArray<ModAssetLibraryEntry *> *otherEntries = [self entriesInFolder:otherFolder error:&otherEntriesErr];
        if (!otherEntries) continue;

        BOOL didUpdate = NO;
        for (ModAssetLibraryEntry *e in otherEntries) {
            if ([e.cachedFromFolder isEqualToString:folderName]) {
                e.cachedFromFolder = trimmed;
                didUpdate = YES;
            }
        }
        if (didUpdate) {
            NSError *writeErr = nil;
            if (![self mal_writeEntries:otherEntries toFolder:otherFolder error:&writeErr]) {
                ZLog(@"[ModAssetLibrary] renamed \"%@\" to \"%@\", but couldn't update \"%@\"'s cachedFromFolder references: %@",
                     folderName, trimmed, otherFolder, writeErr.localizedDescription);
            }
        }
    }

    return YES;
}

+ (nullable NSString *)remarkForFolder:(NSString *)folderName {
    NSString *path = [self mal_remarkPathForFolder:folderName];
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *trimmed = [contents stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

+ (BOOL)setRemark:(nullable NSString *)remark forFolder:(NSString *)folderName error:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSString *folderPath = root ? [root stringByAppendingPathComponent:folderName] : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!folderPath || ![fm fileExistsAtPath:folderPath isDirectory:&isDir] || !isDir) {
        if (error) *error = MALError(ModAssetLibraryErrorFolderNotFound,
            [NSString stringWithFormat:@"No folder named \"%@\".", folderName]);
        return NO;
    }

    NSString *trimmed = [remark stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *path = [self mal_remarkPathForFolder:folderName];
    if (trimmed.length == 0) {

        [fm removeItemAtPath:path error:nil];
        ZLog(@"[ModAssetLibrary] cleared remark for \"%@\"", folderName);
        return YES;
    }

    NSError *writeErr = nil;
    if (![trimmed writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeErr]) {
        if (error) *error = writeErr ?: MALError(ModAssetLibraryErrorManifestWriteFailed, @"Couldn't save the folder's remark.");
        return NO;
    }
    ZLog(@"[ModAssetLibrary] set remark for \"%@\"", folderName);
    return YES;
}

+ (BOOL)deleteAllFoldersWithError:(NSError **)error {
    NSString *root = [self modLibraryRootDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!root || ![fm fileExistsAtPath:root]) return YES;

    NSError *removeErr = nil;
    if (![fm removeItemAtPath:root error:&removeErr]) {
        if (error) *error = removeErr ?: MALError(ModAssetLibraryErrorDeleteFailed,
            @"Couldn't delete the Mod Asset Library.");
        return NO;
    }
    ZLog(@"[ModAssetLibrary] deleted entire mod asset library at \"%@\"", root);
    return YES;
}

@end

static const int32_t kZSCustomFontSamplingPointSize = 90;
static const int32_t kZSCustomFontPadding = 5;
static const int32_t kZSCustomFontAtlasSize = 2048;
static const int32_t kZSFontTypeCount = 2;
static const int32_t kZSFontLanguageCount = 3;
static const size_t kZSIl2CppObjectHeaderSize = sizeof(void *) * 2;
static NSString *const kZSCustomLocalizeKey = @"ZSingularity";

static void *g_zsCustomFontTitle;
static void *g_zsCustomFontContext;
static void *g_zsCustomFontCJK;
static NSString *g_zsCustomFontSignature;

static void *zs_custom_localize_manager_class(void) {
    return mt_class("ProjectMoon.CustomLocalization", "CustomLocalizeManager", "Assembly-CSharp");
}

static void *zs_custom_localize_result_class(void) {
    return mt_class("ProjectMoon.CustomLocalization", "SearchResult", "Assembly-CSharp");
}

static NSString *zs_describe_exception(void *exception) {
    if (!exception) return @"(none)";
    void *exceptionClass = mt_class("System", "Exception", "mscorlib");
    const void *getMessage = mt_method(exceptionClass, "get_Message", 0);
    void *classOfException = [IL2CppBridge classOfInstance:exception];
    NSString *typeName = [NSString stringWithFormat:@"class=%p", classOfException];
    if (!getMessage) return [NSString stringWithFormat:@"%p %@ (no get_Message)", exception, typeName];
    void *messageExc = NULL;
    void *messageStr = [IL2CppBridge invokeMethod:getMessage onInstance:exception args:NULL outException:&messageExc];
    if (messageExc || !messageStr) return [NSString stringWithFormat:@"%p %@ (message unavailable)", exception, typeName];
    return [NSString stringWithFormat:@"%p %@ message=\"%@\"", exception, typeName, [IL2CppBridge nsStringFromIl2CppString:messageStr]];
}

static NSString *zs_hex_string(const void *bytes, size_t length) {
    NSMutableString *out = [NSMutableString string];
    const uint8_t *p = (const uint8_t *)bytes;
    for (size_t i = 0; i < length; i++) {
        if (i && i % 8 == 0) [out appendString:@" "];
        [out appendFormat:@"%02x", p[i]];
    }
    return out;
}

static NSString *zs_legacy_custom_font_directory(void) {
    NSString *documentsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"Fonts"];
}

static NSString *zs_custom_font_directory(void) {
    NSString *fontsDir = [ZSModsPaths modsFontsDirectory];
    if (!fontsDir) {
        ZLog(@"[ZSFont] no Documents directory available");
        return nil;
    }
    [ZSModsPaths migrateLegacyDirectoryAtPath:zs_legacy_custom_font_directory() toPath:fontsDir];

    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:fontsDir isDirectory:&isDirectory] || !isDirectory) return nil;
    return fontsDir;
}

static NSString *zs_assigned_font_path(ZSFontRole role) {
    ModAssetLibraryEntry *entry = [ModAssetLibrary fontEntryOccupyingRole:role];
    if (entry.livePathDescription.length == 0) return nil;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:entry.livePathDescription];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? path : nil;
}

static NSString *zs_custom_font_signature(NSArray<NSString *> *paths) {
    NSMutableString *signature = [NSMutableString string];
    for (NSString *path in paths) {
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        [signature appendFormat:@"%@|%llu|%.0f;", path, attributes.fileSize, attributes.fileModificationDate.timeIntervalSince1970];
    }
    return signature;
}

static BOOL zs_custom_localize_static_bool(const char *methodName, BOOL *outValue) {
    void *managerClass = zs_custom_localize_manager_class();
    const void *method = mt_method(managerClass, methodName, 0);
    if (!method || !outValue) {
        ZLog(@"[ZSFont] static bool %s unavailable (class=%p method=%p)", methodName, managerClass, method);
        return NO;
    }
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:method onInstance:NULL args:NULL outException:&exc];
    if (exc || !boxed) {
        ZLog(@"[ZSFont] static bool %s failed: %@", methodName, zs_describe_exception(exc));
        return NO;
    }
    *outValue = *(uint8_t *)((uint8_t *)boxed + kZSIl2CppObjectHeaderSize) != 0;
    return YES;
}

static void *zs_load_custom_font(NSString *path) {
    void *managerClass = zs_custom_localize_manager_class();
    const void *tryLoadMethod = mt_method(managerClass, "TryLoadFont", 5);
    ZLog(@"[ZSFont] TryLoadFont resolve: managerClass=%p method=%p", managerClass, tryLoadMethod);
    if (!tryLoadMethod) return NULL;

    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    ZLog(@"[ZSFont] TryLoadFont input: path=%@ size=%llu exists=%d sampling=%d padding=%d atlas=%d",
         path, attributes.fileSize, (int)[NSFileManager.defaultManager fileExistsAtPath:path],
         kZSCustomFontSamplingPointSize, kZSCustomFontPadding, kZSCustomFontAtlasSize);

    void *pathStr = [IL2CppBridge il2CppStringFromNSString:path];
    int32_t samplingPointSize = kZSCustomFontSamplingPointSize;
    int32_t padding = kZSCustomFontPadding;
    int32_t atlasSize = kZSCustomFontAtlasSize;
    void *output = NULL;
    void *args[5] = { pathStr, &samplingPointSize, &padding, &atlasSize, &output };
    void *exc = NULL;
    void *result = [IL2CppBridge invokeMethod:tryLoadMethod onInstance:NULL args:args outException:&exc];
    if (exc || !result) {
        ZLog(@"[ZSFont] TryLoadFont invoke failed: result=%p exception=%@", result, zs_describe_exception(exc));
        return NULL;
    }

    BOOL loaded = *(uint8_t *)((uint8_t *)result + kZSIl2CppObjectHeaderSize) != 0;
    ZLog(@"[ZSFont] TryLoadFont returned loaded=%d output=%p alive=%d", loaded, output, output ? (int)ZSUID_UnityObjectIsAlive(output) : -1);
    if (!loaded || !output) return NULL;
    return output;
}

static BOOL zs_read_custom_localize_fonts(void **titleFont, void **contextFont) {
    void *managerClass = zs_custom_localize_manager_class();
    void *resultClass = zs_custom_localize_result_class();
    if (!managerClass || !resultClass) return NO;

    void *dataField = [IL2CppBridge fieldNamed:"_data" onClass:managerClass];
    int32_t titleOffset = [IL2CppBridge fieldOffsetOnClass:resultClass name:"<TitleFont>k__BackingField"];
    int32_t contextOffset = [IL2CppBridge fieldOffsetOnClass:resultClass name:"<ContextFont>k__BackingField"];
    if (!dataField || titleOffset < 0 || contextOffset < 0) return NO;

    uint8_t buffer[256] = {0};
    if (![IL2CppBridge copyStaticFieldValue:dataField toBuffer:buffer]) return NO;

    if (titleFont) *titleFont = *(void **)(buffer + titleOffset - kZSIl2CppObjectHeaderSize);
    if (contextFont) *contextFont = *(void **)(buffer + contextOffset - kZSIl2CppObjectHeaderSize);
    return YES;
}

static BOOL zs_read_custom_localize_fonts_via_get(void **titleFont, void **contextFont) {
    void *managerClass = zs_custom_localize_manager_class();
    void *resultClass = zs_custom_localize_result_class();
    const void *getMethod = mt_method(managerClass, "Get", 0);
    int32_t titleOffset = [IL2CppBridge fieldOffsetOnClass:resultClass name:"<TitleFont>k__BackingField"];
    int32_t contextOffset = [IL2CppBridge fieldOffsetOnClass:resultClass name:"<ContextFont>k__BackingField"];
    int32_t initedOffset = [IL2CppBridge fieldOffsetOnClass:resultClass name:"<IsInited>k__BackingField"];
    int32_t existOffset = [IL2CppBridge fieldOffsetOnClass:resultClass name:"_isDataExist"];
    if (!getMethod || titleOffset < 0 || contextOffset < 0) {
        ZLog(@"[ZSFont] Get() unavailable: method=%p titleOffset=%d contextOffset=%d", getMethod, titleOffset, contextOffset);
        return NO;
    }
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:getMethod onInstance:NULL args:NULL outException:&exc];
    if (exc || !boxed) {
        ZLog(@"[ZSFont] Get() failed: result=%p exception=%@", boxed, zs_describe_exception(exc));
        return NO;
    }
    void *title = *(void **)((uint8_t *)boxed + titleOffset);
    void *context = *(void **)((uint8_t *)boxed + contextOffset);
    int inited = initedOffset >= 0 ? *((uint8_t *)boxed + initedOffset) : -1;
    int exists = existOffset >= 0 ? *((uint8_t *)boxed + existOffset) : -1;
    ZLog(@"[ZSFont] Get() -> boxed=%p inited=%d dataExist=%d title=%p context=%p", boxed, inited, exists, title, context);
    if (titleFont) *titleFont = title;
    if (contextFont) *contextFont = context;
    return YES;
}

static BOOL zs_install_custom_localize_result(void *titleFont, void *contextFont, NSString *directory) {
    ZLog(@"[ZSFont] install: begin title=%p context=%p directory=%@", titleFont, contextFont, directory);

    void *managerClass = zs_custom_localize_manager_class();
    void *resultClass = zs_custom_localize_result_class();
    ZLog(@"[ZSFont] install[1] classes: manager=%p searchResult=%p", managerClass, resultClass);
    if (!managerClass || !resultClass) return NO;

    BOOL isRunning = NO;
    BOOL haveRunning = zs_custom_localize_static_bool("IsRunning", &isRunning);
    ZLog(@"[ZSFont] install[2] class init via IsRunning: ok=%d value=%d", haveRunning, isRunning);

    const void *ctorMethod = mt_method(resultClass, ".ctor", 4);
    const void *isDataExistMethod = mt_method(resultClass, "IsDataExist", 0);
    void *dataField = [IL2CppBridge fieldNamed:"_data" onClass:managerClass];
    int32_t dataExistOffset = [IL2CppBridge fieldOffsetOnClass:resultClass name:"_isDataExist"];
    ZLog(@"[ZSFont] install[3] resolve: ctor=%p isDataExist=%p _data field=%p _isDataExist offset=%d", ctorMethod, isDataExistMethod, dataField, dataExistOffset);
    if (!ctorMethod || !dataField || dataExistOffset < 0) return NO;

    void *boxedResult = [IL2CppBridge newObjectForClass:resultClass];
    ZLog(@"[ZSFont] install[4] newObject: %p", boxedResult);
    if (!boxedResult) return NO;

    void *unboxedResult = (uint8_t *)boxedResult + kZSIl2CppObjectHeaderSize;
    void *directoryStr = [IL2CppBridge il2CppStringFromNSString:directory];
    void *keyStr = [IL2CppBridge il2CppStringFromNSString:kZSCustomLocalizeKey];
    void *ctorArgs[4] = { titleFont, contextFont, directoryStr, keyStr };
    void *ctorExc = NULL;
    [IL2CppBridge invokeMethod:ctorMethod onInstance:unboxedResult args:ctorArgs outException:&ctorExc];
    ZLog(@"[ZSFont] install[5] ctor: exception=%@ header=%@ struct=%@", zs_describe_exception(ctorExc), zs_hex_string(boxedResult, kZSIl2CppObjectHeaderSize), zs_hex_string(unboxedResult, 0x30));
    if (ctorExc) return NO;

    if (isDataExistMethod) {
        void *existExc = NULL;
        void *existBoxed = [IL2CppBridge invokeMethod:isDataExistMethod onInstance:unboxedResult args:NULL outException:&existExc];
        BOOL exists = !existExc && existBoxed && *(uint8_t *)((uint8_t *)existBoxed + kZSIl2CppObjectHeaderSize) != 0;
        ZLog(@"[ZSFont] install[6] IsDataExist after ctor: %d (exception=%@)", exists, zs_describe_exception(existExc));
        if (!exists) {
            *((uint8_t *)boxedResult + dataExistOffset) = 1;
            ZLog(@"[ZSFont] install[6] forced _isDataExist=1");
        }
    }

    uint8_t before[256] = {0};
    [IL2CppBridge copyStaticFieldValue:dataField toBuffer:before];
    ZLog(@"[ZSFont] install[7] _data before: %@", zs_hex_string(before, 0x30));

    [IL2CppBridge setStaticFieldValue:dataField fromBuffer:unboxedResult];

    uint8_t after[256] = {0};
    [IL2CppBridge copyStaticFieldValue:dataField toBuffer:after];
    ZLog(@"[ZSFont] install[8] _data after:  %@", zs_hex_string(after, 0x30));

    void *rawTitle = NULL;
    void *rawContext = NULL;
    BOOL rawOk = zs_read_custom_localize_fonts(&rawTitle, &rawContext);
    ZLog(@"[ZSFont] install[9] raw readback ok=%d title=%p context=%p (expected %p / %p)", rawOk, rawTitle, rawContext, titleFont, contextFont);

    void *getTitle = NULL;
    void *getContext = NULL;
    BOOL getOk = zs_read_custom_localize_fonts_via_get(&getTitle, &getContext);
    ZLog(@"[ZSFont] install[10] Get() readback ok=%d match=%d", getOk, getOk && getTitle == titleFont && getContext == contextFont);

    BOOL rawMatch = rawOk && rawTitle == titleFont && rawContext == contextFont;
    BOOL getMatch = getOk && getTitle == titleFont && getContext == contextFont;
    return rawMatch || getMatch;
}

static void *zs_load_font_manager_data(void) {
    void *fontManagerClass = mt_class("UtilityUI", "FontManagerScriptableObject", "Assembly-CSharp");
    void *resourcesClass = mt_class("UnityEngine", "Resources", "UnityEngine.CoreModule");
    const void *loadMethod = mt_method(resourcesClass, "Load", 2);
    void *typeObj = zs_type_object(fontManagerClass);
    ZLog(@"[ZSFont] FontManager load: class=%p resources=%p load=%p typeObj=%p", fontManagerClass, resourcesClass, loadMethod, typeObj);
    if (!loadMethod || !typeObj) return NULL;

    void *resourcePathStr = [IL2CppBridge il2CppStringFromNSString:@"Font/FontSet/FontManagerScriptableObject"];
    void *loadArgs[2] = { resourcePathStr, typeObj };
    void *exc = NULL;
    void *fontManagerData = [IL2CppBridge invokeMethod:loadMethod onInstance:NULL args:loadArgs outException:&exc];
    ZLog(@"[ZSFont] FontManager load result=%p exception=%@", fontManagerData, zs_describe_exception(exc));
    return exc ? NULL : fontManagerData;
}

static void *zs_tmp_font_asset_class(void) {
    return mt_class("TMPro", "TMP_FontAsset", "Unity.TextMeshPro");
}

static BOOL zs_font_asset_fallback_contains(void *listObj, void *font) {
    if (!listObj || !font) return NO;
    void *listClass = [IL2CppBridge classOfInstance:listObj];
    const void *containsMethod = [IL2CppBridge methodOnClass:listClass name:"Contains" argCount:1];
    if (!containsMethod) return NO;
    void *args[1] = { font };
    void *exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:containsMethod onInstance:listObj args:args outException:&exc];
    if (exc || !boxed) return NO;
    return *(uint8_t *)((uint8_t *)boxed + kZSIl2CppObjectHeaderSize) != 0;
}

static void zs_font_asset_fallback_add(void *listObj, void *font) {
    if (!listObj || !font) return;
    void *listClass = [IL2CppBridge classOfInstance:listObj];
    const void *addMethod = [IL2CppBridge methodOnClass:listClass name:"Add" argCount:1];
    if (!addMethod) return;
    void *args[1] = { font };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:addMethod onInstance:listObj args:args outException:&exc];
}

static void zs_font_asset_fallback_insert_front(void *listObj, void *font) {
    if (!listObj || !font) return;
    if (zs_font_asset_fallback_contains(listObj, font)) return;
    void *listClass = [IL2CppBridge classOfInstance:listObj];
    const void *insertMethod = [IL2CppBridge methodOnClass:listClass name:"Insert" argCount:2];
    if (!insertMethod) {
        zs_font_asset_fallback_add(listObj, font);
        return;
    }
    int32_t index = 0;
    void *args[2] = { &index, font };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:insertMethod onInstance:listObj args:args outException:&exc];
    if (exc) zs_font_asset_fallback_add(listObj, font);
}

static NSString *const kZSCustomFontPrewarmCharacters = @" !\"#$%&'()*+,-./0123456789:;<=>?@[\\]^_`{|}~ÀÈÌÒÙàèìòùÁÉÍÓÚáéíóúÂÊÎÔÛâêîôûÃÑÕãñõÄËÏÖÜäëïöüĀĒĪŌŪāēīōū";

static void zs_font_asset_try_add_characters(void *fontAsset, NSString *characters) {
    if (!fontAsset || characters.length == 0) return;
    void *fontAssetClass = zs_tmp_font_asset_class();
    const void *tryAddMethod = mt_method(fontAssetClass, "TryAddCharacters", 1);
    if (!fontAssetClass || !tryAddMethod) {
        ZLog(@"[ZSFont] TryAddCharacters unavailable: class=%p method=%p", fontAssetClass, tryAddMethod);
        return;
    }
    void *charsStr = [IL2CppBridge il2CppStringFromNSString:characters];
    void *args[1] = { charsStr };
    void *exc = NULL;
    void *result = [IL2CppBridge invokeMethod:tryAddMethod onInstance:fontAsset args:args outException:&exc];
    BOOL added = !exc && result && *(uint8_t *)((uint8_t *)result + kZSIl2CppObjectHeaderSize) != 0;
    ZLog(@"[ZSFont] TryAddCharacters on %p added=%d exception=%@", fontAsset, added, zs_describe_exception(exc));
}

static void zs_read_default_font_families(void *fontManagerData, NSMutableSet<NSValue *> *titleFamily, NSMutableSet<NSValue *> *contextFamily) {
    if (!fontManagerData) return;
    void *managerClass = mt_class("UtilityUI", "FontManagerScriptableObject", "Assembly-CSharp");
    void *fontSetClass = mt_class("UtilityUI", "FontSet", "Assembly-CSharp");
    void *fontAssetClass = mt_class("UtilityUI", "FontAsset", "Assembly-CSharp");
    if (!managerClass || !fontSetClass || !fontAssetClass) return;

    int32_t titleOffset = [IL2CppBridge fieldOffsetOnClass:fontSetClass name:"title"];
    int32_t subOffset = [IL2CppBridge fieldOffsetOnClass:fontSetClass name:"sub"];
    int32_t assetOffset = [IL2CppBridge fieldOffsetOnClass:fontAssetClass name:"fontAsset"];
    if (titleOffset < 0 || subOffset < 0 || assetOffset < 0) return;

    static const char *setNames[] = { "krSet", "enSet", "jpSet", "romanSet", "specialKanjiSet" };
    for (size_t i = 0; i < sizeof(setNames) / sizeof(setNames[0]); i++) {
        int32_t setOffset = [IL2CppBridge fieldOffsetOnClass:managerClass name:setNames[i]];
        if (setOffset < 0) continue;
        uint8_t *setBase = (uint8_t *)fontManagerData + setOffset;
        void *titleAsset = *(void **)(setBase + (titleOffset - kZSIl2CppObjectHeaderSize) + (assetOffset - kZSIl2CppObjectHeaderSize));
        void *subAsset = *(void **)(setBase + (subOffset - kZSIl2CppObjectHeaderSize) + (assetOffset - kZSIl2CppObjectHeaderSize));
        if (titleAsset) [titleFamily addObject:[NSValue valueWithPointer:titleAsset]];
        if (subAsset) [contextFamily addObject:[NSValue valueWithPointer:subAsset]];
    }
}

static void zs_append_font_group(void *listObj, NSArray<NSValue *> *group) {
    if (!listObj) return;
    for (NSValue *value in group) {
        void *asset = value.pointerValue;
        if (!zs_font_asset_fallback_contains(listObj, asset)) zs_font_asset_fallback_add(listObj, asset);
    }
}

static void zs_append_custom_fallback_to_loaded_font_assets(void *titleFont, void *contextFont, void *cjkFont, void *fontManagerData) {
    void *fontAssetClass = zs_tmp_font_asset_class();
    const void *getFallbackMethod = mt_method(fontAssetClass, "get_fallbackFontAssetTable", 0);
    if (!fontAssetClass || !getFallbackMethod) {
        ZLog(@"[ZSFont] fallback-patch skipped: class=%p getter=%p", fontAssetClass, getFallbackMethod);
        return;
    }

    NSUInteger count = 0;
    void *fontAssets = zs_resources_find_all_for_class(fontAssetClass, &count);
    if (!fontAssets) {
        ZLog(@"[ZSFont] fallback-patch skipped: no live TMP_FontAsset instances");
        return;
    }

    void *titleListObj = NULL;
    void *contextListObj = NULL;
    if (titleFont) {
        void *titleExc = NULL;
        titleListObj = [IL2CppBridge invokeMethod:getFallbackMethod onInstance:titleFont args:NULL outException:&titleExc];
        if (titleExc) titleListObj = NULL;
    }
    if (contextFont) {
        if (contextFont == titleFont) {
            contextListObj = titleListObj;
        } else {
            void *contextExc = NULL;
            contextListObj = [IL2CppBridge invokeMethod:getFallbackMethod onInstance:contextFont args:NULL outException:&contextExc];
            if (contextExc) contextListObj = NULL;
        }
    }

    if (cjkFont && titleListObj && cjkFont != titleFont) zs_font_asset_fallback_insert_front(titleListObj, cjkFont);
    if (cjkFont && contextListObj && contextListObj != titleListObj && cjkFont != contextFont) zs_font_asset_fallback_insert_front(contextListObj, cjkFont);

    NSMutableSet<NSValue *> *titleFamily = [NSMutableSet set];
    NSMutableSet<NSValue *> *contextFamily = [NSMutableSet set];
    zs_read_default_font_families(fontManagerData, titleFamily, contextFamily);

    NSMutableArray<NSValue *> *titleGroup = [NSMutableArray array];
    NSMutableArray<NSValue *> *contextGroup = [NSMutableArray array];
    NSMutableArray<NSValue *> *neutralGroup = [NSMutableArray array];

    NSUInteger patched = 0;
    for (NSUInteger i = 0; i < count; i++) {
        void *fontAsset = zs_array_object_at(fontAssets, i);
        if (!fontAsset || fontAsset == titleFont || fontAsset == contextFont || fontAsset == cjkFont) continue;

        void *exc = NULL;
        void *listObj = [IL2CppBridge invokeMethod:getFallbackMethod onInstance:fontAsset args:NULL outException:&exc];
        if (exc || !listObj) continue;

        NSValue *assetKey = [NSValue valueWithPointer:fontAsset];
        BOOL inTitleFamily = [titleFamily containsObject:assetKey];
        BOOL inContextFamily = [contextFamily containsObject:assetKey];
        void *ownRoleFont = NULL;
        if (inTitleFamily && !inContextFamily) {
            ownRoleFont = titleFont;
            [titleGroup addObject:assetKey];
        } else if (inContextFamily && !inTitleFamily) {
            ownRoleFont = contextFont;
            [contextGroup addObject:assetKey];
        } else {
            [neutralGroup addObject:assetKey];
        }

        BOOL changed = NO;
        if (cjkFont && !zs_font_asset_fallback_contains(listObj, cjkFont)) {
            zs_font_asset_fallback_insert_front(listObj, cjkFont);
            changed = YES;
        }
        if (ownRoleFont && !zs_font_asset_fallback_contains(listObj, ownRoleFont)) {
            zs_font_asset_fallback_insert_front(listObj, ownRoleFont);
            changed = YES;
        }
        if (titleFont && !zs_font_asset_fallback_contains(listObj, titleFont)) {
            zs_font_asset_fallback_add(listObj, titleFont);
            changed = YES;
        }
        if (contextFont && contextFont != titleFont && !zs_font_asset_fallback_contains(listObj, contextFont)) {
            zs_font_asset_fallback_add(listObj, contextFont);
            changed = YES;
        }
        if (changed) patched++;
    }

    zs_append_font_group(titleListObj, titleGroup);
    zs_append_font_group(titleListObj, neutralGroup);
    zs_append_font_group(titleListObj, contextGroup);
    if (contextListObj != titleListObj) {
        zs_append_font_group(contextListObj, contextGroup);
        zs_append_font_group(contextListObj, neutralGroup);
        zs_append_font_group(contextListObj, titleGroup);
    }
    ZLog(@"[ZSFont] fallback-patch: patched %lu/%lu live TMP_FontAsset instance(s), cjk=%p families title=%lu context=%lu neutral=%lu",
         (unsigned long)patched, (unsigned long)count, cjkFont,
         (unsigned long)titleGroup.count, (unsigned long)contextGroup.count, (unsigned long)neutralGroup.count);
}

static void zs_refresh_font_consumers(void *fontManagerData) {
    void *fontManagerClass = mt_class("UtilityUI", "FontManagerScriptableObject", "Assembly-CSharp");
    const void *setFallbackMethod = mt_method(fontManagerClass, "SetFallbackFontsByLanguage", 1);
    ZLog(@"[ZSFont] refresh: fontManagerData=%p setFallback=%p", fontManagerData, setFallbackMethod);
    if (fontManagerData && setFallbackMethod) {
        for (int32_t language = 0; language < kZSFontLanguageCount; language++) {
            int32_t languageValue = language;
            void *langArgs[1] = { &languageValue };
            void *fallbackExc = NULL;
            [IL2CppBridge invokeMethod:setFallbackMethod onInstance:fontManagerData args:langArgs outException:&fallbackExc];
            ZLog(@"[ZSFont] SetFallbackFontsByLanguage(%d) exception=%@", language, zs_describe_exception(fallbackExc));
        }
    }

    const char *setterClassNames[] = {
        "FontSetter", "FontTypesCategorySetter", "BebasKaiFontSetter", "ExcelsiorSansFontSetter",
        "FixedFontSetter", "PretendardFontSetter", "TextMeshProLanguageSetter"
    };
    for (size_t i = 0; i < sizeof(setterClassNames) / sizeof(setterClassNames[0]); i++) {
        void *setterClass = mt_class("UtilityUI", setterClassNames[i], "Assembly-CSharp");
        const void *updateMethod = mt_method(setterClass, "UpdateTMP", 0);
        if (!setterClass || !updateMethod) {
            ZLog(@"[ZSFont] refresh %s skipped: class=%p UpdateTMP=%p", setterClassNames[i], setterClass, updateMethod);
            continue;
        }
        NSUInteger setterCount = 0;
        void *setterArray = zs_resources_find_all_for_class(setterClass, &setterCount);
        if (!setterArray) {
            ZLog(@"[ZSFont] refresh %s skipped: no instance array", setterClassNames[i]);
            continue;
        }
        NSUInteger failures = 0;
        for (NSUInteger j = 0; j < setterCount; j++) {
            void *setterInstance = zs_array_object_at(setterArray, j);
            if (!setterInstance) continue;
            void *updateExc = NULL;
            [IL2CppBridge invokeMethod:updateMethod onInstance:setterInstance args:NULL outException:&updateExc];
            if (updateExc) failures++;
        }
        ZLog(@"[ZSFont] refreshed %lu live %s instance(s), %lu exception(s)", (unsigned long)setterCount, setterClassNames[i], (unsigned long)failures);
    }

    const char *langRefreshClassNames[] = { "TextMeshProLanguageSetterManager", "TextMeshProChildrenSetter" };
    const char *langRefreshMethodNames[] = { "UpdateUIs", "RefreshLanguage" };
    for (size_t i = 0; i < sizeof(langRefreshClassNames) / sizeof(langRefreshClassNames[0]); i++) {
        void *langRefreshClass = mt_class("UtilityUI", langRefreshClassNames[i], "Assembly-CSharp");
        const void *langRefreshMethod = mt_method(langRefreshClass, langRefreshMethodNames[i], 1);
        if (!langRefreshClass || !langRefreshMethod) {
            ZLog(@"[ZSFont] refresh %s.%s skipped: class=%p method=%p", langRefreshClassNames[i], langRefreshMethodNames[i], langRefreshClass, langRefreshMethod);
            continue;
        }
        NSUInteger langRefreshCount = 0;
        void *langRefreshArray = zs_resources_find_all_for_class(langRefreshClass, &langRefreshCount);
        if (!langRefreshArray) {
            ZLog(@"[ZSFont] refresh %s skipped: no instance array", langRefreshClassNames[i]);
            continue;
        }
        NSUInteger failures = 0;
        for (NSUInteger j = 0; j < langRefreshCount; j++) {
            void *langRefreshInstance = zs_array_object_at(langRefreshArray, j);
            if (!langRefreshInstance) continue;
            for (int32_t language = 0; language < kZSFontLanguageCount; language++) {
                int32_t languageValue = language;
                void *langRefreshArgs[1] = { &languageValue };
                void *langRefreshExc = NULL;
                [IL2CppBridge invokeMethod:langRefreshMethod onInstance:langRefreshInstance args:langRefreshArgs outException:&langRefreshExc];
                if (langRefreshExc) failures++;
            }
        }
        ZLog(@"[ZSFont] refreshed %lu live %s instance(s), %lu exception(s)", (unsigned long)langRefreshCount, langRefreshClassNames[i], (unsigned long)failures);
    }

    void *duiStyleManagerClass = mt_class("DUI.StyleLibs", "DUIStyleManager", "Assembly-CSharp");
    const void *onSceneChangedMethod = mt_method(duiStyleManagerClass, "OnSceneChanged", 0);
    if (onSceneChangedMethod) {
        NSUInteger duiCount = 0;
        void *duiArray = zs_resources_find_all_for_class(duiStyleManagerClass, &duiCount);
        NSUInteger failures = 0;
        for (NSUInteger j = 0; duiArray && j < duiCount; j++) {
            void *duiInstance = zs_array_object_at(duiArray, j);
            if (!duiInstance) continue;
            void *duiExc = NULL;
            [IL2CppBridge invokeMethod:onSceneChangedMethod onInstance:duiInstance args:NULL outException:&duiExc];
            if (duiExc) failures++;
        }
        ZLog(@"[ZSFont] refreshed %lu live DUIStyleManager instance(s), %lu exception(s)", (unsigned long)duiCount, (unsigned long)failures);
    } else {
        ZLog(@"[ZSFont] refresh DUIStyleManager skipped: class=%p OnSceneChanged=%p", duiStyleManagerClass, onSceneChangedMethod);
    }
}

static void zs_log_custom_localize_state(void *fontManagerData, void *titleFont, void *contextFont) {
    BOOL isRunning = NO;
    BOOL isUsing = NO;
    BOOL haveRunning = zs_custom_localize_static_bool("IsRunning", &isRunning);
    BOOL haveUsing = zs_custom_localize_static_bool("IsUsing", &isUsing);
    ZLog(@"[ZSFont] CustomLocalizeManager IsRunning=%d IsUsing=%d", haveRunning ? isRunning : -1, haveUsing ? isUsing : -1);

    void *getTitle = NULL;
    void *getContext = NULL;
    zs_read_custom_localize_fonts_via_get(&getTitle, &getContext);

    void *fontManagerClass = mt_class("UtilityUI", "FontManagerScriptableObject", "Assembly-CSharp");
    void *fontAssetStructClass = mt_class("UtilityUI", "FontAsset", "Assembly-CSharp");
    const void *getFontAssetMethod = mt_method(fontManagerClass, "GetFontAsset", 2);
    int32_t fontAssetOffset = [IL2CppBridge fieldOffsetOnClass:fontAssetStructClass name:"fontAsset"];
    if (!fontManagerData || !getFontAssetMethod || fontAssetOffset < 0) {
        ZLog(@"[ZSFont] slot check skipped: data=%p method=%p offset=%d", fontManagerData, getFontAssetMethod, fontAssetOffset);
        return;
    }

    static const char *typeNames[] = { "Title", "Sub" };
    static const char *languageNames[] = { "KR", "EN", "JP" };
    int32_t matched = 0;
    int32_t total = 0;
    for (int32_t type = 0; type < kZSFontTypeCount; type++) {
        for (int32_t language = 0; language < kZSFontLanguageCount; language++) {
            int32_t typeValue = type;
            int32_t languageValue = language;
            void *args[2] = { &typeValue, &languageValue };
            void *exc = NULL;
            void *boxed = [IL2CppBridge invokeMethod:getFontAssetMethod onInstance:fontManagerData args:args outException:&exc];
            total++;
            if (exc || !boxed) {
                ZLog(@"[ZSFont] slot %s/%s: GetFontAsset failed exception=%@", typeNames[type], languageNames[language], zs_describe_exception(exc));
                continue;
            }
            void *resolved = *(void **)((uint8_t *)boxed + fontAssetOffset);
            BOOL isCustom = resolved == titleFont || resolved == contextFont;
            if (isCustom) matched++;
            ZLog(@"[ZSFont] slot %s/%s: fontAsset=%p custom=%d", typeNames[type], languageNames[language], resolved, isCustom);
        }
    }
    ZLog(@"[ZSFont] FontManager primary slots resolving to the custom font: %d/%d", matched, total);
}

static void zs_apply_custom_font_if_present(void) {
    NSString *fontsDir = zs_custom_font_directory();
    if (!fontsDir) return;

    NSString *assignedTitlePath = zs_assigned_font_path(ZSFontRoleTitle);
    NSString *assignedContextPath = zs_assigned_font_path(ZSFontRoleContext);
    NSString *cjkPath = zs_assigned_font_path(ZSFontRoleKanjiHanzi);
    NSString *titlePath = assignedTitlePath ?: assignedContextPath ?: cjkPath;
    NSString *contextPath = assignedContextPath ?: assignedTitlePath ?: cjkPath;
    ZLog(@"[ZSFont] apply: directory=%@ assigned title=%@ context=%@ cjk=%@", fontsDir,
         assignedTitlePath.lastPathComponent ?: @"(none)", assignedContextPath.lastPathComponent ?: @"(none)", cjkPath.lastPathComponent ?: @"(none)");
    if (!titlePath || !contextPath) return;

    NSMutableArray<NSString *> *signatureInputs = [NSMutableArray arrayWithObjects:titlePath, contextPath, nil];
    if (cjkPath) [signatureInputs addObject:cjkPath];
    NSString *signature = zs_custom_font_signature(signatureInputs);
    ZLog(@"[ZSFont] apply: title=%@ context=%@ cjk=%@", titlePath.lastPathComponent, contextPath.lastPathComponent, cjkPath.lastPathComponent ?: @"(none)");

    BOOL cjkCachedUsable = !cjkPath || (g_zsCustomFontCJK && ZSUID_UnityObjectIsAlive(g_zsCustomFontCJK));
    BOOL cachedFontsUsable = g_zsCustomFontTitle && g_zsCustomFontContext &&
        [signature isEqualToString:g_zsCustomFontSignature] &&
        ZSUID_UnityObjectIsAlive(g_zsCustomFontTitle) && ZSUID_UnityObjectIsAlive(g_zsCustomFontContext) &&
        cjkCachedUsable;

    void *currentTitle = NULL;
    void *currentContext = NULL;
    BOOL haveCurrent = zs_read_custom_localize_fonts(&currentTitle, &currentContext);
    ZLog(@"[ZSFont] apply: cachedUsable=%d cached=%p/%p current(haveCurrent=%d)=%p/%p",
         cachedFontsUsable, g_zsCustomFontTitle, g_zsCustomFontContext, haveCurrent, currentTitle, currentContext);
    BOOL alreadyInstalled = cachedFontsUsable && haveCurrent && currentTitle == g_zsCustomFontTitle && currentContext == g_zsCustomFontContext;

    void *titleFont = g_zsCustomFontTitle;
    void *contextFont = g_zsCustomFontContext;
    void *cjkFont = g_zsCustomFontCJK;

    if (!alreadyInstalled) {
        if (!cachedFontsUsable) {
            titleFont = zs_load_custom_font(titlePath);
            if (!titleFont) {
                ZLog(@"[ZSFont] apply: aborting, title font failed to load");
                return;
            }
            contextFont = [contextPath isEqualToString:titlePath] ? titleFont : zs_load_custom_font(contextPath);
            if (!contextFont) {
                ZLog(@"[ZSFont] apply: aborting, context font failed to load");
                return;
            }
            zs_font_asset_try_add_characters(titleFont, kZSCustomFontPrewarmCharacters);
            if (contextFont != titleFont) zs_font_asset_try_add_characters(contextFont, kZSCustomFontPrewarmCharacters);
            cjkFont = NULL;
            if (cjkPath) {
                if ([cjkPath isEqualToString:titlePath]) cjkFont = titleFont;
                else if ([cjkPath isEqualToString:contextPath]) cjkFont = contextFont;
                else {
                    cjkFont = zs_load_custom_font(cjkPath);
                    if (!cjkFont) ZLog(@"[ZSFont] apply: CJK font failed to load, continuing without it");
                }
            }
        }

        g_zsCustomFontTitle = titleFont;
        g_zsCustomFontContext = contextFont;
        g_zsCustomFontCJK = cjkFont;
        g_zsCustomFontSignature = signature;

        if (!zs_install_custom_localize_result(titleFont, contextFont, fontsDir)) {
            g_zsCustomFontTitle = NULL;
            g_zsCustomFontContext = NULL;
            g_zsCustomFontCJK = NULL;
            g_zsCustomFontSignature = nil;
            ZLog(@"[ZSFont] failed to install custom fonts into CustomLocalizeManager");
            return;
        }

        ZLog(@"[ZSFont] installed %@ (title) and %@ (context) into CustomLocalizeManager", titlePath.lastPathComponent, contextPath.lastPathComponent);
    } else {
        ZLog(@"[ZSFont] apply: already installed, refreshing consumers for the current scene");
    }

    void *fontManagerData = zs_load_font_manager_data();
    zs_refresh_font_consumers(fontManagerData);
    zs_append_custom_fallback_to_loaded_font_assets(titleFont, contextFont, cjkFont, fontManagerData);
    zs_log_custom_localize_state(fontManagerData, titleFont, contextFont);
}

static const double kFontApplyDelaySeconds = 2.0;

void zs_schedule_font_apply(void) {
    static uint64_t fontApplyGeneration;
    uint64_t token = ++fontApplyGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFontApplyDelaySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != fontApplyGeneration) return;
        zs_apply_custom_font_if_present();
    });
}
