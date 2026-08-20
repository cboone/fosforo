# Name the install steps for what they guarantee, and script the Audio Unit build

Addresses [#43](https://github.com/cboone/fosforo/issues/43).

## Context

The install path works and cannot be read, and the Audio Unit half of it is prose rather than code.

Three steps whose names all contain "install" mean three different things. Zig's own `install` copies into `zig-out` and has nothing to do with plug-in folders. `install-clap` copies the CLAP into `~/Library/Audio/Plug-Ins/CLAP` and prints no hash, so it cannot say what landed. `install-plugins` builds the CLAP, installs it, verifies it, and installs the Audio Unit **only if CMake happens to have been run already** in that worktree. So the real distinction between the last two is not "one bundle versus two"; it is "an unverified copy" versus "a verified copy that also picks up a component somebody else built". Neither name carries that, and the guarantee is the entire reason `install-plugins` exists.

The consequence is the failure `scripts/install-plugins` was written to prevent, reintroduced one level up. A worktree that has never run CMake has a **stale Audio Unit installed from some other branch**, and `install-plugins` cannot overwrite it, because nothing was built to copy. It leaves the old one in place and reports only the CLAP. Logic then loads a plugin from a different branch, it renders, and it reads as a pass. That was observed while verifying [#37](https://github.com/cboone/fosforo/issues/37): a `Fosforo.component` dated two weeks before the branch under test, sitting next to a correctly installed CLAP from the branch under test.

The intended outcome is one invariant, stated once and true of every step:

> **An `install-*` step builds exactly what it installs, copies it to `~/Library/Audio/Plug-Ins`, and prints the hash of what landed. A build step stays in the worktree.**

Everything below follows from that. The old asymmetry, where both install steps built the CLAP and neither built the Audio Unit, is what made the names unreadable in the first place.

## Decisions taken

Three forks were settled before writing this, and the rest of the plan is downstream of them.

1. **Keep the `install-*` names, and fix the destination confusion where it is actually read.** `b.install_tls.description` is a writable field on `std.Build`, so Zig's own `install` step can say `zig-out` out loud in `zig build --help` instead of "Copy build artifacts to prefix path". Renaming the two project steps would have cost a rename in `AGENTS.md`, `CONTRIBUTING.md`, `README.md` and eight files under `docs/plans/done/` to solve a problem one description string solves.
1. **Remove the CMake clobber rather than encoding the ordering around it.** `cmake/CMakeLists.txt` drives a bare `zig build --release=fast` because the only thing it wants from Zig is `libfosforo_impl.a`; that command also reassembles and re-signs `zig-out/Fosforo.clap`. Pointing it at a dedicated `impl` step with its own `--prefix` makes it stop touching either. The ordering hazard then does not need encoding, because it no longer exists.
1. **A missing Audio Unit reports, and does not refuse or delete.** When one is installed and none was built here, name it, its hash and its modification date, and say plainly that a host will load *that* bundle. Exit 0: the CLAP-only loop is deliberately the common one.

## The step family

| Step              | Builds                                        | Writes to                       |
| ----------------- | --------------------------------------------- | ------------------------------- |
| `install`         | the CLAP bundle (Zig's own default step)      | `zig-out`                       |
| `impl`            | `libfosforo_impl.a` only                      | the prefix, for CMake's use     |
| `audio-unit`      | `Fosforo.component` via CMake                 | `build/assets`                  |
| `plugins`         | both bundles                                  | `zig-out` and `build/assets`    |
| `install-clap`    | the CLAP, then installs and verifies it       | `~/Library/Audio/Plug-Ins/CLAP` |
| `install-plugins` | both bundles, then installs and verifies both | both plug-in folders            |

`audio-unit` also produces `build/assets/Fosforo.clap`, because `fosforo_all` is the target and `--target fosforo_auv2` alone does not build the CLAP. That is the wrapper CLAP CI validates, not a second thing to install.

## Changes

### `build.zig`

- Re-describe Zig's own step: `b.install_tls.description = "Assemble Fosforo.clap into zig-out (not a plug-in folder)"`. `TopLevelStep` is a private type but `install_tls` is a public field, so the assignment compiles without naming it. Confirm this at the first build.
- Replace `b.installArtifact(impl)` with a named `InstallArtifact` node reused by a new `impl` step. Drop it from the default install step: with CMake taking its own prefix, nothing reads `zig-out/lib/libfosforo_impl.a`, and a plain `zig build` should produce exactly what `AGENTS.md` claims it does. The dynamic library compiles the same modules, so no type checking is lost.
- Add `audio-unit`, running a new `scripts/build-audio-unit` as a `SystemCommand` with `stdio = .inherit` and `has_side_effects = true`, matching the `install-plugins` and `smoke-leaks` call sites already in the file.
- Add `plugins`, depending on `b.getInstallStep()` and on the `audio-unit` run step.
- **Delete the inline `sh -c` copy** in `installClapBundle`. `install-clap` becomes `scripts/install-plugins --clap-only` and inherits the hash comparison it never had. This is the reuse that collapses the verified/unverified axis; there should be exactly one implementation of "copy a bundle into a plug-in folder and prove it landed".
- `install-plugins` gains a dependency on the `audio-unit` run step, which is what makes the invariant true.

The two Zig builds in play, the outer Debug one and CMake's nested `zig build --release=fast impl`, no longer collide over an output path, because `--prefix` separates them. They do share `.zig-cache`, which Zig's manifest locking is built for. Measure it rather than assume it: run `zig build install-plugins` from clean and confirm both halves land.

### `cmake/CMakeLists.txt`

```cmake
- set(ZIG_IMPL_LIB "${REPO_ROOT}/zig-out/lib/libfosforo_impl.a")
+ set(ZIG_PREFIX "${CMAKE_BINARY_DIR}/zig")
+ set(ZIG_IMPL_LIB "${ZIG_PREFIX}/lib/libfosforo_impl.a")

  add_custom_target(fosforo-zig ALL
-     COMMAND ${ZIG_EXECUTABLE} build --release=fast
+     COMMAND ${ZIG_EXECUTABLE} build --release=fast --prefix ${ZIG_PREFIX} impl
```

`build/` is already in `.gitignore`, so `build/zig/` needs nothing. Update the `BYPRODUCTS` line and the comment above the target, which currently explains a full build.

### `scripts/build-audio-unit` (new)

Invoke the `write-bash-scripts` skill before writing it. It carries the two constraints that were prose:

- Configure only when `build/CMakeCache.txt` is absent. CMake regenerates its own build system when `CMakeLists.txt` changes, so this is safe rather than merely cheap. A `--reconfigure` flag forces it, for changing cache variables by hand.
- Build `fosforo_all`, never `fosforo_auv2`, because setting `AUV2_MANUFACTURER_CODE` sends `make_clapfirst_plugins` down a branch that adds no dependency between the two targets.

Exit codes follow the sibling scripts: `0`, `64` for usage, `70` for a failed build. Add the filename to the `.editorconfig` shell section in the same commit, per the gotcha about `shfmt` styling a file only once it is listed there.

### `scripts/install-plugins`

The header currently explains the manual Audio Unit copy as a standing state of affairs. It is not one any more; rewrite it around the invariant, and keep the `can_resize` incident, which is still the reason the script exists.

Add a report for an installed component that this build cannot account for, using the existing `short_hash` and `stat -f '%Sm'` for the date. Four cases, one code path:

| Built here           | Installed | Report                                                                     |
| -------------------- | --------- | -------------------------------------------------------------------------- |
| yes                  | either    | install, compare, print the hash (unchanged)                               |
| no                   | yes       | name it, hash it, date it, say a host will load it, `zig build audio-unit` |
| no                   | no        | say so, and that Logic needs `zig build audio-unit`                        |
| `--clap-only`, built | yes       | say it was skipped, and whether the installed one matches the built one    |

The `--clap-only` row is worth the extra branch: "skipped" is currently the whole message, and it hides the same staleness question in the case where the answer is cheapest to get.

### `.github/workflows/ci.yml`

The `clap-wrapper` job adopts `./scripts/build-audio-unit` in place of its two `cmake` lines. A build script only a developer runs is one CI cannot vouch for, and the `fosforo_all` rationale then has a single home instead of being restated in the job's comment. The comment shrinks to a pointer; nothing else in that job moves, including the deliberate ordering of the two plist assertions ahead of the signature check.

### Documentation

- `AGENTS.md`: the `Development` command block, the `Structure` listing (add `scripts/build-audio-unit`), the "A host loads what is installed" gotcha (`install-plugins` now builds both), the `--target fosforo_auv2` gotcha (point it at the script), and the **`cmake --build` rebuilds and re-signs `zig-out/Fosforo.clap`** gotcha. That last one is a rewrite, not a deletion: the clobber goes away, and the optimize-mode split it also documents stays exactly as true, since the component is still linked against a ReleaseFast archive while a plain `zig build` is Debug. Say that the ordering in `scripts/build-release-bundles` is no longer load-bearing.
- `scripts/build-release-bundles`: rewrite the ordering comment in `main`. Keep the order; retire the claim that it is load-bearing.
- `scripts/build-installer`: its input assertion cites "the CMake clobbering gotcha in AGENTS.md". The assertion stays correct, since a plain `zig build` still replaces a release CLAP with a Debug one; only the cited route disappears.
- `CONTRIBUTING.md`: replace the two `cmake` lines under **Building the Audio Unit** with `zig build audio-unit`.
- `README.md`: replace the manual `cp -R` with `zig build install-clap`, and `cmake -B build cmake/ && cmake --build build` with `zig build audio-unit`. The README's CMake line omits `--target fosforo_all` today, so this fixes a latent defect as a side effect.
- `CHANGELOG.md`: one entry under `Unreleased` → `Changed`, in the existing house style, covering the invariant, the new steps, the removed clobber and the stale-component report.

## Out of scope

Carried from the issue, and not revisited here: the release scripts' own ordering and their local-only policy (ADR 0014); making the day-to-day loop invoke CMake, which it still deliberately does not; and the optimize-mode split, which stays as it is and gets documented rather than changed.

## Verification

Run from a worktree where CMake has never been configured, which is the state the issue was filed from.

1. `zig build --help` lists `impl`, `audio-unit`, `plugins`, `install-clap`, `install-plugins`, and shows `install` describing `zig-out`.
1. `zig build install-clap` on a worktree with a foreign component installed prints the CLAP hash **and** names the stale `Fosforo.component` with its hash and date. Exit code 0.
1. `zig build install-plugins` from clean configures CMake, builds both bundles, installs both, and prints two hashes. Confirm the nested build behaves: both halves land, and neither Zig build reports a cache error.
1. `shasum -a 256` on both installed binaries against `zig-out/Fosforo.clap/Contents/MacOS/Fosforo` and `build/assets/Fosforo.component/Contents/MacOS/Fosforo` agrees, which is the check `AGENTS.md` documents and the one the old ordering would have broken.
1. `ls zig-out/Fosforo.clap` is unchanged in mtime and hash after `zig build audio-unit`, which is the clobber assertion. `ls build/zig/lib/libfosforo_impl.a` exists and `zig-out/lib/` does not.
1. `codesign --verify --strict --verbose zig-out/Fosforo.clap` still passes after a CMake build, which it could not be trusted to before.
1. `zig build test`, `zig fmt --check build.zig src/`, `typos`, and both `shfmt -d` and `shellcheck` over `git ls-files -z | xargs -0 shfmt -f`. `markdownlint-cli2` for the documentation changes.
1. `scripts/build-release-bundles` is not run (it needs a Developer ID), but read it against the new CMake target to confirm its assumptions still hold.
1. Open the plugin in REAPER and in Logic from the installed bundles, confirming the hashes first. Logic is the one that proves the stale-component failure is closed.
