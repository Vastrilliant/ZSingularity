#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const kZSLogoDefaultName;
extern NSNotificationName const ZSLogoDidChangeNotification;

@interface ZSLogoPack : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *fontPath;
@property (nonatomic, copy, readonly, nullable) NSString *fillPath;
@property (nonatomic, copy, readonly, nullable) NSString *vfxPath;
@property (nonatomic, copy, readonly, nullable) NSString *postScriptName;
@end

typedef void (^ZSLogoSelectCompletion)(BOOL success);
typedef void (^ZSLogoNamesCompletion)(NSArray<NSString *> *names);

NSArray<NSString *> *zs_logo_cached_names(void);
void zs_logo_refresh_names(ZSLogoNamesCompletion completion);

NSString *zs_logo_selected_name(void);
void zs_logo_select(NSString *name, ZSLogoSelectCompletion _Nullable completion);

ZSLogoPack * _Nullable zs_logo_selected_pack(void);
UIFont * _Nullable zs_logo_selected_font(CGFloat size);

NS_ASSUME_NONNULL_END
