#import "UIInternal.h"
#import "Docs.h"

@implementation UserInterface (Settings)

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

- (void)zs_lowResAnimateChanges:(dispatch_block_t)changes {
    [self.stack layoutIfNeeded];
    [UIView animateWithDuration:0.46
                          delay:0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        if (changes) changes();
        [self.stack setNeedsLayout];
        [self.stack layoutIfNeeded];
        [self.glassContainer layoutIfNeeded];
        [self.panel layoutIfNeeded];
        [self.scrollViewport layoutIfNeeded];
    } completion:^(BOOL finished) {
        [self zs_updateSliderGlassVisibility];
    }];
}

- (void)zs_lowResSetPanelActive:(BOOL)active animated:(BOOL)animated {
    if (active) g_zsLowResDeleteOpen = NO;
    dispatch_block_t changes = ^{
        zs_reveal_set_expanded(g_zsLowResInfoWrapper, !active && g_zsLowResStage != 0);
        zs_reveal_set_expanded(g_zsLowResTranscodeWrapper, !active);
        zs_reveal_set_expanded(g_zsLowResProgressWrapper, active);
        zs_reveal_set_expanded(g_zsLowResSwapWrapper, !active && g_zsLowResStage == 0 && g_zsLowResSwapEligible && !g_zsLowResDeleteOpen);
        zs_reveal_set_expanded(g_zsLowResDeleteWrapper, !active && g_zsLowResStage == 0 && g_zsLowResDeleteOpen);
    };
    if (animated) {
        [self zs_lowResAnimateChanges:changes];
    } else {
        changes();
        [self.stack setNeedsLayout];
        [self.stack layoutIfNeeded];
        [self zs_updateSliderGlassVisibility];
    }
}

- (void)zs_lowResSetInfoText:(NSString *)text buttonTitle:(NSString *)title buttonColor:(UIColor *)color buttonEnabled:(BOOL)enabled buttonVisible:(BOOL)visible {
    [self zs_lowResSetInfoText:text attributedText:nil buttonTitle:title buttonColor:color buttonEnabled:enabled buttonVisible:visible];
}

- (void)zs_lowResSetInfoText:(NSString *)text attributedText:(NSAttributedString *)attributed buttonTitle:(NSString *)title buttonColor:(UIColor *)color buttonEnabled:(BOOL)enabled buttonVisible:(BOOL)visible {
    [UIView transitionWithView:g_zsLowResInfoLabel
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent
                    animations:^{
        if (attributed) {
            g_zsLowResInfoLabel.attributedText = attributed;
        } else {
            g_zsLowResInfoLabel.text = text;
        }
    }
                    completion:nil];
    [UIView transitionWithView:g_zsLowResInfoButton
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent
                    animations:^{
        [g_zsLowResInfoButton setTitle:title forState:UIControlStateNormal];
        [g_zsLowResInfoButton setTitleColor:color forState:UIControlStateNormal];
    } completion:nil];
    g_zsLowResInfoButton.enabled = enabled;
    [self zs_lowResAnimateChanges:^{
        g_zsLowResInfoButton.hidden = !visible;
        g_zsLowResInfoButtonSeparator.hidden = !visible;
    }];
}

- (void)lowResCompressTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    if ([TexComp.shared status].running) {
        if (!g_zsLowResUserCancelled) return;
        if (g_zsLowResReopenPending) {
            g_zsLowResReopenPending = NO;
            g_zsLowResStage = 0;
            g_zsLowResGeneration++;
            [self zs_lowResSetPanelActive:NO animated:YES];
            return;
        }
        g_zsLowResReopenPending = YES;
        g_zsLowResStage = 5;
        g_zsLowResGeneration++;
        [UIView transitionWithView:g_zsLowResInfoLabel duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent animations:^{
            g_zsLowResInfoLabel.text = @"Finishing the stopped compression\u2026";
        } completion:nil];
        g_zsLowResInfoButton.hidden = YES;
        g_zsLowResInfoButtonSeparator.hidden = YES;
        [self zs_lowResAnimateChanges:^{
            [self zs_lowResApplyConfigMode:NO];
            zs_reveal_set_expanded(g_zsLowResInfoWrapper, YES);
        }];
        return;
    }
    if (g_zsLowResStage != 0) {
        g_zsLowResReopenPending = NO;
        g_zsLowResStage = 0;
        g_zsLowResGeneration++;
        [self zs_lowResSetPanelActive:NO animated:YES];
        return;
    }
    [self zs_lowResBeginCounting];
}

- (void)zs_lowResBeginCounting {
    g_zsLowResStage = 1;
    g_zsLowResDeleteOpen = NO;
    NSUInteger generation = ++g_zsLowResGeneration;
    UIColor *blue = [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0];
    [UIView transitionWithView:g_zsLowResInfoLabel duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent animations:^{
        g_zsLowResInfoLabel.text = @"Counting Texture2D assets\u2026";
    } completion:nil];
    [g_zsLowResInfoButton setTitle:@"Continue" forState:UIControlStateNormal];
    [g_zsLowResInfoButton setTitleColor:blue forState:UIControlStateNormal];
    g_zsLowResInfoButton.enabled = NO;
    g_zsLowResInfoButton.hidden = NO;
    g_zsLowResInfoButtonSeparator.hidden = NO;
    [self zs_lowResAnimateChanges:^{
        [self zs_lowResApplyConfigMode:NO];
        zs_reveal_set_expanded(g_zsLowResInfoWrapper, YES);
        zs_reveal_set_expanded(g_zsLowResSwapWrapper, NO);
        zs_reveal_set_expanded(g_zsLowResDeleteWrapper, NO);
    }];
    __weak typeof(self) weakSelf = self;
    BOOL accepted = [TexComp.shared prepareWithCompletion:^(NSUInteger textures, NSUInteger bundles, BOOL ok) {
        if (generation != g_zsLowResGeneration || g_zsLowResStage != 1) return;
        [weakSelf zs_lowResShowSummaryWithTextures:textures bundles:bundles ok:ok];
    }];
    if (!accepted) {
        g_zsLowResStage = 0;
        g_zsLowResGeneration++;
        [self zs_lowResSetPanelActive:NO animated:YES];
    }
}

- (void)zs_lowResShowSummaryWithTextures:(NSUInteger)textures bundles:(NSUInteger)bundles ok:(BOOL)ok {
    UIColor *blue = [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0];
    if (!ok || textures == 0) {
        NSString *text = !ok ? @"Couldn't count Texture2D assets. Close this panel and try again."
                             : @"No Texture2D assets need compression. Everything eligible is already compressed, or none were found.";
        [self zs_lowResSetInfoText:text buttonTitle:@"Continue" buttonColor:blue buttonEnabled:NO buttonVisible:NO];
        return;
    }
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *mainText = [NSString stringWithFormat:@"Compress and reduce Texture2D assets\u2019 memory footprint by up to 75%%.\n\nThere are about %@ Texture2D assets scattered across %@ bundles. Depending on your device specs, texture compression could take from a few, to several minutes. Are you sure you want to continue?\n\n",
                          [formatter stringFromNumber:@(textures)], [formatter stringFromNumber:@(bundles)]];
    NSString *noteText = @"Note: Texture2D assets are only a fraction of the game\u2019s total memory footprint, realistically you should expect to save around 375MB - 750MB of memory\n\nTranscoding to bigger ASTC blocks will also cause a significant Texture quality decrease";
    UIFont *baseFont = g_zsLowResInfoLabel.font ?: zs_mono_font(11, UIFontWeightMedium);
    UIColor *baseColor = g_zsLowResInfoLabel.textColor ?: [UIColor colorWithWhite:0.9 alpha:1];
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:mainText attributes:@{
        NSFontAttributeName: baseFont,
        NSForegroundColorAttributeName: baseColor,
    }];
    [attributed appendAttributedString:[[NSAttributedString alloc] initWithString:noteText attributes:@{
        NSFontAttributeName: zs_mono_font(MAX(baseFont.pointSize - 2, 8), UIFontWeightMedium),
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.5 alpha:1],
    }]];
    [self zs_lowResSetInfoText:nil attributedText:attributed buttonTitle:@"Continue" buttonColor:blue buttonEnabled:YES buttonVisible:YES];
}

- (void)lowResInfoActionTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    if (g_zsLowResStage == 1) {
        g_zsLowResStage = 2;
        [self zs_lowResShowConfig];
        return;
    }
    if (g_zsLowResStage != 2) return;
    NSArray<NSNumber *> *blocks = zs_lowres_block_options();
    NSInteger index = MAX((NSInteger)0, MIN((NSInteger)blocks.count - 1, g_zsLowResBlockIndex));
    [self zs_lowResStartTranscodeWithBlockSize:blocks[index].unsignedIntegerValue];
}

- (void)zs_lowResApplyConfigMode:(BOOL)config {
    g_zsLowResLabelHost.hidden = config;
    g_zsLowResLabelHost.alpha = config ? 0 : 1;
    g_zsLowResConfigView.hidden = !config;
    g_zsLowResConfigView.alpha = config ? 1 : 0;
}

- (void)zs_lowResShowConfig {
    NSArray<NSNumber *> *blocks = zs_lowres_block_options();
    NSInteger index = MAX((NSInteger)0, MIN((NSInteger)blocks.count - 1, g_zsLowResBlockIndex));
    g_zsLowResBlockIndex = index;
    g_zsLowResCodecExpanded = NO;
    [g_zsLowResCodecOptions removeFromSuperview];
    g_zsLowResCodecOptions = nil;
    g_zsLowResCodecHeight.constant = kZSGroupedCardRowHeight;
    g_zsLowResCodecRow.alpha = 1;
    g_zsLowResCodecRow.userInteractionEnabled = YES;
    zs_disclosure_row_set_value(g_zsLowResCodecRow, zs_lowres_block_title(blocks[index].unsignedIntegerValue, NO));

    [UIView transitionWithView:g_zsLowResInfoButton
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent
                    animations:^{
        [g_zsLowResInfoButton setTitle:@"Start Compression" forState:UIControlStateNormal];
        [g_zsLowResInfoButton setTitleColor:zs_accent_green_color() forState:UIControlStateNormal];
    } completion:nil];
    g_zsLowResInfoButton.enabled = YES;
    [self zs_lowResAnimateChanges:^{
        [self zs_lowResApplyConfigMode:YES];
        g_zsLowResInfoButton.hidden = NO;
        g_zsLowResInfoButtonSeparator.hidden = NO;
    }];
}

- (void)zs_lowResCodecRowTapped:(UIControl *)sender {
    if (g_zsLowResStage != 2) return;
    [self zs_lowResSetCodecExpanded:YES];
    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_lowResSetCodecExpanded:(BOOL)expanded {
    UIView *container = g_zsLowResCodecContainer;
    UIControl *row = g_zsLowResCodecRow;
    if (!container || !row || g_zsLowResCodecExpanded == expanded) return;
    g_zsLowResCodecExpanded = expanded;

    UIView *options = g_zsLowResCodecOptions;
    NSArray<NSNumber *> *blocks = zs_lowres_block_options();
    CGFloat expandedHeight = blocks.count * kZSGroupedCardRowHeight + (blocks.count - 1);
    if (expanded) {
        [options removeFromSuperview];
        NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:blocks.count];
        for (NSNumber *entry in blocks) [titles addObject:zs_lowres_block_title(entry.unsignedIntegerValue, YES)];
        options = zs_make_card_options_stack(titles, g_zsLowResBlockIndex, self, @selector(zs_lowResCodecOptionTapped:));
        options.alpha = 0;
        [container addSubview:options];
        [NSLayoutConstraint activateConstraints:@[
            [options.topAnchor constraintEqualToAnchor:container.topAnchor],
            [options.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [options.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        ]];
        g_zsLowResCodecOptions = options;
    }
    options.userInteractionEnabled = expanded;
    row.userInteractionEnabled = !expanded;
    [self zs_lowResAnimateChanges:^{
        g_zsLowResCodecHeight.constant = expanded ? expandedHeight : kZSGroupedCardRowHeight;
        row.alpha = expanded ? 0 : 1;
        options.alpha = expanded ? 1 : 0;
    }];
}

- (void)zs_lowResCodecOptionTapped:(UIControl *)sender {
    NSArray<NSNumber *> *blocks = zs_lowres_block_options();
    if (sender.tag >= 0 && sender.tag < (NSInteger)blocks.count) {
        g_zsLowResBlockIndex = sender.tag;
        zs_disclosure_row_set_value(g_zsLowResCodecRow, zs_lowres_block_title(blocks[sender.tag].unsignedIntegerValue, NO));
    }
    [self zs_lowResSetCodecExpanded:NO];
    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_lowResStartTranscodeWithBlockSize:(NSUInteger)blockSize {
    if (g_zsLowResStage != 2) return;
    __weak typeof(self) weakSelf = self;
    BOOL started = [TexComp.shared startWithMode:TexCompModeTranscode blockSize:blockSize completion:^(TexCompStatus status) {
        [weakSelf zs_lowResFinishedWithCancelled:status.cancelled];
    }];
    if (!started) {
        g_zsLowResStage = 0;
        g_zsLowResGeneration++;
        [self zs_lowResSetPanelActive:NO animated:YES];
        return;
    }
    g_zsLowResUserCancelled = NO;
    g_zsLowResStage = 3;
    g_zsLowResGeneration++;
    [[ZSMetalTabs shared] setPauseOverlayVisible:YES];
    [self zs_lowResRefreshProgressUI];
    [self zs_lowResSetPanelActive:YES animated:YES];
    [self zs_lowResStartUITimer];
}

- (void)zs_lowResStartUITimer {
    [g_zsLowResTimer invalidate];
    __weak typeof(self) weakSelf = self;
    g_zsLowResTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        if (![TexComp.shared status].running) {
            [timer invalidate];
            g_zsLowResTimer = nil;
            return;
        }
        [weakSelf zs_lowResRefreshProgressUI];
    }];
}

- (void)zs_lowResAttachProgressToCard:(UIView *)card transcodeButton:(UIButton *)button {
    UIStackView *inner = objc_getAssociatedObject(card, "zs_innerStack");
    NSUInteger index = inner ? [inner.arrangedSubviews indexOfObject:button] : NSNotFound;
    if (index == NSNotFound) return;
    UIStackView *info = zs_make_lowres_info_view(self, @selector(lowResInfoActionTapped:), @selector(zs_lowResCodecRowTapped:));
    UIView *progress = zs_make_lowres_progress_view(self, @selector(lowResCancelTapped:));
    UIView *swap = zs_make_lowres_swap_view(self, @selector(lowResSwapTapped:));
    UIView *infoWrapper = zs_make_reveal_wrapper(info, NO);
    UIView *progressWrapper = zs_make_reveal_wrapper(progress, NO);
    UIView *swapWrapper = zs_make_reveal_wrapper(swap, NO);
    UIView *deleteWrapper = zs_make_reveal_wrapper(zs_make_lowres_delete_view(self, @selector(lowResDeleteConfirmTapped:), @selector(lowResDeleteCancelTapped:)), NO);
    [inner removeArrangedSubview:button];
    [button removeFromSuperview];
    UIView *buttonWrapper = zs_make_reveal_wrapper(button, YES);
    [inner insertArrangedSubview:buttonWrapper atIndex:index];
    [inner insertArrangedSubview:infoWrapper atIndex:index + 1];
    [inner insertArrangedSubview:progressWrapper atIndex:index + 2];
    [inner insertArrangedSubview:swapWrapper atIndex:index + 3];
    [inner insertArrangedSubview:deleteWrapper atIndex:index + 4];
    g_zsLowResSwapWrapper = swapWrapper;
    g_zsLowResDeleteWrapper = deleteWrapper;
    g_zsLowResDeleteOpen = NO;
    g_zsLowResInfoView = info;
    g_zsLowResProgressView = progress;
    g_zsLowResInfoWrapper = infoWrapper;
    g_zsLowResProgressWrapper = progressWrapper;
    g_zsLowResTranscodeWrapper = buttonWrapper;
    g_zsLowResReopenPending = NO;
    g_zsLowResStage = 0;
    g_zsLowResGeneration++;
    TexCompStatus st = [TexComp.shared status];
    if (st.running && st.mode == TexCompModeTranscode && !g_zsLowResUserCancelled) {
        g_zsLowResStage = 3;
        [self zs_lowResRefreshProgressUI];
        [self zs_lowResSetPanelActive:YES animated:NO];
        if (!g_zsLowResTimer.isValid) [self zs_lowResStartUITimer];
    }
    [self zs_lowResRefreshSwapWindowAnimated:NO];
}

- (void)zs_lowResRefreshProgressUI {
    TexCompStatus st = [TexComp.shared status];
    double fraction = st.texturesTotal > 0 ? (double)st.texturesProcessed / (double)st.texturesTotal : 0.0;
    NSUInteger percent = (NSUInteger)floor(fraction * 100.0);
    g_zsLowResPercentLabel.text = [NSString stringWithFormat:@"%lu%%", (unsigned long)percent];
    g_zsLowResTexturesLabel.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)st.texturesProcessed, (unsigned long)st.texturesTotal];
    g_zsLowResBundleCountLabel.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)st.bundlesDone, (unsigned long)st.bundlesTotal];
    if (st.preparing) {
        g_zsLowResETALabel.text = @"Preparing\u2026";
    } else if (st.etaSeconds < 0) {
        g_zsLowResETALabel.text = @"ETA --:--:--";
    } else {
        unsigned long seconds = (unsigned long)llround(st.etaSeconds);
        g_zsLowResETALabel.text = [NSString stringWithFormat:@"ETA %lu:%02lu:%02lu", seconds / 3600, (seconds % 3600) / 60, seconds % 60];
    }
    UIView *track = g_zsLowResTrack;
    UIView *fill = g_zsLowResFill;
    if (track && fill) {
        [NSLayoutConstraint deactivateConstraints:@[g_zsLowResFillWidth]];
        g_zsLowResFillWidth = [fill.widthAnchor constraintEqualToAnchor:track.widthAnchor multiplier:MAX(MIN(fraction, 1.0), 0.0001)];
        g_zsLowResFillWidth.active = YES;
    }
}

- (void)zs_lowResApplySwapState:(TexCompFolderState)state {
    UIColor *green = zs_accent_green_color();
    UIColor *blue = zs_lowres_original_folder_color();
    UIColor *missing = [UIColor colorWithWhite:1 alpha:0.2];
    g_zsLowResDiskExists = state.diskExists;
    g_zsLowResBackupExists = state.backupExists;
    g_zsLowResDiskTranscoded = state.diskTranscoded;
    g_zsLowResBackupTranscoded = state.backupTranscoded;
    g_zsLowResSwapLeftIcon.tintColor = !state.backupExists ? missing : (state.backupTranscoded ? green : blue);
    g_zsLowResSwapRightIcon.tintColor = !state.diskExists ? missing : (state.diskTranscoded ? green : blue);
    BOOL canSwap = state.diskExists && state.backupExists;
    g_zsLowResSwapButton.enabled = canSwap;
    g_zsLowResSwapButton.alpha = canSwap ? 1 : 0.3;
}

- (void)zs_lowResRefreshSwapWindowAnimated:(BOOL)animated {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *shared = [UnityCacheLocator unityCacheSharedDirectories].firstObject;
        TexCompFolderState state = zs_lowres_folder_state(shared);
        BOOL stagedLedger = [NSFileManager.defaultManager fileExistsAtPath:[[TexComp stagingDirectory] stringByAppendingPathComponent:@"ledger.json"]];
        BOOL eligible = state.backupExists && (state.backupTranscoded || state.diskTranscoded || stagedLedger);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || g_zsLowResSwapBusy) return;
            g_zsLowResSharedPath = shared;
            g_zsLowResSwapEligible = eligible;
            [strongSelf zs_lowResApplySwapState:state];
            if (g_zsLowResStage != 0 || [TexComp.shared status].running) return;
            if (!eligible) g_zsLowResDeleteOpen = NO;
            dispatch_block_t changes = ^{
                zs_reveal_set_expanded(g_zsLowResSwapWrapper, eligible && !g_zsLowResDeleteOpen);
                zs_reveal_set_expanded(g_zsLowResDeleteWrapper, eligible && g_zsLowResDeleteOpen);
            };
            if (animated) {
                [strongSelf zs_lowResAnimateChanges:changes];
            } else {
                changes();
                [strongSelf.stack setNeedsLayout];
                [strongSelf.stack layoutIfNeeded];
                [strongSelf zs_updateSliderGlassVisibility];
            }
        });
    });
}

- (void)zs_lowResPresentAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_lowResAutoSwapAfterCompletion {
    g_zsLowResSwapBusy = YES;
    g_zsLowResCancelButton.enabled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *shared = [UnityCacheLocator unityCacheSharedDirectories].firstObject;
        NSString *failure = zs_lowres_swap_shared_folders();
        TexCompFolderState state = zs_lowres_folder_state(shared);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            g_zsLowResSwapBusy = NO;
            g_zsLowResCancelButton.enabled = YES;
            g_zsLowResSharedPath = shared;
            if (!strongSelf) return;
            BOOL stagedLedger = [NSFileManager.defaultManager fileExistsAtPath:[[TexComp stagingDirectory] stringByAppendingPathComponent:@"ledger.json"]];
            g_zsLowResSwapEligible = state.backupExists && (state.backupTranscoded || state.diskTranscoded || stagedLedger);
            [strongSelf zs_lowResApplySwapState:state];
            g_zsLowResStage = 0;
            g_zsLowResGeneration++;
            [strongSelf zs_lowResSetPanelActive:NO animated:YES];
            if (failure) [strongSelf zs_lowResPresentAlertWithTitle:@"Swap failed" message:failure];
        });
    });
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    if (g_zsLowResSwapBusy || g_zsLowResStage != 0 || [TexComp.shared status].running) return nil;
    BOOL isDisk = interaction.view.tag == 2;
    if (isDisk ? !g_zsLowResDiskExists : !g_zsLowResBackupExists) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *delete = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
            [weakSelf zs_lowResBeginDeleteForDisk:isDisk];
        }];
        delete.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:@"" children:@[delete]];
    }];
}

- (UITargetedPreview *)zs_lowResSlotPreviewForInteraction:(UIContextMenuInteraction *)interaction {
    UIView *view = interaction.view;
    UIPreviewParameters *parameters = [[UIPreviewParameters alloc] init];
    parameters.backgroundColor = UIColor.clearColor;
    parameters.visiblePath = [UIBezierPath bezierPathWithRoundedRect:view.bounds cornerRadius:6];
    return [[UITargetedPreview alloc] initWithView:view parameters:parameters];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    return [self zs_lowResSlotPreviewForInteraction:interaction];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForDismissingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    return [self zs_lowResSlotPreviewForInteraction:interaction];
}

- (void)zs_lowResBeginDeleteForDisk:(BOOL)isDisk {
    if (g_zsLowResSwapBusy || g_zsLowResStage != 0) return;
    BOOL transcoded = isDisk ? g_zsLowResDiskTranscoded : g_zsLowResBackupTranscoded;
    g_zsLowResDeleteTargetIsDisk = isDisk;
    g_zsLowResDeleteLabel.text = transcoded
        ? @"Deleting this folder will make the original take precedence, are you sure?"
        : @"Deleting this folder will make the transcoded one take precedence, texture compression is a lossy process \u2014 if you want the original textures back you\u2019ll have to redownload them again, are you sure?";
    g_zsLowResDeleteOpen = YES;
    [self zs_lowResAnimateChanges:^{
        zs_reveal_set_expanded(g_zsLowResSwapWrapper, NO);
        zs_reveal_set_expanded(g_zsLowResDeleteWrapper, YES);
    }];
}

- (void)lowResDeleteCancelTapped:(UIButton *)sender {
    if (g_zsLowResSwapBusy) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    g_zsLowResDeleteOpen = NO;
    [self zs_lowResAnimateChanges:^{
        zs_reveal_set_expanded(g_zsLowResDeleteWrapper, NO);
        zs_reveal_set_expanded(g_zsLowResSwapWrapper, g_zsLowResSwapEligible);
    }];
}

- (void)lowResDeleteConfirmTapped:(UIButton *)sender {
    if (g_zsLowResSwapBusy || g_zsLowResStage != 0 || [TexComp.shared status].running) return;
    NSString *shared = g_zsLowResSharedPath;
    if (!shared) return;
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
    BOOL deleteDisk = g_zsLowResDeleteTargetIsDisk;
    g_zsLowResSwapBusy = YES;
    sender.enabled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = zs_lowres_delete_folder(shared, deleteDisk);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            sender.enabled = YES;
            g_zsLowResSwapBusy = NO;
            g_zsLowResDeleteOpen = NO;
            if (!strongSelf) return;
            [strongSelf zs_lowResRefreshSwapWindowAnimated:YES];
            if (failure) [strongSelf zs_lowResPresentAlertWithTitle:@"Delete failed" message:failure];
        });
    });
}

- (void)lowResSwapTapped:(UIButton *)sender {
    if (g_zsLowResSwapBusy || g_zsLowResStage != 0 || [TexComp.shared status].running) return;
    NSString *shared = g_zsLowResSharedPath;
    if (!shared) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
    g_zsLowResSwapBusy = YES;
    sender.enabled = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = zs_lowres_exchange_shared_folders(shared);
        TexCompFolderState state = zs_lowres_folder_state(shared);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                g_zsLowResSwapBusy = NO;
                return;
            }
            if (failure) {
                g_zsLowResSwapBusy = NO;
                [strongSelf zs_lowResApplySwapState:state];
                [strongSelf zs_lowResPresentAlertWithTitle:@"Swap failed" message:failure];
                return;
            }
            [strongSelf zs_lowResAnimateSwapToState:state];
        });
    });
}

- (void)zs_lowResAnimateSwapToState:(TexCompFolderState)state {
    UIView *leftSlot = g_zsLowResSwapLeftSlot;
    UIView *rightSlot = g_zsLowResSwapRightSlot;
    UIImageView *leftIcon = g_zsLowResSwapLeftIcon;
    UIImageView *rightIcon = g_zsLowResSwapRightIcon;
    if (!leftSlot || !rightSlot || !leftIcon || !rightIcon) {
        g_zsLowResSwapBusy = NO;
        [self zs_lowResApplySwapState:state];
        return;
    }
    CGFloat distance = CGRectGetMidX(rightSlot.frame) - CGRectGetMidX(leftSlot.frame);
    __weak typeof(self) weakSelf = self;
    UICubicTimingParameters *easeOut = [[UICubicTimingParameters alloc] initWithControlPoint1:CGPointMake(0.05, 0.85) controlPoint2:CGPointMake(0.15, 1.0)];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.24 timingParameters:easeOut];
    [animator addAnimations:^{
        leftIcon.transform = CGAffineTransformMakeTranslation(distance, 0);
        rightIcon.transform = CGAffineTransformMakeTranslation(-distance, 0);
    }];
    [animator addCompletion:^(UIViewAnimatingPosition position) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        leftIcon.transform = CGAffineTransformIdentity;
        rightIcon.transform = CGAffineTransformIdentity;
        [weakSelf zs_lowResApplySwapState:state];
        [CATransaction commit];
        g_zsLowResSwapBusy = NO;
    }];
    [animator startAnimation];
}

- (void)lowResCancelTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Stop compression?"
                                                                   message:@"Bundles already written stay in Documents/LowRes and will be skipped next time."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep Going" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        g_zsLowResUserCancelled = YES;
        g_zsLowResStage = 0;
        g_zsLowResGeneration++;
        [TexComp.shared cancel];
        [weakSelf zs_lowResSetPanelActive:NO animated:YES];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_lowResFinishedWithCancelled:(BOOL)cancelled {
    [[ZSMetalTabs shared] setPauseOverlayVisible:NO];
    [g_zsLowResTimer invalidate];
    g_zsLowResTimer = nil;
    g_zsLowResUserCancelled = NO;
    if (g_zsLowResReopenPending) {
        g_zsLowResReopenPending = NO;
        if (g_zsLowResStage == 5) {
            [self zs_lowResBeginCounting];
            return;
        }
    }
    if (!cancelled && g_zsLowResStage == 3) {
        g_zsLowResStage = 4;
        g_zsLowResGeneration++;
        [self zs_lowResRefreshProgressUI];
        g_zsLowResETALabel.text = @"Complete";
        [self zs_lowResAutoSwapAfterCompletion];
        return;
    }
    g_zsLowResStage = 0;
    g_zsLowResGeneration++;
    [self zs_lowResSetPanelActive:NO animated:YES];
    [self zs_lowResRefreshSwapWindowAnimated:YES];
    if (cancelled) return;
    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Compression complete"
                                                                   message:[TexComp.shared summary]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
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

#pragma mark Developer (Keep Alive)

static BOOL zs_keep_alive_background_mode_declared(void) {
    NSArray *modes = [NSBundle mainBundle].infoDictionary[@"UIBackgroundModes"];
    return [modes isKindOfClass:[NSArray class]] && [modes containsObject:@"location"];
}

- (void)toggleKeepAliveTapped {
    self.keepAliveEnabled = !self.keepAliveEnabled;

    if (self.keepAliveEnabled) {
        if (!self.keepAliveLocationManager) {
            self.keepAliveLocationManager = [[CLLocationManager alloc] init];
            self.keepAliveLocationManager.delegate = self;
        }
        self.keepAliveLocationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
        self.keepAliveLocationManager.distanceFilter = kCLDistanceFilterNone;
        self.keepAliveLocationManager.pausesLocationUpdatesAutomatically = NO;

        BOOL canBackground = zs_keep_alive_background_mode_declared();
        self.keepAliveLocationManager.allowsBackgroundLocationUpdates = canBackground;
        if (!canBackground) {
            ZLog(@"[UserInterface] Keep Alive: running bundle doesn't declare UIBackgroundModes location - foreground-only");
        }

        CLAuthorizationStatus status = self.keepAliveLocationManager.authorizationStatus;
        if (status == kCLAuthorizationStatusNotDetermined) {
            [self.keepAliveLocationManager requestAlwaysAuthorization];
        } else {
            [self.keepAliveLocationManager startUpdatingLocation];
        }

        ZLog(@"[UserInterface] Keep Alive enabled - starting low-accuracy location updates");
    } else {
        [self.keepAliveLocationManager stopUpdatingLocation];
        ZLog(@"[UserInterface] Keep Alive disabled - stopped location updates");
    }

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (!self.keepAliveEnabled) return;

    CLAuthorizationStatus status = manager.authorizationStatus;
    if (status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse) {
        [manager startUpdatingLocation];
    } else if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        self.keepAliveEnabled = NO;
        ZLog(@"[UserInterface] Keep Alive: location permission denied");
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    ZLog(@"[UserInterface] Keep Alive location error: %@", error.localizedDescription);
}

#pragma mark Developer (Patch LC)

- (void)patchLCTapped {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        UTType *ipaType = [UTType typeWithFilenameExtension:@"ipa" conformingToType:UTTypeData] ?: UTTypeData;
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ipaType] asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.apple.itunes.ipa"] inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;

    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) {
        ZLog(@"[PatchLC] no root view controller to present the file picker from");
        return;
    }
    self.patchLCPicker = picker;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_handlePatchLCPickedURL:(NSURL *)url {
    if ([url.pathExtension caseInsensitiveCompare:@"ipa"] != NSOrderedSame) {
        [self zs_presentModsAlertWithTitle:@"Patch LC Failed" message:@"Pick an .ipa file."];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    UIAlertController *working = [UIAlertController alertControllerWithTitle:@"Patching\u2026"
                                                                      message:@"Embedding the memory extension into the IPA."
                                                               preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [working.view addSubview:spinner];
    [spinner startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:working.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:working.view.bottomAnchor constant:-16],
    ]];

    __block BOOL workingShown = (presenter == nil);
    __block dispatch_block_t pendingResult = nil;
    if (presenter) {
        [presenter presentViewController:working animated:YES completion:^{
            workingShown = YES;
            if (pendingResult) {
                dispatch_block_t result = pendingResult;
                pendingResult = nil;
                result();
            }
        }];
    }

    BOOL accessing = [url startAccessingSecurityScopedResource];
    __weak typeof(self) weakSelf = self;
    [ZSLiveContainerPatcher patchIPAAtURL:url completion:^(NSURL *patchedURL, NSString *hostBundleID, NSError *error) {
        if (accessing) [url stopAccessingSecurityScopedResource];

        dispatch_block_t present = ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            if (!patchedURL) {
                [haptic notificationOccurred:UINotificationFeedbackTypeError];
                [strongSelf zs_presentModsAlertWithTitle:@"Patch LC Failed" message:error.localizedDescription ?: @"Unknown error."];
                return;
            }

            UIViewController *sharePresenter = zs_key_window().rootViewController;
            while (sharePresenter.presentedViewController) sharePresenter = sharePresenter.presentedViewController;
            if (!sharePresenter) {
                [NSFileManager.defaultManager removeItemAtURL:patchedURL.URLByDeletingLastPathComponent error:nil];
                return;
            }

            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[patchedURL] applicationActivities:nil];
            activityVC.popoverPresentationController.sourceView = sharePresenter.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(sharePresenter.view.bounds), CGRectGetMidY(sharePresenter.view.bounds), 0, 0);
            activityVC.popoverPresentationController.permittedArrowDirections = 0;
            activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                [NSFileManager.defaultManager removeItemAtURL:patchedURL.URLByDeletingLastPathComponent error:nil];
            };
            [sharePresenter presentViewController:activityVC animated:YES completion:nil];
            [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
        };

        dispatch_block_t finish = ^{
            if (working.presentingViewController) {
                [working dismissViewControllerAnimated:YES completion:present];
            } else {
                present();
            }
        };

        if (workingShown) {
            finish();
        } else {
            pendingResult = finish;
        }
    }];
}

#pragma mark Developer (Create Logos)

- (void)zs_createLogosTapped {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP, UTTypeFolder]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip-archive", @"public.folder"] inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;

    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) {
        ZLog(@"[Logo] no root view controller to present the file picker from");
        return;
    }
    self.createLogosPicker = picker;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_handleCreateLogosPickedURL:(NSURL *)url {
    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    UIAlertController *working = [UIAlertController alertControllerWithTitle:@"Creating Logos\u2026"
                                                                      message:@"Transcoding SVGs, stripping fonts and compressing."
                                                               preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [working.view addSubview:spinner];
    [spinner startAnimating];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:working.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:working.view.bottomAnchor constant:-16],
    ]];

    __block BOOL workingShown = (presenter == nil);
    __block dispatch_block_t pendingResult = nil;
    if (presenter) {
        [presenter presentViewController:working animated:YES completion:^{
            workingShown = YES;
            if (pendingResult) {
                dispatch_block_t result = pendingResult;
                pendingResult = nil;
                result();
            }
        }];
    }

    __weak typeof(self) weakSelf = self;
    zs_logo_create_pack(url, ^(NSURL *outputURL, NSString *errorMessage) {
        dispatch_block_t present = ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            if (!outputURL) {
                [haptic notificationOccurred:UINotificationFeedbackTypeError];
                [strongSelf zs_presentModsAlertWithTitle:@"Create Logos Failed" message:errorMessage ?: @"Unknown error."];
                return;
            }

            UIViewController *sharePresenter = zs_key_window().rootViewController;
            while (sharePresenter.presentedViewController) sharePresenter = sharePresenter.presentedViewController;
            if (!sharePresenter) {
                [NSFileManager.defaultManager removeItemAtURL:outputURL.URLByDeletingLastPathComponent error:nil];
                return;
            }

            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[outputURL] applicationActivities:nil];
            activityVC.popoverPresentationController.sourceView = sharePresenter.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(sharePresenter.view.bounds), CGRectGetMidY(sharePresenter.view.bounds), 0, 0);
            activityVC.popoverPresentationController.permittedArrowDirections = 0;
            activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                [NSFileManager.defaultManager removeItemAtURL:outputURL.URLByDeletingLastPathComponent error:nil];
            };
            [sharePresenter presentViewController:activityVC animated:YES completion:nil];
            [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
        };

        dispatch_block_t finish = ^{
            if (working.presentingViewController) {
                [working dismissViewControllerAnimated:YES completion:present];
            } else {
                present();
            }
        };

        if (workingShown) {
            finish();
        } else {
            pendingResult = finish;
        }
    });
}

#pragma mark Developer (Library Symlink)

- (void)librarySymlinkTapped {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *library = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];

    if (!documents || !library) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Library Symlink Failed" message:@"Could not resolve the Documents or Library directory."];
        return;
    }

    NSURL *linkURL = [documents URLByAppendingPathComponent:@"Library"];
    NSDictionary *existingAttrs = [fm attributesOfItemAtPath:linkURL.path error:nil];

    if (existingAttrs && [existingAttrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
        [self zs_presentModsAlertWithTitle:@"Library Symlink" message:@"Already exposed at Documents/Library in the Files app."];
        return;
    }

    if (existingAttrs) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Library Symlink Failed" message:@"Documents/Library already exists and isn't a symlink, so it wasn't overwritten."];
        return;
    }

    NSError *error = nil;
    BOOL created = [fm createSymbolicLinkAtURL:linkURL withDestinationURL:library error:&error];
    if (!created) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Library Symlink Failed" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }

    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self zs_presentModsAlertWithTitle:@"Library Symlink Created" message:@"The Library folder is now browsable at Documents/Library in the Files app, including its internal logs."];
}

- (void)zs_customGreetingTextButtonTapped:(id)sender {
    [self zs_presentFloatingTextFieldWithInitialText:zs_custom_greeting_text()
                                          placeholder:@"Greeting text"
                                               secure:NO
                                             hintText:@"Note: Client side only, others won\u2019t see this."
                                         resetHandler:^{
        zs_set_custom_greeting_text(@"");
    }
                                           completion:^(NSString * _Nullable trimmedText) {
        zs_set_custom_greeting_text(trimmedText ?: @"");
    }];
}

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
    zs_clear_modded_bundles();

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
    self.docsUpdateActionsSpacer.hidden = !visible;
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
    UIColor *repoLinkColor = [UIColor colorWithRed:0x30 / 255.0 green:0xD1 / 255.0 blue:0x58 / 255.0 alpha:1.0];
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

- (void)zs_logoChevronTapped:(UIButton *)sender {
    if (self.logoDropdownOpen) {
        [self zs_closeLogoDropdownAnimated:YES];
        return;
    }
    [self zs_openLogoDropdownWithNames:zs_logo_cached_names()];

    __weak typeof(self) weakSelf = self;
    zs_logo_refresh_names(^(NSArray<NSString *> *names) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.logoDropdownOpen) return;
        if ([strongSelf.logoDropdownNames isEqualToArray:names]) return;
        [strongSelf zs_closeLogoDropdownAnimated:NO];
        [strongSelf zs_openLogoDropdownWithNames:names];
    });
}

- (void)zs_openLogoDropdownWithNames:(NSArray<NSString *> *)names {
    if (!self.logoChevronButton || !self.scrollView || self.logoDropdownOpen || names.count == 0) return;

    self.logoDropdownNames = names;
    NSString *currentName = zs_logo_selected_name();

    CGRect buttonFrame = [self.logoChevronButton convertRect:self.logoChevronButton.bounds toView:self.scrollView];
    BOOL hasLocal = NO;
    for (NSString *candidate in names) {
        if (zs_logo_is_local(candidate)) {
            hasLocal = YES;
            break;
        }
    }
    CGFloat deleteWidth = 34;
    CGFloat dropdownWidth = kZSLogoDropdownWidth + (hasLocal ? deleteWidth : 0);
    CGFloat rowHeight = kZSReencodeFieldHeight;
    NSInteger rowCount = (NSInteger)names.count + 1;
    CGFloat dropdownHeight = rowHeight * rowCount;

    CGFloat originX = CGRectGetMinX(buttonFrame);
    originX = MIN(originX, CGRectGetWidth(self.scrollView.bounds) - dropdownWidth - kPanelPadding);
    originX = MAX(originX, kPanelPadding);
    CGRect dropdownFrame = CGRectMake(originX, CGRectGetMaxY(buttonFrame) + 4, dropdownWidth, dropdownHeight);

    CGSize contentSize = self.scrollView.contentSize;
    CGRect scrimFrame = CGRectMake(0, 0,
                                   MAX(contentSize.width, CGRectGetWidth(self.scrollView.bounds)),
                                   MAX(contentSize.height, CGRectGetHeight(self.scrollView.bounds)));
    UIControl *scrim = [[UIControl alloc] initWithFrame:scrimFrame];
    scrim.backgroundColor = UIColor.clearColor;
    [scrim addTarget:self action:@selector(zs_logoDropdownScrimTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:scrim];
    self.logoDropdownScrim = scrim;

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
    [self.scrollView addSubview:overlay];
    self.logoDropdownOverlay = overlay;

    UIView *rowHost = glassOverlay ? glassOverlay.contentView : overlay;

    for (NSInteger i = 0; i < rowCount; i++) {
        BOOL isAddRow = i == (NSInteger)names.count;
        NSString *name = isAddRow ? @"+ Add logo" : names[i];
        BOOL selected = !isAddRow && [name isEqualToString:currentName];
        UIButton *optionButton = zs_make_docs_language_option_button(@{@"name": name}, selected, i, self,
                                                                       @selector(zs_logoDropdownOptionTapped:));
        if (isAddRow) [optionButton setTitleColor:zs_accent_green_color() forState:UIControlStateNormal];
        optionButton.frame = CGRectMake(0, i * rowHeight, dropdownWidth, rowHeight);
        optionButton.alpha = 0;
        [rowHost addSubview:optionButton];

        if (!isAddRow && zs_logo_is_local(name)) {
            optionButton.titleEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12 + deleteWidth);
            UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
            deleteButton.tag = i;
            deleteButton.frame = CGRectMake(dropdownWidth - deleteWidth, i * rowHeight, deleteWidth, rowHeight);
            UIImageSymbolConfiguration *trashConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
            [deleteButton setImage:[UIImage systemImageNamed:@"trash" withConfiguration:trashConfig] forState:UIControlStateNormal];
            deleteButton.tintColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.40 alpha:0.9];
            deleteButton.accessibilityLabel = [NSString stringWithFormat:@"Delete %@", name];
            deleteButton.alpha = 0;
            [deleteButton addTarget:self action:@selector(zs_logoDropdownDeleteTapped:) forControlEvents:UIControlEventTouchUpInside];
            [rowHost addSubview:deleteButton];
        }

        if (i > 0) {
            CGFloat hairline = 1.0 / MAX(UIScreen.mainScreen.scale, (CGFloat)1.0);
            UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, i * rowHeight - hairline, dropdownWidth, hairline)];
            divider.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.5];
            divider.alpha = 0;
            [rowHost addSubview:divider];
        }
    }

    self.logoDropdownOpen = YES;
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
        self.logoChevronButton.transform = CGAffineTransformMakeRotation(M_PI);
        for (UIView *subview in rowHost.subviews) {
            subview.alpha = 1;
        }
    } completion:nil];

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_closeLogoDropdownAnimated:(BOOL)animated {
    if (!self.logoDropdownOpen) return;

    UIView *overlay = self.logoDropdownOverlay;
    UIControl *scrim = self.logoDropdownScrim;
    self.logoDropdownOverlay = nil;
    self.logoDropdownScrim = nil;
    self.logoDropdownOpen = NO;

    void (^finish)(void) = ^{
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
    };

    if (!animated) {
        self.logoChevronButton.transform = CGAffineTransformIdentity;
        finish();
        return;
    }

    [UIView animateWithDuration:0.16
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        overlay.alpha = 0;
        overlay.transform = CGAffineTransformMakeScale(0.92, 0.92);
        self.logoChevronButton.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        finish();
    }];
}

- (void)zs_logoDropdownOptionTapped:(UIButton *)sender {
    NSArray<NSString *> *names = self.logoDropdownNames;
    if (sender.tag < 0 || sender.tag > (NSInteger)names.count) return;

    if (sender.tag == (NSInteger)names.count) {
        [self zs_closeLogoDropdownAnimated:YES];
        [self zs_presentLogoImportPicker];
        return;
    }

    NSString *name = names[sender.tag];
    [self zs_closeLogoDropdownAnimated:YES];

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];

    zs_logo_select(name, ^(BOOL success) {
        if (success) return;
        UINotificationFeedbackGenerator *failHaptic = [UINotificationFeedbackGenerator new];
        [failHaptic notificationOccurred:UINotificationFeedbackTypeError];
    });
}

- (void)zs_logoDropdownDeleteTapped:(UIButton *)sender {
    NSArray<NSString *> *names = self.logoDropdownNames;
    if (sender.tag < 0 || sender.tag >= (NSInteger)names.count) return;
    NSString *name = names[sender.tag];
    if (!zs_logo_is_local(name)) return;
    [self zs_closeLogoDropdownAnimated:YES];

    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Logo?"
                                                                       message:[NSString stringWithFormat:@"\u201C%@\u201D will be removed from this device.", name]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        BOOL deleted = zs_logo_delete(name);
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:deleted ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
        if (!deleted) [weakSelf zs_presentModsAlertWithTitle:@"Couldn't Delete Logo" message:[NSString stringWithFormat:@"\u201C%@\u201D couldn't be removed.", name]];
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_presentLogoImportPicker {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        UTType *packType = [UTType typeWithFilenameExtension:@"zs" conformingToType:UTTypeData] ?: UTTypeData;
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP, UTTypeFolder, packType]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip-archive", @"public.folder", @"public.data"] inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;

    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) {
        ZLog(@"[Logo] no root view controller to present the file picker from");
        return;
    }
    self.logoImportPicker = picker;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_handleLogoImportPickedURL:(NSURL *)url {
    __weak typeof(self) weakSelf = self;
    zs_logo_import_item(url, ^(NSArray<NSString *> *importedNames, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (errorMessage) {
            [strongSelf zs_presentModsAlertWithTitle:@"Couldn't Add Logo" message:errorMessage];
            return;
        }
        zs_logo_select(importedNames.firstObject, nil);
    });
}

- (void)zs_logoDropdownScrimTapped:(UIControl *)sender {
    [self zs_closeLogoDropdownAnimated:YES];
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
