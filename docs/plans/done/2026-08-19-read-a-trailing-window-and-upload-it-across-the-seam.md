# Read a trailing window on the render thread and upload it across the seam

Issue [#37](https://github.com/cboone/fosforo/issues/37). Phase 2, step 3 of `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`. Depends on [#35](https://github.com/cboone/fosforo/issues/35), which landed the container, and [#36](https://github.com/cboone/fosforo/issues/36), which landed the producer.

## Context

`src/dsp/ring.zig` has a writer and no reader. `process` publishes a second of history on the audio thread and nothing consumes it, which leaves both halves of [ADR 0010](../../adr/0010-lock-free-history-buffer.md)'s protocol only half exercised: `Ring.read` and `Ring.capacity` are still analysed by nothing but `zig build test`, because Zig's analysis is lazy per declaration and the plugin calls only `init`, `deinit`, `write` and `clear`. This issue is the consumer arriving.

It is also the caller the in-flight semaphore has been waiting for. The phase 1 plan put the ring of per-frame dynamic buffers explicitly out of scope on the grounds that "there is nothing dynamic to buffer until phase 2's history buffer, and the semaphore is what that phase will find already in place" (`docs/plans/done/2026-07-29-cvdisplaylink-render-loop-and-resize-seam.md:417`), and `max_frames_in_flight`'s own docstring says the semaphore "limits how far ahead the CPU may encode, which is what phase 2's per-frame dynamic buffers will actually need in order to know which slot of a ring is free" (`src/gpu/metal/renderer.zig:66-75`). Both mechanisms are used here rather than rebuilt.

The intended outcome is that the render thread reads a 20 ms window every tick and uploads it into a GPU buffer nothing draws yet. Keeping the upload apart from the trace is what lets this land behind checks that the path neither stalls nor leaks, which is a claim `smoke-appkit` and `smoke-leaks` can make and a picture cannot.

## The decisions the issue asks for

### The history's storage gets the instance's lifetime, so the race disappears rather than being managed

`deactivate` frees `Instance.history` on the **main thread**, and it is not `destroy`: REAPER and Logic both deactivate routinely when a track is disabled, and a host may do it with the editor open. Once `Editor.tick` reads that memory there is a genuine use-after-free between the two threads.

The storage moves to the instance. `create` allocates it, `destroy` frees it, and `destroy` already calls `self.editor.destroy()` first, which closes the `Gate` and spins until no tick is inside (`src/clap/gui.zig:339`). By the time the free runs, no reader can exist. That is the same reasoning the gate already encodes for the renderer's own teardown, reused rather than answered twice, and it leaves nothing to synchronise on the read path at all.

The alternative was a second gate the editor enters around `Ring.read`, closed by `deactivate` and reopened by `activate`. It was rejected on three counts: `Gate` is one-way and would need a `reopen` that is a `fetchAnd` rather than a plain store, because a refused reader between its `fetchAdd` and its `fetchSub` would otherwise underflow the count; the gate would have to become reachable from both `Instance` and `Editor`, which today deliberately share no type (`src/clap/gui.zig:18-20`); and it would put a main-thread spin on every track disable rather than only on editor close. Managing the race is more machinery than deleting it.

**The cost is that capacity stops being derived from the sample rate**, since `create` runs before any rate exists. It becomes a fixed `1 << 18` samples, 262144 f32 and 1 MiB, which is at least a full second at every rate through 262 kHz and 5.46 seconds at 48 kHz. ADR 0010's ratio survives intact and then some: a 20 ms window at 192 kHz is 3840 samples against 262144, a margin of 68 to 1 for `coherent` to spend. An instance that never activates now holds that megabyte, which is the price, and it is small beside phase 3's accumulation textures at several megabytes per open editor.

**`activate` clears rather than reallocates.** `Ring.deinit` never reset the cursor, and freshness across an activation cycle held only because `activate` assigned a whole new `Ring`. With the storage persisting, that guarantee has to be made explicitly, and `Ring.clear` is the operation that makes it: it publishes a capacity of silence through `write` rather than blanking behind the cursor, which is the shape `reset` already relies on.

### The window is 20 milliseconds, and its sample count is published to the editor at `activate`

ADR 0010 says only "tens of milliseconds". Twenty is the choice, and the reasoning belongs beside the constant rather than in a commit message:

- At 48 kHz it is 960 samples against the 960-point default editor width, so the crude trace [#38](https://github.com/cboone/fosforo/issues/38) draws needs no decimation at the default geometry. #35 put min/max decimation out of scope and flagged that the boundary was close; 20 ms is the side of it that does not bite yet.
- It shows two periods of 100 Hz and twenty of 1 kHz, both readable, which is what makes #38's "count the periods across a known window duration" a check someone can actually perform.
- Against a capacity of a second or more it leaves `coherent` a margin measured in seconds while the copy itself takes microseconds.

A duration rather than a sample count, because the horizontal axis of a scope is time and a window that silently halved when a session moved from 48 to 96 kHz would be lying about it. That means the sample count depends on the rate, and the rate exists only between `activate` and `deactivate`, so `activate` computes it and publishes it to the editor as a single atomic `u32`, released on the main thread and acquired on the render thread. It is the same main-to-render shape `Editor.meter_reset` already uses, and it carries no lifetime at all, only a value. `deactivate` publishes zero, and zero means the editor reads nothing and uploads nothing.

Phase 4 turns this into a parameter. Until then it is `window_seconds` in `src/clap/gui.zig`, alongside `default_size` and `min_size`, because it is a property of the display rather than of the audio path.

### The upload crosses the seam as `upload`, and the copy into the slot's buffer happens inside `frame`

This is the one place the issue's shape and the semaphore's discipline pull against each other, and it is worth stating why the resolution is what it is.

A per-frame buffer is only safe to write once the frame's slot is known free, and the slot is acquired by the try-wait at the top of `Renderer.frame` (`src/gpu/metal/renderer.zig:299-300`). An `upload` called from `Editor.tick` **before** `frame` does not hold a slot yet. Writing the GPU buffer there is exactly the failure the issue warns about: under load the wait fails, the tick is dropped, and the buffer just overwritten is one the GPU is still reading. That shows as tearing rather than as a crash.

So `upload` copies the samples into a renderer-owned CPU array, and `frame` copies that array into `vertices[slot]` after the wait has succeeded. Three consequences make this the right shape rather than merely a workable one:

- The buffer ring stays sized to `max_frames_in_flight`, which is what the issue asks for and what `maximumDrawableCount` is already pinned to.
- A skipped upload is trivially correct. When `Ring.read` reports a torn window the editor skips the upload, and `frame` simply re-copies the last good window rather than binding a buffer whose contents are several encodes stale.
- No new wait enters `frame`. The added work is two `@memcpy`s of at most 32 KiB and one `setVertexBuffer:offset:atIndex:`, none of which can block, which is the constraint `AGENTS.md` states as "nothing the render thread waits on may be unbounded".

The rejected alternative was writing the GPU buffer directly from `upload`, which needs `max_frames_in_flight + 1` buffers and still breaks the moment an upload is skipped, because the buffer it would then rebind holds the window from four encodes ago rather than the last good one. Folding the samples into `frame`'s signature was also rejected: it is not a new operation, and `frame`'s docstring turns on it taking no arguments.

**Raw samples cross the seam, not a vertex format.** `[]const f32` needs no new seam type and names nothing Metal owns. A `Vertex` struct chosen now would be chosen for a line strip that phase 3 replaces with oriented quads, so it would be designed in the wrong phase and discarded in the next one. #38's vertex function derives its position from `[[vertex_id]]` and the sample value, exactly as `fullscreen_vertex` already derives its own from the id alone.

### A torn window is counted, not retried

`Ring.read` returns false when the producer lapped the window during the copy, and its docstring is explicit that the response is to skip and not retry. #35's plan asked for one thing more: that a torn window "becomes something #37's caller can count, in the same way `Editor.framesPresented` turned 'the loop is running' and 'the loop is drawing' into two separable claims" (`docs/plans/done/2026-08-19-lock-free-circular-history-buffer.md:42-48`).

`Editor` gains a monotonic counter and a `windowsTorn()` accessor beside `framesPresented()`, the debug render meter prints it, and the smoke harness asserts it stays at zero. At a 68 to 1 margin anything else is a real signal rather than noise.

## Changes

### `src/dsp/ring.zig`

One correctness fix, which this issue is the reason to make now: `read` underflows against a ring with no storage. `index` computes `@as(u64, self.samples.len) - 1` to build its mask, and at a length of zero that is `0 - 1`, reached unconditionally for any `dst.len > 0` even though `copied` is zero. It panics in Debug and wraps into an illegal slice in `--release=fast`. Nothing hits it today because nothing calls `read` outside tests, and instance-lifetime storage means the editor will not hit it either, but it stays a defect in a `pub fn` and the read path is what this issue touches.

Guard at the top: an empty ring zero-fills `dst` and reports coherent, which is the same answer the existing "fewer samples than asked for" path already gives.

### `src/clap/plugin.zig`

| Site                    | Change                                                                                                                                                                                         |
|-------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Instance.history`      | Docstring rewritten: the storage has the instance's lifetime, why, and that this issue deleted the race rather than managing it                                                                |
| `create`                | Allocates the ring, behind an `errdefer allocator.destroy(self)` so a failed sizing does not leak the instance                                                                                 |
| `destroy`               | Frees the ring, **after** `self.editor.destroy()`, with a comment saying the order is what makes it safe                                                                                       |
| `init`                  | Wires `self.editor.history = &self.history` beside the existing `log` and `host_gui` wiring                                                                                                    |
| `activate`              | Drops the `Ring.init` and its undo path; clears the history; publishes `gui.windowSamples(sample_rate)` to the editor                                                                          |
| `deactivate`            | Drops the `Ring.deinit`; publishes a window of zero                                                                                                                                            |
| `historySamples`        | Becomes a `history_samples` constant, with the fixed-capacity reasoning replacing the rate-derived reasoning                                                                                   |
| `activate`'s rate check | The comment leans on the history being sized from the rate, which stops being true; the check itself stays, because `self.sample_rate` still outlives the call and phase 3 still divides by it |
| `process`               | The comment "the history is sized from the sample rate" needs the same correction                                                                                                              |

### `src/gpu/iface.zig`

- `pub const max_window_samples: usize = 8192`, the largest window `upload` accepts and the size the backend allocates each buffer to. It covers 20 ms through 409.6 kHz; above that the window shortens rather than the rate being refused, which is the right failure for a rate no device offers.
- A sixth line in the comptime block, `assertSignature("upload", @TypeOf(Renderer.upload), fn (*Renderer, []const f32) void)`, placed after `resize` and carrying the same kind of comment that one does: why the parameter type is drawn from this file's vocabulary rather than the backend's.
- `Error` gains `BufferAllocationFailed`. The header sentence "every way starting a renderer can fail" stays true, because the ring is allocated at start.
- Two docstrings that enumerate what exists have to follow: the `Renderer` alias says "Four operations" and lists them, and the file header's "which is how `resize` arrived" sentence gets a companion clause for how `upload` arrived.

### `src/gpu/metal/renderer.zig`

- `mtl.resource_storage_mode_shared`, joining the four restated Metal constants under the same stated risk.
- Fields: `vertices: [max_frames_in_flight]objc.Object`, `slot: usize = 0`, and the CPU staging pair `window: [iface.max_window_samples]f32 = @splat(0)` with `window_len: usize = 0`. The staging array is inline rather than allocated, because `Renderer.init` takes no allocator and `Renderer` lives inside the heap-allocated `Instance`.
- `init` allocates the three buffers in a loop with an index-bounded `errdefer`, which is the one place the file's acquire-then-`errdefer` pattern needs more than one line.
- `probe` allocates and releases one buffer, so its docstring's claim to do "everything `init` does except attach a surface" stays true and `zig build smoke-gpu` covers the allocation in CI.
- `deinit` releases the three buffers before `self.* = undefined`. Frames may still be executing; the encoder retains resources it binds for the command buffer's lifetime, which is the same argument that lets the layer be released there. Confirm it rather than assume it, and state it in a comment either way.
- `upload` asserts not-main-thread, copies at most `max_window_samples` into the staging array, and records the length. No autorelease pool, because it sends no messages.
- `frame` advances `slot` immediately after a successful wait, copies staging into `vertices[slot]`'s `contents`, and binds it between `setRenderPipelineState:` and `drawPrimitives:`. Advancing after the wait is what makes the slot safe: a successful wait proves at most two frames are outstanding, so the buffer three encodes back is free.

The draw call itself is unchanged. The buffer is bound although no shader reads it yet, deliberately: it makes the path real end to end, it establishes the command buffer's retain that `deinit` depends on, and it is the line #38 builds on.

`Renderer.resize` needs no change at all. The buffers are sized from `max_window_samples` rather than from the drawable, so a resize does not invalidate them.

### `src/clap/gui.zig`

- `window_seconds: f64 = 0.020` and `windowSamples(sample_rate) u32` beside `default_size`, `min_size` and `max_size`, saturating through `lossyCast` the way `historySamples` does and clamped to `gpu.max_window_samples`.
- `Editor` fields: `history: ?*const ring.Ring = null` following the optional-const-pointer pattern `log` and `host_gui` already establish; `window: std.atomic.Value(u32) = .init(0)` for the count; `samples: [gpu.max_window_samples]f32 = @splat(0)` as the fixed buffer the editor owns; and a monotonic torn counter.
- `setWindow` (main thread, release) and `windowsTorn` (thread-safe, acquire).
- `tick` reads and uploads between the mailbox drain and `renderer.frame()`, which is the ordering ADR 0010 asks for and the reason the drain comes first: nothing reads a resource the resize is about to replace.
- `report` prints the torn count alongside the rate and geometry.

**`Editor.destroy` must reset the torn counter and must not touch `window` or `history`.** Those two are published by `plugin.init` and `activate`, whose lifetimes outlive any single editor: a host that closes and reopens an editor on an active plugin would otherwise get a window of zero and never read again. This is the kind of thing that fails silently, so it wants a comment at the assignment rather than only in this plan.

### `src/smoke.zig`

`oneCycle` never calls `activate`, so without this the appkit half would upload an empty window on every tick and prove nothing about the samples or the race. It gains:

- `activate` and `start_processing` after `init`, and a synthetic `clap_process_t` built from a zeroed struct with one two-channel input holding a ramp and one two-channel output. `process` reads only `frames_count`, `audio_inputs` and `audio_outputs`, so the event lists stay null.
- A few `process` calls before the editor opens, so the ring is non-empty by the first tick.
- `stop_processing` and `deactivate` **while the editor is still showing**, followed by a wait for two more frames. That is the deactivate-while-rendering path, and this harness is the only place it can be exercised at all.
- An assertion that `windowsTorn()` is zero across the cycle.

The honest limit is worth writing down in the harness: it cannot read the drawable back, so it asserts that the upload path runs, does not tear, does not stall and does not leak. What the samples became is #38's question.

## Tests

| File         | Test                                                                                                               |
|--------------|--------------------------------------------------------------------------------------------------------------------|
| `ring.zig`   | `read` against a ring with no storage zero-fills and reports coherent                                              |
| `gui.zig`    | `windowSamples` at 44.1, 48, 96 and 192 kHz, and its clamp at an absurd rate                                       |
| `gui.zig`    | `windowSamples` never exceeds `gpu.max_window_samples`, walked rather than spot-checked                            |
| `gui.zig`    | `setWindow` and `windowsTorn` round-trip, and `Editor.destroy` clears the torn counter and leaves the window alone |
| `plugin.zig` | The ring has storage immediately after `create`, before any `activate`                                             |
| `plugin.zig` | `activate` clears stale history: tap a ramp, deactivate, activate, read zeros                                      |
| `plugin.zig` | `deactivate` leaves the capacity in place                                                                          |
| `plugin.zig` | `init` points the editor's `history` at the instance's ring                                                        |
| `plugin.zig` | `activate` publishes the window count and `deactivate` publishes zero                                              |

`refAllDecls(Renderer)` in `renderer.zig`'s test block is what type-checks the new `newBufferWithLength:options:` and `setVertexBuffer:offset:atIndex:` selector signatures without a GPU, which is the existing convention rather than a new one.

## Documentation

Three gotchas belong in `AGENTS.md`, all of them things that fail silently:

- The upload's ordering. The copy into the per-frame buffer is inside `frame` and after the semaphore wait, because a buffer written before the slot is acquired can be one the GPU is still reading, and the symptom is tearing under load rather than a crash.
- The history's lifetime. Its storage belongs to the instance, `destroy` frees it only after `editor.destroy()` has closed the gate, and reordering those two lines reintroduces exactly the race this issue removed.
- `Editor.destroy` resets what the editor owns and leaves what `plugin.init` and `activate` published.

No new ADR. ADR 0010 settles the protocol and says nothing about where the storage lives, and this is an implementation choice of the same weight as #36's "the tap is the left channel", which was recorded in a docstring. The `Instance.history` docstring is the place it lives, and it is replacing a docstring that already names this issue as the owner of the question.

## Verification

```bash
zig fmt --check build.zig src/
zig build test
zig build
zig build validate-shaders
zig build smoke-gpu
zig build smoke-appkit
zig build smoke-leaks
```

`smoke-leaks` is the one that needed the instrument checked before its result was trusted, and checking it overturned the assumption above. **`leaks` cannot see a leaked `MTLBuffer` at all.**

The plan assumed `scripts/smoke-leak-check`'s `PLUGIN_OWNED` pattern would catch one under whatever name `leaks` chose for it. It does not, and the failure is not the prefix. Dropping the release in `Renderer.deinit` and running 60 cycles produces a report the script calls clean; the *same* omission applied to the command queue is caught in the same run as `AGXG17XFamilyCommandQueue`, so the instrument works. None of the 234 leaked classes in the buffer run is a buffer under any name, while the leak is real: peak RSS across 200 cycles goes from 47.7 MB to 57.7 MB. `leaks` walks the malloc heap, and a Metal buffer's storage is not in it.

So the verification this issue asked for did not cover the thing it was asked about, and the backend counts its own instead. `live_windows` is incremented by `buildWindows` and decremented by `releaseWindows`, `gpu.Renderer.liveWindowBuffers` reports it on `probe`'s precedent, and `src/smoke.zig` asserts it is zero after the cycle loop rather than inside it, because every fourth cycle leaves the editor to `plugin.destroy` in a `defer` the cycle cannot assert after. Removing the release from `deinit` now fails with `WindowBuffersLeaked` and names the count.

The limit is worth stating: the counter proves the ring was handed back, not that `release` was sent, so a `releaseWindows` that stopped releasing would still balance. What it catches is the realistic failure, a path that builds a ring and forgets it.

Both halves are positive controls rather than claims, and both were run: the read path by inverting `Ring.read`'s result and watching `smoke-appkit` report torn windows, and the empty-ring guard by removing it and watching the new `ring.zig` test abort on `integer overflow`.

In REAPER, launched from a terminal so the debug diagnostics are readable:

- Confirm the installed bundle is the one under test, through the hashes `zig build install-plugins` prints, before believing any of the below.
- Play audio and confirm the once-a-second render line still reports a rate, now with a torn count that stays at zero.
- Disable and re-enable the track with the editor open, which is `deactivate` and `activate` against a running display link, and confirm the loop keeps presenting across both.
- Change the session sample rate with the editor open, which is the other way that pair is reached, and confirm the reported window count follows the rate.

In Logic, where the Audio Unit destroys its editor rather than hiding it and diagnostics are unreadable: confirm the editor opens and renders, and that disabling and enabling the track does not crash. The pixel sample described in `AGENTS.md` is the check, since nothing is drawn differently yet.

### What was run, and by whom

Everything below passed. Splitting the automated half from the host half matters, because only one of them is repeatable by the next person to touch this.

| Check                                                | Result                                                 |
|------------------------------------------------------|--------------------------------------------------------|
| `zig fmt --check`, `zig build test`                  | 139 tests, all passing                                 |
| `zig build`, `zig build validate-shaders`            | Clean                                                  |
| `zig build smoke-gpu`, `smoke-appkit`, `smoke-leaks` | Clean, 400 cycles under `leaks`                        |
| The same four, under `--release=fast`                | Clean                                                  |
| `clap-validator` against both bundles                | 21 passed, 0 failed, 0 warnings, 23 skipped, on each   |
| `shfmt`, `shellcheck`, `markdownlint-cli2`, `typos`  | Clean                                                  |
| REAPER and Logic                                     | Confirmed by the author against hash-verified installs |

**The `--release=fast` pass was added after the fact and is worth keeping.** Everything else here is Debug, which is what `zig build` and `zig build test` produce, and the shipping build compiles `std.debug.assert` out. That takes `platform.assertNotMainThread` in the new `upload` with it, so the mode this issue's code actually ships in had never once been compiled until it was run deliberately. The two checks the harness added survive the mode change, because `WindowTorn` and `WindowBuffersLeaked` are explicit returns rather than assertions.

**The host half was confirmed by the author rather than by this document**, against installs whose hashes matched their sources: the CLAP at `2be599cc0772` and the Audio Unit at `5a7956287f88`. That check was not a formality. A `Fosforo.component` dated two weeks earlier, from another branch, was installed at the time the CLAP was first installed from this one, and `install-plugins` could not overwrite it because CMake had never run in this worktree. Logic would have loaded it, rendered, and read as a pass. Issue #43 is that gap.

### What this does not close

**The memory-ordering gap #35 deferred to this issue stays open.** #35 recorded that replacing `write`'s release store with a `.monotonic` one passes every test in the project, and that the first check able to tell the two apart is "a known signal drawn on screen during playback". Nothing is drawn here, so that check is not available yet and this issue cannot honestly claim it. It moves to #38, which is the first phase that has a picture to be wrong.

## What landed differently

Four things the plan did not anticipate, each recorded because the reason is more useful than the change.

**`leaks` cannot see the buffer ring**, which is set out in full above. The plan treated `smoke-leaks` as covering the new resource and it does not, so `gpu.Renderer.liveWindowBuffers` is a seventh seam operation that was not planned. It is the same kind of thing as `probe`, a question about the backend rather than an instruction to it, which is what makes it defensible on a seam that exists to stay small.

**`activate` gained explicit sample-rate bounds.** Sizing the history from the rate was refusing absurd values as a side effect, because `Ring.init` rejected anything that saturated a `usize` or rounded down to no slots. Moving the allocation to `create` removed that without anything in the plan noticing, and two existing tests caught it: `floatMax(f64)` and 0.5 Hz both became rates `activate` accepted. `min_sample_rate` and `max_sample_rate` put the boundary back where it was, explicitly, which is how this project treats every other value arriving from a host.

**The seam's own docstring was wrong before this touched it.** It said "four operations" and listed three, having missed `resize`. Corrected to six plus the count above, with a note that the comptime block is the list that cannot drift and the prose is the one that has to be kept beside it.

**The plugin tests now measure the cursor from a baseline.** `activate`'s `clear` means the cursor no longer starts an activation at zero, so eleven tests asserting absolute values failed at once. `testWritten` subtracts the baseline in one place rather than each restating an implementation detail of `activate`, and every assertion still states what the tap wrote.

**One issue was filed rather than fixed here.** Verifying this in a host surfaced that `zig build install-plugins` installs one bundle, cannot build the Audio Unit, and says nothing about a stale one already installed, while its three step names conflate `zig-out` with the plug-in folders and an unverified copy with a verified one. That is [#43](https://github.com/cboone/fosforo/issues/43), and it is deliberately not this issue's work: the install path is orthogonal to the upload path, and folding it in would have made a phase 2 step into a build-system change.

## Out of scope

Recorded so they read as deliberate omissions rather than oversights.

- **Drawing anything.** #38, and the reason this one is landable behind automated checks.
- **The `CVTimeStamp`s.** Phase 3's frame-rate-independent decay is their first caller and the phase that should decide how time is measured.
- **Anything in `Renderer.resize`.** The accumulation textures are phase 3. The vertex buffers are sized from the window rather than the drawable, so this issue leaves `resize` untouched, which is narrower than the issue's own allowance for "what a resized vertex buffer needs".
- **Decimation.** 20 ms at 48 kHz is 960 samples against a 960-point default width, so it does not bite at the default geometry. Above 48 kHz, or in an editor dragged narrower, the window holds more samples than the drawable has pixels and #38 will let it alias. Min/max decimation is phase 3.
- **Uniforms.** #38 needs the sample count to reach the shader; nothing here does.
- **A second channel.** The X-Y vectorscope wants a second `Ring` sharing nothing with this one, per #36's reasoning, and neither the window nor the upload is shaped to forbid that.
- **Making the window a parameter.** Phase 4, along with triggering.

## Commits

As landed, in order. The seam and the editor precede the plugin, which the plan had the other way round: `activate` calls `gui.windowSamples` and `Editor.setWindow`, so the plugin commit cannot build until both exist.

1. `docs: plan the trailing-window read and the upload path (#37)`
2. `fix: guard Ring.read against a ring with no storage (#37)`
3. `feat: add the per-frame window upload to the renderer seam (#37)`
4. `feat: read a trailing window in Editor.tick and upload it (#37)`
5. `feat: give the history buffer the instance's lifetime (#37)`
6. `test: drive audio and a deactivate through the smoke harness (#37)`
7. `docs: record the upload path's ordering and lifetime rules (#37)`
