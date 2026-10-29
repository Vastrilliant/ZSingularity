#pragma once

#import "UIInternal.h"

@interface ZSFillView : UIView
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign, getter=isTrailingSquared) BOOL trailingSquared;
- (void)zs_beginLiveMaskResync;
- (void)zs_endLiveMaskResync;
@end

@interface ZSPillarChartView : UIView
- (void)setSegmentsWithFractions:(NSArray<NSNumber *> *)fractions colors:(NSArray<UIColor *> *)colors;
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
@property (nonatomic, assign) BOOL panActive;
@property (nonatomic, weak) UIScrollView *lockedScrollView;
@property (nonatomic, assign) CGFloat holdAnchorTouchX;
@property (nonatomic, assign) CGFloat holdAnchorValueX;
@property (nonatomic, strong) UIVisualEffectView *trackGlass;
@property (nonatomic, assign) BOOL glassEnabled;
@end

@interface ZSModeSlider : UIControl
@property (nonatomic, copy) NSArray<NSString *> *labels;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) NSInteger defaultIndex;
@property (nonatomic, strong) UIColor *fillColor;
@property (nonatomic, assign) BOOL gifTintEnabled;
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

@interface ZSDeadZoneScrollView : UIScrollView
@property (nonatomic, assign) CGFloat deadZone;
@end

@interface ZSPanelScrollView : UIScrollView
@end

@interface ZSSectionIndexView : UIView
@property (nonatomic, copy) void (^onSelect)(NSUInteger index);
- (void)setTitles:(NSArray<NSString *> *)titles fullTitles:(NSArray<NSString *> *)fullTitles;
@end

@interface ZSMarqueeLabel : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic, strong) UIColor *textColor;

@property (nonatomic, copy) NSString *marqueeKey;
@end
