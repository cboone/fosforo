# Run CI on stacked pull requests

Closes [#87](https://github.com/cboone/fosforo/issues/87).

## Context

`.github/workflows/ci.yml:14` carries `branches: [main]` on its `pull_request` trigger. That filter reads the pull request's **base** ref, so a pull request targeting anything but `main` matches nothing and the workflow's eight jobs never dispatch: `ci` (the reusable workflow, which expands into `Test`, `Format`, `Build` and two entries that always skip), `shaders`, `smoke`, `ring-race`, `shell`, `python`, `clap-validator` and `clap-wrapper`. **Eight declared jobs are twelve names in a rollup and ten executions**, which is worth pinning down here because this project's prose said "nine" for months and that matched no reading of the file. Nothing anywhere says so, and the pull request page reads green.

This is the third instance of one shape, a check that is configured, is believed to be running, and silently is not, after [#28](https://github.com/cboone/fosforo/issues/28) and [#85](https://github.com/cboone/fosforo/issues/85). The build plan names the group at `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md:245`.

**The filter was never a decision.** `git blame -L 3,21 -- .github/workflows/ci.yml` returns `b3108ede` for every line of the trigger block: "ci: add macOS CI and secret scanning", 2026-07-25, the commit that founded CI here. `workflow_dispatch` was added later; the `branches:` keys have not been touched since. The three sibling workflows written afterwards all carry a bare `pull_request:`, and that asymmetry is the whole bug:

| Workflow                           | `push`                              | `pull_request`                     |
| ---------------------------------- | ----------------------------------- | ---------------------------------- |
| `.github/workflows/ci.yml:4`       | `branches: [main]` + `paths-ignore` | **`branches: [main]`** + same list |
| `.github/workflows/typos.yml:4`    | `branches: [main]`                  | no branch filter                   |
| `.github/workflows/gitleaks.yml`   | `branches: [main]`                  | no branch filter                   |
| `.github/workflows/trufflehog.yml` | `branches: [main]`                  | no branch filter                   |

**[#86](https://github.com/cboone/fosforo/pull/86) does not demonstrate the gap, and the issue overstates it by one word.** The issue says #86 "would have skipped almost everything anyway"; it would have skipped **everything**. Its four files are `AGENTS.md`, `README.md` and two under `docs/`, every one of them matched by `paths-ignore`, so dropping the branch filter would not have changed that pull request's outcome at all. #86 is evidence that the configuration is wrong, read off the configuration; it is not evidence read off a result. The failure the fix is actually for is a stacked branch **carrying code**, which would merge into its parent with zero verification, leaving the parent's own pull request the first thing to build it, by which point the stacked commits are already in. Nothing here has hit that yet, and the acceptance test below is what produces the missing result.

## The cost of widening, measured

The issue asks for this before anything is widened, on the grounds that `ci.yml` is the expensive workflow. Three measurements, and the first dissolves the money question entirely.

**Runner minutes are free.** `GET /repos/cboone/fosforo/actions/runs/{id}/timing` returns `billable.MACOS.total_ms = 0` over nine macOS jobs and `billable.UBUNTU.total_ms = 0` over three Ubuntu jobs, on every run sampled. The repository is public and every runner is standard. The build plan already resolved this at `2026-07-25-repo-foundation-and-phased-build-plan.md:510`, so the cost bullet was arguing against a figure this project had settled.

**A run is bounded and short.** Over the last 100 completed `ci.yml` runs: 74 `pull_request` at a median of 103 s and a maximum of 224 s wall clock, and 26 `push` at 94 s and 199 s. The two jobs the issue singles out are the same story: `smoke` ran 75–180 s across five runs sampled, and `clap-wrapper`, which fetches the AudioUnit SDK through CMake with no cache, ran 76–94 s.

**The frequency is one.** Of 47 pull requests ever opened here, exactly one targeted a base other than `main`. Widening would have added CI to a single pull request in the project's history, and the cost afterwards is one run per push to a stacked branch, which is what a `main`-based branch already costs, because `push` stays filtered to `main` and a branch with an open pull request is already covered by `pull_request`.

**What the widening does cost is queue depth, and that ceiling is already binding.** GitHub's documented concurrent-job limit is 5 macOS jobs on Free, Pro and Team alike, with no public-repository exemption, shared across every repository on the account. `ci.yml` dispatches 12 jobs, of which `ci / Cross compile` and `ci / Scrut` skip without taking a runner, leaving **7 real macOS jobs against a ceiling of 5**. Measured on run `34267759051`: peak concurrency is exactly 5, and `ci / Build` and `ci / Test` are admitted at 19:15:01 and 19:15:10 only as `ci / Format` and `shaders` free their slots. So every run is already two waves deep and the 103 s median is a queued figure rather than a compute one. **`timeout-minutes` is not at risk**, which is the natural worry and is unfounded: a job's budget starts when the job starts, not when the run does, so none of the measured ceilings at `ci.yml:71`, `85`, `279`, `427`, `461`, `549`, `610` and `724` is eaten by queueing.

**Nothing is blocked on a check.** Two rulesets are active, "Main" over the default branch (deletion, non-fast-forward, pull request with zero required approvals, Copilot review) and "PRs" over `~ALL` (Copilot review only). Neither carries a `required_status_checks` rule, so widening cannot deadlock a stacked pull request on a check that never arrives.

## Native stacked pull requests, which is why the filter looked defensible

Verified against GitHub's documentation rather than inferred. Stacked pull requests went to **public preview on 2026-07-30**, five weeks before #86, and for a native stack the documentation states: "GitHub Actions workflows trigger as if each pull request in the stack targets the base of the stack. A workflow configured to run on `pull_request` events targeting `main` runs for every pull request in the stack, not just the bottom one, so no workflow changes are required." A `github.event.pull_request.stack` context carries `number`, `size`, `position`, `base.ref` and `base.sha`, and is present only when the pull request belongs to a stack.

**This does not make the fix unnecessary, and the reason is the shape of the issue rather than a preference.** A native stack is created through the `github/gh-stack` extension (`gh stack init --base BRANCH`) or the web UI; a pull request retargeted by hand with `gh pr create --base`, which is what actually happens and what #86 was, is not a stack and gets nothing. Depending on the preview would make CI's correctness depend on **how the pull request was created**, which is invisible at the point of use and is the same class of failure the issue is about. The preview is also documented as subject to change, and it is limited to branches in one repository. Dropping the filter is a superset of what the preview gives: a native stack keeps running everything, and a hand-retargeted one starts to.

**One consequence of adopting stacks has to be recorded rather than acted on.** A four-deep stack is four runs of 7 macOS jobs against a ceiling of 5, roughly six waves. GitHub's own guidance for that is to gate expensive jobs on `github.event.pull_request.stack.position == github.event.pull_request.stack.size`. That is the number to re-measure if stacks get deep, and it must not be built now: it would reintroduce "some jobs do not run on some pull requests", which is exactly what is being fixed.

## What changes

### 1. Drop `branches: [main]` from `ci.yml`'s `pull_request` trigger

`.github/workflows/ci.yml:13-14`, deleting one line. Everything else in the block stays.

`push` keeps its filter, and that half is load-bearing: a push to a branch with an open pull request already dispatches `pull_request`, so widening `push` too would double every run on a stacked branch and additionally build branches nobody has proposed.

`paths-ignore` stays on both triggers. For a `pull_request` it evaluates over the `base...head` diff, which for a stacked pull request is the child's own changes against its parent, so a docs-only stacked branch still skips exactly as a `main`-based one does. That is the behaviour all four workflows already agree on, and it is why #86 is not a usable test of this fix.

Drop the filter rather than widening it to a glob. An enumerated `branches: [main, 'feature/**', ...]` would have to track a branch-prefix convention that `CONTRIBUTING.md:191` lists six entries for, plus `ci/`, which the convention does not list and which this branch uses; a stack based on a prefix the glob missed would be dark again with nothing saying so, which is the failure being fixed rather than a different one. It would also make `ci.yml` the odd one of four, and three-of-four agreement is itself a check.

### 2. Three comments in `ci.yml`, in the shape `workflow_dispatch`'s already uses

- **Above the trigger**, recording: that `branches:` on `pull_request` reads the base ref; that the three sibling workflows carry no filter and this now matches them; that a push to a **base** branch dispatches nothing on the child, because `synchronize` means the head moved, so a child's green result can describe a merge against an older parent; that auto-retargeting after the parent merges is an `edited` event, which is not in the default activity set and so also fires nothing; and that the fix does not reach a stack already in flight, per the merge-ref note below.
- **Extending `ci.yml:23-29`**, the `workflow_dispatch` comment, which gains a second reader: a stacked pull request whose parent moved. It must say that dispatch runs `refs/heads/<branch>`, the head **without** the base merged in, so it is a strictly weaker check than the pull request would have got.
- **Beside `ci.yml:31-33`**, one line closing the issue's third checkbox in place: `github.ref` is `refs/pull/N/merge` on a `pull_request`, so the concurrency group is keyed by pull request number rather than by branch, two pull requests in one stack cannot collide, and repeated pushes to a stacked branch cancel their own in-flight runs. Demonstrated already: three `pull_request` runs on head `ci/improve-ci-coverage` within 60 seconds all concluded `cancelled`. **No change is needed here.**

**The merge-ref fact is the one most worth writing down**, because the failure it produces is the same silence the issue is about. For a `pull_request`, the `on:` block is read from the workflow file in the merge commit, not from the base branch. So landing this on `main` does nothing for a stack already open: the child's merge ref is merge(child head, parent tip) and neither carries the widened trigger. It stays dark until the fix reaches that merge ref (merge `main` into the parent, or rebase it) **and** the child's head then moves, because a base update fires no event. Closing and reopening the child is the cheapest unblock, since `reopened` is a default activity type and runs the real merge ref.

### 3. A new gotcha bullet in `AGENTS.md`

`AGENTS.md` has no prose about CI triggers at all; `concurrency` appears twice and both are about running two DAW streams. The bullet goes between the `ruff` bullet at `AGENTS.md:382` and the `clap-validator` pins at `:383`, so the three `ci.yml` bullets read in order: what dispatches the workflow, what is pinned inside it, how long its jobs may take.

It carries, in this order: the base-ref fact and the founding-commit finding; that `paths-ignore` still applies to the child's own diff, so #86 would have been unaffected either way and a docs-only stacked branch still runs nothing; the base-update and auto-retarget gaps with the close-and-reopen unblock; the merge-ref caveat; native stacks as the reason the filter looked defensible and as the way to stack now; and the measured macOS ceiling of 5 against 7 real jobs, since that is the figure any future widening has to be argued against. Every number in it quotes a run ID and a sample size, matching the rest of that section.

### 4. Adopt native stacks in the plan docs

Four passages tell future work not to stack and name #87 as the reason. The hard rule goes and the guidance is rewritten around native stacks; the preference that predates #87 must not be deleted with it, since a child's diff is still unreadable until the parent lands and every parent revision still forces a rebase.

- `2026-07-25-repo-foundation-and-phased-build-plan.md:250-254`, the "configured … and silently are not" group: #87 recorded as settled, leaving #85 open.
- The same file at `:411`, which rests on two independent grounds and loses only the second. Rewritten to say stacking now runs CI, that a **native** stack is how to do it where a real dependency exists, and that the diff-readability and rebase costs are unchanged.
- `2026-09-04-close-the-verification-gaps-in-the-test-suite.md:381` and `:403`, "none of them should be stacked until #87 is settled" and "**Do not stack them**, per #87".

**Two things about native stacks are unconfirmed and must be written as open rather than asserted.** GitHub's reference page does not say what happens to the remaining pull requests when the bottom one merges, so the claim that it rebases the next onto the stack base, and that the rebase is a head update which fires `synchronize` and closes the base-update gap, is plausible and unverified here. And the preview's per-account or per-repository enablement is undocumented. The first genuine stack is what measures both; the plan should say so rather than promise the gap is closed.

`CONTRIBUTING.md` needs no change. Its pull request process opens with "Fork the repository", a fork's pull request targets `main`, and cross-fork stacks are documented as unsupported, so stacking is an internal practice and does not belong there.

### 5. No executable guard

Nothing here would catch the filter being re-added, and #99's `actionlint` would not either, since this is a valid trigger rather than a syntax error. That is recorded as a residual hole rather than closed, and noted on [#99](https://github.com/cboone/fosforo/issues/99) as something workflow linting could cover later. The regression is at least reachable from a check: a pull request to `main` still dispatches `ci.yml`, so a guard added there in future would fire.

## Verification

The acceptance test is a throwaway stacked pull request run **before** the fix merges. It works because the `on:` block is read from the merge ref: a pull request whose head branches off `ci/stacked-prs` and whose base **is** `ci/stacked-prs` gets a merge ref already carrying the widened trigger, so the whole workflow runs on a non-`main` base while the fix is still unmerged.

```bash
git push -u origin ci/stacked-prs                        # the base must exist on the remote first
git switch -c test/stacked-ci-probe ci/stacked-prs
# add one comment line inside an existing block of .github/workflows/ci.yml
git commit -S -am 'test: probe whether a non-main base runs CI (#87)'
git push -u origin test/stacked-ci-probe
gh pr create --base ci/stacked-prs --head test/stacked-ci-probe --draft \
  --title 'test: probe CI on a non-main base (#87)' \
  --body 'Throwaway. Close without merging. See #87.'
gh pr view <N> --json baseRefName,isDraft
gh pr diff <N> --name-only
gh api repos/cboone/fosforo/actions/runs \
  --jq '.workflow_runs[] | select(.head_branch=="test/stacked-ci-probe") | "\(.name) \(.event) \(.conclusion)"'
```

**Four things about the probe are load-bearing, and each produces a false pass if got wrong.**

- **It must be created with plain `gh pr create --base`, never `gh stack`.** A native stack would run `branches: [main]` workflows anyway, so a pass would be attributable to the preview rather than to the fix. This is the sharpest trap and it did not exist before 2026-07-30.
- **The diff must touch a path in neither `paths-ignore` list.** A comment in `.github/workflows/ci.yml` is the cleanest subject: in scope, behaviour-free, and covered by neither list. A `.md` file reproduces #86 exactly and proves nothing. A `.zig` file works but risks a red run from `zig fmt --check` for the wrong reason.
- **The probe commit must not touch the `on:` block**, since the merge ref's copy is what gets evaluated; editing the trigger there would test the probe's version rather than this branch's.
- **The base must be confirmed after creation.** If it silently defaulted to `main`, the old trigger matches too and a pass says nothing.

**A pass** is a run named `CI` with `event: pull_request` and `head_branch: test/stacked-ci-probe`, concluding `success`, whose job list holds all twelve names (`ci / Test`, `ci / Format`, `ci / Build`, `ci / Cross compile` and `ci / Scrut` skipped, `shaders`, `smoke`, `ring-race`, `shell`, `python`, `clap-validator`, `clap-wrapper`), with `baseRefName == ci/stacked-prs`. Quote that run ID in the `AGENTS.md` bullet.

**A false pass** in any of four flavours, each ruled out by name: the rollup shows only `scan / gitleaks`, `scan / trufflehog` and `check` and reads green, which is the #86 result and proves nothing, so assert on the `CI` run rather than on the rollup's colour; a `CI` run exists with `event: workflow_dispatch`, bypassing the trigger under test; no `CI` run because the diff landed on an ignored path; or the base became `main`. Budget four to six minutes for the pair of runs and do not read a slow start as a failure, since the two contend for the same five macOS slots.

**Cleanup:** close the probe without merging and delete both remote and local branches, so the comment-only commit never reaches the fix's own diff.

### Result

Run as [#110](https://github.com/cboone/fosforo/pull/110), a draft pull request with `baseRefName: ci/stacked-prs`, a one-line diff touching `.github/workflows/ci.yml`, and `has("stack") == false`, so no native stack can account for the outcome. **It passed.** Run `34271723634`: `name: CI`, `event: pull_request`, `head_branch: test/stacked-ci-probe`, `conclusion: success` in 152 s, with all twelve job names present, `ci / Build`, `ci / Format`, `ci / Test`, `clap-validator`, `clap-wrapper`, `python`, `ring-race`, `shaders`, `shell` and `smoke` succeeding and `ci / Cross compile` and `ci / Scrut` skipped as they are on every run. Before this change that run would not have existed at all; #86's rollup, which is what the same pull request would have produced under the old trigger, holds only `scan / gitleaks`, `scan / trufflehog`, `scan / Validate inputs` and typos' `check`.

All four false-pass flavours were ruled out by name: the run exists under the name `CI` rather than the rollup merely reading green; its event is `pull_request` rather than `workflow_dispatch`; a run exists at all, so the diff did not land on an ignored path; and the base was confirmed as `ci/stacked-prs` before the run was read. The probe was closed without merging and both branches deleted.

Ordinary checks alongside it, all unaffected by this change: `zig build test`, `typos` (which reads `ci.yml`, so the new comments must be spelled correctly and carry no bare 7-hex-digit tokens, per `AGENTS.md:380`), and `markdownlint-cli2` in check mode over the edited Markdown, never `--fix`.

## Commits

Workflow first, documentation second, on the precedent at `docs/plans/done/2026-07-29-tighten-ci-job-timeouts.md:110`: `ci.yml`'s `paths-ignore` covers `*.md` and `docs/**`, so a docs-first push would not exercise the change.

1. `ci: run CI on a pull request based on any branch (#87)` — the trigger and the three comments.
2. `docs: record what dispatches ci.yml and what still does not (#87)` — the `AGENTS.md` bullet, written after the probe so its figures are measurements.
3. `docs: adopt stacked pull requests now that CI runs on them (#87)` — the four plan passages.

## Out of scope

- `markdownlint`, which is [#85](https://github.com/cboone/fosforo/issues/85), and workflow linting, which is [#99](https://github.com/cboone/fosforo/issues/99).
- The secret scanners and `typos`, which already carry no branch filter and are unaffected.
- Any `stack.position` gating of expensive jobs. Recorded above as the thing to re-measure if a stack ever gets deep, and refused now because it would reintroduce the failure being fixed.
- Fan-out machinery to re-dispatch children when a parent moves. Real, buildable, and not worth it against one stacked pull request in 47; the base-update gap is documented and unblocked by hand instead.
