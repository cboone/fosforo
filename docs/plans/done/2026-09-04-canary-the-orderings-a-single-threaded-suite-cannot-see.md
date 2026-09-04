# Canary the std.Io constructor and the orderings a single-threaded suite cannot see

Issue: [#90](https://github.com/cboone/fosforo/issues/90). Type: `test:`. Item 2 of [the verification-gap program](../todo/2026-09-04-close-the-verification-gaps-in-the-test-suite.md), which stays in `todo/` until the other ten land.

## Context

`src/dsp/ring.zig:742` embeds its own source at comptime and asserts the five atomic operations are stated exactly as written. [ADR 0016](../../adr/0016-verify-the-ring-ordering-with-tsan.md) explains why: the machine this project is developed on is the one machine that cannot run the sanitizer, so a weakened atomic passes locally and is learned about only after a push. The canary is deliberately the faster of the two checks rather than the harder to fool.

That pattern exists once, and four declarations of the same kind have no equivalent. The sharpest is `src/platform/io.zig:38`, which is a non-negotiable in `AGENTS.md` with **zero tests, no comptime assertion and no canary** behind it: `Threaded.init` calls `posix.sigaction` on `SIG.IO` and `SIG.PIPE`, and a plugin lives in the host's address space, so adopting it would replace REAPER's or Logic's handlers rather than install its own.

Three findings from exploration shape the work, and one contradicts the issue as filed.

**`statedOnce` cannot express `Gate`.** `enter`'s refusal path and `leave` state `_ = self.state.fetchSub(one_tick, .release);` **identically** (`gui.zig:919,927`). The helper has to return a count.

**`src/platform/io.zig` has no test section at all**, and is absent from `src/main.zig`'s test-collection list. It needs both.

**The acceptance criterion's first plant does not compile.** `std.Io.Threaded.init` calls `posix.sigaction` and `std.Thread.getCpuCount()` (`std/Io/Threaded.zig:1607`), and a container-level `var` initializer must be comptime-evaluable, so `var backend: std.Io.Threaded = .init(...);` is a compile error rather than a test failure. **The type system already refuses the direct substitution.** What it does not refuse is the restructure that reaches the same place:

```zig
var backend: std.Io.Threaded = undefined;
pub fn setup(gpa: std.mem.Allocator) void {
    backend = .init(gpa, .{});
}
```

So the canary's real job here is catching that shape, and the plant used to verify it must be that shape. This is recorded rather than treated as a defect in the issue: it is the strongest fact available about the declaration and it belongs in the ADR amendment.

## Design

**One test-only module, `src/canary.zig`**, rather than four copies of a helper whose two known flaws would then stand corrected beside the flawed original. `src/dsp/ring.zig` migrates onto it, which is what makes the reference implementation and the transplant the same code.

Both flaws named in the issue are fixed by one decision: **a line is a statement line when its trimmed text does not begin with `//`.** Matching on the trimmed line retires the eight-space format, so moving a statement into an `if` block is a wash rather than a failure. Counting only over statement lines retires the prose fragility, so a new doc comment naming `self.cursor.load` cannot break an anchor, and it is what makes `mentions(code, "Threaded.init") == 0` expressible at all in a file whose docstring names `Threaded.init` twice.

```zig
//! src/canary.zig, reached only from `test` blocks.

/// The file's own source above its tests banner, so a canary cannot read its
/// own string literals and count them as code.
pub fn implementation(source: []const u8) []const u8

/// How many statement lines are exactly `line`, ignoring indentation.
pub fn stated(code: []const u8, line: []const u8) usize

/// How many statement lines contain `needle`. Comment lines never count,
/// which is what lets an anchor survive a new paragraph of prose.
pub fn mentions(code: []const u8, needle: []const u8) usize

/// Whether each is stated exactly once and `first` precedes `second`.
/// Counting cannot see two correct lines in the wrong order.
pub fn statedBefore(code: []const u8, first: []const u8, second: []const u8) bool
```

`implementation` cuts at `"\n// Tests\n"`, which every file here already has as a section banner, so there is nothing extra to keep in step. Each site still calls `@embedFile` itself, because it resolves relative to the importing file.

The residual to document: a trailing comment on a code line still counts, because stripping from the first `//` on a statement line would misread a string literal containing one. No line in the five files has one, and the alternative is a tokenizer.

`src/canary.zig` gets its own tests, including the comment-stripping and the ordering helper.

## The five sites

### `src/platform/io.zig`

Two guards, because neither covers the other. The declaration splits so the initializer is nameable:

```zig
const backend_init: std.Io.Threaded = .init_single_threaded;
var backend: std.Io.Threaded = backend_init;

comptime {
    // A constructor that installs signal handlers cannot be comptime-evaluated,
    // so a `const` of this type is already half the proof. These pin the value
    // rather than the token that named it, which is what a find-and-replace
    // rewriting the canary's string literals would leave standing. Unlike a
    // runtime assert this survives `--release=fast`, because a failing comptime
    // assert is a compile error in every optimize mode.
    std.debug.assert(!backend_init.have_signal_handler);
    std.debug.assert(backend_init.async_limit == .nothing);
    std.debug.assert(backend_init.concurrent_limit == .nothing);
}
```

`Io.Limit` is `enum(usize)` (`std/Io.zig:626`) so both comparisons are legal; the field set is `std/Io/Threaded.zig:1674`, to be re-read rather than recalled when writing it.

A new `// Tests` banner and section, matching the three-line box the other files use, holding the text canary:

| Assertion                                                                           | What it refuses                               |
| ----------------------------------------------------------------------------------- | --------------------------------------------- |
| `stated(code, "const backend_init: std.Io.Threaded = .init_single_threaded;") == 1` | The constructor changing                      |
| `stated(code, "var backend: std.Io.Threaded = backend_init;") == 1`                 | The instance being initialized some other way |
| `mentions(code, "Threaded.init") == 0`                                              | The restructure into a runtime `setup`        |
| `mentions(code, "std.Io.Threaded") == 2`                                            | A second instance arriving beside the first   |
| `stated(code, "return backend.io();") == 1`                                         | `get` handing back a different instance       |
| `mentions(code, "backend =") == 0`                                                  | The restructure, from the assignment side     |

Split across two tests, so a failure says whether the constructor moved or the instance did. The third is possible only because comments do not count. It pins one spelling: writing the const as `std.Io.Threaded.init_single_threaded` would trip it, which is the canary contract rather than a false positive. The last does not match the declaration itself, which reads `backend:` before its `=`.

### `src/clap/gui.zig`

Two tests, so a failure names which mechanism moved.

`Gate` and `Pending`, the two that stand between a host's main thread and memory the render thread is reading:

- `stated(code, "self.slot.store(@bitCast(message), .release);") == 1`
- `stated(code, "const raw = self.slot.swap(empty, .acquire);") == 1`
- `mentions(code, "self.slot.") == 2`
- `stated(code, "const previous = self.state.fetchAdd(one_tick, .acquire);") == 1`
- `stated(code, "_ = self.state.fetchSub(one_tick, .release);") == 2` — the refusal path and `leave`, stated identically
- `stated(code, "_ = self.state.fetchOr(closed, .acquire);") == 1`
- `stated(code, "while (self.state.load(.acquire) != closed) {") == 1`
- `mentions(code, "self.state.") == 5`

`Editor`'s five counters, which cross the same two threads and carry the diagnostics rather than the memory. Each by its whole statement plus a count: `self.presented.` 2, `self.window.` 3, `self.uploaded.` 2, `self.torn.` 2, `self.meter_reset.` 2. The `self.window.` count is 3 rather than 2 because `Editor.report` reads it inside a multi-line `l.print` call at `gui.zig:833`, whose trimmed line carries a trailing comma.

### `src/gpu/metal/renderer.zig`

`Mailbox`, by statement and count (`self.state.` 5, `self.staged` 2), and by order, which counting cannot see:

- `statedBefore(code, "const taken = self.staged;", "self.state.store(.empty, .release);")`
- `statedBefore(code, "self.staged = pipelines;", "self.state.store(.full, .release);")`

`take`'s docstring names reversing the first pair as "the defect this comment exists to prevent", and the result is a picture drawn from two different compiles rather than a crash.

`Watcher.halt`, the stop flag and the futex word in one, whose docstring says splitting it costs a quarter second on the host's main thread every time an editor closes: the declaration at `renderer.zig:771` plus the four statements that touch it, and `mentions(code, "self.halt.") == 4`.

### `src/dsp/ring.zig`

The test name, the docstring and the five assertions stay. `implementation` and `statedOnce` are deleted, `statedOnce(code, x)` becomes `expectEqual(1, canary.stated(code, x))`, and `std.mem.count(u8, code, "self.cursor.")` becomes `canary.mentions(code, "self.cursor.")`, still 5.

### `src/main.zig`

`_ = @import("canary.zig");` and `_ = @import("platform/io.zig");` in the test block, beside the existing list and its comment. Confirm the collected test count rises with `--summary all` rather than assuming transitive import was enough.

## Documents

**[ADR 0015](../../adr/0015-adopt-std-io-single-instance.md)** gains a consequence: the constructor rule, enforced by convention since it was written, now has a comptime check and a canary, and the reason it needs both is that the type system already refuses the direct substitution and refuses nothing about the restructure.

**`AGENTS.md`**, three places:

- The ADR 0015 non-negotiable (line 43) gains the guard.
- The ADR 0016 non-negotiable (line 45) and the `src/dsp/ring.zig` gotcha (line 333) both describe the canary as this project's only one. It is now the shape rather than the instance.
- The Structure block gains `src/canary.zig`.

The program plan is not edited: it tracks eleven issues and moves to `done/` as a whole.

## Verification

`zig build test` is the only resource this needs, so it runs beside anything in phase 3.

Each canary is verified by planting the edit it refuses, confirming `zig build test` fails naming the line, then reverting. **Commit the canary before planting against it**, so `git restore` reverts the plant and not the check it was testing.

All eleven were planted and reverted. **Result column is what happened, not what was expected.**

| Plant                                                                  | Site                     | Result                                                |
| ---------------------------------------------------------------------- | ------------------------ | ----------------------------------------------------- |
| `.init_single_threaded` to `.init`, as the issue words it              | `platform/io.zig`        | **compile error**, `comptime call of extern function` |
| `backend` restructured to `undefined` plus a `setup` calling `.init`   | `platform/io.zig`        | both tests, at `io.zig:85` and `io.zig:115`           |
| `have_signal_handler` set true on the initializer                      | `platform/io.zig`        | the comptime block, at build time, `io.zig:67`        |
| `Gate.enter`'s `fetchAdd(one_tick, .acquire)` to `.monotonic`          | `clap/gui.zig`           | `gui.zig:1177`                                        |
| `Gate.leave`'s `fetchSub` to `.monotonic`, one of the two              | `clap/gui.zig`           | `gui.zig:1183`, the count of 2 falling to 1           |
| `Pending.post`'s `store(..., .release)` to `.monotonic`                | `clap/gui.zig`           | `gui.zig:1170`                                        |
| `Editor.setWindow`'s `store(..., .release)` to `.monotonic`            | `clap/gui.zig`           | `gui.zig:1210`                                        |
| `Mailbox.publish`'s `store(.full, .release)` to `.monotonic`           | `gpu/metal/renderer.zig` | `renderer.zig:3645`                                   |
| `Mailbox.take`'s two lines swapped, both still correct                 | `gpu/metal/renderer.zig` | `renderer.zig:3657`, `statedBefore` alone             |
| `Watcher.halt` split into a `bool` and a separate futex word           | `gpu/metal/renderer.zig` | `renderer.zig:3686`                                   |
| `ring.zig`'s release store to `.monotonic`, a control on the migration | `dsp/ring.zig`           | `ring.zig:736`                                        |

Two negative controls, where **passing is the result**, because they are the flaws the issue names and an assertion about them would be a description:

| Control                                                        | Site           | Result                             |
| -------------------------------------------------------------- | -------------- | ---------------------------------- |
| A statement re-indented into an `if` block, no semantic change | `dsp/ring.zig` | green — the eight-space flaw, gone |
| A doc comment naming `self.cursor.load` added above the banner | `dsp/ring.zig` | green — the count flaw, gone       |

The `Mailbox.take` row is the one worth reading twice: it fails `statedBefore` and **nothing else**. Every count and every `stated` assertion passes with those two statements reversed, which is the hole the helper was added to close.

Then `zig fmt --check build.zig src/` and `markdownlint-cli2` in check mode only, never `--fix`, which ignores its file argument and rewrites every file in the tree.

## What this does not close

A canary proves the lines are unchanged, not that they are correct, and `ring.zig`'s own docstring says so. A global find-and-replace rewrites the canary's string literals along with the code; `io.zig`'s comptime block is the one guard here that survives that, and it survives it only for the value, not for the structure. For `Gate` and `Pending` the backstop is [#91](https://github.com/cboone/fosforo/issues/91), which races them under Thread Sanitizer. `Mailbox` and `Watcher.halt` have no such backstop and this is what they get.

## Commits

1. `test: add the canary helpers and move the ring onto them (#90)`
2. `test: canary the std.Io constructor, and pin its value at comptime (#90)`
3. `test: canary the gate, the size mailbox and the editor's counters (#90)`
4. `test: canary the pipeline mailbox and the watcher's halt (#90)`
5. `docs: record that ADR 0015's constructor rule now has a guard (#90)`
