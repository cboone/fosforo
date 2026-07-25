# 0005. Metal directly, behind a small internal renderer interface

**Status:** Accepted

## Context

Rendering is the product. The moat for a genuinely excellent analyzer is rendering and interaction design, not DSP, so the graphics path should be the best-integrated and lowest-overhead one available.

Metal is Apple-only with no caveats. But the scope of that lock is narrower than it feels. Everything below the renderer is platform-neutral by construction: CLAP is cross-platform, the DSP is pure computation that compiles identically anywhere Zig targets, the lock-free buffer is atomics and an array, and even the *structure* of the renderer (a persistent floating-point accumulation texture, a decay pass, an additively blended trace, a tonemap) is an abstract GPU algorithm any modern API expresses. What is genuinely Apple-specific is a thin skin: the calls that allocate the texture, the language the shaders are written in, and the glue handing a drawable to the host.

Four portability strategies were considered: a small internal rendering interface; adopting a cross-platform abstraction such as `wgpu`; authoring shaders once and cross-compiling through SPIR-V; and a WebView (rejected outright in [ADR 0006](./0006-reject-webview-ui.md)).

## Decision

Build the Metal backend directly and do **not** abstract it yet. Keep the renderer behind a small internal interface as code hygiene, and forbid Metal types from leaking above that seam, even with only one backend behind it.

The interface is shaped to this algorithm rather than to graphics in general, so it stays small: create a floating-point texture; run a fullscreen pass with a fragment shader; draw N instanced quads with additive blending; present.

## Consequences

This costs almost nothing now and converts an eventual port from "excavate Metal calls out of a renderer they have grown through" into "write a second backend against a known handful of operations."

Adopting `wgpu` or a shader cross-compilation pipeline pre-emptively is explicitly the thing to avoid. Both pay a concrete tax today against a benefit that may never come due, and both dilute exactly the own-the-stack quality that made the native choice attractive. Design for the port; do not build it until someone needs it.

The seam lives at `src/gpu/iface.zig`. Metal lives strictly beneath it in `src/gpu/metal/`. A review that finds a Metal type named above the seam should treat that as a defect.

Cross-platform is not currently a goal, so the second backend is not planned work.
