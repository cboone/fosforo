# Analyze every public declaration, and settle the one with no caller

Issue: [#95](https://github.com/cboone/fosforo/issues/95). Type: `test:`. Item 7 of [the verification-gap program](../todo/2026-09-04-close-the-verification-gaps-in-the-test-suite.md), which stays in `todo/` until the other nine land. The branch is named `refactor/ref-all-decls`; the commits carry `test:`, on the issue's own classification.

## Context

Zig analyses lazily per declaration, so a `pub fn` nothing reaches is never type-checked however the file it lives in was imported. `AGENTS.md` records that as a gotcha and records `Ring.read` and `Ring.capacity` as its worked example. The class is still open and there is one live instance.

A scan of every `pub`, `fn` and `const` in `src/` against `src`, `scripts`, `shaders` and `build.zig` returns exactly one declaration with no reference anywhere: `palette.dominantToTonemapped` (`src/gpu/palette.zig:497`). It is not junk. It is the published inverse of the dominant channel's affine readout, mirrored line for line by `tonemapped_from_dominant` in `scripts/measure-trace:200`, so it is part of the display contract with no caller, no test, and no build of any kind that type-checks it. A second-order case sits beside it: `plugin.editorOf` (`src/clap/plugin.zig:147`) is reached only from `src/smoke.zig`, whose root is its own executable, so `zig build test` does not analyse it either.

The intended outcome is that neither declaration, nor any future one of the same shape, can be wrong without a check saying so.

## What exploration changed about the issue as filed

Five findings, and three of them change the work rather than confirm it.

**`refAllDecls` is not recursive, and `refAllDeclsRecursive` was removed in Zig 0.16.** `std.testing.refAllDecls` (`std/testing.zig:1213`) walks `std.meta.declarations(T)`, which returns a container's **public** declarations, one level deep. So `refAllDecls(@This())` in `src/dsp/ring.zig` references the type `Ring` and does **not** analyse `Ring.read` or `Ring.capacity`, which is precisely the pair the `AGENTS.md` bullet is about. The three sites that already do this correctly each add a second call for their principal type (`renderer.zig:3169-3170`, `displaylink.zig:223-224`, `view.zig:359-360`); three more are incomplete under the same rule. **So this is a rule to apply uniformly, not a line to paste thirteen times**, and applying it only to the files that have nothing today would leave the class open in the files that already look covered.

**Thirteen files lack it, not ten.** The issue's list of ten predates [#90](https://github.com/cboone/fosforo/issues/90), which created `src/canary.zig` and gave `src/platform/io.zig` its first test section. `src/ring_race.zig` is the third it does not name. `src/smoke.zig` is the twentieth file and is deliberately excluded: `zig build test` never compiles a line of it, so a `refAllDecls` there would be inert. [#92](https://github.com/cboone/fosforo/issues/92) owns that file.

**The acceptance criterion "the test count moves by zero" is wrong, and the reason it is wrong is the mechanism.** `refAllDecls` collects no tests of its own, which is what the criterion means and which stays true. But the repository's idiom wraps it in an unnamed `test { }` block, and an unnamed test block **is** a test: `src/main.zig` reports two tests today and one of them is that block. The count rises by exactly the number of new blocks and by nothing else, which is a stronger statement than the one filed and is measured rather than assumed.

**Both named instances are top-level, so both plants land.** `dominantToTonemapped` is a file-scope `pub fn` and so is `editorOf`. Had either been a method of a file-scope struct, `refAllDecls(@This())` alone would not have reached it and both acceptance criteria would have passed vacuously. That near miss is the argument for the depth rule above, restated as a fact rather than a preference.

**`src/gpu/palette.zig` is not in `src/main.zig`'s collection list at all.** Its 15 tests are collected only because `Renderer`'s method bodies reference it, which the issue notes. The set of modules a test build compiles is therefore not the set `main.zig` names, and the enforcement check below has to account for the difference explicitly rather than assume the two lists agree.

## Design

### The rule

In every module `zig build test` compiles, the test section opens with an unnamed block holding `testing.refAllDecls(@This());` plus one `testing.refAllDecls(T);` for **every public container type declared at file scope**, with no exception for a type that has no declarations today. The no-op calls are deliberate: a rule reading "types that currently have methods" reopens the hole the moment somebody adds a method to `Size`.

This is the existing idiom at `renderer.zig:3160`, `view.zig:355` and `objc.zig:109` generalised, comment included. Error sets are excluded, because `std.meta.declarations` raises a compile error on anything that is not a struct, enum, union or opaque; `iface.Error` is the one such declaration here.

### The sites

Thirteen files gain a test block; three gain the calls their block is missing. Every path is under `src/`.

| File                   | Block   | Types referenced beside `@This()`                           |
| ---------------------- | ------- | ----------------------------------------------------------- |
| `build_info.zig`       | new     | none                                                        |
| `canary.zig`           | new     | none                                                        |
| `clap/c.zig`           | new     | `feature`                                                   |
| `clap/gui.zig`         | new     | `Pending`, `HostGui`, `Editor`                              |
| `clap/log.zig`         | new     | `Log`                                                       |
| `clap/plugin.zig`      | new     | none                                                        |
| `clap/state.zig`       | new     | `TestStream`                                                |
| `dsp/ring.zig`         | new     | `Ring`                                                      |
| `gpu/iface.zig`        | new     | `Size`, `Outcome`, `Diagnostics`, `Readback`, `ShaderStats` |
| `gpu/measure.zig`      | new     | `Image`, `Extremes`, `Centres`, `Span`, `Point`             |
| `gpu/palette.zig`      | new     | `Palette`                                                   |
| `platform/io.zig`      | new     | none                                                        |
| `ring_race.zig`        | new     | none                                                        |
| `gpu/metal/shader.zig` | present | `Stamp`, `Buffer` added                                     |
| `platform/objc.zig`    | present | `CGPoint`, `CGSize`, `CGRect`, `autoresizing` added         |
| `platform/view.zig`    | present | `Delegate` added beside the existing `View`                 |

`main.zig`, `gpu/metal/renderer.zig` and `platform/displaylink.zig` are already complete under the rule and are not touched by the sweep.

Two files have no `// Tests` banner and they resolve differently, which is a correction to this plan made while writing it. `build_info.zig` gains one, because its tests are the end of the file; its alias stays in the import block, since moving it would be churn and the banner is what `canary.implementation` needs. **`clap/c.zig` deliberately gains none.** Its comptime layout block sits _after_ its three tests, so a banner there would tell `canary.implementation` to cut above real implementation code, which is a trap laid for whoever canaries that file next. Its block is spelled `std.testing.refAllDecls`, matching the file's own fully-qualified style, since it has no alias either.

`src/ring_race.zig` was the one entry that could have surfaced something: its `pub fn main` had never been analysed in a macOS test binary, only compiled for the Linux target the harness runs on. It compiles.

### Keeping the class closed

The sweep closes the class as of today and nothing stops the twentieth module from arriving without the line. One test in `src/main.zig`, beside the collection list it depends on, closes that:

```zig
test "every module a test build compiles references all its declarations" {
    // Two lists that have to agree. `sources` is what this test reads; the block
    // above is what decides which modules a test build compiles at all. The count
    // below is what ties them, so adding one without the other fails here rather
    // than silently narrowing what the sweep covers.
    const sources = .{
        .{ "main.zig", @embedFile("main.zig") },
        // ...eighteen more
    };

    // Split so this line is not itself a match. The needle would otherwise appear
    // verbatim in this file's own source and count as a second statement, which is
    // the hazard `canary.implementation` exists for and which cannot be used here:
    // `main.zig` has no tests banner to cut at.
    const needle = "refAllDecls(" ++ "@This());";
    inline for (sources) |entry| {
        errdefer std.debug.print("no declaration sweep in {s}\n", .{entry[0]});
        try std.testing.expectEqual(1, canary.mentions(entry[1], needle));
    }
}
```

Then the tie, in the same test:

```zig
    // `sources` holds four entries the list above does not name: this file, the
    // two it imports at file scope, and `gpu/palette.zig`, whose tests are
    // collected only because `Renderer`'s method bodies reference it.
    const listed = canary.mentions(@embedFile("main.zig"), "_ = @imp" ++ "ort(\"");
    try std.testing.expectEqual(sources.len, listed + 4);
```

Nineteen entries: every `.zig` file under `src/` except `smoke.zig`. `canary.mentions` is what makes this assertable rather than decorative, because it does not count comment lines: `smoke.zig:5` names `testing.refAllDecls` in a doc comment, and a file that documented the convention instead of following it would satisfy a naive `indexOf`.

The second needle is split for the same reason as the first. Both splits are ugly and both are the honest form; the alternative is an assertion that counts its own string literals.

**What this check cannot do** is see a module added to neither list. That is the property `main.zig`'s collection list already has, where the cost is silently collecting no tests, and it is recorded rather than fixed.

### Out of scope, and why

`dominantToTonemapped` gets no test here. [#96](https://github.com/cboone/fosforo/issues/96) claims it explicitly ("Fold in the `dominantToTonemapped` inverse property here rather than in the `refAllDecls` issue"), it is the same file and the same claim as that issue's `tonemap` and `whitePoint` work, and both of this issue's acceptance plants are satisfied by the sweep alone. Splitting it costs one rebase and buys two branches that do not both edit `palette.zig`'s test section.

## Documents

**`AGENTS.md`, the lazy-analysis bullet at line 352.** The program plan predicts this change "retires a documented gotcha's example". It retires half of it, and the half it leaves standing is the one the bullet actually measures:

- **The plain `zig build` half is unchanged.** `refAllDecls` opens with `if (!builtin.is_test) return;`, so a type error planted in `Ring.capacity` still builds clean outside a test build, exactly as the bullet records. Nothing about the shipped analysis moves.
- **The `zig build test` half changes.** Every public declaration of every collected module, file-scope and one level of public container type, is now analysed, so a `pub fn` with no caller fails `Test` where it used to pass everything.
- **The residue is named:** private declarations, and containers nested more than one level deep, are still lazy in both builds, because `std.meta.declarations` returns public declarations only and `refAllDeclsRecursive` no longer exists.

The bullet gains those three sentences and keeps its measurements, because they are still true.

**The build plan** ([`2026-07-25-repo-foundation-and-phased-build-plan.md`](../todo/2026-07-25-repo-foundation-and-phased-build-plan.md)), the verification-program table at line 427: #95's status goes to `Done`. #90's row in the same table still reads `Open` against a closed and merged issue; that is a one-word drive-by fixed here rather than left, and it is called out in the PR body so it is not mistaken for scope.

**The program plan is not edited.** It tracks eleven issues and moves to `done/` as a whole, which is the precedent [#90's plan](2026-09-04-canary-the-orderings-a-single-threaded-suite-cannot-see.md) set. Its line 434 prediction about `AGENTS.md` is corrected in `AGENTS.md` and recorded above rather than rewritten there.

**No ADR changes.** The program plan assigns none to this issue, and nothing here supersedes a settled decision.

## Verification

`zig build test` is the only resource this needs, so it runs beside anything in phase 3 (the build plan's free lane).

**Commit the sweep before planting against it**, so `git restore` reverts the plant and not the check it was testing.

### Measurements

**All green.**

- `zig build test --summary all`: **230 before, 243 after the sweep, 244 with the enforcement check**. The thirteen is exactly the thirteen new blocks and nothing else, which is what the "moves by zero" criterion should have said; the three backfills added no block and moved nothing. A larger rise would have meant a module's tests were being collected twice, and none was.
- `zig fmt --check build.zig src/` clean.
- `markdownlint-cli2` in check mode only. Never `--fix`, which ignores its file argument and rewrites every Markdown file in the tree, completed plans included.

The shipped binary cannot change and this is an argument rather than a measurement: every added line is inside a `test` block, which Zig analyses only in a test build, which is the same reason `src/canary.zig`'s docstring gives for costing the shipped binary nothing. There is consequently no `--release=fast` control worth running, and a byte comparison would be meaningless anyway, since `build.zig` stamps the commit into every binary.

### Plants

Each was made, run, and reverted, with the sweep committed first so `git restore` reverted the plant and not the check. **The result column is what happened, not what was expected.**

| Plant                                                      | Command          | Result                                                        |
| ---------------------------------------------------------- | ---------------- | ------------------------------------------------------------- |
| A type error in `palette.dominantToTonemapped`             | `zig build test` | **Fails** at `palette.zig:500`                                |
| The same plant, with `palette.zig`'s sweep removed         | `zig build test` | **243/243 pass.** The before state, measured                  |
| The same plant                                             | `zig build`      | **Exit 0, signed bundle.** The plain build is unchanged       |
| A type error in `plugin.editorOf`                          | `zig build test` | **Fails** at `plugin.zig:148`                                 |
| A type error in a `pub fn` on `Ring` that nothing calls    | `zig build test` | **Fails** at `ring.zig:72`                                    |
| The same, made **private**                                 | `zig build test` | **244/244 pass.** The residue                                 |
| `refAllDecls(@This());` deleted from `platform/io.zig`     | `zig build test` | **Fails**: `src/platform/io.zig carries no declaration sweep` |
| `_ = @import("gpu/palette.zig");` added to the import list | `zig build test` | **Fails**: `expected 19, found 20`                            |

**Three rows are controls where passing is the result**, and each is what keeps a sentence honest rather than a description of one.

Row two is the strongest of them: it is the same plant with only the new block removed, so "no build compiled this declaration" is measured against this branch rather than inherited from the issue's scan. Row three keeps the `AGENTS.md` bullet's plain-`zig build` half true, which the program plan predicted would be retired and which is not. Row six is the depth rule's own limit: `std.meta.declarations` returns public declarations only, so the identical defect one keyword away is still invisible.

Row five is the one that justifies the depth decision. `refAllDecls(@This())` alone would not have caught it, and both declarations this issue was filed about happen to be file-scope functions, so the acceptance criteria as filed could have been met by a sweep that left the larger half of the class open.

## What this does not close

- **`refAllDecls` proves a declaration compiles, not that it is correct.** `dominantToTonemapped` will type-check and stay unasserted until #96, and the executable link between it and `scripts/measure-trace`'s `tonemapped_from_dominant` is that issue's to make.
- **Private declarations and deeply nested containers stay lazy.** `Gate` in `src/clap/gui.zig:904` is private, so nothing here reaches its declarations directly; they are analysed because `Editor` calls them, which is the ordinary case and is what [#90](https://github.com/cboone/fosforo/issues/90)'s canary and [#91](https://github.com/cboone/fosforo/issues/91)'s sanitizer arm cover on their own terms.
- **Plain `zig build` is unchanged**, deliberately. Forcing the release path to analyse declarations nothing reaches would be putting test machinery in the shipped binary to buy an earlier error message.
- **`src/smoke.zig` is still outside the test graph entirely**, so its 2,181 lines gain nothing here. [#92](https://github.com/cboone/fosforo/issues/92) owns it.
- **The enforcement check's list is hand-maintained**, tied to `main.zig`'s by a count. A module added to neither is checked by nothing, which is the property that list already has.

## Commits

1. `test: reference every public declaration in the thirteen modules with no sweep (#95)`
2. `test: complete the sweep in the three modules that had a partial one (#95)`
3. `test: refuse a module that arrives without a declaration sweep (#95)`
4. `docs: record which half of the lazy-analysis gotcha the sweep retires (#95)`
