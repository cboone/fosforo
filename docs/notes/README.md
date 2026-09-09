# Notes

Each file here records how some part of this project actually behaves: what was measured, what was refused, and which instrument answers which question. They exist because [`AGENTS.md`](../../AGENTS.md) is loaded into an agent's context in full on every session and a reference document is not, so depth that is only needed while working on one area belongs here and a rule that prevents damage belongs there.

**A note is not an ADR and not a plan, and the difference decides how it is edited.** An [ADR](../adr/README.md) records a decision and is superseded by a new ADR rather than rewritten. A [plan](../plans/) in `done/` is a historical record and is never corrected at all. A note is a **living document**: when a measurement here goes stale, the repair is a fresh measurement written in place, and a `path:line` citation in one is a claim about current code. Sequencing lives in [the build plan](../plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md).

**Every figure here was measured rather than reasoned about**, and several are the only copy in the repository. Before changing one, read [`.github/docs.instructions.md`](../../.github/docs.instructions.md): a corrected figure has to be grepped repo-wide, because these numbers are quoted across `AGENTS.md`, `CHANGELOG.md`, several ADRs, the build plan and sometimes a workflow comment.

**Fifteen `AGENTS.md:<line>` citations in `docs/plans/done/` predate this split and no longer resolve.** They are historical records and are deliberately not updated; four of them had already stopped resolving before the split, since every merge since shifted the numbers. `15174cf` is the last commit in which `AGENTS.md` carried the gotchas, so `git show 15174cf:AGENTS.md` is what such a citation should be read against, or an earlier commit for one written further back.

| Note                                                          | Read it before                                                          |
| ------------------------------------------------------------- | ----------------------------------------------------------------------- |
| [Build system](./build-system.md)                             | editing `build.zig`, `cmake/`, `macos/Info.plist`, or any identifier    |
| [CI workflows](./ci-workflows.md)                             | editing anything under `.github/workflows/`                             |
| [Concurrency and canaries](./concurrency-and-canaries.md)     | touching an atomic, a canary, `std.Io`, or a race harness               |
| [Host verification](./host-verification.md)                   | running the plugin in REAPER or Logic, or trusting a result from one    |
| [Leak instruments](./leak-instruments.md)                     | adding an allocation, or reading a `leaks` report                       |
| [Linters](./linters.md)                                       | running or configuring `shfmt`, `typos`, `ruff`, Prettier, markdownlint |
| [Measuring a capture](./measuring-a-capture.md)               | taking a screenshot of the editor, or quoting a number read out of one  |
| [Reading diagnostics](./reading-diagnostics.md)               | looking for a log line from the plugin                                  |
| [Render loop lifecycle](./render-loop-lifecycle.md)           | editing `src/clap/gui.zig`, `src/platform/`, or `Renderer.frame`        |
| [Shader plumbing](./shader-plumbing.md)                       | editing `shaders/scope.metal` or anything that binds to it              |
| [Signing and notarization](./signing-and-notarization.md)     | signing, packaging, or cutting a release                                |
| [Smoke harness](./smoke-harness.md)                           | changing `src/smoke.zig` or any `zig build smoke-*` step                |
| [The test suite](./the-test-suite.md)                         | reasoning about what `zig build test` does and does not compile         |
| [Trace and phosphor physics](./trace-and-phosphor-physics.md) | judging whether what is on screen is the signal or an artifact          |
