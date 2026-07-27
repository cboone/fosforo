//! Fósforo: a GPU-rendered phosphor oscilloscope, authored as a CLAP.
//!
//! This file holds only the boundary the host reaches through. Everything the
//! plugin actually does lives below it.
//!
//! Two artifacts are built from this source (see build.zig and ADR 0003):
//! a static library consumed by clap-wrapper, which supplies its own
//! `clap_entry`, and a dynamic library that exports `clap_entry` itself and is
//! packaged as the `.clap` bundle.

const std = @import("std");
const build_options = @import("build_options");
const clap = @import("clap/c.zig");

const c = clap.c;

/// Called once when the host loads the shared library, before anything else.
/// Nothing here may assume an audio thread exists yet.
export fn fosforo_clap_init(plugin_path: [*c]const u8) callconv(.c) bool {
    _ = plugin_path;
    return true;
}

/// Called once as the host unloads the library.
export fn fosforo_clap_deinit() callconv(.c) void {}

/// The host asks for a factory by string id. Returning null for an unknown id
/// is required rather than merely polite.
export fn fosforo_clap_get_factory(factory_id: [*c]const u8) callconv(.c) ?*const anyopaque {
    if (factory_id == null) return null;
    if (!std.mem.eql(u8, std.mem.span(factory_id), std.mem.span(@as([*:0]const u8, @ptrCast(&c.CLAP_PLUGIN_FACTORY_ID))))) {
        return null;
    }
    // The factory itself arrives with the walking skeleton (plan phase 1).
    return null;
}

/// The one symbol a CLAP host looks up by name.
///
/// Every host-facing callback crosses the C ABI and must carry the C calling
/// convention. Getting that wrong compiles cleanly and crashes at load time,
/// which is why the signatures are spelled out rather than inferred.
pub const entry: c.clap_plugin_entry_t = .{
    .clap_version = clap.version,
    .init = fosforo_clap_init,
    .deinit = fosforo_clap_deinit,
    .get_factory = fosforo_clap_get_factory,
};

comptime {
    if (build_options.export_entry) {
        @export(&entry, .{ .name = "clap_entry", .linkage = .strong });
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = clap;
}
