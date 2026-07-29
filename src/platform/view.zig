//! The `NSView` the host embeds, and nothing else.
//!
//! Deliberately knows nothing about Metal. The renderer hangs a layer off the
//! view it is handed (ADR 0005), so a `CAMetalLayer` is never named here, and
//! this file stays the answer to "what does AppKit need" rather than to "what
//! does the GPU need".
//!
//! A plain `NSView`, with no class registered at runtime. The CLAP embedding
//! protocol has the host call `set_size` when the editor is dragged, and this
//! build reports itself as non-resizable anyway, so there is nothing a
//! `setFrameSize:` override would catch. Issue #5 registers a subclass when the
//! display link and the resize seam give it a reason to.

const std = @import("std");
const objc = @import("objc");
const platform = @import("objc.zig");

const CGRect = platform.CGRect;

/// The scale to assume when AppKit cannot be asked.
///
/// Reachable only before the view joins a window, which `Editor.setParent`
/// avoids by attaching first and reading the scale second. 1.0 rather than 2.0
/// on the grounds that guessing low renders sharp content at the wrong size,
/// while guessing high renders blurry content: the first is a bug someone
/// notices, the second is one they live with.
const fallback_scale: f64 = 1.0;

pub const View = struct {
    object: objc.Object,

    /// [main-thread] Create the view, sized in logical points.
    ///
    /// The autoresizing mask matters even though nothing resizes yet: a host
    /// that sizes its window slightly differently from what `get_size` reported
    /// should get a view filling it rather than one sitting in a corner with
    /// the host's background showing around it.
    pub fn create(width: u32, height: u32) ?View {
        platform.assertMainThread();

        const frame: CGRect = .{ .size = .{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        } };

        const object = objc.getClass("NSView").?
            .msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{frame});
        if (object.value == null) return null;

        object.msgSend(void, "setAutoresizingMask:", .{
            platform.autoresizing.width_sizable | platform.autoresizing.height_sizable,
        });

        return .{ .object = object };
    }

    /// [main-thread] Add the view to the host's parent view.
    ///
    /// The host's view retains it, which is why `destroy` removes it from the
    /// superview before releasing: dropping our reference while the host still
    /// holds one would leave a view alive with nothing drawing into it.
    pub fn attach(self: View, parent: *anyopaque) void {
        platform.assertMainThread();
        objc.Object.fromId(parent).msgSend(void, "addSubview:", .{self.object});
    }

    /// [main-thread] Remove the view from its superview and give up ownership.
    pub fn destroy(self: View) void {
        platform.assertMainThread();
        self.object.msgSend(void, "removeFromSuperview", .{});
        self.object.release();
    }

    /// [main-thread] `hide` in CLAP's vocabulary does not free anything; it
    /// stops the editor being drawn and is expected to be reversible.
    pub fn setHidden(self: View, hidden: bool) void {
        platform.assertMainThread();
        self.object.msgSend(void, "setHidden:", .{hidden});
    }

    /// [main-thread] Backing pixels per logical point, which is 2.0 on every
    /// Retina display and 1.0 on everything else.
    ///
    /// Falls back through the main screen to `fallback_scale`, because a view
    /// has no window until it is in one and `[nil backingScaleFactor]` would
    /// answer 0. A zero scale is a zero-sized drawable, which Metal rejects.
    pub fn backingScale(self: View) f64 {
        platform.assertMainThread();

        const window = self.object.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            const scale = window.msgSend(f64, "backingScaleFactor", .{});
            if (scale > 0) return scale;
        }

        const screen = objc.getClass("NSScreen").?.msgSend(objc.Object, "mainScreen", .{});
        if (screen.value != null) {
            const scale = screen.msgSend(f64, "backingScaleFactor", .{});
            if (scale > 0) return scale;
        }

        return fallback_scale;
    }

    /// The pointer the renderer attaches its surface to. Opaque by the time it
    /// crosses the seam, which is the point.
    pub fn handle(self: View) *anyopaque {
        return self.object.value.?;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// No test creates a view. A test binary has no `NSApplication` and no host
// window, so an `NSView` built here would be exercising a different environment
// from the one this code runs in, and a green result would mean less than it
// appears to. The view is verified by opening the editor in REAPER and Logic.

test {
    // Forces the message sends above to be type-checked in the file that owns
    // them rather than at the first call site in `gui.zig`.
    testing.refAllDecls(@This());
    testing.refAllDecls(View);
}
