#import "ZSInfoPlistPatch.h"
#import "ZTweakLog.h"

static BOOL g_zsInfoPlistNeedsRestartPrompt = NO;

static NSDictionary<NSString *, id> *zs_info_plist_launch_flags(void) {
    return @{
        @"CADisableMinimumFrameDuration": @YES,
        @"CADisableMinimumFrameDurationOnPhone": @YES,
        @"LSSupportsGameMode": @YES,
        @"UIFileSharingEnabled": @YES,
        @"LSSupportsOpeningDocumentsInPlace": @YES,
    };
}

static NSDictionary<NSString *, NSArray<NSString *> *> *zs_info_plist_stale_array_entries(void) {
    return @{
        @"UIBackgroundModes": @[@"audio"],
    };
}

void zs_patch_info_plist_launch_flags(void) {
    NSString *path = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!plist) {
        ZLog(@"[ZSInfoPlistPatch] couldn't read Info.plist at %@", path);
        return;
    }

    NSDictionary<NSString *, id> *flags = zs_info_plist_launch_flags();
    NSDictionary<NSString *, NSArray<NSString *> *> *staleEntries = zs_info_plist_stale_array_entries();
    BOOL needsWrite = NO;
    for (NSString *key in flags) {
        if ([flags[key] isKindOfClass:[NSArray class]]) {
            NSArray *existing = [plist[key] isKindOfClass:[NSArray class]] ? plist[key] : @[];
            NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:existing];
            [merged addObjectsFromArray:flags[key]];
            NSArray *stale = staleEntries[key];
            if (stale.count) [merged removeObjectsInArray:stale];
            if (![merged.array isEqual:existing]) {
                plist[key] = merged.array;
                needsWrite = YES;
            }
            continue;
        }
        if (![plist[key] isEqual:flags[key]]) {
            plist[key] = flags[key];
            needsWrite = YES;
        }
    }
    if (!needsWrite) return;

    if ([plist writeToFile:path atomically:YES]) {
        ZLog(@"[ZSInfoPlistPatch] patched %@", [flags.allKeys componentsJoinedByString:@", "]);
        g_zsInfoPlistNeedsRestartPrompt = YES;
    } else {
        ZLog(@"[ZSInfoPlistPatch] failed to write Info.plist at %@", path);
    }
}

BOOL zs_info_plist_needs_restart_prompt(void) {
    return g_zsInfoPlistNeedsRestartPrompt;
}

__attribute__((constructor))
static void zs_info_plist_patch_init(void) {
    zs_patch_info_plist_launch_flags();
}
