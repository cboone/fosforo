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

- Replace the `layer: objc.Object` field with `surface: Surface`, a two-case union of `layer: objc.Object` and `offscreen: objc.Object` (an owned `BGRA8Unorm` texture with `MTLStorageModeShared`, so `getBytes` needs no blit).
- `initOffscreen` reuses `init`'s body wholesale: same `MTLCreateSystemDefaultDevice`, `newCommandQueue`, `buildPipelines`, `dispatch_semaphore_create`, `buildWindows`, `buildAccumulation`, same `errdefer` ladder. It differs in its last acquisition only, building the target texture where `init` calls `attachLayer`. Factor the shared prefix so the two cannot drift.
- `frame` changes at **three points and nowhere else**: acquiring the target texture (`nextDrawable`, which may yield `.no_drawable`, versus the owned texture, which cannot), the `setTexture:` on the resolve attachment, and `presentDrawable:` becoming conditional. Everything under test — pipelines, bindings, uniforms, draw calls, attachment formats, ping-pong, semaphore, slot discipline — is untouched and shared.
- `resize` switches: `applyLayerGeometry` for the layer case, rebuilding the offscreen texture for the other, then the existing accumulation reallocation for both.
- `deinit` releases whichever the union holds.
- `readback` builds a shared `RGBA16Float` staging texture, blits `accum[accum_source]` into it (the half the last committed frame wrote), commits, and `waitUntilCompleted`. Because one queue completes in order, that wait is also what guarantees every earlier frame finished. Then `getBytes` from the staging texture into `energy`, widening `f16` to `f32`, and from the offscreen target into `picture`, swizzling BGRA to RGBA.

The blit is a readback mechanism, not a rendering path: it changes nothing about what was drawn, and it is why the accumulation keeps `MTLStorageModePrivate` in both cases rather than the offscreen renderer quietly allocating a different resource from the shipping one.

### The analyser, which is pure and belongs in `zig build test`

New `src/gpu/measure.zig`, importing only `std` and `iface.zig`. No Metal, no GPU, no I/O. It holds the window generators, the feature extraction and the expected-value arithmetic:

| Function                        | What it answers                                                     |
| ------------------------------- | ------------------------------------------------------------------- |
| `litRows(image, threshold)`     | topmost and bottommost lit row per column, or none                  |
| `impliedSample(row, height)`    | the sample a row implies, inverting the documented mapping          |
| `expectedRow(sample, height)`   | the row a sample should land on, from `trace_full_scale` and `trace_rail` |
| `pixelTolerance(height)`        | one backing pixel expressed as a sample value                       |
| `railRow(height)`               | where `trace_rail` puts the clamp                                   |
| `peakCount(image, threshold)`   | local maxima in the top-row series, counted under strict equality   |
| `plateauWidth(image)`           | columns sharing the extreme row                                     |
| `constant`, `ramp`, `sine`      | the windows the cases feed in                                       |

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

| # | Case                                   | Assertion                                                                  | Tolerance      |
| - | -------------------------------------- | -------------------------------------------------------------------------- | -------------- |
| 1 | Silence, 960 zeros                     | every column lit, one row per column, implied sample is zero                 | 1 px           |
| 2 | Levels 0.5, 1.0, 1.05 and the negatives | implied sample matches `clamp(v * full_scale, ±rail) / full_scale`           | 1 px           |
| 3 | Levels 1.089, 1.111, 2.0, 8.0          | **identical row**, equal to `railRow`                                        | none, exact    |
| 4 | ±0.5 compared                          | equal distance from the centre row, opposite sides                           | 1 px           |
| 5 | 3 samples, `[-1, 0, +1]`               | lit columns span the full width; column 0 is the bottom, column 959 the top  | none, exact    |
| 6 | Sines of 1, 2, 4, 5, 8, 20 cycles      | `peakCount` equals the cycle count, and 2 → 4 → 8 as a ratio                 | none, exact    |
| 7 | Any lit accumulation pixel             | `(r, b)` are `(0.30, 0.45)` times `g`, the colour ray `measure-trace` assumes | 1e-3 relative  |
| 8 | Every pixel, both readbacks            | `picture == round(255 * min(1, background + energy))`                        | ±1 byte level  |
| 9 | Any unlit pixel                        | `picture` is exactly `RGBA(5, 5, 8, 255)`                                    | none, exact    |
| 10 | 1 deposit frame then k=1..4 quiet ones | peak energy is `decay_per_frame ^ k`                                         | 1% relative    |

Case 3 is ADR 0017's saturation claim, and it needs no rasterization model at all: four different inputs must produce one output. Case 5 is the sharp probe for the horizontal mapping, because with `sample_count` as the divisor instead of `sample_count - 1` a three-sample window ends at column 640 and leaves 320 columns dark. Case 8 compares the two readbacks against each other, so it assumes nothing about how many segments covered a pixel, and it is what would have caught #55.

The harness also **reports** the maximum energy per pixel rather than asserting it, because whether a line strip's shared vertices deposit twice under Metal's diamond-exit rule is not documented anywhere this project can cite. That number is a finding to record, not a claim to make in advance.

## Verification

The harness's own correctness is established by planting defects and confirming each fails a *named* assertion, not merely some assertion. Record the results in a table in this plan, on ADR 0013's precedent.

| Planted defect                                              | Expected failure  |
| ----------------------------------------------------------- | ----------------- |
| Swap `full_scale` and `rail` in `trace_vertex`               | case 2            |
| Apply `full_scale` twice                                     | case 2            |
| Divide x by `sample_count` rather than `sample_count - 1`    | case 5            |
| Negate y                                                     | case 4            |
| Drop the `clamp`                                             | case 3            |
| Change the beam colour literal                               | case 7            |
| Change the background literal                                | case 9            |
| Reinstate #55's `1 - decay` resolve gain                      | case 8            |
| `decay_per_frame` of 1.0                                     | case 10           |
| Bind `target` rather than `source` to the decay pass          | case 10           |

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

`smoke-appkit` and `smoke-leaks` matter more than usual here: `frame`, `resize` and `deinit` all changed, and those two are the only checks that run the layer-backed path. Finish in a host, because `frame` was edited: `zig build install-clap`, confirm the hashes match, and play a sine in REAPER.

Two negative controls, since an absence has to be told apart from an instrument that did not run. Confirm `smoke-trace` **passes** on the unmodified shader before planting anything, and confirm each planted defect is caught by the assertion named above rather than by a different one.

## Files

| File                                                          | Change                                                              |
| ------------------------------------------------------------- | ------------------------------------------------------------------- |
| `src/gpu/iface.zig`                                            | `Readback`, `Error.SurfaceNotReadable`, two `assertSignature` lines, the prose op count |
| `src/gpu/metal/renderer.zig`                                   | `Surface` union, `initOffscreen`, `readback`, three branches in `frame`, `resize` and `deinit` |
| `src/gpu/measure.zig`                                          | new; pure analysis and window generators, with its own tests        |
| `src/smoke.zig`                                                | the `trace` half, its case table, `usage`                           |
| `build.zig`                                                    | `smoke-trace` through the existing `addSmokeHalf`                   |
| `.github/workflows/ci.yml`                                     | the fourth `smoke` step, and a re-measured `timeout-minutes` comment |
| `docs/adr/0013-gui-smoke-harness-as-a-build-step.md`           | a #51 amendment: what was built, and why it is not the refused readback |
| `AGENTS.md`, `CONTRIBUTING.md`, `README.md`                    | the command block, the smoke bullet, the CI gating paragraph        |
| `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md` | #51 recorded as landed, and the verification table's GUI row |

Commits follow the boundaries above: the seam and backend first, then `measure.zig` with its tests, then the harness half, then build and CI, then docs. Conventional Commits, each referencing `(#51)`.

## Out of scope

- **A golden image.** ADR 0013's criterion is not met and features are what survive #57, #58 and #60.
- **Retiring `scripts/measure-trace`.** It reads a host's screenshot, which is a different question from what the shader computed, and #38's host procedure still depends on it. Note in passing that it inverts the mapping without the half-pixel centre term `measure.zig` uses; both are inside one pixel and reconciling them is not this issue's work.
- **Asserting #58's velocity weighting or #60's tonemap.** Neither exists. This issue is what makes them measurable when they do.
- **Promoting `smoke-appkit` out of `continue-on-error`.** That is #72.
