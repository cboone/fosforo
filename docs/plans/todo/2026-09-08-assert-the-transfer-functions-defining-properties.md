# Assert the transfer function's defining properties

Issue: [#96](https://github.com/cboone/fosforo/issues/96). Type: `test:`. Item 8 of [the verification-gap program](2026-09-04-close-the-verification-gaps-in-the-test-suite.md), which stays in `todo/` until the other items land.

## Context

[ADR 0019](../../adr/0019-brightness-is-a-fixed-transfer-function.md) fixes brightness as a function of accumulated energy alone. Two of the functions carrying that claim state their defining properties in prose and assert none of them.

`src/gpu/palette.zig` has fifteen good tests: the sRGB round trip, the knee, the gradients, monotonicity, and the decay's anchor, clamp and composition. Three declarations are reached only incidentally.

- **`tonemap` (`palette.zig:472`)** claims to be "equal to exactly one at `white` rather than approaching one asymptotically", which is the whole reason extended Reinhard was chosen over plain Reinhard. Its only two calls are inside a test about the decay clamp (`palette.zig:826-830`).
- **`whitePoint` (`palette.zig:427`)** is never called with either of the values its docstring argues about: the `8e5` clamp the `@max` exists for, and the zero-decay end where everything above one deposit blows out white.
- **`dominantToTonemapped` (`palette.zig:497`)** has been *analyzed* since [#95](https://github.com/cboone/fosforo/issues/95) added the declaration sweep, and is still asserted by nothing. It is the published inverse `scripts/measure-trace` mirrors in `tonemapped_from_dominant`.

`resolved` at zero energy must reproduce `background_bytes`, which `verdict.resolve` asserts against the running shader as `BackgroundNotThePaletteAtZero` (`verdict.zig:723-727`) and nothing asserts against the model.

## What planting first changed about this plan

The issue predicts that a white point wrong by a factor of ten is the plant that closes something genuinely uncovered, quoting [`2026-08-30-tonemap-accumulated-energy-through-a-palette.md`](../done/2026-08-30-tonemap-accumulated-energy-through-a-palette.md): "arithmetically correct and passes a model-versus-picture comparison, because both sides use it." **That was true when it was written and is now only half true**, because [#56](https://github.com/cboone/fosforo/issues/56) added `"the white point holds a deposit's brightness steady across refresh rates"` (`palette.zig:833`), whose steady-state half requires byte 255 at `1 / (1 - decay)`. Worked through: `white_headroom = 8.0` puts the 60 Hz white point at 80 and sends a dwelt pixel to `tonemap(10, 80)`, which is 0.9106 and resolves to green 243 rather than 255. **That existing test fires.** So the headroom plant is a control here, not the closing row.

**The genuinely uncovered constant is the clamp's `1e-6`.** Nothing calls `whitePoint` at a decay of one, so moving that epsilon by a factor of ten fails nothing at all today — and it is restated in three languages with no pin on any copy:

| Copy                        | Spelling                  | Pinned by |
| --------------------------- | ------------------------- | --------- |
| `src/gpu/palette.zig:449`   | `@max(1.0 - decay, 1e-6)` | nothing   |
| `shaders/scope.metal:155`   | `max(1.0 - decay, 1e-6)`  | nothing   |
| `scripts/measure-trace:221` | `max(1.0 - decay, 1e-6)`  | nothing   |

`renderer.zig`'s two constants tests already pin `WHITE_HEADROOM` in the script (`renderer.zig:3533`) and `white_headroom` in the shader (`renderer.zig:3587`). The epsilon is the one ingredient of the white point they do not reach, and it is the one the `8e5` figure is made of.

## Three decisions, settled before writing anything

**`tonemap(w, w) == 1.0` is asserted to `1e-6` and to the byte, not with `expectEqual`.** Measured in `f32` rather than assumed: the identity is bit-exact at `w = 0.8`, `3.5` and `8.0`, and reads **0.9999999** at the shipped 60 Hz white point of 7.999998 and **0.99999994** at the `8e5` clamp. That is the same trap `palette.zig:550-557` already names from the other end for `srgbEncode(1.0)`, and its answer is the one to copy: assert the float approximately, and assert the byte exactly, because the byte is what the display shows.

**The clamp is pinned as the literal `8e5`, not as `white_headroom / min_dwell`.** Deriving it from the two constants would be a restatement that moves with them, which is exactly the failure the section above describes. `8e5` is the figure `palette.zig:341`, `palette.zig:430` and `AGENTS.md`'s phosphor-fade bullet all quote, so pinning it makes a change to either constant move a number a reader can already find. It is the single assertion that catches a factor of ten in the headroom *or* in the epsilon.

**The dwell floor becomes a named constant, because a pin needs a name to anchor on.** `scalarAfter` (`renderer.zig:3391`) matches `"NAME = "` and reads the number after it, so an inline `1e-6` inside a `max(...)` call is unreachable by the existing readers. `palette.min_dwell` is added, the MSL gains `constant float min_dwell`, the script gains `MIN_DWELL`, and both constants tests grow one row. Its charset already accepts `eE` and `+-`, so `1e-6` parses with no change to the reader (`renderer.zig:3395`).

## The five tests

All in `src/gpu/palette.zig`, taking it from 15 named tests to 20. Nothing here needs a device, a window server or a host, so it runs in the program plan's free lane.

### 1. The tonemap's defining property

`test "the tonemap reaches one exactly at the white point rather than approaching it"`, placed after `"an interval longer than a refresh is not believed"` (`:817`), which is where the two incidental calls already live.

- `tonemap(0, w) == 0` with `expectEqual`, at `white_headroom`, at `whitePoint(decayOver(frameNanos(60)))`, and at `whitePoint(1.0)`.
- `tonemap(w, w)` within `1e-6` of one, at the same three, with the two non-bit-exact values named in the comment and `srgbEncode(1.0)`'s precedent cited for why the float is approximate.
- The direction that keeps it non-vacuous: `tonemap(w * 0.99, w) < 1.0`, so an unconditional `return 1.0` fails here rather than passing.
- The property as the picture shows it: `resolved(table, shipped_palette, decay, w)`'s dominant channel is byte 255 at `e = w`. This is what ties the float identity to ADR 0019's "the core would be pale green forever" and reuses `paletteScratch`.

### 2. The rail is exactly at the white point

`test "the tonemap is monotone in energy and rails at the white point rather than above it"`, immediately after.

- A sweep over `[0, 4w]` asserting non-decreasing, mirroring the sweep style at `:568-574`.
- The `@min` arm: `tonemap(e, w) == 1.0` exactly for `e` at `w`, `2w`, `100w` and `1e6`.
- The strictness under it: `tonemap(w * (1 - 1e-3), w) < 1.0`. Asserted with the rail, because the two together say the rail is at `w` and neither alone does.

Split from test 1 rather than folded in, so one plant fails one named test — the value #97 recorded for keeping its rows split.

### 3. The white point's derivation and both its ends

`test "the white point is the dwell asymptote, and the clamp is the phosphor that never fades"`, after test 2.

- The zero-decay end: `whitePoint(0.0) == white_headroom` exactly, and `tonemap(1.0, whitePoint(0.0)) == 1.0`, which is the shader comment's "everything above one deposit blows out white" made executable. `white_headroom` is where it first does, so `tonemap(white_headroom, whitePoint(0.0)) == 1.0` and something just under it does not.
- The derivation, at the four rates ADR 0019 tabulates, against `white_headroom * (1 / (1 - decay))` **and** against pinned figures to `1e-4`, measured in `f32` on this branch:

  | Hz  | decay      | steady state | white point |
  | --- | ---------- | ------------ | ----------- |
  | 48  | 0.87660336 | 8.103949     | 6.483159    |
  | 60  | 0.90000000 | 9.999998     | 7.999998    |
  | 120 | 0.94868330 | 19.486841    | 15.589474   |
  | 240 | 0.97400373 | 38.467060    | 30.773650   |

- **The clamp.** `whitePoint(1.0)` and `whitePoint(decayOver(0))` are both `8e5`, with `expectApproxEqRel` at `1e-6`. Both spellings, because the second is the reachable path through this file that the docstring warns about (`palette.zig:434-441`) and the first is the value the shader can be handed by an unbound uniform.
- A decay above one clamps the same way rather than going negative: `whitePoint(2.0) == whitePoint(1.0)`. That is the hot-reload case `palette.zig:443-448` describes, from the end nothing has ever evaluated.

### 4. The resolve of no energy

`test "the resolve of no energy is the background the drawable shows"`, after test 3.

For every palette and at three decays — `0.0`, `decayOver(frameNanos(60))` and `1.0` — `resolved(table, p, decay, 0.0)` equals `background_bytes`. This is the model half of `verdict.zig`'s `BackgroundNotThePaletteAtZero`, and it is a different claim from `"every gradient starts at the background and ends at white"` (`:602`) because it runs through `tonemap` and `whitePoint` rather than calling `paletteAt` at zero directly.

The comment says which half is which, so a reader does not take one for the other: `verdict.resolve` compares the picture's corner against the model, and this compares the model against the constant.

### 5. The inverse `measure-trace` performs on a capture

`test "the dominant channel inverts exactly, which is what measure-trace does to a capture"`, after `"each gradient's dominant channel is an exact readout of the tonemapped value"` (`:623`), whose forward direction it is the inverse of.

- **The argmax agreement, which is the structural gap.** `Palette.dominant()` is a hand-written switch (`:121-128`); `scripts/measure-trace:194-196` picks the same channel with `np.argmax(tint)`. Nothing ties them. Assert `dominant()` equals the first index of the maximum over `tints_srgb[row]`, which is what `argmax` returns and which the neutral gradient's three-way tie makes a real distinction rather than a formality. The existing test's `component <= tints_srgb[…][c]` allows ties and cannot see this.
- The byte round trip, over every byte from the background's own value up to 255, for every palette: `srgbByte(paletteEntry(tints_srgb[row], dominantToTonemapped(p, byte))[dominant])` equals `byte`, with `expectEqual`.
  - **Through the closed form, not through `paletteAt`.** The table is 0.05 bytes off the closed form by its own test (`:695`), which is enough to cross a rounding boundary; the closed form is affine in that channel to `1e-6` by the test above it. The chain to the table is already covered, so routing through it would only add noise.
  - **Starting at the background's byte, not at zero.** Bytes below it have no preimage: `dominantToTonemapped(.green, 0)` is negative and `paletteEntry` clamps, so the round trip is only defined at or above the background.
  - Measured in `f32` before writing it: over all 1,001 samples — 251 bytes each for green, amber and neutral, 248 for blue, whose dominant channel's background byte is 8 — the worst error is **1.5e-5 of a byte**, and the closest any value comes to a `.5` rounding boundary is **0.49998**. So `expectEqual` has four orders of magnitude of margin and is the right assertion rather than a hopeful one.
- The two anchors: the background's own byte inverts to zero within `1e-6` (measured `1.2e-10`), and 255 inverts to exactly 1.0.

## Naming and pinning the dwell floor

Four files, one constant.

**`src/gpu/palette.zig`.** `pub const min_dwell: f32 = 1e-6;` immediately above `whitePoint`, with a docstring saying what the existing inline comment says: it is not what the arithmetic needs but what a hot-reloaded shader needs, since an unbound fragment uniform reads zero at one end and a decay of exactly one divides by zero at the other. `whitePoint` becomes `white_headroom / @max(1.0 - decay, min_dwell)`. The existing `refAllDecls` sweep picks it up with no edit, and `src/main.zig`'s enforcement list is untouched because no module and no container type is added.

**`shaders/scope.metal`.** `constant float min_dwell = 1e-6;` beside `white_headroom` (`:72`), and `tonemap`'s local becomes `max(1.0 - decay, min_dwell)`. The file is 22,363 bytes against `shader.max_bytes`' twofold headroom, which permits 32,768, so a few hundred bytes changes nothing there.

**`scripts/measure-trace`.** `MIN_DWELL = 1e-6  # palette.min_dwell` beside `WHITE_HEADROOM` (`:83`), and `white_point` reads it. The name ends with no other name and no other name ends with it, which is the rule the occurrence-count assertions exist for.

**`src/gpu/metal/renderer.zig`.** `"MIN_DWELL = "` joins the needle list in `"the screenshot tool still holds this project's numbers"` (`:3506-3517`) for both the value assertion and the `std.mem.count == 1` loop; `"min_dwell = "` joins `"the shader's look constants and the model's are the same numbers"` (`:3583`), with an occurrence count there too, which that test currently does not do for `white_headroom` either. **The MSL needle needs the count.** The file will hold `const float dwell = max(1.0 - decay, min_dwell);` as well as the declaration, and `"min_dwell = "` matches only the declaration — but that is a fact to assert rather than to check once by reading.

That test's comment about a reloaded shader getting neither constant checked becomes "none of these three", which is #77's residue growing by one rather than a new hole.

## Plants

Each planted on top of a passing run, and **committed before planting** so `git restore` reverts the plant and not the check. Each plant's trigger unconditional.

| Plant                                                 | Must be caught by                            |
| ----------------------------------------------------- | -------------------------------------------- |
| `min_dwell` 1e-6 to 1e-5, in `palette.zig` alone      | Test 3's `8e5` pin, and nothing else         |
| the same, in `shaders/scope.metal` alone              | The shader constants test                    |
| the same, in `scripts/measure-trace` alone            | The script constants test                    |
| `white_headroom` 0.8 to 8.0, in all three copies      | Test 3's `8e5` pin and its four-rate table   |
| Plain Reinhard: drop the shoulder term from `tonemap` | Test 1, while every existing test passes     |
| Remove `@min(…, 1.0)` from `tonemap`                  | Test 2's rail arm                            |
| `tonemap` returns 1.0 unconditionally                 | Test 1's zero arm and its strictly-below arm |
| `Palette.dominant` returns 1 for `.blue`              | Test 5's argmax arm and its round trip       |
| `dominantToTonemapped` drops the `- background` term  | Test 5's round trip and its zero anchor      |
| `resolved` looks up at `tonemap(…) + 1e-3`            | Test 4                                       |

**Three rows carry more than the column says.** The first is the one that closes something: nothing today calls `whitePoint` at a decay of one, so that plant currently fails nothing anywhere in the repository. The fourth is a control rather than a closing row, for the reason worked out above, and its acceptance is to **record every test that fires**, not only the new ones — the refresh-rate test's steady-state half is predicted to. The fifth carries the issue's own second acceptance box, which is that every *existing* test passes while test 1 fails.

**Then plant the checkers.** After each production plant is confirmed, weaken that test's own assertions one at a time and confirm the weakened test stops failing. [ADR 0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md)'s #92 amendment is the reason this is a separate pass: two arms there survived their own weakening, having been planted far enough outside a bound to be caught by something else. Test 3's four-rate table and test 5's round trip are the two most exposed to that, since both assert many values at once.

## Documents

**This plan's own program plan**, [`2026-09-04-close-the-verification-gaps-in-the-test-suite.md`](2026-09-04-close-the-verification-gaps-in-the-test-suite.md), in one commit:

- Section 8 marked landed, in item 4's form: acceptance bullets to `- [x]`, then a bolded `**Landed.**` paragraph with the measured deltas and the correction that the headroom plant is a control rather than the closing row.
- **Sections 7 and 9 are stale and get corrected in the same commit.** #95 and #97 both landed on `main` after this document was last edited, and item 7 still says "Six modules have it; ten do not, including `palette.zig`", which #95 falsified. #97's own plan set the precedent when it corrected #90's row: a status table that lies about a neighbouring row while this row is being edited is the stale-claim class the program exists to close. The commit message says the neighbours were corrected as well as advanced.

**The build plan**, [`2026-07-25-repo-foundation-and-phased-build-plan.md`](2026-07-25-repo-foundation-and-phased-build-plan.md):

- The verification-program table's #96 row, `Open` to `Done`. #95 and #97 already read `Done` there, so only this row moves.
- The Verification table's "238 named tests across `src/`", which is stale by more than this issue adds. Measure it before and after and record the corrected figure, saying in the commit message that it is corrected as well as advanced.

**`AGENTS.md`**, two clauses:

- The phosphor-fade bullet's "zero sends `whitePoint` to its 8e5 clamp for that frame, which `smoke-trace` caught at two levels off its prediction" gains a clause saying the clamp is now pinned in `zig build test` as well, so the figure is checked without a device.
- The `scripts/measure-trace` bullet's list of restated constants gains the dwell floor.

**[ADR 0019](../../adr/0019-brightness-is-a-fixed-transfer-function.md)**, one sentence. Line 31's "Extended Reinhard reaches its white point exactly at `e = w` while the steady state is only *approached*" gets the same treatment line 29 already gave the refresh-rate table: a clause recording that the claim is now an assertion rather than a derivation. No new decision, so no new ADR.

**Not touched.** No CHANGELOG entry, on #90's and #97's precedent. Nothing here decides anything and no new rule is created; the one new constant is a name for a literal that was already there in three places.

**One incidental fix.** `paletteScratch`'s docstring is duplicated verbatim on two lines (`palette.zig:594-595`), and has been since #60 created the file. Its own commit, since it is unrelated to every test here.

## Verification

`zig build test` is the resource the tests need. The MSL and Python edits add three more checks, and the third acceptance box adds a fourth.

1. **Baseline `zig build test` green and record the count**, before writing anything. The published 238 is stale and the delta is the thing being claimed.
2. Per test: write it, commit it, plant against it, confirm the **named** test is the one that fails, revert, run green. Record what each plant actually did, including any that panics or refuses to compile rather than failing an assertion — a plant that does not compile is not a passing plant, and the build's exit code rather than the shape of its output is what separates them (#97's second correction).
3. **`zig build validate-shaders`** after the MSL edit. It needs the Metal toolchain; `xcrun --kill-cache` if it reports the toolchain missing.
4. **`zig build smoke-gpu`** after the MSL edit, because `validate-shaders` runs `metal -fsyntax-only` and never links a pipeline state.
5. **`ruff format --check . && ruff check .`** after the Python edit. Confirm the log says it read **1** file; a vacuous pass is this job's real failure mode.
6. **`zig build smoke-trace`**, the issue's third acceptance box: its figures must be **unchanged**, since `min_dwell` holds the same value the inline literal did and nothing on the shipping path moves. A changed figure means the rename was not a rename.
7. `zig fmt --check build.zig src/` before each commit. `markdownlint-cli2` in check mode only for this plan, the program plan and the build plan — **never `--fix`**, which ignores its file argument and rewrites every Markdown file in the tree. `typos` over the whole tree at the end.

## What this does not close

- **The shader's `tonemap` and the model's are still two independent derivations**, and now their constants agree textually while their arithmetic does not: MSL writes `energy / (white * white)` and Zig writes `energy * shoulder` with `shoulder = 1 / (white * white)`. Nothing textual could tie those and nothing should try; `zig build smoke-trace` comparing a rendered frame against the model is the check, and it stays the check.
- **A hot-reloaded shader gets none of the three MSL constants checked**, which is [#77](https://github.com/cboone/fosforo/issues/77)'s residue rather than this issue's. It grows from two constants to three, and the rule that makes it survivable is unchanged: rerun `zig build test` after the last save, before quoting any number.
- **`white_headroom`'s value is still provisional**, and ADR 0019 assigns re-judging it to [#58](https://github.com/cboone/fosforo/issues/58). Everything here asserts that the constants are used consistently; none of it says 0.8 is the right number, and nothing here should be read as tuning it.
- **`TraceUniforms` layout drift** stays readable from nowhere, which is #77's and is untouched.

## Commits

As landed, with the deviation the Results section records:

1. `2056212` `docs: drop paletteScratch's duplicated docstring line (#96)`
2. `53e0a76` `refactor: name the dwell floor the white point clamps at (#96)` — the constant in three languages, no assertion yet.
3. `ad18653` `test: pin the dwell floor against the shader and the script (#96)` — both constants tests, and the occurrence count the shader half has never had.
4. `2031a42` `test: assert the tonemap reaches one at the white point (#96)` — **carries test 2 as well**, which was meant to be its own commit.
5. `59c9758` `test: rail the tonemap at the white point and nowhere else (#96)` — the comment recording what planting test 2 found.
6. `2c29f36` `test: assert the white point is the dwell asymptote and its clamp (#96)`
7. `53dbf81` `test: resolve no energy to the background the drawable shows (#96)`
8. `6d5d10c` `test: invert the dominant channel the way measure-trace does (#96)`
9. `19200d3` `test: state the strictly-below-the-rail arms with a margin f32 can hold (#96)` — unplanned, and the third of the three things this plan got wrong.
10. `docs: record the transfer function's asserted properties (#96)` — this plan's results, the program plan's four sections, the build plan's two rows, `AGENTS.md` and ADR 0019.

One plant per commit is the value of this issue, which is why 6 and 7 were kept apart by hand after 4 and 5 ran together. At merge an eleventh commit moves this plan to `docs/plans/done/` and turns its sibling links around.

**The branch is named `chore/tonemap-and-whitepoint` and the work is not a chore.** The branch name is already pushed nowhere and is not worth rewriting; the PR title is `test: assert the transfer function's defining properties (#96)`, matching the issue's own type and every commit above.

## Results

**Done.** Five tests across one file plus two constants tests, the suite from **265 named tests to 270** and from 285 runs to 290, and `zig build smoke-trace`'s transcript **byte-for-byte identical** at this branch's base and tip. **This section records what happened, not what was expected**, and three entries falsify what this plan predicted.

| Plant                                                 | Result                                                          |
| ----------------------------------------------------- | --------------------------------------------------------------- |
| `min_dwell` 1e-6 to 1e-5, `palette.zig` alone         | Both constants tests, as the reference both compare against     |
| the same, `shaders/scope.metal` alone                 | The shader constants test alone                                 |
| the same, `scripts/measure-trace` alone               | The script constants test alone                                 |
| the same, **all three at once**, before test 3        | **285 of 285 passing.** The hole this issue closes              |
| the same, all three at once, after test 3             | Test 3 alone, through the `8e5` pin                             |
| `white_headroom` 0.8 to 8.0, all three                | **Six tests, three of them pre-existing.** A control            |
| Plain Reinhard, shoulder term dropped                 | **Four tests, two of them pre-existing.** Not the clean row     |
| Remove `@min(…, 1.0)`                                 | Test 2 alone                                                    |
| `tonemap` returns 1.0 unconditionally                 | Seven tests, four of them in `verdict.zig`                      |
| `Palette.dominant` returns 1 for `.blue`              | Test 5 and the pre-existing dominant-channel test               |
| `Palette.dominant` sends `.neutral` to channel 1      | **Test 5 alone, through the argmax arm alone**                  |
| `dominantToTonemapped` drops `- background`           | Test 5 alone                                                    |
| `resolved` looks up at `tonemap(…) + 1e-3`            | Test 4 and two pre-existing `verdict.zig` tests                 |

### Weakenings, which found more than the plants did

| Weakening                                             | Result                                                          |
| ----------------------------------------------------- | --------------------------------------------------------------- |
| Test 2's rail loop removed, plant F                   | Still fails — the sweep catches it                              |
| Test 2's `value <= 1.0` removed, plant F              | Still fails — the rail loop catches it                          |
| Both removed, plant F                                 | **Still fails, at `value >= previous`.** See below              |
| Test 1's byte loop removed, plant E                   | Still fails, through the float identity                         |
| Test 1's float identity removed, plant E              | Still fails, through the byte loop                              |
| Test 3's `8e5` pin made vacuous, plant D              | **Still failed, at test 2.** See below                          |
| Test 5's argmax arm made vacuous, plant J             | **290 of 290 passing.** The arm is the sole catcher             |

### Three things this plan got wrong

**The plain-Reinhard plant does not leave every existing test passing, and the issue's own acceptance box says it should.** It fires four tests: both new ones, plus `"the white point holds a deposit's brightness steady across refresh rates"` from #56 and `"a dwelt trace reaches the white point and is exactly white there"` from #92. Both require byte 255 at the dwell asymptote, which plain Reinhard cannot reach. The box was written against a tree those two issues had since changed — the same way the headroom prediction was, which this plan caught before starting and this one it did not.

**The monotonicity sweep catches a missing clamp, incidentally.** With the `@min` and both rail arms removed, test 2 still fails at `value >= previous`: above the rail the unclamped curve is not monotone *in f32*, because the shoulder factor `1 + e/w²` advances by one ulp of 1.0 while the quotient it multiplies moves by less. The clamp flattens all of it to exactly 1.0. That is a real property of the shipping function and is recorded in the test, but the rail arms are what state where the rail is.

**Two assertions were on a knife edge in f32, and a plant is what exposed them.** `tonemap(w * 0.99, w) < 1.0` and its sibling at `w * 0.999` asked whether the curve is under one within a hundredth of the rail. `f(kw)` falls short of one by `(1 - k²) / (1 + kw)`, which at the 8e5 clamp has to clear the 6e-8 of one f32 step below one: at `k = 0.99` the shortfall is 0.0199 against a required 0.0475, so both passed on the luck of the rounding rather than on the curve. Planting `min_dwell` at 1e-5 moves the clamp to 8e4 and lands them on the other side, which is how this surfaced — as a test 2 failure under a plant that has nothing to do with test 2. Restated at `k = 0.9`, four times clear, after which the epsilon plant fails exactly one test.

### One deviation from the commit list

**Commits 4 and 5 landed as a single commit, `2031a42`, whose message names only test 1.** Both tonemap tests are in it. The split was worth having and the mistake was staging the whole file; it is recorded here rather than rewritten, since the branch's history is not amended. What the split was for is preserved anyway, because each test was planted against independently. Commits 7 and 8 were kept apart by moving test 5 out of the file, committing test 4, and putting it back.

### One tool note

**`prettier --write` was reached for to re-align the build plan's Verification table and reverted.** It fixed the alignment and also rewrote four unrelated `*emphasis*` spans to `_emphasis_` across the file. The table was re-padded by a throwaway script instead, which touched the one row that moved. `markdownlint --fix` was never a candidate, for the reason this plan's verification section gives.
