# Close the eleven cheap assertions

Issue: [#97](https://github.com/cboone/fosforo/issues/97). Type: `test:`. Item 9 of [the verification-gap program](2026-09-04-close-the-verification-gaps-in-the-test-suite.md), which stays in `todo/` until the other ten land.

## Context

A review of the whole verification surface found eleven small, named holes: each pure, each testable in `zig build test`, and none worth its own branch. They are filed as one issue with a checklist because splitting eleven small tests across eleven pull requests is worse than the alternative.

They are not "write more tests". Each is a specific declaration whose current coverage is **zero or partial in a way that reads as covered**: a switch whose only caller returns early in a test build, a positive clamp tested at four levels beside an untested negative one, a header test that re-derives its expectation from the same constant the writer used. Nine of the eleven are one test each; two are two.

Nothing here needs a device, a window server, or a host. All fourteen new tests sit in the free lane the program plan's table puts `zig build test` in, so this runs beside phase 3's issue work.

## Three decisions, settled before writing anything

**The `clap_host_t` fixture is shared rather than copied.** `gui.zig` has no host fixture at all today, and it cannot reach `plugin.test_host` because `plugin.zig` imports `gui.zig`. The repository already has an answer for a test fixture two files need: `state.TestStream` is `pub`, lives below the tests banner, and carries a docstring naming who shares it and why. `log.testHost` (`log.zig:180`) becomes `pub` the same way. **The line is drawn at the struct literal:** an eleven-field `clap_host_t` written out twice can drift, which is the argument `plugin.zig:959-966` already makes; a responder function that returns null unconditionally cannot, so those stay local to `gui.zig`.

**The state header is pinned as literal bytes.** `save` writes `magic` and then a `writeInt` through `const endian`, and the existing test reads it back through `readInt` with the same constant, so flipping `endian` passes all ten tests in the file. The expectation becomes `{ 'F', 'S', 'F', 'R', 1, 0, 0, 0 }` outright. That means a `version` bump must edit the test, and **that is the point rather than a cost**: the version moves "only when an existing field changes meaning or disappears" (`state.zig:29`), which is a flag day that should force someone to look at a literal byte array on purpose. `src/clap/c.zig:69` is the precedent for a literal that must be edited deliberately.

**The negative rail is asserted by restating the row, not by a new helper.** `railRow` is `pub` and has a caller outside the tests (`smoke.zig:1230`, in `checkRail`); a `railRowBelow` sibling would be a `pub fn` whose only reader is one test in its own file, which is the shape [#95](https://github.com/cboone/fosforo/issues/95) is open about. The negative rail row is written as a `const` inside the test, derived from `iface.trace_rail` exactly the way `railRow` derives the positive one. That restatement is **bit-exact**: `1.0 - (-x)` and `1.0 + x` are the same operation on the same bits, verified equal at every height from 2 to 4096, so it takes `expectEqual` with no tolerance and mirrors the positive test line for line. The symmetry property is asserted too, but with `expectApproxEqAbs`, because `expectedRow(-x, h) + expectedRow(x, h) == h - 1` is **false in f32 at h = 5 and h = 65** while holding at every height the editor permits — an exact equality there would be a test of float rounding rather than of the clamp, which is the trap the existing positive test's own comment names.

## The eleven rows

Fourteen tests. Implementation order follows the issue: `severityName` first, because it is the only row whose current coverage is zero rather than partial and a wrong string there is invisible in every build that could show it. The rest are independent.

### 1. `log.severityName`, all eight arms — `src/clap/log.zig`

After `"a host without the extension is survivable"`. One test, `"every severity the header defines has its own name, and anything else is unknown"`: the seven `c.CLAP_LOG_*` arms against their strings, plus `severityName(7)` and `severityName(-1)` against `"unknown"`. Seven is the next value a CLAP bump would define, so the `else` arm is what stops a newer host's severity printing as a `debug` line.

**Use `expectEqualStrings`, never `expectEqual`.** `std.testing.expectEqual` on a slice compares `.ptr` and `.len` and nothing else (`std/testing.zig:129-140`, read rather than recalled), so an `expectEqual("debug", …)` would pass or fail on string interning. This is the one row where the house's default assertion is the wrong one.

Plant: swap two arms' strings, `CLAP_LOG_ERROR => "fatal"`.

Prose: `mirror`'s docstring (`log.zig:105-107`) says "this function has no automated coverage". Still true of `mirror`; it gains a clause saying the names it formats now have some.

### 2. `HostGui.init`, three host shapes and the control — `src/clap/gui.zig`

After `const test_host_gui` (`gui.zig:1301`), beside the fixtures they use. `pub` on `log.testHost`, and `const testHost = log_mod.testHost;` in `gui.zig`'s test section.

Two tests. `"the host's gui extension is found through init rather than assembled by hand"` is the control and closes a gap of its own: `TestHostGui` and `test_host_gui` build a `HostGui` by hand and bypass `init` entirely, so **nothing has ever run `init`'s success path**. It asserts `ext == &TestHostGui.ext`, `host` set, and `requestResize` reaching the fixture and moving `TestHostGui.calls` to 1. `"a host without the gui extension is survivable"` is a deliberate echo of `log.zig:222`, over `inline for (.{ null, getNothing, getEmptyGuiExtension })`, asserting `ext == null` **and** that `requestResize` returns false, so the survivability claim is stated as what a caller sees.

Order the loop body so the field check runs before the behaviour check, or the `.?` on a null vtable panics first.

Plants: `&c.CLAP_EXT_GUI` to `&c.CLAP_EXT_LOG`; and delete the `if (ext.request_resize == null)` guard.

### 3. `expectedRow`'s negative rail clamp — `src/gpu/measure.zig`

Immediately after `"every level at or above the rail lands on one row"`. One test, `"the rail below the centre line clamps as tightly as the one above it"`, mirroring the positive test at h = 540 against a test-local `rail_below`:

- `expectEqual(rail_below, expectedRow(under, height))` for `-1.111, -2.0, -8.0, -1000.0`.
- The threshold from just below, `expectedRow(-threshold * 1.001, height)`.
- The direction that keeps it non-vacuous: `expectedRow(-1.0, height) < rail_below - 1.0`.
- The symmetry, `expectApproxEqAbs`, with the h = 5 and h = 65 counterexamples in the comment as the reason it is not an equality.

Plant: `-iface.trace_rail` to `-iface.trace_full_scale` in the clamp, which moves the row from 534.0999755859375 to 512.5.

### 4. `displaylink.monotonicNanos` — `src/platform/displaylink.zig`

The file's first named test, after the existing "No test creates a display link" comment. `"the render clock advances rather than repeating, and never runs backwards"`: a thousand readings, each `>=` the last; the first `> 0`; the last `>` the first; and the whole loop under one second.

The strict-advance assertion is what makes this worth its lines and it is safe by three orders of magnitude — the timebase is 24 MHz, about 41.67 ns a tick, against a loop of tens of microseconds. It catches the realistic defect for a clock feeding a 158 ms time constant, which is a units mistake. The one-second bound catches the other direction, a `* 1000` scale error that **nothing else in this project would see**, since `palette.decayOver` takes `dt` as a parameter and would agree with a wrong clock. Measure the loop during implementation and quote the figure in the comment, in this file's style.

It cannot prove the unit is nanoseconds, or that this is the clock that stops while the machine sleeps. Both are properties of the declaration and are already argued in the docstring.

Plants: `return 0;`; `/ 1_000_000`; `* 1000`.

### 5. `plugin.bit()`'s `channel >= 64` arm — `src/clap/plugin.zig`

Before `"process propagates the input's constant mask"`. One test, `"a channel past the mask's width gets no bit rather than a wrong one"`: `bit(0)`, `bit(63)`, and zero for `bit(64)`, `bit(65)` and `bit(maxInt(u32))`. `constant_mask` is 64 bits wide and CLAP puts no ceiling on `channel_count`, so this is the arm that exists for a host `TestBuses` cannot express, being two channels by construction.

Plant: `else 0` to `else 1`.

### 6. `getExtension(null)` — `src/clap/plugin.zig`

After `"get_extension answers for what is implemented and nothing else"`. One test, `"get_extension refuses a null id rather than reading through it"`, driving the vtable the way a host would. The parameter is `[*c]const u8`, so null is a value a host can pass and the ABI cannot refuse.

Plant: in the null branch, `return null` to `return &audio_ports`.

### 7. `audioPortsGet(..., null)` — `src/clap/plugin.zig`

After `"audio_ports.get rejects an index that does not exist"`. One test, `"audio_ports.get refuses a null out-parameter rather than writing through it"`, deliberately parallel to the existing `"the gui callbacks refuse null out-parameters rather than writing through them"` (`plugin.zig:1498`). Both `is_input` values, plus `index = 1` with a null `info`, so the two halves of the guard stay distinguishable.

Plant: split the guard into `if (index != 0) return false; if (info == null) return true;`.

### 8. The state header's literal wire bytes — `src/clap/state.zig`

After `"save writes the header and load accepts it"`. Two tests, and the pair is the point.

`"save writes the eight bytes the format documents rather than whatever endian names"` compares `stream.written()` against `{ 'F', 'S', 'F', 'R', 1, 0, 0, 0 }`, with a comment saying a version bump must edit that line, plus `expectEqual(@as(usize, 8), header_size)`.

`"a big-endian header is a version from the future rather than version one"` seeds `{ 'F', 'S', 'F', 'R', 0, 0, 0, 1 }` by hand — **not** through `makeHeader`, which shares `endian` and so cannot express this — and requires `error.UnsupportedVersion`, since big-endian 1 reads little-endian as 16,777,216. That proves `load` reads little-endian without going through `save`.

Plant: `const endian` to `.big`. Both new tests fail and all ten existing ones still pass, which is this row's whole argument and should be recorded as a measured result rather than a prediction. The existing weak assertion at `state.zig:223` stays, with a one-line comment pointing at the new pin, so it is labelled rather than deleted.

### 9. `ramp` and `sine` at lengths 0 and 1 — `src/gpu/measure.zig`

Beside the existing tests for each. Two tests, split by length rather than by function, because the property is about the window and not the generator: `"a one-sample window holds the value it starts at rather than a nan"` and `"an empty window is left alone rather than read past"`.

Both back the slice with a sentinel-filled `[4]f32` and pass `window[0..1]` or `window[0..0]`, asserting `ramp` writes `from` exactly, `sine` writes `0.0`, and that the slots past the slice still hold the sentinel — so each test says "one slot, not the buffer" as well as "the right value".

Plants: remove `if (out.len == 1)` from `ramp`, and `if (out.len < 2)` from `sine`. Both take `t` or `phase` through a zero span to NaN.

### 10. `iface.ShaderStats` all-zero in a test build — `src/gpu/iface.zig`

End of the test section. One test, `"the shader counters read zero in a build that has no watcher"`, asserting the two statements of the invariant against each other: `expectEqual(ShaderStats{}, Renderer.shaderStats())` **and** the five fields explicitly. Either alone is weak; together they catch a changed field default, where `.{}` and the atomic disagree, and a seeded atomic, where both fail.

Ordering-safe, and provably: every writer of the five atomics is comptime-unreachable in a test build, because each sits behind `shader.live`, which folds in `!builtin.is_test`. Zig runs a test binary single-threaded and in order and nothing here constructs a `Renderer`. The comment says that as the alarm rather than the caveat — a future test that started a watcher would break this one, and that is the correct outcome.

**The limitation goes in the test's own comment.** Dropping `!builtin.is_test` from `shader.live` does _not_ fail this test, because nothing in a test binary would then start a watcher either. That plant belongs to `shader.zig:276`'s existing test. Without the comment the next reader will believe this row closes the gate.

`Renderer.shaderStats` is a static read of five atomics and acquires no device, so the section comment at `iface.zig:556` stays true; it gains a clause saying so.

Plants: `reloads: u64 = 1` as a field default; `.init(1)` on `shader_reloads`.

### 11. `objc.autoresizing`'s two constants — `src/platform/objc.zig`

After `"a default-constructed rect is the zero rect"`. One test carrying `c.zig:69`'s name, `"restated autoresizing masks are pinned against a careless edit"`, with the same kind of disclaimer above it: AppKit's header is Objective-C, nothing here can read it, so this restates the literals a second time and catches a one-sided edit rather than proving agreement.

Three assertions: 2, 16, and 18 for the OR, which is the value `view.zig:80-82` actually sends and the only one with an observable effect. The two constants are asserted separately as well as together **because the OR alone cannot see them swapped**, which is worth recording as the negative control.

Plant: transpose 16 to 61.

## Plants that do something other than fail

The acceptance criterion is a planted defect per row, and eight of them do something other than fail an assertion. A panic aborts the whole test binary, so those are verified one at a time and the remaining rows re-run after reverting.

| Row | Site               | What the obvious plant does instead                                                                                                 |
| --- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `log.severityName` | Deleting the `else` arm is a **compile error**: a switch over `int32_t` must be exhaustive, so the compiler already holds that half |
| 2   | `HostGui.init`     | Deleting the `get_extension orelse` guard **panics** on the `.?` rather than failing an assertion                                   |
| 3   | `expectedRow`      | The dropped-minus plant is **already caught** by the positive test; inverting the bounds panics inside `std.math.clamp`'s assert    |
| 5   | `plugin.bit`       | `channel <= 64` **panics** on `@intCast(64)` into the `u6` shift amount rather than returning a wrong mask                          |
| 6   | `getExtension`     | Deleting the null guard **panics** inside `std.mem.len`'s own assert                                                                |
| 7   | `audioPortsGet`    | Deleting `or info == null` writes through a null C pointer: a panic in Debug, a corrupted host in `--release=fast`                  |
| 9   | `ramp` and `sine`  | The length-0 plants panic on `out.len - 1`; and `ramp(&[_]f32{}, …)` **does not compile**, since `*const [0]f32` is not a `[]f32`   |
| 10  | `ShaderStats`      | Dropping `!builtin.is_test` **does not fail this test at all**; that plant belongs to `shader.zig:276`                              |

Rows 3 and 10 are the two that matter most, for opposite reasons: one plant is already covered elsewhere and would report a false success, and the other is covered by nothing here and would report a false success too.

## Documents

**The build plan**, [`2026-07-25-repo-foundation-and-phased-build-plan.md`](2026-07-25-repo-foundation-and-phased-build-plan.md), in one commit:

- Line 429, #97's status, `Open` to `Done`.
- Line 422, **#90's status, also `Open` and also wrong**. It landed at `dc2b2ae` through `0b67da5` and is a non-negotiable in `AGENTS.md`. A status table that lies about a neighbouring row while this row is being edited is the stale-claim class #89's sweep was about.
- Line 491, the test count. It reads 205; the tree holds **224** today and this adds **14**, so it becomes 238. The commit message says the figure is corrected as well as advanced, since it was stale by nineteen before this issue touched it.

**`AGENTS.md`**, one clause: the hand-restated Metal and AppKit constants bullet says "there is no surviving header symbol to test them against", which is still true, but the two `NSView.autoresizingMask` values now have a pin on `c.zig`'s precedent.

**Not touched.** No CHANGELOG entry and no ADR, on #90's precedent: that was a larger test-only change and touched neither. Nothing here decides anything and no new rule is created. The program plan tracks eleven issues and moves to `done/` as a whole, so it is not edited either.

## Verification

`zig build test` is the only resource this needs. Baseline it green before anything else, then per row: plant, run, confirm the **named** test is the one that fails (or that it panics or refuses to compile, and record which), revert, run green.

**Commit each test before planting against it**, so `git restore` reverts the plant and not the check it was testing.

**Plant the checker as well as the code.** A test named for a defect does not necessarily catch it: after each row's production plant passes, weaken that test's own assertions one at a time and confirm the weakened test stops failing. That is what separates "the test fires" from "something in the file fires", and rows 3 and 10 above are the two where the distinction has already been shown to bite.

Then `zig fmt --check build.zig src/` before each commit, and `markdownlint-cli2` in check mode only for the plan and the build plan — never `--fix`, which ignores its file argument and rewrites every Markdown file in the tree. `typos` over the whole tree at the end.

## Commits

1. `test: name every severity the host can send (#97)`
2. `test: survive the three host shapes clap.gui can arrive in (#97)` — carries the fixture reasoning: the host literal is shared because it can drift, the responders are local because they cannot.
3. `test: clamp the rail below the centre line as tightly as the one above (#97)`
4. `test: reach the degenerate arms of ramp and sine (#97)`
5. `test: assert the render clock advances and never runs backwards (#97)`
6. `test: cover the channel with no bit in the constant mask (#97)`
7. `test: refuse a null extension id and a null port info (#97)`
8. `test: pin the state header's wire bytes on both sides (#97)`
9. `test: assert the shader counters read zero without a watcher (#97)`
10. `test: pin the restated autoresizing masks (#97)`
11. `docs: record the eleven cheap assertions and refresh the test count (#97)`

One plant per commit is the value of this issue, which is why 3 and 4, and 6 and 7, stay split despite touching one file each. At merge a twelfth commit moves this plan to `docs/plans/done/`, on `0b67da5`'s precedent, and the sibling link becomes `../todo/…`.

## What this does not close

Every one of these is a test of a pure function or a small guard, so each proves what its own name says and nothing more. Three residues worth stating rather than leaving to be rediscovered:

- **`mirror` still has no coverage.** Row 1 covers the table it formats, not the function, and the reason it cannot be covered — a test binary's `stderr` is the runner's stream — is in its docstring and is not a gap this issue can close.
- **The `TraceUniforms` layout is still readable from nowhere**, which is [#77](https://github.com/cboone/fosforo/issues/77)'s residue rather than this issue's, and row 10 does not touch it.
- **A hot-reloaded shader's counters are still exercised only by `smoke-gpu`.** Row 10 asserts they are zero where there is no watcher; what a live watcher does to them is `src/smoke.zig`'s, and making that reachable from a test build is [#93](https://github.com/cboone/fosforo/issues/93).
