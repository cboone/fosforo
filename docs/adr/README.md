# Architecture decision records

Each file records one decision, the context that forced it, and its consequences. Decisions here are settled and should be built on rather than reopened. If one turns out to be wrong, add a new ADR superseding it rather than editing history.

Background for all of these lives in [the design brainstorm](../design/scope-plugin-handoff.md); sequencing lives in [the build plan](../plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md).

| ADR                                                 | Decision                                                   | Status   |
| --------------------------------------------------- | ---------------------------------------------------------- | -------- |
| [0001](./0001-mac-first-apple-silicon.md)           | Mac-first, Apple Silicon primary                           | Accepted |
| [0002](./0002-zig-pinned-to-0-16-0.md)              | Zig, pinned to 0.16.0                                      | Accepted |
| [0003](./0003-author-clap-project-outward.md)       | Author CLAP once, project outward with clap-wrapper        | Accepted |
| [0004](./0004-clap-bindings-via-translate-c.md)     | CLAP bindings via translate-c over normalized headers      | Accepted |
| [0005](./0005-metal-behind-a-renderer-seam.md)      | Metal directly, behind a small internal renderer interface | Accepted |
| [0006](./0006-reject-webview-ui.md)                 | Reject a WebView UI                                        | Accepted |
| [0007](./0007-renderer-simulates-a-crt.md)          | Render as a simulation of a physical device                | Accepted |
| [0008](./0008-objective-c-glue-via-zig-objc.md)     | Objective-C glue via zig-objc                              | Accepted |
| [0009](./0009-runtime-shader-compilation.md)        | Runtime MSL compilation is the single runtime path         | Accepted |
| [0010](./0010-lock-free-history-buffer.md)          | Lock-free circular history buffer, not a queue             | Accepted |
| [0011](./0011-auv2-first.md)                        | AUv2 first, AUv3 and other formats deferred                | Accepted |
| [0012](./0012-phosphor-oscilloscope-first.md)       | First deliverable is the phosphor oscilloscope only        | Accepted |
| [0013](./0013-gui-smoke-harness-as-a-build-step.md) | The GUI smoke harness is a build step, not a test          | Accepted |
