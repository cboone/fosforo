//! The lock-free circular history buffer, which is the entire concurrency
//! story between the audio thread and the render thread (ADR 0010).
//!
//! Not a queue, and the distinction is the decision rather than a detail. A
//! queue models "deliver every item exactly once", which is neither needed nor
//! wanted here: a scope wants the most recent window and is perfectly happy to
//! overwrite everything older. Providing the guarantee nobody asked for is what
//! would cost the complexity.
//!
//! The protocol is small enough to state completely:
//!
//! - The producer writes samples into the backing array, then publishes an
//!   advanced cursor with **release** semantics, once per call.
//! - The consumer takes an **acquire** load of that cursor and reads a trailing
//!   window relative to it.
//! - Capacity is on the order of a second while any display window is tens of
//!   milliseconds, so the producer cannot realistically lap the consumer
//!   between publishing and copying. That margin is what makes a seqlock retry
//!   loop unnecessary, and `read` reports on it rather than assuming it.
//!
//! **Those two orderings are verified by `zig build ring-race`, and by nothing
//! in `zig build test`.** Every test below is single-threaded, so nothing here
//! ever runs `write` and `read` at once: replacing the release store with a
//! `.monotonic` one passes all of them. `src/ring_race.zig` runs the two on real
//! threads under Thread Sanitizer, which judges by the happens-before graph
//! rather than by whether corruption appeared, so its verdict is a property of
//! this code and not of the scheduler. It cannot run on `aarch64-macos`, where
//! Zig 0.16 links a `-fsanitize-thread` binary that segfaults before `main`, so
//! it runs on Linux in CI, and the canary at the bottom of this file is what
//! catches a weakening on the machine you are probably reading this on. See
//! ADR 0016.
//!
//! **What that does not cover is the torn-window path, by construction.** A
//! producer that laps the consumer mid-copy reads and writes the same slots with
//! nothing ordering them, which is a data race in the model Thread Sanitizer
//! implements however benign it is here. The harness therefore bounds its writer
//! so lapping cannot happen, rather than reporting a race this design accepts on
//! purpose. `coherent` is what covers that path, exactly and with one thread,
//! because it is arithmetic.
//!
//! Nothing below `init` allocates, takes a lock, or makes a syscall. The
//! storage is allocated once by its owner and never resized, which is what lets
//! `write` be reachable from `process`.
//!
//! **Not a `std.Io` case, deliberately** (ADR 0015). `Io.Mutex` is reachable
//! through `src/platform/io.zig` and would be wrong here twice over. The
//! producer runs on the audio thread, where ADR 0010 forbids taking a lock at
//! all; the consumer runs inside `Editor.tick`, which holds a gate that
//! teardown spins on, so a contended `futexWait` there becomes a wait the
//! host's main thread can enter when an editor closes. The single atomic cursor
//! is the structure rather than a stand-in for a lock it could not use, which
//! is the same thing `Gate` and the frame semaphore say at their own call
//! sites. That ADR asks each such site to say so where it is, so the convention
//! cannot be over-applied by someone who found only the ADR.
//!
//! `src/clap/plugin.zig` is the producer, writing the tapped channel from
//! `process` and clearing the history from `reset`. `src/clap/gui.zig` becomes
//! the consumer. Keeping the container separate from both is what makes it the
//! one part of the signal path testable with no host, no GPU, and no window
//! server.

const std = @import("std");

/// A fixed-capacity ring over `f32`, written by one thread and read by another.
///
/// Single-producer and single-consumer, and not merely by convention: the
/// producer's own read of the cursor is unsynchronised because it is the only
/// writer of it, so a second producer would silently lose samples.
pub const Ring = struct {
    /// The backing array. Its length **is** the capacity, and is always a power
    /// of two, which is what makes the wrap a mask.
    samples: []f32,

    /// Samples ever written. Monotonic, never reset, and the only thing that
    /// crosses between the two threads.
    ///
    /// A `u64` counting samples rather than an index, so a reader can tell "the
    /// buffer has lapped twice" from "the buffer has not moved" without
    /// coordinating with the writer over what a wrapped index means. At 192 kHz
    /// it takes about three million years to overflow.
    cursor: std.atomic.Value(u64) = .init(0),

    pub const InitError = error{
        /// A ring with no slots has no trailing window to return. Refused
        /// rather than asserted: `std.math.ceilPowerOfTwo` asserts against zero
        /// itself, and that assertion is at its most convincing exactly where
        /// it does the least good. `zig build test` takes no `-Doptimize`, so
        /// it is a Debug build and the assertion is live; the `--release=fast`
        /// build that ships is the one where it is gone and a host's bad value
        /// would run on unchecked.
        EmptyCapacity,
        /// The capacity, once rounded up, does not fit in a `usize`.
        Overflow,
    } || std.mem.Allocator.Error;

    /// [main-thread] Allocate the storage, once. Rounds the request **up** to a
    /// power of two, so `capacity` is what the caller actually got rather than
    /// what it asked for.
    ///
    /// **Why round at all**, since the honest answer is not the obvious one.
    /// For `write` and `read` alone a division would have been fine: each wraps
    /// at most twice per call, because each is at most two `@memcpy`s, so the
    /// cost is a handful of 64-bit divisions per audio block and per frame. The
    /// argument is phase 4's triggering, which scans backward sample by sample
    /// looking for a threshold crossing and is the first caller where the wrap
    /// is per-sample rather than per-call. Choosing the mask now means that
    /// caller is not the moment the choice gets revisited.
    ///
    /// The cost is a bounded rounding on an allocation made once per
    /// activation: a second of audio at 48 kHz asks for 48000 samples and gets
    /// 65536, which is 256 KiB, next to phase 3's ping-pong accumulation
    /// textures at megabytes each.
    pub fn init(allocator: std.mem.Allocator, minimum_capacity: usize) InitError!Ring {
        if (minimum_capacity == 0) return error.EmptyCapacity;

        const rounded = try std.math.ceilPowerOfTwo(usize, minimum_capacity);
        const samples = try allocator.alloc(f32, rounded);

        // Zeroed rather than left undefined. `read` pads the front of a window
        // longer than what has been written, so this is belt and braces rather
        // than load-bearing; it costs one memset per activation and the
        // alternative is uninitialised memory reaching the trace.
        @memset(samples, 0);

        return .{ .samples = samples };
    }

    /// [main-thread] The mirror of `init`, and the only other place this
    /// memory moves.
    pub fn deinit(self: *Ring, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        self.samples = &.{};
    }

    /// The rounded capacity, in samples. What the caller got, not what it asked
    /// for.
    pub fn capacity(self: *const Ring) usize {
        return self.samples.len;
    }

    /// [thread-safe] Samples ever written.
    ///
    /// An acquire load, so a caller that reads this and then reads the samples
    /// by hand sees them, rather than only the count.
    pub fn written(self: *const Ring) u64 {
        return self.cursor.load(.acquire);
    }

    /// [audio-thread] Append a block, publishing the cursor **once**.
    ///
    /// Once per call rather than once per sample, which is the difference
    /// between one release store per audio block and one per frame of audio.
    /// The consumer only ever wants a whole window anyway, so a cursor that
    /// advanced mid-block would buy it nothing and cost the producer
    /// everything.
    ///
    /// An input longer than the whole ring keeps only its newest `capacity`
    /// samples, and still advances the cursor by the entire input. That keeps
    /// one invariant true in every case rather than in the expected one: the
    /// ring holds the newest `capacity` samples ending at the cursor. No host
    /// will hand over a block longer than a second of audio, but a container
    /// that is total needs no caller to promise it will not.
    pub fn write(self: *Ring, input: []const f32) void {
        if (input.len == 0) return;

        const cap = self.samples.len;

        // Unsynchronised, and safe because this thread is the only writer of
        // it. The release store at the bottom is the publication.
        const at = self.cursor.load(.monotonic);

        // What survives, and where in the stream it starts. When the input
        // fits, `base` is the cursor and `src` is the whole input; when it does
        // not, both skip the samples that would have been overwritten by the
        // rest of this very call.
        const src = if (input.len <= cap) input else input[input.len - cap ..];
        const base = at + (input.len - src.len);

        const start = self.index(base);
        const first = @min(src.len, cap - start);
        @memcpy(self.samples[start..][0..first], src[0..first]);
        if (first < src.len) @memcpy(self.samples[0 .. src.len - first], src[first..]);

        // Release, paired with the acquire load in `read`: a consumer that
        // observes this cursor observes every sample written above it.
        //
        // **Two things catch you weakening this, and neither is a test of this
        // module's behaviour**, which is the module docstring's point restated
        // at the line it applies to. Every test here is single-threaded, so
        // `.monotonic` passes all of them and surfaces later as rare visual
        // corruption in someone's session. `zig build ring-race` runs this
        // against a reader under Thread Sanitizer and reports the missing edge;
        // the canary at the bottom of this file reads this line as text and
        // fails without needing a Linux host. Read ADR 0016 before changing it,
        // and change the canary in the same edit, or you have silenced the
        // faster of the two and learned nothing from the slower.
        self.cursor.store(at + input.len, .release);
    }

    /// [audio-thread] Publish a whole capacity of silence, so every sample a
    /// reader can still reach is zero.
    ///
    /// **This is repeated `write` of silence, and it has to be literally that
    /// rather than merely shaped like it.** The tempting implementation is one
    /// `@memset` of the storage followed by one cursor store advancing by the
    /// capacity, on the reasoning that a reader then sees a full lap and
    /// reports its window torn. That reasoning has a hole, and the hole is the
    /// whole reason this loop exists.
    ///
    /// `coherent` compares the cursor before and after the reader's copy, so it
    /// can only detect tearing that cursor *movement* reveals. A reader whose
    /// entire copy lands inside the memset window observes the same cursor
    /// twice, is told its window is coherent, and comes away with a window that
    /// was rewritten underneath it. Publishing after the fill does not fix that;
    /// publishing before it just moves the same hole to readers that snapshot
    /// during the fill. One store cannot bracket a write this wide.
    ///
    /// `write` is not exposed to this, because it writes *ahead* of the cursor
    /// while a reader reads behind it, so the two only overlap when the producer
    /// laps, and lapping is exactly what the cursor shows. Doing the clear as a
    /// sequence of ordinary writes inherits that property instead of
    /// approximating it: every slot this touches is ahead of a cursor that has
    /// already been published, so a reader is exposed to no more than it already
    /// is during ordinary processing, and to no less.
    ///
    /// The chunk is a typical audio block for the same reason: the residual
    /// uncertainty in `coherent` is one unpublished chunk wide, so a clear is no
    /// worse than a host handing over a block of that size, which is the risk
    /// ADR 0010 already accepts and rests its margin argument on.
    ///
    /// The cursor stays monotonic, which is what `coherent`'s unsaturated
    /// subtraction rests on, and advances by exactly the capacity, because that
    /// is how many zeroes really were written.
    pub fn clear(self: *Ring) void {
        var remaining = self.samples.len;
        while (remaining > 0) {
            const n = @min(remaining, silence.len);
            self.write(silence[0..n]);
            remaining -= n;
        }
    }

    /// [render-thread] Fill `dst` with the most recent `dst.len` samples,
    /// oldest first, allocating nothing.
    ///
    /// **The front is zero-padded** when fewer samples have been written than
    /// were asked for, which is a normal case rather than an edge one: a scope
    /// opened before playback starts hits it on its very first frame. It draws
    /// as a flat line filling in from the right, which is the correct picture.
    /// The same rule covers a window longer than the whole capacity, and a ring
    /// with no storage at all.
    ///
    /// The window ends at the cursor as it was when this call started, not at
    /// wherever the producer reached during the copy, so the samples returned
    /// are the ones the caller asked about rather than a moving target.
    ///
    /// **Returns false if the producer lapped the window during the copy**,
    /// leaving `dst` torn. That cannot realistically happen, for the reason
    /// ADR 0010 gives and this module's header repeats, and the whole structure
    /// rests on it, so it is checked rather than assumed. This is not a retry
    /// loop and does not become one: the caller's correct response to a torn
    /// window is to skip the frame, not to spin on the audio thread's heels.
    ///
    /// Reported rather than asserted, on the same reasoning `activate` and
    /// `process` already apply to the values a host hands them: an assertion is
    /// compiled out of exactly the build where the problem does damage.
    pub fn read(self: *const Ring, dst: []f32) bool {
        if (dst.len == 0) return true;

        const cap = self.samples.len;

        // A ring holding no storage, which is both the value `deinit` leaves
        // behind and the one a `Ring` that was never initialised carries. This
        // is a guard rather than a shortcut: every path below reaches `index`,
        // whose mask is `len - 1` computed on a `u64`, and that underflows at a
        // length of zero however few samples the caller asked for.
        //
        // The answer is the one the zero pad already gives a window longer than
        // anything written, and it is coherent for the reason `coherent` states
        // for a copy of nothing: no sample came out of shared storage, so there
        // is nothing in `dst` a producer could have torn.
        if (cap == 0) {
            @memset(dst, 0);
            return true;
        }

        const at = self.cursor.load(.monotonic);

        // Everything the ring can still be holding: before the first lap that
        // is the cursor itself, and after it the capacity.
        const available = @min(at, @as(u64, cap));
        const copied: usize = @intCast(@min(@as(u64, dst.len), available));
        const pad = dst.len - copied;

        @memset(dst[0..pad], 0);

        const start = self.index(at - copied);
        const first = @min(copied, cap - start);
        @memcpy(dst[pad..][0..first], self.samples[start..][0..first]);
        if (first < copied) @memcpy(dst[pad + first ..][0 .. copied - first], self.samples[0 .. copied - first]);

        return coherent(at, self.cursor.load(.acquire), cap, copied);
    }

    /// The wrap, in one place. A mask rather than a modulo, which is the whole
    /// reason `init` rounds the capacity.
    fn index(self: *const Ring, at: u64) usize {
        return @intCast(at & (@as(u64, self.samples.len) - 1));
    }
};

/// The source `clear` writes from, one chunk at a time.
///
/// A static block rather than a `@memset` of the storage, because the point of
/// `clear` is to reach the ring through `write` rather than around it. 256
/// samples is a typical audio block, which is what bounds `clear`'s exposure to
/// a concurrent reader at what ordinary processing already costs; see `clear`.
const silence: [256]f32 = @splat(0);

/// Whether a window ending at `snapshot` survived a copy that finished with the
/// producer at `now`.
///
/// The copied samples occupied the `copied` slots ending at `snapshot`, so the
/// producer has overwritten one of them exactly when it has advanced further
/// than the `capacity - copied` slots that were free in front of it.
///
/// Split out and taking its inputs rather than reading them, the way
/// `gui.Meter.observe` takes the time rather than calling the clock. It is the
/// one piece of this file's work that is pure arithmetic, and that is what makes
/// it testable exactly instead of by racing two threads and hoping.
///
/// The subtraction needs no saturation: the cursor is monotonic and has one
/// writer, so `now` is never behind `snapshot`. The right-hand side cannot
/// underflow either, because `read` clamps `copied` to the capacity before
/// getting here.
fn coherent(snapshot: u64, now: u64, capacity: usize, copied: usize) bool {
    // Nothing was taken from the storage, so nothing in it can have been
    // overwritten underneath the caller. This is the read of a ring the
    // producer has not reached yet, whose window is entirely the zero pad, and
    // the pad is arithmetic rather than shared memory. Without this case the
    // check measures the producer's whole run against the capacity and reports
    // a tear in a window that has nothing in it to tear.
    if (copied == 0) return true;

    return now - snapshot <= @as(u64, capacity - copied);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A monotonically increasing signal, so the order samples come back in is
/// checkable rather than merely plausible.
fn ramp(buffer: []f32, from: f32) void {
    for (buffer, 0..) |*sample, i| sample.* = from + @as(f32, @floatFromInt(i));
}

fn expectSamples(expected: []const f32, found: []const f32) !void {
    try testing.expectEqualSlices(f32, expected, found);
}

test "init rounds the capacity up to a power of two and reports what was allocated" {
    // A caller asking for a second at 48 kHz gets 1.365 seconds, and has to be
    // able to find that out: the rounding is invisible otherwise, and a caller
    // that assumed it got exactly what it asked for would compute the window's
    // duration wrong.
    var ring = try Ring.init(testing.allocator, 48_000);
    defer ring.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 65_536), ring.capacity());

    // A request that is already a power of two is left alone.
    var exact = try Ring.init(testing.allocator, 1024);
    defer exact.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1024), exact.capacity());

    // The smallest ring that is still a ring.
    var one = try Ring.init(testing.allocator, 1);
    defer one.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), one.capacity());
}

test "init refuses a capacity nothing could be read from" {
    // Refused rather than asserted. `ceilPowerOfTwo` asserts against zero
    // itself, and that assertion is gone from the build this project ships.
    try testing.expectError(error.EmptyCapacity, Ring.init(testing.allocator, 0));

    // Rejected before anything is allocated, so this does not try to reserve
    // sixteen exabytes on the way to failing.
    try testing.expectError(error.Overflow, Ring.init(testing.allocator, std.math.maxInt(usize)));
}

test "a fresh ring reads as silence rather than as whatever the heap held" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 0), ring.written());

    var window: [8]f32 = @splat(7);
    try testing.expect(ring.read(&window));
    try expectSamples(&@as([8]f32, @splat(0)), &window);
}

test "a read longer than what has been written is padded at the front" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    ring.write(&[_]f32{ 1, 2, 3 });
    try testing.expectEqual(@as(u64, 3), ring.written());

    // The case a scope hits on its very first frame: the trace is flat on the
    // left and fills in from the right, rather than the read refusing or
    // reporting a short count nobody asked for.
    var window: [6]f32 = @splat(7);
    try testing.expect(ring.read(&window));
    try expectSamples(&[_]f32{ 0, 0, 0, 1, 2, 3 }, &window);
}

test "a read of exactly the capacity" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    // Partly filled: the pad and the copy meet exactly at the capacity.
    ring.write(&[_]f32{ 1, 2, 3 });
    var window: [8]f32 = @splat(7);
    try testing.expect(ring.read(&window));
    try expectSamples(&[_]f32{ 0, 0, 0, 0, 0, 1, 2, 3 }, &window);

    // Full: the pad is empty and the copy is the whole backing array, which is
    // the boundary where an off-by-one in either direction shows.
    ring.write(&[_]f32{ 4, 5, 6, 7, 8 });
    try testing.expect(ring.read(&window));
    try expectSamples(&[_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 }, &window);
}

test "a write that straddles the end of the backing array reads back contiguous" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    // Six then five, so the second write splits two samples onto the end of the
    // array and three onto the front. The seam is the one place the two
    // `@memcpy`s in `write` have to agree with the two in `read`.
    ring.write(&[_]f32{ 1, 2, 3, 4, 5, 6 });
    ring.write(&[_]f32{ 7, 8, 9, 10, 11 });
    try testing.expectEqual(@as(u64, 11), ring.written());

    var whole: [8]f32 = undefined;
    try testing.expect(ring.read(&whole));
    try expectSamples(&[_]f32{ 4, 5, 6, 7, 8, 9, 10, 11 }, &whole);

    // A shorter window whose own start lands on the far side of the seam.
    var recent: [4]f32 = undefined;
    try testing.expect(ring.read(&recent));
    try expectSamples(&[_]f32{ 8, 9, 10, 11 }, &recent);
}

test "a cursor that has lapped many times still returns the newest window" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    // 125 laps and a bit, one sample at a time, so every possible alignment of
    // a block against the seam is visited rather than one convenient one.
    var sample: usize = 0;
    while (sample < 1000) : (sample += 1) {
        ring.write(&[_]f32{@floatFromInt(sample)});
    }

    try testing.expectEqual(@as(u64, 1000), ring.written());

    var window: [8]f32 = undefined;
    try testing.expect(ring.read(&window));
    try expectSamples(&[_]f32{ 992, 993, 994, 995, 996, 997, 998, 999 }, &window);

    // The cursor counts samples rather than indexing the array, so it keeps
    // saying how far the stream has run after the storage has wrapped.
    try testing.expect(ring.written() > ring.capacity());
}

test "a read longer than the whole capacity is padded to the difference" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    var block: [100]f32 = undefined;
    ramp(&block, 0);
    ring.write(&block);

    // `read`'s docstring claims the front pad covers a window longer than the
    // capacity as well as one longer than what has been written, and those are
    // two different paths through it. The other has an empty ring behind it and
    // copies nothing; this one has a full ring behind it, so a maximum-length
    // copy and a non-empty pad have to coexist and agree about where they meet.
    var window: [12]f32 = @splat(7);
    try testing.expect(ring.read(&window));
    try expectSamples(&[_]f32{ 0, 0, 0, 0, 92, 93, 94, 95, 96, 97, 98, 99 }, &window);
}

test "a capacity of one holds the newest sample and nothing else" {
    var ring = try Ring.init(testing.allocator, 1);
    defer ring.deinit(testing.allocator);

    // The degenerate shape, and the only one where the mask is zero, so every
    // index collapses to the same slot and an error in the arithmetic has
    // nowhere to show. Not a realistic capacity; it is here because it is the
    // boundary of the one the plugin will actually ask for.
    var newest: [1]f32 = @splat(7);
    try testing.expect(ring.read(&newest));
    try expectSamples(&[_]f32{0}, &newest);

    ring.write(&[_]f32{ 1, 2, 3 });
    try testing.expectEqual(@as(u64, 3), ring.written());
    try testing.expect(ring.read(&newest));
    try expectSamples(&[_]f32{3}, &newest);

    var wide: [3]f32 = @splat(7);
    try testing.expect(ring.read(&wide));
    try expectSamples(&[_]f32{ 0, 0, 3 }, &wide);
}

test "a write longer than the capacity keeps only its newest samples" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    var block: [20]f32 = undefined;
    ramp(&block, 0);
    ring.write(&block);

    // Everything older than the last eight was overwritten by the rest of the
    // same call, so the ring holds the newest capacity samples ending at the
    // cursor, which is the invariant every read depends on.
    var window: [8]f32 = undefined;
    try testing.expect(ring.read(&window));
    try expectSamples(&[_]f32{ 12, 13, 14, 15, 16, 17, 18, 19 }, &window);

    // And the cursor advanced by the whole input, not by what survived. It
    // describes the stream, not the storage.
    try testing.expectEqual(@as(u64, 20), ring.written());

    // The next write has to land where that one left off, which is what a base
    // index computed from the truncated length rather than the whole one would
    // get wrong.
    ring.write(&[_]f32{ 20, 21 });
    try testing.expect(ring.read(&window));
    try expectSamples(&[_]f32{ 14, 15, 16, 17, 18, 19, 20, 21 }, &window);
}

test "clear publishes a whole capacity of silence" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    var block: [8]f32 = undefined;
    ramp(&block, 1);
    ring.write(&block);

    ring.clear();

    // The cursor advanced by the capacity rather than standing still, because a
    // clear is a full-capacity block of zeroes going past rather than a hole
    // punched in what the reader is already holding.
    try testing.expectEqual(@as(u64, 16), ring.written());

    var window: [8]f32 = undefined;
    try testing.expect(ring.read(&window));
    try expectSamples(&@as([8]f32, @splat(0)), &window);

    // A shorter window is zeroes too, rather than the pad `read` produces
    // before the ring has filled. Those are two different paths to the same
    // picture and only one of them is this one.
    var narrow: [4]f32 = @splat(7);
    try testing.expect(ring.read(&narrow));
    try expectSamples(&@as([4]f32, @splat(0)), &narrow);

    // And the stream carries on from there, so the trace fills back in from the
    // right instead of restarting.
    ring.write(&[_]f32{ 9, 10 });
    try testing.expectEqual(@as(u64, 18), ring.written());
    try testing.expect(ring.read(&narrow));
    try expectSamples(&[_]f32{ 0, 0, 9, 10 }, &narrow);
}

test "clear spans a capacity larger than one chunk" {
    // The capacities the tests above use are smaller than `silence`, so they
    // run the loop in `clear` exactly once and say nothing about it. A ring
    // several chunks wide is what exercises the wrap and the accounting: the
    // capacity is always a power of two and so is the chunk, so a capacity is
    // either under one chunk or an exact multiple, and both shapes are covered
    // between here and the tests above.
    var ring = try Ring.init(testing.allocator, silence.len * 4);
    defer ring.deinit(testing.allocator);

    var block: [silence.len * 4]f32 = undefined;
    ramp(&block, 1);
    ring.write(&block);
    try testing.expectEqual(@as(u64, silence.len * 4), ring.written());

    ring.clear();

    // Exactly one capacity, not one chunk and not a chunk short.
    try testing.expectEqual(@as(u64, silence.len * 8), ring.written());

    var window: [silence.len * 4]f32 = undefined;
    try testing.expect(ring.read(&window));
    try expectSamples(&@as([silence.len * 4]f32, @splat(0)), &window);
}

test "clear leaves nothing of the samples it overwrote" {
    // A capacity of one, where the mask is zero and a wrap that got the seam
    // wrong has nowhere to hide.
    var ring = try Ring.init(testing.allocator, 1);
    defer ring.deinit(testing.allocator);

    ring.write(&[_]f32{5});
    ring.clear();

    try testing.expectEqual(@as(u64, 2), ring.written());

    var newest: [1]f32 = @splat(7);
    try testing.expect(ring.read(&newest));
    try expectSamples(&[_]f32{0}, &newest);
}

test "an empty write and an empty read change nothing" {
    var ring = try Ring.init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);

    ring.write(&.{});
    try testing.expectEqual(@as(u64, 0), ring.written());

    // A caller with nothing to show is not a caller with a torn window.
    try testing.expect(ring.read(&.{}));

    ring.write(&[_]f32{ 1, 2, 3 });
    ring.write(&.{});
    try testing.expectEqual(@as(u64, 3), ring.written());

    var window: [3]f32 = undefined;
    try testing.expect(ring.read(&window));
    try expectSamples(&[_]f32{ 1, 2, 3 }, &window);
}

test "a ring with no storage reads as silence rather than underflowing its mask" {
    // Not a hypothetical state. It is the default `Instance.history` carries
    // before anything initialises it, and it is what `deinit` leaves behind, so
    // a caller holding a `*const Ring` can meet it without having made a
    // mistake. Every path below the guard reaches `index`, whose mask is
    // `len - 1` on a `u64`, and zero minus one is not a mask.
    const never_initialised: Ring = .{ .samples = &.{} };

    var window: [4]f32 = @splat(7);
    try testing.expect(never_initialised.read(&window));
    try expectSamples(&[_]f32{ 0, 0, 0, 0 }, &window);

    // The same state reached the other way, with a cursor `deinit` deliberately
    // does not reset, so the guard cannot be resting on the cursor being zero.
    var freed = try Ring.init(testing.allocator, 8);
    freed.write(&[_]f32{ 1, 2, 3 });
    freed.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 3), freed.written());

    @memset(&window, 7);
    try testing.expect(freed.read(&window));
    try expectSamples(&[_]f32{ 0, 0, 0, 0 }, &window);
}

test "an ordinary read reports the window it copied as coherent" {
    var ring = try Ring.init(testing.allocator, 1024);
    defer ring.deinit(testing.allocator);

    // The realistic ratio, an order of magnitude apart rather than adjacent:
    // this is the margin ADR 0010 rests the whole design on.
    var block: [256]f32 = undefined;
    ramp(&block, 0);
    ring.write(&block);

    var window: [64]f32 = undefined;
    try testing.expect(ring.read(&window));
    try expectSamples(block[192..], &window);
}

test "the coherence check is exact at its boundary" {
    // The producer has not moved at all, which is every read in a single
    // threaded test and almost every read in a running plugin.
    try testing.expect(coherent(100, 100, 8, 4));

    // Four samples copied out of eight leaves four slots of headroom in front
    // of the window. Consuming exactly that is still coherent; the sample after
    // it is the one that lands on the oldest sample already copied.
    try testing.expect(coherent(100, 104, 8, 4));
    try testing.expect(!coherent(100, 105, 8, 4));

    // A window as long as the whole ring has no headroom at all, so a single
    // sample written during the copy tears it. That is not a defect in the
    // check: it is what asking for the entire history means, and it is why the
    // capacity is an order of magnitude larger than any window that gets read.
    try testing.expect(coherent(100, 100, 8, 8));
    try testing.expect(!coherent(100, 101, 8, 8));

    // An empty window cannot be torn, however far the producer ran.
    try testing.expect(coherent(100, 1_000_000, 8, 0));

    // A `clear` advances by the whole capacity, so it tears any window with
    // even one sample in it. That is the property that makes publishing the
    // silence correct and memsetting behind the cursor wrong: this is what the
    // reader gets told, and the version that leaves the cursor alone would
    // report the first line above instead, on a window it had just overwritten.
    try testing.expect(!coherent(100, 108, 8, 1));
    try testing.expect(coherent(100, 108, 8, 0));
}

/// Everything above this line, so the canary cannot read its own string
/// literals and count them as code. The marker is the section heading that is
/// already there rather than a new one, so there is nothing extra to keep in
/// step.
fn implementation() []const u8 {
    const source = @embedFile("ring.zig");
    const marker = "\n// Tests\n";
    return source[0 .. std.mem.indexOf(u8, source, marker) orelse source.len];
}

/// Whether `line`, indented as a statement inside a method, appears exactly once.
fn statedOnce(text: []const u8, line: []const u8) bool {
    var buffer: [160]u8 = undefined;
    const statement = std.fmt.bufPrint(&buffer, "\n        {s}\n", .{line}) catch return false;
    return std.mem.count(u8, text, statement) == 1;
}

// The canary.
//
// `zig build ring-race` is what verifies the release/acquire pairing, and it
// needs a Linux host, so the machine this project is developed on is the one
// machine that cannot run it (ADR 0016). This is the tripwire that fires anyway:
// one file read at comptime, and it fails in `zig build test` on any machine the
// moment one of the five atomic operations below is edited.
//
// **It reads the source as text and proves nothing about behaviour**, which is
// what its name says out loud so it cannot be mistaken for the thing that does.
// A passing canary means these lines are unchanged, not that they are correct.
//
// It costs the shipped binary nothing: Zig analyses `test` declarations only in
// a test build, so neither `@embedFile` nor the two helpers above are ever
// reached by `zig build`.
test "the atomics are still the atomics, read as text because no test here can read them as behaviour" {
    const code = implementation();

    // The publication, and the half a simplifier reaches for first. This is the
    // exact line `ring-race`'s weakened arm models the absence of.
    try testing.expect(statedOnce(code, "self.cursor.store(at + input.len, .release);"));

    // The three acquire loads, each by its whole statement, so moving one
    // between methods reads as a change rather than as a wash.
    try testing.expect(statedOnce(code, "return self.cursor.load(.acquire);"));
    try testing.expect(statedOnce(code, "const at = self.cursor.load(.acquire);"));
    try testing.expect(statedOnce(code, "return coherent(at, self.cursor.load(.acquire), cap, copied);"));

    // The producer's own unsynchronised read, safe only because it is the only
    // writer of the cursor.
    try testing.expect(statedOnce(code, "const at = self.cursor.load(.monotonic);"));

    // And that those five are all of them. Without this the checks above are
    // satisfied by a file that also acquired a sixth operation somewhere else,
    // which is the shape a seqlock retry loop would arrive in, and `read`'s
    // docstring says why this is not that.
    try testing.expectEqual(5, std.mem.count(u8, code, "self.cursor."));
}
