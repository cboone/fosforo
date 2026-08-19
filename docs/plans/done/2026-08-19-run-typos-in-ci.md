# Run `typos` in CI and stop short commit SHAs from failing it

Addresses [issue #28](https://github.com/cboone/fosforo/issues/28).

## Context

`typos.toml` has been in the repository since 2026-07-25, added in `5ddf044` to allowlist `precessing` in the design document. Nothing has ever run the tool it configures. Grepping `.github/` for `typos`, `spell` or `codespell` returns nothing, the reusable `run-zig-ci.yml` at the pinned revision declares only `test`, `format`, `build`, `cross-compile` and `scrut`, and `AGENTS.md`'s Development block does not mention the tool. So the check is neither automated nor discoverable by hand, and the allowlist it carries has never been exercised.

This is the same shape as the gap [#19](https://github.com/cboone/fosforo/issues/19) closed for the GUI smoke path and [#10](https://github.com/cboone/fosforo/issues/10) closed for `clap-validator`: a check the repository appears to have and does not enforce. The consequence is already real. `typos` **fails on this tree right now**, and would have failed on `main`, because the last three letters of the short commit SHA `91f9abd` read to it as a misspelling of `and`.

Issue #28 offers deleting `typos.toml` as an equally honest resolution. Wiring it in was chosen instead.

The order of the work matters. The short-SHA false positive is structural rather than incidental here: every GitHub Action in this repository is pinned by commit and the pins get explained in prose, so this class recurs every time a pin is documented. Wiring the tool in without suppressing that class first would produce a job that cries wolf, and would land red.

## What was verified

Everything below was confirmed against this worktree with `typos` 1.49.0, not assumed.

<!-- prettier-ignore -->
| Claim                                                            | Result                                                                     |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Bare `typos` fails on this tree                                  | Yes, **exit 2**, two errors                                                |
| Both errors are the same cause                                   | Yes, both from `91f9abd`, twice in one done plan                           |
| `typos` 1.49.0 has an inline ignore directive                    | **No.** Its reference documents configuration as the only mechanism        |
| Any other finding anywhere in the tree                           | **None.** Those two are the entire backlog                                 |
| Every short SHA in prose is backticked                           | Yes, ten occurrences, all inside backticks                                 |
| Any bare short SHA a backtick-anchored pattern would miss        | **None** found across tracked Markdown                                     |
| Local `typos` version matches the latest upstream release        | Yes, both 1.49.0, so the CI pin matches what is on this machine            |
| `ci.yml` ignores `*.md`, `docs/**`, `**/AGENTS.md`, `.claude/**` | Yes, on **both** the `push` and `pull_request` triggers                    |
| `--isolated` flags `precessing`, configured run is silent        | Yes, exit 2 isolated and exit 0 configured                                 |
| Linux release asset layout                                       | `./typos` sits at the tarball root beside `doc/`, `README.md` and licenses |
| SHA256 of `typos-v1.49.0-x86_64-unknown-linux-musl.tar.gz`       | `48bd2d58e02ce713b8c0f1aa239e68ee4f7d8c551013135806e6aed3938d9e10`         |
| Upstream publishes a checksum manifest with the release          | **No.** Same as shfmt and shellcheck, so the sum is committed here         |

Two rows are load-bearing. The `paths-ignore` one decides where this job goes. The inline-directive one decides how documents that explain the check survive it, which is not a hypothetical: this plan is a tracked Markdown file, the job will read it forever, and a plan about a spell checker has to be able to name what the spell checker catches.

## Why a separate workflow rather than a job in `ci.yml`

`ci.yml` ignores `*.md`, `docs/**`, `LICENSE`, `.claude/**`, `**/CLAUDE.md` and `**/AGENTS.md` on both triggers. That is correct for a workflow whose jobs are macOS builds costing ten times an Ubuntu minute, and exactly wrong for a spell checker: the files it exists to check are the files that skip it. A `typos` job added to `ci.yml` would be green on every pull request that could have failed it, which reproduces the defect this issue is about in a subtler and harder-to-notice form.

`paths-ignore` is workflow-level, not job-level, so there is no way to exempt one job from it. The alternative, dropping `*.md` and `docs/**` from those lists, would run the CMake build and four macOS jobs on every typo fix, which the `shell` job's comment already argues against on cost grounds.

`.github/workflows/typos.yml` therefore stands alone, next to `gitleaks.yml` and `trufflehog.yml`, which are the repository's other whole-tree scans and are likewise separate for the same reason. It carries no `paths-ignore` at all, on the precedent that keeps `.editorconfig` out of `ci.yml`'s lists: a check must not be able to skip the change that governs it, and here the config and the workflow both live in the set it scans.

## Changes

### 1. Add two ignore patterns to `typos.toml`

Add a `[default]` section above the existing `[default.extend-words]`, since TOML assigns bare keys to the most recently opened table:

```toml
[default]
extend-ignore-re = [
  # Every GitHub Action here is pinned by commit and the pins get explained in
  # prose, so short SHAs appear throughout this repository's Markdown. typos
  # already skips 40-character hex strings and not 7-character ones, which
  # makes `91f9abd` read as a misspelling of `and`. This suppresses the class
  # rather than the two occurrences that exist today: it recurs on every
  # documented pin.
  "`[0-9a-f]{7,40}`",

  # The escape hatch a document needs in order to quote what this tool catches.
  # typos has no inline directive at 1.49.0, so a plan or a gotcha that spells
  # a misspelling out, which is the only way to explain one, fails the check it
  # is explaining. A marked span is narrower than excluding the file: it is
  # visible in the diff, it names itself, and it ends.
  "(?s)<!-- spellchecker:off -->.*?<!-- spellchecker:on -->",
]
```

The SHA pattern is anchored on the backticks rather than on a word boundary, deliberately. Every short SHA in this repository's prose is already backticked, and an unanchored `\b[0-9a-f]{7,40}\b` would also swallow ordinary hex-alphabet words in running text. It narrows the tool rather than blinding it: a full-length pin and a short one are both ignored, and a misspelling beside either is still caught. The verification section proves that rather than asserting it.

The marker names follow the convention the typos ecosystem already uses for this pattern rather than inventing one, and the HTML-comment form is chosen because Markdown is the only place this repository needs it. It is not a mechanism added on speculation: this plan uses it immediately, in the one place a literal misspelling earns its keep.

Two details to confirm before relying on the second pattern, both first thing during implementation. Rust's `regex` crate supports `(?s)` and lazy repetition but no lookaround, so the span form should work as written; if it does not, the fallback is a line-scoped `"(?m)^.*<!-- spellchecker:ignore -->.*$"`. And an unclosed `off` marker fails safe, suppressing nothing rather than everything after it, which is the direction that should be verified rather than assumed.

### 2. Add `.github/workflows/typos.yml`

Modelled on `gitleaks.yml` for its triggers and on `ci.yml`'s `shell` job for how the tool is installed.

```yaml
name: typos

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

# Deliberately not a job in ci.yml. That workflow ignores `*.md`, `docs/**` and
# the agent config files on both triggers, which is right for a set of macOS
# builds and exactly wrong for a spell checker: the files this job exists to
# check are the files that would skip it. paths-ignore is workflow-level, so
# there is no way to exempt one job from it, and this one carries none at all,
# on the same reasoning that keeps .editorconfig out of ci.yml's lists.
#
# Ubuntu rather than macOS, matching the `shell` job: this is platform-
# independent static analysis and the macOS runner bills at ten times the rate.
jobs:
  check:
    runs-on: ubuntu-latest
    # Borrowed rather than measured: this job has never run. 3 comes from
    # `shell`, which is the same Ubuntu checkout plus a pinned download plus a
    # tree walk and peaks at 8s over 9 runs. Replace it with a real figure and
    # sample size once this pull request's runs supply one, the way every other
    # ceiling here was set (#17).
    timeout-minutes: 3
    env:
      # Pinned for the reason the shell tools are: a dictionary ships inside the
      # binary, so a new release can introduce findings with no change on this
      # side. A version in a URL is not a pin, because a release asset can be
      # replaced in place under the same tag; the sum below is the pin. Bump the
      # two together, with `shasum -a 256` on the downloaded asset.
      TYPOS_VERSION: "1.49.0"
      TYPOS_SHA256: "48bd2d58e02ce713b8c0f1aa239e68ee4f7d8c551013135806e6aed3938d9e10"
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      # Into RUNNER_TEMP rather than the workspace, unlike the `shell` job.
      # That one selects files through `git ls-files`, so an untracked download
      # beside the checkout is invisible to it; this one walks the working tree,
      # and a tarball left in the checkout would be one more thing the run
      # depends on typos choosing to skip.
      #
      # Downloaded to a file rather than piped into tar, so nothing consumes the
      # bytes before the sum has verified them. Upstream publishes no checksum
      # manifest, and fetching one from the host that serves the asset would
      # verify transport rather than provenance.
      - name: Install typos
        run: |
          cd "${RUNNER_TEMP}"
          curl -sSfL -o typos.tar.gz \
            "https://github.com/crate-ci/typos/releases/download/v${TYPOS_VERSION}/typos-v${TYPOS_VERSION}-x86_64-unknown-linux-musl.tar.gz"
          echo "${TYPOS_SHA256}  typos.tar.gz" | sha256sum --check --strict -
          tar -xzf typos.tar.gz ./typos
          sudo install typos /usr/local/bin/typos

      # Confirms the pin resolved to the intended version, so a sum bumped
      # without its version, or the reverse, fails here rather than silently
      # checking against a different dictionary than the tree was cleared with.
      - name: Report tool version
        run: typos --version

      # No arguments: typos defaults to `.`, discovers typos.toml by walking up
      # from there, and respects .gitignore, which is why the config's
      # extend-exclude list only has to name the build outputs .gitignore
      # already covers. Exit 2 on a finding is what gates the job.
      - name: Check spelling
        id: typos
        run: typos

      # Only on the failing path, matching the clap-validator jobs. The default
      # output is already legible in the log; this lifts it into the run summary
      # where it is readable without opening one.
      - name: Summarize the findings
        if: failure() && steps.typos.outcome == 'failure'
        run: |
          {
            echo "### typos"
            echo
            echo '```text'
            typos --format brief || true
            echo '```'
          } >> "${GITHUB_STEP_SUMMARY}"
```

No step asserts that `typos.toml` was found, and none is needed. A config that went unread fails loudly rather than quietly: `precessing` and the SHAs would both start reporting. The silent-failure direction this repository usually guards against does not exist here.

### 3. Record it in `AGENTS.md`

`CLAUDE.md` is a symlink to `AGENTS.md`, so only the one file is edited.

Add to the `## Development` block, after the `shellcheck` line:

```bash
typos                      # spell-checks the whole tree; allowlist and ignores in typos.toml
```

Add a `## Gotchas` bullet, in the shape of the existing entries:

> - **`typos` runs from its own workflow, and both halves of that are what make it run at all.** `.github/workflows/typos.yml` is separate from `ci.yml` because that workflow ignores `*.md`, `docs/**` and the agent config files on both triggers, which is right for a set of macOS builds and exactly wrong for a spell checker: the files it exists to check are the files that would skip it, so a job added there would be green on every pull request that could have failed it. `paths-ignore` is workflow-level, so no job can be exempted from it. The typos workflow therefore carries none, on the precedent that keeps `.editorconfig` out of `ci.yml`'s lists, and it runs on Ubuntu because spell checking is platform-independent and the macOS runner bills at ten times the rate. The other half is `extend-ignore-re` in `typos.toml`. Every Action here is pinned by commit and the pins get explained in prose; `typos` skips 40-character hex strings and not 7-character ones, so `91f9abd` reads to it as a misspelling of `and`. That is not one finding in one plan file but a class that recurs on every documented pin, and it is why this check was failing on `main` at the moment it was written. The pattern is anchored on backticks rather than on a word boundary, so a full-length pin and a short one are both ignored while a misspelling beside either is still caught. **Add to `typos.toml` rather than rewording a word the tool is wrong about**, which is what the `precessing` entry is: a phase-space loop that slowly rotates exhibits precession, whatever the audio context suggests.

### 4. Record it in `CONTRIBUTING.md`

Three small additions, matching how `shfmt` and `shellcheck` are already handled there:

- `### Requirements`: `typos`, for the spell check CI runs over the whole tree. CI pins 1.49.0, and `brew install typos-cli` is what put it on this machine
- `## Code Style`: keep `typos` clean by running it before committing. It reads `typos.toml`; add an allowlist entry or an ignore pattern there rather than rewording a word the tool is wrong about
- `## Pull Request Process`: a step after the formatting one, `typos`

## Files touched

<!-- prettier-ignore -->
| File                            | Change                                                              |
| ------------------------------- | ------------------------------------------------------------------- |
| `typos.toml`                    | New `[default]` section with `extend-ignore-re`                     |
| `.github/workflows/typos.yml`   | New. One Ubuntu job, pinned binary and checksum, no `paths-ignore`  |
| `AGENTS.md`                     | One Development command and one Gotchas bullet                      |
| `CONTRIBUTING.md`               | Requirements, Code Style, Pull Request Process                      |

`docs/plans/done/2026-07-29-tighten-ci-job-timeouts.md` is **not** modified, per the issue's own scope note. Plans in `docs/plans/done/` are historical records, and rewording one to satisfy a tool would be the wrong repair. The config change is what makes it pass.

## Verification

Run from the worktree root, in this order. The first command is a negative control and must be run **before** the config change, since the point of it is that the check is currently failing.

```bash
# Negative control, before the config change. Expect exit 2 and two findings,
# both in docs/plans/done/2026-07-29-tighten-ci-job-timeouts.md.
typos; echo "exit: $?"

# After change 1, over the whole tree, this plan file included. Expect silence
# and exit 0. If this plan still reports, the marked span below is not working.
typos; echo "exit: $?"

# The instrument, checked against itself. --isolated ignores implicit config
# files, so this proves typos.toml is what makes the tree pass rather than the
# tool having nothing to say. Already confirmed during planning: isolated
# reports `precessing` and exits 2, configured is silent and exits 0.
typos --isolated docs/design/scope-plugin-handoff.md   # expect: `precessing` flagged, exit 2
typos docs/design/scope-plugin-handoff.md              # expect: silent, exit 0

# Nothing else regressed.
zig build test
zig fmt --check build.zig src/
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck
markdownlint-cli2
```

The positive control is the one that matters most, because it is what separates a narrowed tool from a blinded one. It is written into the worktree so the repository's own `typos.toml` applies, and it holds a short pin, a full-length pin, and one deliberate misspelling. Expect exactly one finding, the misspelled word, with neither SHA reported:

<!-- spellchecker:off -->

```bash
printf 'Pinned at `91f9abd` and `91f9abd25d4f82354c0f950dfc8b6d7525b0f5b5`; please recieve this.\n' > control.md
typos                     # expect: one finding, `recieve` in control.md
rm control.md
typos; echo "exit: $?"    # expect: silent again, exit 0
```

<!-- spellchecker:on -->

That block is itself the check on the second ignore pattern, and it verifies in both directions. With the markers present, `typos` must be silent about the deliberate misspelling above. Delete the two marker lines and it must report it again. A pattern that suppresses in only one of those two states is not doing what the comment in `typos.toml` claims.

On the pull request, confirm the `typos` workflow appears and passes, and that it starts green rather than needing a follow-up fix. Then record its measured duration and replace the borrowed `timeout-minutes: 3` with a real figure and sample size, per #17.

The docs-only case, which is the whole reason this workflow is separate, cannot be proven on this pull request: the branch touches `.github/` and `typos.toml`, so `ci.yml` triggers anyway. It is confirmed by the next docs-only pull request, where `typos` should be present and `ci` absent.

## Commits

Three, each self-contained and reviewable, all referencing #28:

1. `chore: teach typos about pinned SHAs and marked spans (#28)` — `typos.toml` alone, which takes the tree from failing to clean before anything runs the tool
1. `ci: run typos on every push and pull request (#28)` — the new workflow
1. `docs: document the typos check and its two ignore patterns (#28)` — `AGENTS.md` and `CONTRIBUTING.md`

The plan file moves to `docs/plans/done/` as part of the pull request, following the repository's convention.

## Out of scope

- **Editing the done plan to remove the short-SHA finding.** The issue says so explicitly, and `.github/copilot-instructions.md` already tells reviewers not to suggest wording edits to files in `docs/plans/done/`.
- **`markdownlint-cli2`.** `.markdownlint-cli2.jsonc` is in exactly the same state `typos.toml` is in: a config file with careful reasoning in its comments that no automation reads. `AGENTS.md` does not list it either, and `.editorconfig` defers to its MD009 rule for a behaviour nothing enforces. That is a sibling issue worth filing after this lands, not work to fold in here.
- **Adding a spell check to the reusable `cboone/gh-actions` workflows.** It would change every consumer of them and belongs in that repository.

## Issue housekeeping

Before the first commit, self-assign #28 and add the `in progress` label. Leave the label in place after the work lands locally; it comes off when the pull request merges, not when the branch is pushed.

## Outcome

Everything above landed as planned, in four commits rather than three: the plan file took its own, so that every commit leaves the tree clean under the check the second one introduces.

Every control returned what the plan predicted, and the two that could have gone the other way did not.

<!-- prettier-ignore -->
| Control                                                     | Result                                                                |
| ----------------------------------------------------------- | --------------------------------------------------------------------- |
| Negative, before the config change                          | Exit 2, nine findings across the done plan and this one               |
| Whole tree, after it                                        | Silent, exit 0                                                        |
| Sample with a short pin, a full pin and one misspelling     | Only the misspelling reported: it narrows without blinding            |
| Marked span, unmarked copy, unclosed marker                 | Silent, reported, reported. The unclosed case fails safe              |
| `typos --isolated` against the design document              | `precessing` reported, and silent with the config, so it is read      |
| `actionlint` on the new workflow and a broken one           | Silent, then a finding, so its silence means something                |
| Download, sum check and `tar -xzf typos.tar.gz ./typos`     | Verified against the pinned asset: a static x86-64 Linux binary       |

`zig build test`, `zig fmt --check`, `shfmt`, `shellcheck` and `markdownlint-cli2` were all clean afterwards.

Two things are still owed and cannot be settled from here. The `timeout-minutes: 3` is still borrowed from `shell` rather than measured, and gets replaced once this pull request's runs supply a figure and a sample size. And the docs-only trigger case, which is the whole reason this workflow stands apart from `ci.yml`, is only confirmed by a later docs-only pull request showing `typos` present and `ci` absent.
