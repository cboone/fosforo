//! The plugin factory, the descriptor, and one instance's lifecycle.
//!
//! This is the layer ADR 0004 calls "a thin idiomatic Zig layer" over the
//! translated module: above it the host sees nothing but C function pointers,
//! and below it everything sees an `*Instance`.

const std = @import("std");
const build_options = @import("build_options");
const clap = @import("c.zig");

const c = clap.c;

/// **Permanent.** CLAP hosts persist this string into project files exactly as
/// AU hosts persist the `aufx`/`Fsfr`/`Ctmn` triple. Changing it after release
/// makes the plugin read as missing in every project that used it, orphaning
/// automation and settings, and CLAP offers no redirect mechanism.
///
/// Deliberately aligned with the Catamount vendor identity rather than with
/// `CFBundleIdentifier` (`com.cboone.fosforo`, in macos/Info.plist), which is a
/// signing and preferences identity and answers a different question. See the
/// identifiers section of the build plan.
pub const id = "com.catamount.fosforo";

/// Null-terminated, which `clap_plugin_descriptor_t.features` requires rather
/// than merely prefers: the host walks this array until it reads a null.
///
/// `analyzer` leads because hosts that key off a single primary category should
/// file this under analysis. `audio-effect` follows so hosts that only
/// understand the four processing categories still place it somewhere, which
/// also matches the `aufx` AU type in cmake/CMakeLists.txt.
const features = [_:null]?[*:0]const u8{
    clap.feature.analyzer,
    clap.feature.audio_effect,
    clap.feature.stereo,
};

/// Owned by the plugin and valid until `clap_plugin_entry.deinit`, so it is
/// static rather than built per instance.
pub const descriptor: c.clap_plugin_descriptor_t = .{
    .clap_version = clap.version,
    .id = id,
    .name = "Fósforo",
    .vendor = "Catamount",
    .url = "https://github.com/cboone/fosforo",
    .manual_url = "https://github.com/cboone/fosforo#readme",
    .support_url = "https://github.com/cboone/fosforo/issues",
    .version = build_options.version.ptr,
    .description = "A GPU-rendered phosphor oscilloscope.",
    .features = @ptrCast(&features),
};

pub const factory: c.clap_plugin_factory_t = .{
    .get_plugin_count = getPluginCount,
    .get_plugin_descriptor = getPluginDescriptor,
    .create_plugin = createPlugin,
};

/// One plugin instance. The host only ever holds `&instance.plugin`; everything
/// else is recovered from there through `plugin_data`.
const Instance = struct {
    plugin: c.clap_plugin_t,
    allocator: std.mem.Allocator,
    host: *const c.clap_host_t,

    /// The two axes CLAP writes its threading contracts against, as in
    /// `[audio-thread & active & !processing]`. Tracked so a debug build traps
    /// a host driving the lifecycle out of order at the point it happens,
    /// rather than leaving it to surface later as something unexplainable.
    active: bool = false,
    processing: bool = false,

    /// Constant between `activate` and `deactivate`, which is what lets the
    /// audio path size its buffers once and never allocate again (ADR 0010).
    sample_rate: f64 = 0,
    max_frames: u32 = 0,

    fn from(plugin: [*c]const c.clap_plugin_t) *Instance {
        return @ptrCast(@alignCast(plugin.*.plugin_data.?));
    }
};

/// Split out from `createPlugin` so tests can supply a checked allocator and
/// catch a leak that the C entry point would otherwise hide.
fn create(allocator: std.mem.Allocator, host: *const c.clap_host_t) !*Instance {
    const self = try allocator.create(Instance);
    self.* = .{
        .plugin = .{
            .desc = &descriptor,
            .plugin_data = self,
            .init = init,
            .destroy = destroy,
            .activate = activate,
            .deactivate = deactivate,
            .start_processing = startProcessing,
            .stop_processing = stopProcessing,
            .reset = reset,
            .process = process,
            .get_extension = getExtension,
            .on_main_thread = onMainThread,
        },
        .allocator = allocator,
        .host = host,
    };
    return self;
}

// ---------------------------------------------------------------------------
// Factory. Every method must be thread-safe, and hosts call them while scanning
// the plugin directory, so nothing here may be expensive.
// ---------------------------------------------------------------------------

fn getPluginCount(factory_ptr: [*c]const c.clap_plugin_factory_t) callconv(.c) u32 {
    _ = factory_ptr;
    return 1;
}

fn getPluginDescriptor(
    factory_ptr: [*c]const c.clap_plugin_factory_t,
    index: u32,
) callconv(.c) [*c]const c.clap_plugin_descriptor_t {
    _ = factory_ptr;
    return if (index == 0) &descriptor else null;
}

/// Forbidden from calling back into the host, so this does nothing but validate
/// and allocate. Real setup belongs in `init`, where host extensions exist.
fn createPlugin(
    factory_ptr: [*c]const c.clap_plugin_factory_t,
    host: [*c]const c.clap_host_t,
    plugin_id: [*c]const u8,
) callconv(.c) [*c]const c.clap_plugin_t {
    _ = factory_ptr;
    if (host == null or plugin_id == null) return null;

    // Precedes every other field access: a host from a future major version may
    // hand over a differently shaped struct, and `clap_version` is the only
    // field whose offset is guaranteed under that skew.
    if (!c.clap_version_is_compatible(host.*.clap_version)) return null;

    if (!std.mem.eql(u8, std.mem.span(plugin_id), id)) return null;

    const self = create(std.heap.c_allocator, host) catch return null;
    return &self.plugin;
}

// ---------------------------------------------------------------------------
// Instance lifecycle.
// ---------------------------------------------------------------------------

/// [main-thread] Host extensions are reachable from here, unlike in
/// `create_plugin`, so anything needing them belongs here.
fn init(plugin: [*c]const c.clap_plugin_t) callconv(.c) bool {
    _ = plugin;
    return true;
}

/// [main-thread & !active]
fn destroy(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.from(plugin);
    std.debug.assert(!self.active);
    self.allocator.destroy(self);
}

/// [main-thread & !active] The one place the plugin is allowed to allocate for
/// the audio path, because `sample_rate` and `max_frames_count` are fixed from
/// here until `deactivate`.
fn activate(
    plugin: [*c]const c.clap_plugin_t,
    sample_rate: f64,
    min_frames_count: u32,
    max_frames_count: u32,
) callconv(.c) bool {
    _ = min_frames_count;
    const self = Instance.from(plugin);
    std.debug.assert(!self.active);

    self.sample_rate = sample_rate;
    self.max_frames = max_frames_count;
    self.active = true;
    return true;
}

/// [main-thread & active]
fn deactivate(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.from(plugin);
    std.debug.assert(self.active and !self.processing);
    self.active = false;
}

/// [audio-thread & active & !processing]
fn startProcessing(plugin: [*c]const c.clap_plugin_t) callconv(.c) bool {
    const self = Instance.from(plugin);
    std.debug.assert(self.active and !self.processing);
    self.processing = true;
    return true;
}

/// [audio-thread & active & processing]
fn stopProcessing(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.from(plugin);
    std.debug.assert(self.active and self.processing);
    self.processing = false;
}

/// [audio-thread & active] Note that `clap_process.steady_time` may jump
/// backward across this, so anything derived from it has to be rebuilt rather
/// than advanced.
fn reset(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.from(plugin);
    std.debug.assert(self.active);
}

/// [audio-thread & active & processing] Nothing reachable from here may
/// allocate, take a lock, or make a syscall (ADR 0010).
///
/// The plugin declares no audio ports yet, so the host has nothing to hand us
/// and there is nothing to copy. Reporting `CONTINUE` rather than `SLEEP` keeps
/// the host calling us once the ports and the signal tap arrive.
fn process(
    plugin: [*c]const c.clap_plugin_t,
    process_ctx: [*c]const c.clap_process_t,
) callconv(.c) c.clap_process_status {
    _ = process_ctx;
    const self = Instance.from(plugin);
    std.debug.assert(self.active and self.processing);
    return c.CLAP_PROCESS_CONTINUE;
}

/// [thread-safe] Returning null for an unrecognised id is required rather than
/// merely polite. Every extension this plugin will support is still unwritten,
/// so for now that is all of them.
fn getExtension(
    plugin: [*c]const c.clap_plugin_t,
    extension_id: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    _ = plugin;
    _ = extension_id;
    return null;
}

/// [main-thread] Only ever reached after the plugin asks the host for it.
fn onMainThread(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    _ = plugin;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// `create_plugin` is forbidden from calling host callbacks and nothing below
/// it calls them yet, so leaving the function pointers null is not a shortcut:
/// a test that starts failing here is reporting a real contract violation.
const test_host: c.clap_host_t = .{
    .clap_version = clap.version,
    .host_data = null,
    .name = "fosforo test",
    .vendor = "Catamount",
    .url = "",
    .version = "0.0.0",
    .get_extension = null,
    .request_restart = null,
    .request_process = null,
    .request_callback = null,
};

test "the factory exposes exactly one plugin" {
    try testing.expectEqual(@as(u32, 1), factory.get_plugin_count.?(&factory));
    try testing.expect(factory.get_plugin_descriptor.?(&factory, 0) == &descriptor);
    try testing.expect(factory.get_plugin_descriptor.?(&factory, 1) == null);
}

test "the descriptor fills every mandatory field" {
    try testing.expectEqualStrings(id, std.mem.span(descriptor.id));
    try testing.expectEqualStrings("Fósforo", std.mem.span(descriptor.name));
    try testing.expectEqualStrings("Catamount", std.mem.span(descriptor.vendor));
    try testing.expectEqual(clap.version, descriptor.clap_version);
    try testing.expect(std.mem.span(descriptor.version).len > 0);
}

test "the feature list is null terminated and leads with analyzer" {
    var count: usize = 0;
    while (descriptor.features[count] != null) : (count += 1) {}
    try testing.expectEqual(features.len, count);
    try testing.expectEqualStrings(clap.feature.analyzer, std.mem.span(descriptor.features[0]));
}

test "create_plugin rejects an id that is not ours" {
    try testing.expect(factory.create_plugin.?(&factory, &test_host, "com.example.other") == null);
}

test "create_plugin rejects a host from an incompatible CLAP major version" {
    var stale = test_host;
    stale.clap_version = .{ .major = 0, .minor = 9, .revision = 0 };
    try testing.expect(factory.create_plugin.?(&factory, &stale, id) == null);
}

test "an instance runs the whole lifecycle and frees itself" {
    const self = try create(testing.allocator, &test_host);
    const plugin = &self.plugin;

    try testing.expect(plugin.desc == &descriptor);
    try testing.expect(plugin.init.?(plugin));

    try testing.expect(plugin.activate.?(plugin, 48_000, 1, 512));
    try testing.expect(self.active);
    try testing.expectEqual(@as(f64, 48_000), self.sample_rate);
    try testing.expectEqual(@as(u32, 512), self.max_frames);

    try testing.expect(plugin.start_processing.?(plugin));
    try testing.expect(self.processing);
    try testing.expectEqual(c.CLAP_PROCESS_CONTINUE, plugin.process.?(plugin, null));

    plugin.reset.?(plugin);
    plugin.stop_processing.?(plugin);
    try testing.expect(!self.processing);

    plugin.deactivate.?(plugin);
    try testing.expect(!self.active);

    // testing.allocator fails the test if this does not actually free.
    plugin.destroy.?(plugin);
}

test "get_extension returns null until the extensions are written" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);

    try testing.expect(self.plugin.get_extension.?(&self.plugin, "clap.gui") == null);
    try testing.expect(self.plugin.get_extension.?(&self.plugin, "clap.audio-ports") == null);
}
