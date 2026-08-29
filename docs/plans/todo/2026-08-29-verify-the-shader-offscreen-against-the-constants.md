# Verify the shader offscreen against the constants

Issue [#51](https://github.com/cboone/fosforo/issues/51). Branch `test/verify-shaders`.

## Context

`TraceUniforms` exists twice, in Zig and in MSL, and nothing links the two beyond a layout test. The layout test catches a field added or reordered; it cannot catch an arithmetic one. A shader that applied `trace_full_scale` twice, swapped it with `trace_rail`, or divided x by `sample_count` instead of `sample_count - 1` draws a plausible trace at the wrong scale and passes every check this project has: 160 unit tests, `validate-shaders`, both smoke halves, `smoke-leaks`, `clap-validator` and the Metal validation layer. The mapping itself is asserted by prose in ADR 0017 and by nothing executable.

That gap has already cost something. #55 shipped a resolve gain of `1 - decay` that divided every moving trace by ten and rendered a 100 Hz sine as a black display. It passed all of the above and was found by eye in under a minute. ADR 0013's #55 amendment records the conclusion: "The harness answers whether frames are presented and whether resources balance; it has never answered what the pixels became, and #51 remains the issue that would change that."

Phase 3 is when it stops being optional. #58 makes brightness a function of screen-space segment length, which is exactly the kind of relationship that looks plausible while being wrong, and there is no way to measure it at all today. `scripts/measure-trace` is the only instrument that reads a picture, and it needs a host, a screenshot, a crop, a colour-space conversion and a human.

**The outcome:** `zig build smoke-trace`, a third smoke half needing a Metal device and no window, required in CI beside `smoke-gpu`, that renders the shipping pipeline into a texture it owns and asserts what the pixels became.

## Why this is not the readback ADR 0013 refused

ADR 0013:85 refuses two things, and this is neither.

It refuses **reading the drawable back**, because `attachLayer` sets `setFramebufferOnly: true` and relaxing that would change the shipping renderer's storage mode in every host on every frame. Nothing here touches the layer, the drawable or that flag.

It refuses **a harness-only readable path**, on the grounds that "a path the shipping renderer never takes is a paraphrase." The answer is to make the offscreen path a *variant of the shipping path* chosen at construction, not a copy of it: the harness calls the real `upload` and the real `frame`, and `frame` differs only in where it gets its colour attachment and whether it presents. That is `probe`'s principle (share `buildPipelines` rather than paraphrase it) applied to the frame instead of to the pipeline.

ADR 0013:87 sets the criterion for a golden: "when the picture is expensive enough to justify a golden and stable enough that the golden does not churn." This builds **no golden**. It asserts extracted features against values computed from `iface.trace_full_scale` and `iface.trace_rail`, which is what the throwaway #38 probe actually did, and what survives #57, #58 and #60 with changed expected numbers rather than a rewritten instrument.

## Design

### The seam: two new operations

`src/gpu/iface.zig` gains two entries in the comptime signature block, taking it from eight operations to ten. Both are defended in prose the way `probe` is, as real backend capabilities rather than hooks: "render one frame into a surface this backend owns" and "hand the pixels back" are questions any second backend would have to answer, and neither names a Metal type.

```zig
assertSignature("initOffscreen", @TypeOf(Renderer.initOffscreen), fn (Size, *Diagnostics) Error!Renderer);
assertSignature("readback", @TypeOf(Renderer.readback), fn (*Renderer, Readback) Error!void);
```

`initOffscreen` takes its `Size` in **whole backing pixels**, not points, and that is the one honest difference from `init`: there is no view whose `backingScaleFactor` could be read, and inventing a scale would put `backingPixels`' rounding between the caller and the geometry it is asserting about. `backingPixels` already has five unit tests; nothing is lost.

Two new declarations:

```zig
/// Where an offscreen render's pixels land. Plain scalars, in this file's own
/// vocabulary: nothing here names a texture or a pixel format.
pub const Readback = struct {
    /// Linear RGBA from the accumulation, four floats per pixel, row-major.
    energy: []f32,
    /// The resolved picture, four bytes per pixel, RGBA. The backend swizzles
    /// out of the drawable's own component order so this file need not name it.
    picture: []u8,
};
```

and one `Error` member, `SurfaceNotReadable`, for `readback` called on a layer-backed renderer. That is a real condition rather than a programming error: a drawable is `framebufferOnly` by design, so there is genuinely nothing to read, and the seam refusing is what keeps the shipping renderer unchanged.

Both slices are copied into with `@min(needed, out.len)` on `upload`'s stated precedent, so a wrong size is a short read rather than an overrun. The caller sizes them from the `Size` it passed in and cannot be wrong.

### The backend

`src/gpu/metal/renderer.zig`:

- Replace the `layer: objc.Object` field with `surface: Surface`, a two-case union of `layer: objc.Object` and `target: objc.Object` (an owned `BGRA8Unorm` texture with `MTLStorageModeShared`, so `getBytes` needs no blit).
- Both constructors share one `acquire`, which takes the device, queue, pipelines, semaphore, window buffers and accumulation in the order `init` has always taken them, and hands them back as an `Acquired` the caller assembles. A separate struct rather than a partly-filled `Renderer`, because a union has no placeholder and inventing one would put a state in the type that no renderer is ever in. `init` then attaches a layer; `initOffscreen` builds a texture. That is the whole difference.
- `frame` changes at **three points and nowhere else**: acquiring the colour attachment (`nextDrawable`, which may yield `.no_drawable`, versus the owned texture, which cannot), the `setTexture:` on the resolve attachment, and `presentDrawable:` becoming conditional. Everything under test — pipelines, bindings, uniforms, draw calls, attachment formats, ping-pong, semaphore, slot discipline — is untouched and shared.
- `resize` switches: `applyLayerGeometry` for the layer case, `replaceTarget` for the other, then the existing accumulation reallocation for both. `replaceTarget` takes the new texture before releasing the old and abandons the resize if that fails, which is the opposite of `replaceAccumulation`'s order and deliberately so: `frame` has an outcome for an absent accumulation and none for an absent surface, and a target out of step with the accumulation is a fragment reading past the end of a texture rather than a dropped frame.
- `deinit` releases whichever the union holds.
- `readback` blits `accum[accum_source]` (the half the last committed frame wrote) into a shared `MTLBuffer`, commits, and `waitUntilCompleted`. Because one queue completes its buffers in order, that wait is also what guarantees every earlier frame finished. Then the buffer's `contents` is read directly as `f16` and widened into `energy`, and `getBytes` copies the offscreen target into `picture`, swizzled to RGBA.

**A buffer rather than a second texture**, which is what keeps the read allocation-free on this side: `contents` is a mapped pointer, so the half-floats widen straight into the caller's slice. Blitting texture-to-texture would leave `getBytes` needing a destination this file has no allocator to provide.

The blit is a readback mechanism, not a rendering path: it changes nothing about what was drawn, and it is why the accumulation keeps `MTLStorageModePrivate` in both cases rather than the offscreen renderer quietly allocating a different resource from the shipping one.

### The analyser, which is pure and belongs in `zig build test`

New `src/gpu/measure.zig`, importing only `std` and `iface.zig`. No Metal, no GPU, no I/O. It holds the window generators, the feature extraction and the expected-value arithmetic:

| Function                      | What it answers                                                           |
| ----------------------------- | ------------------------------------------------------------------------- |
| `litRows(image, threshold)`   | topmost and bottommost lit row per column, or none                        |
| `impliedSample(row, height)`  | the sample a row implies, inverting the documented mapping                |
| `expectedRow(sample, height)` | the row a sample should land on, from `trace_full_scale` and `trace_rail` |
| `pixelTolerance(height)`      | one backing pixel expressed as a sample value                             |
| `railRow(height)`             | where `trace_rail` puts the clamp                                         |
| `peakCount(image, threshold)` | local maxima in the top-row series, counted under strict equality         |
| `plateauWidth(image)`         | columns sharing the extreme row                                           |
| `constant`, `ramp`, `sine`    | the windows the cases feed in                                             |

**This module is where #38's one methodological finding gets a permanent guard.** That issue's first period counter counted upward zero crossings against the centre row using the topmost lit pixel per column; a steep segment crossing the centre lights every row it spans, so every tone came back exactly one period low, and a ±1 tolerance called all six "ok". `measure.zig`'s unit tests synthesize images in plain Zig, including the steep-crossing case, and assert `peakCount` exactly. The analyser being untested is how the analysis was wrong last time.

### The harness half

`src/smoke.zig` gains a `trace` subcommand beside `gpu` and `appkit`, dispatched by the same `std.mem.eql` chain, reported through the same `report`/exit-code discipline, and narrating through the same `say`.

`initOffscreen` and `readback` assert the main thread; `upload` and `frame` assert **not** the main thread. So each case runs its frame loop on a spawned `std.Thread` and joins, which is the shipping arrangement rather than a workaround for it.

```zig
var r = try gpu.Renderer.initOffscreen(.{ .width = 960, .height = 540 }, &diags);
defer r.deinit();
const t = try std.Thread.spawn(.{}, driveFrames, .{ &r, window, frames });
t.join();
try r.readback(.{ .energy = energy, .picture = picture });
```

`driveFrames` uploads the window, calls `frame`, and for the decay cases uploads an empty slice before the remaining frames, which sets `window_len` to zero so `traceVertices` returns null and the trace draw is skipped. That is the shipping behaviour for a plugin the host has not activated, reused rather than simulated.

Geometry is 960x540 throughout, so every number is directly comparable to the table #38 published.

### Build and CI

`build.zig` reuses `addSmokeHalf(b, exe, install, "trace")` verbatim; only the description template widens, since "the trace half of the GUI smoke harness" is no longer a GUI claim. The `smoke` aggregate step gains the third half and its description follows.

CI adds a fourth step to the `smoke` job, ungated like `smoke-gpu`:

```yaml
- name: Verify the shader draws what the constants say
  run: zig build smoke-trace
```

That job deliberately has no Metal toolchain, which is what keeps runtime compilation honest, and this step needs none. Its `timeout-minutes: 8` is documented as 4x a measured 58 s max over 10 runs; measure the new step locally and over the first CI runs and update that figure and its comment with real data rather than assuming it fits. This is a required step and adds nothing to the labelled step-timeout budget the job header tracks, so #69's contention for that margin is unaffected.

## The assertions

Every tolerance below is stated with the error it must not absorb, because "a tolerance wide enough to absorb a systematic error is a tolerance that hides one." One backing pixel at H=540 is a sample value of `1 / (0.9 * 270)`, or 0.0041; the errors being hunted are one to three orders of magnitude larger.

| #   | Case                                    | Assertion                                                                     | Tolerance     |
| --- | --------------------------------------- | ----------------------------------------------------------------------------- | ------------- |
| 1   | Silence, 960 zeros                      | every column lit, one row per column, implied sample is zero                  | 1 px          |
| 2   | Levels 0.5, 1.0, 1.05 and the negatives | implied sample matches `clamp(v * full_scale, ±rail) / full_scale`            | 1 px          |
| 3   | Levels 1.089, 1.111, 2.0, 8.0           | **identical row**, equal to `railRow`                                         | none, exact   |
| 4   | ±0.5 compared                           | equal distance from the centre row, opposite sides                            | 1 px          |
| 5   | 3 samples, `[-1, 0, +1]`                | lit columns span the full width; column 0 is the bottom, column 959 the top   | none, exact   |
| 6   | Sines of 1, 2, 4, 5, 8, 20 cycles       | `peakCount` equals the cycle count, and 2 → 4 → 8 as a ratio                  | none, exact   |
| 7   | Any lit accumulation pixel              | `(r, b)` are `(0.30, 0.45)` times `g`, the colour ray `measure-trace` assumes | 1e-3 relative |
| 8   | Every pixel, both readbacks             | `picture == round(255 * min(1, background + energy))`                         | ±1 byte level |
| 9   | Any unlit pixel                         | `picture` is exactly `RGBA(5, 5, 8, 255)`                                     | none, exact   |
| 10  | 1 deposit frame then k=1..4 quiet ones  | peak energy is `decay_per_frame ^ k`                                          | 1% relative   |

Case 3 is ADR 0017's saturation claim, and it needs no rasterization model at all: four different inputs must produce one output. Case 5 is the sharp probe for the horizontal mapping, because with `sample_count` as the divisor instead of `sample_count - 1` a three-sample window ends at column 640 and leaves 320 columns dark. Case 8 compares the two readbacks against each other, so it assumes nothing about how many segments covered a pixel, and it is what would have caught #55.

The harness also **reports** the maximum energy per pixel rather than asserting it, because whether a line strip's shared vertices deposit twice under Metal's diamond-exit rule is not documented anywhere this project can cite. That number is a finding to record, not a claim to make in advance.

### What it measured

The rows are #38's table, from an instrument sharing nothing with the throwaway Objective-C probe that produced it:

| Sample   | Measured row | Implied sample | #38's row |
| -------- | ------------ | -------------- | --------- |
| `0.000`  | 269          | +0.00206       | 269       |
| `+0.500` | 148          | +0.50000       | 148       |
| `+1.000` | 26           | +1.00206       | 26        |
| `+1.050` | 14           | +1.05144       | 14        |
| `-1.000` | 512          | -0.99794       | 512       |

Sines at 1, 2, 4, 5, 8 and 20 cycles counted exactly, the rail held row 5 for every level from 1.111 to 1000.0, and the background reached the picture as `RGBA(5, 5, 8, 255)`, which is the value `find_drawable` searches a window capture for.

**One deposit peaks at exactly 1.0000.** That answers the open question this plan declined to prejudge: a line strip's shared vertices do *not* deposit twice, so coverage is counted once per pixel at this geometry. It is a measurement at one geometry rather than a general claim about the rasterizer, and #57 replaces the primitive it is about.

The beam's ray measured red/green 0.2998 and blue/green 0.4500 against literals of 0.30 and 0.45, with a worst deviation of 0.00000 across every lit pixel: half-float precision, and the first executable confirmation of the premise `scripts/measure-trace`'s colour guard rests on.

## Verification

The harness's own correctness is established by planting defects and confirming each fails a *named* assertion. **All ten were planted and all ten were caught**, measured rather than predicted:

| Planted defect                                            | Error returned         | What the harness printed                   |
| --------------------------------------------------------- | ---------------------- | ------------------------------------------ |
| Swap `full_scale` and `rail` in `trace_vertex`            | `LevelMisplaced`       | 0.250 read as 0.27366, off by 0.02366      |
| Apply `full_scale` twice                                  | `LevelMisplaced`       | 0.250 read as 0.22428, off by 0.02572      |
| Divide x by `sample_count` rather than `sample_count - 1` | `TraceNotDrawn`        | silence lit 959 of 960 columns             |
| The same, with the silence check relaxed by one column    | `TraceEndsEarly`       | three samples span columns 0 to 639 of 959 |
| Negate y                                                  | `LevelMisplaced`       | 0.250 read as -0.24897, off by 0.49897     |
| The same, with the level and rail checks skipped          | `TraceInverted`        | +0.5 sits -121.5 above centre              |
| Drop the `clamp`                                          | `RailMisplaced`        | rail on row 0, expected 4.9                |
| A beam colour that varies across the fragment             | `BeamNotOneColour`     | worst ray deviation 0.28152                |
| Reorder the background literal's channels                 | `BackgroundNotNeutral` | background RGBA(8, 5, 5, 255)              |
| Reinstate #55's `1 - decay` resolve gain                  | `ResolveNotAnAdd`      | worst channel off by -224                  |
| `decay_per_frame` of 1.0                                  | `DecayWrong`           | 1.0000 of the deposit, expected 0.9000     |
| Bind `target` rather than `source` to the decay pass      | `DecayWrong`           | 0.0000 of the deposit, expected 0.9000     |

Three things fell out of doing this rather than predicting it.

**The wrong divisor is caught twice, and the broad net fires first.** At a full window it costs one column, which the silence check sees as 959 of 960; the three-sample probe is what makes the error 320 columns wide, and it had to be reached by relaxing the first check. Both are worth keeping: the second is the one that would still be decisive if Metal's diamond-exit rule ever made a one-column deficit ambiguous.

**Binding the wrong accumulation texture does not compile.** Zig's unused-local rule catches it before any harness runs, which is a better outcome than a caught defect and worth recording as the reason that row needed `_ = &source;` to be exercised at all.

**A uniform change to the beam's colour is invisible to the ray check, by construction.** The check takes its reference from the brightest lit pixel rather than from a restated literal, so it asserts that every deposit is the *same* colour and says nothing about which. That is the premise `scripts/measure-trace`'s guard rests on and had never been checked; pinning the literal here would be a fourth copy with nothing tying it back.

Then, in order:

```bash
zig fmt --check build.zig src/
zig build test                # measure.zig's own tests, plus the existing suite
zig build validate-shaders
zig build smoke-gpu           # unchanged, and the control that the seam still builds
zig build smoke-trace         # the new half
zig build smoke-appkit        # the shipping frame path, which this change touched
zig build smoke-leaks         # liveWindowBuffers and liveAccumulationTextures still balance
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert zig-out/bin/fosforo-smoke trace
typos && ruff format --check . && ruff check .
```

`smoke-appkit` and `smoke-leaks` matter more than usual here: `frame`, `resize` and `deinit` all changed, and those two are the only checks in the harness that run the layer-backed path.

### In a host, which is what the offscreen half does not replace

`frame` was edited, so a real drawable had to be measured rather than reasoned about. #22 landed while this branch was in flight and made that cheap: `clap-host` takes an explicit path, so no install, no folder juggling and no contention.

```bash
~/Development/clap-host/builds/ninja-system/host/Debug/clap-host -p "$PWD/zig-out/Fosforo.clap"
```

Its log settles provenance without a hash comparison, which is #22's whole point: `fosforo-build: version=0.0.0 branch=test/verify-shaders commit=5ca27c6`. It then rendered at **60.0 Hz into a 960x540 drawable at 2.00x, 3912 windows uploaded and 0 torn**, so the layer-backed path is intact through the `Surface` union.

**Then measured, not looked at.** A full-screen capture was **refused** by `scripts/measure-trace`, at 61.9% of pixels off the colour ray: this display is scaled, so a screen-sized capture resamples the drawable. That is the guard #64 built doing exactly its job, and it is a positive control for everything below. Capturing the window by its `CGWindowID` instead gives a lossless 1920x1080 drawable at **0.02% off the ray**, three orders of magnitude better, which is the margin that guard was calibrated to.

| Reading            | Measured                          | Expected                                       |
| ------------------ | --------------------------------- | ---------------------------------------------- |
| Drawable           | 1920 x 1080                       | 960x540 at 2x, as the render meter reported    |
| Columns lit        | 1920 of 1920                      | silence draws full width                       |
| Row                | 539, top and bottom               | one row, one pixel above an even centre        |
| Implied sample     | +0.0021                           | the one-pixel floor, about -53.7 dBFS          |
| Off the colour ray | 0.02%                             | under the 0.5% the guard permits               |

**Row 539 is the number that matters**, because it is the one AGENTS.md already records from REAPER at this geometry, from before any of this work: silence lands one pixel above centre because an even height puts the centre on an exact pixel boundary. The shipping path after the `Surface` union reproduces it exactly, measured by an instrument that shares no code with the new harness.

The two instruments also agree across geometries. Offscreen at 960x540 the harness reads row 269 implying +0.00206; in a host at 1920x1080 `measure-trace` reads row 539 implying +0.0021. Both are one pixel above centre, from different code, different pixel formats and different colour spaces.

**What was not done, and is not blocked.** Playing a sine through REAPER would additionally exercise the ring, the audio thread tap and the window read, none of which this branch touches, and it needs the installed bundle moved aside first because `CLAP_PATH` is additive. `clap-host` feeds no signal, so everything above is measured against silence.

Two negative controls, since an absence has to be told apart from an instrument that did not run. Confirm `smoke-trace` **passes** on the unmodified shader before planting anything, and confirm each planted defect is caught by the assertion named above rather than by a different one.

## Files

| File                                                                  | Change                                                                                         |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `src/gpu/iface.zig`                                                   | `Readback`, `Error.SurfaceNotReadable`, two `assertSignature` lines, the prose op count        |
| `src/gpu/metal/renderer.zig`                                          | `Surface` union, `initOffscreen`, `readback`, three branches in `frame`, `resize` and `deinit` |
| `src/gpu/measure.zig`                                                 | new; pure analysis and window generators, with its own tests                                   |
| `src/smoke.zig`                                                       | the `trace` half, its case table, `usage`                                                      |
| `build.zig`                                                           | `smoke-trace` through the existing `addSmokeHalf`                                              |
| `.github/workflows/ci.yml`                                            | the fourth `smoke` step, and a re-measured `timeout-minutes` comment                           |
| `docs/adr/0013-gui-smoke-harness-as-a-build-step.md`                  | a #51 amendment: what was built, and why it is not the refused readback                        |
| `AGENTS.md`, `CONTRIBUTING.md`, `README.md`                           | the command block, the smoke bullet, the CI gating paragraph                                   |
| `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md` | #51 recorded as landed, and the verification table's GUI row                                   |

Commits follow the boundaries above: the seam and backend first, then `measure.zig` with its tests, then the harness half, then build and CI, then docs. Conventional Commits, each referencing `(#51)`.

## Out of scope

- **A golden image.** ADR 0013's criterion is not met and features are what survive #57, #58 and #60.
- **Retiring `scripts/measure-trace`.** It reads a host's screenshot, which is a different question from what the shader computed, and #38's host procedure still depends on it. Note in passing that it inverts the mapping without the half-pixel centre term `measure.zig` uses; both are inside one pixel and reconciling them is not this issue's work.
- **Asserting #58's velocity weighting or #60's tonemap.** Neither exists. This issue is what makes them measurable when they do.
- **Promoting `smoke-appkit` out of `continue-on-error`.** That is #72.
