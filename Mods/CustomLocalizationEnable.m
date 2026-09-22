
#import "CustomLocalizationEnable.h"
#import "IL2CppIntrospection.h"
#import "ZTweakLog.h"
#import "ZSUpdater.h"
#import <pthread.h>

static NSString *ZSCustomLangStagingDirectory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"CustomLang"];
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

static void *zs_custom_localize_enable_thread(void *arg) {
    (void)arg;

    if ([ZSDylibUpdater isStandaloneInstall]) {
        ZLog(@"[CustomLocalizeEnable] skipping: standalone install, app bundle isn't writable at runtime");
        return NULL;
    }

    void *localizeManager = NULL;
    int attempts = 0;
    while (!localizeManager && attempts < 150) { // ~30s at 200ms
        localizeManager = ZSFindClass("CustomLocalizeManager", "ProjectMoon.CustomLocalization");
        if (!localizeManager) {
            usleep(200 * 1000);
            attempts++;
        }
    }
    if (!localizeManager) {
        ZLog(@"[CustomLocalizeEnable] couldn't resolve CustomLocalizeManager - giving up");
        return NULL;
    }

    NSString *langPath = ZSInvokeStaticString(localizeManager, "GetLangDataPath");
    ZLog(@"[CustomLocalizeEnable] game reports its Lang folder at: %@", langPath ?: @"(nil)");
    if (langPath.length == 0) return NULL;

    NSString *stagingDir = ZSCustomLangStagingDirectory();
    if (!stagingDir) return NULL;

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:stagingDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *documentsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documentsDir && [langPath hasPrefix:documentsDir]) {
        [fm createDirectoryAtPath:langPath withIntermediateDirectories:YES attributes:nil error:nil];
        ZLog(@"[CustomLocalizeEnable] Lang path is already under Documents - nothing to redirect");
        return NULL;
    }


    NSString *existingLinkDestination = [fm destinationOfSymbolicLinkAtPath:langPath error:nil];
    if (existingLinkDestination) {
        if ([existingLinkDestination isEqualToString:stagingDir]) {
            ZLog(@"[CustomLocalizeEnable] Lang symlink already in place");
            return NULL;
        }
        [fm removeItemAtPath:langPath error:nil];
    } else {
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:langPath isDirectory:&isDirectory]) {
            NSString *sidecar = [langPath stringByAppendingString:@".zs-orig"];
            [fm removeItemAtPath:sidecar error:nil];
            [fm moveItemAtPath:langPath toPath:sidecar error:nil];
        } else {
            [fm createDirectoryAtPath:langPath.stringByDeletingLastPathComponent
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
        }
    }

    NSError *linkErr = nil;
    if (![fm createSymbolicLinkAtPath:langPath withDestinationPath:stagingDir error:&linkErr]) {
        ZLog(@"[CustomLocalizeEnable] failed to symlink Lang -> CustomLang: %@", linkErr.localizedDescription);
        return NULL;
    }

    ZLog(@"[CustomLocalizeEnable] linked %@ -> %@", langPath, stagingDir);
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
