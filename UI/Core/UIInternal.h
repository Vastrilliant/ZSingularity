#pragma once

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Metal/Metal.h>
#import <os/lock.h>
#import <sys/stat.h>
#import <string.h>
#import "Engine.h"
#import "Diagnostics.h"
#import "ZTweakLog.h"
#import "Mods.h"
#import "Transcoder.h"
#import "TexComp.h"
#import "PatchManifestNetwork.h"
#import "Version.h"
#import "Updater.h"
#import "UnityBundleTools.h"
#import "AssetExplorer.h"
#import "IL2CppIntrospection.h"
#import "Dumper/Dumper.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "GifTint.h"
#import "Logo.h"
#import "DonatedHeap.h"

@class ZSCapsuleSlider, ZSModeSlider, ZSWheelPicker, ZSSelectModeList;
@class ZSAssetCheckerboardView, ZSAssetPreviewClipView, ZSAssetThumbCell, ZSAssetThumbGridSource, ZSCapsuleSlider, ZSDeadZoneScrollView, ZSDocsScrollView, ZSFieldBrowserPickerViewController, ZSFillView, ZSFlatChromeButton, ZSGlassControlRow, ZSGlassWrappedButton, ZSLocJSONCell, ZSLocJSONNode, ZSLogoObserverToken, ZSMarqueeLabel, ZSMemoryColumnRow, ZSMetalTabs, ZSModeSlider, ZSPanelScrollView, ZSPassthroughEffectView, ZSPassthroughView, ZSPillarChartView, ZSPinScrimView, ZSRow, ZSSectionIndexView, ZSSelectModeCell, ZSSelectModeList, ZSSelectModeOverlayView, ZSSyslogCell, ZSSyslogTableController, ZSWeakGlassBox, ZSWheelPicker;

static const CGFloat kZSSubtitleFontSize = 10;

static const float kDefaultValueEpsilon = 0.0005f;

static const NSInteger kZSCrashMessageTextViewTag = 0x5A435248;

static const NSInteger kZSDeveloperUnlockTapCount = 10;
static const CFTimeInterval kZSDeveloperUnlockTapInterval = 0.6;

static const CGFloat kZSAuthFieldCornerRadius = 3;

static const CGFloat kZSDeleteCapsuleExpandedWidth = 60;
static const NSTimeInterval kZSDeleteCapsuleSnapDuration = 0.28;
static const CGFloat kZSDeleteCapsuleSpringDamping = 0.6;
static const CGFloat kZSDeleteCapsuleSpringVelocity = 0.4;

static const CGFloat kZSGroupedCardRowHeight = 40;

typedef struct {
    BOOL diskExists;
    BOOL diskTranscoded;
    BOOL backupExists;
    BOOL backupTranscoded;
} TexCompFolderState;

static const CGFloat kZSMemoryColumnPadding = 14;

static const CGFloat kZSReencodeFieldHeight = 28;

static const CGFloat kZSModsOptionsDropdownWidth = 190;
static const CGFloat kZSModsOptionsRowHeight = kZSReencodeFieldHeight;

static const CGFloat kZSSignatureInset = 8;

typedef NS_ENUM(NSInteger, ZSLocJSONKind) {
    ZSLocJSONKindObject,
    ZSLocJSONKindArray,
    ZSLocJSONKindString,
    ZSLocJSONKindNumber,
    ZSLocJSONKindBool,
    ZSLocJSONKindNull,
};

static const NSTimeInterval kPostFXReapplyInterval = 1.0;

static const CGFloat kZSSectionIndexReservedWidth = 10;

static const CGFloat kPanelWidth = 330;
static const CGFloat kPanelPadding = 16;

static const CGFloat kHandleWidth = 27;
static const CGFloat kHandleHeight = 72;
static const CGFloat kPanelCornerRadiusMinimum = 20;
static const CGFloat kHandleCornerRadius = 10;

static const NSTimeInterval kZSFullScreenPanelDuration = 0.434;
static const NSTimeInterval kZSPullTabIconFadeDuration = 0.155;
static const NSTimeInterval kZSExtendedContentFadeDuration = 0.18;
static const CGFloat kContentFadeHeight = 22;

static const CGFloat kZSLogoDropdownWidth = 156;

static const CGFloat kZSSyslogFullScreenLeftInset = kPanelPadding * 1.5;

@interface UserInterface : NSObject <UIGestureRecognizerDelegate, UIScrollViewDelegate, UITextFieldDelegate, UIDocumentPickerDelegate, UITextViewDelegate, CLLocationManagerDelegate, UIContextMenuInteractionDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIVisualEffectView *glassContainer;
@property (nonatomic, strong) UIVisualEffectView *panelGlass;
@property (nonatomic, strong) UIVisualEffectView *handleGlass;
@property (nonatomic, strong) UIView *contentOverlay;
@property (nonatomic, strong) UIView *glassContainerContent;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, strong) UILabel *chevron;
@property (nonatomic, strong) UIView *scrollViewport;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIStackView *experimentalSectionContainer;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *pendingSectionBuilders;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *pendingExperimentalSectionBuilders;
@property (nonatomic, strong) NSDictionary *pendingCollapsedStates;
@property (nonatomic, copy) NSArray<UIView *> *developerSectionViews;
@property (nonatomic, strong) ZSSectionIndexView *sectionIndexView;
@property (nonatomic, copy) NSArray<NSString *> *sectionIndexSectionNames;
@property (nonatomic, assign) NSInteger developerUnlockTapCount;
@property (nonatomic, assign) CFTimeInterval developerUnlockLastTapTime;
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, assign) BOOL installed;
@property (nonatomic, assign) CGFloat panelWidth;
@property (nonatomic, strong) UIView *tutorialOverlay;
@property (nonatomic, strong) UIView *tutorialPanel;
@property (nonatomic, strong) UIButton *tutorialOKButton;
@property (nonatomic, strong) UILabel *tutorialGestureWarningLabel;
@property (nonatomic, assign) BOOL tutorialCanDismiss;
@property (nonatomic, assign) BOOL tutorialPresented;
@property (nonatomic, strong) NSTimer *tutorialUnlockTimer;
@property (nonatomic, strong) UIView *crashOverlay;
@property (nonatomic, strong) UIView *crashPanel;
@property (nonatomic, assign) BOOL crashReportPresented;
@property (nonatomic, copy) NSDictionary *crashReport;

@property (nonatomic, strong) UIVisualEffectView *docsPanelGlass;
@property (nonatomic, strong) UIVisualEffectView *panelBlurOverlay;
@property (nonatomic, strong) UIViewPropertyAnimator *panelBlurAnimator;
@property (nonatomic, strong) CADisplayLink *panelBlurLink;
@property (nonatomic, assign) BOOL panelBlurActive;
@property (nonatomic, assign) CGFloat panelBlurProgress;
@property (nonatomic, assign) CGFloat panelBlurFrom;
@property (nonatomic, assign) CGFloat panelBlurTo;
@property (nonatomic, assign) CFTimeInterval panelBlurStartTime;
@property (nonatomic, assign) NSTimeInterval panelBlurDuration;
@property (nonatomic, assign) NSUInteger panelBlurToken;
@property (nonatomic, assign) NSUInteger panelBlurGlassToken;
@property (nonatomic, strong) UIView *docsPanel;
@property (nonatomic, strong) UIView *docsContentOverlay;
@property (nonatomic, strong) UIView *extendedContentClip;
@property (nonatomic, assign) BOOL panelLeftCornersFlat;
@property (nonatomic, strong) UIView *docsPanelSeparator;
@property (nonatomic, strong) UIScrollView *docsScrollView;
@property (nonatomic, strong) UILabel *docsTitleLabel;
@property (nonatomic, strong) UIButton *docsHeaderModeChevronButton;
@property (nonatomic, strong) UIButton *docsLanguageButton;
@property (nonatomic, strong) UIView *docsLanguageDropdownOverlay;
@property (nonatomic, strong) UIControl *docsLanguageDropdownScrim;
@property (nonatomic, assign) BOOL docsLanguageDropdownOpen;
@property (nonatomic, weak) UIButton *logoChevronButton;
@property (nonatomic, strong) UIView *logoDropdownOverlay;
@property (nonatomic, strong) UIControl *logoDropdownScrim;
@property (nonatomic, assign) BOOL logoDropdownOpen;
@property (nonatomic, copy) NSArray<NSString *> *logoDropdownNames;
@property (nonatomic, strong) NSLayoutConstraint *docsTitleTrailingFullConstraint;
@property (nonatomic, strong) NSLayoutConstraint *docsTitleTrailingToChevronConstraint;
@property (nonatomic, strong) NSLayoutConstraint *docsTitleTrailingToLanguageConstraint;
@property (nonatomic, strong) UIStackView *docsSubheaderRow;
@property (nonatomic, strong) UILabel *docsSubheaderLabel;
@property (nonatomic, strong) UIStackView *docsSubheaderPageGroup;
@property (nonatomic, strong) UILabel *docsSubheaderPageLabel;
@property (nonatomic, strong) UIButton *docsSubheaderLeftArrowButton;
@property (nonatomic, strong) UIButton *docsSubheaderRightArrowButton;
@property (nonatomic, assign) ZSUpdateCheckMode docsReleaseViewMode;
@property (nonatomic, assign) NSUInteger docsReleaseHistoryIndex;
@property (nonatomic, strong) NSLayoutConstraint *docsScrollViewTopToTitleConstraint;
@property (nonatomic, strong) NSLayoutConstraint *docsScrollViewTopToSubheaderConstraint;
@property (nonatomic, strong) UITextView *docsBodyLabel;
@property (nonatomic, strong) UIStackView *docsUpdateActionsStack;
@property (nonatomic, strong) UIView *docsUpdateActionsSpacer;
@property (nonatomic, strong) UIButton *docsLiveContainerInstallButton;
@property (nonatomic, strong) UIButton *docsGitHubReleaseLinkButton;
@property (nonatomic, strong) UILabel *docsUpdateActionsDisabledNoteLabel;
@property (nonatomic, strong) NSLayoutConstraint *docsScrollViewBottomToOverlayConstraint;
@property (nonatomic, assign) BOOL docsPanelOpen;
@property (nonatomic, copy) NSString *docsActiveKey;
@property (nonatomic, assign) CGFloat docsPanelWidth;
@property (nonatomic, strong) NSTimer *postFXReapplyTimer;
@property (nonatomic, strong) NSTimer *saveDebounceTimer;
@property (nonatomic, assign) BOOL syslogTabEnabled;
@property (nonatomic, strong) NSMutableArray<NSString *> *syslogChannelLines;
@property (nonatomic, strong) NSMutableArray<NSString *> *debugChannelLines;
@property (nonatomic, strong) UITextField *syslogBlacklistField;
@property (nonatomic, strong) UILabel *syslogBlacklistStatusLabel;
@property (nonatomic, strong) UIStackView *syslogBlacklistEntriesStack;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *syslogBlacklist;

@property (nonatomic, weak) UIButton *modsOptionsDropdownButton;
@property (nonatomic, strong) UIView *modsOptionsDropdownOverlay;
@property (nonatomic, strong) UIControl *modsOptionsDropdownScrim;
@property (nonatomic, assign) BOOL modsOptionsDropdownOpen;
@property (nonatomic, strong) ModAssetLibraryEntry *modsOptionsDropdownEntry;
@property (nonatomic, copy) NSString *modsOptionsDropdownFolderName;

@property (nonatomic, weak) UIDocumentPickerViewController *loadModsPicker;
@property (nonatomic, copy) NSString *loadModsTargetFolder;

@property (nonatomic, strong) NSMutableArray<NSString *> *loadModsSummaryLines;

@property (nonatomic, strong) UIStackView *modsLibraryStack;
@property (nonatomic, assign) BOOL modsLibraryBrowseMode;
@property (nonatomic, strong) NSArray<ModAssetLibraryEntry *> *modsLibraryBrowseEntries;
@property (nonatomic, strong) NSArray<ModAssetLibraryEntry *> *modsLibraryDisplayedEntries;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *modsLibraryDisplayedFolders;
@property (nonatomic, copy) NSString *modsLibrarySelectedFolder;
@property (nonatomic, strong) ModAssetLibraryEntry *modsLibrarySelectedEntry;
@property (nonatomic, strong) ZSRow *manifestZeroingRow;
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedFolders;
@property (nonatomic, strong) NSMutableSet<NSString *> *modsLibraryExpandedInfoEntries;
@property (nonatomic, strong) ZSGlassControlRow *modsLibraryControlsRow;
@property (nonatomic, strong) UIButton *modsLibraryAddButton;
@property (nonatomic, strong) UIButton *modsLibrarySortButton;
@property (nonatomic, strong) UIButton *modsLibraryViewButton;
@property (nonatomic, assign) NSInteger modsLibrarySortMode;
@property (nonatomic, assign) BOOL modsLibrarySortDescending;
@property (nonatomic, assign) BOOL modsLibraryIconsMode;
@property (nonatomic, strong) UICollectionView *modsLibraryIconsCollectionView;
@property (nonatomic, strong) id modsLibraryIconsSource;
@property (nonatomic, strong) NSLayoutConstraint *assetExplorerStatusTrailingToControls;
@property (nonatomic, strong) NSLayoutConstraint *assetExplorerStatusTrailingToModsRow;

@property (nonatomic, weak) UIDocumentPickerViewController *libraryImportPicker;
@property (nonatomic, copy) NSString *libraryImportTargetFolder;

@property (nonatomic, weak) UIDocumentPickerViewController *patchLCPicker;
@property (nonatomic, weak) UIDocumentPickerViewController *logoImportPicker;
@property (nonatomic, weak) UIDocumentPickerViewController *createLogosPicker;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTimer *> *doctorPollTimers;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorUploadProgressLastUpdate;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorProcessProgressLastPercent;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorDownloadProgressLastUpdate;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *doctorDownloadProgressPersistLastUpdate;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ModAssetLibraryEntry *> *doctorDownloadLiveEntryCache;

@property (nonatomic, strong) NSMutableSet<NSString *> *doctorDownloadInFlightPaths;

@property (nonatomic, weak) UIDocumentPickerViewController *doctorInstallTargetPicker;
@property (nonatomic, copy) NSURL *doctorInstallPendingDoctoredURL;
@property (nonatomic, copy) NSString *doctorInstallPendingEntryPath;
@property (nonatomic, copy) NSString *doctorInstallPendingFolderName;

@property (nonatomic, assign) BOOL doctorStateRecoveredThisLaunch;

@property (nonatomic, weak) UIButton *holdConfirmActiveButton;
@property (nonatomic, assign) NSTimeInterval holdConfirmStartTime;
@property (nonatomic, assign) BOOL holdConfirmTriggered;
@property (nonatomic, strong) CADisplayLink *holdConfirmDisplayLink;

@property (nonatomic, assign) CGRect zs_lastKeyboardFrame;

@property (nonatomic, strong) UIView *zsFloatingFieldBackdrop;
@property (nonatomic, strong) UIView *zsFloatingFieldContainer;
@property (nonatomic, strong) UITextField *zsFloatingField;
@property (nonatomic, weak) NSLayoutConstraint *zsFloatingFieldBottomConstraint;
@property (nonatomic, copy) void (^zsFloatingFieldCompletion)(NSString * _Nullable trimmedText);
@property (nonatomic, strong) UIView *zsFloatingFieldButtonRow;
@property (nonatomic, strong) UILabel *zsFloatingFieldHintLabel;
@property (nonatomic, copy) void (^zsFloatingFieldResetHandler)(void);

@property (nonatomic, strong) UIButton *syslogButton;
@property (nonatomic, assign) BOOL syslogDebugModeEnabled;

@property (nonatomic, assign) BOOL keepAliveEnabled;
@property (nonatomic, strong) CLLocationManager *keepAliveLocationManager;

@property (nonatomic, strong) UIView *syslogFullScreenOverlay;
@property (nonatomic, strong) UITextField *syslogSearchField;
@property (nonatomic, strong) UIButton *syslogExportButton;
@property (nonatomic, strong) UIButton *syslogChannelToggleButton;
@property (nonatomic, strong) UILabel *syslogInfoLabel;
@property (nonatomic, strong) NSTimer *syslogInfoRefreshTimer;
@property (nonatomic, strong) UIScrollView *syslogFullScreenScrollView;
@property (nonatomic, strong) NSLayoutConstraint *syslogCloseButtonLeadingConstraint;
@property (nonatomic, strong) UITableView *syslogTableView;
@property (nonatomic, strong) ZSSyslogTableController *syslogTableController;
@property (nonatomic, strong) UILabel *syslogEmptyLabel;
@property (nonatomic, assign) BOOL syslogRenderScheduled;
@property (nonatomic, assign) BOOL syslogRenderDeferred;
@property (nonatomic, assign) BOOL syslogFullScreenOpen;
@property (nonatomic, strong) UIView *syslogCopyToastView;
@property (nonatomic, strong) UIVisualEffectView *syslogCommandDropdown;
@property (nonatomic, strong) UIButton *syslogSlashButton;
@property (nonatomic, assign) BOOL syslogCommandBrowseActive;
@property (nonatomic, strong) UIStackView *syslogCommandStack;

@property (nonatomic, strong) ZSCapsuleSlider *normalFpsSlider;
@property (nonatomic, strong) UILabel *normalFpsValueLabel;
@property (nonatomic, strong) ZSCapsuleSlider *combatFpsSlider;
@property (nonatomic, strong) UILabel *combatFpsValueLabel;
@property (nonatomic, weak) UISwitch *expAdaptivePerformanceToggle;

@property (nonatomic, strong) UILabel *updateStatusLabel;
@property (nonatomic, strong) UIView *updateStatusDot;
@property (nonatomic, assign) ZSUpdateCheckMode updateCheckMode;
@property (nonatomic, assign) BOOL updateAvailable;
@property (nonatomic, copy) NSString *updateLatestVersion;
@property (nonatomic, assign) BOOL updateOnDeviceInstallDisabled;

@property (nonatomic, copy) NSString *browseSelectedCategory;
@property (nonatomic, copy) NSDictionary *browseSelectedEntry;
@property (nonatomic, strong) UIButton *browseCategoryButton;
@property (nonatomic, strong) UIButton *browseClassButton;
@property (nonatomic, strong) UIStackView *browseFieldsContainer;

@property (nonatomic, strong) UIButton *memoryUsageAnalyzeButton;
@property (nonatomic, strong) NSTimer *memoryUsageRefreshTimer;
@property (nonatomic, assign) BOOL memoryFullScreenOpen;
@property (nonatomic, assign) BOOL assetExplorerFullScreenOpen;
@property (nonatomic, strong) UIView *assetExplorerFullScreenOverlay;
@property (nonatomic, assign) BOOL dumperFullScreenOpen;
@property (nonatomic, strong) UIView *dumperFullScreenOverlay;
@property (nonatomic, strong) NSMutableDictionary *dumperUI;
@property (nonatomic, strong) UIView *selectModeOverlay;
@property (nonatomic, strong) UIView *selectModeHeader;
@property (nonatomic, strong) UISegmentedControl *selectModeKindControl;
@property (nonatomic, strong) UISwitch *selectModeVisibleSwitch;
@property (nonatomic, strong) UIPanGestureRecognizer *selectModeDragPan;
@property (nonatomic, strong) NSLayoutConstraint *selectModePanelLeading;
@property (nonatomic, strong) NSLayoutConstraint *selectModePanelTop;
@property (nonatomic, assign) BOOL selectModeMeshMode;
@property (nonatomic, assign) NSInteger selectModeCorner;
@property (nonatomic, assign) BOOL selectModeIncludeInvisible;
@property (nonatomic, strong) UIView *selectModePanel;
@property (nonatomic, strong) UITableView *selectModeTable;
@property (nonatomic, strong) ZSSelectModeList *selectModeList;
@property (nonatomic, strong) UIView *selectModeHighlight;
@property (nonatomic, strong) NSLayoutConstraint *selectModeTableHeight;
@property (nonatomic, copy) NSDictionary *selectModeSelection;
@property (nonatomic, assign) CGPoint selectModeLastPoint;
@property (nonatomic, assign) NSUInteger selectModeLookupToken;
@property (nonatomic, strong) UITableView *assetExplorerTableView;
@property (nonatomic, strong) UICollectionView *assetExplorerThumbCollectionView;
@property (nonatomic, strong) ZSAssetThumbGridSource *assetExplorerThumbSource;
@property (nonatomic, strong) UIButton *assetExplorerViewModeButton;
@property (nonatomic, assign) BOOL assetExplorerThumbnailMode;
@property (nonatomic, strong) UILabel *assetExplorerTitleLabel;
@property (nonatomic, strong) UILabel *assetExplorerStatusLabel;
@property (nonatomic, strong) UIButton *assetExplorerBackButton;
@property (nonatomic, strong) UIButton *assetExplorerCloseButton;
@property (nonatomic, assign) BOOL assetExplorerTextureOpen;
@property (nonatomic, strong) UIButton *assetExplorerTextureBackButton;
@property (nonatomic, strong) UIButton *assetExplorerTextureExportButton;
@property (nonatomic, strong) UIImageView *assetExplorerTextureImageView;
@property (nonatomic, strong) UIView *assetExplorerPreviewClipView;
@property (nonatomic, assign) CGFloat assetExplorerPreviewScale;
@property (nonatomic, assign) CGPoint assetExplorerPreviewOffset;
@property (nonatomic, assign) CGFloat assetExplorerPreviewGestureBaseScale;
@property (nonatomic, assign) CGPoint assetExplorerPreviewGestureBaseOffset;
@property (nonatomic, assign) CGPoint assetExplorerPreviewGestureFocal;
@property (nonatomic, assign) NSInteger assetExplorerPreviewPanTouchCount;
@property (nonatomic, strong) UITextView *assetExplorerTextView;
@property (nonatomic, strong) UILabel *assetExplorerTextureMessageLabel;
@property (nonatomic, strong) UILabel *assetExplorerTextureCaptionLabel;
@property (nonatomic, strong) UILabel *assetExplorerDebugLabel;
@property (nonatomic, strong) UIActivityIndicatorView *assetExplorerTextureSpinner;
@property (nonatomic, strong) NSArray<ZSAssetExplorerBundle *> *assetExplorerBundles;
@property (nonatomic, assign) NSUInteger assetExplorerNamesSession;
@property (nonatomic, strong) NSArray<ZSAssetExplorerAsset *> *assetExplorerAssets;
@property (nonatomic, strong) ZSAssetExplorerBundle *assetExplorerSelectedBundle;
@property (nonatomic, assign) NSUInteger assetExplorerGeneration;
@property (nonatomic, strong) UIView *assetExplorerBackdropView;
@property (nonatomic, strong) UIView *assetExplorerSearchContainer;
@property (nonatomic, strong) UITextField *assetExplorerSearchField;
@property (nonatomic, strong) ZSGlassControlRow *assetExplorerControlsStack;
@property (nonatomic, strong) UIButton *assetExplorerFilterButton;
@property (nonatomic, strong) UIButton *assetExplorerSortButton;
@property (nonatomic, strong) UIButton *assetExplorerShareButton;
@property (nonatomic, strong) NSArray<ZSAssetExplorerBundle *> *assetExplorerDisplayedBundles;
@property (nonatomic, assign) NSUInteger assetExplorerDisplayedModdedCount;
@property (nonatomic, assign) NSUInteger assetExplorerDisplayedBookmarkedCount;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *assetExplorerBookmarkedKeys;
@property (nonatomic, copy) NSString *assetExplorerRecentKey;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *assetExplorerRemarks;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *assetExplorerFMODBookmarkedKeys;
@property (nonatomic, copy) NSString *assetExplorerFMODRecentKey;
@property (nonatomic, assign) NSUInteger assetExplorerFMODDisplayedBookmarkedCount;
@property (nonatomic, assign) NSUInteger assetExplorerFMODDisplayedModdedCount;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *assetExplorerLocalizeBookmarkedKeys;
@property (nonatomic, copy) NSString *assetExplorerLocalizeRecentKey;
@property (nonatomic, assign) NSUInteger assetExplorerLocalizeDisplayedBookmarkedCount;
@property (nonatomic, assign) NSUInteger assetExplorerLocalizeDisplayedModdedCount;
@property (nonatomic, strong) NSSet<NSString *> *assetExplorerLocalizeModdedPaths;
@property (nonatomic, copy) NSString *assetExplorerListAnchorKey;
@property (nonatomic, assign) CGFloat assetExplorerListAnchorOffset;
@property (nonatomic, assign) CGFloat assetExplorerListSavedOffsetY;
@property (nonatomic, copy) NSString *assetExplorerListSavedQuery;
@property (nonatomic, assign) BOOL assetExplorerListRestorePending;
@property (nonatomic, strong) NSArray<ZSAssetExplorerAsset *> *assetExplorerDisplayedAssets;
@property (nonatomic, copy) NSString *assetExplorerFilterKind;
@property (nonatomic, copy) NSString *assetExplorerSortKind;
@property (nonatomic, assign) BOOL assetExplorerBundleSortDescending;
@property (nonatomic, assign) BOOL assetExplorerSortBySize;
@property (nonatomic, assign) BOOL assetExplorerSizeAscending;
@property (nonatomic, assign) BOOL assetExplorerBundleSortBySize;
@property (nonatomic, assign) BOOL assetExplorerBundleSizeAscending;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *assetExplorerBundleSizes;
@property (nonatomic, assign) BOOL assetExplorerBundleSortByDate;
@property (nonatomic, assign) BOOL assetExplorerBundleDateAscending;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *assetExplorerBundleDates;
@property (nonatomic, assign) BOOL assetExplorerBundleSortByCreation;
@property (nonatomic, assign) BOOL assetExplorerBundleCreationAscending;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *assetExplorerBundleCreations;
@property (nonatomic, strong) NSArray<ZSAssetExplorerAsset *> *assetExplorerTextureAssets;
@property (nonatomic, assign) NSInteger assetExplorerTextureIndex;
@property (nonatomic, strong) UIStackView *assetExplorerTexturePagerStack;
@property (nonatomic, strong) UIButton *assetExplorerTexturePrevButton;
@property (nonatomic, strong) UIButton *assetExplorerTextureNextButton;
@property (nonatomic, strong) UILabel *assetExplorerTexturePositionLabel;
@property (nonatomic, strong) ZSAssetExplorerVisual *assetExplorerVisual;
@property (nonatomic, strong) dispatch_source_t assetExplorerLiveTimer;
@property (nonatomic, assign) NSUInteger assetExplorerLiveToken;
@property (nonatomic, assign) BOOL assetExplorerLivePaused;
@property (nonatomic, assign) NSTimeInterval assetExplorerLiveElapsed;
@property (nonatomic, strong) ZSModeSlider *assetExplorerModeControl;
@property (nonatomic, assign) BOOL assetExplorerDataMode;
@property (nonatomic, strong) NSData *assetExplorerDataJSON;
@property (nonatomic, assign) NSUInteger assetExplorerDataToken;
@property (nonatomic, assign) NSInteger assetExplorerPageIndex;
@property (nonatomic, strong) UIStackView *assetExplorerPageStack;
@property (nonatomic, strong) UIButton *assetExplorerPagePrevButton;
@property (nonatomic, strong) UIButton *assetExplorerPageNextButton;
@property (nonatomic, strong) UILabel *assetExplorerPageLabel;
@property (nonatomic, copy) NSString *assetExplorerStatusMessage;
@property (nonatomic, strong) UIView *assetExplorerHubView;
@property (nonatomic, strong) UITableView *assetExplorerFMODTableView;
@property (nonatomic, assign) BOOL assetExplorerHubVisible;
@property (nonatomic, assign) BOOL assetExplorerFMODMode;
@property (nonatomic, assign) NSUInteger assetExplorerFMODGeneration;
@property (nonatomic, assign) NSInteger assetExplorerFMODSortMode;
@property (nonatomic, strong) NSArray<ZSFMODBankFile *> *assetExplorerFMODBankFiles;
@property (nonatomic, strong) NSArray<ZSFMODBankFile *> *assetExplorerFMODDisplayedBanks;
@property (nonatomic, strong) ZSFMODBankFile *assetExplorerFMODBankFile;
@property (nonatomic, strong) ZSFMODBank *assetExplorerFMODBank;
@property (nonatomic, strong) NSArray<ZSFMODStream *> *assetExplorerFMODDisplayedStreams;
@property (nonatomic, strong) ZSFMODStream *assetExplorerFMODStream;
@property (nonatomic, strong) NSSet<NSString *> *assetExplorerFMODModdedNames;
@property (nonatomic, assign) BOOL assetExplorerLocalizeMode;
@property (nonatomic, assign) NSUInteger assetExplorerLocalizeGeneration;
@property (nonatomic, assign) NSInteger assetExplorerLocalizeSortMode;
@property (nonatomic, assign) BOOL assetExplorerLocalizeRawMode;
@property (nonatomic, copy) NSString *assetExplorerLocalizeRoot;
@property (nonatomic, copy) NSString *assetExplorerLocalizeDirectory;
@property (nonatomic, copy) NSString *assetExplorerLocalizeFilePath;
@property (nonatomic, copy) NSString *assetExplorerLocalizeRawText;
@property (nonatomic, strong) NSArray<NSDictionary *> *assetExplorerLocalizeEntries;
@property (nonatomic, strong) NSArray<NSDictionary *> *assetExplorerLocalizeDisplayedEntries;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *assetExplorerLocalizeOffsets;
@property (nonatomic, strong) NSNumber *assetExplorerLocalizePendingOffset;
@property (nonatomic, copy) NSString *assetExplorerLocalizePendingOpenFilePath;
@property (nonatomic, strong) NSData *assetExplorerLocalizeFileData;
@property (nonatomic, strong) ZSLocJSONNode *assetExplorerLocalizeRootNode;
@property (nonatomic, strong) NSMutableArray<ZSLocJSONNode *> *assetExplorerLocalizeVisibleRows;
@property (nonatomic, strong) UITableView *assetExplorerLocalizeTableView;
@property (nonatomic, strong) UITableView *assetExplorerLocalizeJSONTableView;
@property (nonatomic, strong) UIView *memoryFullScreenOverlay;
@property (nonatomic, strong) UIScrollView *memoryFullScreenScrollView;
@property (nonatomic, strong) UIView *memoryFullScreenContentView;
@property (nonatomic, strong) UILabel *memoryFullScreenStatusLabel;
@property (nonatomic, strong) UIView *memoryRefreshPieView;
@property (nonatomic, strong) CAShapeLayer *memoryRefreshPieLayer;
@property (nonatomic, strong) NSLayoutConstraint *memoryCloseButtonLeadingConstraint;
@property (nonatomic, strong) UIView *memoryPopupScrim;
@property (nonatomic, strong) UIView *memoryPopupView;
@property (nonatomic, strong) NSMutableString *memoryNumpadText;
@property (nonatomic, assign) BOOL memoryNumpadFresh;
@property (nonatomic, assign) NSUInteger memoryNumpadPageCount;
@property (nonatomic, assign) NSUInteger memoryNumpadCurrentPage;
@property (nonatomic, strong) UILabel *memoryNumpadDisplayLabel;
@property (nonatomic, strong) UIButton *memoryExportButton;
@property (nonatomic, strong) UIPageControl *memoryPageControl;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *memoryLocalPages;
@property (nonatomic, strong) UIView *memoryInfoPanel;
@property (nonatomic, strong) UIView *memoryBigPieDisc;
@property (nonatomic, strong) CAShapeLayer *memoryBigPieLayer;
@property (nonatomic, strong) UILabel *memoryClockLabel;
@property (nonatomic, strong) UIView *memoryInvertClip;
@property (nonatomic, strong) CAShapeLayer *memoryInvertMaskLayer;
@property (nonatomic, strong) UILabel *memoryInvertClockLabel;
@property (nonatomic, strong) UILabel *memorySubtextLabel;
@property (nonatomic, strong) UILabel *memoryInvertSubtextLabel;
@property (nonatomic, strong) NSArray<UILabel *> *memoryInvertFeedLabels;
@property (nonatomic, strong) NSArray<UILabel *> *memoryFeedLabels;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *memoryFeed;
@property (nonatomic, strong) NSTimer *memoryClockTimer;
@property (nonatomic, assign) CFTimeInterval memoryPieBegin;
@property (nonatomic, assign) NSUInteger memoryCyclePhase;
@property (nonatomic, assign) NSUInteger memoryCycleUnitsDone;
@property (nonatomic, assign) NSUInteger memoryCycleUnitEstimate;
@property (nonatomic, assign) CFTimeInterval memoryCycleStart;
@property (nonatomic, assign) NSUInteger memoryCycleCount;
@property (nonatomic, assign) NSUInteger memoryCycleOverruns;
@property (nonatomic, assign) CFTimeInterval memoryCycleWorkAccum;
@property (nonatomic, assign) CFTimeInterval memoryCycleMaxStep;
@property (nonatomic, assign) CFTimeInterval memoryLastWork;
@property (nonatomic, assign) CFTimeInterval memoryLastPeak;
@property (nonatomic, strong) NSArray<UILabel *> *memoryStatLabels;
@property (nonatomic, assign) NSUInteger memoryBuildIndex;
@property (nonatomic, assign) CGFloat memoryBuildHeight;
@property (nonatomic, assign) CGFloat memoryBuildPanelWidth;
@property (nonatomic, assign) BOOL memoryBuildSkipped;
@property (nonatomic, assign) NSUInteger memoryBuildGroupColumnCount;
@property (nonatomic, strong) NSArray<ZSMemoryUsageGroup *> *memoryPendingGroups;
@property (nonatomic, strong) NSMutableArray<UIView *> *memoryPendingColumns;
@property (nonatomic, assign) BOOL memoryHasSnapshot;
@property (nonatomic, assign) ZSMemorySystemStats memorySnapshotStats;
@property (nonatomic, strong) NSArray<ZSMemoryColumnRow *> *memorySnapshotSystemRows;
@property (nonatomic, strong) NSArray<ZSMemoryUsageGroup *> *memorySnapshotGroups;
@property (nonatomic, strong) NSDate *memorySnapshotDate;

@property (nonatomic, strong) NSMutableArray<NSString *> *pinnedActionKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *pinnedTabElements;
@property (nonatomic, assign) CGFloat pinClusterOffsetY;
@property (nonatomic, assign) BOOL pinRecenterPending;
@property (nonatomic, assign) BOOL panelFullScreenLayoutActive;
@property (nonatomic, assign) BOOL extendedCoverMode;
@property (nonatomic, assign) BOOL pinchDismissInFlight;
@property (nonatomic, assign) BOOL extendedCoverEntering;
@property (nonatomic, assign) NSUInteger pinRecenterToken;
@property (nonatomic, strong) UIView *pinMenuScrim;
@property (nonatomic, strong) UIView *pinMenuContent;
@property (nonatomic, assign) CGFloat pinMenuExtraWidth;
@property (nonatomic, assign) BOOL pinMenuOpen;
@property (nonatomic, assign) BOOL pinMenuTransitioning;

+ (instancetype)shared;
- (void)installIfNeeded;
- (void)zs_bootstrapSyslogCaptureIfNeeded;

- (void)zs_handleOpenPanelGesture:(UISwipeGestureRecognizer *)gesture;
- (void)zs_flashTutorialGestureWarning;
- (void)zs_hideTutorialGestureWarning;
- (void)zs_presentTutorialIfNeeded;
- (void)zs_tutorialUnlock;
- (void)zs_tutorialDiscordTapped;
- (void)zs_tutorialGitHubTapped;
- (void)zs_tutorialOKTapped;
- (void)zs_layoutTutorialForWindow:(UIView *)unityView;
- (void)zs_layoutCrashReportForWindow:(UIView *)unityView;
- (BOOL)zs_presentCrashReportIfNeeded;
- (void)zs_crashSaveTapped:(UIButton *)sender;
- (void)zs_crashOKTapped;
- (void)openPanel;
- (void)closePanel;
- (void)closePanelAnimated:(BOOL)animated;
- (void)teardownPanelState;
- (void)destroyPanelHierarchy;
- (void)zs_closeButtonTapped;
- (void)panelSwiped:(UIPanGestureRecognizer *)gesture;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer;
- (void)buildPanel:(UIView *)unityView;
- (BOOL)zs_hasPendingExperimentalSectionBuilders;
- (void)zs_runNextPendingSectionBuilder;
- (void)zs_fillVisiblePanelSectionsWithHeadroom;
- (void)zs_applyExperimentalAvailabilityTint;
- (void)zs_scheduleSave;
- (void)zs_writeSettingsNow;
@end

UIView *zs_ae_section_header(NSString *title);
UIImage *zs_section_collapse_chevron_image(BOOL collapsed);

#import "Helpers.h"
#import "Controls.h"
#import "Components.h"
#import "Chrome.h"
#import "UIPanel.h"
#import "UISettings.h"
#import "UIMods.h"
#import "UIDiagnostics.h"
#import "UIAssetExplorer.h"
#import "UIDumper.h"
