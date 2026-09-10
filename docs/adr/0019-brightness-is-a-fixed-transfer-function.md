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

The headroom is below one for a reason that is easy to economise away. Extended Reinhard reaches its white point exactly at `e = w` while the steady state is only _approached_, so a white point set at the asymptote would never arrive and the core would be pale green forever.

**That sentence is now an assertion too** ([#96](https://github.com/cboone/fosforo/issues/96)), and it was the last claim in this ADR standing on prose alone. `src/gpu/palette.zig` holds `tonemap(w, w)` at one and the resolved bytes at 255 across the three white points a frame can produce, and holds it under one below the rail so the pair is not satisfied by a curve that returns one everywhere. Plain Reinhard fails it. **Two things planting it established that reading it did not.** Plain Reinhard fails three other tests as well, two of them pre-existing, so the acceptance criterion that predicted "every existing test passes" was written against a tree that #56 and #92 had since changed. And the identity is not bit-exact in f32 at every white point — it reads one ulp under one at the shipped 7.999998 and at the 8e5 clamp — so what is asserted exactly is the byte, which is the thing a viewer sees.

### The drawable is sRGB and the arithmetic is linear light

`MTLPixelFormatBGRA8Unorm_sRGB`, so the render-output stage applies the transfer function and the shader writes linear values. Both of the shader's remaining literals are therefore the _inverse_ of that function, and the background is spelled as the bytes it must show — `float3(5, 5, 8) / (255 * 12.92)` — because bytes are what depends on it: `scripts/measure-trace` locates the drawable inside a whole-window capture by looking for exactly `RGB(5, 5, 8)`.

`CAMetalLayer.colorspace` stays nil. Nil means "already display-ready" rather than "unmanaged", which is the assumption the non-sRGB format was relying on all along. Never set `kCGColorSpaceLinearSRGB`; that is the double encode.

### The gradients are data, not a formula in the shader

Four palettes — green, amber, storage-tube blue, and a neutral one for measurement — built in `src/gpu/palette.zig`, uploaded into a lookup texture, and indexed by the shader. **One definition read by two callers**, which is [ADR 0013](./0013-gui-smoke-harness-as-a-build-step.md)'s argument about `probe` sharing `buildPipelines` rather than paraphrasing it, applied to a colour: the analytic alternative would have needed the same formula written twice, in two languages, agreeing by inspection.

The lookup is indexed with `access::read` and interpolated by hand rather than sampled. Nearest-neighbour is 6.4 bytes wrong at 256 entries; a linear-filtered sampler would put a half-texel convention between the shader and the model that nothing could check; and a sampler anywhere in the shader fails an unrelated negative assertion in `src/gpu/metal/renderer.zig`.

**Every gradient's largest tint component is exactly 1.0**, which makes that channel an affine readout of the tonemapped value. That is a constraint on any future re-tint rather than a coincidence: `measure.Image.green`, `src/smoke.zig`'s threshold and `scripts/measure-trace`'s isolation and guard all invert on it, and breaking it changes the meaning of every channel readout in this project at once while failing nothing but the one test written for it.

## Consequences

**The hot core is emergent and is now executed rather than claimed.** `zig build smoke-trace` drives one deposit and thirty, and reads `RGB(102, 207, 119)` and `RGB(255, 255, 255)` off the picture. Nothing draws a core. **That first figure has moved twice and the claim has not.** It read `RGB(75, 189, 96)` when this was written; [#96](https://github.com/cboone/fosforo/issues/96) corrected it to `RGB(143, 224, 154)` because [#57](https://github.com/cboone/fosforo/issues/57) gave the beam area and a density scale, so one deposit became 2.6 deposits of overlap and got brighter; and [#58](https://github.com/cboone/fosforo/issues/58) moved it again, because velocity weighting brought a moving trace back to 1.57. Only the number moved, each time.

**The model and the picture agree, and the residual is the quantiser rather than the mapping.** `checkResolve` predicts all three channels of every pixel from one number, through the curve, the interpolation and the hardware's encode. That is stronger than the per-channel comparison it replaces, because it asserts the picture's chroma follows from the intensity, which is the palette's whole claim.

> **The figure this paragraph opened with has moved and the claim has not.** It read "off by **zero** across 518,400 pixels" when [#60](https://github.com/cboone/fosforo/issues/60) measured it, at 2412 lit pixels. [#57](https://github.com/cboone/fosforo/issues/57) gave the beam a falloff, which lights 4853 and puts most of the new ones in the gradient's toe, where the sRGB curve runs at 3294.6 bytes per unit linear and a rounding boundary is a whole level. The worst channel is **off by one**, the check allows exactly that, and `src/gpu/verdict.zig` carries the reasoning. If it ever reaches two, the question to ask is whether the toe moved rather than whether the tonemap did.

**The headroom is provisional, and the host session established that it cannot yet be tuned.** Measured in REAPER against a 100 Hz sine: the picture peaked at 2.2 and 3.0 deposits on two successive frames, against roughly 1 for a fast crossing. **No white point can carve a visible core out of a 2:1 range** — set it high and nothing reaches white, set it low and everything does. Dropping the headroom from 0.8 to 0.2 put white at 2.0 deposits and moved fifty pixels of thirty-two thousand, which is invisible by eye and was confirmed so.

That is a statement about [#58](https://github.com/cboone/fosforo/issues/58) rather than about this constant. Velocity weighting divides the deposit by segment screen length, which widens the dwell ratio by an order of magnitude, and only then is there a range for a white point to map. **Re-judge the headroom when #58 lands.** Until then the value is what the derivation argues for on its own terms and is not fitted to a picture, because the picture cannot yet distinguish one value from another.

> **Superseded: #58 has landed, the prediction in this paragraph was wrong, and the headroom is settled at 0.8. See the two amendments below.** The paragraph is kept as written because what was believed at the time is the point of recording it, and the second amendment is about that belief being mistaken.

Two things fell out of measuring it. The 2.2-against-3.0 swing between successive frames is the free-running sweep: how hard the beam dwells depends on where the phase happens to land, and phase 4's triggering is what stops that wandering. And **brightness legitimately varies with level**, in the direction that looks like a violation and is not — a quieter sine travels fewer rows per sample, so consecutive samples pile onto the same pixel and it accumulates more. That is the beam genuinely dwelling on a slower-moving trace, which is crude velocity weighting emerging from the rasterizer. What this ADR fixes is the _transfer function_, not the energy, and a check that asserted equal brightness across levels would be asserting something false.

> **The mechanism named there was superseded by [#57](https://github.com/cboone/fosforo/issues/57); the claim it supports was not.** "Consecutive samples pile onto the same pixel" describes a line rasterizer, and there is no line rasterizer any more. Brightness still varies with level, and now for a reason that is explicit rather than emergent: a beam is the union of oriented quads, adjacent quads overlap, and a slow-moving trace puts more of them over one pixel. The figure moved with it — a moving trace measures **2.6133** deposits at one sample per logical point rather than roughly 1 — and so did the range, which widened on its own before #58 has divided anything by anything. The headroom is still provisional and is still #58's to re-judge, against a picture that can now distinguish more values than it could.
>
> **[#58](https://github.com/cboone/fosforo/issues/58) has landed, and the prediction two paragraphs up is wrong in a way worth keeping.** "Widens the dwell ratio by an order of magnitude" was inferred from a 100 Hz sine, and that is the one signal it is not true of. Measured offscreen, turning point against zero crossing, at an amplitude of 0.5 in a 20 ms window:
>
> | signal | cycles in the window | before | after |
> | ------ | -------------------- | ------ | ----- |
> | 100 Hz | 2                    | 1.36   | 1.84  |
> | 1 kHz  | 20                   | 1.34   | 7.50  |
>
> A 100 Hz sine at 0.5 has a fastest crossing only **1.88 times** the speed of its turning point, because the sweep runs at 96,000 px/s over 1920 px in 20 ms while the trace reaches 152,681 px/s. No weighting can widen that, and the 1.84 measured is the beam being honest about the signal rather than the term underperforming. Anyone re-deriving this figure from a single test tone will reach the same wrong conclusion; use two tones a decade apart.
>
> **What changed is that the range now discriminates between signals.** Before, 100 Hz and 1 kHz both read about 1.35, so the transfer function mapped the same narrow band whatever was playing. That is gone.
>
> **But the headroom still has no visible travel, and the reason above is not why.** Judged in REAPER at 0.4 and at 1.2: no visible difference. That is arithmetic rather than eyesight. A moving trace deposits `d` once and slides on, reaching 1.57, while white sits at `white_headroom / (1 - decay)`, or 15.6 at 120 Hz — **ten times further**. Across 0.4 to 1.2 a 1 kHz turning point moves from green 191 to 190, its crossing does not move at all, and a stationary line reads 255 at both; only the time a cleared pixel takes to whiten changes, 47 ms against 229 ms, which is over before it can be looked at.
>
> So this ADR blamed the wrong constraint. The 2:1 range was real and #58 fixed it; the binding constraint is that the dwell asymptote is **19.5 times a single deposit** at 120 Hz, which follows from anchoring white to the asymptote at all rather than from anything about the beam. Nothing between "moving" and "stationary" exists on a free-running sweep, and lowering the headroom does not bridge it: at 0.2 a 100 Hz turning point still only reaches green 214, and the value that would whiten it is the value that whitens everything.
>
> **A white core on moving material is therefore a property of a _triggered_ display.** `white_headroom` stays at **0.8** on the derivation, and the re-judgement moves to phase 4, where the sweep stops wandering and periodic content can dwell. It is no longer waiting on anything in phase 3.

**The persistence tail roughly doubled, as a side effect nobody asked for.** The sRGB toe is 12.92 times steeper than the linear resolve it replaced, so a single deposit at `decay = 0.90` now falls below green 16 at frame 54 rather than 31: about half a second of visible trail becomes about a second at 60 Hz. The fix is free, and that is a property of the curve rather than luck — because the white point scales with the dwell asymptote, changing the decay does not change how bright a single deposit is, so `decay_per_frame` is a pure persistence knob for the first time and its value is what #56 should inherit as its initial `tau`.

**#56 inherited it, and inheriting a per-frame factor as a time constant needed a reference rate.** 60 Hz, which is the rate every row of the table above was computed against, giving `tau = -(1 / 60) / ln(0.90)` or 158.19 ms. The consequence on this machine is that the trail is twice what it was, because the panel runs at about 120 Hz and a per-frame 0.90 faded twice as fast there; at 60 Hz nothing changed at all. The constant is derived from the pair `(60 Hz, 0.90)` rather than written out, so the anchor is the thing to argue with.

**What ADR 0017 forbids is untouched.** That ADR fixes _displacement_ as a readout of amplitude and forbids compressing the region above full scale; this compresses _brightness_, which ADR 0017's own closing paragraph reserves to ADR 0007. Neither axis derives anything from the signal's statistics. The question was asked deliberately rather than assumed away, and the answer is that they are two axes.

**The compositor was the one thing no automated check here could see, and it was measured in a host.** `Renderer.readback` calls `getBytes:` on a texture and never involves CoreAnimation, so a screenshot is the only instrument for whether a `_sRGB` layer with a nil colorspace is composited the way the non-sRGB one was. A `clap-host` window captured with `screencapture` and converted from the display's profile reads **exactly `RGB(5, 5, 8)` across 99.9% of the drawable**, at every corner, which is the value format 80 put on screen: the change is invisible where it is supposed to be. The centre line at silence reads `RGB(255, 255, 255)`, since a stationary trace dwells and reaches the white point, and the peak row is 539 implying a sample of `+0.0021` — the same figure #38 measured in REAPER, so the vertical mapping is untouched.

Had it gone the other way the fallback was to revert the pixel format and do the encode in the shader, which produces identical stored bytes at the cost of one `pow` and leaves everything else in this decision standing. It is written down here because the argument for the format is now settled by a measurement rather than by that fallback being cheap.
