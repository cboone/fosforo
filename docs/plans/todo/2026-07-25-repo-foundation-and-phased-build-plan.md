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
| Zig `translate-c` mishandles `#pragma once` under path aliasing                                         | `clap/factory/../version.h` against `clap/version.h` yields 161 redefinition errors; plain clang is clean | Preprocess with `zig cc -E` before translating                  |
| `clap-wrapper` consumes a **static library**, not a `.clap` dylib                                       | `make_clapfirst_plugins` takes `IMPL_TARGET` plus `ENTRY_SOURCE`             | Inverts the build shape the handoff assumed                     |
| CLAP is at **1.2.10**, MIT licensed                                                                    | `version.h` in `free-audio/clap`                                             | Vendor current rather than 1.2.2                                |
| **Visage is C++-only with no C API**                                                                    | Repository survey                                                            | Prior art only, never a dependency. Question closed             |
| Runtime MSL compilation works from Zig                                                                 | `newLibraryWithSource:` resolved a fragment function                         | Runtime compilation is the single runtime path                  |
| `clap-validator` is **not on crates.io**                                                               | `cargo install clap-validator` fails                                         | Install with `cargo install --git`                              |

The full chain is proven working: `translate-c` over normalized CLAP 1.2.10 headers, `export const clap_entry` emitting `_clap_entry`, Cocoa/Metal/QuartzCore/CoreVideo linking, `objc_msgSend` from Zig including float returns, Metal device acquisition reporting `hasUnifiedMemory: true`, runtime shader compilation, and `metal -fsyntax-only` correctly rejecting a bad shader.

### Environment status

| Tool             | Status                                                                            |
| ------------------ | ----------------------------------------------------------------------------------- |
| Zig 0.16.0       | Installed. Current stable, released 2026-04-13                                    |
| CMake 4.4.0      | Installed. The below-3.5 policy risk did not materialize                          |
| Metal toolchain  | Installed. Needed `xcrun --kill-cache` before `xcrun` would resolve it            |
| REAPER           | Installed. Native CLAP host, so the dev loop needs neither CMake nor a standalone |
| Logic Pro        | Installed. AUv2 only, which is what makes clap-wrapper necessary at all           |
| `clap-validator` | Installed, 0.4.1. Not on crates.io, and needs rustc 1.95+ (`cargo install --git`) |

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

## Phase 0: repository foundation (complete)

| Step | Work                                                                                                                                     | Status |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------ | -------- |
| 0.1  | Install `clap-validator` from git                                                                                                        | Done   |
| 0.2  | Scaffold README, CHANGELOG, `.gitignore`, agent config, `docs/plans/`                                                                    | Done   |
| 0.3  | Move the source brainstorm to `docs/design/scope-plugin-handoff.md`, verbatim                                                            | Done   |
| 0.4  | Write ADRs 0001 through 0012 under `docs/adr/`                                                                                          | Done   |
| 0.5  | Build skeleton: `build.zig`, `build.zig.zon`, `src/main.zig`, `src/clap/c.zig`                                                          | Done   |
| 0.6  | `cmake/CMakeLists.txt` and `cmake/entry.cpp` wiring `make_clapfirst_plugins`                                                            | Done   |
| 0.7  | CI on `macos-latest`, cross-compilation disabled                                                                                        | Done   |
| 0.8  | Secret scanning (gitleaks, TruffleHog) and `.gitleaks.toml`                                                                             | Done   |
| 0.9  | Community files: CONTRIBUTING, code of conduct, security policy, PR template                                                            | Done   |
| 0.10 | `zig build validate-shaders`                                                                                                            | Done   |

Two steps landed differently from how they were planned, both deliberately:

- **0.5 needs no header-rewriting tool.** The plan assumed `tools/normalize-clap-headers.zig` would rewrite CLAP's relative includes. Running the headers through `zig cc -E` first sidesteps the `#pragma once` bug entirely, with no tool to maintain and no mutation of a pinned dependency. The cost is that object-like macros are consumed; the ones that matter are restated and tested in `src/clap/c.zig`. ADR 0004 records this.
- **0.10 is not wired into `zig build test`.** Doing so would make the default test path depend on an on-demand Xcode component, reintroducing exactly the non-hermetic build ADR 0009 exists to prevent. It is a separate step with its own CI job.

**Exit criteria, all met:** `zig build` succeeds; `zig build test` passes; `zig fmt --check` clean; `zig build validate-shaders` passes; `actionlint` clean; gitleaks reports no leaks; and **both** the Zig-built and clap-wrapper-built `.clap` pass `clap-validator` with 3 passed, 0 failed.

Phase 0 also absorbed work scheduled for Phase 1: the CMake integration builds `Fosforo.component` (AUv2) and `Fosforo.clap` end to end, retiring the "linking a Zig static archive from CMake is unproven" risk. Three undocumented clap-wrapper integration requirements were found and are recorded inline in `cmake/CMakeLists.txt`: the consumer must set `CMAKE_OSX_DEPLOYMENT_TARGET` and `CMAKE_CXX_STANDARD`, and must enable `OBJC`/`OBJCXX` in its own project.

## Phase 1: walking skeleton

**Goal:** a plugin that loads and renders a dim cleared drawable. This proves the whole CLAP plus Objective-C plus wrapper chain end to end so it never needs debugging again.

Steps 1 and 3 of the original plan (the static library and the clap-wrapper integration) landed in Phase 0, so what remains is:

1. Plugin factory and descriptor, currently stubbed to return null.
2. Minimal CLAP plugin: stereo `audio-ports`, pass-through `process`, `state`, `log`.
3. CLAP GUI extension: create an `NSView` hosting a `CAMetalLayer` and graft it onto the host's parent view. Reach the parent through `clap.cocoaView()` rather than touching `unnamed_0` directly.
4. `CVDisplayLink` render loop clearing to a dim color, skipping the frame cleanly when the next drawable returns nil.
5. **Narrow the AU sandbox claims.** clap-wrapper's default `resourceUsage` in the generated `AudioComponents` entry claims `network.client` and `temporary-exception.files.all.read-write`. An analyzer needs neither, and overclaiming contradicts the threat model in `.github/SECURITY.md`. It matters for sandboxed hosts and for any future App Store path. Tracked as [issue #1](https://github.com/cboone/fosforo/issues/1).

**Exit criteria:** loads in REAPER and Logic; `clap-validator` reports more than the current 3 passing tests once a factory exists; `auval -v aufx Fsfr Ctmn` passes; open, close, and resize during playback are clean.

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

| Risk                                                                     | Status and mitigation                                                                                    |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Linking a Zig static archive from CMake was unproven                   | **Retired.** Both AUv2 and CLAP build through clap-wrapper and pass `clap-validator`                     |
| CMake 4.4 rejects `cmake_minimum_required` below 3.5                   | **Did not materialize.** Escape hatch if a future dependency trips it: `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` |
| Zig `translate-c` `#pragma once` bug                                   | **Worked around** by preprocessing with `zig cc -E`. Worth reporting upstream, though `ziglang/zig` is not your repository |
| Toolchain-generated names such as `unnamed_0` shift across Zig versions | Comptime `@sizeOf` and `@offsetOf` assertions on every struct crossing the ABI. These already caught one wrong field count |
| Zig 0.16 is recent and most third-party audio code predates it          | Minimal dependency surface: only CLAP headers and `zig-objc`, both verified on 0.16                      |
| clap-wrapper is pinned to an untagged commit                            | `make_clapfirst_plugins` postdates v0.9.1. Move to a tag once one ships containing it                    |
| Three deployment targets must stay in step                              | `build.zig`, `cmake/CMakeLists.txt`, and `macos/Info.plist` all say macOS 11.0. A mismatch shows as a linker warning |

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

- **Product name rendering.** Applied: repository and binary stay ASCII `fosforo`, display name is **Fósforo** in `macos/Info.plist`. Change it there if you disagree.
- **AUv2 four-character codes.** Settled as `Ctmn` (manufacturer) and `Fsfr` (subtype), manufacturer name "Christopher Boone", in `cmake/CMakeLists.txt`. These follow Apple's convention that a manufacturer code must not be all-lowercase, which is reserved (compare Voxengo's `Vxng` and Tokyo Dawn's `Tdrl` against Apple's own `appl`). Treat them as permanent: Logic stores the type/subtype/manufacturer triple in project files, so changing either code after release orphans saved projects. If a second plugin ever ships, move them into the CLAP AUv2 extension so the manufacturer code comes from one shared place.
- **Repository visibility.** Resolved: public. Actions minutes are therefore free on standard runners, macOS included.
- **CI is unverified.** The workflows are lint-clean via `actionlint` but have never executed. Expect the first push to need a fixup, particularly around whether the `macos-latest` runner image already carries the Metal toolchain.
