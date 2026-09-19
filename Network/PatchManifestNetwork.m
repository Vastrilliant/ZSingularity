#import "PatchManifestNetwork.h"
#import "ZTweakLog.h"
#import "ZSEngine.h"

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
static NSMutableSet<NSString *> *gPatchedSuffixes;

static NSMutableDictionary<NSNumber *, NSMutableData *> *gBuffers;
static dispatch_queue_t gStateQueue;

static NSString * const kSettingsSection = @"network";
static NSString * const kZeroingEnabledKey = @"fmodManifestZeroingEnabled";

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

static BOOL PMIsTargetTask(NSURLSessionDataTask *task) {
    NSString *matchedSuffix = PMMatchedSuffixForTask(task);

    ZLog(@"[PatchManifestNetwork] observed request url=%@ match=%@",
          task.currentRequest.URL ?: task.originalRequest.URL, matchedSuffix ? @"YES" : @"NO");

    return matchedSuffix != nil;
}

static NSData *PMPatchManifestData(NSData *input) {
    if (input.length == 0 || input.length > kMaxManifestBytes) {
        return input;
    }

    if (![PatchManifestNetwork isZeroingEnabled]) {
        ZLog(@"[PatchManifestNetwork] zeroing disabled via Config switch - forwarding manifest unmodified");
        return input;
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
        ZLog(@"[PatchManifestNetwork] manifest has no Files dictionary");
        return input;
    }

    NSUInteger patchedCount = 0;
    for (NSString *key in files) {
        NSMutableDictionary *entry = files[key];
        if (![entry isKindOfClass:[NSMutableDictionary class]]) continue;

        BOOL hashAlreadyZero = [entry[@"Hash"] isEqual:@"0"] || [entry[@"Hash"] isEqual:@0];
        BOOL sizeAlreadyZero = [entry[@"Size"] respondsToSelector:@selector(unsignedLongLongValue)]
            ? [entry[@"Size"] unsignedLongLongValue] == 0
            : NO;
        if (hashAlreadyZero && sizeAlreadyZero) continue;

        entry[@"Hash"] = @"0";
        entry[@"Size"] = @0;
        patchedCount++;
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

    ZLog(@"[PatchManifestNetwork] zeroed Hash/Size on %lu Files entries", (unsigned long)patchedCount);

    return output;
}

static void PMDidReceiveData(id self,
                             SEL _cmd,
                             NSURLSession *session,
                             NSURLSessionDataTask *task,
                             NSData *data) {
    if (!PMIsTargetTask(task)) {
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))gOrigDidReceiveData)(
            self, _cmd, session, task, data);
        return;
    }

    NSNumber *key = @(task.taskIdentifier);
    __block NSMutableData *buffer = nil;

    dispatch_sync(gStateQueue, ^{
        buffer = gBuffers[key];
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
    if (![task isKindOfClass:NSURLSessionDataTask.class] ||
        !PMIsTargetTask((NSURLSessionDataTask *)task)) {
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

    BOOL patched = NO;
    if (!error && buffer.length > 0 && buffer.length <= kMaxManifestBytes) {
        NSData *patchedData = PMPatchManifestData(buffer);
        patched = (patchedData != buffer);
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))gOrigDidReceiveData)(
            self,
            @selector(URLSession:dataTask:didReceiveData:),
            session,
            (NSURLSessionDataTask *)task,
            patchedData);
    } else if (buffer.length > kMaxManifestBytes) {
        ZLog(@"[PatchManifestNetwork] response exceeded %lu-byte safety cap; forwarding nothing",
              (unsigned long)kMaxManifestBytes);
    }

    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))gOrigDidComplete)(
        self, _cmd, session, task, error);

    if (patched) {
        NSString *matchedSuffix = PMMatchedSuffixForTask(task);
        BOOL allPatched = NO;
        @synchronized ([PatchManifestNetwork class]) {
            if (matchedSuffix) [gPatchedSuffixes addObject:matchedSuffix];
            allPatched = gPatchedSuffixes.count >= PMTargetPathSuffixes().count;
        }
        if (allPatched) {
            ZLog(@"[PatchManifestNetwork] every manifest patched - deactivating for the rest of this session");
            [PatchManifestNetwork uninstall];
        } else {
            ZLog(@"[PatchManifestNetwork] patched %@ - staying active for the remaining manifests", matchedSuffix);
        }
    }
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

+ (BOOL)isZeroingEnabled {
    NSDictionary *section = zs_settings_section(kSettingsSection);
    id stored = section[kZeroingEnabledKey];

    return stored ? [stored boolValue] : NO;
}

+ (void)setZeroingEnabled:(BOOL)enabled {
    NSMutableDictionary *section = [zs_settings_section(kSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZeroingEnabledKey] = @(enabled);
    zs_write_settings_section(kSettingsSection, section);
    ZLog(@"[PatchManifestNetwork] zeroing %@ via Config switch", enabled ? @"enabled" : @"disabled");
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
        gPatchedSuffixes = [NSMutableSet set];
        gStateQueue = dispatch_queue_create("com.120F.PatchManifestNetwork", DISPATCH_QUEUE_SERIAL);

        method_setImplementation(didReceiveMethod, (IMP)PMDidReceiveData);
        method_setImplementation(didCompleteMethod, (IMP)PMDidComplete);
        gInstalled = YES;

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

        gBuffers = nil;
        gPatchedSuffixes = nil;
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

