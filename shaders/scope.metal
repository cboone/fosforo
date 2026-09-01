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
// #57 made the trace geometry: each inter-sample segment is an oriented quad,
// shaded by its distance from the segment rather than by whether a one-pixel line
// happened to cover the pixel, which is where the antialiasing and the intensity
// profile both come from. The other two are done. #60 put a tonemap and a palette
// lookup in the resolve, and there is no colour left in this file — the gradients
// are built in `src/gpu/palette.zig` and uploaded, so the GPU and the model that
// checks it read one table rather than two copies of one formula. #56 made the
// decay factor `exp(-dt / tau)` against a measured elapsed time, and that arrived
// without a line of MSL changing: it is computed once per frame on the Zig side
// rather than once per pixel here, which is what `AccumUniforms` being a uniform
// rather than a literal was always for.

#include <metal_stdlib>

using namespace metal;

// The fraction of a dwelling beam's steady state that reads pure white.
//
// **The white point is derived from the decay rather than fixed**, which is why
// this is a fraction and not an energy. A beam that never moves converges on
// 1 / (1 - decay); anchoring white there makes the look independent of how long
// the phosphor holds, and since #56 made the decay a function of elapsed time it
// is what stops the picture reading twice as hot at 120 Hz as at 60. That is a
// live property now rather than a prediction, and a test in
// `src/gpu/palette.zig` holds a deposit's brightness to within two bytes across
// 48, 60, 120 and 240 Hz.
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
// `uniforms.decay` is `exp(-dt / tau)` for the interval since the last committed
// frame, computed in `src/gpu/palette.zig` and handed over per frame (#56). That
// is why it arrives as a uniform rather than living here as a literal the way
// `trace_fragment`'s colour used to: it is a measurement, not a look constant.
// The `exp` stays on the CPU because it is the same number for every pixel.
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
// attainable domain is (0, d / (1 - decay)], where d is the energy one frame
// deposits on the pixel the beam dwells hardest on. Until #57 that was exactly
// one, because a line strip's x is monotone in `vertex_id` so one frame could not
// deposit twice on a pixel; oriented quads overlap at every joint, so it is now
// about 2.6 and the domain is correspondingly wider. The conclusion survives the
// premise and is strengthened by it. Plain Reinhard returns 0.909 at ten
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
// The last four are per-frame measurements rather than constants, which is why
// the Zig side gives them no defaults. `viewport` is the accumulation's own size,
// because nothing here ever calls `setViewport:` and a render pass therefore takes
// its extent from the attachment; `half_width_px` is the beam's width in points
// times the display's scale; and `density` is described at `trace_fragment`.
struct TraceUniforms {
    uint sample_count;
    float full_scale;
    float rail;
    float half_width_px;
    float viewport_width;
    float viewport_height;
    float density;
};

// The segment this fragment belongs to, in the same window space `[[position]]`
// arrives in.
//
// **`flat` rather than interpolated, and it is only correct because all four
// corners compute the same pair.** A triangle strip's two triangles have
// different provoking vertices, so a `trace_vertex` that derived *this corner's*
// own endpoint instead would hand the two halves of one quad different segments
// and draw a discontinuity along its diagonal, with nothing here to fail.
struct TraceOut {
    float4 position [[position]];
    float2 p0 [[flat]];
    float2 p1 [[flat]];
};

// Clip space to the window space a fragment's `[[position]]` arrives in.
//
// **The Y negation belongs to the rasterizer and is restated here, not added.**
// `trace_vertex` still emits clip space with positive up, which is what the "No Y
// flip" note below is about; this pair exists because the beam's width is
// isotropic in pixels and anisotropic in clip space, so the expansion has to
// happen on this side of the transform and come back. Writing `(y * 0.5 + 0.5)`
// here instead mirrors the trace against `in.position.y` while still drawing a
// plausible picture.
float2 to_window(float2 clip, float2 viewport) {
    return float2((clip.x + 1.0) * 0.5 * viewport.x, (1.0 - clip.y) * 0.5 * viewport.y);
}

float2 to_clip(float2 window, float2 viewport) {
    return float2(2.0 * window.x / viewport.x - 1.0, 1.0 - 2.0 * window.y / viewport.y);
}

// Distance from a point to a *segment*, not to the line through it.
//
// The difference is the whole of what gives the beam round caps, and it buys three
// things at once. Joints are covered, so there is no wedge gap outside a turn. The
// first and last samples sit at x = ±1 and the quad containing them has area,
// which is what
// #38's 1914-of-1920 edge columns were about. And a degenerate segment collapses
// to a disk rather than to the NaN `normalize` would hand back.
float distance_to_segment(float2 p, float2 a, float2 b) {
    const float2 ab = b - a;
    const float denom = dot(ab, ab);
    const float t = denom > 1e-12 ? saturate(dot(p - a, ab) / denom) : 0.0;
    return distance(p, a + t * ab);
}

// One instance per inter-sample segment, expanded into an oriented quad.
//
// `[[instance_id]]` is the segment and reads the two samples that bound it;
// `[[vertex_id]]` runs 0..3 and picks a corner. **Nothing describes a vertex to
// Metal**: there is no `MTLVertexDescriptor`, no buffer of corners, and the only
// thing crossing `src/gpu/iface.zig` is still a plain `[]const f32`. That file
// predicted this step would either confirm or falsify that arrangement, and it
// confirmed it.
//
// The samples arrive oldest first, so segments run left to right and the newest
// sample lands exactly on the right edge. Dividing by `sample_count - 1` rather
// than by `sample_count` is what puts it there, and it is why the caller refuses
// to draw below two samples: at one this divides by zero and there is no segment
// to draw anyway.
//
// `device` rather than `constant` for the samples, because `constant` is for
// values indexed uniformly across a draw and this is indexed per instance. The
// window would fit in `constant`'s 64 KiB, so this is a choice rather than a
// constraint.
//
// **No Y flip here**, unlike `fullscreen_vertex` above. A positive sample is up,
// which is what a scope means, and the rasterizer is what turns that into a row
// counted from the top. `to_window` restates that transform rather than adding
// one; see its comment, which is where the sign is easy to get backwards.
//
// The quad is *oriented*: the segment's own box, extended by the half-width along
// its direction at both ends and along its normal on both sides, which is the
// capsule's bounding box with the rounding left to the fragment. Corner selection
// is the Z order a triangle strip wants, `(-,-) (+,-) (-,+) (+,+)`; the ring
// order gives a bowtie covering half the quad, and since nothing in this project
// sets a cull mode or a winding, neither a bowtie nor a mirrored quad announces
// itself. Note also that `vertex_id & 2u` is 0 or **2** rather than 0 or 1 —
// `fullscreen_vertex` exploits that deliberately four functions above, so the
// idiom reads as correct here and would silently double the quad's height.
//
// The clamp is the vertical scale's whole policy in one line, and ADR 0017 is
// why it clamps rather than letting the rasterizer clip: clipping removes the
// peaks and keeps the crossings, so an over-scale signal would read as a quieter
// one with gaps.
vertex TraceOut trace_vertex(uint vertex_id [[vertex_id]],
                             uint segment [[instance_id]],
                             device const float *samples [[buffer(0)]],
                             constant TraceUniforms &uniforms [[buffer(1)]]) {
    const float2 viewport = float2(uniforms.viewport_width, uniforms.viewport_height);
    const float span = float(uniforms.sample_count - 1u);

    const float y0 = clamp(samples[segment] * uniforms.full_scale, -uniforms.rail, uniforms.rail);
    const float y1 = clamp(samples[segment + 1u] * uniforms.full_scale, -uniforms.rail, uniforms.rail);

    const float2 a = to_window(float2(2.0 * float(segment) / span - 1.0, y0), viewport);
    const float2 b = to_window(float2(2.0 * float(segment + 1u) / span - 1.0, y1), viewport);

    const float2 along = b - a;
    const float len = length(along);
    const float2 dir = len > 1e-6 ? along / len : float2(1.0, 0.0);
    const float2 normal = float2(-dir.y, dir.x);

    const float h = uniforms.half_width_px;
    const float2 corner = float2((vertex_id & 1u) != 0u ? 1.0 : -1.0,
                                 (vertex_id & 2u) != 0u ? 1.0 : -1.0);

    const float2 at = 0.5 * (a + b) + dir * corner.x * (0.5 * len + h) + normal * corner.y * h;

    TraceOut out;
    out.position = float4(to_clip(at, viewport), 0.0, 1.0);
    out.p0 = a;
    out.p1 = b;
    return out;
}

// One deposit, as a scalar, shaped by the beam's intensity profile. The colour
// moved to the palette, which is what this comment used to say #60 would do.
//
// **The profile is the biweight, `(1 - u²)²`.** It peaks at exactly 1.0 on the
// centreline, so a single segment still deposits an energy of one at its core and
// `whitePoint`'s derivation from the dwell asymptote is untouched, and it reaches
// zero *with zero slope* at the quad's edge, so there is no seam where the
// geometry ends. Compact support is worth more than it looks: an unlit pixel holds
// exactly 0.0, which is what lets `checkResolve` keep its background assertions
// and what lets `src/gpu/measure.zig` sum a whole column for its centroid. A
// Gaussian is the profile a real beam has and has neither property, on top of
// putting a transcendental on this path.
//
// **`density` is the segment pitch in pixels, clamped to one, and it is not
// velocity weighting.** Quads overlap at every joint, so a pixel collects roughly
// `1 + 1.6 * s` deposits where `s` is samples per logical point. At one sample per
// point that is about 2.6; at four it is 7.4 and a *moving* trace saturates to
// white, which is reachable at 96 kHz on a small editor and 192 kHz on a default
// one. The line strip was idempotent in overdraw and had no such term. This factor
// is identical for every segment in a frame and depends only on the window length
// and the drawable width, never on the signal, which is exactly what distinguishes
// it from #58's per-segment term.
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
fragment float4 trace_fragment(TraceOut in [[stage_in]],
                               constant TraceUniforms &beam [[buffer(0)]]) {
    const float d = distance_to_segment(in.position.xy, in.p0, in.p1);
    const float u = min(d / beam.half_width_px, 1.0);
    const float falloff = 1.0 - u * u;

    return float4(falloff * falloff * beam.density);
}
