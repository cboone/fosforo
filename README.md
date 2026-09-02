# fosforo

A Mac-first GPU-rendered phosphor oscilloscope and signal-analysis plugin, authored as a CLAP and rendered with Metal.

## Status

Early development, and not yet worth installing unless you are working on it. No release has been cut.

What works: the plugin loads in REAPER and in Logic Pro, through the Audio Unit that [clap-wrapper](https://github.com/free-audio/clap-wrapper) projects it into. It passes stereo audio through unchanged, saves and restores its state, and taps one channel into a lock-free history buffer the render thread reads a trailing window from. It opens a resizable editor backed by a `CAMetalLayer` and renders into it at vsync, driven by a `CVDisplayLink`. **It draws the signal**, as a beam depositing energy into a persistent floating-point accumulation texture that decays between frames, so the trace glows and fades rather than being redrawn from nothing. The fade is exponential in real elapsed time against a time constant, so it looks the same at 60 Hz, at 120, and on a display that drifts between the two. The beam is real geometry: each inter-sample segment is a quad shaded by its distance from the beam's path, three points wide, with an intensity profile and antialiasing that come from the profile rather than from multisampling.

What does not work yet: the beam's brightness does not vary with how fast it sweeps, and the trace follows the samples rather than the continuous waveform between them, so intersample peaks are invisible. Those are the rest of [phase 3](https://github.com/cboone/fosforo/milestone/3), and each is an issue.

## Roadmap

Six phases. [The build plan](./docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md) holds the reasoning, the sequencing and the exit criteria for each; [the design brainstorm](./docs/design/scope-plugin-handoff.md) is the background it came from. Issues are filed one phase at a time, so a phase marked planned deliberately has none yet.

| Phase | Scope                                                                       | Status      |
| ----- | --------------------------------------------------------------------------- | ----------- |
| 0     | Repository foundation, build skeleton, ADRs                                 | Complete    |
| 1     | Walking skeleton: loads in a host and renders a cleared drawable            | Complete    |
| 2     | Signal path: history buffer, audio tap, trailing-window read, a crude trace | Complete    |
| 3     | The phosphor renderer: accumulation, tonemap, decay, beam geometry          | In progress |
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

Install the CLAP for any CLAP-capable host (REAPER, Bitwig). This builds it, copies it into `~/Library/Audio/Plug-Ins/CLAP`, and prints the hash and the branch it came from, so the build a host loads can be told apart from the build you just made:

```bash
zig build --release=fast install-clap
```

Logic Pro loads only Audio Units, so it additionally needs the AUv2 build produced through [clap-wrapper](https://github.com/free-audio/clap-wrapper). This one command builds and installs both bundles, and is much slower, because CMake fetches the AudioUnit SDK:

```bash
zig build --release=fast install-plugins
```

`--release=fast` has to be repeated on each of those, because every `install-*` step builds what it installs and a plain `zig build` is a Debug build. Installing Debug is a reasonable thing to want while there is nothing to look at yet, since the render meter described below is compiled out of a release build, but it should be something you chose rather than something the flag's absence did quietly.

## Usage

Insert it on a track as you would any analyzer: it passes audio through unchanged, so it can sit anywhere in a chain without altering the signal. Open its editor and it renders, resizably, at your display's refresh rate.

There is a trace to look at now, and looking at it is still not the check. A trace stuck flat at zero looks correct against silence, and a window that froze several seconds ago looks identical to a live one against steady material, so "I can see a waveform" separates neither case from a working editor. Two things do: stop the transport and confirm the trace goes flat within a frame or two, and count periods against the 20 ms the window holds rather than judging the shape. On an empty display the background is `RGB(5, 5, 8)`, a phosphor screen's unlit state and, by eye, black.

A debug build also emits a once-a-second `rendering at N Hz` line, which is the only positive statement that frames are being presented. It reaches the host through `clap.log`, and REAPER implements that extension and then discards what it receives, so the copy you can actually read is the one debug builds mirror to `stderr`: launch REAPER from a terminal. A release build compiles out both that mirror and the meter behind it, so nothing reports there.

## License

[MIT License](./LICENSE). TL;DR: Do whatever you want with this software, just keep the copyright notice included. The authors aren't liable if something goes wrong.
