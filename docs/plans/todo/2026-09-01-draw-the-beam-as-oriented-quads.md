# Draw the beam as oriented quads rather than a line strip

Issue [#57](https://github.com/cboone/fosforo/issues/57). Branch `feature/beam-as-quads`. Phase 3, step 4 of [the build plan](2026-07-25-repo-foundation-and-phased-build-plan.md). Depends on [#55](https://github.com/cboone/fosforo/issues/55), which gave it somewhere to deposit, and on [#51](https://github.com/cboone/fosforo/issues/51), which gave it the only instrument that can see a single frame. [#58](https://github.com/cboone/fosforo/issues/58) and [#59](https://github.com/cboone/fosforo/issues/59) sit behind it.

## Context

The trace is one aliased device pixel wide, and has been since [#38](https://github.com/cboone/fosforo/issues/38) shipped it that way knowingly. Metal has no line-width API, verified against the SDK headers rather than assumed, so a line strip rasterizes at exactly one device pixel: on a 2x drawable that is half a point, and the result is thin, dim and jagged. `AGENTS.md` records it as the deliverable rather than a defect, and names the three wrong fixes so they do not get proposed again. This is where it stops being either.

What replaces it is [ADR 0007](../../adr/0007-renderer-simulates-a-crt.md)'s geometry bullet, which is one sentence and has been waiting since the planning pass: "Each segment expands into an oriented quad shaded by perpendicular distance from the centerline, giving analytic antialiasing independent of MSAA and a real beam intensity profile."

Three things follow that are not obvious from that sentence, and each is why this issue is worth doing before #58 rather than alongside it.

**It is the real test of the seam's raw-samples claim.** `src/gpu/iface.zig:438-449` argues that `[]const f32` crosses the seam and a vertex type must not, with the explicit prediction that a line strip is "one phase's way of drawing a trace" that phase 3 replaces with oriented quads. #38 could have falsified that and did not. This can, and the comment must record which way it went rather than quietly staying as written.

**It decides where silence sits, deliberately this time.** A flat trace lands on an exact pixel boundary at every even drawable height, the rasterizer picks one of two rows, and silence reads back as `+0.0021` rather than `+0.0000`. #38 measured that in REAPER and declined the corrective bias on three grounds, two of which this issue makes false: `Renderer` does now store its own size, and this is the step that re-answers the question.

**It re-answers the edge columns, and the evidence is currently unavailable rather than clean.** `level-1.089.wav` lit 1914 of 1920 columns where every other level lit all of them. Re-run against #55's accumulation, every level lights 1920 of 1920, but the issue's own comment refuses to read that as the problem going away: persistence keeps a column lit from an earlier frame, so a screenshot of an accumulated picture cannot tell an intermittent dropout from a fixed one. #51 has since landed and reads a single rendered frame, so the column count is measurable for the first time.

## The decisions this issue asks for

### The beam is 3.0 points wide, and points rather than device pixels makes the rail constraint scale-free

`iface.trace_rail` puts the rail 1% of the half-height inside the drawable, and the smallest editor `gui.clampSize` permits is 270 points tall. That leaves `(1 - 0.98) * 135`, or **2.7 points** of margin above a railed trace. A half-width of 1.5 points fits inside it at every geometry on any display, because both terms are in points and the scale cancels. Expressed in device pixels the same guarantee has to be re-derived per scale factor and holds only by arithmetic accident.

Checked rather than asserted: at 960x540 a railed profile spans rows 3.4 to 6.4 against a rail row of 4.9, and at the smallest editor it spans 1.2 to 4.2, with row 0 to spare. Nothing clips, but only just, and a clipped profile would bias the centroid downward.

`Renderer` starts storing the scale it currently only forwards. **The store has to go above the early return at `renderer.zig:1432`**, because the comment immediately above it says a scale can change without the pixel count changing; below that line the beam width would freeze whenever a window moved between displays. `Acquired.assemble` and the `Renderer` literal need the field too.

`initOffscreen` has no view whose scale could be read, and `iface.zig:456-460` already argues that a nominal one would make every measurement through that constructor a measurement of `backingPixels`' rounding. At exactly 1.0 that rounding is identity, so the offscreen path takes 1.0. **The consequence is structural and worth stating rather than discovering: `smoke-trace` always measures a 1.5-device-pixel half-width and can never exercise the 3.0 a 2x host runs**, which is where the rail clearance and the row spans are tightest.

### The fragment shades by distance to the segment, so caps are round and adjacent quads overlap

Distance to the *segment* rather than to its infinite line, which is six ALU operations and buys three things at once: joints are covered with no wedge gap on the outside of a turn, the endpoints at `x = ±1` are covered because the cap has area, and a degenerate segment becomes a dot rather than a `normalize(0)` NaN.

The quad is **oriented**, not axis-aligned: the segment's own box, extended by the half-width along its direction at both ends and by the half-width along its normal on both sides. That is the capsule's oriented bounding box, and the fragment does the rounding inside it.

The cost is that adjacent quads overlap and both deposit. **Two premises retire because of it.** `shaders/scope.metal:135-140` and `src/gpu/palette.zig:456-464` both justify extended Reinhard over plain Reinhard by saying the attainable domain is `(0, 1 / (1 - decay)]` "because a line strip's x is monotone in `vertex_id` so one frame cannot deposit twice on a pixel". That is false afterwards. The *conclusion* survives and gets stronger, since a wider domain is exactly what extended Reinhard handles and plain Reinhard does not, but the sentence has to be rewritten rather than left standing. [ADR 0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md)'s finding that "a line strip deposits once per pixel here" is superseded, and predicted its own obsolescence.

**One deviation from ADR 0007's wording, which the amendment has to name rather than gloss.** The ADR says "shaded by perpendicular distance from the centerline", which is the infinite line and has neither caps nor overlap. Distance to the segment is a deliberate departure, made for the edge columns and the joints, and it is what introduces the overlap. Four files carry the older phrasing.

### The deposit is scaled by sample density, and that is not velocity weighting

Additive overlap makes per-pixel brightness linear in samples per logical point, roughly `1 + 1.6 * s`, scale-invariant because the half-width and the segment pitch both scale together. At one sample per point that is about 2.6 deposits. At four it is 7.4, and the *moving* trace saturates to white: reachable at 96 kHz on a 480-point editor and at 192 kHz on a 960-point one, both ordinary. Today the line rasterizer is idempotent in overdraw, which is what ADR 0013's measured 1.0000 records, so oversampling costs nothing; quads make it cost, and phase 3's exit criteria include stability under sample-rate change.

The fix is one scalar in `TraceUniforms`, computed once per frame: `min(1, viewport_width / (sample_count - 1))`, the segment pitch in device pixels, clamped so it only ever attenuates.

**It is not velocity weighting and does not trespass on #58.** That factor is identical for every segment in a frame and depends only on the window length and the drawable width, never on the signal. #58's term varies per segment with how fast the beam is moving, which is the whole of what makes it velocity weighting. At one sample per point this factor is exactly 1.0, so nothing about the harness geometry changes.

**It also retires an assumption behind `max_window_samples`.** `iface.zig:41-44` sizes it for a 20 ms window at 409.6 kHz on the reasoning that extra samples are free. Under additive quads they are not, and 8192 samples on a 480-pixel drawable is 17 samples per point. The density scale is what keeps that geometry legible; [#62](https://github.com/cboone/fosforo/issues/62) is still the right answer to the fragment cost.

### The profile is the biweight, which keeps the shape of every published brightness number

`p = (1 - u²)²` with `u = min(d / half_width, 1)`. It peaks at exactly 1.0 on the centreline, so a single segment still deposits an energy of 1.0 at its core and `whitePoint`'s derivation from the dwell asymptote is untouched. It reaches zero with zero slope at the quad's edge, so there is no seam. Two multiplies, no transcendental.

**Compact support is worth more than it looks.** Because the profile is exactly zero at and beyond the half-width, unlit pixels hold exactly 0.0, so `checkResolve`'s background assertions and `probe.pixel(0, 0)` survive untouched, and the centroid can be summed over a whole column for free. A Gaussian would have neither property, on top of needing a transcendental and showing a truncation seam.

The published *values* do move, because overlap raises a moving trace from one deposit to about 2.6. Worked through `palette.zig`'s own arithmetic at `whitePoint(0.9) = 8.0`:

|          | today, e = 1.0     | after, e ≈ 2.6       |
| -------- | ------------------ | -------------------- |
| resolved | `RGB(75, 189, 96)` | `RGB(144, 225, 155)` |
| red gap  | 114                | 81                   |
| blue gap | 93                 | 70                   |

`MovingTraceTooDim` needs the lead channel at 128 or above and gets 225 rather than 189, so it gains margin. `MovingTraceNotTinted` needs 24 levels and gets 70 at the tightest channel. It would fire at about 5.8 deposits, which the density scale is what keeps out of reach.

### The energy-weighted centroid replaces the beam's top edge as the readout

This is what makes five smoke checks stronger rather than merely surviving, and it is the answer to the centre-line half pixel.

`src/gpu/measure.zig` reads `extremes(...).top` as the trace's position. With a one-pixel line that *is* the trace. With a profile it is the threshold contour's upper edge, biased above the true centreline by the lit half-width, systematically and with the same sign at every level. `pixelTolerance` is one backing pixel by construction and cannot absorb that; the file's own docstring says a tolerance wide enough to hide a systematic error is a tolerance that hides one.

A symmetric profile's energy-weighted centroid is exactly its centreline. At silence the beam centres on `y = 0` in NDC, which is pixel-space `y = 270.0` at a height of 540, equidistant from the centres of rows 269 and 270. The centroid is `269.5` in row-index units, and `impliedSample` there is `(1 - 2 * 270 / 540) / 0.9`, **exactly zero**. The `+0.0021` #38 measured and declined to correct is not corrected by a bias; it disappears because the estimator reads what the geometry says.

**Sum the whole column rather than the thresholded rows.** Since unlit pixels are exactly 0.0, including them is free and it halves the error: 0.054 rows against 0.112 at an adversarial sub-pixel offset. Worse, thresholding first makes the residual depend on the sub-pixel position, which is a bias that varies with signal level and is exactly the kind this estimator exists to remove.

`checkSymmetry` is the sharpest illustration of why the edge estimator has to go rather than be widened: it reads `seen.top` for both the `+0.5` and `-0.5` arms, so a half-width `h` moves both edges up, `above` grows by `h`, `below` shrinks by `h`, and the difference it asserts on is `2h`. It fails at a half-width over half a pixel, for a reason that has nothing to do with asymmetry.

## What changes

### `shaders/scope.metal` — the trace's two functions, rewritten

`trace_vertex` becomes an instanced quad expander. `[[vertex_id]]` runs 0..3 and selects a corner; `[[instance_id]]` is the segment index and reads `samples[segment]` and `samples[segment + 1]` from the same `device const float *samples [[buffer(0)]]`. **No `MTLVertexDescriptor`, no CPU-side geometry, and the sample buffer's layout is untouched**, which is what keeps the seam's claim intact.

`TraceOut` gains `p0` and `p1` in pixel space, both `[[flat]]`. `trace_fragment` gains `TraceOut in [[stage_in]]` and `constant TraceUniforms &beam [[buffer(0)]]`, computes the distance from `in.position.xy` to the segment, and returns `float4(profile * beam.density)` — one scalar broadcast to four channels, which is what keeps green an affine readout of energy.

A `distance_to_segment` helper, guarded at `dot(ab, ab) > 1e-12`.

**Four traps to write comments against, because each compiles and draws something plausible.**

- `vertex_id & 2` is 0 or **2**, not 0 or 1. `fullscreen_vertex` exploits that deliberately, so the idiom reads as correct arriving from four lines above and yields a quad twice as tall as intended. Use a boolean test or `(vertex_id >> 1) & 1`.
- Strip order must be the Z order `(0,0), (1,0), (0,1), (1,1)`. The ring order gives a bowtie covering half the quad, and nothing sets a cull mode, a winding, a viewport, a scissor or a sample count, so neither a bowtie nor a mirrored quad announces itself.
- **Metal's NDC-to-window transform negates y.** The file says "No Y flip" three times, meaning the *vertex* function does not negate because the rasterizer does. A pixel-space conversion written as `(y * 0.5 + 0.5) * H` is vertically mirrored against `in.position.y`, and those comments point straight at the wrong sign.
- `[[flat]]` takes the provoking vertex's value, which differs between the strip's two triangles. This is harmless **only** because all four corners compute the same `p0`/`p1`. Deriving this corner's own endpoint instead would put a discontinuity along the quad's diagonal with no compile error.

Docstrings to rewrite: lines 22-24, 135-140, and the whole of `trace_vertex`'s 225-245.

### `src/gpu/metal/renderer.zig` — the draw, the uniforms, the scale, and a NaN guard

- `mtl.primitive_type_triangle_strip: u64 = 4`, added to the existing docstring rather than as a bare constant, since that block already records the enum order and already implies the value.
- `TraceUniforms` gains `half_width_px`, `viewport_width`, `viewport_height` and `density`, all `f32` and all **without defaults**, by `AccumUniforms.decay`'s own argument that a per-frame measurement with a default compiles into a plausible picture. Size 28.
- A new named binding constant for the trace fragment's buffer 0, and the `setFragmentBytes:` call in the trace branch that does not exist today. Without a named constant the binding goes unchecked by the test at `renderer.zig:2771`, and `probe` cannot catch a missing bind because pipeline creation validates the declaration while the bind is a draw-time error.
- `Renderer` gains `scale: f64 = 1.0`, stored above the early return.
- `traceVertices` returns a struct carrying the sample count and the instance count. The comment at 1789-1793 argues the vertex count and the divisor must be one number; it is now three numbers derived from one, and if they disagree `samples[segment + 1]` reads a stale tail in bounds with no crash.
- **`writeWindow` sanitises non-finite samples to zero.** Nothing checks the audio today: `plugin.zig:324` checks the sample rate and nothing checks the signal. Under the line strip a NaN produces a NaN clip position and the rasterizer drops the primitive, one missing segment, self-healing. With quads a NaN can reach the fragment through `[[flat]]` p0/p1, and `float4(NaN)` blended into `RGBA16Float` is **permanent**, because `NaN * decay` is NaN on both halves of the ping-pong forever. That is precisely the ruined screen `clearAccumulation`'s docstring exists to prevent, arriving through a new door, recoverable only by a resize. Fast math means `isfinite` and `x != x` may fold away in MSL, so the guard has to be in Zig, and `writeWindow` already touches every sample.

### `src/gpu/metal/shader.zig` — the headroom factor, in the first commit

The file is **15,247 bytes** against a ceiling of 16,384, which is `embedded.len * 4 < max_bytes` at line 262. A rewrite of two functions at this repository's comment density does not fit in 1,137 bytes. Lower the factor to `* 3`, giving 21,845, and state the file size that motivated it exactly as #60 stated 8087. Line 60's "around ten kilobytes" and `renderer.zig:2183`'s "a file currently eight" are already stale and get worse.

**Not** raising `max_bytes`, which is what the factor exists to make visible.

### `src/gpu/iface.zig` — one new constant, two docstrings, one verdict

- `beam_width_points: f32 = 3.0`, with the rail-margin derivation, sited beside `trace_full_scale` and `trace_rail` because it is the same kind of object: a display-contract constant restated in `scripts/measure-trace` and pinned by the constants test.
- `trace_rail`'s docstring: the coverage-diamond half retires. The value does not move, because `1.089` is baked into the test-tone set, every published level-sweep table and #59's intersample margin.
- **The seam comment at 438-449 records the verdict.** The prediction held: a plain array indexed by `[[vertex_id]]` and `[[instance_id]]`, no `MTLVertexDescriptor`, nothing added to this file's vocabulary. The issue asks for this either way, so the sentence becomes a finding.

### `src/clap/gui.zig` — the rail test asserts the wrong bound

`gui.zig:1315-1327` asserts `inset > 1.0` at the minimum size, justified by the one-pixel coverage diamond. The property that now matters is that the beam's top edge stays inside, so the bound is `beam_width_points / 2`, or 1.5. It passes either way at an inset of 2.7, which is what makes it a correctness-of-reasoning defect rather than a failure: shrink the minimum or widen the beam and it silently stops guarding.

### `src/gpu/measure.zig` — the centroid estimator

- `centroidRow(image, x, channel) ?f32`, the energy-weighted mean row over a whole column.
- `centroids(image, threshold) ?Bounds` with `Bounds { top: f32, bottom: f32 }`.
- `impliedSampleAt(row: f32, height: usize) f32`, carrying the same `+ 0.5` row-centre term, with `impliedSample` delegating so the two cannot drift.
- `rasterize`, the test model, grows a half-width and the biweight, and **must clamp columns to `[0, width - 1]`** or the three-sample ramp test indexes out of bounds. That is a real crash in the model, not a wrong number.

`topRow`, `bottomRow`, `litColumns`, `litSpan` and `periods` stay. `periods` survives with reasoning rather than by luck: its band is derived from the measured peak, so the band and the columns shift together, and the 20-cycle margin is enormous.

### `src/smoke.zig` — five checks re-derived, two added

| Check                    | Change                                                                                                                                                                                                 |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `checkSilence`           | Centroid for `CentreLineWrong`, exact rather than within a pixel. `TraceNotFlat` becomes a parity-dependent range: an even height lights 2 rows, an odd one 3, and 1440x407 is already a test geometry |
| `checkLevels`            | Centroid against `expectedRow`; the systematic bias is gone rather than tolerated                                                                                                                      |
| `checkSaturation`        | Centroid against `railRow`; `RailNotSaturated`'s pixel-identity assertion is unaffected                                                                                                                |
| `checkSymmetry`          | Centroid for both arms, so the bias cancels instead of doubling                                                                                                                                        |
| `checkHorizontalMapping` | The one-column slack existed for the diamond-exit rule; tighten to columns 0 and `width - 1`                                                                                                           |
| `checkBeamProfile` (new) | The cross-section at one column matches the biweight, and the width is in pixel space rather than NDC, which is the only thing that would catch an elliptical beam                                     |
| `checkEdgeColumns` (new) | Every column lit at a railed level, on a single frame, which is #57's edge-column question asked of something persistence cannot mask                                                                  |

`trace_threshold` stays at 0.5 and its justification is restated. It was "half of one deposit, and one deposit is 1.0"; it becomes the biweight's half-intensity contour at `u = 0.541` of the half-width, which makes it the constant that sets every geometric measurement's effective beam width.

`checkHotCore` and `checkDecay` are re-measured rather than re-derived, and `checkDecay`'s docstring at 1286-1292 becomes flatly wrong: "anything above 1.0 is coverage counted more than once" describes overlap as a suspicion, and overlap is now the design.

`checkDepositIsScalar` survives, because four channels through identical arithmetic on identical inputs round identically even once the values are fractional. Worth confirming rather than assuming, since its 1e-3 tolerance is stated in terms of half-float precision.

**`checkResolve` is the most likely new flake.** It compares 518,400 pixels against the model with one byte of slack. Today 2412 lit pixels sit near energy 1.0; the profile puts thousands across the low end, where the sRGB toe is 3294.6 bytes per unit linear and `palette.zig:88` warns about rounding boundaries. Read the printed worst-off-by before touching the tolerance.

### `scripts/measure-trace`

Row reading moves to the centroid, or the script stops agreeing with `measure.zig`: at 1080 rows a 3-point beam at 2x puts the topmost lit row **three times `pixelTolerance`** above the centreline, which reads as close enough and is not. Also `beam_width_points` restated and pinned; the "a trail is lit" heuristic at 754-767, which would otherwise fire unconditionally; the `abs(peak_top - rail_row) <= 1.5` rail message; the module docstring's one-pixel sentence; and `SATURATED = 250`, whose "almost nothing reaches the white point" note becomes live again.

### Tests

| File           | Test                                                                                                                                                                                                                                        |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `renderer.zig` | `TraceUniforms` layout, size 28 and seven offsets                                                                                                                                                                                           |
| `renderer.zig` | The defaults loop, restructured: `full_scale` and `rail` carry the seam's constants; the four geometry fields deliberately carry none                                                                                                       |
| `renderer.zig` | `"the trace's uniforms carry the seam's scale"` constructs `TraceUniforms{ .sample_count = 2 }` and stops compiling; it needs the four new fields                                                                                           |
| `renderer.zig` | `bindingIndexAfter` needles renamed to `"TraceUniforms &uniforms"` and `"TraceUniforms &beam"`, on the `AccumUniforms &uniforms` / `&phosphor` precedent                                                                                    |
| `renderer.zig` | The deposit scrape, rewritten to assert `float4(` takes one argument rather than one literal `1.0`                                                                                                                                          |
| `renderer.zig` | `traceVertices` at 2, 960 and `max_window_samples`, asserting both numbers; `"the trace draws one vertex per sample"` is retitled because the title becomes false                                                                           |
| `renderer.zig` | `beam_width_points` added to the `measure-trace` constants test, with the occurrence count the "no name ends with another's" rule requires                                                                                                  |
| `iface.zig`    | The beam's half-width fits the rail margin at the smallest editor                                                                                                                                                                           |
| `measure.zig`  | The centroid of a symmetric profile is its centre, including the boundary-straddling case that makes silence exactly zero                                                                                                                   |
| `measure.zig`  | `"a flat window lights every column on one row"` asserts `top == bottom` and is false at any width; `"a sine below the visibility floor"` moves from 1 row to 2 or 3; `"a plateau says nothing about level"` needs its direction re-checked |

Deliberately not written: anything asserting `primitive_type_triangle_strip != primitive_type_line_strip`, which asserts that the code says what it says; and any test that constructs a `Renderer`, because `zig build test` acquires no GPU. Note that `mtl.primitive_type_line_strip` goes unreferenced with no compile error.

### Documentation

- [ADR 0007](../../adr/0007-renderer-simulates-a-crt.md): `## Amended by issue #57`, on the precedent 0013, 0017 and 0019 set. The geometry bullet is built; the beam width is a decision with a derivation; the "perpendicular distance from the centerline" wording is departed from deliberately; the one-deposit-per-pixel premise is retired. **No new ADR** — ADR 0007 settles the structure and ADR 0005 settles where it lives, which is the conclusion #55 reached for the same reason.
- [ADR 0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md): the line-strip deposit finding, marked superseded, with the new number.
- [ADR 0019](../../adr/0019-brightness-is-a-fixed-transfer-function.md): its stated mechanism for why brightness varies with level, "consecutive samples pile onto the same pixel", is superseded by geometry.
- `.github/workflows/ci.yml:216-231` quotes row 269, row 26, rail row 5, one deposit at exactly 1.0000, 2412 lit pixels and `RGB(75, 189, 96)`. Every one moves.
- `AGENTS.md`: the line-width gotcha, the `measure-trace` bullets, the `smoke-trace` bullet. `README.md:9` and `:11` both name the one-pixel line strip. `CHANGELOG.md` under `Added`, and the build plan's phase 3 table row.

## Verification

```bash
zig build test
zig build validate-shaders
zig build smoke-gpu
zig build smoke-trace
zig fmt --check build.zig src/
ruff format --check . && ruff check .
typos
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
```

**The acceptance test is `checkSilence`'s centroid reading exactly 0.0000 at a height of 540**, not within a pixel of it. That single number is the centre-line half pixel answered, and it cannot be obtained any other way. `checkEdgeColumns` at a railed level is the second: 960 of 960 columns on a single frame, the first time the 1914-of-1920 question has been put to something persistence cannot mask.

Then by hand, because `smoke-trace` renders a window it supplied itself and says nothing about the audio path, the ring, the display link or the compositor:

```bash
zig build install-clap
/Applications/REAPER.app/Contents/MacOS/REAPER 2>&1 | grep --line-buffered fosforo
```

**Arm 1, the trace's position.** Play `sine-100hz-0.5.wav`, capture the plugin's window, and run `scripts/measure-trace --refresh 120 verification/shot.png`. The peak and trough must invert to ±0.5000, and the guard's off-ray fraction must stay under `MAX_OFF_RAY`. **Done**: reads `+0.5000` and `-0.5000` at 0.26%.

**Arm 2, the rail.** The level sweep at 1.000, 1.050, 1.089 and 2.000. The centroid inverts straight to a sample value, so the criterion is that the implied sample tracks the level and then *stops*: +1.0000, +1.0500, +1.0889, +1.0889. Watching for a flat top is the wrong test, as `AGENTS.md` records; the peak ceasing to climb is the whole of what ADR 0017 means by refusing to say how far over a signal is. **Partly done**: `level-2.000` reads `+1.0893` against a predicted 1.08889 and prints the "on the rail" line. 1.000, 1.050 and 1.089 remain.

**Arm 3, sample rate, which is the density scale's whole justification and the only check on it anywhere.** Change REAPER's **device** rate in preferences, not the files: `gui.windowSamples` is `sample_rate * 0.020`, so the negotiated rate is what sets the window length and the files stay 48 kHz throughout. Play `sine-100hz-0.5.wav` at 48, 96 and 192 kHz, at the default editor and at the minimum, and read the `deposits` figure `measure-trace` prints for the brightest pixel.

**The criterion is a direction, not a magnitude.** Predicted single-frame energy at a 960-point editor is 2.60, 2.10 and 1.85 deposits, which is the offscreen sweep re-measured through the host's own persistence, so the printed number will be larger than those and should *fall* by roughly a third across the range. What must not happen is a rise: before the density scale was corrected to points, a 2x display went 2.60 at 48 kHz to 3.70 at 192, and the minimum editor at 192 kHz was worse still. That case is the sharpest test here, because 480 points at 3840 samples is eight samples per point.

Two cautions. Use the sine rather than `level-2.000`, whose brightest pixel reads "at or above the white point" and yields no number at all. And take more than one capture per rate: the sweep is free-running, so peak dwell swings about ±35% between frames depending on where the phase lands, which ADR 0019 records from #60's session.

**Arm 4, by eye.** The beam is visibly wider and smoother with no seam where the geometry ends, and a transport stop still draws the bright vertical line [#79](https://github.com/cboone/fosforo/issues/79) describes, which is #58's to remove rather than this issue's.

### Numbers to record rather than predict

1. **Peak single-frame energy.** `checkDecay` prints it; it was exactly 1.0000 and should land near 2.6. That number is what retires the tonemap's domain premise, quantified.
2. **`checkHotCore`'s tint gaps**, predicted at 81 and 70 against a bound of 24.
3. **Whether the joint overlap beads.** Two analyses disagree. Treating adjacent capsules as end-to-end predicts a 2:1 ripple at the segment pitch on steep strokes, green 189 against 219. Treating them as side-by-side, which is what they are when the segment pitch is under the beam width, predicts near-uniform coverage instead. At one sample per point the pitch is 1 px against a 3 px width, so the second geometry is the one in play, but this is exactly the kind of thing to look at rather than derive.
4. **Whether the dwell ratio widens.** ADR 0019 records that 2:1 is too narrow for any white point to carve a core out of, and hands the re-judgement to #58. Overlap widens it here by some amount. If materially, `white_headroom` becomes re-judgeable earlier than expected; if not, that belongs in #58 before it starts.

### Planted defects

Each planted on a passing run, committed first so `git restore` cannot revert the fix with the plant, and with an unconditional trigger.

| Plant                                                 | Must be caught by                                                                                         |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Distance to the infinite line rather than the segment | `checkEdgeColumns`, and visibly by gaps at turns                                                          |
| `vertex_id & 2` used as 0-or-1                        | `checkBeamProfile`, since the quad doubles in height                                                      |
| Ring corner order, giving a bowtie                    | `checkSilence`'s `litColumns`                                                                             |
| The y flip's sign inverted                            | `checkSymmetry`'s `TraceInverted`                                                                         |
| `half_width` applied in NDC rather than pixels        | `checkBeamProfile`, since the beam becomes elliptical                                                     |
| The density scale dropped                             | The 192 kHz arm of the host pass, and nothing automated                                                   |
| A NaN injected into the uploaded window               | Nothing yet; this is what the `writeWindow` guard is for, and the plant is how the guard is shown to work |
| The centroid computed unweighted                      | `checkLevels`, but **not** `checkSilence`, since at silence the two agree                                 |

The last two are deliberately included expecting an asymmetric result, and recording which check separates them is the point.

## Deliberately not done

- **Velocity weighting.** [#58](https://github.com/cboone/fosforo/issues/58). The density scale is not it, for the reason given above, and nothing here may introduce a term that varies per segment with the signal.
- **Bandlimited reconstruction.** [#59](https://github.com/cboone/fosforo/issues/59), which inherits this geometry.
- **Decimation.** [#62](https://github.com/cboone/fosforo/issues/62). The density scale fixes the brightness, not the fragment cost of drawing 8192 segments onto 480 pixels.
- **Moving `trace_rail`.** Its stated reason changes; its value does not.
- **Re-judging `white_headroom`.** ADR 0019 holds it provisional and hands it to #58.
- **A 10-bit drawable, P3, or EDR.** The falloff skirt puts many more pixels in the gradient's toe where 8-bit quantization is worst, and this issue measured the cost: `checkResolve` went from off by 0 to off by 1 across 518,400 pixels, with lit pixels rising from 2412 to 4853. Filed as [#83](https://github.com/cboone/fosforo/issues/83) and [#84](https://github.com/cboone/fosforo/issues/84), both behind #58, since velocity weighting is what decides how many pixels end up in the toe that ships.

## Risks to watch at the keyboard

1. **Nothing validates a hot-reloaded shader's binding indices**, and this issue moves two. [#77](https://github.com/cboone/fosforo/issues/77) is where that gets checked; until then a trace that breaks right after a save is a moved `[[buffer(N)]]` before it is anything else, and `zig build test` is what checks it.
2. **`bindingIndexAfter` finds the first match and scans to end of file.** `"TraceUniforms &"` becomes ambiguous the moment the fragment takes one, and the failure is a passing test reading the wrong declaration.
3. **The sampler negative control is narrower than its docstring claims** — it searches for `[[sampler(`, not the bare word — but a profile implemented as a texture lookup still fails it, with a message about the accumulation's uniforms.
4. **`zig build` does not rebuild the smoke harness.** Run a smoke step first.
5. **A host loads what is installed.** Use `install-clap`, which prints the hash and the provenance of what landed.
6. **`markRenderThread` guards the compile path**, and it is debug-only.

## Commit sequence

1. `chore: make room in the shader for the beam's geometry (#57)` — the headroom factor alone and first, so the rewrite never discovers a red `expect` late.
2. `fix: refuse a non-finite sample before it reaches the GPU (#57)` — the `writeWindow` guard, ahead of the change that makes a NaN permanent.
3. `feat: draw each segment as an oriented quad (#57)` — the MSL, `TraceUniforms`, the primitive, the stored scale, the density scale, `traceVertices`, and the tests that move with them.
4. `feat: read the trace by its energy-weighted centroid (#57)` — `measure.zig` and its unit tests, including the rasterizer model.
5. `test: re-derive the trace checks against a beam with width (#57)` — `src/smoke.zig`, the five re-derived checks and the two new ones. First commit at which `smoke-trace` passes.
6. `fix: read a screenshot's trace by centroid too (#57)` — `scripts/measure-trace`.
7. `docs: record that the seam's raw-samples claim held (#57)` — `iface.zig`'s verdict, `gui.zig`'s rail bound, the two ADR amendments, ADR 0019's superseded mechanism, `AGENTS.md`, README, CHANGELOG, CI's recorded numbers, the build plan.

Each builds and is `zig build test`-clean. Commit 2 stands alone because the guard is correct and worth having whether or not the rest lands.

## What happened

Seven commits, in the planned order, with one inserted: the non-finite guard became its own commit ahead of the geometry rather than a line inside it, because the hazard it closes is created by the geometry and a guard that lands with the thing it guards cannot be shown to have been needed.

### The acceptance test reads exactly zero

`silence: centroid row 269.500, implying a sample of 0.00000`, at 960x540. The centre-line half pixel #38 left open is answered, and **the answer is that no bias was ever needed**. The geometry was right the whole time; `extremes(...).top` was reading the beam's top edge, which a one-pixel line does not have and a beam does. Every other vertical number moved with it: four of the seven levels now read exact, the other three are within 0.00022, symmetry is 121.50 against 121.50, and the rail lands on 4.872 against a predicted 4.9.

### Three predictions in this plan were wrong

**The caps are not what fixes the edge columns.** The plan, ADR 0007's amendment and the CHANGELOG all said the endpoints at `x = ±1` are covered "because the cap has area". Planting butt joints — no extension along the segment at all — still reads 960 of 960. What covers column zero is the quad's *body*: the first segment spans a whole pixel horizontally and therefore contains its centre, where a line's endpoint was a point that had to exit a diamond to light anything. All four places carrying the claim were corrected. The fix is that a quad has area at all, which is weaker and more robust than what was written.

**An over-large quad is harmless.** `vertex_id & 2` read as 0-or-1 was planted expecting `checkBeamProfile` to catch a doubled height. Nothing caught it, and nothing should have: the fragment clamps `u` to 1, so geometry beyond the half-width deposits exactly zero and the picture is bit-identical. The failure mode is an *under*-sized quad, which clips the profile; planted that way it fails `RailMisplaced`.

**Two plants were caught by an earlier check than predicted.** The inverted Y flip was expected at `checkSymmetry` and fails `checkLevels`; the clip-space half-width was expected at `checkBeamProfile` and fails `checkSaturation`. Both because the centroid made the earlier checks exact, which is the change's own doing.

### The shader budget cost more than the plan allowed for

The plan set the headroom factor to 3, from a file of 15,247 bytes against a fourfold ceiling of 16,384. The rewrite took it to **22,050**, which overshoots a threefold ceiling of 21,845 by 205 bytes. The factor went to 2 instead, with the real number recorded beside it, and `src/gpu/metal/shader.zig` now says plainly that this is the last honest move of the factor: at 32,768 against 22,050, the next thing to add ten kilobytes has to move `Buffer` off the stack and raise the bound.

### A half-pixel disagreement had to be settled that the plan did not mention

`scripts/measure-trace` omitted the pixel-centre term `src/gpu/measure.zig` has always carried, and both files said so and called reconciling them nobody's business. That was defensible while every assertion was stated in a one-pixel band. The centroid took the harness's tolerance to a twentieth of a pixel, at which point the two instruments disagreed by ten times it about captures they had both measured correctly: the same synthetic trace read `+0.5021` from the script and `+0.5000` from the harness. The script now carries the term and both read `+0.5000`.

### Planted defects

| Plant                                  | Caught by                | Reading                                  |
| -------------------------------------- | ------------------------ | ---------------------------------------- |
| The quad too small to hold its profile | `checkSaturation`        | `RailMisplaced`                          |
| Corners in ring order, giving a bowtie | `checkHorizontalMapping` | `TraceStartsLate`                        |
| The Y flip's sign inverted             | `checkLevels`            | `LevelMisplaced`                         |
| The half-width applied in clip space   | `checkSaturation`        | `RailMisplaced`                          |
| The centroid computed unweighted       | `checkSaturation`        | `RailMisplaced`                          |
| The last segment dropped from the draw | `checkHorizontalMapping` | `TraceEndsEarly`                         |
| A NaN in the window, guard removed     | `checkSilence`           | `TraceNotFlat`                           |
| A NaN in the window, guard in place    | —                        | passes, reading 0.00000                  |
| Distance to the infinite line          | **nothing**              | square caps rather than round; unchanged |
| Butt joints, no cap at all             | **nothing**              | 960 of 960 columns still lit             |
| The density scale dropped              | **nothing**              | unchanged at this geometry               |

The last three are the honest rows. The first two are why the edge-column claim above was corrected. The third is structural and not fixable here: the harness runs 960 samples across 960 pixels, so `density` is exactly 1.0 and a dropped scale is a no-op. **Only a host at a sample rate above 48 kHz can see it**, which is why the sample-rate pass is in the verification section and why it is the one thing here no automated check covers.

The NaN pair is a control rather than a single plant, for the reason `scripts/ring-race-check` exists: an absence has to be told apart from an instrument that was never running.

### What is left

The host verification has not been run. Everything above is `zig build smoke-trace`, which renders a window it supplied itself and says nothing about the audio path, the ring, the display link or the compositor. The bash block in the verification section is what remains, and the sample-rate arm of it is the only check on `density` that exists.

## The density scale was wrong, and answering "what does host verification need" is what found it

Not a plant and not a review finding: it fell out of working through the sample-rate arm of the verification above, which is the one thing here no automated check covers.

**The corrector was scale-dependent while the thing it corrects is not.** Overlap depends on `half_width / pitch`; the half-width is `beam_width_points * scale` and the pitch in pixels is `points * scale / instances`, so the scale cancels and overlap is a function of samples per logical *point* alone. `min(1, viewport_width / span)` was computed in **backing pixels**, which does not cancel. Measured offscreen at a 960-point editor by forcing both scales:

| Session               | 1x     | 2x, before | 2x, after  |
| --------------------- | ------ | ---------- | ---------- |
| 48 kHz, 960 samples   | 2.6133 | 2.4434     | 2.4434     |
| 192 kHz, 3840 samples | 1.8486 | **3.4531** | **1.7266** |

At 48 kHz the two scales already agreed within 7%. At 192 kHz they were a factor of **1.87** apart, in opposite directions from their own baselines — 1x fading 29% and 2x brightening 41%. Afterwards they agree to 7%, the same as at 48 kHz. [ADR 0019](../../adr/0019-brightness-is-a-fixed-transfer-function.md) makes brightness a function of accumulated energy and of nothing else, and a term tracking the backing scale is exactly what that forbids, so this was a defect rather than an imprecision.

**`zig build smoke-trace` could not have caught it**, and that is the structural limit this plan already recorded as a coverage gap turning out to be a correctness gap: `initOffscreen` always passes a scale of 1.0, so the harness measures one side of a two-sided defect and reads it as *dimmer* where the shipping display reads *brighter*. The answer is that the arithmetic moved into `beamDensity`, a pure function with no GPU anywhere near it, and two tests assert the property directly.

### Planted defects, second round

| Plant                                         | Caught by                                                     | Reading                     |
| --------------------------------------------- | ------------------------------------------------------------- | --------------------------- |
| The pitch computed in pixels, `scale` unused  | the compiler                                                  | `unused function parameter` |
| The scale multiplied rather than divided      | `"the beam's density does not depend on the display's scale"` | 1 against 0.50026           |
| The clamp dropped, so undersampling amplifies | `"…attenuates oversampling and never amplifies"`              | 2.0042 against 1            |
| The zero-instance guard dropped               | **nothing**                                                   | unchanged                   |

The first is the better outcome ADR 0013 records for the accumulation-texture plant: a defect that does not compile beats one a test catches. The last is honest and is now stated at the guard itself — `points / 0.0` is `inf` and `@min(1.0, inf)` is `1.0`, so the guard changes no result and is kept for the reader rather than for the arithmetic.

### What this does not change

Every number in the sections above was measured at one sample per logical point, where `density` is exactly 1.0 by construction, so `smoke-trace`'s output is byte-identical before and after. The host pass is still what settles the density arm, and it is now worth running.
