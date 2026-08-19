# 0013. The GUI smoke harness is a build step, never part of `zig build test`

**Status:** Accepted

## Context

Nothing in `zig build test` executes a Metal or an AppKit call. Every message send in `src/gpu/metal/renderer.zig` and `src/platform/view.zig` is type-checked, by a `testing.refAllDecls` each file carries for exactly that purpose, and `zig build validate-shaders` type-checks the MSL under [ADR 0009](./0009-runtime-shader-compilation.md). Neither runs anything, and both files say so in their own test sections, naming "running the plugin in a host" as the verification that actually covers them.

That leaves a class of failure with no automated check at all, and it is the class that surfaces inside someone's DAW rather than in a build log:

- A shader that passes `metal -fsyntax-only` and then fails `newLibraryWithSource:` at runtime.
- A selector whose signature is wrong in a way the ABI tolerates until it is called.
- A retain and release imbalance across editor open and close cycles.
- A lifecycle ordering bug, such as releasing the view before the layer attached to it.

Issue #4 was verified with a temporary in-process host that drove exactly this path, then deleted rather than committed, on the grounds that keeping it is a decision rather than a detail.

The decision is forced because such a harness cannot be a normal test. It needs a GPU, and for half of what it covers a window server as well, which are machine capabilities the default build must not acquire a dependency on.

## Decision

Keep the harness, as `src/smoke.zig`, behind its own build steps, and never wire any of them into `zig build test`.

**An executable, not a test artifact.** A test binary gets `std.testing`'s assertions but must stay silent: `std.debug.print` from inside one interleaves with the test runner's stream, which the build runner reads as a failed step despite a zero exit code. `src/clap/log.zig` already documents that hazard, and its `mirror` is disabled under `builtin.is_test` for the same reason. A smoke test that cannot say what it was doing when it died is worth much less than one that can, so this reports through stderr and its own exit codes: 0 for a pass, 1 for a half that ran and failed, 2 for being invoked wrong.

**Two halves, gated differently**, because their environmental requirements differ and so do their odds of running unattended:

| Half     | Needs                        | Covers                                                               |
| -------- | ---------------------------- | -------------------------------------------------------------------- |
| `gpu`    | A Metal device, no window    | Runtime shader compilation, pipeline assembly, wrong Metal selectors |
| `appkit` | A window server and a device | View embedding, teardown order, the CLAP GUI lifecycle               |

The GPU half is required in CI. The AppKit half runs there under `continue-on-error` until an actual run settles whether a hosted runner grants an unbundled process a window-server connection.

**The GPU half reaches the device through the seam**, as `Renderer.probe`, one of the operations declared beside `init`, `deinit`, `resize`, and `frame` in `src/gpu/iface.zig`. `Renderer.init` cannot run without a window, because its last step attaches a `CAMetalLayer` to an `NSView`. `probe` is everything before that step, sharing `buildPipeline` with `init` rather than paraphrasing it, so a pass means the shipping path compiled the shader. It names no Metal type above the seam, which [ADR 0005](./0005-metal-behind-a-renderer-seam.md) requires and the comptime block in that file enforces.

**Leak checking stays outside the process**, in `scripts/smoke-leak-check` behind `zig build smoke-leaks`. A leak the harness could observe about itself is one it has not leaked.

## Consequences

**This is the only check in the project that can go red for reasons unrelated to the code.** That is the cost of being the only one that runs anything, and gating the uncertain half while keeping the certain half required is how it is contained rather than denied.

**`zig build` stays what it was.** The harness is installed by `b.addInstallArtifact` attached to the smoke steps rather than by `b.installArtifact`, so the day-to-day loop still builds only the `.clap`. `zig build test` remains hermetic, which is the property [ADR 0009](./0009-runtime-shader-compilation.md) exists to protect and the reason `validate-shaders` sits outside it too.

**An absence has to be told apart from an instrument that did not run.** `leaks` exits non-zero whenever it finds anything and always finds something: AppKit's LaunchServices chatter leaks a few hundred `NSXPCConnection` allocations per run, varying run to run. So its exit code is not the signal, and a clean grep is not either until a report is known to exist. `scripts/smoke-leak-check` asserts in order that the harness passed, that a report was produced and parses, and only then that nothing this project owns appears in it.

**Leaked Metal classes are named by the driver, not by the framework.** Dropping the command queue release in `Renderer.deinit` leaks an object `leaks` reports as `AGXG17XFamilyCommandQueue`, not as `MTLCommandQueue`: the concrete classes are private and carry the GPU family. The check matches prefixes (`MTL`, `AGX`, `NSView`, `CALayer`, `CAMetalLayer`, `IOSurface`, `IOGPU`) against the class of each leaked object, anchored on the angle bracket `leaks` writes it in, because the same names appear in stack frames on every clean run.

### What it does not cover, stated so it is not assumed

**It does not catch a reversed teardown order**, which is one of the four failures named in the context above. Verified rather than assumed: reversing `Editor.destroy` to release the view before the renderer passes both the tests and the harness, and leaks nothing. The retain counts balance either way, because the renderer holds its own reference to the layer and releases exactly that one. The ordering in `Editor.destroy` remains correct as a defensive convention and as the order that stays correct if the renderer ever touches its layer during teardown; it is simply not a defect this project can currently detect.

**Neither half runs an event loop.** The window is ordered front and the AppKit half waits on the display link's own thread rather than pumping the main run loop. That covers embedding, drawing, resizing, and teardown, and stops short of anything driven by user input.

## Amended by issue #5: proving a frame was presented

This ADR originally recorded that the harness **could not prove a frame was presented**, because `Renderer.frame` returned nothing: a build in which `nextDrawable` returned nil on every call would have passed the AppKit half. It said closing that needed a frame-outcome signal on the seam and belonged with the display link. [Issue #5](https://github.com/cboone/fosforo/issues/5) is that work, and it closed the gap rather than inheriting it.

The reason it could not be deferred is that #5 turned the gap into a total loss of coverage. `show` used to draw a frame synchronously, so every cycle exercised the render path exactly once. Once `show` starts a `CVDisplayLink` instead, the harness's `show` and `hide` run back to back and CoreVideo's first callback never arrives between them. Measured, not assumed: instrumenting the tick and running `zig build smoke-appkit` counted **zero** entries to `Renderer.frame` across ten cycles, in a run that reported `smoke: appkit ok`.

Three pieces close it:

- `frame` returns an `Outcome` (`presented`, `no_drawable`, `no_command_buffer`, `no_encoder`) rather than `void`. It is not an error set: every value but the first is a normal response to load, and modelling them as errors would push a caller toward escalating something whose only correct answer is to skip the tick.
- `Editor` counts presented frames in an atomic and exposes `framesPresented()`. `plugin.editorOf` reaches it, which is the one deliberate exception to `Instance` staying private, because CLAP has no callback that reports whether anything was drawn.
- Each AppKit cycle waits for a frame, resizes to 1280x720, waits for two more, then hides and asserts the counter **stopped** advancing.

That last assertion is new coverage rather than restored coverage: it is what keeps `hide` from silently becoming a no-op, which would cost every host with a closed editor a GPU frame every vsync.

**Both failure modes were verified by planting them.** Making `show` not start the loop, and making `nextDrawable` always report `no_drawable`, each produce `smoke: appkit FAILED: NoFramePresented`. The second is precisely the case this ADR named as undetectable.

**What it still does not prove is what the frame contained.** The counter says the pipeline ran, the drawable was acquired, and the command buffer was committed. A shader writing the wrong colour presents exactly as readily as one writing the right colour. Closing that needs a readback of the drawable and a comparison against an expected value, which is worth doing when there is something in the picture worth comparing: today it is a flat colour, and in phase 3 it will not be.

**`probe` and `init` are not the same path.** `probe` stops before `attachLayer`, so a defect confined to layer attachment is caught only by the AppKit half, which is the half that might not run in CI.
