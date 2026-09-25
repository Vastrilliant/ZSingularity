
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import "ZSEngine.h"
#import "ZSDiagnostics.h"
#import "ZTweakLog.h"
#import "Mods.h"
#import "Transcoder.h"
#import "PatchManifestNetwork.h"
#import "ZSVersion.h"
#import "ZSUpdater.h"

#import "UnityBundleTools.h"
#import "IL2CppIntrospection.h"
#import "Dumper/ZSDumper.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "ZSEmbeddedFont.h"
#import "ZSEmbeddedSignature.h"
#import "ZSDocs.h"
#import "ZSGifTint.h"

@class ZSCapsuleSlider, ZSModeSlider, ZSWheelPicker;

#pragma mark - Compact row control

@interface ZSRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) ZSCapsuleSlider *slider;
@property (nonatomic, strong) ZSModeSlider *modeSlider;
@property (nonatomic, strong) ZSWheelPicker *wheelPicker;
@property (nonatomic, strong) UISwitch *toggle;
@end

static NSDictionary *zs_load_collapsed_section_states(void);
static void zs_update_value_label(ZSCapsuleSlider *slider);

#pragma mark - Monospaced font helper

static UIFont *zs_mono_font(CGFloat size, UIFontWeight weight) {
    return [UIFont monospacedSystemFontOfSize:size weight:weight];
}

static const CGFloat kZSSubtitleFontSize = 10;

#pragma mark - Window discovery

static UIWindow *zs_key_window(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return [UIApplication sharedApplication].delegate.window;
}

static UIView *zs_ui_host_view(void) {
    return zs_unity_view() ?: zs_key_window();
}

static void zs_close_application(void) {
    zs_persist_current_settings();
    exit(0);
}

static void zs_add_restart_action(UIAlertController *alert) {
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart App"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        zs_close_application();
    }]];
}

static NSString *zs_asset_imported_line(NSString *name) {
    return [NSString stringWithFormat:@"%@ Asset imported", name];
}

static void zs_drop_font_from_import(NSURL *url, NSString *reason, NSMutableArray<NSURL *> *validURLs, NSMutableArray<NSString *> *summaryLines) {
    [validURLs removeObject:url];
    NSString *line = [NSString stringWithFormat:@"%@: %@", url.lastPathComponent, reason];
    NSUInteger existingIdx = [summaryLines indexOfObject:zs_asset_imported_line(url.lastPathComponent)];
    if (existingIdx != NSNotFound) {
        summaryLines[existingIdx] = line;
    } else {
        [summaryLines addObject:line];
    }
}

static void zs_force_dark(UIView *view) {
    if (@available(iOS 13.0, *)) {
        view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
}

#pragma mark - Accent color

static UIColor *zs_accent_green_color(void) {
    return [UIColor colorWithRed:0x30 / 255.0 green:0xD1 / 255.0 blue:0x58 / 255.0 alpha:1.0];
}

static UIColor *zs_accent_yellow_color(void) {
    return [UIColor colorWithRed:1.0 green:0.82 blue:0.2 alpha:1.0];
}

static UIColor *zs_bar_fill_color(void) {
    UIColor *base = zs_accent_green_color();
    CGFloat h = 0, s = 0, b = 0, a = 0;
    [base getHue:&h saturation:&s brightness:&b alpha:&a];
    return [UIColor colorWithHue:h saturation:MIN(1.0, s * 1.15) brightness:MIN(1.0, b * 1.12) alpha:a];
}

#pragma mark - Liquid Glass helpers

static NSString * const kZSLiquidGlassSettingsSection = @"liquidGlass";
static NSString * const kZSLiquidGlassDisabledKey = @"disabled";

static NSString * const kZSUISettingsSection = @"ui";
static NSString * const kZSUICollapsedSectionsKey = @"collapsedSections";


static BOOL gZSLiquidGlassDisabledCache;
static BOOL gZSLiquidGlassDisabledCacheLoaded;

static BOOL zs_liquid_glass_disabled_by_user(void) {
    if (!gZSLiquidGlassDisabledCacheLoaded) {
        NSDictionary *section = zs_settings_section(kZSLiquidGlassSettingsSection);
        id stored = section[kZSLiquidGlassDisabledKey];
        gZSLiquidGlassDisabledCache = stored ? [stored boolValue] : NO;
        gZSLiquidGlassDisabledCacheLoaded = YES;
    }
    return gZSLiquidGlassDisabledCache;
}

static void zs_set_liquid_glass_disabled_by_user(BOOL disabled) {
    NSMutableDictionary *section = [zs_settings_section(kZSLiquidGlassSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSLiquidGlassDisabledKey] = @(disabled);
    zs_write_settings_section(kZSLiquidGlassSettingsSection, section);
    gZSLiquidGlassDisabledCache = disabled;
    gZSLiquidGlassDisabledCacheLoaded = YES;
}

static NSString * const kZSEnkephalinSettingsSection = @"enkephalin";
static NSString * const kZSEnkephalinDisabledKey = @"disabled";

static BOOL gZSEnkephalinDisabledCache;
static BOOL gZSEnkephalinDisabledCacheLoaded;

static BOOL zs_enkephalin_disabled_by_user(void) {
    if (!gZSEnkephalinDisabledCacheLoaded) {
        NSDictionary *section = zs_settings_section(kZSEnkephalinSettingsSection);
        id stored = section[kZSEnkephalinDisabledKey];
        gZSEnkephalinDisabledCache = stored ? [stored boolValue] : NO;
        gZSEnkephalinDisabledCacheLoaded = YES;
    }
    return gZSEnkephalinDisabledCache;
}

static void zs_set_enkephalin_disabled_by_user(BOOL disabled) {
    NSMutableDictionary *section = [zs_settings_section(kZSEnkephalinSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSEnkephalinDisabledKey] = @(disabled);
    zs_write_settings_section(kZSEnkephalinSettingsSection, section);
    gZSEnkephalinDisabledCache = disabled;
    gZSEnkephalinDisabledCacheLoaded = YES;
}

#pragma mark - Social links

static NSString * const kZSSocialGitHubURL = @"https://github.com/Vastrilliant/ZSingularity";
static NSString * const kZSSocialDiscordURL = @"https://discord.gg/nRmztE2unw";

static void zs_style_social_text_button(UIButton *button, NSString *text) {
    UIFont *baseFont = zs_mono_font(kZSSubtitleFontSize, UIFontWeightMedium);
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:text ?: @""
        attributes:@{NSFontAttributeName: baseFont,
                      NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45],
                      NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)}];
    [button setAttributedTitle:attributed forState:UIControlStateNormal];
    button.backgroundColor = [UIColor clearColor];
    button.layer.borderWidth = 0;
    button.layer.cornerRadius = 0;
    button.clipsToBounds = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    button.titleLabel.font = baseFont;
    [button.titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
}


static NSString * const kZSTutorialSettingsSection = @"tutorial";
static NSString * const kZSTutorialCompletedKey = @"completed";
static NSString * const kZSTutorialOverrideCompletionKey = @"overrideCompletion";

static BOOL zs_tutorial_completed(void) {
    NSDictionary *section = zs_settings_section(kZSTutorialSettingsSection);
    return [section[kZSTutorialCompletedKey] boolValue];
}

static void zs_set_tutorial_completed(BOOL completed) {
    NSMutableDictionary *section = [zs_settings_section(kZSTutorialSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSTutorialCompletedKey] = @(completed);
    zs_write_settings_section(kZSTutorialSettingsSection, section);
}

static BOOL zs_tutorial_override_completion_enabled(void) {
    NSDictionary *section = zs_settings_section(kZSTutorialSettingsSection);
    return [section[kZSTutorialOverrideCompletionKey] boolValue];
}

static void zs_set_tutorial_override_completion_enabled(BOOL enabled) {
    NSMutableDictionary *section = [zs_settings_section(kZSTutorialSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSTutorialOverrideCompletionKey] = @(enabled);
    zs_write_settings_section(kZSTutorialSettingsSection, section);
}

static NSString * const kZSDeveloperSettingsSection = @"developer";
static NSString * const kZSDeveloperEnabledKey = @"enabled";
static const NSInteger kZSDeveloperUnlockTapCount = 10;
static const CFTimeInterval kZSDeveloperUnlockTapInterval = 0.6;

static BOOL zs_developer_settings_enabled(void) {
    NSDictionary *section = zs_settings_section(kZSDeveloperSettingsSection);
    return [section[kZSDeveloperEnabledKey] boolValue];
}

static void zs_set_developer_settings_enabled(BOOL enabled) {
    NSMutableDictionary *section = [zs_settings_section(kZSDeveloperSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSDeveloperEnabledKey] = @(enabled);
    zs_write_settings_section(kZSDeveloperSettingsSection, section);
}

#pragma mark - Update pipeline settings

static NSString * const kZSUpdatePipelineSettingsSection = @"updatePipeline";
static NSString * const kZSUpdateUseNightlyReleasesKey = @"useNightlyReleases";
static NSString * const kZSReleaseInfoDocsKey = @"__release_info__";

static BOOL gZSUpdateUseNightlyReleasesCache;
static BOOL gZSUpdateUseNightlyReleasesCacheLoaded;

static BOOL zs_update_uses_nightly_releases(void) {
    if (!gZSUpdateUseNightlyReleasesCacheLoaded) {
        NSDictionary *section = zs_settings_section(kZSUpdatePipelineSettingsSection);
        id stored = section[kZSUpdateUseNightlyReleasesKey];
        gZSUpdateUseNightlyReleasesCache = stored ? [stored boolValue] : NO;
        gZSUpdateUseNightlyReleasesCacheLoaded = YES;
    }
    return gZSUpdateUseNightlyReleasesCache;
}

static void zs_set_update_uses_nightly_releases(BOOL useNightlyReleases) {
    NSMutableDictionary *section = [zs_settings_section(kZSUpdatePipelineSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSUpdateUseNightlyReleasesKey] = @(useNightlyReleases);
    zs_write_settings_section(kZSUpdatePipelineSettingsSection, section);
    gZSUpdateUseNightlyReleasesCache = useNightlyReleases;
    gZSUpdateUseNightlyReleasesCacheLoaded = YES;
}

static ZSUpdateCheckMode zs_update_check_mode(void) {
    return zs_update_uses_nightly_releases() ? ZSUpdateCheckModeNightlyReleases : ZSUpdateCheckModeReleases;
}

static BOOL zs_has_liquid_glass(void) {
    static BOOL has;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        has = NO;
        if (@available(iOS 26.0, *)) {
            has = (NSClassFromString(@"UIGlassEffect") != nil &&
                   NSClassFromString(@"UIGlassContainerEffect") != nil);
        }
    });
    return has && !zs_liquid_glass_disabled_by_user();
}

static UIVisualEffect *zs_make_glass_effect_style(NSInteger style, BOOL interactive, UIColor *tintColor) {
    if (zs_has_liquid_glass()) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        if (!glassClass) return nil;

        SEL factory = NSSelectorFromString(@"effectWithStyle:");
        id effect = nil;
        if ([glassClass respondsToSelector:factory]) {

            effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, factory, style);
        }
        if (!effect) {

            effect = [[glassClass alloc] init];
        }

        SEL setInteractive = NSSelectorFromString(@"setInteractive:");
        if ([effect respondsToSelector:setInteractive]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setInteractive, interactive);
        }

        SEL setTint = NSSelectorFromString(@"setTintColor:");
        if ([effect respondsToSelector:setTint]) {
            ((void (*)(id, SEL, id))objc_msgSend)(effect, setTint, tintColor);
        }
        return effect;
    }

    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
}

static UIColor *zs_glass_tint_color(void) {
    return [UIColor colorWithWhite:0.0 alpha:0.32];
}

static UIVisualEffect *zs_make_glass_effect(BOOL interactive) {
    return zs_make_glass_effect_style(0 , interactive, zs_glass_tint_color());
}

static UIVisualEffect *zs_make_glass_effect_dark(BOOL interactive) {
    return zs_make_glass_effect_style(0 , interactive, zs_glass_tint_color());
}

static void zs_set_track_glass_interactive(UIVisualEffectView *trackGlass, BOOL interactive) {
    if (!trackGlass) return;
    trackGlass.effect = zs_make_glass_effect(interactive);
}

static void zs_dump_glass_effect_instance_info(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass) {
        ZLog(@"[UserInterface] UIGlassEffect class not found");
        return;
    }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(glassClass, &methodCount);
    ZLog(@"[UserInterface] UIGlassEffect instance methods (%u):", methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        ZLog(@"[UserInterface]   - %@", NSStringFromSelector(method_getName(methods[i])));
    }
    free(methods);

    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(glassClass, &propCount);
    ZLog(@"[UserInterface] UIGlassEffect properties (%u):", propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        ZLog(@"[UserInterface]   @property %s (%s)", property_getName(props[i]), property_getAttributes(props[i]));
    }
    free(props);
}

static UIVisualEffect *zs_make_glass_container_effect(CGFloat spacing) {
    if (!zs_has_liquid_glass()) return nil;
    Class containerClass = NSClassFromString(@"UIGlassContainerEffect");
    if (!containerClass) return nil;

    id effect = [[containerClass alloc] init];
    SEL setSpacing = NSSelectorFromString(@"setSpacing:");
    if ([effect respondsToSelector:setSpacing]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(effect, setSpacing, spacing);
    }
    return effect;
}

static void zs_configure_glass_corners(UIView *view, CGFloat radius, BOOL concentric) {
    if (!view || !zs_has_liquid_glass()) return;

    Class radiusClass = NSClassFromString(@"UICornerRadius");
    Class configClass = NSClassFromString(@"UICornerConfiguration");
    if (!radiusClass || !configClass) return;

    SEL radiusSelector = concentric
        ? NSSelectorFromString(@"containerConcentricRadiusWithMinimum:")
        : NSSelectorFromString(@"fixedRadius:");

    SEL configSelector = NSSelectorFromString(@"configurationWithRadius:");
    SEL setConfiguration = NSSelectorFromString(@"setCornerConfiguration:");

    if (![radiusClass respondsToSelector:radiusSelector] ||
        ![configClass respondsToSelector:configSelector] ||
        ![view respondsToSelector:setConfiguration]) {
        return;
    }

    id radiusObject = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass,
                                                                radiusSelector,
                                                                radius);
    if (!radiusObject) return;

    id configuration = ((id (*)(id, SEL, id))objc_msgSend)(configClass,
                                                             configSelector,
                                                             radiusObject);
    if (!configuration) return;

    ((void (*)(id, SEL, id))objc_msgSend)(view,
                                           setConfiguration,
                                           configuration);
}

static NSHashTable<UIVisualEffectView *> *zs_suspendable_glass_registry(void) {
    static NSHashTable<UIVisualEffectView *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static const void *kZSSuspendedGlassEffectKey = &kZSSuspendedGlassEffectKey;

static void zs_register_suspendable_glass(UIVisualEffectView *view) {
    if (!view) return;
    [zs_suspendable_glass_registry() addObject:view];
}

static void zs_set_glass_suspended(BOOL suspended) {
    for (UIVisualEffectView *view in zs_suspendable_glass_registry()) {
        if (suspended) {
            if (view.effect) {
                objc_setAssociatedObject(view, kZSSuspendedGlassEffectKey, view.effect, OBJC_ASSOCIATION_RETAIN);
                view.effect = nil;
            }
        } else {
            UIVisualEffect *stored = objc_getAssociatedObject(view, kZSSuspendedGlassEffectKey);
            if (stored) {
                view.effect = stored;
                objc_setAssociatedObject(view, kZSSuspendedGlassEffectKey, nil, OBJC_ASSOCIATION_RETAIN);
            }
        }
    }
}

static void zs_configure_glass_button_fixed_corner_radius(UIButton *button, CGFloat radius) {
    if (!button) return;

    SEL getConfiguration = NSSelectorFromString(@"configuration");
    if (![button respondsToSelector:getConfiguration]) return;
    id configuration = ((id (*)(id, SEL))objc_msgSend)(button, getConfiguration);
    if (!configuration) return;

    SEL setCornerStyle = NSSelectorFromString(@"setCornerStyle:");
    if ([configuration respondsToSelector:setCornerStyle]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(configuration, setCornerStyle, 1 );
    }

    SEL getBackground = NSSelectorFromString(@"background");
    if ([configuration respondsToSelector:getBackground]) {
        id background = ((id (*)(id, SEL))objc_msgSend)(configuration, getBackground);
        SEL setCornerRadius = NSSelectorFromString(@"setCornerRadius:");
        if (background && [background respondsToSelector:setCornerRadius]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(background, setCornerRadius, radius);
        }
    }

    SEL setConfiguration = NSSelectorFromString(@"setConfiguration:");
    if ([button respondsToSelector:setConfiguration]) {
        ((void (*)(id, SEL, id))objc_msgSend)(button, setConfiguration, configuration);
    }
}

static const CGFloat kZSAuthFieldCornerRadius = 3;

static void zs_clear_button_configuration(UIButton *button) {
    if (!button) return;
    SEL setConfig = NSSelectorFromString(@"setConfiguration:");
    if ([button respondsToSelector:setConfig]) {
        ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, nil);
    }
}

static void zs_style_button_as_native_glass_with_font(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font) {
    if (zs_has_liquid_glass()) {
        Class configClass = NSClassFromString(@"UIButtonConfiguration");
        SEL glassSel = NSSelectorFromString(@"glassButtonConfiguration");
        if (configClass && [configClass respondsToSelector:glassSel]) {
            id configuration = ((id (*)(id, SEL))objc_msgSend)(configClass, glassSel);
            if (configuration) {
                if (font) {
                    SEL setAttributedTitle = NSSelectorFromString(@"setAttributedTitle:");
                    if ([configuration respondsToSelector:setAttributedTitle]) {
                        NSAttributedString *attributedTitle =
                            [[NSAttributedString alloc] initWithString:title
                                                             attributes:@{NSFontAttributeName: font}];
                        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setAttributedTitle, attributedTitle);
                    }
                } else {
                    SEL setTitle = NSSelectorFromString(@"setTitle:");
                    if ([configuration respondsToSelector:setTitle]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setTitle, title);
                    }
                }
                SEL setBaseForeground = NSSelectorFromString(@"setBaseForegroundColor:");
                if (tintColor && [configuration respondsToSelector:setBaseForeground]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setBaseForeground, tintColor);
                }

                SEL setBaseBackground = NSSelectorFromString(@"setBaseBackgroundColor:");
                if ([configuration respondsToSelector:setBaseBackground]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setBaseBackground, zs_glass_tint_color());
                }
                SEL setConfig = NSSelectorFromString(@"setConfiguration:");
                if ([button respondsToSelector:setConfig]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, configuration);
                    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;

                    return;
                }
            }
        }
    }

    zs_clear_button_configuration(button);
    [button setTitle:title forState:UIControlStateNormal];
    if (tintColor) [button setTitleColor:tintColor forState:UIControlStateNormal];
    if (font) button.titleLabel.font = font;
    button.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    button.layer.cornerCurve = kCACornerCurveContinuous;

    button.layer.cornerRadius = 200;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static void zs_style_button_as_native_glass(UIButton *button, NSString *title, UIColor *tintColor) {
    zs_style_button_as_native_glass_with_font(button, title, tintColor, nil);
}

static void zs_style_button_as_liquid_glass_fallback_with_font(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font) {
    NSMutableParagraphStyle *paragraphStyle = [NSMutableParagraphStyle new];
    paragraphStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *titleAttributes = @{
        NSFontAttributeName: font ?: [UIFont systemFontOfSize:13],
        NSForegroundColorAttributeName: tintColor ?: UIColor.whiteColor,
        NSParagraphStyleAttributeName: paragraphStyle,
    };
    NSAttributedString *attributedTitle = [[NSAttributedString alloc] initWithString:title ?: @"" attributes:titleAttributes];
    [button setAttributedTitle:attributedTitle forState:UIControlStateNormal];
    [button setTitle:title forState:UIControlStateNormal];
    if (tintColor) [button setTitleColor:tintColor forState:UIControlStateNormal];
    if (font) button.titleLabel.font = font;
    button.tintColor = tintColor ?: UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.cornerRadius = 200;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static void zs_style_button_mirroring_glass_state(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font) {
    if (zs_has_liquid_glass()) {
        zs_style_button_as_native_glass_with_font(button, title, tintColor, font);
    } else {
        zs_style_button_as_liquid_glass_fallback_with_font(button, title, tintColor, font);
    }
}

static UIButton *zs_make_liquid_glass_fallback_twin(UIButton *primaryButton, NSString *title, UIColor *tintColor, UIFont *font) {
    UIButton *fallback = [UIButton buttonWithType:UIButtonTypeCustom];
    fallback.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_liquid_glass_fallback_with_font(fallback, title, tintColor, font);
    [primaryButton.superview addSubview:fallback];
    [NSLayoutConstraint activateConstraints:@[
        [fallback.leadingAnchor constraintEqualToAnchor:primaryButton.leadingAnchor],
        [fallback.trailingAnchor constraintEqualToAnchor:primaryButton.trailingAnchor],
        [fallback.topAnchor constraintEqualToAnchor:primaryButton.topAnchor],
        [fallback.bottomAnchor constraintEqualToAnchor:primaryButton.bottomAnchor],
    ]];
    BOOL hasGlass = zs_has_liquid_glass();
    primaryButton.hidden = !hasGlass;
    fallback.hidden = hasGlass;
    return fallback;
}

static void zs_style_button_as_solid_glass_with_font(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font) {
    if (zs_has_liquid_glass()) {
        Class configClass = NSClassFromString(@"UIButtonConfiguration");
        SEL prominentGlassSel = NSSelectorFromString(@"prominentGlassButtonConfiguration");
        SEL glassSel = NSSelectorFromString(@"glassButtonConfiguration");
        SEL configSel = [configClass respondsToSelector:prominentGlassSel] ? prominentGlassSel : glassSel;
        if (configClass && [configClass respondsToSelector:configSel]) {
            id configuration = ((id (*)(id, SEL))objc_msgSend)(configClass, configSel);
            if (configuration) {
                if (font) {
                    SEL setAttributedTitle = NSSelectorFromString(@"setAttributedTitle:");
                    if ([configuration respondsToSelector:setAttributedTitle]) {
                        NSAttributedString *attributedTitle =
                            [[NSAttributedString alloc] initWithString:title
                                                             attributes:@{NSFontAttributeName: font}];
                        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setAttributedTitle, attributedTitle);
                    }
                } else {
                    SEL setTitle = NSSelectorFromString(@"setTitle:");
                    if ([configuration respondsToSelector:setTitle]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setTitle, title);
                    }
                }
                SEL setBaseBackground = NSSelectorFromString(@"setBaseBackgroundColor:");
                if (tintColor && [configuration respondsToSelector:setBaseBackground]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setBaseBackground, tintColor);
                }
                SEL setBaseForeground = NSSelectorFromString(@"setBaseForegroundColor:");
                if ([configuration respondsToSelector:setBaseForeground]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setBaseForeground, [UIColor whiteColor]);
                }
                SEL setConfig = NSSelectorFromString(@"setConfiguration:");
                if ([button respondsToSelector:setConfig]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, configuration);
                    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
                    zs_configure_glass_button_fixed_corner_radius(button, 14);
                    return;
                }
            }
        }
    }

    zs_clear_button_configuration(button);
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    if (font) button.titleLabel.font = font;
    button.backgroundColor = tintColor;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.cornerRadius = 14;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static void zs_set_install_option_greyed_out(UIButton *button, BOOL greyedOut) {
    button.enabled = !greyedOut;
    button.alpha = greyedOut ? 0.4 : 1.0;
}

static void zs_style_pill_icon_button_as_native_glass(UIButton *button, UIImage *image, UIColor *tintColor) {
    if (zs_has_liquid_glass()) {
        Class configClass = NSClassFromString(@"UIButtonConfiguration");
        SEL glassSel = NSSelectorFromString(@"glassButtonConfiguration");
        if (configClass && [configClass respondsToSelector:glassSel]) {
            id configuration = ((id (*)(id, SEL))objc_msgSend)(configClass, glassSel);
            if (configuration) {
                SEL setImage = NSSelectorFromString(@"setImage:");
                if ([configuration respondsToSelector:setImage]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setImage, image);
                }
                SEL setBaseForeground = NSSelectorFromString(@"setBaseForegroundColor:");
                if (tintColor && [configuration respondsToSelector:setBaseForeground]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setBaseForeground, tintColor);
                }
                SEL setConfig = NSSelectorFromString(@"setConfiguration:");
                if ([button respondsToSelector:setConfig]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, configuration);
                    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
                    return;
                }
            }
        }
    }

    zs_clear_button_configuration(button);
    [button setImage:image forState:UIControlStateNormal];
    if (tintColor) button.tintColor = tintColor;
    button.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.cornerRadius = 200;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static UIImage *zs_mods_doctor_button_icon(NSString *sfSymbolName, CGFloat pointSize) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:sfSymbolName withConfiguration:config];
}

static void zs_style_icon_button_as_native_glass(UIButton *button, UIImage *image, UIColor *tintColor) {
    if (zs_has_liquid_glass()) {
        Class configClass = NSClassFromString(@"UIButtonConfiguration");
        SEL glassSel = NSSelectorFromString(@"glassButtonConfiguration");
        if (configClass && [configClass respondsToSelector:glassSel]) {
            id configuration = ((id (*)(id, SEL))objc_msgSend)(configClass, glassSel);
            if (configuration) {
                SEL setImage = NSSelectorFromString(@"setImage:");
                if ([configuration respondsToSelector:setImage]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setImage, image);
                }
                SEL setBaseForeground = NSSelectorFromString(@"setBaseForegroundColor:");
                if (tintColor && [configuration respondsToSelector:setBaseForeground]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(configuration, setBaseForeground, tintColor);
                }
                SEL setConfig = NSSelectorFromString(@"setConfiguration:");
                if ([button respondsToSelector:setConfig]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, configuration);
                    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
                    return;
                }
            }
        }
    }

    zs_clear_button_configuration(button);
    [button setImage:image forState:UIControlStateNormal];
    if (tintColor) button.tintColor = tintColor;
    button.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
    button.layer.cornerRadius = 9;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static void zs_style_auth_verify_button(UIButton *button, NSString *title) {
    zs_style_button_as_native_glass_with_font(button, title, zs_accent_green_color(), zs_mono_font(11, UIFontWeightSemibold));
}

static void zs_crossfade_auth_verify_button_title(UIButton *button, NSString *title) {
    [UIView transitionWithView:button
                       duration:0.2
                        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        zs_style_auth_verify_button(button, title);
    }
                     completion:nil];
}

static void zs_style_auth_remove_button(UIButton *button, NSString *title) {
    zs_style_button_as_native_glass_with_font(button, title, [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0], zs_mono_font(11, UIFontWeightSemibold));
}

static void zs_crossfade_auth_button_to_remove(UIButton *button) {
    [UIView transitionWithView:button
                       duration:0.2
                        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        zs_style_auth_remove_button(button, @"Remove");
    }
                     completion:nil];
}

static void zs_crossfade_auth_button_to_verify(UIButton *button) {
    [UIView transitionWithView:button
                       duration:0.2
                        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        zs_style_auth_verify_button(button, @"Verify");
    }
                     completion:nil];
}

static void zs_remove_tap_to_confirm(UIButton *button) {
    [button removeTarget:nil action:@selector(zs_handleTapToConfirm:) forControlEvents:UIControlEventTouchUpInside];
}

static void * const kZSHoldConfirmBlockKey = (void *)&kZSHoldConfirmBlockKey;

static void * const kZSHoldConfirmExpansionViewKey = (void *)&kZSHoldConfirmExpansionViewKey;
static void * const kZSHoldConfirmExpansionWidthKey = (void *)&kZSHoldConfirmExpansionWidthKey;
static void * const kZSHoldConfirmDeleteLabelKey = (void *)&kZSHoldConfirmDeleteLabelKey;
static void * const kZSHoldConfirmExpansionFillKey = (void *)&kZSHoldConfirmExpansionFillKey;
static void * const kZSHoldConfirmButtonFillKey = (void *)&kZSHoldConfirmButtonFillKey;

static void * const kZSHoldConfirmGlassViewKey = (void *)&kZSHoldConfirmGlassViewKey;
static void * const kZSHoldConfirmGlassHostKey = (void *)&kZSHoldConfirmGlassHostKey;

static const CGFloat kZSDeleteCapsuleExpandedWidth = 60;
static const NSTimeInterval kZSDeleteCapsuleSnapDuration = 0.28;
static const CGFloat kZSDeleteCapsuleSpringDamping = 0.6;
static const CGFloat kZSDeleteCapsuleSpringVelocity = 0.4;

static void zs_attach_delete_capsule(UIButton *button, UIView *parent, UIView *glassHost) {
    if (!parent) return;

    if (zs_has_liquid_glass() && glassHost) {

        UIVisualEffect *effect = zs_make_glass_effect_style(0 , YES,
                                                              [UIColor colorWithRed:1.0 green:0.12 blue:0.12 alpha:0.22]);
        UIVisualEffectView *capsuleGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
        capsuleGlass.userInteractionEnabled = NO;
        capsuleGlass.opaque = NO;
        capsuleGlass.clipsToBounds = YES;
        capsuleGlass.layer.cornerCurve = kCACornerCurveContinuous;
        capsuleGlass.alpha = 0;
        [glassHost addSubview:capsuleGlass];
        zs_configure_glass_corners(capsuleGlass, 9, NO);
        zs_register_suspendable_glass(capsuleGlass);
        objc_setAssociatedObject(button, kZSHoldConfirmGlassViewKey, capsuleGlass, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(button, kZSHoldConfirmGlassHostKey, glassHost, OBJC_ASSOCIATION_RETAIN);
    }

    UIView *expansion = [[UIView alloc] init];
    expansion.translatesAutoresizingMaskIntoConstraints = NO;
    expansion.clipsToBounds = YES;
    expansion.userInteractionEnabled = NO;
    expansion.layer.cornerCurve = kCACornerCurveContinuous;
    [parent addSubview:expansion];

    [parent bringSubviewToFront:expansion];
    parent.clipsToBounds = NO;

    UILabel *deleteLabel = [[UILabel alloc] init];
    deleteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    deleteLabel.text = @"Delete";
    deleteLabel.font = zs_mono_font(11, UIFontWeightSemibold);
    deleteLabel.textColor = [UIColor whiteColor];
    deleteLabel.alpha = 0;
    [expansion addSubview:deleteLabel];

    CALayer *expansionFill = [CALayer layer];
    expansionFill.backgroundColor = [UIColor colorWithRed:1.0 green:0.08 blue:0.08 alpha:0.85].CGColor;
    expansionFill.anchorPoint = CGPointMake(0, 0);
    expansionFill.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    expansionFill.cornerCurve = kCACornerCurveContinuous;
    [expansion.layer insertSublayer:expansionFill atIndex:0];

    CALayer *buttonFill = [CALayer layer];
    buttonFill.backgroundColor = expansionFill.backgroundColor;
    buttonFill.anchorPoint = CGPointMake(0, 0);
    buttonFill.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    buttonFill.cornerCurve = kCACornerCurveContinuous;

    [button.layer insertSublayer:buttonFill atIndex:0];

    NSLayoutConstraint *widthConstraint = [expansion.widthAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [expansion.trailingAnchor constraintEqualToAnchor:button.leadingAnchor],
        [expansion.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [expansion.heightAnchor constraintEqualToAnchor:button.heightAnchor],
        widthConstraint,

        [deleteLabel.centerYAnchor constraintEqualToAnchor:expansion.centerYAnchor],
        [deleteLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:expansion.leadingAnchor constant:8],
        [deleteLabel.trailingAnchor constraintLessThanOrEqualToAnchor:expansion.trailingAnchor constant:-4],
    ]];

    objc_setAssociatedObject(button, kZSHoldConfirmExpansionViewKey, expansion, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kZSHoldConfirmExpansionWidthKey, widthConstraint, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kZSHoldConfirmDeleteLabelKey, deleteLabel, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kZSHoldConfirmExpansionFillKey, expansionFill, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kZSHoldConfirmButtonFillKey, buttonFill, OBJC_ASSOCIATION_RETAIN);
}

static void zs_attach_hold_to_confirm(UIButton *button, id target, UIView *glassHost, void (^onConfirm)(void)) {
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(zs_handleHoldToConfirmGesture:)];
    press.minimumPressDuration = 0;
    press.cancelsTouchesInView = NO;
    [button addGestureRecognizer:press];
    objc_setAssociatedObject(button, kZSHoldConfirmBlockKey, [onConfirm copy], OBJC_ASSOCIATION_COPY);
    zs_attach_delete_capsule(button, button.superview, glassHost);
}

static void * const kZSTapConfirmTitleKey = (void *)&kZSTapConfirmTitleKey;
static void * const kZSTapConfirmMessageKey = (void *)&kZSTapConfirmMessageKey;
static void * const kZSTapConfirmActionTitleKey = (void *)&kZSTapConfirmActionTitleKey;
static void * const kZSTapConfirmDestructiveKey = (void *)&kZSTapConfirmDestructiveKey;
static void * const kZSTapConfirmBlockKey = (void *)&kZSTapConfirmBlockKey;

static void zs_attach_tap_to_confirm(UIButton *button, id target,
                                      NSString *title, NSString *message, NSString *actionTitle,
                                      BOOL destructive, void (^onConfirm)(void)) {
    zs_remove_tap_to_confirm(button);
    objc_setAssociatedObject(button, kZSTapConfirmTitleKey, title, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(button, kZSTapConfirmMessageKey, message, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(button, kZSTapConfirmActionTitleKey, actionTitle, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(button, kZSTapConfirmDestructiveKey, @(destructive), OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(button, kZSTapConfirmBlockKey, [onConfirm copy], OBJC_ASSOCIATION_COPY);
    [button addTarget:target action:@selector(zs_handleTapToConfirm:) forControlEvents:UIControlEventTouchUpInside];
}

#pragma mark - Engine scripts

#pragma mark - Capsule slider (Control Center / Now Playing style)

static const CGFloat kCapsuleSliderHeight = 18;
static const CGFloat kCapsuleSliderThinHeight = 6;
static const CGFloat kCapsuleSliderFatHeight = 18;
static const CGFloat kDefaultSnapFraction = 0.035;

@interface ZSFillView : UIView
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign, getter=isTrailingSquared) BOOL trailingSquared;
- (void)zs_beginLiveMaskResync;
- (void)zs_endLiveMaskResync;
@end

@implementation ZSFillView {
    CAShapeLayer *_maskLayer;
    CADisplayLink *_liveResyncLink;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _maskLayer = [CAShapeLayer new];
        self.layer.mask = _maskLayer;

        zs_apply_gif_view_tint(self);
    }
    return self;
}

- (void)dealloc {
    [_liveResyncLink invalidate];
    zs_remove_gif_view_tint(self);
}

- (UIBezierPath *)zs_pathForBounds:(CGRect)bounds squaredTrailing:(BOOL)squared {
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return [UIBezierPath bezierPath];
    CGFloat r = MIN(self.cornerRadius, bounds.size.height / 2.0);
    UIRectCorner corners = squared ? (UIRectCornerTopLeft | UIRectCornerBottomLeft) : UIRectCornerAllCorners;
    return [UIBezierPath bezierPathWithRoundedRect:bounds byRoundingCorners:corners cornerRadii:CGSizeMake(r, r)];
}

- (void)zs_applyMaskForBounds:(CGRect)bounds {
    UIBezierPath *path = [self zs_pathForBounds:bounds squaredTrailing:self.trailingSquared];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _maskLayer.frame = bounds;
    _maskLayer.path = path.CGPath;
    zs_refresh_gif_view_tint(self, bounds);
    [CATransaction commit];
}

- (void)zs_applyMask {
    [self zs_applyMaskForBounds:self.bounds];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_liveResyncLink) return;
    [self zs_applyMask];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    if (_cornerRadius == cornerRadius) return;
    _cornerRadius = cornerRadius;
    if (!_liveResyncLink) [self zs_applyMask];
}

- (void)setTrailingSquared:(BOOL)squared {
    if (_trailingSquared == squared) return;
    _trailingSquared = squared;
    if (!_liveResyncLink) [self zs_applyMask];
}

#pragma mark - Live (presentation-layer-driven) resync for animated resizes

- (void)zs_beginLiveMaskResync {
    [_liveResyncLink invalidate];
    _liveResyncLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_liveMaskResyncTick)];
    [_liveResyncLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)zs_endLiveMaskResync {
    [_liveResyncLink invalidate];
    _liveResyncLink = nil;
    [self zs_applyMask];
}

- (void)zs_liveMaskResyncTick {
    CALayer *presentation = (CALayer *)self.layer.presentationLayer ?: self.layer;
    [self zs_applyMaskForBounds:presentation.bounds];
}

@end

#pragma mark - Pie chart

@interface ZSPieChartView : UIView
- (void)setSlicesWithFractions:(NSArray<NSNumber *> *)fractions colors:(NSArray<UIColor *> *)colors;
@end

@implementation ZSPieChartView {
    NSArray<NSNumber *> *_fractions;
    NSArray<UIColor *> *_colors;
    NSMutableArray<CAShapeLayer *> *_sliceLayers;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _sliceLayers = [NSMutableArray new];
        self.backgroundColor = UIColor.clearColor;
    }
    return self;
}

- (void)setSlicesWithFractions:(NSArray<NSNumber *> *)fractions colors:(NSArray<UIColor *> *)colors {
    _fractions = [fractions copy];
    _colors = [colors copy];
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self zs_rebuildSliceLayers];
}

- (void)zs_rebuildSliceLayers {
    for (CAShapeLayer *layer in _sliceLayers) {
        [layer removeFromSuperlayer];
    }
    [_sliceLayers removeAllObjects];

    if (_fractions.count == 0 || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;

    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) / 2.0;
    CGFloat startAngle = -M_PI_2;

    for (NSUInteger i = 0; i < _fractions.count; i++) {
        CGFloat sweep = _fractions[i].doubleValue * 2.0 * M_PI;
        CGFloat endAngle = startAngle + sweep;

        UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:center radius:radius startAngle:startAngle endAngle:endAngle clockwise:YES];
        [path addLineToPoint:center];
        [path closePath];

        CAShapeLayer *slice = [CAShapeLayer new];
        slice.path = path.CGPath;
        slice.fillColor = (i < _colors.count ? _colors[i] : UIColor.grayColor).CGColor;
        slice.strokeColor = [UIColor colorWithWhite:0.07 alpha:1].CGColor;
        slice.lineWidth = 1.5;
        [self.layer addSublayer:slice];
        [_sliceLayers addObject:slice];

        startAngle = endAngle;
    }
}

@end

@interface ZSCapsuleSlider : UIControl
@property (nonatomic, assign) float minimumValue;
@property (nonatomic, assign) float maximumValue;
@property (nonatomic, assign) float value;
@property (nonatomic, strong) UIColor *fillColor;
@property (nonatomic, assign) float defaultValue;
@property (nonatomic, assign) BOOL hasDefaultValue;
@property (nonatomic, assign) float step;

@property (nonatomic, copy) NSArray<NSNumber *> *indicatorValues;
@end

@interface ZSCapsuleSlider ()
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) ZSFillView *fill;
@property (nonatomic, strong) UIView *defaultTick;
@property (nonatomic, strong) NSMutableArray<UIView *> *indicatorTicks;
@property (nonatomic, strong) NSLayoutConstraint *fillWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *trackHeightConstraint;
@property (nonatomic, assign) BOOL touching;

@property (nonatomic, assign) float liveDragValue;
@property (nonatomic, strong) UIVisualEffectView *trackGlass;
@property (nonatomic, assign) BOOL glassEnabled;
@end

@implementation ZSCapsuleSlider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _minimumValue = 0;
        _maximumValue = 1;
        _value = 0;
        _fillColor = zs_bar_fill_color();
        _hasDefaultValue = NO;
        _step = 0;
        _indicatorTicks = [NSMutableArray new];

        self.track = [[UIView alloc] init];
        self.track.translatesAutoresizingMaskIntoConstraints = NO;
        if (zs_has_liquid_glass()) {
            self.track.backgroundColor = UIColor.clearColor;
        } else {
            self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
            self.track.layer.borderWidth = 1;
            self.track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        }
        self.track.userInteractionEnabled = NO;
        self.track.layer.cornerCurve = kCACornerCurveContinuous;
        self.track.clipsToBounds = YES;
        [self addSubview:self.track];

        self.fill = [[ZSFillView alloc] init];
        self.fill.translatesAutoresizingMaskIntoConstraints = NO;
        self.fill.backgroundColor = [_fillColor colorWithAlphaComponent:1.0];
        self.fill.userInteractionEnabled = NO;
        [self.track addSubview:self.fill];

        [NSLayoutConstraint activateConstraints:@[
            [self.track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.track.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [self.fill.leadingAnchor constraintEqualToAnchor:self.track.leadingAnchor],
            [self.fill.topAnchor constraintEqualToAnchor:self.track.topAnchor],
            [self.fill.bottomAnchor constraintEqualToAnchor:self.track.bottomAnchor],
        ]];
        self.trackHeightConstraint = [self.track.heightAnchor constraintEqualToConstant:kCapsuleSliderThinHeight];
        self.trackHeightConstraint.active = YES;
        self.fillWidthConstraint = [self.fill.widthAnchor constraintEqualToConstant:0];
        self.fillWidthConstraint.active = YES;

        self.defaultTick = [[UIView alloc] init];
        self.defaultTick.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        self.defaultTick.userInteractionEnabled = NO;
        self.defaultTick.hidden = YES;
        [self addSubview:self.defaultTick];

        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        press.minimumPressDuration = 0;
        [self addGestureRecognizer:press];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.trackHeightConstraint.constant;
    self.track.layer.cornerRadius = h / 2.0;
    self.fill.cornerRadius = h / 2.0;
    if (@available(iOS 13.0, *)) {
        self.track.layer.cornerCurve = kCACornerCurveContinuous;
    }
    if (self.trackGlass) {
        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);
        self.trackGlass.layer.cornerRadius = h / 2.0;
        self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [self updateFillForCurrentValue];
    [self updateDefaultTickPosition];
    [self updateIndicatorTickPositions];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, kCapsuleSliderHeight);
}

- (void)setValue:(float)value {
    float clamped = MAX(self.minimumValue, MIN(self.maximumValue, value));
    if (self.step > 0) {
        clamped = self.minimumValue + roundf((clamped - self.minimumValue) / self.step) * self.step;
        clamped = MAX(self.minimumValue, MIN(self.maximumValue, clamped));
    }
    _value = clamped;
    [self updateFillForCurrentValue];
}

- (void)setStep:(float)step {
    _step = step;
    self.value = self.value;
}

- (void)setMinimumValue:(float)minimumValue {
    _minimumValue = minimumValue;
    [self updateFillForCurrentValue];
    [self updateDefaultTickPosition];
    [self updateIndicatorTickPositions];
}

- (void)setMaximumValue:(float)maximumValue {
    _maximumValue = maximumValue;
    [self updateFillForCurrentValue];
    [self updateDefaultTickPosition];
    [self updateIndicatorTickPositions];
}

- (void)setIndicatorValues:(NSArray<NSNumber *> *)indicatorValues {
    _indicatorValues = [indicatorValues copy];
    for (UIView *tick in self.indicatorTicks) [tick removeFromSuperview];
    [self.indicatorTicks removeAllObjects];
    for (NSUInteger i = 0; i < _indicatorValues.count; i++) {
        UIView *tick = [[UIView alloc] init];
        tick.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        tick.userInteractionEnabled = NO;
        [self addSubview:tick];
        [self.indicatorTicks addObject:tick];
    }
    [self updateIndicatorTickPositions];
}

- (void)setDefaultValue:(float)defaultValue {
    if (self.step > 0) {
        defaultValue = self.minimumValue + roundf((defaultValue - self.minimumValue) / self.step) * self.step;
    }
    _defaultValue = defaultValue;
    [self updateDefaultTickPosition];
    [self updateFillForCurrentValue];
}

- (void)setHasDefaultValue:(BOOL)hasDefaultValue {
    _hasDefaultValue = hasDefaultValue;
    [self updateDefaultTickPosition];
    [self updateFillForCurrentValue];
}

static const float kDefaultValueEpsilon = 0.0005f;

- (void)updateFillForCurrentValue {
    CGFloat range = self.maximumValue - self.minimumValue;

    float displayValue = self.touching ? self.liveDragValue : self.value;
    CGFloat fraction = range > 0 ? (displayValue - self.minimumValue) / range : 0;
    fraction = MAX(0, MIN(1, fraction));
    self.fillWidthConstraint.constant = self.bounds.size.width * fraction;

    BOOL atSquaringPoint = self.hasDefaultValue &&
        self.defaultValue > self.minimumValue && self.defaultValue < self.maximumValue &&
        fabsf(self.value - self.defaultValue) <= kDefaultValueEpsilon;
    if (!atSquaringPoint) {
        for (NSNumber *indicatorNumber in self.indicatorValues) {
            float indicatorValue = indicatorNumber.floatValue;
            if (indicatorValue > self.minimumValue && indicatorValue < self.maximumValue &&
                fabsf(self.value - indicatorValue) <= kDefaultValueEpsilon) {
                atSquaringPoint = YES;
                break;
            }
        }
    }
    self.fill.trailingSquared = atSquaringPoint;
    [self.fill setNeedsLayout];
    [self.fill layoutIfNeeded];
}

static const CGFloat kDefaultTickWidth = 1;
static const CGFloat kDefaultTickHeight = 4;
static const CGFloat kDefaultTickGap = 3;

- (void)updateDefaultTickPosition {
    if (self.bounds.size.width <= 0) return;

    self.defaultTick.hidden = !self.hasDefaultValue;
    if (self.defaultTick.hidden) return;

    CGFloat range = self.maximumValue - self.minimumValue;
    CGFloat fraction = range > 0 ? (self.defaultValue - self.minimumValue) / range : 0;
    fraction = MAX(0, MIN(1, fraction));
    CGFloat x = self.bounds.size.width * fraction - (kDefaultTickWidth / 2.0);
    x = MAX(0, MIN(self.bounds.size.width - kDefaultTickWidth, x));

    CGFloat trackTop = CGRectGetMinY(self.track.frame);
    CGFloat y = trackTop - kDefaultTickGap - kDefaultTickHeight;
    self.defaultTick.frame = CGRectMake(x, y, kDefaultTickWidth, kDefaultTickHeight);
    self.defaultTick.layer.cornerRadius = kDefaultTickWidth / 2.0;
}

- (void)updateIndicatorTickPositions {
    if (self.bounds.size.width <= 0 || self.indicatorTicks.count == 0) return;

    CGFloat range = self.maximumValue - self.minimumValue;
    CGFloat trackTop = CGRectGetMinY(self.track.frame);
    CGFloat y = trackTop - kDefaultTickGap - kDefaultTickHeight;

    for (NSUInteger i = 0; i < self.indicatorTicks.count; i++) {
        float indicatorValue = self.indicatorValues[i].floatValue;
        CGFloat fraction = range > 0 ? (indicatorValue - self.minimumValue) / range : 0;
        fraction = MAX(0, MIN(1, fraction));
        CGFloat x = self.bounds.size.width * fraction - (kDefaultTickWidth / 2.0);
        x = MAX(0, MIN(self.bounds.size.width - kDefaultTickWidth, x));

        UIView *tick = self.indicatorTicks[i];
        tick.frame = CGRectMake(x, y, kDefaultTickWidth, kDefaultTickHeight);
        tick.layer.cornerRadius = kDefaultTickWidth / 2.0;
    }
}

static const CGFloat kFillAlpha = 1.0;

- (void)setGlassEnabled:(BOOL)glassEnabled {
    if (!zs_has_liquid_glass()) {
        _glassEnabled = NO;
        [self.trackGlass removeFromSuperview];
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.layer.borderWidth = 1;
        self.track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        self.fill.backgroundColor = [self.fillColor colorWithAlphaComponent:kFillAlpha];
        return;
    }

    _glassEnabled = glassEnabled;

    if (glassEnabled) {
        self.track.backgroundColor = UIColor.clearColor;
        self.track.layer.borderWidth = 0;
        if (!self.trackGlass) {
            UIVisualEffect *effect = zs_make_glass_effect(self.touching);
            self.trackGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
            self.trackGlass.translatesAutoresizingMaskIntoConstraints = NO;
            self.trackGlass.userInteractionEnabled = NO;
            self.trackGlass.opaque = NO;
            self.trackGlass.clipsToBounds = YES;
            self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;
        }

        if (self.trackGlass.superview != self.track) {
            [self.trackGlass removeFromSuperview];
            [self.track addSubview:self.trackGlass];
            [NSLayoutConstraint activateConstraints:@[
                [self.trackGlass.leadingAnchor constraintEqualToAnchor:self.track.leadingAnchor],
                [self.trackGlass.trailingAnchor constraintEqualToAnchor:self.track.trailingAnchor],
                [self.trackGlass.topAnchor constraintEqualToAnchor:self.track.topAnchor],
                [self.trackGlass.bottomAnchor constraintEqualToAnchor:self.track.bottomAnchor],
            ]];
        }

        CGFloat h = self.trackHeightConstraint.constant;
        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);

        self.fill.backgroundColor = [self.fillColor colorWithAlphaComponent:kFillAlpha];
        [self.track sendSubviewToBack:self.trackGlass];
        [self.trackGlass setNeedsLayout];
        [self.trackGlass layoutIfNeeded];
    } else {
        [self.trackGlass removeFromSuperview];
        self.fill.backgroundColor = [self.fillColor colorWithAlphaComponent:kFillAlpha];
    }
}

- (void)setPillTouching:(BOOL)touching {
    if (self.touching == touching) return;
    self.touching = touching;
    self.trackHeightConstraint.constant = touching ? kCapsuleSliderFatHeight : kCapsuleSliderThinHeight;
    zs_set_track_glass_interactive(self.trackGlass, touching);

    [self.fill zs_beginLiveMaskResync];
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.6
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [self layoutIfNeeded];
        if (!touching) {

            [self updateFillForCurrentValue];
        }
     } completion:^(BOOL finished) {
        [self.fill zs_endLiveMaskResync];
        if (touching) {
            [self updateFillForCurrentValue];
        }
        [self updateDefaultTickPosition];
    }];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:touching ? UIImpactFeedbackStyleLight : UIImpactFeedbackStyleSoft];
    [haptic impactOccurred];
}

- (void)setValueFromLocation:(CGPoint)location sendActions:(BOOL)send {
    CGFloat fraction = self.bounds.size.width > 0 ? location.x / self.bounds.size.width : 0;
    BOOL clampedAtEdge = (fraction <= 0 || fraction >= 1);
    fraction = MAX(0, MIN(1, fraction));
    float previous = self.value;
    float rawValue = self.minimumValue + fraction * (self.maximumValue - self.minimumValue);

    BOOL snapped = NO;
    CGFloat range = self.maximumValue - self.minimumValue;
    if (range > 0) {
        CGFloat threshold = range * kDefaultSnapFraction;
        BOOL haveCandidate = NO;
        float bestCandidate = 0;
        CGFloat bestDistance = 0;
        if (self.hasDefaultValue) {
            CGFloat distance = fabsf(rawValue - self.defaultValue);
            if (distance <= threshold) {
                haveCandidate = YES;
                bestDistance = distance;
                bestCandidate = self.defaultValue;
            }
        }
        for (NSNumber *indicatorNumber in self.indicatorValues) {
            float indicatorValue = indicatorNumber.floatValue;
            CGFloat distance = fabsf(rawValue - indicatorValue);
            if (distance <= threshold && (!haveCandidate || distance < bestDistance)) {
                haveCandidate = YES;
                bestDistance = distance;
                bestCandidate = indicatorValue;
            }
        }
        if (haveCandidate) {
            rawValue = bestCandidate;
            snapped = (previous != rawValue);
        }
    }

    self.liveDragValue = rawValue;
    self.value = rawValue;

    if (snapped) {
        UISelectionFeedbackGenerator *snapHaptic = [UISelectionFeedbackGenerator new];
        [snapHaptic selectionChanged];
    } else if (clampedAtEdge && self.value != previous) {
        UISelectionFeedbackGenerator *edgeHaptic = [UISelectionFeedbackGenerator new];
        [edgeHaptic selectionChanged];
    }

    if (send) [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:self];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:

            [self setPillTouching:YES];
            [self setValueFromLocation:location sendActions:YES];
            break;
        case UIGestureRecognizerStateChanged:
            [self setValueFromLocation:location sendActions:YES];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self setPillTouching:NO];
            break;
        default:
            break;
    }
}

@end

#pragma mark - Mode slider (segmented, preset-value control)

@interface ZSModeSlider : UIControl
@property (nonatomic, copy) NSArray<NSString *> *labels;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) NSInteger defaultIndex;
@property (nonatomic, strong) UIColor *fillColor;
- (void)setSelectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated;
@end

@interface ZSModeSlider ()
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *thumb;
@property (nonatomic, strong) UIView *defaultIndicator;
@property (nonatomic, strong) NSMutableArray<UILabel *> *segmentLabels;
@property (nonatomic, strong) UIVisualEffectView *trackGlass;
@property (nonatomic, assign) BOOL glassEnabled;
- (void)zs_forceLabelRedisplay;
- (void)zs_applySegmentLabelColors;
@end

@implementation ZSModeSlider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _selectedIndex = 0;
        _defaultIndex = -1;
        _fillColor = zs_bar_fill_color();
        _segmentLabels = [NSMutableArray new];

        self.track = [[UIView alloc] init];
        self.track.translatesAutoresizingMaskIntoConstraints = NO;
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.userInteractionEnabled = NO;
        self.track.layer.cornerCurve = kCACornerCurveContinuous;
        self.track.layer.borderWidth = 1;
        self.track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        self.track.clipsToBounds = YES;
        [self addSubview:self.track];

        self.thumb = [[UIView alloc] init];
        self.thumb.backgroundColor = [_fillColor colorWithAlphaComponent:1.0];
        self.thumb.userInteractionEnabled = NO;
        self.thumb.layer.cornerCurve = kCACornerCurveContinuous;
        [self.track addSubview:self.thumb];
        zs_apply_gif_view_tint(self.thumb);

        self.defaultIndicator = [[UIView alloc] init];
        self.defaultIndicator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        self.defaultIndicator.userInteractionEnabled = NO;
        self.defaultIndicator.hidden = YES;
        [self addSubview:self.defaultIndicator];

        [NSLayoutConstraint activateConstraints:@[
            [self.track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.track.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.track.heightAnchor constraintEqualToConstant:kCapsuleSliderHeight],
        ]];

        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        press.minimumPressDuration = 0;
        [self addGestureRecognizer:press];
    }
    return self;
}

- (void)dealloc {
    zs_remove_gif_view_tint(self.thumb);
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, kCapsuleSliderHeight);
}

- (void)setGlassEnabled:(BOOL)glassEnabled {
    if (!zs_has_liquid_glass()) {
        _glassEnabled = NO;
        [self.trackGlass removeFromSuperview];
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.layer.borderWidth = 1;
        return;
    }

    _glassEnabled = glassEnabled;

    if (glassEnabled) {
        if (!self.trackGlass) {
            UIVisualEffect *effect = zs_make_glass_effect(NO);
            self.trackGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
            self.trackGlass.translatesAutoresizingMaskIntoConstraints = NO;
            self.trackGlass.userInteractionEnabled = NO;
            self.trackGlass.opaque = NO;
            self.trackGlass.clipsToBounds = YES;
            self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;
        }

        if (self.trackGlass.superview != self.track) {
            [self.trackGlass removeFromSuperview];
            [self.track addSubview:self.trackGlass];
            [NSLayoutConstraint activateConstraints:@[
                [self.trackGlass.leadingAnchor constraintEqualToAnchor:self.track.leadingAnchor],
                [self.trackGlass.trailingAnchor constraintEqualToAnchor:self.track.trailingAnchor],
                [self.trackGlass.topAnchor constraintEqualToAnchor:self.track.topAnchor],
                [self.trackGlass.bottomAnchor constraintEqualToAnchor:self.track.bottomAnchor],
            ]];
        }

        CGFloat h = self.track.bounds.size.height > 0 ? self.track.bounds.size.height : kCapsuleSliderHeight;
        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);

        self.track.backgroundColor = UIColor.clearColor;
        self.track.layer.borderWidth = 0;
        [self.track sendSubviewToBack:self.trackGlass];
        [self.trackGlass setNeedsLayout];
        [self.trackGlass layoutIfNeeded];
    } else {
        [self.trackGlass removeFromSuperview];
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.layer.borderWidth = 1;
    }
}

- (void)setLabels:(NSArray<NSString *> *)labels {
    _labels = [labels copy];
    for (UILabel *l in self.segmentLabels) [l removeFromSuperview];
    [self.segmentLabels removeAllObjects];
    for (NSString *text in _labels) {
        UILabel *l = [[UILabel alloc] init];
        l.text = text;
        l.textAlignment = NSTextAlignmentCenter;
        l.font = zs_mono_font(9, UIFontWeightBold);
        l.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        l.userInteractionEnabled = NO;
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.7;
        l.layer.zPosition = 10;
        [self.track addSubview:l];
        [self.segmentLabels addObject:l];
    }
    [self zs_applySegmentLabelColors];
    [self setNeedsLayout];
}

- (void)zs_applySegmentLabelColors {
    NSInteger count = (NSInteger)self.segmentLabels.count;
    if (count == 0) return;
    NSInteger clampedIndex = MAX(0, MIN(count - 1, self.selectedIndex));
    for (NSInteger i = 0; i < count; i++) {
        UILabel *l = self.segmentLabels[i];
        UIColor *color = (i == clampedIndex) ? UIColor.blackColor : [UIColor colorWithWhite:1 alpha:0.6];
        l.textColor = color;
    }
}

- (void)setDefaultIndex:(NSInteger)defaultIndex {
    _defaultIndex = defaultIndex;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.track.bounds.size.height > 0 ? self.track.bounds.size.height : kCapsuleSliderHeight;
    self.track.layer.cornerRadius = h / 2.0;
    self.thumb.layer.cornerRadius = MAX(0, (h / 2.0) - 2);

    if (self.trackGlass) {

        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);
        self.trackGlass.layer.cornerRadius = h / 2.0;
        self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;
    }

    NSInteger count = (NSInteger)self.labels.count;
    if (count == 0) {
        self.defaultIndicator.hidden = YES;
        return;
    }
    CGFloat segmentWidth = self.track.bounds.size.width / (CGFloat)count;

    NSInteger clampedIndex = MAX(0, MIN(count - 1, self.selectedIndex));
    for (NSInteger i = 0; i < count; i++) {
        UILabel *l = self.segmentLabels[i];
        l.frame = CGRectMake(segmentWidth * i, 0, segmentWidth, self.track.bounds.size.height);
        [self.track bringSubviewToFront:l];
    }
    [self zs_applySegmentLabelColors];

    self.thumb.frame = CGRectMake(segmentWidth * clampedIndex + 2, 2, MAX(0, segmentWidth - 4), MAX(0, self.track.bounds.size.height - 4));
    if (self.trackGlass) [self.track sendSubviewToBack:self.trackGlass];
    if (self.trackGlass) [self.track insertSubview:self.thumb aboveSubview:self.trackGlass];
    zs_refresh_gif_view_tint(self.thumb, self.thumb.bounds);

    BOOL hasDefault = self.defaultIndex >= 0 && self.defaultIndex < count;
    self.defaultIndicator.hidden = !hasDefault;
    if (hasDefault) {
        CGFloat length = kDefaultTickHeight * 1.75;
        CGFloat thickness = kDefaultTickWidth;
        CGFloat centerX = segmentWidth * self.defaultIndex + segmentWidth / 2.0;
        CGFloat x = centerX - length / 2.0;
        x = MAX(0, MIN(self.bounds.size.width - length, x));
        CGFloat trackTop = CGRectGetMinY(self.track.frame);
        CGFloat y = trackTop - kDefaultTickGap - thickness;
        self.defaultIndicator.frame = CGRectMake(x, y, length, thickness);
        self.defaultIndicator.layer.cornerRadius = thickness / 2.0;
    }
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    [self setSelectedIndex:selectedIndex animated:NO];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated {
    NSInteger count = (NSInteger)self.labels.count;
    if (count == 0) { _selectedIndex = 0; return; }
    selectedIndex = MAX(0, MIN(count - 1, selectedIndex));
    _selectedIndex = selectedIndex;
    [self zs_applySegmentLabelColors];
    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.3
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            [self setNeedsLayout];
            [self layoutIfNeeded];
        } completion:nil];
    } else {
        [self setNeedsLayout];
    }
}

- (void)selectIndexForLocation:(CGPoint)location sendActions:(BOOL)send {
    NSInteger count = (NSInteger)self.labels.count;
    if (count == 0 || self.bounds.size.width <= 0) return;
    CGFloat segmentWidth = self.bounds.size.width / (CGFloat)count;
    NSInteger idx = (NSInteger)floorf(location.x / MAX((CGFloat)1, segmentWidth));
    idx = MAX(0, MIN(count - 1, idx));
    if (idx != self.selectedIndex) {
        [self setSelectedIndex:idx animated:YES];
        UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
        [haptic selectionChanged];
        if (send) [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:self];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            zs_set_track_glass_interactive(self.trackGlass, YES);
            [self selectIndexForLocation:location sendActions:YES];
            break;
        case UIGestureRecognizerStateChanged:
            [self selectIndexForLocation:location sendActions:YES];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            zs_set_track_glass_interactive(self.trackGlass, NO);
            break;
        default:
            break;
    }
}

- (void)zs_forceLabelRedisplay {
    [self setNeedsLayout];
    [self layoutIfNeeded];
    for (UILabel *l in self.segmentLabels) {
        [l setNeedsDisplay];
        [l.layer setNeedsDisplay];
    }
}

@end

#pragma mark - Wheel picker control

@interface ZSWheelPicker : UIControl
@property (nonatomic, copy) NSArray<NSString *> *labels;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) NSInteger defaultIndex;
@property (nonatomic, strong) UIColor *fillColor;
- (void)setSelectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated;
@end

@interface ZSWheelPicker ()
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *selectionPill;
@property (nonatomic, strong) UIView *defaultIndicator;
@property (nonatomic, strong) CAGradientLayer *edgeFadeMask;
@property (nonatomic, strong) NSMutableArray<CATextLayer *> *itemLabels;
@property (nonatomic, strong) UIView *itemLayerHost;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *itemCenters;
@property (nonatomic, assign) CGFloat contentCenterX;
@property (nonatomic, assign) CGFloat dragStartCenterX;
@property (nonatomic, strong) UIVisualEffectView *trackGlass;
@property (nonatomic, assign) BOOL glassEnabled;
@property (nonatomic, assign) NSInteger itemCount;
@property (nonatomic, assign) CGFloat cycleWidth;
- (NSInteger)nearestIndexForContentCenterX:(CGFloat)cx;
- (NSInteger)nearestAbsoluteIndexForLogicalIndex:(NSInteger)logicalIndex;
- (void)recentreIfNeeded;
- (void)zs_forceLabelRedisplay;
@end

@implementation ZSWheelPicker

static const CGFloat kWheelItemHPadding = 14;
static const CGFloat kWheelItemGap = 8;
static const NSInteger kZSWheelLoopCopies = 9;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _selectedIndex = 0;
        _defaultIndex = -1;
        _fillColor = zs_bar_fill_color();
        _itemLabels = [NSMutableArray new];
        _itemCenters = [NSMutableArray new];

        self.track = [[UIView alloc] init];
        self.track.translatesAutoresizingMaskIntoConstraints = NO;
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.userInteractionEnabled = NO;
        self.track.layer.cornerCurve = kCACornerCurveContinuous;
        self.track.layer.borderWidth = 1;
        self.track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        self.track.clipsToBounds = YES;
        [self addSubview:self.track];

        self.selectionPill = [[UIView alloc] init];
        self.selectionPill.backgroundColor = [_fillColor colorWithAlphaComponent:1.0];
        self.selectionPill.userInteractionEnabled = NO;
        self.selectionPill.layer.cornerCurve = kCACornerCurveContinuous;
        [self.track addSubview:self.selectionPill];
        zs_apply_gif_view_tint(self.selectionPill);

        self.defaultIndicator = [[UIView alloc] init];
        self.defaultIndicator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        self.defaultIndicator.userInteractionEnabled = NO;
        self.defaultIndicator.hidden = YES;
        [self addSubview:self.defaultIndicator];

        [NSLayoutConstraint activateConstraints:@[
            [self.track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.track.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.track.heightAnchor constraintEqualToConstant:kCapsuleSliderHeight],
        ]];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)dealloc {
    zs_remove_gif_view_tint(self.selectionPill);
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, kCapsuleSliderHeight);
}

- (void)setGlassEnabled:(BOOL)glassEnabled {
    if (!zs_has_liquid_glass()) {
        _glassEnabled = NO;
        [self.trackGlass removeFromSuperview];
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.layer.borderWidth = 1;
        return;
    }

    _glassEnabled = glassEnabled;

    if (glassEnabled) {
        if (!self.trackGlass) {
            UIVisualEffect *effect = zs_make_glass_effect(NO);
            self.trackGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
            self.trackGlass.translatesAutoresizingMaskIntoConstraints = NO;
            self.trackGlass.userInteractionEnabled = NO;
            self.trackGlass.opaque = NO;
            self.trackGlass.clipsToBounds = YES;
            self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;
        }

        if (self.trackGlass.superview != self.track) {
            [self.trackGlass removeFromSuperview];
            [self.track addSubview:self.trackGlass];
            [NSLayoutConstraint activateConstraints:@[
                [self.trackGlass.leadingAnchor constraintEqualToAnchor:self.track.leadingAnchor],
                [self.trackGlass.trailingAnchor constraintEqualToAnchor:self.track.trailingAnchor],
                [self.trackGlass.topAnchor constraintEqualToAnchor:self.track.topAnchor],
                [self.trackGlass.bottomAnchor constraintEqualToAnchor:self.track.bottomAnchor],
            ]];
        }

        CGFloat h = self.track.bounds.size.height > 0 ? self.track.bounds.size.height : kCapsuleSliderHeight;
        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);

        self.track.backgroundColor = UIColor.clearColor;
        self.track.layer.borderWidth = 0;
        [self.track sendSubviewToBack:self.trackGlass];
        [self.trackGlass setNeedsLayout];
        [self.trackGlass layoutIfNeeded];
    } else {
        [self.trackGlass removeFromSuperview];
        self.track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.track.layer.borderWidth = 1;
    }
}

- (void)setLabels:(NSArray<NSString *> *)labels {
    _labels = [labels copy];
    _itemCount = (NSInteger)_labels.count;
    for (CATextLayer *layer in self.itemLabels) [layer removeFromSuperlayer];
    [self.itemLabels removeAllObjects];
    [self.itemCenters removeAllObjects];

    if (_itemCount == 0) {
        self.cycleWidth = 0;
        [self setNeedsLayout];
        return;
    }

    if (!self.itemLayerHost) {
        self.itemLayerHost = [[UIView alloc] init];
        self.itemLayerHost.userInteractionEnabled = NO;
        self.itemLayerHost.backgroundColor = UIColor.clearColor;
        self.itemLayerHost.frame = self.track.bounds;
        [self.track addSubview:self.itemLayerHost];
    } else {
        self.itemLayerHost.frame = self.track.bounds;
        for (CALayer *layer in [self.itemLayerHost.layer.sublayers copy]) [layer removeFromSuperlayer];
    }

    UIFont *font = zs_mono_font(9, UIFontWeightBold);
    NSDictionary *attributes = @{NSFontAttributeName: font};
    CGFloat x = 0;
    for (NSInteger copy = 0; copy < kZSWheelLoopCopies; copy++) {
        for (NSString *text in _labels) {
            NSString *value = text ?: @"";
            CGFloat textWidth = ceil([value sizeWithAttributes:attributes].width);
            CGFloat w = MAX(34, textWidth + kWheelItemHPadding * 2);
            CATextLayer *layer = [CATextLayer layer];
            layer.string = value;
            layer.alignmentMode = kCAAlignmentCenter;
            layer.font = (__bridge CFTypeRef)font;
            layer.fontSize = 9;
            layer.foregroundColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
            layer.contentsScale = UIScreen.mainScreen.scale;
            CGFloat yDiff = (kCapsuleSliderHeight - layer.fontSize) / 2.0 - layer.fontSize / 10.0;
            layer.frame = CGRectMake(x, yDiff, w, layer.fontSize + 4);
            [self.itemLayerHost.layer addSublayer:layer];
            [self.itemLabels addObject:layer];
            [self.itemCenters addObject:@(x + w / 2.0)];
            x += w + kWheelItemGap;
        }
    }
    self.cycleWidth = x / (CGFloat)kZSWheelLoopCopies;

    if (self.trackGlass) [self.track sendSubviewToBack:self.trackGlass];
    if (self.trackGlass) [self.track insertSubview:self.selectionPill aboveSubview:self.trackGlass];
    NSInteger middleCopy = kZSWheelLoopCopies / 2;
    NSInteger clampedSelected = MAX(0, MIN(_itemCount - 1, self.selectedIndex));
    NSInteger absoluteIndex = middleCopy * _itemCount + clampedSelected;
    self.contentCenterX = self.itemCenters[absoluteIndex].doubleValue;
    [self setNeedsLayout];
}

- (NSInteger)nearestAbsoluteIndexForLogicalIndex:(NSInteger)logicalIndex {
    if (_itemCount == 0 || self.itemCenters.count == 0) return 0;
    CGFloat baseCenter = self.itemCenters[logicalIndex].doubleValue;
    CGFloat cycle = MAX((CGFloat)1, self.cycleWidth);
    NSInteger approxCopy = (NSInteger)llround((self.contentCenterX - baseCenter) / cycle);
    approxCopy = MAX(0, MIN(kZSWheelLoopCopies - 1, approxCopy));
    return approxCopy * _itemCount + logicalIndex;
}

- (void)recentreIfNeeded {
    if (_itemCount == 0 || self.cycleWidth <= 0) return;
    NSInteger nearest = [self nearestIndexForContentCenterX:self.contentCenterX];
    NSInteger copy = nearest / _itemCount;
    NSInteger middleCopy = kZSWheelLoopCopies / 2;
    if (labs((long)(copy - middleCopy)) >= 3) {
        self.contentCenterX += (middleCopy - copy) * self.cycleWidth;
        [self setNeedsLayout];
    }
}

- (void)setDefaultIndex:(NSInteger)defaultIndex {
    _defaultIndex = defaultIndex;
    [self setNeedsLayout];
}

- (NSInteger)nearestIndexForContentCenterX:(CGFloat)cx {
    NSInteger count = (NSInteger)self.itemCenters.count;
    if (count == 0) return 0;
    NSInteger best = 0;
    CGFloat bestDist = CGFLOAT_MAX;
    for (NSInteger i = 0; i < count; i++) {
        CGFloat d = fabs(self.itemCenters[i].doubleValue - cx);
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.track.bounds.size.height > 0 ? self.track.bounds.size.height : kCapsuleSliderHeight;
    self.track.layer.cornerRadius = h / 2.0;

    if (self.trackGlass) {
        zs_configure_glass_corners(self.trackGlass, h / 2.0, NO);
        self.trackGlass.layer.cornerRadius = h / 2.0;
        self.trackGlass.layer.cornerCurve = kCACornerCurveContinuous;
    }

    if (!self.edgeFadeMask) {
        self.edgeFadeMask = [CAGradientLayer layer];
        self.edgeFadeMask.startPoint = CGPointMake(0, 0.5);
        self.edgeFadeMask.endPoint = CGPointMake(1, 0.5);
        self.edgeFadeMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.whiteColor.CGColor,
                                      (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor];
        self.edgeFadeMask.locations = @[@0, @0.16, @0.84, @1.0];
        self.track.layer.mask = self.edgeFadeMask;
    }
    self.edgeFadeMask.frame = self.track.bounds;

    NSInteger count = (NSInteger)self.itemCenters.count;
    if (count == 0) {
        self.defaultIndicator.hidden = YES;
        return;
    }
    CGFloat trackW = self.track.bounds.size.width;
    CGFloat focusX = trackW / 2.0;
    NSInteger nearest = [self nearestIndexForContentCenterX:self.contentCenterX];

    CATextLayer *nearestLabel = self.itemLabels[nearest];
    CGFloat pillWidth = MIN(trackW - 6, nearestLabel.bounds.size.width);
    self.selectionPill.frame = CGRectMake(focusX - pillWidth / 2.0, 2, MAX(0, pillWidth), MAX(0, h - 4));
    self.selectionPill.layer.cornerRadius = MAX(0, (h - 4) / 2.0);
    if (self.trackGlass) [self.track sendSubviewToBack:self.trackGlass];
    if (self.trackGlass) [self.track insertSubview:self.selectionPill aboveSubview:self.trackGlass];
    zs_refresh_gif_view_tint(self.selectionPill, self.selectionPill.bounds);

    self.itemLayerHost.frame = self.track.bounds;
    for (NSInteger i = 0; i < count; i++) {
        CATextLayer *l = self.itemLabels[i];
        CGFloat center = self.itemCenters[i].doubleValue;
        CGFloat screenCenterX = focusX + (center - self.contentCenterX);
        CGRect frame = l.frame;
        frame.origin.x = screenCenterX - frame.size.width / 2.0;
        frame.origin.y = (h - l.fontSize) / 2.0 - l.fontSize / 10.0;
        l.frame = frame;

        CGFloat dist = fabs(screenCenterX - focusX);
        CGFloat norm = MIN(1.0, dist / MAX((CGFloat)1, trackW * 0.5));
        BOOL isNearest = (i == nearest);
        NSInteger logicalIndex = _itemCount > 0 ? (i % _itemCount) : i;
        BOOL isCommittedSelection = (logicalIndex == self.selectedIndex);
        l.opacity = isNearest ? 1.0 : MAX(0.25, 1.0 - norm * 0.7);
        l.foregroundColor = (isCommittedSelection ? UIColor.blackColor : [UIColor colorWithWhite:1 alpha:0.55]).CGColor;
    }

    BOOL hasDefault = self.defaultIndex >= 0 && self.defaultIndex < _itemCount;
    self.defaultIndicator.hidden = !hasDefault;
    if (hasDefault) {
        NSInteger defAbsolute = [self nearestAbsoluteIndexForLogicalIndex:self.defaultIndex];
        CGFloat defCenter = self.itemCenters[defAbsolute].doubleValue;
        CGFloat screenX = focusX + (defCenter - self.contentCenterX);
        CGFloat length = kDefaultTickHeight * 1.75;
        CGFloat thickness = kDefaultTickWidth;
        CGFloat tx = screenX - length / 2.0;
        tx = MAX(0, MIN(self.bounds.size.width - length, tx));
        CGFloat trackTop = CGRectGetMinY(self.track.frame);
        CGFloat ty = trackTop - kDefaultTickGap - thickness;
        self.defaultIndicator.frame = CGRectMake(tx, ty, length, thickness);
        self.defaultIndicator.layer.cornerRadius = thickness / 2.0;
    }
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    [self setSelectedIndex:selectedIndex animated:NO];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated {
    if (_itemCount == 0) { _selectedIndex = MAX(0, selectedIndex); return; }
    selectedIndex = MAX(0, MIN(_itemCount - 1, selectedIndex));
    _selectedIndex = selectedIndex;
    NSInteger absoluteIndex = [self nearestAbsoluteIndexForLogicalIndex:selectedIndex];
    CGFloat target = self.itemCenters[absoluteIndex].doubleValue;
    if (animated) {
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.86
              initialSpringVelocity:0.3
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.contentCenterX = target;
            [self setNeedsLayout];
            [self layoutIfNeeded];
        } completion:^(BOOL finished) {
            [self recentreIfNeeded];
        }];
    } else {
        self.contentCenterX = target;
        [self setNeedsLayout];
        [self recentreIfNeeded];
    }
}

- (void)snapToIndex:(NSInteger)absoluteIndex sendActions:(BOOL)send {
    NSInteger total = (NSInteger)self.itemCenters.count;
    if (total == 0 || _itemCount == 0) return;
    absoluteIndex = MAX(0, MIN(total - 1, absoluteIndex));
    NSInteger logical = absoluteIndex % _itemCount;
    BOOL changed = (logical != self.selectedIndex);
    _selectedIndex = logical;
    CGFloat target = self.itemCenters[absoluteIndex].doubleValue;
    [UIView animateWithDuration:0.32
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.contentCenterX = target;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    } completion:^(BOOL finished) {
        [self recentreIfNeeded];
    }];
    if (changed) {
        UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
        [haptic selectionChanged];
        if (send) [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (self.itemCenters.count == 0) return;
    CGPoint translation = [gesture translationInView:self];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            zs_set_track_glass_interactive(self.trackGlass, YES);
            self.dragStartCenterX = self.contentCenterX;
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat minC = self.itemCenters.firstObject.doubleValue;
            CGFloat maxC = self.itemCenters.lastObject.doubleValue;
            CGFloat proposed = self.dragStartCenterX - translation.x;
            if (proposed < minC) proposed = minC - (minC - proposed) * 0.35;
            if (proposed > maxC) proposed = maxC + (proposed - maxC) * 0.35;
            self.contentCenterX = proposed;
            [self setNeedsLayout];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            zs_set_track_glass_interactive(self.trackGlass, NO);
            CGPoint velocity = [gesture velocityInView:self];
            CGFloat projected = self.contentCenterX - velocity.x * 0.15;
            [self snapToIndex:[self nearestIndexForContentCenterX:projected] sendActions:YES];
            break;
        }
        default:
            break;
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (self.itemCenters.count == 0 || self.track.bounds.size.width <= 0) return;
    CGPoint location = [gesture locationInView:self];
    CGFloat focusX = self.track.bounds.size.width / 2.0;
    CGFloat contentX = self.contentCenterX + (location.x - focusX);
    [self snapToIndex:[self nearestIndexForContentCenterX:contentX] sendActions:YES];
}

- (void)zs_forceLabelRedisplay {
    [self setNeedsLayout];
    [self layoutIfNeeded];
    for (CATextLayer *layer in self.itemLabels) [layer setNeedsDisplay];
}

@end

@implementation ZSRow
@end

@interface ZSMarqueeLabel : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic, strong) UIColor *textColor;

@property (nonatomic, copy) NSString *marqueeKey;
@end

@implementation ZSMarqueeLabel {
    UILabel *_label;
    NSLayoutConstraint *_labelLeadingConstraint;
    BOOL _scrolling;
}

static NSMutableDictionary<NSString *, NSNumber *> *gGDMarqueeCycleStartTimes;
static dispatch_once_t gGDMarqueeRegistryToken;
static CFTimeInterval zs_marquee_cycle_start(NSString *key) {
    dispatch_once(&gGDMarqueeRegistryToken, ^{
        gGDMarqueeCycleStartTimes = [NSMutableDictionary dictionary];
    });
    if (!key) return CACurrentMediaTime();
    NSNumber *existing = gGDMarqueeCycleStartTimes[key];
    if (existing) return existing.doubleValue;
    CFTimeInterval now = CACurrentMediaTime();
    gGDMarqueeCycleStartTimes[key] = @(now);
    return now;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _label = [[UILabel alloc] init];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.numberOfLines = 1;
        _label.lineBreakMode = NSLineBreakByClipping;
        [self addSubview:_label];

        _labelLeadingConstraint = [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor];
        [NSLayoutConstraint activateConstraints:@[
            _labelLeadingConstraint,
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)setText:(NSString *)text {
    _label.text = text;
    [_label.layer removeAnimationForKey:@"zsMarqueeScroll"];
    _label.layer.transform = CATransform3DIdentity;
    _scrolling = NO;
    [self setNeedsLayout];
}
- (NSString *)text { return _label.text; }
- (void)setFont:(UIFont *)font { _label.font = font; [self setNeedsLayout]; }
- (UIFont *)font { return _label.font; }
- (void)setTextColor:(UIColor *)textColor { _label.textColor = textColor; }
- (UIColor *)textColor { return _label.textColor; }

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, ceil(_label.font.lineHeight));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [_label sizeToFit];
    CGFloat overflow = ceil(CGRectGetWidth(_label.frame)) - CGRectGetWidth(self.bounds);
    if (overflow > 4 && !_scrolling) {
        _scrolling = YES;
        [self zs_startScrollingWithOverflow:overflow];
    } else if (overflow <= 4 && _scrolling) {

        _scrolling = NO;
        [_label.layer removeAnimationForKey:@"zsMarqueeScroll"];
        _label.layer.transform = CATransform3DIdentity;
    }
}

- (void)zs_startScrollingWithOverflow:(CGFloat)overflow {
    NSTimeInterval moveDuration = MAX(2.5, overflow / 16.0);
    NSTimeInterval holdDuration = 0.9;
    NSTimeInterval cycle = 2 * (moveDuration + holdDuration);

    NSTimeInterval t1 = holdDuration / cycle;
    NSTimeInterval t2 = (holdDuration + moveDuration) / cycle;
    NSTimeInterval t3 = (2 * holdDuration + moveDuration) / cycle;

    CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    anim.keyTimes = @[@0, @(t1), @(t2), @(t3), @1];
    anim.values = @[@0, @0, @(-overflow), @(-overflow), @0];
    CAMediaTimingFunction *linear = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    CAMediaTimingFunction *easeInOut = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    anim.timingFunctions = @[linear, easeInOut, linear, easeInOut];
    anim.duration = cycle;
    anim.repeatCount = HUGE_VALF;
    anim.beginTime = zs_marquee_cycle_start(self.marqueeKey);
    anim.removedOnCompletion = NO;
    [_label.layer addAnimation:anim forKey:@"zsMarqueeScroll"];
}

@end

#pragma mark - Miscellaneous UI

static NSString *zs_custom_greeting_button_title(NSString *text) {
    if (text.length == 0) return @"Not Set";
    return text;
}

static ZSMarqueeLabel *zs_custom_greeting_marquee_label(UIButton *button) {
    static const void *kGreetingLabelKey = &kGreetingLabelKey;
    ZSMarqueeLabel *label = objc_getAssociatedObject(button, kGreetingLabelKey);
    if (!label) {
        label = [[ZSMarqueeLabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.userInteractionEnabled = NO;
        [button addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:10],
            [label.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-10],
            [label.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        ]];
        objc_setAssociatedObject(button, kGreetingLabelKey, label, OBJC_ASSOCIATION_RETAIN);
    }
    return label;
}

static ZSRow *zs_make_custom_greeting_row(NSString *currentText, id target, SEL tapAction) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = @"Custom Greeting Text";
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = zs_mono_font(11, UIFontWeightMedium);
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    UIFont *greetingButtonFont = zs_mono_font(11, UIFontWeightRegular);

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass_with_font(button, @"", UIColor.whiteColor, greetingButtonFont);
    [button addTarget:target action:tapAction forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:button];

    UIButton *buttonFallback = zs_make_liquid_glass_fallback_twin(button, @"", UIColor.whiteColor, greetingButtonFont);
    [buttonFallback addTarget:target action:tapAction forControlEvents:UIControlEventTouchUpInside];

    UIButton *activeGreetingButton = zs_has_liquid_glass() ? button : buttonFallback;
    objc_setAssociatedObject(row, "zs_button", activeGreetingButton, OBJC_ASSOCIATION_RETAIN);

    ZSMarqueeLabel *greetingLabel = zs_custom_greeting_marquee_label(activeGreetingButton);
    greetingLabel.font = greetingButtonFont;
    greetingLabel.textColor = UIColor.whiteColor;
    greetingLabel.marqueeKey = @"customGreetingButton";
    greetingLabel.text = zs_custom_greeting_button_title(currentText);

    static const CGFloat kZSCustomGreetingFieldWidth = 156;
    static const CGFloat kZSCustomGreetingFieldHeight = 26;
    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:button.leadingAnchor constant:-6],
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.widthAnchor constraintEqualToConstant:kZSCustomGreetingFieldWidth],
        [button.heightAnchor constraintEqualToConstant:kZSCustomGreetingFieldHeight],
        [button.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:3],
    ]];

    return row;
}

static const CGFloat kRowHeight = 26;
static const CGFloat kTitleColumnWidth = 92;
static const CGFloat kValueColumnWidth = 34;

static float zs_slider_step_for_range(float minV, float maxV) {
    if (minV >= -1.0f && maxV <= 1.0f) return 0.05f;
    if (maxV > 20.0f) return 5.0f;
    return 0.0f;
}

static ZSRow *zs_make_slider_row(NSString *title, float minV, float maxV, float val, NSString *(^format)(float)) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    float step = zs_slider_step_for_range(minV, maxV);
    float displayVal = val;
    if (step > 0) {
        displayVal = minV + roundf((val - minV) / step) * step;
        displayVal = MAX(minV, MIN(maxV, displayVal));
    }

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = title;
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = zs_mono_font(11, UIFontWeightMedium);
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    row.valueLabel = [[UILabel alloc] init];
    row.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.valueLabel.text = format(displayVal);
    row.valueLabel.textColor = zs_accent_green_color();
    row.valueLabel.font = zs_mono_font(10, UIFontWeightRegular);
    row.valueLabel.textAlignment = NSTextAlignmentRight;
    zs_apply_gif_text_tint(row.valueLabel);
    [row addSubview:row.valueLabel];

    row.slider = [[ZSCapsuleSlider alloc] init];
    row.slider.translatesAutoresizingMaskIntoConstraints = NO;
    row.slider.minimumValue = minV;
    row.slider.maximumValue = maxV;
    row.slider.step = step;
    row.slider.value = displayVal;
    [row.slider setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:row.slider];

    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.widthAnchor constraintEqualToConstant:kTitleColumnWidth],
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [row.valueLabel.widthAnchor constraintEqualToConstant:kValueColumnWidth],
        [row.valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.slider.leadingAnchor constraintEqualToAnchor:row.titleLabel.trailingAnchor constant:4],
        [row.slider.trailingAnchor constraintEqualToAnchor:row.valueLabel.leadingAnchor constant:-6],
        [row.slider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    NSLayoutConstraint *sliderRowTop = [row.topAnchor constraintEqualToAnchor:row.slider.topAnchor constant:-3];
    NSLayoutConstraint *sliderRowBottom = [row.bottomAnchor constraintEqualToAnchor:row.slider.bottomAnchor constant:3];
    sliderRowTop.priority = UILayoutPriorityRequired - 1;
    sliderRowBottom.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[sliderRowTop, sliderRowBottom]];

    objc_setAssociatedObject(row.slider, "zs_format", format, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(row.slider, "zs_valueLabel", row.valueLabel, OBJC_ASSOCIATION_RETAIN);

    return row;
}

static ZSRow *zs_make_mode_slider_row(NSString *title, NSArray<NSString *> *labels, NSInteger selectedIndex, NSInteger defaultIndex) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = title;
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = zs_mono_font(11, UIFontWeightMedium);
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    row.modeSlider = [[ZSModeSlider alloc] init];
    row.modeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    row.modeSlider.labels = labels;
    row.modeSlider.defaultIndex = defaultIndex;
    row.modeSlider.selectedIndex = selectedIndex;
    [row addSubview:row.modeSlider];

    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.widthAnchor constraintEqualToConstant:kTitleColumnWidth],
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.modeSlider.leadingAnchor constraintEqualToAnchor:row.titleLabel.trailingAnchor constant:4],
        [row.modeSlider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [row.modeSlider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    NSLayoutConstraint *modeSliderRowTop = [row.topAnchor constraintEqualToAnchor:row.modeSlider.topAnchor constant:-3];
    NSLayoutConstraint *modeSliderRowBottom = [row.bottomAnchor constraintEqualToAnchor:row.modeSlider.bottomAnchor constant:3];
    modeSliderRowTop.priority = UILayoutPriorityRequired - 1;
    modeSliderRowBottom.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[modeSliderRowTop, modeSliderRowBottom]];

    return row;
}

static ZSRow *zs_make_wheel_row(NSString *title, NSArray<NSString *> *labels, NSInteger selectedIndex, NSInteger defaultIndex) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = title;
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = zs_mono_font(11, UIFontWeightMedium);
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    row.wheelPicker = [[ZSWheelPicker alloc] init];
    row.wheelPicker.translatesAutoresizingMaskIntoConstraints = NO;
    row.wheelPicker.labels = labels;
    row.wheelPicker.defaultIndex = defaultIndex;
    row.wheelPicker.selectedIndex = selectedIndex;
    [row addSubview:row.wheelPicker];

    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.widthAnchor constraintEqualToConstant:kTitleColumnWidth],
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.wheelPicker.leadingAnchor constraintEqualToAnchor:row.titleLabel.trailingAnchor constant:4],
        [row.wheelPicker.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [row.wheelPicker.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    NSLayoutConstraint *wheelRowTop = [row.topAnchor constraintEqualToAnchor:row.wheelPicker.topAnchor constant:-3];
    NSLayoutConstraint *wheelRowBottom = [row.bottomAnchor constraintEqualToAnchor:row.wheelPicker.bottomAnchor constant:3];
    wheelRowTop.priority = UILayoutPriorityRequired - 1;
    wheelRowBottom.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[wheelRowTop, wheelRowBottom]];

    return row;
}

static UILabel *zs_make_hint_label(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    label.font = zs_mono_font(10, UIFontWeightRegular);
    label.numberOfLines = 0;
    return label;
}

static ZSRow *zs_make_switch_row(NSString *title, BOOL val) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = title;
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = zs_mono_font(11, UIFontWeightMedium);
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    row.toggle = [[UISwitch alloc] init];
    row.toggle.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat toggleScale = 0.65;
    row.toggle.transform = CGAffineTransformMakeScale(toggleScale, toggleScale);
    row.toggle.on = val;
    zs_apply_gif_switch_tint(row.toggle);
    [row addSubview:row.toggle];

    CGSize toggleIntrinsicSize = row.toggle.intrinsicContentSize;
    CGFloat toggleTrailingCompensation = (toggleIntrinsicSize.width - toggleIntrinsicSize.width * toggleScale) / 2.0;

    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:row.toggle.leadingAnchor constant:-6],

        [row.toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:toggleTrailingCompensation],
        [row.toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.toggle.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.titleLabel.trailingAnchor constant:6],
    ]];

    NSLayoutConstraint *switchRowTop = [row.titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:2];
    NSLayoutConstraint *switchRowBottom = [row.titleLabel.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-2];
    switchRowTop.priority = UILayoutPriorityRequired - 1;
    switchRowBottom.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[switchRowTop, switchRowBottom]];

    return row;
}

static ZSRow *zs_make_button_pair_row(NSString *leftTitle, UIColor *leftTint,
                                       NSString *rightTitle, UIColor *rightTint) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIFont *pairButtonFont = zs_mono_font(11, UIFontWeightSemibold);

    UIButton *leftButton = [UIButton buttonWithType:UIButtonTypeSystem];
    leftButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass_with_font(leftButton, leftTitle, leftTint, pairButtonFont);
    [row addSubview:leftButton];
    UIButton *leftButtonFallback = zs_make_liquid_glass_fallback_twin(leftButton, leftTitle, leftTint, pairButtonFont);
    objc_setAssociatedObject(row, "zs_button_left", zs_has_liquid_glass() ? leftButton : leftButtonFallback, OBJC_ASSOCIATION_RETAIN);

    UIButton *rightButton = [UIButton buttonWithType:UIButtonTypeSystem];
    rightButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass_with_font(rightButton, rightTitle, rightTint, pairButtonFont);
    [row addSubview:rightButton];
    UIButton *rightButtonFallback = zs_make_liquid_glass_fallback_twin(rightButton, rightTitle, rightTint, pairButtonFont);
    objc_setAssociatedObject(row, "zs_button_right", zs_has_liquid_glass() ? rightButton : rightButtonFallback, OBJC_ASSOCIATION_RETAIN);

    static const CGFloat kButtonGap = 8;
    [NSLayoutConstraint activateConstraints:@[
        [leftButton.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [leftButton.topAnchor constraintEqualToAnchor:row.topAnchor constant:3],
        [leftButton.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-3],
        [leftButton.widthAnchor constraintEqualToAnchor:rightButton.widthAnchor],

        [rightButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [rightButton.topAnchor constraintEqualToAnchor:row.topAnchor constant:3],
        [rightButton.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-3],

        [rightButton.leadingAnchor constraintEqualToAnchor:leftButton.trailingAnchor constant:kButtonGap],
    ]];

    return row;
}

#pragma mark Grouped action card (CONFIG)

static const CGFloat kZSGroupedCardRowHeight = 40;
static const CGFloat kZSGroupedCardHorizontalPadding = 14;
static const CGFloat kZSGroupedCardCornerRadius = 14;

static UIButton *zs_make_grouped_action_button(NSString *title, UIColor *tint) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:tint forState:UIControlStateNormal];
    button.titleLabel.font = zs_mono_font(11, UIFontWeightSemibold);
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.backgroundColor = UIColor.clearColor;
    button.clipsToBounds = YES;
    return button;
}

static UIView *zs_make_grouped_row_separator(void) {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    [line.heightAnchor constraintEqualToConstant:1].active = YES;
    return line;
}

static UIView *zs_make_grouped_vertical_divider(void) {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    [line.widthAnchor constraintEqualToConstant:1].active = YES;
    return line;
}

static UIView *zs_make_grouped_action_pair_row(UIButton *leftButton, UIButton *rightButton) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    leftButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    rightButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;

    [row addSubview:leftButton];
    UIView *divider = zs_make_grouped_vertical_divider();
    [row addSubview:divider];
    [row addSubview:rightButton];

    [NSLayoutConstraint activateConstraints:@[
        [leftButton.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [leftButton.topAnchor constraintEqualToAnchor:row.topAnchor],
        [leftButton.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [leftButton.trailingAnchor constraintEqualToAnchor:divider.leadingAnchor constant:-10],

        [divider.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
        [divider.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-8],
        [divider.centerXAnchor constraintEqualToAnchor:row.centerXAnchor],

        [rightButton.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor constant:10],
        [rightButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [rightButton.topAnchor constraintEqualToAnchor:row.topAnchor],
        [rightButton.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [leftButton.widthAnchor constraintEqualToAnchor:rightButton.widthAnchor],
    ]];

    return row;
}

static UIView *zs_make_grouped_action_card(NSArray<UIView *> *rows) {
    UIStackView *innerStack = [[UIStackView alloc] init];
    innerStack.axis = UILayoutConstraintAxisVertical;
    innerStack.translatesAutoresizingMaskIntoConstraints = NO;
    innerStack.spacing = 0;

    for (NSUInteger i = 0; i < rows.count; i++) {
        UIView *row = rows[i];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [innerStack addArrangedSubview:row];
        [row.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight].active = YES;
        if (i + 1 < rows.count) {
            [innerStack addArrangedSubview:zs_make_grouped_row_separator()];
        }
    }

    UIView *card;
    UIView *contentHost;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        zs_configure_glass_corners(glass, kZSGroupedCardCornerRadius, NO);
        zs_register_suspendable_glass(glass);
        card = glass;
        contentHost = glass.contentView;
    } else {
        UIView *plain = [[UIView alloc] init];
        plain.translatesAutoresizingMaskIntoConstraints = NO;
        plain.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1];
        plain.layer.cornerRadius = kZSGroupedCardCornerRadius;
        plain.layer.cornerCurve = kCACornerCurveContinuous;
        plain.clipsToBounds = YES;
        card = plain;
        contentHost = plain;
    }

    [contentHost addSubview:innerStack];
    [NSLayoutConstraint activateConstraints:@[
        [innerStack.topAnchor constraintEqualToAnchor:contentHost.topAnchor],
        [innerStack.bottomAnchor constraintEqualToAnchor:contentHost.bottomAnchor],
        [innerStack.leadingAnchor constraintEqualToAnchor:contentHost.leadingAnchor constant:kZSGroupedCardHorizontalPadding],
        [innerStack.trailingAnchor constraintEqualToAnchor:contentHost.trailingAnchor constant:-kZSGroupedCardHorizontalPadding],
    ]];

    return card;
}

static UIView *zs_make_glass_container_card(UIView *contentView, UIEdgeInsets insets) {
    UIView *card;
    UIView *contentHost;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        zs_configure_glass_corners(glass, kZSGroupedCardCornerRadius, NO);
        zs_register_suspendable_glass(glass);
        card = glass;
        contentHost = glass.contentView;
    } else {
        UIView *plain = [[UIView alloc] init];
        plain.translatesAutoresizingMaskIntoConstraints = NO;
        plain.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1];
        plain.layer.cornerRadius = kZSGroupedCardCornerRadius;
        plain.layer.cornerCurve = kCACornerCurveContinuous;
        plain.clipsToBounds = YES;
        card = plain;
        contentHost = plain;
    }

    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [contentHost addSubview:contentView];
    [NSLayoutConstraint activateConstraints:@[
        [contentView.topAnchor constraintEqualToAnchor:contentHost.topAnchor constant:insets.top],
        [contentView.bottomAnchor constraintEqualToAnchor:contentHost.bottomAnchor constant:-insets.bottom],
        [contentView.leadingAnchor constraintEqualToAnchor:contentHost.leadingAnchor constant:insets.left],
        [contentView.trailingAnchor constraintEqualToAnchor:contentHost.trailingAnchor constant:-insets.right],
    ]];

    return card;
}

static NSArray<UIColor *> *zs_memory_chart_palette(void) {
    return @[
        [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0],
        [UIColor colorWithRed:0x30 / 255.0 green:0xD1 / 255.0 blue:0x58 / 255.0 alpha:1.0],
        [UIColor colorWithRed:1.0 green:0.82 blue:0.2 alpha:1.0],
        [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0],
        [UIColor colorWithRed:0.68 green:0.42 blue:1.0 alpha:1.0],
        [UIColor colorWithRed:0.42 green:0.88 blue:0.88 alpha:1.0],
        [UIColor colorWithRed:1.0 green:0.6 blue:0.32 alpha:1.0],
        [UIColor colorWithWhite:0.7 alpha:1.0],
    ];
}

static UIView *zs_make_memory_legend_row(NSString *title, NSString *detailText, UIColor *color) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *swatch = [[UIView alloc] init];
    swatch.translatesAutoresizingMaskIntoConstraints = NO;
    swatch.backgroundColor = color;
    swatch.layer.cornerRadius = 3;
    swatch.layer.cornerCurve = kCACornerCurveContinuous;
    [row addSubview:swatch];

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.text = title;
    nameLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    nameLabel.font = zs_mono_font(10, UIFontWeightMedium);
    nameLabel.numberOfLines = 1;
    nameLabel.adjustsFontSizeToFitWidth = YES;
    nameLabel.minimumScaleFactor = 0.75;
    [row addSubview:nameLabel];

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    detailLabel.text = detailText;
    detailLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    detailLabel.font = zs_mono_font(10, UIFontWeightRegular);
    detailLabel.textAlignment = NSTextAlignmentRight;
    [detailLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:detailLabel];

    [NSLayoutConstraint activateConstraints:@[
        [swatch.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [swatch.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [swatch.widthAnchor constraintEqualToConstant:10],
        [swatch.heightAnchor constraintEqualToConstant:10],

        [nameLabel.leadingAnchor constraintEqualToAnchor:swatch.trailingAnchor constant:7],
        [nameLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:detailLabel.leadingAnchor constant:-6],

        [detailLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [detailLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.heightAnchor constraintEqualToConstant:16],
    ]];

    return row;
}

static UIVisualEffectView *zs_wrap_field_in_native_glass(UITextField *field, CGFloat cornerRadius) {
    field.borderStyle = UITextBorderStyleNone;
    UIView *leftPadding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    field.leftView = leftPadding;
    field.leftViewMode = UITextFieldViewModeAlways;

    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(YES)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        zs_configure_glass_corners(glass, cornerRadius, NO);
        zs_register_suspendable_glass(glass);

        field.backgroundColor = UIColor.clearColor;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        [glass.contentView addSubview:field];
        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor],
            [field.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor],
            [field.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor],
            [field.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor],
        ]];
        return glass;
    }

    field.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    field.layer.cornerRadius = cornerRadius;
    field.layer.cornerCurve = kCACornerCurveContinuous;
    return nil;
}

#pragma mark Re-Encoding format (Config section)

static NSArray<NSString *> *zs_reencode_format_options(void) {
    return @[@"ASTC_RGBA_4x4", @"ASTC_RGBA_6x6", @"ASTC_RGBA_8x8", @"RGBA32", @"ETC2"];
}

static NSString * const kZSDefaultReencodeFormat = @"ASTC_RGBA_6x6";

static const CGFloat kZSReencodeFieldWidth = 116;
static const CGFloat kZSReencodeFieldHeight = 28;

static const CGFloat kZSReencodeHorizontalPadding = 10;

static const CGFloat kZSReencodeChevronReserve = 20;

static NSString *zs_reencode_format_display_name(NSString *format) {
    if ([format isEqualToString:@"ASTC_RGBA_4x4"]) return @"ASTC 4x4";
    if ([format isEqualToString:@"ASTC_RGBA_6x6"]) return @"ASTC 6x6";
    if ([format isEqualToString:@"ASTC_RGBA_8x8"]) return @"ASTC 8x8";
    if ([format isEqualToString:@"RGBA32"]) return @"RGBA32";
    if ([format isEqualToString:@"ETC2"]) return @"ETC2";
    return format ?: @"RGBA32";
}

static NSString *zs_codec_descriptor_label_for_format(NSString *format) {
    if ([format isEqualToString:@"ASTC_RGBA_4x4"]) return @"ASTC_4x4";
    if ([format isEqualToString:@"ASTC_RGBA_6x6"]) return @"ASTC_6x6";
    if ([format isEqualToString:@"ASTC_RGBA_8x8"]) return @"ASTC_8x8";
    if ([format isEqualToString:@"RGBA32"]) return @"RGBA32";
    if ([format isEqualToString:@"ETC2"]) return @"ETC2";
    return format ?: @"RGBA32";
}

static UIImage *zs_make_dropdown_chevron_image(void) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
    UIImage *chevronImage = [UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:symbolConfig];
    chevronImage = [chevronImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.55]
                                       renderingMode:UIImageRenderingModeAlwaysOriginal];
    return chevronImage;
}

static UIImage *zs_make_release_history_arrow_image(BOOL pointingLeft) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    UIImage *arrowImage = [UIImage systemImageNamed:pointingLeft ? @"chevron.left" : @"chevron.right" withConfiguration:symbolConfig];
    arrowImage = [arrowImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.55]
                                   renderingMode:UIImageRenderingModeAlwaysOriginal];
    return arrowImage;
}

static UIImageView *zs_reencode_chevron_view(UIButton *button) {
    static const void *kChevronKey = &kChevronKey;
    UIImageView *chevron = objc_getAssociatedObject(button, kChevronKey);
    if (!chevron) {
        chevron = [[UIImageView alloc] initWithImage:zs_make_dropdown_chevron_image()];
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        chevron.contentMode = UIViewContentModeCenter;

        chevron.userInteractionEnabled = NO;
        [button addSubview:chevron];
        [NSLayoutConstraint activateConstraints:@[

            [chevron.trailingAnchor constraintEqualToAnchor:button.trailingAnchor
                                                    constant:-kZSReencodeHorizontalPadding],
            [chevron.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        ]];
        objc_setAssociatedObject(button, kChevronKey, chevron, OBJC_ASSOCIATION_RETAIN);
    }
    return chevron;
}

static void zs_style_reencode_format_button(UIButton *button, NSString *format) {

    zs_style_button_as_native_glass_with_font(button, zs_reencode_format_display_name(format), UIColor.whiteColor, zs_mono_font(11, UIFontWeightRegular));
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;

    SEL getConfiguration = NSSelectorFromString(@"configuration");
    BOOL appliedConfigurationInsets = NO;
    if ([button respondsToSelector:getConfiguration]) {
        id configuration = ((id (*)(id, SEL))objc_msgSend)(button, getConfiguration);
        if (configuration) {

            SEL setButtonSize = NSSelectorFromString(@"setButtonSize:");
            if ([configuration respondsToSelector:setButtonSize]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(configuration, setButtonSize, 3);
            }

            SEL setContentInsets = NSSelectorFromString(@"setContentInsets:");
            if ([configuration respondsToSelector:setContentInsets]) {
                NSDirectionalEdgeInsets insets = NSDirectionalEdgeInsetsMake(
                    6, kZSReencodeHorizontalPadding,
                    6, kZSReencodeHorizontalPadding + kZSReencodeChevronReserve);
                ((void (*)(id, SEL, NSDirectionalEdgeInsets))objc_msgSend)(configuration, setContentInsets, insets);
            }
            SEL setConfig = NSSelectorFromString(@"setConfiguration:");
            if ([button respondsToSelector:setConfig]) {
                ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, configuration);
                appliedConfigurationInsets = YES;
            }
        }
    }

    if (!appliedConfigurationInsets) {
        button.contentEdgeInsets = UIEdgeInsetsMake(6, kZSReencodeHorizontalPadding,
                                                     6, kZSReencodeHorizontalPadding + kZSReencodeChevronReserve);
    }

    zs_configure_glass_button_fixed_corner_radius(button, kZSAuthFieldCornerRadius);
    if (!zs_has_liquid_glass()) {
        button.layer.cornerRadius = kZSAuthFieldCornerRadius;
        button.clipsToBounds = YES;
    }

    [button bringSubviewToFront:zs_reencode_chevron_view(button)];
}

static UIButton *zs_make_reencode_dropdown_option_button(NSString *format, BOOL selected, NSInteger tag, id target, SEL action) {
    UIButton *option = [UIButton buttonWithType:UIButtonTypeSystem];
    option.tag = tag;
    option.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    option.titleEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    option.titleLabel.font = zs_mono_font(11, UIFontWeightRegular);
    [option setTitle:zs_reencode_format_display_name(format) forState:UIControlStateNormal];
    [option setTitleColor:(selected ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.6])
                  forState:UIControlStateNormal];
    option.backgroundColor = UIColor.clearColor;

    [option addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return option;
}

static ZSRow *zs_make_reencode_format_row(NSString *selectedFormat, id target, SEL tapAction) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    row.titleLabel = [[UILabel alloc] init];
    row.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    row.titleLabel.text = @"Transcode format";
    row.titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    row.titleLabel.font = zs_mono_font(11, UIFontWeightMedium);
    row.titleLabel.adjustsFontSizeToFitWidth = YES;
    row.titleLabel.minimumScaleFactor = 0.8;
    [row addSubview:row.titleLabel];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;

    [button addTarget:target action:tapAction forControlEvents:UIControlEventTouchDown];
    [row addSubview:button];
    objc_setAssociatedObject(row, "zs_button", button, OBJC_ASSOCIATION_RETAIN);

    zs_style_reencode_format_button(button, selectedFormat);

    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [row.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:button.leadingAnchor constant:-6],
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.widthAnchor constraintEqualToConstant:kZSReencodeFieldWidth],
        [button.heightAnchor constraintEqualToConstant:kZSReencodeFieldHeight],
        [button.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:3],
    ]];

    return row;
}

static ZSRow *zs_make_button_and_glass_field_row(NSString *buttonTitle, UIColor *buttonTint, NSString *placeholder) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIFont *syslogButtonFont = zs_mono_font(11, UIFontWeightSemibold);

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass_with_font(button, buttonTitle, buttonTint, syslogButtonFont);
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    [row addSubview:button];
    UIButton *buttonFallback = zs_make_liquid_glass_fallback_twin(button, buttonTitle, buttonTint, syslogButtonFont);
    buttonFallback.titleLabel.adjustsFontSizeToFitWidth = YES;
    buttonFallback.titleLabel.minimumScaleFactor = 0.75;
    objc_setAssociatedObject(row, "zs_button", zs_has_liquid_glass() ? button : buttonFallback, OBJC_ASSOCIATION_RETAIN);

    UITextField *field = [[UITextField alloc] init];
    field.font = zs_mono_font(11, UIFontWeightRegular);
    field.textColor = UIColor.whiteColor;
    field.tintColor = zs_accent_green_color();
    field.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:placeholder
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.returnKeyType = UIReturnKeyDone;
    objc_setAssociatedObject(row, "zs_textfield", field, OBJC_ASSOCIATION_RETAIN);

    UIVisualEffectView *fieldGlass = zs_wrap_field_in_native_glass(field, 6);
    UIView *fieldContainer = fieldGlass ?: field;
    fieldContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:fieldContainer];

    static const CGFloat kGap = 8;
    [NSLayoutConstraint activateConstraints:@[
        [fieldContainer.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [fieldContainer.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [fieldContainer.heightAnchor constraintEqualToConstant:28],
        [row.topAnchor constraintEqualToAnchor:fieldContainer.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor constant:3],

        [button.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [button.centerYAnchor constraintEqualToAnchor:fieldContainer.centerYAnchor],
        [button.heightAnchor constraintEqualToAnchor:fieldContainer.heightAnchor],

        [fieldContainer.leadingAnchor constraintEqualToAnchor:button.trailingAnchor constant:kGap],

        [button.widthAnchor constraintEqualToAnchor:fieldContainer.widthAnchor multiplier:0.5],
    ]];

    return row;
}

static BOOL zs_parse_github_repo_link(NSString *raw, NSString **outOwner, NSString **outName) {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return NO;

    if ([s hasPrefix:@"git@github.com:"]) {
        s = [s substringFromIndex:@"git@github.com:".length];
    } else {

        NSRange schemeRange = [s rangeOfString:@"://"];
        if (schemeRange.location != NSNotFound) {
            s = [s substringFromIndex:NSMaxRange(schemeRange)];
        }
        if ([s.lowercaseString hasPrefix:@"github.com/"]) {
            s = [s substringFromIndex:@"github.com/".length];
        }
    }

    if ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    if ([s.lowercaseString hasSuffix:@".git"]) s = [s substringToIndex:s.length - @".git".length];

    NSArray<NSString *> *parts = [s componentsSeparatedByString:@"/"];
    if (parts.count != 2) return NO;

    NSString *owner = parts[0];
    NSString *name = parts[1];
    if (owner.length == 0 || name.length == 0) return NO;

    if (outOwner) *outOwner = owner;
    if (outName) *outName = name;
    return YES;
}

static NSString *zs_format_github_repo_link(NSString *owner, NSString *name) {
    if (owner.length == 0 || name.length == 0) return @"";
    return [NSString stringWithFormat:@"%@/%@", owner, name];
}

static NSString *zs_sanitize_personal_access_token(NSString *raw) {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray<NSString *> *schemePrefixes = @[@"bearer ", @"token "];
    for (NSString *prefix in schemePrefixes) {
        if (s.length > prefix.length && [[s substringToIndex:prefix.length].lowercaseString isEqualToString:prefix]) {
            return [[s substringFromIndex:prefix.length]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    return s;
}

static ZSRow *zs_make_labeled_glass_field_row(NSString *placeholder, BOOL secure, UIButton *trailingButton) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UITextField *field = [[UITextField alloc] init];
    field.font = zs_mono_font(11, UIFontWeightRegular);
    field.textColor = UIColor.whiteColor;
    field.tintColor = zs_accent_green_color();
    field.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:placeholder
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.returnKeyType = UIReturnKeyDone;
    field.secureTextEntry = secure;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    objc_setAssociatedObject(row, "zs_textfield", field, OBJC_ASSOCIATION_RETAIN);

    UIVisualEffectView *fieldGlass = zs_wrap_field_in_native_glass(field, 6);
    UIView *fieldContainer = fieldGlass ?: field;
    fieldContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:fieldContainer];

    objc_setAssociatedObject(row, "zs_fieldContainer", fieldContainer, OBJC_ASSOCIATION_RETAIN);

    NSMutableArray<NSLayoutConstraint *> *fieldConstraints = [NSMutableArray arrayWithArray:@[
        [fieldContainer.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [fieldContainer.topAnchor constraintEqualToAnchor:row.topAnchor],
        [fieldContainer.heightAnchor constraintEqualToConstant:28],
        [row.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor],
    ]];

    if (trailingButton) {
        trailingButton.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:trailingButton];

        [fieldConstraints addObjectsFromArray:@[
            [fieldContainer.widthAnchor constraintEqualToAnchor:row.widthAnchor multiplier:0.65],
            [trailingButton.leadingAnchor constraintEqualToAnchor:fieldContainer.trailingAnchor constant:8],
            [trailingButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [trailingButton.topAnchor constraintEqualToAnchor:fieldContainer.topAnchor],
            [trailingButton.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor],
        ]];
    } else {
        [fieldConstraints addObject:[fieldContainer.trailingAnchor constraintEqualToAnchor:row.trailingAnchor]];
    }

    [NSLayoutConstraint activateConstraints:[fieldConstraints copy]];

    return row;
}

static UIView *zs_make_blacklist_entry_row(NSString *term, id target, SEL removeAction) {
    UIView *chip = [[UIView alloc] init];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    chip.layer.cornerRadius = 8;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.layer.borderWidth = 1;
    chip.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.1].CGColor;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = term;
    label.font = zs_mono_font(9.5, UIFontWeightRegular);
    label.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [chip addSubview:label];

    UIButton *removeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    removeButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *xSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:7 weight:UIImageSymbolWeightSemibold];
    UIImage *xImage = [UIImage systemImageNamed:@"xmark" withConfiguration:xSymbolConfig];
    [removeButton setImage:xImage forState:UIControlStateNormal];
    [removeButton setTintColor:[UIColor colorWithWhite:1 alpha:0.42]];
    removeButton.accessibilityLabel = [NSString stringWithFormat:@"Remove %@", term];
    [removeButton addTarget:target action:removeAction forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(removeButton, "zs_blacklistTerm", term, OBJC_ASSOCIATION_RETAIN);
    [chip addSubview:removeButton];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:8],
        [label.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
        [label.trailingAnchor constraintEqualToAnchor:removeButton.leadingAnchor constant:-5],
        [removeButton.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-6],
        [removeButton.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
        [removeButton.widthAnchor constraintEqualToConstant:12],
        [removeButton.heightAnchor constraintEqualToConstant:12],
        [chip.heightAnchor constraintEqualToConstant:26],
    ]];

    return chip;
}

#pragma mark - Mods Library accordion rows

static const CGFloat kZSModsOptionsButtonWidth = 30;
static const CGFloat kZSModsOptionsButtonHeight = 18;

static NSString * const kZSStoredBundlesFolderName = @"Stored Bundles";
static NSString * const kZSStoredBundlesFolderSubtext = @"Your stored bundles are here, you can restore them any time.";

static BOOL zs_mods_folder_is_or_within_stored_bundles(NSString *folderName) {
    if (folderName.length == 0) return NO;
    if ([folderName isEqualToString:kZSStoredBundlesFolderName]) return YES;
    NSString *prefix = [kZSStoredBundlesFolderName stringByAppendingString:@"/"];
    return [folderName hasPrefix:prefix];
}

static const CGFloat kZSModsFolderRowIndentWidth = 16;

static UIView *zs_make_mods_folder_row(NSString *folderName, NSString *displayName, NSString *remark, BOOL expanded, id target, SEL tapAction, SEL optionsAction, NSInteger indentLevel) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(row, "zs_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);

    CGFloat indent = indentLevel > 0 ? (indentLevel * kZSModsFolderRowIndentWidth) : 0;

    UIImageSymbolConfiguration *chevronConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:(expanded ? @"chevron.down" : @"chevron.right") withConfiguration:chevronConfig]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.55];
    chevron.contentMode = UIViewContentModeCenter;
    [row addSubview:chevron];

    UIImageSymbolConfiguration *folderConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
    UIImageView *folderIcon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"folder.fill" withConfiguration:folderConfig]];
    folderIcon.translatesAutoresizingMaskIntoConstraints = NO;
    folderIcon.tintColor = [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0];
    folderIcon.contentMode = UIViewContentModeCenter;
    [row addSubview:folderIcon];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = displayName.length > 0 ? displayName : folderName;
    label.font = zs_mono_font(13, UIFontWeightMedium);
    label.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [row addSubview:label];

    BOOL hasRemark = (remark.length > 0);
    ZSMarqueeLabel *remarkLabel = nil;
    if (hasRemark) {
        remarkLabel = [[ZSMarqueeLabel alloc] init];
        remarkLabel.text = remark;
        remarkLabel.font = zs_mono_font(10, UIFontWeightRegular);
        remarkLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];

        remarkLabel.marqueeKey = [folderName stringByAppendingString:@"|remark"];
        [row addSubview:remarkLabel];
    }

    UIButton *optionsButton = nil;
    if (optionsAction) {
        optionsButton = [UIButton buttonWithType:UIButtonTypeSystem];
        optionsButton.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageSymbolConfiguration *dotsSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
        UIImage *dotsImage = [UIImage systemImageNamed:@"ellipsis" withConfiguration:dotsSymbolConfig];
        zs_style_icon_button_as_native_glass(optionsButton, dotsImage, [UIColor colorWithWhite:1 alpha:0.6]);
        objc_setAssociatedObject(optionsButton, "zs_modsFolderName", folderName, OBJC_ASSOCIATION_COPY);
        [optionsButton addTarget:target action:optionsAction forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:optionsButton];
        objc_setAssociatedObject(row, "zs_button_options", optionsButton, OBJC_ASSOCIATION_RETAIN);
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:tapAction];
    [row addGestureRecognizer:tap];

    [NSLayoutConstraint activateConstraints:@[
        [chevron.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:(2 + indent)],
        [chevron.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:14],

        [folderIcon.leadingAnchor constraintEqualToAnchor:chevron.trailingAnchor constant:4],
        [folderIcon.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [folderIcon.widthAnchor constraintEqualToConstant:18],

        [label.leadingAnchor constraintEqualToAnchor:folderIcon.trailingAnchor constant:6],
    ]];

    UIView *labelTrailingNeighbor = optionsButton ?: row;
    [NSLayoutConstraint activateConstraints:@[
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:labelTrailingNeighbor.trailingAnchor constant:(labelTrailingNeighbor == row ? -8 : -6)],
    ]];
    if (optionsButton) {
        [NSLayoutConstraint activateConstraints:@[
            [optionsButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [optionsButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [optionsButton.widthAnchor constraintEqualToConstant:kZSModsOptionsButtonWidth],
            [optionsButton.heightAnchor constraintEqualToConstant:kZSModsOptionsButtonHeight],
        ]];
    }

    if (hasRemark) {
        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:6],

            [remarkLabel.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
            [remarkLabel.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:2],

            [remarkLabel.trailingAnchor constraintEqualToAnchor:labelTrailingNeighbor.trailingAnchor constant:(labelTrailingNeighbor == row ? -8 : -6)],
            [row.bottomAnchor constraintEqualToAnchor:remarkLabel.bottomAnchor constant:6],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-5],
            [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:5],
        ]];
    }
    return row;
}

static const CGFloat kZSModsDoctorCapsuleHeight = 18;
static const CGFloat kZSModsDoctorCapsuleMinWidth = 54;

static const CGFloat kZSModsDoctorCapsuleFontSize = 9 * 0.6;

#pragma mark - Mods Library file options menu (3.4)

static const CGFloat kZSModsOptionsDropdownWidth = 190;
static const CGFloat kZSModsOptionsRowHeight = kZSReencodeFieldHeight;

static BOOL zs_mods_entry_is_re_placeable(ModAssetLibraryEntry *entry) {
    if (!entry.isAssetBundle) return YES;
    return entry.doctorStatus == ModAssetLibraryDoctorStatusInstalled;
}

static NSArray<NSDictionary<NSString *, id> *> *zs_mods_file_options(ModAssetLibraryEntry *entry) {
    BOOL rePlaceable = zs_mods_entry_is_re_placeable(entry);
    return @[
        @{@"title": @"Cache bundle", @"symbol": @"archivebox",              @"destructive": @NO},
        @{@"title": @"Add remark",   @"symbol": @"quote.bubble",            @"destructive": @NO},
        @{@"title": @"Re-place",     @"symbol": @"arrow.triangle.2.circlepath", @"destructive": @NO, @"disabled": @(!rePlaceable)},
        @{@"title": @"Delete",       @"symbol": @"trash",                   @"destructive": @YES},
    ];
}

static NSArray<NSDictionary<NSString *, id> *> *zs_mods_stored_bundle_file_options(void) {
    return @[
        @{@"title": @"Restore",    @"symbol": @"arrow.uturn.backward", @"destructive": @NO},
        @{@"title": @"Add remark", @"symbol": @"quote.bubble",         @"destructive": @NO},
        @{@"title": @"Delete",     @"symbol": @"trash",                @"destructive": @YES},
    ];
}

static UIButton *zs_make_mods_options_row_button(NSDictionary<NSString *, id> *option, NSInteger tag, id target, SEL action) {
    BOOL destructive = [option[@"destructive"] boolValue];
    BOOL disabled = [option[@"disabled"] boolValue];
    UIColor *tint = disabled ? [UIColor colorWithWhite:1 alpha:0.28]
                    : destructive ? [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]
                                : [UIColor colorWithWhite:1 alpha:0.85];

    UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
    row.tag = tag;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    row.titleEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 24);
    row.titleLabel.font = zs_mono_font(12, UIFontWeightRegular);
    [row setTitle:option[@"title"] forState:UIControlStateNormal];
    [row setTitleColor:tint forState:UIControlStateNormal];
    row.backgroundColor = UIColor.clearColor;
    [row addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];

    UIImageSymbolConfiguration *symConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
    UIImage *symbolImage = [UIImage systemImageNamed:option[@"symbol"] withConfiguration:symConfig];
    symbolImage = [symbolImage imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImageView *symbolView = [[UIImageView alloc] initWithImage:symbolImage];
    symbolView.translatesAutoresizingMaskIntoConstraints = NO;
    symbolView.contentMode = UIViewContentModeCenter;
    symbolView.userInteractionEnabled = NO;
    [row addSubview:symbolView];
    [NSLayoutConstraint activateConstraints:@[
        [symbolView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [symbolView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [symbolView.widthAnchor constraintEqualToConstant:16],
    ]];

    return row;
}

#pragma mark - Mods Library folder options menu (3.4.5)

static NSArray<NSDictionary<NSString *, id> *> *zs_mods_folder_options(void) {
    return @[
        @{@"title": @"Add mod",      @"symbol": @"plus",                        @"destructive": @NO},
        @{@"title": @"Rename",       @"symbol": @"pencil",                      @"destructive": @NO},
        @{@"title": @"Cache folder", @"symbol": @"archivebox",                  @"destructive": @NO},
        @{@"title": @"Add remark",   @"symbol": @"quote.bubble",                @"destructive": @NO},
        @{@"title": @"Re-place",     @"symbol": @"arrow.triangle.2.circlepath", @"destructive": @NO},
        @{@"title": @"Delete",       @"symbol": @"trash",                       @"destructive": @YES},
    ];
}

static NSArray<NSDictionary<NSString *, id> *> *zs_mods_cached_folder_options(void) {
    return @[
        @{@"title": @"Restore",    @"symbol": @"arrow.uturn.backward", @"destructive": @NO},
        @{@"title": @"Add remark", @"symbol": @"quote.bubble",         @"destructive": @NO},
        @{@"title": @"Delete",     @"symbol": @"trash",                @"destructive": @YES},
    ];
}

static NSArray<NSDictionary<NSString *, id> *> *zs_mods_options_for_folder(NSString *folderName) {
    BOOL isCachedFolder = zs_mods_folder_is_or_within_stored_bundles(folderName)
        && ![folderName isEqualToString:kZSStoredBundlesFolderName];
    return isCachedFolder ? zs_mods_cached_folder_options() : zs_mods_folder_options();
}

static UIView *zs_make_mods_entry_row(ModAssetLibraryEntry *entry, id target, SEL tapAction,
                                       SEL dispatchAction, SEL downloadAction, SEL retryAction, SEL optionsAction, BOOL showActions,
                                       BOOL downloadInFlight, BOOL isStoredBundlesFolder, NSInteger indentLevel) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(row, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);

    BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);

    BOOL isDoctorEligible = (entry.isAssetBundle || entry.zipCacheHash1.length > 0) && !isStoredBundlesFolder;
    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
    NSString *iconName = @"doc.fill";
    if (isBank) {
        iconName = @"waveform";
    } else if (entry.localizationKind == ModAssetLibraryLocalizationKindPack) {
        iconName = @"shippingbox.fill";
    } else if (entry.localizationKind == ModAssetLibraryLocalizationKindJSON) {
        iconName = @"text.bubble.fill";
    }
    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:iconName withConfiguration:iconConfig]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    icon.contentMode = UIViewContentModeCenter;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = entry.fileName;
    label.font = zs_mono_font(11, UIFontWeightRegular);
    label.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [row addSubview:label];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:tapAction];
    [row addGestureRecognizer:tap];

    UIButton *optionsButton = nil;
    if (showActions) {
        optionsButton = [UIButton buttonWithType:UIButtonTypeSystem];
        optionsButton.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageSymbolConfiguration *dotsSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
        UIImage *dotsImage = [UIImage systemImageNamed:@"ellipsis" withConfiguration:dotsSymbolConfig];
        zs_style_icon_button_as_native_glass(optionsButton, dotsImage, [UIColor colorWithWhite:1 alpha:0.6]);
        objc_setAssociatedObject(optionsButton, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);
        [optionsButton addTarget:target action:optionsAction forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:optionsButton];
        objc_setAssociatedObject(row, "zs_button_options", optionsButton, OBJC_ASSOCIATION_RETAIN);
    }

    UIView *doctorView = nil;
    UIButton *doctorButton = nil;
    if (isDoctorEligible) {
        switch (entry.doctorStatus) {
            case ModAssetLibraryDoctorStatusNotDispatched: {

                if (downloadInFlight) {
                    UILabel *progressLabel = [[UILabel alloc] init];
                    progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
                    progressLabel.text = @"installing…";
                    progressLabel.font = zs_mono_font(10, UIFontWeightMedium);
                    progressLabel.textColor = zs_accent_green_color();
                    progressLabel.textAlignment = NSTextAlignmentRight;
                    zs_apply_gif_text_tint(progressLabel);
                    objc_setAssociatedObject(row, "zs_label_doctorProgress", progressLabel, OBJC_ASSOCIATION_RETAIN);
                    doctorView = progressLabel;
                    break;
                }
                doctorButton = [UIButton buttonWithType:UIButtonTypeSystem];
                doctorButton.translatesAutoresizingMaskIntoConstraints = NO;
                zs_style_pill_icon_button_as_native_glass(doctorButton,
                    zs_mods_doctor_button_icon(@"paperplane.fill", kZSModsDoctorCapsuleFontSize),
                    zs_accent_green_color());
                [doctorButton addTarget:target action:dispatchAction forControlEvents:UIControlEventTouchUpInside];
                objc_setAssociatedObject(row, "zs_button_dispatch", doctorButton, OBJC_ASSOCIATION_RETAIN);
                doctorView = doctorButton;
                break;
            }
            case ModAssetLibraryDoctorStatusUploading: {

                break;
            }
            case ModAssetLibraryDoctorStatusProcessing: {

                break;
            }
            case ModAssetLibraryDoctorStatusReadyToDownload: {

                if (downloadInFlight) {
                    break;
                }
                doctorButton = [UIButton buttonWithType:UIButtonTypeSystem];
                doctorButton.translatesAutoresizingMaskIntoConstraints = NO;
                zs_style_pill_icon_button_as_native_glass(doctorButton,
                    zs_mods_doctor_button_icon(@"arrow.down.circle.fill", kZSModsDoctorCapsuleFontSize),
                    zs_accent_green_color());
                [doctorButton addTarget:target action:downloadAction forControlEvents:UIControlEventTouchUpInside];
                objc_setAssociatedObject(row, "zs_button_download", doctorButton, OBJC_ASSOCIATION_RETAIN);
                doctorView = doctorButton;
                break;
            }
            case ModAssetLibraryDoctorStatusInstalled: {

                break;
            }
            case ModAssetLibraryDoctorStatusFailed: {
                doctorButton = [UIButton buttonWithType:UIButtonTypeSystem];
                doctorButton.translatesAutoresizingMaskIntoConstraints = NO;
                UIColor *failTint = [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];
                zs_style_pill_icon_button_as_native_glass(doctorButton,
                    zs_mods_doctor_button_icon(@"arrow.clockwise", kZSModsDoctorCapsuleFontSize),
                    failTint);
                [doctorButton addTarget:target action:retryAction forControlEvents:UIControlEventTouchUpInside];
                objc_setAssociatedObject(row, "zs_button_retry", doctorButton, OBJC_ASSOCIATION_RETAIN);
                doctorView = doctorButton;
                break;
            }
        }
        if (doctorView) {
            objc_setAssociatedObject(doctorView, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);
            [row addSubview:doctorView];
            objc_setAssociatedObject(row, "zs_view_doctor", doctorView, OBJC_ASSOCIATION_RETAIN);
        }
    }

    CGFloat indent = indentLevel > 0 ? (indentLevel * kZSModsFolderRowIndentWidth) : 0;

    UIView *labelTrailingNeighbor = doctorView ?: (optionsButton ?: row);
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:(22 + indent)],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:16],

        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:5],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:labelTrailingNeighbor.trailingAnchor constant:(labelTrailingNeighbor == row ? -8 : -6)],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.topAnchor constraintEqualToAnchor:label.topAnchor constant:-3],
        [row.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:3],
    ]];

    if (optionsButton) {
        [NSLayoutConstraint activateConstraints:@[
            [optionsButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [optionsButton.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [optionsButton.widthAnchor constraintEqualToConstant:kZSModsOptionsButtonWidth],
            [optionsButton.heightAnchor constraintEqualToConstant:kZSModsOptionsButtonHeight],
        ]];
        if (doctorView) {
            [NSLayoutConstraint activateConstraints:@[
                [doctorView.trailingAnchor constraintEqualToAnchor:optionsButton.leadingAnchor constant:-3],
            ]];
        }
    } else if (doctorView) {

        [NSLayoutConstraint activateConstraints:@[
            [doctorView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        ]];
    }

    if (doctorView) {
        [NSLayoutConstraint activateConstraints:@[
            [doctorView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [doctorView.widthAnchor constraintGreaterThanOrEqualToConstant:kZSModsDoctorCapsuleMinWidth],
        ]];
        if (doctorButton) {
            [doctorView.heightAnchor constraintEqualToConstant:kZSModsDoctorCapsuleHeight].active = YES;
        }
    }

    return row;
}

static NSString *zs_truncated_cab_identifier_for_display(NSString *cabIdentifier) {
    static const NSUInteger kMaxDisplayedCABLength = 16;
    if (cabIdentifier.length <= kMaxDisplayedCABLength) return cabIdentifier;
    return [[cabIdentifier substringToIndex:kMaxDisplayedCABLength] stringByAppendingString:@"\u2026"];
}

static UIView *zs_make_marquee_info_row(NSString *labelText, NSString *value, NSString *marqueeKey, UIFont *font, UIColor *color) {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentFill;
    row.spacing = 4;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *staticLabel = [[UILabel alloc] init];
    staticLabel.text = labelText;
    staticLabel.font = font;
    staticLabel.textColor = color;
    [staticLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [staticLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    ZSMarqueeLabel *valueLabel = [[ZSMarqueeLabel alloc] init];
    valueLabel.text = value;
    valueLabel.font = font;
    valueLabel.textColor = color;

    valueLabel.marqueeKey = marqueeKey;
    [valueLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    [row addArrangedSubview:staticLabel];
    [row addArrangedSubview:valueLabel];
    return row;
}

static NSString *zs_size_descriptor_for_entry(ModAssetLibraryEntry *entry) {
    NSString *base = [NSByteCountFormatter stringFromByteCount:(long long)entry.byteSize countStyle:NSByteCountFormatterCountStyleFile];
    if (entry.doctorDispatchCompressedByteSize > 0 && entry.doctorDispatchCompressedByteSize < entry.byteSize) {
        NSString *compressed = [NSByteCountFormatter stringFromByteCount:(long long)entry.doctorDispatchCompressedByteSize countStyle:NSByteCountFormatterCountStyleFile];
        return [NSString stringWithFormat:@"%@ (%@ Compressed)", base, compressed];
    }
    return base;
}

static NSString *zs_doctor_status_text_for_entry(ModAssetLibraryEntry *entry, BOOL downloadInFlight, BOOL isStoredBundlesFolder) {    if (isStoredBundlesFolder) return @"Stored";
    switch (entry.doctorStatus) {
        case ModAssetLibraryDoctorStatusUploading: {
            unsigned long long bytesSent = (unsigned long long)MAX((int64_t)0, entry.doctorUploadProgress);
            NSInteger uploadPercent = entry.byteSize > 0
                ? (NSInteger)MIN(100, round(((double)bytesSent / (double)entry.byteSize) * 100.0))
                : 0;
            return [NSString stringWithFormat:@"(%ld%%) %llu Bytes Uploaded", (long)uploadPercent, bytesSent];
        }
        case ModAssetLibraryDoctorStatusProcessing: {
            NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, entry.doctorProcessProgress)) * 100.0);
            return [NSString stringWithFormat:@"%ld%% Processed", (long)percent];
        }
        case ModAssetLibraryDoctorStatusReadyToDownload:
            if (downloadInFlight) {
                unsigned long long bytesWritten = (unsigned long long)MAX((int64_t)0, entry.doctorDownloadProgress);
                unsigned long long downloadReferenceBytes = entry.doctorDispatchCompressedByteSize > 0
                    ? entry.doctorDispatchCompressedByteSize : entry.byteSize;
                NSInteger downloadPercent = downloadReferenceBytes > 0
                    ? (NSInteger)MIN(100, round(((double)bytesWritten / (double)downloadReferenceBytes) * 100.0))
                    : 0;
                return [NSString stringWithFormat:@"(%ld%%) %llu Bytes Downloaded", (long)downloadPercent, bytesWritten];
            }
            return @"Not installed";
        case ModAssetLibraryDoctorStatusNotDispatched:
            return downloadInFlight ? @"Installing…" : @"Not installed";
        case ModAssetLibraryDoctorStatusInstalled:
            return @"Installed";
        case ModAssetLibraryDoctorStatusFailed:
            return @"Not installed";
    }
    return @"Not installed";
}

static NSString *zs_kind_descriptor_for_entry(ModAssetLibraryEntry *entry) {
    if (entry.localizationKind == ModAssetLibraryLocalizationKindPack) return @"Localization pack";
    if (entry.localizationKind == ModAssetLibraryLocalizationKindJSON) return @"Localization .json file";
    if (entry.isAssetBundle) return @"Unity Asset Bundle";
    ZSFontKind fontKind = [ZSModsPaths fontKindForFileName:entry.fileName];
    if (fontKind != ZSFontKindUnknown) return [ZSModsPaths displayNameForFontKind:fontKind];
    NSString *extension = entry.fileName.pathExtension;
    if ([extension caseInsensitiveCompare:@"bank"] == NSOrderedSame) return @"FMOD Audio Bank";
    if ([extension caseInsensitiveCompare:@"carra2"] == NSOrderedSame || entry.zipCacheHash1.length > 0) return @".carra2 mod archive";
    return @"Unknown";
}

static UIView *zs_make_mods_entry_info_panel(ModAssetLibraryEntry *entry, BOOL downloadInFlight, BOOL isStoredBundlesFolder) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(container, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN);

    UIStackView *panel = [[UIStackView alloc] init];
    panel.axis = UILayoutConstraintAxisVertical;
    panel.spacing = 2;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layoutMarginsRelativeArrangement = YES;
    panel.layoutMargins = UIEdgeInsetsMake(2, 38, 2, 4);
    [container addSubview:panel];

    UIFont *subtextFont = zs_mono_font(9.5, UIFontWeightRegular);
    UIColor *subtextColor = [UIColor colorWithWhite:1 alpha:0.4];

    UILabel *kindLabel = [[UILabel alloc] init];
    kindLabel.text = [NSString stringWithFormat:@"Kind: %@", zs_kind_descriptor_for_entry(entry)];
    kindLabel.font = subtextFont;
    kindLabel.textColor = subtextColor;
    [panel addArrangedSubview:kindLabel];

    if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) {
        UILabel *assignedLabel = [[UILabel alloc] init];
        assignedLabel.text = [NSString stringWithFormat:@"Assigned: %@", [ZSModsPaths displayNameForFontRole:entry.fontRole]];
        assignedLabel.font = subtextFont;
        assignedLabel.textColor = subtextColor;
        [panel addArrangedSubview:assignedLabel];
    }

    if (entry.remark.length > 0) {
        ZSMarqueeLabel *remarkLabel = [[ZSMarqueeLabel alloc] init];
        remarkLabel.text = entry.remark;
        remarkLabel.font = subtextFont;
        remarkLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
        remarkLabel.marqueeKey = [entry.path stringByAppendingString:@"|remark"];
        [panel addArrangedSubview:remarkLabel];
    }

    if (!isStoredBundlesFolder) {

        NSString *displayedPath = entry.livePathDescription ?: entry.resolvedInstallTargetPath ?: entry.path;
        UIView *pathRow = zs_make_marquee_info_row(@"Filepath:", displayedPath,
                                                    [entry.path stringByAppendingString:@"|path"],
                                                    subtextFont, subtextColor);
        [panel addArrangedSubview:pathRow];

        if (entry.localizationKind != ModAssetLibraryLocalizationKindNone && entry.localizationLanguage.length > 0) {
            UILabel *langFolderLabel = [[UILabel alloc] init];
            langFolderLabel.text = [NSString stringWithFormat:@"Selected lang folder: %@", entry.localizationLanguage];
            langFolderLabel.font = subtextFont;
            langFolderLabel.textColor = subtextColor;
            [panel addArrangedSubview:langFolderLabel];
        }
    }

    if (entry.isAssetBundle) {
        if (entry.cabIdentifier.length > 0) {

            UIView *identifierRow = zs_make_marquee_info_row(@"Identifier:", zs_truncated_cab_identifier_for_display(entry.cabIdentifier),
                                                               [entry.path stringByAppendingString:@"|cab"],
                                                               subtextFont, subtextColor);
            [panel addArrangedSubview:identifierRow];
        }

        if (entry.targetPlatform) {
            int32_t platform = entry.targetPlatform.intValue;
            UILabel *platformLabel = [[UILabel alloc] init];
            platformLabel.text = [NSString stringWithFormat:@"Platform: %@(%d)", [UnityBundleCAB nameForTargetPlatform:platform], platform];
            platformLabel.font = subtextFont;
            platformLabel.textColor = subtextColor;
            [panel addArrangedSubview:platformLabel];
        }

        if (entry.doctorTranscodeCodec.length > 0) {
            UILabel *transcodeCodecLabel = [[UILabel alloc] init];
            transcodeCodecLabel.text = [NSString stringWithFormat:@"Codec: %@", zs_codec_descriptor_label_for_format(entry.doctorTranscodeCodec)];
            transcodeCodecLabel.font = subtextFont;
            transcodeCodecLabel.textColor = subtextColor;
            [panel addArrangedSubview:transcodeCodecLabel];
        }
    }

    BOOL isCarra2Entry = !entry.isAssetBundle && entry.zipCacheHash1.length > 0;
    if (entry.isAssetBundle || isCarra2Entry) {
        NSString *statusText = zs_doctor_status_text_for_entry(entry, downloadInFlight, isStoredBundlesFolder);
        UILabel *statusLabel = [[UILabel alloc] init];
        statusLabel.text = [NSString stringWithFormat:@"Status: %@", statusText];
        statusLabel.font = subtextFont;
        statusLabel.textColor = subtextColor;
        [panel addArrangedSubview:statusLabel];
        objc_setAssociatedObject(container, "zs_label_doctorStatus", statusLabel, OBJC_ASSOCIATION_RETAIN);
    }

    if ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) {
        NSDictionary<NSString *, id> *fmodInfo = [BankTransplant fmodHeaderInfoForBankAtPath:entry.path];
        if (fmodInfo) {
            UILabel *codecLabel = [[UILabel alloc] init];
            codecLabel.text = [NSString stringWithFormat:@"Codec: %@", fmodInfo[@"codec"]];
            codecLabel.font = subtextFont;
            codecLabel.textColor = subtextColor;
            [panel addArrangedSubview:codecLabel];

            NSUInteger numSamples = [fmodInfo[@"numSamples"] unsignedIntegerValue];
            UILabel *fsbInfoLabel = [[UILabel alloc] init];
            fsbInfoLabel.text = [NSString stringWithFormat:@"FSB5 v%@ \u00b7 %lu sample%@",
                                  fmodInfo[@"fsbVersion"], (unsigned long)numSamples, numSamples == 1 ? @"" : @"s"];
            fsbInfoLabel.font = subtextFont;
            fsbInfoLabel.textColor = subtextColor;
            [panel addArrangedSubview:fsbInfoLabel];
        }
    }

    UILabel *sizeLabel = [[UILabel alloc] init];
    sizeLabel.text = [NSString stringWithFormat:@"Size: %@", zs_size_descriptor_for_entry(entry)];
    sizeLabel.font = subtextFont;
    sizeLabel.textColor = subtextColor;
    [panel addArrangedSubview:sizeLabel];

    UILabel *dateLabel = [[UILabel alloc] init];
    dateLabel.text = [NSString stringWithFormat:@"Date Added: %@", entry.dateAdded.length ? entry.dateAdded : @"unknown"];
    dateLabel.font = subtextFont;
    dateLabel.textColor = subtextColor;
    [panel addArrangedSubview:dateLabel];

    if (entry.doctorStatus == ModAssetLibraryDoctorStatusFailed && entry.doctorLastError.length) {
        ZSMarqueeLabel *errorLabel = [[ZSMarqueeLabel alloc] init];
        errorLabel.text = [NSString stringWithFormat:@"Error: %@", entry.doctorLastError];
        errorLabel.font = subtextFont;
        errorLabel.textColor = [UIColor colorWithRed:1.0 green:0.5 blue:0.5 alpha:0.85];
        errorLabel.marqueeKey = [entry.path stringByAppendingString:@"|doctorError"];
        [panel addArrangedSubview:errorLabel];
    }

    [NSLayoutConstraint activateConstraints:@[
        [panel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [panel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    return container;
}

static UILabel *zs_make_section_header(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = [text uppercaseString];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    label.font = zs_mono_font(15.6, UIFontWeightSemibold);
    return label;
}

#pragma mark - Panel title block

static void zs_register_embedded_fonts(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, kExcelsiorSansTTF, (CFIndex)kExcelsiorSansTTFLength);
        if (!data) return;
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CFRelease(data);
        if (!provider) return;

        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!cgFont) {
            ZLog(@"[UserInterface] Failed to parse embedded Excelsior Sans data");
            return;
        }

        CFErrorRef error = NULL;
        BOOL registered = CTFontManagerRegisterGraphicsFont(cgFont, &error);
        CGFontRelease(cgFont);

        if (!registered) {

            NSError *nsError = (__bridge NSError *)error;
            ZLog(@"[UserInterface] Excelsior Sans registration result: %@", nsError.localizedDescription ?: @"(already registered)");
        }
        if (error) CFRelease(error);
    });
}

static UIFont *zs_excelsior_sans_font(CGFloat size, UIFontWeight weight) {
    zs_register_embedded_fonts();

    UIFont *regular = [UIFont fontWithName:@"EXCELSIORSANS" size:size];
    if (!regular) {
        ZLog(@"[UserInterface] Excelsior Sans did not resolve after registration - falling back to system font");
        return [UIFont systemFontOfSize:size weight:weight];
    }
    if (weight < UIFontWeightSemibold) return regular;

    UIFontDescriptor *boldDescriptor =
        [regular.fontDescriptor fontDescriptorWithSymbolicTraits:regular.fontDescriptor.symbolicTraits | UIFontDescriptorTraitBold];
    return boldDescriptor ? [UIFont fontWithDescriptor:boldDescriptor size:size] : regular;
}

#ifndef ZS_BUILD_NUMBER
#define ZS_BUILD_NUMBER 0
#endif

#ifndef ZS_BUILD_CHANNEL
#define ZS_BUILD_CHANNEL local
#endif

#ifndef ZS_BUILD_BRANCH
#define ZS_BUILD_BRANCH "local"
#endif

static NSString *zs_game_bundle_info_string(NSString *key) {
    id value = [NSBundle mainBundle].infoDictionary[key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *zs_build_info_lines(void) {
    NSString *gameVersion = zs_game_bundle_info_string(@"CFBundleShortVersionString") ?: @"?";
    NSString *unityVersion = zs_game_bundle_info_string(@"CrashlyticsUnityVersion") ?: @"?";
    NSString *tweakLine = [NSString stringWithFormat:@"ZS v%@-build-%d-%@ / %@",
        @ZS_VERSION_STRING, ZS_BUILD_NUMBER, @ZS_VERSION_STRINGIFY(ZS_BUILD_CHANNEL), @ZS_BUILD_BRANCH];
    return [NSString stringWithFormat:@"LimbusCompany v%@\nUnity build version %@\n%@", gameVersion, unityVersion, tweakLine];
}

static void zs_apply_update_label_style(UILabel *label, NSString *text, BOOL interactable) {
    if (interactable) {
        UIFont *boldFont = [UIFont fontWithDescriptor:[label.font.fontDescriptor
            fontDescriptorWithSymbolicTraits:label.font.fontDescriptor.symbolicTraits | UIFontDescriptorTraitBold]
                                                  size:label.font.pointSize] ?: label.font;
        NSMutableAttributedString *highlighted = [[NSMutableAttributedString alloc] initWithString:text ?: @""
            attributes:@{NSFontAttributeName: boldFont,
                          NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45],
                          NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)}];
        label.attributedText = highlighted;
    } else {
        label.attributedText = nil;
        label.font = zs_mono_font(kZSSubtitleFontSize, UIFontWeightMedium);
        label.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        label.text = text;
    }
}

static const CGFloat kZSSignatureWidth = 104;
static const CGFloat kZSSignatureInset = 8;
static const CGFloat kZSSignatureOpacity = 0.15;

static UIImage *zs_signature_image(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithBytes:kZSSignaturePNG length:kZSSignaturePNGLength];
        image = [UIImage imageWithData:data];
    });
    return image;
}

static UIImageView *zs_make_signature_overlay(void) {
    UIImage *image = zs_signature_image();
    if (!image || image.size.width <= 0) return nil;
    UIImageView *view = [[UIImageView alloc] initWithImage:image];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.contentMode = UIViewContentModeScaleAspectFit;
    view.alpha = kZSSignatureOpacity;
    view.userInteractionEnabled = NO;
    view.isAccessibilityElement = NO;
    [view.widthAnchor constraintEqualToConstant:kZSSignatureWidth].active = YES;
    [view.heightAnchor constraintEqualToAnchor:view.widthAnchor multiplier:image.size.height / image.size.width].active = YES;
    return view;
}

static UIView *zs_make_title_block(void) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    headerLabel.textAlignment = NSTextAlignmentNatural;

    NSString *fullTitle = @"ZSingularity";
    NSString *emphasized = @"ZS";

    UIFont *bigFont = zs_excelsior_sans_font(45, UIFontWeightBold);
    UIFont *restFont = zs_excelsior_sans_font(33.75, UIFontWeightBold);
    UIColor *titleColor = zs_accent_green_color();

    NSMutableAttributedString *titleString =
        [[NSMutableAttributedString alloc] initWithString:fullTitle
                                                 attributes:@{
            NSFontAttributeName: restFont,
            NSForegroundColorAttributeName: titleColor,
        }];
    [titleString addAttribute:NSFontAttributeName
                         value:bigFont
                         range:NSMakeRange(0, emphasized.length)];

    headerLabel.attributedText = titleString;
    zs_apply_gif_text_tint(headerLabel);
    [container addSubview:headerLabel];

    UIView *updateDot = [[UIView alloc] init];
    updateDot.translatesAutoresizingMaskIntoConstraints = NO;
    updateDot.layer.cornerRadius = 2;
    updateDot.layer.masksToBounds = NO;
    updateDot.layer.shadowOffset = CGSizeZero;
    updateDot.layer.shadowRadius = 4;
    updateDot.layer.shadowOpacity = 0.9;
    updateDot.hidden = YES;
    [container addSubview:updateDot];

    UILabel *updateLabel = [[UILabel alloc] init];
    updateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    updateLabel.text = @"checking for updates";
    updateLabel.textAlignment = NSTextAlignmentNatural;
    updateLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    updateLabel.font = zs_mono_font(kZSSubtitleFontSize, UIFontWeightMedium);
    updateLabel.userInteractionEnabled = YES;
    [container addSubview:updateLabel];

    UILabel *buildInfoLabel = [[UILabel alloc] init];
    buildInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    buildInfoLabel.text = zs_build_info_lines();
    buildInfoLabel.numberOfLines = 0;
    buildInfoLabel.textAlignment = NSTextAlignmentNatural;
    buildInfoLabel.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    buildInfoLabel.font = zs_mono_font(kZSSubtitleFontSize, UIFontWeightMedium);
    [container addSubview:buildInfoLabel];

    headerLabel.userInteractionEnabled = YES;
    objc_setAssociatedObject(container, @"zs_header_label", headerLabel, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(container, @"zs_update_dot", updateDot, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(container, @"zs_update_label", updateLabel, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [headerLabel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [headerLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [headerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor],

        [updateLabel.topAnchor constraintEqualToAnchor:headerLabel.bottomAnchor constant:2],
        [updateLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],

        [updateDot.widthAnchor constraintEqualToConstant:4],
        [updateDot.heightAnchor constraintEqualToConstant:4],
        [updateDot.leadingAnchor constraintEqualToAnchor:updateLabel.trailingAnchor constant:5],
        [updateDot.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor],
        [updateDot.centerYAnchor constraintEqualToAnchor:updateLabel.centerYAnchor],

        [buildInfoLabel.topAnchor constraintEqualToAnchor:updateLabel.bottomAnchor constant:2],
        [buildInfoLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [buildInfoLabel.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor],
        [buildInfoLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    return container;
}

#pragma mark - Field browser picker (EXPERIMENTAL / Browse All Settings)

@interface ZSFieldBrowserPickerViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray *allItems;
@property (nonatomic, copy) NSArray *filteredItems;
@property (nonatomic, copy) NSString *(^titleForItem)(id item);
@property (nonatomic, copy) void (^onSelect)(id item);
@property (nonatomic, strong) UISearchController *searchController;
@end

@implementation ZSFieldBrowserPickerViewController

- (instancetype)initWithTitle:(NSString *)title items:(NSArray *)items titleForItem:(NSString *(^)(id item))titleForItem {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        self.title = title;
        self.allItems = items;
        self.filteredItems = items;
        self.titleForItem = titleForItem;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                              target:self
                                                                                              action:@selector(zs_donePicking)];
}

- (void)zs_donePicking {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text;
    if (query.length == 0) {
        self.filteredItems = self.allItems;
    } else {
        NSString *(^titleBlock)(id) = self.titleForItem;
        NSMutableArray *matches = [NSMutableArray array];
        for (id item in self.allItems) {
            NSString *title = titleBlock ? titleBlock(item) : [item description];
            if ([title rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [matches addObject:item];
            }
        }
        self.filteredItems = matches;
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseId = @"ZSFieldBrowserCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseId];
    cell.backgroundColor = UIColor.clearColor;
    id item = self.filteredItems[indexPath.row];
    cell.textLabel.text = self.titleForItem ? self.titleForItem(item) : [item description];
    cell.textLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    cell.textLabel.font = zs_mono_font(12, UIFontWeightRegular);
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.7;
    UIView *bg = [[UIView alloc] init];
    bg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    cell.selectedBackgroundView = bg;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id item = self.filteredItems[indexPath.row];
    if (self.onSelect) self.onSelect(item);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Overlay

@interface UserInterface : NSObject <UIGestureRecognizerDelegate, UIScrollViewDelegate, UITextFieldDelegate, UIDocumentPickerDelegate, UITextViewDelegate>
@property (nonatomic, strong) UIVisualEffectView *glassContainer;
@property (nonatomic, strong) UIVisualEffectView *panelGlass;
@property (nonatomic, strong) UIVisualEffectView *handleGlass;
@property (nonatomic, strong) UIView *contentOverlay;
@property (nonatomic, strong) UIView *glassContainerContent;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, strong) UILabel *chevron;
@property (nonatomic, strong) UIView *scrollViewport;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIStackView *experimentalSectionContainer;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *pendingSectionBuilders;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *pendingExperimentalSectionBuilders;
@property (nonatomic, strong) NSDictionary *pendingCollapsedStates;
@property (nonatomic, copy) NSArray<UIView *> *developerSectionViews;
@property (nonatomic, assign) NSInteger developerUnlockTapCount;
@property (nonatomic, assign) CFTimeInterval developerUnlockLastTapTime;
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, assign) BOOL installed;
@property (nonatomic, assign) CGFloat panelWidth;
@property (nonatomic, strong) UIView *tutorialOverlay;
@property (nonatomic, strong) UIView *tutorialPanel;
@property (nonatomic, strong) UIButton *tutorialOKButton;
@property (nonatomic, strong) UILabel *tutorialGestureWarningLabel;
@property (nonatomic, assign) BOOL tutorialCanDismiss;
@property (nonatomic, assign) BOOL tutorialPresented;
@property (nonatomic, strong) NSTimer *tutorialUnlockTimer;

@property (nonatomic, strong) UIVisualEffectView *docsPanelGlass;
@property (nonatomic, strong) UIView *docsPanel;
@property (nonatomic, strong) UIView *docsContentOverlay;
@property (nonatomic, strong) UIView *docsPanelSeparator;
@property (nonatomic, strong) UIScrollView *docsScrollView;
@property (nonatomic, strong) UILabel *docsTitleLabel;
@property (nonatomic, strong) UIButton *docsHeaderModeChevronButton;
@property (nonatomic, strong) UIButton *docsLanguageButton;
@property (nonatomic, strong) UIView *docsLanguageDropdownOverlay;
@property (nonatomic, strong) UIControl *docsLanguageDropdownScrim;
@property (nonatomic, assign) BOOL docsLanguageDropdownOpen;
@property (nonatomic, strong) NSLayoutConstraint *docsTitleTrailingFullConstraint;
@property (nonatomic, strong) NSLayoutConstraint *docsTitleTrailingToChevronConstraint;
@property (nonatomic, strong) NSLayoutConstraint *docsTitleTrailingToLanguageConstraint;
@property (nonatomic, strong) UIStackView *docsSubheaderRow;
@property (nonatomic, strong) UILabel *docsSubheaderLabel;
@property (nonatomic, strong) UIStackView *docsSubheaderPageGroup;
@property (nonatomic, strong) UILabel *docsSubheaderPageLabel;
@property (nonatomic, strong) UIButton *docsSubheaderLeftArrowButton;
@property (nonatomic, strong) UIButton *docsSubheaderRightArrowButton;
@property (nonatomic, assign) ZSUpdateCheckMode docsReleaseViewMode;
@property (nonatomic, assign) NSUInteger docsReleaseHistoryIndex;
@property (nonatomic, strong) NSLayoutConstraint *docsScrollViewTopToTitleConstraint;
@property (nonatomic, strong) NSLayoutConstraint *docsScrollViewTopToSubheaderConstraint;
@property (nonatomic, strong) UITextView *docsBodyLabel;
@property (nonatomic, strong) UIStackView *docsUpdateActionsStack;
@property (nonatomic, strong) UIButton *docsLiveContainerInstallButton;
@property (nonatomic, strong) UIButton *docsGitHubReleaseLinkButton;
@property (nonatomic, strong) UILabel *docsUpdateActionsDisabledNoteLabel;
@property (nonatomic, strong) NSLayoutConstraint *docsScrollViewBottomToOverlayConstraint;
@property (nonatomic, assign) BOOL docsPanelOpen;
@property (nonatomic, copy) NSString *docsActiveKey;
@property (nonatomic, assign) CGFloat docsPanelWidth;
@property (nonatomic, strong) NSTimer *postFXReapplyTimer;
@property (nonatomic, strong) NSTimer *saveDebounceTimer;
@property (nonatomic, strong) UIView *syslogConsoleContainer;
@property (nonatomic, strong) UIScrollView *syslogConsoleScrollView;
@property (nonatomic, strong) UILabel *syslogTextLabel;
@property (nonatomic, assign) BOOL syslogTabEnabled;
@property (nonatomic, strong) NSMutableArray<NSString *> *syslogLines;
@property (nonatomic, strong) UITextField *syslogBlacklistField;
@property (nonatomic, strong) UILabel *syslogBlacklistStatusLabel;
@property (nonatomic, strong) UIStackView *syslogBlacklistEntriesStack;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *syslogBlacklist;

@property (nonatomic, strong) UITextField *authRepoLinkField;
@property (nonatomic, strong) UITextField *authTokenField;

@property (nonatomic, strong) UIView *authRepoLinkFieldContainer;
@property (nonatomic, strong) UIView *authTokenFieldContainer;
@property (nonatomic, strong) UIButton *authVerifyButton;

@property (nonatomic, strong) UILabel *authStatusLabel;

@property (nonatomic, assign) BOOL authInRemoveMode;

@property (nonatomic, assign) BOOL authCredentialsStale;

@property (nonatomic, strong) UIButton *customGreetingTextButton;

@property (nonatomic, strong) UIButton *reencodeFormatButton;
@property (nonatomic, strong) UIView *reencodeDropdownOverlay;
@property (nonatomic, strong) UIControl *reencodeDropdownScrim;
@property (nonatomic, assign) BOOL reencodeDropdownOpen;

@property (nonatomic, weak) UIButton *modsOptionsDropdownButton;
@property (nonatomic, strong) UIView *modsOptionsDropdownOverlay;
@property (nonatomic, strong) UIControl *modsOptionsDropdownScrim;
@property (nonatomic, assign) BOOL modsOptionsDropdownOpen;
@property (nonatomic, strong) ModAssetLibraryEntry *modsOptionsDropdownEntry;
@property (nonatomic, copy) NSString *modsOptionsDropdownFolderName;

@property (nonatomic, weak) UIDocumentPickerViewController *loadModsPicker;
@property (nonatomic, copy) NSString *loadModsTargetFolder;

@property (nonatomic, strong) NSMutableArray<NSString *> *loadModsSummaryLines;

@property (nonatomic, strong) UIStackView *modsLibraryStack;
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedFolders;
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedInfoEntries;

@property (nonatomic, weak) UIDocumentPickerViewController *libraryImportPicker;
@property (nonatomic, copy) NSString *libraryImportTargetFolder;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTimer *> *doctorPollTimers;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorUploadProgressLastUpdate;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorProcessProgressLastPercent;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorDownloadProgressLastUpdate;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorDownloadProgressPersistLastUpdate;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ModAssetLibraryEntry *> *doctorDownloadLiveEntryCache;

@property (nonatomic, strong) NSMutableSet<NSString *> *doctorDownloadInFlightPaths;

@property (nonatomic, weak) UIDocumentPickerViewController *doctorInstallTargetPicker;
@property (nonatomic, copy) NSURL *doctorInstallPendingDoctoredURL;
@property (nonatomic, copy) NSString *doctorInstallPendingEntryPath;
@property (nonatomic, copy) NSString *doctorInstallPendingFolderName;

@property (nonatomic, assign) BOOL doctorStateRecoveredThisLaunch;

@property (nonatomic, weak) UIButton *holdConfirmActiveButton;
@property (nonatomic, assign) NSTimeInterval holdConfirmStartTime;
@property (nonatomic, assign) BOOL holdConfirmTriggered;
@property (nonatomic, strong) CADisplayLink *holdConfirmDisplayLink;

@property (nonatomic, assign) CGRect zs_lastKeyboardFrame;

@property (nonatomic, strong) UIView *zsFloatingFieldBackdrop;
@property (nonatomic, strong) UIView *zsFloatingFieldContainer;
@property (nonatomic, strong) UITextField *zsFloatingField;
@property (nonatomic, weak) NSLayoutConstraint *zsFloatingFieldBottomConstraint;
@property (nonatomic, copy) void (^zsFloatingFieldCompletion)(NSString * _Nullable trimmedText);

@property (nonatomic, strong) UIButton *syslogButton;
@property (nonatomic, assign) BOOL syslogDebugModeEnabled;
@property (nonatomic, strong) CALayer *syslogButtonFillLayer;
@property (nonatomic, strong) CADisplayLink *syslogHoldDisplayLink;
@property (nonatomic, assign) NSTimeInterval syslogHoldStartTime;
@property (nonatomic, assign) BOOL syslogHoldTriggered;

@property (nonatomic, strong) ZSCapsuleSlider *normalFpsSlider;
@property (nonatomic, strong) UILabel *normalFpsValueLabel;
@property (nonatomic, strong) ZSCapsuleSlider *combatFpsSlider;
@property (nonatomic, strong) UILabel *combatFpsValueLabel;
@property (nonatomic, weak) UISwitch *expAdaptivePerformanceToggle;

@property (nonatomic, strong) UILabel *updateStatusLabel;
@property (nonatomic, strong) UIView *updateStatusDot;
@property (nonatomic, assign) ZSUpdateCheckMode updateCheckMode;
@property (nonatomic, assign) BOOL updateAvailable;
@property (nonatomic, copy) NSString *updateLatestVersion;
@property (nonatomic, assign) BOOL updateOnDeviceInstallDisabled;

@property (nonatomic, copy) NSString *browseSelectedCategory;
@property (nonatomic, copy) NSDictionary *browseSelectedEntry;
@property (nonatomic, strong) UIButton *browseCategoryButton;
@property (nonatomic, strong) UIButton *browseClassButton;
@property (nonatomic, strong) UIStackView *browseFieldsContainer;

@property (nonatomic, strong) UIButton *memoryUsageAnalyzeButton;
@property (nonatomic, strong) ZSPieChartView *memoryUsagePieChart;
@property (nonatomic, strong) UIStackView *memoryUsageLegendStack;
@property (nonatomic, strong) UILabel *memoryUsageStatusLabel;
@property (nonatomic, strong) UIView *memoryUsageChartRow;

+ (instancetype)shared;
- (void)installIfNeeded;
@end

static const NSTimeInterval kPostFXReapplyInterval = 1.0;
static const NSTimeInterval kSaveDebounceInterval = 0.4;

@interface ZSPassthroughEffectView : UIVisualEffectView
@end

@implementation ZSPassthroughEffectView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface ZSPassthroughView : UIView
@end

@implementation ZSPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@implementation UserInterface

+ (instancetype)shared {
    static UserInterface *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [UserInterface new]; });
    return instance;
}

- (void)installIfNeeded {
    if (self.installed) return;
    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;

    ZLog(@"[UserInterface] installing gesture-based panel opener");
    self.installed = YES;

    [unityView setMultipleTouchEnabled:YES];
    unityView.exclusiveTouch = NO;

    UISwipeGestureRecognizer *openSwipe =
        [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(zs_handleOpenPanelGesture:)];
    openSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    openSwipe.numberOfTouchesRequired = 2;
    openSwipe.delegate = self;
    [unityView addGestureRecognizer:openSwipe];

    zs_gif_tint_set_disabled(zs_enkephalin_disabled_by_user());

    [self zs_presentTutorialIfNeeded];

    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(deviceOrientationChanged)
                                                  name:UIDeviceOrientationDidChangeNotification
                                                object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(zs_keyboardWillChangeFrame:)
                                                  name:UIKeyboardWillChangeFrameNotification
                                                object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(zs_pollAllActiveDoctorEntriesImmediately)
                                                  name:UIApplicationWillEnterForegroundNotification
                                                object:nil];
}

- (void)zs_handleOpenPanelGesture:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    if (self.tutorialPresented) {
        [self zs_flashTutorialGestureWarning];
        return;
    }
    [self openPanel];
}

- (void)zs_flashTutorialGestureWarning {
    if (!self.tutorialGestureWarningLabel) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(zs_hideTutorialGestureWarning) object:nil];
    self.tutorialGestureWarningLabel.hidden = NO;
    [UIView animateWithDuration:0.18 animations:^{
        self.tutorialGestureWarningLabel.alpha = 1;
    }];
    [self performSelector:@selector(zs_hideTutorialGestureWarning) withObject:nil afterDelay:1.6];
}

- (void)zs_hideTutorialGestureWarning {
    UILabel *label = self.tutorialGestureWarningLabel;
    [UIView animateWithDuration:0.18 animations:^{
        label.alpha = 0;
    } completion:^(BOOL finished) {
        label.hidden = YES;
    }];
}

- (void)zs_presentTutorialIfNeeded {
    if ((zs_tutorial_completed() && !zs_tutorial_override_completion_enabled()) || self.tutorialPresented) return;

    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;

    self.tutorialPresented = YES;
    self.tutorialCanDismiss = NO;

    UIView *overlay = [[UIView alloc] initWithFrame:unityView.bounds];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.userInteractionEnabled = YES;
    [unityView addSubview:overlay];
    self.tutorialOverlay = overlay;
    zs_force_dark(overlay);

    UIView *panelHost;
    UIView *panel;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.userInteractionEnabled = YES;
        zs_configure_glass_corners(glass, 24, NO);
        glass.layer.borderWidth = 1;
        glass.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        panel = glass;
        panelHost = glass.contentView;
    } else {
        UIView *plain = [[UIView alloc] init];
        plain.translatesAutoresizingMaskIntoConstraints = NO;
        plain.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
        plain.layer.cornerRadius = 24;
        plain.layer.cornerCurve = kCACornerCurveContinuous;
        plain.layer.borderWidth = 1;
        plain.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        plain.clipsToBounds = YES;
        panel = plain;
        panelHost = plain;
    }

    [overlay addSubview:panel];
    self.tutorialPanel = panel;

    UILabel *header = [[UILabel alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.textAlignment = NSTextAlignmentLeft;
    NSString *fullTitle = @"ZSingularity";
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:fullTitle
                                                                                 attributes:@{
        NSFontAttributeName: zs_excelsior_sans_font(20.5, UIFontWeightBold),
        NSForegroundColorAttributeName: zs_accent_green_color()
    }];
    [title addAttribute:NSFontAttributeName
                 value:zs_excelsior_sans_font(27.5, UIFontWeightBold)
                 range:NSMakeRange(0, 2)];
    header.attributedText = title;
    [panelHost addSubview:header];

    UILabel *welcome = [[UILabel alloc] init];
    welcome.translatesAutoresizingMaskIntoConstraints = NO;
    welcome.text = @"Welcome to ZSingularity!";
    welcome.font = zs_mono_font(16, UIFontWeightBold);
    welcome.textColor = UIColor.whiteColor;
    welcome.numberOfLines = 1;
    [panelHost addSubview:welcome];

    UITextView *body = [[UITextView alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.backgroundColor = UIColor.clearColor;
    body.opaque = NO;
    body.editable = NO;
    body.selectable = NO;
    body.scrollEnabled = NO;
    body.textContainerInset = UIEdgeInsetsZero;
    body.textContainer.lineFragmentPadding = 0;
    body.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    body.font = zs_mono_font(12, UIFontWeightRegular);
    body.userInteractionEnabled = NO;

    NSMutableAttributedString *bodyText = [[NSMutableAttributedString alloc] initWithString:@"To get started, click and hold the screen with two of your fingers, then swipe left to open the menu.\n\nAlso make sure to read the documentation of each setting by clicking the " attributes:@{
        NSFontAttributeName: zs_mono_font(12, UIFontWeightRegular),
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.72]
    }];

    UIImageSymbolConfiguration *infoConfig = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightRegular];
    UIImage *infoImage = [UIImage systemImageNamed:@"info.circle" withConfiguration:infoConfig];
    if (infoImage) {
        NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
        attachment.image = [infoImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.6]];
        attachment.bounds = CGRectMake(0, -2, 12, 12);
        [bodyText appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
        [bodyText appendAttributedString:[[NSAttributedString alloc] initWithString:@" icon next to each section.\n\nJoin the Discord Server if you want to report a bug, suggest new features or need some help." attributes:@{
            NSFontAttributeName: zs_mono_font(12, UIFontWeightRegular),
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.72]
        }]];
    } else {
        [bodyText appendAttributedString:[[NSAttributedString alloc] initWithString:@"info.circle icon next to each section." attributes:@{
            NSFontAttributeName: zs_mono_font(12, UIFontWeightRegular),
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.72]
        }]];
    }
    body.attributedText = bodyText;
    [panelHost addSubview:body];

    UIButton *discord = [UIButton buttonWithType:UIButtonTypeSystem];
    discord.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_social_text_button(discord, @"Discord Server");
    [discord addTarget:self action:@selector(zs_tutorialDiscordTapped) forControlEvents:UIControlEventTouchUpInside];
    [panelHost addSubview:discord];

    UIButton *github = [UIButton buttonWithType:UIButtonTypeSystem];
    github.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_social_text_button(github, @"GitHub Repository");
    [github addTarget:self action:@selector(zs_tutorialGitHubTapped) forControlEvents:UIControlEventTouchUpInside];
    [panelHost addSubview:github];

    self.tutorialGestureWarningLabel = [[UILabel alloc] init];
    self.tutorialGestureWarningLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.tutorialGestureWarningLabel.text = @"Close the tutorial UI first";
    self.tutorialGestureWarningLabel.font = zs_mono_font(kZSSubtitleFontSize, UIFontWeightMedium);
    self.tutorialGestureWarningLabel.textColor = UIColor.systemRedColor;
    self.tutorialGestureWarningLabel.numberOfLines = 1;
    self.tutorialGestureWarningLabel.alpha = 0;
    self.tutorialGestureWarningLabel.hidden = YES;
    [panelHost addSubview:self.tutorialGestureWarningLabel];

    self.tutorialOKButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.tutorialOKButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_solid_glass_with_font(self.tutorialOKButton, @"OK", zs_accent_green_color(), zs_mono_font(18, UIFontWeightBold));
    self.tutorialOKButton.enabled = NO;
    self.tutorialOKButton.alpha = 0.38;
    [self.tutorialOKButton addTarget:self action:@selector(zs_tutorialOKTapped) forControlEvents:UIControlEventTouchUpInside];
    [panelHost addSubview:self.tutorialOKButton];

    CGFloat panelWidth = MIN(440.0, MAX(300.0, unityView.bounds.size.width - 32.0));
    CGFloat panelHeight = MIN(390.0, MAX(320.0, unityView.bounds.size.height - 48.0));

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.widthAnchor constraintEqualToConstant:panelWidth],
        [panel.heightAnchor constraintEqualToConstant:panelHeight],

        [header.topAnchor constraintEqualToAnchor:panelHost.topAnchor constant:18],
        [header.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:20],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:panelHost.trailingAnchor constant:-20],
        [header.heightAnchor constraintEqualToConstant:34],

        [welcome.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:22],
        [welcome.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [welcome.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:18],

        [body.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:22],
        [body.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [body.topAnchor constraintEqualToAnchor:welcome.bottomAnchor constant:18],

        [discord.trailingAnchor constraintEqualToAnchor:github.leadingAnchor constant:-16],
        [github.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [discord.bottomAnchor constraintEqualToAnchor:self.tutorialOKButton.topAnchor constant:-12],
        [github.bottomAnchor constraintEqualToAnchor:self.tutorialOKButton.topAnchor constant:-12],
        [discord.heightAnchor constraintEqualToConstant:24],
        [github.heightAnchor constraintEqualToConstant:24],

        [self.tutorialGestureWarningLabel.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:22],
        [self.tutorialGestureWarningLabel.trailingAnchor constraintLessThanOrEqualToAnchor:discord.leadingAnchor constant:-8],
        [self.tutorialGestureWarningLabel.centerYAnchor constraintEqualToAnchor:discord.centerYAnchor],

        [self.tutorialOKButton.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:22],
        [self.tutorialOKButton.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [self.tutorialOKButton.bottomAnchor constraintEqualToAnchor:panelHost.bottomAnchor constant:-20],
        [self.tutorialOKButton.heightAnchor constraintEqualToConstant:46],
    ]];

    panel.alpha = 0;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.22 animations:^{
        panel.alpha = 1;
        panel.transform = CGAffineTransformIdentity;
    }];

    self.tutorialUnlockTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(zs_tutorialUnlock) userInfo:nil repeats:NO];
}

- (void)zs_tutorialUnlock {
    self.tutorialUnlockTimer = nil;
    self.tutorialCanDismiss = YES;
    self.tutorialOKButton.enabled = YES;
    [UIView animateWithDuration:0.18 animations:^{
        self.tutorialOKButton.alpha = 1.0;
    }];
}

- (void)zs_tutorialDiscordTapped {
    NSURL *url = [NSURL URLWithString:kZSSocialDiscordURL];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)zs_tutorialGitHubTapped {
    NSURL *url = [NSURL URLWithString:kZSSocialGitHubURL];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)zs_tutorialOKTapped {
    if (!self.tutorialCanDismiss) return;

    zs_set_tutorial_completed(YES);
    [self.tutorialUnlockTimer invalidate];
    self.tutorialUnlockTimer = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(zs_hideTutorialGestureWarning) object:nil];

    UIView *panel = self.tutorialPanel;
    UIView *overlay = self.tutorialOverlay;
    self.tutorialPanel = nil;
    self.tutorialOverlay = nil;
    self.tutorialOKButton = nil;
    self.tutorialGestureWarningLabel = nil;
    self.tutorialPresented = NO;

    [UIView animateWithDuration:0.18 animations:^{
        panel.alpha = 0;
        panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)zs_layoutTutorialForWindow:(UIView *)unityView {
    if (!self.tutorialOverlay || !self.tutorialPanel) return;
    self.tutorialOverlay.frame = unityView.bounds;
}

- (void)openPanel {
    if (self.panelOpen) return;
    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;

    self.panelOpen = YES;
    [self buildPanel:unityView];
    zs_reapply_all_settings();

    CGRect restingFrame = self.glassContainer.frame;
    CGFloat offscreenDeltaX = unityView.bounds.size.width - restingFrame.origin.x;

    CGRect contentOverlayRestingFrame = self.contentOverlay.frame;
    self.contentOverlay.frame = CGRectOffset(contentOverlayRestingFrame, offscreenDeltaX, 0);

    BOOL docsOverlayVisible = self.docsContentOverlay && !self.docsContentOverlay.hidden;
    CGRect docsContentOverlayRestingFrame = docsOverlayVisible ? self.docsContentOverlay.frame : CGRectZero;
    if (docsOverlayVisible) {
        self.docsContentOverlay.frame = CGRectOffset(docsContentOverlayRestingFrame, offscreenDeltaX, 0);
    }

    UIView *handleElement = self.handleGlass ?: self.handle;
    CGRect handleRestingFrame = handleElement.frame;
    handleElement.frame = CGRectMake(handleRestingFrame.origin.x + kHandleWidth,
                                      handleRestingFrame.origin.y,
                                      handleRestingFrame.size.width,
                                      handleRestingFrame.size.height);

    self.glassContainer.frame = CGRectMake(unityView.bounds.size.width,
                                            restingFrame.origin.y,
                                            restingFrame.size.width,
                                            restingFrame.size.height);

    [unityView layoutIfNeeded];
    self.glassContainer.hidden = NO;
    self.contentOverlay.hidden = NO;

    [[FPS120Controller shared] setPanelOpen:YES];
    zs_set_glass_suspended(NO);
    zs_gif_tint_set_paused(NO);
    zs_gif_tint_reconstruct_all();
    [self zs_updateSliderGlassVisibility];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        weakSelf.glassContainer.frame = restingFrame;
        weakSelf.contentOverlay.frame = contentOverlayRestingFrame;
        if (docsOverlayVisible) weakSelf.docsContentOverlay.frame = docsContentOverlayRestingFrame;
        handleElement.frame = handleRestingFrame;
    } completion:^(BOOL finished) {
        [weakSelf zs_pollAllActiveDoctorEntriesImmediately];
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *v = zs_ui_host_view();
        if (v && weakSelf.panel) [weakSelf layoutPanelForWindow:v];
        [weakSelf zs_fillVisiblePanelSectionsWithHeadroom];
    });
}

- (void)closePanel {
    if (!self.panelOpen || !self.glassContainer) return;
    UIView *unityView = zs_ui_host_view();

    self.panelOpen = NO;
    self.docsPanelOpen = NO;
    self.docsActiveKey = nil;

    if (self.zsFloatingField) [self zs_commitFloatingFieldSaving:NO];

    [[FPS120Controller shared] setPanelOpen:NO];
    zs_set_glass_suspended(YES);
    zs_gif_tint_set_paused(YES);
    zs_gif_tint_teardown_all();
    [self stopPostFXReapply];

    if (!unityView) {
        [self teardownPanelState];
        return;
    }

    CGRect offscreenFrame = CGRectMake(unityView.bounds.size.width,
                                        self.glassContainer.frame.origin.y,
                                        self.glassContainer.frame.size.width,
                                        self.glassContainer.frame.size.height);

    CGFloat offscreenDeltaX = offscreenFrame.origin.x - self.glassContainer.frame.origin.x;

    CGRect contentOverlayOffscreenFrame = CGRectOffset(self.contentOverlay.frame, offscreenDeltaX, 0);

    BOOL docsOverlayVisible = self.docsContentOverlay && !self.docsContentOverlay.hidden;
    CGRect docsContentOverlayOffscreenFrame = docsOverlayVisible ? CGRectOffset(self.docsContentOverlay.frame, offscreenDeltaX, 0) : CGRectZero;

    UIView *handleElement = self.handleGlass ?: self.handle;
    CGRect handleRetractedFrame = CGRectMake(handleElement.frame.origin.x + kHandleWidth,
                                              handleElement.frame.origin.y,
                                              handleElement.frame.size.width,
                                              handleElement.frame.size.height);

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        weakSelf.glassContainer.frame = offscreenFrame;
        weakSelf.contentOverlay.frame = contentOverlayOffscreenFrame;
        if (docsOverlayVisible) weakSelf.docsContentOverlay.frame = docsContentOverlayOffscreenFrame;
        handleElement.frame = handleRetractedFrame;
    } completion:^(BOOL finished) {
        [weakSelf teardownPanelState];
    }];
}

- (void)teardownPanelState {
    [self.postFXReapplyTimer invalidate];
    self.postFXReapplyTimer = nil;

    if (self.saveDebounceTimer) {
        [self.saveDebounceTimer invalidate];
        self.saveDebounceTimer = nil;
        zs_persist_current_settings();
    }

    [self.holdConfirmDisplayLink invalidate];
    self.holdConfirmDisplayLink = nil;
    self.holdConfirmActiveButton = nil;
    self.holdConfirmTriggered = NO;
    self.holdConfirmStartTime = 0;

    [self.syslogHoldDisplayLink invalidate];
    self.syslogHoldDisplayLink = nil;
    self.syslogHoldTriggered = NO;
    self.syslogHoldStartTime = 0;
    self.syslogDebugModeEnabled = NO;

    for (NSTimer *timer in self.doctorPollTimers.allValues) {
        [timer invalidate];
    }
    self.doctorPollTimers = nil;
    self.doctorUploadProgressLastUpdate = nil;
    self.doctorProcessProgressLastPercent = nil;
    self.doctorDownloadProgressLastUpdate = nil;
    self.doctorDownloadProgressPersistLastUpdate = nil;
    self.doctorDownloadLiveEntryCache = nil;
    self.doctorDownloadInFlightPaths = nil;
    self.doctorInstallTargetPicker = nil;
    self.doctorInstallPendingDoctoredURL = nil;
    self.doctorInstallPendingEntryPath = nil;
    self.doctorInstallPendingFolderName = nil;

    [ZSyslogController sharedController].lineHandler = nil;

    [self destroyPanelHierarchy];
}

- (void)destroyPanelHierarchy {
    [self.tutorialUnlockTimer invalidate];
    self.tutorialUnlockTimer = nil;
    [self.tutorialOverlay removeFromSuperview];
    self.tutorialOverlay = nil;
    self.tutorialPanel = nil;
    self.tutorialOKButton = nil;
    self.tutorialPresented = NO;
    self.tutorialCanDismiss = NO;
    [self.glassContainer removeFromSuperview];
    [self.contentOverlay removeFromSuperview];
    [self.docsContentOverlay removeFromSuperview];

    self.glassContainer = nil;
    self.panelGlass = nil;
    self.handleGlass = nil;
    self.contentOverlay = nil;
    self.glassContainerContent = nil;
    self.panel = nil;
    self.handle = nil;
    self.chevron = nil;
    self.scrollViewport = nil;
    self.scrollView = nil;
    self.stack = nil;
    self.experimentalSectionContainer = nil;
    self.pendingSectionBuilders = nil;
    self.pendingExperimentalSectionBuilders = nil;
    self.pendingCollapsedStates = nil;
    self.developerSectionViews = nil;

    self.docsPanelGlass = nil;
    self.docsPanel = nil;
    self.docsContentOverlay = nil;
    self.docsPanelSeparator = nil;
    self.docsScrollView = nil;
    self.docsTitleLabel = nil;
    self.docsHeaderModeChevronButton = nil;
    self.docsLanguageButton = nil;
    self.docsLanguageDropdownOverlay = nil;
    self.docsLanguageDropdownScrim = nil;
    self.docsLanguageDropdownOpen = NO;
    self.docsTitleTrailingFullConstraint = nil;
    self.docsTitleTrailingToChevronConstraint = nil;
    self.docsTitleTrailingToLanguageConstraint = nil;
    self.docsSubheaderRow = nil;
    self.docsSubheaderLabel = nil;
    self.docsSubheaderPageGroup = nil;
    self.docsSubheaderPageLabel = nil;
    self.docsSubheaderLeftArrowButton = nil;
    self.docsSubheaderRightArrowButton = nil;
    self.docsScrollViewTopToTitleConstraint = nil;
    self.docsScrollViewTopToSubheaderConstraint = nil;
    self.docsBodyLabel = nil;
    self.docsUpdateActionsStack = nil;
    self.docsLiveContainerInstallButton = nil;
    self.docsGitHubReleaseLinkButton = nil;
    self.docsUpdateActionsDisabledNoteLabel = nil;
    self.docsScrollViewBottomToOverlayConstraint = nil;

    self.syslogConsoleContainer = nil;
    self.syslogConsoleScrollView = nil;
    self.syslogTextLabel = nil;
    self.syslogBlacklistField = nil;
    self.syslogBlacklistStatusLabel = nil;
    self.syslogBlacklistEntriesStack = nil;
    self.syslogButton = nil;
    self.syslogButtonFillLayer = nil;

    self.authRepoLinkField = nil;
    self.authTokenField = nil;
    self.authRepoLinkFieldContainer = nil;
    self.authTokenFieldContainer = nil;
    self.authVerifyButton = nil;
    self.authStatusLabel = nil;

    self.customGreetingTextButton = nil;
    self.reencodeFormatButton = nil;
    self.reencodeDropdownOverlay = nil;
    self.reencodeDropdownScrim = nil;
    self.reencodeDropdownOpen = NO;

    self.modsOptionsDropdownOverlay = nil;
    self.modsOptionsDropdownScrim = nil;
    self.modsOptionsDropdownOpen = NO;
    self.modsOptionsDropdownEntry = nil;
    self.modsOptionsDropdownFolderName = nil;

    self.modsLibraryStack = nil;

    self.zsFloatingFieldBackdrop = nil;
    self.zsFloatingFieldContainer = nil;
    self.zsFloatingField = nil;

    self.normalFpsSlider = nil;
    self.normalFpsValueLabel = nil;
    self.combatFpsSlider = nil;
    self.combatFpsValueLabel = nil;

    self.updateStatusLabel = nil;
    self.updateStatusDot = nil;

    self.browseCategoryButton = nil;
    self.browseClassButton = nil;
    self.browseFieldsContainer = nil;

    self.memoryUsageAnalyzeButton = nil;
    self.memoryUsagePieChart = nil;
    self.memoryUsageLegendStack = nil;
    self.memoryUsageStatusLabel = nil;
    self.memoryUsageChartRow = nil;
}

- (void)zs_closeButtonTapped {
    if (self.docsPanelOpen) {
        [self closeDocsPanel];
        return;
    }
    [self closePanel];
}

- (void)panelSwiped:(UIPanGestureRecognizer *)gesture {
    if (!self.panelOpen) return;
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint translation = [gesture translationInView:self.contentOverlay ?: gesture.view];
    BOOL mostlyHorizontal = fabs(translation.x) > fabs(translation.y) * 1.5;
    if (mostlyHorizontal && translation.x > 40) {
        [self zs_closeButtonTapped];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {

    if ([touch.view isKindOfClass:[ZSCapsuleSlider class]]) return NO;
    if ([touch.view isKindOfClass:[ZSModeSlider class]]) return NO;
    if ([touch.view isKindOfClass:[ZSWheelPicker class]]) return NO;
    if ([touch.view isKindOfClass:[UISwitch class]]) return NO;
    if ([touch.view isKindOfClass:[UIButton class]]) return NO;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

#pragma mark Panel

static const CGFloat kPanelWidth = 320;
static const CGFloat kPanelPadding = 16;

static const CGFloat kRowSpacing = 4;
static const CGFloat kSectionSpacing = 20;

static UIButton *zs_make_section_info_button(NSString *docKey, id target, SEL action, CGFloat size) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *infoConfig = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightRegular];
    UIImage *infoImage = [UIImage systemImageNamed:@"info.circle" withConfiguration:infoConfig];
    [button setImage:infoImage forState:UIControlStateNormal];
    button.tintColor = [UIColor colorWithWhite:1 alpha:0.4];
    button.backgroundColor = UIColor.clearColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsZero;
    button.imageEdgeInsets = UIEdgeInsetsZero;

    objc_setAssociatedObject(button, "zs_docsKey", docKey, OBJC_ASSOCIATION_COPY);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [haptic impactOccurred];
    }] forControlEvents:UIControlEventTouchDown];

    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:size],
        [button.heightAnchor constraintEqualToConstant:size],
    ]];
    return button;
}

static UIView *zs_make_syslog_blacklist_card(UIView *syslogRow, UILabel *blacklistHeader, UILabel *statusLabel, UIScrollView *entriesScroll) {
    UIView *card;
    UIView *host;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        zs_configure_glass_corners(glass, 14, NO);
        glass.layer.borderWidth = 1;
        glass.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
        zs_register_suspendable_glass(glass);
        card = glass;
        host = glass.contentView;
    } else {
        UIView *plain = [[UIView alloc] init];
        plain.translatesAutoresizingMaskIntoConstraints = NO;
        plain.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.96];
        plain.layer.cornerRadius = 14;
        plain.layer.cornerCurve = kCACornerCurveContinuous;
        plain.layer.borderWidth = 1;
        plain.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
        plain.clipsToBounds = YES;
        card = plain;
        host = plain;
    }

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];

    [host addSubview:syslogRow];
    [host addSubview:separator];
    [host addSubview:blacklistHeader];
    [host addSubview:statusLabel];
    [host addSubview:entriesScroll];

    [NSLayoutConstraint activateConstraints:@[
        [syslogRow.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [syslogRow.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [syslogRow.topAnchor constraintEqualToAnchor:host.topAnchor constant:12],
        [syslogRow.heightAnchor constraintEqualToConstant:34],

        [separator.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [separator.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [separator.topAnchor constraintEqualToAnchor:syslogRow.bottomAnchor constant:11],
        [separator.heightAnchor constraintEqualToConstant:1],

        [blacklistHeader.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [blacklistHeader.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:10],
        [blacklistHeader.bottomAnchor constraintEqualToAnchor:entriesScroll.topAnchor constant:-6],

        [statusLabel.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [statusLabel.centerYAnchor constraintEqualToAnchor:blacklistHeader.centerYAnchor],
        [statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:blacklistHeader.trailingAnchor constant:8],

        [entriesScroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [entriesScroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [entriesScroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
        [entriesScroll.heightAnchor constraintEqualToConstant:32],
    ]];

    return card;
}

#pragma mark - Experimental settings index mapping

static UIView *zs_make_auth_credentials_card(UITextField *repoField, UITextField *tokenField, UIButton *verifyButton, UILabel *statusLabel) {
    UIView *card;
    UIView *host;

    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        zs_configure_glass_corners(glass, 12, NO);
        glass.layer.borderWidth = 1;
        glass.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
        zs_register_suspendable_glass(glass);
        card = glass;
        host = glass.contentView;
    } else {
        UIView *plain = [[UIView alloc] init];
        plain.translatesAutoresizingMaskIntoConstraints = NO;
        plain.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.96];
        plain.layer.cornerRadius = 12;
        plain.layer.cornerCurve = kCACornerCurveContinuous;
        plain.layer.borderWidth = 1;
        plain.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
        plain.clipsToBounds = YES;
        card = plain;
        host = plain;
    }

    UILabel *repoLabel = [[UILabel alloc] init];
    repoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    repoLabel.text = @"REPOSITORY";
    repoLabel.font = zs_mono_font(8.5, UIFontWeightSemibold);
    repoLabel.textColor = [UIColor colorWithWhite:1 alpha:0.38];
    [host addSubview:repoLabel];

    UILabel *tokenLabel = [[UILabel alloc] init];
    tokenLabel.translatesAutoresizingMaskIntoConstraints = NO;
    tokenLabel.text = @"ACCESS TOKEN";
    tokenLabel.font = zs_mono_font(8.5, UIFontWeightSemibold);
    tokenLabel.textColor = [UIColor colorWithWhite:1 alpha:0.38];
    [host addSubview:tokenLabel];

    repoField.translatesAutoresizingMaskIntoConstraints = NO;
    repoField.font = zs_mono_font(11, UIFontWeightRegular);
    repoField.textColor = UIColor.whiteColor;
    repoField.tintColor = zs_accent_green_color();
    repoField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"owner/repository" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.28]}];
    repoField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    repoField.autocorrectionType = UITextAutocorrectionTypeNo;
    repoField.spellCheckingType = UITextSpellCheckingTypeNo;
    repoField.returnKeyType = UIReturnKeyDone;
    repoField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [host addSubview:repoField];

    tokenField.translatesAutoresizingMaskIntoConstraints = NO;
    tokenField.font = zs_mono_font(11, UIFontWeightRegular);
    tokenField.textColor = UIColor.whiteColor;
    tokenField.tintColor = zs_accent_green_color();
    tokenField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"personal access token" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.28]}];
    tokenField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tokenField.autocorrectionType = UITextAutocorrectionTypeNo;
    tokenField.spellCheckingType = UITextSpellCheckingTypeNo;
    tokenField.returnKeyType = UIReturnKeyDone;
    tokenField.secureTextEntry = YES;
    tokenField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [host addSubview:tokenField];

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [host addSubview:separator];

    verifyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:verifyButton];

    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.font = zs_mono_font(9.5, UIFontWeightRegular);
    statusLabel.numberOfLines = 0;
    statusLabel.hidden = YES;
    [host addSubview:statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [repoLabel.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [repoLabel.topAnchor constraintEqualToAnchor:host.topAnchor constant:12],
        [repoLabel.widthAnchor constraintEqualToConstant:78],

        [repoField.leadingAnchor constraintEqualToAnchor:repoLabel.trailingAnchor constant:8],
        [repoField.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [repoField.centerYAnchor constraintEqualToAnchor:repoLabel.centerYAnchor],
        [repoField.heightAnchor constraintEqualToConstant:24],

        [separator.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [separator.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [separator.topAnchor constraintEqualToAnchor:repoField.bottomAnchor constant:7],
        [separator.heightAnchor constraintEqualToConstant:1],

        [tokenLabel.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [tokenLabel.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:10],
        [tokenLabel.widthAnchor constraintEqualToConstant:78],

        [tokenField.leadingAnchor constraintEqualToAnchor:tokenLabel.trailingAnchor constant:8],
        [tokenField.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [tokenField.centerYAnchor constraintEqualToAnchor:tokenLabel.centerYAnchor],
        [tokenField.heightAnchor constraintEqualToConstant:24],

        [verifyButton.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [verifyButton.topAnchor constraintEqualToAnchor:tokenField.bottomAnchor constant:10],
        [verifyButton.widthAnchor constraintEqualToConstant:72],
        [verifyButton.heightAnchor constraintEqualToConstant:26],

        [statusLabel.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:verifyButton.leadingAnchor constant:-10],
        [statusLabel.centerYAnchor constraintEqualToAnchor:verifyButton.centerYAnchor],
        [statusLabel.bottomAnchor constraintLessThanOrEqualToAnchor:host.bottomAnchor constant:-10],
        [verifyButton.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-10],
    ]];

    return card;
}

static NSInteger zs_exp_idx_QualityAA(int32_t v) { if (v == 1) return 0; if (v == 2) return 1; if (v == 4) return 2; if (v == 8) return 3; return 0; }
static NSInteger zs_exp_idx_URPMSAA(int32_t v) { if (v == 1) return 0; if (v == 2) return 1; if (v == 4) return 2; if (v == 8) return 3; return 0; }
static NSInteger zs_exp_idx_MainShadowResolution(int32_t v) { if (v == 512) return 0; if (v == 1024) return 1; if (v == 2048) return 2; if (v == 4096) return 3; return 0; }
static NSInteger zs_exp_idx_AdditionalShadowResolution(int32_t v) { if (v == 256) return 0; if (v == 512) return 1; if (v == 1024) return 2; if (v == 2048) return 3; return 0; }
static NSInteger zs_exp_idx_AdditionalShadowTierLow(int32_t v) { if (v == 256) return 0; if (v == 512) return 1; if (v == 1024) return 2; if (v == 2048) return 3; return 0; }
static NSInteger zs_exp_idx_AdditionalShadowTierMedium(int32_t v) { if (v == 256) return 0; if (v == 512) return 1; if (v == 1024) return 2; if (v == 2048) return 3; return 0; }
static NSInteger zs_exp_idx_AdditionalShadowTierHigh(int32_t v) { if (v == 256) return 0; if (v == 512) return 1; if (v == 1024) return 2; if (v == 2048) return 3; return 0; }
static NSInteger zs_exp_idx_ColorGradingLUTSize(int32_t v) { if (v == 16) return 0; if (v == 32) return 1; if (v == 48) return 2; if (v == 64) return 3; return 0; }
static NSInteger zs_exp_idx_RigidbodySolverIterations(int32_t v) { return MAX(0, MIN(11, (NSInteger)v - 1)); }
static NSInteger zs_exp_idx_RigidbodySolverVelocityIterations(int32_t v) { return MAX(0, MIN(7, (NSInteger)v - 1)); }

static UIView *zs_make_section_separator(void) {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return line;
}

static UIImage *zs_section_collapse_chevron_image(BOOL collapsed) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:(collapsed ? @"chevron.right" : @"chevron.down") withConfiguration:config];
}

static UIButton *zs_make_section_collapse_button(id target, SEL action, CGFloat size) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setImage:zs_section_collapse_chevron_image(NO) forState:UIControlStateNormal];
    button.tintColor = [UIColor colorWithWhite:1 alpha:0.45];
    button.backgroundColor = UIColor.clearColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsZero;
    button.imageEdgeInsets = UIEdgeInsetsZero;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:size],
        [button.heightAnchor constraintEqualToConstant:size],
    ]];
    return button;
}

static void zs_configure_section_header_row(UIView *row, UIView *leadingSeparator) {
    objc_setAssociatedObject(row, "zs_isSectionHeader", @YES, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionCollapsed", @NO, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionLeadingSeparator", leadingSeparator, OBJC_ASSOCIATION_RETAIN);
}

static void zs_add_section_header(UIStackView *stack, NSString *title, id target) {
    UIView *previous = stack.arrangedSubviews.lastObject;
    UIView *separator = nil;
    if (previous) {
        separator = zs_make_section_separator();
        [stack addArrangedSubview:separator];
        [stack setCustomSpacing:kSectionSpacing afterView:previous];
        [stack setCustomSpacing:kSectionSpacing afterView:separator];
    }

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *header = zs_make_section_header(title);
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:header];

    CGFloat chevronSize = ceil(header.font.lineHeight);
    UIButton *chevronButton = zs_make_section_collapse_button(target, @selector(zs_sectionCollapseToggleTapped:), chevronSize);
    [row addSubview:chevronButton];
    objc_setAssociatedObject(chevronButton, "zs_sectionHeaderRow", row, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionTitle", title, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionChevronButton", chevronButton, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [header.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [chevronButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:header.trailingAnchor constant:6],
        [chevronButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [chevronButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [row.topAnchor constraintEqualToAnchor:header.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    ]];

    zs_configure_section_header_row(row, separator);
    [stack addArrangedSubview:row];
}

static void zs_add_section_header_with_docs(UIStackView *stack, NSString *title, id infoTarget, SEL infoAction) {
    UIView *previous = stack.arrangedSubviews.lastObject;
    UIView *separator = nil;
    if (previous) {
        separator = zs_make_section_separator();
        [stack addArrangedSubview:separator];
        [stack setCustomSpacing:kSectionSpacing afterView:previous];
        [stack setCustomSpacing:kSectionSpacing afterView:separator];
    }

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *header = zs_make_section_header(title);
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:header];

    CGFloat infoButtonSize = ceil(header.font.lineHeight);
    UIButton *infoButton = zs_make_section_info_button(title, infoTarget, infoAction, infoButtonSize);
    [row addSubview:infoButton];

    UIButton *chevronButton = zs_make_section_collapse_button(infoTarget, @selector(zs_sectionCollapseToggleTapped:), infoButtonSize);
    [row addSubview:chevronButton];
    objc_setAssociatedObject(chevronButton, "zs_sectionHeaderRow", row, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionTitle", title, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionChevronButton", chevronButton, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [header.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [infoButton.leadingAnchor constraintEqualToAnchor:header.trailingAnchor constant:6],
        [infoButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [chevronButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:infoButton.trailingAnchor constant:6],
        [chevronButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [chevronButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [row.topAnchor constraintEqualToAnchor:header.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    ]];

    zs_configure_section_header_row(row, separator);
    [stack addArrangedSubview:row];
}

static const CGFloat kHandleWidth = 27;
static const CGFloat kHandleHeight = 72;
static const CGFloat kPanelCornerRadiusMinimum = 20;
static const CGFloat kZSDocsPanelGlassFillOverlap = kPanelCornerRadiusMinimum + 6;
static const CGFloat kHandleCornerRadius = 10;
static const CGFloat kGlassMergeSpacing = 16;
static const CGFloat kZSSyslogConsoleHeight = 180;
static const CGFloat kContentFadeHeight = 22;

- (void)buildPanel:(UIView *)unityView {
    if (self.glassContainer) [self destroyPanelHierarchy];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    self.panelWidth = kPanelWidth;

    UIVisualEffectView *chrome = nil;

    if (zs_has_liquid_glass()) {
        chrome = [[ZSPassthroughEffectView alloc] initWithEffect:zs_make_glass_container_effect(kGlassMergeSpacing)];
    } else {

        chrome = [[ZSPassthroughEffectView alloc] initWithEffect:nil];
    }

    self.glassContainer = chrome;
    self.glassContainerContent = chrome.contentView;
    self.glassContainer.userInteractionEnabled = YES;
    self.glassContainer.hidden = YES;
    [unityView addSubview:self.glassContainer];
    zs_force_dark(self.glassContainer);

    if (zs_has_liquid_glass()) {

        self.panelGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        self.panelGlass.userInteractionEnabled = YES;
        zs_configure_glass_corners(self.panelGlass, kPanelCornerRadiusMinimum, YES);
        [self.glassContainerContent addSubview:self.panelGlass];

        self.handleGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(YES)];
        self.handleGlass.userInteractionEnabled = YES;
        zs_configure_glass_corners(self.handleGlass, kHandleCornerRadius, NO);
        [self.glassContainerContent addSubview:self.handleGlass];

        self.panel = self.panelGlass.contentView;
        self.handle = self.handleGlass.contentView;
    } else {

        self.panel = [[UIView alloc] init];
        self.handle = [[UIView alloc] init];
        self.panel.backgroundColor = UIColor.clearColor;
        self.handle.backgroundColor = UIColor.clearColor;
        [self.glassContainerContent addSubview:self.panel];
        [self.glassContainerContent addSubview:self.handle];
    }

    self.contentOverlay = [[ZSPassthroughView alloc] initWithFrame:CGRectZero];
    self.contentOverlay.backgroundColor = UIColor.clearColor;
    self.contentOverlay.opaque = NO;
    self.contentOverlay.clipsToBounds = YES;
    self.contentOverlay.layer.cornerRadius = kPanelCornerRadiusMinimum;
    self.contentOverlay.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentOverlay.userInteractionEnabled = YES;
    self.contentOverlay.hidden = YES;
    [unityView addSubview:self.contentOverlay];
    zs_force_dark(self.contentOverlay);

    UIPanGestureRecognizer *closeSwipe = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelSwiped:)];
    closeSwipe.delegate = self;
    [self.contentOverlay addGestureRecognizer:closeSwipe];

    if (zs_has_liquid_glass()) {
        self.panel.backgroundColor = UIColor.clearColor;
        self.panel.clipsToBounds = NO;
        self.panel.layer.cornerRadius = 0;
    } else {
        self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        self.panel.layer.cornerRadius = kPanelCornerRadiusMinimum;
        self.panel.layer.cornerCurve = kCACornerCurveContinuous;
        self.panel.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
        self.panel.clipsToBounds = YES;
    }
    self.panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    if (zs_has_liquid_glass()) {
        self.handle.backgroundColor = UIColor.clearColor;
        self.handle.layer.borderWidth = 0;
    } else {
        self.handle.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        self.handle.layer.cornerRadius = kHandleCornerRadius;
        self.handle.layer.cornerCurve = kCACornerCurveContinuous;
        self.handle.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
        self.handle.layer.borderWidth = 0;
    }
    self.handle.clipsToBounds = NO;

    self.chevron = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, kHandleWidth, 24)];
    self.chevron.textAlignment = NSTextAlignmentCenter;
    self.chevron.textColor = [UIColor colorWithWhite:1 alpha:0.66];
    self.chevron.font = zs_mono_font(15, UIFontWeightLight);
    self.chevron.text = @"‹";
    self.chevron.center = CGPointMake(kHandleWidth * 0.5, kHandleHeight * 0.5);
    [self.handle addSubview:self.chevron];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_closeButtonTapped)];
    [self.handle addGestureRecognizer:tap];
    self.handle.userInteractionEnabled = YES;

    [self buildDocsPanel:unityView];

    if (!zs_has_liquid_glass()) {
        [self.glassContainerContent sendSubviewToBack:self.handle];
    }

    self.syslogLines = [NSMutableArray array];
    self.syslogBlacklist = [NSMutableOrderedSet orderedSet];

    self.syslogTextLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.syslogTextLabel.backgroundColor = UIColor.clearColor;
    self.syslogTextLabel.opaque = NO;
    self.syslogTextLabel.numberOfLines = 0;
    self.syslogTextLabel.textAlignment = NSTextAlignmentLeft;
    self.syslogTextLabel.lineBreakMode = NSLineBreakByClipping;
    self.syslogTextLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:5.5]
        ?: [UIFont monospacedSystemFontOfSize:5.5 weight:UIFontWeightRegular];
    self.syslogTextLabel.translatesAutoresizingMaskIntoConstraints = NO;

    __weak typeof(self) weakSelf = self;
    [ZSyslogController sharedController].lineHandler = ^(NSString *line) {
        [weakSelf appendSyslogLine:line];
    };

    self.scrollViewport = [[UIView alloc] init];
    self.scrollViewport.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollViewport.backgroundColor = UIColor.clearColor;
    self.scrollViewport.clipsToBounds = NO;
    [self.contentOverlay addSubview:self.scrollViewport];

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.alwaysBounceVertical = NO;
    self.scrollView.bounces = NO;
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.scrollView.delegate = self;

    self.scrollView.delaysContentTouches = NO;
    [self.scrollViewport addSubview:self.scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollViewport.topAnchor constraintEqualToAnchor:self.contentOverlay.topAnchor],
        [self.scrollViewport.leadingAnchor constraintEqualToAnchor:self.contentOverlay.leadingAnchor],
        [self.scrollViewport.trailingAnchor constraintEqualToAnchor:self.contentOverlay.trailingAnchor],
        [self.scrollViewport.bottomAnchor constraintEqualToAnchor:self.contentOverlay.bottomAnchor],

        [self.scrollView.topAnchor constraintEqualToAnchor:self.scrollViewport.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.scrollViewport.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.scrollViewport.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.scrollViewport.bottomAnchor],
    ]];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = kRowSpacing;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:kPanelPadding],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:kPanelPadding],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-kPanelPadding],
        [self.stack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-(kPanelPadding * 2)],
    ]];

    UIImageView *signatureOverlay = zs_make_signature_overlay();
    if (signatureOverlay) {
        [self.scrollView addSubview:signatureOverlay];
        [NSLayoutConstraint activateConstraints:@[
            [signatureOverlay.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:kZSSignatureInset],
            [signatureOverlay.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-kZSSignatureInset],
        ]];
    }

    zs_ensure_settings_loaded_from_disk();

    zs_set_auto_unload_on_memory_warning(g_expAutoUnloadOnMemoryWarning);
    zs_set_debug_log_memory_usage_tier(g_expDebugLogMemoryUsageTier);
    zs_set_auto_unload_on_elevated_memory_usage(g_expAutoUnloadOnElevatedMemoryUsage);

    for (NSString *term in g_syslogBlacklist) {
        [self.syslogBlacklist addObject:term];
    }

    NSString *(^fpsFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%d", (int)roundf(v)]; };
    NSString *(^twoDecimalFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.2f", v]; };
    NSString *(^wholeNumberFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.0f", v]; };

    UIView *titleBlock = zs_make_title_block();
    [self.stack addArrangedSubview:titleBlock];
    [self.stack setCustomSpacing:kSectionSpacing afterView:titleBlock];

    self.updateStatusDot = objc_getAssociatedObject(titleBlock, @"zs_update_dot");
    self.updateStatusLabel = objc_getAssociatedObject(titleBlock, @"zs_update_label");
    UITapGestureRecognizer *updateStatusTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(updateStatusLabelTapped:)];
    [self.updateStatusLabel addGestureRecognizer:updateStatusTap];
    UILabel *titleHeaderLabel = objc_getAssociatedObject(titleBlock, @"zs_header_label");
    UITapGestureRecognizer *developerUnlockTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_titleHeaderTapped:)];
    [titleHeaderLabel addGestureRecognizer:developerUnlockTap];
    UILongPressGestureRecognizer *updateStatusLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(updateStatusLabelLongPressed:)];
    updateStatusLongPress.minimumPressDuration = 1.0;
    [self.updateStatusLabel addGestureRecognizer:updateStatusLongPress];
    [self zs_beginUpdateCheck];

    self.pendingCollapsedStates = zs_load_collapsed_section_states();
    self.pendingSectionBuilders = [NSMutableArray array];
    self.pendingExperimentalSectionBuilders = [NSMutableArray array];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Display", self, @selector(docsInfoTapped:));

    ZSRow *normalRow = zs_make_slider_row(@"Menu FPS", 10, 120, g_menuFPS, fpsFormat);
    self.normalFpsSlider = normalRow.slider;
    self.normalFpsValueLabel = normalRow.valueLabel;
    normalRow.slider.defaultValue = kDefaultMenuFPS;
    normalRow.slider.hasDefaultValue = YES;
    [normalRow.slider addTarget:self action:@selector(normalFpsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:normalRow];

    ZSRow *combatRow = zs_make_slider_row(@"Combat FPS", 10, 120, g_combatFPS, fpsFormat);
    self.combatFpsSlider = combatRow.slider;
    self.combatFpsValueLabel = combatRow.valueLabel;
    combatRow.slider.defaultValue = kDefaultCombatFPS;
    combatRow.slider.hasDefaultValue = YES;
    [combatRow.slider addTarget:self action:@selector(combatFpsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:combatRow];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Rendering", self, @selector(docsInfoTapped:));

    ZSRow *scaleRow = zs_make_slider_row(@"Render Scale", 25, 100, g_renderScale * 100.0f, ^NSString *(float v) {
        if (fabsf(v - 50.0f) <= kDefaultValueEpsilon) return @"low";
        if (fabsf(v - 75.0f) <= kDefaultValueEpsilon) return @"med";
        if (fabsf(v - 100.0f) <= kDefaultValueEpsilon) return @"high";
        return [NSString stringWithFormat:@"%.2f", v / 100.0];
    });
    scaleRow.slider.defaultValue = kDefaultRenderScalePct;
    scaleRow.slider.hasDefaultValue = YES;
    scaleRow.slider.indicatorValues = @[@50.0f, @75.0f];
    [scaleRow.slider addTarget:self action:@selector(scaleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:scaleRow];

    ZSRow *battleScaleRow = zs_make_slider_row(@"Battle RS", 25, 100, g_battleRenderScale * 100.0f, ^NSString *(float v) {
        if (fabsf(v - 50.0f) <= kDefaultValueEpsilon) return @"low";
        if (fabsf(v - 75.0f) <= kDefaultValueEpsilon) return @"med";
        if (fabsf(v - 100.0f) <= kDefaultValueEpsilon) return @"high";
        return [NSString stringWithFormat:@"%.2f", v / 100.0];
    });
    battleScaleRow.slider.defaultValue = kDefaultBattleRenderScalePct;
    battleScaleRow.slider.hasDefaultValue = YES;
    battleScaleRow.slider.indicatorValues = @[@50.0f, @75.0f];
    [battleScaleRow.slider addTarget:self action:@selector(battleScaleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:battleScaleRow];

    ZSRow *apRenderScaleMultRow = zs_make_slider_row(@"AP RS Mult", 0.0, 2.0, zs_exp_get_number(@"APRenderScaleMultiplier"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    apRenderScaleMultRow.slider.defaultValue = zs_exp_get_default_number(@"APRenderScaleMultiplier");
    apRenderScaleMultRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(apRenderScaleMultRow.slider, @"zs_exp_key", @"APRenderScaleMultiplier", OBJC_ASSOCIATION_RETAIN);
    [apRenderScaleMultRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:apRenderScaleMultRow];

    ZSRow *texRow = zs_make_mode_slider_row(@"Texture MIP", @[@"0", @"1", @"2", @"3", @"4"], g_textureMip, kDefaultTextureMipEngine);
    [texRow.modeSlider addTarget:self action:@selector(texModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:texRow];

    ZSRow *msaaRow = zs_make_mode_slider_row(@"MSAA", @[@"1x", @"2x", @"4x", @"8x"], g_msaaIndex, kDefaultMSAAIndex);
    [msaaRow.modeSlider addTarget:self action:@selector(msaaChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:msaaRow];

    NSInteger memorylessInitialIndex = (g_expRenderTextureMemorylessMode == 2) ? 1 : (g_expRenderTextureMemorylessMode == 4) ? 2 : (g_expRenderTextureMemorylessMode == 6) ? 3 : 0;
    ZSRow *memorylessRow = zs_make_mode_slider_row(@"RT Memoryless", @[@"Off", @"Depth", @"MSAA", @"Both"], memorylessInitialIndex, 0);
    objc_setAssociatedObject(memorylessRow.modeSlider, @"zs_exp_key", @"RenderTextureMemorylessMode", OBJC_ASSOCIATION_RETAIN);
    [memorylessRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:memorylessRow];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Anti-Aliasing", self, @selector(docsInfoTapped:));

    ZSRow *aaModeRow = zs_make_mode_slider_row(@"AA Mode", @[@"None", @"FXAA", @"SMAA", @"TAA"], g_aaModeIndex, kDefaultAAModeIndex);
    [aaModeRow.modeSlider addTarget:self action:@selector(cameraAAModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:aaModeRow];

    ZSRow *aaQualityRow = zs_make_mode_slider_row(@"AA Quality", @[@"Low", @"Med", @"High"], g_aaQualityIndex, kDefaultAAQualityIndex);
    [aaQualityRow.modeSlider addTarget:self action:@selector(cameraAAQualityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:aaQualityRow];

    ZSRow *ditherRow = zs_make_switch_row(@"Dithering", g_ditheringOn);
    objc_setAssociatedObject(ditherRow.toggle, "zs_defaultBool", @(kDefaultDithering), OBJC_ASSOCIATION_RETAIN);
    [ditherRow.toggle addTarget:self action:@selector(cameraDitheringChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:ditherRow];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Post FX", self, @selector(docsInfoTapped:));

    ZSRow *hdrRow = zs_make_switch_row(@"Bloom", g_hdrOn);
    objc_setAssociatedObject(hdrRow.toggle, "zs_defaultBool", @(kDefaultHDR), OBJC_ASSOCIATION_RETAIN);
    [hdrRow.toggle addTarget:self action:@selector(hdrChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:hdrRow];

    ZSRow *blurIntensityRow = zs_make_slider_row(@"Motion Blur", 0, 1, g_blurIntensity, twoDecimalFormat);
    blurIntensityRow.slider.defaultValue = kDefaultMotionBlur;
    blurIntensityRow.slider.hasDefaultValue = YES;
    [blurIntensityRow.slider addTarget:self action:@selector(blurIntensityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:blurIntensityRow];

    ZSRow *tonemapRow = zs_make_mode_slider_row(@"Tonemap", @[@"None", @"Neutral", @"ACES"], g_tonemapMode, kDefaultTonemapIndex);
    [tonemapRow.modeSlider addTarget:self action:@selector(tonemapModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:tonemapRow];

    for (int i = 0; i < kURPPostEffectCount; i++) {
        const ZSVolumeEffectDef *def = &kURPPostEffects[i];
        NSString *name = [NSString stringWithUTF8String:def->name];
        if (!def->floatField) continue;
        float currentVal = g_urpValue[name] ? g_urpValue[name].floatValue : def->defaultV;

        NSString *(^rowFormat)(float) = (def->maxV >= 20.0f) ? wholeNumberFormat : twoDecimalFormat;
        ZSRow *sliderRow = zs_make_slider_row(name, def->minV, def->maxV, currentVal, rowFormat);
        sliderRow.slider.defaultValue = def->defaultV;
        sliderRow.slider.hasDefaultValue = YES;
        objc_setAssociatedObject(sliderRow.slider, "zs_urp_name", name, OBJC_ASSOCIATION_RETAIN);
        [sliderRow.slider addTarget:self action:@selector(urpEffectValueChanged:) forControlEvents:UIControlEventValueChanged];
        [self.stack addArrangedSubview:sliderRow];
    }
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Particles", self, @selector(docsInfoTapped:));

    ZSRow *particleAlignmentRow = zs_make_wheel_row(@"Alignment",
        @[@"View", @"World", @"Local", @"Facing", @"Default"],
        g_expParticleAlignment, kZSParticleAlignmentPreserveOriginal);
    [particleAlignmentRow.wheelPicker addTarget:self action:@selector(particleAlignmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleAlignmentRow];

    ZSRow *particleRenderModeRow = zs_make_wheel_row(@"Render Mode",
        @[@"Billboard", @"Stretched Billboard", @"Horizontal Billboard", @"Vertical Billboard", @"Mesh", @"None", @"Default"],
        g_expParticleRenderMode, kZSParticleRenderModePreserveOriginal);
    [particleRenderModeRow.wheelPicker addTarget:self action:@selector(particleRenderModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleRenderModeRow];

    ZSRow *particleSortModeRow = zs_make_wheel_row(@"Sort Mode",
        @[@"None", @"Distance", @"Oldest Front", @"Youngest Front"],
        g_expParticleSortMode, 0);
    [particleSortModeRow.wheelPicker addTarget:self action:@selector(particleSortModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleSortModeRow];

    ZSRow *particleMinSizeRow = zs_make_slider_row(@"Min Size", 0, 1, g_expParticleMinSize, (^NSString *(float v){return [NSString stringWithFormat:@"%.2f",v];}));
    particleMinSizeRow.slider.defaultValue = 0; particleMinSizeRow.slider.hasDefaultValue = YES;
    [particleMinSizeRow.slider addTarget:self action:@selector(particleMinSizeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleMinSizeRow];

    ZSRow *particleMaxSizeRow = zs_make_slider_row(@"Max Size", 0, 1, g_expParticleMaxSize, (^NSString *(float v){return [NSString stringWithFormat:@"%.2f",v];}));
    particleMaxSizeRow.slider.defaultValue = 0.5; particleMaxSizeRow.slider.hasDefaultValue = YES;
    [particleMaxSizeRow.slider addTarget:self action:@selector(particleMaxSizeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleMaxSizeRow];

    ZSRow *particleFreeformRow = zs_make_switch_row(@"Freeform Stretching", g_expParticleFreeformStretching);
    objc_setAssociatedObject(particleFreeformRow.toggle, @"zs_defaultBool", @NO, OBJC_ASSOCIATION_RETAIN);
    [particleFreeformRow.toggle addTarget:self action:@selector(particleFreeformChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleFreeformRow];

    ZSRow *particleCapEnabledRow = zs_make_switch_row(@"Max Count Cap", g_expParticleMaxParticlesCapEnabled);
    objc_setAssociatedObject(particleCapEnabledRow.toggle, @"zs_defaultBool", @NO, OBJC_ASSOCIATION_RETAIN);
    [particleCapEnabledRow.toggle addTarget:self action:@selector(particleCapEnabledChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleCapEnabledRow];

    ZSRow *particleCapRow = zs_make_slider_row(@"Max Cap", 1, 300, g_expParticleMaxParticlesCap, (^NSString *(float v){return [NSString stringWithFormat:@"%d", (int)roundf(v)];}));
    particleCapRow.slider.defaultValue = 50; particleCapRow.slider.hasDefaultValue = YES;
    [particleCapRow.slider addTarget:self action:@selector(particleCapChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleCapRow];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header(self.stack, @"Memory management", self);

    UIButton *memoryCleanupButton = zs_make_grouped_action_button(@"Memory cleanup", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [memoryCleanupButton addTarget:self action:@selector(memoryCleanupTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.memoryUsageAnalyzeButton = zs_make_grouped_action_button(@"Analyze memory usage", zs_accent_green_color());
    [self.memoryUsageAnalyzeButton addTarget:self action:@selector(memoryUsageAnalyzeTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIView *memoryActionsCard = zs_make_grouped_action_card(@[
        memoryCleanupButton,
        self.memoryUsageAnalyzeButton,
    ]);
    memoryActionsCard.layer.borderWidth = 1;
    memoryActionsCard.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;

    [self.stack addArrangedSubview:memoryActionsCard];
    [self.stack setCustomSpacing:12 afterView:memoryActionsCard];

    UIView *memoryUsageCard = [self zs_buildMemoryUsageCard];
    [self.stack addArrangedSubview:memoryUsageCard];
    [self.stack setCustomSpacing:kSectionSpacing afterView:memoryUsageCard];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Mods", self, @selector(docsInfoTapped:));
    ZSRow *modsRow = zs_make_button_pair_row(
        @"Load Mods", [UIColor colorWithRed:0.55 green:0.42 blue:1.0 alpha:1.0],
        @"Restore Originals", [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]);
    UIButton *loadModsButton = objc_getAssociatedObject(modsRow, "zs_button_left");
    [loadModsButton addTarget:self action:@selector(loadModsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *restoreOriginalsButton = objc_getAssociatedObject(modsRow, "zs_button_right");

    zs_attach_tap_to_confirm(restoreOriginalsButton, self,
        @"Restore Originals?", @"Every modded file will be restored to the game's original files.", @"Restore", YES, ^{
        [weakSelf restoreOriginalsTapped];
    });
    [self.stack addArrangedSubview:modsRow];

    self.modsLibraryExpandedFolders = [NSMutableSet set];
    self.modsLibraryExpandedInfoEntries = [NSMutableSet set];
    self.modsLibraryStack = [[UIStackView alloc] init];
    self.modsLibraryStack.axis = UILayoutConstraintAxisVertical;
    self.modsLibraryStack.spacing = 2;
    self.modsLibraryStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.modsLibraryStack];
    [self zs_rebuildModsLibrary];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Auth", self, @selector(docsInfoTapped:));

    self.authRepoLinkField = [[UITextField alloc] init];
    self.authRepoLinkField.keyboardType = UIKeyboardTypeURL;
    self.authRepoLinkField.delegate = self;

    self.authTokenField = [[UITextField alloc] init];
    self.authTokenField.delegate = self;

    self.authVerifyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    zs_style_auth_verify_button(self.authVerifyButton, @"Verify");
    [self.authVerifyButton addTarget:self action:@selector(zs_authVerifyTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.authStatusLabel = [[UILabel alloc] init];
    UIView *authCard = zs_make_auth_credentials_card(self.authRepoLinkField, self.authTokenField, self.authVerifyButton, self.authStatusLabel);
    self.authRepoLinkFieldContainer = self.authRepoLinkField;
    self.authTokenFieldContainer = self.authTokenField;
    [self.stack addArrangedSubview:authCard];
    [self.stack setCustomSpacing:8 afterView:authCard];

    [self zs_loadAuthFields];

    [self zs_authRunBootVerification];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Debug", self, @selector(docsInfoTapped:));

    ZSRow *syslogRow = zs_make_button_and_glass_field_row(@"Syslog",
                                                            [UIColor colorWithWhite:1 alpha:0.88],
                                                            @"Blacklist keywords");
    UIButton *syslogButton = objc_getAssociatedObject(syslogRow, "zs_button");
    self.syslogButton = syslogButton;

    [syslogButton addTarget:self action:@selector(toggleSyslogTapped) forControlEvents:UIControlEventTouchUpInside];

    UILongPressGestureRecognizer *syslogHold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleSyslogButtonLongPress:)];
    syslogHold.minimumPressDuration = 0;
    syslogHold.cancelsTouchesInView = NO;
    [syslogButton addGestureRecognizer:syslogHold];

    self.syslogBlacklistField = objc_getAssociatedObject(syslogRow, "zs_textfield");
    self.syslogBlacklistField.delegate = self;
    self.syslogBlacklistField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"add keyword(s)" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];

    UILabel *blacklistHeader = [[UILabel alloc] init];
    blacklistHeader.translatesAutoresizingMaskIntoConstraints = NO;
    blacklistHeader.text = @"KEYWORD FILTER";
    blacklistHeader.font = zs_mono_font(9, UIFontWeightSemibold);
    blacklistHeader.textColor = [UIColor colorWithWhite:0.9 alpha:1];

    self.syslogBlacklistStatusLabel = [[UILabel alloc] init];
    self.syslogBlacklistStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.syslogBlacklistStatusLabel.font = zs_mono_font(9, UIFontWeightRegular);
    self.syslogBlacklistStatusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    self.syslogBlacklistStatusLabel.text = @"NO TERMS";

    self.syslogBlacklistEntriesStack = [[UIStackView alloc] init];
    self.syslogBlacklistEntriesStack.axis = UILayoutConstraintAxisHorizontal;
    self.syslogBlacklistEntriesStack.spacing = 5;
    self.syslogBlacklistEntriesStack.alignment = UIStackViewAlignmentCenter;
    self.syslogBlacklistEntriesStack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *blacklistEntriesScroll = [[UIScrollView alloc] init];
    blacklistEntriesScroll.translatesAutoresizingMaskIntoConstraints = NO;
    blacklistEntriesScroll.backgroundColor = UIColor.clearColor;
    blacklistEntriesScroll.showsHorizontalScrollIndicator = NO;
    blacklistEntriesScroll.showsVerticalScrollIndicator = NO;
    blacklistEntriesScroll.alwaysBounceHorizontal = YES;
    [blacklistEntriesScroll addSubview:self.syslogBlacklistEntriesStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.syslogBlacklistEntriesStack.leadingAnchor constraintEqualToAnchor:blacklistEntriesScroll.contentLayoutGuide.leadingAnchor],
        [self.syslogBlacklistEntriesStack.trailingAnchor constraintEqualToAnchor:blacklistEntriesScroll.contentLayoutGuide.trailingAnchor],
        [self.syslogBlacklistEntriesStack.topAnchor constraintEqualToAnchor:blacklistEntriesScroll.contentLayoutGuide.topAnchor],
        [self.syslogBlacklistEntriesStack.bottomAnchor constraintEqualToAnchor:blacklistEntriesScroll.contentLayoutGuide.bottomAnchor],
        [self.syslogBlacklistEntriesStack.heightAnchor constraintEqualToAnchor:blacklistEntriesScroll.frameLayoutGuide.heightAnchor],
    ]];

    [self zs_rebuildSyslogBlacklistEntries];

    UIView *syslogContentHost;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *syslogGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        syslogGlass.translatesAutoresizingMaskIntoConstraints = NO;
        zs_configure_glass_corners(syslogGlass, 14, NO);
        zs_register_suspendable_glass(syslogGlass);
        self.syslogConsoleContainer = syslogGlass;
        syslogContentHost = syslogGlass.contentView;
    } else {
        UIView *plain = [[UIView alloc] init];
        plain.translatesAutoresizingMaskIntoConstraints = NO;
        plain.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1];
        plain.layer.cornerRadius = 14;
        plain.layer.cornerCurve = kCACornerCurveContinuous;
        plain.clipsToBounds = YES;
        self.syslogConsoleContainer = plain;
        syslogContentHost = plain;
    }
    self.syslogConsoleContainer.hidden = NO;
    self.syslogConsoleContainer.layer.borderWidth = 1;
    self.syslogConsoleContainer.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
    [self.syslogConsoleContainer.heightAnchor constraintEqualToConstant:kZSSyslogConsoleHeight].active = YES;

    self.syslogConsoleScrollView = [[UIScrollView alloc] init];
    self.syslogConsoleScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.syslogConsoleScrollView.backgroundColor = UIColor.clearColor;
    self.syslogConsoleScrollView.showsVerticalScrollIndicator = YES;
    self.syslogConsoleScrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.syslogConsoleScrollView.alwaysBounceVertical = YES;
    [syslogContentHost addSubview:self.syslogConsoleScrollView];

    [self.syslogConsoleScrollView addSubview:self.syslogTextLabel];

    static const CGFloat kZSSyslogConsolePadding = 12;
    [NSLayoutConstraint activateConstraints:@[
        [self.syslogConsoleScrollView.topAnchor constraintEqualToAnchor:self.syslogConsoleContainer.topAnchor],
        [self.syslogConsoleScrollView.leadingAnchor constraintEqualToAnchor:self.syslogConsoleContainer.leadingAnchor],
        [self.syslogConsoleScrollView.trailingAnchor constraintEqualToAnchor:self.syslogConsoleContainer.trailingAnchor],
        [self.syslogConsoleScrollView.bottomAnchor constraintEqualToAnchor:self.syslogConsoleContainer.bottomAnchor],

        [self.syslogTextLabel.topAnchor constraintEqualToAnchor:self.syslogConsoleScrollView.topAnchor constant:kZSSyslogConsolePadding],
        [self.syslogTextLabel.leadingAnchor constraintEqualToAnchor:self.syslogConsoleScrollView.leadingAnchor constant:kZSSyslogConsolePadding],
        [self.syslogTextLabel.trailingAnchor constraintEqualToAnchor:self.syslogConsoleScrollView.trailingAnchor constant:-kZSSyslogConsolePadding],
        [self.syslogTextLabel.bottomAnchor constraintEqualToAnchor:self.syslogConsoleScrollView.bottomAnchor constant:-kZSSyslogConsolePadding],
        [self.syslogTextLabel.widthAnchor constraintEqualToAnchor:self.syslogConsoleScrollView.widthAnchor constant:-(kZSSyslogConsolePadding * 2)],
    ]];

    UIView *syslogBlacklistCard = zs_make_syslog_blacklist_card(syslogRow,
                                                                 blacklistHeader,
                                                                 self.syslogBlacklistStatusLabel,
                                                                 blacklistEntriesScroll);
    [self.stack addArrangedSubview:syslogBlacklistCard];
    [self.stack setCustomSpacing:8 afterView:syslogBlacklistCard];
    [self.stack addArrangedSubview:self.syslogConsoleContainer];

    self.syslogTabEnabled = NO;
    [self zs_renderSyslogBuffer];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Miscellaneous", self, @selector(docsInfoTapped:));

    ZSRow *customGreetingRow = zs_make_custom_greeting_row(zs_custom_greeting_text(), self,
                                                            @selector(zs_customGreetingTextButtonTapped:));
    self.customGreetingTextButton = objc_getAssociatedObject(customGreetingRow, "zs_button");

    ZSRow *uidRedactorRow = zs_make_switch_row(@"Hide user ID", UIDRedactor.isEnabled);
    [uidRedactorRow.toggle addTarget:self action:@selector(uidRedactorChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *disableLiquidGlassRow = zs_make_switch_row(@"Disable Liquid Glass", zs_liquid_glass_disabled_by_user());
    [disableLiquidGlassRow.toggle addTarget:self action:@selector(disableLiquidGlassChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *disableEnkephalinRow = zs_make_switch_row(@"Disable Enkephalin", zs_enkephalin_disabled_by_user());
    [disableEnkephalinRow.toggle addTarget:self action:@selector(disableEnkephalinChanged:) forControlEvents:UIControlEventValueChanged];

    [self.stack addArrangedSubview:customGreetingRow];
    [self.stack setCustomSpacing:8 afterView:customGreetingRow];
    [self.stack addArrangedSubview:uidRedactorRow];
    [self.stack setCustomSpacing:8 afterView:uidRedactorRow];
    [self.stack addArrangedSubview:disableLiquidGlassRow];
    [self.stack setCustomSpacing:8 afterView:disableLiquidGlassRow];
    [self.stack addArrangedSubview:disableEnkephalinRow];
    [self.stack setCustomSpacing:kSectionSpacing afterView:disableEnkephalinRow];
    }];

    [self.pendingSectionBuilders addObject:^{
    NSUInteger developerViewsStart = self.stack.arrangedSubviews.count;
    zs_add_section_header(self.stack, @"Developer", self);

    ZSRow *overrideTutorialRow = zs_make_switch_row(@"Override tutorial completion", zs_tutorial_override_completion_enabled());
    [overrideTutorialRow.toggle addTarget:self action:@selector(overrideTutorialCompletionChanged:) forControlEvents:UIControlEventValueChanged];

    UIButton *dumpIL2CPPMethodsButton = zs_make_grouped_action_button(@"Dump IL2CPP Methods", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [dumpIL2CPPMethodsButton addTarget:self action:@selector(dumpIL2CPPMethodsTapped) forControlEvents:UIControlEventTouchUpInside];

    UIView *developerActionsCard = zs_make_grouped_action_card(@[
        dumpIL2CPPMethodsButton,
    ]);
    developerActionsCard.layer.borderWidth = 1;
    developerActionsCard.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;

    [self.stack addArrangedSubview:overrideTutorialRow];
    [self.stack setCustomSpacing:8 afterView:overrideTutorialRow];
    [self.stack addArrangedSubview:developerActionsCard];
    [self.stack setCustomSpacing:kSectionSpacing afterView:developerActionsCard];

    NSArray<UIView *> *arrangedViews = self.stack.arrangedSubviews;
    self.developerSectionViews = [arrangedViews subarrayWithRange:NSMakeRange(developerViewsStart, arrangedViews.count - developerViewsStart)];
    [self zs_applyDeveloperSectionVisibilityRelayout:NO];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Config", self, @selector(docsInfoTapped:));

    NSString *currentReencodeFormat = [ZTranscoderSettings loadConfig].outputFormat;
    if (currentReencodeFormat.length == 0) currentReencodeFormat = kZSDefaultReencodeFormat;
    ZSRow *reencodeFormatRow = zs_make_reencode_format_row(currentReencodeFormat, self,
                                                            @selector(zs_reencodeFormatButtonTapped:));
    self.reencodeFormatButton = objc_getAssociatedObject(reencodeFormatRow, "zs_button");

    ZSRow *manifestZeroingRow = zs_make_switch_row(@"Manifest zeroing", PatchManifestNetwork.isZeroAllEnabled);
    [manifestZeroingRow.toggle addTarget:self action:@selector(manifestZeroingChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *lz4hcRow = zs_make_switch_row(@"LZ4HC compression on dispatch", ZTranscoderService.isUploadCompressionEnabled);
    [lz4hcRow.toggle addTarget:self action:@selector(lz4hcCompressionChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *checkCIBuildsRow = zs_make_switch_row(@"Enable nightly builds", zs_update_uses_nightly_releases());
    [checkCIBuildsRow.toggle addTarget:self action:@selector(nightlyReleasesEnabledChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *experimentalEnabledRow = zs_make_switch_row(@"Enable Experimental Settings", g_experimentalSettingsEnabled);
    [experimentalEnabledRow.toggle addTarget:self action:@selector(experimentalSettingsEnabledChanged:) forControlEvents:UIControlEventValueChanged];

    UIButton *manualIndexButton = zs_make_grouped_action_button(@"Manually Index Files", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [manualIndexButton addTarget:self action:@selector(manuallyIndexFilesTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *resetButton = zs_make_grouped_action_button(@"Reset Settings", [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]);
    [resetButton addTarget:self action:@selector(resetSettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *reapplyButton = zs_make_grouped_action_button(@"Reapply Settings", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [reapplyButton addTarget:self action:@selector(reapplySettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIView *resetReapplyRow = zs_make_grouped_action_pair_row(resetButton, reapplyButton);

    UIButton *deleteSpecificAssetButton = zs_make_grouped_action_button(@"Delete Specific Asset", [UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:1.0]);
    [deleteSpecificAssetButton addTarget:self action:@selector(deleteSpecificAssetTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *hardResetButton = zs_make_grouped_action_button(@"Hard Assets Reset", [UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:1.0]);
    zs_attach_tap_to_confirm(hardResetButton, self,
        @"Hard Assets Reset?", @"This deletes every cached bundle, bank, backup, and Mod Asset Library entry, along with every game file ZSingularity has ever logged by path. This can't be undone.", @"Reset", YES, ^{
        [weakSelf hardAssetsResetTapped];
    });

    UIButton *deleteProxyReleasesButton = zs_make_grouped_action_button(@"Delete Stored Bundles in Proxy", [UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:1.0]);
    zs_attach_tap_to_confirm(deleteProxyReleasesButton, self,
        @"Delete Stored Bundles in Proxy?", @"Every bundle stored in the transcoder proxy will be permanently deleted.", @"Delete", YES, ^{
        [weakSelf deleteStoredBundlesInProxyTapped:deleteProxyReleasesButton];
    });

    UIView *configActionsCard = zs_make_grouped_action_card(@[
        manualIndexButton,
        resetReapplyRow,
        deleteSpecificAssetButton,
        hardResetButton,
        deleteProxyReleasesButton,
    ]);
    configActionsCard.layer.borderWidth = 1;
    configActionsCard.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;

    [self.stack addArrangedSubview:reencodeFormatRow];
    [self.stack setCustomSpacing:8 afterView:reencodeFormatRow];
    [self.stack addArrangedSubview:manifestZeroingRow];
    [self.stack setCustomSpacing:8 afterView:manifestZeroingRow];
    [self.stack addArrangedSubview:lz4hcRow];
    [self.stack setCustomSpacing:8 afterView:lz4hcRow];
    [self.stack addArrangedSubview:checkCIBuildsRow];
    [self.stack setCustomSpacing:8 afterView:checkCIBuildsRow];
    [self.stack addArrangedSubview:experimentalEnabledRow];
    [self.stack setCustomSpacing:8 afterView:experimentalEnabledRow];
    [self.stack addArrangedSubview:configActionsCard];
    [self.stack setCustomSpacing:kSectionSpacing afterView:configActionsCard];

    self.experimentalSectionContainer = [[UIStackView alloc] init];
    self.experimentalSectionContainer.axis = UILayoutConstraintAxisVertical;
    self.experimentalSectionContainer.spacing = kRowSpacing;
    self.experimentalSectionContainer.hidden = !g_experimentalSettingsEnabled;
    [self.stack addArrangedSubview:self.experimentalSectionContainer];
    [self.stack setCustomSpacing:kSectionSpacing afterView:configActionsCard];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Camera & Rendering", self);
    ZSRow *expPixelLightCountRow = zs_make_slider_row(@"Pixel Light Count", 0, 8, zs_exp_get_number(@"PixelLightCount"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expPixelLightCountRow.slider.defaultValue = zs_exp_get_default_number(@"PixelLightCount");
    expPixelLightCountRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expPixelLightCountRow.slider, @"zs_exp_key", @"PixelLightCount", OBJC_ASSOCIATION_RETAIN);
    [expPixelLightCountRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expPixelLightCountRow];
    ZSRow *expLODBiasRow = zs_make_slider_row(@"LOD Bias", 0.1, 4.0, zs_exp_get_number(@"LODBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expLODBiasRow.slider.defaultValue = zs_exp_get_default_number(@"LODBias");
    expLODBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expLODBiasRow.slider, @"zs_exp_key", @"LODBias", OBJC_ASSOCIATION_RETAIN);
    [expLODBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLODBiasRow];
    ZSRow *expLODCrossFadeRow = zs_make_switch_row(@"LOD Cross-Fade", zs_exp_get_bool(@"LODCrossFade"));
    objc_setAssociatedObject(expLODCrossFadeRow.toggle, @"zs_exp_key", @"LODCrossFade", OBJC_ASSOCIATION_RETAIN);
    [expLODCrossFadeRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLODCrossFadeRow];
    NSInteger VSyncCountSelIdx, VSyncCountDefIdx;
    VSyncCountSelIdx = MAX(0, MIN(3, (NSInteger)zs_exp_get_number(@"VSyncCount")));
    VSyncCountDefIdx = MAX(0, MIN(3, (NSInteger)0));
    ZSRow *expVSyncCountRow = zs_make_mode_slider_row(@"VSync Count", @[@"Off", @"Every VBlank", @"Every 2nd VBlank", @"Every 3rd VBlank"], VSyncCountSelIdx, VSyncCountDefIdx);
    objc_setAssociatedObject(expVSyncCountRow.modeSlider, @"zs_exp_key", @"VSyncCount", OBJC_ASSOCIATION_RETAIN);
    [expVSyncCountRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expVSyncCountRow];
    NSInteger QualityAASelIdx, QualityAADefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"QualityAA"); QualityAASelIdx = zs_exp_idx_QualityAA(v); }
    QualityAADefIdx = zs_exp_idx_QualityAA(1);
    ZSRow *expQualityAARow = zs_make_mode_slider_row(@"Quality AA", @[@"1x", @"2x", @"4x", @"8x"], QualityAASelIdx, QualityAADefIdx);
    objc_setAssociatedObject(expQualityAARow.modeSlider, @"zs_exp_key", @"QualityAA", OBJC_ASSOCIATION_RETAIN);
    [expQualityAARow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expQualityAARow];
    ZSRow *expCameraHDRRow = zs_make_switch_row(@"Camera HDR", zs_exp_get_bool(@"CameraHDR"));
    objc_setAssociatedObject(expCameraHDRRow.toggle, @"zs_exp_key", @"CameraHDR", OBJC_ASSOCIATION_RETAIN);
    [expCameraHDRRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraHDRRow];
    ZSRow *expCameraMSAARow = zs_make_switch_row(@"Camera MSAA", zs_exp_get_bool(@"CameraMSAA"));
    objc_setAssociatedObject(expCameraMSAARow.toggle, @"zs_exp_key", @"CameraMSAA", OBJC_ASSOCIATION_RETAIN);
    [expCameraMSAARow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraMSAARow];
    ZSRow *expDynamicResolutionRow = zs_make_switch_row(@"Dynamic Resolution", zs_exp_get_bool(@"DynamicResolution"));
    objc_setAssociatedObject(expDynamicResolutionRow.toggle, @"zs_exp_key", @"DynamicResolution", OBJC_ASSOCIATION_RETAIN);
    [expDynamicResolutionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expDynamicResolutionRow];
    ZSRow *expOcclusionCullingRow = zs_make_switch_row(@"Occlusion Culling", zs_exp_get_bool(@"OcclusionCulling"));
    objc_setAssociatedObject(expOcclusionCullingRow.toggle, @"zs_exp_key", @"OcclusionCulling", OBJC_ASSOCIATION_RETAIN);
    [expOcclusionCullingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expOcclusionCullingRow];
    ZSRow *expDepthTextureRow = zs_make_switch_row(@"Depth Texture", zs_exp_get_bool(@"DepthTexture"));
    objc_setAssociatedObject(expDepthTextureRow.toggle, @"zs_exp_key", @"DepthTexture", OBJC_ASSOCIATION_RETAIN);
    [expDepthTextureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expDepthTextureRow];
    ZSRow *expOpaqueTextureRow = zs_make_switch_row(@"Opaque Texture", zs_exp_get_bool(@"OpaqueTexture"));
    objc_setAssociatedObject(expOpaqueTextureRow.toggle, @"zs_exp_key", @"OpaqueTexture", OBJC_ASSOCIATION_RETAIN);
    [expOpaqueTextureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expOpaqueTextureRow];
    ZSRow *expRenderShadowsRow = zs_make_switch_row(@"Render Shadows", zs_exp_get_bool(@"RenderShadows"));
    objc_setAssociatedObject(expRenderShadowsRow.toggle, @"zs_exp_key", @"RenderShadows", OBJC_ASSOCIATION_RETAIN);
    [expRenderShadowsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRenderShadowsRow];
    ZSRow *expPostProcessingRow = zs_make_switch_row(@"Post Processing", zs_exp_get_bool(@"PostProcessing"));
    objc_setAssociatedObject(expPostProcessingRow.toggle, @"zs_exp_key", @"PostProcessing", OBJC_ASSOCIATION_RETAIN);
    [expPostProcessingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expPostProcessingRow];
    NSInteger AntialiasingModeSelIdx, AntialiasingModeDefIdx;
    AntialiasingModeSelIdx = MAX(0, MIN(3, (NSInteger)zs_exp_get_number(@"AntialiasingMode")));
    AntialiasingModeDefIdx = MAX(0, MIN(3, (NSInteger)3));
    ZSRow *expAntialiasingModeRow = zs_make_mode_slider_row(@"Antialiasing Mode", @[@"None", @"FXAA", @"SMAA", @"TAA"], AntialiasingModeSelIdx, AntialiasingModeDefIdx);
    objc_setAssociatedObject(expAntialiasingModeRow.modeSlider, @"zs_exp_key", @"AntialiasingMode", OBJC_ASSOCIATION_RETAIN);
    [expAntialiasingModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAntialiasingModeRow];
    NSInteger AntialiasingQualitySelIdx, AntialiasingQualityDefIdx;
    AntialiasingQualitySelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"AntialiasingQuality")));
    AntialiasingQualityDefIdx = MAX(0, MIN(2, (NSInteger)2));
    ZSRow *expAntialiasingQualityRow = zs_make_mode_slider_row(@"Antialiasing Quality", @[@"Low", @"Medium", @"High"], AntialiasingQualitySelIdx, AntialiasingQualityDefIdx);
    objc_setAssociatedObject(expAntialiasingQualityRow.modeSlider, @"zs_exp_key", @"AntialiasingQuality", OBJC_ASSOCIATION_RETAIN);
    [expAntialiasingQualityRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAntialiasingQualityRow];
    ZSRow *expCameraDitheringRow = zs_make_switch_row(@"Camera Dithering", zs_exp_get_bool(@"CameraDithering"));
    objc_setAssociatedObject(expCameraDitheringRow.toggle, @"zs_exp_key", @"CameraDithering", OBJC_ASSOCIATION_RETAIN);
    [expCameraDitheringRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraDitheringRow];
    NSInteger CameraRequiresDepthOptionSelIdx, CameraRequiresDepthOptionDefIdx;
    CameraRequiresDepthOptionSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"CameraRequiresDepthOption")));
    CameraRequiresDepthOptionDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expCameraRequiresDepthOptionRow = zs_make_mode_slider_row(@"Camera Requires Depth", @[@"Off", @"On", @"Use Pipeline Settings"], CameraRequiresDepthOptionSelIdx, CameraRequiresDepthOptionDefIdx);
    objc_setAssociatedObject(expCameraRequiresDepthOptionRow.modeSlider, @"zs_exp_key", @"CameraRequiresDepthOption", OBJC_ASSOCIATION_RETAIN);
    [expCameraRequiresDepthOptionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRequiresDepthOptionRow];
    NSInteger CameraRequiresColorOptionSelIdx, CameraRequiresColorOptionDefIdx;
    CameraRequiresColorOptionSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"CameraRequiresColorOption")));
    CameraRequiresColorOptionDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expCameraRequiresColorOptionRow = zs_make_mode_slider_row(@"Camera Requires Color", @[@"Off", @"On", @"Use Pipeline Settings"], CameraRequiresColorOptionSelIdx, CameraRequiresColorOptionDefIdx);
    objc_setAssociatedObject(expCameraRequiresColorOptionRow.modeSlider, @"zs_exp_key", @"CameraRequiresColorOption", OBJC_ASSOCIATION_RETAIN);
    [expCameraRequiresColorOptionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRequiresColorOptionRow];
    NSInteger CameraRenderTypeSelIdx, CameraRenderTypeDefIdx;
    CameraRenderTypeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"CameraRenderType")));
    CameraRenderTypeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expCameraRenderTypeRow = zs_make_mode_slider_row(@"Camera Render Type", @[@"Base", @"Overlay"], CameraRenderTypeSelIdx, CameraRenderTypeDefIdx);
    objc_setAssociatedObject(expCameraRenderTypeRow.modeSlider, @"zs_exp_key", @"CameraRenderType", OBJC_ASSOCIATION_RETAIN);
    [expCameraRenderTypeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRenderTypeRow];
    ZSRow *expCameraRequiresDepthTextureRow = zs_make_switch_row(@"Camera Requires Depth Texture", zs_exp_get_bool(@"CameraRequiresDepthTexture"));
    objc_setAssociatedObject(expCameraRequiresDepthTextureRow.toggle, @"zs_exp_key", @"CameraRequiresDepthTexture", OBJC_ASSOCIATION_RETAIN);
    [expCameraRequiresDepthTextureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRequiresDepthTextureRow];
    ZSRow *expCameraRequiresColorTextureRow = zs_make_switch_row(@"Camera Requires Color Texture", zs_exp_get_bool(@"CameraRequiresColorTexture"));
    objc_setAssociatedObject(expCameraRequiresColorTextureRow.toggle, @"zs_exp_key", @"CameraRequiresColorTexture", OBJC_ASSOCIATION_RETAIN);
    [expCameraRequiresColorTextureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRequiresColorTextureRow];
    ZSRow *expCameraResetHistoryRow = zs_make_switch_row(@"Camera Reset History", zs_exp_get_bool(@"CameraResetHistory"));
    objc_setAssociatedObject(expCameraResetHistoryRow.toggle, @"zs_exp_key", @"CameraResetHistory", OBJC_ASSOCIATION_RETAIN);
    [expCameraResetHistoryRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraResetHistoryRow];
    ZSRow *expCameraStopNaNRow = zs_make_switch_row(@"Camera Stop NaN", zs_exp_get_bool(@"CameraStopNaN"));
    objc_setAssociatedObject(expCameraStopNaNRow.toggle, @"zs_exp_key", @"CameraStopNaN", OBJC_ASSOCIATION_RETAIN);
    [expCameraStopNaNRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraStopNaNRow];
    ZSRow *expCameraAllowXRRow = zs_make_switch_row(@"Camera Allow XR", zs_exp_get_bool(@"CameraAllowXR"));
    objc_setAssociatedObject(expCameraAllowXRRow.toggle, @"zs_exp_key", @"CameraAllowXR", OBJC_ASSOCIATION_RETAIN);
    [expCameraAllowXRRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraAllowXRRow];
    ZSRow *expCameraScreenCoordOverrideRow = zs_make_switch_row(@"Camera Screen Coord Override", zs_exp_get_bool(@"CameraScreenCoordOverride"));
    objc_setAssociatedObject(expCameraScreenCoordOverrideRow.toggle, @"zs_exp_key", @"CameraScreenCoordOverride", OBJC_ASSOCIATION_RETAIN);
    [expCameraScreenCoordOverrideRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraScreenCoordOverrideRow];
    ZSRow *expCameraHDROutputRow = zs_make_switch_row(@"Camera HDR Output", zs_exp_get_bool(@"CameraHDROutput"));
    objc_setAssociatedObject(expCameraHDROutputRow.toggle, @"zs_exp_key", @"CameraHDROutput", OBJC_ASSOCIATION_RETAIN);
    [expCameraHDROutputRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraHDROutputRow];
    NSInteger UpscalingFilterSelIdx, UpscalingFilterDefIdx;
    UpscalingFilterSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"UpscalingFilter")));
    UpscalingFilterDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expUpscalingFilterRow = zs_make_mode_slider_row(@"Upscaling Filter", @[@"Automatic", @"Bilinear", @"FSR"], UpscalingFilterSelIdx, UpscalingFilterDefIdx);
    objc_setAssociatedObject(expUpscalingFilterRow.modeSlider, @"zs_exp_key", @"UpscalingFilter", OBJC_ASSOCIATION_RETAIN);
    [expUpscalingFilterRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expUpscalingFilterRow];
    ZSRow *expFSROverrideRow = zs_make_switch_row(@"FSR Override", zs_exp_get_bool(@"FSROverride"));
    objc_setAssociatedObject(expFSROverrideRow.toggle, @"zs_exp_key", @"FSROverride", OBJC_ASSOCIATION_RETAIN);
    [expFSROverrideRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expFSROverrideRow];
    ZSRow *expFSRSharpnessRow = zs_make_slider_row(@"FSR Sharpness", 0.0, 1.0, zs_exp_get_number(@"FSRSharpness"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expFSRSharpnessRow.slider.defaultValue = zs_exp_get_default_number(@"FSRSharpness");
    expFSRSharpnessRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expFSRSharpnessRow.slider, @"zs_exp_key", @"FSRSharpness", OBJC_ASSOCIATION_RETAIN);
    [expFSRSharpnessRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expFSRSharpnessRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"URP Pipeline", self);
    ZSRow *expURPHDRRow = zs_make_switch_row(@"URP HDR", zs_exp_get_bool(@"URPHDR"));
    objc_setAssociatedObject(expURPHDRRow.toggle, @"zs_exp_key", @"URPHDR", OBJC_ASSOCIATION_RETAIN);
    [expURPHDRRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expURPHDRRow];
    NSInteger URPMSAASelIdx, URPMSAADefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"URPMSAA"); URPMSAASelIdx = zs_exp_idx_URPMSAA(v); }
    URPMSAADefIdx = zs_exp_idx_URPMSAA(1);
    ZSRow *expURPMSAARow = zs_make_mode_slider_row(@"URP MSAA", @[@"Disabled", @"2x", @"4x", @"8x"], URPMSAASelIdx, URPMSAADefIdx);
    objc_setAssociatedObject(expURPMSAARow.modeSlider, @"zs_exp_key", @"URPMSAA", OBJC_ASSOCIATION_RETAIN);
    [expURPMSAARow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expURPMSAARow];
    NSInteger MainLightModeSelIdx, MainLightModeDefIdx;
    MainLightModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"MainLightMode")));
    MainLightModeDefIdx = MAX(0, MIN(1, (NSInteger)1));
    ZSRow *expMainLightModeRow = zs_make_mode_slider_row(@"Main Light Mode", @[@"Disabled", @"Enabled"], MainLightModeSelIdx, MainLightModeDefIdx);
    objc_setAssociatedObject(expMainLightModeRow.modeSlider, @"zs_exp_key", @"MainLightMode", OBJC_ASSOCIATION_RETAIN);
    [expMainLightModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expMainLightModeRow];
    ZSRow *expMainLightShadowsRow = zs_make_switch_row(@"Main Light Shadows", zs_exp_get_bool(@"MainLightShadows"));
    objc_setAssociatedObject(expMainLightShadowsRow.toggle, @"zs_exp_key", @"MainLightShadows", OBJC_ASSOCIATION_RETAIN);
    [expMainLightShadowsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expMainLightShadowsRow];
    NSInteger MainShadowResolutionSelIdx, MainShadowResolutionDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"MainShadowResolution"); MainShadowResolutionSelIdx = zs_exp_idx_MainShadowResolution(v); }
    MainShadowResolutionDefIdx = zs_exp_idx_MainShadowResolution(2048);
    ZSRow *expMainShadowResolutionRow = zs_make_mode_slider_row(@"Main Shadow Resolution", @[@"512", @"1024", @"2048", @"4096"], MainShadowResolutionSelIdx, MainShadowResolutionDefIdx);
    objc_setAssociatedObject(expMainShadowResolutionRow.modeSlider, @"zs_exp_key", @"MainShadowResolution", OBJC_ASSOCIATION_RETAIN);
    [expMainShadowResolutionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expMainShadowResolutionRow];
    NSInteger AdditionalLightModeSelIdx, AdditionalLightModeDefIdx;
    AdditionalLightModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"AdditionalLightMode")));
    AdditionalLightModeDefIdx = MAX(0, MIN(2, (NSInteger)1));
    ZSRow *expAdditionalLightModeRow = zs_make_mode_slider_row(@"Additional Light Mode", @[@"Disabled", @"Per Vertex", @"Per Pixel"], AdditionalLightModeSelIdx, AdditionalLightModeDefIdx);
    objc_setAssociatedObject(expAdditionalLightModeRow.modeSlider, @"zs_exp_key", @"AdditionalLightMode", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalLightModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalLightModeRow];
    ZSRow *expMaxAdditionalLightsRow = zs_make_slider_row(@"Max Additional Lights", 0, 16, zs_exp_get_number(@"MaxAdditionalLights"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expMaxAdditionalLightsRow.slider.defaultValue = zs_exp_get_default_number(@"MaxAdditionalLights");
    expMaxAdditionalLightsRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expMaxAdditionalLightsRow.slider, @"zs_exp_key", @"MaxAdditionalLights", OBJC_ASSOCIATION_RETAIN);
    [expMaxAdditionalLightsRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expMaxAdditionalLightsRow];
    ZSRow *expAdditionalLightShadowsRow = zs_make_switch_row(@"Additional Light Shadows", zs_exp_get_bool(@"AdditionalLightShadows"));
    objc_setAssociatedObject(expAdditionalLightShadowsRow.toggle, @"zs_exp_key", @"AdditionalLightShadows", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalLightShadowsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalLightShadowsRow];
    NSInteger AdditionalShadowResolutionSelIdx, AdditionalShadowResolutionDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"AdditionalShadowResolution"); AdditionalShadowResolutionSelIdx = zs_exp_idx_AdditionalShadowResolution(v); }
    AdditionalShadowResolutionDefIdx = zs_exp_idx_AdditionalShadowResolution(512);
    ZSRow *expAdditionalShadowResolutionRow = zs_make_mode_slider_row(@"Additional Shadow Resolution", @[@"256", @"512", @"1024", @"2048"], AdditionalShadowResolutionSelIdx, AdditionalShadowResolutionDefIdx);
    objc_setAssociatedObject(expAdditionalShadowResolutionRow.modeSlider, @"zs_exp_key", @"AdditionalShadowResolution", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalShadowResolutionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalShadowResolutionRow];
    ZSRow *expReflectionProbeBlendingRow = zs_make_switch_row(@"Reflection Probe Blending", zs_exp_get_bool(@"ReflectionProbeBlending"));
    objc_setAssociatedObject(expReflectionProbeBlendingRow.toggle, @"zs_exp_key", @"ReflectionProbeBlending", OBJC_ASSOCIATION_RETAIN);
    [expReflectionProbeBlendingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expReflectionProbeBlendingRow];
    ZSRow *expReflectionProbeBoxProjectionRow = zs_make_switch_row(@"Reflection Probe Box Projection", zs_exp_get_bool(@"ReflectionProbeBoxProjection"));
    objc_setAssociatedObject(expReflectionProbeBoxProjectionRow.toggle, @"zs_exp_key", @"ReflectionProbeBoxProjection", OBJC_ASSOCIATION_RETAIN);
    [expReflectionProbeBoxProjectionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expReflectionProbeBoxProjectionRow];
    ZSRow *expReflectionProbeAtlasRow = zs_make_switch_row(@"Reflection Probe Atlas", zs_exp_get_bool(@"ReflectionProbeAtlas"));
    objc_setAssociatedObject(expReflectionProbeAtlasRow.toggle, @"zs_exp_key", @"ReflectionProbeAtlas", OBJC_ASSOCIATION_RETAIN);
    [expReflectionProbeAtlasRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expReflectionProbeAtlasRow];
    ZSRow *expDynamicBatchingRow = zs_make_switch_row(@"Dynamic Batching", zs_exp_get_bool(@"DynamicBatching"));
    objc_setAssociatedObject(expDynamicBatchingRow.toggle, @"zs_exp_key", @"DynamicBatching", OBJC_ASSOCIATION_RETAIN);
    [expDynamicBatchingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expDynamicBatchingRow];
    ZSRow *expSRPBatcherRow = zs_make_switch_row(@"SRP Batcher", zs_exp_get_bool(@"SRPBatcher"));
    objc_setAssociatedObject(expSRPBatcherRow.toggle, @"zs_exp_key", @"SRPBatcher", OBJC_ASSOCIATION_RETAIN);
    [expSRPBatcherRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expSRPBatcherRow];
    NSInteger ColorGradingModeSelIdx, ColorGradingModeDefIdx;
    ColorGradingModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"ColorGradingMode")));
    ColorGradingModeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expColorGradingModeRow = zs_make_mode_slider_row(@"Color Grading Mode", @[@"Low Dynamic Range", @"High Dynamic Range"], ColorGradingModeSelIdx, ColorGradingModeDefIdx);
    objc_setAssociatedObject(expColorGradingModeRow.modeSlider, @"zs_exp_key", @"ColorGradingMode", OBJC_ASSOCIATION_RETAIN);
    [expColorGradingModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expColorGradingModeRow];
    NSInteger ColorGradingLUTSizeSelIdx, ColorGradingLUTSizeDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"ColorGradingLUTSize"); ColorGradingLUTSizeSelIdx = zs_exp_idx_ColorGradingLUTSize(v); }
    ColorGradingLUTSizeDefIdx = zs_exp_idx_ColorGradingLUTSize(32);
    ZSRow *expColorGradingLUTSizeRow = zs_make_mode_slider_row(@"Color Grading L U T Size", @[@"16", @"32", @"48", @"64"], ColorGradingLUTSizeSelIdx, ColorGradingLUTSizeDefIdx);
    objc_setAssociatedObject(expColorGradingLUTSizeRow.modeSlider, @"zs_exp_key", @"ColorGradingLUTSize", OBJC_ASSOCIATION_RETAIN);
    [expColorGradingLUTSizeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expColorGradingLUTSizeRow];
    NSInteger GPUResidentDrawerModeSelIdx, GPUResidentDrawerModeDefIdx;
    GPUResidentDrawerModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"GPUResidentDrawerMode")));
    GPUResidentDrawerModeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expGPUResidentDrawerModeRow = zs_make_mode_slider_row(@"GPU Resident Drawer Mode", @[@"Disabled", @"Instanced Drawing"], GPUResidentDrawerModeSelIdx, GPUResidentDrawerModeDefIdx);
    objc_setAssociatedObject(expGPUResidentDrawerModeRow.modeSlider, @"zs_exp_key", @"GPUResidentDrawerMode", OBJC_ASSOCIATION_RETAIN);
    [expGPUResidentDrawerModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expGPUResidentDrawerModeRow];
    ZSRow *expGPUResidentOcclusionRow = zs_make_switch_row(@"GPU Resident Occlusion", zs_exp_get_bool(@"GPUResidentOcclusion"));
    objc_setAssociatedObject(expGPUResidentOcclusionRow.toggle, @"zs_exp_key", @"GPUResidentOcclusion", OBJC_ASSOCIATION_RETAIN);
    [expGPUResidentOcclusionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expGPUResidentOcclusionRow];
    ZSRow *expSmallMeshScreenPercentageRow = zs_make_slider_row(@"Small Mesh Screen Percentage", 0.0, 20.0, zs_exp_get_number(@"SmallMeshScreenPercentage"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expSmallMeshScreenPercentageRow.slider.defaultValue = zs_exp_get_default_number(@"SmallMeshScreenPercentage");
    expSmallMeshScreenPercentageRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expSmallMeshScreenPercentageRow.slider, @"zs_exp_key", @"SmallMeshScreenPercentage", OBJC_ASSOCIATION_RETAIN);
    [expSmallMeshScreenPercentageRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expSmallMeshScreenPercentageRow];
    NSInteger IntermediateTextureModeSelIdx, IntermediateTextureModeDefIdx;
    IntermediateTextureModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"IntermediateTextureMode")));
    IntermediateTextureModeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expIntermediateTextureModeRow = zs_make_mode_slider_row(@"Intermediate Texture Mode", @[@"Automatic", @"Always"], IntermediateTextureModeSelIdx, IntermediateTextureModeDefIdx);
    objc_setAssociatedObject(expIntermediateTextureModeRow.modeSlider, @"zs_exp_key", @"IntermediateTextureMode", OBJC_ASSOCIATION_RETAIN);
    [expIntermediateTextureModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expIntermediateTextureModeRow];
    NSInteger StoreActionsOptimizationSelIdx, StoreActionsOptimizationDefIdx;
    StoreActionsOptimizationSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"StoreActionsOptimization")));
    StoreActionsOptimizationDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expStoreActionsOptimizationRow = zs_make_mode_slider_row(@"Store Actions Optimization", @[@"Automatic", @"Store", @"Discard"], StoreActionsOptimizationSelIdx, StoreActionsOptimizationDefIdx);
    objc_setAssociatedObject(expStoreActionsOptimizationRow.modeSlider, @"zs_exp_key", @"StoreActionsOptimization", OBJC_ASSOCIATION_RETAIN);
    [expStoreActionsOptimizationRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expStoreActionsOptimizationRow];
    ZSRow *expConservativeEnclosingSphereRow = zs_make_switch_row(@"Conservative Enclosing Sphere", zs_exp_get_bool(@"ConservativeEnclosingSphere"));
    objc_setAssociatedObject(expConservativeEnclosingSphereRow.toggle, @"zs_exp_key", @"ConservativeEnclosingSphere", OBJC_ASSOCIATION_RETAIN);
    [expConservativeEnclosingSphereRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expConservativeEnclosingSphereRow];
    ZSRow *expNumIterationsEnclosingSphereRow = zs_make_slider_row(@"Num Iterations Enclosing Sphere", 1, 256, zs_exp_get_number(@"NumIterationsEnclosingSphere"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expNumIterationsEnclosingSphereRow.slider.defaultValue = zs_exp_get_default_number(@"NumIterationsEnclosingSphere");
    expNumIterationsEnclosingSphereRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expNumIterationsEnclosingSphereRow.slider, @"zs_exp_key", @"NumIterationsEnclosingSphere", OBJC_ASSOCIATION_RETAIN);
    [expNumIterationsEnclosingSphereRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expNumIterationsEnclosingSphereRow];
    NSInteger ShaderVariantLogLevelSelIdx, ShaderVariantLogLevelDefIdx;
    ShaderVariantLogLevelSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ShaderVariantLogLevel")));
    ShaderVariantLogLevelDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expShaderVariantLogLevelRow = zs_make_mode_slider_row(@"Shader Variant Log Level", @[@"Disabled", @"URP Shaders Only", @"All Shaders"], ShaderVariantLogLevelSelIdx, ShaderVariantLogLevelDefIdx);
    objc_setAssociatedObject(expShaderVariantLogLevelRow.modeSlider, @"zs_exp_key", @"ShaderVariantLogLevel", OBJC_ASSOCIATION_RETAIN);
    [expShaderVariantLogLevelRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShaderVariantLogLevelRow];
    ZSRow *expGraphicsSRPBatchingRow = zs_make_switch_row(@"Graphics SRP Batching", zs_exp_get_bool(@"GraphicsSRPBatching"));
    objc_setAssociatedObject(expGraphicsSRPBatchingRow.toggle, @"zs_exp_key", @"GraphicsSRPBatching", OBJC_ASSOCIATION_RETAIN);
    [expGraphicsSRPBatchingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expGraphicsSRPBatchingRow];
    ZSRow *expLightsUseLinearIntensityRow = zs_make_switch_row(@"Lights Use Linear Intensity", zs_exp_get_bool(@"LightsUseLinearIntensity"));
    objc_setAssociatedObject(expLightsUseLinearIntensityRow.toggle, @"zs_exp_key", @"LightsUseLinearIntensity", OBJC_ASSOCIATION_RETAIN);
    [expLightsUseLinearIntensityRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLightsUseLinearIntensityRow];
    ZSRow *expLightsUseColorTemperatureRow = zs_make_switch_row(@"Lights Use Color Temperature", zs_exp_get_bool(@"LightsUseColorTemperature"));
    objc_setAssociatedObject(expLightsUseColorTemperatureRow.toggle, @"zs_exp_key", @"LightsUseColorTemperature", OBJC_ASSOCIATION_RETAIN);
    [expLightsUseColorTemperatureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLightsUseColorTemperatureRow];
    ZSRow *expBurstCompilationRow = zs_make_switch_row(@"Burst Compilation", zs_exp_get_bool(@"BurstCompilation"));
    objc_setAssociatedObject(expBurstCompilationRow.toggle, @"zs_exp_key", @"BurstCompilation", OBJC_ASSOCIATION_RETAIN);
    [expBurstCompilationRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expBurstCompilationRow];
    ZSRow *expBurstSafetyChecksRow = zs_make_switch_row(@"Burst Safety Checks", zs_exp_get_bool(@"BurstSafetyChecks"));
    objc_setAssociatedObject(expBurstSafetyChecksRow.toggle, @"zs_exp_key", @"BurstSafetyChecks", OBJC_ASSOCIATION_RETAIN);
    [expBurstSafetyChecksRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expBurstSafetyChecksRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Light Probes", self);
    NSInteger ShEvalModeSelIdx, ShEvalModeDefIdx;
    ShEvalModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ShEvalMode")));
    ShEvalModeDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expShEvalModeRow = zs_make_mode_slider_row(@"SH Eval Mode", @[@"Automatic", @"Per Vertex", @"Per Pixel"], ShEvalModeSelIdx, ShEvalModeDefIdx);
    objc_setAssociatedObject(expShEvalModeRow.modeSlider, @"zs_exp_key", @"ShEvalMode", OBJC_ASSOCIATION_RETAIN);
    [expShEvalModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShEvalModeRow];
    NSInteger LightProbeSystemSelIdx, LightProbeSystemDefIdx;
    LightProbeSystemSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"LightProbeSystem")));
    LightProbeSystemDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expLightProbeSystemRow = zs_make_mode_slider_row(@"Light Probe System", @[@"Legacy Light Probes", @"Adaptive Probe Volumes"], LightProbeSystemSelIdx, LightProbeSystemDefIdx);
    objc_setAssociatedObject(expLightProbeSystemRow.modeSlider, @"zs_exp_key", @"LightProbeSystem", OBJC_ASSOCIATION_RETAIN);
    [expLightProbeSystemRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLightProbeSystemRow];
    NSInteger ProbeVolumeMemoryBudgetSelIdx, ProbeVolumeMemoryBudgetDefIdx;
    ProbeVolumeMemoryBudgetSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ProbeVolumeMemoryBudget")));
    ProbeVolumeMemoryBudgetDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expProbeVolumeMemoryBudgetRow = zs_make_mode_slider_row(@"Probe Volume Memory Budget", @[@"Low", @"Medium", @"High"], ProbeVolumeMemoryBudgetSelIdx, ProbeVolumeMemoryBudgetDefIdx);
    objc_setAssociatedObject(expProbeVolumeMemoryBudgetRow.modeSlider, @"zs_exp_key", @"ProbeVolumeMemoryBudget", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeMemoryBudgetRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeMemoryBudgetRow];
    NSInteger ProbeVolumeBlendingMemoryBudgetSelIdx, ProbeVolumeBlendingMemoryBudgetDefIdx;
    ProbeVolumeBlendingMemoryBudgetSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ProbeVolumeBlendingMemoryBudget")));
    ProbeVolumeBlendingMemoryBudgetDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expProbeVolumeBlendingMemoryBudgetRow = zs_make_mode_slider_row(@"Probe Volume Blending Memory Budget", @[@"Low", @"Medium", @"High"], ProbeVolumeBlendingMemoryBudgetSelIdx, ProbeVolumeBlendingMemoryBudgetDefIdx);
    objc_setAssociatedObject(expProbeVolumeBlendingMemoryBudgetRow.modeSlider, @"zs_exp_key", @"ProbeVolumeBlendingMemoryBudget", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeBlendingMemoryBudgetRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeBlendingMemoryBudgetRow];
    ZSRow *expProbeVolumeStreamingRow = zs_make_switch_row(@"Probe Volume Streaming", zs_exp_get_bool(@"ProbeVolumeStreaming"));
    objc_setAssociatedObject(expProbeVolumeStreamingRow.toggle, @"zs_exp_key", @"ProbeVolumeStreaming", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeStreamingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeStreamingRow];
    ZSRow *expProbeVolumeGPUStreamingRow = zs_make_switch_row(@"Probe Volume G P U Streaming", zs_exp_get_bool(@"ProbeVolumeGPUStreaming"));
    objc_setAssociatedObject(expProbeVolumeGPUStreamingRow.toggle, @"zs_exp_key", @"ProbeVolumeGPUStreaming", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeGPUStreamingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeGPUStreamingRow];
    ZSRow *expProbeVolumeDiskStreamingRow = zs_make_switch_row(@"Probe Volume Disk Streaming", zs_exp_get_bool(@"ProbeVolumeDiskStreaming"));
    objc_setAssociatedObject(expProbeVolumeDiskStreamingRow.toggle, @"zs_exp_key", @"ProbeVolumeDiskStreaming", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeDiskStreamingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeDiskStreamingRow];
    ZSRow *expProbeVolumeScenariosRow = zs_make_switch_row(@"Probe Volume Scenarios", zs_exp_get_bool(@"ProbeVolumeScenarios"));
    objc_setAssociatedObject(expProbeVolumeScenariosRow.toggle, @"zs_exp_key", @"ProbeVolumeScenarios", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeScenariosRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeScenariosRow];
    ZSRow *expProbeVolumeScenarioBlendingRow = zs_make_switch_row(@"Probe Volume Scenario Blending", zs_exp_get_bool(@"ProbeVolumeScenarioBlending"));
    objc_setAssociatedObject(expProbeVolumeScenarioBlendingRow.toggle, @"zs_exp_key", @"ProbeVolumeScenarioBlending", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeScenarioBlendingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeScenarioBlendingRow];
    NSInteger ProbeVolumeSHBandsSelIdx, ProbeVolumeSHBandsDefIdx;
    ProbeVolumeSHBandsSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"ProbeVolumeSHBands")));
    ProbeVolumeSHBandsDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expProbeVolumeSHBandsRow = zs_make_mode_slider_row(@"Probe Volume SH Bands", @[@"L1 (Linear)", @"L2 (Quadratic)"], ProbeVolumeSHBandsSelIdx, ProbeVolumeSHBandsDefIdx);
    objc_setAssociatedObject(expProbeVolumeSHBandsRow.modeSlider, @"zs_exp_key", @"ProbeVolumeSHBands", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeSHBandsRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeSHBandsRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Shadows", self);
    NSInteger AdditionalShadowTierLowSelIdx, AdditionalShadowTierLowDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"AdditionalShadowTierLow"); AdditionalShadowTierLowSelIdx = zs_exp_idx_AdditionalShadowTierLow(v); }
    AdditionalShadowTierLowDefIdx = zs_exp_idx_AdditionalShadowTierLow(256);
    ZSRow *expAdditionalShadowTierLowRow = zs_make_mode_slider_row(@"Additional Shadow Tier Low", @[@"256", @"512", @"1024", @"2048"], AdditionalShadowTierLowSelIdx, AdditionalShadowTierLowDefIdx);
    objc_setAssociatedObject(expAdditionalShadowTierLowRow.modeSlider, @"zs_exp_key", @"AdditionalShadowTierLow", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalShadowTierLowRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalShadowTierLowRow];
    NSInteger AdditionalShadowTierMediumSelIdx, AdditionalShadowTierMediumDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"AdditionalShadowTierMedium"); AdditionalShadowTierMediumSelIdx = zs_exp_idx_AdditionalShadowTierMedium(v); }
    AdditionalShadowTierMediumDefIdx = zs_exp_idx_AdditionalShadowTierMedium(512);
    ZSRow *expAdditionalShadowTierMediumRow = zs_make_mode_slider_row(@"Additional Shadow Tier Medium", @[@"256", @"512", @"1024", @"2048"], AdditionalShadowTierMediumSelIdx, AdditionalShadowTierMediumDefIdx);
    objc_setAssociatedObject(expAdditionalShadowTierMediumRow.modeSlider, @"zs_exp_key", @"AdditionalShadowTierMedium", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalShadowTierMediumRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalShadowTierMediumRow];
    NSInteger AdditionalShadowTierHighSelIdx, AdditionalShadowTierHighDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"AdditionalShadowTierHigh"); AdditionalShadowTierHighSelIdx = zs_exp_idx_AdditionalShadowTierHigh(v); }
    AdditionalShadowTierHighDefIdx = zs_exp_idx_AdditionalShadowTierHigh(1024);
    ZSRow *expAdditionalShadowTierHighRow = zs_make_mode_slider_row(@"Additional Shadow Tier High", @[@"256", @"512", @"1024", @"2048"], AdditionalShadowTierHighSelIdx, AdditionalShadowTierHighDefIdx);
    objc_setAssociatedObject(expAdditionalShadowTierHighRow.modeSlider, @"zs_exp_key", @"AdditionalShadowTierHigh", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalShadowTierHighRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalShadowTierHighRow];
    NSInteger SoftShadowQualitySelIdx, SoftShadowQualityDefIdx;
    SoftShadowQualitySelIdx = MAX(0, MIN(3, (NSInteger)zs_exp_get_number(@"SoftShadowQuality")));
    SoftShadowQualityDefIdx = MAX(0, MIN(3, (NSInteger)0));
    ZSRow *expSoftShadowQualityRow = zs_make_mode_slider_row(@"Soft Shadow Quality", @[@"Use Pipeline Settings", @"Low", @"Medium", @"High"], SoftShadowQualitySelIdx, SoftShadowQualityDefIdx);
    objc_setAssociatedObject(expSoftShadowQualityRow.modeSlider, @"zs_exp_key", @"SoftShadowQuality", OBJC_ASSOCIATION_RETAIN);
    [expSoftShadowQualityRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expSoftShadowQualityRow];
    ZSRow *expShadowDistanceRow = zs_make_slider_row(@"Shadow Distance", 0, 500, zs_exp_get_number(@"ShadowDistance"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expShadowDistanceRow.slider.defaultValue = zs_exp_get_default_number(@"ShadowDistance");
    expShadowDistanceRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expShadowDistanceRow.slider, @"zs_exp_key", @"ShadowDistance", OBJC_ASSOCIATION_RETAIN);
    [expShadowDistanceRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowDistanceRow];
    NSInteger ShadowCascadesSelIdx, ShadowCascadesDefIdx;
    ShadowCascadesSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ShadowCascades")));
    ShadowCascadesDefIdx = MAX(0, MIN(2, (NSInteger)2));
    ZSRow *expShadowCascadesRow = zs_make_mode_slider_row(@"Shadow Cascades", @[@"No Cascades", @"Two Cascades", @"Four Cascades"], ShadowCascadesSelIdx, ShadowCascadesDefIdx);
    objc_setAssociatedObject(expShadowCascadesRow.modeSlider, @"zs_exp_key", @"ShadowCascades", OBJC_ASSOCIATION_RETAIN);
    [expShadowCascadesRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowCascadesRow];
    ZSRow *expCascadeBorderRow = zs_make_slider_row(@"Cascade Border", 0.0, 1.0, zs_exp_get_number(@"CascadeBorder"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expCascadeBorderRow.slider.defaultValue = zs_exp_get_default_number(@"CascadeBorder");
    expCascadeBorderRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascadeBorderRow.slider, @"zs_exp_key", @"CascadeBorder", OBJC_ASSOCIATION_RETAIN);
    [expCascadeBorderRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascadeBorderRow];
    ZSRow *expShadowDepthBiasRow = zs_make_slider_row(@"Shadow Depth Bias", 0.0, 5.0, zs_exp_get_number(@"ShadowDepthBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expShadowDepthBiasRow.slider.defaultValue = zs_exp_get_default_number(@"ShadowDepthBias");
    expShadowDepthBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expShadowDepthBiasRow.slider, @"zs_exp_key", @"ShadowDepthBias", OBJC_ASSOCIATION_RETAIN);
    [expShadowDepthBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowDepthBiasRow];
    ZSRow *expShadowNormalBiasRow = zs_make_slider_row(@"Shadow Normal Bias", 0.0, 5.0, zs_exp_get_number(@"ShadowNormalBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expShadowNormalBiasRow.slider.defaultValue = zs_exp_get_default_number(@"ShadowNormalBias");
    expShadowNormalBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expShadowNormalBiasRow.slider, @"zs_exp_key", @"ShadowNormalBias", OBJC_ASSOCIATION_RETAIN);
    [expShadowNormalBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowNormalBiasRow];
    ZSRow *expSoftShadowsRow = zs_make_switch_row(@"Soft Shadows", zs_exp_get_bool(@"SoftShadows"));
    objc_setAssociatedObject(expSoftShadowsRow.toggle, @"zs_exp_key", @"SoftShadows", OBJC_ASSOCIATION_RETAIN);
    [expSoftShadowsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expSoftShadowsRow];
    NSInteger ShadowCascadeOptionSelIdx, ShadowCascadeOptionDefIdx;
    ShadowCascadeOptionSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ShadowCascadeOption")));
    ShadowCascadeOptionDefIdx = MAX(0, MIN(2, (NSInteger)2));
    ZSRow *expShadowCascadeOptionRow = zs_make_mode_slider_row(@"Shadow Cascade Option", @[@"No Cascades", @"Two Cascades", @"Four Cascades"], ShadowCascadeOptionSelIdx, ShadowCascadeOptionDefIdx);
    objc_setAssociatedObject(expShadowCascadeOptionRow.modeSlider, @"zs_exp_key", @"ShadowCascadeOption", OBJC_ASSOCIATION_RETAIN);
    [expShadowCascadeOptionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowCascadeOptionRow];
    ZSRow *expCascade2SplitRow = zs_make_slider_row(@"Cascade2 Split", 0.0, 1.0, zs_exp_get_number(@"Cascade2Split"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade2SplitRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade2Split");
    expCascade2SplitRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade2SplitRow.slider, @"zs_exp_key", @"Cascade2Split", OBJC_ASSOCIATION_RETAIN);
    [expCascade2SplitRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade2SplitRow];
    ZSRow *expCascade3SplitXRow = zs_make_slider_row(@"Cascade3 Split X", 0.0, 1.0, zs_exp_get_number(@"Cascade3SplitX"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade3SplitXRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade3SplitX");
    expCascade3SplitXRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade3SplitXRow.slider, @"zs_exp_key", @"Cascade3SplitX", OBJC_ASSOCIATION_RETAIN);
    [expCascade3SplitXRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade3SplitXRow];
    ZSRow *expCascade3SplitYRow = zs_make_slider_row(@"Cascade3 Split Y", 0.0, 1.0, zs_exp_get_number(@"Cascade3SplitY"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade3SplitYRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade3SplitY");
    expCascade3SplitYRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade3SplitYRow.slider, @"zs_exp_key", @"Cascade3SplitY", OBJC_ASSOCIATION_RETAIN);
    [expCascade3SplitYRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade3SplitYRow];
    ZSRow *expCascade4SplitXRow = zs_make_slider_row(@"Cascade4 Split X", 0.0, 1.0, zs_exp_get_number(@"Cascade4SplitX"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade4SplitXRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade4SplitX");
    expCascade4SplitXRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade4SplitXRow.slider, @"zs_exp_key", @"Cascade4SplitX", OBJC_ASSOCIATION_RETAIN);
    [expCascade4SplitXRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade4SplitXRow];
    ZSRow *expCascade4SplitYRow = zs_make_slider_row(@"Cascade4 Split Y", 0.0, 1.0, zs_exp_get_number(@"Cascade4SplitY"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade4SplitYRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade4SplitY");
    expCascade4SplitYRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade4SplitYRow.slider, @"zs_exp_key", @"Cascade4SplitY", OBJC_ASSOCIATION_RETAIN);
    [expCascade4SplitYRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade4SplitYRow];
    ZSRow *expCascade4SplitZRow = zs_make_slider_row(@"Cascade4 Split Z", 0.0, 1.0, zs_exp_get_number(@"Cascade4SplitZ"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade4SplitZRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade4SplitZ");
    expCascade4SplitZRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade4SplitZRow.slider, @"zs_exp_key", @"Cascade4SplitZ", OBJC_ASSOCIATION_RETAIN);
    [expCascade4SplitZRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade4SplitZRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Adaptive Performance", self);
    ZSRow *expAdaptivePerformanceRow = zs_make_switch_row(@"Adaptive Performance", zs_exp_get_bool(@"AdaptivePerformance"));
    self.expAdaptivePerformanceToggle = expAdaptivePerformanceRow.toggle;
    objc_setAssociatedObject(expAdaptivePerformanceRow.toggle, @"zs_exp_key", @"AdaptivePerformance", OBJC_ASSOCIATION_RETAIN);
    [expAdaptivePerformanceRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdaptivePerformanceRow];
    ZSRow *expAPMaxShadowDistanceMultiplierRow = zs_make_slider_row(@"AP Max Shadow Distance Mult.", 0.0, 2.0, zs_exp_get_number(@"APMaxShadowDistanceMultiplier"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expAPMaxShadowDistanceMultiplierRow.slider.defaultValue = zs_exp_get_default_number(@"APMaxShadowDistanceMultiplier");
    expAPMaxShadowDistanceMultiplierRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAPMaxShadowDistanceMultiplierRow.slider, @"zs_exp_key", @"APMaxShadowDistanceMultiplier", OBJC_ASSOCIATION_RETAIN);
    [expAPMaxShadowDistanceMultiplierRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPMaxShadowDistanceMultiplierRow];
    ZSRow *expAPShadowmapResolutionMultiplierRow = zs_make_slider_row(@"AP Shadowmap Resolution Mult.", 0.0, 2.0, zs_exp_get_number(@"APShadowmapResolutionMultiplier"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expAPShadowmapResolutionMultiplierRow.slider.defaultValue = zs_exp_get_default_number(@"APShadowmapResolutionMultiplier");
    expAPShadowmapResolutionMultiplierRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAPShadowmapResolutionMultiplierRow.slider, @"zs_exp_key", @"APShadowmapResolutionMultiplier", OBJC_ASSOCIATION_RETAIN);
    [expAPShadowmapResolutionMultiplierRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPShadowmapResolutionMultiplierRow];
    ZSRow *expAPDecalsDrawDistanceRow = zs_make_slider_row(@"AP Decals Draw Distance", 0, 1000, zs_exp_get_number(@"APDecalsDrawDistance"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expAPDecalsDrawDistanceRow.slider.defaultValue = zs_exp_get_default_number(@"APDecalsDrawDistance");
    expAPDecalsDrawDistanceRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAPDecalsDrawDistanceRow.slider, @"zs_exp_key", @"APDecalsDrawDistance", OBJC_ASSOCIATION_RETAIN);
    [expAPDecalsDrawDistanceRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPDecalsDrawDistanceRow];
    NSInteger APShadowCascadesBiasSelIdx, APShadowCascadesBiasDefIdx;
    APShadowCascadesBiasSelIdx = MAX(0, MIN(4, (NSInteger)zs_exp_get_number(@"APShadowCascadesBias")));
    APShadowCascadesBiasDefIdx = MAX(0, MIN(4, (NSInteger)0));
    ZSRow *expAPShadowCascadesBiasRow = zs_make_mode_slider_row(@"AP Shadow Cascades Bias", @[@"0", @"1", @"2", @"3", @"4"], APShadowCascadesBiasSelIdx, APShadowCascadesBiasDefIdx);
    objc_setAssociatedObject(expAPShadowCascadesBiasRow.modeSlider, @"zs_exp_key", @"APShadowCascadesBias", OBJC_ASSOCIATION_RETAIN);
    [expAPShadowCascadesBiasRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPShadowCascadesBiasRow];
    NSInteger APShadowQualityBiasSelIdx, APShadowQualityBiasDefIdx;
    APShadowQualityBiasSelIdx = MAX(0, MIN(4, (NSInteger)zs_exp_get_number(@"APShadowQualityBias")));
    APShadowQualityBiasDefIdx = MAX(0, MIN(4, (NSInteger)0));
    ZSRow *expAPShadowQualityBiasRow = zs_make_mode_slider_row(@"AP Shadow Quality Bias", @[@"0", @"1", @"2", @"3", @"4"], APShadowQualityBiasSelIdx, APShadowQualityBiasDefIdx);
    objc_setAssociatedObject(expAPShadowQualityBiasRow.modeSlider, @"zs_exp_key", @"APShadowQualityBias", OBJC_ASSOCIATION_RETAIN);
    [expAPShadowQualityBiasRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPShadowQualityBiasRow];
    ZSRow *expAPLutBiasRow = zs_make_slider_row(@"AP LUT Bias", 0.0, 2.0, zs_exp_get_number(@"APLutBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expAPLutBiasRow.slider.defaultValue = zs_exp_get_default_number(@"APLutBias");
    expAPLutBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAPLutBiasRow.slider, @"zs_exp_key", @"APLutBias", OBJC_ASSOCIATION_RETAIN);
    [expAPLutBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPLutBiasRow];
    NSInteger APAntiAliasingQualityBiasSelIdx, APAntiAliasingQualityBiasDefIdx;
    APAntiAliasingQualityBiasSelIdx = MAX(0, MIN(4, (NSInteger)zs_exp_get_number(@"APAntiAliasingQualityBias")));
    APAntiAliasingQualityBiasDefIdx = MAX(0, MIN(4, (NSInteger)0));
    ZSRow *expAPAntiAliasingQualityBiasRow = zs_make_mode_slider_row(@"AP Anti-Aliasing Quality Bias", @[@"0", @"1", @"2", @"3", @"4"], APAntiAliasingQualityBiasSelIdx, APAntiAliasingQualityBiasDefIdx);
    objc_setAssociatedObject(expAPAntiAliasingQualityBiasRow.modeSlider, @"zs_exp_key", @"APAntiAliasingQualityBias", OBJC_ASSOCIATION_RETAIN);
    [expAPAntiAliasingQualityBiasRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPAntiAliasingQualityBiasRow];
    ZSRow *expAPSkipDynamicBatchingRow = zs_make_switch_row(@"AP Skip Dynamic Batching", zs_exp_get_bool(@"APSkipDynamicBatching"));
    objc_setAssociatedObject(expAPSkipDynamicBatchingRow.toggle, @"zs_exp_key", @"APSkipDynamicBatching", OBJC_ASSOCIATION_RETAIN);
    [expAPSkipDynamicBatchingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPSkipDynamicBatchingRow];
    ZSRow *expAPSkipFrontToBackSortingRow = zs_make_switch_row(@"AP Skip Front-To-Back Sorting", zs_exp_get_bool(@"APSkipFrontToBackSorting"));
    objc_setAssociatedObject(expAPSkipFrontToBackSortingRow.toggle, @"zs_exp_key", @"APSkipFrontToBackSorting", OBJC_ASSOCIATION_RETAIN);
    [expAPSkipFrontToBackSortingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPSkipFrontToBackSortingRow];
    ZSRow *expAPSkipTransparentObjectsRow = zs_make_switch_row(@"AP Skip Transparent Objects", zs_exp_get_bool(@"APSkipTransparentObjects"));
    objc_setAssociatedObject(expAPSkipTransparentObjectsRow.toggle, @"zs_exp_key", @"APSkipTransparentObjects", OBJC_ASSOCIATION_RETAIN);
    [expAPSkipTransparentObjectsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPSkipTransparentObjectsRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Particles & Animator", self);
    ZSRow *expParticleGPUInstancingRow = zs_make_switch_row(@"Particle GPU Instancing", zs_exp_get_bool(@"ParticleGPUInstancing"));
    objc_setAssociatedObject(expParticleGPUInstancingRow.toggle, @"zs_exp_key", @"ParticleGPUInstancing", OBJC_ASSOCIATION_RETAIN);
    [expParticleGPUInstancingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleGPUInstancingRow];
    NSInteger ParticleMeshDistributionSelIdx, ParticleMeshDistributionDefIdx;
    ParticleMeshDistributionSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"ParticleMeshDistribution")));
    ParticleMeshDistributionDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expParticleMeshDistributionRow = zs_make_mode_slider_row(@"Particle Mesh Distribution", @[@"Uniform", @"Weighted By Shape"], ParticleMeshDistributionSelIdx, ParticleMeshDistributionDefIdx);
    objc_setAssociatedObject(expParticleMeshDistributionRow.modeSlider, @"zs_exp_key", @"ParticleMeshDistribution", OBJC_ASSOCIATION_RETAIN);
    [expParticleMeshDistributionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleMeshDistributionRow];
    ZSRow *expParticleLengthScaleRow = zs_make_slider_row(@"Particle Length Scale", 0.0, 20.0, zs_exp_get_number(@"ParticleLengthScale"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleLengthScaleRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleLengthScale");
    expParticleLengthScaleRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleLengthScaleRow.slider, @"zs_exp_key", @"ParticleLengthScale", OBJC_ASSOCIATION_RETAIN);
    [expParticleLengthScaleRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleLengthScaleRow];
    ZSRow *expParticleVelocityScaleRow = zs_make_slider_row(@"Particle Velocity Scale", 0.0, 5.0, zs_exp_get_number(@"ParticleVelocityScale"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleVelocityScaleRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleVelocityScale");
    expParticleVelocityScaleRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleVelocityScaleRow.slider, @"zs_exp_key", @"ParticleVelocityScale", OBJC_ASSOCIATION_RETAIN);
    [expParticleVelocityScaleRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleVelocityScaleRow];
    ZSRow *expParticleCameraVelocityScaleRow = zs_make_slider_row(@"Particle Camera Velocity Scale", 0.0, 5.0, zs_exp_get_number(@"ParticleCameraVelocityScale"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleCameraVelocityScaleRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleCameraVelocityScale");
    expParticleCameraVelocityScaleRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleCameraVelocityScaleRow.slider, @"zs_exp_key", @"ParticleCameraVelocityScale", OBJC_ASSOCIATION_RETAIN);
    [expParticleCameraVelocityScaleRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleCameraVelocityScaleRow];
    ZSRow *expParticleNormalDirectionRow = zs_make_slider_row(@"Particle Normal Direction", 0.0, 3.0, zs_exp_get_number(@"ParticleNormalDirection"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleNormalDirectionRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleNormalDirection");
    expParticleNormalDirectionRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleNormalDirectionRow.slider, @"zs_exp_key", @"ParticleNormalDirection", OBJC_ASSOCIATION_RETAIN);
    [expParticleNormalDirectionRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleNormalDirectionRow];
    ZSRow *expParticleShadowBiasRow = zs_make_slider_row(@"Particle Shadow Bias", 0.0, 2.0, zs_exp_get_number(@"ParticleShadowBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleShadowBiasRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleShadowBias");
    expParticleShadowBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleShadowBiasRow.slider, @"zs_exp_key", @"ParticleShadowBias", OBJC_ASSOCIATION_RETAIN);
    [expParticleShadowBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleShadowBiasRow];
    ZSRow *expParticleSortingFudgeRow = zs_make_slider_row(@"Particle Sorting Fudge", -100.0, 100.0, zs_exp_get_number(@"ParticleSortingFudge"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.1f", v]; });
    expParticleSortingFudgeRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleSortingFudge");
    expParticleSortingFudgeRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleSortingFudgeRow.slider, @"zs_exp_key", @"ParticleSortingFudge", OBJC_ASSOCIATION_RETAIN);
    [expParticleSortingFudgeRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleSortingFudgeRow];
    ZSRow *expParticleAllowRollRow = zs_make_switch_row(@"Particle Allow Roll", zs_exp_get_bool(@"ParticleAllowRoll"));
    objc_setAssociatedObject(expParticleAllowRollRow.toggle, @"zs_exp_key", @"ParticleAllowRoll", OBJC_ASSOCIATION_RETAIN);
    [expParticleAllowRollRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleAllowRollRow];
    ZSRow *expParticleRotateWithStretchDirectionRow = zs_make_switch_row(@"Particle Rotate With Stretch Direction", zs_exp_get_bool(@"ParticleRotateWithStretchDirection"));
    objc_setAssociatedObject(expParticleRotateWithStretchDirectionRow.toggle, @"zs_exp_key", @"ParticleRotateWithStretchDirection", OBJC_ASSOCIATION_RETAIN);
    [expParticleRotateWithStretchDirectionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleRotateWithStretchDirectionRow];
    ZSRow *expParticleApplyActiveColorSpaceRow = zs_make_switch_row(@"Particle Apply Active Color Space", zs_exp_get_bool(@"ParticleApplyActiveColorSpace"));
    objc_setAssociatedObject(expParticleApplyActiveColorSpaceRow.toggle, @"zs_exp_key", @"ParticleApplyActiveColorSpace", OBJC_ASSOCIATION_RETAIN);
    [expParticleApplyActiveColorSpaceRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleApplyActiveColorSpaceRow];
    NSInteger AnimatorCullingModeSelIdx, AnimatorCullingModeDefIdx;
    AnimatorCullingModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"AnimatorCullingMode")));
    AnimatorCullingModeDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expAnimatorCullingModeRow = zs_make_mode_slider_row(@"Animator Culling Mode", @[@"Always Animate", @"Cull Update Transforms", @"Cull Completely"], AnimatorCullingModeSelIdx, AnimatorCullingModeDefIdx);
    objc_setAssociatedObject(expAnimatorCullingModeRow.modeSlider, @"zs_exp_key", @"AnimatorCullingMode", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorCullingModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorCullingModeRow];
    NSInteger AnimatorUpdateModeSelIdx, AnimatorUpdateModeDefIdx;
    AnimatorUpdateModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"AnimatorUpdateMode")));
    AnimatorUpdateModeDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expAnimatorUpdateModeRow = zs_make_mode_slider_row(@"Animator Update Mode", @[@"Normal", @"Animate Physics", @"Unscaled Time"], AnimatorUpdateModeSelIdx, AnimatorUpdateModeDefIdx);
    objc_setAssociatedObject(expAnimatorUpdateModeRow.modeSlider, @"zs_exp_key", @"AnimatorUpdateMode", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorUpdateModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorUpdateModeRow];
    ZSRow *expAnimatorApplyRootMotionRow = zs_make_switch_row(@"Animator Apply Root Motion", zs_exp_get_bool(@"AnimatorApplyRootMotion"));
    objc_setAssociatedObject(expAnimatorApplyRootMotionRow.toggle, @"zs_exp_key", @"AnimatorApplyRootMotion", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorApplyRootMotionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorApplyRootMotionRow];
    ZSRow *expAnimatorLinearVelocityBlendingRow = zs_make_switch_row(@"Animator Linear Velocity Blending", zs_exp_get_bool(@"AnimatorLinearVelocityBlending"));
    objc_setAssociatedObject(expAnimatorLinearVelocityBlendingRow.toggle, @"zs_exp_key", @"AnimatorLinearVelocityBlending", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorLinearVelocityBlendingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorLinearVelocityBlendingRow];
    ZSRow *expAnimatorAnimatePhysicsRow = zs_make_switch_row(@"Animator Animate Physics", zs_exp_get_bool(@"AnimatorAnimatePhysics"));
    objc_setAssociatedObject(expAnimatorAnimatePhysicsRow.toggle, @"zs_exp_key", @"AnimatorAnimatePhysics", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorAnimatePhysicsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorAnimatePhysicsRow];
    ZSRow *expAnimatorConstantClipSamplingOptimizationRow = zs_make_switch_row(@"Animator Constant Clip Sampling Optimization", zs_exp_get_bool(@"AnimatorConstantClipSamplingOptimization"));
    objc_setAssociatedObject(expAnimatorConstantClipSamplingOptimizationRow.toggle, @"zs_exp_key", @"AnimatorConstantClipSamplingOptimization", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorConstantClipSamplingOptimizationRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorConstantClipSamplingOptimizationRow];
    ZSRow *expAnimatorStabilizeFeetRow = zs_make_switch_row(@"Animator Stabilize Feet", zs_exp_get_bool(@"AnimatorStabilizeFeet"));
    objc_setAssociatedObject(expAnimatorStabilizeFeetRow.toggle, @"zs_exp_key", @"AnimatorStabilizeFeet", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorStabilizeFeetRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorStabilizeFeetRow];
    ZSRow *expAnimatorSpeedRow = zs_make_slider_row(@"Animator Speed", 0.0, 3.0, zs_exp_get_number(@"AnimatorSpeed"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expAnimatorSpeedRow.slider.defaultValue = zs_exp_get_default_number(@"AnimatorSpeed");
    expAnimatorSpeedRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAnimatorSpeedRow.slider, @"zs_exp_key", @"AnimatorSpeed", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorSpeedRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorSpeedRow];
    ZSRow *expAnimatorLogWarningsRow = zs_make_switch_row(@"Animator Log Warnings", zs_exp_get_bool(@"AnimatorLogWarnings"));
    objc_setAssociatedObject(expAnimatorLogWarningsRow.toggle, @"zs_exp_key", @"AnimatorLogWarnings", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorLogWarningsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorLogWarningsRow];
    ZSRow *expAnimatorFireEventsRow = zs_make_switch_row(@"Animator Fire Events", zs_exp_get_bool(@"AnimatorFireEvents"));
    objc_setAssociatedObject(expAnimatorFireEventsRow.toggle, @"zs_exp_key", @"AnimatorFireEvents", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorFireEventsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorFireEventsRow];
    ZSRow *expAnimatorWriteDefaultValuesOnDisableRow = zs_make_switch_row(@"Animator Write Default Values On Disable", zs_exp_get_bool(@"AnimatorWriteDefaultValuesOnDisable"));
    objc_setAssociatedObject(expAnimatorWriteDefaultValuesOnDisableRow.toggle, @"zs_exp_key", @"AnimatorWriteDefaultValuesOnDisable", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorWriteDefaultValuesOnDisableRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorWriteDefaultValuesOnDisableRow];
    ZSRow *expAnimatorKeepStateOnDisableRow = zs_make_switch_row(@"Animator Keep State On Disable", zs_exp_get_bool(@"AnimatorKeepStateOnDisable"));
    objc_setAssociatedObject(expAnimatorKeepStateOnDisableRow.toggle, @"zs_exp_key", @"AnimatorKeepStateOnDisable", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorKeepStateOnDisableRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorKeepStateOnDisableRow];
    ZSRow *expAnimatorKeepControllerStateOnDisableRow = zs_make_switch_row(@"Animator Keep Controller State On Disable", zs_exp_get_bool(@"AnimatorKeepControllerStateOnDisable"));
    objc_setAssociatedObject(expAnimatorKeepControllerStateOnDisableRow.toggle, @"zs_exp_key", @"AnimatorKeepControllerStateOnDisable", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorKeepControllerStateOnDisableRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorKeepControllerStateOnDisableRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Physics", self);
    NSInteger RigidbodySolverIterationsSelIdx, RigidbodySolverIterationsDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"RigidbodySolverIterations"); RigidbodySolverIterationsSelIdx = zs_exp_idx_RigidbodySolverIterations(v); }
    RigidbodySolverIterationsDefIdx = zs_exp_idx_RigidbodySolverIterations(6);
    ZSRow *expRigidbodySolverIterationsRow = zs_make_mode_slider_row(@"Rigidbody Solver Iterations", @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"10", @"11", @"12"], RigidbodySolverIterationsSelIdx, RigidbodySolverIterationsDefIdx);
    objc_setAssociatedObject(expRigidbodySolverIterationsRow.modeSlider, @"zs_exp_key", @"RigidbodySolverIterations", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodySolverIterationsRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodySolverIterationsRow];
    NSInteger RigidbodySolverVelocityIterationsSelIdx, RigidbodySolverVelocityIterationsDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"RigidbodySolverVelocityIterations"); RigidbodySolverVelocityIterationsSelIdx = zs_exp_idx_RigidbodySolverVelocityIterations(v); }
    RigidbodySolverVelocityIterationsDefIdx = zs_exp_idx_RigidbodySolverVelocityIterations(1);
    ZSRow *expRigidbodySolverVelocityIterationsRow = zs_make_mode_slider_row(@"Rigidbody Solver Velocity Iterations", @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8"], RigidbodySolverVelocityIterationsSelIdx, RigidbodySolverVelocityIterationsDefIdx);
    objc_setAssociatedObject(expRigidbodySolverVelocityIterationsRow.modeSlider, @"zs_exp_key", @"RigidbodySolverVelocityIterations", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodySolverVelocityIterationsRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodySolverVelocityIterationsRow];
    ZSRow *expRigidbodySleepThresholdRow = zs_make_slider_row(@"Rigidbody Sleep Threshold", 0.0, 1.0, zs_exp_get_number(@"RigidbodySleepThreshold"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expRigidbodySleepThresholdRow.slider.defaultValue = zs_exp_get_default_number(@"RigidbodySleepThreshold");
    expRigidbodySleepThresholdRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbodySleepThresholdRow.slider, @"zs_exp_key", @"RigidbodySleepThreshold", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodySleepThresholdRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodySleepThresholdRow];
    ZSRow *expRigidbodyMaxAngularVelocityRow = zs_make_slider_row(@"Rigidbody Max Angular Velocity", 0.0, 50.0, zs_exp_get_number(@"RigidbodyMaxAngularVelocity"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.1f", v]; });
    expRigidbodyMaxAngularVelocityRow.slider.defaultValue = zs_exp_get_default_number(@"RigidbodyMaxAngularVelocity");
    expRigidbodyMaxAngularVelocityRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbodyMaxAngularVelocityRow.slider, @"zs_exp_key", @"RigidbodyMaxAngularVelocity", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodyMaxAngularVelocityRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodyMaxAngularVelocityRow];
    ZSRow *expRigidbodyMaxLinearVelocityRow = zs_make_slider_row(@"Rigidbody Max Linear Velocity", 0.0, 100.0, zs_exp_get_number(@"RigidbodyMaxLinearVelocity"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.1f", v]; });
    expRigidbodyMaxLinearVelocityRow.slider.defaultValue = zs_exp_get_default_number(@"RigidbodyMaxLinearVelocity");
    expRigidbodyMaxLinearVelocityRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbodyMaxLinearVelocityRow.slider, @"zs_exp_key", @"RigidbodyMaxLinearVelocity", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodyMaxLinearVelocityRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodyMaxLinearVelocityRow];
    NSInteger RigidbodyInterpolationSelIdx, RigidbodyInterpolationDefIdx;
    RigidbodyInterpolationSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"RigidbodyInterpolation")));
    RigidbodyInterpolationDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expRigidbodyInterpolationRow = zs_make_mode_slider_row(@"Rigidbody Interpolation", @[@"None", @"Interpolate", @"Extrapolate"], RigidbodyInterpolationSelIdx, RigidbodyInterpolationDefIdx);
    objc_setAssociatedObject(expRigidbodyInterpolationRow.modeSlider, @"zs_exp_key", @"RigidbodyInterpolation", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodyInterpolationRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodyInterpolationRow];
    ZSRow *expRigidbodyDetectCollisionsRow = zs_make_switch_row(@"Rigidbody Detect Collisions", zs_exp_get_bool(@"RigidbodyDetectCollisions"));
    objc_setAssociatedObject(expRigidbodyDetectCollisionsRow.toggle, @"zs_exp_key", @"RigidbodyDetectCollisions", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodyDetectCollisionsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodyDetectCollisionsRow];
    ZSRow *expRigidbody2DLinearDampingRow = zs_make_slider_row(@"Rigidbody2D Linear Damping", 0.0, 5.0, zs_exp_get_number(@"Rigidbody2DLinearDamping"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expRigidbody2DLinearDampingRow.slider.defaultValue = zs_exp_get_default_number(@"Rigidbody2DLinearDamping");
    expRigidbody2DLinearDampingRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbody2DLinearDampingRow.slider, @"zs_exp_key", @"Rigidbody2DLinearDamping", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DLinearDampingRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DLinearDampingRow];
    ZSRow *expRigidbody2DAngularDampingRow = zs_make_slider_row(@"Rigidbody2D Angular Damping", 0.0, 5.0, zs_exp_get_number(@"Rigidbody2DAngularDamping"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expRigidbody2DAngularDampingRow.slider.defaultValue = zs_exp_get_default_number(@"Rigidbody2DAngularDamping");
    expRigidbody2DAngularDampingRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbody2DAngularDampingRow.slider, @"zs_exp_key", @"Rigidbody2DAngularDamping", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DAngularDampingRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DAngularDampingRow];
    ZSRow *expRigidbody2DGravityScaleRow = zs_make_slider_row(@"Rigidbody2D Gravity Scale", -5.0, 5.0, zs_exp_get_number(@"Rigidbody2DGravityScale"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expRigidbody2DGravityScaleRow.slider.defaultValue = zs_exp_get_default_number(@"Rigidbody2DGravityScale");
    expRigidbody2DGravityScaleRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbody2DGravityScaleRow.slider, @"zs_exp_key", @"Rigidbody2DGravityScale", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DGravityScaleRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DGravityScaleRow];
    NSInteger Rigidbody2DInterpolationSelIdx, Rigidbody2DInterpolationDefIdx;
    Rigidbody2DInterpolationSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"Rigidbody2DInterpolation")));
    Rigidbody2DInterpolationDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expRigidbody2DInterpolationRow = zs_make_mode_slider_row(@"Rigidbody2D Interpolation", @[@"None", @"Interpolate", @"Extrapolate"], Rigidbody2DInterpolationSelIdx, Rigidbody2DInterpolationDefIdx);
    objc_setAssociatedObject(expRigidbody2DInterpolationRow.modeSlider, @"zs_exp_key", @"Rigidbody2DInterpolation", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DInterpolationRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DInterpolationRow];
    NSInteger Rigidbody2DSleepModeSelIdx, Rigidbody2DSleepModeDefIdx;
    Rigidbody2DSleepModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"Rigidbody2DSleepMode")));
    Rigidbody2DSleepModeDefIdx = MAX(0, MIN(2, (NSInteger)1));
    ZSRow *expRigidbody2DSleepModeRow = zs_make_mode_slider_row(@"Rigidbody2D Sleep Mode", @[@"Never Sleep", @"Start Awake", @"Start Asleep"], Rigidbody2DSleepModeSelIdx, Rigidbody2DSleepModeDefIdx);
    objc_setAssociatedObject(expRigidbody2DSleepModeRow.modeSlider, @"zs_exp_key", @"Rigidbody2DSleepMode", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DSleepModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DSleepModeRow];
    NSInteger Rigidbody2DCollisionDetectionModeSelIdx, Rigidbody2DCollisionDetectionModeDefIdx;
    Rigidbody2DCollisionDetectionModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"Rigidbody2DCollisionDetectionMode")));
    Rigidbody2DCollisionDetectionModeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expRigidbody2DCollisionDetectionModeRow = zs_make_mode_slider_row(@"Rigidbody2D Collision Detection Mode", @[@"Discrete", @"Continuous"], Rigidbody2DCollisionDetectionModeSelIdx, Rigidbody2DCollisionDetectionModeDefIdx);
    objc_setAssociatedObject(expRigidbody2DCollisionDetectionModeRow.modeSlider, @"zs_exp_key", @"Rigidbody2DCollisionDetectionMode", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DCollisionDetectionModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DCollisionDetectionModeRow];
    ZSRow *expAdaptivePhysicsRow = zs_make_switch_row(@"Adaptive Physics", zs_exp_get_bool(@"AdaptivePhysics"));
    objc_setAssociatedObject(expAdaptivePhysicsRow.toggle, @"zs_exp_key", @"AdaptivePhysics", OBJC_ASSOCIATION_RETAIN);
    [expAdaptivePhysicsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdaptivePhysicsRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    [self zs_applyExperimentalAvailabilityTint];

    zs_add_section_header(self.experimentalSectionContainer, @"Browse All Settings", self);

    self.browseCategoryButton = zs_make_grouped_action_button(self.browseSelectedCategory ?: @"Category: --", zs_accent_green_color());
    [self.browseCategoryButton addTarget:self action:@selector(browseCategoryButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    self.browseClassButton = zs_make_grouped_action_button(self.browseSelectedEntry[@"name"] ?: @"Setting: --", zs_accent_green_color());
    [self.browseClassButton addTarget:self action:@selector(browseClassButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    UIView *browseCard = zs_make_grouped_action_card(@[self.browseCategoryButton, self.browseClassButton]);
    [self.experimentalSectionContainer addArrangedSubview:browseCard];

    self.browseFieldsContainer = [[UIStackView alloc] init];
    self.browseFieldsContainer.axis = UILayoutConstraintAxisVertical;
    self.browseFieldsContainer.spacing = kRowSpacing;
    [self.experimentalSectionContainer addArrangedSubview:self.browseFieldsContainer];
    [self zs_rebuildBrowseFields];
    }];

    [self.pendingSectionBuilders addObject:^{
    UIView *socialLinksSeparator = zs_make_section_separator();
    [self.stack addArrangedSubview:socialLinksSeparator];
    [self.stack setCustomSpacing:kSectionSpacing afterView:self.experimentalSectionContainer];
    [self.stack setCustomSpacing:kSectionSpacing afterView:socialLinksSeparator];

    UIStackView *socialLinksStack = [[UIStackView alloc] init];
    socialLinksStack.axis = UILayoutConstraintAxisVertical;
    socialLinksStack.alignment = UIStackViewAlignmentLeading;
    socialLinksStack.distribution = UIStackViewDistributionFill;
    socialLinksStack.spacing = 4;
    socialLinksStack.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *githubButton = [UIButton buttonWithType:UIButtonTypeSystem];
    githubButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_social_text_button(githubButton, @"View GitHub Repository");
    zs_attach_tap_to_confirm(githubButton, self, @"Open GitHub?",
        @"You'll be leaving the app to open this link in Safari.", @"Open", NO, ^{
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:kZSSocialGitHubURL] options:@{} completionHandler:nil];
    });
    [socialLinksStack addArrangedSubview:githubButton];

    UIButton *discordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    discordButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_social_text_button(discordButton, @"Join the Discord Server");
    zs_attach_tap_to_confirm(discordButton, self, @"Open Discord?",
        @"You'll be leaving the app to open this link in Safari.", @"Open", NO, ^{
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:kZSSocialDiscordURL] options:@{} completionHandler:nil];
    });
    [socialLinksStack addArrangedSubview:discordButton];

    [self.stack addArrangedSubview:socialLinksStack];
    }];

    [self layoutPanelForWindow:unityView];

    zs_gif_tint_preload();

    [CATransaction commit];
}

static const CGFloat kZSPanelSectionBuildHeadroom = 20.0;

- (BOOL)zs_hasPendingExperimentalSectionBuilders {
    return g_experimentalSettingsEnabled && self.experimentalSectionContainer && self.pendingExperimentalSectionBuilders.count > 0;
}

- (void)zs_runNextPendingSectionBuilder {
    if (!self.stack) return;

    NSMutableArray<dispatch_block_t> *queue = [self zs_hasPendingExperimentalSectionBuilders]
        ? self.pendingExperimentalSectionBuilders
        : self.pendingSectionBuilders;
    if (queue.count == 0) return;

    dispatch_block_t builder = queue.firstObject;
    [queue removeObjectAtIndex:0];

    NSUInteger before = self.stack.arrangedSubviews.count;
    builder();

    NSArray<UIView *> *arranged = self.stack.arrangedSubviews;
    NSDictionary *states = self.pendingCollapsedStates;
    for (NSUInteger i = before; i < arranged.count; i++) {
        [self zs_restoreCollapsedSectionsInView:arranged[i] states:states];
    }
}

- (void)zs_fillVisiblePanelSectionsWithHeadroom {
    if (!self.scrollView || !self.stack) return;

    CGFloat targetHeight = self.scrollView.bounds.size.height + self.scrollView.contentOffset.y + kZSPanelSectionBuildHeadroom;

    while (self.pendingSectionBuilders.count > 0 || [self zs_hasPendingExperimentalSectionBuilders]) {
        [self.stack setNeedsLayout];
        [self.stack layoutIfNeeded];
        if (self.stack.bounds.size.height >= targetHeight) break;
        [self zs_runNextPendingSectionBuilder];
    }

    [self.stack setNeedsLayout];
    [self.stack layoutIfNeeded];
}

- (void)zs_applyExperimentalAvailabilityTint {
    for (UIView *view in self.experimentalSectionContainer.arrangedSubviews) {
        if (![view isKindOfClass:[ZSRow class]]) continue;
        ZSRow *row = (ZSRow *)view;
        NSString *key = objc_getAssociatedObject(row.toggle, @"zs_exp_key")
                     ?: objc_getAssociatedObject(row.slider, @"zs_exp_key")
                     ?: objc_getAssociatedObject(row.modeSlider, @"zs_exp_key");
        if (!key || !row.titleLabel) continue;
        row.titleLabel.textColor = zs_exp_key_class_available(key)
            ? [UIColor colorWithWhite:0.9 alpha:1]
            : [UIColor colorWithWhite:0.9 alpha:0.35];
    }
}

#pragma mark Docs language switcher

static const CGFloat kZSDocsLanguageDropdownWidth = 132;

static UIImage *zs_make_docs_language_globe_image(void) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    UIImage *globeImage = [UIImage systemImageNamed:@"globe" withConfiguration:symbolConfig];
    globeImage = [globeImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.55]
                                   renderingMode:UIImageRenderingModeAlwaysOriginal];
    return globeImage;
}

static UIButton *zs_make_docs_language_option_button(NSDictionary<NSString *, NSString *> *option, BOOL selected, NSInteger tag, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.titleEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    button.titleLabel.font = zs_mono_font(12, UIFontWeightRegular);
    [button setTitle:option[@"name"] forState:UIControlStateNormal];
    [button setTitleColor:(selected ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.6])
                  forState:UIControlStateNormal];
    button.backgroundColor = UIColor.clearColor;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark Docs panel

- (void)buildDocsPanel:(UIView *)unityView {
    self.docsPanelWidth = self.panelWidth;

    if (zs_has_liquid_glass()) {
        self.docsPanelGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        self.docsPanelGlass.userInteractionEnabled = YES;
        zs_configure_glass_corners(self.docsPanelGlass, kPanelCornerRadiusMinimum, YES);
        [self.glassContainerContent addSubview:self.docsPanelGlass];
        [self.glassContainerContent sendSubviewToBack:self.docsPanelGlass];
        self.docsPanel = self.docsPanelGlass.contentView;
    } else {
        self.docsPanel = [[UIView alloc] init];
        self.docsPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        self.docsPanel.layer.cornerRadius = kPanelCornerRadiusMinimum;
        self.docsPanel.layer.cornerCurve = kCACornerCurveContinuous;
        self.docsPanel.clipsToBounds = YES;
        [self.glassContainerContent addSubview:self.docsPanel];
        [self.glassContainerContent sendSubviewToBack:self.docsPanel];
    }
    self.docsPanel.backgroundColor = self.docsPanelGlass ? UIColor.clearColor : self.docsPanel.backgroundColor;
    self.docsPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    self.docsContentOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.docsContentOverlay.backgroundColor = UIColor.clearColor;
    self.docsContentOverlay.opaque = NO;
    self.docsContentOverlay.clipsToBounds = YES;
    self.docsContentOverlay.layer.cornerRadius = kPanelCornerRadiusMinimum;
    self.docsContentOverlay.layer.cornerCurve = kCACornerCurveContinuous;
    self.docsContentOverlay.userInteractionEnabled = YES;
    self.docsContentOverlay.hidden = YES;
    [unityView addSubview:self.docsContentOverlay];
    zs_force_dark(self.docsContentOverlay);
    if (self.contentOverlay) {
        [unityView insertSubview:self.docsContentOverlay belowSubview:self.contentOverlay];
    }

    self.docsPanelSeparator = [[UIView alloc] init];
    self.docsPanelSeparator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    self.docsPanelSeparator.userInteractionEnabled = NO;
    self.docsPanelSeparator.hidden = YES;
    [self.glassContainerContent addSubview:self.docsPanelSeparator];

    self.docsTitleLabel = [[UILabel alloc] init];
    self.docsTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsTitleLabel.font = [UIFont monospacedSystemFontOfSize:21 weight:UIFontWeightBold];
    self.docsTitleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.95];
    [self.docsContentOverlay addSubview:self.docsTitleLabel];

    self.docsHeaderModeChevronButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.docsHeaderModeChevronButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.docsHeaderModeChevronButton setImage:zs_make_dropdown_chevron_image() forState:UIControlStateNormal];
    self.docsHeaderModeChevronButton.hidden = YES;
    [self.docsHeaderModeChevronButton addTarget:self action:@selector(docsHeaderModeChevronTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.docsContentOverlay addSubview:self.docsHeaderModeChevronButton];

    self.docsLanguageButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.docsLanguageButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.docsLanguageButton setImage:zs_make_docs_language_globe_image() forState:UIControlStateNormal];
    self.docsLanguageButton.hidden = YES;
    [self.docsLanguageButton addTarget:self action:@selector(docsLanguageButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.docsContentOverlay addSubview:self.docsLanguageButton];

    self.docsSubheaderRow = [[UIStackView alloc] init];
    self.docsSubheaderRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsSubheaderRow.axis = UILayoutConstraintAxisHorizontal;
    self.docsSubheaderRow.alignment = UIStackViewAlignmentCenter;
    self.docsSubheaderRow.spacing = 6;
    self.docsSubheaderRow.hidden = YES;
    [self.docsContentOverlay addSubview:self.docsSubheaderRow];

    self.docsSubheaderLabel = [[UILabel alloc] init];
    self.docsSubheaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsSubheaderLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightSemibold];
    self.docsSubheaderLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    [self.docsSubheaderRow addArrangedSubview:self.docsSubheaderLabel];

    self.docsSubheaderLeftArrowButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.docsSubheaderLeftArrowButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.docsSubheaderLeftArrowButton setImage:zs_make_release_history_arrow_image(YES) forState:UIControlStateNormal];
    self.docsSubheaderLeftArrowButton.hidden = YES;
    [self.docsSubheaderLeftArrowButton addTarget:self action:@selector(docsSubheaderOlderReleaseTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.docsSubheaderPageLabel = [[UILabel alloc] init];
    self.docsSubheaderPageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsSubheaderPageLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.docsSubheaderPageLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];

    self.docsSubheaderRightArrowButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.docsSubheaderRightArrowButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.docsSubheaderRightArrowButton setImage:zs_make_release_history_arrow_image(NO) forState:UIControlStateNormal];
    self.docsSubheaderRightArrowButton.hidden = YES;
    [self.docsSubheaderRightArrowButton addTarget:self action:@selector(docsSubheaderNewerReleaseTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.docsSubheaderPageGroup = [[UIStackView alloc] init];
    self.docsSubheaderPageGroup.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsSubheaderPageGroup.axis = UILayoutConstraintAxisHorizontal;
    self.docsSubheaderPageGroup.alignment = UIStackViewAlignmentCenter;
    self.docsSubheaderPageGroup.spacing = 6;
    self.docsSubheaderPageGroup.hidden = YES;
    [self.docsSubheaderPageGroup addArrangedSubview:self.docsSubheaderLeftArrowButton];
    [self.docsSubheaderPageGroup addArrangedSubview:self.docsSubheaderPageLabel];
    [self.docsSubheaderPageGroup addArrangedSubview:self.docsSubheaderRightArrowButton];
    [self.docsContentOverlay addSubview:self.docsSubheaderPageGroup];

    self.docsScrollView = [[UIScrollView alloc] init];
    self.docsScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsScrollView.showsVerticalScrollIndicator = NO;
    self.docsScrollView.alwaysBounceVertical = NO;
    self.docsScrollView.bounces = NO;
    self.docsScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.docsScrollView.delaysContentTouches = NO;
    [self.docsContentOverlay addSubview:self.docsScrollView];

    UIStackView *docsContent = [[UIStackView alloc] init];
    docsContent.translatesAutoresizingMaskIntoConstraints = NO;
    docsContent.axis = UILayoutConstraintAxisVertical;
    docsContent.alignment = UIStackViewAlignmentFill;
    docsContent.spacing = 18;
    [self.docsScrollView addSubview:docsContent];

    NSTextStorage *docsBodyTextStorage = [[NSTextStorage alloc] init];
    ZSDocsQuoteLayoutManager *docsBodyLayoutManager = [[ZSDocsQuoteLayoutManager alloc] init];
    [docsBodyTextStorage addLayoutManager:docsBodyLayoutManager];
    NSTextContainer *docsBodyTextContainer = [[NSTextContainer alloc] initWithSize:CGSizeZero];
    docsBodyTextContainer.widthTracksTextView = YES;
    [docsBodyLayoutManager addTextContainer:docsBodyTextContainer];

    self.docsBodyLabel = [[UITextView alloc] initWithFrame:CGRectZero textContainer:docsBodyTextContainer];
    self.docsBodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsBodyLabel.editable = NO;
    self.docsBodyLabel.selectable = YES;
    self.docsBodyLabel.scrollEnabled = NO;
    self.docsBodyLabel.backgroundColor = [UIColor clearColor];
    self.docsBodyLabel.textContainerInset = UIEdgeInsetsZero;
    self.docsBodyLabel.textContainer.lineFragmentPadding = 0;
    self.docsBodyLabel.dataDetectorTypes = UIDataDetectorTypeNone;
    self.docsBodyLabel.linkTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor colorWithRed:0.55 green:0.75 blue:1.0 alpha:1.0],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    };
    self.docsBodyLabel.delegate = self;
    [docsContent addArrangedSubview:self.docsBodyLabel];

    self.docsUpdateActionsStack = [[UIStackView alloc] init];
    self.docsUpdateActionsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsUpdateActionsStack.axis = UILayoutConstraintAxisVertical;
    self.docsUpdateActionsStack.alignment = UIStackViewAlignmentFill;
    self.docsUpdateActionsStack.spacing = 10;
    self.docsUpdateActionsStack.hidden = YES;
    [docsContent addArrangedSubview:self.docsUpdateActionsStack];

    UIFont *installButtonFont = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightSemibold];
    UIColor *liveContainerBlue = [UIColor colorWithRed:0.02 green:0.48 blue:1.0 alpha:1.0];

    NSString *liveContainerInstallTitle = @"LiveContainer installation";
    self.docsLiveContainerInstallButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.docsLiveContainerInstallButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_solid_glass_with_font(self.docsLiveContainerInstallButton, liveContainerInstallTitle, liveContainerBlue, installButtonFont);
    [self.docsLiveContainerInstallButton.heightAnchor constraintEqualToConstant:50].active = YES;
    [self.docsLiveContainerInstallButton addTarget:self action:@selector(docsLiveContainerInstallTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.docsUpdateActionsDisabledNoteLabel = [[UILabel alloc] init];
    self.docsUpdateActionsDisabledNoteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsUpdateActionsDisabledNoteLabel.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    self.docsUpdateActionsDisabledNoteLabel.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    self.docsUpdateActionsDisabledNoteLabel.textAlignment = NSTextAlignmentCenter;
    self.docsUpdateActionsDisabledNoteLabel.numberOfLines = 0;
    self.docsUpdateActionsDisabledNoteLabel.text = @"On-device install disabled for this release.";
    self.docsUpdateActionsDisabledNoteLabel.hidden = YES;

    self.docsGitHubReleaseLinkButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.docsGitHubReleaseLinkButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsGitHubReleaseLinkButton.contentEdgeInsets = UIEdgeInsetsMake(4, 0, 4, 0);
    [self.docsGitHubReleaseLinkButton addTarget:self action:@selector(docsGitHubReleaseLinkTapped:) forControlEvents:UIControlEventTouchUpInside];

    [self.docsUpdateActionsStack addArrangedSubview:self.docsLiveContainerInstallButton];
    [self.docsUpdateActionsStack addArrangedSubview:self.docsUpdateActionsDisabledNoteLabel];
    [self.docsUpdateActionsStack addArrangedSubview:self.docsGitHubReleaseLinkButton];
    [self.docsUpdateActionsStack setCustomSpacing:16 afterView:self.docsLiveContainerInstallButton];
    [self.docsUpdateActionsStack setCustomSpacing:14 afterView:self.docsUpdateActionsDisabledNoteLabel];

    self.docsScrollViewBottomToOverlayConstraint =
        [self.docsScrollView.bottomAnchor constraintEqualToAnchor:self.docsContentOverlay.bottomAnchor];

    self.docsScrollViewTopToTitleConstraint =
        [self.docsScrollView.topAnchor constraintEqualToAnchor:self.docsTitleLabel.bottomAnchor constant:8];
    self.docsScrollViewTopToSubheaderConstraint =
        [self.docsScrollView.topAnchor constraintEqualToAnchor:self.docsSubheaderRow.bottomAnchor constant:8];

    self.docsTitleTrailingFullConstraint =
        [self.docsTitleLabel.trailingAnchor constraintEqualToAnchor:self.docsContentOverlay.trailingAnchor constant:-kPanelPadding];
    self.docsTitleTrailingToChevronConstraint =
        [self.docsTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.docsHeaderModeChevronButton.leadingAnchor constant:-8];
    self.docsTitleTrailingToChevronConstraint.active = NO;

    self.docsTitleTrailingToLanguageConstraint =
        [self.docsTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.docsLanguageButton.leadingAnchor constant:-8];
    self.docsTitleTrailingToLanguageConstraint.active = NO;

    [NSLayoutConstraint activateConstraints:@[
        [self.docsTitleLabel.topAnchor constraintEqualToAnchor:self.docsContentOverlay.safeAreaLayoutGuide.topAnchor constant:kPanelPadding],
        [self.docsTitleLabel.leadingAnchor constraintEqualToAnchor:self.docsContentOverlay.leadingAnchor constant:kPanelPadding],
        self.docsTitleTrailingFullConstraint,

        [self.docsHeaderModeChevronButton.centerYAnchor constraintEqualToAnchor:self.docsTitleLabel.centerYAnchor],
        [self.docsHeaderModeChevronButton.trailingAnchor constraintEqualToAnchor:self.docsContentOverlay.trailingAnchor constant:-kPanelPadding],

        [self.docsLanguageButton.centerYAnchor constraintEqualToAnchor:self.docsTitleLabel.centerYAnchor],
        [self.docsLanguageButton.trailingAnchor constraintEqualToAnchor:self.docsContentOverlay.trailingAnchor constant:-kPanelPadding],

        [self.docsSubheaderRow.topAnchor constraintEqualToAnchor:self.docsTitleLabel.bottomAnchor constant:2],
        [self.docsSubheaderRow.leadingAnchor constraintEqualToAnchor:self.docsContentOverlay.leadingAnchor constant:kPanelPadding],

        [self.docsSubheaderPageGroup.centerYAnchor constraintEqualToAnchor:self.docsSubheaderRow.centerYAnchor],
        [self.docsSubheaderPageGroup.heightAnchor constraintEqualToAnchor:self.docsSubheaderRow.heightAnchor],
        [self.docsSubheaderPageGroup.trailingAnchor constraintEqualToAnchor:self.docsContentOverlay.trailingAnchor constant:-kPanelPadding],
        [self.docsSubheaderRow.trailingAnchor constraintLessThanOrEqualToAnchor:self.docsSubheaderPageGroup.leadingAnchor constant:-8],

        self.docsScrollViewTopToTitleConstraint,
        [self.docsScrollView.leadingAnchor constraintEqualToAnchor:self.docsContentOverlay.leadingAnchor],
        [self.docsScrollView.trailingAnchor constraintEqualToAnchor:self.docsContentOverlay.trailingAnchor],

        [docsContent.topAnchor constraintEqualToAnchor:self.docsScrollView.contentLayoutGuide.topAnchor constant:kPanelPadding],
        [docsContent.leadingAnchor constraintEqualToAnchor:self.docsScrollView.contentLayoutGuide.leadingAnchor constant:kPanelPadding],
        [docsContent.trailingAnchor constraintEqualToAnchor:self.docsScrollView.contentLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [docsContent.bottomAnchor constraintEqualToAnchor:self.docsScrollView.contentLayoutGuide.bottomAnchor constant:-kPanelPadding],
        [docsContent.widthAnchor constraintEqualToAnchor:self.docsScrollView.frameLayoutGuide.widthAnchor constant:-(kPanelPadding * 2)],
    ]];

    self.docsScrollViewBottomToOverlayConstraint.active = YES;
}

- (void)docsInfoTapped:(UIButton *)sender {
    NSString *key = objc_getAssociatedObject(sender, "zs_docsKey");
    if (!key) return;
    [self showDocsForKey:key];
}

static void zs_refresh_mode_and_wheel_sliders(UIView *view) {
    if ([view isKindOfClass:[ZSModeSlider class]]) {
        [(ZSModeSlider *)view zs_forceLabelRedisplay];
    } else if ([view isKindOfClass:[ZSWheelPicker class]]) {
        [(ZSWheelPicker *)view zs_forceLabelRedisplay];
    }
    for (UIView *sub in view.subviews) {
        zs_refresh_mode_and_wheel_sliders(sub);
    }
}

static void zs_save_collapsed_section_state(NSString *title, BOOL collapsed) {
    if (!title.length) return;
    NSMutableDictionary *section = [zs_settings_section(kZSUISettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *collapsedSections = [section[kZSUICollapsedSectionsKey] isKindOfClass:[NSDictionary class]]
        ? [section[kZSUICollapsedSectionsKey] mutableCopy]
        : [NSMutableDictionary new];
    collapsedSections[title] = @(collapsed);
    section[kZSUICollapsedSectionsKey] = collapsedSections;
    zs_write_settings_section(kZSUISettingsSection, section);
}

static NSDictionary *zs_load_collapsed_section_states(void) {
    NSDictionary *section = zs_settings_section(kZSUISettingsSection);
    NSDictionary *states = section[kZSUICollapsedSectionsKey];
    return [states isKindOfClass:[NSDictionary class]] ? states : @{};
}

- (void)zs_restoreCollapsedSectionsInView:(UIView *)view states:(NSDictionary *)states {
    if (!view) return;
    if ([objc_getAssociatedObject(view, "zs_isSectionHeader") boolValue]) {
        NSString *title = objc_getAssociatedObject(view, "zs_sectionTitle");
        UIButton *chevronButton = objc_getAssociatedObject(view, "zs_sectionChevronButton");
        if ([states[title] boolValue] && chevronButton) {
            [self zs_sectionCollapseToggleTapped:chevronButton];
        }
    }
    for (UIView *subview in view.subviews) {
        [self zs_restoreCollapsedSectionsInView:subview states:states];
    }
}

- (void)zs_titleHeaderTapped:(UITapGestureRecognizer *)recognizer {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.developerUnlockLastTapTime > kZSDeveloperUnlockTapInterval) {
        self.developerUnlockTapCount = 0;
    }
    self.developerUnlockLastTapTime = now;
    self.developerUnlockTapCount++;

    if (self.developerUnlockTapCount < kZSDeveloperUnlockTapCount) return;
    self.developerUnlockTapCount = 0;

    BOOL enabled = !zs_developer_settings_enabled();
    zs_set_developer_settings_enabled(enabled);
    ZLog(@"[UserInterface] developer settings %@", enabled ? @"enabled" : @"disabled");
    [self zs_applyDeveloperSectionVisibilityRelayout:YES];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:enabled ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning];
}

- (void)zs_applyDeveloperSectionVisibilityRelayout:(BOOL)relayout {
    NSArray<UIView *> *sectionViews = self.developerSectionViews;
    if (sectionViews.count == 0) return;

    BOOL visible = zs_developer_settings_enabled();

    UIView *headerRow = nil;
    for (UIView *view in sectionViews) {
        if ([objc_getAssociatedObject(view, "zs_isSectionHeader") boolValue]) {
            headerRow = view;
            break;
        }
    }
    BOOL collapsed = [objc_getAssociatedObject(headerRow, "zs_sectionCollapsed") boolValue];

    NSMutableArray<UIView *> *revealedViews = [NSMutableArray array];
    for (UIView *view in sectionViews) {
        view.hidden = (view == headerRow) ? !visible : (!visible || collapsed);
        if (!view.hidden) [revealedViews addObject:view];
    }

    if (!relayout) return;

    [self.stack setNeedsLayout];
    [self.stack layoutIfNeeded];
    [self.glassContainer setNeedsLayout];
    [self.glassContainer layoutIfNeeded];
    [self.panel setNeedsLayout];
    [self.panel layoutIfNeeded];
    [self.scrollViewport setNeedsLayout];
    [self.scrollViewport layoutIfNeeded];
    [self zs_updateSliderGlassVisibility];

    if (revealedViews.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIView *view in revealedViews) {
                zs_refresh_mode_and_wheel_sliders(view);
            }
        });
    }
}

- (void)zs_sectionCollapseToggleTapped:(UIButton *)sender {
    UIView *headerRow = objc_getAssociatedObject(sender, "zs_sectionHeaderRow");
    if (!headerRow) return;

    UIStackView *stack = [headerRow.superview isKindOfClass:[UIStackView class]] ? (UIStackView *)headerRow.superview : nil;
    if (!stack) return;

    NSArray<UIView *> *arranged = stack.arrangedSubviews;
    NSUInteger headerIndex = [arranged indexOfObject:headerRow];
    if (headerIndex == NSNotFound) return;

    BOOL collapsed = ![objc_getAssociatedObject(headerRow, "zs_sectionCollapsed") boolValue];
    objc_setAssociatedObject(headerRow, "zs_sectionCollapsed", @(collapsed), OBJC_ASSOCIATION_RETAIN);
    zs_save_collapsed_section_state(objc_getAssociatedObject(headerRow, "zs_sectionTitle"), collapsed);

    UIView *leadingSeparator = objc_getAssociatedObject(headerRow, "zs_sectionLeadingSeparator");
    leadingSeparator.hidden = collapsed;

    NSMutableArray<UIView *> *revealedViews = collapsed ? nil : [NSMutableArray array];
    for (NSUInteger i = headerIndex + 1; i < arranged.count; i++) {
        UIView *view = arranged[i];
        if ([objc_getAssociatedObject(view, "zs_isSectionHeader") boolValue]) break;
        if (!zs_developer_settings_enabled() && [self.developerSectionViews containsObject:view]) continue;

        if (view == self.experimentalSectionContainer) {
            view.hidden = collapsed ? YES : !g_experimentalSettingsEnabled;
        } else {
            view.hidden = collapsed;
        }
        if (revealedViews && !view.hidden) [revealedViews addObject:view];
    }

    [sender setImage:zs_section_collapse_chevron_image(collapsed) forState:UIControlStateNormal];

    [self.stack setNeedsLayout];
    [self.stack layoutIfNeeded];
    [self.glassContainer setNeedsLayout];
    [self.glassContainer layoutIfNeeded];
    [self.panel setNeedsLayout];
    [self.panel layoutIfNeeded];
    [self.scrollViewport setNeedsLayout];
    [self.scrollViewport layoutIfNeeded];
    [self zs_updateSliderGlassVisibility];

    if (revealedViews.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIView *view in revealedViews) {
                zs_refresh_mode_and_wheel_sliders(view);
            }
        });
    }
}

- (BOOL)textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)URL
         inRange:(NSRange)characterRange interaction:(UITextItemInteraction)interaction {
    if (textView != self.docsBodyLabel) return YES;

    if (URL.scheme.length == 0) {
        NSString *targetKey = zs_docs_key_for_filename(URL.path);
        if (targetKey) {
            [self showDocsForKey:targetKey];
        } else {
            ZLog(@"[UserInterface] Docs: couldn't resolve cross-reference link \"%@\" to a known section", URL);
        }
        return NO;
    }

    if ([URL.scheme isEqualToString:@"http"] || [URL.scheme isEqualToString:@"https"]) {
        [[UIApplication sharedApplication] openURL:URL options:@{} completionHandler:nil];
        return NO;
    }

    if ([URL.scheme isEqualToString:@"zsupdate"] && [URL.host isEqualToString:@"replace"]) {
        ZSUpdateCheckMode mode = ZSUpdateCheckModeReleases;
        NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"mode"]) mode = (ZSUpdateCheckMode)item.value.integerValue;
        }
        [self zs_confirmAndReplaceInstalledDylibWithMode:mode];
        return NO;
    }
    return NO;
}

- (void)zs_setDocsBodyForKey:(NSString *)key markdown:(NSString *)markdown width:(CGFloat)width loading:(BOOL)loading {
    if (markdown) {
        self.docsBodyLabel.attributedText = zs_render_markdown(markdown, width);
        return;
    }
    NSString *placeholder = loading
        ? @"Loading documentation\u2026"
        : @"Documentation for this section is coming soon.";
    self.docsBodyLabel.attributedText = [[NSAttributedString alloc] initWithString:placeholder
        attributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular],
                      NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55]}];
}

- (void)zs_fetchMissingImagesForKey:(NSString *)key markdown:(NSString *)markdown width:(CGFloat)width {
    if (markdown.length == 0) return;

    __weak typeof(self) weakSelf = self;
    for (NSString *imageName in zs_docs_image_names_in_markdown(markdown)) {
        if (zs_docs_cached_image(imageName)) continue;

        zs_docs_fetch_image(imageName, ^(UIImage * _Nullable image) {
            if (!image) return;
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!strongSelf.docsPanelOpen || ![strongSelf.docsActiveKey isEqualToString:key]) return;
            [strongSelf zs_setDocsBodyForKey:key markdown:markdown width:width loading:NO];
        });
    }
}

- (void)zs_setDocsSubheaderText:(nullable NSString *)text {
    if (text.length > 0) {
        self.docsSubheaderLabel.text = text;
        self.docsSubheaderRow.hidden = NO;
        self.docsScrollViewTopToTitleConstraint.active = NO;
        self.docsScrollViewTopToSubheaderConstraint.active = YES;
    } else {
        self.docsSubheaderLabel.text = nil;
        self.docsSubheaderRow.hidden = YES;
        [self zs_setDocsSubheaderArrowsVisible:NO hasOlder:NO atLatest:YES];
        self.docsScrollViewTopToSubheaderConstraint.active = NO;
        self.docsScrollViewTopToTitleConstraint.active = YES;
    }
}

- (void)zs_updateDocsHeaderTrailingConstraints {
    BOOL chevronVisible = !self.docsHeaderModeChevronButton.hidden;
    BOOL languageVisible = !self.docsLanguageButton.hidden;
    self.docsTitleTrailingToChevronConstraint.active = chevronVisible;
    self.docsTitleTrailingToLanguageConstraint.active = languageVisible && !chevronVisible;
    self.docsTitleTrailingFullConstraint.active = !chevronVisible && !languageVisible;
}

- (void)zs_setDocsHeaderChevronVisible:(BOOL)visible {
    self.docsHeaderModeChevronButton.hidden = !visible;
    [self zs_updateDocsHeaderTrailingConstraints];
}

- (void)zs_setDocsLanguageButtonVisible:(BOOL)visible {
    self.docsLanguageButton.hidden = !visible;
    if (!visible && self.docsLanguageDropdownOpen) {
        [self zs_closeDocsLanguageDropdownAnimated:NO];
    }
    [self zs_updateDocsHeaderTrailingConstraints];
}

- (void)zs_setDocsSubheaderArrowsVisible:(BOOL)visible hasOlder:(BOOL)hasOlder atLatest:(BOOL)atLatest {
    self.docsSubheaderPageGroup.hidden = !visible;
    self.docsSubheaderLeftArrowButton.enabled = hasOlder;
    self.docsSubheaderLeftArrowButton.alpha = hasOlder ? 1.0 : 0.3;
    self.docsSubheaderRightArrowButton.enabled = !atLatest;
    self.docsSubheaderRightArrowButton.alpha = atLatest ? 0.3 : 1.0;
    self.docsSubheaderPageLabel.text = visible
        ? [NSString stringWithFormat:@"Page %lu", (unsigned long)(self.docsReleaseHistoryIndex + 1)]
        : nil;
}

- (void)showDocsForKey:(NSString *)key {
    if (!self.panelOpen || !key) return;

    self.docsActiveKey = key;
    self.docsTitleLabel.text = [key uppercaseString];
    [self zs_setDocsHeaderChevronVisible:NO];
    [self zs_setDocsLanguageButtonVisible:YES];
    [self zs_setDocsSubheaderText:nil];
    [self zs_setDocsUpdateActionsVisible:NO];

    CGFloat docsContentWidth = (self.docsPanelWidth > 0 ? self.docsPanelWidth : self.panelWidth) - (kPanelPadding * 2);

    NSString *cachedMarkdown = zs_docs_cached_content(key);
    [self zs_setDocsBodyForKey:key markdown:cachedMarkdown width:docsContentWidth loading:(cachedMarkdown == nil)];
    if (cachedMarkdown) {
        [self zs_fetchMissingImagesForKey:key markdown:cachedMarkdown width:docsContentWidth];
    }
    self.docsScrollView.contentOffset = CGPointZero;

    __weak typeof(self) weakSelf = self;
    zs_docs_fetch_latest(key, ^(NSString *freshMarkdown, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf.docsPanelOpen || ![strongSelf.docsActiveKey isEqualToString:key]) return;

        if (freshMarkdown) {
            [strongSelf zs_setDocsBodyForKey:key markdown:freshMarkdown width:docsContentWidth loading:NO];
            [strongSelf zs_fetchMissingImagesForKey:key markdown:freshMarkdown width:docsContentWidth];
        } else if (!zs_docs_cached_content(key)) {
            strongSelf.docsBodyLabel.attributedText = [[NSAttributedString alloc]
                initWithString:@"Couldn't load documentation. Check your connection and reopen this section."
                     attributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular],
                                   NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55]}];
        }
    });

    if (self.docsPanelOpen) {
        return;
    }

    self.docsPanelOpen = YES;
    [self positionPanelAnimated:YES];
    [UIView animateWithDuration:0.2 animations:^{
        self.chevron.text = @"\u2715";
    }];
}

- (void)closeDocsPanel {
    if (!self.docsPanelOpen) return;

    if (self.docsLanguageDropdownOpen) {
        [self zs_closeDocsLanguageDropdownAnimated:NO];
    }

    self.docsPanelOpen = NO;
    self.docsActiveKey = nil;
    [self positionPanelAnimated:YES];
    [UIView animateWithDuration:0.2 animations:^{
        self.chevron.text = @"\u2039";
    }];
}

- (void)layoutDocsPanelForWindow:(UIView *)unityView {
    if (!self.docsPanel) return;

    if (self.docsLanguageDropdownOpen) {
        [self zs_closeDocsLanguageDropdownAnimated:NO];
    }

    self.docsScrollView.contentInset = UIEdgeInsetsMake(0,
                                                          0,
                                                          unityView.safeAreaInsets.bottom + 12,
                                                          0);
}

#pragma mark Settings persistence

- (void)zs_scheduleSave {
    [self.saveDebounceTimer invalidate];
    self.saveDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:kSaveDebounceInterval
                                                                target:self
                                                              selector:@selector(zs_writeSettingsNow)
                                                              userInfo:nil
                                                               repeats:NO];
}

- (void)zs_writeSettingsNow {
    self.saveDebounceTimer = nil;
    zs_persist_current_settings();
}

#pragma mark Reset

static void zs_collect_rows_recursive(UIView *view, NSMutableArray<ZSRow *> *out) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[ZSRow class]]) {
            [out addObject:(ZSRow *)subview];
        }
        zs_collect_rows_recursive(subview, out);
    }
}

- (void)resetSettingsTapped {
    NSMutableArray<ZSRow *> *allRows = [NSMutableArray array];
    zs_collect_rows_recursive(self.stack, allRows);
    for (ZSRow *row in allRows) {
        if (row.slider && row.slider.hasDefaultValue) {
            row.slider.value = row.slider.defaultValue;
            zs_update_value_label(row.slider);
            [row.slider sendActionsForControlEvents:UIControlEventValueChanged];
        } else if (row.modeSlider) {
            NSInteger def = row.modeSlider.defaultIndex >= 0 ? row.modeSlider.defaultIndex : 0;
            [row.modeSlider setSelectedIndex:def animated:YES];
            [row.modeSlider sendActionsForControlEvents:UIControlEventValueChanged];
        } else if (row.wheelPicker) {
            NSInteger def = row.wheelPicker.defaultIndex >= 0 ? row.wheelPicker.defaultIndex : 0;
            [row.wheelPicker setSelectedIndex:def animated:YES];
            [row.wheelPicker sendActionsForControlEvents:UIControlEventValueChanged];
        } else if (row.toggle) {
            NSNumber *def = objc_getAssociatedObject(row.toggle, "zs_defaultBool");
            if (def) {
                row.toggle.on = def.boolValue;
                [row.toggle sendActionsForControlEvents:UIControlEventValueChanged];
            }
        }
    }

    [self.saveDebounceTimer invalidate];
    self.saveDebounceTimer = nil;
    zs_persist_current_settings();

    ZLog(@"[UserInterface] Reset Settings tapped - all rows restored to their default values");
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)reapplySettingsTapped {
    ZLog(@"[UserInterface] Reapply Settings tapped");
    zs_reapply_all_settings();

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

#pragma mark Config (Manually Index Files)

- (void)manuallyIndexFilesTapped {
    UIViewController *presenter = zs_key_window().rootViewController;
    UIAlertController *indexing = [UIAlertController alertControllerWithTitle:@"Indexing\u2026"
                                                                        message:@"Assets are being indexed."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [indexing.view addSubview:spinner];
    [spinner startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:indexing.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:indexing.view.bottomAnchor constant:-16],
    ]];
    if (presenter) [presenter presentViewController:indexing animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [ZSFileIndex forceReindex];
        ZLog(@"[UserInterface] Manually Index Files: reindex complete");

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            void (^afterDismiss)(void) = ^{
                [strongSelf zs_presentModsAlertWithTitle:@"Manually Index Files"
                                                  message:@"File index rebuilt."];
            };
            if (indexing.presentingViewController) {
                [indexing dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

- (void)memoryCleanupTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];
    sender.enabled = NO;
    zs_run_memory_cleanup(^(BOOL ran) {
        sender.enabled = YES;
        if (!ran) return;
        UINotificationFeedbackGenerator *doneHaptic = [UINotificationFeedbackGenerator new];
        [doneHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    });
}

- (UIView *)zs_buildMemoryUsageCard {
    ZSPieChartView *pieChart = [[ZSPieChartView alloc] init];
    pieChart.translatesAutoresizingMaskIntoConstraints = NO;
    self.memoryUsagePieChart = pieChart;

    UIStackView *legendStack = [[UIStackView alloc] init];
    legendStack.translatesAutoresizingMaskIntoConstraints = NO;
    legendStack.axis = UILayoutConstraintAxisVertical;
    legendStack.spacing = 6;
    self.memoryUsageLegendStack = legendStack;

    UIView *chartRow = [[UIView alloc] init];
    chartRow.translatesAutoresizingMaskIntoConstraints = NO;
    [chartRow addSubview:pieChart];
    [chartRow addSubview:legendStack];
    chartRow.hidden = YES;
    self.memoryUsageChartRow = chartRow;

    [NSLayoutConstraint activateConstraints:@[
        [pieChart.leadingAnchor constraintEqualToAnchor:chartRow.leadingAnchor],
        [pieChart.topAnchor constraintEqualToAnchor:chartRow.topAnchor],
        [pieChart.bottomAnchor constraintEqualToAnchor:chartRow.bottomAnchor],
        [pieChart.widthAnchor constraintEqualToConstant:84],
        [pieChart.heightAnchor constraintEqualToConstant:84],

        [legendStack.leadingAnchor constraintEqualToAnchor:pieChart.trailingAnchor constant:16],
        [legendStack.trailingAnchor constraintEqualToAnchor:chartRow.trailingAnchor],
        [legendStack.centerYAnchor constraintEqualToAnchor:chartRow.centerYAnchor],
        [legendStack.topAnchor constraintGreaterThanOrEqualToAnchor:chartRow.topAnchor],
        [legendStack.bottomAnchor constraintLessThanOrEqualToAnchor:chartRow.bottomAnchor],
    ]];

    UILabel *statusLabel = zs_make_hint_label(@"Tap Analyze memory usage to scan loaded textures, meshes, audio and other assets.");
    statusLabel.textAlignment = NSTextAlignmentCenter;
    self.memoryUsageStatusLabel = statusLabel;

    UIStackView *contentStack = [[UIStackView alloc] init];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.axis = UILayoutConstraintAxisVertical;
    contentStack.spacing = 10;
    [contentStack addArrangedSubview:statusLabel];
    [contentStack addArrangedSubview:chartRow];

    UIView *card = zs_make_glass_container_card(contentStack, UIEdgeInsetsMake(14, 14, 14, 14));
    card.layer.borderWidth = 1;
    card.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;

    return card;
}

- (void)memoryUsageAnalyzeTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];
    sender.enabled = NO;
    self.memoryUsageStatusLabel.text = @"Scanning loaded assets…";
    self.memoryUsageChartRow.hidden = YES;

    __weak typeof(self) weakSelf = self;
    zs_collect_memory_usage_breakdown(^(NSArray<ZSMemoryUsageCategory *> *categories) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        sender.enabled = YES;
        [strongSelf zs_applyMemoryUsageCategories:categories];
    });
}

- (void)zs_applyMemoryUsageCategories:(NSArray<ZSMemoryUsageCategory *> *)categories {
    if (categories.count == 0) {
        self.memoryUsageStatusLabel.text = @"No trackable asset memory usage found.";
        self.memoryUsageChartRow.hidden = YES;
        return;
    }

    NSArray<UIColor *> *palette = zs_memory_chart_palette();
    NSUInteger maxSlices = palette.count;
    NSMutableArray<ZSMemoryUsageCategory *> *merged = [NSMutableArray new];

    if (categories.count > maxSlices) {
        [merged addObjectsFromArray:[categories subarrayWithRange:NSMakeRange(0, maxSlices - 1)]];
        int64_t otherTotal = 0;
        NSUInteger otherCount = 0;
        for (NSUInteger i = maxSlices - 1; i < categories.count; i++) {
            otherTotal += categories[i].totalBytes;
            otherCount += categories[i].objectCount;
        }
        ZSMemoryUsageCategory *other = [ZSMemoryUsageCategory new];
        other.name = @"Other";
        other.totalBytes = otherTotal;
        other.objectCount = otherCount;
        [merged addObject:other];
    } else {
        [merged addObjectsFromArray:categories];
    }

    int64_t grandTotal = 0;
    for (ZSMemoryUsageCategory *category in merged) grandTotal += category.totalBytes;

    if (grandTotal <= 0) {
        self.memoryUsageStatusLabel.text = @"No trackable asset memory usage found.";
        self.memoryUsageChartRow.hidden = YES;
        return;
    }

    for (UIView *row in self.memoryUsageLegendStack.arrangedSubviews.copy) {
        [row removeFromSuperview];
    }

    NSMutableArray<NSNumber *> *fractions = [NSMutableArray new];
    NSMutableArray<UIColor *> *colors = [NSMutableArray new];

    for (NSUInteger i = 0; i < merged.count; i++) {
        ZSMemoryUsageCategory *category = merged[i];
        double fraction = (double)category.totalBytes / (double)grandTotal;
        UIColor *color = palette[i % palette.count];
        [fractions addObject:@(fraction)];
        [colors addObject:color];

        NSString *sizeText = [NSByteCountFormatter stringFromByteCount:(long long)category.totalBytes countStyle:NSByteCountFormatterCountStyleFile];
        NSString *detailText = [NSString stringWithFormat:@"%.0f%% · %@", fraction * 100.0, sizeText];
        UIView *legendRow = zs_make_memory_legend_row(category.name, detailText, color);
        [self.memoryUsageLegendStack addArrangedSubview:legendRow];
    }

    [self.memoryUsagePieChart setSlicesWithFractions:fractions colors:colors];
    NSString *totalText = [NSByteCountFormatter stringFromByteCount:(long long)grandTotal countStyle:NSByteCountFormatterCountStyleFile];
    self.memoryUsageStatusLabel.text = [NSString stringWithFormat:@"Total tracked: %@", totalText];
    self.memoryUsageChartRow.hidden = NO;
}

- (void)dumpIL2CPPMethodsTapped {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *working = [self zs_presentDylibInstallWorkingAlertWithTitle:@"Dumping IL2CPP…"
                                                                             message:@"Enumerating loaded assemblies, classes, methods, fields, and properties."];
    __weak typeof(self) weakSelf = self;
    [ZSDumper dumpIL2CPPToDocumentsWithCompletion:^(NSURL * _Nullable outputURL, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf zs_dismissDylibInstallWorkingAlert:working thenRun:^{
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            if (error) {
                [haptic notificationOccurred:UINotificationFeedbackTypeError];
                [strongSelf zs_presentModsAlertWithTitle:@"IL2CPP Dump Failed"
                                                  message:error.localizedDescription ?: @"Unknown error."];
                return;
            }
            [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            [strongSelf zs_presentModsAlertWithTitle:@"IL2CPP Dump Complete"
                                              message:[NSString stringWithFormat:@"Saved to %@", outputURL.path ?: @"Documents"]];
        }];
    }];
}

#pragma mark Config (Delete Specific Asset)

- (void)deleteSpecificAssetTapped {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Delete Specific Asset"
                                                                      message:@"Enter a filename, filename hash, or CAB identifier to search for in the index."
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Filename, hash, or CAB identifier";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
    }];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [prompt addAction:[UIAlertAction actionWithTitle:@"Search" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *trimmed = [(prompt.textFields.firstObject.text ?: @"")
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) return;
        [weakSelf zs_searchAndConfirmDeleteAssetForQuery:trimmed];
    }]];
    [presenter presentViewController:prompt animated:YES completion:nil];
}

- (void)zs_searchAndConfirmDeleteAssetForQuery:(NSString *)query {
    UIAlertController *working = [self zs_presentDylibInstallWorkingAlertWithTitle:@"Searching\u2026"
        message:@"Looking for a match in the index."];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [ZSFileIndex ensureIndexUpToDate];

        NSArray<NSString *> *bundleMatches = [ZSFileIndex allCachedBundlePathsMatchingQuery:query];
        if (bundleMatches.count > 1) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf zs_dismissDylibInstallWorkingAlert:working thenRun:^{
                    [weakSelf zs_presentAmbiguousDeleteAssetMatches:bundleMatches forQuery:query];
                }];
            });
            return;
        }
        if (bundleMatches.count == 1) {
            NSString *matchedPath = bundleMatches.firstObject;
            NSString *displayPath = [ModAssetLibrary liveGamePathDescriptionForInstalledURL:[NSURL fileURLWithPath:matchedPath]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf zs_dismissDylibInstallWorkingAlert:working thenRun:^{
                    [weakSelf zs_confirmDeleteAssetAtPath:matchedPath
                                            fileName:matchedPath.lastPathComponent
                                                kind:@"Asset Bundle"
                                         displayPath:displayPath];
                }];
            });
            return;
        }

        NSString *fmodDir = [BankTransplant mobileFMODBuildsDirectory];
        NSArray<NSString *> *fmodMatches = @[];
        if (fmodDir.length > 0) {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSMutableArray<NSString *> *existingFMODMatches = [NSMutableArray array];
            for (NSString *name in [ZSFileIndex allCachedFMODFileNamesMatchingQuery:query]) {
                NSString *candidate = [fmodDir stringByAppendingPathComponent:name];
                if ([fm fileExistsAtPath:candidate]) [existingFMODMatches addObject:candidate];
            }
            fmodMatches = existingFMODMatches;
        }
        if (fmodMatches.count > 1) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf zs_dismissDylibInstallWorkingAlert:working thenRun:^{
                    [weakSelf zs_presentAmbiguousDeleteAssetMatches:fmodMatches forQuery:query];
                }];
            });
            return;
        }
        if (fmodMatches.count == 1) {
            NSString *fmodPath = fmodMatches.firstObject;
            NSString *displayPath = [ModAssetLibrary liveGamePathDescriptionForInstalledURL:[NSURL fileURLWithPath:fmodPath]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf zs_dismissDylibInstallWorkingAlert:working thenRun:^{
                    [weakSelf zs_confirmDeleteAssetAtPath:fmodPath
                                            fileName:fmodPath.lastPathComponent
                                                kind:@"FMOD Audio Bank"
                                         displayPath:displayPath];
                }];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf zs_dismissDylibInstallWorkingAlert:working thenRun:^{
                UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
                [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
                [weakSelf zs_presentModsAlertWithTitle:@"Not Found"
                                            message:[NSString stringWithFormat:@"No file, hash, or CAB identifier matching \u201C%@\u201D was found in the index.", query]];
            }];
        });
    });
}

- (void)zs_presentAmbiguousDeleteAssetMatches:(NSArray<NSString *> *)matchedPaths forQuery:(NSString *)query {
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeError];
    [self zs_presentModsAlertWithTitle:@"Multiple Matches Found"
                                message:[NSString stringWithFormat:@"\u201C%@\u201D matched %ld different files in the index. Narrow your search so it matches exactly one file, then try again.", query, (long)matchedPaths.count]];
}

- (void)zs_confirmDeleteAssetAtPath:(NSString *)path
                            fileName:(NSString *)fileName
                                kind:(NSString *)kind
                         displayPath:(NSString *)displayPath {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Asset?"
                                                                       message:[NSString stringWithFormat:@"Found a matching %@:\n\n\u201C%@\u201D\n%@\n\nThis will permanently delete it from the game's files. This can't be undone.",
                                                                                kind, fileName, displayPath]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Abort" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_performDeleteAssetAtPath:path fileName:fileName];
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_performDeleteAssetAtPath:(NSString *)path fileName:(NSString *)fileName {
    NSError *deleteErr = nil;
    BOOL ok = [NSFileManager.defaultManager removeItemAtPath:path error:&deleteErr];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];

    if (ok) {
        ZLog(@"[UserInterface] Delete Specific Asset: deleted %@", path);
        [self zs_presentModsAlertWithTitle:@"Delete Specific Asset"
                                    message:[NSString stringWithFormat:@"\u201C%@\u201D was deleted.", fileName]];
    } else {
        ZLog(@"[UserInterface] Delete Specific Asset: failed to delete %@: %@", path, deleteErr.localizedDescription);
        [self zs_presentModsAlertWithTitle:@"Delete Specific Asset"
                                    message:[NSString stringWithFormat:@"Couldn't delete \u201C%@\u201D: %@", fileName, deleteErr.localizedDescription ?: @"Unknown error."]];
    }
}

#pragma mark Config (Hard Assets Reset)

- (void)hardAssetsResetTapped {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSArray<NSString *> *trackedPaths = zs_tracked_asset_paths();
    NSInteger assetsDeleted = 0;
    for (NSString *path in trackedPaths) {
        if (![fm fileExistsAtPath:path]) continue;
        NSError *removeErr = nil;
        if ([fm removeItemAtPath:path error:&removeErr]) {
            assetsDeleted++;
        } else {
            ZLog(@"[UserInterface] hard reset: couldn't delete live asset %@: %@", path, removeErr.localizedDescription);
        }
    }
    zs_clear_tracked_asset_paths();

    NSString *bankBackupDir = [BankTransplant bankBackupDirectory];
    if (bankBackupDir) [fm removeItemAtPath:bankBackupDir error:nil];
    NSString *bundleBackupDir = [ZTranscoderInstaller bundleBackupDirectory];
    if (bundleBackupDir) [fm removeItemAtPath:bundleBackupDir error:nil];
    NSString *localizationBackupDir = [LocalizationTransplant backupDirectory];
    if (localizationBackupDir) [fm removeItemAtPath:localizationBackupDir error:nil];

    NSError *libraryError = nil;
    BOOL libraryCleared = [ModAssetLibrary deleteAllFoldersWithError:&libraryError];

    [self zs_rebuildModsLibrary];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];

    if (!libraryCleared) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        NSString *reason = libraryError.localizedDescription ?: @"Unknown error.";
        [self zs_presentModsAlertWithTitle:@"Hard Reset Failed" message:reason];
        return;
    }

    if (assetsDeleted == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        [self zs_presentModsAlertWithTitle:@"Nothing to Reset"
                                    message:@"No tracked assets were found."];
        return;
    }

    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    NSString *message = [NSString stringWithFormat:
        @"Deleted %ld tracked asset%@ from the game's own files, cleared every backup, and emptied the Mod Asset Library. Restart the game for it to take effect.",
        (long)assetsDeleted, assetsDeleted == 1 ? @"" : @"s"];
    ZLog(@"[UserInterface] Hard Assets Reset: deleted %ld tracked asset(s), cleared backups and the Mod Asset Library", (long)assetsDeleted);
    [self zs_presentModsAlertWithTitle:@"Hard Assets Reset" message:message offersRestart:YES];
}

- (void)deleteStoredBundlesInProxyTapped:(UIButton *)button {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first."];
        return;
    }

    NSString *originalTitle = [button titleForState:UIControlStateNormal];
    button.enabled = NO;
    [button setTitle:@"Deleting\u2026" forState:UIControlStateNormal];

    __weak typeof(self) weakSelf = self;
    [ZTranscoderService deleteAllReleasesForConfig:config completion:^(NSInteger deletedCount, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        button.enabled = YES;
        [button setTitle:originalTitle forState:UIControlStateNormal];

        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        if (error) {
            [haptic notificationOccurred:UINotificationFeedbackTypeError];
            [strongSelf zs_presentModsAlertWithTitle:@"Delete Failed"
                                              message:error.localizedDescription ?: @"Couldn't reach the configured repository."];
            return;
        }

        if (deletedCount == 0) {
            [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
            [strongSelf zs_presentModsAlertWithTitle:@"Nothing to Delete"
                                              message:@"No releases were found in the configured repository."];
            return;
        }

        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
        ZLog(@"[UserInterface] Delete Stored Bundles in Proxy: deleted %ld release(s)", (long)deletedCount);
        [strongSelf zs_presentModsAlertWithTitle:@"Proxy Cleared"
                                          message:[NSString stringWithFormat:@"Deleted %ld release%@ from the configured repository.",
                                                    (long)deletedCount, deletedCount == 1 ? @"" : @"s"]];
    }];
}

#pragma mark Mods (Load Mods - single entry point, routes by file kind)

- (void)loadModsTapped {
    __weak typeof(self) weakSelf = self;
    [self zs_promptForModFolderNameWithTitle:@"New Mod Folder"
                                  actionTitle:@"Create"
                                   completion:^(NSString *trimmedName) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSError *error = nil;
        BOOL created = [ModAssetLibrary createFolderNamed:trimmedName error:&error];
        if (!created) {
            [strongSelf zs_presentModsAlertWithTitle:@"Couldn't Create Folder" message:error.localizedDescription ?: @"Unknown error."];
            return;
        }
        [strongSelf zs_rebuildModsLibrary];
        [strongSelf zs_presentLoadModsPickerIntoFolder:trimmedName];
    }];
}

- (void)zs_presentLoadModsPickerIntoFolder:(NSString *)folderName {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem, UTTypeFolder]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item", @"public.folder"]
                                                                          inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods] no root view controller to present the file picker from");
        return;
    }
    self.loadModsPicker = picker;
    self.loadModsTargetFolder = folderName;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    if (controller == self.loadModsPicker) {
        NSString *folderName = self.loadModsTargetFolder;
        self.loadModsTargetFolder = nil;
        if (folderName) [self zs_handleLoadModsPickedURLs:urls intoFolder:folderName];
        return;
    }
    if (controller == self.libraryImportPicker) {
        NSString *folderName = self.libraryImportTargetFolder;
        self.libraryImportTargetFolder = nil;
        if (folderName) [self zs_handlePickedLibraryImportURLs:urls intoFolder:folderName];
        return;
    }
    if (controller == self.doctorInstallTargetPicker) {
        NSURL *doctoredURL = self.doctorInstallPendingDoctoredURL;
        NSString *entryPath = self.doctorInstallPendingEntryPath;
        NSString *folderName = self.doctorInstallPendingFolderName;
        self.doctorInstallPendingDoctoredURL = nil;
        self.doctorInstallPendingEntryPath = nil;
        self.doctorInstallPendingFolderName = nil;
        if (doctoredURL && entryPath && folderName) {
            [self zs_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:urls.firstObject entryPath:entryPath inFolder:folderName];
        }
        return;
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (controller == self.libraryImportPicker) {
        self.libraryImportTargetFolder = nil;
    }
    if (controller == self.doctorInstallTargetPicker) {
        NSString *entryPath = self.doctorInstallPendingEntryPath;
        NSString *folderName = self.doctorInstallPendingFolderName;
        self.doctorInstallPendingDoctoredURL = nil;
        self.doctorInstallPendingEntryPath = nil;
        self.doctorInstallPendingFolderName = nil;
        if (entryPath && folderName) {
            [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
                [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                     code:ZTranscoderInstallerErrorNoInstallTarget
                                 userInfo:@{NSLocalizedDescriptionKey: @"Cancelled - no stock bundle was picked to install into."}]];
        }
    }
}

- (void)zs_handleLoadModsPickedZipURLs:(NSArray<NSURL *> *)zipURLs intoFolder:(NSString *)folderName summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    for (NSURL *zipURL in zipURLs) {
        BOOL accessing = [zipURL startAccessingSecurityScopedResource];
        NSError *formatErr = nil;
        BOOL isLunartique = [LunartiqueModArchive isLunartiqueFormatZipAtURL:zipURL error:&formatErr];
        if (!isLunartique) {
            if (accessing) [zipURL stopAccessingSecurityScopedResource];
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - unknown file, it's neither a Lunartique mod nor a localization pack", zipURL.lastPathComponent]];
            continue;
        }

        NSError *importErr = nil;
        NSArray<NSString *> *rejectedEntryLines = nil;
        BOOL imported = [ModAssetLibrary importLunartiqueZipURL:zipURL intoFolder:folderName rejectedEntryLines:&rejectedEntryLines error:&importErr];
        if (accessing) [zipURL stopAccessingSecurityScopedResource];

        if (rejectedEntryLines.count > 0) {
            [summaryLines addObjectsFromArray:rejectedEntryLines];
        }

        if (imported) {
            [summaryLines addObject:zs_asset_imported_line(zipURL.lastPathComponent)];
        } else if (rejectedEntryLines.count == 0) {

            [summaryLines addObject:[NSString stringWithFormat:@"%@: Lunartique format matched, but import failed - %@", zipURL.lastPathComponent, importErr.localizedDescription ?: @"unknown error"]];
        }
    }
}

- (void)zs_handleLoadModsPickedCarra2URLs:(NSArray<NSURL *> *)carra2URLs intoFolder:(NSString *)folderName summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    for (NSURL *carra2URL in carra2URLs) {
        NSError *importErr = nil;
        BOOL imported = [ModAssetLibrary importCarra2URL:carra2URL intoFolder:folderName error:&importErr];
        if (imported) {
            [summaryLines addObject:zs_asset_imported_line(carra2URL.lastPathComponent)];
        } else {
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - %@", carra2URL.lastPathComponent, importErr.localizedDescription ?: @"doesn't match the Carra2 mod format"]];
        }
    }
}

- (BOOL)zs_urlIsDirectory:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    BOOL isDirectory = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDirectory];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return exists && isDirectory;
}

- (BOOL)zs_isLocalizationPackFolderURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    BOOL isPack = [LocalizationTransplant isTranslationPackDirectoryAtPath:url.path];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return isPack;
}

- (BOOL)zs_isLocalizationPackZipURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSArray<NSString *> *names = [LunartiqueModArchive allEntryNamesInZipAtURL:url error:nil];
    if (accessing) [url stopAccessingSecurityScopedResource];
    if (names.count == 0) return NO;
    return [LocalizationTransplant packRootFolderNameForArchiveEntryNames:names] != nil;
}

- (nullable NSString *)zs_detectedLocalizationLanguageForFolderURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSString *language = [LocalizationTransplant detectedLanguageForPackDirectoryAtPath:url.path];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return language;
}

- (nullable NSString *)zs_detectedLocalizationLanguageForZipURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSArray<NSString *> *names = [LunartiqueModArchive allEntryNamesInZipAtURL:url error:nil];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return names ? [LocalizationTransplant detectedLanguageForArchiveEntryNames:names] : nil;
}

- (void)zs_promptLocalizationLanguageQueue:(NSMutableArray<NSDictionary *> *)queue
                                      jobs:(NSMutableArray<NSDictionary *> *)jobs
                              summaryLines:(NSMutableArray<NSString *> *)summaryLines
                                completion:(void (^)(NSArray<NSDictionary *> *jobs))completion {
    if (queue.count == 0) {
        completion(jobs);
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        completion(jobs);
        return;
    }

    NSDictionary *item = queue.firstObject;
    [queue removeObjectAtIndex:0];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Language Folder"
                                                                    message:item[@"message"]
                                                             preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (NSString *code in [LocalizationTransplant languageCodes]) {
        [alert addAction:[UIAlertAction actionWithTitle:code style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSMutableDictionary *job = [item mutableCopy];
            job[@"language"] = code;
            [jobs addObject:job];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf zs_promptLocalizationLanguageQueue:queue jobs:jobs summaryLines:summaryLines completion:completion];
            });
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [summaryLines addObject:[NSString stringWithFormat:@"%@: cancelled", item[@"name"]]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf zs_promptLocalizationLanguageQueue:queue jobs:jobs summaryLines:summaryLines completion:completion];
        });
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_promptFontRoleQueue:(NSMutableArray<NSURL *> *)queue
                    validURLs:(NSMutableArray<NSURL *> *)validURLs
                    fontRoles:(NSMutableDictionary<NSString *, NSNumber *> *)fontRoles
                 summaryLines:(NSMutableArray<NSString *> *)summaryLines
                   completion:(void (^)(void))completion {
    if (queue.count == 0) {
        completion();
        return;
    }

    NSURL *url = queue.firstObject;
    [queue removeObjectAtIndex:0];

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        zs_drop_font_from_import(url, @"cancelled", validURLs, summaryLines);
        [self zs_promptFontRoleQueue:queue validURLs:validURLs fontRoles:fontRoles summaryLines:summaryLines completion:completion];
        return;
    }

    static const ZSFontRole kRoles[] = { ZSFontRoleTitle, ZSFontRoleContext, ZSFontRoleKanjiHanzi };
    NSMutableArray<NSNumber *> *freeRoles = [NSMutableArray array];
    NSMutableArray<NSString *> *takenLines = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kRoles) / sizeof(kRoles[0]); i++) {
        ZSFontRole role = kRoles[i];
        NSString *occupantName = nil;
        ModAssetLibraryEntry *occupant = [ModAssetLibrary fontEntryOccupyingRole:role];
        if (occupant) {
            occupantName = [ModAssetLibrary displayNameForEntry:occupant];
        } else {
            for (NSString *claimedPath in fontRoles) {
                if (fontRoles[claimedPath].integerValue == role) {
                    occupantName = claimedPath.lastPathComponent;
                    break;
                }
            }
        }
        if (occupantName) {
            [takenLines addObject:[NSString stringWithFormat:@"%@: %@", [ZSModsPaths displayNameForFontRole:role], occupantName]];
        } else {
            [freeRoles addObject:@(role)];
        }
    }

    if (freeRoles.count == 0) {
        zs_drop_font_from_import(url, @"rejected - Title, Context and Kanji/Hanzi are all assigned, delete a font from the library to free one", validURLs, summaryLines);
        [self zs_promptFontRoleQueue:queue validURLs:validURLs fontRoles:fontRoles summaryLines:summaryLines completion:completion];
        return;
    }

    NSString *message = [NSString stringWithFormat:@"Which text should \u201C%@\u201D be used for?", url.lastPathComponent];
    if (takenLines.count > 0) {
        message = [message stringByAppendingFormat:@"\n\nAlready assigned:\n%@", [takenLines componentsJoinedByString:@"\n"]];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Assign Font"
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (size_t i = 0; i < sizeof(kRoles) / sizeof(kRoles[0]); i++) {
        ZSFontRole role = kRoles[i];
        UIAlertAction *action = [UIAlertAction actionWithTitle:[ZSModsPaths displayNameForFontRole:role]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *chosen) {
            fontRoles[url.path] = @(role);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf zs_promptFontRoleQueue:queue validURLs:validURLs fontRoles:fontRoles summaryLines:summaryLines completion:completion];
            });
        }];
        action.enabled = [freeRoles containsObject:@(role)];
        [alert addAction:action];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *chosen) {
        zs_drop_font_from_import(url, @"cancelled", validURLs, summaryLines);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf zs_promptFontRoleQueue:queue validURLs:validURLs fontRoles:fontRoles summaryLines:summaryLines completion:completion];
        });
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_handleLoadModsPickedURLs:(NSArray<NSURL *> *)urls intoFolder:(NSString *)folderName {
    if (urls.count == 0) return;

    NSMutableArray<NSURL *> *validURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *fontURLs = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *fontRoles = [NSMutableDictionary dictionary];
    NSMutableArray<NSURL *> *bankURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *zipURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *carra2URLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *localizationJSONURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *localizationFolderURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *localizationZipURLs = [NSMutableArray array];
    NSMutableArray<NSString *> *summaryLines = [NSMutableArray array];
    NSMutableSet<NSString *> *acceptedBankNames = [NSMutableSet set];

    for (NSURL *url in urls) {
        if ([url.pathExtension caseInsensitiveCompare:@"zip"] == NSOrderedSame) {
            if ([self zs_isLocalizationPackZipURL:url]) {
                [localizationZipURLs addObject:url];
            } else {
                [zipURLs addObject:url];
            }
        } else if ([url.pathExtension caseInsensitiveCompare:@"carra2"] == NSOrderedSame) {
            [carra2URLs addObject:url];
        } else if ([url.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) {
            NSString *bankKey = url.lastPathComponent.lowercaseString;
            ModAssetLibraryEntry *overlappingBank = [ModAssetLibrary activeEntryOverlappingBankNamed:url.lastPathComponent];
            if (overlappingBank) {
                [summaryLines addObject:[ModAssetLibrary overlapRejectionLineForName:url.lastPathComponent existingEntry:overlappingBank]];
            } else if ([acceptedBankNames containsObject:bankKey]) {
                [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - it points to the %@ as another bank in this batch",
                                         url.lastPathComponent, ModAssetLibraryOverlapPhrase]];
            } else {
                [acceptedBankNames addObject:bankKey];
                [bankURLs addObject:url];
                [validURLs addObject:url];
            }
        } else if ([self zs_urlIsDirectory:url]) {
            if ([self zs_isLocalizationPackFolderURL:url]) {
                [localizationFolderURLs addObject:url];
            } else {
                [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - unknown folder, it doesn't look like a localization pack", url.lastPathComponent]];
            }
        } else if ([url.pathExtension caseInsensitiveCompare:@"json"] == NSOrderedSame) {
            if ([LocalizationTransplant isLocalizationJSONAtURL:url]) {
                [localizationJSONURLs addObject:url];
            } else {
                [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - not a localization .json file (it must start with dataList)", url.lastPathComponent]];
            }
        } else if ([ZSModsPaths fontKindForFileName:url.lastPathComponent] != ZSFontKindUnknown) {

            [validURLs addObject:url];
            [fontURLs addObject:url];
            [summaryLines addObject:zs_asset_imported_line(url.lastPathComponent)];
        } else if ([self zs_isRecognizedBundleURL:url]) {

            [validURLs addObject:url];
            [summaryLines addObject:zs_asset_imported_line(url.lastPathComponent)];
        } else {

            [summaryLines addObject:[NSString stringWithFormat:@"%@: not a recognized asset", url.lastPathComponent]];
        }
    }

    self.loadModsSummaryLines = summaryLines;

    NSMutableArray<NSDictionary *> *promptQueue = [NSMutableArray array];
    if (localizationJSONURLs.count > 0) {
        NSUInteger count = localizationJSONURLs.count;
        [promptQueue addObject:@{
            @"type": @"json",
            @"urls": [localizationJSONURLs copy],
            @"name": count == 1 ? localizationJSONURLs.firstObject.lastPathComponent
                                : [NSString stringWithFormat:@"%lu localization .json files", (unsigned long)count],
            @"message": count == 1
                ? [NSString stringWithFormat:@"Which language folder should \u201C%@\u201D go into?", localizationJSONURLs.firstObject.lastPathComponent]
                : [NSString stringWithFormat:@"Which language folder should these %lu .json files go into?", (unsigned long)count],
        }];
    }
    NSMutableArray<NSDictionary *> *autoJobs = [NSMutableArray array];
    for (NSURL *folderURL in localizationFolderURLs) {
        NSString *detected = [self zs_detectedLocalizationLanguageForFolderURL:folderURL];
        NSMutableDictionary *item = [@{
            @"type": @"folder",
            @"url": folderURL,
            @"name": folderURL.lastPathComponent,
            @"message": [NSString stringWithFormat:@"\u201C%@\u201D has no language prefix in its .json files. Which language folder should it replace? The prefix will be added to every .json file.", folderURL.lastPathComponent],
        } mutableCopy];
        if (detected) {
            item[@"language"] = detected;
            [autoJobs addObject:item];
        } else {
            [promptQueue addObject:item];
        }
    }
    for (NSURL *zipURL in localizationZipURLs) {
        NSString *detected = [self zs_detectedLocalizationLanguageForZipURL:zipURL];
        NSMutableDictionary *item = [@{
            @"type": @"zip",
            @"url": zipURL,
            @"name": zipURL.lastPathComponent,
            @"message": [NSString stringWithFormat:@"\u201C%@\u201D has no language prefix in its .json files. Which language folder should it replace? The prefix will be added to every .json file.", zipURL.lastPathComponent],
        } mutableCopy];
        if (detected) {
            item[@"language"] = detected;
            [autoJobs addObject:item];
        } else {
            [promptQueue addObject:item];
        }
    }

    __weak typeof(self) weakSelf = self;
    [self zs_promptFontRoleQueue:fontURLs
                       validURLs:validURLs
                       fontRoles:fontRoles
                    summaryLines:summaryLines
                      completion:^{
        [weakSelf zs_promptLocalizationLanguageQueue:promptQueue
                                                jobs:autoJobs
                                        summaryLines:summaryLines
                                          completion:^(NSArray<NSDictionary *> *localizationJobs) {
            [weakSelf zs_runLoadModsImportWithValidURLs:validURLs
                                               bankURLs:bankURLs
                                                zipURLs:zipURLs
                                             carra2URLs:carra2URLs
                                       localizationJobs:localizationJobs
                                             fontRoles:fontRoles
                                             intoFolder:folderName
                                           summaryLines:summaryLines];
        }];
    }];
}

- (void)zs_runLoadModsImportWithValidURLs:(NSArray<NSURL *> *)validURLs
                                 bankURLs:(NSArray<NSURL *> *)bankURLs
                                  zipURLs:(NSArray<NSURL *> *)zipURLs
                               carra2URLs:(NSArray<NSURL *> *)carra2URLs
                         localizationJobs:(NSArray<NSDictionary *> *)localizationJobs
                                fontRoles:(NSDictionary<NSString *, NSNumber *> *)fontRoles
                               intoFolder:(NSString *)folderName
                             summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    self.loadModsSummaryLines = summaryLines;

    if (validURLs.count == 0 && zipURLs.count == 0 && carra2URLs.count == 0 && localizationJobs.count == 0) {
        [self zs_processLoadModsBankURLs:bankURLs];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    UIAlertController *indexing = [UIAlertController alertControllerWithTitle:@"Indexing\u2026"
                                                                        message:@"Assets are being indexed."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [indexing.view addSubview:spinner];
    [spinner startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:indexing.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:indexing.view.bottomAnchor constant:-16],
    ]];
    if (presenter) [presenter presentViewController:indexing animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (validURLs.count > 0) {
            NSError *importError = nil;
            NSArray<NSString *> *rejectedFileLines = nil;
            BOOL imported = [ModAssetLibrary importFileURLs:validURLs intoFolder:folderName fontRoles:fontRoles rejectedFileLines:&rejectedFileLines error:&importError];
            if (!imported && rejectedFileLines.count == 0) {
                ZLog(@"[Mods] couldn't add picked files to Mod Asset Library folder \"%@\": %@", folderName, importError);
            }

            for (NSString *rejectedLine in rejectedFileLines) {
                NSString *rejectedFileName = [[rejectedLine componentsSeparatedByString:@": rejected"] firstObject];
                NSUInteger existingIdx = [summaryLines indexOfObjectPassingTest:^BOOL(NSString *line, NSUInteger idx, BOOL *stop) {
                    return [line hasPrefix:[rejectedFileName stringByAppendingString:@": "]] || [line isEqualToString:zs_asset_imported_line(rejectedFileName)];
                }];
                if (existingIdx != NSNotFound) {
                    summaryLines[existingIdx] = rejectedLine;
                } else {
                    [summaryLines addObject:rejectedLine];
                }
            }
        }
        if (zipURLs.count > 0) {
            [self zs_handleLoadModsPickedZipURLs:zipURLs intoFolder:folderName summaryLines:summaryLines];
        }
        if (carra2URLs.count > 0) {
            [self zs_handleLoadModsPickedCarra2URLs:carra2URLs intoFolder:folderName summaryLines:summaryLines];
        }
        for (NSDictionary *job in localizationJobs) {
            NSString *type = job[@"type"];
            NSString *language = job[@"language"];
            if ([type isEqualToString:@"json"]) {
                [ModAssetLibrary importLocalizationJSONURLs:job[@"urls"] language:language intoFolder:folderName summaryLines:summaryLines];
            } else if ([type isEqualToString:@"folder"]) {
                [ModAssetLibrary importLocalizationPackFolderURL:job[@"url"] language:language intoFolder:folderName summaryLines:summaryLines];
            } else if ([type isEqualToString:@"zip"]) {
                [ModAssetLibrary importLocalizationPackZipURL:job[@"url"] language:language intoFolder:folderName summaryLines:summaryLines];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.loadModsSummaryLines = summaryLines;
            void (^afterDismiss)(void) = ^{
                [strongSelf zs_rebuildModsLibrary];
                [strongSelf zs_processLoadModsBankURLs:bankURLs];
            };
            if (indexing.presentingViewController) {
                [indexing dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

- (BOOL)zs_isRecognizedBundleURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    BOOL isBundle = [UnityBundleCAB isUnityFSBundleAtPath:url.path];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return isBundle;
}

- (void)zs_processLoadModsBankURLs:(NSArray<NSURL *> *)bankURLs {
    if (bankURLs.count == 0) {
        [self zs_presentLoadModsFinalSummary];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    UIAlertController *working = [UIAlertController alertControllerWithTitle:@"Swapping Files\u2026"
                                                                       message:@"Swapping modded files into the game's files."
                                                                preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [working.view addSubview:spinner];
    [spinner startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:working.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:working.view.bottomAnchor constant:-16],
    ]];
    if (presenter) [presenter presentViewController:working animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *lines = [NSMutableArray array];

        for (NSURL *url in bankURLs) {
            NSError *bankErr = nil;
            BOOL ok = [BankTransplant transplantAndSwapModdedBankAtURL:url error:&bankErr];
            if (ok) {
                [lines addObject:[NSString stringWithFormat:@"%@: swapped", url.lastPathComponent]];
            } else {
                [lines addObject:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent, bankErr.localizedDescription ?: @"failed"]];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            void (^afterDismiss)(void) = ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf.loadModsSummaryLines addObjectsFromArray:lines];
                [strongSelf zs_presentLoadModsFinalSummary];
            };
            if (working.presentingViewController) {
                [working dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

- (void)restoreOriginalsTapped {
    [self zs_performRestoreOriginalsForce:NO];
}

- (void)zs_forceRestoreOriginalsTapped {
    [self zs_performRestoreOriginalsForce:YES];
}

- (void)zs_performRestoreOriginalsForce:(BOOL)force {
    NSError *bankError = nil;
    NSInteger banksRestored = [BankTransplant restoreAllBackedUpBanksForce:force error:&bankError];

    NSError *bundleError = nil;
    NSInteger bundlesRestored = [ZTranscoderInstaller restoreAllBackedUpBundlesForce:force error:&bundleError];

    NSError *localizationError = nil;
    NSInteger localizationRestored = [LocalizationTransplant restoreAllBackupsForce:force error:&localizationError];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];

    if (banksRestored < 0 || bundlesRestored < 0 || localizationRestored < 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        NSString *reason = bankError.localizedDescription ?: bundleError.localizedDescription ?: @"Unknown error.";
        ZLog(@"[BankTransplant] Restore Originals (force=%d) failed: %@", force, reason);
        [self zs_presentModsAlertWithTitle:@"Restore Failed" message:reason];
        return;
    }

    if (banksRestored == 0 && bundlesRestored == 0 && localizationRestored == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        if (force) {

            [self zs_presentModsAlertWithTitle:@"Nothing to Restore" message:@"No backed-up banks, bundles or localization files found."];
        } else {
            [self zs_presentRestoreNothingToRestoreAlertWithForceOption];
        }
        return;
    }

    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (banksRestored > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld bank%@", (long)banksRestored, banksRestored == 1 ? @"" : @"s"]];
    }
    if (bundlesRestored > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld bundle%@", (long)bundlesRestored, bundlesRestored == 1 ? @"" : @"s"]];
    }
    if (localizationRestored > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld localization item%@", (long)localizationRestored, localizationRestored == 1 ? @"" : @"s"]];
    }
    NSString *message = [NSString stringWithFormat:
        @"Restored %@ to their original state. Restart the game for it to take effect.",
        [parts componentsJoinedByString:@" and "]];
    ZLog(@"[BankTransplant] Restore Originals (force=%d): %ld bank(s), %ld bundle(s), %ld localization item(s) restored.", force, (long)banksRestored, (long)bundlesRestored, (long)localizationRestored);
    [self zs_presentModsAlertWithTitle:@"Restore Originals" message:message offersRestart:YES];
}

- (void)zs_presentRestoreNothingToRestoreAlertWithForceOption {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[BankTransplant] Nothing to Restore: every backed-up bank/bundle already matches its backup.");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Nothing to Restore"
                                                                     message:@"No modded assets were found in the game's files to restore."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Force Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_forceRestoreOriginalsTapped];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark Mods (doctor pipeline)

static const NSTimeInterval kZSDoctorProgressMinUpdateInterval = 0.08;
static const NSTimeInterval kZSDoctorDownloadProgressPersistInterval = 1.0;

static NSString *zs_mods_folder_name_for_entry(ModAssetLibraryEntry *entry) {

    if (entry.currentFolder.length > 0) return entry.currentFolder;

    NSString *root = [ModAssetLibrary modLibraryRootDirectory];
    NSString *path = entry.path;
    if (root.length > 0 && [path hasPrefix:root]) {
        NSString *relative = [path substringFromIndex:root.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        NSString *first = relative.pathComponents.firstObject;
        if (first.length > 0) return first;
    }

    return path.stringByDeletingLastPathComponent.lastPathComponent;
}

static ModAssetLibraryEntry *zs_mods_entry_placeholder_for_path(NSString *path) {
    ModAssetLibraryEntry *placeholder = [ModAssetLibraryEntry new];
    placeholder.path = path;
    return placeholder;
}

static const NSTimeInterval kDoctorPollInterval = 6.0;

- (void)zs_modsLibraryEntryDispatchTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;
    NSString *folderName = zs_mods_folder_name_for_entry(entry);
    if (!folderName) {
        ZLog(@"[Mods Library] Dispatch tapped for %@ but couldn't derive its owning folder from its path (%@) - not proceeding.", entry.fileName, entry.path);
        return;
    }

    [self zs_doctorStartOrInstallForEntry:entry folderName:folderName previousScratchBranch:entry.doctorScratchBranch];
}

- (void)zs_doctorStartOrInstallForEntry:(ModAssetLibraryEntry *)entry folderName:(NSString *)folderName previousScratchBranch:(nullable NSString *)previousScratchBranch {
    if (entry.targetPlatform && entry.targetPlatform.intValue == 9) {
        if (!self.doctorDownloadInFlightPaths) self.doctorDownloadInFlightPaths = [NSMutableSet set];
        if ([self.doctorDownloadInFlightPaths containsObject:entry.path]) {
            ZLog(@"[Mods Library] doctor install for %@ already in flight, ignoring duplicate tap.", entry.fileName);
            return;
        }
        [self.doctorDownloadInFlightPaths addObject:entry.path];
        [self zs_rebuildModsLibrary];
        ZLog(@"[Mods Library] %@ already has a known target platform, installing directly without re-dispatching.", entry.fileName);
        [self zs_doctorInstallUsingKnownTargetForDoctoredURL:[NSURL fileURLWithPath:entry.path]
                                                entryPath:entry.path
                                                 inFolder:folderName];
        return;
    }

    [self zs_doctorBeginDispatchForEntry:entry folderName:folderName previousScratchBranch:previousScratchBranch];
}

- (void)zs_doctorBeginDispatchForEntry:(ModAssetLibraryEntry *)entry folderName:(NSString *)folderName previousScratchBranch:(nullable NSString *)previousScratchBranch {

    if (self.authCredentialsStale) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        ZLog(@"[Mods Library] dispatch for %@ blocked: auth credentials are stale.", entry.fileName);
        return;
    }

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        ZLog(@"[Mods Library] dispatch for %@ blocked: auth not configured (repo/owner/token missing).", entry.fileName);
        [self zs_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first."];
        return;
    }

    NSString *entryPath = entry.path;
    [self.doctorUploadProgressLastUpdate removeObjectForKey:entryPath];
    [self.doctorProcessProgressLastPercent removeObjectForKey:entryPath];

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusUploading;
        entryToMutate.doctorUploadProgress = 0;
        entryToMutate.doctorProcessProgress = 0.0;
        entryToMutate.doctorLastError = nil;
        entryToMutate.doctorTranscodeCodec = config.outputFormat.length > 0 ? config.outputFormat : kZSDefaultReencodeFormat;
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't flip %@ to Uploading: %@", entry.fileName, stateError);
        return;
    }
    [self zs_rebuildModsLibrary];

    ZLog(@"[Mods Library] dispatching %@ (folder=%@, resuming scratch branch=%@).", entryPath.lastPathComponent, folderName, previousScratchBranch ?: @"none");
    NSURL *bundleURL = [NSURL fileURLWithPath:entryPath];
    NSString *carra2Hash1 = entry.isAssetBundle ? nil : entry.zipCacheHash1;
    NSString *carra2Hash2 = entry.isAssetBundle ? nil : entry.zipCacheHash2;
    __weak typeof(self) weakSelf = self;
    [ZTranscoderService dispatchBundleAtURL:bundleURL
                                   carra2Hash1:carra2Hash1
                                   carra2Hash2:carra2Hash2
                                        config:config
                         previousScratchBranch:previousScratchBranch
                                uploadProgress:^(int64_t bytesSent, int64_t totalBytesExpected) {
        [weakSelf zs_doctorHandleUploadProgress:bytesSent totalBytesExpected:totalBytesExpected forEntryPath:entryPath inFolder:folderName];
    }
                                    completion:^(ZTranscoderHandle * _Nullable handle, NSError * _Nullable error) {
        [weakSelf zs_doctorDispatchCompletedForEntryPath:entryPath inFolder:folderName handle:handle error:error];
    }];
}

- (void)zs_modsLibraryEntryRetryTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;
    NSString *folderName = zs_mods_folder_name_for_entry(entry);
    if (!folderName) return;

    [self zs_stopDoctorPollTimerForEntryPath:entry.path];
    [self.doctorUploadProgressLastUpdate removeObjectForKey:entry.path];
    [self.doctorProcessProgressLastPercent removeObjectForKey:entry.path];

    NSString *previousScratchBranch = entry.doctorScratchBranch;

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusNotDispatched;
        entryToMutate.doctorUploadProgress = 0;
        entryToMutate.doctorProcessProgress = 0.0;
        entryToMutate.doctorScratchBranch = nil;
        entryToMutate.doctorRunID = nil;
        entryToMutate.doctorRunURL = nil;
        entryToMutate.doctorLastError = nil;
    }
                                                                           error:&error];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't reset %@ back to NotDispatched: %@", entry.fileName, error);
        return;
    }

    ZLog(@"[Mods Library] retrying %@, previous scratch branch=%@.", entry.fileName, previousScratchBranch ?: @"none");
    [self zs_doctorStartOrInstallForEntry:updated folderName:folderName previousScratchBranch:previousScratchBranch];
}

- (BOOL)zs_updateDoctorProgressLabelForEntry:(ModAssetLibraryEntry *)entry downloadInFlight:(BOOL)downloadInFlight {
    if (!self.modsLibraryStack) return NO;
    for (UIView *view in self.modsLibraryStack.arrangedSubviews) {
        ModAssetLibraryEntry *viewEntry = objc_getAssociatedObject(view, "zs_modsEntry");
        if (![viewEntry.path isEqualToString:entry.path]) continue;
        UILabel *statusLabel = objc_getAssociatedObject(view, "zs_label_doctorStatus");
        if (!statusLabel) continue;
        NSString *statusText = zs_doctor_status_text_for_entry(entry, downloadInFlight, NO);
        statusLabel.text = [NSString stringWithFormat:@"Status: %@", statusText];
        return YES;
    }
    return NO;
}

- (void)zs_doctorHandleUploadProgress:(int64_t)bytesSent totalBytesExpected:(int64_t)totalBytesExpected forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (!self.doctorUploadProgressLastUpdate) self.doctorUploadProgressLastUpdate = [NSMutableDictionary dictionary];
    NSNumber *last = self.doctorUploadProgressLastUpdate[entryPath];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL isFinal = totalBytesExpected > 0 && bytesSent >= totalBytesExpected;
    if (last && !isFinal && (now - last.doubleValue) < kZSDoctorProgressMinUpdateInterval) return;
    self.doctorUploadProgressLastUpdate[entryPath] = @(now);

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorUploadProgress = bytesSent;
        entryToMutate.doctorUploadTotalBytes = totalBytesExpected;
    }
                                                                           error:&error];
    if (!updated) return;
    if (![self zs_updateDoctorProgressLabelForEntry:updated downloadInFlight:NO]) {
        [self zs_rebuildModsLibrary];
    }
}

- (void)zs_doctorDispatchCompletedForEntryPath:(NSString *)entryPath
                                        inFolder:(NSString *)folderName
                                          handle:(ZTranscoderHandle *)handle
                                           error:(NSError *)error {
    [self.doctorUploadProgressLastUpdate removeObjectForKey:entryPath];

    if (!handle) {
        [self zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
        return;
    }

    if (handle.alreadyComplete) {
        NSError *stateError = nil;
        ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                            inFolder:folderName
                                                                          applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
            entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusReadyToDownload;

            entryToMutate.doctorProcessProgress = 1.0;
            entryToMutate.doctorScratchBranch = handle.scratchBranch;
            entryToMutate.doctorRunID = nil;
            entryToMutate.doctorRunURL = nil;
            entryToMutate.doctorDispatchCompressedByteSize = handle.compressedByteSize;
        }
                                                                               error:&stateError];
        if (!updated) {
            ZLog(@"[Mods Library] cache-hit dispatch finished for %@ but its manifest entry is gone (deleted mid-upload?).", entryPath.lastPathComponent);
            return;
        }
        ZLog(@"[Mods Library] %@ was a cache hit, ready to download immediately (scratch branch=%@).", entryPath.lastPathComponent, handle.scratchBranch);
        [self zs_rebuildModsLibrary];
        return;
    }

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusProcessing;

        entryToMutate.doctorProcessProgress = 0.0;
        entryToMutate.doctorScratchBranch = handle.scratchBranch;
        entryToMutate.doctorRunID = handle.runID;
        entryToMutate.doctorRunURL = handle.runURL;
        entryToMutate.doctorDispatchCompressedByteSize = handle.compressedByteSize;
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] dispatch finished for %@ but its manifest entry is gone (deleted mid-upload?) - not arming a poll timer.", entryPath.lastPathComponent);
        return;
    }
    ZLog(@"[Mods Library] %@ uploaded, now processing (run=%@, scratch branch=%@) - arming poll timer.", entryPath.lastPathComponent, handle.runID, handle.scratchBranch);
    [self zs_rebuildModsLibrary];
    [self zs_armDoctorPollTimerForEntryPath:entryPath inFolder:folderName];
}

- (void)zs_doctorFailEntryAtPath:(NSString *)entryPath inFolder:(NSString *)folderName error:(NSError *)error {
    [self zs_stopDoctorPollTimerForEntryPath:entryPath];

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusFailed;
        entryToMutate.doctorLastError = error.localizedDescription ?: @"Unknown error.";
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't record doctor failure for %@ (entry deleted mid-flight?): %@", entryPath.lastPathComponent, stateError);
        return;
    }
    ZLog(@"[Mods Library] %@ doctor pipeline failed: %@", entryPath.lastPathComponent, error.localizedDescription ?: @"Unknown error.");
    [self zs_rebuildModsLibrary];
}

#pragma mark Mods (doctor pipeline) - 6s poll loop

- (void)zs_armDoctorPollTimerForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    ZLog(@"[Mods Library] arming %.0fs doctor poll timer for %@.", kDoctorPollInterval, entryPath.lastPathComponent);
    if (!self.doctorPollTimers) self.doctorPollTimers = [NSMutableDictionary dictionary];
    [self.doctorPollTimers[entryPath] invalidate];

    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:kDoctorPollInterval
                                              repeats:YES
                                                block:^(NSTimer *timer) {
        [weakSelf zs_pollDoctorRunForEntryPath:entryPath inFolder:folderName];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.doctorPollTimers[entryPath] = timer;

    [self zs_pollDoctorRunForEntryPath:entryPath inFolder:folderName];
}

- (void)zs_stopDoctorPollTimerForEntryPath:(NSString *)entryPath {
    NSTimer *timer = self.doctorPollTimers[entryPath];
    if (timer) ZLog(@"[Mods Library] stopping doctor poll timer for %@.", entryPath.lastPathComponent);
    [timer invalidate];
    [self.doctorPollTimers removeObjectForKey:entryPath];
}

- (void)zs_pollAllActiveDoctorEntriesImmediately {
    for (NSString *entryPath in self.doctorPollTimers.allKeys) {
        NSString *folderName = zs_mods_folder_name_for_entry(zs_mods_entry_placeholder_for_path(entryPath));
        [self zs_pollDoctorRunForEntryPath:entryPath inFolder:folderName];
    }
}

- (void)zs_pollDoctorRunForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSError *readError = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&readError];
    ModAssetLibraryEntry *current = nil;
    for (ModAssetLibraryEntry *candidate in entries) {
        if ([candidate.path isEqualToString:entryPath]) { current = candidate; break; }
    }
    if (!current || current.doctorStatus != ModAssetLibraryDoctorStatusProcessing) {
        ZLog(@"[Mods Library] poll for %@ found it no longer Processing (status changed or entry deleted), stopping timer.", entryPath.lastPathComponent);
        [self zs_stopDoctorPollTimerForEntryPath:entryPath];
        return;
    }

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                 code:ZTranscoderServiceErrorInvalidConfig
                             userInfo:@{NSLocalizedDescriptionKey: @"GitHub auth was cleared while this bundle was still processing."}]];
        return;
    }

    ZTranscoderHandle *handle = [ZTranscoderHandle handleFromDictionaryRepresentation:@{
        @"scratchBranch": current.doctorScratchBranch ?: @"",
        @"runID": current.doctorRunID ?: @"",
        @"runURL": current.doctorRunURL ?: @"",
    }];
    if (!handle) {
        [self zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderServiceErrorDomain
                                 code:ZTranscoderServiceErrorRunNotFound
                             userInfo:@{NSLocalizedDescriptionKey: @"Lost track of this submission's scratch branch."}]];
        return;
    }

    __weak typeof(self) weakSelf = self;
    if (current.doctorRunID.length == 0) {

        [ZTranscoderService resolveRunForHandle:handle config:config completion:^(BOOL found, NSError * _Nullable error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                [strongSelf zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
                return;
            }
            if (!found) return;
            ZLog(@"[Mods Library] storing resolved run %@ against %@.", handle.runID, entryPath.lastPathComponent);
            [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                inFolder:folderName
                                              applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                entryToMutate.doctorRunID = handle.runID;
                entryToMutate.doctorRunURL = handle.runURL;
            }
                                                   error:nil];
            [strongSelf zs_rebuildModsLibrary];
        }];
        return;
    }

    [ZTranscoderService fetchRunStatusForHandle:handle config:config completion:^(ZTranscoderRunStatus status, double percentComplete, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (status == ZTranscoderRunStatusFailed) {
            [strongSelf zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
            return;
        }
        if (status == ZTranscoderRunStatusSucceeded) {
            [strongSelf zs_stopDoctorPollTimerForEntryPath:entryPath];
            [strongSelf.doctorProcessProgressLastPercent removeObjectForKey:entryPath];
            NSError *stateError = nil;
            ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                                inFolder:folderName
                                                                              applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusReadyToDownload;
                entryToMutate.doctorProcessProgress = 1.0;
            }
                                                                                   error:&stateError];
            ZLog(@"[Mods Library] %@ finished processing, ready to download.", entryPath.lastPathComponent);
            if (updated) [strongSelf zs_rebuildModsLibrary];
            return;
        }

        [strongSelf zs_doctorHandleProcessProgress:percentComplete forEntryPath:entryPath inFolder:folderName];
    }];
}

- (void)zs_doctorHandleProcessProgress:(double)fractionComplete forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, fractionComplete)) * 100.0);
    if (!self.doctorProcessProgressLastPercent) self.doctorProcessProgressLastPercent = [NSMutableDictionary dictionary];
    NSNumber *last = self.doctorProcessProgressLastPercent[entryPath];
    if (last && last.integerValue == percent) return;
    self.doctorProcessProgressLastPercent[entryPath] = @(percent);

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorProcessProgress = fractionComplete;
    }
                                                                           error:&error];
    if (!updated) return;
    [self zs_rebuildModsLibrary];
}

- (void)zs_recoverStaleDoctorStateForThisLaunch {
    if (self.doctorStateRecoveredThisLaunch) return;
    self.doctorStateRecoveredThisLaunch = YES;

    NSInteger interruptedUploads = 0;
    NSInteger resumedPolls = 0;
    for (NSString *folderName in [ModAssetLibrary folderNames]) {
        NSError *error = nil;
        NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&error];
        for (ModAssetLibraryEntry *entry in entries) {
            if (entry.doctorStatus == ModAssetLibraryDoctorStatusUploading) {
                interruptedUploads++;
                [ModAssetLibrary updateDoctorStateForEntry:entry
                                                    inFolder:folderName
                                                  applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                    entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusFailed;
                    entryToMutate.doctorLastError = @"Upload was interrupted (the app was closed or backgrounded mid-upload). Tap Retry to send it again.";
                }
                                                       error:nil];
            } else if (entry.doctorStatus == ModAssetLibraryDoctorStatusProcessing) {
                if (!self.doctorPollTimers[entry.path]) {
                    resumedPolls++;
                    [self zs_armDoctorPollTimerForEntryPath:entry.path inFolder:folderName];
                }
            }
        }
    }
    if (interruptedUploads > 0 || resumedPolls > 0) {
        ZLog(@"[Mods Library] launch recovery: %ld interrupted upload(s) marked Failed, %ld Processing entr%@ resumed polling.",
             (long)interruptedUploads, (long)resumedPolls, resumedPolls == 1 ? @"y" : @"ies");
    }
}

- (void)zs_presentLoadModsFinalSummary {
    NSArray<NSString *> *lines = self.loadModsSummaryLines ?: @[];
    self.loadModsSummaryLines = nil;

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    if (lines.count == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        [self zs_presentModsAlertWithTitle:@"No Files Loaded" message:@"No files were submitted."];
        return;
    }

    NSMutableArray<NSString *> *overlapLines = [NSMutableArray array];
    NSMutableArray<NSString *> *summaryLines = [NSMutableArray array];
    for (NSString *line in lines) {
        if ([line containsString:ModAssetLibraryOverlapPhrase]) {
            [overlapLines addObject:line];
        } else {
            [summaryLines addObject:line];
        }
    }

    BOOL anySucceeded = NO;
    for (NSString *line in summaryLines) {
        if ([line rangeOfString:@": swapped"].location != NSNotFound || [line rangeOfString:@": installed"].location != NSNotFound) {
            anySucceeded = YES;
            break;
        }
    }

    __weak typeof(self) weakSelf = self;
    dispatch_block_t presentSummary = ^{
        if (summaryLines.count == 0) return;
        NSString *message = [summaryLines componentsJoinedByString:@"\n"];
        if (anySucceeded) {
            message = [message stringByAppendingString:@"\n\nRestart the game for swapped/installed files to take effect."];
        }
        [weakSelf zs_presentModsAlertWithTitle:@"Load Mods" message:message offersRestart:anySucceeded];
    };

    if (overlapLines.count > 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Mod Overlap"
                                    message:[overlapLines componentsJoinedByString:@"\n"]
                              offersRestart:NO
                             dismissHandler:presentSummary];
        return;
    }

    [haptic notificationOccurred:anySucceeded ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning];
    presentSummary();
}

- (void)zs_presentModsAlertWithTitle:(NSString *)title message:(NSString *)message {
    [self zs_presentModsAlertWithTitle:title message:message offersRestart:NO dismissHandler:nil];
}

- (void)zs_presentModsAlertWithTitle:(NSString *)title message:(NSString *)message offersRestart:(BOOL)offersRestart {
    [self zs_presentModsAlertWithTitle:title message:message offersRestart:offersRestart dismissHandler:nil];
}

- (void)zs_presentModsAlertWithTitle:(NSString *)title
                              message:(NSString *)message
                        offersRestart:(BOOL)offersRestart
                       dismissHandler:(nullable dispatch_block_t)dismissHandler {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[BankTransplant] %@: %@", title, message);
        if (dismissHandler) dismissHandler();
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (dismissHandler) dismissHandler();
    }]];
    if (offersRestart) zs_add_restart_action(alert);
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark Mods Library

- (void)zs_promptForModFolderNameWithTitle:(NSString *)title
                                actionTitle:(NSString *)actionTitle
                                 completion:(void (^)(NSString *trimmedName))completion {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:title
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Folder name";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *trimmed = [(prompt.textFields.firstObject.text ?: @"")
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) return;
        completion(trimmed);
    }]];
    [presenter presentViewController:prompt animated:YES completion:nil];
}

- (void)zs_rebuildModsLibrary {
    if (!self.modsLibraryStack) return;

    BOOL wasDropdownOpen = self.modsOptionsDropdownOpen;
    BOOL dropdownWasFolderMode = wasDropdownOpen && (self.modsOptionsDropdownEntry == nil);
    NSString *dropdownTargetFolderName = wasDropdownOpen ? self.modsOptionsDropdownFolderName : nil;
    NSString *dropdownTargetEntryPath = (wasDropdownOpen && !dropdownWasFolderMode) ? self.modsOptionsDropdownEntry.path : nil;

    [self zs_recoverStaleDoctorStateForThisLaunch];

    for (UIView *view in self.modsLibraryStack.arrangedSubviews) {

        UIButton *deleteButton = objc_getAssociatedObject(view, "zs_button_delete");
        if (deleteButton) {
            UIView *capsuleGlass = objc_getAssociatedObject(deleteButton, kZSHoldConfirmGlassViewKey);
            [capsuleGlass removeFromSuperview];
        }
        [self.modsLibraryStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSMutableArray<NSString *> *folders = [[ModAssetLibrary folderNames] mutableCopy];
    [folders removeObject:kZSStoredBundlesFolderName];
    if (folders.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No mod folders yet.";
        empty.font = zs_mono_font(11, UIFontWeightRegular);
        empty.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        [self.modsLibraryStack addArrangedSubview:empty];

    }

    for (NSString *folderName in folders) {
        BOOL expanded = [self.modsLibraryExpandedFolders containsObject:folderName];

        NSString *folderRemark = [ModAssetLibrary remarkForFolder:folderName];
        UIView *folderRow = zs_make_mods_folder_row(folderName, nil, folderRemark, expanded, self,
            @selector(zs_modsLibraryFolderRowTapped:),
            @selector(zs_modsLibraryFolderOptionsTapped:), 0);
        [self.modsLibraryStack addArrangedSubview:folderRow];

        if (!expanded) continue;

        NSError *error = nil;
        NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&error];
        if (!entries || entries.count == 0) {
            UILabel *emptyFolder = [[UILabel alloc] init];
            emptyFolder.text = @"  Empty.";
            emptyFolder.font = zs_mono_font(11, UIFontWeightRegular);
            emptyFolder.textColor = [UIColor colorWithWhite:1 alpha:0.4];
            [self.modsLibraryStack addArrangedSubview:emptyFolder];
            continue;
        }

        NSArray<ModAssetLibraryEntry *> *sortedEntries =
            [entries sortedArrayUsingComparator:^NSComparisonResult(ModAssetLibraryEntry *a, ModAssetLibraryEntry *b) {
                return [a.fileName localizedStandardCompare:b.fileName];
            }];

        for (ModAssetLibraryEntry *entry in sortedEntries) {
            BOOL entryExpanded = [self.modsLibraryExpandedInfoEntries containsObject:entry.path];

            UIView *entryRow = zs_make_mods_entry_row(entry, self,
                @selector(zs_modsLibraryEntryInfoTapped:),
                @selector(zs_modsLibraryEntryDispatchTapped:),
                @selector(zs_modsLibraryEntryDownloadTapped:),
                @selector(zs_modsLibraryEntryRetryTapped:),
                @selector(zs_modsLibraryEntryOptionsTapped:),
                entryExpanded,
                [self.doctorDownloadInFlightPaths containsObject:entry.path],
                NO, 0);
            [self.modsLibraryStack addArrangedSubview:entryRow];

            if (entryExpanded) {
                UIView *infoPanel = zs_make_mods_entry_info_panel(entry,
                    [self.doctorDownloadInFlightPaths containsObject:entry.path], NO);
                [self.modsLibraryStack addArrangedSubview:infoPanel];
            }
        }
    }

    NSError *storedError = nil;
    BOOL hasStoredBundlesFolder = [[ModAssetLibrary folderNames] containsObject:kZSStoredBundlesFolderName];
    NSArray<ModAssetLibraryEntry *> *storedEntries =
        hasStoredBundlesFolder ? [ModAssetLibrary entriesInFolder:kZSStoredBundlesFolderName error:&storedError] : nil;

    NSArray<NSString *> *cachedSubFolders =
        hasStoredBundlesFolder ? [ModAssetLibrary subFolderNamesInFolder:kZSStoredBundlesFolderName] : @[];

    void (^appendStoredEntryRows)(NSArray<ModAssetLibraryEntry *> *, NSInteger) = ^(NSArray<ModAssetLibraryEntry *> *entriesToShow, NSInteger indentLevel) {
        NSArray<ModAssetLibraryEntry *> *sorted =
            [entriesToShow sortedArrayUsingComparator:^NSComparisonResult(ModAssetLibraryEntry *a, ModAssetLibraryEntry *b) {
                return [a.fileName localizedStandardCompare:b.fileName];
            }];

        for (ModAssetLibraryEntry *entry in sorted) {
            BOOL entryExpanded = [self.modsLibraryExpandedInfoEntries containsObject:entry.path];

            UIView *entryRow = zs_make_mods_entry_row(entry, self,
                @selector(zs_modsLibraryEntryInfoTapped:),
                @selector(zs_modsLibraryEntryDispatchTapped:),
                @selector(zs_modsLibraryEntryDownloadTapped:),
                @selector(zs_modsLibraryEntryRetryTapped:),
                @selector(zs_modsLibraryEntryOptionsTapped:),
                entryExpanded,
                NO,
                YES, indentLevel);
            [self.modsLibraryStack addArrangedSubview:entryRow];

            if (entryExpanded) {
                UIView *infoPanel = zs_make_mods_entry_info_panel(entry, NO, YES);
                [self.modsLibraryStack addArrangedSubview:infoPanel];
            }
        }
    };

    if (storedEntries.count > 0 || cachedSubFolders.count > 0) {
        BOOL storedExpanded = [self.modsLibraryExpandedFolders containsObject:kZSStoredBundlesFolderName];
        UIView *storedFolderRow = zs_make_mods_folder_row(kZSStoredBundlesFolderName, nil,
            kZSStoredBundlesFolderSubtext, storedExpanded, self,
            @selector(zs_modsLibraryFolderRowTapped:), NULL, 0);
        [self.modsLibraryStack addArrangedSubview:storedFolderRow];

        if (storedExpanded) {
            appendStoredEntryRows(storedEntries, 0);

            for (NSString *cachedFolderName in cachedSubFolders) {
                BOOL cachedFolderExpanded = [self.modsLibraryExpandedFolders containsObject:cachedFolderName];
                NSError *cachedEntriesErr = nil;
                NSArray<ModAssetLibraryEntry *> *cachedFolderEntries =
                    [ModAssetLibrary entriesInFolder:cachedFolderName error:&cachedEntriesErr] ?: @[];

                UIView *cachedFolderRow = zs_make_mods_folder_row(cachedFolderName,
                    cachedFolderName.lastPathComponent, nil, cachedFolderExpanded, self,
                    @selector(zs_modsLibraryFolderRowTapped:), @selector(zs_modsLibraryFolderOptionsTapped:), 1);
                [self.modsLibraryStack addArrangedSubview:cachedFolderRow];

                if (cachedFolderExpanded) appendStoredEntryRows(cachedFolderEntries, 1);
            }
        }
    }

    if (wasDropdownOpen) {

        [self.contentOverlay layoutIfNeeded];

        UIButton *newButton = nil;
        ModAssetLibraryEntry *newEntry = nil;
        for (UIView *view in self.modsLibraryStack.arrangedSubviews) {
            if (dropdownWasFolderMode) {
                NSString *rowFolderName = objc_getAssociatedObject(view, "zs_modsFolderName");
                if (rowFolderName && [rowFolderName isEqualToString:dropdownTargetFolderName]) {
                    newButton = objc_getAssociatedObject(view, "zs_button_options");
                    break;
                }
            } else {
                ModAssetLibraryEntry *rowEntry = objc_getAssociatedObject(view, "zs_modsEntry");
                if (rowEntry && [rowEntry.path isEqualToString:dropdownTargetEntryPath]) {
                    newButton = objc_getAssociatedObject(view, "zs_button_options");
                    newEntry = rowEntry;
                    break;
                }
            }
        }

        if (newButton) {

            newButton.hidden = YES;
            self.modsOptionsDropdownButton = newButton;
            if (newEntry) self.modsOptionsDropdownEntry = newEntry;

            CGRect newButtonFrame = [newButton convertRect:newButton.bounds toView:self.contentOverlay];
            CGRect currentFrame = self.modsOptionsDropdownOverlay.frame;
            CGFloat dx = CGRectGetMaxX(newButtonFrame) - CGRectGetMaxX(currentFrame);
            CGFloat dy = CGRectGetMinY(newButtonFrame) - CGRectGetMinY(currentFrame);
            if (dx != 0 || dy != 0) {
                self.modsOptionsDropdownOverlay.frame = CGRectOffset(currentFrame, dx, dy);
            }
        } else {

            [self zs_closeModsOptionsDropdownAnimated:NO];
        }
    }
}

- (void)zs_modsLibraryFolderRowTapped:(UITapGestureRecognizer *)gesture {
    NSString *folderName = objc_getAssociatedObject(gesture.view, "zs_modsFolderName");
    if (!folderName) return;
    BOOL wasExpanded = [self.modsLibraryExpandedFolders containsObject:folderName];
    if (wasExpanded) {
        [self.modsLibraryExpandedFolders removeObject:folderName];
    } else {
        [self.modsLibraryExpandedFolders addObject:folderName];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_modsLibraryEntryInfoTapped:(UITapGestureRecognizer *)gesture {
    ModAssetLibraryEntry *entry = objc_getAssociatedObject(gesture.view, "zs_modsEntry");
    if (!entry) return;
    if ([self.modsLibraryExpandedInfoEntries containsObject:entry.path]) {
        [self.modsLibraryExpandedInfoEntries removeObject:entry.path];
    } else {
        [self.modsLibraryExpandedInfoEntries addObject:entry.path];
    }
    [self zs_rebuildModsLibrary];
}

#pragma mark Mods Library file options dropdown (3.4)

- (void)zs_modsLibraryEntryOptionsTapped:(UIButton *)sender {
    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;

    if (self.modsOptionsDropdownOpen && self.modsOptionsDropdownButton == sender) {
        [self zs_closeModsOptionsDropdownAnimated:YES];
        return;
    }
    if (self.modsOptionsDropdownOpen) {
        [self zs_closeModsOptionsDropdownAnimated:NO];
    }

    [self zs_openModsOptionsDropdownForButton:sender entry:entry folderName:zs_mods_folder_name_for_entry(entry)];
}

- (void)zs_modsLibraryFolderOptionsTapped:(UIButton *)sender {
    NSString *folderName = objc_getAssociatedObject(sender, "zs_modsFolderName");
    if (!folderName) return;

    if (self.modsOptionsDropdownOpen && self.modsOptionsDropdownButton == sender) {
        [self zs_closeModsOptionsDropdownAnimated:YES];
        return;
    }
    if (self.modsOptionsDropdownOpen) {
        [self zs_closeModsOptionsDropdownAnimated:NO];
    }

    [self zs_openModsOptionsDropdownForButton:sender entry:nil folderName:folderName];
}

- (void)zs_openModsOptionsDropdownForButton:(UIButton *)button entry:(nullable ModAssetLibraryEntry *)entry folderName:(NSString *)folderName {
    if (!button || !self.contentOverlay || self.modsOptionsDropdownOpen || !folderName) return;

    BOOL isStoredBundlesRow = entry && zs_mods_folder_is_or_within_stored_bundles(folderName);
    NSArray<NSDictionary<NSString *, id> *> *options = entry
        ? (isStoredBundlesRow ? zs_mods_stored_bundle_file_options() : zs_mods_file_options(entry))
        : zs_mods_options_for_folder(folderName);
    if (options.count == 0) return;

    CGRect buttonFrame = [button convertRect:button.bounds toView:self.contentOverlay];

    CGRect collapsedFrame = CGRectMake(CGRectGetMaxX(buttonFrame) - kZSModsOptionsDropdownWidth,
                                        CGRectGetMinY(buttonFrame),
                                        kZSModsOptionsDropdownWidth,
                                        CGRectGetHeight(buttonFrame));

    UIControl *scrim = [[UIControl alloc] initWithFrame:self.contentOverlay.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = UIColor.clearColor;
    [scrim addTarget:self action:@selector(zs_modsOptionsDropdownScrimTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentOverlay addSubview:scrim];
    self.modsOptionsDropdownScrim = scrim;

    UIView *overlay;
    UIVisualEffectView *glassOverlay = nil;
    if (zs_has_liquid_glass()) {

        glassOverlay = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(YES)];
        glassOverlay.frame = collapsedFrame;
        glassOverlay.clipsToBounds = YES;
        zs_configure_glass_corners(glassOverlay, kZSAuthFieldCornerRadius, NO);
        glassOverlay.layer.borderWidth = 1;
        glassOverlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        zs_register_suspendable_glass(glassOverlay);
        overlay = glassOverlay;
    } else {
        overlay = [[UIView alloc] initWithFrame:collapsedFrame];
        overlay.clipsToBounds = YES;
        overlay.layer.cornerRadius = kZSAuthFieldCornerRadius;
        overlay.layer.cornerCurve = kCACornerCurveContinuous;
        overlay.layer.borderWidth = 1;
        overlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        overlay.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.98];
    }
    [self.contentOverlay addSubview:overlay];
    self.modsOptionsDropdownOverlay = overlay;

    UIView *rowHost = glassOverlay ? glassOverlay.contentView : overlay;

    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        UIButton *rowButton = zs_make_mods_options_row_button(options[i], i, self,
                                                                @selector(zs_modsOptionsDropdownRowTapped:));
        rowButton.frame = CGRectMake(0, i * kZSModsOptionsRowHeight,
                                      kZSModsOptionsDropdownWidth, kZSModsOptionsRowHeight);
        rowButton.alpha = 0;
        [rowHost addSubview:rowButton];

        if (i > 0) {
            CGFloat hairline = 1.0 / MAX(UIScreen.mainScreen.scale, (CGFloat)1.0);
            UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, i * kZSModsOptionsRowHeight - hairline,
                                                                        kZSModsOptionsDropdownWidth, hairline)];
            divider.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.5];
            divider.alpha = 0;
            [rowHost addSubview:divider];
        }
    }

    button.hidden = YES;
    self.modsOptionsDropdownButton = button;
    self.modsOptionsDropdownEntry = entry;
    self.modsOptionsDropdownFolderName = folderName;
    self.modsOptionsDropdownOpen = YES;

    CGFloat expandedHeight = kZSModsOptionsRowHeight * options.count;
    CGRect expandedFrame = CGRectMake(CGRectGetMinX(collapsedFrame), CGRectGetMinY(collapsedFrame),
                                       kZSModsOptionsDropdownWidth, expandedHeight);
    [UIView animateWithDuration:0.22
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        overlay.frame = expandedFrame;
        for (UIView *subview in rowHost.subviews) {
            subview.alpha = 1;
        }
    } completion:nil];

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_closeModsOptionsDropdownAnimated:(BOOL)animated {
    if (!self.modsOptionsDropdownOpen) return;

    UIView *overlay = self.modsOptionsDropdownOverlay;
    UIControl *scrim = self.modsOptionsDropdownScrim;
    UIButton *button = self.modsOptionsDropdownButton;
    self.modsOptionsDropdownOverlay = nil;
    self.modsOptionsDropdownScrim = nil;
    self.modsOptionsDropdownButton = nil;
    self.modsOptionsDropdownEntry = nil;
    self.modsOptionsDropdownFolderName = nil;
    self.modsOptionsDropdownOpen = NO;

    if (!button || !button.superview) {
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
        return;
    }

    CGRect collapsedFrame = [button convertRect:button.bounds toView:self.contentOverlay];
    CGRect collapsedDropdownFrame = CGRectMake(CGRectGetMaxX(collapsedFrame) - kZSModsOptionsDropdownWidth,
                                                CGRectGetMinY(collapsedFrame),
                                                kZSModsOptionsDropdownWidth,
                                                CGRectGetHeight(collapsedFrame));

    void (^finish)(void) = ^{
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
        button.hidden = NO;
    };

    if (!animated) {
        finish();
        return;
    }

    UIView *rowHost = [overlay isKindOfClass:[UIVisualEffectView class]]
        ? ((UIVisualEffectView *)overlay).contentView
        : overlay;
    for (UIView *subview in rowHost.subviews) {
        subview.alpha = 0;
    }

    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        overlay.frame = collapsedDropdownFrame;
    } completion:^(BOOL finished) {
        finish();
    }];
}

- (void)zs_modsOptionsDropdownRowTapped:(UIButton *)sender {
    ModAssetLibraryEntry *entry = self.modsOptionsDropdownEntry;
    NSString *folderName = self.modsOptionsDropdownFolderName;
    BOOL isFolderMode = (entry == nil);
    BOOL isStoredBundlesRow = !isFolderMode && zs_mods_folder_is_or_within_stored_bundles(folderName);
    NSArray<NSDictionary<NSString *, id> *> *options = isFolderMode ? zs_mods_options_for_folder(folderName)
        : (isStoredBundlesRow ? zs_mods_stored_bundle_file_options() : zs_mods_file_options(entry));
    if (sender.tag < 0 || sender.tag >= (NSInteger)options.count) {
        [self zs_closeModsOptionsDropdownAnimated:YES];
        return;
    }

    NSDictionary<NSString *, id> *tappedOption = options[sender.tag];
    [self zs_closeModsOptionsDropdownAnimated:YES];
    if (!folderName) return;
    if (!isFolderMode && !entry) return;

    if ([tappedOption[@"disabled"] boolValue]) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        return;
    }

    NSString *title = tappedOption[@"title"];

    if (isFolderMode) {
        if ([title isEqualToString:@"Add mod"]) {
            [self zs_presentModImportPickerForFolder:folderName];
        } else if ([title isEqualToString:@"Rename"]) {
            [self zs_promptForModFolderRenameForFolder:folderName];
        } else if ([title isEqualToString:@"Cache folder"]) {
            [self zs_cacheModFolder:folderName];
        } else if ([title isEqualToString:@"Add remark"]) {
            [self zs_promptForModFolderRemarkForFolder:folderName];
        } else if ([title isEqualToString:@"Re-place"]) {
            [self zs_rePlaceModFolder:folderName];
        } else if ([title isEqualToString:@"Delete"]) {
            [self zs_confirmDeleteModFolder:folderName];
        } else if ([title isEqualToString:@"Restore"]) {
            [self zs_restoreStoredModFolder:folderName];
        }
        return;
    }

    if ([title isEqualToString:@"Cache bundle"]) {
        [self zs_cacheBundleEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Restore"]) {
        [self zs_restoreStoredBundleEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Add remark"]) {
        [self zs_promptForModRemarkForEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Re-place"]) {
        [self zs_rePlaceModEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Delete"]) {
        [self zs_confirmDeleteModEntry:entry inFolder:folderName];
    }
}

- (void)zs_modsOptionsDropdownScrimTapped:(UIControl *)sender {
    [self zs_closeModsOptionsDropdownAnimated:YES];
}

static NSURL *zs_mods_live_stock_url_for_entry(ModAssetLibraryEntry *entry) {
    if (entry.livePathDescription.length == 0) return nil;
    NSString *absolute = [NSHomeDirectory() stringByAppendingPathComponent:entry.livePathDescription];
    return [NSURL fileURLWithPath:absolute];
}

- (BOOL)zs_cacheBundleEntryCore:(ModAssetLibraryEntry *)entry
                        inFolder:(NSString *)folderName
                  toStoredFolder:(NSString *)storedFolder
                    partlyFailed:(BOOL *)outPartlyFailed
                           error:(NSError **)outError {
    if (outPartlyFailed) *outPartlyFailed = NO;
    BOOL isLiveInstalledBundle = entry.isAssetBundle && entry.doctorStatus == ModAssetLibraryDoctorStatusInstalled;
    BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);

    if (isBank) {
        NSError *bankErr = nil;
        NSInteger restored = [BankTransplant restoreBackedUpBankNamed:entry.fileName error:&bankErr];
        if (restored < 0) {
            if (outError) *outError = bankErr ?: [NSError errorWithDomain:@"ZSModsCache" code:6
                                                                   userInfo:@{NSLocalizedDescriptionKey: @"Couldn't restore the original bank before caching it."}];
            return NO;
        }
    }

    BOOL isFont = [ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown;
    if (isFont) {
        [ModAssetLibrary deactivateFontForEntry:entry];
    }

    NSURL *stockURL = isLiveInstalledBundle ? zs_mods_live_stock_url_for_entry(entry) : nil;
    if (isLiveInstalledBundle && !stockURL) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsCache" code:1
                                                    userInfo:@{NSLocalizedDescriptionKey: @"This entry's live location isn't known."}];
        return NO;
    }

    NSString *tempPath = nil;
    NSURL *replacementBytesURL = nil;
    if (stockURL) {

        tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        NSError *snapshotErr = nil;
        BOOL scoped = [stockURL startAccessingSecurityScopedResource];
        BOOL snapshotted = [NSFileManager.defaultManager copyItemAtURL:stockURL toURL:[NSURL fileURLWithPath:tempPath] error:&snapshotErr];
        if (scoped) [stockURL stopAccessingSecurityScopedResource];
        if (!snapshotted) {
            if (outError) *outError = snapshotErr ?: [NSError errorWithDomain:@"ZSModsCache" code:2
                                                                       userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the live bundle."}];
            return NO;
        }

        NSError *cacheErr = nil;
        if (![ZTranscoderInstaller cacheOriginalBackForStockBundleURL:stockURL error:&cacheErr]) {
            [NSFileManager.defaultManager removeItemAtPath:tempPath error:nil];
            if (outError) *outError = cacheErr ?: [NSError errorWithDomain:@"ZSModsCache" code:3
                                                                     userInfo:@{NSLocalizedDescriptionKey: @"Unknown error."}];
            return NO;
        }
        replacementBytesURL = [NSURL fileURLWithPath:tempPath];
    }

    if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
        [self zs_restoreLocalizationEntryBestEffort:entry];
    }

    entry.cachedFromFolder = folderName;
    NSError *moveErr = nil;
    ModAssetLibraryEntry *moved = [ModAssetLibrary moveEntry:entry
                                                    fromFolder:folderName
                                                      toFolder:storedFolder
                                           replacementBytesURL:replacementBytesURL
                                                         error:&moveErr];
    if (tempPath) [NSFileManager.defaultManager removeItemAtPath:tempPath error:nil];
    if (!moved) {

        ZLog(@"[Mods Library] couldn't move %@ into \"%@\": %@", entry.fileName, storedFolder, moveErr.localizedDescription);
        if (outPartlyFailed) *outPartlyFailed = (replacementBytesURL != nil);
        if (outError) *outError = moveErr ?: [NSError errorWithDomain:@"ZSModsCache" code:5
                                                                userInfo:@{NSLocalizedDescriptionKey: @"The entry couldn't be moved into Stored Bundles."}];
        return NO;
    }

    return YES;
}

- (void)zs_cacheBundleEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    NSError *createErr = nil;
    if (![ModAssetLibrary createFolderNamed:kZSStoredBundlesFolderName error:&createErr]
        && createErr.code != ModAssetLibraryErrorFolderAlreadyExists) {
        [self zs_presentModsAlertWithTitle:@"Store Failed"
                                    message:createErr.localizedDescription ?: @"Couldn't prepare Stored Bundles."];
        return;
    }

    BOOL partlyFailed = NO;
    NSError *error = nil;
    BOOL ok = [self zs_cacheBundleEntryCore:entry inFolder:folderName toStoredFolder:kZSStoredBundlesFolderName
                                partlyFailed:&partlyFailed error:&error];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:partlyFailed ? @"Store Partly Failed" : @"Store Failed"
                                    message:partlyFailed
                                        ? @"The live bundle was restored, but the entry couldn't be moved into Stored Bundles. See syslog."
                                        : (error.localizedDescription ?: @"Unknown error.")];
        [self zs_rebuildModsLibrary];
        return;
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    ZLog(@"[Mods Library] cached %@ from \"%@\" into \"%@\"", entry.fileName, folderName, kZSStoredBundlesFolderName);
    [self zs_rebuildModsLibrary];
}

- (void)zs_cacheModFolder:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    if (entries.count == 0) {
        [self zs_presentModsAlertWithTitle:@"Nothing to Cache" message:@"This folder has no mods in it."];
        return;
    }

    NSError *createErr = nil;
    if (![ModAssetLibrary createFolderNamed:kZSStoredBundlesFolderName error:&createErr]
        && createErr.code != ModAssetLibraryErrorFolderAlreadyExists) {
        [self zs_presentModsAlertWithTitle:@"Cache Folder Failed"
                                    message:createErr.localizedDescription ?: @"Couldn't prepare Stored Bundles."];
        return;
    }

    NSError *subErr = nil;
    NSString *destinationFolder = [ModAssetLibrary createUniqueSubFolderNamed:folderName
                                                                    insideFolder:kZSStoredBundlesFolderName
                                                                           error:&subErr];
    if (!destinationFolder) {
        [self zs_presentModsAlertWithTitle:@"Cache Folder Failed"
                                    message:subErr.localizedDescription ?: @"Couldn't make room for this folder inside Stored Bundles."];
        return;
    }

    NSInteger failureCount = 0;
    BOOL anyPartlyFailed = NO;
    for (ModAssetLibraryEntry *entry in entries) {
        BOOL partlyFailed = NO;
        NSError *error = nil;
        BOOL ok = [self zs_cacheBundleEntryCore:entry inFolder:folderName toStoredFolder:destinationFolder
                                    partlyFailed:&partlyFailed error:&error];
        if (!ok) {
            failureCount++;
            if (partlyFailed) anyPartlyFailed = YES;
            ZLog(@"[Mods Library] Cache folder %@: couldn't cache %@: %@", folderName, entry.fileName, error.localizedDescription);
        }
    }

    if (failureCount == entries.count) {
        NSError *cleanupErr = nil;
        if (![ModAssetLibrary deleteFolderNamed:destinationFolder error:&cleanupErr]) {
            ZLog(@"[Mods Library] Cache folder %@: couldn't clean up the empty \"%@\" after every item failed: %@",
                 folderName, destinationFolder, cleanupErr.localizedDescription);
        }
    } else {
        NSArray<ModAssetLibraryEntry *> *remaining = [ModAssetLibrary entriesInFolder:folderName error:nil];
        if (remaining.count == 0) {
            NSError *deleteErr = nil;
            if (![ModAssetLibrary deleteFolderNamed:folderName error:&deleteErr]) {
                ZLog(@"[Mods Library] Cache folder %@: cached every entry but couldn't remove the now-empty original folder: %@",
                     folderName, deleteErr.localizedDescription);
            }
        }
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:failureCount == 0 ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (failureCount > 0) {
        NSString *message = [NSString stringWithFormat:@"%ld of %ld mod%@ couldn't be moved into Stored Bundles.%@ See syslog.",
                              (long)failureCount, (long)entries.count, entries.count == 1 ? @"" : @"s",
                              anyPartlyFailed ? @" Some live bundles were already restored before the move failed." : @""];
        [self zs_presentModsAlertWithTitle:@"Cache Folder Partly Failed" message:message];
    }
    ZLog(@"[Mods Library] cache folder \"%@\": %ld of %lu entries cached into \"%@\"",
         folderName, (long)(entries.count - failureCount), (unsigned long)entries.count, destinationFolder);
    [self zs_rebuildModsLibrary];
}

- (void)zs_restoreStoredBundleEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    ModAssetLibraryEntry *overlapping = [ModAssetLibrary activeEntryOverlappingEntry:entry];
    if (overlapping) {
        UINotificationFeedbackGenerator *overlapHaptic = [UINotificationFeedbackGenerator new];
        [overlapHaptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Mod Overlap"
                                    message:[ModAssetLibrary overlapRejectionLineForName:[ModAssetLibrary displayNameForEntry:entry]
                                                                            existingEntry:overlapping]];
        return;
    }

    NSURL *stockURL = entry.isAssetBundle ? zs_mods_live_stock_url_for_entry(entry) : nil;

    NSArray<NSString *> *realFolders = [[ModAssetLibrary folderNames] mutableCopy];
    NSString *targetFolder = entry.cachedFromFolder;
    BOOL targetStillExists = targetFolder.length > 0 && [realFolders containsObject:targetFolder];
    if (targetStillExists) {
        [self zs_finishRestoringStoredBundleEntry:entry stockURL:stockURL intoFolder:targetFolder];
        return;
    }

    NSMutableArray<NSString *> *pickable = [realFolders mutableCopy];
    [pickable removeObject:kZSStoredBundlesFolderName];

    if (pickable.count == 0) {
        [self zs_promptForModFolderNameWithTitle:@"Choose a Folder"
                                      actionTitle:@"Create & Restore"
                                       completion:^(NSString *trimmedName) {
            NSError *createErr = nil;
            if (![ModAssetLibrary createFolderNamed:trimmedName error:&createErr]) {
                [self zs_presentModsAlertWithTitle:@"Couldn't Create Folder" message:createErr.localizedDescription ?: @"Unknown error."];
                return;
            }
            [self zs_finishRestoringStoredBundleEntry:entry stockURL:stockURL intoFolder:trimmedName];
        }];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Restore Into Which Folder?"
                                                                      message:[NSString stringWithFormat:@"\"%@\" no longer exists.", targetFolder ?: @"its original folder"]
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *candidate in pickable) {
        [sheet addAction:[UIAlertAction actionWithTitle:candidate style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self zs_finishRestoringStoredBundleEntry:entry stockURL:stockURL intoFolder:candidate];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)zs_finishRestoringStoredBundleEntry:(ModAssetLibraryEntry *)entry stockURL:(nullable NSURL *)stockURL intoFolder:(NSString *)destFolder {
    NSString *sourceFolder = zs_mods_folder_name_for_entry(entry) ?: kZSStoredBundlesFolderName;

    if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
        NSError *applyErr = nil;
        if (![self zs_applyLocalizationEntry:entry error:&applyErr]) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:applyErr.localizedDescription ?: @"Unknown error."];
            return;
        }
    }

    if (stockURL) {
        NSError *installErr = nil;
        if (![ZTranscoderInstaller installDoctoredBundleAtURL:[NSURL fileURLWithPath:entry.path]
                                              toStockBundleURL:stockURL
                                                          error:&installErr]) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:installErr.localizedDescription ?: @"Unknown error."];
            return;
        }
    }

    BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);
    if (isBank) {
        NSError *bankErr = nil;
        if (![BankTransplant transplantAndSwapModdedBankAtURL:[NSURL fileURLWithPath:entry.path] error:&bankErr]) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:bankErr.localizedDescription ?: @"Unknown error."];
            return;
        }
    }

    if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) {
        NSError *fontErr = nil;
        if (![ModAssetLibrary activateFontForEntry:entry error:&fontErr]) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:fontErr.localizedDescription ?: @"Unknown error."];
            return;
        }
    }

    NSError *moveErr = nil;
    if (![self zs_moveRestoredStoredBundleEntry:entry fromFolder:sourceFolder toFolder:destFolder error:&moveErr]) {
        [self zs_presentModsAlertWithTitle:@"Restore Partly Failed"
                                    message:@"The live bundle was restored, but the entry couldn't be moved out of Stored Bundles. See syslog."];
        [self zs_rebuildModsLibrary];
        return;
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    ZLog(@"[Mods Library] restored %@ from \"%@\" into \"%@\"", entry.fileName, sourceFolder, destFolder);
    [self zs_rebuildModsLibrary];
}

- (BOOL)zs_moveRestoredStoredBundleEntry:(ModAssetLibraryEntry *)entry
                               fromFolder:(NSString *)sourceFolder
                                 toFolder:(NSString *)destFolder
                                    error:(NSError **)outError {
    entry.cachedFromFolder = nil;
    NSError *moveErr = nil;
    ModAssetLibraryEntry *moved = [ModAssetLibrary moveEntry:entry
                                                    fromFolder:sourceFolder
                                                      toFolder:destFolder
                                           replacementBytesURL:nil
                                                         error:&moveErr];
    if (!moved) {
        ZLog(@"[Mods Library] restored %@'s live file but couldn't move its library entry back into \"%@\": %@", entry.fileName, destFolder, moveErr.localizedDescription);
        if (outError) *outError = moveErr;
        return NO;
    }

    if (![sourceFolder isEqualToString:kZSStoredBundlesFolderName]) {
        NSArray<ModAssetLibraryEntry *> *remaining = [ModAssetLibrary entriesInFolder:sourceFolder error:nil];
        if (remaining.count == 0) {
            NSError *deleteErr = nil;
            if (![ModAssetLibrary deleteFolderNamed:sourceFolder error:&deleteErr]) {
                ZLog(@"[Mods Library] restored the last item out of cached folder \"%@\" but couldn't remove it: %@",
                     sourceFolder, deleteErr.localizedDescription);
            }
        }
    }
    return YES;
}

- (void)zs_restoreStoredModFolder:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    if (entries.count == 0) {
        [self zs_presentModsAlertWithTitle:@"Nothing to Restore" message:@"This cached folder is empty."];
        return;
    }

    NSString *targetFolder = folderName.lastPathComponent;
    NSArray<NSString *> *realFolders = [ModAssetLibrary folderNames];
    BOOL targetStillExists = targetFolder.length > 0 && [realFolders containsObject:targetFolder];
    if (targetStillExists) {
        [self zs_finishRestoringStoredModFolder:folderName entries:entries intoFolder:targetFolder];
        return;
    }

    NSError *createErr = nil;
    if (![ModAssetLibrary createFolderNamed:targetFolder error:&createErr] && createErr.code != ModAssetLibraryErrorFolderAlreadyExists) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Create Folder" message:createErr.localizedDescription ?: @"Unknown error."];
        return;
    }
    [self zs_finishRestoringStoredModFolder:folderName entries:entries intoFolder:targetFolder];
}

- (void)zs_finishRestoringStoredModFolder:(NSString *)folderName
                                   entries:(NSArray<ModAssetLibraryEntry *> *)entries
                                intoFolder:(NSString *)destFolder {
    NSInteger failureCount = 0;
    NSMutableArray<NSString *> *overlapLines = [NSMutableArray array];
    for (ModAssetLibraryEntry *entry in entries) {
        ModAssetLibraryEntry *overlapping = [ModAssetLibrary activeEntryOverlappingEntry:entry];
        if (overlapping) {
            failureCount++;
            [overlapLines addObject:[ModAssetLibrary overlapRejectionLineForName:[ModAssetLibrary displayNameForEntry:entry]
                                                                    existingEntry:overlapping]];
            continue;
        }

        if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
            NSError *applyErr = nil;
            if (![self zs_applyLocalizationEntry:entry error:&applyErr]) {
                failureCount++;
                ZLog(@"[Mods Library] restore folder \"%@\": couldn't re-place %@: %@", folderName, entry.fileName, applyErr.localizedDescription);
                continue;
            }
        }

        NSURL *stockURL = entry.isAssetBundle ? zs_mods_live_stock_url_for_entry(entry) : nil;
        if (stockURL) {
            NSError *installErr = nil;
            if (![ZTranscoderInstaller installDoctoredBundleAtURL:[NSURL fileURLWithPath:entry.path]
                                                  toStockBundleURL:stockURL
                                                              error:&installErr]) {
                failureCount++;
                ZLog(@"[Mods Library] restore folder \"%@\": couldn't restore %@'s live file: %@", folderName, entry.fileName, installErr.localizedDescription);
                continue;
            }
        }

        BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);
        if (isBank) {
            NSError *bankErr = nil;
            if (![BankTransplant transplantAndSwapModdedBankAtURL:[NSURL fileURLWithPath:entry.path] error:&bankErr]) {
                failureCount++;
                ZLog(@"[Mods Library] restore folder \"%@\": couldn't restore %@'s live bank: %@", folderName, entry.fileName, bankErr.localizedDescription);
                continue;
            }
        }

        if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) {
            NSError *fontErr = nil;
            if (![ModAssetLibrary activateFontForEntry:entry error:&fontErr]) {
                failureCount++;
                ZLog(@"[Mods Library] restore folder \"%@\": couldn't activate %@'s font: %@", folderName, entry.fileName, fontErr.localizedDescription);
                continue;
            }
        }

        NSError *moveErr = nil;
        if (![self zs_moveRestoredStoredBundleEntry:entry fromFolder:folderName toFolder:destFolder error:&moveErr]) {
            failureCount++;
        }
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:failureCount == 0 ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (overlapLines.count > 0) {
        NSInteger otherFailures = failureCount - (NSInteger)overlapLines.count;
        NSString *overlapMessage = [overlapLines componentsJoinedByString:@"\n"];
        if (otherFailures > 0) {
            overlapMessage = [overlapMessage stringByAppendingFormat:@"\n\n%ld other mod%@ couldn't be restored. See syslog.",
                              (long)otherFailures, otherFailures == 1 ? @"" : @"s"];
        }
        [self zs_presentModsAlertWithTitle:@"Mod Overlap" message:overlapMessage];
    } else if (failureCount > 0) {
        [self zs_presentModsAlertWithTitle:@"Restore Partly Failed"
                                    message:[NSString stringWithFormat:@"%ld of %ld mod%@ couldn't be restored. See syslog.",
                                             (long)failureCount, (long)entries.count, entries.count == 1 ? @"" : @"s"]];
    }
    ZLog(@"[Mods Library] restored cached folder \"%@\": %ld of %lu entries restored into \"%@\"",
         folderName, (long)(entries.count - failureCount), (unsigned long)entries.count, destFolder);
    [self zs_rebuildModsLibrary];
}

- (void)zs_presentFloatingTextFieldWithInitialText:(NSString *)initialText
                                        placeholder:(NSString *)placeholder
                                             secure:(BOOL)secure
                                         completion:(void (^)(NSString * _Nullable trimmedText))completion {
    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;
    if (self.zsFloatingField) {
        [self zs_commitFloatingFieldSaving:YES];
    }

    self.zsFloatingFieldCompletion = completion;

    UIView *backdrop = [[UIView alloc] init];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.backgroundColor = UIColor.clearColor;
    backdrop.userInteractionEnabled = YES;
    [backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_floatingFieldBackdropTapped)]];
    [unityView addSubview:backdrop];
    zs_force_dark(backdrop);
    self.zsFloatingFieldBackdrop = backdrop;
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:unityView.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:unityView.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:unityView.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:unityView.bottomAnchor],
    ]];

    UITextField *field = [[UITextField alloc] init];
    field.text = initialText;
    field.placeholder = placeholder;
    field.secureTextEntry = secure;
    field.textColor = UIColor.whiteColor;
    field.font = zs_mono_font(15, UIFontWeightRegular);
    field.returnKeyType = UIReturnKeyDone;
    field.autocapitalizationType = secure ? UITextAutocapitalizationTypeNone : UITextAutocapitalizationTypeSentences;
    field.autocorrectionType = secure ? UITextAutocorrectionTypeNo : UITextAutocorrectionTypeDefault;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    self.zsFloatingField = field;

    UIVisualEffectView *glass = zs_wrap_field_in_native_glass(field, 6);
    UIView *container = glass ?: field;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [unityView addSubview:container];
    zs_force_dark(container);
    [unityView bringSubviewToFront:container];
    self.zsFloatingFieldContainer = container;

    container.alpha = 0;
    NSLayoutConstraint *bottom = [container.bottomAnchor constraintEqualToAnchor:unityView.bottomAnchor constant:-8];
    self.zsFloatingFieldBottomConstraint = bottom;
    [NSLayoutConstraint activateConstraints:@[
        [container.leadingAnchor constraintEqualToAnchor:unityView.safeAreaLayoutGuide.leadingAnchor constant:16],
        [container.trailingAnchor constraintEqualToAnchor:unityView.safeAreaLayoutGuide.trailingAnchor constant:-16],
        bottom,
        [container.heightAnchor constraintEqualToConstant:44],
    ]];

    CGFloat bottomInset = unityView.safeAreaInsets.bottom + 291;
    if (!CGRectIsEmpty(self.zs_lastKeyboardFrame)) {
        CGFloat inset = CGRectGetHeight(unityView.bounds) - CGRectGetMinY(self.zs_lastKeyboardFrame);
        if (inset >= 8) bottomInset = inset;
    }
    bottom.constant = -(bottomInset + 8);
    [unityView layoutIfNeeded];

    [UIView animateWithDuration:0.15 animations:^{
        container.alpha = 1;
    }];

    [field becomeFirstResponder];
}

- (void)zs_commitFloatingFieldSaving:(BOOL)saving {
    void (^completion)(NSString * _Nullable) = self.zsFloatingFieldCompletion;
    NSString *trimmed = [(self.zsFloatingField.text ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    UIView *backdrop = self.zsFloatingFieldBackdrop;
    UIView *container = self.zsFloatingFieldContainer;
    self.zsFloatingFieldBackdrop = nil;
    self.zsFloatingFieldContainer = nil;
    self.zsFloatingField = nil;
    self.zsFloatingFieldBottomConstraint = nil;
    self.zsFloatingFieldCompletion = nil;

    backdrop.userInteractionEnabled = NO;
    container.userInteractionEnabled = NO;

    [UIView animateWithDuration:0.15 animations:^{
        backdrop.alpha = 0;
        container.alpha = 0;
    } completion:^(BOOL finished) {
        [backdrop removeFromSuperview];
        [container removeFromSuperview];
    }];

    if (saving && completion) {
        completion(trimmed.length > 0 ? trimmed : nil);
    }
}

- (void)zs_commitFloatingField {
    [self zs_commitFloatingFieldSaving:YES];
}

- (void)zs_floatingFieldBackdropTapped {
    [self.zsFloatingField resignFirstResponder];
}

- (void)zs_promptForModRemarkForEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    if (!entry) return;
    __weak typeof(self) weakSelf = self;
    [self zs_presentFloatingTextFieldWithInitialText:entry.remark
                                          placeholder:@"Remark"
                                               secure:NO
                                           completion:^(NSString * _Nullable trimmedText) {
        [weakSelf zs_saveModRemark:trimmedText forEntry:entry inFolder:folderName];
    }];
}

- (void)zs_saveModRemark:(nullable NSString *)remark forEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.remark = remark;
    }
                                                                           error:&error];
    if (!updated) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Save Remark" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }
    [self zs_rebuildModsLibrary];
}

- (BOOL)zs_rePlaceModEntryCore:(ModAssetLibraryEntry *)entry error:(NSError **)outError {
    if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
        return [self zs_applyLocalizationEntry:entry error:outError];
    }

    BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);
    if (isBank) {
        return [BankTransplant transplantAndSwapModdedBankAtURL:[NSURL fileURLWithPath:entry.path] error:outError];
    }

    if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) {
        return [ModAssetLibrary activateFontForEntry:entry error:outError];
    }

    if (!entry.isAssetBundle) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsRePlace" code:1
                                                    userInfo:@{NSLocalizedDescriptionKey: @"This file type can't be re-placed."}];
        return NO;
    }

    if (entry.doctorStatus != ModAssetLibraryDoctorStatusInstalled) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsRePlace" code:2
                                                    userInfo:@{NSLocalizedDescriptionKey: @"This bundle hasn't been processed and installed yet - dispatch it first."}];
        return NO;
    }

    NSURL *stockURL = zs_mods_live_stock_url_for_entry(entry);
    if (!stockURL) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsRePlace" code:3
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve this mod's installed location."}];
        return NO;
    }

    return [ZTranscoderInstaller installDoctoredBundleAtURL:[NSURL fileURLWithPath:entry.path]
                                            toStockBundleURL:stockURL
                                                       error:outError];
}

- (void)zs_rePlaceModEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    NSError *error = nil;
    BOOL ok = [self zs_rePlaceModEntryCore:entry error:&error];
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    if (!ok) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Re-place Failed" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }
    [self zs_persistFontLivePathIfNeededForEntry:entry inFolder:folderName];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    ZLog(@"[Mods Library] re-placed %@ into the game's files", entry.fileName);
    [self zs_rebuildModsLibrary];
}

- (void)zs_persistFontLivePathIfNeededForEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    if ([ZSModsPaths fontKindForFileName:entry.fileName] == ZSFontKindUnknown) return;
    NSString *livePath = entry.livePathDescription;
    [ModAssetLibrary updateDoctorStateForEntry:entry inFolder:folderName applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.livePathDescription = livePath;
    } error:nil];
}

- (void)zs_rePlaceModFolder:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];

    NSInteger succeeded = 0, failed = 0;
    for (ModAssetLibraryEntry *entry in entries) {
        NSError *entryErr = nil;
        if ([self zs_rePlaceModEntryCore:entry error:&entryErr]) {
            succeeded++;
            [self zs_persistFontLivePathIfNeededForEntry:entry inFolder:folderName];
        } else {
            failed++;
            ZLog(@"[Mods Library] re-place \"%@\" in \"%@\" failed: %@", entry.fileName, folderName, entryErr.localizedDescription);
        }
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:(failed == 0 && succeeded > 0) ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning];
    ZLog(@"[Mods Library] re-placed folder \"%@\": %ld succeeded, %ld skipped or failed", folderName, (long)succeeded, (long)failed);
    [self zs_presentModsAlertWithTitle:@"Re-place Folder"
                                message:[NSString stringWithFormat:@"%ld re-placed, %ld skipped or failed. See syslog for details.",
                                         (long)succeeded, (long)failed]];
    [self zs_rebuildModsLibrary];
}

- (void)zs_confirmDeleteModEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete File?"
                                                                       message:[NSString stringWithFormat:@"\u201C%@\u201D will be removed from the Mod Asset Library and the original will be restored in the game's files.", entry.fileName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_deleteModEntryConfirmed:entry inFolder:folderName];
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_promptForModFolderRenameForFolder:(NSString *)folderName {
    __weak typeof(self) weakSelf = self;
    [self zs_promptForModFolderNameWithTitle:@"Rename Folder"
                                  actionTitle:@"Rename"
                                   completion:^(NSString *trimmedName) {
        [weakSelf zs_renameModFolder:folderName to:trimmedName];
    }];
}

- (void)zs_renameModFolder:(NSString *)folderName to:(NSString *)newName {
    NSError *error = nil;
    BOOL ok = [ModAssetLibrary renameFolderNamed:folderName to:newName error:&error];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Rename Folder" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }

    if ([self.modsLibraryExpandedFolders containsObject:folderName]) {
        [self.modsLibraryExpandedFolders removeObject:folderName];
        [self.modsLibraryExpandedFolders addObject:newName];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_promptForModFolderRemarkForFolder:(NSString *)folderName {
    if (!folderName) return;
    __weak typeof(self) weakSelf = self;
    [self zs_presentFloatingTextFieldWithInitialText:[ModAssetLibrary remarkForFolder:folderName]
                                          placeholder:@"Remark"
                                               secure:NO
                                           completion:^(NSString * _Nullable trimmedText) {
        [weakSelf zs_saveModFolderRemark:trimmedText forFolder:folderName];
    }];
}

- (void)zs_saveModFolderRemark:(nullable NSString *)remark forFolder:(NSString *)folderName {
    NSError *error = nil;
    BOOL ok = [ModAssetLibrary setRemark:remark forFolder:folderName error:&error];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Save Remark" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_confirmDeleteModFolder:(NSString *)folderName {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Folder?"
                                                                       message:[NSString stringWithFormat:@"\u201C%@\u201D and every mod inside it will be removed and the originals will be restored in the game's files.", folderName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_deleteModFolderConfirmed:folderName];
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_modsLibraryEntryDownloadTapped:(UIButton *)sender {

    if (self.authCredentialsStale) {
        UINotificationFeedbackGenerator *errorHaptic = [UINotificationFeedbackGenerator new];
        [errorHaptic notificationOccurred:UINotificationFeedbackTypeError];
        ZLog(@"[Mods Library] download blocked: auth credentials are stale.");
        return;
    }

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;
    NSString *folderName = zs_mods_folder_name_for_entry(entry);
    if (!folderName) {
        ZLog(@"[Mods Library] Download tapped for %@ but couldn't derive its owning folder from its path (%@) - not proceeding.", entry.fileName, entry.path);
        return;
    }

    if (!self.doctorDownloadInFlightPaths) self.doctorDownloadInFlightPaths = [NSMutableSet set];
    if ([self.doctorDownloadInFlightPaths containsObject:entry.path]) {
        ZLog(@"[Mods Library] download for %@ already in flight, ignoring duplicate tap.", entry.fileName);
        return;
    }

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        ZLog(@"[Mods Library] download for %@ blocked: auth not configured (repo/owner/token missing).", entry.fileName);
        [self zs_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token under Mods \u2192 Auth first."];
        return;
    }

    ZTranscoderHandle *handle = [ZTranscoderHandle handleFromDictionaryRepresentation:@{
        @"scratchBranch": entry.doctorScratchBranch ?: @"",
        @"runID": entry.doctorRunID ?: @"",
        @"runURL": entry.doctorRunURL ?: @"",
    }];
    if (!handle) {
        ZLog(@"[Mods Library] download for %@ blocked: lost track of its scratch branch.", entry.fileName);
        [self zs_presentModsAlertWithTitle:@"Can't Download"
                                    message:@"Lost track of this submission's scratch branch - try Retry to send it again."];
        return;
    }

    NSString *entryPath = entry.path;
    [self.doctorDownloadInFlightPaths addObject:entryPath];
    [self.doctorDownloadProgressLastUpdate removeObjectForKey:entryPath];
    [self.doctorDownloadProgressPersistLastUpdate removeObjectForKey:entryPath];
    NSError *resetError = nil;
    ModAssetLibraryEntry *resetEntry = [ModAssetLibrary updateDoctorStateForEntry:entry inFolder:folderName applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorDownloadProgress = 0;
    } error:&resetError];
    if (!self.doctorDownloadLiveEntryCache) self.doctorDownloadLiveEntryCache = [NSMutableDictionary dictionary];
    if (resetEntry) self.doctorDownloadLiveEntryCache[entryPath] = resetEntry;
    [self zs_rebuildModsLibrary];

    ZLog(@"[Mods Library] downloading doctored bundle for %@ (run=%@).", entryPath.lastPathComponent, handle.runID);
    __weak typeof(self) weakSelf = self;
    [ZTranscoderService fetchDoctoredBundleForHandle:handle config:config
        progress:^(int64_t bytesWritten, int64_t totalBytesExpected) {
            [weakSelf zs_doctorHandleDownloadProgress:bytesWritten totalBytesExpected:totalBytesExpected forEntryPath:entryPath inFolder:folderName];
        }
        completion:^(NSURL * _Nullable doctoredBundleURL, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!doctoredBundleURL) {
            [strongSelf zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:error];
            return;
        }
        ZLog(@"[Mods Library] download finished for %@, proceeding to install.", entryPath.lastPathComponent);
        [strongSelf zs_doctorInstallUsingKnownTargetForDoctoredURL:doctoredBundleURL entryPath:entryPath inFolder:folderName];
    }];
}

- (void)zs_doctorHandleDownloadProgress:(int64_t)bytesWritten totalBytesExpected:(int64_t)totalBytesExpected forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (!self.doctorDownloadProgressLastUpdate) self.doctorDownloadProgressLastUpdate = [NSMutableDictionary dictionary];
    if (!self.doctorDownloadProgressPersistLastUpdate) self.doctorDownloadProgressPersistLastUpdate = [NSMutableDictionary dictionary];
    if (!self.doctorDownloadLiveEntryCache) self.doctorDownloadLiveEntryCache = [NSMutableDictionary dictionary];

    NSNumber *last = self.doctorDownloadProgressLastUpdate[entryPath];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL isFinal = totalBytesExpected > 0 && bytesWritten >= totalBytesExpected;
    if (last && !isFinal && (now - last.doubleValue) < kZSDoctorProgressMinUpdateInterval) return;
    self.doctorDownloadProgressLastUpdate[entryPath] = @(now);

    ModAssetLibraryEntry *liveEntry = self.doctorDownloadLiveEntryCache[entryPath];
    NSNumber *lastPersist = self.doctorDownloadProgressPersistLastUpdate[entryPath];
    BOOL shouldPersist = isFinal || !liveEntry || !lastPersist
        || (now - lastPersist.doubleValue) >= kZSDoctorDownloadProgressPersistInterval;

    if (shouldPersist) {
        NSError *error = nil;
        ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                            inFolder:folderName
                                                                          applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
            entryToMutate.doctorDownloadProgress = bytesWritten;
        }
                                                                               error:&error];
        if (!updated) return;
        self.doctorDownloadProgressPersistLastUpdate[entryPath] = @(now);
        if (isFinal) {
            [self.doctorDownloadLiveEntryCache removeObjectForKey:entryPath];
        } else {
            self.doctorDownloadLiveEntryCache[entryPath] = updated;
        }
        if (![self zs_updateDoctorProgressLabelForEntry:updated downloadInFlight:YES]) {
            [self zs_rebuildModsLibrary];
        }
        return;
    }

    liveEntry.doctorDownloadProgress = bytesWritten;
    if (![self zs_updateDoctorProgressLabelForEntry:liveEntry downloadInFlight:YES]) {
        [self zs_rebuildModsLibrary];
    }
}

- (void)zs_doctorDownloadFailedForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName error:(NSError *)error {
    [self.doctorDownloadInFlightPaths removeObject:entryPath];
    [self.doctorDownloadLiveEntryCache removeObjectForKey:entryPath];
    [self.doctorDownloadProgressPersistLastUpdate removeObjectForKey:entryPath];
    ZLog(@"[Mods Library] download failed for %@: %@", entryPath.lastPathComponent, error.localizedDescription ?: @"Unknown error.");
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeError];
    [self zs_presentModsAlertWithTitle:@"Download Failed"
                                message:error.localizedDescription ?: @"Unknown error."];
    [self zs_rebuildModsLibrary];
}

- (void)zs_doctorInstallUsingKnownTargetForDoctoredURL:(NSURL *)doctoredURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    ModAssetLibraryEntry *entry = nil;
    for (ModAssetLibraryEntry *candidate in entries) {
        if ([candidate.path isEqualToString:entryPath]) { entry = candidate; break; }
    }

    NSString *relativeTarget = entry.resolvedInstallTargetPath;
    if (relativeTarget.length > 0) {
        NSString *absolute = [NSHomeDirectory() stringByAppendingPathComponent:relativeTarget];
        [self zs_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:[NSURL fileURLWithPath:absolute] entryPath:entryPath inFolder:folderName];
        return;
    }

    if (entry.zipCacheHash1.length > 0 && entry.zipCacheHash2.length > 0) {
        NSError *synthErr = nil;
        NSString *synthDir = [UnityCacheLocator synthesizeCacheDirectoryForHash1:entry.zipCacheHash1 hash2:entry.zipCacheHash2 error:&synthErr];
        if (synthDir) {
            NSString *synthDataPath = [synthDir stringByAppendingPathComponent:@"__data"];

            NSString *storedInfoPath = [entryPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"__info"];
            if ([NSFileManager.defaultManager fileExistsAtPath:storedInfoPath]) {
                [NSFileManager.defaultManager copyItemAtPath:storedInfoPath toPath:[synthDir stringByAppendingPathComponent:@"__info"] error:nil];
            }
            ZLog(@"[Mods Library] no import-time cache match for %@ - using SYNTHESIZED (unverified) target %@ from its Lunartique zip hash pair.",
                 entryPath.lastPathComponent, synthDataPath);
            [self zs_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:[NSURL fileURLWithPath:synthDataPath] entryPath:entryPath inFolder:folderName];
            return;
        }
        ZLog(@"[Mods Library] Lunartique cache-directory synthesis failed for %@: %@ - falling back to the manual picker.",
             entryPath.lastPathComponent, synthErr.localizedDescription);
    }

    ZLog(@"[Mods Library] no import-time cache match on file for %@ - falling back to the manual picker.", entryPath.lastPathComponent);
    [self zs_presentDoctorInstallTargetPickerForDoctoredURL:doctoredURL entryPath:entryPath inFolder:folderName];
}

- (void)zs_presentDoctorInstallTargetPickerForDoctoredURL:(NSURL *)doctoredURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (self.doctorInstallTargetPicker) {

        [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                 code:ZTranscoderInstallerErrorNoInstallTarget
                             userInfo:@{NSLocalizedDescriptionKey: @"Another download is already waiting on a file pick - finish that one, then try this download again."}]];
        return;
    }

    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {

        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem]];
    } else {

        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"]
                                                                          inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods Library] no root view controller to present the doctor install target picker from");
        [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                 code:ZTranscoderInstallerErrorNoInstallTarget
                             userInfo:@{NSLocalizedDescriptionKey: @"Couldn't present the file picker."}]];
        return;
    }

    self.doctorInstallTargetPicker = picker;
    self.doctorInstallPendingDoctoredURL = doctoredURL;
    self.doctorInstallPendingEntryPath = entryPath;
    self.doctorInstallPendingFolderName = folderName;

    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_doctorInstallDoctoredURL:(NSURL *)doctoredURL toStockBundleURL:(NSURL *)stockBundleURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {

    NSError *currentEntriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *currentEntries = [ModAssetLibrary entriesInFolder:folderName error:&currentEntriesErr] ?: @[];
    ModAssetLibraryEntry *currentEntry = nil;
    for (ModAssetLibraryEntry *candidate in currentEntries) {
        if ([candidate.path isEqualToString:entryPath]) { currentEntry = candidate; break; }
    }
    BOOL wasCarra2Entry = currentEntry && !currentEntry.isAssetBundle && currentEntry.zipCacheHash1.length > 0;

    if (!wasCarra2Entry) {
        NSError *readErr = nil;
        NSData *doctoredData = [NSData dataWithContentsOfURL:doctoredURL options:0 error:&readErr];
        if (!doctoredData) {
            [self.doctorDownloadInFlightPaths removeObject:entryPath];
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            [haptic notificationOccurred:UINotificationFeedbackTypeError];
            [self zs_presentModsAlertWithTitle:@"Install Failed"
                                        message:readErr.localizedDescription ?: @"Couldn't read the doctored bundle."];
            [self zs_rebuildModsLibrary];
            return;
        }
        NSError *libraryWriteErr = nil;
        if (![doctoredData writeToFile:entryPath options:NSDataWritingAtomic error:&libraryWriteErr]) {
            [self.doctorDownloadInFlightPaths removeObject:entryPath];
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            [haptic notificationOccurred:UINotificationFeedbackTypeError];
            [self zs_presentModsAlertWithTitle:@"Install Failed"
                                        message:libraryWriteErr.localizedDescription ?: @"Couldn't update the mod library's own copy."];
            [self zs_rebuildModsLibrary];
            return;
        }
    }

    NSError *installError = nil;
    BOOL installed = [ZTranscoderInstaller installDoctoredBundleAtURL:doctoredURL toStockBundleURL:stockBundleURL error:&installError];
    [self.doctorDownloadInFlightPaths removeObject:entryPath];

    if (!installed) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Install Failed"
                                    message:installError.localizedDescription ?: @"Unknown error."];
        [self zs_rebuildModsLibrary];
        return;
    }

    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *nowISO = [iso stringFromDate:[NSDate date]];

    NSString *installedLogName = entryPath.lastPathComponent;
    unsigned long long freshByteSize = 0;

    if (wasCarra2Entry) {
        NSError *replaceErr = nil;
        ModAssetLibraryEntry *replaced = [ModAssetLibrary replaceEntry:currentEntry
                                                                inFolder:folderName
                                              withDownloadedBundleAtURL:doctoredURL
                                                                   error:&replaceErr];
        if (!replaced) {
            ZLog(@"[Mods Library] installed %@ but couldn't replace its Carra2 entry with the downloaded bundle: %@", entryPath.lastPathComponent, replaceErr.localizedDescription);
        } else {
            installedLogName = replaced.fileName;
            freshByteSize = replaced.byteSize;
            NSError *stateError = nil;
            ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:replaced
                                                                                inFolder:folderName
                                                                              applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusInstalled;
                entryToMutate.dateAdded = nowISO;
                entryToMutate.livePathDescription = [ModAssetLibrary liveGamePathDescriptionForInstalledURL:stockBundleURL];
            }
                                                                                   error:&stateError];
            if (!updated) {
                ZLog(@"[Mods Library] replaced %@ with its downloaded bundle but couldn't record it as Installed on the manifest (entry deleted mid-flight?): %@", entryPath.lastPathComponent, stateError);
            }
        }
    } else {
        int32_t freshPlatform = 0;
        NSError *platformErr = nil;
        BOOL gotPlatform = [UnityBundleCAB targetPlatform:&freshPlatform forBundleAtPath:doctoredURL.path error:&platformErr];
        NSNumber *freshPlatformNumber = gotPlatform ? @(freshPlatform) : nil;
        if (!gotPlatform) {

            ZLog(@"[Mods Library] couldn't re-read target platform from the doctored bundle for %@, leaving the row's existing value: %@", entryPath.lastPathComponent, platformErr.localizedDescription);
        }
        NSDictionary<NSFileAttributeKey, id> *doctoredAttrs = [NSFileManager.defaultManager attributesOfItemAtPath:doctoredURL.path error:nil];
        freshByteSize = doctoredAttrs.fileSize;

        NSError *stateError = nil;
        ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                            inFolder:folderName
                                                                          applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
            entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusInstalled;
            if (freshPlatformNumber) entryToMutate.targetPlatform = freshPlatformNumber;
            if (freshByteSize > 0) entryToMutate.byteSize = freshByteSize;
            entryToMutate.dateAdded = nowISO;

            entryToMutate.livePathDescription = [ModAssetLibrary liveGamePathDescriptionForInstalledURL:stockBundleURL];

        }
                                                                               error:&stateError];
        if (!updated) {
            ZLog(@"[Mods Library] installed %@ but couldn't record it as Installed on the manifest (entry deleted mid-flight?): %@", entryPath.lastPathComponent, stateError);
        }
    }

    ZLog(@"[Mods Library] installed doctored bundle %@ over %@ (%llu bytes)", installedLogName, stockBundleURL.path, freshByteSize);
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self zs_rebuildModsLibrary];
}

- (void)zs_restoreLocalizationEntryBestEffort:(ModAssetLibraryEntry *)entry {
    if (entry.localizationKind == ModAssetLibraryLocalizationKindPack) {
        [LocalizationTransplant restorePackForLanguage:entry.localizationLanguage ifAppliedFromPackAtPath:entry.path];
    } else if (entry.localizationKind == ModAssetLibraryLocalizationKindJSON && entry.localizationRelativePath.length > 0) {
        [LocalizationTransplant restoreRelativeTarget:entry.localizationRelativePath ifAppliedFromModFileAtPath:entry.path];
    }
}

- (BOOL)zs_applyLocalizationEntry:(ModAssetLibraryEntry *)entry error:(NSError **)outError {
    if (entry.localizationKind == ModAssetLibraryLocalizationKindPack) {
        return [LocalizationTransplant applyPackAtPath:entry.path toLanguage:entry.localizationLanguage error:outError];
    }
    if (entry.localizationRelativePath.length == 0) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsRePlace" code:4
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve this mod's target file."}];
        return NO;
    }
    return [LocalizationTransplant applyModFileAtPath:entry.path toRelativeTarget:entry.localizationRelativePath error:outError];
}

- (void)zs_restoreModEntryBestEffort:(ModAssetLibraryEntry *)entry {
    if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
        [self zs_restoreLocalizationEntryBestEffort:entry];
        return;
    }

    if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) {
        [ModAssetLibrary deactivateFontForEntry:entry];
        return;
    }

    NSError *bankError = nil;
    [BankTransplant restoreBackedUpBankNamed:entry.fileName error:&bankError];
    if (bankError) {
        ZLog(@"[Mods Library] couldn't restore %@ before removing it from the library: %@", entry.fileName, bankError.localizedDescription);
    }

    if (entry.isAssetBundle) {
        NSURL *stockURL = zs_mods_live_stock_url_for_entry(entry);
        if (stockURL) {
            NSError *bundleError = nil;
            BOOL restored = [ZTranscoderInstaller cacheOriginalBackForStockBundleURL:stockURL error:&bundleError];
            if (!restored) {
                ZLog(@"[Mods Library] couldn't restore %@'s live bundle at %@ before removing it from the library: %@", entry.fileName, stockURL.path, bundleError.localizedDescription);
            }
        }
    }
}

- (void)zs_handleHoldToConfirmGesture:(UILongPressGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    if (![button isKindOfClass:[UIButton class]]) return;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.holdConfirmActiveButton = button;
            self.holdConfirmStartTime = CACurrentMediaTime();
            self.holdConfirmTriggered = NO;

            UIView *expansion = objc_getAssociatedObject(button, kZSHoldConfirmExpansionViewKey);
            NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kZSHoldConfirmExpansionWidthKey);
            UILabel *deleteLabel = objc_getAssociatedObject(button, kZSHoldConfirmDeleteLabelKey);
            UIVisualEffectView *capsuleGlass = objc_getAssociatedObject(button, kZSHoldConfirmGlassViewKey);
            UIView *glassHost = objc_getAssociatedObject(button, kZSHoldConfirmGlassHostKey);

            widthConstraint.constant = kZSDeleteCapsuleExpandedWidth;
            [UIView animateWithDuration:kZSDeleteCapsuleSnapDuration
                                   delay:0
                  usingSpringWithDamping:kZSDeleteCapsuleSpringDamping
                   initialSpringVelocity:kZSDeleteCapsuleSpringVelocity
                                 options:UIViewAnimationOptionAllowUserInteraction
                              animations:^{
                deleteLabel.alpha = 1;
                if (capsuleGlass && glassHost) {
                    capsuleGlass.alpha = 1;
                    CGRect buttonFrameInHost = [button convertRect:button.bounds toView:glassHost];
                    CGRect expansionFrameInHost = [expansion convertRect:expansion.bounds toView:glassHost];
                    capsuleGlass.frame = CGRectUnion(buttonFrameInHost, expansionFrameInHost);
                }
                [button.superview layoutIfNeeded];
            }
                              completion:nil];

            [self.holdConfirmDisplayLink invalidate];
            self.holdConfirmDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_holdConfirmTick:)];
            [self.holdConfirmDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.holdConfirmDisplayLink invalidate];
            self.holdConfirmDisplayLink = nil;

            if (!self.holdConfirmTriggered) {

                [self zs_collapseHoldConfirmButton:button];

                UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
                [haptic notificationOccurred:UINotificationFeedbackTypeError];
            }
            self.holdConfirmActiveButton = nil;
            break;
        }
        default:
            break;
    }
}

- (void)zs_holdConfirmTick:(CADisplayLink *)link {
    static const NSTimeInterval kZSHoldConfirmDuration = 1.5;

    UIButton *button = self.holdConfirmActiveButton;
    if (!button) {
        [link invalidate];
        return;
    }

    NSTimeInterval elapsed = CACurrentMediaTime() - self.holdConfirmStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / kZSHoldConfirmDuration);

    UIView *expansion = objc_getAssociatedObject(button, kZSHoldConfirmExpansionViewKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kZSHoldConfirmExpansionFillKey);
    CALayer *buttonFill = objc_getAssociatedObject(button, kZSHoldConfirmButtonFillKey);

    CGFloat expansionWidth = expansion.bounds.size.width;
    CGFloat buttonWidth = button.bounds.size.width;
    CGFloat filledWidth = (expansionWidth + buttonWidth) * pct;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    expansionFill.frame = CGRectMake(0, 0, MIN(filledWidth, expansionWidth), expansion.bounds.size.height);
    buttonFill.frame = CGRectMake(0, 0, MAX(0, filledWidth - expansionWidth), buttonWidth);
    [CATransaction commit];

    if (pct >= 1.0 && !self.holdConfirmTriggered) {
        self.holdConfirmTriggered = YES;
        [link invalidate];
        self.holdConfirmDisplayLink = nil;

        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

        void (^onConfirm)(void) = objc_getAssociatedObject(button, kZSHoldConfirmBlockKey);
        if (onConfirm) onConfirm();
    }
}

- (void)zs_collapseHoldConfirmButton:(UIButton *)button {
    UIView *expansion = objc_getAssociatedObject(button, kZSHoldConfirmExpansionViewKey);
    NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kZSHoldConfirmExpansionWidthKey);
    UILabel *deleteLabel = objc_getAssociatedObject(button, kZSHoldConfirmDeleteLabelKey);
    UIVisualEffectView *capsuleGlass = objc_getAssociatedObject(button, kZSHoldConfirmGlassViewKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kZSHoldConfirmExpansionFillKey);
    CALayer *buttonFill = objc_getAssociatedObject(button, kZSHoldConfirmButtonFillKey);

    widthConstraint.constant = 0;
    [UIView animateWithDuration:kZSDeleteCapsuleSnapDuration
                           delay:0
          usingSpringWithDamping:kZSDeleteCapsuleSpringDamping
           initialSpringVelocity:kZSDeleteCapsuleSpringVelocity
                         options:UIViewAnimationOptionAllowUserInteraction
                      animations:^{
        deleteLabel.alpha = 0;
        capsuleGlass.alpha = 0;
        [button.superview layoutIfNeeded];
    }
                      completion:nil];

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.18];
    expansionFill.frame = CGRectMake(0, 0, 0, expansion.bounds.size.height);
    buttonFill.frame = CGRectMake(0, 0, 0, button.bounds.size.height);
    [CATransaction commit];
}

- (void)zs_handleTapToConfirm:(UIButton *)sender {
    NSString *title = objc_getAssociatedObject(sender, kZSTapConfirmTitleKey);
    NSString *message = objc_getAssociatedObject(sender, kZSTapConfirmMessageKey);
    NSString *actionTitle = objc_getAssociatedObject(sender, kZSTapConfirmActionTitleKey) ?: @"Confirm";
    BOOL destructive = [objc_getAssociatedObject(sender, kZSTapConfirmDestructiveKey) boolValue];
    void (^onConfirm)(void) = objc_getAssociatedObject(sender, kZSTapConfirmBlockKey);

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        if (onConfirm) onConfirm();
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:actionTitle
                                                 style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
        if (onConfirm) onConfirm();
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_deleteModEntryConfirmed:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    [self zs_restoreModEntryBestEffort:entry];

    NSError *error = nil;
    BOOL ok = [ModAssetLibrary removeEntry:entry fromFolder:folderName error:&error];
    [self.modsLibraryExpandedInfoEntries removeObject:entry.path];

    if (ok && zs_mods_folder_is_or_within_stored_bundles(folderName) && ![folderName isEqualToString:kZSStoredBundlesFolderName]) {
        NSError *remainingErr = nil;
        NSArray<ModAssetLibraryEntry *> *remaining = [ModAssetLibrary entriesInFolder:folderName error:&remainingErr];
        if (remaining.count == 0) {
            NSError *deleteErr = nil;
            if (![ModAssetLibrary deleteFolderNamed:folderName error:&deleteErr]) {
                ZLog(@"[Mods Library] removed the last item out of cached folder \"%@\" but couldn't remove it: %@",
                     folderName, deleteErr.localizedDescription);
            } else {
                [self.modsLibraryExpandedFolders removeObject:folderName];
            }
        }
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Remove File" message:error.localizedDescription ?: @"Unknown error."];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_deleteModFolderConfirmed:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    for (ModAssetLibraryEntry *entry in entries) {
        [self zs_restoreModEntryBestEffort:entry];
    }

    NSError *deleteErr = nil;
    BOOL ok = [ModAssetLibrary deleteFolderNamed:folderName error:&deleteErr];

    [self.modsLibraryExpandedFolders removeObject:folderName];
    for (ModAssetLibraryEntry *entry in entries) [self.modsLibraryExpandedInfoEntries removeObject:entry.path];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Delete Folder" message:deleteErr.localizedDescription ?: @"Unknown error."];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_presentModImportPickerForFolder:(NSString *)folderName {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem, UTTypeFolder]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item", @"public.folder"]
                                                                          inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods Library] no root view controller to present the file picker from");
        return;
    }
    self.libraryImportPicker = picker;
    self.libraryImportTargetFolder = folderName;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_handlePickedLibraryImportURLs:(NSArray<NSURL *> *)urls intoFolder:(NSString *)folderName {
    [self zs_handleLoadModsPickedURLs:urls intoFolder:folderName];
}

#pragma mark Syslog

- (void)toggleSyslogTapped {

    if (self.syslogHoldTriggered) {
        self.syslogHoldTriggered = NO;
        return;
    }

    if (self.syslogDebugModeEnabled) {
        [self zs_resetSyslogDebugMode];
        return;
    }

    self.syslogTabEnabled = !self.syslogTabEnabled;

    if (self.syslogTabEnabled) {
        BOOL started = [[ZSyslogController sharedController] start];
        [self zs_renderSyslogBuffer];
        if (!started) {
            [self appendSyslogLine:@"[syslog] Unable to start stdout/stderr capture"];
        }
        ZLog(@"[UserInterface] syslog console opened");
    } else {
        [self stopSyslog];
        [self zs_renderSyslogBuffer];
        ZLog(@"[UserInterface] syslog console closed");
    }

    UIView *unityView = zs_ui_host_view();
    if (unityView) {
        [self layoutPanelForWindow:unityView];
    }

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)handleSyslogButtonLongPress:(UILongPressGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.syslogHoldStartTime = CACurrentMediaTime();
            self.syslogHoldTriggered = NO;

            if (!self.syslogButtonFillLayer) {
                CALayer *fill = [CALayer layer];

                fill.backgroundColor = [UIColor colorWithRed:1.0 green:0.08 blue:0.08 alpha:0.85].CGColor;
                fill.anchorPoint = CGPointMake(0, 0);

                fill.cornerRadius = 200;
                fill.cornerCurve = kCACornerCurveContinuous;

                [self.syslogButton.layer insertSublayer:fill atIndex:0];
                self.syslogButtonFillLayer = fill;
            }

            [self.syslogHoldDisplayLink invalidate];
            self.syslogHoldDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_syslogHoldTick:)];
            [self.syslogHoldDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.syslogHoldDisplayLink invalidate];
            self.syslogHoldDisplayLink = nil;

            if (!self.syslogHoldTriggered) {

                [CATransaction begin];
                [CATransaction setAnimationDuration:0.18];
                self.syslogButtonFillLayer.frame = CGRectMake(0, 0, 0, self.syslogButton.bounds.size.height);
                self.syslogButtonFillLayer.cornerRadius = 200;
                [CATransaction commit];
            }
            break;
        }
        default:
            break;
    }
}

- (void)zs_syslogHoldTick:(CADisplayLink *)link {

    static const NSTimeInterval kSyslogHoldDuration = 1.0;
    NSTimeInterval elapsed = CACurrentMediaTime() - self.syslogHoldStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / kSyslogHoldDuration);

    CGRect bounds = self.syslogButton.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.syslogButtonFillLayer.frame = CGRectMake(0, 0, bounds.size.width * pct, bounds.size.height);
    self.syslogButtonFillLayer.cornerRadius = 200;
    [CATransaction commit];

    if (pct >= 1.0 && !self.syslogHoldTriggered) {
        self.syslogHoldTriggered = YES;
        [link invalidate];
        self.syslogHoldDisplayLink = nil;
        [self zs_enterSyslogDebugMode];
    }
}

- (void)zs_enterSyslogDebugMode {
    self.syslogDebugModeEnabled = YES;

    zs_style_button_mirroring_glass_state(self.syslogButton, @"Debug", [UIColor colorWithWhite:1 alpha:0.95], zs_mono_font(11, UIFontWeightSemibold));

    self.syslogTabEnabled = YES;

    BOOL started = [[ZSyslogController sharedController] start];
    [self zs_renderSyslogBuffer];
    if (!started) {
        [self appendSyslogLine:@"[syslog] Unable to start stdout/stderr capture"];
    }

    UIView *unityView = zs_ui_host_view();
    if (unityView) {
        [self layoutPanelForWindow:unityView];
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeWarning];

    ZLog(@"Debug syslog mode enabled - filtering to tweak-only log lines");
}

- (void)zs_resetSyslogDebugMode {
    self.syslogDebugModeEnabled = NO;
    zs_style_button_mirroring_glass_state(self.syslogButton, @"Syslog", [UIColor colorWithWhite:1 alpha:0.88], zs_mono_font(11, UIFontWeightSemibold));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.syslogButtonFillLayer.frame = CGRectMake(0, 0, 0, self.syslogButton.bounds.size.height);
    self.syslogButtonFillLayer.cornerRadius = 200;
    [CATransaction commit];

    UIView *unityView = zs_ui_host_view();
    if (unityView) {
        [self layoutPanelForWindow:unityView];
    }
    [self zs_renderSyslogBuffer];

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ZLog(@"Debug syslog mode disabled");
}

- (void)stopSyslog {
    [[ZSyslogController sharedController] stop];
    [self.syslogLines removeAllObjects];
    self.syslogTextLabel.attributedText = nil;
}

- (BOOL)zs_syslogLineIsBlacklisted:(NSString *)line {
    if (self.syslogBlacklist.count == 0) return NO;
    NSString *lower = line.lowercaseString;
    for (NSString *term in self.syslogBlacklist) {
        if (term.length > 0 && [lower containsString:term]) return YES;
    }
    return NO;
}

- (void)appendSyslogLine:(NSString *)line {
    if (!line.length) return;
    if ([self zs_syslogLineIsBlacklisted:line]) return;

    [self.syslogLines addObject:line];
    static const NSUInteger kMaxSyslogLines = 80;
    if (self.syslogLines.count > kMaxSyslogLines) {
        NSUInteger removeCount = self.syslogLines.count - kMaxSyslogLines;
        [self.syslogLines removeObjectsInRange:NSMakeRange(0, removeCount)];
    }

    [self zs_renderSyslogBuffer];
}

- (NSArray<NSString *> *)zs_syslogDisplayLines {

    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *line in self.syslogLines) {
        BOOL isZLogLine = [line containsString:kZLogTag];
        if (self.syslogDebugModeEnabled ? isZLogLine : !isZLogLine) {
            [filtered addObject:line];
        }
    }
    return filtered;
}

- (void)zs_renderSyslogBuffer {
    NSArray<NSString *> *displayLines = [self zs_syslogDisplayLines];
    NSString *joined = displayLines.count > 0
        ? [displayLines componentsJoinedByString:@"\n\n"]
        : (self.syslogTabEnabled
           ? (self.syslogDebugModeEnabled ? @"[syslog] Listening for tweak output\u2026" : @"[syslog] Listening for output\u2026")
           : @"[syslog] disabled");

    NSAttributedString *styled =
        [[NSAttributedString alloc] initWithString:joined
                                         attributes:@{
        NSFontAttributeName: self.syslogTextLabel.font,
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.92 alpha:1],
    }];

    self.syslogTextLabel.attributedText = styled;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.syslogConsoleScrollView) return;
        [self.syslogConsoleScrollView layoutIfNeeded];
        CGFloat maxOffsetY = MAX(0, self.syslogConsoleScrollView.contentSize.height - self.syslogConsoleScrollView.bounds.size.height);
        if (maxOffsetY > 0 && !self.syslogConsoleScrollView.isDragging && !self.syslogConsoleScrollView.isDecelerating) {
            self.syslogConsoleScrollView.contentOffset = CGPointMake(0, maxOffsetY);
        }
    });
}

#pragma mark Auth

- (void)zs_loadAuthFields {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    self.authRepoLinkField.text = zs_format_github_repo_link(config.repoOwner, config.repoName);
    self.authTokenField.text = config.authToken ?: @"";
}

- (void)zs_persistAuthFields {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];

    NSString *linkRaw = [self.authRepoLinkField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (linkRaw.length == 0) {
        config.repoOwner = nil;
        config.repoName = nil;
    } else {
        NSString *owner = nil, *name = nil;
        if (zs_parse_github_repo_link(linkRaw, &owner, &name)) {
            config.repoOwner = owner;
            config.repoName = name;

            self.authRepoLinkField.text = zs_format_github_repo_link(owner, name);
        } else {

            ZLog(@"[UserInterface] Auth: couldn't parse GitHub repo link \"%@\" - keeping previously saved repo, if any", linkRaw);
        }
    }

    NSString *tokenSanitized = zs_sanitize_personal_access_token(self.authTokenField.text ?: @"");
    config.authToken = tokenSanitized.length > 0 ? tokenSanitized : nil;
    self.authTokenField.text = tokenSanitized;

    NSError *error = nil;
    if (![ZTranscoderSettings saveConfig:config error:&error]) {
        ZLog(@"[UserInterface] Auth: failed to save ZTranscoder config: %@", error);
    }
}

- (void)zs_setAuthStatusLabelText:(NSString *)text color:(UIColor *)color {
    self.authStatusLabel.text = text ?: @"";
    self.authStatusLabel.textColor = color;
    self.authStatusLabel.hidden = (text.length == 0);
    if ([color isEqual:zs_accent_green_color()]) {
        zs_apply_gif_text_tint(self.authStatusLabel);
    } else {
        zs_remove_gif_text_tint(self.authStatusLabel);
    }
}

- (void)zs_setAuthFieldsLocked:(BOOL)locked {
    self.authRepoLinkField.enabled = !locked;
    self.authTokenField.enabled = !locked;

    UIColor *textColor = locked ? [UIColor colorWithWhite:1 alpha:0.35] : UIColor.whiteColor;
    self.authRepoLinkField.textColor = textColor;
    self.authTokenField.textColor = textColor;

    NSArray<UIView *> *fieldContainers = @[self.authRepoLinkFieldContainer, self.authTokenFieldContainer];
    for (UIView *container in fieldContainers) {
        if (!container) continue;
        container.alpha = locked ? 0.5 : 1.0;
        if (zs_has_liquid_glass() && [container isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)container).effect = zs_make_glass_effect(!locked);
        }
    }
}

- (void)zs_authEnterVerifiedState {
    self.authCredentialsStale = NO;
    self.authInRemoveMode = YES;
    [self zs_setAuthFieldsLocked:YES];

    [self.authVerifyButton removeTarget:self action:@selector(zs_authVerifyTapped:) forControlEvents:UIControlEventTouchUpInside];
    zs_remove_tap_to_confirm(self.authVerifyButton);
    __weak typeof(self) weakSelf = self;
    zs_attach_tap_to_confirm(self.authVerifyButton, self,
        @"Remove Credentials?", @"Your stored GitHub credentials will be removed from this device.", @"Remove", YES, ^{
        [weakSelf zs_authRemoveCredentialsConfirmed];
    });
    self.authVerifyButton.enabled = YES;
    zs_crossfade_auth_button_to_remove(self.authVerifyButton);

    [self zs_setAuthStatusLabelText:@"Credentials confirmed." color:zs_accent_green_color()];
    ZLog(@"[UserInterface] Auth: credentials verified");
}

- (void)zs_authEnterStaleState {
    self.authCredentialsStale = YES;
    self.authInRemoveMode = YES;
    [self zs_setAuthFieldsLocked:YES];

    [self.authVerifyButton removeTarget:self action:@selector(zs_authVerifyTapped:) forControlEvents:UIControlEventTouchUpInside];
    zs_remove_tap_to_confirm(self.authVerifyButton);
    __weak typeof(self) weakSelf = self;
    zs_attach_tap_to_confirm(self.authVerifyButton, self,
        @"Remove Credentials?", @"Your stored GitHub credentials will be removed from this device.", @"Remove", YES, ^{
        [weakSelf zs_authRemoveCredentialsConfirmed];
    });
    self.authVerifyButton.enabled = YES;
    zs_crossfade_auth_button_to_remove(self.authVerifyButton);

    [self zs_setAuthStatusLabelText:@"Your credentials are no longer valid."
                               color:[UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]];
    ZLog(@"[UserInterface] Auth: stored credentials are no longer valid");
}

- (void)zs_authRemoveCredentialsConfirmed {
    NSError *error = nil;
    if (![ZTranscoderSettings clearAllWithError:&error]) {
        ZLog(@"[UserInterface] Auth: failed to wipe stored credentials: %@", error);
    } else {
        ZLog(@"[UserInterface] Auth: credentials removed");
    }

    self.authInRemoveMode = NO;
    self.authCredentialsStale = NO;
    zs_remove_tap_to_confirm(self.authVerifyButton);
    [self.authVerifyButton addTarget:self action:@selector(zs_authVerifyTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.authRepoLinkField.text = @"";
    self.authTokenField.text = @"";
    [self zs_setAuthFieldsLocked:NO];

    self.authVerifyButton.enabled = YES;
    zs_crossfade_auth_button_to_verify(self.authVerifyButton);

    [self zs_setAuthStatusLabelText:nil color:nil];
}

- (void)zs_authRunBootVerification {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [ZTranscoderService verifyCredentialsForConfig:config completion:^(BOOL valid, NSError *verifyError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (valid) {
            [strongSelf zs_authEnterVerifiedState];
        } else {
            [strongSelf zs_authEnterStaleState];
        }
    }];
}

#pragma mark Re-Encoding format

- (void)zs_reencodeFormatSelected:(NSString *)format {
    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    config.outputFormat = format;

    NSError *error = nil;
    if (![ZTranscoderSettings saveConfig:config error:&error]) {
        ZLog(@"[UserInterface] Config: failed to save Re-Encoding format: %@", error);
        return;
    }

    if (self.reencodeFormatButton) {
        zs_style_reencode_format_button(self.reencodeFormatButton, format);
    }

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

#pragma mark Custom Greeting Text

- (void)zs_customGreetingTextButtonTapped:(UIButton *)sender {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    NSString *currentText = zs_custom_greeting_text();

    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Custom Greeting Text"
                                                                      message:@"Overrides the greeting phrase shown on your own player card. Only visible on this device."
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Enter custom greeting";
        field.text = currentText;
        field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
        field.autocorrectionType = UITextAutocorrectionTypeDefault;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (currentText.length > 0) {
        [prompt addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            zs_set_custom_greeting_text(@"");
            zs_custom_greeting_marquee_label(self.customGreetingTextButton).text = zs_custom_greeting_button_title(@"");
        }]];
    }
    __weak typeof(self) weakSelf = self;
    [prompt addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *entered = prompt.textFields.firstObject.text ?: @"";
        zs_set_custom_greeting_text(entered);
        NSString *stored = zs_custom_greeting_text();
        zs_custom_greeting_marquee_label(weakSelf.customGreetingTextButton).text = zs_custom_greeting_button_title(stored);
    }]];
    [presenter presentViewController:prompt animated:YES completion:nil];
}

- (void)zs_reencodeFormatButtonTapped:(UIButton *)sender {
    if (self.reencodeDropdownOpen) {
        [self zs_closeReencodeDropdownAnimated:YES];
    } else {
        [self zs_openReencodeDropdown];
    }
}

- (void)zs_openReencodeDropdown {
    if (!self.reencodeFormatButton || !self.contentOverlay || self.reencodeDropdownOpen) return;

    NSArray<NSString *> *options = zs_reencode_format_options();
    if (options.count == 0) return;

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    NSString *currentFormat = config.outputFormat.length > 0 ? config.outputFormat : kZSDefaultReencodeFormat;

    CGRect collapsedFrame = [self.reencodeFormatButton convertRect:self.reencodeFormatButton.bounds
                                                              toView:self.contentOverlay];

    UIControl *scrim = [[UIControl alloc] initWithFrame:self.contentOverlay.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = UIColor.clearColor;
    [scrim addTarget:self action:@selector(zs_reencodeDropdownScrimTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentOverlay addSubview:scrim];
    self.reencodeDropdownScrim = scrim;

    UIView *overlay;
    UIVisualEffectView *glassOverlay = nil;
    if (zs_has_liquid_glass()) {
        glassOverlay = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(YES)];
        glassOverlay.frame = collapsedFrame;
        glassOverlay.clipsToBounds = YES;
        zs_configure_glass_corners(glassOverlay, kZSAuthFieldCornerRadius, NO);
        glassOverlay.layer.borderWidth = 1;
        glassOverlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        zs_register_suspendable_glass(glassOverlay);
        overlay = glassOverlay;
    } else {
        overlay = [[UIView alloc] initWithFrame:collapsedFrame];
        overlay.clipsToBounds = YES;
        overlay.layer.cornerRadius = kZSAuthFieldCornerRadius;
        overlay.layer.cornerCurve = kCACornerCurveContinuous;
        overlay.layer.borderWidth = 1;
        overlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;

        overlay.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.98];
    }
    [self.contentOverlay addSubview:overlay];
    self.reencodeDropdownOverlay = overlay;

    UIView *rowHost = glassOverlay ? glassOverlay.contentView : overlay;

    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        NSString *format = options[i];
        BOOL selected = [format isEqualToString:currentFormat];
        UIButton *optionButton = zs_make_reencode_dropdown_option_button(format, selected, i, self,
                                                                          @selector(zs_reencodeDropdownOptionTapped:));
        optionButton.frame = CGRectMake(0, i * kZSReencodeFieldHeight,
                                         CGRectGetWidth(collapsedFrame), kZSReencodeFieldHeight);

        optionButton.alpha = 0;
        [rowHost addSubview:optionButton];

        if (i > 0) {

            CGFloat hairline = 1.0 / MAX(UIScreen.mainScreen.scale, (CGFloat)1.0);
            UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, i * kZSReencodeFieldHeight - hairline,
                                                                        CGRectGetWidth(collapsedFrame), hairline)];
            divider.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.5];
            divider.alpha = 0;
            [rowHost addSubview:divider];
        }
    }

    self.reencodeFormatButton.hidden = YES;
    self.reencodeDropdownOpen = YES;

    CGFloat expandedHeight = kZSReencodeFieldHeight * options.count;
    CGRect expandedFrame = CGRectMake(CGRectGetMinX(collapsedFrame), CGRectGetMinY(collapsedFrame),
                                       CGRectGetWidth(collapsedFrame), expandedHeight);
    [UIView animateWithDuration:0.22
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        overlay.frame = expandedFrame;
        for (UIView *subview in rowHost.subviews) {
            subview.alpha = 1;
        }
    } completion:nil];

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_closeReencodeDropdownAnimated:(BOOL)animated {
    if (!self.reencodeDropdownOpen) return;

    UIView *overlay = self.reencodeDropdownOverlay;
    UIControl *scrim = self.reencodeDropdownScrim;
    self.reencodeDropdownOverlay = nil;
    self.reencodeDropdownScrim = nil;
    self.reencodeDropdownOpen = NO;

    CGRect collapsedFrame = [self.reencodeFormatButton convertRect:self.reencodeFormatButton.bounds
                                                              toView:self.contentOverlay];

    void (^finish)(void) = ^{
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
        self.reencodeFormatButton.hidden = NO;
    };

    if (!animated) {
        finish();
        return;
    }

    UIView *rowHost = [overlay isKindOfClass:[UIVisualEffectView class]]
        ? ((UIVisualEffectView *)overlay).contentView
        : overlay;
    for (UIView *subview in rowHost.subviews) {
        subview.alpha = 0;
    }

    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        overlay.frame = collapsedFrame;
    } completion:^(BOOL finished) {
        finish();
    }];
}

- (void)zs_reencodeDropdownOptionTapped:(UIButton *)sender {
    NSArray<NSString *> *options = zs_reencode_format_options();
    if (sender.tag < 0 || sender.tag >= (NSInteger)options.count) return;

    NSString *format = options[sender.tag];
    [self zs_reencodeFormatSelected:format];
    [self zs_closeReencodeDropdownAnimated:YES];
}

- (void)zs_reencodeDropdownScrimTapped:(UIControl *)sender {
    [self zs_closeReencodeDropdownAnimated:YES];
}

- (void)zs_authVerifyTapped:(UIButton *)sender {
    if (self.authInRemoveMode) return;

    [self zs_persistAuthFields];

    ZTranscoderConfig *config = [ZTranscoderSettings loadConfig];
    if (config.repoOwner.length == 0 || config.repoName.length == 0 || config.authToken.length == 0) {
        [self zs_presentModsAlertWithTitle:@"Auth Not Configured"
                                    message:@"Set a GitHub Repository Link and Personal Access Token above first."];
        return;
    }

    sender.enabled = NO;
    zs_crossfade_auth_verify_button_title(sender, @"Verifying\u2026");

    __weak typeof(self) weakSelf = self;
    [ZTranscoderService verifyCredentialsForConfig:config completion:^(BOOL valid, NSError *verifyError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (valid) {
            [strongSelf zs_authEnterVerifiedState];
        } else {
            sender.enabled = YES;
            zs_crossfade_auth_verify_button_title(sender, @"Verify");
            ZLog(@"[UserInterface] Auth: manual verification failed: %@", verifyError.localizedDescription ?: @"Couldn't verify the repository link and token.");
            [strongSelf zs_presentModsAlertWithTitle:@"Verification Failed"
                                              message:verifyError.localizedDescription ?: @"Couldn't verify the repository link and token."];
        }
    }];
}

- (void)zs_keyboardWillChangeFrame:(NSNotification *)note {
    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;

    CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect endFrameInWindow = [unityView convertRect:endFrame fromView:nil];
    self.zs_lastKeyboardFrame = endFrameInWindow;

    BOOL keyboardVisible = CGRectGetMinY(endFrameInWindow) < CGRectGetMaxY(unityView.bounds);
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    if (duration <= 0) duration = 0.25;

    if (self.zsFloatingField && keyboardVisible) {
        CGFloat bottomInset = CGRectGetHeight(unityView.bounds) - CGRectGetMinY(endFrameInWindow);
        self.zsFloatingFieldBottomConstraint.constant = -(bottomInset + 8);
        [UIView animateWithDuration:duration animations:^{
            [unityView layoutIfNeeded];
        }];
    } else if (self.zsFloatingField && !keyboardVisible) {
        [self.zsFloatingField resignFirstResponder];
    }
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField == self.authRepoLinkField || textField == self.authTokenField) {
        __weak typeof(self) weakSelf = self;
        __weak UITextField *weakField = textField;
        [self zs_presentFloatingTextFieldWithInitialText:textField.text
                                              placeholder:textField.placeholder
                                                   secure:textField.secureTextEntry
                                               completion:^(NSString * _Nullable trimmedText) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            __strong UITextField *strongField = weakField;
            if (!strongSelf || !strongField) return;
            strongField.text = trimmedText ?: @"";
            [strongSelf zs_persistAuthFields];
        }];
        return NO;
    }
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == self.zsFloatingField) {

        [self zs_commitFloatingField];
        return;
    }
}

#pragma mark Syslog blacklist

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.zsFloatingField) {

        [textField resignFirstResponder];
        return YES;
    }
    if (textField != self.syslogBlacklistField) return YES;

    NSString *raw = textField.text ?: @"";
    BOOL added = NO;
    for (NSString *piece in [raw componentsSeparatedByString:@","]) {
        NSString *term = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
        if (term.length == 0) continue;
        if (![self.syslogBlacklist containsObject:term]) added = YES;
        [self.syslogBlacklist addObject:term];
    }

    textField.text = @"";
    if (added) {
        g_syslogBlacklist = self.syslogBlacklist.array;
        [self zs_rebuildSyslogBlacklistEntries];
        [self zs_scheduleSave];
        [self reapplySyslogBlacklistFilter];
        ZLog(@"[UserInterface] syslog blacklist updated, now %lu term(s)", (unsigned long)self.syslogBlacklist.count);
    }
    [textField resignFirstResponder];
    return YES;
}

- (void)zs_rebuildSyslogBlacklistEntries {
    if (!self.syslogBlacklistEntriesStack) return;

    for (UIView *view in self.syslogBlacklistEntriesStack.arrangedSubviews) {
        [self.syslogBlacklistEntriesStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (self.syslogBlacklist.count == 0) {
        self.syslogBlacklistStatusLabel.text = @"NO TERMS";
        return;
    }

    self.syslogBlacklistStatusLabel.text = self.syslogBlacklist.count == 1
        ? @"1 TERM"
        : [NSString stringWithFormat:@"%lu TERMS", (unsigned long)self.syslogBlacklist.count];

    for (NSString *term in self.syslogBlacklist) {
        [self.syslogBlacklistEntriesStack addArrangedSubview:
            zs_make_blacklist_entry_row(term, self, @selector(zs_removeBlacklistEntryTapped:))];
    }
}

- (void)zs_removeBlacklistEntryTapped:(UIButton *)sender {
    NSString *term = objc_getAssociatedObject(sender, "zs_blacklistTerm");
    if (!term) return;

    [self.syslogBlacklist removeObject:term];
    g_syslogBlacklist = self.syslogBlacklist.array;
    [self zs_rebuildSyslogBlacklistEntries];
    [self zs_scheduleSave];
}

- (void)reapplySyslogBlacklistFilter {
    if (self.syslogLines.count == 0) return;
    NSIndexSet *toRemove = [self.syslogLines indexesOfObjectsPassingTest:^BOOL(NSString *line, NSUInteger idx, BOOL *stop) {
        return [self zs_syslogLineIsBlacklisted:line];
    }];
    if (toRemove.count == 0) return;
    [self.syslogLines removeObjectsAtIndexes:toRemove];
    [self zs_renderSyslogBuffer];
}

#pragma mark Pull tab

- (void)layoutPanelForWindow:(UIView *)unityView {
    if (!self.glassContainer || !self.panel || !self.handle) return;

    [self positionPanelAnimated:NO];

    if (self.contentOverlay) {
        [self.contentOverlay setNeedsLayout];
        [self.contentOverlay layoutIfNeeded];
    }

    if (self.docsPanel) {
        [unityView bringSubviewToFront:self.docsContentOverlay];
        if (self.contentOverlay) [unityView bringSubviewToFront:self.contentOverlay];
    }

    self.scrollView.contentInset = UIEdgeInsetsMake(unityView.safeAreaInsets.top + 12,
                                                    0,
                                                    unityView.safeAreaInsets.bottom + 12,
                                                    0);
    self.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;

    [self.glassContainer setNeedsLayout];
    [self.glassContainer layoutIfNeeded];
    [self.panel setNeedsLayout];
    [self.panel layoutIfNeeded];
    [self.scrollViewport setNeedsLayout];
    [self.scrollViewport layoutIfNeeded];

    [self zs_fillVisiblePanelSectionsWithHeadroom];

    [self installStaticContentFadeMask];
    [self zs_updateSliderGlassVisibility];
    [self layoutDocsPanelForWindow:unityView];

}

#pragma mark Scroll-linked slider glass

static const CGFloat kZSSliderGlassCullMargin = 0;

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self zs_fillVisiblePanelSectionsWithHeadroom];
    [self zs_updateSliderGlassVisibility];

    if (self.reencodeDropdownOpen) {
        [self zs_closeReencodeDropdownAnimated:NO];
    }
}

- (void)zs_updateSliderGlassVisibilityForArrangedSubviews:(NSArray<UIView *> *)arrangedSubviews containerHidden:(BOOL)containerHidden visibleRect:(CGRect)visibleRect {
    for (UIView *arranged in arrangedSubviews) {
        if (![arranged isKindOfClass:[ZSRow class]]) continue;
        ZSRow *row = (ZSRow *)arranged;
        if (!row.slider && !row.modeSlider && !row.wheelPicker) continue;

        BOOL onScreen = NO;
        if (!containerHidden && !row.hidden && row.window) {
            CGRect rowFrameInViewport = [row convertRect:row.bounds toView:self.scrollViewport];
            onScreen = !CGRectIsEmpty(rowFrameInViewport) && CGRectIntersectsRect(rowFrameInViewport, visibleRect);
        }

        if (row.slider) {
            [row.slider setGlassEnabled:onScreen];
            zs_set_gif_window_active(row.slider.fill, onScreen);
        } else if (row.modeSlider) {
            [row.modeSlider setGlassEnabled:onScreen];
            zs_set_gif_window_active(row.modeSlider.thumb, onScreen);
        } else {
            [row.wheelPicker setGlassEnabled:onScreen];
            zs_set_gif_window_active(row.wheelPicker.selectionPill, onScreen);
        }
    }
}

- (void)zs_updateSliderGlassVisibility {
    if (!zs_has_liquid_glass() || !self.stack || !self.scrollViewport) return;

    if (!self.panelOpen) {
        [self zs_updateSliderGlassVisibilityForArrangedSubviews:self.stack.arrangedSubviews containerHidden:YES visibleRect:CGRectZero];
        if (self.experimentalSectionContainer) {
            [self zs_updateSliderGlassVisibilityForArrangedSubviews:self.experimentalSectionContainer.arrangedSubviews containerHidden:YES visibleRect:CGRectZero];
        }
        return;
    }

    CGRect visibleRect = CGRectInset(self.scrollViewport.bounds, -kZSSliderGlassCullMargin, -kZSSliderGlassCullMargin);

    [self zs_updateSliderGlassVisibilityForArrangedSubviews:self.stack.arrangedSubviews containerHidden:NO visibleRect:visibleRect];
    if (self.experimentalSectionContainer) {
        [self zs_updateSliderGlassVisibilityForArrangedSubviews:self.experimentalSectionContainer.arrangedSubviews containerHidden:self.experimentalSectionContainer.hidden visibleRect:visibleRect];
    }
}

#pragma mark Content edge mask

- (void)installStaticContentFadeMask {
    if (!self.scrollViewport || CGRectIsEmpty(self.scrollViewport.bounds)) return;

    CAGradientLayer *mask = (CAGradientLayer *)self.scrollViewport.layer.mask;
    if (![mask isKindOfClass:[CAGradientLayer class]]) {
        mask = [CAGradientLayer layer];
        mask.startPoint = CGPointMake(0.5, 0);
        mask.endPoint = CGPointMake(0.5, 1);
        self.scrollViewport.layer.mask = mask;
    }

    CGFloat height = CGRectGetHeight(self.scrollViewport.bounds);
    CGFloat fadeFraction = height > 0 ? MIN(0.25, kContentFadeHeight / height) : 0;
    mask.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    mask.locations = @[@0, @(fadeFraction), @(1 - fadeFraction), @1];
    mask.frame = self.scrollViewport.bounds;
}

- (void)deviceOrientationChanged {
    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;
    [self zs_layoutTutorialForWindow:unityView];
    if (!self.panel) return;
    [self layoutPanelForWindow:unityView];
}

- (void)positionPanelAnimated:(BOOL)animated {
    UIView *unityView = zs_ui_host_view();
    if (!unityView || !self.glassContainer) return;

    CGFloat panelW = self.panelWidth > 0 ? self.panelWidth : kPanelWidth;
    BOOL docsVisible = self.docsPanelOpen && self.docsPanel != nil;
    CGFloat docsW = docsVisible ? (self.docsPanelWidth > 0 ? self.docsPanelWidth : panelW) : 0;
    CGFloat chromeWidth = kHandleWidth + docsW + panelW;
    CGFloat height = unityView.bounds.size.height;

    CGFloat targetX = unityView.bounds.size.width - chromeWidth;

    UIView *panelElement = self.panelGlass ?: self.panel;
    UIView *handleElement = self.handleGlass ?: self.handle;
    UIView *docsPanelElement = self.docsPanelGlass ?: self.docsPanel;

    void (^changes)(void) = ^{
        if (docsVisible) {
            self.docsContentOverlay.hidden = NO;
            self.docsPanelSeparator.hidden = NO;
        }

        CGRect dockFrame = CGRectMake(targetX, 0, chromeWidth, height);
        self.glassContainer.frame = dockFrame;

        handleElement.frame = CGRectMake(0,
                                          (height - kHandleHeight) * 0.5,
                                          kHandleWidth,
                                          kHandleHeight);

        CGRect docsFrameLocal = CGRectMake(kHandleWidth, 0, docsW, height);

        if (docsPanelElement) {
            CGFloat glassOverlap = docsW > 0 ? kZSDocsPanelGlassFillOverlap : 0;
            docsPanelElement.frame = CGRectMake(kHandleWidth, 0, docsW + glassOverlap, height);
        }

        panelElement.frame = CGRectMake(kHandleWidth + docsW, 0, panelW, height);

        if (self.docsPanelSeparator) {
            CGFloat hairline = 1.0 / MAX(unityView.traitCollection.displayScale, 1.0);
            self.docsPanelSeparator.frame = CGRectMake(kHandleWidth + docsW - hairline, 0, hairline, height);
            [self.glassContainerContent bringSubviewToFront:self.docsPanelSeparator];
        }

        if (self.panelGlass) {
            self.panel.frame = self.panelGlass.bounds;
        }
        if (self.handleGlass) {
            self.handle.frame = self.handleGlass.bounds;
        }
        if (self.docsPanel && self.docsPanelGlass) {
            self.docsPanel.frame = self.docsPanelGlass.bounds;
        }

        if (self.contentOverlay) {
            self.contentOverlay.frame = [panelElement convertRect:panelElement.bounds toView:unityView];
            self.contentOverlay.layer.cornerRadius = kPanelCornerRadiusMinimum;
            self.contentOverlay.layer.cornerCurve = kCACornerCurveContinuous;
        }
        if (self.docsContentOverlay && docsPanelElement) {
            self.docsContentOverlay.frame = [self.glassContainerContent convertRect:docsFrameLocal toView:unityView];
            self.docsContentOverlay.layer.cornerRadius = kPanelCornerRadiusMinimum;
            self.docsContentOverlay.layer.cornerCurve = kCACornerCurveContinuous;
        }

        [self zs_updateSliderGlassVisibility];
    };

    void (^completion)(BOOL) = ^(BOOL finished) {
        if (!docsVisible) {
            self.docsContentOverlay.hidden = YES;
            self.docsPanelSeparator.hidden = YES;
        }
    };

    if (!animated) {
        changes();
        completion(YES);
    } else {
        [UIView animateWithDuration:0.28
                              delay:0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.3
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes
                         completion:completion];
    }

    [self startPostFXReapply];
}

#pragma mark Post FX continuous reapply

- (void)startPostFXReapply {
    if (self.postFXReapplyTimer) return;
    self.postFXReapplyTimer = [NSTimer timerWithTimeInterval:kPostFXReapplyInterval
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        zs_reapply_post_fx();
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.postFXReapplyTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPostFXReapply {
    [self.postFXReapplyTimer invalidate];
    self.postFXReapplyTimer = nil;
}

#pragma mark Slider/switch/mode-slider actions

static void zs_update_value_label(ZSCapsuleSlider *slider) {
    UILabel *label = objc_getAssociatedObject(slider, "zs_valueLabel");
    NSString *(^format)(float) = objc_getAssociatedObject(slider, "zs_format");
    if (label && format) label.text = format(slider.value);
}

- (void)normalFpsChanged:(ZSCapsuleSlider *)slider {
    NSInteger fps = (NSInteger)roundf(slider.value);
    g_menuFPS = fps;
    self.normalFpsValueLabel.text = [NSString stringWithFormat:@"%d", (int)fps];
    [[FPS120Controller shared] setManualMenuFPS:fps];
    [self zs_scheduleSave];
}

- (void)combatFpsChanged:(ZSCapsuleSlider *)slider {
    NSInteger fps = (NSInteger)roundf(slider.value);
    g_combatFPS = fps;
    self.combatFpsValueLabel.text = [NSString stringWithFormat:@"%d", (int)fps];
    [[FPS120Controller shared] setManualCombatFPS:fps];
    [self zs_scheduleSave];
}

- (void)texModeChanged:(ZSModeSlider *)slider {
    int32_t engineValue = (int32_t)slider.selectedIndex;
    g_textureMip = engineValue;
    zs_set_texture_mip_limit(engineValue);
    [self zs_scheduleSave];
}

- (void)scaleChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    float scale = slider.value / 100.0f;
    g_renderScale = scale;
    if (![FPS120Controller shared].isInBattle) zs_apply_render_scale_for_battle_state(NO, YES);
    [self zs_scheduleSave];
}

- (void)battleScaleChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    float scale = slider.value / 100.0f;
    g_battleRenderScale = scale;
    if ([FPS120Controller shared].isInBattle) zs_apply_render_scale_for_battle_state(YES, YES);
    [self zs_scheduleSave];
}

- (void)msaaChanged:(ZSModeSlider *)slider {
    int32_t idx = (int32_t)slider.selectedIndex;
    g_msaaIndex = idx;
    int32_t v = zs_step_value(kMSAASteps, 4, (float)idx);
    zs_urp_set_int("set_msaaSampleCount", v);
    [self zs_scheduleSave];
}

- (void)hdrChanged:(UISwitch *)toggle {
    g_hdrOn = toggle.on;
    zs_urp_set_bool("set_supportsHDR", toggle.on);
    [self zs_scheduleSave];
}

- (void)manifestZeroingChanged:(UISwitch *)toggle {
    [PatchManifestNetwork setZeroAllEnabled:toggle.on];
}

- (void)overrideTutorialCompletionChanged:(UISwitch *)toggle {
    zs_set_tutorial_override_completion_enabled(toggle.on);
}

- (void)lz4hcCompressionChanged:(UISwitch *)toggle {
    [ZTranscoderService setUploadCompressionEnabled:toggle.on];
}

- (void)uidRedactorChanged:(UISwitch *)toggle {
    [UIDRedactor setEnabled:toggle.on];
}

- (void)disableLiquidGlassChanged:(UISwitch *)toggle {
    zs_set_liquid_glass_disabled_by_user(toggle.on);
    UIViewController *presenter = zs_key_window().rootViewController;
    if (presenter) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart Required"
                                                                         message:@"You must restart the app for the Liquid Glass changes to take effect."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        zs_add_restart_action(alert);
        [presenter presentViewController:alert animated:YES completion:nil];
    }
}

- (void)disableEnkephalinChanged:(UISwitch *)toggle {
    zs_set_enkephalin_disabled_by_user(toggle.on);
    zs_gif_tint_set_disabled(toggle.on);
}

- (void)nightlyReleasesEnabledChanged:(UISwitch *)toggle {
    zs_set_update_uses_nightly_releases(toggle.on);
    [self zs_beginUpdateCheck];
}

- (void)experimentalSettingsEnabledChanged:(UISwitch *)toggle {
    g_experimentalSettingsEnabled = toggle.on;
    self.experimentalSectionContainer.hidden = !toggle.on;

    if (toggle.on) {
        [self zs_fillVisiblePanelSectionsWithHeadroom];
    }

    [self.stack setNeedsLayout];
    [self.stack layoutIfNeeded];
    [self zs_updateSliderGlassVisibility];

    [self zs_scheduleSave];
    if (toggle.on) {
        [self zs_presentModsAlertWithTitle:@"Experimental Settings"
                                    message:@"Enabling experimental settings, while most of them do nothing -- some have the capability to break your game, use with extreme caution"];
    }
}

- (void)blurIntensityChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    g_blurIntensity = slider.value;
    zs_apply_motion_blur();
    [self zs_scheduleSave];
}

- (void)tonemapModeChanged:(ZSModeSlider *)slider {
    g_tonemapMode = (int32_t)slider.selectedIndex;
    zs_apply_tonemapping();
    [self zs_scheduleSave];
}

- (void)urpEffectValueChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    NSString *name = objc_getAssociatedObject(slider, "zs_urp_name");
    if (!name) return;
    g_urpValue[name] = @(slider.value);
    zs_apply_urp_post_effect(name);
    [self zs_scheduleSave];
}

- (void)cameraAAModeChanged:(ZSModeSlider *)slider {
    g_aaModeIndex = (int32_t)slider.selectedIndex;
    int32_t v = zs_step_value(kAAModeSteps, 4, (float)slider.selectedIndex);
    zs_camera_data_set_int("set_antialiasing", v);
    [self zs_scheduleSave];
}

- (void)cameraAAQualityChanged:(ZSModeSlider *)slider {
    g_aaQualityIndex = (int32_t)slider.selectedIndex;
    int32_t v = zs_step_value(kAAQualitySteps, 3, (float)slider.selectedIndex);
    zs_camera_data_set_int("set_antialiasingQuality", v);
    [self zs_scheduleSave];
}

- (void)cameraDitheringChanged:(UISwitch *)toggle {
    g_ditheringOn = toggle.on;
    zs_camera_data_set_bool("set_dithering", toggle.on);
    [self zs_scheduleSave];
}

#pragma mark Particles

- (void)particleAlignmentChanged:(ZSWheelPicker *)picker {
    g_expParticleAlignment = (int32_t)picker.selectedIndex;
    zs_apply_particle_key(@"ParticleAlignment");
    [self zs_scheduleSave];
}

- (void)particleRenderModeChanged:(ZSWheelPicker *)picker {
    g_expParticleRenderMode = (int32_t)picker.selectedIndex;
    zs_apply_particle_key(@"ParticleRenderMode");
    [self zs_scheduleSave];
}

- (void)particleSortModeChanged:(ZSWheelPicker *)picker {
    g_expParticleSortMode = (int32_t)picker.selectedIndex;
    zs_apply_particle_key(@"ParticleSortMode");
    [self zs_scheduleSave];
}

- (void)particleMinSizeChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    g_expParticleMinSize = slider.value;
    zs_apply_particle_key(@"ParticleMinSize");
    [self zs_scheduleSave];
}

- (void)particleMaxSizeChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    g_expParticleMaxSize = slider.value;
    zs_apply_particle_key(@"ParticleMaxSize");
    [self zs_scheduleSave];
}

- (void)particleFreeformChanged:(UISwitch *)toggle {
    g_expParticleFreeformStretching = toggle.on;
    zs_apply_particle_key(@"ParticleFreeformStretching");
    [self zs_scheduleSave];
}

- (void)particleCapEnabledChanged:(UISwitch *)toggle {
    g_expParticleMaxParticlesCapEnabled = toggle.on;
    zs_apply_particle_max_particles_cap();
    [self zs_scheduleSave];
}

- (void)particleCapChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    g_expParticleMaxParticlesCap = (int32_t)roundf(slider.value);
    zs_apply_particle_max_particles_cap();
    [self zs_scheduleSave];
}

#pragma mark Experimental

- (void)zs_beginUpdateCheck {
    ZSUpdateCheckMode mode = zs_update_check_mode();
    self.updateCheckMode = mode;
    self.updateAvailable = NO;

    zs_apply_update_label_style(self.updateStatusLabel, @"checking for updates", NO);
    self.updateStatusDot.hidden = YES;

    __weak typeof(self) weakSelf = self;
    [ZSUpdateChecker checkForUpdateWithMode:mode completion:^(ZSUpdateCheckResult result, NSString * _Nullable latestVersion) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.updateCheckMode != mode) return;

        BOOL updateAvailable = (result == ZSUpdateCheckResultUpdateAvailable);
        UIColor *dotColor = updateAvailable ? zs_accent_yellow_color() : zs_accent_green_color();

        strongSelf.updateAvailable = updateAvailable;
        strongSelf.updateLatestVersion = latestVersion;

        NSString *subtext;
        if (mode == ZSUpdateCheckModeNightlyReleases) {
            subtext = updateAvailable ? @"A new nightly build is available" : @"Nightly build is up to date";
        } else {
            subtext = updateAvailable ? @"A new update is available" : @"Version is up to date";
        }

        zs_apply_update_label_style(strongSelf.updateStatusLabel, subtext, updateAvailable);
        strongSelf.updateStatusDot.backgroundColor = dotColor;
        strongSelf.updateStatusDot.layer.shadowColor = dotColor.CGColor;
        strongSelf.updateStatusDot.hidden = NO;
    }];
}

- (void)updateStatusLabelTapped:(UITapGestureRecognizer *)recognizer {
    if (!self.updateAvailable) return;
    [self zs_showReleaseInfoWithMode:self.updateCheckMode index:0];
}

- (void)updateStatusLabelLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    [self zs_showReleaseInfoWithMode:self.updateCheckMode index:0];
}

- (NSAttributedString *)zs_releaseInfoLoadingOrErrorStringWithText:(NSString *)text {
    return [[NSAttributedString alloc] initWithString:text
        attributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular],
                      NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55]}];
}

static BOOL zs_release_notes_disable_on_device_install(NSString *notesMarkdown) {
    if (notesMarkdown.length == 0) return NO;
    return [notesMarkdown containsString:@"AllowOnDeviceUpdate=false"];
}

static NSString *zs_docs_release_header_title(ZSUpdateCheckMode mode, NSString * _Nullable version) {
    if (mode == ZSUpdateCheckModeNightlyReleases) {
        NSString *buildDigits = [version stringByReplacingOccurrencesOfString:@"build " withString:@""];
        NSString *buildPart = buildDigits.length > 0 ? buildDigits : @"\u2026";
        return [NSString stringWithFormat:@"Nightly: build %@", buildPart];
    }
    return [NSString stringWithFormat:@"Release: %@", version.length > 0 ? version : @"\u2026"];
}

- (void)zs_setDocsUpdateActionsVisible:(BOOL)visible {
    self.docsUpdateActionsStack.hidden = !visible;
}

- (void)zs_configureReleaseInfoActionsWithMode:(ZSUpdateCheckMode)mode disabled:(BOOL)disabled releaseURLString:(NSString * _Nullable)releaseURLString {
    objc_setAssociatedObject(self.docsLiveContainerInstallButton, "zs_updateMode", @(mode), OBJC_ASSOCIATION_RETAIN);

    BOOL liveContainerAvailable = [ZSDylibUpdater isRunningUnderLiveContainer];

    self.docsLiveContainerInstallButton.hidden = NO;

    BOOL liveContainerGreyedOut = disabled || !liveContainerAvailable;
    zs_set_install_option_greyed_out(self.docsLiveContainerInstallButton, liveContainerGreyedOut);

    NSString *disabledNoteText = nil;
    if (disabled) {
        disabledNoteText = @"On-device install disabled for this release.";
    } else if (liveContainerGreyedOut) {
        disabledNoteText = @"Not in a LiveContainer Instance.";
    }
    self.docsUpdateActionsDisabledNoteLabel.text = disabledNoteText;
    self.docsUpdateActionsDisabledNoteLabel.hidden = (disabledNoteText.length == 0);

    NSString *fallbackRepoURLString = [NSString stringWithFormat:@"https://github.com/%@/%@", kZSUpdateRepoOwner, kZSUpdateRepoName];
    NSURL *releaseURL = releaseURLString.length > 0 ? [NSURL URLWithString:releaseURLString] : nil;
    if (!releaseURL) releaseURL = [NSURL URLWithString:fallbackRepoURLString];
    objc_setAssociatedObject(self.docsGitHubReleaseLinkButton, "zs_releaseRepoURL", releaseURL, OBJC_ASSOCIATION_RETAIN);

    UIFont *repoLinkFont = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    UIColor *repoLinkColor = [UIColor colorWithRed:0.55 green:0.75 blue:1.0 alpha:1.0];
    NSAttributedString *repoTitle = [[NSAttributedString alloc] initWithString:@"View GitHub release"
        attributes:@{NSFontAttributeName: repoLinkFont,
                      NSForegroundColorAttributeName: repoLinkColor,
                      NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)}];
    [self.docsGitHubReleaseLinkButton setAttributedTitle:repoTitle forState:UIControlStateNormal];

    [self zs_setDocsUpdateActionsVisible:YES];
}

- (void)docsLiveContainerInstallTapped:(UIButton *)sender {
    NSNumber *modeNumber = objc_getAssociatedObject(sender, "zs_updateMode");
    ZSUpdateCheckMode mode = modeNumber ? (ZSUpdateCheckMode)modeNumber.integerValue : ZSUpdateCheckModeReleases;
    [self zs_confirmAndReplaceInstalledDylibWithMode:mode];
}

- (void)docsGitHubReleaseLinkTapped:(UIButton *)sender {
    NSURL *url = objc_getAssociatedObject(sender, "zs_releaseRepoURL");
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)docsHeaderModeChevronTapped:(UIButton *)sender {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Update Channel"
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"Release" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self zs_showReleaseInfoWithMode:ZSUpdateCheckModeReleases index:0];
    }]];

    if (zs_update_uses_nightly_releases()) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Nightly" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self zs_showReleaseInfoWithMode:ZSUpdateCheckModeNightlyReleases index:0];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    alert.popoverPresentationController.sourceView = sender;
    alert.popoverPresentationController.sourceRect = sender.bounds;

    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)docsLanguageButtonTapped:(UIButton *)sender {
    if (self.docsLanguageDropdownOpen) {
        [self zs_closeDocsLanguageDropdownAnimated:YES];
    } else {
        [self zs_openDocsLanguageDropdown];
    }
}

- (void)zs_openDocsLanguageDropdown {
    if (!self.docsLanguageButton || !self.docsContentOverlay || self.docsLanguageDropdownOpen) return;

    NSArray<NSDictionary<NSString *, NSString *> *> *options = zs_docs_language_options();
    if (options.count == 0) return;

    NSString *currentCode = zs_docs_current_language();

    CGRect buttonFrame = [self.docsLanguageButton convertRect:self.docsLanguageButton.bounds toView:self.docsContentOverlay];
    CGFloat dropdownWidth = kZSDocsLanguageDropdownWidth;
    CGFloat rowHeight = kZSReencodeFieldHeight;
    CGFloat dropdownHeight = rowHeight * options.count;

    CGFloat originX = CGRectGetMaxX(buttonFrame) - dropdownWidth;
    originX = MIN(originX, CGRectGetWidth(self.docsContentOverlay.bounds) - dropdownWidth - kPanelPadding);
    originX = MAX(originX, kPanelPadding);
    CGFloat originY = CGRectGetMaxY(buttonFrame) + 6;
    CGRect dropdownFrame = CGRectMake(originX, originY, dropdownWidth, dropdownHeight);

    UIControl *scrim = [[UIControl alloc] initWithFrame:self.docsContentOverlay.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = UIColor.clearColor;
    [scrim addTarget:self action:@selector(zs_docsLanguageDropdownScrimTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.docsContentOverlay addSubview:scrim];
    self.docsLanguageDropdownScrim = scrim;

    UIView *overlay;
    UIVisualEffectView *glassOverlay = nil;
    if (zs_has_liquid_glass()) {
        glassOverlay = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(YES)];
        glassOverlay.frame = dropdownFrame;
        glassOverlay.clipsToBounds = YES;
        zs_configure_glass_corners(glassOverlay, kZSAuthFieldCornerRadius, NO);
        glassOverlay.layer.borderWidth = 1;
        glassOverlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        zs_register_suspendable_glass(glassOverlay);
        overlay = glassOverlay;
    } else {
        overlay = [[UIView alloc] initWithFrame:dropdownFrame];
        overlay.clipsToBounds = YES;
        overlay.layer.cornerRadius = kZSAuthFieldCornerRadius;
        overlay.layer.cornerCurve = kCACornerCurveContinuous;
        overlay.layer.borderWidth = 1;
        overlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        overlay.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.98];
    }
    [self.docsContentOverlay addSubview:overlay];
    self.docsLanguageDropdownOverlay = overlay;

    UIView *rowHost = glassOverlay ? glassOverlay.contentView : overlay;

    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        NSDictionary<NSString *, NSString *> *option = options[i];
        BOOL selected = [option[@"code"] isEqualToString:currentCode];
        UIButton *optionButton = zs_make_docs_language_option_button(option, selected, i, self,
                                                                       @selector(zs_docsLanguageDropdownOptionTapped:));
        optionButton.frame = CGRectMake(0, i * rowHeight, dropdownWidth, rowHeight);
        optionButton.alpha = 0;
        [rowHost addSubview:optionButton];

        if (i > 0) {
            CGFloat hairline = 1.0 / MAX(UIScreen.mainScreen.scale, (CGFloat)1.0);
            UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, i * rowHeight - hairline, dropdownWidth, hairline)];
            divider.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.5];
            divider.alpha = 0;
            [rowHost addSubview:divider];
        }
    }

    self.docsLanguageDropdownOpen = YES;
    overlay.alpha = 0;
    overlay.transform = CGAffineTransformMakeScale(0.92, 0.92);

    [UIView animateWithDuration:0.2
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        overlay.alpha = 1;
        overlay.transform = CGAffineTransformIdentity;
        for (UIView *subview in rowHost.subviews) {
            subview.alpha = 1;
        }
    } completion:nil];

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_closeDocsLanguageDropdownAnimated:(BOOL)animated {
    if (!self.docsLanguageDropdownOpen) return;

    UIView *overlay = self.docsLanguageDropdownOverlay;
    UIControl *scrim = self.docsLanguageDropdownScrim;
    self.docsLanguageDropdownOverlay = nil;
    self.docsLanguageDropdownScrim = nil;
    self.docsLanguageDropdownOpen = NO;

    void (^finish)(void) = ^{
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
    };

    if (!animated) {
        finish();
        return;
    }

    [UIView animateWithDuration:0.16
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        overlay.alpha = 0;
        overlay.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } completion:^(BOOL finished) {
        finish();
    }];
}

- (void)zs_docsLanguageDropdownOptionTapped:(UIButton *)sender {
    NSArray<NSDictionary<NSString *, NSString *> *> *options = zs_docs_language_options();
    if (sender.tag < 0 || sender.tag >= (NSInteger)options.count) return;

    NSString *code = options[sender.tag][@"code"];
    [self zs_docsLanguageSelected:code];
    [self zs_closeDocsLanguageDropdownAnimated:YES];
}

- (void)zs_docsLanguageDropdownScrimTapped:(UIControl *)sender {
    [self zs_closeDocsLanguageDropdownAnimated:YES];
}

- (void)zs_docsLanguageSelected:(NSString *)code {
    if ([code isEqualToString:zs_docs_current_language()]) return;
    zs_docs_set_current_language(code);

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];

    NSString *key = self.docsActiveKey;
    if (key.length > 0 && ![key isEqualToString:kZSReleaseInfoDocsKey]) {
        [self showDocsForKey:key];
    }
}

- (void)docsSubheaderOlderReleaseTapped:(UIButton *)sender {
    if (!sender.enabled) return;
    [self zs_showReleaseInfoWithMode:self.docsReleaseViewMode index:(self.docsReleaseHistoryIndex + 1)];
}

- (void)docsSubheaderNewerReleaseTapped:(UIButton *)sender {
    if (!sender.enabled || self.docsReleaseHistoryIndex == 0) return;
    [self zs_showReleaseInfoWithMode:self.docsReleaseViewMode index:(self.docsReleaseHistoryIndex - 1)];
}

- (void)zs_showReleaseInfoWithMode:(ZSUpdateCheckMode)mode index:(NSUInteger)index {
    if (!self.panelOpen) return;

    NSString *key = kZSReleaseInfoDocsKey;
    self.docsActiveKey = key;
    self.docsReleaseViewMode = mode;
    self.docsReleaseHistoryIndex = index;

    NSString *placeholderVersion = (mode == self.updateCheckMode && index == 0) ? self.updateLatestVersion : nil;
    self.docsTitleLabel.text = zs_docs_release_header_title(mode, placeholderVersion);
    [self zs_setDocsSubheaderText:@"What's New"];
    [self zs_setDocsHeaderChevronVisible:YES];
    [self zs_setDocsLanguageButtonVisible:NO];
    [self zs_setDocsSubheaderArrowsVisible:(mode == ZSUpdateCheckModeReleases) hasOlder:NO atLatest:(index == 0)];

    CGFloat docsContentWidth = (self.docsPanelWidth > 0 ? self.docsPanelWidth : self.panelWidth) - (kPanelPadding * 2);
    self.docsBodyLabel.attributedText = [self zs_releaseInfoLoadingOrErrorStringWithText:@"Loading release info\u2026"];
    [self zs_setDocsUpdateActionsVisible:NO];
    self.docsScrollView.contentOffset = CGPointZero;

    __weak typeof(self) weakSelf = self;
    [ZSUpdateChecker fetchReleaseInfoAtIndex:index mode:mode completion:^(ZSReleaseInfo * _Nullable info, BOOL hasOlder, BOOL hasNewer, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf.docsPanelOpen || ![strongSelf.docsActiveKey isEqualToString:key]) return;
        if (strongSelf.docsReleaseViewMode != mode || strongSelf.docsReleaseHistoryIndex != index) return;

        if (!info) {
            strongSelf.docsBodyLabel.attributedText = [strongSelf
                zs_releaseInfoLoadingOrErrorStringWithText:@"Couldn't load release info. Check your connection and try again."];
            [strongSelf zs_setDocsUpdateActionsVisible:NO];
            return;
        }

        strongSelf.docsTitleLabel.text = zs_docs_release_header_title(mode, info.version);
        [strongSelf zs_setDocsSubheaderArrowsVisible:(mode == ZSUpdateCheckModeReleases) hasOlder:hasOlder atLatest:(index == 0)];

        NSString *bodyMarkdown = info.notesMarkdown.length > 0 ? info.notesMarkdown : @"No release notes provided.";
        strongSelf.docsBodyLabel.attributedText = zs_render_markdown(bodyMarkdown, docsContentWidth);

        if (index == 0) {
            strongSelf.updateOnDeviceInstallDisabled = zs_release_notes_disable_on_device_install(info.notesMarkdown);
            [strongSelf zs_configureReleaseInfoActionsWithMode:mode disabled:strongSelf.updateOnDeviceInstallDisabled releaseURLString:info.htmlURL];
        } else {
            [strongSelf zs_setDocsUpdateActionsVisible:NO];
        }
    }];

    if (self.docsPanelOpen) return;

    self.docsPanelOpen = YES;
    [self positionPanelAnimated:YES];
    [UIView animateWithDuration:0.2 animations:^{
        self.chevron.text = @"\u2715";
    }];
}

- (UIAlertController *)zs_presentDylibInstallWorkingAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIViewController *presenter = zs_key_window().rootViewController;
    UIAlertController *working = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [working.view addSubview:spinner];
    [spinner startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:working.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:working.view.bottomAnchor constant:-16],
    ]];
    if (presenter) [presenter presentViewController:working animated:YES completion:nil];
    return working;
}

- (void)zs_dismissDylibInstallWorkingAlert:(UIAlertController *)working thenRun:(void (^)(void))block {
    if (working.presentingViewController) {
        [working dismissViewControllerAnimated:YES completion:block];
    } else if (block) {
        block();
    }
}

- (void)zs_confirmAndReplaceInstalledDylibWithMode:(ZSUpdateCheckMode)mode {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    if (self.updateOnDeviceInstallDisabled) {
        [self zs_presentModsAlertWithTitle:@"Install Disabled"
                                    message:@"On-device installation is disabled for this release."];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Install update?"
        message:@"This downloads the latest build and replaces it in this app's Tweaks folder."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Replace" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
        [weakSelf zs_performReplaceInstalledDylibWithMode:mode];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_performReplaceInstalledDylibWithMode:(ZSUpdateCheckMode)mode {
    UIAlertController *working = [self zs_presentDylibInstallWorkingAlertWithTitle:@"Replacing .dylib\u2026"
        message:@"Downloading & Installing update."];

    __weak typeof(self) weakSelf = self;
    [ZSUpdateChecker fetchLatestDylibDataWithMode:mode completion:^(NSData * _Nullable dylibData, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (!dylibData) {
            [strongSelf zs_dismissDylibInstallWorkingAlert:working thenRun:^{
                [strongSelf zs_presentModsAlertWithTitle:@"Replace Failed"
                                                  message:error.localizedDescription ?: @"Couldn't download the latest build."];
            }];
            return;
        }

        [ZSDylibUpdater replaceInstalledDylibWithData:dylibData completion:^(BOOL success, NSString *message) {
            [strongSelf zs_dismissDylibInstallWorkingAlert:working thenRun:^{
                UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
                [haptic notificationOccurred:success ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
                NSString *displayMessage = success ? @"Successfully Installed. Restart your game to load the new build." : message;
                [strongSelf zs_presentModsAlertWithTitle:success ? @"Dylib Replaced" : @"Replace Failed" message:displayMessage offersRestart:success];
            }];
        }];
    }];
}

- (void)expToggleChanged:(UISwitch *)toggle {
    NSString *key = objc_getAssociatedObject(toggle, @"zs_exp_key");
    if (!key) return;
    if ([key isEqualToString:@"LODCrossFade"]) g_expLODCrossFade = toggle.on;
    else if ([key isEqualToString:@"CameraHDR"]) g_expCameraHDR = toggle.on;
    else if ([key isEqualToString:@"CameraMSAA"]) g_expCameraMSAA = toggle.on;
    else if ([key isEqualToString:@"DynamicResolution"]) g_expDynamicResolution = toggle.on;
    else if ([key isEqualToString:@"OcclusionCulling"]) g_expOcclusionCulling = toggle.on;
    else if ([key isEqualToString:@"DepthTexture"]) g_expDepthTexture = toggle.on;
    else if ([key isEqualToString:@"OpaqueTexture"]) g_expOpaqueTexture = toggle.on;
    else if ([key isEqualToString:@"RenderShadows"]) g_expRenderShadows = toggle.on;
    else if ([key isEqualToString:@"PostProcessing"]) g_expPostProcessing = toggle.on;
    else if ([key isEqualToString:@"CameraDithering"]) g_expCameraDithering = toggle.on;
    else if ([key isEqualToString:@"CameraResetHistory"]) g_expCameraResetHistory = toggle.on;
    else if ([key isEqualToString:@"CameraStopNaN"]) g_expCameraStopNaN = toggle.on;
    else if ([key isEqualToString:@"CameraAllowXR"]) g_expCameraAllowXR = toggle.on;
    else if ([key isEqualToString:@"CameraScreenCoordOverride"]) g_expCameraScreenCoordOverride = toggle.on;
    else if ([key isEqualToString:@"CameraRequiresDepthTexture"]) g_expCameraRequiresDepthTexture = toggle.on;
    else if ([key isEqualToString:@"CameraRequiresColorTexture"]) g_expCameraRequiresColorTexture = toggle.on;
    else if ([key isEqualToString:@"CameraHDROutput"]) g_expCameraHDROutput = toggle.on;
    else if ([key isEqualToString:@"FSROverride"]) g_expFSROverride = toggle.on;
    else if ([key isEqualToString:@"URPHDR"]) g_expURPHDR = toggle.on;
    else if ([key isEqualToString:@"MainLightShadows"]) g_expMainLightShadows = toggle.on;
    else if ([key isEqualToString:@"AdditionalLightShadows"]) g_expAdditionalLightShadows = toggle.on;
    else if ([key isEqualToString:@"ReflectionProbeBlending"]) g_expReflectionProbeBlending = toggle.on;
    else if ([key isEqualToString:@"ReflectionProbeBoxProjection"]) g_expReflectionProbeBoxProjection = toggle.on;
    else if ([key isEqualToString:@"ReflectionProbeAtlas"]) g_expReflectionProbeAtlas = toggle.on;
    else if ([key isEqualToString:@"ProbeVolumeStreaming"]) g_expProbeVolumeStreaming = toggle.on;
    else if ([key isEqualToString:@"ProbeVolumeGPUStreaming"]) g_expProbeVolumeGPUStreaming = toggle.on;
    else if ([key isEqualToString:@"ProbeVolumeDiskStreaming"]) g_expProbeVolumeDiskStreaming = toggle.on;
    else if ([key isEqualToString:@"ProbeVolumeScenarios"]) g_expProbeVolumeScenarios = toggle.on;
    else if ([key isEqualToString:@"ProbeVolumeScenarioBlending"]) g_expProbeVolumeScenarioBlending = toggle.on;
    else if ([key isEqualToString:@"SoftShadows"]) g_expSoftShadows = toggle.on;
    else if ([key isEqualToString:@"DynamicBatching"]) g_expDynamicBatching = toggle.on;
    else if ([key isEqualToString:@"SRPBatcher"]) g_expSRPBatcher = toggle.on;
    else if ([key isEqualToString:@"GraphicsSRPBatching"]) g_expGraphicsSRPBatching = toggle.on;
    else if ([key isEqualToString:@"GPUResidentOcclusion"]) g_expGPUResidentOcclusion = toggle.on;
    else if ([key isEqualToString:@"ConservativeEnclosingSphere"]) g_expConservativeEnclosingSphere = toggle.on;
    else if ([key isEqualToString:@"AdaptivePerformance"]) g_expAdaptivePerformance = toggle.on;
    else if ([key isEqualToString:@"APSkipDynamicBatching"]) g_expAPSkipDynamicBatching = toggle.on;
    else if ([key isEqualToString:@"APSkipFrontToBackSorting"]) g_expAPSkipFrontToBackSorting = toggle.on;
    else if ([key isEqualToString:@"APSkipTransparentObjects"]) g_expAPSkipTransparentObjects = toggle.on;
    else if ([key isEqualToString:@"AnimatorKeepControllerStateOnDisable"]) g_expAnimatorKeepControllerStateOnDisable = toggle.on;
    else if ([key isEqualToString:@"AnimatorKeepStateOnDisable"]) g_expAnimatorKeepStateOnDisable = toggle.on;
    else if ([key isEqualToString:@"AnimatorApplyRootMotion"]) g_expAnimatorApplyRootMotion = toggle.on;
    else if ([key isEqualToString:@"AnimatorLinearVelocityBlending"]) g_expAnimatorLinearVelocityBlending = toggle.on;
    else if ([key isEqualToString:@"AnimatorAnimatePhysics"]) g_expAnimatorAnimatePhysics = toggle.on;
    else if ([key isEqualToString:@"AnimatorConstantClipSamplingOptimization"]) g_expAnimatorConstantClipSamplingOptimization = toggle.on;
    else if ([key isEqualToString:@"AnimatorStabilizeFeet"]) g_expAnimatorStabilizeFeet = toggle.on;
    else if ([key isEqualToString:@"AnimatorLogWarnings"]) g_expAnimatorLogWarnings = toggle.on;
    else if ([key isEqualToString:@"AnimatorFireEvents"]) g_expAnimatorFireEvents = toggle.on;
    else if ([key isEqualToString:@"AnimatorWriteDefaultValuesOnDisable"]) g_expAnimatorWriteDefaultValuesOnDisable = toggle.on;
    else if ([key isEqualToString:@"ParticleGPUInstancing"]) g_expParticleGPUInstancing = toggle.on;
    else if ([key isEqualToString:@"ParticleAllowRoll"]) g_expParticleAllowRoll = toggle.on;
    else if ([key isEqualToString:@"ParticleFreeformStretching"]) g_expParticleFreeformStretching = toggle.on;
    else if ([key isEqualToString:@"ParticleRotateWithStretchDirection"]) g_expParticleRotateWithStretchDirection = toggle.on;
    else if ([key isEqualToString:@"ParticleApplyActiveColorSpace"]) g_expParticleApplyActiveColorSpace = toggle.on;
    else if ([key isEqualToString:@"ParticleMaxParticlesCapEnabled"]) g_expParticleMaxParticlesCapEnabled = toggle.on;
    else if ([key isEqualToString:@"LightsUseLinearIntensity"]) g_expLightsUseLinearIntensity = toggle.on;
    else if ([key isEqualToString:@"LightsUseColorTemperature"]) g_expLightsUseColorTemperature = toggle.on;
    else if ([key isEqualToString:@"BurstCompilation"]) g_expBurstCompilation = toggle.on;
    else if ([key isEqualToString:@"BurstSafetyChecks"]) g_expBurstSafetyChecks = toggle.on;
    else if ([key isEqualToString:@"RigidbodyDetectCollisions"]) g_expRigidbodyDetectCollisions = toggle.on;
    else if ([key isEqualToString:@"AdaptivePhysics"]) g_expAdaptivePhysics = toggle.on;
    zs_exp_apply_key(key);
    [self zs_scheduleSave];
}

- (void)expSliderChanged:(ZSCapsuleSlider *)slider {
    NSString *key = objc_getAssociatedObject(slider, @"zs_exp_key");
    if (!key) return;
    zs_update_value_label(slider);
    float v = slider.value;
    if ([key isEqualToString:@"PixelLightCount"]) g_expPixelLightCount = (int32_t)roundf(v);
    else if ([key isEqualToString:@"LODBias"]) g_expLODBias = v;
    else if ([key isEqualToString:@"FSRSharpness"]) g_expFSRSharpness = v;
    else if ([key isEqualToString:@"MaxAdditionalLights"]) g_expMaxAdditionalLights = (int32_t)roundf(v);
    else if ([key isEqualToString:@"ShadowDistance"]) g_expShadowDistance = v;
    else if ([key isEqualToString:@"CascadeBorder"]) g_expCascadeBorder = v;
    else if ([key isEqualToString:@"Cascade2Split"]) g_expCascade2Split = v;
    else if ([key isEqualToString:@"Cascade3SplitX"]) g_expCascade3SplitX = v;
    else if ([key isEqualToString:@"Cascade3SplitY"]) g_expCascade3SplitY = v;
    else if ([key isEqualToString:@"Cascade4SplitX"]) g_expCascade4SplitX = v;
    else if ([key isEqualToString:@"Cascade4SplitY"]) g_expCascade4SplitY = v;
    else if ([key isEqualToString:@"Cascade4SplitZ"]) g_expCascade4SplitZ = v;
    else if ([key isEqualToString:@"ShadowDepthBias"]) g_expShadowDepthBias = v;
    else if ([key isEqualToString:@"ShadowNormalBias"]) g_expShadowNormalBias = v;
    else if ([key isEqualToString:@"SmallMeshScreenPercentage"]) g_expSmallMeshScreenPercentage = v;
    else if ([key isEqualToString:@"ParticleLengthScale"]) g_expParticleLengthScale = v;
    else if ([key isEqualToString:@"ParticleVelocityScale"]) g_expParticleVelocityScale = v;
    else if ([key isEqualToString:@"ParticleCameraVelocityScale"]) g_expParticleCameraVelocityScale = v;
    else if ([key isEqualToString:@"ParticleNormalDirection"]) g_expParticleNormalDirection = v;
    else if ([key isEqualToString:@"ParticleShadowBias"]) g_expParticleShadowBias = v;
    else if ([key isEqualToString:@"ParticleSortingFudge"]) g_expParticleSortingFudge = v;
    else if ([key isEqualToString:@"ParticleMinSize"]) g_expParticleMinSize = v;
    else if ([key isEqualToString:@"ParticleMaxSize"]) g_expParticleMaxSize = v;
    else if ([key isEqualToString:@"ParticleMaxParticlesCap"]) g_expParticleMaxParticlesCap = (int32_t)roundf(v);
    else if ([key isEqualToString:@"AnimatorSpeed"]) g_expAnimatorSpeed = v;
    else if ([key isEqualToString:@"NumIterationsEnclosingSphere"]) g_expNumIterationsEnclosingSphere = (int32_t)roundf(v);
    else if ([key isEqualToString:@"APMaxShadowDistanceMultiplier"]) g_expAPMaxShadowDistanceMultiplier = v;
    else if ([key isEqualToString:@"APShadowmapResolutionMultiplier"]) g_expAPShadowmapResolutionMultiplier = v;
    else if ([key isEqualToString:@"APRenderScaleMultiplier"]) {
        g_expAPRenderScaleMultiplier = v;
        if (fabsf(v - zs_exp_get_default_number(@"APRenderScaleMultiplier")) > kDefaultValueEpsilon && !g_expAdaptivePerformance) {
            g_expAdaptivePerformance = YES;
            self.expAdaptivePerformanceToggle.on = YES;
            zs_exp_apply_key(@"AdaptivePerformance");
        }
    }
    else if ([key isEqualToString:@"APDecalsDrawDistance"]) g_expAPDecalsDrawDistance = v;
    else if ([key isEqualToString:@"APLutBias"]) g_expAPLutBias = v;
    else if ([key isEqualToString:@"RigidbodySleepThreshold"]) g_expRigidbodySleepThreshold = v;
    else if ([key isEqualToString:@"RigidbodyMaxAngularVelocity"]) g_expRigidbodyMaxAngularVelocity = v;
    else if ([key isEqualToString:@"RigidbodyMaxLinearVelocity"]) g_expRigidbodyMaxLinearVelocity = v;
    else if ([key isEqualToString:@"Rigidbody2DLinearDamping"]) g_expRigidbody2DLinearDamping = v;
    else if ([key isEqualToString:@"Rigidbody2DAngularDamping"]) g_expRigidbody2DAngularDamping = v;
    else if ([key isEqualToString:@"Rigidbody2DGravityScale"]) g_expRigidbody2DGravityScale = v;
    zs_exp_apply_key(key);
    [self zs_scheduleSave];
}

- (void)expModeChanged:(ZSModeSlider *)slider {
    NSString *key = objc_getAssociatedObject(slider, @"zs_exp_key");
    if (!key) return;
    NSInteger i = slider.selectedIndex;
    if ([key isEqualToString:@"VSyncCount"]) g_expVSyncCount = (int32_t)i;
    else if ([key isEqualToString:@"QualityAA"]) g_expQualityAA = (i==0?1:(i==1?2:(i==2?4:8)));
    else if ([key isEqualToString:@"AntialiasingMode"]) g_expAntialiasingMode = (int32_t)i;
    else if ([key isEqualToString:@"AntialiasingQuality"]) g_expAntialiasingQuality = (int32_t)i;
    else if ([key isEqualToString:@"UpscalingFilter"]) g_expUpscalingFilter = (int32_t)i;
    else if ([key isEqualToString:@"RenderTextureMemorylessMode"]) {
        g_expRenderTextureMemorylessMode = (i==0?0:(i==1?2:(i==2?4:6)));
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(zs_applyRenderTextureMemorylessDeferred) object:nil];
        [self performSelector:@selector(zs_applyRenderTextureMemorylessDeferred) withObject:nil afterDelay:0.25];
        [self zs_scheduleSave];
        return;
    }
    else if ([key isEqualToString:@"URPMSAA"]) g_expURPMSAA = (i==0?1:(i==1?2:(i==2?4:8)));
    else if ([key isEqualToString:@"StoreActionsOptimization"]) g_expStoreActionsOptimization = (int32_t)i;
    else if ([key isEqualToString:@"IntermediateTextureMode"]) g_expIntermediateTextureMode = (int32_t)i;
    else if ([key isEqualToString:@"MainLightMode"]) g_expMainLightMode = (int32_t)i;
    else if ([key isEqualToString:@"MainShadowResolution"]) g_expMainShadowResolution = (i==0?512:(i==1?1024:(i==2?2048:4096)));
    else if ([key isEqualToString:@"AdditionalLightMode"]) g_expAdditionalLightMode = (int32_t)i;
    else if ([key isEqualToString:@"AdditionalShadowResolution"]) g_expAdditionalShadowResolution = (i==0?256:(i==1?512:(i==2?1024:2048)));
    else if ([key isEqualToString:@"ShadowCascades"]) g_expShadowCascades = (i==0?0:(i==1?1:2));
    else if ([key isEqualToString:@"ShadowCascadeOption"]) g_expShadowCascadeOption = (int32_t)i;
    else if ([key isEqualToString:@"ColorGradingMode"]) g_expColorGradingMode = (int32_t)i;
    else if ([key isEqualToString:@"ColorGradingLUTSize"]) g_expColorGradingLUTSize = (i==0?16:(i==1?32:(i==2?48:64)));
    else if ([key isEqualToString:@"GPUResidentDrawerMode"]) g_expGPUResidentDrawerMode = (int32_t)i;
    else if ([key isEqualToString:@"ShaderVariantLogLevel"]) g_expShaderVariantLogLevel = (int32_t)i;
    else if ([key isEqualToString:@"APShadowCascadesBias"]) g_expAPShadowCascadesBias = (int32_t)i;
    else if ([key isEqualToString:@"APShadowQualityBias"]) g_expAPShadowQualityBias = (int32_t)i;
    else if ([key isEqualToString:@"APAntiAliasingQualityBias"]) g_expAPAntiAliasingQualityBias = (int32_t)i;
    else if ([key isEqualToString:@"RigidbodySolverIterations"]) g_expRigidbodySolverIterations = MAX(1, (int32_t)i + 1);
    else if ([key isEqualToString:@"RigidbodySolverVelocityIterations"]) g_expRigidbodySolverVelocityIterations = MAX(1, (int32_t)i + 1);
    else if ([key isEqualToString:@"RigidbodyInterpolation"]) g_expRigidbodyInterpolation = (int32_t)i;
    else if ([key isEqualToString:@"Rigidbody2DInterpolation"]) g_expRigidbody2DInterpolation = (int32_t)i;
    else if ([key isEqualToString:@"Rigidbody2DSleepMode"]) g_expRigidbody2DSleepMode = (int32_t)i;
    else if ([key isEqualToString:@"Rigidbody2DCollisionDetectionMode"]) g_expRigidbody2DCollisionDetectionMode = (int32_t)i;
    else if ([key isEqualToString:@"CameraRequiresDepthOption"]) g_expCameraRequiresDepthOption = (int32_t)i;
    else if ([key isEqualToString:@"CameraRequiresColorOption"]) g_expCameraRequiresColorOption = (int32_t)i;
    else if ([key isEqualToString:@"CameraRenderType"]) g_expCameraRenderType = (int32_t)i;
    else if ([key isEqualToString:@"ShEvalMode"]) g_expShEvalMode = (int32_t)i;
    else if ([key isEqualToString:@"LightProbeSystem"]) g_expLightProbeSystem = (int32_t)i;
    else if ([key isEqualToString:@"ProbeVolumeMemoryBudget"]) g_expProbeVolumeMemoryBudget = (int32_t)i;
    else if ([key isEqualToString:@"ProbeVolumeBlendingMemoryBudget"]) g_expProbeVolumeBlendingMemoryBudget = (int32_t)i;
    else if ([key isEqualToString:@"ProbeVolumeSHBands"]) g_expProbeVolumeSHBands = (int32_t)i;
    else if ([key isEqualToString:@"AdditionalShadowTierLow"]) g_expAdditionalShadowTierLow = (i==0?256:(i==1?512:(i==2?1024:2048)));
    else if ([key isEqualToString:@"AdditionalShadowTierMedium"]) g_expAdditionalShadowTierMedium = (i==0?256:(i==1?512:(i==2?1024:2048)));
    else if ([key isEqualToString:@"AdditionalShadowTierHigh"]) g_expAdditionalShadowTierHigh = (i==0?256:(i==1?512:(i==2?1024:2048)));
    else if ([key isEqualToString:@"SoftShadowQuality"]) g_expSoftShadowQuality = (int32_t)i;
    else if ([key isEqualToString:@"ParticleMeshDistribution"]) g_expParticleMeshDistribution = (int32_t)i;
    else if ([key isEqualToString:@"AnimatorCullingMode"]) g_expAnimatorCullingMode = (int32_t)i;
    else if ([key isEqualToString:@"AnimatorUpdateMode"]) g_expAnimatorUpdateMode = (int32_t)i;
    zs_exp_apply_key(key);
    [self zs_scheduleSave];
}

- (void)zs_applyRenderTextureMemorylessDeferred {
    zs_exp_apply_key(@"RenderTextureMemorylessMode");
}

- (void)expWheelChanged:(ZSWheelPicker *)picker {
    NSString *key = objc_getAssociatedObject(picker, @"zs_exp_key");
    if (!key) return;
    NSInteger i = picker.selectedIndex;
    if ([key isEqualToString:@"ParticleRenderMode"]) g_expParticleRenderMode = (int32_t)i;
    else if ([key isEqualToString:@"ParticleAlignment"]) g_expParticleAlignment = (int32_t)i;
    else if ([key isEqualToString:@"ParticleSortMode"]) g_expParticleSortMode = (int32_t)i;
    zs_exp_apply_key(key);
    [self zs_scheduleSave];
}

- (void)browseCategoryButtonTapped {
    NSArray<NSString *> *categories = zs_field_browser_categories();
    NSMutableArray<NSString *> *display = [NSMutableArray array];
    for (NSString *category in categories) {
        [display addObject:[NSString stringWithFormat:@"%@ (%lu)", category, (unsigned long)zs_field_browser_count_for_category(category)]];
    }

    __weak typeof(self) weakSelf = self;
    ZSFieldBrowserPickerViewController *picker =
        [[ZSFieldBrowserPickerViewController alloc] initWithTitle:@"Category"
                                                              items:categories
                                                       titleForItem:^NSString *(id item) { return item; }];
    picker.onSelect = ^(id item) {
        weakSelf.browseSelectedCategory = item;
        weakSelf.browseSelectedEntry = nil;
        [weakSelf.browseCategoryButton setTitle:item forState:UIControlStateNormal];
        [weakSelf.browseClassButton setTitle:@"Setting: --" forState:UIControlStateNormal];
        [weakSelf zs_rebuildBrowseFields];
    };

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    UIViewController *presenter = zs_key_window().rootViewController;
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)browseClassButtonTapped {
    if (self.browseSelectedCategory.length == 0) {
        [self browseCategoryButtonTapped];
        return;
    }

    NSArray<NSDictionary *> *entries = zs_field_browser_entries_for_category(self.browseSelectedCategory);

    __weak typeof(self) weakSelf = self;
    ZSFieldBrowserPickerViewController *picker =
        [[ZSFieldBrowserPickerViewController alloc] initWithTitle:@"Setting"
                                                              items:entries
                                                       titleForItem:^NSString *(id item) {
        NSDictionary *entry = item;
        NSString *namespaze = entry[@"namespace"];
        NSString *qualified = namespaze.length > 0 ? [NSString stringWithFormat:@"%@.%@", namespaze, entry[@"name"]] : entry[@"name"];
        return [NSString stringWithFormat:@"%@ (%@)", qualified, entry[@"kind"]];
    }];
    picker.onSelect = ^(id item) {
        weakSelf.browseSelectedEntry = item;
        NSDictionary *entry = item;
        [weakSelf.browseClassButton setTitle:entry[@"name"] forState:UIControlStateNormal];
        [weakSelf zs_rebuildBrowseFields];
    };

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    UIViewController *presenter = zs_key_window().rootViewController;
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)zs_rebuildBrowseFields {
    if (!self.browseFieldsContainer) return;
    for (UIView *subview in self.browseFieldsContainer.arrangedSubviews) {
        [self.browseFieldsContainer removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }

    if (!self.browseSelectedEntry) {
        UILabel *hint = zs_make_hint_label(@"Pick a category, then a setting to edit its live value.");
        [self.browseFieldsContainer addArrangedSubview:hint];
        return;
    }

    ZSFieldBrowserResolution resolution;
    NSArray<ZSLiveField *> *fields = zs_field_browser_fields_for_entry(self.browseSelectedEntry, &resolution);

    if (resolution == ZSFieldBrowserResolutionClassNotFound) {
        [self.browseFieldsContainer addArrangedSubview:zs_make_hint_label(@"Class not currently loaded by the game.")];
        return;
    }
    if (resolution == ZSFieldBrowserResolutionNoEditableFields || fields.count == 0) {
        [self.browseFieldsContainer addArrangedSubview:zs_make_hint_label(@"No editable static fields on this entry.")];
        return;
    }

    for (ZSLiveField *field in fields) {
        [self.browseFieldsContainer addArrangedSubview:[self zs_rowForBrowsedField:field]];
    }
}

- (UIView *)zs_rowForBrowsedField:(ZSLiveField *)field {
    NSDictionary *entry = self.browseSelectedEntry;

    if (field.kind == ZSFieldKindBool) {
        ZSRow *row = zs_make_switch_row(field.name, field.currentValue != 0);
        objc_setAssociatedObject(row.toggle, @"zs_browse_entry", entry, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(row.toggle, @"zs_browse_field", field.name, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(row.toggle, @"zs_browse_type", @(field.typeEnum), OBJC_ASSOCIATION_RETAIN);
        [row.toggle addTarget:self action:@selector(browseFieldToggleChanged:) forControlEvents:UIControlEventValueChanged];
        return row;
    }

    double absValue = fabs(field.currentValue);
    NSInteger base = (NSInteger)llround(field.currentValue);

    if (absValue < 5) {
        NSInteger lo = MAX(0, base - 2);
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        for (NSInteger i = 0; i < 5; i++) [labels addObject:[NSString stringWithFormat:@"%ld", (long)(lo + i)]];
        NSInteger selIdx = MAX(0, MIN(4, base - lo));
        ZSRow *row = zs_make_mode_slider_row(field.name, labels, selIdx, selIdx);
        objc_setAssociatedObject(row.modeSlider, @"zs_browse_entry", entry, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(row.modeSlider, @"zs_browse_field", field.name, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(row.modeSlider, @"zs_browse_type", @(field.typeEnum), OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(row.modeSlider, @"zs_browse_base", @(lo), OBJC_ASSOCIATION_RETAIN);
        [row.modeSlider addTarget:self action:@selector(browseFieldModeChanged:) forControlEvents:UIControlEventValueChanged];
        return row;
    }

    if (absValue < 10) {
        NSInteger lo = MAX(0, base - 10);
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        for (NSInteger i = 0; i < 21; i++) [labels addObject:[NSString stringWithFormat:@"%ld", (long)(lo + i)]];
        NSInteger selIdx = MAX(0, MIN((NSInteger)labels.count - 1, base - lo));
        ZSRow *row = zs_make_wheel_row(field.name, labels, selIdx, selIdx);
        objc_setAssociatedObject(row.wheelPicker, @"zs_browse_entry", entry, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(row.wheelPicker, @"zs_browse_field", field.name, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(row.wheelPicker, @"zs_browse_type", @(field.typeEnum), OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(row.wheelPicker, @"zs_browse_base", @(lo), OBJC_ASSOCIATION_RETAIN);
        [row.wheelPicker addTarget:self action:@selector(browseFieldWheelChanged:) forControlEvents:UIControlEventValueChanged];
        return row;
    }

    double range = MAX(absValue * 1.5, 10.0);
    float minV = (float)(field.currentValue - range);
    float maxV = (float)(field.currentValue + range);
    BOOL isFloat = (field.kind == ZSFieldKindFloat);
    ZSRow *row = zs_make_slider_row(field.name, minV, maxV, (float)field.currentValue, ^NSString *(float v) {
        return isFloat ? [NSString stringWithFormat:@"%.2f", v] : [NSString stringWithFormat:@"%.0f", v];
    });
    objc_setAssociatedObject(row.slider, @"zs_browse_entry", entry, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row.slider, @"zs_browse_field", field.name, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row.slider, @"zs_browse_type", @(field.typeEnum), OBJC_ASSOCIATION_RETAIN);
    [row.slider addTarget:self action:@selector(browseFieldSliderChanged:) forControlEvents:UIControlEventValueChanged];
    return row;
}

- (void)browseFieldToggleChanged:(UISwitch *)toggle {
    NSDictionary *entry = objc_getAssociatedObject(toggle, @"zs_browse_entry");
    NSString *fieldName = objc_getAssociatedObject(toggle, @"zs_browse_field");
    NSNumber *typeEnum = objc_getAssociatedObject(toggle, @"zs_browse_type");
    if (!entry || !fieldName || !typeEnum) return;
    zs_field_browser_set_value(entry, fieldName, typeEnum.intValue, toggle.on ? 1 : 0);
}

- (void)browseFieldSliderChanged:(ZSCapsuleSlider *)slider {
    NSDictionary *entry = objc_getAssociatedObject(slider, @"zs_browse_entry");
    NSString *fieldName = objc_getAssociatedObject(slider, @"zs_browse_field");
    NSNumber *typeEnum = objc_getAssociatedObject(slider, @"zs_browse_type");
    if (!entry || !fieldName || !typeEnum) return;
    zs_update_value_label(slider);
    zs_field_browser_set_value(entry, fieldName, typeEnum.intValue, slider.value);
}

- (void)browseFieldModeChanged:(ZSModeSlider *)slider {
    NSDictionary *entry = objc_getAssociatedObject(slider, @"zs_browse_entry");
    NSString *fieldName = objc_getAssociatedObject(slider, @"zs_browse_field");
    NSNumber *typeEnum = objc_getAssociatedObject(slider, @"zs_browse_type");
    NSNumber *base = objc_getAssociatedObject(slider, @"zs_browse_base");
    if (!entry || !fieldName || !typeEnum || !base) return;
    double value = base.integerValue + slider.selectedIndex;
    zs_field_browser_set_value(entry, fieldName, typeEnum.intValue, value);
}

- (void)browseFieldWheelChanged:(ZSWheelPicker *)picker {
    NSDictionary *entry = objc_getAssociatedObject(picker, @"zs_browse_entry");
    NSString *fieldName = objc_getAssociatedObject(picker, @"zs_browse_field");
    NSNumber *typeEnum = objc_getAssociatedObject(picker, @"zs_browse_type");
    NSNumber *base = objc_getAssociatedObject(picker, @"zs_browse_base");
    if (!entry || !fieldName || !typeEnum || !base) return;
    double value = base.integerValue + picker.selectedIndex;
    zs_field_browser_set_value(entry, fieldName, typeEnum.intValue, value);
}

@end

#pragma mark - Startup

__attribute__((constructor))
static void graphics_debug_overlay_init(void) {
    __block NSTimer *installTimer;
    installTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [[UserInterface shared] installIfNeeded];
        if ([UserInterface shared].installed) {
            zs_dump_glass_effect_instance_info();
            [timer invalidate];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:installTimer forMode:NSRunLoopCommonModes];
}

