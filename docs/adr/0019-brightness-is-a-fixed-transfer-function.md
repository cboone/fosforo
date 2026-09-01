# 0019. Brightness is a fixed transfer function, and the white point is its rail

**Status:** Accepted

## Context

[ADR 0007](./0007-renderer-simulates-a-crt.md) specifies a tonemap pass that compresses unbounded linear energy through a curve and a palette running toward white. [#60](https://github.com/cboone/fosforo/issues/60) built it, and building it forced four decisions that ADR 0007 does not make and that will each be reopened by somebody who has not read this.

The arithmetic that forces them is worth restating, because every one of these follows from it. A **moving** trace lights each pixel once per frame, so its energy is one. A **stationary** one re-deposits into the same pixel every frame and converges on `1 / (1 - decay)`, which is ten at the shipped factor. [#55](https://github.com/cboone/fosforo/issues/55) shipped a resolve at unit gain, which clips the dwelt end to white and loses the colour, then tried a gain of `1 - decay`, which renders the moving end at green 53 of 255 and reads as a black display. A linear mapping into eight bits can show one end of that range or the other.

## Decision

**Brightness is a fixed monotone transfer function of accumulated energy, and of nothing else.**

Four consequences, each stated so it is not relitigated in review.

### The curve depends on energy alone

No dependence on the frame's or the window's own statistics. The curve, the gradients, the tint and the exponent are constants; the white point derives from the decay, which is a property of the simulated phosphor and, since [#56](https://github.com/cboone/fosforo/issues/56) landed, of the refresh rate — never of the audio.

**The improvement someone will propose is an exposure derived from the frame's measured peak energy**, because it makes quiet material look right without a control. That is auto-gain on the brightness axis, and it is refused by exactly the reasoning [ADR 0017](./0017-absolute-vertical-axis.md) uses on the vertical one: a display that rescales itself to the signal cannot be read against itself between two moments. Adding it needs an ADR superseding this one.

### The white point is the brightness axis's rail

Above it the display says "at or above" and refuses to say how far, which is ADR 0017's own criterion applied to the second axis. `iface.trace_rail` and this are the same kind of object, and `scripts/measure-trace` reports both the same way: a peak on the vertical rail prints "at or above +0.74 dBFS, amount unknowable", and a pixel at or above the white point prints that rather than an energy.

It is `white_headroom / (1 - decay)` rather than a constant, and that is not a tuning convenience. The dwell asymptote tracks the decay, so a fixed white point would make the look depend on the refresh rate the moment #56 measures elapsed time: at 120 Hz the steady state is 19.5 against 60 Hz's 10, so the same picture would read twice as hot. Deriving it holds a single deposit at green 188 to 190 and the steady state at 255 across 48, 60, 120 and 240 Hz.

**That prediction has been discharged, and the table it was computed from is now an assertion.** #56 landed and the decay is genuinely different at each of those rates, so this stopped being a property held in reserve and became the thing keeping the picture the same. `src/gpu/palette.zig` holds a deposit's resolved bytes to within two levels across 48, 60, 120 and 240 Hz and requires the dwell steady state to reach exactly 255 at all four; both run under `zig build test` on a runner with no GPU. Nothing checked it before, and it is the failure that would have arrived in silence if `tau` or the headroom moved — a picture correct at one refresh rate and hot or dim at another, with every other test green.

The headroom is below one for a reason that is easy to economise away. Extended Reinhard reaches its white point exactly at `e = w` while the steady state is only *approached*, so a white point set at the asymptote would never arrive and the core would be pale green forever.

### The drawable is sRGB and the arithmetic is linear light

`MTLPixelFormatBGRA8Unorm_sRGB`, so the render-output stage applies the transfer function and the shader writes linear values. Both of the shader's remaining literals are therefore the *inverse* of that function, and the background is spelled as the bytes it must show — `float3(5, 5, 8) / (255 * 12.92)` — because bytes are what depends on it: `scripts/measure-trace` locates the drawable inside a whole-window capture by looking for exactly `RGB(5, 5, 8)`.

`CAMetalLayer.colorspace` stays nil. Nil means "already display-ready" rather than "unmanaged", which is the assumption the non-sRGB format was relying on all along. Never set `kCGColorSpaceLinearSRGB`; that is the double encode.

### The gradients are data, not a formula in the shader

Four palettes — green, amber, storage-tube blue, and a neutral one for measurement — built in `src/gpu/palette.zig`, uploaded into a lookup texture, and indexed by the shader. **One definition read by two callers**, which is [ADR 0013](./0013-gui-smoke-harness-as-a-build-step.md)'s argument about `probe` sharing `buildPipelines` rather than paraphrasing it, applied to a colour: the analytic alternative would have needed the same formula written twice, in two languages, agreeing by inspection.

The lookup is indexed with `access::read` and interpolated by hand rather than sampled. Nearest-neighbour is 6.4 bytes wrong at 256 entries; a linear-filtered sampler would put a half-texel convention between the shader and the model that nothing could check; and a sampler anywhere in the shader fails an unrelated negative assertion in `src/gpu/metal/renderer.zig`.

**Every gradient's largest tint component is exactly 1.0**, which makes that channel an affine readout of the tonemapped value. That is a constraint on any future re-tint rather than a coincidence: `measure.Image.green`, `src/smoke.zig`'s threshold and `scripts/measure-trace`'s isolation and guard all invert on it, and breaking it changes the meaning of every channel readout in this project at once while failing nothing but the one test written for it.

## Consequences

**The hot core is emergent and is now executed rather than claimed.** `zig build smoke-trace` drives one deposit and thirty, and reads `RGB(75, 189, 96)` and `RGB(255, 255, 255)` off the picture. Nothing draws a core.

**The model and the picture agree exactly.** `checkResolve` predicts all three channels of every pixel from one number and reports the worst channel off by **zero** across 518,400 pixels, through the curve, the interpolation and the hardware's encode. That is stronger than the per-channel comparison it replaces, because it asserts the picture's chroma follows from the intensity, which is the palette's whole claim.

**The headroom is provisional, and the host session established that it cannot yet be tuned.** Measured in REAPER against a 100 Hz sine: the picture peaked at 2.2 and 3.0 deposits on two successive frames, against roughly 1 for a fast crossing. **No white point can carve a visible core out of a 2:1 range** — set it high and nothing reaches white, set it low and everything does. Dropping the headroom from 0.8 to 0.2 put white at 2.0 deposits and moved fifty pixels of thirty-two thousand, which is invisible by eye and was confirmed so.

That is a statement about [#58](https://github.com/cboone/fosforo/issues/58) rather than about this constant. Velocity weighting divides the deposit by segment screen length, which widens the dwell ratio by an order of magnitude, and only then is there a range for a white point to map. **Re-judge the headroom when #58 lands.** Until then the value is what the derivation argues for on its own terms and is not fitted to a picture, because the picture cannot yet distinguish one value from another.

Two things fell out of measuring it. The 2.2-against-3.0 swing between successive frames is the free-running sweep: how hard the beam dwells depends on where the phase happens to land, and phase 4's triggering is what stops that wandering. And **brightness legitimately varies with level**, in the direction that looks like a violation and is not — a quieter sine travels fewer rows per sample, so consecutive samples pile onto the same pixel and it accumulates more. That is the beam genuinely dwelling on a slower-moving trace, which is crude velocity weighting emerging from the rasterizer. What this ADR fixes is the *transfer function*, not the energy, and a check that asserted equal brightness across levels would be asserting something false.

> **The mechanism named there was superseded by [#57](https://github.com/cboone/fosforo/issues/57); the claim it supports was not.** "Consecutive samples pile onto the same pixel" describes a line rasterizer, and there is no line rasterizer any more. Brightness still varies with level, and now for a reason that is explicit rather than emergent: a beam is the union of oriented quads, adjacent quads overlap, and a slow-moving trace puts more of them over one pixel. The figure moved with it — a moving trace measures **2.6133** deposits at one sample per logical point rather than roughly 1 — and so did the range, which widened on its own before #58 has divided anything by anything. The headroom is still provisional and is still #58's to re-judge, against a picture that can now distinguish more values than it could.

**The persistence tail roughly doubled, as a side effect nobody asked for.** The sRGB toe is 12.92 times steeper than the linear resolve it replaced, so a single deposit at `decay = 0.90` now falls below green 16 at frame 54 rather than 31: about half a second of visible trail becomes about a second at 60 Hz. The fix is free, and that is a property of the curve rather than luck — because the white point scales with the dwell asymptote, changing the decay does not change how bright a single deposit is, so `decay_per_frame` is a pure persistence knob for the first time and its value is what #56 should inherit as its initial `tau`.

**#56 inherited it, and inheriting a per-frame factor as a time constant needed a reference rate.** 60 Hz, which is the rate every row of the table above was computed against, giving `tau = -(1 / 60) / ln(0.90)` or 158.19 ms. The consequence on this machine is that the trail is twice what it was, because the panel runs at about 120 Hz and a per-frame 0.90 faded twice as fast there; at 60 Hz nothing changed at all. The constant is derived from the pair `(60 Hz, 0.90)` rather than written out, so the anchor is the thing to argue with.

**What ADR 0017 forbids is untouched.** That ADR fixes *displacement* as a readout of amplitude and forbids compressing the region above full scale; this compresses *brightness*, which ADR 0017's own closing paragraph reserves to ADR 0007. Neither axis derives anything from the signal's statistics. The question was asked deliberately rather than assumed away, and the answer is that they are two axes.

**The compositor was the one thing no automated check here could see, and it was measured in a host.** `Renderer.readback` calls `getBytes:` on a texture and never involves CoreAnimation, so a screenshot is the only instrument for whether a `_sRGB` layer with a nil colorspace is composited the way the non-sRGB one was. A `clap-host` window captured with `screencapture` and converted from the display's profile reads **exactly `RGB(5, 5, 8)` across 99.9% of the drawable**, at every corner, which is the value format 80 put on screen: the change is invisible where it is supposed to be. The centre line at silence reads `RGB(255, 255, 255)`, since a stationary trace dwells and reaches the white point, and the peak row is 539 implying a sample of `+0.0021` — the same figure #38 measured in REAPER, so the vertical mapping is untouched.

Had it gone the other way the fallback was to revert the pixel format and do the encode in the shader, which produces identical stored bytes at the cost of one `pow` and leaves everything else in this decision standing. It is written down here because the argument for the format is now settled by a measurement rather than by that fallback being cheap.
