#import "UIInternal.h"

#pragma mark - Compact row control

#pragma mark - Monospaced font helper

UIFont *zs_mono_font(CGFloat size, UIFontWeight weight) {
    return [UIFont monospacedSystemFontOfSize:size weight:weight];
}

#pragma mark - Window discovery

UIWindow *zs_key_window(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return [UIApplication sharedApplication].delegate.window;
}

UIView *zs_ui_host_view(void) {
    return zs_unity_view() ?: zs_key_window();
}

static void zs_close_application(void) {
    zs_persist_current_settings();
    exit(0);
}

void zs_add_restart_action(UIAlertController *alert) {
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart App"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        zs_close_application();
    }]];
}

NSString *zs_asset_imported_line(NSString *name) {
    return [NSString stringWithFormat:@"%@ Asset imported", name];
}

void zs_drop_font_from_import(NSURL *url, NSString *reason, NSMutableArray<NSURL *> *validURLs, NSMutableArray<NSString *> *summaryLines) {
    [validURLs removeObject:url];
    NSString *line = [NSString stringWithFormat:@"%@: %@", url.lastPathComponent, reason];
    NSUInteger existingIdx = [summaryLines indexOfObject:zs_asset_imported_line(url.lastPathComponent)];
    if (existingIdx != NSNotFound) {
        summaryLines[existingIdx] = line;
    } else {
        [summaryLines addObject:line];
    }
}

void zs_force_dark(UIView *view) {
    if (@available(iOS 13.0, *)) {
        view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
}

#pragma mark - Accent color

UIColor *zs_accent_green_color(void) {
    return [UIColor colorWithRed:0x30 / 255.0 green:0xD1 / 255.0 blue:0x58 / 255.0 alpha:1.0];
}

UIColor *zs_accent_yellow_color(void) {
    return [UIColor colorWithRed:1.0 green:0.82 blue:0.2 alpha:1.0];
}

UIColor *zs_bar_fill_color(void) {
    UIColor *base = zs_accent_green_color();
    CGFloat h = 0, s = 0, b = 0, a = 0;
    [base getHue:&h saturation:&s brightness:&b alpha:&a];
    return [UIColor colorWithHue:h saturation:MIN(1.0, s * 1.15) brightness:MIN(1.0, b * 1.12) alpha:a];
}

#pragma mark - Liquid Glass helpers

static NSString * const kZSLiquidGlassSettingsSection = @"liquidGlass";
static NSString * const kZSLiquidGlassDisabledKey = @"disabled";

NSString * const kZSUISettingsSection = @"ui";
NSString * const kZSUICollapsedSectionsKey = @"collapsedSections";

static BOOL gZSLiquidGlassDisabledCache;
static BOOL gZSLiquidGlassDisabledCacheLoaded;

BOOL zs_liquid_glass_disabled_by_user(void) {
    if (!gZSLiquidGlassDisabledCacheLoaded) {
        NSDictionary *section = zs_settings_section(kZSLiquidGlassSettingsSection);
        id stored = section[kZSLiquidGlassDisabledKey];
        gZSLiquidGlassDisabledCache = stored ? [stored boolValue] : NO;
        gZSLiquidGlassDisabledCacheLoaded = YES;
    }
    return gZSLiquidGlassDisabledCache;
}

void zs_set_liquid_glass_disabled_by_user(BOOL disabled) {
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

BOOL zs_enkephalin_disabled_by_user(void) {
    if (!gZSEnkephalinDisabledCacheLoaded) {
        NSDictionary *section = zs_settings_section(kZSEnkephalinSettingsSection);
        id stored = section[kZSEnkephalinDisabledKey];
        gZSEnkephalinDisabledCache = stored ? [stored boolValue] : NO;
        gZSEnkephalinDisabledCacheLoaded = YES;
    }
    return gZSEnkephalinDisabledCache;
}

void zs_set_enkephalin_disabled_by_user(BOOL disabled) {
    NSMutableDictionary *section = [zs_settings_section(kZSEnkephalinSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSEnkephalinDisabledKey] = @(disabled);
    zs_write_settings_section(kZSEnkephalinSettingsSection, section);
    gZSEnkephalinDisabledCache = disabled;
    gZSEnkephalinDisabledCacheLoaded = YES;
}

#pragma mark - Social links

NSString * const kZSSocialGitHubURL = @"https://github.com/Vastrilliant/ZSingularity";
NSString * const kZSSocialDiscordURL = @"https://discord.gg/nRmztE2unw";
NSString * const kZSPortalURL = @"https://vastrilliant.github.io/ZSingularity/";

static NSString * const kZSInjectionWarningSettingsSection = @"injectionWarning";
static NSString * const kZSInjectionWarningSuppressedKey = @"suppressed";

BOOL zs_injection_warning_suppressed(void) {
    NSDictionary *section = zs_settings_section(kZSInjectionWarningSettingsSection);
    return [section[kZSInjectionWarningSuppressedKey] boolValue];
}

void zs_set_injection_warning_suppressed(BOOL suppressed) {
    NSMutableDictionary *section = [zs_settings_section(kZSInjectionWarningSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSInjectionWarningSuppressedKey] = @(suppressed);
    zs_write_settings_section(kZSInjectionWarningSettingsSection, section);
}

BOOL zs_injected_via_portal(void) {
    id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"ZSInjectionSignature"];
    return [value isKindOfClass:[NSString class]] && [(NSString *)value isEqualToString:@"ZSPortal.v1"];
}

void zs_style_social_text_button(UIButton *button, NSString *text) {
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

BOOL zs_tutorial_completed(void) {
    NSDictionary *section = zs_settings_section(kZSTutorialSettingsSection);
    return [section[kZSTutorialCompletedKey] boolValue];
}

void zs_set_tutorial_completed(BOOL completed) {
    NSMutableDictionary *section = [zs_settings_section(kZSTutorialSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSTutorialCompletedKey] = @(completed);
    zs_write_settings_section(kZSTutorialSettingsSection, section);
}

BOOL zs_tutorial_override_completion_enabled(void) {
    NSDictionary *section = zs_settings_section(kZSTutorialSettingsSection);
    return [section[kZSTutorialOverrideCompletionKey] boolValue];
}

void zs_set_tutorial_override_completion_enabled(BOOL enabled) {
    NSMutableDictionary *section = [zs_settings_section(kZSTutorialSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSTutorialOverrideCompletionKey] = @(enabled);
    zs_write_settings_section(kZSTutorialSettingsSection, section);
}

static NSString * const kZSDeveloperSettingsSection = @"developer";
static NSString * const kZSDeveloperEnabledKey = @"enabled";

BOOL zs_developer_settings_enabled(void) {
    NSDictionary *section = zs_settings_section(kZSDeveloperSettingsSection);
    return [section[kZSDeveloperEnabledKey] boolValue];
}

void zs_set_developer_settings_enabled(BOOL enabled) {
    NSMutableDictionary *section = [zs_settings_section(kZSDeveloperSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSDeveloperEnabledKey] = @(enabled);
    zs_write_settings_section(kZSDeveloperSettingsSection, section);
}

#pragma mark - Update pipeline settings

static NSString * const kZSUpdatePipelineSettingsSection = @"updatePipeline";
static NSString * const kZSUpdateUseNightlyReleasesKey = @"useNightlyReleases";
NSString * const kZSReleaseInfoDocsKey = @"__release_info__";

static BOOL gZSUpdateUseNightlyReleasesCache;
static BOOL gZSUpdateUseNightlyReleasesCacheLoaded;

BOOL zs_update_uses_nightly_releases(void) {
    if (!gZSUpdateUseNightlyReleasesCacheLoaded) {
        NSDictionary *section = zs_settings_section(kZSUpdatePipelineSettingsSection);
        id stored = section[kZSUpdateUseNightlyReleasesKey];
        gZSUpdateUseNightlyReleasesCache = stored ? [stored boolValue] : NO;
        gZSUpdateUseNightlyReleasesCacheLoaded = YES;
    }
    return gZSUpdateUseNightlyReleasesCache;
}

void zs_set_update_uses_nightly_releases(BOOL useNightlyReleases) {
    NSMutableDictionary *section = [zs_settings_section(kZSUpdatePipelineSettingsSection) mutableCopy] ?: [NSMutableDictionary new];
    section[kZSUpdateUseNightlyReleasesKey] = @(useNightlyReleases);
    zs_write_settings_section(kZSUpdatePipelineSettingsSection, section);
    gZSUpdateUseNightlyReleasesCache = useNightlyReleases;
    gZSUpdateUseNightlyReleasesCacheLoaded = YES;
}

ZSUpdateCheckMode zs_update_check_mode(void) {
    return zs_update_uses_nightly_releases() ? ZSUpdateCheckModeNightlyReleases : ZSUpdateCheckModeReleases;
}

static BOOL zs_plist_flag_enabled(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        return [lower isEqualToString:@"yes"] || [lower isEqualToString:@"true"] || [lower isEqualToString:@"1"];
    }
    return NO;
}

static BOOL zs_design_requires_compatibility(void) {
    static BOOL compat;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        static NSString * const key = @"UIDesignRequiresCompatibility";
        BOOL found = zs_plist_flag_enabled([NSBundle mainBundle].infoDictionary[key]);
        if (!found) {
            CFBundleRef mainRef = CFBundleGetMainBundle();
            if (mainRef) {
                CFTypeRef raw = CFBundleGetValueForInfoDictionaryKey(mainRef, (__bridge CFStringRef)key);
                if (raw) found = zs_plist_flag_enabled((__bridge id)raw);
            }
        }
        if (!found) {
            NSString *path = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
            found = zs_plist_flag_enabled(plist[key]);
        }
        compat = found;
    });
    return compat;
}

BOOL zs_has_liquid_glass(void) {
    static BOOL has;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        has = NO;
        if (@available(iOS 26.0, *)) {
            has = (NSClassFromString(@"UIGlassEffect") != nil &&
                   NSClassFromString(@"UIGlassContainerEffect") != nil &&
                   !zs_design_requires_compatibility());
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

UIColor *zs_glass_tint_color(void) {
    return [UIColor colorWithWhite:0.0 alpha:0.32];
}

UIVisualEffect *zs_make_glass_effect(BOOL interactive) {
    return zs_make_glass_effect_style(0 , interactive, zs_glass_tint_color());
}

UIVisualEffect *zs_make_glass_effect_dark(BOOL interactive) {
    return zs_make_glass_effect_style(0 , interactive, zs_glass_tint_color());
}

void zs_set_track_glass_interactive(UIVisualEffectView *trackGlass, BOOL interactive) {
    if (!trackGlass) return;
    trackGlass.effect = zs_make_glass_effect(interactive);
}

void zs_dump_glass_effect_instance_info(void) {
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

UIVisualEffect *zs_make_glass_container_effect(CGFloat spacing) {
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

void zs_configure_glass_corners(UIView *view, CGFloat radius, BOOL concentric) {
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

void zs_configure_glass_corners_sides(UIView *view, CGFloat radius, BOOL concentric, BOOL roundLeft, BOOL roundRight) {
    if (!view || !zs_has_liquid_glass()) return;

    Class radiusClass = NSClassFromString(@"UICornerRadius");
    Class configClass = NSClassFromString(@"UICornerConfiguration");
    SEL roundSelector = concentric
        ? NSSelectorFromString(@"containerConcentricRadiusWithMinimum:")
        : NSSelectorFromString(@"fixedRadius:");
    SEL flatSelector = NSSelectorFromString(@"fixedRadius:");
    SEL fourCornerSelector = NSSelectorFromString(@"configurationWithTopLeftRadius:topRightRadius:bottomLeftRadius:bottomRightRadius:");
    SEL setConfiguration = NSSelectorFromString(@"setCornerConfiguration:");

    if (!radiusClass || !configClass ||
        ![radiusClass respondsToSelector:roundSelector] ||
        ![radiusClass respondsToSelector:flatSelector] ||
        ![configClass respondsToSelector:fourCornerSelector] ||
        ![view respondsToSelector:setConfiguration]) {
        zs_configure_glass_corners(view, radius, concentric);
        return;
    }

    id round = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass, roundSelector, radius);
    id flat = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass, flatSelector, 0);
    if (!round || !flat) {
        zs_configure_glass_corners(view, radius, concentric);
        return;
    }

    id left = roundLeft ? round : flat;
    id right = roundRight ? round : flat;
    id configuration = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(configClass, fourCornerSelector, left, right, left, right);
    if (!configuration) {
        zs_configure_glass_corners(view, radius, concentric);
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(view, setConfiguration, configuration);
}

CGFloat zs_screen_corner_radius(UIView *view, CGFloat fallback) {
    UIScreen *screen = view.window.screen ?: UIScreen.mainScreen;
    CGFloat radius = 0;
    @try {
        id value = [screen valueForKey:@"_displayCornerRadius"];
        if ([value isKindOfClass:[NSNumber class]]) radius = [value doubleValue];
    } @catch (__unused NSException *exception) {
    }
    return radius > 0 ? radius : fallback;
}

void zs_configure_main_panel_glass_corners_split(UIView *view, CGFloat radius, BOOL roundTopLeft, BOOL roundBottomLeft) {
    if (!view || !zs_has_liquid_glass()) return;

    Class radiusClass = NSClassFromString(@"UICornerRadius");
    Class configClass = NSClassFromString(@"UICornerConfiguration");
    SEL concentricSelector = NSSelectorFromString(@"containerConcentricRadiusWithMinimum:");
    SEL fixedSelector = NSSelectorFromString(@"fixedRadius:");
    SEL fourCornerSelector = NSSelectorFromString(@"configurationWithTopLeftRadius:topRightRadius:bottomLeftRadius:bottomRightRadius:");
    SEL setConfiguration = NSSelectorFromString(@"setCornerConfiguration:");
    BOOL fallbackRoundLeft = roundTopLeft && roundBottomLeft;

    if (!radiusClass || !configClass ||
        ![radiusClass respondsToSelector:concentricSelector] ||
        ![radiusClass respondsToSelector:fixedSelector] ||
        ![configClass respondsToSelector:fourCornerSelector] ||
        ![view respondsToSelector:setConfiguration]) {
        zs_configure_glass_corners_sides(view, radius, YES, fallbackRoundLeft, YES);
        return;
    }

    CGFloat rightRadius = MAX(zs_screen_corner_radius(view, radius), radius);
    id roundLeftRadius = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass, concentricSelector, radius);
    id flatRadius = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass, fixedSelector, 0);
    id rightFixed = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass, fixedSelector, rightRadius);
    if (!roundLeftRadius || !flatRadius || !rightFixed) {
        zs_configure_glass_corners_sides(view, radius, YES, fallbackRoundLeft, YES);
        return;
    }

    id topLeft = roundTopLeft ? roundLeftRadius : flatRadius;
    id bottomLeft = roundBottomLeft ? roundLeftRadius : flatRadius;
    id configuration = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(configClass, fourCornerSelector, topLeft, rightFixed, bottomLeft, rightFixed);
    if (!configuration) {
        zs_configure_glass_corners_sides(view, radius, YES, fallbackRoundLeft, YES);
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(view, setConfiguration, configuration);
}

// Corner configuration for the main panel glass while it is expanded leftwards over the extended window.
// Left corners are always round (concentric with the screen, or a fixed radius when flush with the screen
// edge); right corners match the regular main panel.
void zs_configure_main_panel_glass_corners_expanding(UIView *view, CGFloat leftRadius, BOOL leftConcentric, CGFloat rightMinimumRadius) {
    if (!view || !zs_has_liquid_glass()) return;

    Class radiusClass = NSClassFromString(@"UICornerRadius");
    Class configClass = NSClassFromString(@"UICornerConfiguration");
    SEL concentricSelector = NSSelectorFromString(@"containerConcentricRadiusWithMinimum:");
    SEL fixedSelector = NSSelectorFromString(@"fixedRadius:");
    SEL fourCornerSelector = NSSelectorFromString(@"configurationWithTopLeftRadius:topRightRadius:bottomLeftRadius:bottomRightRadius:");
    SEL setConfiguration = NSSelectorFromString(@"setCornerConfiguration:");

    if (!radiusClass || !configClass ||
        ![radiusClass respondsToSelector:concentricSelector] ||
        ![radiusClass respondsToSelector:fixedSelector] ||
        ![configClass respondsToSelector:fourCornerSelector] ||
        ![view respondsToSelector:setConfiguration]) {
        zs_configure_glass_corners_sides(view, leftRadius, leftConcentric, YES, YES);
        return;
    }

    CGFloat rightRadius = MAX(zs_screen_corner_radius(view, rightMinimumRadius), rightMinimumRadius);
    id left = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass, leftConcentric ? concentricSelector : fixedSelector, leftRadius);
    id right = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass, fixedSelector, rightRadius);
    if (!left || !right) {
        zs_configure_glass_corners_sides(view, leftRadius, leftConcentric, YES, YES);
        return;
    }

    id configuration = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(configClass, fourCornerSelector, left, right, left, right);
    if (!configuration) {
        zs_configure_glass_corners_sides(view, leftRadius, leftConcentric, YES, YES);
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(view, setConfiguration, configuration);
}

void zs_configure_main_panel_glass_corners(UIView *view, CGFloat radius, BOOL roundLeft) {
    zs_configure_main_panel_glass_corners_split(view, radius, roundLeft, roundLeft);
}

static NSHashTable<UIVisualEffectView *> *zs_suspendable_glass_registry(void) {
    static NSHashTable<UIVisualEffectView *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static const void *kZSSuspendedGlassEffectKey = &kZSSuspendedGlassEffectKey;

void zs_register_suspendable_glass(UIVisualEffectView *view) {
    if (!view) return;
    [zs_suspendable_glass_registry() addObject:view];
}

void zs_set_glass_suspended(BOOL suspended) {
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

static void zs_clear_button_configuration(UIButton *button) {
    if (!button) return;
    SEL setConfig = NSSelectorFromString(@"setConfiguration:");
    if ([button respondsToSelector:setConfig]) {
        ((void (*)(id, SEL, id))objc_msgSend)(button, setConfig, nil);
    }
}

static const CGFloat kZSGlassButtonCornerRadius = 8;

static void * const kZSButtonGlassViewKey = (void *)&kZSButtonGlassViewKey;
static void * const kZSButtonGlassAlphaKey = (void *)&kZSButtonGlassAlphaKey;

@interface ZSWeakGlassBox : NSObject
@property (nonatomic, weak) UIVisualEffectView *glass;
@end

@implementation ZSWeakGlassBox
@end

static UIVisualEffectView *zs_button_glass_view(UIButton *button) {
    id stored = objc_getAssociatedObject(button, kZSButtonGlassViewKey);
    if ([stored isKindOfClass:[ZSWeakGlassBox class]]) return ((ZSWeakGlassBox *)stored).glass;
    return stored;
}

static UIVisualEffectView *zs_button_wrapping_glass(UIButton *button) {
    UIVisualEffectView *glass = zs_button_glass_view(button);
    if (glass && button.superview == glass.contentView) return glass;
    return nil;
}

static void zs_wrap_button_in_glass(UIButton *button) {
    UIVisualEffectView *glass = zs_button_glass_view(button);
    UIView *parent = button.superview;
    if (!glass || !parent || parent == glass.contentView || glass.superview) return;

    NSMutableArray<NSLayoutConstraint *> *external = [NSMutableArray array];
    for (UIView *ancestor = parent; ancestor; ancestor = ancestor.superview) {
        for (NSLayoutConstraint *constraint in ancestor.constraints) {
            if (constraint.firstItem == button || constraint.secondItem == button) [external addObject:constraint];
        }
    }

    BOOL frameBased = button.translatesAutoresizingMaskIntoConstraints;
    glass.translatesAutoresizingMaskIntoConstraints = frameBased;
    if (frameBased) {
        glass.frame = button.frame;
        glass.autoresizingMask = button.autoresizingMask;
    }
    glass.hidden = button.hidden;
    glass.alpha = button.alpha;

    UIStackView *stack = [parent isKindOfClass:[UIStackView class]] ? (UIStackView *)parent : nil;
    NSUInteger arrangedIndex = stack ? [stack.arrangedSubviews indexOfObject:button] : NSNotFound;
    NSUInteger subviewIndex = [parent.subviews indexOfObject:button];

    for (NSLayoutConstraint *constraint in external) constraint.active = NO;

    [button removeFromSuperview];
    if (arrangedIndex != NSNotFound) {
        [stack insertArrangedSubview:glass atIndex:arrangedIndex];
    } else {
        [parent insertSubview:glass atIndex:MIN(subviewIndex, parent.subviews.count)];
    }

    button.translatesAutoresizingMaskIntoConstraints = NO;
    [glass.contentView addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor],
        [button.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor],
    ]];

    for (NSLayoutConstraint *old in external) {
        id first = old.firstItem == button ? (id)glass : old.firstItem;
        id second = old.secondItem == button ? (id)glass : old.secondItem;
        NSLayoutConstraint *replacement = [NSLayoutConstraint constraintWithItem:first
                                                                       attribute:old.firstAttribute
                                                                       relatedBy:old.relation
                                                                          toItem:second
                                                                       attribute:old.secondAttribute
                                                                      multiplier:old.multiplier
                                                                        constant:old.constant];
        replacement.priority = old.priority;
        replacement.identifier = old.identifier;
        replacement.active = YES;
    }

    NSNumber *pendingAlpha = objc_getAssociatedObject(button, kZSButtonGlassAlphaKey);
    if (!pendingAlpha && button.alpha != 1) {
        objc_setAssociatedObject(button, kZSButtonGlassAlphaKey, @(button.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button setAlpha:1];
    }

    ZSWeakGlassBox *box = [ZSWeakGlassBox new];
    box.glass = glass;
    objc_setAssociatedObject(button, kZSButtonGlassViewKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface ZSGlassWrappedButton : UIButton
@end

@implementation ZSGlassWrappedButton
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    UIView *parent = self.superview;
    if ([parent isKindOfClass:[UIStackView class]]) {
        __weak ZSGlassWrappedButton *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            ZSGlassWrappedButton *strongSelf = weakSelf;
            if (strongSelf) zs_wrap_button_in_glass(strongSelf);
        });
        return;
    }
    zs_wrap_button_in_glass(self);
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    UIVisualEffectView *glass = zs_button_wrapping_glass(self);
    glass.hidden = hidden;
    [(glass ? glass.superview : self.superview) setNeedsLayout];
}

- (CGFloat)alpha {
    NSNumber *stored = objc_getAssociatedObject(self, kZSButtonGlassAlphaKey);
    return stored ? stored.doubleValue : [super alpha];
}

- (void)setAlpha:(CGFloat)alpha {
    UIVisualEffectView *glass = zs_button_wrapping_glass(self);
    if (!glass) {
        [super setAlpha:alpha];
        return;
    }
    objc_setAssociatedObject(self, kZSButtonGlassAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    glass.alpha = alpha;
    [super setAlpha:1];
}
@end

@implementation ZSGlassControlRow

- (void)setButtons:(NSArray<UIButton *> *)buttons {
    _buttons = [buttons copy];
    for (UIButton *button in _buttons) [self addSubview:button];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat size = self.itemSize > 0 ? self.itemSize : 30;
    CGFloat x = CGRectGetWidth(self.bounds);
    CGFloat y = (CGRectGetHeight(self.bounds) - size) / 2.0;
    for (UIButton *button in [self.buttons reverseObjectEnumerator]) {
        if (button.hidden) continue;
        UIView *item = zs_button_wrapping_glass(button) ?: button;
        NSUInteger index = [self.buttons indexOfObject:button];
        CGFloat width = index < self.itemWidths.count ? self.itemWidths[index].doubleValue : size;
        x -= width;
        item.translatesAutoresizingMaskIntoConstraints = YES;
        item.frame = CGRectMake(x, y, width, size);
        x -= self.itemSpacing;
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

static void zs_apply_slash_glass_background(UIButton *button, UIColor *glassTint, NSString *title, UIFont *font, UIImage *image, UIColor *foreground) {
    UIVisualEffect *effect = glassTint ? zs_make_glass_effect_style(0, YES, glassTint) : zs_make_glass_effect(YES);
    UIVisualEffectView *glass = zs_button_glass_view(button);
    if (glass) {
        glass.effect = effect;
    } else {
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.userInteractionEnabled = YES;
        zs_register_suspendable_glass(glass);
        objc_setAssociatedObject(button, kZSButtonGlassViewKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (object_getClass(button) == [UIButton class]) {
            object_setClass(button, [ZSGlassWrappedButton class]);
        }
    }
    zs_configure_glass_corners(glass, kZSGlassButtonCornerRadius, NO);

    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.background = [UIBackgroundConfiguration clearConfiguration];
    configuration.baseForegroundColor = foreground;
    if (image) configuration.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (title) {
        if (font) {
            configuration.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: font}];
        } else {
            configuration.title = title;
        }
    }
    button.configuration = configuration;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;

    zs_wrap_button_in_glass(button);
}

static void * const kZSFlatButtonRadiusKey = (void *)&kZSFlatButtonRadiusKey;

@interface ZSFlatChromeButton : UIButton
@end

@implementation ZSFlatChromeButton
- (void)layoutSubviews {
    [super layoutSubviews];
    NSNumber *fixed = objc_getAssociatedObject(self, kZSFlatButtonRadiusKey);
    CGFloat radius = fixed.doubleValue;
    CGFloat limit = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) / 2.0;
    if (radius <= 0 || radius > limit) radius = limit;
    if (self.layer.cornerRadius != radius) self.layer.cornerRadius = radius;
}
@end

static void zs_apply_flat_button_chrome(UIButton *button) {
    if (!button) return;
    zs_clear_button_configuration(button);
    button.hidden = NO;
    button.opaque = NO;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    button.layer.borderWidth = 0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.masksToBounds = YES;
    button.clipsToBounds = YES;
    CGFloat limit = MIN(CGRectGetWidth(button.bounds), CGRectGetHeight(button.bounds)) / 2.0;
    objc_setAssociatedObject(button, kZSFlatButtonRadiusKey, @(kZSGlassButtonCornerRadius), OBJC_ASSOCIATION_RETAIN);
    button.layer.cornerRadius = limit > 0 ? MIN(kZSGlassButtonCornerRadius, limit) : kZSGlassButtonCornerRadius;
    if (object_getClass(button) == [UIButton class]) {
        object_setClass(button, [ZSFlatChromeButton class]);
    }
    [button setNeedsLayout];
}

void zs_style_button_as_native_glass_with_font(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font) {
    if (zs_has_liquid_glass()) {
        zs_apply_slash_glass_background(button, nil, title, font, nil, tintColor ?: UIColor.whiteColor);
        return;
    }

    zs_apply_flat_button_chrome(button);
    [button setTitle:title forState:UIControlStateNormal];
    if (tintColor) {
        [button setTitleColor:tintColor forState:UIControlStateNormal];
        button.tintColor = tintColor;
    }
    if (font) button.titleLabel.font = font;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static void zs_style_button_as_native_glass(UIButton *button, NSString *title, UIColor *tintColor) {
    zs_style_button_as_native_glass_with_font(button, title, tintColor, nil);
}

static void zs_style_button_as_liquid_glass_fallback_with_font(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font) {
    zs_apply_flat_button_chrome(button);
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
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static void zs_style_button_mirroring_glass_state(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font) {
    if (zs_has_liquid_glass()) {
        zs_style_button_as_native_glass_with_font(button, title, tintColor, font);
    } else {
        zs_style_button_as_liquid_glass_fallback_with_font(button, title, tintColor, font);
    }
}

UIButton *zs_make_liquid_glass_fallback_twin(UIButton *primaryButton, NSString *title, UIColor *tintColor, UIFont *font) {
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

void zs_style_button_as_solid_glass_with_font(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font) {
    if (zs_has_liquid_glass()) {
        zs_apply_slash_glass_background(button, tintColor, title, font, nil, UIColor.whiteColor);
        return;
    }

    zs_clear_button_configuration(button);
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    if (font) button.titleLabel.font = font;
    button.backgroundColor = tintColor;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.cornerRadius = kZSGlassButtonCornerRadius;
    button.clipsToBounds = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

void zs_set_install_option_greyed_out(UIButton *button, BOOL greyedOut) {
    button.enabled = !greyedOut;
    button.alpha = greyedOut ? 0.4 : 1.0;
}

void zs_style_pill_icon_button_as_native_glass(UIButton *button, UIImage *image, UIColor *tintColor) {
    if (zs_has_liquid_glass()) {
        zs_apply_slash_glass_background(button, nil, nil, nil, image, tintColor ?: UIColor.whiteColor);
        return;
    }

    zs_apply_flat_button_chrome(button);
    [button setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    button.tintColor = tintColor ?: UIColor.whiteColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

void zs_style_arrow_only_button(UIButton *button, UIImage *image, UIColor *tintColor, BOOL dropShadow) {
    zs_clear_button_configuration(button);
    [button setImage:image forState:UIControlStateNormal];
    if (tintColor) button.tintColor = tintColor;
    button.backgroundColor = UIColor.clearColor;
    button.layer.borderWidth = 0;
    button.layer.cornerRadius = 0;
    button.clipsToBounds = NO;
    button.layer.masksToBounds = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    if (dropShadow) {
        button.layer.shadowColor = UIColor.blackColor.CGColor;
        button.layer.shadowOpacity = 0.65;
        button.layer.shadowRadius = 3;
        button.layer.shadowOffset = CGSizeMake(0, 1.5);
    } else {
        button.layer.shadowOpacity = 0;
    }
}

UIImage *zs_mods_doctor_button_icon(NSString *sfSymbolName, CGFloat pointSize) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:sfSymbolName withConfiguration:config];
}

static void zs_style_icon_button_as_native_glass(UIButton *button, UIImage *image, UIColor *tintColor) {
    if (zs_has_liquid_glass()) {
        zs_apply_slash_glass_background(button, nil, nil, nil, image, tintColor ?: UIColor.whiteColor);
        return;
    }

    zs_apply_flat_button_chrome(button);
    [button setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    button.tintColor = tintColor ?: UIColor.whiteColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

void zs_style_options_button_as_original_native_glass(UIButton *button, UIImage *image, UIColor *tintColor) {
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

    zs_apply_flat_button_chrome(button);
    [button setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    button.tintColor = tintColor ?: UIColor.whiteColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
}

static void zs_remove_tap_to_confirm(UIButton *button) {
    [button removeTarget:nil action:@selector(zs_handleTapToConfirm:) forControlEvents:UIControlEventTouchUpInside];
}

void * const kZSHoldConfirmBlockKey = (void *)&kZSHoldConfirmBlockKey;

void * const kZSHoldConfirmExpansionViewKey = (void *)&kZSHoldConfirmExpansionViewKey;
void * const kZSHoldConfirmExpansionWidthKey = (void *)&kZSHoldConfirmExpansionWidthKey;
void * const kZSHoldConfirmDeleteLabelKey = (void *)&kZSHoldConfirmDeleteLabelKey;
void * const kZSHoldConfirmExpansionFillKey = (void *)&kZSHoldConfirmExpansionFillKey;
void * const kZSHoldConfirmButtonFillKey = (void *)&kZSHoldConfirmButtonFillKey;

void * const kZSHoldConfirmGlassViewKey = (void *)&kZSHoldConfirmGlassViewKey;
void * const kZSHoldConfirmGlassHostKey = (void *)&kZSHoldConfirmGlassHostKey;

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

void * const kZSTapConfirmTitleKey = (void *)&kZSTapConfirmTitleKey;
void * const kZSTapConfirmMessageKey = (void *)&kZSTapConfirmMessageKey;
void * const kZSTapConfirmActionTitleKey = (void *)&kZSTapConfirmActionTitleKey;
void * const kZSTapConfirmDestructiveKey = (void *)&kZSTapConfirmDestructiveKey;
void * const kZSTapConfirmBlockKey = (void *)&kZSTapConfirmBlockKey;

void zs_attach_tap_to_confirm(UIButton *button, id target,
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

@implementation ZSRow
@end
