#import "UIInternal.h"

static NSString *zs_mods_library_entry_title(ModAssetLibraryEntry *entry) {
    if (entry.remark.length > 0) return entry.remark;
    return entry.fileName.length > 0 ? entry.fileName : @"Unnamed asset";
}

static NSString *zs_mods_library_entry_kind(ModAssetLibraryEntry *entry) {
    if (entry.isAssetBundle) return @"Asset Bundle";
    if (entry.localizationKind == ModAssetLibraryLocalizationKindJSON) return @"Localization JSON";
    if (entry.localizationKind == ModAssetLibraryLocalizationKindPack) return @"Localization Pack";
    return entry.fileName.pathExtension.uppercaseString ?: @"";
}

static NSString *zs_mods_library_entry_symbol(ModAssetLibraryEntry *entry) {
    if ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) return @"waveform";
    if (entry.fontRole != ZSFontRoleNone || [ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) return @"textformat";
    if (entry.isAssetBundle) return @"shippingbox.fill";
    if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) return @"curlybraces";
    return @"doc.fill";
}

static NSString *zs_mods_library_target_platform_name(NSNumber *platform) {
    if (!platform) return nil;
    NSInteger value = platform.integerValue;
    NSString *name = nil;
    switch (value) {
        case 2: name = @"StandaloneOSX"; break;
        case 5: name = @"StandaloneWindows"; break;
        case 9: name = @"iOS"; break;
        case 13: name = @"Android"; break;
        case 19: name = @"StandaloneWindows64"; break;
        case 20: name = @"WebGL"; break;
        case 24: name = @"StandaloneLinux64"; break;
        default: break;
    }
    return name.length > 0 ? [NSString stringWithFormat:@"%@ (%ld)", name, (long)value] : [NSString stringWithFormat:@"%ld", (long)value];
}

static NSString *zs_mods_current_transcoder_codec_name(void) {
    switch (zs_transcoder_codec()) {
        case ZSTranscoderCodecASTC8x8: return @"ASTC 8x8";
        case ZSTranscoderCodecASTC10x10: return @"ASTC 10x10";
        case ZSTranscoderCodecRGBA32: return @"RGBA32";
        default: return @"ASTC 6x6";
    }
}

static NSString *zs_mods_library_entry_kind_title(ModAssetLibraryEntry *entry) {
    if ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) return @"FMOD Sound bank";
    if (entry.isAssetBundle) return @"Unity asset bundle";
    if (entry.localizationKind == ModAssetLibraryLocalizationKindPack) return @"Localization pack";
    if (entry.localizationKind == ModAssetLibraryLocalizationKindJSON) return @"Localization file";
    if (entry.fontRole != ZSFontRoleNone || [ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) return @"Font";
    NSString *extension = entry.fileName.pathExtension.uppercaseString;
    return extension.length > 0 ? [extension stringByAppendingString:@" file"] : @"File";
}

static NSString *zs_mods_library_entry_status(ModAssetLibraryEntry *entry) {
    switch (entry.doctorStatus) {
        case ModAssetLibraryDoctorStatusUploading: return @"Uploading";
        case ModAssetLibraryDoctorStatusProcessing: return @"Processing";
        case ModAssetLibraryDoctorStatusReadyToDownload: return @"Ready to download";
        case ModAssetLibraryDoctorStatusFailed: return @"Failed";
        case ModAssetLibraryDoctorStatusInstalled: return @"Installed";
        default: return nil;
    }
}

static BOOL zs_mods_library_entry_supports_explorer(ModAssetLibraryEntry *entry) {
    if (!entry) return NO;
    if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) return NO;
    if (entry.fontRole != ZSFontRoleNone) return NO;
    if (entry.isAssetBundle) return YES;
    if ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) return YES;
    return entry.localizationKind != ModAssetLibraryLocalizationKindNone;
}

static void zs_mods_library_collect_folder_stats(NSString *folder, NSFileManager *fileManager, unsigned long long *size, NSUInteger *count, NSDate **modified) {
    NSString *root = [ModAssetLibrary modLibraryRootDirectory];
    NSString *folderPath = root.length > 0 ? [root stringByAppendingPathComponent:folder] : nil;
    NSDate *folderDate = folderPath ? [fileManager attributesOfItemAtPath:folderPath error:nil].fileModificationDate : nil;
    if (folderDate && (!*modified || [folderDate compare:*modified] == NSOrderedDescending)) *modified = folderDate;
    for (ModAssetLibraryEntry *entry in [ModAssetLibrary entriesInFolder:folder error:nil] ?: @[]) {
        *size += entry.byteSize;
        *count += 1;
        NSDate *entryDate = entry.path.length > 0 ? [fileManager attributesOfItemAtPath:entry.path error:nil].fileModificationDate : nil;
        if (entryDate && (!*modified || [entryDate compare:*modified] == NSOrderedDescending)) *modified = entryDate;
    }
    for (NSString *subFolder in [ModAssetLibrary subFolderNamesInFolder:folder] ?: @[]) {
        zs_mods_library_collect_folder_stats(subFolder, fileManager, size, count, modified);
    }
}

static NSString *zs_mods_library_folder_item_count(NSDictionary<NSString *, id> *folderRow) {
    NSUInteger count = [folderRow[@"count"] unsignedIntegerValue];
    return [NSString stringWithFormat:@"%lu %@", (unsigned long)count, count == 1 ? @"item" : @"items"];
}

static NSString *zs_mods_library_folder_info(NSDictionary<NSString *, id> *folderRow, BOOL compact) {
    NSUInteger count = [folderRow[@"count"] unsignedIntegerValue];
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)count, count == 1 ? @"entry" : @"entries"]];
    if (count > 0) {
        [parts addObject:[NSByteCountFormatter stringFromByteCount:(long long)[folderRow[@"size"] unsignedLongLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
    }
    NSDate *modified = folderRow[@"modified"];
    if (!compact && [modified isKindOfClass:NSDate.class]) {
        NSString *dateText = [NSDateFormatter localizedStringFromDate:modified dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle];
        [parts addObject:[@"Modified " stringByAppendingString:dateText]];
    }
    return [parts componentsJoinedByString:@"  •  "];
}

static const NSInteger kZSModsLibrarySortName = 0;
static const NSInteger kZSModsLibrarySortSize = 1;
static const NSInteger kZSModsLibrarySortDate = 2;
static const NSInteger kZSModsLibrarySortKind = 3;

@interface ZSModsLibraryIconCell : UICollectionViewCell
@property (nonatomic, strong) UIView *tile;
@property (nonatomic, strong) UIImageView *glyph;
@property (nonatomic, strong) UILabel *badge;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, assign) BOOL showsFolder;
@end

@implementation ZSModsLibraryIconCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;

        _tile = [[UIView alloc] init];
        _tile.layer.cornerRadius = 12;
        _tile.layer.cornerCurve = kCACornerCurveContinuous;
        _tile.clipsToBounds = YES;
        [self.contentView addSubview:_tile];

        _glyph = [[UIImageView alloc] init];
        _glyph.contentMode = UIViewContentModeScaleAspectFit;
        [_tile addSubview:_glyph];

        _badge = [[UILabel alloc] init];
        _badge.font = zs_mono_font(8, UIFontWeightSemibold);
        _badge.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.adjustsFontSizeToFitWidth = YES;
        _badge.minimumScaleFactor = 0.6;
        [_tile addSubview:_badge];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = zs_mono_font(10, UIFontWeightRegular);
        _titleLabel.textColor = [UIColor colorWithWhite:0.94 alpha:1];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 2;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self.contentView addSubview:_titleLabel];

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.font = zs_mono_font(8, UIFontWeightRegular);
        _detailLabel.textColor = [UIColor colorWithWhite:1 alpha:0.42];
        _detailLabel.textAlignment = NSTextAlignmentCenter;
        _detailLabel.numberOfLines = 1;
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_detailLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat tileHeight = MAX(floor(width * 0.72), 1);
    self.tile.frame = CGRectMake(0, 0, width, tileHeight);
    BOOL hasBadge = self.badge.text.length > 0;
    CGFloat badgeHeight = hasBadge ? 12 : 0;
    self.badge.frame = CGRectMake(4, tileHeight - badgeHeight - 5, width - 8, badgeHeight);
    if (self.showsFolder) {
        CGFloat folderWidth = MIN(width * 0.86, 76);
        CGFloat folderHeight = MIN(tileHeight, folderWidth * 0.8);
        self.glyph.frame = CGRectMake((width - folderWidth) / 2.0, (tileHeight - folderHeight) / 2.0, folderWidth, folderHeight);
    } else {
        CGFloat glyphSide = MIN(tileHeight * 0.5, 40);
        CGFloat glyphCenterY = hasBadge ? (tileHeight - badgeHeight - 5) / 2.0 : tileHeight / 2.0;
        self.glyph.frame = CGRectMake((width - glyphSide) / 2.0, glyphCenterY - glyphSide / 2.0, glyphSide, glyphSide);
    }
    self.titleLabel.frame = CGRectMake(2, tileHeight + 6, width - 4, 26);
    self.detailLabel.frame = CGRectMake(2, tileHeight + 6 + 26 + 2, width - 4, 11);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.tile.alpha = highlighted ? 0.55 : 1;
}

- (void)configureWithFolder:(NSDictionary<NSString *, id> *)folderRow {
    UIColor *blue = [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0];
    self.showsFolder = YES;
    self.tile.backgroundColor = UIColor.clearColor;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:64 weight:UIImageSymbolWeightRegular];
    self.glyph.image = [UIImage systemImageNamed:@"folder.fill" withConfiguration:config];
    self.glyph.tintColor = blue;
    self.badge.text = nil;
    self.titleLabel.text = folderRow[@"title"];
    self.detailLabel.text = zs_mods_library_folder_item_count(folderRow);
    [self setNeedsLayout];
}

- (void)configureWithEntry:(ModAssetLibraryEntry *)entry {
    self.showsFolder = NO;
    self.tile.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightRegular];
    self.glyph.image = [UIImage systemImageNamed:zs_mods_library_entry_symbol(entry) withConfiguration:config];
    self.glyph.tintColor = zs_accent_green_color();
    NSString *extension = entry.fileName.pathExtension.uppercaseString;
    self.badge.text = extension.length > 0 && extension.length <= 8 ? extension : nil;
    self.titleLabel.text = zs_mods_library_entry_title(entry);
    self.detailLabel.text = [NSByteCountFormatter stringFromByteCount:(long long)entry.byteSize countStyle:NSByteCountFormatterCountStyleFile];
    [self setNeedsLayout];
}

@end

@interface ZSModsLibraryIconsSource : NSObject <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, weak) UserInterface *owner;
@end

@implementation ZSModsLibraryIconsSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    UserInterface *owner = self.owner;
    if (!owner || owner.modsLibrarySelectedEntry) return 0;
    return (NSInteger)(owner.modsLibraryDisplayedFolders.count + owner.modsLibraryDisplayedEntries.count);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ZSModsLibraryIconCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"ZSModsLibraryIconCell" forIndexPath:indexPath];
    UserInterface *owner = self.owner;
    if (!owner) return cell;
    NSIndexPath *rowPath = [NSIndexPath indexPathForRow:indexPath.item inSection:0];
    NSDictionary<NSString *, id> *folderRow = [owner zs_modsLibraryFolderAtIndexPath:rowPath];
    if (folderRow) {
        [cell configureWithFolder:folderRow];
        return cell;
    }
    ModAssetLibraryEntry *entry = [owner zs_modsLibraryEntryAtIndexPath:rowPath];
    if (entry) [cell configureWithEntry:entry];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    UserInterface *owner = self.owner;
    if (!owner) return;
    [owner zs_modsLibrarySelectRowAtIndexPath:[NSIndexPath indexPathForRow:indexPath.item inSection:0] inTableView:owner.assetExplorerTableView];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point API_AVAILABLE(ios(13.0)) {
    UserInterface *owner = self.owner;
    if (!owner || owner.modsLibrarySelectedEntry) return nil;
    return [owner zs_modsLibraryContextMenuForIndexPath:[NSIndexPath indexPathForRow:indexPath.item inSection:0]];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)collectionViewLayout;
    CGFloat available = collectionView.bounds.size.width - layout.sectionInset.left - layout.sectionInset.right;
    CGFloat spacing = layout.minimumInteritemSpacing;
    NSInteger columns = MAX(3, (NSInteger)floor((available + spacing) / (92.0 + spacing)));
    CGFloat width = floor((available - spacing * (columns - 1)) / columns);
    CGFloat tileHeight = MAX(floor(width * 0.72), 1);
    return CGSizeMake(MAX(width, 1), tileHeight + 6 + 26 + 2 + 11);
}

@end

static BOOL g_zsStoredBackupsExpanded;
static BOOL g_zsLz4hcExpanded;
static BOOL g_zsLz4hcBusy;
static NSArray<NSString *> *g_zsLz4hcPendingPaths;

static UIColor *zs_stored_backups_red_color(void) {
    return [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
}

static NSString *zs_stored_backups_size_string(unsigned long long bytes) {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowsNonnumericFormatting = NO;
    return [formatter stringFromByteCount:(long long)bytes];
}

static UIView *zs_stored_backups_card_for_view(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (objc_getAssociatedObject(candidate, "zs_backupsWrapper")) return candidate;
    }
    return nil;
}

static UIView *zs_lz4hc_section_for_view(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (objc_getAssociatedObject(candidate, "zs_lz4Wrapper")) return candidate;
    }
    return nil;
}

static UIView *zs_make_stored_backups_separator(void) {
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    [line.heightAnchor constraintEqualToConstant:1].active = YES;
    return line;
}

@implementation UserInterface (Mods)

#pragma mark Mods (Load Mods - single entry point, routes by file kind)

- (void)loadModsTapped {
    __weak typeof(self) weakSelf = self;
    [self zs_promptForModFolderNameWithTitle:@"New Mod Folder"
                                  actionTitle:@"Create"
                                     hintText:@"Create a new folder to add mods to it."
                                   completion:^(NSString *trimmedName) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSError *error = nil;
        BOOL created = [ModAssetLibrary createFolderNamed:trimmedName error:&error];
        if (!created) {
            [strongSelf zs_presentModsAlertWithTitle:@"Couldn't Create Folder" message:error.localizedDescription ?: @"Unknown error."];
            return;
        }
        [strongSelf zs_rebuildModsLibrary];
        [strongSelf zs_presentLoadModsPickerIntoFolder:trimmedName];
    }];
}

- (void)zs_presentLoadModsPickerIntoFolder:(NSString *)folderName {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem, UTTypeFolder]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item", @"public.folder"]
                                                                          inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods] no root view controller to present the file picker from");
        return;
    }
    self.loadModsPicker = picker;
    self.loadModsTargetFolder = folderName;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    if (controller == self.logoImportPicker) {
        self.logoImportPicker = nil;
        [self zs_handleLogoImportPickedURL:urls.firstObject];
        return;
    }
    if (controller == self.assetExplorerSwapDocumentPicker) {
        self.assetExplorerSwapDocumentPicker = nil;
        [self zs_assetExplorerSwapPickedImageURL:urls.firstObject];
        return;
    }
    if (controller == self.patchLCPicker) {
        self.patchLCPicker = nil;
        [self zs_handlePatchLCPickedURL:urls.firstObject];
        return;
    }
    if (controller == self.createLogosPicker) {
        self.createLogosPicker = nil;
        [self zs_handleCreateLogosPickedURL:urls.firstObject];
        return;
    }
    if (controller == self.loadModsPicker) {
        NSString *folderName = self.loadModsTargetFolder;
        self.loadModsTargetFolder = nil;
        if (folderName) [self zs_handleLoadModsPickedURLs:urls intoFolder:folderName];
        return;
    }
    if (controller == self.libraryImportPicker) {
        NSString *folderName = self.libraryImportTargetFolder;
        self.libraryImportTargetFolder = nil;
        if (folderName) [self zs_handlePickedLibraryImportURLs:urls intoFolder:folderName];
        return;
    }
    if (controller == self.doctorInstallTargetPicker) {
        NSURL *doctoredURL = self.doctorInstallPendingDoctoredURL;
        NSString *entryPath = self.doctorInstallPendingEntryPath;
        NSString *folderName = self.doctorInstallPendingFolderName;
        self.doctorInstallPendingDoctoredURL = nil;
        self.doctorInstallPendingEntryPath = nil;
        self.doctorInstallPendingFolderName = nil;
        if (doctoredURL && entryPath && folderName) {
            [self zs_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:urls.firstObject entryPath:entryPath inFolder:folderName];
        }
        return;
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (controller == self.libraryImportPicker) {
        self.libraryImportTargetFolder = nil;
    }
    if (controller == self.doctorInstallTargetPicker) {
        NSString *entryPath = self.doctorInstallPendingEntryPath;
        NSString *folderName = self.doctorInstallPendingFolderName;
        self.doctorInstallPendingDoctoredURL = nil;
        self.doctorInstallPendingEntryPath = nil;
        self.doctorInstallPendingFolderName = nil;
        if (entryPath && folderName) {
            [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
                [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                     code:ZTranscoderInstallerErrorNoInstallTarget
                                 userInfo:@{NSLocalizedDescriptionKey: @"Cancelled - no stock bundle was picked to install into."}]];
        }
    }
}

- (void)zs_handleLoadModsPickedZipURLs:(NSArray<NSURL *> *)zipURLs intoFolder:(NSString *)folderName summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    for (NSURL *zipURL in zipURLs) {
        BOOL accessing = [zipURL startAccessingSecurityScopedResource];
        NSError *formatErr = nil;
        BOOL isLunartique = [LunartiqueModArchive isLunartiqueFormatZipAtURL:zipURL error:&formatErr];
        if (!isLunartique) {
            if (accessing) [zipURL stopAccessingSecurityScopedResource];
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - unknown file, it's neither a Lunartique mod nor a localization pack", zipURL.lastPathComponent]];
            continue;
        }

        NSError *importErr = nil;
        NSArray<NSString *> *rejectedEntryLines = nil;
        BOOL imported = [ModAssetLibrary importLunartiqueZipURL:zipURL intoFolder:folderName rejectedEntryLines:&rejectedEntryLines error:&importErr];
        if (accessing) [zipURL stopAccessingSecurityScopedResource];

        if (rejectedEntryLines.count > 0) {
            [summaryLines addObjectsFromArray:rejectedEntryLines];
        }

        if (imported) {
            [summaryLines addObject:zs_asset_imported_line(zipURL.lastPathComponent)];
        } else if (rejectedEntryLines.count == 0) {

            [summaryLines addObject:[NSString stringWithFormat:@"%@: Lunartique format matched, but import failed - %@", zipURL.lastPathComponent, importErr.localizedDescription ?: @"unknown error"]];
        }
    }
}

- (void)zs_handleLoadModsPickedCarra2URLs:(NSArray<NSURL *> *)carra2URLs intoFolder:(NSString *)folderName summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    for (NSURL *carra2URL in carra2URLs) {
        NSError *importErr = nil;
        BOOL imported = [ModAssetLibrary importCarra2URL:carra2URL intoFolder:folderName error:&importErr];
        if (imported) {
            [summaryLines addObject:zs_asset_imported_line(carra2URL.lastPathComponent)];
        } else {
            [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - %@", carra2URL.lastPathComponent, importErr.localizedDescription ?: @"doesn't match the Carra2 mod format"]];
        }
    }
}

- (BOOL)zs_urlIsDirectory:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    BOOL isDirectory = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDirectory];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return exists && isDirectory;
}

- (BOOL)zs_isLocalizationPackFolderURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    BOOL isPack = [LocalizationTransplant isTranslationPackDirectoryAtPath:url.path];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return isPack;
}

- (BOOL)zs_isLocalizationPackZipURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSArray<NSString *> *names = [LunartiqueModArchive allEntryNamesInZipAtURL:url error:nil];
    if (accessing) [url stopAccessingSecurityScopedResource];
    if (names.count == 0) return NO;
    return [LocalizationTransplant packRootFolderNameForArchiveEntryNames:names] != nil;
}

- (nullable NSString *)zs_detectedLocalizationLanguageForFolderURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSString *language = [LocalizationTransplant detectedLanguageForPackDirectoryAtPath:url.path];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return language;
}

- (nullable NSString *)zs_detectedLocalizationLanguageForZipURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSArray<NSString *> *names = [LunartiqueModArchive allEntryNamesInZipAtURL:url error:nil];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return names ? [LocalizationTransplant detectedLanguageForArchiveEntryNames:names] : nil;
}

- (void)zs_promptLocalizationLanguageQueue:(NSMutableArray<NSDictionary *> *)queue
                                      jobs:(NSMutableArray<NSDictionary *> *)jobs
                              summaryLines:(NSMutableArray<NSString *> *)summaryLines
                                completion:(void (^)(NSArray<NSDictionary *> *jobs))completion {
    if (queue.count == 0) {
        completion(jobs);
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        completion(jobs);
        return;
    }

    NSDictionary *item = queue.firstObject;
    [queue removeObjectAtIndex:0];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Language Folder"
                                                                    message:item[@"message"]
                                                             preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (NSString *code in [LocalizationTransplant languageCodes]) {
        [alert addAction:[UIAlertAction actionWithTitle:code style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSMutableDictionary *job = [item mutableCopy];
            job[@"language"] = code;
            [jobs addObject:job];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf zs_promptLocalizationLanguageQueue:queue jobs:jobs summaryLines:summaryLines completion:completion];
            });
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [summaryLines addObject:[NSString stringWithFormat:@"%@: cancelled", item[@"name"]]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf zs_promptLocalizationLanguageQueue:queue jobs:jobs summaryLines:summaryLines completion:completion];
        });
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_promptFontRoleQueue:(NSMutableArray<NSURL *> *)queue
                    validURLs:(NSMutableArray<NSURL *> *)validURLs
                    fontRoles:(NSMutableDictionary<NSString *, NSNumber *> *)fontRoles
                 summaryLines:(NSMutableArray<NSString *> *)summaryLines
                   completion:(void (^)(void))completion {
    if (queue.count == 0) {
        completion();
        return;
    }

    NSURL *url = queue.firstObject;
    [queue removeObjectAtIndex:0];

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        zs_drop_font_from_import(url, @"cancelled", validURLs, summaryLines);
        [self zs_promptFontRoleQueue:queue validURLs:validURLs fontRoles:fontRoles summaryLines:summaryLines completion:completion];
        return;
    }

    static const ZSFontRole kRoles[] = { ZSFontRoleTitle, ZSFontRoleContext, ZSFontRoleKanjiHanzi };
    NSMutableArray<NSNumber *> *freeRoles = [NSMutableArray array];
    NSMutableArray<NSString *> *takenLines = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kRoles) / sizeof(kRoles[0]); i++) {
        ZSFontRole role = kRoles[i];
        NSString *occupantName = nil;
        ModAssetLibraryEntry *occupant = [ModAssetLibrary fontEntryOccupyingRole:role];
        if (occupant) {
            occupantName = [ModAssetLibrary displayNameForEntry:occupant];
        } else {
            for (NSString *claimedPath in fontRoles) {
                if (fontRoles[claimedPath].integerValue == role) {
                    occupantName = claimedPath.lastPathComponent;
                    break;
                }
            }
        }
        if (occupantName) {
            [takenLines addObject:[NSString stringWithFormat:@"%@: %@", [ZSModsPaths displayNameForFontRole:role], occupantName]];
        } else {
            [freeRoles addObject:@(role)];
        }
    }

    if (freeRoles.count == 0) {
        zs_drop_font_from_import(url, @"rejected - Title, Context and Kanji/Hanzi are all assigned, delete a font from the library to free one", validURLs, summaryLines);
        [self zs_promptFontRoleQueue:queue validURLs:validURLs fontRoles:fontRoles summaryLines:summaryLines completion:completion];
        return;
    }

    NSString *message = [NSString stringWithFormat:@"Which text should \u201C%@\u201D be used for?", url.lastPathComponent];
    if (takenLines.count > 0) {
        message = [message stringByAppendingFormat:@"\n\nAlready assigned:\n%@", [takenLines componentsJoinedByString:@"\n"]];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Assign Font"
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (size_t i = 0; i < sizeof(kRoles) / sizeof(kRoles[0]); i++) {
        ZSFontRole role = kRoles[i];
        UIAlertAction *action = [UIAlertAction actionWithTitle:[ZSModsPaths displayNameForFontRole:role]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *chosen) {
            fontRoles[url.path] = @(role);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf zs_promptFontRoleQueue:queue validURLs:validURLs fontRoles:fontRoles summaryLines:summaryLines completion:completion];
            });
        }];
        action.enabled = [freeRoles containsObject:@(role)];
        [alert addAction:action];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *chosen) {
        zs_drop_font_from_import(url, @"cancelled", validURLs, summaryLines);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf zs_promptFontRoleQueue:queue validURLs:validURLs fontRoles:fontRoles summaryLines:summaryLines completion:completion];
        });
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)zs_handleLoadModsPickedURLs:(NSArray<NSURL *> *)urls intoFolder:(NSString *)folderName {
    if (urls.count == 0) return;

    NSMutableArray<NSURL *> *validURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *fontURLs = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *fontRoles = [NSMutableDictionary dictionary];
    NSMutableArray<NSURL *> *bankURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *zipURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *carra2URLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *localizationJSONURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *localizationFolderURLs = [NSMutableArray array];
    NSMutableArray<NSURL *> *localizationZipURLs = [NSMutableArray array];
    NSMutableArray<NSString *> *summaryLines = [NSMutableArray array];
    NSMutableSet<NSString *> *acceptedBankNames = [NSMutableSet set];

    for (NSURL *url in urls) {
        if ([url.pathExtension caseInsensitiveCompare:@"zip"] == NSOrderedSame) {
            if ([self zs_isLocalizationPackZipURL:url]) {
                [localizationZipURLs addObject:url];
            } else {
                [zipURLs addObject:url];
            }
        } else if ([url.pathExtension caseInsensitiveCompare:@"carra2"] == NSOrderedSame) {
            [carra2URLs addObject:url];
        } else if ([url.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) {
            NSString *bankKey = url.lastPathComponent.lowercaseString;
            ModAssetLibraryEntry *overlappingBank = [ModAssetLibrary activeEntryOverlappingBankNamed:url.lastPathComponent];
            if (overlappingBank) {
                [summaryLines addObject:[ModAssetLibrary overlapRejectionLineForName:url.lastPathComponent existingEntry:overlappingBank]];
            } else if ([acceptedBankNames containsObject:bankKey]) {
                [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - it points to the %@ as another bank in this batch",
                                         url.lastPathComponent, ModAssetLibraryOverlapPhrase]];
            } else {
                [acceptedBankNames addObject:bankKey];
                [bankURLs addObject:url];
                [validURLs addObject:url];
            }
        } else if ([self zs_urlIsDirectory:url]) {
            if ([self zs_isLocalizationPackFolderURL:url]) {
                [localizationFolderURLs addObject:url];
            } else {
                [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - unknown folder, it doesn't look like a localization pack", url.lastPathComponent]];
            }
        } else if ([url.pathExtension caseInsensitiveCompare:@"json"] == NSOrderedSame) {
            if ([LocalizationTransplant isLocalizationJSONAtURL:url]) {
                [localizationJSONURLs addObject:url];
            } else {
                [summaryLines addObject:[NSString stringWithFormat:@"%@: rejected - not a localization .json file (it must start with dataList)", url.lastPathComponent]];
            }
        } else if ([ZSModsPaths fontKindForFileName:url.lastPathComponent] != ZSFontKindUnknown) {

            [validURLs addObject:url];
            [fontURLs addObject:url];
            [summaryLines addObject:zs_asset_imported_line(url.lastPathComponent)];
        } else if ([self zs_isRecognizedBundleURL:url]) {

            [validURLs addObject:url];
            [summaryLines addObject:zs_asset_imported_line(url.lastPathComponent)];
        } else {

            [summaryLines addObject:[NSString stringWithFormat:@"%@: not a recognized asset", url.lastPathComponent]];
        }
    }

    self.loadModsSummaryLines = summaryLines;

    NSMutableArray<NSDictionary *> *promptQueue = [NSMutableArray array];
    if (localizationJSONURLs.count > 0) {
        NSUInteger count = localizationJSONURLs.count;
        [promptQueue addObject:@{
            @"type": @"json",
            @"urls": [localizationJSONURLs copy],
            @"name": count == 1 ? localizationJSONURLs.firstObject.lastPathComponent
                                : [NSString stringWithFormat:@"%lu localization .json files", (unsigned long)count],
            @"message": count == 1
                ? [NSString stringWithFormat:@"Which language folder should \u201C%@\u201D go into?", localizationJSONURLs.firstObject.lastPathComponent]
                : [NSString stringWithFormat:@"Which language folder should these %lu .json files go into?", (unsigned long)count],
        }];
    }
    NSMutableArray<NSDictionary *> *autoJobs = [NSMutableArray array];
    for (NSURL *folderURL in localizationFolderURLs) {
        NSString *detected = [self zs_detectedLocalizationLanguageForFolderURL:folderURL];
        NSMutableDictionary *item = [@{
            @"type": @"folder",
            @"url": folderURL,
            @"name": folderURL.lastPathComponent,
            @"message": [NSString stringWithFormat:@"\u201C%@\u201D has no language prefix in its .json files. Which language folder should it replace? The prefix will be added to every .json file.", folderURL.lastPathComponent],
        } mutableCopy];
        if (detected) {
            item[@"language"] = detected;
            [autoJobs addObject:item];
        } else {
            [promptQueue addObject:item];
        }
    }
    for (NSURL *zipURL in localizationZipURLs) {
        NSString *detected = [self zs_detectedLocalizationLanguageForZipURL:zipURL];
        NSMutableDictionary *item = [@{
            @"type": @"zip",
            @"url": zipURL,
            @"name": zipURL.lastPathComponent,
            @"message": [NSString stringWithFormat:@"\u201C%@\u201D has no language prefix in its .json files. Which language folder should it replace? The prefix will be added to every .json file.", zipURL.lastPathComponent],
        } mutableCopy];
        if (detected) {
            item[@"language"] = detected;
            [autoJobs addObject:item];
        } else {
            [promptQueue addObject:item];
        }
    }

    __weak typeof(self) weakSelf = self;
    [self zs_promptFontRoleQueue:fontURLs
                       validURLs:validURLs
                       fontRoles:fontRoles
                    summaryLines:summaryLines
                      completion:^{
        [weakSelf zs_promptLocalizationLanguageQueue:promptQueue
                                                jobs:autoJobs
                                        summaryLines:summaryLines
                                          completion:^(NSArray<NSDictionary *> *localizationJobs) {
            [weakSelf zs_runLoadModsImportWithValidURLs:validURLs
                                               bankURLs:bankURLs
                                                zipURLs:zipURLs
                                             carra2URLs:carra2URLs
                                       localizationJobs:localizationJobs
                                             fontRoles:fontRoles
                                             intoFolder:folderName
                                           summaryLines:summaryLines];
        }];
    }];
}

- (void)zs_runLoadModsImportWithValidURLs:(NSArray<NSURL *> *)validURLs
                                 bankURLs:(NSArray<NSURL *> *)bankURLs
                                  zipURLs:(NSArray<NSURL *> *)zipURLs
                               carra2URLs:(NSArray<NSURL *> *)carra2URLs
                         localizationJobs:(NSArray<NSDictionary *> *)localizationJobs
                                fontRoles:(NSDictionary<NSString *, NSNumber *> *)fontRoles
                               intoFolder:(NSString *)folderName
                             summaryLines:(NSMutableArray<NSString *> *)summaryLines {
    self.loadModsSummaryLines = summaryLines;

    if (validURLs.count == 0 && zipURLs.count == 0 && carra2URLs.count == 0 && localizationJobs.count == 0) {
        [self zs_processLoadModsBankURLs:bankURLs];
        return;
    }

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
        if (validURLs.count > 0) {
            NSError *importError = nil;
            NSArray<NSString *> *rejectedFileLines = nil;
            BOOL imported = [ModAssetLibrary importFileURLs:validURLs intoFolder:folderName fontRoles:fontRoles rejectedFileLines:&rejectedFileLines error:&importError];
            if (!imported && rejectedFileLines.count == 0) {
                ZLog(@"[Mods] couldn't add picked files to Mod Asset Library folder \"%@\": %@", folderName, importError);
            }

            for (NSString *rejectedLine in rejectedFileLines) {
                NSString *rejectedFileName = [[rejectedLine componentsSeparatedByString:@": rejected"] firstObject];
                NSUInteger existingIdx = [summaryLines indexOfObjectPassingTest:^BOOL(NSString *line, NSUInteger idx, BOOL *stop) {
                    return [line hasPrefix:[rejectedFileName stringByAppendingString:@": "]] || [line isEqualToString:zs_asset_imported_line(rejectedFileName)];
                }];
                if (existingIdx != NSNotFound) {
                    summaryLines[existingIdx] = rejectedLine;
                } else {
                    [summaryLines addObject:rejectedLine];
                }
            }
        }
        if (zipURLs.count > 0) {
            [self zs_handleLoadModsPickedZipURLs:zipURLs intoFolder:folderName summaryLines:summaryLines];
        }
        if (carra2URLs.count > 0) {
            [self zs_handleLoadModsPickedCarra2URLs:carra2URLs intoFolder:folderName summaryLines:summaryLines];
        }
        for (NSDictionary *job in localizationJobs) {
            NSString *type = job[@"type"];
            NSString *language = job[@"language"];
            if ([type isEqualToString:@"json"]) {
                [ModAssetLibrary importLocalizationJSONURLs:job[@"urls"] language:language intoFolder:folderName summaryLines:summaryLines];
            } else if ([type isEqualToString:@"folder"]) {
                [ModAssetLibrary importLocalizationPackFolderURL:job[@"url"] language:language intoFolder:folderName summaryLines:summaryLines];
            } else if ([type isEqualToString:@"zip"]) {
                [ModAssetLibrary importLocalizationPackZipURL:job[@"url"] language:language intoFolder:folderName summaryLines:summaryLines];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.loadModsSummaryLines = summaryLines;
            void (^afterDismiss)(void) = ^{
                [strongSelf zs_rebuildModsLibrary];
                [strongSelf zs_openModLibraryInFolder:folderName];
                [strongSelf zs_processLoadModsBankURLs:bankURLs];
            };
            if (indexing.presentingViewController) {
                [indexing dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

- (BOOL)zs_isRecognizedBundleURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    BOOL isBundle = [UnityBundleCAB isUnityFSBundleAtPath:url.path];
    if (accessing) [url stopAccessingSecurityScopedResource];
    return isBundle;
}

- (void)zs_processLoadModsBankURLs:(NSArray<NSURL *> *)bankURLs {
    if (bankURLs.count == 0) {
        [self zs_presentLoadModsFinalSummary];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    UIAlertController *working = [UIAlertController alertControllerWithTitle:@"Swapping Files\u2026"
                                                                       message:@"Swapping modded files into the game's files."
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

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *lines = [NSMutableArray array];

        for (NSURL *url in bankURLs) {
            NSError *bankErr = nil;
            BOOL ok = [BankTransplant transplantAndSwapModdedBankAtURL:url error:&bankErr];
            if (ok) {
                [lines addObject:[NSString stringWithFormat:@"%@: swapped", url.lastPathComponent]];
            } else {
                [lines addObject:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent, bankErr.localizedDescription ?: @"failed"]];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            void (^afterDismiss)(void) = ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf.loadModsSummaryLines addObjectsFromArray:lines];
                [strongSelf zs_presentLoadModsFinalSummary];
            };
            if (working.presentingViewController) {
                [working dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

- (void)restoreOriginalsTapped {
    [self zs_performRestoreOriginalsForce:NO];
}

- (void)zs_forceRestoreOriginalsTapped {
    [self zs_performRestoreOriginalsForce:YES];
}

- (void)zs_performRestoreOriginalsForce:(BOOL)force {
    NSError *bankError = nil;
    NSInteger banksRestored = [BankTransplant restoreAllBackedUpBanksForce:force error:&bankError];

    NSError *bundleError = nil;
    NSInteger bundlesRestored = [ZTranscoderInstaller restoreAllBackedUpBundlesForce:force error:&bundleError];

    NSError *localizationError = nil;
    NSInteger localizationRestored = [LocalizationTransplant restoreAllBackupsForce:force error:&localizationError];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];

    if (banksRestored < 0 || bundlesRestored < 0 || localizationRestored < 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        NSString *reason = bankError.localizedDescription ?: bundleError.localizedDescription ?: @"Unknown error.";
        ZLog(@"[BankTransplant] Restore Originals (force=%d) failed: %@", force, reason);
        [self zs_presentModsAlertWithTitle:@"Restore Failed" message:reason];
        return;
    }

    if (banksRestored == 0 && bundlesRestored == 0 && localizationRestored == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        if (force) {

            [self zs_presentModsAlertWithTitle:@"Nothing to Restore" message:@"No backed-up banks, bundles or localization files found."];
        } else {
            [self zs_presentRestoreNothingToRestoreAlertWithForceOption];
        }
        return;
    }

    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (banksRestored > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld bank%@", (long)banksRestored, banksRestored == 1 ? @"" : @"s"]];
    }
    if (bundlesRestored > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld bundle%@", (long)bundlesRestored, bundlesRestored == 1 ? @"" : @"s"]];
    }
    if (localizationRestored > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ld localization item%@", (long)localizationRestored, localizationRestored == 1 ? @"" : @"s"]];
    }
    NSString *message = [NSString stringWithFormat:
        @"Restored %@ to their original state. Restart the game for it to take effect.",
        [parts componentsJoinedByString:@" and "]];
    ZLog(@"[BankTransplant] Restore Originals (force=%d): %ld bank(s), %ld bundle(s), %ld localization item(s) restored.", force, (long)banksRestored, (long)bundlesRestored, (long)localizationRestored);
    [self zs_presentModsAlertWithTitle:@"Restore Originals" message:message offersRestart:YES];
}

- (void)zs_presentRestoreNothingToRestoreAlertWithForceOption {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[BankTransplant] Nothing to Restore: every backed-up bank/bundle already matches its backup.");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Nothing to Restore"
                                                                     message:@"No modded assets were found in the game's files to restore."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Force Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_forceRestoreOriginalsTapped];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark Mods (doctor pipeline)

static const NSTimeInterval kZSDoctorProgressMinUpdateInterval = 0.08;
static const NSTimeInterval kZSDoctorDownloadProgressPersistInterval = 1.0;

static NSString *zs_mods_folder_name_for_entry(ModAssetLibraryEntry *entry) {

    if (entry.currentFolder.length > 0) return entry.currentFolder;

    NSString *root = [ModAssetLibrary modLibraryRootDirectory];
    NSString *path = entry.path;
    if (root.length > 0 && [path hasPrefix:root]) {
        NSString *relative = [path substringFromIndex:root.length];
        if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        NSString *first = relative.pathComponents.firstObject;
        if (first.length > 0) return first;
    }

    return path.stringByDeletingLastPathComponent.lastPathComponent;
}

static ModAssetLibraryEntry *zs_mods_entry_placeholder_for_path(NSString *path) {
    ModAssetLibraryEntry *placeholder = [ModAssetLibraryEntry new];
    placeholder.path = path;
    return placeholder;
}


- (void)zs_modsLibraryEntryDispatchTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;
    NSString *folderName = zs_mods_folder_name_for_entry(entry);
    if (!folderName) {
        ZLog(@"[Mods Library] Dispatch tapped for %@ but couldn't derive its owning folder from its path (%@) - not proceeding.", entry.fileName, entry.path);
        return;
    }

    [self zs_doctorStartOrInstallForEntry:entry folderName:folderName previousScratchBranch:entry.doctorScratchBranch];
}

- (void)zs_doctorStartOrInstallForEntry:(ModAssetLibraryEntry *)entry folderName:(NSString *)folderName previousScratchBranch:(nullable NSString *)previousScratchBranch {
    if (entry.targetPlatform && entry.targetPlatform.intValue == 9) {
        if (!self.doctorDownloadInFlightPaths) self.doctorDownloadInFlightPaths = [NSMutableSet set];
        if ([self.doctorDownloadInFlightPaths containsObject:entry.path]) {
            ZLog(@"[Mods Library] doctor install for %@ already in flight, ignoring duplicate tap.", entry.fileName);
            return;
        }
        [self.doctorDownloadInFlightPaths addObject:entry.path];
        [self zs_rebuildModsLibrary];
        ZLog(@"[Mods Library] %@ already has a known target platform, installing directly without re-dispatching.", entry.fileName);
        [self zs_doctorInstallUsingKnownTargetForDoctoredURL:[NSURL fileURLWithPath:entry.path]
                                                entryPath:entry.path
                                                 inFolder:folderName];
        return;
    }

    [self zs_doctorBeginDispatchForEntry:entry folderName:folderName previousScratchBranch:previousScratchBranch];
}

- (void)zs_doctorBeginDispatchForEntry:(ModAssetLibraryEntry *)entry folderName:(NSString *)folderName previousScratchBranch:(nullable NSString *)previousScratchBranch {
    NSString *entryPath = entry.path;
    [self.doctorUploadProgressLastUpdate removeObjectForKey:entryPath];
    [self.doctorProcessProgressLastPercent removeObjectForKey:entryPath];

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusProcessing;
        entryToMutate.doctorUploadProgress = 0;
        entryToMutate.doctorUploadTotalBytes = 0;
        entryToMutate.doctorProcessProgress = 0.0;
        entryToMutate.doctorLastError = nil;
        entryToMutate.doctorTranscodeCodec = zs_mods_current_transcoder_codec_name();
        entryToMutate.doctorRGBA32Passthrough = @(zs_transcoder_codec() != ZSTranscoderCodecRGBA32 && zs_transcoder_rgba32_passthrough());
        entryToMutate.doctorScratchBranch = nil;
        entryToMutate.doctorRunID = nil;
        entryToMutate.doctorRunURL = nil;
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't flip %@ to Processing: %@", entry.fileName, stateError);
        return;
    }
    [self zs_rebuildModsLibrary];

    ZLog(@"[Mods Library] starting on-device transcode for %@ (previous scratch branch=%@ ignored).", entryPath.lastPathComponent, previousScratchBranch ?: @"none");
    NSURL *bundleURL = [NSURL fileURLWithPath:entryPath];
    ZTranscoderConfig *config = [ZTranscoderConfig new];
    if (entry.resolvedInstallTargetPath.length > 0) {
        config.targetBundlePath = [NSHomeDirectory() stringByAppendingPathComponent:entry.resolvedInstallTargetPath];
        ZLog(@"[Mods Library] local transcode target for %@: %@", entry.fileName, config.targetBundlePath);
    } else {
        ZLog(@"[Mods Library] no stored install target for %@; transcoder will use its CAB-resolution fallback.", entry.fileName);
    }
    __weak typeof(self) weakSelf = self;
    [ZTranscoderService dispatchBundleAtURL:bundleURL
                                   carra2Hash1:nil
                                   carra2Hash2:nil
                                        config:config
                         previousScratchBranch:nil
                                uploadProgress:^(int64_t bytesSent, int64_t totalBytesExpected) {
        double fraction = totalBytesExpected > 0 ? (double)bytesSent / (double)totalBytesExpected : 0.0;
        [weakSelf zs_doctorHandleProcessProgress:fraction forEntryPath:entryPath inFolder:folderName];
    }
                                    completion:^(ZTranscoderHandle * _Nullable handle, NSError * _Nullable error) {
        [weakSelf zs_doctorDispatchCompletedForEntryPath:entryPath inFolder:folderName handle:handle error:error];
    }];
}

- (void)zs_modsLibraryEntryRetryTapped:(UIButton *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;
    NSString *folderName = zs_mods_folder_name_for_entry(entry);
    if (!folderName) return;

    [self zs_stopDoctorPollTimerForEntryPath:entry.path];
    [self.doctorUploadProgressLastUpdate removeObjectForKey:entry.path];
    [self.doctorProcessProgressLastPercent removeObjectForKey:entry.path];

    NSString *previousScratchBranch = entry.doctorScratchBranch;

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusNotDispatched;
        entryToMutate.doctorUploadProgress = 0;
        entryToMutate.doctorProcessProgress = 0.0;
        entryToMutate.doctorScratchBranch = nil;
        entryToMutate.doctorRunID = nil;
        entryToMutate.doctorRunURL = nil;
        entryToMutate.doctorLastError = nil;
    }
                                                                           error:&error];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't reset %@ back to NotDispatched: %@", entry.fileName, error);
        return;
    }

    ZLog(@"[Mods Library] retrying %@, previous scratch branch=%@.", entry.fileName, previousScratchBranch ?: @"none");
    [self zs_doctorStartOrInstallForEntry:updated folderName:folderName previousScratchBranch:previousScratchBranch];
}

- (BOOL)zs_updateDoctorProgressLabelForEntry:(ModAssetLibraryEntry *)entry downloadInFlight:(BOOL)downloadInFlight {
    if (!self.modsLibraryStack) return NO;
    for (UIView *view in self.modsLibraryStack.arrangedSubviews) {
        ModAssetLibraryEntry *viewEntry = objc_getAssociatedObject(view, "zs_modsEntry");
        if (![viewEntry.path isEqualToString:entry.path]) continue;
        UILabel *statusLabel = objc_getAssociatedObject(view, "zs_label_doctorStatus");
        if (!statusLabel) continue;
        NSString *statusText = zs_doctor_status_text_for_entry(entry, downloadInFlight, NO);
        statusLabel.text = [NSString stringWithFormat:@"Status: %@", statusText];
        return YES;
    }
    return NO;
}

- (void)zs_doctorHandleUploadProgress:(int64_t)bytesSent totalBytesExpected:(int64_t)totalBytesExpected forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (!self.doctorUploadProgressLastUpdate) self.doctorUploadProgressLastUpdate = [NSMutableDictionary dictionary];
    NSNumber *last = self.doctorUploadProgressLastUpdate[entryPath];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL isFinal = totalBytesExpected > 0 && bytesSent >= totalBytesExpected;
    if (last && !isFinal && (now - last.doubleValue) < kZSDoctorProgressMinUpdateInterval) return;
    self.doctorUploadProgressLastUpdate[entryPath] = @(now);

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorUploadProgress = bytesSent;
        entryToMutate.doctorUploadTotalBytes = totalBytesExpected;
    }
                                                                           error:&error];
    if (!updated) return;
    if (![self zs_updateDoctorProgressLabelForEntry:updated downloadInFlight:NO]) {
        [self zs_rebuildModsLibrary];
    }
}

- (void)zs_doctorDispatchCompletedForEntryPath:(NSString *)entryPath
                                        inFolder:(NSString *)folderName
                                          handle:(ZTranscoderHandle *)handle
                                           error:(NSError *)error {
    [self.doctorUploadProgressLastUpdate removeObjectForKey:entryPath];

    if (error) {
        [self zs_doctorFailEntryAtPath:entryPath inFolder:folderName error:error];
        return;
    }

    if (handle.scratchBranch.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:handle.scratchBranch]) {
        [self zs_doctorFailEntryAtPath:entryPath inFolder:folderName
                                 error:ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"The local transcode completed without producing an installable bundle.")];
        return;
    }

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusProcessing;
        entryToMutate.doctorProcessProgress = 1.0;
        entryToMutate.doctorScratchBranch = handle.scratchBranch;
        entryToMutate.doctorRunID = nil;
        entryToMutate.doctorRunURL = nil;
        entryToMutate.doctorDispatchCompressedByteSize = handle.compressedByteSize;
        entryToMutate.doctorLastError = nil;
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] transcode finished for %@ but its manifest entry is gone.", entryPath.lastPathComponent);
        return;
    }
    [self zs_rebuildModsLibrary];
    ZLog(@"[Mods Library] %@ transcode finished, installing immediately from %@.", entryPath.lastPathComponent, handle.scratchBranch);
    [self zs_doctorInstallUsingKnownTargetForDoctoredURL:[NSURL fileURLWithPath:handle.scratchBranch]
                                               entryPath:entryPath
                                                inFolder:folderName];
    NSString *warningMessage = handle.warningMessage;
    if (warningMessage.length > 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf zs_presentModsAlertWithTitle:@"Some Objects Were Skipped" message:warningMessage];
        });
    }
}

- (void)zs_doctorFailEntryAtPath:(NSString *)entryPath inFolder:(NSString *)folderName error:(NSError *)error {
    [self zs_stopDoctorPollTimerForEntryPath:entryPath];

    NSError *stateError = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusFailed;
        entryToMutate.doctorLastError = error.localizedDescription ?: @"Unknown error.";
    }
                                                                           error:&stateError];
    if (!updated) {
        ZLog(@"[Mods Library] couldn't record doctor failure for %@ (entry deleted mid-flight?): %@", entryPath.lastPathComponent, stateError);
        return;
    }
    ZLog(@"[Mods Library] %@ doctor pipeline failed: %@", entryPath.lastPathComponent, error.localizedDescription ?: @"Unknown error.");
    [self zs_rebuildModsLibrary];
}

#pragma mark Mods (doctor pipeline) - legacy poll cleanup

- (void)zs_stopDoctorPollTimerForEntryPath:(NSString *)entryPath {
    NSTimer *timer = self.doctorPollTimers[entryPath];
    if (timer) ZLog(@"[Mods Library] stopping doctor poll timer for %@.", entryPath.lastPathComponent);
    [timer invalidate];
    [self.doctorPollTimers removeObjectForKey:entryPath];
}

- (void)zs_pollAllActiveDoctorEntriesImmediately {
    for (NSString *entryPath in self.doctorPollTimers.allKeys) {
        NSString *folderName = zs_mods_folder_name_for_entry(zs_mods_entry_placeholder_for_path(entryPath));
        [self zs_pollDoctorRunForEntryPath:entryPath inFolder:folderName];
    }
}

- (void)zs_pollDoctorRunForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    ZLog(@"[Mods Library] ignoring legacy remote poll for %@ because visual mods now transcode entirely on-device.", entryPath.lastPathComponent);
    [self zs_stopDoctorPollTimerForEntryPath:entryPath];
    (void)folderName;
}

- (void)zs_doctorHandleProcessProgress:(double)fractionComplete forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSInteger percent = (NSInteger)round(MAX(0.0, MIN(1.0, fractionComplete)) * 100.0);
    if (!self.doctorProcessProgressLastPercent) self.doctorProcessProgressLastPercent = [NSMutableDictionary dictionary];
    NSNumber *last = self.doctorProcessProgressLastPercent[entryPath];
    if (last && last.integerValue == percent) return;
    self.doctorProcessProgressLastPercent[entryPath] = @(percent);

    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorProcessProgress = fractionComplete;
    }
                                                                           error:&error];
    if (!updated) return;
    [self zs_rebuildModsLibrary];
}

- (void)zs_recoverStaleDoctorStateForThisLaunch {
    if (self.doctorStateRecoveredThisLaunch) return;
    self.doctorStateRecoveredThisLaunch = YES;

    NSInteger interruptedTranscodes = 0;
    NSInteger recoveredOutputs = 0;
    for (NSString *folderName in [ModAssetLibrary folderNames]) {
        NSError *error = nil;
        NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&error];
        for (ModAssetLibraryEntry *entry in entries) {
            if (entry.doctorStatus == ModAssetLibraryDoctorStatusUploading) {
                interruptedTranscodes++;
                [ModAssetLibrary updateDoctorStateForEntry:entry
                                                    inFolder:folderName
                                                  applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                    entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusFailed;
                    entryToMutate.doctorLastError = @"On-device transcoding was interrupted (the app was closed or backgrounded mid-transcode). Tap Retry to run it again.";
                }
                                                       error:nil];
            } else if (entry.doctorStatus == ModAssetLibraryDoctorStatusProcessing || entry.doctorStatus == ModAssetLibraryDoctorStatusReadyToDownload) {
                NSString *outputPath = entry.doctorScratchBranch;
                if (outputPath.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:outputPath]) {
                    recoveredOutputs++;
                    [ModAssetLibrary updateDoctorStateForEntry:entry
                                                        inFolder:folderName
                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                        entryToMutate.doctorProcessProgress = 1.0;
                        entryToMutate.doctorLastError = nil;
                    }
                                                           error:nil];
                    [self zs_doctorInstallUsingKnownTargetForDoctoredURL:[NSURL fileURLWithPath:outputPath]
                                                               entryPath:entry.path
                                                                inFolder:folderName];
                } else {
                    interruptedTranscodes++;
                    [ModAssetLibrary updateDoctorStateForEntry:entry
                                                        inFolder:folderName
                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                        entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusFailed;
                        entryToMutate.doctorLastError = @"On-device transcoding was interrupted (the app was closed or backgrounded mid-transcode). Tap Retry to run it again.";
                    }
                                                           error:nil];
                }
            }
        }
    }
    if (interruptedTranscodes > 0 || recoveredOutputs > 0) {
        ZLog(@"[Mods Library] launch recovery: %ld interrupted local transcode(s) marked Failed, %ld completed output(s) sent directly to install.",
             (long)interruptedTranscodes, (long)recoveredOutputs);
    }
}

- (void)zs_presentLoadModsFinalSummary {
    NSArray<NSString *> *lines = self.loadModsSummaryLines ?: @[];
    self.loadModsSummaryLines = nil;

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    if (lines.count == 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
        [self zs_presentModsAlertWithTitle:@"No Files Loaded" message:@"No files were submitted."];
        return;
    }

    NSMutableArray<NSString *> *overlapLines = [NSMutableArray array];
    NSMutableArray<NSString *> *summaryLines = [NSMutableArray array];
    for (NSString *line in lines) {
        if ([line containsString:ModAssetLibraryOverlapPhrase]) {
            [overlapLines addObject:line];
        } else {
            [summaryLines addObject:line];
        }
    }

    BOOL anySucceeded = NO;
    for (NSString *line in summaryLines) {
        if ([line rangeOfString:@": swapped"].location != NSNotFound || [line rangeOfString:@": installed"].location != NSNotFound) {
            anySucceeded = YES;
            break;
        }
    }

    __weak typeof(self) weakSelf = self;
    dispatch_block_t presentSummary = ^{
        if (summaryLines.count == 0) return;
        NSString *message = [summaryLines componentsJoinedByString:@"\n"];
        if (anySucceeded) {
            message = [message stringByAppendingString:@"\n\nRestart the game for swapped/installed files to take effect."];
        }
        [weakSelf zs_presentModsAlertWithTitle:@"Load Mods" message:message offersRestart:anySucceeded];
    };

    if (overlapLines.count > 0) {
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Mod Overlap"
                                    message:[overlapLines componentsJoinedByString:@"\n"]
                              offersRestart:NO
                             dismissHandler:presentSummary];
        return;
    }

    [haptic notificationOccurred:anySucceeded ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeWarning];
    presentSummary();
}

- (void)zs_presentModsAlertWithTitle:(NSString *)title message:(NSString *)message {
    [self zs_presentModsAlertWithTitle:title message:message offersRestart:NO dismissHandler:nil];
}

- (void)zs_presentModsAlertWithTitle:(NSString *)title message:(NSString *)message offersRestart:(BOOL)offersRestart {
    [self zs_presentModsAlertWithTitle:title message:message offersRestart:offersRestart dismissHandler:nil];
}

- (void)zs_presentModsAlertWithTitle:(NSString *)title
                              message:(NSString *)message
                        offersRestart:(BOOL)offersRestart
                       dismissHandler:(nullable dispatch_block_t)dismissHandler {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[BankTransplant] %@: %@", title, message);
        if (dismissHandler) dismissHandler();
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (dismissHandler) dismissHandler();
    }]];
    if (offersRestart) zs_add_restart_action(alert);
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark Mods Library

- (void)zs_promptForModFolderNameWithTitle:(NSString *)title
                                actionTitle:(NSString *)actionTitle
                                 completion:(void (^)(NSString *trimmedName))completion {
    [self zs_promptForModFolderNameWithTitle:title actionTitle:actionTitle hintText:nil completion:completion];
}

- (void)zs_promptForModFolderNameWithTitle:(NSString *)title
                                actionTitle:(NSString *)actionTitle
                                   hintText:(NSString *)hintText
                                 completion:(void (^)(NSString *trimmedName))completion {
    [self zs_presentFloatingTextFieldWithInitialText:nil
                                          placeholder:@"Folder name"
                                               secure:NO
                                             hintText:hintText
                                         resetHandler:nil
                                           completion:^(NSString * _Nullable trimmedText) {
        if (trimmedText.length == 0) return;
        completion(trimmedText);
    }];
}

- (void)zs_refreshManifestZeroingRow {
    ZSRow *row = self.manifestZeroingRow;
    if (!row) return;

    BOOL fullZeroing = PatchManifestNetwork.isFullZeroingEnabled;
    BOOL eligible = !fullZeroing && zs_mod_library_has_zeroable_assets();
    CGFloat alpha = eligible ? 1.0 : 0.35;
    row.toggle.enabled = eligible;
    row.toggle.alpha = alpha;
    row.titleLabel.alpha = alpha;
    [row.toggle setOn:(fullZeroing || (eligible && PatchManifestNetwork.isZeroAllEnabled)) animated:NO];
}

- (void)zs_rebuildModsLibrary {
    [self zs_refreshManifestZeroingRow];
    if (!self.modsLibraryStack) return;

    [self zs_recoverStaleDoctorStateForThisLaunch];
    if (self.modsOptionsDropdownOpen) [self zs_closeModsOptionsDropdownAnimated:NO];

    for (UIView *view in self.modsLibraryStack.arrangedSubviews) {
        UIButton *deleteButton = objc_getAssociatedObject(view, "zs_button_delete");
        if (deleteButton) {
            UIView *capsuleGlass = objc_getAssociatedObject(deleteButton, kZSHoldConfirmGlassViewKey);
            [capsuleGlass removeFromSuperview];
        }
        [self.modsLibraryStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    UIButton *openButton = zs_make_grouped_action_button(@"Open Mod Library", zs_accent_green_color());
    [openButton addTarget:self action:@selector(zs_openModLibraryTapped) forControlEvents:UIControlEventTouchUpInside];
    UIView *libraryCard = zs_make_grouped_action_card(@[openButton, [self zs_makeStoredBackupsSection], [self zs_makeLz4hcCompressSection]]);
    libraryCard.layer.borderWidth = 1;
    libraryCard.layer.borderColor = [zs_accent_green_color() colorWithAlphaComponent:0.2].CGColor;
    [self.modsLibraryStack addArrangedSubview:libraryCard];
    [self.modsLibraryStack setCustomSpacing:8 afterView:libraryCard];

    if (self.modsLibraryBrowseMode && self.assetExplorerFullScreenOpen) {
        BOOL wasShowingDetails = self.modsLibrarySelectedEntry != nil;
        [self zs_assetExplorerRefreshModLibraryEntries];
        if (self.modsLibrarySelectedEntry) {
            [self zs_assetExplorerShowModLibraryEntry:self.modsLibrarySelectedEntry];
        } else if (wasShowingDetails) {
            [self zs_assetExplorerShowModLibrary];
        } else {
            [self zs_assetExplorerRefreshListResettingScroll:NO];
        }
    }
}

- (UIView *)zs_makeStoredBackupsSection {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *button = zs_make_grouped_action_button(@"Delete Stored Backups", [UIColor colorWithWhite:0.9 alpha:1]);
    [button addTarget:self action:@selector(zs_storedBackupsToggleTapped:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:button];

    UILabel *subtext = [[UILabel alloc] init];
    subtext.translatesAutoresizingMaskIntoConstraints = NO;
    subtext.font = zs_mono_font(8, UIFontWeightRegular);
    subtext.textColor = [UIColor colorWithWhite:1 alpha:0.4];
    subtext.numberOfLines = 0;
    subtext.text = @"Calculating backup size...";
    [subtext setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [row addSubview:subtext];

    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:row.topAnchor],
        [button.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [button.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight],
        [subtext.topAnchor constraintEqualToAnchor:row.topAnchor constant:kZSGroupedCardRowHeight - 4],
        [subtext.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [subtext.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [subtext.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-9],
    ]];
    objc_setAssociatedObject(row, "zs_selfSizingRow", @YES, OBJC_ASSOCIATION_RETAIN);

    UIView *expansion = [[UIView alloc] init];
    expansion.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *topSeparator = zs_make_stored_backups_separator();
    UILabel *expansionLabel = [[UILabel alloc] init];
    expansionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    expansionLabel.numberOfLines = 0;
    expansionLabel.font = zs_mono_font(11, UIFontWeightMedium);
    expansionLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    UIView *confirmSeparator = zs_make_stored_backups_separator();
    UIButton *confirm = zs_make_grouped_action_button(@"Confirm", zs_stored_backups_red_color());
    confirm.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [confirm addTarget:self action:@selector(zs_storedBackupsConfirmTapped:) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *view in @[topSeparator, expansionLabel, confirmSeparator, confirm]) [expansion addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [topSeparator.topAnchor constraintEqualToAnchor:expansion.topAnchor],
        [topSeparator.leadingAnchor constraintEqualToAnchor:expansion.leadingAnchor],
        [topSeparator.trailingAnchor constraintEqualToAnchor:expansion.trailingAnchor],
        [expansionLabel.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor constant:12],
        [expansionLabel.leadingAnchor constraintEqualToAnchor:expansion.leadingAnchor],
        [expansionLabel.trailingAnchor constraintEqualToAnchor:expansion.trailingAnchor],
        [confirmSeparator.topAnchor constraintEqualToAnchor:expansionLabel.bottomAnchor constant:12],
        [confirmSeparator.leadingAnchor constraintEqualToAnchor:expansion.leadingAnchor],
        [confirmSeparator.trailingAnchor constraintEqualToAnchor:expansion.trailingAnchor],
        [confirm.topAnchor constraintEqualToAnchor:confirmSeparator.bottomAnchor],
        [confirm.leadingAnchor constraintEqualToAnchor:expansion.leadingAnchor],
        [confirm.trailingAnchor constraintEqualToAnchor:expansion.trailingAnchor],
        [confirm.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight],
        [confirm.bottomAnchor constraintEqualToAnchor:expansion.bottomAnchor],
    ]];

    UIView *wrapper = zs_make_reveal_wrapper(expansion, g_zsStoredBackupsExpanded);
    UIStackView *section = [[UIStackView alloc] initWithArrangedSubviews:@[row, wrapper]];
    section.axis = UILayoutConstraintAxisVertical;
    section.spacing = 0;
    section.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(section, "zs_selfSizingRow", @YES, OBJC_ASSOCIATION_RETAIN);

    objc_setAssociatedObject(section, "zs_backupsWrapper", wrapper, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(section, "zs_backupsSubtext", subtext, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(section, "zs_backupsExpansionLabel", expansionLabel, OBJC_ASSOCIATION_RETAIN);

    [self zs_refreshStoredBackupsSizeForCard:section];
    return section;
}

- (UIView *)zs_makeLz4hcCompressSection {
    UIButton *button = zs_make_grouped_action_button(@"LZ4HC Compress Bundles", [UIColor colorWithRed:1.0 green:0.72 blue:0.3 alpha:1.0]);
    [button addTarget:self action:@selector(zs_lz4hcToggleTapped:) forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight].active = YES;

    UIView *expansion = [[UIView alloc] init];
    expansion.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *topSeparator = zs_make_stored_backups_separator();
    UILabel *expansionLabel = [[UILabel alloc] init];
    expansionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    expansionLabel.numberOfLines = 0;
    expansionLabel.font = zs_mono_font(11, UIFontWeightMedium);
    expansionLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    UIView *confirmSeparator = zs_make_stored_backups_separator();
    UIButton *confirm = zs_make_grouped_action_button(@"Confirm", zs_accent_green_color());
    confirm.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [confirm addTarget:self action:@selector(zs_lz4hcConfirmTapped:) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *view in @[topSeparator, expansionLabel, confirmSeparator, confirm]) [expansion addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [topSeparator.topAnchor constraintEqualToAnchor:expansion.topAnchor],
        [topSeparator.leadingAnchor constraintEqualToAnchor:expansion.leadingAnchor],
        [topSeparator.trailingAnchor constraintEqualToAnchor:expansion.trailingAnchor],
        [expansionLabel.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor constant:12],
        [expansionLabel.leadingAnchor constraintEqualToAnchor:expansion.leadingAnchor],
        [expansionLabel.trailingAnchor constraintEqualToAnchor:expansion.trailingAnchor],
        [confirmSeparator.topAnchor constraintEqualToAnchor:expansionLabel.bottomAnchor constant:12],
        [confirmSeparator.leadingAnchor constraintEqualToAnchor:expansion.leadingAnchor],
        [confirmSeparator.trailingAnchor constraintEqualToAnchor:expansion.trailingAnchor],
        [confirm.topAnchor constraintEqualToAnchor:confirmSeparator.bottomAnchor],
        [confirm.leadingAnchor constraintEqualToAnchor:expansion.leadingAnchor],
        [confirm.trailingAnchor constraintEqualToAnchor:expansion.trailingAnchor],
        [confirm.heightAnchor constraintEqualToConstant:kZSGroupedCardRowHeight],
        [confirm.bottomAnchor constraintEqualToAnchor:expansion.bottomAnchor],
    ]];

    BOOL expanded = g_zsLz4hcExpanded && g_zsLz4hcPendingPaths.count > 0;
    g_zsLz4hcExpanded = expanded;
    if (expanded) expansionLabel.text = [self zs_lz4hcPromptForCount:g_zsLz4hcPendingPaths.count];

    UIView *wrapper = zs_make_reveal_wrapper(expansion, expanded);
    UIStackView *section = [[UIStackView alloc] initWithArrangedSubviews:@[button, wrapper]];
    section.axis = UILayoutConstraintAxisVertical;
    section.spacing = 0;
    section.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(section, "zs_selfSizingRow", @YES, OBJC_ASSOCIATION_RETAIN);

    objc_setAssociatedObject(section, "zs_lz4Wrapper", wrapper, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(section, "zs_lz4Label", expansionLabel, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(section, "zs_lz4Button", button, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(section, "zs_lz4Confirm", confirm, OBJC_ASSOCIATION_RETAIN);
    return section;
}

- (NSString *)zs_lz4hcPromptForCount:(NSUInteger)count {
    return [NSString stringWithFormat:@"Found %lu uncompressed bundle(s), compress them? This can take a while.", (unsigned long)count];
}

- (void)zs_refreshStoredBackupsSizeForCard:(UIView *)card {
    __weak UIView *weakCard = card;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long bytes = [ZSModsPaths modsBackupsByteSize];
        NSString *size = zs_stored_backups_size_string(bytes);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *strongCard = weakCard;
            if (!strongCard) return;
            UILabel *subtext = objc_getAssociatedObject(strongCard, "zs_backupsSubtext");
            UILabel *expansionLabel = objc_getAssociatedObject(strongCard, "zs_backupsExpansionLabel");
            subtext.text = [NSString stringWithFormat:@"Backups folder is taking up %@", size];
            expansionLabel.text = [NSString stringWithFormat:@"Deleting stored backups will reclaim %@ of storage.\n\nHowever, deleting mods without backups will prompt you to download those files again, are you sure you want to continue?", size];
        });
    });
}

- (void)zs_storedBackupsToggleTapped:(UIButton *)sender {
    UIView *card = zs_stored_backups_card_for_view(sender);
    UIView *wrapper = objc_getAssociatedObject(card, "zs_backupsWrapper");
    if (!wrapper) return;

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    g_zsStoredBackupsExpanded = !g_zsStoredBackupsExpanded;
    BOOL expanded = g_zsStoredBackupsExpanded;
    if (expanded) [self zs_refreshStoredBackupsSizeForCard:card];
    [self zs_lowResAnimateChanges:^{
        zs_reveal_set_expanded(wrapper, expanded);
    }];
}

- (void)zs_storedBackupsConfirmTapped:(UIButton *)sender {
    UIView *card = zs_stored_backups_card_for_view(sender);
    __weak UIView *weakCard = card;
    __weak typeof(self) weakSelf = self;

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeWarning];

    sender.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [ZSModsPaths deleteAllStoredBackupsWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            UINotificationFeedbackGenerator *result = [UINotificationFeedbackGenerator new];
            [result notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];

            g_zsStoredBackupsExpanded = NO;
            UIView *strongCard = weakCard;
            UIView *wrapper = objc_getAssociatedObject(strongCard, "zs_backupsWrapper");
            if (wrapper) {
                [strongSelf zs_lowResAnimateChanges:^{
                    zs_reveal_set_expanded(wrapper, NO);
                }];
            }
            if (strongCard) [strongSelf zs_refreshStoredBackupsSizeForCard:strongCard];
            if (!ok) {
                [strongSelf zs_presentModsAlertWithTitle:@"Couldn't Delete Backups" message:error.localizedDescription ?: @"Unknown error."];
            }
        });
    });
}

- (void)zs_openModLibraryTapped {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self zs_openModLibraryFullScreenPanel];
}

- (void)zs_openModLibraryInFolder:(NSString *)folderName {
    if (folderName.length == 0 || ![[ModAssetLibrary folderNames] containsObject:folderName]) return;
    BOOL alreadyBrowsing = self.assetExplorerFullScreenOpen && self.modsLibraryBrowseMode;
    if (!alreadyBrowsing) {
        if (self.assetExplorerFullScreenOpen) return;
        [self zs_openModLibraryFullScreenPanel];
        if (!self.assetExplorerFullScreenOpen) return;
    }
    if (self.modsLibrarySelectedEntry) {
        [self zs_assetExplorerShowModLibrary];
    } else {
        [self zs_assetExplorerRefreshModLibraryEntries];
    }
    [self zs_modsLibraryOpenFolder:folderName];
}

- (void)zs_modsLibraryFolderRowTapped:(UITapGestureRecognizer *)gesture {
    NSString *folderName = objc_getAssociatedObject(gesture.view, "zs_modsFolderName");
    if (!folderName) return;
    BOOL wasExpanded = [self.modsLibraryExpandedFolders containsObject:folderName];
    if (wasExpanded) {
        [self.modsLibraryExpandedFolders removeObject:folderName];
    } else {
        [self.modsLibraryExpandedFolders addObject:folderName];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_modsLibraryEntryInfoTapped:(UITapGestureRecognizer *)gesture {
    ModAssetLibraryEntry *entry = objc_getAssociatedObject(gesture.view, "zs_modsEntry");
    if (!entry) return;
    if ([self.modsLibraryExpandedInfoEntries containsObject:entry.path]) {
        [self.modsLibraryExpandedInfoEntries removeObject:entry.path];
    } else {
        [self.modsLibraryExpandedInfoEntries addObject:entry.path];
    }
    [self zs_rebuildModsLibrary];
}

#pragma mark Mods Library file options dropdown (3.4)

- (void)zs_modsLibraryEntryOptionsTapped:(UIButton *)sender {
    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;

    if (self.modsOptionsDropdownOpen && self.modsOptionsDropdownButton == sender) {
        [self zs_closeModsOptionsDropdownAnimated:YES];
        return;
    }
    if (self.modsOptionsDropdownOpen) {
        [self zs_closeModsOptionsDropdownAnimated:NO];
    }

    [self zs_openModsOptionsDropdownForButton:sender entry:entry folderName:zs_mods_folder_name_for_entry(entry)];
}

- (void)zs_modsLibraryFolderOptionsTapped:(UIButton *)sender {
    NSString *folderName = objc_getAssociatedObject(sender, "zs_modsFolderName");
    if (!folderName) return;

    if (self.modsOptionsDropdownOpen && self.modsOptionsDropdownButton == sender) {
        [self zs_closeModsOptionsDropdownAnimated:YES];
        return;
    }
    if (self.modsOptionsDropdownOpen) {
        [self zs_closeModsOptionsDropdownAnimated:NO];
    }

    [self zs_openModsOptionsDropdownForButton:sender entry:nil folderName:folderName];
}

- (void)zs_openModsOptionsDropdownForButton:(UIButton *)button entry:(nullable ModAssetLibraryEntry *)entry folderName:(NSString *)folderName {
    if (!button || !self.contentOverlay || self.modsOptionsDropdownOpen || !folderName) return;

    BOOL isStoredBundlesRow = entry && zs_mods_folder_is_or_within_stored_bundles(folderName);
    NSArray<NSDictionary<NSString *, id> *> *options = entry
        ? (isStoredBundlesRow ? zs_mods_stored_bundle_file_options() : zs_mods_file_options(entry))
        : zs_mods_options_for_folder(folderName);
    if (options.count == 0) return;

    CGRect buttonFrame = [button convertRect:button.bounds toView:self.contentOverlay];

    CGRect collapsedFrame = CGRectMake(CGRectGetMaxX(buttonFrame) - kZSModsOptionsDropdownWidth,
                                        CGRectGetMinY(buttonFrame),
                                        kZSModsOptionsDropdownWidth,
                                        CGRectGetHeight(buttonFrame));

    UIControl *scrim = [[UIControl alloc] initWithFrame:self.contentOverlay.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = UIColor.clearColor;
    [scrim addTarget:self action:@selector(zs_modsOptionsDropdownScrimTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentOverlay addSubview:scrim];
    self.modsOptionsDropdownScrim = scrim;

    UIView *overlay;
    UIVisualEffectView *glassOverlay = nil;
    if (zs_has_liquid_glass()) {

        glassOverlay = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(YES)];
        glassOverlay.frame = collapsedFrame;
        glassOverlay.clipsToBounds = YES;
        zs_configure_glass_corners(glassOverlay, kZSAuthFieldCornerRadius, NO);
        glassOverlay.layer.borderWidth = 1;
        glassOverlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        zs_register_suspendable_glass(glassOverlay);
        overlay = glassOverlay;
    } else {
        overlay = [[UIView alloc] initWithFrame:collapsedFrame];
        overlay.clipsToBounds = YES;
        overlay.layer.cornerRadius = kZSAuthFieldCornerRadius;
        overlay.layer.cornerCurve = kCACornerCurveContinuous;
        overlay.layer.borderWidth = 1;
        overlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        overlay.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.98];
    }
    overlay.alpha = 0;
    [self.contentOverlay addSubview:overlay];
    self.modsOptionsDropdownOverlay = overlay;

    UIView *rowHost = glassOverlay ? glassOverlay.contentView : overlay;

    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        UIButton *rowButton = zs_make_mods_options_row_button(options[i], i, self,
                                                                @selector(zs_modsOptionsDropdownRowTapped:));
        rowButton.frame = CGRectMake(0, i * kZSModsOptionsRowHeight,
                                      kZSModsOptionsDropdownWidth, kZSModsOptionsRowHeight);
        rowButton.alpha = 0;
        [rowHost addSubview:rowButton];

        if (i > 0) {
            CGFloat hairline = 1.0 / MAX(UIScreen.mainScreen.scale, (CGFloat)1.0);
            UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, i * kZSModsOptionsRowHeight - hairline,
                                                                        kZSModsOptionsDropdownWidth, hairline)];
            divider.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.5];
            divider.alpha = 0;
            [rowHost addSubview:divider];
        }
    }

    button.hidden = YES;
    self.modsOptionsDropdownButton = button;
    self.modsOptionsDropdownEntry = entry;
    self.modsOptionsDropdownFolderName = folderName;
    self.modsOptionsDropdownOpen = YES;

    CGFloat expandedHeight = kZSModsOptionsRowHeight * options.count;
    CGRect expandedFrame = CGRectMake(CGRectGetMinX(collapsedFrame), CGRectGetMinY(collapsedFrame),
                                       kZSModsOptionsDropdownWidth, expandedHeight);
    [UIView animateWithDuration:0.22
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        overlay.frame = expandedFrame;
        for (UIView *subview in rowHost.subviews) {
            subview.alpha = 1;
        }
    } completion:nil];
    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        overlay.alpha = 1;
    } completion:nil];

    UISelectionFeedbackGenerator *haptic = [UISelectionFeedbackGenerator new];
    [haptic selectionChanged];
}

- (void)zs_closeModsOptionsDropdownAnimated:(BOOL)animated {
    if (!self.modsOptionsDropdownOpen) return;

    UIView *overlay = self.modsOptionsDropdownOverlay;
    UIControl *scrim = self.modsOptionsDropdownScrim;
    UIButton *button = self.modsOptionsDropdownButton;
    self.modsOptionsDropdownOverlay = nil;
    self.modsOptionsDropdownScrim = nil;
    self.modsOptionsDropdownButton = nil;
    self.modsOptionsDropdownEntry = nil;
    self.modsOptionsDropdownFolderName = nil;
    self.modsOptionsDropdownOpen = NO;

    if (!button || !button.superview) {
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
        return;
    }

    CGRect collapsedFrame = [button convertRect:button.bounds toView:self.contentOverlay];
    CGRect collapsedDropdownFrame = CGRectMake(CGRectGetMaxX(collapsedFrame) - kZSModsOptionsDropdownWidth,
                                                CGRectGetMinY(collapsedFrame),
                                                kZSModsOptionsDropdownWidth,
                                                CGRectGetHeight(collapsedFrame));

    void (^finish)(void) = ^{
        [overlay removeFromSuperview];
        [scrim removeFromSuperview];
        button.hidden = NO;
    };

    if (!animated) {
        finish();
        return;
    }

    [UIView animateWithDuration:0.18
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        overlay.frame = collapsedDropdownFrame;
        overlay.alpha = 0;
    } completion:^(BOOL finished) {
        finish();
    }];
}

- (void)zs_modsLibraryPerformOptionNamed:(NSString *)title forEntry:(nullable ModAssetLibraryEntry *)entry folderName:(NSString *)folderName {
    if (folderName.length == 0 || title.length == 0) return;

    if (!entry) {
        if ([title isEqualToString:@"Add mod"]) {
            [self zs_presentModImportPickerForFolder:folderName];
        } else if ([title isEqualToString:@"Rename"]) {
            [self zs_promptForModFolderRenameForFolder:folderName];
        } else if ([title isEqualToString:@"Cache folder"]) {
            [self zs_cacheModFolder:folderName];
        } else if ([title isEqualToString:@"Add remark"]) {
            [self zs_promptForModFolderRemarkForFolder:folderName];
        } else if ([title isEqualToString:@"Re-place"]) {
            [self zs_rePlaceModFolder:folderName];
        } else if ([title isEqualToString:@"Delete"]) {
            [self zs_confirmDeleteModFolder:folderName];
        } else if ([title isEqualToString:@"Restore"]) {
            [self zs_restoreStoredModFolder:folderName];
        }
        return;
    }

    if ([title isEqualToString:@"Cache bundle"]) {
        [self zs_cacheBundleEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Restore"]) {
        [self zs_restoreStoredBundleEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Add remark"]) {
        [self zs_promptForModRemarkForEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Re-place"]) {
        [self zs_rePlaceModEntry:entry inFolder:folderName];
    } else if ([title isEqualToString:@"Delete"]) {
        [self zs_confirmDeleteModEntry:entry inFolder:folderName];
    }
}

- (void)zs_modsOptionsDropdownRowTapped:(UIButton *)sender {
    ModAssetLibraryEntry *entry = self.modsOptionsDropdownEntry;
    NSString *folderName = self.modsOptionsDropdownFolderName;
    BOOL isFolderMode = (entry == nil);
    BOOL isStoredBundlesRow = !isFolderMode && zs_mods_folder_is_or_within_stored_bundles(folderName);
    NSArray<NSDictionary<NSString *, id> *> *options = isFolderMode ? zs_mods_options_for_folder(folderName)
        : (isStoredBundlesRow ? zs_mods_stored_bundle_file_options() : zs_mods_file_options(entry));
    if (sender.tag < 0 || sender.tag >= (NSInteger)options.count) {
        [self zs_closeModsOptionsDropdownAnimated:YES];
        return;
    }

    NSDictionary<NSString *, id> *tappedOption = options[sender.tag];
    [self zs_closeModsOptionsDropdownAnimated:YES];
    if (!folderName || (!isFolderMode && !entry)) return;

    if ([tappedOption[@"disabled"] boolValue]) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        return;
    }

    [self zs_modsLibraryPerformOptionNamed:tappedOption[@"title"] forEntry:entry folderName:folderName];
}

- (void)zs_modsOptionsDropdownScrimTapped:(UIControl *)sender {
    [self zs_closeModsOptionsDropdownAnimated:YES];
}

static NSURL *zs_mods_live_stock_url_for_entry(ModAssetLibraryEntry *entry) {
    if (entry.livePathDescription.length == 0) return nil;
    NSString *absolute = [NSHomeDirectory() stringByAppendingPathComponent:entry.livePathDescription];
    return [NSURL fileURLWithPath:absolute];
}

- (BOOL)zs_cacheBundleEntryCore:(ModAssetLibraryEntry *)entry
                        inFolder:(NSString *)folderName
                  toStoredFolder:(NSString *)storedFolder
                    partlyFailed:(BOOL *)outPartlyFailed
                           error:(NSError **)outError {
    if (outPartlyFailed) *outPartlyFailed = NO;
    BOOL isLiveInstalledBundle = entry.isAssetBundle && entry.doctorStatus == ModAssetLibraryDoctorStatusInstalled;
    BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);

    if (isBank) {
        NSError *bankErr = nil;
        NSInteger restored = [BankTransplant restoreBackedUpBankNamed:entry.fileName error:&bankErr];
        if (restored < 0) {
            if (outError) *outError = bankErr ?: [NSError errorWithDomain:@"ZSModsCache" code:6
                                                                   userInfo:@{NSLocalizedDescriptionKey: @"Couldn't restore the original bank before caching it."}];
            return NO;
        }
    }

    BOOL isFont = [ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown;
    if (isFont) {
        [ModAssetLibrary deactivateFontForEntry:entry];
    }

    NSURL *stockURL = isLiveInstalledBundle ? zs_mods_live_stock_url_for_entry(entry) : nil;
    if (isLiveInstalledBundle && !stockURL) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsCache" code:1
                                                    userInfo:@{NSLocalizedDescriptionKey: @"This entry's live location isn't known."}];
        return NO;
    }

    NSString *tempPath = nil;
    NSURL *replacementBytesURL = nil;
    if (stockURL) {

        tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        NSError *snapshotErr = nil;
        BOOL scoped = [stockURL startAccessingSecurityScopedResource];
        BOOL snapshotted = [NSFileManager.defaultManager copyItemAtURL:stockURL toURL:[NSURL fileURLWithPath:tempPath] error:&snapshotErr];
        if (scoped) [stockURL stopAccessingSecurityScopedResource];
        if (!snapshotted) {
            if (outError) *outError = snapshotErr ?: [NSError errorWithDomain:@"ZSModsCache" code:2
                                                                       userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the live bundle."}];
            return NO;
        }

        NSError *cacheErr = nil;
        if (![ZTranscoderInstaller cacheOriginalBackForStockBundleURL:stockURL error:&cacheErr]) {
            [NSFileManager.defaultManager removeItemAtPath:tempPath error:nil];
            if (outError) *outError = cacheErr ?: [NSError errorWithDomain:@"ZSModsCache" code:3
                                                                     userInfo:@{NSLocalizedDescriptionKey: @"Unknown error."}];
            return NO;
        }
        replacementBytesURL = [NSURL fileURLWithPath:tempPath];
    }

    if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
        [self zs_restoreLocalizationEntryBestEffort:entry];
    }

    entry.cachedFromFolder = folderName;
    NSError *moveErr = nil;
    ModAssetLibraryEntry *moved = [ModAssetLibrary moveEntry:entry
                                                    fromFolder:folderName
                                                      toFolder:storedFolder
                                           replacementBytesURL:replacementBytesURL
                                                         error:&moveErr];
    if (tempPath) [NSFileManager.defaultManager removeItemAtPath:tempPath error:nil];
    if (!moved) {

        ZLog(@"[Mods Library] couldn't move %@ into \"%@\": %@", entry.fileName, storedFolder, moveErr.localizedDescription);
        if (outPartlyFailed) *outPartlyFailed = (replacementBytesURL != nil);
        if (outError) *outError = moveErr ?: [NSError errorWithDomain:@"ZSModsCache" code:5
                                                                userInfo:@{NSLocalizedDescriptionKey: @"The entry couldn't be moved into Stored Bundles."}];
        return NO;
    }

    return YES;
}

- (void)zs_cacheBundleEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    NSError *createErr = nil;
    if (![ModAssetLibrary createFolderNamed:kZSStoredBundlesFolderName error:&createErr]
        && createErr.code != ModAssetLibraryErrorFolderAlreadyExists) {
        [self zs_presentModsAlertWithTitle:@"Store Failed"
                                    message:createErr.localizedDescription ?: @"Couldn't prepare Stored Bundles."];
        return;
    }

    BOOL partlyFailed = NO;
    NSError *error = nil;
    BOOL ok = [self zs_cacheBundleEntryCore:entry inFolder:folderName toStoredFolder:kZSStoredBundlesFolderName
                                partlyFailed:&partlyFailed error:&error];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:partlyFailed ? @"Store Partly Failed" : @"Store Failed"
                                    message:partlyFailed
                                        ? @"The live bundle was restored, but the entry couldn't be moved into Stored Bundles. See syslog."
                                        : (error.localizedDescription ?: @"Unknown error.")];
        [self zs_rebuildModsLibrary];
        return;
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    ZLog(@"[Mods Library] cached %@ from \"%@\" into \"%@\"", entry.fileName, folderName, kZSStoredBundlesFolderName);
    [self zs_rebuildModsLibrary];
}

- (void)zs_cacheModFolder:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    if (entries.count == 0) {
        [self zs_presentModsAlertWithTitle:@"Nothing to Cache" message:@"This folder has no mods in it."];
        return;
    }

    NSError *createErr = nil;
    if (![ModAssetLibrary createFolderNamed:kZSStoredBundlesFolderName error:&createErr]
        && createErr.code != ModAssetLibraryErrorFolderAlreadyExists) {
        [self zs_presentModsAlertWithTitle:@"Cache Folder Failed"
                                    message:createErr.localizedDescription ?: @"Couldn't prepare Stored Bundles."];
        return;
    }

    NSError *subErr = nil;
    NSString *destinationFolder = [ModAssetLibrary createUniqueSubFolderNamed:folderName
                                                                    insideFolder:kZSStoredBundlesFolderName
                                                                           error:&subErr];
    if (!destinationFolder) {
        [self zs_presentModsAlertWithTitle:@"Cache Folder Failed"
                                    message:subErr.localizedDescription ?: @"Couldn't make room for this folder inside Stored Bundles."];
        return;
    }

    NSInteger failureCount = 0;
    BOOL anyPartlyFailed = NO;
    for (ModAssetLibraryEntry *entry in entries) {
        BOOL partlyFailed = NO;
        NSError *error = nil;
        BOOL ok = [self zs_cacheBundleEntryCore:entry inFolder:folderName toStoredFolder:destinationFolder
                                    partlyFailed:&partlyFailed error:&error];
        if (!ok) {
            failureCount++;
            if (partlyFailed) anyPartlyFailed = YES;
            ZLog(@"[Mods Library] Cache folder %@: couldn't cache %@: %@", folderName, entry.fileName, error.localizedDescription);
        }
    }

    if (failureCount == entries.count) {
        NSError *cleanupErr = nil;
        if (![ModAssetLibrary deleteFolderNamed:destinationFolder error:&cleanupErr]) {
            ZLog(@"[Mods Library] Cache folder %@: couldn't clean up the empty \"%@\" after every item failed: %@",
                 folderName, destinationFolder, cleanupErr.localizedDescription);
        }
    } else {
        NSArray<ModAssetLibraryEntry *> *remaining = [ModAssetLibrary entriesInFolder:folderName error:nil];
        if (remaining.count == 0) {
            NSError *deleteErr = nil;
            if (![ModAssetLibrary deleteFolderNamed:folderName error:&deleteErr]) {
                ZLog(@"[Mods Library] Cache folder %@: cached every entry but couldn't remove the now-empty original folder: %@",
                     folderName, deleteErr.localizedDescription);
            }
        }
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:failureCount == 0 ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (failureCount > 0) {
        NSString *message = [NSString stringWithFormat:@"%ld of %ld mod%@ couldn't be moved into Stored Bundles.%@ See syslog.",
                              (long)failureCount, (long)entries.count, entries.count == 1 ? @"" : @"s",
                              anyPartlyFailed ? @" Some live bundles were already restored before the move failed." : @""];
        [self zs_presentModsAlertWithTitle:@"Cache Folder Partly Failed" message:message];
    }
    ZLog(@"[Mods Library] cache folder \"%@\": %ld of %lu entries cached into \"%@\"",
         folderName, (long)(entries.count - failureCount), (unsigned long)entries.count, destinationFolder);
    [self zs_rebuildModsLibrary];
}

- (void)zs_restoreStoredBundleEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    ModAssetLibraryEntry *overlapping = [ModAssetLibrary activeEntryOverlappingEntry:entry];
    if (overlapping) {
        UINotificationFeedbackGenerator *overlapHaptic = [UINotificationFeedbackGenerator new];
        [overlapHaptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Mod Overlap"
                                    message:[ModAssetLibrary overlapRejectionLineForName:[ModAssetLibrary displayNameForEntry:entry]
                                                                            existingEntry:overlapping]];
        return;
    }

    NSURL *stockURL = entry.isAssetBundle ? zs_mods_live_stock_url_for_entry(entry) : nil;

    NSArray<NSString *> *realFolders = [[ModAssetLibrary folderNames] mutableCopy];
    NSString *targetFolder = entry.cachedFromFolder;
    BOOL targetStillExists = targetFolder.length > 0 && [realFolders containsObject:targetFolder];
    if (targetStillExists) {
        [self zs_finishRestoringStoredBundleEntry:entry stockURL:stockURL intoFolder:targetFolder];
        return;
    }

    NSMutableArray<NSString *> *pickable = [realFolders mutableCopy];
    [pickable removeObject:kZSStoredBundlesFolderName];

    if (pickable.count == 0) {
        [self zs_promptForModFolderNameWithTitle:@"Choose a Folder"
                                      actionTitle:@"Create & Restore"
                                       completion:^(NSString *trimmedName) {
            NSError *createErr = nil;
            if (![ModAssetLibrary createFolderNamed:trimmedName error:&createErr]) {
                [self zs_presentModsAlertWithTitle:@"Couldn't Create Folder" message:createErr.localizedDescription ?: @"Unknown error."];
                return;
            }
            [self zs_finishRestoringStoredBundleEntry:entry stockURL:stockURL intoFolder:trimmedName];
        }];
        return;
    }

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Restore Into Which Folder?"
                                                                      message:[NSString stringWithFormat:@"\"%@\" no longer exists.", targetFolder ?: @"its original folder"]
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *candidate in pickable) {
        [sheet addAction:[UIAlertAction actionWithTitle:candidate style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self zs_finishRestoringStoredBundleEntry:entry stockURL:stockURL intoFolder:candidate];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)zs_finishRestoringStoredBundleEntry:(ModAssetLibraryEntry *)entry stockURL:(nullable NSURL *)stockURL intoFolder:(NSString *)destFolder {
    NSString *sourceFolder = zs_mods_folder_name_for_entry(entry) ?: kZSStoredBundlesFolderName;

    if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
        NSError *applyErr = nil;
        if (![self zs_applyLocalizationEntry:entry error:&applyErr]) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:applyErr.localizedDescription ?: @"Unknown error."];
            return;
        }
    }

    if (stockURL) {
        NSError *installErr = nil;
        if (![ZTranscoderInstaller installDoctoredBundleAtURL:[NSURL fileURLWithPath:entry.path]
                                              toStockBundleURL:stockURL
                                                          error:&installErr]) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:installErr.localizedDescription ?: @"Unknown error."];
            return;
        }
    }

    BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);
    if (isBank) {
        NSError *bankErr = nil;
        if (![BankTransplant transplantAndSwapModdedBankAtURL:[NSURL fileURLWithPath:entry.path] error:&bankErr]) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:bankErr.localizedDescription ?: @"Unknown error."];
            return;
        }
    }

    if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) {
        ModAssetLibraryEntry *roleOccupant = [ModAssetLibrary fontEntryOccupyingRole:entry.fontRole];
        if (roleOccupant) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:[NSString stringWithFormat:@"%@ is already assigned to \u201C%@\u201D. Cache or delete that font first.",
                                                 [ZSModsPaths displayNameForFontRole:entry.fontRole], [ModAssetLibrary displayNameForEntry:roleOccupant]]];
            return;
        }
        NSError *fontErr = nil;
        if (![ModAssetLibrary activateFontForEntry:entry error:&fontErr]) {
            [self zs_presentModsAlertWithTitle:@"Restore Failed"
                                        message:fontErr.localizedDescription ?: @"Unknown error."];
            return;
        }
    }

    NSError *moveErr = nil;
    if (![self zs_moveRestoredStoredBundleEntry:entry fromFolder:sourceFolder toFolder:destFolder error:&moveErr]) {
        [self zs_presentModsAlertWithTitle:@"Restore Partly Failed"
                                    message:@"The live bundle was restored, but the entry couldn't be moved out of Stored Bundles. See syslog."];
        [self zs_rebuildModsLibrary];
        return;
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    ZLog(@"[Mods Library] restored %@ from \"%@\" into \"%@\"", entry.fileName, sourceFolder, destFolder);
    [self zs_rebuildModsLibrary];
}

- (BOOL)zs_moveRestoredStoredBundleEntry:(ModAssetLibraryEntry *)entry
                               fromFolder:(NSString *)sourceFolder
                                 toFolder:(NSString *)destFolder
                                    error:(NSError **)outError {
    entry.cachedFromFolder = nil;
    NSError *moveErr = nil;
    ModAssetLibraryEntry *moved = [ModAssetLibrary moveEntry:entry
                                                    fromFolder:sourceFolder
                                                      toFolder:destFolder
                                           replacementBytesURL:nil
                                                         error:&moveErr];
    if (!moved) {
        ZLog(@"[Mods Library] restored %@'s live file but couldn't move its library entry back into \"%@\": %@", entry.fileName, destFolder, moveErr.localizedDescription);
        if (outError) *outError = moveErr;
        return NO;
    }

    if (![sourceFolder isEqualToString:kZSStoredBundlesFolderName]) {
        NSArray<ModAssetLibraryEntry *> *remaining = [ModAssetLibrary entriesInFolder:sourceFolder error:nil];
        if (remaining.count == 0) {
            NSError *deleteErr = nil;
            if (![ModAssetLibrary deleteFolderNamed:sourceFolder error:&deleteErr]) {
                ZLog(@"[Mods Library] restored the last item out of cached folder \"%@\" but couldn't remove it: %@",
                     sourceFolder, deleteErr.localizedDescription);
            }
        }
    }
    return YES;
}

- (void)zs_restoreStoredModFolder:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    if (entries.count == 0) {
        [self zs_presentModsAlertWithTitle:@"Nothing to Restore" message:@"This cached folder is empty."];
        return;
    }

    NSString *targetFolder = folderName.lastPathComponent;
    NSArray<NSString *> *realFolders = [ModAssetLibrary folderNames];
    BOOL targetStillExists = targetFolder.length > 0 && [realFolders containsObject:targetFolder];
    if (targetStillExists) {
        [self zs_finishRestoringStoredModFolder:folderName entries:entries intoFolder:targetFolder];
        return;
    }

    NSError *createErr = nil;
    if (![ModAssetLibrary createFolderNamed:targetFolder error:&createErr] && createErr.code != ModAssetLibraryErrorFolderAlreadyExists) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Create Folder" message:createErr.localizedDescription ?: @"Unknown error."];
        return;
    }
    [self zs_finishRestoringStoredModFolder:folderName entries:entries intoFolder:targetFolder];
}

- (void)zs_finishRestoringStoredModFolder:(NSString *)folderName
                                   entries:(NSArray<ModAssetLibraryEntry *> *)entries
                                intoFolder:(NSString *)destFolder {
    NSInteger failureCount = 0;
    NSMutableArray<NSString *> *overlapLines = [NSMutableArray array];
    for (ModAssetLibraryEntry *entry in entries) {
        ModAssetLibraryEntry *overlapping = [ModAssetLibrary activeEntryOverlappingEntry:entry];
        if (overlapping) {
            failureCount++;
            [overlapLines addObject:[ModAssetLibrary overlapRejectionLineForName:[ModAssetLibrary displayNameForEntry:entry]
                                                                    existingEntry:overlapping]];
            continue;
        }

        if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
            NSError *applyErr = nil;
            if (![self zs_applyLocalizationEntry:entry error:&applyErr]) {
                failureCount++;
                ZLog(@"[Mods Library] restore folder \"%@\": couldn't re-place %@: %@", folderName, entry.fileName, applyErr.localizedDescription);
                continue;
            }
        }

        NSURL *stockURL = entry.isAssetBundle ? zs_mods_live_stock_url_for_entry(entry) : nil;
        if (stockURL) {
            NSError *installErr = nil;
            if (![ZTranscoderInstaller installDoctoredBundleAtURL:[NSURL fileURLWithPath:entry.path]
                                                  toStockBundleURL:stockURL
                                                              error:&installErr]) {
                failureCount++;
                ZLog(@"[Mods Library] restore folder \"%@\": couldn't restore %@'s live file: %@", folderName, entry.fileName, installErr.localizedDescription);
                continue;
            }
        }

        BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);
        if (isBank) {
            NSError *bankErr = nil;
            if (![BankTransplant transplantAndSwapModdedBankAtURL:[NSURL fileURLWithPath:entry.path] error:&bankErr]) {
                failureCount++;
                ZLog(@"[Mods Library] restore folder \"%@\": couldn't restore %@'s live bank: %@", folderName, entry.fileName, bankErr.localizedDescription);
                continue;
            }
        }

        if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) {
            ModAssetLibraryEntry *roleOccupant = [ModAssetLibrary fontEntryOccupyingRole:entry.fontRole];
            if (roleOccupant) {
                failureCount++;
                ZLog(@"[Mods Library] restore folder \"%@\": %@'s %@ role is already assigned to %@", folderName, entry.fileName, [ZSModsPaths displayNameForFontRole:entry.fontRole], [ModAssetLibrary displayNameForEntry:roleOccupant]);
                continue;
            }
            NSError *fontErr = nil;
            if (![ModAssetLibrary activateFontForEntry:entry error:&fontErr]) {
                failureCount++;
                ZLog(@"[Mods Library] restore folder \"%@\": couldn't activate %@'s font: %@", folderName, entry.fileName, fontErr.localizedDescription);
                continue;
            }
        }

        NSError *moveErr = nil;
        if (![self zs_moveRestoredStoredBundleEntry:entry fromFolder:folderName toFolder:destFolder error:&moveErr]) {
            failureCount++;
        }
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:failureCount == 0 ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (overlapLines.count > 0) {
        NSInteger otherFailures = failureCount - (NSInteger)overlapLines.count;
        NSString *overlapMessage = [overlapLines componentsJoinedByString:@"\n"];
        if (otherFailures > 0) {
            overlapMessage = [overlapMessage stringByAppendingFormat:@"\n\n%ld other mod%@ couldn't be restored. See syslog.",
                              (long)otherFailures, otherFailures == 1 ? @"" : @"s"];
        }
        [self zs_presentModsAlertWithTitle:@"Mod Overlap" message:overlapMessage];
    } else if (failureCount > 0) {
        [self zs_presentModsAlertWithTitle:@"Restore Partly Failed"
                                    message:[NSString stringWithFormat:@"%ld of %ld mod%@ couldn't be restored. See syslog.",
                                             (long)failureCount, (long)entries.count, entries.count == 1 ? @"" : @"s"]];
    }
    ZLog(@"[Mods Library] restored cached folder \"%@\": %ld of %lu entries restored into \"%@\"",
         folderName, (long)(entries.count - failureCount), (unsigned long)entries.count, destFolder);
    [self zs_rebuildModsLibrary];
}

- (void)zs_presentFloatingTextFieldWithInitialText:(NSString *)initialText
                                        placeholder:(NSString *)placeholder
                                             secure:(BOOL)secure
                                         completion:(void (^)(NSString * _Nullable trimmedText))completion {
    [self zs_presentFloatingTextFieldWithInitialText:initialText
                                          placeholder:placeholder
                                               secure:secure
                                         resetHandler:nil
                                           completion:completion];
}

- (void)zs_presentFloatingTextFieldWithInitialText:(NSString *)initialText
                                        placeholder:(NSString *)placeholder
                                             secure:(BOOL)secure
                                       resetHandler:(void (^)(void))resetHandler
                                         completion:(void (^)(NSString * _Nullable trimmedText))completion {
    [self zs_presentFloatingTextFieldWithInitialText:initialText
                                          placeholder:placeholder
                                               secure:secure
                                             hintText:nil
                                         resetHandler:resetHandler
                                           completion:completion];
}

- (void)zs_presentFloatingTextFieldWithInitialText:(NSString *)initialText
                                        placeholder:(NSString *)placeholder
                                             secure:(BOOL)secure
                                           hintText:(NSString *)hintText
                                       resetHandler:(void (^)(void))resetHandler
                                         completion:(void (^)(NSString * _Nullable trimmedText))completion {
    UIView *unityView = zs_ui_host_view();
    if (!unityView) return;
    if (self.zsFloatingField) {
        [self zs_commitFloatingFieldSaving:YES];
    }

    self.zsFloatingFieldCompletion = completion;
    self.zsFloatingFieldResetHandler = resetHandler;

    UIView *backdrop = [[UIView alloc] init];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.backgroundColor = UIColor.clearColor;
    backdrop.userInteractionEnabled = YES;
    [backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zs_floatingFieldBackdropTapped)]];
    [unityView addSubview:backdrop];
    zs_mark_host_owned(backdrop);
    zs_force_dark(backdrop);
    self.zsFloatingFieldBackdrop = backdrop;
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:unityView.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:unityView.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:unityView.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:unityView.bottomAnchor],
    ]];

    UITextField *field = [[UITextField alloc] init];
    field.text = initialText;
    field.placeholder = placeholder;
    field.secureTextEntry = secure;
    field.textColor = UIColor.whiteColor;
    field.font = zs_mono_font(15, UIFontWeightRegular);
    field.returnKeyType = UIReturnKeyDone;
    field.autocapitalizationType = secure ? UITextAutocapitalizationTypeNone : UITextAutocapitalizationTypeSentences;
    field.autocorrectionType = secure ? UITextAutocorrectionTypeNo : UITextAutocorrectionTypeDefault;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    self.zsFloatingField = field;

    UIVisualEffectView *glass = zs_wrap_field_in_native_glass(field, 6);
    UIView *container = glass ?: field;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [unityView addSubview:container];
    zs_mark_host_owned(container);
    zs_force_dark(container);
    [unityView bringSubviewToFront:container];
    self.zsFloatingFieldContainer = container;

    container.alpha = 0;
    NSLayoutConstraint *bottom = [container.bottomAnchor constraintEqualToAnchor:unityView.bottomAnchor constant:-8];
    self.zsFloatingFieldBottomConstraint = bottom;
    [NSLayoutConstraint activateConstraints:@[
        [container.leadingAnchor constraintEqualToAnchor:unityView.safeAreaLayoutGuide.leadingAnchor constant:16],
        [container.trailingAnchor constraintEqualToAnchor:unityView.safeAreaLayoutGuide.trailingAnchor constant:-16],
        bottom,
        [container.heightAnchor constraintEqualToConstant:44],
    ]];

    UIButton *saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIFont *buttonFont = zs_mono_font(11, UIFontWeightSemibold);
    zs_style_button_as_native_glass_with_font(saveButton, @"Save", zs_accent_green_color(), buttonFont);
    zs_style_button_as_native_glass_with_font(resetButton, @"Reset", [UIColor colorWithRed:1.0 green:0.72 blue:0.3 alpha:1.0], buttonFont);
    zs_style_button_as_native_glass_with_font(cancelButton, @"Cancel", [UIColor colorWithWhite:1 alpha:0.85], buttonFont);
    [saveButton addTarget:self action:@selector(zs_floatingFieldSaveTapped) forControlEvents:UIControlEventTouchUpInside];
    [resetButton addTarget:self action:@selector(zs_floatingFieldResetTapped) forControlEvents:UIControlEventTouchUpInside];
    [cancelButton addTarget:self action:@selector(zs_floatingFieldCancelTapped) forControlEvents:UIControlEventTouchUpInside];

    NSArray<UIView *> *rowButtons = resetHandler ? @[saveButton, resetButton, cancelButton] : @[saveButton, cancelButton];
    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:rowButtons];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 8;
    buttonRow.alignment = UIStackViewAlignmentCenter;
    buttonRow.alpha = 0;
    [buttonRow setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [buttonRow setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    for (UIView *rowButton in rowButtons) {
        [rowButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [rowButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    }
    [unityView addSubview:buttonRow];
    zs_mark_host_owned(buttonRow);
    zs_force_dark(buttonRow);
    [unityView bringSubviewToFront:buttonRow];
    self.zsFloatingFieldButtonRow = buttonRow;
    [NSLayoutConstraint activateConstraints:@[
        [buttonRow.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [buttonRow.bottomAnchor constraintEqualToAnchor:container.topAnchor constant:-8],
        [saveButton.heightAnchor constraintEqualToConstant:30],
        [resetButton.heightAnchor constraintEqualToConstant:30],
        [cancelButton.heightAnchor constraintEqualToConstant:30],
        [saveButton.widthAnchor constraintGreaterThanOrEqualToConstant:60],
        [resetButton.widthAnchor constraintGreaterThanOrEqualToConstant:60],
        [cancelButton.widthAnchor constraintGreaterThanOrEqualToConstant:60],
    ]];

    UILabel *hintLabel = nil;
    if (hintText.length > 0) {
        hintLabel = [[UILabel alloc] init];
        hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
        hintLabel.text = hintText;
        hintLabel.font = zs_mono_font(12, UIFontWeightRegular);
        [hintLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [hintLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.78];
        hintLabel.numberOfLines = 0;
        hintLabel.backgroundColor = UIColor.clearColor;
        hintLabel.layer.shadowColor = UIColor.blackColor.CGColor;
        hintLabel.layer.shadowOpacity = 0.9;
        hintLabel.layer.shadowRadius = 2;
        hintLabel.layer.shadowOffset = CGSizeMake(0, 1);
        hintLabel.layer.masksToBounds = NO;
        hintLabel.alpha = 0;
        [unityView addSubview:hintLabel];
        zs_mark_host_owned(hintLabel);
        zs_force_dark(hintLabel);
        [unityView bringSubviewToFront:hintLabel];
        self.zsFloatingFieldHintLabel = hintLabel;
        [NSLayoutConstraint activateConstraints:@[
            [hintLabel.leadingAnchor constraintEqualToAnchor:buttonRow.trailingAnchor constant:12],
            [hintLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [hintLabel.centerYAnchor constraintEqualToAnchor:buttonRow.centerYAnchor],
        ]];
    }

    CGFloat bottomInset = unityView.safeAreaInsets.bottom + 291;
    if (!CGRectIsEmpty(self.zs_lastKeyboardFrame)) {
        CGFloat inset = CGRectGetHeight(unityView.bounds) - CGRectGetMinY(self.zs_lastKeyboardFrame);
        if (inset >= 8) bottomInset = inset;
    }
    bottom.constant = -(bottomInset + 8);
    [unityView layoutIfNeeded];

    [UIView animateWithDuration:0.15 animations:^{
        container.alpha = 1;
        buttonRow.alpha = 1;
        hintLabel.alpha = 1;
    }];

    [field becomeFirstResponder];
}

- (void)zs_keyboardWillChangeFrame:(NSNotification *)note {
    UIView *unityView = zs_ui_host_view();
    NSDictionary *info = note.userInfo;
    NSValue *endValue = info[UIKeyboardFrameEndUserInfoKey];
    if (!unityView || !endValue) return;

    CGRect endFrame = [unityView convertRect:endValue.CGRectValue fromView:nil];
    CGFloat inset = CGRectGetHeight(unityView.bounds) - CGRectGetMinY(endFrame);
    BOOL visible = inset >= 8 && !CGRectIsEmpty(endFrame);
    self.zs_lastKeyboardFrame = visible ? endFrame : CGRectZero;

    NSLayoutConstraint *bottom = self.zsFloatingFieldBottomConstraint;
    if (!bottom || !self.zsFloatingFieldContainer) return;

    CGFloat bottomInset = visible ? inset : unityView.safeAreaInsets.bottom;
    bottom.constant = -(bottomInset + 8);

    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve = [info[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    [UIView animateWithDuration:duration
                          delay:0
                        options:(UIViewAnimationOptions)(curve << 16) | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [unityView layoutIfNeeded];
    } completion:nil];
}

- (void)zs_commitFloatingFieldSaving:(BOOL)saving {
    void (^completion)(NSString * _Nullable) = self.zsFloatingFieldCompletion;
    NSString *trimmed = [(self.zsFloatingField.text ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    UIView *backdrop = self.zsFloatingFieldBackdrop;
    UIView *container = self.zsFloatingFieldContainer;
    UIView *buttonRow = self.zsFloatingFieldButtonRow;
    UIView *hintLabel = self.zsFloatingFieldHintLabel;
    self.zsFloatingFieldBackdrop = nil;
    self.zsFloatingFieldContainer = nil;
    self.zsFloatingFieldButtonRow = nil;
    self.zsFloatingFieldHintLabel = nil;
    self.zsFloatingFieldResetHandler = nil;
    self.zsFloatingField = nil;
    self.zsFloatingFieldBottomConstraint = nil;
    self.zsFloatingFieldCompletion = nil;

    backdrop.userInteractionEnabled = NO;
    container.userInteractionEnabled = NO;
    buttonRow.userInteractionEnabled = NO;

    [UIView animateWithDuration:0.15 animations:^{
        backdrop.alpha = 0;
        container.alpha = 0;
        buttonRow.alpha = 0;
        hintLabel.alpha = 0;
    } completion:^(BOOL finished) {
        [backdrop removeFromSuperview];
        [container removeFromSuperview];
        [buttonRow removeFromSuperview];
        [hintLabel removeFromSuperview];
    }];

    if (saving && completion) {
        completion(trimmed.length > 0 ? trimmed : nil);
    }
}

- (void)zs_commitFloatingField {
    [self zs_commitFloatingFieldSaving:YES];
}

- (void)zs_floatingFieldBackdropTapped {
    [self.zsFloatingField resignFirstResponder];
}

- (void)zs_floatingFieldSaveTapped {
    [self.zsFloatingField resignFirstResponder];
}

- (void)zs_floatingFieldResetTapped {
    UITextField *field = self.zsFloatingField;
    if (!field) return;
    void (^resetHandler)(void) = self.zsFloatingFieldResetHandler;
    if (resetHandler) {
        [self zs_commitFloatingFieldSaving:NO];
        [field resignFirstResponder];
        resetHandler();
        return;
    }
    field.text = @"";
    [field resignFirstResponder];
}

- (void)zs_floatingFieldCancelTapped {
    UITextField *field = self.zsFloatingField;
    if (!field) return;
    [self zs_commitFloatingFieldSaving:NO];
    [field resignFirstResponder];
}

- (void)zs_promptForModRemarkForEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    if (!entry) return;
    __weak typeof(self) weakSelf = self;
    [self zs_presentFloatingTextFieldWithInitialText:entry.remark
                                          placeholder:@"Remark"
                                               secure:NO
                                           completion:^(NSString * _Nullable trimmedText) {
        [weakSelf zs_saveModRemark:trimmedText forEntry:entry inFolder:folderName];
    }];
}

- (void)zs_saveModRemark:(nullable NSString *)remark forEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    NSError *error = nil;
    ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:entry
                                                                        inFolder:folderName
                                                                      applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.remark = remark;
    }
                                                                           error:&error];
    if (!updated) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Save Remark" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }
    [self zs_rebuildModsLibrary];
}

- (BOOL)zs_rePlaceModEntryCore:(ModAssetLibraryEntry *)entry error:(NSError **)outError {
    if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
        return [self zs_applyLocalizationEntry:entry error:outError];
    }

    BOOL isBank = ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame);
    if (isBank) {
        return [BankTransplant transplantAndSwapModdedBankAtURL:[NSURL fileURLWithPath:entry.path] error:outError];
    }

    if (!entry.isAssetBundle) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsRePlace" code:1
                                                    userInfo:@{NSLocalizedDescriptionKey: @"This file type can't be re-placed."}];
        return NO;
    }

    if (entry.doctorStatus != ModAssetLibraryDoctorStatusInstalled) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsRePlace" code:2
                                                    userInfo:@{NSLocalizedDescriptionKey: @"This bundle hasn't been processed and installed yet - dispatch it first."}];
        return NO;
    }

    NSURL *stockURL = zs_mods_live_stock_url_for_entry(entry);
    if (!stockURL) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsRePlace" code:3
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve this mod's installed location."}];
        return NO;
    }

    return [ZTranscoderInstaller installDoctoredBundleAtURL:[NSURL fileURLWithPath:entry.path]
                                            toStockBundleURL:stockURL
                                                       error:outError];
}

static dispatch_queue_t zs_mods_replace_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        queue = dispatch_queue_create("com.zsingularity.mods.replace", attr);
    });
    return queue;
}

static BOOL g_zsModsReplaceInFlight = NO;

static void * const kZSModsButtonFlashingKey = (void *)&kZSModsButtonFlashingKey;

static BOOL zs_mods_button_is_flashing(UIButton *button) {
    return [objc_getAssociatedObject(button, kZSModsButtonFlashingKey) boolValue];
}

static void zs_mods_flash_button_title(UIButton *button, NSString *flashTitle, NSString *originalTitle) {
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;
    objc_setAssociatedObject(button, kZSModsButtonFlashingKey, @YES, OBJC_ASSOCIATION_RETAIN);
    [UIView performWithoutAnimation:^{
        [button setTitle:flashTitle forState:UIControlStateNormal];
        [button layoutIfNeeded];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView performWithoutAnimation:^{
            [button setTitle:originalTitle forState:UIControlStateNormal];
            [button layoutIfNeeded];
        }];
        objc_setAssociatedObject(button, kZSModsButtonFlashingKey, nil, OBJC_ASSOCIATION_RETAIN);
    });
}

static NSArray<NSString *> *zs_mods_uncompressed_bundle_paths(void) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *folderName in [ModAssetLibrary folderNames]) {
        if (zs_mods_folder_is_or_within_stored_bundles(folderName)) continue;
        NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:nil] ?: @[];
        for (ModAssetLibraryEntry *entry in entries) {
            @autoreleasepool {
                if (!entry.isAssetBundle) continue;
                NSMutableArray<NSString *> *candidates = [NSMutableArray array];
                if (entry.path.length > 0) [candidates addObject:entry.path];
                if (entry.doctorStatus == ModAssetLibraryDoctorStatusInstalled) {
                    NSString *livePath = zs_mods_live_stock_url_for_entry(entry).path;
                    if (livePath.length > 0) [candidates addObject:livePath];
                }
                for (NSString *candidate in candidates) {
                    if (![fm fileExistsAtPath:candidate]) continue;
                    if ([UnityBundleCAB compressionTypeForBundleAtPath:candidate error:nil] == UnityBundleCABCompressionNone) {
                        [paths addObject:candidate];
                    }
                }
            }
        }
    }
    return paths.array;
}

static BOOL zs_mods_lz4hc_compress_bundle(NSString *path, NSError **error) {
    NSData *compressed = [UnityBundleCAB LZ4HCDataForBundleAtPath:path error:error];
    if (!compressed) return NO;
    return [compressed writeToFile:path options:NSDataWritingAtomic error:error];
}

- (void)zs_lz4hcToggleTapped:(UIButton *)sender {
    if (g_zsLz4hcBusy || zs_mods_button_is_flashing(sender)) return;
    UIView *section = zs_lz4hc_section_for_view(sender);
    UIView *wrapper = objc_getAssociatedObject(section, "zs_lz4Wrapper");
    UILabel *label = objc_getAssociatedObject(section, "zs_lz4Label");
    if (!wrapper) return;

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    if (g_zsLz4hcExpanded) {
        g_zsLz4hcExpanded = NO;
        g_zsLz4hcPendingPaths = nil;
        [self zs_lowResAnimateChanges:^{
            zs_reveal_set_expanded(wrapper, NO);
        }];
        return;
    }

    g_zsLz4hcBusy = YES;
    __weak typeof(self) weakSelf = self;
    __weak UIButton *weakSender = sender;
    __weak UIView *weakWrapper = wrapper;
    __weak UILabel *weakLabel = label;
    dispatch_async(zs_mods_replace_queue(), ^{
        NSArray<NSString *> *found = zs_mods_uncompressed_bundle_paths();
        dispatch_async(dispatch_get_main_queue(), ^{
            g_zsLz4hcBusy = NO;
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (found.count == 0) {
                UIButton *button = weakSender;
                if (button) zs_mods_flash_button_title(button, @"Nothing to compress", @"LZ4HC Compress Bundles");
                return;
            }
            g_zsLz4hcPendingPaths = found;
            g_zsLz4hcExpanded = YES;
            weakLabel.text = [strongSelf zs_lz4hcPromptForCount:found.count];
            UIView *strongWrapper = weakWrapper;
            [strongSelf zs_lowResAnimateChanges:^{
                zs_reveal_set_expanded(strongWrapper, YES);
            }];
        });
    });
}

- (void)zs_lz4hcConfirmTapped:(UIButton *)sender {
    if (g_zsLz4hcBusy || g_zsModsReplaceInFlight) return;
    NSArray<NSString *> *paths = g_zsLz4hcPendingPaths;
    if (paths.count == 0) return;

    UIView *section = zs_lz4hc_section_for_view(sender);
    UIView *wrapper = objc_getAssociatedObject(section, "zs_lz4Wrapper");
    UIButton *mainButton = objc_getAssociatedObject(section, "zs_lz4Button");

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeWarning];

    g_zsLz4hcBusy = YES;
    g_zsModsReplaceInFlight = YES;
    sender.enabled = NO;
    mainButton.enabled = NO;
    NSUInteger total = paths.count;
    __weak typeof(self) weakSelf = self;
    __weak UIButton *weakConfirm = sender;
    __weak UIButton *weakMain = mainButton;
    __weak UIView *weakWrapper = wrapper;
    dispatch_async(zs_mods_replace_queue(), ^{
        NSUInteger succeeded = 0, failed = 0;
        NSString *firstError = nil;
        for (NSUInteger i = 0; i < total; i++) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIButton *confirm = weakConfirm;
                if (!confirm) return;
                [UIView performWithoutAnimation:^{
                    [confirm setTitle:[NSString stringWithFormat:@"Compressing %lu/%lu", (unsigned long)(i + 1), (unsigned long)total] forState:UIControlStateNormal];
                    [confirm layoutIfNeeded];
                }];
            });
            @autoreleasepool {
                NSError *error = nil;
                if (zs_mods_lz4hc_compress_bundle(paths[i], &error)) {
                    succeeded++;
                } else {
                    failed++;
                    if (!firstError) firstError = error.localizedDescription ?: @"Unknown error.";
                    ZLog(@"[Mods Library] LZ4HC compress \"%@\" failed: %@", paths[i], error.localizedDescription);
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            g_zsLz4hcBusy = NO;
            g_zsModsReplaceInFlight = NO;
            g_zsLz4hcExpanded = NO;
            g_zsLz4hcPendingPaths = nil;
            ZLog(@"[Mods Library] LZ4HC compressed bundles: %lu succeeded, %lu failed", (unsigned long)succeeded, (unsigned long)failed);
            typeof(self) strongSelf = weakSelf;
            UIButton *confirm = weakConfirm;
            UIButton *titleButton = weakMain;
            confirm.enabled = YES;
            titleButton.enabled = YES;
            [UIView performWithoutAnimation:^{
                [confirm setTitle:@"Confirm" forState:UIControlStateNormal];
                [confirm layoutIfNeeded];
            }];
            UINotificationFeedbackGenerator *result = [UINotificationFeedbackGenerator new];
            [result notificationOccurred:failed > 0 ? UINotificationFeedbackTypeWarning : UINotificationFeedbackTypeSuccess];
            UIView *strongWrapper = weakWrapper;
            if (strongWrapper) {
                [strongSelf zs_lowResAnimateChanges:^{
                    zs_reveal_set_expanded(strongWrapper, NO);
                }];
            }
            if (failed > 0) {
                [strongSelf zs_presentModsAlertWithTitle:@"LZ4HC Compress Bundles"
                                                 message:[NSString stringWithFormat:@"%lu compressed, %lu failed. %@", (unsigned long)succeeded, (unsigned long)failed, firstError]];
            } else if (titleButton) {
                zs_mods_flash_button_title(titleButton, @"Compression complete", @"LZ4HC Compress Bundles");
            }
        });
    });
}

- (void)zs_rePlaceModEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    if (g_zsModsReplaceInFlight) return;
    g_zsModsReplaceInFlight = YES;

    __strong typeof(self) strongSelf = self;
    dispatch_async(zs_mods_replace_queue(), ^{
        NSError *error = nil;
        BOOL ok = NO;
        @autoreleasepool {
            ok = [strongSelf zs_rePlaceModEntryCore:entry error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            g_zsModsReplaceInFlight = NO;
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            if (!ok) {
                [haptic notificationOccurred:UINotificationFeedbackTypeError];
                [strongSelf zs_presentModsAlertWithTitle:@"Re-place Failed" message:error.localizedDescription ?: @"Unknown error."];
                return;
            }
            [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            ZLog(@"[Mods Library] re-placed %@ into the game's files", entry.fileName);
            [strongSelf zs_rebuildModsLibrary];
        });
    });
}

- (void)zs_rePlaceModFolder:(NSString *)folderName {
    if (g_zsModsReplaceInFlight) return;
    g_zsModsReplaceInFlight = YES;

    __strong typeof(self) strongSelf = self;
    dispatch_async(zs_mods_replace_queue(), ^{
        NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:nil] ?: @[];

        NSInteger succeeded = 0, failed = 0;
        for (ModAssetLibraryEntry *entry in entries) {
            @autoreleasepool {
                if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) continue;
                NSError *entryErr = nil;
                if ([strongSelf zs_rePlaceModEntryCore:entry error:&entryErr]) {
                    succeeded++;
                } else {
                    failed++;
                    ZLog(@"[Mods Library] re-place \"%@\" in \"%@\" failed: %@", entry.fileName, folderName, entryErr.localizedDescription);
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            g_zsModsReplaceInFlight = NO;
            ZLog(@"[Mods Library] re-placed folder \"%@\": %ld succeeded, %ld failed", folderName, (long)succeeded, (long)failed);
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            if (failed > 0) {
                [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
                [strongSelf zs_presentModsAlertWithTitle:@"Re-place Folder"
                                                 message:[NSString stringWithFormat:@"%ld re-placed, %ld failed. See syslog for details.",
                                                          (long)succeeded, (long)failed]];
            } else {
                [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            }
            [strongSelf zs_rebuildModsLibrary];
        });
    });
}

- (void)reloadModsTapped:(UIButton *)sender {
    if (g_zsModsReplaceInFlight || zs_mods_button_is_flashing(sender)) return;
    g_zsModsReplaceInFlight = YES;

    NSString *originalTitle = [sender titleForState:UIControlStateNormal] ?: @"Reload Mods";
    __weak UIButton *weakSender = sender;
    __strong typeof(self) strongSelf = self;
    dispatch_async(zs_mods_replace_queue(), ^{
        NSInteger succeeded = 0, failed = 0;
        for (NSString *folderName in [ModAssetLibrary folderNames]) {
            if (zs_mods_folder_is_or_within_stored_bundles(folderName)) continue;
            NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:nil] ?: @[];
            for (ModAssetLibraryEntry *entry in entries) {
                @autoreleasepool {
                    if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) continue;
                    NSError *entryErr = nil;
                    if ([strongSelf zs_rePlaceModEntryCore:entry error:&entryErr]) {
                        succeeded++;
                    } else {
                        failed++;
                        ZLog(@"[Mods Library] reload \"%@\" in \"%@\" failed: %@", entry.fileName, folderName, entryErr.localizedDescription);
                    }
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            g_zsModsReplaceInFlight = NO;
            ZLog(@"[Mods Library] reloaded mods: %ld succeeded, %ld failed", (long)succeeded, (long)failed);
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            UIButton *button = weakSender;
            if (failed > 0) {
                [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
                [strongSelf zs_presentModsAlertWithTitle:@"Reload Mods"
                                                 message:[NSString stringWithFormat:@"%ld re-placed, %ld failed. See syslog for details.",
                                                          (long)succeeded, (long)failed]];
            } else if (succeeded > 0) {
                [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
                if (button) zs_mods_flash_button_title(button, @"Reload success", originalTitle);
            } else if (button) {
                zs_mods_flash_button_title(button, @"Nothing to reload", originalTitle);
            }
            [strongSelf zs_rebuildModsLibrary];
        });
    });
}

- (void)zs_confirmDeleteModEntry:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete File?"
                                                                       message:[NSString stringWithFormat:@"\u201C%@\u201D will be removed from the Mod Asset Library and the original will be restored in the game's files.", entry.fileName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_deleteModEntryConfirmed:entry inFolder:folderName];
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_promptForModFolderRenameForFolder:(NSString *)folderName {
    __weak typeof(self) weakSelf = self;
    [self zs_promptForModFolderNameWithTitle:@"Rename Folder"
                                  actionTitle:@"Rename"
                                   completion:^(NSString *trimmedName) {
        [weakSelf zs_renameModFolder:folderName to:trimmedName];
    }];
}

- (void)zs_renameModFolder:(NSString *)folderName to:(NSString *)newName {
    NSError *error = nil;
    BOOL ok = [ModAssetLibrary renameFolderNamed:folderName to:newName error:&error];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Rename Folder" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }

    if ([self.modsLibraryExpandedFolders containsObject:folderName]) {
        [self.modsLibraryExpandedFolders removeObject:folderName];
        [self.modsLibraryExpandedFolders addObject:newName];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_promptForModFolderRemarkForFolder:(NSString *)folderName {
    if (!folderName) return;
    __weak typeof(self) weakSelf = self;
    [self zs_presentFloatingTextFieldWithInitialText:[ModAssetLibrary remarkForFolder:folderName]
                                          placeholder:@"Remark"
                                               secure:NO
                                           completion:^(NSString * _Nullable trimmedText) {
        [weakSelf zs_saveModFolderRemark:trimmedText forFolder:folderName];
    }];
}

- (void)zs_saveModFolderRemark:(nullable NSString *)remark forFolder:(NSString *)folderName {
    NSError *error = nil;
    BOOL ok = [ModAssetLibrary setRemark:remark forFolder:folderName error:&error];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Save Remark" message:error.localizedDescription ?: @"Unknown error."];
        return;
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_confirmDeleteModFolder:(NSString *)folderName {
    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) return;

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Folder?"
                                                                       message:[NSString stringWithFormat:@"\u201C%@\u201D and every mod inside it will be removed and the originals will be restored in the game's files.", folderName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf zs_deleteModFolderConfirmed:folderName];
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_modsLibraryEntryDownloadTapped:(UIButton *)sender {

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    ModAssetLibraryEntry *entry = objc_getAssociatedObject(sender, "zs_modsEntry");
    if (!entry) return;
    NSString *folderName = zs_mods_folder_name_for_entry(entry);
    if (!folderName) {
        ZLog(@"[Mods Library] Download tapped for %@ but couldn't derive its owning folder from its path (%@) - not proceeding.", entry.fileName, entry.path);
        return;
    }

    if (!self.doctorDownloadInFlightPaths) self.doctorDownloadInFlightPaths = [NSMutableSet set];
    if ([self.doctorDownloadInFlightPaths containsObject:entry.path]) {
        ZLog(@"[Mods Library] download for %@ already in flight, ignoring duplicate tap.", entry.fileName);
        return;
    }

    ZTranscoderConfig *config = [ZTranscoderConfig new];
    ZTranscoderHandle *handle = [ZTranscoderHandle handleFromDictionaryRepresentation:@{
        @"scratchBranch": entry.doctorScratchBranch ?: @"",
        @"runID": entry.doctorRunID ?: @"",
        @"runURL": entry.doctorRunURL ?: @"",
    }];
    if (!handle) {
        ZLog(@"[Mods Library] download for %@ blocked: lost track of its scratch branch.", entry.fileName);
        [self zs_presentModsAlertWithTitle:@"Can't Download"
                                    message:@"Lost track of this submission's scratch branch - try Retry to send it again."];
        return;
    }

    NSString *entryPath = entry.path;
    [self.doctorDownloadInFlightPaths addObject:entryPath];
    [self.doctorDownloadProgressLastUpdate removeObjectForKey:entryPath];
    [self.doctorDownloadProgressPersistLastUpdate removeObjectForKey:entryPath];
    NSError *resetError = nil;
    ModAssetLibraryEntry *resetEntry = [ModAssetLibrary updateDoctorStateForEntry:entry inFolder:folderName applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
        entryToMutate.doctorDownloadProgress = 0;
    } error:&resetError];
    if (!self.doctorDownloadLiveEntryCache) self.doctorDownloadLiveEntryCache = [NSMutableDictionary dictionary];
    if (resetEntry) self.doctorDownloadLiveEntryCache[entryPath] = resetEntry;
    [self zs_rebuildModsLibrary];

    ZLog(@"[Mods Library] installing locally transcoded bundle for %@.", entryPath.lastPathComponent);
    __weak typeof(self) weakSelf = self;
    NSURL *doctoredBundleURL = [NSURL fileURLWithPath:handle.scratchBranch];
    if (!handle.alreadyComplete || ![[NSFileManager defaultManager] fileExistsAtPath:doctoredBundleURL.path]) {
        [self.doctorDownloadInFlightPaths removeObject:entryPath];
        [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
            ZTMakeTranscoderError(ZTranscoderServiceErrorOutputMissing, @"The locally transcoded bundle is no longer available.")];
        return;
    }

    ZLog(@"[Mods Library] local transcode output found for %@, proceeding to install.", entryPath.lastPathComponent);
    unsigned long long outputSize = 0;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:doctoredBundleURL.path error:nil];
    if (attrs) outputSize = [attrs[NSFileSize] unsignedLongLongValue];
    [self zs_doctorHandleDownloadProgress:(int64_t)MIN(outputSize, (unsigned long long)INT64_MAX)
                       totalBytesExpected:(int64_t)MIN(outputSize, (unsigned long long)INT64_MAX)
                            forEntryPath:entryPath
                               inFolder:folderName];
    [self zs_doctorInstallUsingKnownTargetForDoctoredURL:doctoredBundleURL entryPath:entryPath inFolder:folderName];
}

- (void)zs_doctorHandleDownloadProgress:(int64_t)bytesWritten totalBytesExpected:(int64_t)totalBytesExpected forEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (!self.doctorDownloadProgressLastUpdate) self.doctorDownloadProgressLastUpdate = [NSMutableDictionary dictionary];
    if (!self.doctorDownloadProgressPersistLastUpdate) self.doctorDownloadProgressPersistLastUpdate = [NSMutableDictionary dictionary];
    if (!self.doctorDownloadLiveEntryCache) self.doctorDownloadLiveEntryCache = [NSMutableDictionary dictionary];

    NSNumber *last = self.doctorDownloadProgressLastUpdate[entryPath];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL isFinal = totalBytesExpected > 0 && bytesWritten >= totalBytesExpected;
    if (last && !isFinal && (now - last.doubleValue) < kZSDoctorProgressMinUpdateInterval) return;
    self.doctorDownloadProgressLastUpdate[entryPath] = @(now);

    ModAssetLibraryEntry *liveEntry = self.doctorDownloadLiveEntryCache[entryPath];
    NSNumber *lastPersist = self.doctorDownloadProgressPersistLastUpdate[entryPath];
    BOOL shouldPersist = isFinal || !liveEntry || !lastPersist
        || (now - lastPersist.doubleValue) >= kZSDoctorDownloadProgressPersistInterval;

    if (shouldPersist) {
        NSError *error = nil;
        ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                            inFolder:folderName
                                                                          applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
            entryToMutate.doctorDownloadProgress = bytesWritten;
        }
                                                                               error:&error];
        if (!updated) return;
        self.doctorDownloadProgressPersistLastUpdate[entryPath] = @(now);
        if (isFinal) {
            [self.doctorDownloadLiveEntryCache removeObjectForKey:entryPath];
        } else {
            self.doctorDownloadLiveEntryCache[entryPath] = updated;
        }
        if (![self zs_updateDoctorProgressLabelForEntry:updated downloadInFlight:YES]) {
            [self zs_rebuildModsLibrary];
        }
        return;
    }

    liveEntry.doctorDownloadProgress = bytesWritten;
    if (![self zs_updateDoctorProgressLabelForEntry:liveEntry downloadInFlight:YES]) {
        [self zs_rebuildModsLibrary];
    }
}

- (void)zs_doctorDownloadFailedForEntryPath:(NSString *)entryPath inFolder:(NSString *)folderName error:(NSError *)error {
    [self.doctorDownloadInFlightPaths removeObject:entryPath];
    [self.doctorDownloadLiveEntryCache removeObjectForKey:entryPath];
    [self.doctorDownloadProgressPersistLastUpdate removeObjectForKey:entryPath];
    ZLog(@"[Mods Library] download failed for %@: %@", entryPath.lastPathComponent, error.localizedDescription ?: @"Unknown error.");
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeError];
    [self zs_presentModsAlertWithTitle:@"Download Failed"
                                message:error.localizedDescription ?: @"Unknown error."];
    [self zs_rebuildModsLibrary];
}

- (void)zs_doctorInstallUsingKnownTargetForDoctoredURL:(NSURL *)doctoredURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    ModAssetLibraryEntry *entry = nil;
    for (ModAssetLibraryEntry *candidate in entries) {
        if ([candidate.path isEqualToString:entryPath]) { entry = candidate; break; }
    }

    NSString *relativeTarget = entry.resolvedInstallTargetPath;
    if (relativeTarget.length > 0) {
        NSString *absolute = [NSHomeDirectory() stringByAppendingPathComponent:relativeTarget];
        [self zs_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:[NSURL fileURLWithPath:absolute] entryPath:entryPath inFolder:folderName];
        return;
    }

    if (entry.zipCacheHash1.length > 0 && entry.zipCacheHash2.length > 0) {
        NSError *synthErr = nil;
        NSString *synthDir = [UnityCacheLocator synthesizeCacheDirectoryForHash1:entry.zipCacheHash1 hash2:entry.zipCacheHash2 error:&synthErr];
        if (synthDir) {
            NSString *synthDataPath = [synthDir stringByAppendingPathComponent:@"__data"];

            NSString *storedInfoPath = [entryPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"__info"];
            if ([NSFileManager.defaultManager fileExistsAtPath:storedInfoPath]) {
                [NSFileManager.defaultManager copyItemAtPath:storedInfoPath toPath:[synthDir stringByAppendingPathComponent:@"__info"] error:nil];
            }
            ZLog(@"[Mods Library] no import-time cache match for %@ - using SYNTHESIZED (unverified) target %@ from its Lunartique zip hash pair.",
                 entryPath.lastPathComponent, synthDataPath);
            [self zs_doctorInstallDoctoredURL:doctoredURL toStockBundleURL:[NSURL fileURLWithPath:synthDataPath] entryPath:entryPath inFolder:folderName];
            return;
        }
        ZLog(@"[Mods Library] Lunartique cache-directory synthesis failed for %@: %@ - falling back to the manual picker.",
             entryPath.lastPathComponent, synthErr.localizedDescription);
    }

    ZLog(@"[Mods Library] no import-time cache match on file for %@ - falling back to the manual picker.", entryPath.lastPathComponent);
    [self zs_presentDoctorInstallTargetPickerForDoctoredURL:doctoredURL entryPath:entryPath inFolder:folderName];
}

- (void)zs_presentDoctorInstallTargetPickerForDoctoredURL:(NSURL *)doctoredURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {
    if (self.doctorInstallTargetPicker) {

        [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                 code:ZTranscoderInstallerErrorNoInstallTarget
                             userInfo:@{NSLocalizedDescriptionKey: @"Another download is already waiting on a file pick - finish that one, then try this download again."}]];
        return;
    }

    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {

        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem]];
    } else {

        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"]
                                                                          inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods Library] no root view controller to present the doctor install target picker from");
        [self zs_doctorDownloadFailedForEntryPath:entryPath inFolder:folderName error:
            [NSError errorWithDomain:ZTranscoderInstallerErrorDomain
                                 code:ZTranscoderInstallerErrorNoInstallTarget
                             userInfo:@{NSLocalizedDescriptionKey: @"Couldn't present the file picker."}]];
        return;
    }

    self.doctorInstallTargetPicker = picker;
    self.doctorInstallPendingDoctoredURL = doctoredURL;
    self.doctorInstallPendingEntryPath = entryPath;
    self.doctorInstallPendingFolderName = folderName;

    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_doctorInstallDoctoredURL:(NSURL *)doctoredURL toStockBundleURL:(NSURL *)stockBundleURL entryPath:(NSString *)entryPath inFolder:(NSString *)folderName {

    NSError *currentEntriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *currentEntries = [ModAssetLibrary entriesInFolder:folderName error:&currentEntriesErr] ?: @[];
    ModAssetLibraryEntry *currentEntry = nil;
    for (ModAssetLibraryEntry *candidate in currentEntries) {
        if ([candidate.path isEqualToString:entryPath]) { currentEntry = candidate; break; }
    }
    BOOL wasCarra2Entry = currentEntry && !currentEntry.isAssetBundle && currentEntry.zipCacheHash1.length > 0;

    if (!wasCarra2Entry) {
        NSError *readErr = nil;
        NSData *doctoredData = [NSData dataWithContentsOfURL:doctoredURL options:0 error:&readErr];
        if (!doctoredData) {
            [self.doctorDownloadInFlightPaths removeObject:entryPath];
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            [haptic notificationOccurred:UINotificationFeedbackTypeError];
            [self zs_presentModsAlertWithTitle:@"Install Failed"
                                        message:readErr.localizedDescription ?: @"Couldn't read the doctored bundle."];
            [self zs_rebuildModsLibrary];
            return;
        }
        NSError *libraryWriteErr = nil;
        if (![doctoredData writeToFile:entryPath options:NSDataWritingAtomic error:&libraryWriteErr]) {
            [self.doctorDownloadInFlightPaths removeObject:entryPath];
            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            [haptic notificationOccurred:UINotificationFeedbackTypeError];
            [self zs_presentModsAlertWithTitle:@"Install Failed"
                                        message:libraryWriteErr.localizedDescription ?: @"Couldn't update the mod library's own copy."];
            [self zs_rebuildModsLibrary];
            return;
        }
    }

    NSError *installError = nil;
    BOOL installed = [ZTranscoderInstaller installDoctoredBundleAtURL:doctoredURL toStockBundleURL:stockBundleURL error:&installError];
    [self.doctorDownloadInFlightPaths removeObject:entryPath];

    if (!installed) {
        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeError];
        [self zs_presentModsAlertWithTitle:@"Install Failed"
                                    message:installError.localizedDescription ?: @"Unknown error."];
        [self zs_rebuildModsLibrary];
        return;
    }

    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *nowISO = [iso stringFromDate:[NSDate date]];

    NSString *installedLogName = entryPath.lastPathComponent;
    unsigned long long freshByteSize = 0;

    if (wasCarra2Entry) {
        NSError *replaceErr = nil;
        ModAssetLibraryEntry *replaced = [ModAssetLibrary replaceEntry:currentEntry
                                                                inFolder:folderName
                                              withDownloadedBundleAtURL:doctoredURL
                                                                   error:&replaceErr];
        if (!replaced) {
            ZLog(@"[Mods Library] installed %@ but couldn't replace its Carra2 entry with the downloaded bundle: %@", entryPath.lastPathComponent, replaceErr.localizedDescription);
        } else {
            installedLogName = replaced.fileName;
            freshByteSize = replaced.byteSize;
            NSError *stateError = nil;
            ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:replaced
                                                                                inFolder:folderName
                                                                              applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
                entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusInstalled;
                entryToMutate.dateAdded = nowISO;
                entryToMutate.livePathDescription = [ModAssetLibrary liveGamePathDescriptionForInstalledURL:stockBundleURL];
            }
                                                                                   error:&stateError];
            if (!updated) {
                ZLog(@"[Mods Library] replaced %@ with its downloaded bundle but couldn't record it as Installed on the manifest (entry deleted mid-flight?): %@", entryPath.lastPathComponent, stateError);
            }
        }
    } else {
        int32_t freshPlatform = 0;
        NSError *platformErr = nil;
        BOOL gotPlatform = [UnityBundleCAB targetPlatform:&freshPlatform forBundleAtPath:doctoredURL.path error:&platformErr];
        NSNumber *freshPlatformNumber = gotPlatform ? @(freshPlatform) : nil;
        if (!gotPlatform) {

            ZLog(@"[Mods Library] couldn't re-read target platform from the doctored bundle for %@, leaving the row's existing value: %@", entryPath.lastPathComponent, platformErr.localizedDescription);
        }
        NSDictionary<NSFileAttributeKey, id> *doctoredAttrs = [NSFileManager.defaultManager attributesOfItemAtPath:doctoredURL.path error:nil];
        freshByteSize = doctoredAttrs.fileSize;

        NSError *stateError = nil;
        ModAssetLibraryEntry *updated = [ModAssetLibrary updateDoctorStateForEntry:zs_mods_entry_placeholder_for_path(entryPath)
                                                                            inFolder:folderName
                                                                          applyBlock:^(ModAssetLibraryEntry *entryToMutate) {
            entryToMutate.doctorStatus = ModAssetLibraryDoctorStatusInstalled;
            if (freshPlatformNumber) entryToMutate.targetPlatform = freshPlatformNumber;
            if (freshByteSize > 0) entryToMutate.byteSize = freshByteSize;
            entryToMutate.dateAdded = nowISO;

            entryToMutate.livePathDescription = [ModAssetLibrary liveGamePathDescriptionForInstalledURL:stockBundleURL];

        }
                                                                               error:&stateError];
        if (!updated) {
            ZLog(@"[Mods Library] installed %@ but couldn't record it as Installed on the manifest (entry deleted mid-flight?): %@", entryPath.lastPathComponent, stateError);
        }
    }

    ZLog(@"[Mods Library] installed doctored bundle %@ over %@ (%llu bytes)", installedLogName, stockBundleURL.path, freshByteSize);
    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self zs_rebuildModsLibrary];
}

- (void)zs_restoreLocalizationEntryBestEffort:(ModAssetLibraryEntry *)entry {
    if (entry.localizationKind == ModAssetLibraryLocalizationKindPack) {
        [LocalizationTransplant restorePackForLanguage:entry.localizationLanguage ifAppliedFromPackAtPath:entry.path];
        [LocalizationTransplant discardPackBackupForLanguage:entry.localizationLanguage];
    } else if (entry.localizationKind == ModAssetLibraryLocalizationKindJSON && entry.localizationRelativePath.length > 0) {
        [LocalizationTransplant restoreRelativeTarget:entry.localizationRelativePath ifAppliedFromModFileAtPath:entry.path];
        [LocalizationTransplant discardFileBackupForRelativeTarget:entry.localizationRelativePath];
    }
}

- (BOOL)zs_applyLocalizationEntry:(ModAssetLibraryEntry *)entry error:(NSError **)outError {
    if (entry.localizationKind == ModAssetLibraryLocalizationKindPack) {
        return [LocalizationTransplant applyPackAtPath:entry.path toLanguage:entry.localizationLanguage error:outError];
    }
    if (entry.localizationRelativePath.length == 0) {
        if (outError) *outError = [NSError errorWithDomain:@"ZSModsRePlace" code:4
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Couldn't resolve this mod's target file."}];
        return NO;
    }
    return [LocalizationTransplant applyModFileAtPath:entry.path toRelativeTarget:entry.localizationRelativePath error:outError];
}

- (void)zs_restoreModEntryBestEffort:(ModAssetLibraryEntry *)entry {
    if (entry.localizationKind != ModAssetLibraryLocalizationKindNone) {
        [self zs_restoreLocalizationEntryBestEffort:entry];
        return;
    }

    if ([ZSModsPaths fontKindForFileName:entry.fileName] != ZSFontKindUnknown) {
        [ModAssetLibrary deactivateFontForEntry:entry];
        return;
    }

    NSError *bankError = nil;
    [BankTransplant restoreBackedUpBankNamed:entry.fileName error:&bankError];
    if (bankError) {
        ZLog(@"[Mods Library] couldn't restore %@ before removing it from the library: %@", entry.fileName, bankError.localizedDescription);
    }
    [BankTransplant discardBackupForBankNamed:entry.fileName];

    if (entry.isAssetBundle) {
        NSURL *stockURL = zs_mods_live_stock_url_for_entry(entry);
        if (stockURL) {
            NSError *bundleError = nil;
            BOOL restored = [ZTranscoderInstaller cacheOriginalBackForStockBundleURL:stockURL error:&bundleError];
            if (restored) {
                [ZTranscoderInstaller discardBackupForStockBundleURL:stockURL];
            } else {
                ZLog(@"[Mods Library] couldn't restore %@'s live bundle at %@ before removing it from the library: %@", entry.fileName, stockURL.path, bundleError.localizedDescription);
            }
        }
    }
}

- (void)zs_handleHoldToConfirmGesture:(UILongPressGestureRecognizer *)gesture {
    UIButton *button = (UIButton *)gesture.view;
    if (![button isKindOfClass:[UIButton class]]) return;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.holdConfirmActiveButton = button;
            self.holdConfirmStartTime = CACurrentMediaTime();
            self.holdConfirmTriggered = NO;

            UIView *expansion = objc_getAssociatedObject(button, kZSHoldConfirmExpansionViewKey);
            NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kZSHoldConfirmExpansionWidthKey);
            UILabel *deleteLabel = objc_getAssociatedObject(button, kZSHoldConfirmDeleteLabelKey);
            UIVisualEffectView *capsuleGlass = objc_getAssociatedObject(button, kZSHoldConfirmGlassViewKey);
            UIView *glassHost = objc_getAssociatedObject(button, kZSHoldConfirmGlassHostKey);

            widthConstraint.constant = kZSDeleteCapsuleExpandedWidth;
            [UIView animateWithDuration:kZSDeleteCapsuleSnapDuration
                                   delay:0
                  usingSpringWithDamping:kZSDeleteCapsuleSpringDamping
                   initialSpringVelocity:kZSDeleteCapsuleSpringVelocity
                                 options:UIViewAnimationOptionAllowUserInteraction
                              animations:^{
                deleteLabel.alpha = 1;
                if (capsuleGlass && glassHost) {
                    capsuleGlass.alpha = 1;
                    CGRect buttonFrameInHost = [button convertRect:button.bounds toView:glassHost];
                    CGRect expansionFrameInHost = [expansion convertRect:expansion.bounds toView:glassHost];
                    capsuleGlass.frame = CGRectUnion(buttonFrameInHost, expansionFrameInHost);
                }
                [button.superview layoutIfNeeded];
            }
                              completion:nil];

            [self.holdConfirmDisplayLink invalidate];
            self.holdConfirmDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(zs_holdConfirmTick:)];
            [self.holdConfirmDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.holdConfirmDisplayLink invalidate];
            self.holdConfirmDisplayLink = nil;

            if (!self.holdConfirmTriggered) {

                [self zs_collapseHoldConfirmButton:button];

                UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
                [haptic notificationOccurred:UINotificationFeedbackTypeError];
            }
            self.holdConfirmActiveButton = nil;
            break;
        }
        default:
            break;
    }
}

- (void)zs_holdConfirmTick:(CADisplayLink *)link {
    static const NSTimeInterval kZSHoldConfirmDuration = 1.5;

    UIButton *button = self.holdConfirmActiveButton;
    if (!button) {
        [link invalidate];
        return;
    }

    NSTimeInterval elapsed = CACurrentMediaTime() - self.holdConfirmStartTime;
    CGFloat pct = (CGFloat)MIN(1.0, elapsed / kZSHoldConfirmDuration);

    UIView *expansion = objc_getAssociatedObject(button, kZSHoldConfirmExpansionViewKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kZSHoldConfirmExpansionFillKey);
    CALayer *buttonFill = objc_getAssociatedObject(button, kZSHoldConfirmButtonFillKey);

    CGFloat expansionWidth = expansion.bounds.size.width;
    CGFloat buttonWidth = button.bounds.size.width;
    CGFloat filledWidth = (expansionWidth + buttonWidth) * pct;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    expansionFill.frame = CGRectMake(0, 0, MIN(filledWidth, expansionWidth), expansion.bounds.size.height);
    buttonFill.frame = CGRectMake(0, 0, MAX(0, filledWidth - expansionWidth), buttonWidth);
    [CATransaction commit];

    if (pct >= 1.0 && !self.holdConfirmTriggered) {
        self.holdConfirmTriggered = YES;
        [link invalidate];
        self.holdConfirmDisplayLink = nil;

        UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

        void (^onConfirm)(void) = objc_getAssociatedObject(button, kZSHoldConfirmBlockKey);
        if (onConfirm) onConfirm();
    }
}

- (void)zs_collapseHoldConfirmButton:(UIButton *)button {
    UIView *expansion = objc_getAssociatedObject(button, kZSHoldConfirmExpansionViewKey);
    NSLayoutConstraint *widthConstraint = objc_getAssociatedObject(button, kZSHoldConfirmExpansionWidthKey);
    UILabel *deleteLabel = objc_getAssociatedObject(button, kZSHoldConfirmDeleteLabelKey);
    UIVisualEffectView *capsuleGlass = objc_getAssociatedObject(button, kZSHoldConfirmGlassViewKey);
    CALayer *expansionFill = objc_getAssociatedObject(button, kZSHoldConfirmExpansionFillKey);
    CALayer *buttonFill = objc_getAssociatedObject(button, kZSHoldConfirmButtonFillKey);

    widthConstraint.constant = 0;
    [UIView animateWithDuration:kZSDeleteCapsuleSnapDuration
                           delay:0
          usingSpringWithDamping:kZSDeleteCapsuleSpringDamping
           initialSpringVelocity:kZSDeleteCapsuleSpringVelocity
                         options:UIViewAnimationOptionAllowUserInteraction
                      animations:^{
        deleteLabel.alpha = 0;
        capsuleGlass.alpha = 0;
        [button.superview layoutIfNeeded];
    }
                      completion:nil];

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.18];
    expansionFill.frame = CGRectMake(0, 0, 0, expansion.bounds.size.height);
    buttonFill.frame = CGRectMake(0, 0, 0, button.bounds.size.height);
    [CATransaction commit];
}

- (void)zs_handleTapToConfirm:(UIButton *)sender {
    NSString *title = objc_getAssociatedObject(sender, kZSTapConfirmTitleKey);
    NSString *message = objc_getAssociatedObject(sender, kZSTapConfirmMessageKey);
    NSString *actionTitle = objc_getAssociatedObject(sender, kZSTapConfirmActionTitleKey) ?: @"Confirm";
    BOOL destructive = [objc_getAssociatedObject(sender, kZSTapConfirmDestructiveKey) boolValue];
    void (^onConfirm)(void) = objc_getAssociatedObject(sender, kZSTapConfirmBlockKey);

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        if (onConfirm) onConfirm();
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:actionTitle
                                                 style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
        if (onConfirm) onConfirm();
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

- (void)zs_deleteModEntryConfirmed:(ModAssetLibraryEntry *)entry inFolder:(NSString *)folderName {
    [self zs_restoreModEntryBestEffort:entry];

    NSError *error = nil;
    BOOL ok = [ModAssetLibrary removeEntry:entry fromFolder:folderName error:&error];
    [self.modsLibraryExpandedInfoEntries removeObject:entry.path];

    if (ok && zs_mods_folder_is_or_within_stored_bundles(folderName) && ![folderName isEqualToString:kZSStoredBundlesFolderName]) {
        NSError *remainingErr = nil;
        NSArray<ModAssetLibraryEntry *> *remaining = [ModAssetLibrary entriesInFolder:folderName error:&remainingErr];
        if (remaining.count == 0) {
            NSError *deleteErr = nil;
            if (![ModAssetLibrary deleteFolderNamed:folderName error:&deleteErr]) {
                ZLog(@"[Mods Library] removed the last item out of cached folder \"%@\" but couldn't remove it: %@",
                     folderName, deleteErr.localizedDescription);
            } else {
                [self.modsLibraryExpandedFolders removeObject:folderName];
            }
        }
    }

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Remove File" message:error.localizedDescription ?: @"Unknown error."];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_deleteModFolderConfirmed:(NSString *)folderName {
    NSError *entriesErr = nil;
    NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:&entriesErr] ?: @[];
    for (ModAssetLibraryEntry *entry in entries) {
        [self zs_restoreModEntryBestEffort:entry];
    }

    NSError *deleteErr = nil;
    BOOL ok = [ModAssetLibrary deleteFolderNamed:folderName error:&deleteErr];

    [self.modsLibraryExpandedFolders removeObject:folderName];
    for (ModAssetLibraryEntry *entry in entries) [self.modsLibraryExpandedInfoEntries removeObject:entry.path];

    UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
    [haptic notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    if (!ok) {
        [self zs_presentModsAlertWithTitle:@"Couldn't Delete Folder" message:deleteErr.localizedDescription ?: @"Unknown error."];
    }
    [self zs_rebuildModsLibrary];
}

- (void)zs_presentModImportPickerForFolder:(NSString *)folderName {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData, UTTypeItem, UTTypeFolder]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item", @"public.folder"]
                                                                          inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;

    UIViewController *presenter = zs_key_window().rootViewController;
    if (!presenter) {
        ZLog(@"[Mods Library] no root view controller to present the file picker from");
        return;
    }
    self.libraryImportPicker = picker;
    self.libraryImportTargetFolder = folderName;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)zs_handlePickedLibraryImportURLs:(NSArray<NSURL *> *)urls intoFolder:(NSString *)folderName {
    [self zs_handleLoadModsPickedURLs:urls intoFolder:folderName];
}


#pragma mark Mod library browser

- (void)zs_openModLibraryFullScreenPanel {
    if (!self.panelOpen || self.assetExplorerFullScreenOpen) return;
    self.modsLibraryBrowseMode = YES;
    self.modsLibrarySelectedEntry = nil;
    self.modsLibraryBrowseEntries = @[];
    self.modsLibraryDisplayedEntries = @[];
    self.modsLibraryDisplayedFolders = @[];
    self.modsLibrarySelectedFolder = nil;
    [self zs_openAssetExplorerFullScreenPanel];
}
- (ModAssetLibraryEntry *)zs_modsLibraryEntryAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger index = indexPath.row - (NSInteger)self.modsLibraryDisplayedFolders.count;
    if (index < 0 || index >= (NSInteger)self.modsLibraryDisplayedEntries.count) return nil;
    return self.modsLibraryDisplayedEntries[(NSUInteger)index];
}
- (NSDictionary<NSString *, id> *)zs_modsLibraryFolderAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.modsLibraryDisplayedFolders.count) return nil;
    return self.modsLibraryDisplayedFolders[(NSUInteger)indexPath.row];
}
- (void)zs_modsLibraryApplyListChrome {
    NSString *folder = self.modsLibrarySelectedFolder;
    BOOL inFolder = folder.length > 0;
    self.assetExplorerCloseButton.hidden = inFolder;
    self.assetExplorerBackButton.hidden = !inFolder;
    self.assetExplorerTitleLabel.hidden = NO;
    self.assetExplorerTitleLabel.text = inFolder ? folder.lastPathComponent : @"Mod Library";
}
- (void)zs_modsLibraryOpenFolder:(NSString *)folder {
    if (folder.length == 0) return;
    [self.assetExplorerSearchField resignFirstResponder];
    self.modsLibrarySelectedFolder = folder;
    self.assetExplorerSearchField.text = @"";
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self zs_assetExplorerRefreshListResettingScroll:YES];
}
- (void)zs_modsLibraryNavigateUpFromFolder {
    NSString *folder = self.modsLibrarySelectedFolder;
    if (folder.length == 0) return;
    NSString *parent = folder.stringByDeletingLastPathComponent;
    if (parent.length == 0 || !zs_mods_folder_is_or_within_stored_bundles(parent)) parent = nil;
    [self.assetExplorerSearchField resignFirstResponder];
    self.modsLibrarySelectedFolder = parent;
    self.assetExplorerSearchField.text = @"";
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self zs_assetExplorerRefreshListResettingScroll:YES];
}
- (void)zs_modsLibraryRebuildRowsForQuery:(NSString *)query {
    NSString *current = self.modsLibrarySelectedFolder ?: @"";
    NSMutableArray<ModAssetLibraryEntry *> *matches = [NSMutableArray array];
    for (ModAssetLibraryEntry *entry in self.modsLibraryBrowseEntries ?: @[]) {
        NSString *folder = entry.currentFolder ?: @"";
        NSString *remark = entry.remark ?: @"";
        NSString *cab = entry.cabIdentifier ?: @"";
        NSString *path = entry.path ?: @"";
        NSString *language = entry.localizationLanguage ?: @"";
        if (query.length > 0 &&
            ![entry.fileName localizedCaseInsensitiveContainsString:query] &&
            ![folder localizedCaseInsensitiveContainsString:query] &&
            ![remark localizedCaseInsensitiveContainsString:query] &&
            ![cab localizedCaseInsensitiveContainsString:query] &&
            ![path localizedCaseInsensitiveContainsString:query] &&
            ![language localizedCaseInsensitiveContainsString:query]) continue;
        [matches addObject:entry];
    }

    NSMutableArray<ModAssetLibraryEntry *> *shownEntries = [NSMutableArray array];
    if (current.length == 0) {
        if (query.length > 0) [shownEntries addObjectsFromArray:matches];
    } else {
        NSString *prefix = [current stringByAppendingString:@"/"];
        for (ModAssetLibraryEntry *entry in matches) {
            NSString *folder = entry.currentFolder ?: @"";
            if ([folder isEqualToString:current] || (query.length > 0 && [folder hasPrefix:prefix])) [shownEntries addObject:entry];
        }
    }
    NSInteger sortMode = self.modsLibrarySortMode;
    BOOL sortAscending = !self.modsLibrarySortDescending;
    [shownEntries sortUsingComparator:^NSComparisonResult(ModAssetLibraryEntry *a, ModAssetLibraryEntry *b) {
        NSComparisonResult primary = NSOrderedSame;
        if (sortMode == kZSModsLibrarySortSize) {
            if (a.byteSize != b.byteSize) primary = a.byteSize < b.byteSize ? NSOrderedAscending : NSOrderedDescending;
        } else if (sortMode == kZSModsLibrarySortDate) {
            primary = [a.dateAdded ?: @"" compare:b.dateAdded ?: @""];
        } else if (sortMode == kZSModsLibrarySortKind) {
            primary = [zs_mods_library_entry_kind(a) localizedStandardCompare:zs_mods_library_entry_kind(b)];
        }
        if (primary != NSOrderedSame) return sortAscending ? primary : (primary == NSOrderedAscending ? NSOrderedDescending : NSOrderedAscending);
        NSComparisonResult result = [zs_mods_library_entry_title(a) localizedStandardCompare:zs_mods_library_entry_title(b)];
        if (result != NSOrderedSame) return (sortMode == kZSModsLibrarySortName && !sortAscending) ? (result == NSOrderedAscending ? NSOrderedDescending : NSOrderedAscending) : result;
        return [a.fileName ?: @"" localizedStandardCompare:b.fileName ?: @""];
    }];

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (current.length == 0) {
        BOOL hasStored = NO;
        for (NSString *name in [ModAssetLibrary folderNames] ?: @[]) {
            if ([name isEqualToString:kZSStoredBundlesFolderName]) hasStored = YES;
            else [candidates addObject:name];
        }
        if (hasStored) [candidates addObject:kZSStoredBundlesFolderName];
    } else if ([current isEqualToString:kZSStoredBundlesFolderName]) {
        [candidates addObjectsFromArray:[ModAssetLibrary subFolderNamesInFolder:current] ?: @[]];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *folderRows = [NSMutableArray arrayWithCapacity:candidates.count];
    for (NSString *folder in candidates) {
        BOOL isStoredRoot = [folder isEqualToString:kZSStoredBundlesFolderName];
        if (isStoredRoot) {
            BOOL hasContent = [[ModAssetLibrary entriesInFolder:folder error:nil] count] > 0 || [[ModAssetLibrary subFolderNamesInFolder:folder] count] > 0;
            if (!hasContent) continue;
        }
        NSString *title = isStoredRoot ? folder : folder.lastPathComponent;
        NSString *remark = isStoredRoot ? kZSStoredBundlesFolderSubtext : ([ModAssetLibrary remarkForFolder:folder] ?: @"");
        if (query.length > 0 &&
            ![title localizedCaseInsensitiveContainsString:query] &&
            ![remark localizedCaseInsensitiveContainsString:query]) continue;
        unsigned long long folderSize = 0;
        NSUInteger folderCount = 0;
        NSDate *folderModified = nil;
        zs_mods_library_collect_folder_stats(folder, NSFileManager.defaultManager, &folderSize, &folderCount, &folderModified);
        [folderRows addObject:@{
            @"folder": folder,
            @"title": title,
            @"remark": remark,
            @"hasOptions": @(!isStoredRoot),
            @"size": @(folderSize),
            @"count": @(folderCount),
            @"modified": folderModified ?: NSNull.null,
        }];
    }
    self.modsLibraryDisplayedFolders = folderRows;
    self.modsLibraryDisplayedEntries = shownEntries;
}
- (UIContextMenuConfiguration *)zs_modsLibraryContextMenuForFolderRow:(NSDictionary<NSString *, id> *)folderRow API_AVAILABLE(ios(13.0)) {
    if (![folderRow[@"hasOptions"] boolValue]) return nil;
    NSString *folder = folderRow[@"folder"];
    NSString *title = folderRow[@"title"] ?: @"";
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIMenu *menu = [weakSelf zs_modsLibraryFolderMenuForFolder:folder];
        return [UIMenu menuWithTitle:title children:menu.children ?: @[]];
    }];
}
- (UISwipeActionsConfiguration *)zs_modsLibraryDeleteSwipeForIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    NSDictionary<NSString *, id> *folderRow = [self zs_modsLibraryFolderAtIndexPath:indexPath];
    ModAssetLibraryEntry *entry = folderRow ? nil : [self zs_modsLibraryEntryAtIndexPath:indexPath];
    if (!folderRow && !entry) return nil;
    if (folderRow && ![folderRow[@"hasOptions"] boolValue]) return nil;
    NSString *folderName = folderRow ? folderRow[@"folder"] : (entry.currentFolder ?: @"");
    NSArray<NSDictionary<NSString *, id> *> *options = folderRow
        ? zs_mods_options_for_folder(folderName)
        : (zs_mods_folder_is_or_within_stored_bundles(folderName) ? zs_mods_stored_bundle_file_options() : zs_mods_file_options(entry));
    BOOL canDelete = NO;
    for (NSDictionary<NSString *, id> *option in options) {
        if ([option[@"title"] isEqualToString:@"Delete"] && ![option[@"disabled"] boolValue]) {
            canDelete = YES;
            break;
        }
    }
    if (!canDelete) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *swipeAction, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf zs_modsLibraryPerformOptionNamed:@"Delete" forEntry:entry folderName:folderName];
        completionHandler(YES);
    }];
    action.image = [UIImage systemImageNamed:@"trash"];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
- (UISwipeActionsConfiguration *)zs_modsLibraryRemarkSwipeForIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    NSDictionary<NSString *, id> *folderRow = [self zs_modsLibraryFolderAtIndexPath:indexPath];
    ModAssetLibraryEntry *entry = folderRow ? nil : [self zs_modsLibraryEntryAtIndexPath:indexPath];
    if (!folderRow && !entry) return nil;
    if (folderRow && ![folderRow[@"hasOptions"] boolValue]) return nil;
    NSString *folderName = folderRow ? folderRow[@"folder"] : (entry.currentFolder ?: @"");
    NSString *existingRemark = folderRow ? folderRow[@"remark"] : entry.remark;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:(existingRemark.length > 0 ? @"Edit Remark" : @"Add Remark") handler:^(UIContextualAction *swipeAction, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf zs_modsLibraryPerformOptionNamed:@"Add remark" forEntry:entry folderName:folderName];
        completionHandler(YES);
    }];
    action.image = [UIImage systemImageNamed:@"text.bubble.fill"];
    action.backgroundColor = [UIColor colorWithRed:0.24 green:0.42 blue:0.78 alpha:1];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
- (UIMenu *)zs_modsLibraryFolderMenuForFolder:(NSString *)folder {
    __weak typeof(self) weakSelf = self;
    NSArray<NSDictionary<NSString *, id> *> *options = zs_mods_options_for_folder(folder);
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithCapacity:options.count];
    for (NSDictionary<NSString *, id> *option in options) {
        NSString *title = option[@"title"] ?: @"Action";
        NSString *symbol = option[@"symbol"];
        UIAction *item = [UIAction actionWithTitle:title image:(symbol.length > 0 ? [UIImage systemImageNamed:symbol] : nil) identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf zs_modsLibraryPerformOptionNamed:title forEntry:nil folderName:folder];
        }];
        UIMenuElementAttributes attributes = 0;
        if ([option[@"destructive"] boolValue]) attributes |= UIMenuElementAttributesDestructive;
        if ([option[@"disabled"] boolValue]) attributes |= UIMenuElementAttributesDisabled;
        item.attributes = attributes;
        [items addObject:item];
    }
    return [UIMenu menuWithTitle:@"" children:items];
}
- (void)zs_assetExplorerRefreshModLibraryEntries {
    NSMutableArray<NSString *> *pendingFolders = [[ModAssetLibrary folderNames] mutableCopy];
    NSMutableSet<NSString *> *visitedFolders = [NSMutableSet set];
    NSMutableDictionary<NSString *, ModAssetLibraryEntry *> *entriesByPath = [NSMutableDictionary dictionary];

    while (pendingFolders.count > 0) {
        NSString *folderName = pendingFolders.firstObject;
        [pendingFolders removeObjectAtIndex:0];
        if (folderName.length == 0 || [visitedFolders containsObject:folderName]) continue;
        [visitedFolders addObject:folderName];

        NSArray<ModAssetLibraryEntry *> *entries = [ModAssetLibrary entriesInFolder:folderName error:nil] ?: @[];
        for (ModAssetLibraryEntry *entry in entries) {
            if (entry.path.length > 0) entriesByPath[entry.path] = entry;
        }

        for (NSString *subFolder in [ModAssetLibrary subFolderNamesInFolder:folderName]) {
            if (![visitedFolders containsObject:subFolder]) [pendingFolders addObject:subFolder];
        }
    }

    NSArray<ModAssetLibraryEntry *> *sortedEntries = [[entriesByPath allValues] sortedArrayUsingComparator:^NSComparisonResult(ModAssetLibraryEntry *a, ModAssetLibraryEntry *b) {
        NSComparisonResult result = [a.fileName localizedStandardCompare:b.fileName];
        if (result != NSOrderedSame) return result;
        return [a.currentFolder localizedStandardCompare:b.currentFolder];
    }];
    self.modsLibraryBrowseEntries = sortedEntries;

    NSString *openFolder = self.modsLibrarySelectedFolder;
    if (openFolder.length > 0) {
        BOOL openFolderExists = [[ModAssetLibrary folderNames] containsObject:openFolder] ||
            (zs_mods_folder_is_or_within_stored_bundles(openFolder) && [[ModAssetLibrary subFolderNamesInFolder:kZSStoredBundlesFolderName] containsObject:openFolder]);
        if (!openFolderExists) self.modsLibrarySelectedFolder = nil;
    }

    NSString *selectedPath = self.modsLibrarySelectedEntry.path;
    self.modsLibrarySelectedEntry = nil;
    if (selectedPath.length > 0) {
        for (ModAssetLibraryEntry *entry in sortedEntries) {
            if ([entry.path isEqualToString:selectedPath]) {
                self.modsLibrarySelectedEntry = entry;
                break;
            }
        }
    }
}
- (void)zs_assetExplorerShowModLibrary {
    [self.assetExplorerSearchField resignFirstResponder];
    self.assetExplorerSelectedBundle = nil;
    self.assetExplorerAssets = @[];
    self.assetExplorerDisplayedAssets = @[];
    self.assetExplorerDisplayedBundles = @[];
    self.assetExplorerHubVisible = NO;
    self.assetExplorerFMODMode = NO;
    self.assetExplorerFMODBankFile = nil;
    self.assetExplorerFMODBank = nil;
    self.assetExplorerFMODStream = nil;
    self.assetExplorerLocalizeMode = NO;
    self.assetExplorerTextureOpen = NO;
    self.assetExplorerDataMode = NO;
    self.modsLibrarySelectedEntry = nil;
    self.assetExplorerStatusMessage = nil;
    self.assetExplorerSearchField.text = @"";
    [self zs_assetExplorerResetViewState];
    [self zs_assetExplorerRefreshModLibraryEntries];

    self.assetExplorerHubView.hidden = YES;
    self.assetExplorerFMODTableView.hidden = YES;
    self.assetExplorerLocalizeTableView.hidden = YES;
    self.assetExplorerLocalizeJSONTableView.hidden = YES;
    self.assetExplorerTableView.hidden = NO;
    self.assetExplorerThumbCollectionView.hidden = YES;
    self.assetExplorerTextView.hidden = YES;
    self.assetExplorerTextureImageView.hidden = YES;
    self.assetExplorerBackdropView.hidden = YES;
    self.assetExplorerTextureMessageLabel.hidden = YES;
    self.assetExplorerTextureCaptionLabel.hidden = YES;
    self.assetExplorerDebugLabel.hidden = YES;
    self.assetExplorerTexturePagerStack.hidden = YES;
    self.assetExplorerPageStack.hidden = YES;
    self.assetExplorerModeControl.hidden = YES;
    self.assetExplorerTextureBackButton.hidden = YES;
    self.assetExplorerTextureExportButton.hidden = YES;
    [self.assetExplorerTextureSpinner stopAnimating];

    self.assetExplorerCloseButton.hidden = NO;
    self.assetExplorerBackButton.hidden = YES;
    self.assetExplorerTitleLabel.hidden = NO;
    self.assetExplorerTitleLabel.text = @"Mod Library";
    self.assetExplorerStatusLabel.hidden = NO;
    self.assetExplorerSearchContainer.hidden = NO;
    self.assetExplorerControlsStack.hidden = YES;
    self.assetExplorerSearchField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    [self zs_assetExplorerRefreshListResettingScroll:YES];
}
- (NSAttributedString *)zs_modsLibraryDetailTextForEntry:(ModAssetLibraryEntry *)entry {
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    [rows addObject:@[@"Kind", zs_mods_library_entry_kind_title(entry)]];

    NSNumberFormatter *grouping = [[NSNumberFormatter alloc] init];
    grouping.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *readable = [NSByteCountFormatter stringFromByteCount:(long long)entry.byteSize countStyle:NSByteCountFormatterCountStyleFile];
    NSString *exact = [grouping stringFromNumber:@(entry.byteSize)] ?: [NSString stringWithFormat:@"%llu", entry.byteSize];
    [rows addObject:@[@"Size", [NSString stringWithFormat:@"%@ (%@ bytes)", readable, exact]]];

    if (entry.cabIdentifier.length > 0) [rows addObject:@[@"CAB Identifier", entry.cabIdentifier]];
    if (entry.resolvedInstallTargetPath.length > 0) [rows addObject:@[@"File path", entry.resolvedInstallTargetPath]];
    NSString *platformName = zs_mods_library_target_platform_name(entry.targetPlatform);
    if (platformName.length > 0) [rows addObject:@[@"Target Platform", platformName]];

    NSString *dateText = entry.dateAdded.length > 0 ? entry.dateAdded : @"Unknown";
    NSDateFormatter *parser = [[NSDateFormatter alloc] init];
    parser.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    parser.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    parser.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *added = entry.dateAdded.length > 0 ? [parser dateFromString:entry.dateAdded] : nil;
    if (added) dateText = [NSDateFormatter localizedStringFromDate:added dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
    [rows addObject:@[@"Date Added", dateText]];

    BOOL installed = entry.isAssetBundle ? entry.doctorStatus == ModAssetLibraryDoctorStatusInstalled : YES;
    BOOL checksumMismatch = [ModAssetLibrary integrityForEntry:entry] == ModAssetLibraryIntegrityMismatch;
    [rows addObject:@[@"Status", checksumMismatch ? @"Checksum mismatch" : (installed ? @"Installed" : @"Not installed")]];

    if (entry.isAssetBundle || entry.doctorTranscodeCodec.length > 0) {
        NSString *codec = entry.doctorTranscodeCodec.length > 0 ? entry.doctorTranscodeCodec : @"—";
        if ([codec isEqualToString:@"ASTC_RGBA_6x6"]) codec = @"ASTC 6x6";
        [rows addObject:@[@"Codec", codec]];
    }
    if (entry.isAssetBundle) {
        NSString *passthrough = entry.doctorRGBA32Passthrough ? (entry.doctorRGBA32Passthrough.boolValue ? @"Yes" : @"No") : @"—";
        [rows addObject:@[@"Passthrough RGBA32", passthrough]];
    }

    UIFont *labelFont = zs_mono_font(9, UIFontWeightMedium);
    UIFont *valueFont = zs_mono_font(12, UIFontWeightRegular);
    UIColor *labelColor = [UIColor colorWithWhite:1 alpha:0.42];
    UIColor *valueColor = [UIColor colorWithWhite:1 alpha:0.92];
    NSMutableParagraphStyle *labelStyle = [[NSMutableParagraphStyle alloc] init];
    labelStyle.paragraphSpacing = 2;
    NSMutableParagraphStyle *valueStyle = [[NSMutableParagraphStyle alloc] init];
    valueStyle.paragraphSpacing = 14;

    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    for (NSArray<NSString *> *row in rows) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[row[0].uppercaseString stringByAppendingString:@"\n"] attributes:@{NSFontAttributeName: labelFont, NSForegroundColorAttributeName: labelColor, NSParagraphStyleAttributeName: labelStyle, NSKernAttributeName: @0.6}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[row[1] stringByAppendingString:@"\n"] attributes:@{NSFontAttributeName: valueFont, NSForegroundColorAttributeName: valueColor, NSParagraphStyleAttributeName: valueStyle}]];
    }
    return text;
}
- (void)zs_assetExplorerShowModLibraryEntry:(ModAssetLibraryEntry *)entry {
    if (!entry || !self.modsLibraryBrowseMode) return;
    self.modsLibrarySelectedEntry = entry;
    self.assetExplorerTextView.attributedText = [self zs_modsLibraryDetailTextForEntry:entry];
    self.assetExplorerTextView.contentOffset = CGPointZero;
    self.assetExplorerTextView.hidden = NO;
    self.assetExplorerTableView.hidden = YES;
    self.assetExplorerThumbCollectionView.hidden = YES;
    self.assetExplorerHubView.hidden = YES;
    self.assetExplorerFMODTableView.hidden = YES;
    self.assetExplorerLocalizeTableView.hidden = YES;
    self.assetExplorerLocalizeJSONTableView.hidden = YES;
    self.assetExplorerTextureImageView.hidden = YES;
    self.assetExplorerBackdropView.hidden = YES;
    self.assetExplorerTextureMessageLabel.hidden = YES;
    self.assetExplorerTextureCaptionLabel.hidden = YES;
    self.assetExplorerDebugLabel.hidden = YES;
    self.assetExplorerTexturePagerStack.hidden = YES;
    self.assetExplorerPageStack.hidden = YES;
    self.assetExplorerModeControl.hidden = YES;
    self.assetExplorerTextureBackButton.hidden = YES;
    self.assetExplorerTextureExportButton.hidden = YES;
    [self.assetExplorerTextureSpinner stopAnimating];

    self.assetExplorerCloseButton.hidden = YES;
    self.assetExplorerBackButton.hidden = NO;
    self.assetExplorerTitleLabel.hidden = NO;
    self.assetExplorerTitleLabel.text = entry.remark.length > 0 ? entry.remark : (entry.fileName ?: @"Asset Details");
    self.assetExplorerStatusLabel.hidden = YES;
    self.assetExplorerSearchContainer.hidden = YES;
    self.assetExplorerControlsStack.hidden = YES;
    [self zs_assetExplorerSyncControls];
}
- (void)zs_modsLibraryRefreshListResettingScroll:(BOOL)resetScroll query:(NSString *)query {
    [self zs_modsLibraryRebuildRowsForQuery:query];
    if (!self.modsLibrarySelectedEntry) [self zs_modsLibraryApplyListChrome];
    NSUInteger folderCount = self.modsLibraryDisplayedFolders.count;
    NSUInteger entryCount = self.modsLibraryDisplayedEntries.count;
    NSMutableArray<NSString *> *statusParts = [NSMutableArray array];
    if (folderCount > 0) [statusParts addObject:[NSString stringWithFormat:@"%lu folder%@", (unsigned long)folderCount, folderCount == 1 ? @"" : @"s"]];
    if (entryCount > 0 || folderCount == 0) [statusParts addObject:[NSString stringWithFormat:@"%lu asset%@", (unsigned long)entryCount, entryCount == 1 ? @"" : @"s"]];
    self.assetExplorerStatusLabel.text = [statusParts componentsJoinedByString:@"  •  "];
    [self.assetExplorerTableView reloadData];
    [self.modsLibraryIconsCollectionView reloadData];
    if (resetScroll) {
        [self.assetExplorerTableView setContentOffset:CGPointZero animated:NO];
        [self.modsLibraryIconsCollectionView setContentOffset:CGPointZero animated:NO];
    }
    [self zs_assetExplorerUpdateThumbnailGrid];
    [self zs_modsLibraryApplyViewModeVisibility];
}

- (void)zs_modsLibraryApplyViewModeVisibility {
    UICollectionView *icons = self.modsLibraryIconsCollectionView;
    if (!icons) return;
    BOOL listing = self.modsLibraryBrowseMode && !self.modsLibrarySelectedEntry;
    BOOL showIcons = listing && self.modsLibraryIconsMode;
    icons.hidden = !showIcons;
    if (listing) self.assetExplorerTableView.hidden = showIcons;
}

- (void)zs_modsLibraryBuildHeaderControls {
    UIView *overlay = self.assetExplorerFullScreenOverlay;
    if (!overlay) return;
    if (self.modsLibraryControlsRow.superview == overlay && self.assetExplorerStatusTrailingToModsRow) return;
    [self.modsLibraryIconsCollectionView removeFromSuperview];
    [self.modsLibraryControlsRow removeFromSuperview];

    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    UIColor *idleTint = [UIColor colorWithWhite:1 alpha:0.9];

    UIButton *addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    addButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(addButton, [UIImage systemImageNamed:@"plus" withConfiguration:symbolConfig], zs_accent_green_color());
    [addButton addTarget:self action:@selector(zs_modsLibraryAddModTapped) forControlEvents:UIControlEventTouchUpInside];
    addButton.accessibilityLabel = @"Add Mod";
    self.modsLibraryAddButton = addButton;

    UIButton *sortButton = [UIButton buttonWithType:UIButtonTypeSystem];
    sortButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(sortButton, [UIImage systemImageNamed:@"arrow.up.arrow.down" withConfiguration:symbolConfig], idleTint);
    sortButton.showsMenuAsPrimaryAction = YES;
    sortButton.tag = 0;
    sortButton.accessibilityLabel = @"Sort by";
    self.modsLibrarySortButton = sortButton;

    UIButton *viewButton = [UIButton buttonWithType:UIButtonTypeSystem];
    viewButton.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_pill_icon_button_as_native_glass(viewButton, [UIImage systemImageNamed:@"square.grid.2x2" withConfiguration:symbolConfig], idleTint);
    [viewButton addTarget:self action:@selector(zs_modsLibraryViewModeTapped) forControlEvents:UIControlEventTouchUpInside];
    viewButton.tag = 0;
    viewButton.accessibilityLabel = @"View";
    self.modsLibraryViewButton = viewButton;

    ZSGlassControlRow *row = [[ZSGlassControlRow alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.itemSize = 30;
    row.itemSpacing = 8;
    row.itemWidths = @[@39, @30, @30];
    row.hidden = YES;
    [overlay addSubview:row];
    row.buttons = @[addButton, sortButton, viewButton];
    self.modsLibraryControlsRow = row;

    ZSModsLibraryIconsSource *source = [[ZSModsLibraryIconsSource alloc] init];
    source.owner = self;
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 8;
    layout.minimumLineSpacing = 12;
    layout.sectionInset = UIEdgeInsetsMake(8, kZSSyslogFullScreenLeftInset, 12, kPanelPadding);
    UICollectionView *icons = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    icons.translatesAutoresizingMaskIntoConstraints = NO;
    icons.backgroundColor = UIColor.clearColor;
    icons.showsVerticalScrollIndicator = NO;
    icons.alwaysBounceVertical = YES;
    icons.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    icons.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    icons.hidden = YES;
    [icons registerClass:[ZSModsLibraryIconCell class] forCellWithReuseIdentifier:@"ZSModsLibraryIconCell"];
    icons.dataSource = source;
    icons.delegate = source;
    [overlay addSubview:icons];
    self.modsLibraryIconsSource = source;
    self.modsLibraryIconsCollectionView = icons;

    UIView *closeButton = self.assetExplorerCloseButton;
    UIView *search = self.assetExplorerSearchContainer;
    UITableView *table = self.assetExplorerTableView;
    [NSLayoutConstraint activateConstraints:@[
        [addButton.widthAnchor constraintEqualToConstant:39],
        [addButton.heightAnchor constraintEqualToConstant:30],
        [sortButton.widthAnchor constraintEqualToConstant:30],
        [sortButton.heightAnchor constraintEqualToConstant:30],
        [viewButton.widthAnchor constraintEqualToConstant:30],
        [viewButton.heightAnchor constraintEqualToConstant:30],
        [row.widthAnchor constraintEqualToConstant:39 + 30 + 30 + 16],
        [row.heightAnchor constraintEqualToConstant:30],
        [row.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [row.trailingAnchor constraintEqualToAnchor:search.leadingAnchor constant:-8],

        [icons.topAnchor constraintEqualToAnchor:table.topAnchor],
        [icons.leadingAnchor constraintEqualToAnchor:table.leadingAnchor],
        [icons.trailingAnchor constraintEqualToAnchor:table.trailingAnchor],
        [icons.bottomAnchor constraintEqualToAnchor:table.bottomAnchor],
    ]];

    self.assetExplorerStatusTrailingToModsRow = [self.assetExplorerStatusLabel.trailingAnchor constraintEqualToAnchor:row.leadingAnchor constant:-10];
    self.assetExplorerStatusTrailingToModsRow.active = NO;
}

- (void)zs_modsLibrarySyncHeaderControls {
    if (!self.modsLibraryControlsRow) return;
    BOOL browsing = self.modsLibraryBrowseMode;
    BOOL listing = browsing && !self.modsLibrarySelectedEntry;
    self.modsLibraryControlsRow.hidden = !listing;
    if (browsing) {
        self.assetExplorerStatusTrailingToControls.active = NO;
        self.assetExplorerStatusTrailingToModsRow.active = YES;
    } else {
        self.assetExplorerStatusTrailingToModsRow.active = NO;
        self.assetExplorerStatusTrailingToControls.active = YES;
    }
    [self zs_modsLibraryApplyViewModeVisibility];
    if (listing) [self zs_modsLibraryRebuildHeaderMenus];
}

- (void)zs_modsLibraryRebuildHeaderMenus {
    if (!self.modsLibrarySortButton) return;
    __weak typeof(self) weakSelf = self;
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    NSInteger mode = self.modsLibrarySortMode;
    BOOL ascending = !self.modsLibrarySortDescending;

    NSArray<NSDictionary<NSString *, id> *> *specs = @[
        @{@"title": @"Name", @"mode": @(kZSModsLibrarySortName), @"asc": @"Name · A to Z", @"desc": @"Name · Z to A", @"defaultAsc": @YES},
        @{@"title": @"Size", @"mode": @(kZSModsLibrarySortSize), @"asc": @"Size · Smallest first", @"desc": @"Size · Largest first", @"defaultAsc": @NO},
        @{@"title": @"Date Added", @"mode": @(kZSModsLibrarySortDate), @"asc": @"Date Added · Oldest first", @"desc": @"Date Added · Newest first", @"defaultAsc": @NO},
        @{@"title": @"File Kind", @"mode": @(kZSModsLibrarySortKind), @"asc": @"File Kind · A to Z", @"desc": @"File Kind · Z to A", @"defaultAsc": @YES},
    ];
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithCapacity:specs.count];
    for (NSDictionary<NSString *, id> *spec in specs) {
        NSInteger specMode = [spec[@"mode"] integerValue];
        BOOL active = specMode == mode;
        NSString *title = active ? (ascending ? spec[@"asc"] : spec[@"desc"]) : spec[@"title"];
        UIImage *image = active ? [UIImage systemImageNamed:(ascending ? @"arrow.up" : @"arrow.down")] : nil;
        BOOL defaultAscending = [spec[@"defaultAsc"] boolValue];
        UIAction *action = [UIAction actionWithTitle:title image:image identifier:nil handler:^(__kindof UIAction *selected) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.modsLibrarySortMode == specMode) {
                strongSelf.modsLibrarySortDescending = !strongSelf.modsLibrarySortDescending;
            } else {
                strongSelf.modsLibrarySortMode = specMode;
                strongSelf.modsLibrarySortDescending = !defaultAscending;
            }
            [strongSelf zs_assetExplorerRefreshListResettingScroll:YES];
            [strongSelf zs_modsLibraryRebuildHeaderMenus];
        }];
        action.state = active ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:action];
    }

    BOOL sortActive = mode != kZSModsLibrarySortName || !ascending;
    NSInteger desiredSortStyle = sortActive ? 1 : 0;
    if (self.modsLibrarySortButton.tag != desiredSortStyle) {
        UIColor *tint = sortActive ? zs_accent_green_color() : [UIColor colorWithWhite:1 alpha:0.9];
        zs_style_pill_icon_button_as_native_glass(self.modsLibrarySortButton, [UIImage systemImageNamed:@"arrow.up.arrow.down" withConfiguration:symbolConfig], tint);
        self.modsLibrarySortButton.tag = desiredSortStyle;
    }
    self.modsLibrarySortButton.menu = [UIMenu menuWithTitle:@"Sort by" children:items];
    self.modsLibrarySortButton.showsMenuAsPrimaryAction = YES;

    NSInteger desiredViewStyle = self.modsLibraryIconsMode ? 1 : 0;
    if (self.modsLibraryViewButton.tag != desiredViewStyle) {
        UIColor *tint = self.modsLibraryIconsMode ? zs_accent_green_color() : [UIColor colorWithWhite:1 alpha:0.9];
        zs_style_pill_icon_button_as_native_glass(self.modsLibraryViewButton, [UIImage systemImageNamed:(self.modsLibraryIconsMode ? @"list.bullet" : @"square.grid.2x2") withConfiguration:symbolConfig], tint);
        self.modsLibraryViewButton.tag = desiredViewStyle;
    }
}

- (void)zs_modsLibraryAddModTapped {
    [self.assetExplorerSearchField resignFirstResponder];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self loadModsTapped];
}

- (void)zs_modsLibraryViewModeTapped {
    self.modsLibraryIconsMode = !self.modsLibraryIconsMode;
    [self zs_modsLibraryRebuildHeaderMenus];
    [self.modsLibraryIconsCollectionView reloadData];
    [self.modsLibraryIconsCollectionView setContentOffset:CGPointZero animated:NO];
    [self zs_modsLibraryApplyViewModeVisibility];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (nullable UIView *)zs_modsLibraryInstallAccessoryForEntry:(ModAssetLibraryEntry *)entry {
    if (!entry.isAssetBundle || zs_mods_folder_is_or_within_stored_bundles(entry.currentFolder ?: @"")) return nil;
    NSString *title = nil;
    SEL action = NULL;
    UIColor *tint = zs_accent_green_color();
    switch (entry.doctorStatus) {
        case ModAssetLibraryDoctorStatusNotDispatched:
            title = @"Install";
            action = @selector(zs_modsLibraryEntryDispatchTapped:);
            break;
        case ModAssetLibraryDoctorStatusReadyToDownload:
            if ([self.doctorDownloadInFlightPaths containsObject:entry.path]) return nil;
            title = @"Install";
            action = @selector(zs_modsLibraryEntryDownloadTapped:);
            break;
        case ModAssetLibraryDoctorStatusFailed:
            title = @"Retry";
            action = @selector(zs_modsLibraryEntryRetryTapped:);
            tint = [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];
            break;
        default:
            return nil;
    }
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    zs_style_button_as_native_glass_with_font(button, title, tint, zs_mono_font(12, UIFontWeightSemibold));
    button.titleLabel.numberOfLines = 1;
    button.titleLabel.lineBreakMode = NSLineBreakByClipping;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = button.configuration;
        if (configuration) {
            configuration.titleLineBreakMode = NSLineBreakByClipping;
            configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 4, 0, 4);
            button.configuration = configuration;
        }
    }
    objc_setAssociatedObject(button, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    ZSGlassControlRow *holder = [[ZSGlassControlRow alloc] initWithFrame:CGRectMake(0, 0, 77, 31)];
    holder.itemSize = 31;
    holder.itemSpacing = 0;
    holder.itemWidths = @[@77];
    holder.buttons = @[button];
    return holder;
}

- (UITableViewCell *)zs_modsLibraryCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
    static NSString * const libraryIdentifier = @"zs.asset.explorer.mod-library.cell";
    UITableViewCell *libraryCell = [tableView dequeueReusableCellWithIdentifier:libraryIdentifier];
    if (!libraryCell) libraryCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:libraryIdentifier];
    NSDictionary<NSString *, id> *folderRow = [self zs_modsLibraryFolderAtIndexPath:indexPath];
    ModAssetLibraryEntry *entry = folderRow ? nil : [self zs_modsLibraryEntryAtIndexPath:indexPath];
    if (!folderRow && !entry) return libraryCell;
    libraryCell.indentationLevel = 0;
    libraryCell.backgroundColor = UIColor.clearColor;
    libraryCell.contentView.backgroundColor = UIColor.clearColor;
    libraryCell.textLabel.font = zs_mono_font(11, UIFontWeightRegular);
    libraryCell.textLabel.textColor = [UIColor colorWithWhite:0.94 alpha:1];
    libraryCell.textLabel.numberOfLines = 1;
    libraryCell.textLabel.adjustsFontSizeToFitWidth = YES;
    libraryCell.textLabel.minimumScaleFactor = 0.65;
    libraryCell.detailTextLabel.font = zs_mono_font(9, UIFontWeightRegular);
    libraryCell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.42];
    libraryCell.detailTextLabel.numberOfLines = 1;
    libraryCell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    if (folderRow) {
        NSString *folderRemark = folderRow[@"remark"];
        NSString *folderInfo = zs_mods_library_folder_info(folderRow, NO);
        libraryCell.textLabel.text = folderRow[@"title"];
        libraryCell.detailTextLabel.text = folderRemark.length > 0 ? [NSString stringWithFormat:@"%@  •  %@", folderRemark, folderInfo] : folderInfo;
        libraryCell.accessoryView = nil;
        UIImageSymbolConfiguration *folderSymbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
        libraryCell.imageView.image = [UIImage systemImageNamed:@"folder.fill" withConfiguration:folderSymbolConfig];
        libraryCell.imageView.tintColor = [UIColor colorWithRed:0.42 green:0.62 blue:1.0 alpha:1.0];
        libraryCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        libraryCell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return libraryCell;
    }
    libraryCell.textLabel.text = zs_mods_library_entry_title(entry);
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)entry.byteSize countStyle:NSByteCountFormatterCountStyleFile];
    NSString *kind = zs_mods_library_entry_kind(entry);
    NSString *status = zs_mods_library_entry_status(entry);
    NSMutableArray<NSString *> *detailParts = [NSMutableArray array];
    if (entry.remark.length > 0 && entry.fileName.length > 0) [detailParts addObject:entry.fileName];
    if (self.modsLibrarySelectedFolder.length == 0 && entry.currentFolder.length > 0) [detailParts addObject:entry.currentFolder];
    [detailParts addObject:size];
    [detailParts addObject:status.length > 0 ? status : (kind.length > 0 ? kind : @"File")];
    libraryCell.detailTextLabel.text = [detailParts componentsJoinedByString:@"  •  "];
    NSString *symbol = zs_mods_library_entry_symbol(entry);
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular];
    libraryCell.imageView.image = [UIImage systemImageNamed:symbol withConfiguration:symbolConfig];
    libraryCell.imageView.tintColor = zs_accent_green_color();
    libraryCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    libraryCell.accessoryView = [self zs_modsLibraryInstallAccessoryForEntry:entry];
    libraryCell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return libraryCell;
}

- (void)zs_modsLibraryLeaveForAssetExplorer {
    [self.assetExplorerSearchField resignFirstResponder];
    self.modsLibraryBrowseMode = NO;
    self.modsLibrarySelectedEntry = nil;
    self.modsLibrarySelectedFolder = nil;
    self.modsLibraryBrowseEntries = @[];
    self.modsLibraryDisplayedEntries = @[];
    self.modsLibraryDisplayedFolders = @[];
    self.assetExplorerSearchField.text = @"";
    [self zs_assetExplorerShowHub];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

- (void)zs_modsLibraryViewEntryInAssetExplorer:(ModAssetLibraryEntry *)entry {
    if (!zs_mods_library_entry_supports_explorer(entry) || !self.modsLibraryBrowseMode) return;
    if (entry.isAssetBundle) {
        [self zs_modsLibraryViewBundleEntryInAssetExplorer:entry];
    } else if ([entry.fileName.pathExtension caseInsensitiveCompare:@"bank"] == NSOrderedSame) {
        [self zs_modsLibraryViewBankEntryInAssetExplorer:entry];
    } else {
        [self zs_modsLibraryViewLocalizationEntryInAssetExplorer:entry];
    }
}

- (void)zs_modsLibraryViewBundleEntryInAssetExplorer:(ModAssetLibraryEntry *)entry {
    NSString *cab = [entry.cabIdentifier copy] ?: @"";
    NSString *targetPath = entry.resolvedInstallTargetPath.length > 0 ? [NSHomeDirectory() stringByAppendingPathComponent:entry.resolvedInstallTargetPath].stringByStandardizingPath : @"";
    NSString *displayName = zs_mods_library_entry_title(entry);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ZSAssetExplorerBundle * (^findIn)(NSArray<ZSAssetExplorerBundle *> *) = ^ZSAssetExplorerBundle *(NSArray<ZSAssetExplorerBundle *> *list) {
            for (ZSAssetExplorerBundle *candidate in list) {
                if (cab.length > 0 && [candidate.cabIdentifier caseInsensitiveCompare:cab] == NSOrderedSame) return candidate;
            }
            if (targetPath.length > 0) {
                for (ZSAssetExplorerBundle *candidate in list) {
                    if ([candidate.filePath.stringByStandardizingPath isEqualToString:targetPath]) return candidate;
                }
            }
            return nil;
        };
        NSArray<ZSAssetExplorerBundle *> *bundles = [ZSAssetExplorer cachedBundles:nil] ?: @[];
        ZSAssetExplorerBundle *match = findIn(bundles);
        if (!match) {
            [ZSFileIndex ensureIndexUpToDate];
            bundles = [ZSAssetExplorer cachedBundles:nil] ?: @[];
            match = findIn(bundles);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || !strongSelf.modsLibraryBrowseMode) return;
            if (!match) {
                [strongSelf zs_presentModsAlertWithTitle:@"Not Found in AssetExplorer" message:[NSString stringWithFormat:@"%@ doesn't match any Unity asset bundle the AssetExplorer has indexed.", displayName]];
                return;
            }
            [strongSelf zs_modsLibraryLeaveForAssetExplorer];
            strongSelf.assetExplorerHubVisible = NO;
            strongSelf.assetExplorerFMODMode = NO;
            strongSelf.assetExplorerHubView.hidden = YES;
            strongSelf.assetExplorerFMODTableView.hidden = YES;
            strongSelf.assetExplorerBundles = bundles;
            strongSelf.assetExplorerTableView.hidden = NO;
            NSUInteger namesSession = strongSelf.assetExplorerNamesSession;
            [strongSelf zs_assetExplorerOpenBundle:match];
            [ZSAssetExplorer resolveNamesForBundles:bundles
                                          batchSize:150
                                     shouldContinue:^BOOL{
                typeof(self) innerSelf = weakSelf;
                return innerSelf && innerSelf.assetExplorerFullScreenOpen && innerSelf.assetExplorerNamesSession == namesSession;
            }
                                            handler:^(NSArray<ZSAssetExplorerBundle *> *updated) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) innerSelf = weakSelf;
                    if (!innerSelf || !innerSelf.assetExplorerFullScreenOpen || innerSelf.assetExplorerNamesSession != namesSession) return;
                    innerSelf.assetExplorerBundles = updated;
                    if (!innerSelf.assetExplorerSelectedBundle) [innerSelf zs_assetExplorerRefreshListResettingScroll:NO];
                });
            }];
        });
    });
}

- (void)zs_modsLibraryViewBankEntryInAssetExplorer:(ModAssetLibraryEntry *)entry {
    NSString *bankName = [entry.fileName copy] ?: @"";
    NSString *displayName = zs_mods_library_entry_title(entry);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<ZSFMODBankFile *> *banks = [ZSFMODExplorer availableBanks:nil] ?: @[];
        ZSFMODBankFile *match = nil;
        for (ZSFMODBankFile *candidate in banks) {
            if ([candidate.fileName caseInsensitiveCompare:bankName] == NSOrderedSame) { match = candidate; break; }
        }
        NSMutableSet<NSString *> *modded = [NSMutableSet set];
        for (NSString *relative in [BankTransplant documentsRelativePathsOfSwappedBanks] ?: @[]) {
            [modded addObject:relative.lastPathComponent];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.assetExplorerFullScreenOpen || !strongSelf.modsLibraryBrowseMode) return;
            if (!match) {
                [strongSelf zs_presentModsAlertWithTitle:@"Not Found in AssetExplorer" message:[NSString stringWithFormat:@"%@ doesn't match any FMOD audio bank the AssetExplorer can see.", displayName]];
                return;
            }
            [strongSelf zs_modsLibraryLeaveForAssetExplorer];
            strongSelf.assetExplorerHubVisible = NO;
            strongSelf.assetExplorerFMODMode = YES;
            strongSelf.assetExplorerFMODBankFiles = banks;
            strongSelf.assetExplorerFMODModdedNames = modded;
            strongSelf.assetExplorerStatusMessage = nil;
            [strongSelf zs_assetExplorerFMODApplyLevel];
            [strongSelf zs_assetExplorerFMODRefreshListResettingScroll:YES];
            [strongSelf zs_assetExplorerFMODOpenBankFile:match];
        });
    });
}

- (void)zs_modsLibraryViewLocalizationEntryInAssetExplorer:(ModAssetLibraryEntry *)entry {
    NSString *root = [LocalizationTransplant localizeDirectory] ?: @"";
    NSString *relative = entry.localizationRelativePath ?: @"";
    NSString *target = relative.length > 0 ? [root stringByAppendingPathComponent:relative] : root;
    BOOL isDirectory = NO;
    if (root.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:target isDirectory:&isDirectory]) {
        [self zs_presentModsAlertWithTitle:@"Not Found in AssetExplorer" message:[NSString stringWithFormat:@"%@ isn't present in the game's localization folder.", zs_mods_library_entry_title(entry)]];
        return;
    }
    [self zs_modsLibraryLeaveForAssetExplorer];
    self.assetExplorerHubVisible = NO;
    self.assetExplorerFMODMode = NO;
    self.assetExplorerLocalizeMode = YES;
    self.assetExplorerLocalizeRoot = root;
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    NSString *directory = isDirectory ? target : target.stringByDeletingLastPathComponent;
    NSString *cursor = directory;
    while (cursor.length > root.length && [cursor hasPrefix:root]) {
        [offsets addObject:@0];
        cursor = cursor.stringByDeletingLastPathComponent;
    }
    self.assetExplorerLocalizeOffsets = offsets;
    self.assetExplorerLocalizePendingOffset = nil;
    self.assetExplorerLocalizePendingOpenFilePath = isDirectory ? nil : target;
    [self zs_assetExplorerLocalizeOpenDirectory:directory];
}

- (UIContextMenuConfiguration *)zs_modsLibraryContextMenuForIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(13.0)) {
    NSDictionary<NSString *, id> *folderRow = [self zs_modsLibraryFolderAtIndexPath:indexPath];
    if (folderRow) return [self zs_modsLibraryContextMenuForFolderRow:folderRow];
    ModAssetLibraryEntry *entry = [self zs_modsLibraryEntryAtIndexPath:indexPath];
    if (!entry) return nil;
    NSString *folderName = entry.currentFolder ?: @"";
    BOOL storedEntry = zs_mods_folder_is_or_within_stored_bundles(folderName);
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:entry.path previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        NSMutableArray<UIMenuElement *> *menuItems = [NSMutableArray array];
        BOOL doctorEligible = !storedEntry && (entry.isAssetBundle || entry.zipCacheHash1.length > 0);
        NSString *primaryTitle = nil;
        SEL primaryAction = NULL;
        if (doctorEligible) {
            if (entry.doctorStatus == ModAssetLibraryDoctorStatusNotDispatched) {
                primaryTitle = @"Install / Transcode";
                primaryAction = @selector(zs_modsLibraryEntryDispatchTapped:);
            } else if (entry.doctorStatus == ModAssetLibraryDoctorStatusReadyToDownload) {
                primaryTitle = @"Download";
                primaryAction = @selector(zs_modsLibraryEntryDownloadTapped:);
            } else if (entry.doctorStatus == ModAssetLibraryDoctorStatusFailed) {
                primaryTitle = @"Retry";
                primaryAction = @selector(zs_modsLibraryEntryRetryTapped:);
            }
        }
        if (primaryTitle.length > 0) {
            UIAction *primary = [UIAction actionWithTitle:primaryTitle image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(__kindof UIAction *action) {
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                UIButton *sender = [UIButton buttonWithType:UIButtonTypeCustom];
                objc_setAssociatedObject(sender, "zs_modsEntry", entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ((void (*)(id, SEL, id))objc_msgSend)(strongSelf, primaryAction, sender);
            }];
            [menuItems addObject:primary];
        }

        if (!storedEntry && zs_mods_library_entry_supports_explorer(entry)) {
            UIAction *viewAction = [UIAction actionWithTitle:@"View in AssetExplorer" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(__kindof UIAction *action) {
                [weakSelf zs_modsLibraryViewEntryInAssetExplorer:entry];
            }];
            [menuItems addObject:viewAction];
        }

        NSArray<NSDictionary<NSString *, id> *> *options = storedEntry ? zs_mods_stored_bundle_file_options() : zs_mods_file_options(entry);
        NSMutableArray<UIMenuElement *> *optionItems = [NSMutableArray arrayWithCapacity:options.count];
        for (NSDictionary<NSString *, id> *option in options) {
            NSString *title = option[@"title"] ?: @"Action";
            NSString *symbol = option[@"symbol"];
            UIMenuElementAttributes attributes = 0;
            if ([option[@"destructive"] boolValue]) attributes |= UIMenuElementAttributesDestructive;
            if ([option[@"disabled"] boolValue]) attributes |= UIMenuElementAttributesDisabled;
            UIAction *item = [UIAction actionWithTitle:title image:(symbol.length > 0 ? [UIImage systemImageNamed:symbol] : nil) identifier:nil handler:^(__kindof UIAction *action) {
                [weakSelf zs_modsLibraryPerformOptionNamed:title forEntry:entry folderName:folderName];
            }];
            item.attributes = attributes;
            [optionItems addObject:item];
        }
        [menuItems addObjectsFromArray:optionItems];
        return [UIMenu menuWithTitle:zs_mods_library_entry_title(entry) children:menuItems];
    }];
    return nil;
}

- (void)zs_modsLibrarySelectRowAtIndexPath:(NSIndexPath *)indexPath inTableView:(UITableView *)tableView {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary<NSString *, id> *tappedFolder = self.modsLibrarySelectedEntry ? nil : [self zs_modsLibraryFolderAtIndexPath:indexPath];
    if (tappedFolder) {
        [self zs_modsLibraryOpenFolder:tappedFolder[@"folder"]];
        return;
    }
    ModAssetLibraryEntry *selectedLibraryEntry = self.modsLibrarySelectedEntry ? nil : [self zs_modsLibraryEntryAtIndexPath:indexPath];
    if (selectedLibraryEntry) [self zs_assetExplorerShowModLibraryEntry:selectedLibraryEntry];
}

@end
