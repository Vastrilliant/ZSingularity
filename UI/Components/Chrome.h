#pragma once

#import "UIInternal.h"

@interface ZSMetalTabs : NSObject
+ (instancetype)shared;
- (void)ensureInstalled;
- (BOOL)isVisible;
- (void)setVisible:(BOOL)visible snap:(BOOL)snap;
- (void)setPauseOverlayVisible:(BOOL)visible;
- (void)setRamHudVisible:(BOOL)visible;
- (void)updateWithViewSize:(CGSize)size
                     rects:(NSArray<NSValue *> *)rects
                      keys:(NSArray<NSString *> *)keys
                   symbols:(NSArray<NSString *> *)symbols
                     glass:(BOOL)glass
                   visible:(BOOL)visible
                      snap:(BOOL)snap;
- (BOOL)touchBegan:(UITouch *)touch inView:(UIView *)view;
- (void)touchMoved:(UITouch *)touch inView:(UIView *)view;
- (void)touchEnded:(UITouch *)touch inView:(UIView *)view cancelled:(BOOL)cancelled;
@end

@interface ZSPassthroughEffectView : UIVisualEffectView
@end

@interface ZSPassthroughView : UIView
@end

@interface ZSPinScrimView : UIView
@property (nonatomic, assign) CGRect passthroughRect;
@end

@interface ZSSelectModeOverlayView : UIView
@end

@interface ZSSelectModeCell : UITableViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIImageView *chevron;
@property (nonatomic, strong) NSLayoutConstraint *chevronWidth;
@property (nonatomic, assign) BOOL showsCard;
@end

@interface ZSSelectModeList : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *rows;
@property (nonatomic, copy) void (^onLocation)(ZSAssetLocation *location);
@end

extern NSString * const kZSMTHandleKey;
extern NSString * const kZSSelectModeCellID;

NSArray<NSDictionary *> *zs_select_mode_message_rows(NSString *text, BOOL warning);
NSArray<NSDictionary *> *zs_select_mode_rows(NSDictionary *hit, NSArray<ZSAssetLocation *> *spriteLocations, NSArray<ZSAssetLocation *> *textureLocations, NSArray<ZSAssetLocation *> *meshLocations, NSUInteger position, NSUInteger total, BOOL loading, BOOL indexing);
void zs_mark_host_owned(UIView *view);
void zs_install_unity_touch_filter(UIView *hostView);
