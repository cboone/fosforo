# Weight the beam by inverse screen-space velocity

Closes [#58](https://github.com/cboone/fosforo/issues/58). Phase 3, step 5.

## Context

[ADR 0007](../../adr/0007-renderer-simulates-a-crt.md) calls this "the single relationship" that produces the phosphor look, and the build plan calls it the step where the render stops looking like a plot. The beam sweeps at a constant _time_ rate and covers a varying _screen_ distance, so where the signal moves slowly the beam dwells and deposits a lot of energy per pixel, and where it moves fast the same energy is smeared over hundreds of pixels. That is what an electron beam and a phosphor physically do, and it costs a division.

Everything it waits on has landed. [#57](https://github.com/cboone/fosforo/issues/57) made each inter-sample segment an oriented quad shaded by distance from the segment, so there are segments to weight and `trace_vertex` already computes their screen length. [#60](https://github.com/cboone/fosforo/issues/60) put a tonemap and a palette in the resolve, so accumulated energy past 1.0 is legible rather than clipped. [#51](https://github.com/cboone/fosforo/issues/51) built `zig build smoke-trace`, which is the only instrument that can measure a _relationship_ rather than a picture, and which was pulled forward on exactly this argument: "it looks like a scope" cannot tell `1/length` from `1/sqrt(length)` from a constant with a lucky palette.

Two things ride on it. [ADR 0019](../../adr/0019-brightness-is-a-fixed-transfer-function.md) holds `white_headroom` at 0.8 marked **provisional**, because a 2:1 dwell range is too narrow for any white point to carve a core out of, and hands the re-judgement here. And [#79](https://github.com/cboone/fosforo/issues/79), the bright vertical line a transport stop draws, is expected to close as _covered_ rather than fixed, because a segment spanning hundreds of rows is precisely what this relationship makes dim by construction.

No new ADR. ADR 0007 already specifies this as a consequence; this executes it and resolves ADR 0019's provisional constant.

## Design

### The weight

One expression in `trace_fragment`, multiplied into the deposit beside `density`:

```metal
const float w = beam.half_width_px / (beam.half_width_px + in.length);
return float4(falloff * falloff * beam.density * w);
```

`in.length` is a new `[[flat]]` member of `TraceOut`, assigned from the `len` that `trace_vertex` already computes in window space at line 334. Flat rather than interpolated for the reason `p0` and `p1` already carry: all four corners compute the same value.

**The constant is derived, not chosen.** A capsule's integral of the biweight is `(16/15)·h·len` along its length plus `(π/3)·h²` for the two caps, so the weight that makes a segment's _total_ deposited energy independent of its length is `1 / (1 + 1.019·len/h)`. `h / (h + len)` is that, to within 2% across the whole range. Two consequences that make this the form rather than an approximation of it:

- **The floor the issue asks for is answered by construction.** The denominator is `h + len ≥ h > 0`, so there is no division by zero to guard and no epsilon to justify. The floor's real job is physical, not numerical: below the beam's own width, moving stops reducing a pixel's dwell, and this form handles that smoothly rather than with a kink.
- **It improves sample-rate stability**, which `density` alone leaves imperfect. Per-pixel energy for a flat trace goes 1.56 at 48 kHz against 1.58 at 192 kHz, where today it is 2.6 against 1.85.

Screen space, not signal space: `len` is measured after `to_window`, in backing pixels, so the weight responds to the drawable's geometry rather than to sample values.

### What it is not

**`TraceUniforms.density` is untouched.** That is one number per frame from the window length and the drawable width, correcting the joint overlap #57 measured, and it depends on nothing about the signal. This term is per segment and depends on exactly that. Collapsing them would make brightness track the sample rate again. `density` is the time a segment represents; this is one over the distance it covers.

**No new uniform, so no binding moves.** `half_width_px` is already in `TraceUniforms` and is the only length constant the weight needs. `TraceUniforms` keeps its 28-byte layout, its offsets, its `from_the_seam` split and its three binding indices, so the layout test, the defaults test and `bindingIndexAfter`'s seven assertions are all unchanged. The build plan's note that "#58 moves bindings again if velocity weighting adds a uniform" resolves as: it does not. `src/gpu/iface.zig` is unchanged too, so the seam's `[]const f32` claim survives a third issue.

### The harness's lit threshold has to become relative

`trace_threshold` is a fixed 0.5 energy, which works today only because every deposit peaks near 1.0. After this change one frame spans two orders of magnitude and a fixed energy stops being an iso-intensity contour: it becomes an absolute brightness assertion smuggled into every geometry check. `checkHorizontalMapping` is where that bites hardest, because its 3-sample window makes every segment about 538 px long, so nothing in it clears 0.5 at all.

So `trace_threshold` becomes **0.5 of the frame's peak**, read through one helper, and a separate low absolute floor answers "was anything drawn":

```zig
fn litLevel(image: measure.Image) f32 {
    return trace_threshold * measure.maxChannel(image, 1);
}
```

Nothing that is actually asserted is lost. Absolute brightness is covered by `checkHotCore`, `checkResolve`, `checkDecay` and the new check, none of which read the threshold.

## Changes

### `shaders/scope.metal`

1. `TraceOut` gains `float length [[flat]];`, with the existing flat-versus-interpolated paragraph extended to cover it.
2. `trace_vertex` sets `out.length = len;`. Nothing else in that function moves.
3. `trace_fragment` multiplies the deposit by the weight, with a paragraph beside `density`'s stating the derivation, the two asymptotics, and why the two terms are separate.
4. `white_headroom`'s "provisional at 0.8" paragraph is rewritten to whatever the host session settles (see Verification).
5. `tonemap`'s domain paragraph: the attainable domain is re-derived, and the stale "a line strip's x is monotone in `vertex_id`" premise, which #57 retired everywhere else, goes with it.

### `src/gpu/measure.zig`

Pure, no GPU, tested at the foot of the file, on `beamDensity`'s precedent that the property worth asserting should not need a device.

| Addition                                   | What it is                                                                                                               |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| `beamWeight(len_px, half_width_px) f32`    | The model of the shader's term, so the harness states expectations through it rather than restating the formula          |
| `segmentEnergy(len_px, half_width_px) f32` | The closed form `beamWeight * ((16/15)·h·len + (π/3)·h²)`, which is the invariant under test                             |
| `rowEnergy(image, y) f32`                  | Sums green across one row. `checkBeamProfile` sums inline today because no helper exists; both callers use this          |
| `totalEnergy(image) f32`                   | Sums green over the whole image                                                                                          |
| `alternating(out, amplitude)`              | Window builder beside `constant`, `ramp` and `sine`: every sample flips sign, so every segment has the same known length |

Tests: `beamWeight` is 1 at zero length, monotone decreasing, asymptotically proportional to `1/len`, and never negative or NaN; `segmentEnergy` varies by under 2% across the whole length range, which is the property the whole issue rests on; `alternating` and the two sums against hand-built images.

### `src/smoke.zig`

1. `trace_threshold`'s docstring restated as a fraction; new `trace_drawn: f32 = 1e-4` absolute floor; new `litLevel` helper; every call site that passed `trace_threshold` to `measure` passes `litLevel(image)` instead, and every `TraceNotDrawn` guard compares against `trace_drawn`.
2. `checkBeamProfile`'s expectation gains the weight: `beam_half_width_px * 16/15 * measure.beamWeight(len, beam_half_width_px)`, with `len` computed from `measure.expectedRow` on ±0.9 and the segment pitch. It stays a statement about the biweight and becomes a plant detector for the weight as well.
3. **New `checkVelocityWeighting`**, added to `traceHalf`'s call list after `checkBeamProfile`. Two arms, and the pairing is the point.

**Arm 1, per unit length.** Three isolated rods: a window that steps from `+a` to `-a` at its midpoint, at `a` of 0.05, 0.2 and 0.9, so one segment crosses the middle row and its neighbours are the flat runs far above and below. `rowEnergy` at row 270 is the cross-section integral, which is the deposit _per unit length_, and it must equal `(16/15)·h·beamWeight(len)`. This is the issue's own sentence made executable.

| `a`  | segment length | predicted weight | predicted cross-section |
| ---- | -------------- | ---------------- | ----------------------- |
| 0.05 | 24.32          | 0.05809          | 0.09294                 |
| 0.20 | 97.21          | 0.01520          | 0.02431                 |
| 0.90 | 437.40         | 0.003418         | 0.005469                |

**Arm 2, total energy is invariant to slope and to sample density.** Four slopes crossed with two window lengths, eight probes, one assertion. Total accumulated energy must agree across all eight within 5%, and match `instances * density * segmentEnergy(len)` within 10%. Unweighted, the four slopes alone span a factor of **197**.

| window | slope             | pitch | segment length | predicted total |
| ------ | ----------------- | ----- | -------------- | --------------- |
| 960    | flat              | 1.001 | 1.001          | 2277            |
| 960    | alternating ±0.05 | 1.001 | 24.32          | 2300            |
| 960    | alternating ±0.45 | 1.001 | 218.70         | 2302            |
| 960    | alternating ±1.0  | 1.001 | 486.00         | 2302            |
| 3840   | the same four     | 0.250 | as above       | 2267 to 2303    |

The 3840-sample arms are what no other check here reaches: they drive `density` to 0.25 while the slopes drive the weight, and the totals still agreeing is the executable form of "these are two terms with different domains". The window is a stack array in the check, on `checkHorizontalMapping`'s precedent.

The error is `error.DepositNotVelocityWeighted`, one name phrased as the false claim, and every measured number prints before it returns.

### `src/gpu/metal/renderer.zig`

Docstrings only, no code. `TraceUniforms.density` and `beamDensity` both carry a "not velocity weighting, which is #58's" contrast written in the future tense; both are restated against the term that now exists, including the resize finding below.

### Prose that quotes numbers this moves

`src/gpu/palette.zig` (`white_headroom`, and `tonemap`'s stale line-strip premise), [ADR 0007](../../adr/0007-renderer-simulates-a-crt.md)'s amendment, [ADR 0019](../../adr/0019-brightness-is-a-fixed-transfer-function.md)'s provisional-headroom section, and `CLAUDE.md`'s current-state paragraph plus the gotchas quoting 2.6133 and the transport-stop line. `scripts/measure-trace` restates `white_headroom` and is tied back by a test that reads the script as text, so it moves **only if** the host session changes that constant.

## Verification

### Offscreen, in this order

```bash
zig build test
zig build validate-shaders
zig build smoke-trace
zig build smoke-gpu
zig fmt --check build.zig src/
```

`zig build test` first, because the `measure.zig` model has to be right before anything is measured against it, and `segmentEnergy` varying by under 2% is the whole premise. `validate-shaders` will not catch a pipeline that cannot link with the new `TraceOut` member; `smoke-gpu` is what does.

**The acceptance test is arm 2 of `checkVelocityWeighting`**: eight probes whose segment lengths span a factor of 486 and whose sample densities differ fourfold, agreeing on total deposited energy within 5%. Nothing else in this project can state the relationship this issue is about, and by-eye verification of a relationship is how plausible-looking wrong code survives.

Then `zig build smoke-appkit`, `smoke-leaks -Dleak-cycles=40`, and by hand `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert zig-out/bin/fosforo-smoke appkit 3`. No format, texture or attachment changed, so the layer is cheap insurance rather than a real risk. Run a smoke step first: `zig build` does not rebuild the harness.

### Numbers to record rather than predict

1. **`checkDecay`'s one-deposit peak**, which is 2.6133 today and should land near **1.57**. That number is what re-anchors every energy figure in this repository.
2. **`checkResolve`'s worst channel off by N.** It was 0 before #57 and 1 after, because more pixels landed in the sRGB toe. More land there now, so 2 is plausible; widen the tolerance only with the measurement recorded, on #60's rule.
3. **`checkHotCore`'s one-deposit bytes and tint gaps.** Predicted around green 206, comfortably over the bound of 128, with the gradient barely started toward white.
4. **Whether the eight totals agree within 5% or need more.** Half-float precision and the cap integral are the two contributors, and the tolerance should be set from the printed spread rather than from a failing run.

### In a host, and one arm of it is expected to disappoint

```bash
zig build install-clap
/Applications/REAPER.app/Contents/MacOS/REAPER 2>&1 | grep --line-buffered fosforo
```

Provenance first, capture with `screencapture -o -x -t png -W`, read every capture with `scripts/measure-trace --explain --refresh 120`, and verify at 48 kHz.

**Arm 1, the material that shows the range, and it is not the 100 Hz sine.** Every figure ADR 0019 and the issue's own comment quote comes from `sine-100hz-0.5.wav`, and that signal's physical velocity ratio is **1.88:1**: at 1920 px over 20 ms the sweep runs at 96,000 px/s, and a 0.5 sine at 100 Hz reaches 152,681 px/s vertically, so its fastest crossing is only 1.88 times the speed of its turning point. **No velocity weighting can widen that**, because 1.88 is what the beam actually does. Today's measured 2.2-to-3.0 against roughly 1 _overstates_ it, because the joint overlap grows as `1/len` for shallow segments and saturates near 1 for steep ones. So expect the 100 Hz sine's range to come back near 2:1 and possibly slightly narrower than today, and **that is correct rather than a regression.** The order of magnitude is real and lives on higher-slope material: `sine-1000hz-0.5.wav` has a ratio of **15.9:1** on the same arithmetic, and `click-2hz.wav` is ADR 0007's own kick-and-click example. Judge the core on those two.

**Arm 2, `white_headroom`.** With the weight in, a dwelling pixel at 120 Hz converges on about 30 against a white point of 15.6, so the core arrives; a 1 kHz crossing tonemaps to about 0.083, which the sRGB toe puts at green 81 over a background of 5, so the dim end is dim rather than black. The prediction is that **0.8 survives unchanged** and stops being provisional. Turn it live with #61's hot reload while looking at `click-2hz.wav`, and if it does survive, drop "provisional" from the shader, `src/gpu/palette.zig`, ADR 0019 and the issue comment together.

**Arm 3, [#79](https://github.com/cboone/fosforo/issues/79).** Play any tone and stop the transport. The step to silence is a segment spanning hundreds of rows, so its weight is on the order of 0.003 against a signal's 1.5, roughly 500 times dimmer. If the line is no longer distracting, comment on #79 with the measurement and close it as **covered rather than fixed**, which is what its own body and the build plan both ask for. What survives afterwards is whether a deliberate discontinuity should be drawn at all, which is [#53](https://github.com/cboone/fosforo/issues/53)'s.

**Arm 4, resize.** Drag the editor from the default to its minimum during playback and record what happens to brightness. The prediction, and it is the finding this issue owes: **fast segments hold and slow ones halve**, because `density` is the segment pitch in _points_ and therefore cancels the velocity term's response to geometry. The physics says everything should get brighter. See Follow-ups.

**Arm 5, sample rate.** Change REAPER's device rate to 96 and 192 kHz and confirm the picture's brightness and contrast hold. The harness covers this offscreen through arm 2's 3840-sample probes, so this arm is about the ring, `windowSamples` and the upload path rather than about the weight.

Then `clap-validator`, `typos`, `markdownlint-cli2` (never `--fix`), `ruff format --check . && ruff check .` (the log must read **1** file), `shfmt -d` and `shellcheck` via `git ls-files`.

### What retunes, and what reverts

Written down in advance because at the keyboard every one of these reads as "the change is wrong".

| Symptom                                                     | Response                                                                                                                    |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| The 100 Hz sine's range did not widen                       | Expected. Judge on 1 kHz and the click; do not touch the weight                                                             |
| The whole picture is dimmer than before                     | Expected, by about 0.6 on slow material. Re-judge `white_headroom`, do not add a gain                                       |
| Fast crossings are invisible rather than dim                | Read the byte, not the eye. Below green 20 or so, suspect the weight; at 81 it is the design                                |
| Brightness tracks the signal's _level_                      | Not a defect, and ADR 0019 says so: a quieter sine moves fewer rows per sample and genuinely dwells                         |
| Brightness tracks the _frame's peak_                        | Stop. Something made the transfer function depend on the frame's contents, which ADR 0019 forbids without a superseding ADR |
| The totals in arm 2 disagree between the two window lengths | The two terms have been collapsed. Check that the weight reads `half_width_px` and never the pitch                          |

### Planted defects

Each planted on a passing run, committed first so `git restore` cannot revert the fix with the plant, and with an unconditional trigger.

| Plant                                                          | Must be caught by                                                                 |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| The weight dropped entirely (`w = 1.0`)                        | `checkVelocityWeighting` arm 2, whose totals then span 197x                       |
| `h / len` with the `h +` term removed                          | Arm 2's flat probe, 2.5x off, and nothing else; this is why the floor is asserted |
| `len` taken in clip space rather than window space             | Arm 1, since the aspect ratio makes the weight anisotropic                        |
| `length` declared interpolated rather than `[[flat]]`          | Arm 1's cross-sections, which then differ across a quad's diagonal                |
| The weight applied to `out.position` instead of the deposit    | `checkLevels` and `checkSilence`, on geometry rather than energy                  |
| The relative threshold reverted to an absolute 0.5             | `checkHorizontalMapping`, with `TraceNotDrawn`                                    |
| The weight computed from the pitch rather than `half_width_px` | Arm 2's 3840-sample probes, and **nothing else here**                             |

That last row is the point of the 3840-sample arms existing, and it is the gap #57 hit from the other side: the harness runs at scale 1.0 and could not see a density term that tracked the backing scale, so `beamDensity`'s properties had to be asserted without a GPU. Here the window length is something the harness _can_ vary, so the arm exists rather than the gap.

## Deliberately not done

- **`TraceUniforms.density` is not re-derived.** Arm 4 above records that its width dependence cancels this issue's response to a resize, and the physics says a narrower window should read brighter. Fixing it needs a reference geometry constant and changes brightness at every non-default editor size, which is a second relationship and reopens a correction #57 measured and settled. It becomes a follow-up issue with arm 4's measurement in it.
- **Bandlimited reconstruction**, [#59](https://github.com/cboone/fosforo/issues/59), which edits the same shader and goes behind this.
- **Min/max decimation**, [#62](https://github.com/cboone/fosforo/issues/62). Above 48 kHz the display still invents structure; verify at 48.
- **Narrowing the accumulation to `R16Float`.** The deposit is still a scalar in four channels and `checkDepositIsScalar` still asserts it, so three quarters remain dead weight. #59 may yet want per-channel data.
- **Reload-time binding validation**, [#77](https://github.com/cboone/fosforo/issues/77). This issue adds no uniform and moves no index, so it does not make that overdue issue any more urgent than #57 already did.

## Follow-ups

| What                                            | Where it goes                                                                                          |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `density`'s width dependence versus the physics | New issue, with arm 4's measurement                                                                    |
| #79 closes as covered                           | Comment with arm 3's measurement, then close                                                           |
| #83's toe measurement                           | Unblocked: it wanted the energy distribution this produces before measuring the banding that will ship |
| The build plan's phase 3 table and issue order  | `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`                                  |

## Commits

Grouped so each is reviewable on its own, all referencing `(#58)`:

1. `feat: weight each segment's deposit by its inverse screen length (#58)` -- the shader, plus the `measure.zig` model and its tests.
2. `test: make the harness's lit threshold a fraction of the frame's peak (#58)` -- `src/smoke.zig` call sites and `checkBeamProfile`'s expectation.
3. `test: assert the beam's deposit is invariant to slope and sample density (#58)` -- `checkVelocityWeighting`.
4. `docs: re-anchor the energy figures and settle the white point (#58)` -- ADRs, `CLAUDE.md`, the renderer's density docstrings, and `white_headroom` if the host session moves it.

---

## Results

Everything offscreen is done and green. **The host arm is outstanding**, and it is the only thing between here and closing the issue.

### Where the plan was wrong

**The lit threshold is derived from constants, not taken as a fraction of the frame's peak.** The fraction-of-peak policy was chosen and then falsified by `checkPeriods`. Velocity weighting correlates brightness with height, and `measure.periods` reads height: the trace is _moving_ where it crosses the half-amplitude band, so at two cycles it deposits 0.635 against a frame peak of 1.544, a contour at half the peak read it as dark, and the two runs fragmented into **eight**. The form that works is `trace_threshold * beamWeight(len, h)`, which restores the constant's original meaning exactly, since 0.5 was always half of what one segment deposits at its core. Recorded at the constant.

**The unweighted spread across the four slopes is 197, not 214.** Arithmetic slip in the plan; the test asserts against 190 and the figure is corrected everywhere.

**"Fast segments hold and slow ones halve" under resize was wrong in both halves.** Measured rather than predicted, below.

**`checkBeamProfile` catches more plants than predicted.** The plan expected the pitch-for-half-width confusion to be visible only to the dense-window arms; at 960 samples the pitch is 1.001 against a half-width of 1.5, so it fails the cross-section immediately.

### What the harness measures

| Measurement                                      | Result                                                               |
| ------------------------------------------------ | -------------------------------------------------------------------- |
| Total energy across 4 slopes x 2 densities       | spans **1.0094**, against 197 unweighted                             |
| Per unit length, 3 rods over an 18x length range | within **1.3%** of `beamWeight`, and biased low by a consistent 1.2% |
| `checkDecay` one deposit                         | **1.5674**, from 2.6133                                              |
| `checkBeamProfile` cross-section                 | **0.005400** against a predicted 0.005468                            |
| `checkResolve` worst channel                     | off by **-1**, unchanged from #57                                    |
| `checkHotCore` one deposit / thirty              | `RGB(102, 207, 119)` / `RGB(255, 255, 255)`                          |
| `smoke-leaks` at 40 cycles                       | 283 leaks, 18,560 bytes, inside the band                             |
| `clap-validator`                                 | 44 run, 21 passed, 0 failed, 0 warnings                              |

### The dwell range, which is the issue's real subject

Turning point against zero crossing, amplitude 0.5, measured offscreen with the weight planted out for the baseline. 100 Hz is 2 cycles in a 20 ms window and 1 kHz is 20.

| signal | before | after    |
| ------ | ------ | -------- |
| 100 Hz | 1.36   | **1.84** |
| 1 kHz  | 1.34   | **7.50** |

The order of magnitude the issue promised is real at 1 kHz and is not real at 100 Hz, and every figure the prediction rested on came from a 100 Hz sine. That signal's fastest crossing is 1.88 times the speed of its turning point, so nothing can widen it. **What changed is that the range now discriminates between signals**, where before both read about 1.35.

### Resize, the finding `density` owes

Peak energy on a flat trace and on a full-scale zigzag, one 960-sample window:

| drawable | flat  | fast   | contrast |
| -------- | ----- | ------ | -------- |
| 960x540  | 1.198 | 0.0136 | 88.1     |
| 480x540  | 1.193 | 0.0110 | 108.5    |
| 480x270  | 1.193 | 0.0219 | 54.5     |

A slow trace holds to 0.4% in both directions. A fast one dims by a fifth on a half-width editor and brightens by 1.61 on a half-size one, so the _contrast_ moves with the window by up to 1.6x where the physics says everything should simply double. Follow-up issue, not this one.

### Planted defects

| Plant                                                | Caught by                                                    |
| ---------------------------------------------------- | ------------------------------------------------------------ |
| The weight dropped (`velocity = 1.0`)                | `checkBeamProfile`, 1.5796 against 0.005468                  |
| `h / len`, the floor term removed                    | **only** arm 2, 5690.3 against 2276.4; arm 1 passes it       |
| `len` taken in clip space                            | `checkBeamProfile`, 0.7595                                   |
| `segment_length` derived per corner                  | `checkBeamProfile`, 0.3303, and the centroid moves to 479.99 |
| The weight applied to the geometry                   | `checkSilence`, 0 of 960 columns lit                         |
| The contour reverted to an absolute 0.5              | `checkHorizontalMapping`, `TraceNotDrawn`                    |
| The weight computed from the pitch                   | `checkBeamProfile`, 0.003607                                 |
| `segment_length` interpolated rather than `[[flat]]` | **nothing, and it is not a defect**                          |

The second row is why there are two arms rather than one: `h / len` is within 5% of the right answer for every long segment, so the per-unit-length arm passes it and only the conservation arm sees it.

The last row was planted expecting a catch and is a correction to the plan. A value equal at all four corners interpolates to itself, so `[[flat]]` here is a cost saving and a statement of intent rather than a correctness requirement. `TraceOut`'s existing comment is about _deriving_ per-corner values, which is the row above it and is caught.

### Outstanding

`white_headroom` is **settled**: judged in REAPER at 0.4 and 1.2 with no visible difference, which is arithmetic rather than eyesight, and the re-judgement moved to phase 4. See the commit and ADR 0019.

What remains is one host session. `smoke-trace` renders a window it supplied itself and says nothing about the audio path, the ring, the display link or the compositor.

```bash
zig build install-clap    # prints the hash and provenance of what landed, and of what it replaced
/Applications/REAPER.app/Contents/MacOS/REAPER 2>&1 | grep --line-buffered fosforo
```

Both `2>&1` and `--line-buffered` are required and each fails differently; see AGENTS.md. Verify at **48 kHz**, since above it the display aliases until [#62](https://github.com/cboone/fosforo/issues/62). Capture with `screencapture -o -x -t png -W verification/shot.png` and click the editor window, which is titled `CLAP: Fósforo (Catamount) - Track N` at about 960x593, not the project window. Read every capture with `scripts/measure-trace --explain --refresh 120`.

| #   | Arm                                                                    | Signal                                     | Pass criterion                                                                                                                                                         |
| --- | ---------------------------------------------------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **[#79](https://github.com/cboone/fosforo/issues/79), transport stop** | any tone, then stop                        | The bright vertical line is gone. Predicted green **15 to 30** against a background of 5 and a trace at 190. If so, close #79 as covered rather than fixed             |
| 2   | **The characteristic look**                                            | `sine-1000hz-0.5.wav`                      | A visible gradient along the trace: turning points at green **190**, crossings at **99**. This is what #58 was for and it is the one arm that should be obvious by eye |
| 3   | Resize during playback                                                 | any tone                                   | Brightness holds on slow parts and the fast parts change; the contrast moves by up to 1.6x. Subtle, and already measured offscreen, so confirmation only               |
| 4   | Level sweep                                                            | 1.000, 1.050, 1.089, 2.000                 | The implied sample tracks the level and then **stops**: +1.0000, +1.0500, +1.0889, +1.0889. Watching for a flat top is the wrong test (ADR 0017)                       |
| 5   | Sample rate                                                            | `sine-100hz-0.5.wav` at 48, 96 and 192 kHz | Peak still inverts to +0.5000 at every rate. Change REAPER's **device** rate, not the files. Exercises the ring and `windowSamples`, not the weight                    |

Arms 1 and 2 are the ones worth the session. Arms 3 to 5 are confirmation and regression.

Then the pre-PR sweep, all currently green:

```bash
zig build test && zig build validate-shaders && zig build smoke-gpu && zig build smoke-trace
zig build smoke-appkit && zig build smoke-leaks -Dleak-cycles=40
clap-validator validate zig-out/Fosforo.clap
zig fmt --check build.zig src/ && typos && markdownlint-cli2
uvx ruff format --check . && uvx ruff check .          # the log must read 1 file
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck
```

**Before quoting any number, put `white_headroom` and `palette_row` back to 0.8 and 0** and re-run `zig build test`. Each is tied to `src/gpu/palette.zig` by the constants test, so an experiment left in place fails CI, and a capture taken against an edited shader was measured against a mapping the model has never seen.
