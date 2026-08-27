# Accumulate the beam into a persistent RGBA16F texture

Issue [#55](https://github.com/cboone/fosforo/issues/55). Phase 3, steps 2 and 8 of `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`. Depends on [#38](https://github.com/cboone/fosforo/issues/38), which landed the trace this deposits into and merged as [#54](https://github.com/cboone/fosforo/pull/54).

## Context

Phase 2 closed with a trace that is redrawn from nothing every frame. `Renderer.frame` clears the drawable, draws a one-pixel line strip over it, presents, and discards everything. Nothing survives a frame, so nothing about the signal's history reaches the screen.

[ADR 0007](../../adr/0007-renderer-simulates-a-crt.md) says the renderer is a simulation of a cathode-ray tube, and its first concrete consequence is a persistent floating-point buffer the beam deposits energy into. Every remaining step of phase 3 stands on it: the decay ([#56](https://github.com/cboone/fosforo/issues/56)) dims it, the beam geometry ([#57](https://github.com/cboone/fosforo/issues/57)) deposits into it with an intensity profile, velocity weighting ([#58](https://github.com/cboone/fosforo/issues/58)) varies how much, and the tonemap ([#60](https://github.com/cboone/fosforo/issues/60)) is what reads it. None of those can start until there is somewhere for a beam to leave energy.

Floating point rather than 8-bit is the part most likely to be economised away, so it is stated: an 8-bit alpha blend toward black **stalls**. Once a value is small enough that multiplying it by the decay factor rounds back to the same integer, it stops decaying and stays lit forever, leaving ghost trails that never clear. Float has no such floor, and it accumulates past 1.0 where the beam dwells, which is the input [#60](https://github.com/cboone/fosforo/issues/60) needs in order to produce a hot core without drawing one.

The issue folds the build plan's step 8 in with step 2, and it is right to: an accumulation texture that does not survive a window drag is broken the first time anyone drags one. `Renderer` currently stores no size at all, so this is also where that changes.

The intended outcome is a display whose trace fades rather than snapping, whose geometry at a standstill is pixel-identical to what [#38](https://github.com/cboone/fosforo/issues/38) measured, and whose accumulation survives a resize by being rebuilt rather than by being stretched.

## The decisions the issue asks for

### Two textures with ping-pong, as the issue specifies

A decay pass reads `accum[source]` and writes `accum[1 - source]`; the trace deposits additively into the same target; a resolve pass reads that target and writes the drawable. The index advances and the roles swap.

The alternative was one texture with the decay expressed as fixed-function blend state (`sourceRGBBlendFactor = zero`, `destinationRGBBlendFactor = sourceColor`) against `loadAction = Load`, which halves the memory to 16.6 MB and removes a full-screen read and write every frame. It is rejected for three reasons, recorded so it is not re-proposed: the issue asks for ping-pong in those words; a decay expressed as blend state can only ever be spatially uniform, where ping-pong keeps a per-pixel decay reachable without a structural change; and it hides the decay in pipeline state rather than in a shader body, where [#56](https://github.com/cboone/fosforo/issues/56) has to find it.

### The accumulation and the drawable are sized from one integer expression

`Renderer.resize` currently forwards `size` and `scale` to the layer and keeps neither, and `drawableSize` hands `CAMetalLayer` a `CGSize` computed as `points * scale` in `f64`. `Pending.Packed` quantizes the scale to 1/256ths, so a scale that is not exactly 1.0 or 2.0 produces a fractional drawable size, and whatever rounding `CAMetalLayer` applies to it is undocumented.

That is a live correctness question the moment a second surface has to line up with the drawable, because the resolve pass reads the accumulation at integer pixel coordinates. A texture one pixel narrower than the drawable is an out-of-bounds read, which MSL does not define as a benign zero.

So a new backend-local `Pixels` type carries whole backing pixels, `backingPixels(size, scale)` is the one place the scale factor is applied and the one place the result becomes an integer, and the layer receives a `CGSize` built from those integers. There is then nothing left for the layer to disagree with. `Renderer` stores `pixels` and not `size`/`scale`, because whole backing pixels are what the textures need, what the layer needs, and what the half-pixel centre-line bias in `AGENTS.md` was declined for wanting.

### The decay factor is provisional, and the resolve applies no gain

[#56](https://github.com/cboone/fosforo/issues/56) owns decay in real elapsed time and owns the genuine open decision inside it (the `CVTimeStamp` CoreVideo hands the callback, or `display_link.monotonicNanos()`). It is not economised into this step. But **no** dimming is not an option either: a persistent texture with an additive deposit and no decay saturates to white within a second or two, which would make this step unjudgeable and turn [#56](https://github.com/cboone/fosforo/issues/56) into a blocker rather than a refinement.

So this step carries a constant per-frame factor, `decay_per_frame = 0.90`, and [#56](https://github.com/cboone/fosforo/issues/56) replaces the value in `frame` with `exp(-dt / tau)`. It reaches the shader as a uniform rather than as an MSL literal, on `TraceUniforms`' precedent rather than `trace_fragment`'s: a value #56 must vary per frame needs the binding either way, and a constant on the Zig side is one a test can hold a range on.

The number is chosen so that [#56](https://github.com/cboone/fosforo/issues/56)'s absence is visible on this machine rather than hidden by it. At 120 Hz a deposit falls to 5% in 28 frames, about 237 ms; at 60 Hz the same 28 frames are 474 ms. The development machine's ProMotion panel drifts between 48 and 120 Hz, so the persistence will visibly depend on what else the machine is doing. That is the defect #56 exists to fix, and it should be legible rather than subtle.

**A gain of `1 - decay_per_frame` was planned here, written, and removed after a host measured it.** The reasoning was that a pixel the beam visits every frame reaches a steady state of `deposit / (1 - decay)`, so scaling by that factor makes a stationary trace resolve to exactly the colour #38 drew and keeps that issue's geometry tables comparable. All of that is true, and it is the wrong case to optimise: a sliding trace never lights the same pixel twice, so it never accumulates, so the gain divides every real signal by ten. In REAPER a 100 Hz sine rendered as a black display, at a measured peak green of 53 against 255.

So the resolve writes accumulated energy as it is and the format clips whatever exceeds 1.0. That is ADR 0007's shape rather than a retreat from it, and the arithmetic says no linear alternative exists: the ratio between a fresh deposit and a dwelt-on one is `1 / (1 - decay)`, or 10:1 here, and an 8-bit linear mapping can show one end of that or the other. A stationary trace therefore saturates toward white, which is what a dwelling beam should do and what [#60](https://github.com/cboone/fosforo/issues/60)'s tonemap exists to map.

What survives from the plan is the range test: `0 < decay_per_frame < 1` is what makes a planted decay of `1.0` or `0.0` fail `zig build test` rather than needing an eye.

### The accumulation is cleared at allocation, and the clear belongs to the function that allocates

`newTextureWithDescriptor:` does not contract that it returns zeroed memory. Relying on the zero fill that Apple Silicon happens to perform would be the kind of assumption this project refuses, and the failure mode is not a transient smudge: garbage in an `RGBA16F` is very likely a NaN bit pattern, and `NaN * 0.90` is `NaN` forever. That is a permanent screen-full defect.

`buildAccumulation` therefore clears both textures before returning, through one command buffer holding two empty render passes (`loadAction = Clear` to zero, `storeAction = Store`, no draws), committed without waiting. Queue ordering places it before the next frame. Making the clear part of the allocating function rather than a step in a call sequence is what makes "an allocated accumulation always holds defined data" a property of one function.

Both are cleared rather than only the initial source, so the invariant survives any later change to which index is read first. The clear is to zero energy and **never** to `background`: a re-added background floor reaches `background / (1 - decay)` at steady state, which at 0.90 is ten times the background and a bright grey field.

### A skipped frame neither decays nor deposits, and the swap point is what enforces it

Both passes go into the one command buffer the frame already builds, after `nextDrawable` succeeds. `accum_source` advances immediately before `return .presented`, so every early return leaves the pair untouched: the source still holds valid accumulated energy, and the target holds stale data that the next frame's `DontCare` load action and full-screen decay draw overwrite completely.

The reason is not latency. `writeWindow` has already copied staging into `windows[slot]` by the time `nextDrawable` is called, and successive windows overlap by about 98% at 60 Hz. A frame that deposited without presenting would have its energy deposited again by the next frame, which makes **brightness a function of compositor load**, precisely the artifact ADR 0007 exists to avoid, since brightness is supposed to be a readout of the signal's statistics.

Note the deliberate asymmetry with the slot, because both live in the same function: `slot` advances on a **successful wait**, because a successful wait is what proves the buffer is free. `accum_source` advances on a **commit**, because a commit is what proves the target was written. Two invariants, two advance points.

The cost is that persistence advances per committed frame rather than per tick, which is a real inaccuracy and is [#56](https://github.com/cboone/fosforo/issues/56)'s to absorb: `dt` must be measured across committed frames, not across ticks.

### A failed reallocation is a real machine condition, so it is reported rather than asserted

`resize` returns `void` and runs on the render thread with nothing to print to (ADR 0010). `gui.max_size` is 8192x8192 logical points, which at a backing scale of 2 is 16384x16384 pixels and **2 GiB per texture**; that bound was chosen against Metal's texture *dimension* limit, at a time when the only texture was a `framebufferOnly` drawable CoreAnimation allocated. Nothing refuses it now.

So `accum` is `?[2]objc.Object`. A failed allocation leaves it null, `frame` returns a new `iface.Outcome` member `.no_accumulation` before taking a semaphore slot, and a later successful resize restores it. The alternative, storing nil and messaging it, is worse than a skipped frame: messaging nil is a silent no-op, so the frame would present a drawable nothing had written.

`iface.Error` gains `TextureAllocationFailed` rather than reusing `BufferAllocationFailed`, whose doc comment names the window buffers specifically and describes a failure no user can provoke. This one scales with the editor's geometry, so it is the first failure here a user can cause by dragging a window.

### `resize` reallocates only when the pixel size actually changed

`Editor.onDisplayChanged` posts the current size with a freshly read scale unconditionally, and `Pending` is last-write-wins rather than change-detecting. Without a guard, a redundant post throws away the phosphor and churns 33 MB. This is a cost decision rather than a correctness one and the plan does not claim otherwise, but a drag delivers a size on nearly every tick and a three-second drag would otherwise allocate and release several hundred texture pairs.

### `probe` does not allocate a pair, and its docstring stops overclaiming

The `buildWindows` precedent does not transfer. Window buffers have a size the seam publishes (`iface.max_window_samples`), so `probe` allocates the real thing; a texture has no such number, and a nominal 64x64 would be `probe` paraphrasing `init`, which its own docstring is careful to say it does not do.

The thing worth catching is caught without allocating anything: `newRenderPipelineStateWithDescriptor:` validates a pipeline's colour-attachment pixel format, and `probe` calls `buildPipelines`. Once the decay and trace pipelines carry `MTLPixelFormatRGBA16Float`, `zig build smoke-gpu`, the one required CI job that runs Metal, exercises that constant on every push.

What this costs is a sentence: `probe`'s opening claim to be "everything `init` does except attach a surface" stops being true and has to name the geometry as well as the surface.

## Changes

### `shaders/scope.metal`

The header currently says two passes in one render pass and that phase 3 replaces the bodies rather than the structure. The structure is now two render passes and three draws, and this is that phase; rewrite it.

| Site               | Change                                                                                                                                                                                                                                                                                                                                                                                                                      |
|--------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `AccumUniforms`    | New struct, `float decay; float gain;`, carrying the same "nothing links the two declarations" comment `TraceUniforms` carries. Scalars only, for the same alignment reason                                                                                                                                                                                                                                                 |
| `clear_fragment`   | Deleted. Its pass becomes the resolve, which is what #38 kept it for                                                                                                                                                                                                                                                                                                                                                        |
| `decay_fragment`   | New. `texture2d<float, access::read> source [[texture(0)]]`, returns `source.read(uint2(in.position.xy)) * uniforms.decay`. Three notes beside it: `access::read` is mandatory for `read()` and is not the default; `[[position]]` is window space with half-integer pixel centres, so truncation is the pixel index; and **no Y flip**, matching `trace_vertex`'s existing note, because both surfaces are top-left origin |
| `resolve_fragment` | New. Reads the accumulation the same way and returns `float4(float3(0.02, 0.02, 0.03) + energy.rgb * uniforms.gain, 1.0)`. It inherits the background literal `clear_fragment` owned, which is what keeps the screenshot crop working. No `saturate()`: the `BGRA8Unorm` target clamps on write, and adding one would imply a tonemap where there is none                                                                   |
| `trace_fragment`   | Unchanged. #60 owns the palette, and keeping the flat green is what lets #38's `green > 64` isolation keep working                                                                                                                                                                                                                                                                                                          |

### `src/gpu/iface.zig`

- `Error` gains `TextureAllocationFailed`, documented against `BufferAllocationFailed` as above.
- `Outcome` gains `.no_accumulation`, documented as the one skip that is about this plugin's own resources rather than about the machine being busy.
- **The comptime signature wall is untouched.** `resize` is still `fn (*Renderer, Size, f64) void` and `frame` is still `fn (*Renderer) Outcome`. Worth saying out loud in review, because "did the seam change" is the first question this file invites. It changes only if the leak measurement below forces a `liveAccumulationTextures` operation.
- The file header's "there is no texture creation here, because nothing calls it yet" stays true and stays valuable: the textures live entirely below the seam, and nothing above it names one.

### `src/gpu/metal/renderer.zig`

New constants in the `mtl` block, which already carries the warning that it has nothing to check itself against. All seven were read out of the SDK headers rather than recalled, on `primitive_type_line_strip`'s precedent.

| Constant                      | Value | Metal name                    | Why it needs a note                                                                                                                                                                                                                                                                                                                     |
|-------------------------------|-------|-------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `pixel_format_rgba16_float`   | 115   | `MTLPixelFormatRGBA16Float`   | Sits below `pixel_format_bgra8_unorm`, whose comment already predicts #60's sRGB move                                                                                                                                                                                                                                                   |
| `load_action_dont_care`       | 0     | `MTLLoadActionDontCare`       | A full-screen triangle covers every pixel of both attachments, so a load or a clear would be overdrawn                                                                                                                                                                                                                                  |
| `texture_usage_shader_read`   | 0x1   | `MTLTextureUsageShaderRead`   |                                                                                                                                                                                                                                                                                                                                         |
| `texture_usage_render_target` | 0x4   | `MTLTextureUsageRenderTarget` | **The descriptor's default usage is `ShaderRead` alone.** Without this, `renderCommandEncoderWithDescriptor:` returns nil and every frame is `.no_encoder`: a permanently black editor                                                                                                                                                  |
| `storage_mode_private`        | 2     | `MTLStorageModePrivate`       | A different enum from `resource_storage_mode_shared` above it, which is `MTLResourceOptions` with the mode packed into bits 4 and up. Both are 0 for shared, and that coincidence is what makes them confusable. `Memoryless` is the trap worth naming: its contents do not survive a render pass, which is the negation of persistence |
| `blend_factor_one`            | 1     | `MTLBlendFactorOne`           |                                                                                                                                                                                                                                                                                                                                         |
| `blend_operation_add`         | 0     | `MTLBlendOperationAdd`        |                                                                                                                                                                                                                                                                                                                                         |

| Site                                                  | Change                                                                                                                                                                                                                                                                                                                                                                                                                                      |
|-------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Pixels`                                              | New `struct { width: u32, height: u32 }`. Backend-local: `iface.Size` is logical points at every call site above, and reusing it here would make "size" mean two things                                                                                                                                                                                                                                                                     |
| `backingPixels`                                       | New. `fn (iface.Size, f64) Pixels`, `@intFromFloat(@round(...))`, so there is exactly one rounding rule                                                                                                                                                                                                                                                                                                                                     |
| `drawableSize`                                        | Becomes `fn (Pixels) CGSize`. The layer now gets an exact integer size                                                                                                                                                                                                                                                                                                                                                                      |
| `applyLayerGeometry`                                  | New. Owns the `CATransaction` and its `defer commit`, so the transaction is provably closed before `resize` allocates anything. A `defer` runs at function exit, so appending allocation to `resize`'s body would otherwise hold a CoreAnimation transaction open across a 33 MB allocation on a non-main thread                                                                                                                            |
| `accumulation_pixel_format` / `drawable_pixel_format` | New named aliases used by the descriptor, the layer and the pass table, so the three cannot drift and no test is needed to prove they agree                                                                                                                                                                                                                                                                                                 |
| `cleared`                                             | New `ClearColor` of all zeros: the accumulation's zero-energy state, distinct from `background`                                                                                                                                                                                                                                                                                                                                             |
| `background`                                          | **Deleted.** Nothing clears with it any more and `resolve_fragment` owns the literal, which retires the hand-kept duplication its own comment apologises for and answers #60's "The background, possibly" bullet early                                                                                                                                                                                                                      |
| `decay_per_frame`, `resolve_gain`                     | New. `0.90`, and `1.0 - decay_per_frame` derived from it                                                                                                                                                                                                                                                                                                                                                                                    |
| `AccumUniforms`                                       | New `extern struct { decay: f32 = decay_per_frame, gain: f32 = resolve_gain }`, on `TraceUniforms`' shape and with its layout test                                                                                                                                                                                                                                                                                                          |
| `accumulation_texture_index`, `accum_uniform_index`   | New, both 0, in the block with `window_buffer_index`, with a sentence saying fragment textures, fragment buffers and vertex buffers are three separate index spaces so index 0 here collides with nothing                                                                                                                                                                                                                                   |
| `Functions` → `Pass`                                  | Gains `pixel_format: u64` and `blending: enum { off, additive } = .off`. The format joins the function names because it is a third coupling with no compiler behind it                                                                                                                                                                                                                                                                      |
| `passes`                                              | `decay_pass`, `trace_pass` (additive, accumulation format), `resolve_pass` (drawable format). Walked by the existing shader-source test, so the two new functions are covered by being added here                                                                                                                                                                                                                                           |
| `buildPipeline`                                       | Takes the format from `pass` rather than hardcoding `BGRA8Unorm`, and sets the blend properties when `pass.blending == .additive`. **This is the change without which nothing works**: a pipeline whose colour-attachment format disagrees with the attachment bound at encode time is a draw-time validation failure. Replace the "No blending on any pass" comment; its prediction came true, and recording outcomes is this file's habit |
| `Pipelines`                                           | `{ decay, trace, resolve }`, three chained `errdefer`s, released in reverse                                                                                                                                                                                                                                                                                                                                                                 |
| `accum`, `accum_source`                               | New fields, `?[2]objc.Object = null` and `u1 = 0`                                                                                                                                                                                                                                                                                                                                                                                           |
| `buildAccumulation`                                   | New. Both or neither, on `buildWindows`' shape, and clears them before returning                                                                                                                                                                                                                                                                                                                                                            |
| `clearAccumulation`                                   | New. One command buffer, two empty render passes, `commit` and **no wait**                                                                                                                                                                                                                                                                                                                                                                  |
| `releaseAccumulation`                                 | New. The one release site, on `releaseWindows`' precedent and for its reason                                                                                                                                                                                                                                                                                                                                                                |
| `init`                                                | `pixels` computed once and stored; `buildAccumulation` placed between `buildWindows` and `attachLayer`, so the layer stays the last acquisition and the only one needing no `errdefer`                                                                                                                                                                                                                                                      |
| `resize`                                              | Compute `pixels`, `applyLayerGeometry`, return early if the pair exists and `pixels` is unchanged, otherwise store and rebuild. Takes a throwaway `iface.Diagnostics` and discards it, with a comment saying `.no_accumulation` reaching `Editor` is the signal that survives                                                                                                                                                               |
| `frame`                                               | `self.accum orelse return .no_accumulation` **before** the semaphore wait, so a skipped frame touches neither the slot nor the staged window. Then the two passes below                                                                                                                                                                                                                                                                     |
| `deinit`                                              | Releases the pair immediately above `releaseWindows`                                                                                                                                                                                                                                                                                                                                                                                        |
| `probe`                                               | Docstring corrected; no allocation added                                                                                                                                                                                                                                                                                                                                                                                                    |

`frame`'s new body replaces the single pass with two:

1. **Pass 1**, attachment `accum[1 - accum_source]`, `DontCare` / `Store`. Bind `accum[accum_source]` as fragment texture 0 and the uniforms as fragment bytes 0. Decay pipeline, three vertices. Then the existing guarded trace block verbatim, except that its pipeline now carries additive blending. `endEncoding`.
2. **Pass 2**, attachment the drawable's texture, `DontCare` / `Store`. Bind pass 1's target as fragment texture 0 and the same uniforms. Resolve pipeline, three vertices. `endEncoding`.
3. Completion handler, `handed_off = true`, present, commit, `accum_source +%= 1`, `.presented`.

**Two encoders here, against the existing comment that argues for one, and the reason has to be written down because it reads as a regression.** A render pass has one set of attachments and these two have different ones; the accumulation must be stored before the resolve can read it as a texture. The tile-memory argument survives intact *within* pass 1, where the decay and the deposit share a target, which is why those two are one pass and not two.

A nil pass-2 encoder returns `.no_encoder` **without committing**: the `defer` hands the slot back, no completion handler was registered, and `accum_source` never advanced, so pass 1's encoded-but-unexecuted work leaves the accumulation exactly where it was.

Alpha gets one/one/add alongside RGB so the pipeline has one story; `resolve_fragment` reads `.rgb` and the accumulation's alpha carries no meaning, which is worth one sentence so #60 does not inherit a channel it has to guess about.

**Two assumptions to state rather than leave implicit.** Textures created through `newTextureWithDescriptor:` are non-heap and therefore hazard-tracked by default, which is what serializes frame N+2's write against frame N's; do not move them to an `MTLHeap`, where tracking is off. And releasing the outgoing pair in `resize` is safe because a command buffer from `-[MTLCommandQueue commandBuffer]` retains every resource it references, attachments included, until it completes, a stronger fact than `deinit`'s current "an encoder retains what it binds", because a render target is attached rather than bound.

### `src/smoke.zig`

Two additions to `oneCycle`, both small and both aimed at this issue's resize half.

- Resize **back down** after the existing growth to 1280x720, to `gui.min_size`. A shrink is where a stale larger texture is most likely to survive unnoticed.
- Resize to a wrapped-negative height, `set_size(p, 1280, 4294967295)`, which routes through `Editor.setSize` → `clampSize` → `clampAxis` and the mailbox on exactly the path REAPER's own value takes. **Today that path is exercised only by a human dragging a window**; this makes it 400 automated exercises under `leaks`, and it is what would catch a texture dimension derived from something other than the clamped size.

## Tests

| File                         | Test                                                                                                                                                                                                                                                                                                                                                                          |
|------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `src/gpu/metal/renderer.zig` | *(existing)* `"the embedded shader defines the functions every pipeline asks for"` now covers `decay_fragment` and `resolve_fragment` by their being added to `passes`. That it needs no edit is the payoff of #38 having written it as a walk                                                                                                                                |
| `src/gpu/metal/renderer.zig` | `"the shader reads the accumulation at the texture index the encoder binds it to"`: greps `texture(0)`, exactly parallel to the existing `buffer({d})` test and against the same coupling with no compiler behind it                                                                                                                                                          |
| `src/gpu/metal/renderer.zig` | `"the accumulation's uniforms are laid out the way the shader reads them"`: `@sizeOf` 8, `@alignOf` 4, offsets 0 and 4, mirroring the `TraceUniforms` test                                                                                                                                                                                                                    |
| `src/gpu/metal/renderer.zig` | `"a frame both dims what is there and shows what is left"`: `0 < decay_per_frame < 1` and `resolve_gain == 1 - decay_per_frame`. This is what makes a planted decay of `1.0` or `0.0` fail `zig build test` rather than needing an eye                                                                                                                                        |
| `src/gpu/metal/renderer.zig` | `"the drawable and the accumulation are sized from one expression"`: replaces `"the drawable is sized in backing pixels and the layer in points"`. Adds the fractional-scale case (1.5) and asserts `drawableSize(backingPixels(s, k))` is the `CGSize` the layer is given, which is the property that keeps `read()` in bounds                                               |
| `src/gpu/metal/renderer.zig` | `"the smallest editor the seam permits still asks for at least one pixel"`: `backingPixels({480, 270}, 1.0/256.0)` has both axes ≥ 1. Metal rejects a zero-dimension texture, and this is the arithmetic that says it cannot happen. Literals with a comment naming `gui.min_size` and `Pending`'s smallest encodable scale, since the backend must not import the clap layer |
| `src/gpu/iface.zig`          | *(existing)* `"only a presented frame counts as having drawn"` lists the skips **by hand** and must gain `.no_accumulation`. The walking test beside it will not catch the omission                                                                                                                                                                                           |

Deliberately not written, on #38's precedent: anything asserting that a pass's pixel format is what the constant says, because two named aliases used at every site leave nothing to drift; a `Pixels` equality test, because `std.meta.eql` on two `u32`s is not a claim; and anything reachable only by constructing a `Renderer`, because `zig build test` acquires no GPU (ADR 0009) and this issue does not change that.

## Documentation

- **ADR 0013**, following its own `## Amended by issue #38` precedent: `## Amended by issue #55`. That amendment set the rule that a Metal resource which is not a buffer must be checked against `leaks` with a planted leak; this is its third application and its third answer. Record which arm it landed in, the RSS figures, and whether `PLUGIN_OWNED` needed changing.
- **AGENTS.md**: the texture leak-visibility result beside the `MTLBuffer` bullet; a memory-footprint bullet (33 MB per open editor at the default geometry, 4 GiB for the pair at `gui.max_size` on a 2x display, and that `hide` does not free it); a bullet on the two surfaces having to be the same size and `backingPixels` being where that is decided; an amendment to the `RGB(5, 5, 8)` bullet saying the screenshot crop survives and the per-column peak measurement does not; and the "two passes in one render pass" line in the overview.
- **README** status paragraph and **CHANGELOG** `Added`.
- The **build plan**: mark phase 3 steps 2 and 8 done, and move this issue's row in the phase 3 table from `In progress` to `Done`. The table itself, and the parallelism section beside it, landed separately, because the resource contention they describe is not a phase 3 fact and outlives this issue.

No new ADR. ADR 0007 already settles the structure and ADR 0005 already settles where it lives.

## Verification

```bash
zig fmt --check build.zig src/
zig build test
zig build
zig build validate-shaders          # xcrun --kill-cache if the toolchain reports missing
zig build smoke-gpu
zig build smoke-appkit
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert zig-out/bin/fosforo-smoke appkit 20
/usr/bin/time -l zig-out/bin/fosforo-smoke appkit 40
/usr/bin/time -l zig-out/bin/fosforo-smoke appkit 400
zig build smoke-leaks
```

Then every line again under `--release=fast`, which matters more here than it has anywhere before. `platform.assertNotMainThread` is `std.debug.assert` and compiles out; it guards `resize`, which this issue turns from two message sends into the function that allocates and releases tens of megabytes. In Debug a `resize` reached from the main thread aborts; in ReleaseFast it silently reallocates underneath a frame the render thread is inside. And the Audio Unit is built ReleaseFast, so Logic is the only host in which the shipping texture path runs at all.

Three notes on the instruments:

- **`MTL_DEBUG_LAYER` is new to this repository**, and this change is the first that earns it: it names attachment format mismatches, missing `RenderTarget` usage and unbound fragment textures on stderr, where the same failures otherwise surface as a nil encoder. Run it by hand; do not wire it into CI in this issue, because ADR 0013 already carries one check that can go red for reasons unrelated to the code.
- **RSS is a far sharper leak detector here than it was for buffers**, and the slope rather than the peak is the instrument. Measure *without* `leaks`, since `MallocStackLogging=1` inflates it. A per-cycle texture leak at 400 cycles is 13 to 23 GB, so plant leaks at 40 cycles or the machine swaps instead of reporting a number.
- **`zig build smoke-leaks` is local-only.** CI's `smoke` job runs `smoke-gpu` (required) and `smoke-appkit` (`continue-on-error`); nothing in CI runs `leaks` or measures RSS. [#63](https://github.com/cboone/fosforo/issues/63) proposes changing that and carries the measurements below.

### The baseline these are measured against

Taken on this machine against `612f405`, before any of this lands, so the numbers below are a starting line rather than a prediction. **Two of them correct assumptions this plan made before they were measured.**

| Check                               | Figure                                                          |
|-------------------------------------|-----------------------------------------------------------------|
| `zig build smoke-leaks`, 400 cycles | 51.8 s, reporting 288 leaks / 18,816 bytes, none this project's |
| The same at 20 and 60 cycles        | 212 leaks / 14,640 bytes, identical at both                     |
| Peak RSS, 40 cycles, plain          | 40.8 MB                                                         |
| Peak RSS, 200 cycles, plain         | 53.5 MB and 55.0 MB across two runs                             |
| Peak RSS, 400 cycles, plain         | 68.6 MB                                                         |

**Peak RSS is not flat across cycle counts**, which an earlier draft of this plan assumed it was. Unmodified code rises about 28 MB between 40 and 400 cycles and varies 1.5 MB run to run at a fixed count, so the slope has a non-zero baseline of roughly 0.077 MB per cycle and a texture leak has to be read against that rather than against zero. It is still an enormous signal: a leaked pair is 33 to 59 MB per cycle, some 400 times the baseline slope.

**The 400-cycle leak figure reproduces the 288 / 18,816 already on record**, so that instrument is stable across machines. The 47.7 MB RSS figure on record does not reproduce as cleanly; 200 cycles measures 53.5 to 55.0 MB here, which is machine and OS state rather than a regression. Predicted peak after this change is therefore **baseline plus roughly one editor's worth**, about 100 to 130 MB at 400 cycles, since editors are sequential rather than concurrent and the mid-cycle resize takes the pair to 59 MB.

### Planted defects

| Plant                                               | Expected                                                                                                                                                                                                                                                                                                                                                                                                         |
|-----------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Drop a release in `releaseAccumulation`             | **Unknown, and measuring it is the point.** Arm A, `leaks` sees it: a driver-private class name (`AGXG17XFamilyTexture` or similar, never `MTLTexture`), and `PLUGIN_OWNED` already carries `AGX`, `IOGPU`, `IOSurface` and `_?MTL`. Arm B, it is blind: the `MTLBuffer` case again, and ADR 0013's rule fires: add `live_textures`. **Do not predict which.** A pipeline state was visible and a buffer was not |
| `resize` allocates without releasing                | 800 live textures after 400 cycles. **A hazard `live_windows` never had**, because window buffers are allocated once and never reallocated, so a texture counter must be decremented on the resize path too                                                                                                                                                                                                      |
| `decay_per_frame = 1.0` or `0.0`                    | Fails `zig build test` on the range assertion. Plant both anyway and look, since 1.0 is the control that proves an eye can see persistence at all before an eye is trusted on the harder direction                                                                                                                                                                                                               |
| Drop the `accum_source` swap                        | The decay reads a texture nothing updates, which is observationally **identical to a decay of 0.0**. Record that as the limit: the swap and the factor are two mechanisms with one symptom, and the way to tell them apart is to plant each and read the diff                                                                                                                                                    |
| Advance `accum_source` at the top of `frame`        | The decay reads the texture it is about to write. Visible strobing under any skipped frame, which is rare here                                                                                                                                                                                                                                                                                                   |
| Skip the clear in `buildAccumulation`               | Most likely a permanently white or black editor from a NaN. **If it looks fine, that is a fact about this driver's zero fill and not a licence to remove the clear**. Record it as such                                                                                                                                                                                                                          |
| Clear the accumulation to `background`              | The washout: a re-added floor reaches ten times the background, a bright grey field. Caught by the pixel sample at `(W/2, H/4)`, which must read exactly `RGB(5, 5, 8)`, the same signature the screenshot crop depends on                                                                                                                                                                                       |
| Drop `texture_usage_render_target`                  | `smoke: appkit FAILED: NoFramePresented`, because every frame is `.no_encoder`. **Keep this row**: it is the positive control proving `smoke-appkit` reaches the new code at all                                                                                                                                                                                                                                 |
| Give `resolve_pass` the accumulation's pixel format | Refused at draw time. Named under `MTL_DEBUG_LAYER`, garbled or black without it. This is the plant that justifies the debug-layer run                                                                                                                                                                                                                                                                           |
| Make `resize` not rebuild the pair                  | The resolve reads out of bounds when the editor grows. Confirms the sizing hazard is real rather than hypothetical                                                                                                                                                                                                                                                                                               |
| Leave the trace pass writing to the drawable        | Exactly #38's picture, with the textures allocated, cleared, decayed, resolved and never seen. The "this whole change did nothing" plant, and the one most available to a reviewer once the resolve is described as trivial. Nothing automated catches it                                                                                                                                                        |
| Release the textures after the layer in `deinit`    | **Passes**, and predict it. ADR 0013 already records that reversing `Editor.destroy` passes and leaks nothing; a texture holds no reference to the layer. The order stays as defensive convention and the ADR's sentence about it covers a second case now                                                                                                                                                       |
| Add `waitUntilCompleted` to `frame`                 | `smoke-appkit` **passes**, slower. In a host under GPU load, closing the editor hangs the main thread in `Gate.close`. Nothing automated catches it; the review item is "no new wait in `frame` or `resize`"                                                                                                                                                                                                     |

### Telling persistence from its absence

The central problem of this issue: a static trace against steady material looks much the same either way, and with the resolve gain it looks *identical*. Every check therefore turns on a transient.

- **The stop transient, primary.** #38 already recorded the no-persistence answer for this exact gesture: with a sine playing, stopping the transport returns the trace to flat within about 20 ms plus a refresh period. With persistence the sine **fades** while a flat line appears on top of it. Snap versus fade is not a judgement call. Toggle six times. Predict the shape so nobody reports it as a defect: to 5% takes about 28 frames, roughly 237 ms at 120 Hz and 474 ms at 60.
- **The detuned standstill ribbon, the measurement.** #38 established that a sine at exactly the refresh rate stands still and that detuning by 1 Hz crawls, with the harmonic as the control that made it conclusive. Persistence turns the crawl into a **ribbon**, because the trace sweeps `δ · tau` cycles of phase during the persistence time. At δ = 0 the picture is #38's exactly, which is the perfect control. Sweep δ = 1, 2, 5, 10, 30 Hz and find where the ribbon closes into a solid band: **that δ gives tau ≈ 1/δ**. Without persistence every δ gives a single curve. Pin the display to 60 Hz first, since the factor is provisionally per-frame.
- **The impulse, the cleanest demonstration.** `scripts/make-test-tones` has no impulse or gated burst; add two, using its existing `render`/`verify` machinery. A **1 ms** burst at 0.8 repeated at 2 Hz (not a single sample, since 1 ms at 48 kHz is 48 samples and about 96 backing pixels), and a 100 Hz sine gated on for 100 ms every second. Without persistence a click is a stroboscopic blink; with it, each click leaves a fading afterimage and **the number visible at once is a direct readout of tau in half-seconds**.
- **Bypass, a behaviour to predict and record.** #38 recorded that REAPER freezes the picture on bypass, stops calling `process`, and keeps `windowsUploaded` climbing because the same window is re-read. Under persistence that means the same trace is deposited every frame, so the picture should **brighten toward steady state rather than fade**. If it fades, something is not depositing every frame and that is a finding.

Not valid: "it looks glowier", "it looks like a scope now". A saturating additive deposit thickens a static trace with no persistence at all.

### In a host

**Provenance first, and it is not a formality.** Run `zig build install-plugins`, read **both** hash pairs it prints, and confirm both match before believing anything below. Check the component's modification date as well as its hash: a component from a fortnight ago beside a CLAP from a minute ago is the #43 trap and it has voided a run before. The installed CLAP will be Debug, which is what the render meter needs, and the installed component ReleaseFast, which is what Logic needs.

REAPER, launched from a terminal:

1. The meter reads `rendering at 119.5–120.0 Hz, 960x540 at 2.00x, 960 sample window, N uploaded, 0 torn`. A rate at a clean fraction of the refresh rate means a new early return is firing.
1. Silence, **by pixel sample rather than by eye**. `screencapture -o -x -t png -W`; sample `(W/2, H/2)` for the trace colour and `(W/2, H/4)` for exactly `RGB(5, 5, 8)`. The first catches a resolve reading a texture nothing writes, the second catches a clear to the background. `-t png` forces lossless: #38 paid for that, when a HEIC capture named `.png` smeared a one-pixel trace into 256 green levels.
1. Watch the trace **fade in** over about a quarter of a second when the editor opens, which is the accumulation reaching steady state and is expected.
1. The stop transient, the ribbon sweep, and the click file, per above.
1. Resize during playback: drag wider and taller with the meter's size following and the rate holding; drag the bottom edge past the top and confirm `480x270` in the meter with the loop still running; drag to fill the display and confirm no stall; drag between a 2x and a 1x display if two are available and confirm the scale field changes and the picture stays sharp. **The trail disappearing during a drag is correct** and must be predicted, because a rebuilt texture is a cleared one and REAPER posts a size on most frames of a drag. The failure to watch for is the opposite: a picture that stretches and blurs and **snaps sharp when the drag ends**, which is a resolve sampling a texture that was never rebuilt.
1. Bypass, deactivate/reactivate with the editor open, and a sample-rate change (882 samples at 44.1 k, 1920 at 96 k).
1. **The #38 geometry regression, measured at the standstill**, which is the one condition where the tables are directly comparable: peak rows 54/1026 at 1.000, 29/1050 at 1.050, and 10/1069 identically at 1.089 and 2.000, the peak ceasing to climb. The standstill is also the one condition where `measure-trace`'s two-shade premise still holds, so it is the only place the tool runs unmodified. Setting `decay_per_frame` to 0.0 reproduces #38's picture exactly and is the other way to re-run any of it, and the way to run `measure-trace` against anything that is not a standstill until [#64](https://github.com/cboone/fosforo/issues/64) lands.
1. `pan-hard-right` still draws flat. Cheap, and it is what keeps someone from filing a bug against a working plugin.
1. Four instances with editors open: each draws its own signal, RSS is about baseline plus 4 × 33 MB, no dropouts.
1. Open and close ten FX windows and confirm RSS does **not** return. See below.

Logic, where the editor is destroyed rather than hidden and the build is ReleaseFast:

1. Provenance, including the component's mtime.
1. Pixel-sample to confirm a render at all, since Logic has no readable diagnostics under any build mode.
1. **Twenty open/close cycles of the plugin window on a playing track.** Each is a full `destroy`/`create`/`set_parent` on a still-activated instance, so each allocates and releases a pair. Every reopen must come back live rather than flat, and memory must return to level, watching `AUHostingServiceXPC`, not Logic, since AUv2 is hosted out of process and a crash there presents as a blank window rather than as Logic dying.
1. The stop transient by eye, resize during playback, and two instances.

### What was run, and by whom

Everything above the line is repeatable by anyone; everything below it was confirmed by the author against hash-verified installs, `865a5e22fbbd` for the CLAP and `c89414585da9` for the component.

| Check                                                         | Result                                                                               |
|---------------------------------------------------------------|--------------------------------------------------------------------------------------|
| `zig fmt --check`, `zig build test`                           | Clean, 160 tests                                                                     |
| `zig build`, `validate-shaders`                               | Clean                                                                                |
| `smoke-gpu`, `smoke-appkit`                                   | Clean                                                                                |
| `smoke-appkit` under `MTL_DEBUG_LAYER=1`                      | Clean, and it caught two defects nothing else did                                    |
| Peak RSS, 40 / 200 / 400 cycles                               | 44.1 / 55.3 / 62.9 MB, against 40.8 / 53.5 / 68.6 before. The textures are not in it |
| `zig build smoke-leaks`                                       | Clean at 400 cycles, 288 leaks / 18,816 bytes, none this project's                   |
| The texture-leak plant                                        | **Arm B, and worse**: invisible to `leaks` *and* to RSS                              |
| All of the above under `--release=fast`                       | Clean                                                                                |
| `clap-validator`                                              | 21 passed, 0 failed                                                                  |
| `shfmt`, `shellcheck`, `markdownlint-cli2`, `typos`           | Clean                                                                                |
| REAPER: meter, brightness, stop transient, click, resize      | Passed                                                                               |
| REAPER: geometry regression at four levels                    | Passed, every peak row identical to #38                                              |
| REAPER: channel trap, bypass, multi-instance                  | Passed                                                                               |
| Logic: render, twenty open/close cycles, transient, instances | Passed                                                                               |
| Logic: window resizing                                        | **Refused by the host**, [#65](https://github.com/cboone/fosforo/issues/65)          |

Four host results are worth more than a row each.

**The gain error was found by eye in under a minute, and by nothing else at all.** A 100 Hz sine rendered as a black display while 160 unit tests, both smoke halves, `smoke-leaks`, `clap-validator` and the Metal validation layer all passed. Measured off the capture: peak green 53 against 255, background exactly `RGB(5, 5, 8)` across 95.7% of the drawable, 45 distinct green levels above it. Every part of the picture was correct except that none of it was bright enough to see. That is the argument for this project's rule that an issue is not finished until it has been in a host, made against a real defect rather than in the abstract.

**The geometry is unmoved**, which was the real risk in `backingPixels`. Peak rows 54, 29, 10 and 10 at samples 1.000, 1.050, 1.089 and 2.000, identical to #38's, with the last two on the rail and the plateau widening from 262 columns to all 1920. All three of #38's recorded claims reproduce: 43 px below the rail at 1.000, 19 at 1.050, and the same row for everything from 1.089 up.

**One number improved and should not be trusted.** #38 measured `level-1.089` lighting 1914 of 1920 columns; every level now lights all 1920. Persistence masks a single frame's coverage rather than provably fixing it, and a screenshot of an accumulated picture cannot tell those apart. Recorded on [#57](https://github.com/cboone/fosforo/issues/57) as unmeasured rather than passing.

**The frame-rate dependence is visible without instrumentation.** Pinning the display to 60 Hz doubles the fade length of a `click-2hz` click. That is [#56](https://github.com/cboone/fosforo/issues/56)'s whole subject, demonstrated in a minute, and it now carries an acceptance criterion with a measured failing baseline.

### What this does not close

- **Nothing here measures a pixel automatically.** The drawable is `framebufferOnly` and ADR 0013 refuses a harness-only readable path; [#51](https://github.com/cboone/fosforo/issues/51) is where that changes. Every claim about the picture in this plan is author-run.
- **`measure-trace` exists but is in no repository**, which is worse than it not existing, because #60 describes it as though it were committed here. It is at `~/Music/fosforo-test-tones/measure-trace`, beside the WAVs `scripts/make-test-tones` renders, and `git log --all -S measure-trace` is empty in both this repository and `audio-tools`. [#64](https://github.com/cboone/fosforo/issues/64) tracks committing it. Three of its properties decide what survives this change:
  - **The crop survives.** `find_drawable` requires exactly `RGB(5, 5, 8)` with the blue channel leading red and green by 2 to 4, and `resolve_fragment` still emits that where no energy has landed. That is the single strongest reason not to touch the background in this step.
  - **The `green > 64` isolation survives, but the per-column peak-row measurement does not**, because persistence means the topmost lit pixel in a column is a previous frame's sample rather than this one's.
  - **The lossless guard breaks, and it breaks by accusing the author.** `measure-trace` refuses any capture holding more than 32 distinct green levels, on the stated premise that "a lossless capture has 2", and tells the operator to recapture. A decaying trail occupies many levels by construction, so a perfectly good PNG is refused and only `--allow-lossy` gets through, which then names the wrong thing. The exception is the standstill, where the trace lands on identical pixels every frame and the drawable really does hold two shades again, so the one measurement this plan asks `measure-trace` for still works. Everything else needs [#64](https://github.com/cboone/fosforo/issues/64) first.
- **One frame of resolve lag would be invisible.** If the resolve read the stale half of the ping-pong, the drawable would show the accumulation as of one frame ago. No instrument here can see it.

## What landed differently

Seven corrections, and the first four are the same discovery arriving in stages.

**`leaks` cannot see a leaked accumulation texture.** Measured, as the issue required: dropping one release and running 20 cycles reports 283 leaks for 18,560 bytes against a clean 288 for 18,816, none of the 250 classes a texture under any name, while the leak runs at roughly 46 MB per cycle. Arm B, as for `MTLBuffer`.

**Neither can peak RSS, and this plan asserted the opposite.** It said RSS was "a far sharper leak detector here than it was for buffers", on the strength of a leaked `MTLBuffer` moving it from 47.7 MB to 57.7 MB. A leaked texture does not move it at all: 44.3 MB against 44.1 MB clean at 40 cycles while leaking nearly two gigabytes. Shared storage is in the process's resident set and `MTLStorageModePrivate` is not. **`liveAccumulationTextures` is therefore not the better of two instruments, it is the only one**, which is a stronger position than the window buffers are in.

**The counter is consequently mandatory rather than conditional**, and the commit that adds it is no longer marked as such.

**The seam changed, which this plan said it would not.** `liveAccumulationTextures` is an eighth operation in the comptime wall. The prose count in `iface.zig` that has to be kept beside it by hand was updated with it.

**Two planted defects are caught by nothing this project runs.** The plan listed a missing `MTLTextureUsageRenderTarget` and a resolve pipeline compiled against the wrong format as positive controls that would fail `smoke-appkit` with `NoFramePresented`. Both pass. Metal validates neither without the layer enabled, so both are undefined behaviour that happens to present a frame while the picture is wrong. `MTL_DEBUG_LAYER=1` names both exactly, `RenderPass Descriptor Validation` for the first and `Set Render Pipeline State Validation` for the second. That is the argument for the debug-layer run made against real defects, and it is worth handing to [#63](https://github.com/cboone/fosforo/issues/63).

**`backingPixels` saturates and floors rather than using `@intFromFloat(@round(...))`.** `@intFromFloat` is illegal behaviour out of range, and `gui.windowSamples` already established `std.math.lossyCast` as this project's idiom at a boundary it does not own. The floor at one pixel per axis is because Metal rejects a zero-dimension texture.

**The memory prediction was wrong in the same direction as the RSS finding.** This plan predicted peak RSS moving to 100 to 130 MB. Measured after the change it is 44.1 MB at 40 cycles, 55.3 at 200 and 62.9 at 400, against a pre-change 40.8, 53.5 and 68.6. The textures are simply not in that number. The 33 MB per open editor is real and is still worth stating; what is not true is that anything here can observe it.

The consequence for the host procedure is that **step 10, opening and closing ten FX windows to confirm RSS does not return, cannot work.** `hide` keeping the renderer alive is still a real cost and is still worth [filing](https://github.com/cboone/fosforo/issues/22), but no instrument available in a host can measure it, and `liveAccumulationTextures` is reachable only from the smoke harness.

## Out of scope

Recorded so they read as deliberate omissions rather than oversights.

- **Decay in real elapsed time**, [#56](https://github.com/cboone/fosforo/issues/56), including which clock measures it. The constant here is provisional and says so at the source.
- **The beam as oriented quads** ([#57](https://github.com/cboone/fosforo/issues/57)), **velocity weighting** ([#58](https://github.com/cboone/fosforo/issues/58)), **bandlimited reconstruction** ([#59](https://github.com/cboone/fosforo/issues/59)), **the tonemap, palette and sRGB drawable** ([#60](https://github.com/cboone/fosforo/issues/60)), **shader hot-reload** ([#61](https://github.com/cboone/fosforo/issues/61)) and **min/max decimation** ([#62](https://github.com/cboone/fosforo/issues/62)). The trace keeps its flat green literal and the resolve keeps its trivial gain precisely so #60 replaces a body rather than re-adding a pass.
- **The offscreen measurement harness**, [#51](https://github.com/cboone/fosforo/issues/51). Building it here would roughly double the change, and #56, #58 and #60 all want it more than this step does.
- **Releasing the accumulation on `hide`.** `Editor.setHidden` stops the display link and deliberately keeps the renderer, which was free when an editor held about 96 KiB of buffers and is 33 MB now. In REAPER, closing an FX window is `hide`, so a session with twenty instances whose editors have each been opened once holds **660 MB of accumulation textures with every render loop stopped**. That is `hide`'s existing semantics becoming expensive rather than a defect introduced here. File it; measure it in step 10 above; do not fix it here.
- **`gui.max_size`.** 8192x8192 points at a backing scale of 2 is a 4 GiB pair, and the bound was justified by Metal's texture dimension limit at a time when no texture of this project's own existed. File it with the number; the allocation-failure path above keeps it from being a crash.
- **Wiring `MTL_DEBUG_LAYER` into CI.** Run it by hand here and file a follow-up if it earns a step.
- **Getting `smoke-leaks` and a peak-RSS slope check into CI**, [#63](https://github.com/cboone/fosforo/issues/63). Filed rather than done here because it is a decision about what may block a merge, and because the measurements above are the evidence it needs rather than a side effect of this change. Its short answer: yes, `smoke-leaks` should run, under `continue-on-error` on ADR 0013's precedent, and the RSS slope beside it is the stronger of the two instruments because `leaks` is blind to exactly the resources this project holds most of.
- **Committing `measure-trace` and fixing its lossless guard**, [#64](https://github.com/cboone/fosforo/issues/64), which **follows this issue rather than preceding it**. The guard's acceptance test is a capture of a trace that actually fades, and that does not exist until this has landed. Nothing here needs the fix: the host procedure above reaches for `measure-trace` only at the standstill, where the drawable really does hold two green shades and the guard's premise still holds.
- **NaN in the sample path.** #38 recorded that nothing rejects a non-finite sample and deferred the fix to phase 3's fast-math policy. A NaN now persists in the accumulation instead of lasting one frame, which makes it worse rather than different, worth naming, but the fix is still a finite check in `Renderer.upload` and still belongs with the fast-math decision rather than here.

## Risks to watch at the keyboard

- **`usage` and `storageMode` must both be set explicitly.** The descriptor's default usage is `ShaderRead` alone, and the symptom of omitting `RenderTarget` is a nil encoder that reads as `NoFramePresented` rather than as anything about textures.
- **`Memoryless` will be suggested and is exactly wrong.** Its contents do not survive the render pass.
- **Two attachment formats now**, so a pipeline built against the wrong one fails at draw time, which `probe` never reaches.
- **`max_frames_in_flight` is 3 and the ping-pong is 2 deep**, so the accumulation passes cannot overlap on the GPU and `.no_frame_slot` becomes a live outcome rather than a theoretical one. `iface.zig` predicted exactly this at the constant. More textures would not help: each frame's output genuinely depends on the previous frame's.
- **No new unbounded wait in `frame` or `resize`.** `Editor.tick` holds the gate across its whole body, so anything unbounded becomes a wait the host's main thread takes in `Gate.close`. A `waitUntilCompleted` "to make the ping-pong safe" is the tempting fix and the harness cannot catch it.
- **Do not reallocate when the pixel size is unchanged**, or `onDisplayChanged` throws the phosphor away for nothing.
- **`live_textures`, if it turns out to be needed, must be decremented on the resize path**, which `live_windows` never was.
- **The trace fades in when an editor opens.** Expected, and it will read as a bug on first sight.
- **ProMotion drift is #56's subject, not a defect to chase.** Pin the display while judging the look.
- The `msgSend` coercions most likely to need a line's adjustment: the four-argument `texture2DDescriptorWithPixelFormat:width:height:mipmapped:` with its `BOOL`, and unwrapping `?[2]objc.Object` in `deinit` and `resize`.

## Commits

1. `docs: plan the persistent accumulation texture (#55)`
1. `feat: size the drawable in whole backing pixels and keep them (#55)`
1. `feat: allocate a cleared ping-pong accumulation pair (#55)`
1. `feat: deposit the trace into the accumulation and resolve it to the drawable (#55)`
1. `test: exercise a shrink and a wrapped height in the smoke cycle (#55)`
1. `test: count the accumulation textures the backend holds (#55)`, **conditional**, only if the planted leak shows `leaks` cannot see a texture
1. `docs: record what leaks can see of a texture (#55)`

Commits 2, 3 and 4 each compile and pass `zig build test` on their own, and each is reviewable in isolation: 2 is arithmetic, 3 is resource lifetime, 4 is the picture.
