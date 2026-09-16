# Shader instructions

Read [shader plumbing](../docs/notes/shader-plumbing.md) and [trace and phosphor physics](../docs/notes/trace-and-phosphor-physics.md) before editing shader source or bindings.

- `scope.metal` is embedded and compiled at runtime. Debug builds can reload it; keep shared structures and binding indices consistent with Zig. Reload validation checks binding indices, but cannot detect `TraceUniforms` layout drift; the separate layout test covers the embedded build.
- The trace deposits scalar energy. Geometry, velocity weighting, elapsed-time decay and fixed resolve/gradient contracts determine the phosphor image; do not add independent signal autoscaling or conceal over-scale input.
- Use `zig build validate-shaders` with the Metal toolchain for compilation and `zig build smoke-trace` for what the shipping pipeline actually draws. A compilation pass alone does not verify pixels.
- Run the worktree's own capture measurement script and follow the root provenance, 48 kHz and ignored-capture rules for host verification.
