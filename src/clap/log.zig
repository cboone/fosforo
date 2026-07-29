//! Diagnostics routed through the host.
//!
//! A plugin is a shared library loaded into someone else's process, so `stderr`
//! usually goes nowhere a user or a bug report can reach it. Hosts that
//! implement `clap.log` surface messages in a console window instead, which is
//! the only channel that reliably works inside a DAW.
//!
//! The extension is optional, so a host offering nothing has to be survivable.
//! Debug builds additionally mirror every message to `stderr`, because a host
//! accepting a message is not the same as a developer being able to read it:
//! REAPER implements `clap.log` and discards what this plugin sends it.

const std = @import("std");
const builtin = @import("builtin");
const clap = @import("c.zig");

const c = clap.c;

/// Longest message that reaches the host intact.
///
/// Deliberately a stack buffer rather than a heap one. `clap_host_log.log` is
/// documented `[thread-safe]`, so a host is within its rights to be called from
/// anywhere, and formatting must not be the thing that makes a caller unsafe.
/// Nothing chooses this size for a reason beyond "longer than any message this
/// plugin writes", and overflow truncates rather than failing.
const message_size = 512;

/// The host's log extension, looked up once.
///
/// An absent extension is the common case, not an error: plenty of hosts do not
/// implement `clap.log` and a plugin is expected to carry on.
pub const Log = struct {
    ext: ?*const c.clap_host_log_t = null,
    host: ?*const c.clap_host_t = null,

    /// [main-thread] Host extensions are unreachable until `clap_plugin.init`,
    /// which is why this is a separate call rather than part of constructing an
    /// instance.
    pub fn init(host: *const c.clap_host_t) Log {
        const get_extension = host.get_extension orelse return .{ .host = host };
        const ptr = get_extension(host, &c.CLAP_EXT_LOG) orelse return .{ .host = host };

        // A host that answers the id still owes us a populated vtable, and one
        // that hands back a struct with a null `log` is easier to survive than
        // to diagnose from a crash report.
        const ext: *const c.clap_host_log_t = @ptrCast(@alignCast(ptr));
        if (ext.log == null) return .{ .host = host };

        return .{ .ext = ext, .host = host };
    }

    /// Send an already null-terminated message.
    pub fn message(self: Log, severity: c.clap_log_severity, msg: [*:0]const u8) void {
        if (self.ext) |ext| ext.log.?(self.host, severity, msg);
        mirror(severity, std.mem.span(msg));
    }

    /// Format and send. Truncates rather than failing, on the grounds that a
    /// clipped diagnostic beats a missing one.
    pub fn print(
        self: Log,
        severity: c.clap_log_severity,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var buffer: [message_size]u8 = undefined;

        // Reserve room for the marker and the terminator up front, so the
        // overflow path writes into space that was never in play rather than
        // having to back up over formatted output.
        var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - truncation_marker.len - 1]);
        const overflowed = if (writer.print(fmt, args)) |_| false else |_| true;

        var len = writer.buffered().len;
        if (overflowed) {
            @memcpy(buffer[len..][0..truncation_marker.len], truncation_marker);
            len += truncation_marker.len;
        }
        buffer[len] = 0;

        self.message(severity, buffer[0..len :0].ptr);
    }
};

/// ASCII rather than a typographic ellipsis. Truncation can land in the middle
/// of a multi-byte sequence, and appending a character that is itself multi-byte
/// would compound one piece of invalid UTF-8 into two.
const truncation_marker = "...";

/// A second copy of every message, on stderr.
///
/// Not a fallback. It runs whether or not the host took the message, because
/// "the host has it" and "you can read it" are different claims: REAPER
/// implements `clap.log` and then discards what this plugin sends it, which is
/// normal severity filtering and leaves a developer with no channel at all.
/// Mirroring means the terminal always works while you are building.
///
/// Debug builds only, for two reasons. A shipped plugin has no business writing
/// to a DAW's stderr, and this locks a mutex and makes a syscall, which is
/// precisely what ADR 0010 forbids on the audio thread. A release build should
/// not carry a path that tempts anyone into calling it from there.
///
/// Silent under `zig build test` as well. There is no host in a test binary, so
/// every message would take this path and interleave with the test runner's own
/// stream, which the build runner reads as a failed step. That does mean this
/// function has no automated coverage; it is verified by running the plugin in
/// a host, which is the only place it is meant to do anything.
fn mirror(severity: c.clap_log_severity, msg: []const u8) void {
    if (builtin.mode != .Debug or builtin.is_test) return;
    std.debug.print("[fosforo] {s}: {s}\n", .{ severityName(severity), msg });
}

fn severityName(severity: c.clap_log_severity) []const u8 {
    return switch (severity) {
        c.CLAP_LOG_DEBUG => "debug",
        c.CLAP_LOG_INFO => "info",
        c.CLAP_LOG_WARNING => "warning",
        c.CLAP_LOG_ERROR => "error",
        c.CLAP_LOG_FATAL => "fatal",
        c.CLAP_LOG_HOST_MISBEHAVING => "host-misbehaving",
        c.CLAP_LOG_PLUGIN_MISBEHAVING => "plugin-misbehaving",
        else => "unknown",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Zig runs a test binary's tests sequentially on one thread, so a file-scope
/// capture is safe here and avoids threading a context through the C ABI.
var captured: [message_size]u8 = undefined;
var captured_len: usize = 0;
var captured_severity: c.clap_log_severity = -1;

fn captureLog(
    host: [*c]const c.clap_host_t,
    severity: c.clap_log_severity,
    msg: [*c]const u8,
) callconv(.c) void {
    _ = host;
    const text = std.mem.span(msg);
    captured_len = @min(text.len, captured.len);
    @memcpy(captured[0..captured_len], text[0..captured_len]);
    captured_severity = severity;
}

const capturing_ext: c.clap_host_log_t = .{ .log = captureLog };
const empty_ext: c.clap_host_log_t = .{ .log = null };

fn getCapturingExtension(
    host: [*c]const c.clap_host_t,
    extension_id: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    _ = host;
    if (std.mem.eql(u8, std.mem.span(extension_id), &c.CLAP_EXT_LOG)) return &capturing_ext;
    return null;
}

fn getEmptyExtension(
    host: [*c]const c.clap_host_t,
    extension_id: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    _ = host;
    if (std.mem.eql(u8, std.mem.span(extension_id), &c.CLAP_EXT_LOG)) return &empty_ext;
    return null;
}

fn getNothing(
    host: [*c]const c.clap_host_t,
    extension_id: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    _ = host;
    _ = extension_id;
    return null;
}

fn testHost(get_extension: @FieldType(c.clap_host_t, "get_extension")) c.clap_host_t {
    return .{
        .clap_version = clap.version,
        .host_data = null,
        .name = "fosforo test",
        .vendor = "Catamount",
        .url = "",
        .version = "0.0.0",
        .get_extension = get_extension,
        .request_restart = null,
        .request_process = null,
        .request_callback = null,
    };
}

test "a host offering clap.log receives the message" {
    const host = testHost(getCapturingExtension);
    const log = Log.init(&host);
    try testing.expect(log.ext != null);

    captured_len = 0;
    log.message(c.CLAP_LOG_INFO, "hello");
    try testing.expectEqualStrings("hello", captured[0..captured_len]);
    try testing.expectEqual(c.CLAP_LOG_INFO, captured_severity);

    log.print(c.CLAP_LOG_WARNING, "sample rate {d}", .{48000});
    try testing.expectEqualStrings("sample rate 48000", captured[0..captured_len]);
    try testing.expectEqual(c.CLAP_LOG_WARNING, captured_severity);
}

test "an over-long message is truncated rather than dropped" {
    const host = testHost(getCapturingExtension);
    const log = Log.init(&host);

    captured_len = 0;
    log.print(c.CLAP_LOG_DEBUG, "{s}", .{"x" ** (message_size * 2)});

    try testing.expect(captured_len > 0);
    try testing.expect(captured_len < message_size);
    try testing.expect(std.mem.endsWith(u8, captured[0..captured_len], truncation_marker));
}

test "a host without the extension is survivable" {
    // Three shapes a host can take: no `get_extension` at all, one that does not
    // know the id, and one that answers with a vtable it never filled in. All
    // three have to leave `ext` null rather than producing a null call.
    inline for (.{ null, getNothing, getEmptyExtension }) |get_extension| {
        const host = testHost(get_extension);
        const log = Log.init(&host);
        try testing.expect(log.ext == null);
    }
}
