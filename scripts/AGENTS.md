# Helper script instructions

Read the relevant [notes index](../docs/notes/README.md) before changing a helper.

- `zig build install-clap` and `zig build install-plugins` build exactly what they install. The `scripts/install-plugins` helper builds nothing; it copies bundles and reports their hash/provenance. Follow [host verification](../docs/notes/host-verification.md); the shared plugin folders and host streams are exclusive.
- Read [signing and notarization](../docs/notes/signing-and-notarization.md) for the three independent release steps, signature controls, unsigned package testing and certificate replacement. Credentials stay in environment variables or the keychain; releases stay local.
- Read [capture measurement](../docs/notes/measuring-a-capture.md) for `measure-trace`. Use the branch's own constants and script; the velocity-weighted `--periods` limitation must be reported when interpreting captures.
- Race and leak wrappers must judge their controls and reports, not just an executable's exit code. Read the [concurrency](../docs/notes/concurrency-and-canaries.md) and [leak](../docs/notes/leak-instruments.md) notes first.
- Follow [linters](../docs/notes/linters.md): shfmt reads tracked shell files and `.editorconfig`; Ruff includes the extensionless Python helper. Use uv to run Python.
- `check-doc-budget` is the existing root-size gate. For instruction restructuring, also measure global plus root plus every scoped file in a path; the 32 KiB combined constraint governs even if a single-file gate passes.
