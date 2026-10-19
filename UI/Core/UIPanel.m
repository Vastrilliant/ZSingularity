#import "UIInternal.h"
#import "Docs.h"

@interface ZSDocsQuoteLayoutManager : NSLayoutManager
@end

@implementation ZSDocsQuoteLayoutManager

- (void)zs_enumerateTightRectsForGlyphRange:(NSRange)glyphRange
                                  container:(NSTextContainer *)container
                                 usingBlock:(void (^)(CGRect rect))block {
    NSString *text = self.textStorage.string;
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    [self enumerateLineFragmentsForGlyphRange:glyphRange usingBlock:^(CGRect rect, CGRect usedRect, NSTextContainer *lineContainer, NSRange lineGlyphRange, BOOL *stop) {
        NSRange sub = NSIntersectionRange(glyphRange, lineGlyphRange);
        if (sub.length == 0) return;

        NSRange chars = [self characterRangeForGlyphRange:sub actualGlyphRange:NULL];
        NSUInteger end = NSMaxRange(chars);
        while (end > chars.location && [whitespace characterIsMember:[text characterAtIndex:end - 1]]) end--;
        if (end <= chars.location) return;

        NSRange trimmedGlyphs = [self glyphRangeForCharacterRange:NSMakeRange(chars.location, end - chars.location)
                                              actualCharacterRange:NULL];
        CGRect tight = [self boundingRectForGlyphRange:trimmedGlyphs inTextContainer:container];
        tight.origin.y = usedRect.origin.y;
        tight.size.height = usedRect.size.height;
        block(tight);
    }];
}

- (void)drawBackgroundForGlyphRange:(NSRange)glyphsToShow atPoint:(CGPoint)origin {
    [super drawBackgroundForGlyphRange:glyphsToShow atPoint:origin];

    NSTextStorage *textStorage = self.textStorage;
    NSTextContainer *textContainer = self.textContainers.firstObject;
    if (!textStorage || !textContainer) return;

    NSRange characterRange = [self characterRangeForGlyphRange:glyphsToShow actualGlyphRange:NULL];

    [textStorage enumerateAttribute:kZSDocsCodeBackgroundAttributeName
                             inRange:characterRange
                             options:0
                          usingBlock:^(UIColor *color, NSRange range, BOOL *stop) {
        if (![color isKindOfClass:[UIColor class]] || range.length == 0) return;

        NSRange runGlyphRange = [self glyphRangeForCharacterRange:range actualCharacterRange:NULL];
        [self zs_enumerateTightRectsForGlyphRange:runGlyphRange
                                        container:textContainer
                                       usingBlock:^(CGRect rect) {
            CGRect fill = CGRectOffset(rect, origin.x, origin.y);
            fill = CGRectInset(fill, -2, 1);
            [color setFill];
            [[UIBezierPath bezierPathWithRoundedRect:fill cornerRadius:kZSDocsCodeCornerRadius] fill];
        }];
    }];

    NSMutableArray<NSDictionary *> *blocks = [NSMutableArray array];
    [textStorage enumerateAttribute:kZSDocsCodeBlockBackgroundAttributeName
                             inRange:characterRange
                             options:0
                          usingBlock:^(UIColor *color, NSRange range, BOOL *stop) {
        if (![color isKindOfClass:[UIColor class]] || range.length == 0) return;

        NSRange runGlyphRange = [self glyphRangeForCharacterRange:range actualCharacterRange:NULL];
        [self zs_enumerateTightRectsForGlyphRange:runGlyphRange
                                        container:textContainer
                                       usingBlock:^(CGRect rect) {
            CGRect fill = CGRectOffset(rect, origin.x, origin.y);
            NSDictionary *last = blocks.lastObject;
            if (last && last[@"color"] == color) {
                CGRect lastRect = [last[@"rect"] CGRectValue];
                if (CGRectGetMinY(fill) <= CGRectGetMaxY(lastRect) + 20) {
                    blocks[blocks.count - 1] = @{@"color": color,
                                                  @"rect": [NSValue valueWithCGRect:CGRectUnion(lastRect, fill)]};
                    return;
                }
            }
            [blocks addObject:@{@"color": color, @"rect": [NSValue valueWithCGRect:fill]}];
        }];
    }];
    for (NSDictionary *block in blocks) {
        CGRect fill = CGRectInset([block[@"rect"] CGRectValue], -6, -4);
        [(UIColor *)block[@"color"] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:fill cornerRadius:kZSDocsCodeBlockCornerRadius] fill];
    }

    [textStorage enumerateAttribute:kZSDocsQuoteBarColorAttributeName
                             inRange:characterRange
                             options:0
                          usingBlock:^(UIColor *color, NSRange range, BOOL *stop) {
        if (![color isKindOfClass:[UIColor class]] || range.length == 0) return;

        NSRange runGlyphRange = [self glyphRangeForCharacterRange:range actualCharacterRange:NULL];

        __block CGRect unionRect = CGRectNull;
        [self enumerateLineFragmentsForGlyphRange:runGlyphRange usingBlock:^(CGRect rect, CGRect usedRect, NSTextContainer *container, NSRange lineGlyphRange, BOOL *innerStop) {
            unionRect = CGRectIsNull(unionRect) ? usedRect : CGRectUnion(unionRect, usedRect);
        }];
        if (CGRectIsNull(unionRect)) return;

        CGRect barRect = CGRectMake(origin.x + textContainer.lineFragmentPadding,
                                     origin.y + unionRect.origin.y,
                                     kZSDocsQuoteBarWidth,
                                     unionRect.size.height);
        UIBezierPath *barPath = [UIBezierPath bezierPathWithRoundedRect:barRect cornerRadius:kZSDocsQuoteBarWidth / 2];
        [color setFill];
        [barPath fill];
    }];
}

@end

@implementation UserInterface (Panel)

#pragma mark Docs language switcher

static const CGFloat kZSDocsLanguageDropdownWidth = 132;

static UIImage *zs_make_docs_language_globe_image(void) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    UIImage *globeImage = [UIImage systemImageNamed:@"globe" withConfiguration:symbolConfig];
    globeImage = [globeImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.55]
                                   renderingMode:UIImageRenderingModeAlwaysOriginal];
    return globeImage;
}

UIButton *zs_make_docs_language_option_button(NSDictionary<NSString *, NSString *> *option, BOOL selected, NSInteger tag, id target, SEL action) {
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
    self.docsPanelWidth = self.panelWidth - kZSSectionIndexReservedWidth;

    if (zs_has_liquid_glass()) {
        // The extended window no longer owns a Liquid Glass surface. The main panel glass (panelGlass)
        // expands leftwards over it instead (see positionPanelAnimated:). docsPanel is only a
        // placeholder that marks the extended window as built.
        self.docsPanelGlass = nil;
        self.docsPanel = [[UIView alloc] init];
        self.docsPanel.hidden = YES;
    } else {
        self.docsPanel = [[UIView alloc] init];
        self.docsPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        self.docsPanel.layer.cornerRadius = kPanelCornerRadiusMinimum;
        self.docsPanel.layer.cornerCurve = kCACornerCurveContinuous;
        self.docsPanel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
        self.docsPanel.clipsToBounds = YES;
        [self.glassContainerContent addSubview:self.docsPanel];
        [self.glassContainerContent sendSubviewToBack:self.docsPanel];
    }
    self.docsPanel.backgroundColor = self.docsPanelGlass ? UIColor.clearColor : self.docsPanel.backgroundColor;
    self.docsPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    self.extendedContentClip = [[UIView alloc] initWithFrame:CGRectZero];
    self.extendedContentClip.backgroundColor = UIColor.clearColor;
    self.extendedContentClip.opaque = NO;
    self.extendedContentClip.clipsToBounds = YES;
    self.extendedContentClip.layer.cornerRadius = kPanelCornerRadiusMinimum;
    self.extendedContentClip.layer.cornerCurve = kCACornerCurveContinuous;
    self.extendedContentClip.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    self.extendedContentClip.userInteractionEnabled = YES;
    self.extendedContentClip.hidden = YES;
    [unityView addSubview:self.extendedContentClip];
    zs_mark_host_owned(self.extendedContentClip);
    if (self.contentOverlay) {
        [unityView insertSubview:self.extendedContentClip belowSubview:self.contentOverlay];
    }

    self.docsContentOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.docsContentOverlay.backgroundColor = UIColor.clearColor;
    self.docsContentOverlay.opaque = NO;
    self.docsContentOverlay.userInteractionEnabled = YES;
    self.docsContentOverlay.hidden = YES;
    [self.extendedContentClip addSubview:self.docsContentOverlay];
    zs_force_dark(self.docsContentOverlay);

    self.docsPanelSeparator = [[UIView alloc] init];
    self.docsPanelSeparator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    self.docsPanelSeparator.userInteractionEnabled = NO;
    self.docsPanelSeparator.hidden = YES;
    self.docsPanelSeparator.alpha = 0;
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
    [self.docsSubheaderLeftArrowButton.widthAnchor constraintEqualToConstant:28].active = YES;
    [self.docsSubheaderLeftArrowButton.heightAnchor constraintEqualToConstant:28].active = YES;
    [self.docsSubheaderLeftArrowButton addTarget:self action:@selector(docsSubheaderOlderReleaseTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.docsSubheaderPageLabel = [[UILabel alloc] init];
    self.docsSubheaderPageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsSubheaderPageLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.docsSubheaderPageLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];

    self.docsSubheaderRightArrowButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.docsSubheaderRightArrowButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.docsSubheaderRightArrowButton setImage:zs_make_release_history_arrow_image(NO) forState:UIControlStateNormal];
    self.docsSubheaderRightArrowButton.hidden = YES;
    [self.docsSubheaderRightArrowButton.widthAnchor constraintEqualToConstant:28].active = YES;
    [self.docsSubheaderRightArrowButton.heightAnchor constraintEqualToConstant:28].active = YES;
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

    self.docsScrollView = [[ZSDocsScrollView alloc] init];
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
        NSForegroundColorAttributeName: [UIColor colorWithRed:0x30 / 255.0 green:0xD1 / 255.0 blue:0x58 / 255.0 alpha:1.0],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    };
    self.docsBodyLabel.delegate = self;
    [docsContent addArrangedSubview:self.docsBodyLabel];

    self.docsUpdateActionsSpacer = [[UIView alloc] init];
    self.docsUpdateActionsSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    self.docsUpdateActionsSpacer.hidden = YES;
    [self.docsUpdateActionsSpacer setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
    [self.docsUpdateActionsSpacer setContentCompressionResistancePriority:1 forAxis:UILayoutConstraintAxisVertical];
    [docsContent addArrangedSubview:self.docsUpdateActionsSpacer];
    [docsContent setCustomSpacing:0 afterView:self.docsBodyLabel];

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

    NSLayoutConstraint *docsMinHeightConstraint = [docsContent.heightAnchor constraintGreaterThanOrEqualToConstant:0];
    ((ZSDocsScrollView *)self.docsScrollView).minContentHeightConstraint = docsMinHeightConstraint;
    ((ZSDocsScrollView *)self.docsScrollView).minContentHeightInset = kPanelPadding * 2;

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
        docsMinHeightConstraint,
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

NSDictionary *zs_load_collapsed_section_states(void) {
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
    [self zs_refreshSectionIndex];
    [self zs_removeDeveloperOnlyPins];

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

static NSArray<NSArray<NSString *> *> *zs_section_index_entries(void) {
    return @[
        @[@"Display", @"DI"],
        @[@"Rendering", @"RE"],
        @[@"Anti-Aliasing", @"AA"],
        @[@"Post FX", @"FX"],
        @[@"Particles", @"PA"],
        @[@"Memory management", @"MM"],
        @[@"Mods", @"MO"],
        @[@"Developer", @"DV"],
        @[@"Miscellaneous", @"MS"],
        @[@"Config", @"CN"],
    ];
}

- (UIView *)zs_headerRowForSectionTitle:(NSString *)title {
    for (UIView *view in self.stack.arrangedSubviews) {
        if (![objc_getAssociatedObject(view, "zs_isSectionHeader") boolValue]) continue;
        NSString *viewTitle = objc_getAssociatedObject(view, "zs_sectionTitle");
        if ([viewTitle isEqualToString:title]) return view;
    }
    return nil;
}

- (void)zs_refreshSectionIndex {
    if (!self.sectionIndexView) return;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSString *> *initials = [NSMutableArray array];
    for (NSArray<NSString *> *entry in zs_section_index_entries()) {
        NSString *name = entry[0];
        if ([name isEqualToString:@"Developer"] && !zs_developer_settings_enabled()) continue;

        UIView *header = [self zs_headerRowForSectionTitle:name];
        BOOL collapsed = header
            ? [objc_getAssociatedObject(header, "zs_sectionCollapsed") boolValue]
            : [self.pendingCollapsedStates[name] boolValue];
        if (collapsed) continue;

        [names addObject:name];
        [initials addObject:entry[1]];
    }

    self.sectionIndexSectionNames = names;
    [self.sectionIndexView setTitles:initials fullTitles:names];
    self.sectionIndexView.hidden = initials.count == 0;
}

- (void)zs_scrollToSectionAtIndex:(NSUInteger)index {
    if (!self.scrollView || !self.stack) return;
    if (index >= self.sectionIndexSectionNames.count) return;
    NSString *title = self.sectionIndexSectionNames[index];

    UIView *header = [self zs_headerRowForSectionTitle:title];
    while (!header && (self.pendingSectionBuilders.count > 0 || [self zs_hasPendingExperimentalSectionBuilders])) {
        [self zs_runNextPendingSectionBuilder];
        header = [self zs_headerRowForSectionTitle:title];
    }
    if (!header) return;

    [self.stack setNeedsLayout];
    [self.stack layoutIfNeeded];
    [self.scrollView layoutIfNeeded];

    UIEdgeInsets inset = self.scrollView.contentInset;
    CGFloat viewportHeight = self.scrollView.bounds.size.height;
    CGFloat targetY = CGRectGetMinY([self.scrollView convertRect:header.bounds fromView:header]) - inset.top - kContentFadeHeight;

    while (self.pendingSectionBuilders.count > 0 || [self zs_hasPendingExperimentalSectionBuilders]) {
        CGFloat reachableY = self.stack.bounds.size.height + (kPanelPadding * 2) - viewportHeight + inset.bottom;
        if (reachableY >= targetY) break;
        [self zs_runNextPendingSectionBuilder];
        [self.stack setNeedsLayout];
        [self.stack layoutIfNeeded];
    }
    [self.scrollView layoutIfNeeded];

    CGFloat minY = -inset.top;
    CGFloat maxY = MAX(self.scrollView.contentSize.height - viewportHeight + inset.bottom, minY);
    CGFloat offsetY = MIN(MAX(targetY, minY), maxY);
    [self.scrollView setContentOffset:CGPointMake(self.scrollView.contentOffset.x, offsetY) animated:NO];
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
    [self zs_refreshSectionIndex];

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
    if (textView.tag == kZSCrashMessageTextViewTag) {
        [[UIApplication sharedApplication] openURL:URL options:@{} completionHandler:nil];
        return NO;
    }

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
    self.docsSubheaderLeftArrowButton.hidden = !visible;
    self.docsSubheaderRightArrowButton.hidden = !visible;
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
    self.syslogFullScreenOpen = NO;
    [self zs_endAssetExplorerSession];
    [self zs_syncSyslogButtonState];
    [self zs_endMemoryAnalysis];
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

    BOOL wasOpen = self.docsPanelOpen;
    self.docsPanelOpen = YES;
    [self positionPanelAnimated:YES];
    if (!wasOpen) {
        [UIView animateWithDuration:0.2 animations:^{
            self.chevron.text = @"\u2715";
        }];
    }
}

- (void)closeDocsPanel {
    if (!self.docsPanelOpen) return;

    if (self.extendedCoverMode) {
        [self closePanel];
        return;
    }

    if (self.docsLanguageDropdownOpen) {
        [self zs_closeDocsLanguageDropdownAnimated:NO];
    }

    self.docsPanelOpen = NO;
    self.docsActiveKey = nil;
    self.syslogFullScreenOpen = NO;
    [self zs_endAssetExplorerSession];
    [self zs_syncSyslogButtonState];
    [self zs_endMemoryAnalysis];
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

#pragma mark Pinned actions

// STUB: the pull tabs used to tuck themselves in behind the main panel (and hide) while an extended window
// was open. With the main panel expanding over the extended window they now simply follow its left edge and
// end up off-screen when it is fully extended. Return YES to restore the old tuck-in behaviour.
static BOOL zs_pull_tabs_tuck_into_panel_when_extended(void) { return NO; }

// STUB: the main panel used to flatten its left corners while an extended window was open (because a second
// glass surface sat flush against it). The expanded panel keeps its rounded corners instead.
// Return YES to restore flattening.
static BOOL zs_flatten_main_panel_left_corners_when_extended(void) { return NO; }

static NSString * const kZSPinKeyMemory = @"memory";
static NSString * const kZSPinKeySyslog = @"syslog";
static NSString * const kZSPinKeyMemoryCleanup = @"memoryCleanup";
static NSString * const kZSPinKeyAssetExplorer = @"assetExplorer";
static NSString * const kZSPinKeyReapply = @"reapplySettings";
static NSString * const kZSPinnedActionsSettingsSection = @"pinnedActions";
static NSString * const kZSPinnedActionsSettingsKey = @"keys";

static const CGFloat kZSPinnedTabHeight = 48;
static const CGFloat kZSPinnedTabGap = 4;
static const NSInteger kZSPinnedIconTag = 0x5A50;
static const NSInteger kZSPinMenuPinIconTag = 0x5A51;
static const NSTimeInterval kZSPinRecenterDelay = 0.5;
static const CGFloat kZSPinMenuWidth = 224;
static const CGFloat kZSPinMenuHeaderTop = 10;
static const CGFloat kZSPinMenuHeaderHeight = 28;
static const CGFloat kZSPinMenuHeaderGap = 6;
static const CGFloat kZSPinMenuRowHeight = 36;
static const CGFloat kZSPinMenuBottomPadding = 8;
static const CGFloat kZSPinMenuCornerRadius = 20;

static NSArray<NSDictionary<NSString *, NSString *> *> *zs_pin_action_catalog(void) {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *catalog = [NSMutableArray arrayWithObjects:
        @{@"key": kZSMTHandleKey, @"title": @"Pull Tab", @"symbol": @"chevron.left"},
        @{@"key": kZSPinKeyMemory, @"title": @"Memory Analysis", @"symbol": @"memorychip"},
        @{@"key": kZSPinKeyMemoryCleanup, @"title": @"Memory Cleanup", @"symbol": @"sparkles"},
        @{@"key": kZSPinKeyAssetExplorer, @"title": @"Asset Explorer", @"symbol": @"shippingbox.fill"},
        nil];
    if (zs_developer_settings_enabled()) {
        [catalog addObject:@{@"key": kZSPinKeySyslog, @"title": @"Console Log", @"symbol": @"terminal"}];
    }
    [catalog addObject:@{@"key": kZSPinKeyReapply, @"title": @"Reapply Settings", @"symbol": @"arrow.clockwise"}];
    return catalog;
}

static NSDictionary<NSString *, NSString *> *zs_pin_action_for_key(NSString *key) {
    for (NSDictionary<NSString *, NSString *> *action in zs_pin_action_catalog()) {
        if ([action[@"key"] isEqualToString:key]) return action;
    }
    return nil;
}

static UIImage *zs_pin_symbol(NSString *name, CGFloat pointSize, UIFontWeight weight) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight == UIFontWeightSemibold ? UIImageSymbolWeightSemibold : UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:name withConfiguration:config];
}

static void zs_configure_glass_corners_flat_right(UIView *view, CGFloat leftRadius) {
    if (!view || !zs_has_liquid_glass()) return;

    Class radiusClass = NSClassFromString(@"UICornerRadius");
    Class configClass = NSClassFromString(@"UICornerConfiguration");
    SEL fixedSelector = NSSelectorFromString(@"fixedRadius:");
    SEL fourCornerSelector = NSSelectorFromString(@"configurationWithTopLeftRadius:topRightRadius:bottomLeftRadius:bottomRightRadius:");
    SEL setConfiguration = NSSelectorFromString(@"setCornerConfiguration:");

    if (!radiusClass || !configClass ||
        ![radiusClass respondsToSelector:fixedSelector] ||
        ![configClass respondsToSelector:fourCornerSelector] ||
        ![view respondsToSelector:setConfiguration]) {
        zs_configure_glass_corners(view, leftRadius, NO);
        return;
    }

    id flat = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass, fixedSelector, 0);
    id round = ((id (*)(id, SEL, CGFloat))objc_msgSend)(radiusClass, fixedSelector, leftRadius);
    id configuration = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(configClass, fourCornerSelector, round, flat, round, flat);

    if (!configuration) {
        zs_configure_glass_corners(view, leftRadius, NO);
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(view, setConfiguration, configuration);
}

- (NSMutableArray<NSString *> *)zs_pinnedKeys {
    if (!self.pinnedActionKeys) {
        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        id stored = zs_settings_section(kZSPinnedActionsSettingsSection)[kZSPinnedActionsSettingsKey];
        if ([stored isKindOfClass:[NSArray class]]) {
            for (id entry in (NSArray *)stored) {
                if ([entry isKindOfClass:[NSString class]] && zs_pin_action_for_key(entry) && ![keys containsObject:entry]) {
                    [keys addObject:entry];
                }
            }
        }
        self.pinnedActionKeys = keys;
    }
    return self.pinnedActionKeys;
}

- (NSArray<NSString *> *)zs_pinnedActionKeys {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSString *key in [self zs_pinnedKeys]) {
        if (![key isEqualToString:kZSMTHandleKey]) [keys addObject:key];
    }
    return keys;
}

- (void)zs_removeDeveloperOnlyPins {
    if (zs_developer_settings_enabled()) return;
    [self zs_removePinnedKey:kZSPinKeySyslog delay:0];
}

- (void)zs_persistPinnedKeys {
    zs_write_settings_section(kZSPinnedActionsSettingsSection, @{kZSPinnedActionsSettingsKey: [[self zs_pinnedKeys] copy]});
}

- (CGRect)zs_pinnedSlotFrameAtIndex:(NSUInteger)index handleY:(CGFloat)handleY localX:(CGFloat)x {
    CGFloat y = handleY - kZSPinnedTabGap - kZSPinnedTabHeight - (CGFloat)index * (kZSPinnedTabHeight + kZSPinnedTabGap);
    return CGRectMake(x, y, kHandleWidth, kZSPinnedTabHeight);
}

- (CGRect)zs_pinnedOriginFrameForHandleY:(CGFloat)handleY localX:(CGFloat)x {
    return CGRectMake(x, handleY + (kHandleHeight - kZSPinnedTabHeight) * 0.5, kHandleWidth, kZSPinnedTabHeight);
}

- (BOOL)zs_expandsMainPanel {
    return zs_has_liquid_glass() && self.panelGlass != nil;
}

- (BOOL)zs_pullTabsHiddenForFullScreen:(BOOL)fullScreenOpen {
    if (!fullScreenOpen) return NO;
    if (![self zs_expandsMainPanel]) return YES;
    return zs_pull_tabs_tuck_into_panel_when_extended();
}

- (CGFloat)zs_handleRestingY {
    return (CGRectGetHeight(self.glassContainer.bounds) - kHandleHeight) * 0.5 + self.pinClusterOffsetY;
}

- (CGFloat)zs_centeredClusterOffset {
    return (CGFloat)[self zs_pinnedActionKeys].count * (kZSPinnedTabHeight + kZSPinnedTabGap) * 0.5;
}

- (CGRect)zs_pinAnchorFrame {
    return (self.handleGlass ?: self.handle).frame;
}

- (CGFloat)zs_pinAnchorX {
    return CGRectGetMaxX([self zs_pinAnchorFrame]) - kHandleWidth;
}

- (CGFloat)zs_pinAnchorY {
    return [self zs_pinAnchorFrame].origin.y;
}

- (CGRect)zs_pinnedOriginFrameForAnchor {
    CGRect anchor = [self zs_pinAnchorFrame];
    return CGRectMake([self zs_pinAnchorX], CGRectGetMidY(anchor) - kZSPinnedTabHeight * 0.5, kHandleWidth, kZSPinnedTabHeight);
}

- (void)zs_applyPinClusterLayout {
    UIView *handleElement = self.handleGlass ?: self.handle;
    if (!handleElement || !self.glassContainer) return;
    CGFloat y = [self zs_handleRestingY];
    CGRect frame = handleElement.frame;
    handleElement.frame = CGRectMake(frame.origin.x, y, frame.size.width, frame.size.height);
    BOOL fullScreenOpen = self.syslogFullScreenOpen || self.memoryFullScreenOpen || self.assetExplorerFullScreenOpen;
    [self zs_layoutPinnedTabsWithHandleY:y localX:frame.origin.x visible:![self zs_pullTabsHiddenForFullScreen:fullScreenOpen]];
}

- (void)zs_schedulePinClusterRecenter {
    if (!self.pinRecenterPending) return;
    self.pinRecenterToken = self.pinRecenterToken + 1;
    NSUInteger token = self.pinRecenterToken;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZSPinRecenterDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.pinRecenterToken != token) return;
        [strongSelf zs_recenterPinCluster];
    });
}

- (void)zs_recenterPinCluster {
    if (self.pinMenuOpen || !self.panelOpen || !self.glassContainer) return;
    self.pinRecenterPending = NO;

    CGFloat target = [self zs_centeredClusterOffset];
    if (fabs(target - self.pinClusterOffsetY) < 0.5) {
        self.pinClusterOffsetY = target;
        return;
    }
    self.pinClusterOffsetY = target;

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.45
                          delay:0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.2
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [weakSelf zs_applyPinClusterLayout];
    } completion:nil];
}

- (CGFloat)zs_handleLocalX {
    return (self.handleGlass ?: self.handle).frame.origin.x;
}

- (UIView *)zs_makePinnedTabElementForKey:(NSString *)key {
    NSDictionary<NSString *, NSString *> *action = zs_pin_action_for_key(key);
    if ([key isEqualToString:kZSMTHandleKey] || !action || !self.glassContainerContent) return nil;

    UIView *element = nil;
    UIView *content = nil;

    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(YES)];
        glass.userInteractionEnabled = YES;
        zs_configure_glass_corners(glass, kHandleCornerRadius, NO);
        element = glass;
        content = glass.contentView;
    } else {
        UIView *tab = [[UIView alloc] init];
        tab.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        tab.layer.cornerRadius = kHandleCornerRadius;
        tab.layer.cornerCurve = kCACornerCurveContinuous;
        tab.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
        element = tab;
        content = tab;
    }

    element.frame = [self zs_pinnedOriginFrameForAnchor];
    [self.glassContainerContent addSubview:element];

    UIImageView *icon = [[UIImageView alloc] initWithImage:zs_pin_symbol(action[@"symbol"], 13, UIFontWeightMedium)];
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
    icon.contentMode = UIViewContentModeCenter;
    icon.frame = content.bounds;
    icon.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    icon.tag = kZSPinnedIconTag;
    [content addSubview:icon];

    content.userInteractionEnabled = YES;
    content.isAccessibilityElement = YES;
    content.accessibilityLabel = action[@"title"];
    content.accessibilityTraits = UIAccessibilityTraitButton;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_pinnedTabTapped:)];
    objc_setAssociatedObject(tap, "zs_pinKey", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [content addGestureRecognizer:tap];

    if (!self.pinnedTabElements) self.pinnedTabElements = [NSMutableDictionary dictionary];
    self.pinnedTabElements[key] = element;
    [self zs_restackPinChrome];
    return element;
}

- (void)zs_restackPinChrome {
    UIView *container = self.glassContainerContent;
    if (!container) return;

    UIView *panelElement = self.panelGlass ?: self.panel;
    UIView *handleElement = self.handleGlass ?: self.handle;
    UIView *docsElement = self.docsPanelGlass ?: self.docsPanel;

    if (panelElement.superview == container) [container sendSubviewToBack:panelElement];
    if (handleElement.superview == container) [container sendSubviewToBack:handleElement];
    for (UIView *tab in self.pinnedTabElements.allValues) {
        if (tab.superview == container) [container sendSubviewToBack:tab];
    }
    if (docsElement.superview == container) [container sendSubviewToBack:docsElement];
}

- (void)zs_buildPinnedTabsFromStore {
    self.pinClusterOffsetY = [self zs_centeredClusterOffset];
    self.pinRecenterPending = NO;
    self.pinRecenterToken = self.pinRecenterToken + 1;
    self.pinnedTabElements = [NSMutableDictionary dictionary];
    for (NSString *key in [self zs_pinnedActionKeys]) {
        [self zs_makePinnedTabElementForKey:key];
    }
}

- (void)zs_layoutPinnedTabsWithHandleY:(CGFloat)handleY localX:(CGFloat)x visible:(BOOL)visible {
    [self zs_layoutPinnedTabsWithHandleY:handleY localX:x visible:visible updateIcons:YES];
}

- (void)zs_layoutPinnedTabsWithHandleY:(CGFloat)handleY localX:(CGFloat)x visible:(BOOL)visible updateIcons:(BOOL)updateIcons {
    NSArray<NSString *> *keys = [self zs_pinnedActionKeys];
    for (NSUInteger idx = 0; idx < keys.count; idx++) {
        UIView *element = self.pinnedTabElements[keys[idx]];
        if (!element) continue;
        element.frame = [self zs_pinnedSlotFrameAtIndex:idx handleY:handleY localX:x];
        element.userInteractionEnabled = visible;
        if (updateIcons) [element viewWithTag:kZSPinnedIconTag].alpha = visible ? 1 : 0;
    }
}

- (void)zs_addPinnedKey:(NSString *)key delay:(NSTimeInterval)delay {
    NSMutableArray<NSString *> *keys = [self zs_pinnedKeys];
    if ([keys containsObject:key] || !zs_pin_action_for_key(key)) return;
    [keys addObject:key];
    [self zs_persistPinnedKeys];
    if ([key isEqualToString:kZSMTHandleKey]) {
        [self zs_refreshMetalTabs];
        return;
    }
    self.pinRecenterPending = YES;
    if (!self.pinMenuOpen) [self zs_schedulePinClusterRecenter];

    __weak typeof(self) weakSelf = self;
    dispatch_block_t emerge = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.glassContainerContent || !strongSelf.panelOpen) return;
        NSUInteger idx = [[strongSelf zs_pinnedActionKeys] indexOfObject:key];
        if (idx == NSNotFound || strongSelf.pinnedTabElements[key]) return;

        UIView *element = [strongSelf zs_makePinnedTabElementForKey:key];
        if (!element) return;

        UIView *icon = [element viewWithTag:kZSPinnedIconTag];
        icon.alpha = 0;
        [strongSelf.glassContainerContent layoutIfNeeded];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) innerSelf = weakSelf;
            if (!innerSelf || !innerSelf.panelOpen || innerSelf.pinnedTabElements[key] != element) return;
            NSUInteger slotIdx = [[innerSelf zs_pinnedActionKeys] indexOfObject:key];
            if (slotIdx == NSNotFound) return;
            CGRect slot = [innerSelf zs_pinnedSlotFrameAtIndex:slotIdx handleY:[innerSelf zs_pinAnchorY] localX:[innerSelf zs_pinAnchorX]];

            [UIView animateWithDuration:0.5
                                  delay:0
                 usingSpringWithDamping:0.72
                  initialSpringVelocity:0.5
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                element.frame = slot;
                icon.alpha = 1;
            } completion:nil];
        });
    };

    if (delay > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), emerge);
    } else {
        emerge();
    }
}

- (void)zs_removePinnedKey:(NSString *)key delay:(NSTimeInterval)delay {
    NSMutableArray<NSString *> *keys = [self zs_pinnedKeys];
    NSUInteger idx = [keys indexOfObject:key];
    if (idx == NSNotFound) return;

    UIView *element = self.pinnedTabElements[key];
    [keys removeObjectAtIndex:idx];
    [self.pinnedTabElements removeObjectForKey:key];
    [self zs_persistPinnedKeys];
    self.pinRecenterPending = YES;
    if (!self.pinMenuOpen) [self zs_schedulePinClusterRecenter];
    if (!element) return;

    __weak typeof(self) weakSelf = self;
    CGFloat handleY = [self zs_pinAnchorY];
    CGFloat localX = [self zs_pinAnchorX];
    CGRect origin = [self zs_pinnedOriginFrameForAnchor];
    [UIView animateWithDuration:0.38
                          delay:delay
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.2
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        element.frame = origin;
        [element viewWithTag:kZSPinnedIconTag].alpha = 0;
        [weakSelf zs_layoutPinnedTabsWithHandleY:handleY localX:localX visible:YES];
    } completion:^(BOOL finished) {
        [element removeFromSuperview];
    }];
}

- (void)zs_refreshMetalTabs {
    [self zs_syncMetalTabsAllowingHierarchy:NO snap:NO];
}

- (void)zs_syncMetalTabsAllowingHierarchy:(BOOL)allowHierarchy snap:(BOOL)snap {
    ZSMetalTabs *tabs = [ZSMetalTabs shared];
    UIView *unityView = zs_ui_host_view();
    NSArray<NSString *> *pinnedKeys = [[self zs_pinnedKeys] copy];
    NSArray<NSString *> *keys = [self zs_pinnedActionKeys];
    BOOL handlePinned = [pinnedKeys containsObject:kZSMTHandleKey];
    BOOL hasPinnedItems = handlePinned || keys.count > 0;
    BOOL show = unityView && self.installed && !self.panelOpen && (allowHierarchy || !self.glassContainer) && !self.tutorialPresented && !self.crashReportPresented && hasPinnedItems;
    if (!show) {
        [tabs setVisible:NO snap:NO];
        return;
    }
    [tabs ensureInstalled];

    CGSize size = unityView.bounds.size;
    CGFloat tabX = size.width - kHandleWidth;
    CGFloat handleY = (size.height - kHandleHeight) * 0.5 + (CGFloat)keys.count * (kZSPinnedTabHeight + kZSPinnedTabGap) * 0.5;
    if (!handlePinned) handleY += (kHandleHeight + kZSPinnedTabGap) * 0.5;
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    NSMutableArray<NSString *> *itemKeys = [NSMutableArray array];
    NSMutableArray<NSString *> *symbols = [NSMutableArray array];
    if (handlePinned) {
        [rects addObject:[NSValue valueWithCGRect:CGRectMake(tabX, handleY, kHandleWidth, kHandleHeight)]];
        [itemKeys addObject:kZSMTHandleKey];
        [symbols addObject:@""];
    }
    for (NSUInteger idx = 0; idx < keys.count; idx++) {
        NSDictionary<NSString *, NSString *> *action = zs_pin_action_for_key(keys[idx]);
        if (!action) continue;
        [rects addObject:[NSValue valueWithCGRect:[self zs_pinnedSlotFrameAtIndex:idx handleY:handleY localX:tabX]]];
        [itemKeys addObject:keys[idx]];
        [symbols addObject:action[@"symbol"] ?: @""];
    }
    [tabs updateWithViewSize:size rects:rects keys:itemKeys symbols:symbols glass:zs_has_liquid_glass() visible:YES snap:snap];
}

- (void)zs_metalTabActivatedForKey:(NSString *)key {
    if (self.panelOpen || self.glassContainer || !key) return;
    if ([key isEqualToString:kZSMTHandleKey]) {
        [self openPanel];
        return;
    }
    [self zs_performPinnedActionForKey:key];
}

- (void)zs_selectModeOpenLocation:(ZSAssetLocation *)location {
    if (!location) return;
    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];
    [self zs_exitSelectMode];

    if (!self.panelOpen) {
        [self zs_openExtendedOnlyForKey:kZSPinKeyAssetExplorer];
    } else {
        [self zs_openAssetExplorerFullScreenPanel];
    }
    if (!self.assetExplorerFullScreenOpen) return;

    if (!self.assetExplorerHubVisible) [self zs_assetExplorerShowHub];
    [self zs_assetExplorerHubUnityTapped];

    NSString *path = [location.filePath copy];
    NSString *cab = [location.cabIdentifier copy];
    NSString *name = [location.bundleName copy];
    ZSAssetLocation *focus = [ZSAssetLocation new];
    focus.pathID = location.pathID;
    focus.classID = location.classID;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<ZSAssetExplorerBundle *> *bundles = [ZSAssetExplorer cachedBundles:&error] ?: @[];
        ZSAssetExplorerBundle *match = nil;
        for (ZSAssetExplorerBundle *candidate in bundles) {
            if (path.length > 0 && [candidate.filePath isEqualToString:path]) { match = candidate; break; }
        }
        if (!match) {
            for (ZSAssetExplorerBundle *candidate in bundles) {
                if (cab.length > 0 && [candidate.cabIdentifier isEqualToString:cab]) { match = candidate; break; }
            }
        }
        if (!match) {
            match = [[ZSAssetExplorerBundle alloc] init];
            match.cabIdentifier = cab ?: @"";
            match.displayName = name.length > 0 ? name : (cab ?: @"");
            match.filePath = path ?: @"";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UserInterface *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || strongSelf.assetExplorerSelectedBundle) return;
            if (bundles.count > 0 && strongSelf.assetExplorerBundles.count == 0) strongSelf.assetExplorerBundles = bundles;
            [strongSelf zs_assetExplorerOpenBundle:match focusLocation:focus];
        });
    });
}

- (void)zs_openExtendedOnlyForKey:(NSString *)key {
    UIView *unityView = zs_ui_host_view();
    if (!unityView || self.panelOpen) return;

    BOOL isMemory = [key isEqualToString:kZSPinKeyMemory];
    BOOL isAssetExplorer = [key isEqualToString:kZSPinKeyAssetExplorer];

    self.panelOpen = YES;
    [[ZSMetalTabs shared] setVisible:NO snap:NO];
    [self buildPanel:unityView];
    zs_reapply_all_settings();

    self.extendedCoverMode = YES;
    self.extendedCoverEntering = YES;
    if (isMemory) {
        [self memoryUsageAnalyzeTapped:nil];
    } else if (isAssetExplorer) {
        [self zs_openAssetExplorerFullScreenPanel];
    } else {
        self.syslogTabEnabled = NO;
        [self toggleSyslogTapped];
    }
    self.extendedCoverEntering = NO;

    UIView *container = self.glassContainer;
    UIView *clip = self.extendedContentClip;
    if (!container || !clip || !self.docsPanelOpen) {
        self.extendedCoverMode = NO;
        self.panelOpen = NO;
        [self teardownPanelState];
        [self zs_syncMetalTabsAllowingHierarchy:YES snap:NO];
        return;
    }

    CGFloat offscreenDeltaX = unityView.bounds.size.width;
    CGRect containerRestingFrame = container.frame;
    CGRect clipRestingFrame = clip.frame;

    [UIView performWithoutAnimation:^{
        container.frame = CGRectOffset(containerRestingFrame, offscreenDeltaX, 0);
        clip.frame = CGRectOffset(clipRestingFrame, offscreenDeltaX, 0);
        container.hidden = NO;
        [unityView layoutIfNeeded];
    }];

    [[FPS120Controller shared] setPanelOpen:YES];
    zs_set_glass_suspended(NO);
    zs_gif_tint_set_paused(NO);
    zs_logo_effects_set_paused(NO);
    zs_gif_tint_reconstruct_all();

    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        container.frame = containerRestingFrame;
        clip.frame = clipRestingFrame;
    } completion:nil];
}

- (void)zs_pinnedTabTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    if (self.pinMenuOpen) return;
    NSString *key = objc_getAssociatedObject(gesture, "zs_pinKey");
    [self zs_performPinnedActionForKey:key];
}

- (void)zs_performPinnedActionForKey:(NSString *)key {
    if (!key) return;
    if ([key isEqualToString:kZSMTHandleKey]) {
        if (!self.panelOpen) [self openPanel];
        return;
    }
    BOOL needsPanel = [key isEqualToString:kZSPinKeyMemory] || [key isEqualToString:kZSPinKeySyslog] || [key isEqualToString:kZSPinKeyAssetExplorer];
    if (needsPanel && !self.panelOpen) {
        [self zs_openExtendedOnlyForKey:key];
        return;
    }
    if ([key isEqualToString:kZSPinKeyMemory]) {
        [self memoryUsageAnalyzeTapped:nil];
    } else if ([key isEqualToString:kZSPinKeySyslog]) {
        self.syslogTabEnabled = self.syslogFullScreenOpen;
        [self toggleSyslogTapped];
    } else if ([key isEqualToString:kZSPinKeyMemoryCleanup]) {
        [self memoryCleanupTapped:nil];
    } else if ([key isEqualToString:kZSPinKeyAssetExplorer]) {
        [self zs_openAssetExplorerFullScreenPanel];
    } else if ([key isEqualToString:kZSPinKeyReapply]) {
        [self reapplySettingsTapped];
    }
}

- (void)zs_handleHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [self zs_presentPinMenu];
}

- (void)zs_shiftPinContainerByExtraWidth:(CGFloat)extra {
    if (extra == 0 || !self.glassContainer || !self.glassContainerContent) return;
    CGRect container = self.glassContainer.frame;
    self.glassContainer.frame = CGRectMake(container.origin.x - extra, container.origin.y, container.size.width + extra, container.size.height);
    for (UIView *view in self.glassContainerContent.subviews) {
        view.frame = CGRectOffset(view.frame, extra, 0);
    }
}

- (void)zs_presentPinMenu {
    if (self.pinMenuOpen || self.pinMenuTransitioning) return;
    if (!self.panelOpen || !self.glassContainer || !self.glassContainerContent) return;
    if (self.docsPanelOpen || self.syslogFullScreenOpen || self.memoryFullScreenOpen) return;

    self.pinRecenterToken = self.pinRecenterToken + 1;

    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;

    NSArray<NSDictionary<NSString *, NSString *> *> *catalog = zs_pin_action_catalog();
    NSArray<NSString *> *pinned = [self zs_pinnedKeys];
    UIView *handleElement = self.handleGlass ?: self.handle;
    BOOL glass = zs_has_liquid_glass();

    CGFloat menuHeight = kZSPinMenuHeaderTop + kZSPinMenuHeaderHeight + kZSPinMenuHeaderGap
                       + kZSPinMenuRowHeight * catalog.count + kZSPinMenuBottomPadding;
    CGFloat extra = kZSPinMenuWidth - kHandleWidth;

    [self zs_shiftPinContainerByExtraWidth:extra];
    self.pinMenuExtraWidth = extra;

    CGFloat containerHeight = CGRectGetHeight(self.glassContainer.bounds);
    UIEdgeInsets insets = unityView.safeAreaInsets;
    CGFloat midY = CGRectGetMidY(handleElement.frame);
    CGFloat expandedY = midY - menuHeight * 0.5;
    expandedY = MAX(insets.top + 8, MIN(expandedY, containerHeight - insets.bottom - 8 - menuHeight));
    CGRect expanded = CGRectMake(0, expandedY, kZSPinMenuWidth, menuHeight);

    ZSPinScrimView *scrim = [[ZSPinScrimView alloc] initWithFrame:unityView.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = UIColor.clearColor;
    scrim.passthroughRect = [self.glassContainerContent convertRect:expanded toView:unityView];
    UITapGestureRecognizer *scrimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_pinMenuDismissTapped)];
    [scrim addGestureRecognizer:scrimTap];
    [unityView addSubview:scrim];
    zs_mark_host_owned(scrim);

    UIView *menuContent = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kZSPinMenuWidth, menuHeight)];
    menuContent.alpha = 0;
    [self.handle addSubview:menuContent];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setImage:zs_pin_symbol(@"xmark", 13, UIFontWeightSemibold) forState:UIControlStateNormal];
    closeButton.tintColor = [UIColor colorWithWhite:1 alpha:0.78];
    closeButton.frame = CGRectMake(10, kZSPinMenuHeaderTop, 28, kZSPinMenuHeaderHeight);
    closeButton.accessibilityLabel = @"Close";
    [closeButton addTarget:self action:@selector(zs_pinMenuDismissTapped) forControlEvents:UIControlEventTouchUpInside];
    [menuContent addSubview:closeButton];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(44, kZSPinMenuHeaderTop, kZSPinMenuWidth - 56, kZSPinMenuHeaderHeight)];
    title.text = @"Pin an action";
    title.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    title.font = zs_mono_font(13, UIFontWeightSemibold);
    [menuContent addSubview:title];

    CGFloat rowY = kZSPinMenuHeaderTop + kZSPinMenuHeaderHeight + kZSPinMenuHeaderGap;
    for (NSDictionary<NSString *, NSString *> *action in catalog) {
        BOOL isPinned = [pinned containsObject:action[@"key"]];

        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.frame = CGRectMake(0, rowY, kZSPinMenuWidth, kZSPinMenuRowHeight);
        objc_setAssociatedObject(row, "zs_pinKey", action[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
        [row addTarget:self action:@selector(zs_pinMenuRowTapped:) forControlEvents:UIControlEventTouchUpInside];
        row.accessibilityLabel = action[@"title"];
        row.accessibilityValue = isPinned ? @"Pinned" : @"Not pinned";

        UIImageView *actionIcon = [[UIImageView alloc] initWithImage:zs_pin_symbol(action[@"symbol"], 14, UIFontWeightMedium)];
        actionIcon.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
        actionIcon.contentMode = UIViewContentModeCenter;
        actionIcon.frame = CGRectMake(12, 0, 24, kZSPinMenuRowHeight);
        actionIcon.userInteractionEnabled = NO;
        [row addSubview:actionIcon];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(44, 0, kZSPinMenuWidth - 44 - 48, kZSPinMenuRowHeight)];
        label.text = action[@"title"];
        label.textColor = [UIColor colorWithWhite:1 alpha:0.92];
        label.font = zs_mono_font(12, UIFontWeightRegular);
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.8;
        label.userInteractionEnabled = NO;
        [row addSubview:label];

        UIImageView *pinIcon = [[UIImageView alloc] initWithImage:zs_pin_symbol(isPinned ? @"pin.fill" : @"pin", 14, UIFontWeightMedium)];
        pinIcon.tintColor = isPinned ? zs_accent_green_color() : [UIColor colorWithWhite:1 alpha:0.7];
        pinIcon.contentMode = UIViewContentModeCenter;
        pinIcon.frame = CGRectMake(kZSPinMenuWidth - 44, 0, 32, kZSPinMenuRowHeight);
        pinIcon.tag = kZSPinMenuPinIconTag;
        pinIcon.userInteractionEnabled = NO;
        [row addSubview:pinIcon];

        [menuContent addSubview:row];
        rowY += kZSPinMenuRowHeight;
    }

    self.pinMenuScrim = scrim;
    self.pinMenuContent = menuContent;
    self.pinMenuOpen = YES;
    self.pinMenuTransitioning = YES;

    self.handle.clipsToBounds = YES;

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.46
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        handleElement.frame = expanded;
        if (glass) {
            zs_configure_glass_corners_flat_right(handleElement, kZSPinMenuCornerRadius);
        } else {
            weakSelf.handle.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
            weakSelf.handle.layer.cornerRadius = kZSPinMenuCornerRadius;
        }
        weakSelf.chevron.alpha = 0;
        [weakSelf zs_layoutPinnedTabsWithHandleY:expanded.origin.y localX:extra visible:YES];
    } completion:^(BOOL finished) {
        weakSelf.pinMenuTransitioning = NO;
    }];

    if (glass && self.panelGlass) {
        [UIView animateWithDuration:0.3
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            zs_configure_main_panel_glass_corners_split(weakSelf.panelGlass, kPanelCornerRadiusMinimum, NO, YES);
        } completion:nil];
    }

    [UIView animateWithDuration:0.24
                          delay:0.16
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        menuContent.alpha = 1;
    } completion:nil];
}

- (void)zs_pinMenuDismissTapped {
    [self zs_dismissPinMenuAnimated:YES delay:0 completion:nil];
}

- (void)zs_dismissPinMenuAnimated:(BOOL)animated delay:(NSTimeInterval)delay completion:(dispatch_block_t)completion {
    if (!self.pinMenuOpen) {
        if (completion) completion();
        return;
    }

    UIView *scrim = self.pinMenuScrim;
    UIView *menuContent = self.pinMenuContent;
    UIView *handleElement = self.handleGlass ?: self.handle;
    BOOL glass = zs_has_liquid_glass();
    CGFloat extra = self.pinMenuExtraWidth;
    CGRect collapsed = CGRectMake(extra, [self zs_handleRestingY], kHandleWidth, kHandleHeight);

    self.pinMenuOpen = NO;
    self.pinMenuScrim = nil;
    self.pinMenuContent = nil;
    self.pinMenuTransitioning = NO;

    __weak typeof(self) weakSelf = self;
    void (^applyCollapsedStyle)(void) = ^{
        if (glass) {
            zs_configure_glass_corners(handleElement, kHandleCornerRadius, NO);
        } else {
            weakSelf.handle.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
            weakSelf.handle.layer.cornerRadius = kHandleCornerRadius;
        }
    };

    void (^restorePanelCorner)(BOOL) = ^(BOOL withAnimation) {
        if (!glass || !weakSelf.panelGlass || weakSelf.docsPanelOpen || weakSelf.pinMenuOpen) return;
        void (^apply)(void) = ^{
            zs_configure_main_panel_glass_corners(weakSelf.panelGlass, kPanelCornerRadiusMinimum, YES);
        };
        if (!withAnimation) {
            [UIView performWithoutAnimation:apply];
            return;
        }
        [UIView animateWithDuration:0.3
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:apply
                         completion:nil];
    };

    void (^finish)(void) = ^{
        [UIView performWithoutAnimation:^{
            handleElement.frame = CGRectMake(extra, CGRectGetMinY(handleElement.frame) + (CGRectGetHeight(handleElement.frame) - kHandleHeight) * 0.5, kHandleWidth, kHandleHeight);
            [weakSelf zs_shiftPinContainerByExtraWidth:-extra];
            weakSelf.pinMenuExtraWidth = 0;
            weakSelf.handle.clipsToBounds = NO;
            weakSelf.chevron.alpha = 1;
            [menuContent removeFromSuperview];
        }];
        [scrim removeFromSuperview];
        if (completion) completion();
    };

    if (!animated) {
        [UIView performWithoutAnimation:^{
            handleElement.frame = collapsed;
            applyCollapsedStyle();
            [weakSelf zs_layoutPinnedTabsWithHandleY:collapsed.origin.y localX:extra visible:YES];
        }];
        finish();
        restorePanelCorner(NO);
        if (weakSelf.pinRecenterPending) {
            weakSelf.pinRecenterPending = NO;
            weakSelf.pinRecenterToken = weakSelf.pinRecenterToken + 1;
            weakSelf.pinClusterOffsetY = [weakSelf zs_centeredClusterOffset];
            [UIView performWithoutAnimation:^{
                [weakSelf zs_applyPinClusterLayout];
            }];
        }
        return;
    }

    [self zs_schedulePinClusterRecenter];
    scrim.userInteractionEnabled = NO;

    [UIView animateWithDuration:0.14
                          delay:delay
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        menuContent.alpha = 0;
    } completion:nil];

    [UIView animateWithDuration:0.4
                          delay:delay
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        handleElement.frame = collapsed;
        applyCollapsedStyle();
        weakSelf.chevron.alpha = 1;
        [weakSelf zs_layoutPinnedTabsWithHandleY:collapsed.origin.y localX:extra visible:YES];
    } completion:^(BOOL finished) {
        finish();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            restorePanelCorner(YES);
        });
    }];
}

- (void)zs_pinMenuRowTapped:(UIButton *)sender {
    NSString *key = objc_getAssociatedObject(sender, "zs_pinKey");
    if (!key) return;

    BOOL alreadyPinned = [[self zs_pinnedKeys] containsObject:key];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    if (alreadyPinned) {
        [self zs_removePinnedKey:key delay:0];
    } else {
        [self zs_addPinnedKey:key delay:0];
    }

    BOOL nowPinned = !alreadyPinned;
    sender.accessibilityValue = nowPinned ? @"Pinned" : @"Not pinned";
    UIImageView *pinIcon = (UIImageView *)[sender viewWithTag:kZSPinMenuPinIconTag];
    if ([pinIcon isKindOfClass:[UIImageView class]]) {
        pinIcon.image = zs_pin_symbol(nowPinned ? @"pin.fill" : @"pin", 14, UIFontWeightMedium);
        pinIcon.tintColor = nowPinned ? zs_accent_green_color() : [UIColor colorWithWhite:1 alpha:0.7];
    }
}

#pragma mark Pull tab

- (void)layoutPanelForWindow:(UIView *)unityView {
    if (!self.glassContainer || !self.panel || !self.handle) return;

    [self positionPanelAnimated:NO];

    if (self.contentOverlay) {
        [self.contentOverlay setNeedsLayout];
        [self.contentOverlay layoutIfNeeded];
    }

    if (self.extendedContentClip) {
        [unityView bringSubviewToFront:self.extendedContentClip];
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
    if (scrollView == self.memoryFullScreenScrollView) {
        CGFloat width = scrollView.bounds.size.width;
        UIPageControl *pageControl = self.memoryPageControl;
        if (width > 1 && pageControl) {
            NSInteger page = (NSInteger)llround(scrollView.contentOffset.x / width);
            page = MAX(0, MIN(page, (NSInteger)pageControl.numberOfPages - 1));
            if (pageControl.currentPage != page) pageControl.currentPage = page;
        }
        [self zs_updateMemoryHeaderPieAlpha];
        return;
    }
    [self zs_fillVisiblePanelSectionsWithHeadroom];
    [self zs_updateSliderGlassVisibility];
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

    if (!self.panelOpen || self.extendedCoverMode) {
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
    [self zs_refreshMetalTabs];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf zs_refreshMetalTabs];
    });
    [self zs_dismissPinMenuAnimated:NO delay:0 completion:nil];
    [self zs_layoutTutorialForWindow:unityView];
    [self zs_layoutCrashReportForWindow:unityView];
    if (!self.panel) return;
    [self layoutPanelForWindow:unityView];
}

- (void)positionPanelAnimated:(BOOL)animated {
    UIView *unityView = zs_ui_host_view();
    if (!unityView || !self.glassContainer) return;

    CGFloat panelW = self.panelWidth > 0 ? self.panelWidth : kPanelWidth;
    BOOL docsVisible = self.docsPanelOpen && self.docsPanel != nil;
    BOOL fullScreenOpen = self.syslogFullScreenOpen || self.memoryFullScreenOpen || self.assetExplorerFullScreenOpen;
    BOOL fullScreenChanged = fullScreenOpen != self.panelFullScreenLayoutActive;
    self.panelFullScreenLayoutActive = fullScreenOpen;
    BOOL leftCornersFlatChanged = docsVisible != self.panelLeftCornersFlat;
    self.panelLeftCornersFlat = docsVisible;
    BOOL coverActive = self.extendedCoverMode && fullScreenOpen && docsVisible;
    CGFloat docsW = 0;
    if (docsVisible) {
        if (coverActive) {
            docsW = unityView.bounds.size.width - kHandleWidth;
        } else {
            docsW = fullScreenOpen
                ? (unityView.bounds.size.width - kHandleWidth - panelW)
                : (self.docsPanelWidth > 0 ? self.docsPanelWidth : panelW);
        }
    }
    CGFloat chromeWidth = coverActive ? unityView.bounds.size.width : (kHandleWidth + docsW + panelW);
    CGFloat height = unityView.bounds.size.height;

    CGFloat targetX = unityView.bounds.size.width - chromeWidth;

    UIView *panelElement = self.panelGlass ?: self.panel;
    UIView *handleElement = self.handleGlass ?: self.handle;
    UIView *clip = self.extendedContentClip;
    BOOL glass = zs_has_liquid_glass();
    CGFloat docsX = fullScreenOpen ? 0 : kHandleWidth;

    // Liquid Glass: one glass surface. The main panel itself expands leftwards over the extended window,
    // instead of a second glass surface being built and slid over.
    BOOL expandPanel = [self zs_expandsMainPanel];
    UIView *docsPanelElement = expandPanel ? nil : (self.docsPanelGlass ?: self.docsPanel);
    BOOL pullTabsHidden = [self zs_pullTabsHiddenForFullScreen:fullScreenOpen];

    // Column (container-local) holding the regular main panel content.
    CGRect mainColumnLocal = CGRectMake(kHandleWidth + docsW, 0, panelW, height);
    // Left edge of the main panel glass. Expanded: it reaches back to where the extended window starts.
    CGFloat panelGlassLeft = (expandPanel && docsVisible) ? docsX : mainColumnLocal.origin.x;
    CGRect panelFrameLocal = expandPanel
        ? CGRectMake(panelGlassLeft, 0, chromeWidth - panelGlassLeft, height)
        : mainColumnLocal;

    CGFloat docsSpanWidth = docsW + (fullScreenOpen ? kHandleWidth : 0);
    CGFloat docsLeftRadius = fullScreenOpen ? zs_screen_corner_radius(unityView, kPanelCornerRadiusMinimum) : kPanelCornerRadiusMinimum;
    CACornerMask docsCornerMask = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    CACornerMask contentOverlayCornerMask = docsVisible
        ? (kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner)
        : (kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner);

    if (self.pinMenuOpen) {
        [self zs_dismissPinMenuAnimated:NO delay:0 completion:nil];
    }

    if (docsVisible && clip) {
        [UIView performWithoutAnimation:^{
            [clip.layer removeAnimationForKey:@"opacity"];
            clip.alpha = 1;
            clip.hidden = NO;

            CGRect overlayFrame = CGRectMake(0, 0, docsSpanWidth, height);
            void (^prepareOverlay)(UIView *, BOOL) = ^(UIView *overlay, BOOL visible) {
                if (!overlay) return;
                overlay.transform = CGAffineTransformIdentity;
                overlay.alpha = 1;
                overlay.frame = overlayFrame;
                overlay.hidden = !visible;
                if (visible) [overlay layoutIfNeeded];
            };
            prepareOverlay(self.docsContentOverlay, !fullScreenOpen);
            prepareOverlay(self.syslogFullScreenOverlay, self.syslogFullScreenOpen);
            prepareOverlay(self.memoryFullScreenOverlay, self.memoryFullScreenOpen);
            prepareOverlay(self.assetExplorerFullScreenOverlay, self.assetExplorerFullScreenOpen);
        }];
    }

    void (^configurePanelCornersOn)(UIView *) = ^(UIView *target) {
        if (!target) return;
        if (expandPanel) {
            if (docsVisible && zs_flatten_main_panel_left_corners_when_extended()) {
                zs_configure_main_panel_glass_corners(target, kPanelCornerRadiusMinimum, NO);
            } else {
                // The expanded panel's left edge is the extended window's left edge.
                zs_configure_main_panel_glass_corners_expanding(target,
                                                                docsVisible ? docsLeftRadius : kPanelCornerRadiusMinimum,
                                                                docsVisible ? !fullScreenOpen : YES,
                                                                kPanelCornerRadiusMinimum);
            }
        } else {
            zs_configure_main_panel_glass_corners(target, kPanelCornerRadiusMinimum, !docsVisible);
        }
    };

    void (^applyPanelCorners)(void) = ^{
        if (self.panelGlass) {
            configurePanelCornersOn(self.panelGlass);
            configurePanelCornersOn(self.panelBlurOverlay);
        }
        if (self.contentOverlay) {
            self.contentOverlay.layer.maskedCorners = contentOverlayCornerMask;
        }
    };

    void (^applyIconAlpha)(void) = ^{
        CGFloat alpha = pullTabsHidden ? 0 : 1;
        self.chevron.alpha = alpha;
        for (UIView *tab in self.pinnedTabElements.allValues) {
            [tab viewWithTag:kZSPinnedIconTag].alpha = alpha;
        }
    };

    static const NSTimeInterval kCornerAnimationDuration = 0.3;
    static const NSTimeInterval kCornerRestoreDelay = 0.1;

    void (^animatePanelCorners)(void) = ^{
        [UIView animateWithDuration:kCornerAnimationDuration
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:applyPanelCorners
                         completion:nil];
    };

    void (^changes)(void) = ^{
        CGRect dockFrame = CGRectMake(targetX, 0, chromeWidth, height);
        self.glassContainer.frame = dockFrame;

        // Pull tabs follow the left edge of the main panel. When it is fully extended that is x < 0 (off-screen):
        // the panel's expanded bounds deliberately do not clamp the tabs. The old behaviour (tucked behind the
        // main column and hidden) is kept behind zs_pull_tabs_tuck_into_panel_when_extended().
        CGFloat handleLocalX = (expandPanel && !zs_pull_tabs_tuck_into_panel_when_extended())
            ? (panelGlassLeft - kHandleWidth)
            : (fullScreenOpen ? (kHandleWidth + docsW) : 0);
        CGFloat handleRestingY = (height - kHandleHeight) * 0.5 + self.pinClusterOffsetY;
        handleElement.frame = CGRectMake(handleLocalX,
                                          handleRestingY,
                                          kHandleWidth,
                                          kHandleHeight);
        handleElement.userInteractionEnabled = !pullTabsHidden;
        [self zs_layoutPinnedTabsWithHandleY:handleRestingY localX:handleLocalX visible:!pullTabsHidden updateIcons:NO];

        CGRect docsFrameLocal = CGRectMake(docsX, 0, docsSpanWidth, height);

        if (docsPanelElement) {
            docsPanelElement.frame = docsFrameLocal;
            if (glass) {
                zs_configure_glass_corners_sides(self.docsPanelGlass, docsLeftRadius, !fullScreenOpen, YES, NO);
            } else {
                docsPanelElement.clipsToBounds = YES;
                docsPanelElement.layer.cornerRadius = docsLeftRadius;
                docsPanelElement.layer.cornerCurve = kCACornerCurveContinuous;
                docsPanelElement.layer.maskedCorners = docsCornerMask;
            }
        }

        panelElement.frame = panelFrameLocal;
        if (expandPanel && self.panelBlurOverlay) self.panelBlurOverlay.frame = panelFrameLocal;
        if (expandPanel) applyPanelCorners();

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
            self.contentOverlay.frame = [self.glassContainerContent convertRect:mainColumnLocal toView:unityView];
            self.contentOverlay.layer.cornerRadius = kPanelCornerRadiusMinimum;
            self.contentOverlay.layer.cornerCurve = kCACornerCurveContinuous;
        }
        if (clip && self.docsPanel) {
            clip.frame = [self.glassContainerContent convertRect:docsFrameLocal toView:unityView];
            clip.layer.cornerRadius = docsLeftRadius;
            clip.layer.cornerCurve = kCACornerCurveContinuous;
            clip.layer.maskedCorners = docsCornerMask;
        }

        [self zs_updateSliderGlassVisibility];
    };

    void (^completion)(BOOL) = ^(BOOL finished) {
        if (self.docsPanelOpen) return;
        [self zs_finishExtendedPanelClose];
        if (leftCornersFlatChanged && !expandPanel && !docsVisible && animated) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCornerRestoreDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.docsPanelOpen) return;
                animatePanelCorners();
            });
        }
    };

    UIView *separator = self.docsPanelSeparator;
    if (separator) {
        static const NSTimeInterval kSeparatorFadeInDuration = 0.25;
        static const NSTimeInterval kSeparatorFadeOutDuration = 0.16;
        if (docsVisible && !coverActive) {
            BOOL needsFadeIn = separator.hidden || separator.alpha < 1;
            if (separator.hidden) {
                [separator.layer removeAllAnimations];
                separator.alpha = 0;
                separator.hidden = NO;
            }
            if (needsFadeIn) {
                if (animated) {
                    [UIView animateWithDuration:kSeparatorFadeInDuration
                                          delay:0
                                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                                     animations:^{
                        separator.alpha = 1;
                    } completion:nil];
                } else {
                    [separator.layer removeAllAnimations];
                    separator.alpha = 1;
                }
            }
        } else if (!separator.hidden) {
            if (animated) {
                [UIView animateWithDuration:kSeparatorFadeOutDuration
                                      delay:0
                                    options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseIn
                                 animations:^{
                    separator.alpha = 0;
                } completion:^(BOOL finished) {
                    if (!self.docsPanelOpen && separator.alpha == 0) separator.hidden = YES;
                }];
            } else {
                [separator.layer removeAllAnimations];
                separator.alpha = 0;
                separator.hidden = YES;
            }
        }
    }

    NSTimeInterval mainDuration = fullScreenChanged ? kZSFullScreenPanelDuration : 0.28;

    // Extended window opening / closing: cross-fade the panel glass <-> blur partway through the animation.
    if (animated && expandPanel && leftCornersFlatChanged) {
        [self zs_scheduleBlurSwapActive:docsVisible mainDuration:mainDuration];
    }

    if (leftCornersFlatChanged && !expandPanel) {
        if (!animated) {
            applyPanelCorners();
        } else if (docsVisible) {
            animatePanelCorners();
        }
    }

    if (!animated) {
        changes();
        applyIconAlpha();
        completion(YES);
    } else {
        if (fullScreenChanged) {
            UICubicTimingParameters *timing = [[UICubicTimingParameters alloc] initWithControlPoint1:CGPointMake(0.16, 1.0)
                                                                                       controlPoint2:CGPointMake(0.3, 1.0)];
            UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:mainDuration
                                                                                timingParameters:timing];
            [animator addAnimations:changes];
            [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
                completion(finalPosition == UIViewAnimatingPositionEnd);
            }];
            [animator startAnimation];
        } else {
            [UIView animateWithDuration:mainDuration
                                  delay:0
                 usingSpringWithDamping:docsVisible ? 0.85 : 1.0
                  initialSpringVelocity:docsVisible ? 0.3 : 0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:changes
                             completion:completion];
        }

        [UIView animateWithDuration:kZSPullTabIconFadeDuration
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                         animations:applyIconAlpha
                         completion:nil];
    }

    [self startPostFXReapply];
}

- (void)zs_finishExtendedPanelClose {
    UIView *clip = self.extendedContentClip;
    if (!clip || clip.hidden || self.docsPanelOpen) return;

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:kZSExtendedContentFadeDuration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        clip.alpha = 0;
    } completion:^(BOOL finished) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !finished) return;
        if (strongSelf.docsPanelOpen || strongSelf.extendedContentClip != clip) return;
        [strongSelf zs_tearDownExtendedPanelContents];
    }];
}

- (void)zs_tearDownExtendedPanelContents {
    UIView *clip = self.extendedContentClip;
    if (!clip) return;

    clip.hidden = YES;
    clip.alpha = 1;
    self.docsContentOverlay.hidden = YES;
    self.syslogFullScreenOverlay.hidden = YES;
    self.memoryFullScreenOverlay.hidden = YES;
    self.assetExplorerFullScreenOverlay.hidden = YES;
    for (UIView *overlay in @[self.syslogFullScreenOverlay ?: [NSNull null], self.memoryFullScreenOverlay ?: [NSNull null], self.assetExplorerFullScreenOverlay ?: [NSNull null]]) {
        if (![overlay isKindOfClass:[UIView class]]) continue;
        overlay.transform = CGAffineTransformIdentity;
        overlay.alpha = 1;
    }

    self.syslogTableController.lines = @[];
    self.syslogTableController.atBottom = YES;
    self.syslogRenderDeferred = NO;
    [self.syslogTableView reloadData];
    self.syslogTableView.contentOffset = CGPointZero;

    [self.memoryFullScreenContentView removeFromSuperview];
    self.memoryFullScreenContentView = nil;
    self.memoryFullScreenScrollView.contentOffset = CGPointZero;
    self.memoryFullScreenStatusLabel.text = @"Scanning…";
    self.assetExplorerGeneration += 1;
    self.assetExplorerBundles = @[];
    self.assetExplorerAssets = @[];
    self.assetExplorerDisplayedBundles = @[];
    self.assetExplorerDisplayedAssets = @[];
    self.assetExplorerStatusMessage = nil;
    self.assetExplorerSelectedBundle = nil;
    [self zs_assetExplorerSetTextureModeVisible:NO];
}

#pragma mark Slider/switch/mode-slider actions

void zs_update_value_label(ZSCapsuleSlider *slider) {
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

- (void)fullManifestZeroingChanged:(UISwitch *)toggle {
    [PatchManifestNetwork setFullZeroingEnabled:toggle.on];
    [self zs_refreshManifestZeroingRow];
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

#pragma mark Panel glass <-> blur cross-fade (TEMPORARY tunables)

- (void)zs_scheduleBlurSwapActive:(BOOL)active mainDuration:(NSTimeInterval)mainDuration {
    ZSPanelBlurConfig cfg = zs_panel_blur_config();
    if (!self.panelBlurOverlay) return;
    NSUInteger token = ++self.panelBlurToken;
    if (!cfg.enabled) {
        if (self.panelBlurActive) [self zs_setPanelBlurActive:NO animated:YES];
        return;
    }

    NSTimeInterval delay = mainDuration * MAX(0, MIN(1, active ? cfg.openAt : cfg.closeAt));
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || token != strongSelf.panelBlurToken || !strongSelf.panelBlurOverlay) return;
        if (strongSelf.docsPanelOpen != active) return;
        [strongSelf zs_setPanelBlurActive:active animated:YES];
    });
}

- (void)zs_rebuildPanelBlurAnimator {
    UIVisualEffectView *overlay = self.panelBlurOverlay;
    if (!overlay) return;
    ZSPanelBlurConfig cfg = zs_panel_blur_config();

    UIViewPropertyAnimator *old = self.panelBlurAnimator;
    self.panelBlurAnimator = nil;
    if (old && old.state == UIViewAnimatingStateActive) [old stopAnimation:YES];
    overlay.effect = nil;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:zs_panel_blur_style_at(cfg.style)];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:1
                                                                                   curve:UIViewAnimationCurveLinear
                                                                              animations:^{ overlay.effect = blur; }];
    animator.pausesOnCompletion = YES;
    self.panelBlurAnimator = animator;
    [self zs_applyPanelBlurProgress:self.panelBlurProgress];
}

// progress 0 = fully glass, 1 = fully blur. Intensity scales the blur radius, tint scales the dark overlay.
- (void)zs_applyPanelBlurProgress:(CGFloat)progress {
    UIVisualEffectView *overlay = self.panelBlurOverlay;
    if (!overlay) return;
    ZSPanelBlurConfig cfg = zs_panel_blur_config();
    progress = MAX(0, MIN(1, progress));
    self.panelBlurProgress = progress;
    if (self.panelBlurAnimator) {
        self.panelBlurAnimator.fractionComplete = MAX(0, MIN(1, cfg.intensity * progress));
    }
    overlay.contentView.backgroundColor = [UIColor colorWithWhite:0 alpha:cfg.tint * progress];
}

- (void)zs_finishPanelBlurIfInactive {
    if (self.panelBlurActive || self.panelBlurProgress > 0.001) return;
    UIViewPropertyAnimator *animator = self.panelBlurAnimator;
    self.panelBlurAnimator = nil;
    if (animator && animator.state == UIViewAnimatingStateActive) [animator stopAnimation:YES];
    self.panelBlurOverlay.effect = nil;
    self.panelBlurOverlay.contentView.backgroundColor = UIColor.clearColor;
    self.panelBlurOverlay.hidden = YES;
}

- (void)zs_setPanelBlurActive:(BOOL)active animated:(BOOL)animated {
    UIVisualEffectView *overlay = self.panelBlurOverlay;
    UIVisualEffectView *glassView = self.panelGlass;
    if (!overlay || !glassView) return;
    if (active == self.panelBlurActive && !self.panelBlurLink) return;
    self.panelBlurActive = active;

    ZSPanelBlurConfig cfg = zs_panel_blur_config();
    NSTimeInterval duration = animated ? cfg.fade : 0;

    if (active) overlay.hidden = NO;
    if (!self.panelBlurAnimator) [self zs_rebuildPanelBlurAnimator];

    // Glass side: dematerialize / materialize through the effect (the supported way to animate glass).
    UIVisualEffect *glassTarget = active ? nil : zs_make_glass_effect_dark(NO);
    [self.panelBlurLink invalidate];
    self.panelBlurLink = nil;

    if (duration <= 0.001) {
        [UIView performWithoutAnimation:^{ glassView.effect = glassTarget; }];
        [self zs_applyPanelBlurProgress:active ? 1 : 0];
        [self zs_finishPanelBlurIfInactive];
        return;
    }

    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut
                     animations:^{ glassView.effect = glassTarget; }
                     completion:nil];

    // Blur side: driven by a display link so intensity and tint can be tuned independently.
    self.panelBlurFrom = self.panelBlurProgress;
    self.panelBlurTo = active ? 1 : 0;
    self.panelBlurStartTime = CACurrentMediaTime();
    self.panelBlurDuration = duration;
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_panelBlurTick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.panelBlurLink = link;
}

- (void)zs_panelBlurTick:(CADisplayLink *)link {
    CGFloat t = self.panelBlurDuration > 0 ? (CGFloat)((CACurrentMediaTime() - self.panelBlurStartTime) / self.panelBlurDuration) : 1;
    t = MAX(0, MIN(1, t));
    CGFloat eased = t * t * (3 - 2 * t);
    [self zs_applyPanelBlurProgress:self.panelBlurFrom + (self.panelBlurTo - self.panelBlurFrom) * eased];
    if (t >= 1) {
        [link invalidate];
        if (self.panelBlurLink == link) self.panelBlurLink = nil;
        [self zs_finishPanelBlurIfInactive];
    }
}

- (void)zs_teardownPanelBlur {
    self.panelBlurToken = self.panelBlurToken + 1;
    [self.panelBlurLink invalidate];
    self.panelBlurLink = nil;
    UIViewPropertyAnimator *animator = self.panelBlurAnimator;
    self.panelBlurAnimator = nil;
    if (animator && animator.state == UIViewAnimatingStateActive) [animator stopAnimation:YES];
    [self.panelBlurOverlay removeFromSuperview];
    self.panelBlurOverlay = nil;
    self.panelBlurActive = NO;
    self.panelBlurProgress = 0;
}

- (void)zs_refreshPanelBlurAppearance {
    if (self.panelBlurAnimator || self.panelBlurActive) [self zs_rebuildPanelBlurAnimator];
}

- (void)zs_blurEnabledChanged:(UISwitch *)toggle {
    zs_panel_blur_set(@"enabled", toggle.on ? 1 : 0);
    if (!toggle.on && self.panelBlurActive) [self zs_setPanelBlurActive:NO animated:YES];
}

- (void)zs_blurStyleChanged:(ZSWheelPicker *)picker {
    zs_panel_blur_set(@"style", (double)picker.selectedIndex);
    [self zs_refreshPanelBlurAppearance];
}

- (void)zs_blurIntensityChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    zs_panel_blur_set(@"intensity", slider.value);
    [self zs_refreshPanelBlurAppearance];
}

- (void)zs_blurTintChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    zs_panel_blur_set(@"tint", slider.value);
    [self zs_applyPanelBlurProgress:self.panelBlurProgress];
}

- (void)zs_blurFadeChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    zs_panel_blur_set(@"fade", slider.value);
}

- (void)zs_blurOpenAtChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    zs_panel_blur_set(@"openAt", slider.value);
}

- (void)zs_blurCloseAtChanged:(ZSCapsuleSlider *)slider {
    zs_update_value_label(slider);
    zs_panel_blur_set(@"closeAt", slider.value);
}

- (void)zs_blurPreviewTapped {
    [self zs_setPanelBlurActive:!self.panelBlurActive animated:YES];
}

- (void)disableEnkephalinChanged:(UISwitch *)toggle {
    zs_set_enkephalin_disabled_by_user(toggle.on);
    zs_gif_tint_set_disabled(toggle.on);
}

- (void)ramBypassChanged:(UISwitch *)toggle {
    zs_set_donated_heap_enabled(toggle.on);
    UIViewController *presenter = zs_key_window().rootViewController;
    if (presenter) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart Required"
                                                                         message:@"You must restart the app for RamBypass to take effect."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        zs_add_restart_action(alert);
        [presenter presentViewController:alert animated:YES completion:nil];
    }
}

- (void)ramHudChanged:(UISwitch *)toggle {
    zs_set_ram_hud_enabled(toggle.on);
    [[ZSMetalTabs shared] setRamHudVisible:toggle.on];
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

@end
