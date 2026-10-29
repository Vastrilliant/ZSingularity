#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    const char *name;
    void *replacement;
} ZSRebindEntry;

void zs_rebind_install(const ZSRebindEntry *entries, size_t count);
size_t zs_rebind_applied_count(void);

NS_ASSUME_NONNULL_END
