//! The editor's teardown barrier: a one-way gate the render thread passes
//! through and `Editor.destroy` closes.
//!
//! Its own file rather than a struct inside `gui.zig`, because it is the one
//! thing in that file a Thread Sanitizer can be pointed at. `gui.zig` reaches
//! CLAP's translated headers, `objc` and CoreVideo, so it cannot be built for
//! `x86_64-linux` at all; this reaches nothing but `std`, so `src/gate_race.zig`
//! races it on a Linux runner the way `src/ring_race.zig` races the history
//! buffer (ADR 0016, #91).
//!
//! The canary at the bottom is the other half of that arrangement and the faster
//! of the two: the sanitizer runs only in CI, and this fails on the machine of
//! whoever weakened an ordering.

const std = @import("std");

/// A one-way gate the render thread passes through and teardown closes.
///
/// This exists because `CVDisplayLinkStop` does not promise what a caller
/// freeing resources actually needs to know. It stops future callbacks; it says
/// nothing about one already running. Without an answer, `destroy` would be
/// releasing a Metal device that a tick might be one instruction away from
/// sending a message to, which is a crash inside someone else's DAW that only
/// happens when an editor closes at exactly the wrong moment.
///
/// One word carries both halves, which is what makes it correct: a tick claims
/// its place and learns whether the gate was open in the same atomic operation,
/// so there is no window between checking and entering for `close` to slip
/// into.
///
/// Deliberately not a mutex, and **not one of the primitives ADR 0015 governs**.
/// `platform/io.zig` owns an `Io`, so `Io.Mutex` is available and is still the
/// wrong answer twice over: a mutex would reintroduce the check-then-enter
/// window that the single word above closes, and its contended path calls
/// `io.futexWait`, an unbounded wait. `Editor.tick` holds this gate across its
/// whole body, so any unbounded wait reachable from a tick becomes one the
/// host's main thread can enter in `Gate.close` when an editor closes. This is a
/// better structure than the mutex it replaced rather than a stand-in for one.
///
/// **What the orderings below protect is not this word.** It is the editor's
/// own memory: `Editor.destroy` releases the renderer, the view and the display
/// link and then writes eleven plain fields that `Editor.tick` reads from inside
/// the gate. The edge that makes that safe is `leave`'s release paired with the
/// acquire load in `close`'s spin, and it is the only edge here with non-atomic
/// memory on both sides of it. That is why `src/gate_race.zig` races a payload
/// rather than the gate alone, and why a Thread Sanitizer can say anything about
/// this type at all.
pub const Gate = struct {
    /// Bit 0 is the closed flag; everything above it counts ticks inside.
    state: std.atomic.Value(u32) = .init(0),

    /// Private, and reachable from this file's own tests for that reason: a
    /// caller outside has no business reading the word's shape.
    const closed: u32 = 1;
    const one_tick: u32 = 2;

    /// [render-thread] Claim a place inside, or find the gate shut.
    ///
    /// The increment happens either way and is undone on refusal, because
    /// reading the flag first and incrementing second is exactly the race this
    /// type exists to close.
    pub fn enter(self: *Gate) bool {
        const previous = self.state.fetchAdd(one_tick, .acquire);
        if (previous & closed != 0) {
            _ = self.state.fetchSub(one_tick, .release);
            return false;
        }
        return true;
    }

    /// [render-thread] Give the place back.
    pub fn leave(self: *Gate) void {
        _ = self.state.fetchSub(one_tick, .release);
    }

    /// [main-thread] Shut the gate and wait for anyone inside to leave, and
    /// report how many turns that wait took.
    ///
    /// Spins rather than sleeping. The wait is bounded by one tick, it happens
    /// once when an editor closes, and the alternative is a condition variable
    /// this file would have to reach outside itself for.
    ///
    /// **The count is returned because nothing outside can observe it**, and
    /// `src/gate_race.zig` has to. A race harness that never contended would
    /// report a clean sanitizer result over two threads that never met, which is
    /// the vacuous pass ADR 0016's control arm exists to refuse; and no
    /// arrangement of the harness's own atomics can see inside this loop.
    /// Arranging for the holder to wait for a "closing" flag before leaving
    /// makes the spin *less* likely rather than more, because the holder is
    /// spinning on that flag and leaves the moment it appears. Callers in the
    /// plugin discard it.
    pub fn close(self: *Gate) u64 {
        _ = self.state.fetchOr(closed, .acquire);

        var spins: u64 = 0;
        while (self.state.load(.acquire) != closed) {
            spins += 1;
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
        return spins;
    }
};

// Tests

const testing = std.testing;
const canary = @import("../canary.zig");

test {
    // `Gate` is named separately because `refAllDecls` does not descend, and it
    // is named even though the sweep of a type with only methods is cheap: the
    // rule "types that currently have methods" reopens the hole in whichever
    // file adds one next (#95).
    testing.refAllDecls(@This());
    testing.refAllDecls(Gate);
}

test "a closed gate turns ticks away and leaves the count where it found it" {
    var gate: Gate = .{};

    try testing.expect(gate.enter());
    gate.leave();

    // Uncontended, so this returns without waiting for anything, which is also
    // the whole of what these tests can say about the spin.
    try testing.expectEqual(0, gate.close());

    // Every refused entry has to undo its own claim. One that did not would
    // leave the count non-zero, and the next `close` would spin forever on a
    // tick that no longer exists.
    try testing.expect(!gate.enter());
    try testing.expect(!gate.enter());
    try testing.expectEqual(Gate.closed, gate.state.load(.acquire));

    try testing.expectEqual(0, gate.close());
}

test "close waits for a tick that is already inside" {
    var gate: Gate = .{};
    try testing.expect(gate.enter());

    // The state a tick mid-frame leaves behind: closed, and still occupied.
    _ = gate.state.fetchOr(Gate.closed, .acquire);
    try testing.expectEqual(Gate.closed | Gate.one_tick, gate.state.load(.acquire));

    // `close` would spin here rather than returning, which is the property
    // under test and also why it cannot be called until the tick leaves.
    gate.leave();
    _ = gate.close();
    try testing.expectEqual(Gate.closed, gate.state.load(.acquire));
}

// The canary.
//
// The two tests above are honest about what they do not do, and what they do not
// do is the whole risk here: the first closes an uncontended gate, so `close`'s
// spin body never executes, and the second produces "the state a tick mid-frame
// leaves behind" by calling `fetchOr` in the test body. **There is no second
// thread in this file**, so every ordering below is invisible to both of them
// and a `.release` simplified to `.monotonic` passes each one.
//
// That is the same argument ADR 0016 makes about the ring. It now has both
// halves of the same answer: `zig build gate-race` proves the behaviour on a
// Linux runner, and this reads the source as text, which proves nothing about
// behaviour and fails immediately on the machine of whoever weakened it.
test "the gate still states its orderings, read as text because no test here has a second thread" {
    const code = canary.implementation(@embedFile("gate.zig"));

    // The claim, which learns whether the gate was open in the same operation
    // that takes a place, because reading the flag first and incrementing second
    // is exactly the race this type exists to close.
    try testing.expectEqual(1, canary.stated(code, "const previous = self.state.fetchAdd(one_tick, .acquire);"));

    // Both ways back out, stated identically in `enter`'s refusal path and in
    // `leave`. A count rather than "exactly once" is the whole reason
    // `canary.stated` returns one: either of these weakened alone takes this to
    // 1, and both weakened takes it to 0.
    //
    // `leave`'s is the one with a measured consequence, recorded in ADR 0016's
    // #91 amendment: it is the release half of the only edge in this type with
    // non-atomic memory on both sides of it.
    try testing.expectEqual(2, canary.stated(code, "_ = self.state.fetchSub(one_tick, .release);"));

    // The close and its spin, which is what stands between a host's main thread
    // and a tick still touching the device `destroy` is about to release. The
    // acquire load is the other half of the edge above.
    try testing.expectEqual(1, canary.stated(code, "_ = self.state.fetchOr(closed, .acquire);"));
    try testing.expectEqual(1, canary.stated(code, "while (self.state.load(.acquire) != closed) {"));

    // And that those five are all of them, so the checks above cannot be
    // satisfied by a file that also acquired a sixth operation somewhere else.
    try testing.expectEqual(5, canary.mentions(code, "self.state."));
}
