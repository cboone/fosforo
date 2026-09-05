# Check a hot-reloaded shader's binding indices against the Zig constants

Issue: [#77](https://github.com/cboone/fosforo/issues/77). Type: `test:`. Step "none" on the [Phase 3 milestone](https://github.com/cboone/fosforo/milestone/3), split out of [#61](https://github.com/cboone/fosforo/issues/61), which left it open deliberately.

## Context

[#61](https://github.com/cboone/fosforo/issues/61) made a debug build compile `shaders/scope.metal` from disk while a host is running it. Everything tying the Zig constants to the MSL read the **embedded** copy at comptime, which is correct and had to stay correct: a test about a file that can differ between a build and a frame would say nothing, and making `zig build test` read the filesystem is the hermeticity [ADR 0009](../../adr/0009-runtime-shader-compilation.md) exists to protect.

The consequence is that a *reloaded* shader got `buildPipeline`'s missing-function check and nothing else. Move a `[[buffer(N)]]` and the reload succeeds.

The issue predicted this "becomes real at [#57](https://github.com/cboone/fosforo/issues/57)". It did: #57 restructured `trace_vertex` into instanced quads and added `TraceUniforms.density`, and [#60](https://github.com/cboone/fosforo/issues/60) added the palette texture. [#58](https://github.com/cboone/fosforo/issues/58) moves bindings again if velocity weighting adds a uniform of its own, so this landed ahead of it rather than behind it.

## What a mismatch actually costs, measured first

The comment above `window_buffer_index` said Metal "reports an unbound buffer at draw time, inside a DAW, on the render thread, with nothing this project can print". **It does not**, and this was measured before anything was written, because the whole decision the issue owns turns on it.

Three copies of the shipped shader, one index moved apiece, one per index space, each rendered through `zig build smoke-trace` with `FOSFORO_SHADER_PATH` pointing at it:

| Moved binding                               | Index space      | What was drawn            | `smoke-trace` verdict      |
| ------------------------------------------- | ---------------- | ------------------------- | -------------------------- |
| `samples [[buffer(0)]]` → `[[buffer(3)]]`   | Vertex buffer    | A flat trace at zero      | `LevelMisplaced`           |
| `palette [[texture(1)]]` → `[[texture(2)]]` | Fragment texture | Background `RGB(0, 0, 0)` | `BackgroundNotBlueLeading` |
| `&beam [[buffer(0)]]` → `[[buffer(1)]]`     | Fragment buffer  | No trace at all           | `TraceNotDrawn`            |

**Every draw completed and the process survived in all three.** The unbound argument reads as **zeros**, so the failure is a confident wrong picture with no diagnostic anywhere. Under `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert` the first case is named exactly, and then aborts:

```text
-[MTLDebugRenderCommandEncoder validateCommonDrawErrors:]:6001: failed assertion `Draw Errors Validation
Vertex Function(trace_vertex): missing Buffer binding at index 3 for samples[0].
```

That is the by-hand check the gotchas already prescribe, not anything CI runs.

## The decision this issue owned

**Warn and keep the swap**, which is what the issue recommended and what the measurement above turns from defensible into settled. Refusing costs a reloader that declines to reload, which is how people stop trusting one; keeping the swap costs a wrong picture the next save fixes, rather than a wedged GPU. Had the unbound read faulted, that comparison would have gone the other way.

Two consequences follow from the same measurement, and the second is the one that shaped the harness:

- A smoke arm that draws through a mismatch is survivable, and would still be wrong to write, because it **aborts** under the `MTL_DEBUG_LAYER=1` invocation the gotchas prescribe. Planting one would break a documented manual check with a deliberate fixture.
- So the arm goes in the GPU half, which reaches `probe` and never encodes a draw.

## The change

### `bindingIndexIn` replaces `bindingIndexAfter`, at `src/gpu/metal/renderer.zig:722`

The old helper closed over `shader_source` and took `comptime needle` and `comptime kind`, because it built its search string as `"[[" ++ kind ++ "("`. The new one takes its source as a parameter and walks the attributes after the anchor, matching `kind` then `(` at each, which is what a runtime caller can do without allocating. Scanning to end of file and answering null is kept: the negative control asserting there is no `sampler` anywhere in the shader rests on it, and `src/gpu/palette.zig` names that assertion.

One implementation rather than two is the point. The reloaded shader is judged by the same rule as the shipped one instead of by a second rule that resembles it.

### One `bindings` table with two readers, at `src/gpu/metal/renderer.zig:353` and `:372`

Eight entries, each an anchor, a kind and the constant this file binds at. The comptime test walks it over the embedded copy; `noteBindings` walks it over whatever came off disk. A binding added there is covered by both, and the two cannot drift because there is one list.

The anchor is the parameter declaration and never the bare attribute, for the reason established the expensive way at #57 and #60: `buffer(0)` appears in this shader whatever the constants say, so `indexOf("buffer(0)")` passes when two indices are swapped, when a fragment binding drifts while a vertex one still uses the number, and when either fragment texture moves alone.

### `noteBindings`, at `src/gpu/metal/renderer.zig:792`

Reports the first mismatch and returns. Two messages rather than one, because a wrong number and an absent anchor are different mistakes:

```text
[fosforo] shader: `device const float *samples` reads buffer(3) where this build binds 0; the picture will be wrong
```

### `iface.ShaderStats.binding_mismatches`, at `src/gpu/iface.zig:385`

So the check is asserted rather than trusted. A warning on a stream nothing reads is indistinguishable from a check that never ran, which is the distinction [ADR 0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md) keeps insisting on. It is a field rather than a twelfth seam operation, which is what let a fifth number arrive without touching the signature list.

### Two call sites, at `src/gpu/metal/renderer.zig:2608` and `:1130`

`buildPipelines`, which serves an editor opening, and `Watcher.poll`, which serves the live swap. Covering only the watcher would have made a moved index loud on every save and silent on every editor opening, which is the more confusing half of the two.

### The smoke arm, at `src/smoke.zig:393` and `:489`

`moveBinding` is the embedded shader with `samples` reading `buffer(3)`. It compiles cleanly and defines everything the pipelines ask for, which is what makes it a different fixture from `renameResolve` rather than a variation on it: every check that existed before this passes that file.

The arm asserts the decision rather than the mechanism — `binding_mismatches` moved by one *and* `reloads` moved by one — so reversing warn-to-refuse fails something. The identical-copy arm above it carries the negative control at `:452`, without which "the mismatch was noticed" cannot be told from "every reload is reported as a mismatch".

### A canary for the watcher's call site, at `src/gpu/metal/renderer.zig:3999`

The watcher's call site is not reachable from a smoke arm, for the validation-layer reason above, so `src/canary.zig` counts the two call sites as text: each stated once, and `noteBindings(` mentioned three times, being the two calls and the declaration. `stated` alone cannot see a third caller appearing elsewhere; `mentions` is that half.

## What this does not close, stated in the code

**`TraceUniforms` layout drift.** MSL computes its own struct offsets, so a field added or reordered on one side only leaves text that still describes the struct correctly and draws a plausible trace at the wrong scale. Nothing reading the source can see it.

[#51](https://github.com/cboone/fosforo/issues/51) does not close it either, which is worth stating because the obvious reading is that it would: `zig build smoke-trace` measures the **embedded** shader and nothing reloads during a trace run. Closing it needs a readback of a *reloaded* shader, which ADR 0013 refuses, since pointing the readback at the filesystem would make `smoke-trace` depend on it.

Said in three places rather than one: `noteBindings`' docstring, the `binding_mismatches` field, and the ADR 0009 consequence.

**A false positive is accepted.** The anchor is a parameter declaration, so renaming a parameter without moving its index reads as a mismatch. It costs one printed line naming the anchor it looked for, never a refused swap. The alternative is parsing MSL.

## Documents

| File                                 | Change                                                                                                                              |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `AGENTS.md`                          | The hot-reload gotcha rewritten; the `TraceUniforms` bullet's `bindingIndexAfter` reference and its "same problem" clause corrected |
| `docs/adr/0009-…`                    | "What reloading does not check" rewritten: half discharged, half restated, with the measurement that decided warn over refuse       |
| `docs/plans/todo/2026-07-25-repo-…`  | Phase 3 table row for #77 to **Done**; the "overdue rather than upcoming" paragraph and the free-lane list updated                  |
| `docs/plans/todo/2026-09-04-close-…` | The "already filed" row for #77 marked done                                                                                         |
| `src/gpu/palette.zig`                | The `sampler` negative assertion's reference renamed to `bindingIndexIn`                                                            |

## Verification

Six defects planted against the committed change, each restored afterwards:

| Planted                                              | Caught by                                                                      |
| ---------------------------------------------------- | ------------------------------------------------------------------------------ |
| `Watcher.poll`'s call site dropped                   | The canary, `expected 1, found 0`                                              |
| `buildPipelines`' call site dropped                  | The canary, and `smoke-gpu` as `MovedBindingNotNoticed`                        |
| The checker refuses every shader                     | Three unit tests, and `smoke-gpu` as `UnexpectedBindingMismatch`               |
| The checker never fires                              | Two unit tests, and `smoke-gpu` as `MovedBindingNotNoticed`                    |
| `bindingIndexIn` reverted to the vacuous bare search | Four unit tests, the anchoring one by name                                     |
| `palette [[texture(1)]]` moved in the shipped shader | The comptime walk, naming ``the binding anchored on `access::read> palette` `` |

Green afterwards: `zig build test`, `smoke-gpu`, `smoke-trace`, `smoke-appkit`, `validate-shaders`, `zig fmt --check`, `zig build`, `zig build --release=fast`, `markdownlint-cli2`, `typos`.

Not run, and neither is reachable from this change: a host, since nothing here alters what is drawn, and `ring-race`, which needs a Linux host.

## Out of scope

Anything needing a readback of a *reloaded* shader, for the ADR 0013 reason above. Validating the embedded shader, since the comptime tests already do it and should keep doing it. Putting `MTL_DEBUG_LAYER` in CI, which is [#69](https://github.com/cboone/fosforo/issues/69).
