# Enforce Markdown formatting with Prettier and markdownlint

Closes [#85](https://github.com/cboone/fosforo/issues/85) and [#106](https://github.com/cboone/fosforo/issues/106).

## Context

`.markdownlint-cli2.jsonc` pins `MD060` to `aligned` and nothing runs it. That is the fourth instance of this repository's recurring failure, a check that is configured, believed to be running, and silently is not: `typos` before [#28](https://github.com/cboone/fosforo/issues/28), `ruff` before the `python` job, `actionlint` before [#99](https://github.com/cboone/fosforo/issues/99), and now this one. It has already cost something, and #85 measured it: `main` reports 0 findings while `feature/beam-as-quads` reports 129, of which 127 sit in that branch's own plan file and nothing said so.

The half that makes the gap expensive is that `MD060` has no fixer at any version. Prose tables here run past 400 characters a cell, so a one-word edit silently unaligns a row, and `markdownlint --fix` leaves the file byte-identical while reporting one error per misaligned pipe. #106 is the answer the rest of the tree already took: Prettier aligns GFM tables and fixes them, and its output satisfies `MD060: aligned`, so markdownlint becomes a verifier over an auto-fixer rather than a critic with no remedy. The cross-repo plan at `~/Development/docs/plans/todo/2026-09-04-fix-markdownlint-table-alignment-and-line-width.md` set fosforo aside as one of two repositories keeping `aligned` deliberately, on the grounds that adopting Prettier here would complete that arrangement.

The outcome is that a Markdown workflow runs both tools on every pull request with no `paths-ignore`, Prettier owns formatting, markdownlint verifies it, and the day-to-day fix is `npx prettier --write` rather than hand-padding pipes.

## Decisions

| Question                    | Decision                                                                                                           |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Who owns table alignment    | Prettier. markdownlint keeps `MD060: aligned` as a verifier.                                                       |
| Where the check runs        | A new `.github/workflows/markdown.yml`, on `typos.yml`'s precedent, with no `paths-ignore` at all.                 |
| How the tools are pinned    | `package.json` plus `package-lock.json`, installed with `npm ci`. The repository's first `package.json`.           |
| Prettier's remit            | Every tracked Markdown file except `docs/design/scope-plugin-handoff.md`, including the completed plans.           |
| Emphasis style              | Prettier's, so `*emphasis*` becomes `_emphasis_`. `MD049` is set to `false`; see the intraword finding below.      |
| Prettier's other file types | Out of remit. Both tools are invoked over an explicit Markdown glob, so YAML, JSON and JSONC keep `.editorconfig`. |

Two of these were the user's call rather than a recommendation. Prettier's remit includes `docs/plans/done/`, which reformats 43 historical records; the narrower alternative, excluding them, was offered and declined. The emphasis flip was accepted knowing this repository has twice reached for Prettier and twice reverted over exactly that.

## What was measured

Every figure below is from Prettier 3.8.1 and markdownlint-cli2 0.21.0, run over a scratch copy of the tree. Nothing in the worktree was modified.

| Claim                                                | Result                                                    |
| ---------------------------------------------------- | --------------------------------------------------------- |
| Prettier's output satisfies `MD060: aligned`         | Yes, 0 errors over 78 linted files                        |
| Prettier is idempotent on its own output             | Yes, `--check` clean on the second pass                   |
| Files Prettier rewrites                              | 56 of 79 tracked, one of which is the `CLAUDE.md` symlink |
| Lines those rewrites touch                           | 805                                                       |
| Of those, emphasis `*x*` to `_x_`                    | 302 lines, the largest single category                    |
| Of those, table alignment                            | 91 lines, which is the point of the exercise              |
| `proseWrap: "preserve"` leaves prose unreflowed      | Yes, no paragraph was rewrapped                           |
| `prettier --write` preserves the `CLAUDE.md` symlink | Yes, it writes through to `AGENTS.md`                     |
| markdownlint-cli2 lints `node_modules/`              | **Yes.** See the trap below                               |
| Prettier skips `node_modules/`                       | Yes, by default, with no configuration                    |
| A planted misaligned table fails the check           | Yes, 3 markdownlint errors and 1 Prettier warning         |

### The trap that `package.json` arms

`markdownlint-cli2` walks into `node_modules/` and lints dependency READMEs. A fake package carrying one misaligned table took the run from 78 files and 0 errors to 79 files and 2 errors. So the very first `npm ci` turns the new job red unless `node_modules/**` joins the `ignores` list, and the failure would name a dependency's README rather than anything in this repository. Prettier needs no equivalent, which is the asymmetry worth recording: it excludes `node_modules/` itself and always has.

### The Prettier defect that has to be fixed first

Prettier 3.8.1 deletes the spaces around inline code spans, changing what the prose renders as. Minimal reproduction, confirmed against three controls that do not reproduce:

```text
in:   **A `glob/**` here.** Then `code` and `more` after.
out:  **A `glob/**`here.** Then`code`and`more` after.
```

The trigger is an inline code span containing two asterisks that sits **inside** a strong-emphasis span. The same code span outside the emphasis is untouched, and the same emphasis without the asterisks in the span is untouched. Once tripped, every later code span in that paragraph loses its adjacent spaces.

Two live occurrences, 54 deleted spaces between them:

| File                            | Construct                                                            | Spaces lost |
| ------------------------------- | -------------------------------------------------------------------- | ----------- |
| `AGENTS.md`                     | the `actionlint` gotcha's claim about which paths trigger `ci.yml`   | 46          |
| `.github/shell.instructions.md` | the paragraph exempting `scripts/measure-trace` from the shell rules | 8           |

The defect also blocks Prettier's own emphasis conversion inside the damaged paragraph, which leaves a stray `*tag*` that `MD049` then reports, so the corruption is visible to the linter even though the deleted spaces are not.

The remedy is to move the offending code span outside the strong-emphasis span, which was verified to stop it. `<!-- prettier-ignore -->` also works, but only in a loose list, and `AGENTS.md`'s Gotchas list is tight, so the marker would not hold there. Rewording is the portable fix and removes the latent hazard rather than pinning it.

### Why `MD049` is `false` rather than `consistent`

The cross-repo plan predicted that deleting `MD049` restores the default `consistent`, which Prettier satisfies. **It does not, and this is a correction to that plan.** `docs/plans/done/2026-07-29-consistent-display-name-across-clap-and-au.md:33` contains `*un*defined`, an emphasis on a word fragment. CommonMark does not permit intraword emphasis with underscores, so Prettier correctly refuses to convert it and correctly leaves the asterisks. `MD049: consistent` then takes that first asterisk as the file's expected style and reports every underscore after it, 4 findings in that one file. Pinning `underscore` fails the same line from the other side. Setting the rule to `false` was measured at 0 errors across all 78 files and is the only setting that survives a case Prettier gets right.

A related claim needs no repair. `docs/plans/done/2026-09-05-make-the-trace-judgements-pure-and-testable.md:302` states that `MD049` is already pinned to asterisk. It never has been, and the rule appears nowhere in the config. That file stays as the historical record it is, on the precedent the `actionlint` gotcha set, and `AGENTS.md` carries the live statement.

## The changes

### New files

| File                             | Content                                                                                                   |
| -------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `.prettierrc.json`               | `printWidth: 10000` and `proseWrap: "preserve"`, matching the other repositories here                     |
| `.prettierignore`                | the design document, plus `node_modules/`, `build/`, `zig-out/`, `zig-pkg/` and `.zig-cache/` defensively |
| `package.json`                   | `private: true`, `devDependencies` only, exact versions with no caret or tilde                            |
| `package-lock.json`              | generated by `npm install`, carrying an integrity hash per package                                        |
| `.github/workflows/markdown.yml` | the check, described below                                                                                |

`proseWrap: "preserve"` is load-bearing. It stops Prettier reflowing prose, which is what keeps the one-long-line-per-paragraph convention `MD013: false` exists to permit, and it makes `printWidth` inert for Markdown.

Pin `prettier` at 3.8.1 and `markdownlint-cli2` at 0.21.0, the versions every figure above was measured at. The editor extension bundles markdownlint-cli2 0.23.2 and aligning with it is worth doing, but as a deliberate upgrade with its own re-measurement, not folded into this change.

### Edited files

| File                               | Change                                                                                                     |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `.markdownlint-cli2.jsonc`         | add `node_modules/**` to `ignores` and `"MD049": false` to `config`, each with its reasoning as a comment  |
| `.gitignore`                       | add `node_modules/`                                                                                        |
| `AGENTS.md`                        | reword one construct, add both tools to the command block, rewrite the gotcha at the `markdownlint` bullet |
| `.github/shell.instructions.md`    | reword one construct                                                                                       |
| `.github/docs.instructions.md`     | the delimiter-row bullet, described below                                                                  |
| `CONTRIBUTING.md`                  | a Requirements entry and a Code Style bullet, matching `typos`, `ruff` and `actionlint`                    |
| `.github/PULL_REQUEST_TEMPLATE.md` | a checklist row, matching the same three                                                                   |
| 4 completed plans                  | remove 11 now-vestigial `<!-- prettier-ignore -->` markers                                                 |
| 55 Markdown files                  | the bulk reformat                                                                                          |

The `AGENTS.md` gotcha inverts. Its current text is a warning that nothing enforces the config and an instruction to run the tool by hand; what replaces it says that Prettier fixes and markdownlint verifies, that the workflow carries no `paths-ignore` and why, and that `markdownlint --fix` is **still** forbidden for the reason it always was, because it ignores its file arguments and rewrites everything matching its globs.

The `.github/docs.instructions.md` bullet stating that both `|-----|` and `| --- |` delimiter rows satisfy `MD060` becomes false the moment Prettier runs, because Prettier normalizes every delimiter row to the padded form. Replace it with a statement that Prettier owns the table's shape and that neither form should be proposed as a defect, because the formatter settles it.

The 11 markers are vestigial rather than load-bearing. Each sits above an ordinary table whose delimiter row runs one character wide, and they were added to keep Prettier off tables in a repository that had not adopted Prettier. Keeping them would leave 11 tables that no tool aligns, which is the friction this change exists to remove. Removing them is not what fixed the `MD049` finding, which was measured: the finding survives their removal and is the intraword case above.

### The workflow

Copy `typos.yml`'s shape, which is the established template for a check whose files `ci.yml` ignores: `push` on `main`, a bare `pull_request:`, `workflow_dispatch:`, workflow-level `concurrency` keyed on the workflow and ref with `cancel-in-progress`, `permissions: contents: read`, `runs-on: ubuntu-latest`, and `timeout-minutes: 3` on the floor that `shell`, `python`, `typos` and `actionlint` share.

Carry `typos.yml`'s comment explaining the absence of `paths-ignore`, because it transfers word for word: `ci.yml` ignores `*.md` and `docs/**` on both triggers, `paths-ignore` is workflow-level so no job can be exempted from it, and a Markdown job added there would be green on every pull request that could have failed it.

Steps: checkout, `actions/setup-node` pinned at `820762786026740c76f36085b0efc47a31fe5020` (v7.0.0) with `cache: npm`, `npm ci`, a `Report tool versions` step printing both, then `npx prettier --check "**/*.md"` and `npx markdownlint-cli2`, each with an `id`, then a `Summarize the findings` step gated on failure in the shape both existing summary steps use.

Two details. Quote the glob so Prettier expands it rather than the shell, and keep the invocation Markdown-only: a bare `prettier --check .` would pull every workflow, `.markdownlint-cli2.jsonc` and `.claude/settings.json` into Prettier's remit, which is scope this change does not ask for and which `.editorconfig` already governs. Pin Node by major only; the tools' behaviour is pinned by the lockfile, not by Node's patch level.

## Commit sequence

The reword must land before the reformat, or the reformat commits the corruption. `MD049: false` must land no later than the reformat, or the tree fails its own linter in between.

1. `chore: pin prettier and markdownlint-cli2 as dev dependencies` — the four new config files, `.gitignore`, and both `.markdownlint-cli2.jsonc` edits.
2. `fix: keep prettier from deleting spaces around code spans` — the two rewords, with the reproduction in the message.
3. `style: format every Markdown file with prettier` — the bulk reformat and the 11 marker removals, nothing else.
4. `ci: run prettier and markdownlint over every Markdown file` — the workflow.
5. `docs: record that Markdown formatting is enforced` — `AGENTS.md`, `CONTRIBUTING.md`, the PR template and `docs.instructions.md`.

Keeping 3 alone is what makes it reviewable: it is 805 lines across 55 files and every one of them should be mechanical.

## Verification

Re-measure rather than trusting the figures above, since they come from the locally installed tools and the pin makes CI's copies authoritative.

```bash
npm ci
npx prettier --check "**/*.md"     # expect: all matched files use Prettier code style
npx markdownlint-cli2              # expect: Linting: 78 file(s), Summary: 0 error(s)
git diff --stat HEAD~1             # on commit 3: expect 55 files, CLAUDE.md absent
ls -l CLAUDE.md                    # expect: still a symlink to AGENTS.md
```

Then the checks that matter more than a green run, because a check that cannot fail is the thing this issue is about.

**Confirm both instruments fire.** Append a misaligned table and an `*asterisk*` span to `README.md`, run both tools, and expect markdownlint to report `MD060` and Prettier to report the file; then revert. Measured at 3 markdownlint errors and 1 Prettier warning.

**Confirm the space-deletion defect is gone.** Diff the tree against `main` and check that no space adjacent to an inline code span was deleted outside a table. This is the one failure mode neither tool reports, so it needs its own pass.

**Confirm the workflow is not skipped on the change it governs.** Open the pull request and check that the `markdown` workflow ran. A documentation-only branch is exactly the case `ci.yml` skips, and running here is the entire reason the workflow is separate. Check also that a `run` of it appears for a branch touching only `docs/`.

**Confirm the `node_modules` ignore holds.** The run after `npm ci` must still report 78 files. If it reports more, the ignore did not take and a dependency's README is being linted.

## Follow-ups, not part of this

- Report the space-deletion defect upstream to Prettier with the minimal reproduction above, and re-check it when the pin moves.
- Consider aligning the pin with the editor extension's markdownlint-cli2 0.23.2, with its own re-measurement, since a rule set that ships inside the tool can introduce findings with no change on this side.
- `ruff.toml`'s comment says "all 53 .md files"; the tree now has 79. A stale figure, unrelated to this change and worth a sweep of its own.
