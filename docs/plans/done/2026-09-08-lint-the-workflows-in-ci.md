# Lint the workflows in CI

Issue: [#99](https://github.com/cboone/fosforo/issues/99). Type: `ci:`. Branch: `test/lint-workflows`.

## Context

`.github/workflows/ci.yml` is 46 KB and nothing checks it. `actionlint` appears in the build plan's **Phase 0** exit criteria and in no workflow, so it has been a local step at best. That is the shape this repository has now hit four times: a check that is configured, is believed to be running, and silently is not. #28 was `typos`, [#85](https://github.com/cboone/fosforo/issues/85) is `markdownlint`, [#87](https://github.com/cboone/fosforo/issues/87) is the `pull_request` branch filter, and the workflow files are the one place whose errors surface only as a failed run on someone else's branch.

The intended outcome is a job that fails on a workflow defect, on the `shell`, `python` and `typos` jobs' precedent, plus two fold-ins the last run's warnings exposed.

**The issue's second acceptance criterion is answered before the job is written, and the answer is no.** `actionlint` would not have caught the `version-file` warning, for a reason that is structural and permanent here rather than a gap that a newer release closes. That is recorded below because it bounds what this job is worth.

## What was measured

`actionlint` 1.7.12, run against this worktree. Every null result below shares a run with a positive control, so none of them is an instrument that was not running.

| Planted defect                                         | Caught | Why                                               |
| ------------------------------------------------------ | ------ | ------------------------------------------------- |
| Misspelled `runs-on:` label                            | yes    | `runner-label`, against a bundled label list      |
| `if:` naming a step id that does not exist             | yes    | `expression`, against the typed `steps` object    |
| `needs:` naming a job that does not exist              | yes    | `job-needs`                                       |
| Unquoted variable in a `run:` block                    | yes    | shellcheck integration, `SC2086`                  |
| Unknown input on a **local** composite action          | yes    | reads `.github/actions/*/action.yml`              |
| Missing **required** input on a local composite action | yes    | same                                              |
| Unknown input on a **SHA-pinned** third-party action   | **no** | input DB is keyed by tag; a commit pin defeats it |
| `version-file:` on `mlugg/setup-zig`                   | **no** | both of the above: SHA-pinned _and_ not in the DB |
| Unknown input on a **remote reusable workflow**        | **no** | not resolved at all, pinned or otherwise          |

Three consequences worth carrying.

**The `with:` check is defeated by this repository's own pinning policy.** `actionlint` validates inputs against a database of popular actions bundled in the binary, keyed by tag. Every third-party action here is pinned to a commit SHA, which is correct and non-negotiable, and which means the check never fires. Measured both ways: `actions/checkout@v4` with a bogus input is reported, and the identical bogus input on `actions/checkout@11bd7190…` is not.

**Local actions are checked, but only inside a git repository.** `actionlint` resolves `./.github/actions/…` through the project root, which it finds via git. Run outside a checkout it silently skips those checks and exits 0. `actions/checkout` leaves a `.git`, so CI is fine; a run in an exported tree is not. A first attempt at the table above produced three false negatives for exactly this reason.

**Without `shellcheck` on `PATH` the integration is skipped silently, and the job still exits 0.** A planted `SC2086` passes. `-shellcheck=/nonexistent` behaves the same way: no warning, no error. This is the vacuous pass the `python` job's comment names, and it is why the job installs `shellcheck` rather than hoping the runner image ships one.

**Superseded claim.** `docs/plans/done/2026-07-29-tighten-ci-job-timeouts.md:129` records that "`actionlint` resolves the pinned SHA to check" a reusable workflow's inputs. It does not, in either sense: not for reusable workflows, and not for SHA-pinned actions. That plan stays as the historical record it is; the measured boundary goes into `AGENTS.md`, which is the live document.

## Changes

### 1. The `actionlint` job, in `ci.yml`

**In `ci.yml` rather than its own workflow, and this is confirmed rather than assumed.** `typos` is separate because `ci.yml` ignores `*.md`, `docs/**`, `LICENSE`, `.claude/**` and the two agent config globs, so the files it checks are the files that would skip it. None of those patterns matches `.github/**`, and `paths-ignore` skips a run only when _every_ changed file matches, so a workflow edit always triggers `ci.yml`. The `typos` argument therefore does not apply and the `shell`/`python` precedent does.

The residue, stated rather than fixed here: `ci.yml`'s `pull_request` carries `branches: [main]`, so a stacked pull request runs no `actionlint` either. That is [#87](https://github.com/cboone/fosforo/issues/87) and governs all nine jobs, not this one.

Place it between `python` and `clap-validator`, which keeps `ring-race`'s "the two Ubuntu jobs below" true by not inserting above `shell`.

- `runs-on: ubuntu-latest`, matching `shell`, `python` and `typos`: platform-independent static analysis, and the macOS runner bills at ten times the rate.
- `timeout-minutes: 3`, unmeasured, on the `python` job's precedent and phrased the same way. It is structurally the same thing: an Ubuntu checkout, two pinned downloads and a walk over four workflow files. It gets a measured value once there are runs behind it.
- Pin `ACTIONLINT_VERSION: "1.7.12"` and `ACTIONLINT_SHA256: "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"`, for `actionlint_1.7.12_linux_amd64.tar.gz`. Computed locally with `shasum -a 256` on the downloaded asset, and independently equal to the entry in upstream's `actionlint_1.7.12_checksums.txt`. Committed rather than fetched, on the `shell` job's reasoning: fetching the manifest from the host that serves the asset verifies transport, not provenance. The rule set ships inside the binary, which is `typos`' and `ruff`'s extra reason to pin.
- Download into `${RUNNER_TEMP}`, matching `typos` and `python` and not `shell`, because this job does not select files through `git ls-files`. Download to a file rather than piping into `tar`, so nothing consumes the bytes before the sum has verified them. The tarball carries docs beside the binary, so extract the single member: `tar -xzf actionlint.tar.gz actionlint`.
- A `Report tool versions` step running `actionlint --version` and `shellcheck --version`, on the established reasoning, plus one specific to this job: the second line is the only evidence in the log that the shellcheck integration had anything to shell out to.
- The gate is bare `actionlint`, no path arguments, matching `typos` and `python`. It finds `.github/workflows` itself, lints all four files plus the local composite action, and exits 1 on a finding.
- A `Summarize the findings` step gated on `if: failure() && steps.actionlint.outcome == 'failure'`, writing `actionlint -oneline` into `${GITHUB_STEP_SUMMARY}`, matching `typos` and the two validator jobs.

### 2. Pin `shellcheck` for the integration, and hoist the pair

`actionlint` shells out to `shellcheck` for every `run:` block. That is the only thing that lints the embedded shell in `ci.yml`: the `shell` job selects tracked files by shebang, and a `run:` block inside YAML is not a file. So this is genuine new coverage over the largest unchecked body of shell in the repository, and it is the same gap the `python` job closed for `scripts/measure-trace`.

The runner image ships `shellcheck` 0.9.0, which the `shell` job already refuses to depend on. Install the same pinned 0.11.0 here, and move `SHELLCHECK_VERSION` and `SHELLCHECK_SHA256` from the `shell` job's `env:` up to workflow level, on the precedent `VALIDATOR_REV` and `RUST_VERSION` set two jobs ago: "Duplicating these would let the two cache keys drift, and a drifted key still passes." `SHFMT_VERSION` and `SHFMT_SHA256` stay in `shell`, which is the only job that uses them.

Both jobs then read the same pair, so the embedded shell and the tracked scripts cannot be linted by two different tools.

### 3. Remove the `version-file:` input from `mlugg/setup-zig`

`mlugg/setup-zig@v2.2.1` declares `version`, `mirror`, `use-cache`, `cache-key`, `cache-size-limit` and `use-tool-cache`. There is no `version-file`. Five steps pass it, at `ci.yml:111`, `285`, `433`, `621` and `730`.

**Deleting it cannot change which Zig gets installed, because it is ignored today.** What the empty `version` default already does is read `minimum_zig_version` from `build.zig.zon`, which is the behaviour `build.zig.zon`'s own comment claims and ADR 0002 depends on. So the fix is to delete the two-line `with:` block from all five steps, leaving a bare `- uses:`, and to carry a comment at the first of them saying that the absent input is what reads the file, so nobody helpfully restores it.

`ci.yml:68`'s `zig-version-file:` is **correct and stays**: that is an input to `cboone/gh-actions`' reusable workflow, which does declare it.

### 4. Bump `actions/checkout` to v6.1.0

Eight uses, seven in `ci.yml` and one in `typos.yml`, all on `11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2`, which is `node20`. Move all eight to `d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0`, which is `node24`.

v6 rather than v5 because `cboone/gh-actions` already pins `actions/checkout@de0fac2e…`, which is v6.0.2, so this keeps the two repositories on one major. The `allow-unsafe-pr-checkout` breaking change in v5.1.0, v6.1.0 and v7.0.1 is inert here: it concerns `pull_request_target`, which appears nowhere in this repository. v5.0.0's floor of runner v2.327.1 is far below what GitHub-hosted runners run.

**This does not clear the Node 20 warning and is not expected to.** `mlugg/setup-zig@v2.2.1` is the latest release and is itself `using: node20`, and `cboone/gh-actions` pins the same SHA, so the warning stands until upstream moves. What the bump buys is that half the exposure is gone and this repository is not the reason the warning persists.

### 5. Documentation

- **`AGENTS.md`** — one line in the `## Development` block beside `typos` and `ruff`, and one `## Gotchas` bullet in the tooling cluster at lines 372-378. The bullet carries the measured coverage boundary: the SHA-pin blind spot, the git-repository requirement, and the silent shellcheck skip. `CLAUDE.md` is a symlink, so only the one file is edited.
- **`CONTRIBUTING.md`** — a Requirements bullet (`CI pins 1.7.12`; `brew install actionlint`) and a Code Style bullet, matching the `typos` and `ruff` entries.
- **`CHANGELOG.md`** — one `### Added` entry under `## [Unreleased]`.
- **The build plan** — the Verification table's `CI` row ends "**Nothing lints the workflows themselves ([#99](https://github.com/cboone/fosforo/issues/99))**", which becomes a statement that something now does, with the boundary named. The verification-program table's #99 row flips to `Done`.
- **`docs/plans/todo/2026-09-04-close-the-verification-gaps-in-the-test-suite.md`** — section 11 gets its outcome, including that the `version-file` question was answered in the negative.

Not updated: no ADR. The plan prescribes none for #99, and nothing here supersedes a settled decision.

## Verification

Run from this worktree, with the tree clean, before the branch is pushed.

```bash
actionlint                      # exits 0, prints nothing
actionlint --version            # 1.7.12
shellcheck --version            # 0.11.0, so the integration had something to run
```

Then the planted defects, which are the acceptance criteria. Each is applied to a **copy** of the tree under the scratchpad, never to the worktree, and each is confirmed to fail before being discarded:

<!-- spellchecker:off -->

| Plant                                                            | Expected                     |
| ---------------------------------------------------------------- | ---------------------------- |
| `runs-on: ubunut-latest` on the new job                          | `runner-label`, exit 1       |
| `if: steps.nope.outputs.x == 'y'` on a step                      | `expression`, exit 1         |
| `echo $ACTIONLINT_VERSION` unquoted in a `run:` block            | `SC2086`, exit 1             |
| A required input dropped from `./.github/actions/clap-validator` | `action`, exit 1             |
| The identical tree, unplanted                                    | exit 0, the negative control |

<!-- spellchecker:on -->

The last row is not optional. Every claim above is an absence, and without it "the defect was caught" cannot be told from "everything is reported".

Two more that check the job rather than the tool:

- Run `actionlint` with `shellcheck` removed from `PATH` against the `SC2086` plant, and confirm it exits **0**. That is the vacuous pass, and it is what the install step exists to prevent.
- Confirm `git ls-files -z | xargs -0 shfmt -f | xargs -r shellcheck` still passes, so hoisting the version pair changed nothing about the `shell` job.

Then the repository's own checks, since this branch touches Markdown and YAML:

```bash
typos
markdownlint-cli2               # check only; NEVER --fix, it rewrites every file
```

In CI, the branch's first run is the real verification, and three things are read off it: the `actionlint` job is green, its `Report tool versions` step prints both versions, and the `version-file` warning is gone from every job while the Node 20 warning remains and names only `mlugg/setup-zig`.

## Commits

Conventional Commits, each referencing `(#99)`, in the smallest reviewable units:

1. `ci: lint the workflows with a pinned actionlint`
2. `ci: stop passing an input mlugg/setup-zig does not declare`
3. `ci: move actions/checkout off the Node 20 runtime`
4. `docs: record what actionlint checks and what it cannot see`
