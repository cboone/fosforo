# Make the trace half's judgements pure, and turn the plant table into tests

Issue: [#92](https://github.com/cboone/fosforo/issues/92). Type: `refactor:` then `test:`. Item 4 of [the verification-gaps program](../todo/2026-09-04-close-the-verification-gaps-in-the-test-suite.md), taken now because it is the largest gap in that program and because [#93](https://github.com/cboone/fosforo/issues/93) and [#98](https://github.com/cboone/fosforo/issues/98) both cite it.

## Context

`src/smoke.zig` is 2,240 lines with **zero** test blocks, and it is not in `zig build test`'s module graph at all: it imports `src/main.zig` rather than the reverse, so no test binary compiles a line of it. It holds the thirteen `check*` functions that carry this project's hardest claims about what the pixels became.

The argument for closing this was made and won at [#51](https://github.com/cboone/fosforo/issues/51), about the other half of the same analysis. ADR 0013's #51 amendment:

> #38's defect was in the *analysis* and not in the shader: its first period counter read the topmost lit pixel against the centre row, a steep segment crossing the centre lights every row it spans, and every tone came back exactly one period low. An analysis that runs only against a GPU is an analysis nothing tests, so this one has its own tests and a rasterizer that deliberately reproduces the spanning behaviour that broke the original.

That produced `src/gpu/measure.zig` and its 15 tests. It was never carried through to the `check*` functions, which hold the **expectations** rather than the extraction, and it has been vindicated a second time since: `checkDecayIsInRealTime` composes its expectation per step rather than asking `decayOver` for the whole span, because the span clamps at `palette.max_elapsed_nanos` and predicts 0.7684 against a true 0.5451. `AGENTS.md` records that as "the first thing this check caught and it was in the check itself."

**This is smaller than the line count suggests, and exploration made it smaller still.** The trace half is contiguous, `src/smoke.zig:656-1750`, and imports only `std`, `gpu/iface.zig`, `gpu/measure.zig` and `gpu/palette.zig`. Nothing in it names `objc`, `clap`, `gui`, `plugin`, `platform` or `shader`. The GPU work is confined to `Probe`, and every check has the same skeleton: a prologue that builds a probe and runs it, then an epilogue over two already-populated slices. The seam is always the last `try probe.run(...)` line.

**The models are mostly borrowed rather than restated.** `checkResolve` calls `palette.buildPalette` and `palette.resolved` and says why: sharing the table is what makes the comparison exact rather than close. What is uncovered is the surrounding judgement: the loops, the tolerances, the guards against going vacuous, and the arithmetic each check performs for itself.

**Three vacuity holes turned up while reading, and they are in scope rather than adjacent to it.** The issue asks for "the guards against going vacuous", and these are what that phrase turns out to name:

- `checkDecay` and `checkDecayIsInRealTime` divide the measured peak by `first` with no check that `first` is non-zero. A blank readback gives `0 / 0`, and `nan > 0.02 * want` is **false**, so the assertion passes. A run in which nothing was drawn at all reads as a healthy decay.
- `checkPeriods` declares `var doubling: [3]usize = undefined` and writes it only inside a `switch` over the literal list `{1, 2, 4, 5, 8, 20}`. It is sound today and becomes unsound the moment that list changes.
- `expectClose` scales its tolerance by `@abs(b)` alone. At `b == 0` the tolerance collapses to zero and the predicate silently becomes exact equality, and it is asymmetric in its two arguments for no stated reason.

> **The third bullet is half wrong and is left standing rather than edited away**, on this directory's usual rule. The zero case is not a defect: with no division anywhere, `b == 0` reduces the predicate to exact equality, which is the right answer for a relative tolerance. Planting the old spelling back is what established that, because the test written for it passed. The clause that survives is the last one, the asymmetry, and it turned out to be the whole of it. See **Results**.

## The baseline

`zig build smoke-trace` on `0de9bec`, which is this branch's HEAD, measured from CI run [33988812989](https://github.com/cboone/fosforo/actions/runs/33988812989) rather than predicted. The acceptance criterion is that this transcript is reproduced **byte for byte**, and CI's figures are identical to this machine's, so either run can be the reference.

```text
  rendering shaders/scope.metal into a 960x540 texture and measuring it
  silence: centroid row 269.500, implying a sample of 0.00000
  level  0.250: centroid row  208.70, implying  0.25022, off by 0.00022
  level  0.500: centroid row  148.00, implying  0.50000, off by 0.00000
  level  1.000: centroid row   26.50, implying  1.00000, off by 0.00000
  level  1.050: centroid row   14.38, implying  1.04986, off by 0.00014
  level -0.250: centroid row  330.28, implying -0.25014, off by 0.00014
  level -0.500: centroid row  391.00, implying -0.50000, off by 0.00000
  level -1.000: centroid row  512.50, implying -1.00000, off by 0.00000
  rail: centroid row 4.872, expected 4.9
  symmetry: +0.5 sits 121.50 above centre, -0.5 sits 121.50 below
  three samples span columns 0 to 959 of 959
  railed: 960 of 960 columns lit, spanning 0 to 959
  beam: cross-section integrates to 1.5796, expected 1.6000, centred on column 479.50
   1 cycles in,  1 periods counted
   2 cycles in,  2 periods counted
   4 cycles in,  4 periods counted
   5 cycles in,  5 periods counted
   8 cycles in,  8 periods counted
  20 cycles in, 20 periods counted
  deposit: 4 channels agree to 0.00000 at every lit pixel
  background: RGBA(5, 5, 8, 255)
  resolve: 4853 lit pixels, worst channel off by 1
  hot core: one deposit reads RGB(143, 224, 154)
  hot core: thirty deposits peak at 24.188, white point 8.000
  hot core: the dwelt pixel reads RGB(255, 255, 255)
  decay: one deposit peaks at 2.6133
  decay: after 1 quiet frames, 0.8999 of the deposit, expected 0.9000
  decay: after 2 quiet frames, 0.8094 of the deposit, expected 0.8100
  decay: after 3 quiet frames, 0.7283 of the deposit, expected 0.7290
  decay: after 4 quiet frames, 0.6555 of the deposit, expected 0.6561
  real time: 12 frames 8 ms apart, 0.5433 left after 96 ms, expected 0.5451
  real time: 6 frames 16 ms apart, 0.5441 left after 96 ms, expected 0.5451
  real time: the two rates differ by 0.14%
```

## The change

### 1. `src/gpu/verdict.zig`, a new pure module

On `src/gpu/measure.zig`'s precedent, and stated in its docstring the way that file states its own: what it does not import, that `zig build test` therefore covers it on a runner with no graphics support (ADR 0009), and the historical defect that forces the split. Imports `std`, `builtin`, `iface.zig`, `measure.zig`, `palette.zig`, and nothing else. Tests under the `// ---` / `// Tests` / `// ---` banner, preceded by `const testing = std.testing;`.

**The judges print, through a `say` gated on `!builtin.is_test`.** That is `src/clap/log.zig:109`'s idiom, and ADR 0013's own Decision section is why it is mandatory rather than convenient: a test binary must stay silent, because `std.debug.print` from inside one interleaves with the runner's stream and the build runner reads that as a failed step despite a zero exit code. Gating the printer rather than moving the printing to `src/smoke.zig` is what keeps the bodies a near-verbatim move, which is what makes the transcript above cheap to preserve.

```zig
/// Everything a judge says, on stderr, and nothing in a test binary.
///
/// `src/clap/log.zig:109`'s idiom, for that file's reason ... a test binary has
/// to stay silent (ADR 0013).
fn say(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmt ++ "\n", args);
}
```

**Judges return `Fault!Report`.** `Fault` is one named error set holding the trace half's error names, which today are 33 ad-hoc `error.Foo` literals collected nowhere. `report` in `src/smoke.zig` prints `@errorName(err)`, so the names must not change. A test asserts a plant with `expectError` and reads the figures off the success value:

```zig
pub fn edgeColumns(image: measure.Image) Fault!Lit {
    const lit = measure.litColumns(image, trace_threshold);
    const span = measure.litSpan(image, trace_threshold) orelse return Fault.TraceNotDrawn;

    say("  railed: {d} of {d} columns lit, spanning {d} to {d}", .{
        lit, image.width, span.first, span.last,
    });

    if (span.first != 0 or span.last != image.width - 1) return Fault.EdgeColumnDark;
    if (lit != image.width) return Fault.ColumnDropped;
    return .{ .lit = lit, .span = span };
}
```

**Geometry comes off the image, never from `trace_width` / `trace_height`.** `measure.Image` already carries `width` and `height`, and this is what lets a test judge an 8x4 image instead of allocating 8.3 MB per case. `trace_width` and `trace_height` stay in `src/smoke.zig`, where they size the allocation and the offscreen surface; `trace_threshold`, `beam_half_width_px`, `trace_frame_nanos`, `trace_decay` and `decay_span_nanos` move to `verdict.zig`, which is where they are read. `trace_frame_timeout_us` stays behind: it is GPU scheduling, not judgement.

`verdict.Picture` is `Probe.pixel`'s value type, `{ width, height, bytes: []const u8 }` with a `pixel(x, y) []const u8`, so `resolve` and the two core judges take a picture rather than a probe. It lives here rather than in `measure.zig` because `measure.zig` is entirely `f32` arithmetic and has no function that touches a byte.

Fifteen judges, from thirteen checks. Four checks fold a loop that drives a fresh probe per arm, so their judge takes the collected scalars rather than an image; that is what makes them testable at all, since the readback buffer is overwritten by the next probe:

| Judge                              | Takes                    | Replaces                 |
| ---------------------------------- | ------------------------ | ------------------------ |
| `silence(image)`                   | one image                | `checkSilence`           |
| `level(image, level)`              | one image, per level     | `checkLevels`            |
| `saturation(levels, rows, height)` | the four measured rows   | `checkSaturation`        |
| `symmetry(rows, height)`           | the two measured rows    | `checkSymmetry`          |
| `horizontalMapping(image)`         | one image                | `checkHorizontalMapping` |
| `edgeColumns(image)`               | one image                | `checkEdgeColumns`       |
| `beamProfile(image, row)`          | one image and a row      | `checkBeamProfile`       |
| `period(image, cycles)`            | one image, per frequency | `checkPeriods`           |
| `periodRatio(counted)`             | the six counts           | `checkPeriods`           |
| `depositIsScalar(image)`           | one image                | `checkDepositIsScalar`   |
| `resolve(image, picture)`          | both readbacks           | `checkResolve`           |
| `movingCore(image, picture)`       | both readbacks           | `checkHotCore`           |
| `dwellCore(image, picture)`        | both readbacks           | `checkHotCore`           |
| `decay(peaks)`                     | the five measured peaks  | `checkDecay`             |
| `realTimeDecay(ratios)`            | the two measured ratios  | `checkDecayIsInRealTime` |

**The folds are transcript-identical, which was checked against the baseline rather than assumed.** `saturation` prints one line, from its first arm; `symmetry`, `decay` and `realTimeDecay` print after every arm has run. In each case nothing else prints between the first and last arm, so moving the print to the end of the fold does not reorder the transcript.

### 2. `src/smoke.zig` keeps the driving halves

Each `check*` shrinks to its prologue plus a call. `traceHalf`'s thirteen-line call list at `src/smoke.zig:979-991` is unchanged, and so is its fail-fast, which `trace_frame_timeout_us`' docstring relies on ("at most one deadline is ever burned in a run"). The file loses roughly 400 lines.

`checkDecayIsInRealTime` needs one structural correction while it is open. It holds two probes alive at once (`src/smoke.zig:1709-1719`) over the same aliased readback buffers, and is correct only because it extracts a scalar from the first before the second's readback overwrites it. That is currently an accident of statement order; with the judge taking scalars it becomes the shape of the code, and the reason gets a comment.

### 3. The comptime assertion, at `src/smoke.zig:1660-1693`

`decay_span_nanos`' docstring argues that both arms "divide it into whole nanoseconds and span *exactly* the same interval: 12 steps of 8 ms and 6 of 16 ms". Nothing asserts it, and the intervals live as a literal in the `for` at `src/smoke.zig:1689`. One comptime table in `verdict.zig` replaces both, read by the driver to know how many frames to run and by the judge to compose its expectation:

```zig
pub const Arm = struct { interval_nanos: u64, steps: u64 };

pub const decay_arms = arms: {
    const intervals = [_]u64{ 8 * std.time.ns_per_ms, 16 * std.time.ns_per_ms };
    var out: [intervals.len]Arm = undefined;
    for (intervals, &out) |interval, *slot| {
        if (decay_span_nanos % interval != 0) @compileError(
            "decay_span_nanos must divide evenly, or the two arms span different intervals",
        );
        slot.* = .{ .interval_nanos = interval, .steps = decay_span_nanos / interval };
    }
    break :arms out;
};
```

`@compileError` rather than `std.debug.assert`, because `--release=fast` strips the latter and this is a claim about constants.

### 4. `expectClose`, at `src/smoke.zig:1748-1750`

The degeneracy is removed by construction rather than guarded. Scaling by `@max(@abs(a), @abs(b))` makes the predicate symmetric in its arguments and well defined everywhere: the only input that collapses the tolerance to zero is `a == b == 0`, where exact equality already holds. Its one caller passes two values near 0.545 with a tolerance of 1e-4, so the change is invisible to the transcript, which prints nothing from this function at all.

### 5. The vacuity guards

`decay` and `realTimeDecay` refuse a zero first peak with `Fault.TraceNotDrawn` rather than dividing and comparing a `nan`. `periodRatio` takes the counts as a slice rather than reading a partially-written `undefined` array. Both are behaviour changes rather than moves, so they land in their own commit, and neither can alter the transcript on a healthy run.

### 6. `measure.rasterize` becomes public

It moves above `src/gpu/measure.zig`'s `// Tests` banner with its docstring intact. It is already documented as "a model of the beam, used to test the analysis", which is exactly what `verdict.zig`'s tests need, and one model shared by two suites is better than a second, smaller copy. It gains a caller rather than losing one, which is the direction [#95](https://github.com/cboone/fosforo/issues/95) wants.

### 7. `src/main.zig`

One import beside `gpu/measure.zig` at `src/main.zig:87`, with a comment on that one's shape, since the case is identical: not reached from the plugin at all, its one caller is `src/smoke.zig`, and an analysis checked only by the build step that needs a GPU is an analysis the usual test run would never see. `build.zig` needs no change: it names only `src/main.zig`, `src/smoke.zig` and `src/ring_race.zig` as roots, and everything else is pulled in by `@import`.

## The tests, written as the historical plants

The plant table in [`docs/plans/done/2026-08-29-verify-the-shader-offscreen-against-the-constants.md`](./2026-08-29-verify-the-shader-offscreen-against-the-constants.md) has **twelve rows and ten defects**: rows 3 and 4 are the same wrong divisor with a check relaxed, rows 5 and 6 the same negated y with checks skipped. The column has twelve cells to fill.

**Two rows name errors that no longer exist**, and the column says so rather than pretending otherwise. `BeamNotOneColour` was retired by [#60](https://github.com/cboone/fosforo/issues/60) when the deposit stopped carrying a colour; `checkDepositIsScalar` replaced it with a different claim, so what gets a test is the standing claim and not the retired one. `ResolveNotAnAdd` is `ResolveNotTheTonemap` under the same issue, and there the claim survived the rename.

**One row cannot become a test, by construction.** Binding `target` rather than `source` to the decay pass makes `source` an unused local, which Zig rejects before any judge runs; the plan records that it needed `_ = &source;` to be exercised at all. That cell says "caught by the compiler, not by a judge", which is a better outcome than a covered row.

Tests beyond the table, each closing something the table never reached:

- **Nothing was drawn at all.** `resolve`'s `lit == 0` guard, which no test reaches today, and the two decay folds' new zero-peak refusal, which is the `nan` hole above.
- **Chroma that does not follow from intensity**, which is the palette's whole claim and the thing a per-channel comparison could not see.
- **A beam expanded in clip space rather than in pixels**, which makes the profile elliptical, 1.78 times wider one way than the other at 960x540. `beamProfile` is the only judge that can see it, and its docstring says so.
- **`expectClose` against zero**, in both directions.
- **A dropped interior column**, which separates `ColumnDropped` from `EdgeColumnDark`.

## Documents

Every one lands with the change, on the program plan's rule that a document updated later describes a state nobody checked.

| Document                                                                      | Edit                                                                     |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `docs/adr/0013-gui-smoke-harness-as-a-build-step.md`                          | A `## Amended by issue #92:` section, appended after the #89 one         |
| `docs/plans/done/2026-08-29-verify-the-shader-offscreen-against-the-...md`    | The plant table gains a "Now covered by" column, twelve cells            |
| `AGENTS.md`                                                                   | The current state, the `smoke-trace` bullet, and the `src/` tree listing |
| `docs/plans/todo/2026-09-04-close-the-verification-gaps-in-the-test-suite.md` | Item 4's acceptance ticked, with what it did and did not close           |
| `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`         | The status table and the paragraph naming this the largest gap           |

**The ADR amendment must say what writing the guard established, not that the guard exists.** ADR 0015's #90 amendment is the model: it records that the compiler already enforced half the rule, which narrowed what a canary was for. The heading follows the invariant form, `## Amended by issue #N: <lowercase clause>`, and the ADR's own rule is that superseded prose stays standing rather than being edited away.

**Editing a `done/` plan in place is sanctioned here**, explicitly, by the issue's own acceptance criterion. That is the exception, not a new licence.

## Commits

1. `docs: plan making the trace half's judgements pure and testable (#92)`
2. `refactor: move the trace half's judgements into src/gpu/verdict.zig (#92)`
3. `test: share measure.zig's beam model with the new judges (#92)`
4. `test: encode the plant table as tests of the judges (#92)`
5. `test: correct expectClose's diagnosis, which planting falsified (#92)`
6. `test: make two arms discriminate, which planting showed they did not (#92)`
7. `test: assert the arm a matching pair of wrong rates would slip past (#92)`
8. `test: cover the wrong divisor at the width where it costs one column (#92)`
9. `docs: record that the trace half's judgements need no device (#92)`

**One deviation from the sequence planned above, and it is worth naming rather than tidying.** Commit 4 was to be a separate `fix:` for the vacuity guards and `expectClose`; both were written into `src/gpu/verdict.zig` as it was created, so they landed inside the move at commit 2 instead of beside it. The move is still transcript-identical, which was verified before it was committed, so nothing about the acceptance changed; what was lost is that the two behaviour changes are not reviewable on their own. Commits 5 through 8 are the ones planting produced afterwards and were not foreseen at all.

## Results

| Check                                    | Result                                                       |
| ---------------------------------------- | ------------------------------------------------------------ |
| `zig build smoke-trace`, transcript diff | Byte-identical, 35 lines, at the move and at the end         |
| `zig build test`                         | 230 tests before, **252** after, all passing                 |
| `zig build smoke-gpu`, `smoke-appkit`    | Pass; 10 open and close cycles clean                         |
| `zig build smoke-leaks -Dleak-cycles=40` | 285 leaks, 18,416 bytes, inside the recorded 285-288 baseline |
| `src/smoke.zig`                          | 2,240 lines to 1,712; `src/gpu/verdict.zig` is 1,557         |
| Judges planted, one weakening at a time  | 22 planted, **21** refused by the test that names the row    |
| `zig fmt --check`, `typos`               | Clean                                                        |
| `markdownlint-cli2`                      | Clean                                                        |

`ruff` is not installed on this machine, so its two commands were not run; no Python changed, and `scripts/measure-trace` is untouched.

**The transcript comparison excludes one line, and it has to.** `src/build_info.zig` stamps a provenance marker that names the branch, the commit and whether the tree is dirty, so it moves on every commit by construction. Everything from `rendering shaders/scope.metal into a 960x540 texture` down is compared.

**The local baseline was checked against CI before it was trusted**, from run [33988812989](https://github.com/cboone/fosforo/actions/runs/33988812989) on `0de9bec`, which is this branch's own merge base. All 35 figure lines agree, so the comparison is against a reading two machines produced rather than against one machine's habit.

### What planting the judges produced, which planting the shader did not

The tests were written first as the historical plants, and then each judge was weakened in turn to see whether its test noticed. **That second pass is where every finding below came from, and none of them was visible in the first.** Writing a test named for a plant is cheap; establishing that it refuses the plant and would not refuse a correct picture is the part that costs a sweep.

**A blank readback used to pass the decay checks outright.** They divided the measured peak by a first peak nothing checked, and `nan > 0.02 * want` is **false**. Planted with the guard removed, the judge returns `void` where the test now demands a refusal, which is the executable form of that sentence.

**The `expectClose` defect this issue named does not exist.** It performed no division, and at zero it reduced to exact equality, which is the right answer for a relative tolerance. The old spelling was planted back and the test written for it passed, so the test asserted nothing. The real defect was asymmetry, and the discriminating arm is `a = 2`, `b = 1` at a tolerance of 0.75.

**Two tests encoded a plant without covering it.** The centreline plant sat at 0.01 of full scale, 2.4 times a whole backing pixel, so widening the twentieth-of-a-pixel bound twentyfold changed no verdict; it now sits at 0.001, between the two bounds. The background plant sat one byte off the palette's value at zero, which the per-pixel loop refuses anyway within its own slack; it is now five levels off. **This is #38's tolerance rule one level up:** a plant far enough outside a bound to be caught by something else is a plant that hides the arm it names.

**And one arm cannot fire.** `movingCore` refuses a channel gap of zero or less before refusing a gap under 24, and for the shipped palette the second already refuses everything the first would, since green's non-lead tints are below 1.0. It stays for a palette whose non-lead tint reaches 1.0, and now says so at the source.

### What survived its own weakening, and why exactly one still does

**One of the 22 plants leaves every test passing, and it is the dead arm rather than a hole.** `movingCore`'s `gap <= 0` cannot fire for the shipped palette, so removing it changes no verdict any test can reach. It stays for a palette whose non-lead tint reaches 1.0, and the source now says so.

Two more survived on the first sweep and do not on the last, which is the sweep earning its cost. `realTimeDecay`'s spread check catches a per-frame factor without the per-arm comparison, so removing that comparison broke nothing: what it meant was that **nothing asserted the per-arm case at all**, a *pair* of arms wrong in the same way, which the spread between them is blind to by construction. And `silence`'s flatness arm had no plant sitting between its bound and the next net. Both now have one.

**The sweep needed its own negative control, and it was wrong the first time.** The first version matched failures with `grep -oE "test\.[^']+' failed"`, and three test names here contain an apostrophe, so the character class stopped early and four *caught* plants were reported as uncaught. It reads the exit code now. An instrument that reports absences has to be checked against a case it should find, which is the rule `scripts/ring-race-check` already applies to a sanitizer and which this sweep had to learn separately.

## Verification

Run in order. The first two are the negative controls and neither is optional.

1. **`zig build smoke-trace > /tmp/before.txt 2>&1` on `main`, before touching anything.** An absence has to be told apart from an instrument that did not run, and a transcript comparison against a baseline nobody re-measured is a comparison against a claim. The CI transcript above is the cross-check on this machine's copy, not a substitute for it.
2. **`zig build test` before the new tests are written**, so the 230 tests currently passing are known to pass, and the count is known.
3. `zig fmt --check build.zig src/`
4. `zig build test` — the new judge tests, plus the existing suite. Report the new total against 230.
5. `zig build smoke-trace > /tmp/after.txt 2>&1 && diff /tmp/before.txt /tmp/after.txt` — **after commit 1 and again at the end.** Empty output is the acceptance criterion. A moved number is a changed check.
6. `zig build smoke-gpu` — the control that the seam still builds, since `src/smoke.zig` changed.
7. `zig build smoke-appkit` and `zig build smoke-leaks` — neither path was touched, so these are controls rather than tests, and cheap ones to have run before claiming the harness is intact.
8. **Re-plant three defects against the judges in isolation** and confirm each fails by the name the table gives, not by a different one: #55's `1 - decay` resolve gain, a level centroid off by more than one pixel, and a decay that never fades. A test that passes because the judge rejects everything is worth nothing, so each plant test is paired with the good-input case in the same test block.
9. `typos && ruff format --check . && ruff check .`
10. `markdownlint-cli2` — by hand, since nothing runs it. **Never with `--fix`**: it ignores its file arguments and rewrites every file matching its globs, including completed plans. The plant table's cells run long and MD060 is pinned to `aligned`, so re-pad that one table with `prettier --write` on that file alone.

**No host verification.** Nothing here changes the shader, the renderer, the seam or any shipping path; the whole change is a harness refactor plus tests. The transcript comparison at step 5 is the stronger statement, because it asserts that the numbers the shader produces are unchanged rather than that a picture still looks right.

## Out of scope

- **Testing the driving halves.** They acquire a device, correctly and permanently. `Probe`, `Worker` and `driveFrame` stay untested and stay in `src/smoke.zig`.
- **Whether the drawable looks right in a host.** `scripts/measure-trace` and [#38](https://github.com/cboone/fosforo/issues/38)'s procedure still own that, and `zig build smoke-trace` measures a window it supplied itself.
- **The GPU half and the AppKit half.** Both have their own untested judgement and neither is what this issue is about. The reload fixtures at `src/smoke.zig:269-654` are shared by both halves and are not touched.
- **An automated mutation tester.** There is no mature one for Zig, and the program plan already records this issue as the affordable share of it: it converts the plants expressible as data into tests that re-run, and leaves the rest as manual obligations.
- **Retuning any tolerance.** Every number in the judges moves across unchanged. A tolerance that turns out to be wrong is a separate finding with its own measurement.
