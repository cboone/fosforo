# Close the verification gaps in the test suite

Issues: [#89](https://github.com/cboone/fosforo/issues/89) through [#99](https://github.com/cboone/fosforo/issues/99), each one branch and one PR, on the rule the phase 3 section already states: the code and its verification land together.

**None of them sits on a milestone**, on the rule in the build plan's "How work is tracked": a milestone marks what has to close before that phase's exit criteria are met, and phase 3's are about the picture and its stability under resize, sample-rate change and multiple instances. No one of these has to close for those to be true. They are recorded in the build plan's phase 3 section instead, which is where a reader who does not open the tracker will find them.

## Context

A review of the whole verification surface on `0e1ddf5` found 200 named tests across `src/`, roughly a quarter of the Zig source, and a set of instruments layered with an explicit written theory of what each one cannot see. That theory is the strongest thing here, and it has outrun the instruments in a small number of specific places.

The gaps are not spread evenly and they are not the usual "write more tests". They cluster in one shape: **the question "would I know if this broke?" was answered once, by hand, and the answer was written into prose rather than into anything that re-runs.** ADR 0013 and ADR 0016 both record planted defects as acceptance criteria and both are right to; what neither does is leave behind a check that fails if the planted defect is reintroduced tomorrow. Ten defects were planted against `smoke-trace` and all ten were caught; none of the ten is a test.

Four consequences of that shape, in the order they cost something:

- `main` is currently red on a required check, and the reason falsifies a bound the code argues for in a docstring.
- `src/smoke.zig` carries the project's hardest claims, is the second-largest file here, and has zero tests. The argument for splitting `src/gpu/measure.zig` out and testing it applies to the rest of that file and was not carried through.
- ADR 0016's discipline, which is exemplary, is scoped to one file. Four more cross-thread mechanisms have arrived since and none of them has any part of it.
- ADR 0015 is listed among the non-negotiables and a one-token edit defeats it silently, in a project that already has the pattern for stopping exactly that.

Everything below is scoped so that most of it runs against `zig build test` alone, which the build plan's lane table puts outside all three exclusive resources. Ten of the eleven sit in that free lane, so this program runs beside phase 3's issue work rather than behind it.

## The principle these all share

A test asserts a property of the code. Planting a defect asserts a property of the test, and the second does not follow from the first. Where a check is an external instrument, or where its claim is an absence, the second property has a bad default answer and reading the source cannot improve it.

The work below does not replace planting. It moves the plants that can be expressed as data into `zig build test`, so they regress; keeps the ones that cannot as manual obligations with a named home; and closes the two places where the plant was never possible because the code was not reachable from a test build at all.

## Summary

| Issue                                              | Work                                                          | Type        | Needs               | Closes                                                    |
| -------------------------------------------------- | ------------------------------------------------------------- | ----------- | ------------------- | --------------------------------------------------------- |
| [#89](https://github.com/cboone/fosforo/issues/89) | Give the trace half's frame wait a deadline                   | `fix:`      | A device, no window | A red `main` on a required check                          |
| [#90](https://github.com/cboone/fosforo/issues/90) | Canary every ordering-critical declaration                    | `test:`     | Nothing             | ADR 0015 and three unguarded atomics                      |
| [#91](https://github.com/cboone/fosforo/issues/91) | Race `gui.zig`'s two cross-thread primitives                  | `test:`     | A Linux runner      | ADR 0016 applied to the primitives that guard teardown    |
| [#92](https://github.com/cboone/fosforo/issues/92) | Make the trace half's judgements pure, and test them          | `refactor:` | A device, no window | `src/smoke.zig`'s 0 tests; makes the plant table regress  |
| [#93](https://github.com/cboone/fosforo/issues/93) | Make the watcher's bookkeeping reachable from a test build    | `refactor:` | Nothing             | Code no test binary compiles                              |
| [#94](https://github.com/cboone/fosforo/issues/94) | Run the unit suite in the mode that ships                     | `ci:`       | Nothing             | Debug-only test coverage of a ReleaseFast product         |
| [#95](https://github.com/cboone/fosforo/issues/95) | Analyze every public declaration, and settle the uncalled one | `test:`     | Nothing             | The lazy-analysis hole, live in one declaration           |
| [#96](https://github.com/cboone/fosforo/issues/96) | Assert the transfer function's defining properties            | `test:`     | Nothing             | `tonemap` and `whitePoint`'s stated claims                |
| [#97](https://github.com/cboone/fosforo/issues/97) | The remaining cheap assertions                                | `test:`     | Nothing             | Eleven small, named holes                                 |
| [#98](https://github.com/cboone/fosforo/issues/98) | Cover the render thread's read side                           | `test:`     | A seam decision     | `Editor.tick` and `Editor.readWindow`, currently untested |
| [#99](https://github.com/cboone/fosforo/issues/99) | Lint the workflows                                            | `ci:`       | Nothing             | 46 KB of `ci.yml` that nothing checks                     |

## 1. Give the trace half's frame wait a deadline rather than a spin count

**Issue:** [#89](https://github.com/cboone/fosforo/issues/89). **Type:** `fix:`. **Do this first**, because it is the only item that is currently costing something.

### What happened

CI run [33465800182](https://github.com/cboone/fosforo/actions/runs/33465800182) on `0e1ddf5` failed with `smoke: trace FAILED: FramesNeverPresented`, inside `checkDecay`'s five-frame arm. Every measurement it printed before that point was correct: levels within a pixel, the rail on the expected row, the resolve's worst channel off by 0, the hot core reaching `RGB(255, 255, 255)`. Nothing about the shader was wrong.

It is the only unintentional CI failure in the last 60 runs of `ci.yml`. The other two were on a branch named `test/measure-ring-race-planted-defect`.

### Why the bound is wrong

`FramesNeverPresented` comes from `driveFrame` (`src/smoke.zig:783`) exhausting `trace_frame_attempts = 100_000` while `frame` reports `.no_frame_slot`. That constant's docstring (`src/smoke.zig:628`) argues:

> **The bound is attempts rather than time, and each attempt yields**, so this is a bound on scheduler turns rather than on a duration. A frame at this geometry completes in well under a millisecond, and a hundred thousand yields is many seconds of slack on a loaded runner. That is the same reasoning `frame_timeout_us` carries: the margin is for a busy machine, and anything approaching this ceiling is the defect rather than the ceiling.

The failing step ran from 03:20:06 to 03:20:09. Three seconds, against four for a passing trace step on the previous commit. It did not spend "many seconds of slack"; it gave up faster than a successful run completes, because `std.Thread.yield()` returns almost immediately when nothing else on the core is runnable. The bound is a spin count wearing a timeout's clothes, and it is the only wait in the harness that is not wall-clock: `frame_timeout_us` is 2 s (`src/smoke.zig:91`) and `reload_timeout_us` is 6 s (`:429`).

The exposure grows with frame count, which is why it surfaced where it did. `checkDecay`'s last arm drives five frames against a three-deep semaphore. `checkDecayIsInRealTime`, which drives thirteen and seven and runs after it, is more exposed and has never been reached on a slow runner.

### Shape

Replace the attempt count with a deadline read from `platform.io`'s clock, on `frame_timeout_us`' precedent, and keep yielding between polls. Say the elapsed time in the failure message rather than the attempt count, so the next occurrence is attributable without reading the source.

### Acceptance

- Plant a `frame` that always reports `.no_frame_slot`, and confirm the harness fails naming a duration rather than a count, at roughly the deadline rather than in a fraction of a second.
- Re-run `zig build smoke-trace` on this machine and confirm the reported figures are unchanged, since this must not move any measurement.
- Correct the docstring rather than deleting it. The reasoning it records was falsified by a measurement, and that is worth keeping alongside the correction.

### What it does not close

Nothing about whether the trace half's *assertions* are right. That is item 4.

## 2. Canary every ordering-critical declaration

**Issue:** [#90](https://github.com/cboone/fosforo/issues/90). **Type:** `test:`. Cheapest item here by a wide margin, and it reaches the one non-negotiable with no guard at all.

### The gap

`src/dsp/ring.zig:742` embeds its own source at comptime and asserts the five atomic operations are stated exactly as written. ADR 0016 explains why: the machine this project is developed on is the one machine that cannot run the sanitizer, so a weakened atomic would pass locally and be learned about only after a push. The canary is deliberately the faster of the two checks rather than the harder to fool.

That pattern exists once. Four declarations of the same kind have no equivalent:

| Declaration                      | Where                                | What a silent edit costs                                                   |
| -------------------------------- | ------------------------------------ | -------------------------------------------------------------------------- |
| `backend: std.Io.Threaded`       | `src/platform/io.zig:38`             | `Threaded.init` replaces the host DAW's `SIGIO` and `SIGPIPE` handlers     |
| `Gate.enter` / `leave` / `close` | `src/clap/gui.zig:916-941`           | Editor teardown races the render thread it is waiting for                  |
| `Pending.post` / `take`          | `src/clap/gui.zig:173,180`           | The render thread acts on a size from one display and a scale from another |
| `Mailbox.publish` / `take`       | `src/gpu/metal/renderer.zig:649,666` | A swapped pipeline is read before it is fully published                    |

The first is the sharpest. `CLAUDE.md` lists "`std.Io` is reached through the one instance in `src/platform/io.zig`, constructed with `init_single_threaded` and never with `Threaded.init`" among the non-negotiables. `src/platform/io.zig` has zero tests, no comptime assertion, and no canary. Changing one token compiles, passes all 200 tests, and ships a plugin that installs signal handlers into REAPER's address space.

### Shape

Copy `statedOnce`'s structure from `src/dsp/ring.zig:721`, once per file, reading that file's own source through `@embedFile`. Two things about the existing implementation are worth fixing while transplanting it rather than reproducing:

- `statedOnce` formats `"\n        {s}\n"` with exactly eight spaces, so re-indenting a statement into an `if` block fails it with no semantic change. Match on the trimmed line instead.
- The count assertion (`std.mem.count(u8, code, "self.cursor.")` equals five) reads text above the tests banner, so a new doc comment naming `self.cursor.load` breaks it. Anchor the count on the statement rather than the identifier.

### Acceptance

Each canary is verified by planting the edit it exists to refuse and confirming `zig build test` fails naming the line, then reverting:

- `.init_single_threaded` to `.init` in `io.zig`.
- `Gate.enter`'s `fetchAdd(one_tick, .acquire)` to `.monotonic`.
- `Pending.post`'s `store(..., .release)` to `.monotonic`.
- `Mailbox.publish`'s `store(.full, .release)` to `.monotonic`.

### What it does not close

A canary proves the lines are unchanged, not that they are correct, and its own docstring in `ring.zig` says so. A global find-and-replace rewrites the canary's string literals along with the code. That is accepted for the same reason it is accepted in `ring.zig`, and for `Gate` and `Pending` it is what item 3 backstops.

## 3. Race `gui.zig`'s two cross-thread primitives under Thread Sanitizer

**Issue:** [#91](https://github.com/cboone/fosforo/issues/91). **Type:** `test:`. The largest of the concurrency items and the one with a real design decision in it.

### The gap

ADR 0016 gives `src/dsp/ring.zig` a TSan arm, a deliberately weakened control arm that must be flagged first, and a source canary. It closes with an obligation scoped to one file: "Anyone adding a further atomic operation to `src/dsp/ring.zig` should plant a defect in it and confirm the job goes red before assuming this covers it."

Four mechanisms have arrived since and the obligation does not reach them. `Gate` is the one that matters most, because it is what stands between a host's main thread and memory the render thread is still reading. Its two tests are honest about what they do and what they do not:

- `gui.zig:1115` closes an uncontended gate, so `close`'s spin body at `gui.zig:938` never executes.
- `gui.zig:1134` produces "the state a tick mid-frame leaves behind" by calling `state.fetchOr(Gate.closed, .acquire)` in the test body. There is no second thread anywhere in the file.

So the exact failure ADR 0016 was written about, an atomic simplified by someone watching a green suite, is available on `Gate` today and passes all 44 tests in that file.

### Shape

`Gate` reaches nothing but `std`, so extracting it to its own module is mechanical, and the module can then be built for `x86_64-linux` beside `src/dsp/ring.zig`. `Pending` does not: its `Update` carries `gpu.Size`, and reaching `src/gpu/iface.zig` from a Linux target pulls `src/gpu/metal/renderer.zig` into the module's import table, where `b.dependency("objc", ...)` panics at configure time on any OS that is not Darwin. That is the same wall `build.zig`'s early return at line 41 already exists for.

**The decision this issue owns** is how `Pending` stops needing `gpu.Size`. Two candidates, and the second is the recommendation:

- Make `Pending` generic over its size type. Correct, and it puts a type parameter on a struct whose whole argument is that it is one `u64`.
- Move the plain `Size` struct out of `src/gpu/iface.zig` into a module that names no backend, and have the seam re-export it. `Size` is two `u32` fields and is already used by `gui.zig`, `view.zig` and the renderer; the seam's comptime block at `iface.zig:430` is what enforces ADR 0005 and would be unaffected.

Then a second harness on `src/ring_race.zig`'s pattern, with the same three load-bearing properties: a weakened control arm that must be flagged before the real arm's silence means anything, `link_libc` so TSan intercepts `pthread_create`, and `use_llvm = true` so the instrumentation is actually emitted.

The arms worth having, given what each primitive is for:

| Arm                | Threads                                  | Must be |
| ------------------ | ---------------------------------------- | ------- |
| `gate`             | One entering and leaving, one closing    | Clean   |
| `gate-weakened`    | The same, with `enter`'s acquire relaxed | Flagged |
| `pending`          | One posting, one taking                  | Clean   |
| `pending-weakened` | The same, with `post`'s release relaxed  | Flagged |

### Acceptance

- Both weakened arms are flagged with `WARNING: ThreadSanitizer: data race` before either clean arm's result is read, judged by a script on `scripts/ring-race-check`'s assertion order.
- The defect is planted in the **real** primitives as well as the replicas, on ADR 0016's own reasoning that "a control that models the defect is not the subject exhibiting it".
- `Gate`'s spin body is genuinely entered, confirmed by a counter the harness prints, so a `close` that never waited would be visible as a vacuous pass.

### What it does not close

`renderer.Mailbox` carries `Pipelines`, which are Objective-C objects, so it cannot be raced on Linux at all. Item 6 covers what is testable about it. And the watcher thread itself stays outside any sanitizer, which should be stated in the ADR amendment rather than left to be rediscovered.

## 4. Make the trace half's judgements pure, and turn the plant table into tests

**Issue:** [#92](https://github.com/cboone/fosforo/issues/92). **Type:** `refactor:` then `test:`. The highest-leverage item, and the one that changes the project's relationship to planting.

### The gap

`src/smoke.zig` is 1,898 lines with zero test blocks, and it is not in the test module's graph at all: it imports `src/main.zig` rather than the reverse, so `zig build test` never compiles a line of it.

ADR 0013's #51 amendment already made this argument and won it, about the other half of the same analysis:

> #38's defect was in the *analysis* and not in the shader: its first period counter read the topmost lit pixel against the centre row, a steep segment crossing the centre lights every row it spans, and every tone came back exactly one period low. An analysis that runs only against a GPU is an analysis nothing tests, so this one has its own tests.

That reasoning was applied to `src/gpu/measure.zig`, which has 14 tests and a model rasterizer that deliberately reproduces the spanning behaviour that broke the original. It was not carried through to the eleven `check*` functions, which hold the expectations rather than the extraction. And it has already been vindicated a second time: `checkDecayIsInRealTime`'s per-step composition exists because asking `decayOver` for the whole span clamps and predicts 0.7684 against a true 0.5451, which `AGENTS.md` records as "the first thing this check caught and it was in the check itself".

### Why this is smaller than it looks

The models are mostly already borrowed rather than restated. `checkResolve` calls `palette.buildPalette` and `palette.resolved`, so the palette arithmetic is covered by `src/gpu/palette.zig`'s 15 tests, and its comment is explicit that sharing the table is what makes the comparison exact. What is uncovered is the surrounding judgement: the loops, the tolerances, the guards against going vacuous, and the arithmetic each check does for itself.

Each `check*` already splits cleanly, because the GPU work is confined to `Probe`:

```text
checkResolve(energy, picture, window)
  ├─ drive:  Probe.init → measure.sine → probe.run     needs a device
  └─ judge:  loops over image and picture              pure, given two slices
```

### Shape

Move the judging halves into a module that names no Metal type and imports nothing but `std`, the seam, `src/gpu/measure.zig` and `src/gpu/palette.zig`, on `measure.zig`'s precedent. Name it in `src/main.zig`'s test block beside `measure.zig`, with the same comment explaining why. `src/smoke.zig` keeps the driving halves and calls the judges.

Then write the tests, and write them **as the historical plants**. Ten defects were planted against this half and the table is in `docs/plans/done/2026-08-29-verify-the-shader-offscreen-against-the-constants.md`. Every one of them that can be expressed as a synthetic readback buffer becomes a test asserting the judge rejects it, including:

- #55's `1 - decay` resolve gain, which fails with a channel 224 levels out.
- The period counter's off-by-one, against a window whose steep segment spans the centre row.
- A picture whose chroma does not follow from its intensity, which is the palette's whole claim.
- A run in which nothing was drawn at all, which is what `if (lit == 0)` exists for and which no test currently reaches.

Two arithmetic details to fix while the code is open, both currently correct and currently unasserted: `decay_span_nanos / interval` at `src/smoke.zig:1351` is integer division whose divisibility is argued in a comment, which should be a comptime assertion; and `expectClose`'s relative tolerance divides by `b`, which is undefined if a future caller passes zero.

### Acceptance

- Every test added is verified by the plant it encodes, run against the judge in isolation rather than against the GPU.
- `zig build smoke-trace` on this machine reports figures identical to the ones it reports today, printed and compared, since a refactor that moved a number is a refactor that changed the check.
- The plan document's plant table gains a column naming the test that now covers each row, and the rows that cannot be covered say so.

### What it does not close

The driving halves stay untested, correctly: they acquire a device. And this says nothing about whether the *drawable* looks right in a host, which `scripts/measure-trace` and #38's procedure still own.

## 5. Make the watcher's bookkeeping reachable from a test build

**Issue:** [#93](https://github.com/cboone/fosforo/issues/93). **Type:** `refactor:`. Small, and it closes a hole that is invisible from inside `zig build test` by construction.

### The gap

`src/gpu/metal/renderer.zig:689` reads `const Watcher = if (shader.live) struct { ... } else struct { ... }`, and `shader.live` is `builtin.mode == .Debug and !builtin.is_test` (`src/gpu/metal/shader.zig:45`). A test binary is a Debug build with `is_test` set, so the test binary always gets the stub. The real `poll` at `renderer.zig:822-869`, including the three counter `fetchAdd` calls at 849, 856 and 865 and the load-bearing rule that `seen` advances before the compile on every outcome, is not compiled into any test binary at all.

A plain `zig build` does type-check it, since that is Debug and not a test, and `smoke-appkit`'s `hotReloadPhase` exercises it. So this is not uncovered; it is uncoverable by the check that runs on every push and on every machine.

### Shape

The decision of what a poll outcome does to the counters, and in what order `seen` moves relative to the compile, is a pure function of an outcome enum and the previous stamp. Extract that, leave the file reading and the `MTLDevice` behind, and test the extracted part unconditionally. This is the same move as item 4 and should cite it.

### Acceptance

- Plant a `poll` that advances `seen` only on success and confirm the extracted test fails, which is the defect the docstring at `renderer.zig:842-846` names and which today only a hand-run `smoke-appkit` would catch.
- Confirm `zig build smoke-appkit`'s hot-reload arms still pass unchanged.

## 6. Run the unit suite in the mode that ships

**Issue:** [#94](https://github.com/cboone/fosforo/issues/94). **Type:** `ci:`.

### The gap

`addTestStep` (`build.zig:489-502`) builds one test artifact from the shared `optimize` value. `standardOptimizeOption` declares no default and the reusable CI workflow passes no `-Doptimize`, so every test this project has ever run has been a Debug build. The shipped CLAP is `--release=fast`, where `std.debug.assert` is a no-op and the safety checks are off.

The concrete cost is that the structural guarantee ADR 0010 asks for is enforced only in a build nobody ships. `process` asserts `fba.end_index == 0` at `plugin.zig:524`, `reset` asserts `self.active`, and `markRenderThread`'s companion assertion in the renderer is debug-only by design. More usefully: the convention that "every trust boundary refuses rather than asserts" is checkable only in a build where the asserts are absent, and no such build has ever run a test.

### Shape

A second `b.addTest` at `.optimize = .ReleaseFast` behind its own step, and a step in the `ci` job beside the existing one. Two things to measure rather than assume before wiring it:

- Whether any existing test depends on Debug-only trapping behaviour. Nothing obvious does. `shader.live` is false in both modes, so the "nothing is read from disk in a test build" assertion holds; `mirror` returns early in both.
- Whether the float tolerances in `src/gpu/palette.zig` survive. Zig does not enable fast-math in ReleaseFast, so they should, and the assertions at 1e-4 and 2% are the ones to watch.

If any test does need to differ by mode, that is a finding worth recording rather than a reason to abandon the step.

### Acceptance

- Both steps green locally and in CI.
- Plant a value that a trust boundary is supposed to refuse and confirm the ReleaseFast run refuses it rather than trapping, which is the property the split exists to make observable.

### What it does not close

The watcher, which is stubbed out in ReleaseFast too. That is item 5.

## 7. Analyze every public declaration, and settle the one with no caller

**Issue:** [#95](https://github.com/cboone/fosforo/issues/95). **Type:** `test:`. Cheap, and it closes a class rather than an instance.

### The gap

`AGENTS.md` records that Zig analyzes lazily per declaration, so a `pub fn` nothing reaches is never type-checked however the file was imported, and that `Ring.read` and `Ring.capacity` were in that state. The class is still open, and there is now exactly one live instance.

A scan of every `pub`, `fn` and `const` in `src/` against `src`, `scripts`, `shaders` and `build.zig` returns one declaration with no reference anywhere: `palette.dominantToTonemapped` (`src/gpu/palette.zig:497`). `src/gpu/palette.zig` carries no `refAllDecls`, so nothing type-checks it in any build. It is not junk: it is the published inverse that `scripts/measure-trace` mirrors when it inverts the dominant channel, so it is part of the display contract with no caller and no test.

One second-order case: `plugin.editorOf` (`src/clap/plugin.zig:147`) is reached only from `src/smoke.zig`, so `zig build test` does not analyze it either.

### Shape

Two parts, and the first is what closes the class:

- Add `testing.refAllDecls(@This())` to the test section of every module that lacks one. Six modules have it; ten do not, including `palette.zig`, `iface.zig`, `measure.zig`, `ring.zig`, `plugin.zig` and `gui.zig`. It forces analysis of every public declaration in a test build at the cost of one line each.
- Give `dominantToTonemapped` the test that makes it mean something: assert it inverts `paletteAt`'s dominant channel across the byte range. That is the executable link between the Zig model and the Python tool that currently exists only as a restated constant, and it belongs with item 8.

### Acceptance

- Plant a type error in `dominantToTonemapped` and confirm `zig build test` now fails, where today it builds clean everywhere.
- Plant one in `plugin.editorOf` and confirm the same.

## 8. Assert the transfer function's defining properties

**Issue:** [#96](https://github.com/cboone/fosforo/issues/96). **Type:** `test:`. Small, and it reaches the claims ADR 0019 rests on.

### The gap

`src/gpu/palette.zig` has 15 good tests covering the sRGB round trip, the knee, the gradients, monotonicity and the decay's composition. Two functions state properties in prose that nothing asserts:

- `tonemap`'s docstring claims it is "equal to exactly one at `white` rather than approaching one asymptotically". `tonemap(w, w) == 1.0`, `tonemap(0, w) == 0`, monotonicity, and the `@min` clamp arm are all unexercised. Its only two calls are incidental.
- `whitePoint` is never called with either of the values its docstring argues about: the `8e5` clamp that the `@max` exists for, and the zero-decay end where "everything above one deposit blows out white". It is reached only indirectly through `resolved`, at two decay values.

`resolved` at zero energy, which must reproduce `background_bytes` and which `checkResolve` asserts against the running shader, is also untested against the model.

### Shape

One test per property, expectations derived from the constants rather than restated. Add `dominantToTonemapped`'s inverse property here rather than in item 7, since it is the same file and the same claim.

### Acceptance

Plant a white point wrong by a factor of ten, which `docs/plans/done/2026-08-30-tonemap-accumulated-energy-through-a-palette.md` records as "arithmetically correct and passes a model-versus-picture comparison, because both sides use it", and confirm the clamp assertion fails where the picture comparison does not. That is the one plant here that closes something genuinely uncovered.

## 9. The remaining cheap assertions

**Issue:** [#97](https://github.com/cboone/fosforo/issues/97). **Type:** `test:`. One issue with a checklist, because splitting eleven small pure tests across eleven PRs is worse than the alternative.

| Target                                       | Where                              | Why it is not covered now                                                                    |
| -------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------- |
| `log.severityName`, all eight arms           | `src/clap/log.zig:113`             | Its only caller returns early under `builtin.is_test`, so no arm runs; a typo ships silently |
| `HostGui.init`, three host shapes            | `src/clap/gui.zig:214`             | Zero tests, while its structural twin `Log.init` has exactly this test at `log.zig:222`      |
| `measure.expectedRow`'s negative rail clamp  | `src/gpu/measure.zig:208`          | The positive clamp is tested at four levels; a sign error in the negative one passes         |
| `displaylink.monotonicNanos`                 | `src/platform/displaylink.zig:117` | On the release hot path since #56, no test; two readings and a monotonicity assert           |
| `plugin.bit()`'s `channel >= 64` arm         | `src/clap/plugin.zig:633`          | The whole reason the function exists; `TestBuses` is fixed at two channels                   |
| `getExtension(null)`                         | `src/clap/plugin.zig:645`          | Tested with four real ids, never null                                                        |
| `audioPortsGet(..., null)`                   | `src/clap/plugin.zig:925`          | Only `index` is varied; the null out-parameter half of the guard is unexercised              |
| The state header's literal wire bytes        | `src/clap/state.zig:217`           | Save, load and the test all use the same `endian`, so flipping it passes all ten tests       |
| `measure.ramp` and `sine` at lengths 0 and 1 | `src/gpu/measure.zig:357,377`      | Degenerate arms exist and are never reached                                                  |
| `iface.ShaderStats` all-zero in a test build | `src/gpu/iface.zig:301`            | A documented invariant with no assertion anywhere                                            |
| `objc.autoresizing`'s two constants          | `src/platform/objc.zig:28`         | Hand-restated AppKit values with no header to check against, unlike `clap/c.zig:69`'s pin    |

Two notes on the entries that are not simply omissions. The state header one is low practical risk under ADR 0001, since every supported machine is little-endian; what it fixes is a test named "save writes the header" that does not pin what `save` writes. And `objc.autoresizing` is in `clap/c.zig`'s position "minus the header symbol that lets that file prove its restatements agree", as its own docstring says, so what it gets is a pin against a careless edit rather than a proof.

### Acceptance

Each row is verified by planting the defect it names. The `severityName` row is the one to plant first, because it is the only one where the current coverage is zero rather than partial.

## 10. Cover the render thread's read side

**Issue:** [#98](https://github.com/cboone/fosforo/issues/98). **Type:** `test:`. Listed last of the code items because it needs a decision, not because it matters least.

### The gap

`Editor.tick` (`src/clap/gui.zig:665`) and `Editor.readWindow` (`:714`) have no unit tests. Between them they are the whole render-thread half of ADR 0010's protocol: the gate refusal, the null-renderer return, the single clock reading used for both the resize and the decay, the `pending.take` to `resize` path, the frame outcome feeding `presented`, and all four paths through `readWindow` including the torn one.

`gui.zig:1329` moves `torn` and `uploaded` with direct `fetchAdd` calls, so the counters read as covered while the code that writes them is not. `smoke-appkit` covers this behaviourally and is required in CI, so this is not unverified; it is unverified by anything that runs without a window server.

### The decision this issue owns

Testing `tick` needs a `Renderer` that does not acquire a GPU. ADR 0013 is explicit that shaping the seam to suit the harness is what `probe` is careful not to do, and that principle applies here with more force, not less. Three candidates:

- A comptime-selected test backend behind `src/gpu/iface.zig`. Most capable, and it puts a second implementation behind a seam whose whole argument is that there is one.
- Split `tick`'s decisions from its calls, so the ordering and the early returns are testable and the message sends are not. Consistent with items 4 and 5, and covers the clock-read-once property, which is the one the docstring argues hardest for.
- Leave it to `smoke-appkit` and record that as the decision.

The recommendation is the second, and the third is a defensible outcome that should be written into ADR 0013 rather than left implied.

## 11. Lint the workflows

**Issue:** [#99](https://github.com/cboone/fosforo/issues/99). **Type:** `ci:`.

`.github/workflows/ci.yml` is 46 KB and nothing checks it. `actionlint` appears in the phase 1 exit criteria in the build plan and in no workflow, so it has been a local step at best. On the `shell`, `python` and `typos` jobs' precedent: Ubuntu, a pinned binary, a committed SHA256, and its own job rather than a step inside an existing one.

Worth folding in while the workflows are open: the deprecation warnings the last run emitted, about `version-file` being an unexpected input to `mlugg/setup-zig` and Node 20 actions being forced onto Node 24.

## Already filed, and not restated here

These are real gaps and each already has an issue. This plan should not duplicate them.

| Issue                                              | Gap                                                                                       |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| [#69](https://github.com/cboone/fosforo/issues/69) | `MTL_DEBUG_LAYER` is the only instrument for two Metal misconfigurations and runs by hand |
| [#77](https://github.com/cboone/fosforo/issues/77) | A hot-reloaded shader's binding indices are checked by nothing                            |
| [#34](https://github.com/cboone/fosforo/issues/34) | The cross-display path has never executed                                                 |
| [#85](https://github.com/cboone/fosforo/issues/85) | Nothing runs `markdownlint`                                                               |
| [#87](https://github.com/cboone/fosforo/issues/87) | A pull request based on anything but `main` runs no CI at all                             |

**[#87](https://github.com/cboone/fosforo/issues/87) is the one that bears on how this program is worked**, rather than on what it contains. `ci.yml`'s `pull_request` trigger carries `branches: [main]`, so a PR targeting anything else runs none of the nine jobs. Every issue here is an ordinary branch off `main` for that reason as much as for the usual one, and none of them should be stacked until #87 is settled. #99 is its natural neighbour: both are workflow changes and both are about a check that is configured, believed to be running, and silently is not.

## Sequencing and contention

The build plan sorts work into three exclusive lanes and one free lane, separated by *why* each resource is exclusive: Logic and the Audio Unit (the filesystem, so not negotiable at all), the install path and a host (a choice, since `CLAP_PATH` works and is deliberately not used), and the GPU and the window server (hardware). Everything else overlaps freely.

**Ten of these eleven are in the free lane.**

| Issues                       | What they run                                  | Lane                                   |
| ---------------------------- | ---------------------------------------------- | -------------------------------------- |
| #90, #93, #94, #95, #96, #97 | `zig build test`                               | Free                                   |
| #89, #92                     | `smoke-trace`: a device, no window             | Free                                   |
| #91                          | A Linux runner, so CI rather than this machine | Free                                   |
| #99                          | Nothing on this machine                        | Free                                   |
| #98                          | Possibly `smoke-appkit`                        | GPU and window server, if it needs one |

That is the property worth acting on: this is a large body of work that takes the host lane from nobody, arriving at a point where the phase 3 chain behind #58 is dependency-serial anyway. The build plan's rule to prefer an unblocked issue in the free lane over a blocked one in an exclusive lane has more to offer with these filed than it did without them.

Order within the program: **#89 first**, because `main` is red. Then #90, which is the largest gap closed by the fewest lines. Then #92, which is the largest gap here and which #93 and #98 both cite. The rest are independent and can be taken in any order.

**Nothing here is blocked.** #92 needed [#57](https://github.com/cboone/fosforo/issues/57), which has merged. What survives is a merge conflict rather than a dependency: #92, #80 and #58 all edit `src/smoke.zig`, so whichever lands second rebases, and the build plan's merge-order table records that as costing nothing but the rebase. They are in different lanes and can be in flight together.

**Do not stack them**, per [#87](https://github.com/cboone/fosforo/issues/87): `ci.yml`'s `pull_request` trigger carries `branches: [main]`, so a pull request based on anything else runs none of the nine jobs. Each of these is an ordinary branch off `main`.

## Out of scope

- **A coverage percentage, or a gate on one.** It would reward exactly the decorative assertions the review identified, of which there are about half a dozen (`descriptor.id` compared against the constant it is assigned from, `TraceUniforms` defaults compared against the constants they are declared as, `0.98 > 0.9`). What is worth having is the audit, not the number.
- **An automated mutation-testing framework.** This is the natural upgrade to planting and there is no mature mutation tester for Zig. #92 is the affordable share of it: it converts the plants that can be expressed as data into tests that re-run, and leaves the ones that need an external instrument as manual obligations.
- **Automated coverage for the Audio Unit.** `auval` cannot enumerate the component and `AudioComponentFindNext` cannot either, so loading it in Logic remains the only test. Nothing here changes that.
- **Automated coverage for the release path.** `assert-distributable-signature`, `build-release-bundles`, `build-installer` and `notarize-installer` are never run by CI, because no runner holds a certificate. Only the ad-hoc negative direction is guarded, which is the right trade and should stay recorded rather than fixed.
- **A golden image.** ADR 0013 has refused this twice on its own terms and the criterion it set, a picture stable enough that the golden does not churn, is still not met while #57, #58 and #59 are ahead.

## Documents this program updates

Every one of these lands **with its issue**, not afterwards, on the same rule that puts an issue's verification in its own branch. A document updated later is a document that describes a state nobody checked.

### ADRs

| ADR                                                          | Issue | What it records                                                                                                                                                        |
| ------------------------------------------------------------ | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [0015](../../adr/0015-adopt-std-io-single-instance.md)       | #90   | The constructor rule gains an executable guard, having been enforced by convention since it was written                                                                |
| [0016](../../adr/0016-verify-the-ring-ordering-with-tsan.md) | #91   | The discipline now covers `Gate` and `Pending`; `renderer.Mailbox` cannot be raced on Linux and what covers it instead; the watcher thread stays outside any sanitizer |
| [0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md)  | #92   | The trace half's judgements are testable without a device, and the plant table has become executable                                                                   |
| [0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md)  | #98   | Whichever way the seam decision goes, including the refusal, which is a valid close for that issue                                                                     |

ADR 0013 is amended twice, by two issues, which is ordinary for it: it already carries six amendments and its own rule is that a superseded sentence stays standing rather than being edited away.

### The build plan

[`2026-07-25-repo-foundation-and-phased-build-plan.md`](2026-07-25-repo-foundation-and-phased-build-plan.md) is updated **once, with this plan**, rather than eleven times:

- "How work is tracked" carries a running count of off-milestone issues. It goes to eighteen, in four groups: the two risks, three deferred phase 3 questions, two checks that are configured and silently do not run (#85 and #87), and these eleven. The count is reasoned under that section's own rule, that a milestone marks what has to close before a phase's exit criteria rather than what is one of its numbered steps, so none of these belongs on one.
- Phase 3 gains a subsection naming this program, on the precedent that puts #62 and #77 in that section under "step: none".
- The lane table's free lane gains ten of the eleven, and its GPU-and-window-server row gains #98 conditionally. That is the substantive change: the free lane now holds more open issues than the two exclusive lanes combined, which is what makes this program startable beside phase 3 rather than behind it.
- The merge-order table records #92 against #80 and #58 as a **merge conflict** over `src/smoke.zig` rather than a dependency, since #57 has merged and discharged the one real dependency this program had.
- The **Verification** table gains the `Unit tests` row it never had, and its `Concurrency` and `CI` rows name what changes them (#90, #91, #94, #89, #99) rather than being rewritten in advance.

### `AGENTS.md`

Left alone by this plan and updated by the issues that change what it describes. Three bullets there will be wrong once their issue lands, and each issue owns its own correction: the `smoke-trace` bullet (#89 and #92), the `src/dsp/ring.zig` bullet naming the canary as this project's only one (#90 and #91), and the `zig build test` bullet on lazy analysis, whose worked example stops being reachable once #95 adds `refAllDecls` everywhere.

That last one is worth stating rather than leaving to be discovered: **#95 retires a documented gotcha's example, not the gotcha.** Zig still analyses lazily; what changes is that this repository no longer demonstrates it. The bullet should be corrected to say so rather than deleted.
