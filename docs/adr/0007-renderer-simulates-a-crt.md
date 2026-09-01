# 0007. Render as a simulation of a physical device

**Status:** Accepted

## Context

The obvious way to build an oscilloscope display is to plot a graph: take the samples, connect them with lines, draw. That approach produces exactly the frozen-in-time look the project exists to escape, and it discards information.

## Decision

Treat the renderer not as a plotter but as a small **simulation of a physical device**: an analog cathode-ray oscilloscope, where an electron beam deposits energy into a phosphor that glows and slowly decays.

## Consequences

This reframing is generative. Nearly every rendering decision falls out of asking "what did the tube physically do?" rather than "how do I draw a line."

Critically, the phosphor look is **not nostalgia**. The two things it produces, brightness that varies along the trace and a persistent halo, are direct readouts of the signal's statistics: where it dwells, and how much it varies. A single-trace plot throws both away. The reason to reproduce the physics is that the physics *is* information, and on a GPU it is cheap.

The concrete consequences:

- **A persistent floating-point accumulation buffer.** One texture surviving between frames, holding accumulated glow in linear light. It must persist, because the halo is the memory of recent beam positions. It must be floating point for two reasons: it accumulates additively past 1.0 where the beam dwells, and correct fading requires true multiplicative decay. An 8-bit alpha blend toward black stalls once values round back to the same integer, leaving permanent ghost trails that never clear.
- **Three passes per frame:** decay (dim what is there), trace (additively deposit the new sweep), tonemap (read accumulated linear energy, write the visible gamma-encoded image).
- **Frame-rate-independent persistence.** Decay is exponential in real elapsed time against a user-facing time constant, so the look is identical at 60 Hz, 120 Hz, or variable refresh.
- **The beam as geometry, not line primitives.** Each segment expands into an oriented quad shaded by perpendicular distance from the centerline, giving analytic antialiasing independent of MSAA and a real beam intensity profile.
- **Velocity-weighted intensity.** The beam sweeps at constant *time* rate but covers varying *screen* distance, so deposited brightness per unit length is inversely proportional to segment screen-length. This single relationship reproduces the entire characteristic look: bright at peaks and turning points where the trace doubles back, dim through fast crossings. For low-end work a kick's slow sub-tail glows solid while its sharp click smears dim, which is exactly the information worth foregrounding, obtained from the physics rather than designed in.
- **Bandlimited reconstruction before geometry.** The samples are not the signal. Connecting them with straight lines under-draws the true continuous waveform and hides intersample peaks. Polyphase upsampling before building segments, the same mathematics true-peak metering uses, makes the beam follow the real curve and makes overshoots visible.
- **Tonemapping with an emergent hot core.** Compressing unbounded linear energy through a curve and mapping through a palette running toward white produces a white-hot core inside a colored bloom wherever the beam dwelt, without ever drawing a core explicitly. This is the single most recognizable feature of a good scope render, and it emerges from accumulation plus tonemap rather than being authored.

An alternative path exists for maximal fidelity: rasterize segments in a compute kernel that atomically adds fixed-point energy into the accumulation buffer, giving exact control over deposition at the cost of hand-written line rasterization. The additive-blend pipeline is chosen because it is simpler and looks excellent; the compute path stays available if the last increment of fidelity is wanted later.

## Amended by issue #60: the tonemap consequence is built

The third pass exists. `resolve_fragment` compresses accumulated energy through extended Reinhard and looks the result up in one of four gradients running to white, into a `BGRA8Unorm_sRGB` drawable so the arithmetic happens in linear light.

**The emergent hot core is real, and it is now executed rather than asserted.** `zig build smoke-trace` drives one deposit and thirty and reads the picture back: `RGB(75, 189, 96)` and `RGB(255, 255, 255)`. Nothing draws a core, exactly as this ADR predicted; what produces it is the top of one monotone ramp being reached only where the beam dwelt.

Two things this ADR did not anticipate, both recorded in [ADR 0019](./0019-brightness-is-a-fixed-transfer-function.md) because they are decisions rather than consequences. The white point has to be **derived from the decay** or the look tracks the refresh rate once decay becomes a function of elapsed time. And plain Reinhard cannot produce the feature at all: the attainable energy domain is bounded by the dwell asymptote, and plain Reinhard needs an energy seventeen times that to reach white, so the core would be pale green forever.

**Frame-rate-independent persistence is built** ([#56](https://github.com/cboone/fosforo/issues/56)), and the bullet above is the whole of what it needed to say. The decay is `exp(-dt / tau)` with `tau` at 158.19 ms, anchored so that one frame at 60 Hz reproduces the provisional 0.90 the accumulation shipped with; the fade is 0.9 s at 48, 60, 120 and 240 Hz rather than doubling with each halving of the rate. What this ADR did not say, because it could not have, is that the claim is falsifiable by no single screenshot: it is about how successive frames differ. `zig build smoke-trace` fades the same 96 ms as twelve 8 ms steps and as six 16 ms ones and asserts the two agree, which they do to 0.18%.

**The clock is `display_link.monotonicNanos()` rather than the `CVTimeStamp` CoreVideo hands the callback**, and the reasoning lives beside the code in `src/platform/displaylink.zig`. The short form: exponential decay composes, so the total fade over an interval depends on its length and not on how it was cut into frames, which leaves the timestamp buying a bounded per-frame phase error that never accumulates against the cost of laying out 80 bytes of `CVTimeStamp` by hand with no header to check them against.

**One honest caveat about what is visible today.** Steps 4, 5 and 6 of the build plan's phase 3 are not built, so the only source of energy variation is persistence at pixels the beam revisits. That is enough — a stationary trace goes white and a moving one stays tinted — but the velocity weighting this ADR calls "the single relationship" that produces the characteristic look is still ahead, and the core it will produce is a different and sharper thing than the one dwell alone produces.

## Amended by issue #57: the beam is geometry

The geometry bullet is built. Each inter-sample segment expands into a quad and the fragment shades it by distance from the beam's path, so the trace has a width that was chosen, an intensity profile, and antialiasing that comes from the profile rather than from multisampling. The line strip is gone.

**The width is 3.0 points, and points rather than backing pixels is the load-bearing half.** `iface.trace_rail` keeps the rail 1% of the half-height inside the drawable, which is 2.7 points at the smallest editor `gui.clampSize` permits; a half-width of 1.5 points fits inside that at every backing scale, because both terms are in points and the scale cancels. Stated in pixels the same guarantee has to be re-derived per scale factor and then holds at each one separately.

**Two departures from the wording above, both deliberate.** This ADR says "shaded by perpendicular distance from the centerline", which is the infinite line: no caps, no joints, no overlap. What is built measures distance to the *segment*, which gives round caps, and that buys three things a perpendicular distance does not. Joints are covered with no wedge gap outside a turn. The first and last samples sit at `x = ±1` and their caps have area, which closes the edge-column question [#38](https://github.com/cboone/fosforo/issues/38) left open: `zig build smoke-trace` reads 960 of 960 columns lit at the level that failed, on a single frame, where every earlier reading was taken from an accumulated screenshot that persistence could have been masking. And a degenerate segment collapses to a disk rather than to a NaN.

The second departure is that the ADR pictures the quads as an efficiency detail ("instanced rendering feeds this efficiently"). They are instanced, but the reason that matters is a seam claim rather than a throughput one: `src/gpu/iface.zig` predicted that oriented quads would either confirm or falsify its argument that raw `[]const f32` crosses the seam and a vertex type must not. Each segment is one instance, `[[instance_id]]` reads the two samples bounding it, `[[vertex_id]]` picks a corner, and there is still no `MTLVertexDescriptor` anywhere in the project. The prediction held.

**The profile is the biweight, `(1 - u²)²`, and its compact support is doing more work than its shape.** It peaks at exactly 1.0 on the centreline, so a single segment still deposits an energy of one and the white point's derivation from the dwell asymptote is untouched. It reaches zero *with zero slope* at the quad's edge, so there is no seam. And an unlit pixel holds exactly 0.0, which is what lets the resolve check keep its background assertions and lets `src/gpu/measure.zig` read a beam's centre by summing a whole column. A Gaussian is the profile a real beam has and has none of those three properties.

**The premise that one frame cannot deposit twice on a pixel is retired.** [ADR 0013](./0013-gui-smoke-harness-as-a-build-step.md) measured a line strip depositing exactly 1.0000 per pixel per frame, and the tonemap's choice of extended Reinhard over plain Reinhard was argued from the bounded domain that implies. Quads overlap at every joint, so a moving trace now measures **2.6133** deposits at one sample per logical point. The conclusion survives and is strengthened, since a wider domain is what extended Reinhard handles and plain Reinhard does not, but the reasoning had to be rewritten in both places that carried it.

**And overlap turned out to have a consequence nothing anticipated: brightness became a function of the session's sample rate.** Per-pixel energy is roughly `1 + 1.6 * s` for `s` samples per logical point, so a 192 kHz session on a default editor, or 96 kHz on the smallest one, would saturate a *moving* trace to white. A line strip was idempotent in overdraw and had no such term. `TraceUniforms.density` is the answer: the segment pitch in pixels, clamped so it only attenuates, one number per frame derived from the window length and the drawable width and from nothing about the signal. That last clause is what keeps it out of [#58](https://github.com/cboone/fosforo/issues/58)'s territory, whose term varies per segment with how fast the beam is moving.

**The caveat the amendment above ended with is now half spent.** Velocity weighting is still ahead and is still "the single relationship". But dwell is no longer the only source of energy variation: the overlap at a turning point is real dwell arriving from geometry rather than from persistence, and it widened the single-frame range on its own. What #58 adds is the per-segment division that makes a fast crossing dim, which this does not.
