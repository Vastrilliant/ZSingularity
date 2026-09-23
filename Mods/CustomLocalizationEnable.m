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

static void ZSSetComponentGameObjectActive(void *component, BOOL active) {
    if (!component) return;
    void *klass = [IL2CppBridge classOfInstance:component];
    const void *getGameObject = [IL2CppBridge methodOnClass:klass name:"get_gameObject" argCount:0];
    if (!getGameObject) return;
    void *exc = NULL;
    void *gameObject = [IL2CppBridge invokeMethod:getGameObject onInstance:component args:NULL outException:&exc];
    if (exc || !gameObject) return;
    void *goClass = [IL2CppBridge classOfInstance:gameObject];
    const void *setActive = [IL2CppBridge methodOnClass:goClass name:"SetActive" argCount:1];
    if (!setActive) return;
    void *args[1] = { &active };
    exc = NULL;
    [IL2CppBridge invokeMethod:setActive onInstance:gameObject args:args outException:&exc];
}

static BOOL ZSFixLoginSceneCustomLocalizeButton(void) {
    void *loginKlass = ZSFindClass("LoginSceneManager", "");
    if (!loginKlass) return NO;
    void *loginInstance = [IL2CppBridge findFirstLiveInstanceOfClass:loginKlass];
    if (!loginInstance) return NO;

    int32_t customOff = [IL2CppBridge fieldOffsetOnClass:loginKlass name:"btn_customLocalize"];
    int32_t clearOff = [IL2CppBridge fieldOffsetOnClass:loginKlass name:"btn_allCacheClear"];
    if (customOff < 0 || clearOff < 0) return NO;

    void *customBtn = *(void **)((uint8_t *)loginInstance + customOff);
    void *clearBtn = *(void **)((uint8_t *)loginInstance + clearOff);
    if (!customBtn) return NO;

    ZSSetComponentGameObjectActive(customBtn, YES);
    ZSSetComponentGameObjectActive(clearBtn, NO);
    ZLog(@"[CustomLocalizeEnable] forced btn_customLocalize visible on LoginSceneManager");
    return YES;
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

    int loginAttempts = 0;
    __block BOOL fixedButton = NO;
    while (!fixedButton && loginAttempts < 150) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            fixedButton = ZSFixLoginSceneCustomLocalizeButton();
        });
        if (!fixedButton) {
            usleep(200 * 1000);
            loginAttempts++;
        }
    }
    if (!fixedButton) {
        ZLog(@"[CustomLocalizeEnable] never found a live LoginSceneManager to fix up the button");
    }

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
