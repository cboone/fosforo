# 0019. Brightness is a fixed transfer function, and the white point is its rail

**Status:** Accepted

## Context

[ADR 0007](./0007-renderer-simulates-a-crt.md) specifies a tonemap pass that compresses unbounded linear energy through a curve and a palette running toward white. [#60](https://github.com/cboone/fosforo/issues/60) built it, and building it forced four decisions that ADR 0007 does not make and that will each be reopened by somebody who has not read this.

The arithmetic that forces them is worth restating, because every one of these follows from it. A **moving** trace lights each pixel once per frame, so its energy is one. A **stationary** one re-deposits into the same pixel every frame and converges on `1 / (1 - decay)`, which is ten at the shipped factor. [#55](https://github.com/cboone/fosforo/issues/55) shipped a resolve at unit gain, which clips the dwelt end to white and loses the colour, then tried a gain of `1 - decay`, which renders the moving end at green 53 of 255 and reads as a black display. A linear mapping into eight bits can show one end of that range or the other.

## Decision

**Brightness is a fixed monotone transfer function of accumulated energy, and of nothing else.**

Four consequences, each stated so it is not relitigated in review.

### The curve depends on energy alone

No dependence on the frame's or the window's own statistics. The curve, the gradients, the tint and the exponent are constants; the white point derives from the decay, which is a property of the simulated phosphor and, once [#56](https://github.com/cboone/fosforo/issues/56) lands, of the refresh rate — never of the audio.

**The improvement someone will propose is an exposure derived from the frame's measured peak energy**, because it makes quiet material look right without a control. That is auto-gain on the brightness axis, and it is refused by exactly the reasoning [ADR 0017](./0017-absolute-vertical-axis.md) uses on the vertical one: a display that rescales itself to the signal cannot be read against itself between two moments. Adding it needs an ADR superseding this one.

### The white point is the brightness axis's rail

Above it the display says "at or above" and refuses to say how far, which is ADR 0017's own criterion applied to the second axis. `iface.trace_rail` and this are the same kind of object, and `scripts/measure-trace` reports both the same way: a peak on the vertical rail prints "at or above +0.74 dBFS, amount unknowable", and a pixel at or above the white point prints that rather than an energy.

It is `white_headroom / (1 - decay)` rather than a constant, and that is not a tuning convenience. The dwell asymptote tracks the decay, so a fixed white point would make the look depend on the refresh rate the moment #56 measures elapsed time: at 120 Hz the steady state is 19.5 against 60 Hz's 10, so the same picture would read twice as hot. Deriving it holds a single deposit at green 188 to 190 and the steady state at 255 across 48, 60, 120 and 240 Hz.

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

**The persistence tail roughly doubled, as a side effect nobody asked for.** The sRGB toe is 12.92 times steeper than the linear resolve it replaced, so a single deposit at `decay = 0.90` now falls below green 16 at frame 54 rather than 31: about half a second of visible trail becomes about a second at 60 Hz. The fix is free, and that is a property of the curve rather than luck — because the white point scales with the dwell asymptote, changing the decay does not change how bright a single deposit is, so `decay_per_frame` is a pure persistence knob for the first time and its value is what #56 should inherit as its initial `tau`.

**What ADR 0017 forbids is untouched.** That ADR fixes *displacement* as a readout of amplitude and forbids compressing the region above full scale; this compresses *brightness*, which ADR 0017's own closing paragraph reserves to ADR 0007. Neither axis derives anything from the signal's statistics. The question was asked deliberately rather than assumed away, and the answer is that they are two axes.

**What is still unmeasured, stated so it is not read as settled.** A `_sRGB` layer with a nil colorspace is composited the way the non-sRGB one was — this follows from the stored bytes being identical and from Apple's documentation, and it is corroborated by third parties, but no capture of a running host has confirmed it here. `Renderer.readback` calls `getBytes:` on a texture and never involves CoreAnimation, so **no automated check in this project can see it**; a screenshot is the only instrument. If it turns out wrong, the fallback is to revert the pixel format and do the encode in the shader, which produces identical stored bytes at the cost of one `pow` and leaves everything else in this decision standing.
