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

| Finding                                                                                        | Evidence                                                                                                  | Consequence                                                      |
| ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `clap-zig-bindings` is **LGPLv3**, covers CLAP **1.2.2**, and **fails to compile on Zig 0.16** | Cloned; `zig build test` fails on the removed `std.testing.refAllDeclsRecursive`                          | Rejected. The handoff called it "the cleanest binding path"      |
| Zig 0.16 **removed `@Type`**                                                                   | `@Type` reports `invalid builtin function`                                                                | The classic comptime `objc_msgSend` cast pattern no longer works |
| `zig-objc` migrated to the replacement `@Fn`/`@Tuple` builtins, is **MIT**, and passes on 0.16 | Cloned; `zig build test` exits 0                                                                          | Viable dependency, contrary to the handoff's "hand-roll it"      |
| Zig `translate-c` mishandles `#pragma once` under path aliasing                                | `clap/factory/../version.h` against `clap/version.h` yields 161 redefinition errors; plain clang is clean | Preprocess with `zig cc -E` before translating                   |
| `clap-wrapper` consumes a **static library**, not a `.clap` dylib                              | `make_clapfirst_plugins` takes `IMPL_TARGET` plus `ENTRY_SOURCE`                                          | Inverts the build shape the handoff assumed                      |
| CLAP is at **1.2.10**, MIT licensed                                                            | `version.h` in `free-audio/clap`                                                                          | Vendor current rather than 1.2.2                                 |
| **Visage is C++-only with no C API**                                                           | Repository survey                                                                                         | Prior art only, never a dependency. Question closed              |
| Runtime MSL compilation works from Zig                                                         | `newLibraryWithSource:` resolved a fragment function                                                      | Runtime compilation is the single runtime path                   |
| `clap-validator` is **not on crates.io**                                                       | `cargo install clap-validator` fails                                                                      | Install with `cargo install --git`                               |

The full chain is proven working: `translate-c` over normalized CLAP 1.2.10 headers, `export const clap_entry` emitting `_clap_entry`, Cocoa/Metal/QuartzCore/CoreVideo linking, `objc_msgSend` from Zig including float returns, Metal device acquisition reporting `hasUnifiedMemory: true`, runtime shader compilation, and `metal -fsyntax-only` correctly rejecting a bad shader.

### Environment status

| Tool             | Status                                                                            |
| ---------------- | --------------------------------------------------------------------------------- |
| Zig 0.16.0       | Installed. Current stable, released 2026-04-13                                    |
| CMake 4.4.x      | Installed. The below-3.5 policy risk did not materialize                          |
| Metal toolchain  | Installed. Needed `xcrun --kill-cache` before `xcrun` would resolve it            |
| REAPER           | Installed. Native CLAP host, so the dev loop needs neither CMake nor a standalone |
| Logic Pro        | Installed. AUv2 only, which is what makes clap-wrapper necessary at all           |
| `clap-validator` | Installed, 0.4.1. Not on crates.io, and needs rustc 1.95+ (`cargo install --git`) |

## Locked decisions

Each becomes an ADR under `docs/adr/`.

| ADR  | Decision                                                                                                                     |
| ---- | ---------------------------------------------------------------------------------------------------------------------------- |
| 0001 | Mac-first, Apple Silicon primary. One audio-thread contract, one SIMD target, unified memory                                 |
| 0002 | Zig, pinned to 0.16.0 via `minimum_zig_version`. Compiler bumps are scheduled work, never incidental                         |
| 0003 | Author CLAP once; project outward with `clap-wrapper`. Never author AU or VST3 directly                                      |
| 0004 | CLAP bindings via `translate-c` over vendored, normalized headers. Reject `clap-zig-bindings` as copyleft, stale, and broken |
| 0005 | Metal directly, behind a small internal renderer interface. Build one backend; forbid Metal types leaking above the seam     |
| 0006 | Reject a WebView UI. The serializing bridge and borrowed compositor schedule are disqualifying for a measurement instrument  |
| 0007 | Render as a simulation of a physical device: persistent floating-point accumulation, decay, additive trace, tonemap          |
| 0008 | Objective-C glue via `zig-objc`, with the project-local per-arity fallback already proven as a contingency                   |
| 0009 | Runtime MSL compilation is the single runtime path. The Metal toolchain is a validation tool, never a build dependency       |
| 0010 | Lock-free circular history buffer with one monotonic write cursor. Not a queue                                               |
| 0011 | AUv2 first. AUv3, VST3, AAX, and iPad remain later toggles with no bearing on output quality                                 |
| 0012 | First deliverable is the phosphor oscilloscope only. Alignment and Family B lenses are deferred                              |

Five more were decided during execution rather than in this pass, each because a
phase reached a question this plan had not asked. They are listed here so the set
is complete in one place; [`docs/adr/README.md`](../../adr/README.md) is the index.

| ADR  | Decision                                                                                          | Decided in |
| ---- | ------------------------------------------------------------------------------------------------- | ---------- |
| 0013 | The GUI smoke harness is an executable behind its own build steps, never part of `zig build test` | Phase 1    |
| 0014 | Distribute as one signed, notarized, stapled `.pkg` placing both bundles                          | Phase 1    |
| 0015 | Adopt `std.Io` through the single `init_single_threaded` instance in `src/platform/io.zig`        | Phase 2    |
| 0016 | Verify the ring's release/acquire pairing with Thread Sanitizer, plus a source canary             | Phase 2    |
| 0017 | The vertical axis is absolute: no rescaling to the signal, and over-scale rails visibly           | Phase 2    |

## Build architecture

The key structural insight follows from `make_clapfirst_plugins` wanting a static library: build the core **once** as a static archive and give it **two** consumers. CMake then stays off the critical development path entirely.

```text
build.zig
├─ build.zig.zon          pinned: Zig 0.16.0, CLAP 1.2.10, zig-objc
├─ zig cc -E over src/clap/clap_all.h -> translate-c -> module "clap.c"
├─ src/                               core implementation
├─ libfosforo_impl.a                  exports fosforo_clap_{init,deinit,get_factory}
│   ├─ consumer 1: zig build          -> Fosforo.clap        (fast loop, REAPER, no CMake)
│   └─ consumer 2: cmake/             -> clap-wrapper
│                                        ├─ Fosforo.clap       (the same plugin, wrapper entry)
│                                        ├─ Fosforo.component  (AUv2, for Logic)
│                                        └─ Fosforo.app        (standalone, provisional)
```

Two lines changed after this was written and both are worth reading as they now
stand. **`tools/normalize-clap-headers.zig` was never built**, for the reason
Phase 0 step 0.5 records below: preprocessing with `zig cc -E` sidesteps the
`#pragma once` bug with no tool to maintain. And **`Fosforo.app` is provisional
rather than pending**: `cmake/CMakeLists.txt` sets `FOSFORO_FORMATS` to `CLAP`
and `AUV2` only, and ADR 0011 files the standalone with AUv3, VST3 and AAX as a
later clap-wrapper toggle. CMake builds a second `.clap` beside the component,
which was not anticipated here and which CI validates alongside the Zig-built
one.

Because REAPER loads a raw `.clap`, `zig build` alone drives the entire day-to-day loop. CMake is invoked only when the Audio Unit for Logic is needed, which keeps a C++ build system off the path where iteration speed matters.

### Source layout

What exists today, which is the layout to build on:

```text
src/
  main.zig              the host-facing boundary and exported entry points
  smoke.zig             the out-of-band GUI smoke harness (ADR 0013)
  ring_race.zig         the two-thread race harness (ADR 0016)
  clap/
    c.zig               translated CLAP ABI plus comptime layout assertions
    clap_all.h          the header set fed through `zig cc -E`
    plugin.zig          factory, descriptor, lifecycle, audio ports, process
    gui.zig             the editor's lifecycle, the resize mailbox, the tick
    state.zig           the versioned save/load format
    log.zig             diagnostics routed through the host's clap.log
  dsp/
    ring.zig            lock-free history buffer
  gpu/
    iface.zig           THE SEAM: size, upload, resize, frame, present.
                        No Metal types above this
    measure.zig         reads a rendered trace back as numbers; pure, no GPU
    metal/renderer.zig  device, pipeline, surface, one frame
  platform/
    io.zig              the one std.Io instance (ADR 0015)
    objc.zig            Core Graphics types and the thread assertions
    view.zig            the NSView the host embeds
    displaylink.zig     CVDisplayLink and its monotonic clock
```

The extensions are flat files rather than a `clap/ext/` directory, and there are
three of them rather than five: `audio-ports`, `state` and `gui`. Those are the
three `getExtension` answers to, which is what "extension" counts as here.
`log.zig` is not a fourth, and the direction is the reason: `clap.log` is a
*host* extension, fetched from `clap_host.get_extension` and consumed, so that
file is a caller of someone else's interface rather than an implementer of one
of ours. `params` is Phase 4 step 5, which is what gives it something to
declare.

**Provisional, and named here only so the eventual home is not re-argued.** Each
arrives with the phase that has a caller for it, on the same rule
[`src/gpu/iface.zig`](../../../src/gpu/iface.zig) states for the seam's own
operations:

```text
src/dsp/
  decimate.zig          min/max decimation (@Vector)          — phase 3 step 4
  resample.zig          polyphase bandlimited interpolation   — phase 3 step 6
  trigger.zig           threshold, transient, pitch, transport — phase 4
```

## Phase 0: repository foundation (complete)

| Step | Work                                                                           | Status |
| ---- | ------------------------------------------------------------------------------ | ------ |
| 0.1  | Install `clap-validator` from git                                              | Done   |
| 0.2  | Scaffold README, CHANGELOG, `.gitignore`, agent config, `docs/plans/`          | Done   |
| 0.3  | Move the source brainstorm to `docs/design/scope-plugin-handoff.md`, verbatim  | Done   |
| 0.4  | Write ADRs 0001 through 0012 under `docs/adr/`                                 | Done   |
| 0.5  | Build skeleton: `build.zig`, `build.zig.zon`, `src/main.zig`, `src/clap/c.zig` | Done   |
| 0.6  | `cmake/CMakeLists.txt` and `cmake/entry.cpp` wiring `make_clapfirst_plugins`   | Done   |
| 0.7  | CI on `macos-latest`, cross-compilation disabled                               | Done   |
| 0.8  | Secret scanning (gitleaks, TruffleHog) and `.gitleaks.toml`                    | Done   |
| 0.9  | Community files: CONTRIBUTING, code of conduct, security policy, PR template   | Done   |
| 0.10 | `zig build validate-shaders`                                                   | Done   |

Two steps landed differently from how they were planned, both deliberately:

- **0.5 needs no header-rewriting tool.** The plan assumed `tools/normalize-clap-headers.zig` would rewrite CLAP's relative includes. Running the headers through `zig cc -E` first sidesteps the `#pragma once` bug entirely, with no tool to maintain and no mutation of a pinned dependency. The cost is that object-like macros are consumed; the ones that matter are restated and tested in `src/clap/c.zig`. ADR 0004 records this.
- **0.10 is not wired into `zig build test`.** Doing so would make the default test path depend on an on-demand Xcode component, reintroducing exactly the non-hermetic build ADR 0009 exists to prevent. It is a separate step with its own CI job.

**Exit criteria, all met:** `zig build` succeeds; `zig build test` passes; `zig fmt --check` clean; `zig build validate-shaders` passes; `actionlint` clean; gitleaks reports no leaks; and **both** the Zig-built and clap-wrapper-built `.clap` pass `clap-validator` with 3 passed, 0 failed.

Phase 0 also absorbed work scheduled for Phase 1: the CMake integration builds `Fosforo.component` (AUv2) and `Fosforo.clap` end to end, retiring the "linking a Zig static archive from CMake is unproven" risk. Three undocumented clap-wrapper integration requirements were found and are recorded inline in `cmake/CMakeLists.txt`: the consumer must set `CMAKE_OSX_DEPLOYMENT_TARGET` and `CMAKE_CXX_STANDARD`, and must enable `OBJC`/`OBJCXX` in its own project.

## Phase 1: walking skeleton (complete)

**Goal:** a plugin that loads and renders a dim cleared drawable. This proves the whole CLAP plus Objective-C plus wrapper chain end to end so it never needs debugging again.

Steps 1 and 3 of the original plan (the static library and the clap-wrapper integration) landed in Phase 0, so what remained was tracked as issues under the [Phase 1 milestone](https://github.com/cboone/fosforo/milestone/1), all five now closed:

| Issue                                            | Work                                                                      | Status |
| ------------------------------------------------ | ------------------------------------------------------------------------- | ------ |
| [#2](https://github.com/cboone/fosforo/issues/2) | Plugin factory and descriptor. **Chooses the permanent CLAP plugin `id`** | Done   |
| [#3](https://github.com/cboone/fosforo/issues/3) | Stereo `audio-ports`, pass-through `process`, `state`, `log`              | Done   |
| [#4](https://github.com/cboone/fosforo/issues/4) | CLAP GUI extension: `NSView` hosting a `CAMetalLayer`                     | Done   |
| [#5](https://github.com/cboone/fosforo/issues/5) | `CVDisplayLink` render loop and the resize seam                           | Done   |
| [#1](https://github.com/cboone/fosforo/issues/1) | Narrow the over-broad AU sandbox `resourceUsage` claims                   | Done   |

**Exit criteria:** loads in REAPER and Logic; `clap-validator` reports more than the current 3 passing tests once a factory exists; `auval -v aufx Fsfr Ctmn` passes; open, close, and resize during playback are clean.

Met, with one criterion retired rather than satisfied:

| Criterion                           | Result                                                                                                                                                                                                                                     |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Loads in REAPER and Logic           | Passed in both, and the Audio Unit's first presented frame was confirmed by sampling a pixel rather than by eye                                                                                                                            |
| `clap-validator` beyond 3 tests     | 21 passed, 0 failed, against **both** bundles in CI                                                                                                                                                                                        |
| `auval -v aufx Fsfr Ctmn`           | **Retired as untestable.** `auval` and `AudioComponentFindNext` enumerate only Apple's built-in components on this OS, while Logic sees the plugin. A null result there is not evidence, so loading in Logic is the check that replaced it |
| Open, close, resize during playback | Passed in REAPER 7.78, after exposing three defects: a `u32` dimension that had wrapped past zero, an Audio Unit that never started its display link, and a view and drawable that disagreed without `Editor.pushBack`                     |
| No dropouts with several instances  | Passed in Logic: 15 instances, every editor open, 64-sample buffer, no System Overload                                                                                                                                                     |

**One path shipped unverified and is tracked as [#34](https://github.com/cboone/fosforo/issues/34).** The development machine has a single display, so `viewDidChangeBackingProperties` and `DisplayLink.setDisplay` have never executed. Neither failure is dangerous, both are quality defects a second monitor surfaces immediately, and neither is reachable from `zig build test` or `src/smoke.zig`. It stays a manual check, filed so it does not decay into an assumed pass.

### How work is tracked

This document holds the reasoning, architecture, and sequencing. GitHub issues hold actionable units, one milestone per phase.

Issues are filed **just in time**, for whichever phase is next, rather than up front for all six. Phases 4 onward deliberately have no issues yet: ADR 0012 defers those decisions until the phosphor scope ships and gets reassessed, and filing them now would manufacture a backlog of choices that have not been made. File a phase's issues when it becomes the next phase, and link them back here.

Phase 2's issues were filed on that rule when phase 1 closed, and phase 3's when phase 2 closed. Phase 4's are not filed and should not be until phase 3 closes.

**Seven open issues sit on no milestone, and that is deliberate.** None of them
is a step of any phase, so putting one on a milestone would misreport that
phase's remaining work.

**Two are carried in the risks table below instead**, which is where a reader who
does not open the tracker will find them:
[#34](https://github.com/cboone/fosforo/issues/34) is verification debt from
phase 1, and [#30](https://github.com/cboone/fosforo/issues/30) is certificate
maintenance for a release that is several phases out.

**The other five arrived while phase 3 was under way, and are deferred questions
rather than risks to this plan**, which is why they are not in that table.
[#51](https://github.com/cboone/fosforo/issues/51) and
[#65](https://github.com/cboone/fosforo/issues/65) are verification the phase
wanted and could not close in place: the first because nothing here answers what
the pixels became, the second because the evidence points at Logic rather than at
this project. **#51 is done**, as `zig build smoke-trace`, a third smoke half
required in CI beside `smoke-gpu`; it landed early rather than at its filed
position because #56, #57, #58 and #60 all want it more than it wants any of
them, and #58 in particular has no other way to be measured at all. [#53](https://github.com/cboone/fosforo/issues/53) is a feature #55
made worth having, since a bypassed plugin keeps drawing the last window it read
with nothing to say the picture is stale. And
[#69](https://github.com/cboone/fosforo/issues/69) and
[#72](https://github.com/cboone/fosforo/issues/72) are two questions about the
`smoke` job that #63 split out rather than answered. The working order below
places those last two; the rest slot in wherever their subject does.

## Phase 2: signal path (complete)

**Goal:** a visible trace that follows audio.

1. Lock-free circular history buffer: single monotonic write cursor, release on publish, acquire on read. Capacity on the order of a second so the producer cannot realistically lap the consumer, which makes a seqlock retry loop unnecessary.
2. Audio-thread tap handed a fixed-buffer allocator sized at `activate` time, so "does the audio path touch the heap" becomes a fact about the call graph rather than a convention that was hopefully honored.
3. Render thread reads a trailing window relative to an acquire load of the cursor.
4. Crude aliased single trace, no persistence.

Filed against the [Phase 2 milestone](https://github.com/cboone/fosforo/milestone/2), one issue per step, sequenced so each depends only on the one above it:

| Issue                                              | Step | Work                                                                                                                                                                                                                                                                                                                                                                                                                  | Status |
| -------------------------------------------------- | ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| [#35](https://github.com/cboone/fosforo/issues/35) | 1    | `src/dsp/ring.zig`, the buffer alone with no caller. The only part of the phase needing no GPU, no window, and no host, which is why it is separate                                                                                                                                                                                                                                                                   | Done   |
| [#36](https://github.com/cboone/fosforo/issues/36) | 2    | `process` writes the tapped **left output** channel into the ring. Sized in `activate` from the sample rate and freed in `deactivate` as this landed; #37 moved both to `create` and `destroy`, for the reason in its row below                                                                                                                                                                                       | Done   |
| [#37](https://github.com/cboone/fosforo/issues/37) | 3    | The trailing-window read in `Editor.tick`, a per-frame buffer ring behind the seam, and `upload` on `gpu/iface.zig`. **Resolved the `deactivate` race by giving the ring the instance's lifetime**, since a host may deactivate with the editor open and no gate covers that path; capacity is a fixed constant as a consequence. Raw samples cross the seam rather than a vertex format, which phase 3 would replace | Done   |
| [#38](https://github.com/cboone/fosforo/issues/38) | 4    | The trace itself: a line strip in `shaders/scope.metal`, drawn over the existing clear. **Settled the vertical axis as [ADR 0017](../../adr/0017-absolute-vertical-axis.md):** fixed and absolute, with over-scale railed rather than rescaled or clipped away                                                                                                                                                        | Done   |

**All four steps are written and the phase is closed.** A sample tapped on the
audio thread reaches a per-frame `MTLBuffer` bound as a vertex argument, and
`trace_vertex` reads it: `shaders/scope.metal` encodes the background and the
trace over it as two passes in one render pass. The exit criterion is a
statement about a picture rather than about code, so it was closed by a host
procedure rather than by a build, and what that procedure found is under
**Exit criteria** below.

[#45](https://github.com/cboone/fosforo/issues/45) was raised while the editor
was still a uniform dim rectangle, and closed as subsumed by #38. It observed
that the clear colour lands in the drawable as `RGB(5, 5, 8)` and is therefore
indistinguishable from a black window by eye, which makes every check of the
editor an instrumented one. The trace is what answers that, so the colour did
not have to. It does not retire the instrumented checks: a trace stuck flat at
zero and a window frozen seconds ago both survive being looked at.

**Two mechanisms this phase needs already exist,** built ahead of their caller in phase 1, and the issues say so explicitly to stop them being rebuilt:

- **The real-time allocation discipline.** `activate` already allocates `Instance.scratch`, `deactivate` frees it, and `process` already wraps it in a `FixedBufferAllocator`, hands that down, and asserts `fba.end_index == 0`. `passThrough` already takes an allocator it does not use, so the call graph proves the property rather than a comment claiming it. What is stubbed is `scratchBytes`, which returns 0 because nothing downstream needs scratch yet. Step 2 is therefore about *using* this path, not creating it.
- **The in-flight frame semaphore.** [#5](https://github.com/cboone/fosforo/issues/5) put the ring of per-frame dynamic buffers out of scope on the grounds that there was nothing dynamic to buffer until this phase, and that the semaphore is what this phase would find already in place. Step 3 is that caller arriving.

**Two open chores are folded into this phase** rather than left to drift, both moved onto the milestone:

| Issue                                              | Work                                                                   | Status | Why here                                                                                                                                                                                                                                                                                                                                                                   |
| -------------------------------------------------- | ---------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [#22](https://github.com/cboone/fosforo/issues/22) | Make dev builds identifiable and stop worktrees overwriting each other | Open   | This is the first phase whose results can only be judged in a running host, which is exactly where an ambiguous installed build does damage. It has already voided two verification runs, and nearly voided a third: verifying #37 in Logic found a two-week-old Audio Unit installed from another branch, which [#43](https://github.com/cboone/fosforo/issues/43) covers |
| [#29](https://github.com/cboone/fosforo/issues/29) | Decide how to handle the primitives Zig 0.16 moved behind `std.Io`     | Done   | The issue predicts a fourth local workaround will be added by whoever next needs a timer or a lock. Step 3's `deactivate` race is that moment, so the convention should be settled just before it rather than just after                                                                                                                                                   |

**Exit criteria:** the trace tracks audio, and `process` performs no allocation, lock, or syscall.

**The second was met before this phase began.** `process` wraps `Instance.scratch` in a `FixedBufferAllocator` and asserts it was never drawn from, and `scratchBytes` still returns zero, so the tap's only work is a copy into storage `create` already owns.

**The first is met by [#38](https://github.com/cboone/fosforo/issues/38), automatically as far as anything automated can reach and by hand for the rest.** The harness proves windows are read, uploaded and drawn, and that an editor reopened on a still-activated plugin keeps reading; what it cannot prove is that the picture is the signal, because the drawable is `framebufferOnly` and reading it back would change the shipping renderer, which [ADR 0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md)'s #38 amendment sets out. That gap is closed by the host procedure in that issue's plan, which has been run in full against hash-verified installs in REAPER and Logic. Its results are recorded there, measured out of screenshots rather than judged by eye: the level sweep reads every level back to within a pixel and saturates at the rail, the window stands still at both the refresh rate and its second harmonic, and the tap draws the channel it claims.

Of the two chores folded onto the milestone, [#29](https://github.com/cboone/fosforo/issues/29) landed as [ADR 0015](../../adr/0015-adopt-std-io-single-instance.md) and [#22](https://github.com/cboone/fosforo/issues/22) is still open. Neither is an exit criterion.

**Phase 3's issues are filed**, [#55](https://github.com/cboone/fosforo/issues/55) through [#62](https://github.com/cboone/fosforo/issues/62) on the [Phase 3 milestone](https://github.com/cboone/fosforo/milestone/3). The just-in-time rule above is why they did not exist until now: this phase closing is what permitted them.

## Phase 3: the phosphor renderer (next)

**Goal:** the moat. Sequenced so every step is independently visible and yields a better screenshot.

1. Define the renderer seam (ADR 0005) before writing any Metal behind it.
2. Persistent `RGBA16F` accumulation texture with ping-pong decay. **Done** ([#55](https://github.com/cboone/fosforo/issues/55)). Floating point is required because an 8-bit alpha blend toward black stalls once values round back to the same integer, leaving permanent ghost trails that never clear.
3. Frame-rate-independent decay: exponential in real elapsed time, so the look is identical at 60 Hz, 120 Hz, or variable refresh.
4. Beam as geometry: each inter-sample segment expands into an oriented quad shaded by perpendicular distance from the centerline, giving analytic antialiasing independent of MSAA.
5. **Velocity-weighted intensity.** Deposited brightness per unit length is inversely proportional to segment screen-length. This single relationship produces the entire characteristic look, and it is the step where the render stops looking like a plot: a kick's slow sub-tail glows solid while its sharp click smears dim, which is exactly the information worth foregrounding.
6. Bandlimited reconstruction: polyphase upsampling before geometry, so the beam follows the true continuous curve and intersample overshoots become visible.
7. Tonemap pass plus palette lookup into an sRGB drawable, producing an emergent white-hot core inside a colored bloom without ever drawing a core explicitly.
8. Resize mailbox. **Landed early, in phase 1** ([#5](https://github.com/cboone/fosforo/issues/5)), because the display link introduced the render thread and a resizable editor gave it something to service. Building it against a drawable was much cheaper than retrofitting it around the textures above, which is the whole reason it moved. What remained for this phase was reallocating those textures inside `Renderer.resize`, where the mailbox already delivers the size, and that landed with step 2 in [#55](https://github.com/cboone/fosforo/issues/55): a texture that does not survive a window drag is broken the first time anyone drags one, so the two were not separable. **Done.**
9. Shader hot-reload in debug builds, which is the payoff for choosing runtime compilation.

Filed against the [Phase 3 milestone](https://github.com/cboone/fosforo/milestone/3). Unlike phases 1 and 2, **these are not a chain**: several depend only on #55, and one belongs to no numbered step at all.

| Issue                                              | Step | Work                                                                                                                                                                                                                                                                                                                                                                                    | Status |
| -------------------------------------------------- | ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| [#55](https://github.com/cboone/fosforo/issues/55) | 2, 8 | The ping-pong pair, the decay and resolve passes, and the reallocation in `Renderer.resize` that is step 8's remainder. **Established that a leaked `MTLTexture` is invisible to `leaks` *and* to peak RSS**, so the backend counts its own; and that a resolve gain normalising a stationary trace divides every moving one by ten, found in a host after every automated check passed | Done   |
| [#56](https://github.com/cboone/fosforo/issues/56) | 3    | Decay in real elapsed time. Owns the deferred decision about which clock measures it                                                                                                                                                                                                                                                                                                    | Open   |
| [#57](https://github.com/cboone/fosforo/issues/57) | 4    | Oriented quads. Also re-answers the centre-line half pixel and the edge columns #38 left open, and is the real test of the seam's raw-samples claim                                                                                                                                                                                                                                     | Open   |
| [#58](https://github.com/cboone/fosforo/issues/58) | 5    | Velocity weighting. Depends on #57, since there are no segments before there is geometry                                                                                                                                                                                                                                                                                                | Open   |
| [#59](https://github.com/cboone/fosforo/issues/59) | 6    | Bandlimited reconstruction. Depends on #57, and makes decimation worse rather than better                                                                                                                                                                                                                                                                                               | Open   |
| [#60](https://github.com/cboone/fosforo/issues/60) | 7    | Tonemap, palette, sRGB drawable. Breaks every green-channel measurement #38 established, which is an argument for reworking the tooling in the same change rather than against doing it                                                                                                                                                                                                 | Open   |
| [#61](https://github.com/cboone/fosforo/issues/61) | 9    | Shader hot-reload. Independent of every other step and **worth doing early rather than in this order**, because its value is proportional to how much shader iteration comes after it                                                                                                                                                                                                   | Open   |
| [#62](https://github.com/cboone/fosforo/issues/62) | none | Min/max decimation. Not one of the numbered steps; filed here because two completed plans assign it to this phase and `src/dsp/decimate.zig` has been reserved for it since phase 0                                                                                                                                                                                                     | Open   |

**Exit criteria:** looks like hardware; stable under resize, sample-rate change, and multiple instances.

### Working order, and why the phase runs one issue at a time

**Each issue is one complete piece of work: the code and its verification land together, in one branch and one PR.** No issue is written now and verified later, and no issue is split into halves that land at different times.

That rule earns its place here rather than being process for its own sake, because in this project the verification is where most of the findings come from. #38's level sweep, the stroboscopic standstill and its harmonic, the channel trap, and the measurement establishing that `leaks` cannot see a leaked `MTLBuffer` at all were every one of them produced by verifying rather than by writing. A plan that defers verification defers the findings with it, and then lands the next issue on top of conclusions nobody has checked.

**The consequence is that this phase runs serially, and the dependency graph is not what makes it serial.** Verification belongs to every issue, and almost every issue's verification needs one of two exclusive resources.

| Resource                                                  | Who needs it                                                                                                                                                                                  | Why it serializes                                                                                                                                                                                                                      |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **GPU and window server** (`smoke-appkit`, `smoke-leaks`) | #55's measurement, [#63](https://github.com/cboone/fosforo/issues/63)'s planted leaks                                                                                                         | Two harnesses cannot both open windows and time each other's frames. `smoke-gpu` and `smoke-trace` are exempt: both need a device and neither needs a window. #63 refused the peak-RSS slope that used to be the sharpest form of this |
| **`~/Library/Audio/Plug-Ins/` and a host**                | #55's host verification, [#22](https://github.com/cboone/fosforo/issues/22), [#34](https://github.com/cboone/fosforo/issues/34), [#64](https://github.com/cboone/fosforo/issues/64)'s capture | One location, and the installed bundle belongs to whichever worktree copied last. An install from another worktree silently voids a run in progress                                                                                    |

So two issues cannot be in flight at once, whatever their dependencies would allow. **What still overlaps freely is everything needing neither resource:** compiling, `zig build test`, `zig build validate-shaders`, `smoke-gpu`, `smoke-trace`, documentation, and [#30](https://github.com/cboone/fosforo/issues/30), which touches no code and runs nothing on this machine. `clap-host` is the one lever on the second resource, since it takes an explicit path and therefore reads the worktree rather than the shared install location; it cannot test resizing and is not a load test, so it supplements REAPER and Logic within an issue rather than replacing them or freeing a second issue to run beside one.

Two orderings follow from the rule, and both were reasoned about before it was adopted:

- **[#63](https://github.com/cboone/fosforo/issues/63) landed whole, after #55, and the ordering earned its keep in a way nobody predicted.** The stated reason was that its RSS threshold had to be set against the post-#55 baseline rather than the pre-#55 one. What actually happened is that the post-#55 measurements retired the RSS check altogether: the counter #55 added catches the one defect it was for, and the storage class #55 introduced is invisible to it. Setting the threshold after #55 and not setting it at all were the same decision arrived at from opposite ends. The `smoke-leaks` step did land, at 40 cycles, and the planted-leak work it carried found that the check's class allowlist had never been able to see a plain allocation.
- **[#64](https://github.com/cboone/fosforo/issues/64) also lands after #55**, for the same reason rather than a different one. Committing `measure-trace` could be done today, but the guard fix in the same issue is only acceptance-testable against a trace that actually fades, which does not exist until #55 has landed. Preserving the tool sooner is worth something and is not worth a split; the exposure is a few days against a file that is not otherwise at risk.

Merge order is a separate question from run order, and only two things constrain it. **Every issue here is an ordinary branch off `main`, and none needs another's unfinished work:**

| Constraint                   | Where it applies                                                 | What it actually requires                                                                                         |
| ---------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **Code dependency**          | #56, #57 and #60 need #55; #58 and #59 need #57                  | Wait for the PR to merge, then branch from `main` as usual                                                        |
| **Merge conflict**           | #61 against #55, both rewriting `Pipelines` and `buildPipelines` | Nothing, strictly. Whichever lands second rebases over a rewrite of one struct, so ordering them is a convenience |
| **Machine and install path** | The verification half of #55, #63, #22, #34 and #64              | Do not *run* two issues at the same moment. No effect on what may be branched, reviewed or merged                 |

The resulting order is **#55**, then **#64**, then **#63**, then **#51** — all four done — then **#22**, then **#61**, then **#56**, **#57** and **#60** in whichever order suits, then **#58** and **#59** behind #57. #51 was pulled forward for the same shape of reason as #61: it is independent of every remaining step and every one of them is easier to verify with it than without, and #58's velocity weighting has no other instrument at all. Unlike #61 it also changes what the later issues have to do, since each now has an offscreen check to update rather than only a picture to look at. [#69](https://github.com/cboone/fosforo/issues/69) was split out of #63 and slots in wherever suits, since it touches the same `smoke` job and nothing else; it is the one issue whose cost has to be re-measured rather than assumed, because #63 took that job's step-budget margin from 2.7x to 1.5x. [#72](https://github.com/cboone/fosforo/issues/72) came out of the same split and sits in the same place, and it is a decision rather than a cost: it is what would let `liveAccumulationTextures` fail a build, which today it cannot, since the step carrying it runs under `continue-on-error`. [#34](https://github.com/cboone/fosforo/issues/34) slots in wherever a second display becomes available, since that rather than anything here is what gates it. [#61](https://github.com/cboone/fosforo/issues/61) is deliberately pulled forward from its filed position at step 9: it is independent of every other step, and its value is proportional to how much shader iteration comes after it, which once #55 has landed is five issues' worth.

The subtle entry was [#63](https://github.com/cboone/fosforo/issues/63)'s: its RSS threshold depended on #55's baseline **number** rather than on its code, so it wanted #55 merged before the figure was fixed, while its `smoke-leaks` half depended on nothing. It is now **done**, and the threshold was never set, for the reason two bullets above.

Stacking is available and is deliberately not the recommendation. Branching #57 off #55 before #55 merges would make partial work available to it, at the usual cost: the child's diff is unreadable until the parent lands, and every parent revision forces a rebase. #55's own commits are strictly sequential anyway, so the simpler model wins.

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
2. Code signing and notarization, plus a documented Gatekeeper path for users building from source. **Landed early, in phase 1** ([#20](https://github.com/cboone/fosforo/issues/20), [#24](https://github.com/cboone/fosforo/issues/24), ADR 0014), on the same reasoning that moved the resize mailbox: an unsigned bundle failed `codesign --verify` from the moment there was a bundle, and the three release scripts were cheaper to write beside the signing than to retrofit around a finished plugin. What remains for this phase is the Gatekeeper path itself, and re-issuing the certificates that [#30](https://github.com/cboone/fosforo/issues/30) covers.
3. Release automation via the `release` skill, GitHub Releases, screenshots, and documentation.

## Explicitly deferred

Recorded so these read as deliberate omissions rather than oversights:

- Multi-instance kick and bass alignment sharing a playhead clock, with overlaid traces and a live cross-correlation offset finder. This is the most differentiated idea in the handoff and the strongest candidate for the phase after v0.1.0.
- Family B lenses: delay-embedding phase-space attractor, constant-Q with reassignment or synchrosqueezing, aligned statistical density and eye diagrams, scrub-anywhere record, waterfall.
- Stereo monitoring: banded correlation-history plot and X-Y vectorscope.
- AUv3, iPad, VST3, AAX, Windows and Linux backends, Intel Mac binaries.

## Risks

| Risk                                                                    | Status and mitigation                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linking a Zig static archive from CMake was unproven                    | **Retired.** Both AUv2 and CLAP build through clap-wrapper and pass `clap-validator`                                                                                                                                                                                                                                                                                      |
| CMake 4.4 rejects `cmake_minimum_required` below 3.5                    | **Did not materialize.** Escape hatch if a future dependency trips it: `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`                                                                                                                                                                                                                                                               |
| Zig `translate-c` `#pragma once` bug                                    | **Worked around** by preprocessing with `zig cc -E`. Worth reporting upstream, though `ziglang/zig` is not your repository                                                                                                                                                                                                                                                |
| Toolchain-generated names such as `unnamed_0` shift across Zig versions | Comptime `@sizeOf` and `@offsetOf` assertions on every struct crossing the ABI. These already caught one wrong field count                                                                                                                                                                                                                                                |
| Zig 0.16 is recent and most third-party audio code predates it          | Minimal dependency surface: only CLAP headers and `zig-objc`, both verified on 0.16                                                                                                                                                                                                                                                                                       |
| clap-wrapper is pinned to an untagged commit                            | `make_clapfirst_plugins` postdates v0.9.1. Move to a tag once one ships containing it                                                                                                                                                                                                                                                                                     |
| Three deployment targets must stay in step                              | `build.zig`, `cmake/CMakeLists.txt`, and `macos/Info.plist` all say macOS 11.0. A mismatch shows as a linker warning                                                                                                                                                                                                                                                      |
| `zig-objc` is pinned to a branch tarball, not a tag or commit           | `build.zig.zon` fetches `refs/heads/main` and pins only the content hash, so the hash is the pin and a refetch after an upstream push fails rather than drifting. Move to a tag or commit when upstream cuts one                                                                                                                                                          |
| The Developer ID certificates expire 2027-02-01                         | **Open**, [#30](https://github.com/cboone/fosforo/issues/30). Xcode issued them under the G1 intermediate rather than G2, capping both leaves at their issuer's expiry. Already-signed artifacts are unaffected, since a secure timestamp outlives the certificate; what stops is signing anything new. Re-issue from the developer portal and do not revoke the old pair |
| The cross-display path has never executed                               | **Open**, [#34](https://github.com/cboone/fosforo/issues/34). `viewDidChangeBackingProperties` and `DisplayLink.setDisplay` shipped on code reading alone, because the development machine has one display. Manual, and filed so it does not decay into an assumed pass                                                                                                   |

## Verification

| Layer       | Check                                                                                                                                                            |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Build       | `zig build` produces `Fosforo.clap`; `zig fmt --check` clean                                                                                                     |
| Bindings    | Comptime `@sizeOf` and `@offsetOf` assertions for every CLAP struct crossing the ABI                                                                             |
| Shaders     | `zig build validate-shaders` pipes each shader through `metal -fsyntax-only`. Deliberately not in `zig build test` (ADR 0009)                                    |
| Plugin      | `clap-validator validate` passes for **both** `.clap` bundles, enforced in CI                                                                                    |
| Audio Unit  | **No automated check exists.** `auval` cannot enumerate this component at all, so loading it in Logic is the only test                                           |
| GUI         | `zig build smoke-gpu` is required in CI; `smoke-appkit` runs under `continue-on-error` because a hosted runner may grant no window server (ADR 0013)             |
| Pixels      | `zig build smoke-trace` renders the shipping pipeline into a texture and asserts the mapping, the rail, period counts, the resolve and the decay. Required in CI |
| Leaks       | `zig build smoke-leaks` in CI at 40 cycles and 400 by hand, judging leaked classes and a byte bound, plus the two counters, which count what `leaks` cannot see  |
| Concurrency | `zig build ring-race` runs the ring on two threads under Thread Sanitizer, on Linux; a source canary in `src/dsp/ring.zig` fails `zig build test` too (ADR 0016) |
| Signatures  | `scripts/assert-adhoc-signature` on all three bundles in CI; `scripts/assert-distributable-signature` by hand, since no runner holds a certificate               |
| Shell       | `shfmt -d` and `shellcheck` over every file `shfmt -f` selects, against the profile in `.editorconfig`                                                           |
| Spelling    | `typos` over the whole tree, from its own workflow so no `paths-ignore` can exempt the files it exists to check                                                  |
| Hosts       | Loads in REAPER and Logic Pro; open, close, resize during playback. `clap-host` is the third, manual, and the only one that shows `clap.log`                     |
| Real-time   | A fixed-buffer allocator threaded through `process`, so no allocation is a fact about the call graph rather than a convention                                    |
| CI          | Green on `macos-latest` and `ubuntu-latest`; `clap-validator` clean; gitleaks, TruffleHog and `typos` clean                                                      |

## Items to confirm during execution

- **Product name rendering.** Applied: repository and binary stay ASCII `fosforo`, display name is **Fósforo** in `macos/Info.plist`. Change it there if you disagree.
- **Repository visibility.** Resolved: public. Actions minutes are therefore free on standard runners, macOS included.

## Identifiers: what is permanent and what is not

Worth stating explicitly, because these look interchangeable and are not. Some are load-bearing identity that hosts persist into user project files; the rest are display metadata. Getting the distinction wrong is only discoverable after release, when it is too late.

**Permanent once released.** Changing any of these makes the plugin read as missing in projects that used it, orphaning automation and settings. There is no redirect mechanism.

| Identifier           | Value                   | Where                  | Who persists it                |
| -------------------- | ----------------------- | ---------------------- | ------------------------------ |
| AU type              | `aufx`                  | `cmake/CMakeLists.txt` | Every AU host, including Logic |
| AU subtype           | `Fsfr`                  | `cmake/CMakeLists.txt` | Every AU host, including Logic |
| AU manufacturer code | `Ctmn`                  | `cmake/CMakeLists.txt` | Every AU host, including Logic |
| **CLAP plugin `id`** | `com.catamount.fosforo` | `src/clap/plugin.zig`  | Every CLAP host, e.g. REAPER   |

The CLAP `id` is the CLAP-side equivalent of the AU triple and carries exactly the same permanence. It was settled in phase 1 along with the descriptor, and deliberately rather than incidentally.

Convention is reverse-DNS, which leaves the choice of authority. The value tracks the **Catamount vendor identity** rather than `CFBundleIdentifier` (`com.cboone.fosforo`), because the two answer different questions: the bundle identifier is a code-signing and preferences identity, while the CLAP `id` is product identity as a host records it. Keying the latter to the vendor keeps it stable if the signing identity ever moves, at the cost that the two strings no longer match on sight. Anything comparing them is wrong by construction.

**Sticky, but not project-breaking.** `CFBundleIdentifier` (`com.cboone.fosforo`, in `macos/Info.plist`) is the code-signing and notarization identity and the preferences domain. Changing it after release orphans user preferences and complicates signing, but does not break project reload.

**Free to change.** The AU manufacturer *name* ("Catamount") and the display name ("Fósforo") are metadata. No host keys off them. One caveat: the manufacturer name must keep the `"Vendor: Product"` shape, because hosts split on the colon to group plugins by vendor in their browsers. Every AU surveyed follows this without exception. Hosts may also show a stale name until `~/Library/Caches/AudioUnitCache` is cleared.

- **CI is unverified.** Resolved: the workflows run green on every push, and the `macos-latest` image does carry the Metal toolchain. What the first runs changed is recorded in the completed CI plans under `docs/plans/done/`.
