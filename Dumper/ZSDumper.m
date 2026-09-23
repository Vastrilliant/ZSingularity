#import "ZSDumper.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdint.h>
#include <stdbool.h>
#import "ZTweakLog.h"

typedef void *(*zs_domain_get_fn)(void);
typedef void **(*zs_domain_get_assemblies_fn)(const void *, size_t *);
typedef const void *(*zs_assembly_get_image_fn)(const void *);
typedef const char *(*zs_image_get_name_fn)(const void *);
typedef const char *(*zs_image_get_filename_fn)(const void *);
typedef size_t (*zs_image_get_class_count_fn)(const void *);
typedef const void *(*zs_image_get_class_fn)(const void *, size_t);
typedef void *(*zs_thread_current_fn)(void);
typedef void *(*zs_thread_attach_fn)(void *);
typedef void (*zs_thread_detach_fn)(void *);

typedef const char *(*zs_class_get_name_fn)(void *);
typedef const char *(*zs_class_get_namespace_fn)(void *);
typedef void *(*zs_class_get_parent_fn)(void *);
typedef void *(*zs_class_get_declaring_type_fn)(void *);
typedef const void *(*zs_class_get_type_fn)(void *);
typedef int32_t (*zs_class_instance_size_fn)(void *);
typedef size_t (*zs_class_num_fields_fn)(const void *);
typedef bool (*zs_class_is_valuetype_fn)(const void *);
typedef bool (*zs_class_is_blittable_fn)(const void *);
typedef int (*zs_class_get_flags_fn)(const void *);
typedef bool (*zs_class_is_abstract_fn)(const void *);
typedef bool (*zs_class_is_interface_fn)(const void *);
typedef bool (*zs_class_is_enum_fn)(const void *);
typedef int32_t (*zs_class_value_size_fn)(void *, uint32_t *);
typedef int (*zs_class_array_element_size_fn)(const void *);
typedef bool (*zs_class_is_generic_fn)(const void *);
typedef bool (*zs_class_is_inflated_fn)(const void *);
typedef uint32_t (*zs_class_get_type_token_fn)(void *);
typedef int (*zs_class_get_rank_fn)(const void *);
typedef size_t (*zs_class_get_bitmap_size_fn)(const void *);
typedef void *(*zs_class_get_fields_fn)(void *, void **);
typedef void *(*zs_class_get_methods_fn)(void *, void **);
typedef void *(*zs_class_get_nested_types_fn)(void *, void **);
typedef void *(*zs_class_get_interfaces_fn)(void *, void **);
typedef const void *(*zs_class_get_properties_fn)(void *, void **);
typedef const void *(*zs_class_get_events_fn)(void *, void **);
typedef const void *(*zs_class_get_image_fn)(void *);
typedef const char *(*zs_class_get_assemblyname_fn)(const void *);

typedef const char *(*zs_method_get_name_fn)(const void *);
typedef const void *(*zs_method_get_return_type_fn)(const void *);
typedef uint32_t (*zs_method_get_param_count_fn)(const void *);
typedef const void *(*zs_method_get_param_fn)(const void *, uint32_t);
typedef const char *(*zs_method_get_param_name_fn)(const void *, uint32_t);
typedef void *(*zs_method_get_class_fn)(const void *);
typedef void *(*zs_method_get_declaring_type_fn)(const void *);
typedef uint32_t (*zs_method_get_flags_fn)(const void *, uint32_t *);
typedef uint32_t (*zs_method_get_token_fn)(const void *);
typedef bool (*zs_method_is_generic_fn)(const void *);
typedef bool (*zs_method_is_inflated_fn)(const void *);
typedef bool (*zs_method_is_instance_fn)(const void *);
typedef void *(*zs_method_get_pointer_fn)(const void *);

typedef int (*zs_field_get_flags_fn)(void *);
typedef const char *(*zs_field_get_name_fn)(void *);
typedef void *(*zs_field_get_parent_fn)(void *);
typedef size_t (*zs_field_get_offset_fn)(void *);
typedef const void *(*zs_field_get_type_fn)(void *);
typedef bool (*zs_field_is_literal_fn)(void *);

typedef uint32_t (*zs_property_get_flags_fn)(void *);
typedef const void *(*zs_property_get_get_method_fn)(void *);
typedef const void *(*zs_property_get_set_method_fn)(void *);
typedef const char *(*zs_property_get_name_fn)(void *);
typedef void *(*zs_property_get_parent_fn)(void *);

typedef int (*zs_type_get_type_fn)(const void *);
typedef char *(*zs_type_get_name_fn)(const void *);
typedef uint32_t (*zs_type_get_attrs_fn)(const void *);
typedef bool (*zs_type_is_byref_fn)(const void *);
typedef char *(*zs_type_get_assembly_qualified_name_fn)(const void *);
typedef bool (*zs_type_is_static_fn)(const void *);
typedef bool (*zs_type_is_pointer_type_fn)(const void *);
typedef void *(*zs_type_get_class_or_element_class_fn)(const void *);

typedef struct {
    zs_domain_get_fn domain_get;
    zs_domain_get_assemblies_fn domain_get_assemblies;
    zs_assembly_get_image_fn assembly_get_image;
    zs_image_get_name_fn image_get_name;
    zs_image_get_filename_fn image_get_filename;
    zs_image_get_class_count_fn image_get_class_count;
    zs_image_get_class_fn image_get_class;
    zs_thread_current_fn thread_current;
    zs_thread_attach_fn thread_attach;
    zs_thread_detach_fn thread_detach;
    zs_class_get_name_fn class_get_name;
    zs_class_get_namespace_fn class_get_namespace;
    zs_class_get_parent_fn class_get_parent;
    zs_class_get_declaring_type_fn class_get_declaring_type;
    zs_class_get_type_fn class_get_type;
    zs_class_instance_size_fn class_instance_size;
    zs_class_num_fields_fn class_num_fields;
    zs_class_is_valuetype_fn class_is_valuetype;
    zs_class_is_blittable_fn class_is_blittable;
    zs_class_get_flags_fn class_get_flags;
    zs_class_is_abstract_fn class_is_abstract;
    zs_class_is_interface_fn class_is_interface;
    zs_class_is_enum_fn class_is_enum;
    zs_class_value_size_fn class_value_size;
    zs_class_array_element_size_fn class_array_element_size;
    zs_class_is_generic_fn class_is_generic;
    zs_class_is_inflated_fn class_is_inflated;
    zs_class_get_type_token_fn class_get_type_token;
    zs_class_get_rank_fn class_get_rank;
    zs_class_get_bitmap_size_fn class_get_bitmap_size;
    zs_class_get_fields_fn class_get_fields;
    zs_class_get_methods_fn class_get_methods;
    zs_class_get_nested_types_fn class_get_nested_types;
    zs_class_get_interfaces_fn class_get_interfaces;
    zs_class_get_properties_fn class_get_properties;
    zs_class_get_events_fn class_get_events;
    zs_class_get_image_fn class_get_image;
    zs_class_get_assemblyname_fn class_get_assemblyname;
    zs_method_get_name_fn method_get_name;
    zs_method_get_return_type_fn method_get_return_type;
    zs_method_get_param_count_fn method_get_param_count;
    zs_method_get_param_fn method_get_param;
    zs_method_get_param_name_fn method_get_param_name;
    zs_method_get_class_fn method_get_class;
    zs_method_get_declaring_type_fn method_get_declaring_type;
    zs_method_get_flags_fn method_get_flags;
    zs_method_get_token_fn method_get_token;
    zs_method_is_generic_fn method_is_generic;
    zs_method_is_inflated_fn method_is_inflated;
    zs_method_is_instance_fn method_is_instance;
    zs_method_get_pointer_fn method_get_pointer;
    zs_field_get_flags_fn field_get_flags;
    zs_field_get_name_fn field_get_name;
    zs_field_get_parent_fn field_get_parent;
    zs_field_get_offset_fn field_get_offset;
    zs_field_get_type_fn field_get_type;
    zs_field_is_literal_fn field_is_literal;
    zs_property_get_flags_fn property_get_flags;
    zs_property_get_get_method_fn property_get_get_method;
    zs_property_get_set_method_fn property_get_set_method;
    zs_property_get_name_fn property_get_name;
    zs_property_get_parent_fn property_get_parent;
    zs_type_get_type_fn type_get_type;
    zs_type_get_name_fn type_get_name;
    zs_type_get_attrs_fn type_get_attrs;
    zs_type_is_byref_fn type_is_byref;
    zs_type_get_assembly_qualified_name_fn type_get_assembly_qualified_name;
    zs_type_is_static_fn type_is_static;
    zs_type_is_pointer_type_fn type_is_pointer_type;
    zs_type_get_class_or_element_class_fn type_get_class_or_element_class;
} ZSRuntimeAPI;

static ZSRuntimeAPI gAPI;
static BOOL gResolved;
static BOOL gRunning;
static NSLock *gRuntimeLock;

static void *zs_symbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

#define ZS_RESOLVE(name) gAPI.name = (typeof(gAPI.name))zs_symbol(#name)

static BOOL zs_resolve_api(NSError **error) {
    if (gResolved) return YES;
    ZS_RESOLVE(domain_get);
    ZS_RESOLVE(domain_get_assemblies);
    ZS_RESOLVE(assembly_get_image);
    ZS_RESOLVE(image_get_name);
    ZS_RESOLVE(image_get_filename);
    ZS_RESOLVE(image_get_class_count);
    ZS_RESOLVE(image_get_class);
    ZS_RESOLVE(thread_current);
    ZS_RESOLVE(thread_attach);
    ZS_RESOLVE(thread_detach);
    ZS_RESOLVE(class_get_name);
    ZS_RESOLVE(class_get_namespace);
    ZS_RESOLVE(class_get_parent);
    ZS_RESOLVE(class_get_declaring_type);
    ZS_RESOLVE(class_get_type);
    ZS_RESOLVE(class_instance_size);
    ZS_RESOLVE(class_num_fields);
    ZS_RESOLVE(class_is_valuetype);
    ZS_RESOLVE(class_is_blittable);
    ZS_RESOLVE(class_get_flags);
    ZS_RESOLVE(class_is_abstract);
    ZS_RESOLVE(class_is_interface);
    ZS_RESOLVE(class_is_enum);
    ZS_RESOLVE(class_value_size);
    ZS_RESOLVE(class_array_element_size);
    ZS_RESOLVE(class_is_generic);
    ZS_RESOLVE(class_is_inflated);
    ZS_RESOLVE(class_get_type_token);
    ZS_RESOLVE(class_get_rank);
    ZS_RESOLVE(class_get_bitmap_size);
    ZS_RESOLVE(class_get_fields);
    ZS_RESOLVE(class_get_methods);
    ZS_RESOLVE(class_get_nested_types);
    ZS_RESOLVE(class_get_interfaces);
    ZS_RESOLVE(class_get_properties);
    ZS_RESOLVE(class_get_events);
    ZS_RESOLVE(class_get_image);
    ZS_RESOLVE(class_get_assemblyname);
    ZS_RESOLVE(method_get_name);
    ZS_RESOLVE(method_get_return_type);
    ZS_RESOLVE(method_get_param_count);
    ZS_RESOLVE(method_get_param);
    ZS_RESOLVE(method_get_param_name);
    ZS_RESOLVE(method_get_class);
    ZS_RESOLVE(method_get_declaring_type);
    ZS_RESOLVE(method_get_flags);
    ZS_RESOLVE(method_get_token);
    ZS_RESOLVE(method_is_generic);
    ZS_RESOLVE(method_is_inflated);
    ZS_RESOLVE(method_is_instance);
    ZS_RESOLVE(method_get_pointer);
    ZS_RESOLVE(field_get_flags);
    ZS_RESOLVE(field_get_name);
    ZS_RESOLVE(field_get_parent);
    ZS_RESOLVE(field_get_offset);
    ZS_RESOLVE(field_get_type);
    ZS_RESOLVE(field_is_literal);
    ZS_RESOLVE(property_get_flags);
    ZS_RESOLVE(property_get_get_method);
    ZS_RESOLVE(property_get_set_method);
    ZS_RESOLVE(property_get_name);
    ZS_RESOLVE(property_get_parent);
    ZS_RESOLVE(type_get_type);
    ZS_RESOLVE(type_get_name);
    ZS_RESOLVE(type_get_attrs);
    ZS_RESOLVE(type_is_byref);
    ZS_RESOLVE(type_get_assembly_qualified_name);
    ZS_RESOLVE(type_is_static);
    ZS_RESOLVE(type_is_pointer_type);
    ZS_RESOLVE(type_get_class_or_element_class);

    BOOL required = gAPI.domain_get &&
                    gAPI.domain_get_assemblies &&
                    gAPI.assembly_get_image &&
                    gAPI.image_get_name &&
                    gAPI.image_get_class_count &&
                    gAPI.image_get_class &&
                    gAPI.thread_attach &&
                    gAPI.thread_detach &&
                    gAPI.class_get_name &&
                    gAPI.class_get_namespace &&
                    gAPI.class_get_methods &&
                    gAPI.method_get_name &&
                    gAPI.method_get_return_type &&
                    gAPI.method_get_param_count &&
                    gAPI.method_get_param &&
                    gAPI.method_get_flags &&
                    gAPI.method_get_token &&
                    gAPI.field_get_name &&
                    gAPI.field_get_flags &&
                    gAPI.field_get_offset &&
                    gAPI.field_get_type &&
                    gAPI.type_get_type &&
                    gAPI.type_get_name;
    if (!required) {
        if (error) *error = [NSError errorWithDomain:@"ZSDumper" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The loaded IL2CPP runtime is missing required reflection exports."}];
        return NO;
    }
    gResolved = YES;
    return YES;
}

static NSString *zs_ptr(const void *ptr) {
    return ptr ? [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)ptr] : @"0x0";
}

static NSString *zs_hex(uint64_t value) {
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)value];
}

static NSString *zs_string(const char *value) {
    return value ? [NSString stringWithUTF8String:value] ?: @"" : @"";
}

static NSString *zs_json(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    return !error && data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"null" : @"null";
}

static void zs_append_json_object(NSFileHandle *handle, NSDictionary *object, BOOL *needsComma) {
    if (*needsComma) [handle writeData:[@"," dataUsingEncoding:NSUTF8StringEncoding]];
    [handle writeData:[zs_json(object) dataUsingEncoding:NSUTF8StringEncoding]];
    *needsComma = YES;
}

static void zs_write_line(NSFileHandle *handle, NSString *line) {
    [handle writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
}

static NSString *zs_access(uint32_t flags) {
    switch (flags & 0x7) {
        case 1: return @"private";
        case 2: return @"private protected";
        case 3: return @"internal";
        case 4: return @"protected";
        case 5: return @"protected internal";
        case 6: return @"public";
        default: return @"";
    }
}

static NSString *zs_safe_identifier(NSString *value) {
    if (value.length == 0) return @"_";
    NSMutableString *result = [NSMutableString stringWithCapacity:value.length];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        [result appendFormat:@"%C", [allowed characterIsMember:c] ? c : '_'];
    }
    if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[result characterAtIndex:0]]) [result insertString:@"_" atIndex:0];
    return result;
}

static NSString *zs_csharp_type(NSString *typeName) {
    if (typeName.length == 0) return @"void";
    NSString *result = [typeName stringByReplacingOccurrencesOfString:@"System." withString:@""];
    NSDictionary *aliases = @{@"Void": @"void", @"Boolean": @"bool", @"Byte": @"byte", @"SByte": @"sbyte", @"Char": @"char", @"Double": @"double", @"Single": @"float", @"Int16": @"short", @"UInt16": @"ushort", @"Int32": @"int", @"UInt32": @"uint", @"Int64": @"long", @"UInt64": @"ulong", @"String": @"string", @"Object": @"object", @"Decimal": @"decimal"};
    NSString *alias = aliases[result];
    return alias ?: result;
}

static NSDictionary *zs_type_dict(const ZSRuntimeAPI *api, const void *type) {
    if (!type) return @{};
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:@{
        @"pointer": zs_ptr(type),
        @"name": zs_string(api->type_get_name(type)),
        @"enum": @(api->type_get_type(type)),
        @"attrs": zs_hex(api->type_get_attrs ? api->type_get_attrs(type) : 0),
        @"byref": @(api->type_is_byref ? api->type_is_byref(type) : NO),
        @"static": @(api->type_is_static ? api->type_is_static(type) : NO),
        @"pointerType": @(api->type_is_pointer_type ? api->type_is_pointer_type(type) : NO),
        @"classPointer": zs_ptr(api->type_get_class_or_element_class ? api->type_get_class_or_element_class(type) : NULL)
    }];
    if (api->type_get_assembly_qualified_name) dict[@"assemblyQualifiedName"] = zs_string(api->type_get_assembly_qualified_name(type));
    return dict;
}

static NSDictionary *zs_method_dict(const ZSRuntimeAPI *api, const void *method) {
    if (!method) return @{};
    uint32_t implementationFlags = 0;
    uint32_t flags = api->method_get_flags(method, &implementationFlags);
    uint32_t parameterCount = api->method_get_param_count(method);
    NSMutableArray *parameters = [NSMutableArray arrayWithCapacity:parameterCount];
    NSMutableArray *parameterNames = [NSMutableArray arrayWithCapacity:parameterCount];
    for (uint32_t i = 0; i < parameterCount; i++) {
        const void *type = api->method_get_param(method, i);
        NSString *parameterName = api->method_get_param_name ? zs_string(api->method_get_param_name(method, i)) : @"";
        if (parameterName.length == 0) parameterName = [NSString stringWithFormat:@"arg%u", i];
        [parameterNames addObject:parameterName];
        [parameters addObject:zs_type_dict(api, type)];
    }
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:@{
        @"pointer": zs_ptr(method),
        @"name": zs_string(api->method_get_name(method)),
        @"flags": zs_hex(flags),
        @"implementationFlags": zs_hex(implementationFlags),
        @"token": zs_hex(api->method_get_token(method)),
        @"parameterCount": @(parameterCount),
        @"parameterNames": parameterNames,
        @"parameters": parameters,
        @"returnType": zs_type_dict(api, api->method_get_return_type(method)),
        @"generic": @(api->method_is_generic ? api->method_is_generic(method) : NO),
        @"inflated": @(api->method_is_inflated ? api->method_is_inflated(method) : NO),
        @"instance": @(api->method_is_instance ? api->method_is_instance(method) : NO),
        @"static": @((flags & 0x10) != 0),
        @"virtual": @((flags & 0x40) != 0),
        @"abstract": @((flags & 0x400) != 0),
        @"specialName": @((flags & 0x800) != 0),
        @"access": zs_access(flags),
        @"classPointer": zs_ptr(api->method_get_class ? api->method_get_class(method) : NULL),
        @"declaringClassPointer": zs_ptr(api->method_get_declaring_type ? api->method_get_declaring_type(method) : NULL)
    }];
    void *nativePointer = api->method_get_pointer ? api->method_get_pointer(method) : *(void * const *)method;
    dict[@"nativePointer"] = zs_ptr(nativePointer);
    dict[@"nativePointerSource"] = api->method_get_pointer ? @"il2cpp_method_get_pointer" : @"MethodInfo[0]";
    if (nativePointer) {
        Dl_info info = {0};
        if (dladdr(nativePointer, &info) != 0) {
            if (info.dli_fname) dict[@"nativeImage"] = zs_string(info.dli_fname);
            if (info.dli_fbase) {
                uintptr_t base = (uintptr_t)info.dli_fbase;
                uintptr_t address = (uintptr_t)nativePointer;
                dict[@"nativeImageBase"] = zs_ptr((const void *)base);
                if (address >= base) dict[@"rva"] = zs_hex(address - base);
            }
            if (info.dli_sname) dict[@"nativeSymbol"] = zs_string(info.dli_sname);
        }
    }
    return dict;
}

static NSString *zs_method_signature(const ZSRuntimeAPI *api, const void *method) {
    uint32_t flags = api->method_get_flags(method, NULL);
    NSMutableArray *parts = [NSMutableArray array];
    NSString *access = zs_access(flags);
    if (access.length > 0) [parts addObject:access];
    if ((flags & 0x10) != 0) [parts addObject:@"static"];
    if ((flags & 0x400) != 0) [parts addObject:@"abstract"];
    if ((flags & 0x40) != 0 && (flags & 0x400) == 0) [parts addObject:@"virtual"];
    const void *returnType = api->method_get_return_type(method);
    NSString *returnName = returnType ? zs_csharp_type(zs_string(api->type_get_name(returnType))) : @"void";
    NSMutableArray *parameters = [NSMutableArray array];
    uint32_t count = api->method_get_param_count(method);
    for (uint32_t i = 0; i < count; i++) {
        const void *type = api->method_get_param(method, i);
        NSString *typeName = type ? zs_csharp_type(zs_string(api->type_get_name(type))) : @"object";
        NSString *parameterName = api->method_get_param_name ? zs_string(api->method_get_param_name(method, i)) : @"";
        if (parameterName.length == 0) parameterName = [NSString stringWithFormat:@"arg%u", i];
        [parameters addObject:[NSString stringWithFormat:@"%@ %@", typeName, zs_safe_identifier(parameterName)]];
    }
    NSString *prefix = parts.count ? [[parts componentsJoinedByString:@" "] stringByAppendingString:@" "] : @"";
    return [NSString stringWithFormat:@"%@%@ %@(%@) {}", prefix, returnName, zs_safe_identifier(zs_string(api->method_get_name(method))), [parameters componentsJoinedByString:@", "]];
}

static NSString *zs_csv_quote(NSString *value) {
    return [NSString stringWithFormat:@"\"%@\"", [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""] ?: @""];
}

static void zs_write_loaded_images(NSFileHandle *handle, BOOL *needsComma) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        NSDictionary *image = @{
            @"index": @(i),
            @"path": zs_string(_dyld_get_image_name(i)),
            @"header": zs_ptr(_dyld_get_image_header(i)),
            @"slide": zs_hex((uint64_t)_dyld_get_image_vmaddr_slide(i))
        };
        zs_append_json_object(handle, image, needsComma);
    }
}

static void zs_write_class(const ZSRuntimeAPI *api,
                           void *klass,
                           NSUInteger classIndex,
                           NSUInteger assemblyIndex,
                           NSString *assemblyName,
                           NSString *imageFilename,
                           NSFileHandle *classesJSON,
                           NSFileHandle *methodsJSON,
                           NSFileHandle *fieldsJSON,
                           NSFileHandle *propertiesJSON,
                           NSFileHandle *cs,
                           NSFileHandle *csv,
                           BOOL *classNeedsComma,
                           BOOL *methodNeedsComma,
                           BOOL *fieldNeedsComma,
                           BOOL *propertyNeedsComma,
                           NSUInteger *methodCount,
                           NSUInteger *fieldCount,
                           NSUInteger *propertyCount) {
    NSString *name = zs_string(api->class_get_name(klass));
    NSString *namespaze = zs_string(api->class_get_namespace(klass));
    void *parent = api->class_get_parent ? api->class_get_parent(klass) : NULL;
    void *declaringType = api->class_get_declaring_type ? api->class_get_declaring_type(klass) : NULL;
    int flags = api->class_get_flags ? api->class_get_flags(klass) : 0;
    uint32_t alignment = 0;
    int32_t valueSize = api->class_value_size ? api->class_value_size(klass, &alignment) : -1;
    size_t fieldCount = api->class_num_fields ? api->class_num_fields(klass) : 0;
    NSString *kind = @"class";
    if (api->class_is_interface && api->class_is_interface(klass)) kind = @"interface";
    else if (api->class_is_enum && api->class_is_enum(klass)) kind = @"enum";
    else if (api->class_is_valuetype && api->class_is_valuetype(klass)) kind = @"struct";

    NSMutableDictionary *classDict = [NSMutableDictionary dictionaryWithDictionary:@{
        @"index": @(classIndex),
        @"assemblyIndex": @(assemblyIndex),
        @"assembly": assemblyName ?: @"",
        @"imageFilename": imageFilename ?: @"",
        @"pointer": zs_ptr(klass),
        @"namespace": namespaze,
        @"name": name,
        @"kind": kind,
        @"flags": zs_hex((uint64_t)(uint32_t)flags),
        @"abstract": @(api->class_is_abstract ? api->class_is_abstract(klass) : NO),
        @"interface": @(api->class_is_interface ? api->class_is_interface(klass) : NO),
        @"enum": @(api->class_is_enum ? api->class_is_enum(klass) : NO),
        @"valuetype": @(api->class_is_valuetype ? api->class_is_valuetype(klass) : NO),
        @"blittable": @(api->class_is_blittable ? api->class_is_blittable(klass) : NO),
        @"generic": @(api->class_is_generic ? api->class_is_generic(klass) : NO),
        @"inflated": @(api->class_is_inflated ? api->class_is_inflated(klass) : NO),
        @"fieldCount": @(fieldCount),
        @"instanceSize": @(api->class_instance_size ? api->class_instance_size(klass) : -1),
        @"valueSize": @(valueSize),
        @"valueAlignment": @(alignment),
        @"parentPointer": zs_ptr(parent),
        @"declaringTypePointer": zs_ptr(declaringType)
    }];
    if (api->class_get_type_token) classDict[@"typeToken"] = zs_hex(api->class_get_type_token(klass));
    if (api->class_get_rank) classDict[@"rank"] = @(api->class_get_rank(klass));
    if (api->class_array_element_size) classDict[@"arrayElementSize"] = @(api->class_array_element_size(klass));
    if (api->class_get_bitmap_size) classDict[@"bitmapSize"] = @(api->class_get_bitmap_size(klass));
    if (api->class_get_assemblyname) classDict[@"assemblyNameNoExtension"] = zs_string(api->class_get_assemblyname(klass));
    if (api->class_get_image) classDict[@"imagePointer"] = zs_ptr(api->class_get_image(klass));

    void *nestedIter = NULL;
    NSMutableArray *nestedTypes = [NSMutableArray array];
    if (api->class_get_nested_types) {
        void *nested = NULL;
        while ((nested = api->class_get_nested_types(klass, &nestedIter))) {
            [nestedTypes addObject:@{ @"pointer": zs_ptr(nested), @"name": zs_string(api->class_get_name(nested)), @"namespace": zs_string(api->class_get_namespace(nested)) }];
        }
    }
    classDict[@"nestedTypes"] = nestedTypes;

    void *interfaceIter = NULL;
    NSMutableArray *interfaces = [NSMutableArray array];
    if (api->class_get_interfaces) {
        void *interfaceClass = NULL;
        while ((interfaceClass = api->class_get_interfaces(klass, &interfaceIter))) {
            [interfaces addObject:@{ @"pointer": zs_ptr(interfaceClass), @"name": zs_string(api->class_get_name(interfaceClass)), @"namespace": zs_string(api->class_get_namespace(interfaceClass)) }];
        }
    }
    classDict[@"interfaces"] = interfaces;

    NSMutableArray *sourceMethods = [NSMutableArray array];
    void *methodIter = NULL;
    NSUInteger currentMethodCount = 0;
    const void *method = NULL;
    while ((method = api->class_get_methods(klass, &methodIter))) {
        @autoreleasepool {
            NSMutableDictionary *methodDict = [zs_method_dict(api, method) mutableCopy];
            methodDict[@"classIndex"] = @(classIndex);
            methodDict[@"assemblyIndex"] = @(assemblyIndex);
            methodDict[@"assembly"] = assemblyName ?: @"";
            methodDict[@"namespace"] = namespaze;
            methodDict[@"class"] = name;
            zs_append_json_object(methodsJSON, methodDict, methodNeedsComma);
            NSString *signature = zs_method_signature(api, method);
            [sourceMethods addObject:signature];
            zs_write_line(csv, [@[zs_csv_quote(assemblyName ?: @""), zs_csv_quote(namespaze ?: @""), zs_csv_quote(name ?: @""), zs_csv_quote(zs_string(api->method_get_name(method))), zs_csv_quote(signature ?: @""), zs_csv_quote(methodDict[@"token"] ?: @"0x0"), zs_csv_quote(methodDict[@"pointer"] ?: @"0x0"), zs_csv_quote(methodDict[@"nativePointer"] ?: @"0x0"), zs_csv_quote(methodDict[@"nativeImage"] ?: @""), zs_csv_quote(methodDict[@"rva"] ?: @""), zs_csv_quote(methodDict[@"flags"] ?: @"0x0"), zs_csv_quote(methodDict[@"implementationFlags"] ?: @"0x0"), [methodDict[@"generic"] boolValue] ? @"1" : @"0", [methodDict[@"inflated"] boolValue] ? @"1" : @"0", [methodDict[@"instance"] boolValue] ? @"1" : @"0"] componentsJoinedByString:@","]);
            currentMethodCount++;
            (*methodCount)++;
        }
    }
    classDict[@"methodCount"] = @(currentMethodCount);

    NSMutableArray *sourceFields = [NSMutableArray array];
    void *fieldIter = NULL;
    NSUInteger currentFieldCount = 0;
    if (api->class_get_fields) {
        void *field = NULL;
        while ((field = api->class_get_fields(klass, &fieldIter))) {
            @autoreleasepool {
                int fieldFlags = api->field_get_flags(field);
                const void *fieldType = api->field_get_type(field);
                NSMutableDictionary *fieldDict = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"classIndex": @(classIndex),
                    @"assemblyIndex": @(assemblyIndex),
                    @"assembly": assemblyName ?: @"",
                    @"namespace": namespaze,
                    @"class": name,
                    @"classPointer": zs_ptr(klass),
                    @"pointer": zs_ptr(field),
                    @"name": zs_string(api->field_get_name(field)),
                    @"flags": zs_hex((uint64_t)(uint32_t)fieldFlags),
                    @"offset": zs_hex(api->field_get_offset(field)),
                    @"type": zs_type_dict(api, fieldType),
                    @"static": @((fieldFlags & 0x10) != 0),
                    @"literal": @(api->field_is_literal ? api->field_is_literal(field) : ((fieldFlags & 0x40) != 0)),
                    @"access": zs_access((uint32_t)fieldFlags)
                }];
                if (api->field_get_parent) fieldDict[@"parentPointer"] = zs_ptr(api->field_get_parent(field));
                zs_append_json_object(fieldsJSON, fieldDict, fieldNeedsComma);
                [sourceFields addObject:fieldDict];
                currentFieldCount++;
                (*fieldCount)++;
            }
        }
    }
    classDict[@"fieldCount"] = @(currentFieldCount);

    NSUInteger currentPropertyCount = 0;
    void *propertyIter = NULL;
    if (api->class_get_properties) {
        const void *property = NULL;
        while ((property = api->class_get_properties(klass, &propertyIter))) {
            @autoreleasepool {
                NSMutableDictionary *propertyDict = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"classIndex": @(classIndex),
                    @"assemblyIndex": @(assemblyIndex),
                    @"assembly": assemblyName ?: @"",
                    @"namespace": namespaze,
                    @"class": name,
                    @"classPointer": zs_ptr(klass),
                    @"pointer": zs_ptr(property),
                    @"name": zs_string(api->property_get_name ? api->property_get_name((void *)property) : NULL),
                    @"flags": zs_hex(api->property_get_flags ? api->property_get_flags((void *)property) : 0),
                    @"getter": api->property_get_get_method ? zs_method_dict(api, api->property_get_get_method((void *)property)) : @{},
                    @"setter": api->property_get_set_method ? zs_method_dict(api, api->property_get_set_method((void *)property)) : @{}
                }];
                if (api->property_get_parent) propertyDict[@"parentPointer"] = zs_ptr(api->property_get_parent((void *)property));
                zs_append_json_object(propertiesJSON, propertyDict, propertyNeedsComma);
                currentPropertyCount++;
                (*propertyCount)++;
            }
        }
    }
    classDict[@"propertyCount"] = @(currentPropertyCount);

    if (api->class_get_events) {
        void *eventIter = NULL;
        NSMutableArray *events = [NSMutableArray array];
        const void *event = NULL;
        while ((event = api->class_get_events(klass, &eventIter))) [events addObject:@{ @"pointer": zs_ptr(event) }];
        classDict[@"eventCount"] = @(events.count);
        classDict[@"events"] = events;
    }

    zs_append_json_object(classesJSON, classDict, classNeedsComma);

    NSString *namespaceName = namespaze.length ? namespaze : [NSString stringWithFormat:@"__Assembly_%@", zs_safe_identifier(assemblyName)];
    NSString *className = zs_safe_identifier(name.length ? name : @"UnnamedClass");
    NSString *kindName = kind;
    NSString *classPrefix = [kindName isEqualToString:@"interface"] ? @"public interface" : ([kindName isEqualToString:@"enum"] ? @"public enum" : ([kindName isEqualToString:@"struct"] ? @"public struct" : @"public class"));
    zs_write_line(cs, [NSString stringWithFormat:@"namespace %@ {", zs_safe_identifier(namespaceName)]);
    NSString *parentName = parent ? zs_csharp_type(zs_string(api->class_get_name(parent))) : @"";
    if (parentName.length > 0 && [kindName isEqualToString:@"class"]) zs_write_line(cs, [NSString stringWithFormat:@"    %@ %@ : %@ {", classPrefix, className, parentName]);
    else zs_write_line(cs, [NSString stringWithFormat:@"    %@ %@ {", classPrefix, className]);
    for (NSDictionary *fieldDict in sourceFields) {
        NSString *fieldAccess = fieldDict[@"access"];
        if (fieldAccess.length == 0) fieldAccess = @"private";
        NSString *staticPart = [fieldDict[@"static"] boolValue] ? @" static" : @"";
        NSString *fieldType = zs_csharp_type(fieldDict[@"type"][@"name"] ?: @"object");
        zs_write_line(cs, [NSString stringWithFormat:@"        %@%@ %@ %@;", fieldAccess, staticPart, fieldType, zs_safe_identifier(fieldDict[@"name"] ?: @"field")]);
    }
    for (NSString *signature in sourceMethods) zs_write_line(cs, [NSString stringWithFormat:@"        %@", signature]);
    zs_write_line(cs, @"    }");
    zs_write_line(cs, @"}");
    zs_write_line(cs, @"");
}

static NSError *zs_dump_runtime(NSURL **outputURL) {
    NSError *error = nil;
    if (!zs_resolve_api(&error)) return error;
    void *domain = gAPI.domain_get();
    if (!domain) return [NSError errorWithDomain:@"ZSDumper" code:2 userInfo:@{NSLocalizedDescriptionKey: @"il2cpp_domain_get returned NULL."}];
    void *thread = gAPI.thread_current ? gAPI.thread_current() : NULL;
    BOOL attachedHere = NO;
    if (!thread) {
        thread = gAPI.thread_attach(domain);
        attachedHere = YES;
    }
    if (!thread) return [NSError errorWithDomain:@"ZSDumper" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Could not attach the dumper thread to the IL2CPP runtime."}];

    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) {
        if (attachedHere) gAPI.thread_detach(thread);
        return [NSError errorWithDomain:@"ZSDumper" code:4 userInfo:@{NSLocalizedDescriptionKey: @"The app Documents directory could not be resolved."}];
    }

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *folderPath = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSingularity-IL2CPP-Dump-%@", timestamp]];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&error]) {
        if (attachedHere) gAPI.thread_detach(thread);
        return error;
    }

    NSArray *jsonNames = @[@"assemblies.json", @"classes.json", @"methods.json", @"fields.json", @"properties.json"];
    NSMutableArray<NSFileHandle *> *handles = [NSMutableArray arrayWithCapacity:jsonNames.count];
    for (NSString *name in jsonNames) {
        NSString *path = [folderPath stringByAppendingPathComponent:name];
        [fm createFileAtPath:path contents:[NSData data] attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            for (NSFileHandle *opened in handles) [opened closeFile];
            if (attachedHere) gAPI.thread_detach(thread);
            return [NSError errorWithDomain:@"ZSDumper" code:5 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not open %@ for writing.", name]}];
        }
        [handle writeData:[@"[" dataUsingEncoding:NSUTF8StringEncoding]];
        [handles addObject:handle];
    }

    NSString *csPath = [folderPath stringByAppendingPathComponent:@"Dump.cs"];
    NSString *csvPath = [folderPath stringByAppendingPathComponent:@"Methods.csv"];
    NSString *indexPath = [folderPath stringByAppendingPathComponent:@"dump.json"];
    NSString *readmePath = [folderPath stringByAppendingPathComponent:@"README.txt"];
    [fm createFileAtPath:csPath contents:[NSData data] attributes:nil];
    [fm createFileAtPath:csvPath contents:[NSData data] attributes:nil];
    [fm createFileAtPath:indexPath contents:[NSData data] attributes:nil];
    [fm createFileAtPath:readmePath contents:[NSData data] attributes:nil];
    NSFileHandle *cs = [NSFileHandle fileHandleForWritingAtPath:csPath];
    NSFileHandle *csv = [NSFileHandle fileHandleForWritingAtPath:csvPath];
    if (!cs || !csv) {
        for (NSFileHandle *opened in handles) [opened closeFile];
        if (attachedHere) gAPI.thread_detach(thread);
        return [NSError errorWithDomain:@"ZSDumper" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Could not open generated source files for writing."}];
    }

    NSFileHandle *assembliesJSON = handles[0];
    NSFileHandle *classesJSON = handles[1];
    NSFileHandle *methodsJSON = handles[2];
    NSFileHandle *fieldsJSON = handles[3];
    NSFileHandle *propertiesJSON = handles[4];
    BOOL assembliesComma = NO;
    BOOL classesComma = NO;
    BOOL methodsComma = NO;
    BOOL fieldsComma = NO;
    BOOL propertiesComma = NO;
    size_t assemblyCount = 0;
    void **assemblies = gAPI.domain_get_assemblies(domain, &assemblyCount);
    NSUInteger classCount = 0;
    NSUInteger methodCount = 0;
    NSUInteger fieldCount = 0;
    NSUInteger propertyCount = 0;
    NSDate *started = [NSDate date];

    [csv writeData:[@"assembly,namespace,class,method,signature,token,methodInfo,nativePointer,nativeImage,rva,flags,implementationFlags,generic,inflated,instance\n" dataUsingEncoding:NSUTF8StringEncoding]];
    zs_write_line(cs, @"using System;");
    zs_write_line(cs, @"");

    for (size_t assemblyIndex = 0; assemblyIndex < assemblyCount; assemblyIndex++) {
        @autoreleasepool {
            const void *assembly = assemblies[assemblyIndex];
            const void *image = assembly ? gAPI.assembly_get_image(assembly) : NULL;
            if (!image) continue;
            NSString *assemblyName = zs_string(gAPI.image_get_name(image));
            NSString *filename = zs_string(gAPI.image_get_filename ? gAPI.image_get_filename(image) : NULL);
            size_t imageClassCount = gAPI.image_get_class_count(image);
            NSDictionary *assemblyDict = @{
                @"index": @(assemblyIndex),
                @"pointer": zs_ptr(assembly),
                @"imagePointer": zs_ptr(image),
                @"name": assemblyName,
                @"filename": filename,
                @"classCount": @(imageClassCount)
            };
            zs_append_json_object(assembliesJSON, assemblyDict, &assembliesComma);
            for (size_t classSlot = 0; classSlot < imageClassCount; classSlot++) {
                @autoreleasepool {
                    void *klass = (void *)gAPI.image_get_class(image, classSlot);
                    if (!klass) continue;
                    zs_write_class(&gAPI, klass, classCount, assemblyIndex, assemblyName, filename, classesJSON, methodsJSON, fieldsJSON, propertiesJSON, cs, csv, &classesComma, &methodsComma, &fieldsComma, &propertiesComma, &methodCount, &fieldCount, &propertyCount);
                    classCount++;
                }
            }
        }
    }

    [assembliesJSON writeData:[@"]" dataUsingEncoding:NSUTF8StringEncoding]];
    [classesJSON writeData:[@"]" dataUsingEncoding:NSUTF8StringEncoding]];
    [methodsJSON writeData:[@"]" dataUsingEncoding:NSUTF8StringEncoding]];
    [fieldsJSON writeData:[@"]" dataUsingEncoding:NSUTF8StringEncoding]];
    [propertiesJSON writeData:[@"]" dataUsingEncoding:NSUTF8StringEncoding]];
    for (NSFileHandle *handle in handles) [handle closeFile];
    [cs closeFile];
    [csv closeFile];

    NSDictionary *metadata = @{
        @"formatVersion": @3,
        @"generatedAt": [[ISO8601DateFormatter new] stringFromDate:[NSDate date]],
        @"processId": @([[NSProcessInfo processInfo] processIdentifier]),
        @"pointerSize": @(sizeof(void *)),
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"executablePath": NSBundle.mainBundle.executablePath ?: @"",
        @"mainBundlePath": NSBundle.mainBundle.bundlePath ?: @"",
        @"elapsedSeconds": @([[NSDate date] timeIntervalSinceDate:started]),
        @"counts": @{
            @"assemblies": @(assemblyCount),
            @"classes": @(classCount),
            @"methods": @(methodCount),
            @"fields": @(fieldCount),
            @"properties": @(propertyCount)
        },
        @"files": @{
            @"assemblies": @"assemblies.json",
            @"classes": @"classes.json",
            @"methods": @"methods.json",
            @"fields": @"fields.json",
            @"properties": @"properties.json",
            @"source": @"Dump.cs",
            @"methodsCSV": @"Methods.csv",
            @"loadedImages": @"loaded-images.json"
        },
        @"api": @{
            @"methodGetPointer": @(gAPI.method_get_pointer != NULL),
            @"classGetProperties": @(gAPI.class_get_properties != NULL),
            @"classGetEvents": @(gAPI.class_get_events != NULL),
            @"typeAssemblyQualifiedName": @(gAPI.type_get_assembly_qualified_name != NULL),
            @"typeStatic": @(gAPI.type_is_static != NULL),
            @"typePointerType": @(gAPI.type_is_pointer_type != NULL)
        }
    };

    NSData *metadataData = [zs_json(metadata) dataUsingEncoding:NSUTF8StringEncoding];
    [metadataData writeToFile:indexPath atomically:YES];

    NSMutableString *readme = [NSMutableString stringWithFormat:@"ZSingularity IL2CPP Runtime Dump\n\nGenerated: %@\nAssemblies: %lu\nClasses: %lu\nMethods: %lu\nFields: %lu\nProperties: %lu\nPointer size: %lu\n\nFiles:\nassemblies.json\nclasses.json\nmethods.json\nfields.json\nproperties.json\nDump.cs\nMethods.csv\nloaded-images.json\ndump.json\n\nMethod native addresses come from il2cpp_method_get_pointer when that export exists; otherwise MethodInfo[0] is used as a compatibility fallback.\n", metadata[@"generatedAt"], (unsigned long)assemblyCount, (unsigned long)classCount, (unsigned long)methodCount, (unsigned long)fieldCount, (unsigned long)propertyCount, (unsigned long)sizeof(void *)];
    [readme writeToFile:readmePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSMutableArray *loadedImages = [NSMutableArray array];
    uint32_t loadedImageCount = _dyld_image_count();
    for (uint32_t i = 0; i < loadedImageCount; i++) {
        [loadedImages addObject:@{
            @"index": @(i),
            @"path": zs_string(_dyld_get_image_name(i)),
            @"header": zs_ptr(_dyld_get_image_header(i)),
            @"slide": zs_hex((uint64_t)_dyld_get_image_vmaddr_slide(i))
        }];
    }
    NSData *loadedImageData = [zs_json(loadedImages) dataUsingEncoding:NSUTF8StringEncoding];
    [loadedImageData writeToFile:[folderPath stringByAppendingPathComponent:@"loaded-images.json"] atomically:YES];

    if (attachedHere) gAPI.thread_detach(thread);
    if (outputURL) *outputURL = [NSURL fileURLWithPath:folderPath isDirectory:YES];
    return nil;
}

@implementation ZSDumper

+ (void)initialize {
    if (self == [ZSDumper class]) gRuntimeLock = [NSLock new];
}

+ (void)dumpIL2CPPToDocumentsWithCompletion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    [gRuntimeLock lock];
    if (gRunning) {
        [gRuntimeLock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, [NSError errorWithDomain:@"ZSDumper" code:7 userInfo:@{NSLocalizedDescriptionKey: @"An IL2CPP dump is already running."}]);
        });
        return;
    }
    gRunning = YES;
    [gRuntimeLock unlock];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSURL *url = nil;
            NSError *error = zs_dump_runtime(&url);
            [gRuntimeLock lock];
            gRunning = NO;
            [gRuntimeLock unlock];
            if (error) ZLog(@"[ZSDumper] failed: %@", error.localizedDescription);
            else ZLog(@"[ZSDumper] completed: %@", url.path);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(url, error);
            });
        }
    });
}

@end
