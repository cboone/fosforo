# Lock-free circular history buffer

Issue [#35](https://github.com/cboone/fosforo/issues/35). Plan: `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`, phase 2, step 1.

## Context

Phase 1 closed with a plugin that loads, opens an editor, and renders a dim cleared drawable at vsync. It does nothing with audio beyond copying it. Phase 2's goal is a visible trace that follows the signal, and [ADR 0010](../../adr/0010-lock-free-history-buffer.md) settles the structure that connects the audio thread to the render thread: a circular history buffer carrying one monotonically increasing write cursor. Not a queue. A scope wants the most recent window and is perfectly happy to overwrite everything older, so "deliver every item exactly once" is a property that costs complexity to provide and that nothing here wants.

This issue is the container alone, in `src/dsp/ring.zig`, with no caller. That separation is the point rather than an accident of sequencing: it is the only part of phase 2 that needs neither a GPU nor a window server nor a host, so it is the only part that can be tested properly instead of verified by opening the plugin in REAPER and looking at it. Issues [#36](https://github.com/cboone/fosforo/issues/36) (the audio-thread write) and [#37](https://github.com/cboone/fosforo/issues/37) (the render-thread read) are the callers, and both depend on this landing first.

The intended outcome is a fixed-capacity ring over `f32` that allocates once, never resizes, publishes a cursor with release semantics on the write side, reads a trailing window relative to an acquire load on the read side, and reports when the margin the whole design rests on has not held.

## The three decisions the issue asks for

All three are settled here so the implementation does not relitigate them, and each gets its reasoning in a comment beside the code rather than only in this file.

### Capacity rounds up to a power of two

`init` rounds the requested sample count up with `std.math.ceilPowerOfTwo` and reports the rounded figure as the capacity, so the wrap is `cursor & (capacity - 1)` in a single private helper rather than a modulo in two places.

The comment must be honest about why, because the obvious reason is not the real one. For `write` and `read` as specified below, the division would have been fine: both wrap at most twice per call, since each is at most two `@memcpy`s, so the cost is a handful of 64-bit divisions per audio block and per frame. The real argument is phase 4's triggering, which scans backward sample by sample looking for a threshold crossing and is the first caller where the wrap is per-sample rather than per-call. Choosing the mask now means that caller is not the moment the choice gets revisited.

The cost is a bounded rounding on an allocation made once per activation:

| Sample rate | Requested | Rounded | Duration | Bytes   |
| ----------- | --------- | ------- | -------- | ------- |
| 44100       | 44100     | 65536   | 1.486 s  | 256 KiB |
| 48000       | 48000     | 65536   | 1.365 s  | 256 KiB |
| 96000       | 96000     | 131072  | 1.365 s  | 512 KiB |
| 192000      | 192000    | 262144  | 1.365 s  | 1 MiB   |

Next to phase 3's ping-pong `RGBA16F` accumulation textures, which are megabytes each and reallocated on every resize, this is not a quantity worth optimising.

### A read before the buffer has filled is zero-padded at the front

A scope opened before playback starts hits this on its very first frame, so it is a normal case rather than an edge one. The window is filled oldest first, and the front of it is zeroed for however many samples have not been written yet, which draws as a flat line that fills in from the right. That is the correct picture rather than a degraded one.

It is done explicitly, by computing what is available and memsetting the shortfall, not by relying on the backing array's zero fill. The array is zeroed at `init` anyway, but that makes the padding belt and braces rather than load-bearing, which is the difference between a property the code states and one a reader has to reconstruct.

The same rule covers a window longer than the whole capacity: the front is zeroed and the ring supplies the rest.

### The margin is reported per read, not assumed

ADR 0010's argument for having no seqlock retry loop is that capacity is on the order of a second while any display window is tens of milliseconds, so the producer cannot realistically lap the consumer between publishing the cursor and the consumer finishing its copy. That argument is sound and it is also the single assumption the whole structure rests on, so `read` checks it rather than asserting it in a build where the assertion is compiled out.

`read` snapshots the cursor, copies, re-loads the cursor, and returns whether the producer overwrote any of the window during the copy. One extra atomic load and one comparison. It does not retry, so ADR 0010's decision stands exactly as written; what changes is that a torn window becomes something [#37](https://github.com/cboone/fosforo/issues/37)'s caller can count, in the same way `Editor.framesPresented` turned "the loop is running" and "the loop is drawing" into two separable claims.

Not an assertion, for the reason the repository already applies at every other trust boundary (`activate`'s sample rate, `process`'s frame count, `clampAxis`'s wrapped dimension): an assertion is compiled out of exactly the build where the problem does damage, and this project runs its tests and its releases under `ReleaseFast`.

## The module

`src/dsp/ring.zig`, a new `src/dsp/` directory, matching the source layout the build plan already records.

```zig
pub const Ring = struct {
    /// The backing array. Its length is the capacity and is always a power of
    /// two, which is what makes the wrap a mask.
    samples: []f32,

    /// Samples ever written. Monotonic, never reset, and the one thing that
    /// crosses between the two threads.
    cursor: std.atomic.Value(u64) = .init(0),

    pub const InitError = error{ EmptyCapacity, Overflow } || std.mem.Allocator.Error;

    /// [main-thread] Allocated once by its owner and never resized.
    pub fn init(allocator: std.mem.Allocator, minimum_capacity: usize) InitError!Ring;

    /// [main-thread]
    pub fn deinit(self: *Ring, allocator: std.mem.Allocator) void;

    /// The rounded capacity, which is what the caller actually got.
    pub fn capacity(self: *const Ring) usize;

    /// [thread-safe] Samples ever written, by an acquire load.
    pub fn written(self: *const Ring) u64;

    /// [audio-thread] Publishes the cursor once per call, not once per sample.
    pub fn write(self: *Ring, input: []const f32) void;

    /// [render-thread] Fills `dst` with the most recent `dst.len` samples,
    /// oldest first. Returns false if the producer lapped the window during
    /// the copy, leaving `dst` torn.
    pub fn read(self: *const Ring, dst: []f32) bool;
};
```

Nothing allocates below `init`, and neither `write` nor `read` takes an allocator, because neither has anything to allocate. `read` takes `*const Ring` rather than `*Ring`, which `std.atomic.Value.load` permits and which states that the consumer mutates nothing.

### `init`

Refuse a zero capacity explicitly rather than letting `std.math.ceilPowerOfTwo` assert on it, on the compiled-out-in-release reasoning above. Let the rounding's own `error.Overflow` propagate. `@memset` the backing array to zero after allocating.

### `write`

Load the cursor `.monotonic` (the producer is its only writer, so this is uncontended and needs no ordering of its own), copy, then `store(at + input.len, .release)`. The release store is the publication, and it happens once per call.

An input longer than the capacity keeps only its newest `capacity` samples and still advances the cursor by the whole input length, so the invariant "the ring holds the newest `capacity` samples ending at the cursor" is true in every case rather than in the expected one.

The oversized case needs no second code path, but it does need the base index computed rather than assumed. The surviving samples start at cursor position `at + (input.len - src.len)`, which is `at` whenever the input fits and skips the discarded head when it does not. Writing them at `at & mask` instead would be wrong: `(at + input.len - capacity) & mask` equals `at & mask` only when `input.len` is itself a multiple of the capacity, so an oversized block would land rotated and every subsequent read would return the right samples in the wrong order.

The copy itself is at most two `@memcpy`s, split at the end of the backing array.

### `read`

```zig
const at = self.cursor.load(.acquire);
const available = @min(at, capacity);              // before the first lap, the cursor itself
const copied = @min(dst.len, available);
@memset(dst[0 .. dst.len - copied], 0);            // the zero pad, at the front
// ... at most two @memcpy into dst[dst.len - copied ..], oldest first
return coherent(at, self.cursor.load(.acquire), capacity, copied);
```

The window ends at the snapshot rather than at whatever the cursor reached during the copy, so two reads taken from the same cursor value return the same samples. The coherence predicate is a pure function, split out and tested exactly, the way `Meter.observe` takes the time rather than reading it:

```zig
/// The copied samples occupied the `copied` slots ending at `snapshot`, so the
/// producer has overwritten one of them exactly when it has advanced further
/// than the `capacity - copied` slots that were free in front of it.
fn coherent(snapshot: u64, now: u64, capacity: usize, copied: usize) bool {
    return now - snapshot <= capacity - copied;
}
```

The subtraction is safe without saturation because the cursor is monotonic and single-writer, so `now >= snapshot` always. `copied <= capacity` is guaranteed by the `available` clamp above, which is what keeps the right-hand side from underflowing.

A copy of zero samples is coherent unconditionally and needs its own case. That is the read of a ring the producer has not reached yet, whose window is entirely the zero pad: the pad is arithmetic rather than shared memory, so nothing in it can be overwritten. Without the case the check measures the producer's whole run against the capacity and reports a tear in a window with nothing in it to tear.

## Wiring, which is easy to miss

`src/main.zig`'s `test` block names every module that nothing else reaches, and this one has no caller at all until [#36](https://github.com/cboone/fosforo/issues/36). Without `_ = @import("dsp/ring.zig");` there, `zig build test` collects none of the tests below and passes, which is the failure mode this whole issue exists to avoid.

## Tests

All in `src/dsp/ring.zig` under the `// Tests` banner the other modules use, with `const testing = std.testing;`. The four the issue names, plus what the specification above makes reachable:

| Test                                                 | What it pins down                                                          |
| ---------------------------------------------------- | -------------------------------------------------------------------------- |
| Wrapping at the seam                                 | A write straddling the end of the backing array reads back contiguous      |
| A read longer than what has been written             | Zeroes at the front, samples at the back, oldest first                     |
| A read of exactly the capacity                       | The boundary case where the pad is empty and the copy is the whole array   |
| A read longer than the whole capacity                | A non-empty pad and a full-capacity copy agreeing about where they meet    |
| A cursor advanced past the capacity many times over  | The newest window is correct after many laps, and `written` agrees         |
| A write longer than the capacity                     | Only the newest `capacity` samples survive, and the cursor advances by all |
| A capacity of one                                    | The degenerate shape, where the mask is zero and every index collapses     |
| `init` rounds a non-power-of-two request up          | `capacity` reports what was allocated, not what was asked for              |
| `init` refuses a zero request and an overflowing one | Refusal rather than an assertion the shipped build would not carry         |
| A read of a fresh ring                               | All zeroes, and reported coherent                                          |
| A zero-length write and a zero-length read           | Both no-ops, and neither disturbs the cursor                               |
| `coherent` at and past its boundary                  | Equality is coherent; one sample past it is not                            |
| `coherent` with nothing copied                       | An empty window cannot be torn, however far the producer ran               |

Ordering is checked with a monotonically increasing test signal, so oldest-first is verifiable rather than plausible.

**No threaded test.** Two threads racing on arm64 with correct acquire/release would assert the scheduler rather than the protocol, and would essentially never fail even against ordering that is wrong. What the protocol makes observable is `read`'s coherence report, and that is tested directly through its predicate.

## Documentation

- `CHANGELOG.md`, under `## [Unreleased]` → `### Added`: one entry in the existing house style, prose with the reasoning and an issue link.
- `AGENTS.md`, the `Structure` tree: add `dsp/ring.zig` with a one-line description, matching the annotations already on every other file there.

No new ADR. ADR 0010 already decided this and nothing here supersedes it; the three decisions above are implementation choices within it, which is what code comments are for.

## Verification

```bash
zig build test
zig fmt --check build.zig src/
markdownlint-cli2
typos
```

`zig build test` covers everything this issue can cover without a caller. No host, no GPU, no window; that is the reason it exists as its own unit.

**Verify the instrument before trusting the result.** A module that nothing imports contributes no tests and reports no failure, so a green `zig build test` is not by itself evidence that any of the above ran. Break one assertion in `src/dsp/ring.zig` deliberately, confirm `zig build test` goes red, and restore it. That is the same reasoning that made `Editor.framesPresented` necessary: a check nobody has watched fail is not a check.

### What `zig build test` does not reach, and where it gets reached

Three gaps, recorded rather than papered over.

**The memory ordering is verified by reading.** Every test here is single-threaded, so nothing executes `write` and `read` on two threads at once. The tests therefore cannot discriminate a correct ordering from an incorrect one: replacing the `.release` store in `write` with a `.monotonic` one passes all of them, and would very likely pass in a host too, surfacing much later as rare visual corruption. Thread Sanitizer is not the way out either. Zig 0.16 accepts `-fsanitize-thread` and links a binary on `aarch64-macos` that segfaults on startup, so it is unavailable here rather than merely awkward. **This is deferred to [#37](https://github.com/cboone/fosforo/issues/37)**, where a known signal drawn on screen during playback is the first check that can tell the two apart. A threaded stress test is still the wrong answer, for the reason above: it would assert the scheduler.

**A plain `zig build` never analyzes this module.** The only import is inside a `test` block, and Zig analyzes those only in a test build. Verified rather than assumed, because a build-cache manifest records the files the compiler *read* and cannot distinguish those from the ones it *checked*: an isolated two-file reproduction compiles a binary successfully with a type error sitting in a test-only import. So the `Build`, `clap-validator`, and `clap-wrapper` CI jobs give `src/dsp/ring.zig` no coverage at all, and only the `Test` job does. This stops being true when [#36](https://github.com/cboone/fosforo/issues/36) imports it from `src/clap/plugin.zig`.

**The real-time discipline is a claim about the call graph.** `write` allocates nothing, takes no lock, and makes no syscall, and nothing asserts that; reading it is the available check. [#36](https://github.com/cboone/fosforo/issues/36) is where the property becomes load-bearing, since that is where `process` starts calling it.

## Out of scope

- **Min/max decimation** (`src/dsp/decimate.zig`). Nothing needs it until a window holds more samples than the drawable has pixels, and phase 2's trace is deliberately crude.
- **Anything about the audio thread or the renderer.** [#36](https://github.com/cboone/fosforo/issues/36) and [#37](https://github.com/cboone/fosforo/issues/37) are separate precisely so this one stays testable in isolation.
- **The window duration and the capacity's duration.** Both belong to the owner. `init` takes a sample count; how many seconds that is, and where the number comes from, is [#36](https://github.com/cboone/fosforo/issues/36)'s decision.
- **Multi-channel.** One tapped channel is what phase 2 draws, and whether the second is stored separately or summed is a question for the tap. The container's shape constrains the answer without settling it: a second channel is a second `Ring` sharing nothing, or a widened element type, and neither is decided here.
- **A per-sample accessor.** Phase 4's triggering is its first caller. The mask chosen above is what makes it cheap when it arrives; adding it now would be an operation with nothing to exercise it.

## Commits

Two were planned. Six landed, and the four unplanned ones all came from asking what had actually been verified rather than what had been run:

1. `feat: add the lock-free circular history buffer` — `src/dsp/ring.zig` and the `src/main.zig` test wiring.
2. `docs: record the history buffer in the changelog and structure` — `CHANGELOG.md` and `AGENTS.md`.
3. `test: cover the two read paths the docstring claimed but nothing exercised` — a read longer than the whole capacity against a full ring, and the degenerate capacity of one. Both passed first time; they moved two claims from traced-by-hand to executed. This commit also carries the `EmptyCapacity` comment correction below, which its message does not mention.
4. `docs: correct what the default test and build paths actually do` — `zig build test` is Debug rather than ReleaseFast, an error this file's module comment had inherited from `src/clap/state.zig`. Plus the AGENTS.md gotcha for that and for the test-only import that a plain `zig build` never type-checks.
5. `chore: stop typos reading abbreviated git SHAs as words` — the pin `91f9abd` contains `abd`, in two completed plans that are records rather than prose to correct.
6. `docs: record the verification gaps this issue leaves to #37` — the section above.

The two decisions the issue asked for were settled before any code was written, and neither moved. What moved was the confidence attached to the result, which is the part worth noticing: every check was green at commit 2, and three of the four findings above were still there.
