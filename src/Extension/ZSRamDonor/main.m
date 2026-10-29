@import Foundation;

#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/proc.h>
#import <xpc/xpc.h>
#import "RamDonorProtocol.h"

extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address,
                                        mach_vm_size_t size);

#ifndef VM_FLAGS_PURGABLE
#define VM_FLAGS_PURGABLE 0x2
#endif

static NSMutableArray<NSValue *> *gRegions;

static void ZSReleaseRegions(void)
{
    for (NSUInteger i = 0; i + 1 < gRegions.count; i += 2)
    {
        const mach_vm_address_t base = (mach_vm_address_t)(uintptr_t)gRegions[i].pointerValue;
        const mach_vm_size_t size = (mach_vm_size_t)(uintptr_t)gRegions[i + 1].pointerValue;

        mach_vm_deallocate(mach_task_self(), base, size);
    }

    [gRegions removeAllObjects];
}

static xpc_object_t ZSCreateRegion(uint64_t size, NSString **error)
{
    if (size == 0)
    {
        *error = @"Refusing to create a zero sized region";
        return nil;
    }

    mach_vm_address_t address = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &address, size,
                                        VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);

    if (kr != KERN_SUCCESS)
    {
        *error = [NSString stringWithFormat:@"mach_vm_allocate failed: %s", mach_error_string(kr)];
        return nil;
    }

    xpc_object_t shmem = xpc_shmem_create((void *)address, (size_t)size);

    if (!shmem)
    {
        mach_vm_deallocate(mach_task_self(), address, size);

        *error = @"xpc_shmem_create returned NULL";
        return nil;
    }

    gRegions = gRegions ?: [NSMutableArray array];

    [gRegions addObject:[NSValue valueWithPointer:(void *)(uintptr_t)address]];
    [gRegions addObject:[NSValue valueWithPointer:(void *)(uintptr_t)size]];

    return shmem;
}

static void ZSHandleMessage(xpc_connection_t channel, xpc_object_t message)
{
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY)
    {
        return;
    }

    const char *op = xpc_dictionary_get_string(message, ZSDonorKeyOp);

    if (!op)
    {
        return;
    }

    xpc_object_t reply = xpc_dictionary_create_reply(message);

    if (!reply)
    {
        return;
    }

    if (strcmp(op, ZSDonorOpCreate) == 0)
    {
        NSString *error = nil;
        xpc_object_t shmem = ZSCreateRegion(xpc_dictionary_get_uint64(message, ZSDonorKeySize), &error);

        if (shmem)
        {
            xpc_dictionary_set_value(reply, ZSDonorKeyShmem, shmem);
        }
        else
        {
            xpc_dictionary_set_string(reply, ZSDonorKeyError, error.UTF8String);
            NSLog(@"[ZSRamDonor] Could not create a region: %@", error);
        }
    }
    else if (strcmp(op, ZSDonorOpRelease) == 0)
    {
        ZSReleaseRegions();
    }
    else if (strcmp(op, ZSDonorOpAvailable) == 0)
    {
        xpc_dictionary_set_uint64(reply, ZSDonorKeyAvailable, (uint64_t)os_proc_available_memory());
    }
    else
    {
        xpc_dictionary_set_string(reply, ZSDonorKeyError, "Unknown operation");
    }

    xpc_connection_send_message(channel, reply);
}

static void ZSDoNothing(void) {}

__attribute__((constructor))
static void ZSAllowEndpointDecoding(void)
{
    Class decoder = NSClassFromString(@"NSXPCDecoder");
    SEL selector = NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:");
    Method method = class_getInstanceMethod(decoder, selector);

    if (method)
    {
        method_setImplementation(method, (IMP)ZSDoNothing);
        NSLog(@"[ZSRamDonor] Loaded in pid %d, decoder validation disabled", getpid());
    }
    else
    {
        NSLog(@"[ZSRamDonor] Loaded in pid %d, but NSXPCDecoder validation hook was NOT found", getpid());
    }
}

@interface ZSRamDonorHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation ZSRamDonorHandler
{
    xpc_connection_t _channel;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    NSExtensionItem *item = (NSExtensionItem *)context.inputItems.firstObject;
    NSDictionary *info = item.userInfo;
    id wrapper = info[@"endpoint"];

    if (wrapper && ![wrapper isKindOfClass:NSXPCListenerEndpoint.class])
    {
        NSLog(@"[ZSRamDonor] The endpoint decoded as %@, not an NSXPCListenerEndpoint", [wrapper class]);
        wrapper = nil;
    }

    xpc_endpoint_t endpoint = ZSUnwrapEndpoint(wrapper);

    if (!endpoint)
    {
        NSLog(@"[ZSRamDonor] Request carried no usable endpoint (userInfo keys: %@)", info.allKeys);
        return;
    }

    _channel = xpc_connection_create_from_endpoint(endpoint);

    xpc_connection_set_event_handler(_channel, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
        {
            exit(0);
        }

        ZSHandleMessage(self->_channel, event);
    });

    xpc_connection_resume(_channel);

    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, ZSDonorKeyOp, "hello");
    xpc_connection_send_message(_channel, hello);

    NSLog(@"[ZSRamDonor] Ready, pid %d", getpid());
}

@end
