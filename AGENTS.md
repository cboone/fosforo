# fosforo

## Overview and status

Fósforo is a macOS GPU-rendered phosphor oscilloscope and signal-analysis plugin, authored as CLAP and rendered with Metal. Display text uses **Fósforo**; repository, binary and identifiers stay ASCII `fosforo`.

The [build plan](docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md) owns phase status and verification gaps. The plugin's audio pass-through, phosphor pipeline, host state and smoke instruments are described by the living [notes index](docs/notes/README.md). Keep implementation status in the plan and CHANGELOG.

## Non-negotiables

Read the relevant [ADRs](docs/adr/) before changing architecture. Supersede settled decisions with a new ADR rather than relitigating them in review.

- macOS on Apple Silicon only. Zig 0.16.0 is pinned in `build.zig.zon`, which CI reads. Author CLAP once; clap-wrapper supplies other formats.
- No Metal type above `src/gpu/iface.zig`, and no WebView UI.
- Nothing reachable from the audio thread may allocate, lock or make a syscall.
- Use the one `std.Io` instance in `src/platform/io.zig`, constructed with `init_single_threaded`, never `Threaded.init` (ADR 0015).
- Preserve ring and gate release/acquire ordering, race controls and source canaries. Every ordering-critical cross-thread declaration needs its own source canary; read ADR 0016 and the concurrency note before touching one.
- GUI smoke and race harnesses are separate build steps, never part of `zig build test`.
- The vertical axis is absolute; do not autoscale the signal or hide over-scale input. The display's transfer function and gradients are fixed contracts documented in the physics note and ADRs 0017/0019.

## Rules

- Confirm bundle hash and provenance before trusting host results. `install-*` builds what it installs and prints what landed. All other steps stay in the worktree. Use one host stream at a time: the shared plugin folder and window server are exclusive.
- For REAPER diagnostics, redirect stderr with `2>&1` and use `grep --line-buffered`; otherwise lines are missed or misleadingly delayed. Read [diagnostics](docs/notes/reading-diagnostics.md) before running a host.
- Use the worktree's own `scripts/measure-trace`. Its `--periods` measurement is unreliable for velocity-weighted captures; centroids are unaffected. Verify at 48 kHz and read [capture measurement](docs/notes/measuring-a-capture.md) before quoting numbers.
- Captures belong in ignored `verification/`, never in commits. Commit measured results, not session captures.
- `zig build` does not rebuild the smoke executable. Run the named smoke step to ensure the harness matches the source.
- Run `npm ci`, then Prettier, then markdownlint. Never pass `--fix` to markdownlint-cli2 here; it rewrites all configured globs, including completed plans. Use `npm run format`, then `npm run lint:md`.
- Select shell files with `git ls-files`, never a recursive shfmt tree walk, which reaches vendored build scripts. Read [linters](docs/notes/linters.md) before changing lint commands.
- When correcting a measured figure, search the old value across current repository docs and code. Completed plans are historical records: never update their figures, citations or line numbers. Notes are living and corrected in place.
- Do not put CI job/run counts in prose. Anchor measurements to a run ID or omit them.

## Development

```bash
zig build                  # Zig-built CLAP; no CMake
zig build test
zig build test-safe
zig build test-release
zig build audio-unit       # CMake wrapper build
zig build plugins          # both bundles in this worktree
zig build install-clap
zig build install-plugins
zig build smoke-gpu
zig build smoke-trace
zig build smoke-appkit
zig build smoke-leaks
zig build ring-race        # requires Linux for Thread Sanitizer
zig build gate-race        # requires Linux for Thread Sanitizer
npm ci
npm run format
npm run lint:md
typos
```

Read [build system](docs/notes/build-system.md) before changing `build.zig`, dependency pins, bundle metadata or identifiers. It explains CMake's `fosforo_all` target, optimization modes and signatures. Read [test suite](docs/notes/the-test-suite.md) before changing test coverage and [smoke harness](docs/notes/smoke-harness.md) before changing smoke steps. `clap-validator` checks both CLAP bundles in CI; Logic loading is the complete Audio Unit check because `auval` cannot see this component.

## Navigation and scoped instructions

Read each scoped file before touching that directory, including from a root session. Preserve paired `CLAUDE.md -> AGENTS.md` symlinks.

- [src/AGENTS.md](src/AGENTS.md): concurrency, lifecycle, shader bindings, test and leak instruments.
- [shaders/AGENTS.md](shaders/AGENTS.md): Metal plumbing, rendering contracts and pixel verification.
- [cmake/AGENTS.md](cmake/AGENTS.md): wrapper, bundle identity and signing boundaries.
- [scripts/AGENTS.md](scripts/AGENTS.md): installation, release tools, measurement and linting.
- [.github/workflows/AGENTS.md](.github/workflows/AGENTS.md): CI dispatch, tool prerequisites and verification coverage.
- [docs/AGENTS.md](docs/AGENTS.md): ADRs, living notes, historical plans and instruction budgets.

## Releasing

Read [signing and notarization](docs/notes/signing-and-notarization.md) first. Releases are one signed, notarized, stapled `.pkg`, built locally, never in public CI. Run `scripts/build-release-bundles`, `scripts/build-installer`, then `scripts/notarize-installer`; identities come from environment variables and notarization credentials from a keychain profile. The note records certificate expiry and replacement requirements. Do not revoke superseded certificates.

Keep this root an operating summary. Specialized detail belongs in existing living notes and paired scoped instructions. Measure every global-plus-root-plus-nested chain against 32 KiB; do not raise the limit to accommodate growth.
