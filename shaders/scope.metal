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
// that factor is a constant until #56 measures elapsed time, and `trace_fragment`
// still draws a line strip until #57 makes it geometry. The resolve is done:
// #60 put a tonemap and a palette lookup there, and there is no colour left in
// this file — the gradients are built in `src/gpu/palette.zig` and uploaded, so
// the GPU and the model that checks it read one table rather than two copies of
// one formula.

#include <metal_stdlib>

using namespace metal;

// The fraction of a dwelling beam's steady state that reads pure white.
//
// **The white point is derived from the decay rather than fixed**, which is why
// this is a fraction and not an energy. A beam that never moves converges on
// 1 / (1 - decay); anchoring white there makes the look independent of how long
// the phosphor holds, and once #56 makes the decay a function of elapsed time it
// is what stops the picture reading twice as hot at 120 Hz as at 60.
//
// Below one deliberately. Reinhard reaches its white point exactly at e = w while
// the steady state is only approached, so a white point set at the asymptote
// itself would never arrive and the core would stay pale green. At 0.8 a dwelt
// pixel goes white after sixteen frames.
//
// **Provisional at 0.8, and #58 is what settles it.** Measured in REAPER against
// a 100 Hz sine: the picture peaked at 2.2 and 3.0 deposits on two successive
// frames, against roughly 1 for a fast crossing. **No white point can carve a
// visible core out of a 2:1 range** — set it high and nothing reaches white, set
// it low and everything does. Dropping this to 0.2 put white at 2.0 deposits and
// moved fifty pixels of thirty-two thousand, which is invisible, so the knob has
// almost no useful travel today. Velocity weighting divides the deposit by
// segment screen length and widens that ratio by an order of magnitude, at which
// point a core appears at a sensible white point because there is a range to map.
// Re-judge this when #58 lands rather than tuning it now; 0.8 is the value the
// paragraph above argues for on its own terms.
//
// The 2.2-against-3.0 swing between frames is worth carrying too: the sweep is
// free-running, so how hard the beam dwells depends on where the phase happens to
// land, and phase 4's triggering is what stops that wandering.
//
// Editable live: a debug build recompiles this file on save (#61), and this is
// the number worth turning while looking at a host.
constant float white_headroom = 0.8;

// Which gradient to read: 0 green, 1 amber, 2 storage-tube blue, 3 neutral.
//
// A literal rather than a uniform because nothing can author or automate a choice
// until phase 5 gives it a parameter. All four are reachable today by editing this
// digit and saving, which is what makes them shipped rather than dormant. The
// gradients themselves are built in `src/gpu/palette.zig` and uploaded, so they
// are one definition rather than two: the GPU and the model read the same table.
constant uint palette_row = 0;

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

// Compress unbounded linear energy into [0, 1].
//
// Extended Reinhard: monotone, defined on the whole non-negative line, and equal
// to exactly one at the white point rather than approaching one asymptotically.
//
// **Plain Reinhard, e / (1 + e), is the obvious choice and is wrong here.** The
// attainable domain is (0, 1 / (1 - decay)], which is ten at the factor the Zig
// side currently applies, because a line strip's x is monotone in `vertex_id` so
// one frame cannot deposit twice on a pixel. Plain Reinhard returns 0.909 there
// and needs an energy of 167 to reach byte 255, seventeen times anything this
// display can produce, so a palette running to white never arrives and the core
// stays pale green. `1 - exp(-e)` fails from the other side, saturating by five
// and resolving nothing above it, which #58 makes worse by widening the domain.
//
// **The clamp on `dwell` is what a hot-reloaded shader needs**, not what this
// arithmetic needs. A fragment buffer no reloaded source declares reads zero, so
// `decay` is zero, the white point falls to `white_headroom` and everything above
// one deposit blows out white: loud and obviously wrong, which is the right
// failure. A decay of exactly one is the other end, and unclamped it would divide
// by zero; clamped, the shoulder term vanishes and this degrades to plain
// Reinhard rather than to a NaN the format turns into garbage.
float tonemap(float energy, float decay) {
    const float dwell = max(1.0 - decay, 1e-6);
    const float white = white_headroom / dwell;
    return min(energy * (1.0 + energy / (white * white)) / (1.0 + energy), 1.0);
}

// Put accumulated energy on the drawable, through the curve and the palette.
//
// **This is where the hot core comes from, and nothing draws one.** The gradient
// runs the phosphor's tint toward white on a fourth power, so a moving trace sits
// near the middle of the range and reads as the tint while a pixel the beam dwelt
// on climbs through the top fifth and arrives white. The core is the top of one
// monotone ramp rather than a second thing drawn over the first (ADR 0007), and
// the background is the same ramp's value at zero rather than a term added beside
// it — which is #60's own question about whether the background stays a literal,
// answered by construction. There is no colour in this file any more.
//
// **A gain of (1 - decay) was tried here and measured wrong**, which is worth
// recording because the arithmetic looks convincing. It normalises a stationary
// trace to the colour the unaccumulated line strip drew, and it does that by
// dividing a *moving* trace by ten, because a sliding trace never lights the
// same pixel twice and so never accumulates. In REAPER a 100 Hz sine measured a
// peak green of 53 against 255, which reads as a black display. This curve gives
// that same signal a peak green of 189 and a dwelt pixel 255, which is the whole
// difference between a curve and a gain.
//
// Reads green rather than `.rgb` because the deposit is a scalar now, and green
// rather than red because green is the channel everything else reads:
// `measure.Image.green`, `trace_threshold` in `src/smoke.zig`, and
// `scripts/measure-trace`'s isolation. Reading the same one is what makes those
// measurements statements about this pass rather than about a channel that
// happens to agree; `checkDepositIsScalar` is what keeps them agreeing.
//
// The lookup interpolates between neighbours **explicitly rather than through a
// sampler**, and that is load-bearing twice over. It puts no half-texel convention
// between this and the Zig model, so the two are exact rather than close; and it
// keeps a `sampler` out of this file, which a negative assertion in the renderer
// refuses for an unrelated reason. Nearest-neighbour would be 6.4 bytes wrong at
// 256 entries, because green is affine in `t` while the sRGB toe runs at 3294.6
// bytes per unit linear.
fragment float4 resolve_fragment(VertexOut in [[stage_in]],
                                 texture2d<float, access::read> energy [[texture(0)]],
                                 texture2d<float, access::read> palette [[texture(1)]],
                                 constant AccumUniforms &phosphor [[buffer(0)]]) {
    const float deposited = energy.read(uint2(in.position.xy)).g;
    const float t = tonemap(deposited, phosphor.decay);

    const uint entries = palette.get_width();
    const uint row = min(palette_row, palette.get_height() - 1u);

    const float x = t * float(entries - 1u);
    const uint lo = min(uint(floor(x)), entries - 1u);
    const uint hi = min(lo + 1u, entries - 1u);

    const float3 a = palette.read(uint2(lo, row)).rgb;
    const float3 b = palette.read(uint2(hi, row)).rgb;
    return float4(mix(a, b, x - floor(x)), 1.0);
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

// One deposit, as a scalar. The colour moved to the palette, which is what this
// comment used to say #60 would do.
//
// **All four channels carry the same number**, so whichever one anything reads
// means the same thing: `resolve_fragment` reads green, `measure.Image.green`
// reads green, and `checkDepositIsScalar` in `src/smoke.zig` asserts the four
// agree so a later weighting cannot make them disagree in silence. That also
// answers the question `mtl.blend_factor_one`'s comment left open — alpha
// accumulates exactly like the other three and carries the same meaning, and the
// resolve writes an opaque alpha of its own rather than reading it.
//
// **Three quarters of an `RGBA16Float` accumulation are now dead weight**, and
// narrowing it to `R16Float` is deliberately not done here: it would change
// `energy_bytes_per_pixel`, `readEnergy`, `iface.Readback.energy`'s
// four-floats-per-pixel contract and every `measure.Image` index, and #58 and #59
// may yet want per-channel data.
//
// This is a *deposit* into the accumulation rather than a write to the drawable,
// blended one-to-one and additive, so where the beam crosses its own path the
// value climbs past 1.0. That headroom is what the tonemap above wants and it is
// the reason the accumulation is floating point.
fragment float4 trace_fragment() {
    return float4(1.0);
}
