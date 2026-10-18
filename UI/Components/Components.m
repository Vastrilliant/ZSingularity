#import "UIInternal.h"
#import "EmbeddedFont.h"
#import "EmbeddedSignature.h"

#pragma mark - Miscellaneous UI

NSString *zs_custom_greeting_button_title(NSString *text) {
    if (text.length == 0) return @"Not Set";
    return text;
}

static const CGFloat kRowHeight = 26;
static const CGFloat kTitleColumnWidth = 92;
static const CGFloat kSettingRowHeight = 24;

static float zs_slider_step_for_range(float minV, float maxV) {
    if (minV >= -1.0f && maxV <= 1.0f) return 0.05f;
    if (maxV > 20.0f) return 5.0f;
    return 0.0f;
}

ZSRow *zs_make_slider_row(NSString *title, float minV, float maxV, float val, NSString *(^format)(float)) {
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
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.slider.centerYAnchor],

        [row.valueLabel.trailingAnchor constraintEqualToAnchor:row.slider.trailingAnchor constant:-6],
        [row.valueLabel.bottomAnchor constraintEqualToAnchor:row.slider.track.topAnchor constant:-3],

        [row.slider.leadingAnchor constraintEqualToAnchor:row.titleLabel.trailingAnchor constant:4],
        [row.slider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    ]];

    NSLayoutConstraint *sliderRowTop = [row.topAnchor constraintEqualToAnchor:row.slider.topAnchor constant:-9];
    NSLayoutConstraint *sliderRowBottom = [row.bottomAnchor constraintEqualToAnchor:row.slider.bottomAnchor constant:3];
    sliderRowTop.priority = UILayoutPriorityRequired - 1;
    sliderRowBottom.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[sliderRowTop, sliderRowBottom]];

    objc_setAssociatedObject(row.slider, "zs_format", format, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(row.slider, "zs_valueLabel", row.valueLabel, OBJC_ASSOCIATION_RETAIN);

    return row;
}

ZSRow *zs_make_mode_slider_row(NSString *title, NSArray<NSString *> *labels, NSInteger selectedIndex, NSInteger defaultIndex) {
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

ZSRow *zs_make_wheel_row(NSString *title, NSArray<NSString *> *labels, NSInteger selectedIndex, NSInteger defaultIndex) {
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

UILabel *zs_make_hint_label(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    label.font = zs_mono_font(10, UIFontWeightRegular);
    label.numberOfLines = 0;
    return label;
}

ZSRow *zs_make_switch_row(NSString *title, BOOL val) {
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
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [row.toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:toggleTrailingCompensation],
        [row.toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.toggle.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.titleLabel.trailingAnchor constant:6],
    ]];

    NSLayoutConstraint *switchRowHeight = [row.heightAnchor constraintEqualToConstant:kSettingRowHeight];
    switchRowHeight.priority = UILayoutPriorityRequired - 1;
    switchRowHeight.active = YES;

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

void zs_add_unavailable_subtext(ZSRow *row, NSString *text) {
    UILabel *subLabel = [[UILabel alloc] init];
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subLabel.font = zs_mono_font(8, UIFontWeightRegular);
    subLabel.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    subLabel.text = text;
    subLabel.numberOfLines = 0;
    [subLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [row addSubview:subLabel];

    for (NSLayoutConstraint *constraint in row.constraints) {
        BOOL isTitle = constraint.firstItem == row.titleLabel;
        BOOL isToggle = constraint.firstItem == row.toggle;
        if ((isTitle || isToggle) && constraint.firstAttribute == NSLayoutAttributeCenterY) {
            constraint.active = NO;
        }
        if (constraint.firstItem == row && constraint.firstAttribute == NSLayoutAttributeHeight) {
            constraint.active = NO;
        }
    }

    CGFloat topBandHeight = kZSGroupedCardRowHeight;
    [NSLayoutConstraint activateConstraints:@[
        [row.titleLabel.centerYAnchor constraintEqualToAnchor:row.topAnchor constant:topBandHeight / 2.0],
        [row.toggle.centerYAnchor constraintEqualToAnchor:row.topAnchor constant:topBandHeight / 2.0],
        [subLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:topBandHeight - 4],
        [subLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [subLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [subLabel.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-9],
    ]];
    objc_setAssociatedObject(row, "zs_selfSizingRow", @YES, OBJC_ASSOCIATION_RETAIN);
}
static const CGFloat kZSGroupedCardHorizontalPadding = 14;
static const CGFloat kZSGroupedCardCornerRadius = 14;

__weak UIButton *g_zsLowResTranscodeButton;
NSTimer *g_zsLowResTimer;
__weak UIView *g_zsLowResProgressView;
__weak UILabel *g_zsLowResBundleCountLabel;
__weak UILabel *g_zsLowResETALabel;
__weak UILabel *g_zsLowResPercentLabel;
__weak UILabel *g_zsLowResTexturesLabel;
__weak UIView *g_zsLowResTrack;
__weak UIView *g_zsLowResFill;
NSLayoutConstraint *g_zsLowResFillWidth;
BOOL g_zsLowResUserCancelled;
__weak UIStackView *g_zsLowResInfoView;
__weak UILabel *g_zsLowResInfoLabel;
__weak UIButton *g_zsLowResInfoButton;
__weak UIView *g_zsLowResInfoButtonSeparator;
NSInteger g_zsLowResStage;
NSUInteger g_zsLowResGeneration;
BOOL g_zsLowResReopenPending;
BOOL g_zsLowResSwapBusy;
__weak UIButton *g_zsLowResCancelButton;
__weak UIView *g_zsLowResInfoWrapper;
__weak UIView *g_zsLowResProgressWrapper;
__weak UIView *g_zsLowResSwapWrapper;
__weak UIView *g_zsLowResSwapLeftSlot;
__weak UIView *g_zsLowResSwapRightSlot;
__weak UIImageView *g_zsLowResSwapLeftIcon;
__weak UIImageView *g_zsLowResSwapRightIcon;
__weak UIButton *g_zsLowResSwapButton;
NSString *g_zsLowResSharedPath;
BOOL g_zsLowResSwapEligible;
BOOL g_zsLowResDiskExists;
BOOL g_zsLowResBackupExists;
BOOL g_zsLowResDiskTranscoded;
BOOL g_zsLowResBackupTranscoded;
BOOL g_zsLowResDeleteOpen;
BOOL g_zsLowResDeleteTargetIsDisk;
__weak UIView *g_zsLowResDeleteWrapper;
__weak UILabel *g_zsLowResDeleteLabel;
__weak UIView *g_zsLowResTranscodeWrapper;
NSInteger g_zsLowResBlockIndex;
BOOL g_zsLowResCodecExpanded;
__weak UIView *g_zsLowResLabelHost;
__weak UIView *g_zsLowResConfigView;
__weak UIView *g_zsLowResCodecContainer;
__weak UIControl *g_zsLowResCodecRow;
__weak UIView *g_zsLowResCodecOptions;
NSLayoutConstraint *g_zsLowResCodecHeight;

UIButton *zs_make_grouped_action_button(NSString *title, UIColor *tint) {
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

UIView *zs_make_grouped_action_pair_row(UIButton *leftButton, UIButton *rightButton) {
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

UIView *zs_make_grouped_action_card(NSArray<UIView *> *rows) {
    UIStackView *innerStack = [[UIStackView alloc] init];
    innerStack.axis = UILayoutConstraintAxisVertical;
    innerStack.translatesAutoresizingMaskIntoConstraints = NO;
    innerStack.spacing = 0;

    for (NSUInteger i = 0; i < rows.count; i++) {
        UIView *row = rows[i];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [innerStack addArrangedSubview:row];
        if (![objc_getAssociatedObject(row, "zs_selfSizingRow") boolValue]) {
            [row.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight].active = YES;
        }
        if (i + 1 < rows.count) {
            [innerStack addArrangedSubview:zs_make_grouped_row_separator()];
        }
    }

    UIView *card;
    UIView *contentHost;
    NSLayoutConstraint *innerBottom = nil;
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
    innerBottom = [innerStack.bottomAnchor constraintEqualToAnchor:contentHost.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [innerStack.topAnchor constraintEqualToAnchor:contentHost.topAnchor],
        innerBottom,
        [innerStack.leadingAnchor constraintEqualToAnchor:contentHost.leadingAnchor constant:kZSGroupedCardHorizontalPadding],
        [innerStack.trailingAnchor constraintEqualToAnchor:contentHost.trailingAnchor constant:-kZSGroupedCardHorizontalPadding],
    ]];

    objc_setAssociatedObject(card, "zs_innerStack", innerStack, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(card, "zs_innerBottom", innerBottom, OBJC_ASSOCIATION_RETAIN);

    return card;
}

static UIColor *zs_disclosure_secondary_color(void) {
    return [UIColor colorWithWhite:1 alpha:0.55];
}

static UILabel *zs_make_lowres_label(NSString *text, UIColor *color, UIFontWeight weight) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = zs_mono_font(11, weight);
    label.textColor = color;
    label.text = text;
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return label;
}

UIView *zs_make_lowres_progress_view(id target, SEL cancelAction) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIColor *primary = [UIColor colorWithWhite:0.9 alpha:1];
    UILabel *header = [[UILabel alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.attributedText = [[NSAttributedString alloc] initWithString:@"COMPRESSION STATUS" attributes:@{
        NSFontAttributeName: zs_mono_font(10, UIFontWeightSemibold),
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45],
        NSKernAttributeName: @0.8,
    }];
    UILabel *bundleCount = zs_make_lowres_label(@"0/0", zs_disclosure_secondary_color(), UIFontWeightMedium);
    UILabel *eta = zs_make_lowres_label(@"ETA --:--:--", zs_disclosure_secondary_color(), UIFontWeightMedium);
    UILabel *percent = zs_make_lowres_label(@"0%", zs_accent_green_color(), UIFontWeightSemibold);
    UILabel *textures = zs_make_lowres_label(@"0/0", primary, UIFontWeightSemibold);

    UIView *track = [[UIView alloc] init];
    track.translatesAutoresizingMaskIntoConstraints = NO;
    track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    track.layer.cornerRadius = 3;
    track.clipsToBounds = YES;

    UIView *fill = [[UIView alloc] init];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.backgroundColor = zs_bar_fill_color();
    fill.layer.cornerRadius = 3;
    [track addSubview:fill];

    UIView *separator = zs_make_grouped_row_separator();
    UIButton *cancel = zs_make_grouped_action_button(@"Cancel", [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0]);
    cancel.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [cancel addTarget:target action:cancelAction forControlEvents:UIControlEventTouchUpInside];

    for (UIView *view in @[header, bundleCount, eta, percent, textures, track, separator, cancel]) [container addSubview:view];

    NSLayoutConstraint *fillWidth = [fill.widthAnchor constraintEqualToAnchor:track.widthAnchor multiplier:0.0001];
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [header.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [bundleCount.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [bundleCount.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12],
        [eta.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [eta.centerYAnchor constraintEqualToAnchor:bundleCount.centerYAnchor],
        [eta.leadingAnchor constraintGreaterThanOrEqualToAnchor:bundleCount.trailingAnchor constant:8],

        [percent.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [percent.topAnchor constraintEqualToAnchor:bundleCount.bottomAnchor constant:14],
        [textures.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [textures.centerYAnchor constraintEqualToAnchor:percent.centerYAnchor],

        [track.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [track.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [track.topAnchor constraintEqualToAnchor:percent.bottomAnchor constant:6],
        [track.heightAnchor constraintEqualToConstant:6],
        [fill.leadingAnchor constraintEqualToAnchor:track.leadingAnchor],
        [fill.topAnchor constraintEqualToAnchor:track.topAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:track.bottomAnchor],
        fillWidth,

        [separator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:track.bottomAnchor constant:12],

        [cancel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [cancel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [cancel.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        [cancel.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight],
        [cancel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    g_zsLowResCancelButton = cancel;
    g_zsLowResBundleCountLabel = bundleCount;
    g_zsLowResETALabel = eta;
    g_zsLowResPercentLabel = percent;
    g_zsLowResTexturesLabel = textures;
    g_zsLowResTrack = track;
    g_zsLowResFill = fill;
    g_zsLowResFillWidth = fillWidth;
    return container;
}

NSArray<NSNumber *> *zs_lowres_block_options(void) {
    return @[@8, @10, @12];
}

static void * const kZSRevealContentKey = (void *)&kZSRevealContentKey;
static void * const kZSRevealFullKey = (void *)&kZSRevealFullKey;
static void * const kZSRevealZeroKey = (void *)&kZSRevealZeroKey;

UIView *zs_make_reveal_wrapper(UIView *content, BOOL expanded) {
    UIView *wrapper = [[UIView alloc] init];
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;
    wrapper.clipsToBounds = YES;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:content];
    NSLayoutConstraint *full = [wrapper.heightAnchor constraintEqualToAnchor:content.heightAnchor];
    NSLayoutConstraint *zero = [wrapper.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
    ]];
    full.active = expanded;
    zero.active = !expanded;
    content.alpha = expanded ? 1 : 0;
    objc_setAssociatedObject(wrapper, kZSRevealContentKey, content, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(wrapper, kZSRevealFullKey, full, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(wrapper, kZSRevealZeroKey, zero, OBJC_ASSOCIATION_RETAIN);
    return wrapper;
}

void zs_reveal_set_expanded(UIView *wrapper, BOOL expanded) {
    if (!wrapper) return;
    UIView *content = objc_getAssociatedObject(wrapper, kZSRevealContentKey);
    NSLayoutConstraint *full = objc_getAssociatedObject(wrapper, kZSRevealFullKey);
    NSLayoutConstraint *zero = objc_getAssociatedObject(wrapper, kZSRevealZeroKey);
    if (expanded) {
        zero.active = NO;
        full.active = YES;
    } else {
        full.active = NO;
        zero.active = YES;
    }
    NSTimeInterval duration = expanded ? 0.28 : 0.16;
    NSTimeInterval delay = expanded ? 0.12 : 0;
    [UIView animateWithDuration:duration
                          delay:delay
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                     animations:^{ content.alpha = expanded ? 1 : 0; }
                     completion:nil];
}

NSString *zs_lowres_swap_shared_folders(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *shared = [UnityCacheLocator unityCacheSharedDirectories].firstObject;
    if (!shared) return @"Couldn't find the UnityCache/Shared folder.";
    NSString *lowRes = [TexComp stagingDirectory];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:lowRes isDirectory:&isDirectory] || !isDirectory) return @"Documents/LowRes doesn't exist.";

    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:lowRes error:nil]) {
        if ([name hasPrefix:@"."] || [name isEqualToString:@"ledger.json"]) continue;
        [visible addObject:name];
    }
    if (visible.count == 0) return @"Documents/LowRes has no compressed textures to swap in.";

    NSString *source = lowRes;
    if (visible.count == 1 && [visible.firstObject caseInsensitiveCompare:@"Shared"] == NSOrderedSame) {
        NSString *candidate = [lowRes stringByAppendingPathComponent:visible.firstObject];
        BOOL candidateIsDirectory = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&candidateIsDirectory] && candidateIsDirectory) source = candidate;
    }

    NSString *mergeError = [TexComp mergeOriginalsIntoDirectory:source copied:NULL];
    if (mergeError) return mergeError;

    if (![source isEqualToString:lowRes]) {
        NSString *ledger = [lowRes stringByAppendingPathComponent:@"ledger.json"];
        NSString *ledgerTarget = [source stringByAppendingPathComponent:@"ledger.json"];
        if ([fm fileExistsAtPath:ledger]) {
            [fm removeItemAtPath:ledgerTarget error:nil];
            [fm copyItemAtPath:ledger toPath:ledgerTarget error:nil];
        }
    }

    NSString *backup = [shared stringByAppendingString:@".backup"];
    NSError *error = nil;
    if ([fm fileExistsAtPath:backup]) {
        if (![fm removeItemAtPath:backup error:&error]) {
            return [NSString stringWithFormat:@"Couldn't remove the old Shared.backup: %@", error.localizedDescription ?: @"unknown error"];
        }
    }
    if (![fm moveItemAtPath:shared toPath:backup error:&error]) {
        return [NSString stringWithFormat:@"Couldn't rename Shared to Shared.backup: %@", error.localizedDescription ?: @"unknown error"];
    }
    if (![fm moveItemAtPath:source toPath:shared error:&error]) {
        NSString *reason = error.localizedDescription ?: @"unknown error";
        NSError *rollbackError = nil;
        if (![fm moveItemAtPath:backup toPath:shared error:&rollbackError]) {
            return [NSString stringWithFormat:@"Couldn't move the compressed textures into place: %@. Restoring Shared also failed: %@. Your original files are in Shared.backup.", reason, rollbackError.localizedDescription ?: @"unknown error"];
        }
        return [NSString stringWithFormat:@"Couldn't move the compressed textures into place: %@. Shared was restored.", reason];
    }
    NSString *restoreError = [TexComp restoreMissingFilesIntoDirectory:shared fromBackup:backup restored:NULL];
    if (restoreError) return [NSString stringWithFormat:@"The compressed textures are in place, but %@ The game may ask to download them again.", restoreError];
    return nil;
}

TexCompFolderState zs_lowres_folder_state(NSString *shared) {
    TexCompFolderState state = {0};
    if (!shared) return state;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backup = [shared stringByAppendingString:@".backup"];
    BOOL isDirectory = NO;
    state.diskExists = [fm fileExistsAtPath:shared isDirectory:&isDirectory] && isDirectory;
    isDirectory = NO;
    state.backupExists = [fm fileExistsAtPath:backup isDirectory:&isDirectory] && isDirectory;
    state.diskTranscoded = state.diskExists && [fm fileExistsAtPath:[shared stringByAppendingPathComponent:@"ledger.json"]];
    state.backupTranscoded = state.backupExists && [fm fileExistsAtPath:[backup stringByAppendingPathComponent:@"ledger.json"]];
    return state;
}

NSString *zs_lowres_exchange_shared_folders(NSString *shared) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backup = [shared stringByAppendingString:@".backup"];
    NSString *temp = [shared stringByAppendingString:@".swap"];
    TexCompFolderState state = zs_lowres_folder_state(shared);
    if (!state.diskExists) return @"Couldn't find the UnityCache/Shared folder.";
    if (!state.backupExists) return @"Couldn't find Shared.backup.";
    NSError *error = nil;
    if ([fm fileExistsAtPath:temp] && ![fm removeItemAtPath:temp error:&error]) {
        return [NSString stringWithFormat:@"Couldn't clear a leftover temporary folder: %@", error.localizedDescription ?: @"unknown error"];
    }
    if (![fm moveItemAtPath:shared toPath:temp error:&error]) {
        return [NSString stringWithFormat:@"Couldn't rename Shared: %@", error.localizedDescription ?: @"unknown error"];
    }
    if (![fm moveItemAtPath:backup toPath:shared error:&error]) {
        NSString *reason = error.localizedDescription ?: @"unknown error";
        NSError *rollbackError = nil;
        if (![fm moveItemAtPath:temp toPath:shared error:&rollbackError]) {
            return [NSString stringWithFormat:@"Couldn't rename Shared.backup: %@. Restoring Shared also failed: %@. Your Shared folder is named Shared.swap.", reason, rollbackError.localizedDescription ?: @"unknown error"];
        }
        return [NSString stringWithFormat:@"Couldn't rename Shared.backup: %@. Nothing was changed.", reason];
    }
    if (![fm moveItemAtPath:temp toPath:backup error:&error]) {
        NSString *reason = error.localizedDescription ?: @"unknown error";
        NSError *rollbackError = nil;
        if (![fm moveItemAtPath:shared toPath:backup error:&rollbackError] || ![fm moveItemAtPath:temp toPath:shared error:&rollbackError]) {
            return [NSString stringWithFormat:@"Couldn't finish the swap: %@. Rolling back also failed: %@. Check for Shared.swap.", reason, rollbackError.localizedDescription ?: @"unknown error"];
        }
        return [NSString stringWithFormat:@"Couldn't finish the swap: %@. Nothing was changed.", reason];
    }
    return nil;
}

UIColor *zs_lowres_original_folder_color(void) {
    return [UIColor colorWithRed:0.35 green:0.78 blue:0.98 alpha:1.0];
}

static UIImage *zs_lowres_folder_image(void) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:32 weight:UIImageSymbolWeightRegular];
    return [[UIImage systemImageNamed:@"folder.fill" withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIView *zs_make_lowres_folder_slot(NSString *name, NSInteger tag, id<UIContextMenuInteractionDelegate> delegate, UIImageView * __strong *iconOut) {
    UIView *slot = [[UIView alloc] init];
    slot.translatesAutoresizingMaskIntoConstraints = NO;
    slot.tag = tag;
    slot.layer.borderWidth = 1;
    slot.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    slot.layer.cornerRadius = 6;
    UIImageView *icon = [[UIImageView alloc] initWithImage:zs_lowres_folder_image()];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = zs_lowres_original_folder_color();
    UILabel *label = zs_make_lowres_label(name, zs_disclosure_secondary_color(), UIFontWeightMedium);
    [slot addSubview:icon];
    [slot addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [slot.widthAnchor constraintEqualToConstant:58],
        [slot.heightAnchor constraintEqualToConstant:58],
        [icon.topAnchor constraintEqualToAnchor:slot.topAnchor constant:5],
        [icon.centerXAnchor constraintEqualToAnchor:slot.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:40],
        [icon.heightAnchor constraintEqualToConstant:32],
        [label.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:3],
        [label.centerXAnchor constraintEqualToAnchor:slot.centerXAnchor],
    ]];
    [slot addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:delegate]];
    if (iconOut) *iconOut = icon;
    return slot;
}

static NSAttributedString *zs_lowres_swap_legend(void) {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineSpacing = 1;
    NSString *text = @"Green is the transcoded folder\nBlue is the original folder\n\nClick the swap icon to switch between them, you must restart the game for changes to take effect";
    NSMutableAttributedString *legend = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: zs_mono_font(9, UIFontWeightMedium),
        NSForegroundColorAttributeName: zs_disclosure_secondary_color(),
        NSParagraphStyleAttributeName: paragraph,
    }];
    [legend addAttribute:NSForegroundColorAttributeName value:zs_accent_green_color() range:[text rangeOfString:@"Green"]];
    [legend addAttribute:NSForegroundColorAttributeName value:zs_lowres_original_folder_color() range:[text rangeOfString:@"Blue"]];
    return legend;
}

UIView *zs_make_lowres_swap_view(id target, SEL swapAction) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *leftIcon = nil;
    UIImageView *rightIcon = nil;
    id<UIContextMenuInteractionDelegate> menuDelegate = (id<UIContextMenuInteractionDelegate>)target;
    UIView *leftSlot = zs_make_lowres_folder_slot(@"backup", 1, menuDelegate, &leftIcon);
    UIView *rightSlot = zs_make_lowres_folder_slot(@"disk", 2, menuDelegate, &rightIcon);

    UIButton *swap = [UIButton buttonWithType:UIButtonTypeSystem];
    swap.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *swapConfig = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [swap setImage:[UIImage systemImageNamed:@"arrow.left.arrow.right" withConfiguration:swapConfig] forState:UIControlStateNormal];
    swap.tintColor = [UIColor colorWithWhite:0.9 alpha:1];
    [swap addTarget:target action:swapAction forControlEvents:UIControlEventTouchUpInside];

    UILabel *legend = [[UILabel alloc] init];
    legend.translatesAutoresizingMaskIntoConstraints = NO;
    legend.numberOfLines = 0;
    legend.attributedText = zs_lowres_swap_legend();

    for (UIView *view in @[leftSlot, rightSlot, swap, legend]) [container addSubview:view];

    UILayoutGuide *leftGuide = [[UILayoutGuide alloc] init];
    UILayoutGuide *rightGuide = [[UILayoutGuide alloc] init];
    [container addLayoutGuide:leftGuide];
    [container addLayoutGuide:rightGuide];

    [NSLayoutConstraint activateConstraints:@[
        [leftGuide.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [leftGuide.trailingAnchor constraintEqualToAnchor:swap.leadingAnchor],
        [rightGuide.leadingAnchor constraintEqualToAnchor:swap.trailingAnchor],
        [rightGuide.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [leftSlot.centerXAnchor constraintEqualToAnchor:leftGuide.centerXAnchor],
        [rightSlot.centerXAnchor constraintEqualToAnchor:rightGuide.centerXAnchor],
        [leftSlot.topAnchor constraintEqualToAnchor:container.topAnchor constant:10],
        [rightSlot.topAnchor constraintEqualToAnchor:container.topAnchor constant:10],

        [swap.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [swap.centerYAnchor constraintEqualToAnchor:leftIcon.centerYAnchor],
        [swap.widthAnchor constraintEqualToConstant:36],
        [swap.heightAnchor constraintEqualToConstant:36],

        [legend.topAnchor constraintEqualToAnchor:leftSlot.bottomAnchor constant:8],
        [legend.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [legend.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [legend.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],
    ]];

    g_zsLowResSwapLeftSlot = leftSlot;
    g_zsLowResSwapRightSlot = rightSlot;
    g_zsLowResSwapLeftIcon = leftIcon;
    g_zsLowResSwapRightIcon = rightIcon;
    g_zsLowResSwapButton = swap;
    return container;
}

UIView *zs_make_lowres_delete_view(id target, SEL confirmAction, SEL cancelAction) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *topSeparator = zs_make_grouped_row_separator();
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.font = zs_mono_font(11, UIFontWeightMedium);
    label.textColor = [UIColor colorWithWhite:0.9 alpha:1];

    UIView *separator = zs_make_grouped_row_separator();
    UIButton *confirm = zs_make_grouped_action_button(@"Confirm", [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0]);
    confirm.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [confirm addTarget:target action:confirmAction forControlEvents:UIControlEventTouchUpInside];
    UIView *cancelSeparator = zs_make_grouped_row_separator();
    UIButton *cancel = zs_make_grouped_action_button(@"Cancel", zs_disclosure_secondary_color());
    cancel.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [cancel addTarget:target action:cancelAction forControlEvents:UIControlEventTouchUpInside];

    for (UIView *view in @[topSeparator, label, separator, confirm, cancelSeparator, cancel]) [container addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [topSeparator.topAnchor constraintEqualToAnchor:container.topAnchor],
        [topSeparator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [topSeparator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [label.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor constant:12],
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:12],
        [separator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [confirm.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        [confirm.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [confirm.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [confirm.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight],
        [cancelSeparator.topAnchor constraintEqualToAnchor:confirm.bottomAnchor],
        [cancelSeparator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [cancelSeparator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [cancel.topAnchor constraintEqualToAnchor:cancelSeparator.bottomAnchor],
        [cancel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [cancel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [cancel.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight],
        [cancel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];
    g_zsLowResDeleteLabel = label;
    return container;
}

NSString *zs_lowres_delete_folder(NSString *shared, BOOL deleteDisk) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *backup = [shared stringByAppendingString:@".backup"];
    NSError *error = nil;
    if (!deleteDisk) {
        if (![fm removeItemAtPath:backup error:&error]) {
            return [NSString stringWithFormat:@"Couldn't delete Shared.backup: %@", error.localizedDescription ?: @"unknown error"];
        }
        return nil;
    }
    NSString *temp = [shared stringByAppendingString:@".deleting"];
    if ([fm fileExistsAtPath:temp]) [fm removeItemAtPath:temp error:nil];
    if (![fm moveItemAtPath:shared toPath:temp error:&error]) {
        return [NSString stringWithFormat:@"Couldn't delete Shared: %@", error.localizedDescription ?: @"unknown error"];
    }
    if (![fm moveItemAtPath:backup toPath:shared error:&error]) {
        NSString *reason = error.localizedDescription ?: @"unknown error";
        NSError *rollbackError = nil;
        if (![fm moveItemAtPath:temp toPath:shared error:&rollbackError]) {
            return [NSString stringWithFormat:@"Couldn't promote Shared.backup: %@. Restoring Shared also failed: %@. Your Shared folder is named Shared.deleting.", reason, rollbackError.localizedDescription ?: @"unknown error"];
        }
        return [NSString stringWithFormat:@"Couldn't promote Shared.backup: %@. Nothing was deleted.", reason];
    }
    [fm removeItemAtPath:temp error:nil];
    return nil;
}

NSString *zs_lowres_block_title(NSUInteger block, BOOL verbose) {
    long percent = lround((1.0 - 36.0 / (double)(block * block)) * 100.0);
    if (verbose) {
        return [NSString stringWithFormat:@"ASTC_%lux%lu (~%ld%% compression)", (unsigned long)block, (unsigned long)block, percent];
    }
    return [NSString stringWithFormat:@"ASTC_%lux%lu (~%ld%%)", (unsigned long)block, (unsigned long)block, percent];
}

static UIView *zs_make_lowres_config_view(id target, SEL codecAction) {
    UIStackView *config = [[UIStackView alloc] init];
    config.translatesAutoresizingMaskIntoConstraints = NO;
    config.axis = UILayoutConstraintAxisVertical;
    config.spacing = 0;
    config.clipsToBounds = YES;
    config.hidden = YES;
    config.alpha = 0;

    NSArray<NSNumber *> *blocks = zs_lowres_block_options();
    NSUInteger blockIndex = (NSUInteger)MAX((NSInteger)0, MIN((NSInteger)blocks.count - 1, g_zsLowResBlockIndex));

    UIView *codecContainer = [[UIView alloc] init];
    codecContainer.translatesAutoresizingMaskIntoConstraints = NO;
    codecContainer.clipsToBounds = YES;
    UIControl *codecRow = zs_make_disclosure_row(@"Codec", zs_lowres_block_title(blocks[blockIndex].unsignedIntegerValue, NO), target, codecAction);
    [codecContainer addSubview:codecRow];
    NSLayoutConstraint *codecHeight = [codecContainer.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight];
    [NSLayoutConstraint activateConstraints:@[
        codecHeight,
        [codecRow.topAnchor constraintEqualToAnchor:codecContainer.topAnchor],
        [codecRow.leadingAnchor constraintEqualToAnchor:codecContainer.leadingAnchor],
        [codecRow.trailingAnchor constraintEqualToAnchor:codecContainer.trailingAnchor],
        [codecRow.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight],
    ]];

    UIView *noteHost = [[UIView alloc] init];
    noteHost.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *note = [[UILabel alloc] init];
    note.translatesAutoresizingMaskIntoConstraints = NO;
    note.numberOfLines = 0;
    note.font = zs_mono_font(9, UIFontWeightRegular);
    note.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    note.text = @"Keep your iDevice turned on and do not close the app to avoid data corruption\nYour game will be paused for the duration of this process";
    [noteHost addSubview:note];
    [NSLayoutConstraint activateConstraints:@[
        [note.topAnchor constraintEqualToAnchor:noteHost.topAnchor constant:4],
        [note.bottomAnchor constraintEqualToAnchor:noteHost.bottomAnchor constant:-12],
        [note.leadingAnchor constraintEqualToAnchor:noteHost.leadingAnchor],
        [note.trailingAnchor constraintEqualToAnchor:noteHost.trailingAnchor],
    ]];

    for (UIView *view in @[codecContainer, zs_make_grouped_row_separator(), noteHost]) [config addArrangedSubview:view];

    g_zsLowResCodecContainer = codecContainer;
    g_zsLowResCodecRow = codecRow;
    g_zsLowResCodecHeight = codecHeight;
    g_zsLowResCodecOptions = nil;
    return config;
}

UIStackView *zs_make_lowres_info_view(id target, SEL action, SEL codecAction) {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    stack.clipsToBounds = YES;

    UIView *topSeparator = zs_make_grouped_row_separator();

    UIView *labelHost = [[UIView alloc] init];
    labelHost.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.font = zs_mono_font(11, UIFontWeightMedium);
    label.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    [labelHost addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:labelHost.topAnchor constant:12],
        [label.bottomAnchor constraintEqualToAnchor:labelHost.bottomAnchor constant:-12],
        [label.leadingAnchor constraintEqualToAnchor:labelHost.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:labelHost.trailingAnchor],
    ]];

    UIView *buttonSeparator = zs_make_grouped_row_separator();
    UIButton *button = zs_make_grouped_action_button(@"Continue", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:0.3] forState:UIControlStateDisabled];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight].active = YES;

    UIView *config = zs_make_lowres_config_view(target, codecAction);

    for (UIView *view in @[topSeparator, labelHost, config, buttonSeparator, button]) [stack addArrangedSubview:view];

    g_zsLowResLabelHost = labelHost;
    g_zsLowResConfigView = config;
    g_zsLowResInfoLabel = label;
    g_zsLowResInfoButton = button;
    g_zsLowResInfoButtonSeparator = buttonSeparator;
    return stack;
}

UIControl *zs_make_disclosure_row(NSString *title, NSString *value, id target, SEL action) {
    UIControl *row = [[UIControl alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    if (target && action) [row addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.userInteractionEnabled = NO;
    titleLabel.text = title;
    titleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    titleLabel.font = zs_mono_font(11, UIFontWeightMedium);
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.8;
    [titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:titleLabel];

    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.userInteractionEnabled = NO;
    valueLabel.text = value;
    valueLabel.textColor = zs_disclosure_secondary_color();
    valueLabel.font = zs_mono_font(11, UIFontWeightLight);
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:valueLabel];

    UIImageSymbolConfiguration *chevronConfig = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
    UIImage *chevronImage = [[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevronConfig]
                             imageWithTintColor:zs_disclosure_secondary_color()
                                  renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:chevronImage];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.userInteractionEnabled = NO;
    chevron.contentMode = UIViewContentModeCenter;
    [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chevron setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [valueLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-4],
        [valueLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:10],
    ]];

    objc_setAssociatedObject(row, "zs_valueLabel", valueLabel, OBJC_ASSOCIATION_RETAIN);
    return row;
}

void zs_disclosure_row_set_value(UIControl *row, NSString *value) {
    UILabel *valueLabel = objc_getAssociatedObject(row, "zs_valueLabel");
    valueLabel.text = value;
}

void zs_disclosure_row_install_menu(UIControl *row, NSArray<NSString *> *titles, NSInteger selectedIndex, void (^onSelect)(NSInteger index)) {
    UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeCustom];
    menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    menuButton.backgroundColor = [UIColor clearColor];
    [row addSubview:menuButton];
    [NSLayoutConstraint activateConstraints:@[
        [menuButton.topAnchor constraintEqualToAnchor:row.topAnchor],
        [menuButton.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [menuButton.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [menuButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    ]];

    __weak UIControl *weakRow = row;
    __weak UIButton *weakButton = menuButton;
    void (^builder)(NSInteger) = ^(NSInteger current) {
        UIButton *strongButton = weakButton;
        if (!strongButton) return;
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray arrayWithCapacity:titles.count];
        for (NSUInteger i = 0; i < titles.count; i++) {
            NSInteger index = (NSInteger)i;
            UIAction *action = [UIAction actionWithTitle:titles[i] image:nil identifier:nil handler:^(__kindof UIAction *picked) {
                UIControl *innerRow = weakRow;
                if (!innerRow) return;
                zs_disclosure_row_set_value(innerRow, titles[index]);
                void (^refresh)(NSInteger) = objc_getAssociatedObject(innerRow, "zs_menuRebuild");
                if (refresh) refresh(index);
                if (onSelect) onSelect(index);
                UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
                [haptic selectionChanged];
            }];
            action.state = index == current ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }
        strongButton.menu = [UIMenu menuWithTitle:@"" children:actions];
    };
    objc_setAssociatedObject(row, "zs_menuRebuild", builder, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSInteger clamped = MAX((NSInteger)0, MIN((NSInteger)titles.count - 1, selectedIndex));
    zs_disclosure_row_set_value(row, titles[clamped]);
    builder(clamped);
    menuButton.showsMenuAsPrimaryAction = YES;
}

#pragma mark Expanding dropdown row

@interface ZSExpandingDropdown : NSObject
@property (nonatomic, weak) UIView *container;
@property (nonatomic, weak) UIControl *row;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
@property (nonatomic, strong) UIView *options;
@property (nonatomic, copy) NSArray<NSString *> *optionTitles;
@property (nonatomic, copy) NSArray<NSString *> *valueTitles;
@property (nonatomic, copy) NSArray *subtexts;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, copy) void (^animator)(dispatch_block_t changes);
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
@end

@implementation ZSExpandingDropdown

- (NSString *)subtextForIndex:(NSUInteger)index {
    if (index >= self.subtexts.count) return nil;
    id entry = self.subtexts[index];
    return [entry isKindOfClass:[NSString class]] && [entry length] ? entry : nil;
}

- (UIView *)buildOptions {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.spacing = 0;

    UIColor *checkColor = [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0];
    UIImageSymbolConfiguration *checkConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    UIImage *checkImage = [[UIImage systemImageNamed:@"checkmark" withConfiguration:checkConfig]
                           imageWithTintColor:checkColor
                                renderingMode:UIImageRenderingModeAlwaysOriginal];
    CGFloat band = kZSGroupedCardRowHeight;

    for (NSUInteger i = 0; i < self.optionTitles.count; i++) {
        UIControl *option = [[UIControl alloc] init];
        option.translatesAutoresizingMaskIntoConstraints = NO;
        option.tag = (NSInteger)i;
        [option addTarget:self action:@selector(optionTapped:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.userInteractionEnabled = NO;
        label.text = self.optionTitles[i];
        label.textColor = [UIColor colorWithWhite:0.9 alpha:1];
        label.font = zs_mono_font(11, UIFontWeightMedium);
        [option addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:option.leadingAnchor],
            [label.centerYAnchor constraintEqualToAnchor:option.topAnchor constant:band / 2.0],
        ]];

        NSString *subtext = [self subtextForIndex:i];
        if (subtext) {
            UILabel *sub = [[UILabel alloc] init];
            sub.translatesAutoresizingMaskIntoConstraints = NO;
            sub.userInteractionEnabled = NO;
            sub.font = zs_mono_font(8, UIFontWeightRegular);
            sub.textColor = [UIColor colorWithWhite:1 alpha:0.4];
            sub.text = subtext;
            sub.numberOfLines = 0;
            [sub setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
            [option addSubview:sub];
            [NSLayoutConstraint activateConstraints:@[
                [sub.topAnchor constraintEqualToAnchor:option.topAnchor constant:band - 4],
                [sub.leadingAnchor constraintEqualToAnchor:option.leadingAnchor],
                [sub.trailingAnchor constraintEqualToAnchor:option.trailingAnchor],
                [sub.bottomAnchor constraintEqualToAnchor:option.bottomAnchor constant:-9],
            ]];
        } else {
            [option.heightAnchor constraintEqualToConstant:band].active = YES;
        }

        if ((NSInteger)i == self.selectedIndex) {
            UIImageView *check = [[UIImageView alloc] initWithImage:checkImage];
            check.translatesAutoresizingMaskIntoConstraints = NO;
            check.userInteractionEnabled = NO;
            check.contentMode = UIViewContentModeCenter;
            [option addSubview:check];
            [NSLayoutConstraint activateConstraints:@[
                [check.trailingAnchor constraintEqualToAnchor:option.trailingAnchor],
                [check.centerYAnchor constraintEqualToAnchor:option.topAnchor constant:band / 2.0],
                [label.trailingAnchor constraintLessThanOrEqualToAnchor:check.leadingAnchor constant:-8],
            ]];
        }

        [stack addArrangedSubview:option];
        if (i + 1 < self.optionTitles.count) [stack addArrangedSubview:zs_make_grouped_row_separator()];
    }
    return stack;
}

- (void)setExpanded:(BOOL)expanded {
    UIView *container = self.container;
    UIControl *row = self.row;
    if (!container || !row || _expanded == expanded) return;
    _expanded = expanded;
    NSUInteger generation = ++self.generation;

    CGFloat collapsedHeight = kZSGroupedCardRowHeight;
    CGFloat expandedHeight = collapsedHeight;
    UIView *options = self.options;
    if (expanded) {
        [options removeFromSuperview];
        options = [self buildOptions];
        options.alpha = 0;
        [container addSubview:options];
        [NSLayoutConstraint activateConstraints:@[
            [options.topAnchor constraintEqualToAnchor:container.topAnchor],
            [options.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [options.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        ]];
        CGFloat width = container.bounds.size.width > 0 ? container.bounds.size.width : 260;
        CGSize fitted = [options systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                               withHorizontalFittingPriority:UILayoutPriorityRequired
                                     verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
        expandedHeight = MAX(collapsedHeight, ceil(fitted.height));
        self.options = options;
    }
    options.userInteractionEnabled = expanded;
    row.userInteractionEnabled = !expanded;

    __weak typeof(self) weakSelf = self;
    dispatch_block_t changes = ^{
        weakSelf.heightConstraint.constant = expanded ? expandedHeight : collapsedHeight;
        row.alpha = expanded ? 0 : 1;
        options.alpha = expanded ? 1 : 0;
    };
    if (self.animator) {
        self.animator(changes);
    } else {
        [container.window layoutIfNeeded];
        [UIView animateWithDuration:0.46
                              delay:0
             usingSpringWithDamping:0.88
              initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            changes();
            UIView *top = container;
            while (top.superview) top = top.superview;
            [top layoutIfNeeded];
        } completion:nil];
    }

    if (!expanded) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.expanded || strongSelf.generation != generation) return;
            [strongSelf.options removeFromSuperview];
            strongSelf.options = nil;
        });
    }
}

- (void)rowTapped {
    [self setExpanded:YES];
    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)optionTapped:(UIControl *)sender {
    NSInteger index = sender.tag;
    if (index >= 0 && index < (NSInteger)self.optionTitles.count) {
        self.selectedIndex = index;
        NSArray<NSString *> *values = self.valueTitles.count == self.optionTitles.count ? self.valueTitles : self.optionTitles;
        UIControl *row = self.row;
        if (row) zs_disclosure_row_set_value(row, values[(NSUInteger)index]);
        if (self.onSelect) self.onSelect(index);
    }
    [self setExpanded:NO];
    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

@end

UIView *zs_make_expanding_dropdown_row(NSString *title, NSArray<NSString *> *optionTitles, NSArray<NSString *> *valueTitles, NSArray *optionSubtexts, NSInteger selectedIndex, void (^animator)(dispatch_block_t changes), void (^onSelect)(NSInteger index)) {
    NSInteger clamped = MAX((NSInteger)0, MIN((NSInteger)optionTitles.count - 1, selectedIndex));
    ZSExpandingDropdown *dropdown = [[ZSExpandingDropdown alloc] init];
    dropdown.optionTitles = optionTitles;
    dropdown.valueTitles = valueTitles;
    dropdown.subtexts = optionSubtexts;
    dropdown.selectedIndex = clamped;
    dropdown.animator = animator;
    dropdown.onSelect = onSelect;

    NSArray<NSString *> *values = valueTitles.count == optionTitles.count ? valueTitles : optionTitles;
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.clipsToBounds = YES;

    UIControl *row = zs_make_disclosure_row(title, values[(NSUInteger)clamped], dropdown, @selector(rowTapped));
    [container addSubview:row];
    NSLayoutConstraint *height = [container.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight];
    [NSLayoutConstraint activateConstraints:@[
        height,
        [row.topAnchor constraintEqualToAnchor:container.topAnchor],
        [row.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [row.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight],
    ]];

    dropdown.container = container;
    dropdown.row = row;
    dropdown.heightConstraint = height;
    objc_setAssociatedObject(container, "zs_expandingDropdown", dropdown, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(container, "zs_selfSizingRow", @YES, OBJC_ASSOCIATION_RETAIN);
    return container;
}

static UIView *zs_enclosing_grouped_card(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (objc_getAssociatedObject(candidate, "zs_innerStack")) return candidate;
    }
    return nil;
}

UIStackView *zs_make_card_options_stack(NSArray<NSString *> *titles, NSInteger selectedIndex, id target, SEL action) {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.spacing = 0;

    UIColor *checkColor = [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0];
    UIImageSymbolConfiguration *checkConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    UIImage *checkImage = [[UIImage systemImageNamed:@"checkmark" withConfiguration:checkConfig]
                           imageWithTintColor:checkColor
                                renderingMode:UIImageRenderingModeAlwaysOriginal];

    for (NSUInteger i = 0; i < titles.count; i++) {
        UIControl *option = [[UIControl alloc] init];
        option.translatesAutoresizingMaskIntoConstraints = NO;
        option.tag = (NSInteger)i;
        [option addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        [option.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight].active = YES;

        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.userInteractionEnabled = NO;
        label.text = titles[i];
        label.textColor = [UIColor colorWithWhite:0.9 alpha:1];
        label.font = zs_mono_font(11, UIFontWeightMedium);
        [option addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:option.leadingAnchor],
            [label.centerYAnchor constraintEqualToAnchor:option.centerYAnchor],
        ]];

        if ((NSInteger)i == selectedIndex) {
            UIImageView *check = [[UIImageView alloc] initWithImage:checkImage];
            check.translatesAutoresizingMaskIntoConstraints = NO;
            check.userInteractionEnabled = NO;
            check.contentMode = UIViewContentModeCenter;
            [option addSubview:check];
            [NSLayoutConstraint activateConstraints:@[
                [check.trailingAnchor constraintEqualToAnchor:option.trailingAnchor],
                [check.centerYAnchor constraintEqualToAnchor:option.centerYAnchor],
                [label.trailingAnchor constraintLessThanOrEqualToAnchor:check.leadingAnchor constant:-8],
            ]];
        }

        [stack addArrangedSubview:option];
        if (i + 1 < titles.count) {
            [stack addArrangedSubview:zs_make_grouped_row_separator()];
        }
    }
    return stack;
}

static NSArray<UIColor *> *zs_memory_chart_palette(void) {
    return @[
        [UIColor colorWithRed:0.09 green:0.24 blue:0.58 alpha:1.0],
        [UIColor colorWithRed:0.04 green:0.46 blue:0.22 alpha:1.0],
        [UIColor colorWithRed:0.74 green:0.52 blue:0.02 alpha:1.0],
        [UIColor colorWithRed:0.66 green:0.06 blue:0.12 alpha:1.0],
        [UIColor colorWithRed:0.34 green:0.08 blue:0.58 alpha:1.0],
        [UIColor colorWithRed:0.02 green:0.42 blue:0.44 alpha:1.0],
        [UIColor colorWithRed:0.70 green:0.30 blue:0.02 alpha:1.0],
        [UIColor colorWithRed:0.16 green:0.10 blue:0.60 alpha:1.0],
        [UIColor colorWithRed:0.58 green:0.06 blue:0.36 alpha:1.0],
        [UIColor colorWithRed:0.08 green:0.38 blue:0.10 alpha:1.0],
        [UIColor colorWithRed:0.52 green:0.42 blue:0.02 alpha:1.0],
        [UIColor colorWithWhite:0.24 alpha:1.0],
    ];
}

static UIColor *zs_memory_color_for_index(NSUInteger index, BOOL isOther) {
    NSArray<UIColor *> *palette = zs_memory_chart_palette();
    if (isOther) return palette.lastObject;
    NSUInteger distinctCount = palette.count - 1;
    if (index < distinctCount) return palette[index];
    NSUInteger extra = index - distinctCount;
    CGFloat hue = fmod(0.137 * (double)extra + 0.06, 1.0);
    CGFloat brightness = (extra / 7) % 2 == 0 ? 0.72 : 0.52;
    return [UIColor colorWithHue:hue saturation:0.68 brightness:brightness alpha:1.0];
}

@implementation ZSMemoryColumnRow
@end

static const CGFloat kZSMemoryColumnVerticalInset = 6;
static const CGFloat kZSMemoryHeaderGap = 10;
static const CGFloat kZSMemoryPillarWidth = 28;
static const CGFloat kZSMemoryPillarGap = 12;
static const CGFloat kZSMemorySwatchSize = 8;
static const CGFloat kZSMemorySwatchGap = 6;
static const CGFloat kZSMemoryTwoLineThreshold = 27;
static const CGFloat kZSMemoryMinRowHeight = 13;
static const CGFloat kZSMemoryLegendColumnGap = 18;
static const CGFloat kZSMemoryMinInnerWidth = 200;
static const CGFloat kZSMemoryMaxNameWidth = 260;
static const CGFloat kZSMemoryMaxDetailWidth = 380;

NSArray<NSArray<NSString *> *> *zs_memory_page_titles(BOOL fullScreen) {
    if (fullScreen) {
        return @[
            @[@"System"],
            @[@"Process footprint by owner", @"Unity allocations by subsystem"],
            @[@"Malloc zones", @"Malloc attribution"],
            @[@"Heaviest loaded assets", @"Live object counts"],
            @[@"Reservations & diagnostics", @"Clean file-backed pages"],
        ];
    }
    return @[
        @[@"System"],
        @[@"Process footprint by owner"],
        @[@"Unity allocations by subsystem"],
        @[@"Malloc zones"],
        @[@"Malloc attribution"],
        @[@"Heaviest loaded assets"],
        @[@"Live object counts"],
        @[@"Reservations & diagnostics", @"Clean file-backed pages"],
    ];
}

static CGFloat zs_memory_column_fraction(NSString *title, BOOL fullScreen) {
    static NSDictionary<NSString *, NSNumber *> *fullFractions;
    static NSDictionary<NSString *, NSNumber *> *partialFractions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fullFractions = @{
            @"System": @0.5,
            @"Process footprint by owner": @0.6,
            @"Unity allocations by subsystem": @0.4,
            @"Malloc zones": @0.4,
            @"Malloc attribution": @0.6,
            @"Heaviest loaded assets": @0.7,
            @"Live object counts": @0.3,
            @"Reservations & diagnostics": @0.6,
            @"Clean file-backed pages": @0.4,
        };
        partialFractions = @{
            @"System": @1.0,
            @"Process footprint by owner": @1.0,
            @"Unity allocations by subsystem": @1.0,
            @"Malloc zones": @1.0,
            @"Malloc attribution": @1.0,
            @"Heaviest loaded assets": @1.0,
            @"Live object counts": @1.0,
            @"Reservations & diagnostics": @0.6,
            @"Clean file-backed pages": @0.4,
        };
    });
    if (!title) return 0;
    return (fullScreen ? fullFractions : partialFractions)[title].doubleValue;
}

CGFloat zs_memory_column_width(NSString *title, CGFloat windowWidth, BOOL fullScreen) {
    CGFloat fraction = zs_memory_column_fraction(title, fullScreen);
    return fraction > 0 ? floor(windowWidth * fraction) : 0;
}

static NSMutableDictionary<NSString *, NSNumber *> *g_memorySubtitleShrinkState;

static CGFloat zs_memory_text_width(NSString *text, UIFont *font) {
    if (text.length == 0) return 0;
    return ceil([text sizeWithAttributes:@{NSFontAttributeName: font}].width);
}

CGFloat zs_memory_clamp(CGFloat value, CGFloat low, CGFloat high) {
    return MAX(low, MIN(high, value));
}

static CGSize zs_memory_wrapped_size(NSString *text, UIFont *font, CGFloat width) {
    if (text.length == 0) return CGSizeZero;
    CGRect rect = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                  attributes:@{NSFontAttributeName: font}
                                     context:nil];
    return CGSizeMake(ceil(rect.size.width), ceil(rect.size.height));
}

NSAttributedString *zs_memory_fetch_subtext(UIColor *color) {
    return [[NSAttributedString alloc] initWithString:@"FETCHING INFO"
                                           attributes:@{NSFontAttributeName: zs_mono_font(8, UIFontWeightSemibold),
                                                        NSForegroundColorAttributeName: color,
                                                        NSKernAttributeName: @1.2}];
}

UILabel *zs_memory_make_label(NSString *text, UIFont *font, UIColor *color, NSTextAlignment alignment) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.textAlignment = alignment;
    label.numberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    return label;
}

UIView *zs_build_memory_column(NSString *title,
                                      NSString *subtitle,
                                      NSArray<ZSMemoryColumnRow *> *rows,
                                      NSArray<NSNumber *> *fractions,
                                      BOOL compactStats,
                                      CGFloat headerTrailingReserve,
                                      CGFloat fixedColumnWidth,
                                      CGFloat height,
                                      BOOL localPaging,
                                      NSUInteger *pageInOut,
                                      NSUInteger *pageCountOut) {
    NSUInteger count = rows.count;
    if (pageCountOut) *pageCountOut = 1;
    if (count == 0 || height <= 0) return nil;

    BOOL hasPillar = fractions.count == count;
    BOOL showsSwatch = !compactStats;
    CGFloat swatchWidth = showsSwatch ? (kZSMemorySwatchSize + kZSMemorySwatchGap) : 0;
    CGFloat pillarExtra = hasPillar ? (kZSMemoryPillarWidth + kZSMemoryPillarGap) : 0;
    CGFloat usableHeight = height - kZSMemoryColumnVerticalInset * 2;

    UIFont *titleFont = zs_mono_font(12, UIFontWeightSemibold);
    UIFont *subtitleFont = zs_mono_font(9, UIFontWeightRegular);
    CGFloat titleWidth = MIN(zs_memory_text_width(title, titleFont), 340);
    CGFloat subtitleNaturalWidth = zs_memory_text_width(subtitle, subtitleFont);
    if (!g_memorySubtitleShrinkState) g_memorySubtitleShrinkState = [NSMutableDictionary new];
    NSString *shrinkStateKey = title ?: @"";
    BOOL previouslyShrunk = [g_memorySubtitleShrinkState[shrinkStateKey] boolValue];
    __block BOOL shrinkSubtitle = NO;

    CGFloat fixedInnerWidth = fixedColumnWidth > 0 ? fixedColumnWidth - kZSMemoryColumnPadding * 2 : 0;
    NSUInteger minLegendColumns = 1;
    NSUInteger maxLegendColumns = localPaging ? 1 : 3;
    if (compactStats) {
        maxLegendColumns = fixedInnerWidth > 0 ? (NSUInteger)zs_memory_clamp(floor(fixedInnerWidth / 120.0), 1, 6) : 4;
        minLegendColumns = fixedInnerWidth > 0 ? (NSUInteger)zs_memory_clamp(floor(fixedInnerWidth / 250.0), 1, maxLegendColumns) : 1;
    }
    CGFloat minRowHeight = compactStats ? 15 : kZSMemoryMinRowHeight;

    __block CGFloat fontSize = compactStats ? 11 : 10;
    __block BOOL twoLine = NO;
    __block NSUInteger legendColumns = minLegendColumns;
    __block CGFloat nameWidth = 0;
    __block CGFloat detailWidth = 0;
    __block CGFloat valueWidth = 0;
    __block CGFloat innerWidth = 0;
    __block CGFloat titleHeight = 0;
    __block CGFloat subtitleHeight = 0;
    __block CGFloat headerHeight = 0;
    __block CGFloat regionHeight = 0;
    BOOL lockedSingleLine = NO;

    void (^measure)(void) = ^{
        UIFont *nameFont = zs_mono_font(fontSize, compactStats ? UIFontWeightRegular : UIFontWeightMedium);
        UIFont *valueFont = zs_mono_font(fontSize, UIFontWeightMedium);
        UIFont *detailFont = zs_mono_font(MAX(fontSize - 1, 7), UIFontWeightRegular);

        nameWidth = 0;
        detailWidth = 0;
        valueWidth = 0;
        for (ZSMemoryColumnRow *row in rows) {
            nameWidth = MAX(nameWidth, zs_memory_text_width(row.name, nameFont));
            detailWidth = MAX(detailWidth, zs_memory_text_width(row.detail, detailFont));
            valueWidth = MAX(valueWidth, zs_memory_text_width(row.value, valueFont));
        }
        nameWidth = MIN(nameWidth, kZSMemoryMaxNameWidth);
        detailWidth = MIN(detailWidth, kZSMemoryMaxDetailWidth);

        CGFloat rowsWidth;
        if (twoLine) {
            CGFloat lineOneWidth = swatchWidth + nameWidth + (valueWidth > 0 ? 12 + valueWidth : 0);
            rowsWidth = MAX(lineOneWidth, swatchWidth + detailWidth);
        } else {
            rowsWidth = swatchWidth + nameWidth + (detailWidth > 0 ? 10 + detailWidth : 0) + (valueWidth > 0 ? 14 + valueWidth : 0);
        }
        CGFloat legendWidth = rowsWidth * (CGFloat)legendColumns + kZSMemoryLegendColumnGap * (CGFloat)(legendColumns - 1);
        innerWidth = MAX(MAX(pillarExtra + legendWidth, titleWidth + headerTrailingReserve), kZSMemoryMinInnerWidth);
        if (fixedColumnWidth > 0) innerWidth = fixedColumnWidth - kZSMemoryColumnPadding * 2;

        titleHeight = zs_memory_wrapped_size(title, titleFont, innerWidth - headerTrailingReserve).height;
        shrinkSubtitle = subtitleNaturalWidth > 0 && subtitleNaturalWidth / innerWidth <= (previouslyShrunk ? 1.4 : 1.2);
        subtitleHeight = shrinkSubtitle ? ceil(subtitleFont.lineHeight) : zs_memory_wrapped_size(subtitle, subtitleFont, innerWidth).height;
        headerHeight = titleHeight + (subtitleHeight > 0 ? 3 + subtitleHeight : 0);
        regionHeight = usableHeight - headerHeight - kZSMemoryHeaderGap;
    };

    NSArray<ZSMemoryColumnRow *> *pageRows = rows;
    NSArray<NSNumber *> *pageFractions = fractions;
    NSUInteger layoutCount = count;

    if (localPaging) {
        measure();
        NSUInteger capacity = MAX((NSUInteger)floor(MAX(regionHeight, 0) / kZSMemoryMinRowHeight), (NSUInteger)1);
        if (count > capacity) {
            NSUInteger totalPages = (count + capacity - 1) / capacity;
            NSUInteger page = MIN(pageInOut ? *pageInOut : 0, totalPages - 1);
            NSUInteger start = page * capacity;
            NSRange range = NSMakeRange(start, MIN(capacity, count - start));
            pageRows = [rows subarrayWithRange:range];
            if (hasPillar) {
                NSArray<NSNumber *> *slice = [fractions subarrayWithRange:range];
                double sliceTotal = 0;
                for (NSNumber *fraction in slice) sliceTotal += fraction.doubleValue;
                NSMutableArray<NSNumber *> *normalized = [NSMutableArray arrayWithCapacity:slice.count];
                for (NSNumber *fraction in slice) [normalized addObject:@(sliceTotal > 0 ? fraction.doubleValue / sliceTotal : 0)];
                pageFractions = normalized;
            }
            layoutCount = capacity;
            if (pageInOut) *pageInOut = page;
            if (pageCountOut) *pageCountOut = totalPages;
        } else if (pageInOut) {
            *pageInOut = 0;
        }
    }

    for (NSInteger pass = 0; pass < 5; pass++) {
        measure();

        NSUInteger nextLegendColumns = MAX(legendColumns, minLegendColumns);
        while (nextLegendColumns < maxLegendColumns) {
            NSUInteger perColumn = (layoutCount + nextLegendColumns - 1) / nextLegendColumns;
            if (floor(regionHeight / (CGFloat)perColumn) >= minRowHeight) break;
            nextLegendColumns++;
        }
        NSUInteger rowsPerColumn = (layoutCount + nextLegendColumns - 1) / nextLegendColumns;
        CGFloat availableRow = floor(regionHeight / (CGFloat)rowsPerColumn);

        BOOL nextTwoLine = !compactStats && !lockedSingleLine && nextLegendColumns == 1 && availableRow >= kZSMemoryTwoLineThreshold;
        if (twoLine && !nextTwoLine) lockedSingleLine = YES;

        CGFloat nextFontSize;
        if (compactStats) nextFontSize = zs_memory_clamp(availableRow - 6, 8, 11);
        else if (nextTwoLine) nextFontSize = 11;
        else nextFontSize = zs_memory_clamp(availableRow - 4, 7, 10);

        BOOL stable = (nextTwoLine == twoLine) && (nextLegendColumns == legendColumns) && fabs(nextFontSize - fontSize) < 0.3;
        twoLine = nextTwoLine;
        legendColumns = nextLegendColumns;
        fontSize = nextFontSize;
        if (stable) break;
    }

    measure();
    NSUInteger rowsPerColumn = (layoutCount + legendColumns - 1) / legendColumns;
    if (twoLine && floor(regionHeight / (CGFloat)rowsPerColumn) < 24) {
        twoLine = NO;
        measure();
    }

    g_memorySubtitleShrinkState[shrinkStateKey] = @(shrinkSubtitle);

    CGFloat availableRowHeight = MAX(floor(regionHeight / (CGFloat)rowsPerColumn), 1);
    CGFloat rowHeight = twoLine ? MIN(availableRowHeight, 38) : MIN(availableRowHeight, compactStats ? 24 : 22);

    CGFloat columnWidth = innerWidth + kZSMemoryColumnPadding * 2;
    UIView *column = [[UIView alloc] initWithFrame:CGRectMake(0, 0, columnWidth, height)];
    column.backgroundColor = UIColor.clearColor;
    column.accessibilityIdentifier = title;

    CGFloat left = kZSMemoryColumnPadding;
    CGFloat top = kZSMemoryColumnVerticalInset;

    UILabel *titleLabel = zs_memory_make_label(title, titleFont, [UIColor colorWithWhite:0.96 alpha:1], NSTextAlignmentLeft);
    titleLabel.numberOfLines = 0;
    titleLabel.adjustsFontSizeToFitWidth = NO;
    titleLabel.frame = CGRectMake(left, top, innerWidth - headerTrailingReserve, titleHeight);
    [column addSubview:titleLabel];

    if (subtitleHeight > 0) {
        UILabel *subtitleLabel = zs_memory_make_label(subtitle, subtitleFont, [UIColor colorWithWhite:1 alpha:0.5], NSTextAlignmentLeft);
        subtitleLabel.numberOfLines = shrinkSubtitle ? 1 : 0;
        subtitleLabel.adjustsFontSizeToFitWidth = shrinkSubtitle;
        subtitleLabel.minimumScaleFactor = 0.65;
        subtitleLabel.frame = CGRectMake(left, top + titleHeight + 3, innerWidth, subtitleHeight);
        [column addSubview:subtitleLabel];
    }

    CGFloat regionTop = top + headerHeight + kZSMemoryHeaderGap;

    if (hasPillar) {
        ZSPillarChartView *pillar = [[ZSPillarChartView alloc] initWithFrame:CGRectMake(left, regionTop, kZSMemoryPillarWidth, regionHeight)];
        NSMutableArray<UIColor *> *pillarColors = [NSMutableArray arrayWithCapacity:count];
        for (ZSMemoryColumnRow *row in pageRows) [pillarColors addObject:row.color ?: UIColor.grayColor];
        [column addSubview:pillar];
        [pillar setSegmentsWithFractions:pageFractions colors:pillarColors];
    }

    UIFont *nameFont = zs_mono_font(fontSize, compactStats ? UIFontWeightRegular : UIFontWeightMedium);
    UIFont *valueFont = zs_mono_font(fontSize, UIFontWeightMedium);
    UIFont *detailFont = zs_mono_font(MAX(fontSize - 1, 7), UIFontWeightRegular);
    UIColor *nameColor = compactStats ? [UIColor colorWithWhite:1 alpha:0.5] : [UIColor colorWithWhite:0.92 alpha:1];
    UIColor *valueColor = [UIColor colorWithWhite:0.92 alpha:1];
    UIColor *detailColor = [UIColor colorWithWhite:1 alpha:0.5];

    CGFloat legendLeft = left + pillarExtra;
    CGFloat legendWidth = (innerWidth - pillarExtra - kZSMemoryLegendColumnGap * (CGFloat)(legendColumns - 1)) / (CGFloat)legendColumns;
    CGFloat lineOneBox = ceil(nameFont.lineHeight) + 2;
    CGFloat detailLineHeight = ceil(detailFont.lineHeight);
    CGFloat lineBudget = legendWidth - swatchWidth - (valueWidth > 0 ? 14 + valueWidth : 0);
    CGFloat drawNameWidth = nameWidth;
    CGFloat drawDetailWidth = detailWidth;
    if (!twoLine) {
        if (detailWidth > 0 && nameWidth + 10 + detailWidth > lineBudget) {
            drawDetailWidth = MAX(lineBudget - 10 - nameWidth, lineBudget * 0.3);
            drawNameWidth = MAX(MIN(nameWidth, lineBudget - 10 - drawDetailWidth), 40);
        } else if (nameWidth > lineBudget) {
            drawNameWidth = MAX(lineBudget, 40);
        }
    }
    CGFloat twoLineBlockHeight = lineOneBox + detailLineHeight;

    for (NSUInteger i = 0; i < pageRows.count; i++) {
        ZSMemoryColumnRow *row = pageRows[i];
        NSUInteger legendIndex = i / rowsPerColumn;
        NSUInteger rowIndex = i % rowsPerColumn;

        CGFloat rowsLeft = legendLeft + (legendWidth + kZSMemoryLegendColumnGap) * (CGFloat)legendIndex;
        CGFloat rightEdge = rowsLeft + legendWidth;
        CGFloat nameX = rowsLeft + swatchWidth;
        CGFloat valueX = rightEdge - valueWidth;

        CGFloat rowY = regionTop + rowHeight * (CGFloat)rowIndex;
        CGFloat lineY = twoLine ? rowY + floor((rowHeight - twoLineBlockHeight) / 2.0) : rowY;
        CGFloat lineH = twoLine ? lineOneBox : rowHeight;

        if (showsSwatch) {
            UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(rowsLeft, lineY + floor((lineH - kZSMemorySwatchSize) / 2.0), kZSMemorySwatchSize, kZSMemorySwatchSize)];
            swatch.backgroundColor = row.color ?: UIColor.grayColor;
            swatch.layer.cornerRadius = 2.5;
            swatch.layer.cornerCurve = kCACornerCurveContinuous;
            [column addSubview:swatch];
        }

        if (valueWidth > 0 && row.value.length > 0) {
            UILabel *valueLabel = zs_memory_make_label(row.value, valueFont, valueColor, NSTextAlignmentRight);
            valueLabel.adjustsFontSizeToFitWidth = NO;
            valueLabel.frame = CGRectMake(valueX, lineY, valueWidth, lineH);
            [column addSubview:valueLabel];
        }

        if (twoLine) {
            CGFloat nameMax = (valueWidth > 0 ? valueX - 12 : rightEdge) - nameX;
            UILabel *nameLabel = zs_memory_make_label(row.name, nameFont, nameColor, NSTextAlignmentLeft);
            nameLabel.frame = CGRectMake(nameX, lineY, MAX(nameMax, 40), lineH);
            [column addSubview:nameLabel];

            if (row.detail.length > 0) {
                UILabel *detailLabel = zs_memory_make_label(row.detail, detailFont, detailColor, NSTextAlignmentLeft);
                detailLabel.frame = CGRectMake(nameX, lineY + lineH, rightEdge - nameX, detailLineHeight);
                [column addSubview:detailLabel];
            }
        } else {
            UILabel *nameLabel = zs_memory_make_label(row.name, nameFont, nameColor, NSTextAlignmentLeft);
            nameLabel.frame = CGRectMake(nameX, rowY, drawNameWidth, rowHeight);
            [column addSubview:nameLabel];

            if (detailWidth > 0 && row.detail.length > 0) {
                UILabel *detailLabel = zs_memory_make_label(row.detail, detailFont, detailColor, NSTextAlignmentLeft);
                detailLabel.frame = CGRectMake(nameX + drawNameWidth + 10, rowY, drawDetailWidth, rowHeight);
                [column addSubview:detailLabel];
            }
        }
    }

    return column;
}

static const CGFloat kZSMemoryPageButtonSize = 22;
static const CGFloat kZSMemoryPageLabelWidth = 30;

static UIButton *zs_memory_make_page_button(NSString *symbolName, BOOL enabled, void (^handler)(void)) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbolName withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.enabled = enabled;
    button.alpha = enabled ? 0.9 : 0.28;
    if (handler) {
        [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            handler();
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    return button;
}

NSString *zs_memory_megabytes_string(int64_t bytes) {
    return [NSString stringWithFormat:@"%.2fMB", (double)bytes / (1024.0 * 1024.0)];
}

UIVisualEffectView *zs_memory_make_popup_surface(CGSize size) {
    UIVisualEffect *effect = zs_has_liquid_glass()
        ? zs_make_glass_effect_dark(NO)
        : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark];
    UIVisualEffectView *surface = [[UIVisualEffectView alloc] initWithEffect:effect];
    surface.frame = CGRectMake(0, 0, size.width, size.height);
    if (zs_has_liquid_glass()) {
        zs_configure_glass_corners(surface, 18, NO);
    } else {
        surface.layer.cornerRadius = 18;
        surface.layer.cornerCurve = kCACornerCurveContinuous;
        surface.clipsToBounds = YES;
    }
    zs_force_dark(surface);
    return surface;
}

CGRect zs_memory_popup_frame(UIView *overlay, UIView *source, CGSize desired) {
    CGRect anchor = [source convertRect:source.bounds toView:overlay];
    UIEdgeInsets insets = overlay.safeAreaInsets;
    CGFloat minX = insets.left + 8;
    CGFloat maxX = MAX(minX, overlay.bounds.size.width - insets.right - 8 - desired.width);
    CGFloat x = MIN(MAX(anchor.origin.x, minX), maxX);
    CGFloat top = insets.top + 8;
    CGFloat bottom = overlay.bounds.size.height - insets.bottom - 8;
    CGFloat height = MIN(desired.height, MAX(bottom - top, 60));
    CGFloat y = CGRectGetMaxY(anchor) + 6;
    if (y + height > bottom) y = MAX(top, bottom - height);
    return CGRectMake(x, y, desired.width, height);
}

UIView *zs_build_memory_group_column(ZSMemoryUsageGroup *group,
                                            CGFloat height,
                                            CGFloat windowWidth,
                                            BOOL fullScreen,
                                            NSUInteger localPage,
                                            void (^onLocalPageChange)(NSUInteger page),
                                            void (^onPageChange)(NSInteger delta),
                                            void (^onFilterTap)(UIView *source),
                                            void (^onPageTap)(UIView *source)) {
    if (group.categories.count == 0) return nil;

    int64_t grandTotal = 0;
    for (ZSMemoryUsageCategory *category in group.categories) grandTotal += category.totalBytes;
    if (group.showsChart && grandTotal <= 0) return nil;

    NSMutableArray<ZSMemoryColumnRow *> *rows = [NSMutableArray arrayWithCapacity:group.categories.count];
    NSMutableArray<NSNumber *> *fractions = group.showsChart ? [NSMutableArray arrayWithCapacity:group.categories.count] : nil;
    UIColor *listSwatchColor = [UIColor colorWithWhite:0.32 alpha:1.0];

    for (NSUInteger i = 0; i < group.categories.count; i++) {
        ZSMemoryUsageCategory *category = group.categories[i];
        NSString *sizeText = [NSByteCountFormatter stringFromByteCount:(long long)category.totalBytes countStyle:NSByteCountFormatterCountStyleMemory];

        ZSMemoryColumnRow *row = [ZSMemoryColumnRow new];
        row.name = category.name ?: @"";
        row.detail = category.detail ?: @"";

        if (group.showsChart) {
            double fraction = (double)category.totalBytes / (double)grandTotal;
            [fractions addObject:@(fraction)];
            row.color = zs_memory_color_for_index(i, [category.name hasPrefix:@"Other ("]);
            row.value = [NSString stringWithFormat:@"%.1f%% · %@", fraction * 100.0, sizeText];
        } else {
            row.color = listSwatchColor;
            if (category.totalBytes > 0) {
                row.value = sizeText;
            } else if (category.objectCount > 0) {
                row.value = [NSString stringWithFormat:@"%lu objects", (unsigned long)category.objectCount];
            } else {
                row.value = @"";
            }
        }
        [rows addObject:row];
    }

    BOOL localPaging = !group.pagingEnabled && group.showsChart && onLocalPageChange != nil;
    BOOL showsPaging = group.pagingEnabled && onPageChange != nil;
    BOOL showsFilter = showsPaging && onFilterTap != nil && group.kindOptions.count > 0;
    CGFloat filterWidth = showsFilter ? kZSMemoryPageButtonSize : 0;
    CGFloat controlsWidth = filterWidth + kZSMemoryPageButtonSize * 2 + kZSMemoryPageLabelWidth;
    CGFloat reserve = (showsPaging || localPaging) ? controlsWidth + 10 : 0;
    CGFloat columnWidth = zs_memory_column_width(group.title, windowWidth, fullScreen);
    NSUInteger resolvedPage = localPage;
    NSUInteger localPageCount = 1;
    UIView *column = zs_build_memory_column(group.title, group.subtitle, rows, fractions, NO, reserve, columnWidth, height, localPaging, &resolvedPage, &localPageCount);
    if (!column) return nil;

    if (localPaging) {
        if (localPageCount <= 1) return column;

        CGFloat lineHeight = ceil(zs_mono_font(12, UIFontWeightSemibold).lineHeight);
        CGFloat localControlsY = kZSMemoryColumnVerticalInset + floor((lineHeight - kZSMemoryPageButtonSize) / 2.0);
        CGFloat localControlsX = column.bounds.size.width - kZSMemoryColumnPadding - controlsWidth;

        UIButton *localPrevious = zs_memory_make_page_button(@"chevron.left", resolvedPage > 0, ^{ onLocalPageChange(resolvedPage - 1); });
        localPrevious.frame = CGRectMake(localControlsX, localControlsY, kZSMemoryPageButtonSize, kZSMemoryPageButtonSize);
        [column addSubview:localPrevious];

        UILabel *localLabel = [[UILabel alloc] initWithFrame:CGRectMake(localControlsX + kZSMemoryPageButtonSize, localControlsY, kZSMemoryPageLabelWidth, kZSMemoryPageButtonSize)];
        localLabel.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)(resolvedPage + 1), (unsigned long)localPageCount];
        localLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
        localLabel.font = zs_mono_font(10, UIFontWeightMedium);
        localLabel.textAlignment = NSTextAlignmentCenter;
        localLabel.adjustsFontSizeToFitWidth = YES;
        localLabel.minimumScaleFactor = 0.6;
        [column addSubview:localLabel];

        UIButton *localNext = zs_memory_make_page_button(@"chevron.right", resolvedPage + 1 < localPageCount, ^{ onLocalPageChange(resolvedPage + 1); });
        localNext.frame = CGRectMake(localControlsX + kZSMemoryPageButtonSize + kZSMemoryPageLabelWidth, localControlsY, kZSMemoryPageButtonSize, kZSMemoryPageButtonSize);
        [column addSubview:localNext];
        return column;
    }

    if (!showsPaging) return column;

    CGFloat titleLineHeight = ceil(zs_mono_font(12, UIFontWeightSemibold).lineHeight);
    CGFloat controlsY = kZSMemoryColumnVerticalInset + floor((titleLineHeight - kZSMemoryPageButtonSize) / 2.0);
    CGFloat controlsX = column.bounds.size.width - kZSMemoryColumnPadding - controlsWidth;

    if (showsFilter) {
        BOOL filtering = group.activeKind.length > 0;
        UIButton *filter = zs_memory_make_page_button(filtering ? @"line.3.horizontal.decrease.circle.fill" : @"line.3.horizontal.decrease.circle", YES, nil);
        filter.frame = CGRectMake(controlsX, controlsY, kZSMemoryPageButtonSize, kZSMemoryPageButtonSize);
        __weak UIButton *weakFilter = filter;
        [filter addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            UIButton *strongFilter = weakFilter;
            if (strongFilter) onFilterTap(strongFilter);
        }] forControlEvents:UIControlEventTouchUpInside];
        [column addSubview:filter];
    }

    CGFloat pagerX = controlsX + filterWidth;

    UIButton *previous = zs_memory_make_page_button(@"chevron.left", group.pageIndex > 0, ^{ onPageChange(-1); });
    previous.frame = CGRectMake(pagerX, controlsY, kZSMemoryPageButtonSize, kZSMemoryPageButtonSize);
    [column addSubview:previous];

    UIButton *pageButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [pageButton setTitle:[NSString stringWithFormat:@"%lu", (unsigned long)(group.pageIndex + 1)] forState:UIControlStateNormal];
    [pageButton setTitleColor:[UIColor colorWithWhite:0.92 alpha:1] forState:UIControlStateNormal];
    pageButton.titleLabel.font = zs_mono_font(10, UIFontWeightMedium);
    pageButton.frame = CGRectMake(pagerX + kZSMemoryPageButtonSize, controlsY, kZSMemoryPageLabelWidth, kZSMemoryPageButtonSize);
    if (onPageTap) {
        __weak UIButton *weakPageButton = pageButton;
        [pageButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            UIButton *strongPageButton = weakPageButton;
            if (strongPageButton) onPageTap(strongPageButton);
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    [column addSubview:pageButton];

    UIButton *next = zs_memory_make_page_button(@"chevron.right", group.hasNextPage, ^{ onPageChange(1); });
    next.frame = CGRectMake(pagerX + kZSMemoryPageButtonSize + kZSMemoryPageLabelWidth, controlsY, kZSMemoryPageButtonSize, kZSMemoryPageButtonSize);
    [column addSubview:next];

    return column;
}

static NSString *zs_memory_count_string(int64_t value) {
    if (value >= 1000000000) return [NSString stringWithFormat:@"%.2fB", (double)value / 1e9];
    if (value >= 1000000) return [NSString stringWithFormat:@"%.2fM", (double)value / 1e6];
    if (value >= 1000) return [NSString stringWithFormat:@"%.1fK", (double)value / 1e3];
    return [NSString stringWithFormat:@"%lld", (long long)value];
}

NSArray<ZSMemoryColumnRow *> *zs_memory_system_stat_rows(ZSMemorySystemStats stats) {
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleMemory;

    NSString *(^bytes)(int64_t, NSString *) = ^NSString *(int64_t value, NSString *fallback) {
        return value > 0 ? [formatter stringFromByteCount:(long long)value] : fallback;
    };
    NSString *(^count)(int64_t) = ^NSString *(int64_t value) {
        return value > 0 ? zs_memory_count_string(value) : @"0";
    };

    NSString *limitUsedText = stats.memoryLimitApproxBytes > 0
        ? [NSString stringWithFormat:@"%.1f%%", (double)MAX(0, stats.residentBytes) / (double)stats.memoryLimitApproxBytes * 100.0]
        : @"Unknown";
    NSString *pressureText = stats.pressureLabel ? [NSString stringWithUTF8String:stats.pressureLabel] : @"Unknown";
    NSString *ratioText = stats.compressionRatio > 0 ? [NSString stringWithFormat:@"%.2fx", stats.compressionRatio] : @"None";
    NSString *freeLevelText = stats.freeLevelPercent > 0 ? [NSString stringWithFormat:@"%lld%%", (long long)stats.freeLevelPercent] : @"Unknown";

    NSArray<NSArray<NSString *> *> *pairs = @[
        @[@"Footprint", bytes(MAX(0, stats.residentBytes), @"Unknown")],
        @[@"Peak footprint", bytes(stats.peakFootprintBytes, @"Unknown")],
        @[@"Resident", bytes(stats.residentSizeBytes, @"Unknown")],
        @[@"Peak resident", bytes(stats.peakResidentBytes, @"Unknown")],
        @[@"Dirty", bytes(stats.internalBytes, @"Unknown")],
        @[@"Clean mapped", bytes(stats.externalBytes, @"None")],
        @[@"Compressed", bytes(stats.compressedBytes, @"None")],
        @[@"Comp. peak", bytes(stats.compressedPeakBytes, @"None")],
        @[@"Comp. lifetime", bytes(stats.compressedLifetimeBytes, @"None")],
        @[@"Reusable", bytes(stats.reusableBytes, @"None")],
        @[@"Purgeable", bytes(stats.purgeableVolatileBytes, @"None")],
        @[@"IOKit/GPU", bytes(stats.deviceMappedBytes, @"None")],
        @[@"Virtual", bytes(stats.virtualBytes, @"Unknown")],
        @[@"VM regions", count(stats.regionCount)],
        @[@"Page size", bytes(stats.pageSizeBytes, @"Unknown")],
        @[@"Available", bytes(stats.availableBytes, @"Unknown")],
        @[@"Limit ≈", bytes(stats.memoryLimitApproxBytes, @"Unknown")],
        @[@"Limit used", limitUsedText],
        @[@"Pressure", pressureText],
        @[@"Incr. limit", stats.hasIncreasedMemoryLimitEntitlement ? @"Yes" : @"No"],
        @[@"Ext. VA", stats.hasExtendedVirtualAddressingEntitlement ? @"Yes" : @"No"],
        @[@"Device RAM", bytes(MAX(0, stats.deviceTotalBytes), @"Unknown")],
        @[@"Free", bytes(stats.systemFreeBytes, @"Unknown")],
        @[@"Free level", freeLevelText],
        @[@"Active", bytes(stats.systemActiveBytes, @"Unknown")],
        @[@"Inactive", bytes(stats.systemInactiveBytes, @"Unknown")],
        @[@"Wired", bytes(stats.systemWiredBytes, @"Unknown")],
        @[@"Speculative", bytes(stats.systemSpeculativeBytes, @"None")],
        @[@"Sys purgeable", bytes(stats.systemPurgeableBytes, @"None")],
        @[@"Sys file-backed", bytes(stats.systemFileBackedBytes, @"None")],
        @[@"Sys anonymous", bytes(stats.systemAnonymousBytes, @"None")],
        @[@"Compressor", bytes(stats.systemCompressorBytes, @"None")],
        @[@"Comp. ratio", ratioText],
        @[@"Page-ins", count(stats.pageIns)],
        @[@"Page-outs", count(stats.pageOuts)],
        @[@"Faults", count(stats.faults)],
        @[@"COW faults", count(stats.cowFaults)],
        @[@"Zero-fills", count(stats.zeroFills)],
        @[@"Compressions", count(stats.compressions)],
        @[@"Decompress.", count(stats.decompressions)],
    ];

    NSMutableArray<ZSMemoryColumnRow *> *rows = [NSMutableArray arrayWithCapacity:pairs.count];
    for (NSArray<NSString *> *pair in pairs) {
        ZSMemoryColumnRow *row = [ZSMemoryColumnRow new];
        row.name = pair[0];
        row.value = pair[1];
        row.detail = @"";
        [rows addObject:row];
    }
    return rows;
}

static NSString *zs_memchart_display_value(ZSMemoryUsageGroup *group, ZSMemoryUsageCategory *category, int64_t grandTotal) {
    NSString *sizeText = [NSByteCountFormatter stringFromByteCount:(long long)category.totalBytes countStyle:NSByteCountFormatterCountStyleMemory];
    if (group.showsChart) {
        double fraction = grandTotal > 0 ? (double)category.totalBytes / (double)grandTotal : 0;
        return [NSString stringWithFormat:@"%.1f%% · %@", fraction * 100.0, sizeText];
    }
    if (category.totalBytes > 0) return sizeText;
    if (category.objectCount > 0) return [NSString stringWithFormat:@"%lu objects", (unsigned long)category.objectCount];
    return @"";
}

NSDictionary *zs_memchart_export_document(ZSMemorySystemStats stats,
                                                 NSArray<ZSMemoryColumnRow *> *systemRows,
                                                 NSArray<ZSMemoryUsageGroup *> *groups,
                                                 NSDate *date) {
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];

    NSMutableArray<NSDictionary *> *systemEntries = [NSMutableArray arrayWithCapacity:systemRows.count];
    for (ZSMemoryColumnRow *row in systemRows) {
        [systemEntries addObject:@{@"name": row.name ?: @"", @"value": row.value ?: @""}];
    }

    NSDictionary *systemRaw = @{
        @"footprintBytes": @(stats.residentBytes),
        @"peakResidentBytes": @(stats.peakResidentBytes),
        @"availableBytes": @(stats.availableBytes),
        @"approxMemoryLimitBytes": @(stats.memoryLimitApproxBytes),
        @"dirtyResidentBytes": @(stats.internalBytes),
        @"compressedBytes": @(stats.compressedBytes),
        @"cleanFileBackedBytes": @(stats.externalBytes),
        @"reusableBytes": @(stats.reusableBytes),
        @"residentBytes": @(stats.residentSizeBytes),
        @"peakFootprintBytes": @(stats.peakFootprintBytes),
        @"compressedPeakBytes": @(stats.compressedPeakBytes),
        @"compressedLifetimeBytes": @(stats.compressedLifetimeBytes),
        @"purgeableVolatileBytes": @(stats.purgeableVolatileBytes),
        @"deviceMappedBytes": @(stats.deviceMappedBytes),
        @"vmRegionCount": @(stats.regionCount),
        @"pageSizeBytes": @(stats.pageSizeBytes),
        @"systemInactiveBytes": @(stats.systemInactiveBytes),
        @"systemSpeculativeBytes": @(stats.systemSpeculativeBytes),
        @"systemPurgeableBytes": @(stats.systemPurgeableBytes),
        @"systemFileBackedBytes": @(stats.systemFileBackedBytes),
        @"systemAnonymousBytes": @(stats.systemAnonymousBytes),
        @"systemCompressorBytes": @(stats.systemCompressorBytes),
        @"compressionRatio": @(stats.compressionRatio),
        @"freeLevelPercent": @(stats.freeLevelPercent),
        @"pageIns": @(stats.pageIns),
        @"pageOuts": @(stats.pageOuts),
        @"faults": @(stats.faults),
        @"cowFaults": @(stats.cowFaults),
        @"zeroFills": @(stats.zeroFills),
        @"compressions": @(stats.compressions),
        @"decompressions": @(stats.decompressions),
        @"virtualAddressSpaceBytes": @(stats.virtualBytes),
        @"systemFreeBytes": @(stats.systemFreeBytes),
        @"systemActiveBytes": @(stats.systemActiveBytes),
        @"systemWiredBytes": @(stats.systemWiredBytes),
        @"deviceMemoryBytes": @(stats.deviceTotalBytes),
        @"memoryPressure": stats.pressureLabel ? [NSString stringWithUTF8String:stats.pressureLabel] : @"Unknown",
        @"increasedMemoryLimitEntitlement": @(stats.hasIncreasedMemoryLimitEntitlement),
        @"extendedVirtualAddressingEntitlement": @(stats.hasExtendedVirtualAddressingEntitlement),
    };

    NSMutableArray<NSDictionary *> *groupEntries = [NSMutableArray arrayWithCapacity:groups.count];
    for (ZSMemoryUsageGroup *group in groups) {
        if (group.categories.count == 0) continue;

        int64_t grandTotal = 0;
        for (ZSMemoryUsageCategory *category in group.categories) grandTotal += category.totalBytes;
        if (group.showsChart && grandTotal <= 0) continue;

        NSMutableArray<NSDictionary *> *categoryEntries = [NSMutableArray arrayWithCapacity:group.categories.count];
        for (ZSMemoryUsageCategory *category in group.categories) {
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"name"] = category.name ?: @"";
            entry[@"detail"] = category.detail ?: @"";
            entry[@"value"] = zs_memchart_display_value(group, category, grandTotal);
            entry[@"totalBytes"] = @(category.totalBytes);
            entry[@"objectCount"] = @(category.objectCount);
            if (group.showsChart) {
                entry[@"percent"] = @(round((double)category.totalBytes / (double)grandTotal * 1000.0) / 10.0);
            }
            [categoryEntries addObject:entry];
        }

        NSMutableDictionary *groupEntry = [NSMutableDictionary dictionary];
        groupEntry[@"title"] = group.title ?: @"";
        groupEntry[@"subtitle"] = group.subtitle ?: @"";
        groupEntry[@"categories"] = categoryEntries;

        if (group.pagingEnabled) {
            groupEntry[@"page"] = @(group.pageIndex + 1);
            groupEntry[@"pageCount"] = @(group.pageCount);
            groupEntry[@"hasNextPage"] = @(group.hasNextPage);
            groupEntry[@"kindFilter"] = group.activeKind.length > 0 ? group.activeKind : @"All Kinds";

            NSMutableArray<NSDictionary *> *kindEntries = [NSMutableArray arrayWithCapacity:group.kindOptions.count];
            for (ZSMemoryUsageCategory *option in group.kindOptions) {
                [kindEntries addObject:@{@"name": option.name ?: @"",
                                         @"totalBytes": @(option.totalBytes),
                                         @"objectCount": @(option.objectCount)}];
            }
            groupEntry[@"kindOptions"] = kindEntries;
        }
        [groupEntries addObject:groupEntry];
    }

    return @{
        @"generatedAt": [isoFormatter stringFromDate:date],
        @"refreshIntervalSeconds": @(ZS_MEMORY_SCAN_CYCLE_SECONDS),
        @"system": systemEntries,
        @"systemRaw": systemRaw,
        @"groups": groupEntries,
    };
}

UIVisualEffectView *zs_wrap_field_in_native_glass(UITextField *field, CGFloat cornerRadius) {
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

static NSString *zs_codec_descriptor_label_for_format(NSString *format) {
    if ([format isEqualToString:@"ASTC_RGBA_4x4"]) return @"ASTC_4x4";
    if ([format isEqualToString:@"ASTC_RGBA_6x6"]) return @"ASTC_6x6";
    if ([format isEqualToString:@"ASTC_RGBA_8x8"]) return @"ASTC_8x8";
    if ([format isEqualToString:@"RGBA32"]) return @"RGBA32";
    if ([format isEqualToString:@"ETC2"]) return @"ETC2";
    return format ?: @"RGBA32";
}

UIImage *zs_make_dropdown_chevron_image(void) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
    UIImage *chevronImage = [UIImage systemImageNamed:@"chevron.up.chevron.down" withConfiguration:symbolConfig];
    chevronImage = [chevronImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.55]
                                       renderingMode:UIImageRenderingModeAlwaysOriginal];
    return chevronImage;
}

UIImage *zs_make_release_history_arrow_image(BOOL pointingLeft) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    UIImage *arrowImage = [UIImage systemImageNamed:pointingLeft ? @"chevron.left" : @"chevron.right" withConfiguration:symbolConfig];
    arrowImage = [arrowImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.55]
                                   renderingMode:UIImageRenderingModeAlwaysOriginal];
    return arrowImage;
}

static ZSRow *zs_make_full_width_glass_button_row(NSString *buttonTitle, UIColor *buttonTint) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *button = zs_make_grouped_action_button(buttonTitle, buttonTint);
    [row addSubview:button];
    objc_setAssociatedObject(row, "zs_button", button, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.topAnchor constraintEqualToAnchor:row.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [row.heightAnchor constraintEqualToConstant:34],
    ]];

    return row;
}

ZSRow *zs_make_full_width_glass_field_row(UITextField *field) {
    ZSRow *row = [[ZSRow alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIVisualEffectView *fieldGlass = zs_wrap_field_in_native_glass(field, 6);
    UIView *fieldContainer = fieldGlass ?: field;
    fieldContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:fieldContainer];

    [NSLayoutConstraint activateConstraints:@[
        [fieldContainer.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [fieldContainer.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [fieldContainer.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [fieldContainer.heightAnchor constraintEqualToConstant:28],
        [row.heightAnchor constraintEqualToConstant:34],
    ]];

    return row;
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

UIView *zs_make_blacklist_entry_row(NSString *term, id target, SEL removeAction) {
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

NSString * const kZSStoredBundlesFolderName = @"Stored Bundles";
NSString * const kZSStoredBundlesFolderSubtext = @"Your stored bundles are here, you can restore them any time.";

BOOL zs_mods_folder_is_or_within_stored_bundles(NSString *folderName) {
    if (folderName.length == 0) return NO;
    if ([folderName isEqualToString:kZSStoredBundlesFolderName]) return YES;
    NSString *prefix = [kZSStoredBundlesFolderName stringByAppendingString:@"/"];
    return [folderName hasPrefix:prefix];
}

static const CGFloat kZSModsFolderRowIndentWidth = 16;

UIView *zs_make_mods_folder_row(NSString *folderName, NSString *displayName, NSString *remark, BOOL expanded, id target, SEL tapAction, SEL optionsAction, NSInteger indentLevel) {
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
        zs_style_options_button_as_original_native_glass(optionsButton, dotsImage, [UIColor colorWithWhite:1 alpha:0.6]);
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

static BOOL zs_mods_entry_is_re_placeable(ModAssetLibraryEntry *entry) {
    if (!entry.isAssetBundle) return YES;
    return entry.doctorStatus == ModAssetLibraryDoctorStatusInstalled;
}

NSArray<NSDictionary<NSString *, id> *> *zs_mods_file_options(ModAssetLibraryEntry *entry) {
    NSMutableArray<NSDictionary<NSString *, id> *> *options = [NSMutableArray array];
    [options addObject:@{@"title": @"Cache bundle", @"symbol": @"archivebox", @"destructive": @NO}];
    [options addObject:@{@"title": @"Add remark", @"symbol": @"quote.bubble", @"destructive": @NO}];
    if ([ZSModsPaths fontKindForFileName:entry.fileName] == ZSFontKindUnknown) {
        [options addObject:@{@"title": @"Re-place", @"symbol": @"arrow.triangle.2.circlepath", @"destructive": @NO, @"disabled": @(!zs_mods_entry_is_re_placeable(entry))}];
    }
    [options addObject:@{@"title": @"Delete", @"symbol": @"trash", @"destructive": @YES}];
    return options;
}

NSArray<NSDictionary<NSString *, id> *> *zs_mods_stored_bundle_file_options(void) {
    return @[
        @{@"title": @"Restore",    @"symbol": @"arrow.uturn.backward", @"destructive": @NO},
        @{@"title": @"Add remark", @"symbol": @"quote.bubble",         @"destructive": @NO},
        @{@"title": @"Delete",     @"symbol": @"trash",                @"destructive": @YES},
    ];
}

UIButton *zs_make_mods_options_row_button(NSDictionary<NSString *, id> *option, NSInteger tag, id target, SEL action) {
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

    NSString *symbolName = option[@"symbol"];
    if (symbolName.length == 0) return row;

    UIImageSymbolConfiguration *symConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
    UIImage *symbolImage = [UIImage systemImageNamed:symbolName withConfiguration:symConfig];
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

NSArray<NSDictionary<NSString *, id> *> *zs_mods_options_for_folder(NSString *folderName) {
    BOOL isCachedFolder = zs_mods_folder_is_or_within_stored_bundles(folderName)
        && ![folderName isEqualToString:kZSStoredBundlesFolderName];
    return isCachedFolder ? zs_mods_cached_folder_options() : zs_mods_folder_options();
}

UIView *zs_make_mods_entry_row(ModAssetLibraryEntry *entry, id target, SEL tapAction,
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
        zs_style_options_button_as_original_native_glass(optionsButton, dotsImage, [UIColor colorWithWhite:1 alpha:0.6]);
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

NSString *zs_doctor_status_text_for_entry(ModAssetLibraryEntry *entry, BOOL downloadInFlight, BOOL isStoredBundlesFolder) {    if (isStoredBundlesFolder) return @"Stored";
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

UIView *zs_make_mods_entry_info_panel(ModAssetLibraryEntry *entry, BOOL downloadInFlight, BOOL isStoredBundlesFolder) {
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

UILabel *zs_make_section_header(NSString *text) {
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

static UIFont *zs_title_font(CGFloat size, UIFontWeight weight) {
    UIFont *logoFont = zs_logo_selected_font(size);
    return logoFont ?: zs_excelsior_sans_font(size, weight);
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

void zs_apply_update_label_style(UILabel *label, NSString *text, BOOL interactable) {
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

UIImageView *zs_make_signature_overlay(void) {
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

static BOOL zs_custom_logo_active(void) {
    return zs_logo_selected_font(12) != nil;
}

NSAttributedString *zs_make_title_string(CGFloat restSize, CGFloat emphasizedSize) {
    NSString *fullTitle = @"ZSingularity";
    NSUInteger emphasizedLength = 2;
    ZSLogoFontStyle *style = zs_custom_logo_active() ? zs_logo_selected_style().font : nil;

    CGFloat restPoints = restSize;
    CGFloat emphasizedPoints = emphasizedSize;
    UIColor *color = zs_accent_green_color();

    if (style) {
        restPoints = restSize * style.sizeScale;
        emphasizedPoints = style.emphasisScale > 0 ? restPoints * style.emphasisScale : emphasizedSize * style.sizeScale;
        color = style.color;
        if (style.textCase == ZSLogoTextCaseUpper) fullTitle = fullTitle.uppercaseString;
        if (style.textCase == ZSLogoTextCaseLower) fullTitle = fullTitle.lowercaseString;
    }

    NSDictionary *(^attributesForSize)(CGFloat) = ^NSDictionary *(CGFloat points) {
        NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
        attributes[NSFontAttributeName] = zs_title_font(points, UIFontWeightBold);
        attributes[NSForegroundColorAttributeName] = color;
        if (!style) return attributes;

        if (style.spacing != 0) attributes[NSKernAttributeName] = @(style.spacing);
        if (style.baselineOffset != 0) attributes[NSBaselineOffsetAttributeName] = @(style.baselineOffset);
        if (style.shadowBlur > 0) {
            CGFloat alpha = CGColorGetAlpha(style.shadowColor.CGColor) * style.shadowOpacity;
            NSShadow *shadow = [[NSShadow alloc] init];
            shadow.shadowBlurRadius = style.shadowBlur;
            shadow.shadowOffset = style.shadowOffset;
            shadow.shadowColor = [style.shadowColor colorWithAlphaComponent:alpha];
            attributes[NSShadowAttributeName] = shadow;
        }
        if (style.strokeWidth > 0) {
            attributes[NSStrokeWidthAttributeName] = @(-style.strokeWidth / points * 100.0);
            attributes[NSStrokeColorAttributeName] = style.strokeColor;
        }
        return attributes;
    };

    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:fullTitle
                                                                              attributes:attributesForSize(restPoints)];
    [title setAttributes:attributesForSize(emphasizedPoints) range:NSMakeRange(0, emphasizedLength)];
    return title;
}

static void zs_style_title_header_label(UILabel *label) {
    label.attributedText = zs_make_title_string(33.75, 45);

    if (zs_custom_logo_active()) {
        zs_remove_gif_text_tint(label);
        zs_logo_effects_attach(label);
    } else {
        zs_logo_effects_detach(label);
        zs_apply_gif_text_tint(label);
    }
}

static UIImage *zs_make_logo_chevron_image(void) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
    UIImage *chevronImage = [UIImage systemImageNamed:@"chevron.down" withConfiguration:symbolConfig];
    return [chevronImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.55]
                               renderingMode:UIImageRenderingModeAlwaysOriginal];
}

@interface ZSLogoObserverToken : NSObject
@property (nonatomic, strong) id observer;
@end

@implementation ZSLogoObserverToken
- (void)dealloc {
    if (_observer) [[NSNotificationCenter defaultCenter] removeObserver:_observer];
}
@end

static const void *kZSLogoInstallOverlayKey = &kZSLogoInstallOverlayKey;
static const void *kZSLogoInstallObserverKey = &kZSLogoInstallObserverKey;

static UIView *zs_make_logo_install_overlay(UIView *container, UILabel *headerLabel) {
    UIView *overlay = [[UIView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    overlay.layer.cornerRadius = 10;
    overlay.layer.cornerCurve = kCACornerCurveContinuous;
    overlay.userInteractionEnabled = NO;
    overlay.alpha = 0;
    overlay.hidden = YES;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = zs_accent_green_color();
    spinner.hidesWhenStopped = NO;

    UILabel *label = [[UILabel alloc] init];
    label.text = @"Installing\u2026";
    label.textColor = zs_accent_green_color();
    label.font = zs_mono_font(13, UIFontWeightSemibold);

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[spinner, label]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    [overlay addSubview:stack];

    [container addSubview:overlay];
    objc_setAssociatedObject(overlay, @"zs_install_spinner", spinner, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:headerLabel.leadingAnchor constant:-10],
        [overlay.trailingAnchor constraintEqualToAnchor:headerLabel.trailingAnchor constant:10],
        [overlay.topAnchor constraintEqualToAnchor:headerLabel.topAnchor constant:-4],
        [overlay.bottomAnchor constraintEqualToAnchor:headerLabel.bottomAnchor constant:4],
        [stack.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
    ]];
    return overlay;
}

static void zs_apply_logo_install_state(UIView *container, BOOL animated) {
    UIView *overlay = objc_getAssociatedObject(container, kZSLogoInstallOverlayKey);
    if (!overlay) return;
    UIActivityIndicatorView *spinner = objc_getAssociatedObject(overlay, @"zs_install_spinner");
    BOOL installing = zs_logo_is_installing();

    if (installing) {
        [container bringSubviewToFront:overlay];
        overlay.hidden = NO;
        [spinner startAnimating];
        [UIView animateWithDuration:animated ? 0.22 : 0 animations:^{
            overlay.alpha = 1;
        }];
        return;
    }

    [UIView animateWithDuration:animated ? 0.22 : 0 animations:^{
        overlay.alpha = 0;
    } completion:^(BOOL finished) {
        if (zs_logo_is_installing()) return;
        overlay.hidden = YES;
        [spinner stopAnimating];
    }];
}

UIView *zs_make_title_block(void) {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    headerLabel.textAlignment = NSTextAlignmentNatural;

    [container addSubview:headerLabel];
    zs_style_title_header_label(headerLabel);

    UIButton *logoChevron = [UIButton buttonWithType:UIButtonTypeSystem];
    logoChevron.translatesAutoresizingMaskIntoConstraints = NO;
    [logoChevron setImage:zs_make_logo_chevron_image() forState:UIControlStateNormal];
    logoChevron.accessibilityLabel = @"Change logo";
    [container addSubview:logoChevron];

    ZSLogoObserverToken *observerToken = [[ZSLogoObserverToken alloc] init];
    __weak UILabel *weakHeaderLabel = headerLabel;
    observerToken.observer = [[NSNotificationCenter defaultCenter] addObserverForName:ZSLogoDidChangeNotification
                                                                                object:nil
                                                                                 queue:[NSOperationQueue mainQueue]
                                                                            usingBlock:^(NSNotification *note) {
        UILabel *label = weakHeaderLabel;
        if (label) zs_style_title_header_label(label);
    }];
    objc_setAssociatedObject(container, @"zs_logo_observer", observerToken, OBJC_ASSOCIATION_RETAIN);

    UIView *installOverlay = zs_make_logo_install_overlay(container, headerLabel);
    objc_setAssociatedObject(container, kZSLogoInstallOverlayKey, installOverlay, OBJC_ASSOCIATION_RETAIN);
    ZSLogoObserverToken *installToken = [[ZSLogoObserverToken alloc] init];
    __weak UIView *weakContainer = container;
    installToken.observer = [[NSNotificationCenter defaultCenter] addObserverForName:ZSLogoInstallStateDidChangeNotification
                                                                               object:nil
                                                                                queue:[NSOperationQueue mainQueue]
                                                                           usingBlock:^(NSNotification *note) {
        UIView *strongContainer = weakContainer;
        if (strongContainer) zs_apply_logo_install_state(strongContainer, YES);
    }];
    objc_setAssociatedObject(container, kZSLogoInstallObserverKey, installToken, OBJC_ASSOCIATION_RETAIN);

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
    objc_setAssociatedObject(container, @"zs_logo_chevron", logoChevron, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(container, @"zs_update_dot", updateDot, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(container, @"zs_update_label", updateLabel, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [headerLabel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [headerLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [headerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:logoChevron.leadingAnchor constant:-2],

        [logoChevron.widthAnchor constraintEqualToConstant:28],
        [logoChevron.heightAnchor constraintEqualToConstant:28],
        [logoChevron.centerYAnchor constraintEqualToAnchor:headerLabel.centerYAnchor],
        [logoChevron.leadingAnchor constraintEqualToAnchor:headerLabel.trailingAnchor constant:2],
        [logoChevron.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor],

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

    zs_apply_logo_install_state(container, NO);
    return container;
}

#pragma mark - Field browser picker (EXPERIMENTAL / Browse All Settings)

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

@interface NSObject (ZSSyslogLongPress)
- (void)handleSyslogFullScreenRowLongPress:(UILongPressGestureRecognizer *)gesture;
@end

static const CGFloat kZSSyslogIndexColumnWidth = 22;

@implementation ZSAssetPreviewClipView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.contentView.hidden) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit) return hit;
    UIView *content = self.contentView;
    if (!content || content.superview != self) return nil;
    CGPoint inContent = [content convertPoint:point fromView:self];
    return [content pointInside:inContent withEvent:event] ? content : nil;
}
@end

static UIImage *zs_asset_checkerboard_tile(void) {
    CGFloat square = 12;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(square * 2, square * 2)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithWhite:0.34 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 0, square * 2, square * 2));
        [[UIColor colorWithWhite:0.22 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 0, square, square));
        UIRectFill(CGRectMake(square, square, square, square));
    }];
}

@implementation ZSAssetCheckerboardView {
    CAGradientLayer *_fadeMask;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.backgroundColor = [UIColor colorWithPatternImage:zs_asset_checkerboard_tile()];
        _fadeMask = [CAGradientLayer layer];
        _fadeMask.type = kCAGradientLayerRadial;
        _fadeMask.startPoint = CGPointMake(0.5, 0.5);
        _fadeMask.endPoint = CGPointMake(1.0, 1.0);
        _fadeMask.colors = @[
            (id)[UIColor colorWithWhite:0 alpha:1].CGColor,
            (id)[UIColor colorWithWhite:0 alpha:0.85].CGColor,
            (id)[UIColor colorWithWhite:0 alpha:0.35].CGColor,
            (id)[UIColor colorWithWhite:0 alpha:0].CGColor,
        ];
        _fadeMask.locations = @[@0.0, @0.35, @0.7, @1.0];
        self.layer.mask = _fadeMask;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fadeMask.frame = self.bounds;
    [CATransaction commit];
}

@end

@implementation ZSLocJSONNode
- (BOOL)isContainer {
    return self.kind == ZSLocJSONKindObject || self.kind == ZSLocJSONKindArray;
}
@end

typedef struct {
    const uint8_t *p;
    const uint8_t *end;
    BOOL failed;
} ZSLocJSONCursor;

static void zs_loc_json_skip(ZSLocJSONCursor *c) {
    while (c->p < c->end && (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r')) c->p++;
}

static int zs_loc_json_hex(unichar ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

static NSString *zs_loc_json_unescape(NSString *raw) {
    NSUInteger length = raw.length;
    unichar *chars = malloc(length * sizeof(unichar));
    unichar *result = malloc(length * sizeof(unichar));
    if (!chars || !result) {
        free(chars);
        free(result);
        return raw;
    }
    [raw getCharacters:chars range:NSMakeRange(0, length)];
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < length; i++) {
        unichar ch = chars[i];
        if (ch != '\\' || i + 1 >= length) {
            result[count++] = ch;
            continue;
        }
        unichar next = chars[++i];
        switch (next) {
            case 'n': result[count++] = '\n'; break;
            case 't': result[count++] = '\t'; break;
            case 'r': result[count++] = '\r'; break;
            case 'b': result[count++] = '\b'; break;
            case 'f': result[count++] = '\f'; break;
            case 'u': {
                BOOL ok = i + 4 < length;
                unsigned int value = 0;
                for (NSUInteger k = 1; ok && k <= 4; k++) {
                    int digit = zs_loc_json_hex(chars[i + k]);
                    if (digit < 0) ok = NO;
                    else value = value * 16 + (unsigned int)digit;
                }
                if (ok) {
                    result[count++] = (unichar)value;
                    i += 4;
                } else {
                    result[count++] = 'u';
                }
                break;
            }
            default: result[count++] = next; break;
        }
    }
    NSString *string = [NSString stringWithCharacters:result length:count];
    free(chars);
    free(result);
    return string;
}

static NSString *zs_loc_json_string(ZSLocJSONCursor *c) {
    c->p++;
    const uint8_t *start = c->p;
    BOOL escaped = NO;
    while (c->p < c->end) {
        uint8_t ch = *c->p;
        if (ch == '\\') {
            escaped = YES;
            c->p += 2;
            continue;
        }
        if (ch == '"') break;
        c->p++;
    }
    if (c->p >= c->end) {
        c->failed = YES;
        return nil;
    }
    const uint8_t *stop = c->p;
    c->p++;
    NSString *raw = [[NSString alloc] initWithBytes:start length:(NSUInteger)(stop - start) encoding:NSUTF8StringEncoding];
    if (!raw) {
        c->failed = YES;
        return nil;
    }
    return escaped ? zs_loc_json_unescape(raw) : raw;
}

static BOOL zs_loc_json_literal(ZSLocJSONCursor *c, const char *word) {
    size_t length = strlen(word);
    if ((size_t)(c->end - c->p) < length || memcmp(c->p, word, length) != 0) return NO;
    c->p += length;
    return YES;
}

static ZSLocJSONNode *zs_loc_json_value(ZSLocJSONCursor *c, NSString *key, NSInteger depth) {
    if (depth > 256) {
        c->failed = YES;
        return nil;
    }
    zs_loc_json_skip(c);
    if (c->p >= c->end) {
        c->failed = YES;
        return nil;
    }
    ZSLocJSONNode *node = [[ZSLocJSONNode alloc] init];
    node.key = key;
    node.depth = depth;
    uint8_t ch = *c->p;
    if (ch == '{') {
        node.kind = ZSLocJSONKindObject;
        node.children = [NSMutableArray array];
        c->p++;
        zs_loc_json_skip(c);
        if (c->p < c->end && *c->p == '}') {
            c->p++;
            return node;
        }
        while (!c->failed) {
            zs_loc_json_skip(c);
            if (c->p >= c->end || *c->p != '"') break;
            NSString *childKey = zs_loc_json_string(c);
            if (c->failed) return nil;
            zs_loc_json_skip(c);
            if (c->p >= c->end || *c->p != ':') break;
            c->p++;
            ZSLocJSONNode *child = zs_loc_json_value(c, childKey, depth + 1);
            if (!child) return nil;
            [node.children addObject:child];
            zs_loc_json_skip(c);
            if (c->p >= c->end) break;
            if (*c->p == ',') {
                c->p++;
                continue;
            }
            if (*c->p == '}') {
                c->p++;
                return node;
            }
            break;
        }
        c->failed = YES;
        return nil;
    }
    if (ch == '[') {
        node.kind = ZSLocJSONKindArray;
        node.children = [NSMutableArray array];
        c->p++;
        zs_loc_json_skip(c);
        if (c->p < c->end && *c->p == ']') {
            c->p++;
            return node;
        }
        while (!c->failed) {
            NSString *childKey = [NSString stringWithFormat:@"[%lu]", (unsigned long)node.children.count];
            ZSLocJSONNode *child = zs_loc_json_value(c, childKey, depth + 1);
            if (!child) return nil;
            [node.children addObject:child];
            zs_loc_json_skip(c);
            if (c->p >= c->end) break;
            if (*c->p == ',') {
                c->p++;
                continue;
            }
            if (*c->p == ']') {
                c->p++;
                return node;
            }
            break;
        }
        c->failed = YES;
        return nil;
    }
    if (ch == '"') {
        node.kind = ZSLocJSONKindString;
        node.text = zs_loc_json_string(c);
        if (c->failed) return nil;
        return node;
    }
    if (zs_loc_json_literal(c, "true")) {
        node.kind = ZSLocJSONKindBool;
        node.text = @"true";
        return node;
    }
    if (zs_loc_json_literal(c, "false")) {
        node.kind = ZSLocJSONKindBool;
        node.text = @"false";
        return node;
    }
    if (zs_loc_json_literal(c, "null")) {
        node.kind = ZSLocJSONKindNull;
        node.text = @"null";
        return node;
    }
    const uint8_t *start = c->p;
    while (c->p < c->end) {
        uint8_t d = *c->p;
        if ((d >= '0' && d <= '9') || d == '-' || d == '+' || d == '.' || d == 'e' || d == 'E') c->p++;
        else break;
    }
    if (c->p == start) {
        c->failed = YES;
        return nil;
    }
    node.kind = ZSLocJSONKindNumber;
    node.text = [[NSString alloc] initWithBytes:start length:(NSUInteger)(c->p - start) encoding:NSASCIIStringEncoding];
    return node;
}

NSData *zs_loc_json_strip_bom(NSData *data) {
    const uint8_t *bytes = data.bytes;
    if (data.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        return [data subdataWithRange:NSMakeRange(3, data.length - 3)];
    }
    return data;
}

ZSLocJSONNode *zs_loc_json_parse(NSData *data) {
    if (data.length == 0) return nil;
    ZSLocJSONCursor cursor = { data.bytes, (const uint8_t *)data.bytes + data.length, NO };
    ZSLocJSONNode *root = zs_loc_json_value(&cursor, @"", -1);
    if (!root || cursor.failed) return nil;
    zs_loc_json_skip(&cursor);
    if (cursor.p != cursor.end) return nil;
    return root;
}

void zs_loc_json_flatten(NSArray<ZSLocJSONNode *> *nodes, NSMutableArray<ZSLocJSONNode *> *out) {
    for (ZSLocJSONNode *node in nodes) {
        [out addObject:node];
        if (node.expanded && node.isContainer) zs_loc_json_flatten(node.children, out);
    }
}

static NSString *zs_loc_json_clip(NSString *text, NSUInteger limit) {
    if (text.length <= limit) return text;
    return [[text substringToIndex:limit] stringByAppendingString:@"…"];
}

static NSString *zs_loc_json_display_escape(NSString *text) {
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    return [text stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"];
}

static NSString *zs_loc_json_scalar_text(ZSLocJSONNode *node, NSUInteger limit) {
    if (node.kind == ZSLocJSONKindString) {
        return [NSString stringWithFormat:@"\"%@\"", zs_loc_json_clip(zs_loc_json_display_escape(node.text ?: @""), limit)];
    }
    return node.text ?: @"";
}

static NSString *zs_loc_json_preview(ZSLocJSONNode *node) {
    if (node.kind != ZSLocJSONKindObject) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (ZSLocJSONNode *child in node.children) {
        if (child.isContainer) continue;
        [parts addObject:[NSString stringWithFormat:@"%@: %@", child.key, zs_loc_json_scalar_text(child, 36)]];
        if (parts.count == 2) break;
    }
    return [parts componentsJoinedByString:@"  "];
}

NSAttributedString *zs_loc_json_attributed(ZSLocJSONNode *node) {
    UIFont *font = zs_mono_font(10, UIFontWeightRegular);
    UIColor *keyColor = [UIColor colorWithWhite:1 alpha:0.6];
    UIColor *dimColor = [UIColor colorWithWhite:1 alpha:0.38];
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    void (^append)(NSString *, UIColor *) = ^(NSString *string, UIColor *color) {
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:string attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}]];
    };
    append(node.isContainer ? (node.expanded ? @"▾ " : @"▸ ") : @"  ", dimColor);
    if (node.depth >= 0) append([NSString stringWithFormat:@"%@: ", node.key ?: @""], keyColor);
    switch (node.kind) {
        case ZSLocJSONKindObject:
        case ZSLocJSONKindArray: {
            NSString *count = [NSString stringWithFormat:@"%lu", (unsigned long)node.children.count];
            append(node.kind == ZSLocJSONKindObject ? [NSString stringWithFormat:@"{%@}", count] : [NSString stringWithFormat:@"[%@]", count], dimColor);
            if (!node.expanded) {
                NSString *preview = zs_loc_json_preview(node);
                if (preview.length > 0) append([@"  " stringByAppendingString:preview], dimColor);
            }
            break;
        }
        case ZSLocJSONKindString:
            append(zs_loc_json_scalar_text(node, 3000), zs_accent_green_color());
            break;
        case ZSLocJSONKindNumber:
            append(node.text ?: @"", [UIColor colorWithRed:0.45 green:0.72 blue:1 alpha:1]);
            break;
        default:
            append(node.text ?: @"", [UIColor colorWithRed:1 green:0.62 blue:0.35 alpha:1]);
            break;
    }
    return out;
}

static NSString *zs_loc_json_quote(NSString *text) {
    NSMutableString *out = [NSMutableString stringWithCapacity:text.length + 2];
    [out appendString:@"\""];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        switch (ch) {
            case '"': [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\n': [out appendString:@"\\n"]; break;
            case '\r': [out appendString:@"\\r"]; break;
            case '\t': [out appendString:@"\\t"]; break;
            default:
                if (ch < 0x20) [out appendFormat:@"\\u%04x", ch];
                else [out appendFormat:@"%C", ch];
                break;
        }
    }
    [out appendString:@"\""];
    return out;
}

void zs_loc_json_write(ZSLocJSONNode *node, NSInteger indent, NSMutableString *out) {
    if (node.kind == ZSLocJSONKindString) {
        [out appendString:zs_loc_json_quote(node.text ?: @"")];
        return;
    }
    if (!node.isContainer) {
        [out appendString:node.text ?: @"null"];
        return;
    }
    BOOL object = node.kind == ZSLocJSONKindObject;
    if (node.children.count == 0) {
        [out appendString:object ? @"{}" : @"[]"];
        return;
    }
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)((indent + 1) * 2) withString:@" " startingAtIndex:0];
    NSString *closePad = [@"" stringByPaddingToLength:(NSUInteger)(indent * 2) withString:@" " startingAtIndex:0];
    [out appendString:object ? @"{\n" : @"[\n"];
    for (NSUInteger i = 0; i < node.children.count; i++) {
        ZSLocJSONNode *child = node.children[i];
        [out appendString:pad];
        if (object) [out appendFormat:@"%@: ", zs_loc_json_quote(child.key ?: @"")];
        zs_loc_json_write(child, indent + 1, out);
        [out appendString:i + 1 < node.children.count ? @",\n" : @"\n"];
    }
    [out appendString:closePad];
    [out appendString:object ? @"}" : @"]"];
}

@implementation ZSLocJSONCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        UIView *selected = [[UIView alloc] init];
        selected.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
        self.selectedBackgroundView = selected;

        _line = [[UILabel alloc] init];
        _line.translatesAutoresizingMaskIntoConstraints = NO;
        _line.numberOfLines = 0;
        _line.lineBreakMode = NSLineBreakByWordWrapping;
        [self.contentView addSubview:_line];
        _leadingConstraint = [_line.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16];
        [NSLayoutConstraint activateConstraints:@[
            _leadingConstraint,
            [_line.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_line.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [_line.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        ]];
    }
    return self;
}

@end

NSString *zs_asset_explorer_bundle_key(ZSAssetExplorerBundle *bundle) {
    if (bundle.cabIdentifier.length > 0) return bundle.cabIdentifier;
    return bundle.filePath.lastPathComponent ?: @"";
}

NSMutableOrderedSet<NSString *> *zs_ae_string_set(id stored) {
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    if (![stored isKindOfClass:[NSArray class]]) return set;
    for (id value in (NSArray *)stored) {
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) [set addObject:value];
    }
    return set;
}

void zs_ae_set_detail(UILabel *label, NSString *detail, BOOL recent) {
    if (!recent) {
        label.attributedText = nil;
        label.text = detail;
        return;
    }
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:[detail stringByAppendingString:@"  •  "]
                                                                                   attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.38], NSFontAttributeName: zs_mono_font(9, UIFontWeightRegular)}];
    [attributed appendAttributedString:[[NSAttributedString alloc] initWithString:@"RECENTLY INSPECTED"
                                                                       attributes:@{NSForegroundColorAttributeName: zs_accent_green_color(), NSFontAttributeName: zs_mono_font(9, UIFontWeightSemibold)}]];
    label.attributedText = attributed;
}

NSArray<NSNumber *> *zs_ae_section_kinds(NSUInteger bookmarked, NSUInteger modded, NSUInteger total) {
    NSMutableArray<NSNumber *> *kinds = [NSMutableArray arrayWithCapacity:3];
    if (bookmarked > 0) [kinds addObject:@0];
    if (modded > 0) [kinds addObject:@1];
    if (total > bookmarked + modded) [kinds addObject:@2];
    return kinds;
}

NSUInteger zs_ae_section_count(NSInteger kind, NSUInteger bookmarked, NSUInteger modded, NSUInteger total) {
    if (kind == 0) return bookmarked;
    if (kind == 1) return modded;
    return total - bookmarked - modded;
}

NSInteger zs_ae_flat_index(NSIndexPath *indexPath, NSUInteger bookmarked, NSUInteger modded, NSUInteger total) {
    NSArray<NSNumber *> *kinds = zs_ae_section_kinds(bookmarked, modded, total);
    if (indexPath.section < 0 || indexPath.section >= (NSInteger)kinds.count) return -1;
    NSInteger kind = kinds[(NSUInteger)indexPath.section].integerValue;
    NSUInteger start = 0;
    for (NSInteger earlier = 0; earlier < kind; earlier++) start += zs_ae_section_count(earlier, bookmarked, modded, total);
    return (NSInteger)start + indexPath.row;
}

NSString *zs_ae_section_title(NSInteger kind) {
    return kind == 0 ? @"BOOKMARKED" : (kind == 1 ? @"MODDED" : @"STOCK");
}

@implementation ZSAssetThumbCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.backgroundColor = [[UIColor colorWithPatternImage:zs_asset_checkerboard_tile()] colorWithAlphaComponent:0.5];
        self.contentView.clipsToBounds = YES;
        self.contentView.layer.borderWidth = 1.0 / MAX(UIScreen.mainScreen.scale, 1);
        self.contentView.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.3].CGColor;

        _imageView = [[UIImageView alloc] init];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        _imageView.tintColor = [UIColor colorWithWhite:1 alpha:0.35];
        [self.contentView addSubview:_imageView];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.color = [UIColor colorWithWhite:1 alpha:0.7];
        _spinner.hidesWhenStopped = YES;
        [self.contentView addSubview:_spinner];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    self.imageView.frame = bounds;
    self.spinner.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.representedKey = nil;
    self.imageView.image = nil;
    self.imageView.contentMode = UIViewContentModeScaleAspectFill;
    [self.spinner stopAnimating];
}

@end

@implementation ZSAssetThumbGridSource {
    NSCache<NSString *, id> *_cache;
    NSOperationQueue *_queue;
    NSMutableSet<NSString *> *_pending;
    NSMutableSet<NSString *> *_wanted;
    NSLock *_wantedLock;
    NSUInteger _generation;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 600;
        _queue = [[NSOperationQueue alloc] init];
        _queue.maxConcurrentOperationCount = 3;
        _queue.qualityOfService = NSQualityOfServiceUserInitiated;
        _pending = [NSMutableSet set];
        _wanted = [NSMutableSet set];
        _wantedLock = [[NSLock alloc] init];
        _assets = @[];
    }
    return self;
}

- (void)reset {
    _generation += 1;
    [_queue cancelAllOperations];
    [_pending removeAllObjects];
    [_wantedLock lock];
    [_wanted removeAllObjects];
    [_wantedLock unlock];
    [_cache removeAllObjects];
    _assets = @[];
    _bundlePath = nil;
}

- (NSString *)keyForAsset:(ZSAssetExplorerAsset *)asset {
    return [NSString stringWithFormat:@"%@|%lld", self.bundlePath ?: @"", (long long)asset.pathID];
}

- (void)applyThumbnail:(id)thumbnail toCell:(ZSAssetThumbCell *)cell {
    [cell.spinner stopAnimating];
    if ([thumbnail isKindOfClass:[UIImage class]]) {
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.image = thumbnail;
    } else {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
        cell.imageView.contentMode = UIViewContentModeCenter;
        cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle" withConfiguration:config];
    }
}

- (void)loadThumbnailForAsset:(ZSAssetExplorerAsset *)asset key:(NSString *)key {
    if ([_pending containsObject:key]) return;
    [_pending addObject:key];
    NSUInteger generation = _generation;
    NSString *path = [self.bundlePath copy];
    int64_t pathID = asset.pathID;
    int32_t classID = asset.classID;
    __weak typeof(self) weakSelf = self;
    [_queue addOperationWithBlock:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_generation != generation) return;
        [strongSelf->_wantedLock lock];
        BOOL stillWanted = [strongSelf->_wanted containsObject:key];
        [strongSelf->_wantedLock unlock];
        if (!stillWanted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) innerSelf = weakSelf;
                if (!innerSelf || innerSelf->_generation != generation) return;
                [innerSelf->_pending removeObject:key];
            });
            return;
        }
        UIImage *image = [ZSAssetExplorer thumbnailForPathID:pathID classID:classID inBundleAtPath:path maxDimension:128 error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) innerSelf = weakSelf;
            if (!innerSelf || innerSelf->_generation != generation) return;
            [innerSelf->_pending removeObject:key];
            id stored = image ?: (id)[NSNull null];
            [innerSelf->_cache setObject:stored forKey:key];
            for (ZSAssetThumbCell *cell in innerSelf.collectionView.visibleCells) {
                if ([cell isKindOfClass:[ZSAssetThumbCell class]] && [cell.representedKey isEqualToString:key]) [innerSelf applyThumbnail:stored toCell:cell];
            }
        });
    }];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.assets.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    self.collectionView = collectionView;
    ZSAssetThumbCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"ZSAssetThumbCell" forIndexPath:indexPath];
    ZSAssetExplorerAsset *asset = indexPath.item < (NSInteger)self.assets.count ? self.assets[(NSUInteger)indexPath.item] : nil;
    if (!asset) return cell;
    NSString *key = [self keyForAsset:asset];
    cell.representedKey = key;
    [_wantedLock lock];
    [_wanted addObject:key];
    [_wantedLock unlock];
    id cached = [_cache objectForKey:key];
    if (cached) {
        [self applyThumbnail:cached toCell:cell];
    } else {
        cell.imageView.image = nil;
        [cell.spinner startAnimating];
        [self loadThumbnailForAsset:asset key:key];
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    NSString *key = [(ZSAssetThumbCell *)cell representedKey];
    if (key.length == 0) return;
    [_wantedLock lock];
    [_wanted removeObject:key];
    [_wantedLock unlock];
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    if (indexPath.item < 0 || indexPath.item >= (NSInteger)self.assets.count) return;
    if (self.onSelect) self.onSelect(self.assets[(NSUInteger)indexPath.item]);
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)collectionViewLayout;
    CGFloat scale = MAX(collectionView.traitCollection.displayScale, 1);
    CGFloat spacing = layout.minimumInteritemSpacing;
    CGFloat available = floor((collectionView.bounds.size.width - layout.sectionInset.left - layout.sectionInset.right) * scale) / scale;
    NSInteger columns = MAX(3, (NSInteger)floor((available + spacing) / (96.0 + spacing)));
    CGFloat width = available - spacing * (columns - 1);
    NSInteger column = indexPath.item % columns;
    CGFloat left = floor(width * column / columns * scale) / scale;
    CGFloat right = column == columns - 1 ? width : floor(width * (column + 1) / columns * scale) / scale;
    CGFloat itemWidth = right - left;
    if (column == columns - 1) itemWidth -= 0.01;
    CGFloat side = floor(width / columns * scale) / scale;
    return CGSizeMake(MAX(itemWidth, 1), MAX(side, 1));
}

@end

@interface ZSSyslogCell : UITableViewCell
@property (nonatomic, strong) UILabel *indexLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) NSLayoutConstraint *indexLeading;
@property (nonatomic, strong) NSLayoutConstraint *textLeading;
@property (nonatomic, strong) NSLayoutConstraint *textTrailing;
@end

@implementation ZSSyslogCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.contentView.backgroundColor = UIColor.clearColor;

    UIFont *rowFont = [UIFont fontWithName:@"Menlo-Regular" size:11]
        ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    UIFont *indexFont = [UIFont fontWithName:@"Menlo-Regular" size:10]
        ?: [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    UIFont *headerFont = [UIFont fontWithName:@"Menlo-Regular" size:9]
        ?: [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];

    UILabel *indexLabel = [[UILabel alloc] init];
    indexLabel.translatesAutoresizingMaskIntoConstraints = NO;
    indexLabel.numberOfLines = 1;
    indexLabel.font = indexFont;
    indexLabel.textColor = [UIColor colorWithWhite:1 alpha:0.28];
    indexLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:indexLabel];
    self.indexLabel = indexLabel;

    UILabel *messageLabel = [[UILabel alloc] init];
    messageLabel.numberOfLines = 0;
    messageLabel.font = rowFont;
    messageLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    self.messageLabel = messageLabel;

    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.numberOfLines = 0;
    headerLabel.textAlignment = NSTextAlignmentLeft;
    headerLabel.font = headerFont;
    headerLabel.textColor = [UIColor colorWithWhite:1 alpha:0.32];
    self.headerLabel = headerLabel;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[messageLabel, headerLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3;
    [self.contentView addSubview:textStack];

    self.indexLeading = [indexLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0];
    self.textLeading = [textStack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0];
    self.textTrailing = [textStack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0];
    NSLayoutConstraint *bottom = [textStack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6];
    bottom.priority = UILayoutPriorityRequired - 1;

    [NSLayoutConstraint activateConstraints:@[
        [indexLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        self.indexLeading,
        [indexLabel.widthAnchor constraintEqualToConstant:kZSSyslogIndexColumnWidth],
        [textStack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        self.textLeading,
        self.textTrailing,
        bottom,
    ]];
    return self;
}

@end

@implementation ZSSyslogTableController

- (instancetype)init {
    self = [super init];
    if (self) {
        _lines = @[];
        _atBottom = YES;
    }
    return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.lines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier = @"zs.syslog.cell";
    ZSSyslogCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[ZSSyslogCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        if (self.longPressTarget) {
            UILongPressGestureRecognizer *longPress =
                [[UILongPressGestureRecognizer alloc] initWithTarget:self.longPressTarget action:@selector(handleSyslogFullScreenRowLongPress:)];
            longPress.minimumPressDuration = 0.4;
            [cell.contentView addGestureRecognizer:longPress];
        }
    }

    NSUInteger row = (NSUInteger)indexPath.row;
    NSString *line = row < self.lines.count ? self.lines[row] : @"";
    NSString *header = nil;
    NSString *message = nil;
    zs_parseSyslogLineHeader(line, &header, &message);

    cell.contentView.backgroundColor = (row % 2 == 0) ? [UIColor colorWithWhite:1 alpha:0.045] : UIColor.clearColor;
    cell.indexLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)(row + 1)];
    cell.messageLabel.text = message ?: line;
    cell.headerLabel.text = header;
    cell.headerLabel.hidden = header.length == 0;
    cell.indexLeading.constant = self.leftInset;
    cell.textLeading.constant = self.leftInset + kZSSyslogIndexColumnWidth + 3;
    cell.textTrailing.constant = -self.rightInset;
    objc_setAssociatedObject(cell.contentView, "zs_logLineText", line, OBJC_ASSOCIATION_RETAIN);
    return cell;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    BOOL nowAtBottom;
    if (scrollView.contentSize.height <= scrollView.bounds.size.height) {
        nowAtBottom = YES;
    } else {
        CGFloat maxY = scrollView.contentSize.height - scrollView.bounds.size.height + scrollView.adjustedContentInset.bottom;
        nowAtBottom = scrollView.contentOffset.y >= maxY - 48;
    }
    BOOL was = self.atBottom;
    self.atBottom = nowAtBottom;
    if (nowAtBottom && !was && self.reachedBottom) self.reachedBottom();
}

@end

BOOL zs_mod_library_has_zeroable_assets(void) {
    for (NSString *folderName in [ModAssetLibrary folderNames]) {
        if ([folderName isEqualToString:kZSStoredBundlesFolderName]) continue;
        NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:nil];
        for (ModAssetLibraryEntry *entry in entries) {
            if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) return YES;
            if ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) return YES;
        }
    }
    return NO;
}

@implementation ZSDocsScrollView

- (void)layoutSubviews {
    [super layoutSubviews];
    NSLayoutConstraint *constraint = self.minContentHeightConstraint;
    if (!constraint) return;
    CGFloat target = MAX(0, self.bounds.size.height - self.minContentHeightInset);
    if (fabs(constraint.constant - target) > 0.5) constraint.constant = target;
}

@end
