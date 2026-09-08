//! The gate's race harness: the only thing in this project that runs
//! `Gate.enter`, `Gate.leave` and `Gate.close` on two threads at once.
//!
//! `src/clap/gate.zig` is what stands between a host's main thread and memory
//! the render thread is still reading. `Editor.destroy` closes it and then
//! releases the renderer, the view and the display link and overwrites eleven
//! plain fields that `Editor.tick` reads from inside it. Every test of that
//! module is single-threaded, so replacing `leave`'s release with a `.monotonic`
//! store passes all of them. This harness is what notices. See ADR 0016, whose
//! argument for `src/dsp/ring.zig` is reused here in full rather than restated:
//! Thread Sanitizer builds a happens-before graph rather than looking for
//! corruption, so the verdict is a property of the code and does not depend on
//! the scheduler doing anything in particular.
//!
//! Two arms, each its own process, because one of them must fail:
//!
//!     gate           the real `Gate`, on two threads       must be CLEAN
//!     gate-weakened  the same pattern with `leave`'s       must be FLAGGED
//!                    release store relaxed
//!
//! The second is the negative control, and `scripts/race-check` judges it first
//! for the reason ADR 0016 records: everything the first arm proves is an
//! absence, and a search for absence succeeds for the wrong reason when the
//! instrument is not running.
//!
//! **The payload is what makes any of this visible, and it is not scaffolding.**
//! Thread Sanitizer reports two threads reaching one address with no edge
//! between them, and two relaxed atomic accesses to the same word are not a race
//! in that model whatever their ordering. So an arm can discriminate an ordering
//! only where that ordering guards *non-atomic* memory. The ring has its sample
//! buffer; the gate has the editor's own fields, written by `destroy` after
//! `close` returns and read by `tick` from inside. This harness stands a slice of
//! plain `u64` in for those fields, read by the holder inside the gate and
//! written by the closer after `close` returns, which is `Editor.destroy`'s shape
//! with everything Apple owns removed. Without it both arms come back clean and
//! the harness measures nothing.
//!
//! **Three details are load-bearing and each looks incidental.**
//!
//! The `inside` flag both threads use to rendezvous is `.monotonic` on both
//! sides deliberately. An acquire load paired with a release store there would
//! supply the very happens-before edge the arms exist to detect the absence of,
//! and would report a weakened `leave` as clean. That is the same trap
//! `src/ring_race.zig`'s one-shot warm-up exists for, and it was found there by
//! planting the defect rather than by reading the code.
//!
//! The closer writes the payload **before** `join` rather than after. `join` is
//! itself a happens-before edge, so joining first would order every write behind
//! every read and make both arms clean. The window between `close` returning and
//! `join` being called is the whole experiment.
//!
//! A gate is one-way, so each round gets a fresh one. The holder does its reading
//! *after* signalling rather than before, so the closer is spinning in `close`
//! while the reads are still happening, and then holds for a fixed count before
//! leaving. That fixed count is not padding: how long the holder takes to leave
//! otherwise depends on the ordering under test, because Thread Sanitizer
//! instruments a release store far more heavily than a relaxed one, and without
//! it the control stops closing a gate that has a tick inside it. See
//! `hold_spins`, which carries the measurement. `Gate.close` reports how many
//! turns it spun, and `contended` below is what rules out a run where the two
//! threads never actually met.
//!
//! **An executable rather than a test artifact**, on `src/smoke.zig`'s and
//! `src/ring_race.zig`'s precedent and for their reasons: a test binary has to
//! stay silent, and this must never be wired into `zig build test`, which cannot
//! acquire a dependency on the host being able to run Thread Sanitizer at all
//! (ADR 0009, ADR 0013).

const std = @import("std");

const gate_mod = @import("clap/gate.zig");

/// Rounds, each a fresh gate with one holder and one closer.
///
/// Enough that `contended` is a population rather than an anecdote, and small
/// enough that the instrumented payload accesses below stay in the hundreds of
/// thousands rather than the millions. Every round spawns a thread, which is the
/// cost that scales here.
const rounds: u64 = 256;

/// Words of payload standing in for the editor's own fields.
///
/// The holder reads all of them inside the gate, and the closer overwrites them
/// once the gate is shut. This is what a sanitizer can actually see; the gate's
/// own word is atomic on both sides and could never be reported.
const payload_words: usize = 1024;

/// Turns the holder spins inside the gate after reading, before it leaves.
///
/// **Not padding, and the arms diverge without it.** Reading the payload is not
/// a long enough hold on its own, because how long the holder takes to *leave*
/// depends on the very ordering under test: Thread Sanitizer instruments a
/// release store as a full publish of the thread's clock and a relaxed one as
/// almost nothing, so the weakened arm's holder leaves markedly sooner. Measured
/// rather than reasoned about, on a run with no explicit hold: the clean arm
/// contended in 195 rounds of 256 and the weakened arm in 0, which failed the
/// run on `NeverContended`. The control was no longer closing a gate with a tick
/// inside it, which is the only situation either arm exists to model.
///
/// So the hold is a fixed count that costs the same in both arms, and
/// `contended` is what reports that it worked.
const hold_spins: u64 = 1 << 14;

/// How long the closer waits for the holder to signal that it is inside.
///
/// Only reachable if the holder never ran at all, which would be a defect in the
/// harness rather than a finding about the gate. Generous, and still small
/// enough that hitting it fails in seconds rather than reading as a wedged job,
/// which is `src/ring_race.zig`'s reasoning for its own bound.
const max_spins: u64 = 1 << 28;

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = init.args.iterate();
    _ = args.next();

    const arm = args.next() orelse return usage();

    if (std.mem.eql(u8, arm, "gate")) return report("gate", gateArm());
    if (std.mem.eql(u8, arm, "gate-weakened")) return report("gate-weakened", weakenedArm());

    return usage();
}

fn usage() u8 {
    say(
        \\usage: fosforo-gate-race gate
        \\       fosforo-gate-race gate-weakened
        \\
        \\  gate           the real Gate on two threads; Thread Sanitizer must find nothing
        \\  gate-weakened  the same pattern with leave's release relaxed; TSan must find a race
        \\
        \\Run both through scripts/race-check, which judges them in the order that
        \\makes the first one's silence mean something.
    , .{});
    return 2;
}

/// The exit-code discipline, in one place, matching `src/ring_race.zig`.
///
/// Zero for an arm that ran as expected, 1 for one that ran and failed, 2 for
/// being called wrong. A passing **weakened** arm still exits non-zero overall,
/// because Thread Sanitizer replaces the status with its own `exitcode` when it
/// has reported anything, which is why `scripts/race-check` reads the output
/// rather than only the status.
fn report(arm: []const u8, result: anyerror!Counters) u8 {
    const counters = result catch |err| {
        say("race: {s} FAILED: {s}", .{ arm, @errorName(err) });
        return 1;
    };

    // `contended` is the statistic that makes a clean arm mean something, and it
    // is printed rather than merely counted for the reason `validated` is in the
    // ring harness: a run whose closer never waited for a tick is two threads
    // that never met, and the script has no other way to see that from outside.
    say("race: {s} rounds={d} contended={d} spins={d} checksum={d}", .{
        arm,
        counters.rounds,
        counters.contended,
        counters.spins,
        counters.checksum,
    });
    say("race: {s} ok", .{arm});
    return 0;
}

/// Everything this harness says, on stderr, as `src/ring_race.zig` does.
fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// What an arm reports about itself.
const Counters = struct {
    /// Rounds completed.
    rounds: u64 = 0,

    /// Rounds in which `close` spun at least once, so a tick was genuinely
    /// inside when teardown began. The number that makes a clean result mean
    /// something.
    contended: u64 = 0,

    /// Turns spent spinning across every round, summed. Reported for the same
    /// reason `#89` made the trace harness print its elapsed time: a run that
    /// barely contended and one that contended hard read identically without it.
    spins: u64 = 0,

    /// What the holders summed out of the payload, folded together. Its value is
    /// not checked against anything; it exists so the reads cannot be elided and
    /// so a harness that raced an untouched buffer is visible from outside.
    checksum: u64 = 0,
};

const ArmError = error{
    /// A holder found the gate shut. Every round builds a fresh one, so this is
    /// a defect in the harness rather than a finding about the gate.
    GateRefusedAnOpenTick,

    /// A holder never signalled that it was inside, so the closer gave up.
    HolderNeverEntered,

    /// No round contended: `close` returned without spinning every time, so the
    /// two threads never overlapped and a clean sanitizer result over them would
    /// be vacuous. The script asserts this from outside as well.
    NeverContended,
};

// ---------------------------------------------------------------------------
// The arms
// ---------------------------------------------------------------------------

/// The real thing. Thread Sanitizer must find nothing here.
fn gateArm() !Counters {
    return drive(gate_mod.Gate);
}

/// The negative control. Thread Sanitizer must find a race here.
fn weakenedArm() !Counters {
    return drive(Weakened);
}

/// One holder on a spawned thread and one closer on this one, over any gate that
/// answers `enter`, `leave` and `close`.
///
/// Generic so the two arms cannot drift apart. The round count, the payload, the
/// rendezvous and the write window are shared by construction, which is what
/// makes the ordering of `leave`'s store the single variable between them.
fn drive(comptime G: type) !Counters {
    const payload = try std.heap.page_allocator.alloc(u64, payload_words);
    defer std.heap.page_allocator.free(payload);
    @memset(payload, 0);

    var counters: Counters = .{};

    var round: u64 = 0;
    while (round < rounds) : (round += 1) {
        var session: Session(G) = .{ .payload = payload };

        const holder = try std.Thread.spawn(.{}, Session(G).run, .{&session});

        // Relaxed on purpose; see the module docstring. This orders nothing, and
        // ordering anything here would hide the defect the weakened arm plants.
        var spins: u64 = 0;
        var signalled = true;
        while (!session.inside.load(.monotonic)) {
            spins += 1;
            if (spins > max_spins) {
                signalled = false;
                break;
            }
            std.atomic.spinLoopHint();
        }

        // Both guarded, and the round is abandoned rather than half-run. Closing
        // a gate the holder never entered would spin until it finally did, and
        // writing the payload without having closed would be an unordered write
        // in *both* arms, which would flag the real gate for the harness's fault.
        const waited = if (signalled) session.gate.close() else 0;

        // The window the whole harness exists for. `Editor.destroy` does exactly
        // this: closes, then writes memory a tick reads from inside the gate.
        // Before `join`, which would otherwise supply the edge itself.
        if (signalled) {
            for (payload, 0..) |*word, at| word.* = teardown(round, at);
        }

        holder.join();

        if (!signalled) return ArmError.HolderNeverEntered;
        if (!session.entered) return ArmError.GateRefusedAnOpenTick;

        counters.rounds += 1;
        counters.spins += waited;
        if (waited > 0) counters.contended += 1;
        counters.checksum +%= session.checksum;
    }

    if (counters.contended == 0) return ArmError.NeverContended;

    return counters;
}

/// One round: a fresh gate, a holder, and the payload they contend over.
fn Session(comptime G: type) type {
    return struct {
        const Self = @This();

        gate: G = .{},
        payload: []u64,

        /// The rendezvous, and `.monotonic` on both sides deliberately. See the
        /// module docstring: release-acquire here would order the holder's reads
        /// against the closer's writes by itself and report every arm clean.
        inside: std.atomic.Value(bool) = .init(false),

        /// Both written by the holder and read by the closer after `join`, which
        /// is what orders them. Nothing touches them in between.
        entered: bool = false,
        checksum: u64 = 0,

        /// [holder] Enter, read the payload, hold, leave.
        ///
        /// The signal goes up before the reads rather than after, so the closer
        /// is already spinning inside `close` while the reads are in flight. It
        /// goes up whether or not the gate let this tick in, so a refusal fails
        /// the round rather than wedging the closer.
        fn run(self: *Self) void {
            self.entered = self.gate.enter();
            self.inside.store(true, .monotonic);
            if (!self.entered) return;

            var sum: u64 = 0;
            for (self.payload) |word| sum +%= word;
            self.checksum = sum;

            // See `hold_spins`. Without this the two arms hold for measurably
            // different lengths, because the cost of leaving is the cost of the
            // ordering being tested.
            var held: u64 = 0;
            while (held < hold_spins) : (held += 1) std.atomic.spinLoopHint();

            self.gate.leave();
        }
    };
}

/// The gate with the defect, which is the whole of the negative control.
///
/// **Deliberately wrong, and never to be copied.** It is `Gate` with one thing
/// removed: `leave`'s store is `.monotonic`, so nothing orders the payload the
/// holder read above it against the closer's writes. `close`'s load stays
/// `.acquire`, because release-acquire needs both halves and changing only the
/// store is precisely the regression this exists to catch. Someone simplifying
/// `Gate.leave`'s atomic produces exactly this.
///
/// `leave` rather than `enter` is the ordering weakened here, and that is a
/// measurement rather than a preference: it is the release half of the only edge
/// in `Gate` with non-atomic memory on both sides of it, which is what a Thread
/// Sanitizer can see. ADR 0016's #91 amendment carries the table of all five.
const Weakened = struct {
    state: std.atomic.Value(u32) = .init(0),

    const closed: u32 = 1;
    const one_tick: u32 = 2;

    fn enter(self: *Weakened) bool {
        const previous = self.state.fetchAdd(one_tick, .acquire);
        if (previous & closed != 0) {
            _ = self.state.fetchSub(one_tick, .release);
            return false;
        }
        return true;
    }

    fn leave(self: *Weakened) void {
        // The defect. `Gate.leave` stores with `.release` here.
        _ = self.state.fetchSub(one_tick, .monotonic);
    }

    fn close(self: *Weakened) u64 {
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

/// What the closer writes into the payload once the gate is shut.
///
/// Nothing reads it back for correctness; it only has to differ from what the
/// holders summed, so a write that never happened would change the checksum of
/// every round after it.
fn teardown(round: u64, at: usize) u64 {
    return round *% 0x9e37_79b9 +% at +% 1;
}

// ---------------------------------------------------------------------------
// Tests
//
// The harness is an executable and its arms need two threads and a sanitizer, so
// only the pure parts are testable here, exactly as in `src/ring_race.zig`.
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    // `main` and the arms are otherwise analysed only for the Linux target the
    // harness runs on, because `zig build gate-race` refuses on a macOS host.
    // This is the first thing that compiles them here.
    testing.refAllDecls(@This());
}

test "the replica is the gate with exactly one ordering removed" {
    // Read as text rather than asserted about behaviour, because the difference
    // is invisible to any single-threaded test: that is the whole premise. What
    // this catches is the replica drifting into a second difference, which would
    // make the control flag a race the real gate could not have.
    const canary = @import("canary.zig");
    const code = canary.implementation(@embedFile("gate_race.zig"));

    try testing.expectEqual(1, canary.stated(code, "const previous = self.state.fetchAdd(one_tick, .acquire);"));
    try testing.expectEqual(1, canary.stated(code, "_ = self.state.fetchSub(one_tick, .release);"));
    try testing.expectEqual(1, canary.stated(code, "_ = self.state.fetchOr(closed, .acquire);"));
    try testing.expectEqual(1, canary.stated(code, "while (self.state.load(.acquire) != closed) {"));

    // The defect itself, stated once, so a control that quietly stopped being
    // weakened fails here rather than passing as a clean arm.
    try testing.expectEqual(1, canary.stated(code, "_ = self.state.fetchSub(one_tick, .monotonic);"));

    // And that those five are all of them, which is the assertion that makes the
    // four above mean "exactly one difference" rather than "at least these
    // lines". Without it the replica could acquire a sixth operation, and a
    // control carrying an ordering the subject does not have can flag a race the
    // real `Gate` could never produce. This is the same bound `src/clap/gate.zig`
    // and the rendezvous check below both carry; it was missing here alone.
    try testing.expectEqual(5, canary.mentions(code, "self.state."));
}

test "the rendezvous cannot become an ordering" {
    // The trap the module docstring names, asserted rather than left to whoever
    // next tidies this file. A release store or an acquire load on `inside`
    // orders the holder's reads against the closer's writes by itself, and both
    // arms then come back clean: the harness would measure nothing and say so in
    // no way at all.
    const canary = @import("canary.zig");
    const code = canary.implementation(@embedFile("gate_race.zig"));

    try testing.expectEqual(1, canary.stated(code, "self.inside.store(true, .monotonic);"));
    try testing.expectEqual(1, canary.stated(code, "while (!session.inside.load(.monotonic)) {"));
    try testing.expectEqual(2, canary.mentions(code, ".inside."));
}

test "the closer writes the payload before it joins" {
    // The other trap: `join` is a happens-before edge, so writing after it would
    // order every write behind every read and report both arms clean.
    const canary = @import("canary.zig");
    const code = canary.implementation(@embedFile("gate_race.zig"));

    try testing.expect(canary.statedBefore(
        code,
        "for (payload, 0..) |*word, at| word.* = teardown(round, at);",
        "holder.join();",
    ));
}

test "teardown never writes what a holder summed out of a cleared payload" {
    // The payload starts zeroed, so the first round's holder sums zero. Every
    // word the closer writes is non-zero, which is what makes a skipped write
    // visible in the checksum rather than silently indistinguishable.
    var at: usize = 0;
    while (at < 4) : (at += 1) {
        try testing.expect(teardown(0, at) != 0);
        try testing.expect(teardown(1, at) != 0);
    }
    try testing.expect(teardown(0, 0) != teardown(1, 0));
}
