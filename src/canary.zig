//! Reading a file's own source at comptime, so a declaration nothing here can
//! check as behaviour can still be checked as text.
//!
//! `src/dsp/ring.zig` had the first of these and the reason generalises past it
//! (ADR 0016). Every mechanism this module guards is one where the failure is a
//! *weakening* rather than a break: a `.release` store simplified to
//! `.monotonic`, a constructor swapped for its sibling, two correct lines put in
//! the wrong order. Each of those compiles, each passes a single-threaded suite,
//! and the instrument that would catch it either needs a host this machine
//! cannot be (`zig build ring-race` needs Linux) or does not exist at all.
//!
//! **These read the source as text and prove nothing about behaviour.** A
//! passing canary means the lines are unchanged, not that they are correct. A
//! global find-and-replace rewrites the string literals here along with the code
//! they name, which is accepted for the reason ADR 0016 accepts it: the canary
//! is deliberately the faster of the two checks rather than the harder to fool.
//!
//! It costs the shipped binary nothing. Zig analyses `test` declarations only in
//! a test build, so nothing outside one ever reaches this module or the
//! `@embedFile` its callers hand it.
//!
//! Two properties of the matching are load-bearing, and both are answers to
//! flaws in the first implementation rather than choices.
//!
//! **A statement line is matched trimmed**, so moving a statement into an `if`
//! block is a wash rather than a failure. The original formatted a match string
//! with exactly eight leading spaces, which made re-indentation with no semantic
//! change fail it.
//!
//! **A line whose trimmed text begins with `//` is not a statement line**, and
//! neither `stated` nor `mentions` can see one. The original counted a bare
//! identifier over text that included the doc comments above the tests banner,
//! so a new comment naming `self.cursor.load` broke it. It is also what makes an
//! assertion like `mentions(code, "Threaded.init") == 0` expressible at all, in
//! a file whose docstring names `Threaded.init` twice in order to forbid it.
//!
//! The residual, stated rather than hidden: a trailing comment on a code line is
//! still part of that statement line. Stripping from the first `//` would
//! misread a string literal that contains one, and the alternative to both is a
//! tokenizer. No line in any file guarded here has a trailing comment.

const std = @import("std");

/// Everything above the tests banner, so a canary cannot read its own string
/// literals and count them as code.
///
/// The marker is the section heading these files already carry rather than a new
/// one, so there is nothing extra to keep in step. A file with no banner is
/// returned whole, which is correct for one whose tests live elsewhere.
pub fn implementation(source: []const u8) []const u8 {
    const marker = "\n// Tests\n";
    return source[0 .. std.mem.indexOf(u8, source, marker) orelse source.len];
}

/// How many statement lines are exactly `line`, ignoring indentation.
pub fn stated(code: []const u8, line: []const u8) usize {
    var found: usize = 0;
    var lines = statements(code);
    while (lines.next()) |statement| {
        if (std.mem.eql(u8, statement, line)) found += 1;
    }
    return found;
}

/// How many statement lines contain `needle`.
///
/// The counterpart to `stated`, and the one that closes the hole `stated` leaves
/// open: a file that states every line asked of it and also acquired a sixth
/// operation somewhere else satisfies every `stated` check and fails this one.
pub fn mentions(code: []const u8, needle: []const u8) usize {
    var found: usize = 0;
    var lines = statements(code);
    while (lines.next()) |statement| {
        if (std.mem.indexOf(u8, statement, needle) != null) found += 1;
    }
    return found;
}

/// Whether each line is stated exactly once and `first` precedes `second`.
///
/// Counting cannot see two correct statements in the wrong order, and there is
/// at least one place where the order is the whole protocol: `Mailbox.take` in
/// `gpu/metal/renderer.zig` copies the payload before it releases the slot, and
/// reversing those two lines lets the producer overwrite what the consumer is
/// still reading. That is not a crash, it is a picture drawn from two different
/// compiles.
///
/// False when either line is absent or stated more than once, because "before"
/// means nothing about a line stated twice.
pub fn statedBefore(code: []const u8, first: []const u8, second: []const u8) bool {
    if (stated(code, first) != 1) return false;
    if (stated(code, second) != 1) return false;

    var index: usize = 0;
    var at_first: ?usize = null;
    var at_second: ?usize = null;

    var lines = statements(code);
    while (lines.next()) |statement| : (index += 1) {
        if (std.mem.eql(u8, statement, first)) at_first = index;
        if (std.mem.eql(u8, statement, second)) at_second = index;
    }

    return at_first.? < at_second.?;
}

/// The lines of `code` that are not comments, each already trimmed.
///
/// Blank lines are dropped too. They cannot match anything a caller asks for,
/// and dropping them keeps `statedBefore`'s indices to statements alone.
fn statements(code: []const u8) Statements {
    return .{ .lines = std.mem.splitScalar(u8, code, '\n') };
}

const Statements = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn next(self: *Statements) ?[]const u8 {
        while (self.lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            return trimmed;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// This module is itself the thing five canaries rest on, so a bug here is five
// checks silently passing. Each property the module claims is asserted, and the
// two flaws it exists to fix are asserted as absences rather than described.

test "a statement matches trimmed, so indentation is not part of the claim" {
    const code =
        \\fn f() void {
        \\    self.cursor.store(1, .release);
        \\}
    ;
    try testing.expectEqual(1, stated(code, "self.cursor.store(1, .release);"));

    // The first flaw. Eight spaces was the original match and this is the same
    // statement one block deeper, which must still read as unchanged.
    const nested =
        \\fn f() void {
        \\    if (ready) {
        \\        self.cursor.store(1, .release);
        \\    }
        \\}
    ;
    try testing.expectEqual(1, stated(nested, "self.cursor.store(1, .release);"));
}

test "a statement stated twice is counted twice, which Gate needs" {
    // `Gate.enter`'s refusal path and `Gate.leave` state this identically, so a
    // helper that could only answer "exactly once" could not express either.
    const code =
        \\fn enter(self: *Gate) bool {
        \\    _ = self.state.fetchSub(one_tick, .release);
        \\}
        \\fn leave(self: *Gate) void {
        \\    _ = self.state.fetchSub(one_tick, .release);
        \\}
    ;
    try testing.expectEqual(2, stated(code, "_ = self.state.fetchSub(one_tick, .release);"));
    try testing.expectEqual(0, stated(code, "_ = self.state.fetchSub(one_tick, .monotonic);"));
}

test "comments are not statements, which is the second flaw fixed" {
    const code =
        \\/// Prose naming self.cursor.load(.acquire) in a doc comment.
        \\//! And a module docstring naming Threaded.init in order to forbid it.
        \\// A plain comment naming self.cursor.store as well.
        \\const x = 1;
    ;
    try testing.expectEqual(0, mentions(code, "self.cursor."));
    try testing.expectEqual(0, mentions(code, "Threaded.init"));
    try testing.expectEqual(1, mentions(code, "const x"));

    // An indented comment is still a comment.
    const indented =
        \\fn f() void {
        \\        // self.cursor.load(.acquire)
        \\    const y = 2;
        \\}
    ;
    try testing.expectEqual(0, mentions(indented, "self.cursor."));
}

test "mentions counts lines rather than occurrences, and catches an operation nothing asked about" {
    const code =
        \\const at = self.cursor.load(.acquire);
        \\self.cursor.store(at, .release);
        \\const sneaky = self.cursor.load(.monotonic);
    ;
    // Every line a caller pinned is present, and there is one more.
    try testing.expectEqual(1, stated(code, "const at = self.cursor.load(.acquire);"));
    try testing.expectEqual(1, stated(code, "self.cursor.store(at, .release);"));
    try testing.expectEqual(3, mentions(code, "self.cursor."));
}

test "statedBefore reads order, which no count can" {
    const right =
        \\const taken = self.staged;
        \\self.state.store(.empty, .release);
    ;
    const wrong =
        \\self.state.store(.empty, .release);
        \\const taken = self.staged;
    ;
    const first = "const taken = self.staged;";
    const second = "self.state.store(.empty, .release);";

    try testing.expect(statedBefore(right, first, second));
    try testing.expect(!statedBefore(wrong, first, second));

    // Both counts are identical either way, which is why this helper exists.
    try testing.expectEqual(stated(right, first), stated(wrong, first));
    try testing.expectEqual(stated(right, second), stated(wrong, second));
}

test "statedBefore refuses an absent or repeated line rather than guessing" {
    const missing = "const taken = self.staged;";
    try testing.expect(!statedBefore(missing, "const taken = self.staged;", "self.state.store(.empty, .release);"));

    const twice =
        \\const taken = self.staged;
        \\const taken = self.staged;
        \\self.state.store(.empty, .release);
    ;
    try testing.expect(!statedBefore(twice, "const taken = self.staged;", "self.state.store(.empty, .release);"));
}

test "implementation stops at the tests banner, and a file without one is returned whole" {
    const code =
        \\const real = 1;
        \\
        \\// Tests
        \\
        \\const fake = 2;
    ;
    const above = implementation(code);
    try testing.expectEqual(1, mentions(above, "const real"));
    try testing.expectEqual(0, mentions(above, "const fake"));

    const unbanner = "const only = 1;";
    try testing.expectEqual(1, mentions(implementation(unbanner), "const only"));
}
