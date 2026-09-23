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

static BOOL ZSUnboxBoolean(void *boxed) {
    if (!boxed) return NO;
    return *(uint8_t *)((uint8_t *)boxed + 0x10) != 0;
}

static int32_t ZSUnboxInt32(void *boxed) {
    if (!boxed) return -1;
    return *(int32_t *)((uint8_t *)boxed + 0x10);
}

static void ZSLogCustomLocalizeCandidates(void *localizeManager) {
    if (!localizeManager) return;

    const void *dirsMethod = [IL2CppBridge methodOnClass:localizeManager name:"GetDirectoriesFrom" argCount:0];
    if (dirsMethod) {
        void *exc = NULL;
        void *array = [IL2CppBridge invokeMethod:dirsMethod onInstance:NULL args:NULL outException:&exc];
        if (exc) {
            ZLog(@"[CustomLocalizeEnable] GetDirectoriesFrom raised a managed exception");
        } else if (!array) {
            ZLog(@"[CustomLocalizeEnable] GetDirectoriesFrom returned nil");
        } else {
            void *arrKlass = [IL2CppBridge classOfInstance:array];
            const void *getLength = [IL2CppBridge methodOnClass:arrKlass name:"get_Length" argCount:0];
            int32_t length = -1;
            if (getLength) {
                exc = NULL;
                void *boxedLength = [IL2CppBridge invokeMethod:getLength onInstance:array args:NULL outException:&exc];
                if (!exc) length = ZSUnboxInt32(boxedLength);
            }
            ZLog(@"[CustomLocalizeEnable] GetDirectoriesFrom found %d subdirectory(ies) under the Lang root", length);
        }
    } else {
        ZLog(@"[CustomLocalizeEnable] GetDirectoriesFrom method not found for diagnostic");
    }

    const void *candidatesMethod = [IL2CppBridge methodOnClass:localizeManager name:"GetCandidates" argCount:0];
    if (!candidatesMethod) {
        ZLog(@"[CustomLocalizeEnable] GetCandidates method not found for diagnostic");
        return;
    }
    void *exc = NULL;
    void *list = [IL2CppBridge invokeMethod:candidatesMethod onInstance:NULL args:NULL outException:&exc];
    if (exc) {
        ZLog(@"[CustomLocalizeEnable] GetCandidates raised a managed exception");
        return;
    }
    if (!list) {
        ZLog(@"[CustomLocalizeEnable] GetCandidates returned nil");
        return;
    }
    void *listKlass = [IL2CppBridge classOfInstance:list];
    const void *getCount = [IL2CppBridge methodOnClass:listKlass name:"get_Count" argCount:0];
    if (!getCount) {
        ZLog(@"[CustomLocalizeEnable] GetCandidates list get_Count not found for diagnostic");
        return;
    }
    exc = NULL;
    void *boxedCount = [IL2CppBridge invokeMethod:getCount onInstance:list args:NULL outException:&exc];
    if (exc) {
        ZLog(@"[CustomLocalizeEnable] GetCandidates.Count raised a managed exception");
        return;
    }
    ZLog(@"[CustomLocalizeEnable] CustomLocalizeManager resolved %d candidate(s)", ZSUnboxInt32(boxedCount));
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
    __block NSString *parentPath = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        langPath = ZSInvokeStaticString(localizeManager, "GetLangDataPath");
        parentPath = ZSInvokeStaticString(localizeManager, "GetParentPath");
    });
    ZLog(@"[CustomLocalizeEnable] game reports its Lang folder at: %@", langPath ?: @"(nil)");
    ZLog(@"[CustomLocalizeEnable] game reports its candidate-scan parent path at: %@", parentPath ?: @"(nil)");

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
        const void *parentMethod = [IL2CppBridge methodOnClass:localizeManager name:"GetParentPath" argCount:0];
        const void *runningMethod = [IL2CppBridge methodOnClass:localizeManager name:"IsRunning" argCount:0];

        void *forcedString = [IL2CppBridge il2CppStringFromNSString:targetDir];
        if (forcedString) {
            gZSForcedLangPathString = forcedString;
        } else {
            ZLog(@"[CustomLocalizeEnable] failed to create managed string for %@", targetDir);
        }

        if (langMethod && forcedString) {
            ZSHookMethodPointer(langMethod, (void *)ZSForcedLangDataPathNative);
            ZLog(@"[CustomLocalizeEnable] hooked GetLangDataPath to return %@", targetDir);
        } else if (!langMethod) {
            ZLog(@"[CustomLocalizeEnable] GetLangDataPath method not found for hooking");
        }

        if (parentMethod && forcedString) {
            ZSHookMethodPointer(parentMethod, (void *)ZSForcedLangDataPathNative);
            ZLog(@"[CustomLocalizeEnable] hooked GetParentPath to return %@", targetDir);
        } else if (!parentMethod) {
            ZLog(@"[CustomLocalizeEnable] GetParentPath method not found for hooking");
        }

        if (runningMethod) {
            ZSHookMethodPointer(runningMethod, (void *)ZSForcedIsRunningNative);
            ZLog(@"[CustomLocalizeEnable] hooked IsRunning to return true");
        } else {
            ZLog(@"[CustomLocalizeEnable] IsRunning method not found for hooking");
        }

        ZSLogCustomLocalizeCandidates(localizeManager);
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
