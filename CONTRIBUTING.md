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
- `actionlint`, only if you are changing anything under `.github/`. CI pins 1.7.12; `brew install actionlint`. It wants `shellcheck` on `PATH` as well, or it skips the `run:` blocks without saying so
- `node` and `npm`, only if you are changing Markdown, which includes every document in `docs/`. Run `npm ci` once; that installs Prettier and `markdownlint-cli2` at the versions `package-lock.json` pins, and it is the only thing in this repository that wants Node. Do not install either globally and expect it to match, since the lockfile is what CI resolves

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

Every bundle also carries the branch and commit it was built from, which the
install steps print and `scripts/read-provenance` reads back out of any built
file. That is the check to reach for when there is nothing here to compare a
hash against, such as a component another branch installed.

A CLAP needs no install at all. REAPER honours `CLAP_PATH`, so a bundle can be
loaded straight out of a worktree, which sidesteps the shared folder entirely.
Move any installed copy aside first, because the variable adds to the standard
locations rather than replacing them:

```bash
CLAP_PATH="$PWD/zig-out" /Applications/REAPER.app/Contents/MacOS/REAPER
```

There is no equivalent for the Audio Unit, and a symlinked component is not
registered by macOS at all, so that half really does have to be copied.

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
zig build smoke-trace  # renders into a texture and measures it; needs a GPU, no window
zig build smoke-leaks  # 400 editor cycles under `leaks --atExit`
zig build ring-race    # the history buffer under Thread Sanitizer; needs a Linux host
zig build gate-race    # the editor's teardown gate, the same way and on the same host
```

**CI runs all of them now.** The `smoke` job runs each half as its own step, and
`smoke-gpu`, `smoke-trace` and `smoke-appkit` all fail the job: the first two
need a device and no window, and the third's window-server dependency was
settled by the 65 green runs #72 cites. `smoke-leaks` runs beside them at
`-Dleak-cycles=40` under `continue-on-error`, so it reports without being able
to stop anything. The `race` job runs both race harnesses on Linux, as two
steps, where they are required.

`smoke-trace` is the one that answers what the shader drew, as opposed to whether
it compiled or whether a frame was presented. It renders through the shipping
pipeline into a texture the backend owns and asserts the vertical mapping, the
rail, the horizontal mapping, period counts, the resolve and the decay against
values computed from the constants in `src/gpu/iface.zig`.

The one advisory step is advisory for a reason rather than out of caution.
`smoke-appkit` fails only on its own assertions and on the window-server
connection that 65 green runs settled, which is why
[#72](https://github.com/cboone/fosforo/issues/72) dropped its flag. The leak
check additionally judges the runner's own AppKit chatter, against class
prefixes that include `NSView` and `IOSurface`, so a framework leaking on its
own account would fail it with nothing here being wrong. Running it locally is
what has teeth. Its criteria do not vary with the cycle count while its cost
does, which is why CI takes 40 against a default of 400 here.

Both race steps refuse on macOS and say where they do run: Zig 0.16 links a
`-fsanitize-thread` binary on Apple Silicon that segfaults before `main`, so
they run on Linux in CI. Compile-check either from a Mac with `zig build-exe
src/ring_race.zig -fsanitize-thread -lc -target x86_64-linux-gnu`, substituting
`src/gate_race.zig`. Each subject also has a source canary that fails `zig build
test` on any machine, so weakening an ordering is caught locally even though the
sanitizer is not ([ADR 0016](docs/adr/0016-verify-the-ring-ordering-with-tsan.md)).

`Gate` lives in `src/clap/gate.zig` rather than in `src/clap/gui.zig` so that a
Linux target can reach it, and `src/gate_race.zig` races a plain buffer standing
in for the editor's own fields. That payload is the whole reason the arm can
discriminate anything: Thread Sanitizer reports unordered access to _non-atomic_
memory, so an ordering that guards nothing but its own word is invisible to it.
That is why `Pending` has no arm and keeps only its canary.

## Code Style

- Run `zig fmt build.zig src/` before committing
- Format shell scripts before committing with `git ls-files -z | xargs -0 shfmt -f | xargs shfmt -w`, and pass `shfmt` no parser or printer options. The profile lives in `.editorconfig`, and `shfmt` ignores that file entirely if any of those options is given (`-i`, `-ci`, `-sr`, `-ln` and the rest of the two groups in `shfmt --help`). The output-mode selectors are fine, so `-w` and `-d` above are safe. Select files through `git ls-files` rather than running `shfmt -w .`, which reaches vendored scripts under `build/` and reformats them
- Keep `shellcheck` clean: `git ls-files -z | xargs -0 shfmt -f | xargs shellcheck`
- Keep `typos` clean by running it before committing. It reads `typos.toml`, which allowlists words the tool is wrong about and ignores backticked commit SHAs. Add to that file rather than rewording a correct word, and if a document has to spell out a misspelling in order to explain it, wrap that part in `<!-- spellchecker:off -->` and `<!-- spellchecker:on -->`
- Keep `ruff` clean if you touched `scripts/measure-trace`: `ruff format --check . && ruff check .`. That file has no `.py` extension, so `ruff.toml`'s `extend-include` is the only reason ruff can see it at all, and **a vacuous pass is the failure to watch for**: ruff reports discovering nothing as success, so check that `ruff format --check` says it read 1 file rather than 0. `ruff.toml` is the authority on its style, and the `[measure-trace]` section in `.editorconfig` restates it by hand, because ruff does not read that file
- Keep `actionlint` clean if you touched a workflow or the composite action: run `actionlint` from the repository root, with no arguments, which is what CI runs. Two silent skips to know about. It finds local actions through the **git** project root, so it must run inside a checkout rather than an exported tree, and **without `shellcheck` on `PATH` it does not lint `run:` blocks at all and still exits 0**. It also cannot check `with:` inputs on a SHA-pinned action or on a remote reusable workflow, which is most of what this repository uses, so a bad input name is caught by reading the run's warnings and by nothing else
- Keep Markdown clean if you touched any `.md` file, and do it in this order: `npx prettier --write "**/*.md"` first, then `npx markdownlint-cli2`. Prettier is the fixer and markdownlint is the verifier, so running the linter first only shows you findings the formatter was about to resolve. **Never pass `--fix` to markdownlint**: it cannot fix `MD060` at any version, and it ignores the file arguments it is given and rewrites every file matching its globs, including completed plans under `docs/plans/done/` that are historical records. Two things that surprise people: `markdownlint-cli2` lints `node_modules/` unless the `ignores` list stops it, which is why that entry is there and must stay; and Prettier normalises `*emphasis*` to `_emphasis_`, which is deliberate and is why `MD049` is `false`
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
