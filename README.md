# fosforo

A Mac-first GPU-rendered phosphor oscilloscope and signal-analysis plugin, authored as a CLAP and rendered with Metal.

## Status

Early development, and not yet worth installing unless you are working on it. No release has been cut.

What works: the plugin loads in REAPER and in Logic Pro, through the Audio Unit that [clap-wrapper](https://github.com/free-audio/clap-wrapper) projects it into. It passes stereo audio through unchanged, saves and restores its state, and taps one channel into a lock-free history buffer the render thread reads a trailing window from. It opens a resizable editor backed by a `CAMetalLayer` and renders into it at vsync, driven by a `CVDisplayLink`.

What does not work yet: **the trace.** The audio reaches the GPU and no shader draws it, so the editor is a dim, uniform rectangle. That is the work in progress ([#38](https://github.com/cboone/fosforo/issues/38)), and it is the last step of phase 2.

## Roadmap

Six phases. [The build plan](./docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md) holds the reasoning, the sequencing and the exit criteria for each; [the design brainstorm](./docs/design/scope-plugin-handoff.md) is the background it came from. Issues are filed one phase at a time, so a phase marked planned deliberately has none yet.

| Phase | Scope                                                                       | Status      |
|-------|-----------------------------------------------------------------------------|-------------|
| 0     | Repository foundation, build skeleton, ADRs                                 | Complete    |
| 1     | Walking skeleton: loads in a host and renders a cleared drawable            | Complete    |
| 2     | Signal path: history buffer, audio tap, trailing-window read, a crude trace | In progress |
| 3     | The phosphor renderer: accumulation, decay, beam geometry, tonemap          | Planned     |
| 4     | Triggering, including host-transport-locked and pitch-locked sweeps         | Planned     |
| 5     | Measurement and interaction: cursors, musically literate readouts           | Planned     |
| 6     | Ship v0.1.0                                                                 | Planned     |

Deferred past v0.1.0 by [ADR 0012](./docs/adr/0012-phosphor-oscilloscope-first.md): multi-instance kick and bass alignment, the stereo lenses, and the rest of the analyzer family. [ADR 0011](./docs/adr/0011-auv2-first.md) defers AUv3, VST3, AAX and a standalone build; [ADR 0001](./docs/adr/0001-mac-first-apple-silicon.md) rules out Windows, Linux and Intel Macs.

## Requirements

- macOS on Apple Silicon
- [Zig](https://ziglang.org/) 0.16.0 (pinned; see `build.zig.zon`)
- Xcode, for the Apple frameworks and SDK
- CMake 3.21 or newer, only if building the Audio Unit for Logic
- The Metal toolchain, only for `zig build validate-shaders`. Shaders compile at runtime from embedded source, so the build itself never needs it ([ADR 0009](./docs/adr/0009-runtime-shader-compilation.md))

## Installation

Build from source:

```bash
git clone https://github.com/cboone/fosforo.git
cd fosforo
zig build --release=fast
```

Install the CLAP for any CLAP-capable host (REAPER, Bitwig). This builds it, copies it into `~/Library/Audio/Plug-Ins/CLAP`, and prints the hash of what landed, so the build a host loads can be told apart from the build you just made:

```bash
zig build install-clap
```

Logic Pro loads only Audio Units, so it additionally needs the AUv2 build produced through [clap-wrapper](https://github.com/free-audio/clap-wrapper). This one command builds and installs both bundles, and is much slower, because CMake fetches the AudioUnit SDK:

```bash
zig build install-plugins
```

## Usage

Insert it on a track as you would any analyzer: it passes audio through unchanged, so it can sit anywhere in a chain without altering the signal. Open its editor and it renders, resizably, at your display's refresh rate.

There is nothing to read in it yet, for the reason in the status above. Until [#38](https://github.com/cboone/fosforo/issues/38) lands, a working editor and a broken one look alike — the background is `RGB(5, 5, 8)`, which is a phosphor screen's unlit state and also, by eye, black. A debug build emits a once-a-second `rendering at N Hz` line, which is the check that distinguishes them. It reaches the host through `clap.log`, and REAPER implements that extension and then discards what it receives, so the copy you can actually read is the one debug builds mirror to `stderr`: launch REAPER from a terminal. A release build compiles out both that mirror and the meter behind it, so nothing reports there.

## License

[MIT License](./LICENSE). TL;DR: Do whatever you want with this software, just keep the copyright notice included. The authors aren't liable if something goes wrong.
