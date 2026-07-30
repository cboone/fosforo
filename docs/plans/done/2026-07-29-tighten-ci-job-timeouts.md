# Tighten CI job timeouts

Addresses [#17](https://github.com/cboone/fosforo/issues/17).

## Context

Every `timeout-minutes` in this repository was chosen by copying a neighbour, not by measuring anything. A timeout is a runaway guard rather than a prediction, so headroom is correct, but `clap-wrapper` sits at 45 minutes against a two-minute job and `shell` at 10 minutes against an eight-second one.

The passing path pays nothing for this. The hanging path pays the whole ceiling, and every job in `ci.yml` except `shell` runs on `macos-latest`, which bills at ten times the Linux rate. Tightening the ceilings cuts the cost of a wedged job without touching the normal path. The intended outcome is that no ceiling in the repository stands more than roughly 4x above the slowest run actually observed for that job, with two documented exceptions where a conditional step is unmeasured.

## Findings that shaped the design

Re-measured from the Actions API rather than taken from the issue, which sampled fewer runs. Successful jobs only, `completed_at - started_at`.

| Job                      | Current ceiling | Runs | Min | Max  | Mean | New ceiling | Max as % of new |
| ------------------------ | --------------- | ---- | --- | ---- | ---- | ----------- | --------------- |
| `clap-wrapper`           | 45              | 12   | 49s | 121s | 75s  | 10          | 20%             |
| `clap-validator`         | 20              | 19   | 23s | 170s | 45s  | 8           | 35%             |
| `shaders`                | 20              | 28   | 25s | 90s  | 43s  | 8           | 19%             |
| `ci / Test`              | 20 (inherited)  | 27   | 23s | 110s | 39s  | 8           | 23%             |
| `ci / Build`             | 20 (inherited)  | 28   | 24s | 123s | 47s  | 8           | 26%             |
| `ci / Format`            | 20 (inherited)  | 28   | 15s | 30s  | 22s  | 8           | 6%              |
| `shell`                  | 10              | 9    | 4s  | 8s   | 6s   | 3           | 4%              |
| `scan / gitleaks`        | 15 (inherited)  | 29   | 4s  | 24s  | 6s   | 3           | 13%             |
| `scan / trufflehog`      | 15 (inherited)  | 28   | 8s  | 53s  | 11s  | 3           | 29%             |
| `scan / Validate inputs` | 360 (default)   | 59   | 2s  | 5s   | 3s   | unchanged   | n/a             |

Three of the issue's numbers moved with the larger sample, and one of its claims does not hold.

- **`shell` is 8s, not 4s.** The issue had a single run. Nine now, ranging 4s to 8s. Its 150x figure becomes 75x, which changes nothing about the conclusion.
- **`ci / Build` is 123s, not 89s.** This is the job that sets the floor for the shared `ci / *` ceiling, so it is the one that matters. 8 minutes is 3.9x it, still inside the 4x intent, but with no room to go lower.
- **`clap-wrapper`'s 121s does not include a cold validator cache.** The issue reads it as the honest worst case because the job runs the full CMake configure every time. But the `./.github/actions/clap-validator` step took 1s or 2s in all 12 sampled runs, so the cache was warm in every one and the Rust build has never fired in this job. Adding the 58s that build measured in its sibling gives ~181s, and the predecessor `audio-unit-sandbox` job reached 142s over its own 14 runs, so ~200s is the defensible cold worst case. 10 minutes is 3.0x that, consistent with the rest.
- **`clap-validator`'s 170s is confirmed cold.** Run 30377926469 breaks down as 58s building the validator plus 75s building the plugin. The cache-miss path is bounded by observation, not estimated, which makes 8 minutes the tightest ratio in the set at 2.8x and the one most worth watching after merge.
- **`shaders`' Metal download has still never fired.** `Download the Metal toolchain` was `skipped` in all 29 sampled runs, 28 successful and one cancelled. `xcodebuild -downloadComponent MetalToolchain` is a multi-gigabyte fetch and its duration here remains unmeasured.

Two further facts settled the shape of the change.

- **Both reusable workflows already expose the input.** `run-zig-ci.yml` at the pinned `91f9abd` declares `timeout-minutes` as `type: number` with `default: 20`, applied to all five of its jobs; `scan-for-secrets.yml` declares the same with `default: 15`. Neither caller passes it, which is why the current values are inherited. One `with:` line per caller changes them.
- **A step-level timeout cannot exceed its job's.** The issue's third option for `shaders` proposes cutting the job to 8 while giving the download "its own generous budget". That is not available. `jobs.<job_id>.timeout-minutes` is documented as the point at which GitHub "automatically cancels" the job, and `jobs.<job_id>.steps[*].timeout-minutes` only kills the step's process; the tighter of the two wins, and the job ceiling is always the outer bound. A step timeout inside an 8-minute job is a label, not headroom.

## Decisions

- **Roughly 4x the observed maximum, floored at 3 minutes.** 8 for the macOS jobs, 10 for `clap-wrapper` because its cold path is inferred rather than measured, 3 for the three Linux jobs. This drops the worst-case spend on a single wedged macOS job from 45 minutes to 10.
- **`shaders` goes to 8, with a `timeout-minutes: 5` on the download step.** The ceiling deliberately does not budget for a step that has never fired: paying 12 extra minutes of insurance indefinitely against an unmeasured risk is worse than failing loudly once and raising the ceiling with a real number behind it. The step timeout adds no budget, and its only job is to make that failure legible as a wedged download rather than an opaque job cancellation. Both facts go in comments, because the next reader will otherwise re-derive the issue's option 3 and believe it works.
- **Include `gitleaks.yml` and `trufflehog.yml`, which the issue omitted.** They inherit 15 against 24s and 53s maxima. The stakes are a tenth of the macOS jobs since both run on `ubuntu-latest`, but leaving them is leaving two workflows carrying an untightened ceiling for no reason other than that the issue's table stopped at `ci.yml`.
- **Accept that `ci / Format` gets 16x.** The reusable workflow applies one input to all its jobs, so the shared ceiling is set by the slowest, which is `Build` at 123s. Tightening `Format` on its own would mean adding per-job inputs upstream in `cboone/gh-actions`. Not worth it for a 30-second job on a shared runner.
- **Leave `scan / Validate inputs` alone.** It has no `timeout-minutes` at all in `scan-for-secrets.yml`, so it inherits GitHub's 360-minute default. That is not settable from this repository; it is an upstream fix and belongs in an issue against `cboone/gh-actions`, not here.
- **Use `ci:` as the commit type, not `feat:`.** The issue carries the `enhancement` label, but the repository already uses `ci:` for workflow changes and the issue's own title does too.

## Changes

### 1. `.github/workflows/ci.yml`

Five edits, one per job. Each new value gets a comment recording the measured maximum and the sample size it came from, so the next person to touch it has the basis rather than another number to copy.

- **`ci`**: add `timeout-minutes: 8` to the existing `with:` block, alongside `zig-version-file`, `runs-on`, and `run-cross-compile`. Note in the comment that this covers all three of `Test`, `Format`, and `Build`, and that the value is set by the slowest.
- **`shaders`**: `20` → `8`, and add `timeout-minutes: 5` to the `Download the Metal toolchain` step.
- **`shell`**: `10` → `3`. Its comment should name the two pinned binary downloads as the only variable part.
- **`clap-validator`**: `20` → `8`, noting that the 170s maximum is a cache-miss run and already includes the 58s validator build.
- **`clap-wrapper`**: `45` → `10`, noting that the observed 121s is warm-cache only and that ~200s is the cold estimate.

The `shaders` job is the only one whose shape changes:

```yaml
  shaders:
    runs-on: macos-latest
    # 90s max over 28 runs. This does not budget for the Metal download below,
    # which has been skipped in every run sampled and is unmeasured. If a future
    # runner image ever ships without the toolchain, this job fails here rather
    # than paying for insurance against a step that has never fired, and the
    # ceiling gets raised once with a real measurement behind it.
    timeout-minutes: 8
    steps:
      # ...
      - name: Download the Metal toolchain
        if: steps.metal.outputs.available == 'false'
        # A label, not a budget. A step timeout cannot exceed its job's; the
        # ceiling above is the outer bound either way. This only makes a wedged
        # multi-gigabyte download read as one instead of as a cancelled job.
        timeout-minutes: 5
        run: |
          xcodebuild -downloadComponent MetalToolchain
          xcrun --kill-cache
```

### 2. `.github/workflows/gitleaks.yml` and `.github/workflows/trufflehog.yml`

One line each, into the existing `with:` block next to `tool:`, plus a brief comment giving the measured maximum. Both call `scan-for-secrets.yml` at the same pinned `91f9abd`.

```yaml
    with:
      tool: gitleaks
      # 24s max over 29 runs; the reusable workflow's own default is 15.
      timeout-minutes: 3
```

### 3. Documentation

| File           | Change                                                                     |
| -------------- | -------------------------------------------------------------------------- |
| `AGENTS.md`    | New Gotchas entry recording the measured basis and the `shaders` exception |
| `CHANGELOG.md` | One `### Changed` entry under `## [Unreleased]`, referencing #17           |

The AGENTS.md entry should cover four things: the ceilings are measured rather than copied and the plan holds the figures; `shaders` is a deliberate exception whose ceiling does not budget for its own download step; a step-level `timeout-minutes` cannot exceed its job's, so it labels a failure rather than extending a budget; and the `ci / *` and `scan / *` values live in a `with:` block because they are inputs to reusable workflows, not job keys.

`CLAUDE.md` is a symlink to `AGENTS.md` and needs no separate edit. That entry is what stops this recurring: #17 exists because `shell` was given 10 minutes by copying its neighbours, and nothing in the repository recorded that the neighbours' values were arbitrary too.

### 4. Commits

`ci.yml` carries `paths-ignore` for `*.md` and `docs/**`, so the workflow commits must come before the documentation one to be exercised at all. The two secret-scan workflows have no `paths-ignore` and run on every push.

1. `ci: tighten the ci.yml job timeouts to measured values (#17)`
1. `ci: tighten the secret-scan job timeouts to measured values (#17)`
1. `docs: record the measured basis for the CI timeouts (#17)`
1. `docs: move the plan to done (#17)`

Commit trailers do not close issues through a merge commit, so put `Closes #17` in the PR body.

## Verification

Nothing here can be verified locally; `timeout-minutes` only takes effect on a runner. Two checks are still local, and the rest is post-merge observation.

| Check                                | Expectation                                                     | Result                        |
| ------------------------------------ | --------------------------------------------------------------- | ----------------------------- |
| `actionlint .github/workflows/*.yml` | Clean. Catches a misplaced key or a bad `with:` input name      | Clean, all four workflows     |
| `markdownlint-cli2`                  | Clean, per `.markdownlint-cli2.jsonc`                           | Clean, 30 files               |
| Every job on the PR                  | Green, and `shaders` still reports the download step as skipped | Pending, observed on the PR   |

The `actionlint` run matters more than usual for the two `with:` additions: passing an input a reusable workflow does not declare is a workflow-level error, and `actionlint` resolves the pinned SHA to check it.

After merge, let a few runs accumulate and re-measure. The criterion is that no job's duration exceeds **75%** of its new ceiling, that is 360s against an 8-minute ceiling, 450s against 10, and 135s against 3. Every current maximum clears this with room, the closest being `clap-validator` at 170s of 360s.

```bash
gh run list --workflow=ci.yml --limit 5

# Per-job durations for successful jobs, which is what the table above was built from.
for id in $(gh run list --workflow=ci.yml --limit 20 --json databaseId --jq '.[].databaseId'); do
  gh api "/repos/cboone/fosforo/actions/runs/${id}/jobs?per_page=100" --jq '
    .jobs[]
    | select(.conclusion == "success")
    | [.name, ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601))]
    | @tsv'
done | sort
```

If a job lands above 75%, the 4x multiple was too tight for that job specifically and it should be raised with the new figure recorded, not reverted wholesale. The two candidates are `ci / Build`, whose maximum moved from 89s to 123s between the issue being filed and this plan, and `clap-validator` on a cold cache after a pin bump.

## Notes for execution

- Invoke `write-markdown` before the `AGENTS.md` and `CHANGELOG.md` edits.
- Do not touch `docs/plans/done/2026-07-29-validate-the-clap-wrapper-built-clap.md`, which records raising `clap-wrapper` from 30 to 45. It is a historical record of a decision this plan supersedes, and rewriting it would erase the reasoning that made 45 look correct at the time.
- Consider a follow-up issue against `cboone/gh-actions`: `scan-for-secrets.yml`'s `validate-inputs` job sets no `timeout-minutes`, so it inherits 360 and no caller can change that.
