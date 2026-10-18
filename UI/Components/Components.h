#pragma once

#import "UIInternal.h"

@interface ZSMemoryColumnRow : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, strong) UIColor *color;
@end

@interface ZSFieldBrowserPickerViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray *allItems;
@property (nonatomic, copy) NSArray *filteredItems;
@property (nonatomic, copy) NSString *(^titleForItem)(id item);
@property (nonatomic, copy) void (^onSelect)(id item);
@property (nonatomic, strong) UISearchController *searchController;
- (instancetype)initWithTitle:(NSString *)title items:(NSArray *)items titleForItem:(NSString *(^)(id item))titleForItem;
@end

@interface ZSAssetPreviewClipView : UIView
@property (nonatomic, weak) UIView *contentView;
@end

@interface ZSAssetCheckerboardView : UIView
@end

@interface ZSLocJSONNode : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) ZSLocJSONKind kind;
@property (nonatomic, assign) NSInteger depth;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, strong) NSMutableArray<ZSLocJSONNode *> *children;
- (BOOL)isContainer;
@end

@interface ZSLocJSONCell : UITableViewCell
@property (nonatomic, strong) UILabel *line;
@property (nonatomic, strong) NSLayoutConstraint *leadingConstraint;
@end

@interface ZSAssetThumbCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, copy) NSString *representedKey;
@end

@interface ZSAssetThumbGridSource : NSObject <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, copy) NSArray<ZSAssetExplorerAsset *> *assets;
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, copy) void (^onSelect)(ZSAssetExplorerAsset *asset);
@property (nonatomic, weak) UICollectionView *collectionView;
- (void)reset;
@end

@interface ZSSyslogTableController : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSString *> *lines;
@property (nonatomic, assign) CGFloat leftInset;
@property (nonatomic, assign) CGFloat rightInset;
@property (nonatomic, assign) BOOL atBottom;
@property (nonatomic, weak) id longPressTarget;
@property (nonatomic, copy) void (^reachedBottom)(void);
@end

@interface ZSDocsScrollView : UIScrollView
@property (nonatomic, weak) NSLayoutConstraint *minContentHeightConstraint;
@property (nonatomic, assign) CGFloat minContentHeightInset;
@end

extern __weak UIButton *g_zsLowResTranscodeButton;
extern NSTimer *g_zsLowResTimer;
extern __weak UIView *g_zsLowResProgressView;
extern __weak UILabel *g_zsLowResBundleCountLabel;
extern __weak UILabel *g_zsLowResETALabel;
extern __weak UILabel *g_zsLowResPercentLabel;
extern __weak UILabel *g_zsLowResTexturesLabel;
extern __weak UIView *g_zsLowResTrack;
extern __weak UIView *g_zsLowResFill;
extern NSLayoutConstraint *g_zsLowResFillWidth;
extern BOOL g_zsLowResUserCancelled;
extern __weak UIStackView *g_zsLowResInfoView;
extern __weak UILabel *g_zsLowResInfoLabel;
extern __weak UIButton *g_zsLowResInfoButton;
extern __weak UIView *g_zsLowResInfoButtonSeparator;
extern NSInteger g_zsLowResStage;
extern NSUInteger g_zsLowResGeneration;
extern BOOL g_zsLowResReopenPending;
extern BOOL g_zsLowResSwapBusy;
extern __weak UIButton *g_zsLowResCancelButton;
extern __weak UIView *g_zsLowResInfoWrapper;
extern __weak UIView *g_zsLowResProgressWrapper;
extern __weak UIView *g_zsLowResSwapWrapper;
extern __weak UIView *g_zsLowResSwapLeftSlot;
extern __weak UIView *g_zsLowResSwapRightSlot;
extern __weak UIImageView *g_zsLowResSwapLeftIcon;
extern __weak UIImageView *g_zsLowResSwapRightIcon;
extern __weak UIButton *g_zsLowResSwapButton;
extern NSString *g_zsLowResSharedPath;
extern BOOL g_zsLowResSwapEligible;
extern BOOL g_zsLowResDiskExists;
extern BOOL g_zsLowResBackupExists;
extern BOOL g_zsLowResDiskTranscoded;
extern BOOL g_zsLowResBackupTranscoded;
extern BOOL g_zsLowResDeleteOpen;
extern BOOL g_zsLowResDeleteTargetIsDisk;
extern __weak UIView *g_zsLowResDeleteWrapper;
extern __weak UILabel *g_zsLowResDeleteLabel;
extern __weak UIView *g_zsLowResTranscodeWrapper;
extern NSInteger g_zsLowResBlockIndex;
extern BOOL g_zsLowResCodecExpanded;
extern __weak UIView *g_zsLowResLabelHost;
extern __weak UIView *g_zsLowResConfigView;
extern __weak UIView *g_zsLowResCodecContainer;
extern __weak UIControl *g_zsLowResCodecRow;
extern __weak UIView *g_zsLowResCodecOptions;
extern NSLayoutConstraint *g_zsLowResCodecHeight;
extern NSString * const kZSStoredBundlesFolderName;
extern NSString * const kZSStoredBundlesFolderSubtext;

ZSRow *zs_make_slider_row(NSString *title, float minV, float maxV, float val, NSString *(^format)(float));
ZSRow *zs_make_mode_slider_row(NSString *title, NSArray<NSString *> *labels, NSInteger selectedIndex, NSInteger defaultIndex);
ZSRow *zs_make_wheel_row(NSString *title, NSArray<NSString *> *labels, NSInteger selectedIndex, NSInteger defaultIndex);
UILabel *zs_make_hint_label(NSString *text);
ZSRow *zs_make_switch_row(NSString *title, BOOL val);
void zs_add_unavailable_subtext(ZSRow *row, NSString *text);
UIButton *zs_make_grouped_action_button(NSString *title, UIColor *tint);
UIView *zs_make_grouped_action_pair_row(UIButton *leftButton, UIButton *rightButton);
UIView *zs_make_grouped_action_card(NSArray<UIView *> *rows);
UIView *zs_make_lowres_progress_view(id target, SEL cancelAction);
NSArray<NSNumber *> *zs_lowres_block_options(void);
UIView *zs_make_reveal_wrapper(UIView *content, BOOL expanded);
void zs_reveal_set_expanded(UIView *wrapper, BOOL expanded);
NSString *zs_lowres_swap_shared_folders(void);
TexCompFolderState zs_lowres_folder_state(NSString *shared);
NSString *zs_lowres_exchange_shared_folders(NSString *shared);
UIColor *zs_lowres_original_folder_color(void);
UIView *zs_make_lowres_swap_view(id target, SEL swapAction);
UIView *zs_make_lowres_delete_view(id target, SEL confirmAction, SEL cancelAction);
NSString *zs_lowres_delete_folder(NSString *shared, BOOL deleteDisk);
NSString *zs_lowres_block_title(NSUInteger block, BOOL verbose);
UIStackView *zs_make_lowres_info_view(id target, SEL action, SEL codecAction);
UIControl *zs_make_disclosure_row(NSString *title, NSString *value, id target, SEL action);
void zs_disclosure_row_set_value(UIControl *row, NSString *value);
void zs_disclosure_row_install_menu(UIControl *row, NSArray<NSString *> *titles, NSInteger selectedIndex, void (^onSelect)(NSInteger index));
UIView *zs_make_expanding_dropdown_row(NSString *title, NSArray<NSString *> *optionTitles, NSArray<NSString *> * _Nullable valueTitles, NSArray * _Nullable optionSubtexts, NSInteger selectedIndex, void (^ _Nullable animator)(dispatch_block_t changes), void (^ _Nullable onSelect)(NSInteger index));
UIStackView *zs_make_card_options_stack(NSArray<NSString *> *titles, NSInteger selectedIndex, id target, SEL action);
NSArray<NSArray<NSString *> *> *zs_memory_page_titles(BOOL fullScreen);
CGFloat zs_memory_column_width(NSString *title, CGFloat windowWidth, BOOL fullScreen);
CGFloat zs_memory_clamp(CGFloat value, CGFloat low, CGFloat high);
NSAttributedString *zs_memory_fetch_subtext(UIColor *color);
UILabel *zs_memory_make_label(NSString *text, UIFont *font, UIColor *color, NSTextAlignment alignment);
UIView *zs_build_memory_column(NSString *title, NSString *subtitle, NSArray<ZSMemoryColumnRow *> *rows, NSArray<NSNumber *> *fractions, BOOL compactStats, CGFloat headerTrailingReserve, CGFloat fixedColumnWidth, CGFloat height, BOOL localPaging, NSUInteger *pageInOut, NSUInteger *pageCountOut);
NSString *zs_memory_megabytes_string(int64_t bytes);
UIVisualEffectView *zs_memory_make_popup_surface(CGSize size);
CGRect zs_memory_popup_frame(UIView *overlay, UIView *source, CGSize desired);
UIView *zs_build_memory_group_column(ZSMemoryUsageGroup *group, CGFloat height, CGFloat windowWidth, BOOL fullScreen, NSUInteger localPage, void (^onLocalPageChange)(NSUInteger page), void (^onPageChange)(NSInteger delta), void (^onFilterTap)(UIView *source), void (^onPageTap)(UIView *source));
NSArray<ZSMemoryColumnRow *> *zs_memory_system_stat_rows(ZSMemorySystemStats stats);
NSDictionary *zs_memchart_export_document(ZSMemorySystemStats stats, NSArray<ZSMemoryColumnRow *> *systemRows, NSArray<ZSMemoryUsageGroup *> *groups, NSDate *date);
UIVisualEffectView *zs_wrap_field_in_native_glass(UITextField *field, CGFloat cornerRadius);
UIImage *zs_make_dropdown_chevron_image(void);
UIImage *zs_make_release_history_arrow_image(BOOL pointingLeft);
ZSRow *zs_make_full_width_glass_field_row(UITextField *field);
UIView *zs_make_blacklist_entry_row(NSString *term, id target, SEL removeAction);
BOOL zs_mods_folder_is_or_within_stored_bundles(NSString *folderName);
UIView *zs_make_mods_folder_row(NSString *folderName, NSString *displayName, NSString *remark, BOOL expanded, id target, SEL tapAction, SEL optionsAction, NSInteger indentLevel);
NSArray<NSDictionary<NSString *, id> *> *zs_mods_file_options(ModAssetLibraryEntry *entry);
NSArray<NSDictionary<NSString *, id> *> *zs_mods_stored_bundle_file_options(void);
UIButton *zs_make_mods_options_row_button(NSDictionary<NSString *, id> *option, NSInteger tag, id target, SEL action);
NSArray<NSDictionary<NSString *, id> *> *zs_mods_options_for_folder(NSString *folderName);
UIView *zs_make_mods_entry_row(ModAssetLibraryEntry *entry, id target, SEL tapAction, SEL dispatchAction, SEL downloadAction, SEL retryAction, SEL optionsAction, BOOL showActions, BOOL downloadInFlight, BOOL isStoredBundlesFolder, NSInteger indentLevel);
NSString *zs_doctor_status_text_for_entry(ModAssetLibraryEntry *entry, BOOL downloadInFlight, BOOL isStoredBundlesFolder);
UIView *zs_make_mods_entry_info_panel(ModAssetLibraryEntry *entry, BOOL downloadInFlight, BOOL isStoredBundlesFolder);
UILabel *zs_make_section_header(NSString *text);
void zs_apply_update_label_style(UILabel *label, NSString *text, BOOL interactable);
UIImageView *zs_make_signature_overlay(void);
NSAttributedString *zs_make_title_string(CGFloat restSize, CGFloat emphasizedSize);
UIView *zs_make_title_block(void);
NSData *zs_loc_json_strip_bom(NSData *data);
ZSLocJSONNode *zs_loc_json_parse(NSData *data);
void zs_loc_json_flatten(NSArray<ZSLocJSONNode *> *nodes, NSMutableArray<ZSLocJSONNode *> *out);
NSAttributedString *zs_loc_json_attributed(ZSLocJSONNode *node);
void zs_loc_json_write(ZSLocJSONNode *node, NSInteger indent, NSMutableString *out);
NSString *zs_asset_explorer_bundle_key(ZSAssetExplorerBundle *bundle);
NSMutableOrderedSet<NSString *> *zs_ae_string_set(id stored);
void zs_ae_set_detail(UILabel *label, NSString *detail, BOOL recent);
NSArray<NSNumber *> *zs_ae_section_kinds(NSUInteger bookmarked, NSUInteger modded, NSUInteger total);
NSUInteger zs_ae_section_count(NSInteger kind, NSUInteger bookmarked, NSUInteger modded, NSUInteger total);
NSInteger zs_ae_flat_index(NSIndexPath *indexPath, NSUInteger bookmarked, NSUInteger modded, NSUInteger total);
NSString *zs_ae_section_title(NSInteger kind);
BOOL zs_mod_library_has_zeroable_assets(void);
