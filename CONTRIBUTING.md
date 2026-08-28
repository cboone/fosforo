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
- `ruff`, only if you are changing `scripts/measure-trace`, the one Python file here. CI pins 0.16.5; `brew install ruff`. Running the script itself needs [`uv`](https://docs.astral.sh/uv/) rather than a Python install, since its shebang resolves its own dependencies

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

Every step whose name begins with `install-` builds exactly what it installs,
copies it into `~/Library/Audio/Plug-Ins`, and prints the hash of what landed.
Every other step stays in the worktree, including Zig's own `install`, which
writes to `zig-out`. Compare the hash a step prints against the build you meant
to test before trusting anything a host tells you: several worktrees compete for
one plug-in folder, and the failure is silent.

### Building the Audio Unit

Only needed for Logic Pro, which does not load CLAP plugins. This fetches the
AudioUnit SDK and takes considerably longer than the Zig build, which is why the
day-to-day loop never invokes CMake.

```bash
zig build audio-unit     # builds it in the worktree
zig build install-plugins # builds both bundles and installs both
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

### Checks that need hardware CI cannot assume

Three checks exist that `zig build test` deliberately does not run, and none is
a pull request checklist item, because the machine you are on may not be able to
run them.

```bash
zig build smoke        # runs Metal and AppKit for real; needs a GPU and a window server
zig build smoke-leaks  # 400 editor cycles under `leaks --atExit`
zig build ring-race    # the history buffer under Thread Sanitizer; needs a Linux host
```

**CI runs all three now.** The `smoke` job runs each half as its own step,
requiring `smoke-gpu` and letting `smoke-appkit` fail without failing the job,
and `smoke-leaks` runs beside them at `-Dleak-cycles=40`, also under
`continue-on-error`. The `ring-race` job runs on Linux, where it is required.

So two of those four steps observe without being able to stop anything, and
[#72](https://github.com/cboone/fosforo/issues/72) is where the `smoke-appkit`
half of that gets decided. Running them locally is what has teeth in the
meantime. The leak check's criteria do not vary with the cycle count while its
cost does, which is why CI takes 40 against a default of 400 here.

`zig build ring-race` refuses on macOS and says where it does run: Zig 0.16 links
a `-fsanitize-thread` binary on Apple Silicon that segfaults before `main`, so it
runs on Linux in CI. Compile-check it from a Mac with `zig build-exe
src/ring_race.zig -fsanitize-thread -lc -target x86_64-linux-gnu`. The ring's
memory ordering also has a source canary that fails `zig build test` on any
machine, so weakening it is caught locally even though the sanitizer is not
([ADR 0016](docs/adr/0016-verify-the-ring-ordering-with-tsan.md)).

## Code Style

- Run `zig fmt build.zig src/` before committing
- Format shell scripts before committing with `git ls-files -z | xargs -0 shfmt -f | xargs shfmt -w`, and pass `shfmt` no parser or printer options. The profile lives in `.editorconfig`, and `shfmt` ignores that file entirely if any of those options is given (`-i`, `-ci`, `-sr`, `-ln` and the rest of the two groups in `shfmt --help`). The output-mode selectors are fine, so `-w` and `-d` above are safe. Select files through `git ls-files` rather than running `shfmt -w .`, which reaches vendored scripts under `build/` and reformats them
- Keep `shellcheck` clean: `git ls-files -z | xargs -0 shfmt -f | xargs shellcheck`
- Keep `typos` clean by running it before committing. It reads `typos.toml`, which allowlists words the tool is wrong about and ignores backticked commit SHAs. Add to that file rather than rewording a correct word, and if a document has to spell out a misspelling in order to explain it, wrap that part in `<!-- spellchecker:off -->` and `<!-- spellchecker:on -->`
- Keep `ruff` clean if you touched `scripts/measure-trace`: `ruff format --check . && ruff check .`. That file has no `.py` extension, so `ruff.toml`'s `extend-include` is the only reason ruff can see it at all, and **a vacuous pass is the failure to watch for**: ruff reports discovering nothing as success, so check that `ruff format --check` says it read 1 file rather than 0. `ruff.toml` is the authority on its style, and the `[measure-trace]` section in `.editorconfig` restates it by hand, because ruff does not read that file
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
1. If you touched `scripts/measure-trace`, ensure `ruff format --check .` and `ruff check .` are both clean
1. Submit a pull request

### Branch Naming

Use descriptive branch names with a type prefix:

- `feature/*`: new features
- `fix/*`: bug fixes
- `docs/*`: documentation changes
- `refactor/*`: code refactoring
- `test/*`: test additions or fixes
- `chore/*`: maintenance, build, and CI work
