# Split AGENTS.md into topic notes and guard the budget

Issue: [#117](https://github.com/cboone/fosforo/issues/117). Type: `docs:`. Branch: `chore/refactor-claude-md`, stacked on `chore/improve-linting`.

## Context

`AGENTS.md` is 165,013 characters and `CLAUDE.md` is a committed symlink to it, so Claude Code loads all of it into every session before any work starts. It reports `CLAUDE.md is over the 150.0k-char limit (164.9k chars)` at startup.

**That 150,000 is the most generous threshold this file will ever be measured against, and it is the wrong one to design for.** Read out of the CLI, the threshold is `Math.max(40000, Math.round(contextWindow * 0.05 * charsPerToken))`, where `charsPerToken` is 4 for a hardcoded set of model ids running `claude-3-opus` through `claude-haiku-4-5` and 3 for anything outside it. Opus 5 is outside that set, and this session runs the 1M-context variant, so the product is `1,000,000 * 0.05 * 3 = 150,000`. Every other configuration collapses to the 40,000 floor:

| Session                   |   Context | chars/token | Threshold | 164.9k over by |
| ------------------------- | --------: | ----------: | --------: | -------------: |
| Opus 5 (1M), this session | 1,000,000 |           3 |   150,000 |         14,913 |
| Opus 5, non-1M            |   200,000 |           3 |    40,000 |        125,013 |
| Sonnet 5                  |   200,000 |           3 |    40,000 |        125,013 |
| Opus 4.6, Sonnet 4.6      |   200,000 |           4 |    40,000 |        125,013 |
| Haiku 4.5                 |   200,000 |           4 |    40,000 |        125,013 |

A subagent launched with a `model` override drops to the floor as well, so the file is over budget for most of the work this repository dispatches. **The target is under 40,000.**

The cut is affordable because the file is not 165 KB of unique knowledge. `## Gotchas` is 141,992 of the 165,013 characters, 89 top-level bullets in one flat list with no subheadings, and roughly 70% of it restates an ADR or a completed plan in _less_ depth than the original. The remaining 30% exists nowhere else: measured tables, refusals and figures a repo-wide `grep -F` finds in no other file. **That 30% is why this is a move and not a delete**, and it is what a careless reduction would destroy.

The growth mechanism is plain: 139 commits have touched `AGENTS.md`, and nearly every issue closes with a `docs: record …` commit appending to Gotchas. Nothing bounds it. So the outcome wanted is not only a smaller file but a shape that stays small: depth in topic documents opened on demand, a written budget, and a CI check, because this repository has now found four separate tools configured, believed to be running, and silently not ([#28](https://github.com/cboone/fosforo/issues/28), [#85](https://github.com/cboone/fosforo/issues/85), [#99](https://github.com/cboone/fosforo/issues/99), and `mlugg/setup-zig`'s inert `version-file`).

## Decisions taken before this plan was written

- Target **under 40,000** characters, not 150,000.
- Depth moves to a new **`docs/notes/`** directory of living topic documents with a `README.md` index, mirroring `docs/adr/README.md`.
- The guard is a **size check** plus a **written budget rule** in `AGENTS.md`. **`markdownlint` is not in scope**: `chore/improve-linting` owns [#85](https://github.com/cboone/fosforo/issues/85) and [#106](https://github.com/cboone/fosforo/issues/106) and has already landed them.
- The four drift findings are fixed **in this branch**.
- **This branch rebases onto `chore/improve-linting` and opens as a stacked pull request against it**, rather than waiting for it to merge or fighting its Prettier reformat. See "Stacking" below.
- A GitHub issue is filed first, so the header above cites one like every other plan here.

## What changed under this branch while it was being planned

`chore/improve-linting` committed three times in the last half hour and it moves the ground this plan stands on:

- `style: format every Markdown file with prettier (#106)` reformatted **64 files**, `AGENTS.md` among them, taking it to **166,639** characters and touching 107 of its lines.
- `ci: run prettier and markdownlint over every Markdown file (#85)` added **`.github/workflows/markdown.yml`**, 117 lines, carrying **no `paths-ignore`** and the full argument for why, plus `package.json`, `package-lock.json`, `.prettierrc.json` and `.prettierignore`.
- `docs: record that Markdown formatting is enforced (#85)` replaced the `markdownlint-cli2` gotcha with a pair of bullets on the Prettier/markdownlint division of labour.

Three consequences, all folded into this plan below. **The size guard is a job in `markdown.yml`, not a new workflow**, since that file already exists, already carries the no-`paths-ignore` reasoning, and splitting Markdown enforcement across two workflows would duplicate it. **Prettier is now the fixer**, so the rule this plan was going to preserve verbatim ("never pass `markdownlint --fix`") is superseded by "run `npx prettier --write` first, then verify"; take the wording from `improve-linting` rather than restating it. And **every new `docs/notes/*.md` must be Prettier-formatted** and will be judged by `markdown.yml`.

**Every character count in this plan was taken at 165,013, before that reformat.** After the rebase the baseline is 166,639 and Prettier has reflowed 107 lines, so the per-file totals in the split table below move by roughly a percent. Re-measure before quoting any of them as a result; they are accurate enough to size the work and not accurate enough to publish.

## Stacking

`origin/chore/improve-linting` is at `dc55f93`, six commits, with its own plan already moved to `done/`, so it is ready to open. This branch rebases onto it and opens against it.

**Open it with `gh stack`, not `gh pr create --base`**, and this is not a style preference. [#87](https://github.com/cboone/fosforo/issues/87) established that GitHub triggers a _native_ stacked pull request as if every member targeted the stack's base, while one retargeted by hand is not a native stack and hits three gaps that make CI silently not run. The extension is not installed here: `gh extension install github/gh-stack` first. If it is opened by hand instead, the three gaps are: a push to the parent fires no event on the child, because `synchronize` means the head moved, so a green child can describe a merge against an older parent; auto-retargeting after the parent merges is an `edited` event, which is not in the default activity set, so that fires nothing either; and closing and reopening the child is the cheapest unblock, since `reopened` is a default activity type and runs the real merge ref.

Two things this does _not_ need. `ci.yml`'s `pull_request` trigger no longer carries `branches: [main]`, so a pull request against any base dispatches it (#87). And `concurrency` is keyed by `github.ref`, which is `refs/pull/N/merge`, so two members of one stack cannot collide.

Expect `ci.yml` to run nothing on this pull request, and that is correct rather than a symptom: its `paths-ignore` covers `*.md`, `docs/**`, `**/CLAUDE.md` and `**/AGENTS.md` on both triggers, and this is a documentation change plus one shell script. `markdown.yml` and `typos.yml` carry no `paths-ignore` and are the two that judge it. `paths-ignore` reads the `base...head` diff, which for a stacked pull request is this branch's own changes against its parent, not against `main`.

The convention that mitigates the rest is rebasing onto `main` and retargeting before merge, and it is a convention rather than a mechanism.

## What the audit measured

Re-measured after the rebase, at the 166,639 baseline:

| Section              |   Chars | Share |
| -------------------- | ------: | ----: |
| `## Gotchas`         | 143,429 | 86.1% |
| `## Current state`   |  10,003 |  6.0% |
| `## Development`     |   4,960 |  3.0% |
| `## Structure`       |   4,031 |  2.4% |
| `## Releasing`       |   2,046 |  1.2% |
| `## Non-negotiables` |   1,929 |  1.2% |
| `## Overview`        |     230 |  0.1% |

Deleting every section except Gotchas still leaves 143 KB, so the target is decided entirely inside Gotchas.

**Sixteen categories of material exist only in `AGENTS.md`**, verified by repo-wide `grep -F` returning zero hits elsewhere: both capture-guard margin tables (a completed plan explicitly designates `AGENTS.md` as their home); the `t = 0.9` quantization ladder; the colour-space error measurement; the `SATURATED` 8338-of-2,073,600 figure; the six-defect by five-instrument leak blindness matrix; the moiré ceiling bullet, the railing sweep and the 54-versus-31-frame persistence doubling; the one-host-stream rule, the GPU/window-server exclusivity paragraph and the host-mention count retraction; the hardened-runtime entitlements measurement; the CI macOS five-concurrent-job arithmetic; `ruff` 0.16.5's `PLW`/`EXE` rule set and the `typos` word-versus-identifier rule; the shader compile-cost distribution; the `CAMetalDisplayLink` availability finding; the `clap-host` operational details; the `pyobjc` window-id one-liner and the observed REAPER window titles; and the AUv2 `_destroyWindow` behaviour. These move verbatim and are never summarised.

## The split

Fourteen topic documents plus an index. They are **living documents**, so they take `docs/adr/`'s naming shape (kebab-case, no date, no frontmatter) rather than the dated plan shape.

**Files are cut by trigger, not by topic**: the question is "what am I about to do", never "what is this about", because an agent reliably knows which files it is about to touch and unreliably knows which topic it is in.

| `docs/notes/` file              | `AGENTS.md` bullets (by line)    |       Chars |
| ------------------------------- | -------------------------------- | ----------: |
| `measuring-a-capture.md`        | 270, 277, 299, 300, 301, 315     |      18,820 |
| `ci-workflows.md`               | 397-402                          |      12,289 |
| `smoke-harness.md`              | 256, 257, 356, 357, 372          |      12,142 |
| `host-verification.md`          | 204, 359, 360, 361               |      12,031 |
| `shader-plumbing.md`            | 312, 340-345                     |      11,811 |
| `concurrency-and-canaries.md`   | 373-377, 404                     |      11,165 |
| `trace-and-phosphor-physics.md` | 313, 314, 331, 332, 333, 336-339 |      10,831 |
| `render-loop-lifecycle.md`      | 254, 255, 405, 406-416           |       9,310 |
| `build-system.md`               | 189-196, 202, 362, 363, 403      |       8,496 |
| `linters.md`                    | 393-396                          |       7,788 |
| `signing-and-notarization.md`   | 197-201, 203                     |       7,709 |
| `leak-instruments.md`           | 311, 378-381                     |       7,138 |
| `reading-diagnostics.md`        | 358, 417, 418                    |       6,292 |
| `the-test-suite.md`             | 364, 365                         |       6,158 |
| **Total**                       |                                  | **141,980** |

Five splits are deliberate and worth not undoing:

- **The linter bullets and the CI-workflow bullets separate.** One 20,077-char file would be read for the wrong half half the time: `linters.md` fires when running a linter, `ci-workflows.md` when editing `.github/workflows/`.
- **`leak-instruments.md` stays separate at 7,138.** Merging it into `smoke-harness.md` would force a 19,280-char read for a 700-char question. Bullet 311 moves here from the Metal cluster, because the blindness matrix it feeds lives here.
- **The Metal-hazards cluster is dissolved.** It was a residue category rather than a topic: 311 to leaks, 312 to shader plumbing, 313 and 314 to trace physics.
- **`host-verification.md` answers "can I trust this result?" and `reading-diagnostics.md` answers "where do I read a log line?"** The naming bullets (display name, permanent identifiers) go to `build-system.md`, because their trigger is a CMake or plist edit.
- **The `zig build test` bullet and the smoke-harness bullet separate**, into `the-test-suite.md` and `smoke-harness.md`.

`docs/notes/README.md` is an index in `docs/adr/README.md`'s exact form: prose saying what these files are and how they differ from an ADR (an ADR records a decision and is superseded rather than edited; a note records how a thing behaves and is corrected in place), then an aligned table of relative links.

One supersession must travel with its text: the `actionlint` bullet states that `docs/plans/done/2026-07-29-tighten-ci-job-timeouts.md` records a claim that is wrong and that the bullet "is the live statement". `ci-workflows.md` inherits that sentence, or the stale done plan silently becomes authoritative again.

## The new AGENTS.md

| Section                          |     Now |        New | Form                                                                                                                                                                                                              |
| -------------------------------- | ------: | ---------: | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Title and `## Overview`          |     230 |        240 | verbatim                                                                                                                                                                                                          |
| `## Current state`               |  10,005 |      2,600 | one "what is true now" paragraph, a bare list of landed issues, the next-issue line. The build plan's phase-3 and verification tables are the source of truth and carry a `Status` column this narrative does not |
| `## Non-negotiables`             |   1,929 |      1,929 | **verbatim, untouched**                                                                                                                                                                                           |
| `## Structure`                   |   4,031 |      3,400 | tree kept whole, the `scripts/` and `cmake/` annotations compressed, two corrected                                                                                                                                |
| `## Development`                 |   4,769 |      3,500 | the command block verbatim, the three prose paragraphs cut to ~500                                                                                                                                                |
| `## Releasing`                   |   2,046 |      1,500 | recipe and keychain command verbatim; the certificate-expiry diagnosis moves to `signing-and-notarization.md`                                                                                                     |
| `## Rules` (new)                 |       — |      2,800 | 14 imperative bullets, no argument, each with a pointer tail                                                                                                                                                      |
| `## Where the depth lives` (new) |       — |      3,800 | 14-row aligned table in `docs/adr/README.md`'s shape                                                                                                                                                              |
| `## Gotchas`                     | 141,992 |          0 | deleted                                                                                                                                                                                                           |
| **Total**                        | 165,013 | **19,769** | **20,231 under the 40,000 floor**                                                                                                                                                                                 |

**Gotchas is replaced by a pointer table, not by a compressed list.** Two alternatives were costed and rejected. Keeping all 89 bolded lead clauses is 12,884 characters and reproduces the exact failure being fixed, a flat 89-item list with no structure; worse, a lead clause without its qualifier is often _false_, and "Compiling the shader costs about 40 ms" reads as something to act on when the point of the bullet is that the figure is 0.14 ms on a warm cache. Keeping only the 48 bullets containing an imperative severs rules from their evidence and leaves an agent asking "why is my trace flat at zero?" with nothing to follow, since that answer is a pure record. The pointer table's failure mode is one extra tool call; the other two produce confidently wrong statements already in context.

Each pointer row carries **three to five keyword phrases naming the questions its document answers**, so a `grep` over `AGENTS.md` still finds the topic, and each trigger is phrased as a **path predicate** ("before editing `.github/workflows/*.yml`") rather than a topic predicate.

**These fourteen rules stay in `AGENTS.md` at full strength.** The selection test is that omitting the rule causes silent damage or a wrong pass, not a legible error:

1. Confirm provenance before trusting any host result; `zig build install-clap` is the whole answer.
2. One host stream at a time. The only rule here that damages another agent's run rather than yours.
3. Run the worktree's own `scripts/measure-trace`, never a copy from elsewhere.
4. The REAPER pipe needs `2>&1` and `grep --line-buffered`, and each fails differently. Kept as a rule as well as a command, because an agent that constructs the pipe rather than copying it omits both.
5. `zig build` does not rebuild the smoke harness.
6. Run Prettier before the Markdown linter, and never pass `--fix` to `markdownlint-cli2`. Take the exact wording from `improve-linting`.
7. When a diff corrects a measured figure, grep the old value repo-wide. Currently stated only in `.github/docs.instructions.md`, which Claude Code never loads.
8. `docs/plans/done/` is a historical record: never update a citation or a figure in one. Same provenance problem, and directly load-bearing for this refactor.
9. Captures go in `verification/`, never into a commit. Has already cost three rewritten commits.
10. Select files for `shfmt` with `git ls-files`, never `shfmt -d .` or `-w .`.
11. Verify at 48 kHz; structure appearing only above it is moiré, not signal.
12. No job counts or run counts in prose about CI.
13. Nothing reachable from the audio thread may allocate, lock, or make a syscall. Already in Non-negotiables; listed so the reduction cannot quietly drop it.
14. Metal must not leak above `src/gpu/iface.zig`. Same reason.

Two candidates were cut on purpose. **`Threaded.init`** is already verbatim in `## Non-negotiables`, and duplicating it creates two places to update, which is the disease being treated. **Do not `refAllDecls` the translated CLAP module** demotes to `build-system.md`: `src/clap/c.zig` already warns at the point of use, and the failure is a compile error rather than silent damage.

## The regrowth guard

**A `budget` job in `.github/workflows/markdown.yml`**, the workflow `improve-linting` just added. It already carries no `paths-ignore` and already records why, so this job inherits the argument instead of restating it. It cannot go in `ci.yml`: that workflow ignores `*.md`, `docs/**`, `.claude/**`, `**/CLAUDE.md` and `**/AGENTS.md` on both triggers, `paths-ignore` is workflow-level so no job can be exempted, and a size check there would be the fifth instance of "configured, believed to be running, silently is not".

**`scripts/check-doc-budget`**, on the `scripts/smoke-leak-check` and `scripts/assert-adhoc-signature` model: it judges a result and exits with a `sysexits` code. Two assertions:

1. `AGENTS.md` **warns at 24,000 and fails at 30,000**. Not at 40,000: 30,000 is 25% under the real floor, so a miscount cannot cross the actual threshold and a future change to the formula cannot silently truncate the file. 24,000 is about one phase's growth, which makes the warning arrive while there is still room to act on it.
2. `CLAUDE.md` is still a symlink to `AGENTS.md`. If it is ever replaced by a copy the two drift silently and Claude Code reads the stale one, which nothing else here would notice.

Two operational notes, both from this repository's own gotchas: the script must be added to the alphabetised list in `.editorconfig`'s shell section **in the same commit**, because the `shell` CI job finds files by shebang and lints it immediately while `.editorconfig` styles it only once listed, and that asymmetry reports tabs against a file matching its siblings exactly; and the script has no extension, so a `[*.sh]` section will not reach it.

## Drift fixed along the way

- **`AGENTS.md:298` contradicts itself.** The paragraph opens "**`SATURATED` stopped being inert here**" and closes, three sentences later, "**`SATURATED` is nearly inert and is kept for when it is not**". The second is a pre-#57 sentence kept beside its own correction. Delete it; the 8338-of-2,073,600 figure is the live one.
- **`docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md:338` still reads `RGB(75, 189, 96)`.** `docs/plans/done/2026-09-08-assert-the-transfer-functions-defining-properties.md:254` claims all five copies were corrected to `RGB(143, 224, 154)`; four were. This is a **todo** plan, so a live claim under `.github/docs.instructions.md`'s first rule, and exactly the class its fifth bullet exists to catch. **Fix this first**, or the corrected copy in `## Current state` disappears and the stale one becomes the most authoritative-looking.
- **`AGENTS.md:56` says `build.zig` produces "three artifacts".** It produces five: `addLibrary` at `build.zig:84` and `:99`, `addExecutable` at `:665`, and `:774` instantiated twice by `addRaceStep`. The annotation predates #91.
- **`AGENTS.md:58` says `cmake/` is "used only for the AUv2 build".** It also produces `build/assets/Fosforo.clap`, which CI validates on every push, as `AGENTS.md:160` itself states.

Folded in since `## Structure` is being edited anyway: add `verification/`, which `AGENTS.md:328` mandates and the tree omits, and the `.github/*.instructions.md` files. Separately, `docs/adr/README.md`'s row for 0016 predates the #91 amendment that added `Gate` and `zig build gate-race`; that is a one-line fix to the index row, and the ADR itself must not be edited.

**One required fix nothing else will catch.** `.github/docs.instructions.md` carries `applyTo: "docs/**/*.md"`, which now captures `docs/notes/**`. Its first and third rules tell Copilot that these files are historical records whose point-in-time statements must not be hedged or corrected. Applied to a living note that is exactly wrong: it would suppress the review comment that catches a stale figure. Add one bullet putting `docs/notes/` on the same footing as ADRs and todo plans, where a `path:line` citation is a claim about current code.

## Commit sequence

Twenty-one commits, each `-S` signed. The ordering has one non-obvious property worth preserving: **the pointer scaffolding is added before anything is deleted**, so `AGENTS.md` temporarily grows to about 168,000 and every subsequent commit is a pure deletion. That is the only way these diffs stay reviewable as moves.

0. Before any of it: file the issue, then `git rebase origin/chore/improve-linting` and re-measure `wc -c AGENTS.md` against the 166,639 baseline.
1. `docs: correct the stale hot-core figure the build plan kept` — the todo plan's `RGB(75, 189, 96)`. First, so the correction survives the `## Current state` rewrite.
2. `docs: add a notes directory and its index` — `docs/notes/README.md`, conventions paragraph and an empty aligned index.
3. `docs: add the rules and pointers that replace the gotchas` — `## Rules` and the `## Where the depth lives` header. Deletes nothing.
4. **Fourteen** `docs: move the <topic> notes out of the gotchas` commits, **in descending file size** so an abort banks the largest win. Each creates one document, deletes its bullets, and adds one row to each of the two tables. The last also deletes the emptied `## Gotchas` heading. `AGENTS.md` ends near 26,200.
   - The `ci-workflows.md` commit carries the `actionlint` supersession sentence verbatim.
   - The `linters.md` commit must move the whole `<!-- spellchecker:off -->` … `:on -->` span in one piece: an unclosed marker suppresses nothing, and the sentence it wraps will fail `typos`.
   - Run `npx prettier --write` then `npx markdownlint-cli2` after each commit that carries a table.
5. `docs: cut the current state to its live claims` — 10,005 to 2,600, distributing the per-issue narrative into the topic documents. Must follow 4, since the destinations have to exist.
6. `docs: compress the structure and development annotations`, and `docs: move the certificate diagnosis into the signing note`.
7. `docs: resolve the SATURATED contradiction` and `docs: point the ADR index at 0016's gate amendment`.
8. `chore: add a document budget check` — `scripts/check-doc-budget` plus its `.editorconfig` entry, in one commit.
9. `ci: enforce the document budget` — the `budget` job in `markdown.yml`. Must follow 6, or the founding commit is red.
10. `docs: point the instruction files at the notes` — the required `docs.instructions.md` bullet, plus one pointer line each in `copilot-instructions.md` and `shell.instructions.md`.
11. `docs: record where the old AGENTS.md citations resolve` — last. Adds to `docs/notes/README.md` the SHA of the final move commit, so any `AGENTS.md:<line>` citation resolves through `git show <sha>^:AGENTS.md`.

## Verification

Run, with results, on the branch as it stands.

| Check                                                        | Result                                                            |
| ------------------------------------------------------------ | ----------------------------------------------------------------- |
| `wc -c AGENTS.md`                                            | **26,127**, from 166,639: 84% off, and 34% under the 40,000 floor |
| `git ls-files -s CLAUDE.md`                                  | mode `120000`, still a symlink                                    |
| `scripts/check-doc-budget`, +10,000 chars                    | exits 65, naming the budget                                       |
| `scripts/check-doc-budget`, +3,500 chars                     | exits 0 and warns, so the warning band is reachable               |
| `scripts/check-doc-budget`, `CLAUDE.md` copied not linked    | exits 65 for the other reason                                     |
| 20 orphaned figures, `grep -rlF` over `AGENTS.md docs/notes` | each in exactly one file                                          |
| relative links in `AGENTS.md`, `docs/notes/`, `.github/*.md` | 0 broken, resolved against the filesystem                         |
| `npm run format:check` and `npm run lint:md`                 | clean, 0 errors over 95 files                                     |
| `typos`, `actionlint`, `shfmt -d`, `shellcheck`              | all clean                                                         |
| `zig fmt --check build.zig src/`                             | clean                                                             |
| `zig build test --summary all`                               | **297/297**                                                       |
| `zig build`                                                  | produces a signed `zig-out/Fosforo.clap`                          |

**Nothing was lost, checked rather than assumed.** Each of `34.39`, `1.29%`, `8338`, `8.77`, `70.9`, `443 pixels`, `54 frames`, `113 vtable`, `960x605`, `MidiInCore`, `PLW`, `34285826257`, `_destroyWindow`, `CAMetalDisplayLink`, `kCGWindowNumber`, `moiré`, `__tsan_write8`, `NeverContended`, `MAXIMUM_LEAKED_BYTES` and `MTLCompilerService` resolves to exactly one file, except two that are correct at two: `moiré` also appears in the Rules summary, and `MTLCompilerService` is named by both the compile-cost bullet and the entitlements bullet in the original text.

**The extraction was mechanical, and that was the point.** A script sliced each bullet out of `AGENTS.md` and wrote it unchanged, so no measurement passed through a transcription. It refuses unless each topic's match string hits exactly one bullet, which caught one ambiguity: `Logic cannot be launched from a terminal` matched two, because the `clap-host` bullet's single long line contains the phrase as well.

**Six cross-references were orphaned by the split and are repaired.** Two in `AGENTS.md` pointed at the deleted section; four pointed across the new file boundaries. Found by grepping for directional words, because a broken "the bullet above" reads exactly like a working one. Six others survived because both ends landed in the same file.

**The test count needed no repair.** `zig build test` reports 297/297. Both `285` figures in the notes are anchored to #94's and #96's planting experiments, not present-tense claims, so under `.github/docs.instructions.md` they stay exactly as written.

### Left for after the push

- **The workflow runs on the change that governs it.** Confirm `markdown.yml` dispatches on this pull request and `ci.yml` does not, which is `paths-ignore` working rather than a symptom.
- **The loaded size, not the file size.** Start a session on a **200k-context** model, which is the configuration the whole plan is aimed at, and confirm no `over the …-char limit` line appears.

### What would falsify the design

An agent handed only the new `AGENTS.md` and a real task cannot answer "how do I run this and what will I break" without a tool call, which means the Rules list is under-selected. Or `docs/notes/*.md` files turn out to be edited in the same commits as code more than about one time in three, which means they are specification and belong in source comments or ADRs.

## Risks

- **Stacking removes the Prettier conflict and leaves one.** Rebasing onto `chore/improve-linting` means the reformat is already applied to the `AGENTS.md` this refactor then dismantles, so the 107 reflowed lines never become a merge. What remains is `feature/velocity-weighted-beam` (#58), five commits ahead with a 9-line delta in `## Current state` and the transport-stop gotcha, both of which this plan rewrites. That one is small and paragraph-shaped, and the mapping table makes the re-placement mechanical: #58's `## Current state` prose folds into the compressed section, and its transport-stop edit lands in `trace-and-phosphor-physics.md`.
- **The stack inherits its parent's fate.** If `chore/improve-linting` is reworked or abandoned, this branch rebases again. That is the cost of stacking rather than waiting, and it is worth paying because the alternative is resolving a Prettier reflow against an 86% deletion by hand.
- **A pointer is weaker than a paragraph already in context.** An agent that reads `AGENTS.md` and does not open the note knows a gotcha exists but not what it says. This is the real cost, and it is why the fourteen rules stay at full strength. If a class of mistake starts recurring, promote that specific rule back rather than re-inlining the topic. The largest note, `measuring-a-capture.md` at 18,820, is the one most likely to be skipped; if it is, split it at the test-signals and screencapture bullets.
- **18 `AGENTS.md:<line>` citations across six done plans** are invalidated. At least four are already broken: line 153 is the CMake paragraph today and is cited by a ring plan; lines 173 and 184 are cited by the leaks plan and point into the release code block. **The split completes a decay already well under way.** Per `.github/docs.instructions.md` those files must not be edited; commit 11's SHA sentence is the durable fix and touches no historical record.
- **`.github/*.instructions.md` keeps its duplication deliberately.** Copilot loads those files by `applyTo:` glob and never loads `docs/notes/`, so thinning them would degrade PR review to buy bytes in a file Copilot does not read. Each gains one pointer line; a follow-up issue records the duplication.
- **The budget can be met and still be wrong.** 19,769 characters of the wrong 19,769 is worse than 165 KB. The grep list above is the guard against that and is the part not to skip.
