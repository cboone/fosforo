# Make the shader watcher's bookkeeping reachable from a test build

Issue: [#93](https://github.com/cboone/fosforo/issues/93). Type: `refactor:` then `test:`. Item 5 of [the verification-gaps program](2026-09-04-close-the-verification-gaps-in-the-test-suite.md), and one of the two still open there alongside [#98](https://github.com/cboone/fosforo/issues/98).

## Context

`src/gpu/metal/renderer.zig:957` reads `const Watcher = if (shader.live) struct { ... } else struct { ... }`, and `shader.live` is `builtin.mode == .Debug and !builtin.is_test` (`src/gpu/metal/shader.zig:45`). A test binary is a Debug build with `is_test` set, so it always selects the stub. The real `poll` at `renderer.zig:1090-1152` is absent from every test binary, and with it the three `fetchAdd` calls at `:1117`, `:1124` and `:1133` and the load-bearing rule argued at `:1110-1114`:

```zig
// **Advanced before the compile, and on every outcome including failure.**
// Without that a broken file prints the same diagnostic four times a
// second forever; with it, it prints once per save and recovers when the
// file is fixed.
self.seen = now;
```

This is not _uncovered_. A plain `zig build` is Debug and not a test, so it type-checks the live body, and `smoke-appkit`'s `hotReloadPhase` exercises it across five arms. It is **uncoverable** by the check that runs on every push and on every machine, which is worse: the gate is structural, so no test written in `zig build test` can reach this code however it is written. `--release=fast` selects the stub too, so #94's `test-safe` and `test-release` close nothing here either.

**The gate is in two places and the second one matters more.** The same bookkeeping is duplicated in `buildPipelines` (`renderer.zig:2613-2639`, increments at `:2622`, `:2634`, `:2636`) inside its own `if (comptime shader.live)`, and once more in `readShader` (`:2650-2663`, at `:2653` and `:2656`). That second copy is the one [ADR 0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md) rests on, because `probe` and `init` share `buildPipelines` rather than paraphrasing it and the function's own comment says so. A test build takes the `else` on both, so neither is compiled.

**And the two copies do not agree, which is the finding rather than the tidying.** The watcher's compile failure moves `rejected` alone, because nothing falls back and the shader now running stays; `buildPipelines`' moves `rejected` _and_ `fallbacks`, because the embedded copy is what the editor opens with. That asymmetry is deliberate, is documented in `iface.ShaderStats.fallbacks`, and exists today only as two pairs of `fetchAdd` lines two thousand lines apart with nothing tying them together.

This is the same move as [#92](https://github.com/cboone/fosforo/issues/92), which took the trace half's _judgements_ out of `src/smoke.zig` into `src/gpu/verdict.zig` on `src/gpu/measure.zig`'s precedent, and the same move `shader.choosePath` already is one file over: it is split out of `resolvePath` for exactly this reason, stated at `shader.zig:119-121` — "`live` is false in a test build by design, so `resolvePath` returns null there and a test of it would assert nothing about the property that matters."

## The baseline

Measured on this branch at `83ae938`, which is `main`:

| Check                        | Reading                                                             |
| ---------------------------- | ------------------------------------------------------------------- |
| `zig build test`             | 297 of 297, 8 of 8 steps                                            |
| `src/gpu/metal/renderer.zig` | 4,073 lines                                                         |
| Counters                     | five file-scope `std.atomic.Value` in `renderer.zig`                |
| Counter write sites          | nine, across `poll`, `buildPipelines`, `readShader`, `noteBindings` |

**Every line citation in the issue and in the program plan's item 5 is stale**, by roughly 190 to 270 lines: #96, #97 and #114 landed after the last refresh. The numbers above were re-read against this branch. The program plan says this out loud at its own line 48 — "every remaining item's acceptance should be re-derived against the tree rather than executed as written" — so re-deriving is following it rather than deviating.

## The change

### 1. `src/gpu/metal/reload.zig`, a new module below the seam

Beside `shader.zig` and for its reason: **it names no Metal type**, so it can sit under `gpu/metal/` without weakening `renderer.zig`'s claim to be the only file allowed to (ADR 0005). Imports `std`, `../iface.zig` and `shader.zig`, and nothing else, which is what lets `zig build test` cover all of it on a runner with no graphics support (ADR 0009). Tests under the `// ---` / `// Tests` / `// ---` banner every file here carries, which is also the cut point `canary.implementation` needs.

**It prints nothing, and that is the one place it departs from `verdict.zig`.** There the judges' bodies _were_ the printing, so `say` moved with them behind a `!builtin.is_test` gate. Here every message names a path, a `readFile` error, a byte count or a Metal diagnostic — all of them the driver's, none of them the tally's. So `sayShader` stays in `renderer.zig` with its `shader.live` gate untouched, and this module answers _whether_ to say rather than what.

```zig
/// What one look at the watched file resolves to.
pub const Step = enum { idle, reload };

/// Every way a source off disk can end, at either of the two sites that read one.
pub const Outcome = enum {
    watch_unreadable,
    watch_rejected,
    watch_reloaded,
    open_unreadable,
    open_rejected,
    open_reloaded,
};

/// What an outcome adds to the tally.
pub const Deltas = struct { reloads: u64 = 0, rejected: u64 = 0, fallbacks: u64 = 0 };

pub fn deltas(outcome: Outcome) Deltas { ... }
```

Six variants rather than three plus a site parameter, because the mapping is the whole content and a table with the site in the key is a table a test can read row by row:

| Outcome            | `reloads` | `rejected` | `fallbacks` | Says                      |
| ------------------ | --------- | ---------- | ----------- | ------------------------- |
| `watch_unreadable` |           |            | +1          | every time                |
| `watch_rejected`   |           | +1         |             | every time                |
| `watch_reloaded`   | +1        |            |             | every time                |
| `open_unreadable`  |           |            | +1          | only if `fallbacks` was 0 |
| `open_rejected`    |           | +1         | +1          | every time                |
| `open_reloaded`    | +1        |            |             | never                     |

```zig
/// The process-wide tally, and the say-once rule that rides on it.
pub const Counters = struct {
    path_resolved: std.atomic.Value(bool) = .init(false),
    reloads: std.atomic.Value(u64) = .init(0),
    rejected: std.atomic.Value(u64) = .init(0),
    fallbacks: std.atomic.Value(u64) = .init(0),
    binding_mismatches: std.atomic.Value(u64) = .init(0),

    /// Credit one outcome, and answer whether it is worth saying out loud.
    pub fn note(self: *Counters, outcome: Outcome) bool { ... }

    pub fn noteMismatch(self: *Counters) void { ... }
    pub fn notePathResolved(self: *Counters) void { ... }
    pub fn stats(self: *const Counters) iface.ShaderStats { ... }
};
```

**A type with a file-scope instance rather than five bare globals**, which is what makes it testable at all: a test constructs its own `Counters` and the shared one stays untouched. All writes stay `fetchAdd(1, .release)` and all reads `load(.acquire)`, unchanged.

**The say-once rule keeps its exact current coupling**, which is surprising enough to be worth a test rather than a comment. `readShader` guards its message with `shader_fallbacks.fetchAdd(1, .release) == 0`, and `buildPipelines`' rejection path moves `fallbacks` too, so **an `open_rejected` earlier in the process silences a later `open_unreadable`**. That is today's behaviour, it is preserved exactly, and it becomes an assertion instead of an accident.

```zig
/// One watcher's memory of the file, and every decision one poll makes.
pub const Watch = struct {
    seen: ?shader.Stamp = null,

    /// The baseline, taken when the thread starts rather than on its first poll.
    pub fn baseline(self: *Watch, now: ?shader.Stamp) void { ... }

    /// [watcher-thread] One look, and the only writer of `seen` besides the above.
    pub fn look(self: *Watch, vacant: bool, now: ?shader.Stamp) Step { ... }
};
```

`look` is total over its three inputs:

| `vacant` | `now` | `seen` before | `seen` after  | Returns   |
| -------- | ----- | ------------- | ------------- | --------- |
| false    | any   | any           | **unchanged** | `.idle`   |
| true     | null  | any           | unchanged     | `.idle`   |
| true     | some  | null          | `now`         | `.idle`   |
| true     | some  | equal         | unchanged     | `.idle`   |
| true     | some  | differs       | **`now`**     | `.reload` |

The last row is the whole issue: `seen` moves _inside_ `look`, before the caller has read a byte, so the advance-before-compile rule is a property of a function `zig build test` compiles rather than a statement order in one it does not.

### 2. `Watcher.poll` becomes a driver

The stat now precedes the vacancy question, which is the one behaviour change here and is deliberate. `poll`'s comment says the check is "before the stat, so a hidden editor costs nothing"; `Mailbox.vacant`'s own docstring says the check is "before the compile", and prices the hidden-editor case at "four `stat` calls a second and no XPC round trips at all". The two disagree today. This makes `vacant`'s accounting the true one, and buys the lossless-skip rule a place inside the tested function:

```zig
/// [watcher-thread] One look at the file.
fn poll(self: *Watcher, device: objc.Object) void {
    var path_buf: shader.PathBuffer = undefined;
    const path = shader.resolvePath(&path_buf) orelse return;
    const now: ?shader.Stamp = shader.stamp(path) catch null;

    if (self.watch.look(self.mailbox.vacant(), now) == .idle) return;

    shader.read(&self.buf, path) catch |err| {
        if (shader_counters.note(.watch_unreadable)) {
            sayShader("cannot read {s} ({t}); keeping the shader now running", .{ path, err });
        }
        return;
    };

    var diags: iface.Diagnostics = .{};
    const pipelines = buildPipelinesFromSource(device, self.buf.source(), &diags) catch {
        if (shader_counters.note(.watch_rejected)) {
            sayShader("{s}; keeping the shader now running", .{diags.message()});
        }
        return;
    };

    if (shader_counters.note(.watch_reloaded)) {
        sayShader("recompiled {d} bytes from {s}", .{ self.buf.len, path });
    }

    noteBindings(self.buf.source(), &shader_counters);
    self.mailbox.publish(pipelines);
}
```

`stamp(path) catch null` rather than `catch return`, so a failed stat reaches `look` as the "learned nothing" case instead of short-circuiting into an untested branch. `run` takes its baseline through `self.watch.baseline(...)`, so nothing outside the module writes `seen`.

`buildPipelines` and `readShader` take the same shape, with `.open_reloaded`, `.open_rejected` and `.open_unreadable`. `shaderStats()` becomes `return shader_counters.stats();` and keeps its `fn () ShaderStats` signature, which `iface.zig:540` pins.

### 3. `noteBindings` takes the tally, which is what makes its bump reachable

`noteBindings` is private and called only from the two live-gated sites, so Zig's lazy analysis leaves it out of a test binary entirely — the `binding_mismatches` increment at `renderer.zig:813` is compiled by nothing that `zig build test` builds, even though `firstBindingMismatch` beneath it has five tests. Giving it a `counters: *reload.Counters` parameter gives it a test caller, using the `replaceOnce` helper already at `renderer.zig:3348` and the same three planted index moves the existing tests use. The pairing "a mismatch found is a mismatch counted" then regresses, with the shipped shader as its negative control.

### 4. `src/main.zig`

One `_ = @import("gpu/metal/reload.zig");` in the collection block beside `gpu/verdict.zig`, with a comment giving _this_ module's reason rather than that one's: it is reached from the plugin only through branches a test build does not compile, so without the line its own tests would not be collected at all. One entry in the `sources` tuple of `"every module a test build compiles carries a declaration sweep"`, which takes it from 22 modules to 23 and leaves the `sources.len == listed + 4` arithmetic unchanged. `build.zig` needs no change: it names only `src/main.zig`, `src/smoke.zig` and the two race roots as roots.

## The tests

In `src/gpu/metal/reload.zig`, written as the plants and each paired with the good input in the same block, on `verdict.zig`'s convention so a function that refused everything would fail too.

**`Watch.look`, five rows plus the two that only a sequence can show.**

- A full mailbox skips and leaves `seen` where it was, which is the lossless rule.
- A failed stat, and an unresolvable path, both leave `seen` where it was.
- The first stamp after a null baseline records without reloading — an editor opening is not an edit.
- An identical stamp is not a change.
- A changed stamp returns `.reload` **and `seen` is already `now`**. This is the acceptance criterion's plant.
- **A broken file is reported once per save, not four times a second.** Two looks with the same changed stamp: the first `.reload`, the second `.idle`. This is the docstring's claim stated behaviourally, and it is the test that fails hardest under the plant.
- A rename-with-identical-size-and-mtime is a change, which is `Stamp.differs`' inode field arriving at its caller.

**The outcome table, all six rows.** `deltas` asserted cell by cell, with the two asymmetries named in their own test: `watch_rejected` moves `rejected` alone while `open_rejected` moves `rejected` and `fallbacks`, and swapping either mapping fails.

**The say-once rule.** `open_unreadable` says the first time and not the second; every other outcome says every time; and a prior `open_rejected` silences the first `open_unreadable`, which is the coupling through `fallbacks` that nothing states today.

**`stats()`.** Each field reads back the atomic behind it. A swapped `reloads`/`rejected` in that constructor is invisible to everything in the repository today and would misreport every `smoke` arm that reads it.

**`binding_mismatches` moves alongside `reloads`, never instead of it**, which is `iface.ShaderStats.binding_mismatches`' stated claim and #77's decision as a type.

In `src/gpu/metal/renderer.zig`: `noteBindings` against a planted moved index moves a local tally by one, and against `shader_source` moves it not at all.

## The canary, for the residue

Which outcome the driver passes at which site is still outside any test binary, so it is counted as text on the existing `noteBindings` canary's precedent (`renderer.zig:4050`). One test asserting each of the six `shader_counters.note(...)` call sites is stated exactly once, bounded by a `mentions(code, "shader_counters.")` count so a seventh site elsewhere fails as loudly as a lost one; the two `noteBindings(...)` strings updated for their new parameter; and one `statedBefore` pinning `note(.watch_reloaded)` ahead of `noteBindings(...)`, which is an ordering `poll`'s own comment argues for and which no count can see.

## Documents

Every one lands with the change, on the program plan's rule that a document updated later describes a state nobody checked.

| Document                                                              | Edit                                                                      |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `docs/adr/0013-gui-smoke-harness-as-a-build-step.md`                  | A `## Amended by issue #93:` section, appended after the #92 one          |
| `AGENTS.md`                                                           | Current state, the `src/` tree, the hot-reload and `#77` bullets          |
| `docs/plans/todo/2026-09-04-close-the-verification-gaps...md`         | Item 5 ticked, with what it did and did not close                         |
| `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md` | The phase 3 status and the unit-test count, re-measured                   |
| `src/gpu/metal/renderer.zig:41-42`                                    | Stale since #77: it claims nothing validates a reloaded shader's bindings |
| `src/gpu/metal/renderer.zig:2648-2649`                                | `readShader`'s "the watcher asks this four times a second"                |
| `src/gpu/iface.zig:628-645`                                           | The zero-counters test's comment narrows, see below                       |

**The ADR amendment must say what the extraction established, not that it exists**, on #92's model. Three things belong in it. That a `shader.live` gate produces _structural uncoverability_ rather than an omission, which is a distinct category from the false negatives the rest of that document catalogues and from #89's false positive. What stays with `smoke-appkit`: which outcome occurs when, the thread, the file, and the device. And that **#77's closure was never recorded here** — the #61 amendment still reads "This one was **not** closed, and is #77", while the arm has existed at `smoke.zig:477` since that issue landed. ADR convention keeps superseded prose standing, so this is a sentence in the new amendment rather than an edit to the old one.

**`iface.zig`'s zero-counters test needs its comment corrected rather than its assertions.** It currently argues that the five atomics are "comptime-unreachable rather than merely unreached" in a test binary. After this, `Counters.note` _is_ compiled there; what stays true, and is now asserted by every test using a local instance, is that no call site reaches the shared one. The narrower claim is the honest one and the test itself is unchanged.

**`renderer.zig:2648-2649` is a factual error, not a stale claim.** `Watcher.poll` never calls `readShader`: it calls `shader.read` directly and resolves its own path. The once-guard only ever suppressed repetition across `init` and `probe`, and this change moves that exact rule, so it is corrected in the commit that moves it.

## Verification

Nothing here needs a Linux host. The GPU steps need a device and the AppKit ones a window server, so the one-stream rule applies to the last two rows.

| Check                                           | What it establishes                                         |
| ----------------------------------------------- | ----------------------------------------------------------- |
| `zig build test`                                | 297 before; the count after is measured, not predicted      |
| `zig build test-safe`, `test-release`           | The new module survives both pinned modes                   |
| `zig build`                                     | The only build that type-checks the live `poll` at all      |
| `zig build smoke-gpu`                           | Six `reloadFallbackArms`, transcript compared line for line |
| `zig build smoke-appkit`                        | **The five hot-reload arms, run rather than inspected**     |
| `zig build smoke-leaks -Dleak-cycles=40`        | Inside the recorded 285-288 leaks / ~18.5 KB baseline       |
| `clap-validator validate zig-out/Fosforo.clap`  | The bundle still loads                                      |
| `zig fmt --check`, `typos`, `markdownlint-cli2` | Clean; `uvx ruff@0.16.5` as a control, expecting 1 file     |

**The plants, one weakening at a time**, and the second pass is the one #92 says this criterion should have asked for: plant the _test_ as well as the code.

| Plant                                        | In             | Must fail                                       |
| -------------------------------------------- | -------------- | ----------------------------------------------- |
| `.reload` returned without writing `seen`    | `reload.zig`   | the advance test **and** the once-per-save test |
| `.reload` returned when `!vacant`            | `reload.zig`   | the lossless-skip test                          |
| A null baseline reloads instead of recording | `reload.zig`   | the editor-opening test                         |
| A failed stat treated as a change            | `reload.zig`   | the stat-failure test                           |
| `watch_rejected` moves `fallbacks` too       | `reload.zig`   | the outcome table                               |
| `open_rejected` moves `rejected` alone       | `reload.zig`   | the outcome table                               |
| `open_unreadable` says every time            | `reload.zig`   | the say-once test                               |
| `stats()` swaps `reloads` and `rejected`     | `reload.zig`   | the stats test                                  |
| `noteBindings` bumps on the shipped shader   | `renderer.zig` | its negative control                            |
| Each new assertion weakened in turn          | both           | its own test                                    |

**One control has to run against the tree as it stands, before anything moves.** Apply the "advance `seen` only on success" plant to today's `poll` and record what `zig build test` and `zig build smoke-appkit` each report. The issue and the program plan both assert that only a hand-run `smoke-appkit` catches it; reading the arms suggests otherwise, because every `waitForReload` is a `>=` comparison that a counter climbing four times a second satisfies trivially, and the arm that would actually fail is `BrokenShaderWasSwappedIn` — which would be reporting a defect it is not named for. **Measure it and record the answer whichever way it goes.** If `smoke-appkit` does catch it under a misleading name, that is a finding of the same shape as #92's `expectClose`: a claim in the issue falsified by running it, and worth writing down rather than quietly working around.

## Commits

Small and at logical boundaries, each carrying `(#93)`.

1. `docs: plan making the shader watcher's bookkeeping testable (#93)`
2. `refactor: move the shader reload bookkeeping into src/gpu/metal/reload.zig (#93)`
3. `test: encode the poll state machine and the outcome table as tests (#93)`
4. `test: cover the binding-mismatch bump by passing the tally in (#93)`
5. `test: canary the note call sites and the mismatch ordering (#93)`
6. `docs: correct two comments the reload paths outgrew (#93)`
7. `docs: record what the watcher's bookkeeping extraction covered (#93)`

## Out of scope

- **`TraceUniforms` layout drift**, which stays open and is named in `noteBindings`' docstring. Seeing it needs a readback of a _reloaded_ shader, which ADR 0013 refuses.
- **A sanitizer arm on the watcher thread.** `Mailbox` carries three Metal object pointers, so racing it would need a device on a Linux host; the canary is what it gets, per ADR 0016.
- **Anything about `Editor.tick` or `Editor.readWindow`**, which is [#98](https://github.com/cboone/fosforo/issues/98) and owns its own seam decision.
- **Changing what `smoke-gpu` or `smoke-appkit` assert.** Both transcripts are compared, and a refactor that moved a number is a refactor that changed the check.
