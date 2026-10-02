#include <metal_stdlib>
using namespace metal;

struct ZSLRGPUParams {
    uint width;
    uint height;
    uint block;
    uint blocksX;
    uint srgb;
};

static float3 zslr_srgb_to_linear(float3 value) {
    float3 low = value / 12.92f;
    float3 high = pow((value + 0.055f) / 1.055f, float3(2.4f));
    return select(low, high, value > 0.04045f);
}

static float3 zslr_linear_to_srgb(float3 value) {
    float3 low = value * 12.92f;
    float3 high = 1.055f * pow(value, float3(1.0f / 2.4f)) - 0.055f;
    return select(low, high, value > 0.0031308f);
}

kernel void zslr_astc_encode_void_extent(
    texture2d<float, access::sample> source [[texture(0)]],
    device uint *encoded [[buffer(0)]],
    device float *metrics [[buffer(1)]],
    constant ZSLRGPUParams &params [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]) {
    uint blocksY = (params.height + params.block - 1) / params.block;
    if (gid.x >= params.blocksX || gid.y >= blocksY) return;

    uint x0 = gid.x * params.block;
    uint y0 = gid.y * params.block;
    uint x1 = min(x0 + params.block, params.width);
    uint y1 = min(y0 + params.block, params.height);
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float3 sumRGB = float3(0.0f);
    float3 sumRGBSquared = float3(0.0f);
    float3 sumAlphaRGB = float3(0.0f);
    float3 sumAlphaRGBSquared = float3(0.0f);
    float sumAlpha = 0.0f;
    float sumAlphaSquared = 0.0f;
    uint count = 0;
    for (uint y = y0; y < y1; y++) {
        for (uint x = x0; x < x1; x++) {
            float2 coord = (float2(x, y) + 0.5f) / float2(params.width, params.height);
            float4 original = source.sample(nearestSampler, coord);
            sumRGB += original.rgb;
            sumRGBSquared += original.rgb * original.rgb;
            sumAlphaRGB += original.rgb * original.a;
            sumAlphaRGBSquared += original.rgb * original.rgb * original.a;
            sumAlpha += original.a;
            sumAlphaSquared += original.a * original.a;
            count++;
        }
    }
    float3 averageRGB = sumAlpha > 0.0f ? sumAlphaRGB / sumAlpha : sumRGB / float(count);
    float averageAlpha = sumAlpha / float(count);
    float3 encodedRGB = params.srgb != 0 ? zslr_linear_to_srgb(averageRGB) : averageRGB;
    ushort4 color = ushort4(round(clamp(float4(encodedRGB, averageAlpha), float4(0.0f), float4(1.0f)) * 65535.0f));
    float4 quantized = float4(color) / 65535.0f;
    float3 reconstructedRGB = params.srgb != 0 ? zslr_srgb_to_linear(quantized.rgb) : quantized.rgb;
    float4 reconstructed = float4(reconstructedRGB, quantized.a);

    float3 reconstructedSquared = reconstructed.rgb * reconstructed.rgb;
    float rawRGBError = dot(sumRGBSquared, float3(1.0f)) - 2.0f * dot(reconstructed.rgb, sumRGB) + dot(reconstructedSquared, float3(float(count)));
    float rawAlphaError = max(0.0f, sumAlphaSquared - 2.0f * reconstructed.a * sumAlpha + reconstructed.a * reconstructed.a * float(count));
    float rgbWeightedError = dot(sumAlphaRGBSquared, float3(1.0f)) - 2.0f * dot(reconstructed.rgb, sumAlphaRGB) + dot(reconstructedSquared, float3(sumAlpha));
    float rawError = max(0.0f, rawRGBError + rawAlphaError);
    rgbWeightedError = max(0.0f, rgbWeightedError);
    float alphaError = max(0.0f, rawAlphaError);

    uint blockIndex = gid.y * params.blocksX + gid.x;
    uint outputIndex = blockIndex * 4;
    encoded[outputIndex] = 0xFFFFFDFCu;
    encoded[outputIndex + 1] = 0xFFFFFFFFu;
    encoded[outputIndex + 2] = uint(color.r) | (uint(color.g) << 16);
    encoded[outputIndex + 3] = uint(color.b) | (uint(color.a) << 16);
    uint metricIndex = blockIndex * 4;
    metrics[metricIndex] = rawError;
    metrics[metricIndex + 1] = rgbWeightedError;
    metrics[metricIndex + 2] = sumAlpha;
    metrics[metricIndex + 3] = alphaError;
}
