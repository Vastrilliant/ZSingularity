#import "ZSStandaloneSigner.h"
#include "ZSSignEngine/common/common.h"
#include "ZSSignEngine/openssl.h"
#include "ZSSignEngine/macho.h"

NSString * const ZSStandaloneSignerErrorDomain = @"ZSStandaloneSignerErrorDomain";

static void zs_refresh_file(NSString *path) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return;
    NSString *tmpPath = [path stringByAppendingString:@".tmp"];
    NSError *error = nil;
    [NSFileManager.defaultManager copyItemAtPath:path toPath:tmpPath error:&error];
    [NSFileManager.defaultManager removeItemAtPath:path error:&error];
    [NSFileManager.defaultManager moveItemAtPath:tmpPath toPath:path error:&error];
}

@implementation ZSStandaloneSigner

+ (NSProgress *)signMachOPathArr:(NSArray<NSString *> *)machoPathArr
                         bundleId:(NSString *)bundleId
                             cert:(NSData *)cert
                             pass:(NSString *)pass
                completionHandler:(void (^)(BOOL success, NSError * _Nullable error))completionHandler
{
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:(int64_t)machoPathArr.count];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ZSignAsset *pSignAsset = new ZSignAsset();
        const char *pKeyData = (const char *)cert.bytes;
        string strPassword = pass.UTF8String ?: "";
        string strBundleId = bundleId.UTF8String ?: "";

        bool inited = pSignAsset->InitSimple(pKeyData, (int)cert.length, nil, 0, strPassword);
        if (!inited) {
            delete pSignAsset;
            NSError *initError = [NSError errorWithDomain:ZSStandaloneSignerErrorDomain
                                                       code:-1
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Couldn't initialize the signing identity. Check the certificate password."}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(NO, initError);
            });
            return;
        }

        NSMutableArray<NSString *> *errorList = [NSMutableArray new];
        dispatch_queue_t serialQueue = dispatch_queue_create("com.zsingularity.signqueue", DISPATCH_QUEUE_SERIAL);
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

        for (NSString *machoPath in machoPathArr) {
            dispatch_group_async(group, concurrentQueue, ^{
                ZMachO *macho = new ZMachO();
                NSString *errorMsg = nil;
                zs_refresh_file(machoPath);
                if (!macho->Init(machoPath.UTF8String)) {
                    errorMsg = [NSString stringWithFormat:@"Invalid mach-o file! %@", machoPath];
                } else {
                    bool signed_ = macho->Sign(pSignAsset, true, strBundleId, "", "", "");
                    if (!signed_) {
                        errorMsg = [NSString stringWithFormat:@"Failed to sign %@", machoPath];
                    } else {
                        zs_refresh_file(machoPath);
                    }
                }
                delete macho;

                dispatch_sync(serialQueue, ^{
                    if (errorMsg) [errorList addObject:errorMsg];
                    progress.completedUnitCount++;
                });
            });
        }

        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        delete pSignAsset;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (errorList.count > 0) {
                NSError *signError = [NSError errorWithDomain:ZSStandaloneSignerErrorDomain
                                                           code:-2
                                                       userInfo:@{NSLocalizedDescriptionKey: [errorList componentsJoinedByString:@"\n"]}];
                completionHandler(NO, signError);
            } else {
                completionHandler(YES, nil);
            }
        });
    });

    return progress;
}

@end
