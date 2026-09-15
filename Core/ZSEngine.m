}
@end

- (void)zs_addAnimation:(CAAnimation *)animation forKey:(NSString *)key;
@end

@implementation CALayer (ZSLockedFrameRate)
- (void)zs_addAnimation:(CAAnimation *)animation forKey:(NSString *)key {
    float locked = (float)[FPS120Controller shared].targetFPS;
    if (locked > 0) {
        CAFrameRateRange pinned;
        pinned.minimum = locked;
        pinned.preferred = locked;
        pinned.maximum = locked;
        animation.preferredFrameRateRange = pinned;
    }
    [self zs_addAnimation:animation forKey:key];
}
@end

static void zs_install_locked_framerate_hook(void) {
    zs_safely_swizzle_class([CADisplayLink class], @selector(setPreferredFrameRateRange:), @selector(zs_setPreferredFrameRateRange:));
}

#pragma mark - Apply-everything entry points
