<!-- markdownlint-disable relative-links MD041 -->

# Contributing to fosforo

Thank you for your interest in contributing to fosforo.

Please note that this project has a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold it.

Two things are worth knowing before you start. First, the project is deliberately **macOS-only on Apple Silicon**, and that is a design decision rather than an oversight; see [ADR 0001](docs/adr/0001-mac-first-apple-silicon.md). Patches adding Windows or Linux support are not currently in scope. Second, the architecture decisions in [`docs/adr/`](docs/adr/) are settled. If you disagree with one, open a discussion proposing a superseding ADR rather than a pull request changing the code.

## Reporting Issues

- **Bug reports and feature requests:** Use the [issue tracker](https://github.com/cboone/fosforo/issues/new/choose)
- **Questions and ideas:** Use [GitHub Discussions](https://github.com/cboone/fosforo/discussions)
- **Security vulnerabilities:** See [SECURITY.md](.github/SECURITY.md)

## Development Setup

### Requirements

- macOS on Apple Silicon
- Zig **0.16.0** exactly. The version is pinned in `build.zig.zon` and CI reads it from there
- Xcode, for the Apple frameworks and SDK
- CMake 3.21 or newer, only if you are building the Audio Unit
- The Metal toolchain, only if you are type-checking shaders: `xcodebuild -downloadComponent MetalToolchain`
- `shfmt` and `shellcheck`, only if you are changing shell scripts. CI pins 3.13.1 and 0.11.0
- `typos`, for the spell check CI runs over the whole tree. CI pins 1.49.0; `brew install typos-cli`

### Getting Started

```bash
git clone https://github.com/cboone/fosforo.git
cd fosforo

# Build. Dependencies are fetched and pinned by content hash automatically.
zig build

# Run tests
zig build test

# Format check
zig fmt --check build.zig src/

# Install the CLAP locally for a CLAP-native host such as REAPER
zig build install-clap
```

### Building the Audio Unit

Only needed for Logic Pro, which does not load CLAP plugins. This fetches the
AudioUnit SDK and takes considerably longer than the Zig build.

```bash
cmake -B build cmake/
cmake --build build --target fosforo_all
```

### Type-checking shaders

Shaders compile at runtime from embedded source, so the build never requires
the Metal toolchain (see [ADR 0009](docs/adr/0009-runtime-shader-compilation.md)).
This step is separate and optional:

```bash
zig build validate-shaders
```

If `xcrun` reports the Metal toolchain as missing even after downloading it,
run `xcrun --kill-cache`.

## Code Style

- Run `zig fmt build.zig src/` before committing
- Format shell scripts before committing with `git ls-files -z | xargs -0 shfmt -f | xargs shfmt -w`, and pass `shfmt` no parser or printer options. The profile lives in `.editorconfig`, and `shfmt` ignores that file entirely if any of those options is given (`-i`, `-ci`, `-sr`, `-ln` and the rest of the two groups in `shfmt --help`). The output-mode selectors are fine, so `-w` and `-d` above are safe. Select files through `git ls-files` rather than running `shfmt -w .`, which reaches vendored scripts under `build/` and reformats them
- Keep `shellcheck` clean: `git ls-files -z | xargs -0 shfmt -f | xargs shellcheck`
- Keep `typos` clean by running it before committing. It reads `typos.toml`, which allowlists words the tool is wrong about and ignores backticked commit SHAs. Add to that file rather than rewording a correct word, and if a document has to spell out a misspelling in order to explain it, wrap that part in `<!-- spellchecker:off -->` and `<!-- spellchecker:on -->`
- Keep Metal types out of anything above `src/gpu/iface.zig`. That seam is load-bearing; see [ADR 0005](docs/adr/0005-metal-behind-a-renderer-seam.md)
- Anything reachable from the audio thread must not allocate, lock, or make a syscall

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) format:

```text
<type>: <description>
```

**Types:**

- `feat`: new feature
- `fix`: bug fix
- `docs`: documentation changes
- `refactor`: code refactoring (no functional change)
- `test`: adding or updating tests
- `build`: build system or dependency changes
- `ci`: CI configuration changes
- `chore`: maintenance tasks

**Examples:**

```text
feat: add velocity-weighted beam intensity
fix: resolve texture race when resizing during playback
docs: explain the phosphor decay time constant
build: bump pinned Zig to 0.17.0
```

## Pull Request Process

1. Fork the repository
1. Create a feature branch
1. Make your changes
1. Ensure tests pass: `zig build test`
1. Ensure formatting passes: `zig fmt --check build.zig src/`
1. If you touched a shell script, ensure `git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d` and the same pipeline ending in `xargs shellcheck` are both silent
1. Ensure the spell check passes: `typos`
1. Submit a pull request

### Branch Naming

Use descriptive branch names with a type prefix:

- `feature/*`: new features
- `fix/*`: bug fixes
- `docs/*`: documentation changes
- `refactor/*`: code refactoring
- `test/*`: test additions or fixes
