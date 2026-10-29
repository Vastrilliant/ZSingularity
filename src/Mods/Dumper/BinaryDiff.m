#import "BinaryDiff.h"
#import "ZTweakLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <compression.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach-o/nlist.h>
#import <libkern/OSByteOrder.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>

NSString * const ZSBinaryDiffErrorDomain = @"ZSBinaryDiff";

static NSString * const kZSBDFrameworkEntry = @"Frameworks/UnityFramework.framework/UnityFramework";
static NSString * const kZSBDMetadataEntry = @"Data/Managed/Metadata/global-metadata.dat";
static NSString * const kZSBDInfoEntry = @"Info.plist";

static const size_t kZSBDChunk = 1 << 20;
static const size_t kZSBDMaxLineChars = 600;

static NSError *zs_bd_error(ZSBinaryDiffErrorCode code, NSString *message) {
    return [NSError errorWithDomain:ZSBinaryDiffErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static inline uint16_t zs_bd_u16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static inline uint32_t zs_bd_u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline uint64_t zs_bd_u64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }

typedef struct {
    const uint8_t *p;
    size_t n;
} ZSBDMap;

static BOOL zs_bd_map_open(NSString *path, ZSBDMap *map) {
    map->p = NULL;
    map->n = 0;
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        return NO;
    }
    void *mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) return NO;
    map->p = (const uint8_t *)mapped;
    map->n = (size_t)st.st_size;
    return YES;
}

static void zs_bd_map_close(ZSBDMap *map) {
    if (map->p) munmap((void *)map->p, map->n);
    map->p = NULL;
    map->n = 0;
}

static NSString *zs_bd_hex(const uint8_t *digest, size_t length) {
    static const char digits[] = "0123456789abcdef";
    char buffer[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < length && i < CC_SHA256_DIGEST_LENGTH; i++) {
        buffer[i * 2] = digits[digest[i] >> 4];
        buffer[i * 2 + 1] = digits[digest[i] & 0xF];
    }
    buffer[MIN(length, (size_t)CC_SHA256_DIGEST_LENGTH) * 2] = 0;
    return [NSString stringWithUTF8String:buffer];
}

static NSString *zs_bd_sha256_file(NSString *path, BOOL (^isCancelled)(void)) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;
    uint8_t *buffer = malloc(kZSBDChunk);
    if (!buffer) {
        close(fd);
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    BOOL ok = YES;
    while (YES) {
        if (isCancelled()) {
            ok = NO;
            break;
        }
        ssize_t got = read(fd, buffer, kZSBDChunk);
        if (got < 0) {
            ok = NO;
            break;
        }
        if (got == 0) break;
        CC_SHA256_Update(&ctx, buffer, (CC_LONG)got);
    }
    free(buffer);
    close(fd);
    if (!ok) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    return zs_bd_hex(digest, CC_SHA256_DIGEST_LENGTH);
}

typedef struct {
    uint16_t method;
    uint64_t compressedSize;
    uint64_t size;
    uint64_t localOffset;
    BOOL found;
} ZSBDZipEntry;

static NSString *zs_bd_relative_app_path(NSString *name) {
    if (![name hasPrefix:@"Payload/"]) return nil;
    NSRange slash = [name rangeOfString:@"/" options:0 range:NSMakeRange(8, name.length - 8)];
    if (slash.location == NSNotFound) return nil;
    NSString *appDirectory = [name substringWithRange:NSMakeRange(8, slash.location - 8)];
    if (![appDirectory hasSuffix:@".app"]) return nil;
    return [name substringFromIndex:slash.location + 1];
}

static BOOL zs_bd_zip_locate(ZSBDMap zip, uint64_t *cdOffset, uint64_t *cdSize, uint64_t *count) {
    if (zip.n < 22) return NO;
    size_t window = MIN((size_t)(22 + 65535), zip.n);
    size_t lowest = zip.n - window;
    size_t i = zip.n - 22;
    BOOL found = NO;
    while (YES) {
        if (zs_bd_u32(zip.p + i) == 0x06054b50) {
            uint16_t commentLength = zs_bd_u16(zip.p + i + 20);
            if (i + 22 + commentLength == zip.n) {
                found = YES;
                break;
            }
        }
        if (i == lowest) break;
        i--;
    }
    if (!found) return NO;
    uint64_t entries = zs_bd_u16(zip.p + i + 10);
    uint64_t size = zs_bd_u32(zip.p + i + 12);
    uint64_t offset = zs_bd_u32(zip.p + i + 16);
    if ((entries == 0xFFFF || size == 0xFFFFFFFF || offset == 0xFFFFFFFF) && i >= 20 && zs_bd_u32(zip.p + i - 20) == 0x07064b50) {
        uint64_t record = zs_bd_u64(zip.p + i - 20 + 8);
        if (record + 56 <= zip.n && zs_bd_u32(zip.p + record) == 0x06064b50) {
            entries = zs_bd_u64(zip.p + record + 32);
            size = zs_bd_u64(zip.p + record + 40);
            offset = zs_bd_u64(zip.p + record + 48);
        }
    }
    if (offset + size > zip.n) return NO;
    *cdOffset = offset;
    *cdSize = size;
    *count = entries;
    return YES;
}

static BOOL zs_bd_zip_find(ZSBDMap zip, NSArray<NSString *> *wanted, ZSBDZipEntry *out) {
    uint64_t cdOffset = 0, cdSize = 0, count = 0;
    if (!zs_bd_zip_locate(zip, &cdOffset, &cdSize, &count)) return NO;
    uint64_t cursor = cdOffset;
    uint64_t end = cdOffset + cdSize;
    for (uint64_t k = 0; k < count && cursor + 46 <= end; k++) {
        const uint8_t *record = zip.p + cursor;
        if (zs_bd_u32(record) != 0x02014b50) break;
        uint16_t method = zs_bd_u16(record + 10);
        uint64_t compressed = zs_bd_u32(record + 20);
        uint64_t size = zs_bd_u32(record + 24);
        uint16_t nameLength = zs_bd_u16(record + 28);
        uint16_t extraLength = zs_bd_u16(record + 30);
        uint16_t commentLength = zs_bd_u16(record + 32);
        uint64_t local = zs_bd_u32(record + 42);
        if (cursor + 46 + nameLength + extraLength + commentLength > end) break;
        const uint8_t *name = record + 46;
        if (nameLength > 8 && memcmp(name, "Payload/", 8) == 0) {
            NSString *full = [[NSString alloc] initWithBytes:name length:nameLength encoding:NSUTF8StringEncoding];
            NSString *relative = full ? zs_bd_relative_app_path(full) : nil;
            NSUInteger index = relative ? [wanted indexOfObject:relative] : NSNotFound;
            if (index != NSNotFound && !out[index].found) {
                if (compressed == 0xFFFFFFFF || size == 0xFFFFFFFF || local == 0xFFFFFFFF) {
                    const uint8_t *extra = name + nameLength;
                    const uint8_t *extraEnd = extra + extraLength;
                    while (extra + 4 <= extraEnd) {
                        uint16_t fieldID = zs_bd_u16(extra);
                        uint16_t fieldLength = zs_bd_u16(extra + 2);
                        const uint8_t *data = extra + 4;
                        if (data + fieldLength > extraEnd) break;
                        if (fieldID == 1) {
                            size_t used = 0;
                            if (size == 0xFFFFFFFF && used + 8 <= fieldLength) { size = zs_bd_u64(data + used); used += 8; }
                            if (compressed == 0xFFFFFFFF && used + 8 <= fieldLength) { compressed = zs_bd_u64(data + used); used += 8; }
                            if (local == 0xFFFFFFFF && used + 8 <= fieldLength) { local = zs_bd_u64(data + used); used += 8; }
                            break;
                        }
                        extra += 4 + fieldLength;
                    }
                }
                out[index].method = method;
                out[index].compressedSize = compressed;
                out[index].size = size;
                out[index].localOffset = local;
                out[index].found = YES;
            }
        }
        cursor += 46 + nameLength + extraLength + commentLength;
    }
    return YES;
}

static BOOL zs_bd_write_all(int fd, const uint8_t *bytes, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, bytes, length);
        if (written <= 0) return NO;
        bytes += written;
        length -= (size_t)written;
    }
    return YES;
}

static BOOL zs_bd_zip_extract(ZSBDMap zip, const ZSBDZipEntry *entry, NSString *destination, NSString **sha, BOOL (^isCancelled)(void), void (^tick)(double), NSError **error) {
    if (entry->localOffset + 30 > zip.n || zs_bd_u32(zip.p + entry->localOffset) != 0x04034b50) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorBadArchive, @"The IPA contains a corrupt entry header.");
        return NO;
    }
    uint64_t nameLength = zs_bd_u16(zip.p + entry->localOffset + 26);
    uint64_t extraLength = zs_bd_u16(zip.p + entry->localOffset + 28);
    uint64_t dataStart = entry->localOffset + 30 + nameLength + extraLength;
    if (dataStart + entry->compressedSize > zip.n) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorBadArchive, @"The IPA is truncated.");
        return NO;
    }
    if (entry->method != 0 && entry->method != 8) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorBadArchive, [NSString stringWithFormat:@"Unsupported zip compression method %u.", entry->method]);
        return NO;
    }
    int fd = open(destination.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorIO, @"Could not create a temporary file for extraction.");
        return NO;
    }
    const uint8_t *source = zip.p + dataStart;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint64_t produced = 0;
    BOOL ok = YES;
    BOOL cancelled = NO;
    NSString *failure = nil;

    if (entry->method == 0) {
        uint64_t offset = 0;
        while (offset < entry->compressedSize) {
            if (isCancelled()) { cancelled = YES; ok = NO; break; }
            size_t piece = (size_t)MIN((uint64_t)kZSBDChunk, entry->compressedSize - offset);
            if (!zs_bd_write_all(fd, source + offset, piece)) {
                ok = NO;
                failure = @"Writing the extracted file failed.";
                break;
            }
            CC_SHA256_Update(&ctx, source + offset, (CC_LONG)piece);
            offset += piece;
            produced += piece;
            if (tick && entry->size) tick((double)produced / (double)entry->size);
        }
    } else {
        compression_stream stream;
        if (compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_OK) {
            close(fd);
            if (error) *error = zs_bd_error(ZSBinaryDiffErrorIO, @"Could not start the decompressor.");
            return NO;
        }
        uint8_t *buffer = malloc(kZSBDChunk);
        if (!buffer) {
            compression_stream_destroy(&stream);
            close(fd);
            if (error) *error = zs_bd_error(ZSBinaryDiffErrorIO, @"Out of memory while extracting.");
            return NO;
        }
        stream.src_ptr = source;
        stream.src_size = (size_t)entry->compressedSize;
        compression_status status = COMPRESSION_STATUS_OK;
        do {
            if (isCancelled()) { cancelled = YES; ok = NO; break; }
            stream.dst_ptr = buffer;
            stream.dst_size = kZSBDChunk;
            status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
            size_t got = kZSBDChunk - stream.dst_size;
            if (status == COMPRESSION_STATUS_ERROR) {
                ok = NO;
                failure = @"The IPA entry is corrupt (decompression failed).";
                break;
            }
            if (got) {
                if (!zs_bd_write_all(fd, buffer, got)) {
                    ok = NO;
                    failure = @"Writing the extracted file failed.";
                    break;
                }
                CC_SHA256_Update(&ctx, buffer, (CC_LONG)got);
                produced += got;
                if (tick && entry->size) tick(MIN(1.0, (double)produced / (double)entry->size));
            } else if (status == COMPRESSION_STATUS_OK && stream.src_size == 0) {
                ok = NO;
                failure = @"The IPA entry ended unexpectedly.";
                break;
            }
        } while (status == COMPRESSION_STATUS_OK);
        free(buffer);
        compression_stream_destroy(&stream);
    }
    close(fd);

    if (ok && produced != entry->size) {
        ok = NO;
        failure = [NSString stringWithFormat:@"Extracted %llu bytes but the IPA lists %llu.", produced, entry->size];
    }
    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
        if (error) {
            *error = cancelled ? zs_bd_error(ZSBinaryDiffErrorCancelled, @"Dump cancelled.")
                               : zs_bd_error(ZSBinaryDiffErrorBadArchive, failure ?: @"Extraction failed.");
        }
        return NO;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    if (sha) *sha = zs_bd_hex(digest, CC_SHA256_DIGEST_LENGTH);
    return YES;
}

static BOOL zs_bd_extract_all(NSString *ipaPath, NSString *temp, BOOL (^isCancelled)(void), void (^emit)(NSString *, double),
                              NSString **frameworkPath, NSString **frameworkSHA, NSString **metadataPath, NSString **metadataSHA,
                              NSString **infoPath, NSError **error) {
    ZSBDMap zip;
    if (!zs_bd_map_open(ipaPath, &zip)) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorIO, @"Could not open the IPA.");
        return NO;
    }
    NSArray<NSString *> *wanted = @[kZSBDFrameworkEntry, kZSBDMetadataEntry, kZSBDInfoEntry];
    ZSBDZipEntry entries[3];
    memset(entries, 0, sizeof entries);
    if (!zs_bd_zip_find(zip, wanted, entries)) {
        zs_bd_map_close(&zip);
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorBadArchive, @"That file is not a readable IPA (zip) archive.");
        return NO;
    }
    for (NSUInteger i = 0; i < 2; i++) {
        if (!entries[i].found) {
            zs_bd_map_close(&zip);
            if (error) *error = zs_bd_error(ZSBinaryDiffErrorMissingEntry, [NSString stringWithFormat:@"The IPA does not contain %@.", wanted[i].lastPathComponent]);
            return NO;
        }
    }

    NSString *frameworkOut = [temp stringByAppendingPathComponent:@"UnityFramework"];
    NSString *metadataOut = [temp stringByAppendingPathComponent:@"global-metadata.dat"];
    NSString *infoOut = [temp stringByAppendingPathComponent:@"Info.plist"];
    NSString *frameworkHash = nil, *metadataHash = nil;
    NSError *extractError = nil;

    emit(@"Extracting UnityFramework", 0.05);
    BOOL ok = zs_bd_zip_extract(zip, &entries[0], frameworkOut, &frameworkHash, isCancelled, ^(double t) {
        emit(@"Extracting UnityFramework", 0.05 + 0.40 * t);
    }, &extractError);
    if (ok) {
        emit(@"Extracting global-metadata.dat", 0.45);
        ok = zs_bd_zip_extract(zip, &entries[1], metadataOut, &metadataHash, isCancelled, ^(double t) {
            emit(@"Extracting global-metadata.dat", 0.45 + 0.10 * t);
        }, &extractError);
    }
    BOOL haveInfo = NO;
    if (ok && entries[2].found && entries[2].size < (1 << 24)) {
        haveInfo = zs_bd_zip_extract(zip, &entries[2], infoOut, NULL, isCancelled, NULL, NULL);
    }
    zs_bd_map_close(&zip);
    if (!ok) {
        if (error) *error = extractError;
        return NO;
    }
    *frameworkPath = frameworkOut;
    *frameworkSHA = frameworkHash;
    *metadataPath = metadataOut;
    *metadataSHA = metadataHash;
    *infoPath = haveInfo ? infoOut : nil;
    return YES;
}

@interface ZSBDDump : NSObject
@property (nonatomic, copy) NSArray<NSString *> *lines;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *facts;
@property (nonatomic, strong) NSMutableArray<NSString *> *factKeys;
- (void)setFact:(NSString *)value forKey:(NSString *)key;
@end

@implementation ZSBDDump
- (instancetype)init {
    if ((self = [super init])) {
        _facts = [NSMutableDictionary dictionary];
        _factKeys = [NSMutableArray array];
        _lines = @[];
    }
    return self;
}
- (void)setFact:(NSString *)value forKey:(NSString *)key {
    if (!self.facts[key]) [self.factKeys addObject:key];
    self.facts[key] = value;
}
@end

static NSComparisonResult zs_bd_compare(NSString *a, NSString *b) {
    return [a compare:b options:NSLiteralSearch];
}

static NSArray<NSString *> *zs_bd_sorted(NSSet<NSString *> *set) {
    return [set.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return zs_bd_compare(a, b);
    }];
}

static NSString *zs_bd_text(const uint8_t *bytes, size_t length) {
    BOOL special = NO;
    for (size_t i = 0; i < length; i++) {
        uint8_t c = bytes[i];
        if (c == '\\' || c == '\n' || c == '\r' || c == '\t') {
            special = YES;
            break;
        }
    }
    NSString *text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
    if (!text) return @"";
    BOOL truncated = text.length > kZSBDMaxLineChars;
    if (truncated) text = [text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:kZSBDMaxLineChars - 1].location];
    if (special) {
        NSMutableString *mutableText = [text mutableCopy];
        [mutableText replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:NSLiteralSearch range:NSMakeRange(0, mutableText.length)];
        [mutableText replaceOccurrencesOfString:@"\n" withString:@"\\n" options:NSLiteralSearch range:NSMakeRange(0, mutableText.length)];
        [mutableText replaceOccurrencesOfString:@"\r" withString:@"\\r" options:NSLiteralSearch range:NSMakeRange(0, mutableText.length)];
        [mutableText replaceOccurrencesOfString:@"\t" withString:@"\\t" options:NSLiteralSearch range:NSMakeRange(0, mutableText.length)];
        text = mutableText;
    }
    if (truncated) text = [text stringByAppendingFormat:@"\u2026[%zu bytes]", length];
    return text;
}

static ZSBDDump *zs_bd_dump_metadata(NSString *path, BOOL (^isCancelled)(void), ZSDumpLog logf, NSString *label) {
    ZSBDMap map;
    if (!zs_bd_map_open(path, &map)) return nil;
    if (map.n < 256 || zs_bd_u32(map.p) != 0xFAB11BAF) {
        zs_bd_map_close(&map);
        return nil;
    }
    uint32_t header[8];
    memcpy(header, map.p, sizeof header);
    uint32_t version = header[1];
    BOOL v38 = version >= 38;
    uint64_t tableOffset = header[2], tableSize = header[3], dataOffset = 0, dataSize = 0, literalCount = 0;
    BOOL literalsValid = NO;
    if (v38) {
        literalCount = header[4];
        dataOffset = header[5];
        dataSize = header[6];
        literalsValid = literalCount > 0 && tableSize / literalCount == 4;
    } else {
        dataOffset = header[4];
        dataSize = header[5];
        literalCount = tableSize / 8;
        literalsValid = literalCount > 0;
    }
    literalsValid = literalsValid && tableOffset + tableSize <= map.n && dataOffset + dataSize <= map.n;

    NSMutableSet<NSString *> *lines = [NSMutableSet set];
    NSUInteger literalLines = 0;
    BOOL cancelled = NO;
    if (literalsValid) {
        for (uint64_t i = 0; i < literalCount && !cancelled; i++) {
            @autoreleasepool {
                uint64_t start = 0, length = 0;
                BOOL entryOK = NO;
                if (v38) {
                    start = zs_bd_u32(map.p + tableOffset + i * 4);
                    uint64_t next = (i + 1 < literalCount) ? zs_bd_u32(map.p + tableOffset + (i + 1) * 4) : dataSize;
                    if (next >= start && next <= dataSize) {
                        length = next - start;
                        entryOK = YES;
                    }
                } else {
                    length = zs_bd_u32(map.p + tableOffset + i * 8);
                    start = zs_bd_u32(map.p + tableOffset + i * 8 + 4);
                    entryOK = start + length <= dataSize;
                }
                if (entryOK) {
                    [lines addObject:[@"literal \"" stringByAppendingString:[zs_bd_text(map.p + dataOffset + start, (size_t)length) stringByAppendingString:@"\""]]];
                    literalLines++;
                }
            }
            if ((i & 0xFFF) == 0 && isCancelled()) cancelled = YES;
        }
    }
    if (cancelled) {
        zs_bd_map_close(&map);
        return nil;
    }

    const size_t block = 4096;
    size_t blockCount = (map.n + block - 1) / block;
    uint8_t *qualifies = calloc(blockCount, 1);
    if (!qualifies) {
        zs_bd_map_close(&map);
        return nil;
    }
    for (size_t b = 0; b < blockCount; b++) {
        size_t start = b * block;
        size_t end = MIN(start + block, map.n);
        size_t length = end - start;
        size_t printable = 0, zeros = 0, other = 0;
        for (size_t j = start; j < end; j++) {
            uint8_t c = map.p[j];
            if (c == 0) zeros++;
            else if (c >= 0x20 && c <= 0x7E) printable++;
            else other++;
        }
        qualifies[b] = length >= 1024 && other * 50 <= length && printable * 10 >= length * 6 && zeros * 100 >= length * 3 && zeros * 100 <= length * 35;
    }

    NSUInteger identifierLines = 0;
    size_t b = 0;
    while (b < blockCount && !cancelled) {
        if (!qualifies[b]) {
            b++;
            continue;
        }
        size_t runStart = b;
        while (b < blockCount && qualifies[b]) b++;
        if (b - runStart < 4) continue;
        size_t lo = (runStart > 0 ? runStart - 1 : 0) * block;
        size_t hi = MIN((b + 1) * block, map.n);
        size_t coreLow = runStart * block;
        size_t coreHigh = MIN(b * block, map.n);
        size_t pos = lo;
        while (pos < hi && map.p[pos] != 0) pos++;
        @autoreleasepool {
            while (pos < hi) {
                while (pos < hi && map.p[pos] == 0) pos++;
                size_t tokenStart = pos;
                while (pos < hi && map.p[pos] != 0) pos++;
                if (pos >= hi) break;
                size_t tokenLength = pos - tokenStart;
                size_t minimumLength = (tokenStart >= coreLow && pos <= coreHigh) ? 2 : 4;
                if (tokenLength < minimumLength || tokenLength > 512) continue;
                if (literalsValid && tokenStart >= dataOffset && tokenStart < dataOffset + dataSize) continue;
                BOOL clean = YES;
                for (size_t k = tokenStart; k < pos; k++) {
                    if (map.p[k] < 0x20 || map.p[k] > 0x7E) {
                        clean = NO;
                        break;
                    }
                }
                if (!clean) continue;
                NSString *token = [[NSString alloc] initWithBytes:map.p + tokenStart length:tokenLength encoding:NSASCIIStringEncoding];
                if (token) {
                    NSUInteger before = lines.count;
                    [lines addObject:[@"ident " stringByAppendingString:token]];
                    if (lines.count > before) identifierLines++;
                }
                if ((pos & 0xFFFFF) < 64 && isCancelled()) {
                    cancelled = YES;
                    break;
                }
            }
        }
    }
    free(qualifies);
    size_t fileSize = map.n;
    zs_bd_map_close(&map);
    if (cancelled) return nil;

    ZSBDDump *dump = [ZSBDDump new];
    dump.lines = zs_bd_sorted(lines);
    [dump setFact:[NSString stringWithFormat:@"%u", version] forKey:@"metadata version"];
    [dump setFact:[NSString stringWithFormat:@"%zu", fileSize] forKey:@"file size"];
    [dump setFact:[NSString stringWithFormat:@"%lu", (unsigned long)literalLines] forKey:@"string literals"];
    [dump setFact:[NSString stringWithFormat:@"%lu", (unsigned long)identifierLines] forKey:@"identifiers"];
    if (logf) {
        logf([NSString stringWithFormat:@"%@ global-metadata.dat: version %u, %lu literals, %lu identifiers%@", label, version,
              (unsigned long)literalLines, (unsigned long)identifierLines, literalsValid ? @"" : @" (literal table not recognised)"]);
    }
    return dump;
}

static ZSBDDump *zs_bd_dump_macho(NSString *path, BOOL (^isCancelled)(void), ZSDumpLog logf, NSString *label) {
    ZSBDMap map;
    if (!zs_bd_map_open(path, &map)) return nil;
    const uint8_t *slice = map.p;
    size_t sliceSize = map.n;
    if (map.n >= 8 && zs_bd_u32(map.p) == FAT_CIGAM) {
        uint32_t archCount = OSSwapBigToHostInt32(zs_bd_u32(map.p + 4));
        BOOL chosen = NO;
        for (uint32_t i = 0; i < archCount && 8 + (size_t)(i + 1) * 20 <= map.n; i++) {
            const uint8_t *arch = map.p + 8 + (size_t)i * 20;
            uint32_t cpu = OSSwapBigToHostInt32(zs_bd_u32(arch));
            uint32_t offset = OSSwapBigToHostInt32(zs_bd_u32(arch + 8));
            uint32_t size = OSSwapBigToHostInt32(zs_bd_u32(arch + 12));
            if ((uint64_t)offset + size > map.n) continue;
            if (!chosen || cpu == CPU_TYPE_ARM64) {
                slice = map.p + offset;
                sliceSize = size;
                chosen = YES;
            }
            if (cpu == CPU_TYPE_ARM64) break;
        }
    }
    if (sliceSize < sizeof(struct mach_header_64) || zs_bd_u32(slice) != MH_MAGIC_64) {
        zs_bd_map_close(&map);
        return nil;
    }
    uint32_t commandCount = zs_bd_u32(slice + 16);
    uint32_t commandsSize = zs_bd_u32(slice + 20);
    if ((uint64_t)sizeof(struct mach_header_64) + commandsSize > sliceSize) {
        zs_bd_map_close(&map);
        return nil;
    }

    ZSBDDump *dump = [ZSBDDump new];
    NSMutableSet<NSString *> *lines = [NSMutableSet set];
    [dump setFact:[NSString stringWithFormat:@"%zu", map.n] forKey:@"file size"];
    uint64_t symbolCount = 0, functionCount = 0;
    BOOL cancelled = NO;
    size_t cursor = sizeof(struct mach_header_64);
    size_t commandsEnd = cursor + commandsSize;

    for (uint32_t c = 0; c < commandCount && cursor + 8 <= commandsEnd && !cancelled; c++) {
        const uint8_t *command = slice + cursor;
        uint32_t type = zs_bd_u32(command);
        uint32_t size = zs_bd_u32(command + 4);
        if (size < 8 || cursor + size > commandsEnd) break;

        if (type == LC_UUID && size >= 24) {
            [dump setFact:[[NSUUID alloc] initWithUUIDBytes:(const unsigned char *)(command + 8)].UUIDString forKey:@"uuid"];
        } else if (type == LC_SEGMENT_64 && size >= 72) {
            char segmentName[17] = {0};
            memcpy(segmentName, command + 8, 16);
            uint64_t vmSize = zs_bd_u64(command + 32);
            uint32_t sectionCount = zs_bd_u32(command + 64);
            [dump setFact:[NSString stringWithFormat:@"%llu", vmSize] forKey:[NSString stringWithFormat:@"segment %s vmsize", segmentName]];
            for (uint32_t s = 0; s < sectionCount && 72 + (size_t)(s + 1) * 80 <= size; s++) {
                const uint8_t *section = command + 72 + (size_t)s * 80;
                char sectionName[17] = {0}, sectionSegment[17] = {0};
                memcpy(sectionName, section, 16);
                memcpy(sectionSegment, section + 16, 16);
                uint64_t sectionSize = zs_bd_u64(section + 40);
                uint32_t sectionOffset = zs_bd_u32(section + 48);
                uint32_t flags = zs_bd_u32(section + 64);
                [dump setFact:[NSString stringWithFormat:@"%llu", sectionSize] forKey:[NSString stringWithFormat:@"section %s,%s size", sectionSegment, sectionName]];
                if ((flags & SECTION_TYPE) != S_CSTRING_LITERALS) continue;
                if (sectionOffset == 0 || (uint64_t)sectionOffset + sectionSize > sliceSize) continue;
                BOOL objc = strncmp(sectionName, "__objc", 6) == 0;
                size_t minimum = objc ? 2 : 4;
                NSString *prefix = objc ? @"objc " : @"string ";
                const uint8_t *bytes = slice + sectionOffset;
                size_t pos = 0, total = (size_t)sectionSize;
                @autoreleasepool {
                    while (pos < total) {
                        size_t start = pos;
                        while (pos < total && bytes[pos] != 0) pos++;
                        size_t length = pos - start;
                        pos++;
                        if (length < minimum || length > 4096) continue;
                        [lines addObject:[prefix stringByAppendingString:zs_bd_text(bytes + start, length)]];
                        if ((pos & 0xFFFFF) < 64 && isCancelled()) {
                            cancelled = YES;
                            break;
                        }
                    }
                }
                if (cancelled) break;
            }
        } else if (type == LC_SYMTAB && size >= 24) {
            uint32_t symbolOffset = zs_bd_u32(command + 8);
            uint32_t symbolTotal = zs_bd_u32(command + 12);
            uint32_t stringOffset = zs_bd_u32(command + 16);
            uint32_t stringSize = zs_bd_u32(command + 20);
            if ((uint64_t)symbolOffset + (uint64_t)symbolTotal * 16 <= sliceSize && (uint64_t)stringOffset + stringSize <= sliceSize) {
                @autoreleasepool {
                    for (uint32_t i = 0; i < symbolTotal; i++) {
                        const uint8_t *entry = slice + symbolOffset + (size_t)i * 16;
                        uint32_t nameIndex = zs_bd_u32(entry);
                        uint8_t nType = entry[4];
                        if ((nType & N_STAB) != 0 || (nType & N_TYPE) != N_SECT || nameIndex == 0 || nameIndex >= stringSize) continue;
                        const char *name = (const char *)(slice + stringOffset + nameIndex);
                        size_t length = strnlen(name, stringSize - nameIndex);
                        if (length == 0 || length > 4096) continue;
                        [lines addObject:[@"symbol " stringByAppendingString:zs_bd_text((const uint8_t *)name, length)]];
                        symbolCount++;
                        if ((i & 0xFFFF) == 0 && isCancelled()) {
                            cancelled = YES;
                            break;
                        }
                    }
                }
            }
        } else if (type == LC_FUNCTION_STARTS && size >= 16) {
            uint32_t dataOffset = zs_bd_u32(command + 8);
            uint32_t dataSize = zs_bd_u32(command + 12);
            if ((uint64_t)dataOffset + dataSize <= sliceSize) {
                const uint8_t *p = slice + dataOffset;
                const uint8_t *e = p + dataSize;
                while (p < e) {
                    uint64_t value = 0;
                    int shift = 0;
                    uint8_t byte;
                    do {
                        byte = *p++;
                        if (shift < 64) value |= (uint64_t)(byte & 0x7F) << shift;
                        shift += 7;
                    } while ((byte & 0x80) && p < e);
                    if (value == 0) break;
                    functionCount++;
                }
            }
        }
        cursor += size;
    }
    zs_bd_map_close(&map);
    if (cancelled) return nil;

    [dump setFact:[NSString stringWithFormat:@"%llu", symbolCount] forKey:@"defined symbols"];
    [dump setFact:[NSString stringWithFormat:@"%llu", functionCount] forKey:@"function starts"];
    dump.lines = zs_bd_sorted(lines);
    if (logf) {
        logf([NSString stringWithFormat:@"%@ UnityFramework: %lu strings and symbols, %llu function starts", label, (unsigned long)dump.lines.count, functionCount]);
    }
    return dump;
}

static void zs_bd_merge_diff(NSArray<NSString *> *baseline, NSArray<NSString *> *target, NSMutableArray<NSString *> *added, NSMutableArray<NSString *> *removed, BOOL (^isCancelled)(void)) {
    NSUInteger i = 0, j = 0;
    NSUInteger bn = baseline.count, tn = target.count;
    NSUInteger step = 0;
    while (i < bn || j < tn) {
        if ((++step & 0xFFFF) == 0 && isCancelled()) return;
        if (i >= bn) {
            [added addObject:target[j++]];
        } else if (j >= tn) {
            [removed addObject:baseline[i++]];
        } else {
            NSComparisonResult order = zs_bd_compare(baseline[i], target[j]);
            if (order == NSOrderedSame) {
                i++;
                j++;
            } else if (order == NSOrderedAscending) {
                [removed addObject:baseline[i++]];
            } else {
                [added addObject:target[j++]];
            }
        }
    }
}

static NSString *zs_bd_kind(NSString *line) {
    NSRange space = [line rangeOfString:@" "];
    return space.location == NSNotFound ? @"other" : [line substringToIndex:space.location];
}

static NSString *zs_bd_body(NSString *line) {
    NSRange space = [line rangeOfString:@" "];
    return space.location == NSNotFound ? line : [line substringFromIndex:space.location + 1];
}

static NSDictionary<NSString *, NSNumber *> *zs_bd_kind_counts(NSArray<NSString *> *lines) {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSString *line in lines) {
        NSString *kind = zs_bd_kind(line);
        counts[kind] = @(counts[kind].unsignedIntegerValue + 1);
    }
    return counts;
}

static void zs_bd_put(FILE *file, NSString *text) {
    const char *utf8 = text.UTF8String;
    if (utf8) fputs(utf8, file);
}

static void zs_bd_putf(FILE *file, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static void zs_bd_putf(FILE *file, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    zs_bd_put(file, text);
}

static BOOL zs_bd_write_dump(NSString *path, ZSBDDump *dump) {
    FILE *file = fopen(path.fileSystemRepresentation, "w");
    if (!file) return NO;
    for (NSString *key in dump.factKeys) zs_bd_putf(file, @"# %@: %@\n", key, dump.facts[key]);
    for (NSString *line in dump.lines) {
        zs_bd_put(file, line);
        fputc('\n', file);
    }
    return fclose(file) == 0;
}

@interface ZSBDResult : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *baselineSHA;
@property (nonatomic, copy) NSString *targetSHA;
@property (nonatomic, assign) BOOL identical;
@property (nonatomic, strong) ZSBDDump *baselineDump;
@property (nonatomic, strong) ZSBDDump *targetDump;
@property (nonatomic, copy) NSArray<NSString *> *added;
@property (nonatomic, copy) NSArray<NSString *> *removed;
@end

@implementation ZSBDResult
@end

static void zs_bd_write_group(FILE *file, NSString *fileName, NSArray<NSString *> *lines, NSString *sign) {
    if (lines.count == 0) return;
    NSDictionary<NSString *, NSNumber *> *counts = zs_bd_kind_counts(lines);
    NSString *currentKind = nil;
    for (NSString *line in lines) {
        NSString *kind = zs_bd_kind(line);
        if (![kind isEqualToString:currentKind]) {
            zs_bd_putf(file, @"\n--- %@ / %@ (%lu) ---\n", fileName, kind, (unsigned long)counts[kind].unsignedIntegerValue);
            currentKind = kind;
        }
        zs_bd_putf(file, @"%@ %@\n", sign, zs_bd_body(line));
    }
}

static NSString *zs_bd_version_string(NSDictionary *info) {
    NSString *shortVersion = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : nil;
    NSString *build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : nil;
    if (shortVersion && build) return [NSString stringWithFormat:@"%@ (%@)", shortVersion, build];
    return shortVersion ?: build ?: @"unknown version";
}

@implementation ZSBinaryDiff

+ (NSURL *)diffIPAAtURL:(NSURL *)ipaURL
     installedFramework:(NSString *)installedFramework
      installedMetadata:(NSString *)installedMetadata
             outputRoot:(NSString *)outputRoot
               progress:(ZSDumpProgress)progress
                    log:(ZSDumpLog)logf
              cancelled:(BOOL (^)(void))cancelled
                summary:(NSDictionary **)summary
                  error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (installedFramework.length == 0 || ![fm fileExistsAtPath:installedFramework]) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorInvalidInput, @"The installed UnityFramework could not be located.");
        return nil;
    }
    if (installedMetadata.length == 0 || ![fm fileExistsAtPath:installedMetadata]) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorInvalidInput, @"The installed global-metadata.dat could not be located.");
        return nil;
    }
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSBinaryDiff-%@", NSUUID.UUID.UUIDString]];
    NSError *tempError = nil;
    if (![fm createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:&tempError]) {
        if (error) *error = tempError ?: zs_bd_error(ZSBinaryDiffErrorIO, @"Could not create a temporary folder.");
        return nil;
    }
    NSString *outputFolder = nil;
    NSURL *result = [self runWithIPAPath:ipaURL.path
                      installedFramework:installedFramework
                       installedMetadata:installedMetadata
                              outputRoot:outputRoot
                                    temp:temp
                            outputFolder:&outputFolder
                                progress:progress
                                     log:logf
                               cancelled:cancelled
                                 summary:summary
                                   error:error];
    [fm removeItemAtPath:temp error:nil];
    if (!result && outputFolder) [fm removeItemAtPath:outputFolder error:nil];
    return result;
}

+ (NSURL *)runWithIPAPath:(NSString *)ipaPath
       installedFramework:(NSString *)installedFramework
        installedMetadata:(NSString *)installedMetadata
               outputRoot:(NSString *)outputRoot
                     temp:(NSString *)temp
             outputFolder:(NSString **)outputFolderOut
                 progress:(ZSDumpProgress)progress
                      log:(ZSDumpLog)logf
                cancelled:(BOOL (^)(void))cancelledBlock
                  summary:(NSDictionary **)summary
                    error:(NSError **)error {
    BOOL (^isCancelled)(void) = cancelledBlock ?: ^BOOL{ return NO; };
    void (^emit)(NSString *, double) = ^(NSString *stage, double fraction) {
        if (progress) progress(stage, fraction);
    };
    void (^say)(NSString *) = ^(NSString *line) {
        if (logf) logf(line);
    };
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *stepError = nil;

    emit(@"Reading IPA", 0);
    NSString *ipaFramework = nil, *ipaFrameworkSHA = nil, *ipaMetadata = nil, *ipaMetadataSHA = nil, *ipaInfo = nil;
    if (!zs_bd_extract_all(ipaPath, temp, isCancelled, emit, &ipaFramework, &ipaFrameworkSHA, &ipaMetadata, &ipaMetadataSHA, &ipaInfo, &stepError)) {
        if (error) *error = stepError;
        return nil;
    }
    say([NSString stringWithFormat:@"IPA UnityFramework sha256 %@", ipaFrameworkSHA]);
    say([NSString stringWithFormat:@"IPA global-metadata.dat sha256 %@", ipaMetadataSHA]);

    emit(@"Hashing installed UnityFramework", 0.55);
    NSString *installedFrameworkSHA = zs_bd_sha256_file(installedFramework, isCancelled);
    if (!installedFrameworkSHA) {
        if (error) *error = isCancelled() ? zs_bd_error(ZSBinaryDiffErrorCancelled, @"Dump cancelled.") : zs_bd_error(ZSBinaryDiffErrorIO, @"Could not read the installed UnityFramework.");
        return nil;
    }
    emit(@"Hashing installed global-metadata.dat", 0.60);
    NSString *installedMetadataSHA = zs_bd_sha256_file(installedMetadata, isCancelled);
    if (!installedMetadataSHA) {
        if (error) *error = isCancelled() ? zs_bd_error(ZSBinaryDiffErrorCancelled, @"Dump cancelled.") : zs_bd_error(ZSBinaryDiffErrorIO, @"Could not read the installed global-metadata.dat.");
        return nil;
    }
    say([NSString stringWithFormat:@"Installed UnityFramework sha256 %@", installedFrameworkSHA]);
    say([NSString stringWithFormat:@"Installed global-metadata.dat sha256 %@", installedMetadataSHA]);

    BOOL frameworkSame = [ipaFrameworkSHA isEqualToString:installedFrameworkSHA];
    BOOL metadataSame = [ipaMetadataSHA isEqualToString:installedMetadataSHA];
    if (frameworkSame && metadataSame) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorIdentical, @"The IPA's UnityFramework and global-metadata.dat are byte-identical to the installed game's (matching sha256). There is nothing to diff.");
        return nil;
    }

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *folder = [outputRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSingularity-BinaryDiff-%@", [formatter stringFromDate:[NSDate date]]]];
    NSString *baselineFolder = [folder stringByAppendingPathComponent:@"ipa"];
    NSString *targetFolder = [folder stringByAppendingPathComponent:@"installed"];
    if (![fm createDirectoryAtPath:baselineFolder withIntermediateDirectories:YES attributes:nil error:&stepError] ||
        ![fm createDirectoryAtPath:targetFolder withIntermediateDirectories:YES attributes:nil error:&stepError]) {
        *outputFolderOut = folder;
        if (error) *error = stepError ?: zs_bd_error(ZSBinaryDiffErrorIO, @"Could not create the output folder.");
        return nil;
    }
    *outputFolderOut = folder;

    NSMutableArray<ZSBDResult *> *results = [NSMutableArray array];
    NSArray<NSDictionary *> *jobs = @[
        @{@"name": @"UnityFramework", @"macho": @YES, @"same": @(frameworkSame), @"ipaPath": ipaFramework, @"installedPath": installedFramework,
          @"ipaSHA": ipaFrameworkSHA, @"installedSHA": installedFrameworkSHA, @"start": @0.65, @"span": @0.15},
        @{@"name": @"global-metadata.dat", @"macho": @NO, @"same": @(metadataSame), @"ipaPath": ipaMetadata, @"installedPath": installedMetadata,
          @"ipaSHA": ipaMetadataSHA, @"installedSHA": installedMetadataSHA, @"start": @0.80, @"span": @0.12}
    ];
    for (NSDictionary *job in jobs) {
        ZSBDResult *entry = [ZSBDResult new];
        entry.name = job[@"name"];
        entry.baselineSHA = job[@"ipaSHA"];
        entry.targetSHA = job[@"installedSHA"];
        entry.identical = [job[@"same"] boolValue];
        entry.added = @[];
        entry.removed = @[];
        [results addObject:entry];
        if (entry.identical) {
            say([NSString stringWithFormat:@"%@ is identical (sha256 match), skipping", entry.name]);
            continue;
        }
        BOOL macho = [job[@"macho"] boolValue];
        double start = [job[@"start"] doubleValue], span = [job[@"span"] doubleValue];
        NSString *dumpName = [entry.name stringByAppendingString:@".txt"];
        @autoreleasepool {
            emit([NSString stringWithFormat:@"Dumping IPA %@", entry.name], start);
            ZSBDDump *baseline = macho ? zs_bd_dump_macho(job[@"ipaPath"], isCancelled, logf, @"IPA") : zs_bd_dump_metadata(job[@"ipaPath"], isCancelled, logf, @"IPA");
            if (!baseline) {
                if (error) *error = isCancelled() ? zs_bd_error(ZSBinaryDiffErrorCancelled, @"Dump cancelled.") : zs_bd_error(ZSBinaryDiffErrorBadBinary, [NSString stringWithFormat:@"The IPA's %@ could not be parsed.", entry.name]);
                return nil;
            }
            emit([NSString stringWithFormat:@"Dumping installed %@", entry.name], start + span * 0.5);
            ZSBDDump *target = macho ? zs_bd_dump_macho(job[@"installedPath"], isCancelled, logf, @"Installed") : zs_bd_dump_metadata(job[@"installedPath"], isCancelled, logf, @"Installed");
            if (!target) {
                if (error) *error = isCancelled() ? zs_bd_error(ZSBinaryDiffErrorCancelled, @"Dump cancelled.") : zs_bd_error(ZSBinaryDiffErrorBadBinary, [NSString stringWithFormat:@"The installed %@ could not be parsed.", entry.name]);
                return nil;
            }
            if (!zs_bd_write_dump([baselineFolder stringByAppendingPathComponent:dumpName], baseline) ||
                !zs_bd_write_dump([targetFolder stringByAppendingPathComponent:dumpName], target)) {
                if (error) *error = zs_bd_error(ZSBinaryDiffErrorIO, @"Writing a dump file failed.");
                return nil;
            }
            emit([NSString stringWithFormat:@"Diffing %@", entry.name], start + span);
            NSMutableArray<NSString *> *added = [NSMutableArray array];
            NSMutableArray<NSString *> *removed = [NSMutableArray array];
            zs_bd_merge_diff(baseline.lines, target.lines, added, removed, isCancelled);
            if (isCancelled()) {
                if (error) *error = zs_bd_error(ZSBinaryDiffErrorCancelled, @"Dump cancelled.");
                return nil;
            }
            entry.added = added;
            entry.removed = removed;
            baseline.lines = @[];
            target.lines = @[];
            entry.baselineDump = baseline;
            entry.targetDump = target;
            say([NSString stringWithFormat:@"%@: +%lu added, -%lu removed", entry.name, (unsigned long)added.count, (unsigned long)removed.count]);
        }
    }

    emit(@"Writing report", 0.95);
    NSDictionary *installedInfo = NSBundle.mainBundle.infoDictionary ?: @{};
    NSDictionary *ipaInfoDictionary = ipaInfo ? ([NSDictionary dictionaryWithContentsOfFile:ipaInfo] ?: @{}) : @{};
    NSString *reportPath = [folder stringByAppendingPathComponent:@"diff.txt"];
    FILE *file = fopen(reportPath.fileSystemRepresentation, "w");
    if (!file) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorIO, @"Could not create diff.txt.");
        return nil;
    }
    zs_bd_putf(file, @"ZSingularity binary diff\n");
    zs_bd_putf(file, @"generated  %@\n\n", [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]);
    zs_bd_putf(file, @"baseline   IPA        %@  %@\n", ipaPath.lastPathComponent, zs_bd_version_string(ipaInfoDictionary));
    zs_bd_putf(file, @"target     installed  %@  %@\n\n", NSBundle.mainBundle.bundleIdentifier ?: @"unknown bundle", zs_bd_version_string(installedInfo));
    zs_bd_putf(file, @"added   = present in the installed game, not in the IPA\n");
    zs_bd_putf(file, @"removed = present in the IPA, not in the installed game\n\n");

    zs_bd_putf(file, @"==================== FILES ====================\n");
    for (ZSBDResult *entry in results) {
        zs_bd_putf(file, @"\n%@\n  ipa        sha256 %@\n  installed  sha256 %@\n  result     %@\n", entry.name, entry.baselineSHA, entry.targetSHA, entry.identical ? @"identical, not diffed" : @"different");
    }

    zs_bd_putf(file, @"\n==================== SUMMARY ====================\n");
    for (ZSBDResult *entry in results) {
        if (entry.identical) {
            zs_bd_putf(file, @"\n%@: unchanged\n", entry.name);
            continue;
        }
        zs_bd_putf(file, @"\n%@: +%lu added, -%lu removed\n", entry.name, (unsigned long)entry.added.count, (unsigned long)entry.removed.count);
        NSDictionary<NSString *, NSNumber *> *addedCounts = zs_bd_kind_counts(entry.added);
        NSDictionary<NSString *, NSNumber *> *removedCounts = zs_bd_kind_counts(entry.removed);
        NSMutableSet<NSString *> *kinds = [NSMutableSet setWithArray:addedCounts.allKeys];
        [kinds addObjectsFromArray:removedCounts.allKeys];
        for (NSString *kind in [kinds.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
            zs_bd_putf(file, @"  %@  +%lu  -%lu\n", kind, (unsigned long)addedCounts[kind].unsignedIntegerValue, (unsigned long)removedCounts[kind].unsignedIntegerValue);
        }
        NSMutableArray<NSString *> *keys = [entry.baselineDump.factKeys mutableCopy];
        for (NSString *key in entry.targetDump.factKeys) if (![keys containsObject:key]) [keys addObject:key];
        for (NSString *key in keys) {
            NSString *a = entry.baselineDump.facts[key] ?: @"-";
            NSString *b = entry.targetDump.facts[key] ?: @"-";
            if ([a isEqualToString:b]) zs_bd_putf(file, @"  %@: %@\n", key, a);
            else zs_bd_putf(file, @"  %@: %@ -> %@  (changed)\n", key, a, b);
        }
    }

    zs_bd_putf(file, @"\n\n==================== ADDED ====================\n");
    for (ZSBDResult *entry in results) zs_bd_write_group(file, entry.name, entry.added, @"+");
    zs_bd_putf(file, @"\n\n==================== REMOVED ====================\n");
    for (ZSBDResult *entry in results) zs_bd_write_group(file, entry.name, entry.removed, @"-");
    BOOL closed = fclose(file) == 0;
    if (!closed) {
        if (error) *error = zs_bd_error(ZSBinaryDiffErrorIO, @"Writing diff.txt failed.");
        return nil;
    }

    NSMutableDictionary *summaryDictionary = [NSMutableDictionary dictionary];
    NSArray<NSString *> *summaryKeys = @[@"unityFramework", @"globalMetadata"];
    for (NSUInteger i = 0; i < results.count && i < summaryKeys.count; i++) {
        ZSBDResult *entry = results[i];
        summaryDictionary[summaryKeys[i]] = @{@"changed": @(!entry.identical),
                                              @"added": @(entry.added.count),
                                              @"removed": @(entry.removed.count)};
    }
    if (summary) *summary = summaryDictionary;
    emit(@"Complete", 1.0);
    return [NSURL fileURLWithPath:folder isDirectory:YES];
}

@end
