//! The Objective-C types that cross `objc_msgSend`, and the two helpers
//! everything above this file needs.
//!
//! ADR 0008 anticipated this file holding hand-rolled message-send wrappers.
//! It does not need to: adopting `zig-objc` was the point of that decision, and
//! what is left over is the types those wrappers pass and the checks nobody
//! else is positioned to make.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");

/// Core Graphics geometry, as the 64-bit ABI defines it.
///
/// `extern` is not decoration. `zig-objc` refuses a struct argument that is not
/// `extern` or `packed`, because anything else has no guaranteed layout and
/// would be handed to `objc_msgSend` as whatever the compiler felt like. That
/// refusal is a compile error here and was a segfault before Zig 0.16.
pub const CGFloat = f64;
pub const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const CGSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };

/// `NSView.autoresizingMask` values. Restated because AppKit's headers are
/// Objective-C and `translate-c` cannot read them, which is the same position
/// `src/clap/c.zig` is in for CLAP's object-like macros, minus the header
/// symbol that lets that file prove its restatements agree.
pub const autoresizing = struct {
    pub const width_sizable: u64 = 2;
    pub const height_sizable: u64 = 16;
};

/// Wrap a null-terminated Zig string as an `NSString`.
///
/// The result is autoreleased, so every caller has to be inside a pool. That is
/// not a caveat worth avoiding: the alternative is an owned string that each
/// caller has to remember to release, and the calls this exists for are already
/// inside a pool for the sake of the objects they return.
pub fn nsString(text: [*:0]const u8) objc.Object {
    return objc.getClass("NSString").?.msgSend(objc.Object, "stringWithUTF8String:", .{text});
}

/// Read an `NSString`'s UTF-8 bytes. Borrowed from the string, so the slice
/// dies with it, which for an autoreleased string means at the end of the pool.
pub fn utf8(string: objc.Object) []const u8 {
    if (string.value == null) return "";
    const ptr = string.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return "";
    return std.mem.span(ptr);
}

/// Trap an AppKit mutation that reached the wrong thread.
///
/// The view lifecycle belongs to the host's main thread, and the render loop
/// runs on a display-link thread that must never touch it. Writing that as an
/// assertion rather than a comment is what makes it possible to find the
/// violation at the point it happens instead of inferring it later from a
/// corrupted view hierarchy.
///
/// Debug builds only. It is a message send, and a release build should not pay
/// for one on every editor callback.
pub fn assertMainThread() void {
    if (builtin.mode != .Debug) return;
    std.debug.assert(isMainThread());
}

/// The other half of the same rule, from the other side.
///
/// ADR 0010 says the render thread touches Metal only and never mutates AppKit
/// state. The way that stays true is for the render path to be unreachable from
/// the main thread in the first place, so a `frame` or a `resize` that somebody
/// wired back into a lifecycle callback trips here rather than working by
/// accident until two threads happen to overlap.
///
/// This is only sound because the display link is the sole caller of the render
/// path. Anything that wants to draw from the main thread has to go through the
/// mailbox instead, which is the point.
pub fn assertNotMainThread() void {
    if (builtin.mode != .Debug) return;
    std.debug.assert(!isMainThread());
}

fn isMainThread() bool {
    return objc.getClass("NSThread").?.msgSend(bool, "isMainThread", .{});
}

// The whole calling convention below depends on these, and every one of them is
// true only on a 64-bit target. ADR 0001 makes that permanent, but a comptime
// check costs nothing and turns a wrong assumption into a compile error rather
// than a garbled view frame.
comptime {
    if (@sizeOf(CGFloat) != 8) @compileError("CGFloat is f64 only on 64-bit targets");
    if (@sizeOf(CGPoint) != 16) @compileError("CGPoint must be two CGFloats");
    if (@sizeOf(CGSize) != 16) @compileError("CGSize must be two CGFloats");
    if (@sizeOf(CGRect) != 32) @compileError("CGRect must be a CGPoint and a CGSize");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Nothing here sends a message. Creating Objective-C objects in a test binary
// with no `NSApplication` is a different environment from the one this code
// runs in, so a passing test would prove less than it appears to. The message
// sends are verified by running the plugin in a host, and the layout, which is
// what actually breaks silently, is asserted at comptime above.

test {
    // Forces the message-send signatures above to be type-checked here rather
    // than at whichever call site happens to reach them first.
    testing.refAllDecls(@This());
}

test "CGRect nests the point and size the way AppKit reads it" {
    const rect: CGRect = .{ .origin = .{ .x = 1, .y = 2 }, .size = .{ .width = 3, .height = 4 } };

    try testing.expectEqual(@as(usize, 0), @offsetOf(CGRect, "origin"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(CGRect, "size"));
    try testing.expectEqual(@as(CGFloat, 3), rect.size.width);
}

test "a default-constructed rect is the zero rect" {
    const rect: CGRect = .{};

    try testing.expectEqual(@as(CGFloat, 0), rect.origin.x);
    try testing.expectEqual(@as(CGFloat, 0), rect.size.height);
}
