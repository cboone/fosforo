# Tonemap accumulated energy through a palette into an sRGB drawable

Issue [#60](https://github.com/cboone/fosforo/issues/60). Branch `feature/tonemap`. Phase 3, step 7 of `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`. Depends on [#55](https://github.com/cboone/fosforo/issues/55) (the accumulation) and [#51](https://github.com/cboone/fosforo/issues/51) (the offscreen readback); planned against [#61](https://github.com/cboone/fosforo/issues/61) as merged, which it now is ([#78](https://github.com/cboone/fosforo/pull/78)).

## Context

`resolve_fragment` is a bare add. It reads the accumulation, adds a background literal, and lets `BGRA8Unorm` clip whatever exceeds 1.0. That is what #55 shipped deliberately, so that this issue would replace a body rather than re-add a pass, and it is the last provisional thing between the accumulation and a picture worth looking at.

The arithmetic that makes it provisional is in #60's own comment and it is the whole problem. A **moving** trace lights each pixel once per frame, so its energy is 1.0. A **stationary** one re-deposits into the same pixel every frame and converges on `1 / (1 - decay)`, which is 10 at the factor `renderer.zig` currently applies. A linear mapping into eight bits can show one end of that range or the other and not both, which #55 measured from both sides: a unit gain clips a dwelt trace to white and loses the colour, and a gain of `1 - decay` renders a moving one at green 53 against 255, which reads as a black display. **The tonemap is not a refinement of a picture that already works. It is the only thing that makes the two ends coexist**, and the white-hot core inside a coloured bloom that ADR 0007 calls the single most recognisable feature of a good scope render is what falls out when they do.

Three things have changed since the issue was filed and all three change the work.

- **#51 landed.** `zig build smoke-trace` renders offscreen through the shipping pipeline and reads back two surfaces: `energy`, the linear unclipped accumulation, and `picture`, the resolved bytes. Seven of its nine cases read `energy` and are untouched by anything here. ADR 0013's #51 amendment predicted exactly that — *"the geometry assertions read the accumulation rather than the picture precisely because #60 rewrites only the latter"* — and it is right. This issue discharges that prediction and inherits an instrument the issue's body assumed would not exist.
- **#61 landed**, so a debug build swaps `shaders/scope.metal` live. That is worth five issues' worth of iteration and this is the issue with the most to iterate on, which decides where the curve's constants live.
- **The tooling breaks less than the issue predicts, and only because of one choice.** #60 says a palette breaks every green-channel measurement #38 established. It does, unless the palette's dominant channel is exactly 1.0 — in which case that channel stays an *exact affine readout* of the tonemapped value and `measure.Image.green`, `trace_threshold`, `lit_rows` and the capture guard all survive with re-derived numbers rather than being replaced. All four palettes below are built to hold that property, and it gets asserted rather than relied on.

## Findings that shaped the design

Every number here was evaluated rather than recalled. Where something could not be measured under plan mode it says so and names the instrument that settles it.

### The drawable's format, and the two things that move with it

`MTLPixelFormatBGRA8Unorm_sRGB = 81`, read out of `$(xcrun --show-sdk-path)/System/Library/Frameworks/Metal.framework/Headers/MTLPixelFormat.h:66`, which is the practice `mtl`'s own docstring asks for and the practice that caught the line-strip enum. The header's *prose* at `CAMetalLayer.h:73-75` claims only two layer formats are supported; Apple's documentation lists nine. The enum values are current and the comment is stale — do not read that comment as authority.

`drawable_pixel_format` is one constant feeding three sites that must agree: the layer's `setPixelFormat:`, `resolve_pass.pixel_format`, and `buildTarget`'s offscreen descriptor. They move together by construction, which is what `renderer.zig:167-171` claims and is now load-bearing rather than tidy.

**`CAMetalLayer.colorspace` stays nil and no `setColorspace:` call is added.** Nil means "these bytes are already display-ready", not "unmanaged", and it is the assumption format 80 has been relying on all along. The stored bytes are identical either way; what changes is which *linear* value produces a given byte. Never set `kCGColorSpaceLinearSRGB` — that is the double-encode, and it shows as middle grey reading 187.

### The background literal has to move, and it is not cosmetic

`float3(0.02, 0.02, 0.03)` stores bytes `RGB(5, 5, 8)` today because the format applies no transfer function. Under format 81 the hardware encodes it, storing **`RGB(39, 39, 48)`**, 7.8x brighter. Four things break at once, and only three of them break loudly.

The literal therefore becomes the linear value that encodes back to the same bytes, written as the inverse rather than as a decimal:

```metal
float3(5.0, 5.0, 8.0) / (255.0 * 12.92)
```

Both values are inside the transfer function's linear segment, whose ceiling is byte 10, so no power is involved and the round trip lands on an integer: `12.92 * (5 / (255 * 12.92)) * 255` is exactly 5.000, half a byte from either rounding boundary. That margin is deliberate — Apple's float-to-unorm conversion is documented to bias low by 1/127500 of full scale, so a literal near a `.5` boundary is not something to assert on. Spelling it as bytes also puts the one number `scripts/measure-trace`'s crop depends on where a test can see it: a linear decimal would make the byte value a derivation the Python side could get wrong in silence, and the constants test would compare two agreeing linear numbers while the crop looked for black.

**Nothing a viewer sees changes.** `find_drawable`, `README.md`'s "the background is `RGB(5, 5, 8)`", `checkResolve`'s four structural background assertions and AGENTS.md's pixel-sampling technique all survive untouched, and that is the point of choosing this spelling over a round linear number.

### The tint is not phase 2's triple, and reusing it would ship a paler green while calling it unchanged

`trace_fragment` returns `float4(0.30, 1.0, 0.45, 1.0)` into a drawable the compositor reads as sRGB, so **those are display-encoded numbers**, showing bytes `RGB(76, 255, 115)`. A palette that mixes in linear light and reuses them produces `RGB(149, 255, 179)` at full brightness: a visibly whiter green, shipped as "the same colour". The linear tint that *is* that green is the sRGB decode, `(0.073239, 1.0, 0.170645)`, and `measure.zig` holds the test that encodes it back to `(76, 255, 115)` so the derivation is executable rather than asserted in a comment.

### Plain Reinhard cannot reach white, and the white point has to follow the decay

The attainable energy domain today is `(0, 10]`. A line strip's x is monotone in `vertex_id`, so one frame cannot deposit twice on a pixel; the only source of energy past 1.0 is accumulation, whose asymptote is `1 / (1 - decay)`.

| curve | at e = 1 | at e = 10 | first white | verdict |
| --- | --- | --- | --- | --- |
| `e / (1 + e)` | green 188 | green 245, spread 26 | e ≈ 20 | **never arrives.** Needs e = 167 for byte 255, 17x anything reachable |
| `1 - exp(-e)` | green 208 | green 255 | e ≈ 6 | burns half its range below e = 3 and resolves nothing above 10 |
| `min(e(1 + e/w²)/(1 + e), 1)` | green 189 | white | **exactly at e = w** | monotone, unbounded domain, saturates where told |

Extended Reinhard, and `w` is not a free constant. Once #56 makes decay `exp(-dt / tau)`, the steady state `1/(1 - decay) ≈ tau/dt` tracks the refresh rate, so a **fixed** white point makes the display twice as hot at 120 Hz as at 60. Deriving it from the same decay the accumulation already uses removes that exactly:

| Hz | decay | steady state | `w = 0.8 / (1 - decay)` | green at e = 1 | green at steady state |
| --- | --- | --- | --- | --- | --- |
| 48 | 0.876603 | 8.10 | 6.48 | 190 | 255 |
| 60 | 0.900000 | 10.00 | 8.00 | 189 | 255 |
| 120 | 0.948683 | 19.49 | 15.59 | 188 | 255 |
| 240 | 0.974004 | 38.47 | 30.77 | 188 | 255 |

Frame-rate invariant to within one byte at both ends, for free, and it pre-empts a defect #56 would otherwise inherit. The headroom of 0.8 is why white is *reached* rather than approached: Reinhard equals 1 at `e = w` and the steady state is only asymptotic, so a white point set at the asymptote itself would never arrive.

**`white_headroom` is therefore an MSL literal and the resolve pass reads `decay` from a uniform.** `AccumUniforms` already carries it, and `accum_uniform_index`'s docstring already says "where the **two** fullscreen passes find the accumulation and their uniforms" — the resolve is the pass that had not needed it yet.

### The LUT must interpolate, and 256 entries is then plenty

A gradient lookup read with nearest-neighbour indexing is **6.4 bytes wrong** at 256 entries, because green is affine in `t` while the sRGB toe has a slope of `12.92 x 255 = 3294.6` bytes per unit linear: a step of 1/255 in `t` is thirteen bytes at the dark end. Interpolating between adjacent entries in the fragment — explicitly, with a `mix`, not with a sampler — drops it to **0.004 bytes**, three orders of magnitude inside the check's tolerance.

| entries | nearest | interpolated |
| --- | --- | --- |
| 64 | 19.47 bytes | 0.065 |
| 128 | 11.55 | 0.016 |
| **256** | **6.36** | **0.004** |
| 1024 | 1.57 | 0.0002 |

Doing the interpolation by hand rather than with a linear-filtered sampler is what makes the Zig-side model **exact**: no half-texel convention to get wrong, and no `sampler` in the shader. That last matters concretely — `renderer.zig:2573` asserts `bindingIndexAfter("AccumUniforms &", "sampler")` is null, and `bindingIndexAfter` scans the whole file after its needle, so a sampler anywhere below line 72 would fail a negative test whose message is about the accumulation uniforms.

### The shader is 105 bytes from failing a test

`src/gpu/metal/shader.zig:254` asserts `embedded.len * 8 < max_bytes`, which is `embedded.len < 8192`. **`shaders/scope.metal` is 8087 bytes.** This change adds two to three kilobytes. Left alone it fails as a bare `expect` with no message, in a file nobody editing MSL is looking at, and the obvious fix — raising `max_bytes` — enlarges a 64 KiB stack `Buffer` in `buildPipelines` and two `[shader.max_bytes]u8` locals in `src/smoke.zig`. **Change the factor, not the bound**: `* 4` keeps `max_bytes` at 64 KiB and still asserts fourfold headroom. Deal with it in the first commit, not by discovering a red test.

### Fast math is on, so keep the resolve free of transcendentals

`buildPipelinesFromSource` passes `null` for `MTLCompileOptions`, so relaxed precision is in effect. That is fine and needs no new object, provided the new code stays arithmetic: extended Reinhard is a rational function, the LUT read is a `mix`, and **the sRGB encode is done by the render-output stage rather than by shader code**, which is a real advantage of an sRGB drawable over encoding by hand. The palette's fourth power lives in the Zig generator, not the shader. The only cross-language approximation left is the ROP's sRGB encode against the reference formula, which is what `checkResolve`'s byte tolerance is actually about.

### The persistence tail roughly doubles, as a side effect nobody asked for

The sRGB toe is 12.92x steeper than today's linear resolve, so a decaying deposit stays above any given byte for far longer. Measured: a single deposit at `decay = 0.90` currently falls below green 16 after **31 frames**, and after this change it takes **54** — visible persistence goes from about half a second to about a second at 60 Hz.

That is a look change arriving as a consequence of gamma encoding rather than as a decision, and it is worth knowing before the first host session mistakes it for a defect. **The fix is free, and that is a property of the curve rather than luck:** because the white point scales with the dwell asymptote, changing the decay does not change how bright a single deposit is. `decay_per_frame` therefore becomes a pure persistence knob, decoupled from brightness for the first time. Expect to move it in this diff, record the arithmetic, and hand the value to [#56](https://github.com/cboone/fosforo/issues/56) as its initial `tau`.

### Two claims nothing here can measure, and what settles them

- **`getBytes:` on an `_sRGB` texture returns the raw stored bytes.** Documented behaviour and consistent with `replaceRegion:`'s universally-relied-on inverse, but unmeasured. `smoke-trace`'s first run settles it: see the three-way reading in Verification step 2.
- **A `_sRGB` layer with a nil colorspace composites the way format 80 did.** `readPicture` calls `getBytes:` off a shared texture and never involves CoreAnimation, so **no automated check in this project can see this.** A `screencapture` of a real host is the only instrument.

**Both get their own commit, before the tonemap exists, and the sequencing is the point.** A commit that flips the format and converts the two literals and changes nothing else leaves the resolve's arithmetic identical, so the picture on that commit and the picture on `main` must be byte-identical at the background and within a level or two everywhere else. **That comparison cannot be made later**, because once the palette lands there is no before-picture to compare against. It is also the cheapest possible isolation: one variable moved, one thing to blame.

**The fallback, if it fails, is not to abandon the design.** Revert the format to 80 and do the sRGB encode in the shader by hand. It produces identical stored bytes at the cost of one `pow` in a fragment where fast math is on, and everything else — the curve, the palette, the model, the tooling — is unchanged. Knowing that in advance is what makes the format flip a cheap experiment rather than a commitment.

## Design

### `shaders/scope.metal`

Two MSL literals, both hot-reloadable, and that is the whole of what the shader owns:

```metal
constant float white_headroom = 0.8;   // white at headroom / (1 - decay)
constant uint  palette_row    = 0;     // 0 green, 1 amber, 2 blue, 3 neutral
```

`resolve_fragment` gains a second fragment texture and the uniform:

```metal
fragment float4 resolve_fragment(VertexOut in [[stage_in]],
                                 texture2d<float, access::read> energy [[texture(0)]],
                                 texture2d<float, access::read> palette [[texture(1)]],
                                 constant AccumUniforms &phosphor [[buffer(0)]])
```

It reads green from the accumulation, computes `w = white_headroom / (1 - phosphor.decay)`, maps `t = min(e * (1 + e / (w * w)) / (1 + e), 1.0)`, and looks the colour up: `i = t * (n - 1)` with `n = palette.get_width()`, then `mix` of `palette.read(uint2(floor(i), row))` and its successor. The row is clamped with `palette.get_height()` so a mistyped literal cannot read out of bounds.

**Guard the reciprocal, because an unbound buffer reads zero.** This is the #77 exposure reaching the resolve pass for the first time: a hot-reloaded shader that omits the uniform, or declares it at another index, gets `decay = 0`, so `w = 0.8` and everything above one deposit blows out to white. That failure is loud and obviously wrong, which is the acceptable outcome — but `decay = 1` would give `w = inf` and then `NaN`, so the shader writes `1.0 / (w * w)` as a guarded term that degrades to plain Reinhard rather than to a NaN the format turns into garbage.

`trace_fragment` becomes `return float4(1.0);` — a scalar deposit. The palette owns colour now. All four channels carry the same number so that whichever one anything reads means the same thing, which also answers the question `mtl.blend_factor_one`'s docstring left open about alpha.

**The parameter names are load-bearing.** `bindingIndexAfter` anchors on them, and `phosphor` must differ from `decay_fragment`'s `uniforms` or the assertion reads the wrong declaration. `resolve_fragment` keeps its name: `renameResolve` in `src/smoke.zig:307` does a literal search-and-replace for it, and a rename there fails as `error.RenamedShaderNotRefused`, which names the wrong thing entirely.

### The palette, which is Zig data rather than a shader formula

This is the consequence of choosing a lookup over a closed form, and it lands better than expected: **there is exactly one definition of the palette, and the GPU and the model read the same table.** `src/gpu/measure.zig` owns the generator and the four tints; `renderer.zig` uploads what it produces; `measure.resolved` interpolates the same table the shader does. The analytic alternative would have needed the formula written twice, in two languages, agreeing by inspection.

One generator, four tints, each authored in sRGB and decoded once:

| palette | authored | bytes | linear tint | exact channel |
| --- | --- | --- | --- | --- |
| green (P31, phase 2's own) | `(0.30, 1.00, 0.45)` | 76, 255, 115 | `(0.073239, 1.0, 0.170645)` | green |
| amber (P3) | `(1.00, 0.69, 0.00)` | 255, 176, 0 | `(1.0, 0.433880, 0.0)` | red |
| storage-tube blue (P11) | `(0.35, 0.60, 1.00)` | 89, 153, 255 | `(0.100482, 0.318547, 1.0)` | blue |
| neutral white (measurement) | `(1.00, 1.00, 1.00)` | 255, 255, 255 | `(1.0, 1.0, 1.0)` | all three |

```
entry(tint, t) = background + (1 - background) * mix(tint, 1, t^4) * t
```

`background` at `t = 0` and exactly white at `t = 1`, both by construction and with no overshoot for the format to clip. That first property answers #60's open question directly: **the background stops being a literal beside the palette and becomes the palette's value at zero energy**, stated once. Monotone in every channel, since `d/dt` is `(1 - bg)(tint + 5(1 - tint)t⁴)`, non-negative for a tint in `[0, 1]`.

**Every palette's dominant channel is exactly 1.0**, which is the property the measurement chain rests on: `mix(1, 1, w) = 1` for any `w`, so that channel is `bg + (1 - bg) * t` — affine, verified to `0.00e+00` across all four. It gets asserted in `measure.zig`, because a re-tint that broke it would change the meaning of every channel readout in this project at once and fail nothing.

The core exponent of 4 confines the whitening to the top fifth: the white weight is 0.06 at `t = 0.5` and 0.66 at `t = 0.9`. At 2 the whole picture whitens.

### What the picture becomes

Green palette, `w = 8`, which is `0.8 / (1 - 0.90)`:

| energy | t | R | G | B | spread | reads as |
| --- | --- | --- | --- | --- | --- | --- |
| 0.10 | 0.0911 | 22 | 86 | 36 | 64 | green |
| 0.50 | 0.3359 | 48 | 157 | 71 | 109 | green |
| **1.00** (a moving trace) | 0.5078 | **75** | **189** | **96** | 114 | green |
| 3.00 | 0.7852 | 157 | 229 | 166 | 72 | green |
| 5.00 | 0.8984 | 205 | 243 | 209 | 38 | pale |
| 7.00 | 0.9707 | 240 | 252 | 241 | 12 | near white |
| **8.00** and above | 1.0000 | **255** | **255** | **255** | 0 | **WHITE** |

A moving trace peaks at green 189 against #55's failing 53. A dwelt pixel reaches `e ≥ 8` after 16 frames of continuous deposit — 267 ms at 60 Hz, 133 ms at 120 Hz, that difference being #56's defect rather than this one's.

### `src/gpu/metal/renderer.zig`

- `mtl.pixel_format_bgra8_unorm_srgb: u64 = 81` added, `pixel_format_bgra8_unorm`'s docstring rewritten (it currently *predicts* this change), and `drawable_pixel_format` repointed. The layer, `resolve_pass` and `buildTarget` follow.
- `palette_texture_index: u64 = 1` beside the existing three zeroes, with the note that fragment textures are their own index space.
- A `palette: objc.Object` field, built once in `acquire`/`assemble` and released in `deinit`. `MTLTextureType2D`, `RGBA32Float` (125), `palette_entries` x `palette_count`, usage `shader_read`, storage `shared`, filled with one `replaceRegion:mipmapLevel:withBytes:bytesPerRow:` from `measure.buildPalette`. 16,384 bytes; f32 rather than f16 so the model and the texture hold bit-identical values.
- `frame`'s resolve encoder binds the palette texture and `setFragmentBytes:` the `AccumUniforms` it already built for the decay pass.
- Docstrings that become false: `Surface.target` and `picture_bytes_per_pixel` both say "`BGRA8Unorm`"; `mtl.blend_factor_one`'s open question about alpha; and `AccumUniforms`' advice that "#60 is likely to want a companion. A second field then costs a layout test line rather than a new binding" — **that advice is a trap and gets corrected rather than left**, because `AccumUniforms` was bound only to the decay pass, so a field added for the resolve would have failed the `@sizeOf` test and still not reached the fragment that wanted it.

### `src/gpu/measure.zig`

The model of the resolve belongs here on `expectedRow`'s explicit precedent, and the file's opening argument applies unchanged: an analysis that runs only against a GPU is one nothing tests.

New: `background_bytes`, the four tints, `core_exponent`, `palette_entries`, `white_headroom`, `decay_per_frame`; `srgbEncode`/`srgbDecode`; `buildPalette` and `paletteAt` (the shader's interpolation, restated); `tonemap(energy, white_point)`; `whitePoint(decay)`; `resolved(energy) [3]u8`; `dominantToTonemapped(byte) f32`, the exact inverse the capture guard rests on; and `peakPixel(image, c)`, which `checkHotCore` needs.

`Image.green`'s docstring is rewritten. It currently says #60 ends the green convention. It does not, and the reason it does not is now a *constraint on future re-tints* rather than an accident of the beam's colour.

### `scripts/measure-trace`

The guard's structure survives and every one of its numbers has to be re-derived. The picture is still a one-dimensional manifold; the dominant channel still inverts it exactly; red and blue still follow. What changed is that the manifold is **curved**, so an error in the estimator no longer maps to an equal error in the prediction: `d(red byte)/d(green byte)` runs from 0 at the bottom to about 4.4 at `t = 0.85`, against a flat 0.30 on the old linear ray. The tolerance is therefore applied to the *estimator channel*, in levels, and the prediction is evaluated at both ends of that slack — which keeps `RAY_TOLERANCE` meaning what it says and refuses the alternative of widening it fourfold everywhere, which is the tolerance-wide-enough-to-hide-a-systematic-error the guard's predecessor was replaced for.

Also: `SATURATED = 250` stops excluding anything, because the dominant channel now reaches 255 only at the white point rather than clipping at `c = 0.98`; and **`--threshold 64` silently doubles the persistence envelope it reports** — byte 64 used to be an energy of 0.251, about 13 frames of trail, and under the sRGB toe it is 0.0525, about 28. The default becomes derived from an energy with the derivation in its `help=` string. A `--palette N` option selects which gradient to invert against, defaulting to 0.

**`BG8 = tuple(c * 255.0 ...)` is the silent failure to sequence deliberately.** Flip the format and forget the shader literal and `checkResolve` fails loudly. Convert the literal and forget the Python side and nothing fails at all: `want` becomes `[0, 0, 1]`, pure black passes all five of `find_drawable`'s conditions, and the tool crops to a title bar and reports rows for a region that is not the drawable. Spelling the background as bytes on both sides is what removes that failure rather than documenting it.

### `src/smoke.zig`

`checkResolve` keeps its whole-image loop and changes its model to `measure.resolved`, reading energy from **green only** and comparing all three picture channels against it — strictly stronger than today's per-channel comparison, because it asserts the picture's chroma follows from one number, which is the palette's whole claim. Renamed `error.ResolveNotTheTonemap`. One assertion is added, turning #60's own question into a check: the background read off pixel (0,0) equals `measure.resolved(0)`, or `error.BackgroundNotThePaletteAtZero`.

`checkBeamIsOneColour` is **adapted, not retired**. Its green-dominance line fails immediately against `float4(1.0)` and its ray premise is gone, but the loop is the only thing anywhere asserting the accumulation's channels move together, and nothing else links `measure.Image.green` to the channel the resolve reads. It becomes `checkDepositIsScalar`.

`checkHotCore` is new and is the headline feature made executable. Nothing today drives enough frames for the accumulation to reach the white point, so without it the core is never rendered on a GPU. One deposit must be green-dominant with peak green ≥ 128 (a bound, not a tune, so it survives a re-tune, and it names #55's measured 53); thirty depositing frames must put `maxChannel` past the white point and `peakPixel` at 255 in all three channels.

`checkDecay` stops restating `0.90` and reads `measure.decay_per_frame`, which a test in `renderer.zig` pins against the real constant.

## Verification

### Order, because the first two settle assumptions nothing here has measured

1. `zig build test`, then `zig build validate-shaders`. The latter will not catch a pipeline that cannot link — that is `smoke-gpu`'s job.
2. **`zig build smoke-trace`, and read the background line first.** It settles three unmeasured claims at once and the outcomes are distinguishable: `RGBA(5, 5, 8, 255)` means the hardware encodes on write and `getBytes:` returns stored bytes; `RGBA(0, 0, 0, 255)` with `BackgroundNotBlueLeading` means one of those two is false and the harness must move to a blit-to-buffer readback; `RGBA(39, 39, 48, 255)` with `BackgroundNotDark` means the format moved and the literal did not. Then read the printed "worst channel off by N" and decide the tolerance from it rather than from a failing run. Expect 1; if it is 2, widen to 2 **with the measurement recorded**, which still leaves three orders of magnitude against the 224-level defect the check exists to catch.
3. `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert zig-out/bin/fosforo-smoke appkit 3`, by hand. A pixel format changed, and AGENTS.md names a pipeline-versus-attachment mismatch as one of exactly two misconfigurations that present a frame and draw the wrong picture. Run a smoke step first: `zig build` does not rebuild the harness.
4. `zig build smoke-gpu`, `smoke-appkit`, and `smoke-leaks -Dleak-cycles=40`.
5. **The palette texture's leak visibility, measured before anything is assumed** (ADR 0013's standing rule, and the rule exists because a leaked `MTLTexture` is invisible to `leaks` *and* to peak RSS while a leaked command queue is caught in the same run). Drop its release from `deinit`, run `smoke-leaks`, and record which of `leaks`, the byte bound, or nothing catches 16 KiB per cycle. **If nothing does, add `liveLookupTextures` as a twelfth seam operation** and assert it in `src/smoke.zig` beside the other two. Either way the result goes in the instruments table in AGENTS.md, which is what that table is for.
6. **The compositor, on the format commit and against `main`.** This is the check that cannot be deferred. Install with `zig build install-clap` or use `CLAP_PATH`, confirm with `scripts/read-provenance`, launch REAPER from a terminal, and capture the same content on `main` and on the format commit. **The two must be byte-identical at the background and within a level or two everywhere else.** If the harness reads 5 and the screenshot reads about 39, the compositor is double-encoding; the fallback above is the shader-side encode, not abandoning the design.
7. **The look, in a host, in this order** — provenance first, REAPER from a terminal so `clap.log` and the `rendering at N Hz` meter are readable, `screencapture -o -x -t png -W` per case, every capture read with `scripts/measure-trace --explain`:
   - **Silence, transport stopped.** The cheapest confirmation, because it exercises the whole one-to-white range with no signal: the centre line goes green to white over about a quarter of a second. White on the first frame means the white point is too low; never whitening means it is unreachable.
   - **`sine-100hz-0.5.wav`.** The peak row and implied sample must be **identical to #38's published values**. #60 touches colour and not geometry; movement there means something else broke.
   - **`level-2.000.wav`, the best demonstration available today.** The clamp pins about 32% of columns to the rail rows phase-independently, so those rows dwell while the connecting strokes do not: a hot region emerging from dwell alone, with no #57 and no #58, and ADR 0017's visible rail made brighter. `plateau` width must be unchanged.
   - **`click-2hz.wav`.** A white stationary centre line with a dim green transient over it — ADR 0007's own kick-and-click example in the one form available before #58. If the transient is invisible, the exposure is the knob.
   - **`sine-1000hz-0.5.wav`**, where forty-odd randomly-phased ghosts overlap most. Computed haze at green 117 against a live trace at 189. **This is the main aesthetic risk**, and the persistence-tail finding above is why.
   - **Resize, which clears the accumulation.** The issue's own before-picture: today the trace flashes green and passes through cyan, because blue clips at about two frames and red at four. It must now climb green to white monotonically. **A visible cyan or yellow on the way up means the palette is not monotone in hue and the design is wrong.**
   - **Switch `palette_row` to 1, 2 and 3 and save**, without restarting the host, to confirm all four gradients and to exercise #61 on the thing it was pulled forward for.
8. **The level sweep, 0.002 through 2.000, which is the ADR 0017 check and is new.** The trace's *brightness* must not track the signal's level; only its displacement may. Peak green at 0.100 and at 0.500 should agree to within a byte or two, since only the path length differs. Nothing checks this today because brightness was saturated at every level, and if brightness does track level the tonemap has become auto-gain.
9. `clap-validator`, `zig fmt --check`, `typos`, `ruff format --check . && ruff check .` (the log must say it read **1** file), `shfmt -d` and `shellcheck` via `git ls-files`.

### What retunes, and what reverts

Written down in advance, because at the keyboard every one of these reads as "the change is wrong".

| Symptom | Response |
| --- | --- |
| The trace reads dim | Retune the exposure live under `FOSFORO_SHADER_PATH`. Revert only if no value makes both ends work, which would mean the curve family is wrong |
| The picture is muddy at 1 kHz | Lower `decay_per_frame`. The curve decouples persistence from brightness, so this costs nothing, and the value goes to #56 as its initial `tau` |
| A white core where material should not produce one | The premise "a moving trace does not accumulate" would be wrong. Re-derive the curve from measured energies rather than from this plan's |
| The screenshot does not show `RGB(5, 5, 8)` | Revert **the format flip only** and encode in the shader. Keep everything else |
| `checkResolve` cannot fit within ±2 bytes | The hardware's encode diverges from the reference formula by more than a level, which makes the one assertion that would have caught #55 unusable. Decisive for the shader-side encode |
| Brightness tracks signal level in the sweep | Stop. Something made the transfer function depend on the frame's contents, and ADR 0017 forbids that without a superseding ADR |

**Pre-refuse, in the plan and in the constant's docstring, the improvement someone will propose:** deriving the exposure or the white point from the frame's *measured peak energy*. That is auto-gain on the brightness axis, refused by exactly the reasoning ADR 0017 uses on the vertical one. The white point deriving from `decay` is not that — decay is a property of the simulated phosphor and of the refresh rate, never of the audio.

### Planted defects

Each is planted on top of a passing run, because an absence has to be told apart from an instrument that never ran. Commit before planting, and make each plant's trigger unconditional.

| Plant | Must be caught by |
| --- | --- |
| Revert `drawable_pixel_format` to 80, leave the literal | `checkResolve` → `error.BackgroundNotDark` (background reads 0, 0, 1) |
| Move the format to 81, leave `float3(0.02, 0.02, 0.03)` | `checkResolve` → `error.BackgroundNotDark` (background reads 39, 39, 48) |
| Use the display-encoded tint `(0.30, 1.0, 0.45)` as linear | `measure.zig` → the tint-encodes-back-to-(76, 255, 115) test |
| Plain Reinhard, `w` removed | `checkHotCore` → the dwelt end never reaches 255 |
| Swap `t` and `1 - t` in the LUT index | `measure.zig` monotonicity test, and `checkResolve` |
| Nearest-neighbour LUT lookup instead of `mix` | `checkResolve` → worst off by 6, not 1 |
| Re-tint so the dominant channel is 0.95 | `measure.zig` → the exact-affine-channel test |
| `trace_fragment` returns `float4(1.0, 0.9, 1.0, 1.0)` | `checkDepositIsScalar` |
| Move `palette_row` past the last row | shader clamp; assert the clamp by planting a row of `NaN` past the end |
| Drop the reciprocal's guard and bind no uniform to the resolve | `checkResolve`, loudly — the point of the plant is that it fails as white rather than as `NaN` |
| Drop the palette texture's release in `deinit` | step 5 above decides which instrument, and that is the measurement |
| Change `white_headroom` in MSL only | the constants test |
| Rename a Python constant so it ends with another's | the occurrence-count assertion added to the constants test |

**Two things nothing automated can catch, stated so they are not assumed away.** A badly chosen constant is arithmetically correct and passes a model-versus-picture comparison, because both sides use it: a white point wrong by a factor of ten looks wrong and fails nothing. And #55's gain passed 160 unit tests, every smoke half, `clap-validator` and the validation layer, and was found by eye in under a minute. **Budget a REAPER session with the level sweep before calling this done.**

### The reload hazard, which is specific to this issue's working style

While iterating with `FOSFORO_SHADER_PATH` set, the running picture comes from a file the constants test has never seen, and #60 multiplies the number of look constants that hazard covers. Re-run `zig build test` and re-capture **after the last save**, before quoting any number. This is safe inside `smoke-trace` for a reason worth knowing: `frame` skips the watcher on `.target` surfaces, so the offscreen half always measures the embedded copy.

## Files

| File | Change |
| --- | --- |
| `shaders/scope.metal` | Two literals, the tonemap, the LUT lookup, a scalar deposit, the header's three-pass note |
| `src/gpu/metal/shader.zig` | The read buffer's headroom factor, 8x to 4x, with the measurement |
| `src/gpu/metal/renderer.zig` | Format 81 and the repoint; the palette texture and its index; the resolve's two new bindings; five docstrings; the reworked constants test and four new assertions |
| `src/gpu/measure.zig` | The palette generator, the four tints, the sRGB transfer function, the resolve model, the inverse, `peakPixel`, and their tests |
| `src/smoke.zig` | `checkResolve`'s model, `checkDepositIsScalar`, `checkHotCore`, the decay constant, comment repairs |
| `scripts/measure-trace` | Six restated constants, the curved-manifold guard, the derived threshold, `--palette`, the messages |
| `docs/adr/0019-…` | New: the brightness axis is a fixed transfer function |
| `docs/adr/0007`, `0013`, `0017` | Amendments: the consequence is built; the #51 prediction is discharged; the tension was asked about and there is none |
| `AGENTS.md` | Six gotcha bullets and the Current state section |
| `.github/workflows/ci.yml` | The `smoke` job's measured-figures comment, whose beam-ray numbers die with `checkBeamIsOneColour` |
| `README.md`, `CHANGELOG.md`, the phase plan | Step 7 done; an `[Unreleased] / Added` entry; `README.md:65` survives untouched, which is itself a check |

## Commits

Each builds and is `zig build test`-clean.

1. **`chore: make room in the shader read buffer for a tonemap (#60)`** — `shader.zig` only, first, so the next commit's growth does not fail a bare `expect` in a file nobody editing MSL is looking at.
2. **`feat: model the sRGB transfer function as arithmetic (#60)`** — `measure.zig` gains `srgbEncode`/`srgbDecode` and their round-trip and continuity tests. Nothing calls it yet; small and obviously correct alone.
3. **`feat: build the phosphor palettes as a table (#60)`** — `measure.zig` gains the four tints, the generator, `paletteAt` and the monotonicity, exact-channel, background-at-zero and tint-encodes-back tests. Still nothing on the GPU. This is the commit where the four palettes are proved without a device.
4. **`feat: write the drawable in linear light through an sRGB format (#60)`** — the format constant, the repoint, both shader literals converted, `checkResolve`'s model gaining only the sRGB encode, the Python side gaining it too. **The resolve's arithmetic is untouched**, so the picture on this commit and the picture on `main` must be indistinguishable, and this is the only commit where that comparison is available. Split out for exactly that reason, and because it is the one commit whose failure mode is a fallback rather than a fix.
5. **`feat: tonemap accumulated energy through a palette into an sRGB drawable (#60)`** — the atom: the curve, the palette texture, the two new bindings, the scalar deposit, `measure.resolved`, `checkResolve`'s model, `checkDepositIsScalar`, `checkHotCore`, and the Python constants. **Deliberately not split further**: the picture and the things that read it are one decision, any intermediate state has a shader disagreeing with its model, and the constants test would fail in every one of them. The guard's three empirical numbers keep their current values here, marked pending, because a capture of a picture that does not exist yet cannot be taken; for one commit the guard may over-refuse, which is loud rather than silent.
6. **`chore: re-derive the capture guard's constants from a fresh pair (#60)`** — after a real REAPER capture and a quality-60 JPEG of it, read with `--explain`. **Replaces** the tables in the script and in AGENTS.md rather than amending them; quoting #64's old margins beside new arithmetic is the exact failure #64 was filed about.
7. **`docs: record the brightness axis as a fixed transfer function (#60)`** — ADR 0019, three amendments, AGENTS.md, the CI comment, CHANGELOG, the phase plan.

An eighth, `fix:`, for whatever the host session turns up, should be expected rather than planned. A `refactor:` moving `decay_per_frame` is likely too, for the reason the persistence-tail finding gives.

## Out of scope

- **Narrowing the accumulation to `R16Float`.** A scalar deposit makes three of four channels dead weight, and the pair is 33 MB per editor at the default geometry. It would change `energy_bytes_per_pixel`, `readEnergy`, `iface.Readback.energy`'s four-floats-per-pixel contract and every `measure.Image` index, and #58 and #59 may yet want per-channel data. File it; do not fold it in.
- **A control for the palette.** `palette_row` is an MSL literal, so all four are reachable today by editing one digit and saving. A *parameter* is phase 5's, and it is what would make the LUT authorable rather than merely selectable.
- **Hot-reloading the gradients themselves.** The lookup buys one definition of the palette shared by the GPU and the model; it costs live retuning of the stops. The curve's headroom and the palette selection stay editable.
- **Checking a hot-reloaded shader's binding indices.** [#77](https://github.com/cboone/fosforo/issues/77) owns it, and this issue makes it worse in a way worth recording: the resolve pass has no bindings today, and afterwards it has two textures and a buffer.
- **Anything about #56, #57, #58 or #59.** The white point derived from decay is not an implementation of #56; it is this issue declining to build a defect #56 would have to find.

## Risks to watch at the keyboard

1. **Do the compositor check early.** It is the one assumption nothing automated can reach, and if it is wrong the colour story changes rather than a number moving.
2. **The two-step background trap.** The loud half is the format; the silent half is the Python side, and the constants test cannot see it. Spell the background as bytes on both sides.
3. **A tint whose dominant channel is not exactly 1.0** changes the meaning of every channel readout in this project at once and fails nothing but the one test written for it.
4. **`bindingIndexAfter` scans forward from its needle to end of file.** New MSL parameter names must not be prefixes or substrings of existing ones, and the `sampler` negative test at `renderer.zig:2573` closes the door on ever switching the LUT to a filtered sampler.
5. **Python constant names must not end with another's.** `scalarAfter` takes the first substring match, so `TONEMAP_WHITE_POINT` above `WHITE_POINT` silently repoints an assertion. Add an occurrence-count check to the test rather than relying on the convention.
6. **The arity guard goes vacuous if `BEAM` is renamed.** `scalarsAfter(script, "BEAM = ", "(", 4)` returning null stops being an arity test and becomes a second copy of the not-found test, with its comment still claiming otherwise. Re-point it at a tuple that survives.
7. **`zig build` does not rebuild the smoke harness**, and **a host loads what is installed**. Both have cost this project time before.
8. **Do not widen `checkResolve`'s tolerance pre-emptively.** One 8-bit level is `3.0e-4` of linear signal in the sRGB toe. Run it, read the number the harness prints, then decide.
9. **The longer trail will read as a defect and is not one.** 31 frames to 54 is a consequence of the toe, and the response is to move `decay_per_frame`, which this curve makes free. Do not reach for the exposure or the white point to fix a persistence problem.
10. **A hue excursion on the way up is the one symptom that means the design is wrong** rather than mistuned. Watch a resize: green through to white, with no cyan and no yellow.
