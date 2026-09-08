# Race the editor's teardown gate under Thread Sanitizer

Issue: [#91](https://github.com/cboone/fosforo/issues/91). Type: `test:`. Item 3 of [the verification-gaps program](2026-09-04-close-the-verification-gaps-in-the-test-suite.md), and the largest of its concurrency items.

## Context

[ADR 0016](../../adr/0016-verify-the-ring-ordering-with-tsan.md) gives `src/dsp/ring.zig` three things: a Thread Sanitizer arm on a Linux runner, a deliberately weakened control arm judged before the real arm's silence is read, and a source canary that fails on the machine of whoever weakened an ordering. Its closing obligation is scoped to that one file.

`Gate` in `src/clap/gui.zig` is in the position `Ring` was in. It is what stands between a host's main thread and memory the render thread is still reading: `Editor.destroy` closes it and then releases the renderer, the view and the display link, and writes eleven plain fields (`gui.zig:445-464`) that `Editor.tick` reads from inside it. Every test of it is single-threaded, and the two that name it say so. `gui.zig:1127` closes an uncontended gate, so `close`'s spin body never executes; `gui.zig:1146` produces "the state a tick mid-frame leaves behind" by calling `fetchOr` in the test body. There is no second thread anywhere in that file, so a `.release` simplified to `.monotonic` passes all 44 tests beside it.

[#90](https://github.com/cboone/fosforo/issues/90) has since given both primitives a source canary (`gui.zig:1175-1204`), and that canary's own comment names this issue as the arm that would prove the behaviour rather than the text. This is that arm.

## The finding that reshapes the issue

**A Thread Sanitizer arm discriminates only where the atomic orders access to _non-atomic_ memory.** TSan builds a happens-before graph and reports two threads reaching one address with no edge between them; two relaxed atomic accesses to the same word are not a race in that model, whatever the ordering.

That rule sorts the three primitives:

| Primitive | Non-atomic memory the ordering protects                                                                                                        | Raceable     |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| `Ring`    | `samples: []f32`, written by one thread and read by the other                                                                                  | Yes, and is  |
| `Gate`    | The editor's resources: `renderer`, `view`, `link`, `meter`, `applied`, and six more plain fields `destroy` writes after `close` returns       | Yes          |
| `Pending` | **None.** The whole message is packed into the `u64` (`gui.zig:167-173`); `take` reads nothing else, and `tick` uses only the value it returns | Predicted no |

So `pending-weakened` as the issue specifies it is predicted to come back **clean**, which would be a vacuous control: the exact failure ADR 0016's control-first assertion order exists to catch, arriving from the other side. That prediction is measured rather than assumed, in stage 7 below, and whichever way it lands is what the ADR amendment records.

The same rule bears on which defect the weakened arm should plant. The issue's table says `enter`'s acquire relaxed. The teardown edge is `leave`'s release paired with `close`'s spin `load(.acquire)`; `enter`'s acquire has no release to pair with on the opening side, because the render thread's first entry is ordered by thread creation instead. So `enter` relaxed is predicted not to race either. Stage 8 plants all five orderings in the real `Gate` and records which do, on ADR 0016's own precedent of a measured table rather than an assumed one.

## Decisions taken

- **Build `Gate` first, then measure `Pending`.** The naive `pending-weakened` arm is written exactly as filed and the sanitizer settles it, so the ADR quotes a verdict rather than this analysis.
- **Two harness binaries, one judging script.** `src/ring_race.zig` stays untouched. `scripts/ring-race-check` is renamed and parameterized rather than copied, so the control-first assertion order has one implementation.
- **`Gate` moves to `src/clap/gate.zig`**, beside the editor lifecycle it guards. It imports nothing but `std`, so the directory costs the Linux build nothing.

`main` carries no branch protection, so no required-check name is at stake and the CI job can be renamed.

## Work

### 1. Extract `Gate` to `src/clap/gate.zig`

Move the struct verbatim, docstring included, and make it `pub`. `gui.zig` gains `const Gate = @import("gate.zig").Gate;`, which leaves the `gate: Gate = .{}` field (`gui.zig:288`), `close` in `destroy` (`:439`) and the reopen (`:477`) unchanged.

Move with it:

- The two pure `Gate` tests, `gui.zig:1127-1159`. The tests that reach it through `Editor` (`:1112`) stay.
- The `Gate` half of the canary, `gui.zig:1188-1203`, reading `@embedFile("gate.zig")`. The `Pending` half (`:1181-1183`) stays in `gui.zig`. The new file needs a `// Tests` banner, since that literal is what `canary.implementation` cuts at.
- Correct the sweep comment at `gui.zig:1031-1040`, which currently explains that `Gate` is absent from the list because it is private.

`gate.zig` carries `testing.refAllDecls(@This()); testing.refAllDecls(Gate);`, per #95's rule that a type with no declarations today is named anyway.

### 2. `close` reports the spin count

Acceptance criterion 3 asks that `Gate`'s spin body is genuinely entered, "confirmed by a counter the harness prints, so a `close` that never waited is visible as a vacuous pass". Nothing outside `Gate` can observe that: a holder that waits for a "closing" flag before leaving makes the spin _less_ likely, not more, and no arrangement of the harness's own atomics can see inside the loop.

So `close` returns the number of spins it performed. One word, no new state, and the canaried lines are unchanged. Call sites become `_ = self.gate.close();` at `gui.zig:439` and in the moved tests.

### 3. The harness, `src/gate_race.zig`

On `src/ring_race.zig`'s pattern: `main(init: std.process.Init.Minimal) u8`, arm selected from argv, exit codes 0 ran-as-expected, 1 ran-and-failed, 2 called-wrong, and a `report` that prints counters and an `ok` line to stderr.

A gate is one-shot, so a round is a fresh gate. Per round:

```text
holder (spawned):  gate.enter()
                   inside.store(true, .monotonic)
                   read payload, hold_spins times      non-atomic reads
                   gate.leave()                        the release under test

closer (main):     spin until inside.load(.monotonic)
                   spins = gate.close()                acquire, then the spin load
                   write payload                       non-atomic writes
                   join
```

**Three details are load-bearing and each looks incidental.** The `inside` flag is `.monotonic` on both sides deliberately, because an acquire/release pair there would supply the very happens-before edge under test and hide a weakened `leave`, which is the same trap `ring_race.zig`'s one-shot warm-up exists for. The payload is written **before** `join`, because `join` is itself an edge and joining first would make every arm clean. And the holder spins a fixed count after signalling rather than waiting for the closer, so contention is the common case rather than the rare one.

Counters printed: `rounds`, `contended` (rounds where `close` spun at least once), `spins`. `contended` is the progress field the script judges, standing where `validated` stands for the ring.

Arms: `gate` against the real `src/clap/gate.zig`, and `gate-weakened` against a replica with one ordering relaxed. **Which ordering the replica relaxes is chosen from stage 8's measurement**, not from the issue's table.

### 4. Generalize the script

`git mv scripts/ring-race-check scripts/race-check`, taking four positional arguments:

```bash
scripts/race-check <binary> <clean-arm> <weakened-arm> <progress-field>
```

Everything that makes it correct is preserved and generalized rather than rewritten: `RACE_MARKER`, `TSAN_OPTIONS='halt_on_error=0 exitcode=66'`, the weakened arm judged first with `set -e` aborting before the clean arm is read, `arm_status` recorded and not obeyed (TSan's `exitcode=66` replaces the process status), the explicit `mktemp` template, and exit codes 64/65/66. `MINIMUM_VALIDATED` becomes `MINIMUM_MET`, keyed on the field name passed in.

Both harnesses unify their line prefix to `race:` so the greps take one shape. That is the only change to `src/ring_race.zig`.

### 5. `build.zig`

Factor `addRingRaceStep` into one `addRaceStep` taking the step name, description, module root, artifact name and the three script arguments, called twice. Both calls stay **above** the `if (target.result.os.tag != .macos) return;` at line 42, which is the wall `b.dependency("objc", ...)` puts there.

Every setting carries forward unchanged and none is optional: `resolveTargetQuery(.{})` rather than the shared target, whose `os_version_min` of 11.0 resolves on Linux to a kernel version no kernel satisfies; `link_libc = true`, so TSan intercepts `pthread_create`; `sanitize_thread = true` on the module and `use_llvm = true` on the executable, without which the runtime links and no instrumentation is emitted; `.Debug`; `stdio = .inherit` and `has_side_effects = true`. On a non-Linux host both steps keep `fail.step.dependOn(&exe.step)`, so the harness still type-checks here even though it cannot run.

### 6. CI

Rename the `ring-race` job to `race` and give it a second step. One job, one runner, one Zig cache: the sanitizer runtime is built from compiler-rt once and the second binary reuses it.

**Re-measure `timeout-minutes` rather than keeping 6.** The current value is 4x an 88s cold maximum over 8 runs, and a second instrumented binary changes the numerator. Measure on this pull request's own runs, per #17, and record the figure and sample size in the comment beside it.

**Measured at 84s max over 8 runs with both harnesses**, against the ring's 88s alone, so the ceiling stays at 6. The second binary is not what this job spends its time on: warm runs land at 40s to 44s and cold ones at 74s to 84s, because the sanitizer runtime is built from compiler-rt once per cold job and both binaries reuse it. That is also the argument for one job rather than two.

### 7. Measure `Pending`

Ran as a 2x2 rather than the single arm the issue specifies, because a bare negative could not be told from a broken instrument:

| Arm                        | Rides alongside the word | `post`       | Races | Took |
| -------------------------- | ------------------------ | ------------ | ----- | ---- |
| `pending`                  | no                       | `.release`   | 0     | 2268 |
| `pending-weakened`         | no                       | `.monotonic` | **0** | 548  |
| `pending-payload`          | yes                      | `.release`   | 0     | 55   |
| `pending-payload-weakened` | yes                      | `.monotonic` | **2** | 2    |

Row four is what makes row two mean something. **Clean, as predicted**, so both arms were dropped: `Pending` keeps its canary and its unit tests, `gpu.Size` never moved, and the decision this issue owns is answered by refusal rather than by a new module. The arms were temporary and are not in the tree.

**The first attempt at row three and four was wrong**, and usefully: it wrote the payload before spawning the taker, and thread creation is itself a happens-before edge, so both payload arms came back clean and the control proved nothing. Writing it after the spawn and before the first post is what makes `post`'s store the only thing that can order it.

### 8. Plant the defects in the real `Gate`

Acceptance criterion 2, on ADR 0016's reasoning that "a control that models the defect is not the subject exhibiting it". Plant each of `Gate`'s five orderings in turn against the `gate` arm and record the verdict:

| Planted                                                          | Predicted | Measured  |
| ---------------------------------------------------------------- | --------- | --------- |
| `enter`'s `fetchAdd(one_tick, .acquire)` to `.monotonic`         | clean     | clean     |
| `enter`'s refusal `fetchSub(one_tick, .release)` to `.monotonic` | clean     | clean     |
| `leave`'s `fetchSub(one_tick, .release)` to `.monotonic`         | data race | data race |
| `close`'s `fetchOr(closed, .acquire)` to `.monotonic`            | clean     | clean     |
| `close`'s `load(.acquire)` to `.monotonic`                       | data race | data race |

The predictions were stated so they could be wrong; all five held. Run ids are in ADR 0016's amendment. Both races were reported against the payload write at `src/gate_race.zig:242`.

Planted against a committed baseline on a throwaway branch, since `git restore` would otherwise revert the fix along with the plant, and one line at a time rather than by find-and-replace, which rewrites the canary's own string literals along with the code and leaves the suite green.

## Verification

None of this runs on this machine, which is the whole of ADR 0016's shape: `aarch64-macos` links a `-fsanitize-thread` binary that exits before `main`. So the harness is compile-checked locally and judged in CI.

```bash
zig build test                      # the moved tests and the moved canary
zig fmt --check build.zig src/
zig build                           # the .clap still builds with Gate extracted
zig build-exe src/gate_race.zig -fsanitize-thread -lc -target x86_64-linux-gnu
zig build gate-race                 # refuses on this host, naming the CI job
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck
typos && markdownlint-cli2          # never with --fix
```

`.editorconfig` needs no new entry: `scripts/race-check` is a rename of a file already listed, and the section names each extensionless script directly.

Then, in CI. All met on [34273378203](https://github.com/cboone/fosforo/actions/runs/34273378203):

- Both weakened arms flagged, each judged before its clean arm is read. One report apiece.
- `contended` well clear of 1 on the `gate` arm: **195 of 256 rounds, 810 spins**, so the spin body was demonstrably entered rather than assumed. Later runs read 202 and 1344.
- The `ring` arm unchanged in substance: `reads=4096 validated=4096 torn=0 published=1047552`, as before, the transcript differing only in the `race:` prefix.
- The three harness canaries each verified by planting what they forbid and watching the named test fail, and the gate's canary by relaxing `leave` and watching it fail while both behavioural tests still passed, which is the argument for having it.

## Documents this updates

Landing with the issue, not afterwards.

- **[ADR 0016](../../adr/0016-verify-the-ring-ordering-with-tsan.md)**, amended: `Gate` is covered and how; the general rule that a TSan arm needs non-atomic memory to order; `Pending`'s measured verdict; `renderer.Mailbox` carries `Pipelines`, which are Objective-C objects, so it cannot be raced on Linux at all and has a canary instead; and the watcher thread stays outside any sanitizer, stated rather than left to be rediscovered.
- **`AGENTS.md`**: the commands block gains `gate-race`; the structure block gains `src/clap/gate.zig` and `src/gate_race.zig` and renames `scripts/ring-race-check`; the `src/dsp/ring.zig` gotcha bullet and the non-negotiables list both name where the canaries live.
- **The build plan**, [`2026-07-25`](2026-07-25-repo-foundation-and-phased-build-plan.md): the source layout at line 116, the `Concurrency` row of the Verification table at line 499, and the #91 row at line 423.
- **[The verification-gaps plan](2026-09-04-close-the-verification-gaps-in-the-test-suite.md)**, item 3: mark it landed, and correct two claims it makes that are false on `main`. It cites the ADR 0005 comptime block at `iface.zig:430`, which is at 486; and it says `Size` is "already used by `gui.zig`, `view.zig` and the renderer", where `src/platform/view.zig` names `Size` nowhere and passes geometry as bare `u32`.

## What this does not close

- **`renderer.Mailbox`**, for the reason above. Item 6 of the program covers what is testable about it.
- **The watcher thread**, which stays outside any sanitizer.
- **A weakening that survives its own canary.** A global find-and-replace rewrites the canary's string literals along with the code, which ADR 0016 accepts because the sanitizer job catches what the canary cannot. That trade now holds for `Gate` as well, which is the point.
- **`Pending`, if stage 7 lands as predicted.** It keeps a canary and eight unit tests and acquires no behavioural check, and the ADR says so rather than leaving the gap implied.
