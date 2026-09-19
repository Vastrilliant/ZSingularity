
#import "LocalizationMods.h"
#import "ZTweakLog.h"
#import "ZSEngine.h"
#import "UnityBundleTools.h"

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
    for (NSString *path in paths) {
        NSString *leaf = path.lastPathComponent;
        if ([leaf.pathExtension caseInsensitiveCompare:@"json"] != NSOrderedSame) continue;
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
    return [documentsDir stringByAppendingPathComponent:@"Assets/Resources_moved/Localize"];
}

+ (nullable NSString *)languageDirectoryForCode:(NSString *)languageCode {
    if (!LTIsValidLanguageCode(languageCode)) return nil;
    NSString *localizeDir = [self localizeDirectory];
    return localizeDir ? [localizeDir stringByAppendingPathComponent:languageCode] : nil;
}

+ (nullable NSString *)backupDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityLocalizeBackups"];
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
    if (![self lt_replaceDirectoryAtPath:languageDir withCopyOfDirectoryAtPath:packPath error:error]) return NO;

    NSString *markerPath = LTPackMarkerPath(languageCode);
    if (markerPath) {
        [LTPackFingerprint(packPath) writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    zs_track_asset_path(languageDir);
    [ZSFileIndex ensureLocalizationIndexUpToDate];
    ZLog(@"[LocalizationTransplant] swapped the \"%@\" language folder with %@", languageCode, packPath.lastPathComponent);
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

@end
