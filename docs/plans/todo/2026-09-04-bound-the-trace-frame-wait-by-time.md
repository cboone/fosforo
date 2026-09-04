# Bound the trace half's frame wait by time, not by yields

Issue: [#89](https://github.com/cboone/fosforo/issues/89). Type: `fix:`. Item 1 of [the verification-gaps program](2026-09-04-close-the-verification-gaps-in-the-test-suite.md), and the only one of the eleven that is currently costing something.

## Context

`zig build smoke-trace` is required in CI and it turned `main` red on a runner with nothing wrong with the shader. Run [33465800182](https://github.com/cboone/fosforo/actions/runs/33465800182) on `0e1ddf5` failed `checkDecay`'s five-frame arm as `smoke: trace FAILED: FramesNeverPresented`, having printed every figure before it correctly: the levels within a pixel, the rail on row 5, the deposit scalar to 0.00000, the resolve's worst channel off by 0, the hot core at `RGB(255, 255, 255)`, and the decay at 0.7285 against a predicted 0.7290. It is the only unintentional CI failure in the last 60 runs of `ci.yml`.

`FramesNeverPresented` comes from `driveFrame` (`src/smoke.zig:762`) exhausting `trace_frame_attempts = 100_000` while `Renderer.frame` reports `.no_frame_slot`. That constant's docstring (`src/smoke.zig:628`) argues the bound is on scheduler turns rather than on a duration, and that "a hundred thousand yields is many seconds of slack on a loaded runner". The failing step ran three seconds against four for a passing trace step on the previous commit: it did not spend many seconds of slack, it gave up faster than a healthy run completes, because `std.Thread.yield()` returns almost immediately when nothing else on the core is runnable. **The bound is a spin count wearing a timeout's clothes**, and it is the only wait in the harness that is not wall-clock, against `frame_timeout_us` at 2 s (`:91`) and `reload_timeout_us` at 6 s (`:429`).

One correction to the issue as filed, and it changes the repair rather than only the record. The issue reasons that exposure grows with frame count, so `checkDecayIsInRealTime`'s thirteen-frame arm is next. **Exposure is not proportional to frame count**: `checkHotCore` drives thirty frames (`src/smoke.zig:1246`), runs *before* `checkDecay`, and passed in that same failing run, which is what the `hot core` line in the log proves. Raising the count would therefore have been the wrong repair; the count is not a duration at any value.

The intended outcome is that the offscreen wait gives up on a measured duration and says which one, so the next occurrence is attributable from the CI log without reading the source, and so a runner slow enough to matter is distinguishable from a completion handler that never fires.

## The change

Three edits in `src/smoke.zig`, and nothing outside it.

### 1. A wall clock beside the sleep, at `src/smoke.zig:109-123`

`sleepFor` is already the harness's local wrapper over the one `std.Io` instance, with a docstring carrying the ADR 0015 reasoning. Add `nowNanos` beside it in the same shape:

```zig
fn nowNanos() u64 {
    return @intCast(std.Io.Clock.awake.now(io.get()).nanoseconds);
}
```

`platform/io.zig` is already imported as `io` (`src/smoke.zig:55`), so this needs no new import. Four things belong in its docstring:

- **It is not the synthetic clock.** The trace half hands `Renderer.frame` a number this file makes up so a fade is reproducible; this one is how long something actually took. Confusing them is the one way to get this wrong silently.
- **It is safe from any thread, and more plainly so than `sleepFor` is.** `driveFrame` runs on a thread `std.Thread.spawn` created and `init_single_threaded` did not. Verified in the Zig 0.16 source rather than inferred: `Threaded.now` (`lib/zig/std/Io/Threaded.zig:11437`) binds its userdata and immediately discards it, then calls `clock_gettime`, so it touches no threadlocal and no shared state. `sleep` reaches `nanosleep` by way of `Threaded.Thread.current`, which is the threadlocal `sleepFor`'s docstring is about.
- **It is not `display_link.monotonicNanos()`**, which is the same two lines against the same instance. That one is the render loop's clock and stays where the loop it paces is, on `platform/io.zig`'s own rule that the construction is shared and the callers are not hidden. A harness whose whole reason for a synthetic clock is that it has no display link should not borrow the display link's module for a timeout.
- **The cast is lossless**, for `monotonicNanos`' reason: `Io.Timestamp` counts signed `i96` nanoseconds and `awake` counts from boot.

`sleepFor`'s own first line, "Sleep, which is all this harness asks of `std.Io`", becomes false and needs the one-word correction.

### 2. `trace_frame_attempts` becomes `trace_frame_timeout_us`, at `src/smoke.zig:619-634`

`_us` rather than `_nanos` so it reads as a sibling of `frame_timeout_us` and `reload_timeout_us` and shares their `/ std.time.us_per_ms` message idiom; the file already reserves `_nanos` for the synthetic clock (`trace_frame_nanos`, `decay_span_nanos`).

```zig
const trace_frame_timeout_us: u64 = 2 * std.time.us_per_s;
```

Two seconds, on `frame_timeout_us`' precedent and for its reason. The cost asymmetry is worth stating in the docstring: only one deadline is ever burned in a run, because `traceHalf` returns on the first error, so a generous ceiling costs seconds once on a genuine defect while a tight one is what turned `main` red.

**Correct the docstring rather than deleting it**, which is the issue's third acceptance criterion. The first paragraph (why `.no_frame_slot` is the ordinary case offscreen, and why every other outcome is a failure here) is untouched. The second is replaced by a record of what it argued, the measurement that falsified it, and the observation above that `checkHotCore`'s thirty frames had already passed in the same run.

One sentence to add that the old docstring had no reason to carry: **a sleeping wait may sum its sleeps and a yielding wait must read a clock.** That is why `waitForFrames` and `waitForReload` accumulate `waited_us` soundly while this one could not: `sleep` guarantees a floor per turn and `yield` guarantees nothing.

### 3. `driveFrame` polls against a deadline, at `src/smoke.zig:762-784`

Keep the `while` shape, keep the yield, keep the error name. The clock is read once at the top and again only on the retry path, so a frame that presents on its first attempt pays one `clock_gettime`.

```zig
fn driveFrame(renderer: *gpu.Renderer, now_nanos: u64) !void {
    const started = nowNanos();
    var attempts: u64 = 0;
    while (true) : (attempts += 1) {
        switch (renderer.frame(now_nanos)) {
            .presented => return,
            .no_frame_slot => {
                const waited = nowNanos() - started;
                if (waited >= trace_frame_timeout_us * std.time.ns_per_us) {
                    say("  waited {d}ms across {d} attempts for a frame slot", .{
                        waited / std.time.ns_per_ms,
                        attempts + 1,
                    });
                    return error.FramesNeverPresented;
                }
                std.Thread.yield() catch {};
            },
            else => |outcome| {
                say("  frame reported {s} on a surface with no compositor", .{@tagName(outcome)});
                return error.FrameSkipped;
            },
        }
    }
}
```

The measured elapsed rather than the ceiling is what the issue asks to print, and it is what makes the difference visible: a failure at 2000 ms and one at 40 ms are the same message under the old code. The attempt count stays as a diagnostic beside it, demoted from the bound to a number; it is the figure that would have told this story the first time.

`error.FramesNeverPresented` keeps its name. Nothing outside `src/smoke.zig:783` references it, so renaming buys nothing and would cost the link to the issue and to the CI log.

The comment on the `.no_frame_slot` arm needs rewording rather than keeping. Its `spinLoopHint` measurement stays (it is a finding and still true), but its claim that "reaching for `std.Io` from a thread its single-threaded instance did not spawn is a bigger claim than this needs" is now the thing being done, one function up. The yield stays because it is the right latency for a slot that frees in microseconds, not because of ADR 0015.

**Not touched:** `src/gpu/iface.zig:411`'s "there is exactly one clock, `display_link.monotonicNanos()`". That sentence is about what may be passed *through the seam* into `Renderer.frame`, and this deadline never reaches it — `frame` still receives the synthetic `now_nanos` unchanged, which is what keeps a retried frame from advancing the simulated clock (`src/smoke.zig:745`).

## Documents

Each lands in this branch, on the program plan's rule that a document updated later describes a state nobody checked.

| Document                                                       | Edit                                                                                                                                        |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `docs/adr/0013-gui-smoke-harness-as-a-build-step.md`           | A new `## Amended by issue #89` section. Line 252's finding stays standing, on that ADR's own rule; the amendment says what its bound was  |
| `AGENTS.md`, the `smoke-trace` bullet                          | A paragraph on the harness's two wait idioms and why the offscreen one is a deadline                                                        |
| `docs/plans/todo/2026-09-04-close-the-verification-gaps-...md` | Item 1 and its summary-table row marked landed, with the `checkHotCore` correction to its exposure claim                                     |

The ADR amendment is an addition to the scope the program plan set, which assigned #89 no ADR. It earns its place because 0013:252 is where the yield-instead-of-spin decision is recorded, and a reader arriving there should not have to find out from the source that its bound has since been replaced.

## Verification

Run in this order. The first two must both be captured *before* any edit, because the second acceptance criterion is a comparison against today's output rather than an inspection of tomorrow's.

1. **Baseline.** On the current `HEAD` (`4602f9c`), `zig build smoke-trace 2>&1 | tee /tmp/trace-before.txt`. Note that the first line is the provenance marker and will differ afterwards; every line below it must not.
2. **Build and unit tests.** `zig build`, `zig build test`, `zig fmt --check build.zig src/`.
3. **No measurement moved.** `zig build smoke-trace 2>&1 | tee /tmp/trace-after.txt`, then `diff <(tail -n +2 /tmp/trace-before.txt) <(tail -n +2 /tmp/trace-after.txt)`, which must be empty. Print both in the PR body.
4. **The plant.** Commit the fix first, then plant, then restore only the planted file — `git restore` would otherwise revert the fix along with the plant. Make `Renderer.frame` return `.no_frame_slot` unconditionally at its top in `src/gpu/metal/renderer.zig`, with no condition guarding it, so the trigger cannot be missed. Then `time zig-out/bin/fosforo-smoke trace`, which must:
   - fail as `smoke: trace FAILED: FramesNeverPresented`, preceded by a `waited ~2000ms across N attempts for a frame slot` line;
   - take roughly two seconds past startup rather than a fraction of a second, which is the whole claim, measured by `time` rather than judged;
   - fail in `checkSilence`, the first case, since the plant is unconditional.

   Then `git restore src/gpu/metal/renderer.zig` and re-run step 3 to confirm the plant left nothing behind.
5. **A negative control for the deadline itself.** Temporarily set `trace_frame_timeout_us` to `1 * std.time.us_per_ms` with the plant still in place and confirm the printed duration follows the constant. Without this the run in step 4 proves a two-second wait happened, not that this constant is what caused it.
6. **Nothing else moved.** `zig build smoke-gpu`, and `zig build smoke-appkit` since the `sleepFor` docstring is in its path even though its code is not.
7. **Linters.** `lint-and-fix`, which covers `zig fmt`, `typos` over the changed Markdown, and `shfmt`/`shellcheck`/`ruff` on files this branch does not touch. Run `markdownlint` in check mode only: `--fix` ignores its file argument and rewrites the whole tree.

## Out of scope

- **Whether the trace half's assertions are right.** That is [#92](https://github.com/cboone/fosforo/issues/92), which refactors the judging halves out and must land after [#57](https://github.com/cboone/fosforo/issues/57).
- **`waitForFrames` and `waitForReload`.** Both sum nominal poll intervals rather than reading a clock, which under-counts real elapsed time and therefore errs toward waiting longer than the stated ceiling. That is sound in the safe direction and is not what turned `main` red; converting them is a change to the AppKit half with no failure behind it.
- **Renaming the error, or the "half" noun.** Both are settled by their own docstrings.
