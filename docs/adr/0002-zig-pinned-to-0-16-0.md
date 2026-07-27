# 0002. Zig, pinned to 0.16.0

**Status:** Accepted

## Context

The plugin format is a plain C API ([ADR 0003](./0003-author-clap-project-outward.md)), the rendering API is reached through the Objective-C runtime's C interface, and the DSP is small numeric kernels. The language that fits is one with frictionless C interoperability and good SIMD.

Zig provides three things that fit this problem unusually well:

- **C interoperability with no binding layer.** A C header becomes a Zig module with no glue to write or maintain.
- **Portable first-class SIMD** through `@Vector`. Decimation, cross-correlation, and interpolation vectorize cleanly with no intrinsics and no per-target conditionals.
- **An explicit-allocator convention.** If the DSP path takes an allocator and is handed a fixed-buffer allocator sized at preparation time, then "does the audio path touch the heap" becomes a fact about the call graph rather than a convention that was hopefully honored. This matters because memory safety is not real-time safety: a lock or an allocation compiles perfectly and still destroys audio-thread performance.

The cost is that Zig is pre-1.0 and moves.

## Decision

Use Zig, pinned to 0.16.0 (current stable, released 2026-04-13). The pin lives in `build.zig.zon` as `minimum_zig_version`, which CI reads as the single source of truth.

Treat compiler upgrades as scheduled, deliberate work, never as incidental churn absorbed mid-feature.

## Consequences

0.16.0 is an unusually disruptive release, and this is not hypothetical. Verified against the installed toolchain:

- `@Type` is **removed**. Function types can no longer be reified from a tuple; the replacements are the `@Fn` and `@Tuple` builtins. This breaks the conventional comptime `objc_msgSend` pattern (see [ADR 0008](./0008-objective-c-glue-via-zig-objc.md)).
- `@cImport` is **deprecated** in favour of `b.addTranslateC()` in the build system (see [ADR 0004](./0004-clap-bindings-via-translate-c.md)).
- `std.fs.File` moved to `std.Io.File`, and all I/O now takes an `std.Io` parameter.
- Runtime indexing into a vector is **forbidden**, which directly constrains how the SIMD kernels are written.
- `heap.ThreadSafe` is removed; `ArenaAllocator` is now lock-free and thread-safe.

The practical consequence is that essentially every third-party Zig audio project predates this release and does not build. The project therefore keeps its dependency surface minimal and verifies each dependency against 0.16.0 before adopting it.
