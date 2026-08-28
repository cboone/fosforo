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

**The GPU half reaches the device through the seam**, as `Renderer.probe`, one of the operations declared beside `init`, `deinit`, `resize`, `upload`, `frame`, and `liveWindowBuffers` in `src/gpu/iface.zig`. `Renderer.init` cannot run without a window, because its last step attaches a `CAMetalLayer` to an `NSView`. `probe` is everything before that step, sharing `buildPipelines` with `init` rather than paraphrasing it, so a pass means the shipping path compiled the shader. It names no Metal type above the seam, which [ADR 0005](./0005-metal-behind-a-renderer-seam.md) requires and the comptime block in that file enforces.

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

- `frame` returns an `Outcome` (`presented`, `no_drawable`, `no_frame_slot`, `no_command_buffer`, `no_encoder`) rather than `void`. It is not an error set: every value but the first is a normal response to load, and modelling them as errors would push a caller toward escalating something whose only correct answer is to skip the tick.
- `Editor` counts presented frames in an atomic and exposes `framesPresented()`. `plugin.editorOf` reaches it, which is the one deliberate exception to `Instance` staying private, because CLAP has no callback that reports whether anything was drawn.
- Each AppKit cycle waits for a frame, resizes to 1280x720, waits for two more, then hides and asserts the counter **stopped** advancing.

That last assertion is new coverage rather than restored coverage: it is what keeps `hide` from silently becoming a no-op, which would cost every host with a closed editor a GPU frame every vsync.

**Both failure modes were verified by planting them.** Making `show` not start the loop, and making `nextDrawable` always report `no_drawable`, each produce `smoke: appkit FAILED: NoFramePresented`. The second is precisely the case this ADR named as undetectable.

**What it still does not prove is what the frame contained.** The counter says the pipeline ran, the drawable was acquired, and the command buffer was committed. A shader writing the wrong colour presents exactly as readily as one writing the right colour. Closing that needs a readback of the drawable and a comparison against an expected value, which is worth doing when there is something in the picture worth comparing: today it is a flat colour, and in phase 3 it will not be.

**`probe` and `init` are not the same path.** `probe` stops before `attachLayer`, so a defect confined to layer attachment is caught only by the AppKit half, which is the half that might not run in CI.

## Amended by issue #38: what the harness can assert about the samples

Issue [#38](https://github.com/cboone/fosforo/issues/38) drew the first trace and asked, as a checkbox, whether `zig build smoke-appkit` could assert more than that a frame was presented. It can, and the thing it now asserts is not the thing the section above predicted.

**Two transcription errors in this document were corrected in place while writing this**, and are named here because a silent edit to an ADR looks like exactly what this directory's rules forbid. The `Outcome` list omitted `no_frame_slot`, added by [#37](https://github.com/cboone/fosforo/issues/37); the list of seam operations `probe` sits beside omitted `upload` and `liveWindowBuffers`, added by the same issue. Neither was a decision.

### A drawable readback was refused, and the criterion above is wrong

The paragraph above says a readback "is worth doing when there is something in the picture worth comparing: today it is a flat colour, and in phase 3 it will not be." #38 produces a picture, and a readback is still not worth it, so the criterion needs sharpening rather than waiting on.

The cost is not effort. `attachLayer` sets `setFramebufferOnly: true`, and reading a drawable back means dropping that: changing the shipping renderer's storage mode, in every host, on every frame, so that a check can run in CI. The plan for issue #19 already refused precisely that, in these words: "A drawable that is `framebufferOnly` cannot be read back, and changing that to suit a test would change the shipping renderer." A harness-only readable path is worse rather than a way around it, because it inverts the principle `probe` is built on: `probe` shares `buildPipelines` with `init` *rather than paraphrasing it*, and a path the shipping renderer never takes is a paraphrase. The comparison also needs a golden image, in a project with no image comparison of any kind, pinning the vertical scale, the horizontal mapping, the drawable size and Metal's line rasterization rule against a shader phase 3 replaces wholesale.

**The real criterion is when the picture is expensive enough to justify a golden and stable enough that the golden does not churn.** That is after phase 3's look settles, not at its start.

### `windowsTorn() == 0` was a vacuous assertion, and this document said why

Issue [#37](https://github.com/cboone/fosforo/issues/37) added an assertion that no window tore across a cycle. It is satisfied by three worlds it cannot tell apart: reads happened and none tore; reads happened and none *could* tear, because the harness stops calling `process` before the editor opens and the producer is stationary; and **no read ever happened at all**. `Editor.readWindow` returns before either counter when its history pointer is null or its window count is zero, so a `plugin.init` that dropped its history wiring, an `activate` that dropped `setWindow`, or a widened early return would all leave the count at zero and read as healthy.

The Consequences above already state the rule that breaks, about `leaks`: **an absence has to be told apart from an instrument that did not run.**

### What the harness now asserts

`Editor` counts windows read intact and handed across the seam, behind `windowsUploaded()`, beside `framesPresented()` and `windowsTorn()`. It is the same split this ADR already made once, on the same object: #5 turned "the loop is running" and "the loop is drawing" into two claims, and #38 turns "the loop is drawing" and "the loop is drawing the samples" into two more. Following the precedent is not extending it.

Four assertions, each verified by planting the defect it names:

| Plant                                                   | Result                                       |
| ------------------------------------------------------- | -------------------------------------------- |
| Drop `self.editor.history = &self.history` from `init`  | `smoke: appkit FAILED: NoWindowUploaded`     |
| Drop `setWindow` from `activate`                        | `NoWindowUploaded`                           |
| `readWindow` returns early once one window has uploaded | `UploadsStopped`                             |
| Drop `setWindow(0)` from `deactivate`                   | `UploadedWhileDeactivated`, naming 2 windows |
| Clear `window` in `Editor.destroy`                      | `ReopenedEditorStalled`                      |
| Make `Renderer.upload` a no-op                          | **Passes.** See the limit below              |

**The first two are not harness-only coverage, which was measured rather than assumed.** Both were predicted to be unique to the harness and both also fail `zig build test`, against the existing tests "init points the editor at the instance's history" and "activate publishes a window to the editor and deactivate takes it away". They are worth keeping as controls that the two levels agree, and not worth citing as coverage nothing else provides.

**The third plant had to be strengthened before it tripped.** A `readWindow` that stopped once *one frame* had been presented still uploaded a second window, because the count is captured after the first wait and the assertion asks only that it advanced. Stopping once one window had uploaded is the defect the assertion actually names, and that one trips it. What the assertion catches is a path that stopped, not one that slowed.

**`ReopenedEditorStalled` is the one that closes something previously untestable.** `Editor.destroy` deliberately keeps `history` and `window` while clearing everything else, and its comment says clearing either "would leave the second editor reading nothing for the rest of the activation, with no symptom but a trace that never moved." Nothing tested that, and it is the Logic path specifically: clap-wrapper's AUv2 view destroys rather than hides, so every open of the plugin window there is a `destroy` and `create` on a still-activated instance. Each cycle now reopens an editor before the deactivate block, which makes the comment enforceable.

**The limit, stated in the words `live_windows` already uses.** A `Renderer.upload` that does nothing passes every assertion above: the counter proves the window was read and handed across the seam, not that the backend copied it. Changing `upload` to return a count so the harness could catch that would be shaping the seam to the harness, which is what `probe`'s docstring is careful to say it is not.

### A second Metal resource, checked rather than assumed

The trace needs a second `MTLRenderPipelineState`, and this document's own rule is that a Metal resource which is not a buffer must be checked against `leaks` with a planted leak before `smoke-leaks` is assumed to cover it. Dropping the trace pipeline's release takes a 400-cycle run from 288 leaks and 18,816 bytes to 9,880 leaks and 8,555,776 bytes, and `scripts/smoke-leak-check` reports that objects belonging to this project were leaked. So a pipeline state is visible to `leaks` where an `MTLBuffer` is not, and there is no second blind spot of the `live_windows` kind here.

## Amended by issue #55: a third resource kind, and the first with no instrument

The rule this document set under #38 is that a Metal resource which is not a buffer must be checked against `leaks` with a planted leak before `smoke-leaks` is assumed to cover it. Its third application produced the worst answer so far, and it changes what the harness is for.

**An `MTLTexture` is invisible to `leaks`, as an `MTLBuffer` is.** Dropping one release from `releaseAccumulation` and running 20 cycles reports 283 leaks for 18,560 bytes against a clean 288 for 18,816. The leaking run reports *fewer* bytes than the clean one, none of the 250 leaked classes is a texture under any name, and the leak is real at roughly 46 MB per cycle.

**Peak RSS is also blind, which does not follow from the buffer case and is the finding worth recording.** A leaked `MTLBuffer` moved peak RSS from 47.7 MB to 57.7 MB and was catchable that way, so a leaked texture was expected to be far more visible still, at 33 to 59 MB per cycle rather than 96 KiB. It does not move it at all: 44.3 MB against 44.1 MB clean at 40 cycles, while leaking nearly two gigabytes. Shared storage is in the process's resident set and `MTLStorageModePrivate` is not.

So `gpu.Renderer.liveAccumulationTextures` is not the better of two instruments in the way `liveWindowBuffers` is. It is the only one, and the seam grew an eighth operation to carry it.

**What the counter catches and what it does not, both planted.** It catches an allocation never handed back: removing the release from `replaceAccumulation` fails `smoke-appkit` with 20 textures outstanding across 10 cycles. It does not catch a `releaseAccumulation` that stops sending `release`, because the count returns either way, and that hole is worse here than for the window buffers precisely because RSS backstops that one and backstops nothing for this.

There is also a new obligation the window buffers never had. They are allocated once and released once; these are rebuilt on every resize that changes the pixel count, so the resize path has to decrement too. `oneCycle` now performs four resizes rather than one, including a shrink to the minimum and a wrapped-negative height, so `smoke-leaks` exercises that path 400 times.

### Two defects the harness cannot see at all, and what can

Worth recording beside the leak result, because both were expected to be positive controls proving the harness reaches new code, and both pass:

- The accumulation descriptor without `MTLTextureUsageRenderTarget`.
- The resolve pipeline compiled against the accumulation's pixel format rather than the drawable's.

Metal validates neither without the validation layer enabled, so both are undefined behaviour that happens to present a frame while the picture is wrong, and `smoke-appkit` reports a clean run. `MTL_DEBUG_LAYER=1` names both exactly, as `RenderPass Descriptor Validation` and `Set Render Pipeline State Validation`.

That is a class this document did not previously account for: not a resource leak, not a lifecycle error, but a binding the API accepts and the hardware ignores. The harness is the wrong instrument for it and the validation layer is the right one. Whether that earns a build step belongs to [#63](https://github.com/cboone/fosforo/issues/63), which is where the cost of adding a check that can go red for reasons unrelated to the code is already being weighed.

### And the limit that matters most, restated

None of the above sees whether the picture is bright enough to look at. #55 shipped a resolve gain that rendered a sine as a black display, and it passed 160 unit tests, both smoke halves, `smoke-leaks`, `clap-validator` and the validation layer. It was found by eye in under a minute. The harness answers whether frames are presented and whether resources balance; it has never answered what the pixels became, and #51 remains the issue that would change that.

## Amended by issue #63: the leak check enters CI, and a fourth instrument is refused

`zig build smoke-leaks` had never run anywhere but a keyboard. It now runs in the `smoke` job on every push, at 40 cycles rather than 400, under `continue-on-error` on the same reasoning as the AppKit half: it *is* the AppKit half with an instrument wrapped around it, so it inherits the dependency on a hosted runner granting an unbundled process a window-server connection. Promoting it, like promoting `smoke-appkit`, stays a separate decision about what may block a merge.

**Two of the numbers this document has been quoting were stale, and both were stale in the direction that flatters the check.**

Depth buys nothing either assertion reads. Across five runs at 40 and at 400 cycles the report gave 288 leaks for 18,816 bytes four times and 285 for 18,464 once, so a tenfold change in depth moves the figure by under 2% and only run to run, because AppKit's chatter is a fixed startup cost rather than a per-cycle one. The rationale `scripts/smoke-leak-check` carried for its 400 — that at 400 a per-cycle leak more than doubles the total, and at 10 it would sit inside the run-to-run variation — was an argument about totals that no assertion used, over a variation that is not there. What depth does buy is repetition of the rare paths inside `oneCycle`, and 40 reaches `plugin.destroy`'s teardown ten times and each of the four resizes forty.

Depth costs everything, and more than it did. The 51.8 s figure for 400 cycles predates the four resizes recorded above; the same run now takes **113 s**, and the harness is bound by display refresh rather than by CPU, so a hosted runner at half this machine's rate pays roughly twice that again. 40 cycles takes 13 s.

### The rule this document set was too narrow, and the gap was live

The rule since #38 has been that *a Metal resource which is not a buffer* must be checked against `leaks` with a planted leak. That is now **any allocation**, because the narrower version excluded the case that turned out to be broken.

`scripts/smoke-leak-check` judged by an allowlist of Objective-C class prefixes, and this project's own allocations do not have a class. Dropping `self.history.deinit` from `plugin.destroy` and running 40 cycles leaks roughly **42.6 million bytes against a clean 18,816**, and the check called it clean: `leaks` finds the block, and writes it as something the `<ClassName 0xADDRESS>` extractor does not match. Two thousand times the baseline, reported as nothing at all, in the check that was about to become this project's leak gate.

A bound on total leaked bytes closes it. The two assertions are complementary rather than one subsuming the other, which is why both run and why the class check runs first: a leaked command queue is 137,152 bytes, *under* the bound, and is caught only by its class; a leaked history ring has no class and is caught only by the bound.

**The leak count is not a discriminator.** Across two runs of that planted leak the report gave 232 leaks and then 328, against a clean 288 that does not move at all. The count wanders in both directions while forty megabytes go missing, and one of those two runs would have read as an improvement.

### The peak-RSS slope, considered and refused

The same issue also proposed running the harness at two cycle counts and bounding the growth in peak resident set size. It is not being added, and the reasoning is recorded here rather than in a comment on a check that does not exist.

Its case rested on one measurement this document already carries: a leaked window buffer ring moves peak RSS from 47.7 MB to 57.7 MB while `leaks` reports clean. That is true and it is not sufficient, for three reasons.

**The defect it demonstrably catches is already caught, more cheaply and exactly.** `src/smoke.zig` asserts `liveWindowBuffers() == 0` after the cycle loop, inside a step that already runs on every push, and the same planted defect fails it at 10 cycles with a named error and an exact count rather than at 440 cycles against two calibrated constants.

**What is left of its coverage is the failure this project has already declined to chase.** Subtracting the counters leaves a `releaseWindows` that decrements without releasing — the hole recorded above, which is equally uncovered for the accumulation textures, so the guard would be half-applied by construction.

**Its sensitivity is proportional to its cost, and it is blind to the resource that now dominates.** Baseline growth is 18.8 MB across 40 to 400 cycles with 1.5 MB of run-to-run spread per endpoint, so a five-sigma ceiling sits near 30 MB and the smallest detectable per-cycle leak is about 0.031 MB against a leaked ring's 0.048 MB of resident pages: a margin of 1.5x. Halving the span doubles that floor above the defect, so it cannot be made cheaper without ceasing to work. And a leaked accumulation texture moves peak RSS by 0.2 MB while leaking nearly two gigabytes, so it does not see `MTLStorageModePrivate` storage at all.

The short form, and the thing to re-read before proposing it again: **it is a calibrated instrument for a defect an uncalibrated one already catches, and it is blind to the defect nothing else catches.** The byte bound above is the opposite trade and is why it was affordable — 56 times above the observed baseline and 40 times below the smallest leak it is for, so it needs no calibration against the machine it runs on.

The row nothing covers is left uncovered deliberately. Saying so is what stops it being rediscovered as a gap worth a fourth instrument.
