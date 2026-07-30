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
  set-au-display-name       writes the display name and description into the AU
macos/Info.plist            the .clap bundle's plist
shaders/scope.metal         compiled at runtime from embedded source, not linked
src/
  main.zig                  the host-facing boundary and exported entry points
  clap/c.zig                translated CLAP ABI plus comptime layout assertions
  clap/plugin.zig           factory, descriptor, lifecycle, audio ports, process
  clap/gui.zig              the editor's lifecycle, with no AppKit or Metal in it
  clap/state.zig            the versioned save/load format and its stream loops
  clap/log.zig              diagnostics routed through the host's clap.log
  gpu/iface.zig             THE SEAM. No Metal type may be named above this file
  gpu/metal/renderer.zig    the one backend: device, pipeline, layer, one frame
  platform/objc.zig         Core Graphics types and the main-thread assertion
  platform/view.zig         the NSView the host embeds, and nothing about Metal
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
codesign --verify --strict --verbose zig-out/Fosforo.clap  # the bundle signature, not the linker's
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d      # no parser/printer options: they discard .editorconfig
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck
```

`zig build` alone produces a loadable `.clap`, which REAPER opens natively. That is the day-to-day loop and it never invokes CMake.

CMake is needed only for the Audio Unit that Logic requires, and it is much slower because it fetches the AudioUnit SDK:

```bash
cmake -B build cmake/
cmake --build build --target fosforo_all
```

Validate with `clap-validator validate zig-out/Fosforo.clap`. CI runs it on every push against **both** `.clap` bundles, the Zig-built one and the clap-wrapper-built `build/assets/Fosforo.clap`, so neither is only a local step, and it asserts every bundle's signature alongside them. The Audio Unit has no equivalent: `auval` cannot see this component at all, for the reason in the gotchas below, so loading it in Logic is the only check there is.

## Gotchas

- **`xcrun` caches tool lookups.** If `xcrun metal` reports the Metal toolchain missing right after installing it, run `xcrun --kill-cache`.
- **CLAP bindings come from preprocessed headers.** Zig 0.16's `translate-c` mishandles `#pragma once` under path aliasing, so `build.zig` runs the headers through `zig cc -E` first. Object-like macros do not survive that; the ones that matter are restated and tested in `src/clap/c.zig` (ADR 0004).
- **`unnamed_0` is toolchain-generated.** The anonymous union in `clap_window` is reached only through `clap.cocoaView()`. Re-verify after any Zig upgrade.
- **Metal's and AppKit's constants are hand-restated.** Their headers are Objective-C, so `translate-c` cannot read them the way it reads CLAP's. `MTLPixelFormat`, `MTLLoadAction`, `MTLStoreAction`, and `MTLPrimitiveType` live in `src/gpu/metal/renderer.zig`; `NSView.autoresizingMask` lives in `src/platform/objc.zig`. Unlike the restated CLAP macros in `src/clap/c.zig`, there is no surviving header symbol to test them against. They are ABI values Apple cannot renumber, and a wrong one shows as a black or garbled drawable rather than as anything subtle.
- **`@embedFile` reaches `shaders/` through the import table.** It resolves relative to the importing file and cannot escape the module root, which is `src/`. `build.zig` adds the shader with `addAnonymousImport`, which is why `@embedFile("scope.metal")` works from `src/gpu/metal/`. Keeping shaders outside `src/` is deliberate: `zig build validate-shaders` treats that directory as shaders rather than as Zig.
- **Keep three deployment targets in step:** `build.zig`, `cmake/CMakeLists.txt`, and `macos/Info.plist` all specify macOS 11.0.
- **The AUv2 build rewrites its own `Info.plist`.** Two `POST_BUILD` scripts correct what clap-wrapper generates, and the `clap-wrapper` CI job asserts both results independently, because a rewriting step cannot detect its own absence. `cmake/narrow-au-resource-usage` strips a hardcoded `resourceUsage` dictionary claiming network and whole-filesystem access, emitted next to the `sandboxSafe` flag that Apple documents as mutually exclusive with it; it no-ops safely if clap-wrapper stops emitting it, so re-check when the pin moves. `cmake/set-au-display-name` replaces the generated name and description, for the reason in the display name bullet below. Both must stay ahead of the signing command, which is the third and last `POST_BUILD` command on that target; see the next bullet for why the order is load-bearing.
- **Every bundle is signed by the build, and two different signatures are involved.** The linker ad-hoc signs the Mach-O binary on arm64 unconditionally, which is why these bundles load at all, but that signature covers only the binary: it reports `flags=0x20002(adhoc,linker-signed)` and `Sealed Resources=none`, and `codesign --verify` rejects the bundle with `code has no resources but signature indicates they must be present`. The bundle signature is a separate thing and nothing upstream supplies it. clap-wrapper's only `codesign` calls sign its own generated AUv2 build helper, `wrap_clap.cmake` has none at all, and `make_clapfirst.cmake` states that signing is the consuming project's decision. So `build.zig` signs `zig-out/Fosforo.clap` and `cmake/CMakeLists.txt` signs both bundles it builds, all three ad-hoc, and CI asserts all three. Override the identity with `zig build -Dcodesign-identity=` or `-DFOSFORO_CODESIGN_IDENTITY=`, and both call sites then add `--timestamp` and `--options runtime` as well, because notarization rejects a submission missing either. Those two follow from the identity rather than being switches of their own, so a distributable signature cannot be half-configured, and neither is ever applied ad-hoc: `--timestamp` would make a plain build need the network, and an ad-hoc signature has no certificate whose expiry a timestamp could outlive. `scripts/assert-adhoc-signature` guards that in both CI jobs, and it asserts a negative `codesign --verify` cannot: a conditional that leaked would still produce a valid signature, so the first symptom would be a job hanging on Apple's timestamp server rather than failing anything legible. It checks three independent marks, because they fail independently: the `runtime` flag, a `Timestamp=` line, and an `Authority=` chain. The positive direction has no CI equivalent, since no runner has a certificate, and is checked by hand. **The AUv2 signing command must remain the last `POST_BUILD` command registered on that target,** because signing seals the `Info.plist` the two scripts above rewrite: sign first and `codesign --verify` reports tampering rather than a missing signature, which is worse than not signing. That is also why the `clap-wrapper` job runs `codesign --verify` and both `--check` scripts together and treats the three as one test: signing in the wrong order passes the two `--check` runs and fails the signature, while a dropped signing step fails only the signature. `/usr/bin/codesign` is a base-OS binary rather than an on-demand Xcode component, so none of this costs the hermetic build ADR 0009 protects. Every automated invocation names it by absolute path rather than resolving it through `PATH`, so that stays true even where a wrapper or shim shadows the name; the commands above are the short form because a human types those.
- **`cmake --build` rebuilds and re-signs `zig-out/Fosforo.clap`.** `cmake/CMakeLists.txt` drives Zig itself, through an `ALL` custom target running a bare `zig build --release=fast`, because the only thing CMake wants from Zig is `libfosforo_impl.a`. That command also reassembles the Zig-built bundle and signs it, ad-hoc, since the custom target passes no `-Dcodesign-identity`. So a CMake build silently replaces whatever `zig build -Dcodesign-identity=` produced, and any check that runs afterwards is reading a different file than the one that was signed. `scripts/build-release-bundles` builds the Audio Unit first and the CLAP second for exactly this reason; the order is load-bearing, not cosmetic. The same custom target is why the two paths disagree about optimize mode: `standardOptimizeOption` declares no default, so a plain `zig build` is **Debug** while everything CMake triggers is **ReleaseFast**. A shipped CLAP must be built `--release=fast` explicitly, or the release carries a Debug renderer next to a ReleaseFast Audio Unit built from the same tree.
- **The hardened runtime costs this plugin nothing, and an entitlements file would be inert.** Notarization requires `--options runtime`, and the obvious worry is that ADR 0009's runtime shader compilation needs `com.apple.security.cs.allow-jit` or one of the `allow-unsigned-executable-memory` family. It needs neither, for two independent reasons, both measured rather than reasoned about. First, `newLibraryWithSource:` compiles **out of process**: Metal hands the source to `MTLCompilerService.xpc`, an Apple-signed XPC service inside `Metal.framework`, so no executable memory is ever created in the caller's address space and there is nothing for a JIT entitlement to permit. A standalone binary signed `--options runtime` with no entitlements at all compiles `shaders/scope.metal` and resolves both functions, which is a *stricter* case than the plugin's. Second, entitlements attach to a process, and a plugin never gets one: it is loaded into the host's address space, so the host's entitlements apply and its own are ignored. REAPER runs hardened and carries `allow-jit`, `allow-unsigned-executable-memory` and `disable-library-validation`, that last being what lets it load a bundle signed by another team at all; Logic hosts AUv2 out of process in Apple's `AUHostingServiceXPC`, which carries the latter two. So there is deliberately no `entitlements.plist` in this repository, and adding one would change nothing about how the plugin runs. Re-measure before assuming otherwise; do not add entitlements speculatively.
- **`auval` cannot see this component, and neither can `AudioComponentFindNext`.** On Darwin 25.5.0 both enumerate only Apple's built-in components, from an ordinary terminal outside any sandbox, while Logic sees every installed Audio Unit including this one. A null result from either is not evidence that the component failed to register. Use a host.
- **`~/Library/Caches/AudioUnitCache` is not the AU registration cache.** Deleting it is the standard advice, it changes nothing, and it is not rebuilt afterwards. The capability data lives in `~/Library/Preferences/com.apple.audio.AudioComponentCache.plist`. Relaunching Logic triggers a rescan; `killall AudioComponentRegistrar` does not, and `launchctl kickstart` on the registrar is refused under SIP.
- **The display name lives in four places.** It cannot be derived from one source, because it crosses Zig, CMake, and a generated plist. `src/clap/plugin.zig` holds the CLAP descriptor's `name` and `description` and is the source of truth; `macos/Info.plist` carries `CFBundleName` and `CFBundleDisplayName` for the Zig-built bundle; `DISPLAY_NAME` in `cmake/CMakeLists.txt` covers the CLAP that CMake builds; and `cmake/set-au-display-name` covers the Audio Unit, whose plist clap-wrapper composes from the ASCII `OUTPUT_NAME` and then describes as a wrapper. Change one, change all four. The ASCII `Fosforo` that names files, binaries, and `CFBundleExecutable` is a separate string and must not follow.
- **Some identifiers are permanent.** The AU triple (`aufx`/`Fsfr`/`Ctmn`) and the CLAP plugin `id` are stored in users' project files; changing either makes the plugin read as missing. The manufacturer name and display name are free metadata. See the plan's identifiers section before touching any of them.
- **Shader validation is deliberately not part of `zig build test`,** so the build stays hermetic (ADR 0009).
- **`shfmt` reads `.editorconfig`, but only when given no parser or printer options.** The shell profile, equivalent to `-i 2 -ci -sr`, lives there because `cmake/narrow-au-resource-usage` was written to a style the repository never recorded, so bare `shfmt` reported an already-consistent file as unformatted. Passing any option from `shfmt --help`'s "Parser options" or "Printer options" groups (`-ln`, `-p`, `-s`, `-i`, `-bn`, `-ci`, `-sr`, `-kp`, `-fn`, `-mn`) makes `shfmt` discard `.editorconfig` wholesale, which means `shfmt -d` is correct and `shfmt -i 2 -d` silently is not. The output-mode selectors are exempt, so `-d`, `-w`, `-l` and `-f` are all safe. Verified per flag, not inferred from the documentation. The scripts in `cmake/` have no extension, so the section names each one directly; a `[*.sh]` section does not match them. **A new shell script must be added to that section.** The `shell` job selects files by shebang, so it lints a new script immediately, while `.editorconfig` styles it only once listed, and the failure that asymmetry produces is `shfmt` reporting tabs against a file that matches its siblings exactly. Always select files with `git ls-files`, never `shfmt -d .`: `shfmt` does not read `.gitignore`, so walking the tree reaches vendored scripts under `build/` once the CMake build has run, and `shfmt -w .` will reformat them. A fresh CI checkout has no `build/`, so `-d .` passes there and fails locally. The `shell` CI job enforces this and `shellcheck` together, and `.editorconfig` is deliberately absent from that workflow's `paths-ignore` lists so a change to the profile cannot skip the job that checks it.
- **`clap-validator` is pinned twice over,** at workflow-level `env` in `.github/workflows/ci.yml`: the validator commit, because it is installed from git rather than a registry and a tag can move, and the Rust toolchain that builds it, because the crate declares an MSRV the runner image may stop satisfying. Bump them together and the cache key follows automatically. Warnings do not fail either job: `clap-validator` exits non-zero on failed and crashed tests only, so a `WARNING` line is visible in the log without breaking the build.
- **Two jobs validate a `.clap`, and they share one cached validator.** `.github/actions/clap-validator` is a local composite action that builds and caches it; `clap-validator` and `clap-wrapper` both call it and pass the workflow-level pins. The cache key lives only in that action, because a key written twice can drift, and a drifted key still passes: it just pays a full Rust build every run. On a cold cache both jobs build concurrently and race to save, which is safe, since the loser warns rather than failing.
- **Every `timeout-minutes` is measured, not copied.** Each one sits at roughly 4x the slowest run observed for that job, with the figure and its sample size in a comment beside it; `docs/plans/done/2026-07-29-tighten-ci-job-timeouts.md` holds the full table and the queries that produced it. Re-measure before changing one, rather than copying a neighbour: that is exactly how the old values propagated, and it left `shell` at 150x. Three details are easy to get wrong. The `ci / *` and `scan / *` values are `with:` inputs rather than job keys, because those jobs belong to reusable workflows, and one input covers all of a workflow's jobs, so the value is set by the slowest of them. **`shaders` is a deliberate exception:** its ceiling does not budget for the Metal toolchain download, which has never fired and is unmeasured, so if a runner image ever ships without the toolchain the job fails rather than carrying insurance indefinitely, and the ceiling gets raised once with real data. And **a step-level `timeout-minutes` cannot exceed its job's**, so the one on that download step labels a wedged download rather than granting it extra budget. The upstream `scan / Validate inputs` job sets no timeout at all and inherits GitHub's 360; that one is not reachable from this repository.
- **`--target fosforo_auv2` does not build the CLAP.** Setting `AUV2_MANUFACTURER_CODE` sends `make_clapfirst_plugins` down its explicit-configuration branch, which never adds a dependency from the AUv2 target to the CLAP one. Build `fosforo_all` when both artifacts are wanted, which is what CI does.
- **REAPER accepts `clap.log` messages and discards them.** It implements the extension, so `Log.init` finds it and a host-only design would send every diagnostic into a hole with no visible destination. That is why debug builds mirror to `stderr` as well as calling the host, rather than treating `stderr` as a fallback for hosts that offer nothing. Launch REAPER from a terminal to read them.
