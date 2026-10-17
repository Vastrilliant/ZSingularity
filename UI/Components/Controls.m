#import "UIInternal.h"

#pragma mark - Capsule slider (Control Center / Now Playing style)

static const CGFloat kCapsuleSliderHeight = 18;
static const CGFloat kCapsuleSliderThinHeight = 6;
static const CGFloat kCapsuleSliderFatHeight = 18;
static const NSTimeInterval kCapsuleSliderHoldDuration = 0.08;
static const CGFloat kCapsuleSliderHoldSlop = 6;
static const CGFloat kDefaultSnapFraction = 0.035;

static BOOL zs_pan_should_begin_horizontally(UIGestureRecognizer *gesture, UIView *view) {
    if (![gesture isKindOfClass:[UIPanGestureRecognizer class]]) return YES;
    CGPoint translation = [(UIPanGestureRecognizer *)gesture translationInView:view];
    return fabs(translation.x) >= fabs(translation.y);
}

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

#pragma mark - Pillar chart

static const NSInteger kZSPillarSegmentCount = 120;
static const CGFloat kZSPillarSegmentGap = 2.0;

@implementation ZSPillarChartView {
    NSArray<NSNumber *> *_fractions;
    NSArray<UIColor *> *_colors;
    NSMutableArray<CAShapeLayer *> *_segmentLayers;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _segmentLayers = [NSMutableArray new];
        self.backgroundColor = UIColor.clearColor;
    }
    return self;
}

- (void)setSegmentsWithFractions:(NSArray<NSNumber *> *)fractions colors:(NSArray<UIColor *> *)colors {
    _fractions = [fractions copy];
    _colors = [colors copy];
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self zs_rebuildSegmentLayers];
}

- (NSArray<NSNumber *> *)zs_segmentCountsForFractions:(NSArray<NSNumber *> *)fractions total:(NSInteger)total {
    NSInteger n = fractions.count;
    if (n == 0 || total <= 0) return @[];

    NSMutableArray<NSNumber *> *counts = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSNumber *> *remainders = [NSMutableArray arrayWithCapacity:n];
    NSInteger assigned = 0;

    for (NSNumber *fractionNum in fractions) {
        double fraction = fractionNum.doubleValue;
        double raw = fraction * (double)total;
        NSInteger base = (NSInteger)floor(raw);
        if (base < 1 && fraction > 0.0) base = 1;
        [counts addObject:@(base)];
        [remainders addObject:@(raw - floor(raw))];
        assigned += base;
    }

    NSInteger overflow = assigned - total;
    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:n];
    for (NSInteger i = 0; i < n; i++) [order addObject:@(i)];

    if (overflow > 0) {
        [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            double ra = remainders[a.integerValue].doubleValue;
            double rb = remainders[b.integerValue].doubleValue;
            return ra < rb ? NSOrderedAscending : (ra > rb ? NSOrderedDescending : NSOrderedSame);
        }];
        for (NSNumber *idxNum in order) {
            if (overflow <= 0) break;
            NSInteger idx = idxNum.integerValue;
            NSInteger c = counts[idx].integerValue;
            if (c > 1) {
                counts[idx] = @(c - 1);
                overflow--;
            }
        }
    } else if (overflow < 0) {
        [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            double ra = remainders[a.integerValue].doubleValue;
            double rb = remainders[b.integerValue].doubleValue;
            return ra > rb ? NSOrderedAscending : (ra < rb ? NSOrderedDescending : NSOrderedSame);
        }];
        NSInteger remaining = -overflow;
        NSInteger orderIdx = 0;
        while (remaining > 0 && order.count > 0) {
            NSInteger idx = order[orderIdx % order.count].integerValue;
            counts[idx] = @(counts[idx].integerValue + 1);
            remaining--;
            orderIdx++;
        }
    }

    return counts;
}

- (void)zs_rebuildSegmentLayers {
    for (CAShapeLayer *layer in _segmentLayers) {
        [layer removeFromSuperlayer];
    }
    [_segmentLayers removeAllObjects];

    if (_fractions.count == 0 || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;

    NSInteger targetSegmentCount = (NSInteger)floor((self.bounds.size.height + kZSPillarSegmentGap) / 5.0);
    NSInteger totalSegments = MAX(24, MIN((NSInteger)kZSPillarSegmentCount, targetSegmentCount));
    NSArray<NSNumber *> *segmentCounts = [self zs_segmentCountsForFractions:_fractions total:totalSegments];

    NSMutableArray<UIColor *> *segmentColors = [NSMutableArray new];
    for (NSUInteger i = 0; i < segmentCounts.count; i++) {
        UIColor *color = (i < _colors.count) ? _colors[i] : UIColor.grayColor;
        NSInteger count = segmentCounts[i].integerValue;
        for (NSInteger s = 0; s < count; s++) {
            [segmentColors addObject:color];
        }
    }

    NSInteger renderedCount = segmentColors.count;
    if (renderedCount == 0) return;

    CGFloat width = self.bounds.size.width;
    CGFloat totalGap = kZSPillarSegmentGap * (renderedCount - 1);
    CGFloat segmentHeight = (self.bounds.size.height - totalGap) / (CGFloat)renderedCount;
    if (segmentHeight <= 0) return;

    CGFloat y = 0;
    for (NSInteger i = 0; i < renderedCount; i++) {
        CGRect rect = CGRectMake(0, y, width, segmentHeight);
        CAShapeLayer *segment = [CAShapeLayer new];
        segment.path = [UIBezierPath bezierPathWithRect:rect].CGPath;
        segment.fillColor = segmentColors[i].CGColor;
        [self.layer addSublayer:segment];
        [_segmentLayers addObject:segment];

        y += segmentHeight + kZSPillarSegmentGap;
    }
}

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

        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        hold.minimumPressDuration = kCapsuleSliderHoldDuration;
        hold.allowableMovement = kCapsuleSliderHoldSlop;
        hold.numberOfTouchesRequired = 1;
        [self addGestureRecognizer:hold];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (UIScrollView *)zs_enclosingScrollView {
    UIView *candidate = self.superview;
    while (candidate && ![candidate isKindOfClass:[UIScrollView class]]) candidate = candidate.superview;
    return (UIScrollView *)candidate;
}

- (void)zs_lockEnclosingScrollView {
    if (self.lockedScrollView) return;
    UIScrollView *scrollView = [self zs_enclosingScrollView];
    if (!scrollView || !scrollView.scrollEnabled) return;
    self.lockedScrollView = scrollView;
    scrollView.scrollEnabled = NO;
}

- (void)zs_unlockEnclosingScrollView {
    UIScrollView *scrollView = self.lockedScrollView;
    self.lockedScrollView = nil;
    if (scrollView) scrollView.scrollEnabled = YES;
}

- (void)dealloc {
    [self zs_unlockEnclosingScrollView];
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
        [(self.superview ?: self) layoutIfNeeded];
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

- (void)handlePress:(UIGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:self];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.panActive = YES;
            CGFloat range = self.maximumValue - self.minimumValue;
            CGFloat startFraction = range > 0 ? (self.value - self.minimumValue) / range : 0;
            self.holdAnchorTouchX = location.x;
            self.holdAnchorValueX = MAX(0, MIN(1, startFraction)) * self.bounds.size.width;
            self.liveDragValue = self.value;
            [self zs_lockEnclosingScrollView];
            [self setPillTouching:YES];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGFloat shiftedX = self.holdAnchorValueX + (location.x - self.holdAnchorTouchX);
            [self setValueFromLocation:CGPointMake(shiftedX, location.y) sendActions:YES];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.panActive = NO;
            [self zs_unlockEnclosingScrollView];
            [self setPillTouching:NO];
            break;
        default:
            break;
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint location = [gesture locationInView:self];
    [self setPillTouching:YES];
    [self setValueFromLocation:location sendActions:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && !strongSelf.panActive) [strongSelf setPillTouching:NO];
    });
}

@end

#pragma mark - Mode slider (segmented, preset-value control)

@implementation ZSModeSlider

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _selectedIndex = 0;
        _defaultIndex = -1;
        _fillColor = zs_bar_fill_color();
        _gifTintEnabled = YES;
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

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        pan.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![super gestureRecognizerShouldBegin:gestureRecognizer]) return NO;
    return zs_pan_should_begin_horizontally(gestureRecognizer, self);
}

- (void)dealloc {
    zs_remove_gif_view_tint(self.thumb);
}

- (void)setGifTintEnabled:(BOOL)gifTintEnabled {
    if (_gifTintEnabled == gifTintEnabled) return;
    _gifTintEnabled = gifTintEnabled;
    if (gifTintEnabled) {
        self.thumb.backgroundColor = [self.fillColor colorWithAlphaComponent:1.0];
        zs_apply_gif_view_tint(self.thumb);
    } else {
        zs_remove_gif_view_tint(self.thumb);
        self.thumb.backgroundColor = zs_accent_green_color();
    }
    [self setNeedsLayout];
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

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    [self selectIndexForLocation:[gesture locationInView:self] sendActions:YES];
}

- (void)handlePress:(UIGestureRecognizer *)gesture {
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

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![super gestureRecognizerShouldBegin:gestureRecognizer]) return NO;
    return zs_pan_should_begin_horizontally(gestureRecognizer, self);
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

@implementation ZSDeadZoneScrollView {
    BOOL _deadZoneArmed;
    CGFloat _deadZoneStartX;
}

- (void)setContentOffset:(CGPoint)contentOffset {
    UIGestureRecognizerState state = self.panGestureRecognizer.state;
    if (state == UIGestureRecognizerStateBegan) {
        _deadZoneArmed = YES;
        _deadZoneStartX = self.contentOffset.x;
    } else if (state != UIGestureRecognizerStateChanged) {
        _deadZoneArmed = NO;
    }
    if (_deadZoneArmed) {
        CGFloat minX = -self.contentInset.left;
        CGFloat maxX = MAX(self.contentSize.width - self.bounds.size.width + self.contentInset.right, minX);
        contentOffset.x = MIN(MAX(contentOffset.x, minX), maxX);
        if (self.panGestureRecognizer.numberOfTouches > 1) {
            contentOffset.x = self.contentOffset.x;
        } else if (fabs(contentOffset.x - _deadZoneStartX) < self.deadZone) {
            contentOffset.x = _deadZoneStartX;
        }
    }
    [super setContentOffset:contentOffset];
}

@end

@implementation ZSPanelScrollView

- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit && hit != self && self.isDecelerating && !self.isDragging) return self;
    return hit;
}

@end

static const CGFloat kZSSectionIndexRowHeight = 12;
static const CGFloat kZSSectionIndexVerticalPadding = 4;
static const CGFloat kZSSectionIndexBaseFontSize = 8;
static const CGFloat kZSSectionIndexPeakGrowth = 0.65;
static const CGFloat kZSSectionIndexFalloff = 0.9;
static const CGFloat kZSSectionIndexLabelInset = 4;
static const CGFloat kZSSectionIndexFullTitleScale = 1.35;
static const CGFloat kZSSectionIndexShadowMargin = 22;

@implementation ZSSectionIndexView {
    NSArray<NSString *> *_titles;
    NSArray<NSString *> *_fullTitles;
    NSMutableArray<UILabel *> *_labels;
    CAGradientLayer *_shadow;
    NSInteger _activeIndex;
    NSInteger _focusIndex;
    CGFloat _touchP;
    CGFloat _progress;
    CGFloat _target;
    CADisplayLink *_link;
    CFTimeInterval _lastTimestamp;
    UISelectionFeedbackGenerator *_haptic;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _titles = @[];
    _fullTitles = @[];
    _labels = [NSMutableArray array];
    _activeIndex = -1;
    _focusIndex = -1;
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = NO;
    _shadow = [CAGradientLayer layer];
    _shadow.type = kCAGradientLayerRadial;
    _shadow.colors = @[
        (id)[UIColor colorWithWhite:0 alpha:0.62].CGColor,
        (id)[UIColor colorWithWhite:0 alpha:0.34].CGColor,
        (id)[UIColor colorWithWhite:0 alpha:0.0].CGColor,
    ];
    _shadow.locations = @[@0.0, @0.5, @1.0];
    _shadow.startPoint = CGPointMake(0.5, 0.5);
    _shadow.endPoint = CGPointMake(1.0, 1.0);
    _shadow.opacity = 0;
    [self.layer insertSublayer:_shadow atIndex:0];
    return self;
}

- (void)setTitles:(NSArray<NSString *> *)titles fullTitles:(NSArray<NSString *> *)fullTitles {
    if ([_titles isEqualToArray:titles] && [_fullTitles isEqualToArray:fullTitles]) return;
    _titles = [titles copy];
    _fullTitles = [fullTitles copy];
    for (UILabel *label in _labels) [label removeFromSuperview];
    [_labels removeAllObjects];
    for (NSString *title in _titles) {
        UILabel *label = [[UILabel alloc] init];
        label.text = title;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = zs_mono_font(kZSSectionIndexBaseFontSize, UIFontWeightSemibold);
        label.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        [self addSubview:label];
        [_labels addObject:label];
    }
    _activeIndex = -1;
    _focusIndex = -1;
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
}

- (CGSize)intrinsicContentSize {
    if (_labels.count == 0) return CGSizeMake(UIViewNoIntrinsicMetric, 0);
    return CGSizeMake(UIViewNoIntrinsicMetric, _labels.count * kZSSectionIndexRowHeight + kZSSectionIndexVerticalPadding * 2);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self zs_layoutMagnified];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) return;
    [_link invalidate];
    _link = nil;
    _progress = 0;
    _target = 0;
    _focusIndex = -1;
}

- (void)zs_layoutMagnified {
    NSUInteger count = _labels.count;
    if (count == 0) return;
    CGFloat width = self.bounds.size.width;
    CGFloat t = _progress * _progress * (3 - 2 * _progress);
    CGFloat p = MAX(0, MIN(_touchP, (CGFloat)count));

    CGFloat scales[count];
    CGFloat heights[count];
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat d = ((CGFloat)i + 0.5) - p;
        CGFloat s = 1 + kZSSectionIndexPeakGrowth * t * exp(-(d * d) / (2 * kZSSectionIndexFalloff * kZSSectionIndexFalloff));
        scales[i] = s;
        heights[i] = kZSSectionIndexRowHeight * s;
    }

    NSInteger anchor = MIN((NSInteger)floor(p), (NSInteger)count - 1);
    CGFloat magnified = 0;
    for (NSInteger j = 0; j < anchor; j++) magnified += heights[j];
    magnified += (p - anchor) * heights[anchor];
    CGFloat offset = p * kZSSectionIndexRowHeight - magnified;

    CGFloat startY = kZSSectionIndexVerticalPadding + offset;
    CGFloat y = startY;
    CGFloat minLeft = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < count; i++) {
        UILabel *label = _labels[i];
        BOOL showFull = (NSInteger)i == _focusIndex && scales[i] >= kZSSectionIndexFullTitleScale && i < _fullTitles.count;
        NSString *text = showFull ? _fullTitles[i] : _titles[i];
        if (![label.text isEqualToString:text]) {
            if (t > 0) {
                CATransition *fade = [CATransition animation];
                fade.type = kCATransitionFade;
                fade.duration = 0.12;
                [label.layer addAnimation:fade forKey:@"zs_text"];
            }
            label.text = text;
        }
        label.font = zs_mono_font(kZSSectionIndexBaseFontSize * scales[i], UIFontWeightSemibold);
        CGFloat labelWidth = ceil([text sizeWithAttributes:@{NSFontAttributeName: label.font}].width) + 2;
        CGFloat centered = (width - labelWidth) * 0.5;
        CGFloat trailing = width - kZSSectionIndexLabelInset - labelWidth;
        CGFloat x = centered + (trailing - centered) * t;
        label.frame = CGRectMake(x, y, labelWidth, heights[i]);
        minLeft = MIN(minLeft, x);
        y += heights[i];
    }

    CGFloat reachX = (width - minLeft) + kZSSectionIndexShadowMargin;
    CGFloat reachY = (y - startY) * 0.5 + kZSSectionIndexShadowMargin;
    CGFloat grow = 0.35 + 0.65 * t;
    CGFloat radiusX = reachX * grow;
    CGFloat radiusY = reachY * grow;
    CGFloat centerY = (startY + y) * 0.5;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shadow.frame = CGRectMake(width - radiusX, centerY - radiusY, radiusX * 2, radiusY * 2);
    _shadow.opacity = t;
    [CATransaction commit];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -8, 0), point);
}

- (NSInteger)indexForTouch:(UITouch *)touch {
    if (_labels.count == 0) return -1;
    CGFloat y = [touch locationInView:self].y - kZSSectionIndexVerticalPadding;
    NSInteger index = (NSInteger)floor(y / kZSSectionIndexRowHeight);
    return MAX(0, MIN(index, (NSInteger)_labels.count - 1));
}

- (void)zs_applyActiveIndex {
    UIColor *dim = [UIColor colorWithWhite:1 alpha:0.5];
    for (NSUInteger i = 0; i < _labels.count; i++) {
        _labels[i].textColor = ((NSInteger)i == _activeIndex) ? zs_accent_green_color() : dim;
    }
}

- (void)zs_setTarget:(CGFloat)target {
    _target = target;
    if (_link || _progress == target) return;
    _lastTimestamp = 0;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_tick:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)zs_tick:(CADisplayLink *)link {
    CFTimeInterval timestamp = link.timestamp;
    CFTimeInterval dt = _lastTimestamp > 0 ? timestamp - _lastTimestamp : 1.0 / 60.0;
    _lastTimestamp = timestamp;
    BOOL rising = _target > _progress;
    CGFloat step = (CGFloat)dt / (rising ? 0.16 : 0.22);
    _progress = rising ? MIN(_target, _progress + step) : MAX(_target, _progress - step);
    if (_progress == _target) {
        [_link invalidate];
        _link = nil;
        if (_progress <= 0) _focusIndex = -1;
    }
    [self zs_layoutMagnified];
}

- (void)zs_trackTouch:(UITouch *)touch {
    CGFloat y = [touch locationInView:self].y - kZSSectionIndexVerticalPadding;
    _touchP = MAX(0, MIN(y / kZSSectionIndexRowHeight, (CGFloat)_labels.count));
    NSInteger index = [self indexForTouch:touch];
    _focusIndex = index;
    [self zs_selectIndex:index];
    [self zs_layoutMagnified];
}

- (void)zs_selectIndex:(NSInteger)index {
    if (index < 0 || index == _activeIndex) return;
    _activeIndex = index;
    [self zs_applyActiveIndex];
    [_haptic selectionChanged];
    [_haptic prepare];
    if (self.onSelect) self.onSelect((NSUInteger)index);
}

- (void)zs_endTracking {
    _activeIndex = -1;
    [self zs_applyActiveIndex];
    [self zs_setTarget:0];
    _haptic = nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _haptic = [[UISelectionFeedbackGenerator alloc] init];
    [_haptic prepare];
    [self zs_setTarget:1];
    [self zs_trackTouch:touches.anyObject];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self zs_trackTouch:touches.anyObject];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self zs_endTracking];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self zs_endTracking];
}

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
