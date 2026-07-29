//! The renderer seam.
//!
//! ADR 0005 forbids Metal types above this file, with one backend behind it and
//! no second one planned. That is a hygiene decision rather than a portability
//! one: it converts an eventual port from "excavate Metal calls out of a
//! renderer they have grown through" into "write a second backend against a
//! known handful of operations".
//!
//! The interface is shaped to this project's algorithm rather than to graphics
//! in general, which is what keeps it small. It also stays honest about what
//! exists: there is no `resize` and no texture creation here, because nothing
//! calls them yet. Operations arrive with the phase that has a caller for them.

const std = @import("std");

/// Pixels, in the drawable's own terms rather than the window's. The caller
/// works in logical points and hands the scale factor over separately, because
/// only the backend knows what it wants to do with it.
pub const Size = struct { width: u32, height: u32 };

/// The native view the backend attaches its drawable surface to.
///
/// Deliberately opaque. On macOS this is an `NSView`, and what the backend
/// hangs off it is the backend's business: naming `CAMetalLayer` here would be
/// exactly the leak ADR 0005 exists to prevent, since a Metal layer is a Metal
/// type wearing QuartzCore's coat.
pub const NativeView = *anyopaque;

/// Every way starting a renderer can fail. Each is a real machine condition
/// rather than a programming error, so each is reported rather than asserted.
pub const Error = error{
    /// No GPU. Reachable on a machine with no Metal support, and worth checking
    /// first when a host that sandboxes plugins fails where another does not.
    NoDevice,
    /// The shader source did not compile. See `Diagnostics` for what went wrong.
    ShaderCompilationFailed,
    /// The shaders compiled but could not be assembled into a pipeline state.
    PipelineCreationFailed,
    /// A drawable surface could not be created or attached to the view.
    SurfaceCreationFailed,
};

/// A fixed buffer the backend writes a human-readable failure into.
///
/// This exists so a Metal compiler diagnostic can reach the host's log without
/// the gpu layer importing the log or the clap layer importing Metal. Both
/// directions would be a layering violation, and the message is the difference
/// between "the editor did not open" and a file and line number.
///
/// Fixed rather than allocated: the failure paths this serves are the ones
/// where the least should be assumed about the process, and truncating a
/// compiler error still leaves the first and most useful line intact.
pub const Diagnostics = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    /// Truncates rather than failing. A clipped diagnostic beats a missing one.
    pub fn set(self: *Diagnostics, text: []const u8) void {
        self.len = @min(text.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], text[0..self.len]);
    }

    /// Empty when nothing was recorded, so a caller can log it unconditionally.
    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// The one backend. Aliased rather than dispatched through a vtable, because
/// paying for indirection with a single implementation would buy nothing that
/// the comptime check below does not buy for free.
pub const Renderer = @import("metal/renderer.zig").Renderer;

// ADR 0005 asks a reviewer to treat a Metal type named above this seam as a
// defect. This is that review, mechanized. Every parameter and return type
// below is drawn from this file's own vocabulary, so a backend that started
// taking an `objc.Object` or handing back an `MTLDevice` stops compiling
// instead of quietly passing.
comptime {
    assertSignature("init", @TypeOf(Renderer.init), fn (NativeView, Size, f64, *Diagnostics) Error!Renderer);
    assertSignature("deinit", @TypeOf(Renderer.deinit), fn (*Renderer) void);
    assertSignature("frame", @TypeOf(Renderer.frame), fn (*Renderer) void);
}

fn assertSignature(comptime name: []const u8, comptime Found: type, comptime Want: type) void {
    if (Found != Want) @compileError(
        "the renderer backend's `" ++ name ++ "` is " ++ @typeName(Found) ++
            ", but the seam declares " ++ @typeName(Want),
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Nothing here constructs a `Renderer`. Doing so would acquire a GPU, and
// `zig build test` runs in CI on a runner whose Metal support is not something
// this project should depend on (ADR 0009). The backend is verified by running
// the plugin in a host; what is testable without one is tested here.

test "diagnostics start empty and can be read unconditionally" {
    const diags: Diagnostics = .{};
    try testing.expectEqualStrings("", diags.message());
}

test "a diagnostic longer than the buffer is truncated rather than overflowing" {
    const capacity = @typeInfo(@FieldType(Diagnostics, "buffer")).array.len;

    var diags: Diagnostics = .{};
    diags.set("x" ** (capacity * 2));

    try testing.expectEqual(capacity, diags.message().len);
}

test "setting a diagnostic twice replaces it rather than appending" {
    var diags: Diagnostics = .{};
    diags.set("program_source:30:1: error: unknown type name");
    diags.set("no device");

    try testing.expectEqualStrings("no device", diags.message());
}
