// The phosphor renderer's shaders.
//
// Compiled at runtime from embedded source rather than linked as a .metallib,
// so the build needs no Metal toolchain. See ADR 0009. `zig build
// validate-shaders` type-checks this file when the toolchain is available, and
// `zig build smoke-gpu` is what proves a pipeline state can be built from it,
// which `-fsyntax-only` never reaches.
//
// Two render passes and three draws, in this order.
//
//   pass 1, into the accumulation   decay_fragment   reads the other half
//                                   trace_fragment   deposits additively
//   pass 2, into the drawable       resolve_fragment reads what pass 1 wrote
//
// Two encoders rather than one, unlike the single pass this replaced, because a
// render pass has one set of attachments and these two have different ones: the
// accumulation has to be stored before the resolve can read it as a texture.
// The tile-memory argument for sharing an encoder still holds *within* pass 1,
// where the decay and the deposit write the same target, which is why those two
// are one pass and not two.
//
// Phase 3 is not finished here. `decay_fragment` takes its factor per frame but
// that factor is a constant until #56 measures elapsed time; `trace_fragment`
// still draws a line strip until #57 makes it geometry; and `resolve_fragment`
// is a gain and an add where #60 puts a tonemap and a palette.

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

// The other half of `AccumUniforms` in `src/gpu/metal/renderer.zig`, on the same
// terms as `TraceUniforms` below: two declarations in two languages with nothing
// linking them, scalars only, and a layout test there as the only thing that
// would notice a field added or reordered on one side.
struct AccumUniforms {
    float decay;
};

// Dim what the phosphor already holds, reading the half of the ping-pong the
// beam is not about to deposit into.
//
// `access::read` rather than the default `access::sample`, which is what lets
// this index by integer pixel and skip a sampler entirely. `[[position]]` in a
// fragment is window space with pixel centres at half-integers, so truncating it
// is the pixel index, and the accumulation is allocated at exactly the
// drawable's size so the read is one-to-one and in bounds by construction.
//
// **No Y flip**, matching `trace_vertex`'s note below rather than
// `fullscreen_vertex`'s uv. Both surfaces are top-left origin, so nothing needs
// inverting between them.
//
// `uniforms.decay` is a constant per frame today. #56 makes it exp(-dt / tau)
// against a measured elapsed time, which is why it arrives as a uniform rather
// than living here as a literal the way `trace_fragment`'s colour does.
fragment float4 decay_fragment(VertexOut in [[stage_in]],
                               texture2d<float, access::read> source [[texture(0)]],
                               constant AccumUniforms &uniforms [[buffer(0)]]) {
    return source.read(uint2(in.position.xy)) * uniforms.decay;
}

// Put accumulated energy on the drawable. Deliberately trivial: #60's tonemap
// and palette are what this becomes.
//
// No gain, no curve, no clamp: accumulated energy goes to the drawable as it is
// and the format clips whatever exceeds 1.0. That is ADR 0007's shape, where
// energy accumulates past full scale and a tonemap compresses it, and #60 is
// what supplies the compressing.
//
// **A gain of (1 - decay) was tried here and measured wrong**, which is worth
// recording because the arithmetic looks convincing. It normalises a stationary
// trace to the colour the unaccumulated line strip drew, and it does that by
// dividing a *moving* trace by ten, because a sliding trace never lights the
// same pixel twice and so never accumulates. In REAPER a 100 Hz sine measured a
// peak green of 53 against 255, which reads as a black display. The case it
// optimised for is silence; the case it broke is every signal.
//
// The background literal moved here from the deleted `clear_fragment`, and it is
// load-bearing beyond looking right: the screenshot tooling finds this drawable
// inside a window capture by looking for exactly RGB(5, 5, 8), blue leading red
// and green by two to four. Emitting it where no energy has landed is what keeps
// that crop working.
fragment float4 resolve_fragment(VertexOut in [[stage_in]],
                                 texture2d<float, access::read> energy [[texture(0)]]) {
    const float3 lit = energy.read(uint2(in.position.xy)).rgb;
    return float4(float3(0.02, 0.02, 0.03) + lit, 1.0);
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
// The clamp is the vertical scale's whole policy in one line, and ADR 0017 is
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
// intensity yet. #60's tonemap and palette own the colour, which is why it is a
// literal here rather than a constant on the Zig side: nothing else reads it and
// that issue deletes it.
//
// This is now a *deposit* into the accumulation rather than a write to the
// drawable, blended one-to-one and additive, so where the beam crosses its own
// path the value climbs past 1.0. That headroom is what #60 wants and it is the
// reason the accumulation is floating point. Keeping the colour green until then
// is deliberate: the screenshot tooling isolates the trace with green > 64.
fragment float4 trace_fragment() {
    return float4(0.30, 1.0, 0.45, 1.0);
}
