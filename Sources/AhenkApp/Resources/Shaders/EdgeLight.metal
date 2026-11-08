// Ahenk edge light, Step 1 probe shader.
//
// Shaders ship as source in the app's resource bundle and are compiled at
// runtime with MTLDevice.makeLibrary(source:options:) (see MetalShaders.swift;
// SwiftPM has no Metal build step). This first shader draws a soft glow along
// every screen edge that swells with the beat; `--smoke` renders it offscreen.
// Step 4 grows it into the full style renderer. Keep EdgeLightUniforms in sync
// with the Swift struct of the same name.

#include <metal_stdlib>
using namespace metal;

struct EdgeLightUniforms {
    float2 resolution;  // drawable size in pixels
    float time;         // seconds
    float thickness;    // pixels
    float glow;         // 0...1
    float intensity;    // 0...1
    float beat;         // 0...1 pulse envelope
    float level;        // 0...1 loudness
    float4 colorA;
    float4 colorB;
};

struct EdgeLightVertexOut {
    float4 position [[position]];
    float2 uv;
};

// One triangle that covers the whole viewport.
vertex EdgeLightVertexOut edgeLightVertex(uint vertexID [[vertex_id]]) {
    const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    EdgeLightVertexOut out;
    out.position = float4(corners[vertexID], 0.0, 1.0);
    out.uv = corners[vertexID] * 0.5 + 0.5;
    return out;
}

fragment float4 edgeLightFragment(EdgeLightVertexOut in [[stage_in]],
                                  constant EdgeLightUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * u.resolution;
    // Distance to the nearest screen edge, in pixels.
    float edge = min(min(p.x, u.resolution.x - p.x), min(p.y, u.resolution.y - p.y));
    float width = max(1.0, u.thickness * (1.0 + 0.6 * u.beat));
    float core = 1.0 - smoothstep(0.0, width, edge);
    float halo = exp(-edge / (width * (1.0 + 4.0 * u.glow))) * u.glow;
    // Colours drift slowly around the frame.
    float along = (p.x + p.y) / max(1.0, u.resolution.x + u.resolution.y);
    float3 color = mix(u.colorA.rgb, u.colorB.rgb, 0.5 + 0.5 * sin(6.2831853 * (along + u.time * 0.1)));
    float alpha = clamp((core + halo) * u.intensity * (0.6 + 0.4 * u.level), 0.0, 1.0);
    return float4(color * alpha, alpha); // premultiplied alpha
}
