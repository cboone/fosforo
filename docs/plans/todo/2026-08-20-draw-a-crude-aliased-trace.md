# Draw a crude aliased trace from the history buffer

Issue [#38](https://github.com/cboone/fosforo/issues/38). Phase 2, step 4 of `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`. Depends on [#37](https://github.com/cboone/fosforo/issues/37), which landed the read and the upload.

## Context

The render thread already reads a 20 ms window every tick and copies it into a GPU buffer that is bound to a shader declaring no such argument. `src/gpu/metal/renderer.zig:466-471` says so in as many words: "Bound although the shader currently declares no such argument, which Metal permits and which is deliberate rather than an oversight... #38 adds the vertex function that reads it." This issue is that vertex function.

It is phase 2's exit criterion and the first time this project renders anything derived from audio. It is also the first deliverable that can be judged by eye, which changes what verification means here: phase 1's picture was `RGB(5, 5, 8)` and indistinguishable from failure at a glance, and `Editor.framesPresented` exists because of it.

Deliberately crude, and the crudeness is the point. A single aliased polyline, one device pixel wide, no persistence, no decay, no velocity weighting, no bandlimited reconstruction. Every one of those is phase 3, and drawing something ugly first means phase 3 arrives with a working signal path underneath it and can be judged on how it looks rather than on whether it works at all.

The intended outcome is that a sine played into the plugin draws as a sine, at a frequency countable against a known window duration, at a vertical scale someone can state out loud.

## The decisions the issue asks for

### The vertical axis is absolute: full scale at 0.9, a rail at 0.98, and no rescaling ever

The issue is explicit that this is a real decision: "a scope that silently rescales is lying about level, which is the one thing a measurement instrument may not do." Auto-gain, auto-range, and per-window peak normalization are refused outright and are not revisited below.

The mapping, with `s` the sample and Metal's NDC `+1` at the top:

```text
x_ndc(i) = 2i / (n - 1) - 1
y_ndc(i) = clamp(s[i] * full_scale, -rail, +rail)

full_scale = 0.9
rail       = 0.98
```

So full scale draws 5% of the drawable height in from each edge, and the rail sits 1% in. At the default 960x540 editor on a 2x display (1920x1080 backing): full scale at rows 54 and 1026, the rail at rows 10.8 and 1069.2, centre at 540. **The 43-pixel strip between a full-scale peak and the rail is the whole design.** It is what makes "at full scale" and "over" two different pictures rather than two opinions about the same picture, and it is what the level-sweep checkbox is checking.

Three alternatives, each dismissed for a concrete reason rather than a preference:

- **Full scale on the drawable's exact edges, over-scale left to the rasterizer.** A one-pixel line whose centre sits on the framebuffer boundary has half its coverage diamond off-screen and may not rasterize, so a correct loud signal would draw with its tips intermittently missing: a level-dependent artifact on the axis whose entire job is level. Worse, clipping a line strip does not remove the trace, it removes the peaks: the segments crossing the boundary still draw up to it and the segments wholly above it do not, so an over-scale signal reads as a *quieter* signal with gaps. That is a more dangerous misreading than vanishing.
- **Full scale on the exact edges, clamped there.** Rails rather than clipping, but rails exactly where a one-pixel line may rasterize to nothing, so "railed" would read as "gone". That is the specific trap the issue's framing worries about.
- **Full scale inside a margin, over-scale left to the rasterizer.** Keeps the peaks-into-gaps failure above for no benefit.

**Why 0.98.** It is set by the smallest editor `clampSize` permits. `min_size.height` is 270 points, which on a 1x display is 270 backing pixels and a half-height of 135, so `(1 - 0.98) * 135 = 2.7` pixels between the rail and the edge. Above one pixel at every geometry this plugin will adopt, which is the arithmetic that makes the rail always rasterize, and it is a relationship a test can hold.

**Why 0.9.** The rail is reached at `rail / full_scale`, which is `0.98 / 0.9 = 1.0889`, so the margin is worth **+0.74 dB** of visible headroom above full scale before railing. Typical intersample overshoot on limited material is 0.5 to 1.5 dBTP, so when phase 3 adds the bandlimited reconstruction ADR 0007 asks for, the smaller half of that range draws inside the margin rather than against the rail. That is why the number is not arbitrary; it is not the reason for having a margin at all.

**The tempting figure here is wrong and was believed for a while, so it is worth naming.** `1 / full_scale` is 1.111, or +0.92 dB, and that is *not* the railing threshold: it is where the trace would reach the drawable's edge if nothing clamped it, which cannot happen because the rail clamps first. Measured rather than argued: `s = 1.05` draws at row 14 of 540 and `s = 1.0889`, `1.111`, `2.0` and `8.0` all draw at row 5.

**The trace has a floor, and it is arithmetic rather than a defect.** One pixel of excursion needs `s = 1 / (full_scale * H/2)`: about `0.00206`, or **-54 dBFS**, at the default editor on a 2x display, and about **-42 dBFS** at the minimum editor on a 1x display. Below that a sine moves the trace less than a backing pixel and reads as flat. It bounds the bottom of any level sweep.

**The constants live in `src/gpu/iface.zig`, beside `max_window_samples`, and reach the shader as uniform fields.** Three reasons. Nothing in `zig build test` reads `shaders/scope.metal`, so a policy stated only there is a policy no test can hold. `renderer.zig:66-72`'s `background` already demonstrates the cost of the alternative, a "kept in step with `clear_fragment`" comment holding two numbers together by hand. And the test that ties the rail to `min_size.height` lives in `src/clap/gui.zig`, which reaches the seam and must not reach the Metal backend, so the constant has to be visible from there. `max_window_samples` is the precedent: a policy number the seam publishes, named without naming anything Metal owns.

### The sample count reaches the shader as uniforms copied at encode time

`window_len` has never crossed to the GPU. The #37 plan flagged it as the one mechanism left open: "**Uniforms.** #38 needs the sample count to reach the shader; nothing here does."

`setVertexBytes:length:atIndex:` at index 1, with a twelve-byte `extern struct`. Metal copies the bytes into the command buffer's own transient storage at encode time, so there is no lifetime and no aliasing with a GPU read in flight, which means it needs none of the slot discipline `Renderer.window`'s docstring exists to describe. Apple's ceiling for the call is 4 KiB.

The alternative, a fourth `MTLBuffer`, is refused on a cost this project has already measured: **`leaks` cannot see a Metal buffer at all**, so a fourth one would either need adding to `live_windows`' accounting or would silently escape it. The other alternatives do not work. MSL has no `[[vertex_count]]` attribute, so the shader cannot derive the count. Writing the count into the window buffer as a header changes what `writeWindow` and `buildWindows` mean and makes `max_window_samples * 4` the wrong size.

The struct carries `sample_count`, `full_scale`, and `rail`: scalars only, deliberately, because MSL aligns `float2` to 8 bytes and `float4` to 16 and a vector member would introduce padding this side would have to reproduce by hand. Nothing links the Zig declaration to the MSL one, which is why there is a layout test and why the buffer indices are named on both sides and searched for by a third.

### One library, two pipeline states, and the fullscreen pass stays

Two entry-point pairs need two `MTLRenderPipelineState` objects. They do **not** need two libraries, and that distinction is the expensive one: AGENTS.md's hardened-runtime gotcha establishes that `newLibraryWithSource:` hands the source to `MTLCompilerService.xpc` out of process, which is the most costly thing `init` does and sits on `set_parent`, where a host is blocked. Compiling the same embedded string twice to pull four functions out of it would double that for nothing.

So `buildPipelines` compiles once and calls a reshaped `buildPipeline` twice, returning both states or neither. That lands exactly on `buildWindows`/`releaseWindows`' precedent: an all-or-none acquisition with one `errdefer` in `init` and one release site.

**The cheapest possible version of this issue deletes the fullscreen pass** and lets `load_action_clear` do the clearing, and a reviewer will raise it. The issue rejects it directly ("alongside... rather than replacing them"), and there is a second reason worth recording: the fullscreen pass is where phase 3's decay (steps 2 and 3) and tonemap (step 7) live. Keeping it means phase 3 replaces a body. Dropping it means phase 3 re-adds a pass.

One encoder, two `setRenderPipelineState:` calls, clear first. Apple Silicon is tile-based deferred, so both draws run against tile memory inside one pass and are written out once. A second encoder would end the pass, store the full attachment, and reload it, which is two round trips through the framebuffer for an identical picture.

**No blending on either pipeline**, which preserves current behaviour rather than deciding anything new. `blendingEnabled` defaults to `NO`. Phase 3's additive trace lands on an `RGBA16F` accumulation texture rather than on the drawable, so enabling additive here would be additive against the wrong surface, and additive over a non-black background makes the trace's colour a function of the background, which is entangled with the palette rather than separable from it.

### The harness gains a `windowsUploaded` counter rather than a drawable readback

The issue asks whether `zig build smoke-appkit` can assert more than "a frame was presented", and asks for the answer to be recorded either way.

**A drawable readback is refused, and not on cost.** It means dropping `setFramebufferOnly: true` at `src/gpu/metal/renderer.zig:662`, which changes the shipping renderer's storage mode in every host on every frame to make a check possible in CI. The #19 plan already refused exactly that: "A drawable that is `framebufferOnly` cannot be read back, and changing that to suit a test would change the shipping renderer." A harness-only readable path is worse, because it inverts `probe`'s design principle: `probe` shares `buildPipeline` with `init` "rather than paraphrasing it", and a path the shipping renderer does not take is a paraphrase. The comparison also needs a golden image, in a project with no image comparison of any kind, pinning the vertical scale, the X mapping, the drawable size, and Metal's line rasterization rule against a shader phase 3 replaces.

**This sharpens ADR 0013's own criterion, which #38 shows is not quite right.** The #5 amendment says a readback becomes worth doing "when there is something in the picture worth comparing: today it is a flat colour, and in phase 3 it will not be." #38 has a picture and a readback is still not worth it. The real criterion is when the picture is expensive enough to justify a golden and stable enough that the golden does not churn, which is after phase 3's look settles rather than at its start.

**What is added instead closes a defect that is already there.** `oneCycle` asserts `windowsTorn() == 0`, and that assertion is satisfied by three different worlds it cannot tell apart: reads happened and none tore; reads happened and none *could* tear, because the harness stops calling `process` before the editor opens and the producer is stationary; and **no read ever happened at all**. `readWindow` returns before the increment when `self.history` is null or `self.window.load(.acquire)` is zero, so a `plugin.init` that dropped its `history` wiring, an `activate` that dropped `setWindow`, or a widened early return all pass it silently. ADR 0013's own Consequences section states the rule this breaks, three sections earlier, about `leaks`: "An absence has to be told apart from an instrument that did not run."

`Editor.uploaded` is the same move ADR 0013 already made once, on the same object, for the same reason. `framesPresented` exists because "the loop is running" and "the loop is drawing" were one claim and #5 split them. `windowsUploaded` exists because "the loop is drawing" and "the loop is drawing the samples" are one claim, and this is the issue that splits them.

## Changes

### `shaders/scope.metal`

Four additions below the existing pair, which stay: `TraceUniforms`, `TraceOut`, `trace_vertex`, `trace_fragment`.

```metal
struct TraceUniforms {
    uint  sample_count;
    float full_scale;
    float rail;
};

struct TraceOut {
    float4 position [[position]];
};

vertex TraceOut trace_vertex(uint vertex_id [[vertex_id]],
                             device const float *samples [[buffer(0)]],
                             constant TraceUniforms &uniforms [[buffer(1)]]) {
    const float x = 2.0 * float(vertex_id) / float(uniforms.sample_count - 1u) - 1.0;
    const float y = clamp(samples[vertex_id] * uniforms.full_scale, -uniforms.rail, uniforms.rail);

    TraceOut out;
    out.position = float4(x, y, 0.0, 1.0);
    return out;
}
```

Four details that are easy to get wrong and want a sentence each in the source:

- **No Y flip**, unlike `fullscreen_vertex` immediately above, which negates Y because its uv runs down from the top-left. A reader arriving from that function will expect the flip, so its absence has to be stated.
- **`device` rather than `constant` for the samples.** `constant` is for values indexed uniformly across a draw and carries a 64 KiB ceiling; `vertex_id` varies per vertex. 32 KiB would fit, which makes this a choice rather than a constraint.
- **`2i / (n - 1)`** puts the newest sample exactly on the right edge rather than one step short of it. The displayed duration is therefore `(n-1)/fs`, 19.979 ms at 48 kHz rather than 20 ms, a 0.1% discrepancy far below what a period count can resolve.
- **`n - 1` is why the draw is guarded at two.** At one sample this divides by zero.

`trace_fragment` takes no arguments, because the trace has no varyings yet, and returns a flat phosphor green. The colour is provisional and says so: phase 3 step 7's tonemap and palette own it, and it is a literal in MSL rather than a Zig constant precisely because nothing else needs it and phase 3 deletes it.

The file header is rewritten. It currently claims "The real passes arrive in plan phase 3" and "For now this only proves the compile path end to end", and both stop being true.

### `src/gpu/iface.zig`

- `trace_full_scale: f32 = 0.9` and `trace_rail: f32 = 0.98` beside `max_window_samples`, carrying the reasoning above: what full scale means, why the rail is inside the edge, what the rail's 1% is tied to, and that the display never rescales itself.
- No signature change, so the `comptime` block is untouched and the prose operation count at `:149-172` stays accurate. The trace adds vocabulary only inside the backend.
- One optional clause worth adding at `:187-192`. That comment predicted a line strip would be "one phase's way of drawing a trace" and argued no vertex type should cross the seam. #38 is the phase that could have falsified it and did not: the trace is drawn with no `MTLVertexDescriptor` at all, from a plain array indexed by `[[vertex_id]]`. Turning the prediction into a recorded outcome is this file's established habit.

### `src/gpu/metal/renderer.zig`

| Site                | Change                                                                                                                       |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `mtl`               | `primitive_type_line_strip: u64 = 2`, in numeric order above the triangle                                                    |
| New constants       | `Functions { vertex, fragment }`, `clear_functions`, `trace_functions`, and `passes` for the test to walk                    |
| New constants       | `window_buffer_index: u64 = 0` and `uniform_buffer_index: u64 = 1`, typed `u64` so the call sites lose their `@as`           |
| New types           | `TraceUniforms` (`extern struct { sample_count: u32, full_scale: f32, rail: f32 }`) and `Pipelines { clear, trace }`         |
| `Renderer.pipeline` | Becomes `pipelines: Pipelines`                                                                                               |
| `init`              | `const pipelines = try buildPipelines(device, diags); errdefer releasePipelines(pipelines);` One acquisition, one `errdefer` |
| `probe`             | The symmetric pair, matching the `buildWindows`/`releaseWindows` lines three below it                                        |
| `deinit`            | `releasePipelines(self.pipelines)` in the same position                                                                      |
| `buildPipelines`    | Compiles the library once, calls `buildPipeline` per pass, `errdefer clear.release()` between them                           |
| `buildPipeline`     | Takes the library and a `comptime Functions`; its body is the old one from the two `newFunctionWithName:` calls down         |
| `releasePipelines`  | The one release site for either state                                                                                        |
| `traceVertices`     | New pure helper beside `writeWindow`: `?u32`, null below two samples                                                         |
| `frame`             | Clear pass, then the guarded trace pass. See below                                                                           |

`frame`'s new tail, replacing `:464-486`:

```zig
encoder.msgSend(void, "setRenderPipelineState:", .{self.pipelines.clear});
encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
    mtl.primitive_type_triangle, @as(u64, 0), @as(u64, 3),
});

if (traceVertices(self.window_len)) |count| {
    encoder.msgSend(void, "setRenderPipelineState:", .{self.pipelines.trace});
    encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
        self.windows[self.slot], @as(u64, 0), window_buffer_index,
    });

    const uniforms: TraceUniforms = .{
        .sample_count = count,
        .full_scale = iface.trace_full_scale,
        .rail = iface.trace_rail,
    };
    encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
        &uniforms, @as(u64, @sizeOf(TraceUniforms)), uniform_buffer_index,
    });

    encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
        mtl.primitive_type_line_strip, @as(u64, 0), @as(u64, count),
    });
}

encoder.msgSend(void, "endEncoding", .{});
```

**No new early return enters `frame`**, and that is the first thing a reviewer of this function should check. The guard skips only the draw: the clear was encoded and the frame goes on to present it, so `.presented` stays the truthful answer. The inverse rule bites here as hard as the familiar one. AGENTS.md warns that an early return must not report `.presented`; reporting anything else for a frame that *did* reach the screen would be the same lie in the other direction, and `src/smoke.zig`'s `waitForFrames` would time out on it. The state is real rather than theoretical: `window_len` is zero until the first upload, so an editor opened on a plugin the host has not activated sits in it.

Three prose rewrites, each because the reason it gave has expired:

- The module doc at `:1-7`: "What it does today is clear a drawable to a dim colour. That is the whole deliverable of phase 1."
- The `background` comment at `:66-72`, whose argument is that "the clear alone would produce an identical picture while proving nothing". That expires the moment there is a trace over it. The new reason to keep the fullscreen pass is that phase 3's decay and tonemap are that pass.
- The comment at `:466-476`, whose entire subject is a buffer bound to a shader that does not read it. Deleted.

`primitive_type_line_strip = 2` was read out of `MTLRenderCommandEncoder.h` rather than recalled. Worth saying, because the block it joins has nothing to check itself against, and two independent attempts to recall this value from memory produced 5 and 1.

### `src/clap/gui.zig`

- `Editor.uploaded: std.atomic.Value(u64) = .init(0)`, beside `presented` and `torn`, incremented with a `.release` `fetchAdd` in `readWindow` on the success branch immediately after `renderer.upload(window)` returns.
- `pub fn windowsUploaded(self: *const Editor) u64`, acquire, beside `framesPresented` and `windowsTorn`.
- **Cleared in `Editor.destroy`** with the other two. It is the editor's count rather than the instance's, which is the distinction the comment already there exists to draw.
- `report` prints it alongside the rate, geometry, window and torn count.

### `src/smoke.zig`

Three assertions in `oneCycle`, one reopen cycle, and one interleaving change.

| Point in the cycle              | Assertion                                          | Error                      |
| ------------------------------- | -------------------------------------------------- | -------------------------- |
| After the first `waitForFrames` | `windowsUploaded() > 0`                            | `NoWindowUploaded`         |
| Across the resize               | The count advanced by at least one                 | `UploadsStopped`           |
| After `deactivate`              | The count stopped advancing                        | `UploadedWhileDeactivated` |
| After the reopen                | `windowsUploaded() > 0` again on the second editor | `ReopenedEditorStalled`    |

The first needs no extra wait, and the ordering is what makes it sound: `tick` calls `readWindow` before `renderer.frame()` and increments `presented` after both, so by the time `framesPresented()` has advanced at all, a `readWindow` has run to completion. If it ran and uploaded nothing, it returned early.

The third mirrors the existing `LoopRanWhileHidden` assertion in shape and reason, and covers a path nothing tests today. **Its ordering matters:** `deactivate` calls `setWindow(0)` as a release store from the main thread while a tick may already be inside `readWindow` holding a non-zero `want`, so wait one frame after `deactivate` to absorb the in-flight tick, then capture, then wait two more and assert no advance.

**The reopen cycle is the one addition beyond the counter.** `Editor.destroy`'s comment names a defect nothing tests: clearing `history` or `window` there "would leave the second editor reading nothing for the rest of the activation, with no symptom but a trace that never moved." That is precisely the Logic path, where an editor is destroyed rather than hidden, and #38 is the issue that makes the symptom visible. A second `create` / `set_parent` / `show` on the same still-activated plugin, before the deactivate block, makes the comment enforceable. `Editor.destroy` resets `uploaded`, so `windowsUploaded() > 0` on the second editor is the whole check.

**A few `process` calls move inside the wait loops**, so the audio path runs on the harness's main thread while the display link ticks on CoreVideo's. Today the producer is stationary from the moment the editor opens, which is why the torn count is not merely unlikely but unreachable. This makes it a genuine interleaving and lets `uploaded` see changing windows. **It does not close [#44](https://github.com/cboone/fosforo/issues/44)**, and the plan says so rather than letting it read that way: a weakened release store's visibility window is nanoseconds against a window that lags 20 ms, so a sine looks like a sine either way.

The `torn` assertion stays and its comment is corrected. With `uploaded > 0` proven it becomes a real statement about copies that happened.

## Tests

| File           | Test                                                                                                          |
| -------------- | ------------------------------------------------------------------------------------------------------------- |
| `renderer.zig` | The embedded shader defines the functions every pipeline asks for, walking `passes` rather than listing them  |
| `renderer.zig` | The shader reads the buffers at the indices the encoder binds them to, searching for `buffer(0)`/`buffer(1)`  |
| `renderer.zig` | A window shorter than one segment draws no trace: `traceVertices` of 0 and 1 are null, of 2 is 2              |
| `renderer.zig` | The trace draws one vertex per sample, at 960 and at `max_window_samples`                                     |
| `renderer.zig` | The trace's uniforms are laid out the way the shader reads them: size, alignment, three offsets, under 4 KiB  |
| `gui.zig`      | The rail leaves at least one backing pixel at the smallest editor: `(1 - rail) * min_size.height / 2 > 1`     |
| `gui.zig`      | The rail is outside full scale, so over-scale has somewhere to go                                             |
| `gui.zig`      | `setWindow`/`windowsUploaded` round-trip, and teardown clears `uploaded` with the other editor-owned counters |

The anonymous `test { refAllDecls }` block needs no change and does the load-bearing work: it is the only thing that type-checks the new `setVertexBytes:length:atIndex:` selector signature, since nothing in `zig build test` reaches `frame`. Its comment gains a clause naming that selector, because it is a genuinely new dependency on a test whose purpose is easy to mistake for a formality.

Two tests deliberately not written. Asserting `primitive_type_line_strip != primitive_type_triangle` asserts that the code says what it says; the block above them is honest that these have nothing to check against, and a second sentence claiming otherwise is worse than the gap. And re-clamping `window_len` inside `traceVertices` would state `max_window_samples` in a third place, when `upload` is its sole writer and clamps already.

## Documentation

**A new ADR 0017, on the principle and not the constants.** The vertical axis is fixed and absolute, ±1.0 is the reference, the display never rescales itself to the signal, and over-scale is shown as a rail rather than hidden or clipped away. Auto-gain is the single most common thing anyone proposes for a scope, and an ADR is the artifact that says do not relitigate this in review, supersede it. Its Consequences name what it forbids (auto-gain, peak normalization, per-window rescaling, soft compression above full scale) and what it defers (a user gain parameter in phase 4, a graticule later), both of which move the reference without touching the principle that the reference is stated. It deliberately does not pin 0.9 and 0.98, so those can move without superseding it. Add it to `docs/adr/README.md` and to the non-negotiables list in `AGENTS.md`.

**An amendment to ADR 0013**, following its own `## Amended by issue #5` precedent: `## Amended by issue #38: what the harness can assert about the samples`. Three things. The readback decision and the sharpened criterion above. What the harness now asserts, with the planted defects that verified each, in the table shape the #5 amendment already uses, including the plant that passes. And the `torn` finding, stated against the ADR's own "an absence has to be told apart from an instrument that did not run". While there, correct two stale lists in place and say inside the new section that they were corrected, because a silent edit to an ADR looks like what that directory's rules forbid: the `Outcome` bullet omits `no_frame_slot`, and the seam-operation list omits `upload` and `liveWindowBuffers`.

**Five gotchas in `AGENTS.md`**, all of them things that fail silently or read as defects:

- **Metal has no line-width API**, verified against the SDK headers rather than assumed. A line strip rasterizes at exactly one device pixel, which on a 2x drawable is half a point: thin, dim, and jagged. That is the deliverable. The three ways to thicken it are all wrong here, and the right one is phase 3 step 4's beam-as-geometry.
- **A one-pixel line whose centre lands on the drawable's edge may rasterize to nothing**, because half its coverage diamond is off-screen, so a trace clamped to ±1.0 NDC would read as absent rather than as railed. That is why the rail sits 1% inside and why 1% is safe. The benign twin is the centre line at even drawable heights, and it is the first thing to suspect if silence draws nothing rather than a flat line. The fix, if it is ever needed, is a half-pixel bias of `+1.0/H` in NDC, which needs the drawable height in the uniform.
- **The trace's floor.** Below roughly -54 dBFS at the default editor, or -42 dBFS at the smallest on a 1x display, a sine moves the trace less than one backing pixel and reads as flat.
- **Nothing links `TraceUniforms` to the MSL struct of the same name.** The layout test is the only thing that would notice a field added or reordered on one side, and the symptom is a plausible-looking trace at the wrong scale rather than anything that fails.
- **Amend rather than delete the "phase 1 render is indistinguishable from a black window by eye" bullet.** The background-only case still looks exactly like failure, and the issue's own verification section makes the sharper point: a trace stuck flat at zero also looks correct against silence, and a frozen window looks identical to a live one against steady material.

Also: the structure line in `AGENTS.md` reading "device, pipeline, layer, one frame" needs pluralizing, and a CHANGELOG `Added` entry.

Update phase 2's status in `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`. This is its last step, so its exit criteria are met or they are not, and the plan should say which.

## Verification

```bash
zig fmt --check build.zig src/
zig build test
zig build
zig build validate-shaders          # xcrun --kill-cache first if the toolchain reports missing
zig build smoke-gpu
zig build smoke-appkit
zig build smoke-leaks
```

Then all of it again under `--release=fast`, on #37's precedent: everything above is Debug, and the shipping build compiles `std.debug.assert` out along with the `assertNotMainThread` in the new code paths.

`smoke-gpu` is worth naming rather than listing. `validate-shaders` is `-fsyntax-only` and never links a pipeline state, and `newRenderPipelineStateWithDescriptor:` is exactly where a vertex function whose buffer arguments the pipeline cannot satisfy fails. So the new shader is covered by two CI jobs rather than one, and `probe` gets stronger for free.

**`smoke-leaks` is a step, not a formality.** The pipeline count doubles, and AGENTS.md's rule is that a Metal resource added later that is not a buffer must be checked against `leaks` with a planted leak before assuming the harness covers it. Drop one `release` from `releasePipelines`, run it, and confirm it goes red. If it does not, that is a second blind spot of the same kind as `live_windows` and it needs recording rather than shrugging at.

### Planted defects

Each targets exactly one assertion, on the `Ring.capacity` and `no_drawable` precedent.

| Plant                                                    | Expected                                                                                                                                                                                                                                                                                                                                                   |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Delete `self.editor.history = &self.history` in `init`   | `NoWindowUploaded`. Also run `zig build test`, because the value of this plant is that it is harness-only coverage and that prediction has to be measured                                                                                                                                                                                                  |
| Delete `setWindow` from `activate`                       | `NoWindowUploaded` **and** a unit-test failure, so it is a control that the two agree rather than evidence of unique coverage                                                                                                                                                                                                                              |
| An early return at the top of `readWindow` after frame 1 | `UploadsStopped`                                                                                                                                                                                                                                                                                                                                           |
| Delete `setWindow(0)` from `deactivate`                  | `UploadedWhileDeactivated`                                                                                                                                                                                                                                                                                                                                 |
| Clear `window` in `Editor.destroy`                       | `ReopenedEditorStalled`                                                                                                                                                                                                                                                                                                                                    |
| Drop one `release` from `releasePipelines`               | `smoke-leaks` red, or a recorded second blind spot                                                                                                                                                                                                                                                                                                         |
| Make `Renderer.upload` a no-op                           | **Passes.** Record it as the limit, in the words `live_windows` already uses: the counter proves the window was read and handed across the seam, not that the backend copied it. Changing `upload` to return a count so the harness could catch it would be shaping the seam to the harness, which is what `probe`'s docstring is careful to say it is not |

### What was run, and what it found

Everything below passed. The split matters, because only the first two blocks are repeatable by the next person to touch this.

| Check                                                | Result                                                   |
| ---------------------------------------------------- | -------------------------------------------------------- |
| `zig fmt --check`, `zig build test`                  | Clean, 154 tests                                         |
| `zig build`, `zig build validate-shaders`            | Clean                                                    |
| `zig build smoke-gpu`, `smoke-appkit`, `smoke-leaks` | Clean; 400 cycles, 288 leaks and 18,816 bytes, none ours |
| The same four under `--release=fast`                 | Clean                                                    |
| `shfmt`, `shellcheck`, `markdownlint-cli2`, `typos`  | Clean                                                    |
| The six planted defects                              | As tabulated above, with two corrections recorded below  |
| REAPER and Logic, steps 1 to 7                       | Passed. The measurements are below                       |
| Step 8                                               | Observed throughout rather than run as a step            |

**Two of the planted defects did not behave as the plan predicted, and both corrections are worth more than the rows they fix.**

The plan expected dropping the editor's history wiring to be caught only by the harness. It is also caught by `zig build test`, against the existing test "init points the editor at the instance's history". So that row is a control showing the two levels agree, not evidence of unique coverage, and the plan was wrong to imply otherwise. Dropping `setWindow` from `activate` behaves the same way, which the plan did predict.

The plant for `UploadsStopped` had to be strengthened before it tripped. A `readWindow` that stops once one *frame* has been presented still uploads a second window, because the count is captured after the first wait and the assertion asks only that it advanced; the assertion caught it only once the plant stopped after one *upload*. What `UploadsStopped` catches is a path that stopped, not one that slowed, and that is now stated where the assertion lives.

### The level sweep, measured in REAPER

Step 5 was run against the installed CLAP with `scripts/make-test-tones`' output, and read out of screenshots rather than by eye. The drawable was detected as exactly 1920x1080 in every capture, so the editor was at its default size on a 2x display.

| File          | Peak row | Trough row | Read back as   | Actual level |
| ------------- | -------- | ---------- | -------------- | ------------ |
| `level-1.000` | 54       | 1025       | +1.0000        | 1.000        |
| `level-1.050` | 29       | 1050       | +1.0514        | 1.050        |
| `level-1.089` | 10       | 1069       | +1.0905, rails | 1.089        |
| `level-2.000` | 10       | 1069       | +1.0905, rails | 2.000        |

Every row matches the offscreen prediction exactly, and levels below the rail read back their own value to within a pixel. **The peak climbs and then stops**: 1.089 and 2.000 are identical in peak and trough, so a file peaking at 2.0 is reported as 1.089 with the amount unknowable. That is [ADR 0017](../../adr/0017-absolute-vertical-axis.md)'s claim, observed rather than argued, and it is the first evidence covering the whole chain: REAPER, the tap on output channel 0, the ring, the trailing-window read, the upload, the shader, the pixels.

**Two things about the measurement were harder than the picture**, and both are recorded because they cost time and would cost it again.

A lossy screenshot cannot be measured at all. The first capture arrived as HEIC with a `.png` name, and the codec smeared the one-pixel trace into a halo tens of pixels deep: the drawable held **256 distinct green levels** where a lossless render of this shader holds two, and the analyser confidently reported a full-scale signal as railed. Raising the threshold did not rescue it, because at 240 the halo still reached the top of the drawable. Capture with `screencapture -o -x -t png -W`, where `-t png` forces lossless and `-o` drops the window's drop shadow.

That shadow is the second trap. Over a dark desktop it is near-black with a blue cast, which is also the background's signature, so an automatic crop keyed on colour alone stretched 119 rows past the real drawable and divided by the wrong height. Keying on the exact `RGB(5, 5, 8)` with the blue lead constrained to the 2-to-4 the shader produces separates them.

One observation left unexplained, because it is 0.3% and did not recur: `level-1.089` lit 1914 of 1920 columns where the other three lit all 1920. The likely cause is the horizontal twin of the rail problem, the first and last vertices sitting at x = ±1 exactly, on the drawable's edge where half a one-pixel line's coverage diamond is off-screen.

### Both hosts, and what bypass revealed

Step 7 passed in both. REAPER's `hide` and `show` on a playing track resume the trace, and **Logic's full `destroy` / `create` / `set_parent` on a still-activated instance brings it back live rather than flat**, which is the defect `Editor.destroy`'s comment names and the one `ReopenedEditorStalled` was added to cover. That comment is now enforced at two levels rather than being an assertion about code nobody had exercised.

**Bypassing the plugin in REAPER freezes the picture on the last frame drawn, and un-bypassing resumes it.** That was not in the procedure and it is worth recording, because it is the stationary-window path reaching a host for the first time. `readWindow` says that when there is no window to read "the renderer keeps whatever it last held", and `src/smoke.zig` asserts exactly that after `deactivate`: uploads stop, frames keep presenting, the last good window is drawn again. Bypass arrives at the same state by a different route, so the behaviour is the design rather than a surprise.

It is also, precisely, the hazard stated in `AGENTS.md`: a window frozen seconds ago is indistinguishable from a live one against steady material. A bypassed Fósforo displays a signal that is not the current signal and says nothing about it.

Left as an open question rather than fixed here, for two reasons. The plugin cannot detect bypass directly, since CLAP expresses it as a parameter flag and there are no parameters until phase 4, so any answer is a heuristic on the cursor having stopped advancing. And the same mechanism would serve a general no-signal indication, which is a feature decision rather than a correction to this issue. **Which route REAPER takes is worth establishing first and costs nothing:** the debug line reports the window count, so bypass that reports `0 sample window` means the host called `deactivate`, and one that keeps reporting `960` means it merely stopped calling `process`.

### The standstill, and the jitter that hid it

Step 4 was run on a 16-inch MacBook Pro, whose Liquid Retina XDR panel is ProMotion and therefore the case this plan originally said to skip. It works, with one condition.

| Refresh | Tone  | Result                                 |
| ------- | ----- | -------------------------------------- |
| 120 Hz  | 120.0 | Standstill, at a 16-sample block       |
| 60 Hz   | 60.0  | Standstill, 1.2 periods, one peak      |
| 60 Hz   | 120.0 | Standstill, 2.4 periods, **two peaks** |

**The harmonic is what makes this conclusive.** A standstill at `R` alone could be a coincidence; one at `R` and `2R` in the same configuration, distinguishable by period count, could not. It holds only if the window advances exactly `fs/R` samples per frame, which is the claim being tested.

**The first attempt reported the standstill at 121.15 Hz, and that was the instrument rather than the signal.** At a 64-sample block the trace jitters by 58 degrees of phase, and a standstill cannot be located by eye to better than the jitter around it. Dropping to a 16-sample block cut the jitter to 14 degrees and the standstill moved to 120.0, the predicted value. Nothing drifted at either block size, which was the real result all along: no drift is what proves the right edge tracks the present, and the standstill frequency is a refinement on top of it.

The residual jitter is block quantization and is not reducible from here: the cursor advances only when `process` runs, so it moves in whole blocks, and 48 kHz at 120 Hz needs 400 samples a frame, which no block size divides. It is exactly what phase 4's triggering removes.

### The channel trap, and the half pixel at the centre line

Step 6 was measured the same way, and it is the check that proves the trace is drawing the channel it claims rather than something correlated with it.

| File             | Peak row | Trough row | Read back as | Columns lit    |
| ---------------- | -------- | ---------- | ------------ | -------------- |
| `pan-hard-left`  | 297      | 782        | +0.5000      | 1920 of 1920   |
| `pan-hard-right` | 539      | 539        | +0.0021      | 1920 of 1920   |

Hard left is pixel-identical to `level-0.500`, which is the tone arriving on output channel 0 at full level. Hard right has peak equal to trough equal to a full-width plateau, which is a flat line: channel 0 is silent, as it must be, since the tap is `out.data32[0]`.

**Silence reads `+0.0021` rather than `+0.0000`, and that is one pixel rather than a residual signal.** A flat trace at `y = 0` lands on row 540.0 of a 1080-tall drawable, an exact pixel boundary, so rows 539 and 540 are equally valid and the rasterizer picks one. It picked 539. One pixel at this geometry is 0.00206 in sample units, which is the -53.7 dBFS floor this plan already documents, so the reading is off by the smallest amount the display can represent.

**The half-pixel bias that would centre it is deliberately not applied.** It would be `+1.0/H` in NDC, and three things argue against it: nothing can see half a pixel; `Renderer` stores no size at all, so `resize` would have to begin keeping one purely to get `H` into `TraceUniforms`; and phase 3's beam-as-geometry replaces this rasterization outright and re-answers the question with different machinery. The failure that would change that verdict is the line *flickering* between rows 539 and 540 during playback, which is the tie-break going unstable and would read as shimmer on silence. That was watched for and did not occur.

### The mapping was measured offscreen rather than reasoned about

The vertical mapping and the period count are the two claims a host check would confirm last and least precisely, so both were measured first, with a throwaway Objective-C program that compiles `shaders/scope.metal` with the real Metal compiler, draws the trace pass into an offscreen `BGRA8Unorm` texture it owns, and reads the pixels back.

**It is deliberately not in the repository.** It renders to its own texture rather than to the shipping renderer's drawable, so it neither needs nor implies relaxing `framebufferOnly`, and the shader it probes is one phase 3 replaces. It is recorded here the way the `leaks` RSS figures are recorded in `AGENTS.md`: as a measurement someone can reproduce, not as a check that runs.

At 960x540 with `full_scale = 0.9` and `rail = 0.98`, every constant-level case landed within one pixel of the arithmetic, each lighting exactly one pixel per column:

| Sample   | Expected row | Measured row |
| -------- | ------------ | ------------ |
| `0.000`  | 270.0        | 269          |
| `+0.500` | 148.5        | 148          |
| `+1.000` | 27.0         | 26           |
| `-1.000` | 513.0        | 512          |
| `+1.050` | 14.85        | 14           |
| `+1.089` | 5.4          | 5            |
| `+1.111` | 5.4          | 5            |
| `+2.000` | 5.4          | 5            |
| `+8.000` | 5.4          | 5            |
| `-2.000` | 534.6        | 534          |

Three things fall out of that table. Silence draws a real pixel on the centre row rather than nothing, so the benign half of the boundary-rasterization concern is confirmed benign at an even drawable height. Everything from `+1.089` up is pixel-identical, which is the instrument declining to say how far over it is. And `+1.05` is visibly over full scale without being railed, at row 14 against full scale's 26 and the rail's 5, which is the margin doing the job it exists for.

**That last row is also where the probe caught a wrong number in this plan.** The headroom was written as +0.92 dB, from `1 / full_scale = 1.111`. The rail is reached at `rail / full_scale = 1.0889`, which is **+0.74 dB**; 1.111 is where the trace would reach the drawable's edge unclamped, and it never gets there. The original level-sweep table below called 1.111 "the last level that is not railed", which the measurement flatly contradicts.

Sines at 0.8 amplitude, counted by peaks across the 20 ms window, came back exact at 50, 100, 200, 250, 400 and 1000 Hz: 1, 2, 4, 5, 8 and 20 periods, matching `f x 0.020` in every case.

**The first version of that counter was wrong and passed everything anyway**, which is the part worth keeping. It counted upward zero crossings against the centre row using the topmost lit pixel per column, and a steep segment crossing the centre lights every row it spans, so the topmost pixel reads as "above" whatever the sample was. Every tone came back exactly one period low, and a ±1 tolerance called all six "ok". Counting peaks instead, against a strict equality, is what produced the numbers above. A tolerance wide enough to absorb a systematic error is a tolerance that hides one.

### In a host

**Still to be done by the author**, and it is what closes phase 2's exit criterion. The offscreen measurements above cover the arithmetic; none of them proves that the samples reaching the shader in a DAW are the ones the DAW is playing.

**The signals come from `scripts/make-test-tones`**, which renders them as 32-bit float and reads each one's peak back out of the finished file. Three of the level cases sit above 1.0, so no integer format can hold them, and no dB knob in a DAW is accurate enough: REAPER's stock Tone Generator and `JS: Volume Adjustment` both compute gain as `2 ^ (x / 6)`, which is a factor of two per six decibels rather than 6.0206 dB. The Tone Generator is still the right source for step 4, where an integer Hz field that nudges by one matters more than exact level.

**Read the trace by measuring pixels, not by looking at it.** The rows below are backing pixels and the difference between a passing and a failing level check is tens of them, which no eye resolves. `screencapture -o -R<x,y,w,h> shot.png` writes backing pixels on a Retina display, which is the unit these tables are in, and Terminal needs Screen Recording permission or the capture comes back empty. A second oscilloscope plugin is not a substitute: it answers a question about the audio, and every step here is a question about this plugin's rendering of the audio, whose reference is arithmetic rather than another instrument.

**Build order is load-bearing here in a way it usually is not.** This verification needs the *Debug* CLAP, because the once-a-second `rendering at N Hz` line is Debug-only and the standstill test below reads the refresh rate from it, and `cmake --build` silently rebuilds and re-signs `zig-out/Fosforo.clap` as ReleaseFast. So: Audio Unit first, then `zig build`, then `zig build install-plugins`, then read both hash pairs and confirm both match before believing anything below.

1. **Silence.** A horizontal line on the centre row. Check it by pixel sample rather than by eye: sample `(W/2, H/2)` and confirm the trace colour, sample `(W/2, H/4)` and confirm `RGB(5, 5, 8)`. If the centre row is background, suspect the boundary-rasterization case above before suspecting the signal path. The front zero-padding never appears in a host, which is worth knowing before going looking for it: `activate` calls `history.clear()`, which writes a full capacity of silence *through* `Ring.write`, so the pad is unreachable and silence draws flat because the samples are zero.
2. **Liveness, checked on the stop rather than the start.** With a sine playing, stop the transport: the trace must return to flat within about 20 ms plus a refresh period. A frozen window keeps showing the sine indefinitely, so this fails loudly where "it appeared quickly" does not. Toggle half a dozen times.
3. **Frequency, counted as a ratio.** At 48 kHz the window is 960 samples, so 50 Hz shows 1 period, 100 Hz shows 2, 250 Hz shows 5, 1 kHz shows 20. Count 100 and 250 by eye and 1 kHz from a screenshot. **The decisive form is the ratio:** 100 → 200 → 400 Hz must give 2 → 4 → 8, which is robust to phase, to the `(n-1)` quibble, and to miscounting a partial period at an edge. Then change the device sample rate and repeat: 100 Hz must still show 2 periods at 44.1 kHz and at 96 kHz, which is the first end-to-end check that `window_seconds` is a duration rather than a sample count.
4. **The stroboscopic standstill.** Between frames the window shifts by `fs/R` samples, so a tone at a whole multiple of the refresh rate advances a whole number of cycles per frame and stands still. Read `R` from the debug line, play a sine at `R` Hz, confirm the standstill, then detune by 1 Hz and confirm a 1 Hz crawl. This proves the window is live, the X axis is linear in time, and the right edge tracks the present, all at once.

   **Use the smallest block size the device offers, which is the whole difficulty of this check.** The cursor advances only when `process` runs, so it moves in whole blocks and no block size divides the 400 samples a frame needs at 48 kHz and 120 Hz. Consecutive frames therefore alternate between too few blocks and too many: the average is exact, which is why nothing drifts, and each frame is off by up to one block. At a 960-sample window on a 1920-wide drawable that is 2 px of horizontal jitter per sample of block, so 128-sample blocks jump a quarter of the screen and 16-sample blocks jump 32 px. **That jitter is what phase 4's triggering exists to remove**, since a trigger aligns the window to the signal rather than to the cursor.

   **Confirm the harmonic rather than the single frequency.** A standstill at `R` alone could be luck; one at `R` and `2R` together cannot, and the two are distinguishable by period count, since `2R` shows twice as many. That is the form the check should take.

   ProMotion is workable rather than disqualifying, which is a correction to an earlier draft of this plan. Pinning the display to a fixed rate in System Settings removes the variable-refresh confound and is worth doing if the result is ambiguous.
5. **Level sweep**, from rendered WAVs at verified peaks rather than a gain knob. The plugin passes audio through, so the host's own meter after it is a free independent readout.

   **Read the peak's position, not its shape.** Railing shows up as the peak *ceasing to climb*, and a visible flat top is a secondary cue that only appears well past the threshold. Rows are for a 1920x1080 drawable, the default editor at 2x:

   | Peak  | dBFS  | Peak row (top / bottom) | Travel clipped off | What it looks like                      |
   | ----- | ----- | ----------------------- | ------------------ | --------------------------------------- |
   | 0.002 | -54   | 539 / 541               | none               | One pixel each way: the practical floor |
   | 0.010 | -40   | 535.1 / 544.9           | none               | About 10 px total, visibly not flat     |
   | 0.100 | -20   | 491.4 / 588.6           | none               | A tenth                                 |
   | 0.500 | -6.02 | 297 / 783               | none               | Exactly half the excursion              |
   | 1.000 | 0     | 54 / 1026               | none               | A 43 px dark strip above the peak       |
   | 1.050 | +0.42 | 29.7 / 1050.3           | none               | Over full scale, still not railed       |
   | 1.089 | +0.74 | 10.8 / 1069.2           | 0.1 px             | Railing begins, and is **invisible**    |
   | 2.000 | +6.02 | 10.8 / 1069.2           | 443 px             | **Same row as 1.089**, now plainly flat |

   **The check is that the peak climbs to 1.089 and then stops.** 1.089 and 2.000 must be pixel-identical in height, which is the whole of what ADR 0017 means by refusing to say how far over the signal is.

   **Do not look for a plateau at 1.089.** It is where clamping *begins*, so it removes a tenth of a pixel of travel, and anyone hunting a flat top there will report a defect that is not one. A plateau becomes 1 px deep at 1.091 and 5 px at 1.100; the sine at 2.000 loses 443 px of travel and is unmistakable.

   `saw-1.100.wav` is the sharpest small-overshoot case, because a saw crosses the rail on a linear ramp rather than at a turning point: 0.51% of the ramp sits above it, which is about 5 px wide and 5 px deep. A clipped sine's plateau can be mistaken for a rounded peak at low zoom; a clipped saw's flat top with a vertical edge cannot.

   Use a sawtooth or square at 0.9 and 1.1 as well as a sine: a clipped sine's plateau can be mistaken for a rounded peak at low zoom, and a clipped saw's flat top with a vertical edge cannot.

6. **The channel trap.** The tap is `out.data32[0]`. Pan a mono sine hard right and the trace must go flat; hard left and it must be full. Someone who skips this and tests with a hard-right-panned tone will file a bug against a working plugin.
7. **Both hosts.** REAPER, CLAP, Debug, launched from a terminal: close and reopen the FX window on a *playing* track, which is `hide`/`show`, and confirm the trace resumes. Logic, Audio Unit, ReleaseFast, no readable diagnostics: closing and reopening the plugin window is a full `destroy`/`create`/`set_parent` on a still-activated instance, which is the single most valuable manual check here, because it is the defect `Editor.destroy`'s comment names. Confirm the trace comes back live rather than flat. Open two instances on two tracks with different material and confirm each draws its own signal.
8. **The slide is expected.** At 60 Hz, 83% of a 20 ms window is new audio every frame, so the trace jumps rather than scrolls and reads as random phase jitter under periodic material. Triggering is phase 4. **Slide moves the phase and preserves the shape and the amplitude**, so a sine of stable amplitude and stable period whose only moving property is phase is a correct signal path; a shape that changes, an amplitude that wanders, or a picture that freezes is not. Step 4 is the version of this that has an answer rather than an impression.

## Out of scope

Recorded so they read as deliberate omissions rather than oversights.

- **Persistence, decay, tonemap, palette, velocity-weighted intensity, and beam-as-geometry.** All phase 3, which is the phase this exists to unblock.
- **Bandlimited reconstruction**, phase 3 step 6. The trace follows the samples rather than the true continuous curve, so intersample overshoot is invisible.
- **Decimation.** At 48 kHz and the default width it is one sample per point and does not bite. Above that, or in an editor dragged narrower, it aliases, which is what "crude aliased" means. Min/max decimation is phase 3.
- **Triggering.** Phase 4. See verification step 8.
- **Blending, MSAA, and any attempt to thicken the line.** See the gotcha above.
- **NaN.** Nothing in the path rejects a non-finite sample: the tap, `Ring.write`, `read`, `upload` and `writeWindow` are all copies, so a NaN from a broken upstream plugin reaches the vertex shader, and Metal's default fast math means `clamp`'s NaN behaviour is not guaranteed. The worst case is a stray line for one frame. Recorded rather than fixed, because fixing it properly means deciding fast-math policy, which is phase 3's decision, and the cheap fix when wanted is a finite check in `Renderer.writeWindow`, on the CPU side where Zig's float semantics are guaranteed and Metal's are not.
- **[#44](https://github.com/cboone/fosforo/issues/44), the ring's memory ordering.** Interleaving `process` with the render loop is not a test of it, and the plan says so where the change is made.

## Risks to watch at the keyboard

Two coercions that may need a one-line adjustment, neither of them design questions:

- `platform.nsString(functions.vertex)` needs `[:0]const u8` to reach `[*:0]const u8`. If 0.16 refuses, widen `platform.nsString` to take `[:0]const u8` and pass `text.ptr`; every existing caller still coerces.
- `"..." ++ functions.vertex` needs `++` on a comptime-known slice for the missing-function diagnostic. If it refuses, `std.fmt.comptimePrint` returns a sentinel array pointer that coerces and reads no worse.

## Commits

1. `docs: plan the crude aliased trace and the vertical scale (#38)`
2. `feat: publish the trace's vertical scale on the renderer seam (#38)`
3. `feat: draw the sample window as a line strip (#38)`
4. `test: count uploaded windows and reopen an editor in the harness (#38)`
5. `docs: record the absolute vertical axis as ADR 0017 (#38)` (landed as 0016 and renumbered when `main` merged, which had taken 0016 for the ring-ordering ADR)
6. `docs: amend ADR 0013 with what the harness can assert (#38)`
