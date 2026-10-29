# MEMORY MANAGEMENT
## Entitlements

An iOS app can have two entitlements that allow it to use more memory.

`com.apple.developer.kernel.increased-memory-limit` allows the app to request more memory from iOS. **This entitlement has no effect on iPhones with less than 4GB of memory.**

`com.apple.developer.kernel.extended-virtual-addressing` enables 64-bit virtual address spaces, allowing the app to map significantly larger address allocations.

While this entitlement in and of itself **does not** increase physical memory, it is highly critical for applications that need to map multiple huge data chunks concurrently. By widening the virtual address boundaries, it prevents memory allocations from failing due to address space fragmentation.

This entitlement is only available for paid Apple developer accounts.

## Extend Memory Usage

By utilizing app extensions, ZS can reallocate IL2CPP managed heaps and malloc memory regions to an app extension, which has a separate memory limit.

This effectively allows the app to bypass Apple's memory restrictions, allowing iPhones with as little as 3GB of memory to mostly run the game normally.

Do note that this requires registering an additional App ID.

Credits: @Stossy11 and the MeloNX team for originally discovering this bypass

## Redirect minimum

Filters which IL2CPP managed memory regions get reallocated. Lower thresholds will reallocate more memory but may come at the cost of stability.

## Memory Cleanup

Frees memory the game is no longer using by releasing idle cached runtime objects.

Those include:
* idle pooled instances
* cached assets
* unused camera render targets
* battle portraits
* battle VFX effects
* fallback text materials and other internal caches

Then it runs `GC.Collect()` twice.

Expect a brief lag spike when running this.
