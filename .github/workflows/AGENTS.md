# CI workflow instructions

Read [CI workflows](../../docs/notes/ci-workflows.md) before editing dispatch, tool installation, pins, timeouts or runner usage.

- Ensure shellcheck is on `PATH` before running actionlint; otherwise shell blocks can go unchecked while the command succeeds.
- Check both Zig-built and wrapper-built CLAP bundles with clap-validator and signature assertions. Keep default builds ad-hoc and release signing local.
- Preserve smoke, race and leak controls; a job that finds no inputs or exercises no assertion does not establish coverage.
- Use pinned dependencies and the repository's documented runner constraints. Do not record transient job or rollup counts as durable prose.
- The existing document-size job checks the root file. Also inspect complete global/root/scoped instruction chains when changing instruction layout.
