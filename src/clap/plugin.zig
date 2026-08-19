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
const ring = @import("../dsp/ring.zig");
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

    /// The signal the editor draws, written by the audio thread and by nothing
    /// else. The cursor inside it is the whole synchronisation (ADR 0010).
    ///
    /// Its storage belongs to the **activation** rather than to the instance,
    /// because the capacity is a second of audio at a sample rate that only
    /// exists between `activate` and `deactivate`. The empty default is the
    /// same value `Ring.deinit` leaves behind, so a never-activated instance
    /// and a deactivated one agree about the shape.
    ///
    /// That lifetime has a consequence nothing here can settle: `deactivate`
    /// frees this on the main thread, and once the render thread starts reading
    /// it there is a race between the two. Issue #37 owns it, and floats giving
    /// the storage the instance's lifetime instead, which makes the race
    /// disappear rather than managing it. There is no reader yet, so there is
    /// nothing to race with today.
    history: ring.Ring = .{ .samples = &.{} },

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
    // most of them `activate` has a documented way to refuse. A bad value
    // accepted here would not fail here: it would surface on the audio thread,
    // which is the one place with no way to report anything.
    //
    // Sizing the history does not make the rate check redundant, though it is
    // worth knowing that it very nearly does: measured through `historySamples`
    // and `Ring.init`, every value these reject is one the buffer would reject
    // too, with zero, negatives, `nan` and subhertz rates all arriving as
    // `EmptyCapacity` and `inf` as `Overflow`. What the check buys is that
    // `self.sample_rate` is **stored** below and outlives this call, so it is
    // the difference between refusing a rate and keeping a `nan` that phase 3
    // divides by. It also names the real fault in the log rather than reporting
    // a plausible rate as an impossible capacity.
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

    // A refused activation is not followed by `deactivate`, since the host is
    // entitled to believe nothing was taken, so this failure path has to be its
    // own undo. Restoring the empty slice matters as much as the free: a
    // later `activate` assigns straight over `self.scratch`, so a dangling one
    // left here would be leaked rather than merely stale.
    //
    // `print` rather than `message` because the two ways this fails want
    // opposite responses from whoever reads the host log. `Overflow` says the
    // rate is nonsense; `OutOfMemory` says the machine is full.
    self.history = ring.Ring.init(self.allocator, historySamples(sample_rate)) catch |err| {
        self.allocator.free(self.scratch);
        self.scratch = &.{};
        self.log.print(c.CLAP_LOG_ERROR, "activate failed: could not size the history buffer for {d} Hz: {s}", .{
            sample_rate,
            @errorName(err),
        });
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
/// Zero, and now an answer rather than a placeholder. The history buffer landed
/// without needing an intermediate: `passThrough` writes the host's own output
/// buffer, `Ring.write` copies straight out of that into storage `activate`
/// already owns, and no step between the two holds anything of its own. A
/// zero-length fixed buffer turns any allocation into `error.OutOfMemory` at the
/// call site instead of a heap call on the audio thread, and nothing about that
/// property is weaker for the number being zero.
///
/// It stops being zero the first time a step wants a buffer that is neither the
/// host's nor the ring's: summing the channels to a mono tap, or a decimation
/// stage in front of the ring, would each want `max_frames` samples. The
/// parameter stays for that reason rather than being removed.
fn scratchBytes(max_frames: u32) usize {
    _ = max_frames;
    return 0;
}

/// How far back the history reaches, in seconds.
const history_seconds: f64 = 1;

/// Samples of history to keep, from the rate the host activated at.
///
/// A second, which is the ratio ADR 0010 rests on: a capacity on the order of a
/// second against a display window of tens of milliseconds is what lets
/// `Ring.read` check for a torn window instead of retrying in a loop.
/// `Ring.init` rounds up to a power of two, so 48 kHz actually buys 1.365
/// seconds and 256 KiB, next to phase 3's accumulation textures at megabytes
/// each.
///
/// **Saturating rather than `@intFromFloat`**, which is illegal behaviour out of
/// range: `activate` has established that `sample_rate` is finite and positive
/// and nothing more, so a host claiming 1e300 Hz reaches this. `lossyCast`
/// clamps it to `maxInt(usize)`, which `ceilPowerOfTwo` rejects before
/// allocating anything, and `activate` refuses and says why. A bare cast would
/// instead panic in the one function whose whole design is to refuse.
///
/// Zero is a legal answer, for a sample rate below 1 Hz. `Ring.init` refuses it
/// as `error.EmptyCapacity`, which is the right answer for a rate no audio
/// device has.
///
/// **The floor is deliberately not `max_frames`.** Nothing needs the ring to
/// hold a whole block: `Ring.write` is total against a block longer than its
/// capacity and tested for it, and taking that floor would turn a host
/// declaring an absurd block size from a harmless truncation into an
/// eight-gigabyte allocation and a refused activation.
fn historySamples(sample_rate: f64) usize {
    return std.math.lossyCast(usize, sample_rate * history_seconds);
}

/// [main-thread & active] The mirror of `activate`, and the only other place
/// the audio path's memory may move.
fn deactivate(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.from(plugin);
    std.debug.assert(self.active and !self.processing);

    self.allocator.free(self.scratch);
    self.scratch = &.{};
    self.history.deinit(self.allocator);

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
///
/// The history is cleared, which is the header's own definition of this
/// callback: "clears all buffers, performs a full reset of the processing
/// state". A scope that kept its window across a transport locate would be
/// drawing audio from a different part of the timeline, and phase 4's trigger
/// scans backward sample by sample and would find threshold crossings on the
/// far side of the jump.
///
/// `Ring.clear` publishes a capacity of silence rather than blanking the stored
/// samples in place, and that shape is load-bearing rather than incidental. See
/// its docstring: the version that leaves the cursor alone races the reader in
/// a way `coherent` is structurally unable to report.
fn reset(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.from(plugin);
    std.debug.assert(self.active);

    self.history.clear();
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
    // Nothing below is sized from `max_frames`: the scratch buffer is empty and
    // the history is sized from the sample rate, which `Ring.write` is total
    // against for a block longer than its capacity. What this refuses is a host
    // that has broken the one bound it negotiated, because the very next thing
    // `process` does is read `frames_count` samples out of that host's own
    // buffers on its word that they are that long.
    if (ctx.frames_count > self.max_frames) return c.CLAP_PROCESS_ERROR;

    var fba = std.heap.FixedBufferAllocator.init(self.scratch);
    const audio = fba.allocator();

    if (passThrough(audio, ctx)) |emitted| tap(audio, &self.history, emitted);

    // The structural guarantee ADR 0010 asks for, stated as an assertion rather
    // than left as a comment nobody can check.
    std.debug.assert(fba.end_index == 0);

    return c.CLAP_PROCESS_CONTINUE;
}

/// Copy the main input to the main output, and report the channel the history
/// tap records.
///
/// Returning the slice rather than letting the tap rebuild the checks below is
/// what keeps one answer to "was anything emitted, and where". Every early
/// return here is a host shape in which the output buffer was left exactly as
/// the host handed it over, and a second copy of that reasoning could drift into
/// recording uninitialised host memory as if it were audio.
///
/// Null means nothing was written, which is not the same as silence: the
/// unusable-input case writes zeroes and returns them, because a flat line is
/// what a scope should draw rather than a trace frozen on the last good block.
///
/// The slice points into the host's own buffer and is valid only for this
/// `process` call, which is why the one caller copies out of it immediately.
///
/// Takes an allocator it does not use, which is deliberate: ADR 0010 wants "the
/// audio path cannot touch the heap" to be a fact about the call graph, and the
/// way to make that true is for the path to have taken its allocator as a
/// parameter from the beginning rather than acquiring one later.
fn passThrough(allocator: std.mem.Allocator, ctx: c.clap_process_t) ?[]const f32 {
    _ = allocator;

    if (ctx.audio_outputs == null or ctx.audio_outputs_count == 0) return null;
    const out = &ctx.audio_outputs[0];

    const frames = ctx.frames_count;
    if (out.data32 == null or frames == 0) return null;

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

    // Below the mask rather than folded into the early returns above, because
    // hoisting it would skip clearing the garbage the host left in
    // `constant_mask`, which this function owes its caller either way. A bus
    // declaring no channels wrote nothing above and has nothing to tap.
    if (out.channel_count == 0) return null;
    return out.data32[0][0..frames];
}

/// Record what the plugin just emitted, so the editor has a window to draw.
///
/// One channel, which is ADR 0010's shape rather than a simplification: it
/// describes an analyzer that "passes audio through and taps one channel", and
/// ADR 0012 files stereo monitoring under a lens deferred past v0.1.0. The
/// second channel, when it arrives, is a second `Ring` sharing nothing with this
/// one rather than a wider element type here, and a sum is not an option at all,
/// because it destroys at capture time exactly what an X-Y vectorscope needs.
///
/// Downstream of the copy on purpose, so the ring holds what the plugin actually
/// emitted. That includes the silence `passThrough` writes when the input is
/// unusable, which is the flat line a scope should draw rather than a trace that
/// stops moving.
///
/// Takes an allocator it does not use, for the reason `passThrough` does: the
/// call graph is what proves the audio path cannot reach the heap, and a step
/// that quietly opts out of the parameter is a step that has to be argued about
/// rather than read.
fn tap(allocator: std.mem.Allocator, history: *ring.Ring, emitted: []const f32) void {
    _ = allocator;

    // Verbatim, including a channel the host flagged constant. That flag says
    // every sample in the block holds the same value, and the header is
    // explicit that checking it is optional, "and this implies that the buffer
    // must be filled with the constant value", so there are always
    // `frames_count` real samples there. Skipping the write would freeze the
    // trace whenever a track went quiet, and worse, would stop the cursor
    // advancing with the stream, so every window read afterwards would be
    // misaligned in time.
    history.write(emitted);
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
/// quietly stop testing anything the moment the signal tap started reading a
/// field it had left null. That prediction came true: the tap is the first code
/// here to assume output channel 0 exists, and "an output bus declaring no
/// channels leaves the history where it was" is the case that catches it. Note
/// what makes that test worth its lines: the fixture holds live pointers, so a
/// missing guard would not crash here. It would silently record a channel the
/// host never offered and crash only in a real host.
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

/// The most recent `window.len` samples the tap published, oldest first.
///
/// Reading the ring here is not the render thread's read, which #37 owns. It
/// exists because what the tap wrote is otherwise unobservable: the container's
/// own tests cover the container and can say nothing about the wiring.
fn testTapped(self: *Instance, window: []f32) !void {
    // False would mean the producer lapped the window mid-copy, which cannot
    // happen with one thread. Asserted rather than discarded so a test that
    // starts racing says so instead of comparing a torn window.
    try testing.expect(self.history.read(window));
}

/// The ramp `TestBuses.fillInput` writes, as a value to compare against, so a
/// test spanning several blocks does not spell out two dozen literals.
fn testRamp(comptime n: usize, base: f32) [n]f32 {
    var out: [n]f32 = undefined;
    for (&out, 0..) |*sample, i| sample.* = base + @as(f32, @floatFromInt(i));
    return out;
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

test "activate sizes the history from the sample rate and reports the rounded capacity" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    // 96 kHz rather than the obvious 44.1: that rate rounds to 65536 as well,
    // so a build that ignored `sample_rate` and hardcoded one second at 48 kHz
    // would pass a 44.1 kHz check. This is the lowest common rate whose
    // capacity differs, which makes it the one that discriminates.
    for ([_]f64{ 48_000, 96_000 }) |rate| {
        try testing.expect(plugin.activate.?(plugin, rate, 1, test_frames));

        // The contract, rather than the arithmetic: the buffer holds at least
        // the second it was asked for.
        try testing.expect(@as(f64, @floatFromInt(self.history.capacity())) >= rate);
        try testing.expectEqual(@as(u64, 0), self.history.written());

        plugin.deactivate.?(plugin);
    }

    try testing.expect(plugin.activate.?(plugin, 48_000, 1, test_frames));
    try testing.expectEqual(@as(usize, 65_536), self.history.capacity());
    plugin.deactivate.?(plugin);

    try testing.expect(plugin.activate.?(plugin, 96_000, 1, test_frames));
    try testing.expectEqual(@as(usize, 131_072), self.history.capacity());
    plugin.deactivate.?(plugin);
}

test "deactivate frees the history and a later activate starts it over" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    try testing.expect(plugin.activate.?(plugin, 48_000, 1, test_frames));
    _ = plugin.start_processing.?(plugin);

    var buses: TestBuses = .{};
    buses.wire(.{});
    const ctx = buses.context();
    _ = plugin.process.?(plugin, &ctx);
    try testing.expectEqual(@as(u64, test_frames), self.history.written());

    plugin.stop_processing.?(plugin);
    plugin.deactivate.?(plugin);
    try testing.expectEqual(@as(usize, 0), self.history.capacity());

    try testing.expect(plugin.activate.?(plugin, 96_000, 1, test_frames));
    try testing.expectEqual(@as(usize, 131_072), self.history.capacity());

    // This half matters more than it looks. `Ring.deinit` does not touch the
    // cursor, so it only holds because `activate` assigns a whole fresh `Ring`
    // whose cursor takes its default. One that kept a stale cursor over freshly
    // zeroed storage would make `read` report a full second of silence as if it
    // were audio the host never played.
    try testing.expectEqual(@as(u64, 0), self.history.written());

    plugin.deactivate.?(plugin);
    // testing.allocator fails the test if either activation leaked.
}

test "activate refuses when the history cannot be allocated" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const self = try create(failing.allocator(), &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    // Derived rather than hardcoded. Whatever `create` cost, the next
    // allocation to reach the heap is the history's: `scratchBytes` returns
    // zero and a zero-byte `alloc` short-circuits before the vtable, so nothing
    // in between consumes an index. A literal here would rot silently the day
    // either of those changed.
    failing.fail_index = failing.alloc_index;

    try testing.expect(!plugin.activate.?(plugin, 48_000, 1, test_frames));

    // Without this the refusal is indistinguishable from one where validation
    // rejected 48 kHz, which would make the test pass for the wrong reason.
    try testing.expect(failing.has_induced_failure);

    try testing.expect(!self.active);
    try testing.expectEqual(@as(usize, 0), self.history.capacity());

    // The undo. `testing.allocator` underneath catches a scratch buffer the
    // refusal path forgot to free, which is the failure that appears the moment
    // `scratchBytes` stops returning zero.
    try testing.expectEqual(@as(usize, 0), self.scratch.len);
}

test "activate refuses a sample rate no history could be sized for" {
    const self = try create(testing.allocator, &test_host);
    defer self.plugin.destroy.?(&self.plugin);
    const plugin = &self.plugin;

    // Both pass `isFinite` and `> 0`, so `activate`'s own bounds let them
    // through and the refusal has to come from sizing the buffer.
    //
    // The large one is the reason `historySamples` saturates instead of
    // casting: `@intFromFloat` is illegal behaviour out of range, so without
    // that this case does not fail the test, it panics. No mid-range value like
    // 1e12 belongs here, because that saturates to a real four-terabyte request
    // and makes the run's cost depend on how the OS declines it.
    try testing.expect(!plugin.activate.?(plugin, std.math.floatMax(f64), 1, test_frames));
    try testing.expect(!self.active);

    // And a rate no audio device has, which rounds down to a ring with no slots.
    try testing.expect(!plugin.activate.?(plugin, 0.5, 1, test_frames));
    try testing.expect(!self.active);

    try testing.expectEqual(@as(usize, 0), self.history.capacity());
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

    // And the tap read that same memory rather than assuming the two sides are
    // distinct buffers.
    var window: [test_frames]f32 = undefined;
    try testTapped(self, &window);
    try testing.expectEqualSlices(f32, &expected[0], &window);
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

        // All three shapes still advance the history, with the silence the
        // plugin actually emitted. A host misbehaving on the input side leaves
        // a timeline the scope keeps drawing, and a flat line is the truth
        // about what went downstream. Freezing the trace instead would report
        // the last good block as if it were still playing.
        try testing.expectEqual(@as(u64, test_frames), self.history.written());

        var window: [test_frames]f32 = undefined;
        try testTapped(self, &window);
        try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0)), &window);
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

    // The one unusable-bus shape that leaves the history where it was. With no
    // output there is nothing the plugin emitted, so there is nothing to record
    // and the trace holds rather than advancing with invented silence.
    try testing.expectEqual(@as(u64, 0), self.history.written());
}

test "process reports an error rather than dereferencing a null context" {
    const self = try testRunning();
    defer testStop(self);

    try testing.expectEqual(c.CLAP_PROCESS_ERROR, self.plugin.process.?(&self.plugin, null));
    try testing.expectEqual(@as(u64, 0), self.history.written());
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
    // whose length we have just decided we cannot trust, and nothing reached
    // the history either.
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(7)), &buses.out_samples[0]);
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(7)), &buses.out_samples[1]);
    try testing.expectEqual(@as(u64, 0), self.history.written());
}

test "the audio path is handed an allocator that cannot reach the heap" {
    const self = try testRunning();
    defer testStop(self);

    // The structural half of ADR 0010: `activate` sized the scratch buffer, and
    // neither the pass-through nor the tap needs one byte of it, so the
    // allocator `process` builds over it fails every request instead of falling
    // back to the heap.
    try testing.expectEqual(@as(usize, 0), self.scratch.len);

    var fba = std.heap.FixedBufferAllocator.init(self.scratch);
    try testing.expectError(error.OutOfMemory, fba.allocator().alloc(u8, 1));
}

test "process taps the left output channel into the history" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{});
    buses.fillInput(0, 100);
    buses.fillInput(1, 200);

    const ctx = buses.context();
    _ = self.plugin.process.?(&self.plugin, &ctx);

    // By exactly the frame count, rather than by frames times channels or by
    // one per block.
    try testing.expectEqual(@as(u64, test_frames), self.history.written());

    // The two bases are far enough apart that the right channel (200 up) and
    // the sum (300 up) each fail this same assertion, so one comparison pins
    // "left", "not right" and "not summed" at once.
    var window: [test_frames]f32 = undefined;
    try testTapped(self, &window);
    try testing.expectEqualSlices(f32, &buses.in_samples[0], &window);
}

test "repeated process calls extend the history rather than restarting it" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{});

    const ctx = buses.context();
    for ([_]f32{ 0, test_frames, 2 * test_frames }) |base| {
        buses.fillInput(0, base);
        _ = self.plugin.process.?(&self.plugin, &ctx);
    }

    // The single-call test passes equally well against a tap that rewinds the
    // cursor or rewrites slot zero each block. This is the cheapest one that
    // does not.
    try testing.expectEqual(@as(u64, 3 * test_frames), self.history.written());

    var window: [3 * test_frames]f32 = undefined;
    try testTapped(self, &window);
    try testing.expectEqualSlices(f32, &testRamp(3 * test_frames, 0), &window);
}

test "the tap reads the output bus rather than the input the host handed over" {
    const self = try testRunning();
    defer testStop(self);

    // The only shape where the two buffers hold different values and both are
    // readable, which makes it the only test that can tell "taps the output"
    // from "taps the input". Every other one in this file passes either way.
    var buses: TestBuses = .{};
    buses.wire(.{ .in_channel_count = 0 });
    buses.fillInput(0, 100);

    const ctx = buses.context();
    _ = self.plugin.process.?(&self.plugin, &ctx);

    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0)), buses.outChannel(0));
    try testing.expectEqual(@as(u64, test_frames), self.history.written());

    var window: [test_frames]f32 = undefined;
    try testTapped(self, &window);
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0)), &window);
}

test "a block the host flagged constant is tapped in full rather than skipped" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{ .constant_mask = 0b11 });
    const ctx = buses.context();

    // A silent block the host flagged constant is still a window the scope has
    // to draw. A tap that skipped it would freeze the trace whenever a track
    // went quiet, and would stop the cursor advancing with the stream, so every
    // window read afterwards would be misaligned in time.
    _ = self.plugin.process.?(&self.plugin, &ctx);
    try testing.expectEqual(@as(u64, test_frames), self.history.written());

    var window: [test_frames]f32 = undefined;
    try testTapped(self, &window);
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0)), &window);

    // And a constant block that is not silence arrives in full. The header is
    // explicit that checking the mask is optional, "and this implies that the
    // buffer must be filled with the constant value", so all eight samples are
    // there. This is the half that fails if someone reads `data32[0][0]` and
    // splats it.
    @memset(&buses.in_samples[0], 0.5);
    _ = self.plugin.process.?(&self.plugin, &ctx);

    try testing.expectEqual(@as(u64, 2 * test_frames), self.history.written());
    try testTapped(self, &window);
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0.5)), &window);
}

test "an output bus declaring no channels leaves the history where it was" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{ .out_channel_count = 0 });
    buses.fillInput(0, 1);

    const ctx = buses.context();
    try testing.expectEqual(c.CLAP_PROCESS_CONTINUE, self.plugin.process.?(&self.plugin, &ctx));

    // This checks a guard, not a crash. `passThrough`'s loops are both bounded
    // by `out.channel_count`, so the tap is the first code here to assume
    // channel 0 exists, and the fixture happens to hold two live pointers, so a
    // missing guard would silently record a channel the host never offered and
    // would crash only in a real host.
    try testing.expectEqual(@as(u64, 0), self.history.written());
}

test "a zero-frame block leaves the history where it was" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{});

    var ctx = buses.context();
    ctx.frames_count = 0;

    try testing.expectEqual(c.CLAP_PROCESS_CONTINUE, self.plugin.process.?(&self.plugin, &ctx));

    // `Ring.write` no-ops on an empty slice, so this looks covered by the
    // container. It is not: the two ways to get here differ, and `to[0..0]` on
    // a null `data32` is the one that is not safe. The guard has to come first.
    try testing.expectEqual(@as(u64, 0), self.history.written());
}

test "reset publishes a capacity of silence rather than blanking behind the cursor" {
    const self = try testRunning();
    defer testStop(self);

    var buses: TestBuses = .{};
    buses.wire(.{});
    buses.fillInput(0, 100);

    const ctx = buses.context();
    _ = self.plugin.process.?(&self.plugin, &ctx);

    self.plugin.reset.?(&self.plugin);

    // Advanced by the whole capacity rather than standing still. A clear that
    // left the cursor alone would write behind it, where `coherent` cannot see
    // it, and would hand a reader caught mid-copy a half-zeroed window while
    // reporting it as intact.
    try testing.expectEqual(
        @as(u64, test_frames + self.history.capacity()),
        self.history.written(),
    );

    var window: [test_frames]f32 = undefined;
    try testTapped(self, &window);
    try testing.expectEqualSlices(f32, &@as([test_frames]f32, @splat(0)), &window);

    // And the stream carries on from there, so the trace fills back in from the
    // right rather than restarting.
    buses.fillInput(0, 900);
    _ = self.plugin.process.?(&self.plugin, &ctx);
    try testTapped(self, &window);
    try testing.expectEqualSlices(f32, &buses.in_samples[0], &window);
}
