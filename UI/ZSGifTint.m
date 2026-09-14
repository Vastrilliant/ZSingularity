
#import "ZSGifTint.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <mach-o/getsect.h>
#import <dlfcn.h>
#import "ZTweakLog.h"

static NSData *zs_embedded_gif_data(void) {
    Dl_info info;
    if (dladdr((const void *)&zs_embedded_gif_data, &info) == 0 || !info.dli_fbase) return nil;
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    unsigned long size = 0;
    uint8_t *bytes = getsectiondata(header, "__DATA", "__enkephalin", &size);
    if (!bytes || size == 0) return nil;
    return [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:NO];
}

static UIImage *zs_blend_images(UIImage *from, UIImage *to, CGFloat t) {
    if (!from || !to) return from ?: to;
    CGSize size = from.size;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = from.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        [from drawInRect:(CGRect){CGPointZero, size}];
        [to drawInRect:(CGRect){CGPointZero, size} blendMode:kCGBlendModeNormal alpha:t];
    }];
}

static CATextLayerAlignmentMode zs_ca_alignment_for(NSTextAlignment alignment) {
    switch (alignment) {
        case NSTextAlignmentCenter: return kCAAlignmentCenter;
        case NSTextAlignmentRight: return kCAAlignmentRight;
        case NSTextAlignmentJustified: return kCAAlignmentJustified;
        case NSTextAlignmentNatural: return kCAAlignmentNatural;
        case NSTextAlignmentLeft:
        default: return kCAAlignmentLeft;
    }
}

static const CGRect kZSTextTexLayerFrame  = (CGRect){{0, 0}, {480, 72}};
static const CGRect kZSIconTexLayerFrame  = (CGRect){{0, 0}, {80, 80}};
static const CGRect kZSShapeTexLayerFrame = (CGRect){{0, 0}, {400, 32}};
static const CGRect kZSSwitchTexLayerFrame = (CGRect){{0, 0}, {51, 31}};

#pragma mark - Window registration (one per registered element)

typedef NS_ENUM(NSInteger, ZSGifWindowKind) {
    ZSGifWindowKindText,
    ZSGifWindowKindIcon,
    ZSGifWindowKindShape,
    ZSGifWindowKindSwitch,
};

@interface ZSGifWindow : NSObject
@property (nonatomic, weak) UIView *ownerView;
@property (nonatomic, strong) CALayer *texLayer;
@property (nonatomic, strong) CALayer *maskLayer;
@property (nonatomic, assign) ZSGifWindowKind kind;
@property (nonatomic, assign) CGFloat panUnit;
@property (nonatomic, assign) BOOL active;
@end
@implementation ZSGifWindow
@end

#pragma mark - Engine: decode + per-tick contents swap only

@interface ZSGifTintEngine : NSObject
+ (instancetype)sharedEngine;
- (nullable UIImage *)currentOrFirstFrame;
- (void)addWindow:(ZSGifWindow *)window;
- (void)setEnginePaused:(BOOL)paused;
@end

@implementation ZSGifTintEngine {
    NSArray<UIImage *> *_frames;
    NSArray<NSNumber *> *_frameDurations;
    NSTimeInterval _totalDuration;

    CADisplayLink *_displayLink;
    NSTimeInterval _startTime;
    NSInteger _lastFrameIndex;
    BOOL _paused;

    NSHashTable<ZSGifWindow *> *_windows;
}

+ (instancetype)sharedEngine {
    static ZSGifTintEngine *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [ZSGifTintEngine new]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastFrameIndex = -1;
        _windows = [NSHashTable weakObjectsHashTable];
        [self decodeFramesIfNeeded];
    }
    return self;
}

#pragma mark Decoding (source: full-resolution Enkephalin.gif, embedded at link time)

static const CGFloat kZSGifPlaybackRate = 0.5;
static const size_t kZSGifDecodeMaxPixelSize = 240;

- (void)decodeFramesIfNeeded {
    if (_frames.count > 0) return;

    NSData *data = zs_embedded_gif_data();
    if (!data) {
        ZLog(@"[ZSGifTint] couldn't find __DATA,__enkephalin section - accent tint disabled");
        _frames = @[];
        _frameDurations = @[];
        return;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        ZLog(@"[ZSGifTint] CGImageSourceCreateWithData failed on embedded gif data - accent tint disabled");
        _frames = @[];
        _frameDurations = @[];
        return;
    }

    size_t count = CGImageSourceGetCount(source);
    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:count];

    NSDictionary *thumbOptions = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(kZSGifDecodeMaxPixelSize),
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
    };

    for (size_t i = 0; i < count; i++) {
        CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, i, (__bridge CFDictionaryRef)thumbOptions);
        if (!cgImage) continue;
        [frames addObject:[UIImage imageWithCGImage:cgImage]];
        CGImageRelease(cgImage);

        NSTimeInterval duration = 0.06;
        NSDictionary *props = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, i, NULL);
        NSDictionary *gifProps = props[(__bridge NSString *)kCGImagePropertyGIFDictionary];
        NSNumber *unclamped = gifProps[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime];
        NSNumber *clamped = gifProps[(__bridge NSString *)kCGImagePropertyGIFDelayTime];
        NSNumber *chosen = unclamped ?: clamped;
        if (chosen && chosen.doubleValue > 0.0) duration = chosen.doubleValue;
        [durations addObject:@(duration / kZSGifPlaybackRate)];
    }

    CFRelease(source);

    if (frames.count > 1) {
        const NSInteger kCrossfadeSteps = 8;
        UIImage *lastFrame = frames.lastObject;
        UIImage *firstFrame = frames.firstObject;
        NSTimeInterval stepDuration = durations.firstObject.doubleValue > 0 ? durations.firstObject.doubleValue : 0.06;
        for (NSInteger i = 1; i <= kCrossfadeSteps; i++) {
            CGFloat t = (CGFloat)i / (CGFloat)(kCrossfadeSteps + 1);
            UIImage *blended = zs_blend_images(lastFrame, firstFrame, t);
            if (blended) {
                [frames addObject:blended];
                [durations addObject:@(stepDuration)];
            }
        }
    }

    _frames = frames;
    _frameDurations = durations;
    _totalDuration = 0;
    for (NSNumber *d in durations) _totalDuration += d.doubleValue;
    ZLog(@"[ZSGifTint] decoded %lu frame(s) (with crossfade padding), total loop duration %.2fs", (unsigned long)_frames.count, _totalDuration);
}

- (nullable UIImage *)currentOrFirstFrame {
    [self decodeFramesIfNeeded];
    if (_lastFrameIndex >= 0 && _lastFrameIndex < (NSInteger)_frames.count) return _frames[_lastFrameIndex];
    return _frames.firstObject;
}

#pragma mark Window registration

- (void)addWindow:(ZSGifWindow *)window {
    [self decodeFramesIfNeeded];
    [_windows addObject:window];
    [self startOrStopDisplayLinkAsNeeded];
}

- (void)setEnginePaused:(BOOL)paused {
    if (_paused == paused) return;
    _paused = paused;
    [self startOrStopDisplayLinkAsNeeded];
}

- (void)startOrStopDisplayLinkAsNeeded {
    BOOL needsLink = (_windows.count > 0) && (_frames.count > 0) && !_paused;
    if (needsLink && !_displayLink) {
        ZLog(@"[ZSGifTint] starting display link for %lu registered window(s)", (unsigned long)_windows.count);
        _startTime = CACurrentMediaTime();
        _lastFrameIndex = -1;
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!needsLink && _displayLink) {
        ZLog(@"[ZSGifTint] stopping display link, no registered windows remain");
        [_displayLink invalidate];
        _displayLink = nil;
    }
}

#pragma mark Timer-driven: advance frame + swap contents on every registered texLayer

- (void)tick:(nullable CADisplayLink *)link {
    if (_frames.count == 0 || _totalDuration <= 0) return;

    NSTimeInterval elapsed = fmod(CACurrentMediaTime() - _startTime, _totalDuration);
    NSTimeInterval cursor = 0;
    NSInteger index = 0;
    for (NSInteger i = 0; i < (NSInteger)_frameDurations.count; i++) {
        cursor += _frameDurations[i].doubleValue;
        if (elapsed < cursor) { index = i; break; }
        index = i;
    }
    if (index == _lastFrameIndex) return;
    _lastFrameIndex = index;

    UIImage *frame = _frames[index];
    if (!frame) return;
    id contents = (__bridge id)frame.CGImage;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (ZSGifWindow *w in _windows) {
        if (!w.active) continue;
        w.texLayer.contents = contents;
    }
    [CATransaction commit];
}

@end

#pragma mark - Public: preload

void zs_gif_tint_preload(void) {
    (void)[ZSGifTintEngine sharedEngine];
}

void zs_gif_tint_set_paused(BOOL paused) {
    [[ZSGifTintEngine sharedEngine] setEnginePaused:paused];
}

#pragma mark - Associated-object bookkeeping shared by all three kinds

static const void *kZSGifWindowKey = &kZSGifWindowKey;

static const CGFloat kZSGifContentY0 = 0.44, kZSGifContentY1 = 0.60;
static const CGFloat kZSGifContentX0 = 0.05, kZSGifContentX1 = 0.95;
static const CGFloat kZSGifPanWindowWidth = 0.45;

static CGFloat zs_pan_unit_for_owner(UIView *owner) {
    uintptr_t addr = (uintptr_t)(__bridge void *)owner;
    uint32_t h = (uint32_t)(addr ^ (addr >> 16));
    h ^= h >> 16; h *= 0x7feb352dU;
    h ^= h >> 15; h *= 0x846ca68bU;
    h ^= h >> 16;
    return (CGFloat)(h % 10000) / 10000.0;
}

static CGRect zs_gif_content_rect(CGFloat panUnit) {
    CGFloat range = (kZSGifContentX1 - kZSGifContentX0) - kZSGifPanWindowWidth;
    CGFloat x0 = kZSGifContentX0 + panUnit * range;
    return CGRectMake(x0, kZSGifContentY0, kZSGifPanWindowWidth, kZSGifContentY1 - kZSGifContentY0);
}

static ZSGifWindow *zs_register(UIView *owner, ZSGifWindowKind kind, CALayer *maskLayer, CGRect texLayerFrame, BOOL atBack) {
    ZSGifWindow *w = objc_getAssociatedObject(owner, kZSGifWindowKey);
    if (w) {
        [w.texLayer removeFromSuperlayer];
    } else {
        w = [ZSGifWindow new];
        w.panUnit = zs_pan_unit_for_owner(owner);
        objc_setAssociatedObject(owner, kZSGifWindowKey, w, OBJC_ASSOCIATION_RETAIN);
    }
    w.active = YES;

    CALayer *tex = [CALayer new];
    tex.frame = texLayerFrame;
    tex.contentsRect = zs_gif_content_rect(w.panUnit);
    tex.contentsGravity = kCAGravityResizeAspectFill;
    tex.contentsScale = UIScreen.mainScreen.scale;
    tex.mask = maskLayer;
    UIImage *current = [[ZSGifTintEngine sharedEngine] currentOrFirstFrame];
    if (current) tex.contents = (__bridge id)current.CGImage;
    if (atBack) {
        [owner.layer insertSublayer:tex atIndex:0];
    } else {
        [owner.layer addSublayer:tex];
    }

    w.ownerView = owner;
    w.kind = kind;
    w.texLayer = tex;
    w.maskLayer = maskLayer;
    [[ZSGifTintEngine sharedEngine] addWindow:w];
    return w;
}

static void zs_unregister(UIView *owner) {
    ZSGifWindow *w = objc_getAssociatedObject(owner, kZSGifWindowKey);
    [w.texLayer removeFromSuperlayer];
    objc_setAssociatedObject(owner, kZSGifWindowKey, nil, OBJC_ASSOCIATION_RETAIN);
}

void zs_set_gif_window_active(UIView *view, BOOL active) {
    if (!view) return;
    ZSGifWindow *w = objc_getAssociatedObject(view, kZSGifWindowKey);
    if (w) w.active = active;
}

#pragma mark - Text tint

static void zs_refresh_text_mask_if_registered(UILabel *label);

static void zs_safely_swizzle(Class cls, SEL origSel, SEL replSel) {
    Method original = class_getInstanceMethod(cls, origSel);
    Method replacement = class_getInstanceMethod(cls, replSel);
    if (!original || !replacement) return;

    BOOL addedOwnOverride = class_addMethod(cls, origSel,
                                             method_getImplementation(replacement),
                                             method_getTypeEncoding(replacement));
    if (addedOwnOverride) {
        class_replaceMethod(cls, replSel,
                             method_getImplementation(original),
                             method_getTypeEncoding(original));
    } else {
        method_exchangeImplementations(original, replacement);
    }
}

@interface UILabel (ZSGifTintSwizzle)
@end
@implementation UILabel (ZSGifTintSwizzle)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = self;
        SEL pairs[][2] = {
            {@selector(setText:), @selector(zs_gifTint_setText:)},
            {@selector(setAttributedText:), @selector(zs_gifTint_setAttributedText:)},
            {@selector(layoutSubviews), @selector(zs_gifTint_layoutSubviews)},
        };
        for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
            zs_safely_swizzle(cls, pairs[i][0], pairs[i][1]);
        }
    });
}

- (void)zs_gifTint_setText:(NSString *)text {
    [self zs_gifTint_setText:text];
    zs_refresh_text_mask_if_registered(self);
}

- (void)zs_gifTint_setAttributedText:(NSAttributedString *)attributedText {
    [self zs_gifTint_setAttributedText:attributedText];
    zs_refresh_text_mask_if_registered(self);
}

- (void)zs_gifTint_layoutSubviews {
    [self zs_gifTint_layoutSubviews];
    zs_refresh_text_mask_if_registered(self);
}

@end

static void zs_refresh_text_mask_if_registered(UILabel *label) {
    ZSGifWindow *w = objc_getAssociatedObject(label, kZSGifWindowKey);
    if (!w || w.kind != ZSGifWindowKindText) return;

    CATextLayer *mask = (CATextLayer *)w.maskLayer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = label.bounds;
    mask.alignmentMode = zs_ca_alignment_for(label.textAlignment);
    mask.truncationMode = kCATruncationEnd;
    mask.wrapped = (label.numberOfLines != 1);
    mask.contentsScale = UIScreen.mainScreen.scale;
    if (label.attributedText.length > 0) {
        mask.string = label.attributedText;
    } else {
        mask.string = label.text ?: @"";
        UIFont *font = label.font ?: [UIFont systemFontOfSize:[UIFont systemFontSize]];
        CTFontRef ctFont = CTFontCreateWithName((__bridge CFStringRef)font.fontName, font.pointSize, NULL);
        if (ctFont) {
            mask.font = ctFont;
            mask.fontSize = font.pointSize;
            CFRelease(ctFont);
        }
    }
    [CATransaction commit];
}

void zs_apply_gif_text_tint(UILabel *label) {
    if (!label) return;
    zs_gif_tint_preload();
    CATextLayer *mask = [CATextLayer new];
    zs_register(label, ZSGifWindowKindText, mask, kZSTextTexLayerFrame, NO);
    zs_refresh_text_mask_if_registered(label);
}

void zs_remove_gif_text_tint(UILabel *label) {
    if (!label) return;
    zs_unregister(label);
}

#pragma mark - Icon tint

void zs_apply_gif_icon_tint(UIImageView *imageView) {
    if (!imageView || !imageView.image) return;
    zs_gif_tint_preload();
    imageView.tintColor = UIColor.clearColor;

    CALayer *mask = [CALayer new];
    ZSGifWindow *w = zs_register(imageView, ZSGifWindowKindIcon, mask, kZSIconTexLayerFrame, NO);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = imageView.bounds;
    mask.contentsGravity = kCAGravityResizeAspect;
    mask.contents = (__bridge id)imageView.image.CGImage;
    [CATransaction commit];
    (void)w;
}

void zs_remove_gif_icon_tint(UIImageView *imageView) {
    if (!imageView) return;
    zs_unregister(imageView);
}

#pragma mark - Generic shape/view tint (slider capsule fill, etc.)

void zs_apply_gif_view_tint(UIView *view) {
    if (!view) return;
    zs_gif_tint_preload();
    CAShapeLayer *mask = [CAShapeLayer new];
    zs_register(view, ZSGifWindowKindShape, mask, kZSShapeTexLayerFrame, NO);
}

void zs_refresh_gif_view_tint(UIView *view, CGRect bounds) {
    if (!view) return;
    ZSGifWindow *w = objc_getAssociatedObject(view, kZSGifWindowKey);
    if (!w || w.kind != ZSGifWindowKindShape) return;

    CAShapeLayer *mask = (CAShapeLayer *)w.maskLayer;
    CAShapeLayer *sourceShape = [view.layer.mask isKindOfClass:[CAShapeLayer class]]
        ? (CAShapeLayer *)view.layer.mask : nil;

    mask.frame = bounds;
    if (sourceShape.path) {
        mask.path = sourceShape.path;
    } else {
        CGFloat r = view.layer.cornerRadius;
        mask.path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:r].CGPath;
    }
}

void zs_remove_gif_view_tint(UIView *view) {
    if (!view) return;
    zs_unregister(view);
}

#pragma mark - iOS stock toggle tint (UISwitch "on"/green track)

static void zs_refresh_switch_mask_if_registered(UISwitch *sw);

@interface UISwitch (ZSGifTintSwizzle)
@end
@implementation UISwitch (ZSGifTintSwizzle)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        zs_safely_swizzle(self, @selector(layoutSubviews), @selector(zs_gifTint_switch_layoutSubviews));
    });
}

- (void)zs_gifTint_switch_layoutSubviews {
    [self zs_gifTint_switch_layoutSubviews];
    zs_refresh_switch_mask_if_registered(self);
}

- (void)zs_gifTint_switchValueChanged {
    ZSGifWindow *w = objc_getAssociatedObject(self, kZSGifWindowKey);
    if (!w || w.kind != ZSGifWindowKindSwitch) return;

    CGFloat target = self.isOn ? 1.0 : 0.0;
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"opacity"];
    anim.fromValue = @(w.texLayer.opacity);
    anim.toValue = @(target);
    anim.duration = 0.25;
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [w.texLayer addAnimation:anim forKey:@"zs_gifTint_switchFade"];
    w.texLayer.opacity = target;
}

@end

static void zs_refresh_switch_mask_if_registered(UISwitch *sw) {
    ZSGifWindow *w = objc_getAssociatedObject(sw, kZSGifWindowKey);
    if (!w || w.kind != ZSGifWindowKindSwitch) return;

    CAShapeLayer *mask = (CAShapeLayer *)w.maskLayer;
    CGRect bounds = sw.bounds;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    w.texLayer.frame = bounds;
    mask.frame = bounds;
    mask.path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:bounds.size.height / 2.0].CGPath;
    [CATransaction commit];
}

void zs_apply_gif_switch_tint(UISwitch *sw) {
    if (!sw) return;
    zs_gif_tint_preload();
    sw.onTintColor = UIColor.clearColor;

    CAShapeLayer *mask = [CAShapeLayer new];
    ZSGifWindow *w = zs_register(sw, ZSGifWindowKindSwitch, mask, kZSSwitchTexLayerFrame, YES);
    w.texLayer.opacity = sw.isOn ? 1.0f : 0.0f;
    zs_refresh_switch_mask_if_registered(sw);

    [sw addTarget:sw action:@selector(zs_gifTint_switchValueChanged) forControlEvents:UIControlEventValueChanged];
}

void zs_remove_gif_switch_tint(UISwitch *sw) {
    if (!sw) return;
    sw.onTintColor = nil;
    [sw removeTarget:sw action:@selector(zs_gifTint_switchValueChanged) forControlEvents:UIControlEventValueChanged];
    zs_unregister(sw);
}
