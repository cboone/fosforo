//! The race harness: the only thing in this project that runs `Ring.write` and
//! `Ring.read` on two threads at once.
//!
//! `src/dsp/ring.zig` publishes its cursor with a release store and reads it
//! with an acquire load, and that pairing is the whole of ADR 0010's protocol
//! between the audio thread and the render thread. Every test of that module is
//! single-threaded, so replacing the release with a `.monotonic` store passes
//! all of them. This harness is what notices. See ADR 0016.
//!
//! **It judges by Thread Sanitizer's verdict, never by whether corruption
//! appeared.** That distinction is the reason this exists at all. A stress test
//! that races two threads and checks the output measures how often this machine
//! reorders, which is a property of the hardware and the day: a passing run says
//! nothing and a failing run does not reproduce. TSan does not look for
//! corruption. It builds a happens-before graph from the atomic operations it
//! observes and reports a data race when two threads reach the same address with
//! no edge between them. A release store paired with an acquire load is that
//! edge; a `.monotonic` store is not. The verdict is a property of the code and
//! it does not depend on the scheduler doing anything in particular.
//!
//! Two arms, each its own process, because one of them must fail:
//!
//!     ring      the real `Ring`, on two threads      must be CLEAN
//!     weakened  the same access pattern with the     must be FLAGGED
//!               publishing store relaxed
//!
//! The second is the negative control, and it is not decoration. Everything the
//! first arm proves is an absence, and a search for absence succeeds for the
//! wrong reason when the instrument is not running. An unlinked runtime, an
//! uninstrumented `@memcpy`, a `pthread_create` TSan never saw, a job that built
//! the wrong module: each of those makes both arms come back clean, and only the
//! control can tell that apart from a correct ring. `scripts/ring-race-check`
//! therefore judges the control first and refuses to read anything into the
//! ring's result until it has passed. That is `scripts/smoke-leak-check`'s
//! ordering, for the same reason.
//!
//! **The writer stops short of lapping the reader, by construction rather than
//! by margin.** `Ring.read` deliberately tolerates a producer that laps it
//! mid-copy and reports it through `coherent` instead of preventing it. On that
//! path the reader genuinely reads slots the writer is concurrently writing with
//! nothing ordering them, which is a data race in the model TSan implements: the
//! well-known seqlock limitation, and it would make the ring arm fail at random.
//! So the writer emits at most `capacity - window_samples` samples over the whole
//! run and can never reach the reader's slots, however badly either thread is
//! scheduled. A ratio would not do, because a descheduled reader breaks any
//! ratio and TSan slows everything down on a runner that is already noisy.
//!
//! That bound costs nothing of what is being verified. The edge under test is
//! cursor-store to cursor-load, and every read exercises it: the reader acquires
//! a cursor the writer released and copies the slots that store published.
//! Wrapping is index arithmetic and `src/dsp/ring.zig` tests it exactly, with
//! one thread, which is the right way to test arithmetic.
//!
//! **An executable rather than a test artifact**, on `src/smoke.zig`'s
//! precedent and for its reasons: a test binary has to stay silent, and a check
//! that cannot say what it was doing is worth much less than one that can. Never
//! wired into `zig build test`, which must not acquire a dependency on the host
//! being able to run Thread Sanitizer at all (ADR 0009, ADR 0013).

const std = @import("std");

const ring = @import("dsp/ring.zig");

/// Samples of storage, and the reason the writer can be bounded.
///
/// Large enough that `capacity - window_samples` is still a long run, which is
/// what keeps the bound above from costing coverage. Nothing wraps at this size,
/// deliberately: the cursor stops below the capacity, so `Ring.index` is the
/// identity throughout and the arms differ in ordering and in nothing else.
const capacity: usize = 1 << 20;

/// The trailing window a read asks for, matching what `gui.windowSamples`
/// yields at 48 kHz, so the shape under test is the shape that ships.
const window_samples: usize = 960;

/// A typical audio block, matching what `clear` writes and what a host hands
/// `process`.
const block_samples: usize = 256;

/// Blocks the writer emits before stopping.
///
/// Floored so the total stays at or under `capacity - window_samples`. This is
/// the bound the module docstring rests on, computed rather than written down,
/// so changing the capacity or the window cannot silently invalidate it.
const write_blocks: usize = (capacity - window_samples) / block_samples;

/// Windows the reader validates before stopping.
///
/// Bounded because every read copies `window_samples` samples and TSan
/// instruments each one. This is what keeps the arm to a few million tracked
/// accesses rather than however many a spin loop would produce.
const target_reads: u64 = 4096;

/// How many reads may happen before the arm gives up.
///
/// Slack rather than a budget: with the wait below in place every attempt that
/// gets as far as a copy validates, so this is only reachable if the producer
/// laps and every read comes back torn.
const max_attempts: u64 = target_reads * 4;

/// How long the reader waits for the writer's first window before giving up.
///
/// Only reachable if the writer never publishes, which would be a defect in the
/// harness rather than a finding about the ring. Generous by any measure, since
/// the writer needs four blocks to fill one window, and still small enough that
/// hitting it fails in seconds. A bound large enough to run for minutes would
/// make that failure read as a wedged job rather than as a failed one, which is
/// the harder thing to diagnose from a CI log.
const max_spins: u64 = 1 << 28;

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = init.args.iterate();
    _ = args.next();

    const arm = args.next() orelse return usage();

    if (std.mem.eql(u8, arm, "ring")) return report("ring", ringArm());
    if (std.mem.eql(u8, arm, "weakened")) return report("weakened", weakenedArm());

    return usage();
}

fn usage() u8 {
    say(
        \\usage: fosforo-ring-race ring
        \\       fosforo-ring-race weakened
        \\
        \\  ring      the real Ring on two threads; Thread Sanitizer must find nothing
        \\  weakened  the same pattern with the publishing store relaxed; TSan must find a race
        \\
        \\Run both through scripts/ring-race-check, which judges them in the order
        \\that makes the first one's silence mean something.
    , .{});
    return 2;
}

/// The exit-code discipline, in one place, matching `src/smoke.zig`.
///
/// Zero for an arm that ran as expected, 1 for one that ran and failed, 2 for
/// being called wrong. Note that a passing **weakened** arm still exits non-zero
/// overall, because Thread Sanitizer replaces the status with its own `exitcode`
/// when it has reported anything. That is the intended result there, and the
/// reason `scripts/ring-race-check` reads the output rather than only the status.
fn report(arm: []const u8, result: anyerror!Counters) u8 {
    const counters = result catch |err| {
        say("ring-race: {s} FAILED: {s}", .{ arm, @errorName(err) });
        return 1;
    };

    // The overlap statistic, printed rather than merely counted. A clean arm
    // whose reader never saw a sample the writer produced would be a vacuous
    // pass, and this line is what lets the script rule that out from outside.
    say("ring-race: {s} reads={d} validated={d} torn={d} published={d}", .{
        arm,
        counters.attempts,
        counters.validated,
        counters.torn,
        counters.published,
    });
    say("ring-race: {s} ok", .{arm});
    return 0;
}

/// Everything this harness says, on stderr, as `src/smoke.zig` does.
fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// What an arm reports about itself.
const Counters = struct {
    /// Reads attempted, including the ones that found nothing to validate.
    attempts: u64 = 0,

    /// Windows that carried at least one sample the writer produced, and that
    /// validated. The number that makes a clean result mean something.
    validated: u64 = 0,

    /// Windows the producer lapped mid-copy. Must be zero: the writer is bounded
    /// so this cannot happen, and a non-zero count means that bound broke and the
    /// run is void rather than passing.
    torn: u64 = 0,

    /// The cursor when the writer stopped.
    published: u64 = 0,
};

const ArmError = error{
    /// A window came back with something other than the writer's ramp in it.
    CorruptWindow,

    /// The writer laps the reader, so the harness's premise no longer holds and
    /// Thread Sanitizer would be reporting a race this project accepts by design.
    WindowTorn,

    /// The reader ran out of attempts without validating enough windows, which
    /// is a defect in the harness rather than a finding about the ring.
    ProducerStalled,
};

// ---------------------------------------------------------------------------
// The arms
// ---------------------------------------------------------------------------

/// The real thing. Thread Sanitizer must find nothing here.
fn ringArm() !Counters {
    var buffer = try ring.Ring.init(std.heap.page_allocator, capacity);
    defer buffer.deinit(std.heap.page_allocator);

    return drive(ring.Ring, &buffer);
}

/// The negative control. Thread Sanitizer must find a race here.
fn weakenedArm() !Counters {
    const samples = try std.heap.page_allocator.alloc(f32, capacity);
    defer std.heap.page_allocator.free(samples);
    @memset(samples, 0);

    var buffer: Weakened = .{ .samples = samples };
    return drive(Weakened, &buffer);
}

/// One writer on this thread and one reader on another, over any buffer that
/// answers `write` and `read`.
///
/// Generic so the two arms cannot drift apart. The loop bounds, the block size,
/// the window size and the validation are shared by construction, which is what
/// makes the ordering of the publishing store the single variable between them.
fn drive(comptime Buffer: type, buffer: *Buffer) !Counters {
    var consumer: Consumer(Buffer) = .{ .buffer = buffer };

    // The reader starts before the writer has published anything, which is the
    // ordinary case in the plugin too: an editor opened before playback begins.
    const reader = try std.Thread.spawn(.{}, Consumer(Buffer).run, .{&consumer});

    var block: [block_samples]f32 = undefined;
    var written: usize = 0;
    while (written < write_blocks * block_samples) : (written += block_samples) {
        for (&block, 0..) |*sample, offset| sample.* = value(written + offset);
        buffer.write(&block);
    }

    reader.join();

    if (consumer.corrupt) return ArmError.CorruptWindow;
    if (consumer.counters.torn != 0) return ArmError.WindowTorn;
    if (consumer.counters.validated < target_reads) return ArmError.ProducerStalled;

    var counters = consumer.counters;
    counters.published = buffer.written();
    return counters;
}

/// The reader thread, and the only place `read` is called.
fn Consumer(comptime Buffer: type) type {
    return struct {
        const Self = @This();

        buffer: *const Buffer,
        counters: Counters = .{},
        corrupt: bool = false,

        /// Every field above is written here and read by `drive` after `join`,
        /// which is what orders them. Nothing touches them in between.
        fn run(self: *Self) void {
            var window: [window_samples]f32 = @splat(0);

            // Wait once for a full window, so the loop below never spends an
            // instrumented copy discovering there is nothing there yet.
            //
            // **Once, and outside the loop, and that is load-bearing rather than
            // tidy.** `written()` is itself an acquire load, so performing it
            // every iteration would order the writer's stores against the copies
            // that follow and hide a weakened load *inside* `read`, which is the
            // other half of the pairing under test. The plugin's consumer does
            // not consult the cursor separately either: `Editor.readWindow` goes
            // straight to `Ring.read`, whose own acquire is the whole mechanism.
            // One warm-up orders only the 960 samples published by the time it
            // returns, against the 1047552 this run goes on to write, so
            // everything the loop actually measures stays unordered.
            //
            // Found by planting the defect rather than by reading the code: the
            // per-iteration version detected a weakened publish and would have
            // reported a weakened `read` as clean.
            var spins: u64 = 0;
            while (self.buffer.written() < window_samples) {
                spins += 1;
                if (spins > max_spins) return;
                std.atomic.spinLoopHint();
            }

            while (self.counters.validated < target_reads and
                self.counters.attempts < max_attempts)
            {
                self.counters.attempts += 1;

                if (!self.buffer.read(&window)) {
                    self.counters.torn += 1;
                    continue;
                }

                if (!valid(&window)) {
                    self.corrupt = true;
                    return;
                }

                self.counters.validated += 1;
            }
        }
    };
}

/// The buffer with the defect, which is the whole of the negative control.
///
/// **Deliberately wrong, and never to be copied.** It is the same access pattern
/// as `Ring` with one thing removed: the publishing store is `.monotonic`, so
/// nothing orders the samples written above it against the reader's copy. The
/// load stays `.acquire`, because release-acquire needs both halves and changing
/// only the store is precisely the regression this exists to catch. Someone
/// simplifying `Ring.write`'s atomic produces exactly this.
///
/// Simpler than `Ring` on purpose. Nothing wraps at this capacity, so there is no
/// mask and no seam, and the parts that would differ are parts the arms do not
/// test. Its job is to be the same shape with the ordering gone, not to be a
/// second ring.
const Weakened = struct {
    samples: []f32,
    cursor: std.atomic.Value(u64) = .init(0),

    fn write(self: *Weakened, input: []const f32) void {
        const at: usize = @intCast(self.cursor.load(.monotonic));
        @memcpy(self.samples[at..][0..input.len], input);

        // The defect. `Ring.write` stores with `.release` here.
        self.cursor.store(at + input.len, .monotonic);
    }

    fn read(self: *const Weakened, dst: []f32) bool {
        const at: usize = @intCast(self.cursor.load(.acquire));
        const copied = @min(dst.len, at);
        const pad = dst.len - copied;

        @memset(dst[0..pad], 0);
        @memcpy(dst[pad..], self.samples[at - copied ..][0..copied]);

        return true;
    }

    fn written(self: *const Weakened) u64 {
        return self.cursor.load(.acquire);
    }
};

// ---------------------------------------------------------------------------
// The writer's sequence, and what makes a window checkable
// ---------------------------------------------------------------------------

/// The sample the writer puts at absolute index `at`.
///
/// One-based, so zero is unambiguously the front pad `read` writes rather than a
/// sample that happens to be the first one. `f32` represents every integer up to
/// 2^24 exactly and the cursor stops around 2^20, so this is exact arithmetic
/// and a window can be checked rather than approximated.
fn value(at: usize) f32 {
    return @floatFromInt(at + 1);
}

/// Whether a window is a run of the writer's sequence.
///
/// Structural rather than absolute: it does not need to know where the cursor
/// was, only that what came back is a front pad of zeroes followed by
/// consecutive ascending samples. That catches a torn window, a window assembled
/// from two different laps, and a copy that landed at the wrong offset, without
/// the reader having to synchronise with the writer to find out what it should
/// have seen. Synchronising to check would add the very happens-before edge the
/// arms exist to detect the absence of.
fn valid(window: []const f32) bool {
    var index: usize = 0;
    while (index < window.len and window[index] == 0) index += 1;

    while (index + 1 < window.len) : (index += 1) {
        if (window[index + 1] != window[index] + 1) return false;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Tests
//
// The harness is an executable and its arms need two threads and a sanitizer, so
// only the pure parts are testable here. `valid` is the one piece whose being
// wrong would make every arm pass for the wrong reason, which is exactly the
// class of thing `coherent` is tested for in `src/dsp/ring.zig`.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a window of consecutive samples behind a zero pad is valid" {
    try testing.expect(valid(&[_]f32{ 0, 0, 1, 2, 3 }));
    try testing.expect(valid(&[_]f32{ 7, 8, 9 }));
    try testing.expect(valid(&[_]f32{0}));
    try testing.expect(valid(&[_]f32{}));
}

test "a window the producer tore is not valid" {
    // The seam a lapped copy leaves: two runs, correct in themselves.
    try testing.expect(!valid(&[_]f32{ 7, 8, 200, 201 }));

    // Backwards, which is what an older lap under a newer one looks like.
    try testing.expect(!valid(&[_]f32{ 9, 8, 7 }));

    // A pad that reappears after real samples, which no correct read produces.
    try testing.expect(!valid(&[_]f32{ 0, 1, 2, 0 }));
}

test "the writer's sequence never collides with the front pad" {
    try testing.expect(value(0) != 0);
    try testing.expectEqual(@as(f32, 1), value(0));

    // Exact at the far end of the run, which is what lets `valid` compare with
    // equality rather than a tolerance.
    const last = write_blocks * block_samples - 1;
    try testing.expectEqual(@as(usize, @intFromFloat(value(last))), last + 1);
}

test "the writer cannot lap the reader" {
    // The premise the ring arm rests on, asserted rather than left to whoever
    // next changes one of these three constants. If this fails, Thread Sanitizer
    // would start reporting the torn-window path, which this project accepts by
    // design and which ADR 0016 puts outside what the harness verifies.
    try testing.expect(write_blocks * block_samples + window_samples <= capacity);
}
