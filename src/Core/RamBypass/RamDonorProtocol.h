/*
 * Credits: this file is based on code from the MeloNX iOS sideloading project
 * (https://starforgejo.dev/projects/MeloNX), modified and adapted by the
 * ZSingularity project to work as part of this tweak.
 */

#ifndef RamDonorProtocol_h
#define RamDonorProtocol_h

@import Foundation;
#import <mach/mach.h>
#import <xpc/xpc.h>

#define ZS_DONOR_CHUNK_SIZE (256ull * 1024ull * 1024ull)

#define ZSDonorKeyOp        "op"
#define ZSDonorKeySize      "size"
#define ZSDonorKeyShmem     "shmem"
#define ZSDonorKeyError     "error"
#define ZSDonorKeyAvailable "available"

#define ZSDonorOpCreate     "create"
#define ZSDonorOpRelease    "release"
#define ZSDonorOpAvailable  "available"

NS_ASSUME_NONNULL_BEGIN

@interface NSXPCListenerEndpoint (ZSPrivate)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end

static inline NSXPCListenerEndpoint *ZSWrapEndpoint(xpc_endpoint_t endpoint)
{
    NSXPCListenerEndpoint *wrapper = [NSXPCListenerEndpoint new];
    wrapper._endpoint = endpoint;

    return wrapper;
}

static inline xpc_endpoint_t _Nullable ZSUnwrapEndpoint(NSXPCListenerEndpoint *_Nullable wrapper)
{
    xpc_object_t inner = wrapper._endpoint;

    if (!inner || xpc_get_type(inner) != XPC_TYPE_ENDPOINT)
    {
        return nil;
    }

    return (xpc_endpoint_t)inner;
}

NS_ASSUME_NONNULL_END

#endif
