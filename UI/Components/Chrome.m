#import "UIInternal.h"

#pragma mark - Metal pull tabs

NSString * const kZSMTHandleKey = @"__handle";
static const CGFloat kZSMTCornerRadius = 10;
static const CGFloat kZSMTCellPoints = 24;
static const int kZSMTMaxItems = 8;
static const CGFloat kZSMTSkinMargin = 18;
static const CGFloat kZSMTGlassSpacing = 16;

typedef struct {
    float rect[4];
    float radii[4];
    float params[4];
    float rest[4];
} ZSMTGPUItem;

typedef struct {
    float viewport[4];
    float misc[4];
    float quad[4];
    float counts[4];
    float skin[4];
    float back[4];
    float skinRect[4];
    ZSMTGPUItem items[8];
} ZSMTGPUScene;

typedef struct {
    float x, y, w, h;
} ZSMTRect;

static os_unfair_lock g_zsmtLock = OS_UNFAIR_LOCK_INIT;
static ZSMTRect g_zsmtRects[8];
static int g_zsmtCount;
static float g_zsmtViewW;
static float g_zsmtViewH;
static BOOL g_zsmtVisible;
static BOOL g_zsmtSnap;
static BOOL g_zsmtGlass;
static float g_zsmtPressTarget[8];
static NSData *g_zsmtAtlasData;
static NSData *g_zsmtSkinData;
static int g_zsmtSkinVersion;
static int g_zsmtSkinW;
static int g_zsmtSkinH;
static int g_zsmtAtlasVersion;
static int g_zsmtAtlasCellPx;
static int g_zsmtAtlasCells;
static id<MTLLibrary> g_zsmtLibrary;
static id<MTLRenderPipelineState> g_zsmtPipeline;
static MTLPixelFormat g_zsmtPipelineFormat;
static __weak CAMetalLayer *g_zsmtLayer;
static BOOL g_zsmtPauseWanted;
static NSUInteger g_zsmtPauseToken;
static NSData *g_zsmtPauseData;
static int g_zsmtPauseTexW;
static int g_zsmtPauseTexH;
static float g_zsmtPausePtW;
static float g_zsmtPausePtH;
static int g_zsmtPauseVersion;
static id<MTLRenderPipelineState> g_zsmtPausePipeline;
static MTLPixelFormat g_zsmtPausePipelineFormat;
static id<MTLTexture> r_zsmtPauseTex;
static int r_zsmtPauseVersion = -1;
static float r_zsmtPauseAmount;
static CFTimeInterval r_zsmtPauseLastTime;
static NSUInteger r_zsmtPauseReportedToken;
static MTLPixelFormat r_zsmtPauseFailedFormat;

static BOOL g_zsmtHudWanted;
static BOOL g_zsmtHudPending;
static NSData *g_zsmtHudData;
static int g_zsmtHudTexW;
static int g_zsmtHudTexH;
static float g_zsmtHudPtW;
static float g_zsmtHudPtH;
static float g_zsmtHudViewW;
static float g_zsmtHudInsetTop;
static float g_zsmtHudInsetRight;
static int g_zsmtHudVersion;
static id<MTLRenderPipelineState> g_zsmtHudPipeline;
static MTLPixelFormat g_zsmtHudPipelineFormat;
static id<MTLTexture> r_zsmtHudTex;
static int r_zsmtHudVersion = -1;
static CFTimeInterval r_zsmtHudLastRequest;
static MTLPixelFormat r_zsmtHudFailedFormat;

static id<MTLTexture> r_zsmtAtlas;
static id<MTLTexture> r_zsmtSkin;
static int r_zsmtSkinVersion = -1;
static id<MTLTexture> r_zsmtBackdrop;
static int r_zsmtAtlasVersion = -1;
static float r_zsmtMaster;
static float r_zsmtPress[8];
static CFTimeInterval r_zsmtLastTime;
static CFTimeInterval r_zsmtLastResync;
static MTLPixelFormat r_zsmtFailedFormat;

static IMP g_zsmtOrigCommit;
static IMP g_zsmtOrigPresent;
static IMP g_zsmtOrigPresentAt;
static IMP g_zsmtOrigPresentAfter;
static const void *kZSMTPendingDrawableKey = &kZSMTPendingDrawableKey;

static NSString * const kZSMTShaderSource =
@"#include <metal_stdlib>\n"
@"using namespace metal;\n"
@"\n"
@"struct ZSItem {\n"
@"    float4 rect;\n"
@"    float4 radii;\n"
@"    float4 params;\n"
@"    float4 rest;\n"
@"};\n"
@"\n"
@"struct ZSScene {\n"
@"    float4 viewport;\n"
@"    float4 misc;\n"
@"    float4 quad;\n"
@"    float4 counts;\n"
@"    float4 skin;\n"
@"    float4 back;\n"
@"    float4 skinRect;\n"
@"    ZSItem items[8];\n"
@"};\n"
@"\n"
@"struct VOut {\n"
@"    float4 position [[position]];\n"
@"    float2 local;\n"
@"};\n"
@"\n"
@"vertex VOut zs_tab_vertex(uint vid [[vertex_id]], constant ZSScene &scene [[buffer(0)]]) {\n"
@"    float2 c = float2(float(vid & 1u), float((vid >> 1u) & 1u));\n"
@"    float2 p = mix(scene.quad.xy, scene.quad.zw, c);\n"
@"    VOut o;\n"
@"    o.position = float4(p.x / scene.viewport.x * 2.0 - 1.0, 1.0 - p.y / scene.viewport.y * 2.0, 0.0, 1.0);\n"
@"    o.local = p;\n"
@"    return o;\n"
@"}\n"
@"\n"
@"float zs_box(float2 p, float2 hs, float4 r) {\n"
@"    float rad = p.x < 0.0 ? (p.y < 0.0 ? r.x : r.w) : (p.y < 0.0 ? r.y : r.z);\n"
@"    float2 q = abs(p) - hs + rad;\n"
@"    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;\n"
@"}\n"
@"\n"
@"float zs_smin(float a, float b, float k) {\n"
@"    float h = max(k - abs(a - b), 0.0) / k;\n"
@"    return min(a, b) - h * h * k * 0.25;\n"
@"}\n"
@"\n"
@"float zs_union(float2 pos, constant ZSScene &scene) {\n"
@"    int n = int(scene.counts.x);\n"
@"    float k = max(scene.counts.y, 0.001);\n"
@"    float d = 1000000.0;\n"
@"    for (int i = 0; i < n; i++) {\n"
@"        constant ZSItem &it = scene.items[i];\n"
@"        float2 hs = it.rect.zw * 0.5;\n"
@"        float s = zs_box(pos - (it.rect.xy + hs), hs, it.radii);\n"
@"        d = (i == 0) ? s : zs_smin(d, s, k);\n"
@"    }\n"
@"    return d;\n"
@"}\n"
@"\n"
@"fragment float4 zs_tab_fragment(VOut in [[stage_in]],\n"
@"                                float4 dst [[color(0)]],\n"
@"                                constant ZSScene &scene [[buffer(0)]],\n"
@"                                texture2d<float> atlas [[texture(0)]],\n"
@"                                texture2d<float> skinTex [[texture(1)]],\n"
@"                                texture2d<float> backTex [[texture(2)]]) {\n"
@"    constexpr sampler smp(coord::normalized, filter::linear, address::clamp_to_edge);\n"
@"    constexpr sampler mipSmp(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);\n"
@"    float px = scene.misc.y;\n"
@"    float master = scene.misc.w;\n"
@"    bool lin = scene.misc.z > 0.5;\n"
@"    bool flatStyle = scene.counts.w > 0.5;\n"
@"    bool realGlass = scene.skin.x > 0.5 && scene.skin.y > 0.5 && !flatStyle;\n"
@"    float2 pos = in.local;\n"
@"\n"
@"    float sd = zs_union(pos, scene);\n"
@"    float sh = zs_union(pos - float2(0.0, 2.0 * px), scene);\n"
@"    float2 grad = float2(dfdx(sd), dfdy(sd));\n"
@"\n"
@"    float shadow = (flatStyle || realGlass) ? 0.0 : exp(-max(sh, 0.0) / (5.0 * px)) * 0.30 * master;\n"
@"    float cover = saturate(0.5 - sd) * master;\n"
@"    if (!realGlass && cover <= 0.0 && shadow < 0.004) {\n"
@"        return dst;\n"
@"    }\n"
@"\n"
@"    int n = int(scene.counts.x);\n"
@"    float cells = max(scene.counts.z, 1.0);\n"
@"    float iconAcc = 0.0;\n"
@"    float pressAcc = 0.0;\n"
@"    float best = 1.0e9;\n"
@"    float2 restPos = pos;\n"
@"    for (int i = 0; i < n; i++) {\n"
@"        constant ZSItem &it = scene.items[i];\n"
@"        float2 hs = it.rect.zw * 0.5;\n"
@"        float2 c = it.rect.xy + hs;\n"
@"        float si = zs_box(pos - c, hs, it.radii);\n"
@"        pressAcc = max(pressAcc, it.params.x * saturate(0.5 - si / (3.0 * px)));\n"
@"        if (si < best) {\n"
@"            best = si;\n"
@"            restPos = (it.rest.xy + it.rest.zw * 0.5) + (pos - c) * (it.rest.zw / max(it.rect.zw, float2(1.0)));\n"
@"        }\n"
@"        float2 ip = (pos - c) / (24.0 * px) + 0.5;\n"
@"        if (ip.x >= 0.0 && ip.x <= 1.0 && ip.y >= 0.0 && ip.y <= 1.0) {\n"
@"            float a = atlas.sample(smp, float2((it.params.y + ip.x) / cells, ip.y), level(0)).a;\n"
@"            iconAcc = max(iconAcc, a * it.params.z);\n"
@"        }\n"
@"    }\n"
@"\n"
@"    float3 g = lin ? pow(max(dst.rgb, float3(0.0)), float3(1.0 / 2.2)) : dst.rgb;\n"
@"    float3 result;\n"
@"\n"
@"    if (realGlass) {\n"
@"        float2 suv = (restPos - scene.skinRect.xy) / max(scene.skinRect.zw - scene.skinRect.xy, float2(1.0));\n"
@"        float inside = step(0.0, suv.x) * step(suv.x, 1.0) * step(0.0, suv.y) * step(suv.y, 1.0);\n"
@"        float4 sk = skinTex.sample(smp, suv, level(0));\n"
@"        sk *= inside;\n"
@"        if (sk.a < 0.004) {\n"
@"            return dst;\n"
@"        }\n"
@"        float cov = smoothstep(0.03, 0.12, sk.a);\n"
@"\n"
@"        float2 texel = 1.0 / scene.back.zw;\n"
@"        float2 buv = (pos - scene.back.xy) * texel;\n"
@"\n"
@"        float3 acc = backTex.sample(mipSmp, buv, level(2.5)).rgb * 0.25;\n"
@"        float rad = 5.0 * px;\n"
@"        for (int k = 0; k < 8; k++) {\n"
@"            float ang = float(k) * 0.78539816;\n"
@"            float2 d = float2(cos(ang), sin(ang)) * rad * texel;\n"
@"            acc += backTex.sample(mipSmp, buv + d, level(2.0)).rgb * 0.09375;\n"
@"        }\n"
@"        float3 blurred = lin ? pow(max(acc, float3(0.0)), float3(1.0 / 2.2)) : acc;\n"
@"\n"
@"        float glassAlpha = saturate(max(cov * scene.skin.z, dot(sk.rgb, float3(0.299, 0.587, 0.114))));\n"
@"        float3 under = mix(g, blurred, cov);\n"
@"        float3 glassOut = sk.rgb + (1.0 - glassAlpha) * under;\n"
@"        glassOut += pressAcc * 0.08 * cov;\n"
@"        glassOut = mix(saturate(glassOut), float3(1.0), iconAcc);\n"
@"        result = mix(g, glassOut, master);\n"
@"    } else if (flatStyle) {\n"
@"        float3 body = mix(g, float3(0.08), 0.94);\n"
@"        body = mix(body, float3(1.0), iconAcc);\n"
@"        result = mix(g, body, cover);\n"
@"    } else {\n"
@"        float3 base = g * (1.0 - shadow);\n"
@"        float dist = max(-sd, 0.0);\n"
@"        float luma = dot(g, float3(0.299, 0.587, 0.114));\n"
@"        float3 body = mix(g, float3(luma), 0.5) * 0.5 + 0.055;\n"
@"\n"
@"        float2 nrm = grad / max(length(grad), 0.0001);\n"
@"        float facing = dot(nrm, normalize(float2(-0.62, -0.78)));\n"
@"        float lit = saturate(facing);\n"
@"        float back = saturate(-facing);\n"
@"        float spec = lit * lit + 0.55 * back * back;\n"
@"        float edge = exp(-dist / (2.4 * px));\n"
@"        float wide = exp(-dist / (7.0 * px));\n"
@"        float rim = 1.0 - smoothstep(0.0, 1.3 * px, dist);\n"
@"\n"
@"        body += g * edge * 0.30;\n"
@"        body += wide * lit * 0.06;\n"
@"        body += edge * spec * 0.42;\n"
@"        body += rim * (0.10 + 0.38 * spec);\n"
@"        body += pressAcc * (0.10 + 0.14 * edge);\n"
@"        body = mix(saturate(body), float3(1.0), iconAcc);\n"
@"\n"
@"        result = mix(base, body, cover);\n"
@"    }\n"
@"\n"
@"    if (lin) {\n"
@"        result = pow(max(result, float3(0.0)), float3(2.2));\n"
@"    }\n"
@"    return float4(result, dst.a);\n"
@"}\n"
@"\n"
@"struct ZSPauseUniforms {\n"
@"    float4 viewport;\n"
@"    float4 params;\n"
@"    float4 rect;\n"
@"};\n"
@"\n"
@"struct ZSPauseOut {\n"
@"    float4 position [[position]];\n"
@"    float2 local;\n"
@"};\n"
@"\n"
@"vertex ZSPauseOut zs_pause_vertex(uint vid [[vertex_id]], constant ZSPauseUniforms &u [[buffer(0)]]) {\n"
@"    float2 c = float2(float(vid & 1u), float((vid >> 1u) & 1u));\n"
@"    ZSPauseOut o;\n"
@"    o.position = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);\n"
@"    o.local = c * u.viewport.xy;\n"
@"    return o;\n"
@"}\n"
@"\n"
@"fragment float4 zs_pause_fragment(ZSPauseOut in [[stage_in]],\n"
@"                                  float4 dst [[color(0)]],\n"
@"                                  constant ZSPauseUniforms &u [[buffer(0)]],\n"
@"                                  texture2d<float> tex [[texture(0)]]) {\n"
@"    constexpr sampler smp(coord::normalized, filter::linear, address::clamp_to_edge);\n"
@"    float amount = u.params.x;\n"
@"    bool lin = u.params.y > 0.5;\n"
@"    float dim = u.params.z;\n"
@"    float3 g = lin ? pow(max(dst.rgb, float3(0.0)), float3(1.0 / 2.2)) : dst.rgb;\n"
@"    float3 dimmed = g * (1.0 - dim * amount);\n"
@"    float2 uv = (in.local - u.rect.xy) / max(u.rect.zw, float2(1.0));\n"
@"    float a = 0.0;\n"
@"    if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {\n"
@"        a = tex.sample(smp, uv, level(0)).a * amount;\n"
@"    }\n"
@"    float3 result = mix(dimmed, float3(1.0), a);\n"
@"    if (lin) {\n"
@"        result = pow(max(result, float3(0.0)), float3(2.2));\n"
@"    }\n"
@"    return float4(result, dst.a);\n"
@"}\n"
@"\n"
@"vertex ZSPauseOut zs_hud_vertex(uint vid [[vertex_id]], constant ZSPauseUniforms &u [[buffer(0)]]) {\n"
@"    float2 c = float2(float(vid & 1u), float((vid >> 1u) & 1u));\n"
@"    float2 p = u.rect.xy + c * u.rect.zw;\n"
@"    ZSPauseOut o;\n"
@"    o.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);\n"
@"    o.local = c;\n"
@"    return o;\n"
@"}\n"
@"\n"
@"fragment float4 zs_hud_fragment(ZSPauseOut in [[stage_in]],\n"
@"                                float4 dst [[color(0)]],\n"
@"                                constant ZSPauseUniforms &u [[buffer(0)]],\n"
@"                                texture2d<float> tex [[texture(0)]]) {\n"
@"    constexpr sampler smp(coord::normalized, filter::linear, address::clamp_to_edge);\n"
@"    bool lin = u.params.y > 0.5;\n"
@"    float4 t = tex.sample(smp, in.local, level(0));\n"
@"    float3 g = lin ? pow(max(dst.rgb, float3(0.0)), float3(1.0 / 2.2)) : dst.rgb;\n"
@"    float3 result = g * (1.0 - t.a) + t.rgb;\n"
@"    if (lin) {\n"
@"        result = pow(max(result, float3(0.0)), float3(2.2));\n"
@"    }\n"
@"    return float4(result, dst.a);\n"
@"}\n";

static BOOL zs_mt_format_is_linear(MTLPixelFormat format) {
    return format == MTLPixelFormatBGRA8Unorm_sRGB ||
           format == MTLPixelFormatRGBA8Unorm_sRGB ||
           format == MTLPixelFormatRGBA16Float;
}

static id<MTLRenderPipelineState> zs_mt_make_pipeline(id<MTLLibrary> library, MTLPixelFormat format) {
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"zs_tab_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"zs_tab_fragment"];
    if (!vertexFunction || !fragmentFunction) return nil;
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = format;
    descriptor.colorAttachments[0].blendingEnabled = NO;
    NSError *error = nil;
    id<MTLRenderPipelineState> state = [library.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!state) ZLog(@"[MetalTabs] pipeline creation failed: %@", error);
    return state;
}

static id<MTLRenderPipelineState> zs_mt_make_pause_pipeline(id<MTLLibrary> library, MTLPixelFormat format) {
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"zs_pause_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"zs_pause_fragment"];
    if (!vertexFunction || !fragmentFunction) return nil;
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = format;
    descriptor.colorAttachments[0].blendingEnabled = NO;
    NSError *error = nil;
    id<MTLRenderPipelineState> state = [library.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!state) ZLog(@"[MetalTabs] pause pipeline creation failed: %@", error);
    return state;
}

static id<MTLRenderPipelineState> zs_mt_make_hud_pipeline(id<MTLLibrary> library, MTLPixelFormat format) {
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"zs_hud_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"zs_hud_fragment"];
    if (!vertexFunction || !fragmentFunction) return nil;
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = format;
    descriptor.colorAttachments[0].blendingEnabled = NO;
    NSError *error = nil;
    id<MTLRenderPipelineState> state = [library.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!state) ZLog(@"[MetalTabs] hud pipeline creation failed: %@", error);
    return state;
}

static void zs_mt_hud_request_refresh(void);

static void zs_mt_request_resync(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - r_zsmtLastResync < 0.5) return;
    r_zsmtLastResync = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UserInterface shared] zs_refreshMetalTabs];
    });
}

static void zs_mt_encode(id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable) {
    if (!g_zsmtVisible && r_zsmtMaster <= 0.0f) return;

    CAMetalLayer *layer = g_zsmtLayer;
    if (!layer || drawable.layer != layer) return;
    id<MTLTexture> target = drawable.texture;
    if (!target) return;

    ZSMTRect rects[8];
    float pressTarget[8];
    int count;
    float viewW, viewH;
    BOOL visible, snap, glass;
    NSData *atlasData;
    NSData *skinData;
    int atlasVersion, atlasCellPx, atlasCells;
    int skinVersion, skinW, skinH;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> pipeline = nil;

    os_unfair_lock_lock(&g_zsmtLock);
    count = g_zsmtCount;
    memcpy(rects, g_zsmtRects, sizeof(rects));
    memcpy(pressTarget, g_zsmtPressTarget, sizeof(pressTarget));
    viewW = g_zsmtViewW;
    viewH = g_zsmtViewH;
    visible = g_zsmtVisible;
    snap = g_zsmtSnap;
    g_zsmtSnap = NO;
    glass = g_zsmtGlass;
    atlasData = g_zsmtAtlasData;
    atlasVersion = g_zsmtAtlasVersion;
    atlasCellPx = g_zsmtAtlasCellPx;
    atlasCells = g_zsmtAtlasCells;
    skinData = g_zsmtSkinData;
    skinVersion = g_zsmtSkinVersion;
    skinW = g_zsmtSkinW;
    skinH = g_zsmtSkinH;
    library = g_zsmtLibrary;
    if (g_zsmtPipelineFormat == target.pixelFormat) pipeline = g_zsmtPipeline;
    os_unfair_lock_unlock(&g_zsmtLock);

    CFTimeInterval now = CACurrentMediaTime();
    float dt = r_zsmtLastTime > 0 ? (float)MIN(MAX(now - r_zsmtLastTime, 0.0), 0.1) : 0.016f;
    r_zsmtLastTime = now;

    float masterTarget = (visible && count > 0) ? 1.0f : 0.0f;
    if (snap && masterTarget > 0.0f) r_zsmtMaster = 1.0f;
    float masterRate = 18.0f;
    r_zsmtMaster += (masterTarget - r_zsmtMaster) * (1.0f - expf(-dt * masterRate));
    if (fabsf(masterTarget - r_zsmtMaster) < 0.004f) r_zsmtMaster = masterTarget;

    float pressBlend = 1.0f - expf(-dt * 24.0f);
    for (int i = 0; i < kZSMTMaxItems; i++) {
        r_zsmtPress[i] += (pressTarget[i] - r_zsmtPress[i]) * pressBlend;
        if (fabsf(pressTarget[i] - r_zsmtPress[i]) < 0.004f) r_zsmtPress[i] = pressTarget[i];
    }

    if (r_zsmtMaster <= 0.0f || count <= 0 || viewW <= 0 || viewH <= 0 || !library) return;

    float sx = (float)target.width / viewW;
    float sy = (float)target.height / viewH;
    if (fabsf(sx - sy) / sx > 0.03f) {
        zs_mt_request_resync();
        return;
    }

    MTLPixelFormat format = target.pixelFormat;
    if (!pipeline) {
        if (r_zsmtFailedFormat == format) return;
        pipeline = zs_mt_make_pipeline(library, format);
        if (!pipeline) {
            r_zsmtFailedFormat = format;
            return;
        }
        os_unfair_lock_lock(&g_zsmtLock);
        g_zsmtPipeline = pipeline;
        g_zsmtPipelineFormat = format;
        os_unfair_lock_unlock(&g_zsmtLock);
    }

    if (atlasData.length > 0 && atlasCellPx > 0 && atlasCells > 0 && (!r_zsmtAtlas || r_zsmtAtlasVersion != atlasVersion)) {
        NSUInteger width = (NSUInteger)atlasCellPx * (NSUInteger)atlasCells;
        NSUInteger height = (NSUInteger)atlasCellPx;
        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                     width:width
                                                                                                    height:height
                                                                                                 mipmapped:NO];
        textureDescriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> atlas = [commandBuffer.device newTextureWithDescriptor:textureDescriptor];
        if (atlas && atlasData.length >= width * height * 4) {
            [atlas replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:atlasData.bytes bytesPerRow:width * 4];
            r_zsmtAtlas = atlas;
            r_zsmtAtlasVersion = atlasVersion;
        }
    }
    if (!r_zsmtAtlas) return;

    if (glass && skinData.length > 0 && skinW > 0 && skinH > 0) {
        if (!r_zsmtSkin || r_zsmtSkinVersion != skinVersion) {
            MTLTextureDescriptor *skinDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                       width:(NSUInteger)skinW
                                                                                                      height:(NSUInteger)skinH
                                                                                                   mipmapped:NO];
            skinDescriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> skin = [commandBuffer.device newTextureWithDescriptor:skinDescriptor];
            if (skin && skinData.length >= (NSUInteger)skinW * (NSUInteger)skinH * 4) {
                [skin replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)skinW, (NSUInteger)skinH) mipmapLevel:0 withBytes:skinData.bytes bytesPerRow:(NSUInteger)skinW * 4];
                r_zsmtSkin = skin;
                r_zsmtSkinVersion = skinVersion;
            }
        }
    } else {
        r_zsmtSkin = nil;
        r_zsmtSkinVersion = -1;
    }
    BOOL useReal = glass && r_zsmtSkin != nil && !layer.framebufferOnly;

    ZSMTGPUScene scene;
    memset(&scene, 0, sizeof(scene));
    float px = sx;
    float minX = 1e9f, minY = 1e9f, maxX = -1e9f, maxY = -1e9f;
    float restMinX = 1e9f, restMinY = 1e9f, restMaxX = -1e9f, restMaxY = -1e9f;
    for (int i = 0; i < count && i < kZSMTMaxItems; i++) {
        float pr = r_zsmtPress[i];
        float w = rects[i].w * (1.0f + 0.10f * pr);
        float h = rects[i].h * (1.0f + 0.06f * pr);
        float right = rects[i].x + rects[i].w;
        float cy = rects[i].y + rects[i].h * 0.5f;
        float x = right - w;
        float y = cy - h * 0.5f;
        float rx = x * sx, ry = y * sy, rw = w * sx, rh = h * sy;
        float radius = MIN((float)kZSMTCornerRadius * px, rh * 0.5f);
        scene.items[i].rect[0] = rx;
        scene.items[i].rect[1] = ry;
        scene.items[i].rect[2] = rw;
        scene.items[i].rect[3] = rh;
        scene.items[i].radii[0] = radius;
        scene.items[i].radii[1] = 0;
        scene.items[i].radii[2] = 0;
        scene.items[i].radii[3] = radius;
        scene.items[i].params[0] = pr;
        scene.items[i].params[1] = (float)i;
        scene.items[i].params[2] = i == 0 ? 0.66f : 0.85f;
        float restX = rects[i].x * sx, restY = rects[i].y * sy, restW = rects[i].w * sx, restH = rects[i].h * sy;
        scene.items[i].rest[0] = restX;
        scene.items[i].rest[1] = restY;
        scene.items[i].rest[2] = restW;
        scene.items[i].rest[3] = restH;
        restMinX = MIN(restMinX, restX);
        restMinY = MIN(restMinY, restY);
        restMaxX = MAX(restMaxX, restX + restW);
        restMaxY = MAX(restMaxY, restY + restH);
        minX = MIN(minX, rx);
        minY = MIN(minY, ry);
        maxX = MAX(maxX, rx + rw);
        maxY = MAX(maxY, ry + rh);
    }
    float margin = 18.0f * px;
    scene.viewport[0] = (float)target.width;
    scene.viewport[1] = (float)target.height;
    scene.misc[0] = margin;
    scene.misc[1] = px;
    scene.misc[2] = zs_mt_format_is_linear(format) ? 1.0f : 0.0f;
    scene.misc[3] = r_zsmtMaster;
    float quadX0 = floorf(fmaxf(minX - margin, 0.0f));
    float quadY0 = floorf(fmaxf(minY - margin, 0.0f));
    float quadX1 = ceilf(fminf(maxX + margin, (float)target.width));
    float quadY1 = ceilf(fminf(maxY + margin, (float)target.height));
    if (quadX1 <= quadX0 || quadY1 <= quadY0) return;
    float skinMargin = kZSMTSkinMargin * px;
    float regionX0 = floorf(fmaxf(restMinX - skinMargin, 0.0f));
    float regionY0 = floorf(fmaxf(restMinY - skinMargin, 0.0f));
    float regionX1 = ceilf(fminf(restMaxX + skinMargin, (float)target.width));
    float regionY1 = ceilf(fminf(restMaxY + skinMargin, (float)target.height));
    if (regionX1 <= regionX0 || regionY1 <= regionY0) return;
    quadX0 = fmaxf(quadX0, regionX0);
    quadY0 = fmaxf(quadY0, regionY0);
    quadX1 = fminf(quadX1, regionX1);
    quadY1 = fminf(quadY1, regionY1);
    if (quadX1 <= quadX0 || quadY1 <= quadY0) return;
    scene.quad[0] = quadX0;
    scene.quad[1] = quadY0;
    scene.quad[2] = quadX1;
    scene.quad[3] = quadY1;
    scene.skinRect[0] = restMinX - skinMargin;
    scene.skinRect[1] = restMinY - skinMargin;
    scene.skinRect[2] = restMaxX + skinMargin;
    scene.skinRect[3] = restMaxY + skinMargin;
    scene.counts[0] = (float)MIN(count, kZSMTMaxItems);
    scene.counts[1] = 9.0f * px;
    scene.counts[2] = (float)atlasCells;
    scene.counts[3] = glass ? 0.0f : 1.0f;

    id<MTLTexture> backdrop = nil;
    if (useReal) {
        NSUInteger copyX = (NSUInteger)regionX0;
        NSUInteger copyY = (NSUInteger)regionY0;
        NSUInteger copyW = (NSUInteger)(regionX1 - regionX0);
        NSUInteger copyH = (NSUInteger)(regionY1 - regionY0);
        if (!r_zsmtBackdrop || r_zsmtBackdrop.width != copyW || r_zsmtBackdrop.height != copyH || r_zsmtBackdrop.pixelFormat != format) {
            MTLTextureDescriptor *backDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                                      width:copyW
                                                                                                     height:copyH
                                                                                                  mipmapped:YES];
            backDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            backDescriptor.storageMode = MTLStorageModePrivate;
            r_zsmtBackdrop = [commandBuffer.device newTextureWithDescriptor:backDescriptor];
        }
        backdrop = r_zsmtBackdrop;
        if (backdrop && copyX + copyW <= target.width && copyY + copyH <= target.height) {
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            if (blit) {
                blit.label = @"ZS Pull Tab Backdrop";
                [blit copyFromTexture:target
                          sourceSlice:0
                          sourceLevel:0
                         sourceOrigin:MTLOriginMake(copyX, copyY, 0)
                           sourceSize:MTLSizeMake(copyW, copyH, 1)
                            toTexture:backdrop
                     destinationSlice:0
                     destinationLevel:0
                    destinationOrigin:MTLOriginMake(0, 0, 0)];
                [blit generateMipmapsForTexture:backdrop];
                [blit endEncoding];
                scene.back[0] = (float)copyX;
                scene.back[1] = (float)copyY;
                scene.back[2] = (float)copyW;
                scene.back[3] = (float)copyH;
            } else {
                backdrop = nil;
            }
        } else {
            backdrop = nil;
        }
    }
    scene.skin[0] = (useReal && backdrop) ? 1.0f : 0.0f;
    scene.skin[1] = (useReal && backdrop) ? 1.0f : 0.0f;
    scene.skin[2] = (float)CGColorGetAlpha(zs_glass_tint_color().CGColor);

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return;
    encoder.label = @"ZS Pull Tabs";
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBytes:&scene length:sizeof(scene) atIndex:0];
    [encoder setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    [encoder setFragmentTexture:r_zsmtAtlas atIndex:0];
    [encoder setFragmentTexture:(useReal && backdrop) ? r_zsmtSkin : r_zsmtAtlas atIndex:1];
    [encoder setFragmentTexture:(useReal && backdrop) ? backdrop : r_zsmtAtlas atIndex:2];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
}

static void zs_mt_encode_pause(id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable) {
    BOOL wanted;
    NSUInteger token;
    NSData *data;
    int texW, texH, version;
    float ptW, ptH;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> pipeline = nil;

    os_unfair_lock_lock(&g_zsmtLock);
    wanted = g_zsmtPauseWanted;
    token = g_zsmtPauseToken;
    data = g_zsmtPauseData;
    texW = g_zsmtPauseTexW;
    texH = g_zsmtPauseTexH;
    ptW = g_zsmtPausePtW;
    ptH = g_zsmtPausePtH;
    version = g_zsmtPauseVersion;
    library = g_zsmtLibrary;
    os_unfair_lock_unlock(&g_zsmtLock);

    if (!wanted && r_zsmtPauseAmount <= 0.0f) return;

    CAMetalLayer *layer = g_zsmtLayer;
    if (!layer || drawable.layer != layer) return;
    id<MTLTexture> target = drawable.texture;
    if (!target) return;

    CFTimeInterval now = CACurrentMediaTime();
    float dt = r_zsmtPauseLastTime > 0 ? (float)MIN(MAX(now - r_zsmtPauseLastTime, 0.0), 0.1) : 0.016f;
    r_zsmtPauseLastTime = now;
    float amountTarget = wanted ? 1.0f : 0.0f;
    r_zsmtPauseAmount += (amountTarget - r_zsmtPauseAmount) * (1.0f - expf(-dt * 7.0f));
    if (fabsf(amountTarget - r_zsmtPauseAmount) < 0.01f) r_zsmtPauseAmount = amountTarget;

    if (!library || data.length == 0 || texW <= 0 || texH <= 0) return;
    if (r_zsmtPauseAmount <= 0.0f) return;

    MTLPixelFormat format = target.pixelFormat;
    os_unfair_lock_lock(&g_zsmtLock);
    if (g_zsmtPausePipelineFormat == format) pipeline = g_zsmtPausePipeline;
    os_unfair_lock_unlock(&g_zsmtLock);
    if (!pipeline) {
        if (r_zsmtPauseFailedFormat == format) return;
        pipeline = zs_mt_make_pause_pipeline(library, format);
        if (!pipeline) {
            r_zsmtPauseFailedFormat = format;
            return;
        }
        os_unfair_lock_lock(&g_zsmtLock);
        g_zsmtPausePipeline = pipeline;
        g_zsmtPausePipelineFormat = format;
        os_unfair_lock_unlock(&g_zsmtLock);
    }

    if (!r_zsmtPauseTex || r_zsmtPauseVersion != version) {
        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                     width:(NSUInteger)texW
                                                                                                    height:(NSUInteger)texH
                                                                                                 mipmapped:NO];
        textureDescriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [commandBuffer.device newTextureWithDescriptor:textureDescriptor];
        if (texture && data.length >= (NSUInteger)texW * (NSUInteger)texH * 4) {
            [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)texW, (NSUInteger)texH) mipmapLevel:0 withBytes:data.bytes bytesPerRow:(NSUInteger)texW * 4];
            r_zsmtPauseTex = texture;
            r_zsmtPauseVersion = version;
        }
    }
    if (!r_zsmtPauseTex) return;

    float tw = (float)target.width;
    float th = (float)target.height;
    float unit = fminf(tw, th) / 390.0f;
    float rw = ptW * unit;
    float rh = ptH * unit;
    float rx = floorf((tw - rw) * 0.5f);
    float ry = floorf((th - rh) * 0.5f);

    float uniforms[12] = {
        tw, th, 0, 0,
        r_zsmtPauseAmount, zs_mt_format_is_linear(format) ? 1.0f : 0.0f, 0.62f, 0,
        rx, ry, rw, rh,
    };

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return;
    encoder.label = @"ZS Game Paused";
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBytes:uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBytes:uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:r_zsmtPauseTex atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];

    if (wanted && r_zsmtPauseAmount >= 1.0f && r_zsmtPauseReportedToken != token) {
        r_zsmtPauseReportedToken = token;
        [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (g_zsmtPauseWanted && g_zsmtPauseToken == token) zs_set_unity_app_paused(YES);
            });
        }];
    }
}

static void zs_mt_encode_hud(id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable) {
    BOOL wanted;
    NSData *data;
    int texW, texH, version;
    float ptW, ptH, viewW, insetTop, insetRight;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> pipeline = nil;

    os_unfair_lock_lock(&g_zsmtLock);
    wanted = g_zsmtHudWanted;
    data = g_zsmtHudData;
    texW = g_zsmtHudTexW;
    texH = g_zsmtHudTexH;
    ptW = g_zsmtHudPtW;
    ptH = g_zsmtHudPtH;
    viewW = g_zsmtHudViewW;
    insetTop = g_zsmtHudInsetTop;
    insetRight = g_zsmtHudInsetRight;
    version = g_zsmtHudVersion;
    library = g_zsmtLibrary;
    os_unfair_lock_unlock(&g_zsmtLock);

    if (!wanted) return;

    CAMetalLayer *layer = g_zsmtLayer;
    if (!layer || drawable.layer != layer) return;
    id<MTLTexture> target = drawable.texture;
    if (!target) return;

    CFTimeInterval now = CACurrentMediaTime();
    if (data.length == 0 || now - r_zsmtHudLastRequest >= 1.0) {
        r_zsmtHudLastRequest = now;
        zs_mt_hud_request_refresh();
    }

    if (!library || data.length == 0 || texW <= 0 || texH <= 0 || viewW <= 0) return;

    MTLPixelFormat format = target.pixelFormat;
    os_unfair_lock_lock(&g_zsmtLock);
    if (g_zsmtHudPipelineFormat == format) pipeline = g_zsmtHudPipeline;
    os_unfair_lock_unlock(&g_zsmtLock);
    if (!pipeline) {
        if (r_zsmtHudFailedFormat == format) return;
        pipeline = zs_mt_make_hud_pipeline(library, format);
        if (!pipeline) {
            r_zsmtHudFailedFormat = format;
            return;
        }
        os_unfair_lock_lock(&g_zsmtLock);
        g_zsmtHudPipeline = pipeline;
        g_zsmtHudPipelineFormat = format;
        os_unfair_lock_unlock(&g_zsmtLock);
    }

    if (!r_zsmtHudTex || r_zsmtHudVersion != version) {
        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                     width:(NSUInteger)texW
                                                                                                    height:(NSUInteger)texH
                                                                                                 mipmapped:NO];
        textureDescriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [commandBuffer.device newTextureWithDescriptor:textureDescriptor];
        if (texture && data.length >= (NSUInteger)texW * (NSUInteger)texH * 4) {
            [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)texW, (NSUInteger)texH) mipmapLevel:0 withBytes:data.bytes bytesPerRow:(NSUInteger)texW * 4];
            r_zsmtHudTex = texture;
            r_zsmtHudVersion = version;
        }
    }
    if (!r_zsmtHudTex) return;

    float tw = (float)target.width;
    float th = (float)target.height;
    float scale = tw / viewW;
    float rw = ceilf(ptW * scale);
    float rh = ceilf(ptH * scale);
    float rx = floorf(tw - rw - (insetRight + 8.0f) * scale);
    float ry = floorf((insetTop + 6.0f) * scale);
    if (rx < 0.0f || ry < 0.0f || rx + rw > tw || ry + rh > th) return;

    float uniforms[12] = {
        tw, th, 0, 0,
        1.0f, zs_mt_format_is_linear(format) ? 1.0f : 0.0f, 0, 0,
        rx, ry, rw, rh,
    };

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return;
    encoder.label = @"ZS RAM HUD";
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBytes:uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBytes:uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:r_zsmtHudTex atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
}

static void zs_mt_note_drawable(id commandBuffer, id drawable) {
    if (drawable) objc_setAssociatedObject(commandBuffer, kZSMTPendingDrawableKey, drawable, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void zs_mt_hook_present(id self, SEL _cmd, id drawable) {
    zs_mt_note_drawable(self, drawable);
    ((void (*)(id, SEL, id))g_zsmtOrigPresent)(self, _cmd, drawable);
}

static void zs_mt_hook_present_at(id self, SEL _cmd, id drawable, CFTimeInterval time) {
    zs_mt_note_drawable(self, drawable);
    ((void (*)(id, SEL, id, CFTimeInterval))g_zsmtOrigPresentAt)(self, _cmd, drawable, time);
}

static void zs_mt_hook_present_after(id self, SEL _cmd, id drawable, CFTimeInterval duration) {
    zs_mt_note_drawable(self, drawable);
    ((void (*)(id, SEL, id, CFTimeInterval))g_zsmtOrigPresentAfter)(self, _cmd, drawable, duration);
}

static void zs_mt_hook_commit(id self, SEL _cmd) {
    id drawable = objc_getAssociatedObject(self, kZSMTPendingDrawableKey);
    if (drawable) {
        objc_setAssociatedObject(self, kZSMTPendingDrawableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        zs_mt_encode(self, drawable);
        zs_mt_encode_pause(self, drawable);
        zs_mt_encode_hud(self, drawable);
    }
    ((void (*)(id, SEL))g_zsmtOrigCommit)(self, _cmd);
}

static void zs_mt_hook_method(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *originalOut = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

static uint8_t *zs_mt_rgba_buffer(UIImage *image, size_t *widthOut, size_t *heightOut) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return NULL;
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) return NULL;
    uint8_t *buffer = calloc(width * height * 4, 1);
    if (!buffer) return NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(buffer, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!bitmap) {
        free(buffer);
        return NULL;
    }
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(bitmap);
    *widthOut = width;
    *heightOut = height;
    return buffer;
}

static NSData *zs_mt_compose_skin(UIImage *onBlack, UIImage *onWhite, int *widthOut, int *heightOut) {
    size_t blackW = 0, blackH = 0, whiteW = 0, whiteH = 0;
    uint8_t *black = zs_mt_rgba_buffer(onBlack, &blackW, &blackH);
    uint8_t *white = zs_mt_rgba_buffer(onWhite, &whiteW, &whiteH);
    if (!black || !white || blackW != whiteW || blackH != whiteH) {
        free(black);
        free(white);
        return nil;
    }
    size_t count = blackW * blackH;
    uint8_t *skin = malloc(count * 4);
    if (!skin) {
        free(black);
        free(white);
        return nil;
    }
    int peak = 0;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *pb = black + i * 4;
        const uint8_t *pw = white + i * 4;
        int transmit = (((int)pw[0] - (int)pb[0]) + ((int)pw[1] - (int)pb[1]) + ((int)pw[2] - (int)pb[2])) / 3;
        transmit = MAX(0, MIN(255, transmit));
        int alpha = 255 - transmit;
        int luma = (pb[0] * 77 + pb[1] * 151 + pb[2] * 28) >> 8;
        uint8_t neutral = (uint8_t)MIN(luma, alpha);
        skin[i * 4 + 0] = neutral;
        skin[i * 4 + 1] = neutral;
        skin[i * 4 + 2] = neutral;
        skin[i * 4 + 3] = (uint8_t)alpha;
        if (alpha > peak) peak = alpha;
    }
    free(black);
    free(white);
    if (peak < 12) {
        free(skin);
        return nil;
    }
    *widthOut = (int)blackW;
    *heightOut = (int)blackH;
    return [NSData dataWithBytesNoCopy:skin length:count * 4 freeWhenDone:YES];
}

static NSString *zs_mt_hud_format_bytes(uint64_t bytes) {
    double mb = (double)bytes / (1024.0 * 1024.0);
    if (mb >= 1024.0) return [NSString stringWithFormat:@"%.2f GB", mb / 1024.0];
    return [NSString stringWithFormat:@"%.0f MB", mb];
}

static void zs_mt_hud_build_texture(void) {
    RamHudSnapshot snapshot;
    zs_ram_hud_get_snapshot(&snapshot);

    NSArray<NSString *> *labels = @[@"TOTAL", @"APP", @"EXT."];
    NSArray<NSString *> *values = @[
        zs_mt_hud_format_bytes(snapshot.totalBytes),
        zs_mt_hud_format_bytes(snapshot.appBytes),
        snapshot.donatedBytes > 0
            ? zs_mt_hud_format_bytes(snapshot.donatedUsedBytes)
            : @"off",
    ];

    UIView *host = zs_ui_host_view();
    CGFloat hostWidth = host.bounds.size.width;
    UIEdgeInsets insets = host.safeAreaInsets;

    static NSString *lastKey;
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%.1f|%.1f|%.1f",
                     values[0], values[1], values[2], hostWidth, insets.top, insets.right];

    os_unfair_lock_lock(&g_zsmtLock);
    BOOL hasData = g_zsmtHudData.length > 0;
    os_unfair_lock_unlock(&g_zsmtLock);

    if (hasData && [key isEqualToString:lastKey]) return;

    UIFont *font = zs_mono_font(10, UIFontWeightSemibold);
    UIColor *labelColor = [UIColor colorWithWhite:1 alpha:0.6];
    NSMutableParagraphStyle *right = [[NSMutableParagraphStyle alloc] init];
    right.alignment = NSTextAlignmentRight;

    CGFloat paddingX = 7;
    CGFloat paddingY = 5;
    CGFloat columnGap = 10;
    CGFloat lineHeight = ceil(font.lineHeight);
    CGFloat labelWidth = 0;
    CGFloat valueWidth = 0;
    for (NSUInteger i = 0; i < labels.count; i++) {
        labelWidth = MAX(labelWidth, ceil([labels[i] sizeWithAttributes:@{NSFontAttributeName: font}].width));
        valueWidth = MAX(valueWidth, ceil([values[i] sizeWithAttributes:@{NSFontAttributeName: font}].width));
    }
    valueWidth = MAX(valueWidth, ceil([@"0.00 GB" sizeWithAttributes:@{NSFontAttributeName: font}].width));

    CGFloat width = paddingX * 2 + labelWidth + columnGap + valueWidth;
    CGFloat height = paddingY * 2 + lineHeight * labels.count;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 3;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(width, height) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        UIBezierPath *background = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, width, height) cornerRadius:8];
        [[UIColor colorWithWhite:0 alpha:0.55] setFill];
        [background fill];
        for (NSUInteger i = 0; i < labels.count; i++) {
            CGFloat y = paddingY + lineHeight * (CGFloat)i;
            [labels[i] drawInRect:CGRectMake(paddingX, y, labelWidth, lineHeight)
                   withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: labelColor}];
            [values[i] drawInRect:CGRectMake(paddingX + labelWidth + columnGap, y, valueWidth, lineHeight)
                   withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: right}];
        }
    }];

    size_t pixelWidth = 0, pixelHeight = 0;
    uint8_t *buffer = zs_mt_rgba_buffer(image, &pixelWidth, &pixelHeight);
    if (!buffer) return;
    NSData *data = [NSData dataWithBytesNoCopy:buffer length:pixelWidth * pixelHeight * 4 freeWhenDone:YES];

    lastKey = key;

    os_unfair_lock_lock(&g_zsmtLock);
    g_zsmtHudData = data;
    g_zsmtHudTexW = (int)pixelWidth;
    g_zsmtHudTexH = (int)pixelHeight;
    g_zsmtHudPtW = (float)width;
    g_zsmtHudPtH = (float)height;
    g_zsmtHudViewW = (float)hostWidth;
    g_zsmtHudInsetTop = (float)insets.top;
    g_zsmtHudInsetRight = (float)insets.right;
    g_zsmtHudVersion++;
    os_unfair_lock_unlock(&g_zsmtLock);
}

static void zs_mt_hud_request_refresh(void) {
    os_unfair_lock_lock(&g_zsmtLock);
    BOOL pending = g_zsmtHudPending;
    g_zsmtHudPending = YES;
    os_unfair_lock_unlock(&g_zsmtLock);
    if (pending) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        zs_mt_hud_build_texture();
        os_unfair_lock_lock(&g_zsmtLock);
        g_zsmtHudPending = NO;
        os_unfair_lock_unlock(&g_zsmtLock);
    });
}

@implementation ZSMetalTabs {
    BOOL _installed;
    NSInteger _installAttempts;
    BOOL _visible;
    NSArray<NSValue *> *_rects;
    NSArray<NSString *> *_keys;
    NSString *_atlasSignature;
    int _atlasVersion;
    NSString *_skinSignature;
    int _skinVersion;
    __weak UITouch *_activeTouch;
    NSInteger _activeIndex;
}

+ (instancetype)shared {
    static ZSMetalTabs *instance;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        instance = [ZSMetalTabs new];
        instance->_activeIndex = -1;
    });
    return instance;
}

- (void)ensureInstalled {
    if (_installed) return;
    UIView *view = zs_unity_view();
    CAMetalLayer *layer = [view.layer isKindOfClass:[CAMetalLayer class]] ? (CAMetalLayer *)view.layer : nil;
    id<MTLDevice> device = layer.device;
    if (!layer || !device) {
        if (++_installAttempts > 60) return;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf ensureInstalled];
        });
        return;
    }

    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> probe = [queue commandBuffer];
    Class commandBufferClass = probe ? object_getClass(probe) : Nil;
    [probe commit];
    if (!commandBufferClass) return;

    _installed = YES;
    g_zsmtLayer = layer;

    zs_mt_hook_method(commandBufferClass, @selector(presentDrawable:), (IMP)zs_mt_hook_present, &g_zsmtOrigPresent);
    zs_mt_hook_method(commandBufferClass, @selector(presentDrawable:atTime:), (IMP)zs_mt_hook_present_at, &g_zsmtOrigPresentAt);
    zs_mt_hook_method(commandBufferClass, @selector(presentDrawable:afterMinimumDuration:), (IMP)zs_mt_hook_present_after, &g_zsmtOrigPresentAfter);
    zs_mt_hook_method(commandBufferClass, @selector(commit), (IMP)zs_mt_hook_commit, &g_zsmtOrigCommit);

    MTLPixelFormat format = layer.pixelFormat;
    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
    [device newLibraryWithSource:kZSMTShaderSource options:options completionHandler:^(id<MTLLibrary> library, NSError *error) {
        if (!library) {
            ZLog(@"[MetalTabs] shader compile failed: %@", error);
            return;
        }
        id<MTLRenderPipelineState> pipeline = zs_mt_make_pipeline(library, format);
        os_unfair_lock_lock(&g_zsmtLock);
        g_zsmtLibrary = library;
        if (pipeline) {
            g_zsmtPipeline = pipeline;
            g_zsmtPipelineFormat = format;
        }
        os_unfair_lock_unlock(&g_zsmtLock);
    }];

    ZLog(@"[MetalTabs] hooked %s", class_getName(commandBufferClass));
}

- (BOOL)isVisible {
    return _visible;
}

- (void)setVisible:(BOOL)visible snap:(BOOL)snap {
    _visible = visible;
    os_unfair_lock_lock(&g_zsmtLock);
    g_zsmtVisible = visible;
    if (visible && snap) g_zsmtSnap = YES;
    if (!visible) {
        for (int i = 0; i < kZSMTMaxItems; i++) g_zsmtPressTarget[i] = 0;
    }
    os_unfair_lock_unlock(&g_zsmtLock);
    if (!visible) {
        _activeTouch = nil;
        _activeIndex = -1;
    }
}

- (void)buildPauseTextureIfNeeded {
    os_unfair_lock_lock(&g_zsmtLock);
    BOOL built = g_zsmtPauseData != nil;
    os_unfair_lock_unlock(&g_zsmtLock);
    if (built) return;

    NSString *title = @"GAME PAUSED";
    NSString *subtitle = @"Texture Compression in progress";
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    NSDictionary *titleAttributes = @{
        NSFontAttributeName: zs_mono_font(34, UIFontWeightHeavy),
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSKernAttributeName: @3.0,
        NSParagraphStyleAttributeName: paragraph,
    };
    NSDictionary *subtitleAttributes = @{
        NSFontAttributeName: zs_mono_font(13, UIFontWeightMedium),
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.75],
        NSKernAttributeName: @0.6,
        NSParagraphStyleAttributeName: paragraph,
    };
    CGSize titleSize = [title sizeWithAttributes:titleAttributes];
    CGSize subtitleSize = [subtitle sizeWithAttributes:subtitleAttributes];
    CGFloat padding = 14;
    CGFloat gap = 10;
    CGFloat width = ceil(MAX(titleSize.width, subtitleSize.width)) + padding * 2;
    CGFloat height = ceil(titleSize.height + gap + subtitleSize.height) + padding * 2;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 3;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(width, height) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [title drawInRect:CGRectMake(0, padding, width, titleSize.height) withAttributes:titleAttributes];
        [subtitle drawInRect:CGRectMake(0, padding + titleSize.height + gap, width, subtitleSize.height) withAttributes:subtitleAttributes];
    }];

    size_t pixelWidth = 0, pixelHeight = 0;
    uint8_t *buffer = zs_mt_rgba_buffer(image, &pixelWidth, &pixelHeight);
    if (!buffer) return;
    NSData *data = [NSData dataWithBytesNoCopy:buffer length:pixelWidth * pixelHeight * 4 freeWhenDone:YES];

    os_unfair_lock_lock(&g_zsmtLock);
    g_zsmtPauseData = data;
    g_zsmtPauseTexW = (int)pixelWidth;
    g_zsmtPauseTexH = (int)pixelHeight;
    g_zsmtPausePtW = (float)width;
    g_zsmtPausePtH = (float)height;
    g_zsmtPauseVersion++;
    os_unfair_lock_unlock(&g_zsmtLock);
}

- (void)setRamHudVisible:(BOOL)visible {
    if (visible) [self ensureInstalled];
    os_unfair_lock_lock(&g_zsmtLock);
    g_zsmtHudWanted = visible;
    os_unfair_lock_unlock(&g_zsmtLock);
}

- (void)setPauseOverlayVisible:(BOOL)visible {
    if (visible) {
        [self ensureInstalled];
        [self buildPauseTextureIfNeeded];
    }
    os_unfair_lock_lock(&g_zsmtLock);
    BOOL changed = g_zsmtPauseWanted != visible;
    g_zsmtPauseWanted = visible;
    if (visible && changed) g_zsmtPauseToken++;
    os_unfair_lock_unlock(&g_zsmtLock);
    if (!visible && changed) zs_set_unity_app_paused(NO);
}

- (NSData *)atlasDataForSymbols:(NSArray<NSString *> *)symbols cellPixels:(int *)cellPixels {
    NSUInteger cells = symbols.count;
    if (cells == 0) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 4;
    format.opaque = NO;
    CGFloat cell = kZSMTCellPoints;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(cell * cells, cell) format:format];
    UIImage *atlas = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        for (NSUInteger i = 0; i < cells; i++) {
            CGFloat originX = cell * (CGFloat)i;
            NSString *symbol = symbols[i];
            if (symbol.length == 0) {
                NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
                paragraph.alignment = NSTextAlignmentCenter;
                NSDictionary *attributes = @{
                    NSFontAttributeName: zs_mono_font(15, UIFontWeightLight),
                    NSForegroundColorAttributeName: UIColor.whiteColor,
                    NSParagraphStyleAttributeName: paragraph,
                };
                NSString *chevron = @"\u2039";
                CGSize textSize = [chevron sizeWithAttributes:attributes];
                [chevron drawInRect:CGRectMake(originX, (cell - textSize.height) * 0.5, cell, textSize.height) withAttributes:attributes];
            } else {
                UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
                UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:configuration];
                image = [image imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
                CGSize size = image.size;
                [image drawInRect:CGRectMake(originX + (cell - size.width) * 0.5, (cell - size.height) * 0.5, size.width, size.height)];
            }
        }
    }];

    CGImageRef cgImage = atlas.CGImage;
    if (!cgImage) return nil;
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) return nil;
    uint8_t *buffer = calloc(width * height * 4, 1);
    if (!buffer) return nil;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(buffer, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!bitmap) {
        free(buffer);
        return nil;
    }
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(bitmap);
    if (cellPixels) *cellPixels = (int)(width / cells);
    return [NSData dataWithBytesNoCopy:buffer length:width * height * 4 freeWhenDone:YES];
}

- (UIImage *)glassStageImageOverColor:(UIColor *)color rects:(NSArray<NSValue *> *)rects box:(CGRect)box scale:(CGFloat)scale host:(UIView *)host {
    UIView *stage = [[UIView alloc] initWithFrame:CGRectMake(-box.size.width - 64, 0, box.size.width, box.size.height)];
    stage.backgroundColor = color;
    stage.userInteractionEnabled = NO;
    stage.clipsToBounds = YES;

    UIVisualEffectView *container = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_container_effect(kZSMTGlassSpacing)];
    container.frame = stage.bounds;
    [stage addSubview:container];

    for (NSValue *value in rects) {
        CGRect r = value.CGRectValue;
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:zs_make_glass_effect_dark(NO)];
        glass.frame = CGRectMake(r.origin.x - box.origin.x, r.origin.y - box.origin.y, r.size.width, r.size.height);
        zs_configure_glass_corners_sides(glass, kZSMTCornerRadius, NO, YES, NO);
        [container.contentView addSubview:glass];
    }

    [host addSubview:stage];
    [stage layoutIfNeeded];

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:box.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [stage drawViewHierarchyInRect:stage.bounds afterScreenUpdates:YES];
    }];
    [stage removeFromSuperview];
    return image;
}

- (void)refreshGlassSkinForRects:(NSArray<NSValue *> *)rects glass:(BOOL)glass {
    if (!glass || rects.count == 0) {
        if (_skinSignature) {
            _skinSignature = nil;
            os_unfair_lock_lock(&g_zsmtLock);
            g_zsmtSkinData = nil;
            g_zsmtSkinW = 0;
            g_zsmtSkinH = 0;
            g_zsmtSkinVersion = ++_skinVersion;
            os_unfair_lock_unlock(&g_zsmtLock);
        }
        return;
    }

    CGRect unionRect = CGRectNull;
    for (NSValue *value in rects) unionRect = CGRectUnion(unionRect, value.CGRectValue);

    NSMutableString *signature = [NSMutableString string];
    for (NSValue *value in rects) {
        CGRect r = value.CGRectValue;
        [signature appendFormat:@"%.1f,%.1f,%.1f,%.1f;", r.origin.x - unionRect.origin.x, r.origin.y - unionRect.origin.y, r.size.width, r.size.height];
    }
    if ([signature isEqualToString:_skinSignature]) return;

    UIView *host = zs_ui_host_view();
    if (!host) return;
    _skinSignature = signature;

    CGRect box = CGRectInset(unionRect, -kZSMTSkinMargin, -kZSMTSkinMargin);
    CGFloat scale = MAX(host.traitCollection.displayScale, 1.0);

    UIImage *onBlack = [self glassStageImageOverColor:UIColor.blackColor rects:rects box:box scale:scale host:host];
    UIImage *onWhite = [self glassStageImageOverColor:UIColor.whiteColor rects:rects box:box scale:scale host:host];

    int width = 0, height = 0;
    NSData *skin = (onBlack && onWhite) ? zs_mt_compose_skin(onBlack, onWhite, &width, &height) : nil;
    if (!skin) ZLog(@"[MetalTabs] real glass capture produced no usable pixels, using procedural glass");

    os_unfair_lock_lock(&g_zsmtLock);
    g_zsmtSkinData = skin;
    g_zsmtSkinW = skin ? width : 0;
    g_zsmtSkinH = skin ? height : 0;
    g_zsmtSkinVersion = ++_skinVersion;
    os_unfair_lock_unlock(&g_zsmtLock);
}

- (void)updateWithViewSize:(CGSize)size
                     rects:(NSArray<NSValue *> *)rects
                      keys:(NSArray<NSString *> *)keys
                   symbols:(NSArray<NSString *> *)symbols
                     glass:(BOOL)glass
                   visible:(BOOL)visible
                      snap:(BOOL)snap {
    NSUInteger count = MIN(rects.count, (NSUInteger)kZSMTMaxItems);
    _rects = [rects subarrayWithRange:NSMakeRange(0, count)];
    _keys = [keys subarrayWithRange:NSMakeRange(0, MIN(keys.count, count))];

    [self refreshGlassSkinForRects:_rects glass:glass];

    NSString *signature = [symbols componentsJoinedByString:@"|"];
    NSData *atlas = nil;
    int cellPixels = 0;
    BOOL rebuildAtlas = ![signature isEqualToString:_atlasSignature];
    if (rebuildAtlas) {
        atlas = [self atlasDataForSymbols:[symbols subarrayWithRange:NSMakeRange(0, MIN(symbols.count, count))] cellPixels:&cellPixels];
        _atlasSignature = signature;
        _atlasVersion++;
    }

    os_unfair_lock_lock(&g_zsmtLock);
    g_zsmtCount = (int)count;
    for (NSUInteger i = 0; i < count; i++) {
        CGRect r = rects[i].CGRectValue;
        g_zsmtRects[i] = (ZSMTRect){(float)r.origin.x, (float)r.origin.y, (float)r.size.width, (float)r.size.height};
    }
    g_zsmtViewW = (float)size.width;
    g_zsmtViewH = (float)size.height;
    g_zsmtGlass = glass;
    if (rebuildAtlas) {
        g_zsmtAtlasData = atlas;
        g_zsmtAtlasVersion = _atlasVersion;
        g_zsmtAtlasCellPx = cellPixels;
        g_zsmtAtlasCells = (int)count;
    }
    os_unfair_lock_unlock(&g_zsmtLock);

    [self setVisible:visible snap:snap];
}

- (NSInteger)hitIndexForPoint:(CGPoint)point slop:(CGSize)slop {
    NSInteger best = -1;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < _rects.count; i++) {
        CGRect rect = CGRectInset(_rects[i].CGRectValue, -slop.width, -slop.height);
        if (!CGRectContainsPoint(rect, point)) continue;
        CGRect original = _rects[i].CGRectValue;
        CGFloat distance = fabs(point.y - CGRectGetMidY(original));
        if (distance < bestDistance) {
            bestDistance = distance;
            best = (NSInteger)i;
        }
    }
    return best;
}

- (void)setPress:(float)value forIndex:(NSInteger)index {
    if (index < 0 || index >= kZSMTMaxItems) return;
    os_unfair_lock_lock(&g_zsmtLock);
    g_zsmtPressTarget[index] = value;
    os_unfair_lock_unlock(&g_zsmtLock);
}

- (BOOL)touchBegan:(UITouch *)touch inView:(UIView *)view {
    if (!_visible || _activeTouch || _rects.count == 0) return NO;
    NSInteger index = [self hitIndexForPoint:[touch locationInView:view] slop:CGSizeMake(8, 2)];
    if (index < 0) return NO;
    _activeTouch = touch;
    _activeIndex = index;
    [self setPress:1 forIndex:index];
    return YES;
}

- (BOOL)touch:(UITouch *)touch isInsideIndex:(NSInteger)index inView:(UIView *)view {
    if (index < 0 || index >= (NSInteger)_rects.count) return NO;
    CGRect rect = CGRectInset(_rects[index].CGRectValue, -24, -24);
    return CGRectContainsPoint(rect, [touch locationInView:view]);
}

- (void)touchMoved:(UITouch *)touch inView:(UIView *)view {
    if (!_activeTouch || touch != _activeTouch) return;
    [self setPress:[self touch:touch isInsideIndex:_activeIndex inView:view] ? 1 : 0 forIndex:_activeIndex];
}

- (void)touchEnded:(UITouch *)touch inView:(UIView *)view cancelled:(BOOL)cancelled {
    if (!_activeTouch || touch != _activeTouch) return;
    NSInteger index = _activeIndex;
    BOOL inside = !cancelled && [self touch:touch isInsideIndex:index inView:view];
    _activeTouch = nil;
    _activeIndex = -1;
    [self setPress:0 forIndex:index];
    if (inside && index < (NSInteger)_keys.count) {
        [[UserInterface shared] zs_metalTabActivatedForKey:_keys[index]];
    }
}

@end

@implementation ZSPassthroughEffectView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@implementation ZSPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@implementation ZSPinScrimView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectContainsPoint(self.passthroughRect, point)) return nil;
    return [super hitTest:point withEvent:event];
}
@end

@implementation ZSSelectModeOverlayView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
@end

NSString * const kZSSelectModeCellID = @"ZSSelectModeCell";

typedef NS_ENUM(NSInteger, ZSSelectModeRowKind) {
    ZSSelectModeRowKindInfo = 0,
    ZSSelectModeRowKindSection,
    ZSSelectModeRowKindLocation,
    ZSSelectModeRowKindMessage,
};

static NSString *zs_select_mode_short_cab(NSString *cab) {
    NSString *identifier = [cab hasPrefix:@"CAB-"] ? [cab substringFromIndex:4] : cab;
    NSString *head = identifier.length > 12 ? [[identifier substringToIndex:12] stringByAppendingString:@"…"] : identifier;
    return [@"CAB-" stringByAppendingString:head];
}

static NSArray<ZSAssetLocation *> *zs_select_mode_unique_locations(NSArray<ZSAssetLocation *> *locations) {
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:locations.count];
    NSMutableArray<ZSAssetLocation *> *unique = [NSMutableArray arrayWithCapacity:locations.count];
    for (ZSAssetLocation *location in locations) {
        NSString *key = [NSString stringWithFormat:@"%@|%lld", location.filePath.length > 0 ? location.filePath : location.cabIdentifier, (long long)location.pathID];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [unique addObject:location];
    }
    return unique;
}

static NSDictionary *zs_select_mode_row(ZSSelectModeRowKind kind, NSAttributedString *text, ZSAssetLocation *location) {
    NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObjectsAndKeys:@(kind), @"kind", text, @"text", nil];
    if (location) row[@"location"] = location;
    return row;
}

NSArray<NSDictionary *> *zs_select_mode_message_rows(NSString *text, BOOL warning) {
    UIFont *medium = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    UIColor *color = warning ? [UIColor colorWithRed:1.0 green:0.62 blue:0.25 alpha:1.0] : [UIColor colorWithWhite:1 alpha:0.55];
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: medium, NSForegroundColorAttributeName: color}];
    return @[zs_select_mode_row(ZSSelectModeRowKindMessage, attributed, nil)];
}

NSArray<NSDictionary *> *zs_select_mode_rows(NSDictionary *hit, NSArray<ZSAssetLocation *> *spriteLocations, NSArray<ZSAssetLocation *> *textureLocations, NSArray<ZSAssetLocation *> *meshLocations, NSUInteger position, NSUInteger total, BOOL loading, BOOL indexing) {
    UIFont *bold = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    UIFont *small = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    UIFont *medium = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    UIFont *mono = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    UIColor *dim = [UIColor colorWithWhite:1 alpha:0.55];

    NSString *spriteName = hit[@"spriteName"];
    NSString *textureName = hit[@"textureName"];
    NSString *meshName = hit[@"meshName"];
    NSMutableAttributedString *info = [[NSMutableAttributedString alloc] init];
    NSString *title = meshName.length > 0 ? meshName : (spriteName.length > 0 ? spriteName : (textureName.length > 0 ? textureName : @"(unnamed)"));
    [info appendAttributedString:[[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: bold, NSForegroundColorAttributeName: UIColor.whiteColor}]];

    NSMutableArray<NSString *> *details = [NSMutableArray array];
    if (hit[@"source"]) [details addObject:hit[@"source"]];
    if ([hit[@"owner"] length] > 0) [details addObject:hit[@"owner"]];
    if (hit[@"width"] && hit[@"height"]) [details addObject:[NSString stringWithFormat:@"%@×%@", hit[@"width"], hit[@"height"]]];
    if ([hit[@"packed"] boolValue]) [details addObject:@"atlas-packed"];
    if (textureName.length > 0 && spriteName.length > 0) [details addObject:[@"texture " stringByAppendingString:textureName]];
    if (total > 1) [details addObject:[NSString stringWithFormat:@"%lu of %lu here", (unsigned long)(position + 1), (unsigned long)total]];
    if (details.count > 0) {
        [info appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:[details componentsJoinedByString:@" · "]] attributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: dim}]];
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    [rows addObject:zs_select_mode_row(ZSSelectModeRowKindInfo, info, nil)];

    if (loading) {
        [rows addObject:zs_select_mode_row(ZSSelectModeRowKindMessage, [[NSAttributedString alloc] initWithString:@"Looking up bundles…" attributes:@{NSFontAttributeName: medium, NSForegroundColorAttributeName: dim}], nil)];
        return rows;
    }

    NSArray<ZSAssetLocation *> *sprites = zs_select_mode_unique_locations(spriteLocations);
    NSArray<ZSAssetLocation *> *textures = zs_select_mode_unique_locations(textureLocations);
    NSArray<ZSAssetLocation *> *meshes = zs_select_mode_unique_locations(meshLocations);

    void (^appendGroup)(NSString *, NSArray<ZSAssetLocation *> *) = ^(NSString *label, NSArray<ZSAssetLocation *> *locations) {
        if (locations.count == 0) return;
        NSString *heading = [NSString stringWithFormat:@"%@ · %lu %@", label, (unsigned long)locations.count, locations.count == 1 ? @"bundle" : @"bundles"];
        [rows addObject:zs_select_mode_row(ZSSelectModeRowKindSection, [[NSAttributedString alloc] initWithString:heading attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: dim}], nil)];
        for (ZSAssetLocation *location in locations) {
            NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:location.bundleName.length > 0 ? location.bundleName : @"(unnamed bundle)" attributes:@{NSFontAttributeName: medium, NSForegroundColorAttributeName: UIColor.whiteColor}];
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:zs_select_mode_short_cab(location.cabIdentifier)] attributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: zs_accent_green_color()}]];
            [rows addObject:zs_select_mode_row(ZSSelectModeRowKindLocation, text, location)];
        }
    };
    appendGroup(@"Sprite", sprites);
    appendGroup(@"Texture", textures);
    appendGroup(@"Mesh", meshes);

    if (sprites.count == 0 && textures.count == 0 && meshes.count == 0) {
        NSString *message = indexing ? @"Not found yet. Indexing is still running, tap the same spot again in a moment." : @"Not found in indexed bundles";
        [rows addObject:zs_select_mode_row(ZSSelectModeRowKindMessage, [[NSAttributedString alloc] initWithString:message attributes:@{NSFontAttributeName: medium, NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.62 blue:0.25 alpha:1.0]}], nil)];
    }
    return rows;
}

@implementation ZSSelectModeCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[UIView alloc] init];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = 12;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    [self.contentView addSubview:_card];

    _label = [[UILabel alloc] init];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.numberOfLines = 0;
    [_card addSubview:_label];

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:config]];
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.45];
    _chevron.contentMode = UIViewContentModeCenter;
    [_card addSubview:_chevron];

    _chevronWidth = [_chevron.widthAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
        [_label.topAnchor constraintEqualToAnchor:_card.topAnchor constant:9],
        [_label.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-9],
        [_label.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
        [_label.trailingAnchor constraintEqualToAnchor:_chevron.leadingAnchor constant:-4],
        [_chevron.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-10],
        [_chevron.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        _chevronWidth,
    ]];
    return self;
}

- (void)configureWithRow:(NSDictionary *)row {
    ZSSelectModeRowKind kind = (ZSSelectModeRowKind)[row[@"kind"] integerValue];
    self.label.attributedText = row[@"text"];
    self.showsCard = kind == ZSSelectModeRowKindInfo || kind == ZSSelectModeRowKindLocation;
    self.card.backgroundColor = self.showsCard ? [UIColor colorWithWhite:1 alpha:0.07] : UIColor.clearColor;
    self.chevronWidth.constant = kind == ZSSelectModeRowKindLocation ? 14 : 0;
    self.chevron.hidden = kind != ZSSelectModeRowKindLocation;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    if (!self.showsCard || self.chevron.hidden) return;
    self.card.backgroundColor = [UIColor colorWithWhite:1 alpha:highlighted ? 0.18 : 0.07];
}

@end

@implementation ZSSelectModeList

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ZSSelectModeCell *cell = [tableView dequeueReusableCellWithIdentifier:kZSSelectModeCellID forIndexPath:indexPath];
    [cell configureWithRow:self.rows[(NSUInteger)indexPath.row]];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self.rows[(NSUInteger)indexPath.row][@"kind"] integerValue] == ZSSelectModeRowKindLocation;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    NSDictionary *row = self.rows[(NSUInteger)indexPath.row];
    if ([row[@"kind"] integerValue] != ZSSelectModeRowKindLocation) return;
    ZSAssetLocation *location = row[@"location"];
    if (location && self.onLocation) self.onLocation(location);
}

@end

static const void *kZSHostOwnedViewKey = &kZSHostOwnedViewKey;

void zs_mark_host_owned(UIView *view) {
    if (view) objc_setAssociatedObject(view, kZSHostOwnedViewKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL zs_touch_belongs_to_host_ui(UITouch *touch, UIView *hostView) {
    UIView *view = touch.view;
    while (view && view != hostView) {
        if (objc_getAssociatedObject(view, kZSHostOwnedViewKey)) return YES;
        view = view.superview;
    }
    return NO;
}

void zs_install_unity_touch_filter(UIView *hostView) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [hostView class];
        NSHashTable<UITouch *> *swallowed = [NSHashTable weakObjectsHashTable];

        SEL selectors[] = {
            @selector(touchesBegan:withEvent:),
            @selector(touchesMoved:withEvent:),
            @selector(touchesEnded:withEvent:),
            @selector(touchesCancelled:withEvent:),
        };
        for (NSUInteger i = 0; i < 4; i++) {
            SEL selector = selectors[i];
            BOOL isBegan = selector == @selector(touchesBegan:withEvent:);
            BOOL isTerminal = selector == @selector(touchesEnded:withEvent:) || selector == @selector(touchesCancelled:withEvent:);
            BOOL isCancel = selector == @selector(touchesCancelled:withEvent:);

            Method method = class_getInstanceMethod(cls, selector);
            if (!method) continue;
            IMP original = method_getImplementation(method);
            const char *encoding = method_getTypeEncoding(method);

            IMP replacement = imp_implementationWithBlock(^(UIView *receiver, NSSet<UITouch *> *touches, UIEvent *event) {
                NSMutableSet<UITouch *> *forwarded = nil;
                for (UITouch *touch in touches) {
                    BOOL swallow;
                    if (isBegan) {
                        swallow = zs_touch_belongs_to_host_ui(touch, receiver);
                        if (!swallow) swallow = [[ZSMetalTabs shared] touchBegan:touch inView:receiver];
                        if (swallow) [swallowed addObject:touch];
                    } else {
                        swallow = [swallowed containsObject:touch];
                        if (swallow) {
                            if (isTerminal) {
                                [[ZSMetalTabs shared] touchEnded:touch inView:receiver cancelled:isCancel];
                            } else {
                                [[ZSMetalTabs shared] touchMoved:touch inView:receiver];
                            }
                        }
                        if (isTerminal && swallow) [swallowed removeObject:touch];
                    }
                    if (swallow) continue;
                    if (!forwarded) forwarded = [NSMutableSet setWithCapacity:touches.count];
                    [forwarded addObject:touch];
                }
                if (forwarded.count == 0) return;
                ((void (*)(id, SEL, NSSet *, UIEvent *))original)(receiver, selector, forwarded, event);
            });
            class_replaceMethod(cls, selector, replacement, encoding);
        }
    });
}
