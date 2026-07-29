//! The editor's lifecycle, as CLAP's `clap.gui` extension drives it.
//!
//! Everything here runs on the host's main thread. The split against
//! `platform/view.zig` and `gpu/` is deliberate and load-bearing for the tests:
//! this file holds the decisions (which windowing API is acceptable, what size
//! the editor is, what order teardown happens in), and the two modules below it
//! hold the AppKit and Metal calls. That is what lets `zig build test` exercise
//! the state machine without an `NSApplication` or a GPU (ADR 0009).
//!
//! The vtable itself lives in `plugin.zig`, alongside the ones for
//! `clap.audio-ports` and `clap.state`, because it needs the `*Instance` that
//! this file deliberately knows nothing about.

const std = @import("std");
const clap = @import("c.zig");
const gpu = @import("../gpu/iface.zig");
const view_mod = @import("../platform/view.zig");

const c = clap.c;

/// The editor's fixed size, in logical points.
///
/// Cocoa is a logical-pixel API, so this is points rather than backing pixels
/// and the same number produces the same apparent size on a Retina display as
/// on anything else. 16:9 because a scope's horizontal axis is time and wants
/// the room; half of 1920x1080 because that sits on a laptop display without
/// taking it over.
///
/// Fixed until issue #5, which introduces resizing together with the mailbox
/// that makes it safe against a render thread.
pub const default_size: gpu.Size = .{ .width = 960, .height = 540 };

/// One instance's editor. Inert until the host calls `create`, and inert again
/// after `destroy`, which is what makes both safe to call more than once.
pub const Editor = struct {
    /// Whether the host has called `create` and not yet `destroy`. Tracked
    /// separately from `view`, because an editor is legitimately created and
    /// not yet parented, and the two states answer different questions.
    created: bool = false,
    visible: bool = false,

    view: ?view_mod.View = null,
    renderer: ?gpu.Renderer = null,

    /// [main-thread] The only place the host's windowing API is judged, shared
    /// by `is_api_supported` and `create` so the two cannot disagree.
    ///
    /// Floating windows are refused outright. The header records that embedding
    /// is supported by every host to date and is the case a plugin must
    /// support, and a floating window would need a second lifecycle with its
    /// own `set_transient` and `suggest_title` handling for no gain here.
    pub fn isApiSupported(api: [*c]const u8, is_floating: bool) bool {
        if (is_floating or api == null) return false;
        return std.mem.eql(u8, std.mem.span(api), &c.CLAP_WINDOW_API_COCOA);
    }

    /// [main-thread] Allocates nothing that needs a GPU.
    ///
    /// CLAP describes this as allocating the editor's resources, and it would
    /// be defensible to acquire the Metal device here for the sake of failing
    /// early. It is deferred to `set_parent` instead, where the view exists and
    /// its backing scale is knowable, which also keeps this callback reachable
    /// from a test binary with no GPU.
    pub fn create(self: *Editor, api: [*c]const u8, is_floating: bool) bool {
        if (!isApiSupported(api, is_floating)) return false;

        // A second `create` without a `destroy` is a host bug. Refusing is
        // better than quietly leaking the first editor's view and layer.
        if (self.created) return false;

        self.created = true;
        return true;
    }

    /// [main-thread] Release everything, in the reverse of the order it was
    /// built: the renderer first, because its layer is still attached to the
    /// view, and the view second.
    ///
    /// Safe when `create` failed, when `set_parent` never happened, and when
    /// called twice. A host is supposed to call this exactly once, but the cost
    /// of surviving one that does not is three null checks.
    pub fn destroy(self: *Editor) void {
        if (self.renderer) |*renderer| renderer.deinit();
        self.renderer = null;

        if (self.view) |v| v.destroy();
        self.view = null;

        self.visible = false;
        self.created = false;
    }

    /// [main-thread] Embed the editor in the host's window.
    ///
    /// Order matters twice over. The view is attached to the parent *before*
    /// its backing scale is read, because a view has no window until it is in
    /// one and the scale would otherwise be a guess. And the renderer is built
    /// last, because it is the only step that can fail for reasons outside this
    /// process.
    pub fn setParent(
        self: *Editor,
        window: *const c.clap_window_t,
        diags: *gpu.Diagnostics,
    ) !void {
        if (!self.created) return error.NotCreated;
        if (self.view != null) return error.AlreadyParented;

        // Every member of `clap_window`'s union is pointer-sized, so reading the
        // cocoa member of a window the host filled in as something else yields a
        // plausible-looking pointer that is not an `NSView`, and the first
        // message sent to it is the crash. Nothing about the earlier `create`
        // call constrains what arrives here, so this is a trust boundary and
        // gets the same treatment `activate` and `process` give theirs: refuse.
        //
        // Judged by the same predicate that gates `create`, so the two cannot
        // disagree about what this plugin can embed in. `is_floating` is false
        // because reaching `set_parent` at all means the host chose embedding.
        if (!isApiSupported(window.api, false)) return error.WrongWindowApi;

        // Reached through the accessor and never through the union field
        // directly: `unnamed_0` is a name translate-c generates and nothing
        // guarantees across Zig versions.
        const parent = clap.cocoaView(window) orelse return error.NoParentView;

        const v = view_mod.View.create(default_size.width, default_size.height) orelse
            return error.ViewCreationFailed;
        errdefer v.destroy();

        v.attach(parent);
        self.view = v;
        errdefer self.view = null;

        self.renderer = try gpu.Renderer.init(v.handle(), default_size, v.backingScale(), diags);

        // A host that reopens an editor may parent it while it is already
        // showing rather than calling `show` again, so the first frame is drawn
        // from whichever of the two arrives last.
        if (self.visible) self.drawOnce();
    }

    /// [main-thread] CLAP's `show` and `hide`. Hiding frees nothing: it is
    /// expected to be reversible, and the host may re-show the same editor.
    pub fn setHidden(self: *Editor, hidden: bool) bool {
        if (!self.created) return false;

        self.visible = !hidden;
        if (self.view) |v| v.setHidden(hidden);

        if (!hidden) self.drawOnce();
        return true;
    }

    /// Draw a single frame, if there is anything to draw it with.
    ///
    /// This is the whole render loop for now. Issue #5 replaces the call sites
    /// with a `CVDisplayLink` driving the same `frame()` at vsync; nothing
    /// below this function changes when it does.
    fn drawOnce(self: *Editor) void {
        if (self.renderer) |*renderer| renderer.frame();
    }

    /// [main-thread] Fixed until issue #5.
    pub fn size(self: *const Editor) gpu.Size {
        _ = self;
        return default_size;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Every test here stops short of `setParent`, which is the one method that
// reaches AppKit and Metal. That boundary is why this file exists separately
// from `platform/view.zig`: the decisions are testable on a machine with no
// window server, and the calls are verified by opening the editor in a host.

test "only embedded cocoa is accepted" {
    try testing.expect(Editor.isApiSupported(&c.CLAP_WINDOW_API_COCOA, false));

    // A floating cocoa window is refused as firmly as a foreign API.
    try testing.expect(!Editor.isApiSupported(&c.CLAP_WINDOW_API_COCOA, true));
    try testing.expect(!Editor.isApiSupported(&c.CLAP_WINDOW_API_WIN32, false));
    try testing.expect(!Editor.isApiSupported(&c.CLAP_WINDOW_API_X11, false));
    try testing.expect(!Editor.isApiSupported(null, false));
}

test "an editor is created, reports its size, and tears down" {
    var editor: Editor = .{};

    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    try testing.expect(editor.created);
    try testing.expectEqual(default_size, editor.size());

    editor.destroy();
    try testing.expect(!editor.created);
}

test "create refuses an API it cannot embed in, leaving the editor inert" {
    var editor: Editor = .{};

    try testing.expect(!editor.create(&c.CLAP_WINDOW_API_WIN32, false));
    try testing.expect(!editor.create(&c.CLAP_WINDOW_API_COCOA, true));
    try testing.expect(!editor.created);
}

test "a second create without a destroy is refused rather than leaking the first" {
    var editor: Editor = .{};
    defer editor.destroy();

    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    try testing.expect(!editor.create(&c.CLAP_WINDOW_API_COCOA, false));
}

test "destroy survives being called twice, and on an editor never created" {
    var never: Editor = .{};
    never.destroy();
    never.destroy();
    try testing.expect(!never.created);

    var created: Editor = .{};
    _ = created.create(&c.CLAP_WINDOW_API_COCOA, false);
    created.destroy();
    created.destroy();
    try testing.expect(!created.created);
}

test "show and hide track visibility and are refused before create" {
    var editor: Editor = .{};

    // Nothing to show yet. Returning false is more useful to a host than
    // silently succeeding on an editor that does not exist.
    try testing.expect(!editor.setHidden(false));

    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    defer editor.destroy();

    // No renderer, so `drawOnce` is a no-op. That it can be reached without
    // one is the property under test.
    try testing.expect(editor.setHidden(false));
    try testing.expect(editor.visible);

    try testing.expect(editor.setHidden(true));
    try testing.expect(!editor.visible);
}

/// A window the host would hand to `set_parent`, carrying no view.
///
/// Zeroed rather than built field by field, because naming the union member
/// would mean spelling `unnamed_0` here, and the whole point of
/// `clap.cocoaView` is that the generated name appears in exactly one place.
fn testWindow(api: [*c]const u8) c.clap_window_t {
    var window = std.mem.zeroes(c.clap_window_t);
    window.api = api;
    return window;
}

test "set_parent refuses an editor that was never created" {
    var editor: Editor = .{};
    var diags: gpu.Diagnostics = .{};

    // Refused before the window is read at all, which is what makes a fixture
    // carrying no view safe to hand over.
    const window = testWindow(&c.CLAP_WINDOW_API_COCOA);
    try testing.expectError(error.NotCreated, editor.setParent(&window, &diags));
}

test "set_parent refuses a window carrying no view" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));

    var diags: gpu.Diagnostics = .{};
    const window = testWindow(&c.CLAP_WINDOW_API_COCOA);

    try testing.expectError(error.NoParentView, editor.setParent(&window, &diags));
    try testing.expect(editor.view == null);
}

test "set_parent refuses a window whose api is not the one create accepted" {
    // Every member of the union is pointer-sized, so a window the host filled in
    // as x11 or win32 would hand over a plausible pointer that is not an
    // NSView. The api has to be judged before the union is read, not after.
    for ([_][*c]const u8{
        &c.CLAP_WINDOW_API_WIN32,
        &c.CLAP_WINDOW_API_X11,
        &c.CLAP_WINDOW_API_WAYLAND,
        &c.CLAP_WINDOW_API_UIKIT,
        null,
    }) |api| {
        var editor: Editor = .{};
        defer editor.destroy();
        try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));

        var diags: gpu.Diagnostics = .{};
        const window = testWindow(api);

        try testing.expectError(error.WrongWindowApi, editor.setParent(&window, &diags));
        try testing.expect(editor.view == null);
    }
}
