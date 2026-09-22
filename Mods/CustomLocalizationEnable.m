#import "CustomLocalizationEnable.h"
#import "IL2CppIntrospection.h"
#import "ZTweakLog.h"
#import "ZSUpdater.h"
#import "ZSEngine.h"
#import <pthread.h>
#import <unistd.h>

static void *gZSForcedLangPathString;

static NSString *ZSCustomLangStagingDirectory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"Lang"];
}

static void *ZSFindClass(const char *className, const char *namespaze) {
    return [IL2CppBridge classNamed:className inNamespace:namespaze assemblyContains:"Assembly-CSharp"];
}

static NSString *ZSInvokeStaticString(void *klass, const char *methodName) {
    if (!klass) return nil;
    const void *method = [IL2CppBridge methodOnClass:klass name:methodName argCount:0];
    if (!method) {
        ZLog(@"[CustomLocalizeEnable] method not found: %s", methodName);
        return nil;
    }
    void *exc = NULL;
    void *result = [IL2CppBridge invokeMethod:method onInstance:NULL args:NULL outException:&exc];
    if (exc) {
        ZLog(@"[CustomLocalizeEnable] %s raised a managed exception", methodName);
        return nil;
    }
    return [IL2CppBridge nsStringFromIl2CppString:result];
}

static void *ZSForcedLangDataPathNative(void) {
    return gZSForcedLangPathString;
}

static BOOL ZSForcedIsRunningNative(void) {
    return YES;
}

static void ZSHookMethodPointer(const void *method, void *replacement) {
    if (!method || !replacement) return;
    *(void **)(uintptr_t)method = replacement;
}

static void *zs_custom_localize_enable_thread(void *arg) {
    (void)arg;

    if ([ZSDylibUpdater isStandaloneInstall]) {
        ZLog(@"[CustomLocalizeEnable] skipping: standalone install, app bundle isn't writable at runtime");
        return NULL;
    }

    __block BOOL unityReady = NO;
    while (!unityReady) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (zs_unity_view()) unityReady = YES;
        });
        if (!unityReady) usleep(200 * 1000);
    }

    usleep(1000 * 1000);

    __block void *localizeManager = NULL;
    int attempts = 0;
    while (!localizeManager && attempts < 150) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            localizeManager = ZSFindClass("CustomLocalizeManager", "ProjectMoon.CustomLocalization");
        });
        if (!localizeManager) {
            usleep(200 * 1000);
            attempts++;
        }
    }
    if (!localizeManager) {
        ZLog(@"[CustomLocalizeEnable] couldn't resolve CustomLocalizeManager - giving up");
        return NULL;
    }

    __block NSString *langPath = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        langPath = ZSInvokeStaticString(localizeManager, "GetLangDataPath");
    });
    ZLog(@"[CustomLocalizeEnable] game reports its Lang folder at: %@", langPath ?: @"(nil)");

    NSString *targetDir = ZSCustomLangStagingDirectory();
    if (!targetDir) return NULL;
    [NSFileManager.defaultManager createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:nil error:nil];

    if (langPath.length > 0) {
        NSString *documentsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (documentsDir && [langPath hasPrefix:documentsDir]) {
            ZLog(@"[CustomLocalizeEnable] Lang path already under Documents - nothing to patch");
            return NULL;
        }
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        const void *langMethod = [IL2CppBridge methodOnClass:localizeManager name:"GetLangDataPath" argCount:0];
        const void *runningMethod = [IL2CppBridge methodOnClass:localizeManager name:"IsRunning" argCount:0];

        if (langMethod) {
            void *forcedString = [IL2CppBridge il2CppStringFromNSString:targetDir];
            if (forcedString) {
                gZSForcedLangPathString = forcedString;
                ZSHookMethodPointer(langMethod, (void *)ZSForcedLangDataPathNative);
                ZLog(@"[CustomLocalizeEnable] hooked GetLangDataPath to return %@", targetDir);
            } else {
                ZLog(@"[CustomLocalizeEnable] failed to create managed string for %@", targetDir);
            }
        } else {
            ZLog(@"[CustomLocalizeEnable] GetLangDataPath method not found for hooking");
        }

        if (runningMethod) {
            ZSHookMethodPointer(runningMethod, (void *)ZSForcedIsRunningNative);
            ZLog(@"[CustomLocalizeEnable] hooked IsRunning to return true");
        } else {
            ZLog(@"[CustomLocalizeEnable] IsRunning method not found for hooking");
        }
    });

    return NULL;
}

void zs_enable_custom_localize(void) {
    pthread_t t;
    pthread_create(&t, NULL, zs_custom_localize_enable_thread, NULL);
    pthread_detach(t);
}

__attribute__((constructor))
static void zs_custom_localize_enable_init(void) {
    zs_enable_custom_localize();
}
