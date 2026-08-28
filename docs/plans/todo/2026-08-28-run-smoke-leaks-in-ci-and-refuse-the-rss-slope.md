# Run smoke-leaks in CI, and refuse the peak-RSS slope check

Issue: [#63](https://github.com/cboone/fosforo/issues/63). Branch: `ci/improve-ci-coverage`.

## Context

`zig build smoke-leaks` is the only check in the verification table that has never run anywhere but a keyboard. Nothing in CI runs `leaks` and nothing in CI measures memory. That was defensible while an editor held about 96 KiB of window buffers; [#55](https://github.com/cboone/fosforo/issues/55) took it to roughly 33 MB per open editor at the default geometry and about 59 MB after the resize `oneCycle` performs, which changes what a leak costs by two and a half orders of magnitude.

#63 proposed two steps in the existing `smoke` job. Planning found three things that change what should land, and the issue's own update anticipated the shape of the first without following it through.

**The peak-RSS slope check is refused.** The issue's argument for it rests on one measurement: dropping the window ring's release in `Renderer.deinit` moves peak RSS from 47.7 MB to 57.7 MB while `leaks` reports clean. That is true, and it is not the whole story, because `src/smoke.zig:311` already asserts `gpu.Renderer.liveWindowBuffers() == 0` after the cycle loop, inside a `smoke-appkit` step that already runs on every push. The same planted defect fires that assertion at 10 cycles, exactly, by name, for free. Subtract that row and what is left is argued below; it does not pay for two minutes of runner time on every push.

**`smoke-leaks` runs at 40 cycles in CI, not 400.** The harness is bound by display refresh rather than by CPU, and the runner refreshes at roughly half the rate of the machine the 51.8 s figure was taken on. Separately, `scripts/smoke-leak-check` justifies its 400 with an argument about total leak counts that its criterion does not use.

**The leak check's criterion may be narrower than the issue assumes**, and that is worth measuring before its coverage is written down.

## Decisions taken

| Question | Choice | Why |
|----------|--------|-----|
| The peak-RSS slope check | **Not shipped.** The refusal and its reasoning are recorded instead | Its one demonstrated catch is already caught in CI by `liveWindowBuffers()`, and it is blind to the storage class #55 introduced |
| `smoke-leaks` cycle count in CI | 40, through a new `-Dleak-cycles` build option, with 400 kept as the by-hand default | The criterion fires at any count; 400 costs roughly ten times as much on a runner that is not the machine it was measured on |
| The class-prefix filter | Measure whether it sees a plain `c_allocator` leak, and bound total leaked bytes if it does not | ADR 0013's planted-leak rule has only ever been applied to Metal resources, and this is the gap the refused RSS check was the only other answer to |
| Gating | `continue-on-error: true` | ADR 0013: it depends on the AppKit half, and promoting a GUI check to required is a separate decision |
| Reporting | Figures emitted on **every** run, green ones included | The sample is the point. A number you have to open a passing job's log to read is a number nobody collects |
| `MTL_DEBUG_LAYER` | Out of scope | [#69](https://github.com/cboone/fosforo/issues/69) owns it, including the `AGENTS.md` pointer correction. Do not touch `AGENTS.md:184` |
| Promoting `smoke-appkit` to required | Out of scope, but **file the issue** both #63 and #69 promise exists and neither created | `liveAccumulationTextures` is the project's only instrument for its largest resource and currently cannot fail a build |

## Why the RSS slope check is refused

Coverage of each plausible planted defect, by instrument. `L` is `leaks` through `scripts/smoke-leak-check`; `R` is the proposed RSS slope; `W` and `A` are `liveWindowBuffers` and `liveAccumulationTextures`, both asserted by `smoke-appkit` in CI today; `T` is `zig build test` under `testing.allocator`.

| Planted defect | L | R | W | A | T |
|----------------|---|---|---|---|---|
| Window ring built and forgotten (`Renderer.deinit`) | no | yes | **yes** | no | no |
| `releaseWindows` decrements without releasing | no | **yes** | no | no | no |
| Accumulation pair never handed back | no | no | no | **yes** | no |
| `releaseAccumulation` decrements without releasing | no | no | no | no | no |
| Command queue or pipeline state release dropped | **yes** | no | no | no | no |
| `history` ring not freed in `plugin.destroy` | **unknown** | yes | no | no | yes |
| A future uncounted *shared*-storage buffer | no | **yes** | no | no | no |
| A future uncounted *private*-storage texture | no | no | no | no | no |

Three things follow, and the third is the one that decides it.

**The row the issue cites is already covered.** `W` catches it at 10 cycles with an exact count and a named error, forty times more cheaply than a 440-cycle slope measurement with two calibrated constants.

**The residual unique coverage is the failure this project has already declined to chase.** `AGENTS.md:204` says of the counter: "a `releaseWindows` that stopped releasing would still balance; what it catches is the realistic failure, a path that builds a ring and forgets it." Buying two minutes per push to guard the unrealistic half is not a trade this repository makes anywhere else, and the identical hole for the accumulation textures is not covered by RSS either, so the guard would be half-applied by construction.

**Its sensitivity is proportional to its cost, and it is blind to the resource that now dominates.** The margin arithmetic: baseline growth is 18.8 MB across 40 to 400 cycles, run-to-run spread is 1.5 MB per endpoint, so the standard deviation on the difference is about 2.1 MB and a five-sigma ceiling sits near 30 MB. The smallest per-cycle leak that clears it is 0.031 MB, against a leaked ring's roughly 0.048 MB of *resident* pages per cycle — a margin of 1.5x. Halving the span to 40/200 doubles the detectable floor to 0.070 MB per cycle, which is above the defect, so the check cannot be made cheaper without ceasing to work. And a leaked accumulation texture moves peak RSS by 0.2 MB while leaking nearly two gigabytes, so the instrument does not see the storage class #55 introduced at all.

The honest summary, and the sentence the ADR amendment should carry: **the RSS slope is a calibrated instrument for a defect an uncalibrated one already catches, and it is blind to the defect nothing else catches.**

## The cycle-count finding

`scripts/smoke-leak-check:52-55` justifies 400 like this: "At 400 a per-cycle leak more than doubles the total; at 10 it would sit inside the run-to-run variation." **That is an argument about totals, and the script does not judge the total.** It prints the summary line and then greps class names against `PLUGIN_OWNED`; a single leaked `AGXG17XFamilyCommandQueue` fails at any cycle count. #63's own measurement agrees from the other side: 20 and 60 cycles produced identical reports (212 leaks / 14,640 bytes), so the variation 400 was chosen to overcome is not there.

What 400 genuinely buys is repetition of the rare paths inside `oneCycle`: the every-fourth-cycle teardown through `plugin.destroy`, and the four resizes including the wrapped-negative height REAPER sends. **At 40 cycles those run 10 and 40 times respectively**, which is enough for a path that either works or does not.

Cost, projected rather than measured, and to be replaced with a runner figure: the harness waits on vsync roughly 13 times per cycle post-#55 plus a 50 ms `hide` sleep, so a cycle costs about 158 ms at 120 Hz and about 267 ms at 60 Hz. That puts 400 cycles at roughly two minutes on the runner before `leaks` overhead, and 40 cycles at roughly 12 to 25 seconds. The `smoke` job goes from a measured 58 s worst case to roughly 80 s rather than to five minutes, its 8-minute ceiling does not move, and [#69](https://github.com/cboone/fosforo/issues/69) can land on the same job afterwards without the ceiling conversation arriving twice.

## The heap-leak measurement

`PLUGIN_OWNED` is `^(NSView|CALayer|CAMetalLayer|IOSurface|IOGPU|_?MTL|AGX)`, matched against the token `leaks` writes inside an angle bracket. The plugin allocates through `std.heap.c_allocator` (`src/clap/plugin.zig:213`), so its blocks are on the malloc heap and `leaks` will find them — but a block carrying no Objective-C class is not written as `<ClassName 0xADDRESS>`, so the extracted token may not be one the allowlist can match. **If that is so, the check being added to CI reports the project's own heap leaks as clean**, and ADR 0013's planted-leak rule has never been applied to a plain allocation.

The experiment: drop `self.history.deinit(...)` from `plugin.destroy` in `src/clap/plugin.zig`, run `zig build smoke-leaks -Dleak-cycles=40`, and read the verdict.

- **Reported clean** — add a total-leaked-bytes band beside the prefix check, provisionally at a stated multiple of the measured baseline, and re-plant to confirm the band fires. The totals are stable at a fixed cycle count by #63's own measurement, and the planted leak is 1 MiB per cycle against a baseline near 14.6 KB, so the band has five orders of magnitude of margin and does not need to be tight to work.
- **Reported as a leak** — record which token matched, and state in `AGENTS.md` that the filter reaches plain allocations as well as Objective-C classes. No code change.

Either way the answer is written down, because "what each instrument can and cannot see" is the issue's fourth checkbox and this is the part of it nobody has checked.

## What lands, in commit order

### 1. `feat: let the leak check's cycle count be set from the build (#63)`

`build.zig`, inside `addSmokeSteps` (lines 363-396). A `b.option(u32, "leak-cycles", ...)` consumed by the `smoke-leaks` step, appending `--cycles N` before `check.addFileArg`. Absent the option, pass nothing and let `DEFAULT_CYCLES` in the script remain the single source of the default; the build must not restate 400.

The comment at lines 376-378 says the steps offer no cycle count and must be corrected. Follow `signClapBundle`'s `b.option` shape (line 293) for the option's declaration and its help text.

### 2. `fix: judge total leaked bytes as well as class prefixes (#63)`

`scripts/smoke-leak-check`. Conditional on the measurement above; skip this commit and say so if the filter already sees the planted leak.

Also, unconditionally: **split the exit codes.** `E_DATAERR=65` currently covers three different worlds — the harness failed, `leaks` produced nothing parseable, and something leaked. For a step that cannot block a merge the exit code is the whole message, and collapsing "the instrument did not run" into "we leaked" is exactly the confusion ADR 0013's assertion order exists to prevent. Add `E_UNAVAILABLE=69` for the first two and keep 65 for the verdict, updating the header's exit-code block.

### 3. `ci: run smoke-leaks on every push, at a cycle count the runner can afford (#63)`

`.github/workflows/ci.yml`, the `smoke` job (lines 148-179). A step after `Smoke-test the AppKit path`:

- `id: leaks`, `continue-on-error: true`, a step-level `timeout-minutes` as a *label* on the Metal-download precedent rather than a budget, running `zig build smoke-leaks -Dleak-cycles=40`.
- Extend the existing `Report whether the runner granted a window server` step (lines 176-179) to carry both outcomes, and add the leak figures to it. The notice is machine-queryable through the check-runs annotations API, which is how the sample gets collected without opening thirty logs.
- The figures go out on **every** run, not `if: failure()`. The two `$GITHUB_STEP_SUMMARY` blocks at lines 448-462 and 560-574 are failure-only because their subject is a failing path; here the green runs are the measurement.

The comment block above the job (lines 108-147) needs its rationale extended to say why a third gated step is here and what it covers.

### 4. `ci: re-measure the smoke job and set its ceiling from what it now costs (#63)`

The comment at lines 131-140 records "38s max over 3 runs". It is now **58 s max over 10 runs (25, 28, 29, 35, 35, 38, 38, 40, 49, 58)**, measured from the Actions API the way `docs/plans/done/2026-07-29-tighten-ci-job-timeouts.md` prescribes, before this change lands at all. Replace the figure, then re-measure after the new step has run and apply the repository's rules: roughly 4x the observed maximum, and no job above 75% of its ceiling. The expectation is that 8 holds; raise it only if a measurement says so, and rewrite the "2.7x the step budgets" sentence if the step labels no longer sum inside it.

### 5. `docs: say what each of the leak instruments can and cannot see (#63)`

`AGENTS.md`. `CLAUDE.md` is a symlink and needs no separate edit. Invoke `write-markdown` first.

- The scope table the issue's fourth checkbox asks for, since the whole finding is that the instruments' apparent ordering is backwards. It must include the class-prefix limitation, which is currently undocumented and is the thing a reader would most naturally get wrong.
- `smoke-leaks` now runs in CI, at 40 cycles, under `continue-on-error`, with 400 as the local default; and `-Dleak-cycles` in the `## Development` command list.
- Leave line 184 alone. The `MTL_DEBUG_LAYER` pointer belongs to #69.

### 6. `docs: record that the peak-RSS slope check was refused and why (#63)`

- `docs/adr/0013-gui-smoke-harness-as-a-build-step.md`: an appended `## Amended by issue #63` section, never an edit in place. It records that `smoke-leaks` became a CI step; that the RSS slope was considered and refused, with the coverage table's reasoning and the sentence at the end of that section above; and, if the measurement found it, that the leak filter's criterion reaches or does not reach plain allocations. The last of these extends the ADR's own rule from "a Metal resource which is not a buffer" to any new allocation.
- `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`: the Leaks row of the Verification table (line 400), which names only `liveWindowBuffers` and says nothing about CI; the exclusive-resource row at line 319, which lists RSS as a contender for the GPU and window server; and lines 326, 337 and 339, whose subject is #63's RSS threshold and its ordering behind #55.
- `CHANGELOG.md`, under Unreleased.

`.editorconfig` needs **no** change, because no new script lands. That trap is only armed by a new file in `scripts/`.

## Verification

### Local, each with the instrument that must fire

Run these serially. They contend for the GPU and the window server, and `AGENTS.md:173` is explicit that a second workload perturbs them.

| Planted defect | Command | Must fail with |
|----------------|---------|----------------|
| Nothing (control) | `zig build smoke-leaks -Dleak-cycles=40` | passes, naming the count and the totals |
| Command queue release dropped in `Renderer.deinit` | same | a leaked `AGX…CommandQueue` in the offender list |
| `self.history.deinit` dropped from `plugin.destroy` | same | the measurement above; the band if one lands |
| Window ring release dropped in `Renderer.deinit` | `zig build smoke-appkit` | `WindowBuffersLeaked` — the positive control for the refusal |
| Accumulation release dropped | `zig build smoke-appkit` | `AccumulationTexturesLeaked` — likewise |

The last two are not incidental. They are what makes the refusal a measurement rather than an assertion: if either fails to fire, the argument for dropping the RSS check collapses and this plan is wrong.

Also confirm `-Dleak-cycles` is honoured in both directions: the script's `--cycles` validation rejects a non-positive value, and a bare `zig build smoke-leaks` still runs 400.

### On the runner

The step is `continue-on-error`, so the first runs are the measurement rather than a gate.

- Confirm the step runs at all, and that the notice carries the figures on a **green** run.
- Collect the leak totals across at least five green runs spanning at least two calendar days, which is the bar a runner-image refresh makes necessary. The runner's AppKit chatter is not this machine's, so the local 14,640-byte baseline is not the one a band should be set against.
- Record the job's duration across the same runs and check it against 75% of the ceiling — 360 s against 8 minutes — before #69 lands on the same job.
- Set any provisional constant from that sample in a follow-up commit on this branch, quoting the runs in the idiom the workflow already uses.

## Out of scope

- **The peak-RSS slope check**, refused above. The issue's title promises it, so post a comment on #63 recording the decision and its reasoning rather than letting the title stand unexplained.
- **`MTL_DEBUG_LAYER`**, which is [#69](https://github.com/cboone/fosforo/issues/69), including the `AGENTS.md:184` pointer.
- **Promoting `smoke-appkit` to required.** Both #63 and #69 say this belongs to another issue and neither filed one; file it. The finding worth carrying into it: `liveAccumulationTextures` is the only instrument for the project's largest resource, it runs in CI, and it cannot fail a build, so a 46 MB-per-cycle leak today produces a green workflow.
- **Running `leaks` on the clap-wrapper bundle.** No equivalent harness drives the AUv2 path.

## Risks to watch at the keyboard

- **The projected costs are inferences, not measurements.** The vsync-bound model fits the observed step timings and the local 51.8 s figure, and it has not been checked directly. Time `zig build smoke-leaks` on this machine today before quoting anything, since that figure predates #55's four resizes as well.
- **A band on total leaked bytes is a threshold on a machine nobody has a shell on.** It has five orders of magnitude of margin against the leak it is for, which is what makes it safe where the RSS ceiling was not; keep it that loose rather than tightening it to look precise.
- **Three gated steps in one job is how a project acquires permanent amber.** The notices carrying figures on green runs are the mitigation, and they are load-bearing rather than decorative.
- **The refusal must not read as "leaks covers this".** Every place the RSS check is declined has to name what stays uncovered: a `release` that stops being sent while the counter still balances, in either resource.
