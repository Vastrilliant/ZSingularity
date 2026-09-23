#import "CustomLocalizationEnable.h"
#import "IL2CppIntrospection.h"
#import "ZTweakLog.h"
#import "ZSUpdater.h"
#import "ZSEngine.h"
#import <pthread.h>
#import <unistd.h>

static void *gZSForcedLangPathString;
static void *gZSCustomLocalizeDropdown;
static void *gZSCustomLocalizePopup;
static void *gZSGameStartTouchTrigger;
static BOOL gZSCustomLocalizeTemplateFixed;
static BOOL gZSCustomLocalizeCaptionFixed;

static NSString *ZSCustomLangStagingDirectory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (!documentsDir) return nil;
    return [documentsDir stringByAppendingPathComponent:@"Lang"];
}

static void *ZSFindClass(const char *className, const char *namespaze) {
    return [IL2CppBridge classNamed:className inNamespace:namespaze assemblyContains:"Assembly-CSharp"];
}

static void *ZSFindClassInAssembly(const char *className, const char *namespaze, const char *assemblySubstring) {
    return [IL2CppBridge classNamed:className inNamespace:namespaze assemblyContains:assemblySubstring];
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

static void ZSResetCustomLocalizeCaches(void *klass) {
    if (!klass) return;
    static const char *fieldNames[] = { "_data", "_candidates", "_fonts", "_configFile" };
    uint8_t zero[64] = {0};
    for (size_t i = 0; i < sizeof(fieldNames) / sizeof(fieldNames[0]); i++) {
        void *field = [IL2CppBridge fieldNamed:fieldNames[i] onClass:klass];
        if (!field) {
            ZLog(@"[CustomLocalizeEnable] cache field %s not found, skipping reset", fieldNames[i]);
            continue;
        }
        [IL2CppBridge setStaticFieldValue:field fromBuffer:zero];
        ZLog(@"[CustomLocalizeEnable] reset cached field %s", fieldNames[i]);
    }
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

static void ZSSetSelectableInteractable(void *component, BOOL interactable) {
    if (!component) return;
    void *klass = [IL2CppBridge classOfInstance:component];
    const void *setInteractable = [IL2CppBridge methodOnClass:klass name:"set_interactable" argCount:1];
    if (!setInteractable) {
        ZLog(@"[CustomLocalizeEnable] set_interactable not found on dropdown class");
        return;
    }
    void *args[1] = { &interactable };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:setInteractable onInstance:component args:args outException:&exc];
    if (exc) {
        ZLog(@"[CustomLocalizeEnable] set_interactable raised a managed exception");
    }
}

static void *ZSTransformOfComponent(void *component) {
    if (!component) return NULL;
    void *klass = [IL2CppBridge classOfInstance:component];
    const void *getTransform = [IL2CppBridge methodOnClass:klass name:"get_transform" argCount:0];
    if (!getTransform) return NULL;
    void *exc = NULL;
    void *transform = [IL2CppBridge invokeMethod:getTransform onInstance:component args:NULL outException:&exc];
    if (exc) return NULL;
    return transform;
}

static void *ZSFindChildTransform(void *transform, NSString *name) {
    if (!transform) return NULL;
    void *klass = [IL2CppBridge classOfInstance:transform];
    const void *findMethod = [IL2CppBridge methodOnClass:klass name:"Find" argCount:1];
    if (!findMethod) return NULL;
    void *nameString = [IL2CppBridge il2CppStringFromNSString:name];
    if (!nameString) return NULL;
    void *args[1] = { nameString };
    void *exc = NULL;
    void *result = [IL2CppBridge invokeMethod:findMethod onInstance:transform args:args outException:&exc];
    if (exc) return NULL;
    return result;
}

static void ZSSetDropdownTemplate(void *dropdown, void *templateRectTransform) {
    if (!dropdown || !templateRectTransform) return;
    void *klass = [IL2CppBridge classOfInstance:dropdown];
    const void *setTemplate = [IL2CppBridge methodOnClass:klass name:"set_template" argCount:1];
    if (!setTemplate) {
        ZLog(@"[CustomLocalizeEnable] set_template not found on dropdown class");
        return;
    }
    void *args[1] = { templateRectTransform };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:setTemplate onInstance:dropdown args:args outException:&exc];
    if (exc) {
        ZLog(@"[CustomLocalizeEnable] set_template raised a managed exception");
    }
}

static BOOL ZSFixCustomLocalizeDropdownTemplate(void *dropdown) {
    void *dropdownTransform = ZSTransformOfComponent(dropdown);
    void *templateTransform = ZSFindChildTransform(dropdownTransform, @"Template");
    if (!templateTransform) {
        return NO;
    }
    ZSSetDropdownTemplate(dropdown, templateTransform);
    ZLog(@"[CustomLocalizeEnable] rewired tmp_dropdown.template to the Template child transform");
    return YES;
}

static void *ZSGameObjectOfTransform(void *transform) {
    if (!transform) return NULL;
    void *klass = [IL2CppBridge classOfInstance:transform];
    const void *getGameObject = [IL2CppBridge methodOnClass:klass name:"get_gameObject" argCount:0];
    if (!getGameObject) return NULL;
    void *exc = NULL;
    void *gameObject = [IL2CppBridge invokeMethod:getGameObject onInstance:transform args:NULL outException:&exc];
    if (exc) return NULL;
    return gameObject;
}

static void *ZSGetComponentOnGameObject(void *gameObject, void *componentKlass) {
    if (!gameObject || !componentKlass) return NULL;
    void *goKlass = [IL2CppBridge classOfInstance:gameObject];
    const void *getComponent = [IL2CppBridge methodOnClass:goKlass name:"GetComponent" argCount:1];
    if (!getComponent) {
        ZLog(@"[CustomLocalizeEnable] GetComponent(Type) not found on GameObject class");
        return NULL;
    }
    void *type = [IL2CppBridge reflectionTypeForClass:componentKlass];
    if (!type) {
        ZLog(@"[CustomLocalizeEnable] couldn't resolve a System.Type for the requested component class");
        return NULL;
    }
    void *args[1] = { type };
    void *exc = NULL;
    void *result = [IL2CppBridge invokeMethod:getComponent onInstance:gameObject args:args outException:&exc];
    if (exc) {
        ZLog(@"[CustomLocalizeEnable] GetComponent(Type) raised a managed exception");
        return NULL;
    }
    return result;
}

static void ZSSetDropdownCaptionText(void *dropdown, void *captionText) {
    if (!dropdown || !captionText) return;
    void *klass = [IL2CppBridge classOfInstance:dropdown];
    const void *setCaptionText = [IL2CppBridge methodOnClass:klass name:"set_captionText" argCount:1];
    if (!setCaptionText) {
        ZLog(@"[CustomLocalizeEnable] set_captionText not found on dropdown class");
        return;
    }
    void *args[1] = { captionText };
    void *exc = NULL;
    [IL2CppBridge invokeMethod:setCaptionText onInstance:dropdown args:args outException:&exc];
    if (exc) {
        ZLog(@"[CustomLocalizeEnable] set_captionText raised a managed exception");
    }
}

static void ZSRefreshDropdownShownValue(void *dropdown) {
    if (!dropdown) return;
    void *klass = [IL2CppBridge classOfInstance:dropdown];
    const void *refresh = [IL2CppBridge methodOnClass:klass name:"RefreshShownValue" argCount:0];
    if (!refresh) {
        ZLog(@"[CustomLocalizeEnable] RefreshShownValue not found on dropdown class");
        return;
    }
    void *exc = NULL;
    [IL2CppBridge invokeMethod:refresh onInstance:dropdown args:NULL outException:&exc];
    if (exc) {
        ZLog(@"[CustomLocalizeEnable] RefreshShownValue raised a managed exception");
    }
}

static BOOL ZSFixCustomLocalizeDropdownCaption(void *dropdown) {
    void *dropdownTransform = ZSTransformOfComponent(dropdown);
    void *labelTransform = ZSFindChildTransform(dropdownTransform, @"Label");
    if (!labelTransform) {
        return NO;
    }
    void *labelGameObject = ZSGameObjectOfTransform(labelTransform);
    if (!labelGameObject) {
        return NO;
    }
    void *tmpTextKlass = ZSFindClassInAssembly("TMP_Text", "TMPro", "Unity.TextMeshPro");
    if (!tmpTextKlass) {
        ZLog(@"[CustomLocalizeEnable] couldn't resolve the TMP_Text class");
        return NO;
    }
    void *labelText = ZSGetComponentOnGameObject(labelGameObject, tmpTextKlass);
    if (!labelText) {
        ZLog(@"[CustomLocalizeEnable] Label child has no TMP_Text component");
        return NO;
    }
    ZSSetDropdownCaptionText(dropdown, labelText);
    ZSRefreshDropdownShownValue(dropdown);
    ZLog(@"[CustomLocalizeEnable] rewired tmp_dropdown.captionText to the Label child's TMP_Text and refreshed it");
    return YES;
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

static BOOL ZSComponentGameObjectActiveInHierarchy(void *component) {
    if (!component) return NO;
    void *klass = [IL2CppBridge classOfInstance:component];
    const void *getGameObject = [IL2CppBridge methodOnClass:klass name:"get_gameObject" argCount:0];
    if (!getGameObject) return NO;
    void *exc = NULL;
    void *gameObject = [IL2CppBridge invokeMethod:getGameObject onInstance:component args:NULL outException:&exc];
    if (exc || !gameObject) return NO;
    void *goClass = [IL2CppBridge classOfInstance:gameObject];
    const void *getActive = [IL2CppBridge methodOnClass:goClass name:"get_activeInHierarchy" argCount:0];
    if (!getActive) return NO;
    exc = NULL;
    void *boxed = [IL2CppBridge invokeMethod:getActive onInstance:gameObject args:NULL outException:&exc];
    if (exc) return NO;
    return ZSUnboxBoolean(boxed);
}

static void *ZSResolveCustomLocalizeDropdown(void *loginInstance, void *loginKlass) {
    int32_t popupOff = [IL2CppBridge fieldOffsetOnClass:loginKlass name:"_customLocalizePopup"];
    if (popupOff < 0) return NULL;
    void *popup = *(void **)((uint8_t *)loginInstance + popupOff);
    if (!popup) return NULL;
    gZSCustomLocalizePopup = popup;
    void *popupKlass = [IL2CppBridge classOfInstance:popup];
    int32_t dropdownOff = [IL2CppBridge fieldOffsetOnClass:popupKlass name:"tmp_dropdown"];
    if (dropdownOff < 0) return NULL;
    return *(void **)((uint8_t *)popup + dropdownOff);
}

static BOOL ZSFixLoginSceneCustomLocalizeButton(void) {
    void *loginKlass = ZSFindClass("LoginSceneManager", "");
    if (!loginKlass) return NO;
    void *loginInstance = [IL2CppBridge findFirstLiveInstanceOfClass:loginKlass];
    if (!loginInstance) return NO;

    int32_t customOff = [IL2CppBridge fieldOffsetOnClass:loginKlass name:"btn_customLocalize"];
    int32_t clearOff = [IL2CppBridge fieldOffsetOnClass:loginKlass name:"btn_allCacheClear"];
    int32_t triggerOff = [IL2CppBridge fieldOffsetOnClass:loginKlass name:"trigger_gameStart"];
    if (customOff < 0 || clearOff < 0) return NO;

    void *customBtn = *(void **)((uint8_t *)loginInstance + customOff);
    void *clearBtn = *(void **)((uint8_t *)loginInstance + clearOff);
    if (!customBtn) return NO;

    if (triggerOff >= 0) {
        gZSGameStartTouchTrigger = *(void **)((uint8_t *)loginInstance + triggerOff);
    }

    ZSSetComponentGameObjectActive(customBtn, YES);
    ZSSetComponentGameObjectActive(clearBtn, NO);
    ZLog(@"[CustomLocalizeEnable] forced btn_customLocalize visible on LoginSceneManager");

    void *dropdown = ZSResolveCustomLocalizeDropdown(loginInstance, loginKlass);
    if (dropdown) {
        gZSCustomLocalizeDropdown = dropdown;
        ZSSetSelectableInteractable(dropdown, YES);
        gZSCustomLocalizeTemplateFixed = ZSFixCustomLocalizeDropdownTemplate(dropdown);
        gZSCustomLocalizeCaptionFixed = ZSFixCustomLocalizeDropdownCaption(dropdown);
        ZLog(@"[CustomLocalizeEnable] forced tmp_dropdown interactable on CustomLocalizeSettingsUIPopup (template fixed: %d, caption fixed: %d)", gZSCustomLocalizeTemplateFixed, gZSCustomLocalizeCaptionFixed);
    } else {
        ZLog(@"[CustomLocalizeEnable] couldn't resolve tmp_dropdown on CustomLocalizeSettingsUIPopup");
    }
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

        ZSResetCustomLocalizeCaches(localizeManager);
        ZSLogCustomLocalizeCandidates(localizeManager);
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
        return NULL;
    }

    while (gZSCustomLocalizeDropdown) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            ZSSetSelectableInteractable(gZSCustomLocalizeDropdown, YES);
            if (!gZSCustomLocalizeTemplateFixed) {
                gZSCustomLocalizeTemplateFixed = ZSFixCustomLocalizeDropdownTemplate(gZSCustomLocalizeDropdown);
            }
            if (!gZSCustomLocalizeCaptionFixed) {
                gZSCustomLocalizeCaptionFixed = ZSFixCustomLocalizeDropdownCaption(gZSCustomLocalizeDropdown);
            }
            if (gZSGameStartTouchTrigger && gZSCustomLocalizePopup) {
                BOOL popupOpen = ZSComponentGameObjectActiveInHierarchy(gZSCustomLocalizePopup);
                ZSSetComponentGameObjectActive(gZSGameStartTouchTrigger, !popupOpen);
            }
        });
        usleep(150 * 1000);
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
