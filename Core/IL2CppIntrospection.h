
#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@interface IL2CppBridge : NSObject

+ (BOOL)resolveSymbols;

+ (void *)classNamed:(const char *)className
          inNamespace:(const char *)namespaze
     assemblyContains:(const char *)assemblySubstring;

+ (const void *)methodOnClass:(void *)klass
                          name:(const char *)methodName
                      argCount:(int)argCount;

+ (void *)invokeMethod:(const void *)method
             onInstance:(void *)obj
                   args:(void **)args
          outException:(void **)outException;

+ (int32_t)fieldOffsetOnClass:(void *)klass name:(const char *)fieldName;
+ (BOOL)copyStaticFieldOnClass:(void *)klass name:(const char *)fieldName toBuffer:(void *)buffer;

+ (void *)fieldNamed:(const char *)fieldName onClass:(void *)klass;
+ (void *)nextFieldOnClass:(void *)klass iterator:(void **)iter;
+ (const char *)nameOfField:(void *)field;
+ (uint32_t)flagsOfField:(void *)field;
+ (int32_t)typeEnumOfField:(void *)field;
+ (BOOL)copyStaticFieldValue:(void *)field toBuffer:(void *)buffer;
+ (void)setStaticFieldValue:(void *)field fromBuffer:(void *)buffer;
+ (BOOL)copyInstanceFieldValue:(void *)field onInstance:(void *)obj toBuffer:(void *)buffer;
+ (void)setInstanceFieldValue:(void *)field onInstance:(void *)obj fromBuffer:(void *)buffer;

+ (void *)findFirstLiveInstanceOfClass:(void *)klass;

+ (void *)classOfInstance:(void *)obj;

+ (void *)reflectionTypeForClass:(void *)klass;

+ (NSString *)nsStringFromIl2CppString:(void *)il2cppString;

+ (void *)il2CppStringFromNSString:(NSString *)string;

+ (const void *)paramTypeForMethod:(const void *)method index:(uint32_t)index;

+ (void *)classFromType:(const void *)type;

+ (void *)newObjectForClass:(void *)klass;

+ (void *)nativeFunctionPointerForMethod:(const void *)method;

@end

typedef NS_ENUM(NSInteger, ZSFieldKind) {
    ZSFieldKindBool,
    ZSFieldKindInteger,
    ZSFieldKindFloat,
};

@interface ZSLiveField : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) ZSFieldKind kind;
@property (nonatomic, assign) double currentValue;
@property (nonatomic, assign) int32_t typeEnum;
@end

FOUNDATION_EXPORT NSArray<NSString *> *zs_field_browser_categories(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *zs_field_browser_entries_for_category(NSString *category);
FOUNDATION_EXPORT NSUInteger zs_field_browser_count_for_category(NSString *category);

typedef NS_ENUM(NSInteger, ZSFieldBrowserResolution) {
    ZSFieldBrowserResolutionOk,
    ZSFieldBrowserResolutionClassNotFound,
    ZSFieldBrowserResolutionNoEditableFields,
};

FOUNDATION_EXPORT NSArray<ZSLiveField *> *zs_field_browser_fields_for_entry(NSDictionary *entry, ZSFieldBrowserResolution *outResolution);

FOUNDATION_EXPORT double zs_field_browser_get_value(NSDictionary *entry, NSString *fieldName, int32_t typeEnum);
FOUNDATION_EXPORT void zs_field_browser_set_value(NSDictionary *entry, NSString *fieldName, int32_t typeEnum, double value);

NS_ASSUME_NONNULL_END
