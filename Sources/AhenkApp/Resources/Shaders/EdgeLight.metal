// Ahenk edge light: 22 styles in one fragment shader.
//
// Shaders ship as source in the app's resource bundle and are compiled at
// runtime (MetalShaders.swift, EdgeLightRenderer.swift; SwiftPM has no Metal
// build step). A screen's light is drawn into a few strips along its edges
// (one CAMetalLayer each, never the whole screen); every strip runs this
// shader over its whole drawable and works out where its pixels are on the
// screen.
//
// Keep in sync with AhenkKit:
// - EdgeLightUniforms.swift: the uniform struct, member for member (the tests
//   and --smoke compare every offset with this file's reflection);
// - EdgeGeometry.swift (EdgeField): edgeDistance, edgePoint, positionMask and
//   the band window, which decide where light may appear;
// - LightLook.swift: `reach` below.
//
// Coordinates are points with the origin at the screen's bottom-left corner
// and y up. `d` is the inward distance from the visible edge, `s` the
// perimeter coordinate (counter-clockwise from the left end of the bottom
// edge). Output is premultiplied; colour may exceed alpha a little, so the
// light brightens what is under it like real light.

#include <metal_stdlib>
using namespace metal;

constant float TAU = 6.28318531;
constant float HALF_PI = 1.57079633;
// EdgeShape.notchFillet
constant float NOTCH_FILLET = 6.0;

struct EdgeLightUniforms {
    float2 screenSize;
    float2 stripOrigin;
    float2 stripSize;
    float pixelScale;
    float band;
    float4 radii;        // top-right, bottom-right, top-left, bottom-left
    float4 notch;        // min x, width, height, corner radius (width 0: none)
    float4 perimeter;    // coordinate radius, wrap, corner arm, length
    float thickness;
    float glow;
    float intensity;
    float opacity;
    float time;          // drift clock (s), speed-scaled, wraps at 4096
    float travel;        // laps around the screen, 0..<1
    float detail;
    float quality;       // 1 full, 0 light
    int style;
    int position;        // 0 all edges, 1 bottom, 2 top, 3 corners
    int colorMode;       // 0 colour slots, 1 rainbow
    int seed;
    float energy;
    float beat;
    float onset;
    float beatPhase;
    float4 bands;        // sub-bass, bass, low-mid, mid
    float4 extra;        // high, swell, kick, tempo
    float4 beatAges;     // seconds since each of the last four beats
    float4 beatSeeds;
    float4 beatStrengths;
    float4 colors[4];
    float4 spectrum[8];
    float2 atlasOrigin;  // the strip's slot in the target, pixels from its top-left corner
    int rotated;         // 1: the slot holds the strip turned a quarter (EdgeAtlas)
    int reserved;
};

struct EdgeLightVertexOut {
    float4 position [[position]];
};

// One triangle that covers the whole strip.
vertex EdgeLightVertexOut edgeLightVertex(uint vertexID [[vertex_id]]) {
    const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    EdgeLightVertexOut out;
    out.position = float4(corners[vertexID], 0.0, 1.0);
    return out;
}

// MARK: - Helpers

static inline float sq(float x) { return x * x; }
static inline float dot2(float2 v) { return dot(v, v); }

static inline uint hashu(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

static inline float hash1(uint x) { return float(hashu(x)) * (1.0 / 4294967296.0); }

static inline uint cellKey(int2 c, uint salt) {
    return hashu(uint(c.x) * 0x8da6b343u ^ hashu(uint(c.y) * 0xd8163841u ^ salt));
}

static inline float4 hash4(int2 c, uint salt) {
    uint h = cellKey(c, salt);
    return float4(hash1(h), hash1(h ^ 0x68e31da4u), hash1(h ^ 0xb5297a4du), hash1(h ^ 0x1b56c4e9u));
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 w = f * f * (3.0 - 2.0 * f);
    int2 c = int2(i);
    float a = hash1(cellKey(c, 17u));
    float b = hash1(cellKey(c + int2(1, 0), 17u));
    float e = hash1(cellKey(c + int2(0, 1), 17u));
    float d = hash1(cellKey(c + int2(1, 1), 17u));
    return mix(mix(a, b, w.x), mix(e, d, w.x), w.y);
}

static inline float fbm(float2 p, int octaves) {
    float sum = 0.0;
    float amplitude = 0.5;
    float norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amplitude * vnoise(p);
        norm += amplitude;
        p = p * 2.03 + float2(17.3, 9.1);
        amplitude *= 0.5;
    }
    return sum / norm;
}

// Piecewise-linear noise along x: jagged, for lightning.
static inline float lnoise(float x, float row) {
    float i = floor(x);
    uint r = uint(int(row * 131.0));
    float a = hash1(uint(int(i)) * 0x27d4eb2du ^ r);
    float b = hash1(uint(int(i) + 1) * 0x27d4eb2du ^ r);
    return mix(a, b, x - i);
}

static inline float wrapDelta(float x, float period) {
    return x - period * rint(x / period);
}

// fbm(s / scale, y), seamless where the perimeter coordinate wraps: the last
// stretch blends into the values just before 0.
static inline float fbmS(float s, float y, float L, float scale, int octaves) {
    s = s - L * floor(s / L);
    float a = fbm(float2(s / scale, y), octaves);
    float blend = min(L * 0.25, 160.0);
    if (s > L - blend) {
        float b = fbm(float2((s - L) / scale, y), octaves);
        a = mix(a, b, smoothstep(L - blend, L, s));
    }
    return a;
}

static inline float3 hsv(float h, float s, float v) {
    float3 k = clamp(abs(fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return v * mix(float3(1.0), k, s);
}

// The colour at `x` of one cycle through the four slots (or the hue wheel).
static inline float3 paletteColor(float x, constant EdgeLightUniforms &u) {
    if (u.colorMode == 1) {
        return hsv(x, 0.72, 1.0);
    }
    float f = fract(x) * 4.0;
    int i = int(f) & 3;
    int j = (i + 1) & 3;
    float t = smoothstep(0.0, 1.0, fract(f));
    return mix(u.colors[i].rgb, u.colors[j].rgb, t);
}

static inline float spectrumBand(constant EdgeLightUniforms &u, int i) {
    i = clamp(i, 0, 31);
    return u.spectrum[i >> 2][i & 3];
}

static inline float spectrumAt(constant EdgeLightUniforms &u, float x) {
    float f = clamp(x, 0.0, 31.0);
    int i = int(f);
    return mix(spectrumBand(u, i), spectrumBand(u, i + 1), f - float(i));
}

// The bright line right on the edge (about `w` wide).
static inline float coreLine(float d, float w) {
    float x = d / max(w, 0.5);
    return exp(-x * x * 1.6);
}

// The soft halo spreading `reach` points into the screen.
static inline float halo(float d, float reach) {
    return exp(-d / max(reach * 0.42, 0.5));
}

// Distance from `p` to the segment `a`–`b`.
static inline float segmentDistance(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot2(ab), 1e-4), 0.0, 1.0);
    return length(p - a - ab * t);
}

// MARK: - Geometry (EdgeField)

static inline float sdRoundBox(float2 p, float2 b, float4 r) {
    r.xy = (p.x > 0.0) ? r.xy : r.zw;
    r.x = (p.y > 0.0) ? r.x : r.y;
    float2 q = abs(p) - b + r.x;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x;
}

static inline float smoothMin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// Inward distance from the visible edge: rounded corners, around the notch.
static inline float edgeDistance(float2 p, constant EdgeLightUniforms &u) {
    float2 halfSize = u.screenSize * 0.5;
    float d = -sdRoundBox(p - halfSize, halfSize, u.radii);
    if (u.notch.y > 0.0) {
        float2 center = float2(u.notch.x + u.notch.y * 0.5, u.screenSize.y);
        float outside = sdRoundBox(p - center, float2(u.notch.y * 0.5, u.notch.z), float4(0.0, u.notch.w, 0.0, u.notch.w));
        d = smoothMin(d, outside, NOTCH_FILLET);
    }
    return d;
}

struct Segments {
    float sw;
    float sh;
    float arc;
    float bottomRight;
    float right;
    float topRight;
    float top;
    float topLeft;
    float left;
    float bottomLeft;
    float total;
};

static inline Segments segments(constant EdgeLightUniforms &u) {
    float r = u.perimeter.x;
    Segments g;
    g.sw = max(0.0, u.screenSize.x - 2.0 * r);
    g.sh = max(0.0, u.screenSize.y - 2.0 * r);
    g.arc = HALF_PI * r;
    g.bottomRight = g.sw;
    g.right = g.bottomRight + g.arc;
    g.topRight = g.right + g.sh;
    g.top = g.topRight + g.arc;
    g.topLeft = g.top + g.sw;
    g.left = g.topLeft + g.arc;
    g.bottomLeft = g.left + g.sh;
    g.total = g.bottomLeft + g.arc;
    return g;
}

struct Ctx {
    float2 p;      // screen point
    float d;       // inward distance
    float s;       // perimeter coordinate, 0..<L
    float L;       // perimeter length
    float u;       // s / L
    float2 t;      // tangent (towards growing s)
    float2 n;      // inward normal
    float m;       // true length of one unit of s here (< 1 deep in a corner, where s is radial)
    float pd;      // depth in the coordinate's own (polar in corners) frame: places particles, keeps them round
    float w;       // line width with the kick
    float reach;   // halo reach
    float band;
    float detail;
    float time;
    float travel;
    float kick;
    float swell;
    float high;
    bool full;
    uint salt;
    Segments g;
};

static inline void edgePoint(float2 p, constant EdgeLightUniforms &u, thread Ctx &c) {
    float width = u.screenSize.x;
    float height = u.screenSize.y;
    float r = u.perimeter.x;
    Segments g = c.g;
    c.m = 1.0;
    if (p.x < r && p.y < r) {
        float a = atan2(r - p.y, r - p.x);
        c.s = g.bottomLeft + a * r;
        c.t = float2(sin(a), -cos(a));
        c.n = float2(cos(a), sin(a));
        c.m = length(p - float2(r, r)) / r;
        c.pd = r - length(p - float2(r, r));
    } else if (p.x > width - r && p.y < r) {
        float a = atan2(r - p.y, p.x - (width - r));
        c.s = g.bottomRight + (HALF_PI - a) * r;
        c.t = float2(sin(a), cos(a));
        c.n = float2(-cos(a), sin(a));
        c.m = length(p - float2(width - r, r)) / r;
        c.pd = r - length(p - float2(width - r, r));
    } else if (p.x > width - r && p.y > height - r) {
        float a = atan2(p.y - (height - r), p.x - (width - r));
        c.s = g.topRight + a * r;
        c.t = float2(-sin(a), cos(a));
        c.n = float2(-cos(a), -sin(a));
        c.m = length(p - float2(width - r, height - r)) / r;
        c.pd = r - length(p - float2(width - r, height - r));
    } else if (p.x < r && p.y > height - r) {
        float a = atan2(p.y - (height - r), r - p.x);
        c.s = g.topLeft + (HALF_PI - a) * r;
        c.t = float2(-sin(a), -cos(a));
        c.n = float2(cos(a), -sin(a));
        c.m = length(p - float2(r, height - r)) / r;
        c.pd = r - length(p - float2(r, height - r));
    } else {
        float bottom = p.y;
        float right = width - p.x;
        float top = height - p.y;
        float left = p.x;
        float m = min(min(bottom, right), min(top, left));
        c.pd = m;
        if (m == bottom) {
            c.s = p.x - r;
            c.t = float2(1.0, 0.0);
            c.n = float2(0.0, 1.0);
        } else if (m == right) {
            c.s = g.right + (p.y - r);
            c.t = float2(0.0, 1.0);
            c.n = float2(-1.0, 0.0);
        } else if (m == top) {
            c.s = g.top + (width - r - p.x);
            c.t = float2(-1.0, 0.0);
            c.n = float2(0.0, -1.0);
        } else {
            c.s = g.left + (height - r - p.y);
            c.t = float2(0.0, -1.0);
            c.n = float2(1.0, 0.0);
        }
    }
    c.m = max(c.m, 0.05);
    c.L = max(g.total, 1.0);
    c.s = c.s - c.L * floor(c.s / c.L);
    c.u = c.s / c.L;
}

// The point at perimeter coordinate `s` on the coordinate's own outline
// (corner radius `perimeter.x`) and the inward normal there: where something
// that lives along the edge (a heart, a burst) sits on the screen.
static inline float2 outlinePoint(float s, constant EdgeLightUniforms &u, Segments g, thread float2 &normal) {
    float width = u.screenSize.x;
    float height = u.screenSize.y;
    float r = u.perimeter.x;
    s = s - g.total * floor(s / g.total);
    if (s < g.bottomRight) {
        normal = float2(0.0, 1.0);
        return float2(r + s, 0.0);
    }
    if (s < g.right) {
        float a = HALF_PI - (s - g.bottomRight) / max(r, 1e-3);
        normal = float2(-cos(a), sin(a));
        return float2(width - r + r * cos(a), r - r * sin(a));
    }
    if (s < g.topRight) {
        normal = float2(-1.0, 0.0);
        return float2(width, r + (s - g.right));
    }
    if (s < g.top) {
        float a = (s - g.topRight) / max(r, 1e-3);
        normal = float2(-cos(a), -sin(a));
        return float2(width - r + r * cos(a), height - r + r * sin(a));
    }
    if (s < g.topLeft) {
        normal = float2(0.0, -1.0);
        return float2(width - r - (s - g.top), height);
    }
    if (s < g.left) {
        float a = HALF_PI - (s - g.topLeft) / max(r, 1e-3);
        normal = float2(cos(a), -sin(a));
        return float2(r - r * cos(a), height - r + r * sin(a));
    }
    if (s < g.bottomLeft) {
        normal = float2(1.0, 0.0);
        return float2(0.0, height - r - (s - g.left));
    }
    float a = (s - g.bottomLeft) / max(r, 1e-3);
    normal = float2(cos(a), sin(a));
    return float2(r - r * cos(a), r - r * sin(a));
}

static inline float spanMask(float s, float center, float halfLength, float fade, float L) {
    return 1.0 - smoothstep(halfLength - fade, halfLength, abs(wrapDelta(s - center, L)));
}

static inline float positionMask(float s, constant EdgeLightUniforms &u, Segments g) {
    float wrap = u.perimeter.y;
    float arm = u.perimeter.z;
    switch (u.position) {
        case 1:
            return spanMask(s, g.sw * 0.5, g.sw * 0.5 + g.arc + wrap, wrap * 0.8 + 1.0, g.total);
        case 2:
            return spanMask(s, g.top + g.sw * 0.5, g.sw * 0.5 + g.arc + wrap, wrap * 0.8 + 1.0, g.total);
        case 3: {
            float halfLength = g.arc * 0.5 + arm;
            float fade = arm * 0.6 + 1.0;
            float m = spanMask(s, g.bottomRight + g.arc * 0.5, halfLength, fade, g.total);
            m = max(m, spanMask(s, g.topRight + g.arc * 0.5, halfLength, fade, g.total));
            m = max(m, spanMask(s, g.topLeft + g.arc * 0.5, halfLength, fade, g.total));
            m = max(m, spanMask(s, g.bottomLeft + g.arc * 0.5, halfLength, fade, g.total));
            return m;
        }
        default:
            return 1.0;
    }
}

// Light of `amount` in `color`, premultiplied, a little additive.
static inline float4 emit(float3 color, float amount) {
    return float4(color * amount, amount * 0.85);
}

// MARK: - Shared pieces

// The colour slot that looks most like fire (the hue wheel's orange in
// rainbow mode), for flames and embers.
static inline float3 warmestColor(constant EdgeLightUniforms &u) {
    if (u.colorMode == 1) {
        return hsv(0.06, 0.85, 1.0);
    }
    float3 best = u.colors[0].rgb;
    float score = best.r + 0.3 * best.g - 0.8 * best.b;
    for (int i = 1; i < 4; i++) {
        float3 c = u.colors[i].rgb;
        float candidate = c.r + 0.3 * c.g - 0.8 * c.b;
        if (candidate > score) {
            score = candidate;
            best = c;
        }
    }
    return best;
}

// Tiny dots that twinkle now and then, one per cell of (s, d); `m` turns
// steps along s into true length (corners).
static inline float twinkleDots(float2 q, float m, float cell, float time, uint salt, float size, float density, float rate) {
    int2 id = int2(floor(q / cell));
    float4 h = hash4(id, salt);
    if (h.w > density) {
        return 0.0;
    }
    float2 center = (float2(id) + 0.3 + 0.4 * h.xy) * cell;
    float2 v = float2((q.x - center.x) * m, q.y - center.y);
    float sz = size * (0.6 + 0.8 * h.z);
    float twinkle = pow(max(0.0, sin(time * rate * (0.5 + h.x) + h.y * 37.0)), 8.0);
    return twinkle * exp(-dot2(v) / (sz * sz));
}

// Four-point stars, checked in the 2 × 2 cells around the point.
static inline float4 starLayer(thread const Ctx &c, constant EdgeLightUniforms &u, float cell, uint salt, float sizeBase) {
    float2 q = float2(c.s, c.pd);
    int2 base = int2(floor(q / cell - 0.5));
    float4 acc = float4(0.0);
    float fade = 1.0 - smoothstep(c.band * 0.5, c.band * 0.95, c.d);
    for (int dy = 0; dy <= 1; dy++) {
        for (int dx = 0; dx <= 1; dx++) {
            int2 id = base + int2(dx, dy);
            float4 h = hash4(id, salt);
            if (h.w > 0.7) {
                continue;
            }
            float2 center = (float2(id) + 0.15 + 0.7 * h.xy) * cell;
            float2 v = float2((q.x - center.x) * c.m, q.y - center.y);
            float rate = (1.0 + 2.2 * h.z) * (1.0 + 1.5 * c.high);
            float twinkle = pow(max(0.0, sin(c.time * rate + h.x * 40.0)), 6.0);
            twinkle = max(twinkle, c.kick * step(0.75, h.y));
            float size = sizeBase * (0.6 + 0.8 * h.z) * c.detail;
            float star = exp(-dot2(v) / sq(size))
                + 0.55 * (exp(-abs(v.x) / (size * 0.3)) * exp(-abs(v.y) / (size * 2.2))
                          + exp(-abs(v.y) / (size * 0.3)) * exp(-abs(v.x) / (size * 2.2)));
            float amount = star * twinkle * fade;
            acc += float4(mix(paletteColor(h.y, u), float3(1.0), 0.55) * amount, amount * 0.8);
        }
    }
    return acc;
}

// MARK: - 0 Soft Glow
// A soft halo in the album's colours flowing around the screen, a brighter
// line on the edge, fine sparkles twinkling in the halo.
static float4 styleSoftGlow(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float3 color = paletteColor(c.u + c.travel + c.time * (1.0 / 64.0), u);
    float line = coreLine(c.d, c.w) * (0.75 + 0.6 * c.kick);
    float glow = halo(c.d, c.reach * (0.85 + 0.35 * c.swell)) * sqrt(u.glow) * (0.6 + 0.4 * c.swell + 0.5 * c.kick);
    float4 acc = emit(color, line + glow);
    float2 q = float2(c.s, c.pd);
    float sparkle = twinkleDots(q, c.m, 14.0 * c.detail, c.time, c.salt, 1.2 * c.detail, 0.6, 1.6 + 2.5 * c.high);
    if (c.full) {
        sparkle += twinkleDots(q + 7.0 * c.detail, c.m, 21.0 * c.detail, c.time * 0.8, c.salt + 9u, 1.5 * c.detail, 0.45, 1.3 + 2.0 * c.high);
    }
    sparkle *= halo(c.d, c.reach * 1.2) * (0.7 + 0.7 * c.high + 0.6 * c.kick) * 1.6;
    acc += float4(mix(color, float3(1.0), 0.7) * sparkle, sparkle * 0.75);
    return acc;
}

// MARK: - 1 Pulse
// Every beat flashes the edge in the next colour and sends a ring of light
// inwards.
static float4 stylePulse(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float3 now = paletteColor(fract(u.beatSeeds.x * 0.25), u);
    float3 before = paletteColor(fract(u.beatSeeds.y * 0.25), u);
    float3 color = mix(before, now, smoothstep(0.0, 0.18, u.beatAges.x));
    float base = coreLine(c.d, c.w * 0.8) * (0.45 + 1.1 * c.kick) + halo(c.d, c.reach * 0.65) * u.glow * (0.3 + 0.7 * c.kick);
    float4 acc = emit(color, base);
    for (int k = 0; k < 3; k++) {
        float age = u.beatAges[k];
        if (age > 1.5) {
            continue;
        }
        float radius = c.w * 0.3 + age * c.band * 0.85;
        float width = max(1.0, c.w * 0.3) + age * 6.0 * c.detail;
        float ring = exp(-sq((c.d - radius) / width)) * u.beatStrengths[k] * exp(-age * 2.4)
            * (1.0 - smoothstep(c.band * 0.6, c.band * 0.95, radius));
        acc += float4(paletteColor(fract(u.beatSeeds[k] * 0.25) + 0.05, u) * ring, ring * 0.8);
    }
    return acc;
}

// MARK: - 2 Breathe
// One colour around the whole screen, slowly breathing in and out.
static float4 styleBreathe(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float breath = 0.5 + 0.5 * sin(c.time * (TAU / 7.0));
    float3 color = paletteColor(c.time * (1.0 / 64.0), u);
    float depth = c.reach * (0.55 + 0.8 * breath) * (0.85 + 0.3 * c.swell);
    float line = coreLine(c.d, c.w * (0.75 + 0.5 * breath)) * (0.45 + 0.45 * breath + 0.15 * c.kick);
    float glow = halo(c.d, depth) * (0.3 + 0.7 * u.glow) * (0.4 + 0.6 * breath);
    return emit(color, line + glow);
}

// MARK: - 3 Wave
// The light's inner edge rolls in waves around the screen; kicks send them on.
static float4 styleWave(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float long_ = max(1.0, rint(c.L / (300.0 * c.detail)));
    float short_ = max(1.0, rint(c.L / (110.0 * c.detail)));
    float a = c.u * TAU;
    float w1 = sin(a * long_ - c.travel * TAU * 3.0);
    float w2 = sin(a * short_ + c.time * 1.7);
    float wave = 0.62 * w1 + 0.38 * w2;
    float amplitude = 0.45 + 0.8 * c.swell + 0.7 * c.kick;
    float depth = max(c.w * 0.6, c.w * 1.1 + c.reach * 0.6 * (1.0 + 0.85 * amplitude * wave));
    float x = c.d / depth;
    float body = 1.0 - smoothstep(0.55, 1.0, x);
    float crest = exp(-sq((x - 0.92) / 0.12)) * (0.5 + 0.5 * w1);
    float3 color = paletteColor(c.u + 0.12 * w1 + c.time * (1.0 / 64.0), u);
    return emit(color, body * (0.55 + 0.35 * c.swell) + crest * 0.55 + coreLine(c.d, c.w) * 0.5);
}

// MARK: - 4 Spectrum
// Bars rise from the edge with the spectrum: bass at the middle of the
// bottom edge, treble at the middle of the top, mirrored left and right.
static float4 styleSpectrum(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float bars = max(8.0, rint(c.L / (12.0 * c.detail)));
    float slot = c.u * bars;
    float center = (floor(slot) + 0.5) / bars;
    float bottomMiddle = (c.g.sw * 0.5) / c.L;
    float f = abs(wrapDelta(center - bottomMiddle, 1.0)) * 2.0;
    float value = spectrumAt(u, f * 31.0);
    float floorHeight = c.w * 0.5;
    float height = floorHeight + value * (c.band * 0.82 - floorHeight);
    float inBar = 1.0 - smoothstep(0.30, 0.38, abs(fract(slot) - 0.5));
    float body = inBar * (1.0 - smoothstep(height - 1.5, height, c.d));
    float tip = inBar * exp(-abs(c.d - height) / (2.0 * c.detail)) * 0.6 * value;
    float shade = 0.55 + 0.45 * (1.0 - c.d / max(height, 1.0));
    float base = coreLine(c.d, c.w * 0.6) * 0.35 + halo(c.d, c.reach * 0.5) * u.glow * 0.25;
    float3 color = paletteColor(f * 0.75, u);
    return emit(mix(color, float3(1.0), tip * 0.5), body * shade + tip + base);
}

// MARK: - 5 Snake, 6 Twin Snakes
// A comet with a white-hot head and a long tapering tail; `direction` -1
// runs the other way.
static float4 snakeBody(thread const Ctx &c, constant EdgeLightUniforms &u, float head, float direction, float tailLength, float shift) {
    float delta = wrapDelta((c.u - head) * direction, 1.0);   // > 0 ahead of the head
    float tail = max(-delta, 0.0) / tailLength;
    float ahead = max(delta, 0.0) * c.L * c.m;
    // Full at the head, fading along the tail; a short round front.
    float body = delta <= 0.0 ? max(1.0 - tail, 0.0) : exp(-sq(ahead / max(c.w * 1.4, 2.0)));
    float strength = body;
    float width = c.w * (0.55 + 0.9 * body) * (1.0 + 0.45 * c.kick);
    float core = exp(-sq(c.d / max(width, 0.5)) * 1.2) * strength;
    float glow = halo(c.d, c.reach * (0.6 + 0.6 * body)) * (0.35 + 0.65 * u.glow) * strength * 0.8;
    float head_ = exp(-sq(delta * c.L * c.m / max(c.w * 2.2, 3.0))) * coreLine(c.d, c.w * 1.6);
    float3 color = paletteColor(shift + min(tail, 1.0) * 0.75 + c.time * (1.0 / 64.0), u);
    color = mix(color, float3(1.0), 0.55 * head_);
    return emit(color, (core + glow) * 1.15 + head_ * (0.9 + 0.6 * c.kick));
}

static float4 styleSnake(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float4 acc = snakeBody(c, u, fract(c.travel), 1.0, 0.3, 0.0);
    float base = halo(c.d, c.reach * 0.6) * u.glow * 0.12 + coreLine(c.d, c.w * 0.5) * 0.1;
    return acc + emit(paletteColor(c.u, u), base);
}

static float4 styleTwinSnakes(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float a = fract(c.travel);
    float b = fract(0.5 - c.travel);
    float4 acc = snakeBody(c, u, a, 1.0, 0.2, 0.0) + snakeBody(c, u, b, -1.0, 0.2, 0.5);
    // Where the heads meet, they flare.
    float gap = abs(wrapDelta(a - b, 1.0)) * c.L;
    float meet = exp(-sq(gap / (110.0 * c.detail)));
    float around = exp(-sq(wrapDelta(c.u - a, 1.0) * c.L * c.m / (45.0 * c.detail))) * halo(c.d, c.reach * 1.2);
    acc += emit(mix(paletteColor(0.25, u), float3(1.0), 0.5), meet * around * 1.2);
    float base = coreLine(c.d, c.w * 0.5) * 0.1;
    return acc + emit(paletteColor(c.u, u), base);
}

// MARK: - 7 Lava
// Thick, slow blobs of molten colour: white-hot at the edge, glowing
// through the middle, a dark crust at the rim.
static float4 styleLava(thread const Ctx &c, constant EdgeLightUniforms &u) {
    int octaves = c.full ? 3 : 2;
    float n = fbmS(c.s + c.time * 6.0 * c.detail, c.time * 0.07, c.L, 110.0 * c.detail, octaves);
    float ripple = fbmS(c.s - c.time * 10.0 * c.detail, 3.7 + c.time * 0.03, c.L, 45.0 * c.detail, 1);
    float blob = c.w * 0.9 + c.reach * (0.25 + 1.1 * n * n) * (0.85 + 0.45 * c.swell + 0.4 * c.kick) + ripple * 4.0 * c.detail;
    float x = c.d / max(blob, 1.0);
    float body = 1.0 - smoothstep(0.84, 1.0, x);
    float heat = clamp(1.0 - x, 0.0, 1.0);
    float cells = fbmS(c.s * 1.0, c.d / (14.0 * c.detail) + c.time * 0.12, c.L, 18.0 * c.detail, 1);
    float3 crust = paletteColor(0.55 + n * 0.25, u) * 0.5;
    float3 molten = paletteColor(n * 0.3, u) * (1.05 + 0.25 * cells);
    float3 color = mix(crust, molten, smoothstep(0.0, 0.7, heat));
    color += float3(1.0, 0.95, 0.85) * pow(heat, 3.0) * 0.45 * (0.7 + 0.4 * c.kick);
    float rim = exp(-sq((x - 0.97) / 0.05)) * 0.3;
    float amount = body * (0.8 + 0.2 * heat) + rim;
    return float4(color * amount, amount * 0.92);
}

// MARK: - 8 Aurora
// Folded curtains of light hanging from the edges, drifting sideways, with
// faint vertical rays; mids make them glow.
static float4 styleAurora(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float4 acc = float4(0.0);
    int layers = c.full ? 3 : 2;
    float mid = u.bands.w;
    for (int i = 0; i < layers; i++) {
        float fi = float(i);
        float direction = (i % 2 == 0) ? 1.0 : -1.0;
        float scale = (240.0 - 60.0 * fi) * c.detail;
        float shift = direction * c.time * (9.0 + 5.0 * fi) * c.detail;
        float fold = fbmS(c.s + shift, fi * 7.1 + c.time * 0.04, c.L, scale, c.full ? 3 : 2);
        float curtain = smoothstep(0.4, 0.75, fold);
        float tall = fbmS(c.s - shift * 0.5, 19.0 + fi * 3.0 + c.time * 0.03, c.L, scale * 0.6, 1);
        float height = c.reach * (0.5 + 1.0 * tall) * (0.8 + 0.4 * mid + 0.3 * c.kick) + 8.0 * c.detail;
        float y = c.d / max(height, 1.0);
        float vertical = smoothstep(0.0, 0.15, y) * exp(-y * 1.4) * (1.0 - smoothstep(1.0, 1.7, y));
        float ray = 0.78 + 0.22 * vnoise(float2(c.s / (9.0 * c.detail) + fi * 13.0, c.pd / (70.0 * c.detail) - c.time * 0.15));
        float amount = curtain * vertical * ray * (0.75 + 0.2 * fi) * 1.3;
        float3 color = mix(paletteColor(fi * 0.25, u), paletteColor(fi * 0.25 + 0.5, u), smoothstep(0.15, 1.0, y));
        acc += float4(color * amount, amount * 0.8);
    }
    return acc + emit(paletteColor(c.u, u), coreLine(c.d, c.w * 0.6) * 0.3);
}

// MARK: - 9 Rainbow
// Rainbow stripes along every edge, red outside and violet inside, shimmering.
static float4 styleRainbow(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float depth = c.w * 1.3 + c.reach * 0.8 * (1.0 + 0.3 * c.kick);
    float x = c.d / max(depth, 1.0);
    float hue = x * 0.78 + 0.03 * sin(c.u * TAU * 2.0 + c.time * 0.6);
    float stripes = 0.82 + 0.18 * cos(x * 7.0 * TAU);
    float waves = max(1.0, rint(c.L / (90.0 * c.detail)));
    float shimmer = 0.85 + 0.15 * sin(c.u * TAU * waves - c.travel * TAU * 4.0);
    float body = 1.0 - smoothstep(0.85, 1.0, x);
    float amount = body * stripes * shimmer * (0.7 + 0.3 * c.swell) + coreLine(c.d, c.w * 0.5) * 0.3;
    return emit(hsv(hue, 0.82, 1.0), amount);
}

// MARK: - 10 Neon Tube
// A thin glass tube set in from the edge: white-hot core, coloured halo,
// one tube per side with dark bends at the corners and the odd flicker.
static float4 styleNeonTube(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float inset = max(4.0 * c.detail, c.w * 0.9);
    float radius = max(0.9 * c.detail, c.w * 0.14);
    float offset = c.d - inset;
    float tube = exp(-sq(offset / radius));
    float glow = exp(-abs(offset) / max(c.reach * 0.3, 2.0)) * (0.35 + 0.65 * u.glow);
    Segments g = c.g;
    float bend = 5.0 * c.detail;
    float gap = 1.0;
    gap = min(gap, smoothstep(bend, bend + 3.0 * c.detail, abs(wrapDelta(c.s - (g.bottomRight + g.arc * 0.5), c.L)) * c.m));
    gap = min(gap, smoothstep(bend, bend + 3.0 * c.detail, abs(wrapDelta(c.s - (g.topRight + g.arc * 0.5), c.L)) * c.m));
    gap = min(gap, smoothstep(bend, bend + 3.0 * c.detail, abs(wrapDelta(c.s - (g.topLeft + g.arc * 0.5), c.L)) * c.m));
    gap = min(gap, smoothstep(bend, bend + 3.0 * c.detail, abs(wrapDelta(c.s - (g.bottomLeft + g.arc * 0.5), c.L)) * c.m));
    // The bends darken the tube and its near glow, not the broad halo.
    float near = exp(-abs(offset) / max(radius * 3.0, 2.0));
    float glowGap = mix(1.0, gap, near);
    int side = 0;
    if (c.s >= g.bottomRight + g.arc * 0.5) { side = 1; }
    if (c.s >= g.topRight + g.arc * 0.5) { side = 2; }
    if (c.s >= g.topLeft + g.arc * 0.5) { side = 3; }
    if (c.s >= g.bottomLeft + g.arc * 0.5) { side = 0; }
    float3 color = paletteColor(float(side) * 0.25, u);
    float flickerRoll = hash1(hashu(uint(int(floor(c.time * 12.0))) * 31u + uint(side) * 7u + c.salt));
    float flicker = flickerRoll > 0.985 ? 0.35 : 1.0;
    float buzz = 0.92 + 0.08 * sin(c.time * 47.0 + float(side));
    float bright = flicker * buzz * (0.8 + 0.5 * c.kick + 0.2 * c.swell);
    float3 rgb = mix(color, float3(1.0), 0.7) * tube * gap * 1.2 + color * glow * glowGap * 0.8;
    float alpha = tube * gap * 0.95 + glow * glowGap * 0.6;
    return float4(rgb, alpha) * bright;
}

// MARK: - 11 Plasma
// Swirling plasma in the album's colours; hi-hats make it shimmer.
static float4 stylePlasma(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float2 q = c.p / (55.0 * c.detail);
    float t = c.time;
    float v = sin(q.x * 1.1 + t * 0.9) + sin(q.y * 1.4 - t * 1.1) + sin((q.x + q.y) * 0.8 + t * 0.7);
    v += sin(length(q - float2(sin(t * 0.33) * 6.0, cos(t * 0.27) * 4.0)) * 1.3 - t * 1.2);
    v += c.high * 0.6 * sin(q.x * 3.2 - q.y * 2.1 + t * 4.0);
    float3 color = paletteColor(v * 0.11 + t * (1.0 / 64.0), u);
    float shine = 0.65 + 0.35 * sin(v * 2.4);
    float depth = c.w + c.reach * 0.9 * (1.0 + 0.25 * c.kick);
    float body = 1.0 - smoothstep(depth * 0.45, depth, c.d);
    return emit(color, body * shine * (0.7 + 0.3 * c.swell) + coreLine(c.d, c.w * 0.6) * 0.35);
}

// MARK: - 12 Fire
// Flames licking in from every edge in the cover's warmest colour; kicks
// make them leap.
static float4 styleFire(thread const Ctx &c, constant EdgeLightUniforms &u) {
    int octaves = c.full ? 4 : 2;
    float height = c.w * 1.2 + c.reach * (0.65 + 0.65 * c.kick + 0.35 * c.swell);
    float n = fbmS(c.s, c.d / (22.0 * c.detail) - c.time * 1.7, c.L, 24.0 * c.detail, octaves);
    float tongues = fbmS(c.s, c.time * 0.6 + 11.0, c.L, 70.0 * c.detail, 1);
    float h = height * (0.65 + 0.7 * tongues);
    float f = clamp((1.0 - c.d / max(h, 1.0)) + (n - 0.5) * 1.15, 0.0, 1.0);
    // Album colours are lifted to read as light; flames need them deeper.
    float3 flame = warmestColor(u);
    float luma = dot(flame, float3(0.3, 0.59, 0.11));
    flame = clamp(luma + (flame - luma) * 1.9, 0.0, 1.0);
    float3 deep = flame * float3(1.0, 0.38, 0.25);
    float3 hot = mix(flame, float3(1.0, 0.82, 0.4), 0.6);
    float3 color = mix(deep, flame, smoothstep(0.05, 0.4, f));
    color = mix(color, hot, smoothstep(0.45, 0.8, f));
    color = mix(color, float3(1.0, 0.97, 0.9), smoothstep(0.85, 1.0, f) * 0.6);
    float amount = smoothstep(0.03, 0.4, f) * (0.45 + 0.75 * f);
    return float4(color * amount, amount * 0.85);
}

// MARK: - 13 Embers
// Glowing embers rise from a low, warm edge and flicker out.
static float4 styleEmbers(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float3 warm = warmestColor(u);
    float4 acc = emit(warm, coreLine(c.d, c.w * 0.7) * 0.45 + halo(c.d, c.reach * 0.6) * u.glow * 0.4);
    int layers = c.full ? 2 : 1;
    float fade = 1.0 - smoothstep(c.band * 0.12, c.band * 0.9, c.d);
    for (int i = 0; i < layers; i++) {
        float fi = float(i);
        float cell = (24.0 - 5.0 * fi) * c.detail;
        float speed = (22.0 + 12.0 * fi) * c.detail;
        float2 q = float2(c.p.x, c.p.y - c.time * speed);
        int2 id = int2(floor(q / cell));
        float4 h = hash4(id, c.salt + 101u + uint(i) * 17u);
        if (h.w > 0.3 + 0.35 * c.swell + 0.2 * c.kick) {
            continue;
        }
        float2 center = (float2(id) + 0.25 + 0.5 * h.xy) * cell;
        center.x += sin(c.time * (1.0 + h.z) + h.x * 30.0) * cell * 0.15;
        float2 v = q - center;
        float size = (0.9 + 1.5 * h.z) * c.detail;
        float flick = 0.5 + 0.5 * sin(c.time * (5.0 + 5.0 * h.y) + h.x * 50.0);
        float spark = (exp(-dot2(v) / (size * size)) + 0.3 * exp(-length(v) / (size * 1.4))) * flick;
        float amount = spark * fade * (0.9 + 0.6 * c.kick) * 1.3;
        float3 color = mix(warm, float3(1.0, 0.86, 0.62), 0.35 + 0.3 * h.y);
        acc += float4(color * amount, amount * 0.8);
    }
    return acc;
}

// MARK: - 14 Snow
// Flakes drift down across the light and settle along the bottom edge.
static float4 styleSnow(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float4 acc = float4(0.0);
    int layers = c.full ? 3 : 2;
    float fade = 1.0 - smoothstep(c.band * 0.4, c.band * 0.95, c.d);
    for (int i = 0; i < layers; i++) {
        float fi = float(i);
        float cell = (30.0 - 6.0 * fi) * c.detail;
        float speed = (16.0 + 9.0 * fi) * c.detail;
        float2 q = float2(c.p.x, c.p.y + c.time * speed);
        q.x += sin(q.y * 0.045 / c.detail + fi * 1.7) * 5.0 * c.detail;
        int2 id = int2(floor(q / cell));
        float4 h = hash4(id, c.salt + 211u + uint(i) * 13u);
        if (h.w > 0.55 + 0.25 * c.swell) {
            continue;
        }
        float2 center = (float2(id) + 0.25 + 0.5 * h.xy) * cell;
        float size = (0.9 + 0.55 * fi + 0.6 * h.z) * c.detail;
        float flake = 1.0 - smoothstep(size * 0.25, size, length(q - center));
        float twinkle = 0.75 + 0.25 * sin(c.time * 3.0 + h.x * 20.0) + 0.5 * c.kick * h.y;
        float amount = flake * twinkle * fade * (0.55 + 0.2 * fi);
        acc += float4(mix(float3(1.0), paletteColor(h.z, u), 0.25) * amount, amount * 0.9);
    }
    float drift = c.w * 0.7 + 5.0 * c.detail * vnoise(float2(c.p.x / (40.0 * c.detail), 1.3)) + 2.0 * c.detail;
    float lying = (1.0 - smoothstep(drift - 1.5, drift + 1.0, c.p.y)) * 0.75;
    float edge = coreLine(c.d, c.w * 0.5) * 0.25 + halo(c.d, c.reach * 0.5) * u.glow * 0.2;
    float3 edgeColor = mix(float3(0.92, 0.96, 1.0), paletteColor(c.u, u), 0.35);
    acc += float4(float3(0.95, 0.97, 1.0) * lying + edgeColor * edge, lying * 0.95 + edge * 0.85);
    return acc;
}

// MARK: - 15 Hearts
static inline float sdHeart(float2 p) {
    p.x = abs(p.x);
    if (p.y + p.x > 1.0) {
        return sqrt(dot2(p - float2(0.25, 0.75))) - 0.35355339;
    }
    return sqrt(min(dot2(p - float2(0.0, 1.0)), dot2(p - 0.5 * max(p.x + p.y, 0.0)))) * sign(p.x - p.y);
}

// Hearts rise from the edge, upright, and beat with the music.
static float4 styleHearts(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float4 acc = emit(paletteColor(c.u, u), coreLine(c.d, c.w * 0.5) * 0.25 + halo(c.d, c.reach * 0.5) * u.glow * 0.2);
    float cells = max(3.0, rint(c.L / (64.0 * c.detail)));
    float cellLength = c.L / cells;
    float j0 = floor(c.s / cellLength);
    for (int k = -1; k <= 1; k++) {
        float j = j0 + float(k);
        float wrapped = j - cells * floor(j / cells);
        float4 h = hash4(int2(int(wrapped), 7), c.salt + 307u);
        float period = 3.4 + 1.6 * h.x;
        float phase = fract(c.time / period + h.y);
        float sc = (j + 0.5 + 0.5 * (h.z - 0.5)) * cellLength;
        float dc = c.w * 0.4 + phase * c.band * 0.78;
        float grow = 0.55 + 0.45 * sin(min(phase * 3.0, 1.0) * HALF_PI);
        float size = (5.5 + 4.0 * h.w) * c.detail * (1.0 + 0.3 * c.kick) * grow;
        float2 normal;
        float2 center = outlinePoint(sc, u, c.g, normal) + normal * dc;
        float2 hp = (c.p - center) / size;
        hp.y += 0.55;
        float sd = sdHeart(hp);
        float fill = 1.0 - smoothstep(-0.04, 0.04, sd);
        float rim = exp(-abs(sd) * 14.0) * 0.4;
        float life = smoothstep(0.0, 0.12, phase) * (1.0 - smoothstep(0.7, 1.0, phase));
        float amount = (fill * 0.85 + rim) * life * (0.8 + 0.4 * c.kick);
        float3 color = mix(paletteColor(h.x * 0.5 + h.w * 0.5, u), float3(1.0), 0.15);
        acc += float4(color * amount, amount * 0.9);
    }
    return acc;
}

// MARK: - 16 Fireworks
// Each beat bursts a firework somewhere along the edge; sparks fall away.
static float4 styleFireworks(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float4 acc = emit(paletteColor(c.u, u), coreLine(c.d, c.w * 0.5) * 0.2 + halo(c.d, c.reach * 0.5) * u.glow * 0.15);
    int sparks = c.full ? 14 : 9;
    float2 down = float2(0.0, -1.0);
    for (int k = 0; k < 4; k++) {
        float age = u.beatAges[k];
        if (age > 1.7) {
            continue;
        }
        float seed = u.beatSeeds[k];
        float4 h = hash4(int2(int(seed), 41), c.salt + 401u);
        float maxRadius = c.band * 0.42 + 8.0 * c.detail;
        float2 normal;
        float2 center = outlinePoint(h.x * c.L, u, c.g, normal) + normal * (c.band * (0.34 + 0.14 * h.y));
        float2 v = c.p - center;
        if (dot2(v) > sq(maxRadius * 1.3 + 30.0 * c.detail * age * age + 12.0)) {
            continue;
        }
        float spread = maxRadius * (1.0 - exp(-age * 3.2)) / 0.96;
        float fall = 26.0 * c.detail * age * age;
        float life = exp(-age * 1.9) * (1.0 - smoothstep(1.2, 1.7, age));
        float sum = 0.0;
        uint seedBits = uint(int(seed));
        for (int i = 0; i < sparks; i++) {
            float angle = TAU * (float(i) + 0.3 * hash1(uint(i) * 97u + seedBits)) / float(sparks) + h.w * TAU;
            float reach = spread * (0.75 + 0.25 * hash1(uint(i) * 131u + seedBits * 7u));
            float2 direction = float2(cos(angle), sin(angle));
            float2 spark = direction * reach + down * fall;
            float2 trail = direction * reach * 0.8 + down * fall * 0.7;
            sum += exp(-dot2(v - spark) / sq(1.8 * c.detail)) * 1.3;
            sum += 0.6 * exp(-sq(segmentDistance(v, trail, spark) / (1.0 * c.detail)));
        }
        float bang = exp(-dot2(v) / sq(6.0 * c.detail)) * exp(-age * 9.0) * 1.5;
        float amount = (sum * life + bang) * (0.75 + 0.6 * u.beatStrengths[k]);
        float3 color = mix(paletteColor(h.z, u), float3(1.0), 0.6 * exp(-age * 4.0));
        acc += float4(color * amount, amount * 0.85);
    }
    return acc;
}

// MARK: - 17 Sparkles
// Four-point stars twinkling all along the edges; beats light many at once.
static float4 styleSparkles(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float3 color = paletteColor(c.u + c.time * (1.0 / 64.0), u);
    float4 acc = emit(color, coreLine(c.d, c.w * 0.55) * 0.3 + halo(c.d, c.reach * 0.7) * u.glow * 0.25);
    acc += starLayer(c, u, 15.0 * c.detail, c.salt + 151u, 2.2);
    if (c.full) {
        acc += starLayer(c, u, 23.0 * c.detail, c.salt + 157u, 3.0);
    }
    return acc;
}

// MARK: - 18 Bubbles
// Glassy bubbles rise and wobble through the light; bass makes them bigger.
static float4 styleBubbles(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float4 acc = emit(paletteColor(c.u, u), coreLine(c.d, c.w * 0.5) * 0.2 + halo(c.d, c.reach * 0.5) * u.glow * 0.18);
    int layers = c.full ? 2 : 1;
    float fade = 1.0 - smoothstep(c.band * 0.45, c.band * 0.95, c.d);
    for (int i = 0; i < layers; i++) {
        float fi = float(i);
        float cell = (38.0 + 10.0 * fi) * c.detail;
        float speed = (14.0 + 8.0 * fi) * c.detail;
        float2 q = float2(c.p.x, c.p.y - c.time * speed);
        q.x += sin(q.y / (18.0 * c.detail) + fi) * 4.0 * c.detail;
        int2 id = int2(floor(q / cell));
        float4 h = hash4(id, c.salt + 503u + uint(i) * 19u);
        if (h.w > 0.45 + 0.25 * c.swell) {
            continue;
        }
        float r = (3.0 + 6.0 * h.z) * c.detail * (1.0 + 0.25 * u.bands.y);
        float room = max(cell - 2.0 * r - 4.0 * c.detail, 0.0);
        float2 center = (float2(id) + 0.5) * cell + (h.xy - 0.5) * room;
        float2 v = q - center;
        float dist = length(v);
        float ring = exp(-sq((dist - r) / max(0.6 * c.detail, r * 0.12)));
        float fill = (1.0 - smoothstep(r * 0.6, r, dist)) * 0.12;
        float shine = exp(-dot2(v - float2(-0.35, 0.35) * r) / sq(r * 0.22)) * 0.8;
        float amount = (ring * 0.75 + fill + shine) * fade;
        acc += float4(mix(paletteColor(h.y, u), float3(1.0), 0.35) * amount, amount * 0.85);
    }
    return acc;
}

// MARK: - 19 Lightning
// Electric light on the edge; every beat strikes a jagged bolt along it.
static float4 styleLightning(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float3 electric = mix(paletteColor(c.u, u), float3(0.85, 0.9, 1.0), 0.45);
    float base = coreLine(c.d, c.w * 0.5) * (0.25 + 0.9 * c.kick) + halo(c.d, c.reach * 0.5) * u.glow * (0.18 + 0.5 * c.kick);
    float4 acc = emit(electric, base);
    for (int k = 0; k < 2; k++) {
        float age = u.beatAges[k];
        if (age > 0.5) {
            continue;
        }
        float seed = u.beatSeeds[k];
        float4 h = hash4(int2(int(seed), 59), c.salt + 601u);
        float span = min((0.06 + 0.08 * h.y) * c.L, 420.0 * c.detail);
        float along = wrapDelta(c.s - h.x * c.L, c.L);
        if (abs(along) > span) {
            continue;
        }
        float jitter = floor(age * 32.0);
        float x = along / (26.0 * c.detail);
        float row = seed * 0.37 + jitter * 1.7;
        float y = (lnoise(x, row) - 0.5) + (lnoise(x * 2.3, row + 5.0) - 0.5) * 0.5 + (lnoise(x * 5.1, row + 9.0) - 0.5) * 0.25;
        float path = c.w * 0.5 + c.band * (0.22 + 0.18 * h.z) + y * c.band * 0.35;
        float taper = 1.0 - smoothstep(span * 0.55, span, abs(along));
        float dist = abs(c.d - path);
        float width = (0.8 + 0.6 * taper) * c.detail;
        float bolt = exp(-sq(dist / width)) + exp(-dist / (5.0 * c.detail)) * 0.35;
        // A thinner branch off the main bolt.
        float branchPath = path + (lnoise(x * 1.7, row + 21.0) - 0.2) * c.band * 0.3;
        float branch = exp(-sq((c.d - branchPath) / (width * 0.7))) * 0.5 * smoothstep(0.0, span * 0.5, along * (h.w > 0.5 ? 1.0 : -1.0));
        float flick = step(0.35, hash1(uint(int(jitter)) * 13u + uint(int(seed))));
        float life = (1.0 - smoothstep(0.05, 0.5, age)) * (0.55 + 0.45 * flick);
        float amount = (bolt + branch) * taper * life * (0.6 + 0.6 * u.beatStrengths[k]);
        acc += float4(mix(electric, float3(1.0), 0.6) * amount, amount * 0.9);
    }
    return acc;
}

// MARK: - 20 Rain
// Slanting rain falls through the light and splashes on the bottom edge.
static float4 styleRain(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float3 cool = mix(paletteColor(0.0, u), float3(0.82, 0.9, 1.0), 0.5);
    float4 acc = emit(cool, coreLine(c.d, c.w * 0.5) * 0.25 + halo(c.d, c.reach * 0.5) * u.glow * 0.2);
    const float2 fallDirection = float2(-0.21512, -0.97659);
    const float2 across = float2(0.97659, -0.21512);
    int layers = c.full ? 2 : 1;
    float fade = 1.0 - smoothstep(c.band * 0.45, c.band * 0.95, c.d);
    for (int i = 0; i < layers; i++) {
        float fi = float(i);
        float2 cell = float2(10.0 + 4.0 * fi, 70.0 + 20.0 * fi) * c.detail;
        float speed = (300.0 + 90.0 * fi) * c.detail;
        float2 r = float2(dot(c.p, across), dot(c.p, fallDirection) - c.time * speed);
        int2 id = int2(floor(r / cell));
        float4 h = hash4(id, c.salt + 701u + uint(i) * 23u);
        if (h.w > 0.3 + 0.5 * c.swell) {
            continue;
        }
        float2 local = r - float2(id) * cell;
        float length_ = (14.0 + 14.0 * h.y) * c.detail;
        float x0 = (0.2 + 0.6 * h.x) * cell.x;
        float y0 = h.z * (cell.y - length_);
        float dy = local.y - y0;
        float streak = (1.0 - smoothstep(0.35 * c.detail, 1.1 * c.detail, abs(local.x - x0)))
            * smoothstep(0.0, 1.0, dy) * (1.0 - smoothstep(length_ - 1.0, length_, dy)) * clamp(dy / length_, 0.0, 1.0);
        float amount = streak * fade * (0.55 + 0.25 * fi + 0.3 * c.kick);
        acc += float4(mix(cool, float3(1.0), 0.3) * amount, amount * 0.85);
    }
    if (c.p.y < 14.0 * c.detail) {
        float cellX = 46.0 * c.detail;
        float id = floor(c.p.x / cellX);
        float4 h = hash4(int2(int(id), 3), c.salt + 809u);
        float phase = fract(c.time / (0.7 + 0.8 * h.x) + h.y);
        float2 v = float2(c.p.x - (id + 0.2 + 0.6 * h.z) * cellX, c.p.y - 1.5 * c.detail);
        float radius = phase * 9.0 * c.detail;
        float splash = exp(-sq((length(v * float2(1.0, 2.2)) - radius) / (0.8 * c.detail))) * (1.0 - phase) * step(-0.5, v.y);
        acc += float4(mix(cool, float3(1.0), 0.4) * splash * 0.8, splash * 0.7);
    }
    return acc;
}

// MARK: - 21 Starfield
// Stars stream out towards the edges as if the screen flew through space;
// kicks jump to warp.
static float4 styleStarfield(thread const Ctx &c, constant EdgeLightUniforms &u) {
    float4 acc = emit(paletteColor(c.u, u), coreLine(c.d, c.w * 0.5) * 0.15 + halo(c.d, c.reach * 0.5) * u.glow * 0.12);
    int layers = c.full ? 2 : 1;
    for (int i = 0; i < layers; i++) {
        float fi = float(i);
        float cells = max(4.0, rint(c.L / ((13.0 + 7.0 * fi) * c.detail)));
        float cellLength = c.L / cells;
        float j = floor(c.s / cellLength);
        float4 h = hash4(int2(int(j), i), c.salt + 907u);
        float laps = 8.0 + floor(h.x * 6.0);
        float progress = fract(c.travel * laps + h.y);
        float dc = c.band * 0.92 * (1.0 - progress * progress);
        float along = (c.s - (j + 0.2 + 0.6 * h.z) * cellLength) * c.m;
        float inward = c.pd - dc;
        float trail = (2.0 + 24.0 * progress * progress) * c.detail * (0.7 + 0.8 * c.kick);
        float width = (0.5 + 0.7 * progress) * c.detail;
        float head = exp(-sq(along / width)) * (inward >= 0.0 ? exp(-inward / trail) : exp(-sq(inward / width)));
        float amount = head * smoothstep(0.0, 0.25, progress) * (0.5 + 0.8 * progress);
        acc += float4(mix(float3(1.0), paletteColor(h.w, u), 0.35) * amount, amount * 0.85);
    }
    return acc;
}

// MARK: - Fragment

fragment float4 edgeLightFragment(EdgeLightVertexOut in [[stage_in]], constant EdgeLightUniforms &u [[buffer(0)]]) {
    // Where this pixel of the slot is on the screen. A turned slot runs
    // along the strip from its bottom end; its top edge is the strip's left.
    float2 local = (in.position.xy - u.atlasOrigin) / u.pixelScale;
    float2 p = u.rotated != 0
        ? float2(u.stripOrigin.x + local.y, u.stripOrigin.y + local.x)
        : float2(u.stripOrigin.x + local.x, u.stripOrigin.y + u.stripSize.y - local.y);
    float d = edgeDistance(p, u);
    float pixel = 1.0 / u.pixelScale;
    float window = smoothstep(-pixel, 0.5 * pixel, d) * (1.0 - smoothstep(u.band * 0.72, u.band, d));
    if (window <= 0.0 || u.opacity <= 0.0 || u.intensity <= 0.0) {
        return float4(0.0);
    }

    Ctx c;
    c.g = segments(u);
    edgePoint(p, u, c);
    float mask = positionMask(c.s, u, c.g);
    if (mask <= 0.0) {
        return float4(0.0);
    }
    c.p = p;
    c.d = max(d, 0.0);
    c.kick = u.extra.z;
    c.swell = u.extra.y;
    c.high = u.extra.x;
    c.w = u.thickness * (1.0 + 0.35 * c.kick);
    // LightLook.reach
    c.reach = u.thickness * (0.5 + 3.0 * u.glow) + 12.0 * u.glow * u.detail;
    c.band = u.band;
    c.detail = u.detail;
    c.time = u.time;
    c.travel = u.travel;
    c.full = u.quality > 0.5;
    c.salt = hashu(uint(u.seed) + 0x9e3779b9u);

    float4 light;
    switch (u.style) {
        case 1: light = stylePulse(c, u); break;
        case 2: light = styleBreathe(c, u); break;
        case 3: light = styleWave(c, u); break;
        case 4: light = styleSpectrum(c, u); break;
        case 5: light = styleSnake(c, u); break;
        case 6: light = styleTwinSnakes(c, u); break;
        case 7: light = styleLava(c, u); break;
        case 8: light = styleAurora(c, u); break;
        case 9: light = styleRainbow(c, u); break;
        case 10: light = styleNeonTube(c, u); break;
        case 11: light = stylePlasma(c, u); break;
        case 12: light = styleFire(c, u); break;
        case 13: light = styleEmbers(c, u); break;
        case 14: light = styleSnow(c, u); break;
        case 15: light = styleHearts(c, u); break;
        case 16: light = styleFireworks(c, u); break;
        case 17: light = styleSparkles(c, u); break;
        case 18: light = styleBubbles(c, u); break;
        case 19: light = styleLightning(c, u); break;
        case 20: light = styleRain(c, u); break;
        case 21: light = styleStarfield(c, u); break;
        default: light = styleSoftGlow(c, u); break;
    }

    light *= window * mask * u.intensity * u.opacity;
    return float4(clamp(light.rgb, 0.0, 1.0), clamp(light.a, 0.0, 1.0));
}
