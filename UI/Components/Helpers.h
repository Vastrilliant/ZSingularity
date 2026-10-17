#pragma once

#import "UIInternal.h"

@interface ZSRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) ZSCapsuleSlider *slider;
@property (nonatomic, strong) ZSModeSlider *modeSlider;
@property (nonatomic, strong) ZSWheelPicker *wheelPicker;
@property (nonatomic, strong) UISwitch *toggle;
@end

@interface ZSGlassControlRow : UIView
@property (nonatomic, copy) NSArray<UIButton *> *buttons;
@property (nonatomic, assign) CGFloat itemSize;
@property (nonatomic, copy) NSArray<NSNumber *> *itemWidths;
@property (nonatomic, assign) CGFloat itemSpacing;
@end

extern NSString * const kZSUISettingsSection;
extern NSString * const kZSUICollapsedSectionsKey;
extern NSString * const kZSSocialGitHubURL;
extern NSString * const kZSSocialDiscordURL;
extern NSString * const kZSReleaseInfoDocsKey;
extern void * const kZSHoldConfirmBlockKey;
extern void * const kZSHoldConfirmExpansionViewKey;
extern void * const kZSHoldConfirmExpansionWidthKey;
extern void * const kZSHoldConfirmDeleteLabelKey;
extern void * const kZSHoldConfirmExpansionFillKey;
extern void * const kZSHoldConfirmButtonFillKey;
extern void * const kZSHoldConfirmGlassViewKey;
extern void * const kZSHoldConfirmGlassHostKey;
extern void * const kZSTapConfirmTitleKey;
extern void * const kZSTapConfirmMessageKey;
extern void * const kZSTapConfirmActionTitleKey;
extern void * const kZSTapConfirmDestructiveKey;
extern void * const kZSTapConfirmBlockKey;

UIFont *zs_mono_font(CGFloat size, UIFontWeight weight);
UIWindow *zs_key_window(void);
UIView *zs_ui_host_view(void);
void zs_add_restart_action(UIAlertController *alert);
NSString *zs_asset_imported_line(NSString *name);
void zs_drop_font_from_import(NSURL *url, NSString *reason, NSMutableArray<NSURL *> *validURLs, NSMutableArray<NSString *> *summaryLines);
void zs_force_dark(UIView *view);
UIColor *zs_accent_green_color(void);
UIColor *zs_accent_yellow_color(void);
UIColor *zs_bar_fill_color(void);
BOOL zs_liquid_glass_disabled_by_user(void);
void zs_set_liquid_glass_disabled_by_user(BOOL disabled);
BOOL zs_enkephalin_disabled_by_user(void);
void zs_set_enkephalin_disabled_by_user(BOOL disabled);
void zs_style_social_text_button(UIButton *button, NSString *text);
BOOL zs_tutorial_completed(void);
void zs_set_tutorial_completed(BOOL completed);
BOOL zs_tutorial_override_completion_enabled(void);
void zs_set_tutorial_override_completion_enabled(BOOL enabled);
BOOL zs_developer_settings_enabled(void);
void zs_set_developer_settings_enabled(BOOL enabled);
BOOL zs_update_uses_nightly_releases(void);
void zs_set_update_uses_nightly_releases(BOOL useNightlyReleases);
ZSUpdateCheckMode zs_update_check_mode(void);
BOOL zs_has_liquid_glass(void);
UIColor *zs_glass_tint_color(void);
UIVisualEffect *zs_make_glass_effect(BOOL interactive);
UIVisualEffect *zs_make_glass_effect_dark(BOOL interactive);
void zs_set_track_glass_interactive(UIVisualEffectView *trackGlass, BOOL interactive);
void zs_dump_glass_effect_instance_info(void);
UIVisualEffect *zs_make_glass_container_effect(CGFloat spacing);
void zs_configure_glass_corners(UIView *view, CGFloat radius, BOOL concentric);
void zs_configure_glass_corners_sides(UIView *view, CGFloat radius, BOOL concentric, BOOL roundLeft, BOOL roundRight);
CGFloat zs_screen_corner_radius(UIView *view, CGFloat fallback);
void zs_configure_main_panel_glass_corners_split(UIView *view, CGFloat radius, BOOL roundTopLeft, BOOL roundBottomLeft);
void zs_configure_main_panel_glass_corners(UIView *view, CGFloat radius, BOOL roundLeft);
void zs_register_suspendable_glass(UIVisualEffectView *view);
void zs_set_glass_suspended(BOOL suspended);
void zs_style_button_as_native_glass_with_font(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font);
UIButton *zs_make_liquid_glass_fallback_twin(UIButton *primaryButton, NSString *title, UIColor *tintColor, UIFont *font);
void zs_style_button_as_solid_glass_with_font(UIButton *button, NSString *title, UIColor *tintColor, UIFont *font);
void zs_set_install_option_greyed_out(UIButton *button, BOOL greyedOut);
void zs_style_pill_icon_button_as_native_glass(UIButton *button, UIImage *image, UIColor *tintColor);
void zs_style_arrow_only_button(UIButton *button, UIImage *image, UIColor *tintColor, BOOL dropShadow);
UIImage *zs_mods_doctor_button_icon(NSString *sfSymbolName, CGFloat pointSize);
void zs_style_options_button_as_original_native_glass(UIButton *button, UIImage *image, UIColor *tintColor);
void zs_attach_tap_to_confirm(UIButton *button, id target, NSString *title, NSString *message, NSString *actionTitle, BOOL destructive, void (^onConfirm)(void));
