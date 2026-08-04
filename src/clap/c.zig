//! The translated CLAP C API, plus the pieces preprocessing consumes.
//!
//! This module is the single source of truth for anything crossing the ABI to
//! the host. See docs/adr/0004-clap-bindings-via-translate-c.md.

const std = @import("std");

pub const c = @import("clap_c");

/// Object-like macros do not survive preprocessing, so the few that matter are
/// restated here. `CLAP_VERSION` itself is a `static const` and does survive,
/// which lets the test below prove these agree with the vendored headers
/// instead of trusting that someone remembered to update them.
pub const version_major = 1;
pub const version_minor = 2;
pub const version_revision = 10;

pub const version: c.clap_version_t = .{
    .major = version_major,
    .minor = version_minor,
    .revision = version_revision,
};

/// The `clap_plugin_descriptor_t.features` vocabulary from `plugin-features.h`,
/// which is object-like macros end to end and so is consumed whole by
/// preprocessing. Only the entries this plugin actually claims are restated;
/// the rest can be added when something needs them.
///
/// Unlike the version macros above there is no surviving header symbol to check
/// these against, so the test below only pins the literals against a careless
/// local edit. That is the risk worth guarding: these strings are a published
/// vocabulary that hosts match on, so upstream is not going to redefine them,
/// but getting one wrong here miscategorises the plugin in every host at once
/// and is invisible until someone goes looking in a browser.
pub const feature = struct {
    pub const analyzer = "analyzer";
    pub const audio_effect = "audio-effect";
    pub const stereo = "stereo";
};

/// The anonymous union in `clap_window` is emitted with a toolchain-generated
/// name, currently `unnamed_0`. Nothing guarantees that name across Zig
/// versions, so it is reached through here and nowhere else.
pub fn cocoaView(window: *const c.clap_window_t) ?*anyopaque {
    return window.unnamed_0.cocoa;
}

/// The write side of `cocoaView`, for a caller playing the **host**.
///
/// The plugin only ever reads a window the host filled in, so nothing shipped
/// calls this: it exists for `src/smoke.zig`, which drives the editor from the
/// other side of the ABI. It lives here regardless, because the alternative is
/// that harness spelling `unnamed_0` itself and reintroducing exactly the
/// generated-name fragility the accessor above exists to contain.
pub fn setCocoaView(window: *c.clap_window_t, view: ?*anyopaque) void {
    window.unnamed_0.cocoa = view;
}

test "restated version macros match the vendored headers" {
    try std.testing.expectEqual(c.CLAP_VERSION.major, version_major);
    try std.testing.expectEqual(c.CLAP_VERSION.minor, version_minor);
    try std.testing.expectEqual(c.CLAP_VERSION.revision, version_revision);
}

// Deliberately not named after the header, unlike the version test above. That
// one reads `CLAP_VERSION` and genuinely proves agreement with the vendored
// headers. Preprocessing leaves nothing here to compare against, so this only
// restates the literals a second time and catches a one-sided edit.
test "restated feature strings are pinned against a careless edit" {
    try std.testing.expectEqualStrings("analyzer", feature.analyzer);
    try std.testing.expectEqualStrings("audio-effect", feature.audio_effect);
    try std.testing.expectEqualStrings("stereo", feature.stereo);
}

// The only coverage either window accessor has. Neither can be reached from a
// test through the plugin, because `Editor.setParent` refuses a window carrying
// no view before it ever reads the union, and a test has no `NSView` to put in
// one. Round-tripping the two against each other is what proves `unnamed_0` is
// still the generated name and `cocoa` still the member, which is the whole
// reason both functions exist.
test "the cocoa view round trips through the window accessors" {
    var sentinel: u8 = 0;
    const view: *anyopaque = @ptrCast(&sentinel);

    var window = std.mem.zeroes(c.clap_window_t);
    window.api = &c.CLAP_WINDOW_API_COCOA;

    try std.testing.expect(cocoaView(&window) == null);

    setCocoaView(&window, view);
    try std.testing.expect(cocoaView(&window) == view);

    // The union sits beside `api` rather than over it, so writing one must not
    // disturb the other. A host reading back a corrupted `api` would be a
    // failure this project causes rather than one it reports.
    try std.testing.expect(window.api == @as([*c]const u8, &c.CLAP_WINDOW_API_COCOA));

    setCocoaView(&window, null);
    try std.testing.expect(cocoaView(&window) == null);
}

// Layout of anything the host reads or writes must match the C headers exactly.
// A mismatch here is a crash inside someone else's DAW rather than a compile
// error, so it is asserted at comptime rather than left to review.
comptime {
    assertLayout(c.clap_plugin_entry_t, 4, .{ "clap_version", "init", "deinit", "get_factory" });
    assertLayout(c.clap_plugin_descriptor_t, 10, .{ "clap_version", "id", "name", "vendor", "features" });
    assertLayout(c.clap_window_t, 2, .{"api"});
    assertLayout(c.clap_plugin_factory_t, 3, .{ "get_plugin_count", "get_plugin_descriptor", "create_plugin" });
    assertLayout(c.clap_plugin_t, 12, .{ "desc", "plugin_data", "init", "destroy", "process", "get_extension" });
    assertLayout(c.clap_host_t, 10, .{ "clap_version", "host_data", "get_extension" });

    // The audio path. `clap_audio_buffer_t` and `clap_process_t` are the two
    // the host fills in and we read every callback, so a field that moved is a
    // wrong pointer dereferenced at audio rate rather than anything diagnosable.
    assertLayout(c.clap_plugin_audio_ports_t, 2, .{ "count", "get" });
    assertLayout(c.clap_audio_port_info_t, 6, .{ "id", "name", "flags", "channel_count", "port_type", "in_place_pair" });
    assertLayout(c.clap_audio_buffer_t, 5, .{ "data32", "data64", "channel_count", "constant_mask" });
    assertLayout(c.clap_process_t, 9, .{ "frames_count", "audio_inputs", "audio_outputs", "audio_inputs_count", "audio_outputs_count" });

    // State and logging.
    assertLayout(c.clap_plugin_state_t, 2, .{ "save", "load" });
    assertLayout(c.clap_istream_t, 2, .{ "ctx", "read" });
    assertLayout(c.clap_ostream_t, 2, .{ "ctx", "write" });
    assertLayout(c.clap_host_log_t, 1, .{"log"});

    // The GUI. `clap_plugin_gui_t` is the widest vtable this plugin fills in,
    // so it is also the one where a callback added or removed upstream is
    // easiest to miss: the count is what announces that.
    assertLayout(c.clap_plugin_gui_t, 15, .{
        "is_api_supported", "create", "destroy", "set_parent", "show", "hide",
    });
    assertLayout(c.clap_gui_resize_hints_t, 5, .{ "can_resize_horizontally", "can_resize_vertically" });
    assertLayout(c.clap_host_gui_t, 5, .{ "request_resize", "closed" });

    // `clap_version` must stay first. A host built against a future major
    // version may hand over a differently shaped struct, and reading the
    // version to discover that is only safe if its offset never moves.
    if (@offsetOf(c.clap_host_t, "clap_version") != 0) @compileError(
        "clap_host_t.clap_version must be the first field",
    );
}

/// Assert that a struct crossing the ABI still looks the way this build expects.
///
/// What it proves: the type is still `extern`, so it has a guaranteed C layout;
/// it still has exactly `want_fields` fields; and every name in `probe` is still
/// present.
///
/// What it does not prove: that the fields are in the same **order**, or at the
/// same **offsets**. A CLAP release that reordered two fields while keeping the
/// count and the names would pass this untouched. That is a deliberate limit
/// rather than an oversight: the upstream headers are the source of the
/// translated struct, so a reorder there reorders both sides together and stays
/// consistent. The case worth catching is a field appearing or disappearing
/// under a version bump, which changes the count, and `clap_host_t.clap_version`
/// specifically, which is checked with `@offsetOf` above because a
/// major-version-skewed host is exactly when the two sides can disagree.
fn assertLayout(comptime T: type, comptime want_fields: usize, comptime probe: anytype) void {
    const info = @typeInfo(T).@"struct";
    if (info.layout != .@"extern") @compileError(@typeName(T) ++ " must be extern");
    if (info.fields.len != want_fields) @compileError(
        @typeName(T) ++ " field count changed: the vendored CLAP headers moved under us",
    );
    for (probe) |name| {
        if (!@hasField(T, name)) @compileError(@typeName(T) ++ " lost field " ++ name);
    }
}
