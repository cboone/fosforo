// The phosphor renderer's shaders.
//
// Compiled at runtime from embedded source rather than linked as a .metallib,
// so the build needs no Metal toolchain. See ADR 0009. `zig build
// validate-shaders` type-checks this file when the toolchain is available, and
// `zig build smoke-gpu` is what proves a pipeline state can be built from it,
// which `-fsyntax-only` never reaches.
//
// Two passes, encoded in this order into one render pass: the background, and
// the trace over it. Phase 3 replaces the bodies rather than the structure, with
// decay and tonemap in the fullscreen pass and the beam as oriented geometry in
// place of the line strip.

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

// Clears to the dim background the trace is drawn over.
fragment float4 clear_fragment(VertexOut in [[stage_in]]) {
    return float4(0.02, 0.02, 0.03, 1.0);
}

// The other half of `TraceUniforms` in `src/gpu/metal/renderer.zig`, and nothing
// in either language links the two. Scalars only, deliberately: MSL aligns
// `float2` to 8 bytes and `float4` to 16, so a vector member would introduce
// padding the Zig side would have to reproduce by hand. A layout test there is
// the only thing that would notice a field added or reordered on one side, and
// the symptom of that is a plausible trace at the wrong scale rather than
// anything that fails.
struct TraceUniforms {
    uint sample_count;
    float full_scale;
    float rail;
};

struct TraceOut {
    float4 position [[position]];
};

// One vertex per sample, drawn as a line strip. Deliberately crude: aliased, one
// device pixel wide, no persistence and no reconstruction (plan phase 2, step 4).
//
// The samples arrive oldest first, so `vertex_id` runs left to right and the
// newest sample lands exactly on the right edge. Dividing by `sample_count - 1`
// rather than by `sample_count` is what puts it there, and it is why the caller
// refuses to draw below two samples: at one this divides by zero.
//
// `device` rather than `constant` for the samples, because `constant` is for
// values indexed uniformly across a draw and this is indexed by `vertex_id`. The
// window would fit in `constant`'s 64 KiB, so this is a choice rather than a
// constraint.
//
// **No Y flip**, unlike `fullscreen_vertex` above, which negates Y because its
// uv runs down from the top-left. Here a positive sample is up, which is what a
// scope means. Arriving from that function it is the absence that surprises.
//
// The clamp is the vertical scale's whole policy in one line, and ADR 0016 is
// why it clamps rather than letting the rasterizer clip: clipping a line strip
// removes the peaks and keeps the crossings, so an over-scale signal would read
// as a quieter one with gaps.
vertex TraceOut trace_vertex(uint vertex_id [[vertex_id]],
                             device const float *samples [[buffer(0)]],
                             constant TraceUniforms &uniforms [[buffer(1)]]) {
    const float x = 2.0 * float(vertex_id) / float(uniforms.sample_count - 1u) - 1.0;
    const float y = clamp(samples[vertex_id] * uniforms.full_scale, -uniforms.rail, uniforms.rail);

    TraceOut out;
    out.position = float4(x, y, 0.0, 1.0);
    return out;
}

// A flat provisional green, and no varyings, because the trace carries no
// intensity yet. Phase 3 step 7's tonemap and palette own the colour, which is
// why it is a literal here rather than a constant on the Zig side: nothing else
// reads it and that phase deletes it.
fragment float4 trace_fragment() {
    return float4(0.30, 1.0, 0.45, 1.0);
}
