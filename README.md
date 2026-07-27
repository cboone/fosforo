# fosforo

A Mac-first GPU-rendered phosphor oscilloscope and signal-analysis plugin, authored as a CLAP and rendered with Metal.

## Status

Early development. Nothing is usable yet. See [the build plan](./docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md) for scope and sequencing, and [the design brainstorm](./docs/design/scope-plugin-handoff.md) for background.

## Requirements

- macOS on Apple Silicon
- [Zig](https://ziglang.org/) 0.16.0 (pinned; see `build.zig.zon`)
- Xcode, for the Apple frameworks and SDK
- CMake 3.21 or newer, only if building the Audio Unit for Logic

## Installation

Build from source:

```bash
git clone https://github.com/cboone/fosforo.git
cd fosforo
zig build -Doptimize=ReleaseFast
```

Install the CLAP for any CLAP-capable host (REAPER, Bitwig):

```bash
cp -R zig-out/Fosforo.clap ~/Library/Audio/Plug-Ins/CLAP/
```

Logic Pro loads only Audio Units, so it additionally needs the AUv2 build produced through [clap-wrapper](https://github.com/free-audio/clap-wrapper):

```bash
cmake -B build cmake/ && cmake --build build
```

## Usage

TODO

## License

[MIT License](./LICENSE). TL;DR: Do whatever you want with this software, just keep the copyright notice included. The authors aren't liable if something goes wrong.
