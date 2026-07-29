# Run clap-validator in CI

Addresses [#10](https://github.com/cboone/fosforo/issues/10).

## Context

`clap-validator` was named as required verification in five places in this repository, and no CI job ran it. It was a local-only step, so its results depended on someone remembering to run it by hand.

| Where                       | What it says                                                   |
| --------------------------- | -------------------------------------------------------------- |
| Plan, Verification table    | `clap-validator validate` passes is a named verification layer |
| Plan, Phase 0 exit criteria | Required **both** built artifacts to pass it                   |
| Plan, Phase 1 exit criteria | Requires it to report more than the original 3 passing tests   |
| ADR 0003                    | Names it as central to the development loop                    |
| `AGENTS.md`                 | Documents it as the validation command                         |

Nothing in the ADRs, the plan, or the commit history recorded a reason to keep it out of CI, so this read as an omission rather than a decision. The nearest recorded reasoning is ADR 0009, which keeps `zig build validate-shaders` out of `zig build test` to protect the hermetic build but explicitly wants it run "as a separate step, run explicitly and in CI". That is the shape adopted here.

The failure mode this guards against is quiet. A descriptor field going null, a lifecycle callback losing `callconv(.c)`, or a factory returning a stale pointer all compile cleanly, pass `zig build test`, and surface only as a validator failure or a crash inside someone's DAW. Issue #2 took the plugin from 3 passing tests to 16, and that number was a claim in a commit message rather than something enforced.

## Findings that shaped the design

Read from the `0.4.1` tag of `free-audio/clap-validator` before planning.

- **Tag `0.4.1` is commit `152b9823e992d782c5c1fd33bca0295478b919aa`.** That is the version installed locally. `master` is well ahead of it.
- **The exit code is trustworthy for failures.** `src/commands/validate.rs` returns `ExitCode::SUCCESS` when `tally.num_failed == 0` and `ExitCode::FAILURE` otherwise, and `src/validator.rs` counts both `TestStatus::Failed` and `TestStatus::Crashed` into `num_failed`. Source-level evidence only, which is why the empirical check below was a required step rather than an optional one.
- **Warnings do not fail the run.** `TestStatus::Warning` increments `num_warnings`, which the exit code ignores. Accepted deliberately: warnings stay visible in the log without being able to turn CI red on their own.
- **MSRV is 1.95.0 and the crate is edition 2024.** The runner image's preinstalled Rust may or may not clear that bar, and it changes without notice.
- **`--json` and `--only-failed` compose,** which is what makes the failure summary cheap.
- **The reusable `run-zig-ci.yml` workflow uploads no artifacts,** so the new job runs `zig build` itself. That is the fast path and never touches CMake.

## Decisions

- **Validate the Zig-built artifact only.** `zig-out/Fosforo.clap` is what the development loop and CLAP-native hosts consume, and ADR 0003 makes it the thing being debugged. The clap-wrapper-built `.clap` under `build/assets/` stays unvalidated in CI; the Phase 0 exit criteria checked both, so that gap is recorded rather than silently dropped.
- **`audio-unit-sandbox` is left alone.** It asserts one thing about a from-scratch CMake build and should keep doing exactly that.
- **Pin the validator to a commit, not a tag or a branch.** Tags can move; a commit cannot. Upstream cannot turn CI red without a change here.
- **Pin the Rust toolchain to an exact stable.** The same reasoning one level down. It only ever builds the validator, and only on a cache miss.
- **Gate on the human-readable run.** Its output is already well formatted, and the failure path pays for the JSON summary rather than every passing run.

## Changes

### 1. A `clap-validator` job in `.github/workflows/ci.yml`

A third sibling of `shaders` and `audio-unit-sandbox`, on `macos-latest`, matching their existing shape: pinned action SHAs with version comments, `timeout-minutes`, and a comment block explaining why the job exists rather than what it runs.

Pins:

| Thing                   | Pin                                                                         |
| ----------------------- | --------------------------------------------------------------------------- |
| `clap-validator`        | `152b9823e992d782c5c1fd33bca0295478b919aa` (tag `0.4.1`)                    |
| Rust                    | `1.97.1`, matching the local toolchain                                      |
| `actions/checkout`      | `11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2), as used elsewhere here |
| `actions/cache/restore` | `0057852bfaa89a56745cba8c7296529d2fc39830` (v4.3.0)                         |
| `actions/cache/save`    | `0057852bfaa89a56745cba8c7296529d2fc39830` (v4.3.0)                         |
| `mlugg/setup-zig`       | `d1434d08867e3ee9daa34448df10607b98908d29` (v2.2.1), as used elsewhere here |

Step order:

1. `actions/checkout`.
1. `actions/cache/restore` over `${{ runner.temp }}/clap-validator`, keyed on `clap-validator-<os>-<arch>-<validator rev>-rust<version>`. No `restore-keys`: a partial match would silently run a validator built from a different commit.
1. Build the validator, only on a cache miss:

   ```bash
   rustup toolchain install "${RUST_VERSION}" --profile minimal --no-self-update
   cargo "+${RUST_VERSION}" install \
     --git https://github.com/free-audio/clap-validator \
     --rev "${VALIDATOR_REV}" \
     --locked \
     --root "${RUNNER_TEMP}/clap-validator"
   ```

   `--locked` uses the committed `Cargo.lock`, so a new release of a transitive dependency cannot change what gets built. `--root` keeps the binary out of the runner's `~/.cargo/bin`, so the cached path holds exactly what this job built.

1. `actions/cache/save`, also only on a cache miss, reusing `steps.validator-cache.outputs.cache-primary-key` so the two keys cannot drift. Restore and save are split rather than using the combined action so the save is an explicit step on the success path.
1. Put `${RUNNER_TEMP}/clap-validator/bin` on `$GITHUB_PATH`.
1. `mlugg/setup-zig` with `version-file: build.zig.zon`, then `zig build`.
1. `clap-validator validate zig-out/Fosforo.clap`. This step is the gate.
1. On failure only, re-run with `--json --only-failed` and render a table into `$GITHUB_STEP_SUMMARY` with `jq`. Scoped to `failure() && steps.validate.outcome == 'failure'` so a `zig build` failure, which leaves no bundle to validate, does not produce an empty table. Terminated with `|| true` so a reporting problem cannot mask the real failure.

`VALIDATOR_REV` and `RUST_VERSION` are job-level `env`, so the cache key and the install step cannot drift apart.

### 2. Confirm the exit code empirically

The issue called this out in bold, and it was the one step that could not be inferred. Source reading established intent; this established the fact, end to end, through the same command the job runs.

The breakage chosen was a duplicated entry in the descriptor's `features` array, because it is precisely the class of defect this job exists to catch: it compiles, and `zig build test` still passes because the existing assertions check the first element and the length, both of which stay consistent.

Observed:

| Run                            | `zig build test` | `clap-validator` result                             | Exit |
| ------------------------------ | ---------------- | --------------------------------------------------- | ---- |
| Baseline                       | passes           | 44 run, 16 passed, 0 failed, 0 warnings, 28 skipped | 0    |
| Duplicate feature entry        | passes           | 44 run, 15 passed, 1 failed, 0 warnings, 28 skipped | 1    |
| Baseline, after `git checkout` | passes           | 44 run, 16 passed, 0 failed, 0 warnings, 28 skipped | 0    |

The failing test was `features-duplicates`, reported as `FAILED`. The exit code is real; the job gates on something.

The `--json --only-failed` output from that same broken build was captured and the summary step's `jq` filter written against it rather than against a guess at the schema. Both result shapes, `plugin-library` and `plugin-instance`, nest the test name one level down under a group key, which is why the filter reads `.test | to_entries[0].value`.

### 3. Documentation the job now backs

- `AGENTS.md`: the Development section notes that CI runs `clap-validator` and that `auval` is still manual. A Gotchas entry covers the two pins and the fact that warnings do not fail the job.
- `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`: the Verification table's `Plugin`, `Audio Unit`, and `CI` rows now distinguish what is enforced from what is still manual. The Phase 0 and Phase 1 exit criteria are left as the historical record they are.
- `CHANGELOG.md`: an entry under `## [Unreleased]`, `### Changed` rather than `### Added`, since this is CI infrastructure and not a user-facing plugin change.

### 4. The deferred gap

The clap-wrapper-built `.clap` is not validated. A follow-up issue records this rather than leaving it implicit: `make_clapfirst_plugins` already declares a `fosforo_clap` target emitting into `build/assets/`, so the work is a `--target fosforo_clap` build plus one validate step, most naturally inside `audio-unit-sandbox` where the CMake cost is already paid.

**Closed.** [#12](https://github.com/cboone/fosforo/issues/12) did exactly that, and folded in [#7](https://github.com/cboone/fosforo/issues/7); `audio-unit-sandbox` is now `clap-wrapper`. See `docs/plans/done/2026-07-29-validate-the-clap-wrapper-built-clap.md`.

## Files

| File                                                                  | Change                                             |
| --------------------------------------------------------------------- | -------------------------------------------------- |
| `.github/workflows/ci.yml`                                            | New `clap-validator` job                           |
| `AGENTS.md`                                                           | Development note plus a Gotchas entry for the pins |
| `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md` | Verification table rows                            |
| `CHANGELOG.md`                                                        | `### Changed` entry under `## [Unreleased]`        |

`CLAUDE.md` is a symlink to `AGENTS.md`, so it needs no separate edit.

`ci.yml` carries `paths-ignore` covering `docs/**` and `*.md`, so a commit touching only documentation does not trigger the workflow. The commits are sequenced so the `ci.yml` change lands first and is exercised.

## Verification

| Check                                               | Expectation                                         | Result                                   |
| --------------------------------------------------- | --------------------------------------------------- | ---------------------------------------- |
| `actionlint .github/workflows/ci.yml`               | Clean                                               | Clean                                    |
| `markdownlint-cli2`                                 | Clean, per `.markdownlint-cli2.jsonc`               | Clean                                    |
| `zig build test`                                    | Passes, unchanged                                   | Passes                                   |
| Local baseline                                      | Exit 0, 16 passed, 0 failed                         | Confirmed                                |
| Local deliberate breakage                           | Non-zero exit, at least one `FAILED` or `CRASHED`   | Confirmed, exit 1, `features-duplicates` |
| Summary step against real failing JSON              | Renders a Markdown table                            | Confirmed by dry run                     |
| First CI run on the PR                              | `clap-validator` job green; cache misses and builds | Pending                                  |
| Second CI run                                       | Cache hit, so no `cargo install` step runs          | Pending                                  |
| Existing `ci`, `shaders`, `audio-unit-sandbox` jobs | Unaffected                                          | Pending                                  |

Confirm the cache actually hits on the second run. A key that varies per run makes this job pay a full Rust build every time, which is the failure mode most likely to go unnoticed because the job still passes.
