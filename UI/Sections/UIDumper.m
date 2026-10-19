#import "UIInternal.h"

static const NSInteger kZSDumperTagBase = 7100;

static NSArray<NSDictionary *> *zs_dumper_option_rows(void) {
    return @[
        @{@"key": @"dumpSource", @"title": @"Dump.cs class dump", @"group": @0},
        @{@"key": @"dumpBodies", @"title": @"Machine code bodies (Bodies.bin)", @"group": @0},
        @{@"key": @"copyBinaries", @"title": @"Copy UnityFramework + global-metadata.dat", @"group": @0},
        @{@"key": @"stringLiterals", @"title": @"stringliteral.json", @"group": @0},
        @{@"key": @"exportScripts", @"title": @"Export Ghidra / IDA / Binja / Hopper scripts", @"group": @0},
        @{@"key": @"scriptMethods", @"title": @"script.json methods and strings", @"group": @1},
        @{@"key": @"genericMethods", @"title": @"Generic method instantiations", @"group": @1},
        @{@"key": @"metadataUsages", @"title": @"Type / method metadata slots", @"group": @1},
        @{@"key": @"addresses", @"title": @"Function address list", @"group": @1},
        @{@"key": @"minifyJSON", @"title": @"Minified JSON", @"group": @1},
    ];
}

static UILabel *zs_dumper_caption(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = zs_mono_font(9, UIFontWeightSemibold);
    label.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    return label;
}

@implementation UserInterface (Dumper)

- (void)dumperTapped {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self zs_openDumperFullScreenPanel];
}

- (void)zs_buildDumperFullScreenPanelIfNeeded {
    if (self.dumperFullScreenOverlay) return;
    if (!self.extendedContentClip) return;

    UIView *overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.hidden = YES;
    overlay.userInteractionEnabled = YES;
    [self.extendedContentClip addSubview:overlay];
    zs_force_dark(overlay);
    self.dumperFullScreenOverlay = overlay;
    [self zs_installPinchToExitOnView:overlay];

    NSMutableDictionary *ui = [NSMutableDictionary dictionary];
    self.dumperUI = ui;

    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(closeButton, [UIImage systemImageNamed:@"xmark" withConfiguration:symbolConfig], [UIColor colorWithWhite:1 alpha:0.85]);
    [closeButton addTarget:self action:@selector(zs_closeDumperFullScreenPanelTapped) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:closeButton];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"IL2CPP Dumper";
    titleLabel.font = zs_mono_font(12, UIFontWeightSemibold);
    titleLabel.textColor = [UIColor colorWithWhite:0.96 alpha:1];
    [overlay addSubview:titleLabel];

    UILabel *statusLabel = [[UILabel alloc] init];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.font = zs_mono_font(9, UIFontWeightRegular);
    statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    statusLabel.textAlignment = NSTextAlignmentRight;
    statusLabel.adjustsFontSizeToFitWidth = YES;
    statusLabel.minimumScaleFactor = 0.6;
    [overlay addSubview:statusLabel];
    ui[@"status"] = statusLabel;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [overlay addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [scroll addSubview:stack];

    ZSDumpOptions *options = [ZSDumpOptions savedOptions];
    NSMutableArray<ZSRow *> *outputRows = [NSMutableArray array];
    NSMutableArray<ZSRow *> *scriptRows = [NSMutableArray array];
    NSArray<NSDictionary *> *defs = zs_dumper_option_rows();
    for (NSUInteger i = 0; i < defs.count; i++) {
        NSDictionary *def = defs[i];
        ZSRow *row = zs_make_switch_row(def[@"title"], [[options valueForKey:def[@"key"]] boolValue]);
        row.toggle.tag = kZSDumperTagBase + (NSInteger)i;
        [row.toggle addTarget:self action:@selector(zs_dumperOptionChanged:) forControlEvents:UIControlEventValueChanged];
        [([def[@"group"] integerValue] == 0 ? outputRows : scriptRows) addObject:row];
    }

    [stack addArrangedSubview:zs_dumper_caption(@"OUTPUT FILES")];
    [stack addArrangedSubview:zs_make_grouped_action_card(outputRows)];
    [stack addArrangedSubview:zs_dumper_caption(@"SCRIPT.JSON CONTENT")];
    [stack addArrangedSubview:zs_make_grouped_action_card(scriptRows)];

    UIButton *runButton = zs_make_grouped_action_button(@"Run Dump", zs_accent_green_color());
    [runButton addTarget:self action:@selector(zs_dumperRunTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *shareButton = zs_make_grouped_action_button(@"Share Output Folder", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [shareButton addTarget:self action:@selector(zs_dumperShareTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *resetButton = zs_make_grouped_action_button(@"Reset Options", [UIColor colorWithWhite:0.75 alpha:1]);
    [resetButton addTarget:self action:@selector(zs_dumperResetTapped) forControlEvents:UIControlEventTouchUpInside];
    ui[@"run"] = runButton;
    ui[@"share"] = shareButton;
    [stack addArrangedSubview:zs_make_grouped_action_card(@[runButton, shareButton, resetButton])];

    UILabel *stageLabel = [[UILabel alloc] init];
    stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    stageLabel.font = zs_mono_font(10, UIFontWeightRegular);
    stageLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    stageLabel.text = @"Idle";
    ui[@"stage"] = stageLabel;
    [stack addArrangedSubview:stageLabel];

    UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    progress.progressTintColor = zs_accent_green_color();
    progress.trackTintColor = [UIColor colorWithWhite:1 alpha:0.12];
    ui[@"progress"] = progress;
    [stack addArrangedSubview:progress];

    [stack addArrangedSubview:zs_dumper_caption(@"LOG")];
    UITextView *log = [[UITextView alloc] init];
    log.translatesAutoresizingMaskIntoConstraints = NO;
    log.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    log.layer.cornerRadius = 12;
    log.editable = NO;
    log.font = zs_mono_font(9, UIFontWeightRegular);
    log.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    log.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [log.heightAnchor constraintEqualToConstant:240].active = YES;
    ui[@"log"] = log;
    [stack addArrangedSubview:log];

    UILayoutGuide *safe = overlay.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [closeButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [closeButton.widthAnchor constraintEqualToConstant:32],
        [closeButton.heightAnchor constraintEqualToConstant:32],
        [titleLabel.leadingAnchor constraintEqualToAnchor:closeButton.trailingAnchor constant:10],
        [titleLabel.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-kPanelPadding],
        [statusLabel.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [scroll.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:kPanelPadding],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-kPanelPadding],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];

    [self zs_dumperSyncControls];
}

- (void)zs_openDumperFullScreenPanel {
    if (!self.panelOpen) return;
    if (self.dumperFullScreenOpen) return;

    [self zs_buildDumperFullScreenPanelIfNeeded];
    if (!self.dumperFullScreenOverlay) return;

    if (self.docsLanguageDropdownOpen) [self zs_closeDocsLanguageDropdownAnimated:NO];
    if (self.syslogFullScreenOpen) {
        [self zs_syslogEndCommandBrowse];
        [self.syslogSearchField resignFirstResponder];
        self.syslogFullScreenOpen = NO;
        [self zs_syncSyslogButtonState];
    }
    if (self.memoryFullScreenOpen) [self zs_endMemoryAnalysis];
    if (self.assetExplorerFullScreenOpen) [self zs_endAssetExplorerSession];

    self.docsActiveKey = nil;
    self.dumperFullScreenOpen = YES;
    self.docsPanelOpen = YES;
    [self zs_syncReducedPanelFPS];
    [self positionPanelAnimated:!self.extendedCoverEntering];
    [self zs_dumperSyncControls];
}

- (void)zs_endDumperSession {
    if (!self.dumperFullScreenOpen) return;
    self.dumperFullScreenOpen = NO;
    self.dumperFullScreenOverlay.hidden = YES;
    [self zs_syncReducedPanelFPS];
}

- (void)zs_closeDumperFullScreenPanelTapped {
    if (!self.dumperFullScreenOpen) return;
    [self closeDocsPanel];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_dumperOptionChanged:(UISwitch *)toggle {
    NSArray<NSDictionary *> *defs = zs_dumper_option_rows();
    NSInteger index = toggle.tag - kZSDumperTagBase;
    if (index < 0 || index >= (NSInteger)defs.count) return;
    ZSDumpOptions *options = [ZSDumpOptions savedOptions];
    [options setValue:@(toggle.isOn) forKey:defs[index][@"key"]];
    if (!options.dumpSource) options.dumpBodies = NO;
    [options save];
    [self zs_dumperSyncControls];
}

- (void)zs_dumperResetTapped {
    if ([ZSDumper isRunning]) return;
    ZSDumpOptions *options = [ZSDumpOptions savedOptions];
    [options resetToDefaults];
    [options save];
    NSArray<NSDictionary *> *defs = zs_dumper_option_rows();
    UIView *overlay = self.dumperFullScreenOverlay;
    for (NSUInteger i = 0; i < defs.count; i++) {
        UISwitch *toggle = (UISwitch *)[overlay viewWithTag:kZSDumperTagBase + (NSInteger)i];
        if ([toggle isKindOfClass:[UISwitch class]]) [toggle setOn:[[options valueForKey:defs[i][@"key"]] boolValue] animated:YES];
    }
    [self zs_dumperSyncControls];
}

- (void)zs_dumperSyncControls {
    NSMutableDictionary *ui = self.dumperUI;
    if (!ui) return;
    BOOL running = [ZSDumper isRunning];
    ZSDumpOptions *options = [ZSDumpOptions savedOptions];
    NSArray<NSDictionary *> *defs = zs_dumper_option_rows();
    for (NSUInteger i = 0; i < defs.count; i++) {
        UISwitch *toggle = (UISwitch *)[self.dumperFullScreenOverlay viewWithTag:kZSDumperTagBase + (NSInteger)i];
        if (![toggle isKindOfClass:[UISwitch class]]) continue;
        NSString *key = defs[i][@"key"];
        BOOL available = !running;
        if ([key isEqualToString:@"dumpBodies"] && !options.dumpSource) available = NO;
        if ([key isEqualToString:@"genericMethods"] && !options.scriptMethods && !options.metadataUsages && !options.addresses) available = !running;
        toggle.enabled = available;
        toggle.alpha = available ? 1 : 0.4;
    }
    UIButton *run = ui[@"run"];
    [run setTitle:running ? @"Cancel Dump" : @"Run Dump" forState:UIControlStateNormal];
    if (run.configuration) {
        UIButtonConfiguration *cfg = run.configuration;
        cfg.title = running ? @"Cancel Dump" : @"Run Dump";
        run.configuration = cfg;
    }
    UIButton *share = ui[@"share"];
    BOOL haveOutput = [ZSDumper lastOutputURL] != nil;
    share.enabled = haveOutput && !running;
    share.alpha = share.enabled ? 1 : 0.4;
    UILabel *status = ui[@"status"];
    status.text = running ? @"RUNNING" : (haveOutput ? @"READY" : @"IDLE");
}

- (void)zs_dumperAppendLog:(NSString *)line {
    UITextView *log = self.dumperUI[@"log"];
    if (!log || line.length == 0) return;
    NSString *existing = log.text ?: @"";
    NSString *next = existing.length ? [existing stringByAppendingFormat:@"\n%@", line] : line;
    if (next.length > 60000) next = [next substringFromIndex:next.length - 40000];
    log.text = next;
    [log scrollRangeToVisible:NSMakeRange(next.length, 0)];
}

- (void)zs_dumperRunTapped {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
    if ([ZSDumper isRunning]) {
        [ZSDumper cancel];
        [self zs_dumperAppendLog:@"Cancelling…"];
        return;
    }
    ZSDumpOptions *options = [ZSDumpOptions savedOptions];
    if (!options.dumpSource && !options.copyBinaries && !options.stringLiterals && !options.exportScripts &&
        !options.scriptMethods && !options.genericMethods && !options.metadataUsages && !options.addresses) {
        [self zs_dumperAppendLog:@"Nothing selected."];
        return;
    }
    UITextView *log = self.dumperUI[@"log"];
    log.text = @"";
    UIProgressView *progressView = self.dumperUI[@"progress"];
    UILabel *stageLabel = self.dumperUI[@"stage"];
    progressView.progress = 0;
    stageLabel.text = @"Starting";
    __weak typeof(self) weakSelf = self;
    __block NSString *lastStage = nil;
    [ZSDumper dumpWithOptions:options
                     progress:^(NSString *stage, double fraction) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            UIProgressView *bar = strongSelf.dumperUI[@"progress"];
            UILabel *label = strongSelf.dumperUI[@"stage"];
            label.text = stage;
            [bar setProgress:(float)MAX(0, MIN(1, fraction)) animated:NO];
            lastStage = stage;
        });
    }
                          log:^(NSString *line) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf zs_dumperAppendLog:line];
        });
    }
                   completion:^(NSURL *outputURL, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        UINotificationFeedbackGenerator *done = [UINotificationFeedbackGenerator new];
        UILabel *label = strongSelf.dumperUI[@"stage"];
        UIProgressView *bar = strongSelf.dumperUI[@"progress"];
        if (error) {
            [done notificationOccurred:UINotificationFeedbackTypeError];
            label.text = @"Failed";
            [strongSelf zs_dumperAppendLog:[NSString stringWithFormat:@"Failed: %@", error.localizedDescription]];
        } else {
            [done notificationOccurred:UINotificationFeedbackTypeSuccess];
            label.text = @"Complete";
            bar.progress = 1;
            NSDictionary *summary = [ZSDumper lastSummary];
            NSDictionary *counts = summary[@"counts"];
            NSDictionary *script = summary[@"script"];
            [strongSelf zs_dumperAppendLog:[NSString stringWithFormat:@"Saved to %@", outputURL.path]];
            if ([counts isKindOfClass:[NSDictionary class]] && [counts[@"classes"] unsignedIntegerValue] > 0) {
                [strongSelf zs_dumperAppendLog:[NSString stringWithFormat:@"classes %@, methods %@, fields %@", counts[@"classes"], counts[@"methods"], counts[@"fields"]]];
            }
            if ([script isKindOfClass:[NSDictionary class]] && script.count) {
                [strongSelf zs_dumperAppendLog:[NSString stringWithFormat:@"ScriptMethod %@ + generic %@, ScriptString %@, ScriptMetadata %@, ScriptMetadataMethod %@, Addresses %@",
                                                script[@"methods"], script[@"genericMethods"], script[@"strings"], script[@"metadata"], script[@"metadataMethods"], script[@"addresses"]]];
                if (![script[@"registrationFound"] boolValue]) [strongSelf zs_dumperAppendLog:@"Metadata registration not located: generic methods and metadata slots were skipped."];
                else if (![script[@"codeRegistrationFound"] boolValue]) [strongSelf zs_dumperAppendLog:@"Code registration not located: generic method pointers were skipped."];
            }
        }
        [strongSelf zs_dumperSyncControls];
    }];
    [self zs_dumperSyncControls];
}

- (void)zs_dumperShareTapped {
    NSURL *url = [ZSDumper lastOutputURL];
    if (!url) return;
    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    UIView *source = self.dumperUI[@"share"];
    activity.popoverPresentationController.sourceView = source ?: presenter.view;
    activity.popoverPresentationController.sourceRect = source ? source.bounds : CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
    [presenter presentViewController:activity animated:YES completion:nil];
}

@end
