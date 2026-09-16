@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIStackView *experimentalSectionContainer;
@property (nonatomic, strong) NSDictionary *pendingCollapsedStates;
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, assign) BOOL installed;
@property (nonatomic, assign) CGFloat panelWidth;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *v = zs_ui_host_view();
        if (v && weakSelf.panel) [weakSelf layoutPanelForWindow:v];
    });
}

    self.scrollView = nil;
    self.stack = nil;
    self.experimentalSectionContainer = nil;

    self.docsPanelGlass = nil;
    self.docsPanel = nil;
    [self.updateStatusLabel addGestureRecognizer:updateStatusLongPress];
    [self zs_beginUpdateCheck];

    zs_add_section_header_with_docs(self.stack, @"Display", self, @selector(docsInfoTapped:));

    ZSRow *normalRow = zs_make_slider_row(@"Menu FPS", 10, 120, g_menuFPS, fpsFormat);
    combatRow.slider.hasDefaultValue = YES;
    [combatRow.slider addTarget:self action:@selector(combatFpsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:combatRow];

    zs_add_section_header_with_docs(self.stack, @"Rendering", self, @selector(docsInfoTapped:));

    ZSRow *scaleRow = zs_make_slider_row(@"Render Scale", 25, 100, g_renderScale * 100.0f, ^NSString *(float v) {
    objc_setAssociatedObject(memorylessRow.modeSlider, @"zs_exp_key", @"RenderTextureMemorylessMode", OBJC_ASSOCIATION_RETAIN);
    [memorylessRow.modeSlider addTarget:self action:@selector(expModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:memorylessRow];

    zs_add_section_header_with_docs(self.stack, @"Anti-Aliasing", self, @selector(docsInfoTapped:));

    ZSRow *aaModeRow = zs_make_mode_slider_row(@"AA Mode", @[@"None", @"FXAA", @"SMAA", @"TAA"], g_aaModeIndex, kDefaultAAModeIndex);
    objc_setAssociatedObject(ditherRow.toggle, "zs_defaultBool", @(kDefaultDithering), OBJC_ASSOCIATION_RETAIN);
    [ditherRow.toggle addTarget:self action:@selector(cameraDitheringChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:ditherRow];

    zs_add_section_header_with_docs(self.stack, @"Post FX", self, @selector(docsInfoTapped:));

    ZSRow *hdrRow = zs_make_switch_row(@"Bloom", g_hdrOn);
        [sliderRow.slider addTarget:self action:@selector(urpEffectValueChanged:) forControlEvents:UIControlEventValueChanged];
        [self.stack addArrangedSubview:sliderRow];
    }
    }];

    zs_add_section_header_with_docs(self.stack, @"Particles", self, @selector(docsInfoTapped:));

    ZSRow *particleAlignmentRow = zs_make_wheel_row(@"Alignment",
    particleCapRow.slider.defaultValue = 50; particleCapRow.slider.hasDefaultValue = YES;
    [particleCapRow.slider addTarget:self action:@selector(particleCapChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:particleCapRow];

    zs_add_section_header_with_docs(self.stack, @"Mods", self, @selector(docsInfoTapped:));
    ZSRow *modsRow = zs_make_button_pair_row(
        @"Load Mods", [UIColor colorWithRed:0.55 green:0.42 blue:1.0 alpha:1.0],
    self.modsLibraryStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.modsLibraryStack];
    [self zs_rebuildModsLibrary];
    }];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Auth", self, @selector(docsInfoTapped:));

    self.authRepoLinkField = [[UITextField alloc] init];
    [self zs_loadAuthFields];

    [self zs_authRunBootVerification];

    zs_add_section_header_with_docs(self.stack, @"Debug", self, @selector(docsInfoTapped:));

    ZSRow *syslogRow = zs_make_button_and_glass_field_row(@"Syslog",

    self.syslogTabEnabled = NO;
    [self zs_renderSyslogBuffer];

    [self.pendingSectionBuilders addObject:^{
    zs_add_section_header_with_docs(self.stack, @"Miscellaneous", self, @selector(docsInfoTapped:));

    ZSRow *customGreetingRow = zs_make_custom_greeting_row(zs_custom_greeting_text(), self,
    [self.stack setCustomSpacing:8 afterView:disableLiquidGlassRow];
    [self.stack addArrangedSubview:disableEnkephalinRow];
    [self.stack setCustomSpacing:kSectionSpacing afterView:disableEnkephalinRow];

    zs_add_section_header_with_docs(self.stack, @"Config", self, @selector(docsInfoTapped:));

    NSString *currentReencodeFormat = [ZTranscoderSettings loadConfig].outputFormat;
    [socialLinksStack addArrangedSubview:discordButton];

    [self.stack addArrangedSubview:socialLinksStack];

    [self layoutPanelForWindow:unityView];

    zs_gif_tint_preload();


    [CATransaction commit];
}

    if (self.pendingSectionBuilders.count == 0 || !self.stack) return;
    builder();

        [self zs_restoreCollapsedSectionsInView:arranged[i] states:states];
    }
}

- (void)zs_fillVisiblePanelSectionsWithHeadroom {
    if (!self.scrollView || !self.stack) return;

    CGFloat targetHeight = self.scrollView.bounds.size.height + self.scrollView.contentOffset.y + kZSPanelSectionBuildHeadroom;

    while (self.pendingSectionBuilders.count > 0) {
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
    [self.scrollViewport setNeedsLayout];
    [self.scrollViewport layoutIfNeeded];

    [self zs_fillVisiblePanelSectionsWithHeadroom];

    [self installStaticContentFadeMask];
    [self zs_updateSliderGlassVisibility];
    [self layoutDocsPanelForWindow:unityView];
static const CGFloat kZSSliderGlassCullMargin = 0;

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self zs_updateSliderGlassVisibility];

    if (self.reencodeDropdownOpen) {
