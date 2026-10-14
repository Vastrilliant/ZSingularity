/*
 * Credits: this file is based on code from the MeloNX iOS sideloading project
 * (https://starforgejo.dev/projects/MeloNX), modified and adapted by the
 * ZSingularity project to work as part of this tweak.
 */

#ifndef DonatedHeap_h
#define DonatedHeap_h

#import <Foundation/Foundation.h>
#import <stdint.h>

typedef struct {
    BOOL active;
    uint64_t poolBytes;
    uint64_t usedBytes;
    uint64_t servedAllocations;
    uint64_t fallbackAllocations;
} RamBypassStats;

typedef struct {
    uint64_t appBytes;
    uint64_t donatedBytes;
    uint64_t donatedUsedBytes;
    uint64_t totalBytes;
} RamHudSnapshot;

BOOL zs_ram_bypass_enabled(void);
BOOL zs_ram_bypass_available(void);
BOOL zs_ram_hud_enabled(void);
void zs_set_ram_hud_enabled(BOOL enabled);
NSInteger zs_ram_redirect_mode(void);
void zs_set_ram_redirect_mode(NSInteger mode);
void zs_ram_hud_get_snapshot(RamHudSnapshot *outSnapshot);
void zs_set_donated_heap_enabled(BOOL enabled);
void zs_ram_bypass_get_stats(RamBypassStats *outStats);
void zs_ram_bypass_memlog(void);

#endif
