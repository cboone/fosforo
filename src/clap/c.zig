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

    // `clap_version` must stay first. A host built against a future major
    // version may hand over a differently shaped struct, and reading the
    // version to discover that is only safe if its offset never moves.
    if (@offsetOf(c.clap_host_t, "clap_version") != 0) @compileError(
        "clap_host_t.clap_version must be the first field",
    );
}

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
