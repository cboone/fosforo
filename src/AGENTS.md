# Source instructions

Paths in code spans are relative to the repository root. Read the linked notes before working on their subjects.

- Keep Metal behind `src/gpu/iface.zig` and all audio-thread paths free of allocation, locks and syscalls. The one single-threaded `std.Io` instance belongs in `src/platform/io.zig`.
- For atomics, source canaries, `std.Io` or race harnesses, read [concurrency and canaries](../docs/notes/concurrency-and-canaries.md). Preserve release/acquire ordering and controls that prove the race instruments can detect a defect. Add source canaries for ordering-critical declarations.
- For `src/clap/gui.zig`, `src/platform/` or `Renderer.frame`, read [render loop lifecycle](../docs/notes/render-loop-lifecycle.md): teardown gate, bounded waits, semaphore slots, staging and ownership are linked constraints.
- For shader bindings or backend work, read [shader plumbing](../docs/notes/shader-plumbing.md). Keep binding indices and shared structures consistent between Zig and Metal. Reload validation checks binding indices; the separate layout test covers the embedded build, and reloaded `TraceUniforms` layout drift remains unobservable.
- Read [leak instruments](../docs/notes/leak-instruments.md) before adding allocations or interpreting leak reports; the instruments cover different allocations and counters.
- For `src/smoke.zig`, read [smoke harness](../docs/notes/smoke-harness.md). The smoke executable is rebuilt by its own build steps, independently of `zig build`.
- Read [test suite](../docs/notes/the-test-suite.md) for lazy declaration analysis, the declaration sweep and Debug/ReleaseSafe/ReleaseFast coverage. Use `zig build test`, `test-safe` and `test-release` as appropriate; pure measurement and verdict logic runs without a GPU.
- Read [trace and phosphor physics](../docs/notes/trace-and-phosphor-physics.md) before changing the absolute axis, energy, palette, rail or capture interpretation.
