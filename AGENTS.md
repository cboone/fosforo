# fosforo

## Overview

A Mac-first GPU-rendered phosphor oscilloscope and signal-analysis plugin, authored as a CLAP and rendered with Metal.

The display name is **Fósforo**; the repository, binary, and identifiers stay ASCII `fosforo`.

## Non-negotiables

These are settled decisions recorded in [`docs/adr/`](docs/adr/). Do not relitigate them in code review; supersede them with a new ADR instead.

- **macOS on Apple Silicon only.** Not a portability oversight (ADR 0001).
- **Zig is pinned to 0.16.0.** `build.zig.zon` is the single source of truth and CI reads it. Compiler bumps are deliberate, scheduled work (ADR 0002).
- **The plugin is authored once, as a CLAP.** Never author an Audio Unit or VST3 directly; clap-wrapper projects outward (ADR 0003).
- **Metal must not leak above `src/gpu/iface.zig`.** That seam is load-bearing even though only one backend exists (ADR 0005).
- **No WebView UI** (ADR 0006).
- **Nothing reachable from the audio thread may allocate, lock, or make a syscall** (ADR 0010).

## Structure

```text
build.zig                   two artifacts from one core: static lib + .clap bundle
build.zig.zon               pins Zig 0.16.0, CLAP 1.2.10, zig-objc by content hash
cmake/                      clap-wrapper integration, used only for the AUv2 build
  CMakeLists.txt
  entry.cpp                 the only C++ in the project; builds the clap_entry symbol
  narrow-au-resource-usage  drops clap-wrapper's default AU sandbox claims
macos/Info.plist            the .clap bundle's plist
shaders/scope.metal         compiled at runtime from embedded source, not linked
src/
  main.zig                  the host-facing boundary and exported entry points
  clap/c.zig                translated CLAP ABI plus comptime layout assertions
  clap/plugin.zig           factory, descriptor, lifecycle, audio ports, process
  clap/state.zig            the versioned save/load format and its stream loops
  clap/log.zig              diagnostics routed through the host's clap.log
docs/
  adr/                      settled architecture decisions
  design/                   the source brainstorm this project came from
  plans/todo/               active plans
  plans/done/               completed plans, kept as historical records
```

## Development

```bash
zig build                  # produces zig-out/Fosforo.clap
zig build test             # unit tests
zig build install-clap     # copy into ~/Library/Audio/Plug-Ins/CLAP
zig fmt --check build.zig src/
zig build validate-shaders # needs the Metal toolchain; see below
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d      # no parser/printer options: they discard .editorconfig
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck
```

`zig build` alone produces a loadable `.clap`, which REAPER opens natively. That is the day-to-day loop and it never invokes CMake.

CMake is needed only for the Audio Unit that Logic requires, and it is much slower because it fetches the AudioUnit SDK:

```bash
cmake -B build cmake/
cmake --build build --target fosforo_all
```

Validate with `clap-validator validate zig-out/Fosforo.clap`, and Audio Units with `auval`. CI runs `clap-validator` on every push against **both** `.clap` bundles, the Zig-built one and the clap-wrapper-built `build/assets/Fosforo.clap`, so neither is only a local step. `auval` still is.

## Gotchas

- **`xcrun` caches tool lookups.** If `xcrun metal` reports the Metal toolchain missing right after installing it, run `xcrun --kill-cache`.
- **CLAP bindings come from preprocessed headers.** Zig 0.16's `translate-c` mishandles `#pragma once` under path aliasing, so `build.zig` runs the headers through `zig cc -E` first. Object-like macros do not survive that; the ones that matter are restated and tested in `src/clap/c.zig` (ADR 0004).
- **`unnamed_0` is toolchain-generated.** The anonymous union in `clap_window` is reached only through `clap.cocoaView()`. Re-verify after any Zig upgrade.
- **Keep three deployment targets in step:** `build.zig`, `cmake/CMakeLists.txt`, and `macos/Info.plist` all specify macOS 11.0.
- **The AUv2 build rewrites its own `Info.plist`.** clap-wrapper hardcodes a `resourceUsage` dictionary claiming network and whole-filesystem access, and emits it next to the `sandboxSafe` flag that Apple documents as mutually exclusive with it. `cmake/narrow-au-resource-usage` strips it as a POST_BUILD step, and the `clap-wrapper` CI job asserts the result independently. Both no-op safely if clap-wrapper stops emitting it, so re-check when the pin moves.
- **Some identifiers are permanent.** The AU triple (`aufx`/`Fsfr`/`Ctmn`) and the CLAP plugin `id` are stored in users' project files; changing either makes the plugin read as missing. The manufacturer name and display name are free metadata. See the plan's identifiers section before touching any of them.
- **Shader validation is deliberately not part of `zig build test`,** so the build stays hermetic (ADR 0009).
- **`shfmt` reads `.editorconfig`, but only when given no parser or printer options.** The shell profile, equivalent to `-i 2 -ci -sr`, lives there because `cmake/narrow-au-resource-usage` was written to a style the repository never recorded, so bare `shfmt` reported an already-consistent file as unformatted. Passing any option from `shfmt --help`'s "Parser options" or "Printer options" groups (`-ln`, `-p`, `-s`, `-i`, `-bn`, `-ci`, `-sr`, `-kp`, `-fn`, `-mn`) makes `shfmt` discard `.editorconfig` wholesale, which means `shfmt -d` is correct and `shfmt -i 2 -d` silently is not. The output-mode selectors are exempt, so `-d`, `-w`, `-l` and `-f` are all safe. Verified per flag, not inferred from the documentation. The script has no extension, so the section names it directly; a `[*.sh]` section does not match it. Always select files with `git ls-files`, never `shfmt -d .`: `shfmt` does not read `.gitignore`, so walking the tree reaches vendored scripts under `build/` once the CMake build has run, and `shfmt -w .` will reformat them. A fresh CI checkout has no `build/`, so `-d .` passes there and fails locally. The `shell` CI job enforces this and `shellcheck` together, and `.editorconfig` is deliberately absent from that workflow's `paths-ignore` lists so a change to the profile cannot skip the job that checks it.
- **`clap-validator` is pinned twice over,** at workflow-level `env` in `.github/workflows/ci.yml`: the validator commit, because it is installed from git rather than a registry and a tag can move, and the Rust toolchain that builds it, because the crate declares an MSRV the runner image may stop satisfying. Bump them together and the cache key follows automatically. Warnings do not fail either job: `clap-validator` exits non-zero on failed and crashed tests only, so a `WARNING` line is visible in the log without breaking the build.
- **Two jobs validate a `.clap`, and they share one cached validator.** `.github/actions/clap-validator` is a local composite action that builds and caches it; `clap-validator` and `clap-wrapper` both call it and pass the workflow-level pins. The cache key lives only in that action, because a key written twice can drift, and a drifted key still passes: it just pays a full Rust build every run. On a cold cache both jobs build concurrently and race to save, which is safe, since the loser warns rather than failing.
- **`--target fosforo_auv2` does not build the CLAP.** Setting `AUV2_MANUFACTURER_CODE` sends `make_clapfirst_plugins` down its explicit-configuration branch, which never adds a dependency from the AUv2 target to the CLAP one. Build `fosforo_all` when both artifacts are wanted, which is what CI does.
- **REAPER accepts `clap.log` messages and discards them.** It implements the extension, so `Log.init` finds it and a host-only design would send every diagnostic into a hole with no visible destination. That is why debug builds mirror to `stderr` as well as calling the host, rather than treating `stderr` as a fallback for hosts that offer nothing. Launch REAPER from a terminal to read them.
