#import "MetalHUDController.h"
#import "ZSEngine.h"
#import "ZTweakLog.h"
#import <stdlib.h>

static NSString * const kSettingsSection = @"metalHUD";
static NSString * const kEnabledKey = @"enabled";

static void ZSMetalHUD_ApplyEnvironment(BOOL enabled) {
    setenv("MTL_HUD_ENABLED", enabled ? "1" : "0", 1);
}

@implementation MetalHUDController

+ (BOOL)isEnabled {
    NSDictionary *section = zs_settings_section(kSettingsSection);
    id stored = section[kEnabledKey];
    return stored ? [stored boolValue] : NO;
}

+ (void)setEnabled:(BOOL)enabled {
    NSMutableDictionary *section = [zs_settings_section(kSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kEnabledKey] = @(enabled);
    zs_write_settings_section(kSettingsSection, section);
    ZLog(@"[MetalHUDController] %@ via Config switch, takes effect after the app is relaunched", enabled ? @"enabled" : @"disabled");
}

+ (void)install {
    ZSMetalHUD_ApplyEnvironment(self.isEnabled);
}

@end

__attribute__((constructor(101)))
static void MetalHUDControllerConstructor(void) {
    [MetalHUDController install];
}
