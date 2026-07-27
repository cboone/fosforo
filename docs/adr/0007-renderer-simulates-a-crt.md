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
