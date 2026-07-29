# Validate the clap-wrapper-built .clap

Addresses [#12](https://github.com/cboone/fosforo/issues/12) and [#7](https://github.com/cboone/fosforo/issues/7).

## Context

Two `.clap` bundles come out of this repository and CI covers one of them.

| Bundle                      | Built by               | `clap_entry` from                              | Covered in CI                                                 |
| --------------------------- | ---------------------- | ---------------------------------------------- | ------------------------------------------------------------- |
| `zig-out/Fosforo.clap`      | `zig build`            | `src/main.zig`                                 | Yes, since [#10](https://github.com/cboone/fosforo/issues/10) |
| `build/assets/Fosforo.clap` | CMake and clap-wrapper | `cmake/entry.cpp` via `make_clapfirst_plugins` | No                                                            |

They share the implementation but not the entry point, so a defect in that seam, or a regression that arrives with a clap-wrapper pin bump, is invisible to the job added in #10. That matters more than a second artifact usually would: ADR 0003 makes the clap-wrapper path load-bearing, and the wrapper-built CLAP is the artifact that proves the projection outward still works.

Phase 0's exit criteria required **both** artifacts to pass `clap-validator`. That was verified by hand once and has had no automated guard since.

### Why #7 is the same work

Issue #7 was filed first and asked for three things: build `fosforo_clap` in the `audio-unit-sandbox` job, rename that job, and decide whether to add validation on top of merely building. It deferred the third point ("Building both artifacts may be enough guard for now, with validation left as a follow-up"). #12 is that follow-up and answers yes, which makes #7's remaining two items a strict subset of #12. Doing them separately would mean touching the same job twice. One change closes both.

## Findings that shaped the design

Read from `cmake/make_clapfirst.cmake` at the pinned clap-wrapper commit `35f524b`, and from `actions/cache` at the pinned action SHA.

- **`fosforo_all` is real and is the right target.** `make_clapfirst_plugins` creates `${TARGET_NAME}_all` as a custom target and hangs every enabled format off it with `add_dependencies`. With `FOSFORO_FORMATS` set to `CLAP AUV2`, `fosforo_all` builds exactly `fosforo_clap` and `fosforo_auv2`.
- **#7's diagnosis is confirmed at the source and empirically.** Because `cmake/CMakeLists.txt` sets `AUV2_MANUFACTURER_CODE`, `make_clapfirst_plugins` takes its explicit-configuration branch. That branch passes the manufacturer and subtype codes to `target_add_auv2_wrapper` instead of `CLAP_TARGET_FOR_CONFIG`, and never calls `add_dependencies(${AUV2_TARGET} ${CLAP_TARGET})`. `--target fosforo_auv2` genuinely does not build the CLAP.
- **The gap is worse than "no bundle", which is why the fix is not cosmetic.** `--target fosforo_auv2` does leave a `build/assets/Fosforo.clap` directory behind, because CMake writes a bundle's `Info.plist` at generate time. What it does not leave is `Contents/MacOS/Fosforo`. So the path exists and the plugin does not. Validating that path without widening the target would fail with `Could not get executable URL within bundle` rather than silently pass, which is the good outcome, but the two changes have to land together.
- **The bundle path in the issue is correct.** The CLAP target's `LIBRARY_OUTPUT_DIRECTORY` is set to `ASSET_OUTPUT_DIRECTORY` unmodified on non-Windows; only the `WIN32` branch appends `/CLAP`. So the bundle is `build/assets/Fosforo.clap`, alongside `Fosforo.component`.
- **The cold-cache race is safe.** `actions/cache/save` at `0057852` wraps its whole body in a `try` whose `catch` calls `logWarning`, and `saveOnlyRun` emits `core.warning` when the save returns `-1`. Neither calls `core.setFailed`. When both jobs miss the cache and race to reserve the same key, the loser warns and the job stays green.
- **No branch ruleset references check names.** The `Main` and `PRs` rulesets require a pull request and a Copilot review, and declare no required status checks, so renaming a job breaks nothing.
- **The `env` context is available in a step's `with:`,** which is what the existing cache key already relies on. Lifting the pins from job-level to workflow-level `env` does not change how they resolve.

## Decisions

- **One job, not a fourth.** The wrapper-built CLAP needs the full CMake configure, which fetches the AudioUnit SDK over the network. `audio-unit-sandbox` already pays that cost, so the validation goes there. A separate job would pay it twice and hold a second macOS runner slot.
- **Rename the job to `clap-wrapper`.** `audio-unit-sandbox` named the single assertion the job made. The job is now "everything the clap-wrapper path emits, checked", and the name should say so.
- **Build `fosforo_all` rather than naming both targets.** It is the command `AGENTS.md` already documents, and it widens automatically if `FOSFORO_FORMATS` ever grows. That widening is wanted: a new format should arrive in CI by default, not by remembering to edit a target list.
- **Extract the validator install into a local composite action.** The install is four steps and one cache key. Duplicating the key across two jobs is the failure mode most likely to go unnoticed, because a drifted key still passes; it just pays a full Rust build every run. `.github/actions/clap-validator/` owns it once. The `validate` step itself stays in `ci.yml`, visible, in both jobs: the gate should be readable where the job is.
- **Duplicate the failure-summary step.** It is failure-path reporting only, the two copies sit in one file where they can be read side by side, and drift costs nothing worse than a differently formatted table. Not worth a second abstraction.
- **Do not add `needs: clap-validator`.** It would guarantee a warm cache, at the cost of serializing the two slowest jobs on every run to avoid a duplicate Rust build that only happens when a pin changes.
- **Pins stay in `ci.yml`, lifted to workflow-level `env`.** The composite action declares `validator-rev` and `rust-version` as required inputs with no defaults, so a caller cannot silently get a different validator, and the two pins stay visible in the file people actually read.

## Changes

### 1. `.github/actions/clap-validator/action.yml` (new)

A composite action: restore, build on a miss, save on a miss, put on `PATH`. Lifted verbatim from the existing `clap-validator` job, with the two pins becoming required inputs.

```yaml
inputs:
  validator-rev:
    required: true
  rust-version:
    required: true

runs:
  using: composite
  steps:
    - name: Restore the cached validator
      id: cache
      uses: actions/cache/restore@0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0
      with:
        path: ${{ runner.temp }}/clap-validator
        key: clap-validator-${{ runner.os }}-${{ runner.arch }}-${{ inputs.validator-rev }}-rust${{ inputs.rust-version }}
    # build (if: cache-hit != 'true'), save (same condition), then $GITHUB_PATH
```

The cache key resolves to the same string it does today, so the existing cache entry carries over rather than being orphaned. `${RUST_VERSION}` and `${VALIDATOR_REV}` move from job-level `env` to step-level `env` on the build step; every `run:` needs an explicit `shell: bash`.

Carry across the comments explaining why each pin exists, why restore and save are split, and why there are no `restore-keys`. They are the reason the file is legible.

### 2. `.github/workflows/ci.yml`

- Lift `VALIDATOR_REV` and `RUST_VERSION` to workflow-level `env`, above `jobs:`.
- Replace the `clap-validator` job's four install steps with `uses: ./.github/actions/clap-validator`. Nothing else in that job changes.
- Rename `audio-unit-sandbox` to `clap-wrapper` and rewrite its comment block: it now covers both wrapper artifacts, not just the AU plist.
- Change its build step to `--target fosforo_all`.
- Add, after the existing plist assertion: the composite action, then `clap-validator validate build/assets/Fosforo.clap` with `id: validate`, then the failure-summary step under `if: failure() && steps.validate.outcome == 'failure'`, with its heading distinguishing it from the sibling job's.
- Raise `timeout-minutes` from 30 to 45. The job now also builds the CLAP and, on a pin bump, builds `clap-validator` from source, which its sibling budgets 20 minutes for on its own.

Step order in `clap-wrapper`: checkout, setup-zig, CMake build, plist assertion, install validator, validate, summarize. The CMake build and the plist assertion come first deliberately. On a warm cache the install is nearly free either way; on a cold one, the build result should not wait behind a Rust compile.

Also delete the paragraph in the `clap-validator` job's comment block recording the wrapper-built bundle as an uncovered gap. It stops being true here.

### 3. Documentation

| File                                                                  | Change                                                                                                                                                                                                                                                                                 |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AGENTS.md`                                                           | Development section: CI now validates both bundles, `auval` is still the only manual step. Gotchas: `audio-unit-sandbox` becomes `clap-wrapper` in the AU plist entry; the pins entry points at workflow-level `env` and the composite action, and notes both jobs share one cache key |
| `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md` | Verification table, `Plugin` row: enforced against both artifacts, not one                                                                                                                                                                                                             |
| `docs/plans/done/2026-07-28-run-clap-validator-in-ci.md`              | Section 4, "The deferred gap": one sentence recording that #12 closed it. The rest stands as the historical record it is                                                                                                                                                               |
| `CHANGELOG.md`                                                        | `### Changed` entry under `## [Unreleased]`, referencing both #12 and #7                                                                                                                                                                                                               |

`CLAUDE.md` is a symlink to `AGENTS.md` and needs no separate edit.

### 4. Commits

`ci.yml` carries `paths-ignore` for `docs/**` and `*.md`, so sequence the CI commits first and let them be exercised.

1. `ci: extract the clap-validator install into a composite action (#12)`. Behavior-neutral; proves the cache key survives before anything depends on it.
1. `ci: build and validate the clap-wrapper-built .clap (#12)`
1. `docs: record that CI now covers both .clap artifacts (#12)`
1. `docs: move the plan to done (#12)`

Commit trailers do not close issues on a merge commit, so put `Closes #12` and `Closes #7` in the PR body.

## Verification

Local, all run against a from-scratch `cmake -B build cmake/`:

| Check                                                          | Expectation                                             | Result                                                                                                                      |
| -------------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `cmake --build build --target fosforo_auv2`                    | `fosforo_clap` absent from the built-target list        | Confirmed. Built: `clap-wrapper-shared-detail`, `fosforo-zig`, `base-sdk-auv2`, `fosforo_auv2-build-helper`, `fosforo_auv2` |
| The bundle it leaves behind                                    | No plugin binary                                        | Confirmed. Only `Fosforo.clap/Contents/Info.plist`, no `Contents/MacOS/Fosforo`                                             |
| `clap-validator validate` against that shell                   | Fails loudly rather than passing                        | Confirmed, exit 1, `Could not get executable URL within bundle`                                                             |
| `cmake --build build --target fosforo_all`                     | Links the CLAP binary; both artifacts present           | Confirmed. `Linking CXX CFBundle shared module assets/Fosforo.clap/Contents/MacOS/Fosforo`                                  |
| `clap-validator validate build/assets/Fosforo.clap`            | Exit 0, and the same tally the Zig-built bundle reports | Confirmed. 44 run, 16 passed, 0 failed, 0 warnings, 28 skipped, identical to `zig-out/Fosforo.clap`                         |
| The same, with a duplicated `features` entry in the descriptor | Non-zero exit, `features-duplicates` `FAILED`           | Confirmed, exit 1, 15 passed / 1 failed, while `zig build test` still passed                                                |
| `--json --only-failed` through the summary step's `jq`         | Renders a Markdown table                                | Confirmed against that real failing output, not a guessed schema                                                            |
| `./cmake/narrow-au-resource-usage --check`                     | Clean, unchanged by the target widening                 | Clean                                                                                                                       |
| `actionlint .github/workflows/ci.yml`                          | Clean                                                   | Clean                                                                                                                       |
| `markdownlint-cli2`                                            | Clean, per `.markdownlint-cli2.jsonc`                   | Clean                                                                                                                       |
| `zig build test`                                               | Passes, untouched                                       | Passes                                                                                                                      |

The duplicated-feature run is the one that matters most. It compiles, `zig build test` passes, and only the validator catches it, which proves the new gate reaches the descriptor through `cmake/entry.cpp` rather than merely asserting a file exists.

Re-run after merging `main`, which brought in [#3](https://github.com/cboone/fosforo/issues/3)'s audio ports, state, and log extensions: both bundles report 44 run, **21** passed, 0 failed, 0 warnings, 23 skipped. The absolute number moves whenever an extension lands; what this job guards is that the two bundles keep agreeing, and they do.

## Note on the PR that carried this

The pull request opened with no CI at all, which was a real signal rather than a fluke. `main` had moved while the branch was open, the branch conflicted, and so `refs/pull/16/merge` never existed. GitHub does not start `pull_request` workflow runs until it can compute that ref, so all three workflows stayed silent while `workflow_dispatch` on the same branch ran fine. A conflicting PR looks exactly like a PR whose checks have not started yet. `gh pr view --json mergeable` distinguishes them: `mergeable: false`, `mergeable_state: dirty`.

On the pull request:

| Check                   | Expectation                                                                                                                   |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `clap-validator` job    | Green, and **cache hit**. The pins are unchanged, so a miss means the composite action's key stopped resolving to the old one |
| `clap-wrapper` job      | Green, cache hit, log shows both artifacts built and the CLAP validated                                                       |
| `ci` and `shaders` jobs | Unaffected                                                                                                                    |
| Second run              | Still hits in both jobs                                                                                                       |

The cache hit on the first run is the check most worth watching. A key that stopped matching still passes; it just quietly pays a full Rust build in two jobs instead of none.

## Notes for execution

- Invoke `write-bash-scripts` before touching any shell in the workflow or action, and `write-markdown` before the documentation edits.
- All three macOS jobs still contend for the same runner pool. This change holds a slot longer; it does not add one.
