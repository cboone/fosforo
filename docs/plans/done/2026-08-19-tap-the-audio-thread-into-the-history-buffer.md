# Tap the audio thread into the history buffer

Issue [#36](https://github.com/cboone/fosforo/issues/36). Phase 2, step 2 of
`docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`. Depends on
[#35](https://github.com/cboone/fosforo/issues/35), which landed the container.

## Context

`src/dsp/ring.zig` shipped with no caller. It is the one module in the project reached only from
`src/main.zig`'s test block, which means a plain `zig build` parses it and never type-checks it, and
the `Build`, `clap-validator` and `clap-wrapper` jobs all pass over a type error in it. This issue is
the producer arriving: `process` starts writing the tapped channel into the ring, which is the first
time this plugin does anything with audio beyond copying it.

The real-time discipline [ADR 0010](../../adr/0010-lock-free-history-buffer.md) asks for is already
wired into `src/clap/plugin.zig` and must be used rather than rebuilt. `activate` validates
`sample_rate` and `max_frames_count` and refuses rather than asserting; it allocates `Instance.scratch`
and `deactivate` frees it; `process` wraps that scratch in a `FixedBufferAllocator`, hands the
allocator down, and asserts `fba.end_index == 0` afterwards; and `passThrough` takes an allocator it
deliberately does not use, so the call graph proves the property rather than a comment claiming it.

The intended outcome is that the audio thread publishes a second of history that nothing reads yet.
Issue [#37](https://github.com/cboone/fosforo/issues/37) is the render-thread read, and keeping the
two apart is what lets this one be tested with no window and no GPU.

## The decisions the issue asks for

### The tap is the left channel of the output, and nothing else

One `Ring` holding output channel 0. [ADR 0010](../../adr/0010-lock-free-history-buffer.md) describes
this plugin as an analyzer that "passes audio through and taps one channel", and
[ADR 0012](../../adr/0012-phosphor-oscilloscope-first.md) files stereo monitoring, the banded
correlation history and the X-Y vectorscope, under a lens deferred past v0.1.0. A sum is not "one
channel": it is a derived signal, it raises a sum-versus-average gain question nothing here can
answer, and it destroys at capture time exactly the information the vectorscope would need.

Nothing about this shape forecloses the second channel. Two `Ring`s share nothing, so adding the
right channel later is one more field in `activate` and one more `write` in the tap, not a reshaping.

**Tapped downstream of the pass-through, from the output side.** By the time the tap runs,
`passThrough` has already silenced whatever the input failed to reach, so a host that hands over an
unusable input still produces a moving timeline of the silence the track actually carried, rather
than a trace frozen on the last good block. With `in_place_pair` taken up the two sides are the same
memory anyway.

### A reset clears the history, as a sequence of ordinary writes

CLAP's own header defines `reset` as "Clears all buffers, performs a full reset of the processing
state", so clearing is the documented contract rather than a judgment call. A scope that keeps a
stale window across a transport locate is showing audio from a different part of the timeline, and
phase 4's trigger scans backward sample by sample and would find threshold crossings on the far side
of the jump.

**The shape is the decision, not the clearing, and the first attempt at it was wrong.** It shipped as
one `@memset` of the storage followed by one cursor store advancing by the capacity, on the reasoning
that a reader would then see a full lap and report its window torn. Copilot caught the hole in review,
correctly.

`coherent` compares the cursor before and after the reader's copy, so it can only detect tearing that
cursor **movement** reveals. A reader whose entire copy lands inside the memset window observes the
same cursor twice, is told its window is coherent, and comes away with a window that was rewritten
underneath it. Publishing after the fill does not fix that, and publishing before it just moves the
same hole to readers that snapshot during the fill. One store cannot bracket a write as wide as the
whole buffer, and no ordering of one store and one memset is safe.

`write` is not exposed to this, because it writes *ahead* of the cursor while a reader reads behind
it, so the two only overlap when the producer laps, and lapping is exactly what the cursor shows.
The fix is therefore to make the clear literally a sequence of `write` calls over a static block of
silence, rather than something merely shaped like one. That inherits `write`'s property instead of
approximating it, which is what the first attempt was doing: every slot the clear touches is ahead of
a cursor that has already been published.

The chunk is 256 samples, a typical audio block, chosen so the residual uncertainty in `coherent` is
one unpublished chunk wide. A clear is then no worse for a concurrent reader than a host handing over
a block of that size, which is the risk ADR 0010 already accepts and rests its margin argument on.

The cost is a full-buffer fill, 256 KiB at 48 kHz, plus one release store per chunk, on a call that
fires at transport locate rather than per block. That is a few microseconds against the 2.7 ms
deadline of a 128-frame block, and it allocates nothing, takes no lock and makes no syscall, so
ADR 0010 is satisfied.

**The lesson worth keeping**, since it generalizes past this function: an analogy to a safe operation
is not the safety of that operation. The first version's docstring said it was "`write` of a
capacity-length block of zeroes, with the wrap collapsed"; the collapsing is exactly what removed the
property being relied on.

### Capacity is a second, derived from the sample rate

`Ring.init` rounds up to a power of two, so 48 kHz asks for 48000 samples and gets 65536, which is
1.365 seconds and 256 KiB, next to phase 3's ping-pong accumulation textures at megabytes each.

`activate` has already established that `sample_rate` is finite and positive and nothing more, so a
host claiming 1e300 Hz reaches the conversion. **A bare `@intFromFloat` is illegal behaviour out of
range**, which in a Debug build is a panic in the one function whose entire design is to refuse
rather than assert. Use `std.math.lossyCast`, verified in this toolchain at `std/math.zig:1331` to
compare against the bounds before casting and to saturate: an absurd rate becomes `maxInt(usize)`,
which `ceilPowerOfTwo` rejects as `error.Overflow` before allocating anything, and `activate` refuses
and logs.

| `sample_rate` | Samples requested   | `Ring.init`                | `activate`     |
| ------------- | ------------------- | -------------------------- | -------------- |
| 48 000        | 48 000              | 65 536, 256 KiB            | true           |
| 96 000        | 96 000              | 131 072, 512 KiB           | true           |
| 0.5           | 0                   | `error.EmptyCapacity`      | false, logged  |
| 1e300         | `maxInt(usize)`     | `error.Overflow`, no alloc | false, logged  |

**The capacity is deliberately not floored at `max_frames`.** `Ring.write` is already total against a
block longer than its capacity, documented at `src/dsp/ring.zig:136` and tested at
`src/dsp/ring.zig:420`, and nothing on the read side wants capacity ≥ one block. Taking that floor
would turn a host declaring an absurd `max_frames` from a harmless truncation into an eight-gigabyte
allocation and a refused activation, over a property no caller uses.

### `scratchBytes` stays zero, and that is now an answer

The tap's whole job is a `@memcpy` out of the host's own output buffer into storage `activate`
already owns, so no step between the two holds anything of its own. The zero-length fixed buffer is
still what turns any allocation on that path into `error.OutOfMemory` at the call site instead of a
heap call on the audio thread. The docstring has to stop saying phase 2 will fix this, because phase
2 is here and it did not.

## Changes

### `src/dsp/ring.zig`

1. Add `pub fn clear(self: *Ring) void` beside `write`, looping over a file-scope `silence: [256]f32`
   and calling `write` with it until a whole capacity has gone past. The docstring carries the
   reasoning above, in particular why this is not one `@memset` under one cursor store, since that is
   the version a later reader will be tempted to simplify it into and it is the version that shipped
   first and was wrong.
2. Update the module docstring at `src/dsp/ring.zig:36`. "This file has no caller yet" is now false,
   and the following sentence is half in the wrong tense.

### `src/clap/plugin.zig`

1. Import the module: `const ring = @import("../dsp/ring.zig");`, keeping the block alphabetical by
   binding name.
2. Add `history: ring.Ring = .{ .samples = &.{} }` to `Instance`, after `scratch`. The default
   matches what `Ring.deinit` leaves behind, so a never-activated instance and a deactivated one
   agree about the shape. The docstring should say the storage belongs to the *activation* rather
   than the instance because its size derives from `sample_rate`, and should note in one sentence
   that `deactivate` frees it on the main thread while, once #37 lands, a render thread may be
   reading it. That race is #37's to resolve and must not be papered over here.
3. In `activate`, allocate the ring after the scratch buffer. **The failure path needs an explicit
   undo**: a refused activation is not followed by `deactivate`, so it must free the scratch buffer
   and restore the empty slice itself, or a later `activate` assigns straight over a live pointer.
   Log with `print` rather than `message`, naming the rate and `@errorName(err)`, because `Overflow`
   and `OutOfMemory` demand opposite responses from whoever reads the host log.
4. Add `history_seconds` and `historySamples(sample_rate: f64) usize` next to `scratchBytes`, and
   rewrite `scratchBytes`'s docstring per the decision above.
5. In `deactivate`, add `self.history.deinit(self.allocator);` beside the scratch free.
6. In `reset`, call `self.history.clear();` and extend the docstring to record why, citing CLAP's
   "clears all buffers" wording.
7. **Rewrite the comment at `src/clap/plugin.zig:341`.** It currently promises "Phase 2 sizes the
   history buffer from it, at which point trusting the value is a write past the end of it". Both
   halves are now false: the ring is sized from `sample_rate`, and `Ring.write` is total against an
   oversized block. Do not size the ring from `max_frames` to rescue a comment. The honest
   justification is that `frames_count` bounds the `@memcpy` issued out of the host's own buffers on
   the host's word that they are that long.
8. Change `passThrough` to return `?[]const f32`: the output channel it wrote, or null. **Do not
   re-derive it in a second helper.** Each of that function's early returns is a host shape in which
   the output buffer was left exactly as the host handed it over, and a second copy of that reasoning
   could drift into recording uninitialised host memory as if it were audio. Add an
   `out.channel_count == 0` guard at the **bottom**, not folded into the early return, so
   `out.constant_mask = mask` still runs.
9. Add `fn tap(allocator: std.mem.Allocator, history: *ring.Ring, emitted: []const f32) void`
   between `passThrough` and `bit`. It takes an allocator it does not use, for the same reason
   `passThrough` does, and its body is one `history.write(emitted)`. It exists rather than being
   inlined into `process` because the one-channel decision and the `constant_mask` reasoning need a
   home and `process` is not it.
10. In `process`, hoist the allocator and call the tap:
    `if (passThrough(audio, ctx)) |emitted| tap(audio, &self.history, emitted);`

### `constant_mask` is confirmed unchanged

The vendored header at `include/clap/audio-buffer.h:20` is explicit: "checking the constant mask is
optional, and this implies that the buffer must be filled with the constant value", and "the constant
mask is a hint". So the buffer holds `frames_count` valid samples regardless, and the tap copies it
verbatim. Honouring the flag would freeze the trace whenever a track went quiet, and worse, would
stop the cursor advancing with the stream, so every window read afterwards would be misaligned in
time. That reasoning belongs as a comment in `tap`.

## Tests

`zig build test` is a Debug build, so `std.debug.assert` is live throughout. Reading the ring inside a
test is in scope: the issue's "out of scope: anything that reads the buffer" is about the render
thread, and `Ring.read` takes `*const Ring`, so no new API is needed to observe what the tap wrote.

### In `src/dsp/ring.zig`

- `clear publishes a whole capacity of silence` — write a ramp into a capacity of 8, `clear`, then
  `written()` has advanced by 8 and every window reads as zeroes; a following write of two samples
  reads back `{0, 0, 9, 10}`.
- `clear spans a capacity larger than one chunk` — a ring four chunks wide, so the loop runs more
  than once. Every other capacity here is under one chunk, so without this the loop is only ever
  exercised with a single iteration and a clear that stopped after its first chunk would pass.
- `clear leaves nothing of the samples it overwrote` — a capacity of one, the degenerate mask.
- Extend `the coherence check is exact at its boundary` with the clear's shape:
  `!coherent(100, 108, 8, 1)`. A clear's total advance is the whole capacity, so a reader that
  observes the whole of one is reported torn. Note what this test does **not** show, which is the
  trap the first implementation fell into: it says nothing about a reader that observes no cursor
  movement at all, which is why the clear has to publish as it goes rather than once at the end.

### In `src/clap/plugin.zig`

Sizing and lifecycle, placed beside the existing `activate` refusal test:

- `activate sizes the history from the sample rate and reports the rounded capacity` — 48 kHz gives
  65 536, 96 kHz gives 131 072. **96 kHz specifically**, because 44.1 kHz also rounds to 65 536, so a
  build that ignored `sample_rate` and hardcoded one second at 48 kHz would pass a 44.1 kHz check.
- `deactivate frees the history and a later activate resizes it` — capacity is 0 after `deactivate`,
  and after re-activating at 96 kHz both the capacity and `written() == 0` hold. The second half
  matters more than it looks: `Ring.deinit` does not touch the cursor, so this only passes because
  `activate` assigns a whole fresh `Ring`. A stale cursor over fresh storage would make `read` report
  a full second of silence as if it were audio.
- `activate refuses when the history cannot be allocated` — `std.testing.FailingAllocator` threaded
  through `create`. **Derive the index rather than hardcoding it**: set `state.fail_index =
  state.alloc_index` after `create` returns, because `scratchBytes` returns 0 and a zero-byte `alloc`
  short-circuits before reaching the vtable, so the count is 1 today and would rot silently.
  Assert `has_induced_failure`, which is what separates "refused because the allocation failed" from
  "refused because validation rejected the rate".
- `activate refuses a sample rate too large to size a history from` — `std.math.floatMax(f64)`.
  Without the saturating cast this test does not fail, it panics, which is itself the demonstration.
  Do not add a mid-range case like 1e12: that saturates to a real four-terabyte request and makes the
  run's cost depend on how the OS declines it.

The tap:

- `process taps the left output channel into the history` — fill the inputs at bases 100 and 200, and
  assert `written() == test_frames` and the window equals `in_samples[0]`. The bases are far enough
  apart that the right channel and the sum both fail the same assertion, so one comparison pins
  "left", "not right" and "not summed" at once.
- `repeated process calls extend the history rather than restarting it` — three blocks, a continuous
  ramp read back. The single-call test passes equally well against a tap that rewinds the cursor.
- `the tap reads the output bus rather than the input the host handed over` — wire with
  `in_channel_count = 0` and a filled `in_samples[0]`. This is the only shape where the two buffers
  hold different values and both are readable, so it is the only test that can tell the two apart.
- `a block the host flagged constant is tapped in full rather than skipped` — two phases: a silent
  constant block advances the cursor with zeroes, then a constant block of `0.5` reads back as eight
  copies of `0.5`, not one followed by seven zeroes.
- `an output bus declaring no channels leaves the history where it was` — the guard from change 8.
  `passThrough`'s loops are both bounded by `out.channel_count`, so this is the first code to assume
  channel 0 exists. The fixture holds two live pointers, so a missing guard would not crash here; it
  would silently tap a channel the host never offered and crash only in a real host.
- `a zero-frame block leaves the history where it was` — `Ring.write` no-ops on an empty slice, but
  `to[0..0]` on a null `data32` does not, so the guard has to come first.
- `reset publishes a capacity of silence rather than clearing behind the cursor` — process a ramp,
  `reset`, then `written()` has advanced by `capacity()` and every window reads as zeroes; process
  again and the newest samples are the new block.

Extend rather than duplicate, since the setups are identical: the in-place test gains the tap
assertions; `process silences the output when the input is unusable` gains `written() == test_frames`
and an all-zero window for all three shapes (all three **do** advance, which is decision 2 working);
`process survives a missing output bus` gains `written() == 0`, which is the one unusable-bus shape
that does not advance; and the null-context and oversized-block tests each gain `written() == 0`.

## Documentation

- `src/main.zig:65` — delete the three-line "Reached from nowhere at all yet" comment. **Keep the
  `_ = @import("dsp/ring.zig")` line.** It looks redundant once `plugin.zig` imports the module and it
  is not: `_ = plugin;` does not transitively collect a dependency's tests, which is exactly why
  `clap/gui.zig`, `clap/log.zig` and `clap/state.zig` are all listed there despite `plugin.zig`
  importing every one at file scope. Removing it silently drops every ring test from the run.
- `AGENTS.md:153` — "`src/dsp/ring.zig` is in that state until its first caller lands" stops being
  true. Keep the worked example and date it rather than deleting it, since the gotcha loses its teeth
  without one. `CLAUDE.md` is a symlink to `AGENTS.md`; edit only `AGENTS.md`.
- `.github/zig.instructions.md:24` — the rule stays correct in the abstract, but this change creates
  a new false positive it does not cover: a reviewer now sees the module imported in both places and
  concludes the test-block import is dead. Extend the bullet to say it is not.
- `CHANGELOG.md` — one entry at the top of `### Added`, in the house voice, naming the four
  decisions and the coverage side effect below.
- `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md:182` — name what was settled,
  since phases 3 and 4 read that table to learn what shape the data is in. The "two mechanisms
  already exist" paragraph at line 188 needs no correction: it is a claim about what existed before
  step 2, which time cannot falsify.
- `src/clap/plugin.zig:819` — `TestBuses`'s docstring predicts that a corner-cutting fixture "would
  quietly stop testing anything the moment the signal tap in phase 2 starts reading a field it had
  left null". That is now past tense, and the zero-channel test is the case where it came true.
- `docs/plans/done/2026-08-19-lock-free-circular-history-buffer.md` — **do not edit.** Completed plans
  are historical records, and that file already dates its own obsolescence at line 184. The accounting
  belongs here and in the PR.

## Verification

```bash
zig build                 # now fails on a type error in dsp/ring.zig; before, it did not
zig build test
zig fmt --check build.zig src/
typos
```

### The `fba.end_index == 0` assertion, broken deliberately

The issue asks for this, and **the obvious experiment produces a false negative.** With `scratchBytes`
returning 0 the scratch slice is empty, so a `FixedBufferAllocator` over it fails every request and
`end_index` cannot move no matter what the tap does. Adding an allocation alone proves nothing. Two
demonstrations, both reverted:

1. **The assertion is live and reached.** Change it to `fba.end_index == 1` and run `zig build test`.
   Expect a panic rather than a failed expectation, with a frame at `process`, and the run stopping
   at the first test in file order that calls `process`.
2. **The assertion catches a real allocation.** Make `scratchBytes` return 64 *and* add
   `_ = allocator.alloc(u8, 16) catch {};` inside the tap. Expect the same panic with `end_index` at
   16. `the audio path is handed an allocator that cannot reach the heap` fails first, on
   `self.scratch.len == 0`; that is the harness noticing the configuration changed, not a second
   defect.

Also break one tap assertion once, on the precedent that a check nobody has watched fail is not a
check: change the expected channel from `in_samples[0]` to `in_samples[1]` and confirm the mismatch
names 200 against 100. Without it, tests comparing zeroes against zeroes pass whether or not the ring
is being written at all.

### What this closes, and what it does not

`src/dsp/ring.zig` stops being a module only the test build type-checks. `plugin.zig` importing it at
file scope means `Build`, `clap-validator` and `clap-wrapper` cover it for the first time, which
closes the gap recorded at `docs/plans/done/2026-08-19-lock-free-circular-history-buffer.md:184`. To
confirm rather than assume, put a type error in `ring.zig` and run a plain `zig build`: it produced a
binary before and must fail now. The build cache cannot answer this, because a manifest lists the
files the compiler read, not the ones it checked.

`clap-validator` also becomes a real carrier for these assertions, since CI builds Debug and the
validator drives `activate`/`process`/`deactivate` at its own rates and block sizes with every
assertion live. It checks no leaks, so a `deactivate` that forgot to free would still pass there.

**The memory-ordering gap stays open and belongs to #37.** Every test here is single-threaded, so
replacing `write`'s release store with `.monotonic` still passes all of them. The PR should say so
rather than let a larger green count imply otherwise, and should state what was *read* for the
no-locks, no-syscalls claim: `tap` calls `Ring.write` and `Ring.clear`, which between them reach
`@memcpy`, `@memset` and `std.atomic.Value` load and store, and nothing else.

### What was run in REAPER, and what was deliberately deferred

One manual run is worth it for a reason no automated check covers: this is the first code here to run
on a real audio thread doing more than a `@memcpy` between the host's own buffers, and a dropout is
audible where nothing in CI can hear it. Install with `zig build install-plugins` and trust the hashes
it prints, not the build you think you made.

**Run, against the Debug build at `bbeab3c26442`, hash-confirmed against `zig-out`:** the pass-through
is still transparent, which is what `passThrough` changing signature to return the tapped slice put at
risk. And repeated transport locates during playback produce no clicks or dropouts, which is the only
genuinely new audio-thread cost in this issue: `reset` memsets 256 KiB at 48 kHz.

**Deferred to later in the phase, deliberately rather than forgotten.** None of it guards a risk this
issue introduces on its own, which is why it can wait, but the list should not evaporate:

| Deferred                                      | What it would cover                                                       |
| --------------------------------------------- | ------------------------------------------------------------------------- |
| 32- or 64-frame blocks, and 96 kHz            | The `reset` memset against the tightest deadline and at double the size   |
| Ten or more device changes, watching RSS      | `activate`/`deactivate` on `c_allocator`, which no test reaches           |
| A mono track                                  | The narrower-input path and the `out.channel_count` guard, in a real host |
| Ten or more instances, then removing them all | Per-instance allocation and teardown at scale                             |
| An offline render                             | A second activation at a different block size                             |
| A `--release=fast` pass                       | The build that ships, where every assertion above is gone                 |

The leak-checking gap is the one worth remembering: `zig build test` uses `testing.allocator` and the
plugin uses `std.heap.c_allocator`, so the production allocator is covered by nothing in this
repository, and a `deactivate` that forgot to free would pass every check that currently exists.

## Out of scope

Anything that reads the buffer. The render-thread trailing-window read, the per-frame vertex buffer
and the new operation on `gpu/iface.zig` are all #37, and the trace itself is
[#38](https://github.com/cboone/fosforo/issues/38).

The second channel, and with it the X-Y vectorscope. Two `Ring`s sharing nothing is the shape when
that arrives; nothing here forecloses it.

The `deactivate` race. Freeing the ring on the main thread while a render thread reads it is real and
is named in #37, which also floats giving the storage the instance's lifetime rather than the
activation's. There is no reader yet, so there is nothing to race with today.

## Commits

1. `feat: publish a capacity of silence on clear (#36)` — `Ring.clear` and its tests.
2. `feat: tap the audio thread into the history buffer (#36)` — the plugin wiring and its tests.
3. `docs: record the history buffer's first caller (#36)` — the stale-comment sweep, `AGENTS.md`,
   `.github/zig.instructions.md`, the changelog and the phase-2 table.
