// Placeholder shaders for the phosphor renderer.
//
// Compiled at runtime from embedded source rather than linked as a .metallib,
// so the build needs no Metal toolchain. See ADR 0009. `zig build
// validate-shaders` type-checks this file when the toolchain is available.
//
// The real passes arrive in plan phase 3: decay, additively blended trace,
// tonemap. For now this only proves the compile path end to end.

#include <metal_stdlib>

using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle. Cheaper than a quad and needs no vertex buffer.
vertex VertexOut fullscreen_vertex(uint vertex_id [[vertex_id]]) {
    const float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);

    VertexOut out;
    out.uv = uv;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return out;
}

// Clears to the dim background the walking skeleton renders (plan phase 1).
fragment float4 clear_fragment(VertexOut in [[stage_in]]) {
    return float4(0.02, 0.02, 0.03, 1.0);
}
