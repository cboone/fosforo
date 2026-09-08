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
const plugin = @import("clap/plugin.zig");

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
    // The id survives preprocessing as a `static const` array rather than a
    // macro, so it compares directly against the vendored header's own value.
    if (!std.mem.eql(u8, std.mem.span(factory_id), &c.CLAP_PLUGIN_FACTORY_ID)) return null;
    return &plugin.factory;
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
    _ = plugin;

    // Reached only through `plugin`, so named here to get their tests collected.
    _ = @import("build_info.zig");
    _ = @import("clap/gui.zig");
    _ = @import("clap/log.zig");
    _ = @import("clap/state.zig");
    _ = @import("dsp/ring.zig");
    _ = @import("gpu/iface.zig");
    _ = @import("gpu/metal/renderer.zig");
    _ = @import("gpu/metal/shader.zig");
    _ = @import("platform/displaylink.zig");
    _ = @import("platform/io.zig");
    _ = @import("platform/objc.zig");
    _ = @import("platform/view.zig");

    // Reached only from the `test` blocks of the five files it guards, so no
    // import chain from `plugin` runs through it and its own tests would
    // otherwise not be collected. It is what those five canaries rest on, which
    // makes a bug in it five checks silently passing.
    _ = @import("canary.zig");

    // Not reached from the plugin at all: it reads a rendered trace back as
    // numbers, and its one caller is `src/smoke.zig`. Named here for the reason
    // the race harness below is, and for one of its own: the analysis it holds is
    // where #38's period counter went wrong, and an analysis checked only by the
    // build step that needs a GPU is an analysis this project's usual test run
    // would never see.
    _ = @import("gpu/measure.zig");

    // The other half of that same argument, and it was left unmade for four
    // issues. `measure.zig` holds the extraction and this holds the
    // *expectations*, which is where the tolerances, the loops and the guards
    // against going vacuous live. Its one caller is `src/smoke.zig` too, so
    // without this line the thirteen hardest claims this project makes about
    // what the pixels became would again be checked only by the build step that
    // needs a GPU.
    _ = @import("gpu/verdict.zig");

    // Not reached from the plugin at all: it is the root of the race harness,
    // which `zig build ring-race` builds as its own executable. Named here so its
    // pure parts are still checked by `zig build test`, because the machine that
    // runs that command is usually the one machine that cannot run the harness.
    _ = @import("ring_race.zig");
}

test "every module a test build compiles carries a declaration sweep" {
    const canary = @import("canary.zig");

    // Zig analyses lazily per declaration, so a `pub fn` nothing reaches is never
    // type-checked however the file it lives in was imported (#95). Every module
    // below answers that with a `refAllDecls` block. Nothing but this makes the
    // convention hold for the module added next month: the sweep itself is a
    // one-time edit, and the hole it closed reopens silently without a check.
    //
    // Every `.zig` file under `src/` except `smoke.zig`, which `zig build test`
    // compiles none of; #92 owns that one.
    const sources = .{
        .{ "main.zig", @embedFile("main.zig") },
        .{ "build_info.zig", @embedFile("build_info.zig") },
        .{ "canary.zig", @embedFile("canary.zig") },
        .{ "ring_race.zig", @embedFile("ring_race.zig") },
        .{ "clap/c.zig", @embedFile("clap/c.zig") },
        .{ "clap/gui.zig", @embedFile("clap/gui.zig") },
        .{ "clap/log.zig", @embedFile("clap/log.zig") },
        .{ "clap/plugin.zig", @embedFile("clap/plugin.zig") },
        .{ "clap/state.zig", @embedFile("clap/state.zig") },
        .{ "dsp/ring.zig", @embedFile("dsp/ring.zig") },
        .{ "gpu/iface.zig", @embedFile("gpu/iface.zig") },
        .{ "gpu/measure.zig", @embedFile("gpu/measure.zig") },
        .{ "gpu/palette.zig", @embedFile("gpu/palette.zig") },
        .{ "gpu/verdict.zig", @embedFile("gpu/verdict.zig") },
        .{ "gpu/metal/renderer.zig", @embedFile("gpu/metal/renderer.zig") },
        .{ "gpu/metal/shader.zig", @embedFile("gpu/metal/shader.zig") },
        .{ "platform/displaylink.zig", @embedFile("platform/displaylink.zig") },
        .{ "platform/io.zig", @embedFile("platform/io.zig") },
        .{ "platform/objc.zig", @embedFile("platform/objc.zig") },
        .{ "platform/view.zig", @embedFile("platform/view.zig") },
    };

    // Split so this line is not itself a match. The needle would otherwise appear
    // verbatim in this file's own source and count as a second statement, which is
    // the hazard `canary.implementation` exists for and which cannot help here:
    // this file has no tests banner to cut at.
    //
    // `canary.mentions` rather than `indexOf` for the reason it exists: it does not
    // count comment lines, so a file that documented the convention instead of
    // following it fails. `src/smoke.zig` names `testing.refAllDecls` in its
    // docstring and follows nothing, which is what that would look like.
    const sweep = "refAllDecls(" ++ "@This());";
    inline for (sources) |module| {
        errdefer std.debug.print("\nsrc/{s} carries no declaration sweep\n", .{module[0]});
        try std.testing.expectEqual(1, canary.mentions(module[1], sweep));
    }

    // The two lists tied together, so adding one without the other fails here
    // rather than quietly narrowing what the sweep covers. `sources` holds four
    // entries the block above does not name: this file, the two it imports at file
    // scope, and `gpu/palette.zig`, whose tests are collected only because
    // `Renderer`'s method bodies reference it. Split for the same reason as above.
    const listed = canary.mentions(@embedFile("main.zig"), "_ = @imp" ++ "ort(\"");
    try std.testing.expectEqual(sources.len, listed + 4);
}

test "the entry hands back the plugin factory, and only for its own id" {
    const got = fosforo_clap_get_factory(&c.CLAP_PLUGIN_FACTORY_ID);
    try std.testing.expect(got == @as(?*const anyopaque, &plugin.factory));

    try std.testing.expect(fosforo_clap_get_factory("clap.preset-discovery-factory") == null);
    try std.testing.expect(fosforo_clap_get_factory(null) == null);
}
