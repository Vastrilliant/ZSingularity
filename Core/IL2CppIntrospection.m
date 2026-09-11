#import "IL2CppIntrospection.h"
#import "ZSDumpTypeRegistry.h"
#import "ZTweakLog.h"
#import <dlfcn.h>
#import <string.h>

#pragma mark - IL2CppBridge

typedef void *(*il2cpp_domain_get_fn)(void);
typedef void **(*il2cpp_domain_get_assemblies_fn)(const void *domain, size_t *size);
typedef const void *(*il2cpp_assembly_get_image_fn)(const void *assembly);
typedef const char *(*il2cpp_image_get_name_fn)(const void *image);
typedef void *(*il2cpp_class_from_name_fn)(const void *image, const char *namespaze, const char *name);
typedef const void *(*il2cpp_class_get_method_from_name_fn)(void *klass, const char *name, int argsCount);
typedef void *(*il2cpp_runtime_invoke_fn)(const void *method, void *obj, void **params, void **exc);
typedef void *(*il2cpp_class_get_field_from_name_fn)(void *klass, const char *name);
typedef int32_t (*il2cpp_field_get_offset_fn)(void *field);
typedef void (*il2cpp_field_static_get_value_fn)(const void *field, void *value);
typedef void *(*il2cpp_object_get_class_fn)(void *obj);
typedef const void *(*il2cpp_class_get_type_fn)(void *klass);
typedef void *(*il2cpp_type_get_object_fn)(const void *type);
typedef int32_t (*il2cpp_string_length_fn)(void *str);
typedef uint16_t *(*il2cpp_string_chars_fn)(void *str);
typedef const void *(*il2cpp_method_get_param_fn)(const void *method, uint32_t index);
typedef void *(*il2cpp_class_from_type_fn)(const void *type);
typedef void *(*il2cpp_object_new_fn)(void *klass);
typedef void *(*il2cpp_class_get_fields_fn)(void *klass, void **iter);
typedef void *(*il2cpp_class_get_field_from_name_public_fn)(void *klass, const char *name);
typedef const char *(*il2cpp_field_get_name_fn)(void *field);
typedef uint32_t (*il2cpp_field_get_flags_fn)(void *field);
typedef const void *(*il2cpp_field_get_type_fn)(void *field);
typedef int32_t (*il2cpp_type_get_type_fn)(const void *type);
typedef void (*il2cpp_field_get_value_fn)(void *obj, void *field, void *value);
typedef void (*il2cpp_field_set_value_fn)(void *obj, void *field, void *value);
typedef void (*il2cpp_field_static_set_value_fn)(void *field, void *value);
typedef void *(*il2cpp_string_new_fn)(const char *str);

static il2cpp_domain_get_fn p_domain_get;
static il2cpp_domain_get_assemblies_fn p_domain_get_assemblies;
static il2cpp_assembly_get_image_fn p_assembly_get_image;
static il2cpp_image_get_name_fn p_image_get_name;
static il2cpp_class_from_name_fn p_class_from_name;
static il2cpp_class_get_method_from_name_fn p_class_get_method_from_name;
static il2cpp_runtime_invoke_fn p_runtime_invoke;
static il2cpp_class_get_field_from_name_fn p_class_get_field_from_name;
static il2cpp_field_get_offset_fn p_field_get_offset;
static il2cpp_field_static_get_value_fn p_field_static_get_value;
static il2cpp_object_get_class_fn p_object_get_class;
static il2cpp_class_get_type_fn p_class_get_type;
static il2cpp_type_get_object_fn p_type_get_object;
static il2cpp_string_length_fn p_string_length;
static il2cpp_string_chars_fn p_string_chars;
static il2cpp_method_get_param_fn p_method_get_param;
static il2cpp_class_from_type_fn p_class_from_type;
static il2cpp_object_new_fn p_object_new;
static il2cpp_class_get_fields_fn p_class_get_fields;
static il2cpp_field_get_name_fn p_field_get_name;
static il2cpp_field_get_flags_fn p_field_get_flags;
static il2cpp_field_get_type_fn p_field_get_type;
static il2cpp_type_get_type_fn p_type_get_type;
static il2cpp_field_get_value_fn p_field_get_value;
static il2cpp_field_set_value_fn p_field_set_value;
static il2cpp_field_static_set_value_fn p_field_static_set_value;
static il2cpp_string_new_fn p_string_new;

static BOOL g_resolved = NO;
static BOOL g_resolveOk = NO;

@implementation IL2CppBridge

+ (BOOL)resolveSymbols {
    if (g_resolved) return g_resolveOk;

    p_domain_get = (il2cpp_domain_get_fn)dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    p_domain_get_assemblies = (il2cpp_domain_get_assemblies_fn)dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    p_assembly_get_image = (il2cpp_assembly_get_image_fn)dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    p_image_get_name = (il2cpp_image_get_name_fn)dlsym(RTLD_DEFAULT, "il2cpp_image_get_name");
    p_class_from_name = (il2cpp_class_from_name_fn)dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    p_class_get_method_from_name = (il2cpp_class_get_method_from_name_fn)dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
    p_runtime_invoke = (il2cpp_runtime_invoke_fn)dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    p_class_get_field_from_name = (il2cpp_class_get_field_from_name_fn)dlsym(RTLD_DEFAULT, "il2cpp_class_get_field_from_name");
    p_field_get_offset = (il2cpp_field_get_offset_fn)dlsym(RTLD_DEFAULT, "il2cpp_field_get_offset");
    p_field_static_get_value = (il2cpp_field_static_get_value_fn)dlsym(RTLD_DEFAULT, "il2cpp_field_static_get_value");
    p_object_get_class = (il2cpp_object_get_class_fn)dlsym(RTLD_DEFAULT, "il2cpp_object_get_class");
    p_class_get_type = (il2cpp_class_get_type_fn)dlsym(RTLD_DEFAULT, "il2cpp_class_get_type");
    p_type_get_object = (il2cpp_type_get_object_fn)dlsym(RTLD_DEFAULT, "il2cpp_type_get_object");

    p_string_length = (il2cpp_string_length_fn)dlsym(RTLD_DEFAULT, "il2cpp_string_length");
    p_string_chars = (il2cpp_string_chars_fn)dlsym(RTLD_DEFAULT, "il2cpp_string_chars");
    p_string_new = (il2cpp_string_new_fn)dlsym(RTLD_DEFAULT, "il2cpp_string_new");

    p_method_get_param = (il2cpp_method_get_param_fn)dlsym(RTLD_DEFAULT, "il2cpp_method_get_param");
    p_class_from_type = (il2cpp_class_from_type_fn)dlsym(RTLD_DEFAULT, "il2cpp_class_from_type");
    p_object_new = (il2cpp_object_new_fn)dlsym(RTLD_DEFAULT, "il2cpp_object_new");
    p_class_get_fields = (il2cpp_class_get_fields_fn)dlsym(RTLD_DEFAULT, "il2cpp_class_get_fields");
    p_field_get_name = (il2cpp_field_get_name_fn)dlsym(RTLD_DEFAULT, "il2cpp_field_get_name");
    p_field_get_flags = (il2cpp_field_get_flags_fn)dlsym(RTLD_DEFAULT, "il2cpp_field_get_flags");
    p_field_get_type = (il2cpp_field_get_type_fn)dlsym(RTLD_DEFAULT, "il2cpp_field_get_type");
    p_type_get_type = (il2cpp_type_get_type_fn)dlsym(RTLD_DEFAULT, "il2cpp_type_get_type");
    p_field_get_value = (il2cpp_field_get_value_fn)dlsym(RTLD_DEFAULT, "il2cpp_field_get_value");
    p_field_set_value = (il2cpp_field_set_value_fn)dlsym(RTLD_DEFAULT, "il2cpp_field_set_value");
    p_field_static_set_value = (il2cpp_field_static_set_value_fn)dlsym(RTLD_DEFAULT, "il2cpp_field_static_set_value");

    g_resolveOk = p_domain_get && p_domain_get_assemblies && p_assembly_get_image && p_image_get_name &&
                  p_class_from_name && p_class_get_method_from_name && p_runtime_invoke &&
                  p_class_get_field_from_name && p_field_get_offset &&
                  p_object_get_class && p_class_get_type && p_type_get_object;
    g_resolved = g_resolveOk;
    ZLog(@"IL2CppBridge symbol resolution %@", g_resolveOk ? @"succeeded" : @"FAILED - il2cpp API unavailable");
    return g_resolveOk;
}

+ (void *)classNamed:(const char *)className
          inNamespace:(const char *)namespaze
     assemblyContains:(const char *)assemblySubstring {
    if (![self resolveSymbols]) return NULL;

    void *domain = p_domain_get();
    if (!domain) return NULL;

    size_t count = 0;
    void **assemblies = p_domain_get_assemblies(domain, &count);
    if (!assemblies || count == 0) return NULL;

    for (size_t i = 0; i < count; i++) {
        const void *image = p_assembly_get_image(assemblies[i]);
        if (!image) continue;
        const char *name = p_image_get_name(image);
        if (!name || !strstr(name, assemblySubstring)) continue;

        void *klass = p_class_from_name(image, namespaze, className);
        if (klass) return klass;
    }
    return NULL;
}

+ (const void *)methodOnClass:(void *)klass
                          name:(const char *)methodName
                      argCount:(int)argCount {
    if (!g_resolveOk || !klass) return NULL;
    const void *method = p_class_get_method_from_name(klass, methodName, argCount);
    return method;
}

+ (void *)invokeMethod:(const void *)method
             onInstance:(void *)obj
                   args:(void **)args
          outException:(void **)outException {
    if (!g_resolveOk || !method) return NULL;
    void *exc = NULL;
    void *result = p_runtime_invoke(method, obj, args, &exc);
    if (exc) {
        ZLog(@"[IL2CppBridge] invokeMethod raised a managed exception (obj=%p)", obj);
    }
    if (outException) *outException = exc;

    return result;
}

+ (BOOL)copyStaticFieldOnClass:(void *)klass name:(const char *)fieldName toBuffer:(void *)buffer {
    if (!g_resolveOk || !klass || !fieldName || !buffer || !p_field_static_get_value) return NO;
    void *field = p_class_get_field_from_name(klass, fieldName);
    if (!field) {
        ZLog(@"[IL2CppBridge] copyStaticFieldOnClass: field not found: %s", fieldName);
        return NO;
    }
    p_field_static_get_value(field, buffer);
    return YES;
}

+ (int32_t)fieldOffsetOnClass:(void *)klass name:(const char *)fieldName {
    if (!g_resolveOk || !klass) return -1;
    void *field = p_class_get_field_from_name(klass, fieldName);
    if (!field) {
        ZLog(@"[IL2CppBridge] fieldOffsetOnClass: field not found: %s", fieldName);
        return -1;
    }
    return p_field_get_offset(field);
}

+ (void *)classOfInstance:(void *)obj {
    if (!g_resolveOk || !obj) return NULL;
    return p_object_get_class(obj);
}

+ (void *)reflectionTypeForClass:(void *)klass {
    if (!g_resolveOk || !klass) return NULL;
    const void *type = p_class_get_type(klass);
    if (!type) return NULL;
    return p_type_get_object(type);
}

+ (NSString *)nsStringFromIl2CppString:(void *)il2cppString {
    if (!il2cppString || !p_string_length || !p_string_chars) return nil;
    int32_t len = p_string_length(il2cppString);
    if (len <= 0) return @"";
    uint16_t *chars = p_string_chars(il2cppString);
    if (!chars) return nil;

    return [[NSString alloc] initWithBytes:chars
                                     length:(NSUInteger)len * sizeof(uint16_t)
                                   encoding:NSUTF16LittleEndianStringEncoding];
}

+ (void *)il2CppStringFromNSString:(NSString *)string {
    if (!g_resolveOk || !p_string_new || !string) return NULL;
    const char *utf8 = [string UTF8String];
    if (!utf8) return NULL;
    return p_string_new(utf8);
}

+ (const void *)paramTypeForMethod:(const void *)method index:(uint32_t)index {
    if (!method || !p_method_get_param) return NULL;
    return p_method_get_param(method, index);
}

+ (void *)classFromType:(const void *)type {
    if (!type || !p_class_from_type) return NULL;
    return p_class_from_type(type);
}

+ (void *)newObjectForClass:(void *)klass {
    if (!klass || !p_object_new) return NULL;
    return p_object_new(klass);
}

+ (void *)nativeFunctionPointerForMethod:(const void *)method {
    if (!method) return NULL;
    return *(void **)method;
}

+ (void *)fieldNamed:(const char *)fieldName onClass:(void *)klass {
    if (!g_resolveOk || !klass || !fieldName) return NULL;
    return p_class_get_field_from_name(klass, fieldName);
}

+ (void *)nextFieldOnClass:(void *)klass iterator:(void **)iter {
    if (!g_resolveOk || !klass || !p_class_get_fields || !iter) return NULL;
    return p_class_get_fields(klass, iter);
}

+ (const char *)nameOfField:(void *)field {
    if (!field || !p_field_get_name) return NULL;
    return p_field_get_name(field);
}

+ (uint32_t)flagsOfField:(void *)field {
    if (!field || !p_field_get_flags) return 0;
    return p_field_get_flags(field);
}

+ (int32_t)typeEnumOfField:(void *)field {
    if (!field || !p_field_get_type || !p_type_get_type) return -1;
    const void *type = p_field_get_type(field);
    if (!type) return -1;
    return p_type_get_type(type);
}

+ (BOOL)copyStaticFieldValue:(void *)field toBuffer:(void *)buffer {
    if (!g_resolveOk || !field || !buffer || !p_field_static_get_value) return NO;
    p_field_static_get_value(field, buffer);
    return YES;
}

+ (void)setStaticFieldValue:(void *)field fromBuffer:(void *)buffer {
    if (!g_resolveOk || !field || !buffer || !p_field_static_set_value) return;
    p_field_static_set_value(field, buffer);
}

+ (BOOL)copyInstanceFieldValue:(void *)field onInstance:(void *)obj toBuffer:(void *)buffer {
    if (!g_resolveOk || !field || !obj || !buffer || !p_field_get_value) return NO;
    p_field_get_value(obj, field, buffer);
    return YES;
}

+ (void)setInstanceFieldValue:(void *)field onInstance:(void *)obj fromBuffer:(void *)buffer {
    if (!g_resolveOk || !field || !obj || !buffer || !p_field_set_value) return;
    p_field_set_value(obj, field, buffer);
}

+ (void *)findFirstLiveInstanceOfClass:(void *)klass {
    ZLog(@"[IL2CppBridge] findFirstLiveInstanceOfClass called but is stubbed, returning NULL (instance-field editing unimplemented)");
    return NULL;
}

@end

#pragma mark - ZSDumpFieldBrowser

@implementation ZSLiveField
@end

static const uint32_t kZSFieldAttrStatic = 0x0010;
static const uint32_t kZSFieldAttrLiteral = 0x0040;
static const uint32_t kZSFieldAccessMask = 0x0007;
static const uint32_t kZSFieldAttrPublic = 0x0006;

NSArray<NSString *> *zs_field_browser_categories(void) {
    static NSArray<NSString *> *categories;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        categories = @[
            @"1. GRAPHICS & QUALITY SETTINGS",
            @"2. CAMERA & RENDERING",
            @"3. FRAME RATE & APPLICATION PERFORMANCE",
            @"4. MEMORY MANAGEMENT",
            @"5. ASSET LOADING & STREAMING",
            @"6. THREADING, ASYNC & JOBS",
            @"7. PARTICLES, VFX & ANIMATION",
            @"8. PHYSICS & UPDATE LOOP",
            @"9. GAME SETTINGS / OPTIONS MENU CODE",
        ];
    });
    return categories;
}

NSArray<NSDictionary *> *zs_field_browser_entries_for_category(NSString *category) {
    if (category.length == 0) return @[];
    const char *wantCategory = category.UTF8String;
    const ZSDumpTypeInfo *registry = zs_dump_type_registry();
    NSUInteger count = zs_dump_type_count();
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:256];
    for (NSUInteger i = 0; i < count; i++) {
        if (strcmp(registry[i].category, wantCategory) != 0) continue;
        [entries addObject:@{
            @"category": @(registry[i].category),
            @"assembly": @(registry[i].assembly),
            @"namespace": @(registry[i].namespaze),
            @"kind": @(registry[i].kind),
            @"name": @(registry[i].name),
        }];
    }
    return entries;
}

NSUInteger zs_field_browser_count_for_category(NSString *category) {
    return zs_field_browser_entries_for_category(category).count;
}

static void *zs_field_browser_resolve_class(NSDictionary *entry) {
    NSString *assembly = entry[@"assembly"];
    NSString *namespaze = entry[@"namespace"];
    NSString *name = entry[@"name"];
    if (name.length == 0) return NULL;

    NSString *assemblySubstring = assembly;
    if ([assemblySubstring hasSuffix:@".cs"]) {
        assemblySubstring = [assemblySubstring substringToIndex:assemblySubstring.length - 3];
    }

    void *klass = [IL2CppBridge classNamed:name.UTF8String
                                inNamespace:namespaze.UTF8String ?: ""
                           assemblyContains:assemblySubstring.UTF8String ?: ""];
    if (!klass) {
        ZLog(@"[ZSDumpFieldBrowser] couldn't resolve class %@ (namespace=%@ assembly~=%@)", name, namespaze, assemblySubstring);
    }
    return klass;
}

static BOOL zs_field_browser_type_kind(int32_t typeEnum, ZSFieldKind *outKind) {
    switch (typeEnum) {
        case 0x02:
            *outKind = ZSFieldKindBool;
            return YES;
        case 0x04: case 0x05: case 0x06: case 0x07:
        case 0x08: case 0x09: case 0x0a: case 0x0b:
            *outKind = ZSFieldKindInteger;
            return YES;
        case 0x0c: case 0x0d:
            *outKind = ZSFieldKindFloat;
            return YES;
        default:
            return NO;
    }
}

static double zs_field_browser_read_buffer(int32_t typeEnum, uint8_t *buf) {
    switch (typeEnum) {
        case 0x02: return *(uint8_t *)buf ? 1 : 0;
        case 0x04: return *(int8_t *)buf;
        case 0x05: return *(uint8_t *)buf;
        case 0x06: return *(int16_t *)buf;
        case 0x07: return *(uint16_t *)buf;
        case 0x08: return *(int32_t *)buf;
        case 0x09: return *(uint32_t *)buf;
        case 0x0a: return (double)*(int64_t *)buf;
        case 0x0b: return (double)*(uint64_t *)buf;
        case 0x0c: return *(float *)buf;
        case 0x0d: return *(double *)buf;
        default: return 0;
    }
}

static void zs_field_browser_write_buffer(int32_t typeEnum, double value, uint8_t *buf) {
    memset(buf, 0, 8);
    switch (typeEnum) {
        case 0x02: *(uint8_t *)buf = (value != 0) ? 1 : 0; break;
        case 0x04: *(int8_t *)buf = (int8_t)value; break;
        case 0x05: *(uint8_t *)buf = (uint8_t)value; break;
        case 0x06: *(int16_t *)buf = (int16_t)value; break;
        case 0x07: *(uint16_t *)buf = (uint16_t)value; break;
        case 0x08: *(int32_t *)buf = (int32_t)value; break;
        case 0x09: *(uint32_t *)buf = (uint32_t)value; break;
        case 0x0a: *(int64_t *)buf = (int64_t)value; break;
        case 0x0b: *(uint64_t *)buf = (uint64_t)value; break;
        case 0x0c: *(float *)buf = (float)value; break;
        case 0x0d: *(double *)buf = value; break;
        default: break;
    }
}

static BOOL zs_field_browser_should_skip_field(void *field) {
    const char *name = [IL2CppBridge nameOfField:field];
    if (!name || name[0] == '<') return YES;
    uint32_t flags = [IL2CppBridge flagsOfField:field];
    if (!(flags & kZSFieldAttrStatic)) return YES;
    if (flags & kZSFieldAttrLiteral) return YES;
    if ((flags & kZSFieldAccessMask) != kZSFieldAttrPublic) return YES;
    return NO;
}

NSArray<ZSLiveField *> *zs_field_browser_fields_for_entry(NSDictionary *entry, ZSFieldBrowserResolution *outResolution) {
    if (outResolution) *outResolution = ZSFieldBrowserResolutionClassNotFound;

    NSString *kind = entry[@"kind"];
    if ([kind isEqualToString:@"enum"] || [kind isEqualToString:@"interface"]) {
        if (outResolution) *outResolution = ZSFieldBrowserResolutionNoEditableFields;
        return @[];
    }

    void *klass = zs_field_browser_resolve_class(entry);
    if (!klass) return @[];

    ZLog(@"[ZSDumpFieldBrowser] browsing live fields for %@", entry[@"name"]);
    NSMutableArray<ZSLiveField *> *fields = [NSMutableArray array];
    void *iter = NULL;
    void *field = NULL;
    while ((field = [IL2CppBridge nextFieldOnClass:klass iterator:&iter])) {
        if (zs_field_browser_should_skip_field(field)) continue;

        int32_t typeEnum = [IL2CppBridge typeEnumOfField:field];
        ZSFieldKind kindEnum;
        if (!zs_field_browser_type_kind(typeEnum, &kindEnum)) continue;

        uint8_t buf[8] = {0};
        if (![IL2CppBridge copyStaticFieldValue:field toBuffer:buf]) continue;

        ZSLiveField *liveField = [ZSLiveField new];
        liveField.name = [NSString stringWithUTF8String:[IL2CppBridge nameOfField:field]];
        liveField.kind = kindEnum;
        liveField.typeEnum = typeEnum;
        liveField.currentValue = zs_field_browser_read_buffer(typeEnum, buf);
        [fields addObject:liveField];
    }

    if (outResolution) *outResolution = fields.count > 0 ? ZSFieldBrowserResolutionOk : ZSFieldBrowserResolutionNoEditableFields;
    ZLog(@"[ZSDumpFieldBrowser] found %lu editable field(s) on %@", (unsigned long)fields.count, entry[@"name"]);
    return fields;
}

double zs_field_browser_get_value(NSDictionary *entry, NSString *fieldName, int32_t typeEnum) {
    void *klass = zs_field_browser_resolve_class(entry);
    if (!klass) return 0;
    void *field = [IL2CppBridge fieldNamed:fieldName.UTF8String onClass:klass];
    if (!field) {
        ZLog(@"[ZSDumpFieldBrowser] get: field %@ not found on %@", fieldName, entry[@"name"]);
        return 0;
    }
    uint8_t buf[8] = {0};
    if (![IL2CppBridge copyStaticFieldValue:field toBuffer:buf]) return 0;
    return zs_field_browser_read_buffer(typeEnum, buf);
}

void zs_field_browser_set_value(NSDictionary *entry, NSString *fieldName, int32_t typeEnum, double value) {
    void *klass = zs_field_browser_resolve_class(entry);
    if (!klass) return;
    void *field = [IL2CppBridge fieldNamed:fieldName.UTF8String onClass:klass];
    if (!field) {
        ZLog(@"[ZSDumpFieldBrowser] set: field %@ not found on %@", fieldName, entry[@"name"]);
        return;
    }
    ZLog(@"[ZSDumpFieldBrowser] set %@.%@ = %g", entry[@"name"], fieldName, value);
    uint8_t buf[8] = {0};
    zs_field_browser_write_buffer(typeEnum, value, buf);
    [IL2CppBridge setStaticFieldValue:field fromBuffer:buf];
}
