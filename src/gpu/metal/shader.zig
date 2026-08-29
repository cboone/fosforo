//! Where the shader source comes from, and nothing about what is done with it.
//!
//! [ADR 0009](../../../docs/adr/0009-runtime-shader-compilation.md) chose runtime
//! MSL compilation partly so the shader could be reloaded without relaunching a
//! host, and its Consequences already say how: "Debug builds reload from disk;
//! release builds use the embedded source." This file is that sentence. #61 is
//! where it was implemented.
//!
//! **It names no Metal type**, which is why it can sit beside `renderer.zig`
//! rather than inside it without weakening that file's claim to be the only one
//! allowed to. It holds the embedded copy, the two gates, the path selection, the
//! change detection and the read; the compile and the swap stay next door, where
//! the device is.
//!
//! Nothing here allocates. The read lands in a caller-owned `Buffer`, on the same
//! reasoning as `Editor.samples` and the stack buffer in `clap/log.zig`: the one
//! thread that calls this has no allocator and should not acquire one to read
//! eight kilobytes.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const io = @import("../../platform/io.zig");

/// The bytes this build was compiled from, and what every test at the foot of
/// `renderer.zig` talks about.
///
/// Reached through the import table rather than by relative path: `@embedFile`
/// resolves relative to the importing file and cannot escape the module root,
/// which is src/, and `shaders/` sits beside it. `build.zig` puts it there.
pub const embedded = @embedFile("scope.metal");

/// Whether this build reads the shader from a file at all.
///
/// **`!builtin.is_test` is not belt and braces.** A test binary is a Debug build,
/// so `builtin.mode` alone would put filesystem reads inside `zig build test`,
/// which is the hermetic path ADR 0009 exists to protect, and the test below is
/// what stops that regressing. `src/clap/log.zig` disables its stderr mirror on
/// exactly this pair, for a related reason.
///
/// The two gates this sits beside guarantee different things and neither
/// substitutes for the other: `build.zig` decides whether the path exists in the
/// binary at all, and this decides whether anything reads it.
pub const live = builtin.mode == .Debug and !builtin.is_test;

/// The override, which is the only reason any of this is testable.
///
/// It also survives a moved worktree with no rebuild, and lets one installed
/// debug bundle be pointed at whichever worktree is being iterated in, which
/// composes with `CLAP_PATH` rather than duplicating it. Invisible in Logic
/// twice over: an app launched through LaunchServices does not inherit a shell's
/// environment, and Logic cannot be launched from a terminal at all. That costs
/// nothing, because the Audio Unit is `--release=fast` from CMake and has no
/// reload path under any circumstances.
pub const path_env = "FOSFORO_SHADER_PATH";

/// The largest shader this build will read.
///
/// `shaders/scope.metal` is around eight kilobytes; the bound is what makes the
/// read allocation-free, and the test below pins the headroom against the file it
/// is for, so a shader that grew eightfold fails a test rather than being refused
/// at runtime by a developer who has to work out why.
pub const max_bytes = 64 * 1024;

/// Storage for a resolved path, owned by the caller.
///
/// A caller's buffer rather than a static one, because the callers are on two
/// different threads: the watcher polls four times a second while `init` and
/// `probe` resolve on the main thread. One shared buffer would be a data race
/// for no saving, since this is a kilobyte on a stack that already carries the
/// 64 KiB `Buffer`.
pub const PathBuffer = [std.fs.max_path_bytes]u8;

/// The file this process should compile from, or null for the embedded copy.
///
/// **The result is copied into `buf`, and that is a correctness requirement
/// rather than a convenience.** `std.c.getenv` returns a pointer into the process
/// environment block, and a `setenv` anywhere in the host can free it: `setenv`
/// may reallocate the `environ` array and release the old entry. The watcher then
/// holds the slice across a `statFile`, a `readFile` and a log call, on a thread
/// that shares nothing with whoever might be writing the environment. Returning
/// the borrowed slice would make that a use-after-free appearing only when a host
/// mutates its own environment at runtime.
///
/// **`std.c.getenv`, and there is no alternative in Zig 0.16.** `std.posix.getenv`
/// and `std.process.getEnvVarOwned` are both gone; what replaced them is
/// `std.process.Environ`, which hangs off the `std.process.Init` that a `main`
/// receives, and a plugin loaded into a host's address space has no `main`.
/// `link_libc` in `build.zig`'s `Core.module` is what makes this callable.
pub fn resolvePath(buf: *PathBuffer) ?[]const u8 {
    if (!live) return null;

    const env: ?[]const u8 = if (std.c.getenv(path_env)) |raw| std.mem.span(raw) else null;
    return copyInto(buf, choosePath(env, build_options.shader_path));
}

/// Take ownership of a chosen path by copying it.
///
/// Split out of `resolvePath` so the copy is testable, which it otherwise is not:
/// `live` is false in a test build by design, so `resolvePath` returns null there
/// and a test of it would assert nothing about the property that matters.
///
/// A path longer than the buffer is refused rather than truncated, on the
/// reasoning `read` gives for a file that exactly fills its own: half a path is a
/// different file, and opening it would be worse than falling back.
fn copyInto(buf: *PathBuffer, chosen: ?[]const u8) ?[]const u8 {
    const path = chosen orelse return null;
    if (path.len > buf.len) return null;

    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

/// Pick between the two places a path can come from.
///
/// Pure, so the ordering is testable without an environment, a build, or a
/// filesystem, which is the whole reason it is separate from `resolvePath`.
///
/// **Existence is deliberately not checked here.** A path that is set and
/// absolute wins; if it then turns out to be missing, the caller falls back to
/// the embedded copy rather than to the build option, because the developer said
/// which file they meant and silently substituting a different one would be worse
/// than saying so.
///
/// **A relative path is refused rather than resolved.** A plugin's working
/// directory belongs to the DAW, so `shaders/scope.metal` happens to be right
/// when REAPER was launched from a worktree and means nothing anywhere else.
/// Empty is "not set" from either side, because `build.zig` says "no file" with
/// `""` and a shell says it by exporting an empty variable.
pub fn choosePath(env: ?[]const u8, option: []const u8) ?[]const u8 {
    if (env) |p| if (p.len > 0 and std.fs.path.isAbsolute(p)) return p;
    if (option.len > 0 and std.fs.path.isAbsolute(option)) return option;
    return null;
}

/// What the file looked like when it was last read.
///
/// **Three fields, not one, and the inode is the one that is easy to omit.** Many
/// editors save by writing a temporary file and renaming it over the target, so
/// the path acquires a *new* inode carrying a plausible mtime and an identical
/// size. A detector watching mtime alone misses a same-nanosecond rename; one
/// watching size alone misses every edit that does not change the length. This is
/// how a hot reloader appears to work and then quietly stops.
pub const Stamp = struct {
    mtime_ns: i96,
    size: u64,
    inode: std.Io.File.INode,

    pub fn differs(self: Stamp, other: Stamp) bool {
        return self.mtime_ns != other.mtime_ns or
            self.size != other.size or
            self.inode != other.inode;
    }
};

/// Stat the file, without opening it for reading.
///
/// Reached through `io.get()`, the project's one `std.Io` instance, because Zig
/// 0.16 moved file operations behind an `Io` along with the clock and `sleep`.
/// Safe from a thread `std.Thread.spawn` created, on the argument
/// `src/platform/io.zig` already makes for `sleep` and which was re-confirmed
/// against the pinned toolchain for this call: the posix implementation discards
/// its userdata and reaches `fstatat` through a syscall region that takes the
/// uncancelable branch whenever the runtime's threadlocal is unset, and only
/// threads the runtime itself spawns ever set it.
///
/// An absolute `sub_path` ignores the directory, and `choosePath` has already
/// refused anything relative.
pub fn stamp(path: []const u8) !Stamp {
    const st = try std.Io.Dir.cwd().statFile(io.get(), path, .{});
    return .{ .mtime_ns = st.mtime.nanoseconds, .size = st.size, .inode = st.inode };
}

/// A shader read off disk, NUL-terminated so it can reach `nsString` unchanged.
pub const Buffer = struct {
    bytes: [max_bytes + 1]u8 = undefined,
    len: usize = 0,

    pub fn source(self: *const Buffer) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }
};

/// Read the whole file into `buf`.
///
/// **A file that exactly fills the buffer is refused rather than truncated.**
/// `Io.Dir.readFile` documents the ambiguity in its own docstring: a returned
/// length equal to the buffer's could mean the file fit exactly or that the
/// buffer ran out. Half a shader compiles about as often as it does not, and the
/// diagnostic from a truncated one would point at a line the author cannot see is
/// missing.
pub fn read(buf: *Buffer, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFile(io.get(), path, buf.bytes[0..max_bytes]);
    if (bytes.len == max_bytes) return error.ShaderTooLarge;

    buf.bytes[bytes.len] = 0;
    buf.len = bytes.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Every test here is pure. Nothing below opens a file, which is the property the
// last test asserts rather than merely observes.

test {
    testing.refAllDecls(@This());
}

test "the environment wins, and an empty value is not a path" {
    try testing.expectEqualStrings("/a/x.metal", choosePath("/a/x.metal", "/b/y.metal").?);
    try testing.expectEqualStrings("/b/y.metal", choosePath("", "/b/y.metal").?);
    try testing.expectEqualStrings("/b/y.metal", choosePath(null, "/b/y.metal").?);
    try testing.expectEqual(@as(?[]const u8, null), choosePath(null, ""));
    try testing.expectEqual(@as(?[]const u8, null), choosePath("", ""));
}

test "a relative path is refused rather than resolved against the host's directory" {
    // A plugin's working directory belongs to the DAW. `shaders/scope.metal`
    // happens to be right when REAPER was launched from a worktree and means
    // nothing anywhere else, which is the worst of both.
    try testing.expectEqualStrings("/b/y.metal", choosePath("shaders/scope.metal", "/b/y.metal").?);
    try testing.expectEqual(@as(?[]const u8, null), choosePath("shaders/scope.metal", ""));

    // The same rule from the other side, which is what `debugShaderPath` in
    // `build.zig` already refuses to emit. Two refusals rather than one, because
    // the option and the variable are set by different things.
    try testing.expectEqual(@as(?[]const u8, null), choosePath(null, "shaders/scope.metal"));
}

test "a change is any of three fields, because editors save by rename" {
    const base: Stamp = .{ .mtime_ns = 1, .size = 10, .inode = 7 };

    try testing.expect(!base.differs(base));
    try testing.expect(base.differs(.{ .mtime_ns = 2, .size = 10, .inode = 7 }));
    try testing.expect(base.differs(.{ .mtime_ns = 1, .size = 11, .inode = 7 }));

    // The one that matters, and the one a two-field stamp misses: an editor that
    // wrote a temporary file and renamed it over the target within the same
    // nanosecond, with the length unchanged.
    try testing.expect(base.differs(.{ .mtime_ns = 1, .size = 10, .inode = 8 }));
}

test "the embedded shader fits the read buffer with room to spare" {
    // The closest legitimate thing to "the file and the binary agree", and it
    // costs no I/O. They agree by construction anyway: `@embedFile` resolves
    // through `build.zig`'s anonymous import, so the compiler records a cache
    // dependency and an edited shader rebuilds this binary before it runs.
    try testing.expect(embedded.len > 0);
    try testing.expect(embedded.len * 8 < max_bytes);
}

test "nothing is read from disk in a test build" {
    // **Not vacuous.** A test binary is a Debug build, so this fails the moment
    // `!builtin.is_test` is dropped from `live`, which is the exact regression
    // that would put filesystem I/O inside the hermetic path ADR 0009 protects.
    var buf: PathBuffer = undefined;
    try testing.expect(!live);
    try testing.expectEqual(@as(?[]const u8, null), resolvePath(&buf));
}

test "a resolved path is copied rather than borrowed" {
    // The property the whole `PathBuffer` parameter exists for. `getenv` returns
    // a pointer into the environment block, a `setenv` in the host can free it,
    // and the watcher holds the result across a stat, a read and a log call. A
    // borrowed slice would be a use-after-free that appears only when a host
    // mutates its own environment, so aliasing is what has to be asserted.
    var buf: PathBuffer = undefined;
    const source = "/somewhere/scope.metal";

    const copied = copyInto(&buf, source).?;

    try testing.expectEqualStrings(source, copied);
    try testing.expect(copied.ptr != source.ptr);
    try testing.expect(copied.ptr == buf[0..].ptr);
}

test "a path too long for the buffer is refused rather than truncated" {
    // Half a path is a different file, and opening it would be worse than the
    // fallback. Same reasoning as `read`'s exactly-fills-the-buffer refusal.
    var buf: PathBuffer = undefined;
    const long = "/" ** (@sizeOf(PathBuffer) + 1);

    try testing.expectEqual(@as(?[]const u8, null), copyInto(&buf, long));
    try testing.expectEqual(@as(?[]const u8, null), copyInto(&buf, null));
}
