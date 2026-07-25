# 0008. Objective-C glue via zig-objc

**Status:** Accepted

## Context

Zig has no native Objective-C bridge, so reaching AppKit and Metal means going through the Objective-C runtime's C API: the `objc_msgSend` family, plus class and selector lookups.

On Apple Silicon this is markedly less painful than it historically was. arm64 collapses the old struct-return and float-return message-send variants into a single entry point, so one cast per signature suffices. Verified directly: a float-returning message send through plain `objc_msgSend` returns correctly, with no `objc_msgSend_fpret` needed.

The conventional Zig approach builds the function type at comptime from a tuple of argument types and casts the single `objc_msgSend` symbol to it. **That approach is broken on Zig 0.16**, which removed `@Type` ([ADR 0002](./0002-zig-pinned-to-0-16-0.md)). Function types can no longer be reified that way.

## Decision

Use [`zig-objc`](https://github.com/mitchellh/zig-objc) as a dependency.

## Consequences

It was verified against the pinned toolchain before adoption, which given the state of the Zig ecosystem was not a formality:

- It is **MIT** licensed, so it carries none of the copyleft problems that disqualified `clap-zig-bindings` ([ADR 0004](./0004-clap-bindings-via-translate-c.md)).
- Its test suite **passes on Zig 0.16.0**.
- It has already migrated to the replacement builtins, constructing message-send signatures with `@Fn` and `@Tuple` rather than the removed `@Type`.

That last point is why this ADR exists at all. The design brainstorm assumed this glue would have to be hand-rolled, on the reasoning that no existing Zig project had solved it. That is now false, and adopting the maintained implementation is preferable to carrying a hand-written one.

**A fallback exists and has been proven.** A minimal per-arity wrapper set (`send0`, `send1`, `send3`, and so on, each casting `objc_msgSend` to an explicitly spelled function type) works on 0.16 without any comptime reification. It was used to validate the whole Metal path before this decision was made: acquiring the device, reading `hasUnifiedMemory`, and compiling a shader at runtime. If `zig-objc` ever falls behind a Zig release, dropping to roughly forty lines of project-local glue is a viable and cheap escape rather than a crisis.

The glue is confined to `src/platform/objc.zig`. It is the tax paid for owning the whole view rather than adopting a UI framework, and for a diagnostic instrument where exact frame timing matters, that ownership is the right trade.
