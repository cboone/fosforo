# Promote `smoke-appkit` to required, and retire the precondition that cannot be met

Closes [#72](https://github.com/cboone/fosforo/issues/72).

## Context

`smoke-appkit` carries `gpu.Renderer.liveAccumulationTextures`, which [#55](https://github.com/cboone/fosforo/issues/55) established is the **only** instrument this project has for its largest resource: a leaked `MTLTexture` in `MTLStorageModePrivate` is invisible to `leaks` and to peak RSS both. [#63](https://github.com/cboone/fosforo/issues/63) then refused a peak-RSS slope check partly on the grounds that the counters are the load-bearing leg. That argument leans on a check running under `continue-on-error`, which therefore cannot fail a build, so a leak of roughly 46 MB per cycle today produces a green workflow and a `::notice::` nobody is obliged to read.

Three issues assigned this decision to a fourth that nobody filed ([#19](https://github.com/cboone/fosforo/issues/19), #63, [#69](https://github.com/cboone/fosforo/issues/69)); #72 is that issue.

**The intended outcome:** `zig build smoke-appkit` fails the `smoke` job. `zig build smoke-leaks` does not, and the reason it does not is written down rather than inherited from the half that moved. The workflow is the whole change; no GitHub ruleset moves.

## Decisions taken

| Question                                      | Decision                                           | Why                                                                               |
| --------------------------------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------- |
| Does `smoke-appkit` drop `continue-on-error`? | **Yes**                                            | #19 pre-registered the rule, and 65 runs met it                                   |
| Does `smoke-leaks` follow it?                 | **No**, and the asymmetry is now the argument      | It is the one step whose verdict depends on the runner's own AppKit chatter       |
| Does `timeout-minutes: 2` stay?               | **Yes**, and its role changes from label to budget | It becomes the only thing bounding a wedge below the job's ceiling                |
| Sample across a runner image refresh first?   | **Retired, not ticked**                            | The evidence does not exist and cannot be waited for; instrumentation replaces it |
| Add a required status check to `main`?        | **No**                                             | Out of scope, and separately filed if wanted                                      |

## What the evidence says, measured from the Actions API on 2026-08-29

Every figure came from `/repos/cboone/fosforo/actions/runs/*/jobs` and the job logs, and is quoted the way every `timeout-minutes` in this repository is quoted.

**The AppKit half has never failed.** The `smoke` job has 68 recorded runs: 65 completed, and 3 cancelled by the `cancel-in-progress` concurrency group on three rapid pushes to `ci/improve-ci-coverage`. `Smoke-test the AppKit path` succeeded on **all 65**. It has never failed and never timed out. Durations in seconds, all 65 sorted:

```text
0 1 1 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 3 3 3 3 3 3 3 3 3 3 3 3 3
3 3 3 3 3 3 4 4 4 4 4 4 4 4 4 4 4 5 5 5 5 5 5 5 5
```

Worst case 5 s against a 120 s budget: 24x the slowest run observed.

**#19 pre-registered the decision rule, and it has been met 65 times over.** `docs/plans/done/2026-07-29-gui-smoke-harness-as-a-build-step.md:168`, stated before the result was known so it could not be rationalised afterwards: "if the AppKit half passes on the first run and on one re-run, drop `continue-on-error` in a follow-up". This is that follow-up. That file is quoted and **never edited**.

**The image-refresh precondition is unmet, and waiting is not a bounded wait.** The issue's fourth checkbox asks for a sample "across at least one runner image refresh". It cannot be ticked:

- All 65 runs used one image, `macos-26-arm64` version `20260728.0273.1`, from the job's first run on 2026-07-30 to the latest on 2026-08-29. Thirty days, one image.
- This repository's entire CI history contains exactly one refresh, `20260720.0258.1` to `20260728.0273.1`, between 2026-07-29 and 2026-07-30. It landed the day *before* the smoke job existed, so the job has never crossed an image boundary.
- The issue's claim that the sample spans "the `macos-latest` migration to macOS 26" is therefore false. This repository has never run CI on anything but `macos-26-arm64`; that migration predates its first CI run.
- Upstream, the most recent 30 `actions/runner-images` releases run through 2026-08-25 and contain no macOS release at all.

So the precondition is retired rather than satisfied, and replaced with instrumentation: the notice prints the image, making the first run after a refresh attributable at a glance rather than merely suspicious.

**"Block a merge" is literally false here, which lowers the cost of being wrong.** `main` declares no required status checks. `docs/plans/done/2026-07-29-validate-the-clap-wrapper-built-clap.md:31` records that the `Main` and `PRs` rulesets require a pull request and a Copilot review and name no status checks; `2026-07-29-consistent-display-name-across-clap-and-au.md:80` says the same. Promotion makes the job go red. It gates nothing mechanically, and that is worth recording because ADR 0013's argument against promotion is phrased as though it did.

**The two steps are not symmetric, and the issue treats them as though they were.** This is the whole argument for moving one and not the other:

|                          | `smoke-appkit`                                                                        | `smoke-leaks`                                                         |
| ------------------------ | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Fails on                 | its own assertions, plus the window server                                            | the same, plus the runner's own AppKit chatter                        |
| Judged against           | `framesPresented`, `windowsUploaded`, `liveWindowBuffers`, `liveAccumulationTextures` | the class prefixes at `scripts/smoke-leak-check:123` and a byte bound |
| Environmental dependency | binary: a window server, or not. Answered 65/65                                       | open-ended: whatever the image's frameworks leak                      |

`PLUGIN_OWNED` is `^(NSView|CALayer|CAMetalLayer|IOSurface|IOGPU|_?MTL|AGX)`. Several of those name classes AppKit, CoreAnimation and the window server allocate on their own account, so an `IOSurface` or `NSView` leaked by a framework fails the leak step with nothing here being wrong. That is ADR 0013 line 41's scenario exactly, and it applies to the leak step and not to the AppKit one.

The byte figures say the same from the other side. Across the 9 completed leak runs, in order: 18656, 18816, 14080, 18816, 14080, 9728, 18624, 18624, 18624. Low 9,728 against high 18,816.

> **Quote this as a ratio in both places, not as a percentage.** `scripts/smoke-leak-check:116` computes its "25% spread" as `(max-min)/max`; the naive `(max-min)/min` gives 93% and is not the same measure. Like-for-like: the first three runs were **1.34x** (25%), nine runs are **1.93x** (48%). The bound's low-end headroom moves with it, from the script's stated 74x to **107x**.

The bound of 1,048,576 absorbs this without effort, the worst figure being 1.8% of it, which is the looseness the bound was bought for. But a number moving by a factor of two between runs on identical code is the runner's number, not this project's.

**The job's ceiling holds and does not move.** Whole-job wall time across the 65 successful runs tops out at **98 s** against the 480 s ceiling: 20%, well inside the 75% criterion. `ci.yml:148` records "58s max over 10 runs", taken the day before the leak step landed, so it was already a figure for a job that no longer existed. The `Smoke-test the GPU path` step is what grew, to 69 s, because it pays for building the harness. Leak step durations: 23, 23, 24, 24, 25, 25, 25, 28, 28 s against a 180 s budget.

## A consequence worth stating before it surprises someone

`Cycle the editor under leaks` carries `continue-on-error: true` and **no `if:` condition**. Today an AppKit failure cannot stop it, because `continue-on-error` keeps the job out of a failed state. Once `smoke-appkit` is required, a failing AppKit step will *skip* the leak step, and the notice will read `leaks: skipped`.

That is correct rather than a regression: it is `scripts/smoke-leak-check`'s own first assertion, "the harness itself passed, because a leak report over a failed run means nothing", enforced one level up by the workflow. It needs saying because the notice's wording changes on exactly the runs anyone would be reading it.

## The changes

### `.github/workflows/ci.yml` — the only behavioural change

The decision is one deleted line at `:195`:

```yaml
      - name: Smoke-test the AppKit path
        id: appkit
        timeout-minutes: 2
        run: zig build smoke-appkit
```

The notice at `:228-238` gains the runner image. `ImageOS` and `ImageVersion` are set by the runner images rather than by Actions and are **undocumented**, so both carry defaults: an unset variable must not take down the step that reports the leak figures, and a notice reading `unknown` is itself a finding.

```yaml
          echo "::notice::AppKit smoke half: ${{ steps.appkit.outcome }}; leaks: ${{ steps.leaks.outcome }}; runner image: ${ImageOS:-unknown} ${ImageVersion:-unknown}"
```

with a matching `Runner image:` line in the step summary above the leak fence.

Four comment blocks are rewritten, since in this repository the comments carry the argument:

- **`:120-131`**, the "gated differently" list: `appkit` becomes Required, and the block gains the asymmetry as the reason `leaks` did not follow.
- **`:148-151`**, the stale ceiling figure: 58 s over 10 runs becomes 98 s over 65, noting the old figure predated the leak step.
- **`:160-167`**, the margin paragraph: records that the leak step's prediction held (98 s, 20% of the ceiling). Also carries an em dash to remove.
- **`:169-174`**, the paragraph that keeps the flag: replaced by the #19 rule quoted in advance, the retired image-refresh checkbox, and "required here means red, not blocked".
- **`:188-192`**, the AppKit step comment: label becomes budget.
- **`:199-201`**, the leaks step comment: "on the same precedent" now dangles off a step that is no longer a label, so it re-anchors on the Metal download.

### `docs/adr/0013-gui-smoke-harness-as-a-build-step.md` — append only

A new `## Amended by issue #72` section after the `#63` one, covering: the rule written before the answer; the retired checkbox and what replaced it; the two halves' asymmetry; required-means-red; and the accepted cost, stated rather than argued away.

**Lines 33, 41 and 153 are left standing.** This directory's rule, set by the #38 amendment, is that in-place edits are for transcription errors and must be disclosed. Line 33 is the decision as taken, with a condition now discharged rather than falsified; line 41 is the counter-argument #72 was weighed against, and erasing it would erase what the decision cost; line 153 is #63's deferral, which the amendment answers. The new section opens by naming all three as superseded, which is what makes leaving them safe.

### Prose that currently calls the AppKit half advisory

- `AGENTS.md` (**the real file**; `CLAUDE.md` is a symlink and is never edited): `:213` the smoke-harness gotcha, `:204` drop "CI-required" from the GPU half, `:236` add `smoke` as the third documented 4x exception and make the label-versus-budget claim conditional on whether a step can fail the job.
- `CONTRIBUTING.md:92-101`: both paragraphs, including the "[#72] is where this gets decided" pointer.
- `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`: the `#72` placement paragraph near `:236`, the working-order sentence at `:353`, and the GUI and Leaks rows of the Verification table at `:415-416`. Re-pad the table: `.markdownlint-cli2.jsonc` pins `MD060` to `"aligned"`.
- `CHANGELOG.md`: amend `:31`, whose final clause asserts a present-tense state that will be false at release, and add a `### Changed` entry.

### Two stale docstrings in source

- `src/smoke.zig:246-247` says "so CI runs this without gating on it". That becomes false.
- `src/smoke.zig:174` and `build.zig:512` both describe the GPU half as the one that *can be* required. Both become half-stale once each half is required for its own reasons. Light touch, same commit.

### `scripts/smoke-leak-check:115-119` — in scope

Its "25% spread" over three CI runs is the figure the ADR amendment's asymmetry argument is built on. Leaving the script at three runs while the ADR quotes nine makes two documents disagree about the same runs, which is the drift #63 re-measured to avoid. Update to nine runs, 1.93x, and 107x low-end headroom.

`scripts/smoke-leak-check:59-64` needs **no** change: it says the leak step runs under `continue-on-error` where nobody opens the log, and every word stays true. It is the one hit a reviewer's `continue-on-error` grep will find that is correct as written, so say so in the PR body.

### Verified as needing no change

`.github/copilot-instructions.md`, `.github/zig.instructions.md`, `README.md`, `docs/adr/README.md`, `typos.toml` (checked: `macos-26-arm64`, `20260728.0273.1`, `ImageOS` and `ImageVersion` all pass), the plan doc's exclusive-resource row at `:335`, and `src/gpu/metal/renderer.zig:396`. Everything under `docs/plans/done/` is a historical record and is quoted, never edited.

## Commits

| #   | Subject                                                                        | Scope                                                           |
| --- | ------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| 1   | `docs: plan promoting smoke-appkit and keeping smoke-leaks advisory (#72)`     | this file                                                       |
| 2   | `ci: re-measure the smoke job against 65 runs on one image (#72)`              | comment-only, zero behaviour change                             |
| 3   | `ci: require the AppKit smoke half, on a rule written before the result (#72)` | **the decision, alone**: one deleted line and its justification |
| 4   | `ci: print the runner image with the smoke notice (#72)`                       | the only runtime-output change, separately revertable           |
| 5   | `docs: record the AppKit promotion and the leak half's asymmetry (#72)`        | ADR 0013, append only                                           |
| 6   | `docs: re-measure the runner's leak spread across nine runs (#72)`             | `scripts/smoke-leak-check`                                      |
| 7   | `docs: stop calling the AppKit half advisory (#72)`                            | `AGENTS.md`, `CONTRIBUTING.md`                                  |
| 8   | `docs: correct the two docstrings that say CI does not gate on this (#72)`     | `src/smoke.zig`, `build.zig`                                    |
| 9   | `docs: close #72 in the build plan and the changelog (#72)`                    | plan doc, `CHANGELOG.md`                                        |

Commit 2 precedes 3 so the decision's diff is not mixed with a measurement refresh. Commit 4 is separate so it can be reverted alone if `ImageOS` turns out not to exist. Commits 2 through 4 touch `ci.yml`, which is not in `paths-ignore`, so the PR's own runs become runs 66 onward on the same image and are the first live exercise of the required step. All commits GPG signed; never `--amend`.

**Concurrent worktree:** `chore/add-build-provenance` also edits `ci.yml`, at `:491` and `:605-617` in the `clap-validator` and `clap-wrapper` jobs. Disjoint from the `smoke` job at `:108-238`, so no conflict, though line numbers shift if it merges first.

## Verification

Locally, before pushing:

```bash
actionlint .github/workflows/ci.yml   # shellchecks the run: blocks, incl. the ${ImageOS:-unknown} expansions
markdownlint-cli2                     # catches MD060 table re-padding
typos
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck
zig fmt --check build.zig src/
zig build test
zig build smoke-gpu
zig build smoke-appkit
zig build smoke-leaks -Dleak-cycles=40
git diff --name-only main...HEAD      # must list neither docs/plans/done/ nor CLAUDE.md
```

All five linters are present at `/opt/homebrew/bin`.

On the first CI run after the PR opens:

1. `smoke` is green, and `Smoke-test the AppKit path` shows no "this step continued on error" annotation. If it is red, that is itself the answer to whether 65 runs were enough, and the notice names the image.
2. **Read the notice for the image.** `ImageVersion` is the load-bearing field, since it is what the 65-run sample is keyed on; `ImageOS` is a short slug and is informational.
3. **If it prints `unknown unknown`, the env vars are absent and the fallback did its job** rather than failing the step. The version stays recoverable from the "Set up job" log group, which always prints `Runner Image` / `Version:`. Commit 4 reverts alone.
4. The step summary still renders the leak fence, with the new `Runner image:` line above it and no stray backticks.
5. The AppKit step duration is still single-digit seconds, so the 24x margin claim holds on runs the comment did not sample.

Re-run the sampling to extend the 65, and record the run numbers so the sample keeps growing under one query:

```bash
gh run list --workflow=ci.yml --limit 400 --json databaseId --jq '.[].databaseId' |
  while read -r id; do
    gh api "/repos/cboone/fosforo/actions/runs/$id/jobs" |
      jq -c '.jobs[] | select(.name=="smoke") | {conclusion,
        steps: [.steps[] | select(.n // .name | test("Smoke-test|Cycle the editor")) |
          {n: .name, c: .conclusion, secs: ((.completed_at|fromdate)-(.started_at|fromdate))}]}'
  done
```

## Out of scope

- **`MTL_DEBUG_LAYER`**, which is #69, and which would be the third gated step that takes the `smoke` job's step-budget margin below 1 and forces the ceiling to move.
- **A server-side required status check on `main`.** That question covers all eight jobs rather than this one step and has never been decided on its merits. File it separately if wanted.
- **The `smoke` job's ceiling**, which stays at 8 minutes: 98 s is 20% of it.
