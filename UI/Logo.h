#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const kZSLogoDefaultName;
extern NSNotificationName const ZSLogoDidChangeNotification;

typedef NS_ENUM(NSInteger, ZSLogoTextCase) {
    ZSLogoTextCaseNone,
    ZSLogoTextCaseUpper,
    ZSLogoTextCaseLower,
};

@interface ZSLogoFontStyle : NSObject
@property (nonatomic, assign) CGFloat sizeScale;
@property (nonatomic, assign) CGFloat emphasisScale;
@property (nonatomic, assign) CGFloat spacing;
@property (nonatomic, assign) CGFloat baselineOffset;
@property (nonatomic, assign) ZSLogoTextCase textCase;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, assign) CGFloat shadowBlur;
@property (nonatomic, assign) CGSize shadowOffset;
@property (nonatomic, strong) UIColor *shadowColor;
@property (nonatomic, assign) CGFloat shadowOpacity;
@property (nonatomic, assign) CGFloat strokeWidth;
@property (nonatomic, strong) UIColor *strokeColor;
@end

@interface ZSLogoLayerStyle : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) CGFloat speed;
@property (nonatomic, assign) CGFloat opacity;
@property (nonatomic, assign) CGFloat scale;
@property (nonatomic, assign) CGSize offset;
@property (nonatomic, assign) CGFloat rotation;
@property (nonatomic, copy) NSString *blendMode;
@property (nonatomic, copy, nullable) NSString *compositingFilter;
@property (nonatomic, assign) BOOL aboveText;
@property (nonatomic, assign) BOOL maskToText;
@end

@interface ZSLogoStyle : NSObject
@property (nonatomic, strong) ZSLogoFontStyle *font;
@property (nonatomic, strong) ZSLogoLayerStyle *fill;
@property (nonatomic, strong) ZSLogoLayerStyle *vfx;
@end

@interface ZSLogoPack : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *fontPath;
@property (nonatomic, copy, readonly, nullable) NSString *fillPath;
@property (nonatomic, copy, readonly, nullable) NSString *vfxPath;
@property (nonatomic, copy, readonly, nullable) NSString *stylePath;
@property (nonatomic, copy, readonly, nullable) NSString *postScriptName;
@property (nonatomic, strong, readonly) ZSLogoStyle *style;
@end

typedef void (^ZSLogoSelectCompletion)(BOOL success);
typedef void (^ZSLogoNamesCompletion)(NSArray<NSString *> *names);
typedef void (^ZSLogoImportCompletion)(NSArray<NSString *> *importedNames, NSString * _Nullable errorMessage);

NSArray<NSString *> *zs_logo_cached_names(void);
void zs_logo_refresh_names(ZSLogoNamesCompletion completion);

BOOL zs_logo_is_local(NSString *name);
void zs_logo_import_zip(NSURL *zipURL, ZSLogoImportCompletion completion);

NSString *zs_logo_selected_name(void);
void zs_logo_select(NSString *name, ZSLogoSelectCompletion _Nullable completion);

ZSLogoPack * _Nullable zs_logo_selected_pack(void);
ZSLogoStyle * _Nullable zs_logo_selected_style(void);
UIFont * _Nullable zs_logo_selected_font(CGFloat size);

NS_ASSUME_NONNULL_END
