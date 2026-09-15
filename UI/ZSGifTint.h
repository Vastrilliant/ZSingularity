
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void zs_gif_tint_preload(void);

void zs_gif_tint_set_paused(BOOL paused);

void zs_gif_tint_teardown_all(void);
void zs_gif_tint_reconstruct_all(void);

void zs_gif_tint_set_disabled(BOOL disabled);
BOOL zs_gif_tint_is_disabled(void);

void zs_set_gif_window_active(UIView *view, BOOL active);

void zs_apply_gif_text_tint(UILabel *label);

void zs_remove_gif_text_tint(UILabel *label);

void zs_apply_gif_icon_tint(UIImageView *imageView);
void zs_remove_gif_icon_tint(UIImageView *imageView);

void zs_apply_gif_view_tint(UIView *view);
void zs_remove_gif_view_tint(UIView *view);

void zs_refresh_gif_view_tint(UIView *view, CGRect bounds);

void zs_apply_gif_switch_tint(UISwitch *sw);
void zs_remove_gif_switch_tint(UISwitch *sw);

NS_ASSUME_NONNULL_END
