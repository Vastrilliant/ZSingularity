/*
 * Credits: this file is based on code from the MeloNX iOS sideloading project
 * (https://starforgejo.dev/projects/MeloNX), modified and adapted by the
 * ZSingularity project to work as part of this tweak.
 */

#import "RamDonor.h"
#import "RamDonorProtocol.h"
#import "ZTweakLog.h"

#import <mach/mach.h>
#import <objc/message.h>

@interface NSExtension : NSObject
@property (nonatomic, strong, readwrite) NSArray *preferredLanguages;
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))callback;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)_kill:(int)signal;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *uuid, NSError *error))callback;
@end

extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address,
                                        mach_vm_size_t size);
extern kern_return_t mach_vm_remap(vm_map_t target, mach_vm_address_t *address,
                                   mach_vm_size_t size, mach_vm_offset_t mask, int flags,
                                   vm_map_t source, mach_vm_address_t sourceAddress,
                                   boolean_t copy, vm_prot_t *currentProtection,
                                   vm_prot_t *maxProtection, vm_inherit_t inheritance);

extern kern_return_t mach_vm_region_recurse(vm_map_read_t target, mach_vm_address_t *address,
                                            mach_vm_size_t *size, natural_t *depth,
                                            vm_region_recurse_info_t info,
                                            mach_msg_type_number_t *count);

#ifndef VM_FLAGS_OVERWRITE
#define VM_FLAGS_OVERWRITE 0x4000
#endif

static const uint64_t ZSDonorHeadroom = 256ull * 1024ull * 1024ull;

@interface ZSDonorSlot : NSObject
@property (nonatomic) xpc_connection_t connection;
@property (nonatomic) uint64_t remaining;
@end

@implementation ZSDonorSlot
@end

@interface ZSDonatedRegion : NSObject
@property (nonatomic) mach_vm_address_t base;
@property (nonatomic) uint64_t size;
@property (nonatomic) NSMutableArray *shmems;
@end

@implementation ZSDonatedRegion
@end

@interface ZSRamDonor ()
@property (nonatomic) xpc_connection_t listener;
@property (nonatomic) NSMutableArray<NSExtension *> *extensions;
@property (nonatomic) NSMutableArray *connections;
@property (nonatomic) NSMutableDictionary<NSNumber *, ZSDonatedRegion *> *regions;
@property (nonatomic) dispatch_semaphore_t connected;
@property (nonatomic) NSUInteger nextDonor;
@property (nonatomic, copy) NSString *lastError;
@end

@implementation ZSRamDonor

static ZSRamDonor *sharedDonor;

+ (ZSRamDonor *)shared
{
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        sharedDonor = [ZSRamDonor new];
    });

    return sharedDonor;
}

- (instancetype)init
{
    self = [super init];

    _extensions = [NSMutableArray array];
    _connections = [NSMutableArray array];
    _regions = [NSMutableDictionary dictionary];
    _connected = dispatch_semaphore_create(0);
    _maxDonors = 4;
    _killDonorsAfterMapping = YES;

    _listener = xpc_connection_create(NULL, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));

    __weak typeof(self) weakSelf = self;

    xpc_connection_set_event_handler(_listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_CONNECTION)
        {
            return;
        }

        [weakSelf acceptConnection:(xpc_connection_t)event];
    });

    xpc_connection_resume(_listener);

    return self;
}

- (NSUInteger)liveDonorCount
{
    @synchronized (self)
    {
        return self.connections.count;
    }
}

+ (NSArray<NSString *> *)donorBundleIdentifiers
{
    static NSArray<NSString *> *identifiers;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSMutableArray<NSBundle *> *hosts = [NSMutableArray array];
        SEL liveContainerSelector = NSSelectorFromString(@"lcMainBundle");

        if ([NSUserDefaults respondsToSelector:liveContainerSelector])
        {
            id liveContainerBundle = ((id (*)(id, SEL))objc_msgSend)(NSUserDefaults.class, liveContainerSelector);

            if ([liveContainerBundle isKindOfClass:NSBundle.class] && liveContainerBundle != NSBundle.mainBundle)
            {
                [hosts addObject:liveContainerBundle];
            }
        }

        [hosts addObject:NSBundle.mainBundle];

        NSMutableArray<NSString *> *found = [NSMutableArray array];

        for (NSBundle *host in hosts)
        {
            NSURL *plugIns = host.builtInPlugInsURL;
            NSArray<NSURL *> *contents = plugIns
                ? [NSFileManager.defaultManager contentsOfDirectoryAtURL:plugIns
                                              includingPropertiesForKeys:nil
                                                                 options:0
                                                                   error:nil]
                : nil;

            for (NSURL *url in contents)
            {
                if (![url.pathExtension isEqualToString:@"appex"])
                {
                    continue;
                }

                NSBundle *bundle = [NSBundle bundleWithURL:url];
                NSString *principal = bundle.infoDictionary[@"NSExtension"][@"NSExtensionPrincipalClass"];
                NSString *bundleID = bundle.bundleIdentifier;

                if ([principal isEqualToString:@"ZSRamDonorHandler"] && bundleID.length > 0 && ![found containsObject:bundleID])
                {
                    [found addObject:bundleID];
                }
            }

            NSString *hostID = host.bundleIdentifier;

            if (hostID.length > 0)
            {
                NSString *derived = [hostID stringByAppendingString:@".ZSRamDonor"];

                if (![found containsObject:derived])
                {
                    [found addObject:derived];
                }
            }
        }

        identifiers = [found copy];
        ZLog(@"[RamBypass] donor extension candidates: %@", identifiers.count > 0 ? [identifiers componentsJoinedByString:@", "] : @"none found");
    });

    return identifiers;
}

+ (NSString *)donorBundleIdentifier
{
    return self.donorBundleIdentifiers.firstObject;
}

static NSString *sWorkingDonorIdentifier;

- (BOOL)startOneDonorWithTimeout:(NSTimeInterval)timeout
{
    NSMutableArray<NSString *> *candidates = [ZSRamDonor.donorBundleIdentifiers mutableCopy];

    if (candidates.count == 0)
    {
        self.lastError = @"The memory helper is missing from this build";
        return NO;
    }

    NSString *known = sWorkingDonorIdentifier;

    if (known && [candidates containsObject:known])
    {
        [candidates removeObject:known];
        [candidates insertObject:known atIndex:0];
    }

    for (NSString *identifier in candidates)
    {
        if ([self startOneDonorWithIdentifier:identifier timeout:timeout])
        {
            sWorkingDonorIdentifier = identifier;
            return YES;
        }
    }

    return NO;
}

- (BOOL)startOneDonorWithIdentifier:(NSString *)identifier timeout:(NSTimeInterval)timeout
{
    NSError *error = nil;
    NSExtension *extension = [NSExtension extensionWithIdentifier:identifier error:&error];

    if (!extension)
    {
        self.lastError = [NSString stringWithFormat:@"Could not load %@: %@",
                                                    identifier, error.localizedDescription];
        ZLog(@"[RamBypass] %@", self.lastError);
        return NO;
    }

    extension.preferredLanguages = @[];

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{ @"endpoint": ZSWrapEndpoint(xpc_endpoint_create(self.listener)) };

    [extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *cancelError) {
        ZLog(@"[RamBypass] donor request cancelled: %@", cancelError);
    }];

    const NSUInteger before = self.liveDonorCount;

    __block BOOL started = NO;
    __block NSUUID *requestIdentifier = nil;
    dispatch_semaphore_t spawned = dispatch_semaphore_create(0);

    [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *uuid) {
        requestIdentifier = uuid;
        started = uuid != nil;
        dispatch_semaphore_signal(spawned);
    }];

    dispatch_semaphore_wait(spawned,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));

    if (!started)
    {
        self.lastError = @"The extension request was rejected, so no process was spawned";
        ZLog(@"[RamBypass] %@", self.lastError);
        return NO;
    }

    ZLog(@"[RamBypass] donor spawned, pid %d, waiting for it to connect",
         [extension pidForRequestIdentifier:requestIdentifier]);

    const NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + timeout;

    while (self.liveDonorCount <= before)
    {
        const NSTimeInterval remaining = deadline - NSDate.timeIntervalSinceReferenceDate;

        if (remaining <= 0)
        {
            self.lastError = @"The donor spawned, but no connection was accepted before the timeout";
            ZLog(@"[RamBypass] %@", self.lastError);
            return NO;
        }

        dispatch_semaphore_wait(self.connected,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    }

    @synchronized (self)
    {
        [self.extensions addObject:extension];
    }

    return YES;
}

- (void)acceptConnection:(xpc_connection_t)connection
{
    __weak typeof(self) weakSelf = self;

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
        {
            [weakSelf forgetConnection:connection];
        }
    });

    xpc_connection_resume(connection);

    @synchronized (self)
    {
        [self.connections addObject:connection];
    }

    dispatch_semaphore_signal(self.connected);
}

- (void)forgetConnection:(xpc_connection_t)connection
{
    @synchronized (self)
    {
        [self.connections removeObjectIdenticalTo:connection];
    }

    ZLog(@"[RamBypass] a donor went away, %lu left", (unsigned long)self.liveDonorCount);
}

- (nullable xpc_object_t)send:(const char *)op
                           to:(xpc_connection_t)donor
                         size:(uint64_t)size
                      timeout:(NSTimeInterval)timeout
{
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, ZSDonorKeyOp, op);

    if (size)
    {
        xpc_dictionary_set_uint64(request, ZSDonorKeySize, size);
    }

    __block xpc_object_t answer = nil;
    dispatch_semaphore_t replied = dispatch_semaphore_create(0);

    xpc_connection_send_message_with_reply(donor, request,
                                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                                           ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY)
        {
            answer = reply;
        }

        dispatch_semaphore_signal(replied);
    });

    if (dispatch_semaphore_wait(replied,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0)
    {
        return nil;
    }

    return answer;
}

- (nullable void *)acquireUpTo:(uint64_t)size minimum:(uint64_t)minimum actual:(uint64_t *)actual
{
    if (actual)
    {
        *actual = 0;
    }

    if (size == 0)
    {
        return NULL;
    }

    const uint64_t pageMask = (uint64_t)vm_page_size - 1;
    size = (size + pageMask) & ~pageMask;
    minimum = MIN((minimum + pageMask) & ~pageMask, size);

    NSMutableArray<ZSDonorSlot *> *slots = [NSMutableArray array];

    if (![self addSlotForNextDonorTo:slots])
    {
        return NULL;
    }

    mach_vm_address_t base = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &base, size, VM_FLAGS_ANYWHERE);

    if (kr != KERN_SUCCESS)
    {
        self.lastError = [NSString stringWithFormat:@"Could not reserve %llu MB of address space: %s",
                                                    size / (1024 * 1024), mach_error_string(kr)];
        return NULL;
    }

    ZSDonatedRegion *region = [ZSDonatedRegion new];
    region.base = base;
    region.size = size;
    region.shmems = [NSMutableArray array];

    uint64_t offset = 0;

    while (offset < size)
    {
        const uint64_t length = MIN(ZS_DONOR_CHUNK_SIZE, size - offset);

        ZSDonorSlot *slot = [self slotWithRoomFor:length in:slots];

        if (!slot || ![self mapChunkOfSize:length from:slot into:region at:base + offset])
        {
            if (!slot)
            {
                self.lastError = [NSString stringWithFormat:
                    @"%lu donor(s) could only take %llu MB of the %llu MB needed",
                    (unsigned long)slots.count, offset / (1024 * 1024), size / (1024 * 1024)];
                ZLog(@"[RamBypass] %@", self.lastError);
            }

            break;
        }

        slot.remaining -= length;
        offset += length;
    }

    if (offset == 0 || offset < minimum)
    {
        [self tearDownRegion:region];
        return NULL;
    }

    if (offset < size)
    {
        mach_vm_deallocate(mach_task_self(), base + offset, size - offset);
        region.size = offset;
    }

    @synchronized (self)
    {
        self.regions[@(base)] = region;
    }

    ZLog(@"[RamBypass] %llu MB of %llu MB mapped at 0x%llx across %lu donor(s)",
         offset / (1024 * 1024), size / (1024 * 1024), (uint64_t)base, (unsigned long)slots.count);

    if (actual)
    {
        *actual = offset;
    }

    if (self.killDonorsAfterMapping)
    {
        [self killDonorProcesses];
    }

    return (void *)base;
}

- (BOOL)mapChunkOfSize:(uint64_t)length
                  from:(ZSDonorSlot *)slot
                  into:(ZSDonatedRegion *)region
                    at:(mach_vm_address_t)target
{
    xpc_object_t reply = [self send:ZSDonorOpCreate to:slot.connection size:length timeout:30.0];

    if (!reply)
    {
        self.lastError = [NSString stringWithFormat:@"A donor did not answer while asking for %llu MB",
                                                    length / (1024 * 1024)];
        ZLog(@"[RamBypass] %@", self.lastError);
        return NO;
    }

    const char *donorError = xpc_dictionary_get_string(reply, ZSDonorKeyError);

    if (donorError)
    {
        self.lastError = [NSString stringWithFormat:@"Donor could not supply %llu MB: %s",
                                                    length / (1024 * 1024), donorError];
        ZLog(@"[RamBypass] %@", self.lastError);
        return NO;
    }

    xpc_object_t shmem = xpc_dictionary_get_value(reply, ZSDonorKeyShmem);

    if (!shmem || xpc_get_type(shmem) != XPC_TYPE_SHMEM)
    {
        self.lastError = @"A donor's reply carried no shared memory";
        ZLog(@"[RamBypass] %@", self.lastError);
        return NO;
    }

    void *scratch = NULL;
    const size_t mapped = xpc_shmem_map(shmem, &scratch);

    if (mapped < length || !scratch)
    {
        self.lastError = [NSString stringWithFormat:@"xpc_shmem_map returned %zu of %llu bytes",
                                                    mapped, length];
        ZLog(@"[RamBypass] %@", self.lastError);
        return NO;
    }

    vm_prot_t current = VM_PROT_NONE;
    vm_prot_t maximum = VM_PROT_NONE;
    mach_vm_address_t destination = target;

    kern_return_t kr = mach_vm_remap(mach_task_self(), &destination, length, 0,
                                     VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                     mach_task_self(), (mach_vm_address_t)scratch, false,
                                     &current, &maximum, VM_INHERIT_SHARE);

    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)scratch, mapped);

    if (kr != KERN_SUCCESS)
    {
        self.lastError = [NSString stringWithFormat:@"Could not remap a donated chunk: %s",
                                                    mach_error_string(kr)];
        ZLog(@"[RamBypass] %@", self.lastError);
        return NO;
    }

    [region.shmems addObject:shmem];

    return YES;
}

- (nullable ZSDonorSlot *)slotWithRoomFor:(uint64_t)length in:(NSMutableArray<ZSDonorSlot *> *)slots
{
    for (NSUInteger i = 0; i < slots.count; i++)
    {
        ZSDonorSlot *slot = slots[self.nextDonor++ % slots.count];

        if (slot.remaining >= length)
        {
            return slot;
        }
    }

    if (slots.count >= self.maxDonors)
    {
        return nil;
    }

    if (![self addSlotForNextDonorTo:slots])
    {
        return nil;
    }

    ZSDonorSlot *added = slots.lastObject;

    return added.remaining >= length ? added : nil;
}

- (BOOL)addSlotForNextDonorTo:(NSMutableArray<ZSDonorSlot *> *)slots
{
    const NSUInteger before = self.liveDonorCount;

    if (slots.count >= before && ![self startOneDonorWithTimeout:10.0])
    {
        return NO;
    }

    xpc_connection_t connection = nil;

    @synchronized (self)
    {
        NSMutableArray *spare = [self.connections mutableCopy];

        for (ZSDonorSlot *slot in slots)
        {
            [spare removeObjectIdenticalTo:slot.connection];
        }

        connection = spare.firstObject;
    }

    if (!connection)
    {
        return NO;
    }

    xpc_object_t reply = [self send:ZSDonorOpAvailable to:connection size:0 timeout:2.0];
    const uint64_t budget = reply ? xpc_dictionary_get_uint64(reply, ZSDonorKeyAvailable) : 0;

    ZSDonorSlot *slot = [ZSDonorSlot new];
    slot.connection = connection;
    slot.remaining = budget > ZSDonorHeadroom ? budget - ZSDonorHeadroom : 0;

    [slots addObject:slot];

    ZLog(@"[RamBypass] donor %lu reports %llu MB available, will use up to %llu MB of it",
         (unsigned long)slots.count, budget / (1024 * 1024), slot.remaining / (1024 * 1024));

    return slot.remaining > 0;
}

- (void)tearDownRegion:(ZSDonatedRegion *)region
{
    [region.shmems removeAllObjects];

    if (region.base)
    {
        mach_vm_deallocate(mach_task_self(), region.base, region.size);
    }
}

- (void)releaseRegionAt:(void *)base
{
    ZSDonatedRegion *region;

    @synchronized (self)
    {
        region = self.regions[@((mach_vm_address_t)base)];
        [self.regions removeObjectForKey:@((mach_vm_address_t)base)];
    }

    if (region)
    {
        [self tearDownRegion:region];
    }
}

static uint64_t ZSTouchedBytesInRange(mach_vm_address_t start, mach_vm_size_t length)
{
    const mach_vm_address_t end = start + length;
    mach_vm_address_t address = start;
    natural_t depth = 0;
    uint64_t pages = 0;

    while (address < end)
    {
        mach_vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;

        kern_return_t kr = mach_vm_region_recurse(mach_task_self(), &address, &size, &depth,
                                                  (vm_region_recurse_info_t)&info, &count);

        if (kr != KERN_SUCCESS || address >= end)
        {
            break;
        }

        if (info.is_submap)
        {
            depth++;
            continue;
        }

        pages += info.pages_dirtied + info.pages_swapped_out;
        address += size;
    }

    return pages * vm_page_size;
}

- (uint64_t)donatedBytes
{
    NSArray<ZSDonatedRegion *> *regions;

    @synchronized (self)
    {
        regions = self.regions.allValues;
    }

    uint64_t bytes = 0;

    for (ZSDonatedRegion *region in regions)
    {
        bytes += ZSTouchedBytesInRange(region.base, region.size);
    }

    return bytes;
}

- (void)killDonorProcesses
{
    NSArray<NSExtension *> *extensions;

    @synchronized (self)
    {
        extensions = [self.extensions copy];
        [self.extensions removeAllObjects];
    }

    ZLog(@"[RamBypass] killing %lu donor(s), mapped memory stays with this process",
         (unsigned long)extensions.count);

    for (NSExtension *extension in extensions)
    {
        [extension _kill:SIGKILL];
    }
}

- (void)shutdown
{
    NSArray<NSExtension *> *extensions;
    NSArray<ZSDonatedRegion *> *regions;

    @synchronized (self)
    {
        extensions = [self.extensions copy];
        regions = self.regions.allValues;

        [self.extensions removeAllObjects];
        [self.connections removeAllObjects];
        [self.regions removeAllObjects];
    }

    for (ZSDonatedRegion *region in regions)
    {
        [self tearDownRegion:region];
    }

    for (NSExtension *extension in extensions)
    {
        [extension _kill:SIGTERM];
    }
}

@end
