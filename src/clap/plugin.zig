//! The plugin factory, the descriptor, and one instance's lifecycle.
//!
//! This is the layer ADR 0004 calls "a thin idiomatic Zig layer" over the
//! translated module: above it the host sees nothing but C function pointers,
//! and below it everything sees an `*Instance`.

const std = @import("std");
const build_options = @import("build_options");
const clap = @import("c.zig");
const gpu = @import("../gpu/iface.zig");
const gui = @import("gui.zig");
const log = @import("log.zig");
const state = @import("state.zig");

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

    /// The host's side of `clap.gui`, resolved in `init` for the same reason
    /// `log` is: host extensions do not exist before it. The editor reaches it
    /// by pointer, which is safe because an `Instance` is heap-allocated and
    /// outlives the editor inside it.
    host_gui: gui.HostGui = .{},

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

    /// Everything the audio path is allowed to allocate from, obtained once in
    /// `activate`. `process` wraps this in a fixed-buffer allocator, so the
    /// heap is not merely unused down there, it is unreachable.
    scratch: []u8 = &.{},

    /// The editor, inert until the host asks for one. Lives here rather than
    /// behind a pointer because it is small and its lifetime is exactly the
    /// instance's, which also means a host that forgets `gui.destroy` still
    /// cannot leak it past `destroy`.
    editor: gui.Editor = .{},

    fn from(plugin: [*c]const c.clap_plugin_t) *Instance {
        return @ptrCast(@alignCast(plugin.*.plugin_data.?));
    }
};

/// The editor behind a plugin the host is holding.
///
/// `Instance` stays private, because everything a host needs is reachable
/// through the vtable and a second way in would be a second thing to keep
/// correct. This is the one exception, and it exists for `src/smoke.zig`: CLAP
/// has no callback that reports whether a frame was drawn, by design, so the
/// only way to assert the render loop is doing anything is to read the counter
/// the editor keeps. See ADR 0013.
pub fn editorOf(plugin: [*c]const c.clap_plugin_t) *const gui.Editor {
    return &Instance.from(plugin).editor;
}

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

    // The editor's render loop reports through the same channel. `&self.log` is
    // stable because an `Instance` is heap-allocated and outlives the editor
    // inside it, which is the same reason the view may hold `&self.editor`.
    self.editor.log = &self.log;

    // The editor enforces a minimum size, and `request_resize` is the only way
    // to make a host honour one: CLAP has no field anywhere that carries a
    // smallest editor, and REAPER shrinks its window past `adjust_size`'s
    // answer regardless.
    self.host_gui = gui.HostGui.init(self.host);
    self.editor.host_gui = &self.host_gui;

    self.log.print(c.CLAP_LOG_DEBUG, "initialised against host {s} {s}", .{
        if (self.host.name) |name| std.mem.span(name) else "(unnamed)",
        if (self.host.version) |v| std.mem.span(v) else "(no version)",
    });

    return true;
}

/// [main-thread & !active]
///
/// Tears the editor down rather than assuming the host already did. A host is
/// supposed to call `gui.destroy` first, and one that does not should still not
/// leave an `NSView` and a Metal device behind. `Editor.destroy` is idempotent,
/// so the well-behaved case costs three null checks.
fn destroy(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.from(plugin);
    std.debug.assert(!self.active);
    self.editor.destroy();
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

    self.scratch = self.allocator.alloc(u8, scratchBytes(max_frames_count)) catch {
        self.log.message(c.CLAP_LOG_ERROR, "activate failed: could not size the audio scratch buffer");
        return false;
    };

    self.sample_rate = sample_rate;
    self.max_frames = max_frames_count;
    self.active = true;

    self.log.print(c.CLAP_LOG_DEBUG, "activated at {d} Hz, up to {d} frames", .{
        sample_rate,
        max_frames_count,
    });
    return true;
}

/// Bytes the audio path may allocate from during one `process` call.
///
/// Currently zero, and that is the point rather than a placeholder: a
/// pass-through allocates nothing, so a zero-length fixed buffer turns any
/// allocation into `error.OutOfMemory` at the call site instead of a heap call
/// on the audio thread. Phase 2 sizes this from `max_frames` when the history
/// buffer lands, and nothing else has to change.
fn scratchBytes(max_frames: u32) usize {
    _ = max_frames;
    return 0;
}

/// [main-thread & active] The mirror of `activate`, and the only other place
/// the audio path's memory may move.
fn deactivate(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.from(plugin);
    std.debug.assert(self.active and !self.processing);

    self.allocator.free(self.scratch);
    self.scratch = &.{};

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
/// Reports `CONTINUE` rather than `SLEEP` because an analyzer wants to keep
/// being called: going quiet is exactly when a scope still has a trace to decay.
fn process(
    plugin: [*c]const c.clap_plugin_t,
    process_ctx: [*c]const c.clap_process_t,
) callconv(.c) c.clap_process_status {
    const self = Instance.from(plugin);
    std.debug.assert(self.active and self.processing);

    if (process_ctx == null) return c.CLAP_PROCESS_ERROR;
    const ctx = process_ctx.*;

    // `max_frames_count` from `activate` is a host contract, and this is a trust
    // boundary treated the same way `activate` treats its own: refuse rather
    // than assert. An assertion is compiled out of a release build, which is
    // precisely the build where a misbehaving host does damage.
    //
    // Nothing here is sized from `max_frames` yet, so today this only refuses
    // work it could technically have done. Phase 2 sizes the history buffer
    // from it, at which point trusting the value is a write past the end of it.
    if (ctx.frames_count > self.max_frames) return c.CLAP_PROCESS_ERROR;

    var fba = std.heap.FixedBufferAllocator.init(self.scratch);
    passThrough(fba.allocator(), ctx);

    // The structural guarantee ADR 0010 asks for, stated as an assertion rather
    // than left as a comment nobody can check.
    std.debug.assert(fba.end_index == 0);

    return c.CLAP_PROCESS_CONTINUE;
}

/// Copy the main input to the main output.
///
/// Takes an allocator it does not use, which is deliberate: ADR 0010 wants "the
/// audio path cannot touch the heap" to be a fact about the call graph, and the
/// way to make that true is for the path to have taken its allocator as a
/// parameter from the beginning rather than acquiring one later.
fn passThrough(allocator: std.mem.Allocator, ctx: c.clap_process_t) void {
    _ = allocator;

    if (ctx.audio_outputs == null or ctx.audio_outputs_count == 0) return;
    const out = &ctx.audio_outputs[0];

    const frames = ctx.frames_count;
    if (out.data32 == null or frames == 0) return;

    const in: ?*const c.clap_audio_buffer_t = if (ctx.audio_inputs != null and
        ctx.audio_inputs_count > 0 and
        ctx.audio_inputs[0].data32 != null) &ctx.audio_inputs[0] else null;

    // Only 32-bit support is declared, so `data64` is never the populated
    // pointer. A null `data32` means the input is unusable, not that we should
    // go looking at `data64`.
    const copied = if (in) |src| @min(src.channel_count, out.channel_count) else 0;

    var mask: u64 = 0;
    var channel: u32 = 0;

    while (channel < copied) : (channel += 1) {
        const from = in.?.data32[channel];
        const to = out.data32[channel];

        // The host took up the `in_place_pair` offer, so the copy is a no-op
        // over memory that already holds the answer.
        if (from != to) @memcpy(to[0..frames], from[0..frames]);

        if (in.?.constant_mask & bit(channel) != 0) mask |= bit(channel);
    }

    // Anything the input does not reach is silenced rather than left holding
    // whatever the host's buffer happened to contain. Leaving it untouched is
    // how uninitialised memory reaches a speaker.
    while (channel < out.channel_count) : (channel += 1) {
        @memset(out.data32[channel][0..frames], 0);
        mask |= bit(channel);
    }

    out.constant_mask = mask;
}

/// `constant_mask` is a per-channel bitfield, and channel counts above 64 have
/// no bit to occupy.
fn bit(channel: u32) u64 {
    return if (channel < 64) @as(u64, 1) << @intCast(channel) else 0;
}

/// [thread-safe] Returning null for an unrecognised id is required rather than
/// merely polite.
fn getExtension(
    plugin: [*c]const c.clap_plugin_t,
    extension_id: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    _ = plugin;
    if (extension_id == null) return null;

    const wanted = std.mem.span(extension_id);
    if (std.mem.eql(u8, wanted, &c.CLAP_EXT_AUDIO_PORTS)) return &audio_ports;
    if (std.mem.eql(u8, wanted, &c.CLAP_EXT_STATE)) return &plugin_state;
    if (std.mem.eql(u8, wanted, &c.CLAP_EXT_GUI)) return &plugin_gui;
    return null;
}

// ---------------------------------------------------------------------------
// clap.state
//
// Two callbacks over src/clap/state.zig, which owns the format. Both run on the
// main thread, so neither is subject to ADR 0010.
// ---------------------------------------------------------------------------

const plugin_state: c.clap_plugin_state_t = .{
    .save = stateSave,
    .load = stateLoad,
};

/// [main-thread]
fn stateSave(
    plugin: [*c]const c.clap_plugin_t,
    stream: [*c]const c.clap_ostream_t,
) callconv(.c) bool {
    const self = Instance.from(plugin);
    if (stream == null) return false;

    if (!state.save(stream)) {
        self.log.message(c.CLAP_LOG_ERROR, "state save failed: the host's stream rejected the write");
        return false;
    }
    return true;
}

/// [main-thread] A failed load leaves the instance as it was. There is nothing
/// to restore yet, so that is trivially true here, and it is the behaviour to
/// preserve once there is: a half-applied state is worse than a refused one.
fn stateLoad(
    plugin: [*c]const c.clap_plugin_t,
    stream: [*c]const c.clap_istream_t,
) callconv(.c) bool {
    const self = Instance.from(plugin);
    if (stream == null) return false;

    state.load(stream) catch |err| {
        self.log.print(c.CLAP_LOG_WARNING, "state load failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// clap.gui
//
// Fifteen callbacks over the `Editor` in src/clap/gui.zig, which owns the
// decisions and knows nothing about `Instance`. Every one is filled in rather
// than left null: a host is entitled to call any of them without checking, and
// a null function pointer is a crash rather than a refusal.
//
// All are [main-thread]. The ones the header marks `[main-thread & floating]`
// are answered rather than omitted, because refusing floating mode in
// `is_api_supported` does not stop a host from asking anyway.
// ---------------------------------------------------------------------------

const plugin_gui: c.clap_plugin_gui_t = .{
    .is_api_supported = guiIsApiSupported,
    .get_preferred_api = guiGetPreferredApi,
    .create = guiCreate,
    .destroy = guiDestroy,
    .set_scale = guiSetScale,
    .get_size = guiGetSize,
    .can_resize = guiCanResize,
    .get_resize_hints = guiGetResizeHints,
    .adjust_size = guiAdjustSize,
    .set_size = guiSetSize,
    .set_parent = guiSetParent,
    .set_transient = guiSetTransient,
    .suggest_title = guiSuggestTitle,
    .show = guiShow,
    .hide = guiHide,
};

fn guiIsApiSupported(
    plugin: [*c]const c.clap_plugin_t,
    api: [*c]const u8,
    is_floating: bool,
) callconv(.c) bool {
    _ = plugin;
    return gui.Editor.isApiSupported(api, is_floating);
}

/// The header is explicit that `api` must be assigned one of its own constants
/// rather than a copy, since the host compares by pointer as well as by value.
fn guiGetPreferredApi(
    plugin: [*c]const c.clap_plugin_t,
    api: [*c][*c]const u8,
    is_floating: [*c]bool,
) callconv(.c) bool {
    _ = plugin;
    if (api == null or is_floating == null) return false;

    api.* = &c.CLAP_WINDOW_API_COCOA;
    is_floating.* = false;
    return true;
}

fn guiCreate(
    plugin: [*c]const c.clap_plugin_t,
    api: [*c]const u8,
    is_floating: bool,
) callconv(.c) bool {
    const self = Instance.from(plugin);
    return self.editor.create(api, is_floating);
}

fn guiDestroy(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    Instance.from(plugin).editor.destroy();
}

/// Refused, and that is the documented answer rather than a gap. The header
/// says the cocoa API uses logical pixels and that `set_scale` should not be
/// called for it; false means "the call was ignored", which is exactly true.
/// The real scale comes from the view's window at `set_parent` time.
fn guiSetScale(plugin: [*c]const c.clap_plugin_t, scale: f64) callconv(.c) bool {
    _ = plugin;
    _ = scale;
    return false;
}

fn guiGetSize(
    plugin: [*c]const c.clap_plugin_t,
    width: [*c]u32,
    height: [*c]u32,
) callconv(.c) bool {
    const self = Instance.from(plugin);
    if (width == null or height == null) return false;

    const size = self.editor.size();
    width.* = size.width;
    height.* = size.height;
    return true;
}

fn guiCanResize(plugin: [*c]const c.clap_plugin_t) callconv(.c) bool {
    _ = plugin;
    return true;
}

/// Both axes, freely. The 16:9 default is a starting size and not a constraint:
/// the argument for it is that a scope's time axis wants room, which is exactly
/// what locking the ratio would stop someone buying more of.
///
/// There is no minimum in this struct to report. CLAP puts that in
/// `adjust_size`, which is where `Editor.adjustSize` answers it.
fn guiGetResizeHints(
    plugin: [*c]const c.clap_plugin_t,
    hints: [*c]c.clap_gui_resize_hints_t,
) callconv(.c) bool {
    _ = plugin;
    if (hints == null) return false;

    // Built locally and assigned once, so the host never sees a partially
    // filled struct and the zeroing covers any field a CLAP bump adds.
    var filled = std.mem.zeroes(c.clap_gui_resize_hints_t);
    filled.can_resize_horizontally = true;
    filled.can_resize_vertically = true;
    filled.preserve_aspect_ratio = false;

    hints.* = filled;
    return true;
}

/// The closest size the editor would actually adopt, which is the honest answer
/// to what the host asked. Each axis is clamped on its own, so a tall narrow
/// request comes back tall and narrow.
fn guiAdjustSize(
    plugin: [*c]const c.clap_plugin_t,
    width: [*c]u32,
    height: [*c]u32,
) callconv(.c) bool {
    const self = Instance.from(plugin);
    if (width == null or height == null) return false;

    const adjusted = self.editor.adjustSize(width.*, height.*);
    width.* = adjusted.width;
    height.* = adjusted.height;
    return true;
}

fn guiSetSize(
    plugin: [*c]const c.clap_plugin_t,
    width: u32,
    height: u32,
) callconv(.c) bool {
    return Instance.from(plugin).editor.setSize(width, height);
}

/// The one callback that can fail for reasons outside this process, and so the
/// one that logs. A Metal compiler error names a file, a line, and the mistake;
/// without this line a developer sees an editor that did not open and nothing
/// else.
fn guiSetParent(
    plugin: [*c]const c.clap_plugin_t,
    window: [*c]const c.clap_window_t,
) callconv(.c) bool {
    const self = Instance.from(plugin);
    if (window == null) return false;

    var diags: gpu.Diagnostics = .{};
    self.editor.setParent(window, &diags) catch |err| {
        self.log.print(c.CLAP_LOG_ERROR, "gui set_parent failed: {s}: {s}", .{
            @errorName(err),
            diags.message(),
        });
        return false;
    };

    self.log.message(c.CLAP_LOG_DEBUG, "editor embedded in the host window");
    return true;
}

/// Floating windows are refused in `is_api_supported`, so neither of these
/// should ever be reached. They are implemented rather than left null because
/// "should never" is a statement about well-behaved hosts.
fn guiSetTransient(
    plugin: [*c]const c.clap_plugin_t,
    window: [*c]const c.clap_window_t,
) callconv(.c) bool {
    _ = plugin;
    _ = window;
    return false;
}

fn guiSuggestTitle(plugin: [*c]const c.clap_plugin_t, title: [*c]const u8) callconv(.c) void {
    _ = plugin;
    _ = title;
}

fn guiShow(plugin: [*c]const c.clap_plugin_t) callconv(.c) bool {
    return Instance.from(plugin).editor.setHidden(false);
}

fn guiHide(plugin: [*c]const c.clap_plugin_t) callconv(.c) bool {
    return Instance.from(plugin).editor.setHidden(true);
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
// The host fixture
//
// Public, and above the test banner, because `src/smoke.zig` shares it: that
// harness plays the host for real, against a real window, and a second
// `clap_host_t` written out beside this one would drift from it. The harness
// copies this and overrides `get_extension` alone, so the two cannot disagree
// about anything else a host owes a plugin.
// ---------------------------------------------------------------------------

/// A host offering no extensions at all, which is the shape every callback here
/// has to survive. `get_extension` is populated because `init` calls it; the
/// remaining pointers stay null because nothing in this file reaches them, so a
/// test that starts failing on a null call is reporting a real contract
/// violation rather than a gap in the fixture.
pub const test_host: c.clap_host_t = .{
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

pub fn testNoExtensions(
    host: [*c]const c.clap_host_t,
    extension_id: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    _ = host;
    _ = extension_id;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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

const test_frames = 8;

/// The pointer graph a host builds around one stereo bus on each side.
///
/// Shaped like what a host actually passes rather than the minimum that
/// compiles: `process` reads all of it now, and a fixture that cut corners would
/// quietly stop testing anything the moment the signal tap in phase 2 starts
/// reading a field it had left null.
///
/// A null `transport` is legal and means free-running, which is the case
/// `clap-validator`'s `transport-null` test covers.
const TestBuses = struct {
    in_samples: [2][test_frames]f32 = @splat(@splat(0)),
    out_samples: [2][test_frames]f32 = @splat(@splat(0)),
    in_channels: [2][*c]f32 = @splat(null),
    out_channels: [2][*c]f32 = @splat(null),
    input: c.clap_audio_buffer_t = .{},
    output: c.clap_audio_buffer_t = .{},

    const Options = struct {
        in_channel_count: u32 = 2,
        out_channel_count: u32 = 2,
        /// Point both sides at the same storage, which is the host taking up the
        /// `in_place_pair` offer.
        in_place: bool = false,
        constant_mask: u64 = 0,
    };

    /// Wires the pointers. Separate from initialisation because every one of
    /// them is interior, so this cannot run before the struct has its final
    /// address.
    fn wire(self: *TestBuses, options: Options) void {
        for (0..2) |i| {
            self.in_channels[i] = &self.in_samples[i];
            self.out_channels[i] = if (options.in_place) &self.in_samples[i] else &self.out_samples[i];
        }

        self.input = .{
            .data32 = &self.in_channels,
            .data64 = null,
            .channel_count = options.in_channel_count,
            .latency = 0,
            .constant_mask = options.constant_mask,
        };
        self.output = .{
            .data32 = &self.out_channels,
            .data64 = null,
            .channel_count = options.out_channel_count,
            .latency = 0,
            // Deliberately garbage. A pass-through has to overwrite this rather
            // than inherit whatever the host left behind.
            .constant_mask = std.math.maxInt(u64),
        };
    }

    fn context(self: *TestBuses) c.clap_process_t {
        return .{
            .steady_time = 0,
            .frames_count = test_frames,
            .transport = null,
            .audio_inputs = &self.input,
            .audio_outputs = &self.output,
            .audio_inputs_count = 1,
            .audio_outputs_count = 1,
            .in_events = &test_in_events,
            .out_events = &test_out_events,
        };
    }

    /// What the host would read back out of the output bus.
    fn outChannel(self: *TestBuses, index: usize) []const f32 {
        return self.output.data32[index][0..test_frames];
    }

    fn fillInput(self: *TestBuses, channel: usize, base: f32) void {
        for (&self.in_samples[channel], 0..) |*sample, i| {
            sample.* = base + @as(f32, @floatFromInt(i));
        }
    }
};

/// An activated, processing instance, which is the only state `process` is
/// legal in.
fn testRunning() !*Instance {
    const self = try create(testing.allocator, &test_host);
    _ = self.plugin.init.?(&self.plugin);
    _ = self.plugin.activate.?(&self.plugin, 48_000, 1, test_frames);
    _ = self.plugin.start_processing.?(&self.plugin);
    return self;
}

fn testStop(self: *Instance) void {
    self.plugin.stop_processing.?(&self.plugin);
    self.plugin.deactivate.?(&self.plugin);
    self.plugin.destroy.?(&self.plugin);
}

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

    try testing.expect(plugin.activate.?(plugin, 48_000, 1, test_frames));
    try testing.expect(self.active);
    try testing.expectEqual(@as(f64, 48_000), self.sample_rate);
    try testing.expectEqual(@as(u32, test_frames), self.max_frames);

    var buses: TestBuses = .{};
    buses.wire(.{});

    try testing.expect(plugin.start_processing.?(plugin));
    try testing.expect(self.processing);

    const ctx = buses.context();
    try testing.expectEqual(c.CLAP_PROCESS_CONTINUE, plugin.process.?(plugin, &ctx));

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

    const ports = self.plugin.get_extension.?(&self.plugin, &c.CLAP_EXT_AUDIO_PORTS);
    try testing.expect(ports == @as(?*const anyopaque, &audio_ports));

    const persisted = self.plugin.get_extension.?(&self.plugin, &c.CLAP_EXT_STATE);
    try testing.expect(persisted == @as(?*const anyopaque, &plugin_state));

    const editor = self.plugin.get_extension.?(&self.plugin, &c.CLAP_EXT_GUI);
    try testing.expect(editor == @as(?*const anyopaque, &plugin_gui));

    try testing.expect(self.plugin.get_extension.?(&self.plugin, "clap.params") == null);
}

test "every gui callback is filled in" {
    // A host may call any of these without checking, so a null one is a crash
    // rather than a refusal. Checked by walking the struct so a callback added
    // by a CLAP bump cannot be left null by being overlooked.
    inline for (@typeInfo(c.clap_plugin_gui_t).@"struct".fields) |field| {
        try testing.expect(@field(plugin_gui, field.name) != null);
    }
}

test "the gui reports the one windowing api it can embed in" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    try testing.expect(plugin_gui.is_api_supported.?(plugin, &c.CLAP_WINDOW_API_COCOA, false));
    try testing.expect(!plugin_gui.is_api_supported.?(plugin, &c.CLAP_WINDOW_API_COCOA, true));
    try testing.expect(!plugin_gui.is_api_supported.?(plugin, &c.CLAP_WINDOW_API_WIN32, false));

    // The header requires the constant itself rather than a copy, because a
    // host is entitled to compare the pointer.
    var api: [*c]const u8 = null;
    var is_floating = true;
    try testing.expect(plugin_gui.get_preferred_api.?(plugin, &api, &is_floating));
    try testing.expect(api == @as([*c]const u8, &c.CLAP_WINDOW_API_COCOA));
    try testing.expect(!is_floating);
}

test "the editor opens at its default size and follows set_size from there" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    var width: u32 = 0;
    var height: u32 = 0;
    try testing.expect(plugin_gui.get_size.?(plugin, &width, &height));
    try testing.expectEqual(gui.default_size.width, width);
    try testing.expectEqual(gui.default_size.height, height);

    try testing.expect(plugin_gui.can_resize.?(plugin));

    // `get_size` is how a host learns what `set_size` actually applied, which
    // matters because `set_size` clamps rather than refusing.
    try testing.expect(plugin_gui.set_size.?(plugin, 1280, 720));
    try testing.expect(plugin_gui.get_size.?(plugin, &width, &height));
    try testing.expectEqual(@as(u32, 1280), width);
    try testing.expectEqual(@as(u32, 720), height);

    try testing.expect(plugin_gui.set_size.?(plugin, 1, 1));
    try testing.expect(plugin_gui.get_size.?(plugin, &width, &height));
    try testing.expectEqual(gui.min_size.width, width);
    try testing.expectEqual(gui.min_size.height, height);
}

test "adjust_size clamps each axis on its own rather than preserving a ratio" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    var width: u32 = 300;
    var height: u32 = 900;
    try testing.expect(plugin_gui.adjust_size.?(plugin, &width, &height));
    try testing.expectEqual(gui.min_size.width, width);
    try testing.expectEqual(@as(u32, 900), height);

    // A size the editor would adopt unchanged comes back unchanged.
    width = 1600;
    height = 900;
    try testing.expect(plugin_gui.adjust_size.?(plugin, &width, &height));
    try testing.expectEqual(@as(u32, 1600), width);
    try testing.expectEqual(@as(u32, 900), height);
}

test "the gui reports hints for an editor that resizes on both axes" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);

    var hints: c.clap_gui_resize_hints_t = undefined;
    try testing.expect(plugin_gui.get_resize_hints.?(&self.plugin, &hints));

    try testing.expect(hints.can_resize_horizontally);
    try testing.expect(hints.can_resize_vertically);

    // The 16:9 default is a starting size, not a constraint. Locking it would
    // stop someone widening the editor to buy more time axis, which is the
    // reason the default is wide in the first place.
    try testing.expect(!hints.preserve_aspect_ratio);
}

test "the gui callbacks refuse null out-parameters rather than writing through them" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    var value: u32 = 0;
    try testing.expect(!plugin_gui.get_size.?(plugin, null, null));
    try testing.expect(!plugin_gui.get_size.?(plugin, &value, null));
    try testing.expect(!plugin_gui.get_size.?(plugin, null, &value));
    try testing.expect(!plugin_gui.adjust_size.?(plugin, null, null));
    try testing.expect(!plugin_gui.adjust_size.?(plugin, &value, null));
    try testing.expect(!plugin_gui.get_resize_hints.?(plugin, null));
    try testing.expect(!plugin_gui.set_parent.?(plugin, null));

    var api: [*c]const u8 = null;
    var is_floating = false;
    try testing.expect(!plugin_gui.get_preferred_api.?(plugin, null, &is_floating));
    try testing.expect(!plugin_gui.get_preferred_api.?(plugin, &api, null));
}

test "the gui refuses what it does not implement" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    // Cocoa is a logical-pixel API, so ignoring the host's scale is the
    // documented behaviour rather than a shortcut.
    try testing.expect(!plugin_gui.set_scale.?(plugin, 2.0));

    // Floating mode is refused, so these are unreachable through a
    // well-behaved host and must still not crash.
    try testing.expect(!plugin_gui.set_transient.?(plugin, null));
    plugin_gui.suggest_title.?(plugin, "Fósforo");
}

test "an editor is created and destroyed without ever being parented" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    try testing.expect(plugin_gui.create.?(plugin, &c.CLAP_WINDOW_API_COCOA, false));

    // Reachable with no view behind them, which is the state a host leaves the
    // editor in between `create` and `set_parent`.
    try testing.expect(plugin_gui.show.?(plugin));
    try testing.expect(plugin_gui.hide.?(plugin));

    plugin_gui.destroy.?(plugin);

    // Twice, because a host that calls `gui.destroy` and then `plugin.destroy`
    // reaches the same teardown twice and neither may double-release.
    plugin_gui.destroy.?(plugin);
}

test "destroying the plugin tears down an editor the host left open" {
    const self = try create(testing.allocator, &test_host);
    const plugin = &self.plugin;

    try testing.expect(plugin_gui.create.?(plugin, &c.CLAP_WINDOW_API_COCOA, false));
    try testing.expect(self.editor.created);

    // No `gui.destroy`, which is the host misbehaving. `plugin.destroy` has to
    // clean up anyway; testing.allocator fails the test if anything leaks.
    plugin.destroy.?(plugin);
}

test "state round trips through the extension the host actually calls" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    _ = self.plugin.init.?(&self.plugin);

    var stream: state.TestStream = .{};
    try testing.expect(plugin_state.save.?(&self.plugin, stream.writer()));
    try testing.expect(plugin_state.load.?(&self.plugin, stream.reader()));
}

test "state reports failure rather than dereferencing a null stream" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    _ = self.plugin.init.?(&self.plugin);

    try testing.expect(!plugin_state.save.?(&self.plugin, null));
    try testing.expect(!plugin_state.load.?(&self.plugin, null));
}

test "state load refuses a blob this build cannot read" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    _ = self.plugin.init.?(&self.plugin);

    var stream: state.TestStream = .{};
    stream.seed("not fosforo state");

    try testing.expect(!plugin_state.load.?(&self.plugin, stream.reader()));
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

test "process copies both channels through unaltered" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{});
    buses.fillInput(0, 100);
    buses.fillInput(1, 200);

    const ctx = buses.context();
    try testing.expectEqual(c.CLAP_PROCESS_CONTINUE, self.plugin.process.?(&self.plugin, &ctx));

    try testing.expectEqualSlices(f32, &buses.in_samples[0], buses.outChannel(0));
    try testing.expectEqualSlices(f32, &buses.in_samples[1], buses.outChannel(1));
}

test "process leaves an in-place buffer holding the input it already held" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{ .in_place = true });
    buses.fillInput(0, 1);
    buses.fillInput(1, 2);

    // Recorded before the call, since in-place means the comparison target is
    // the same memory the plugin is about to write.
    const expected = buses.in_samples;

    const ctx = buses.context();
    _ = self.plugin.process.?(&self.plugin, &ctx);

    try testing.expectEqualSlices(f32, &expected[0], buses.outChannel(0));
    try testing.expectEqualSlices(f32, &expected[1], buses.outChannel(1));
}

test "process propagates the input's constant mask" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{ .constant_mask = 0b01 });

    const ctx = buses.context();
    _ = self.plugin.process.?(&self.plugin, &ctx);

    // The garbage the fixture seeded must be gone, not merged into.
    try testing.expectEqual(@as(u64, 0b01), buses.output.constant_mask);
}

test "process silences an output channel the input does not reach" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{ .in_channel_count = 1 });
    buses.fillInput(0, 1);

    // Whatever a host left in the buffer, which must not survive.
    @memset(&buses.out_samples[1], 7);

    const ctx = buses.context();
    _ = self.plugin.process.?(&self.plugin, &ctx);

    try testing.expectEqualSlices(f32, &buses.in_samples[0], buses.outChannel(0));
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0)), buses.outChannel(1));

    // Silence is constant, and only the silenced channel is.
    try testing.expectEqual(@as(u64, 0b10), buses.output.constant_mask);
}

test "process ignores an output channel the input overruns" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{ .out_channel_count = 1 });
    buses.fillInput(0, 1);
    buses.fillInput(1, 2);

    const ctx = buses.context();
    _ = self.plugin.process.?(&self.plugin, &ctx);

    try testing.expectEqualSlices(f32, &buses.in_samples[0], buses.outChannel(0));
    // The second output channel was never offered, so it stays untouched.
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0)), &buses.out_samples[1]);
}

test "process silences the output when the input is unusable" {
    // A host must supply both buses given the declared ports, so each of these
    // is a host misbehaving. Silence is the only safe answer: leaving the
    // output untouched is how uninitialised memory reaches a speaker.
    const shapes = [_]enum { no_bus, null_data, zero_count }{ .no_bus, .null_data, .zero_count };

    for (shapes) |shape| {
        const self = try testRunning();
        defer testStop(self);

        var buses: TestBuses = .{};
        buses.wire(.{});
        @memset(&buses.out_samples[0], 7);
        @memset(&buses.out_samples[1], 7);

        var ctx = buses.context();
        switch (shape) {
            .no_bus => ctx.audio_inputs = null,
            .null_data => buses.input.data32 = null,
            .zero_count => ctx.audio_inputs_count = 0,
        }

        try testing.expectEqual(c.CLAP_PROCESS_CONTINUE, self.plugin.process.?(&self.plugin, &ctx));

        try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0)), buses.outChannel(0));
        try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0)), buses.outChannel(1));
        try testing.expectEqual(@as(u64, 0b11), buses.output.constant_mask);
    }
}

test "process survives a missing output bus rather than writing through null" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{});

    var ctx = buses.context();
    ctx.audio_outputs = null;
    ctx.audio_outputs_count = 0;

    try testing.expectEqual(c.CLAP_PROCESS_CONTINUE, self.plugin.process.?(&self.plugin, &ctx));
}

test "process reports an error rather than dereferencing a null context" {
    const self = try testRunning();
    defer testStop(self);

    try testing.expectEqual(c.CLAP_PROCESS_ERROR, self.plugin.process.?(&self.plugin, null));
}

test "process refuses a block larger than activate negotiated" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{});
    @memset(&buses.out_samples[0], 7);
    @memset(&buses.out_samples[1], 7);

    // A runtime check rather than an assertion, so this holds in a release
    // build too: that is the build where a misbehaving host does damage.
    var ctx = buses.context();
    ctx.frames_count = self.max_frames + 1;

    try testing.expectEqual(c.CLAP_PROCESS_ERROR, self.plugin.process.?(&self.plugin, &ctx));

    // Refused means untouched. Nothing was read from or written to buffers
    // whose length we have just decided we cannot trust.
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(7)), &buses.out_samples[0]);
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(7)), &buses.out_samples[1]);
}

test "the audio path is handed an allocator that cannot reach the heap" {
    const self = try testRunning();
    defer testStop(self);

    // The structural half of ADR 0010: `activate` sized the scratch buffer, and
    // for a pass-through that size is zero, so the allocator `process` builds
    // over it fails every request instead of falling back to the heap.
    try testing.expectEqual(@as(usize, 0), self.scratch.len);

    var fba = std.heap.FixedBufferAllocator.init(self.scratch);
    try testing.expectError(error.OutOfMemory, fba.allocator().alloc(u8, 1));
}
