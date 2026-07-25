# Fósforo: repo foundation and phased build plan

## Context

`docs/design/scope-plugin-handoff.md` records an extended brainstorm about building a Mac-first audio signal-analysis plugin in Zig, authored as a CLAP, rendered with Metal. That document is deliberately a map of territory rather than a specification: it settles the technical stack, leaves the feature set as an unsynthesized menu, and explicitly hands the next session the job of resolving the open choices and producing a phased build plan.

This is that plan.

The product thesis is that analysis tools are a market failure rather than a hard problem. The DSP behind an oscilloscope, a correlation meter, or a spectrogram is undergraduate signal processing; the entire moat is rendering and interaction design, which no vendor can justify funding because analysis tools do not change the sound and the category has a price ceiling set by capable free options. That makes it unusually well-scoped for a single developer.

**Scope of this PR:** Phase 0 only, which is repository foundation, build skeleton, and planning artifacts. Phases 1 through 6 are specified here for sequencing and land in later PRs.

**Product scope:** the first deliverable is the phosphor oscilloscope only, with triggering and a measurement layer. Multi-instance alignment and the Part 4 "Family B" lenses are deferred until the scope ships and gets reassessed.

**Project posture:** structured as a public open-source project following the conventions in the installed scaffolding skills, while the product itself is designed for the author's own Logic workflow rather than a hypothetical user base.

## Findings that changed the plan

Everything below was verified empirically (Zig 0.16.0, Apple M5 Max, macOS 26.5.2, Xcode 26.6) rather than taken from the handoff on faith. Several findings contradict it.

| Finding                                                                                                | Evidence                                                                     | Consequence                                                     |
| -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| `clap-zig-bindings` is **LGPLv3**, covers CLAP **1.2.2**, and **fails to compile on Zig 0.16**         | Cloned; `zig build test` fails on the removed `std.testing.refAllDeclsRecursive` | Rejected. The handoff called it "the cleanest binding path"     |
| Zig 0.16 **removed `@Type`**                                                                           | `@Type` reports `invalid builtin function`                                    | The classic comptime `objc_msgSend` cast pattern no longer works |
| `zig-objc` migrated to the replacement `@Fn`/`@Tuple` builtins, is **MIT**, and passes on 0.16          | Cloned; `zig build test` exits 0                                             | Viable dependency, contrary to the handoff's "hand-roll it"     |
| Zig `translate-c` mishandles `#pragma once` under path aliasing                                         | `clap/factory/../version.h` against `clap/version.h` yields 161 redefinition errors; plain clang is clean | Requires a mechanical header-normalization build step           |
| `clap-wrapper` consumes a **static library**, not a `.clap` dylib                                       | `make_clapfirst_plugins` takes `IMPL_TARGET` plus `ENTRY_SOURCE`             | Inverts the build shape the handoff assumed                     |
| CLAP is at **1.2.10**, MIT licensed                                                                    | `version.h` in `free-audio/clap`                                             | Vendor current rather than 1.2.2                                |
| **Visage is C++-only with no C API**                                                                    | Repository survey                                                            | Prior art only, never a dependency. Question closed             |
| Runtime MSL compilation works from Zig                                                                 | `newLibraryWithSource:` resolved a fragment function                         | Runtime compilation is the single runtime path                  |
| `clap-validator` is **not on crates.io**                                                               | `cargo install clap-validator` fails                                         | Install with `cargo install --git`                              |

The full chain is proven working: `translate-c` over normalized CLAP 1.2.10 headers, `export const clap_entry` emitting `_clap_entry`, Cocoa/Metal/QuartzCore/CoreVideo linking, `objc_msgSend` from Zig including float returns, Metal device acquisition reporting `hasUnifiedMemory: true`, runtime shader compilation, and `metal -fsyntax-only` correctly rejecting a bad shader.

### Environment status

| Tool             | Status                                                                             |
| ------------------ | ------------------------------------------------------------------------------------ |
| Zig 0.16.0       | Installed. Current stable, released 2026-04-13                                     |
| CMake 4.4.0      | Installed. Hard-errors on `cmake_minimum_required` below 3.5 (see risks)           |
| Metal toolchain  | Installed. Needed `xcrun --kill-cache` before `xcrun` would resolve it             |
| REAPER           | Installed. Native CLAP host, so the dev loop needs neither CMake nor a standalone  |
| Logic Pro        | Installed. AUv2 only, which is what makes clap-wrapper necessary at all            |
| `clap-validator` | Not yet installed: `cargo install --git https://github.com/free-audio/clap-validator` |

## Locked decisions

Each becomes an ADR under `docs/adr/`.

| ADR  | Decision                                                                                                                       |
| ------ | -------------------------------------------------------------------------------------------------------------------------------- |
| 0001 | Mac-first, Apple Silicon primary. One audio-thread contract, one SIMD target, unified memory                                   |
| 0002 | Zig, pinned to 0.16.0 via `minimum_zig_version`. Compiler bumps are scheduled work, never incidental                           |
| 0003 | Author CLAP once; project outward with `clap-wrapper`. Never author AU or VST3 directly                                        |
| 0004 | CLAP bindings via `translate-c` over vendored, normalized headers. Reject `clap-zig-bindings` as copyleft, stale, and broken   |
| 0005 | Metal directly, behind a small internal renderer interface. Build one backend; forbid Metal types leaking above the seam       |
| 0006 | Reject a WebView UI. The serializing bridge and borrowed compositor schedule are disqualifying for a measurement instrument    |
| 0007 | Render as a simulation of a physical device: persistent floating-point accumulation, decay, additive trace, tonemap            |
| 0008 | Objective-C glue via `zig-objc`, with the project-local per-arity fallback already proven as a contingency                     |
| 0009 | Runtime MSL compilation is the single runtime path. The Metal toolchain is a validation tool, never a build dependency         |
| 0010 | Lock-free circular history buffer with one monotonic write cursor. Not a queue                                                 |
| 0011 | AUv2 first. AUv3, VST3, AAX, and iPad remain later toggles with no bearing on output quality                                   |
| 0012 | First deliverable is the phosphor oscilloscope only. Alignment and Family B lenses are deferred                                |

## Build architecture

The key structural insight follows from `make_clapfirst_plugins` wanting a static library: build the core **once** as a static archive and give it **two** consumers. CMake then stays off the critical development path entirely.

```text
build.zig
├─ build.zig.zon          pinned: Zig 0.16.0, CLAP 1.2.10, zig-objc
├─ tools/normalize-clap-headers.zig   rewrites #include "../x.h" -> <clap/x.h>
├─ translate-c(normalized clap.h)     -> module "clap.c"
├─ src/                               core implementation
├─ libfosforo_impl.a                  exports fosforo_clap_{init,deinit,get_factory}
│   ├─ consumer 1: zig build clap     -> Fosforo.clap        (fast loop, REAPER, no CMake)
│   └─ consumer 2: cmake/             -> clap-wrapper
│                                        ├─ Fosforo.component  (AUv2, for Logic)
│                                        └─ Fosforo.app        (standalone)
```

Because REAPER loads a raw `.clap`, `zig build` alone drives the entire day-to-day loop. CMake is invoked only when the Audio Unit for Logic is needed, which keeps a C++ build system off the path where iteration speed matters.

### Source layout

```text
src/
  main.zig              exported entry points
  clap/
    c.zig               re-export of the translate-c module
    plugin.zig          descriptor, factory, lifecycle
    ext/                audio_ports, gui, params, state, log
  dsp/
    ring.zig            lock-free history buffer
    decimate.zig        min/max decimation (@Vector)
    resample.zig        polyphase bandlimited interpolation
    trigger.zig         threshold, transient, pitch, transport
  gpu/
    iface.zig           THE SEAM: create float texture, fullscreen pass,
                        instanced additive quads, present. No Metal types above this
    metal/              device, renderer, shaders.metal (@embedFile)
  platform/
    objc.zig            message-send wrappers
    view.zig            NSView + CAMetalLayer
    displaylink.zig     CVDisplayLink
```

## Phase 0: repository foundation (this PR)

| Step | Work                                                                                                                                                                         |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 0.1  | Install `clap-validator` from git. All other prerequisites are already satisfied                                                                                            |
| 0.2  | Run `scaffold-new-repo` (Zig). Produces README, CHANGELOG, `.gitignore`, `AGENTS.md`, `CLAUDE.md` symlink, `.claude/settings.json`, `.github/copilot-instructions.md`, `docs/plans/` |
| 0.3  | Move `plans/scope-plugin-handoff.md` to `docs/design/scope-plugin-handoff.md`, preserved verbatim as the source brainstorm                                                   |
| 0.4  | Write ADRs 0001 through 0012 under `docs/adr/`, capturing the settled reasoning and the findings above                                                                       |
| 0.5  | Build skeleton: `build.zig`, `build.zig.zon`, `tools/normalize-clap-headers.zig`, and a `src/main.zig` carrying the validated smoke test                                     |
| 0.6  | `cmake/CMakeLists.txt` plus the small `cmake/entry.cpp` shim wiring `make_clapfirst_plugins` for CLAP, AUV2, and STANDALONE                                                  |
| 0.7  | Run `set-up-ci` with `runs-on: macos-latest` and `run-cross-compile: false`. The default `ubuntu-latest` cannot link Apple frameworks                                        |
| 0.8  | Run `set-up-linters` and `set-up-secret-scanning`. Already available locally: `actionlint`, `shellcheck`, `shfmt`, `typos`, `vale`, `gitleaks`, `trufflehog`                 |
| 0.9  | Run `add-community-files` for `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `.github/SECURITY.md`, and a PR template                                                              |
| 0.10 | Wire `zig build validate-shaders` into `zig build test`, piping each shader through `metal -fsyntax-only` and skipping with a warning when the toolchain is absent           |

Commits are grouped per step so the history reads as discrete, reviewable units.

**Exit criteria:** `zig build` succeeds, `zig fmt --check` is clean, CI is green on `macos-latest`, and secret scanning reports nothing.

## Phase 1: walking skeleton

**Goal:** a plugin that loads and renders a dim cleared drawable. This proves the whole CLAP plus Objective-C plus wrapper chain end to end so it never needs debugging again.

1. Static library exporting `fosforo_clap_init`, `fosforo_clap_deinit`, and `fosforo_clap_get_factory`.
2. Minimal CLAP plugin: descriptor, stereo `audio-ports`, pass-through `process`, `state`, `log`.
3. clap-wrapper integration producing the `.component` and the standalone app.
4. CLAP GUI extension: create an `NSView` hosting a `CAMetalLayer` and graft it onto the host's parent view. The anonymous union member is `unnamed_0`, which is toolchain-generated and must be re-verified after any Zig upgrade.
5. `CVDisplayLink` render loop clearing to a dim color, skipping the frame cleanly when the next drawable returns nil.

**Exit criteria:** loads in REAPER and Logic and standalone; `clap-validator` and `auval` pass; open, close, and resize during playback are clean.

## Phase 2: signal path

**Goal:** a visible trace that follows audio.

1. Lock-free circular history buffer: single monotonic write cursor, release on publish, acquire on read. Capacity on the order of a second so the producer cannot realistically lap the consumer, which makes a seqlock retry loop unnecessary.
2. Audio-thread tap handed a fixed-buffer allocator sized at `activate` time, so "does the audio path touch the heap" becomes a fact about the call graph rather than a convention that was hopefully honored.
3. Render thread reads a trailing window relative to an acquire load of the cursor.
4. Crude aliased single trace, no persistence.

**Exit criteria:** the trace tracks audio, and `process` performs no allocation, lock, or syscall.

## Phase 3: the phosphor renderer

**Goal:** the moat. Sequenced so every step is independently visible and yields a better screenshot.

1. Define the renderer seam (ADR 0005) before writing any Metal behind it.
2. Persistent `RGBA16F` accumulation texture with ping-pong decay. Floating point is required because an 8-bit alpha blend toward black stalls once values round back to the same integer, leaving permanent ghost trails that never clear.
3. Frame-rate-independent decay: exponential in real elapsed time, so the look is identical at 60 Hz, 120 Hz, or variable refresh.
4. Beam as geometry: each inter-sample segment expands into an oriented quad shaded by perpendicular distance from the centerline, giving analytic antialiasing independent of MSAA.
5. **Velocity-weighted intensity.** Deposited brightness per unit length is inversely proportional to segment screen-length. This single relationship produces the entire characteristic look, and it is the step where the render stops looking like a plot: a kick's slow sub-tail glows solid while its sharp click smears dim, which is exactly the information worth foregrounding.
6. Bandlimited reconstruction: polyphase upsampling before geometry, so the beam follows the true continuous curve and intersample overshoots become visible.
7. Tonemap pass plus palette lookup into an sRGB drawable, producing an emergent white-hot core inside a colored bloom without ever drawing a core explicitly.
8. Resize mailbox. This is the one genuine threading seam: the GUI resize callback arrives on the host main thread and must reallocate textures the render thread is actively using. A pending-resize flag serviced at the top of the render tick avoids a use-after-free that would otherwise surface only when a user drags the window during playback.
9. Shader hot-reload in debug builds, which is the payoff for choosing runtime compilation.

**Exit criteria:** looks like hardware; stable under resize, sample-rate change, and multiple instances.

## Phase 4: triggering

**Goal:** the place where a software scope beats a hardware one. A hardware scope triggers on a voltage threshold because that is all it has; a plugin knows the host transport.

1. Free-run and threshold trigger as the baseline.
2. Host-transport-locked sweep: trigger per bar, quarter, or sixteenth with an adjustable offset, so periodic material stands still and a kick can be watched evolving across many bars.
3. Transient-detection trigger via envelope derivative or spectral flux. Necessary because a sub-heavy kick crosses zero several times before its transient, which defeats a threshold trigger.
4. Pitch-locked sweep: detect the fundamental and set the sweep period to an integer multiple, freezing a sustained bass into a stable waveform.
5. Parameters and state save/load covering every trigger mode.

## Phase 5: measurement and interaction

1. Mouse input through the CLAP GUI and `NSView`, with droppable cursors giving time and amplitude deltas.
2. Musically literate readouts: a time delta expressed simultaneously in milliseconds, samples, degrees of phase at a reference frequency, and note values at project tempo. The phase reading is the number that actually matters for low-end work, where near 50 to 70 Hz a 2 ms offset is nearly a quarter cycle, the difference between reinforcement and partial cancellation.
3. Resizable and full-screen vector interface; snapshot layers to freeze and overlay against the live signal.
4. Text rendering via a comptime-baked signed-distance-field atlas, which keeps resizability resolution-independent by construction rather than requiring bitmap assets at several densities.

## Phase 6: ship v0.1.0

1. Preset and state round-tripping; GUI polish.
2. Code signing and notarization, plus a documented Gatekeeper path for users building from source.
3. Release automation via the `release` skill, GitHub Releases, screenshots, and documentation.

## Explicitly deferred

Recorded so these read as deliberate omissions rather than oversights:

- Multi-instance kick and bass alignment sharing a playhead clock, with overlaid traces and a live cross-correlation offset finder. This is the most differentiated idea in the handoff and the strongest candidate for the phase after v0.1.0.
- Family B lenses: delay-embedding phase-space attractor, constant-Q with reassignment or synchrosqueezing, aligned statistical density and eye diagrams, scrub-anywhere record, waterfall.
- Stereo monitoring: banded correlation-history plot and X-Y vectorscope.
- AUv3, iPad, VST3, AAX, Windows and Linux backends, Intel Mac binaries.

## Risks

| Risk                                                                              | Mitigation                                                                                  |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| CMake 4.4 rejects dependencies declaring `cmake_minimum_required` below 3.5      | clap-wrapper declares 3.21 and AudioUnitSDK 1.1.0 is modern. Escape hatch: `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` |
| Zig `translate-c` `#pragma once` bug                                             | Normalization step in `tools/`. Worth reporting upstream, though `ziglang/zig` is not your repository |
| Toolchain-generated names such as `unnamed_0` shift across Zig versions          | Comptime `@sizeOf` and `@offsetOf` assertions on every struct crossing the ABI               |
| Zig 0.16 is recent and most third-party audio code predates it                   | Minimal dependency surface: only CLAP headers and `zig-objc`, both verified on 0.16          |
| Linking a Zig static archive from CMake is unproven here                         | Validate in Phase 1 step 3, before any renderer work depends on it                           |

## Verification

| Layer      | Check                                                                                |
| ------------ | -------------------------------------------------------------------------------------- |
| Build      | `zig build` produces `Fosforo.clap`; `zig fmt --check` clean                          |
| Bindings   | Comptime `@sizeOf` and `@offsetOf` assertions for every CLAP struct crossing the ABI  |
| Shaders    | `zig build validate-shaders` pipes each shader through `metal -fsyntax-only`          |
| Plugin     | `clap-validator validate` passes                                                      |
| Audio Unit | `auval -v aufx <subtype> <manufacturer>` passes                                       |
| Hosts      | Loads in REAPER, Logic Pro, and standalone; open, close, resize during playback       |
| Real-time  | Debug-build assertion that `process` performs no allocation                            |
| CI         | Green on `macos-latest`; gitleaks and TruffleHog clean                                |

## Items to confirm during execution

- **Product name rendering.** Repository and binary stay ASCII `fosforo`; the display name should be **Fósforo**, which is both the correct AO90 spelling and a direct nod to the phosphor renderer.
- **AUv2 four-character codes.** Manufacturer and subtype codes plus manufacturer name, or implement the CLAP AUv2 extension and let clap-wrapper probe the plugin for them.
- **Repository visibility.** The plan assumes public. Confirm before the first push, since it also determines whether GitHub Actions minutes are free (they are, for public repositories on standard runners).
