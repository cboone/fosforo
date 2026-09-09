# Count an unreadable shader apart from a fallback

Issue: [#118](https://github.com/cboone/fosforo/issues/118). Type: `fix:`. Found by Copilot's review of [#116](https://github.com/cboone/fosforo/pull/116), which is [#93](https://github.com/cboone/fosforo/issues/93)'s extraction; the extraction preserved the defect deliberately and putting the mapping in one table is what made it visible.

## Context

`src/gpu/metal/reload.zig:122` reads `.watch_unreadable => .{ .fallbacks = 1 }`, and `src/gpu/iface.zig:357-360` documents `fallbacks` as "times the embedded copy was used because the disk one could not be". The watcher never uses the embedded copy. It keeps the pipelines already running, which is what its own message says at `src/gpu/metal/renderer.zig:1136` — "keeping the shader now running" — and what makes the swap fail-soft. The increment and the message contradict each other.

Nothing misreports today, because every reader of `fallbacks` in `src/smoke.zig` drives the opening path: the four at `:444`, `:461`, `:493` and the `:641` timeout dump all belong to `reloadFallbackArms`, which goes through `probe`. `hotReloadPhase` asserts on `reloads` and `rejected` alone. So this is latent rather than live, and the fix is about what the counters mean rather than about a wrong number anyone has seen.

**The issue's option 2 is worse than the issue says, which is what settles the choice.** It proposes widening `fallbacks` to mean "the disk copy was not used". Under `watch_rejected` the disk copy is also not used — the source was read, refused, and the running shader stays — and that row deliberately does not credit `fallbacks`. So the widened sentence would be false for a second row, and making it true would erase the asymmetry that `reload.Outcome` carries the site in its key for (`reload.zig:61-68`, and [ADR 0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md) at its #93 amendment). Option 2 fails on its own terms rather than merely costing `UnexpectedShaderFallback` some strength.

Option 3, dropping the increment, leaves the one outcome with no other trace uncounted: a debug build's `sayShader` line is all that remains and a release build has neither.

So: **option 1, a fourth counter**, and `unreadable` credits both sites rather than the watcher alone.

## The shape the table takes

```zig
.watch_unreadable => .{ .unreadable = 1 },
.watch_rejected   => .{ .rejected = 1 },
.watch_reloaded   => .{ .reloads = 1 },
.open_unreadable  => .{ .unreadable = 1, .fallbacks = 1, .say = .once },
.open_rejected    => .{ .rejected = 1,   .fallbacks = 1 },
.open_reloaded    => .{ .reloads = 1,    .say = .never },
```

Two columns with one meaning each. The first says what happened to the source off disk — it could not be read, it was read and refused, it was read and taken. The second says whether the embedded copy was used, which is true on exactly the two open-path failures and on nothing else. The site then determines the second column alone, which is a sharper statement of why the site is in the key than the current table can make.

It mirrors `rejected`, which already spans both sites this way, and it makes `iface.ShaderStats.fallbacks`' existing docstring true as written rather than needing a new one. It strengthens `src/smoke.zig:444`'s `UnexpectedShaderFallback` instead of weakening it: `fallbacks` now moves only where something fell back.

## Changes

### `src/gpu/iface.zig`

- Add `unreadable: u64 = 0` to `ShaderStats`, above `fallbacks`, with a docstring saying it counts a source that could not be read at either site and that it moves alongside `fallbacks` on the opening path and alone under the watcher. A field rather than a seam operation, which the type's own docstring at `:320-326` already argues for.
- Narrow `fallbacks`' docstring at `:357-359`. It keeps "times the embedded copy was used"; what goes is "unreadable _or_ unusable", which is now `unreadable`'s half, and what stays is that it moves alongside `rejected` under `open_rejected`.
- Correct three counts to six: `fifth number` at `:324`, `five atomics` at `:575`, `five counters` at `:629`.
- Extend the all-zero test at `:654-664` with `unreadable`. The `expectEqual(ShaderStats{}, stats)` half covers it already; the explicit line is what the test's own comment at `:645-647` says the two halves are for.

### `src/gpu/metal/reload.zig`

- Add `unreadable: u64 = 0` to `Deltas`, `unreadable: std.atomic.Value(u64) = .init(0)` to `Counters`, the `fetchAdd` in `note`, and the field in `stats`.
- **The `fallbacks` bump stays first in `note`.** The say-once rule reads its own previous value (`:162-164`), and `open_unreadable` still credits `fallbacks`, so the coupling that lets an earlier `open_rejected` silence a later unreadable file is preserved exactly and its test at `:471-490` is unchanged.
- Replace the #118 note at `:107-119` with the settled reading: what each column means, and why counting a read failure as `rejected` is refused. The note currently tells a reader not to fix it; it should tell them what it was fixed to.
- Extend the `Outcome` docstring at `:61-68` so the asymmetry paragraph covers the read-failure row as well as the compile-failure row.
- Correct `five atomics` at `:4` to six, and `.always` for five of the six at `:94` to four: `always` is `watch_unreadable`, `watch_rejected`, `watch_reloaded` and `open_rejected`, which is four. A pre-existing off-by-one in a docstring this diff rewrites anyway.
- Tests, in place rather than added: the cell-by-cell table at `:401-422`, whose vacuity guard at `:420` **must** gain `+ d.unreadable` or `watch_unreadable` sums to zero and the guard fails; the comment at `:415-417` claiming only `open_rejected` moves two counters, which is now also `open_unreadable`; `noting an outcome moves what its row says` at `:438-455`; `a counter accumulates` at `:457-469`; and the transposition test at `:531-550`, whose four distinct values become five so a swapped pair still cannot read as a pass.
- Add a sibling to `a rejection falls back only where there is something to fall back to` at `:424-436`, asserting the same claim for an unreadable file: `deltas(.watch_unreadable).fallbacks == 0`, `deltas(.open_unreadable).fallbacks == 1`, and both crediting `unreadable`. That row is the defect; the test that would have caught it belongs beside the one that catches its neighbour.

### `src/gpu/metal/renderer.zig`

- Correct `five atomics` at `:680` to six. No call site changes, so the six-outcome canary at `:4145-4176` and its exact counts of 8 and 11 are untouched — `canary.mentions` skips comment lines, so a docstring edit cannot move them either. Take care not to write the literal `shader_counters` into a code line while editing.
- Extend the mismatch test at `:3379-3411`, which enumerates the counters that stayed at zero, with `unreadable`.

### `src/smoke.zig`

- `waitForReload` at `:629-654` learns `unreadable: ?u64 = null`, and the timeout dump at `:641-647` prints it.
- `reloadFallbackArms`: the identical-copy arm asserts `unreadable` flat alongside `fallbacks`; the missing-path arm asserts it moved by one alongside `fallbacks`; the moved-binding arm adds it to the list of counters that did not move, so that enumeration stays total.
- **A sixth arm in `hotReloadPhase`, which is the first instrument to execute `watch_unreadable` at all.** Add `oversizedShader(buf)`, which fills the existing `[shader.max_bytes]u8` local with the embedded shader padded to exactly `shader.max_bytes` bytes. `shader.stamp` then succeeds, so `Watch.look` returns `.reload`; `shader.read` at `src/gpu/metal/shader.zig:212-218` refuses a read that fills its buffer and returns `error.ShaderTooLarge`. That is the only way to fail the watcher's read while the change is still detected — deleting the file fails the stat instead, which `look` maps to the "learned nothing" case and never reaches `read`.
  - It goes after the renamed-function arm and before the recovery arm, so recovery still closes the phase and still proves a good file is picked up after a bad one.
  - It waits on `unreadable`, asserts `reloads` did not move, and asserts the loop kept presenting frames, matching the broken-shader arm beside it.
  - It also executes `shader.read`'s size refusal, which nothing covers today: `shader.zig`'s tests are all pure and the file asserts that none of them opens a file.
  - Update `hotReloadPhase`'s docstring at `:527-530`, which lists what it asserts in order, and its closing `say` line.

### Documents

- `docs/notes/shader-plumbing.md`: a bullet recording the resolution and the new arm. Living, corrected in place.
- `CHANGELOG.md`, under `Unreleased` → `Fixed`: what the counter claimed, why `rejected` was refused as the fix, and the two-column shape the table took.
- [ADR 0013](../../adr/0013-gui-smoke-harness-as-a-build-step.md): a short `Amended by issue #118` section **appended**, never edited, on the pattern of the #61, #89 and #93 amendments. What it records is a harness fact rather than the counter decision: `hotReloadPhase` gained a sixth arm, and it is the only instrument that has ever executed either the `watch_unreadable` row or `shader.read`'s size refusal.
- **No new ADR.** This is counter semantics, not a settled architectural decision, and nothing in ADR 0013 goes stale: its `:403` claim about compile failures is untouched, and its `:405` say-once coupling survives because `open_unreadable` still credits `fallbacks`.

## Verification

```bash
zig fmt --check build.zig src/
zig build test                # the mapping, the say-once coupling, the transposition guard
zig build test-safe           # ReleaseSafe takes the stub; the reload.zig tests still run
zig build smoke-gpu           # the six fallback arms, which must be byte-identical
zig build smoke-appkit        # the six live-swap arms, which gain one
npm run format && npm run lint:md
```

**`smoke-gpu`'s transcript must not change.** Every open-path site still credits `fallbacks` exactly as it did, so no arm there can move; the only row that loses `fallbacks` is `watch_unreadable`, which `probe` cannot reach. A changed transcript there means the narrowing went too far, and that is the check worth reading first.

**`smoke-appkit`'s transcript changes by exactly the new arm**, one `sayShader` line from the plugin naming `ShaderTooLarge` and the amended closing line. Anything else moving is a regression.

**Plant the checker, not just the code.** Every plant below was run, at `6ae7dcc`, against a suite of 319:

| Plant                                                       | Predicted                                    | Measured                                                              |
| ----------------------------------------------------------- | -------------------------------------------- | --------------------------------------------------------------------- |
| `.watch_unreadable => .{ .fallbacks = 1 }` restored         | the table test and the new sibling           | **5 failures**, both of those included                                |
| `.open_unreadable` dropping `.fallbacks`                    | the say-once coupling, and `smoke-gpu`'s arm | **3 failures** plus `smoke-gpu`, as predicted                         |
| the vacuity guard left at three terms                       | nothing                                      | **the table test.** The prediction was wrong; see below               |
| `oversizedShader` padding to `max_bytes - 1`                | the new arm, as `ShaderNeverReloaded`        | `smoke: appkit FAILED: ShaderNeverReloaded`, at 65,535 bytes reloaded |
| `unreadable` and `fallbacks` transposed in `Counters.stats` | the transposition test                       | **3 failures**, that one included                                     |

**The third row's prediction was wrong, in the safe direction, and the reason generalises.** The plan expected a vacuity guard left reading `reloads + rejected + fallbacks` to pass silently, on the assumption that a stale guard is a guard that checks nothing. It fails: under the new table `watch_unreadable` credits none of those three, so the sum is zero and the `> 0` assertion fires. The guard is self-protecting precisely because the fix moved a row out of the counters it sums, which is the same property that made the row worth guarding. **A prediction about what an instrument will not see is an assertion, and has to be run rather than read** — which is #93's own lesson arriving one issue later.

**And the fourth row is worth reading rather than tallying.** At one byte under the boundary the transcript shows `recompiled 65535 bytes`: the file compiles, swaps in, and the arm times out waiting for a counter that never moves. So the arm asserts the boundary rather than passing near it.

## What is deliberately not touched

**`hotReloadPhase`'s fourth arm stays weak.** ADR 0013 at `:401` records that the renamed-function arm can pass without the renamed shader ever being read, because it waits on `rejected >= n + 1` while the previous arm's broken file is still being re-rejected four times a second. That is a real gap, it is unrelated to which counter a read failure moves, and closing it inside this diff would put a second behaviour change in a fix whose evidence is that `smoke-gpu` did not move.

**The counters still cannot tell a swap that used the new bytes from a recompile of the old ones.** That is what the fixtures are for, and it is unchanged.
