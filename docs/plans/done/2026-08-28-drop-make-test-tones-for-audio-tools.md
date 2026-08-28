# Drop `scripts/make-test-tones` now that `audio-tools` carries the generator

Issue: [#67](https://github.com/cboone/fosforo/issues/67). Branch: `chore/remove-moved-script`.

## Context

`scripts/make-test-tones` renders the 20 WAVs the trace's host verification plays: six sines for period counting, an eight-step level sweep, two hard-panned files, two saws, and two transients. It is a bash-and-ffmpeg script and nothing about it is specific to this plugin except four numbers.

It now has a home that is not tied to this plugin. The generator was reimplemented in Python against numpy and scipy as `tools/test-signals/maketones.py` in [cboone/audio-tools](https://github.com/cboone/audio-tools), parameterised so that every frequency, level, duration and gate is an argument. That port was validated against the 20 WAVs still sitting at `~/Music/fosforo-test-tones/`: rendering with this project's parameters reproduces all 20 filenames and **every file is bit-identical** to its ffmpeg counterpart, saws and gated transients included. This issue is the "then" half of that move, which could not land from the other repository.

The bit-identity is what makes the removal safe rather than merely tidy. The peak rows, plateau widths, period counts and implied sample values in [#38](https://github.com/cboone/fosforo/issues/38)'s verification, in `AGENTS.md`, and in ADR 0017's reasoning were all measured against files this script rendered. Because the replacement produces the same bytes, none of those tables becomes an unreproducible claim and nothing needs re-running.

Two facts established while planning, neither of which is in the issue body:

- **`audio-tools` PR [#5](https://github.com/cboone/audio-tools/pull/5) is still open**, so `maketones.py` is on a pushed branch rather than on that repo's `main`. The user has confirmed this is fine to proceed against. `AGENTS.md` is written to point at the eventual `main` path.
- **Three plan documents name the script, not the two the issue lists.** `docs/plans/done/2026-08-27-commit-measure-trace-and-replace-its-lossless-guard.md` landed with [#64](https://github.com/cboone/fosforo/issues/64) after #67 was written, and references the script at lines 9 and 128.

The ordering constraint in the issue is already satisfied: #64 merged as [#68](https://github.com/cboone/fosforo/pull/68) (`39721e8`), so `measure-trace` and its `AGENTS.md` entry are on `main` and this branch edits that prose once, with both facts known. #64's placement argument does not weaken: `measure-trace` stays here because it restates four constants it does not own and cannot measure any other oscilloscope. The half that leaves is the half that was general.

## Changes

### 1. Delete the script

`git rm scripts/make-test-tones`. Nothing in `build.zig`, `cmake/`, or `.github/workflows/` invokes it; grep confirms the only references are prose. `.github/shell.instructions.md` selects by glob (`scripts/**`), so it needs no edit.

### 2. `.editorconfig`

Remove the single `make-test-tones,` token from the brace list on line 48. The list stays alphabetical, and the comment above it explaining why extensionless scripts are enumerated stays exactly as it is.

### 3. `AGENTS.md`, two edits and one addition

**Delete the structure-tree line** (line 49):

```text
  make-test-tones           renders the WAVs the host verification plays, and checks every peak
```

**Repoint the `measure-trace` bullet** (line 180). Its closing clause currently reads "and it is the other half of `scripts/make-test-tones`: render, play, capture, measure is one procedure". `scripts/make-test-tones` is about to not exist, so that path becomes a dangling reference. Keep the "one procedure" framing, which is doing real work, and name where the other half went, deferring the detail to the new bullet.

**Add a new gotcha bullet** recording the new location and the exact invocation. Place it **after** the "A screenshot is written in the display's colour space" bullet (line 182) and before the `MTLStorageModePrivate` bullet: the three bullets from `measure-trace` through the colour-space one are a cluster that refers back to each other ("Its guard...", "the pixel-sampling advice above"), and inserting into the middle of it breaks a referent.

The bullet must carry four things, in the house style of a bold lead sentence followed by prose:

- The script is gone and the generator is at `tools/test-signals/maketones.py` in `cboone/audio-tools`.
- The exact invocation that reproduces this project's set, in a fenced block:

  ```bash
  uv run maketones.py --outdir ~/Music/fosforo-test-tones \
    --levels 0.002 0.010 0.100 0.500 1.000 1.050 1.089 2.000 \
    --saws 0.900 1.100
  ```

- **Why those two flags and only those two.** `1.089` is `trace_rail / trace_full_scale` from `src/gpu/iface.zig`, or `0.98 / 0.9`, the ratio at which the trace stops climbing, and `1.050` is the last level below it that does not rail; the saws at `0.900` and `1.100` straddle the same threshold on a linear ramp; the `0.002` floor is this editor's geometry. Everything else, the six sine frequencies, the pans, the click and the gated burst, is a default there. This ties back to the existing railing and floor bullets rather than restating them.
- **That nothing measured needs re-running,** because the port is bit-identical file for file against the 20 WAVs at `~/Music/fosforo-test-tones/`, so #38's tables and ADR 0017's reasoning stand as measurements.

### 4. Pointer notes in the three done plans

These are historical records, so a pointer is right and a rewrite is not. Add one blockquote note per document, placed immediately after the title's issue-attribution line so it is read before any table, following the post-hoc annotation precedent already in this tree (`docs/plans/done/2026-07-29-cvdisplaylink-render-loop-and-resize-seam.md:322` and ADR 0013's `## Amended by issue #5`). One note per document, not one per reference site.

Shape:

```markdown
> **Pointer added by [#67](https://github.com/cboone/fosforo/issues/67):** `scripts/make-test-tones`, named below, no longer exists here. The generator moved to `tools/test-signals/maketones.py` in [cboone/audio-tools](https://github.com/cboone/audio-tools), and `AGENTS.md` carries the invocation that reproduces this project's signal set. Nothing this document measured changes: the port is bit-identical file for file.
```

The documents and their reference sites:

| Document | Sites |
| --- | --- |
| `docs/plans/done/2026-08-20-draw-a-crude-aliased-trace.md` | 306, 403 |
| `docs/plans/done/2026-08-26-accumulate-the-beam-into-a-persistent-texture.md` | 253, 317 |
| `docs/plans/done/2026-08-27-commit-measure-trace-and-replace-its-lossless-guard.md` | 9, 128 |

Line 317 in the second document is the site the issue records as 312; it moved. Lines 107 and 153 of the third document mention `~/Music/fosforo-test-tones/` as a directory rather than the script, and are left alone.

## Verification

Read-only and quick; nothing here needs a GPU, a host, or an install.

```bash
git ls-files -z | xargs -0 shfmt -f | wc -l        # 12 before, 11 after
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d   # silent
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck # silent
typos                                              # clean, including `maketones` and the new prose
rg -n 'make-test-tones' .                          # only the four pointer notes and the new bullet
zig build test                                     # nothing in the build referenced the script
```

The `shfmt -f` count is the sharp one: it is the check `AGENTS.md` already describes for this list, it drops by exactly one, and a stale `.editorconfig` entry is invisible to every other command here.

Confirm by eye that `rg 'make-test-tones'` returns no reference that reads as a live tool at a path in this repository. Every surviving mention should either be a pointer note saying it moved, or historical prose sitting under one.

## Commits

Four, in this order, each self-contained:

1. `chore: drop scripts/make-test-tones now that audio-tools carries it (#67)` — the deletion and `.editorconfig`.
2. `docs: record where the test-signal generator went (#67)` — every `AGENTS.md` edit: the structure-tree line, the repointed `measure-trace` clause, and the new bullet.
3. `docs: point the plans that name make-test-tones at its new home (#67)` — the three pointer notes.
4. `docs: record the plan for dropping make-test-tones (#67)` — this document, straight to `done/`.

The structure-tree line was planned for the first commit and landed in the second. Splitting one file's hunks across two commits needs interactive staging, and all three `AGENTS.md` edits are documentation describing the same move, so keeping them together is the better unit to review.

## Out of scope

- **Any change to what the signals are.** The replacement renders the same files. If this project later wants different ones, that is a change to the flags above, not to either repository's code.
- **`measure-trace`.** That is #64 and it stays here, for the reasons its own `AGENTS.md` bullet gives.
- **Merging `audio-tools` PR #5.** Separate repository, separate decision, and the user has said to proceed without waiting on it.
