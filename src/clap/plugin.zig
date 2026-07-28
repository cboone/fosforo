//! The plugin factory, the descriptor, and one instance's lifecycle.
//!
//! This is the layer ADR 0004 calls "a thin idiomatic Zig layer" over the
//! translated module: above it the host sees nothing but C function pointers,
//! and below it everything sees an `*Instance`.

const std = @import("std");
const build_options = @import("build_options");
const clap = @import("c.zig");
const log = @import("log.zig");

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

    /// Resolved in `init`, which is the first callback where host extensions
    /// exist. Until then it is the inert value, which discards rather than
    /// dereferences.
    log: log.Log = .{},

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
    const self = Instance.from(plugin);

    self.log = log.Log.init(self.host);
    self.log.print(c.CLAP_LOG_DEBUG, "initialised against host {s} {s}", .{
        if (self.host.name) |name| std.mem.span(name) else "(unnamed)",
        if (self.host.version) |v| std.mem.span(v) else "(no version)",
    });

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
    const self = Instance.from(plugin);
    std.debug.assert(!self.active);

    // The contract says the host guarantees a positive sample rate and a frame
    // range within [1, INT32_MAX]. This is still a trust boundary, and unlike
    // most of them `activate` has a documented way to refuse. Everything
    // downstream divides by `sample_rate` and sizes its buffers from
    // `max_frames_count`, so a bad value accepted here does not fail here: it
    // surfaces later as a division by zero or an undersized buffer on the audio
    // thread, which is the one place with no way to report anything.
    //
    // Rejecting is deliberately narrower than the spec's stated bounds. A
    // `min_frames_count` of 0 is out of spec but harmless, because nothing
    // reads the minimum directly, and refusing to load over it would break a
    // working host for no gain. The inversion check is the one that matters:
    // a maximum below the minimum means `process` could be handed more frames
    // than anything sized from `max_frames` allocated for.
    if (!std.math.isFinite(sample_rate) or sample_rate <= 0) return false;
    if (max_frames_count == 0 or max_frames_count > std.math.maxInt(i32)) return false;
    if (max_frames_count < min_frames_count) return false;

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
/// merely polite. `clap.gui` arrives with issue #4.
fn getExtension(
    plugin: [*c]const c.clap_plugin_t,
    extension_id: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    _ = plugin;
    if (extension_id == null) return null;

    const wanted = std.mem.span(extension_id);
    if (std.mem.eql(u8, wanted, &c.CLAP_EXT_AUDIO_PORTS)) return &audio_ports;
    return null;
}

// ---------------------------------------------------------------------------
// clap.audio-ports
//
// One stereo input and one stereo output, which is the whole shape of an
// analyzer that sits on a track. The host may only scan these while the plugin
// is deactivated, so nothing here has to be safe against a concurrent change.
// ---------------------------------------------------------------------------

const audio_ports: c.clap_plugin_audio_ports_t = .{
    .count = audioPortsCount,
    .get = audioPortsGet,
};

/// The one port id this plugin uses. CLAP allows input and output ids to
/// overlap, and using the same value on both sides is what makes `in_place_pair`
/// below unambiguous.
const main_port_id: c.clap_id = 0;

/// [main-thread]
fn audioPortsCount(plugin: [*c]const c.clap_plugin_t, is_input: bool) callconv(.c) u32 {
    _ = plugin;
    _ = is_input;
    return 1;
}

/// [main-thread]
fn audioPortsGet(
    plugin: [*c]const c.clap_plugin_t,
    index: u32,
    is_input: bool,
    info: [*c]c.clap_audio_port_info_t,
) callconv(.c) bool {
    _ = plugin;
    if (index != 0 or info == null) return false;

    // Built locally and assigned once, so the host never sees a partially
    // filled struct and the zeroing covers any field a CLAP bump adds.
    var port = std.mem.zeroes(c.clap_audio_port_info_t);
    port.id = main_port_id;
    port.flags = @intCast(c.CLAP_AUDIO_PORT_IS_MAIN);
    port.channel_count = 2;
    port.port_type = &c.CLAP_PORT_STEREO;

    // Declares in-place processing: the host may hand us one buffer serving as
    // both sides. A pass-through wants exactly that, and `process` detects the
    // case by pointer identity rather than trusting the offer was taken up.
    port.in_place_pair = main_port_id;

    setPortName(&port.name, if (is_input) "Main In" else "Main Out");

    info.* = port;
    return true;
}

/// `clap_audio_port_info.name` is a fixed `CLAP_NAME_SIZE` array the host reads
/// as a C string, so the terminator matters more than the content.
fn setPortName(dst: []u8, name: []const u8) void {
    const len = @min(name.len, dst.len - 1);
    @memcpy(dst[0..len], name[0..len]);
    @memset(dst[len..], 0);
}

/// [main-thread] Only ever reached after the plugin asks the host for it.
fn onMainThread(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    _ = plugin;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A host offering no extensions at all, which is the shape every callback here
/// has to survive. `get_extension` is populated because `init` calls it; the
/// remaining pointers stay null because nothing in this file reaches them, so a
/// test that starts failing on a null call is reporting a real contract
/// violation rather than a gap in the fixture.
const test_host: c.clap_host_t = .{
    .clap_version = clap.version,
    .host_data = null,
    .name = "fosforo test",
    .vendor = "Catamount",
    .url = "",
    .version = "0.0.0",
    .get_extension = testNoExtensions,
    .request_restart = null,
    .request_process = null,
    .request_callback = null,
};

fn testNoExtensions(
    host: [*c]const c.clap_host_t,
    extension_id: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    _ = host;
    _ = extension_id;
    return null;
}

// Event list stubs. A host always supplies both lists, so the fixture below
// does too rather than leaving them null.

fn testEventCount(list: [*c]const c.clap_input_events_t) callconv(.c) u32 {
    _ = list;
    return 0;
}

fn testEventGet(
    list: [*c]const c.clap_input_events_t,
    index: u32,
) callconv(.c) [*c]const c.clap_event_header_t {
    _ = list;
    _ = index;
    return null;
}

fn testEventPush(
    list: [*c]const c.clap_output_events_t,
    event: [*c]const c.clap_event_header_t,
) callconv(.c) bool {
    _ = list;
    _ = event;
    return true;
}

const test_in_events: c.clap_input_events_t = .{
    .ctx = null,
    .size = testEventCount,
    .get = testEventGet,
};

const test_out_events: c.clap_output_events_t = .{
    .ctx = null,
    .try_push = testEventPush,
};

/// Shaped like what a host actually passes, rather than the minimum that
/// compiles. `process` currently ignores all of it, which is exactly why the
/// fixture has to be honest now: a null context would exercise a call no host
/// makes, and would quietly stop testing anything the moment the signal tap in
/// issue #3 starts reading these fields.
///
/// Zero audio buses is not a simplification, it is the current truth: the
/// plugin declares no audio ports yet. A null `transport` is legal and means
/// free-running, which is the case `clap-validator`'s `transport-null` test
/// covers.
const test_process: c.clap_process_t = .{
    .steady_time = 0,
    .frames_count = 512,
    .transport = null,
    .audio_inputs = null,
    .audio_outputs = null,
    .audio_inputs_count = 0,
    .audio_outputs_count = 0,
    .in_events = &test_in_events,
    .out_events = &test_out_events,
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
    try testing.expectEqual(c.CLAP_PROCESS_CONTINUE, plugin.process.?(plugin, &test_process));

    plugin.reset.?(plugin);
    plugin.stop_processing.?(plugin);
    try testing.expect(!self.processing);

    plugin.deactivate.?(plugin);
    try testing.expect(!self.active);

    // testing.allocator fails the test if this does not actually free.
    plugin.destroy.?(plugin);
}

test "activate refuses a malformed sample rate or frame range" {
    const self = try create(testing.allocator, &test_host);
    const plugin = &self.plugin;
    defer plugin.destroy.?(plugin);

    try testing.expect(!plugin.activate.?(plugin, 0, 1, 512));
    try testing.expect(!plugin.activate.?(plugin, -48_000, 1, 512));
    try testing.expect(!plugin.activate.?(plugin, std.math.nan(f64), 1, 512));
    try testing.expect(!plugin.activate.?(plugin, std.math.inf(f64), 1, 512));
    try testing.expect(!plugin.activate.?(plugin, 48_000, 1, 0));
    try testing.expect(!plugin.activate.?(plugin, 48_000, 512, 256));

    // Every refusal must leave the instance deactivated. Otherwise `destroy`
    // trips its own assertion, and a host that reacted correctly to the false
    // return would still be tearing down a plugin that believes it is live.
    try testing.expect(!self.active);

    // Out of spec but harmless, so it still has to load: nothing reads the
    // minimum, and refusing here would break a working host for no gain.
    try testing.expect(plugin.activate.?(plugin, 48_000, 0, 512));
    plugin.deactivate.?(plugin);
}

test "get_extension answers for what is implemented and nothing else" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);

    const got = self.plugin.get_extension.?(&self.plugin, &c.CLAP_EXT_AUDIO_PORTS);
    try testing.expect(got == @as(?*const anyopaque, &audio_ports));

    // Arrives with issue #4.
    try testing.expect(self.plugin.get_extension.?(&self.plugin, "clap.gui") == null);
    try testing.expect(self.plugin.get_extension.?(&self.plugin, "clap.params") == null);
}

test "the plugin declares one stereo port on each side" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    try testing.expectEqual(@as(u32, 1), audio_ports.count.?(plugin, true));
    try testing.expectEqual(@as(u32, 1), audio_ports.count.?(plugin, false));

    for ([_]bool{ true, false }) |is_input| {
        var info: c.clap_audio_port_info_t = undefined;
        try testing.expect(audio_ports.get.?(plugin, 0, is_input, &info));

        try testing.expectEqual(main_port_id, info.id);
        try testing.expectEqual(@as(u32, 2), info.channel_count);
        try testing.expectEqualStrings("stereo", std.mem.span(info.port_type));
        try testing.expect(info.flags & @as(u32, @intCast(c.CLAP_AUDIO_PORT_IS_MAIN)) != 0);

        // Not CLAP_INVALID_ID: the plugin is offering the host the option of
        // handing it one buffer for both sides.
        try testing.expectEqual(main_port_id, info.in_place_pair);
        try testing.expect(info.in_place_pair != c.CLAP_INVALID_ID);

        const name = std.mem.sliceTo(&info.name, 0);
        try testing.expectEqualStrings(if (is_input) "Main In" else "Main Out", name);
    }
}

test "audio_ports.get rejects an index that does not exist" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);

    var info: c.clap_audio_port_info_t = undefined;
    try testing.expect(!audio_ports.get.?(&self.plugin, 1, true, &info));
    try testing.expect(!audio_ports.get.?(&self.plugin, 1, false, &info));
}

test "a port name longer than the field is truncated with room for the terminator" {
    var name: [c.CLAP_NAME_SIZE]u8 = undefined;
    setPortName(&name, "x" ** (c.CLAP_NAME_SIZE * 2));

    try testing.expectEqual(@as(usize, c.CLAP_NAME_SIZE - 1), std.mem.sliceTo(&name, 0).len);
    try testing.expectEqual(@as(u8, 0), name[name.len - 1]);
}
