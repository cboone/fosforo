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
