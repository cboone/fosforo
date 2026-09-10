# fosforo

## Overview

A Mac-first GPU-rendered phosphor oscilloscope and signal-analysis plugin, authored as a CLAP and rendered with Metal.

The display name is **Fósforo**; the repository, binary, and identifiers stay ASCII `fosforo`.

## Current state

Phase 3 of [the build plan](docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md), five numbered steps in; phase 2 is closed. **That plan's phase 3 table and its verification-gaps table are the source of truth for what has landed**, and both carry a `Status` column, so what follows is orientation rather than a record.

The plugin loads in REAPER and Logic, passes stereo audio through, saves state, and taps one channel into `src/dsp/ring.zig`, which the render thread reads as a trailing 20 ms window. The trace is real geometry: each inter-sample segment is an instanced quad **3.0 points** wide, shaded by distance from the segment, so caps are round and joints have no gaps ([#57](https://github.com/cboone/fosforo/issues/57)). It deposits a scalar additively into a persistent `RGBA16F` ping-pong pair ([#55](https://github.com/cboone/fosforo/issues/55)) that fades in real elapsed time with a **158.19 ms** constant ([#56](https://github.com/cboone/fosforo/issues/56)), and a resolve pass compresses that energy through extended Reinhard into one of four gradients running to white ([#60](https://github.com/cboone/fosforo/issues/60), [ADR 0019](docs/adr/0019-brightness-is-a-fixed-transfer-function.md)). The hot core ADR 0007 predicted is emergent rather than drawn. There is no colour anywhere in `shaders/scope.metal`.

**What the pixels became is checked automatically**, by `zig build smoke-trace`, which renders the shipping pipeline into a texture the backend owns and reads the result back as rows, periods and implied samples ([#51](https://github.com/cboone/fosforo/issues/51)); the judgements are pure and unit-tested in `src/gpu/verdict.zig` ([#92](https://github.com/cboone/fosforo/issues/92)). A debug build hot-reloads the shader without restarting the host ([#61](https://github.com/cboone/fosforo/issues/61)), and checks a reloaded shader's binding indices against the Zig constants ([#77](https://github.com/cboone/fosforo/issues/77)); the watcher's own bookkeeping is reachable from a test build since [#93](https://github.com/cboone/fosforo/issues/93). Every build stamps the worktree and commit it came from ([#22](https://github.com/cboone/fosforo/issues/22), [ADR 0018](docs/adr/0018-stamp-provenance-without-namespacing-identity.md)).

**The beam is velocity weighted** ([#58](https://github.com/cboone/fosforo/issues/58)), which ADR 0007 calls the single relationship that produces the whole characteristic look: a slow sweep glows solid where a fast one smears dim. The form, what it conserves, and the settled `white_headroom` are in [the trace and phosphor notes](docs/notes/trace-and-phosphor-physics.md).

**What is left of the phosphor look is filed:** bandlimited reconstruction ([#59](https://github.com/cboone/fosforo/issues/59)), which is **the next issue in the plan's order**, with [#83](https://github.com/cboone/fosforo/issues/83) behind it. [#79](https://github.com/cboone/fosforo/issues/79) closed as covered by #58 rather than fixed.

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
- **Every ordering-critical declaration is canaried against its own source**, through `src/canary.zig`, which reads a file's own text at comptime and fails `zig build test` if a stated ordering has moved. Fifteen such tests across six files cover the ring, `std.Io`, `Gate`, `Pending`, the editor's counters, `Mailbox`, `Watcher.halt` and the race harnesses' controls; [concurrency and canaries](docs/notes/concurrency-and-canaries.md) is the inventory. Adding a cross-thread declaration without one is the omission this exists to stop (ADR 0016's #91 amendment, #90, #91).
- **The vertical axis is absolute. The display never rescales itself to the signal, and over-scale rails rather than being hidden or clipped away** (ADR 0017).

## Structure

```text
build.zig                   five artifacts from one core: two libs the .clap assembles from, smoke, two race harnesses
build.zig.zon               pins Zig 0.16.0, CLAP 1.2.10, zig-objc by content hash
cmake/                      clap-wrapper integration: the AUv2, and a second .clap CI validates
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
  check-doc-budget          refuses this file above 30,000 characters; the budget job runs it
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
  adr/                      settled architecture decisions; superseded, never edited
  design/                   the source brainstorm this project came from
  notes/                    how each area behaves; living, corrected in place
  plans/todo/               active plans
  plans/done/               completed plans, kept as historical records
verification/               host captures land here; gitignored but for .gitkeep
.github/
  copilot-instructions.md   repo-wide PR review rules
  *.instructions.md         four more, fired by an applyTo glob: cmake, docs, shell, zig
  workflows/                ci, markdown, typos, gitleaks, trufflehog
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
zig build validate-shaders # needs the Metal toolchain; see docs/notes/build-system.md
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
npm ci                     # the two Markdown tools, at the versions package-lock.json pins. NOT optional
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
cmake --build build --target fosforo_all    # and every time; not fosforo_auv2, see the build-system note
```

Validate with `clap-validator validate zig-out/Fosforo.clap`. CI runs it on every push against **both** `.clap` bundles, the Zig-built one and the clap-wrapper-built `build/assets/Fosforo.clap`, so neither is only a local step, and it asserts every bundle's signature alongside them. The Audio Unit has no equivalent: `auval` cannot see this component at all, for the reason in [host verification](docs/notes/host-verification.md), so loading it in Logic is the only check there is.

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

The credentials `notarytool` needs live in a keychain profile, never on a command line, and creating one is a one-time step [the signing note](docs/notes/signing-and-notarization.md) spells out.

**The certificates on hand expire 2027-02-01 and replacing them is outstanding** ([#30](https://github.com/cboone/fosforo/issues/30)). They were issued through Xcode under the G1 intermediate rather than G2, which caps both leaves at their issuer's expiry; [signing and notarization](docs/notes/signing-and-notarization.md) has the full diagnosis and the one check that surfaces it. Nothing already signed is at risk, because a secure timestamp outlives the certificate — what stops is signing anything new, and on current sequencing that happens before v0.1.0 is cut. Re-issue from the developer portal rather than Xcode, and do not revoke the superseded pair.

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

## Maintaining this file

**This file is loaded into every session in full, and `docs/notes/` is not.** That is the whole basis for deciding where something goes. **`scripts/check-doc-budget` refuses above 30,000 characters and warns above 27,000**, and the `budget` job in `.github/workflows/markdown.yml` runs it on every push and pull request; that script's own header carries the formula those thresholds come from and the history that set them. This file reached 166,639 characters before [#117](https://github.com/cboone/fosforo/issues/117) by appending to a flat gotchas list, so the question when adding something here is not whether it is true and worth recording. It is:

- **Does an agent that has not opened anything need it?** A rule whose omission causes silent damage or a wrong pass belongs in [Rules](#rules). A rule whose omission causes a compile error or a failing test does not; the compiler is already telling them.
- **Is it a settled decision?** Then it is an ADR, and [Non-negotiables](#non-negotiables) gets one line pointing at it.
- **Is it a measurement, a refusal, or how some area behaves?** Then it is a note in [`docs/notes/`](docs/notes/README.md), and nothing is added here at all. This is the common case, and it is where a `docs: record …` commit should now land.
- **Is it what has landed?** Then it belongs in the build plan's phase tables, which carry a `Status` column, or in `CHANGELOG.md`. [Current state](#current-state) is orientation and is not a record.

**Raising the budget is not the repair.** The 40,000 it sits under is not ours to move, and every previous attempt to keep this file short by intention rather than by measurement is what produced the 166,639.
