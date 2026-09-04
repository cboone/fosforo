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

**Halves, gated differently**, because their environmental requirements differ and so do their odds of running unattended. Two when this was written; the third arrived with #51 and is recorded in the amendment at the foot of this document, corrected here in place rather than left stale:

| Half     | Needs                        | Covers                                                               |
| -------- | ---------------------------- | -------------------------------------------------------------------- |
| `gpu`    | A Metal device, no window    | Runtime shader compilation, pipeline assembly, wrong Metal selectors |
| `trace`  | A Metal device, no window    | What the shader drew: the mapping, the rail, the resolve, the decay  |
| `appkit` | A window server and a device | View embedding, teardown order, the CLAP GUI lifecycle               |

The GPU half is required in CI. The AppKit half runs there under `continue-on-error` until an actual run settles whether a hosted runner grants an unbundled process a window-server connection.

Both sentences above are the decision as it was taken and are superseded rather than corrected: #51 added a third half that is required too, and #72 discharged the condition the second names. The amendments at the foot of this document carry both. The *table* is corrected in place, on the precedent the #38 amendment set for a stale list, because it enumerates what exists rather than stating a decision.

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

So `gpu.Renderer.liveTextures` — `liveAccumulationTextures` until #60 renamed it — is not the better of two instruments in the way `liveWindowBuffers` is. It is the only one, and the seam grew an eighth operation to carry it.

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

**Superseded by the #51 amendment below, which closed it.** Left standing rather than edited away, because the paragraph is the argument that issue was built against, and because the defect it describes is now the worked example of what the new half catches.

## Amended by issue #63: the leak check enters CI, and a fourth instrument is refused

`zig build smoke-leaks` had never run anywhere but a keyboard. It now runs in the `smoke` job on every push, at 40 cycles rather than 400, under `continue-on-error` on the same reasoning as the AppKit half: it *is* the AppKit half with an instrument wrapped around it, so it inherits the dependency on a hosted runner granting an unbundled process a window-server connection. Promoting it, like promoting `smoke-appkit`, stays a separate decision about what may block a merge.

**Two of the numbers this document has been quoting were stale, and both were stale in the direction that flatters the check.**

Depth buys nothing either assertion reads. Across five runs at 40 and at 400 cycles the report gave 288 leaks for 18,816 bytes four times and 285 for 18,464 once, so a tenfold change in depth moves the figure by under 2% and only run to run, because AppKit's chatter is a fixed startup cost rather than a per-cycle one. The rationale `scripts/smoke-leak-check` carried for its 400 — that at 400 a per-cycle leak more than doubles the total, and at 10 it would sit inside the run-to-run variation — was an argument about totals that no assertion used, over a variation that is not there. What depth does buy is repetition of the rare paths inside `oneCycle`, and 40 reaches `plugin.destroy`'s teardown ten times and each of the four resizes forty.

Depth costs everything, and more than it did. The 51.8 s figure for 400 cycles predates the four resizes recorded above; the same run now takes **113 s**, and the harness is bound by display refresh rather than by CPU, so a hosted runner at half this machine's rate pays roughly twice that again. 40 cycles takes 13 s.

### The rule this document set was too narrow, and the gap was live

The rule since #38 has been that *a Metal resource which is not a buffer* must be checked against `leaks` with a planted leak. That is now **any allocation**, because the narrower version excluded the case that turned out to be broken.

`scripts/smoke-leak-check` judged by an allowlist of Objective-C class prefixes, and this project's own allocations do not have a class. Dropping `self.history.deinit` from `plugin.destroy` and running 40 cycles leaks roughly **42.6 million bytes against a clean 18,816**, and the check called it clean: `leaks` finds the block, and writes it as something the `<ClassName 0xADDRESS>` extractor does not match. Two thousand times the baseline, reported as nothing at all, in the check that was about to become this project's leak gate.

A bound on total leaked bytes closes it, at one mebibyte: 56 times above the observed baseline and 40 times below the smallest leak it is for, so it needs no calibration against the machine it runs on. That was the property being bought rather than a happy accident, and the first three CI runs are why it was worth buying: `macos-latest` reported 18,656, 18,816 and **14,080** bytes, a 25% spread against the 2% seen across six runs on the development machine. A bound tight enough to be called calibrated would need re-measuring against a runner that noisy, and re-measuring again whenever the image refreshed. This one has 74x of room at the low end and 56x at the high end, so it does not. The two assertions are complementary rather than one subsuming the other, which is why both run and why the class check runs first: a leaked command queue is 137,152 bytes, *under* the bound, and is caught only by its class; a leaked history ring has no class and is caught only by the bound.

**The leak count is not a discriminator.** Across two runs of that planted leak the report gave 232 leaks and then 328, against a clean 288 that does not move at all. The count wanders in both directions while forty megabytes go missing, and one of those two runs would have read as an improvement.

### The peak-RSS slope, considered and refused

The same issue also proposed running the harness at two cycle counts and bounding the growth in peak resident set size. It is not being added, and the reasoning is recorded here rather than in a comment on a check that does not exist.

Its case rested on one measurement this document already carries: a leaked window buffer ring moves peak RSS from 47.7 MB to 57.7 MB while `leaks` reports clean. That is true and it is not sufficient, for three reasons.

**The defect it demonstrably catches is already caught, more cheaply and exactly.** `src/smoke.zig` asserts `liveWindowBuffers() == 0` after the cycle loop, inside a step that already runs on every push, and the same planted defect fails it at 10 cycles with a named error and an exact count rather than at 440 cycles against two calibrated constants.

**What is left of its coverage is the failure this project has already declined to chase.** Subtracting the counters leaves a `releaseWindows` that decrements without releasing — the hole recorded above, which is equally uncovered for the accumulation textures, so the guard would be half-applied by construction.

**Its sensitivity is proportional to its cost, and it is blind to the resource that now dominates.** Baseline growth is 18.8 MB across 40 to 400 cycles with 1.5 MB of run-to-run spread per endpoint, so a five-sigma ceiling sits near 30 MB and the smallest detectable per-cycle leak is about 0.031 MB against a leaked ring's 0.048 MB of resident pages: a margin of 1.5x. Halving the span doubles that floor above the defect, so it cannot be made cheaper without ceasing to work. And a leaked accumulation texture moves peak RSS by 0.2 MB while leaking nearly two gigabytes, so it does not see `MTLStorageModePrivate` storage at all.

The short form, and the thing to re-read before proposing it again: **it is a calibrated instrument for a defect an uncalibrated one already catches, and it is blind to the defect nothing else catches.** The byte bound above is the opposite trade and is why it was affordable — 56 times above the observed baseline and 40 times below the smallest leak it is for, so it needs no calibration against the machine it runs on.

The row nothing covers is left uncovered deliberately. Saying so is what stops it being rediscovered as a gap worth a fourth instrument.

## Amended by issue #72: the AppKit half becomes required, and the leak half deliberately does not

Three sentences above are superseded rather than corrected, and are left standing on this directory's rule that an in-place edit to an ADR is for a transcription error and nothing else. The Decision's "the AppKit half runs there under `continue-on-error` until an actual run settles whether a hosted runner grants an unbundled process a window-server connection" is the decision as it was taken, and the condition it names has been discharged rather than removed. The Consequences' "gating the uncertain half while keeping the certain half required is how it is contained rather than denied" is the counter-argument this issue was weighed against, and erasing it would erase what the decision cost. #63's "promoting it, like promoting `smoke-appkit`, stays a separate decision about what may block a merge" is the deferral this section answers.

**The rule was written before the answer was known.** The plan for [issue #19](https://github.com/cboone/fosforo/issues/19) recorded it in these words: "if the AppKit half passes on the first run and on one re-run, drop `continue-on-error` in a follow-up; if it fails for want of a window server, leave the step in place with the flag and record the finding in ADR 0013's consequences, since a job that reports the runner's capability is still worth its seconds." Measured from the Actions API on 2026-08-29, the `smoke` job has 68 recorded runs, 65 of which completed and 3 of which the concurrency group cancelled, and `Smoke-test the AppKit path` **succeeded on all 65**. It has never failed and never timed out. A hosted macOS runner does grant an unbundled process a window-server connection, and the rule saying what to do about it was set down by someone who did not know that.

**The step's cost is not the reason for anything and is recorded anyway.** All 65 durations fall between 0 and 5 seconds against a `timeout-minutes: 2`, a margin of 24x. That timeout was a label while the step could not fail the job; it is now a budget, because a wedged AppKit call is the one failure this step has that is not an assertion, and 120s is what stands between it and the other six minutes of the job's ceiling.

**One consequence arrives free and is worth stating before it surprises someone.** The leak step carries `continue-on-error` and no `if:` condition, so a failing AppKit half now *skips* it rather than running it, and the notice reads `leaks: skipped`. That is this document's own assertion order enforced one level up: a leak report over a run that fell over partway through describes a process that never reached the teardown being measured.

### What the sample cannot show, and why that retires a checkbox rather than ticking it

Issue #72 asked for the outcome "across at least one runner image refresh". That evidence does not exist and cannot be waited for on any schedule this project controls.

**Every one of the 65 runs used the same image: `macos-26-arm64`, version `20260728.0273.1`.** The first was on 2026-07-30 and the latest on 2026-08-29, thirty days apart. This repository's entire CI history contains exactly one image refresh, `20260720.0258.1` to `20260728.0273.1`, and it landed the day before the smoke job did. So this job has never crossed an image boundary, and the issue's claim that the sample spans "the `macos-latest` migration to macOS 26" is false: nothing here has ever run CI on anything but `macos-26-arm64`. Upstream corroborates the cadence rather than the hope: the most recent 30 `actions/runner-images` releases run through 2026-08-25 and contain no macOS release at all.

What replaces the checkbox is instrumentation rather than patience. `Report what the smoke halves concluded` now prints `ImageOS` and `ImageVersion` on every run, so the first run after a refresh is attributable at a glance: a red AppKit half beside a version nobody has seen before is a different event from a red AppKit half on the image 65 runs have already passed on. Both are undocumented runner-image variables rather than Actions ones, so both carry defaults, and the `Set up job` log group stays the positive control if they ever read `unknown`.

### The two halves are not symmetric, and that is the whole of why one moves and the other does not

`smoke-leaks` keeps `continue-on-error`. That is not caution left over from the AppKit half. The reason #63 gave for it, that the leak step *is* the AppKit half with an instrument wrapped around it and therefore inherits its dependency on the runner, has stopped applying now that the dependency is settled. A different and better reason has taken its place.

**`smoke-appkit` can only fail on its own assertions plus one runner capability.** `framesPresented`, `windowsUploaded`, `liveWindowBuffers`, `liveTextures`, and the window-server connection that 65 runs have now answered. Every one of those is a fact about this repository.

**`smoke-leaks` additionally judges the runner's own AppKit chatter.** `scripts/smoke-leak-check` matches leaked classes against `^(NSView|CALayer|CAMetalLayer|IOSurface|IOGPU|_?MTL|AGX)`, and several of those prefixes name classes that AppKit, CoreAnimation and the window server allocate on their own account. An `IOSurface` or an `NSView` leaked by a framework, for reasons that have nothing to do with this project, fails that step, and nothing in this repository would be wrong. That is the Consequences sentence above, exactly and specifically, and it applies to the leak step and not to the AppKit one.

The byte total tells the same story from the other side, and the figure quoted under #63 is now stale in the direction that flatters the check less. Nine completed leak runs reported 18,656, 18,816, 14,080, 18,816, 14,080, 9,728, 18,624, 18,624 and 18,624 bytes: a low of 9,728 against a high of 18,816. **Quote that as a ratio rather than a percentage, because the two conventions differ by a factor of two and both are in circulation here.** By the `(max-min)/max` convention `scripts/smoke-leak-check` used for its "25% spread", nine runs give 48%; the naive `(max-min)/min` gives 93% for the same runs. As a ratio, which is unambiguous, the first three runs were **1.34x** and nine runs are **1.93x**. The bound of 1,048,576 absorbs it without effort, since the worst figure observed is 1.8% of it, and the low-end headroom the #63 section records as 74x is now **107x**. That is exactly the looseness the bound was bought for. But a number that moves by a factor of two between runs is the runner's number rather than this project's, and a check whose input moves like that is not one to put in front of a merge.

### Required means red, not blocked

`main` declares no required status checks and no ruleset that references a check name. Dropping `continue-on-error` therefore changes exactly one thing: a failing AppKit half turns the `smoke` job red instead of leaving a green job with a `::notice::` nobody reads. No ruleset is being changed and none is needed for this to be worth doing.

That is enough because of what the step carries. #55 established that a leaked `MTLTexture` is invisible to `leaks` and to peak RSS both, so `liveTextures` is not the better of two instruments, it is the only one, and it is asserted in `smoke-appkit` and nowhere else. #63 then refused the peak-RSS slope partly on the grounds that the counters already catch what it would, which is an argument that leans on the counters being load-bearing. A load-bearing check that cannot go red is a silent failure reported by a silent step.

**The cost is real and is being accepted rather than argued away.** A runner image that stops granting a window server turns this job red on every push until someone reverts the flag, and it does so at the worst moment, when nobody is expecting it. The revert is one line, the notice now names the image that caused it, and the alternative was an instrument nobody is obliged to read.

## Amended by issue #51: the readback this document refused, and the one it got

The limit restated above is closed. `zig build smoke-trace` is a third half, needing a Metal device and no window, required in CI beside `smoke-gpu`. It renders through the shipping pipeline into a texture and asserts what the pixels became.

**It sits second of four steps, which has the consequence #72 named for its own.** No step in that job carries an `if:`, so a failing trace half now skips the AppKit and leak steps below it rather than running them. That is the same assertion order both documents keep arriving at: a result from a run that fell over earlier describes something other than what it claims to. It also means the cheapest windowless check reports before either window-server step is reached, which is the order the steps were registered in for exactly that reason.

**It is not the readback refused above, and the distinction is the whole design rather than a technicality.** That refusal had two halves. Reading the *drawable* back would mean dropping `setFramebufferOnly:`, changing the shipping renderer's storage mode in every host on every frame so a check could run; nothing here touches the layer, the drawable or that flag, and `init` is byte-for-byte the constructor it was. A *harness-only path* was called worse, on the grounds that "a path the shipping renderer never takes is a paraphrase"; the answer is that the offscreen path is not a second path but the same one against a different surface. `Renderer` gained a `Surface` union, `init` and `initOffscreen` share every acquisition through one function, and `frame` reads that union at exactly three points: where it takes a colour attachment, where it binds one to the resolve pass, and whether it presents. The pipelines, uniforms, bindings, draw calls, attachment formats, ping-pong and slot discipline are the shipping ones. That is `probe`'s discipline of sharing rather than paraphrasing, applied to a frame instead of a pipeline.

**No golden image was built, and the criterion this document set is why.** It asked for a picture "expensive enough to justify a golden and stable enough that the golden does not churn". The picture is not stable — #57 replaces the primitive, #58 changes what brightness means, #60 replaces the resolve outright — so what landed instead asserts extracted features against values computed from `iface.trace_full_scale` and `iface.trace_rail`. Those survive the rest of phase 3 with changed expected numbers rather than a rewritten instrument, and the geometry assertions read the *accumulation* rather than the picture precisely because #60 rewrites only the latter.

### What it can fail on

Ten defects were planted and all ten were caught, each by a named assertion. The one that matters most is #55's `1 - decay` resolve gain, the failure the paragraph above was written about: replanted, it fails with a channel 224 levels out. The full table is in [`docs/plans/done/2026-08-29-verify-the-shader-offscreen-against-the-constants.md`](../plans/done/2026-08-29-verify-the-shader-offscreen-against-the-constants.md).

**Where the assertions can be exact they are exact**, and three are: every level from 1.111 upward lands on one row, the period counts are compared under strict equality, and a three-sample window must reach both edges. The vertical tolerances are one backing pixel expressed as a sample value, which is the display's own quantum and therefore cannot absorb an error the display could show. That is #38's rule applied rather than restated: a tolerance wide enough to absorb a systematic error is a tolerance that hides one, and the ±1 period tolerance that once called six wrong counts "ok" is the thing being guarded against.

### The analysis is tested too, which is the part that had been going wrong

`src/gpu/measure.zig` holds the feature extraction and imports nothing but `std` and the seam, so `zig build test` covers it on a runner with no graphics support. That is not tidiness. #38's defect was in the *analysis* and not in the shader: its first period counter read the topmost lit pixel against the centre row, a steep segment crossing the centre lights every row it spans, and every tone came back exactly one period low. An analysis that runs only against a GPU is an analysis nothing tests, so this one has its own tests and a rasterizer that deliberately reproduces the spanning behaviour that broke the original.

### Three findings from building it

**A line strip deposits once per pixel here.** One depositing frame peaks at exactly 1.0000, which is the beam's green, so shared vertices do not double under Metal's diamond-exit rule at this geometry. That was an open question the plan declined to prejudge, and it is why the resolve check compares the two readbacks against each other rather than against the beam's literal: a check that assumed single coverage would have been resting on it. **Reproduced on a second GPU** by the first CI run, which printed 1.0000 and every other figure identically to the development machine, so this is not one machine's rasterizer. It is still a measurement at one geometry rather than a general claim, and #57 replaces the primitive it is about.

> **Superseded by [#57](https://github.com/cboone/fosforo/issues/57), exactly as that last sentence expected.** Oriented quads overlap at every joint by construction, so one depositing frame now peaks at **2.6133** rather than 1.0000, and the question about Metal's diamond-exit rule is moot rather than answered differently. What survives unchanged is the consequence drawn from it: the resolve check still compares the two readbacks against each other rather than against the beam's literal, and that is now load-bearing rather than prudent, since single coverage is no longer even approximately true.

**Offscreen frames stop at three without a wait**, because that is the semaphore's depth and there is no display link pacing the loop. A `spinLoopHint` retry measured out at roughly the length of the frame it was waiting for and failed on the fourth frame of every case, which reads exactly like a completion handler that never fires and was not one. The harness yields instead.

**Binding the wrong accumulation texture does not compile.** Planting it makes `source` an unused local, which Zig rejects. A better outcome than a caught defect, and worth recording as the reason that row had to be silenced before it could be exercised at all.

## Amended by issue #61: the harness asserts a swap, a refusal, and a recovery

Shader hot-reload ([ADR 0009](./0009-runtime-shader-compilation.md)) is the first feature here whose entire observable effect is the picture, which is the one thing this document has repeatedly recorded that nothing automated can see. The seam therefore grew a ninth operation, `shaderStats`, of the same kind as the two live-resource counters: a question about the backend rather than an instruction to it.

### The split across the two halves is this document's own, not a convenience

**The fallback arms are in the `gpu` half**, which CI requires. They need a device and no window, and what they assert is the invariant that can otherwise ruin a day: *a debug build opens its editor whatever is on disk.* A missing file, a malformed one, and one that compiles without defining what the pipelines ask for are three different failures, and all three must leave the plugin able to start.

**Only the live swap is in the `appkit` half**, because only it needs a running render loop. That half is required as of #72, so the split no longer trades coverage against gating the way it did when this was written; what it still buys is that the invariant which must never break is asserted by the half needing no window server at all.

### One phase per process, and the reason is measured

`hotReloadPhase` runs once, before the cycle loop, rather than inside `oneCycle`. Two independent reasons and both had to be measured.

A cycle in `oneCycle` lasts about as long as one 250 ms poll interval, so a watcher started on its first frame is joined before it ever looks twice: the arms simply cannot run inside one. And running it per cycle would cost `smoke-leaks -Dleak-cycles=400` twenty minutes and 1,200 out-of-process compiles for no coverage the single phase does not already give. Sitting before the loop also puts it inside the existing `liveWindowBuffers() == 0` and `liveTextures() == 0` assertions for free.

### The arm that is not a repeat of the one before it

| Arm                                          | What only this one catches                                            |
| -------------------------------------------- | --------------------------------------------------------------------- |
| An edited shader                             | The watcher never starting at all                                     |
| **A second edit of exactly the same length** | A change detector comparing size alone, and a watcher that fires once |
| A shader that does not compile               | A failed compile swapped in, and a reload that stops the loop         |
| One compiling without the right functions    | That the bytes *on disk* reached the compiler                         |
| A good shader after a broken one             | Recovery without a restart                                            |

Two of those deserve naming. The same-length second edit is a positive control rather than a repetition, and it is what the two most plausible detector bugs both fail. And the renamed-function arm is the one a counter cannot replace: `reloads` proves a compile happened and cannot distinguish a compile of the new bytes from a recompile of the embedded copy, while only the edited file can produce `buildPipeline`'s "compiled but does not define" diagnostic.

Every arm was verified by planting the defect it names. A size-only detector and a watcher that never starts both fail as `ShaderNeverReloaded`, at the second and first edit respectively; a failed compile counted as a reload fails as `BrokenShaderWasSwappedIn`; `choosePath` preferring the build option over the environment fails the GPU half as `MissingShaderNotRefused`; and removing the fallback to the embedded copy fails it as `ShaderFallbackFailed`.

### Free coverage, for the first time

A swap that leaked its outgoing pipeline states is caught by `smoke-leaks` with **no new instrument**, because this document's own #38 amendment measured that an `MTLRenderPipelineState` *is* visible to `leaks` where a buffer and a texture are not. This is the first time the rule set after #38 has been discharged by a measurement already taken rather than by a new one, and it is why no counter for pipeline states was added.

### Two defects the harness cannot see, and what was done about each

Consistent with the section under #55, and worth stating rather than glossing. Both were found by asking what a passing run would still permit, and they were answered differently.

- **A compile moved onto the render thread passes.** An extra 40 ms in a tick is invisible to a frame counter with a two-second timeout, so the harness reports a clean run. **This one is now closed outside the harness**, which is the point worth carrying: a debug-only `threadlocal` marks any thread that has entered the render path, and `buildPipelinesFromSource` asserts it is unset. That is `assertNotMainThread` from the other side, and it is the shape to reach for when the harness turns out to be the wrong instrument — the same conclusion the #55 section reached about the validation layer. Verified by planting a compile in `frame`, which panics naming the assertion.
- **A reload with a moved `[[buffer(N)]]` passes, and still does.** Nothing validates a hot-reloaded shader's bindings; the comptime tests pin the embedded copy, correctly. This one was **not** closed, and is [#77](https://github.com/cboone/fosforo/issues/77), because the obvious fix is a runtime text scan that needs a warn-versus-refuse decision and is blind to the sharper failure anyway: `TraceUniforms` layout drift, where MSL computes its own offsets and no amount of reading the text would see it. #51 has since landed and does not close it either, which is worth stating precisely because the names are close: `smoke-trace` measures what the **embedded** shader draws, so it would catch a moved binding in the shipped source and cannot see one in a file swapped in at runtime, since nothing reloads during a trace run. ADR 0009's amendment carries the full statement of what is uncovered.

The asymmetry is the lesson rather than an inconsistency. One of the two had a cheap structural guard available that makes the defect impossible; the other has only instruments, and the instrument that would work is a readback this document has already refused twice on its own terms.

### The leak baseline wandered and then came back, which is the point

Measured before this branch merged `main`, three runs at 40 cycles reported **36 to 54 leaks for 3,648 to 5,472 bytes**, against the 288 for 18,816 quoted since #63 — and the tempting conclusion was that the reload phase's extra couple of seconds let AppKit's LaunchServices chatter settle before exit.

**Re-measured after the merge, it is 288 for 18,816, three times in a row.** The earlier excursion does not reproduce, so the explanation was a story fitted to two data points and is withdrawn rather than kept with a hedge.

What survives is the rule this document already states, arriving from a third direction: **the leak count is not a discriminator, and neither is the byte total near it.** It has now been seen to move without a cause anyone can name, in both directions, which is exactly why the gate is a bound 56x above the observed figure rather than anything calibrated. `scripts/smoke-leak-check` records the same widening from CI's own side, where nine runs span 9,728 to 18,816 bytes.

**The obligation this creates for a merge is worth naming.** A number measured on a branch is a number measured against that branch's harness, and #51 and #72 both changed this one underneath. Re-measuring after the merge is not diligence, it is the only way the figure means anything.

`smoke-appkit` measures 4.4 s and `smoke-leaks -Dleak-cycles=40` 15.6 s against a documented 13 s. Both sit far inside ceilings set at roughly 4x the slowest observed run, so no `timeout-minutes` changed.

## Amended by issue #60: the prediction under #51 held, and the counting rule needed a distinction

### The picture was the only half that changed, exactly as predicted

The #51 amendment above said "the geometry assertions read the *accumulation* rather than the picture precisely because #60 rewrites only the latter". That turned out to be exactly right, and it is worth recording as a hit rather than leaving it as a claim: of the nine cases in the trace half, **seven were untouched** by a change that replaced the resolve outright, moved the drawable to a different pixel format, and deleted the trace's colour. `checkDecay` in particular would have been destroyed had it read the picture, since the sRGB curve does not preserve a ratio.

Two cases changed and one is new. `checkResolve` keeps its whole-image loop and swaps its model, and now predicts **all three channels from one number**, which is stronger than the per-channel comparison it replaces: it asserts the picture's chroma follows from the intensity, which is the palette's whole claim. `checkBeamIsOneColour` became `checkDepositIsScalar`, because its ray premise died with the deposit's colour while its loop remained the only thing anywhere asserting the accumulation's four channels move together. And `checkHotCore` is new, because every other case drives one depositing frame and the feature #60 exists to produce needs about sixteen: without it the hot core would have shipped unexecuted.

### A resource gets its own planted leak; it does not automatically get its own counter

The rule this document set under #55 is that a resource which is not a buffer gets a planted leak **before anything is assumed about it**. #60 added a third resource, a sixteen-kilobyte palette lookup in shared rather than private storage, and the rule was followed: forty cycles leaking one apiece moved the `leaks` byte total from 12,544 to 12,544, against the 640 KiB a visible leak would have added.

**Same instrument, same blindness, so it joined the existing counter rather than getting a ninth seam operation**, and `liveAccumulationTextures` was renamed `liveTextures`. The distinction worth carrying is that the rule is about *measuring* separately, not about *counting* separately: what a caller asserts is that no texture leaked, and one number answers that. The rename was not cosmetic — with the old wording a leaked palette reported "7 accumulation textures were never released", which sends the reader to the wrong file. Confirmed by planting again after the rename: `error.TexturesLeaked`.

### What the harness still cannot see, and #60 sharpened it

The offscreen path reads `getBytes:` off a texture and never involves CoreAnimation. So `smoke-trace` settles what the *hardware* does — it read `RGBA(5, 5, 8, 255)` for a background written as `float3(5, 5, 8) / (255 * 12.92)`, which is only true if the render-output stage encoded on write and `getBytes:` decoded nothing — and it says nothing whatever about what the **compositor** does with a `_sRGB` layer whose colorspace is nil. A screenshot of a running host is the only instrument for that, which is this document's position restated one layer up: the thing the harness cannot see is still the picture, and it is now the picture *on a screen* rather than the picture at all.

## Amended by issue #89: the offscreen wait's bound was a spin count, not a duration

The finding recorded under #51, that "offscreen frames stop at three without a wait ... The harness yields instead", stands and is still what the code does. What it did not record is the *bound* on that yielding, and that bound was wrong in a way nothing in this document's instrument set was arranged to see.

### A required check turned `main` red with nothing wrong with the shader

CI run [33465800182](https://github.com/cboone/fosforo/actions/runs/33465800182) on `0e1ddf5` failed `smoke: trace FAILED: FramesNeverPresented` inside `checkDecay`'s five-frame arm, having printed every figure before it correctly: the levels within a pixel, the rail on the expected row, the deposit scalar to 0.00000, the resolve's worst channel off by 0, the hot core at `RGB(255, 255, 255)`, and the decay at 0.7285 against a predicted 0.7290. It is the only unintentional failure in the last 60 runs of `ci.yml`.

`driveFrame` gave up after `trace_frame_attempts = 100_000` turns, on a docstring arguing that "the bound is attempts rather than time, and each attempt yields ... a hundred thousand yields is many seconds of slack on a loaded runner". The failing step ran three seconds against four for a passing trace step on the previous commit. It did not spend many seconds of slack; it gave up faster than a healthy run finishes.

### How wrong, measured rather than estimated

`frame` planted to report `.no_frame_slot` unconditionally, run against the two-second deadline that replaced the count: **14,468,498 attempts fit inside 2000 ms**. The old bound was therefore worth about **13.8 ms** on this machine, not many seconds, and the discrepancy is a factor of roughly 150. The same plant against a 1 ms ceiling reports 5,344 attempts, so the rate holds across three orders of magnitude and the deadline is what sets the duration rather than the machine. `std.Thread.yield()` returns almost immediately when nothing else on the core is runnable, which is the whole of it.

### Raising the count would have been the wrong repair

The obvious reading is that the exposure grows with frame count, since a case driving more frames than the semaphore is deep spends longer in the retry path, and that a larger count would therefore buy proportional headroom. It does not, and the failing run refutes it directly: `checkHotCore` drives **thirty** frames against `checkDecay`'s five, runs immediately before it, and passed. A count is not a duration at any value, which is why the repair is a clock.

### The rule that generalises

**A sleeping wait may sum its sleeps; a yielding wait must read a clock.** `waitForFrames` and `waitForReload` accumulate a nominal poll interval and are sound doing so, because `sleep` guarantees a floor per turn and the sum therefore under-counts real elapsed time, erring toward waiting longer than the stated ceiling. `yield` guarantees nothing at all, so a count of yields is a measurement of how idle the machine was.

The harness now reads the wall clock through a second local wrapper beside `sleepFor`, and the two clocks in the trace half must not be confused: the synthetic nanoseconds handed to `Renderer.frame` are made up so that a fade is reproducible on any machine, and a retried frame deliberately does not advance them. The deadline never reaches the seam, so `src/gpu/iface.zig`'s statement that "there is exactly one clock, `display_link.monotonicNanos()`" is untouched: that is a claim about what may be passed through `frame`'s parameter, and `frame` still receives the synthetic reading unchanged.

### What this adds to the theory of instruments

Every limit catalogued above is a **false negative**: a defect one instrument cannot see, closed by naming a second that can. This is the first entry of the other kind. Nothing here was broken, and a required check said something was. That failure mode belongs to the harness's own scaffolding rather than to the code under test, and no amount of adding instruments addresses it: the answer is that a bound which is not measured in the units it claims will eventually be believed in them.

The failure message now names the measured elapsed rather than the ceiling, for the same reason. Under the old bound a give-up at two seconds and one at forty milliseconds printed identically, so the CI log could not distinguish a slow runner from a completion handler that never fired, and settling that took a plant on a development machine rather than a reading of the log.
