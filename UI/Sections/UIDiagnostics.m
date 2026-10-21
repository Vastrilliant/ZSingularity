#import "UIInternal.h"

@implementation UserInterface (Diagnostics)

#pragma mark Syslog

- (void)toggleSyslogTapped {
    self.syslogTabEnabled = !self.syslogTabEnabled;

    if (self.syslogTabEnabled) {
        [self.syslogButton setTitle:@"Hide system logs" forState:UIControlStateNormal];
        [self zs_renderSyslogBuffer];
        [self zs_openSyslogFullScreenPanel];
        ZLog(@"[UserInterface] syslog console opened");
    } else {
        [self.syslogButton setTitle:@"Show system logs" forState:UIControlStateNormal];
        if (self.syslogFullScreenOpen) {
            [self closeDocsPanel];
        }
        ZLog(@"[UserInterface] syslog console closed");
    }

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_syncSyslogButtonState {
    self.syslogTabEnabled = self.syslogFullScreenOpen;
    [self.syslogButton setTitle:self.syslogFullScreenOpen ? @"Hide system logs" : @"Show system logs"
                       forState:UIControlStateNormal];
}

- (void)zs_toggleSyslogChannelTapped {
    self.syslogDebugModeEnabled = !self.syslogDebugModeEnabled;
    [self zs_updateSyslogInfoLabel];
    self.syslogTableController.atBottom = YES;
    [self zs_renderSyslogBuffer];

    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ZLog(@"[UserInterface] syslog channel switched to %@", self.syslogDebugModeEnabled ? @"tweak-only" : @"all logs");
}

- (void)zs_updateSyslogInfoLabel {
    if (!self.syslogInfoLabel) return;

    NSString *channelName = self.syslogDebugModeEnabled ? @"Debug" : @"Syslog";
    BOOL isBattle = [FPS120Controller shared].isInBattle;

    int32_t sceneState = 0;
    NSString *sceneName = ZSGlobalScene_Current(&sceneState) ? ZSGlobalSceneState_Name(sceneState) : @"Unknown";

    self.syslogInfoLabel.text = [NSString stringWithFormat:@"Channel: %@\nIsBattle: %d\nSceneState: %@[%d]",
                                  channelName, isBattle ? 1 : 0, sceneName, sceneState];
}

- (void)zs_startSyslogInfoRefresh {
    if (self.syslogInfoRefreshTimer) return;
    __weak typeof(self) weakSelf = self;
    self.syslogInfoRefreshTimer = [NSTimer timerWithTimeInterval:1.0
                                                           repeats:YES
                                                             block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.syslogFullScreenOpen) {
            [timer invalidate];
            if (strongSelf) strongSelf.syslogInfoRefreshTimer = nil;
            return;
        }
        [strongSelf zs_updateSyslogInfoLabel];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.syslogInfoRefreshTimer forMode:NSRunLoopCommonModes];
}

static NSString * const kZSHardcodedSyslogBlacklistTerm = @"stencil";

- (BOOL)zs_syslogLineIsBlacklisted:(NSString *)line {
    NSString *lower = line.lowercaseString;
    if ([lower containsString:kZSHardcodedSyslogBlacklistTerm]) return YES;

    if (self.syslogBlacklist.count == 0) return NO;
    for (NSString *term in self.syslogBlacklist) {
        if (term.length > 0 && [lower containsString:term]) return YES;
    }
    return NO;
}

static NSString *zs_stringByTrimmingLeadingWhitespace(NSString *str) {
    NSUInteger i = 0;
    while (i < str.length && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[str characterAtIndex:i]]) {
        i++;
    }
    return [str substringFromIndex:i];
}

static NSRegularExpression *zs_syslogTimestampRegex(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}\\s+\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,6})?"
                                                         options:0 error:nil];
    });
    return re;
}

static NSRegularExpression *zs_syslogProcessRegex(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^[^\\s\\[\\]]+\\[\\d+:\\d+\\]"
                                                         options:0 error:nil];
    });
    return re;
}

static NSRegularExpression *zs_syslogBracketTagRegex(void) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^\\[[^\\[\\]]+\\]"
                                                         options:0 error:nil];
    });
    return re;
}

static BOOL zs_consumeSyslogPrefix(NSRegularExpression *regex, NSString **stringPtr, NSString **capturedPtr) {
    NSString *str = *stringPtr;
    NSTextCheckingResult *match = [regex firstMatchInString:str options:NSMatchingAnchored range:NSMakeRange(0, str.length)];
    if (!match) return NO;

    NSString *matched = [str substringWithRange:match.range];
    NSString *rest = zs_stringByTrimmingLeadingWhitespace([str substringFromIndex:NSMaxRange(match.range)]);
    *stringPtr = rest;
    if (capturedPtr) *capturedPtr = matched;
    return YES;
}

void zs_parseSyslogLineHeader(NSString *line, NSString **outHeader, NSString **outMessage) {
    NSString *remaining = line;
    NSMutableArray<NSString *> *headerParts = [NSMutableArray array];
    NSString *captured = nil;

    if (zs_consumeSyslogPrefix(zs_syslogTimestampRegex(), &remaining, &captured)) {
        [headerParts addObject:captured];

        if (zs_consumeSyslogPrefix(zs_syslogProcessRegex(), &remaining, &captured)) {
            [headerParts addObject:captured];

            NSString *beforeTag = remaining;
            if (zs_consumeSyslogPrefix(zs_syslogBracketTagRegex(), &remaining, &captured) &&
                [captured isEqualToString:kZLogTag]) {
                [headerParts addObject:captured];

                if (zs_consumeSyslogPrefix(zs_syslogBracketTagRegex(), &remaining, &captured)) {
                    [headerParts addObject:captured];
                }
            } else {
                remaining = beforeTag;
            }
        }
    }

    if (headerParts.count == 0) {
        if (outHeader) *outHeader = nil;
        if (outMessage) *outMessage = line;
        return;
    }

    if (outHeader) *outHeader = [headerParts componentsJoinedByString:@"  "];
    if (outMessage) *outMessage = remaining;
}

- (void)appendSyslogLine:(NSString *)line {
    if (!line.length) return;
    [self appendSyslogLines:@[line]];
}

- (void)appendSyslogLines:(NSArray<NSString *> *)lines {
    if (lines.count == 0) return;

    if (!self.syslogChannelLines) self.syslogChannelLines = [NSMutableArray array];
    if (!self.debugChannelLines) self.debugChannelLines = [NSMutableArray array];

    BOOL touchedDisplayed = NO;
    BOOL touchedSyslog = NO;
    BOOL touchedDebug = NO;
    for (NSString *line in lines) {
        if (!line.length) continue;
        if ([self zs_syslogLineIsBlacklisted:line]) continue;

        BOOL isZLogLine = [line containsString:kZLogTag];
        if (isZLogLine) {
            [self.debugChannelLines addObject:line];
            touchedDebug = YES;
            if (self.syslogDebugModeEnabled) touchedDisplayed = YES;
        } else {
            [self.syslogChannelLines addObject:line];
            touchedSyslog = YES;
            if (!self.syslogDebugModeEnabled) touchedDisplayed = YES;
        }
    }

    static const NSUInteger kMaxSyslogLines = 2000;
    if (touchedSyslog && self.syslogChannelLines.count > kMaxSyslogLines) {
        [self.syslogChannelLines removeObjectsInRange:NSMakeRange(0, self.syslogChannelLines.count - kMaxSyslogLines)];
    }
    if (touchedDebug && self.debugChannelLines.count > kMaxSyslogLines) {
        [self.debugChannelLines removeObjectsInRange:NSMakeRange(0, self.debugChannelLines.count - kMaxSyslogLines)];
    }

    if (touchedDisplayed) [self zs_scheduleSyslogRender];
}

- (NSArray<NSString *> *)zs_syslogDisplayLines {
    return self.syslogDebugModeEnabled ? (self.debugChannelLines ?: @[]) : (self.syslogChannelLines ?: @[]);
}

- (void)zs_renderSyslogBuffer {
    if (self.syslogFullScreenOpen) {
        [self zs_renderSyslogFullScreenRows];
    }
}

#pragma mark Syslog full-screen viewer

static const CGFloat kZSSyslogCommandRowHeight = 24;
static const CGFloat kZSSyslogCommandVerticalPadding = 4;
static const CGFloat kZSSyslogCommandHorizontalPadding = 10;
static const CGFloat kZSSyslogCommandKeyboardMargin = 8;

- (void)zs_buildSyslogFullScreenPanelIfNeeded {
    if (self.syslogFullScreenOverlay) return;
    if (!self.extendedContentClip) return;

    UIView *overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.hidden = YES;
    overlay.userInteractionEnabled = YES;
    [self.extendedContentClip addSubview:overlay];
    zs_force_dark(overlay);
    self.syslogFullScreenOverlay = overlay;
    [self zs_installPinchToExitOnView:overlay];

    UIImageSymbolConfiguration *closeSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    UIImage *closeImage = [UIImage systemImageNamed:@"xmark" withConfiguration:closeSymbolConfig];
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(closeButton, closeImage, [UIColor colorWithWhite:1 alpha:0.85]);
    [closeButton addTarget:self action:@selector(zs_closeSyslogFullScreenPanelTapped) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:closeButton];

    UITextField *searchField = [[UITextField alloc] init];
    searchField.font = zs_mono_font(12, UIFontWeightRegular);
    searchField.textColor = UIColor.whiteColor;
    searchField.tintColor = zs_accent_green_color();
    searchField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:@"Search logs"
                                         attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    searchField.returnKeyType = UIReturnKeySearch;
    searchField.delegate = self;
    [searchField addTarget:self action:@selector(zs_syslogSearchFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    self.syslogSearchField = searchField;

    UIVisualEffectView *searchGlass = zs_wrap_field_in_native_glass(searchField, 8);
    UIView *searchContainer = searchGlass ?: searchField;
    searchContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:searchContainer];

    UIImageSymbolConfiguration *pillSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];

    UIImage *exportImage = [UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:pillSymbolConfig];
    UIButton *exportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    exportButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(exportButton, exportImage, [UIColor colorWithWhite:1 alpha:0.9]);
    [overlay addSubview:exportButton];
    self.syslogExportButton = exportButton;
    [self.syslogExportButton addTarget:self action:@selector(zs_exportSyslogVisibleLogsTapped) forControlEvents:UIControlEventTouchUpInside];

    UIGraphicsImageRenderer *slashRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(16, 18)];
    UIImage *slashImage = [[slashRenderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        NSDictionary *slashAttributes = @{NSFontAttributeName: zs_mono_font(16, UIFontWeightSemibold), NSForegroundColorAttributeName: UIColor.whiteColor};
        CGSize glyphSize = [@"/" sizeWithAttributes:slashAttributes];
        [@"/" drawAtPoint:CGPointMake((16 - glyphSize.width) / 2, (18 - glyphSize.height) / 2) withAttributes:slashAttributes];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIButton *slashButton = [UIButton buttonWithType:UIButtonTypeCustom];
    slashButton.translatesAutoresizingMaskIntoConstraints = NO;
    [slashButton setImage:slashImage forState:UIControlStateNormal];
    slashButton.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
    [slashButton addTarget:self action:@selector(zs_syslogSlashTapped) forControlEvents:UIControlEventTouchUpInside];
    self.syslogSlashButton = slashButton;

    UIView *slashContainer = slashButton;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *slashGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(YES)];
        zs_configure_glass_corners(slashGlass, 8, NO);
        zs_register_suspendable_glass(slashGlass);
        [slashGlass.contentView addSubview:slashButton];
        [NSLayoutConstraint activateConstraints:@[
            [slashButton.leadingAnchor constraintEqualToAnchor:slashGlass.contentView.leadingAnchor],
            [slashButton.trailingAnchor constraintEqualToAnchor:slashGlass.contentView.trailingAnchor],
            [slashButton.topAnchor constraintEqualToAnchor:slashGlass.contentView.topAnchor],
            [slashButton.bottomAnchor constraintEqualToAnchor:slashGlass.contentView.bottomAnchor],
        ]];
        slashContainer = slashGlass;
    } else {
        slashButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        slashButton.layer.cornerRadius = 8;
        slashButton.layer.cornerCurve = kCACornerCurveContinuous;
    }
    slashContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:slashContainer];

    UIImage *channelToggleImage = [UIImage systemImageNamed:@"switch.2" withConfiguration:pillSymbolConfig];
    UIButton *channelToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    channelToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(channelToggleButton, channelToggleImage, [UIColor colorWithWhite:1 alpha:0.9]);
    [overlay addSubview:channelToggleButton];
    self.syslogChannelToggleButton = channelToggleButton;
    [self.syslogChannelToggleButton addTarget:self action:@selector(zs_toggleSyslogChannelTapped) forControlEvents:UIControlEventTouchUpInside];

    UILabel *infoLabel = [[UILabel alloc] init];
    infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    infoLabel.numberOfLines = 3;
    infoLabel.textAlignment = NSTextAlignmentLeft;
    infoLabel.font = zs_mono_font(9, UIFontWeightRegular);
    infoLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    [overlay addSubview:infoLabel];
    self.syslogInfoLabel = infoLabel;
    [self zs_updateSyslogInfoLabel];

    ZSSyslogTableController *tableController = [[ZSSyslogTableController alloc] init];
    tableController.longPressTarget = self;
    __weak typeof(self) weakSelf = self;
    tableController.reachedBottom = ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.syslogRenderDeferred) return;
        strongSelf.syslogRenderDeferred = NO;
        [strongSelf zs_renderSyslogFullScreenRows];
    };
    self.syslogTableController = tableController;

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.backgroundColor = UIColor.clearColor;
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.showsVerticalScrollIndicator = YES;
    tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    tableView.alwaysBounceVertical = NO;
    tableView.bounces = NO;
    tableView.allowsSelection = NO;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 40;
    tableView.insetsContentViewsToSafeArea = NO;
    tableView.dataSource = tableController;
    tableView.delegate = tableController;
    tableView.panGestureRecognizer.maximumNumberOfTouches = 1;

    UILabel *emptyLabel = [[UILabel alloc] init];
    emptyLabel.font = zs_mono_font(11, UIFontWeightRegular);
    emptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    emptyLabel.textAlignment = NSTextAlignmentCenter;
    tableView.backgroundView = emptyLabel;
    self.syslogEmptyLabel = emptyLabel;

    [overlay addSubview:tableView];
    self.syslogTableView = tableView;
    self.syslogFullScreenScrollView = tableView;

    self.syslogCloseButtonLeadingConstraint = [closeButton.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset];

    [NSLayoutConstraint activateConstraints:@[
        [closeButton.topAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.topAnchor constant:kPanelPadding],
        self.syslogCloseButtonLeadingConstraint,
        [closeButton.widthAnchor constraintEqualToConstant:30],
        [closeButton.heightAnchor constraintEqualToConstant:30],

        [exportButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [exportButton.leadingAnchor constraintEqualToAnchor:closeButton.trailingAnchor constant:10],
        [exportButton.widthAnchor constraintEqualToConstant:30],
        [exportButton.heightAnchor constraintEqualToConstant:30],

        [channelToggleButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [channelToggleButton.leadingAnchor constraintEqualToAnchor:exportButton.trailingAnchor constant:8],
        [channelToggleButton.widthAnchor constraintEqualToConstant:30],
        [channelToggleButton.heightAnchor constraintEqualToConstant:30],

        [infoLabel.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [infoLabel.leadingAnchor constraintEqualToAnchor:channelToggleButton.trailingAnchor constant:12],

        [slashContainer.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [slashContainer.leadingAnchor constraintGreaterThanOrEqualToAnchor:infoLabel.trailingAnchor constant:10],
        [slashContainer.trailingAnchor constraintEqualToAnchor:searchContainer.leadingAnchor constant:-8],
        [slashContainer.widthAnchor constraintEqualToConstant:30],
        [slashContainer.heightAnchor constraintEqualToConstant:30],

        [searchContainer.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [searchContainer.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [searchContainer.heightAnchor constraintEqualToConstant:30],

        [tableView.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:12],
        [tableView.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [tableView.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [tableView.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor],
    ]];

    NSLayoutConstraint *searchWidth = [searchContainer.widthAnchor constraintEqualToConstant:250];
    searchWidth.priority = UILayoutPriorityDefaultHigh;
    searchWidth.active = YES;

    UIVisualEffectView *commandDropdown = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(NO)];
    commandDropdown.translatesAutoresizingMaskIntoConstraints = NO;
    commandDropdown.layer.cornerRadius = 10;
    commandDropdown.layer.cornerCurve = kCACornerCurveContinuous;
    commandDropdown.clipsToBounds = YES;
    commandDropdown.hidden = YES;
    commandDropdown.alpha = 0;
    commandDropdown.userInteractionEnabled = NO;
    [overlay addSubview:commandDropdown];
    self.syslogCommandDropdown = commandDropdown;

    UIScrollView *commandScroll = [[UIScrollView alloc] init];
    commandScroll.translatesAutoresizingMaskIntoConstraints = NO;
    commandScroll.showsVerticalScrollIndicator = NO;
    commandScroll.showsHorizontalScrollIndicator = NO;
    commandScroll.alwaysBounceVertical = NO;
    commandScroll.bounces = NO;
    commandScroll.panGestureRecognizer.maximumNumberOfTouches = 1;
    [commandDropdown.contentView addSubview:commandScroll];
    self.syslogCommandScroll = commandScroll;

    UIStackView *commandStack = [[UIStackView alloc] init];
    commandStack.translatesAutoresizingMaskIntoConstraints = NO;
    commandStack.axis = UILayoutConstraintAxisVertical;
    commandStack.spacing = 0;
    [commandScroll addSubview:commandStack];
    self.syslogCommandStack = commandStack;

    NSLayoutConstraint *commandHeight = [commandDropdown.heightAnchor constraintEqualToConstant:0];
    self.syslogCommandHeightConstraint = commandHeight;

    [NSLayoutConstraint activateConstraints:@[
        [commandScroll.topAnchor constraintEqualToAnchor:commandDropdown.contentView.topAnchor],
        [commandScroll.bottomAnchor constraintEqualToAnchor:commandDropdown.contentView.bottomAnchor],
        [commandScroll.leadingAnchor constraintEqualToAnchor:commandDropdown.contentView.leadingAnchor],
        [commandScroll.trailingAnchor constraintEqualToAnchor:commandDropdown.contentView.trailingAnchor],

        [commandStack.topAnchor constraintEqualToAnchor:commandScroll.contentLayoutGuide.topAnchor constant:kZSSyslogCommandVerticalPadding],
        [commandStack.bottomAnchor constraintEqualToAnchor:commandScroll.contentLayoutGuide.bottomAnchor constant:-kZSSyslogCommandVerticalPadding],
        [commandStack.leadingAnchor constraintEqualToAnchor:commandScroll.contentLayoutGuide.leadingAnchor constant:kZSSyslogCommandHorizontalPadding],
        [commandStack.trailingAnchor constraintEqualToAnchor:commandScroll.contentLayoutGuide.trailingAnchor constant:-kZSSyslogCommandHorizontalPadding],
        [commandStack.widthAnchor constraintEqualToAnchor:commandScroll.frameLayoutGuide.widthAnchor constant:-2 * kZSSyslogCommandHorizontalPadding],

        [commandDropdown.topAnchor constraintEqualToAnchor:searchContainer.bottomAnchor constant:4],
        [commandDropdown.leadingAnchor constraintEqualToAnchor:searchContainer.leadingAnchor],
        [commandDropdown.trailingAnchor constraintEqualToAnchor:searchContainer.trailingAnchor],
        commandHeight,
    ]];

    if (self.syslogKeyboardObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.syslogKeyboardObserver];
    }
    __weak typeof(self) weakKeyboardSelf = self;
    self.syslogKeyboardObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillChangeFrameNotification
                                                                                    object:nil
                                                                                     queue:NSOperationQueue.mainQueue
                                                                                usingBlock:^(NSNotification *note) {
        [weakKeyboardSelf zs_syslogKeyboardWillChangeFrame:note];
    }];
}

static NSArray<NSDictionary<NSString *, NSString *> *> *zs_syslog_commands(void) {
    return @[
        @{@"name": @"/dump", @"desc": @"Dump IL2CPP methods"},
        @{@"name": @"/sigkill", @"desc": @"SIGKILL the process"},
        @{@"name": @"/symlink", @"desc": @"Expose Library in Files"},
        @{@"name": @"/patchlc", @"desc": @"Patch an IPA for LiveContainer"},
        @{@"name": @"/createlogos", @"desc": @"Pack a logo folder or zip into a .zs"},
        @{@"name": @"/keepalive", @"desc": @"Toggle Keep Alive"},
        @{@"name": @"/memlog", @"desc": @"Start the RamBypass allocation profiler"},
        @{@"name": @"/reload", @"desc": @"Reload a bundle's textures: /reload CAB-XXXXX"},
    ];
}

static BOOL zs_syslog_command_takes_arguments(NSString *name) {
    return [name isEqualToString:@"/reload"];
}

- (NSString *)zs_syslogCommandToken {
    NSString *text = [self.syslogSearchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![text hasPrefix:@"/"]) return nil;
    NSString *token = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].firstObject;
    return token.lowercaseString;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)zs_syslogMatchingCommands {
    NSString *token = [self zs_syslogCommandToken];
    if (token.length == 0) return @[];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *matches = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *command in zs_syslog_commands()) {
        if ([command[@"name"] hasPrefix:token]) [matches addObject:command];
    }
    return matches;
}

- (BOOL)zs_syslogCommandModeActive {
    return [self zs_syslogMatchingCommands].count > 0;
}

- (CGFloat)zs_syslogCommandDropdownHeightForKeyboardFrame:(CGRect)hostKeyboardFrame {
    UIView *overlay = self.syslogFullScreenOverlay;
    UIView *dropdown = self.syslogCommandDropdown;
    UIStackView *stack = self.syslogCommandStack;
    if (!overlay || !dropdown || !stack) return 0;

    CGFloat desired = stack.arrangedSubviews.count * kZSSyslogCommandRowHeight + 2 * kZSSyslogCommandVerticalPadding;
    [overlay layoutIfNeeded];

    CGFloat limit = CGRectGetHeight(overlay.bounds) - overlay.safeAreaInsets.bottom;
    UIView *host = zs_ui_host_view();
    if (host && !CGRectIsEmpty(hostKeyboardFrame)) {
        CGRect keyboardInOverlay = [overlay convertRect:hostKeyboardFrame fromView:host];
        limit = MIN(limit, CGRectGetMinY(keyboardInOverlay));
    }

    CGFloat available = floor(limit - CGRectGetMinY(dropdown.frame) - kZSSyslogCommandKeyboardMargin);
    CGFloat height = MAX(0, MIN(desired, available));
    self.syslogCommandScroll.scrollEnabled = desired > height + 0.5;
    return height;
}

- (void)zs_syslogKeyboardWillChangeFrame:(NSNotification *)note {
    UIView *dropdown = self.syslogCommandDropdown;
    UIView *overlay = self.syslogFullScreenOverlay;
    NSLayoutConstraint *heightConstraint = self.syslogCommandHeightConstraint;
    NSValue *endValue = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    UIView *host = zs_ui_host_view();
    if (!dropdown || !overlay || !heightConstraint || !host || !endValue) return;
    if (dropdown.hidden || !dropdown.userInteractionEnabled) return;

    CGRect endFrame = [host convertRect:endValue.CGRectValue fromView:nil];
    CGFloat inset = CGRectGetHeight(host.bounds) - CGRectGetMinY(endFrame);
    CGRect keyboardFrame = (inset >= 8 && !CGRectIsEmpty(endFrame)) ? endFrame : CGRectZero;

    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve = [note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    CGFloat target = [self zs_syslogCommandDropdownHeightForKeyboardFrame:keyboardFrame];

    [UIView animateWithDuration:duration
                          delay:0
                        options:(UIViewAnimationOptions)(curve << 16) | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        heightConstraint.constant = target;
        [overlay layoutIfNeeded];
    } completion:nil];
}

- (void)zs_collapseSyslogCommandDropdown {
    UIVisualEffectView *dropdown = self.syslogCommandDropdown;
    NSLayoutConstraint *heightConstraint = self.syslogCommandHeightConstraint;
    UIView *overlay = self.syslogFullScreenOverlay;
    if (!dropdown || !heightConstraint || !overlay) return;
    if (dropdown.hidden && !dropdown.userInteractionEnabled) return;

    dropdown.userInteractionEnabled = NO;
    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        heightConstraint.constant = 0;
        dropdown.alpha = 0;
        [overlay layoutIfNeeded];
    } completion:^(BOOL finished) {
        if (!dropdown.userInteractionEnabled) dropdown.hidden = YES;
    }];
}

- (void)zs_updateSyslogCommandDropdown {
    UIVisualEffectView *dropdown = self.syslogCommandDropdown;
    UIStackView *stack = self.syslogCommandStack;
    NSLayoutConstraint *heightConstraint = self.syslogCommandHeightConstraint;
    UIView *overlay = self.syslogFullScreenOverlay;
    if (!dropdown || !stack || !heightConstraint || !overlay) return;

    NSArray<NSDictionary<NSString *, NSString *> *> *matches = (self.syslogSearchField.isFirstResponder || self.syslogCommandBrowseActive) ? [self zs_syslogMatchingCommands] : @[];
    NSString *trimmed = [[self.syslogSearchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    BOOL hasArguments = [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound;
    if (matches.count == 0 || hasArguments || (matches.count == 1 && [trimmed isEqualToString:matches.firstObject[@"name"]])) {
        [self zs_collapseSyslogCommandDropdown];
        return;
    }

    for (UIView *row in stack.arrangedSubviews) {
        [stack removeArrangedSubview:row];
        [row removeFromSuperview];
    }

    for (NSDictionary<NSString *, NSString *> *command in matches) {
        NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:command[@"name"]
                                                                                   attributes:@{
            NSFontAttributeName: zs_mono_font(11, UIFontWeightSemibold),
            NSForegroundColorAttributeName: zs_accent_green_color(),
        }];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:command[@"desc"]]
                                                                      attributes:@{
            NSFontAttributeName: zs_mono_font(9, UIFontWeightRegular),
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55],
        }]];

        UILabel *row = [[UILabel alloc] init];
        row.attributedText = title;
        row.numberOfLines = 1;
        row.lineBreakMode = NSLineBreakByTruncatingTail;
        row.userInteractionEnabled = YES;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [row.heightAnchor constraintEqualToConstant:kZSSyslogCommandRowHeight].active = YES;
        objc_setAssociatedObject(row, "zs_commandName", command[@"name"], OBJC_ASSOCIATION_COPY);
        [row addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_syslogCommandRowTapped:)]];
        [stack addArrangedSubview:row];
    }

    BOOL wasVisible = !dropdown.hidden && dropdown.userInteractionEnabled;
    [overlay bringSubviewToFront:dropdown];
    dropdown.userInteractionEnabled = YES;
    if (!wasVisible) {
        dropdown.hidden = NO;
        dropdown.alpha = 0;
        heightConstraint.constant = 0;
        [overlay layoutIfNeeded];
    }

    CGFloat target = [self zs_syslogCommandDropdownHeightForKeyboardFrame:self.zs_lastKeyboardFrame];
    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        heightConstraint.constant = target;
        dropdown.alpha = 1;
        [overlay layoutIfNeeded];
    } completion:nil];
}

- (void)zs_syslogCommandRowTapped:(UITapGestureRecognizer *)gesture {
    NSString *name = objc_getAssociatedObject(gesture.view, "zs_commandName");
    if (name.length == 0) return;

    BOOL browsing = self.syslogCommandBrowseActive && !self.syslogSearchField.isFirstResponder;
    if (zs_syslog_command_takes_arguments(name)) {
        self.syslogCommandBrowseActive = NO;
        self.syslogSearchField.text = [name stringByAppendingString:@" "];
        [self.syslogSearchField becomeFirstResponder];
        [self zs_syslogSearchFieldChanged:self.syslogSearchField];
        UIImpactFeedbackGenerator *argumentHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [argumentHaptic impactOccurred];
        return;
    }
    self.syslogSearchField.text = name;
    if (browsing) {
        self.syslogCommandBrowseActive = NO;
        UIImpactFeedbackGenerator *browseHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [browseHaptic impactOccurred];
        [self zs_executeSyslogCommandIfNeeded];
        return;
    }
    [self zs_syslogSearchFieldChanged:self.syslogSearchField];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_syslogSlashTapped {
    UITextField *field = self.syslogSearchField;
    if (!field) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    if (self.syslogCommandBrowseActive) {
        [self zs_syslogEndCommandBrowse];
        return;
    }
    self.syslogCommandBrowseActive = !field.isFirstResponder;
    field.text = @"/";
    [self zs_syslogSearchFieldChanged:field];
}

- (void)zs_syslogEndCommandBrowse {
    if (!self.syslogCommandBrowseActive) return;
    self.syslogCommandBrowseActive = NO;
    self.syslogSearchField.text = @"";
    [self zs_syslogSearchFieldChanged:self.syslogSearchField];
}

- (void)zs_executeSyslogCommandIfNeeded {
    NSString *token = [self zs_syslogCommandToken];
    NSString *name = nil;
    NSArray<NSDictionary<NSString *, NSString *> *> *matches = [self zs_syslogMatchingCommands];
    for (NSDictionary<NSString *, NSString *> *command in matches) {
        if ([command[@"name"] isEqualToString:token]) {
            name = command[@"name"];
            break;
        }
    }
    if (!name && matches.count == 1) name = matches.firstObject[@"name"];
    if (!name) return;

    NSString *fullText = [self.syslogSearchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRange tokenEnd = [fullText rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *arguments = tokenEnd.location == NSNotFound ? @"" : [[fullText substringFromIndex:NSMaxRange(tokenEnd)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    self.syslogSearchField.text = @"";
    [self zs_syslogSearchFieldChanged:self.syslogSearchField];
    ZLog(@"[UserInterface] command executed: %@ %@", name, arguments);

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf zs_runSyslogCommand:name arguments:arguments];
    });
}

- (void)zs_runSyslogCommand:(NSString *)name arguments:(NSString *)arguments {
    if ([name isEqualToString:@"/dump"]) {
        [self dumpIL2CPPMethodsTapped];
    } else if ([name isEqualToString:@"/sigkill"]) {
        [ZCrashLogger killProcessWithSIGKILL];
    } else if ([name isEqualToString:@"/symlink"]) {
        [self librarySymlinkTapped];
    } else if ([name isEqualToString:@"/patchlc"]) {
        [self patchLCTapped];
    } else if ([name isEqualToString:@"/createlogos"]) {
        [self zs_createLogosTapped];
    } else if ([name isEqualToString:@"/keepalive"]) {
        [self toggleKeepAliveTapped];
        [self zs_showSyslogToastWithText:self.keepAliveEnabled ? @"Keep Alive enabled" : @"Keep Alive disabled"];
    } else if ([name isEqualToString:@"/memlog"]) {
        zs_ram_bypass_memlog();
        [self zs_showSyslogToastWithText:@"Memlog running"];
    } else if ([name isEqualToString:@"/reload"]) {
        if (arguments.length == 0) {
            [self zs_showSyslogToastWithText:@"Usage: /reload CAB-XXXXX"];
            return;
        }
        [self zs_showSyslogToastWithText:@"Reloading bundle..."];
        __weak typeof(self) weakSelf = self;
        [ZTLiveReloader reloadBundleForCABInput:arguments completion:^(BOOL success, NSString *summary) {
            [weakSelf zs_showSyslogToastWithText:summary];
        }];
    }
}

- (NSArray<NSString *> *)zs_syslogFullScreenFilteredLines {
    NSArray<NSString *> *base = [self zs_syslogDisplayLines];
    NSString *query = [self.syslogSearchField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0 || [self zs_syslogCommandModeActive]) return base;

    NSString *lowerQuery = query.lowercaseString;
    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *line in base) {
        if ([line.lowercaseString containsString:lowerQuery]) {
            [filtered addObject:line];
        }
    }
    return filtered;
}

- (void)zs_renderSyslogFullScreenRows {
    UITableView *tableView = self.syslogTableView;
    ZSSyslogTableController *controller = self.syslogTableController;
    if (!tableView || !controller) return;

    NSArray<NSString *> *lines = [self zs_syslogFullScreenFilteredLines];

    UIEdgeInsets overlaySafeInsets = self.syslogFullScreenOverlay.safeAreaInsets;
    CGFloat logIndent = kZSSyslogFullScreenLeftInset + overlaySafeInsets.left * 0.15;
    self.syslogCloseButtonLeadingConstraint.constant = logIndent;
    controller.leftInset = logIndent;
    controller.rightInset = 16 + overlaySafeInsets.right * 0.15;
    controller.lines = lines;

    self.syslogRenderDeferred = NO;
    BOOL stickToBottom = controller.atBottom;
    self.syslogEmptyLabel.text = (self.syslogSearchField.text.length > 0 && ![self zs_syslogCommandModeActive]) ? @"No matching log lines" : @"[syslog] no output yet";
    self.syslogEmptyLabel.hidden = lines.count > 0;
    [tableView reloadData];
    if (stickToBottom && lines.count > 0) [self zs_scrollSyslogFullScreenToBottom];
}

- (void)zs_scheduleSyslogRender {
    if (!self.syslogFullScreenOpen || self.syslogRenderScheduled) return;
    self.syslogRenderScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.syslogRenderScheduled = NO;
        if (!strongSelf.syslogFullScreenOpen) return;
        if (!strongSelf.syslogTableController.atBottom) {
            strongSelf.syslogRenderDeferred = YES;
            return;
        }
        [strongSelf zs_renderSyslogFullScreenRows];
    });
}

- (void)handleSyslogFullScreenRowLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    NSString *text = objc_getAssociatedObject(gesture.view, "zs_logLineText");
    if (!text.length) return;

    [UIPasteboard generalPasteboard].string = text;

    UIView *flash = [[UIView alloc] initWithFrame:gesture.view.bounds];
    flash.backgroundColor = [zs_accent_green_color() colorWithAlphaComponent:0.25];
    flash.userInteractionEnabled = NO;
    flash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gesture.view addSubview:flash];
    [UIView animateWithDuration:0.3 animations:^{
        flash.alpha = 0;
    } completion:^(BOOL finished) {
        [flash removeFromSuperview];
    }];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];

    [self zs_showSyslogCopiedToast];
}

- (void)zs_showSyslogCopiedToast {
    [self zs_showSyslogToastWithText:@"Copied log to clipboard"];
}

- (void)zs_showSyslogToastWithText:(NSString *)text {
    UIView *overlay = self.syslogFullScreenOverlay;
    if (!overlay) return;

    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;

    UIView *toast = self.syslogCopyToastView;
    if (!toast) {
        UIVisualEffectView *toastGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect(NO)];
        toastGlass.translatesAutoresizingMaskIntoConstraints = NO;
        toastGlass.layer.cornerRadius = 14;
        toastGlass.layer.cornerCurve = kCACornerCurveContinuous;
        toastGlass.clipsToBounds = YES;
        toastGlass.alpha = 0;
        toastGlass.userInteractionEnabled = NO;

        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = text;
        label.font = zs_mono_font(11, UIFontWeightMedium);
        label.textColor = [UIColor colorWithWhite:1 alpha:0.92];
        label.textAlignment = NSTextAlignmentCenter;
        [toastGlass.contentView addSubview:label];

        [overlay addSubview:toastGlass];

        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:toastGlass.contentView.topAnchor constant:10],
            [label.bottomAnchor constraintEqualToAnchor:toastGlass.contentView.bottomAnchor constant:-10],
            [label.leadingAnchor constraintEqualToAnchor:toastGlass.contentView.leadingAnchor constant:16],
            [label.trailingAnchor constraintEqualToAnchor:toastGlass.contentView.trailingAnchor constant:-16],

            [toastGlass.centerXAnchor constraintEqualToAnchor:unityView.centerXAnchor],
            [toastGlass.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor constant:-16],
        ]];

        self.syslogCopyToastView = toastGlass;
        toast = toastGlass;
    }

    UIView *toastFirstSubview = [(UIVisualEffectView *)toast contentView].subviews.firstObject;
    if ([toastFirstSubview isKindOfClass:[UILabel class]]) ((UILabel *)toastFirstSubview).text = text;

    [overlay bringSubviewToFront:toast];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(zs_hideSyslogCopiedToast) object:nil];
    [UIView animateWithDuration:0.2 animations:^{
        toast.alpha = 1;
    }];
    [self performSelector:@selector(zs_hideSyslogCopiedToast) withObject:nil afterDelay:1.4];
}

- (void)zs_hideSyslogCopiedToast {
    [UIView animateWithDuration:0.25 animations:^{
        self.syslogCopyToastView.alpha = 0;
    }];
}

- (void)zs_syslogSearchFieldChanged:(UITextField *)field {
    self.syslogTableController.atBottom = YES;
    [self zs_renderSyslogFullScreenRows];
    [self zs_updateSyslogCommandDropdown];
}

- (void)zs_exportSyslogVisibleLogsTapped {
    NSArray<NSString *> *lines = [self zs_syslogFullScreenFilteredLines];
    NSString *joined = [lines componentsJoinedByString:@"\n"];

    UIActivityViewController *activityVC =
        [[UIActivityViewController alloc] initWithActivityItems:@[joined] applicationActivities:nil];
    activityVC.popoverPresentationController.sourceView = self.syslogExportButton;
    activityVC.popoverPresentationController.sourceRect = self.syslogExportButton.bounds;

    UIViewController *presenter = zs_key_window().rootViewController;
    [presenter presentViewController:activityVC animated:YES completion:nil];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)zs_syncReducedPanelFPS {
    [[FPS120Controller shared] setReducedPanelFPS:self.syslogFullScreenOpen || self.memoryFullScreenOpen || self.assetExplorerFullScreenOpen || self.dumperFullScreenOpen];
}

- (void)zs_openSyslogFullScreenPanel {
    if (!self.panelOpen) return;
    if (self.syslogFullScreenOpen) return;

    [self zs_buildSyslogFullScreenPanelIfNeeded];
    if (!self.syslogFullScreenOverlay) return;

    [self zs_endMemoryAnalysis];
    [self zs_endAssetExplorerSession];
    [self zs_endDumperSession];
    self.docsActiveKey = nil;
    self.syslogFullScreenOpen = YES;
    [self zs_startSyslogInfoRefresh];

    self.docsPanelOpen = YES;
    [self positionPanelAnimated:!self.extendedCoverEntering];

    [self.syslogFullScreenOverlay layoutIfNeeded];
    [self zs_updateSyslogInfoLabel];
    self.syslogTableController.atBottom = YES;
    [self zs_renderSyslogFullScreenRows];
    [self zs_scrollSyslogFullScreenToBottom];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.syslogFullScreenOpen) return;
        [strongSelf zs_scrollSyslogFullScreenToBottom];
    });
}

- (void)zs_scrollSyslogFullScreenToBottom {
    UITableView *tableView = self.syslogTableView;
    if (!tableView) return;
    self.syslogTableController.atBottom = YES;
    NSInteger count = [tableView numberOfRowsInSection:0];
    if (count <= 0) return;
    [self.syslogFullScreenOverlay layoutIfNeeded];
    [tableView layoutIfNeeded];
    [tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:count - 1 inSection:0]
                     atScrollPosition:UITableViewScrollPositionBottom
                             animated:NO];
}

- (void)zs_installPinchToExitOnView:(UIView *)view {
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(zs_fullScreenPinched:)];
    pinch.delegate = self;
    pinch.cancelsTouchesInView = NO;
    [view addGestureRecognizer:pinch];
}

- (void)zs_fullScreenPinched:(UIPinchGestureRecognizer *)pinch {
    if (self.assetExplorerFullScreenOpen && self.assetExplorerTextureOpen) return;
    if (pinch.state != UIGestureRecognizerStateChanged) return;
    if (pinch.numberOfTouches < 2 || pinch.scale > 0.8) return;
    pinch.enabled = NO;
    pinch.enabled = YES;
    if (self.memoryPopupScrim || self.pinchDismissInFlight) return;
    if (self.extendedCoverMode && self.panelOpen) {
        UIView *coverOverlay = self.dumperFullScreenOpen ? self.dumperFullScreenOverlay : self.memoryFullScreenOpen ? self.memoryFullScreenOverlay : (self.assetExplorerFullScreenOpen ? self.assetExplorerFullScreenOverlay : (self.syslogFullScreenOpen ? self.syslogFullScreenOverlay : nil));
        [self zs_pinchDismissCoverOverlay:coverOverlay];
        return;
    }
    if (self.dumperFullScreenOpen) {
        [self zs_playPinchDismissOnOverlay:self.dumperFullScreenOverlay];
        [self zs_closeDumperFullScreenPanelTapped];
    } else if (self.memoryFullScreenOpen) {
        [self zs_playPinchDismissOnOverlay:self.memoryFullScreenOverlay];
        [self zs_closeMemoryFullScreenPanelTapped];
    } else if (self.assetExplorerFullScreenOpen) {
        [self zs_playPinchDismissOnOverlay:self.assetExplorerFullScreenOverlay];
        [self zs_closeAssetExplorerFullScreenPanelTapped];
    } else if (self.syslogFullScreenOpen) {
        [self zs_playPinchDismissOnOverlay:self.syslogFullScreenOverlay];
        [self zs_closeSyslogFullScreenPanelTapped];
    }
}

- (void)zs_pinchDismissCoverOverlay:(UIView *)overlay {
    UIView *container = self.glassContainer;
    if (!overlay || !container) return;

    self.pinchDismissInFlight = YES;
    overlay.userInteractionEnabled = NO;
    [self zs_syslogEndCommandBrowse];
    [self.syslogSearchField resignFirstResponder];
    [self.assetExplorerSearchField resignFirstResponder];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.26
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        overlay.transform = CGAffineTransformMakeScale(0.78, 0.78);
        overlay.alpha = 0;
        container.alpha = 0;
    } completion:^(BOOL finished) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.pinchDismissInFlight = NO;
        if (!strongSelf.panelOpen || strongSelf.glassContainer != container) return;
        [strongSelf closePanelAnimated:NO];
    }];
}

- (void)zs_playPinchDismissOnOverlay:(UIView *)overlay {
    if (!overlay) return;
    [UIView animateWithDuration:0.26
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        overlay.transform = CGAffineTransformMakeScale(0.78, 0.78);
        overlay.alpha = 0;
    } completion:nil];
}

- (void)zs_closeSyslogFullScreenPanelTapped {
    if (!self.syslogFullScreenOpen) return;

    [self zs_syslogEndCommandBrowse];
    [self.syslogSearchField resignFirstResponder];
    [self closeDocsPanel];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

#pragma mark Memory full-screen viewer

- (void)memoryUsageAnalyzeTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tapHaptic impactOccurred];

    if (self.memoryFullScreenOpen) {
        if (self.docsPanelOpen) {
            [self closeDocsPanel];
        } else {
            [self zs_endMemoryAnalysis];
        }
        return;
    }

    [self zs_openMemoryFullScreenPanel];
}

- (void)zs_syncMemoryButtonState {
    BOOL active = self.memoryFullScreenOpen;
    [self.memoryUsageAnalyzeButton setTitle:active ? @"Stop analysis" : @"Analyze memory usage" forState:UIControlStateNormal];
    [self.memoryUsageAnalyzeButton setTitleColor:active ? [UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:1.0] : zs_accent_green_color()
                                        forState:UIControlStateNormal];
}

- (void)zs_endMemoryAnalysis {
    [NSNotificationCenter.defaultCenter removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [self zs_dismissMemoryPopupAnimated:NO];
    [self.memoryRefreshPieLayer removeAllAnimations];
    [self.memoryBigPieLayer removeAllAnimations];
    [self.memoryInvertMaskLayer removeAllAnimations];
    [self.memoryClockTimer invalidate];
    self.memoryClockTimer = nil;
    self.memoryFeed = nil;
    self.memoryInfoPanel.hidden = YES;
    [self.memoryUsageRefreshTimer invalidate];
    self.memoryUsageRefreshTimer = nil;
    self.memoryFullScreenOpen = NO;
    self.memoryPendingGroups = nil;
    self.memoryPendingColumns = nil;
    self.memoryLocalPages = nil;
    self.memoryCyclePhase = 0;
    self.memoryCycleUnitsDone = 0;
    self.memoryCycleStart = 0;
    self.memorySnapshotSystemRows = nil;
    self.memorySnapshotGroups = nil;
    self.memorySnapshotDate = nil;
    self.memoryHasSnapshot = NO;
    zs_memory_scan_reset();
    [self zs_syncMemoryButtonState];
}

- (void)zs_buildMemoryFullScreenPanelIfNeeded {
    if (self.memoryFullScreenOverlay) return;
    if (!self.extendedContentClip) return;

    UIView *overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.hidden = YES;
    overlay.userInteractionEnabled = YES;
    [self.extendedContentClip addSubview:overlay];
    zs_force_dark(overlay);
    self.memoryFullScreenOverlay = overlay;
    [self zs_installPinchToExitOnView:overlay];

    UIImageSymbolConfiguration *closeSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    UIImage *closeImage = [UIImage systemImageNamed:@"xmark" withConfiguration:closeSymbolConfig];
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(closeButton, closeImage, [UIColor colorWithWhite:1 alpha:0.85]);
    [closeButton addTarget:self action:@selector(zs_closeMemoryFullScreenPanelTapped) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:closeButton];

    UIImage *exportImage = [UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:closeSymbolConfig];
    UIButton *exportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    exportButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(exportButton, exportImage, [UIColor colorWithWhite:1 alpha:0.9]);
    [exportButton addTarget:self action:@selector(zs_exportMemchartTapped) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:exportButton];
    self.memoryExportButton = exportButton;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Memchart";
    titleLabel.font = zs_mono_font(12, UIFontWeightSemibold);
    titleLabel.textColor = [UIColor colorWithWhite:0.96 alpha:1];
    [overlay addSubview:titleLabel];

    UILabel *statusLabel = [[UILabel alloc] init];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.text = @"Scanning…";
    statusLabel.font = zs_mono_font(9, UIFontWeightRegular);
    statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    statusLabel.textAlignment = NSTextAlignmentRight;
    [statusLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [overlay addSubview:statusLabel];
    self.memoryFullScreenStatusLabel = statusLabel;

    UIPageControl *pageControl = [[UIPageControl alloc] init];
    pageControl.translatesAutoresizingMaskIntoConstraints = NO;
    pageControl.numberOfPages = 1;
    pageControl.currentPage = 0;
    pageControl.hidesForSinglePage = YES;
    pageControl.pageIndicatorTintColor = [UIColor colorWithWhite:1 alpha:0.28];
    pageControl.currentPageIndicatorTintColor = [UIColor colorWithWhite:1 alpha:0.92];
    [pageControl setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [pageControl setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [pageControl addTarget:self action:@selector(zs_memoryPageControlChanged:) forControlEvents:UIControlEventValueChanged];
    [overlay addSubview:pageControl];
    self.memoryPageControl = pageControl;

    UIView *pieView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    pieView.translatesAutoresizingMaskIntoConstraints = NO;
    pieView.userInteractionEnabled = NO;
    UIView *pieDisc = [[UIView alloc] initWithFrame:CGRectMake(2, 2, 26, 26)];
    pieDisc.userInteractionEnabled = NO;
    pieDisc.layer.cornerRadius = 13;
    pieDisc.layer.masksToBounds = YES;
    [pieView addSubview:pieDisc];
    CAShapeLayer *pieLayer = [CAShapeLayer layer];
    pieLayer.frame = CGRectMake(0, 0, 26, 26);
    pieLayer.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(13, 13) radius:7 startAngle:-M_PI_2 endAngle:1.5 * M_PI clockwise:YES].CGPath;
    pieLayer.fillColor = UIColor.clearColor.CGColor;
    pieLayer.strokeColor = UIColor.whiteColor.CGColor;
    pieLayer.lineWidth = 14;
    pieLayer.strokeEnd = 1;
    [pieDisc.layer addSublayer:pieLayer];
    [overlay addSubview:pieView];
    self.memoryRefreshPieView = pieView;
    self.memoryRefreshPieLayer = pieLayer;

    ZSDeadZoneScrollView *scrollView = [[ZSDeadZoneScrollView alloc] init];
    scrollView.deadZone = 12;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scrollView.panGestureRecognizer.maximumNumberOfTouches = 1;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.backgroundColor = UIColor.clearColor;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.showsVerticalScrollIndicator = NO;
    scrollView.bounces = NO;
    scrollView.alwaysBounceVertical = NO;
    scrollView.alwaysBounceHorizontal = NO;
    scrollView.directionalLockEnabled = YES;
    scrollView.pagingEnabled = YES;
    scrollView.delegate = self;
    [overlay addSubview:scrollView];
    self.memoryFullScreenScrollView = scrollView;

    UIView *infoPanel = [[UIView alloc] initWithFrame:CGRectZero];
    infoPanel.backgroundColor = UIColor.clearColor;
    infoPanel.hidden = YES;
    infoPanel.userInteractionEnabled = NO;
    [scrollView addSubview:infoPanel];
    self.memoryInfoPanel = infoPanel;

    UIView *bigDisc = [[UIView alloc] initWithFrame:CGRectZero];
    bigDisc.userInteractionEnabled = NO;
    bigDisc.layer.masksToBounds = YES;
    [infoPanel addSubview:bigDisc];
    CAShapeLayer *bigPie = [CAShapeLayer layer];
    bigPie.fillColor = UIColor.clearColor.CGColor;
    bigPie.strokeColor = UIColor.whiteColor.CGColor;
    bigPie.strokeEnd = 1;
    [bigDisc.layer addSublayer:bigPie];
    self.memoryBigPieDisc = bigDisc;
    self.memoryBigPieLayer = bigPie;

    UILabel *clockLabel = [[UILabel alloc] init];
    clockLabel.textColor = [UIColor colorWithWhite:0.96 alpha:1];
    clockLabel.textAlignment = NSTextAlignmentLeft;
    clockLabel.text = @"0.000000s";
    [infoPanel addSubview:clockLabel];
    self.memoryClockLabel = clockLabel;

    UILabel *subtextLabel = [[UILabel alloc] init];
    subtextLabel.textAlignment = NSTextAlignmentLeft;
    subtextLabel.attributedText = zs_memory_fetch_subtext([UIColor colorWithWhite:1 alpha:0.5]);
    [infoPanel addSubview:subtextLabel];
    self.memorySubtextLabel = subtextLabel;

    UIView *invertClip = [[UIView alloc] initWithFrame:CGRectZero];
    invertClip.userInteractionEnabled = NO;
    invertClip.backgroundColor = UIColor.clearColor;
    invertClip.layer.masksToBounds = YES;
    [infoPanel addSubview:invertClip];
    CAShapeLayer *invertMask = [CAShapeLayer layer];
    invertMask.fillColor = UIColor.clearColor.CGColor;
    invertMask.strokeColor = UIColor.whiteColor.CGColor;
    invertMask.strokeEnd = 1;
    invertClip.layer.mask = invertMask;
    UILabel *invertClock = [[UILabel alloc] init];
    invertClock.textColor = [UIColor colorWithWhite:0.04 alpha:1];
    invertClock.textAlignment = NSTextAlignmentLeft;
    invertClock.text = clockLabel.text;
    [invertClip addSubview:invertClock];
    UILabel *invertSubtext = [[UILabel alloc] init];
    invertSubtext.textAlignment = NSTextAlignmentLeft;
    invertSubtext.attributedText = zs_memory_fetch_subtext([UIColor colorWithWhite:0 alpha:0.55]);
    [invertClip addSubview:invertSubtext];
    self.memoryInvertSubtextLabel = invertSubtext;
    self.memoryInvertClip = invertClip;
    self.memoryInvertMaskLayer = invertMask;
    self.memoryInvertClockLabel = invertClock;

    NSLayoutConstraint *pageControlLeading = [pageControl.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:8];
    pageControlLeading.priority = UILayoutPriorityDefaultHigh;

    self.memoryCloseButtonLeadingConstraint = [closeButton.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:kZSSyslogFullScreenLeftInset];

    [NSLayoutConstraint activateConstraints:@[
        [closeButton.topAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.topAnchor constant:kPanelPadding],
        self.memoryCloseButtonLeadingConstraint,
        [closeButton.widthAnchor constraintEqualToConstant:30],
        [closeButton.heightAnchor constraintEqualToConstant:30],

        [exportButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [exportButton.leadingAnchor constraintEqualToAnchor:closeButton.trailingAnchor constant:10],
        [exportButton.widthAnchor constraintEqualToConstant:30],
        [exportButton.heightAnchor constraintEqualToConstant:30],

        [titleLabel.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:exportButton.trailingAnchor constant:12],

        [statusLabel.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:10],
        [statusLabel.trailingAnchor constraintEqualToAnchor:pieView.leadingAnchor constant:-10],

        [pageControl.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [pageControl.trailingAnchor constraintEqualToAnchor:statusLabel.leadingAnchor constant:-8],
        pageControlLeading,

        [pieView.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [pieView.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-kPanelPadding],
        [pieView.widthAnchor constraintEqualToConstant:30],
        [pieView.heightAnchor constraintEqualToConstant:30],

        [scrollView.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:12],
        [scrollView.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.bottomAnchor],
    ]];
}

- (void)zs_openMemoryFullScreenPanel {
    if (!self.panelOpen) return;
    if (self.memoryFullScreenOpen) return;

    [self zs_buildMemoryFullScreenPanelIfNeeded];
    if (!self.memoryFullScreenOverlay) return;

    if (self.docsLanguageDropdownOpen) {
        [self zs_closeDocsLanguageDropdownAnimated:NO];
    }
    if (self.syslogFullScreenOpen) {
        [self zs_syslogEndCommandBrowse];
        [self.syslogSearchField resignFirstResponder];
        self.syslogFullScreenOpen = NO;
        [self zs_syncSyslogButtonState];
    }
    [self zs_endAssetExplorerSession];
    [self zs_endDumperSession];

    self.docsActiveKey = nil;
    self.memoryFullScreenOpen = YES;
    self.memoryHasSnapshot = NO;
    [self zs_syncMemoryButtonState];
    self.memoryFullScreenStatusLabel.text = @"Scanning…";

    self.docsPanelOpen = YES;
    [self positionPanelAnimated:!self.extendedCoverEntering];

    [self zs_renderMemoryColumnsWithStats:zs_collect_memory_system_stats() groups:@[]];
    self.memoryFullScreenStatusLabel.text = @"Scanning…";
    [self zs_startMemoryUsageAutoRefresh];
}

- (void)zs_closeMemoryFullScreenPanelTapped {
    if (!self.memoryFullScreenOpen) return;

    [self closeDocsPanel];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_applyMemoryPieAnimationsToLayers:(NSArray<CAShapeLayer *> *)layers beginMediaTime:(CFTimeInterval)beginMediaTime {
    if (layers.count == 0) return;

    CFTimeInterval begin = [layers.firstObject convertTime:beginMediaTime fromLayer:nil];
    CFTimeInterval duration = ZS_MEMORY_SCAN_CYCLE_SECONDS * 2.0;

    for (CAShapeLayer *layer in layers) {
        [layer removeAllAnimations];

        CAKeyframeAnimation *fill = [CAKeyframeAnimation animationWithKeyPath:@"strokeEnd"];
        fill.values = @[@0, @1, @1];
        fill.keyTimes = @[@0, @0.5, @1];
        fill.calculationMode = kCAAnimationLinear;
        fill.duration = duration;
        fill.repeatCount = HUGE_VALF;
        fill.beginTime = begin;
        [layer addAnimation:fill forKey:@"zsPieFill"];

        CAKeyframeAnimation *drain = [CAKeyframeAnimation animationWithKeyPath:@"strokeStart"];
        drain.values = @[@0, @0, @1];
        drain.keyTimes = @[@0, @0.5, @1];
        drain.calculationMode = kCAAnimationLinear;
        drain.duration = duration;
        drain.repeatCount = HUGE_VALF;
        drain.beginTime = begin;
        [layer addAnimation:drain forKey:@"zsPieDrain"];
    }
}

- (void)zs_startMemoryRefreshPie {
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval begin = (self.memoryCycleStart > 0 && self.memoryCycleStart <= now) ? self.memoryCycleStart : now;
    self.memoryPieBegin = begin;
    if (self.memoryRefreshPieLayer) {
        [self zs_applyMemoryPieAnimationsToLayers:@[self.memoryRefreshPieLayer] beginMediaTime:begin];
    }
    NSMutableArray<CAShapeLayer *> *bigLayers = [NSMutableArray array];
    if (self.memoryBigPieLayer) [bigLayers addObject:self.memoryBigPieLayer];
    if (self.memoryInvertMaskLayer) [bigLayers addObject:self.memoryInvertMaskLayer];
    [self zs_applyMemoryPieAnimationsToLayers:bigLayers beginMediaTime:begin];
    [self zs_memoryClockTick];
}

- (void)zs_startMemoryClockTimer {
    [self.memoryClockTimer invalidate];
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf zs_memoryClockTick];
    }];
    self.memoryClockTimer = timer;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)zs_memoryClockTick {
    UILabel *label = self.memoryClockLabel;
    if (!label || !self.memoryFullScreenOpen || self.memoryInfoPanel.hidden) return;
    if (self.memoryPageControl.currentPage != 0) return;

    double cycle = ZS_MEMORY_SCAN_CYCLE_SECONDS;
    double elapsed = MAX(CACurrentMediaTime() - self.memoryPieBegin, 0.0);
    double remaining = cycle - fmod(elapsed, cycle);
    NSInteger totalUs = MAX(MIN((NSInteger)llround(remaining * 1000000.0), (NSInteger)llround(cycle * 1000000.0)), 0);
    NSString *text = [NSString stringWithFormat:@"%ld.%06ld%@", (long)(totalUs / 1000000), (long)(totalUs % 1000000), @"s"];
    if (![label.text isEqualToString:text]) label.text = text;
    if (![self.memoryInvertClockLabel.text isEqualToString:text]) self.memoryInvertClockLabel.text = text;
    [self zs_updateMemoryStatRows];
}

- (void)zs_updateMemoryStatRows {
    NSArray<UILabel *> *labels = self.memoryStatLabels;
    if (labels.count == 0) return;

    NSUInteger phase = self.memoryCyclePhase;
    NSArray *groups = self.memoryPendingGroups;
    NSString *phaseName = phase == 0 ? @"SCAN" : (phase == 1 ? @"BUILD" : @"COMMIT");
    NSUInteger planned = MAX(self.memoryCycleUnitEstimate, self.memoryCycleUnitsDone);
    NSString *columns = groups ? [NSString stringWithFormat:@"%lu/%lu", (unsigned long)MIN(self.memoryBuildIndex, groups.count + 1), (unsigned long)(groups.count + 1)] : @"--";
    NSString *age = self.memorySnapshotDate ? [NSString stringWithFormat:@"%.2fs", MAX(-[self.memorySnapshotDate timeIntervalSinceNow], 0.0)] : @"--";
    NSString *work = self.memoryLastWork > 0 ? [NSString stringWithFormat:@"%.0fms", self.memoryLastWork * 1000.0] : @"--";
    NSString *peak = self.memoryLastPeak > 0 ? [NSString stringWithFormat:@"%.0fms", self.memoryLastPeak * 1000.0] : @"--";

    NSArray<NSArray<NSString *> *> *rows = @[
        @[@"CYCLE", [NSString stringWithFormat:@"#%lu", (unsigned long)self.memoryCycleCount]],
        @[@"PHASE", phaseName],
        @[@"STEP", [NSString stringWithFormat:@"%lu/%lu", (unsigned long)self.memoryCycleUnitsDone, (unsigned long)planned]],
        @[@"COLS", columns],
        @[@"AGE", age],
        @[@"WORK", work],
        @[@"PEAK", peak],
        @[@"OVER", [NSString stringWithFormat:@"%lu", (unsigned long)self.memoryCycleOverruns]],
    ];

    UIFont *font = zs_mono_font(8, UIFontWeightRegular);
    UIColor *keyColor = [UIColor colorWithWhite:1 alpha:0.42];
    UIColor *valueColor = [UIColor colorWithWhite:0.92 alpha:1];
    for (NSUInteger i = 0; i < labels.count && i < rows.count; i++) {
        NSString *key = [NSString stringWithFormat:@"%-5s ", rows[i][0].UTF8String];
        NSString *plain = [key stringByAppendingString:rows[i][1]];
        UILabel *label = labels[i];
        if ([label.attributedText.string isEqualToString:plain]) continue;
        NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:plain attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: valueColor}];
        [attributed addAttribute:NSForegroundColorAttributeName value:keyColor range:NSMakeRange(0, key.length)];
        label.attributedText = attributed;
    }
}

- (void)zs_pushMemoryFeed:(NSString *)text {
    if (text.length == 0) return;
    if (!self.memoryFeed) self.memoryFeed = [NSMutableArray new];

    NSMutableDictionary *last = self.memoryFeed.lastObject;
    if (last && [last[@"t"] isEqualToString:text]) {
        last[@"n"] = @([last[@"n"] integerValue] + 1);
    } else {
        [self.memoryFeed addObject:[@{@"t": text, @"n": @1} mutableCopy]];
        if (self.memoryFeed.count > 32) [self.memoryFeed removeObjectAtIndex:0];
    }
    [self zs_renderMemoryFeed];
}

- (void)zs_renderMemoryFeed {
    NSArray<UILabel *> *labels = self.memoryFeedLabels;
    if (labels.count == 0 || self.memoryInfoPanel.hidden) return;

    NSArray<UILabel *> *invertLabels = self.memoryInvertFeedLabels;
    NSUInteger total = labels.count;
    NSUInteger available = self.memoryFeed.count;
    for (NSUInteger i = 0; i < total; i++) {
        UILabel *label = labels[i];
        UILabel *invertLabel = i < invertLabels.count ? invertLabels[i] : nil;
        NSInteger entryIndex = (NSInteger)available - (NSInteger)total + (NSInteger)i;
        if (entryIndex < 0) {
            label.text = nil;
            invertLabel.text = nil;
            continue;
        }
        NSDictionary *entry = self.memoryFeed[(NSUInteger)entryIndex];
        NSInteger repeats = [entry[@"n"] integerValue];
        label.text = repeats > 1 ? [NSString stringWithFormat:@"> %@ ×%ld", entry[@"t"], (long)repeats] : [@"> " stringByAppendingString:entry[@"t"]];
        label.alpha = 0.3 + 0.7 * (CGFloat)(i + 1) / (CGFloat)total;
        invertLabel.text = label.text;
        invertLabel.alpha = label.alpha;
    }
}

- (void)zs_layoutMemoryInfoPanelInFrame:(CGRect)frame {
    UIView *panel = self.memoryInfoPanel;
    if (!panel) return;

    panel.frame = frame;
    CGFloat width = frame.size.width;
    CGFloat height = frame.size.height;
    CGFloat gap = 14;
    CGFloat sideInset = 20;
    CGFloat statGap = 12;
    CGFloat innerWidth = MAX(width - sideInset * 2, 40);

    CGFloat basePie = MAX(MIN(innerWidth, (height - gap * 4 - 34) * 0.6), 40);
    CGFloat pieSide = MIN(basePie * 1.3, height - gap * 2);
    pieSide = floor(MAX(pieSide, 40));

    UILabel *subtext = self.memorySubtextLabel;
    NSString *clockTemplate = [NSString stringWithFormat:@"%ld.000000%@", (long)ceil(ZS_MEMORY_SCAN_CYCLE_SECONDS), @"s"];
    UIFont *statFont = zs_mono_font(8, UIFontWeightRegular);
    CGFloat statWidth = ceil([@"PHASE COMMIT" sizeWithAttributes:@{NSFontAttributeName: statFont}].width) + 2;
    BOOL showStats = YES;
    UIFont *clockFont = nil;
    CGFloat columnWidth = 0;
    for (NSUInteger pass = 0; pass < 4; pass++) {
        clockFont = zs_mono_font(zs_memory_clamp(pieSide * 0.2, 18, 30), UIFontWeightMedium);
        CGFloat clockWidth = ceil([clockTemplate sizeWithAttributes:@{NSFontAttributeName: clockFont}].width) + 2;
        CGFloat subtextWidth = ceil([subtext sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width) + 2;
        columnWidth = MAX(clockWidth, subtextWidth);
        CGFloat extra = showStats ? statGap + statWidth : 0;
        if (columnWidth + pieSide / 2.0 + extra <= innerWidth) break;
        CGFloat fitted = floor(2.0 * (innerWidth - columnWidth - extra));
        if (fitted >= 40) {
            pieSide = MIN(fitted, pieSide);
        } else if (showStats) {
            showStats = NO;
        } else {
            pieSide = 40;
            break;
        }
    }

    CGFloat collectiveWidth = columnWidth + pieSide / 2.0 + (showStats ? statGap + statWidth : 0);
    CGFloat columnX = floor((width - collectiveWidth) / 2.0);
    CGFloat pieX = floor(columnX + columnWidth - pieSide / 2.0);
    CGFloat pieY = floor((height - pieSide) / 2.0);
    CGFloat pieBottom = pieY + pieSide;

    UIView *disc = self.memoryBigPieDisc;
    disc.frame = CGRectMake(pieX, pieY, pieSide, pieSide);
    disc.layer.cornerRadius = pieSide / 2.0;
    CGRect local = CGRectMake(0, 0, pieSide, pieSide);
    CGFloat pieStroke = pieSide / 2.0 + 2.0;
    UIBezierPath *piePath = [UIBezierPath bezierPathWithArcCenter:CGPointMake(pieSide / 2.0, pieSide / 2.0)
                                                           radius:pieStroke / 2.0
                                                       startAngle:-M_PI_2
                                                         endAngle:1.5 * M_PI
                                                        clockwise:YES];
    self.memoryBigPieLayer.frame = local;
    self.memoryBigPieLayer.path = piePath.CGPath;
    self.memoryBigPieLayer.lineWidth = pieStroke;

    UIView *invertClip = self.memoryInvertClip;
    invertClip.frame = disc.frame;
    invertClip.layer.cornerRadius = pieSide / 2.0;
    self.memoryInvertMaskLayer.frame = local;
    self.memoryInvertMaskLayer.path = piePath.CGPath;
    self.memoryInvertMaskLayer.lineWidth = pieStroke;

    CGFloat subtextHeight = ceil([subtext sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].height);
    subtext.frame = CGRectMake(columnX, pieY, columnWidth, subtextHeight);
    self.memoryInvertSubtextLabel.frame = CGRectOffset(subtext.frame, -pieX, -pieY);

    UILabel *clock = self.memoryClockLabel;
    clock.font = clockFont;
    CGFloat clockHeight = ceil(clock.font.lineHeight);
    clock.frame = CGRectMake(columnX, pieY + subtextHeight + 1, columnWidth, clockHeight);

    UILabel *invertClock = self.memoryInvertClockLabel;
    invertClock.font = clock.font;
    invertClock.frame = CGRectOffset(clock.frame, -pieX, -pieY);

    CGFloat feedTop = CGRectGetMaxY(clock.frame) + 10;
    CGFloat feedHeight = MAX(pieBottom - feedTop, 0);

    UIFont *feedFont = zs_mono_font(8, UIFontWeightRegular);
    CGFloat lineHeight = ceil(feedFont.lineHeight) + 1;

    for (UILabel *old in self.memoryFeedLabels) [old removeFromSuperview];
    for (UILabel *old in self.memoryInvertFeedLabels) [old removeFromSuperview];
    NSUInteger lineCount = (NSUInteger)MAX(floor(feedHeight / lineHeight), 0);
    NSMutableArray<UILabel *> *labels = [NSMutableArray arrayWithCapacity:lineCount];
    NSMutableArray<UILabel *> *invertLabels = [NSMutableArray arrayWithCapacity:lineCount];
    CGFloat firstLineY = pieBottom - lineHeight * (CGFloat)lineCount;
    for (NSUInteger i = 0; i < lineCount; i++) {
        CGRect lineFrame = CGRectMake(columnX, firstLineY + lineHeight * (CGFloat)i, columnWidth, lineHeight);

        UILabel *label = zs_memory_make_label(nil, feedFont, [UIColor colorWithWhite:0.92 alpha:1], NSTextAlignmentLeft);
        label.frame = lineFrame;
        [panel addSubview:label];
        [labels addObject:label];

        UILabel *invertLabel = zs_memory_make_label(nil, feedFont, [UIColor colorWithWhite:0.08 alpha:1], NSTextAlignmentLeft);
        invertLabel.frame = CGRectOffset(lineFrame, -pieX, -pieY);
        [invertClip addSubview:invertLabel];
        [invertLabels addObject:invertLabel];
    }
    self.memoryFeedLabels = labels;
    self.memoryInvertFeedLabels = invertLabels;

    for (UILabel *old in self.memoryStatLabels) [old removeFromSuperview];
    NSMutableArray<UILabel *> *statLabels = [NSMutableArray array];
    if (showStats) {
        CGFloat statLineHeight = ceil(statFont.lineHeight) + 1;
        NSUInteger statRows = MIN((NSUInteger)8, (NSUInteger)MAX(floor(pieSide / statLineHeight), 0));
        CGFloat blockHeight = statLineHeight * (CGFloat)statRows;
        CGFloat statX = pieX + pieSide + statGap;
        CGFloat statY = pieY + floor((pieSide - blockHeight) / 2.0);
        for (NSUInteger i = 0; i < statRows; i++) {
            UILabel *statLabel = [[UILabel alloc] init];
            statLabel.numberOfLines = 1;
            statLabel.lineBreakMode = NSLineBreakByClipping;
            statLabel.adjustsFontSizeToFitWidth = YES;
            statLabel.minimumScaleFactor = 0.6;
            statLabel.frame = CGRectMake(statX, statY + statLineHeight * (CGFloat)i, MAX(statWidth, width - 6 - statX), statLineHeight);
            [panel addSubview:statLabel];
            [statLabels addObject:statLabel];
        }
    }
    self.memoryStatLabels = statLabels;
    [panel bringSubviewToFront:invertClip];

    [self zs_renderMemoryFeed];
    [self zs_updateMemoryStatRows];
    [self zs_memoryClockTick];
}

- (void)zs_changeMemoryTopAssetsPageBy:(NSInteger)delta {
    NSInteger next = (NSInteger)zs_memory_top_assets_page() + delta;
    if (next < 0) return;
    zs_set_memory_top_assets_page((NSUInteger)next);

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    [self zs_runMemoryUsageScan];
}

- (void)zs_dismissMemoryPopupAnimated:(BOOL)animated {
    UIView *scrim = self.memoryPopupScrim;
    UIView *popup = self.memoryPopupView;
    if (!scrim && !popup) return;
    self.memoryPopupScrim = nil;
    self.memoryPopupView = nil;
    self.memoryNumpadText = nil;
    self.memoryNumpadDisplayLabel = nil;
    scrim.userInteractionEnabled = NO;
    UIView *dropdownSource = objc_getAssociatedObject(popup, "zs_dropdownSource");
    NSValue *dropdownCollapsed = objc_getAssociatedObject(popup, "zs_dropdownCollapsedFrame");
    void (^remove)(void) = ^{
        [scrim removeFromSuperview];
        [popup removeFromSuperview];
        dropdownSource.hidden = NO;
    };
    if (!animated) {
        remove();
        return;
    }
    if (dropdownSource && dropdownCollapsed) {
        [UIView animateWithDuration:0.18
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            popup.frame = dropdownCollapsed.CGRectValue;
            popup.alpha = 0;
        } completion:^(BOOL finished) {
            remove();
        }];
        return;
    }
    [UIView animateWithDuration:0.12
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        popup.alpha = 0;
        popup.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        remove();
    }];
}

- (void)zs_memoryPopupScrimTapped {
    [self zs_dismissMemoryPopupAnimated:YES];
}

- (void)zs_installMemoryPopup:(UIView *)popup frame:(CGRect)frame overlay:(UIView *)overlay {
    UIControl *scrim = [[UIControl alloc] initWithFrame:overlay.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = UIColor.clearColor;
    [scrim addTarget:self action:@selector(zs_memoryPopupScrimTapped) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:scrim];

    popup.frame = frame;
    popup.alpha = 0;
    popup.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [overlay addSubview:popup];

    self.memoryPopupScrim = scrim;
    self.memoryPopupView = popup;

    [UIView animateWithDuration:0.16
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        popup.alpha = 1;
        popup.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)zs_memoryPopupHighlight:(UIControl *)control {
    control.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
}

- (void)zs_memoryPopupUnhighlight:(UIControl *)control {
    control.backgroundColor = UIColor.clearColor;
}

- (void)zs_presentMemoryKindPopupFromView:(UIView *)source group:(ZSMemoryUsageGroup *)group {
    UIView *overlay = self.memoryFullScreenOverlay;
    if (!overlay) return;
    if (self.memoryPopupView) {
        [self zs_dismissMemoryPopupAnimated:YES];
        return;
    }
    NSArray<ZSMemoryUsageCategory *> *options = group.kindOptions;
    if (options.count == 0) return;

    int64_t totalBytes = 0;
    for (ZSMemoryUsageCategory *option in options) totalBytes += option.totalBytes;

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:options.count + 1];
    [entries addObject:@{@"title": [NSString stringWithFormat:@"All Kinds · %@", zs_memory_megabytes_string(totalBytes)],
                         @"active": @(group.activeKind.length == 0)}];
    for (ZSMemoryUsageCategory *option in options) {
        [entries addObject:@{@"kind": option.name ?: @"",
                             @"title": [NSString stringWithFormat:@"%@ · %@", option.name, zs_memory_megabytes_string(option.totalBytes)],
                             @"active": @([option.name isEqualToString:group.activeKind])}];
    }

    static const CGFloat kWidth = 260;
    CGRect anchor = [source convertRect:source.bounds toView:overlay];
    UIEdgeInsets insets = overlay.safeAreaInsets;
    CGFloat minX = insets.left + 8;
    CGFloat maxX = MAX(minX, overlay.bounds.size.width - insets.right - 8 - kWidth);
    CGFloat top = insets.top + 8;
    CGFloat bottom = overlay.bounds.size.height - insets.bottom - 8;
    CGFloat fullHeight = kZSModsOptionsRowHeight * entries.count;
    CGFloat height = MIN(fullHeight, MAX(bottom - top, kZSModsOptionsRowHeight));
    CGFloat x = MIN(MAX(CGRectGetMaxX(anchor) - kWidth, minX), maxX);
    CGFloat y = MAX(top, MIN(CGRectGetMinY(anchor), bottom - height));
    CGRect expandedFrame = CGRectMake(x, y, kWidth, height);

    UIControl *scrim = [[UIControl alloc] initWithFrame:overlay.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = UIColor.clearColor;
    [scrim addTarget:self action:@selector(zs_memoryPopupScrimTapped) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:scrim];

    UIView *dropdown;
    UIVisualEffectView *glassDropdown = nil;
    if (zs_has_liquid_glass()) {
        glassDropdown = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(YES)];
        glassDropdown.frame = anchor;
        glassDropdown.clipsToBounds = YES;
        zs_configure_glass_corners(glassDropdown, kZSAuthFieldCornerRadius, NO);
        glassDropdown.layer.borderWidth = 1;
        glassDropdown.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        zs_register_suspendable_glass(glassDropdown);
        dropdown = glassDropdown;
    } else {
        dropdown = [[UIView alloc] initWithFrame:anchor];
        dropdown.clipsToBounds = YES;
        dropdown.layer.cornerRadius = kZSAuthFieldCornerRadius;
        dropdown.layer.cornerCurve = kCACornerCurveContinuous;
        dropdown.layer.borderWidth = 1;
        dropdown.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        dropdown.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.98];
    }
    [overlay addSubview:dropdown];

    UIView *rowHost = glassDropdown ? glassDropdown.contentView : dropdown;
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, kWidth, height)];
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = NO;
    scroll.contentSize = CGSizeMake(kWidth, fullHeight);
    scroll.alpha = 0;
    [rowHost addSubview:scroll];

    CGFloat hairline = 1.0 / MAX(UIScreen.mainScreen.scale, (CGFloat)1.0);
    for (NSInteger i = 0; i < (NSInteger)entries.count; i++) {
        NSDictionary *entry = entries[i];
        BOOL active = [entry[@"active"] boolValue];
        UIButton *rowButton = zs_make_mods_options_row_button(@{@"title": entry[@"title"],
                                                                @"symbol": active ? @"checkmark" : @"",
                                                                @"destructive": @NO},
                                                              i, self, @selector(zs_memoryKindRowTapped:));
        rowButton.frame = CGRectMake(0, i * kZSModsOptionsRowHeight, kWidth, kZSModsOptionsRowHeight);
        objc_setAssociatedObject(rowButton, "zs_kind", entry[@"kind"], OBJC_ASSOCIATION_COPY_NONATOMIC);
        [scroll addSubview:rowButton];

        if (i > 0) {
            UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, i * kZSModsOptionsRowHeight - hairline, kWidth, hairline)];
            divider.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.5];
            [scroll addSubview:divider];
        }
    }

    objc_setAssociatedObject(dropdown, "zs_dropdownSource", source, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(dropdown, "zs_dropdownCollapsedFrame", [NSValue valueWithCGRect:anchor], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    source.hidden = YES;
    dropdown.alpha = 0;
    self.memoryPopupScrim = scrim;
    self.memoryPopupView = dropdown;

    [UIView animateWithDuration:0.22
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        dropdown.frame = expandedFrame;
        scroll.alpha = 1;
    } completion:nil];
    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        dropdown.alpha = 1;
    } completion:nil];

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_memoryKindRowTapped:(UIButton *)row {
    NSString *kind = objc_getAssociatedObject(row, "zs_kind");
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    zs_set_memory_top_assets_kind_filter(kind);
    [self zs_dismissMemoryPopupAnimated:YES];
    [self zs_runMemoryUsageScan];
}

- (void)zs_updateMemoryNumpadDisplay {
    UILabel *label = self.memoryNumpadDisplayLabel;
    if (!label) return;
    BOOL empty = self.memoryNumpadText.length == 0;
    NSMutableDictionary *attributes = [@{
        NSFontAttributeName: zs_mono_font(26, UIFontWeightMedium),
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:empty ? 0.3 : 1],
    } mutableCopy];
    if (self.memoryNumpadFresh && !empty) {
        attributes[NSBackgroundColorAttributeName] = [UIColor colorWithRed:0.96 green:0.62 blue:0.22 alpha:0.42];
    }
    label.attributedText = [[NSAttributedString alloc] initWithString:empty ? @"\u2014" : self.memoryNumpadText attributes:attributes];
}

- (void)zs_presentMemoryPageNumpadFromView:(UIView *)source group:(ZSMemoryUsageGroup *)group {
    UIView *overlay = self.memoryFullScreenOverlay;
    if (!overlay) return;
    if (self.memoryPopupView) {
        [self zs_dismissMemoryPopupAnimated:YES];
        return;
    }

    static const CGFloat kKeyWidth = 62;
    static const CGFloat kKeyHeight = 46;
    static const CGFloat kHeaderHeight = 54;
    CGFloat width = kKeyWidth * 4;
    CGFloat height = kHeaderHeight + kKeyHeight * 4;
    CGRect frame = zs_memory_popup_frame(overlay, source, CGSizeMake(width, height));
    if (frame.size.height < height) {
        frame.size.height = height;
        frame.origin.y = MAX(overlay.safeAreaInsets.top + 4, overlay.bounds.size.height - overlay.safeAreaInsets.bottom - 4 - height);
    }

    self.memoryNumpadPageCount = MAX(group.pageCount, (NSUInteger)1);
    self.memoryNumpadCurrentPage = group.pageIndex + 1;
    self.memoryNumpadText = [NSMutableString stringWithFormat:@"%lu", (unsigned long)self.memoryNumpadCurrentPage];
    self.memoryNumpadFresh = YES;

    UIVisualEffectView *surface = zs_memory_make_popup_surface(CGSizeMake(width, height));
    UIView *content = surface.contentView;

    UILabel *display = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, width - 14 - 78, kHeaderHeight)];
    display.textAlignment = NSTextAlignmentRight;
    display.adjustsFontSizeToFitWidth = YES;
    display.minimumScaleFactor = 0.6;
    [content addSubview:display];
    self.memoryNumpadDisplayLabel = display;

    UILabel *suffix = zs_memory_make_label([NSString stringWithFormat:@"/ %lu", (unsigned long)self.memoryNumpadPageCount],
                                           zs_mono_font(14, UIFontWeightMedium),
                                           [UIColor colorWithWhite:1 alpha:0.55],
                                           NSTextAlignmentLeft);
    suffix.frame = CGRectMake(width - 70, 0, 60, kHeaderHeight);
    [content addSubview:suffix];

    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    void (^addKey)(NSString *, NSString *, CGRect) = ^(NSString *identifier, NSString *symbol, CGRect keyFrame) {
        UIButton *key = [UIButton buttonWithType:UIButtonTypeCustom];
        key.frame = keyFrame;
        if (symbol) {
            [key setImage:[UIImage systemImageNamed:symbol withConfiguration:symbolConfig] forState:UIControlStateNormal];
            key.tintColor = UIColor.whiteColor;
        } else {
            [key setTitle:identifier forState:UIControlStateNormal];
            [key setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            key.titleLabel.font = zs_mono_font(20, UIFontWeightMedium);
        }
        objc_setAssociatedObject(key, "zs_key", identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [key addTarget:self action:@selector(zs_memoryNumpadKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
        [key addTarget:self action:@selector(zs_memoryPopupHighlight:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [key addTarget:self action:@selector(zs_memoryPopupUnhighlight:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
        [content addSubview:key];
    };

    NSArray<NSArray<NSString *> *> *digitRows = @[@[@"7", @"8", @"9"], @[@"4", @"5", @"6"], @[@"1", @"2", @"3"]];
    for (NSUInteger r = 0; r < digitRows.count; r++) {
        for (NSUInteger c = 0; c < 3; c++) {
            addKey(digitRows[r][c], nil, CGRectMake(c * kKeyWidth, kHeaderHeight + r * kKeyHeight, kKeyWidth, kKeyHeight));
        }
    }
    addKey(@"0", nil, CGRectMake(0, kHeaderHeight + 3 * kKeyHeight, kKeyWidth * 3, kKeyHeight));
    addKey(@"delete", @"delete.left", CGRectMake(kKeyWidth * 3, kHeaderHeight, kKeyWidth, kKeyHeight * 2));
    addKey(@"enter", @"return", CGRectMake(kKeyWidth * 3, kHeaderHeight + kKeyHeight * 2, kKeyWidth, kKeyHeight * 2));

    CGFloat hairline = 1.0 / MAX(overlay.traitCollection.displayScale, 1.0);
    UIColor *lineColor = [UIColor colorWithWhite:1 alpha:0.14];
    void (^addLine)(CGRect) = ^(CGRect lineFrame) {
        UIView *line = [[UIView alloc] initWithFrame:lineFrame];
        line.backgroundColor = lineColor;
        line.userInteractionEnabled = NO;
        [content addSubview:line];
    };
    addLine(CGRectMake(0, kHeaderHeight, width, hairline));
    addLine(CGRectMake(0, kHeaderHeight + kKeyHeight, kKeyWidth * 3, hairline));
    addLine(CGRectMake(0, kHeaderHeight + kKeyHeight * 2, width, hairline));
    addLine(CGRectMake(0, kHeaderHeight + kKeyHeight * 3, kKeyWidth * 3, hairline));
    addLine(CGRectMake(kKeyWidth, kHeaderHeight, hairline, kKeyHeight * 3));
    addLine(CGRectMake(kKeyWidth * 2, kHeaderHeight, hairline, kKeyHeight * 3));
    addLine(CGRectMake(kKeyWidth * 3, kHeaderHeight, hairline, kKeyHeight * 4));

    [self zs_updateMemoryNumpadDisplay];
    [self zs_installMemoryPopup:surface frame:frame overlay:overlay];
}

- (void)zs_memoryNumpadKeyTapped:(UIButton *)key {
    NSString *identifier = objc_getAssociatedObject(key, "zs_key");
    if (!identifier || !self.memoryNumpadText) return;

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];

    if ([identifier isEqualToString:@"enter"]) {
        [self zs_commitMemoryPageNumpad];
        return;
    }

    if ([identifier isEqualToString:@"delete"]) {
        if (self.memoryNumpadFresh) {
            [self.memoryNumpadText setString:@""];
            self.memoryNumpadFresh = NO;
        } else if (self.memoryNumpadText.length > 0) {
            [self.memoryNumpadText deleteCharactersInRange:NSMakeRange(self.memoryNumpadText.length - 1, 1)];
        }
        [self zs_updateMemoryNumpadDisplay];
        return;
    }

    if (self.memoryNumpadFresh) {
        [self.memoryNumpadText setString:@""];
        self.memoryNumpadFresh = NO;
    }
    if ([self.memoryNumpadText isEqualToString:@"0"]) {
        if ([identifier isEqualToString:@"0"]) return;
        [self.memoryNumpadText setString:@""];
    }
    if (self.memoryNumpadText.length >= 9) return;
    [self.memoryNumpadText appendString:identifier];
    [self zs_updateMemoryNumpadDisplay];
}

- (void)zs_commitMemoryPageNumpad {
    NSString *text = [self.memoryNumpadText copy];
    BOOL unchanged = self.memoryNumpadFresh;
    NSUInteger pageCount = MAX(self.memoryNumpadPageCount, (NSUInteger)1);
    NSUInteger currentPage = self.memoryNumpadCurrentPage;
    [self zs_dismissMemoryPopupAnimated:YES];

    if (text.length == 0 || unchanged) return;

    unsigned long long requested = strtoull(text.UTF8String, NULL, 10);
    unsigned long long clamped = MIN(MAX(requested, 1ULL), (unsigned long long)pageCount);
    if ((NSUInteger)clamped == currentPage) return;

    zs_set_memory_top_assets_page((NSUInteger)clamped - 1);
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self zs_runMemoryUsageScan];
}

- (void)zs_startMemoryUsageAutoRefresh {
    [self.memoryUsageRefreshTimer invalidate];
    self.memoryUsageRefreshTimer = nil;
    self.memoryCycleUnitEstimate = 30;
    self.memoryCycleUnitsDone = 0;
    self.memoryCyclePhase = 0;
    self.memoryCycleStart = CACurrentMediaTime();
    self.memoryCycleCount = 0;
    self.memoryCycleOverruns = 0;
    self.memoryCycleWorkAccum = 0;
    self.memoryCycleMaxStep = 0;
    self.memoryLastWork = 0;
    self.memoryLastPeak = 0;
    [NSNotificationCenter.defaultCenter removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(zs_memoryAppDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    self.memoryFeed = nil;
    [self zs_pushMemoryFeed:@"Starting scan"];
    [self zs_startMemoryRefreshPie];
    [self zs_startMemoryClockTimer];
    [self zs_runMemoryUsageScan];
}

- (void)zs_alignMemoryCycleToPieGrid {
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval begin = self.memoryPieBegin;
    BOOL animating = self.memoryRefreshPieLayer && [self.memoryRefreshPieLayer animationForKey:@"zsPieFill"] != nil;
    if (begin <= 0 || begin > now || !animating) {
        self.memoryCycleStart = now;
        [self zs_startMemoryRefreshPie];
        return;
    }
    double cycle = ZS_MEMORY_SCAN_CYCLE_SECONDS;
    self.memoryCycleStart = begin + floor((now - begin) / cycle) * cycle;
}

- (void)zs_memoryAppDidBecomeActive {
    if (!self.memoryFullScreenOpen) return;
    [self zs_alignMemoryCycleToPieGrid];
    [self zs_restartMemoryCycleKeepingPie:YES];
}

- (void)zs_storeMemorySnapshotWithStats:(ZSMemorySystemStats)stats
                                   rows:(NSArray<ZSMemoryColumnRow *> *)rows
                                 groups:(NSArray<ZSMemoryUsageGroup *> *)groups {
    self.memorySnapshotStats = stats;
    self.memorySnapshotSystemRows = rows;
    self.memorySnapshotGroups = groups;
    self.memorySnapshotDate = [NSDate date];
    self.memoryHasSnapshot = YES;
}

- (void)zs_restartMemoryCycle {
    [self zs_restartMemoryCycleKeepingPie:NO];
}

- (void)zs_restartMemoryCycleKeepingPie:(BOOL)keepPie {
    zs_memory_scan_reset();
    self.memoryCyclePhase = 0;
    self.memoryCycleUnitsDone = 0;
    self.memoryPendingGroups = nil;
    self.memoryPendingColumns = nil;
    if (!keepPie) {
        self.memoryCycleStart = CACurrentMediaTime();
        [self zs_startMemoryRefreshPie];
    }
    [self zs_scheduleNextMemoryStep];
}

- (NSTimeInterval)zs_memoryNextStepDelay {
    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval cycleEnd = self.memoryCycleStart + ZS_MEMORY_SCAN_CYCLE_SECONDS;
    NSTimeInterval base = MAX(now, self.memoryCycleStart);
    NSUInteger planned = MAX(self.memoryCycleUnitEstimate, self.memoryCycleUnitsDone + 2);
    NSUInteger remaining = planned - self.memoryCycleUnitsDone;
    NSTimeInterval interval = MAX(cycleEnd - base, 0.0) / (NSTimeInterval)remaining;
    return (base - now) + MAX(interval, 0.02);
}

- (void)zs_scheduleNextMemoryStep {
    [self.memoryUsageRefreshTimer invalidate];
    self.memoryUsageRefreshTimer = nil;
    if (!self.memoryFullScreenOpen) return;

    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:[self zs_memoryNextStepDelay] repeats:NO block:^(NSTimer *timer) {
        [weakSelf zs_memoryPacedStep];
    }];
    self.memoryUsageRefreshTimer = timer;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)zs_memoryPacedStep {
    self.memoryUsageRefreshTimer = nil;
    if (!self.memoryFullScreenOpen) return;

    CFTimeInterval stepStart = CACurrentMediaTime();
    BOOL cycleDone = NO;
    if (self.memoryCyclePhase == 0) {
        NSArray<ZSMemoryUsageGroup *> *groups = zs_memory_scan_step(NULL);
        [self zs_pushMemoryFeed:zs_memory_scan_current_status()];
        if (groups) {
            self.memoryPendingGroups = groups;
            self.memoryPendingColumns = [NSMutableArray array];
            self.memoryBuildIndex = 0;
            self.memoryBuildGroupColumnCount = 0;
            self.memoryBuildSkipped = NO;
            self.memoryCyclePhase = 1;
        }
    } else if (self.memoryCyclePhase == 1) {
        [self zs_buildNextPendingMemoryColumn];
    } else {
        [self zs_commitPendingMemoryColumns];
        cycleDone = YES;
    }

    CFTimeInterval stepDuration = CACurrentMediaTime() - stepStart;
    self.memoryCycleWorkAccum += stepDuration;
    self.memoryCycleMaxStep = MAX(self.memoryCycleMaxStep, stepDuration);
    self.memoryCycleUnitsDone++;
    if (cycleDone) [self zs_finishMemoryCycle];
    [self zs_scheduleNextMemoryStep];
}

- (void)zs_finishMemoryCycle {
    self.memoryCycleUnitEstimate = MAX(self.memoryCycleUnitsDone, (NSUInteger)8);

    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval cycleEnd = self.memoryCycleStart + ZS_MEMORY_SCAN_CYCLE_SECONDS;
    BOOL overran = now - cycleEnd > 1.0;
    self.memoryCycleStart = cycleEnd;
    if (overran) [self zs_alignMemoryCycleToPieGrid];
    self.memoryCycleCount++;
    if (overran) self.memoryCycleOverruns++;
    self.memoryLastWork = self.memoryCycleWorkAccum;
    self.memoryLastPeak = self.memoryCycleMaxStep;
    self.memoryCycleWorkAccum = 0;
    self.memoryCycleMaxStep = 0;

    self.memoryCycleUnitsDone = 0;
    self.memoryCyclePhase = 0;
    self.memoryPendingGroups = nil;
    self.memoryPendingColumns = nil;
}

- (void)zs_buildNextPendingMemoryColumn {
    NSArray<ZSMemoryUsageGroup *> *groups = self.memoryPendingGroups;
    NSUInteger index = self.memoryBuildIndex;

    if (index == 0) {
        [self zs_pushMemoryFeed:@"task_info · host_statistics64 · sysctl"];
        ZSMemorySystemStats stats = zs_collect_memory_system_stats();
        NSArray<ZSMemoryColumnRow *> *rows = zs_memory_system_stat_rows(stats);
        [self zs_storeMemorySnapshotWithStats:stats rows:rows groups:groups];

        self.memoryBuildSkipped = ![self zs_prepareMemoryBuildMetrics];
        if (!self.memoryBuildSkipped) {
            UIView *systemColumn = zs_build_memory_column(@"System", nil, rows, nil, YES, 0, zs_memory_column_width(@"System", self.memoryBuildPanelWidth, self.extendedCoverMode), self.memoryBuildHeight, NO, NULL, NULL);
            if (systemColumn) [self.memoryPendingColumns addObject:systemColumn];
        }
    } else if (!self.memoryBuildSkipped && index - 1 < groups.count) {
        UIView *column = [self zs_memoryColumnForGroup:groups[index - 1] height:self.memoryBuildHeight panelWidth:self.memoryBuildPanelWidth];
        if (column) {
            [self.memoryPendingColumns addObject:column];
            self.memoryBuildGroupColumnCount++;
        }
    }

    self.memoryBuildIndex = index + 1;
    if (self.memoryBuildIndex > groups.count) self.memoryCyclePhase = 2;
}

- (void)zs_commitPendingMemoryColumns {
    if (self.memoryBuildSkipped || self.memoryPendingColumns.count == 0) return;
    [self zs_installMemoryColumns:self.memoryPendingColumns height:self.memoryBuildHeight groupColumnCount:self.memoryBuildGroupColumnCount];
}

- (void)zs_runMemoryUsageScan {
    __weak typeof(self) weakSelf = self;
    [self zs_pushMemoryFeed:@"Full scan · VM · IL2CPP · malloc"];
    zs_collect_memory_usage_breakdown(^(NSArray<ZSMemoryUsageGroup *> *groups) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.memoryFullScreenOpen) return;
        [strongSelf zs_pushMemoryFeed:@"task_info · host_statistics64 · sysctl"];
        ZSMemorySystemStats stats = zs_collect_memory_system_stats();
        [strongSelf zs_storeMemorySnapshotWithStats:stats rows:zs_memory_system_stat_rows(stats) groups:groups];
        [strongSelf zs_renderMemoryColumnsWithStats:stats groups:groups];
        [strongSelf zs_restartMemoryCycleKeepingPie:strongSelf.memoryCycleStart > 0];
    });
}

static void zs_memory_page_insets(UIView *overlay, CGFloat *leftOut, CGFloat *rightOut) {
    CGFloat logIndent = kZSSyslogFullScreenLeftInset + overlay.safeAreaInsets.left * 0.15;
    if (leftOut) *leftOut = MAX(0, logIndent - kZSMemoryColumnPadding);
    if (rightOut) *rightOut = overlay.safeAreaInsets.right * 0.15;
}

- (BOOL)zs_prepareMemoryBuildMetrics {
    UIScrollView *scrollView = self.memoryFullScreenScrollView;
    UIView *overlay = self.memoryFullScreenOverlay;
    if (!scrollView || !overlay) return NO;
    if (self.memoryPopupScrim) return NO;
    if (scrollView.isDragging || scrollView.isDecelerating) return NO;

    [overlay layoutIfNeeded];

    CGFloat height = scrollView.bounds.size.height;
    if (height < 80) {
        UIView *host = zs_ui_host_view();
        UIEdgeInsets hostInsets = host.safeAreaInsets;
        height = host.bounds.size.height - hostInsets.top - hostInsets.bottom - (kPanelPadding + 30 + 12);
    }
    if (height < 80) return NO;

    CGFloat pageWidth = scrollView.bounds.size.width > 1 ? scrollView.bounds.size.width : overlay.bounds.size.width;
    CGFloat leftInset = 0;
    CGFloat rightInset = 0;
    zs_memory_page_insets(overlay, &leftInset, &rightInset);
    self.memoryBuildHeight = height;
    self.memoryBuildPanelWidth = MAX(pageWidth - leftInset - rightInset, 0);
    return YES;
}

- (UIView *)zs_memoryColumnForGroup:(ZSMemoryUsageGroup *)group height:(CGFloat)height panelWidth:(CGFloat)panelWidth {
    __weak typeof(self) weakSelf = self;
    void (^onPageChange)(NSInteger) = ^(NSInteger delta) {
        [weakSelf zs_changeMemoryTopAssetsPageBy:delta];
    };
    void (^onFilterTap)(UIView *) = ^(UIView *source) {
        [weakSelf zs_presentMemoryKindPopupFromView:source group:group];
    };
    void (^onPageTap)(UIView *) = ^(UIView *source) {
        [weakSelf zs_presentMemoryPageNumpadFromView:source group:group];
    };
    NSString *pageKey = group.title ?: @"";
    NSUInteger localPage = [self.memoryLocalPages[pageKey] unsignedIntegerValue];
    void (^onLocalPageChange)(NSUInteger) = ^(NSUInteger page) {
        [weakSelf zs_setMemoryLocalPage:page forKey:pageKey];
    };
    return zs_build_memory_group_column(group, height, panelWidth, self.extendedCoverMode, localPage, onLocalPageChange, onPageChange, onFilterTap, onPageTap);
}

- (void)zs_setMemoryLocalPage:(NSUInteger)page forKey:(NSString *)key {
    if (!self.memoryLocalPages) self.memoryLocalPages = [NSMutableDictionary new];
    self.memoryLocalPages[key] = @(page);
    self.memoryPendingColumns = nil;
    NSArray<ZSMemoryUsageGroup *> *groups = self.memorySnapshotGroups;
    if (!groups) return;
    [self zs_renderMemoryColumnsWithStats:self.memorySnapshotStats groups:groups];
}

- (void)zs_renderMemoryColumnsWithStats:(ZSMemorySystemStats)stats groups:(NSArray<ZSMemoryUsageGroup *> *)groups {
    if (![self zs_prepareMemoryBuildMetrics]) return;

    CGFloat height = self.memoryBuildHeight;
    CGFloat panelWidth = self.memoryBuildPanelWidth;

    NSMutableArray<UIView *> *columns = [NSMutableArray array];
    UIView *statsColumn = zs_build_memory_column(@"System", nil, zs_memory_system_stat_rows(stats), nil, YES, 0, zs_memory_column_width(@"System", panelWidth, self.extendedCoverMode), height, NO, NULL, NULL);
    if (statsColumn) [columns addObject:statsColumn];

    NSUInteger groupColumnCount = 0;
    for (ZSMemoryUsageGroup *group in groups) {
        UIView *groupColumn = [self zs_memoryColumnForGroup:group height:height panelWidth:panelWidth];
        if (!groupColumn) continue;
        [columns addObject:groupColumn];
        groupColumnCount++;
    }

    [self zs_installMemoryColumns:columns height:height groupColumnCount:groupColumnCount];
}

- (void)zs_installMemoryColumns:(NSArray<UIView *> *)columns height:(CGFloat)height groupColumnCount:(NSUInteger)groupColumnCount {
    UIScrollView *scrollView = self.memoryFullScreenScrollView;
    UIView *overlay = self.memoryFullScreenOverlay;
    if (!scrollView || !overlay) return;
    if (self.memoryPopupScrim) return;
    if (scrollView.isDragging || scrollView.isDecelerating) return;

    CGFloat logIndent = kZSSyslogFullScreenLeftInset + overlay.safeAreaInsets.left * 0.15;
    self.memoryCloseButtonLeadingConstraint.constant = logIndent;

    self.memoryFullScreenStatusLabel.text = groupColumnCount > 0 ? nil : @"No trackable memory usage found";

    CGFloat pageWidth = scrollView.bounds.size.width > 1 ? scrollView.bounds.size.width : overlay.bounds.size.width;
    if (pageWidth < 1) return;

    CGFloat leftInset = 0;
    CGFloat rightInset = 0;
    zs_memory_page_insets(overlay, &leftInset, &rightInset);

    NSMutableDictionary<NSString *, UIView *> *columnsByTitle = [NSMutableDictionary dictionaryWithCapacity:columns.count];
    for (UIView *column in columns) {
        if (column.accessibilityIdentifier.length > 0) columnsByTitle[column.accessibilityIdentifier] = column;
    }

    UIView *contentView = [[UIView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;

    CGFloat hairline = 1.0 / MAX(overlay.traitCollection.displayScale, 1.0);
    NSUInteger pageCount = 0;
    CGRect infoPanelFrame = CGRectZero;
    if (!self.extendedCoverMode) {
        UIView *timerPageView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pageWidth, height)];
        timerPageView.backgroundColor = UIColor.clearColor;
        [contentView addSubview:timerPageView];
        infoPanelFrame = CGRectMake(leftInset, 0, MAX(pageWidth - leftInset - rightInset, 0), height);
        pageCount++;
    }
    for (NSArray<NSString *> *titles in zs_memory_page_titles(self.extendedCoverMode)) {
        NSMutableArray<UIView *> *pageColumns = [NSMutableArray arrayWithCapacity:titles.count];
        for (NSString *title in titles) {
            UIView *column = columnsByTitle[title];
            if (column) [pageColumns addObject:column];
        }
        if (pageColumns.count == 0) continue;

        UIView *pageView = [[UIView alloc] initWithFrame:CGRectMake(pageWidth * (CGFloat)pageCount, 0, pageWidth, height)];
        pageView.backgroundColor = UIColor.clearColor;
        [contentView addSubview:pageView];

        CGFloat x = leftInset;
        for (NSUInteger i = 0; i < pageColumns.count; i++) {
            UIView *column = pageColumns[i];
            CGRect frame = column.frame;
            frame.origin = CGPointMake(x, 0);
            column.frame = frame;
            [pageView addSubview:column];
            x += frame.size.width;

            BOOL hostsInfoPanel = self.extendedCoverMode && pageCount == 0 && pageColumns.count == 1 && [column.accessibilityIdentifier isEqualToString:@"System"];
            if (i + 1 < pageColumns.count || hostsInfoPanel) {
                UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(x, 0, hairline, height)];
                separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
                separator.userInteractionEnabled = NO;
                [pageView addSubview:separator];
            }
            if (hostsInfoPanel) {
                CGFloat panelX = x + hairline;
                infoPanelFrame = CGRectMake(panelX, 0, MAX(pageWidth - rightInset - panelX, 0), height);
            }
        }
        pageCount++;
    }

    CGFloat previousPageWidth = scrollView.bounds.size.width > 1 ? scrollView.bounds.size.width : pageWidth;
    NSInteger previousPage = (NSInteger)llround(scrollView.contentOffset.x / previousPageWidth);
    NSInteger targetPage = MAX(0, MIN(previousPage, (NSInteger)pageCount - 1));

    [self.memoryFullScreenContentView removeFromSuperview];
    [scrollView addSubview:contentView];
    self.memoryFullScreenContentView = contentView;

    [NSLayoutConstraint activateConstraints:@[
        [contentView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [contentView.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [contentView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [contentView.widthAnchor constraintEqualToConstant:pageWidth * (CGFloat)MAX(pageCount, (NSUInteger)1)],
        [contentView.heightAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.heightAnchor],
    ]];

    [scrollView layoutIfNeeded];
    scrollView.contentOffset = CGPointMake(pageWidth * (CGFloat)targetPage, 0);

    self.memoryPageControl.numberOfPages = pageCount;
    self.memoryPageControl.currentPage = targetPage;

    if (!CGRectIsEmpty(infoPanelFrame)) {
        self.memoryInfoPanel.hidden = NO;
        [scrollView bringSubviewToFront:self.memoryInfoPanel];
        [self zs_layoutMemoryInfoPanelInFrame:infoPanelFrame];
    } else {
        self.memoryInfoPanel.hidden = YES;
    }
    [self zs_updateMemoryHeaderPieAlpha];
}

- (void)zs_updateMemoryHeaderPieAlpha {
    UIScrollView *scrollView = self.memoryFullScreenScrollView;
    UIView *pie = self.memoryRefreshPieView;
    if (!pie) return;
    if (self.memoryInfoPanel.hidden || !scrollView || scrollView.bounds.size.width < 1) {
        pie.alpha = 1;
        return;
    }
    CGFloat progress = scrollView.contentOffset.x / (scrollView.bounds.size.width * 0.6);
    pie.alpha = MAX(0, MIN(1, progress));
}

- (void)zs_memoryPageControlChanged:(UIPageControl *)control {
    UIScrollView *scrollView = self.memoryFullScreenScrollView;
    if (!scrollView || scrollView.bounds.size.width < 1) return;
    [scrollView setContentOffset:CGPointMake(scrollView.bounds.size.width * (CGFloat)control.currentPage, 0) animated:YES];
}

- (void)zs_exportMemchartTapped {
    if (!self.memoryHasSnapshot) {
        UINotificationFeedbackGenerator *warning = [UINotificationFeedbackGenerator new];
        [warning notificationOccurred:UINotificationFeedbackTypeWarning];
        return;
    }

    NSDictionary *document = zs_memchart_export_document(self.memorySnapshotStats,
                                                         self.memorySnapshotSystemRows,
                                                         self.memorySnapshotGroups,
                                                         self.memorySnapshotDate ?: [NSDate date]);
    NSError *error = nil;
    NSJSONWritingOptions options = NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes;
    NSData *data = [NSJSONSerialization dataWithJSONObject:document options:options error:&error];
    if (!data) {
        ZLog(@"[UserInterface] Memchart export: JSON serialization failed: %@", error);
        return;
    }

    NSDateFormatter *nameFormatter = [[NSDateFormatter alloc] init];
    nameFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    nameFormatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *fileName = [NSString stringWithFormat:@"Memchart-%@.json", [nameFormatter stringFromDate:self.memorySnapshotDate ?: [NSDate date]]];
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
    if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) {
        ZLog(@"[UserInterface] Memchart export: couldn't write %@: %@", fileName, error);
        return;
    }

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
    activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        [NSFileManager.defaultManager removeItemAtURL:fileURL error:nil];
    };
    activityVC.popoverPresentationController.sourceView = self.memoryExportButton;
    activityVC.popoverPresentationController.sourceRect = self.memoryExportButton.bounds;

    UIViewController *presenter = zs_key_window().rootViewController;
    [presenter presentViewController:activityVC animated:YES completion:nil];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if (textField == self.syslogBlacklistField) {
        [self zs_presentSyslogBlacklistEditor];
        return NO;
    }
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    if (textField == self.syslogSearchField) {
        self.syslogCommandBrowseActive = NO;
        [self zs_updateSyslogCommandDropdown];
    }
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == self.syslogSearchField) {
        [self zs_updateSyslogCommandDropdown];
        return;
    }
    if (textField == self.zsFloatingField) {

        [self zs_commitFloatingField];
        return;
    }
}

#pragma mark Syslog blacklist

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.zsFloatingField) {

        [textField resignFirstResponder];
        return YES;
    }
    if (textField == self.syslogSearchField || textField == self.assetExplorerSearchField) {
        [textField resignFirstResponder];
        if (textField == self.syslogSearchField) [self zs_executeSyslogCommandIfNeeded];
        return YES;
    }
    if (textField != self.syslogBlacklistField) return YES;

    NSString *raw = textField.text ?: @"";
    textField.text = @"";
    [self zs_applySyslogBlacklistInput:raw];
    [textField resignFirstResponder];
    return YES;
}

- (void)zs_presentSyslogBlacklistEditor {
    __weak typeof(self) weakSelf = self;
    [self zs_presentFloatingTextFieldWithInitialText:nil
                                          placeholder:@"add keyword(s)"
                                               secure:NO
                                             hintText:@"TIP: Separate entries with commas, (ie. ZSingularity, Glory-to-NCorp, 0xDEADBEEF)"
                                         resetHandler:nil
                                           completion:^(NSString * _Nullable trimmedText) {
        if (trimmedText.length == 0) return;
        [weakSelf zs_applySyslogBlacklistInput:trimmedText];
    }];
}

- (void)zs_applySyslogBlacklistInput:(NSString *)raw {
    BOOL added = NO;
    for (NSString *piece in [raw componentsSeparatedByString:@","]) {
        NSString *term = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
        if (term.length == 0) continue;
        if (![self.syslogBlacklist containsObject:term]) added = YES;
        [self.syslogBlacklist addObject:term];
    }

    if (added) {
        g_syslogBlacklist = self.syslogBlacklist.array;
        [self zs_rebuildSyslogBlacklistEntries];
        [self zs_scheduleSave];
        [self reapplySyslogBlacklistFilter];
        ZLog(@"[UserInterface] syslog blacklist updated, now %lu term(s)", (unsigned long)self.syslogBlacklist.count);
    }
}

- (void)zs_rebuildSyslogBlacklistEntries {
    if (!self.syslogBlacklistEntriesStack) return;

    for (UIView *view in self.syslogBlacklistEntriesStack.arrangedSubviews) {
        [self.syslogBlacklistEntriesStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (self.syslogBlacklist.count == 0) {
        self.syslogBlacklistStatusLabel.text = @"NO TERMS";
        return;
    }

    self.syslogBlacklistStatusLabel.text = self.syslogBlacklist.count == 1
        ? @"1 TERM"
        : [NSString stringWithFormat:@"%lu TERMS", (unsigned long)self.syslogBlacklist.count];

    for (NSString *term in self.syslogBlacklist) {
        [self.syslogBlacklistEntriesStack addArrangedSubview:
            zs_make_blacklist_entry_row(term, self, @selector(zs_removeBlacklistEntryTapped:))];
    }
}

- (void)zs_removeBlacklistEntryTapped:(UIButton *)sender {
    NSString *term = objc_getAssociatedObject(sender, "zs_blacklistTerm");
    if (!term) return;

    [self.syslogBlacklist removeObject:term];
    g_syslogBlacklist = self.syslogBlacklist.array;
    [self zs_rebuildSyslogBlacklistEntries];
    [self zs_scheduleSave];
}

- (void)reapplySyslogBlacklistFilter {
    NSArray<NSMutableArray<NSString *> *> *buffers = @[
        self.syslogChannelLines ?: [NSMutableArray array],
        self.debugChannelLines ?: [NSMutableArray array],
    ];
    BOOL changed = NO;
    for (NSMutableArray<NSString *> *buffer in buffers) {
        if (buffer.count == 0) continue;
        NSIndexSet *toRemove = [buffer indexesOfObjectsPassingTest:^BOOL(NSString *line, NSUInteger idx, BOOL *stop) {
            return [self zs_syslogLineIsBlacklisted:line];
        }];
        if (toRemove.count == 0) continue;
        [buffer removeObjectsAtIndexes:toRemove];
        changed = YES;
    }
    if (changed) [self zs_renderSyslogBuffer];
}

@end
