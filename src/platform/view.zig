//! The `NSView` the host embeds, and nothing else.
//!
//! Deliberately knows nothing about Metal. The renderer hangs a layer off the
//! view it is handed (ADR 0005), so a `CAMetalLayer` is never named here, and
//! this file stays the answer to "what does AppKit need" rather than to "what
//! does the GPU need".
//!
//! Unlike issue #4, the view is now a subclass registered at runtime. Three
//! things a plain `NSView` cannot report are load-bearing once a render thread
//! exists: that the view resized, that its backing scale changed, and that it
//! moved to a window on a different display. Each is a main-thread AppKit
//! callback, and each ends in a post to the mailbox above.
//!
//! The one place this file touches the layer is `setFrameSize:`, which sets the
//! layer's frame. That is a `CALayer` message naming no Metal type, and it is
//! geometry belonging to the view hierarchy rather than to the drawable.

const std = @import("std");
const objc = @import("objc");
const platform = @import("objc.zig");
const display_link = @import("displaylink.zig");

const CGRect = platform.CGRect;
const CGSize = platform.CGSize;
const c = objc.c;

/// The scale to assume when AppKit cannot be asked.
///
/// Reachable only before the view joins a window, which `Editor.setParent`
/// avoids by attaching first and reading the scale second. 1.0 rather than 2.0
/// on the grounds that guessing low renders sharp content at the wrong size,
/// while guessing high renders blurry content: the first is a bug someone
/// notices, the second is one they live with.
const fallback_scale: f64 = 1.0;

/// How the view reports upward without knowing what is above it.
///
/// Held by pointer in an instance variable, so whoever supplies one has to keep
/// it at a stable address for as long as the view exists. `Editor` satisfies
/// that by living inside the heap-allocated `Instance`.
pub const Delegate = struct {
    context: *anyopaque,

    /// [main-thread] The view's size in logical points changed.
    resized: *const fn (context: *anyopaque, width: u32, height: u32) void,

    /// [main-thread] The backing scale factor, the window, or the display
    /// changed. The receiver re-reads whichever of those it cares about rather
    /// than being told, because AppKit delivers these as three separate
    /// callbacks that all mean "your assumptions about the screen are stale".
    display_changed: *const fn (context: *anyopaque) void,
};

pub const View = struct {
    object: objc.Object,

    /// [main-thread] Create the view, sized in logical points.
    ///
    /// The autoresizing mask matters: a host that resizes its own window and
    /// expects the embedded view to follow does exactly that and never calls
    /// `set_size`, so this is one of the two paths a resize can arrive by.
    pub fn create(width: u32, height: u32, delegate: *const Delegate) ?View {
        platform.assertMainThread();

        const class = viewClass() orelse return null;

        const frame: CGRect = .{ .size = .{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        } };

        const object = class.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{frame});
        if (object.value == null) return null;

        // Before the autoresizing mask, because setting that can provoke a
        // layout pass, and `setFrameSize:` reads the delegate.
        object.setInstanceVariable(delegate_ivar, .{ .value = @ptrCast(@constCast(delegate)) });

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
    ///
    /// Clears the delegate first. AppKit sends `viewDidMoveToWindow` while a
    /// view is being pulled out of its hierarchy, and a callback that fired
    /// after the owner had begun tearing itself down would be reading a pointer
    /// on its way out.
    pub fn destroy(self: View) void {
        platform.assertMainThread();
        self.object.setInstanceVariable(delegate_ivar, .{ .value = null });
        self.object.msgSend(void, "removeFromSuperview", .{});
        self.object.release();
    }

    /// [main-thread] `hide` in CLAP's vocabulary does not free anything; it
    /// stops the editor being drawn and is expected to be reversible.
    pub fn setHidden(self: View, hidden: bool) void {
        platform.assertMainThread();
        self.object.msgSend(void, "setHidden:", .{hidden});
    }

    /// [main-thread] Resize the view, in logical points.
    ///
    /// Deliberately goes through `setFrameSize:` rather than posting the new
    /// size directly, so a resize the host asked for and a resize the host
    /// performed itself arrive by exactly one path. Two paths is how the layer
    /// and the drawable end up disagreeing about which one was last.
    pub fn setSize(self: View, width: u32, height: u32) void {
        platform.assertMainThread();
        self.object.msgSend(void, "setFrameSize:", .{CGSize{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        }});
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

    /// [main-thread] Which display the view is currently on, for the display
    /// link to pace against.
    ///
    /// AppKit does not offer this directly. A screen carries it in its device
    /// description under `NSScreenNumber`, boxed in an `NSNumber`. The same
    /// fallback chain as `backingScale`, and reachable for the same reason: a
    /// view has no window until it is in one, and a window may sit where no
    /// screen claims it.
    pub fn displayID(self: View) display_link.DisplayID {
        platform.assertMainThread();

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const window = self.object.msgSend(objc.Object, "window", .{});
        if (window.value != null) {
            const screen = window.msgSend(objc.Object, "screen", .{});
            if (screen.value != null) {
                const description = screen.msgSend(objc.Object, "deviceDescription", .{});
                const number = description.msgSend(objc.Object, "objectForKey:", .{
                    platform.nsString("NSScreenNumber"),
                });
                if (number.value != null) {
                    const id = number.msgSend(u32, "unsignedIntValue", .{});
                    if (id != 0) return id;
                }
            }
        }

        return display_link.CGMainDisplayID();
    }

    /// The pointer the renderer attaches its surface to. Opaque by the time it
    /// crosses the seam, which is the point.
    pub fn handle(self: View) *anyopaque {
        return self.object.value.?;
    }
};

// ---------------------------------------------------------------------------
// The runtime subclass.
// ---------------------------------------------------------------------------

const delegate_ivar = "fosforo_delegate";

/// Registered once per loaded copy of this plugin, and never disposed.
///
/// `objc_disposeClassPair` is illegal while instances exist, and there is no
/// point in the lifetime of a plugin where the host guarantees none do. A class
/// is process-lifetime by nature; leaving it registered costs one class object.
var registered_class: ?objc.Class = null;

/// Distinct per loaded image, which is what the class name is derived from.
/// Its address is the only thing it is ever read for.
var class_seed: u8 = 0;

/// The subclass, registering it on the first call.
///
/// No lock. Every caller reaches this through `View.create`, which CLAP
/// guarantees is on the main thread and which asserts as much in debug builds,
/// so the check-then-set below cannot interleave with itself.
fn viewClass() ?objc.Class {
    platform.assertMainThread();

    if (registered_class) |class| return class;

    const superclass = objc.getClass("NSView") orelse return null;

    // The name has to be unique across every copy of this plugin in the
    // process, and there really can be more than one: a user with the CLAP and
    // the clap-wrapper Audio Unit both installed loads two. `objc_allocateClassPair`
    // returns nil on a name that is taken, so a shared name would leave the
    // second copy with no view class at all.
    //
    // Reusing the class the first copy registered would be worse than failing.
    // Its method implementations point into that copy's `__TEXT`, so every view
    // the second copy created would call into the first, and all of them would
    // dangle the moment it unloaded.
    var name_buffer: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(
        &name_buffer,
        "FosforoScopeView_{x}",
        .{@intFromPtr(&class_seed)},
    ) catch return null;

    const class = objc.allocateClassPair(superclass, name) orelse return null;
    if (!class.addIvar(delegate_ivar)) {
        objc.disposeClassPair(class);
        return null;
    }

    // `replaceMethod` rather than `addMethod`: all three exist on `NSView`
    // already, and each implementation below calls through to the one it is
    // standing in front of.
    class.replaceMethod("setFrameSize:", setFrameSize);
    class.replaceMethod("viewDidChangeBackingProperties", viewDidChangeBackingProperties);
    class.replaceMethod("viewDidMoveToWindow", viewDidMoveToWindow);

    objc.registerClassPair(class);
    registered_class = class;
    return class;
}

/// The delegate, or null on a view that is being torn down.
fn delegateOf(target: c.id) ?*const Delegate {
    const stored = objc.Object.fromId(target).getInstanceVariable(delegate_ivar);
    return @ptrCast(@alignCast(stored.value orelse return null));
}

/// The single funnel every size change passes through, whichever side it came
/// from: CLAP's `set_size` reaches it via `View.setSize`, and a host that
/// resized its own window reaches it via the autoresizing mask.
fn setFrameSize(target: c.id, sel: c.SEL, size: CGSize) callconv(.c) void {
    _ = sel;

    const self = objc.Object.fromId(target);
    self.msgSendSuper(objc.getClass("NSView").?, void, "setFrameSize:", .{size});

    // Insurance rather than ceremony. This view is layer-hosting, which means
    // AppKit is not obliged to keep the layer's geometry in step with it the
    // way it would for a layer-backed view. Setting it here is one message and
    // is harmless if AppKit already did; not setting it is a layer that stops
    // following its view, which shows as a render pinned to the old size.
    const layer = self.msgSend(objc.Object, "layer", .{});
    if (layer.value != null) {
        layer.msgSend(void, "setFrame:", .{CGRect{ .size = size }});
    }

    const delegate = delegateOf(target) orelse return;
    delegate.resized(
        delegate.context,
        @intFromFloat(@max(0, size.width)),
        @intFromFloat(@max(0, size.height)),
    );
}

/// A window dragged between a Retina and a non-Retina display. Without this the
/// drawable keeps the scale it was built with, and the render is either blurry
/// or oversized until something else resizes the editor.
fn viewDidChangeBackingProperties(target: c.id, sel: c.SEL) callconv(.c) void {
    _ = sel;

    objc.Object.fromId(target)
        .msgSendSuper(objc.getClass("NSView").?, void, "viewDidChangeBackingProperties", .{});

    const delegate = delegateOf(target) orelse return;
    delegate.display_changed(delegate.context);
}

/// The view may now be in a window on a different display, so the display link
/// has to be retargeted or it keeps pacing to the refresh rate of a monitor the
/// editor is no longer on.
fn viewDidMoveToWindow(target: c.id, sel: c.SEL) callconv(.c) void {
    _ = sel;

    objc.Object.fromId(target)
        .msgSendSuper(objc.getClass("NSView").?, void, "viewDidMoveToWindow", .{});

    const delegate = delegateOf(target) orelse return;
    delegate.display_changed(delegate.context);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// No test creates a view or registers the class. A test binary has no
// `NSApplication` and no host window, so an `NSView` built here would be
// exercising a different environment from the one this code runs in, and a
// green result would mean less than it appears to. The view is verified by
// opening the editor in REAPER and Logic.

test {
    // Forces the message sends and the three method implementations above to be
    // type-checked in the file that owns them rather than at the first call site
    // in `gui.zig`.
    testing.refAllDecls(@This());
    testing.refAllDecls(View);
}
