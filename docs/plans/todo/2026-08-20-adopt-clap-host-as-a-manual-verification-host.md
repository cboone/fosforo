# Adopt clap-host as a manual verification host

Closes [#32](https://github.com/cboone/fosforo/issues/32).

## Context

This project verifies against two hosts and neither one shows what the plugin says about itself. REAPER implements `clap.log`, accepts every message, and discards it, which is why `src/clap/log.zig` mirrors to `stderr` in debug builds and why the standing advice is to launch REAPER from a terminal. Logic cannot be launched from a terminal at all, so even the mirror is unreadable there. The mirror is compiled out of a release build, so today a `--release=fast` plugin has no readable diagnostic channel in any available host.

[`free-audio/clap-host`](https://github.com/free-audio/clap-host) is the CLAP reference host and it routes `clap_host_log.log` into Qt's logging by severity. Adopting it as a **third, manual** verification target gives this project a channel it has never had, and one that exercises the host path rather than the `stderr` mirror. It is explicitly not a build dependency, not a CI step, and not a replacement for anything: it needs Qt6, CMake, Ninja, rtaudio and rtmidi, which is precisely the non-hermetic toolchain ADR 0009 keeps off the build, and ADR 0013 already settles how automated GUI verification happens here.

Intended outcome: the recipe, the invocation, and an accurate statement of what it does and does not cover are written down in `AGENTS.md`, verified by actually running it rather than by reading upstream source.

## Findings that change the issue as written

Checked against upstream source, not assumed.

**The issue's coverage claim is half wrong.** It says clap-host calls none of `set_size`, `adjust_size`, `can_resize`, `get_size`, `set_parent`. In fact `host/plugin-host.cc` calls `canUseGui`, `guiIsApiSupported`, `guiCreate`, `guiGetSize`, `guiSetParent`, `guiSetTransient`, `guiSuggestTitle`, `guiShow`, `guiHide` and `guiDestroy`. The original grep missed them because clap-host drives the plugin through clap-helpers' `PluginProxy`, which renames `gui->set_parent` to `guiSetParent`. The accurate claim is narrower: it never calls `set_size`, `can_resize` or `adjust_size`, which is the host-to-plugin resize direction, and that is why its window is fixed.

**`-p` takes either the bundle directory or the inner binary.** Predicted before running it that the bundle form would fail, on the reasoning that `PluginHost::load` hands the path to `QLibrary`, which is `dlopen` on macOS, and that there is no `Contents/MacOS` handling anywhere in the repository. **That prediction was wrong and both forms work.** The reasoning about `dlopen` was right in isolation: a bare `dlopen` on `Fosforo.clap` fails with `not a file`, confirmed directly. What it missed is that `QLibrary` resolves the bundle itself, which `DYLD_PRINT_LIBRARIES=1` settles by showing dyld mapping `Contents/MacOS/Fosforo`. So the bundle form depends on Qt rather than on anything about the bundle, and the upstream README's example is correct for the wrong-looking reason. Recorded here because the plan asserted the opposite: this is why the step was to run it rather than reason about it.

**Every declared `cmake_minimum_required` is 3.17.** True of clap-host, `clap` and `clap-helpers`, which is above CMake 4's floor of 3.5, so the locally installed CMake 4.4.2 configures without a policy shim.

**Local prerequisites are mostly present.** `cmake` 4.4.2, `qtbase` 6.11.1 and `pkgconf` are installed; `ninja`, `rtaudio` and `rtmidi` are not. `qtbase` is linked into `/opt/homebrew` rather than keg-only and carries both Qt6Core and Qt6Widgets, which is all clap-host asks for, so the upstream README's `brew install qt6` is unnecessary here: that alias resolves to the `qt` metapackage and pulls modules nothing needs.

**All fifteen `clap_plugin_gui_t` entry points are populated** in `src/clap/plugin.zig:484`, including `set_transient` and `suggest_title`, so nothing clap-host calls lands on a null pointer.

## Work

### 1. Install the missing prerequisites

Run by hand, since it needs admin access:

```bash
brew install ninja rtaudio rtmidi
```

Nothing else is needed. Do not install `qt6`.

### 2. Clone and build clap-host

Clone target is `~/Development/clap-host`, alongside the other repositories rather than inside this one. Note the collision hazard: this branch's worktree is `~/Development/fosforo__worktrees/clap-host`, which is a different directory with the same last component.

```bash
git clone --recurse-submodules https://github.com/free-audio/clap-host ~/Development/clap-host
cd ~/Development/clap-host
cmake --preset ninja-system
cmake --build --preset ninja-system
```

`--recurse-submodules` is load-bearing: `clap` and `clap-helpers` are submodules and the configure step fails without them. The `ninja-system` preset is Ninja Multi-Config with `UsePkgConfig=TRUE`, and it writes `builds/ninja-system/host/Debug/clap-host`.

Record the upstream commit that was built, since nothing pins it and a later checkout may behave differently.

### 3. Run it against this branch's build and verify

Build the plugin first, then point clap-host at the worktree rather than at `~/Library/Audio/Plug-Ins/`. Taking an explicit path is the one thing clap-host does that sidesteps the installed-versus-built provenance hazard entirely.

```bash
cd ~/Development/fosforo__worktrees/clap-host
zig build
~/Development/clap-host/builds/ninja-system/host/Debug/clap-host \
  -p "$PWD/zig-out/Fosforo.clap/Contents/MacOS/Fosforo"
```

Try the bundle path as well and record which of the two works, because the upstream README documents the one expected to fail.

Four things to confirm, in order:

1. **The plugin loads.** A `Failed to load plugin` warning from `QLibrary` means the path form is wrong, not that the bundle is broken.
1. **`clap.log` messages appear.** The plugin emits `initialised against host {name} {version}` at `CLAP_LOG_DEBUG` from `src/clap/plugin.zig:207`. Qt writes to `stderr`, and the default `CLAP_HOST_BUNDLE=FALSE` keeps clap-host a plain binary rather than an `.app`, so `stderr` is a tty and Qt does not divert to `os_log`. If debug messages are missing, `QT_LOGGING_RULES='*.debug=true'` is the fix; record whether it was needed.
1. **The editor embeds.** Do not trust your eyes: `clear_fragment` writes `RGB(5, 5, 8)`, which is indistinguishable from a black window. Use the two checks the phase 1 render gotcha prescribes. Read the once-a-second `rendering at N Hz` line from `src/clap/gui.zig:638`, and `screencapture` the window and sample a pixel, confirming the blue channel sits two or three above red and green. `editor embedded in the host window` from `src/clap/plugin.zig:637` is the positive statement that `set_parent` succeeded.
1. **The release build is the real test.** Rebuild with `zig build --release=fast` and re-run. The `stderr` mirror in `src/clap/log.zig:108` is compiled out of a release build, so any message still visible arrived through `clap_host_log.log`. This is the control that proves clap-host is reading the host path rather than the mirror, which is the entire claim the issue rests on, and it is the state in which REAPER shows nothing at all.

Known hazards to expect rather than debug from scratch: rtaudio opens an audio device at startup and may raise a microphone permission prompt against the terminal, which the GUI path does not depend on; and if a submodule turns out to declare a pre-3.5 minimum after all, `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` is the escape hatch.

### 4. Record it in `AGENTS.md`

One new gotcha bullet, immediately after the existing **REAPER accepts `clap.log` messages and discards them** bullet, which is the last entry in the Gotchas section. Single long line, matching every sibling. Nothing goes in the Development section: those commands are this project's, and clap-host is not.

The bullet has to carry all of:

- The motivating fact, stated as a contrast with the two bullets above it: clap-host is the only available host that shows what the plugin says about itself, and the only one that shows anything at all from a release build.
- The severity mapping, because it is lossy and surprising. `CLAP_LOG_DEBUG` becomes `qDebug()`, `CLAP_LOG_INFO` becomes `qInfo()`, and `CLAP_LOG_WARNING`, `CLAP_LOG_ERROR`, `CLAP_LOG_FATAL` and `CLAP_LOG_HOST_MISBEHAVING` all collapse into `qWarning()`. **`CLAP_LOG_PLUGIN_MISBEHAVING` falls out of the switch and prints nothing,** so a message sent at that severity is silently discarded by the one host adopted for reading messages. This plugin does not currently emit it; anyone who adds one should know.
- The build recipe from step 2 and the verified invocation from step 3, including which path form works and why the other does not.
- What it covers: `set_parent`, `get_size`, `show`, `hide`, `destroy`, `set_transient` and `suggest_title` all run, so it is a second opinion on the editor lifecycle and, unlike the Audio Unit, it exercises `gui->hide`.
- What it does not cover, stated so nobody reaches for it wrongly: `set_size`, `can_resize` and `adjust_size` are never called and `main-window.cc` fixes the window with `QSizePolicy::Fixed` and `setFixedSize()`, so it is not a resize test. The one direction it implements is `guiRequestResize`, plugin to host, which this project does not use. A minimal Qt example is not a DAW, so it is not a load test either and says nothing about multi-instance behaviour or dropouts.
- Why it can never be more than manual, naming ADR 0009 and ADR 0013.
- The upstream commit built and the fact that nothing pins it, so a future failure has a starting point.

### 5. Add a `CHANGELOG.md` entry

Under `## [Unreleased]` / `### Added`, in the register the surrounding entries use, referencing [#32](https://github.com/cboone/fosforo/issues/32). The substance is that the project gained a readable diagnostic channel for the first time, including from a release build, where the two existing hosts offer none.

### 6. Comment on issue #32

Post the correction from the findings section above: clap-host does call `set_parent`, `get_size`, `show`, `hide` and `destroy`, the original grep missed them because clap-helpers' `PluginProxy` renames them to camelCase, and the accurate narrower claim is that `set_size`, `can_resize` and `adjust_size` are never called. Leave the issue body as the historical record of what was believed. Use a tmpfile with `gh issue comment --body-file`.

## Files

- `AGENTS.md`, one added bullet at the end of the Gotchas section. `CLAUDE.md` is a symlink to it, so this is a single edit.
- `CHANGELOG.md`, one added line under Unreleased / Added.
- This plan file moves to `docs/plans/done/` when the work lands.

No source, build, or CI file changes. Nothing is added to `scripts/`: this is a documented recipe for an external tool, not automation, and a script would encode a path to a checkout this repository does not own.

## Verification

- `zig build` and `zig build test` still pass, trivially, since no code changes.
- `npx markdownlint-cli2` is clean over the two edited files, under the repository's `.markdownlint-cli2.jsonc`.
- The recipe in `AGENTS.md` is verified by having been executed in step 2, not transcribed from upstream. The invocation is verified by having produced visible `clap.log` output in step 3.
- The claim that clap-host reads the host path rather than the `stderr` mirror is verified by the release-build control in step 3.4, which is the only check that distinguishes the two.
- Every "what it does not cover" claim is verified against upstream source rather than inferred from behaviour, since a fixed window and an unimplemented callback look identical from outside.

### Outcome

Built against `c8ce3ee` (2026-06-18). All four checks in step 3 passed.

- Both path forms load. `Loading plugin with id: com.catamount.fosforo index: 0`.
- `clap.log` reaches Qt's output with no `QT_LOGGING_RULES` needed. The host identifies itself as `Clap Test Host`.
- The editor embeds and renders: `editor embedded in the host window`, then `rendering at 120.0 Hz, 960x540 at 2.00x` once a second.
- The release control is decisive. Rebuilt `--release=fast`, the `[fosforo]` mirror lines drop to zero while the bare Qt copies remain, so what is being read is the host path.

The pixel sample needed one detour worth recording. A full-screen `screencapture` grabbed the main display, which was not the one clap-host opened on, and returned an unrelated window; before that it failed outright with `could not create image from display` until screen-recording permission was granted. Capturing by window id is the reliable form. The result: sampling at a two-pixel stride, 518,279 sampled pixels were exactly `RGB(5, 5, 8)`, and their bounding box was 1918x1078 physical, which is 960x540 at 2x offset 65 points for Qt's menu bar. The stride accounts for the factor of four against the box's 2,067,604 pixels, so the region is solid rather than speckled. By eye the window is a black rectangle, which prompted [#45](https://github.com/cboone/fosforo/issues/45).

Also found: `rendering at N Hz` is absent from a release build for a reason unrelated to the log mirror, since the frame meter is itself debug-only at `src/clap/gui.zig:629`. And clap-host builds CLAP 1.2.9 against this project's 1.2.10, with nothing pinning the upstream commit.

## Out of scope

- Any change to `src/clap/log.zig`. The severity mapping is clap-host's business and the `stderr` mirror stays exactly as it is.
- Pinning or vendoring clap-host, adding it to CI, or wiring it into `zig build`. ADR 0009 and ADR 0013 both forbid it and the issue agrees.
- Anything about resizing. clap-host cannot test it, which is the point of writing that down.
