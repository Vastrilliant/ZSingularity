#include <metal_stdlib>
using namespace metal;

struct ZSLRGPUParams {
    uint width;
    uint height;
    uint block;
    uint blocksX;
    uint srgb;
    uint rowOffset;
    uint rowCount;
};

struct ZSLRConfig {
    uchar wx;
    uchar wy;
    uchar bits;
    uchar pad;
    ushort mode;
    ushort levelsRGB;
    ushort levelsRGBA;
};

constant uchar kZSLRTrit[243] = {
0,1,2,4,5,6,8,9,10,16,17,18,20,21,22,24,
25,26,3,7,11,19,23,27,12,13,14,32,33,34,36,37,
38,40,41,42,48,49,50,52,53,54,56,57,58,35,39,43,
51,55,59,44,45,46,64,65,66,68,69,70,72,73,74,80,
81,82,84,85,86,88,89,90,67,71,75,83,87,91,76,77,
78,128,129,130,132,133,134,136,137,138,144,145,146,148,149,150,
152,153,154,131,135,139,147,151,155,140,141,142,160,161,162,164,
165,166,168,169,170,176,177,178,180,181,182,184,185,186,163,167,
171,179,183,187,172,173,174,192,193,194,196,197,198,200,201,202,
208,209,210,212,213,214,216,217,218,195,199,203,211,215,219,204,
205,206,96,97,98,100,101,102,104,105,106,112,113,114,116,117,
118,120,121,122,99,103,107,115,119,123,108,109,110,224,225,226,
228,229,230,232,233,234,240,241,242,244,245,246,248,249,250,227,
231,235,243,247,251,236,237,238,28,29,30,60,61,62,92,93,
94,156,157,158,188,189,190,220,221,222,31,63,95,159,191,223,
124,125,126
};
constant uchar kZSLRDec32[32] = {
0,8,16,24,33,41,49,57,66,74,82,90,99,107,115,123,
132,140,148,156,165,173,181,189,198,206,214,222,231,239,247,255
};
constant uchar kZSLREnc32[256] = {
0,0,0,0,0,1,1,1,1,1,1,1,1,2,2,2,
2,2,2,2,2,3,3,3,3,3,3,3,3,4,4,4,
4,4,4,4,4,4,5,5,5,5,5,5,5,5,6,6,
6,6,6,6,6,6,7,7,7,7,7,7,7,7,8,8,
8,8,8,8,8,8,8,9,9,9,9,9,9,9,9,10,
10,10,10,10,10,10,10,11,11,11,11,11,11,11,11,12,
12,12,12,12,12,12,12,12,13,13,13,13,13,13,13,13,
14,14,14,14,14,14,14,14,15,15,15,15,15,15,15,15,
16,16,16,16,16,16,16,16,16,17,17,17,17,17,17,17,
17,18,18,18,18,18,18,18,18,19,19,19,19,19,19,19,
19,20,20,20,20,20,20,20,20,20,21,21,21,21,21,21,
21,21,22,22,22,22,22,22,22,22,23,23,23,23,23,23,
23,23,24,24,24,24,24,24,24,24,24,25,25,25,25,25,
25,25,25,26,26,26,26,26,26,26,26,27,27,27,27,27,
27,27,27,28,28,28,28,28,28,28,28,28,29,29,29,29,
29,29,29,29,30,30,30,30,30,30,30,30,31,31,31,31
};
constant uchar kZSLRDec48[48] = {
0,255,16,239,32,223,48,207,65,190,81,174,97,158,113,142,
5,250,21,234,38,217,54,201,70,185,86,169,103,152,119,136,
11,244,27,228,43,212,59,196,76,179,92,163,108,147,124,131
};
constant uchar kZSLREnc48[256] = {
0,0,0,16,16,16,16,16,16,32,32,32,32,32,2,2,
2,2,2,18,18,18,18,18,18,34,34,34,34,34,4,4,
4,4,4,4,20,20,20,20,20,36,36,36,36,36,6,6,
6,6,6,6,22,22,22,22,22,38,38,38,38,38,38,8,
8,8,8,8,24,24,24,24,24,24,40,40,40,40,40,10,
10,10,10,10,26,26,26,26,26,26,42,42,42,42,42,12,
12,12,12,12,12,28,28,28,28,28,44,44,44,44,44,14,
14,14,14,14,14,30,30,30,30,30,46,46,46,46,46,46,
47,47,47,47,47,47,31,31,31,31,31,31,15,15,15,15,
15,45,45,45,45,45,29,29,29,29,29,29,13,13,13,13,
13,43,43,43,43,43,43,27,27,27,27,27,11,11,11,11,
11,41,41,41,41,41,41,25,25,25,25,25,9,9,9,9,
9,9,39,39,39,39,39,23,23,23,23,23,23,7,7,7,
7,7,37,37,37,37,37,21,21,21,21,21,21,5,5,5,
5,5,35,35,35,35,35,35,19,19,19,19,19,3,3,3,
3,3,33,33,33,33,33,33,17,17,17,17,17,1,1,1
};
constant uchar kZSLRDec64[64] = {
0,4,8,12,16,20,24,28,32,36,40,44,48,52,56,60,
65,69,73,77,81,85,89,93,97,101,105,109,113,117,121,125,
130,134,138,142,146,150,154,158,162,166,170,174,178,182,186,190,
195,199,203,207,211,215,219,223,227,231,235,239,243,247,251,255
};
constant uchar kZSLREnc64[256] = {
0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,
4,4,4,5,5,5,5,6,6,6,6,7,7,7,7,8,
8,8,8,9,9,9,9,10,10,10,10,11,11,11,11,12,
12,12,12,13,13,13,13,14,14,14,14,15,15,15,15,16,
16,16,16,16,17,17,17,17,18,18,18,18,19,19,19,19,
20,20,20,20,21,21,21,21,22,22,22,22,23,23,23,23,
24,24,24,24,25,25,25,25,26,26,26,26,27,27,27,27,
28,28,28,28,29,29,29,29,30,30,30,30,31,31,31,31,
32,32,32,32,32,33,33,33,33,34,34,34,34,35,35,35,
35,36,36,36,36,37,37,37,37,38,38,38,38,39,39,39,
39,40,40,40,40,41,41,41,41,42,42,42,42,43,43,43,
43,44,44,44,44,45,45,45,45,46,46,46,46,47,47,47,
47,48,48,48,48,48,49,49,49,49,50,50,50,50,51,51,
51,51,52,52,52,52,53,53,53,53,54,54,54,54,55,55,
55,55,56,56,56,56,57,57,57,57,58,58,58,58,59,59,
59,59,60,60,60,60,61,61,61,61,62,62,62,62,63,63
};
constant uchar kZSLRDec96[96] = {
0,255,8,247,16,239,24,231,32,223,40,215,48,207,56,199,
64,191,72,183,80,175,88,167,96,159,104,151,112,143,120,135,
2,253,10,245,18,237,26,229,35,220,43,212,51,204,59,196,
67,188,75,180,83,172,91,164,99,156,107,148,115,140,123,132,
5,250,13,242,21,234,29,226,37,218,45,210,53,202,61,194,
70,185,78,177,86,169,94,161,102,153,110,145,118,137,126,129
};
constant uchar kZSLREnc96[256] = {
0,0,32,32,64,64,64,2,2,2,34,34,66,66,66,4,
4,4,36,36,68,68,68,6,6,6,38,38,70,70,70,8,
8,8,40,40,40,72,72,10,10,10,42,42,42,74,74,12,
12,12,44,44,44,76,76,14,14,14,46,46,46,78,78,16,
16,16,48,48,48,80,80,80,18,18,50,50,50,82,82,82,
20,20,52,52,52,84,84,84,22,22,54,54,54,86,86,86,
24,24,56,56,56,88,88,88,26,26,58,58,58,90,90,90,
28,28,60,60,60,92,92,92,30,30,62,62,62,94,94,94,
95,95,95,63,63,63,31,31,31,93,93,61,61,61,29,29,
29,91,91,59,59,59,27,27,27,89,89,57,57,57,25,25,
25,87,87,55,55,55,23,23,23,85,85,53,53,53,21,21,
21,83,83,51,51,51,19,19,19,81,81,49,49,49,17,17,
17,79,79,79,47,47,15,15,15,77,77,77,45,45,13,13,
13,75,75,75,43,43,11,11,11,73,73,73,41,41,9,9,
9,71,71,71,39,39,39,7,7,69,69,69,37,37,37,5,
5,67,67,67,35,35,35,3,3,65,65,65,33,33,33,1
};
constant uchar kZSLRDec192[192] = {
0,255,4,251,8,247,12,243,16,239,20,235,24,231,28,227,
32,223,36,219,40,215,44,211,48,207,52,203,56,199,60,195,
64,191,68,187,72,183,76,179,80,175,84,171,88,167,92,163,
96,159,100,155,104,151,108,147,112,143,116,139,120,135,124,131,
1,254,5,250,9,246,13,242,17,238,21,234,25,230,29,226,
33,222,37,218,41,214,45,210,49,206,53,202,57,198,61,194,
65,190,69,186,73,182,77,178,81,174,85,170,89,166,93,162,
97,158,101,154,105,150,109,146,113,142,117,138,121,134,125,130,
2,253,6,249,10,245,14,241,18,237,22,233,26,229,30,225,
34,221,38,217,42,213,46,209,50,205,54,201,58,197,62,193,
66,189,70,185,74,181,78,177,82,173,86,169,90,165,94,161,
98,157,102,153,106,149,110,145,114,141,118,137,122,133,126,129
};
constant uchar kZSLREnc192[256] = {
0,64,128,128,2,66,130,130,4,68,132,132,6,70,134,134,
8,72,136,136,10,74,138,138,12,76,140,140,14,78,142,142,
16,80,144,144,18,82,146,146,20,84,148,148,22,86,150,150,
24,88,152,152,26,90,154,154,28,92,156,156,30,94,158,158,
32,96,160,160,34,98,162,162,36,100,164,164,38,102,166,166,
40,104,168,168,42,106,170,170,44,108,172,172,46,110,174,174,
48,112,176,176,50,114,178,178,52,116,180,180,54,118,182,182,
56,120,184,184,58,122,186,186,60,124,188,188,62,126,190,190,
191,191,127,63,63,189,125,61,61,187,123,59,59,185,121,57,
57,183,119,55,55,181,117,53,53,179,115,51,51,177,113,49,
49,175,111,47,47,173,109,45,45,171,107,43,43,169,105,41,
41,167,103,39,39,165,101,37,37,163,99,35,35,161,97,33,
33,159,95,31,31,157,93,29,29,155,91,27,27,153,89,25,
25,151,87,23,23,149,85,21,21,147,83,19,19,145,81,17,
17,143,79,15,15,141,77,13,13,139,75,11,11,137,73,9,
9,135,71,7,7,133,69,5,5,131,67,3,3,129,65,1
};
constant uchar kZSLRDec256[256] = {
0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,
48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,
80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,
96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,
112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,
128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,
176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,
192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,
208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,
224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,
240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255
};
constant uchar kZSLREnc256[256] = {
0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,
48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,
80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,
96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,
112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,
128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,
176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,
192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,
208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,
224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,
240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255
};

constant ZSLRConfig kZSLRConfigs8[10] = {
{8,8,1,0,1348,192,48},
{7,5,2,0,482,96,32},
{5,7,2,0,238,96,32},
{8,2,3,0,23,256,192},
{5,5,3,0,243,64,0},
{5,8,2,0,106,32,0},
{8,5,2,0,102,32,0},
{2,8,4,0,522,192,48},
{8,6,1,0,324,256,192},
{4,8,2,0,74,192,48}
};
constant ZSLRConfig kZSLRConfigs10[10] = {
{8,8,1,0,1348,192,48},
{5,8,2,0,106,32,0},
{7,5,2,0,482,96,32},
{8,7,1,0,836,256,96},
{3,7,3,0,191,256,64},
{8,5,2,0,102,32,0},
{8,2,4,0,518,192,48},
{7,8,1,0,1316,256,96},
{8,2,3,0,23,256,192},
{4,8,2,0,74,192,48}
};
constant ZSLRConfig kZSLRConfigs12[10] = {
{8,8,1,0,1348,192,48},
{5,8,2,0,106,32,0},
{7,5,2,0,482,96,32},
{8,7,1,0,836,256,96},
{8,2,4,0,518,192,48},
{7,8,1,0,1316,256,96},
{8,5,2,0,102,32,0},
{5,5,3,0,243,64,0},
{4,8,2,0,74,192,48},
{6,2,4,0,770,256,192}
};

static float zslr_linear_to_srgb(float value) {
    value = clamp(value, 0.0f, 1.0f);
    return value <= 0.0031308f ? value * 12.92f : 1.055f * pow(value, 1.0f / 2.4f) - 0.055f;
}

static void zslr_put(thread uint *blk, uint pos, uint count, uint value) {
    for (uint i = 0; i < count; i++) {
        uint p = pos + i;
        blk[p >> 5] |= ((value >> i) & 1u) << (p & 31u);
    }
}

static uint zslr_put_trits(thread uint *blk, uint pos, thread const uint *idx, uint n, uint k) {
    uint p = pos;
    for (uint g = 0; g < n; g += 5) {
        uint cnt = min(5u, n - g);
        uint ts[5];
        uint ms[5];
        for (uint j = 0; j < 5; j++) {
            uint v = j < cnt ? idx[g + j] : 0u;
            ts[j] = v >> k;
            ms[j] = v & ((1u << k) - 1u);
        }
        uint T = kZSLRTrit[ts[0] + 3u * ts[1] + 9u * ts[2] + 27u * ts[3] + 81u * ts[4]];
        for (uint j = 0; j < cnt; j++) {
            zslr_put(blk, p, k, ms[j]);
            p += k;
            uint tlen = (j == 0u || j == 1u || j == 3u) ? 2u : 1u;
            uint tpos = j == 0u ? 0u : (j == 1u ? 2u : (j == 2u ? 4u : (j == 3u ? 5u : 7u)));
            zslr_put(blk, p, tlen, (T >> tpos) & ((1u << tlen) - 1u));
            p += tlen;
        }
    }
    return p - pos;
}

static constant uchar *zslr_enc_table(uint levels) {
    switch (levels) {
        case 32: return kZSLREnc32;
        case 48: return kZSLREnc48;
        case 64: return kZSLREnc64;
        case 96: return kZSLREnc96;
        case 192: return kZSLREnc192;
        default: return kZSLREnc256;
    }
}

static constant uchar *zslr_dec_table(uint levels) {
    switch (levels) {
        case 32: return kZSLRDec32;
        case 48: return kZSLRDec48;
        case 64: return kZSLRDec64;
        case 96: return kZSLRDec96;
        case 192: return kZSLRDec192;
        default: return kZSLRDec256;
    }
}

static uint zslr_range_bits(uint levels, thread bool *trit) {
    *trit = false;
    switch (levels) {
        case 16: return 4u;
        case 32: return 5u;
        case 64: return 6u;
        case 128: return 7u;
        case 24: *trit = true; return 3u;
        case 48: *trit = true; return 4u;
        case 96: *trit = true; return 5u;
        case 192: *trit = true; return 6u;
        default: return 8u;
    }
}

static uint zslr_weight_unquant(uint bits, uint index) {
    uint v;
    switch (bits) {
        case 1: v = index ? 63u : 0u; break;
        case 2: v = index * 21u; break;
        case 3: v = (index << 3) | index; break;
        default: v = (index << 2) | (index >> 2); break;
    }
    return v > 32u ? v + 1u : v;
}

static void zslr_infill(uint s, uint t, uint bw, uint bh, uint wx, uint wy, thread uint *v0, thread uint *w) {
    uint ds = (1024u + bw / 2u) / (bw - 1u);
    uint dt = (1024u + bh / 2u) / (bh - 1u);
    uint gs = ((ds * s) * (wx - 1u) + 32u) >> 6;
    uint gt = ((dt * t) * (wy - 1u) + 32u) >> 6;
    uint js = gs >> 4;
    uint jt = gt >> 4;
    uint fs = gs & 15u;
    uint ft = gt & 15u;
    uint w11 = (fs * ft + 8u) >> 4;
    *v0 = js + wx * jt;
    w[0] = 16u - fs - ft + w11;
    w[1] = fs - w11;
    w[2] = ft - w11;
    w[3] = w11;
}

static void zslr_solve_grid(thread const float *px, thread const float *vw, uint n,
                            thread const uint *iv, thread const uint *ipw, uint wx, uint ng, uint dims,
                            thread const float *e0, thread const float *e1,
                            thread const float *den, uint bits, thread uint *gi, thread float *wd, uint iterations) {
    float dir[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    float len2 = 0.0f;
    for (uint c = 0; c < dims; c++) {
        dir[c] = e1[c] - e0[c];
        len2 += dir[c] * dir[c];
    }
    float u[144];
    float g[64];
    float acc[64];
    float inv = len2 > 1e-10f ? 1.0f / len2 : 0.0f;
    for (uint j = 0; j < ng; j++) {
        g[j] = 0.0f;
        acc[j] = 0.0f;
    }
    for (uint i = 0; i < n; i++) {
        float d = 0.0f;
        for (uint c = 0; c < dims; c++) d += (px[i * 4 + c] - e0[c]) * dir[c];
        u[i] = len2 > 1e-10f ? clamp(d * inv, 0.0f, 1.0f) : 0.5f;
        uint base = iv[i];
        uint pw = ipw[i];
        for (uint k = 0; k < 4; k++) {
            uint w = (pw >> (8u * k)) & 255u;
            if (w == 0u) continue;
            uint j = base + (k & 1u) + (k >> 1) * wx;
            float a = float(w) * (1.0f / 16.0f);
            g[j] += a * vw[i] * u[i];
            acc[j] += a * vw[i];
        }
    }
    for (uint j = 0; j < ng; j++) g[j] = acc[j] > 1e-6f ? g[j] / acc[j] : 0.5f;
    for (uint it = 0; it < iterations; it++) {
        for (uint j = 0; j < ng; j++) acc[j] = 0.0f;
        for (uint i = 0; i < n; i++) {
            uint base = iv[i];
            uint pw = ipw[i];
            float pred = 0.0f;
            for (uint k = 0; k < 4; k++) {
                uint w = (pw >> (8u * k)) & 255u;
                if (w == 0u) continue;
                pred += float(w) * (1.0f / 16.0f) * g[base + (k & 1u) + (k >> 1) * wx];
            }
            float r = vw[i] * (u[i] - pred);
            for (uint k = 0; k < 4; k++) {
                uint w = (pw >> (8u * k)) & 255u;
                if (w == 0u) continue;
                acc[base + (k & 1u) + (k >> 1) * wx] += float(w) * (1.0f / 16.0f) * r;
            }
        }
        for (uint j = 0; j < ng; j++) {
            if (den[j] > 1e-6f) g[j] = clamp(g[j] + 0.6f * acc[j] / den[j], 0.0f, 1.0f);
        }
    }
    uint levels = 1u << bits;
    float table[16];
    for (uint l = 0; l < levels; l++) table[l] = float(zslr_weight_unquant(bits, l)) * (1.0f / 64.0f);
    for (uint j = 0; j < ng; j++) {
        uint best = 0;
        float bestDist = 1e30f;
        for (uint l = 0; l < levels; l++) {
            float d = fabs(table[l] - g[j]);
            if (d < bestDist) {
                bestDist = d;
                best = l;
            }
        }
        gi[j] = best;
    }
    for (uint i = 0; i < n; i++) {
        uint base = iv[i];
        uint pw = ipw[i];
        uint sum = 8u;
        for (uint k = 0; k < 4; k++) {
            uint w = (pw >> (8u * k)) & 255u;
            if (w == 0u) continue;
            sum += w * zslr_weight_unquant(bits, gi[base + (k & 1u) + (k >> 1) * wx]);
        }
        wd[i] = float(sum >> 4) * (1.0f / 64.0f);
    }
}

static void zslr_solve_endpoints(thread const float *px, thread const float *vw, uint n, uint dims,
                                 thread const float *wd, thread float *e0, thread float *e1) {
    for (uint c = 0; c < dims; c++) {
        float a00 = 0.0f;
        float a01 = 0.0f;
        float a11 = 0.0f;
        float b0 = 0.0f;
        float b1 = 0.0f;
        for (uint i = 0; i < n; i++) {
            float w = wd[i];
            float iw = 1.0f - w;
            float m = vw[i];
            float p = px[i * 4 + c];
            a00 += m * iw * iw;
            a01 += m * iw * w;
            a11 += m * w * w;
            b0 += m * iw * p;
            b1 += m * w * p;
        }
        float det = a00 * a11 - a01 * a01;
        if (det > 1e-5f) {
            e0[c] = clamp((a11 * b0 - a01 * b1) / det, 0.0f, 1.0f);
            e1[c] = clamp((a00 * b1 - a01 * b0) / det, 0.0f, 1.0f);
        }
    }
}

static float zslr_block_error(thread const float *px, thread const float *vw, uint n, uint dims,
                              thread const uint *iv, thread const uint *ipw, uint wx, uint bits,
                              thread const uint *gi, thread const float *d0, thread const float *d1) {
    uint table[16];
    uint levels = 1u << bits;
    for (uint l = 0; l < levels; l++) table[l] = zslr_weight_unquant(bits, l);
    float err = 0.0f;
    for (uint i = 0; i < n; i++) {
        uint base = iv[i];
        uint pw = ipw[i];
        uint sum = 8u;
        for (uint k = 0; k < 4; k++) {
            uint w = (pw >> (8u * k)) & 255u;
            if (w == 0u) continue;
            sum += w * table[gi[base + (k & 1u) + (k >> 1) * wx]];
        }
        float w = float(sum >> 4) * (1.0f / 64.0f);
        for (uint c = 0; c < dims; c++) {
            float v = d0[c] + (d1[c] - d0[c]) * w;
            float diff = px[i * 4 + c] * 255.0f - v;
            err += vw[i] * diff * diff;
        }
    }
    return err;
}

static float zslr_eval_config(thread const float *px, thread const float *vw, uint bw, uint bh,
                              uint wx, uint wy, uint bits, uint levels, uint dims,
                              thread const float *init0, thread const float *init1,
                              uint passes, uint iterA, uint iterB, thread uint *ep, thread uint *gi) {
    uint n = bw * bh;
    uint ng = wx * wy;
    uint iv[144];
    uint ipw[144];
    float wd[144];
    float den[64];
    for (uint j = 0; j < ng; j++) den[j] = 0.0f;
    for (uint i = 0; i < n; i++) {
        uint w4[4];
        uint v0;
        zslr_infill(i % bw, i / bw, bw, bh, wx, wy, &v0, w4);
        iv[i] = v0;
        ipw[i] = w4[0] | (w4[1] << 8) | (w4[2] << 16) | (w4[3] << 24);
        for (uint k = 0; k < 4; k++) {
            if (w4[k] == 0u) continue;
            float a = float(w4[k]) * (1.0f / 16.0f);
            den[v0 + (k & 1u) + (k >> 1) * wx] += vw[i] * a * a;
        }
    }
    float e0[4];
    float e1[4];
    for (uint c = 0; c < 4; c++) {
        e0[c] = init0[c];
        e1[c] = init1[c];
    }
    for (uint pass = 0; pass < passes; pass++) {
        zslr_solve_grid(px, vw, n, iv, ipw, wx, ng, dims, e0, e1, den, bits, gi, wd, iterA);
        zslr_solve_endpoints(px, vw, n, dims, wd, e0, e1);
    }
    constant uchar *enc = zslr_enc_table(levels);
    constant uchar *dec = zslr_dec_table(levels);
    float d0[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    float d1[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    for (uint c = 0; c < dims; c++) {
        uint a = enc[uint(round(clamp(e0[c], 0.0f, 1.0f) * 255.0f))];
        uint b = enc[uint(round(clamp(e1[c], 0.0f, 1.0f) * 255.0f))];
        ep[c * 2] = a;
        ep[c * 2 + 1] = b;
        d0[c] = float(dec[a]);
        d1[c] = float(dec[b]);
    }
    if (d1[0] + d1[1] + d1[2] < d0[0] + d0[1] + d0[2]) {
        for (uint c = 0; c < dims; c++) {
            uint t = ep[c * 2];
            ep[c * 2] = ep[c * 2 + 1];
            ep[c * 2 + 1] = t;
            float f = d0[c];
            d0[c] = d1[c];
            d1[c] = f;
        }
    }
    float f0[4];
    float f1[4];
    for (uint c = 0; c < 4; c++) {
        f0[c] = d0[c] * (1.0f / 255.0f);
        f1[c] = d1[c] * (1.0f / 255.0f);
    }
    zslr_solve_grid(px, vw, n, iv, ipw, wx, ng, dims, f0, f1, den, bits, gi, wd, iterB);
    return zslr_block_error(px, vw, n, dims, iv, ipw, wx, bits, gi, d0, d1);
}

static void zslr_encode_block(thread const float *px, thread const float *vw, uint bw, uint bh,
                              constant ZSLRConfig *cfgs, uint cfgCount, thread uint *out) {
    uint n = bw * bh;
    out[0] = 0u;
    out[1] = 0u;
    out[2] = 0u;
    out[3] = 0u;

    float lo[4] = { 1.0f, 1.0f, 1.0f, 1.0f };
    float hi[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    float mean[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    float count = 0.0f;
    for (uint i = 0; i < n; i++) {
        if (vw[i] <= 0.0f) continue;
        count += 1.0f;
        for (uint c = 0; c < 4; c++) {
            float v = px[i * 4 + c];
            lo[c] = min(lo[c], v);
            hi[c] = max(hi[c], v);
            mean[c] += v;
        }
    }
    float range = 0.0f;
    for (uint c = 0; c < 4; c++) {
        mean[c] /= max(count, 1.0f);
        range = max(range, hi[c] - lo[c]);
    }

    if (range <= 1.5f / 255.0f) {
        uint q[4];
        for (uint c = 0; c < 4; c++) q[c] = uint(round(clamp(mean[c], 0.0f, 1.0f) * 65535.0f));
        out[0] = 0xFFFFFDFCu;
        out[1] = 0xFFFFFFFFu;
        out[2] = q[0] | (q[1] << 16);
        out[3] = q[2] | (q[3] << 16);
        return;
    }

    bool rgba = lo[3] < 0.998f;
    uint dims = rgba ? 4u : 3u;

    float cov[16];
    for (uint i = 0; i < 16; i++) cov[i] = 0.0f;
    for (uint i = 0; i < n; i++) {
        if (vw[i] <= 0.0f) continue;
        float d[4];
        for (uint c = 0; c < dims; c++) d[c] = px[i * 4 + c] - mean[c];
        for (uint a = 0; a < dims; a++) {
            for (uint b = 0; b < dims; b++) cov[a * 4 + b] += d[a] * d[b];
        }
    }
    float axis[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    for (uint c = 0; c < dims; c++) axis[c] = hi[c] - lo[c];
    for (uint it = 0; it < 6; it++) {
        float nv[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        float len = 0.0f;
        for (uint a = 0; a < dims; a++) {
            for (uint b = 0; b < dims; b++) nv[a] += cov[a * 4 + b] * axis[b];
            len += nv[a] * nv[a];
        }
        len = sqrt(len);
        if (len < 1e-12f) break;
        for (uint a = 0; a < dims; a++) axis[a] = nv[a] / len;
    }
    float tmin = 1e30f;
    float tmax = -1e30f;
    for (uint i = 0; i < n; i++) {
        if (vw[i] <= 0.0f) continue;
        float t = 0.0f;
        for (uint c = 0; c < dims; c++) t += (px[i * 4 + c] - mean[c]) * axis[c];
        tmin = min(tmin, t);
        tmax = max(tmax, t);
    }
    float init0[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    float init1[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    for (uint c = 0; c < dims; c++) {
        init0[c] = clamp(mean[c] + axis[c] * tmin, 0.0f, 1.0f);
        init1[c] = clamp(mean[c] + axis[c] * tmax, 0.0f, 1.0f);
    }

    float scores[16];
    for (uint ci = 0; ci < cfgCount; ci++) {
        scores[ci] = 1e30f;
        uint levels = rgba ? cfgs[ci].levelsRGBA : cfgs[ci].levelsRGB;
        if (levels == 0u) continue;
        uint tmpEp[8];
        uint tmpGrid[64];
        scores[ci] = zslr_eval_config(px, vw, bw, bh, cfgs[ci].wx, cfgs[ci].wy, cfgs[ci].bits, levels, dims,
                                      init0, init1, 1u, 2u, 2u, tmpEp, tmpGrid);
    }

    float bestErr = 1e30f;
    uint bestCfg = 0;
    uint bestEp[8];
    uint bestGrid[64];
    uint bestLevels = 256u;
    for (uint i = 0; i < 8; i++) bestEp[i] = 0u;
    for (uint i = 0; i < 64; i++) bestGrid[i] = 0u;
    for (uint round2 = 0; round2 < 2; round2++) {
        uint pick = cfgCount;
        float pickScore = 1e29f;
        for (uint ci = 0; ci < cfgCount; ci++) {
            if (scores[ci] < pickScore) {
                pickScore = scores[ci];
                pick = ci;
            }
        }
        if (pick == cfgCount) break;
        scores[pick] = 1e30f;
        uint levels = rgba ? cfgs[pick].levelsRGBA : cfgs[pick].levelsRGB;
        uint tmpEp[8];
        uint tmpGrid[64];
        float err = zslr_eval_config(px, vw, bw, bh, cfgs[pick].wx, cfgs[pick].wy, cfgs[pick].bits, levels, dims,
                                     init0, init1, 3u, 4u, 6u, tmpEp, tmpGrid);
        if (err < bestErr) {
            bestErr = err;
            bestCfg = pick;
            bestLevels = levels;
            for (uint i = 0; i < dims * 2u; i++) bestEp[i] = tmpEp[i];
            for (uint j = 0; j < cfgs[pick].wx * cfgs[pick].wy; j++) bestGrid[j] = tmpGrid[j];
        }
    }

    uint wx = cfgs[bestCfg].wx;
    uint wy = cfgs[bestCfg].wy;
    uint bits = cfgs[bestCfg].bits;
    zslr_put(out, 0, 11, cfgs[bestCfg].mode);
    zslr_put(out, 13, 4, rgba ? 12u : 8u);
    bool trit;
    uint k = zslr_range_bits(bestLevels, &trit);
    uint nv = dims * 2u;
    if (trit) {
        zslr_put_trits(out, 17, bestEp, nv, k);
    } else {
        for (uint i = 0; i < nv; i++) zslr_put(out, 17u + i * k, k, bestEp[i]);
    }
    uint ng = wx * wy;
    for (uint j = 0; j < ng; j++) {
        for (uint b = 0; b < bits; b++) {
            if ((bestGrid[j] >> b) & 1u) {
                uint pos = 127u - (j * bits + b);
                out[pos >> 5] |= 1u << (pos & 31u);
            }
        }
    }
}
kernel void zslr_astc_encode(
    texture2d<float, access::sample> source [[texture(0)]],
    device uint *encoded [[buffer(0)]],
    constant ZSLRGPUParams &params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]) {
    uint blockY = gid.y + params.rowOffset;
    uint blocksY = (params.height + params.block - 1) / params.block;
    if (gid.x >= params.blocksX || gid.y >= params.rowCount || blockY >= blocksY) return;

    uint x0 = gid.x * params.block;
    uint y0 = blockY * params.block;
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float px[576];
    float vw[144];
    uint n = 0;
    for (uint y = 0; y < params.block; y++) {
        uint sy = min(y0 + y, params.height - 1);
        for (uint x = 0; x < params.block; x++) {
            uint sx = min(x0 + x, params.width - 1);
            float2 coord = (float2(sx, sy) + 0.5f) / float2(params.width, params.height);
            float4 original = source.sample(nearestSampler, coord);
            if (params.srgb != 0) {
                original.r = zslr_linear_to_srgb(original.r);
                original.g = zslr_linear_to_srgb(original.g);
                original.b = zslr_linear_to_srgb(original.b);
            }
            px[n * 4] = original.r;
            px[n * 4 + 1] = original.g;
            px[n * 4 + 2] = original.b;
            px[n * 4 + 3] = original.a;
            vw[n] = (y0 + y < params.height && x0 + x < params.width) ? 1.0f : 0.0f;
            n++;
        }
    }

    constant ZSLRConfig *cfgs = kZSLRConfigs8;
    uint cfgCount = 10u;
    if (params.block == 10u) {
        cfgs = kZSLRConfigs10;
    } else if (params.block == 12u) {
        cfgs = kZSLRConfigs12;
    }

    uint blk[4];
    zslr_encode_block(px, vw, params.block, params.block, cfgs, cfgCount, blk);

    uint outputIndex = (blockY * params.blocksX + gid.x) * 4;
    encoded[outputIndex] = blk[0];
    encoded[outputIndex + 1] = blk[1];
    encoded[outputIndex + 2] = blk[2];
    encoded[outputIndex + 3] = blk[3];
}
