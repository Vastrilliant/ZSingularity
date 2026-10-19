#import "ScriptDump.h"
#import "ScriptCore.h"
#import "DumperScripts.h"
#import "ZTweakLog.h"

@interface ZSHookBox : NSObject
@property (nonatomic, copy) ZSDumpProgress progress;
@property (nonatomic, copy) ZSDumpLog log;
@property (nonatomic, copy) BOOL (^cancelled)(void);
@end

@implementation ZSHookBox
@end

static void zs_hook_progress(void *ud, const char *stage, double fraction) {
    ZSHookBox *box = (__bridge ZSHookBox *)ud;
    if (box.progress) box.progress([NSString stringWithUTF8String:stage], fraction);
}

static void zs_hook_log(void *ud, const char *line) {
    ZSHookBox *box = (__bridge ZSHookBox *)ud;
    NSString *s = [NSString stringWithUTF8String:line] ?: @"";
    ZLog(@"[ZSDumper] %@", s);
    if (box.log) box.log(s);
}

static bool zs_hook_cancelled(void *ud) {
    ZSHookBox *box = (__bridge ZSHookBox *)ud;
    return box.cancelled ? box.cancelled() : false;
}

static NSError *zs_script_error(NSString *message) {
    return [NSError errorWithDomain:@"ZSDumper" code:20 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation ZSScriptDump

+ (NSUInteger)exportScriptsIntoFolder:(NSString *)folder error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [folder stringByAppendingPathComponent:@"Scripts"];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) return 0;
    NSUInteger written = 0;
    for (unsigned long i = 0; i < kZSDumperAssetCount; i++) {
        const ZSDumperAsset *asset = &kZSDumperAssets[i];
        NSData *data = [NSData dataWithBytes:asset->bytes length:asset->length];
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:asset->name]];
        if ([data writeToFile:path options:NSDataWritingAtomic error:error]) written++;
        else return written;
    }
    return written;
}

+ (NSDictionary *)generateIntoFolder:(NSString *)folder
                             options:(ZSDumpOptions *)options
                            progress:(ZSDumpProgress)progress
                                 log:(ZSDumpLog)log
                           cancelled:(BOOL (^)(void))cancelled
                               error:(NSError **)error {
    ZSHookBox *box = [ZSHookBox new];
    box.progress = progress;
    box.log = log;
    box.cancelled = cancelled;
    ZHooks hooks = {(__bridge void *)box, zs_hook_progress, zs_hook_log, zs_hook_cancelled};

    ZC ctx;
    memset(&ctx, 0, sizeof ctx);
    if (!za_resolve(&ctx.a)) {
        if (error) *error = zs_script_error(@"The IL2CPP runtime is missing reflection exports needed for script generation.");
        return nil;
    }
    Dl_info info = {0};
    if (dladdr((const void *)ctx.a.domain_get, &info) == 0 || !info.dli_fbase) {
        if (error) *error = zs_script_error(@"Could not locate the module that contains the IL2CPP runtime.");
        return nil;
    }
    ZImg img;
    if (!zi_load(&img, info.dli_fbase)) {
        if (error) *error = zs_script_error(@"The IL2CPP module is not a readable 64-bit Mach-O image.");
        return nil;
    }
    ctx.img = &img;
    bool haveFile = info.dli_fname && zi_file_open(&img, info.dli_fname);
    zh_log(&hooks, haveFile ? "binary on disk: %s" : "binary on disk could not be opened: %s", info.dli_fname ?: "?");

    ZMeta meta;
    memset(&meta, 0, sizeof meta);
    void *metaMap = NULL;
    size_t metaSize = 0;
    NSString *metaPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Data/Managed/Metadata/global-metadata.dat"];
    bool metaOk = zm_open(&meta, metaPath.fileSystemRepresentation, &metaMap, &metaSize);
    if (metaOk) zh_log(&hooks, "global-metadata.dat version %u, %u string literals", meta.version, zm_string_count(&meta));
    else zh_log(&hooks, "global-metadata.dat missing or not a standard metadata file");

    if (!zs_enumerate(&ctx, &hooks)) {
        zc_release(&ctx);
        if (haveFile) zi_file_close(&img);
        if (metaMap) munmap(metaMap, metaSize);
        if (error) *error = zs_script_error(@"Enumerating IL2CPP classes failed or was cancelled.");
        return nil;
    }
    zh_log(&hooks, "classes %u, methods %u", ctx.td, ctx.defCount);

    ZFlags flags;
    flags.scriptMethods = options.scriptMethods;
    flags.genericMethods = options.genericMethods;
    flags.metadataUsages = options.metadataUsages;
    flags.addresses = options.addresses;
    flags.stringLiterals = options.stringLiterals;
    flags.minify = options.minifyJSON;

    NSString *scriptPath = [folder stringByAppendingPathComponent:@"script.json"];
    NSString *stringPath = [folder stringByAppendingPathComponent:@"stringliteral.json"];
    ZStats stats;
    bool ok = zs_generate(&ctx, &meta, metaOk, scriptPath.fileSystemRepresentation, stringPath.fileSystemRepresentation, &flags, &hooks, &stats);

    zc_release(&ctx);
    if (haveFile) zi_file_close(&img);
    if (metaMap) munmap(metaMap, metaSize);

    if (!ok) {
        if (error) *error = zs_script_error(@"Script generation was cancelled or failed while writing.");
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"methods"] = @(stats.methods);
    result[@"genericMethods"] = @(stats.genericMethods);
    result[@"strings"] = @(stats.strings);
    result[@"metadata"] = @(stats.metadata);
    result[@"metadataMethods"] = @(stats.metadataMethods);
    result[@"addresses"] = @(stats.addresses);
    result[@"registrationFound"] = @(stats.registrationFound);
    result[@"codeRegistrationFound"] = @(stats.codeRegistrationFound);
    result[@"usagesFound"] = @(stats.usagesFound);
    result[@"metadataVersion"] = @(metaOk ? meta.version : 0);
    return result;
}

@end
