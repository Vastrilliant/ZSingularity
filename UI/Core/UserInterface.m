#import "UIInternal.h"

static const NSTimeInterval kSaveDebounceInterval = 0.4;

@implementation UserInterface

+ (instancetype)shared {
    static UserInterface *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [UserInterface new]; });
    return instance;
}

- (void)zs_bootstrapSyslogCaptureIfNeeded {
    if (self.syslogChannelLines) return;

    self.syslogChannelLines = [NSMutableArray array];
    self.debugChannelLines = [NSMutableArray array];
    self.syslogBlacklist = [NSMutableOrderedSet orderedSet];

    zs_ensure_settings_loaded_from_disk();
    for (NSString *term in g_syslogBlacklist) {
        [self.syslogBlacklist addObject:term];
    }

    __weak typeof(self) weakSelf = self;
    [ZSyslogController sharedController].linesHandler = ^(NSArray<NSString *> *lines) {
        [weakSelf appendSyslogLines:lines];
    };
    BOOL syslogCaptureStarted = [[ZSyslogController sharedController] start];
    if (!syslogCaptureStarted) {
        [self appendSyslogLine:@"[syslog] Unable to start stdout/stderr capture"];
    }
}

- (void)installIfNeeded {
    if (self.installed) return;
    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;

    ZLog(@"[UserInterface] installing gesture-based panel opener");
    self.installed = YES;

    [unityView setMultipleTouchEnabled:YES];
    unityView.exclusiveTouch = NO;
    zs_install_unity_touch_filter(unityView);

    UISwipeGestureRecognizer *openSwipe =
        [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(zs_handleOpenPanelGesture:)];
    openSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    openSwipe.numberOfTouchesRequired = 2;
    openSwipe.delegate = self;
    [unityView addGestureRecognizer:openSwipe];

    zs_gif_tint_set_disabled(zs_enkephalin_disabled_by_user());

    [ZCrashLogger reinstallHandlersIfNeeded];
    if (![self zs_presentCrashReportIfNeeded]) {
        [self zs_presentTutorialIfNeeded];
    }
    [self zs_refreshMetalTabs];
    [[ZSMetalTabs shared] setRamHudVisible:zs_ram_hud_enabled()];

    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(deviceOrientationChanged)
                                                  name:UIDeviceOrientationDidChangeNotification
                                                object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(zs_keyboardWillChangeFrame:)
                                                  name:UIKeyboardWillChangeFrameNotification
                                                object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(zs_pollAllActiveDoctorEntriesImmediately)
                                                  name:UIApplicationWillEnterForegroundNotification
                                                object:nil];
}

- (void)zs_handleOpenPanelGesture:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    if (self.crashReportPresented) return;
    if (self.tutorialPresented) {
        [self zs_flashTutorialGestureWarning];
        return;
    }
    [self openPanel];
}

- (void)zs_flashTutorialGestureWarning {
    if (!self.tutorialGestureWarningLabel) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(zs_hideTutorialGestureWarning) object:nil];
    self.tutorialGestureWarningLabel.hidden = NO;
    [UIView animateWithDuration:0.18 animations:^{
        self.tutorialGestureWarningLabel.alpha = 1;
    }];
    [self performSelector:@selector(zs_hideTutorialGestureWarning) withObject:nil afterDelay:1.6];
}

- (void)zs_hideTutorialGestureWarning {
    UILabel *label = self.tutorialGestureWarningLabel;
    [UIView animateWithDuration:0.18 animations:^{
        label.alpha = 0;
    } completion:^(BOOL finished) {
        label.hidden = YES;
    }];
}

- (void)zs_presentTutorialIfNeeded {
    if ((zs_tutorial_completed() && !zs_tutorial_override_completion_enabled()) || self.tutorialPresented) return;

    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;

    self.tutorialPresented = YES;
    self.tutorialCanDismiss = NO;

    UIView *overlay = [[UIView alloc] initWithFrame:unityView.bounds];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.userInteractionEnabled = YES;
    [unityView addSubview:overlay];
    zs_mark_host_owned(overlay);
    self.tutorialOverlay = overlay;
    zs_force_dark(overlay);

    UIView *panelHost;
    UIView *panel;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.userInteractionEnabled = YES;
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
    self.tutorialPanel = panel;

    UILabel *header = [[UILabel alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.textAlignment = NSTextAlignmentLeft;
    header.attributedText = zs_make_title_string(20.5, 27.5);
    [panelHost addSubview:header];

    UILabel *welcome = [[UILabel alloc] init];
    welcome.translatesAutoresizingMaskIntoConstraints = NO;
    welcome.text = @"Welcome to ZSingularity!";
    welcome.font = zs_mono_font(16, UIFontWeightBold);
    welcome.textColor = UIColor.whiteColor;
    welcome.numberOfLines = 1;
    [panelHost addSubview:welcome];

    UITextView *body = [[UITextView alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.backgroundColor = UIColor.clearColor;
    body.opaque = NO;
    body.editable = NO;
    body.selectable = NO;
    body.scrollEnabled = NO;
    body.textContainerInset = UIEdgeInsetsZero;
    body.textContainer.lineFragmentPadding = 0;
    body.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    body.font = zs_mono_font(12, UIFontWeightRegular);
    body.userInteractionEnabled = NO;

    NSMutableAttributedString *bodyText = [[NSMutableAttributedString alloc] initWithString:@"To get started, click and hold the screen with two of your fingers, then swipe left to open the menu.\n\nAlso make sure to read the documentation of each setting by clicking the " attributes:@{
        NSFontAttributeName: zs_mono_font(12, UIFontWeightRegular),
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.72]
    }];

    UIImageSymbolConfiguration *infoConfig = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightRegular];
    UIImage *infoImage = [UIImage systemImageNamed:@"info.circle" withConfiguration:infoConfig];
    if (infoImage) {
        NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
        attachment.image = [infoImage imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.6]];
        attachment.bounds = CGRectMake(0, -2, 12, 12);
        [bodyText appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
        [bodyText appendAttributedString:[[NSAttributedString alloc] initWithString:@" icon next to each section.\n\nJoin the Discord Server if you want to report a bug, suggest new features or need some help." attributes:@{
            NSFontAttributeName: zs_mono_font(12, UIFontWeightRegular),
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.72]
        }]];
    } else {
        [bodyText appendAttributedString:[[NSAttributedString alloc] initWithString:@"info.circle icon next to each section." attributes:@{
            NSFontAttributeName: zs_mono_font(12, UIFontWeightRegular),
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.72]
        }]];
    }
    body.attributedText = bodyText;
    [panelHost addSubview:body];

    UIButton *discord = [UIButton buttonWithType:UIButtonTypeSystem];
    discord.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_social_text_button(discord, @"Discord Server");
    [discord addTarget:self action:@selector(zs_tutorialDiscordTapped) forControlEvents:UIControlEventTouchUpInside];
    [panelHost addSubview:discord];

    UIButton *github = [UIButton buttonWithType:UIButtonTypeSystem];
    github.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_social_text_button(github, @"GitHub Repository");
    [github addTarget:self action:@selector(zs_tutorialGitHubTapped) forControlEvents:UIControlEventTouchUpInside];
    [panelHost addSubview:github];

    self.tutorialGestureWarningLabel = [[UILabel alloc] init];
    self.tutorialGestureWarningLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.tutorialGestureWarningLabel.text = @"Close the tutorial UI first";
    self.tutorialGestureWarningLabel.font = zs_mono_font(kZSSubtitleFontSize, UIFontWeightMedium);
    self.tutorialGestureWarningLabel.textColor = UIColor.systemRedColor;
    self.tutorialGestureWarningLabel.numberOfLines = 1;
    self.tutorialGestureWarningLabel.alpha = 0;
    self.tutorialGestureWarningLabel.hidden = YES;
    [panelHost addSubview:self.tutorialGestureWarningLabel];

    self.tutorialOKButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.tutorialOKButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_solid_glass_with_font(self.tutorialOKButton, @"OK", zs_accent_green_color(), zs_mono_font(18, UIFontWeightBold));
    self.tutorialOKButton.enabled = NO;
    self.tutorialOKButton.alpha = 0.38;
    [self.tutorialOKButton addTarget:self action:@selector(zs_tutorialOKTapped) forControlEvents:UIControlEventTouchUpInside];
    [panelHost addSubview:self.tutorialOKButton];

    CGFloat panelWidth = MIN(440.0, MAX(300.0, unityView.bounds.size.width - 32.0));
    CGFloat panelHeight = MIN(390.0, MAX(320.0, unityView.bounds.size.height - 48.0));

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.widthAnchor constraintEqualToConstant:panelWidth],
        [panel.heightAnchor constraintEqualToConstant:panelHeight],

        [header.topAnchor constraintEqualToAnchor:panelHost.topAnchor constant:18],
        [header.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:20],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:panelHost.trailingAnchor constant:-20],
        [header.heightAnchor constraintEqualToConstant:34],

        [welcome.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:22],
        [welcome.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [welcome.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:18],

        [body.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:22],
        [body.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [body.topAnchor constraintEqualToAnchor:welcome.bottomAnchor constant:18],

        [discord.trailingAnchor constraintEqualToAnchor:github.leadingAnchor constant:-16],
        [github.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [discord.bottomAnchor constraintEqualToAnchor:self.tutorialOKButton.topAnchor constant:-12],
        [github.bottomAnchor constraintEqualToAnchor:self.tutorialOKButton.topAnchor constant:-12],
        [discord.heightAnchor constraintEqualToConstant:24],
        [github.heightAnchor constraintEqualToConstant:24],

        [self.tutorialGestureWarningLabel.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:22],
        [self.tutorialGestureWarningLabel.trailingAnchor constraintLessThanOrEqualToAnchor:discord.leadingAnchor constant:-8],
        [self.tutorialGestureWarningLabel.centerYAnchor constraintEqualToAnchor:discord.centerYAnchor],

        [self.tutorialOKButton.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:22],
        [self.tutorialOKButton.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [self.tutorialOKButton.bottomAnchor constraintEqualToAnchor:panelHost.bottomAnchor constant:-20],
        [self.tutorialOKButton.heightAnchor constraintEqualToConstant:46],
    ]];

    panel.alpha = 0;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.22 animations:^{
        panel.alpha = 1;
        panel.transform = CGAffineTransformIdentity;
    }];

    self.tutorialUnlockTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(zs_tutorialUnlock) userInfo:nil repeats:NO];
}

- (void)zs_tutorialUnlock {
    self.tutorialUnlockTimer = nil;
    self.tutorialCanDismiss = YES;
    self.tutorialOKButton.enabled = YES;
    [UIView animateWithDuration:0.18 animations:^{
        self.tutorialOKButton.alpha = 1.0;
    }];
}

- (void)zs_tutorialDiscordTapped {
    NSURL *url = [NSURL URLWithString:kZSSocialDiscordURL];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)zs_tutorialGitHubTapped {
    NSURL *url = [NSURL URLWithString:kZSSocialGitHubURL];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)zs_tutorialOKTapped {
    if (!self.tutorialCanDismiss) return;

    zs_set_tutorial_completed(YES);
    [self.tutorialUnlockTimer invalidate];
    self.tutorialUnlockTimer = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(zs_hideTutorialGestureWarning) object:nil];

    UIView *panel = self.tutorialPanel;
    UIView *overlay = self.tutorialOverlay;
    self.tutorialPanel = nil;
    self.tutorialOverlay = nil;
    self.tutorialOKButton = nil;
    self.tutorialGestureWarningLabel = nil;
    self.tutorialPresented = NO;
    [self zs_refreshMetalTabs];

    [UIView animateWithDuration:0.18 animations:^{
        panel.alpha = 0;
        panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)zs_layoutTutorialForWindow:(UIView *)unityView {
    if (!self.tutorialOverlay || !self.tutorialPanel) return;
    self.tutorialOverlay.frame = unityView.bounds;
}

- (void)zs_layoutCrashReportForWindow:(UIView *)unityView {
    if (!self.crashOverlay || !self.crashPanel) return;
    self.crashOverlay.frame = unityView.bounds;
}

- (BOOL)zs_presentCrashReportIfNeeded {
    if (self.crashReportPresented) return YES;

    NSDictionary *report = [ZCrashLogger pendingCrashReport];
    if (!report) return NO;

    UIView *unityView = zs_ui_host_view();
    if (!unityView) return NO;

    self.crashReport = report;
    self.crashReportPresented = YES;

    UIView *overlay = [[UIView alloc] initWithFrame:unityView.bounds];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.userInteractionEnabled = YES;
    [unityView addSubview:overlay];
    zs_mark_host_owned(overlay);
    self.crashOverlay = overlay;
    zs_force_dark(overlay);

    UIView *panelHost;
    UIView *panel;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.userInteractionEnabled = YES;
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
    self.crashPanel = panel;

    UILabel *header = [[UILabel alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.textAlignment = NSTextAlignmentLeft;
    header.attributedText = zs_make_title_string(20.5, 27.5);
    [panelHost addSubview:header];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = [NSString stringWithFormat:@"EXC_CRASH: %@", report[@"signal"]];
    titleLabel.font = zs_mono_font(16, UIFontWeightBold);
    titleLabel.textColor = UIColor.systemRedColor;
    titleLabel.numberOfLines = 1;
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.6;
    [panelHost addSubview:titleLabel];

    NSDictionary *messageAttributes = @{
        NSFontAttributeName: zs_mono_font(12, UIFontWeightRegular),
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.72]
    };
    NSMutableAttributedString *messageText = [[NSMutableAttributedString alloc] initWithString:@"It looks like ZSingularity crashed, please report it to the " attributes:messageAttributes];
    [messageText appendAttributedString:[[NSAttributedString alloc] initWithString:@"Discord Server" attributes:@{
        NSFontAttributeName: zs_mono_font(12, UIFontWeightBold),
        NSLinkAttributeName: [NSURL URLWithString:kZSSocialDiscordURL],
        NSBackgroundColorAttributeName: [zs_accent_green_color() colorWithAlphaComponent:0.18]
    }]];
    [messageText appendAttributedString:[[NSAttributedString alloc] initWithString:@"." attributes:messageAttributes]];

    UITextView *message = [[UITextView alloc] init];
    message.translatesAutoresizingMaskIntoConstraints = NO;
    message.tag = kZSCrashMessageTextViewTag;
    message.backgroundColor = UIColor.clearColor;
    message.opaque = NO;
    message.editable = NO;
    message.selectable = YES;
    message.scrollEnabled = NO;
    message.textContainerInset = UIEdgeInsetsZero;
    message.textContainer.lineFragmentPadding = 0;
    message.delegate = self;
    message.linkTextAttributes = @{
        NSForegroundColorAttributeName: zs_accent_green_color(),
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
    };
    message.attributedText = messageText;
    [panelHost addSubview:message];

    UILabel *traceCaption = [[UILabel alloc] init];
    traceCaption.translatesAutoresizingMaskIntoConstraints = NO;
    traceCaption.text = @"Stack Trace:";
    traceCaption.font = zs_mono_font(12, UIFontWeightSemibold);
    traceCaption.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    [panelHost addSubview:traceCaption];

    UIView *traceBox = [[UIView alloc] init];
    traceBox.translatesAutoresizingMaskIntoConstraints = NO;
    traceBox.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    traceBox.layer.cornerRadius = 12;
    traceBox.layer.cornerCurve = kCACornerCurveContinuous;
    traceBox.layer.borderWidth = 1;
    traceBox.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.1].CGColor;
    traceBox.clipsToBounds = YES;
    [panelHost addSubview:traceBox];

    UITextView *traceView = [[UITextView alloc] init];
    traceView.translatesAutoresizingMaskIntoConstraints = NO;
    traceView.backgroundColor = UIColor.clearColor;
    traceView.editable = NO;
    traceView.selectable = YES;
    traceView.scrollEnabled = YES;
    traceView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    traceView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    traceView.textContainer.lineFragmentPadding = 0;
    traceView.font = zs_mono_font(9.5, UIFontWeightRegular);
    traceView.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    traceView.text = report[@"trace"];
    [traceBox addSubview:traceView];

    UIButton *okButton = [UIButton buttonWithType:UIButtonTypeSystem];
    okButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_solid_glass_with_font(okButton, @"OK", zs_accent_green_color(), zs_mono_font(18, UIFontWeightBold));
    [okButton addTarget:self action:@selector(zs_crashOKTapped) forControlEvents:UIControlEventTouchUpInside];
    [panelHost addSubview:okButton];

    UIButton *saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_solid_glass_with_font(saveButton, @"Save trace stack", UIColor.systemBlueColor, zs_mono_font(14, UIFontWeightBold));
    [saveButton addTarget:self action:@selector(zs_crashSaveTapped:) forControlEvents:UIControlEventTouchUpInside];
    [panelHost addSubview:saveButton];

    UILayoutGuide *leftColumn = [[UILayoutGuide alloc] init];
    [panelHost addLayoutGuide:leftColumn];

    NSLayoutConstraint *preferredWidth = [panel.widthAnchor constraintEqualToAnchor:overlay.widthAnchor constant:-32];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *preferredHeight = [panel.heightAnchor constraintEqualToConstant:340];
    preferredHeight.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.widthAnchor constraintLessThanOrEqualToConstant:780],
        [panel.heightAnchor constraintLessThanOrEqualToConstant:340],
        [panel.topAnchor constraintGreaterThanOrEqualToAnchor:overlay.topAnchor constant:24],
        [panel.bottomAnchor constraintLessThanOrEqualToAnchor:overlay.bottomAnchor constant:-24],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:16],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-16],
        preferredWidth,
        preferredHeight,

        [leftColumn.leadingAnchor constraintEqualToAnchor:panelHost.leadingAnchor constant:22],
        [leftColumn.topAnchor constraintEqualToAnchor:panelHost.topAnchor],
        [leftColumn.bottomAnchor constraintEqualToAnchor:panelHost.bottomAnchor],
        [leftColumn.widthAnchor constraintEqualToAnchor:panelHost.widthAnchor multiplier:0.4],

        [header.topAnchor constraintEqualToAnchor:panelHost.topAnchor constant:18],
        [header.leadingAnchor constraintEqualToAnchor:leftColumn.leadingAnchor constant:-2],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:leftColumn.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:34],

        [titleLabel.leadingAnchor constraintEqualToAnchor:leftColumn.leadingAnchor],
        [titleLabel.trailingAnchor constraintEqualToAnchor:leftColumn.trailingAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14],

        [message.leadingAnchor constraintEqualToAnchor:leftColumn.leadingAnchor],
        [message.trailingAnchor constraintEqualToAnchor:leftColumn.trailingAnchor],
        [message.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [message.bottomAnchor constraintLessThanOrEqualToAnchor:okButton.topAnchor constant:-12],

        [okButton.leadingAnchor constraintEqualToAnchor:leftColumn.leadingAnchor],
        [okButton.widthAnchor constraintEqualToAnchor:leftColumn.widthAnchor multiplier:0.32],
        [okButton.bottomAnchor constraintEqualToAnchor:panelHost.bottomAnchor constant:-20],
        [okButton.heightAnchor constraintEqualToConstant:46],

        [saveButton.leadingAnchor constraintEqualToAnchor:okButton.trailingAnchor constant:10],
        [saveButton.trailingAnchor constraintEqualToAnchor:leftColumn.trailingAnchor],
        [saveButton.bottomAnchor constraintEqualToAnchor:okButton.bottomAnchor],
        [saveButton.heightAnchor constraintEqualToAnchor:okButton.heightAnchor],

        [traceCaption.leadingAnchor constraintEqualToAnchor:leftColumn.trailingAnchor constant:22],
        [traceCaption.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [traceCaption.topAnchor constraintEqualToAnchor:panelHost.topAnchor constant:24],

        [traceBox.leadingAnchor constraintEqualToAnchor:traceCaption.leadingAnchor],
        [traceBox.trailingAnchor constraintEqualToAnchor:panelHost.trailingAnchor constant:-22],
        [traceBox.topAnchor constraintEqualToAnchor:traceCaption.bottomAnchor constant:8],
        [traceBox.bottomAnchor constraintEqualToAnchor:panelHost.bottomAnchor constant:-20],

        [traceView.leadingAnchor constraintEqualToAnchor:traceBox.leadingAnchor],
        [traceView.trailingAnchor constraintEqualToAnchor:traceBox.trailingAnchor],
        [traceView.topAnchor constraintEqualToAnchor:traceBox.topAnchor],
        [traceView.bottomAnchor constraintEqualToAnchor:traceBox.bottomAnchor],
    ]];

    panel.alpha = 0;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.22 animations:^{
        panel.alpha = 1;
        panel.transform = CGAffineTransformIdentity;
    }];

    return YES;
}

- (void)zs_crashSaveTapped:(UIButton *)sender {
    NSDictionary *report = self.crashReport;
    NSString *fullReport = report[@"report"];
    if (fullReport.length == 0) return;

    NSTimeInterval timestamp = [report[@"timestamp"] doubleValue];
    NSDate *date = timestamp > 0 ? [NSDate dateWithTimeIntervalSince1970:timestamp] : [NSDate date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *fileName = [NSString stringWithFormat:@"ZSingularity-crash-%@.txt", [formatter stringFromDate:date]];

    NSString *directoryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath isDirectory:YES];
    NSURL *fileURL = [directoryURL URLByAppendingPathComponent:fileName];
    NSString *contents = [NSString stringWithFormat:@"EXC_CRASH: %@\n%@", report[@"signal"], fullReport];

    NSError *error = nil;
    BOOL wrote = [NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:&error]
        && [contents writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!wrote) {
        [self zs_presentModsAlertWithTitle:@"Save Failed" message:error.localizedDescription ?: @"Couldn't write the crash report."];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) {
        [NSFileManager.defaultManager removeItemAtURL:directoryURL error:nil];
        return;
    }

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
    activityVC.popoverPresentationController.sourceView = sender;
    activityVC.popoverPresentationController.sourceRect = sender.bounds;
    activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        [NSFileManager.defaultManager removeItemAtURL:directoryURL error:nil];
    };
    [presenter presentViewController:activityVC animated:YES completion:nil];
}

- (void)zs_crashOKTapped {
    [ZCrashLogger clearPendingCrashReport];

    UIView *panel = self.crashPanel;
    UIView *overlay = self.crashOverlay;
    self.crashPanel = nil;
    self.crashOverlay = nil;
    self.crashReport = nil;
    self.crashReportPresented = NO;

    [self zs_presentTutorialIfNeeded];
    [self zs_refreshMetalTabs];

    [UIView animateWithDuration:0.18 animations:^{
        panel.alpha = 0;
        panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)openPanel {
    if (self.panelOpen) return;
    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;

    BOOL fromTabs = [[ZSMetalTabs shared] isVisible] && [[self zs_pinnedKeys] containsObject:kZSMTHandleKey];
    CGFloat tabInset = fromTabs ? kHandleWidth : 0;
    self.panelOpen = YES;
    [[ZSMetalTabs shared] setVisible:NO snap:NO];
    [self buildPanel:unityView];
    zs_reapply_all_settings();

    CGRect restingFrame = self.glassContainer.frame;
    CGFloat offscreenDeltaX = unityView.bounds.size.width - tabInset - restingFrame.origin.x;

    CGRect contentOverlayRestingFrame = self.contentOverlay.frame;
    self.contentOverlay.frame = CGRectOffset(contentOverlayRestingFrame, offscreenDeltaX, 0);

    BOOL extendedVisible = self.extendedContentClip && !self.extendedContentClip.hidden;
    CGRect extendedRestingFrame = extendedVisible ? self.extendedContentClip.frame : CGRectZero;
    if (extendedVisible) {
        self.extendedContentClip.frame = CGRectOffset(extendedRestingFrame, offscreenDeltaX, 0);
    }

    UIView *handleElement = self.handleGlass ?: self.handle;
    CGRect handleRestingFrame = handleElement.frame;
    handleElement.frame = CGRectMake(handleRestingFrame.origin.x + (fromTabs ? 0 : kHandleWidth),
                                      handleRestingFrame.origin.y,
                                      handleRestingFrame.size.width,
                                      handleRestingFrame.size.height);

    NSMutableDictionary<NSString *, NSValue *> *pinnedRestingFrames = [NSMutableDictionary dictionary];
    for (NSString *pinKey in self.pinnedTabElements) {
        UIView *pinnedElement = self.pinnedTabElements[pinKey];
        pinnedRestingFrames[pinKey] = [NSValue valueWithCGRect:pinnedElement.frame];
        pinnedElement.frame = CGRectOffset(pinnedElement.frame, fromTabs ? 0 : kHandleWidth, 0);
    }

    self.glassContainer.frame = CGRectMake(unityView.bounds.size.width - tabInset,
                                            restingFrame.origin.y,
                                            restingFrame.size.width,
                                            restingFrame.size.height);

    [unityView layoutIfNeeded];
    self.glassContainer.hidden = NO;
    self.contentOverlay.hidden = NO;

    [[FPS120Controller shared] setPanelOpen:YES];
    zs_set_glass_suspended(NO);
    zs_gif_tint_set_paused(NO);
    zs_logo_effects_set_paused(NO);
    zs_gif_tint_reconstruct_all();
    [self zs_updateSliderGlassVisibility];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        weakSelf.glassContainer.frame = restingFrame;
        weakSelf.contentOverlay.frame = contentOverlayRestingFrame;
        if (extendedVisible) weakSelf.extendedContentClip.frame = extendedRestingFrame;
        handleElement.frame = handleRestingFrame;
        for (NSString *pinKey in pinnedRestingFrames) {
            weakSelf.pinnedTabElements[pinKey].frame = pinnedRestingFrames[pinKey].CGRectValue;
        }
    } completion:^(BOOL finished) {
        [weakSelf zs_pollAllActiveDoctorEntriesImmediately];
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *v = zs_ui_host_view();
        if (v && weakSelf.panel) [weakSelf layoutPanelForWindow:v];
        [weakSelf zs_fillVisiblePanelSectionsWithHeadroom];
    });
}

- (void)closePanel {
    [self closePanelAnimated:YES];
}

- (void)closePanelAnimated:(BOOL)animated {
    if (!self.panelOpen || !self.glassContainer) return;
    UIView *unityView = zs_ui_host_view();

    [self zs_closeLogoDropdownAnimated:NO];
    self.panelOpen = NO;
    self.docsPanelOpen = NO;
    self.docsActiveKey = nil;
    self.syslogFullScreenOpen = NO;
    self.assetExplorerFullScreenOpen = NO;
    [self zs_syncSyslogButtonState];
    [self zs_endMemoryAnalysis];
    [self zs_dismissPinMenuAnimated:NO delay:0 completion:nil];

    if (self.zsFloatingField) [self zs_commitFloatingFieldSaving:NO];

    [[FPS120Controller shared] setPanelOpen:NO];
    zs_set_glass_suspended(YES);
    zs_gif_tint_set_paused(YES);
    zs_logo_effects_set_paused(YES);
    zs_gif_tint_teardown_all();
    [self stopPostFXReapply];

    if (!unityView) {
        [self teardownPanelState];
        return;
    }

    if (!animated) {
        [self teardownPanelState];
        [self zs_syncMetalTabsAllowingHierarchy:YES snap:NO];
        return;
    }

    UIView *closingContainer = self.glassContainer;

    CGRect offscreenFrame = CGRectMake(unityView.bounds.size.width,
                                        self.glassContainer.frame.origin.y,
                                        self.glassContainer.frame.size.width,
                                        self.glassContainer.frame.size.height);

    CGFloat offscreenDeltaX = offscreenFrame.origin.x - self.glassContainer.frame.origin.x;

    CGRect contentOverlayOffscreenFrame = CGRectOffset(self.contentOverlay.frame, offscreenDeltaX, 0);

    BOOL extendedVisible = self.extendedContentClip && !self.extendedContentClip.hidden;
    CGRect extendedOffscreenFrame = extendedVisible ? CGRectOffset(self.extendedContentClip.frame, offscreenDeltaX, 0) : CGRectZero;

    UIView *handleElement = self.handleGlass ?: self.handle;
    CGRect handleRetractedFrame = CGRectMake(handleElement.frame.origin.x + kHandleWidth,
                                              handleElement.frame.origin.y,
                                              handleElement.frame.size.width,
                                              handleElement.frame.size.height);

    NSMutableDictionary<NSString *, NSValue *> *pinnedRetractedFrames = [NSMutableDictionary dictionary];
    for (NSString *pinKey in self.pinnedTabElements) {
        pinnedRetractedFrames[pinKey] = [NSValue valueWithCGRect:CGRectOffset(self.pinnedTabElements[pinKey].frame, kHandleWidth, 0)];
    }

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        for (NSString *pinKey in pinnedRetractedFrames) {
            weakSelf.pinnedTabElements[pinKey].frame = pinnedRetractedFrames[pinKey].CGRectValue;
        }
        weakSelf.glassContainer.frame = offscreenFrame;
        weakSelf.contentOverlay.frame = contentOverlayOffscreenFrame;
        if (extendedVisible) weakSelf.extendedContentClip.frame = extendedOffscreenFrame;
        handleElement.frame = handleRetractedFrame;
    } completion:^(BOOL finished) {
        if (weakSelf.panelOpen || weakSelf.glassContainer != closingContainer) return;
        [weakSelf teardownPanelState];
        [weakSelf zs_syncMetalTabsAllowingHierarchy:YES snap:NO];
    }];
}

- (void)teardownPanelState {
    [self.postFXReapplyTimer invalidate];
    self.postFXReapplyTimer = nil;

    if (self.saveDebounceTimer) {
        [self.saveDebounceTimer invalidate];
        self.saveDebounceTimer = nil;
        zs_persist_current_settings();
    }

    [self.holdConfirmDisplayLink invalidate];
    self.holdConfirmDisplayLink = nil;
    self.holdConfirmActiveButton = nil;
    self.holdConfirmTriggered = NO;
    self.holdConfirmStartTime = 0;

    self.syslogDebugModeEnabled = NO;
    self.syslogFullScreenOpen = NO;
    [self.syslogInfoRefreshTimer invalidate];
    self.syslogInfoRefreshTimer = nil;
    self.memoryFullScreenOpen = NO;

    for (NSTimer *timer in self.doctorPollTimers.allValues) {
        [timer invalidate];
    }
    self.doctorPollTimers = nil;
    self.doctorUploadProgressLastUpdate = nil;
    self.doctorProcessProgressLastPercent = nil;
    self.doctorDownloadProgressLastUpdate = nil;
    self.doctorDownloadProgressPersistLastUpdate = nil;
    self.doctorDownloadLiveEntryCache = nil;
    self.doctorDownloadInFlightPaths = nil;
    self.doctorInstallTargetPicker = nil;
    self.doctorInstallPendingDoctoredURL = nil;
    self.doctorInstallPendingEntryPath = nil;
    self.doctorInstallPendingFolderName = nil;

    [self destroyPanelHierarchy];
}

- (void)destroyPanelHierarchy {
    [self.tutorialUnlockTimer invalidate];
    self.tutorialUnlockTimer = nil;
    [self.tutorialOverlay removeFromSuperview];
    self.tutorialOverlay = nil;
    self.tutorialPanel = nil;
    self.tutorialOKButton = nil;
    self.tutorialPresented = NO;
    self.tutorialCanDismiss = NO;
    [self.glassContainer removeFromSuperview];
    [self.contentOverlay removeFromSuperview];
    [self.docsContentOverlay removeFromSuperview];
    [self.extendedContentClip removeFromSuperview];
    self.extendedContentClip = nil;
    self.panelLeftCornersFlat = NO;

    [self.pinMenuScrim removeFromSuperview];
    self.pinMenuScrim = nil;
    self.pinMenuContent = nil;
    self.pinMenuOpen = NO;
    self.pinMenuTransitioning = NO;
    self.pinMenuExtraWidth = 0;
    self.pinnedTabElements = nil;
    self.pinRecenterPending = NO;
    self.pinRecenterToken = self.pinRecenterToken + 1;
    self.panelFullScreenLayoutActive = NO;
    self.extendedCoverMode = NO;
    self.extendedCoverEntering = NO;

    self.glassContainer = nil;
    self.panelGlass = nil;
    self.handleGlass = nil;
    self.contentOverlay = nil;
    self.glassContainerContent = nil;
    self.panel = nil;
    self.handle = nil;
    self.chevron = nil;
    self.scrollViewport = nil;
    self.scrollView = nil;
    self.stack = nil;
    self.experimentalSectionContainer = nil;
    self.pendingSectionBuilders = nil;
    self.pendingExperimentalSectionBuilders = nil;
    self.pendingCollapsedStates = nil;
    self.developerSectionViews = nil;
    self.sectionIndexView = nil;
    self.sectionIndexSectionNames = nil;

    self.docsPanelGlass = nil;
    self.docsPanel = nil;
    self.docsContentOverlay = nil;
    self.docsPanelSeparator = nil;
    self.docsScrollView = nil;
    self.docsTitleLabel = nil;
    self.docsHeaderModeChevronButton = nil;
    self.docsLanguageButton = nil;
    self.docsLanguageDropdownOverlay = nil;
    self.docsLanguageDropdownScrim = nil;
    self.docsLanguageDropdownOpen = NO;
    self.logoChevronButton = nil;
    self.logoDropdownOverlay = nil;
    self.logoDropdownScrim = nil;
    self.logoDropdownOpen = NO;
    self.logoDropdownNames = nil;
    self.docsTitleTrailingFullConstraint = nil;
    self.docsTitleTrailingToChevronConstraint = nil;
    self.docsTitleTrailingToLanguageConstraint = nil;
    self.docsSubheaderRow = nil;
    self.docsSubheaderLabel = nil;
    self.docsSubheaderPageGroup = nil;
    self.docsSubheaderPageLabel = nil;
    self.docsSubheaderLeftArrowButton = nil;
    self.docsSubheaderRightArrowButton = nil;
    self.docsScrollViewTopToTitleConstraint = nil;
    self.docsScrollViewTopToSubheaderConstraint = nil;
    self.docsBodyLabel = nil;
    self.docsUpdateActionsStack = nil;
    self.docsUpdateActionsSpacer = nil;
    self.docsLiveContainerInstallButton = nil;
    self.docsGitHubReleaseLinkButton = nil;
    self.docsUpdateActionsDisabledNoteLabel = nil;
    self.docsScrollViewBottomToOverlayConstraint = nil;

    self.syslogBlacklistField = nil;
    self.syslogBlacklistStatusLabel = nil;
    self.syslogBlacklistEntriesStack = nil;
    self.syslogButton = nil;

    [self.syslogFullScreenOverlay removeFromSuperview];
    self.syslogFullScreenOverlay = nil;
    self.syslogSearchField = nil;
    self.syslogCommandDropdown = nil;
    self.syslogSlashButton = nil;
    self.syslogCommandBrowseActive = NO;
    self.syslogCommandStack = nil;
    self.syslogExportButton = nil;
    self.syslogChannelToggleButton = nil;
    self.syslogInfoLabel = nil;
    self.syslogFullScreenScrollView = nil;
    self.syslogCloseButtonLeadingConstraint = nil;
    self.syslogTableView = nil;
    self.syslogTableController = nil;
    self.syslogEmptyLabel = nil;
    self.syslogRenderScheduled = NO;
    self.syslogRenderDeferred = NO;
    self.syslogCopyToastView = nil;

    self.customGreetingRow = nil;

    self.modsOptionsDropdownOverlay = nil;
    self.modsOptionsDropdownScrim = nil;
    self.modsOptionsDropdownOpen = NO;
    self.modsOptionsDropdownEntry = nil;
    self.modsOptionsDropdownFolderName = nil;

    self.modsLibraryStack = nil;
    self.manifestZeroingRow = nil;

    self.zsFloatingFieldBackdrop = nil;
    self.zsFloatingFieldContainer = nil;
    self.zsFloatingFieldButtonRow = nil;
    self.zsFloatingFieldHintLabel = nil;
    self.zsFloatingFieldResetHandler = nil;
    self.zsFloatingField = nil;

    self.normalFpsSlider = nil;
    self.normalFpsValueLabel = nil;
    self.combatFpsSlider = nil;
    self.combatFpsValueLabel = nil;

    self.updateStatusLabel = nil;
    self.updateStatusDot = nil;

    self.browseCategoryButton = nil;
    self.browseClassButton = nil;
    self.browseFieldsContainer = nil;

    self.memoryUsageAnalyzeButton = nil;
    [self zs_assetExplorerLocalizeReset];
    [self.assetExplorerFullScreenOverlay removeFromSuperview];
    self.assetExplorerFullScreenOverlay = nil;
    self.assetExplorerLocalizeTableView = nil;
    self.assetExplorerLocalizeJSONTableView = nil;
    self.assetExplorerTableView = nil;
    [self.assetExplorerThumbSource reset];
    self.assetExplorerThumbSource = nil;
    self.assetExplorerThumbCollectionView = nil;
    self.assetExplorerViewModeButton = nil;
    self.assetExplorerThumbnailMode = NO;
    self.assetExplorerFMODTableView = nil;
    self.assetExplorerHubView = nil;
    self.assetExplorerHubVisible = NO;
    self.assetExplorerFMODMode = NO;
    self.assetExplorerFMODGeneration += 1;
    self.assetExplorerFMODBankFile = nil;
    self.assetExplorerFMODBank = nil;
    self.assetExplorerFMODStream = nil;
    self.assetExplorerFMODBankFiles = nil;
    self.assetExplorerFMODDisplayedBanks = nil;
    self.assetExplorerFMODDisplayedStreams = nil;
    self.assetExplorerTitleLabel = nil;
    self.assetExplorerStatusLabel = nil;
    self.assetExplorerBackButton = nil;
    self.assetExplorerCloseButton = nil;
    self.assetExplorerTextureOpen = NO;
    self.assetExplorerTextureBackButton = nil;
    self.assetExplorerTextureExportButton = nil;
    self.assetExplorerModeControl = nil;
    self.assetExplorerDataJSON = nil;
    self.assetExplorerDataMode = NO;
    self.assetExplorerTextureImageView = nil;
    self.assetExplorerPreviewClipView = nil;
    self.assetExplorerTextView = nil;
    self.assetExplorerTextureMessageLabel = nil;
    self.assetExplorerTextureCaptionLabel = nil;
    self.assetExplorerDebugLabel = nil;
    self.assetExplorerTextureSpinner = nil;
    self.assetExplorerBundles = nil;
    self.assetExplorerAssets = nil;
    self.assetExplorerDisplayedBundles = nil;
    self.assetExplorerDisplayedAssets = nil;
    self.assetExplorerBackdropView = nil;
    self.assetExplorerSearchContainer = nil;
    self.assetExplorerSearchField = nil;
    self.assetExplorerControlsStack = nil;
    self.assetExplorerFilterButton = nil;
    self.assetExplorerSortButton = nil;
    self.assetExplorerShareButton = nil;
    self.assetExplorerFilterKind = nil;
    self.assetExplorerSortKind = nil;
    self.assetExplorerSortBySize = NO;
    self.assetExplorerSizeAscending = NO;
    self.assetExplorerBundleSizes = nil;
    self.assetExplorerBundleSortByDate = NO;
    self.assetExplorerBundleDateAscending = NO;
    self.assetExplorerBundleDates = nil;
    self.assetExplorerBundleSortByCreation = NO;
    self.assetExplorerBundleCreationAscending = NO;
    self.assetExplorerBundleCreations = nil;
    self.assetExplorerTextureAssets = nil;
    self.assetExplorerTexturePagerStack = nil;
    self.assetExplorerTexturePrevButton = nil;
    self.assetExplorerTextureNextButton = nil;
    self.assetExplorerTexturePositionLabel = nil;
    self.assetExplorerVisual = nil;
    self.assetExplorerPageStack = nil;
    self.assetExplorerPagePrevButton = nil;
    self.assetExplorerPageNextButton = nil;
    self.assetExplorerPageLabel = nil;
    self.assetExplorerStatusMessage = nil;
    self.assetExplorerSelectedBundle = nil;
    self.assetExplorerListRestorePending = NO;
    self.assetExplorerGeneration += 1;
    self.assetExplorerFullScreenOpen = NO;
    [NSNotificationCenter.defaultCenter removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [self.memoryUsageRefreshTimer invalidate];
    self.memoryUsageRefreshTimer = nil;
    [self.memoryFullScreenOverlay removeFromSuperview];
    self.memoryFullScreenOverlay = nil;
    self.memoryPopupScrim = nil;
    self.memoryPopupView = nil;
    self.memoryNumpadText = nil;
    self.memoryNumpadDisplayLabel = nil;
    self.memoryFullScreenScrollView = nil;
    self.memoryFullScreenContentView = nil;
    self.memoryFullScreenStatusLabel = nil;
    self.memoryRefreshPieView = nil;
    self.memoryRefreshPieLayer = nil;
    self.memoryCloseButtonLeadingConstraint = nil;
    self.memoryExportButton = nil;
    self.memoryPageControl = nil;
    self.memoryLocalPages = nil;
    [self.memoryClockTimer invalidate];
    self.memoryClockTimer = nil;
    self.memoryInfoPanel = nil;
    self.memoryBigPieDisc = nil;
    self.memoryBigPieLayer = nil;
    self.memoryClockLabel = nil;
    self.memoryInvertClip = nil;
    self.memoryInvertMaskLayer = nil;
    self.memoryInvertClockLabel = nil;
    self.memorySubtextLabel = nil;
    self.memoryInvertSubtextLabel = nil;
    self.memoryInvertFeedLabels = nil;
    self.memoryStatLabels = nil;
    self.memoryFeedLabels = nil;
    self.memoryFeed = nil;
    self.memoryPendingGroups = nil;
    self.memoryPendingColumns = nil;
    self.memorySnapshotSystemRows = nil;
    self.memorySnapshotGroups = nil;
    self.memorySnapshotDate = nil;
    self.memoryHasSnapshot = NO;
    zs_memory_scan_reset();
}

- (void)zs_closeButtonTapped {
    if (self.pinMenuOpen) {
        [self zs_dismissPinMenuAnimated:YES delay:0 completion:nil];
        return;
    }
    if (self.docsPanelOpen) {
        [self closeDocsPanel];
        return;
    }
    [self closePanel];
}

- (void)panelSwiped:(UIPanGestureRecognizer *)gesture {
    if (!self.panelOpen) return;
    if (self.assetExplorerFullScreenOpen && self.assetExplorerTextureOpen && self.assetExplorerPreviewScale > 1.01) return;
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint translation = [gesture translationInView:self.contentOverlay ?: gesture.view];
    BOOL mostlyHorizontal = fabs(translation.x) > fabs(translation.y) * 1.5;
    if (mostlyHorizontal && translation.x > 40) {
        [self zs_closeButtonTapped];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([gestureRecognizer isKindOfClass:[UIPinchGestureRecognizer class]]) return YES;

    if (gestureRecognizer == self.selectModeDragPan) {
        UIView *touched = touch.view;
        while (touched && touched != gestureRecognizer.view) {
            if ([touched isKindOfClass:[UIControl class]]) return NO;
            touched = touched.superview;
        }
        return YES;
    }

    if ([touch.view isKindOfClass:[ZSCapsuleSlider class]]) return NO;
    if ([touch.view isKindOfClass:[ZSModeSlider class]]) return NO;
    if ([touch.view isKindOfClass:[ZSWheelPicker class]]) return NO;
    if ([touch.view isKindOfClass:[ZSSectionIndexView class]]) return NO;
    if ([touch.view isKindOfClass:[UISwitch class]]) return NO;
    if ([touch.view isKindOfClass:[UIButton class]]) return NO;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

#pragma mark Panel

static const CGFloat kZSSectionIndexViewWidth = 14;
static const CGFloat kZSSectionIndexTrailingInset = 3;

UIView *zs_ae_section_header(NSString *title) {
    UIView *header = [[UIView alloc] init];
    header.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = zs_mono_font(10, UIFontWeightSemibold);
    label.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    label.text = title;
    [header addSubview:label];
    UILayoutGuide *safeArea = header.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:kPanelPadding],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:safeArea.trailingAnchor constant:-kPanelPadding],
        [label.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    return header;
}

static const CGFloat kRowSpacing = 4;
static const CGFloat kSectionSpacing = 20;

static UIButton *zs_make_section_info_button(NSString *docKey, id target, SEL action, CGFloat size) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *infoConfig = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightRegular];
    UIImage *infoImage = [UIImage systemImageNamed:@"info.circle" withConfiguration:infoConfig];
    [button setImage:infoImage forState:UIControlStateNormal];
    button.tintColor = [UIColor colorWithWhite:1 alpha:0.4];
    button.backgroundColor = UIColor.clearColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsZero;
    button.imageEdgeInsets = UIEdgeInsetsZero;

    objc_setAssociatedObject(button, "zs_docsKey", docKey, OBJC_ASSOCIATION_COPY);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [haptic impactOccurred];
    }] forControlEvents:UIControlEventTouchDown];

    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:size],
        [button.heightAnchor constraintEqualToConstant:size],
    ]];
    return button;
}

static UIView *zs_make_entitlements_card(BOOL hasIncreasedLimit, BOOL hasExtendedVA) {
    UIView *card;
    UIView *host;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        zs_configure_glass_corners(glass, 14, NO);
        glass.layer.borderWidth = 1;
        glass.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
        zs_register_suspendable_glass(glass);
        card = glass;
        host = glass.contentView;
    } else {
        UIView *plain = [[UIView alloc] init];
        plain.translatesAutoresizingMaskIntoConstraints = NO;
        plain.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.96];
        plain.layer.cornerRadius = 14;
        plain.layer.cornerCurve = kCACornerCurveContinuous;
        plain.layer.borderWidth = 1;
        plain.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
        plain.clipsToBounds = YES;
        card = plain;
        host = plain;
    }

    UILabel *header = [[UILabel alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.text = @"ENTITLEMENTS";
    header.font = zs_mono_font(9, UIFontWeightSemibold);
    header.textColor = [UIColor colorWithWhite:0.9 alpha:1];

    UIColor *yesColor = zs_accent_green_color();
    UIColor *noColor = [UIColor colorWithRed:1.0 green:0.33 blue:0.33 alpha:1.0];
    NSArray<NSArray *> *entries = @[
        @[@"kern.increased-memory-limit", @(hasIncreasedLimit)],
        @[@"kern.extended-virtual-addressing", @(hasExtendedVA)],
    ];

    UIStackView *rows = [[UIStackView alloc] init];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 8;

    for (NSArray *entry in entries) {
        BOOL on = [entry[1] boolValue];

        UILabel *nameLabel = [[UILabel alloc] init];
        nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        nameLabel.font = zs_mono_font(11, UIFontWeightRegular);
        nameLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        nameLabel.text = entry[0];
        nameLabel.adjustsFontSizeToFitWidth = YES;
        nameLabel.minimumScaleFactor = 0.7;
        [nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        UILabel *valueLabel = [[UILabel alloc] init];
        valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        valueLabel.font = zs_mono_font(11, UIFontWeightSemibold);
        valueLabel.textColor = on ? yesColor : noColor;
        valueLabel.text = on ? @"Yes" : @"No";
        valueLabel.textAlignment = NSTextAlignmentRight;
        [valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[nameLabel, valueLabel]];
        line.translatesAutoresizingMaskIntoConstraints = NO;
        line.axis = UILayoutConstraintAxisHorizontal;
        line.spacing = 8;
        line.alignment = UIStackViewAlignmentCenter;
        [rows addArrangedSubview:line];
    }

    [host addSubview:header];
    [host addSubview:rows];

    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [header.topAnchor constraintEqualToAnchor:host.topAnchor constant:12],

        [rows.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [rows.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [rows.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
        [rows.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
    ]];

    return card;
}

static UIView *zs_make_syslog_blacklist_card(UIView *syslogRow, UILabel *blacklistHeader, UILabel *statusLabel, UIScrollView *entriesScroll) {
    UIView *card;
    UIView *host;
    if (zs_has_liquid_glass()) {
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        zs_configure_glass_corners(glass, 14, NO);
        glass.layer.borderWidth = 1;
        glass.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
        zs_register_suspendable_glass(glass);
        card = glass;
        host = glass.contentView;
    } else {
        UIView *plain = [[UIView alloc] init];
        plain.translatesAutoresizingMaskIntoConstraints = NO;
        plain.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.96];
        plain.layer.cornerRadius = 14;
        plain.layer.cornerCurve = kCACornerCurveContinuous;
        plain.layer.borderWidth = 1;
        plain.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
        plain.clipsToBounds = YES;
        card = plain;
        host = plain;
    }

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];

    UILabel *cardTitle = [[UILabel alloc] init];
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    cardTitle.text = @"NSLog Keyword Blacklist";
    cardTitle.font = zs_mono_font(9, UIFontWeightSemibold);
    cardTitle.textColor = [UIColor colorWithWhite:0.9 alpha:1];

    [host addSubview:cardTitle];
    [host addSubview:syslogRow];
    [host addSubview:separator];
    [host addSubview:blacklistHeader];
    [host addSubview:statusLabel];
    [host addSubview:entriesScroll];

    [NSLayoutConstraint activateConstraints:@[
        [syslogRow.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [syslogRow.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [cardTitle.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [cardTitle.topAnchor constraintEqualToAnchor:host.topAnchor constant:12],

        [syslogRow.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:8],
        [syslogRow.heightAnchor constraintEqualToConstant:34],

        [separator.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [separator.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [separator.topAnchor constraintEqualToAnchor:syslogRow.bottomAnchor constant:11],
        [separator.heightAnchor constraintEqualToConstant:1],

        [blacklistHeader.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [blacklistHeader.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:10],
        [blacklistHeader.bottomAnchor constraintEqualToAnchor:entriesScroll.topAnchor constant:-6],

        [statusLabel.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [statusLabel.centerYAnchor constraintEqualToAnchor:blacklistHeader.centerYAnchor],
        [statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:blacklistHeader.trailingAnchor constant:8],

        [entriesScroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [entriesScroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-12],
        [entriesScroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
        [entriesScroll.heightAnchor constraintEqualToConstant:32],
    ]];

    return card;
}

#pragma mark - Experimental settings index mapping

static NSInteger zs_exp_idx_QualityAA(int32_t v) { if (v == 1) return 0; if (v == 2) return 1; if (v == 4) return 2; if (v == 8) return 3; return 0; }
static NSInteger zs_exp_idx_URPMSAA(int32_t v) { if (v == 1) return 0; if (v == 2) return 1; if (v == 4) return 2; if (v == 8) return 3; return 0; }
static NSInteger zs_exp_idx_MainShadowResolution(int32_t v) { if (v == 512) return 0; if (v == 1024) return 1; if (v == 2048) return 2; if (v == 4096) return 3; return 0; }
static NSInteger zs_exp_idx_AdditionalShadowResolution(int32_t v) { if (v == 256) return 0; if (v == 512) return 1; if (v == 1024) return 2; if (v == 2048) return 3; return 0; }
static NSInteger zs_exp_idx_AdditionalShadowTierLow(int32_t v) { if (v == 256) return 0; if (v == 512) return 1; if (v == 1024) return 2; if (v == 2048) return 3; return 0; }
static NSInteger zs_exp_idx_AdditionalShadowTierMedium(int32_t v) { if (v == 256) return 0; if (v == 512) return 1; if (v == 1024) return 2; if (v == 2048) return 3; return 0; }
static NSInteger zs_exp_idx_AdditionalShadowTierHigh(int32_t v) { if (v == 256) return 0; if (v == 512) return 1; if (v == 1024) return 2; if (v == 2048) return 3; return 0; }
static NSInteger zs_exp_idx_ColorGradingLUTSize(int32_t v) { if (v == 16) return 0; if (v == 32) return 1; if (v == 48) return 2; if (v == 64) return 3; return 0; }
static NSInteger zs_exp_idx_RigidbodySolverIterations(int32_t v) { return MAX(0, MIN(11, (NSInteger)v - 1)); }
static NSInteger zs_exp_idx_RigidbodySolverVelocityIterations(int32_t v) { return MAX(0, MIN(7, (NSInteger)v - 1)); }

static UIView *zs_make_section_separator(void) {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return line;
}

UIImage *zs_section_collapse_chevron_image(BOOL collapsed) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:(collapsed ? @"chevron.right" : @"chevron.down") withConfiguration:config];
}

static UIButton *zs_make_section_collapse_button(id target, SEL action, CGFloat size) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setImage:zs_section_collapse_chevron_image(NO) forState:UIControlStateNormal];
    button.tintColor = [UIColor colorWithWhite:1 alpha:0.45];
    button.backgroundColor = UIColor.clearColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsZero;
    button.imageEdgeInsets = UIEdgeInsetsZero;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:size],
        [button.heightAnchor constraintEqualToConstant:size],
    ]];
    return button;
}

static void zs_configure_section_header_row(UIView *row, UIView *leadingSeparator) {
    objc_setAssociatedObject(row, "zs_isSectionHeader", @YES, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionCollapsed", @NO, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionLeadingSeparator", leadingSeparator, OBJC_ASSOCIATION_RETAIN);
}

static void zs_add_section_header(UIStackView *stack, NSString *title, id target) {
    UIView *previous = stack.arrangedSubviews.lastObject;
    UIView *separator = nil;
    if (previous) {
        separator = zs_make_section_separator();
        [stack addArrangedSubview:separator];
        [stack setCustomSpacing:kSectionSpacing afterView:previous];
        [stack setCustomSpacing:kSectionSpacing afterView:separator];
    }

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *header = zs_make_section_header(title);
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:header];

    CGFloat chevronSize = ceil(header.font.lineHeight);
    UIButton *chevronButton = zs_make_section_collapse_button(target, @selector(zs_sectionCollapseToggleTapped:), chevronSize);
    [row addSubview:chevronButton];
    objc_setAssociatedObject(chevronButton, "zs_sectionHeaderRow", row, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionTitle", title, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionChevronButton", chevronButton, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [header.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [chevronButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:header.trailingAnchor constant:6],
        [chevronButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [chevronButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [row.topAnchor constraintEqualToAnchor:header.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    ]];

    zs_configure_section_header_row(row, separator);
    [stack addArrangedSubview:row];
}

static void zs_add_section_header_with_docs(UIStackView *stack, NSString *title, id infoTarget, SEL infoAction) {
    UIView *previous = stack.arrangedSubviews.lastObject;
    UIView *separator = nil;
    if (previous) {
        separator = zs_make_section_separator();
        [stack addArrangedSubview:separator];
        [stack setCustomSpacing:kSectionSpacing afterView:previous];
        [stack setCustomSpacing:kSectionSpacing afterView:separator];
    }

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *header = zs_make_section_header(title);
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:header];

    CGFloat infoButtonSize = ceil(header.font.lineHeight);
    UIButton *infoButton = zs_make_section_info_button(title, infoTarget, infoAction, infoButtonSize);
    [row addSubview:infoButton];

    UIButton *chevronButton = zs_make_section_collapse_button(infoTarget, @selector(zs_sectionCollapseToggleTapped:), infoButtonSize);
    [row addSubview:chevronButton];
    objc_setAssociatedObject(chevronButton, "zs_sectionHeaderRow", row, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionTitle", title, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(row, "zs_sectionChevronButton", chevronButton, OBJC_ASSOCIATION_RETAIN);

    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [header.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [infoButton.leadingAnchor constraintEqualToAnchor:header.trailingAnchor constant:6],
        [infoButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [chevronButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:infoButton.trailingAnchor constant:6],
        [chevronButton.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [chevronButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [row.topAnchor constraintEqualToAnchor:header.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    ]];

    zs_configure_section_header_row(row, separator);
    [stack addArrangedSubview:row];
}

static const CGFloat kGlassMergeSpacing = 16;
static const CGFloat kZSSyslogConsoleHeight = 180;

- (void)buildPanel:(UIView *)unityView {
    if (self.glassContainer) [self destroyPanelHierarchy];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    self.panelWidth = kPanelWidth;

    UIVisualEffectView *chrome = nil;

    if (zs_has_liquid_glass()) {
        chrome = [[ZSPassthroughEffectView alloc] initWithEffect:zs_make_glass_container_effect(kGlassMergeSpacing)];
    } else {

        chrome = [[ZSPassthroughEffectView alloc] initWithEffect:nil];
    }

    self.glassContainer = chrome;
    self.glassContainerContent = chrome.contentView;
    self.glassContainer.userInteractionEnabled = YES;
    self.glassContainer.hidden = YES;
    [unityView addSubview:self.glassContainer];
    zs_mark_host_owned(self.glassContainer);
    zs_force_dark(self.glassContainer);

    if (zs_has_liquid_glass()) {

        self.panelGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        self.panelGlass.userInteractionEnabled = YES;
        zs_configure_main_panel_glass_corners(self.panelGlass, kPanelCornerRadiusMinimum, YES);
        [self.glassContainerContent addSubview:self.panelGlass];

        self.handleGlass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(YES)];
        self.handleGlass.userInteractionEnabled = YES;
        zs_configure_glass_corners(self.handleGlass, kHandleCornerRadius, NO);
        [self.glassContainerContent addSubview:self.handleGlass];

        self.panel = self.panelGlass.contentView;
        self.handle = self.handleGlass.contentView;
    } else {

        self.panel = [[UIView alloc] init];
        self.handle = [[UIView alloc] init];
        self.panel.backgroundColor = UIColor.clearColor;
        self.handle.backgroundColor = UIColor.clearColor;
        [self.glassContainerContent addSubview:self.panel];
        [self.glassContainerContent addSubview:self.handle];
    }

    self.contentOverlay = [[ZSPassthroughView alloc] initWithFrame:CGRectZero];
    self.contentOverlay.backgroundColor = UIColor.clearColor;
    self.contentOverlay.opaque = NO;
    self.contentOverlay.clipsToBounds = YES;
    self.contentOverlay.layer.cornerRadius = kPanelCornerRadiusMinimum;
    self.contentOverlay.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentOverlay.userInteractionEnabled = YES;
    self.contentOverlay.hidden = YES;
    [unityView addSubview:self.contentOverlay];
    zs_mark_host_owned(self.contentOverlay);
    zs_force_dark(self.contentOverlay);

    UIPanGestureRecognizer *closeSwipe = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelSwiped:)];
    closeSwipe.delegate = self;
    [self.contentOverlay addGestureRecognizer:closeSwipe];

    if (zs_has_liquid_glass()) {
        self.panel.backgroundColor = UIColor.clearColor;
        self.panel.clipsToBounds = NO;
        self.panel.layer.cornerRadius = 0;
    } else {
        self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        self.panel.layer.cornerRadius = kPanelCornerRadiusMinimum;
        self.panel.layer.cornerCurve = kCACornerCurveContinuous;
        self.panel.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
        self.panel.clipsToBounds = YES;
    }
    self.panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    if (zs_has_liquid_glass()) {
        self.handle.backgroundColor = UIColor.clearColor;
        self.handle.layer.borderWidth = 0;
    } else {
        self.handle.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        self.handle.layer.cornerRadius = kHandleCornerRadius;
        self.handle.layer.cornerCurve = kCACornerCurveContinuous;
        self.handle.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
        self.handle.layer.borderWidth = 0;
    }
    self.handle.clipsToBounds = NO;

    self.chevron = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, kHandleWidth, 24)];
    self.chevron.textAlignment = NSTextAlignmentCenter;
    self.chevron.textColor = [UIColor colorWithWhite:1 alpha:0.66];
    self.chevron.font = zs_mono_font(15, UIFontWeightLight);
    self.chevron.text = @"‹";
    self.chevron.center = CGPointMake(kHandleWidth * 0.5, kHandleHeight * 0.5);
    [self.handle addSubview:self.chevron];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_closeButtonTapped)];
    [self.handle addGestureRecognizer:tap];
    self.handle.userInteractionEnabled = YES;

    UILongPressGestureRecognizer *pinHold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(zs_handleHeld:)];
    pinHold.minimumPressDuration = 0.5;
    pinHold.allowableMovement = 14;
    [self.handle addGestureRecognizer:pinHold];
    [tap requireGestureRecognizerToFail:pinHold];

    [self zs_buildPinnedTabsFromStore];

    [self buildDocsPanel:unityView];
    [self zs_buildSyslogFullScreenPanelIfNeeded];
    [self zs_buildMemoryFullScreenPanelIfNeeded];
    [self zs_buildAssetExplorerFullScreenPanelIfNeeded];

    [self zs_restackPinChrome];

    __weak typeof(self) weakSelf = self;

    self.scrollViewport = [[UIView alloc] init];
    self.scrollViewport.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollViewport.backgroundColor = UIColor.clearColor;
    self.scrollViewport.clipsToBounds = NO;
    [self.contentOverlay addSubview:self.scrollViewport];

    self.scrollView = [[ZSPanelScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.alwaysBounceVertical = NO;
    self.scrollView.bounces = NO;
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.scrollView.delegate = self;

    self.scrollView.delaysContentTouches = NO;
    [self.scrollViewport addSubview:self.scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollViewport.topAnchor constraintEqualToAnchor:self.contentOverlay.topAnchor],
        [self.scrollViewport.leadingAnchor constraintEqualToAnchor:self.contentOverlay.leadingAnchor],
        [self.scrollViewport.trailingAnchor constraintEqualToAnchor:self.contentOverlay.trailingAnchor],
        [self.scrollViewport.bottomAnchor constraintEqualToAnchor:self.contentOverlay.bottomAnchor],

        [self.scrollView.topAnchor constraintEqualToAnchor:self.scrollViewport.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.scrollViewport.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.scrollViewport.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.scrollViewport.bottomAnchor],
    ]];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = kRowSpacing;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:kPanelPadding],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:kPanelPadding],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-(kPanelPadding + kZSSectionIndexReservedWidth)],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-kPanelPadding],
        [self.stack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-((kPanelPadding * 2) + kZSSectionIndexReservedWidth)],
    ]];

    self.sectionIndexView = [[ZSSectionIndexView alloc] init];
    self.sectionIndexView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sectionIndexView.onSelect = ^(NSUInteger index) {
        [weakSelf zs_scrollToSectionAtIndex:index];
    };
    [self.contentOverlay addSubview:self.sectionIndexView];
    [NSLayoutConstraint activateConstraints:@[
        [self.sectionIndexView.trailingAnchor constraintEqualToAnchor:self.contentOverlay.trailingAnchor constant:-kZSSectionIndexTrailingInset],
        [self.sectionIndexView.centerYAnchor constraintEqualToAnchor:self.contentOverlay.centerYAnchor],
        [self.sectionIndexView.widthAnchor constraintEqualToConstant:kZSSectionIndexViewWidth],
    ]];

    UIImageView *signatureOverlay = zs_make_signature_overlay();
    if (signatureOverlay) {
        [self.scrollView addSubview:signatureOverlay];
        [NSLayoutConstraint activateConstraints:@[
            [signatureOverlay.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:kZSSignatureInset],
            [signatureOverlay.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-kZSSignatureInset],
        ]];
    }

    zs_ensure_settings_loaded_from_disk();

    zs_set_auto_unload_on_memory_warning(g_expAutoUnloadOnMemoryWarning);
    zs_set_debug_log_memory_usage_tier(g_expDebugLogMemoryUsageTier);
    zs_set_auto_unload_on_elevated_memory_usage(g_expAutoUnloadOnElevatedMemoryUsage);

    for (NSString *term in g_syslogBlacklist) {
        [self.syslogBlacklist addObject:term];
    }

    NSString *(^fpsFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%d", (int)roundf(v)]; };
    NSString *(^twoDecimalFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.2f", v]; };
    NSString *(^wholeNumberFormat)(float) = ^NSString *(float v) { return [NSString stringWithFormat:@"%.0f", v]; };

    UIView *titleBlock = zs_make_title_block();
    [self.stack addArrangedSubview:titleBlock];
    [self.stack setCustomSpacing:kSectionSpacing afterView:titleBlock];

    self.updateStatusDot = objc_getAssociatedObject(titleBlock, @"zs_update_dot");
    self.updateStatusLabel = objc_getAssociatedObject(titleBlock, @"zs_update_label");
    UITapGestureRecognizer *updateStatusTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(updateStatusLabelTapped:)];
    [self.updateStatusLabel addGestureRecognizer:updateStatusTap];
    UILabel *titleHeaderLabel = objc_getAssociatedObject(titleBlock, @"zs_header_label");
    self.logoChevronButton = objc_getAssociatedObject(titleBlock, @"zs_logo_chevron");
    [self.logoChevronButton addTarget:self action:@selector(zs_logoChevronTapped:) forControlEvents:UIControlEventTouchUpInside];
    UITapGestureRecognizer *developerUnlockTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_titleHeaderTapped:)];
    [titleHeaderLabel addGestureRecognizer:developerUnlockTap];
    UILongPressGestureRecognizer *updateStatusLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(updateStatusLabelLongPressed:)];
    updateStatusLongPress.minimumPressDuration = 1.0;
    [self.updateStatusLabel addGestureRecognizer:updateStatusLongPress];
    [self zs_beginUpdateCheck];

    self.pendingCollapsedStates = zs_load_collapsed_section_states();
    self.pendingSectionBuilders = [NSMutableArray array];
    self.pendingExperimentalSectionBuilders = [NSMutableArray array];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Display", self, @selector(docsInfoTapped:));

    ZSRow *normalRow = zs_make_slider_row(@"Menu FPS", 10, 120, g_menuFPS, fpsFormat);
    self.normalFpsSlider = normalRow.slider;
    self.normalFpsValueLabel = normalRow.valueLabel;
    normalRow.slider.defaultValue = kDefaultMenuFPS;
    normalRow.slider.hasDefaultValue = YES;
    [normalRow.slider addTarget:self action:@selector(normalFpsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:normalRow];

    ZSRow *combatRow = zs_make_slider_row(@"Combat FPS", 10, 120, g_combatFPS, fpsFormat);
    self.combatFpsSlider = combatRow.slider;
    self.combatFpsValueLabel = combatRow.valueLabel;
    combatRow.slider.defaultValue = kDefaultCombatFPS;
    combatRow.slider.hasDefaultValue = YES;
    [combatRow.slider addTarget:self action:@selector(combatFpsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:combatRow];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Rendering", self, @selector(docsInfoTapped:));

    ZSRow *scaleRow = zs_make_slider_row(@"Render Scale", 25, 100, g_renderScale * 100.0f, ^NSString *(float v) {
        if (fabsf(v - 50.0f) <= kDefaultValueEpsilon) return @"low";
        if (fabsf(v - 75.0f) <= kDefaultValueEpsilon) return @"med";
        if (fabsf(v - 100.0f) <= kDefaultValueEpsilon) return @"high";
        return [NSString stringWithFormat:@"%.2f", v / 100.0];
    });
    scaleRow.slider.defaultValue = kDefaultRenderScalePct;
    scaleRow.slider.hasDefaultValue = YES;
    scaleRow.slider.indicatorValues = @[@50.0f, @75.0f];
    [scaleRow.slider addTarget:self action:@selector(scaleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:scaleRow];

    ZSRow *battleScaleRow = zs_make_slider_row(@"Battle RS", 25, 100, g_battleRenderScale * 100.0f, ^NSString *(float v) {
        if (fabsf(v - 50.0f) <= kDefaultValueEpsilon) return @"low";
        if (fabsf(v - 75.0f) <= kDefaultValueEpsilon) return @"med";
        if (fabsf(v - 100.0f) <= kDefaultValueEpsilon) return @"high";
        return [NSString stringWithFormat:@"%.2f", v / 100.0];
    });
    battleScaleRow.slider.defaultValue = kDefaultBattleRenderScalePct;
    battleScaleRow.slider.hasDefaultValue = YES;
    battleScaleRow.slider.indicatorValues = @[@50.0f, @75.0f];
    [battleScaleRow.slider addTarget:self action:@selector(battleScaleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:battleScaleRow];

    ZSRow *texRow = zs_make_mode_slider_row(@"Texture MIP", @[@"0", @"1", @"2", @"3", @"4"], g_textureMip, kDefaultTextureMipEngine);
    [texRow.modeSlider addTarget:self action:@selector(texModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:texRow];

    ZSRow *msaaRow = zs_make_mode_slider_row(@"MSAA", @[@"1x", @"2x", @"4x", @"8x"], g_msaaIndex, kDefaultMSAAIndex);
    [msaaRow.modeSlider addTarget:self action:@selector(msaaChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:msaaRow];

    NSInteger memorylessInitialIndex = (g_expRenderTextureMemorylessMode == 2) ? 1 : (g_expRenderTextureMemorylessMode == 4) ? 2 : (g_expRenderTextureMemorylessMode == 6) ? 3 : 0;
    ZSRow *memorylessRow = zs_make_mode_slider_row(@"RT Memoryless", @[@"Off", @"Depth", @"MSAA", @"Both"], memorylessInitialIndex, 0);
    objc_setAssociatedObject(memorylessRow.modeSlider, @"zs_exp_key", @"RenderTextureMemorylessMode", OBJC_ASSOCIATION_RETAIN);
    [memorylessRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:memorylessRow];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Anti-Aliasing", self, @selector(docsInfoTapped:));

    ZSRow *aaModeRow = zs_make_mode_slider_row(@"AA Mode", @[@"None", @"FXAA", @"SMAA", @"TAA"], g_aaModeIndex, kDefaultAAModeIndex);
    [aaModeRow.modeSlider addTarget:self action:@selector(cameraAAModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:aaModeRow];

    ZSRow *aaQualityRow = zs_make_mode_slider_row(@"AA Quality", @[@"Low", @"Med", @"High"], g_aaQualityIndex, kDefaultAAQualityIndex);
    [aaQualityRow.modeSlider addTarget:self action:@selector(cameraAAQualityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:aaQualityRow];

    ZSRow *ditherRow = zs_make_switch_row(@"Dithering", g_ditheringOn);
    objc_setAssociatedObject(ditherRow.toggle, "zs_defaultBool", @(kDefaultDithering), OBJC_ASSOCIATION_RETAIN);
    [ditherRow.toggle addTarget:self action:@selector(cameraDitheringChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:ditherRow];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Post FX", self, @selector(docsInfoTapped:));

    ZSRow *hdrRow = zs_make_switch_row(@"Bloom", g_hdrOn);
    objc_setAssociatedObject(hdrRow.toggle, "zs_defaultBool", @(kDefaultHDR), OBJC_ASSOCIATION_RETAIN);
    [hdrRow.toggle addTarget:self action:@selector(hdrChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:hdrRow];

    ZSRow *blurIntensityRow = zs_make_slider_row(@"Motion Blur", 0, 1, g_blurIntensity, twoDecimalFormat);
    blurIntensityRow.slider.defaultValue = kDefaultMotionBlur;
    blurIntensityRow.slider.hasDefaultValue = YES;
    [blurIntensityRow.slider addTarget:self action:@selector(blurIntensityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:blurIntensityRow];

    ZSRow *tonemapRow = zs_make_mode_slider_row(@"Tonemap", @[@"None", @"Neutral", @"ACES"], g_tonemapMode, kDefaultTonemapIndex);
    [tonemapRow.modeSlider addTarget:self action:@selector(tonemapModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:tonemapRow];

    for (int i = 0; i < kURPPostEffectCount; i++) {
        const ZSVolumeEffectDef *def = &kURPPostEffects[i];
        NSString *name = [NSString stringWithUTF8String:def->name];
        if (!def->floatField) continue;
        float currentVal = g_urpValue[name] ? g_urpValue[name].floatValue : def->defaultV;

        NSString *(^rowFormat)(float) = (def->maxV >= 20.0f) ? wholeNumberFormat : twoDecimalFormat;
        ZSRow *sliderRow = zs_make_slider_row(name, def->minV, def->maxV, currentVal, rowFormat);
        sliderRow.slider.defaultValue = def->defaultV;
        sliderRow.slider.hasDefaultValue = YES;
        objc_setAssociatedObject(sliderRow.slider, "zs_urp_name", name, OBJC_ASSOCIATION_RETAIN);
        [sliderRow.slider addTarget:self action:@selector(urpEffectValueChanged:) forControlEvents:UIControlEventValueChanged];
        [self.stack addArrangedSubview:sliderRow];
    }
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Particles", self, @selector(docsInfoTapped:));

    ZSRow *particleAlignmentRow = zs_make_wheel_row(@"Alignment",
        @[@"View", @"World", @"Local", @"Facing", @"Default"],
        g_expParticleAlignment, kZSParticleAlignmentPreserveOriginal);
    [particleAlignmentRow.wheelPicker addTarget:self action:@selector(particleAlignmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleAlignmentRow];

    ZSRow *particleRenderModeRow = zs_make_wheel_row(@"Render Mode",
        @[@"Billboard", @"Stretched Billboard", @"Horizontal Billboard", @"Vertical Billboard", @"Mesh", @"None", @"Default"],
        g_expParticleRenderMode, kZSParticleRenderModePreserveOriginal);
    [particleRenderModeRow.wheelPicker addTarget:self action:@selector(particleRenderModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleRenderModeRow];

    ZSRow *particleSortModeRow = zs_make_wheel_row(@"Sort Mode",
        @[@"None", @"Distance", @"Oldest Front", @"Youngest Front"],
        g_expParticleSortMode, 0);
    [particleSortModeRow.wheelPicker addTarget:self action:@selector(particleSortModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleSortModeRow];

    ZSRow *particleMinSizeRow = zs_make_slider_row(@"Min Size", 0, 1, g_expParticleMinSize, (^NSString *(float v){return [NSString stringWithFormat:@"%.2f",v];}));
    particleMinSizeRow.slider.defaultValue = 0; particleMinSizeRow.slider.hasDefaultValue = YES;
    [particleMinSizeRow.slider addTarget:self action:@selector(particleMinSizeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleMinSizeRow];

    ZSRow *particleMaxSizeRow = zs_make_slider_row(@"Max Size", 0, 1, g_expParticleMaxSize, (^NSString *(float v){return [NSString stringWithFormat:@"%.2f",v];}));
    particleMaxSizeRow.slider.defaultValue = 0.5; particleMaxSizeRow.slider.hasDefaultValue = YES;
    [particleMaxSizeRow.slider addTarget:self action:@selector(particleMaxSizeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleMaxSizeRow];

    ZSRow *particleFreeformRow = zs_make_switch_row(@"Freeform Stretching", g_expParticleFreeformStretching);
    objc_setAssociatedObject(particleFreeformRow.toggle, @"zs_defaultBool", @NO, OBJC_ASSOCIATION_RETAIN);
    [particleFreeformRow.toggle addTarget:self action:@selector(particleFreeformChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleFreeformRow];

    ZSRow *particleCapEnabledRow = zs_make_switch_row(@"Max Count Cap", g_expParticleMaxParticlesCapEnabled);
    objc_setAssociatedObject(particleCapEnabledRow.toggle, @"zs_defaultBool", @NO, OBJC_ASSOCIATION_RETAIN);
    [particleCapEnabledRow.toggle addTarget:self action:@selector(particleCapEnabledChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleCapEnabledRow];

    ZSRow *particleCapRow = zs_make_slider_row(@"Max Cap", 1, 300, g_expParticleMaxParticlesCap, (^NSString *(float v){return [NSString stringWithFormat:@"%d", (int)roundf(v)];}));
    particleCapRow.slider.defaultValue = 50; particleCapRow.slider.hasDefaultValue = YES;
    [particleCapRow.slider addTarget:self action:@selector(particleCapChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleCapRow];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Memory management", self, @selector(docsInfoTapped:));

    ZSMemorySystemStats entitlementStats = zs_collect_memory_system_stats();
    UIView *entitlementsCard = zs_make_entitlements_card(entitlementStats.hasIncreasedMemoryLimitEntitlement,
                                                         entitlementStats.hasExtendedVirtualAddressingEntitlement);
    [self.stack addArrangedSubview:entitlementsCard];
    [self.stack setCustomSpacing:8 afterView:entitlementsCard];

    BOOL ramBypassAvailable = zs_ram_bypass_available();
    BOOL ramBypassActiveAtLaunch = ramBypassAvailable && zs_ram_bypass_enabled();
    ZSRow *ramBypassRow = zs_make_switch_row(@"Extend Memory Usage", ramBypassActiveAtLaunch);
    [ramBypassRow.toggle addTarget:self action:@selector(ramBypassChanged:) forControlEvents:UIControlEventValueChanged];
    if (!ramBypassAvailable) {
        ramBypassRow.toggle.on = NO;
        ramBypassRow.toggle.enabled = NO;
        ramBypassRow.titleLabel.alpha = 0.35;
        ramBypassRow.toggle.alpha = 0.35;
        zs_add_unavailable_subtext(ramBypassRow, @"Unavailable, RamDonor extension not registered");
    }

    ZSRow *ramHudRow = zs_make_switch_row(@"Memory Usage HUD", zs_ram_hud_enabled());
    [ramHudRow.toggle addTarget:self action:@selector(ramHudChanged:) forControlEvents:UIControlEventValueChanged];

    __weak typeof(self) weakRedirectSelf = self;
    UIControl *ramRedirectModeRow = zs_make_disclosure_row(@"Redirect minimum", @"", nil, NULL);
    zs_disclosure_row_install_menu(ramRedirectModeRow, @[@"None", @"4 KB", @"8 KB", @"16 KB", @"32 KB", @"64 KB", @"128 KB", @"256 KB"], zs_ram_redirect_mode(), ^(NSInteger index) {
        zs_set_ram_redirect_mode(index);
        [weakRedirectSelf zs_scheduleSave];
    });

    UIButton *memoryCleanupButton = zs_make_grouped_action_button(@"Memory cleanup", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [memoryCleanupButton addTarget:self action:@selector(memoryCleanupTapped:) forControlEvents:UIControlEventTouchUpInside];

    self.memoryUsageAnalyzeButton = zs_make_grouped_action_button(@"Analyze memory usage", zs_accent_green_color());
    [self.memoryUsageAnalyzeButton addTarget:self action:@selector(memoryUsageAnalyzeTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIButton *lowResTranscodeButton = zs_make_grouped_action_button(@"Compress Textures", zs_accent_green_color());
    [lowResTranscodeButton addTarget:self action:@selector(lowResCompressTapped:) forControlEvents:UIControlEventTouchUpInside];
    g_zsLowResTranscodeButton = lowResTranscodeButton;

    UIView *memoryActionsCard = zs_make_grouped_action_card(@[
        ramBypassRow,
        ramHudRow,
        ramRedirectModeRow,
        memoryCleanupButton,
        self.memoryUsageAnalyzeButton,
        lowResTranscodeButton,
    ]);
    memoryActionsCard.layer.borderWidth = 1;
    memoryActionsCard.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
    [self zs_lowResAttachProgressToCard:memoryActionsCard transcodeButton:lowResTranscodeButton];

    [self.stack addArrangedSubview:memoryActionsCard];
    [self.stack setCustomSpacing:kSectionSpacing afterView:memoryActionsCard];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Mods", self, @selector(docsInfoTapped:));
    UIButton *loadModsButton = zs_make_grouped_action_button(@"Load Mods", [UIColor colorWithRed:0.55 green:0.42 blue:1.0 alpha:1.0]);
    [loadModsButton addTarget:self action:@selector(loadModsTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *reloadModsButton = zs_make_grouped_action_button(@"Reload Mods", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [reloadModsButton addTarget:self action:@selector(reloadModsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIView *loadReloadModsRow = zs_make_grouped_action_pair_row(loadModsButton, reloadModsButton);

    UIView *modsActionsCard = zs_make_grouped_action_card(@[loadReloadModsRow]);
    modsActionsCard.layer.borderWidth = 1;
    modsActionsCard.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
    [self.stack addArrangedSubview:modsActionsCard];
    [self.stack setCustomSpacing:8 afterView:modsActionsCard];

    self.modsLibraryExpandedFolders = [NSMutableSet set];
    self.modsLibraryExpandedInfoEntries = [NSMutableSet set];
    self.modsLibraryStack = [[UIStackView alloc] init];
    self.modsLibraryStack.axis = UILayoutConstraintAxisVertical;
    self.modsLibraryStack.spacing = 2;
    self.modsLibraryStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.modsLibraryStack];
    [self zs_rebuildModsLibrary];
    }];

    [self.pendingSectionBuilders addObject:^{
    NSUInteger developerViewsStart = self.stack.arrangedSubviews.count;
    zs_add_section_header(self.stack, @"Developer", self);

    ZSRow *overrideTutorialRow = zs_make_switch_row(@"Override tutorial completion", zs_tutorial_override_completion_enabled());
    [overrideTutorialRow.toggle addTarget:self action:@selector(overrideTutorialCompletionChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *fullManifestZeroingRow = zs_make_switch_row(@"Full manifest zeroing", PatchManifestNetwork.isFullZeroingEnabled);
    [fullManifestZeroingRow.toggle addTarget:self action:@selector(fullManifestZeroingChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *checkCIBuildsRow = zs_make_switch_row(@"Enable nightly builds", zs_update_uses_nightly_releases());
    [checkCIBuildsRow.toggle addTarget:self action:@selector(nightlyReleasesEnabledChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *experimentalEnabledRow = zs_make_switch_row(@"Enable Experimental Settings", g_experimentalSettingsEnabled);
    [experimentalEnabledRow.toggle addTarget:self action:@selector(experimentalSettingsEnabledChanged:) forControlEvents:UIControlEventValueChanged];

    UIButton *syslogButton = zs_make_grouped_action_button(@"Show system logs", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    self.syslogButton = syslogButton;

    [syslogButton addTarget:self action:@selector(toggleSyslogTapped) forControlEvents:UIControlEventTouchUpInside];

    UIView *developerActionsCard = zs_make_grouped_action_card(@[
        overrideTutorialRow,
        checkCIBuildsRow,
        experimentalEnabledRow,
        fullManifestZeroingRow,
        syslogButton,
    ]);
    developerActionsCard.layer.borderWidth = 1;
    developerActionsCard.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;

    [self.stack addArrangedSubview:developerActionsCard];
    [self.stack setCustomSpacing:8 afterView:developerActionsCard];

    self.syslogBlacklistField = [[UITextField alloc] init];
    self.syslogBlacklistField.font = zs_mono_font(11, UIFontWeightRegular);
    self.syslogBlacklistField.textColor = UIColor.whiteColor;
    self.syslogBlacklistField.tintColor = zs_accent_green_color();
    self.syslogBlacklistField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.syslogBlacklistField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.syslogBlacklistField.returnKeyType = UIReturnKeyDone;
    self.syslogBlacklistField.delegate = self;
    self.syslogBlacklistField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"add keyword(s)" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];

    ZSRow *syslogRow = zs_make_full_width_glass_field_row(self.syslogBlacklistField);

    UILabel *blacklistHeader = [[UILabel alloc] init];
    blacklistHeader.translatesAutoresizingMaskIntoConstraints = NO;
    blacklistHeader.text = @"KEYWORD FILTER";
    blacklistHeader.font = zs_mono_font(9, UIFontWeightSemibold);
    blacklistHeader.textColor = [UIColor colorWithWhite:0.9 alpha:1];

    self.syslogBlacklistStatusLabel = [[UILabel alloc] init];
    self.syslogBlacklistStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.syslogBlacklistStatusLabel.font = zs_mono_font(9, UIFontWeightRegular);
    self.syslogBlacklistStatusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    self.syslogBlacklistStatusLabel.text = @"NO TERMS";

    self.syslogBlacklistEntriesStack = [[UIStackView alloc] init];
    self.syslogBlacklistEntriesStack.axis = UILayoutConstraintAxisHorizontal;
    self.syslogBlacklistEntriesStack.spacing = 5;
    self.syslogBlacklistEntriesStack.alignment = UIStackViewAlignmentCenter;
    self.syslogBlacklistEntriesStack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *blacklistEntriesScroll = [[UIScrollView alloc] init];
    blacklistEntriesScroll.translatesAutoresizingMaskIntoConstraints = NO;
    blacklistEntriesScroll.backgroundColor = UIColor.clearColor;
    blacklistEntriesScroll.showsHorizontalScrollIndicator = NO;
    blacklistEntriesScroll.showsVerticalScrollIndicator = NO;
    blacklistEntriesScroll.alwaysBounceHorizontal = YES;
    [blacklistEntriesScroll addSubview:self.syslogBlacklistEntriesStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.syslogBlacklistEntriesStack.leadingAnchor constraintEqualToAnchor:blacklistEntriesScroll.contentLayoutGuide.leadingAnchor],
        [self.syslogBlacklistEntriesStack.trailingAnchor constraintEqualToAnchor:blacklistEntriesScroll.contentLayoutGuide.trailingAnchor],
        [self.syslogBlacklistEntriesStack.topAnchor constraintEqualToAnchor:blacklistEntriesScroll.contentLayoutGuide.topAnchor],
        [self.syslogBlacklistEntriesStack.bottomAnchor constraintEqualToAnchor:blacklistEntriesScroll.contentLayoutGuide.bottomAnchor],
        [self.syslogBlacklistEntriesStack.heightAnchor constraintEqualToAnchor:blacklistEntriesScroll.frameLayoutGuide.heightAnchor],
    ]];

    [self zs_rebuildSyslogBlacklistEntries];

    UIView *syslogBlacklistCard = zs_make_syslog_blacklist_card(syslogRow,
                                                                 blacklistHeader,
                                                                 self.syslogBlacklistStatusLabel,
                                                                 blacklistEntriesScroll);
    [self.stack addArrangedSubview:syslogBlacklistCard];
    [self.stack setCustomSpacing:kSectionSpacing afterView:syslogBlacklistCard];

    self.syslogTabEnabled = NO;
    [self zs_renderSyslogBuffer];

    NSArray<UIView *> *arrangedViews = self.stack.arrangedSubviews;
    self.developerSectionViews = [arrangedViews subarrayWithRange:NSMakeRange(developerViewsStart, arrangedViews.count - developerViewsStart)];
    [self zs_applyDeveloperSectionVisibilityRelayout:NO];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Miscellaneous", self, @selector(docsInfoTapped:));

    UIControl *customGreetingRow = zs_make_disclosure_row(@"Custom Greeting Text",
                                                           zs_custom_greeting_button_title(zs_custom_greeting_text()),
                                                           self, @selector(zs_customGreetingTextButtonTapped:));
    self.customGreetingRow = customGreetingRow;

    ZSRow *uidRedactorRow = zs_make_switch_row(@"Hide user ID", UIDRedactor.isEnabled);
    [uidRedactorRow.toggle addTarget:self action:@selector(uidRedactorChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *disableLiquidGlassRow = zs_make_switch_row(@"Disable Liquid Glass", zs_liquid_glass_disabled_by_user());
    [disableLiquidGlassRow.toggle addTarget:self action:@selector(disableLiquidGlassChanged:) forControlEvents:UIControlEventValueChanged];

    ZSRow *disableEnkephalinRow = zs_make_switch_row(@"Disable Enkephalin", zs_enkephalin_disabled_by_user());
    [disableEnkephalinRow.toggle addTarget:self action:@selector(disableEnkephalinChanged:) forControlEvents:UIControlEventValueChanged];

    UIButton *assetExplorerButton = zs_make_grouped_action_button(@"Asset Explorer", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [assetExplorerButton addTarget:self action:@selector(assetExplorerTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *selectModeButton = zs_make_grouped_action_button(@"Toggle Select Asset Mode", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [selectModeButton addTarget:self action:@selector(zs_selectModeTapped) forControlEvents:UIControlEventTouchUpInside];

    UIView *miscCard = zs_make_grouped_action_card(@[
        customGreetingRow,
        uidRedactorRow,
        disableLiquidGlassRow,
        disableEnkephalinRow,
        assetExplorerButton,
        selectModeButton,
    ]);
    miscCard.layer.borderWidth = 1;
    miscCard.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;

    [self.stack addArrangedSubview:miscCard];
    [self.stack setCustomSpacing:kSectionSpacing afterView:miscCard];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header(self.stack, @"Config", self);

    ZSRow *manifestZeroingRow = zs_make_switch_row(@"Manifest zeroing", PatchManifestNetwork.isZeroAllEnabled);
    [manifestZeroingRow.toggle addTarget:self action:@selector(manifestZeroingChanged:) forControlEvents:UIControlEventValueChanged];
    self.manifestZeroingRow = manifestZeroingRow;
    [self zs_refreshManifestZeroingRow];

    UIButton *manualIndexButton = zs_make_grouped_action_button(@"Manually Index Files", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [manualIndexButton addTarget:self action:@selector(manuallyIndexFilesTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *resetButton = zs_make_grouped_action_button(@"Reset Settings", [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0]);
    [resetButton addTarget:self action:@selector(resetSettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *reapplyButton = zs_make_grouped_action_button(@"Reapply Settings", [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0]);
    [reapplyButton addTarget:self action:@selector(reapplySettingsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIView *resetReapplyRow = zs_make_grouped_action_pair_row(resetButton, reapplyButton);

    UIButton *deleteSpecificAssetButton = zs_make_grouped_action_button(@"Delete Specific Asset", [UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:1.0]);
    [deleteSpecificAssetButton addTarget:self action:@selector(deleteSpecificAssetTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *hardResetButton = zs_make_grouped_action_button(@"Hard Assets Reset", [UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:1.0]);
    zs_attach_tap_to_confirm(hardResetButton, self,
        @"Hard Assets Reset?", @"This deletes every cached bundle, bank, backup, and Mod Asset Library entry, along with every game file ZSingularity has ever logged by path. This can't be undone.", @"Reset", YES, ^{
        [weakSelf hardAssetsResetTapped];
    });

    UIView *configActionsCard = zs_make_grouped_action_card(@[
        manifestZeroingRow,
        manualIndexButton,
        resetReapplyRow,
        deleteSpecificAssetButton,
        hardResetButton,
    ]);
    configActionsCard.layer.borderWidth = 1;
    configActionsCard.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;

    [self.stack addArrangedSubview:configActionsCard];
    [self.stack setCustomSpacing:kSectionSpacing afterView:configActionsCard];

    self.experimentalSectionContainer = [[UIStackView alloc] init];
    self.experimentalSectionContainer.axis = UILayoutConstraintAxisVertical;
    self.experimentalSectionContainer.spacing = kRowSpacing;
    self.experimentalSectionContainer.hidden = !g_experimentalSettingsEnabled;
    [self.stack addArrangedSubview:self.experimentalSectionContainer];
    [self.stack setCustomSpacing:kSectionSpacing afterView:configActionsCard];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Camera & Rendering", self);
    ZSRow *expPixelLightCountRow = zs_make_slider_row(@"Pixel Light Count", 0, 8, zs_exp_get_number(@"PixelLightCount"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expPixelLightCountRow.slider.defaultValue = zs_exp_get_default_number(@"PixelLightCount");
    expPixelLightCountRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expPixelLightCountRow.slider, @"zs_exp_key", @"PixelLightCount", OBJC_ASSOCIATION_RETAIN);
    [expPixelLightCountRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expPixelLightCountRow];
    ZSRow *expLODBiasRow = zs_make_slider_row(@"LOD Bias", 0.1, 4.0, zs_exp_get_number(@"LODBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expLODBiasRow.slider.defaultValue = zs_exp_get_default_number(@"LODBias");
    expLODBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expLODBiasRow.slider, @"zs_exp_key", @"LODBias", OBJC_ASSOCIATION_RETAIN);
    [expLODBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLODBiasRow];
    ZSRow *expLODCrossFadeRow = zs_make_switch_row(@"LOD Cross-Fade", zs_exp_get_bool(@"LODCrossFade"));
    objc_setAssociatedObject(expLODCrossFadeRow.toggle, @"zs_exp_key", @"LODCrossFade", OBJC_ASSOCIATION_RETAIN);
    [expLODCrossFadeRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLODCrossFadeRow];
    NSInteger VSyncCountSelIdx, VSyncCountDefIdx;
    VSyncCountSelIdx = MAX(0, MIN(3, (NSInteger)zs_exp_get_number(@"VSyncCount")));
    VSyncCountDefIdx = MAX(0, MIN(3, (NSInteger)0));
    ZSRow *expVSyncCountRow = zs_make_mode_slider_row(@"VSync Count", @[@"Off", @"Every VBlank", @"Every 2nd VBlank", @"Every 3rd VBlank"], VSyncCountSelIdx, VSyncCountDefIdx);
    objc_setAssociatedObject(expVSyncCountRow.modeSlider, @"zs_exp_key", @"VSyncCount", OBJC_ASSOCIATION_RETAIN);
    [expVSyncCountRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expVSyncCountRow];
    NSInteger QualityAASelIdx, QualityAADefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"QualityAA"); QualityAASelIdx = zs_exp_idx_QualityAA(v); }
    QualityAADefIdx = zs_exp_idx_QualityAA(1);
    ZSRow *expQualityAARow = zs_make_mode_slider_row(@"Quality AA", @[@"1x", @"2x", @"4x", @"8x"], QualityAASelIdx, QualityAADefIdx);
    objc_setAssociatedObject(expQualityAARow.modeSlider, @"zs_exp_key", @"QualityAA", OBJC_ASSOCIATION_RETAIN);
    [expQualityAARow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expQualityAARow];
    ZSRow *expCameraHDRRow = zs_make_switch_row(@"Camera HDR", zs_exp_get_bool(@"CameraHDR"));
    objc_setAssociatedObject(expCameraHDRRow.toggle, @"zs_exp_key", @"CameraHDR", OBJC_ASSOCIATION_RETAIN);
    [expCameraHDRRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraHDRRow];
    ZSRow *expCameraMSAARow = zs_make_switch_row(@"Camera MSAA", zs_exp_get_bool(@"CameraMSAA"));
    objc_setAssociatedObject(expCameraMSAARow.toggle, @"zs_exp_key", @"CameraMSAA", OBJC_ASSOCIATION_RETAIN);
    [expCameraMSAARow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraMSAARow];
    ZSRow *expDynamicResolutionRow = zs_make_switch_row(@"Dynamic Resolution", zs_exp_get_bool(@"DynamicResolution"));
    objc_setAssociatedObject(expDynamicResolutionRow.toggle, @"zs_exp_key", @"DynamicResolution", OBJC_ASSOCIATION_RETAIN);
    [expDynamicResolutionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expDynamicResolutionRow];
    ZSRow *expOcclusionCullingRow = zs_make_switch_row(@"Occlusion Culling", zs_exp_get_bool(@"OcclusionCulling"));
    objc_setAssociatedObject(expOcclusionCullingRow.toggle, @"zs_exp_key", @"OcclusionCulling", OBJC_ASSOCIATION_RETAIN);
    [expOcclusionCullingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expOcclusionCullingRow];
    ZSRow *expDepthTextureRow = zs_make_switch_row(@"Depth Texture", zs_exp_get_bool(@"DepthTexture"));
    objc_setAssociatedObject(expDepthTextureRow.toggle, @"zs_exp_key", @"DepthTexture", OBJC_ASSOCIATION_RETAIN);
    [expDepthTextureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expDepthTextureRow];
    ZSRow *expOpaqueTextureRow = zs_make_switch_row(@"Opaque Texture", zs_exp_get_bool(@"OpaqueTexture"));
    objc_setAssociatedObject(expOpaqueTextureRow.toggle, @"zs_exp_key", @"OpaqueTexture", OBJC_ASSOCIATION_RETAIN);
    [expOpaqueTextureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expOpaqueTextureRow];
    ZSRow *expRenderShadowsRow = zs_make_switch_row(@"Render Shadows", zs_exp_get_bool(@"RenderShadows"));
    objc_setAssociatedObject(expRenderShadowsRow.toggle, @"zs_exp_key", @"RenderShadows", OBJC_ASSOCIATION_RETAIN);
    [expRenderShadowsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRenderShadowsRow];
    ZSRow *expPostProcessingRow = zs_make_switch_row(@"Post Processing", zs_exp_get_bool(@"PostProcessing"));
    objc_setAssociatedObject(expPostProcessingRow.toggle, @"zs_exp_key", @"PostProcessing", OBJC_ASSOCIATION_RETAIN);
    [expPostProcessingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expPostProcessingRow];
    NSInteger AntialiasingModeSelIdx, AntialiasingModeDefIdx;
    AntialiasingModeSelIdx = MAX(0, MIN(3, (NSInteger)zs_exp_get_number(@"AntialiasingMode")));
    AntialiasingModeDefIdx = MAX(0, MIN(3, (NSInteger)3));
    ZSRow *expAntialiasingModeRow = zs_make_mode_slider_row(@"Antialiasing Mode", @[@"None", @"FXAA", @"SMAA", @"TAA"], AntialiasingModeSelIdx, AntialiasingModeDefIdx);
    objc_setAssociatedObject(expAntialiasingModeRow.modeSlider, @"zs_exp_key", @"AntialiasingMode", OBJC_ASSOCIATION_RETAIN);
    [expAntialiasingModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAntialiasingModeRow];
    NSInteger AntialiasingQualitySelIdx, AntialiasingQualityDefIdx;
    AntialiasingQualitySelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"AntialiasingQuality")));
    AntialiasingQualityDefIdx = MAX(0, MIN(2, (NSInteger)2));
    ZSRow *expAntialiasingQualityRow = zs_make_mode_slider_row(@"Antialiasing Quality", @[@"Low", @"Medium", @"High"], AntialiasingQualitySelIdx, AntialiasingQualityDefIdx);
    objc_setAssociatedObject(expAntialiasingQualityRow.modeSlider, @"zs_exp_key", @"AntialiasingQuality", OBJC_ASSOCIATION_RETAIN);
    [expAntialiasingQualityRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAntialiasingQualityRow];
    ZSRow *expCameraDitheringRow = zs_make_switch_row(@"Camera Dithering", zs_exp_get_bool(@"CameraDithering"));
    objc_setAssociatedObject(expCameraDitheringRow.toggle, @"zs_exp_key", @"CameraDithering", OBJC_ASSOCIATION_RETAIN);
    [expCameraDitheringRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraDitheringRow];
    NSInteger CameraRequiresDepthOptionSelIdx, CameraRequiresDepthOptionDefIdx;
    CameraRequiresDepthOptionSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"CameraRequiresDepthOption")));
    CameraRequiresDepthOptionDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expCameraRequiresDepthOptionRow = zs_make_mode_slider_row(@"Camera Requires Depth", @[@"Off", @"On", @"Use Pipeline Settings"], CameraRequiresDepthOptionSelIdx, CameraRequiresDepthOptionDefIdx);
    objc_setAssociatedObject(expCameraRequiresDepthOptionRow.modeSlider, @"zs_exp_key", @"CameraRequiresDepthOption", OBJC_ASSOCIATION_RETAIN);
    [expCameraRequiresDepthOptionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRequiresDepthOptionRow];
    NSInteger CameraRequiresColorOptionSelIdx, CameraRequiresColorOptionDefIdx;
    CameraRequiresColorOptionSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"CameraRequiresColorOption")));
    CameraRequiresColorOptionDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expCameraRequiresColorOptionRow = zs_make_mode_slider_row(@"Camera Requires Color", @[@"Off", @"On", @"Use Pipeline Settings"], CameraRequiresColorOptionSelIdx, CameraRequiresColorOptionDefIdx);
    objc_setAssociatedObject(expCameraRequiresColorOptionRow.modeSlider, @"zs_exp_key", @"CameraRequiresColorOption", OBJC_ASSOCIATION_RETAIN);
    [expCameraRequiresColorOptionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRequiresColorOptionRow];
    NSInteger CameraRenderTypeSelIdx, CameraRenderTypeDefIdx;
    CameraRenderTypeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"CameraRenderType")));
    CameraRenderTypeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expCameraRenderTypeRow = zs_make_mode_slider_row(@"Camera Render Type", @[@"Base", @"Overlay"], CameraRenderTypeSelIdx, CameraRenderTypeDefIdx);
    objc_setAssociatedObject(expCameraRenderTypeRow.modeSlider, @"zs_exp_key", @"CameraRenderType", OBJC_ASSOCIATION_RETAIN);
    [expCameraRenderTypeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRenderTypeRow];
    ZSRow *expCameraRequiresDepthTextureRow = zs_make_switch_row(@"Camera Requires Depth Texture", zs_exp_get_bool(@"CameraRequiresDepthTexture"));
    objc_setAssociatedObject(expCameraRequiresDepthTextureRow.toggle, @"zs_exp_key", @"CameraRequiresDepthTexture", OBJC_ASSOCIATION_RETAIN);
    [expCameraRequiresDepthTextureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRequiresDepthTextureRow];
    ZSRow *expCameraRequiresColorTextureRow = zs_make_switch_row(@"Camera Requires Color Texture", zs_exp_get_bool(@"CameraRequiresColorTexture"));
    objc_setAssociatedObject(expCameraRequiresColorTextureRow.toggle, @"zs_exp_key", @"CameraRequiresColorTexture", OBJC_ASSOCIATION_RETAIN);
    [expCameraRequiresColorTextureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraRequiresColorTextureRow];
    ZSRow *expCameraResetHistoryRow = zs_make_switch_row(@"Camera Reset History", zs_exp_get_bool(@"CameraResetHistory"));
    objc_setAssociatedObject(expCameraResetHistoryRow.toggle, @"zs_exp_key", @"CameraResetHistory", OBJC_ASSOCIATION_RETAIN);
    [expCameraResetHistoryRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraResetHistoryRow];
    ZSRow *expCameraStopNaNRow = zs_make_switch_row(@"Camera Stop NaN", zs_exp_get_bool(@"CameraStopNaN"));
    objc_setAssociatedObject(expCameraStopNaNRow.toggle, @"zs_exp_key", @"CameraStopNaN", OBJC_ASSOCIATION_RETAIN);
    [expCameraStopNaNRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraStopNaNRow];
    ZSRow *expCameraAllowXRRow = zs_make_switch_row(@"Camera Allow XR", zs_exp_get_bool(@"CameraAllowXR"));
    objc_setAssociatedObject(expCameraAllowXRRow.toggle, @"zs_exp_key", @"CameraAllowXR", OBJC_ASSOCIATION_RETAIN);
    [expCameraAllowXRRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraAllowXRRow];
    ZSRow *expCameraScreenCoordOverrideRow = zs_make_switch_row(@"Camera Screen Coord Override", zs_exp_get_bool(@"CameraScreenCoordOverride"));
    objc_setAssociatedObject(expCameraScreenCoordOverrideRow.toggle, @"zs_exp_key", @"CameraScreenCoordOverride", OBJC_ASSOCIATION_RETAIN);
    [expCameraScreenCoordOverrideRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraScreenCoordOverrideRow];
    ZSRow *expCameraHDROutputRow = zs_make_switch_row(@"Camera HDR Output", zs_exp_get_bool(@"CameraHDROutput"));
    objc_setAssociatedObject(expCameraHDROutputRow.toggle, @"zs_exp_key", @"CameraHDROutput", OBJC_ASSOCIATION_RETAIN);
    [expCameraHDROutputRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCameraHDROutputRow];
    NSInteger UpscalingFilterSelIdx, UpscalingFilterDefIdx;
    UpscalingFilterSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"UpscalingFilter")));
    UpscalingFilterDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expUpscalingFilterRow = zs_make_mode_slider_row(@"Upscaling Filter", @[@"Automatic", @"Bilinear", @"FSR"], UpscalingFilterSelIdx, UpscalingFilterDefIdx);
    objc_setAssociatedObject(expUpscalingFilterRow.modeSlider, @"zs_exp_key", @"UpscalingFilter", OBJC_ASSOCIATION_RETAIN);
    [expUpscalingFilterRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expUpscalingFilterRow];
    ZSRow *expFSROverrideRow = zs_make_switch_row(@"FSR Override", zs_exp_get_bool(@"FSROverride"));
    objc_setAssociatedObject(expFSROverrideRow.toggle, @"zs_exp_key", @"FSROverride", OBJC_ASSOCIATION_RETAIN);
    [expFSROverrideRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expFSROverrideRow];
    ZSRow *expFSRSharpnessRow = zs_make_slider_row(@"FSR Sharpness", 0.0, 1.0, zs_exp_get_number(@"FSRSharpness"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expFSRSharpnessRow.slider.defaultValue = zs_exp_get_default_number(@"FSRSharpness");
    expFSRSharpnessRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expFSRSharpnessRow.slider, @"zs_exp_key", @"FSRSharpness", OBJC_ASSOCIATION_RETAIN);
    [expFSRSharpnessRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expFSRSharpnessRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"URP Pipeline", self);
    ZSRow *expURPHDRRow = zs_make_switch_row(@"URP HDR", zs_exp_get_bool(@"URPHDR"));
    objc_setAssociatedObject(expURPHDRRow.toggle, @"zs_exp_key", @"URPHDR", OBJC_ASSOCIATION_RETAIN);
    [expURPHDRRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expURPHDRRow];
    NSInteger URPMSAASelIdx, URPMSAADefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"URPMSAA"); URPMSAASelIdx = zs_exp_idx_URPMSAA(v); }
    URPMSAADefIdx = zs_exp_idx_URPMSAA(1);
    ZSRow *expURPMSAARow = zs_make_mode_slider_row(@"URP MSAA", @[@"Disabled", @"2x", @"4x", @"8x"], URPMSAASelIdx, URPMSAADefIdx);
    objc_setAssociatedObject(expURPMSAARow.modeSlider, @"zs_exp_key", @"URPMSAA", OBJC_ASSOCIATION_RETAIN);
    [expURPMSAARow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expURPMSAARow];
    NSInteger MainLightModeSelIdx, MainLightModeDefIdx;
    MainLightModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"MainLightMode")));
    MainLightModeDefIdx = MAX(0, MIN(1, (NSInteger)1));
    ZSRow *expMainLightModeRow = zs_make_mode_slider_row(@"Main Light Mode", @[@"Disabled", @"Enabled"], MainLightModeSelIdx, MainLightModeDefIdx);
    objc_setAssociatedObject(expMainLightModeRow.modeSlider, @"zs_exp_key", @"MainLightMode", OBJC_ASSOCIATION_RETAIN);
    [expMainLightModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expMainLightModeRow];
    ZSRow *expMainLightShadowsRow = zs_make_switch_row(@"Main Light Shadows", zs_exp_get_bool(@"MainLightShadows"));
    objc_setAssociatedObject(expMainLightShadowsRow.toggle, @"zs_exp_key", @"MainLightShadows", OBJC_ASSOCIATION_RETAIN);
    [expMainLightShadowsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expMainLightShadowsRow];
    NSInteger MainShadowResolutionSelIdx, MainShadowResolutionDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"MainShadowResolution"); MainShadowResolutionSelIdx = zs_exp_idx_MainShadowResolution(v); }
    MainShadowResolutionDefIdx = zs_exp_idx_MainShadowResolution(2048);
    ZSRow *expMainShadowResolutionRow = zs_make_mode_slider_row(@"Main Shadow Resolution", @[@"512", @"1024", @"2048", @"4096"], MainShadowResolutionSelIdx, MainShadowResolutionDefIdx);
    objc_setAssociatedObject(expMainShadowResolutionRow.modeSlider, @"zs_exp_key", @"MainShadowResolution", OBJC_ASSOCIATION_RETAIN);
    [expMainShadowResolutionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expMainShadowResolutionRow];
    NSInteger AdditionalLightModeSelIdx, AdditionalLightModeDefIdx;
    AdditionalLightModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"AdditionalLightMode")));
    AdditionalLightModeDefIdx = MAX(0, MIN(2, (NSInteger)1));
    ZSRow *expAdditionalLightModeRow = zs_make_mode_slider_row(@"Additional Light Mode", @[@"Disabled", @"Per Vertex", @"Per Pixel"], AdditionalLightModeSelIdx, AdditionalLightModeDefIdx);
    objc_setAssociatedObject(expAdditionalLightModeRow.modeSlider, @"zs_exp_key", @"AdditionalLightMode", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalLightModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalLightModeRow];
    ZSRow *expMaxAdditionalLightsRow = zs_make_slider_row(@"Max Additional Lights", 0, 16, zs_exp_get_number(@"MaxAdditionalLights"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expMaxAdditionalLightsRow.slider.defaultValue = zs_exp_get_default_number(@"MaxAdditionalLights");
    expMaxAdditionalLightsRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expMaxAdditionalLightsRow.slider, @"zs_exp_key", @"MaxAdditionalLights", OBJC_ASSOCIATION_RETAIN);
    [expMaxAdditionalLightsRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expMaxAdditionalLightsRow];
    ZSRow *expAdditionalLightShadowsRow = zs_make_switch_row(@"Additional Light Shadows", zs_exp_get_bool(@"AdditionalLightShadows"));
    objc_setAssociatedObject(expAdditionalLightShadowsRow.toggle, @"zs_exp_key", @"AdditionalLightShadows", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalLightShadowsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalLightShadowsRow];
    NSInteger AdditionalShadowResolutionSelIdx, AdditionalShadowResolutionDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"AdditionalShadowResolution"); AdditionalShadowResolutionSelIdx = zs_exp_idx_AdditionalShadowResolution(v); }
    AdditionalShadowResolutionDefIdx = zs_exp_idx_AdditionalShadowResolution(512);
    ZSRow *expAdditionalShadowResolutionRow = zs_make_mode_slider_row(@"Additional Shadow Resolution", @[@"256", @"512", @"1024", @"2048"], AdditionalShadowResolutionSelIdx, AdditionalShadowResolutionDefIdx);
    objc_setAssociatedObject(expAdditionalShadowResolutionRow.modeSlider, @"zs_exp_key", @"AdditionalShadowResolution", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalShadowResolutionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalShadowResolutionRow];
    ZSRow *expReflectionProbeBlendingRow = zs_make_switch_row(@"Reflection Probe Blending", zs_exp_get_bool(@"ReflectionProbeBlending"));
    objc_setAssociatedObject(expReflectionProbeBlendingRow.toggle, @"zs_exp_key", @"ReflectionProbeBlending", OBJC_ASSOCIATION_RETAIN);
    [expReflectionProbeBlendingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expReflectionProbeBlendingRow];
    ZSRow *expReflectionProbeBoxProjectionRow = zs_make_switch_row(@"Reflection Probe Box Projection", zs_exp_get_bool(@"ReflectionProbeBoxProjection"));
    objc_setAssociatedObject(expReflectionProbeBoxProjectionRow.toggle, @"zs_exp_key", @"ReflectionProbeBoxProjection", OBJC_ASSOCIATION_RETAIN);
    [expReflectionProbeBoxProjectionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expReflectionProbeBoxProjectionRow];
    ZSRow *expReflectionProbeAtlasRow = zs_make_switch_row(@"Reflection Probe Atlas", zs_exp_get_bool(@"ReflectionProbeAtlas"));
    objc_setAssociatedObject(expReflectionProbeAtlasRow.toggle, @"zs_exp_key", @"ReflectionProbeAtlas", OBJC_ASSOCIATION_RETAIN);
    [expReflectionProbeAtlasRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expReflectionProbeAtlasRow];
    ZSRow *expDynamicBatchingRow = zs_make_switch_row(@"Dynamic Batching", zs_exp_get_bool(@"DynamicBatching"));
    objc_setAssociatedObject(expDynamicBatchingRow.toggle, @"zs_exp_key", @"DynamicBatching", OBJC_ASSOCIATION_RETAIN);
    [expDynamicBatchingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expDynamicBatchingRow];
    ZSRow *expSRPBatcherRow = zs_make_switch_row(@"SRP Batcher", zs_exp_get_bool(@"SRPBatcher"));
    objc_setAssociatedObject(expSRPBatcherRow.toggle, @"zs_exp_key", @"SRPBatcher", OBJC_ASSOCIATION_RETAIN);
    [expSRPBatcherRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expSRPBatcherRow];
    NSInteger ColorGradingModeSelIdx, ColorGradingModeDefIdx;
    ColorGradingModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"ColorGradingMode")));
    ColorGradingModeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expColorGradingModeRow = zs_make_mode_slider_row(@"Color Grading Mode", @[@"Low Dynamic Range", @"High Dynamic Range"], ColorGradingModeSelIdx, ColorGradingModeDefIdx);
    objc_setAssociatedObject(expColorGradingModeRow.modeSlider, @"zs_exp_key", @"ColorGradingMode", OBJC_ASSOCIATION_RETAIN);
    [expColorGradingModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expColorGradingModeRow];
    NSInteger ColorGradingLUTSizeSelIdx, ColorGradingLUTSizeDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"ColorGradingLUTSize"); ColorGradingLUTSizeSelIdx = zs_exp_idx_ColorGradingLUTSize(v); }
    ColorGradingLUTSizeDefIdx = zs_exp_idx_ColorGradingLUTSize(32);
    ZSRow *expColorGradingLUTSizeRow = zs_make_mode_slider_row(@"Color Grading L U T Size", @[@"16", @"32", @"48", @"64"], ColorGradingLUTSizeSelIdx, ColorGradingLUTSizeDefIdx);
    objc_setAssociatedObject(expColorGradingLUTSizeRow.modeSlider, @"zs_exp_key", @"ColorGradingLUTSize", OBJC_ASSOCIATION_RETAIN);
    [expColorGradingLUTSizeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expColorGradingLUTSizeRow];
    NSInteger GPUResidentDrawerModeSelIdx, GPUResidentDrawerModeDefIdx;
    GPUResidentDrawerModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"GPUResidentDrawerMode")));
    GPUResidentDrawerModeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expGPUResidentDrawerModeRow = zs_make_mode_slider_row(@"GPU Resident Drawer Mode", @[@"Disabled", @"Instanced Drawing"], GPUResidentDrawerModeSelIdx, GPUResidentDrawerModeDefIdx);
    objc_setAssociatedObject(expGPUResidentDrawerModeRow.modeSlider, @"zs_exp_key", @"GPUResidentDrawerMode", OBJC_ASSOCIATION_RETAIN);
    [expGPUResidentDrawerModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expGPUResidentDrawerModeRow];
    ZSRow *expGPUResidentOcclusionRow = zs_make_switch_row(@"GPU Resident Occlusion", zs_exp_get_bool(@"GPUResidentOcclusion"));
    objc_setAssociatedObject(expGPUResidentOcclusionRow.toggle, @"zs_exp_key", @"GPUResidentOcclusion", OBJC_ASSOCIATION_RETAIN);
    [expGPUResidentOcclusionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expGPUResidentOcclusionRow];
    ZSRow *expSmallMeshScreenPercentageRow = zs_make_slider_row(@"Small Mesh Screen Percentage", 0.0, 20.0, zs_exp_get_number(@"SmallMeshScreenPercentage"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expSmallMeshScreenPercentageRow.slider.defaultValue = zs_exp_get_default_number(@"SmallMeshScreenPercentage");
    expSmallMeshScreenPercentageRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expSmallMeshScreenPercentageRow.slider, @"zs_exp_key", @"SmallMeshScreenPercentage", OBJC_ASSOCIATION_RETAIN);
    [expSmallMeshScreenPercentageRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expSmallMeshScreenPercentageRow];
    NSInteger IntermediateTextureModeSelIdx, IntermediateTextureModeDefIdx;
    IntermediateTextureModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"IntermediateTextureMode")));
    IntermediateTextureModeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expIntermediateTextureModeRow = zs_make_mode_slider_row(@"Intermediate Texture Mode", @[@"Automatic", @"Always"], IntermediateTextureModeSelIdx, IntermediateTextureModeDefIdx);
    objc_setAssociatedObject(expIntermediateTextureModeRow.modeSlider, @"zs_exp_key", @"IntermediateTextureMode", OBJC_ASSOCIATION_RETAIN);
    [expIntermediateTextureModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expIntermediateTextureModeRow];
    NSInteger StoreActionsOptimizationSelIdx, StoreActionsOptimizationDefIdx;
    StoreActionsOptimizationSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"StoreActionsOptimization")));
    StoreActionsOptimizationDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expStoreActionsOptimizationRow = zs_make_mode_slider_row(@"Store Actions Optimization", @[@"Automatic", @"Store", @"Discard"], StoreActionsOptimizationSelIdx, StoreActionsOptimizationDefIdx);
    objc_setAssociatedObject(expStoreActionsOptimizationRow.modeSlider, @"zs_exp_key", @"StoreActionsOptimization", OBJC_ASSOCIATION_RETAIN);
    [expStoreActionsOptimizationRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expStoreActionsOptimizationRow];
    ZSRow *expConservativeEnclosingSphereRow = zs_make_switch_row(@"Conservative Enclosing Sphere", zs_exp_get_bool(@"ConservativeEnclosingSphere"));
    objc_setAssociatedObject(expConservativeEnclosingSphereRow.toggle, @"zs_exp_key", @"ConservativeEnclosingSphere", OBJC_ASSOCIATION_RETAIN);
    [expConservativeEnclosingSphereRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expConservativeEnclosingSphereRow];
    ZSRow *expNumIterationsEnclosingSphereRow = zs_make_slider_row(@"Num Iterations Enclosing Sphere", 1, 256, zs_exp_get_number(@"NumIterationsEnclosingSphere"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expNumIterationsEnclosingSphereRow.slider.defaultValue = zs_exp_get_default_number(@"NumIterationsEnclosingSphere");
    expNumIterationsEnclosingSphereRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expNumIterationsEnclosingSphereRow.slider, @"zs_exp_key", @"NumIterationsEnclosingSphere", OBJC_ASSOCIATION_RETAIN);
    [expNumIterationsEnclosingSphereRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expNumIterationsEnclosingSphereRow];
    NSInteger ShaderVariantLogLevelSelIdx, ShaderVariantLogLevelDefIdx;
    ShaderVariantLogLevelSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ShaderVariantLogLevel")));
    ShaderVariantLogLevelDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expShaderVariantLogLevelRow = zs_make_mode_slider_row(@"Shader Variant Log Level", @[@"Disabled", @"URP Shaders Only", @"All Shaders"], ShaderVariantLogLevelSelIdx, ShaderVariantLogLevelDefIdx);
    objc_setAssociatedObject(expShaderVariantLogLevelRow.modeSlider, @"zs_exp_key", @"ShaderVariantLogLevel", OBJC_ASSOCIATION_RETAIN);
    [expShaderVariantLogLevelRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShaderVariantLogLevelRow];
    ZSRow *expGraphicsSRPBatchingRow = zs_make_switch_row(@"Graphics SRP Batching", zs_exp_get_bool(@"GraphicsSRPBatching"));
    objc_setAssociatedObject(expGraphicsSRPBatchingRow.toggle, @"zs_exp_key", @"GraphicsSRPBatching", OBJC_ASSOCIATION_RETAIN);
    [expGraphicsSRPBatchingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expGraphicsSRPBatchingRow];
    ZSRow *expLightsUseLinearIntensityRow = zs_make_switch_row(@"Lights Use Linear Intensity", zs_exp_get_bool(@"LightsUseLinearIntensity"));
    objc_setAssociatedObject(expLightsUseLinearIntensityRow.toggle, @"zs_exp_key", @"LightsUseLinearIntensity", OBJC_ASSOCIATION_RETAIN);
    [expLightsUseLinearIntensityRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLightsUseLinearIntensityRow];
    ZSRow *expLightsUseColorTemperatureRow = zs_make_switch_row(@"Lights Use Color Temperature", zs_exp_get_bool(@"LightsUseColorTemperature"));
    objc_setAssociatedObject(expLightsUseColorTemperatureRow.toggle, @"zs_exp_key", @"LightsUseColorTemperature", OBJC_ASSOCIATION_RETAIN);
    [expLightsUseColorTemperatureRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLightsUseColorTemperatureRow];
    ZSRow *expBurstCompilationRow = zs_make_switch_row(@"Burst Compilation", zs_exp_get_bool(@"BurstCompilation"));
    objc_setAssociatedObject(expBurstCompilationRow.toggle, @"zs_exp_key", @"BurstCompilation", OBJC_ASSOCIATION_RETAIN);
    [expBurstCompilationRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expBurstCompilationRow];
    ZSRow *expBurstSafetyChecksRow = zs_make_switch_row(@"Burst Safety Checks", zs_exp_get_bool(@"BurstSafetyChecks"));
    objc_setAssociatedObject(expBurstSafetyChecksRow.toggle, @"zs_exp_key", @"BurstSafetyChecks", OBJC_ASSOCIATION_RETAIN);
    [expBurstSafetyChecksRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expBurstSafetyChecksRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Light Probes", self);
    NSInteger ShEvalModeSelIdx, ShEvalModeDefIdx;
    ShEvalModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ShEvalMode")));
    ShEvalModeDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expShEvalModeRow = zs_make_mode_slider_row(@"SH Eval Mode", @[@"Automatic", @"Per Vertex", @"Per Pixel"], ShEvalModeSelIdx, ShEvalModeDefIdx);
    objc_setAssociatedObject(expShEvalModeRow.modeSlider, @"zs_exp_key", @"ShEvalMode", OBJC_ASSOCIATION_RETAIN);
    [expShEvalModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShEvalModeRow];
    NSInteger LightProbeSystemSelIdx, LightProbeSystemDefIdx;
    LightProbeSystemSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"LightProbeSystem")));
    LightProbeSystemDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expLightProbeSystemRow = zs_make_mode_slider_row(@"Light Probe System", @[@"Legacy Light Probes", @"Adaptive Probe Volumes"], LightProbeSystemSelIdx, LightProbeSystemDefIdx);
    objc_setAssociatedObject(expLightProbeSystemRow.modeSlider, @"zs_exp_key", @"LightProbeSystem", OBJC_ASSOCIATION_RETAIN);
    [expLightProbeSystemRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expLightProbeSystemRow];
    NSInteger ProbeVolumeMemoryBudgetSelIdx, ProbeVolumeMemoryBudgetDefIdx;
    ProbeVolumeMemoryBudgetSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ProbeVolumeMemoryBudget")));
    ProbeVolumeMemoryBudgetDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expProbeVolumeMemoryBudgetRow = zs_make_mode_slider_row(@"Probe Volume Memory Budget", @[@"Low", @"Medium", @"High"], ProbeVolumeMemoryBudgetSelIdx, ProbeVolumeMemoryBudgetDefIdx);
    objc_setAssociatedObject(expProbeVolumeMemoryBudgetRow.modeSlider, @"zs_exp_key", @"ProbeVolumeMemoryBudget", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeMemoryBudgetRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeMemoryBudgetRow];
    NSInteger ProbeVolumeBlendingMemoryBudgetSelIdx, ProbeVolumeBlendingMemoryBudgetDefIdx;
    ProbeVolumeBlendingMemoryBudgetSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ProbeVolumeBlendingMemoryBudget")));
    ProbeVolumeBlendingMemoryBudgetDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expProbeVolumeBlendingMemoryBudgetRow = zs_make_mode_slider_row(@"Probe Volume Blending Memory Budget", @[@"Low", @"Medium", @"High"], ProbeVolumeBlendingMemoryBudgetSelIdx, ProbeVolumeBlendingMemoryBudgetDefIdx);
    objc_setAssociatedObject(expProbeVolumeBlendingMemoryBudgetRow.modeSlider, @"zs_exp_key", @"ProbeVolumeBlendingMemoryBudget", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeBlendingMemoryBudgetRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeBlendingMemoryBudgetRow];
    ZSRow *expProbeVolumeStreamingRow = zs_make_switch_row(@"Probe Volume Streaming", zs_exp_get_bool(@"ProbeVolumeStreaming"));
    objc_setAssociatedObject(expProbeVolumeStreamingRow.toggle, @"zs_exp_key", @"ProbeVolumeStreaming", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeStreamingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeStreamingRow];
    ZSRow *expProbeVolumeGPUStreamingRow = zs_make_switch_row(@"Probe Volume G P U Streaming", zs_exp_get_bool(@"ProbeVolumeGPUStreaming"));
    objc_setAssociatedObject(expProbeVolumeGPUStreamingRow.toggle, @"zs_exp_key", @"ProbeVolumeGPUStreaming", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeGPUStreamingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeGPUStreamingRow];
    ZSRow *expProbeVolumeDiskStreamingRow = zs_make_switch_row(@"Probe Volume Disk Streaming", zs_exp_get_bool(@"ProbeVolumeDiskStreaming"));
    objc_setAssociatedObject(expProbeVolumeDiskStreamingRow.toggle, @"zs_exp_key", @"ProbeVolumeDiskStreaming", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeDiskStreamingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeDiskStreamingRow];
    ZSRow *expProbeVolumeScenariosRow = zs_make_switch_row(@"Probe Volume Scenarios", zs_exp_get_bool(@"ProbeVolumeScenarios"));
    objc_setAssociatedObject(expProbeVolumeScenariosRow.toggle, @"zs_exp_key", @"ProbeVolumeScenarios", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeScenariosRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeScenariosRow];
    ZSRow *expProbeVolumeScenarioBlendingRow = zs_make_switch_row(@"Probe Volume Scenario Blending", zs_exp_get_bool(@"ProbeVolumeScenarioBlending"));
    objc_setAssociatedObject(expProbeVolumeScenarioBlendingRow.toggle, @"zs_exp_key", @"ProbeVolumeScenarioBlending", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeScenarioBlendingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeScenarioBlendingRow];
    NSInteger ProbeVolumeSHBandsSelIdx, ProbeVolumeSHBandsDefIdx;
    ProbeVolumeSHBandsSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"ProbeVolumeSHBands")));
    ProbeVolumeSHBandsDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expProbeVolumeSHBandsRow = zs_make_mode_slider_row(@"Probe Volume SH Bands", @[@"L1 (Linear)", @"L2 (Quadratic)"], ProbeVolumeSHBandsSelIdx, ProbeVolumeSHBandsDefIdx);
    objc_setAssociatedObject(expProbeVolumeSHBandsRow.modeSlider, @"zs_exp_key", @"ProbeVolumeSHBands", OBJC_ASSOCIATION_RETAIN);
    [expProbeVolumeSHBandsRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expProbeVolumeSHBandsRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Shadows", self);
    NSInteger AdditionalShadowTierLowSelIdx, AdditionalShadowTierLowDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"AdditionalShadowTierLow"); AdditionalShadowTierLowSelIdx = zs_exp_idx_AdditionalShadowTierLow(v); }
    AdditionalShadowTierLowDefIdx = zs_exp_idx_AdditionalShadowTierLow(256);
    ZSRow *expAdditionalShadowTierLowRow = zs_make_mode_slider_row(@"Additional Shadow Tier Low", @[@"256", @"512", @"1024", @"2048"], AdditionalShadowTierLowSelIdx, AdditionalShadowTierLowDefIdx);
    objc_setAssociatedObject(expAdditionalShadowTierLowRow.modeSlider, @"zs_exp_key", @"AdditionalShadowTierLow", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalShadowTierLowRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalShadowTierLowRow];
    NSInteger AdditionalShadowTierMediumSelIdx, AdditionalShadowTierMediumDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"AdditionalShadowTierMedium"); AdditionalShadowTierMediumSelIdx = zs_exp_idx_AdditionalShadowTierMedium(v); }
    AdditionalShadowTierMediumDefIdx = zs_exp_idx_AdditionalShadowTierMedium(512);
    ZSRow *expAdditionalShadowTierMediumRow = zs_make_mode_slider_row(@"Additional Shadow Tier Medium", @[@"256", @"512", @"1024", @"2048"], AdditionalShadowTierMediumSelIdx, AdditionalShadowTierMediumDefIdx);
    objc_setAssociatedObject(expAdditionalShadowTierMediumRow.modeSlider, @"zs_exp_key", @"AdditionalShadowTierMedium", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalShadowTierMediumRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalShadowTierMediumRow];
    NSInteger AdditionalShadowTierHighSelIdx, AdditionalShadowTierHighDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"AdditionalShadowTierHigh"); AdditionalShadowTierHighSelIdx = zs_exp_idx_AdditionalShadowTierHigh(v); }
    AdditionalShadowTierHighDefIdx = zs_exp_idx_AdditionalShadowTierHigh(1024);
    ZSRow *expAdditionalShadowTierHighRow = zs_make_mode_slider_row(@"Additional Shadow Tier High", @[@"256", @"512", @"1024", @"2048"], AdditionalShadowTierHighSelIdx, AdditionalShadowTierHighDefIdx);
    objc_setAssociatedObject(expAdditionalShadowTierHighRow.modeSlider, @"zs_exp_key", @"AdditionalShadowTierHigh", OBJC_ASSOCIATION_RETAIN);
    [expAdditionalShadowTierHighRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdditionalShadowTierHighRow];
    NSInteger SoftShadowQualitySelIdx, SoftShadowQualityDefIdx;
    SoftShadowQualitySelIdx = MAX(0, MIN(3, (NSInteger)zs_exp_get_number(@"SoftShadowQuality")));
    SoftShadowQualityDefIdx = MAX(0, MIN(3, (NSInteger)0));
    ZSRow *expSoftShadowQualityRow = zs_make_mode_slider_row(@"Soft Shadow Quality", @[@"Use Pipeline Settings", @"Low", @"Medium", @"High"], SoftShadowQualitySelIdx, SoftShadowQualityDefIdx);
    objc_setAssociatedObject(expSoftShadowQualityRow.modeSlider, @"zs_exp_key", @"SoftShadowQuality", OBJC_ASSOCIATION_RETAIN);
    [expSoftShadowQualityRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expSoftShadowQualityRow];
    ZSRow *expShadowDistanceRow = zs_make_slider_row(@"Shadow Distance", 0, 500, zs_exp_get_number(@"ShadowDistance"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expShadowDistanceRow.slider.defaultValue = zs_exp_get_default_number(@"ShadowDistance");
    expShadowDistanceRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expShadowDistanceRow.slider, @"zs_exp_key", @"ShadowDistance", OBJC_ASSOCIATION_RETAIN);
    [expShadowDistanceRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowDistanceRow];
    NSInteger ShadowCascadesSelIdx, ShadowCascadesDefIdx;
    ShadowCascadesSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ShadowCascades")));
    ShadowCascadesDefIdx = MAX(0, MIN(2, (NSInteger)2));
    ZSRow *expShadowCascadesRow = zs_make_mode_slider_row(@"Shadow Cascades", @[@"No Cascades", @"Two Cascades", @"Four Cascades"], ShadowCascadesSelIdx, ShadowCascadesDefIdx);
    objc_setAssociatedObject(expShadowCascadesRow.modeSlider, @"zs_exp_key", @"ShadowCascades", OBJC_ASSOCIATION_RETAIN);
    [expShadowCascadesRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowCascadesRow];
    ZSRow *expCascadeBorderRow = zs_make_slider_row(@"Cascade Border", 0.0, 1.0, zs_exp_get_number(@"CascadeBorder"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expCascadeBorderRow.slider.defaultValue = zs_exp_get_default_number(@"CascadeBorder");
    expCascadeBorderRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascadeBorderRow.slider, @"zs_exp_key", @"CascadeBorder", OBJC_ASSOCIATION_RETAIN);
    [expCascadeBorderRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascadeBorderRow];
    ZSRow *expShadowDepthBiasRow = zs_make_slider_row(@"Shadow Depth Bias", 0.0, 5.0, zs_exp_get_number(@"ShadowDepthBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expShadowDepthBiasRow.slider.defaultValue = zs_exp_get_default_number(@"ShadowDepthBias");
    expShadowDepthBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expShadowDepthBiasRow.slider, @"zs_exp_key", @"ShadowDepthBias", OBJC_ASSOCIATION_RETAIN);
    [expShadowDepthBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowDepthBiasRow];
    ZSRow *expShadowNormalBiasRow = zs_make_slider_row(@"Shadow Normal Bias", 0.0, 5.0, zs_exp_get_number(@"ShadowNormalBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expShadowNormalBiasRow.slider.defaultValue = zs_exp_get_default_number(@"ShadowNormalBias");
    expShadowNormalBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expShadowNormalBiasRow.slider, @"zs_exp_key", @"ShadowNormalBias", OBJC_ASSOCIATION_RETAIN);
    [expShadowNormalBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowNormalBiasRow];
    ZSRow *expSoftShadowsRow = zs_make_switch_row(@"Soft Shadows", zs_exp_get_bool(@"SoftShadows"));
    objc_setAssociatedObject(expSoftShadowsRow.toggle, @"zs_exp_key", @"SoftShadows", OBJC_ASSOCIATION_RETAIN);
    [expSoftShadowsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expSoftShadowsRow];
    NSInteger ShadowCascadeOptionSelIdx, ShadowCascadeOptionDefIdx;
    ShadowCascadeOptionSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"ShadowCascadeOption")));
    ShadowCascadeOptionDefIdx = MAX(0, MIN(2, (NSInteger)2));
    ZSRow *expShadowCascadeOptionRow = zs_make_mode_slider_row(@"Shadow Cascade Option", @[@"No Cascades", @"Two Cascades", @"Four Cascades"], ShadowCascadeOptionSelIdx, ShadowCascadeOptionDefIdx);
    objc_setAssociatedObject(expShadowCascadeOptionRow.modeSlider, @"zs_exp_key", @"ShadowCascadeOption", OBJC_ASSOCIATION_RETAIN);
    [expShadowCascadeOptionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expShadowCascadeOptionRow];
    ZSRow *expCascade2SplitRow = zs_make_slider_row(@"Cascade2 Split", 0.0, 1.0, zs_exp_get_number(@"Cascade2Split"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade2SplitRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade2Split");
    expCascade2SplitRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade2SplitRow.slider, @"zs_exp_key", @"Cascade2Split", OBJC_ASSOCIATION_RETAIN);
    [expCascade2SplitRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade2SplitRow];
    ZSRow *expCascade3SplitXRow = zs_make_slider_row(@"Cascade3 Split X", 0.0, 1.0, zs_exp_get_number(@"Cascade3SplitX"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade3SplitXRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade3SplitX");
    expCascade3SplitXRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade3SplitXRow.slider, @"zs_exp_key", @"Cascade3SplitX", OBJC_ASSOCIATION_RETAIN);
    [expCascade3SplitXRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade3SplitXRow];
    ZSRow *expCascade3SplitYRow = zs_make_slider_row(@"Cascade3 Split Y", 0.0, 1.0, zs_exp_get_number(@"Cascade3SplitY"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade3SplitYRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade3SplitY");
    expCascade3SplitYRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade3SplitYRow.slider, @"zs_exp_key", @"Cascade3SplitY", OBJC_ASSOCIATION_RETAIN);
    [expCascade3SplitYRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade3SplitYRow];
    ZSRow *expCascade4SplitXRow = zs_make_slider_row(@"Cascade4 Split X", 0.0, 1.0, zs_exp_get_number(@"Cascade4SplitX"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade4SplitXRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade4SplitX");
    expCascade4SplitXRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade4SplitXRow.slider, @"zs_exp_key", @"Cascade4SplitX", OBJC_ASSOCIATION_RETAIN);
    [expCascade4SplitXRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade4SplitXRow];
    ZSRow *expCascade4SplitYRow = zs_make_slider_row(@"Cascade4 Split Y", 0.0, 1.0, zs_exp_get_number(@"Cascade4SplitY"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade4SplitYRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade4SplitY");
    expCascade4SplitYRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade4SplitYRow.slider, @"zs_exp_key", @"Cascade4SplitY", OBJC_ASSOCIATION_RETAIN);
    [expCascade4SplitYRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade4SplitYRow];
    ZSRow *expCascade4SplitZRow = zs_make_slider_row(@"Cascade4 Split Z", 0.0, 1.0, zs_exp_get_number(@"Cascade4SplitZ"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expCascade4SplitZRow.slider.defaultValue = zs_exp_get_default_number(@"Cascade4SplitZ");
    expCascade4SplitZRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expCascade4SplitZRow.slider, @"zs_exp_key", @"Cascade4SplitZ", OBJC_ASSOCIATION_RETAIN);
    [expCascade4SplitZRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expCascade4SplitZRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Adaptive Performance", self);
    ZSRow *expAdaptivePerformanceRow = zs_make_switch_row(@"Adaptive Performance", zs_exp_get_bool(@"AdaptivePerformance"));
    self.expAdaptivePerformanceToggle = expAdaptivePerformanceRow.toggle;
    objc_setAssociatedObject(expAdaptivePerformanceRow.toggle, @"zs_exp_key", @"AdaptivePerformance", OBJC_ASSOCIATION_RETAIN);
    [expAdaptivePerformanceRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdaptivePerformanceRow];
    ZSRow *expAPMaxShadowDistanceMultiplierRow = zs_make_slider_row(@"AP Max Shadow Distance Mult.", 0.0, 2.0, zs_exp_get_number(@"APMaxShadowDistanceMultiplier"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expAPMaxShadowDistanceMultiplierRow.slider.defaultValue = zs_exp_get_default_number(@"APMaxShadowDistanceMultiplier");
    expAPMaxShadowDistanceMultiplierRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAPMaxShadowDistanceMultiplierRow.slider, @"zs_exp_key", @"APMaxShadowDistanceMultiplier", OBJC_ASSOCIATION_RETAIN);
    [expAPMaxShadowDistanceMultiplierRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPMaxShadowDistanceMultiplierRow];
    ZSRow *expAPShadowmapResolutionMultiplierRow = zs_make_slider_row(@"AP Shadowmap Resolution Mult.", 0.0, 2.0, zs_exp_get_number(@"APShadowmapResolutionMultiplier"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expAPShadowmapResolutionMultiplierRow.slider.defaultValue = zs_exp_get_default_number(@"APShadowmapResolutionMultiplier");
    expAPShadowmapResolutionMultiplierRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAPShadowmapResolutionMultiplierRow.slider, @"zs_exp_key", @"APShadowmapResolutionMultiplier", OBJC_ASSOCIATION_RETAIN);
    [expAPShadowmapResolutionMultiplierRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPShadowmapResolutionMultiplierRow];
    ZSRow *expAPDecalsDrawDistanceRow = zs_make_slider_row(@"AP Decals Draw Distance", 0, 1000, zs_exp_get_number(@"APDecalsDrawDistance"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; });
    expAPDecalsDrawDistanceRow.slider.defaultValue = zs_exp_get_default_number(@"APDecalsDrawDistance");
    expAPDecalsDrawDistanceRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAPDecalsDrawDistanceRow.slider, @"zs_exp_key", @"APDecalsDrawDistance", OBJC_ASSOCIATION_RETAIN);
    [expAPDecalsDrawDistanceRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPDecalsDrawDistanceRow];
    NSInteger APShadowCascadesBiasSelIdx, APShadowCascadesBiasDefIdx;
    APShadowCascadesBiasSelIdx = MAX(0, MIN(4, (NSInteger)zs_exp_get_number(@"APShadowCascadesBias")));
    APShadowCascadesBiasDefIdx = MAX(0, MIN(4, (NSInteger)0));
    ZSRow *expAPShadowCascadesBiasRow = zs_make_mode_slider_row(@"AP Shadow Cascades Bias", @[@"0", @"1", @"2", @"3", @"4"], APShadowCascadesBiasSelIdx, APShadowCascadesBiasDefIdx);
    objc_setAssociatedObject(expAPShadowCascadesBiasRow.modeSlider, @"zs_exp_key", @"APShadowCascadesBias", OBJC_ASSOCIATION_RETAIN);
    [expAPShadowCascadesBiasRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPShadowCascadesBiasRow];
    NSInteger APShadowQualityBiasSelIdx, APShadowQualityBiasDefIdx;
    APShadowQualityBiasSelIdx = MAX(0, MIN(4, (NSInteger)zs_exp_get_number(@"APShadowQualityBias")));
    APShadowQualityBiasDefIdx = MAX(0, MIN(4, (NSInteger)0));
    ZSRow *expAPShadowQualityBiasRow = zs_make_mode_slider_row(@"AP Shadow Quality Bias", @[@"0", @"1", @"2", @"3", @"4"], APShadowQualityBiasSelIdx, APShadowQualityBiasDefIdx);
    objc_setAssociatedObject(expAPShadowQualityBiasRow.modeSlider, @"zs_exp_key", @"APShadowQualityBias", OBJC_ASSOCIATION_RETAIN);
    [expAPShadowQualityBiasRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPShadowQualityBiasRow];
    ZSRow *expAPLutBiasRow = zs_make_slider_row(@"AP LUT Bias", 0.0, 2.0, zs_exp_get_number(@"APLutBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expAPLutBiasRow.slider.defaultValue = zs_exp_get_default_number(@"APLutBias");
    expAPLutBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAPLutBiasRow.slider, @"zs_exp_key", @"APLutBias", OBJC_ASSOCIATION_RETAIN);
    [expAPLutBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPLutBiasRow];
    NSInteger APAntiAliasingQualityBiasSelIdx, APAntiAliasingQualityBiasDefIdx;
    APAntiAliasingQualityBiasSelIdx = MAX(0, MIN(4, (NSInteger)zs_exp_get_number(@"APAntiAliasingQualityBias")));
    APAntiAliasingQualityBiasDefIdx = MAX(0, MIN(4, (NSInteger)0));
    ZSRow *expAPAntiAliasingQualityBiasRow = zs_make_mode_slider_row(@"AP Anti-Aliasing Quality Bias", @[@"0", @"1", @"2", @"3", @"4"], APAntiAliasingQualityBiasSelIdx, APAntiAliasingQualityBiasDefIdx);
    objc_setAssociatedObject(expAPAntiAliasingQualityBiasRow.modeSlider, @"zs_exp_key", @"APAntiAliasingQualityBias", OBJC_ASSOCIATION_RETAIN);
    [expAPAntiAliasingQualityBiasRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPAntiAliasingQualityBiasRow];
    ZSRow *expAPSkipDynamicBatchingRow = zs_make_switch_row(@"AP Skip Dynamic Batching", zs_exp_get_bool(@"APSkipDynamicBatching"));
    objc_setAssociatedObject(expAPSkipDynamicBatchingRow.toggle, @"zs_exp_key", @"APSkipDynamicBatching", OBJC_ASSOCIATION_RETAIN);
    [expAPSkipDynamicBatchingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPSkipDynamicBatchingRow];
    ZSRow *expAPSkipFrontToBackSortingRow = zs_make_switch_row(@"AP Skip Front-To-Back Sorting", zs_exp_get_bool(@"APSkipFrontToBackSorting"));
    objc_setAssociatedObject(expAPSkipFrontToBackSortingRow.toggle, @"zs_exp_key", @"APSkipFrontToBackSorting", OBJC_ASSOCIATION_RETAIN);
    [expAPSkipFrontToBackSortingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPSkipFrontToBackSortingRow];
    ZSRow *expAPSkipTransparentObjectsRow = zs_make_switch_row(@"AP Skip Transparent Objects", zs_exp_get_bool(@"APSkipTransparentObjects"));
    objc_setAssociatedObject(expAPSkipTransparentObjectsRow.toggle, @"zs_exp_key", @"APSkipTransparentObjects", OBJC_ASSOCIATION_RETAIN);
    [expAPSkipTransparentObjectsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAPSkipTransparentObjectsRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Particles & Animator", self);
    ZSRow *expParticleGPUInstancingRow = zs_make_switch_row(@"Particle GPU Instancing", zs_exp_get_bool(@"ParticleGPUInstancing"));
    objc_setAssociatedObject(expParticleGPUInstancingRow.toggle, @"zs_exp_key", @"ParticleGPUInstancing", OBJC_ASSOCIATION_RETAIN);
    [expParticleGPUInstancingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleGPUInstancingRow];
    NSInteger ParticleMeshDistributionSelIdx, ParticleMeshDistributionDefIdx;
    ParticleMeshDistributionSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"ParticleMeshDistribution")));
    ParticleMeshDistributionDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expParticleMeshDistributionRow = zs_make_mode_slider_row(@"Particle Mesh Distribution", @[@"Uniform", @"Weighted By Shape"], ParticleMeshDistributionSelIdx, ParticleMeshDistributionDefIdx);
    objc_setAssociatedObject(expParticleMeshDistributionRow.modeSlider, @"zs_exp_key", @"ParticleMeshDistribution", OBJC_ASSOCIATION_RETAIN);
    [expParticleMeshDistributionRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleMeshDistributionRow];
    ZSRow *expParticleLengthScaleRow = zs_make_slider_row(@"Particle Length Scale", 0.0, 20.0, zs_exp_get_number(@"ParticleLengthScale"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleLengthScaleRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleLengthScale");
    expParticleLengthScaleRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleLengthScaleRow.slider, @"zs_exp_key", @"ParticleLengthScale", OBJC_ASSOCIATION_RETAIN);
    [expParticleLengthScaleRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleLengthScaleRow];
    ZSRow *expParticleVelocityScaleRow = zs_make_slider_row(@"Particle Velocity Scale", 0.0, 5.0, zs_exp_get_number(@"ParticleVelocityScale"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleVelocityScaleRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleVelocityScale");
    expParticleVelocityScaleRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleVelocityScaleRow.slider, @"zs_exp_key", @"ParticleVelocityScale", OBJC_ASSOCIATION_RETAIN);
    [expParticleVelocityScaleRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleVelocityScaleRow];
    ZSRow *expParticleCameraVelocityScaleRow = zs_make_slider_row(@"Particle Camera Velocity Scale", 0.0, 5.0, zs_exp_get_number(@"ParticleCameraVelocityScale"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleCameraVelocityScaleRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleCameraVelocityScale");
    expParticleCameraVelocityScaleRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleCameraVelocityScaleRow.slider, @"zs_exp_key", @"ParticleCameraVelocityScale", OBJC_ASSOCIATION_RETAIN);
    [expParticleCameraVelocityScaleRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleCameraVelocityScaleRow];
    ZSRow *expParticleNormalDirectionRow = zs_make_slider_row(@"Particle Normal Direction", 0.0, 3.0, zs_exp_get_number(@"ParticleNormalDirection"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleNormalDirectionRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleNormalDirection");
    expParticleNormalDirectionRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleNormalDirectionRow.slider, @"zs_exp_key", @"ParticleNormalDirection", OBJC_ASSOCIATION_RETAIN);
    [expParticleNormalDirectionRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleNormalDirectionRow];
    ZSRow *expParticleShadowBiasRow = zs_make_slider_row(@"Particle Shadow Bias", 0.0, 2.0, zs_exp_get_number(@"ParticleShadowBias"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expParticleShadowBiasRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleShadowBias");
    expParticleShadowBiasRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleShadowBiasRow.slider, @"zs_exp_key", @"ParticleShadowBias", OBJC_ASSOCIATION_RETAIN);
    [expParticleShadowBiasRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleShadowBiasRow];
    ZSRow *expParticleSortingFudgeRow = zs_make_slider_row(@"Particle Sorting Fudge", -100.0, 100.0, zs_exp_get_number(@"ParticleSortingFudge"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.1f", v]; });
    expParticleSortingFudgeRow.slider.defaultValue = zs_exp_get_default_number(@"ParticleSortingFudge");
    expParticleSortingFudgeRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expParticleSortingFudgeRow.slider, @"zs_exp_key", @"ParticleSortingFudge", OBJC_ASSOCIATION_RETAIN);
    [expParticleSortingFudgeRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleSortingFudgeRow];
    ZSRow *expParticleAllowRollRow = zs_make_switch_row(@"Particle Allow Roll", zs_exp_get_bool(@"ParticleAllowRoll"));
    objc_setAssociatedObject(expParticleAllowRollRow.toggle, @"zs_exp_key", @"ParticleAllowRoll", OBJC_ASSOCIATION_RETAIN);
    [expParticleAllowRollRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleAllowRollRow];
    ZSRow *expParticleRotateWithStretchDirectionRow = zs_make_switch_row(@"Particle Rotate With Stretch Direction", zs_exp_get_bool(@"ParticleRotateWithStretchDirection"));
    objc_setAssociatedObject(expParticleRotateWithStretchDirectionRow.toggle, @"zs_exp_key", @"ParticleRotateWithStretchDirection", OBJC_ASSOCIATION_RETAIN);
    [expParticleRotateWithStretchDirectionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleRotateWithStretchDirectionRow];
    ZSRow *expParticleApplyActiveColorSpaceRow = zs_make_switch_row(@"Particle Apply Active Color Space", zs_exp_get_bool(@"ParticleApplyActiveColorSpace"));
    objc_setAssociatedObject(expParticleApplyActiveColorSpaceRow.toggle, @"zs_exp_key", @"ParticleApplyActiveColorSpace", OBJC_ASSOCIATION_RETAIN);
    [expParticleApplyActiveColorSpaceRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expParticleApplyActiveColorSpaceRow];
    NSInteger AnimatorCullingModeSelIdx, AnimatorCullingModeDefIdx;
    AnimatorCullingModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"AnimatorCullingMode")));
    AnimatorCullingModeDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expAnimatorCullingModeRow = zs_make_mode_slider_row(@"Animator Culling Mode", @[@"Always Animate", @"Cull Update Transforms", @"Cull Completely"], AnimatorCullingModeSelIdx, AnimatorCullingModeDefIdx);
    objc_setAssociatedObject(expAnimatorCullingModeRow.modeSlider, @"zs_exp_key", @"AnimatorCullingMode", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorCullingModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorCullingModeRow];
    NSInteger AnimatorUpdateModeSelIdx, AnimatorUpdateModeDefIdx;
    AnimatorUpdateModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"AnimatorUpdateMode")));
    AnimatorUpdateModeDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expAnimatorUpdateModeRow = zs_make_mode_slider_row(@"Animator Update Mode", @[@"Normal", @"Animate Physics", @"Unscaled Time"], AnimatorUpdateModeSelIdx, AnimatorUpdateModeDefIdx);
    objc_setAssociatedObject(expAnimatorUpdateModeRow.modeSlider, @"zs_exp_key", @"AnimatorUpdateMode", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorUpdateModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorUpdateModeRow];
    ZSRow *expAnimatorApplyRootMotionRow = zs_make_switch_row(@"Animator Apply Root Motion", zs_exp_get_bool(@"AnimatorApplyRootMotion"));
    objc_setAssociatedObject(expAnimatorApplyRootMotionRow.toggle, @"zs_exp_key", @"AnimatorApplyRootMotion", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorApplyRootMotionRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorApplyRootMotionRow];
    ZSRow *expAnimatorLinearVelocityBlendingRow = zs_make_switch_row(@"Animator Linear Velocity Blending", zs_exp_get_bool(@"AnimatorLinearVelocityBlending"));
    objc_setAssociatedObject(expAnimatorLinearVelocityBlendingRow.toggle, @"zs_exp_key", @"AnimatorLinearVelocityBlending", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorLinearVelocityBlendingRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorLinearVelocityBlendingRow];
    ZSRow *expAnimatorAnimatePhysicsRow = zs_make_switch_row(@"Animator Animate Physics", zs_exp_get_bool(@"AnimatorAnimatePhysics"));
    objc_setAssociatedObject(expAnimatorAnimatePhysicsRow.toggle, @"zs_exp_key", @"AnimatorAnimatePhysics", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorAnimatePhysicsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorAnimatePhysicsRow];
    ZSRow *expAnimatorConstantClipSamplingOptimizationRow = zs_make_switch_row(@"Animator Constant Clip Sampling Optimization", zs_exp_get_bool(@"AnimatorConstantClipSamplingOptimization"));
    objc_setAssociatedObject(expAnimatorConstantClipSamplingOptimizationRow.toggle, @"zs_exp_key", @"AnimatorConstantClipSamplingOptimization", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorConstantClipSamplingOptimizationRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorConstantClipSamplingOptimizationRow];
    ZSRow *expAnimatorStabilizeFeetRow = zs_make_switch_row(@"Animator Stabilize Feet", zs_exp_get_bool(@"AnimatorStabilizeFeet"));
    objc_setAssociatedObject(expAnimatorStabilizeFeetRow.toggle, @"zs_exp_key", @"AnimatorStabilizeFeet", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorStabilizeFeetRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorStabilizeFeetRow];
    ZSRow *expAnimatorSpeedRow = zs_make_slider_row(@"Animator Speed", 0.0, 3.0, zs_exp_get_number(@"AnimatorSpeed"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expAnimatorSpeedRow.slider.defaultValue = zs_exp_get_default_number(@"AnimatorSpeed");
    expAnimatorSpeedRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expAnimatorSpeedRow.slider, @"zs_exp_key", @"AnimatorSpeed", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorSpeedRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorSpeedRow];
    ZSRow *expAnimatorLogWarningsRow = zs_make_switch_row(@"Animator Log Warnings", zs_exp_get_bool(@"AnimatorLogWarnings"));
    objc_setAssociatedObject(expAnimatorLogWarningsRow.toggle, @"zs_exp_key", @"AnimatorLogWarnings", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorLogWarningsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorLogWarningsRow];
    ZSRow *expAnimatorFireEventsRow = zs_make_switch_row(@"Animator Fire Events", zs_exp_get_bool(@"AnimatorFireEvents"));
    objc_setAssociatedObject(expAnimatorFireEventsRow.toggle, @"zs_exp_key", @"AnimatorFireEvents", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorFireEventsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorFireEventsRow];
    ZSRow *expAnimatorWriteDefaultValuesOnDisableRow = zs_make_switch_row(@"Animator Write Default Values On Disable", zs_exp_get_bool(@"AnimatorWriteDefaultValuesOnDisable"));
    objc_setAssociatedObject(expAnimatorWriteDefaultValuesOnDisableRow.toggle, @"zs_exp_key", @"AnimatorWriteDefaultValuesOnDisable", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorWriteDefaultValuesOnDisableRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorWriteDefaultValuesOnDisableRow];
    ZSRow *expAnimatorKeepStateOnDisableRow = zs_make_switch_row(@"Animator Keep State On Disable", zs_exp_get_bool(@"AnimatorKeepStateOnDisable"));
    objc_setAssociatedObject(expAnimatorKeepStateOnDisableRow.toggle, @"zs_exp_key", @"AnimatorKeepStateOnDisable", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorKeepStateOnDisableRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorKeepStateOnDisableRow];
    ZSRow *expAnimatorKeepControllerStateOnDisableRow = zs_make_switch_row(@"Animator Keep Controller State On Disable", zs_exp_get_bool(@"AnimatorKeepControllerStateOnDisable"));
    objc_setAssociatedObject(expAnimatorKeepControllerStateOnDisableRow.toggle, @"zs_exp_key", @"AnimatorKeepControllerStateOnDisable", OBJC_ASSOCIATION_RETAIN);
    [expAnimatorKeepControllerStateOnDisableRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAnimatorKeepControllerStateOnDisableRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    zs_add_section_header(self.experimentalSectionContainer, @"Physics", self);
    NSInteger RigidbodySolverIterationsSelIdx, RigidbodySolverIterationsDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"RigidbodySolverIterations"); RigidbodySolverIterationsSelIdx = zs_exp_idx_RigidbodySolverIterations(v); }
    RigidbodySolverIterationsDefIdx = zs_exp_idx_RigidbodySolverIterations(6);
    ZSRow *expRigidbodySolverIterationsRow = zs_make_mode_slider_row(@"Rigidbody Solver Iterations", @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"10", @"11", @"12"], RigidbodySolverIterationsSelIdx, RigidbodySolverIterationsDefIdx);
    objc_setAssociatedObject(expRigidbodySolverIterationsRow.modeSlider, @"zs_exp_key", @"RigidbodySolverIterations", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodySolverIterationsRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodySolverIterationsRow];
    NSInteger RigidbodySolverVelocityIterationsSelIdx, RigidbodySolverVelocityIterationsDefIdx;
    { int32_t v = (int32_t)zs_exp_get_number(@"RigidbodySolverVelocityIterations"); RigidbodySolverVelocityIterationsSelIdx = zs_exp_idx_RigidbodySolverVelocityIterations(v); }
    RigidbodySolverVelocityIterationsDefIdx = zs_exp_idx_RigidbodySolverVelocityIterations(1);
    ZSRow *expRigidbodySolverVelocityIterationsRow = zs_make_mode_slider_row(@"Rigidbody Solver Velocity Iterations", @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8"], RigidbodySolverVelocityIterationsSelIdx, RigidbodySolverVelocityIterationsDefIdx);
    objc_setAssociatedObject(expRigidbodySolverVelocityIterationsRow.modeSlider, @"zs_exp_key", @"RigidbodySolverVelocityIterations", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodySolverVelocityIterationsRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodySolverVelocityIterationsRow];
    ZSRow *expRigidbodySleepThresholdRow = zs_make_slider_row(@"Rigidbody Sleep Threshold", 0.0, 1.0, zs_exp_get_number(@"RigidbodySleepThreshold"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.3f", v]; });
    expRigidbodySleepThresholdRow.slider.defaultValue = zs_exp_get_default_number(@"RigidbodySleepThreshold");
    expRigidbodySleepThresholdRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbodySleepThresholdRow.slider, @"zs_exp_key", @"RigidbodySleepThreshold", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodySleepThresholdRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodySleepThresholdRow];
    ZSRow *expRigidbodyMaxAngularVelocityRow = zs_make_slider_row(@"Rigidbody Max Angular Velocity", 0.0, 50.0, zs_exp_get_number(@"RigidbodyMaxAngularVelocity"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.1f", v]; });
    expRigidbodyMaxAngularVelocityRow.slider.defaultValue = zs_exp_get_default_number(@"RigidbodyMaxAngularVelocity");
    expRigidbodyMaxAngularVelocityRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbodyMaxAngularVelocityRow.slider, @"zs_exp_key", @"RigidbodyMaxAngularVelocity", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodyMaxAngularVelocityRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodyMaxAngularVelocityRow];
    ZSRow *expRigidbodyMaxLinearVelocityRow = zs_make_slider_row(@"Rigidbody Max Linear Velocity", 0.0, 100.0, zs_exp_get_number(@"RigidbodyMaxLinearVelocity"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.1f", v]; });
    expRigidbodyMaxLinearVelocityRow.slider.defaultValue = zs_exp_get_default_number(@"RigidbodyMaxLinearVelocity");
    expRigidbodyMaxLinearVelocityRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbodyMaxLinearVelocityRow.slider, @"zs_exp_key", @"RigidbodyMaxLinearVelocity", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodyMaxLinearVelocityRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodyMaxLinearVelocityRow];
    NSInteger RigidbodyInterpolationSelIdx, RigidbodyInterpolationDefIdx;
    RigidbodyInterpolationSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"RigidbodyInterpolation")));
    RigidbodyInterpolationDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expRigidbodyInterpolationRow = zs_make_mode_slider_row(@"Rigidbody Interpolation", @[@"None", @"Interpolate", @"Extrapolate"], RigidbodyInterpolationSelIdx, RigidbodyInterpolationDefIdx);
    objc_setAssociatedObject(expRigidbodyInterpolationRow.modeSlider, @"zs_exp_key", @"RigidbodyInterpolation", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodyInterpolationRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodyInterpolationRow];
    ZSRow *expRigidbodyDetectCollisionsRow = zs_make_switch_row(@"Rigidbody Detect Collisions", zs_exp_get_bool(@"RigidbodyDetectCollisions"));
    objc_setAssociatedObject(expRigidbodyDetectCollisionsRow.toggle, @"zs_exp_key", @"RigidbodyDetectCollisions", OBJC_ASSOCIATION_RETAIN);
    [expRigidbodyDetectCollisionsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbodyDetectCollisionsRow];
    ZSRow *expRigidbody2DLinearDampingRow = zs_make_slider_row(@"Rigidbody2D Linear Damping", 0.0, 5.0, zs_exp_get_number(@"Rigidbody2DLinearDamping"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expRigidbody2DLinearDampingRow.slider.defaultValue = zs_exp_get_default_number(@"Rigidbody2DLinearDamping");
    expRigidbody2DLinearDampingRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbody2DLinearDampingRow.slider, @"zs_exp_key", @"Rigidbody2DLinearDamping", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DLinearDampingRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DLinearDampingRow];
    ZSRow *expRigidbody2DAngularDampingRow = zs_make_slider_row(@"Rigidbody2D Angular Damping", 0.0, 5.0, zs_exp_get_number(@"Rigidbody2DAngularDamping"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expRigidbody2DAngularDampingRow.slider.defaultValue = zs_exp_get_default_number(@"Rigidbody2DAngularDamping");
    expRigidbody2DAngularDampingRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbody2DAngularDampingRow.slider, @"zs_exp_key", @"Rigidbody2DAngularDamping", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DAngularDampingRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DAngularDampingRow];
    ZSRow *expRigidbody2DGravityScaleRow = zs_make_slider_row(@"Rigidbody2D Gravity Scale", -5.0, 5.0, zs_exp_get_number(@"Rigidbody2DGravityScale"), ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f", v]; });
    expRigidbody2DGravityScaleRow.slider.defaultValue = zs_exp_get_default_number(@"Rigidbody2DGravityScale");
    expRigidbody2DGravityScaleRow.slider.hasDefaultValue = YES;
    objc_setAssociatedObject(expRigidbody2DGravityScaleRow.slider, @"zs_exp_key", @"Rigidbody2DGravityScale", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DGravityScaleRow.slider addTarget:self action:@selector(expSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DGravityScaleRow];
    NSInteger Rigidbody2DInterpolationSelIdx, Rigidbody2DInterpolationDefIdx;
    Rigidbody2DInterpolationSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"Rigidbody2DInterpolation")));
    Rigidbody2DInterpolationDefIdx = MAX(0, MIN(2, (NSInteger)0));
    ZSRow *expRigidbody2DInterpolationRow = zs_make_mode_slider_row(@"Rigidbody2D Interpolation", @[@"None", @"Interpolate", @"Extrapolate"], Rigidbody2DInterpolationSelIdx, Rigidbody2DInterpolationDefIdx);
    objc_setAssociatedObject(expRigidbody2DInterpolationRow.modeSlider, @"zs_exp_key", @"Rigidbody2DInterpolation", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DInterpolationRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DInterpolationRow];
    NSInteger Rigidbody2DSleepModeSelIdx, Rigidbody2DSleepModeDefIdx;
    Rigidbody2DSleepModeSelIdx = MAX(0, MIN(2, (NSInteger)zs_exp_get_number(@"Rigidbody2DSleepMode")));
    Rigidbody2DSleepModeDefIdx = MAX(0, MIN(2, (NSInteger)1));
    ZSRow *expRigidbody2DSleepModeRow = zs_make_mode_slider_row(@"Rigidbody2D Sleep Mode", @[@"Never Sleep", @"Start Awake", @"Start Asleep"], Rigidbody2DSleepModeSelIdx, Rigidbody2DSleepModeDefIdx);
    objc_setAssociatedObject(expRigidbody2DSleepModeRow.modeSlider, @"zs_exp_key", @"Rigidbody2DSleepMode", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DSleepModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DSleepModeRow];
    NSInteger Rigidbody2DCollisionDetectionModeSelIdx, Rigidbody2DCollisionDetectionModeDefIdx;
    Rigidbody2DCollisionDetectionModeSelIdx = MAX(0, MIN(1, (NSInteger)zs_exp_get_number(@"Rigidbody2DCollisionDetectionMode")));
    Rigidbody2DCollisionDetectionModeDefIdx = MAX(0, MIN(1, (NSInteger)0));
    ZSRow *expRigidbody2DCollisionDetectionModeRow = zs_make_mode_slider_row(@"Rigidbody2D Collision Detection Mode", @[@"Discrete", @"Continuous"], Rigidbody2DCollisionDetectionModeSelIdx, Rigidbody2DCollisionDetectionModeDefIdx);
    objc_setAssociatedObject(expRigidbody2DCollisionDetectionModeRow.modeSlider, @"zs_exp_key", @"Rigidbody2DCollisionDetectionMode", OBJC_ASSOCIATION_RETAIN);
    [expRigidbody2DCollisionDetectionModeRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expRigidbody2DCollisionDetectionModeRow];
    ZSRow *expAdaptivePhysicsRow = zs_make_switch_row(@"Adaptive Physics", zs_exp_get_bool(@"AdaptivePhysics"));
    objc_setAssociatedObject(expAdaptivePhysicsRow.toggle, @"zs_exp_key", @"AdaptivePhysics", OBJC_ASSOCIATION_RETAIN);
    [expAdaptivePhysicsRow.toggle addTarget:self action:@selector(expToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.experimentalSectionContainer addArrangedSubview:expAdaptivePhysicsRow];
    }];

    [self.pendingExperimentalSectionBuilders addObject:^{
    [self zs_applyExperimentalAvailabilityTint];

    zs_add_section_header(self.experimentalSectionContainer, @"Browse All Settings", self);

    self.browseCategoryButton = zs_make_grouped_action_button(self.browseSelectedCategory ?: @"Category: --", zs_accent_green_color());
    [self.browseCategoryButton addTarget:self action:@selector(browseCategoryButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    self.browseClassButton = zs_make_grouped_action_button(self.browseSelectedEntry[@"name"] ?: @"Setting: --", zs_accent_green_color());
    [self.browseClassButton addTarget:self action:@selector(browseClassButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    UIView *browseCard = zs_make_grouped_action_card(@[self.browseCategoryButton, self.browseClassButton]);
    [self.experimentalSectionContainer addArrangedSubview:browseCard];

    self.browseFieldsContainer = [[UIStackView alloc] init];
    self.browseFieldsContainer.axis = UILayoutConstraintAxisVertical;
    self.browseFieldsContainer.spacing = kRowSpacing;
    [self.experimentalSectionContainer addArrangedSubview:self.browseFieldsContainer];
    [self zs_rebuildBrowseFields];
    }];

    [self.pendingSectionBuilders addObject:^{
    UIView *socialLinksSeparator = zs_make_section_separator();
    [self.stack addArrangedSubview:socialLinksSeparator];
    [self.stack setCustomSpacing:kSectionSpacing afterView:self.experimentalSectionContainer];
    [self.stack setCustomSpacing:kSectionSpacing afterView:socialLinksSeparator];

    UIStackView *socialLinksStack = [[UIStackView alloc] init];
    socialLinksStack.axis = UILayoutConstraintAxisVertical;
    socialLinksStack.alignment = UIStackViewAlignmentLeading;
    socialLinksStack.distribution = UIStackViewDistributionFill;
    socialLinksStack.spacing = 4;
    socialLinksStack.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *githubButton = [UIButton buttonWithType:UIButtonTypeSystem];
    githubButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_social_text_button(githubButton, @"View GitHub Repository");
    zs_attach_tap_to_confirm(githubButton, self, @"Open GitHub?",
        @"You'll be leaving the app to open this link in Safari.", @"Open", NO, ^{
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:kZSSocialGitHubURL] options:@{} completionHandler:nil];
    });
    [socialLinksStack addArrangedSubview:githubButton];

    UIButton *discordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    discordButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_social_text_button(discordButton, @"Join the Discord Server");
    zs_attach_tap_to_confirm(discordButton, self, @"Open Discord?",
        @"You'll be leaving the app to open this link in Safari.", @"Open", NO, ^{
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:kZSSocialDiscordURL] options:@{} completionHandler:nil];
    });
    [socialLinksStack addArrangedSubview:discordButton];

    [self.stack addArrangedSubview:socialLinksStack];
    }];

    [self zs_refreshSectionIndex];

    [self layoutPanelForWindow:unityView];

    zs_gif_tint_preload();

    [CATransaction commit];
}

static const CGFloat kZSPanelSectionBuildHeadroom = 20.0;

- (BOOL)zs_hasPendingExperimentalSectionBuilders {
    return g_experimentalSettingsEnabled && self.experimentalSectionContainer && self.pendingExperimentalSectionBuilders.count > 0;
}

- (void)zs_runNextPendingSectionBuilder {
    if (!self.stack) return;

    NSMutableArray<dispatch_block_t> *queue = [self zs_hasPendingExperimentalSectionBuilders]
        ? self.pendingExperimentalSectionBuilders
        : self.pendingSectionBuilders;
    if (queue.count == 0) return;

    dispatch_block_t builder = queue.firstObject;
    [queue removeObjectAtIndex:0];

    NSUInteger before = self.stack.arrangedSubviews.count;
    builder();

    NSArray<UIView *> *arranged = self.stack.arrangedSubviews;
    NSDictionary *states = self.pendingCollapsedStates;
    for (NSUInteger i = before; i < arranged.count; i++) {
        [self zs_restoreCollapsedSectionsInView:arranged[i] states:states];
    }
}

- (void)zs_fillVisiblePanelSectionsWithHeadroom {
    if (!self.scrollView || !self.stack) return;

    CGFloat targetHeight = self.scrollView.bounds.size.height + self.scrollView.contentOffset.y + kZSPanelSectionBuildHeadroom;

    while (self.pendingSectionBuilders.count > 0 || [self zs_hasPendingExperimentalSectionBuilders]) {
        [self.stack setNeedsLayout];
        [self.stack layoutIfNeeded];
        if (self.stack.bounds.size.height >= targetHeight) break;
        [self zs_runNextPendingSectionBuilder];
    }

    [self.stack setNeedsLayout];
    [self.stack layoutIfNeeded];
}

- (void)zs_applyExperimentalAvailabilityTint {
    for (UIView *view in self.experimentalSectionContainer.arrangedSubviews) {
        if (![view isKindOfClass:[ZSRow class]]) continue;
        ZSRow *row = (ZSRow *)view;
        NSString *key = objc_getAssociatedObject(row.toggle, @"zs_exp_key")
                     ?: objc_getAssociatedObject(row.slider, @"zs_exp_key")
                     ?: objc_getAssociatedObject(row.modeSlider, @"zs_exp_key");
        if (!key || !row.titleLabel) continue;
        row.titleLabel.textColor = zs_exp_key_class_available(key)
            ? [UIColor colorWithWhite:0.9 alpha:1]
            : [UIColor colorWithWhite:0.9 alpha:0.35];
    }
}

#pragma mark Settings persistence

- (void)zs_scheduleSave {
    [self.saveDebounceTimer invalidate];
    self.saveDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:kSaveDebounceInterval
                                                                target:self
                                                              selector:@selector(zs_writeSettingsNow)
                                                              userInfo:nil
                                                               repeats:NO];
}

- (void)zs_writeSettingsNow {
    self.saveDebounceTimer = nil;
    zs_persist_current_settings();
}

- (void)setSyslogFullScreenOpen:(BOOL)open {
    _syslogFullScreenOpen = open;
    [self zs_syncReducedPanelFPS];
}

- (void)setMemoryFullScreenOpen:(BOOL)open {
    _memoryFullScreenOpen = open;
    [self zs_syncReducedPanelFPS];
}

- (void)setAssetExplorerFullScreenOpen:(BOOL)open {
    _assetExplorerFullScreenOpen = open;
    if (!open) [self zs_assetExplorerStopLive];
    [self zs_syncReducedPanelFPS];
}

- (void)setAssetExplorerSelectedBundle:(ZSAssetExplorerBundle *)bundle {
    NSString *previousPath = _assetExplorerSelectedBundle.filePath;
    _assetExplorerSelectedBundle = bundle;
    if (previousPath.length > 0 && ![previousPath isEqualToString:bundle.filePath]) {
        [ZSAssetExplorer unloadBundleAtPath:previousPath];
        [self.assetExplorerThumbSource reset];
    }
}

@end

#pragma mark - Startup

__attribute__((constructor))
static void graphics_debug_overlay_init(void) {
    [[UserInterface shared] zs_bootstrapSyslogCaptureIfNeeded];

    __block NSTimer *installTimer;
    installTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [[UserInterface shared] installIfNeeded];
        if ([UserInterface shared].installed) {
            zs_dump_glass_effect_instance_info();
            [timer invalidate];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:installTimer forMode:NSRunLoopCommonModes];
}
