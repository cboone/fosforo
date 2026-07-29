//! The persisted state format.
//!
//! There is nothing to persist yet. The header exists anyway, because a project
//! saved against this build has to still load against the build that does have
//! parameters, and a format that starts unversioned cannot acquire a version
//! later without a flag day.
//!
//! ```text
//! offset  size  field
//! 0       4     magic    "FSFR"
//! 4       4     version  u32 little-endian, currently 1
//! ```
//!
//! Growth happens by appending fields: a reader takes what it recognises and
//! stops. The version bump is reserved for the cases that genuinely break an
//! older reader, which is why `load` tolerates trailing bytes it does not
//! understand rather than treating them as corruption.

const std = @import("std");
const clap = @import("c.zig");

const c = clap.c;

/// The same four bytes as the permanent AU subtype code in
/// `cmake/CMakeLists.txt`, reused so there is one fewer arbitrary constant to
/// justify. Nothing parses it as an AU code.
pub const magic = "FSFR";

/// Bumped only when an existing field changes meaning or disappears. Appending
/// does not require it.
pub const version: u32 = 1;

pub const header_size = magic.len + @sizeOf(u32);

/// Written little-endian explicitly rather than by memory layout, so the format
/// does not silently depend on ADR 0001 holding forever.
const endian: std.builtin.Endian = .little;

pub const LoadError = error{
    /// Not our data at all: a host handed us another plugin's blob, or the
    /// stream is truncated below even the header.
    BadMagic,
    /// Written by a build newer than this one, in a way it said we cannot read.
    UnsupportedVersion,
    /// The stream ended before the header did.
    Truncated,
    /// The host's stream reported a failure.
    StreamFailed,
};

/// [main-thread]
pub fn save(stream: *const c.clap_ostream_t) bool {
    var header: [header_size]u8 = undefined;
    @memcpy(header[0..magic.len], magic);
    std.mem.writeInt(u32, header[magic.len..][0..4], version, endian);

    return writeAll(stream, &header);
}

/// [main-thread]
pub fn load(stream: *const c.clap_istream_t) LoadError!void {
    var header: [header_size]u8 = undefined;
    try readAll(stream, &header);

    if (!std.mem.eql(u8, header[0..magic.len], magic)) return error.BadMagic;

    const found = std.mem.readInt(u32, header[magic.len..][0..4], endian);
    if (found > version) return error.UnsupportedVersion;

    // Anything after the header belongs to a version that knew more than this
    // build does. Leaving it unread is the whole point of the format.
}

/// The host is free to satisfy a write partially, so this loops.
///
/// A return of `0` is not documented as meaningful on the write side. Treating
/// only negative values as failures would spin forever against a host that
/// returns `0`, so anything that is not forward progress ends the loop.
fn writeAll(stream: *const c.clap_ostream_t, bytes: []const u8) bool {
    const write = stream.write orelse return false;

    var done: usize = 0;
    while (done < bytes.len) {
        const n = write(stream, bytes.ptr + done, bytes.len - done);
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
}

/// The read side distinguishes its two failures, because a truncated project
/// file and a broken stream deserve different log lines.
fn readAll(stream: *const c.clap_istream_t, buffer: []u8) LoadError!void {
    const read = stream.read orelse return error.StreamFailed;

    var done: usize = 0;
    while (done < buffer.len) {
        const n = read(stream, buffer.ptr + done, buffer.len - done);
        if (n == 0) return error.Truncated;
        if (n < 0) return error.StreamFailed;
        done += @intCast(n);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// An in-memory stream that can be told to move fewer bytes per call than asked
/// for, which is the behaviour the loops above exist for and the one no real
/// host reproduces on demand.
///
/// Public because `plugin.zig`'s tests drive the same fixture through the
/// `clap.state` vtable. Nothing outside a test references it, so it is never
/// analysed into a release build.
pub const TestStream = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    /// Bytes moved per call. Zero means "as many as asked for".
    chunk: usize = 0,

    /// Calls remaining before the stream starts reporting an error.
    fail_after: ?usize = null,

    ostream: c.clap_ostream_t = .{},
    istream: c.clap_istream_t = .{},

    pub fn writer(self: *TestStream) *const c.clap_ostream_t {
        self.ostream = .{ .ctx = self, .write = testWrite };
        return &self.ostream;
    }

    pub fn reader(self: *TestStream) *const c.clap_istream_t {
        self.istream = .{ .ctx = self, .read = testRead };
        return &self.istream;
    }

    fn written(self: *const TestStream) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Overflowing here is a bug in the calling test, not a stream condition, so
    /// it fails immediately and says so. `@panic` rather than
    /// `std.debug.assert`: the assert is compiled out under `-Doptimize=
    /// ReleaseFast`, which this project runs its tests under, and that is the
    /// build where the bounds check is also gone and the copy would quietly
    /// corrupt the test runner.
    pub fn seed(self: *TestStream, bytes: []const u8) void {
        if (bytes.len > self.buffer.len) @panic("TestStream.seed: input larger than the fixture buffer");

        @memcpy(self.buffer[0..bytes.len], bytes);
        self.len = bytes.len;
        self.cursor = 0;
    }

    fn step(self: *TestStream, asked: usize) ?usize {
        if (self.fail_after) |remaining| {
            if (remaining == 0) return null;
            self.fail_after = remaining - 1;
        }
        return if (self.chunk == 0) asked else @min(self.chunk, asked);
    }
};

fn testWrite(
    stream: [*c]const c.clap_ostream_t,
    buffer: ?*const anyopaque,
    size: u64,
) callconv(.c) i64 {
    const self: *TestStream = @ptrCast(@alignCast(stream.*.ctx.?));
    const n = self.step(@intCast(size)) orelse return -1;

    // A full stream is a real condition a host can present, not a bug in the
    // fixture, so report it the way the CLAP stream contract says to. That is
    // also the branch `writeAll` exists to survive.
    if (n > self.buffer.len - self.len) return -1;

    const src: [*]const u8 = @ptrCast(buffer.?);
    @memcpy(self.buffer[self.len..][0..n], src[0..n]);
    self.len += n;
    return @intCast(n);
}

fn testRead(
    stream: [*c]const c.clap_istream_t,
    buffer: ?*anyopaque,
    size: u64,
) callconv(.c) i64 {
    const self: *TestStream = @ptrCast(@alignCast(stream.*.ctx.?));
    const available = self.len - self.cursor;
    if (available == 0) return 0;

    const n = self.step(@min(@as(usize, @intCast(size)), available)) orelse return -1;

    const dst: [*]u8 = @ptrCast(buffer.?);
    @memcpy(dst[0..n], self.buffer[self.cursor..][0..n]);
    self.cursor += n;
    return @intCast(n);
}

fn makeHeader(with_magic: []const u8, with_version: u32) [header_size]u8 {
    var bytes: [header_size]u8 = undefined;
    @memcpy(bytes[0..magic.len], with_magic);
    std.mem.writeInt(u32, bytes[magic.len..][0..4], with_version, endian);
    return bytes;
}

test "save writes the header and load accepts it" {
    var stream: TestStream = .{};
    try testing.expect(save(stream.writer()));

    try testing.expectEqual(@as(usize, header_size), stream.len);
    try testing.expectEqualSlices(u8, magic, stream.written()[0..magic.len]);
    try testing.expectEqual(version, std.mem.readInt(u32, stream.written()[magic.len..][0..4], endian));

    try load(stream.reader());
}

test "a stream that moves one byte at a time still round trips" {
    var stream: TestStream = .{ .chunk = 1 };
    try testing.expect(save(stream.writer()));
    try testing.expectEqual(@as(usize, header_size), stream.len);

    try load(stream.reader());
}

test "load ignores trailing bytes it does not understand" {
    // What a future build that appended a payload would leave behind.
    var stream: TestStream = .{};
    stream.seed(&makeHeader(magic, version));
    @memcpy(stream.buffer[header_size..][0..4], "junk");
    stream.len += 4;

    try load(stream.reader());
}

test "load rejects another plugin's blob" {
    var stream: TestStream = .{};
    stream.seed(&makeHeader("XXXX", version));

    try testing.expectError(error.BadMagic, load(stream.reader()));
}

test "load rejects a version from the future" {
    var stream: TestStream = .{};
    stream.seed(&makeHeader(magic, version + 1));

    try testing.expectError(error.UnsupportedVersion, load(stream.reader()));
}

test "load rejects a header that ends early" {
    var stream: TestStream = .{};
    stream.seed(makeHeader(magic, version)[0 .. header_size - 1]);

    try testing.expectError(error.Truncated, load(stream.reader()));
}

test "load reports a stream that fails mid-header" {
    var stream: TestStream = .{ .chunk = 1, .fail_after = 2 };
    stream.seed(&makeHeader(magic, version));

    try testing.expectError(error.StreamFailed, load(stream.reader()));
}

test "save reports a stream that fails mid-header" {
    var stream: TestStream = .{ .chunk = 1, .fail_after = 2 };
    try testing.expect(!save(stream.writer()));
}

test "save reports a stream with no room left" {
    // The fixture is bounded, so filling it makes the next write fail the way a
    // host out of space would. This covers the `writeAll` branch that a stream
    // returning a hard error takes, without needing the fail_after counter.
    var stream: TestStream = .{};
    stream.len = stream.buffer.len;

    try testing.expect(!save(stream.writer()));
}

test "a stream missing its function pointer is a failure, not a crash" {
    var empty_out: c.clap_ostream_t = .{ .ctx = null, .write = null };
    try testing.expect(!save(&empty_out));

    var empty_in: c.clap_istream_t = .{ .ctx = null, .read = null };
    try testing.expectError(error.StreamFailed, load(&empty_in));
    _ = &empty_out;
    _ = &empty_in;
}
