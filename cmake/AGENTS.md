# Wrapper build instructions

Read [build system](../docs/notes/build-system.md) before editing wrappers, exported entry points, identifiers or bundle metadata, and [signing and notarization](../docs/notes/signing-and-notarization.md) before signing changes.

- Zig authors the CLAP; CMake only integrates clap-wrapper. Preserve permanent CLAP and Audio Unit identity and the separate display-name rules.
- Use `../scripts/build-audio-unit`, which configures an absent build directory and builds `fosforo_all`, not only `fosforo_auv2`.
- CMake builds the Zig implementation archive under its own prefix. It must not overwrite or re-sign the separate Zig-built bundle.
- Keep the default build offline and ad-hoc signed. Release signatures require the documented local workflow.
- Both CLAP bundles need clap-validator and signature checks. Logic loading verifies the Audio Unit; `auval` cannot establish coverage for it.
- Discover extensionless shell helpers through tracked-file selection, not a recursive tree walk into the vendored build directory.
