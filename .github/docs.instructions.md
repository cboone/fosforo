---
applyTo: "docs/**/*.md"
---

# Reviewing this project's plans and ADRs

These files are a decision record, not specification prose. Most of what looks like a defect in them is a deliberate convention.

- **Plans and ADRs state measured facts at a point in time, and that is the format working correctly.** "#57 has merged", "**Done**", "65 runs in which it never failed", "40.0 ms in the steady state" are records of what was true when written, checked against the tracker or a measurement. **Do not suggest making them conditional, hedged, or future-proof**, and do not suggest rewording them so they "read correctly whenever the document is read". A statement that goes out of date is corrected by a later commit, which git history preserves; a statement hedged in advance records nothing.
- **Verify a claim about issue or PR state against the tracker, not against the pull request description.** A PR description is written once and routinely lags the work: base branches get retargeted, drafts get marked ready, and dependencies merge while the PR is open. If a document and a PR description disagree about whether something has merged, the document is the more likely to be current. Check with `gh pr view` or `gh issue view` before reporting a conflict.
- **Done plans are historical records.** Files in `docs/plans/done/` are completed plan documents preserved for reference. They may not match the final implementation. Do not flag discrepancies between done plan content and the actual codebase, and do not suggest prose or wording edits to them.
- **ADRs are superseded, not edited.** A decision that has changed gets an amendment section at the foot of the file; the original text stays standing even where a later section contradicts it. Do not suggest deleting or rewriting a superseded paragraph, and do not report the contradiction as an inconsistency. In-place edits are reserved for transcription errors, and those say so.
- **Refusals are recorded on purpose.** These documents deliberately keep the arguments for things that were considered and rejected, and for reasoning that a later measurement falsified. A paragraph explaining why something was *not* built is not stale content to be removed.
- **Prose is one long line per paragraph.** `MD013` is disabled in `.markdownlint-cli2.jsonc`. Do not suggest hard-wrapping at any column.
- **Tables use the aligned style** `MD060` pins. Both `|-----|` and `| --- |` delimiter rows appear and both satisfy it; do not suggest normalising one to the other as a defect.
