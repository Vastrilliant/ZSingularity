#import "PatchManifestNetwork.h"
#import "ZTweakLog.h"
#import "Engine.h"
#import "Mods.h"

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <pthread.h>

static NSString * const kTargetHostSuffix = @"limbuscompanycdn.org";

static NSArray<NSString *> *PMTargetPathSuffixes(void) {
    static NSArray<NSString *> *suffixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suffixes = @[@"FmodPatchInfo.json", @"LocalizePatchInfo.json"];
    });
    return suffixes;
}

static const NSUInteger kMaxManifestBytes = 32ULL * 1024ULL * 1024ULL;

static IMP gOrigDidReceiveData;
static IMP gOrigDidComplete;
static Class gDelegateClass;
static BOOL gInstalled;

static NSMutableDictionary<NSNumber *, NSMutableData *> *gBuffers;
static dispatch_queue_t gStateQueue;
static NSMutableSet<NSString *> *gHandledSuffixes;
static dispatch_source_t gRearmTimer;

static NSString * const kSettingsSection = @"network";
static NSString * const kZeroingEnabledKey = @"fmodManifestZeroingEnabled";
static NSString * const kFullZeroingEnabledKey = @"fullManifestZeroingEnabled";

static NSString *PMMatchedSuffixForTask(NSURLSessionTask *task) {
    NSURL *url = task.currentRequest.URL ?: task.originalRequest.URL;
    if (!url) return nil;

    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path ?: @"";
    if (![host hasSuffix:kTargetHostSuffix]) return nil;

    for (NSString *suffix in PMTargetPathSuffixes()) {
        if ([path hasSuffix:suffix]) return suffix;
    }
    return nil;
}

static BOOL PMReadSceneState(int32_t *outState) {
    int32_t sceneState = -1;
    if (!ZSGlobalScene_Current(&sceneState)) return NO;
    *outState = sceneState;
    return YES;
}

static BOOL PMIsOnLoginScene(void) {
    int32_t sceneState = -1;
    return PMReadSceneState(&sceneState) && sceneState == ZSGlobalSceneStateLogin;
}

static BOOL PMIsSuffixHandled(NSString *suffix) {
    __block BOOL handled = NO;
    dispatch_sync(gStateQueue, ^{
        handled = [gHandledSuffixes containsObject:suffix];
    });
    return handled;
}

static void PMMarkSuffixHandled(NSString *suffix) {
    dispatch_sync(gStateQueue, ^{
        [gHandledSuffixes addObject:suffix];
    });
}

static void PMRearmIfLeftLogin(void) {
    if (!gStateQueue) return;
    int32_t sceneState = -1;
    if (!PMReadSceneState(&sceneState) || sceneState == ZSGlobalSceneStateLogin) return;
    dispatch_sync(gStateQueue, ^{
        if (gHandledSuffixes.count == 0) return;
        [gHandledSuffixes removeAllObjects];
        ZLog(@"[PatchManifestNetwork] left the login scene (state=%d) - re-armed for the next login", sceneState);
    });
}

static void PMStartRearmTimer(void) {
    if (gRearmTimer) return;
    gRearmTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gRearmTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC,
                              NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(gRearmTimer, ^{
        PMRearmIfLeftLogin();
    });
    dispatch_resume(gRearmTimer);
}

static void PMStopRearmTimer(void) {
    if (!gRearmTimer) return;
    dispatch_source_cancel(gRearmTimer);
    gRearmTimer = nil;
}

static NSString *PMNormalizedPath(NSString *path) {
    NSString *normalized = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    while ([normalized hasPrefix:@"/"] || [normalized hasPrefix:@"./"]) {
        normalized = [normalized hasPrefix:@"./"] ? [normalized substringFromIndex:2] : [normalized substringFromIndex:1];
    }
    return normalized.lowercaseString;
}

static NSSet<NSString *> *PMReplacedAssetPaths(void) {
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    for (NSString *path in [BankTransplant documentsRelativePathsOfSwappedBanks]) {
        [paths addObject:PMNormalizedPath(path)];
    }
    for (NSString *path in [LocalizationTransplant documentsRelativePathsOfSwappedFiles]) {
        [paths addObject:PMNormalizedPath(path)];
    }
    return paths;
}

static BOOL PMPathHasComponentSuffix(NSString *path, NSString *suffix) {
    if (suffix.length == 0 || path.length < suffix.length) return NO;
    if (![path hasSuffix:suffix]) return NO;
    if (path.length == suffix.length) return YES;
    return [path characterAtIndex:path.length - suffix.length - 1] == '/';
}

static BOOL PMKeyMatchesReplacedPath(NSString *key, NSSet<NSString *> *replaced, NSSet<NSString *> *replacedNames) {
    NSString *normalizedKey = PMNormalizedPath(key);
    if ([replaced containsObject:normalizedKey]) return YES;

    for (NSString *path in replaced) {
        if (PMPathHasComponentSuffix(normalizedKey, path)) return YES;
        if (PMPathHasComponentSuffix(path, normalizedKey)) return YES;
    }

    NSString *name = normalizedKey.lastPathComponent;
    return name.length > 0 && [replacedNames containsObject:name];
}

static BOOL PMEntryIsZero(NSDictionary *entry) {
    id hash = entry[@"Hash"];
    BOOL hashZero = [hash isEqual:@"0"] || [hash isEqual:@0];
    id size = entry[@"Size"];
    BOOL sizeZero = [size respondsToSelector:@selector(unsignedLongLongValue)] && [size unsignedLongLongValue] == 0;
    return hashZero && sizeZero;
}

static NSData *PMPatchManifestData(NSData *input) {
    if (input.length == 0 || input.length > kMaxManifestBytes) {
        return input;
    }

    BOOL fullZeroing = [PatchManifestNetwork isFullZeroingEnabled];
    if (!fullZeroing && ![PatchManifestNetwork isZeroAllEnabled]) {
        return input;
    }

    NSSet<NSString *> *replacedPaths = nil;
    NSMutableSet<NSString *> *replacedNames = nil;
    if (!fullZeroing) {
        replacedPaths = PMReplacedAssetPaths();
        if (replacedPaths.count == 0) {
            ZLog(@"[PatchManifestNetwork] no replaced assets - leaving manifest untouched");
            return input;
        }
        replacedNames = [NSMutableSet set];
        for (NSString *path in replacedPaths) {
            NSString *name = path.lastPathComponent;
            if (name.length > 0) [replacedNames addObject:name];
        }
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:input
                                               options:NSJSONReadingMutableContainers
                                                 error:&jsonError];
    if (![root isKindOfClass:[NSMutableDictionary class]]) {
        ZLog(@"[PatchManifestNetwork] target response wasn't JSON: %@", jsonError);
        return input;
    }

    NSMutableDictionary *manifest = (NSMutableDictionary *)root;
    NSMutableDictionary *files = manifest[@"Files"];
    if (![files isKindOfClass:[NSMutableDictionary class]]) {
        ZLog(@"[PatchManifestNetwork] manifest has no Files dictionary (top-level keys: %@)", manifest.allKeys);
        return input;
    }

    NSUInteger patchedCount = 0;
    NSUInteger matchedCount = 0;
    for (NSString *key in files.allKeys) {
        if (!fullZeroing && !PMKeyMatchesReplacedPath(key, replacedPaths, replacedNames)) continue;

        NSMutableDictionary *entry = files[key];
        if (![entry isKindOfClass:[NSMutableDictionary class]]) continue;
        matchedCount++;

        if (PMEntryIsZero(entry)) continue;

        entry[@"Hash"] = @"0";
        entry[@"Size"] = @0;
        patchedCount++;
    }

    if (!fullZeroing && matchedCount == 0) {
        NSArray<NSString *> *allKeys = files.allKeys;
        NSArray<NSString *> *sampleKeys = [allKeys subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)5, allKeys.count))];
        ZLog(@"[PatchManifestNetwork] none of the %lu replaced assets matched a Files key (%lu keys). replaced=%@ sampleKeys=%@",
              (unsigned long)replacedPaths.count, (unsigned long)allKeys.count, replacedPaths.allObjects, sampleKeys);
        return input;
    }

    if (patchedCount == 0) {
        return input;
    }

    NSError *encodeError = nil;
    NSData *output = [NSJSONSerialization dataWithJSONObject:manifest
                                                       options:0
                                                         error:&encodeError];
    if (!output) {
        ZLog(@"[PatchManifestNetwork] JSON serialization failed: %@", encodeError);
        return input;
    }

    ZLog(@"[PatchManifestNetwork] zeroed Hash/Size on %lu %@ Files entries",
          (unsigned long)patchedCount, fullZeroing ? @"(full zeroing)" : @"replaced");

    return output;
}

static void PMDidReceiveData(id self,
                             SEL _cmd,
                             NSURLSession *session,
                             NSURLSessionDataTask *task,
                             NSData *data) {
    NSString *suffix = PMMatchedSuffixForTask(task);
    if (!suffix) {
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))gOrigDidReceiveData)(
            self, _cmd, session, task, data);
        return;
    }

    NSNumber *key = @(task.taskIdentifier);
    __block BOOL alreadyTracking = NO;
    dispatch_sync(gStateQueue, ^{
        alreadyTracking = gBuffers[key] != nil;
    });

    if (!alreadyTracking) {
        int32_t sceneState = -1;
        BOOL known = PMReadSceneState(&sceneState);
        if (!known || sceneState != ZSGlobalSceneStateLogin) {
            ZLog(@"[PatchManifestNetwork] %@ requested outside the login scene (state=%d known=%d) - passing through untouched",
                  suffix, sceneState, known);
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))gOrigDidReceiveData)(
                self, _cmd, session, task, data);
            return;
        }
        if (PMIsSuffixHandled(suffix)) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))gOrigDidReceiveData)(
                self, _cmd, session, task, data);
            return;
        }
    }

    dispatch_sync(gStateQueue, ^{
        NSMutableData *buffer = gBuffers[key];
        if (!buffer) {
            buffer = [NSMutableData data];
            gBuffers[key] = buffer;
        }

        if (buffer.length <= kMaxManifestBytes &&
            data.length <= (kMaxManifestBytes - buffer.length)) {
            [buffer appendData:data];
        } else {
            [buffer setLength:kMaxManifestBytes + 1];
        }
    });
}

static void PMDidComplete(id self,
                          SEL _cmd,
                          NSURLSession *session,
                          NSURLSessionTask *task,
                          NSError *error) {
    NSString *suffix = [task isKindOfClass:NSURLSessionDataTask.class] ? PMMatchedSuffixForTask(task) : nil;
    if (!suffix) {
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))gOrigDidComplete)(
            self, _cmd, session, task, error);
        return;
    }

    NSNumber *key = @(task.taskIdentifier);
    __block NSMutableData *buffer = nil;

    dispatch_sync(gStateQueue, ^{
        buffer = gBuffers[key];
        [gBuffers removeObjectForKey:key];
    });

    if (!buffer) {
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))gOrigDidComplete)(
            self, _cmd, session, task, error);
        return;
    }

    if (!error && buffer.length > 0 && buffer.length <= kMaxManifestBytes) {
        NSData *forwarded = buffer;
        if (PMIsOnLoginScene()) {
            forwarded = PMPatchManifestData(buffer);
            PMMarkSuffixHandled(suffix);
        } else {
            ZLog(@"[PatchManifestNetwork] %@ finished outside the login scene - forwarding unpatched", suffix);
        }
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))gOrigDidReceiveData)(
            self,
            @selector(URLSession:dataTask:didReceiveData:),
            session,
            (NSURLSessionDataTask *)task,
            forwarded);
    } else if (buffer.length > kMaxManifestBytes) {
        ZLog(@"[PatchManifestNetwork] response exceeded %lu-byte safety cap; forwarding nothing",
              (unsigned long)kMaxManifestBytes);
    }

    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))gOrigDidComplete)(
        self, _cmd, session, task, error);
}

static NSArray<NSString *> *PMFindCandidateDelegateClassNames(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    SEL didReceiveSEL = @selector(URLSession:dataTask:didReceiveData:);
    SEL didCompleteSEL = @selector(URLSession:task:didCompleteWithError:);

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return candidates;

    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned long)count);
    if (!classes) return candidates;

    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (class_getInstanceMethod(cls, didReceiveSEL) &&
            class_getInstanceMethod(cls, didCompleteSEL)) {
            [candidates addObject:NSStringFromClass(cls)];
        }
    }

    free(classes);
    return candidates;
}

@implementation PatchManifestNetwork

+ (BOOL)isZeroAllEnabled {
    NSDictionary *section = zs_settings_section(kSettingsSection);
    id stored = section[kZeroingEnabledKey];

    return stored ? [stored boolValue] : NO;
}

+ (void)setZeroAllEnabled:(BOOL)enabled {
    NSMutableDictionary *section = [zs_settings_section(kSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZeroingEnabledKey] = @(enabled);
    zs_write_settings_section(kSettingsSection, section);
    ZLog(@"[PatchManifestNetwork] zero-all mode %@ via Developer switch", enabled ? @"enabled" : @"disabled");
}

+ (BOOL)isFullZeroingEnabled {
    NSDictionary *section = zs_settings_section(kSettingsSection);
    id stored = section[kFullZeroingEnabledKey];

    return stored ? [stored boolValue] : NO;
}

+ (void)setFullZeroingEnabled:(BOOL)enabled {
    NSMutableDictionary *section = [zs_settings_section(kSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kFullZeroingEnabledKey] = @(enabled);
    zs_write_settings_section(kSettingsSection, section);
    ZLog(@"[PatchManifestNetwork] full zeroing mode %@ via Developer switch", enabled ? @"enabled" : @"disabled");
}

+ (void)install {
    @synchronized (self) {
        if (gInstalled) return;

        gDelegateClass = NSClassFromString(@"UnityWebRequestDelegate");
        if (!gDelegateClass) {
            NSArray<NSString *> *candidates = PMFindCandidateDelegateClassNames();
            ZLog(@"[PatchManifestNetwork] UnityWebRequestDelegate class not found. "
                  @"Classes implementing both NSURLSessionDataDelegate methods we need: %@. "
                  @"If this list is non-empty, set gDelegateClass to the right one of these "
                  @"(usually the Unity/UnityEngine-prefixed one) and rerun. If it's empty, "
                  @"the delegate methods may not be exposed as ObjC methods at all in this "
                  @"build (e.g. a pure C/CFNetwork backend) and this approach needs a different "
                  @"hook point entirely.", candidates);
            return;
        }

        SEL didReceiveSEL = @selector(URLSession:dataTask:didReceiveData:);
        SEL didCompleteSEL = @selector(URLSession:task:didCompleteWithError:);

        Method didReceiveMethod = class_getInstanceMethod(gDelegateClass, didReceiveSEL);
        Method didCompleteMethod = class_getInstanceMethod(gDelegateClass, didCompleteSEL);
        if (!didReceiveMethod || !didCompleteMethod) {
            ZLog(@"[PatchManifestNetwork] required NSURLSession delegate methods not found on %@",
                  NSStringFromClass(gDelegateClass));
            return;
        }

        gOrigDidReceiveData = method_getImplementation(didReceiveMethod);
        gOrigDidComplete = method_getImplementation(didCompleteMethod);

        gBuffers = [NSMutableDictionary dictionary];
        gHandledSuffixes = [NSMutableSet set];
        gStateQueue = dispatch_queue_create("com.120F.PatchManifestNetwork", DISPATCH_QUEUE_SERIAL);

        method_setImplementation(didReceiveMethod, (IMP)PMDidReceiveData);
        method_setImplementation(didCompleteMethod, (IMP)PMDidComplete);
        gInstalled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            PMStartRearmTimer();
        });

        ZLog(@"[PatchManifestNetwork] installed on %@", NSStringFromClass(gDelegateClass));
    }
}

+ (void)uninstall {
    @synchronized (self) {
        if (!gInstalled || !gDelegateClass) return;

        SEL didReceiveSEL = @selector(URLSession:dataTask:didReceiveData:);
        SEL didCompleteSEL = @selector(URLSession:task:didCompleteWithError:);

        Method didReceiveMethod = class_getInstanceMethod(gDelegateClass, didReceiveSEL);
        Method didCompleteMethod = class_getInstanceMethod(gDelegateClass, didCompleteSEL);

        if (didReceiveMethod && gOrigDidReceiveData) {
            method_setImplementation(didReceiveMethod, gOrigDidReceiveData);
        }
        if (didCompleteMethod && gOrigDidComplete) {
            method_setImplementation(didCompleteMethod, gOrigDidComplete);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            PMStopRearmTimer();
        });
        gBuffers = nil;
        gHandledSuffixes = nil;
        gStateQueue = nil;
        gDelegateClass = Nil;
        gOrigDidReceiveData = NULL;
        gOrigDidComplete = NULL;
        gInstalled = NO;

        ZLog(@"[PatchManifestNetwork] uninstalled");
    }
}

@end

__attribute__((constructor))
static void PMNetworkConstructor(void) {

    ZLog(@"[PatchManifestNetwork] constructor fired - dylib loaded and this file is running");
}

static const int kPMPollIntervalUsec = 200 * 1000;
static const int kPMMaxPollAttempts = 150;

static void *PMBackgroundWorker(void *arg) {
    (void)arg;

    for (int attempt = 0; attempt < kPMMaxPollAttempts; attempt++) {
        if (NSClassFromString(@"UnityWebRequestDelegate")) {
            [PatchManifestNetwork install];
            return NULL;
        }
        usleep(kPMPollIntervalUsec);
    }

    ZLog(@"[PatchManifestNetwork] UnityWebRequestDelegate never appeared after %ds of polling; "
          @"running one-shot diagnostic scan", (kPMMaxPollAttempts * kPMPollIntervalUsec) / 1000000);
    [PatchManifestNetwork install];
    return NULL;
}

__attribute__((constructor))
static void PMNetworkConstructor2(void) {
    ZLog(@"[PatchManifestNetwork] constructor fired - starting poll thread");
    pthread_t t;
    pthread_create(&t, NULL, PMBackgroundWorker, NULL);
    pthread_detach(t);
}

