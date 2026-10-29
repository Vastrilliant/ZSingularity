#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    const char *category;
    const char *assembly;
    const char *namespaze;
    const char *kind;
    const char *name;
} ZSDumpTypeInfo;

FOUNDATION_EXPORT const ZSDumpTypeInfo *zs_dump_type_registry(void);
FOUNDATION_EXPORT NSUInteger zs_dump_type_count(void);
FOUNDATION_EXPORT NSUInteger zs_dump_type_count_for_category(NSInteger categoryIndex);
FOUNDATION_EXPORT BOOL zs_dump_registry_contains(NSString *assembly, NSString *namespaze, NSString *name);
FOUNDATION_EXPORT NSDictionary *zs_dump_registry_summary(void);

NS_ASSUME_NONNULL_END
