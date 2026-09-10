# Reading diagnostics

Where a log line from the plugin can actually be read, which is a different answer for each of the three hosts. Read this before looking for one.

- **Logic cannot be launched from a terminal to read the plugin's diagnostics, the way REAPER can.** Running `Logic Pro.app/Contents/MacOS/Logic Pro` directly starts it outside the launch services path it expects and most plugins then fail to register, so the run is not the one worth measuring. There is no equivalent of REAPER's terminal-launch trick, and the debug `stderr` mirror in `src/clap/log.zig` is therefore unreadable in Logic. Verify the Audio Unit by the pixel sample described in [the smoke harness](./smoke-harness.md), or by `zig build smoke-appkit`, and treat the CLAP in REAPER as the place diagnostics are read.

- **REAPER accepts `clap.log` messages and discards them.** It implements the extension, so `Log.init` finds it and a host-only design would send every diagnostic into a hole with no visible destination. That is why debug builds mirror to `stderr` as well as calling the host, rather than treating `stderr` as a fallback for hosts that offer nothing. Launch REAPER from a terminal to read them.

- **[`clap-host`](https://github.com/free-audio/clap-host) is where those messages can actually be read, and it is the only host here that shows anything at all from a release build.** It is the CLAP reference host, it implements `clap.log`, and it routes messages into Qt's logging rather than dropping them the way REAPER does. Since the `stderr` mirror is compiled out of a release build, and Logic cannot be launched from a terminal at all, a `--release=fast` plugin otherwise has no readable diagnostic channel anywhere. It is a **manual** tool and nothing else: not a build dependency, not a CI step, not a substitute for a DAW. Build it once, outside this repository, and keep it:

  ```bash
  brew install ninja rtaudio rtmidi   # cmake, qtbase and pkgconf are already present for other reasons
  git clone --recurse-submodules https://github.com/free-audio/clap-host ~/Development/clap-host
  cd ~/Development/clap-host && cmake --preset ninja-system && cmake --build --preset ninja-system
  ```

  Do not install `qt6`: that alias resolves to the `qt` metapackage, while `find_package` asks only for `Qt6Core` and `Qt6Widgets`, both of which are in `qtbase`, and `qtbase` is linked into `/opt/homebrew` rather than keg-only, so no `CMAKE_PREFIX_PATH` is needed. `--recurse-submodules` is load-bearing, since `clap` and `clap-helpers` are submodules and configuring fails without them; `vcpkg` comes along too and the `ninja-system` preset never touches it. All three declare `cmake_minimum_required(VERSION 3.17)`, above CMake 4's floor of 3.5, so CMake 4.4.2 configures with no policy shim. Then, from a worktree:

  ```bash
  ~/Development/clap-host/builds/ninja-system/host/Debug/clap-host -p "$PWD/zig-out/Fosforo.clap"
  ```

  **Because it takes an explicit path, it reads the worktree rather than `~/Library/Audio/Plug-Ins/`,** which sidesteps the provenance hazard above entirely: no install step and no hash comparison, because you named the file. `-p` accepts the bundle directory or the inner binary and both work, but for different reasons than you would guess. A bare `dlopen` on the bundle fails with `not a file`; `QLibrary` is what resolves it to `Contents/MacOS/Fosforo`, confirmed with `DYLD_PRINT_LIBRARIES=1`, so the bundle form depends on Qt rather than on anything about the bundle. The long option is `--clap-plugin`, not the `--plugin` upstream's README claims.

  **The severity mapping is lossy, and one severity vanishes.** `CLAP_LOG_DEBUG` becomes `qDebug()`, `CLAP_LOG_INFO` becomes `qInfo()`, and `CLAP_LOG_WARNING`, `CLAP_LOG_ERROR`, `CLAP_LOG_FATAL` and `CLAP_LOG_HOST_MISBEHAVING` all collapse into `qWarning()`. `CLAP_LOG_PLUGIN_MISBEHAVING` falls out of the switch entirely and prints nothing, so a message sent at that severity is silently discarded by the one host adopted for reading messages. Nothing emits it today; anyone who adds one should know.

  **In a debug build every message appears twice,** once bare from Qt and once carrying the `[fosforo]` prefix from the `stderr` mirror, and that doubling is the tell for which channel you are reading. A release build shows only the bare copies, which is the positive control that the host path works rather than the mirror. `rendering at N Hz` disappears in release for an unrelated reason, `Editor.report`'s `if (builtin.mode != .Debug) return;` at `src/clap/gui.zig:828`, so a release run shows the lifecycle messages and no render meter.

  **It exercises more of the editor lifecycle than the issue proposing it claimed.** `create`, `get_size`, `set_parent`, `set_transient`, `suggest_title`, `show`, `hide` and `destroy` all run, which makes it a second opinion on embedding and, unlike the Audio Unit, a caller of `gui->hide`. Grepping its source for `set_parent` finds nothing, because it drives the plugin through clap-helpers' `PluginProxy`, which renames them to `guiSetParent` and the rest; grep the camelCase names or you will conclude it does nothing.

  **It cannot test resizing, and reaching for it to do so is the mistake worth naming.** `set_size`, `can_resize` and `adjust_size` are never called, and `host/main-window.cc` pins the window with `QSizePolicy::Fixed` and `setFixedSize()`, so the user cannot drag it. The one direction it implements is `guiRequestResize`, plugin to host, which this project does not use. It is not a load test either: a minimal Qt example says nothing about multi-instance behaviour or dropouts, and REAPER and Logic stay the tools for that. It also stays manual permanently, because Qt6, CMake, Ninja, rtaudio and rtmidi are precisely the non-hermetic dependency ADR 0009 keeps off the build, and ADR 0013 already assigns automated GUI verification to `src/smoke.zig`.

  Verified against `c8ce3ee` (2026-06-18), which builds CLAP 1.2.9 against this project's 1.2.10. **Nothing pins that commit,** so re-check after a pull. `MidiInCore::openPort: no MIDI input sources found!` and an empty `Loading with Audio API: ""` are normal startup noise, not symptoms. The window is 960x605 for a 960x540 editor, the extra 65 points being Qt's menu bar. And the editor still looks like a black window in it, so the pixel sample from [the smoke harness](./smoke-harness.md) is still the check that decides: capture by window id, since a full-screen `screencapture` grabs the main display, which need not be the one clap-host opened on.
