#import "UIInternal.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation UserInterface (AssetExplorer)

#pragma mark Asset explorer full-screen viewer

- (void)assetExplorerTapped {
    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];
    self.modsLibraryBrowseMode = NO;
    self.modsLibrarySelectedEntry = nil;
    [self zs_openAssetExplorerFullScreenPanel];
}

- (void)zs_selectModeTapped {
    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];
    if (self.selectModeOverlay) {
        [self zs_exitSelectMode];
        return;
    }
    [self closePanelAnimated:YES];
    [self zs_enterSelectMode];
}

- (void)zs_exitSelectModeTapped {
    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];
    [self zs_exitSelectMode];
}

- (void)zs_exitSelectMode {
    self.selectModeLookupToken += 1;
    self.selectModeSelection = nil;
    [self.selectModeOverlay removeFromSuperview];
    self.selectModeOverlay = nil;
    self.selectModeHeader = nil;
    self.selectModeKindControl = nil;
    self.selectModeVisibleSwitch = nil;
    self.selectModeDragPan = nil;
    self.selectModePanelLeading = nil;
    self.selectModePanelTop = nil;
    self.selectModePanel = nil;
    self.selectModeTable = nil;
    self.selectModeList = nil;
    self.selectModeHighlight = nil;
    self.selectModeTableHeight = nil;
}

- (void)zs_enterSelectMode {
    UIView *host = zs_ui_host_view();
    if (!host || self.selectModeOverlay) return;

    ZSSelectModeOverlayView *overlay = [[ZSSelectModeOverlayView alloc] initWithFrame:host.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.userInteractionEnabled = YES;
    zs_force_dark(overlay);
    zs_mark_host_owned(overlay);
    [host addSubview:overlay];
    self.selectModeOverlay = overlay;
    self.selectModeSelection = nil;
    self.selectModeLastPoint = CGPointMake(-1000, -1000);

    UIView *catcher = [[UIView alloc] initWithFrame:overlay.bounds];
    catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    catcher.backgroundColor = UIColor.clearColor;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_selectModeTapRecognized:)];
    [catcher addGestureRecognizer:tap];
    [overlay addSubview:catcher];

    UIView *highlight = [[UIView alloc] initWithFrame:CGRectZero];
    highlight.userInteractionEnabled = NO;
    highlight.hidden = YES;
    highlight.backgroundColor = [UIColor colorWithRed:1.0 green:0.18 blue:0.18 alpha:0.12];
    highlight.layer.borderColor = [UIColor colorWithRed:1.0 green:0.18 blue:0.18 alpha:1.0].CGColor;
    highlight.layer.borderWidth = 2.5;
    [overlay addSubview:highlight];
    self.selectModeHighlight = highlight;

    UIView *panel;
    UIView *panelHost;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
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
    self.selectModePanel = panel;

    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.backgroundColor = UIColor.clearColor;
    [panelHost addSubview:header];
    self.selectModeHeader = header;

    UIView *grabber = [[UIView alloc] init];
    grabber.translatesAutoresizingMaskIntoConstraints = NO;
    grabber.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28];
    grabber.layer.cornerRadius = 2;
    grabber.userInteractionEnabled = NO;
    [header addSubview:grabber];

    UISegmentedControl *kindControl = [[UISegmentedControl alloc] initWithItems:@[@"Textures", @"Mesh"]];
    kindControl.translatesAutoresizingMaskIntoConstraints = NO;
    kindControl.selectedSegmentIndex = self.selectModeMeshMode ? 1 : 0;
    kindControl.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    kindControl.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    kindControl.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.22];
    [kindControl setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.6]} forState:UIControlStateNormal];
    [kindControl setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateSelected];
    [kindControl addTarget:self action:@selector(zs_selectModeKindChanged:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:kindControl];
    self.selectModeKindControl = kindControl;

    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(closeButton, [UIImage systemImageNamed:@"xmark" withConfiguration:symbolConfig], [UIColor colorWithWhite:1 alpha:0.85]);
    [closeButton addTarget:self action:@selector(zs_exitSelectModeTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:closeButton];

    UILabel *filterLabel = [[UILabel alloc] init];
    filterLabel.translatesAutoresizingMaskIntoConstraints = NO;
    filterLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    filterLabel.textColor = UIColor.whiteColor;
    filterLabel.text = @"Filter invis";
    [header addSubview:filterLabel];

    UISwitch *visibleSwitch = [[UISwitch alloc] init];
    visibleSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    visibleSwitch.on = !self.selectModeIncludeInvisible;
    visibleSwitch.onTintColor = zs_accent_green_color();
    [visibleSwitch addTarget:self action:@selector(zs_selectModeVisibleToggled:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:visibleSwitch];
    self.selectModeVisibleSwitch = visibleSwitch;

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(zs_selectModeDragged:)];
    drag.maximumNumberOfTouches = 1;
    drag.delegate = self;
    [header addGestureRecognizer:drag];
    self.selectModeDragPan = drag;

    ZSSelectModeList *list = [[ZSSelectModeList alloc] init];
    list.rows = @[];
    __weak typeof(self) weakSelf = self;
    list.onLocation = ^(ZSAssetLocation *location) {
        [weakSelf zs_selectModeOpenLocation:location];
    };
    self.selectModeList = list;

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.backgroundColor = UIColor.clearColor;
    table.separatorStyle = UITableViewCellSeparatorStyleNone;
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedRowHeight = 56;
    table.contentInset = UIEdgeInsetsMake(0, 0, 10, 0);
    table.alwaysBounceVertical = NO;
    table.hidden = YES;
    table.dataSource = list;
    table.delegate = list;
    [table registerClass:ZSSelectModeCell.class forCellReuseIdentifier:kZSSelectModeCellID];
    [panelHost addSubview:table];
    self.selectModeTable = table;

    NSLayoutConstraint *panelWidth = [panel.widthAnchor constraintEqualToConstant:300];
    panelWidth.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *tableHeight = [table.heightAnchor constraintEqualToConstant:0];
    tableHeight.priority = UILayoutPriorityDefaultHigh;
    self.selectModeTableHeight = tableHeight;
    NSLayoutConstraint *panelLeading = [panel.leadingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.leadingAnchor constant:12];
    NSLayoutConstraint *panelTop = [panel.topAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.topAnchor constant:10];
    self.selectModePanelLeading = panelLeading;
    self.selectModePanelTop = panelTop;

    [NSLayoutConstraint activateConstraints:@[
        panelLeading,
        panelTop,
        [panel.bottomAnchor constraintLessThanOrEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor constant:-10],
        [panel.widthAnchor constraintLessThanOrEqualToAnchor:overlay.widthAnchor multiplier:0.9],
        panelWidth,
        [header.topAnchor constraintEqualToAnchor:panelHost.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor],
        [grabber.topAnchor constraintEqualToAnchor:header.topAnchor constant:6],
        [grabber.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:36],
        [grabber.heightAnchor constraintEqualToConstant:4],
        [kindControl.topAnchor constraintEqualToAnchor:header.topAnchor constant:18],
        [kindControl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:14],
        [kindControl.trailingAnchor constraintEqualToAnchor:closeButton.leadingAnchor constant:-10],
        [kindControl.heightAnchor constraintEqualToConstant:32],
        [closeButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-10],
        [closeButton.centerYAnchor constraintEqualToAnchor:kindControl.centerYAnchor],
        [closeButton.widthAnchor constraintEqualToConstant:32],
        [closeButton.heightAnchor constraintEqualToConstant:32],
        [visibleSwitch.topAnchor constraintEqualToAnchor:kindControl.bottomAnchor constant:8],
        [visibleSwitch.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-14],
        [visibleSwitch.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10],
        [filterLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:18],
        [filterLabel.centerYAnchor constraintEqualToAnchor:visibleSwitch.centerYAnchor],
        [table.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [table.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor],
        [table.bottomAnchor constraintEqualToAnchor:panelHost.bottomAnchor],
        tableHeight,
    ]];

    [self zs_selectModeApplyCorner:self.selectModeCorner];
    [self zs_startSelectModeIndexing];
}

- (void)zs_startSelectModeIndexing {
    __weak typeof(self) weakSelf = self;
    [ZSAssetExplorer buildNameIndexWithProgress:nil completion:^(BOOL success) {
        UserInterface *strongSelf = weakSelf;
        if (!strongSelf.selectModeOverlay) return;
        if (strongSelf.selectModeSelection) [strongSelf zs_selectModeLoadLocationsForSelection];
    }];
}

- (void)zs_selectModeTapRecognized:(UITapGestureRecognizer *)tap {
    UIView *catcher = tap.view;
    UIView *host = catcher.superview.superview;
    if (!catcher || !host) return;

    CGPoint point = [tap locationInView:catcher];
    CGFloat scale = host.contentScaleFactor;
    float x = (float)(point.x * scale);
    float y = (float)((catcher.bounds.size.height - point.y) * scale);

    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];

    NSArray<NSDictionary *> *hits = zs_pick_assets_at_screen_point(x, y, self.selectModeMeshMode, !self.selectModeIncludeInvisible);
    if (hits.count == 0) {
        self.selectModeLastPoint = point;
        [self zs_selectModeClearSelection];
        [self zs_selectModeShowRows:zs_select_mode_message_rows(self.selectModeMeshMode ? @"No mesh found there. Try another spot." : @"No texture found there. Try another spot.", YES)];
        return;
    }

    NSUInteger index = 0;
    NSDictionary *current = self.selectModeSelection[@"hit"];
    BOOL samePlace = current != nil && hypot(point.x - self.selectModeLastPoint.x, point.y - self.selectModeLastPoint.y) < 20.0;
    if (samePlace) {
        NSNumber *currentID = current[@"id"];
        for (NSUInteger i = 0; i < hits.count; i++) {
            if ([hits[i][@"id"] isEqual:currentID]) {
                index = (i + 1) % hits.count;
                break;
            }
        }
    }
    self.selectModeLastPoint = point;

    NSDictionary *hit = hits[index];
    self.selectModeSelection = @{@"hit": hit, @"position": @(index), @"total": @(hits.count)};
    [self zs_selectModeApplyHighlightForHit:hit];
    [self zs_selectModeLoadLocationsForSelection];
}

- (void)zs_selectModeApplyHighlightForHit:(NSDictionary *)hit {
    UIView *overlay = self.selectModeOverlay;
    UIView *highlight = self.selectModeHighlight;
    UIView *host = overlay.superview;
    NSArray<NSNumber *> *rect = hit[@"rect"];
    if (!overlay || !highlight || !host || rect.count != 4) {
        highlight.hidden = YES;
        return;
    }
    CGFloat scale = host.contentScaleFactor > 0 ? host.contentScaleFactor : 1;
    CGFloat height = overlay.bounds.size.height;
    CGFloat left = rect[0].doubleValue / scale;
    CGFloat right = rect[2].doubleValue / scale;
    CGFloat top = height - rect[3].doubleValue / scale;
    CGFloat bottom = height - rect[1].doubleValue / scale;
    if (!isfinite(left) || !isfinite(right) || !isfinite(top) || !isfinite(bottom)) {
        highlight.hidden = YES;
        return;
    }
    highlight.frame = CGRectMake(left, top, MAX(right - left, 4), MAX(bottom - top, 4));
    highlight.hidden = NO;
}

- (void)zs_selectModeLoadLocationsForSelection {
    NSDictionary *selection = self.selectModeSelection;
    if (!selection) return;
    NSDictionary *hit = selection[@"hit"];
    NSUInteger position = [selection[@"position"] unsignedIntegerValue];
    NSUInteger total = [selection[@"total"] unsignedIntegerValue];

    NSUInteger token = ++self.selectModeLookupToken;
    [self zs_selectModeShowRows:zs_select_mode_rows(hit, nil, nil, nil, position, total, YES, NO)];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *spriteName = hit[@"spriteName"];
        NSString *textureName = hit[@"textureName"];
        BOOL packed = [hit[@"packed"] boolValue];
        NSArray<ZSAssetLocation *> *spriteLocations = spriteName.length > 0 ? [ZSAssetExplorer locationsForAssetName:spriteName classIDs:@[@213]] : @[];
        BOOL skipTexture = packed && spriteName.length > 0;
        NSArray<ZSAssetLocation *> *textureLocations = (textureName.length > 0 && !skipTexture) ? [ZSAssetExplorer locationsForAssetName:textureName classIDs:@[@28]] : @[];
        NSString *meshName = hit[@"meshName"];
        NSArray<ZSAssetLocation *> *meshLocations = meshName.length > 0 ? [ZSAssetExplorer locationsForAssetName:meshName classIDs:@[@43]] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            UserInterface *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.selectModeOverlay || token != strongSelf.selectModeLookupToken) return;
            [strongSelf zs_selectModeShowRows:zs_select_mode_rows(hit, spriteLocations, textureLocations, meshLocations, position, total, NO, [ZSAssetExplorer isNameIndexBuilding])];
        });
    });
}

- (void)zs_selectModeShowRows:(NSArray<NSDictionary *> *)rows {
    UITableView *table = self.selectModeTable;
    if (!table) return;
    self.selectModeList.rows = rows;
    [table reloadData];
    table.hidden = NO;
    [table setContentOffset:CGPointMake(0, -table.adjustedContentInset.top) animated:NO];
    [self zs_selectModeFitTableAnimated:YES retry:YES];
}

- (void)zs_selectModeFitTableAnimated:(BOOL)animated retry:(BOOL)retry {
    UITableView *table = self.selectModeTable;
    UIView *overlay = self.selectModeOverlay;
    if (!table || !overlay) return;
    [table layoutIfNeeded];
    CGFloat height = table.hidden ? 0 : table.contentSize.height + table.contentInset.bottom;
    self.selectModeTableHeight.constant = height;
    [self zs_selectModeReanchorIfIdle];
    if (animated) {
        [UIView animateWithDuration:0.2 animations:^{
            [overlay layoutIfNeeded];
        }];
    } else {
        [overlay layoutIfNeeded];
    }
    if (!retry) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf zs_selectModeFitTableAnimated:NO retry:NO];
    });
}

- (void)zs_selectModeKindChanged:(UISegmentedControl *)control {
    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];
    self.selectModeMeshMode = control.selectedSegmentIndex == 1;
    self.selectModeLastPoint = CGPointMake(-1000, -1000);
    [self zs_selectModeClearSelection];
}

- (void)zs_selectModeVisibleToggled:(UISwitch *)toggle {
    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];
    self.selectModeIncludeInvisible = !toggle.isOn;
    self.selectModeLastPoint = CGPointMake(-1000, -1000);
    [self zs_selectModeClearSelection];
}

- (CGRect)zs_selectModeConstantRangeForHeight:(CGFloat)height {
    UIView *overlay = self.selectModeOverlay;
    UIView *panel = self.selectModePanel;
    UIEdgeInsets insets = overlay.safeAreaInsets;
    CGFloat margin = 12;
    CGFloat width = panel.bounds.size.width > 0 ? panel.bounds.size.width : MIN(300, overlay.bounds.size.width * 0.9);
    CGFloat availableHeight = MAX(overlay.bounds.size.height - insets.top - insets.bottom - margin * 2, 0);
    CGFloat clampedHeight = MIN(height, availableHeight);
    CGFloat minLeading = margin;
    CGFloat maxLeading = MAX(minLeading, overlay.bounds.size.width - insets.left - insets.right - margin - width);
    CGFloat minTop = margin;
    CGFloat maxTop = MAX(minTop, overlay.bounds.size.height - insets.top - insets.bottom - margin - clampedHeight);
    return CGRectMake(minLeading, minTop, maxLeading - minLeading, maxTop - minTop);
}

- (CGFloat)zs_selectModeExpectedHeight {
    CGFloat headerHeight = self.selectModeHeader.bounds.size.height > 0 ? self.selectModeHeader.bounds.size.height : 100;
    return headerHeight + self.selectModeTableHeight.constant;
}

- (void)zs_selectModeApplyCorner:(NSInteger)corner {
    if (!self.selectModeOverlay || !self.selectModePanelLeading || !self.selectModePanelTop) return;
    CGRect range = [self zs_selectModeConstantRangeForHeight:[self zs_selectModeExpectedHeight]];
    self.selectModePanelLeading.constant = (corner & 1) ? CGRectGetMaxX(range) : CGRectGetMinX(range);
    self.selectModePanelTop.constant = (corner & 2) ? CGRectGetMaxY(range) : CGRectGetMinY(range);
}

- (void)zs_selectModeReanchorIfIdle {
    UIGestureRecognizerState state = self.selectModeDragPan.state;
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) return;
    [self zs_selectModeApplyCorner:self.selectModeCorner];
}

- (void)zs_selectModeDragged:(UIPanGestureRecognizer *)pan {
    UIView *overlay = self.selectModeOverlay;
    UIView *panel = self.selectModePanel;
    if (!overlay || !panel || !self.selectModePanelLeading || !self.selectModePanelTop) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
            panel.transform = CGAffineTransformMakeScale(1.025, 1.025);
        } completion:nil];
    }

    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [pan translationInView:overlay];
        [pan setTranslation:CGPointZero inView:overlay];
        CGRect range = [self zs_selectModeConstantRangeForHeight:panel.bounds.size.height];
        self.selectModePanelLeading.constant = MIN(MAX(self.selectModePanelLeading.constant + translation.x, CGRectGetMinX(range)), CGRectGetMaxX(range));
        self.selectModePanelTop.constant = MIN(MAX(self.selectModePanelTop.constant + translation.y, CGRectGetMinY(range)), CGRectGetMaxY(range));
        [overlay layoutIfNeeded];
        return;
    }

    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled && pan.state != UIGestureRecognizerStateFailed) return;

    CGPoint velocity = [pan velocityInView:overlay];
    CGRect frame = panel.frame;
    CGPoint projected = CGPointMake(CGRectGetMidX(frame) + velocity.x * 0.18, CGRectGetMidY(frame) + velocity.y * 0.18);
    CGPoint center = CGPointMake(overlay.bounds.size.width * 0.5, overlay.bounds.size.height * 0.5);
    NSInteger corner = (projected.x > center.x ? 1 : 0) | (projected.y > center.y ? 2 : 0);
    self.selectModeCorner = corner;

    CGRect range = [self zs_selectModeConstantRangeForHeight:[self zs_selectModeExpectedHeight]];
    CGFloat targetLeading = (corner & 1) ? CGRectGetMaxX(range) : CGRectGetMinX(range);
    CGFloat targetTop = (corner & 2) ? CGRectGetMaxY(range) : CGRectGetMinY(range);
    CGFloat distance = hypot(targetLeading - self.selectModePanelLeading.constant, targetTop - self.selectModePanelTop.constant);
    CGFloat speed = hypot(velocity.x, velocity.y);
    CGFloat initialVelocity = distance > 1 ? MIN(speed / distance, 8) : 0;

    self.selectModePanelLeading.constant = targetLeading;
    self.selectModePanelTop.constant = targetTop;
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:initialVelocity options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        panel.transform = CGAffineTransformIdentity;
        [overlay layoutIfNeeded];
    } completion:nil];
}

- (void)zs_selectModeClearSelection {
    self.selectModeSelection = nil;
    self.selectModeLookupToken += 1;
    self.selectModeHighlight.hidden = YES;
    self.selectModeList.rows = @[];
    [self.selectModeTable reloadData];
    self.selectModeTable.hidden = YES;
    self.selectModeTableHeight.constant = 0;
    [self zs_selectModeReanchorIfIdle];
    UIView *overlay = self.selectModeOverlay;
    [UIView animateWithDuration:0.2 animations:^{
        [overlay layoutIfNeeded];
    }];
}

- (void)zs_buildAssetExplorerFullScreenPanelIfNeeded {
    if (self.assetExplorerFullScreenOverlay) return;
    if (!self.extendedContentClip) return;

    UIView *overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.hidden = YES;
    overlay.userInteractionEnabled = YES;
    [self.extendedContentClip addSubview:overlay];
    zs_force_dark(overlay);
    self.assetExplorerFullScreenOverlay = overlay;
    [self zs_installPinchToExitOnView:overlay];

    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    UIImage *closeImage = [UIImage systemImageNamed:@"xmark" withConfiguration:symbolConfig];
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(closeButton, closeImage, [UIColor colorWithWhite:1 alpha:0.85]);
    [closeButton addTarget:self action:@selector(zs_closeAssetExplorerFullScreenPanelTapped) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:closeButton];
    self.assetExplorerCloseButton = closeButton;

    UIImage *backImage = [UIImage systemImageNamed:@"chevron.left" withConfiguration:symbolConfig];
    UIButton *backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    backButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(backButton, backImage, [UIColor colorWithWhite:1 alpha:0.85]);
    [backButton addTarget:self action:@selector(zs_assetExplorerBackTapped) forControlEvents:UIControlEventTouchUpInside];
    backButton.hidden = YES;
    [overlay addSubview:backButton];
    self.assetExplorerBackButton = backButton;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Asset Explorer";
    titleLabel.font = zs_mono_font(12, UIFontWeightSemibold);
    titleLabel.textColor = [UIColor colorWithWhite:0.96 alpha:1];
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.6;
    [overlay addSubview:titleLabel];
    self.assetExplorerTitleLabel = titleLabel;

    UILabel *statusLabel = [[UILabel alloc] init];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.text = @"Scanning…";
    statusLabel.font = zs_mono_font(9, UIFontWeightRegular);
    statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    statusLabel.textAlignment = NSTextAlignmentRight;
    statusLabel.adjustsFontSizeToFitWidth = YES;
    statusLabel.minimumScaleFactor = 0.6;
    [statusLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [overlay addSubview:statusLabel];
    self.assetExplorerStatusLabel = statusLabel;

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.backgroundColor = UIColor.clearColor;
    tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    tableView.separatorInset = UIEdgeInsetsMake(0, kPanelPadding, 0, kPanelPadding);
    tableView.showsVerticalScrollIndicator = NO;
    tableView.showsHorizontalScrollIndicator = NO;
    tableView.rowHeight = 48;
    tableView.estimatedRowHeight = 48;
    if (@available(iOS 15.0, *)) tableView.sectionHeaderTopPadding = 0;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    tableView.dataSource = self;
    tableView.delegate = self;
    [overlay addSubview:tableView];
    self.assetExplorerTableView = tableView;

    __weak typeof(self) thumbWeakSelf = self;
    ZSAssetThumbGridSource *thumbSource = [[ZSAssetThumbGridSource alloc] init];
    thumbSource.onSelect = ^(ZSAssetExplorerAsset *asset) {
        [thumbWeakSelf zs_assetExplorerOpenTextureForAsset:asset];
    };
    UICollectionViewFlowLayout *thumbLayout = [[UICollectionViewFlowLayout alloc] init];
    thumbLayout.minimumInteritemSpacing = 2;
    thumbLayout.minimumLineSpacing = 2;
    thumbLayout.sectionInset = UIEdgeInsetsMake(2, 2, 2, 2);
    UICollectionView *thumbCollection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:thumbLayout];
    thumbCollection.translatesAutoresizingMaskIntoConstraints = NO;
    thumbCollection.backgroundColor = UIColor.clearColor;
    thumbCollection.showsVerticalScrollIndicator = NO;
    thumbCollection.alwaysBounceVertical = YES;
    thumbCollection.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    thumbCollection.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    thumbCollection.hidden = YES;
    [thumbCollection registerClass:[ZSAssetThumbCell class] forCellWithReuseIdentifier:@"ZSAssetThumbCell"];
    thumbCollection.dataSource = thumbSource;
    thumbCollection.delegate = thumbSource;
    thumbSource.collectionView = thumbCollection;
    [overlay addSubview:thumbCollection];
    self.assetExplorerThumbSource = thumbSource;
    self.assetExplorerThumbCollectionView = thumbCollection;

    UIButton *textureBackButton = [UIButton buttonWithType:UIButtonTypeSystem];
    textureBackButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(textureBackButton, backImage, [UIColor colorWithWhite:1 alpha:0.85]);
    [textureBackButton addTarget:self action:@selector(zs_assetExplorerTextureBackTapped) forControlEvents:UIControlEventTouchUpInside];
    textureBackButton.hidden = YES;
    [overlay addSubview:textureBackButton];
    self.assetExplorerTextureBackButton = textureBackButton;

    UIButton *textureExportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    textureExportButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(textureExportButton, [UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:symbolConfig], [UIColor colorWithWhite:1 alpha:0.85]);
    [textureExportButton addTarget:self action:@selector(zs_assetExplorerTextureExportTapped) forControlEvents:UIControlEventTouchUpInside];
    textureExportButton.hidden = YES;
    textureExportButton.enabled = NO;
    textureExportButton.alpha = 0.35;
    [overlay addSubview:textureExportButton];
    self.assetExplorerTextureExportButton = textureExportButton;

    UIButton *textureSwapButton = [UIButton buttonWithType:UIButtonTypeSystem];
    textureSwapButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(textureSwapButton, [UIImage systemImageNamed:@"arrow.left.arrow.right" withConfiguration:symbolConfig], [UIColor colorWithWhite:1 alpha:0.85]);
    [textureSwapButton addTarget:self action:@selector(zs_assetExplorerTextureSwapTapped) forControlEvents:UIControlEventTouchUpInside];
    textureSwapButton.hidden = YES;
    [overlay addSubview:textureSwapButton];
    self.assetExplorerTextureSwapButton = textureSwapButton;

    ZSModeSlider *modeControl = [[ZSModeSlider alloc] init];
    modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    modeControl.labels = @[@"Preview", @"Data"];
    modeControl.gifTintEnabled = NO;
    modeControl.selectedIndex = 0;
    modeControl.hidden = YES;
    [modeControl addTarget:self action:@selector(zs_assetExplorerModeChanged:) forControlEvents:UIControlEventValueChanged];
    [overlay addSubview:modeControl];
    self.assetExplorerModeControl = modeControl;

    UIImageView *textureImageView = [[UIImageView alloc] init];
    textureImageView.translatesAutoresizingMaskIntoConstraints = NO;
    textureImageView.contentMode = UIViewContentModeScaleAspectFit;
    textureImageView.backgroundColor = UIColor.clearColor;
    textureImageView.userInteractionEnabled = YES;
    UITapGestureRecognizer *previewTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_assetExplorerPreviewTapped)];
    UITapGestureRecognizer *previewDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_assetExplorerPreviewDoubleTapped:)];
    previewDoubleTap.numberOfTapsRequired = 2;
    previewDoubleTap.delegate = self;
    [previewTap requireGestureRecognizerToFail:previewDoubleTap];
    [textureImageView addGestureRecognizer:previewTap];
    [textureImageView addGestureRecognizer:previewDoubleTap];
    textureImageView.hidden = YES;

    ZSAssetPreviewClipView *previewClip = [[ZSAssetPreviewClipView alloc] init];
    previewClip.translatesAutoresizingMaskIntoConstraints = NO;
    previewClip.backgroundColor = UIColor.clearColor;
    previewClip.clipsToBounds = NO;
    previewClip.contentView = textureImageView;
    UIPinchGestureRecognizer *previewPinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(zs_assetExplorerPreviewPinched:)];
    previewPinch.delegate = self;
    UIPanGestureRecognizer *previewPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(zs_assetExplorerPreviewPanned:)];
    previewPan.delegate = self;
    previewPan.maximumNumberOfTouches = 2;
    [previewClip addGestureRecognizer:previewPinch];
    [previewClip addGestureRecognizer:previewPan];
    [previewClip addSubview:textureImageView];
    [overlay addSubview:previewClip];
    self.assetExplorerTextureImageView = textureImageView;
    self.assetExplorerPreviewClipView = previewClip;
    self.assetExplorerPreviewScale = 1;
    self.assetExplorerPreviewOffset = CGPointZero;

    UITextView *textView = [[UITextView alloc] init];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.backgroundColor = UIColor.clearColor;
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = zs_mono_font(10, UIFontWeightRegular);
    textView.textColor = [UIColor colorWithWhite:1 alpha:0.88];
    textView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    textView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    textView.alwaysBounceVertical = YES;
    textView.hidden = YES;
    [overlay addSubview:textView];
    self.assetExplorerTextView = textView;

    UILabel *textureCaption = [[UILabel alloc] init];
    textureCaption.translatesAutoresizingMaskIntoConstraints = NO;
    textureCaption.font = zs_mono_font(9, UIFontWeightRegular);
    textureCaption.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    textureCaption.textAlignment = NSTextAlignmentCenter;
    textureCaption.adjustsFontSizeToFitWidth = YES;
    textureCaption.minimumScaleFactor = 0.6;
    textureCaption.hidden = YES;
    [overlay addSubview:textureCaption];
    self.assetExplorerTextureCaptionLabel = textureCaption;

    UILabel *textureMessage = [[UILabel alloc] init];
    textureMessage.translatesAutoresizingMaskIntoConstraints = NO;
    textureMessage.font = zs_mono_font(11, UIFontWeightRegular);
    textureMessage.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    textureMessage.textAlignment = NSTextAlignmentCenter;
    textureMessage.numberOfLines = 0;
    textureMessage.hidden = YES;
    [overlay addSubview:textureMessage];
    self.assetExplorerTextureMessageLabel = textureMessage;

    UILabel *debugLabel = [[UILabel alloc] init];
    debugLabel.translatesAutoresizingMaskIntoConstraints = NO;
    debugLabel.font = zs_mono_font(8, UIFontWeightMedium);
    debugLabel.textColor = UIColor.whiteColor;
    debugLabel.alpha = 0.55;
    debugLabel.numberOfLines = 0;
    debugLabel.textAlignment = NSTextAlignmentLeft;
    debugLabel.userInteractionEnabled = NO;
    debugLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    debugLabel.layer.shadowOpacity = 1;
    debugLabel.layer.shadowRadius = 2;
    debugLabel.layer.shadowOffset = CGSizeMake(0, 1);
    debugLabel.layer.masksToBounds = NO;
    debugLabel.hidden = YES;
    [overlay addSubview:debugLabel];
    self.assetExplorerDebugLabel = debugLabel;

    UIActivityIndicatorView *textureSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    textureSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    textureSpinner.color = [UIColor colorWithWhite:1 alpha:0.7];
    textureSpinner.hidesWhenStopped = YES;
    [overlay addSubview:textureSpinner];
    self.assetExplorerTextureSpinner = textureSpinner;

    ZSAssetCheckerboardView *backdrop = [[ZSAssetCheckerboardView alloc] initWithFrame:CGRectZero];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.hidden = YES;
    [overlay insertSubview:backdrop atIndex:0];
    [overlay insertSubview:self.assetExplorerPreviewClipView aboveSubview:backdrop];
    self.assetExplorerBackdropView = backdrop;

    UITextField *searchField = [[UITextField alloc] init];
    searchField.font = zs_mono_font(12, UIFontWeightRegular);
    searchField.textColor = UIColor.whiteColor;
    searchField.tintColor = zs_accent_green_color();
    searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    searchField.returnKeyType = UIReturnKeyDone;
    searchField.delegate = self;
    [searchField addTarget:self action:@selector(zs_assetExplorerSearchChanged:) forControlEvents:UIControlEventEditingChanged];
    self.assetExplorerSearchField = searchField;

    UIVisualEffectView *searchGlass = zs_wrap_field_in_native_glass(searchField, 8);
    UIView *searchContainer = searchGlass ?: searchField;
    searchContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:searchContainer];
    self.assetExplorerSearchContainer = searchContainer;

    UIButton *filterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    filterButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(filterButton, [UIImage systemImageNamed:@"line.3.horizontal.decrease.circle" withConfiguration:symbolConfig], [UIColor colorWithWhite:1 alpha:0.9]);
    filterButton.showsMenuAsPrimaryAction = YES;
    filterButton.hidden = YES;
    filterButton.tag = 0;
    self.assetExplorerFilterButton = filterButton;

    UIButton *sortButton = [UIButton buttonWithType:UIButtonTypeSystem];
    sortButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(sortButton, [UIImage systemImageNamed:@"arrow.up.arrow.down" withConfiguration:symbolConfig], [UIColor colorWithWhite:1 alpha:0.9]);
    sortButton.showsMenuAsPrimaryAction = YES;
    sortButton.tag = 0;
    self.assetExplorerSortButton = sortButton;

    UIButton *shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
    shareButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(shareButton, [UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:symbolConfig], [UIColor colorWithWhite:1 alpha:0.9]);
    [shareButton addTarget:self action:@selector(zs_assetExplorerShareBundleTapped) forControlEvents:UIControlEventTouchUpInside];
    shareButton.hidden = YES;
    shareButton.enabled = NO;
    shareButton.alpha = 0.35;
    self.assetExplorerShareButton = shareButton;

    UIButton *viewModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    viewModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(viewModeButton, [UIImage systemImageNamed:@"square.grid.2x2" withConfiguration:symbolConfig], [UIColor colorWithWhite:1 alpha:0.9]);
    [viewModeButton addTarget:self action:@selector(zs_assetExplorerViewModeTapped) forControlEvents:UIControlEventTouchUpInside];
    viewModeButton.enabled = NO;
    viewModeButton.alpha = 0.35;
    viewModeButton.tag = 0;
    self.assetExplorerViewModeButton = viewModeButton;

    ZSGlassControlRow *controlsStack = [[ZSGlassControlRow alloc] init];
    controlsStack.translatesAutoresizingMaskIntoConstraints = NO;
    controlsStack.itemSize = 30;
    controlsStack.itemSpacing = 8;
    controlsStack.itemWidths = @[@39, @30, @30, @30];
    [overlay addSubview:controlsStack];
    controlsStack.buttons = @[viewModeButton, shareButton, filterButton, sortButton];
    self.assetExplorerControlsStack = controlsStack;

    UIImage *nextImage = [UIImage systemImageNamed:@"chevron.right" withConfiguration:symbolConfig];
    UIButton *prevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    prevButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_arrow_only_button(prevButton, backImage, [UIColor colorWithWhite:1 alpha:0.9], NO);
    [prevButton addTarget:self action:@selector(zs_assetExplorerTexturePrevTapped) forControlEvents:UIControlEventTouchUpInside];
    self.assetExplorerTexturePrevButton = prevButton;

    UIButton *nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_arrow_only_button(nextButton, nextImage, [UIColor colorWithWhite:1 alpha:0.9], NO);
    [nextButton addTarget:self action:@selector(zs_assetExplorerTextureNextTapped) forControlEvents:UIControlEventTouchUpInside];
    self.assetExplorerTextureNextButton = nextButton;

    UILabel *positionLabel = [[UILabel alloc] init];
    positionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    positionLabel.font = zs_mono_font(10, UIFontWeightMedium);
    positionLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    positionLabel.textAlignment = NSTextAlignmentCenter;
    positionLabel.adjustsFontSizeToFitWidth = YES;
    positionLabel.minimumScaleFactor = 0.6;
    self.assetExplorerTexturePositionLabel = positionLabel;

    UIStackView *pagerStack = [[UIStackView alloc] initWithArrangedSubviews:@[prevButton, positionLabel, nextButton]];
    pagerStack.translatesAutoresizingMaskIntoConstraints = NO;
    pagerStack.axis = UILayoutConstraintAxisHorizontal;
    pagerStack.alignment = UIStackViewAlignmentCenter;
    pagerStack.spacing = 6;
    pagerStack.hidden = YES;
    [overlay addSubview:pagerStack];
    self.assetExplorerTexturePagerStack = pagerStack;

    UIButton *pagePrevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    pagePrevButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_arrow_only_button(pagePrevButton, backImage, [UIColor colorWithWhite:1 alpha:0.9], YES);
    [pagePrevButton addTarget:self action:@selector(zs_assetExplorerPagePrevTapped) forControlEvents:UIControlEventTouchUpInside];
    self.assetExplorerPagePrevButton = pagePrevButton;

    UIButton *pageNextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    pageNextButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_arrow_only_button(pageNextButton, nextImage, [UIColor colorWithWhite:1 alpha:0.9], YES);
    [pageNextButton addTarget:self action:@selector(zs_assetExplorerPageNextTapped) forControlEvents:UIControlEventTouchUpInside];
    self.assetExplorerPageNextButton = pageNextButton;

    UILabel *pageLabel = [[UILabel alloc] init];
    pageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    pageLabel.font = zs_mono_font(10, UIFontWeightMedium);
    pageLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    pageLabel.textAlignment = NSTextAlignmentCenter;
    pageLabel.adjustsFontSizeToFitWidth = YES;
    pageLabel.minimumScaleFactor = 0.6;
    self.assetExplorerPageLabel = pageLabel;

    UIStackView *pageStack = [[UIStackView alloc] initWithArrangedSubviews:@[pagePrevButton, pageLabel, pageNextButton]];
    pageStack.translatesAutoresizingMaskIntoConstraints = NO;
    pageStack.axis = UILayoutConstraintAxisHorizontal;
    pageStack.alignment = UIStackViewAlignmentCenter;
    pageStack.spacing = 8;
    pageStack.hidden = YES;
    [overlay addSubview:pageStack];
    self.assetExplorerPageStack = pageStack;

    NSLayoutConstraint *modeControlWidth = [modeControl.widthAnchor constraintEqualToConstant:118];
    modeControlWidth.priority = UILayoutPriorityDefaultHigh;
    modeControlWidth.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [pagePrevButton.widthAnchor constraintEqualToConstant:30],
        [pagePrevButton.heightAnchor constraintEqualToConstant:30],
        [pageNextButton.widthAnchor constraintEqualToConstant:30],
        [pageNextButton.heightAnchor constraintEqualToConstant:30],
        [pageLabel.widthAnchor constraintGreaterThanOrEqualToConstant:110],
        [pageStack.centerXAnchor constraintEqualToAnchor:textureImageView.centerXAnchor],
        [pageStack.bottomAnchor constraintEqualToAnchor:textureCaption.topAnchor constant:-8],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [prevButton.widthAnchor constraintEqualToConstant:30],
        [prevButton.heightAnchor constraintEqualToConstant:30],
        [nextButton.widthAnchor constraintEqualToConstant:30],
        [nextButton.heightAnchor constraintEqualToConstant:30],
        [positionLabel.widthAnchor constraintGreaterThanOrEqualToConstant:44],
        [pagerStack.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [pagerStack.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-kPanelPadding],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.topAnchor constraintEqualToAnchor:overlay.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor],
        [backdrop.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],

        [searchContainer.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [searchContainer.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [searchContainer.widthAnchor constraintEqualToConstant:150],
        [searchContainer.heightAnchor constraintEqualToConstant:30],

        [shareButton.widthAnchor constraintEqualToConstant:30],
        [shareButton.heightAnchor constraintEqualToConstant:30],
        [filterButton.widthAnchor constraintEqualToConstant:30],
        [filterButton.heightAnchor constraintEqualToConstant:30],
        [sortButton.widthAnchor constraintEqualToConstant:30],
        [sortButton.heightAnchor constraintEqualToConstant:30],
        [viewModeButton.widthAnchor constraintEqualToConstant:39],
        [viewModeButton.heightAnchor constraintEqualToConstant:30],
        [controlsStack.widthAnchor constraintEqualToConstant:153],
        [controlsStack.heightAnchor constraintEqualToConstant:30],
        [controlsStack.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [controlsStack.trailingAnchor constraintEqualToAnchor:searchContainer.leadingAnchor constant:-8],
    ]];

    NSLayoutConstraint *swapLeading = [textureSwapButton.leadingAnchor constraintEqualToAnchor:textureExportButton.trailingAnchor constant:0];
    NSLayoutConstraint *swapWidth = [textureSwapButton.widthAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[swapLeading, swapWidth]];
    self.assetExplorerTextureSwapLeading = swapLeading;
    self.assetExplorerTextureSwapWidth = swapWidth;

    [NSLayoutConstraint activateConstraints:@[
        [textureBackButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [textureBackButton.leadingAnchor constraintEqualToAnchor:closeButton.trailingAnchor constant:8],
        [textureBackButton.widthAnchor constraintEqualToConstant:30],
        [textureBackButton.heightAnchor constraintEqualToConstant:30],

        [textureExportButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [textureExportButton.leadingAnchor constraintEqualToAnchor:textureBackButton.trailingAnchor constant:8],
        [textureExportButton.widthAnchor constraintEqualToConstant:30],
        [textureExportButton.heightAnchor constraintEqualToConstant:30],

        [modeControl.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [textureSwapButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [textureSwapButton.heightAnchor constraintEqualToConstant:30],
        [modeControl.leadingAnchor constraintEqualToAnchor:textureSwapButton.trailingAnchor constant:8],
        [modeControl.heightAnchor constraintEqualToConstant:30],
        [modeControl.trailingAnchor constraintLessThanOrEqualToAnchor:pagerStack.leadingAnchor constant:-6],

        [textureCaption.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset],
        [textureCaption.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [textureCaption.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [debugLabel.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset],
        [debugLabel.bottomAnchor constraintEqualToAnchor:pageStack.topAnchor constant:-6],
        [debugLabel.widthAnchor constraintLessThanOrEqualToAnchor:overlay.widthAnchor multiplier:0.8],

        [previewClip.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:12],
        [previewClip.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset],
        [previewClip.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [previewClip.bottomAnchor constraintEqualToAnchor:textureCaption.topAnchor constant:-8],

        [textureImageView.topAnchor constraintEqualToAnchor:previewClip.topAnchor],
        [textureImageView.leadingAnchor constraintEqualToAnchor:previewClip.leadingAnchor],
        [textureImageView.trailingAnchor constraintEqualToAnchor:previewClip.trailingAnchor],
        [textureImageView.bottomAnchor constraintEqualToAnchor:previewClip.bottomAnchor],

        [textView.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:12],
        [textView.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset],
        [textView.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [textView.bottomAnchor constraintEqualToAnchor:textureCaption.topAnchor constant:-8],

        [textureMessage.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [textureMessage.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [textureMessage.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset],
        [textureMessage.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-kPanelPadding],

        [textureSpinner.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [textureSpinner.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [closeButton.topAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.topAnchor constant:kPanelPadding],
        [closeButton.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset],
        [closeButton.widthAnchor constraintEqualToConstant:30],
        [closeButton.heightAnchor constraintEqualToConstant:30],

        [backButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [backButton.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset],
        [backButton.widthAnchor constraintEqualToConstant:30],
        [backButton.heightAnchor constraintEqualToConstant:30],

        [titleLabel.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:backButton.trailingAnchor constant:10],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:statusLabel.leadingAnchor constant:-10],

        [statusLabel.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [statusLabel.widthAnchor constraintLessThanOrEqualToConstant:180],

        [tableView.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:12],
        [tableView.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [tableView.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [tableView.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor],

        [thumbCollection.topAnchor constraintEqualToAnchor:tableView.topAnchor],
        [thumbCollection.leadingAnchor constraintEqualToAnchor:tableView.leadingAnchor],
        [thumbCollection.trailingAnchor constraintEqualToAnchor:tableView.trailingAnchor],
        [thumbCollection.bottomAnchor constraintEqualToAnchor:tableView.bottomAnchor],
    ]];

    self.assetExplorerStatusTrailingToControls = [statusLabel.trailingAnchor constraintEqualToAnchor:controlsStack.leadingAnchor constant:-10];
    self.assetExplorerStatusTrailingToControls.active = YES;

    [self zs_modsLibraryBuildHeaderControls];
    [self zs_assetExplorerBuildHubAndFMODViews];
}

- (BOOL)zs_assetExplorerFilterIsImageKind {
    NSString *kind = self.assetExplorerFilterKind;
    if (!self.assetExplorerSelectedBundle || kind.length == 0) return NO;
    BOOL found = NO;
    for (ZSAssetExplorerAsset *asset in self.assetExplorerAssets) {
        NSString *assetKind = asset.typeName.length > 0 ? asset.typeName : @"Unknown";
        if (![assetKind isEqualToString:kind]) continue;
        if (![ZSAssetExplorer classID:asset.classID sharesPreviewGroupWithClassID:28]) return NO;
        found = YES;
    }
    return found;
}

- (void)zs_assetExplorerUpdateThumbnailGrid {
    UICollectionView *grid = self.assetExplorerThumbCollectionView;
    if (!grid) return;
    BOOL available = !self.assetExplorerFMODMode && !self.assetExplorerLocalizeMode && !self.assetExplorerHubVisible && [self zs_assetExplorerFilterIsImageKind];
    BOOL enabled = available && self.assetExplorerThumbnailMode;
    BOOL show = enabled && !self.assetExplorerTextureOpen && !self.assetExplorerTableView.hidden;

    self.assetExplorerViewModeButton.enabled = available;
    self.assetExplorerViewModeButton.alpha = available ? 1 : 0.35;
    NSInteger desiredStyle = enabled ? 1 : 0;
    if (self.assetExplorerViewModeButton.tag != desiredStyle) {
        UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
        UIColor *tint = enabled ? zs_accent_green_color() : [UIColor colorWithWhite:1 alpha:0.9];
        zs_style_pill_icon_button_as_native_glass(self.assetExplorerViewModeButton, [UIImage systemImageNamed:(enabled ? @"list.bullet" : @"square.grid.2x2") withConfiguration:symbolConfig], tint);
        self.assetExplorerViewModeButton.tag = desiredStyle;
    }

    if (show) {
        ZSAssetThumbGridSource *source = self.assetExplorerThumbSource;
        NSArray<ZSAssetExplorerAsset *> *displayed = self.assetExplorerDisplayedAssets ?: @[];
        NSString *bundlePath = self.assetExplorerSelectedBundle.filePath;
        BOOL pathChanged = ![source.bundlePath ?: @"" isEqualToString:bundlePath ?: @""];
        if (pathChanged) {
            [source reset];
            source.bundlePath = bundlePath;
        }
        if (pathChanged || source.assets != displayed) {
            source.assets = displayed;
            [grid reloadData];
        }
    }
    grid.hidden = !show;
    self.assetExplorerTableView.alpha = show ? 0 : 1;
    self.assetExplorerTableView.userInteractionEnabled = !show;
}

- (void)zs_assetExplorerViewModeTapped {
    self.assetExplorerThumbnailMode = !self.assetExplorerThumbnailMode;
    [self zs_assetExplorerUpdateThumbnailGrid];
    if (!self.assetExplorerThumbCollectionView.hidden) [self.assetExplorerThumbCollectionView setContentOffset:CGPointZero animated:NO];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_assetExplorerLoadBundles {
    self.assetExplorerGeneration += 1;
    NSUInteger generation = self.assetExplorerGeneration;
    self.assetExplorerNamesSession += 1;
    NSUInteger namesSession = self.assetExplorerNamesSession;
    self.assetExplorerSelectedBundle = nil;
    [self zs_assetExplorerSetTextureModeVisible:NO];
    self.assetExplorerAssets = @[];
    self.assetExplorerCloseButton.hidden = YES;
    self.assetExplorerTitleLabel.text = @"Asset Explorer";
    self.assetExplorerStatusMessage = @"Loading…";
    self.assetExplorerBackButton.hidden = NO;
    self.assetExplorerTableView.hidden = NO;
    [self zs_assetExplorerResetViewState];
    [self zs_assetExplorerRefreshListResettingScroll:YES];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<ZSAssetExplorerBundle *> *bundles = [ZSAssetExplorer cachedBundles:&error];
        void (^deliver)(NSArray<ZSAssetExplorerBundle *> *, NSError *) = ^(NSArray<ZSAssetExplorerBundle *> *list, NSError *deliverError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || strongSelf.assetExplorerGeneration != generation) return;
                strongSelf.assetExplorerBundles = list ?: @[];
                strongSelf.assetExplorerStatusMessage = deliverError ? deliverError.localizedDescription : nil;
                [strongSelf zs_assetExplorerRefreshListResettingScroll:NO];
                [strongSelf zs_assetExplorerSyncControls];
            });
        };
        deliver(bundles, error);

        NSDictionary *indexBefore = [ZSFileIndex persistedCABMap];
        [ZSFileIndex ensureIndexUpToDate];
        NSDictionary *indexAfter = [ZSFileIndex persistedCABMap];
        BOOL indexChanged = indexBefore != indexAfter && ![indexBefore isEqualToDictionary:indexAfter];
        NSArray<ZSAssetExplorerBundle *> *finalBundles = bundles;
        if (indexChanged) {
            NSError *refreshError = nil;
            NSArray<ZSAssetExplorerBundle *> *refreshed = [ZSAssetExplorer cachedBundles:&refreshError];
            deliver(refreshed, refreshError);
            finalBundles = refreshed;
        }

        [ZSAssetExplorer resolveNamesForBundles:finalBundles
                                      batchSize:150
                                 shouldContinue:^BOOL{
            typeof(self) strongSelf = weakSelf;
            return strongSelf && strongSelf.assetExplorerFullScreenOpen && strongSelf.assetExplorerNamesSession == namesSession;
        }
                                        handler:^(NSArray<ZSAssetExplorerBundle *> *updated) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || strongSelf.assetExplorerNamesSession != namesSession) return;
                strongSelf.assetExplorerBundles = updated;
                if (!strongSelf.assetExplorerSelectedBundle) [strongSelf zs_assetExplorerRefreshListResettingScroll:NO];
            });
        }];
    });
}

- (void)zs_openAssetExplorerFullScreenPanel {
    if (!self.panelOpen) return;
    if (self.assetExplorerFullScreenOpen) return;

    [self zs_buildAssetExplorerFullScreenPanelIfNeeded];
    if (!self.assetExplorerFullScreenOverlay) return;

    if (self.docsLanguageDropdownOpen) {
        [self zs_closeDocsLanguageDropdownAnimated:NO];
    }
    if (self.syslogFullScreenOpen) {
        [self zs_syslogEndCommandBrowse];
        [self.syslogSearchField resignFirstResponder];
        self.syslogFullScreenOpen = NO;
        [self zs_syncSyslogButtonState];
    }
    if (self.memoryFullScreenOpen) {
        [self zs_endMemoryAnalysis];
    }
    [self zs_endDumperSession];

    self.docsActiveKey = nil;
    self.assetExplorerFullScreenOpen = YES;
    self.docsPanelOpen = YES;
    [self positionPanelAnimated:!self.extendedCoverEntering];
    if (self.modsLibraryBrowseMode) {
        [self zs_assetExplorerShowModLibrary];
    } else {
        [self zs_assetExplorerShowHub];
    }
}

- (void)zs_endAssetExplorerSession {
    if (!self.assetExplorerFullScreenOpen) return;
    [self.assetExplorerSearchField resignFirstResponder];
    self.assetExplorerGeneration += 1;
    self.assetExplorerFullScreenOpen = NO;
    self.assetExplorerSelectedBundle = nil;
    [self zs_assetExplorerSetTextureModeVisible:NO];
    self.assetExplorerAssets = @[];
    self.assetExplorerCloseButton.hidden = NO;
    self.assetExplorerBackButton.hidden = YES;
    self.assetExplorerFullScreenOverlay.hidden = YES;
    self.modsLibraryBrowseMode = NO;
    self.modsLibraryBrowseEntries = @[];
    self.modsLibraryDisplayedEntries = @[];
    self.modsLibraryDisplayedFolders = @[];
    self.modsLibrarySelectedFolder = nil;
    self.modsLibrarySelectedEntry = nil;
    self.assetExplorerFMODGeneration += 1;
    [ZSAssetExplorer unloadAllBundles];
    [self.assetExplorerThumbSource reset];
    [self zs_assetExplorerLocalizeReset];
    self.assetExplorerHubVisible = NO;
    self.assetExplorerFMODMode = NO;
    self.assetExplorerFMODBankFile = nil;
    self.assetExplorerFMODBank = nil;
    self.assetExplorerFMODStream = nil;
    self.assetExplorerFMODBankFiles = nil;
    self.assetExplorerFMODDisplayedBanks = nil;
    self.assetExplorerFMODDisplayedStreams = nil;
}

- (void)zs_assetExplorerApplyPreviewTransform {
    UIImageView *imageView = self.assetExplorerTextureImageView;
    if (!imageView) return;
    CGFloat scale = self.assetExplorerPreviewScale > 0 ? self.assetExplorerPreviewScale : 1;
    CGPoint offset = self.assetExplorerPreviewOffset;
    imageView.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(offset.x, offset.y), scale, scale);
    imageView.layer.magnificationFilter = scale >= 3 ? kCAFilterNearest : kCAFilterLinear;
}

static void zs_preview_axis_range(CGFloat clipLen, CGFloat winMin, CGFloat winMax, CGFloat scale, CGFloat *outLo, CGFloat *outHi) {
    CGFloat extra = MAX(0, clipLen * scale - clipLen);
    CGFloat a = extra / 2;
    CGFloat lo = -a;
    CGFloat hi = a;
    CGFloat winLen = winMax - winMin;
    if (a > 0 && winLen > clipLen + 0.5) {
        CGFloat t = MIN(1, extra / (winLen - clipLen));
        lo = -a + (winMax - clipLen) * t;
        hi = a + winMin * t;
        if (lo > hi) {
            CGFloat mid = (lo + hi) / 2;
            lo = mid;
            hi = mid;
        }
    }
    *outLo = lo;
    *outHi = hi;
}

- (CGPoint)zs_assetExplorerClampedPreviewOffset:(CGPoint)offset scale:(CGFloat)scale {
    UIView *clip = self.assetExplorerPreviewClipView;
    UIView *overlay = self.assetExplorerFullScreenOverlay;
    CGSize size = clip.bounds.size;
    CGRect window = CGRectMake(0, 0, size.width, size.height);
    if (clip && overlay && clip.window && overlay.window) {
        window = [clip convertRect:overlay.bounds fromView:overlay];
    }
    CGFloat loX, hiX, loY, hiY;
    zs_preview_axis_range(size.width, CGRectGetMinX(window), CGRectGetMaxX(window), scale, &loX, &hiX);
    zs_preview_axis_range(size.height, CGRectGetMinY(window), CGRectGetMaxY(window), scale, &loY, &hiY);
    offset.x = MIN(MAX(offset.x, loX), hiX);
    offset.y = MIN(MAX(offset.y, loY), hiY);
    return offset;
}

- (void)zs_assetExplorerResetPreviewZoomAnimated:(BOOL)animated {
    self.assetExplorerPreviewScale = 1;
    self.assetExplorerPreviewOffset = CGPointZero;
    if (!animated) {
        [self zs_assetExplorerApplyPreviewTransform];
        return;
    }
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction animations:^{
        [self zs_assetExplorerApplyPreviewTransform];
    } completion:nil];
}

- (void)zs_assetExplorerPreviewPinched:(UIPinchGestureRecognizer *)pinch {
    UIView *clip = self.assetExplorerPreviewClipView;
    if (!clip || !self.assetExplorerTextureOpen || self.assetExplorerTextureImageView.hidden) return;
    CGPoint center = CGPointMake(CGRectGetMidX(clip.bounds), CGRectGetMidY(clip.bounds));
    CGFloat currentScale = self.assetExplorerPreviewScale > 0 ? self.assetExplorerPreviewScale : 1;
    switch (pinch.state) {
        case UIGestureRecognizerStateBegan: {
            CGPoint location = [pinch locationInView:clip];
            self.assetExplorerPreviewGestureBaseScale = currentScale;
            self.assetExplorerPreviewGestureBaseOffset = self.assetExplorerPreviewOffset;
            self.assetExplorerPreviewGestureFocal = CGPointMake(location.x - center.x, location.y - center.y);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (pinch.numberOfTouches < 2) break;
            CGFloat base = self.assetExplorerPreviewGestureBaseScale > 0 ? self.assetExplorerPreviewGestureBaseScale : 1;
            CGFloat scale = MIN(MAX(base * pinch.scale, 0.4), 16);
            CGPoint startOffset = self.assetExplorerPreviewGestureBaseOffset;
            CGPoint startFocal = self.assetExplorerPreviewGestureFocal;
            CGPoint content = CGPointMake((startFocal.x - startOffset.x) / base, (startFocal.y - startOffset.y) / base);
            CGPoint location = [pinch locationInView:clip];
            CGPoint focal = CGPointMake(location.x - center.x, location.y - center.y);
            CGPoint offset = CGPointMake(focal.x - content.x * scale, focal.y - content.y * scale);
            self.assetExplorerPreviewScale = scale;
            self.assetExplorerPreviewOffset = [self zs_assetExplorerClampedPreviewOffset:offset scale:scale];
            [self zs_assetExplorerApplyPreviewTransform];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (currentScale < 1) {
                [self zs_assetExplorerResetPreviewZoomAnimated:YES];
            } else {
                self.assetExplorerPreviewOffset = [self zs_assetExplorerClampedPreviewOffset:self.assetExplorerPreviewOffset scale:currentScale];
                [self zs_assetExplorerApplyPreviewTransform];
            }
            break;
        default:
            break;
    }
}

- (void)zs_assetExplorerPreviewPanned:(UIPanGestureRecognizer *)pan {
    UIView *clip = self.assetExplorerPreviewClipView;
    if (!clip || !self.assetExplorerTextureOpen || self.assetExplorerTextureImageView.hidden) return;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.assetExplorerPreviewGestureBaseOffset = self.assetExplorerPreviewOffset;
        self.assetExplorerPreviewPanTouchCount = pan.numberOfTouches;
        return;
    }
    if (pan.state != UIGestureRecognizerStateChanged) return;
    if (pan.numberOfTouches != self.assetExplorerPreviewPanTouchCount) {
        self.assetExplorerPreviewPanTouchCount = pan.numberOfTouches;
        self.assetExplorerPreviewGestureBaseOffset = self.assetExplorerPreviewOffset;
        [pan setTranslation:CGPointZero inView:clip];
        return;
    }
    if (pan.numberOfTouches > 1) return;
    CGFloat scale = self.assetExplorerPreviewScale > 0 ? self.assetExplorerPreviewScale : 1;
    if (scale <= 1.01) return;
    CGPoint translation = [pan translationInView:clip];
    CGPoint base = self.assetExplorerPreviewGestureBaseOffset;
    CGPoint offset = CGPointMake(base.x + translation.x, base.y + translation.y);
    self.assetExplorerPreviewOffset = [self zs_assetExplorerClampedPreviewOffset:offset scale:scale];
    [self zs_assetExplorerApplyPreviewTransform];
}

- (void)zs_assetExplorerPreviewDoubleTapped:(UITapGestureRecognizer *)tap {
    UIView *clip = self.assetExplorerPreviewClipView;
    if (!clip || tap.state != UIGestureRecognizerStateEnded) return;
    CGFloat scale = self.assetExplorerPreviewScale > 0 ? self.assetExplorerPreviewScale : 1;
    if (fabs(scale - 1) > 0.01) {
        [self zs_assetExplorerResetPreviewZoomAnimated:YES];
        return;
    }
    CGPoint location = [tap locationInView:clip];
    CGPoint focal = CGPointMake(location.x - CGRectGetMidX(clip.bounds), location.y - CGRectGetMidY(clip.bounds));
    CGFloat target = 3;
    CGPoint offset = CGPointMake(focal.x - focal.x * target, focal.y - focal.y * target);
    self.assetExplorerPreviewScale = target;
    self.assetExplorerPreviewOffset = [self zs_assetExplorerClampedPreviewOffset:offset scale:target];
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction animations:^{
        [self zs_assetExplorerApplyPreviewTransform];
    } completion:nil];
}

- (void)zs_assetExplorerSetTextureModeVisible:(BOOL)visible {
    [self zs_assetExplorerResetPreviewZoomAnimated:NO];
    self.assetExplorerTextureOpen = visible;
    self.assetExplorerTableView.hidden = visible;
    self.assetExplorerTitleLabel.hidden = visible;
    self.assetExplorerStatusLabel.hidden = visible;
    self.assetExplorerBackButton.hidden = visible || self.assetExplorerSelectedBundle == nil;
    self.assetExplorerCloseButton.hidden = visible ? NO : (self.assetExplorerSelectedBundle != nil);
    self.assetExplorerTextureBackButton.hidden = !visible;
    self.assetExplorerTextureExportButton.hidden = !visible;
    [self zs_assetExplorerSyncSwapButton];
    self.assetExplorerTextureImageView.hidden = !visible;
    self.assetExplorerTextView.hidden = YES;
    self.assetExplorerTextView.text = @"";
    self.assetExplorerTextureCaptionLabel.hidden = !visible;
    if (!visible) [self zs_assetExplorerSetDebugText:nil];
    self.assetExplorerBackdropView.hidden = !visible;
    self.assetExplorerTexturePagerStack.hidden = !visible;
    self.assetExplorerModeControl.hidden = YES;
    if (visible) [self.assetExplorerSearchField resignFirstResponder];
    [self zs_assetExplorerSyncControls];
    if (!visible) {
        [self zs_assetExplorerStopLive];
        self.assetExplorerLivePaused = NO;
        self.assetExplorerLiveElapsed = 0;
        self.assetExplorerTextureImageView.alpha = 1;
        self.assetExplorerVisual = nil;
        self.assetExplorerPageIndex = 0;
        self.assetExplorerDataMode = NO;
        self.assetExplorerDataJSON = nil;
        self.assetExplorerDataToken += 1;
        self.assetExplorerModeControl.selectedIndex = 0;
        self.assetExplorerPageStack.hidden = YES;
        self.assetExplorerTextureAssets = nil;
        self.assetExplorerTextureIndex = 0;
        [self.assetExplorerTextureSpinner stopAnimating];
        self.assetExplorerTextureMessageLabel.hidden = YES;
        self.assetExplorerTextureMessageLabel.text = nil;
        self.assetExplorerTextureImageView.image = nil;
        self.assetExplorerTextureCaptionLabel.text = nil;
    }
}

- (void)zs_assetExplorerOpenTextureForAsset:(ZSAssetExplorerAsset *)asset {
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    if (!asset || !bundle || ![ZSAssetExplorer hasVisualPreviewForClassID:asset.classID] || self.assetExplorerTextureOpen) return;

    NSMutableArray<ZSAssetExplorerAsset *> *textures = [NSMutableArray array];
    for (ZSAssetExplorerAsset *candidate in self.assetExplorerDisplayedAssets) {
        if ([ZSAssetExplorer hasVisualPreviewForClassID:candidate.classID] && [ZSAssetExplorer classID:asset.classID sharesPreviewGroupWithClassID:candidate.classID]) [textures addObject:candidate];
    }
    NSUInteger index = [textures indexOfObjectIdenticalTo:asset];
    if (index == NSNotFound) {
        textures = [NSMutableArray arrayWithObject:asset];
        index = 0;
    }

    [self zs_assetExplorerSetTextureModeVisible:YES];
    self.assetExplorerTextureAssets = textures;
    self.assetExplorerTextureIndex = (NSInteger)index;
    [self zs_assetExplorerLoadTextureAtCurrentIndex];
}

- (void)zs_assetExplorerSetDebugText:(NSString *)text {
    UILabel *label = self.assetExplorerDebugLabel;
    BOOL show = text.length > 0 && self.assetExplorerTextureOpen && !self.assetExplorerDataMode;
    label.text = show ? text : nil;
    label.hidden = !show;
}

- (void)zs_assetExplorerLoadTextureAtCurrentIndex {
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    NSInteger index = self.assetExplorerTextureIndex;
    if (!bundle || index < 0 || index >= (NSInteger)self.assetExplorerTextureAssets.count) return;
    ZSAssetExplorerAsset *asset = self.assetExplorerTextureAssets[(NSUInteger)index];

    self.assetExplorerGeneration += 1;
    NSUInteger generation = self.assetExplorerGeneration;
    [self zs_assetExplorerStopLive];
    self.assetExplorerLivePaused = NO;
    self.assetExplorerLiveElapsed = 0;
    self.assetExplorerTextureImageView.alpha = 1;
    self.assetExplorerVisual = nil;
    self.assetExplorerPageIndex = 0;
    self.assetExplorerDataJSON = nil;
    self.assetExplorerDataToken += 1;
    self.assetExplorerModeControl.hidden = YES;
    [self zs_assetExplorerResetPreviewZoomAnimated:NO];
    self.assetExplorerTextureImageView.image = nil;
    self.assetExplorerTextureImageView.hidden = NO;
    self.assetExplorerTextView.hidden = YES;
    self.assetExplorerTextView.text = @"";
    self.assetExplorerBackdropView.hidden = NO;
    self.assetExplorerTextureMessageLabel.hidden = YES;
    self.assetExplorerTextureCaptionLabel.text = asset.assetName.length > 0 ? asset.assetName : asset.typeName;
    [self zs_assetExplorerSetDebugText:nil];
    [self.assetExplorerTextureSpinner startAnimating];
    self.assetExplorerTextureExportButton.enabled = NO;
    self.assetExplorerTextureExportButton.alpha = 0.35;
    [self zs_assetExplorerSyncSwapButton];
    [self zs_assetExplorerSyncTexturePager];
    [self zs_assetExplorerSyncPagePager];

    __weak typeof(self) weakSelf = self;
    NSString *bundlePath = [bundle.filePath copy];
    int64_t pathID = asset.pathID;
    int32_t classID = asset.classID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        ZSAssetExplorerVisual *visual = [ZSAssetExplorer visualForPathID:pathID classID:classID inBundleAtPath:bundlePath error:&error];
        BOOL isText = visual.text.length > 0;
        UIImage *image = (visual && !isText) ? [visual imageAtPage:0 error:&error] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || !strongSelf.assetExplorerTextureOpen || strongSelf.assetExplorerGeneration != generation) return;
            [strongSelf.assetExplorerTextureSpinner stopAnimating];
            if (visual) {
                strongSelf.assetExplorerVisual = visual;
                strongSelf.assetExplorerPageIndex = 0;
                NSString *summary = visual.summary.length > 0 ? visual.summary : visual.name;
                if (isText) summary = [NSString stringWithFormat:@"%@  •  %@", asset.typeName ?: @"Asset", summary ?: @""];
                strongSelf.assetExplorerTextureCaptionLabel.text = summary;
                [strongSelf zs_assetExplorerSetDebugText:visual.debugText];
                [strongSelf zs_assetExplorerSyncPagePager];
                [strongSelf zs_assetExplorerSyncModeControl];
            }
            if (isText) {
                strongSelf.assetExplorerTextureImageView.hidden = YES;
                strongSelf.assetExplorerBackdropView.hidden = YES;
                strongSelf.assetExplorerTextView.text = visual.text;
                strongSelf.assetExplorerTextView.hidden = NO;
                [strongSelf.assetExplorerTextView setContentOffset:CGPointZero animated:NO];
                strongSelf.assetExplorerTextureExportButton.enabled = YES;
                strongSelf.assetExplorerTextureExportButton.alpha = 1;
            } else if (image) {
                strongSelf.assetExplorerTextureImageView.image = image;
                strongSelf.assetExplorerTextureExportButton.enabled = YES;
                strongSelf.assetExplorerTextureExportButton.alpha = 1;
                [strongSelf zs_assetExplorerSyncSwapButton];
                if (strongSelf.assetExplorerDataMode) [strongSelf zs_assetExplorerApplyDisplayMode];
                else [strongSelf zs_assetExplorerStartLiveFromElapsed:0];
            } else {
                strongSelf.assetExplorerTextureMessageLabel.text = error.localizedDescription ?: @"Couldn't decode this asset.";
                strongSelf.assetExplorerTextureMessageLabel.hidden = NO;
                if (visual && strongSelf.assetExplorerDataMode) [strongSelf zs_assetExplorerApplyDisplayMode];
            }
        });
    });
}

- (void)zs_assetExplorerSyncModeControl {
    ZSAssetExplorerVisual *visual = self.assetExplorerVisual;
    BOOL available = self.assetExplorerTextureOpen && visual != nil && visual.text.length == 0;
    self.assetExplorerModeControl.hidden = !available;
    [self.assetExplorerModeControl setGlassEnabled:available];
    [self.assetExplorerModeControl setSelectedIndex:self.assetExplorerDataMode ? 1 : 0 animated:NO];
    [self zs_assetExplorerSyncSwapButton];
}

- (void)zs_assetExplorerModeChanged:(ZSModeSlider *)control {
    if (self.assetExplorerLocalizeMode) {
        [self zs_assetExplorerLocalizeModeChanged:control];
        return;
    }
    BOOL dataMode = control.selectedIndex == 1;
    if (dataMode == self.assetExplorerDataMode) return;
    self.assetExplorerDataMode = dataMode;
    [self zs_assetExplorerApplyDisplayMode];
}

- (void)zs_assetExplorerApplyDisplayMode {
    ZSAssetExplorerVisual *visual = self.assetExplorerVisual;
    if (!self.assetExplorerTextureOpen || !visual || visual.text.length > 0) return;
    [self zs_assetExplorerSyncModeControl];
    if (self.assetExplorerDataMode) {
        [self zs_assetExplorerStopLive];
        [self zs_assetExplorerResetPreviewZoomAnimated:NO];
        self.assetExplorerTextureImageView.hidden = YES;
        self.assetExplorerBackdropView.hidden = YES;
        self.assetExplorerTextureMessageLabel.hidden = YES;
        [self zs_assetExplorerSetDebugText:nil];
        [self.assetExplorerTextureSpinner stopAnimating];
        [self zs_assetExplorerSyncPagePager];
        [self zs_assetExplorerLoadDataForCurrentAsset];
        return;
    }
    [self zs_assetExplorerSetDebugText:visual.debugText];
    self.assetExplorerDataToken += 1;
    self.assetExplorerTextView.hidden = YES;
    self.assetExplorerTextView.text = @"";
    self.assetExplorerTextureMessageLabel.hidden = YES;
    self.assetExplorerTextureImageView.hidden = NO;
    self.assetExplorerBackdropView.hidden = NO;
    [self zs_assetExplorerSyncPagePager];
    UIImage *image = self.assetExplorerTextureImageView.image;
    if (image) {
        self.assetExplorerTextureExportButton.enabled = YES;
        self.assetExplorerTextureExportButton.alpha = 1;
        [self zs_assetExplorerStartLiveFromElapsed:self.assetExplorerLiveElapsed];
    } else {
        [self zs_assetExplorerLoadPage:self.assetExplorerPageIndex];
    }
}

- (void)zs_assetExplorerShowDataJSON {
    NSData *json = self.assetExplorerDataJSON;
    if (!json || !self.assetExplorerDataMode) return;
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"";
    self.assetExplorerTextureMessageLabel.hidden = YES;
    self.assetExplorerTextView.text = text;
    self.assetExplorerTextView.hidden = NO;
    [self.assetExplorerTextView setContentOffset:CGPointZero animated:NO];
    self.assetExplorerTextureExportButton.enabled = YES;
    self.assetExplorerTextureExportButton.alpha = 1;
}

- (void)zs_assetExplorerLoadDataForCurrentAsset {
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    NSInteger index = self.assetExplorerTextureIndex;
    if (!bundle || index < 0 || index >= (NSInteger)self.assetExplorerTextureAssets.count) return;
    ZSAssetExplorerAsset *asset = self.assetExplorerTextureAssets[(NSUInteger)index];

    if (self.assetExplorerDataJSON) {
        [self zs_assetExplorerShowDataJSON];
        return;
    }

    self.assetExplorerDataToken += 1;
    NSUInteger token = self.assetExplorerDataToken;
    NSUInteger generation = self.assetExplorerGeneration;
    self.assetExplorerTextView.hidden = YES;
    self.assetExplorerTextView.text = @"";
    [self.assetExplorerTextureSpinner startAnimating];
    self.assetExplorerTextureExportButton.enabled = NO;
    self.assetExplorerTextureExportButton.alpha = 0.35;

    __weak typeof(self) weakSelf = self;
    NSString *bundlePath = [bundle.filePath copy];
    int64_t pathID = asset.pathID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *json = [ZSAssetExplorer jsonDataForPathID:pathID inBundleAtPath:bundlePath error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || !strongSelf.assetExplorerTextureOpen) return;
            if (strongSelf.assetExplorerGeneration != generation || strongSelf.assetExplorerDataToken != token || !strongSelf.assetExplorerDataMode) return;
            [strongSelf.assetExplorerTextureSpinner stopAnimating];
            if (json) {
                strongSelf.assetExplorerDataJSON = json;
                [strongSelf zs_assetExplorerShowDataJSON];
            } else {
                strongSelf.assetExplorerTextureMessageLabel.text = error.localizedDescription ?: @"Couldn't read this asset's data.";
                strongSelf.assetExplorerTextureMessageLabel.hidden = NO;
            }
        });
    });
}

- (void)zs_assetExplorerLoadPage:(NSInteger)page {
    ZSAssetExplorerVisual *visual = self.assetExplorerVisual;
    if (!visual) return;

    self.assetExplorerGeneration += 1;
    NSUInteger generation = self.assetExplorerGeneration;
    [self zs_assetExplorerStopLive];
    self.assetExplorerLivePaused = NO;
    self.assetExplorerLiveElapsed = 0;
    self.assetExplorerTextureImageView.alpha = 1;
    [self zs_assetExplorerResetPreviewZoomAnimated:NO];
    self.assetExplorerTextureImageView.image = nil;
    self.assetExplorerTextureMessageLabel.hidden = YES;
    [self.assetExplorerTextureSpinner startAnimating];
    self.assetExplorerTextureExportButton.enabled = NO;
    self.assetExplorerTextureExportButton.alpha = 0.35;
    [self zs_assetExplorerSyncPagePager];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        UIImage *image = [visual imageAtPage:page error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || !strongSelf.assetExplorerTextureOpen || strongSelf.assetExplorerGeneration != generation) return;
            [strongSelf.assetExplorerTextureSpinner stopAnimating];
            if (image) {
                strongSelf.assetExplorerTextureImageView.image = image;
                strongSelf.assetExplorerTextureExportButton.enabled = YES;
                strongSelf.assetExplorerTextureExportButton.alpha = 1;
                [strongSelf zs_assetExplorerStartLiveFromElapsed:0];
            } else {
                strongSelf.assetExplorerTextureMessageLabel.text = error.localizedDescription ?: @"Couldn't decode this page.";
                strongSelf.assetExplorerTextureMessageLabel.hidden = NO;
            }
        });
    });
}

static dispatch_queue_t zs_asset_explorer_live_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        queue = dispatch_queue_create("zs.assetexplorer.live", attributes);
    });
    return queue;
}

- (void)zs_assetExplorerStopLive {
    self.assetExplorerLiveToken += 1;
    dispatch_source_t timer = self.assetExplorerLiveTimer;
    self.assetExplorerLiveTimer = nil;
    if (timer) dispatch_source_cancel(timer);
}

- (void)zs_assetExplorerStartLiveFromElapsed:(NSTimeInterval)startElapsed {
    [self zs_assetExplorerStopLive];
    ZSAssetExplorerVisual *visual = self.assetExplorerVisual;
    NSInteger page = self.assetExplorerPageIndex;
    if (!visual || ![visual isLivePage:page] || self.assetExplorerLivePaused || !self.assetExplorerTextureOpen) return;

    NSUInteger token = self.assetExplorerLiveToken;
    ZSAssetExplorerLiveFrameProvider provider = visual.liveFrameProvider;
    ZSAssetExplorerLiveDebugProvider debugProvider = visual.liveDebugProvider;
    dispatch_queue_t queue = zs_asset_explorer_live_queue();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    uint64_t interval = NSEC_PER_SEC / 30;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);

    __weak typeof(self) weakSelf = self;
    __block BOOL pending = NO;
    __block CFTimeInterval origin = CACurrentMediaTime() - startElapsed;
    dispatch_source_set_event_handler(timer, ^{
        if (pending) return;
        NSTimeInterval elapsed = CACurrentMediaTime() - origin;
        UIImage *frame = provider(elapsed);
        if (!frame) return;
        NSString *debugLine = debugProvider ? debugProvider(elapsed) : nil;
        pending = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            BOOL current = strongSelf && strongSelf.assetExplorerLiveToken == token;
            if (current) {
                if (strongSelf.assetExplorerFullScreenOpen && strongSelf.assetExplorerTextureOpen && strongSelf.assetExplorerVisual == visual && strongSelf.assetExplorerPageIndex == page) {
                    strongSelf.assetExplorerTextureImageView.image = frame;
                    if (debugLine.length > 0 && !strongSelf.assetExplorerDebugLabel.hidden) strongSelf.assetExplorerDebugLabel.text = debugLine;
                    strongSelf.assetExplorerLiveElapsed = elapsed;
                } else {
                    [strongSelf zs_assetExplorerStopLive];
                }
            }
            dispatch_async(queue, ^{
                pending = NO;
            });
        });
    });
    self.assetExplorerLiveTimer = timer;
    dispatch_resume(timer);
}

- (void)zs_assetExplorerPreviewTapped {
    ZSAssetExplorerVisual *visual = self.assetExplorerVisual;
    if (!self.assetExplorerTextureOpen || !visual || ![visual isLivePage:self.assetExplorerPageIndex] || !self.assetExplorerTextureImageView.image) return;
    if (self.assetExplorerLiveTimer) {
        self.assetExplorerLivePaused = YES;
        [self zs_assetExplorerStopLive];
        [UIView animateWithDuration:0.15 animations:^{
            self.assetExplorerTextureImageView.alpha = 0.55;
        }];
    } else {
        self.assetExplorerLivePaused = NO;
        [UIView animateWithDuration:0.15 animations:^{
            self.assetExplorerTextureImageView.alpha = 1;
        }];
        [self zs_assetExplorerStartLiveFromElapsed:self.assetExplorerLiveElapsed];
    }
}

- (void)zs_assetExplorerSyncPagePager {
    ZSAssetExplorerVisual *visual = self.assetExplorerVisual;
    NSInteger count = visual ? (NSInteger)visual.pageLabels.count : 0;
    NSInteger index = self.assetExplorerPageIndex;
    BOOL showingData = self.assetExplorerDataMode && visual && visual.text.length == 0;
    BOOL show = self.assetExplorerTextureOpen && count > 1 && !showingData;
    self.assetExplorerPageStack.hidden = !show;
    if (!show) return;
    NSString *label = index >= 0 && index < count ? visual.pageLabels[(NSUInteger)index] : @"";
    self.assetExplorerPageLabel.text = [NSString stringWithFormat:@"%@  •  %ld/%ld", label, (long)(index + 1), (long)count];
    BOOL hasPrevious = index > 0;
    BOOL hasNext = index + 1 < count;
    self.assetExplorerPagePrevButton.enabled = hasPrevious;
    self.assetExplorerPagePrevButton.alpha = hasPrevious ? 1 : 0.35;
    self.assetExplorerPageNextButton.enabled = hasNext;
    self.assetExplorerPageNextButton.alpha = hasNext ? 1 : 0.35;
}

- (void)zs_assetExplorerStepPage:(NSInteger)delta {
    ZSAssetExplorerVisual *visual = self.assetExplorerVisual;
    if (!self.assetExplorerTextureOpen || !visual) return;
    NSInteger target = self.assetExplorerPageIndex + delta;
    if (target < 0 || target >= (NSInteger)visual.pageLabels.count) return;
    self.assetExplorerPageIndex = target;
    [self zs_assetExplorerLoadPage:target];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_assetExplorerPagePrevTapped {
    [self zs_assetExplorerStepPage:-1];
}

- (void)zs_assetExplorerPageNextTapped {
    [self zs_assetExplorerStepPage:1];
}

- (void)zs_assetExplorerSyncTexturePager {
    NSInteger count = (NSInteger)self.assetExplorerTextureAssets.count;
    NSInteger index = self.assetExplorerTextureIndex;
    self.assetExplorerTexturePositionLabel.text = count > 0 ? [NSString stringWithFormat:@"%ld/%ld", (long)(index + 1), (long)count] : @"";
    BOOL hasPrevious = index > 0;
    BOOL hasNext = index + 1 < count;
    self.assetExplorerTexturePrevButton.enabled = hasPrevious;
    self.assetExplorerTexturePrevButton.alpha = hasPrevious ? 1 : 0.35;
    self.assetExplorerTextureNextButton.enabled = hasNext;
    self.assetExplorerTextureNextButton.alpha = hasNext ? 1 : 0.35;
}

- (void)zs_assetExplorerStepTexture:(NSInteger)delta {
    if (!self.assetExplorerTextureOpen) return;
    NSInteger target = self.assetExplorerTextureIndex + delta;
    if (target < 0 || target >= (NSInteger)self.assetExplorerTextureAssets.count) return;
    self.assetExplorerTextureIndex = target;
    [self zs_assetExplorerLoadTextureAtCurrentIndex];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_assetExplorerTextureExportTapped {
    if (self.assetExplorerLocalizeMode) {
        [self zs_assetExplorerLocalizeExportTapped];
        return;
    }
    if (self.assetExplorerFMODMode) {
        [self zs_assetExplorerFMODExportStreamTapped];
        return;
    }
    UIImage *image = self.assetExplorerTextureImageView.image;
    ZSAssetExplorerVisual *textVisual = self.assetExplorerVisual;
    BOOL isDataExport = self.assetExplorerDataMode && self.assetExplorerDataJSON.length > 0 && textVisual != nil && textVisual.text.length == 0;
    BOOL isVideoExport = !isDataExport && textVisual.text.length == 0 && textVisual.exportData.length > 0 && textVisual.fileExtension.length > 0;
    BOOL isTextExport = isDataExport || isVideoExport || textVisual.text.length > 0;
    NSData *textData = isDataExport ? self.assetExplorerDataJSON : (isTextExport ? (textVisual.exportData ?: [textVisual.text dataUsingEncoding:NSUTF8StringEncoding]) : nil);
    NSInteger index = self.assetExplorerTextureIndex;
    if ((!image && !isTextExport) || !self.assetExplorerTextureOpen || index < 0 || index >= (NSInteger)self.assetExplorerTextureAssets.count) return;

    ZSAssetExplorerAsset *asset = self.assetExplorerTextureAssets[(NSUInteger)index];
    NSString *baseName = asset.assetName.length > 0 ? asset.assetName : [NSString stringWithFormat:@"%@_%lld", asset.typeName.length > 0 ? asset.typeName : @"Asset", (long long)asset.pathID];
    ZSAssetExplorerVisual *exportVisual = self.assetExplorerVisual;
    NSInteger exportPage = self.assetExplorerPageIndex;
    if (isDataExport) {
        baseName = [baseName stringByAppendingString:@"_data"];
    } else if (exportVisual.pageLabels.count > 1 && exportPage >= 0 && exportPage < (NSInteger)exportVisual.pageLabels.count) {
        baseName = [baseName stringByAppendingFormat:@"_%@", exportVisual.pageLabels[(NSUInteger)exportPage]];
    }
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-_. "];
    NSMutableString *safeName = [NSMutableString string];
    for (NSUInteger i = 0; i < baseName.length; i++) {
        unichar c = [baseName characterAtIndex:i];
        [safeName appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }

    UIButton *sourceButton = self.assetExplorerTextureExportButton;
    sourceButton.enabled = NO;
    __weak typeof(self) weakSelf = self;
    NSString *fileExtension = isDataExport ? @"json" : (isTextExport ? (textVisual.fileExtension.length > 0 ? textVisual.fileExtension : @"txt") : @"png");
    NSString *fileName = [safeName stringByAppendingPathExtension:fileExtension];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *png = isTextExport ? textData : UIImagePNGRepresentation(image);
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSAssetExport-%@", NSUUID.UUID.UUIDString]];
        NSString *path = [directory stringByAppendingPathComponent:fileName];
        BOOL written = NO;
        if (png.length > 0 && [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
            written = [png writeToFile:path atomically:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.assetExplorerTextureImageView.image || isTextExport) {
                sourceButton.enabled = YES;
            }
            if (!written || !strongSelf.assetExplorerTextureOpen) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
                return;
            }
            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
            activityVC.popoverPresentationController.sourceView = sourceButton;
            activityVC.popoverPresentationController.sourceRect = sourceButton.bounds;
            activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
            };
            UIViewController *presenter = zs_key_window().rootViewController;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            [presenter presentViewController:activityVC animated:YES completion:nil];
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
        });
    });
}

- (ZSAssetExplorerAsset *)zs_assetExplorerCurrentSwappableTexture {
    if (!self.assetExplorerTextureOpen || self.assetExplorerLocalizeMode || self.assetExplorerFMODMode || self.assetExplorerDataMode || self.assetExplorerSwapBusy) return nil;
    NSInteger index = self.assetExplorerTextureIndex;
    if (index < 0 || index >= (NSInteger)self.assetExplorerTextureAssets.count) return nil;
    ZSAssetExplorerAsset *asset = self.assetExplorerTextureAssets[(NSUInteger)index];
    ZSAssetExplorerVisual *visual = self.assetExplorerVisual;
    if (asset.classID != 28 || !visual || visual.text.length > 0 || !self.assetExplorerTextureImageView.image) return nil;
    return asset;
}

- (void)zs_assetExplorerSyncSwapButton {
    UIButton *button = self.assetExplorerTextureSwapButton;
    if (!button) return;
    BOOL available = [self zs_assetExplorerCurrentSwappableTexture] != nil;
    button.hidden = !available;
    self.assetExplorerTextureSwapLeading.constant = available ? 8 : 0;
    self.assetExplorerTextureSwapWidth.constant = available ? 30 : 0;
}

- (UIViewController *)zs_assetExplorerSwapPresenter {
    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    return presenter;
}

- (void)zs_assetExplorerTextureSwapTapped {
    if (![self zs_assetExplorerCurrentSwappableTexture]) return;
    UIViewController *presenter = [self zs_assetExplorerSwapPresenter];
    if (!presenter) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Swap texture" message:@"Choose an image to replace this texture with." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf zs_assetExplorerSwapPickFromFiles];
    }]];
    if (@available(iOS 14.0, *)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Photos" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf zs_assetExplorerSwapPickFromPhotos];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIButton *source = self.assetExplorerTextureSwapButton;
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)zs_assetExplorerSwapPickFromFiles {
    if (![self zs_assetExplorerCurrentSwappableTexture]) return;
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.image"] inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    UIViewController *presenter = [self zs_assetExplorerSwapPresenter];
    if (!presenter) return;
    self.assetExplorerSwapDocumentPicker = picker;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_assetExplorerSwapPickFromPhotos {
    if (![self zs_assetExplorerCurrentSwappableTexture]) return;
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
        configuration.filter = [PHPickerFilter imagesFilter];
        configuration.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
        picker.delegate = (id<PHPickerViewControllerDelegate>)self;
        UIViewController *presenter = [self zs_assetExplorerSwapPresenter];
        if (!presenter) return;
        [presenter presentViewController:picker animated:YES completion:nil];
    }
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    PHPickerResult *result = results.firstObject;
    if (!result) {
        [picker dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    NSItemProvider *provider = result.itemProvider;
    NSString *identifier = UTTypeImage.identifier;
    for (NSString *registered in provider.registeredTypeIdentifiers) {
        UTType *type = [UTType typeWithIdentifier:registered];
        if (type && [type conformsToType:UTTypeImage]) {
            identifier = registered;
            break;
        }
    }
    dispatch_group_t group = dispatch_group_create();
    __block NSString *staged = nil;
    __block NSString *displayName = nil;
    NSString *suggestedName = provider.suggestedName;
    dispatch_group_enter(group);
    [provider loadFileRepresentationForTypeIdentifier:identifier completionHandler:^(NSURL *url, NSError *error) {
        if (url) {
            NSString *extension = url.pathExtension.length > 0 ? url.pathExtension : @"img";
            NSString *destination = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSSwapImage-%@.%@", NSUUID.UUID.UUIDString, extension]];
            if ([NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:nil]) {
                staged = destination;
                displayName = suggestedName.length > 0 ? [suggestedName stringByAppendingPathExtension:extension] : url.lastPathComponent;
            }
        }
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [picker dismissViewControllerAnimated:YES completion:^{
        dispatch_group_leave(group);
    }];
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            if (staged) [NSFileManager.defaultManager removeItemAtPath:staged error:nil];
            return;
        }
        if (staged) [strongSelf zs_assetExplorerSwapPickedImagePath:staged displayName:displayName];
        else [strongSelf zs_presentModsAlertWithTitle:@"Swap failed" message:@"Couldn't load the selected photo."];
    });
}

- (void)zs_assetExplorerSwapPickedImageURL:(NSURL *)url {
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *staged = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSSwapImage-%@.%@", NSUUID.UUID.UUIDString, url.pathExtension.length > 0 ? url.pathExtension : @"img"]];
    BOOL copied = [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:staged] error:nil];
    NSString *displayName = url.lastPathComponent;
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!copied) {
        [self zs_presentModsAlertWithTitle:@"Swap failed" message:@"Couldn't read the selected file."];
        return;
    }
    [self zs_assetExplorerSwapPickedImagePath:staged displayName:displayName];
}

- (void)zs_assetExplorerSwapPickedImagePath:(NSString *)path displayName:(NSString *)displayName {
    ZSAssetExplorerAsset *asset = [self zs_assetExplorerCurrentSwappableTexture];
    UIViewController *presenter = [self zs_assetExplorerSwapPresenter];
    if (!asset || !presenter) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return;
    }
    NSString *textureName = asset.assetName.length > 0 ? asset.assetName : [NSString stringWithFormat:@"%@ %lld", asset.typeName ?: @"Texture2D", (long long)asset.pathID];
    NSString *fileName = displayName.length > 0 ? displayName : path.lastPathComponent;
    NSString *title = [NSString stringWithFormat:@"Swap %@ for %@?", textureName, fileName];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Swap" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf zs_assetExplorerSwapPerformWithImagePath:path];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_assetExplorerSwapPerformWithImagePath:(NSString *)path {
    ZSAssetExplorerAsset *asset = [self zs_assetExplorerCurrentSwappableTexture];
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    if (!asset || !bundle) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return;
    }
    self.assetExplorerSwapBusy = YES;
    [self zs_assetExplorerSyncSwapButton];
    self.assetExplorerTextureExportButton.enabled = NO;
    self.assetExplorerTextureExportButton.alpha = 0.35;
    self.assetExplorerTextureCaptionLabel.text = @"Swapping texture…";
    [self.assetExplorerTextureSpinner startAnimating];

    __weak typeof(self) weakSelf = self;
    NSString *bundlePath = [bundle.filePath copy];
    int64_t pathID = asset.pathID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = NO;
        NSArray<ZSAssetExplorerAsset *> *assets = nil;
        @autoreleasepool {
            [ZSAssetExplorer unloadBundleAtPath:bundlePath];
            ok = [ZTTextureSwapper swapTexturePathID:pathID inBundleAtPath:bundlePath withImageAtPath:path error:&error];
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            [ZSAssetExplorer unloadBundleAtPath:bundlePath];
            [ZSAssetExplorer loadBundleIntoMemoryAtPath:bundlePath error:nil];
            if (ok) assets = [ZSAssetExplorer assetsForBundleAtPath:bundlePath error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.assetExplorerSwapBusy = NO;
            [strongSelf.assetExplorerTextureSpinner stopAnimating];
            BOOL stillHere = strongSelf.assetExplorerFullScreenOpen && [strongSelf.assetExplorerSelectedBundle.filePath isEqualToString:bundlePath];
            if (ok && stillHere) {
                if (assets) strongSelf.assetExplorerAssets = assets;
                [strongSelf.assetExplorerThumbSource reset];
                [strongSelf zs_assetExplorerRefreshListResettingScroll:NO];
                if (strongSelf.assetExplorerTextureOpen) [strongSelf zs_assetExplorerLoadTextureAtCurrentIndex];
            } else if (stillHere && strongSelf.assetExplorerTextureOpen) {
                [strongSelf zs_assetExplorerLoadTextureAtCurrentIndex];
            }
            if (ok) {
                UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
                [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            } else {
                [strongSelf zs_presentModsAlertWithTitle:@"Swap failed" message:error.localizedDescription ?: @"The texture couldn't be swapped."];
            }
        });
    });
}

- (void)zs_assetExplorerTexturePrevTapped {
    [self zs_assetExplorerStepTexture:-1];
}

- (void)zs_assetExplorerTextureNextTapped {
    [self zs_assetExplorerStepTexture:1];
}

- (void)zs_assetExplorerTextureBackTapped {
    if (self.assetExplorerLocalizeMode) {
        [self zs_assetExplorerLocalizeCloseFile];
        return;
    }
    if (self.assetExplorerFMODMode) {
        [self zs_assetExplorerFMODCloseStream];
        return;
    }
    if (!self.assetExplorerTextureOpen) return;
    self.assetExplorerGeneration += 1;
    NSInteger currentIndex = self.assetExplorerTextureIndex;
    ZSAssetExplorerAsset *current = currentIndex >= 0 && currentIndex < (NSInteger)self.assetExplorerTextureAssets.count ? self.assetExplorerTextureAssets[(NSUInteger)currentIndex] : nil;
    [self zs_assetExplorerSetTextureModeVisible:NO];
    NSUInteger row = current ? [self.assetExplorerDisplayedAssets indexOfObjectIdenticalTo:current] : NSNotFound;
    if (row != NSNotFound) {
        [self.assetExplorerTableView layoutIfNeeded];
        [self.assetExplorerTableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)row inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
    }
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_closeAssetExplorerFullScreenPanelTapped {
    if (!self.assetExplorerFullScreenOpen) return;
    [self.assetExplorerSearchField resignFirstResponder];
    [self closeDocsPanel];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_assetExplorerBackTapped {
    if (self.modsLibraryBrowseMode) {
        if (!self.modsLibrarySelectedEntry) {
            [self zs_modsLibraryNavigateUpFromFolder];
            return;
        }
        self.modsLibrarySelectedEntry = nil;
        self.assetExplorerTextView.hidden = YES;
        self.assetExplorerTableView.hidden = NO;
        self.assetExplorerCloseButton.hidden = NO;
        self.assetExplorerBackButton.hidden = YES;
        self.assetExplorerTitleLabel.hidden = NO;
        self.assetExplorerTitleLabel.text = @"Mod Library";
        self.assetExplorerStatusLabel.hidden = NO;
        self.assetExplorerTextureCaptionLabel.hidden = YES;
        [self zs_assetExplorerSyncControls];
        [self zs_assetExplorerRefreshListResettingScroll:NO];
        UIImpactFeedbackGenerator *libraryHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [libraryHaptic impactOccurred];
        return;
    }
    if (self.assetExplorerLocalizeMode) {
        [self zs_assetExplorerLocalizeBackTapped];
        return;
    }
    if (self.assetExplorerFMODMode) {
        [self zs_assetExplorerFMODBackTapped];
        return;
    }
    if (!self.assetExplorerSelectedBundle) {
        [self zs_assetExplorerShowHub];
        UIImpactFeedbackGenerator *hubHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [hubHaptic impactOccurred];
        return;
    }
    [self.assetExplorerSearchField resignFirstResponder];
    self.assetExplorerGeneration += 1;
    self.assetExplorerSelectedBundle = nil;
    self.assetExplorerAssets = @[];
    self.assetExplorerCloseButton.hidden = YES;
    self.assetExplorerTitleLabel.text = @"Asset Explorer";
    self.assetExplorerStatusMessage = nil;
    self.assetExplorerBackButton.hidden = NO;
    self.assetExplorerTableView.hidden = NO;
    [self zs_assetExplorerResetViewState];
    BOOL restoring = self.assetExplorerListRestorePending;
    if (restoring) self.assetExplorerSearchField.text = self.assetExplorerListSavedQuery ?: @"";
    [self zs_assetExplorerRefreshListResettingScroll:!restoring];
    [self zs_assetExplorerRestoreListPosition];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_assetExplorerOpenBundle:(ZSAssetExplorerBundle *)bundle {
    [self zs_assetExplorerOpenBundle:bundle focusLocation:nil];
}

- (void)zs_assetExplorerFocusLocation:(ZSAssetLocation *)location {
    if (!location || !self.assetExplorerSelectedBundle) return;
    ZSAssetExplorerAsset *target = nil;
    for (ZSAssetExplorerAsset *candidate in self.assetExplorerAssets) {
        if (candidate.pathID == location.pathID && candidate.classID == location.classID) { target = candidate; break; }
    }
    if (!target) {
        for (ZSAssetExplorerAsset *candidate in self.assetExplorerAssets) {
            if (candidate.pathID == location.pathID) { target = candidate; break; }
        }
    }
    if (!target) return;

    NSUInteger row = [self.assetExplorerDisplayedAssets indexOfObjectIdenticalTo:target];
    if (row != NSNotFound && (NSInteger)row < [self.assetExplorerTableView numberOfRowsInSection:0]) {
        [self.assetExplorerTableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)row inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
    }
    [self zs_assetExplorerOpenTextureForAsset:target];
}

- (void)zs_assetExplorerOpenBundle:(ZSAssetExplorerBundle *)bundle focusLocation:(ZSAssetLocation *)focusLocation {
    if (!bundle || self.assetExplorerSelectedBundle) return;
    [self zs_assetExplorerCaptureListPosition];
    [self zs_assetExplorerBookmarks];
    self.assetExplorerRecentKey = zs_asset_explorer_bundle_key(bundle);
    [self zs_assetExplorerPersistState];
    self.assetExplorerGeneration += 1;
    NSUInteger generation = self.assetExplorerGeneration;
    self.assetExplorerSelectedBundle = bundle;
    self.assetExplorerAssets = @[];
    self.assetExplorerCloseButton.hidden = YES;
    self.assetExplorerTitleLabel.text = [self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForBundle:bundle]] ?: bundle.displayName;
    self.assetExplorerStatusMessage = @"Reading…";
    self.assetExplorerBackButton.hidden = NO;
    self.assetExplorerTableView.hidden = NO;
    [self zs_assetExplorerResetViewState];
    [self zs_assetExplorerRefreshListResettingScroll:YES];

    __weak typeof(self) weakSelf = self;
    NSString *bundlePath = [bundle.filePath copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        [ZSAssetExplorer loadBundleIntoMemoryAtPath:bundlePath error:nil];
        NSArray<ZSAssetExplorerAsset *> *assets = [ZSAssetExplorer assetsForBundleAtPath:bundlePath error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || strongSelf.assetExplorerGeneration != generation) {
                if (!strongSelf || ![strongSelf.assetExplorerSelectedBundle.filePath isEqualToString:bundlePath]) [ZSAssetExplorer unloadBundleAtPath:bundlePath];
                return;
            }
            strongSelf.assetExplorerAssets = assets ?: @[];
            strongSelf.assetExplorerStatusMessage = error ? error.localizedDescription : nil;
            [strongSelf zs_assetExplorerRefreshListResettingScroll:NO];
            [strongSelf zs_assetExplorerSyncControls];
            if (focusLocation) [strongSelf zs_assetExplorerFocusLocation:focusLocation];
        });
    });
}

- (NSString *)zs_assetExplorerNameForAsset:(ZSAssetExplorerAsset *)asset {
    return asset.assetName.length > 0 ? asset.assetName : (asset.typeName ?: @"");
}

- (NSDictionary<NSString *, NSNumber *> *)zs_assetExplorerKindCounts {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (ZSAssetExplorerAsset *asset in self.assetExplorerAssets) {
        NSString *kind = asset.typeName.length > 0 ? asset.typeName : @"Unknown";
        counts[kind] = @(counts[kind].integerValue + 1);
    }
    return counts;
}

- (NSArray<NSString *> *)zs_assetExplorerSortedKinds:(NSDictionary<NSString *, NSNumber *> *)counts {
    return [counts.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a caseInsensitiveCompare:b];
    }];
}

- (NSString *)zs_assetExplorerSafeBaseNameForBundle:(ZSAssetExplorerBundle *)bundle {
    NSString *baseName = bundle.displayName.length > 0 ? bundle.displayName : (bundle.cabIdentifier.length > 0 ? bundle.cabIdentifier : @"Bundle");
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-_. "];
    NSMutableString *safeName = [NSMutableString string];
    for (NSUInteger i = 0; i < baseName.length; i++) {
        unichar c = [baseName characterAtIndex:i];
        [safeName appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    return safeName;
}

- (void)zs_assetExplorerShareBundleTapped {
    if (self.assetExplorerFMODMode) {
        [self zs_assetExplorerFMODShareBankTapped];
        return;
    }
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    NSArray<ZSAssetExplorerAsset *> *assets = self.assetExplorerAssets;
    if (!bundle || assets.count == 0 || self.assetExplorerTextureOpen) return;

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;

    UIButton *sourceButton = self.assetExplorerShareButton;
    __weak typeof(self) weakSelf = self;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export"
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"Asset Kinds" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf zs_assetExplorerExportAssetKinds];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Full Raws" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf zs_assetExplorerExportFullRaws];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Bundle" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf zs_assetExplorerExportBundleFile];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    alert.popoverPresentationController.sourceView = sourceButton;
    alert.popoverPresentationController.sourceRect = sourceButton.bounds;

    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_assetExplorerExportAssetKinds {
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    NSArray<ZSAssetExplorerAsset *> *assets = self.assetExplorerAssets;
    if (!bundle || assets.count == 0 || self.assetExplorerTextureOpen) return;

    NSDictionary<NSString *, NSNumber *> *counts = [self zs_assetExplorerKindCounts];
    NSMutableArray<NSDictionary *> *kinds = [NSMutableArray array];
    for (NSString *kind in [self zs_assetExplorerSortedKinds:counts]) {
        [kinds addObject:@{@"kind": kind, @"count": counts[kind]}];
    }
    NSDictionary *payload = @{
        @"bundle": bundle.displayName ?: @"",
        @"cab": bundle.cabIdentifier ?: @"",
        @"totalAssets": @(assets.count),
        @"kindCount": @(kinds.count),
        @"kinds": kinds,
    };

    NSString *fileName = [[[self zs_assetExplorerSafeBaseNameForBundle:bundle] stringByAppendingString:@"_asset_kinds"] stringByAppendingPathExtension:@"json"];

    [self zs_assetExplorerPerformExportNamed:fileName bundle:bundle writer:^BOOL(NSString *path) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        return json.length > 0 && [json writeToFile:path atomically:YES];
    }];
}

- (void)zs_assetExplorerExportFullRaws {
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    NSArray<ZSAssetExplorerAsset *> *assets = [self.assetExplorerAssets copy];
    if (!bundle || assets.count == 0 || self.assetExplorerTextureOpen) return;

    NSDictionary<NSString *, NSNumber *> *counts = [self zs_assetExplorerKindCounts];
    NSArray<NSString *> *sortedKinds = [self zs_assetExplorerSortedKinds:counts];
    NSString *bundleName = bundle.displayName ?: @"";
    NSString *cab = bundle.cabIdentifier ?: @"";

    NSString *fileName = [[[self zs_assetExplorerSafeBaseNameForBundle:bundle] stringByAppendingString:@"_full_raws"] stringByAppendingPathExtension:@"json"];

    [self zs_assetExplorerPerformExportNamed:fileName bundle:bundle writer:^BOOL(NSString *path) {
        NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *grouped = [NSMutableDictionary dictionary];
        for (ZSAssetExplorerAsset *asset in assets) {
            NSString *kind = asset.typeName.length > 0 ? asset.typeName : @"Unknown";
            NSMutableArray<NSDictionary *> *bucket = grouped[kind];
            if (!bucket) {
                bucket = [NSMutableArray array];
                grouped[kind] = bucket;
            }
            [bucket addObject:@{
                @"pathID": @(asset.pathID),
                @"classID": @(asset.classID),
                @"name": asset.assetName.length > 0 ? asset.assetName : (id)[NSNull null],
                @"size": @(asset.objectSize),
            }];
        }

        NSMutableArray<NSDictionary *> *kindEntries = [NSMutableArray array];
        for (NSString *kind in sortedKinds) {
            NSArray<NSDictionary *> *items = [grouped[kind] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"pathID"] compare:b[@"pathID"]];
            }] ?: @[];
            [kindEntries addObject:@{
                @"kind": kind,
                @"count": @(items.count),
                @"assets": items,
            }];
        }

        NSDictionary *payload = @{
            @"bundle": bundleName,
            @"cab": cab,
            @"totalAssets": @(assets.count),
            @"kindCount": @(kindEntries.count),
            @"kinds": kindEntries,
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        return json.length > 0 && [json writeToFile:path atomically:YES];
    }];
}

- (void)zs_assetExplorerExportBundleFile {
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    if (!bundle || bundle.filePath.length == 0 || self.assetExplorerTextureOpen) return;

    NSString *sourcePath = [bundle.filePath copy];
    NSString *identifier = [bundle.cabIdentifier hasPrefix:@"CAB-"] ? [bundle.cabIdentifier substringFromIndex:4] : (bundle.cabIdentifier ?: @"");
    NSString *shortIdentifier = identifier.length > 5 ? [identifier substringToIndex:5] : identifier;
    NSString *originalName = sourcePath.lastPathComponent.length > 0 ? sourcePath.lastPathComponent : @"__data";
    NSString *fileName = shortIdentifier.length > 0 ? [NSString stringWithFormat:@"%@ (CAB-%@)", originalName, shortIdentifier] : originalName;

    [self zs_assetExplorerPerformExportNamed:fileName bundle:bundle writer:^BOOL(NSString *path) {
        return [NSFileManager.defaultManager copyItemAtPath:sourcePath toPath:path error:nil];
    }];
}

- (void)zs_assetExplorerPerformExportNamed:(NSString *)fileName bundle:(ZSAssetExplorerBundle *)bundle writer:(BOOL (^)(NSString *path))writer {
    UIButton *sourceButton = self.assetExplorerShareButton;
    sourceButton.enabled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSAssetExport-%@", NSUUID.UUID.UUIDString]];
        NSString *path = [directory stringByAppendingPathComponent:fileName];
        BOOL written = NO;
        if ([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
            written = writer(path);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf zs_assetExplorerSyncControls];
            if (!written || !strongSelf.assetExplorerFullScreenOpen || strongSelf.assetExplorerSelectedBundle != bundle) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
                return;
            }
            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
            activityVC.popoverPresentationController.sourceView = sourceButton;
            activityVC.popoverPresentationController.sourceRect = sourceButton.bounds;
            activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
            };
            UIViewController *presenter = zs_key_window().rootViewController;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            [presenter presentViewController:activityVC animated:YES completion:nil];
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
        });
    });
}

- (void)zs_assetExplorerExportAsset:(ZSAssetExplorerAsset *)asset full:(BOOL)full {
    [self zs_assetExplorerExportAsset:asset full:full jsonOnly:NO];
}

- (void)zs_assetExplorerExportAsset:(ZSAssetExplorerAsset *)asset full:(BOOL)full jsonOnly:(BOOL)jsonOnly {
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    if (!asset || !bundle || bundle.filePath.length == 0 || self.assetExplorerTextureOpen) return;

    NSString *bundlePath = [bundle.filePath copy];
    int64_t pathID = asset.pathID;
    [self.assetExplorerTextureSpinner startAnimating];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSAssetExport-%@", NSUUID.UUID.UUIDString]];
        NSString *outputPath = nil;
        NSError *error = nil;
        if ([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
            outputPath = full
                ? [ZSAssetExplorer fullExportAssetAtPathID:pathID inBundleAtPath:bundlePath toDirectory:directory jsonOnly:jsonOnly error:&error]
                : [ZSAssetExplorer exportAssetAtPathID:pathID inBundleAtPath:bundlePath toDirectory:directory error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.assetExplorerTextureSpinner stopAnimating];
            if (!strongSelf.assetExplorerFullScreenOpen || strongSelf.assetExplorerSelectedBundle != bundle) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
                return;
            }
            UIViewController *presenter = zs_key_window().rootViewController;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            if (!outputPath) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export Failed"
                                                                               message:error.localizedDescription ?: @"Couldn't export this asset."
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                [presenter presentViewController:alert animated:YES completion:nil];
                return;
            }
            UITableView *table = strongSelf.assetExplorerTableView;
            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outputPath]] applicationActivities:nil];
            activityVC.popoverPresentationController.sourceView = table;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(table.bounds), CGRectGetMidY(table.bounds), 1, 1);
            activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
            };
            [presenter presentViewController:activityVC animated:YES completion:nil];
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
        });
    });
}

- (void)zs_assetExplorerResetViewState {
    self.assetExplorerSearchField.text = @"";
    self.assetExplorerFilterKind = nil;
    self.assetExplorerSortKind = nil;
    self.assetExplorerSortBySize = NO;
    self.assetExplorerSizeAscending = NO;
    self.assetExplorerThumbnailMode = NO;
    [self zs_assetExplorerSyncControls];
}

- (void)zs_assetExplorerSearchChanged:(UITextField *)field {
    if (self.assetExplorerLocalizeMode) {
        [self zs_assetExplorerLocalizeRefreshListResettingScroll:YES];
        return;
    }
    if (self.assetExplorerFMODMode) {
        [self zs_assetExplorerFMODRefreshListResettingScroll:YES];
        return;
    }
    [self zs_assetExplorerRefreshListResettingScroll:YES];
}

static long long zs_asset_explorer_bundle_creation_timestamp(NSString *bundlePath) {
    NSString *folderPath = [bundlePath stringByDeletingLastPathComponent];
    NSString *candidates[2] = { bundlePath, folderPath };
    for (int i = 0; i < 2; i++) {
        struct stat fileStat;
        if (candidates[i].length == 0 || stat(candidates[i].fileSystemRepresentation, &fileStat) != 0) continue;
        long long birth = (long long)fileStat.st_birthtimespec.tv_sec;
        if (birth > 0) return birth;
    }
    struct stat dataStat;
    if (stat(bundlePath.fileSystemRepresentation, &dataStat) == 0) return (long long)dataStat.st_mtime;
    return 0;
}

static long long zs_asset_explorer_bundle_timestamp(NSString *bundlePath) {
    NSString *infoPath = [[bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"__info"];
    NSData *data = [NSData dataWithContentsOfFile:infoPath options:NSDataReadingMappedIfSafe error:nil];
    if (data.length > 0) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        if (lines.count > 1) {
            NSString *line = [lines[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            long long value = line.longLongValue;
            if (value > 0) return value;
        }
    }
    struct stat infoStat;
    if (stat(infoPath.fileSystemRepresentation, &infoStat) == 0) return (long long)infoStat.st_mtime;
    return 0;
}

- (void)zs_assetExplorerRefreshListResettingScroll:(BOOL)resetScroll {
    NSString *query = [self.assetExplorerSearchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (self.modsLibraryBrowseMode) {
        [self zs_modsLibraryRefreshListResettingScroll:resetScroll query:query];
        return;
    }
    NSUInteger shown = 0;
    NSUInteger total = 0;
    NSString *noun = nil;

    if (self.assetExplorerSelectedBundle) {
        NSString *filterKind = self.assetExplorerFilterKind;
        NSString *sortKind = self.assetExplorerSortKind;
        BOOL bySize = self.assetExplorerSortBySize;
        BOOL sizeAscending = self.assetExplorerSizeAscending;
        NSMutableArray<ZSAssetExplorerAsset *> *matches = [NSMutableArray array];
        for (ZSAssetExplorerAsset *asset in self.assetExplorerAssets) {
            NSString *kind = asset.typeName.length > 0 ? asset.typeName : @"Unknown";
            if (filterKind.length > 0 && ![kind isEqualToString:filterKind]) continue;
            if (query.length > 0) {
                NSString *pathID = [NSString stringWithFormat:@"%lld", (long long)asset.pathID];
                BOOL hit = [[self zs_assetExplorerNameForAsset:asset] localizedCaseInsensitiveContainsString:query] ||
                           [kind localizedCaseInsensitiveContainsString:query] ||
                           [pathID containsString:query] ||
                           [[self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForAsset:asset]] localizedCaseInsensitiveContainsString:query];
                if (!hit) continue;
            }
            [matches addObject:asset];
        }
        __weak typeof(self) weakSelf = self;
        self.assetExplorerDisplayedAssets = [matches sortedArrayUsingComparator:^NSComparisonResult(ZSAssetExplorerAsset *a, ZSAssetExplorerAsset *b) {
            typeof(self) strongSelf = weakSelf;
            if (sortKind.length > 0) {
                BOOL aMatch = [(a.typeName.length > 0 ? a.typeName : @"Unknown") isEqualToString:sortKind];
                BOOL bMatch = [(b.typeName.length > 0 ? b.typeName : @"Unknown") isEqualToString:sortKind];
                if (aMatch != bMatch) return aMatch ? NSOrderedAscending : NSOrderedDescending;
            }
            if (bySize && a.objectSize != b.objectSize) {
                BOOL aLarger = a.objectSize > b.objectSize;
                return (aLarger == !sizeAscending) ? NSOrderedAscending : NSOrderedDescending;
            }
            NSString *nameA = [strongSelf zs_assetExplorerNameForAsset:a];
            NSString *nameB = [strongSelf zs_assetExplorerNameForAsset:b];
            NSComparisonResult result = [nameA compare:nameB options:NSCaseInsensitiveSearch | NSNumericSearch];
            if (result != NSOrderedSame) return result;
            result = [(a.typeName ?: @"") caseInsensitiveCompare:(b.typeName ?: @"")];
            if (result != NSOrderedSame) return result;
            if (a.pathID < b.pathID) return NSOrderedAscending;
            if (a.pathID > b.pathID) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        self.assetExplorerDisplayedBundles = @[];
        shown = self.assetExplorerDisplayedAssets.count;
        total = self.assetExplorerAssets.count;
        noun = @"asset";
    } else {
        NSMutableArray<ZSAssetExplorerBundle *> *matches = [NSMutableArray array];
        for (ZSAssetExplorerBundle *bundle in self.assetExplorerBundles) {
            if (query.length > 0 &&
                ![bundle.displayName localizedCaseInsensitiveContainsString:query] &&
                ![bundle.cabIdentifier localizedCaseInsensitiveContainsString:query] &&
                ![[self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForBundle:bundle]] localizedCaseInsensitiveContainsString:query]) continue;
            [matches addObject:bundle];
        }
        BOOL descending = self.assetExplorerBundleSortDescending;
        BOOL bySize = self.assetExplorerBundleSortBySize;
        BOOL sizeAscending = self.assetExplorerBundleSizeAscending;
        BOOL byDate = self.assetExplorerBundleSortByDate;
        BOOL dateAscending = self.assetExplorerBundleDateAscending;
        if (!self.assetExplorerBundleDates) self.assetExplorerBundleDates = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *dates = self.assetExplorerBundleDates;
        if (byDate) {
            for (ZSAssetExplorerBundle *bundle in self.assetExplorerBundles) {
                if (bundle.filePath.length == 0 || dates[bundle.filePath]) continue;
                dates[bundle.filePath] = @(zs_asset_explorer_bundle_timestamp(bundle.filePath));
            }
        }
        BOOL byCreation = self.assetExplorerBundleSortByCreation;
        BOOL creationAscending = self.assetExplorerBundleCreationAscending;
        if (!self.assetExplorerBundleCreations) self.assetExplorerBundleCreations = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *creations = self.assetExplorerBundleCreations;
        if (byCreation) {
            for (ZSAssetExplorerBundle *bundle in self.assetExplorerBundles) {
                if (bundle.filePath.length == 0 || creations[bundle.filePath]) continue;
                creations[bundle.filePath] = @(zs_asset_explorer_bundle_creation_timestamp(bundle.filePath));
            }
        }
        NSMutableDictionary<NSString *, NSNumber *> *sizes = [NSMutableDictionary dictionaryWithCapacity:self.assetExplorerBundles.count];
        for (ZSAssetExplorerBundle *bundle in self.assetExplorerBundles) {
            if (bundle.filePath.length == 0) continue;
            struct stat fileStat;
            unsigned long long fileSize = stat(bundle.filePath.fileSystemRepresentation, &fileStat) == 0 ? (unsigned long long)fileStat.st_size : 0;
            sizes[bundle.filePath] = @(fileSize);
        }
        self.assetExplorerBundleSizes = sizes;
        NSArray<ZSAssetExplorerBundle *> *sortedBundles = [matches sortedArrayUsingComparator:^NSComparisonResult(ZSAssetExplorerBundle *a, ZSAssetExplorerBundle *b) {
            if (byCreation) {
                long long creationA = creations[a.filePath].longLongValue;
                long long creationB = creations[b.filePath].longLongValue;
                if (creationA != creationB) {
                    BOOL aNewer = creationA > creationB;
                    return (aNewer == !creationAscending) ? NSOrderedAscending : NSOrderedDescending;
                }
            }
            if (byDate) {
                long long dateA = dates[a.filePath].longLongValue;
                long long dateB = dates[b.filePath].longLongValue;
                if (dateA != dateB) {
                    BOOL aNewer = dateA > dateB;
                    return (aNewer == !dateAscending) ? NSOrderedAscending : NSOrderedDescending;
                }
            }
            if (bySize) {
                unsigned long long sizeA = sizes[a.filePath].unsignedLongLongValue;
                unsigned long long sizeB = sizes[b.filePath].unsignedLongLongValue;
                if (sizeA != sizeB) {
                    BOOL aLarger = sizeA > sizeB;
                    return (aLarger == !sizeAscending) ? NSOrderedAscending : NSOrderedDescending;
                }
            }
            NSComparisonResult result = [a.displayName compare:b.displayName options:NSCaseInsensitiveSearch | NSNumericSearch];
            if (result == NSOrderedSame) result = [a.cabIdentifier caseInsensitiveCompare:b.cabIdentifier];
            if (descending && !bySize && !byDate && !byCreation) {
                if (result == NSOrderedAscending) return NSOrderedDescending;
                if (result == NSOrderedDescending) return NSOrderedAscending;
            }
            return result;
        }];
        NSSet<NSString *> *moddedCABs = [ModAssetLibrary moddedBundleCABs];
        NSMutableOrderedSet<NSString *> *bookmarkedKeys = [self zs_assetExplorerBookmarks];
        NSMutableArray<ZSAssetExplorerBundle *> *bookmarkedBundles = [NSMutableArray array];
        NSMutableArray<ZSAssetExplorerBundle *> *moddedBundles = [NSMutableArray array];
        NSMutableArray<ZSAssetExplorerBundle *> *stockBundles = [NSMutableArray array];
        for (ZSAssetExplorerBundle *bundle in sortedBundles) {
            if ([bookmarkedKeys containsObject:zs_asset_explorer_bundle_key(bundle)]) {
                [bookmarkedBundles addObject:bundle];
            } else if (bundle.cabIdentifier.length > 0 && [moddedCABs containsObject:bundle.cabIdentifier]) {
                [moddedBundles addObject:bundle];
            } else {
                [stockBundles addObject:bundle];
            }
        }
        self.assetExplorerDisplayedBookmarkedCount = bookmarkedBundles.count;
        self.assetExplorerDisplayedModdedCount = moddedBundles.count;
        NSMutableArray<ZSAssetExplorerBundle *> *orderedBundles = [NSMutableArray arrayWithArray:bookmarkedBundles];
        [orderedBundles addObjectsFromArray:moddedBundles];
        [orderedBundles addObjectsFromArray:stockBundles];
        self.assetExplorerDisplayedBundles = orderedBundles;
        self.assetExplorerDisplayedAssets = @[];
        shown = self.assetExplorerDisplayedBundles.count;
        total = self.assetExplorerBundles.count;
        noun = @"bundle";
    }

    NSString *message = self.assetExplorerStatusMessage;
    if (message.length == 0) {
        NSString *plural = total == 1 ? @"" : @"s";
        message = shown == total
            ? [NSString stringWithFormat:@"%lu %@%@", (unsigned long)total, noun, plural]
            : [NSString stringWithFormat:@"%lu of %lu %@%@", (unsigned long)shown, (unsigned long)total, noun, plural];
    }
    self.assetExplorerStatusLabel.text = message;
    [self.assetExplorerTableView reloadData];
    if (resetScroll) [self.assetExplorerTableView setContentOffset:CGPointZero animated:NO];
    [self zs_assetExplorerUpdateThumbnailGrid];
    if (resetScroll && !self.assetExplorerThumbCollectionView.hidden) [self.assetExplorerThumbCollectionView setContentOffset:CGPointZero animated:NO];
}

- (void)zs_assetExplorerSyncControls {
    [self zs_assetExplorerUpdateThumbnailGrid];
    [self zs_modsLibrarySyncHeaderControls];
    if (self.modsLibraryBrowseMode) {
        BOOL detail = self.modsLibrarySelectedEntry != nil;
        self.assetExplorerSearchContainer.hidden = detail;
        self.assetExplorerControlsStack.hidden = YES;
        self.assetExplorerFilterButton.hidden = YES;
        self.assetExplorerSortButton.hidden = YES;
        self.assetExplorerShareButton.hidden = YES;
        self.assetExplorerSearchField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
        return;
    }
    if (self.assetExplorerLocalizeMode) {
        [self zs_assetExplorerLocalizeSyncControls];
        return;
    }
    if (self.assetExplorerHubVisible || self.assetExplorerFMODMode) {
        [self zs_assetExplorerFMODSyncControls];
        return;
    }
    BOOL textureOpen = self.assetExplorerTextureOpen;
    BOOL inBundle = self.assetExplorerSelectedBundle != nil;
    self.assetExplorerSearchContainer.hidden = textureOpen;
    self.assetExplorerControlsStack.hidden = textureOpen;
    self.assetExplorerFilterButton.hidden = !inBundle;
    self.assetExplorerSortButton.hidden = NO;
    BOOL canShare = inBundle && self.assetExplorerAssets.count > 0;
    self.assetExplorerShareButton.hidden = !inBundle;
    self.assetExplorerShareButton.enabled = canShare;
    self.assetExplorerShareButton.alpha = canShare ? 1 : 0.35;
    NSString *placeholder = inBundle ? @"Search assets" : @"Search bundles";
    self.assetExplorerSearchField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:placeholder
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    [self zs_assetExplorerRebuildMenus];
}

- (void)zs_assetExplorerRebuildMenus {
    if (!self.assetExplorerSortButton) return;
    if (self.assetExplorerLocalizeMode) {
        [self zs_assetExplorerLocalizeRebuildMenus];
        return;
    }
    if (self.assetExplorerFMODMode) {
        [self zs_assetExplorerFMODRebuildMenus];
        return;
    }
    __weak typeof(self) weakSelf = self;
    BOOL inBundle = self.assetExplorerSelectedBundle != nil;
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];

    NSMutableArray<UIMenuElement *> *sortItems = [NSMutableArray array];
    BOOL sortActive = NO;
    BOOL sizeActive = inBundle ? self.assetExplorerSortBySize : self.assetExplorerBundleSortBySize;
    BOOL dateActive = !inBundle && self.assetExplorerBundleSortByDate;
    BOOL creationActive = !inBundle && self.assetExplorerBundleSortByCreation;
    BOOL sizeAscending = inBundle ? self.assetExplorerSizeAscending : self.assetExplorerBundleSizeAscending;
    NSString *sizeTitle = sizeActive ? (sizeAscending ? @"Size · Smallest first" : @"Size · Largest first") : @"Size";
    UIImage *sizeImage = sizeActive ? [UIImage systemImageNamed:(sizeAscending ? @"arrow.up" : @"arrow.down")] : nil;
    UIAction *sizeAction = [UIAction actionWithTitle:sizeTitle image:sizeImage identifier:nil handler:^(__kindof UIAction *selected) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.assetExplorerSelectedBundle) {
            if (strongSelf.assetExplorerSortBySize) {
                strongSelf.assetExplorerSizeAscending = !strongSelf.assetExplorerSizeAscending;
            } else {
                strongSelf.assetExplorerSortBySize = YES;
                strongSelf.assetExplorerSizeAscending = NO;
            }
        } else {
            strongSelf.assetExplorerBundleSortByDate = NO;
            strongSelf.assetExplorerBundleDateAscending = NO;
            strongSelf.assetExplorerBundleSortByCreation = NO;
            strongSelf.assetExplorerBundleCreationAscending = NO;
            if (strongSelf.assetExplorerBundleSortBySize) {
                strongSelf.assetExplorerBundleSizeAscending = !strongSelf.assetExplorerBundleSizeAscending;
            } else {
                strongSelf.assetExplorerBundleSortBySize = YES;
                strongSelf.assetExplorerBundleSizeAscending = NO;
            }
        }
        [strongSelf zs_assetExplorerRefreshListResettingScroll:YES];
        [strongSelf zs_assetExplorerRebuildMenus];
    }];
    sizeAction.state = sizeActive ? UIMenuElementStateOn : UIMenuElementStateOff;

    if (inBundle) {
        sortActive = self.assetExplorerSortKind.length > 0 || self.assetExplorerSortBySize;
        UIAction *alphabetical = [UIAction actionWithTitle:@"Alphabetical" image:nil identifier:nil handler:^(__kindof UIAction *selected) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.assetExplorerSortKind = nil;
            strongSelf.assetExplorerSortBySize = NO;
            strongSelf.assetExplorerSizeAscending = NO;
            [strongSelf zs_assetExplorerRefreshListResettingScroll:YES];
            [strongSelf zs_assetExplorerRebuildMenus];
        }];
        alphabetical.state = sortActive ? UIMenuElementStateOff : UIMenuElementStateOn;
        [sortItems addObject:alphabetical];
        [sortItems addObject:sizeAction];

        NSDictionary<NSString *, NSNumber *> *counts = [self zs_assetExplorerKindCounts];
        NSMutableArray<UIMenuElement *> *kindItems = [NSMutableArray array];
        for (NSString *kind in [self zs_assetExplorerSortedKinds:counts]) {
            NSString *title = [NSString stringWithFormat:@"%@ (%@)", kind, counts[kind]];
            UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *selected) {
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.assetExplorerSortKind = kind;
                [strongSelf zs_assetExplorerRefreshListResettingScroll:YES];
                [strongSelf zs_assetExplorerRebuildMenus];
            }];
            action.state = [self.assetExplorerSortKind isEqualToString:kind] ? UIMenuElementStateOn : UIMenuElementStateOff;
            [kindItems addObject:action];
        }
        if (kindItems.count > 0) {
            [sortItems addObject:[UIMenu menuWithTitle:@"Kind first" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:kindItems]];
        }
    } else {
        BOOL descending = self.assetExplorerBundleSortDescending;
        BOOL nameSorted = !self.assetExplorerBundleSortBySize && !self.assetExplorerBundleSortByDate && !self.assetExplorerBundleSortByCreation;
        sortActive = descending || self.assetExplorerBundleSortBySize || self.assetExplorerBundleSortByDate || self.assetExplorerBundleSortByCreation;
        NSString *nameTitle = nameSorted ? (descending ? @"Name · Z–A" : @"Name · A–Z") : @"Name";
        UIAction *nameAction = [UIAction actionWithTitle:nameTitle image:nil identifier:nil handler:^(__kindof UIAction *selected) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.assetExplorerBundleSortBySize || strongSelf.assetExplorerBundleSortByDate || strongSelf.assetExplorerBundleSortByCreation) {
                strongSelf.assetExplorerBundleSortBySize = NO;
                strongSelf.assetExplorerBundleSizeAscending = NO;
                strongSelf.assetExplorerBundleSortByDate = NO;
                strongSelf.assetExplorerBundleDateAscending = NO;
                strongSelf.assetExplorerBundleSortByCreation = NO;
                strongSelf.assetExplorerBundleCreationAscending = NO;
                strongSelf.assetExplorerBundleSortDescending = NO;
            } else {
                strongSelf.assetExplorerBundleSortDescending = !strongSelf.assetExplorerBundleSortDescending;
            }
            [strongSelf zs_assetExplorerRefreshListResettingScroll:YES];
            [strongSelf zs_assetExplorerRebuildMenus];
        }];
        nameAction.state = nameSorted ? UIMenuElementStateOn : UIMenuElementStateOff;
        NSString *dateTitle = dateActive ? (self.assetExplorerBundleDateAscending ? @"Last Used · Oldest first" : @"Last Used · Newest first") : @"Last Used";
        UIImage *dateImage = dateActive ? [UIImage systemImageNamed:(self.assetExplorerBundleDateAscending ? @"arrow.up" : @"arrow.down")] : nil;
        UIAction *dateAction = [UIAction actionWithTitle:dateTitle image:dateImage identifier:nil handler:^(__kindof UIAction *selected) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.assetExplorerBundleSortBySize = NO;
            strongSelf.assetExplorerBundleSizeAscending = NO;
            strongSelf.assetExplorerBundleSortDescending = NO;
            strongSelf.assetExplorerBundleSortByCreation = NO;
            strongSelf.assetExplorerBundleCreationAscending = NO;
            if (strongSelf.assetExplorerBundleSortByDate) {
                strongSelf.assetExplorerBundleDateAscending = !strongSelf.assetExplorerBundleDateAscending;
            } else {
                strongSelf.assetExplorerBundleSortByDate = YES;
                strongSelf.assetExplorerBundleDateAscending = NO;
            }
            [strongSelf zs_assetExplorerRefreshListResettingScroll:YES];
            [strongSelf zs_assetExplorerRebuildMenus];
        }];
        dateAction.state = dateActive ? UIMenuElementStateOn : UIMenuElementStateOff;
        NSString *creationTitle = creationActive ? (self.assetExplorerBundleCreationAscending ? @"Creation Date · Oldest first" : @"Creation Date · Newest first") : @"Creation Date";
        UIImage *creationImage = creationActive ? [UIImage systemImageNamed:(self.assetExplorerBundleCreationAscending ? @"arrow.up" : @"arrow.down")] : nil;
        UIAction *creationAction = [UIAction actionWithTitle:creationTitle image:creationImage identifier:nil handler:^(__kindof UIAction *selected) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.assetExplorerBundleSortBySize = NO;
            strongSelf.assetExplorerBundleSizeAscending = NO;
            strongSelf.assetExplorerBundleSortDescending = NO;
            strongSelf.assetExplorerBundleSortByDate = NO;
            strongSelf.assetExplorerBundleDateAscending = NO;
            if (strongSelf.assetExplorerBundleSortByCreation) {
                strongSelf.assetExplorerBundleCreationAscending = !strongSelf.assetExplorerBundleCreationAscending;
            } else {
                strongSelf.assetExplorerBundleSortByCreation = YES;
                strongSelf.assetExplorerBundleCreationAscending = NO;
            }
            [strongSelf zs_assetExplorerRefreshListResettingScroll:YES];
            [strongSelf zs_assetExplorerRebuildMenus];
        }];
        creationAction.state = creationActive ? UIMenuElementStateOn : UIMenuElementStateOff;
        [sortItems addObjectsFromArray:@[nameAction, sizeAction, dateAction, creationAction]];
    }

    NSInteger desiredSortStyle = sortActive ? 1 : 0;
    if (self.assetExplorerSortButton.tag != desiredSortStyle) {
        UIColor *tint = sortActive ? zs_accent_green_color() : [UIColor colorWithWhite:1 alpha:0.9];
        zs_style_pill_icon_button_as_native_glass(self.assetExplorerSortButton, [UIImage systemImageNamed:@"arrow.up.arrow.down" withConfiguration:symbolConfig], tint);
        self.assetExplorerSortButton.tag = desiredSortStyle;
    }
    self.assetExplorerSortButton.menu = [UIMenu menuWithTitle:@"Sort" children:sortItems];
    self.assetExplorerSortButton.showsMenuAsPrimaryAction = YES;

    NSMutableArray<UIMenuElement *> *filterItems = [NSMutableArray array];
    BOOL filterActive = inBundle && self.assetExplorerFilterKind.length > 0;
    if (inBundle) {
        UIAction *all = [UIAction actionWithTitle:@"All kinds" image:nil identifier:nil handler:^(__kindof UIAction *action) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.assetExplorerFilterKind = nil;
            [strongSelf zs_assetExplorerRefreshListResettingScroll:YES];
            [strongSelf zs_assetExplorerRebuildMenus];
        }];
        all.state = filterActive ? UIMenuElementStateOff : UIMenuElementStateOn;
        [filterItems addObject:all];

        NSDictionary<NSString *, NSNumber *> *counts = [self zs_assetExplorerKindCounts];
        NSMutableArray<UIMenuElement *> *kindItems = [NSMutableArray array];
        for (NSString *kind in [self zs_assetExplorerSortedKinds:counts]) {
            NSString *title = [NSString stringWithFormat:@"%@ (%@)", kind, counts[kind]];
            UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *selected) {
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.assetExplorerFilterKind = kind;
                [strongSelf zs_assetExplorerRefreshListResettingScroll:YES];
                [strongSelf zs_assetExplorerRebuildMenus];
            }];
            action.state = [self.assetExplorerFilterKind isEqualToString:kind] ? UIMenuElementStateOn : UIMenuElementStateOff;
            [kindItems addObject:action];
        }
        if (kindItems.count > 0) {
            [filterItems addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:kindItems]];
        }
    }

    NSInteger desiredFilterStyle = filterActive ? 1 : 0;
    if (self.assetExplorerFilterButton.tag != desiredFilterStyle) {
        UIColor *tint = filterActive ? zs_accent_green_color() : [UIColor colorWithWhite:1 alpha:0.9];
        NSString *symbol = filterActive ? @"line.3.horizontal.decrease.circle.fill" : @"line.3.horizontal.decrease.circle";
        zs_style_pill_icon_button_as_native_glass(self.assetExplorerFilterButton, [UIImage systemImageNamed:symbol withConfiguration:symbolConfig], tint);
        self.assetExplorerFilterButton.tag = desiredFilterStyle;
    }
    self.assetExplorerFilterButton.menu = [UIMenu menuWithTitle:@"Filter by kind" children:filterItems];
    self.assetExplorerFilterButton.showsMenuAsPrimaryAction = YES;
}

- (NSMutableOrderedSet<NSString *> *)zs_assetExplorerBookmarks {
    if (self.assetExplorerBookmarkedKeys) return self.assetExplorerBookmarkedKeys;
    NSDictionary *section = zs_settings_section(@"assetExplorer");
    self.assetExplorerBookmarkedKeys = zs_ae_string_set(section[@"bookmarkedBundles"]);
    self.assetExplorerFMODBookmarkedKeys = zs_ae_string_set(section[@"fmodBookmarks"]);
    self.assetExplorerLocalizeBookmarkedKeys = zs_ae_string_set(section[@"localizeBookmarks"]);
    NSMutableDictionary<NSString *, NSString *> *remarks = [NSMutableDictionary dictionary];
    id storedRemarks = section[@"remarks"];
    if ([storedRemarks isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)storedRemarks enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) remarks[key] = value;
        }];
    }
    self.assetExplorerRemarks = remarks;
    id recent = section[@"recentlyInspected"];
    if (self.assetExplorerRecentKey.length == 0 && [recent isKindOfClass:[NSString class]]) self.assetExplorerRecentKey = recent;
    id fmodRecent = section[@"fmodRecent"];
    if (self.assetExplorerFMODRecentKey.length == 0 && [fmodRecent isKindOfClass:[NSString class]]) self.assetExplorerFMODRecentKey = fmodRecent;
    id localizeRecent = section[@"localizeRecent"];
    if (self.assetExplorerLocalizeRecentKey.length == 0 && [localizeRecent isKindOfClass:[NSString class]]) self.assetExplorerLocalizeRecentKey = localizeRecent;
    return self.assetExplorerBookmarkedKeys;
}

- (void)zs_assetExplorerPersistState {
    NSMutableOrderedSet<NSString *> *keys = [self zs_assetExplorerBookmarks];
    zs_write_settings_section(@"assetExplorer", @{
        @"bookmarkedBundles": keys.array ?: @[],
        @"recentlyInspected": self.assetExplorerRecentKey ?: @"",
        @"fmodBookmarks": self.assetExplorerFMODBookmarkedKeys.array ?: @[],
        @"fmodRecent": self.assetExplorerFMODRecentKey ?: @"",
        @"localizeBookmarks": self.assetExplorerLocalizeBookmarkedKeys.array ?: @[],
        @"localizeRecent": self.assetExplorerLocalizeRecentKey ?: @"",
        @"remarks": self.assetExplorerRemarks ?: @{},
    });
}

- (BOOL)zs_assetExplorerIsBookmarked:(ZSAssetExplorerBundle *)bundle {
    return [[self zs_assetExplorerBookmarks] containsObject:zs_asset_explorer_bundle_key(bundle)];
}

- (NSMutableOrderedSet<NSString *> *)zs_assetExplorerFMODBookmarks {
    [self zs_assetExplorerBookmarks];
    return self.assetExplorerFMODBookmarkedKeys;
}

- (NSMutableOrderedSet<NSString *> *)zs_assetExplorerLocalizeBookmarks {
    [self zs_assetExplorerBookmarks];
    return self.assetExplorerLocalizeBookmarkedKeys;
}

- (void)zs_assetExplorerRefreshCurrentList {
    if (!self.assetExplorerFullScreenOpen) return;
    if (self.assetExplorerLocalizeMode) {
        [self zs_assetExplorerLocalizeRefreshListResettingScroll:NO];
    } else if (self.assetExplorerFMODMode) {
        [self zs_assetExplorerFMODRefreshListResettingScroll:NO];
    } else {
        [self zs_assetExplorerRefreshListResettingScroll:NO];
    }
}

- (void)zs_assetExplorerToggleBookmarkKey:(NSString *)key inSet:(NSMutableOrderedSet<NSString *> *)set {
    if (key.length == 0 || !set) return;
    if ([set containsObject:key]) {
        [set removeObject:key];
    } else {
        [set addObject:key];
    }
    [self zs_assetExplorerPersistState];
    [self zs_assetExplorerRefreshCurrentList];
}

- (NSString *)zs_assetExplorerRemarkForKey:(NSString *)key {
    if (key.length == 0) return nil;
    [self zs_assetExplorerBookmarks];
    NSString *remark = self.assetExplorerRemarks[key];
    return remark.length > 0 ? remark : nil;
}

- (void)zs_assetExplorerSetRemark:(NSString *)remark forKey:(NSString *)key {
    if (key.length == 0) return;
    [self zs_assetExplorerBookmarks];
    if (remark.length > 0) {
        self.assetExplorerRemarks[key] = remark;
    } else {
        [self.assetExplorerRemarks removeObjectForKey:key];
    }
    [self zs_assetExplorerPersistState];
    [self zs_assetExplorerRefreshCurrentList];
}

- (void)zs_assetExplorerPromptRemarkForKey:(NSString *)key {
    if (key.length == 0) return;
    __weak typeof(self) weakSelf = self;
    [self zs_presentFloatingTextFieldWithInitialText:[self zs_assetExplorerRemarkForKey:key]
                                          placeholder:@"Remark"
                                               secure:NO
                                           completion:^(NSString * _Nullable trimmedText) {
        [weakSelf zs_assetExplorerSetRemark:trimmedText forKey:key];
    }];
}

- (NSString *)zs_assetExplorerRemarkKeyForBundle:(ZSAssetExplorerBundle *)bundle {
    return bundle ? [@"b:" stringByAppendingString:zs_asset_explorer_bundle_key(bundle)] : nil;
}

- (NSString *)zs_assetExplorerRemarkKeyForAsset:(ZSAssetExplorerAsset *)asset {
    ZSAssetExplorerBundle *bundle = self.assetExplorerSelectedBundle;
    if (!asset || !bundle) return nil;
    return [NSString stringWithFormat:@"a:%@:%lld", zs_asset_explorer_bundle_key(bundle), (long long)asset.pathID];
}

- (NSString *)zs_assetExplorerRemarkKeyForBankFile:(ZSFMODBankFile *)file {
    return file.fileName.length > 0 ? [@"f:" stringByAppendingString:file.fileName] : nil;
}

- (NSString *)zs_assetExplorerRemarkKeyForStream:(ZSFMODStream *)stream {
    ZSFMODBankFile *file = self.assetExplorerFMODBankFile;
    if (!stream || file.fileName.length == 0) return nil;
    return [NSString stringWithFormat:@"s:%@:%ld:%ld", file.fileName, (long)stream.fsbIndex, (long)stream.index];
}

- (NSString *)zs_assetExplorerLocalizeKeyForPath:(NSString *)path {
    NSString *root = self.assetExplorerLocalizeRoot;
    if (root.length > 0 && [path hasPrefix:[root stringByAppendingString:@"/"]]) return [path substringFromIndex:root.length + 1];
    return path.lastPathComponent ?: @"";
}

- (NSString *)zs_assetExplorerRemarkKeyForLocalizePath:(NSString *)path {
    NSString *relative = [self zs_assetExplorerLocalizeKeyForPath:path];
    return relative.length > 0 ? [@"l:" stringByAppendingString:relative] : nil;
}

- (UIAction *)zs_assetExplorerRemarkActionForKey:(NSString *)key {
    __weak typeof(self) weakSelf = self;
    BOOL hasRemark = [self zs_assetExplorerRemarkForKey:key].length > 0;
    return [UIAction actionWithTitle:(hasRemark ? @"Edit Remark" : @"Add Remark")
                               image:[UIImage systemImageNamed:@"text.bubble"]
                          identifier:nil
                             handler:^(__kindof UIAction *action) {
        [weakSelf zs_assetExplorerPromptRemarkForKey:key];
    }];
}

- (UIAction *)zs_assetExplorerBookmarkActionForKey:(NSString *)key inSet:(NSMutableOrderedSet<NSString *> *)set {
    __weak typeof(self) weakSelf = self;
    BOOL bookmarked = [set containsObject:key];
    return [UIAction actionWithTitle:(bookmarked ? @"Remove Bookmark" : @"Bookmark")
                               image:[UIImage systemImageNamed:(bookmarked ? @"bookmark.slash" : @"bookmark")]
                          identifier:nil
                             handler:^(__kindof UIAction *action) {
        [weakSelf zs_assetExplorerToggleBookmarkKey:key inSet:set];
    }];
}

- (UIContextMenuConfiguration *)zs_assetExplorerMenuWithRemarkKey:(NSString *)remarkKey
                                                      bookmarkKey:(NSString *)bookmarkKey
                                                      bookmarkSet:(NSMutableOrderedSet<NSString *> *)bookmarkSet
                                                       extraItems:(NSArray<UIMenuElement *> *)extraItems API_AVAILABLE(ios(13.0)) {
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        typeof(self) strongSelf = weakSelf;
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        if (strongSelf && bookmarkKey.length > 0 && bookmarkSet) [items addObject:[strongSelf zs_assetExplorerBookmarkActionForKey:bookmarkKey inSet:bookmarkSet]];
        if (strongSelf && remarkKey.length > 0) [items addObject:[strongSelf zs_assetExplorerRemarkActionForKey:remarkKey]];
        if (extraItems.count > 0) [items addObjectsFromArray:extraItems];
        return [UIMenu menuWithTitle:@"" children:items];
    }];
}

- (UISwipeActionsConfiguration *)zs_assetExplorerSwipeWithRemarkKey:(NSString *)remarkKey
                                                        bookmarkKey:(NSString *)bookmarkKey
                                                        bookmarkSet:(NSMutableOrderedSet<NSString *> *)bookmarkSet API_AVAILABLE(ios(11.0)) {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray array];
    if (bookmarkKey.length > 0 && bookmarkSet) {
        BOOL bookmarked = [bookmarkSet containsObject:bookmarkKey];
        UIContextualAction *bookmarkAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                                      title:(bookmarked ? @"Unpin" : @"Bookmark")
                                                                                    handler:^(UIContextualAction *contextualAction, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [weakSelf zs_assetExplorerToggleBookmarkKey:bookmarkKey inSet:bookmarkSet];
            completionHandler(YES);
        }];
        bookmarkAction.image = [UIImage systemImageNamed:(bookmarked ? @"bookmark.slash.fill" : @"bookmark.fill")];
        bookmarkAction.backgroundColor = bookmarked ? [UIColor colorWithWhite:0.35 alpha:1] : zs_accent_green_color();
        [actions addObject:bookmarkAction];
    }
    if (remarkKey.length > 0) {
        BOOL hasRemark = [self zs_assetExplorerRemarkForKey:remarkKey].length > 0;
        UIContextualAction *remarkAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                                    title:(hasRemark ? @"Edit Remark" : @"Add Remark")
                                                                                  handler:^(UIContextualAction *contextualAction, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [weakSelf zs_assetExplorerPromptRemarkForKey:remarkKey];
            completionHandler(YES);
        }];
        remarkAction.image = [UIImage systemImageNamed:@"text.bubble.fill"];
        remarkAction.backgroundColor = [UIColor colorWithRed:0.24 green:0.42 blue:0.78 alpha:1];
        [actions addObject:remarkAction];
    }
    if (actions.count == 0) return nil;
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:actions];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (NSUInteger)zs_assetExplorerBookmarkedDisplayCount {
    return MIN(self.assetExplorerDisplayedBookmarkedCount, self.assetExplorerDisplayedBundles.count);
}

- (NSUInteger)zs_assetExplorerModdedDisplayCount {
    return MIN(self.assetExplorerDisplayedModdedCount, self.assetExplorerDisplayedBundles.count - [self zs_assetExplorerBookmarkedDisplayCount]);
}

- (NSUInteger)zs_assetExplorerCountForSectionKind:(NSInteger)kind {
    NSUInteger bookmarked = [self zs_assetExplorerBookmarkedDisplayCount];
    NSUInteger modded = [self zs_assetExplorerModdedDisplayCount];
    if (kind == 0) return bookmarked;
    if (kind == 1) return modded;
    return self.assetExplorerDisplayedBundles.count - bookmarked - modded;
}

- (NSArray<NSNumber *> *)zs_assetExplorerSectionKinds {
    NSMutableArray<NSNumber *> *kinds = [NSMutableArray arrayWithCapacity:3];
    for (NSInteger kind = 0; kind < 3; kind++) {
        if ([self zs_assetExplorerCountForSectionKind:kind] > 0) [kinds addObject:@(kind)];
    }
    return kinds;
}

- (NSInteger)zs_assetExplorerSectionKindForSection:(NSInteger)section {
    NSArray<NSNumber *> *kinds = [self zs_assetExplorerSectionKinds];
    if (section < 0 || section >= (NSInteger)kinds.count) return 2;
    return kinds[(NSUInteger)section].integerValue;
}

- (NSInteger)zs_assetExplorerBundleIndexForIndexPath:(NSIndexPath *)indexPath {
    NSInteger kind = [self zs_assetExplorerSectionKindForSection:indexPath.section];
    NSUInteger start = 0;
    for (NSInteger earlier = 0; earlier < kind; earlier++) start += [self zs_assetExplorerCountForSectionKind:earlier];
    return (NSInteger)start + indexPath.row;
}

- (NSIndexPath *)zs_assetExplorerIndexPathForBundleIndex:(NSInteger)bundleIndex {
    NSArray<NSNumber *> *kinds = [self zs_assetExplorerSectionKinds];
    NSInteger remaining = bundleIndex;
    for (NSUInteger section = 0; section < kinds.count; section++) {
        NSInteger count = (NSInteger)[self zs_assetExplorerCountForSectionKind:kinds[section].integerValue];
        if (remaining < count) return [NSIndexPath indexPathForRow:remaining inSection:(NSInteger)section];
        remaining -= count;
    }
    return nil;
}

- (void)zs_assetExplorerCaptureListPosition {
    UITableView *table = self.assetExplorerTableView;
    self.assetExplorerListSavedOffsetY = table.contentOffset.y;
    self.assetExplorerListSavedQuery = self.assetExplorerSearchField.text ?: @"";
    self.assetExplorerListAnchorKey = nil;
    self.assetExplorerListAnchorOffset = 0;
    NSArray<NSIndexPath *> *visible = [table.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)];
    for (NSIndexPath *indexPath in visible) {
        CGRect rect = [table rectForRowAtIndexPath:indexPath];
        if (CGRectGetMaxY(rect) <= table.contentOffset.y + 1) continue;
        NSInteger bundleIndex = [self zs_assetExplorerBundleIndexForIndexPath:indexPath];
        if (bundleIndex < 0 || bundleIndex >= (NSInteger)self.assetExplorerDisplayedBundles.count) break;
        self.assetExplorerListAnchorKey = zs_asset_explorer_bundle_key(self.assetExplorerDisplayedBundles[(NSUInteger)bundleIndex]);
        self.assetExplorerListAnchorOffset = rect.origin.y - table.contentOffset.y;
        break;
    }
    self.assetExplorerListRestorePending = YES;
}

- (void)zs_assetExplorerRestoreListPosition {
    if (!self.assetExplorerListRestorePending) return;
    self.assetExplorerListRestorePending = NO;
    UITableView *table = self.assetExplorerTableView;
    [table layoutIfNeeded];
    CGFloat target = self.assetExplorerListSavedOffsetY;
    NSString *anchor = self.assetExplorerListAnchorKey;
    if (anchor.length > 0) {
        NSArray<ZSAssetExplorerBundle *> *bundles = self.assetExplorerDisplayedBundles;
        for (NSUInteger i = 0; i < bundles.count; i++) {
            if (![zs_asset_explorer_bundle_key(bundles[i]) isEqualToString:anchor]) continue;
            NSIndexPath *indexPath = [self zs_assetExplorerIndexPathForBundleIndex:(NSInteger)i];
            if (indexPath) target = [table rectForRowAtIndexPath:indexPath].origin.y - self.assetExplorerListAnchorOffset;
            break;
        }
    }
    CGFloat minY = -table.adjustedContentInset.top;
    CGFloat maxY = MAX(minY, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
    target = MIN(MAX(target, minY), maxY);
    [table setContentOffset:CGPointMake(table.contentOffset.x, target) animated:NO];
}

- (BOOL)zs_assetExplorerSectionCountsForTableView:(UITableView *)tableView bookmarked:(NSUInteger *)bookmarked modded:(NSUInteger *)modded total:(NSUInteger *)total {
    NSUInteger b = 0, m = 0, t = 0;
    if (tableView == self.assetExplorerFMODTableView && !self.assetExplorerFMODBankFile) {
        t = self.assetExplorerFMODDisplayedBanks.count;
        b = MIN(self.assetExplorerFMODDisplayedBookmarkedCount, t);
        m = MIN(self.assetExplorerFMODDisplayedModdedCount, t - b);
    } else if (tableView == self.assetExplorerLocalizeTableView) {
        t = self.assetExplorerLocalizeDisplayedEntries.count;
        b = MIN(self.assetExplorerLocalizeDisplayedBookmarkedCount, t);
        m = MIN(self.assetExplorerLocalizeDisplayedModdedCount, t - b);
    } else {
        return NO;
    }
    *bookmarked = b;
    *modded = m;
    *total = t;
    return YES;
}

- (NSInteger)zs_assetExplorerListIndexForIndexPath:(NSIndexPath *)indexPath inTableView:(UITableView *)tableView {
    NSUInteger bookmarked = 0, modded = 0, total = 0;
    if (![self zs_assetExplorerSectionCountsForTableView:tableView bookmarked:&bookmarked modded:&modded total:&total]) return indexPath.row;
    return zs_ae_flat_index(indexPath, bookmarked, modded, total);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (tableView == self.assetExplorerTableView && self.modsLibraryBrowseMode) {
        return self.modsLibrarySelectedEntry ? 0 : 1;
    }
    NSUInteger bookmarked = 0, modded = 0, total = 0;
    if ([self zs_assetExplorerSectionCountsForTableView:tableView bookmarked:&bookmarked modded:&modded total:&total]) {
        return MAX((NSInteger)zs_ae_section_kinds(bookmarked, modded, total).count, 1);
    }
    if (tableView != self.assetExplorerTableView || self.assetExplorerSelectedBundle) return 1;
    return MAX((NSInteger)[self zs_assetExplorerSectionKinds].count, 1);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.assetExplorerTableView && self.modsLibraryBrowseMode) {
        if (self.modsLibrarySelectedEntry) return 0;
        return (NSInteger)(self.modsLibraryDisplayedFolders.count + self.modsLibraryDisplayedEntries.count);
    }
    NSUInteger bookmarked = 0, modded = 0, total = 0;
    if ([self zs_assetExplorerSectionCountsForTableView:tableView bookmarked:&bookmarked modded:&modded total:&total]) {
        NSArray<NSNumber *> *kinds = zs_ae_section_kinds(bookmarked, modded, total);
        if (section < 0 || section >= (NSInteger)kinds.count) return 0;
        return (NSInteger)zs_ae_section_count(kinds[(NSUInteger)section].integerValue, bookmarked, modded, total);
    }
    if (tableView == self.assetExplorerLocalizeJSONTableView) return (NSInteger)self.assetExplorerLocalizeVisibleRows.count;
    if (tableView == self.assetExplorerFMODTableView) return (NSInteger)self.assetExplorerFMODDisplayedStreams.count;
    if (tableView != self.assetExplorerTableView) return 0;
    if (self.assetExplorerSelectedBundle) return (NSInteger)self.assetExplorerDisplayedAssets.count;
    if ([self zs_assetExplorerSectionKinds].count == 0) return 0;
    return (NSInteger)[self zs_assetExplorerCountForSectionKind:[self zs_assetExplorerSectionKindForSection:section]];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (tableView == self.assetExplorerTableView && self.modsLibraryBrowseMode) return CGFLOAT_MIN;
    NSUInteger bookmarked = 0, modded = 0, total = 0;
    if ([self zs_assetExplorerSectionCountsForTableView:tableView bookmarked:&bookmarked modded:&modded total:&total]) {
        return total == 0 ? CGFLOAT_MIN : 26;
    }
    if (tableView != self.assetExplorerTableView || self.assetExplorerSelectedBundle || self.assetExplorerDisplayedBundles.count == 0) return CGFLOAT_MIN;
    return 26;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (tableView == self.assetExplorerTableView && self.modsLibraryBrowseMode) return nil;
    NSUInteger bookmarked = 0, modded = 0, total = 0;
    if ([self zs_assetExplorerSectionCountsForTableView:tableView bookmarked:&bookmarked modded:&modded total:&total]) {
        NSArray<NSNumber *> *kinds = zs_ae_section_kinds(bookmarked, modded, total);
        if (section < 0 || section >= (NSInteger)kinds.count) return nil;
        return zs_ae_section_header(zs_ae_section_title(kinds[(NSUInteger)section].integerValue));
    }
    if (tableView != self.assetExplorerTableView || self.assetExplorerSelectedBundle || self.assetExplorerDisplayedBundles.count == 0) return nil;
    return zs_ae_section_header(zs_ae_section_title([self zs_assetExplorerSectionKindForSection:section]));
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.assetExplorerTableView && self.modsLibraryBrowseMode) return [self zs_modsLibraryCellForTableView:tableView indexPath:indexPath];
    if (tableView == self.assetExplorerLocalizeTableView) return [self zs_assetExplorerLocalizeCellForTableView:tableView indexPath:indexPath];
    if (tableView == self.assetExplorerLocalizeJSONTableView) return [self zs_assetExplorerLocalizeJSONCellForTableView:tableView indexPath:indexPath];
    if (tableView == self.assetExplorerFMODTableView) return [self zs_assetExplorerFMODCellForTableView:tableView indexPath:indexPath];
    static NSString * const identifier = @"zs.asset.explorer.cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.textLabel.font = zs_mono_font(11, UIFontWeightRegular);
    cell.textLabel.textColor = [UIColor colorWithWhite:0.94 alpha:1];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.65;
    cell.detailTextLabel.font = zs_mono_font(9, UIFontWeightRegular);
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.38];
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.5;
    cell.accessoryType = self.assetExplorerSelectedBundle ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.tintColor = [UIColor colorWithWhite:1 alpha:0.5];
    UIView *selected = [[UIView alloc] init];
    selected.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    cell.selectedBackgroundView = selected;

    if (!self.assetExplorerSelectedBundle) {
        NSInteger bundleIndex = [self zs_assetExplorerBundleIndexForIndexPath:indexPath];
        ZSAssetExplorerBundle *bundle = bundleIndex >= 0 && bundleIndex < (NSInteger)self.assetExplorerDisplayedBundles.count ? self.assetExplorerDisplayedBundles[(NSUInteger)bundleIndex] : nil;
        NSString *bundleRemark = [self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForBundle:bundle]];
        cell.textLabel.text = bundleRemark ?: (bundle.displayName ?: @"CAB-???????");
        NSNumber *bundleSize = bundle.filePath ? self.assetExplorerBundleSizes[bundle.filePath] : nil;
        NSString *cabText = bundle.cabIdentifier ?: @"";
        if (bundleRemark && bundle.displayName.length > 0 && ![bundle.displayName isEqualToString:cabText]) {
            cabText = cabText.length > 0 ? [NSString stringWithFormat:@"%@  •  %@", bundle.displayName, cabText] : bundle.displayName;
        }
        NSString *detail = bundleSize ? [NSString stringWithFormat:@"%@  •  %@", cabText, [NSByteCountFormatter stringFromByteCount:bundleSize.longLongValue countStyle:NSByteCountFormatterCountStyleFile]] : cabText;
        NSNumber *bundleDate = nil;
        if (bundle.filePath) {
            if (self.assetExplorerBundleSortByDate) bundleDate = self.assetExplorerBundleDates[bundle.filePath];
            else if (self.assetExplorerBundleSortByCreation) bundleDate = self.assetExplorerBundleCreations[bundle.filePath];
        }
        if (bundleDate && bundleDate.longLongValue > 0) {
            static NSDateFormatter *dateFormatter;
            static dispatch_once_t dateFormatterOnce;
            dispatch_once(&dateFormatterOnce, ^{
                dateFormatter = [[NSDateFormatter alloc] init];
                dateFormatter.dateStyle = NSDateFormatterMediumStyle;
                dateFormatter.timeStyle = NSDateFormatterShortStyle;
            });
            detail = [NSString stringWithFormat:@"%@  •  %@", detail, [dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:bundleDate.doubleValue]]];
        }
        BOOL recent = bundle && self.assetExplorerRecentKey.length > 0 && [zs_asset_explorer_bundle_key(bundle) isEqualToString:self.assetExplorerRecentKey];
        zs_ae_set_detail(cell.detailTextLabel, detail, recent);
    } else {
        cell.detailTextLabel.attributedText = nil;
        ZSAssetExplorerAsset *asset = indexPath.row < self.assetExplorerDisplayedAssets.count ? self.assetExplorerDisplayedAssets[(NSUInteger)indexPath.row] : nil;
        NSString *display = asset.assetName.length > 0 ? asset.assetName : asset.typeName;
        NSString *assetRemark = [self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForAsset:asset]];
        cell.textLabel.text = assetRemark ?: (display.length > 0 ? display : @"Unnamed asset");
        NSString *assetDetail = [NSString stringWithFormat:@"%@  •  PathID %lld  •  %u bytes", asset.typeName ?: @"Unknown", (long long)asset.pathID, asset.objectSize];
        if (assetRemark && asset.assetName.length > 0) assetDetail = [NSString stringWithFormat:@"%@  •  %@", asset.assetName, assetDetail];
        cell.detailTextLabel.text = assetDetail;
        BOOL previewable = [ZSAssetExplorer hasVisualPreviewForClassID:asset.classID];
        cell.accessoryType = previewable ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        if (!previewable) {
            cell.textLabel.textColor = [UIColor colorWithWhite:1 alpha:0.28];
            cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.16];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    return cell;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point API_AVAILABLE(ios(13.0)) {
    if (tableView == self.assetExplorerTableView && self.modsLibraryBrowseMode && !self.modsLibrarySelectedEntry) return [self zs_modsLibraryContextMenuForIndexPath:indexPath];
    if (tableView == self.assetExplorerLocalizeTableView) return [self zs_assetExplorerLocalizeContextMenuForIndexPath:indexPath];
    if (tableView == self.assetExplorerLocalizeJSONTableView) return [self zs_assetExplorerLocalizeJSONContextMenuForIndexPath:indexPath];
    if (tableView == self.assetExplorerFMODTableView) return [self zs_assetExplorerFMODContextMenuForIndexPath:indexPath];
    if (tableView == self.assetExplorerTableView && !self.assetExplorerSelectedBundle && !self.assetExplorerHubVisible) {
        NSInteger bundleIndex = [self zs_assetExplorerBundleIndexForIndexPath:indexPath];
        if (bundleIndex < 0 || bundleIndex >= (NSInteger)self.assetExplorerDisplayedBundles.count) return nil;
        ZSAssetExplorerBundle *bundle = self.assetExplorerDisplayedBundles[(NSUInteger)bundleIndex];
        return [self zs_assetExplorerMenuWithRemarkKey:[self zs_assetExplorerRemarkKeyForBundle:bundle]
                                            bookmarkKey:zs_asset_explorer_bundle_key(bundle)
                                            bookmarkSet:[self zs_assetExplorerBookmarks]
                                             extraItems:nil];
    }
    if (tableView != self.assetExplorerTableView || !self.assetExplorerSelectedBundle || self.assetExplorerTextureOpen) return nil;
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.assetExplorerDisplayedAssets.count) return nil;
    ZSAssetExplorerAsset *asset = self.assetExplorerDisplayedAssets[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *exportAction = [UIAction actionWithTitle:@"Export" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf zs_assetExplorerExportAsset:asset full:NO];
        }];
        UIAction *fullJSONAction = [UIAction actionWithTitle:@".json" image:[UIImage systemImageNamed:@"curlybraces"] identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf zs_assetExplorerExportAsset:asset full:YES jsonOnly:YES];
        }];
        UIAction *fullRawAction = [UIAction actionWithTitle:@"raw" image:[UIImage systemImageNamed:@"doc.zipper"] identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf zs_assetExplorerExportAsset:asset full:YES jsonOnly:NO];
        }];
        UIMenu *fullExportMenu = [UIMenu menuWithTitle:@"Full Export" image:[UIImage systemImageNamed:@"doc.zipper"] identifier:nil options:0 children:@[fullJSONAction, fullRawAction]];
        return [UIMenu menuWithTitle:@"" children:@[[weakSelf zs_assetExplorerRemarkActionForKey:[weakSelf zs_assetExplorerRemarkKeyForAsset:asset]], exportAction, fullExportMenu]];
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    if (tableView == self.assetExplorerTableView && self.modsLibraryBrowseMode && !self.modsLibrarySelectedEntry) {
        return [self zs_modsLibraryDeleteSwipeForIndexPath:indexPath];
    }
    if (tableView == self.assetExplorerFMODTableView) return [self zs_assetExplorerFMODSwipeForIndexPath:indexPath];
    if (tableView == self.assetExplorerLocalizeTableView) return [self zs_assetExplorerLocalizeSwipeForIndexPath:indexPath];
    if (tableView != self.assetExplorerTableView || self.assetExplorerHubVisible) return nil;
    if (self.assetExplorerSelectedBundle) {
        if (self.assetExplorerTextureOpen || indexPath.row < 0 || indexPath.row >= (NSInteger)self.assetExplorerDisplayedAssets.count) return nil;
        ZSAssetExplorerAsset *asset = self.assetExplorerDisplayedAssets[(NSUInteger)indexPath.row];
        return [self zs_assetExplorerSwipeWithRemarkKey:[self zs_assetExplorerRemarkKeyForAsset:asset] bookmarkKey:nil bookmarkSet:nil];
    }
    NSInteger bundleIndex = [self zs_assetExplorerBundleIndexForIndexPath:indexPath];
    if (bundleIndex < 0 || bundleIndex >= (NSInteger)self.assetExplorerDisplayedBundles.count) return nil;
    ZSAssetExplorerBundle *bundle = self.assetExplorerDisplayedBundles[(NSUInteger)bundleIndex];
    return [self zs_assetExplorerSwipeWithRemarkKey:[self zs_assetExplorerRemarkKeyForBundle:bundle]
                                         bookmarkKey:zs_asset_explorer_bundle_key(bundle)
                                         bookmarkSet:[self zs_assetExplorerBookmarks]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    if (tableView == self.assetExplorerTableView && self.modsLibraryBrowseMode && !self.modsLibrarySelectedEntry) {
        return [self zs_modsLibraryRemarkSwipeForIndexPath:indexPath];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.assetExplorerTableView && self.modsLibraryBrowseMode) {
        [self zs_modsLibrarySelectRowAtIndexPath:indexPath inTableView:tableView];
        return;
    }
    if (tableView == self.assetExplorerLocalizeTableView) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self zs_assetExplorerLocalizeSelectRow:[self zs_assetExplorerListIndexForIndexPath:indexPath inTableView:tableView]];
        return;
    }
    if (tableView == self.assetExplorerLocalizeJSONTableView) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self zs_assetExplorerLocalizeToggleRow:indexPath.row];
        return;
    }
    if (tableView == self.assetExplorerFMODTableView) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if (self.assetExplorerFMODBankFile) {
            if (indexPath.row >= 0 && indexPath.row < (NSInteger)self.assetExplorerFMODDisplayedStreams.count) {
                [self zs_assetExplorerFMODOpenStream:self.assetExplorerFMODDisplayedStreams[(NSUInteger)indexPath.row]];
            }
        } else {
            NSInteger bankIndex = [self zs_assetExplorerListIndexForIndexPath:indexPath inTableView:tableView];
            if (bankIndex >= 0 && bankIndex < (NSInteger)self.assetExplorerFMODDisplayedBanks.count) {
                [self zs_assetExplorerFMODOpenBankFile:self.assetExplorerFMODDisplayedBanks[(NSUInteger)bankIndex]];
            }
        }
        return;
    }
    if (tableView != self.assetExplorerTableView) return;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.assetExplorerSelectedBundle) {
        if (self.assetExplorerTextureOpen || indexPath.row >= self.assetExplorerDisplayedAssets.count) return;
        ZSAssetExplorerAsset *asset = self.assetExplorerDisplayedAssets[(NSUInteger)indexPath.row];
        if ([ZSAssetExplorer hasVisualPreviewForClassID:asset.classID]) [self zs_assetExplorerOpenTextureForAsset:asset];
        return;
    }
    NSInteger bundleIndex = [self zs_assetExplorerBundleIndexForIndexPath:indexPath];
    if (bundleIndex < 0 || bundleIndex >= (NSInteger)self.assetExplorerDisplayedBundles.count) return;
    [self zs_assetExplorerOpenBundle:self.assetExplorerDisplayedBundles[(NSUInteger)bundleIndex]];
}

#pragma mark Asset explorer hub and FMOD banks

- (UIButton *)zs_assetExplorerMakeHubTileWithSymbol:(NSString *)symbol title:(NSString *)title action:(SEL)action {
    UIButton *tile = [UIButton buttonWithType:UIButtonTypeCustom];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    tile.layer.cornerRadius = 32;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    tile.layer.borderWidth = 1;
    tile.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    tile.clipsToBounds = YES;
    [tile addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [tile addTarget:self action:@selector(zs_assetExplorerHubTilePressed:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [tile addTarget:self action:@selector(zs_assetExplorerHubTileReleased:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];

    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:46 weight:UIImageSymbolWeightRegular];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:symbolConfig]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.92];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.userInteractionEnabled = NO;
    [tile addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = zs_mono_font(11, UIFontWeightSemibold);
    label.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.6;
    label.userInteractionEnabled = NO;
    [tile addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor constant:-12],
        [label.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:10],
        [label.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-10],
        [label.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-14],
    ]];
    return tile;
}

- (void)zs_assetExplorerHubTilePressed:(UIButton *)tile {
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        tile.transform = CGAffineTransformMakeScale(0.96, 0.96);
        tile.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    } completion:nil];
}

- (void)zs_assetExplorerHubTileReleased:(UIButton *)tile {
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        tile.transform = CGAffineTransformIdentity;
        tile.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    } completion:nil];
}

- (void)zs_assetExplorerBuildHubAndFMODViews {
    UIView *overlay = self.assetExplorerFullScreenOverlay;
    UIButton *closeButton = self.assetExplorerCloseButton;
    if (!overlay || !closeButton || self.assetExplorerHubView) return;

    UITableView *fmodTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    fmodTable.translatesAutoresizingMaskIntoConstraints = NO;
    fmodTable.backgroundColor = UIColor.clearColor;
    fmodTable.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    fmodTable.separatorInset = UIEdgeInsetsMake(0, kPanelPadding, 0, kPanelPadding);
    fmodTable.showsVerticalScrollIndicator = NO;
    fmodTable.showsHorizontalScrollIndicator = NO;
    fmodTable.rowHeight = 48;
    fmodTable.estimatedRowHeight = 48;
    if (@available(iOS 15.0, *)) fmodTable.sectionHeaderTopPadding = 0;
    fmodTable.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    fmodTable.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    fmodTable.dataSource = self;
    fmodTable.delegate = self;
    fmodTable.hidden = YES;
    [overlay addSubview:fmodTable];
    self.assetExplorerFMODTableView = fmodTable;

    UITableView *localizeTable = [self zs_assetExplorerMakeLocalizeTableWithRowHeight:48];
    [overlay addSubview:localizeTable];
    self.assetExplorerLocalizeTableView = localizeTable;

    UITableView *localizeJSONTable = [self zs_assetExplorerMakeLocalizeTableWithRowHeight:0];
    [localizeJSONTable registerClass:[ZSLocJSONCell class] forCellReuseIdentifier:@"zs.asset.explorer.localize.json.cell"];
    [overlay addSubview:localizeJSONTable];
    self.assetExplorerLocalizeJSONTableView = localizeJSONTable;

    UIView *localizeJSONBottom = self.assetExplorerTextureCaptionLabel;
    [NSLayoutConstraint activateConstraints:@[
        [localizeTable.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:12],
        [localizeTable.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [localizeTable.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [localizeTable.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor],

        [localizeJSONTable.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:12],
        [localizeJSONTable.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [localizeJSONTable.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [localizeJSONTable.bottomAnchor constraintEqualToAnchor:(localizeJSONBottom ? localizeJSONBottom.topAnchor : overlay.safeAreaLayoutGuide.bottomAnchor) constant:(localizeJSONBottom ? -8 : 0)],
    ]];

    UIView *hub = [[UIView alloc] init];
    hub.translatesAutoresizingMaskIntoConstraints = NO;
    hub.backgroundColor = UIColor.clearColor;
    hub.hidden = YES;
    [overlay addSubview:hub];
    self.assetExplorerHubView = hub;

    UIButton *unityTile = [self zs_assetExplorerMakeHubTileWithSymbol:@"shippingbox.fill" title:@"Unity Asset Bundles" action:@selector(zs_assetExplorerHubUnityTapped)];
    UIButton *fmodTile = [self zs_assetExplorerMakeHubTileWithSymbol:@"waveform" title:@"FMOD Audio Banks" action:@selector(zs_assetExplorerHubFMODTapped)];
    UIButton *localizeTile = [self zs_assetExplorerMakeHubTileWithSymbol:@"globe" title:@"Localizations" action:@selector(zs_assetExplorerHubLocalizeTapped)];

    UIStackView *tiles = [[UIStackView alloc] initWithArrangedSubviews:@[unityTile, fmodTile, localizeTile]];
    tiles.translatesAutoresizingMaskIntoConstraints = NO;
    tiles.axis = UILayoutConstraintAxisHorizontal;
    tiles.alignment = UIStackViewAlignmentCenter;
    tiles.distribution = UIStackViewDistributionFillEqually;
    tiles.spacing = 16;
    [hub addSubview:tiles];

    NSLayoutConstraint *preferredSize = [unityTile.heightAnchor constraintEqualToConstant:200];
    preferredSize.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [fmodTable.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:12],
        [fmodTable.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [fmodTable.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [fmodTable.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor],

        [hub.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:12],
        [hub.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset],
        [hub.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [hub.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor constant:-8],

        [tiles.centerXAnchor constraintEqualToAnchor:hub.centerXAnchor],
        [tiles.centerYAnchor constraintEqualToAnchor:hub.centerYAnchor],
        [unityTile.widthAnchor constraintEqualToAnchor:unityTile.heightAnchor],
        [fmodTile.widthAnchor constraintEqualToAnchor:fmodTile.heightAnchor],
        [fmodTile.heightAnchor constraintEqualToAnchor:unityTile.heightAnchor],
        [localizeTile.widthAnchor constraintEqualToAnchor:localizeTile.heightAnchor],
        [localizeTile.heightAnchor constraintEqualToAnchor:unityTile.heightAnchor],
        [unityTile.heightAnchor constraintLessThanOrEqualToAnchor:hub.heightAnchor multiplier:0.92],
        [unityTile.widthAnchor constraintLessThanOrEqualToAnchor:hub.widthAnchor multiplier:0.3333 constant:-11],
        preferredSize,
    ]];
}

- (void)zs_assetExplorerShowHub {
    [self.assetExplorerSearchField resignFirstResponder];
    self.assetExplorerGeneration += 1;
    self.assetExplorerNamesSession += 1;
    self.assetExplorerFMODGeneration += 1;
    self.assetExplorerSelectedBundle = nil;
    self.assetExplorerAssets = @[];
    self.assetExplorerFMODBankFile = nil;
    self.assetExplorerFMODBank = nil;
    self.assetExplorerFMODStream = nil;
    self.assetExplorerFMODBankFiles = @[];
    self.assetExplorerFMODDisplayedBanks = @[];
    self.assetExplorerFMODDisplayedStreams = @[];
    self.assetExplorerFMODSortMode = 0;
    self.assetExplorerFMODMode = NO;
    self.assetExplorerHubVisible = YES;
    self.assetExplorerStatusMessage = nil;
    [self zs_assetExplorerLocalizeReset];
    [self zs_assetExplorerResetViewState];
    [self zs_assetExplorerSetTextureModeVisible:NO];
    [self.assetExplorerFMODTableView reloadData];
    [self zs_assetExplorerFMODApplyLevel];
}

- (void)zs_assetExplorerHubUnityTapped {
    if (!self.assetExplorerHubVisible) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    self.assetExplorerHubVisible = NO;
    self.assetExplorerFMODMode = NO;
    self.assetExplorerHubView.hidden = YES;
    self.assetExplorerFMODTableView.hidden = YES;
    [self zs_assetExplorerLoadBundles];
}

- (void)zs_assetExplorerHubFMODTapped {
    if (!self.assetExplorerHubVisible) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    self.assetExplorerHubVisible = NO;
    self.assetExplorerFMODMode = YES;
    [self zs_assetExplorerFMODLoadBanks];
}

- (void)zs_assetExplorerFMODApplyLevel {
    BOOL hub = self.assetExplorerHubVisible;
    BOOL detail = !hub && self.assetExplorerFMODStream != nil;
    BOOL inBank = self.assetExplorerFMODBankFile != nil;

    self.assetExplorerHubView.hidden = !hub;
    self.assetExplorerTableView.hidden = YES;
    self.assetExplorerFMODTableView.hidden = hub || detail;
    self.assetExplorerLocalizeTableView.hidden = YES;
    self.assetExplorerLocalizeJSONTableView.hidden = YES;
    self.assetExplorerTextView.hidden = !detail;
    self.assetExplorerTitleLabel.hidden = detail;
    self.assetExplorerStatusLabel.hidden = hub || detail;
    self.assetExplorerCloseButton.hidden = !(hub || detail);
    self.assetExplorerBackButton.hidden = hub || detail;
    self.assetExplorerTextureBackButton.hidden = !detail;
    self.assetExplorerTextureExportButton.hidden = !detail;
    self.assetExplorerTextureExportButton.enabled = detail;
    self.assetExplorerTextureExportButton.alpha = detail ? 1 : 0.35;
    self.assetExplorerTitleLabel.text = hub ? @"Asset Explorer" : (inBank ? ([self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForBankFile:self.assetExplorerFMODBankFile]] ?: self.assetExplorerFMODBankFile.fileName) : @"FMOD Audio Banks");
    [self zs_assetExplorerSyncControls];
}

- (void)zs_assetExplorerFMODSyncControls {
    BOOL hub = self.assetExplorerHubVisible;
    BOOL inBank = self.assetExplorerFMODBankFile != nil;
    BOOL detail = self.assetExplorerFMODStream != nil;
    BOOL hideControls = hub || detail;
    self.assetExplorerSearchContainer.hidden = hideControls;
    self.assetExplorerControlsStack.hidden = hideControls;
    self.assetExplorerFilterButton.hidden = YES;
    self.assetExplorerSortButton.hidden = NO;
    self.assetExplorerShareButton.hidden = !inBank;
    self.assetExplorerShareButton.enabled = YES;
    self.assetExplorerShareButton.alpha = 1;
    NSString *placeholder = inBank ? @"Search streams" : @"Search banks";
    self.assetExplorerSearchField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:placeholder
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    if (!hideControls) [self zs_assetExplorerFMODRebuildMenus];
}

- (void)zs_assetExplorerFMODRebuildMenus {
    if (!self.assetExplorerSortButton) return;
    __weak typeof(self) weakSelf = self;
    BOOL inBank = self.assetExplorerFMODBankFile != nil;
    NSArray<NSString *> *titles = inBank
        ? @[@"Index", @"Name · A–Z", @"Size · Largest first", @"Length · Longest first"]
        : @[@"Name · A–Z", @"Name · Z–A", @"Size · Largest first", @"Size · Smallest first"];
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIAction *action = [UIAction actionWithTitle:titles[(NSUInteger)i] image:nil identifier:nil handler:^(__kindof UIAction *selected) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.assetExplorerFMODSortMode = i;
            [strongSelf zs_assetExplorerFMODRefreshListResettingScroll:YES];
            [strongSelf zs_assetExplorerFMODRebuildMenus];
        }];
        action.state = self.assetExplorerFMODSortMode == i ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:action];
    }
    NSInteger desiredSortStyle = self.assetExplorerFMODSortMode != 0 ? 1 : 0;
    if (self.assetExplorerSortButton.tag != desiredSortStyle) {
        UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
        UIColor *tint = desiredSortStyle ? zs_accent_green_color() : [UIColor colorWithWhite:1 alpha:0.9];
        zs_style_pill_icon_button_as_native_glass(self.assetExplorerSortButton, [UIImage systemImageNamed:@"arrow.up.arrow.down" withConfiguration:symbolConfig], tint);
        self.assetExplorerSortButton.tag = desiredSortStyle;
    }
    self.assetExplorerSortButton.menu = [UIMenu menuWithTitle:@"Sort" children:items];
    self.assetExplorerSortButton.showsMenuAsPrimaryAction = YES;
}

- (void)zs_assetExplorerFMODLoadBanks {
    self.assetExplorerFMODGeneration += 1;
    NSUInteger generation = self.assetExplorerFMODGeneration;
    self.assetExplorerFMODBankFile = nil;
    self.assetExplorerFMODBank = nil;
    self.assetExplorerFMODStream = nil;
    self.assetExplorerFMODBankFiles = @[];
    self.assetExplorerFMODDisplayedBanks = @[];
    self.assetExplorerFMODDisplayedStreams = @[];
    self.assetExplorerFMODSortMode = 0;
    self.assetExplorerSearchField.text = @"";
    self.assetExplorerStatusMessage = @"Loading…";
    [self zs_assetExplorerFMODApplyLevel];
    [self zs_assetExplorerFMODRefreshListResettingScroll:YES];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<ZSFMODBankFile *> *banks = [ZSFMODExplorer availableBanks:&error];
        NSMutableSet<NSString *> *modded = [NSMutableSet set];
        for (NSString *relative in [BankTransplant documentsRelativePathsOfSwappedBanks] ?: @[]) {
            [modded addObject:relative.lastPathComponent];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || !strongSelf.assetExplorerFMODMode || strongSelf.assetExplorerFMODGeneration != generation) return;
            strongSelf.assetExplorerFMODBankFiles = banks ?: @[];
            strongSelf.assetExplorerFMODModdedNames = modded;
            strongSelf.assetExplorerStatusMessage = error.localizedDescription;
            [strongSelf zs_assetExplorerFMODRefreshListResettingScroll:NO];
        });
    });
}

- (void)zs_assetExplorerFMODOpenBankFile:(ZSFMODBankFile *)file {
    if (!file || self.assetExplorerFMODBankFile) return;
    [self zs_assetExplorerBookmarks];
    self.assetExplorerFMODRecentKey = file.fileName;
    [self zs_assetExplorerPersistState];
    [self.assetExplorerSearchField resignFirstResponder];
    self.assetExplorerFMODGeneration += 1;
    NSUInteger generation = self.assetExplorerFMODGeneration;
    self.assetExplorerFMODBankFile = file;
    self.assetExplorerFMODBank = nil;
    self.assetExplorerFMODStream = nil;
    self.assetExplorerFMODDisplayedStreams = @[];
    self.assetExplorerFMODSortMode = 0;
    self.assetExplorerSearchField.text = @"";
    self.assetExplorerStatusMessage = @"Reading…";
    [self zs_assetExplorerFMODApplyLevel];
    [self zs_assetExplorerFMODRefreshListResettingScroll:YES];

    __weak typeof(self) weakSelf = self;
    NSString *path = [file.filePath copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        ZSFMODBank *bank = [ZSFMODExplorer openBankAtPath:path error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || !strongSelf.assetExplorerFMODMode || strongSelf.assetExplorerFMODGeneration != generation || strongSelf.assetExplorerFMODBankFile != file) return;
            strongSelf.assetExplorerFMODBank = bank;
            if (error) {
                strongSelf.assetExplorerStatusMessage = error.localizedDescription;
            } else {
                strongSelf.assetExplorerStatusMessage = bank.streams.count == 0 ? @"No audio streams in this bank" : nil;
            }
            [strongSelf zs_assetExplorerFMODRefreshListResettingScroll:NO];
        });
    });
}

- (void)zs_assetExplorerFMODOpenStream:(ZSFMODStream *)stream {
    ZSFMODBank *bank = self.assetExplorerFMODBank;
    if (!bank || !stream || self.assetExplorerFMODStream) return;
    [self.assetExplorerSearchField resignFirstResponder];
    self.assetExplorerFMODStream = stream;
    self.assetExplorerTextView.text = [ZSFMODExplorer detailTextForStream:stream inBank:bank];
    [self.assetExplorerTextView setContentOffset:CGPointZero animated:NO];
    [self zs_assetExplorerFMODApplyLevel];
}

- (void)zs_assetExplorerFMODCloseStream {
    if (!self.assetExplorerFMODStream) return;
    self.assetExplorerFMODStream = nil;
    self.assetExplorerTextView.text = @"";
    [self zs_assetExplorerFMODApplyLevel];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_assetExplorerFMODBackTapped {
    [self.assetExplorerSearchField resignFirstResponder];
    if (self.assetExplorerFMODStream) {
        [self zs_assetExplorerFMODCloseStream];
        return;
    }
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    if (self.assetExplorerFMODBankFile) {
        self.assetExplorerFMODGeneration += 1;
        self.assetExplorerFMODBankFile = nil;
        self.assetExplorerFMODBank = nil;
        self.assetExplorerFMODDisplayedStreams = @[];
        self.assetExplorerFMODSortMode = 0;
        self.assetExplorerSearchField.text = @"";
        self.assetExplorerStatusMessage = nil;
        [self zs_assetExplorerFMODApplyLevel];
        [self zs_assetExplorerFMODRefreshListResettingScroll:YES];
        return;
    }
    [self zs_assetExplorerShowHub];
}

- (void)zs_assetExplorerFMODRefreshListResettingScroll:(BOOL)resetScroll {
    NSString *query = [self.assetExplorerSearchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSInteger mode = self.assetExplorerFMODSortMode;
    NSUInteger shown = 0;
    NSUInteger total = 0;
    NSString *noun = nil;

    if (!self.assetExplorerFMODBankFile) {
        NSMutableArray<ZSFMODBankFile *> *matches = [NSMutableArray array];
        for (ZSFMODBankFile *file in self.assetExplorerFMODBankFiles) {
            if (query.length > 0 &&
                ![file.fileName localizedCaseInsensitiveContainsString:query] &&
                ![[self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForBankFile:file]] localizedCaseInsensitiveContainsString:query]) continue;
            [matches addObject:file];
        }
        NSArray<ZSFMODBankFile *> *sortedBanks = [matches sortedArrayUsingComparator:^NSComparisonResult(ZSFMODBankFile *a, ZSFMODBankFile *b) {
            if (mode == 2 || mode == 3) {
                if (a.fileSize != b.fileSize) {
                    BOOL aLarger = a.fileSize > b.fileSize;
                    return (aLarger == (mode == 2)) ? NSOrderedAscending : NSOrderedDescending;
                }
            }
            NSComparisonResult result = [a.fileName compare:b.fileName options:NSCaseInsensitiveSearch | NSNumericSearch];
            if (mode == 1) {
                if (result == NSOrderedAscending) return NSOrderedDescending;
                if (result == NSOrderedDescending) return NSOrderedAscending;
            }
            return result;
        }];
        NSMutableOrderedSet<NSString *> *fmodBookmarks = [self zs_assetExplorerFMODBookmarks];
        NSMutableArray<ZSFMODBankFile *> *bookmarkedBanks = [NSMutableArray array];
        NSMutableArray<ZSFMODBankFile *> *moddedBanks = [NSMutableArray array];
        NSMutableArray<ZSFMODBankFile *> *stockBanks = [NSMutableArray array];
        for (ZSFMODBankFile *file in sortedBanks) {
            if (file.fileName.length > 0 && [fmodBookmarks containsObject:file.fileName]) {
                [bookmarkedBanks addObject:file];
            } else if (file.fileName.length > 0 && [self.assetExplorerFMODModdedNames containsObject:file.fileName]) {
                [moddedBanks addObject:file];
            } else {
                [stockBanks addObject:file];
            }
        }
        self.assetExplorerFMODDisplayedBookmarkedCount = bookmarkedBanks.count;
        self.assetExplorerFMODDisplayedModdedCount = moddedBanks.count;
        [bookmarkedBanks addObjectsFromArray:moddedBanks];
        [bookmarkedBanks addObjectsFromArray:stockBanks];
        self.assetExplorerFMODDisplayedBanks = bookmarkedBanks;
        self.assetExplorerFMODDisplayedStreams = @[];
        shown = self.assetExplorerFMODDisplayedBanks.count;
        total = self.assetExplorerFMODBankFiles.count;
        noun = @"bank";
    } else {
        NSArray<ZSFMODStream *> *all = self.assetExplorerFMODBank.streams ?: @[];
        NSMutableArray<ZSFMODStream *> *matches = [NSMutableArray array];
        for (ZSFMODStream *stream in all) {
            if (query.length > 0) {
                BOOL hit = [stream.name localizedCaseInsensitiveContainsString:query] ||
                           [[self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForStream:stream]] localizedCaseInsensitiveContainsString:query] ||
                           [stream.codecName localizedCaseInsensitiveContainsString:query] ||
                           [[NSString stringWithFormat:@"%ld", (long)stream.index] containsString:query];
                if (!hit) continue;
            }
            [matches addObject:stream];
        }
        if (mode == 0) {
            self.assetExplorerFMODDisplayedStreams = matches;
        } else {
            self.assetExplorerFMODDisplayedStreams = [matches sortedArrayUsingComparator:^NSComparisonResult(ZSFMODStream *a, ZSFMODStream *b) {
                if (mode == 2 && a.dataSize != b.dataSize) return a.dataSize > b.dataSize ? NSOrderedAscending : NSOrderedDescending;
                if (mode == 3 && a.duration != b.duration) return a.duration > b.duration ? NSOrderedAscending : NSOrderedDescending;
                NSComparisonResult result = [a.name compare:b.name options:NSCaseInsensitiveSearch | NSNumericSearch];
                if (result != NSOrderedSame) return result;
                if (a.index < b.index) return NSOrderedAscending;
                if (a.index > b.index) return NSOrderedDescending;
                return NSOrderedSame;
            }];
        }
        self.assetExplorerFMODDisplayedBanks = @[];
        shown = self.assetExplorerFMODDisplayedStreams.count;
        total = all.count;
        noun = @"stream";
    }

    NSString *message = self.assetExplorerStatusMessage;
    if (message.length == 0) {
        NSString *plural = total == 1 ? @"" : @"s";
        message = shown == total
            ? [NSString stringWithFormat:@"%lu %@%@", (unsigned long)total, noun, plural]
            : [NSString stringWithFormat:@"%lu of %lu %@%@", (unsigned long)shown, (unsigned long)total, noun, plural];
    }
    self.assetExplorerStatusLabel.text = message;
    [self.assetExplorerFMODTableView reloadData];
    if (resetScroll) [self.assetExplorerFMODTableView setContentOffset:CGPointZero animated:NO];
}

- (UITableViewCell *)zs_assetExplorerFMODCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier = @"zs.asset.explorer.fmod.cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.textLabel.font = zs_mono_font(11, UIFontWeightRegular);
    cell.textLabel.textColor = [UIColor colorWithWhite:0.94 alpha:1];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.65;
    cell.detailTextLabel.font = zs_mono_font(9, UIFontWeightRegular);
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.38];
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.5;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.tintColor = [UIColor colorWithWhite:1 alpha:0.5];
    UIView *selected = [[UIView alloc] init];
    selected.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    cell.selectedBackgroundView = selected;

    if (!self.assetExplorerFMODBankFile) {
        NSInteger bankIndex = [self zs_assetExplorerListIndexForIndexPath:indexPath inTableView:tableView];
        ZSFMODBankFile *file = bankIndex >= 0 && bankIndex < (NSInteger)self.assetExplorerFMODDisplayedBanks.count ? self.assetExplorerFMODDisplayedBanks[(NSUInteger)bankIndex] : nil;
        NSString *bankRemark = [self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForBankFile:file]];
        cell.textLabel.text = bankRemark ?: (file.fileName ?: @"");
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (bankRemark && file.fileName.length > 0) [parts addObject:file.fileName];
        if (file.streamCount > 0) {
            [parts addObject:[NSString stringWithFormat:@"%ld stream%@", (long)file.streamCount, file.streamCount == 1 ? @"" : @"s"]];
            if (file.codecName.length > 0) [parts addObject:file.codecName];
        } else {
            [parts addObject:@"no audio streams"];
        }
        [parts addObject:[NSByteCountFormatter stringFromByteCount:(long long)file.fileSize countStyle:NSByteCountFormatterCountStyleFile]];
        if (file.fileName && [self.assetExplorerFMODModdedNames containsObject:file.fileName]) [parts addObject:@"modded"];
        BOOL bankRecent = file.fileName.length > 0 && [file.fileName isEqualToString:self.assetExplorerFMODRecentKey];
        zs_ae_set_detail(cell.detailTextLabel, [parts componentsJoinedByString:@"  •  "], bankRecent);
    } else {
        ZSFMODStream *stream = indexPath.row < (NSInteger)self.assetExplorerFMODDisplayedStreams.count ? self.assetExplorerFMODDisplayedStreams[(NSUInteger)indexPath.row] : nil;
        NSString *streamRemark = [self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForStream:stream]];
        cell.textLabel.text = streamRemark ?: (stream.name ?: @"");
        NSTimeInterval duration = stream.duration;
        NSString *length = duration >= 60 ? [NSString stringWithFormat:@"%d:%04.1f", (int)(duration / 60), duration - 60 * (int)(duration / 60)] : [NSString stringWithFormat:@"%.2f s", duration];
        NSString *channels = stream.channels == 1 ? @"mono" : (stream.channels == 2 ? @"stereo" : [NSString stringWithFormat:@"%ldch", (long)stream.channels]);
        NSString *streamDetail = [NSString stringWithFormat:@"%@  •  %@  •  %.1f kHz  •  %@  •  %@", stream.codecName, channels, stream.frequency / 1000.0, length, [NSByteCountFormatter stringFromByteCount:(long long)stream.dataSize countStyle:NSByteCountFormatterCountStyleFile]];
        if (streamRemark && stream.name.length > 0) streamDetail = [NSString stringWithFormat:@"%@  •  %@", stream.name, streamDetail];
        zs_ae_set_detail(cell.detailTextLabel, streamDetail, NO);
    }
    return cell;
}

- (UIContextMenuConfiguration *)zs_assetExplorerFMODContextMenuForIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(13.0)) {
    __weak typeof(self) weakSelf = self;
    if (self.assetExplorerFMODBankFile) {
        if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.assetExplorerFMODDisplayedStreams.count) return nil;
        ZSFMODStream *stream = self.assetExplorerFMODDisplayedStreams[(NSUInteger)indexPath.row];
        return [self zs_assetExplorerMenuWithRemarkKey:[self zs_assetExplorerRemarkKeyForStream:stream]
                                            bookmarkKey:nil
                                            bookmarkSet:nil
                                             extraItems:[self zs_assetExplorerFMODExportMenuForStream:stream].children];
    }
    NSInteger bankIndex = [self zs_assetExplorerListIndexForIndexPath:indexPath inTableView:self.assetExplorerFMODTableView];
    if (bankIndex < 0 || bankIndex >= (NSInteger)self.assetExplorerFMODDisplayedBanks.count) return nil;
    ZSFMODBankFile *file = self.assetExplorerFMODDisplayedBanks[(NSUInteger)bankIndex];
    UIAction *exportAction = [UIAction actionWithTitle:@"Export" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf zs_assetExplorerFMODExportBankFile:file];
    }];
    return [self zs_assetExplorerMenuWithRemarkKey:[self zs_assetExplorerRemarkKeyForBankFile:file]
                                        bookmarkKey:file.fileName
                                        bookmarkSet:[self zs_assetExplorerFMODBookmarks]
                                         extraItems:@[exportAction]];
}

- (UISwipeActionsConfiguration *)zs_assetExplorerFMODSwipeForIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    if (self.assetExplorerFMODBankFile) {
        if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.assetExplorerFMODDisplayedStreams.count) return nil;
        ZSFMODStream *stream = self.assetExplorerFMODDisplayedStreams[(NSUInteger)indexPath.row];
        return [self zs_assetExplorerSwipeWithRemarkKey:[self zs_assetExplorerRemarkKeyForStream:stream] bookmarkKey:nil bookmarkSet:nil];
    }
    NSInteger bankIndex = [self zs_assetExplorerListIndexForIndexPath:indexPath inTableView:self.assetExplorerFMODTableView];
    if (bankIndex < 0 || bankIndex >= (NSInteger)self.assetExplorerFMODDisplayedBanks.count) return nil;
    ZSFMODBankFile *file = self.assetExplorerFMODDisplayedBanks[(NSUInteger)bankIndex];
    return [self zs_assetExplorerSwipeWithRemarkKey:[self zs_assetExplorerRemarkKeyForBankFile:file]
                                         bookmarkKey:file.fileName
                                         bookmarkSet:[self zs_assetExplorerFMODBookmarks]];
}

- (UIMenu *)zs_assetExplorerFMODExportMenuForStream:(ZSFMODStream *)stream {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    [items addObject:[UIAction actionWithTitle:@".fsb" image:[UIImage systemImageNamed:@"waveform"] identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf zs_assetExplorerFMODExportStream:stream format:ZSFMODExportFormatFSB sourceView:nil];
    }]];
    if ([ZSFMODExplorer canExportWAVForStream:stream]) {
        [items addObject:[UIAction actionWithTitle:@".wav" image:[UIImage systemImageNamed:@"speaker.wave.2"] identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf zs_assetExplorerFMODExportStream:stream format:ZSFMODExportFormatWAV sourceView:nil];
        }]];
    }
    [items addObject:[UIAction actionWithTitle:@"raw" image:[UIImage systemImageNamed:@"doc.zipper"] identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf zs_assetExplorerFMODExportStream:stream format:ZSFMODExportFormatRaw sourceView:nil];
    }]];
    return [UIMenu menuWithTitle:@"" children:items];
}

- (void)zs_assetExplorerFMODExportStreamTapped {
    ZSFMODStream *stream = self.assetExplorerFMODStream;
    if (!stream || !self.assetExplorerFMODBank) return;
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;

    UIButton *sourceButton = self.assetExplorerTextureExportButton;
    __weak typeof(self) weakSelf = self;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Standalone .fsb" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf zs_assetExplorerFMODExportStream:stream format:ZSFMODExportFormatFSB sourceView:sourceButton];
    }]];
    if ([ZSFMODExplorer canExportWAVForStream:stream]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"WAV" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf zs_assetExplorerFMODExportStream:stream format:ZSFMODExportFormatWAV sourceView:sourceButton];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Raw stream data" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf zs_assetExplorerFMODExportStream:stream format:ZSFMODExportFormatRaw sourceView:sourceButton];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = sourceButton;
    alert.popoverPresentationController.sourceRect = sourceButton.bounds;
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_assetExplorerFMODShareBankTapped {
    ZSFMODBankFile *file = self.assetExplorerFMODBankFile;
    if (!file) return;
    [self zs_assetExplorerFMODExportBankFile:file];
}

- (void)zs_assetExplorerFMODExportBankFile:(ZSFMODBankFile *)file {
    NSString *sourcePath = [file.filePath copy];
    NSString *fileName = [file.fileName copy];
    if (sourcePath.length == 0 || fileName.length == 0) return;
    [self zs_assetExplorerFMODPerformExportWithSourceView:self.assetExplorerShareButton writer:^NSString *(NSString *directory, NSError **error) {
        NSString *destination = [directory stringByAppendingPathComponent:fileName];
        return [NSFileManager.defaultManager copyItemAtPath:sourcePath toPath:destination error:error] ? destination : nil;
    }];
}

- (void)zs_assetExplorerFMODExportStream:(ZSFMODStream *)stream format:(ZSFMODExportFormat)format sourceView:(UIView *)sourceView {
    ZSFMODBank *bank = self.assetExplorerFMODBank;
    if (!bank || !stream) return;
    [self zs_assetExplorerFMODPerformExportWithSourceView:sourceView writer:^NSString *(NSString *directory, NSError **error) {
        return [ZSFMODExplorer exportStream:stream inBank:bank format:format toDirectory:directory error:error];
    }];
}

- (void)zs_assetExplorerFMODPerformExportWithSourceView:(UIView *)sourceView writer:(NSString *(^)(NSString *directory, NSError **error))writer {
    UIView *anchor = sourceView ?: self.assetExplorerFullScreenOverlay;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSFMODExport-%@", NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        NSString *path = nil;
        if ([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            path = writer(directory, &error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
                return;
            }
            UIViewController *presenter = zs_key_window().rootViewController;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            if (!path) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
                UIAlertController *failure = [UIAlertController alertControllerWithTitle:@"Export Failed" message:error.localizedDescription ?: @"Couldn't write the file." preferredStyle:UIAlertControllerStyleAlert];
                [failure addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [presenter presentViewController:failure animated:YES completion:nil];
                return;
            }
            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
            activityVC.popoverPresentationController.sourceView = anchor;
            activityVC.popoverPresentationController.sourceRect = anchor.bounds;
            activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
            };
            [presenter presentViewController:activityVC animated:YES completion:nil];
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
        });
    });
}

#pragma mark Asset explorer localizations

- (UITableView *)zs_assetExplorerMakeLocalizeTableWithRowHeight:(CGFloat)rowHeight {
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.backgroundColor = UIColor.clearColor;
    table.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    table.separatorInset = UIEdgeInsetsMake(0, kPanelPadding, 0, kPanelPadding);
    table.showsVerticalScrollIndicator = NO;
    table.showsHorizontalScrollIndicator = NO;
    if (@available(iOS 15.0, *)) table.sectionHeaderTopPadding = 0;
    table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    if (rowHeight > 0) {
        table.rowHeight = rowHeight;
        table.estimatedRowHeight = rowHeight;
    } else {
        table.rowHeight = UITableViewAutomaticDimension;
        table.estimatedRowHeight = 30;
    }
    table.dataSource = self;
    table.delegate = self;
    table.hidden = YES;
    return table;
}

- (void)zs_assetExplorerLocalizeRestoreModeControl {
    ZSModeSlider *control = self.assetExplorerModeControl;
    if (!control) return;
    if (![control.labels.firstObject isEqualToString:@"Preview"]) control.labels = @[@"Preview", @"Data"];
    control.selectedIndex = 0;
    control.hidden = YES;
}

- (void)zs_assetExplorerLocalizeReset {
    self.assetExplorerLocalizeGeneration += 1;
    self.assetExplorerLocalizeMode = NO;
    self.assetExplorerLocalizeRoot = nil;
    self.assetExplorerLocalizeDirectory = nil;
    self.assetExplorerLocalizeFilePath = nil;
    self.assetExplorerLocalizeRawText = nil;
    self.assetExplorerLocalizeRawMode = NO;
    self.assetExplorerLocalizeEntries = @[];
    self.assetExplorerLocalizeDisplayedEntries = @[];
    self.assetExplorerLocalizeOffsets = nil;
    self.assetExplorerLocalizePendingOffset = nil;
    self.assetExplorerLocalizePendingOpenFilePath = nil;
    self.assetExplorerLocalizeFileData = nil;
    self.assetExplorerLocalizeRootNode = nil;
    self.assetExplorerLocalizeVisibleRows = nil;
    self.assetExplorerLocalizeSortMode = 0;
    self.assetExplorerLocalizeModdedPaths = nil;
    self.assetExplorerLocalizeDisplayedBookmarkedCount = 0;
    self.assetExplorerLocalizeDisplayedModdedCount = 0;
    [self.assetExplorerLocalizeTableView reloadData];
    [self.assetExplorerLocalizeJSONTableView reloadData];
    self.assetExplorerLocalizeTableView.hidden = YES;
    self.assetExplorerLocalizeJSONTableView.hidden = YES;
    [self zs_assetExplorerLocalizeRestoreModeControl];
}

- (NSString *)zs_assetExplorerLocalizeRawString {
    if (self.assetExplorerLocalizeRawText) return self.assetExplorerLocalizeRawText;
    NSData *data = self.assetExplorerLocalizeFileData;
    if (!data) return @"";
    NSData *body = zs_loc_json_strip_bom(data);
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:body encoding:NSISOLatin1StringEncoding] ?: @"";
    self.assetExplorerLocalizeRawText = text;
    return text;
}

- (void)zs_assetExplorerLocalizeApplyLevel {
    BOOL inFile = self.assetExplorerLocalizeFilePath.length > 0;
    BOOL hasData = self.assetExplorerLocalizeFileData != nil;
    BOOL parsed = self.assetExplorerLocalizeRootNode != nil;
    BOOL showJSON = inFile && hasData && parsed && !self.assetExplorerLocalizeRawMode;
    BOOL showRaw = inFile && hasData && !showJSON;
    BOOL jsonWasHidden = self.assetExplorerLocalizeJSONTableView.hidden;
    BOOL rawWasHidden = self.assetExplorerTextView.hidden;

    self.assetExplorerHubView.hidden = YES;
    self.assetExplorerTableView.hidden = YES;
    self.assetExplorerFMODTableView.hidden = YES;
    self.assetExplorerLocalizeTableView.hidden = inFile;
    self.assetExplorerLocalizeJSONTableView.hidden = !showJSON;
    self.assetExplorerTextView.hidden = !showRaw;
    self.assetExplorerTextureImageView.hidden = YES;
    self.assetExplorerBackdropView.hidden = YES;
    self.assetExplorerTitleLabel.hidden = inFile;
    self.assetExplorerStatusLabel.hidden = inFile;
    self.assetExplorerCloseButton.hidden = !inFile;
    self.assetExplorerBackButton.hidden = inFile;
    self.assetExplorerTextureBackButton.hidden = !inFile;
    self.assetExplorerTextureExportButton.hidden = !inFile;
    self.assetExplorerTextureExportButton.enabled = inFile && hasData;
    self.assetExplorerTextureExportButton.alpha = (inFile && hasData) ? 1 : 0.35;
    self.assetExplorerTextureCaptionLabel.hidden = !inFile;
    self.assetExplorerModeControl.hidden = !(inFile && hasData && parsed);
    [self.assetExplorerModeControl setGlassEnabled:(inFile && hasData && parsed)];
    [self.assetExplorerModeControl setSelectedIndex:self.assetExplorerLocalizeRawMode ? 1 : 0 animated:NO];

    if (showRaw && rawWasHidden) {
        self.assetExplorerTextView.text = [self zs_assetExplorerLocalizeRawString];
        [self.assetExplorerTextView setContentOffset:CGPointZero animated:NO];
    }
    if (showJSON && jsonWasHidden) {
        [self.assetExplorerLocalizeJSONTableView reloadData];
        [self.assetExplorerLocalizeJSONTableView setContentOffset:CGPointZero animated:NO];
    }

    NSString *title = @"Localizations";
    NSString *root = self.assetExplorerLocalizeRoot;
    NSString *directory = self.assetExplorerLocalizeDirectory;
    if (root.length > 0 && directory.length > root.length) {
        NSString *relative = [directory substringFromIndex:root.length];
        while ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        if (relative.length > 0) title = relative;
    }
    self.assetExplorerTitleLabel.text = title;
    [self zs_assetExplorerSyncControls];
}

- (void)zs_assetExplorerLocalizeSyncControls {
    BOOL inFile = self.assetExplorerLocalizeFilePath.length > 0;
    self.assetExplorerSearchContainer.hidden = inFile;
    self.assetExplorerControlsStack.hidden = inFile;
    self.assetExplorerFilterButton.hidden = YES;
    self.assetExplorerSortButton.hidden = NO;
    self.assetExplorerShareButton.hidden = YES;
    self.assetExplorerSearchField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:@"Search files"
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    if (!inFile) [self zs_assetExplorerLocalizeRebuildMenus];
}

- (void)zs_assetExplorerLocalizeRebuildMenus {
    if (!self.assetExplorerSortButton) return;
    __weak typeof(self) weakSelf = self;
    NSArray<NSString *> *titles = @[@"Name · A–Z", @"Name · Z–A", @"Size · Largest first", @"Size · Smallest first"];
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIAction *action = [UIAction actionWithTitle:titles[(NSUInteger)i] image:nil identifier:nil handler:^(__kindof UIAction *selected) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.assetExplorerLocalizeSortMode = i;
            [strongSelf zs_assetExplorerLocalizeRefreshListResettingScroll:YES];
            [strongSelf zs_assetExplorerLocalizeRebuildMenus];
        }];
        action.state = self.assetExplorerLocalizeSortMode == i ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:action];
    }
    NSInteger desiredSortStyle = self.assetExplorerLocalizeSortMode != 0 ? 1 : 0;
    if (self.assetExplorerSortButton.tag != desiredSortStyle) {
        UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
        UIColor *tint = desiredSortStyle ? zs_accent_green_color() : [UIColor colorWithWhite:1 alpha:0.9];
        zs_style_pill_icon_button_as_native_glass(self.assetExplorerSortButton, [UIImage systemImageNamed:@"arrow.up.arrow.down" withConfiguration:symbolConfig], tint);
        self.assetExplorerSortButton.tag = desiredSortStyle;
    }
    self.assetExplorerSortButton.menu = [UIMenu menuWithTitle:@"Sort" children:items];
    self.assetExplorerSortButton.showsMenuAsPrimaryAction = YES;
}

- (void)zs_assetExplorerHubLocalizeTapped {
    if (!self.assetExplorerHubVisible) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    self.assetExplorerHubVisible = NO;
    self.assetExplorerFMODMode = NO;
    self.assetExplorerLocalizeMode = YES;
    NSString *root = [LocalizationTransplant localizeDirectory] ?: @"";
    self.assetExplorerLocalizeRoot = root;
    self.assetExplorerLocalizeOffsets = [NSMutableArray array];
    self.assetExplorerLocalizePendingOffset = nil;
    [self zs_assetExplorerLocalizeOpenDirectory:root];
}

- (void)zs_assetExplorerLocalizeOpenDirectory:(NSString *)path {
    [self.assetExplorerSearchField resignFirstResponder];
    self.assetExplorerLocalizeGeneration += 1;
    NSUInteger generation = self.assetExplorerLocalizeGeneration;
    self.assetExplorerLocalizeDirectory = path ?: @"";
    self.assetExplorerLocalizeFilePath = nil;
    self.assetExplorerLocalizeEntries = @[];
    self.assetExplorerLocalizeDisplayedEntries = @[];
    self.assetExplorerLocalizeSortMode = 0;
    self.assetExplorerSearchField.text = @"";
    self.assetExplorerStatusMessage = @"Loading…";
    [self zs_assetExplorerLocalizeApplyLevel];
    [self zs_assetExplorerLocalizeRefreshListResettingScroll:YES];

    __weak typeof(self) weakSelf = self;
    NSString *directory = [path copy] ?: @"";
    NSSet<NSString *> *knownModdedPaths = self.assetExplorerLocalizeModdedPaths;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fileManager = NSFileManager.defaultManager;
        BOOL isDirectory = NO;
        NSString *message = nil;
        NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
        NSSet<NSString *> *moddedPaths = knownModdedPaths;
        if (!moddedPaths) {
            NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSMutableSet<NSString *> *swapped = [NSMutableSet set];
            for (NSString *relative in [LocalizationTransplant documentsRelativePathsOfSwappedFiles] ?: @[]) {
                if (documents.length > 0) [swapped addObject:[documents stringByAppendingPathComponent:relative]];
            }
            moddedPaths = swapped;
        }
        if (directory.length == 0 || ![fileManager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
            message = @"Localize folder not found";
        } else {
            NSArray<NSString *> *names = [fileManager contentsOfDirectoryAtPath:directory error:nil] ?: @[];
            for (NSString *name in names) {
                if ([name hasPrefix:@"."]) continue;
                NSString *full = [directory stringByAppendingPathComponent:name];
                struct stat fileStat;
                if (stat(full.fileSystemRepresentation, &fileStat) != 0) continue;
                BOOL entryIsDirectory = S_ISDIR(fileStat.st_mode);
                NSInteger count = entryIsDirectory ? (NSInteger)[[fileManager contentsOfDirectoryAtPath:full error:nil] count] : 0;
                BOOL entryModded = NO;
                if (entryIsDirectory) {
                    NSString *prefix = [full stringByAppendingString:@"/"];
                    for (NSString *moddedPath in moddedPaths) {
                        if ([moddedPath hasPrefix:prefix]) {
                            entryModded = YES;
                            break;
                        }
                    }
                } else {
                    entryModded = [moddedPaths containsObject:full];
                }
                [entries addObject:@{@"name": name, @"path": full, @"dir": @(entryIsDirectory), @"size": @((long long)fileStat.st_size), @"count": @(count), @"modded": @(entryModded)}];
            }
            if (entries.count == 0) message = @"Empty folder";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || !strongSelf.assetExplorerLocalizeMode || strongSelf.assetExplorerLocalizeGeneration != generation) return;
            strongSelf.assetExplorerLocalizeEntries = entries;
            strongSelf.assetExplorerLocalizeModdedPaths = moddedPaths;
            strongSelf.assetExplorerStatusMessage = message;
            NSNumber *pending = strongSelf.assetExplorerLocalizePendingOffset;
            strongSelf.assetExplorerLocalizePendingOffset = nil;
            [strongSelf zs_assetExplorerLocalizeRefreshListResettingScroll:pending == nil];
            if (pending) {
                UITableView *table = strongSelf.assetExplorerLocalizeTableView;
                [table layoutIfNeeded];
                CGFloat maxOffset = MAX(0, table.contentSize.height - table.bounds.size.height);
                [table setContentOffset:CGPointMake(0, MIN(pending.doubleValue, maxOffset)) animated:NO];
            }
            NSString *pendingFile = strongSelf.assetExplorerLocalizePendingOpenFilePath;
            if (pendingFile.length > 0) {
                strongSelf.assetExplorerLocalizePendingOpenFilePath = nil;
                for (NSDictionary *candidate in entries) {
                    if (![candidate[@"dir"] boolValue] && [candidate[@"path"] isEqualToString:pendingFile]) {
                        [strongSelf zs_assetExplorerLocalizeOpenFile:candidate];
                        break;
                    }
                }
            }
        });
    });
}

- (void)zs_assetExplorerLocalizeRefreshListResettingScroll:(BOOL)resetScroll {
    NSString *query = [self.assetExplorerSearchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSInteger mode = self.assetExplorerLocalizeSortMode;
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSDictionary *entry in self.assetExplorerLocalizeEntries) {
        if (query.length > 0 &&
            ![entry[@"name"] localizedCaseInsensitiveContainsString:query] &&
            ![[self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForLocalizePath:entry[@"path"]]] localizedCaseInsensitiveContainsString:query]) continue;
        [matches addObject:entry];
    }
    NSArray<NSDictionary *> *sortedEntries = [matches sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL aDirectory = [a[@"dir"] boolValue];
        BOOL bDirectory = [b[@"dir"] boolValue];
        if (aDirectory != bDirectory) return aDirectory ? NSOrderedAscending : NSOrderedDescending;
        if (!aDirectory && (mode == 2 || mode == 3)) {
            long long sizeA = [a[@"size"] longLongValue];
            long long sizeB = [b[@"size"] longLongValue];
            if (sizeA != sizeB) {
                BOOL aLarger = sizeA > sizeB;
                return (aLarger == (mode == 2)) ? NSOrderedAscending : NSOrderedDescending;
            }
        }
        NSComparisonResult result = [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch | NSNumericSearch];
        if (mode == 1) {
            if (result == NSOrderedAscending) return NSOrderedDescending;
            if (result == NSOrderedDescending) return NSOrderedAscending;
        }
        return result;
    }];
    NSMutableOrderedSet<NSString *> *localizeBookmarks = [self zs_assetExplorerLocalizeBookmarks];
    NSMutableArray<NSDictionary *> *bookmarkedEntries = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *moddedEntries = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *stockEntries = [NSMutableArray array];
    for (NSDictionary *entry in sortedEntries) {
        if ([localizeBookmarks containsObject:[self zs_assetExplorerLocalizeKeyForPath:entry[@"path"]]]) {
            [bookmarkedEntries addObject:entry];
        } else if ([entry[@"modded"] boolValue]) {
            [moddedEntries addObject:entry];
        } else {
            [stockEntries addObject:entry];
        }
    }
    self.assetExplorerLocalizeDisplayedBookmarkedCount = bookmarkedEntries.count;
    self.assetExplorerLocalizeDisplayedModdedCount = moddedEntries.count;
    [bookmarkedEntries addObjectsFromArray:moddedEntries];
    [bookmarkedEntries addObjectsFromArray:stockEntries];
    self.assetExplorerLocalizeDisplayedEntries = bookmarkedEntries;

    NSUInteger shown = self.assetExplorerLocalizeDisplayedEntries.count;
    NSUInteger total = self.assetExplorerLocalizeEntries.count;
    NSString *message = self.assetExplorerStatusMessage;
    if (message.length == 0) {
        NSString *plural = total == 1 ? @"" : @"s";
        message = shown == total
            ? [NSString stringWithFormat:@"%lu item%@", (unsigned long)total, plural]
            : [NSString stringWithFormat:@"%lu of %lu item%@", (unsigned long)shown, (unsigned long)total, plural];
    }
    self.assetExplorerStatusLabel.text = message;
    [self.assetExplorerLocalizeTableView reloadData];
    if (resetScroll) [self.assetExplorerLocalizeTableView setContentOffset:CGPointZero animated:NO];
}

- (UITableViewCell *)zs_assetExplorerLocalizeCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier = @"zs.asset.explorer.localize.cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.textLabel.font = zs_mono_font(11, UIFontWeightRegular);
    cell.textLabel.textColor = [UIColor colorWithWhite:0.94 alpha:1];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.65;
    cell.detailTextLabel.font = zs_mono_font(9, UIFontWeightRegular);
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.38];
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.5;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.tintColor = [UIColor colorWithWhite:1 alpha:0.5];
    UIView *selected = [[UIView alloc] init];
    selected.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    cell.selectedBackgroundView = selected;

    NSInteger entryIndex = [self zs_assetExplorerListIndexForIndexPath:indexPath inTableView:tableView];
    NSDictionary *entry = entryIndex >= 0 && entryIndex < (NSInteger)self.assetExplorerLocalizeDisplayedEntries.count ? self.assetExplorerLocalizeDisplayedEntries[(NSUInteger)entryIndex] : nil;
    BOOL isDirectory = [entry[@"dir"] boolValue];
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
    cell.imageView.image = [UIImage systemImageNamed:(isDirectory ? @"folder" : @"doc.text") withConfiguration:symbolConfig];
    cell.imageView.tintColor = [UIColor colorWithWhite:1 alpha:0.5];
    NSString *entryPath = entry[@"path"];
    NSString *entryRemark = [self zs_assetExplorerRemarkForKey:[self zs_assetExplorerRemarkKeyForLocalizePath:entryPath]];
    cell.textLabel.text = entryRemark ?: (entry[@"name"] ?: @"");
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (entryRemark && [entry[@"name"] length] > 0) [parts addObject:entry[@"name"]];
    if (isDirectory) {
        NSInteger count = [entry[@"count"] integerValue];
        [parts addObject:[NSString stringWithFormat:@"%ld item%@", (long)count, count == 1 ? @"" : @"s"]];
    } else {
        [parts addObject:[NSByteCountFormatter stringFromByteCount:[entry[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
    }
    if ([entry[@"modded"] boolValue]) [parts addObject:@"modded"];
    NSString *entryKey = [self zs_assetExplorerLocalizeKeyForPath:entryPath];
    NSString *recentKey = self.assetExplorerLocalizeRecentKey;
    BOOL entryRecent = recentKey.length > 0 && entryKey.length > 0 &&
        ([recentKey isEqualToString:entryKey] || (isDirectory && [recentKey hasPrefix:[entryKey stringByAppendingString:@"/"]]));
    zs_ae_set_detail(cell.detailTextLabel, [parts componentsJoinedByString:@"  •  "], entryRecent);
    return cell;
}

- (void)zs_assetExplorerLocalizeSelectRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.assetExplorerLocalizeDisplayedEntries.count) return;
    NSDictionary *entry = self.assetExplorerLocalizeDisplayedEntries[(NSUInteger)row];
    if ([entry[@"dir"] boolValue]) {
        NSString *query = [self.assetExplorerSearchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        CGFloat offset = query.length == 0 ? self.assetExplorerLocalizeTableView.contentOffset.y : 0;
        if (!self.assetExplorerLocalizeOffsets) self.assetExplorerLocalizeOffsets = [NSMutableArray array];
        [self.assetExplorerLocalizeOffsets addObject:@(offset)];
        self.assetExplorerLocalizePendingOffset = nil;
        [self zs_assetExplorerLocalizeOpenDirectory:entry[@"path"]];
        return;
    }
    [self zs_assetExplorerLocalizeOpenFile:entry];
}

- (void)zs_assetExplorerLocalizeOpenFile:(NSDictionary *)entry {
    NSString *path = [entry[@"path"] copy];
    if (path.length == 0) return;
    [self zs_assetExplorerBookmarks];
    self.assetExplorerLocalizeRecentKey = [self zs_assetExplorerLocalizeKeyForPath:path];
    [self zs_assetExplorerPersistState];
    [self.assetExplorerSearchField resignFirstResponder];
    self.assetExplorerLocalizeGeneration += 1;
    NSUInteger generation = self.assetExplorerLocalizeGeneration;
    self.assetExplorerLocalizeFilePath = path;
    self.assetExplorerLocalizeFileData = nil;
    self.assetExplorerLocalizeRawText = nil;
    self.assetExplorerLocalizeRootNode = nil;
    self.assetExplorerLocalizeVisibleRows = [NSMutableArray array];
    self.assetExplorerLocalizeRawMode = NO;
    self.assetExplorerTextView.text = @"";
    self.assetExplorerTextureMessageLabel.hidden = YES;
    self.assetExplorerTextureMessageLabel.text = nil;
    ZSModeSlider *control = self.assetExplorerModeControl;
    if (![control.labels.firstObject isEqualToString:@".json"]) control.labels = @[@".json", @"raw"];
    control.selectedIndex = 0;
    self.assetExplorerTextureCaptionLabel.text = path.lastPathComponent;
    [self.assetExplorerTextureSpinner startAnimating];
    [self zs_assetExplorerLocalizeApplyLevel];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
        ZSLocJSONNode *root = data ? zs_loc_json_parse(zs_loc_json_strip_bom(data)) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || !strongSelf.assetExplorerLocalizeMode || strongSelf.assetExplorerLocalizeGeneration != generation) return;
            [strongSelf.assetExplorerTextureSpinner stopAnimating];
            if (!data) {
                strongSelf.assetExplorerTextureMessageLabel.text = error.localizedDescription ?: @"Couldn't read this file.";
                strongSelf.assetExplorerTextureMessageLabel.hidden = NO;
                return;
            }
            strongSelf.assetExplorerLocalizeFileData = data;
            strongSelf.assetExplorerLocalizeRootNode = root;
            NSMutableArray<ZSLocJSONNode *> *rows = [NSMutableArray array];
            if (root) {
                NSArray<ZSLocJSONNode *> *top = root.isContainer ? root.children : @[root];
                if (top.count == 1 && top[0].isContainer && top[0].children.count > 0) top[0].expanded = YES;
                zs_loc_json_flatten(top, rows);
            } else {
                strongSelf.assetExplorerLocalizeRawMode = YES;
            }
            strongSelf.assetExplorerLocalizeVisibleRows = rows;
            NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)data.length countStyle:NSByteCountFormatterCountStyleFile];
            strongSelf.assetExplorerTextureCaptionLabel.text = root
                ? [NSString stringWithFormat:@"%@  •  %@", path.lastPathComponent, size]
                : [NSString stringWithFormat:@"%@  •  %@  •  not valid JSON, showing raw", path.lastPathComponent, size];
            [strongSelf zs_assetExplorerLocalizeApplyLevel];
        });
    });
}

- (void)zs_assetExplorerLocalizeCloseFile {
    if (self.assetExplorerLocalizeFilePath.length == 0) return;
    self.assetExplorerLocalizeGeneration += 1;
    [self.assetExplorerTextureSpinner stopAnimating];
    self.assetExplorerTextureMessageLabel.hidden = YES;
    self.assetExplorerTextureMessageLabel.text = nil;
    self.assetExplorerLocalizeFilePath = nil;
    self.assetExplorerLocalizeFileData = nil;
    self.assetExplorerLocalizeRawText = nil;
    self.assetExplorerLocalizeRootNode = nil;
    self.assetExplorerLocalizeVisibleRows = nil;
    self.assetExplorerLocalizeRawMode = NO;
    self.assetExplorerTextView.text = @"";
    [self zs_assetExplorerLocalizeRestoreModeControl];
    [self zs_assetExplorerLocalizeApplyLevel];
    [self zs_assetExplorerLocalizeRefreshListResettingScroll:NO];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_assetExplorerLocalizeModeChanged:(ZSModeSlider *)control {
    BOOL raw = control.selectedIndex == 1;
    if (raw == self.assetExplorerLocalizeRawMode) return;
    self.assetExplorerLocalizeRawMode = raw;
    [self zs_assetExplorerLocalizeApplyLevel];
}

- (void)zs_assetExplorerLocalizeBackTapped {
    [self.assetExplorerSearchField resignFirstResponder];
    NSString *root = self.assetExplorerLocalizeRoot ?: @"";
    NSString *directory = self.assetExplorerLocalizeDirectory ?: @"";
    if (directory.length == 0 || [directory isEqualToString:root]) {
        [self zs_assetExplorerShowHub];
        UIImpactFeedbackGenerator *hubHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [hubHaptic impactOccurred];
        return;
    }
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    NSNumber *offset = self.assetExplorerLocalizeOffsets.lastObject;
    if (offset) [self.assetExplorerLocalizeOffsets removeLastObject];
    self.assetExplorerLocalizePendingOffset = offset;
    [self zs_assetExplorerLocalizeOpenDirectory:[directory stringByDeletingLastPathComponent]];
}

- (void)zs_assetExplorerLocalizeExportTapped {
    NSData *data = self.assetExplorerLocalizeFileData;
    NSString *name = [self.assetExplorerLocalizeFilePath.lastPathComponent copy];
    if (!data || name.length == 0) return;
    [self zs_assetExplorerFMODPerformExportWithSourceView:self.assetExplorerTextureExportButton writer:^NSString *(NSString *directory, NSError **error) {
        NSString *destination = [directory stringByAppendingPathComponent:name];
        return [data writeToFile:destination options:NSDataWritingAtomic error:error] ? destination : nil;
    }];
}

- (UIContextMenuConfiguration *)zs_assetExplorerLocalizeContextMenuForIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(13.0)) {
    NSInteger entryIndex = [self zs_assetExplorerListIndexForIndexPath:indexPath inTableView:self.assetExplorerLocalizeTableView];
    if (entryIndex < 0 || entryIndex >= (NSInteger)self.assetExplorerLocalizeDisplayedEntries.count) return nil;
    NSDictionary *entry = self.assetExplorerLocalizeDisplayedEntries[(NSUInteger)entryIndex];
    NSString *sourcePath = [entry[@"path"] copy];
    NSString *name = [entry[@"name"] copy];
    __weak typeof(self) weakSelf = self;
    NSArray<UIMenuElement *> *extraItems = nil;
    if (![entry[@"dir"] boolValue]) {
        UIAction *exportAction = [UIAction actionWithTitle:@"Export" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf zs_assetExplorerFMODPerformExportWithSourceView:nil writer:^NSString *(NSString *directory, NSError **error) {
                NSString *destination = [directory stringByAppendingPathComponent:name];
                return [NSFileManager.defaultManager copyItemAtPath:sourcePath toPath:destination error:error] ? destination : nil;
            }];
        }];
        extraItems = @[exportAction];
    }
    return [self zs_assetExplorerMenuWithRemarkKey:[self zs_assetExplorerRemarkKeyForLocalizePath:sourcePath]
                                        bookmarkKey:[self zs_assetExplorerLocalizeKeyForPath:sourcePath]
                                        bookmarkSet:[self zs_assetExplorerLocalizeBookmarks]
                                         extraItems:extraItems];
}

- (UISwipeActionsConfiguration *)zs_assetExplorerLocalizeSwipeForIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    NSInteger entryIndex = [self zs_assetExplorerListIndexForIndexPath:indexPath inTableView:self.assetExplorerLocalizeTableView];
    if (entryIndex < 0 || entryIndex >= (NSInteger)self.assetExplorerLocalizeDisplayedEntries.count) return nil;
    NSString *path = self.assetExplorerLocalizeDisplayedEntries[(NSUInteger)entryIndex][@"path"];
    return [self zs_assetExplorerSwipeWithRemarkKey:[self zs_assetExplorerRemarkKeyForLocalizePath:path]
                                         bookmarkKey:[self zs_assetExplorerLocalizeKeyForPath:path]
                                         bookmarkSet:[self zs_assetExplorerLocalizeBookmarks]];
}

- (UITableViewCell *)zs_assetExplorerLocalizeJSONCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier = @"zs.asset.explorer.localize.json.cell";
    ZSLocJSONCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[ZSLocJSONCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    NSArray<ZSLocJSONNode *> *rows = self.assetExplorerLocalizeVisibleRows;
    ZSLocJSONNode *node = indexPath.row < (NSInteger)rows.count ? rows[(NSUInteger)indexPath.row] : nil;
    if (!node) {
        cell.line.attributedText = nil;
        return cell;
    }
    cell.leadingConstraint.constant = 16 + MAX(node.depth, 0) * 12;
    cell.line.attributedText = zs_loc_json_attributed(node);
    return cell;
}

- (void)zs_assetExplorerLocalizeToggleRow:(NSInteger)row {
    NSMutableArray<ZSLocJSONNode *> *rows = self.assetExplorerLocalizeVisibleRows;
    UITableView *table = self.assetExplorerLocalizeJSONTableView;
    if (!rows || !table || row < 0 || row >= (NSInteger)rows.count) return;
    ZSLocJSONNode *node = rows[(NSUInteger)row];
    if (!node.isContainer || node.children.count == 0) return;

    NSIndexPath *rowPath = [NSIndexPath indexPathForRow:row inSection:0];
    if (node.expanded) {
        NSInteger end = row + 1;
        while (end < (NSInteger)rows.count && rows[(NSUInteger)end].depth > node.depth) end++;
        NSRange range = NSMakeRange((NSUInteger)(row + 1), (NSUInteger)(end - row - 1));
        node.expanded = NO;
        [rows removeObjectsInRange:range];
        if (range.length == 0) {
            [table reloadRowsAtIndexPaths:@[rowPath] withRowAnimation:UITableViewRowAnimationNone];
        } else if (range.length > 300) {
            [table reloadData];
        } else {
            NSMutableArray<NSIndexPath *> *removed = [NSMutableArray arrayWithCapacity:range.length];
            for (NSUInteger i = 0; i < range.length; i++) [removed addObject:[NSIndexPath indexPathForRow:(NSInteger)(range.location + i) inSection:0]];
            [table performBatchUpdates:^{
                [table deleteRowsAtIndexPaths:removed withRowAnimation:UITableViewRowAnimationFade];
            } completion:nil];
            UITableViewCell *cell = [table cellForRowAtIndexPath:rowPath];
            if ([cell isKindOfClass:[ZSLocJSONCell class]]) ((ZSLocJSONCell *)cell).line.attributedText = zs_loc_json_attributed(node);
        }
        return;
    }

    node.expanded = YES;
    NSMutableArray<ZSLocJSONNode *> *added = [NSMutableArray array];
    zs_loc_json_flatten(node.children, added);
    NSIndexSet *positions = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange((NSUInteger)(row + 1), added.count)];
    [rows insertObjects:added atIndexes:positions];
    if (added.count > 300) {
        [table reloadData];
        return;
    }
    NSMutableArray<NSIndexPath *> *inserted = [NSMutableArray arrayWithCapacity:added.count];
    for (NSUInteger i = 0; i < added.count; i++) [inserted addObject:[NSIndexPath indexPathForRow:row + 1 + (NSInteger)i inSection:0]];
    [table performBatchUpdates:^{
        [table insertRowsAtIndexPaths:inserted withRowAnimation:UITableViewRowAnimationFade];
    } completion:nil];
    UITableViewCell *cell = [table cellForRowAtIndexPath:rowPath];
    if ([cell isKindOfClass:[ZSLocJSONCell class]]) ((ZSLocJSONCell *)cell).line.attributedText = zs_loc_json_attributed(node);
}

- (UIContextMenuConfiguration *)zs_assetExplorerLocalizeJSONContextMenuForIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(13.0)) {
    NSArray<ZSLocJSONNode *> *rows = self.assetExplorerLocalizeVisibleRows;
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)rows.count) return nil;
    ZSLocJSONNode *node = rows[(NSUInteger)indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        if (node.depth >= 0 && node.key.length > 0) {
            [items addObject:[UIAction actionWithTitle:@"Copy Key" image:[UIImage systemImageNamed:@"key"] identifier:nil handler:^(__kindof UIAction *action) {
                UIPasteboard.generalPasteboard.string = node.key;
            }]];
        }
        [items addObject:[UIAction actionWithTitle:@"Copy Value" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__kindof UIAction *action) {
            if (node.isContainer) {
                NSMutableString *text = [NSMutableString string];
                zs_loc_json_write(node, 0, text);
                UIPasteboard.generalPasteboard.string = text;
            } else {
                UIPasteboard.generalPasteboard.string = node.text ?: @"";
            }
        }]];
        return [UIMenu menuWithTitle:@"" children:items];
    }];
}

@end
