#include <metal_stdlib>
using namespace metal;

struct ZSAParams {
    uint width;
    uint height;
    uint block;
    uint blocksX;
    uint srgb;
    uint rowOffset;
    uint rowCount;
    uint count;
};


constant uchar kZSATrit[243] = {
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

constant uchar kZSADec48[48] = {
0,255,16,239,32,223,48,207,65,190,81,174,97,158,113,142,
5,250,21,234,38,217,54,201,70,185,86,169,103,152,119,136,
11,244,27,228,43,212,59,196,76,179,92,163,108,147,124,131
};
constant uchar kZSAEnc48[256] = {
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

constant uchar kZSADec192[192] = {
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
constant uchar kZSAEnc192[256] = {
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

static float zsa_linear_to_srgb(float value) {
    value = clamp(value, 0.0f, 1.0f);
    return value <= 0.0031308f ? value * 12.92f : 1.055f * pow(value, 1.0f / 2.4f) - 0.055f;
}

static void zsa_put(thread uint *blk, uint pos, uint count, uint value) {
    for (uint i = 0; i < count; i++) {
        uint p = pos + i;
        blk[p >> 5] |= ((value >> i) & 1u) << (p & 31u);
    }
}

static uint zsa_put_trits(thread uint *blk, uint pos, thread const uint *idx, uint n, uint k) {
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
        uint T = kZSATrit[ts[0] + 3u * ts[1] + 9u * ts[2] + 27u * ts[3] + 81u * ts[4]];
        for (uint j = 0; j < cnt; j++) {
            zsa_put(blk, p, k, ms[j]);
            p += k;
            uint tlen = (j == 0u || j == 1u || j == 3u) ? 2u : 1u;
            uint tpos = j == 0u ? 0u : (j == 1u ? 2u : (j == 2u ? 4u : (j == 3u ? 5u : 7u)));
            zsa_put(blk, p, tlen, (T >> tpos) & ((1u << tlen) - 1u));
            p += tlen;
        }
    }
    return p - pos;
}

static float4 zsa_unpack(uint p) {
    return float4(float(p & 255u), float((p >> 8) & 255u), float((p >> 16) & 255u), float(p >> 24)) * (1.0f / 255.0f);
}

template <uint BW>
static float zsa_encode_block_fast(thread const uint *pk, thread uint *out) {
    const uint N = BW * BW;
    out[0] = 0u;
    out[1] = 0u;
    out[2] = 0u;
    out[3] = 0u;

    float px[N * 4];
    for (uint i = 0; i < N; i++) {
        float4 p = zsa_unpack(pk[i]);
        px[i * 4] = p.x;
        px[i * 4 + 1] = p.y;
        px[i * 4 + 2] = p.z;
        px[i * 4 + 3] = p.w;
    }

    float lo[4] = { 1.0f, 1.0f, 1.0f, 1.0f };
    float hi[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    float mean[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    for (uint i = 0; i < N; i++) {
        for (uint c = 0; c < 4; c++) {
            float v = px[i * 4 + c];
            lo[c] = min(lo[c], v);
            hi[c] = max(hi[c], v);
            mean[c] += v;
        }
    }
    float range = 0.0f;
    for (uint c = 0; c < 4; c++) {
        mean[c] /= float(N);
        range = max(range, hi[c] - lo[c]);
    }

    if (range <= 1.5f / 255.0f) {
        uint q[4];
        for (uint c = 0; c < 4; c++) q[c] = uint(round(clamp(mean[c], 0.0f, 1.0f) * 65535.0f));
        out[0] = 0xFFFFFDFCu;
        out[1] = 0xFFFFFFFFu;
        out[2] = q[0] | (q[1] << 16);
        out[3] = q[2] | (q[3] << 16);
        float voidErr = 0.0f;
        for (uint i = 0; i < N; i++) {
            for (uint c = 0; c < 4; c++) {
                float d = px[i * 4 + c] * 255.0f - float(q[c] >> 8);
                voidErr += d * d;
            }
        }
        return voidErr;
    }

    bool rgba = lo[3] < 0.998f;
    uint dims = rgba ? 4u : 3u;

    float cov[16];
    for (uint i = 0; i < 16; i++) cov[i] = 0.0f;
    for (uint i = 0; i < N; i++) {
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

    float proj[N];
    uint lab[N];
    float tmin = 1e30f;
    float tmax = -1e30f;
    for (uint i = 0; i < N; i++) {
        float t = 0.0f;
        for (uint c = 0; c < dims; c++) t += (px[i * 4 + c] - mean[c]) * axis[c];
        proj[i] = t;
        tmin = min(tmin, t);
        tmax = max(tmax, t);
    }
    uint ones = 0;
    for (uint i = 0; i < N; i++) {
        lab[i] = proj[i] > 0.0f ? 1u : 0u;
        ones += lab[i];
    }
    if (ones == 0u || ones == N) {
        float mid = 0.5f * (tmin + tmax);
        for (uint i = 0; i < N; i++) lab[i] = proj[i] > mid ? 1u : 0u;
    }

    float c0[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    float c1[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    for (uint it = 0; it <= 4; it++) {
        float s0[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        float s1[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        uint n0 = 0;
        uint n1 = 0;
        for (uint i = 0; i < N; i++) {
            if (lab[i]) {
                n1++;
                for (uint c = 0; c < dims; c++) s1[c] += px[i * 4 + c];
            } else {
                n0++;
                for (uint c = 0; c < dims; c++) s0[c] += px[i * 4 + c];
            }
        }
        if (n0 == 0u || n1 == 0u) {
            for (uint c = 0; c < dims; c++) {
                c0[c] = lo[c];
                c1[c] = hi[c];
            }
            break;
        }
        for (uint c = 0; c < dims; c++) {
            c0[c] = s0[c] / float(n0);
            c1[c] = s1[c] / float(n1);
        }
        if (it == 4u) break;
        bool changed = false;
        for (uint i = 0; i < N; i++) {
            float d0 = 0.0f;
            float d1 = 0.0f;
            for (uint c = 0; c < dims; c++) {
                float v = px[i * 4 + c];
                d0 += (v - c0[c]) * (v - c0[c]);
                d1 += (v - c1[c]) * (v - c1[c]);
            }
            uint nl = d1 < d0 ? 1u : 0u;
            if (nl != lab[i]) changed = true;
            lab[i] = nl;
        }
        if (!changed) break;
    }

    uint i0[4] = { 0u, 0u, 0u, 0u };
    uint i1[4] = { 0u, 0u, 0u, 0u };
    uint d0v[4] = { 0u, 0u, 0u, 0u };
    uint d1v[4] = { 0u, 0u, 0u, 0u };
    for (uint c = 0; c < dims; c++) {
        uint v0 = uint(round(clamp(c0[c], 0.0f, 1.0f) * 255.0f));
        uint v1 = uint(round(clamp(c1[c], 0.0f, 1.0f) * 255.0f));
        if (rgba) {
            i0[c] = kZSAEnc48[v0];
            i1[c] = kZSAEnc48[v1];
            d0v[c] = kZSADec48[i0[c]];
            d1v[c] = kZSADec48[i1[c]];
        } else {
            i0[c] = kZSAEnc192[v0];
            i1[c] = kZSAEnc192[v1];
            d0v[c] = kZSADec192[i0[c]];
            d1v[c] = kZSADec192[i1[c]];
        }
    }
    if (d1v[0] + d1v[1] + d1v[2] < d0v[0] + d0v[1] + d0v[2]) {
        for (uint c = 0; c < dims; c++) {
            uint t = i0[c]; i0[c] = i1[c]; i1[c] = t;
            t = d0v[c]; d0v[c] = d1v[c]; d1v[c] = t;
        }
    }

    float fastErr = 0.0f;
    for (uint i = 0; i < N; i++) {
        float e0 = 0.0f;
        float e1 = 0.0f;
        for (uint c = 0; c < dims; c++) {
            float v = px[i * 4 + c] * 255.0f;
            e0 += (v - float(d0v[c])) * (v - float(d0v[c]));
            e1 += (v - float(d1v[c])) * (v - float(d1v[c]));
        }
        lab[i] = e1 < e0 ? 1u : 0u;
        fastErr += min(e0, e1);
    }

    uint node[64];
    for (uint i = 0; i < 64; i++) node[i] = 0u;
    if (BW == 8u) {
        for (uint i = 0; i < 64; i++) node[i] = lab[i];
    } else {
        float num[64];
        float den[64];
        for (uint i = 0; i < 64; i++) {
            num[i] = 0.0f;
            den[i] = 0.0f;
        }
        uint ds = (1024u + BW / 2u) / (BW - 1u);
        for (uint t = 0; t < BW; t++) {
            for (uint s = 0; s < BW; s++) {
                uint gs = ((ds * s) * 7u + 32u) >> 6;
                uint gt = ((ds * t) * 7u + 32u) >> 6;
                uint js = gs >> 4;
                uint jt = gt >> 4;
                uint fs = gs & 15u;
                uint ft = gt & 15u;
                uint v0 = js + 8u * jt;
                uint w11 = (fs * ft + 8u) >> 4;
                uint w10 = ft - w11;
                uint w01 = fs - w11;
                uint w00 = 16u - fs - ft + w11;
                float target = float(lab[t * BW + s]);
                if (w00) { num[v0] += float(w00) * target; den[v0] += float(w00); }
                if (w01) { num[v0 + 1u] += float(w01) * target; den[v0 + 1u] += float(w01); }
                if (w10) { num[v0 + 8u] += float(w10) * target; den[v0 + 8u] += float(w10); }
                if (w11) { num[v0 + 9u] += float(w11) * target; den[v0 + 9u] += float(w11); }
            }
        }
        for (uint i = 0; i < 64; i++) node[i] = (den[i] > 0.0f && num[i] / den[i] >= 0.5f) ? 1u : 0u;
    }

    uint vals[8];
    for (uint c = 0; c < dims; c++) {
        vals[c * 2] = i0[c];
        vals[c * 2 + 1] = i1[c];
    }
    zsa_put(out, 0, 11, 0x544u);
    zsa_put(out, 13, 4, rgba ? 12u : 8u);
    zsa_put_trits(out, 17, vals, dims * 2u, rgba ? 4u : 6u);
    for (uint i = 0; i < 64; i++) {
        if (node[i]) out[(127u - i) >> 5] |= 1u << ((127u - i) & 31u);
    }
    return fastErr;
}

static float zsa_encode_block_fast6(thread const uint *pk, thread uint *out) {
    const uint N = 36u;
    const uint GW = 5u;
    out[0] = 0u;
    out[1] = 0u;
    out[2] = 0u;
    out[3] = 0u;

    float px[144];
    for (uint i = 0; i < N; i++) {
        float4 p = zsa_unpack(pk[i]);
        px[i * 4] = p.x;
        px[i * 4 + 1] = p.y;
        px[i * 4 + 2] = p.z;
        px[i * 4 + 3] = p.w;
    }

    float lo[4] = { 1.0f, 1.0f, 1.0f, 1.0f };
    float hi[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    float mean[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
    for (uint i = 0; i < N; i++) {
        for (uint c = 0; c < 4; c++) {
            float v = px[i * 4 + c];
            lo[c] = min(lo[c], v);
            hi[c] = max(hi[c], v);
            mean[c] += v;
        }
    }
    float range = 0.0f;
    for (uint c = 0; c < 4; c++) {
        mean[c] /= float(N);
        range = max(range, hi[c] - lo[c]);
    }

    if (range <= 1.5f / 255.0f) {
        uint q[4];
        for (uint c = 0; c < 4; c++) q[c] = uint(round(clamp(mean[c], 0.0f, 1.0f) * 65535.0f));
        out[0] = 0xFFFFFDFCu;
        out[1] = 0xFFFFFFFFu;
        out[2] = q[0] | (q[1] << 16);
        out[3] = q[2] | (q[3] << 16);
        float voidErr = 0.0f;
        for (uint i = 0; i < N; i++) {
            for (uint c = 0; c < 4; c++) {
                float d = px[i * 4 + c] * 255.0f - float(q[c] >> 8);
                voidErr += d * d;
            }
        }
        return voidErr;
    }

    bool rgba = lo[3] < 0.998f;
    uint dims = rgba ? 4u : 3u;

    float cov[16];
    for (uint i = 0; i < 16; i++) cov[i] = 0.0f;
    for (uint i = 0; i < N; i++) {
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
    for (uint i = 0; i < N; i++) {
        float t = 0.0f;
        for (uint c = 0; c < dims; c++) t += (px[i * 4 + c] - mean[c]) * axis[c];
        tmin = min(tmin, t);
        tmax = max(tmax, t);
    }
    float e0[4] = { 0.0f, 0.0f, 0.0f, 1.0f };
    float e1[4] = { 0.0f, 0.0f, 0.0f, 1.0f };
    for (uint c = 0; c < dims; c++) {
        e0[c] = clamp(mean[c] + axis[c] * tmin, 0.0f, 1.0f);
        e1[c] = clamp(mean[c] + axis[c] * tmax, 0.0f, 1.0f);
    }

    uint v0s[36];
    uint ws[144];
    uint ds = (1024u + 3u) / 5u;
    for (uint t = 0; t < 6; t++) {
        for (uint s = 0; s < 6; s++) {
            uint gs = ((ds * s) * (GW - 1u) + 32u) >> 6;
            uint gt = ((ds * t) * (GW - 1u) + 32u) >> 6;
            uint fs = gs & 15u;
            uint ft = gt & 15u;
            uint n = t * 6u + s;
            uint w11 = (fs * ft + 8u) >> 4;
            v0s[n] = (gs >> 4) + GW * (gt >> 4);
            ws[n * 4u] = 16u - fs - ft + w11;
            ws[n * 4u + 1u] = fs - w11;
            ws[n * 4u + 2u] = ft - w11;
            ws[n * 4u + 3u] = w11;
        }
    }
    uint offs[4] = { 0u, 1u, GW, GW + 1u };
    uint dq[4] = { 0u, 21u, 43u, 64u };

    float bestErr = 1e30f;
    uint bI0[4] = { 0u, 0u, 0u, 0u };
    uint bI1[4] = { 0u, 0u, 0u, 0u };
    uint bQ[25];
    for (uint i = 0; i < 25; i++) bQ[i] = 0u;

    for (uint pass = 0; pass < 4; pass++) {
        uint i0[4] = { 0u, 0u, 0u, 0u };
        uint i1[4] = { 0u, 0u, 0u, 0u };
        uint d0[4] = { 0u, 0u, 0u, 255u };
        uint d1[4] = { 0u, 0u, 0u, 255u };
        for (uint c = 0; c < dims; c++) {
            uint v0 = uint(round(clamp(e0[c], 0.0f, 1.0f) * 255.0f));
            uint v1 = uint(round(clamp(e1[c], 0.0f, 1.0f) * 255.0f));
            if (rgba) {
                i0[c] = kZSAEnc192[v0];
                i1[c] = kZSAEnc192[v1];
                d0[c] = kZSADec192[i0[c]];
                d1[c] = kZSADec192[i1[c]];
            } else {
                i0[c] = v0;
                i1[c] = v1;
                d0[c] = v0;
                d1[c] = v1;
            }
        }
        if (d1[0] + d1[1] + d1[2] < d0[0] + d0[1] + d0[2]) {
            for (uint c = 0; c < dims; c++) {
                uint t = i0[c]; i0[c] = i1[c]; i1[c] = t;
                t = d0[c]; d0[c] = d1[c]; d1[c] = t;
            }
        }

        float dir[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        float dd = 0.0f;
        for (uint c = 0; c < dims; c++) {
            dir[c] = float(d1[c]) - float(d0[c]);
            dd += dir[c] * dir[c];
        }

        float num[25];
        float den[25];
        for (uint g = 0; g < 25; g++) {
            num[g] = 0.0f;
            den[g] = 0.0f;
        }
        for (uint i = 0; i < N; i++) {
            float u = 0.0f;
            if (dd > 1e-6f) {
                float dot = 0.0f;
                for (uint c = 0; c < dims; c++) dot += (px[i * 4 + c] * 255.0f - float(d0[c])) * dir[c];
                u = clamp(dot / dd, 0.0f, 1.0f);
            }
            for (uint k = 0; k < 4; k++) {
                uint w = ws[i * 4u + k];
                if (w != 0u) {
                    num[v0s[i] + offs[k]] += float(w) * u;
                    den[v0s[i] + offs[k]] += float(w);
                }
            }
        }
        uint q[25];
        for (uint g = 0; g < 25; g++) {
            float v = den[g] > 0.0f ? num[g] / den[g] : 0.0f;
            q[g] = uint(round(clamp(v, 0.0f, 1.0f) * 3.0f));
        }

        float err = 0.0f;
        float aa = 0.0f;
        float ab = 0.0f;
        float bb = 0.0f;
        float ap[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        float bp[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        for (uint i = 0; i < N; i++) {
            uint acc = 0u;
            for (uint k = 0; k < 4; k++) {
                uint w = ws[i * 4u + k];
                if (w != 0u) acc += w * dq[q[v0s[i] + offs[k]]];
            }
            uint wt = (acc + 8u) >> 4;
            float wb = float(wt) / 64.0f;
            float wa = 1.0f - wb;
            aa += wa * wa;
            ab += wa * wb;
            bb += wb * wb;
            for (uint c = 0; c < dims; c++) {
                float target = px[i * 4 + c];
                ap[c] += wa * target;
                bp[c] += wb * target;
                uint dec = (d0[c] * (64u - wt) + d1[c] * wt + 32u) >> 6;
                float diff = float(dec) - target * 255.0f;
                err += diff * diff;
            }
        }
        if (err < bestErr) {
            bestErr = err;
            for (uint c = 0; c < 4; c++) {
                bI0[c] = i0[c];
                bI1[c] = i1[c];
            }
            for (uint g = 0; g < 25; g++) bQ[g] = q[g];
        }
        float det = aa * bb - ab * ab;
        if (det < 1e-4f) break;
        for (uint c = 0; c < dims; c++) {
            e0[c] = clamp((bb * ap[c] - ab * bp[c]) / det, 0.0f, 1.0f);
            e1[c] = clamp((aa * bp[c] - ab * ap[c]) / det, 0.0f, 1.0f);
        }
    }

    uint vals[8];
    for (uint c = 0; c < dims; c++) {
        vals[c * 2] = bI0[c];
        vals[c * 2 + 1] = bI1[c];
    }
    zsa_put(out, 0, 11, 0xE2u);
    zsa_put(out, 13, 4, rgba ? 12u : 8u);
    if (rgba) {
        zsa_put_trits(out, 17, vals, 8u, 6u);
    } else {
        for (uint i = 0; i < 6u; i++) zsa_put(out, 17u + i * 8u, 8, vals[i]);
    }
    for (uint g = 0; g < 25; g++) {
        for (uint b = 0; b < 2; b++) {
            if ((bQ[g] >> b) & 1u) {
                uint pos = 127u - (g * 2u + b);
                out[pos >> 5] |= 1u << (pos & 31u);
            }
        }
    }
    return bestErr;
}


static uint zsa_load_pixel(texture2d<float, access::sample> source, constant ZSAParams &params, uint sx, uint sy, float2 invSize) {
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float4 original = source.sample(nearestSampler, (float2(sx, sy) + 0.5f) * invSize);
    if (params.srgb != 0) {
        original.r = zsa_linear_to_srgb(original.r);
        original.g = zsa_linear_to_srgb(original.g);
        original.b = zsa_linear_to_srgb(original.b);
    }
    float4 q = round(clamp(original, 0.0f, 1.0f) * 255.0f);
    return uint(q.r) | (uint(q.g) << 8) | (uint(q.b) << 16) | (uint(q.a) << 24);
}

template <uint BW>
static void zsa_classify(texture2d<float, access::sample> source, device uint *encoded,
                         device float *metrics, constant ZSAParams &params, uint2 gid) {
    uint blockY = gid.y + params.rowOffset;
    uint blocksY = (params.height + BW - 1) / BW;
    if (gid.x >= params.blocksX || gid.y >= params.rowCount || blockY >= blocksY) return;

    const uint N = BW * BW;
    uint x0 = gid.x * BW;
    uint y0 = blockY * BW;
    float2 invSize = 1.0f / float2(params.width, params.height);
    uint pk[N];
    for (uint y = 0; y < BW; y++) {
        uint sy = min(y0 + y, params.height - 1);
        for (uint x = 0; x < BW; x++) {
            uint sx = min(x0 + x, params.width - 1);
            pk[y * BW + x] = zsa_load_pixel(source, params, sx, sy, invSize);
        }
    }

    uint blk[4];
    float blockErr;
    if (BW == 6u) blockErr = zsa_encode_block_fast6(pk, blk);
    else blockErr = zsa_encode_block_fast<BW>(pk, blk);

    uint index = blockY * params.blocksX + gid.x;
    metrics[index] = blockErr;
    encoded[index * 4] = blk[0];
    encoded[index * 4 + 1] = blk[1];
    encoded[index * 4 + 2] = blk[2];
    encoded[index * 4 + 3] = blk[3];
}

#define ZSA_CLASSIFY_KERNEL(BW)                                                  \
kernel void zsa_classify_##BW(                                                   \
    texture2d<float, access::sample> source [[texture(0)]],                      \
    device uint *encoded [[buffer(0)]],                                          \
    constant ZSAParams &params [[buffer(1)]],                                    \
    device float *metrics [[buffer(2)]],                                         \
    uint2 gid [[thread_position_in_grid]]) {                                     \
    zsa_classify<BW>(source, encoded, metrics, params, gid);                     \
}

ZSA_CLASSIFY_KERNEL(6)
ZSA_CLASSIFY_KERNEL(8)
ZSA_CLASSIFY_KERNEL(10)
ZSA_CLASSIFY_KERNEL(12)

kernel void zsa_gather(
    texture2d<float, access::sample> source [[texture(0)]],
    device uchar4 *pixels [[buffer(0)]],
    constant ZSAParams &params [[buffer(1)]],
    device const uint *blocks [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= params.count) return;
    uint block = params.block;
    uint index = blocks[gid];
    uint x0 = (index % params.blocksX) * block;
    uint y0 = (index / params.blocksX) * block;
    float2 invSize = 1.0f / float2(params.width, params.height);
    uint base = gid * block * block;
    for (uint y = 0; y < block; y++) {
        uint sy = min(y0 + y, params.height - 1);
        for (uint x = 0; x < block; x++) {
            uint sx = min(x0 + x, params.width - 1);
            uint p = zsa_load_pixel(source, params, sx, sy, invSize);
            pixels[base + y * block + x] = uchar4(uchar(p & 255u), uchar((p >> 8) & 255u), uchar((p >> 16) & 255u), uchar(p >> 24));
        }
    }
}
