//! What one look at the shader on disk decides, and what each outcome does to the
//! tally. Nothing about reading a file, and nothing about a device.
//!
//! Everything here is arithmetic over a stamp, an enum and five atomics. No Metal,
//! no GPU, no allocator, no I/O, and nothing above this file's own imports, which
//! is what lets `zig build test` cover all of it on a runner with no graphics
//! support at all (ADR 0009). `src/gpu/metal/renderer.zig` owns the device, the
//! watcher thread and the messages; `src/gpu/metal/shader.zig` owns the path and
//! the read; this owns the deciding.
//!
//! **It names no Metal type**, which is why it sits beside `shader.zig` under
//! `metal/` without weakening `renderer.zig`'s claim to be the only file here
//! allowed to name one (ADR 0005).
//!
//! **The split is forced rather than tidy, and the gate that forces it is not the
//! usual one.** `renderer.zig`'s `Watcher` is `if (shader.live) struct { ... } else
//! struct { ... }`, and `shader.live` is `builtin.mode == .Debug and
//! !builtin.is_test`. A test binary is a Debug build with `is_test` set, so it
//! always takes the stub: the real `poll` is not merely untested, it is *not
//! compiled*, and no test written in `zig build test` could reach it however it was
//! written. `--release=fast` takes the stub too, so #94's `test-safe` and
//! `test-release` do not help either. The same gate stands over `buildPipelines`
//! and `readShader`, which carry a second copy of this bookkeeping.
//!
//! Two precedents, and the nearer one is next door. `shader.choosePath` is split
//! out of `resolvePath` for exactly this reason and says so at its own docstring:
//! "`live` is false in a test build by design, so `resolvePath` returns null there
//! and a test of it would assert nothing about the property that matters." And
//! #92 made the same move one layer up, taking the trace half's judgements out of
//! `src/smoke.zig` into `src/gpu/verdict.zig`, on `src/gpu/measure.zig`'s
//! precedent. The pattern all three share: the *decision* is separable from the
//! *call*, and only the call needs the machine.
//!
//! **Nothing here prints, which is the one place this departs from `verdict.zig`.**
//! There the judges' bodies *were* the printing, so `say` moved with them behind a
//! `!builtin.is_test` gate. Here every message names a path, a `readFile` error, a
//! byte count or a Metal compiler diagnostic, and all four belong to the caller.
//! So `sayShader` stays in `renderer.zig` with its `shader.live` gate untouched,
//! and `Counters.note` answers *whether* to say rather than what. The consequence,
//! stated rather than left to be found: the format strings have no coverage here
//! and are verified by `zig build smoke-gpu` and `zig build smoke-appkit`, whose
//! transcripts are the artefact that half is judged by.

const std = @import("std");

const iface = @import("../iface.zig");
const shader = @import("shader.zig");

/// What one look at the watched file resolves to.
///
/// Two states rather than an outcome, because everything past `.reload` needs a
/// file descriptor and a device and belongs to the caller. `.idle` covers five
/// distinct reasons and deliberately does not distinguish them: nothing downstream
/// behaves differently, and a caller that wanted to say which would be printing
/// four times a second about a file nobody touched.
pub const Step = enum { idle, reload };

/// Every way a source read off disk can end, at either of the two sites that read
/// one.
///
/// **The site is in the key rather than in a parameter, because the two sites
/// disagree and the disagreement is the content.** A compile failure under the
/// watcher moves `rejected` alone: nothing falls back, and the shader already
/// running stays, which is the whole of why the swap is fail-soft. The same
/// failure under `buildPipelines` moves `rejected` *and* `fallbacks`, because the
/// embedded copy is what the editor then opens with. That was two pairs of
/// `fetchAdd` calls two thousand lines apart with nothing tying them together;
/// here it is a table with six rows and a test that reads them.
pub const Outcome = enum {
    /// The watcher saw a change and could not read the file.
    watch_unreadable,
    /// The watcher read it and Metal refused it. The running shader stays.
    watch_rejected,
    /// The watcher read it, Metal took it, and the render thread will swap it in.
    watch_reloaded,
    /// An editor opening could not read the file, so the embedded copy was used.
    open_unreadable,
    /// An editor opening read it and Metal refused it, so the embedded copy was
    /// used.
    open_rejected,
    /// An editor opening compiled the copy on disk, which is the ordinary case in
    /// a debug build.
    open_reloaded,
};

/// What an outcome adds to the tally.
pub const Deltas = struct {
    reloads: u64 = 0,
    rejected: u64 = 0,
    fallbacks: u64 = 0,

    /// Whether the caller should put this outcome on stderr.
    ///
    /// `.always` for five of the six. `.once` belongs to `open_unreadable` alone
    /// and is answered by the tally rather than by this value, for the reason
    /// `note` gives. `.never` is `open_reloaded`, which is silent on purpose: a
    /// debug build compiles the disk copy every time an editor opens, so a message
    /// there would say the ordinary thing on every open.
    say: enum { always, once, never } = .always,
};

/// The mapping, in one place, as data.
///
/// A `switch` over a total enum rather than a lookup table, so adding a seventh
/// outcome is a compile error here rather than a silently-zero row.
///
/// **One row is inherited rather than endorsed, and it is
/// [#118](https://github.com/cboone/fosforo/issues/118).** `watch_unreadable`
/// credits `fallbacks`, which `iface.ShaderStats` documents as "times the embedded
/// copy was used" — and the watcher never uses it, which is what its own message
/// says when it keeps the shader now running. That is `renderer.zig`'s behaviour
/// as it stood and it is preserved here exactly, because #93 was a refactor whose
/// evidence is that nothing observable moved. Collecting the six rows into one
/// table is what made it legible. **Do not "fix" it by counting the read failure
/// as `rejected`**, which was the first suggestion and trades one wrong claim for
/// another: that counter means a source that was read and refused, and an
/// unreadable file never reached the compiler. The issue carries the three options
/// and why none is obviously right. Nothing currently misreports, because every
/// reader of `fallbacks` in `src/smoke.zig` drives the opening path.
pub fn deltas(outcome: Outcome) Deltas {
    return switch (outcome) {
        .watch_unreadable => .{ .fallbacks = 1 },
        .watch_rejected => .{ .rejected = 1 },
        .watch_reloaded => .{ .reloads = 1 },
        .open_unreadable => .{ .fallbacks = 1, .say = .once },
        .open_rejected => .{ .rejected = 1, .fallbacks = 1 },
        .open_reloaded => .{ .reloads = 1, .say = .never },
    };
}

/// What has happened to the shader on disk, process-wide.
///
/// **A type with one shared instance rather than five bare globals, and that is
/// what makes any of this testable.** A test constructs its own and asserts
/// against it; the instance `renderer.zig` keeps stays at zero in a test binary,
/// which is what `gpu/iface.zig`'s "the shader counters read zero in a build that
/// has no watcher" continues to assert.
///
/// Process-wide rather than per-renderer, for `live_windows`' reason and one more
/// besides: the question a caller wants answered is "did my edit reach the GPU",
/// and every open editor in the process answers it at once.
///
/// Zero and immovable in a release build, where nothing reads a file. A caller
/// telling that apart from a watcher that never fired reads `path_resolved`.
pub const Counters = struct {
    path_resolved: std.atomic.Value(bool) = .init(false),
    reloads: std.atomic.Value(u64) = .init(0),
    rejected: std.atomic.Value(u64) = .init(0),
    fallbacks: std.atomic.Value(u64) = .init(0),
    binding_mismatches: std.atomic.Value(u64) = .init(0),

    /// [any thread] Credit one outcome, and answer whether it is worth saying out
    /// loud.
    ///
    /// **The say-once rule keeps the coupling it already had, which is surprising
    /// enough to be asserted rather than described.** `readShader` guarded its
    /// message on `fallbacks.fetchAdd(1, .release) == 0`, and `open_rejected`
    /// moves `fallbacks` too, so an earlier rejection **silences** a later
    /// unreadable file. That is the behaviour as it stands and it is preserved
    /// exactly; what changes is that a test says so.
    ///
    /// The fallbacks bump therefore has to happen first, because it is its *own
    /// previous value* the rule reads and re-loading afterwards would race every
    /// other thread doing the same.
    pub fn note(self: *Counters, outcome: Outcome) bool {
        const d = deltas(outcome);

        const fallbacks_before = if (d.fallbacks != 0)
            self.fallbacks.fetchAdd(d.fallbacks, .release)
        else
            self.fallbacks.load(.acquire);

        if (d.reloads != 0) _ = self.reloads.fetchAdd(d.reloads, .release);
        if (d.rejected != 0) _ = self.rejected.fetchAdd(d.rejected, .release);

        return switch (d.say) {
            .always => true,
            .once => fallbacks_before == 0,
            .never => false,
        };
    }

    /// [any thread] A source off disk that compiled and reads a binding somewhere
    /// this backend does not bind it.
    ///
    /// Its own operation rather than a seventh `Outcome`, because it moves
    /// *alongside* `reloads` rather than instead of it, which is the whole of
    /// #77's decision stated as a type. Folding it into the table would make the
    /// two mutually exclusive, which is the opposite of what it means.
    pub fn noteMismatch(self: *Counters) void {
        _ = self.binding_mismatches.fetchAdd(1, .release);
    }

    /// [any thread] This process chose a file to compile from.
    ///
    /// It says a path was *chosen* and neither of the two things it looks like it
    /// might; `iface.ShaderStats.path_resolved` carries that in full.
    pub fn notePathResolved(self: *Counters) void {
        self.path_resolved.store(true, .release);
    }

    /// [thread-safe] The tally as the seam publishes it.
    pub fn stats(self: *const Counters) iface.ShaderStats {
        return .{
            .path_resolved = self.path_resolved.load(.acquire),
            .reloads = self.reloads.load(.acquire),
            .rejected = self.rejected.load(.acquire),
            .fallbacks = self.fallbacks.load(.acquire),
            .binding_mismatches = self.binding_mismatches.load(.acquire),
        };
    }
};

/// One watcher's memory of the file, and every decision one poll makes about it.
///
/// Owned by the watcher thread alone, one per open editor, and the only writer of
/// `seen` anywhere.
pub const Watch = struct {
    /// What the file looked like last time this looked. Null until the first
    /// successful stat, so the file as it stands when an editor opens is not
    /// treated as an edit: `buildPipelines` already compiled it.
    seen: ?shader.Stamp = null,

    /// [watcher-thread] Record the file as it stands, without treating it as a
    /// change.
    ///
    /// Called once when the thread starts rather than left to the first `look`,
    /// and the difference is a whole poll interval of an editor's life during
    /// which an edit would be recorded rather than acted on. `look` handles a null
    /// baseline too and reaches the same state; what this buys is reaching it 250
    /// ms sooner.
    pub fn baseline(self: *Watch, now: ?shader.Stamp) void {
        self.seen = now;
    }

    /// [watcher-thread] One look, and the whole of what a poll decides.
    ///
    /// Total over its three inputs. `now` is null when the path would not resolve
    /// or the stat failed, which are two ways of having learned nothing and are
    /// deliberately not told apart.
    ///
    /// **A full mailbox skips without advancing `seen`, and that is what makes the
    /// skip lossless**: the change is still outstanding and the next look picks it
    /// up. The stat is paid before this question rather than after it, which is
    /// `Mailbox.vacant`'s own accounting — "an editor hidden for an hour costs four
    /// `stat` calls a second and no XPC round trips at all" — and is what puts this
    /// rule inside a function a test binary compiles.
    ///
    /// **`seen` advances before `.reload` is returned, so it advances on every
    /// outcome including failure**, and that is the line this whole module exists
    /// for. Without it a broken file is re-read and re-rejected four times a
    /// second forever; with it, it is reported once per save and recovers when the
    /// file is fixed. Nothing outside `zig build test` sees this: measured on
    /// `f7fba29` with the advance moved to the success path only, `zig build test`
    /// reported 297 of 297 and `zig build smoke-appkit` reported `ok`, with all
    /// five of its hot-reload arms running.
    pub fn look(self: *Watch, vacant: bool, now: ?shader.Stamp) Step {
        if (!vacant) return .idle;
        const current = now orelse return .idle;

        const previous = self.seen orelse {
            // The baseline stat failed when this editor opened, so the file was
            // unreadable then. Recording rather than reloading is right here too:
            // `buildPipelines` already fell back and said so, and a file that has
            // since appeared is a change the next look will see.
            self.seen = current;
            return .idle;
        };
        if (!previous.differs(current)) return .idle;

        self.seen = current;
        return .reload;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    // The decision half of a feature whose call sites a test binary compiles none
    // of, so without these its public surface would be checked by the two build
    // steps that need a device (#95).
    testing.refAllDecls(@This());
    testing.refAllDecls(Step);
    testing.refAllDecls(Outcome);
    testing.refAllDecls(Deltas);
    testing.refAllDecls(Counters);
    testing.refAllDecls(Watch);
}

/// Three stamps that differ in one field each, which is `Stamp.differs`' whole
/// claim arriving at its caller.
const base: shader.Stamp = .{ .mtime_ns = 1_000, .size = 23_388, .inode = 7 };
const touched: shader.Stamp = .{ .mtime_ns = 2_000, .size = 23_388, .inode = 7 };
const renamed: shader.Stamp = .{ .mtime_ns = 1_000, .size = 23_388, .inode = 8 };

test "a changed file advances seen before it asks for a reload, not after" {
    // **The defect this module was extracted to make visible.** Planted against
    // `Watcher.poll` as it stood, with the advance moved to the success path only,
    // `zig build test` reported 297 of 297 and `zig build smoke-appkit` reported
    // `ok`: nothing in the repository caught it, which is one instrument fewer
    // than issue #93 claimed. What fails here is the second assertion.
    var watch: Watch = .{ .seen = base };

    try testing.expectEqual(Step.reload, watch.look(true, touched));
    try testing.expectEqual(touched, watch.seen.?);
}

test "a file that has not been fixed is reported once per save, not four times a second" {
    // The behavioural form of the claim above, and the arm that discriminates
    // hardest: an advance that happened only on success leaves the second look
    // returning `.reload` too, and then every one after it, forever.
    var watch: Watch = .{ .seen = base };

    try testing.expectEqual(Step.reload, watch.look(true, touched));
    try testing.expectEqual(Step.idle, watch.look(true, touched));
    try testing.expectEqual(Step.idle, watch.look(true, touched));

    // And it recovers when the file is fixed, which is what makes a typo cost a
    // save rather than a relaunch.
    try testing.expectEqual(Step.reload, watch.look(true, base));
}

test "a full mailbox skips without advancing seen, which is what makes the skip lossless" {
    var watch: Watch = .{ .seen = base };

    try testing.expectEqual(Step.idle, watch.look(false, touched));
    try testing.expectEqual(base, watch.seen.?);

    // The change is still outstanding, so the next look with room picks it up.
    // Without this the edit would be swallowed and the picture would stay stale
    // until the file was touched again.
    try testing.expectEqual(Step.reload, watch.look(true, touched));
}

test "having learned nothing is not a change, and does not disturb what was known" {
    // Null covers an unresolvable path and a failed stat alike. Either way the
    // last good stamp has to survive, or the next successful stat would read as an
    // edit that never happened.
    var watch: Watch = .{ .seen = base };

    try testing.expectEqual(Step.idle, watch.look(true, null));
    try testing.expectEqual(base, watch.seen.?);

    // Including when there was nothing known to begin with.
    var empty: Watch = .{};
    try testing.expectEqual(Step.idle, empty.look(true, null));
    try testing.expectEqual(@as(?shader.Stamp, null), empty.seen);
}

test "an editor opening is not an edit" {
    // The null baseline means the stat in `run` failed, so the file was unreadable
    // when this editor opened. `buildPipelines` has already fallen back and said
    // so; recompiling here would report a reload for a file nobody touched.
    var watch: Watch = .{};

    try testing.expectEqual(Step.idle, watch.look(true, base));
    try testing.expectEqual(base, watch.seen.?);

    // And the next real edit is a reload, so recording rather than reloading costs
    // one poll interval and not the feature.
    try testing.expectEqual(Step.reload, watch.look(true, touched));
}

test "an identical stamp is not a change" {
    var watch: Watch = .{ .seen = base };

    try testing.expectEqual(Step.idle, watch.look(true, base));
    try testing.expectEqual(base, watch.seen.?);
}

test "a save by rename is a change, which is the inode field arriving at its caller" {
    // `Stamp.differs` has its own test; this is the one that shows the third field
    // reaching a decision. Many editors write a temporary file and rename it over
    // the target, so the path acquires a new inode with a plausible mtime and an
    // identical size, and a two-field stamp is how a hot reloader appears to work
    // and then quietly stops.
    var watch: Watch = .{ .seen = base };

    try testing.expectEqual(Step.reload, watch.look(true, renamed));
    try testing.expectEqual(renamed, watch.seen.?);
}

test "the baseline records without deciding anything" {
    var watch: Watch = .{};

    watch.baseline(base);
    try testing.expectEqual(base, watch.seen.?);
    try testing.expectEqual(Step.idle, watch.look(true, base));

    // A failed baseline stat leaves it null rather than inventing a stamp, which
    // is the state `look`'s null-baseline arm above is written for.
    var failed: Watch = .{};
    failed.baseline(null);
    try testing.expectEqual(@as(?shader.Stamp, null), failed.seen);
}

test "the outcome table, cell by cell" {
    // Six rows, because the two sites map the same three results differently and
    // the mapping is the whole content. Read as a table so that a row swapped for
    // its neighbour fails here rather than misreporting a smoke arm.
    // Inherited rather than endorsed: this row claims the embedded copy was used
    // and the watcher never uses it. Pinned as it stands, because #93 preserved
    // `renderer.zig`'s arithmetic exactly; see `deltas` and #118.
    try testing.expectEqual(Deltas{ .fallbacks = 1 }, deltas(.watch_unreadable));
    try testing.expectEqual(Deltas{ .rejected = 1 }, deltas(.watch_rejected));
    try testing.expectEqual(Deltas{ .reloads = 1 }, deltas(.watch_reloaded));
    try testing.expectEqual(Deltas{ .fallbacks = 1, .say = .once }, deltas(.open_unreadable));
    try testing.expectEqual(Deltas{ .rejected = 1, .fallbacks = 1 }, deltas(.open_rejected));
    try testing.expectEqual(Deltas{ .reloads = 1, .say = .never }, deltas(.open_reloaded));

    // No outcome moves two of the three counters except `open_rejected`, and none
    // moves none. The second half is the vacuity guard: a row that credited
    // nothing would satisfy every "did not move" assertion elsewhere.
    inline for (std.meta.fields(Outcome)) |field| {
        const d = deltas(@field(Outcome, field.name));
        try testing.expect(d.reloads + d.rejected + d.fallbacks > 0);
    }
}

test "a rejection falls back only where there is something to fall back to" {
    // **The asymmetry the two copies of this bookkeeping carried and nothing
    // stated.** The watcher keeps the shader already running, so nothing falls
    // back and `fallbacks` must not move; an editor opening uses the embedded
    // copy, so it must. Swapping either mapping fails here, and would otherwise
    // fail nothing at all.
    try testing.expectEqual(@as(u64, 0), deltas(.watch_rejected).fallbacks);
    try testing.expectEqual(@as(u64, 1), deltas(.open_rejected).fallbacks);

    // Both still count the rejection itself, which is the half they agree on.
    try testing.expectEqual(@as(u64, 1), deltas(.watch_rejected).rejected);
    try testing.expectEqual(@as(u64, 1), deltas(.open_rejected).rejected);
}

test "noting an outcome moves what its row says and nothing else" {
    inline for (std.meta.fields(Outcome)) |field| {
        const outcome = @field(Outcome, field.name);
        const d = deltas(outcome);

        var counters: Counters = .{};
        _ = counters.note(outcome);

        const seen = counters.stats();
        try testing.expectEqual(d.reloads, seen.reloads);
        try testing.expectEqual(d.rejected, seen.rejected);
        try testing.expectEqual(d.fallbacks, seen.fallbacks);

        // Neither of the two that no outcome touches.
        try testing.expectEqual(@as(u64, 0), seen.binding_mismatches);
        try testing.expect(!seen.path_resolved);
    }
}

test "a counter accumulates rather than latching" {
    // `note` returning a bool invites reading it as a once-per-process guard for
    // every outcome. It is not: only `open_unreadable` is, and every counter is a
    // count.
    var counters: Counters = .{};

    for (0..3) |_| _ = counters.note(.watch_reloaded);
    for (0..2) |_| _ = counters.note(.watch_rejected);

    try testing.expectEqual(@as(u64, 3), counters.stats().reloads);
    try testing.expectEqual(@as(u64, 2), counters.stats().rejected);
    try testing.expectEqual(@as(u64, 0), counters.stats().fallbacks);
}

test "an unreadable file on the opening path says so once, and the coupling is through fallbacks" {
    var counters: Counters = .{};

    try testing.expect(counters.note(.open_unreadable));
    try testing.expect(!counters.note(.open_unreadable));
    try testing.expect(!counters.note(.open_unreadable));

    // Counted every time even so. An editor that opens showing yesterday's shader
    // with no explanation is the kind of thing that gets blamed on the GPU, and
    // saying it once is the answer to that rather than counting it once.
    try testing.expectEqual(@as(u64, 3), counters.stats().fallbacks);

    // **The coupling, which is the surprising half.** `open_rejected` moves
    // `fallbacks` too, so a rejection earlier in the process silences the first
    // unreadable file. That was true before this module existed, is preserved
    // exactly, and was stated nowhere.
    var after_rejection: Counters = .{};
    _ = after_rejection.note(.open_rejected);
    try testing.expect(!after_rejection.note(.open_unreadable));
}

test "every other outcome says every time, and the successful open says nothing" {
    var counters: Counters = .{};

    // Five looks at a broken file across five saves are five diagnostics, because
    // each is a different edit the developer is waiting on.
    for (0..5) |_| try testing.expect(counters.note(.watch_rejected));
    for (0..5) |_| try testing.expect(counters.note(.watch_unreadable));
    for (0..5) |_| try testing.expect(counters.note(.watch_reloaded));
    for (0..5) |_| try testing.expect(counters.note(.open_rejected));

    // And the one that is deliberately silent: a debug build compiles the disk
    // copy every time an editor opens, so a message here would announce the
    // ordinary case on every open.
    for (0..5) |_| try testing.expect(!counters.note(.open_reloaded));

    // Ten rather than five, and the difference is the point: silent is not
    // uncounted. Both reloaded rows credit `reloads`, which is what
    // `iface.ShaderStats.reloads` means by "including the first" — the editor
    // opening against the disk copy is a reload, it is just not news.
    try testing.expectEqual(@as(u64, 10), counters.stats().reloads);
}

test "a mismatch moves alongside a reload, never instead of it" {
    // #77's decision stated as a type: the swap happens *and* the mismatch is said
    // out loud, because a reloader that silently declines to reload is how people
    // stop trusting one. `src/smoke.zig` asserts the same thing against a device;
    // this asserts it against the tally the arm reads.
    var counters: Counters = .{};

    _ = counters.note(.watch_reloaded);
    counters.noteMismatch();

    const seen = counters.stats();
    try testing.expectEqual(@as(u64, 1), seen.reloads);
    try testing.expectEqual(@as(u64, 1), seen.binding_mismatches);
    try testing.expectEqual(@as(u64, 0), seen.rejected);
    try testing.expectEqual(@as(u64, 0), seen.fallbacks);
}

test "every field of the published tally reads the counter behind it" {
    // A swapped pair in `stats` is invisible to everything else in this repository
    // and would misreport every smoke arm that reads one. The values are distinct
    // so that a transposition cannot read as a pass.
    var counters: Counters = .{};

    for (0..1) |_| _ = counters.note(.watch_reloaded);
    for (0..2) |_| _ = counters.note(.watch_rejected);
    for (0..3) |_| _ = counters.note(.watch_unreadable);
    for (0..4) |_| counters.noteMismatch();
    counters.notePathResolved();

    try testing.expectEqual(iface.ShaderStats{
        .path_resolved = true,
        .reloads = 1,
        .rejected = 2,
        .fallbacks = 3,
        .binding_mismatches = 4,
    }, counters.stats());
}

test "a fresh tally is the seam's own default, and path_resolved is the odd one out" {
    // The claim `iface.ShaderStats`' docstring makes about a release build: every
    // field zero, permanently, because nothing there reads a file. `path_resolved`
    // is what tells that apart from a watcher that never fired, so it moves on its
    // own and no outcome touches it.
    var counters: Counters = .{};
    try testing.expectEqual(iface.ShaderStats{}, counters.stats());

    counters.notePathResolved();
    try testing.expect(counters.stats().path_resolved);
    try testing.expectEqual(@as(u64, 0), counters.stats().reloads);
}
