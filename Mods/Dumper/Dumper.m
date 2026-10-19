#import "Dumper.h"
#import <dlfcn.h>
#import <copyfile.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <string.h>
#import "ZTweakLog.h"
#import "ScriptDump.h"

typedef void *(*zs_domain_get_fn)(void);
typedef void **(*zs_domain_get_assemblies_fn)(const void *, size_t *);
typedef const void *(*zs_assembly_get_image_fn)(const void *);
typedef const char *(*zs_image_get_name_fn)(const void *);
typedef size_t (*zs_image_get_class_count_fn)(const void *);
typedef const void *(*zs_image_get_class_fn)(const void *, size_t);
typedef void *(*zs_thread_current_fn)(void);
typedef void *(*zs_thread_attach_fn)(void *);
typedef void (*zs_thread_detach_fn)(void *);

typedef const char *(*zs_class_get_name_fn)(void *);
typedef const char *(*zs_class_get_namespace_fn)(void *);
typedef void *(*zs_class_get_parent_fn)(void *);
typedef const void *(*zs_class_get_type_fn)(void *);
typedef int32_t (*zs_class_instance_size_fn)(void *);
typedef bool (*zs_class_is_valuetype_fn)(const void *);
typedef int (*zs_class_get_flags_fn)(const void *);
typedef bool (*zs_class_is_interface_fn)(const void *);
typedef bool (*zs_class_is_enum_fn)(const void *);
typedef bool (*zs_class_is_generic_fn)(const void *);
typedef uint32_t (*zs_class_get_type_token_fn)(void *);
typedef void *(*zs_class_get_fields_fn)(void *, void **);
typedef void *(*zs_class_get_methods_fn)(void *, void **);
typedef void *(*zs_class_get_interfaces_fn)(void *, void **);
typedef const void *(*zs_class_get_properties_fn)(void *, void **);
typedef const void *(*zs_class_get_events_fn)(void *, void **);

typedef const char *(*zs_method_get_name_fn)(const void *);
typedef const void *(*zs_method_get_return_type_fn)(const void *);
typedef uint32_t (*zs_method_get_param_count_fn)(const void *);
typedef const void *(*zs_method_get_param_fn)(const void *, uint32_t);
typedef const char *(*zs_method_get_param_name_fn)(const void *, uint32_t);
typedef uint32_t (*zs_method_get_flags_fn)(const void *, uint32_t *);
typedef uint32_t (*zs_method_get_token_fn)(const void *);
typedef bool (*zs_method_is_generic_fn)(const void *);
typedef void *(*zs_method_get_pointer_fn)(const void *);

typedef int (*zs_field_get_flags_fn)(void *);
typedef const char *(*zs_field_get_name_fn)(void *);
typedef size_t (*zs_field_get_offset_fn)(void *);
typedef const void *(*zs_field_get_type_fn)(void *);

typedef const void *(*zs_property_get_get_method_fn)(void *);
typedef const void *(*zs_property_get_set_method_fn)(void *);
typedef const char *(*zs_property_get_name_fn)(void *);

typedef const char *(*zs_event_get_name_fn)(const void *);

typedef char *(*zs_type_get_name_fn)(const void *);
typedef void (*zs_memory_free_fn)(void *);

typedef struct {
    zs_domain_get_fn domain_get;
    zs_domain_get_assemblies_fn domain_get_assemblies;
    zs_assembly_get_image_fn assembly_get_image;
    zs_image_get_name_fn image_get_name;
    zs_image_get_class_count_fn image_get_class_count;
    zs_image_get_class_fn image_get_class;
    zs_thread_current_fn thread_current;
    zs_thread_attach_fn thread_attach;
    zs_thread_detach_fn thread_detach;
    zs_class_get_name_fn class_get_name;
    zs_class_get_namespace_fn class_get_namespace;
    zs_class_get_parent_fn class_get_parent;
    zs_class_get_type_fn class_get_type;
    zs_class_instance_size_fn class_instance_size;
    zs_class_is_valuetype_fn class_is_valuetype;
    zs_class_get_flags_fn class_get_flags;
    zs_class_is_interface_fn class_is_interface;
    zs_class_is_enum_fn class_is_enum;
    zs_class_is_generic_fn class_is_generic;
    zs_class_get_type_token_fn class_get_type_token;
    zs_class_get_fields_fn class_get_fields;
    zs_class_get_methods_fn class_get_methods;
    zs_class_get_interfaces_fn class_get_interfaces;
    zs_class_get_properties_fn class_get_properties;
    zs_class_get_events_fn class_get_events;
    zs_method_get_name_fn method_get_name;
    zs_method_get_return_type_fn method_get_return_type;
    zs_method_get_param_count_fn method_get_param_count;
    zs_method_get_param_fn method_get_param;
    zs_method_get_param_name_fn method_get_param_name;
    zs_method_get_flags_fn method_get_flags;
    zs_method_get_token_fn method_get_token;
    zs_method_is_generic_fn method_is_generic;
    zs_method_get_pointer_fn method_get_pointer;
    zs_field_get_flags_fn field_get_flags;
    zs_field_get_name_fn field_get_name;
    zs_field_get_offset_fn field_get_offset;
    zs_field_get_type_fn field_get_type;
    zs_property_get_get_method_fn property_get_get_method;
    zs_property_get_set_method_fn property_get_set_method;
    zs_property_get_name_fn property_get_name;
    zs_event_get_name_fn event_get_name;
    zs_type_get_name_fn type_get_name;
    zs_memory_free_fn memory_free;
} ZSRuntimeAPI;

static ZSRuntimeAPI gAPI;
static BOOL gResolved;
static BOOL gRunning;
static BOOL gCancel;
static BOOL gWriteBodies = YES;
static NSDictionary *gLastSummary;
static NSURL *gLastOutput;
static NSLock *gRuntimeLock;

static const NSUInteger kZSWriterFlushThreshold = 1 << 18;
static const NSUInteger kZSDumpThreadStackSize = 16 * 1024 * 1024;
static const uint64_t kZSMaxBodySize = 1 << 22;

static NSError *zs_dump_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"ZSDumper" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface ZSDumpWriter : NSObject
@property (nonatomic, readonly, nullable) NSError *error;
@property (nonatomic, readonly) uint64_t written;
+ (nullable instancetype)writerWithPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (void)appendString:(NSString *)string;
- (void)appendBytes:(const void *)bytes length:(NSUInteger)length;
- (void)finish;
@end

@implementation ZSDumpWriter {
    NSFileHandle *_handle;
    NSMutableData *_buffer;
    NSError *_error;
    uint64_t _written;
}

@synthesize error = _error;
@synthesize written = _written;

+ (instancetype)writerWithPath:(NSString *)path error:(NSError * _Nullable *)error {
    if (![NSFileManager.defaultManager createFileAtPath:path contents:[NSData data] attributes:nil]) {
        if (error) *error = zs_dump_error(5, [NSString stringWithFormat:@"Could not create %@.", path.lastPathComponent]);
        return nil;
    }
    NSError *openError = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:path] error:&openError];
    if (!handle) {
        if (error) *error = openError ?: zs_dump_error(5, [NSString stringWithFormat:@"Could not open %@ for writing.", path.lastPathComponent]);
        return nil;
    }
    ZSDumpWriter *writer = [ZSDumpWriter new];
    writer->_handle = handle;
    writer->_buffer = [NSMutableData dataWithCapacity:kZSWriterFlushThreshold + 4096];
    return writer;
}

- (void)flush {
    if (_buffer.length == 0) return;
    if (!_error && _handle) {
        NSError *writeError = nil;
        if (![_handle writeData:_buffer error:&writeError]) {
            _error = writeError ?: zs_dump_error(8, @"Writing dump data failed.");
        }
    }
    [_buffer setLength:0];
}

- (void)appendBytes:(const void *)bytes length:(NSUInteger)length {
    if (_error || length == 0) return;
    [_buffer appendBytes:bytes length:length];
    _written += length;
    if (_buffer.length >= kZSWriterFlushThreshold) [self flush];
}

- (void)appendString:(NSString *)string {
    if (string.length == 0) return;
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    if (data) [self appendBytes:data.bytes length:data.length];
}

- (void)finish {
    if (!_handle) return;
    [self flush];
    NSError *closeError = nil;
    if (![_handle closeAndReturnError:&closeError] && !_error) _error = closeError;
    _handle = nil;
}

@end

static void *zs_symbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

#define ZS_RESOLVE(name) gAPI.name = (typeof(gAPI.name))zs_symbol("il2cpp_" #name)

static BOOL zs_resolve_api(NSError **error) {
    if (gResolved) return YES;
    ZS_RESOLVE(domain_get);
    ZS_RESOLVE(domain_get_assemblies);
    ZS_RESOLVE(assembly_get_image);
    ZS_RESOLVE(image_get_name);
    ZS_RESOLVE(image_get_class_count);
    ZS_RESOLVE(image_get_class);
    ZS_RESOLVE(thread_current);
    ZS_RESOLVE(thread_attach);
    ZS_RESOLVE(thread_detach);
    ZS_RESOLVE(class_get_name);
    ZS_RESOLVE(class_get_namespace);
    ZS_RESOLVE(class_get_parent);
    ZS_RESOLVE(class_get_type);
    ZS_RESOLVE(class_instance_size);
    ZS_RESOLVE(class_is_valuetype);
    ZS_RESOLVE(class_get_flags);
    ZS_RESOLVE(class_is_interface);
    ZS_RESOLVE(class_is_enum);
    ZS_RESOLVE(class_is_generic);
    ZS_RESOLVE(class_get_type_token);
    ZS_RESOLVE(class_get_fields);
    ZS_RESOLVE(class_get_methods);
    ZS_RESOLVE(class_get_interfaces);
    ZS_RESOLVE(class_get_properties);
    ZS_RESOLVE(class_get_events);
    ZS_RESOLVE(method_get_name);
    ZS_RESOLVE(method_get_return_type);
    ZS_RESOLVE(method_get_param_count);
    ZS_RESOLVE(method_get_param);
    ZS_RESOLVE(method_get_param_name);
    ZS_RESOLVE(method_get_flags);
    ZS_RESOLVE(method_get_token);
    ZS_RESOLVE(method_is_generic);
    ZS_RESOLVE(method_get_pointer);
    ZS_RESOLVE(field_get_flags);
    ZS_RESOLVE(field_get_name);
    ZS_RESOLVE(field_get_offset);
    ZS_RESOLVE(field_get_type);
    ZS_RESOLVE(property_get_get_method);
    ZS_RESOLVE(property_get_set_method);
    ZS_RESOLVE(property_get_name);
    ZS_RESOLVE(event_get_name);
    ZS_RESOLVE(type_get_name);
    gAPI.memory_free = (zs_memory_free_fn)zs_symbol("il2cpp_free");

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
                    gAPI.type_get_name;
    if (!required) {
        if (error) *error = zs_dump_error(1, @"The loaded IL2CPP runtime is missing required reflection exports.");
        return NO;
    }
    gResolved = YES;
    return YES;
}

static NSString *zs_string(const char *value) {
    if (!value) return @"";
    return [NSString stringWithUTF8String:value] ?: @"";
}

static NSString *zs_take_string(const ZSRuntimeAPI *api, char *value) {
    if (!value) return @"";
    NSString *result = zs_string(value);
    if (api->memory_free) api->memory_free(value);
    return result;
}

static NSString *zs_json(id object) {
    if (![NSJSONSerialization isValidJSONObject:object]) return @"null";
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:&error];
    NSString *string = (!error && data) ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    return string ?: @"null";
}

static NSString *zs_access(uint32_t flags) {
    switch (flags & 0x7) {
        case 2: return @"private protected";
        case 3: return @"internal";
        case 4: return @"protected";
        case 5: return @"protected internal";
        case 6: return @"public";
        default: return @"private";
    }
}

static int zs_access_rank(uint32_t flags) {
    static const int ranks[8] = {0, 1, 2, 3, 3, 4, 5, 0};
    return ranks[flags & 0x7];
}

static NSString *zs_accessor(uint32_t flags, uint32_t primaryFlags, NSString *keyword) {
    if ((flags & 0x7) == (primaryFlags & 0x7)) return keyword;
    return [NSString stringWithFormat:@"%@ %@", zs_access(flags), keyword];
}

static NSString *zs_type_visibility(int flags) {
    switch (flags & 0x7) {
        case 0: return @"internal";
        case 1: return @"public";
        case 2: return @"public";
        case 3: return @"private";
        case 4: return @"protected";
        case 5: return @"internal";
        case 6: return @"private protected";
        default: return @"protected internal";
    }
}

static NSString *zs_csharp_type(NSString *typeName) {
    if (typeName.length == 0) return @"void";
    static NSDictionary<NSString *, NSString *> *aliases;
    static NSRegularExpression *systemTypeExpression;
    static NSRegularExpression *arityExpression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        aliases = @{@"Void": @"void", @"Boolean": @"bool", @"Byte": @"byte", @"SByte": @"sbyte", @"Char": @"char", @"Double": @"double", @"Single": @"float", @"Int16": @"short", @"UInt16": @"ushort", @"Int32": @"int", @"UInt32": @"uint", @"Int64": @"long", @"UInt64": @"ulong", @"String": @"string", @"Object": @"object", @"Decimal": @"decimal"};
        systemTypeExpression = [NSRegularExpression regularExpressionWithPattern:@"(?<![A-Za-z0-9_.])System\\.([A-Za-z0-9_]+)(?![A-Za-z0-9_.])" options:0 error:nil];
        arityExpression = [NSRegularExpression regularExpressionWithPattern:@"`[0-9]+" options:0 error:nil];
    });
    NSMutableString *result = [typeName mutableCopy];
    NSArray<NSTextCheckingResult *> *matches = [systemTypeExpression matchesInString:result options:0 range:NSMakeRange(0, result.length)];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSString *simpleName = [result substringWithRange:[match rangeAtIndex:1]];
        [result replaceCharactersInRange:match.range withString:aliases[simpleName] ?: simpleName];
    }
    [arityExpression replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    return [result copy];
}

static BOOL zs_safe_copy(uintptr_t source, void *destination, size_t length) {
    vm_size_t copied = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(), (vm_address_t)source, (vm_size_t)length, (vm_address_t)destination, &copied);
    return result == KERN_SUCCESS && copied == length;
}

@interface ZSModule : NSObject
@property (nonatomic) NSUInteger index;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) uintptr_t base;
@property (nonatomic) intptr_t slide;
@property (nonatomic) uintptr_t textStart;
@property (nonatomic) uintptr_t textEnd;
@property (nonatomic, strong) NSData *starts;
+ (nullable instancetype)moduleAtBase:(const void *)base path:(nullable const char *)path index:(NSUInteger)index;
- (BOOL)containsAddress:(uintptr_t)address;
- (uint64_t)sizeOfFunctionAt:(uintptr_t)address;
@end

@implementation ZSModule

+ (instancetype)moduleAtBase:(const void *)base path:(const char *)path index:(NSUInteger)index {
    const struct mach_header_64 *header = (const struct mach_header_64 *)base;
    if (header->magic != MH_MAGIC_64) return nil;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    uint64_t textVM = 0;
    uint64_t textSize = 0;
    uint64_t linkVM = 0;
    uint64_t linkOffset = 0;
    uint32_t startsOffset = 0;
    uint32_t startsSize = 0;
    BOOL hasText = NO;
    BOOL hasLink = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, "__TEXT", 16) == 0) {
                textVM = segment->vmaddr;
                textSize = segment->vmsize;
                hasText = YES;
            } else if (strncmp(segment->segname, "__LINKEDIT", 16) == 0) {
                linkVM = segment->vmaddr;
                linkOffset = segment->fileoff;
                hasLink = YES;
            }
        } else if (command->cmd == LC_FUNCTION_STARTS) {
            const struct linkedit_data_command *data = (const struct linkedit_data_command *)command;
            startsOffset = data->dataoff;
            startsSize = data->datasize;
        }
        cursor += command->cmdsize;
    }
    if (!hasText) return nil;

    ZSModule *module = [ZSModule new];
    module.index = index;
    module.path = zs_string(path);
    module.base = (uintptr_t)base;
    module.slide = (intptr_t)((uintptr_t)base - (uintptr_t)textVM);
    module.textStart = (uintptr_t)base;
    module.textEnd = (uintptr_t)base + (uintptr_t)textSize;

    NSMutableData *starts = [NSMutableData data];
    if (hasLink && startsSize > 0 && startsOffset >= linkOffset) {
        NSMutableData *raw = [NSMutableData dataWithLength:startsSize];
        uintptr_t source = (uintptr_t)module.slide + (uintptr_t)linkVM + (uintptr_t)(startsOffset - linkOffset);
        if (zs_safe_copy(source, raw.mutableBytes, startsSize)) {
            const uint8_t *p = raw.bytes;
            const uint8_t *end = p + startsSize;
            uintptr_t address = (uintptr_t)textVM + (uintptr_t)module.slide;
            while (p < end && *p) {
                uint64_t delta = 0;
                unsigned shift = 0;
                uint8_t byte;
                do {
                    byte = *p++;
                    delta |= (uint64_t)(byte & 0x7f) << shift;
                    shift += 7;
                } while ((byte & 0x80) && p < end && shift < 64);
                address += (uintptr_t)delta;
                [starts appendBytes:&address length:sizeof(address)];
            }
        }
    }
    module.starts = starts;
    return module;
}

- (BOOL)containsAddress:(uintptr_t)address {
    return address >= _textStart && address < _textEnd;
}

- (uint64_t)sizeOfFunctionAt:(uintptr_t)address {
    const uintptr_t *list = (const uintptr_t *)_starts.bytes;
    NSUInteger count = _starts.length / sizeof(uintptr_t);
    NSUInteger low = 0;
    NSUInteger high = count;
    while (low < high) {
        NSUInteger mid = low + (high - low) / 2;
        if (list[mid] <= address) low = mid + 1;
        else high = mid;
    }
    uintptr_t end = low < count ? list[low] : _textEnd;
    if (end > _textEnd) end = _textEnd;
    return end > address ? (uint64_t)(end - address) : 0;
}

@end

@interface ZSDumpSession : NSObject
@property (nonatomic, readonly) NSMutableArray<ZSModule *> *modules;
@property (nonatomic, readonly) NSUInteger classCount;
@property (nonatomic, readonly) NSUInteger methodCount;
@property (nonatomic, readonly) NSUInteger fieldCount;
@property (nonatomic, readonly) NSUInteger propertyCount;
@property (nonatomic, readonly) NSUInteger eventCount;
@property (nonatomic, readonly) NSUInteger bodyCount;
@property (nonatomic, readonly) uint64_t bodyBytes;
- (instancetype)initWithSource:(ZSDumpWriter *)source bodies:(ZSDumpWriter *)bodies;
- (void)beginAssembly:(NSString *)name;
- (void)writeClass:(void *)klass;
@end

@implementation ZSDumpSession {
    ZSDumpWriter *_source;
    ZSDumpWriter *_bodies;
    NSMutableDictionary<NSNumber *, NSString *> *_typeNames;
    NSMutableDictionary<NSNumber *, NSString *> *_bodyNotes;
    NSMutableSet<NSNumber *> *_rejectedBases;
    NSMutableData *_scratch;
}

@synthesize modules = _modules;
@synthesize classCount = _classCount;
@synthesize methodCount = _methodCount;
@synthesize fieldCount = _fieldCount;
@synthesize propertyCount = _propertyCount;
@synthesize eventCount = _eventCount;
@synthesize bodyCount = _bodyCount;
@synthesize bodyBytes = _bodyBytes;

- (instancetype)initWithSource:(ZSDumpWriter *)source bodies:(ZSDumpWriter *)bodies {
    self = [super init];
    if (!self) return nil;
    _source = source;
    _bodies = bodies;
    _modules = [NSMutableArray array];
    _typeNames = [NSMutableDictionary dictionaryWithCapacity:65536];
    _bodyNotes = [NSMutableDictionary dictionaryWithCapacity:65536];
    _rejectedBases = [NSMutableSet set];
    _scratch = [NSMutableData data];
    return self;
}

- (NSString *)typeName:(const void *)type fallback:(NSString *)fallback {
    if (!type) return fallback;
    NSNumber *key = @((uintptr_t)type);
    NSString *cached = _typeNames[key];
    if (cached) return cached;
    NSString *name = zs_csharp_type(zs_take_string(&gAPI, gAPI.type_get_name(type)));
    _typeNames[key] = name;
    return name;
}

- (NSString *)className:(void *)klass {
    const ZSRuntimeAPI *api = &gAPI;
    const void *type = api->class_get_type ? api->class_get_type(klass) : NULL;
    if (type) return [self typeName:type fallback:@"object"];
    NSString *name = zs_string(api->class_get_name(klass));
    NSString *namespaze = zs_string(api->class_get_namespace(klass));
    return namespaze.length ? [NSString stringWithFormat:@"%@.%@", namespaze, name] : name;
}

- (ZSModule *)moduleContaining:(uintptr_t)address {
    for (ZSModule *module in _modules) {
        if ([module containsAddress:address]) return module;
    }
    Dl_info info = {0};
    if (dladdr((const void *)address, &info) == 0 || !info.dli_fbase) return nil;
    uintptr_t base = (uintptr_t)info.dli_fbase;
    for (ZSModule *module in _modules) {
        if (module.base == base) return nil;
    }
    NSNumber *baseKey = @(base);
    if ([_rejectedBases containsObject:baseKey]) return nil;
    ZSModule *module = [ZSModule moduleAtBase:info.dli_fbase path:info.dli_fname index:_modules.count];
    if (!module) {
        [_rejectedBases addObject:baseKey];
        return nil;
    }
    [_modules addObject:module];
    return [module containsAddress:address] ? module : nil;
}

- (NSString *)bodyNote:(void *)pointer {
    if (!pointer) return @"";
    NSNumber *key = @((uintptr_t)pointer);
    NSString *cached = _bodyNotes[key];
    if (cached) return cached;

    uintptr_t address = (uintptr_t)pointer;
    NSString *note = @"";
    ZSModule *module = [self moduleContaining:address];
    if (module) {
        uint64_t virtualAddress = (uint64_t)(address - (uintptr_t)module.slide);
        NSMutableString *built = [NSMutableString stringWithFormat:@"VA 0x%llx", (unsigned long long)virtualAddress];
        if (module.index > 0) [built appendFormat:@" Module %lu", (unsigned long)module.index];
        uint64_t size = [module sizeOfFunctionAt:address];
        if (gWriteBodies && size > 0 && size <= kZSMaxBodySize) {
            if (_scratch.length < size) [_scratch setLength:(NSUInteger)size];
            if (zs_safe_copy(address, _scratch.mutableBytes, (size_t)size)) {
                uint64_t offset = _bodies.written;
                [_bodies appendBytes:_scratch.bytes length:(NSUInteger)size];
                [built appendFormat:@" Size 0x%llx Body 0x%llx", (unsigned long long)size, (unsigned long long)offset];
                _bodyCount++;
                _bodyBytes += size;
            }
        }
        note = built;
    }
    _bodyNotes[key] = note;
    return note;
}

- (NSString *)methodLine:(const void *)method {
    const ZSRuntimeAPI *api = &gAPI;
    uint32_t implementationFlags = 0;
    uint32_t flags = api->method_get_flags(method, &implementationFlags);

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:6];
    [parts addObject:zs_access(flags)];
    if (flags & 0x10) [parts addObject:@"static"];
    if (flags & 0x400) {
        [parts addObject:@"abstract"];
    } else if (flags & 0x40) {
        if (flags & 0x100) {
            [parts addObject:@"virtual"];
        } else {
            if (flags & 0x20) [parts addObject:@"sealed"];
            [parts addObject:@"override"];
        }
    }

    NSString *returnName = [self typeName:api->method_get_return_type(method) fallback:@"void"];
    uint32_t count = api->method_get_param_count(method);
    NSMutableArray<NSString *> *parameters = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        NSString *typeName = [self typeName:api->method_get_param(method, i) fallback:@"object"];
        NSString *parameterName = api->method_get_param_name ? zs_string(api->method_get_param_name(method, i)) : @"";
        if (parameterName.length == 0) parameterName = [NSString stringWithFormat:@"arg%u", i];
        [parameters addObject:[NSString stringWithFormat:@"%@ %@", typeName, parameterName]];
    }

    NSMutableString *tail = [NSMutableString stringWithFormat:@"0x%x", api->method_get_token(method)];
    if (api->method_is_generic && api->method_is_generic(method)) [tail appendString:@" generic"];
    if (implementationFlags) [tail appendFormat:@" Impl 0x%x", implementationFlags];
    void *pointer = api->method_get_pointer ? api->method_get_pointer(method) : *(void * const *)method;
    NSString *note = [self bodyNote:pointer];
    if (note.length) [tail appendFormat:@" %@", note];

    return [NSString stringWithFormat:@"\t%@ %@ %@(%@); // %@\n", [parts componentsJoinedByString:@" "], returnName, zs_string(api->method_get_name(method)), [parameters componentsJoinedByString:@", "], tail];
}

- (NSString *)propertyLine:(const void *)property {
    const ZSRuntimeAPI *api = &gAPI;
    const void *getter = api->property_get_get_method ? api->property_get_get_method((void *)property) : NULL;
    const void *setter = api->property_get_set_method ? api->property_get_set_method((void *)property) : NULL;
    if (!getter && !setter) return nil;

    uint32_t getterFlags = getter ? api->method_get_flags(getter, NULL) : 0;
    uint32_t setterFlags = setter ? api->method_get_flags(setter, NULL) : 0;
    BOOL useGetter = getter && (!setter || zs_access_rank(getterFlags) >= zs_access_rank(setterFlags));
    uint32_t primaryFlags = useGetter ? getterFlags : setterFlags;

    const void *type = NULL;
    if (getter) {
        type = api->method_get_return_type(getter);
    } else {
        uint32_t count = api->method_get_param_count(setter);
        if (count > 0) type = api->method_get_param(setter, count - 1);
    }

    NSString *access = zs_access(primaryFlags);
    NSMutableArray<NSString *> *accessors = [NSMutableArray arrayWithCapacity:2];
    if (getter) [accessors addObject:zs_accessor(getterFlags, primaryFlags, @"get;")];
    if (setter) [accessors addObject:zs_accessor(setterFlags, primaryFlags, @"set;")];

    return [NSString stringWithFormat:@"\t%@%@ %@ %@ { %@ }\n", access, (primaryFlags & 0x10) ? @" static" : @"", [self typeName:type fallback:@"object"], zs_string(api->property_get_name ? api->property_get_name((void *)property) : NULL), [accessors componentsJoinedByString:@" "]];
}

- (void)beginAssembly:(NSString *)name {
    [_source appendString:[NSString stringWithFormat:@"// Assembly %@\n\n", name]];
}

- (void)writeClass:(void *)klass {
    const ZSRuntimeAPI *api = &gAPI;
    int flags = api->class_get_flags ? api->class_get_flags(klass) : 0;
    BOOL isInterface = api->class_is_interface ? api->class_is_interface(klass) : ((flags & 0x20) != 0);
    BOOL isEnum = !isInterface && api->class_is_enum && api->class_is_enum(klass);
    BOOL isStruct = !isInterface && !isEnum && api->class_is_valuetype && api->class_is_valuetype(klass);
    NSString *kind = isInterface ? @"interface" : (isEnum ? @"enum" : (isStruct ? @"struct" : @"class"));

    NSMutableArray<NSString *> *modifiers = [NSMutableArray arrayWithCapacity:4];
    [modifiers addObject:zs_type_visibility(flags)];
    if (!isInterface && !isEnum && !isStruct) {
        BOOL abstract = (flags & 0x80) != 0;
        BOOL sealed = (flags & 0x100) != 0;
        if (abstract && sealed) [modifiers addObject:@"static"];
        else if (abstract) [modifiers addObject:@"abstract"];
        else if (sealed) [modifiers addObject:@"sealed"];
    }
    [modifiers addObject:kind];

    NSMutableArray<NSString *> *bases = [NSMutableArray array];
    if (!isInterface && !isEnum && !isStruct && api->class_get_parent) {
        void *parent = api->class_get_parent(klass);
        if (parent) {
            NSString *parentName = [self className:parent];
            if (![parentName isEqualToString:@"object"]) [bases addObject:parentName];
        }
    }
    if (api->class_get_interfaces) {
        void *interfaceIterator = NULL;
        void *interfaceClass = NULL;
        while ((interfaceClass = api->class_get_interfaces(klass, &interfaceIterator))) [bases addObject:[self className:interfaceClass]];
    }

    NSMutableString *info = [NSMutableString stringWithFormat:@"// 0x%x Size 0x%x", api->class_get_type_token ? api->class_get_type_token(klass) : 0, (uint32_t)(api->class_instance_size ? api->class_instance_size(klass) : 0)];
    if (api->class_is_generic && api->class_is_generic(klass)) [info appendString:@" generic"];

    NSMutableString *out = [NSMutableString stringWithCapacity:2048];
    [out appendFormat:@"%@\n%@ %@", info, [modifiers componentsJoinedByString:@" "], [self className:klass]];
    if (bases.count) [out appendFormat:@" : %@", [bases componentsJoinedByString:@", "]];
    [out appendString:@"\n{\n"];

    NSMutableString *fields = [NSMutableString string];
    if (api->class_get_fields) {
        void *fieldIterator = NULL;
        void *field = NULL;
        while ((field = api->class_get_fields(klass, &fieldIterator))) {
            @autoreleasepool {
                uint32_t fieldFlags = (uint32_t)api->field_get_flags(field);
                BOOL literal = (fieldFlags & 0x40) != 0;
                [fields appendFormat:@"\t%@%@%@%@ %@ %@;", zs_access(fieldFlags), (fieldFlags & 0x10) ? @" static" : @"", literal ? @" const" : @"", (!literal && (fieldFlags & 0x20)) ? @" readonly" : @"", [self typeName:api->field_get_type(field) fallback:@"object"], zs_string(api->field_get_name(field))];
                if (!literal) [fields appendFormat:@" // 0x%x", (uint32_t)api->field_get_offset(field)];
                [fields appendString:@"\n"];
                _fieldCount++;
            }
        }
    }
    if (fields.length) [out appendFormat:@"\t// Fields\n%@", fields];

    NSMutableString *properties = [NSMutableString string];
    if (api->class_get_properties) {
        void *propertyIterator = NULL;
        const void *property = NULL;
        while ((property = api->class_get_properties(klass, &propertyIterator))) {
            @autoreleasepool {
                NSString *line = [self propertyLine:property];
                if (!line) continue;
                [properties appendString:line];
                _propertyCount++;
            }
        }
    }
    if (properties.length) [out appendFormat:@"\t// Properties\n%@", properties];

    NSMutableString *events = [NSMutableString string];
    if (api->class_get_events && api->event_get_name) {
        void *eventIterator = NULL;
        const void *event = NULL;
        while ((event = api->class_get_events(klass, &eventIterator))) {
            [events appendFormat:@"\tevent %@;\n", zs_string(api->event_get_name(event))];
            _eventCount++;
        }
    }
    if (events.length) [out appendFormat:@"\t// Events\n%@", events];

    NSMutableString *methods = [NSMutableString string];
    void *methodIterator = NULL;
    const void *method = NULL;
    while ((method = api->class_get_methods(klass, &methodIterator))) {
        @autoreleasepool {
            [methods appendString:[self methodLine:method]];
            _methodCount++;
        }
    }
    if (methods.length) [out appendFormat:@"\t// Methods\n%@", methods];

    [out appendString:@"}\n\n"];
    [_source appendString:out];
    _classCount++;
}

@end

static BOOL zs_any_writer_failed(NSArray<ZSDumpWriter *> *writers) {
    for (ZSDumpWriter *writer in writers) {
        if (writer.error) return YES;
    }
    return NO;
}

static NSString *zs_unity_framework_path(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *frameworkDirectory = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/UnityFramework.framework"];
    NSString *executable = [NSBundle bundleWithPath:frameworkDirectory].executablePath;
    if (executable.length && [fm fileExistsAtPath:executable]) return executable;
    NSString *fallback = [frameworkDirectory stringByAppendingPathComponent:@"UnityFramework"];
    if ([fm fileExistsAtPath:fallback]) return fallback;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        NSString *path = zs_string(_dyld_get_image_name(i));
        if ([path hasSuffix:@"/UnityFramework.framework/UnityFramework"] && [fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

static NSString *zs_global_metadata_path(void) {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Data/Managed/Metadata/global-metadata.dat"];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? path : nil;
}

static BOOL zs_copy_file(NSString *source, NSString *destination) {
    if (source.length == 0) return NO;
    int result = copyfile(source.fileSystemRepresentation, destination.fileSystemRepresentation, NULL, COPYFILE_DATA | COPYFILE_CLONE);
    if (result != 0) ZLog(@"[ZSDumper] copy failed (%d): %@", errno, source.lastPathComponent);
    return result == 0;
}

static NSError *zs_dump_attached(void *domain, ZSDumpOptions *options, ZSDumpProgress progress, ZSDumpLog logf, NSURL **outputURL) {
    gWriteBodies = options.dumpBodies;
    NSMutableDictionary *scriptSummary = nil;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) return zs_dump_error(4, @"The app Documents directory could not be resolved.");

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *folderPath = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"ZSingularity-IL2CPP-Dump-%@", timestamp]];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    if (![fm createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&error]) {
        return error ?: zs_dump_error(5, @"Could not create the dump folder.");
    }

    NSArray<NSString *> *fileNames = options.dumpSource ? @[@"Dump.cs", @"Bodies.bin"] : @[];
    NSMutableArray<ZSDumpWriter *> *writers = [NSMutableArray arrayWithCapacity:fileNames.count];
    for (NSString *fileName in fileNames) {
        NSError *openError = nil;
        ZSDumpWriter *writer = [ZSDumpWriter writerWithPath:[folderPath stringByAppendingPathComponent:fileName] error:&openError];
        if (!writer) {
            for (ZSDumpWriter *opened in writers) [opened finish];
            [fm removeItemAtPath:folderPath error:nil];
            return openError ?: zs_dump_error(5, [NSString stringWithFormat:@"Could not open %@ for writing.", fileName]);
        }
        [writers addObject:writer];
    }

    ZSDumpSession *session = writers.count == 2 ? [[ZSDumpSession alloc] initWithSource:writers[0] bodies:writers[1]] : nil;
    size_t assemblyCount = 0;
    void **assemblies = gAPI.domain_get_assemblies(domain, &assemblyCount);
    if (!assemblies) assemblyCount = 0;
    NSUInteger writtenAssemblies = 0;
    NSDate *started = [NSDate date];

    for (size_t assemblyIndex = 0; session && assemblyIndex < assemblyCount; assemblyIndex++) {
        if (gCancel) break;
        if (progress) progress(@"Dumping classes", assemblyCount ? (double)assemblyIndex / (double)assemblyCount : 0);
        @autoreleasepool {
            const void *assembly = assemblies[assemblyIndex];
            const void *image = assembly ? gAPI.assembly_get_image(assembly) : NULL;
            if (!image) continue;
            [session beginAssembly:zs_string(gAPI.image_get_name(image))];
            writtenAssemblies++;
            size_t imageClassCount = gAPI.image_get_class_count(image);
            for (size_t classSlot = 0; classSlot < imageClassCount; classSlot++) {
                @autoreleasepool {
                    void *klass = (void *)gAPI.image_get_class(image, classSlot);
                    if (klass) [session writeClass:klass];
                }
                if (zs_any_writer_failed(writers) || gCancel) break;
            }
        }
        if (zs_any_writer_failed(writers)) break;
    }

    for (ZSDumpWriter *writer in writers) [writer finish];
    for (ZSDumpWriter *writer in writers) {
        if (writer.error) {
            NSString *message = [NSString stringWithFormat:@"Writing the dump failed: %@", writer.error.localizedDescription];
            [fm removeItemAtPath:folderPath error:nil];
            return zs_dump_error(8, message);
        }
    }

    if (gCancel) {
        [fm removeItemAtPath:folderPath error:nil];
        return zs_dump_error(9, @"Dump cancelled.");
    }
    if (!options.dumpBodies) [fm removeItemAtPath:[folderPath stringByAppendingPathComponent:@"Bodies.bin"] error:nil];
    if (progress) progress(@"Copying binaries", 0);
    BOOL copiedFramework = options.copyBinaries && zs_copy_file(zs_unity_framework_path(), [folderPath stringByAppendingPathComponent:@"UnityFramework"]);
    BOOL copiedMetadata = options.copyBinaries && zs_copy_file(zs_global_metadata_path(), [folderPath stringByAppendingPathComponent:@"global-metadata.dat"]);

    if (options.scriptMethods || options.metadataUsages || options.addresses || options.stringLiterals || options.genericMethods) {
        NSError *scriptError = nil;
        NSDictionary *scriptResult = [ZSScriptDump generateIntoFolder:folderPath options:options progress:progress log:logf cancelled:^BOOL{ return gCancel; } error:&scriptError];
        if (!scriptResult) {
            if (gCancel) {
                [fm removeItemAtPath:folderPath error:nil];
                return zs_dump_error(9, @"Dump cancelled.");
            }
            if (logf) logf([NSString stringWithFormat:@"Script generation failed: %@", scriptError.localizedDescription]);
        } else {
            scriptSummary = [scriptResult mutableCopy];
        }
    }
    if (options.exportScripts) {
        NSError *exportError = nil;
        NSUInteger exported = [ZSScriptDump exportScriptsIntoFolder:folderPath error:&exportError];
        if (logf) logf(exportError ? [NSString stringWithFormat:@"Exporting scripts failed: %@", exportError.localizedDescription] : [NSString stringWithFormat:@"Exported %lu script files", (unsigned long)exported]);
    }

    NSMutableArray *modules = [NSMutableArray arrayWithCapacity:session.modules.count];
    for (ZSModule *module in session.modules) {
        [modules addObject:@{
            @"index": @(module.index),
            @"path": module.path,
            @"base": [NSString stringWithFormat:@"0x%llx", (unsigned long long)module.base],
            @"slide": [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)module.slide]
        }];
    }

    NSDictionary *metadata = @{
        @"formatVersion": @4,
        @"generatedAt": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]],
        @"processId": @(NSProcessInfo.processInfo.processIdentifier),
        @"pointerSize": @(sizeof(void *)),
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"executablePath": NSBundle.mainBundle.executablePath ?: @"",
        @"mainBundlePath": NSBundle.mainBundle.bundlePath ?: @"",
        @"elapsedSeconds": @([[NSDate date] timeIntervalSinceDate:started]),
        @"counts": @{
            @"assemblies": @(writtenAssemblies),
            @"classes": @(session.classCount),
            @"methods": @(session.methodCount),
            @"fields": @(session.fieldCount),
            @"properties": @(session.propertyCount),
            @"events": @(session.eventCount),
            @"bodies": @(session.bodyCount),
            @"bodyBytes": @(session.bodyBytes)
        },
        @"files": @{
            @"source": options.dumpSource ? @"Dump.cs" : (id)NSNull.null,
            @"bodies": (options.dumpSource && options.dumpBodies) ? @"Bodies.bin" : (id)NSNull.null,
            @"unityFramework": copiedFramework ? @"UnityFramework" : (id)NSNull.null,
            @"globalMetadata": copiedMetadata ? @"global-metadata.dat" : (id)NSNull.null
        },
        @"script": scriptSummary ?: (id)NSNull.null,
        @"modules": modules,
        @"format": @{
            @"classHeader": @"// <type token> Size <instance size> [generic]",
            @"field": @"// <offset>, absent for const fields",
            @"method": @"// <method token> [generic] [Impl <implementation flags>] [VA <unslid virtual address> [Module <index>] Size <byte length> Body <byte offset in Bodies.bin>]",
            @"modules": @"Module 0 when no Module is given; index refers to the modules list",
            @"bodies": @"Raw AArch64 machine code of each IL2CPP compiled method, deduplicated by function address; function bounds come from LC_FUNCTION_STARTS of the owning module",
            @"propertiesAndEvents": @"Accessor methods are listed under Methods with their own token and body"
        }
    };

    NSError *metadataError = nil;
    NSData *metadataData = [zs_json(metadata) dataUsingEncoding:NSUTF8StringEncoding];
    if (![metadataData writeToFile:[folderPath stringByAppendingPathComponent:@"dump.json"] options:NSDataWritingAtomic error:&metadataError]) {
        [fm removeItemAtPath:folderPath error:nil];
        return metadataError ?: zs_dump_error(8, @"Writing the dump metadata failed.");
    }

    if (outputURL) *outputURL = [NSURL fileURLWithPath:folderPath isDirectory:YES];
    gLastSummary = @{@"counts": metadata[@"counts"] ?: @{}, @"script": scriptSummary ?: @{}, @"elapsed": metadata[@"elapsedSeconds"] ?: @0};
    return nil;
}

static NSError *zs_dump_runtime(ZSDumpOptions *options, ZSDumpProgress progress, ZSDumpLog logf, NSURL **outputURL) {
    NSError *error = nil;
    if (!zs_resolve_api(&error)) return error;
    void *domain = gAPI.domain_get();
    if (!domain) return zs_dump_error(2, @"il2cpp_domain_get returned NULL.");
    void *thread = gAPI.thread_current ? gAPI.thread_current() : NULL;
    BOOL attachedHere = NO;
    if (!thread) {
        thread = gAPI.thread_attach(domain);
        attachedHere = YES;
    }
    if (!thread) return zs_dump_error(3, @"Could not attach the dumper thread to the IL2CPP runtime.");

    NSError *result = zs_dump_attached(domain, options, progress, logf, outputURL);
    if (attachedHere) gAPI.thread_detach(thread);
    return result;
}

@implementation ZSDumpOptions

static NSString * const kZSDumpOptionsKey = @"ZSDumperOptions";

- (void)resetToDefaults {
    self.dumpSource = YES;
    self.dumpBodies = NO;
    self.copyBinaries = YES;
    self.scriptMethods = YES;
    self.genericMethods = YES;
    self.metadataUsages = YES;
    self.addresses = YES;
    self.stringLiterals = YES;
    self.exportScripts = YES;
    self.minifyJSON = YES;
}

+ (instancetype)savedOptions {
    ZSDumpOptions *options = [ZSDumpOptions new];
    [options resetToDefaults];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kZSDumpOptionsKey];
    if (saved) {
        for (NSString *key in saved) {
            if ([options respondsToSelector:NSSelectorFromString([NSString stringWithFormat:@"set%@%@:", [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]])]) {
                [options setValue:saved[key] forKey:key];
            }
        }
    }
    return options;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{@"dumpSource": @(self.dumpSource), @"dumpBodies": @(self.dumpBodies), @"copyBinaries": @(self.copyBinaries),
             @"scriptMethods": @(self.scriptMethods), @"genericMethods": @(self.genericMethods), @"metadataUsages": @(self.metadataUsages),
             @"addresses": @(self.addresses), @"stringLiterals": @(self.stringLiterals), @"exportScripts": @(self.exportScripts),
             @"minifyJSON": @(self.minifyJSON)};
}

- (void)save {
    [NSUserDefaults.standardUserDefaults setObject:[self dictionaryRepresentation] forKey:kZSDumpOptionsKey];
}

- (id)copyWithZone:(NSZone *)zone {
    ZSDumpOptions *copy = [ZSDumpOptions new];
    [copy setValuesForKeysWithDictionary:[self dictionaryRepresentation]];
    return copy;
}

@end

@implementation ZSDumper

+ (void)initialize {
    if (self == [ZSDumper class]) gRuntimeLock = [NSLock new];
}

+ (BOOL)isRunning {
    [gRuntimeLock lock];
    BOOL running = gRunning;
    [gRuntimeLock unlock];
    return running;
}

+ (void)cancel {
    gCancel = YES;
}

+ (NSDictionary *)lastSummary {
    return gLastSummary;
}

+ (NSURL *)lastOutputURL {
    return gLastOutput;
}

+ (void)dumpIL2CPPToDocumentsWithCompletion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    [self dumpWithOptions:[ZSDumpOptions savedOptions] progress:nil log:nil completion:completion];
}

+ (void)dumpWithOptions:(ZSDumpOptions *)options
               progress:(ZSDumpProgress)progress
                    log:(ZSDumpLog)logf
             completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    [gRuntimeLock lock];
    if (gRunning) {
        [gRuntimeLock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, zs_dump_error(7, @"An IL2CPP dump is already running."));
        });
        return;
    }
    gRunning = YES;
    gCancel = NO;
    [gRuntimeLock unlock];

    ZSDumpOptions *snapshot = [options copy];
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            NSURL *url = nil;
            NSError *error = zs_dump_runtime(snapshot, progress, logf, &url);
            [gRuntimeLock lock];
            gRunning = NO;
            [gRuntimeLock unlock];
            if (error) ZLog(@"[ZSDumper] failed: %@", error.localizedDescription);
            else ZLog(@"[ZSDumper] completed: %@", url.path);
            gLastOutput = error ? nil : url;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(url, error);
            });
        }
    }];
    worker.name = @"ZSingularity.ZSDumper";
    worker.stackSize = kZSDumpThreadStackSize;
    worker.qualityOfService = NSQualityOfServiceUtility;
    [worker start];
}

@end
