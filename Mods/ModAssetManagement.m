#import "ModAssetManagement.h"
#import "ZTweakLog.h"
#import "BankTransplant.h"
#import "LocalizationMods.h"
#import "UnityBundleTools.h"
#import <compression.h>

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
static NSString * const kMALManifestFileName = @"manifest.json";
static NSString * const kMALFolderRemarkFileName = @"remark.txt";
static NSString * const kMALOriginalBundleBackupsDirectoryName = @".OriginalBundleBackups";

static NSError *MALError(ModAssetLibraryErrorCode code, NSString *message) {
    return [NSError errorWithDomain:ModAssetLibraryErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
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
+ (NSString *)mal_manifestPathForFolder:(NSString *)folderName;
+ (NSString *)mal_remarkPathForFolder:(NSString *)folderName;
+ (BOOL)mal_writeEntries:(NSArray<ModAssetLibraryEntry *> *)entries toFolder:(NSString *)folderName error:(NSError **)error;
+ (NSString *)mal_uniqueFileNameFor:(NSString *)desired inFolder:(NSString *)folderPath;
+ (NSString *)mal_uniqueFolderNameFor:(NSString *)desired inParentFolder:(NSString *)parentPath;
+ (nullable NSString *)mal_livePathDescriptionForFileName:(NSString *)fileName;
+ (void)mal_reconcileEntryPaths:(NSArray<ModAssetLibraryEntry *> *)entries folderName:(NSString *)folderName;
+ (NSString *)mal_gameBundleRelativePath:(NSString *)path;
@end

@implementation ModAssetLibrary

+ (NSString *)liveGamePathDescriptionForInstalledURL:(NSURL *)installedURL {
    return [self mal_sandboxRelativePath:installedURL.path];
}

+ (NSString *)modLibraryRootDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libraryDir = paths.firstObject;
    if (!libraryDir) return nil;
    return [libraryDir stringByAppendingPathComponent:@"ZSingularityModsLibrary"];
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
    NSString *root = [self modLibraryRootDirectory];
    if (!root) return nil;
    return [root stringByAppendingPathComponent:kMALOriginalBundleBackupsDirectoryName];
}

+ (NSArray<NSString *> *)folderNames {
    NSString *root = [self modLibraryRootDirectory];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (!root || ![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) return @[];

    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    for (NSString *entry in entries) {
        if ([entry isEqualToString:kMALOriginalBundleBackupsDirectoryName]) continue;
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

static NSString *MALCABRejectionLine(NSString *displayName) {
    return [NSString stringWithFormat:@"%@: rejected - its CAB identifier could not be found, meaning it's either malformed or outdated", displayName];
}

+ (BOOL)importFileURLs:(NSArray<NSURL *> *)moddedURLs
             intoFolder:(NSString *)folderName
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

    NSMutableArray<NSString *> *rejectedLines = [NSMutableArray array];
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
        entry.cabIdentifier = cabID;
        entry.targetPlatform = targetPlatformNumber;

        entry.livePathDescription = [self mal_livePathDescriptionForFileName:destName];
        entry.resolvedInstallTargetPath = resolvedTargetPath;
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

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *destName = [self mal_uniqueFolderNameFor:sourcePath.lastPathComponent inParentFolder:folderPath];
    NSString *destPath = [folderPath stringByAppendingPathComponent:destName];

    NSError *copyErr = nil;
    if (![fm copyItemAtPath:sourcePath toPath:destPath error:&copyErr]) {
        [fm removeItemAtPath:destPath error:nil];
        [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - couldn't copy it into the library: %@", displayName, copyErr.localizedDescription ?: @"unknown error"]];
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

