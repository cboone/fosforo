# Decay the accumulation in real elapsed time

Issue [#56](https://github.com/cboone/fosforo/issues/56). Branch `feature/decay-in-real-time`. Phase 3, step 5 of [the build plan](../todo/2026-07-25-repo-foundation-and-phased-build-plan.md). Depends on [#55](https://github.com/cboone/fosforo/issues/55) (the accumulation) and [#51](https://github.com/cboone/fosforo/issues/51) (the offscreen readback); branched from `feature/tonemap` ([#60](https://github.com/cboone/fosforo/issues/60)) rather than from `main`, so that must merge first.

## Context

`decay_fragment` multiplies the accumulation by a constant **once per frame**, so the phosphor's persistence is a function of how fast the machine happens to be drawing. That is not insurance against hardware nobody has. This machine's panel is ProMotion, adaptive between 48 and 120 Hz, and #38's verification watched the render meter drift between 120.0 and 119.5 while doing nothing unusual.

The defect is observable in about a minute and has a measured baseline, which is the strongest position an issue like this can start from. Playing `click-2hz.wav`, a 1 ms burst at 0.8 repeated twice a second: at the panel's native ~120 Hz each click fades over roughly a quarter second, and pinned to 60 Hz in System Settings **the fade visibly doubles in length**. The acceptance criterion is that after this change those two are the same.

[ADR 0007](../../adr/0007-renderer-simulates-a-crt.md) already requires this in as many words — *"Decay is exponential in real elapsed time against a user-facing time constant, so the look is identical at 60 Hz, 120 Hz, or variable refresh"* — so this issue discharges a consequence that ADR recorded rather than deciding anything that wants a new one. What it does decide is **which clock**, a question [#37](https://github.com/cboone/fosforo/issues/37)'s plan deferred here in writing.

**Three things have changed since the issue was filed and all three make the work smaller.**

- **#60 landed, and it pre-paid the hardest part.** `tonemap` derives the white point as `white_headroom / (1 - decay)` rather than fixing it, precisely so that the dwell asymptote and the white point track the refresh rate together. ADR 0019's table measured a single deposit at green 188–190 and the dwell steady state at 255 across 48, 60, 120 and 240 Hz. **Changing the decay therefore changes trail length and nothing else** — not brightness, not the tint, not any published row. ADR 0019 says so outright: `decay_per_frame` "is a pure persistence knob for the first time and its value is what #56 should inherit as its initial `tau`."
- **#51 landed**, so the frame-rate-independence claim can become an assertion instead of a System Settings toggle and a judgment by eye. The issue's body says the offscreen harness "is the only mechanism that could make this an automated check rather than a manual one". It is, and it needs one thing from the design: the harness must be able to hand the renderer a clock.
- **#61 landed**, so the shader can be edited against a running host. Nothing here needs it, because the arithmetic moves to the Zig side, but it is what makes re-judging `tau` against a real signal cheap afterwards.

## The three decisions

### The time constant is 158.19 ms, anchored on 60 Hz

`tau = -(1 / 60) / ln(0.90)`, the value that reproduces at 60 Hz exactly the 0.90 per frame #55 shipped and ADR 0019's table measured the white point against.

| Hz  | decay per frame | visible trail |
| --- | --------------- | ------------- |
| 48  | 0.876603        | 0.90 s        |
| 60  | 0.900000        | 0.90 s        |
| 120 | 0.948683        | 0.90 s        |
| 240 | 0.974004        | 0.90 s        |

The trail figure is ADR 0019's: under the sRGB toe a single deposit falls below green 16 at frame 54, which at 60 Hz is about a second. On this machine at ~120 Hz that is a **doubling** of what is on screen today, because today's constant is per frame; at 60 Hz nothing changes at all. `click-2hz.wav` will consequently keep two or three trails on screen at once rather than resolving each click before the next arrives, which is the look this anchor buys.

### The clock is `display_link.monotonicNanos()`, and `CVTimeStamp` is refused

The reasoning belongs beside the code, as the issue asks, and it is not "the cheap one won".

**Exponential decay composes.** `exp(-(a + b) / tau) = exp(-a / tau) · exp(-b / tau)`, so the total fade across any interval depends only on the **sum** of the elapsed times and not on how that sum was cut into frames. Both candidate clocks are monotonic and both cover the whole interval, so both sum to the same wall time. What `CVTimeStamp`'s `output_time` buys is a more accurate *subdivision* on a frame that misses its deadline — a bounded per-frame phase error of at most one refresh period against a 158 ms time constant, which never accumulates because the next interval absorbs it.

Against that: `CVTimeStamp` is 80 bytes with a nested `CVSMPTETime`, laid out by hand with no header to check it against, threaded through `DisplayLink.create`'s comptime callback into `Editor.tick`. A wrong field offset yields a plausible-but-wrong `dt`, which is the failure mode this project keeps naming as the hardest kind to notice. `monotonicNanos()` exists, is `CLOCK_UPTIME_RAW`, and is already the clock the render meter is measured against.

`src/platform/displaylink.zig:34-42` currently promises the opposite — *"Phase 3's frame-rate-independent decay is the first thing that wants a timestamp, and restating the struct then is the same rule `src/gpu/iface.zig` already applies to the seam"*. That comment becomes the record of the refusal, since it is the one place someone would go looking.

### The timestamp crosses the seam, and the renderer owns the interval

`frame` becomes `fn (*Renderer, u64) Outcome`, taking an **absolute** monotonic reading rather than a `dt`.

Absolute rather than an interval because the renderer is the only thing that knows whether a frame committed. `frame` has six early returns; `self.accum_source ^= 1` advances at exactly one point, after `commit`, "because a commit is what proves the target was written". The elapsed-time bookkeeping has the same invariant and must advance at the same line, or a run of `.no_frame_slot` ticks would silently discard the time they spanned and the phosphor would hold too long under exactly the load that produces them. A caller passing `dt` cannot maintain that; a caller passing `now` gets it for free.

The payoff is `smoke-trace`. The harness drives frames back to back with no real time between them, so a renderer reading its own clock could only be checked against whatever interval the machine happened to produce. Injecting timestamps turns the whole issue into an assertion.

## What changes

### `src/gpu/palette.zig` — the model, and now the only definition

`decay_per_frame` is replaced by a time constant and a function. This file already owns `white_headroom`, `whitePoint` and `tonemap`, reaches nothing but `std`, and is what lets `zig build test` cover the brightness model on a runner with no GPU.

```zig
pub const decay_reference_hz: f64 = 60.0;
pub const decay_reference_factor: f64 = 0.90;

/// The phosphor's time constant. What survives an interval is `exp(-dt / tau)`.
pub const decay_tau_nanos: u64 = /* -(ns_per_s / reference_hz) / ln(reference_factor) */;

/// The longest interval the decay will believe.
pub const max_elapsed_nanos: u64 = std.time.ns_per_s / 24;

pub fn decayOver(elapsed_nanos: u64) f32;
```

Derive `decay_tau_nanos` at comptime from the reference pair if `@log` is comptime-evaluable on `f64` at Zig 0.16.0; otherwise write the literal (≈ `158_187_027`) and let the test below carry the derivation. Either way the derivation is executable rather than a claim in a comment.

**`max_elapsed_nanos` lives inside `decayOver` rather than at the call site**, so the fade and the white point cannot be clamped differently — they read one `decay` field. 24 Hz is the slowest interval that is still a refresh; anything longer is a resumed loop. It is worth its lines and the numbers say why: without it, a one-second gap gives `decay ≈ 0.0018`, a white point of 0.801, and `tonemap(1, 0.801) = 1.0` — **one pure-white frame** every time an editor is shown after being hidden. Clamped, the same resume produces a frame about 7% brighter than steady state, which is a blip rather than a flash.

### `src/gpu/metal/renderer.zig` — the constant goes, the clock arrives

- **Delete `decay_per_frame` (`:215-229`) outright.** `renderer.zig` already imports `palette` for the gradient table, so it calls `palette.decayOver(dt)` rather than restating the arithmetic. The two-copy arrangement existed because `palette.zig` must not import the backend; the reverse import already exists, and duplicating a *formula* across two files in the same language is a worse trade than duplicating a scalar was.
- **`AccumUniforms` loses its default:** `decay: f32` with no `= decay_per_frame`. A default is now actively wrong — `.{}` would produce a plausible frame at a fixed decay — so the type system is what forces the value to be supplied.
- **New field:** `last_frame_nanos: ?u64 = null`. Null before the first committed frame, which yields `dt = 0` on a pair `buildAccumulation` has just cleared: nothing to fade, and at one deposit the white point's influence is under a percent.
- **`frame(self: *Renderer, now_nanos: u64)`:** compute `dt` and build `accum_uniforms` where `:1694` builds them today (read-only, before the early returns), and assign `self.last_frame_nanos = now_nanos` beside `self.accum_source ^= 1` at `:1826`. The comment there currently reads "Two invariants, two points"; it becomes three, and the third is the one this issue adds.

Both binds are untouched: the same struct still goes to `accum_uniform_index` for the decay pass (`:1711`) and the resolve (`:1794`), which is what makes the clamp automatically consistent across the two.

### `src/gpu/iface.zig` — one line in the signature block

`assertSignature("frame", ..., fn (*Renderer, u64) Outcome)` at `:415-456`, plus prose on `frame` in the `Renderer` alias docstring saying the parameter is an absolute monotonic reading in nanoseconds and not an interval, and why. The operation count stays eleven.

### `shaders/scope.metal` — comments only

`decay_fragment`'s body is unchanged; the arithmetic moved to the CPU, which is one `exp` per frame rather than one per pixel and is why the issue asked for a uniform in the first place. Update `:22-24` (the header's "not finished here" list), `:112-114` (`uniforms.decay` "is a constant per frame today"), and `:36-40` (`white_headroom`'s "once #56 makes the decay a function of elapsed time"), all of which are written in the future tense about this change.

### `src/clap/gui.zig` — one clock read, used twice

`tick` reads `display_link.monotonicNanos()` once at the top and passes it to `renderer.frame(...)`; `report` takes it as a parameter instead of reading its own. More truthful than two reads, and it means the meter and the decay describe the same instant.

Consequence to record rather than fix: `monotonicNanos` gains a caller that is not behind `if (builtin.mode != .Debug) return`, so the clock is now live in a release build. AGENTS.md:308 currently claims adopting `std.Io` "left the release binary byte-identical, since `monotonicNanos` is reached only from the debug-only `Editor.report` and is stripped with its caller". **Re-measure the release binary and update that sentence with the real number.** Nothing about ADR 0015 changes: `init_single_threaded` is still the only constructor, and the render thread already read this clock in debug.

### `src/smoke.zig` — the automated acceptance test

`Probe.run` and `Worker` gain a frame interval; `Worker.drive` keeps a synthetic clock and advances it by that interval per frame.

- **`trace_frame_nanos: u64 = std.time.ns_per_s / 60`** is the harness's nominal rate. Chosen so `decayOver(trace_frame_nanos)` is exactly 0.90: **every existing offscreen number stays what it was**, including `checkResolve`'s per-pixel prediction (`:1055`, `:1078`), `checkHotCore`'s white point (`:1174`) and `checkDecay`'s five cases. Those sites swap `palette.decay_per_frame` for `palette.decayOver(trace_frame_nanos)` and nothing else moves.
- **New case, `checkDecayIsInRealTime`.** Drive the same 96 ms of simulated wall time two ways from a fresh renderer each: one deposit then **12 intervals of 8 ms** (125 Hz), and one deposit then **6 intervals of 16 ms** (62.5 Hz). Integer nanoseconds, exactly equal totals. Assert each arm's `measure.maxChannel` ratio against `decayOver(96 ms)` = **0.5451**, and assert the two arms agree with each other. Tolerance 2%, on `checkDecay`'s own reasoning about half-float compounding.

  The falsification is loud, which is the point: with a per-frame factor the arms give `0.9^12 = 0.2824` and `0.9^6 = 0.5314`, a factor of 1.88 apart, against a tolerance of 2%.

### `scripts/measure-trace` — the constant it borrows changes shape

`DECAY = 0.9` at `:66` becomes `TAU_NS` (an integer, so the tie is exact rather than a float cast) and `CAPTURE_HZ = 120.0`, with `lit_threshold` deriving its own decay. Watch two things the file already warns about: **no name may end with another's**, since the Zig side finds each by substring and takes the first match, and the constants test counts occurrences for exactly that reason.

**Measure before adding a `--refresh` flag.** The white point reaches only `lit_threshold`, at `LIT_ENERGY = 0.231`, where the shoulder term is negligible — moving the white point from 8.0 to 15.6 looks likely to move the reported byte by less than one. If that holds, state the number and keep the constant; if it does not, add the flag.

### Tests

**`palette.zig`** (pure, runs anywhere):

- `decayOver(0) == 1.0`, and monotone decreasing in `elapsed_nanos`.
- `decayOver(ns_per_s / 60)` ≈ 0.90 — the derivation, executable.
- **Composition**, at several splits: `decayOver(a) * decayOver(b)` ≈ `decayOver(a + b)`. This is the property the whole issue is about, and it is provable as arithmetic with no GPU.
- The clamp: `decayOver(10 * ns_per_s) == decayOver(max_elapsed_nanos)`.
- `whitePoint(decayOver(dt))` finite and positive at `dt = 0` and at the clamp.
- **Brightness invariance**, which is ADR 0019's table turned into an assertion: `resolved(table, .green, decayOver(ns_per_s / 60), 1.0)` and the same at `/ 120` and `/ 240` agree to within a byte. Nothing checks this today, and it is what would break in silence if `tau` or `white_headroom` moved.

**`renderer.zig`:** the `AccumUniforms` layout test is unchanged (still one `f32` at offset 0). Replace the two value tests at `:2965-2981` with one asserting the field has **no default** — `@typeInfo(AccumUniforms).@"struct".fields[0].default_value_ptr == null` — which is directly testable and is the safety this change buys. Drop the `decay_per_frame == palette.decay_per_frame` line from `:2925-2929`, since there is no longer a second copy; the rest of that test (`white_headroom`, `palette_row` against the shader source) stays. Update the `measure-trace` constants test's needle list and its uniqueness count.

### Documentation

- `src/platform/displaylink.zig:34-42` — the refusal and its reasoning, in the comment that currently promises the restatement.
- `src/gpu/measure.zig:156-162` — `maxChannel`'s "the ratio of this across successive frames is the decay factor" becomes a ratio per elapsed interval.
- ADR 0007 — the "Frame-rate-independent persistence" bullet is now built rather than planned; note it beside the two consequences already recorded there.
- ADR 0019 — its prediction is discharged. The white point derived from the decay is now doing the job it was built for, and the table it was measured against is what set `tau`.
- README.md:11 — "the persistence is measured in frames rather than in seconds" comes out of the not-yet list.
- AGENTS.md — the Current state paragraph, the `std.Io` bullet's release-binary claim, and a new gotcha for the clock decision and the resume clamp.
- The build plan's phase 3 table (`:323`) and ordering paragraph (`:364`).

## Verification

**Automated, and this is the part the issue thought might not exist:**

```bash
zig build test          # the model, the composition property, the constants ties
zig build smoke-trace   # ten existing cases unchanged, plus checkDecayIsInRealTime
zig build smoke-gpu
zig fmt --check build.zig src/
ruff format --check . && ruff check .   # the measure-trace edit
typos
```

`zig build smoke-trace` is the acceptance test. Both arms must land within 2% of 0.5451 and within 2% of each other.

**Plant the defect before believing the check.** Commit first, then make `frame` ignore its parameter and pass `palette.decayOver(trace_frame_nanos)` unconditionally — the per-frame behaviour this issue removes — and confirm `checkDecayIsInRealTime` fails with the two arms 1.88x apart. Make the plant's trigger unconditional so `git restore` cannot revert the fix along with it.

**In a host, which is still the only thing that covers the audio path, the ring, the display link and the compositor:**

```bash
zig build install-clap
CLAP_PATH="$PWD/zig-out" /Applications/REAPER.app/Contents/MacOS/REAPER
```

Play `~/Music/fosforo-test-tones/click-2hz.wav`. Read the `rendering at N Hz` line to confirm the rate, then pin the display to 60 Hz in System Settings and back to 120. **The fade duration must not change.** Before this issue it doubles, which is the measured baseline in #56's comment. Confirm provenance from the install step's hash and branch line before trusting either reading.

Also worth a look while there, because #55's resolve-gain defect was found by eye in under a minute and passed every automated check at the time: a 100 Hz sine should look the same brightness as it does today, and only the tail should be longer.

## Deliberately not done

- **No `CVTimeStamp`, and no ADR for that.** The reasoning goes beside the code; ADR 0007 already settled the "what".
- **No `exp` in the shader.** One per frame on the CPU rather than one per pixel, which is why `AccumUniforms` carries a decay rather than a `dt` and a `tau`.
- **`tau` gets no parameter.** Phase 5 owns that. What this issue owes it is a constant with a unit and a meaning, which is what a control needs to be attached to.
- **`white_headroom` is not re-judged.** ADR 0019 says explicitly to leave it until #58 widens the dwell range, because the picture cannot currently distinguish one value from another.
- **No new instrument for the resume clamp.** Its worst case is a 7% brightness blip on a single frame, and there is nothing to measure it with that would not cost more than the artefact.

## What happened

**Every number the plan predicted held, and two things it did not predict were found by the harness rather than by reasoning.**

`tau` is 158,187,026 ns, derived at comptime from `(60 Hz, 0.90)`: `@log` turned out to be comptime-evaluable on `f64` at Zig 0.16.0, so the literal fallback was not needed and the derivation is executable. The per-frame factors it produces are 0.876603, 0.900000, 0.948683 and 0.974004 at 48, 60, 120 and 240 Hz, matching ADR 0019's table exactly.

`smoke-trace`'s ten existing cases print byte-identical numbers, which is what anchoring on 60 Hz bought: `resolve: 2412 lit pixels, worst channel off by 0`, `thirty deposits peak at 9.539, white point 8.000`, and the same four decay ratios. `checkDecayIsInRealTime` reads 0.5430 and 0.5439 against a predicted 0.5451 — **0.18% apart**.

**The first frame cannot use a zero interval, and `checkResolve` is what said so.** The plan asserted that one deposit would resolve "within a percent of its usual value" at `dt = 0`, on the grounds that the tonemap's shoulder term is negligible at an energy of one. It is negligible, and the resolve check still failed at **two levels off** against a tolerance of one, because a decay of 1.0 sends the white point to its 8e5 clamp rather than to something merely large. The first frame now stands in one interval at the reference rate, which is a bounded guess where zero was not a guess at all. By eye that frame would have looked exactly right.

**The clamp caught the new check before the new check caught anything.** `checkDecayIsInRealTime` was first written asking `decayOver(decay_span_nanos)` for its expectation, which clamps at 41.7 ms and predicts 0.7684 against a true 0.5451. Composing per step is both correct and better, since it makes the two arms' expectations two independent derivations that must coincide.

### The host half, as far as it goes without hands

`clap-host` loaded the installed debug bundle and reported `rendering at 60.0 Hz, 960x540 at 2.00x, 882 sample window, 420 uploaded, 0 torn` for as long as it was watched. **That line is stronger evidence than it was before this issue**, because `Editor.tick` now reads the clock once and hands the same reading to the decay and to the meter: a stable 60.0 Hz *is* the statement that the intervals feeding `decayOver` are 16.67 ms, and there is no separate reading that could be wrong while the meter looked right.

The display happened to be at 60 Hz, which is the anchor rate, so the decay in that session was exactly the 0.90 that shipped before — the picture is meant to be identical there and the capture says it is. Measured off a window-targeted `screencapture` at 1920x1080, converted out of Display P3:

```text
drawable found at x=0 y=130, cropping to it
off the curve    0.02% of 2071680 unsaturated pixels
highest peak     row 539    implies sample +0.0021
brightest pixel  g=255, at or above the white point
```

Row 539 and `+0.0021` are the same figures #38 measured in REAPER and ADR 0019 measured in `clap-host`, so the vertical mapping is untouched. The last line is the one that belongs to this issue: the white point is derived from the decay, the decay now comes from a measured interval, and a stationary trace still dwells all the way to white. Had those intervals been wrong the white point would have been wrong with them and that line would not have reached 255.

**Take the window by id rather than the screen.** A full-screen capture put `find_drawable`'s bounding box at 2296x1232 against a 1920x1080 drawable, swept in adjacent dark chrome, and was refused at 19.8% off the ray with a median deviation of 0.00 — the crop was wrong, not the picture. `screencapture -o -x -t png -l <window>` fixes it, and the id comes from `CGWindowListCopyWindowInfo`.

**The acceptance test passed.** #56's comment states it as a criterion rather than a technique: *"After this issue, the visible fade duration of a `click-2hz.wav` click must be the same at 60 Hz and at 120 Hz. Before it, the 60 Hz fade is twice the 120 Hz one."* Run in REAPER against the installed debug bundle, switching the display between the two rates: **no visible effect on the fade duration.** That is the before-and-after this issue was filed with, and it is now the after.

Worth naming what that adds over the offscreen check, because the two are not the same claim. `checkDecayIsInRealTime` renders a window it supplied itself and hands the renderer synthetic timestamps, so it says everything about the arithmetic and nothing about the audio path, the ring, the display link, or whether a real `CVDisplayLink` at two different rates produces the intervals the arithmetic assumes. The host says exactly that and by eye, which is the half no harness here can reach.

### Planted defects

Committed first, so `git restore` could not revert the fix along with the plant.

| Plant | Caught by | Reading |
| ----- | --------- | ------- |
| The decay is per frame again — `frame` ignores its parameter | `checkDecayIsInRealTime` | 0.2813 against 0.5451, the predicted `0.9^12 = 0.2824` |
| The clock advances at the top of `frame`, above the semaphore wait | `checkHotCore`, `CoreNotWhite` | thirty deposits pile to 29.703 against 9.539 |
| The clock advances below the semaphore wait but not at the commit | **nothing** | unchanged at 0.5430 |

The third is the honest one. `.no_frame_slot` returns *above* where the elapsed time is computed, so that placement loses nothing and the invariant holds there too; only hoisting above the semaphore breaks it, and in a host it is `.no_drawable` under a busy compositor that would do the same. The invariant is real and its blast radius is narrower than the plan claimed.

### `--refresh` was added, and the measurement is why

The plan said to measure before adding the flag and to keep a constant if the white point's influence stayed under a byte. It does for `lit_threshold` — 120.62 at 48 Hz to 120.33 at 240, three tenths of a byte — and it does not for `energy_from_tonemapped`, which reads 5.0 deposits at 60 Hz and 7.0 at 120 for the same `t = 0.9`. Inverting the curve near saturation is exactly where the white point does its work. One number needs the flag and the other does not, so the flag exists and defaults to 120.

One consequence worth carrying: the lit threshold straddles a rounding boundary, so the *printed* integer goes 121 below about 90 Hz and 120 above. One level on a threshold changes no conclusion, but a re-measured capture that moved by one is explained.

### The release binary

`monotonicNanos` is no longer debug-only, so AGENTS.md's claim that adopting `std.Io` "left the release binary byte-identical" is now half wrong. Measured by building `--release=fast` with and without the one call in `Editor.tick`: **220,000 to 220,176 bytes, +176**, and the binary gains one imported symbol, `clock_gettime_nsec_np`. `Io.Threaded`'s symbols are still absent, which is what ADR 0015's vtable argument was about, so nothing there changed.

## Commit sequence

The plan's five-commit split was optimistic about what compiles on its own, and the reason is worth recording. Deleting `palette.decay_per_frame` breaks `smoke.zig` and two tests in `renderer.zig`, one of which reads `scripts/measure-trace` as text, so the model, the seam, the renderer, the editor, the harness's call sites and the Python constant all have to move in one commit for `zig build test` to pass. What was actually committed:

1. `docs:` the plan.
2. `feat:` the whole behaviour change, which is everything that must move together.
3. `test:` the harness's synthetic clock and `checkDecayIsInRealTime`.
4. `docs:` the refusal of `CVTimeStamp`, the shader's future-tense notes, ADRs 0007 and 0019, README, AGENTS.md, the build plan, and this section.
