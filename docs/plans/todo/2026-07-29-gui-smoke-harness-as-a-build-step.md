# Promote the GUI smoke harness into a maintained build step

Addresses [#19](https://github.com/cboone/fosforo/issues/19).

## Context

Nothing in `zig build test` executes a single Metal or AppKit call. Every message send in `src/gpu/metal/renderer.zig` and `src/platform/view.zig` is type-checked by a `testing.refAllDecls`, and `zig build validate-shaders` type-checks the MSL, but neither runs anything. Both files say so in their own test sections, and both name "running the plugin in a host" as the verification that actually covers them.

The failures that fall through that gap are the ones that surface inside someone's DAW: a shader that passes `metal -fsyntax-only` and then fails `newLibraryWithSource:`, a selector whose signature is wrong in a way the ABI tolerates until it is called, a retain/release imbalance across editor open and close cycles, or a teardown that releases the view before the layer attached to it.

Issue #4 was verified with a temporary in-process host that drove exactly that path, and it was deleted rather than committed because keeping it is a design decision rather than a detail. This is that decision: the harness becomes a maintained executable behind its own build steps, and the reasoning becomes an ADR.

The intended outcome is that a contributor can answer "does the editor actually come up on this machine" with one command, and that CI can answer the shader-compilation half of it unattended.

## Decisions settled before starting

These four shape everything below. The first three were confirmed with the issue's author; the fourth is the issue's own framing.

**The GPU half reaches the device through a new seam operation.** `Renderer.init` cannot run without a window, because its last step attaches a `CAMetalLayer` to an `NSView`. `src/gpu/iface.zig` grows a fourth operation, `probe`, which acquires the device, compiles the embedded `scope.metal`, assembles the pipeline, and releases all of it. `iface.zig` already says operations arrive with the phase that has a caller for them; this is that caller. It names no Metal type above the seam and reuses the private `buildPipeline`, so it is not a second copy of `init`.

**Leak checking lives in a wrapper script**, `scripts/smoke-leak-check`, behind `zig build smoke-leaks`. A script can enforce what a documented command cannot: that no plugin-owned class appears in the report, and, first, that a report was produced at all. A clean grep against output `leaks` never generated reads as a pass, which is the exact failure mode a null result invites.

**The change carries ADR 0013.** What is settled and would otherwise be relitigated in review: the harness is an executable rather than a test artifact, it is never wired into `zig build test`, and it is the one check in this project allowed to go red for reasons unrelated to the code.

**The two halves stay separate**, because their environmental requirements differ:

| Half   | Needs                        | Catches                                                                | CI status                    |
| ------ | ---------------------------- | ---------------------------------------------------------------------- | ---------------------------- |
| GPU    | A Metal device, no window    | Runtime shader compilation, pipeline assembly, wrong Metal selectors   | Required                     |
| AppKit | A window server and a device | View embedding, teardown order, retain and release across cycles       | `continue-on-error` at first |

## Work

Ordered so each step compiles and is reviewable on its own.

### 1. Parameterize the module factory in `build.zig`

`coreModule` hardcodes `src/main.zig` and takes five positional arguments that three call sites now have to thread. Gather them once:

```zig
/// Everything shared by every artifact built from this source, gathered so the
/// call sites do not thread five arguments each.
const Core = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    clap_c: *std.Build.Module,
    objc: *std.Build.Module,

    const Options = struct {
        /// Also what bounds `@embedFile`, which is why every root has to sit
        /// directly in src/ rather than in a subdirectory of it.
        root: []const u8 = "src/main.zig",
        export_entry: bool = false,
    };

    fn module(self: Core, options: Options) *std.Build.Module { ... }
};
```

The body is today's `coreModule` verbatim, with `b.path(options.root)` for the root source file. The `addOptions` block stays per-call, so each artifact gets its own `build_options`. `addAnonymousImport("scope.metal", ...)` and the five frameworks stay, which is the whole point: the harness needs both.

### 2. Add the write-side `clap_window` accessor

`src/clap/c.zig` gains the mirror of `cocoaView`:

```zig
/// The write side of `cocoaView`, for a caller playing the host.
pub fn setCocoaView(window: *c.clap_window_t, view: ?*anyopaque) void {
    window.unnamed_0.cocoa = view;
}
```

The plugin only ever reads a window the host filled in, so this exists for the harness alone. It lives here regardless, because the alternative is the harness spelling `unnamed_0` and reintroducing the generated-name fragility the read accessor exists to contain. Add a round-trip test beside the existing ones: zero a `clap_window_t`, write a pointer through `setCocoaView`, read it back through `cocoaView`. That test covers both accessors, which is more than the read side has today.

### 3. Add `probe` to the renderer seam

In `src/gpu/iface.zig`, document the operation and extend the comptime block that ADR 0005 asks a reviewer to enforce:

```zig
assertSignature("probe", @TypeOf(Renderer.probe), fn (*Diagnostics) Error!void);
```

In `src/gpu/metal/renderer.zig`, implement it as everything `init` does except `attachLayer`: `MTLCreateSystemDefaultDevice`, `newCommandQueue`, `buildPipeline`, then release all three inside the same `objc.AutoreleasePool` discipline `init` uses. Reusing `buildPipeline` is what keeps the shader path under test rather than a paraphrase of it.

On success `probe` writes what it found into `diags` (the device's `name`), so the harness can print it. That widens `Diagnostics`' stated contract from "a failure" to "a description", and the doc comment on both sides has to say so rather than leave a reader to infer it. The device name never crosses the seam as a Metal object, only as bytes in the existing buffer.

### 4. Share the host fixture

`src/clap/plugin.zig` holds `test_host` and `testNoExtensions` inside its `Tests` section. Make both `pub` and move them just above the section banner, under a comment recording that they are shared with the out-of-band harness. The name stays: the harness is a smoke test, and renaming would churn roughly twenty call sites for nothing.

`src/clap/log.zig` has a parallel `testHost(get_extension)` fixture. Folding the two together would require `log.zig` to import `plugin.zig`, which imports `log.zig`. Out of scope, and noted here so it reads as observed rather than missed.

### 5. Write the harness

New file `src/smoke.zig`. It sits directly in `src/` rather than in `src/smoke/`, because the module root is the root source file's directory and a subdirectory would put `clap/plugin.zig` out of reach and break `@embedFile("scope.metal")` in the renderer.

```text
fosforo-smoke gpu
fosforo-smoke appkit [cycles]     # cycles defaults to 10
```

A plain executable rather than a test artifact, and `src/clap/log.zig` already documents why: `std.debug.print` from inside a test binary interleaves with the runner's own stream, which the build runner reads as a failed step. A smoke test that cannot say what it was doing when it died is worth much less than one that can. Each stage prints a line before it runs; a failure prints the stage and the reason and exits non-zero.

**Both halves go through the real entry point.** `@import("main.zig")` exposes `entry`, so the harness calls `entry.init`, then `get_factory(&c.CLAP_PLUGIN_FACTORY_ID)`, then `create_plugin`, exactly as a host does. Reaching for `plugin.factory` directly would skip `src/main.zig` entirely.

**The harness offers `clap.log`.** It copies the shared `test_host` and overrides `get_extension` alone, which is sharing rather than a second fixture. This is worth the few lines twice over: it is the only runtime exercise of the plugin calling *into* a host, and in a non-Debug build the `stderr` mirror in `log.zig` is compiled out, so it is the only channel a Metal compiler diagnostic has.

The GPU half is `gpu.Renderer.probe(&diags)` and a printed device name.

The AppKit half, per cycle and inside its own `objc.AutoreleasePool` so autoreleased objects cannot pile up and confuse the leak count:

1. `NSApplication.sharedApplication` once, before any window. A nil result is the "this machine has no window server" answer and must be reported as exactly that, not as a crash.
1. One borderless `NSWindow` (style mask 0, so `NSBackingStoreBuffered` is the only AppKit constant restated here), ordered front, and its `contentView` checked non-nil.
1. `create_plugin` → `init` → `get_extension("clap.gui")` → `create` → `get_size`, asserted against `gui.default_size` → `set_parent` with a `clap_window_t` built through `clap.setCocoaView` → `show` → `hide`.
1. Teardown in both orders across cycles: `gui.destroy` then `plugin.destroy` on most, and `plugin.destroy` alone on some, since `plugin.zig`'s `destroy` claims to tear down an editor the host left open and no runtime check has ever confirmed it.

`NSWindow` and `NSApplication` calls live in this file rather than in `src/platform/`. That layer is the plugin's side of the embedding boundary; the window is the host's side, and the harness is the host.

### 6. Wire the build steps

Alongside `addShaderValidationStep` in `build.zig`, and depending on the new artifact rather than on `test`:

| Step           | Runs                                                    |
| -------------- | ------------------------------------------------------- |
| `smoke-gpu`    | `fosforo-smoke gpu`                                     |
| `smoke-appkit` | `fosforo-smoke appkit`                                  |
| `smoke`        | Both halves                                             |
| `smoke-leaks`  | `scripts/smoke-leak-check` over the AppKit half         |

Two details that decide whether the output is usable. `run.stdio = .inherit`, so the harness's progress lines reach the terminal rather than being buffered and discarded on success; and `has_side_effects = true`, so the step re-runs rather than reporting a cached result for a check whose whole subject is the machine it runs on.

The artifact is installed through `b.addInstallArtifact` attached to the smoke steps, **not** `b.installArtifact`. Plain `zig build` is the day-to-day loop and must keep producing only the `.clap`; `zig build smoke-gpu` leaves `zig-out/bin/fosforo-smoke` behind for the leak script and for running by hand.

### 7. Write the leak wrapper

`scripts/smoke-leak-check`, in the style of `cmake/narrow-au-resource-usage`: `set -eu`, no options from `shfmt`'s parser or printer groups anywhere near it. It runs

```bash
MallocStackLogging=1 leaks --atExit -- "$binary" appkit "$cycles"
```

and then makes two assertions, in this order:

1. **The positive control.** The report exists and names a nonzero total. `leaks` exits non-zero whenever it finds anything, and issue #4's verification recorded 283 to 288 leaked allocations that are all `NSXPCConnection` cycles from AppKit's LaunchServices chatter, varying run to run. So the script cannot gate on the exit code, and a grep that finds nothing has to be distinguishable from a `leaks` that never ran.
1. **No plugin-owned object appears**: `NSView`, `CAMetalLayer`, `MTLDevice`, `MTLCommandQueue`, or a render pipeline state. Any hit is a failure and the matching lines are printed.

Add the script to `.editorconfig`'s shell section in the same commit. Per the note in that file, the `shell` CI job finds shell files by shebang and will lint it immediately, while the style profile applies only once the file is named there, and the failure that asymmetry produces is `shfmt` reporting tabs against a file that matches its siblings exactly. Add `scripts` to `.paths` in `build.zig.zon` for the same reason `cmake` is there.

### 8. Add the CI job, one half required

One `smoke` job on `macos-latest` rather than two, so the checkout, the Zig install, and the build are paid once:

```yaml
- name: Smoke-test the GPU path
  run: zig build smoke-gpu

- name: Smoke-test the AppKit path
  id: appkit
  continue-on-error: true
  run: zig build smoke-appkit

- name: Report whether the runner granted a window server
  if: always()
  run: echo "::notice::AppKit half: ${{ steps.appkit.outcome }}"
```

The third step is the experiment the issue asks for, and it runs on this PR. `continue-on-error` on the middle step is what makes the answer free: an unsupported runner produces a notice rather than a red build. The decision rule, stated before the result is known so it cannot be rationalized afterward: if the AppKit half passes on the first run and on one re-run, drop `continue-on-error` in a follow-up; if it fails for want of a window server, leave the step in place with the flag and record the finding in ADR 0013's consequences, since a job that reports the runner's capability is still worth its seconds.

The workflow's comments carry the reasoning for every job in it, so this one gets the same treatment: why the GPU half needs no Metal toolchain (runtime compilation, ADR 0009) and therefore does not belong in the `shaders` job, and why one half is gated and the other is not.

### 9. Documentation

- **`docs/adr/0013-gui-smoke-harness-as-a-build-step.md`**, plus its row in `docs/adr/README.md`.
- **`AGENTS.md`** (`CLAUDE.md` is a symlink to it): the four commands in Development; `src/smoke.zig` and `scripts/` in the structure map; and one gotcha covering the executable-not-test-artifact reason, the `zig build test` exclusion, and that this is the only check that can go red for machine reasons.
- **`CHANGELOG.md`**, under `Unreleased` → `Added`, linking #19 in the existing style.

## Files

| Path                                       | Change                                                  |
| ------------------------------------------ | ------------------------------------------------------- |
| `build.zig`                                | `Core` struct, the smoke artifact, four steps           |
| `src/smoke.zig`                            | New. The harness                                        |
| `src/clap/c.zig`                           | `setCocoaView` and a round-trip test                    |
| `src/clap/plugin.zig`                      | `test_host` and `testNoExtensions` made `pub` and moved |
| `src/gpu/iface.zig`                        | `probe` on the seam, one more `assertSignature`         |
| `src/gpu/metal/renderer.zig`               | `Renderer.probe`, reusing `buildPipeline`               |
| `scripts/smoke-leak-check`                 | New. The `leaks --atExit` wrapper                       |
| `.editorconfig`, `build.zig.zon`           | Register the new script and its directory               |
| `.github/workflows/ci.yml`                 | The `smoke` job                                         |
| `docs/adr/0013-*.md`, `docs/adr/README.md` | New ADR and its index row                               |
| `AGENTS.md`, `CHANGELOG.md`                | Commands, structure map, gotcha, changelog entry        |

Reused rather than rewritten: `plugin.test_host`, `clap.cocoaView`, `gui.default_size`, `gpu.Diagnostics`, `buildPipeline`, `objc.AutoreleasePool`, and `platform.assertMainThread`.

## Verification

Hermetic, and must all pass unchanged:

```bash
zig fmt --check build.zig src/
zig build test
zig build
zig build validate-shaders
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck
```

The new steps, on this machine:

```bash
zig build smoke-gpu       # names the device, compiles scope.metal, builds the pipeline
zig build smoke-appkit    # opens a window, embeds the editor, cycles it
zig build smoke-leaks     # 400 cycles under leaks --atExit
```

Then the checks that prove the harness is an instrument rather than a decoration. A green smoke test means nothing until each of these has been seen to fail:

1. Break `shaders/scope.metal` in a way `metal -fsyntax-only` catches, and confirm `smoke-gpu` fails with the compiler's own diagnostic rather than a generic message.
1. Rename `clear_fragment` in the shader only, and confirm the failure names the missing function.
1. Plant a wrong selector signature in `renderer.zig`, and confirm the harness reaches it where `zig build test` does not.
1. Reverse the teardown order in `Editor.destroy` (view before renderer) and confirm the AppKit half notices.
1. Remove one `release` from `Renderer.deinit` and confirm `smoke-leaks` fails, naming the class. This is the one that proves the leak script's grep works, and it is the reason the script asserts a report was produced before it trusts a clean one.

Finally, `clap-validator validate zig-out/Fosforo.clap` must report the same counts as before, since none of this touches the plugin's behaviour, and the CI run on the PR settles the window-server question.

## Known limits, stated rather than left to be discovered

**The harness cannot prove a frame was presented.** `Renderer.frame` returns nothing by design: a nil drawable is a skipped tick, not an error. So a build where `nextDrawable` returned nil on every call would pass the AppKit half. Closing that needs a frame-outcome signal on the seam, which belongs with issue #5's render loop rather than here.

**Neither half runs an event loop.** The window is ordered front and the plugin's `show` draws once; nothing pumps `NSApp`. That is enough for embedding and teardown and short of what a user sees.

**`probe` and `init` are not the same path.** `probe` stops before `attachLayer`, so a defect confined to layer attachment is caught only by the AppKit half, which is the half that might not run in CI.

## Results

Every hermetic check passes unchanged: `zig fmt --check`, `zig build test`, `zig build`, `zig build validate-shaders`, `shfmt -d`, and `shellcheck`. `clap-validator` reports 21 passed and 0 failed against the Zig-built bundle, the same counts as before, which is the expected outcome for a change that adds no plugin behaviour.

Both halves pass on this machine. `smoke-gpu` acquires the device (`Apple M5 Max`), compiles `scope.metal` at runtime from the embedded source, and assembles the pipeline. `smoke-appkit` connects to `NSApplication`, opens a 960x540 window at backing scale 2, resolves the factory through `clap_entry`, and runs ten open and close cycles clean, with the plugin's diagnostics arriving twice over: once through the harness's `clap.log` and once through the `stderr` mirror a debug build compiles in.

`smoke-leaks` at 400 cycles reports 288 leaks for 18816 total leaked bytes, all of them AppKit's own `NSXPC` chatter, and none belonging to this project. The 40-cycle run reports the identical 288 and 18816, which is the flatness the criterion asks for stated as a measurement rather than an impression.

### The controls, which are what make the pass mean anything

| Planted defect                              | `zig build test` | `smoke-gpu`                       | `smoke-appkit` | `smoke-leaks`                 |
| ------------------------------------------- | ---------------- | --------------------------------- | -------------- | ----------------------------- |
| Syntax error in `scope.metal`               | passes           | fails, with the file and line     | —              | —                             |
| `clear_fragment` renamed in the shader only | passes           | fails, naming the missing entry   | —              | —                             |
| `newCommandQueue` misspelled                | passes           | aborts, naming class and selector | —              | —                             |
| `self.queue.release()` dropped              | passes           | —                                 | passes         | fails: 6688 leaks against 288 |

**One control did not behave as predicted, and the plan was wrong rather than the code.** Reversing `Editor.destroy` to release the view before the renderer passes `zig build test`, passes `smoke-appkit`, and leaks nothing. The retain counts balance either way: the renderer holds its own reference to the layer and releases exactly that one, so the order in which the two are dropped changes nothing observable. The ordering stays as it is, and stays correct, but as a defensive convention rather than as something this project can detect. ADR 0013 records it under what the harness does not cover, because the issue lists a reversed teardown as one of the four failures it wanted caught and claiming coverage here would be false.

**The leak script's class patterns came from evidence, not from the headers.** Dropping the command queue release leaks an object `leaks` reports as `AGXG17XFamilyCommandQueue` and `MTLPrivateDataTable`. Issue #4's methodology named `MTLDevice` and `MTLCommandQueue`, and a grep for those would have called that planted leak clean: the concrete Metal classes are driver-private and carry the GPU family. The check matches prefixes against the class of each leaked object, anchored on the angle bracket `leaks` writes it in, because the same strings appear in stack frames on every clean run and matching them there produces a false failure.

**`std.process.args()` no longer exists.** Zig 0.16 hands argv to `main` through a `std.process.Init.Minimal` parameter, which is how `src/smoke.zig` reads its arguments.

## Out of scope

- Wiring anything here into `zig build test`. ADR 0009's reasoning applies unchanged, and ADR 0013 restates it for this step.
- Screenshot or pixel comparison of any kind. A drawable that is `framebufferOnly` cannot be read back, and changing that to suit a test would change the shipping renderer.
- Folding `log.zig`'s `testHost` into the shared fixture, which needs an import cycle broken first.
- `auval`, which remains unverified for environment reasons that predate this work.

## Commits

Small commits at each logical boundary, all referencing `(#19)`:

1. `refactor: gather what every artifact's module shares (#19)`
1. `feat: add the write-side accessor for clap_window's cocoa view (#19)`
1. `feat: let the renderer seam probe a device without a window (#19)`
1. `refactor: share the bare host fixture with out-of-band callers (#19)`
1. `test: add the GUI smoke harness and its build steps (#19)`
1. `test: check the smoke harness for leaks under leaks --atExit (#19)`
1. `ci: smoke-test the GPU path, and the AppKit path experimentally (#19)`
1. `docs: record the smoke harness as a build step in an ADR (#19)`
