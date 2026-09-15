# Documentation instructions

[notes/README.md](notes/README.md) indexes specialized operational guidance. Read the relevant note before changing its subject.

- ADRs record settled decisions; supersede them instead of rewriting history. Notes are living documents, corrected in place.
- Completed plans in `plans/done/` are historical records. Never repair their figures, citations or line numbers. Active status belongs in the build plan's phase and verification tables or CHANGELOG.
- When changing a measured value, search its old value across current docs, ADRs, comments and workflows, respecting the completed-plan exception.
- Root instructions contain rules whose omission can silently damage work or produce a misleading pass. Keep component detail in scoped instructions and notes; measurements belong in notes.
- Run Prettier before markdownlint. Do not use markdownlint-cli2 `--fix`; it can rewrite every configured glob. Preserve design and historical-plan exclusions.
- Preserve every `CLAUDE.md -> AGENTS.md` pair. Measure all global/root/nested chains in bytes against 32 KiB, including after formatting. Passing `scripts/check-doc-budget` alone does not establish that combined bound.
