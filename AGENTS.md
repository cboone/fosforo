# fosforo

## Overview

A Mac-first GPU-rendered phosphor oscilloscope and signal-analysis plugin, authored as a CLAP and rendered with Metal.

The display name is **Fósforo**; the repository, binary, and identifiers stay ASCII `fosforo`.

## Current state

Phase 3 of [the build plan](docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md), four numbered steps in. **Phase 2 is closed.** The plugin loads in REAPER and Logic, passes stereo audio through, saves state, taps one channel into `src/dsp/ring.zig`, and reads a trailing 20 ms window on the render thread which `Renderer.frame` copies into a per-frame `MTLBuffer`. That the picture is the signal is the one claim no harness could close, because the drawable is `framebufferOnly` and reading it back would change the shipping renderer; it was settled instead by the host procedure in [#38](https://github.com/cboone/fosforo/issues/38), run against hash-verified installs and measured out of screenshots rather than judged by eye.

The trace now deposits additively into a persistent `RGBA16F` ping-pong accumulation pair ([#55](https://github.com/cboone/fosforo/issues/55)), so `shaders/scope.metal` encodes **two** render passes and three draws: `decay_fragment` then `trace_fragment` into the accumulation, and `resolve_fragment` into the drawable. Two chores the plan sequenced behind that one have also landed: `scripts/measure-trace` is committed here and its guard reads colour rather than counting shades ([#64](https://github.com/cboone/fosforo/issues/64)), and `zig build smoke-leaks` runs in CI at 40 cycles ([#63](https://github.com/cboone/fosforo/issues/63)), which refused the peak-RSS slope it was filed to add.

**What the pixels became is now checked automatically** ([#51](https://github.com/cboone/fosforo/issues/51)). `zig build smoke-trace` is a third smoke half, needing a device and no window and required in CI beside `smoke-gpu`: `Renderer` grew a `Surface` union and a second constructor, so the shipping `frame` resolves into a texture the backend owns rather than a drawable, and `src/gpu/measure.zig` reads the result back as rows, periods and implied samples. Ten planted defects were caught, #55's resolve gain among them.

**The resolve is finished** ([#60](https://github.com/cboone/fosforo/issues/60), [ADR 0019](docs/adr/0019-brightness-is-a-fixed-transfer-function.md)). It compresses accumulated energy through extended Reinhard and looks the result up in one of four gradients running to white, into a `BGRA8Unorm_sRGB` drawable so the arithmetic runs in linear light. The hot core ADR 0007 predicted is emergent and is executed rather than claimed: `smoke-trace` drives one deposit and thirty and reads `RGB(143, 224, 154)` and `RGB(255, 255, 255)` off the picture. **The first of those figures was `RGB(75, 189, 96)` here until #96 read it off a run**: #57 gave the beam area and a density scale, so one deposit is brighter than it was when #60 measured it, and the number went stale on a branch that changed nothing about the resolve. The `smoke-trace` transcript is identical at #96's base and tip, so this is a correction rather than a movement. The trace deposits a scalar now; there is no colour anywhere in `shaders/scope.metal`.

**The beam is geometry** ([#57](https://github.com/cboone/fosforo/issues/57)). Each inter-sample segment is an instanced quad and `trace_fragment` shades it by distance from the _segment_, so caps are round, joints have no wedge gaps, and the endpoints at `x = ±1` have area — which closed #38's 1914-of-1920 edge columns at 960 of 960 on a single frame. The width is **3.0 points**, in points rather than pixels so the rail clearance is scale-free, and the profile is the biweight `(1 - u²)²`, whose compact support is what keeps unlit pixels at exactly 0.0. The seam's raw-samples prediction held: still no `MTLVertexDescriptor`, still a plain `[]const f32`. Two consequences that were not anticipated. Overlap at joints retired the "one frame cannot deposit twice on a pixel" premise the tonemap's argument rested on, taking a moving trace from 1.0000 deposits to **2.6133**. And it made per-pixel brightness scale with samples per logical point, roughly `1 + 1.6 * s`, which would white out a moving trace at 192 kHz; `TraceUniforms.density` clamps that, and it is not velocity weighting because it is one number per frame that depends on nothing about the signal.

**Verified in REAPER across four arms.** A 0.5 sine inverts to ±0.5000 exactly, at 48, 96 and 192 kHz alike; the level sweep reads +0.9991, +1.0504, +1.0894 and +1.0894, so the display is honest about level below the rail and stops counting at it, which is ADR 0017 executed rather than asserted. **The joints do not bead**, which was the one thing the plan could not settle by derivation: adjacent capsules overlap along their whole length rather than meeting end to end, because the segment pitch is under the beam width, so coverage is uniform and there is no ripple at the sample period.

**What is left of the phosphor look is filed:** velocity weighting ([#58](https://github.com/cboone/fosforo/issues/58)) and bandlimited reconstruction ([#59](https://github.com/cboone/fosforo/issues/59)).

[#22](https://github.com/cboone/fosforo/issues/22) has landed, which was phase 2 work carried forward rather than a phase 3 step: it is the install-path ambiguity the provenance gotcha below describes, and it had already voided two verification runs of the kind every remaining issue here depends on. Every build now says which worktree and commit it came from ([ADR 0018](docs/adr/0018-stamp-provenance-without-namespacing-identity.md)), `CLAP_PATH` was established to work and is deliberately not used, because this project runs one host stream at a time, and two of the issue's four proposals were refused with measurements rather than built.

[#61](https://github.com/cboone/fosforo/issues/61) has landed, pulled forward from step 9 because shader hot-reload is worth five issues' worth of iteration rather than none. A debug build watches `shaders/scope.metal` and swaps the pipelines without restarting the host, which discharges a consequence [ADR 0009](docs/adr/0009-runtime-shader-compilation.md) recorded when it chose runtime compilation. It also settled the number the rest of phase 3 will be argued against: a source Metal has not seen takes about **40 ms** to compile, against 0.14 ms for one it has, so the compile runs on a thread of its own and hands finished pipelines to the render loop through a mailbox. [#59](https://github.com/cboone/fosforo/issues/59) defers the same "where does slow work run" question about its own upsampling and can reuse that shape.

[#56](https://github.com/cboone/fosforo/issues/56) has landed, and it inherited a value rather than a defect, exactly as this paragraph used to predict: because the white point derives from the decay, the provisional `decay_per_frame = 0.90` was a pure persistence knob, and turning a per-frame factor into a time constant was a matter of naming the rate it was anchored at. That rate is 60 Hz, so `palette.decay_tau_nanos` is `-(1 / 60) / ln(0.90)` or **158.19 ms** and every offscreen number the harness printed before it prints still. On this machine the trail is now twice what it was, because the panel runs at about 120 Hz where a per-frame 0.90 faded twice as fast; at 60 Hz nothing changed. `Renderer.frame` takes an absolute monotonic reading rather than an interval, and `CVTimeStamp` was refused with an argument recorded in `src/platform/displaylink.zig`.

[#77](https://github.com/cboone/fosforo/issues/77) has landed, which is the gap #61 opened by making the shader reloadable: everything tying the Zig constants to the MSL read the _embedded_ copy at comptime, so a swapped-in file got `buildPipeline`'s missing-function check and nothing else. `bindingIndexIn` now takes its source as a parameter and one `bindings` table has two readers, the comptime test over the embedded copy and `noteBindings` over whatever came off disk. **A mismatch is warned about and swapped in anyway**, and that decision was settled by measurement rather than by taste: rendering three shaders with one index moved apiece, one per index space, every draw completed and the unbound argument read as **zeros**, giving a flat trace, a black background and no trace at all. So refusing the swap would have been trading a wrong picture the next save fixes for a reloader people stop trusting. `iface.ShaderStats.binding_mismatches` is what makes the check assertable rather than trusted. **It closes half a class**: `TraceUniforms` layout drift is still readable from nowhere, because MSL computes its own offsets.

[#92](https://github.com/cboone/fosforo/issues/92) has landed, which is item 4 of [the verification-gaps program](docs/plans/todo/2026-09-04-close-the-verification-gaps-in-the-test-suite.md) rather than a phase 3 step, and it is the same argument ADR 0013 won at #51 applied to the half that was left out. `src/gpu/measure.zig` reads a trace back as numbers and has its own tests; the thirteen `check*` functions deciding whether those numbers were the right ones lived in a 2,240-line file with **zero** test blocks that `zig build test` never compiled. The judgements are now `src/gpu/verdict.zig`, the harness keeps the driving, and `zig build smoke-trace`'s transcript is byte-identical across the move. The suite went from 230 tests to 252, and the plant table in `docs/plans/done/2026-08-29-verify-the-shader-offscreen-against-the-constants.md` gained a column naming the test that covers each row, which is what makes those plants regress rather than being prose about a check nobody re-runs. **Planting the judges is where the findings were:** a blank readback used to pass the decay checks outright, because `nan` compares false; the `expectClose` defect the issue named turned out not to exist, while a different one did; and two tests that encoded a plant were not covering it, having been planted far enough outside a bound to be caught by something else.

[#93](https://github.com/cboone/fosforo/issues/93) has landed, which is item 5 of the same program and the same move one layer down. `renderer.zig`'s `Watcher` is `if (shader.live) struct { ... } else struct { ... }` and `shader.live` folds in `!builtin.is_test`, so a test binary took the stub: the real `poll` was not merely untested but **not compiled**, and no test written in `zig build test` could have reached it. The same gate stood over `buildPipelines` and `readShader`, which carried a second copy of the bookkeeping, and the two copies **disagreed** — a compile failure under the watcher moves `rejected` alone, because nothing falls back, while the same failure when an editor opens moves `rejected` _and_ `fallbacks`. That was two pairs of `fetchAdd` calls two thousand lines apart; it is now `src/gpu/metal/reload.zig`, a six-row table with a test that reads it, beside the poll's `seen` state machine. The suite went from 297 tests to 318 and both smoke transcripts are unchanged.

**The finding is that the issue named an instrument that does not work.** #93 says its acceptance plant, a `poll` advancing `seen` only on success, is one "today only a hand-run `smoke-appkit` would catch". Run against `poll` as it stood, before anything moved: `zig build test` reported 297 of 297 and `zig build smoke-appkit` reported `ok`, with all five hot-reload arms running. **Nothing caught it.** Two more things planting produced. A third site the issue did not name, `noteBindings`, whose counter increment no test binary compiled either, because a private function reached only from gated call sites is never analyzed — `firstBindingMismatch` beneath it had five tests and the pairing had none. And a weakness in `hotReloadPhase`'s fourth arm, which under that defect can pass without the renamed shader ever being read, since it waits on `rejected >= n + 1` while the previous arm's broken file is still being re-rejected four times a second. That one stays open.

**The next issue in the plan's order is [#58](https://github.com/cboone/fosforo/issues/58)**, with [#59](https://github.com/cboone/fosforo/issues/59) behind it.

## Non-negotiables

These are settled decisions recorded in [`docs/adr/`](docs/adr/). Do not relitigate them in code review; supersede them with a new ADR instead.

- **macOS on Apple Silicon only.** Not a portability oversight (ADR 0001).
- **Zig is pinned to 0.16.0.** `build.zig.zon` is the single source of truth and CI reads it. Compiler bumps are deliberate, scheduled work (ADR 0002).
- **The plugin is authored once, as a CLAP.** Never author an Audio Unit or VST3 directly; clap-wrapper projects outward (ADR 0003).
- **Metal must not leak above `src/gpu/iface.zig`.** That seam is load-bearing even though only one backend exists (ADR 0005).
- **No WebView UI** (ADR 0006).
- **Nothing reachable from the audio thread may allocate, lock, or make a syscall** (ADR 0010).
- **The GUI smoke harness is an executable behind its own steps, never part of `zig build test`** (ADR 0013).
- **`std.Io` is reached through the one instance in `src/platform/io.zig`, constructed with `init_single_threaded` and never with `Threaded.init`.** Guarded since #90 by a comptime assertion on the value and a canary on the shape, and by the compiler, which refuses the direct substitution outright (ADR 0015).
- **The ring's release store and acquire load are verified by `zig build ring-race`, and the gate's by `zig build gate-race`, each guarded by a canary in its own file.** Weakening either without reading ADR 0016 is the failure this exists to stop (ADR 0016, #91).
- **Every ordering-critical declaration is canaried against its own source**, through `src/canary.zig`: the ring's five atomics, the `std.Io` constructor, `Gate`'s five in `src/clap/gate.zig`, `Pending` in `src/clap/gui.zig`, and `Mailbox` and `Watcher.halt` in `src/gpu/metal/renderer.zig` (#90, #91).
- **The vertical axis is absolute. The display never rescales itself to the signal, and over-scale rails rather than being hidden or clipped away** (ADR 0017).

## Structure

```text
build.zig                   three artifacts from one core: static lib, .clap bundle, smoke harness
build.zig.zon               pins Zig 0.16.0, CLAP 1.2.10, zig-objc by content hash
cmake/                      clap-wrapper integration, used only for the AUv2 build
  CMakeLists.txt
  entry.cpp                 the only C++ in the project; builds the clap_entry symbol
  entry.h                   declares the three extern "C" functions entry.cpp calls
  narrow-au-resource-usage  drops clap-wrapper's default AU sandbox claims
  set-au-display-name       writes the display name and description into the AU
macos/Info.plist            the .clap bundle's plist
shaders/scope.metal         compiled at runtime from embedded source, not linked
packaging/distribution.xml  the installer's domains, choices and payload layout
scripts/
  build-audio-unit          the CMake half of the build, with its two constraints encoded
  install-plugins           the one implementation of "copy a bundle and prove it landed"
  smoke-leak-check          wraps the smoke harness in `leaks --atExit` and judges the report
  race-check                runs both arms of a race harness and judges the control first
  measure-trace             reads a trace out of a screenshot; the only Python here
  read-provenance           reads the branch and commit back out of a built bundle
  assert-adhoc-signature    CI's guard that the default build stays offline and ad-hoc
  assert-distributable-signature  the inverse, run locally: Developer ID, hardened, timestamped
  build-release-bundles     release step 1: both bundles, signed to notarize
  build-installer           release step 2: one pkg, signed with the Installer identity
  notarize-installer        release step 3: submit, staple, assess
src/
  main.zig                  the host-facing boundary and exported entry points
  build_info.zig            the branch, commit and dirty state, in the three shapes anything reads
  canary.zig                reads a file's own source as text; reached only from `test` blocks
  smoke.zig                 the out-of-band GUI smoke harness, which plays the host
  ring_race.zig             the history buffer on two threads; one of two checks needing Linux
  gate_race.zig             the teardown gate on two threads; the other one
  clap/c.zig                translated CLAP ABI plus comptime layout assertions
  clap/clap_all.h           the header set build.zig runs through `zig cc -E`
  clap/plugin.zig           factory, descriptor, lifecycle, audio ports, process
  clap/gui.zig              the editor's lifecycle, the resize mailbox, the tick
  clap/gate.zig             the teardown barrier; its own file so Linux can race it
  clap/state.zig            the versioned save/load format and its stream loops
  clap/log.zig              diagnostics routed through the host's clap.log
  dsp/ring.zig              the lock-free history buffer the two threads share
  gpu/iface.zig             THE SEAM. No Metal type may be named above this file
  gpu/measure.zig           reads a rendered trace back as numbers; pure, no GPU
  gpu/palette.zig           the display's colour contract: curve, gradients, sRGB
  gpu/verdict.zig           what those numbers had to be; pure, no GPU
  gpu/metal/renderer.zig    the one backend: device, pipelines, surface, one frame
  gpu/metal/reload.zig      what a poll decides and what it costs the tally; no Metal
  gpu/metal/shader.zig      where the shader source comes from; names no Metal type
  platform/io.zig           the one std.Io instance, and the only place one is built
  platform/objc.zig         Core Graphics types and the thread assertions
  platform/displaylink.zig  CVDisplayLink, and the monotonic clock it is measured by
  platform/view.zig         the NSView the host embeds, and nothing about Metal
docs/
  adr/                      settled architecture decisions
  design/                   the source brainstorm this project came from
  plans/todo/               active plans
  plans/done/               completed plans, kept as historical records
```

## Development

```bash
zig build                  # produces zig-out/Fosforo.clap, and nothing else
zig build test             # unit tests, at whatever -Doptimize says; Debug by default
zig build test-safe        # the same suite pinned to ReleaseSafe: optimized, checks still on
zig build test-release     # the same suite pinned to ReleaseFast, which is what ships
zig build impl             # libfosforo_impl.a alone, which is all CMake wants from Zig
zig build audio-unit       # produces build/assets/Fosforo.component, through CMake; slow, see below
zig build plugins          # both bundles, still in the worktree
zig build install-clap     # build the CLAP, install it, print the hash of what landed
zig build install-plugins  # the same for BOTH bundles, so a host result can be trusted
zig fmt --check build.zig src/
scripts/read-provenance zig-out/Fosforo.clap  # which branch and commit a built bundle came from
zig build install-clap && /Applications/REAPER.app/Contents/MacOS/REAPER 2>&1 \
  | grep --line-buffered fosforo   # the whole host loop; hot reload needs no env var
zig build validate-shaders # needs the Metal toolchain; see below
zig build smoke            # runs Metal and AppKit for real; needs a GPU and a window server
zig build smoke-gpu        # the half that needs no window: device, shader, pipeline
zig build smoke-trace      # the other half that needs no window: what the shader actually drew
zig build smoke-appkit     # the half that opens a window and cycles the editor
zig build smoke-leaks      # 400 cycles under `leaks --atExit`, judged by scripts/smoke-leak-check
zig build smoke-leaks -Dleak-cycles=40  # what CI runs; the criteria do not vary with depth, the cost does
zig build ring-race        # the history buffer on two threads under Thread Sanitizer; needs a Linux host
zig build gate-race        # the editor's teardown gate, the same way and on the same host
zig build-exe src/ring_race.zig -fsanitize-thread -lc -target x86_64-linux-gnu  # compile-check it from macOS
codesign --verify --strict --verbose zig-out/Fosforo.clap  # the bundle signature, not the linker's
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d      # no parser/printer options: they discard .editorconfig
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck
typos                      # spell-checks the whole tree; allowlist and ignore patterns in typos.toml
npm ci                     # the two Markdown tools, at the versions package-lock.json pins. NOT optional, see below
npm run format             # THE fixer: tables, emphasis, fences. Run this before the linter
npm run lint:md            # every .md; config in .markdownlint-cli2.jsonc. NEVER markdownlint-cli2 --fix, see below
ruff format --check . && ruff check .  # the one Python file; ruff.toml is what makes it visible
actionlint                 # every workflow. Needs shellcheck on PATH, or it skips run: blocks in silence
scripts/measure-trace shot.png         # reads a trace out of a screenshot, in backing pixels
scripts/measure-trace --refresh 60 shot.png  # a capture taken with the display pinned to 60 Hz
scripts/measure-trace --scale 1 shot.png     # a capture from a non-Retina display
```

`zig build` alone produces a loadable `.clap`, which REAPER opens natively. That is the day-to-day loop and it never invokes CMake.

**Every `install-*` step builds exactly what it installs, copies it to `~/Library/Audio/Plug-Ins`, and prints the hash of what landed; every other step stays in the worktree.** That invariant is the whole distinction between the steps whose names begin with "install", including Zig's own, which writes to `zig-out` and says so in `zig build --help`. It is also what closed #43: both install steps used to build the CLAP and neither built the Audio Unit, so `install-plugins` installed a component only if CMake happened to have been run in that worktree already, and a worktree where it had not kept whatever component another branch had installed and said nothing about it.

CMake is needed only for the Audio Unit that Logic requires, and it is much slower because it fetches the AudioUnit SDK. `zig build audio-unit` runs `scripts/build-audio-unit`, which configures only when `build/` is absent and builds `fosforo_all`; those are the two things worth getting right and they are no longer something to remember:

```bash
cmake -B build cmake/                       # what the script does once per worktree
cmake --build build --target fosforo_all    # and every time; not fosforo_auv2, see below
```

Validate with `clap-validator validate zig-out/Fosforo.clap`. CI runs it on every push against **both** `.clap` bundles, the Zig-built one and the clap-wrapper-built `build/assets/Fosforo.clap`, so neither is only a local step, and it asserts every bundle's signature alongside them. The Audio Unit has no equivalent: `auval` cannot see this component at all, for the reason in the gotchas below, so loading it in Logic is the only check there is.

## Releasing

A release is a single signed, notarized, stapled `.pkg` that places both bundles (ADR 0014). It is built locally and deliberately never in CI, because this repository is public and the alternative is Developer ID private keys in repository secrets. Three steps, each independently re-runnable, so a rejected notarization does not cost a rebuild:

```bash
export FOSFORO_SIGNING_IDENTITY="Developer ID Application: ..."
export FOSFORO_INSTALLER_IDENTITY="Developer ID Installer: ..."
scripts/build-release-bundles          # both bundles, hardened and timestamped
scripts/build-installer                # one pkg, signed with the Installer identity
scripts/notarize-installer dist/Fosforo-VERSION.pkg
```

`scripts/build-installer --unsigned` exercises packaging without a certificate. It cannot be notarized, is named so it cannot be mistaken for a release, and skips the input signature check, which it says out loud.

The credentials `notarytool` needs live in a keychain profile, never on a command line:

```bash
xcrun notarytool store-credentials "fosforo-notary" \
  --key ~/path/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer XXXXXXXX-...
```

An App Store Connect API key rather than an app-specific password, because it is scoped, independently revocable, and not the Apple ID password. The `.p8` downloads once and never again, so the copy on disk is the only copy; `.gitignore` covers `*.p8` for that reason.

**The certificates on hand expire 2027-02-01 and replacing them is outstanding** ([#30](https://github.com/cboone/fosforo/issues/30)). They were issued through Xcode under the G1 intermediate rather than G2, which caps both leaves at their issuer's expiry; the gotcha below has the full diagnosis and the check that surfaces it. Nothing already signed is at risk, because a secure timestamp outlives the certificate — what stops is signing anything new, and on current sequencing that happens before v0.1.0 is cut. Re-issue from the developer portal rather than Xcode, and do not revoke the superseded pair.

## Rules

Every one of these is here because omitting it causes **silent damage or a wrong pass**, not a legible error. The reasoning behind each is in the note named beside it; these lines are the part that has to be in context before you have opened anything.

- **Confirm provenance before trusting any result a host gave you.** The failure reads as a pass. `zig build install-clap` builds what it installs and prints the hash and provenance of what landed. See [host verification](docs/notes/host-verification.md).
- **One host stream at a time.** Install, launch, read. The shared plug-in folder and the window server are both exclusive, so a second stream corrupts someone else's run, not only yours. See [host verification](docs/notes/host-verification.md).
- **The REAPER pipe needs `2>&1` and `grep --line-buffered`, and each fails differently.** Without the first the plugin's lines pass through unfiltered; without the second the render meter arrives in bursts minutes apart, which reads as a stopped render loop. See [reading diagnostics](docs/notes/reading-diagnostics.md).
- **Run the worktree's own `scripts/measure-trace`, never a copy from anywhere else.** It restates constants a branch may have moved, so another copy runs and reports confident numbers against the wrong mapping. See [measuring a capture](docs/notes/measuring-a-capture.md).
- **Verify at 48 kHz.** Above it the window holds more samples than the drawable has pixels, and structure that appears only at a higher rate is moiré rather than signal. See [trace and phosphor physics](docs/notes/trace-and-phosphor-physics.md).
- **Captures go in `verification/`, never into a commit.** They are working artifacts of one session; what belongs in the repository is the numbers read out of them. One reached a commit before this rule existed and removing it meant rewriting three commits.
- **`zig build` does not rebuild the smoke harness.** `zig build && zig-out/bin/fosforo-smoke appkit 40` runs whatever a previous smoke step left there, with no warning and no hash to compare. Run a smoke step. See [the smoke harness](docs/notes/smoke-harness.md).
- **Run Prettier before the Markdown linter, and never pass `--fix` to `markdownlint-cli2`.** `npm run format` then `npm run lint:md`. `--fix` ignores the files you name and rewrites everything matching its `globs`, including completed plans. See [linters](docs/notes/linters.md).
- **Select files for `shfmt` with `git ls-files`, never `shfmt -d .` or `-w .`.** `shfmt` does not read `.gitignore`, so a tree walk reaches vendored scripts under `build/`. A fresh CI checkout has no `build/`, so this passes there and fails locally. See [linters](docs/notes/linters.md).
- **When a diff corrects a measured figure, grep the old value across the repository.** Figures here are quoted across `AGENTS.md`, `CHANGELOG.md`, several ADRs, the build plan and sometimes a workflow comment, so a correction applied where you noticed it leaves the stale copies reading as current.
- **Anything in `docs/plans/done/` is a historical record.** Never update a citation, a figure or a line number in one. A done plan's `path:line` citations are pre-change locations and are correct precisely because they no longer resolve. `docs/notes/` is the opposite: living, and corrected in place.
- **No job counts or run counts in prose about CI.** A declared job is not a rollup entry and reusable workflows expand, so any count goes stale on the next workflow edit. Anchor a measurement to a run id or leave it out. See [CI workflows](docs/notes/ci-workflows.md).

Two more are settled decisions rather than rules of thumb, and are stated in full under [Non-negotiables](#non-negotiables): nothing reachable from the audio thread may allocate, lock, or make a syscall; and no Metal type may be named above `src/gpu/iface.zig`.

## Where the depth lives

Everything this file used to carry as a flat list of gotchas is in [`docs/notes/`](docs/notes/README.md), one document per thing you might be about to do. They are **living documents**: a stale figure in one is repaired by a fresh measurement written in place, unlike an ADR, which is superseded, or a done plan, which is never corrected at all.

| Read before                                                    | Note                                                                   | Answers                                                                                |
| -------------------------------------------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| editing `build.zig`, `cmake/`, `macos/Info.plist`, identifiers | [build system](docs/notes/build-system.md)                             | restated constants, `translate-c`, git stamping, optimize-mode split, display name     |
| editing `.github/workflows/*.yml`                              | [CI workflows](docs/notes/ci-workflows.md)                             | what dispatches `ci.yml`, `actionlint`'s blind spot, pins, timeouts, runner ceiling    |
| touching an atomic, a canary, `std.Io`, a race harness         | [concurrency and canaries](docs/notes/concurrency-and-canaries.md)     | `ring-race`, `gate-race`, why `Pending` has no arm, `use_llvm`, `Threaded.init`        |
| running the plugin in a host, or trusting a result from one    | [host verification](docs/notes/host-verification.md)                   | provenance, `CLAP_PATH`, the symlinked AU, one stream at a time, AU registration       |
| adding an allocation, or reading a `leaks` report              | [leak instruments](docs/notes/leak-instruments.md)                     | what `leaks` cannot see, the byte bound, the counters, the blindness matrix            |
| running or configuring a linter                                | [linters](docs/notes/linters.md)                                       | `shfmt` and `.editorconfig`, `typos` tables, Prettier vs markdownlint, `ruff`'s rules  |
| capturing the editor, or quoting a number from a capture       | [measuring a capture](docs/notes/measuring-a-capture.md)               | the colour guard, sRGB versus the display profile, cropping, the test signals          |
| looking for a log line from the plugin                         | [reading diagnostics](docs/notes/reading-diagnostics.md)               | REAPER discards `clap.log`, Logic cannot be launched, `clap-host`                      |
| editing `src/clap/gui.zig`, `src/platform/`, `Renderer.frame`  | [render loop lifecycle](docs/notes/render-loop-lifecycle.md)           | the teardown gate, bounded waits, semaphore slots, buffer staging, ownership           |
| editing `shaders/scope.metal` or anything that binds to it     | [shader plumbing](docs/notes/shader-plumbing.md)                       | `TraceUniforms` drift, binding indices, compile cost, hot reload, the validation layer |
| signing, packaging, or cutting a release                       | [signing and notarization](docs/notes/signing-and-notarization.md)     | two certificates, the G1 expiry trap, stapling, why entitlements are inert             |
| changing `src/smoke.zig` or a `zig build smoke-*` step         | [smoke harness](docs/notes/smoke-harness.md)                           | what `smoke-trace` proves, the background colour, wall-clock waits, the watcher poll   |
| reasoning about what `zig build test` compiles                 | [the test suite](docs/notes/the-test-suite.md)                         | the three optimize modes, lazy per-declaration analysis, `refAllDecls`                 |
| judging whether the picture is the signal or an artifact       | [trace and phosphor physics](docs/notes/trace-and-phosphor-physics.md) | the rail, the floor, the moiré ceiling, railing, the transport-stop line               |
