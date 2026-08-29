//! The GUI smoke harness: the only thing in this project that *runs* Metal and
//! AppKit rather than type-checking them.
//!
//! `zig build test` executes no message send and no GPU call. Every one of them
//! is type-checked, by the `testing.refAllDecls` in `gpu/metal/renderer.zig` and
//! `platform/view.zig`, and `zig build validate-shaders` type-checks the MSL,
//! but nothing runs. The failures that fall through that gap are the ones that
//! surface inside someone's DAW: a shader that passes `metal -fsyntax-only` and
//! then fails `newLibraryWithSource:`, a selector whose signature is wrong in a
//! way the ABI tolerates until it is called, a retain and release imbalance
//! across editor cycles, or a teardown that releases the view before the layer
//! attached to it. This is the harness that closes it. See ADR 0013.
//!
//! Two halves, split because their environmental requirements differ:
//!
//!     gpu     a Metal device, no window    runtime shader compilation,
//!                                          pipeline assembly, wrong selectors
//!     appkit  a window server and a device view embedding, teardown order,
//!                                          retain and release across cycles
//!
//! **An executable rather than a test artifact**, deliberately. A test binary
//! gets `std.testing`'s assertions but must stay silent: `std.debug.print` from
//! inside one interleaves with the test runner's own stream, which the build
//! runner reads as a failed step, and `clap/log.zig` documents the same hazard
//! for the same reason. A smoke test that cannot say what it was doing when it
//! died is worth much less than one that can, so this reports through stderr and
//! its own exit code instead.
//!
//! **Never wired into `zig build test`.** It needs machine capabilities the
//! default build must not depend on, which is `addShaderValidationStep`'s
//! position and ADR 0009's reasoning.
//!
//! This file plays the **host**. That is why it is the one place above
//! `platform/` that sends AppKit messages: `platform/view.zig` is the plugin's
//! side of the embedding boundary, and an `NSWindow` is the other side of it.

const std = @import("std");
const objc = @import("objc");

const clap = @import("clap/c.zig");
const gpu = @import("gpu/iface.zig");
const gui = @import("clap/gui.zig");
const io = @import("platform/io.zig");
const platform = @import("platform/objc.zig");
const plugin = @import("clap/plugin.zig");
const root = @import("main.zig");

const c = clap.c;

/// Open and close cycles the AppKit half runs when the caller does not say.
///
/// Enough that a per-cycle leak would show as a trend rather than as noise, and
/// few enough to stay quick. The leak criterion in `scripts/smoke-leak-check`
/// asks for far more, because a leak of one object per cycle only becomes
/// unmissable against the `NSXPCConnection` chatter AppKit produces on its own.
const default_cycles = 10;

/// How long a cycle will wait for the render loop to put a frame on screen.
///
/// Generous by two orders of magnitude: a 60 Hz display owes a frame every
/// 16 ms, and the first tick after `CVDisplayLinkStart` arrives within one
/// refresh period. The margin is for a loaded CI runner, not for a loop that is
/// working. Anything approaching this ceiling is the defect, not the timeout.
const frame_timeout_us: u64 = 2 * std.time.us_per_s;

/// How often the wait below re-reads the counter. Short enough that a healthy
/// loop is confirmed almost immediately, long enough not to spin a core.
const frame_poll_us: u32 = 1 * std.time.us_per_ms;

/// What the cycle activates the plugin at, and how much audio it pushes through
/// before opening the editor.
///
/// Without an activation `Instance.history` holds a capacity of silence and
/// every upload is a window of zeros, which exercises the path and proves
/// nothing about the samples. 48 kHz is the rate `Editor.window` then follows,
/// and the blocks below fill more than the 960-sample window it asks for, so the
/// render thread reads real audio rather than a mostly-zero pad.
const smoke_sample_rate: f64 = 48_000;
const smoke_block_frames: u32 = 512;
const smoke_blocks = 4;

/// Sleep, which is all this harness asks of `std.Io`.
///
/// Taken from `platform/io.zig` rather than declared here. Zig 0.16 moved every
/// sleep behind an `Io` instance, and a harness that waits for another thread
/// needs to wait; ADR 0015 records why that instance is shared and why it is
/// constructed in exactly one place.
///
/// Cancellation cannot fire. `Threaded.Thread.current` is a threadlocal set only
/// for threads the runtime spawns, `init_single_threaded` spawns none, and every
/// syscall region therefore takes the uncancelable branch. The error is
/// propagated rather than swallowed because `report` prints it by name and a
/// `catch` would need a justification longer than this sentence.
fn sleepFor(duration: std.Io.Duration) std.Io.Cancelable!void {
    return io.get().sleep(duration, .awake);
}

/// AppKit constants, restated here for the reason `platform/objc.zig` restates
/// `NSView.autoresizingMask`: the headers are Objective-C and `translate-c`
/// cannot read them. Two is the whole list, because a borderless window is
/// `NSWindowStyleMaskBorderless`, which is zero.
const ns = struct {
    const backing_store_buffered: u64 = 2;

    /// `NSApplicationActivationPolicyAccessory`. An unbundled binary defaults to
    /// `Prohibited`, which cannot put a window on screen at all, and `Regular`
    /// would take focus from the terminal that launched this.
    const activation_policy_accessory: i64 = 1;
};

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = init.args.iterate();
    _ = args.next();

    const half = args.next() orelse return usage();

    if (std.mem.eql(u8, half, "gpu")) return report("gpu", gpuHalf());

    if (std.mem.eql(u8, half, "appkit")) {
        const cycles = if (args.next()) |text| std.fmt.parseInt(u32, text, 10) catch {
            say("smoke: `{s}` is not a cycle count", .{text});
            return 2;
        } else default_cycles;

        if (cycles == 0) {
            say("smoke: a cycle count of zero would assert nothing", .{});
            return 2;
        }

        return report("appkit", appkitHalf(cycles));
    }

    return usage();
}

fn usage() u8 {
    say(
        \\usage: fosforo-smoke gpu
        \\       fosforo-smoke appkit [cycles]
        \\
        \\  gpu     acquire a device, compile the embedded shader, build the pipeline
        \\  appkit  open a window and cycle the editor through it
    , .{});
    return 2;
}

/// The exit-code discipline, in one place.
///
/// Zero for a pass, 1 for a half that ran and failed, 2 for being called wrong.
/// The distinction matters to CI: the third is a defect in the invocation and
/// the second is the thing this exists to find.
fn report(half: []const u8, result: anyerror!void) u8 {
    result catch |err| {
        say("smoke: {s} FAILED: {s}", .{ half, @errorName(err) });
        return 1;
    };
    say("smoke: {s} ok", .{half});
    return 0;
}

/// Everything this harness says, on stderr.
///
/// The same stream `clap/log.zig` mirrors to in a debug build, so the plugin's
/// own diagnostics interleave with the stage they belong to rather than arriving
/// on a second channel in a different order.
fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

// ---------------------------------------------------------------------------
// The GPU half
// ---------------------------------------------------------------------------

/// Needs a device and nothing else, which is what made it the half that could be
/// required in CI first; #72 required the other one too, once 65 runs had
/// settled that a hosted runner grants a window server. Runtime shader
/// compilation is precisely what
/// `zig build validate-shaders` cannot prove, since a file can type-check under
/// `metal -fsyntax-only` and still fail `newLibraryWithSource:`.
fn gpuHalf() !void {
    say("  acquiring a device, compiling shaders/scope.metal, building the pipeline", .{});

    var diags: gpu.Diagnostics = .{};
    gpu.Renderer.probe(&diags) catch |err| {
        say("  {s}", .{diags.message()});
        return err;
    };

    // `probe` fills the buffer in on success too. Naming the device is the
    // difference between "something ran" and a result someone can check.
    say("  device: {s}", .{diags.message()});
}

// ---------------------------------------------------------------------------
// The AppKit half
// ---------------------------------------------------------------------------

/// The host's log extension, which the plugin discovers through
/// `smoke_host.get_extension` exactly as it would in a DAW.
///
/// Worth its few lines twice over. It is the only runtime exercise of the
/// plugin calling *into* a host, and in a build that is not Debug the `stderr`
/// mirror in `clap/log.zig` is compiled out, leaving this as the only channel a
/// Metal compiler diagnostic has.
const host_log: c.clap_host_log_t = .{ .log = hostLog };

/// The shared fixture with one field replaced.
///
/// `plugin.test_host` is the same struct `zig build test` drives every callback
/// against, which is the point: a second `clap_host_t` written out here would
/// drift from it, and only one of the two would ever be exercised by the tests.
const smoke_host: c.clap_host_t = host: {
    var h = plugin.test_host;
    h.name = "fosforo smoke";
    h.get_extension = hostGetExtension;
    break :host h;
};

fn hostGetExtension(
    host: [*c]const c.clap_host_t,
    extension_id: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    if (extension_id == null) return null;
    if (std.mem.eql(u8, std.mem.span(extension_id), &c.CLAP_EXT_LOG)) return &host_log;

    // Everything else is answered the way the shared fixture answers it, so
    // this host stays the bare one the tests use plus exactly one extension.
    return plugin.testNoExtensions(host, extension_id);
}

/// [thread-safe] Prefixed rather than merged into the harness's own output.
///
/// A debug build prints every message twice, once here and once through the
/// `stderr` mirror in `clap/log.zig`. That is not noise to be suppressed: the
/// two lines are the two channels, and seeing both is how a run confirms the
/// host path works rather than assuming it.
fn hostLog(
    host: [*c]const c.clap_host_t,
    severity: c.clap_log_severity,
    msg: [*c]const u8,
) callconv(.c) void {
    _ = host;
    _ = severity;
    if (msg == null) return;
    say("  via clap.log: {s}", .{std.mem.span(msg)});
}

/// Needs a window server as well as a device, which is the part a headless
/// runner may refuse. CI gates on it anyway, since #72: 65 runs settled that a
/// hosted runner grants one, and this half carries the only assertion anywhere
/// on `liveAccumulationTextures`.
fn appkitHalf(cycles: u32) !void {
    platform.assertMainThread();

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // Before any window. A process with no window-server connection fails here,
    // and reporting that as itself is what keeps an unsupported CI runner
    // distinguishable from a defect in this code.
    const app_class = objc.getClass("NSApplication") orelse return error.NoAppKit;
    const app = app_class.msgSend(objc.Object, "sharedApplication", .{});
    if (app.value == null) return error.NoApplication;
    app.msgSend(void, "setActivationPolicy:", .{ns.activation_policy_accessory});
    say("  NSApplication connected", .{});

    const window = try openWindow();
    defer closeWindow(window);

    const content = window.msgSend(objc.Object, "contentView", .{});
    const parent = content.value orelse return error.NoContentView;
    say("  window open at {d}x{d}, backing scale {d}", .{
        gui.default_size.width,
        gui.default_size.height,
        window.msgSend(f64, "backingScaleFactor", .{}),
    });

    // Through the real entry point rather than reaching for `plugin.factory`,
    // so `src/main.zig` is on the path a host actually takes.
    if (!root.entry.init.?("fosforo-smoke")) return error.EntryInitFailed;
    defer root.entry.deinit.?();

    const raw = root.entry.get_factory.?(&c.CLAP_PLUGIN_FACTORY_ID) orelse return error.NoFactory;
    const factory: *const c.clap_plugin_factory_t = @ptrCast(@alignCast(raw));
    say("  factory resolved through clap_entry", .{});

    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        // Per cycle, so AppKit's autoreleased objects drain on the same schedule
        // the cycles run on. Without this they accumulate until the outer pool
        // drains and every leak measurement below is taken against a pile of
        // objects that were never leaked.
        const cycle_pool = objc.AutoreleasePool.init();
        defer cycle_pool.deinit();

        // Every fourth cycle skips `gui.destroy`, which is a host misbehaving.
        // `plugin.destroy` claims to tear the editor down anyway, and until now
        // that claim has only ever been checked against an editor with no view
        // and no renderer behind it.
        oneCycle(factory, parent, i % 4 != 3) catch |err| {
            say("  failed during cycle {d} of {d}", .{ i + 1, cycles });
            return err;
        };
    }

    // The one leak this project's leak check cannot see, so it is asserted here
    // instead. `scripts/smoke-leak-check` catches a released-one-too-few command
    // queue and calls the same omission on the window buffers clean, because
    // `leaks` walks the malloc heap and a Metal buffer's storage is not in it.
    // Measured, not assumed: see `live_windows` in the Metal backend.
    //
    // After the loop rather than inside it, because every fourth cycle leaves
    // the editor for `plugin.destroy` to tear down, and that runs in a `defer`
    // the cycle itself cannot assert after.
    const live = gpu.Renderer.liveWindowBuffers();
    if (live != 0) {
        say("  {d} window buffers were never released across {d} cycles", .{ live, cycles });
        return error.WindowBuffersLeaked;
    }

    // The same argument one resource further, and a worse case. `leaks` cannot
    // see a leaked accumulation texture either, and unlike the window buffers
    // neither can peak RSS: a planted leak of roughly 46 MB per cycle moved the
    // resident set by 0.2 MB across 40 cycles and reported *fewer* leaked bytes
    // than a clean run. This assertion is the only thing anywhere that fails.
    //
    // It also covers more ground than the one above, because these are
    // reallocated on every resize that changes the pixel count and `oneCycle`
    // performs one, so a resize path that allocated without releasing would
    // show up here rather than only a teardown that forgot.
    const textures = gpu.Renderer.liveAccumulationTextures();
    if (textures != 0) {
        say("  {d} accumulation textures were never released across {d} cycles", .{ textures, cycles });
        return error.AccumulationTexturesLeaked;
    }

    say("  {d} open and close cycles clean", .{cycles});
}

fn openWindow() !objc.Object {
    const frame: platform.CGRect = .{ .size = .{
        .width = @floatFromInt(gui.default_size.width),
        .height = @floatFromInt(gui.default_size.height),
    } };

    const window_class = objc.getClass("NSWindow") orelse return error.NoAppKit;
    const window = window_class
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
        frame,
        @as(u64, 0), // NSWindowStyleMaskBorderless
        ns.backing_store_buffered,
        false,
    });
    if (window.value == null) return error.WindowCreationFailed;
    errdefer window.release();

    // Ordered in rather than merely allocated, because a layer in an off-screen
    // window is a different case from one the compositor is showing, and the
    // second is the one a DAW produces.
    window.msgSend(void, "orderFront:", .{@as(?*anyopaque, null)});
    return window;
}

/// Ordered out before released. `close` is deliberately not sent: a window built
/// this way is released when closed by default, and pairing that with the
/// release owed for `alloc` would be an over-release.
fn closeWindow(window: objc.Object) void {
    window.msgSend(void, "orderOut:", .{@as(?*anyopaque, null)});
    window.release();
}

/// A stereo pair of buses and the audio to push through them.
///
/// The host's side of `process`, which this file is entitled to build for the
/// same reason it builds an `NSWindow`: it is playing the host. Deliberately
/// thin, because `plugin.zig`'s own tests cover what `process` does with these
/// and what this half adds is only that the audio thread and the render thread
/// are running at the same time.
///
/// The event lists stay null. `process` reads `frames_count`, `audio_inputs` and
/// `audio_outputs` and nothing else, so a zeroed context is a complete one, and
/// filling in lists nothing reads would be inventing a contract.
const Audio = struct {
    input: [2][smoke_block_frames]f32 = @splat(@splat(0)),
    output: [2][smoke_block_frames]f32 = @splat(@splat(0)),

    input_channels: [2][*c]f32 = @splat(null),
    output_channels: [2][*c]f32 = @splat(null),

    buses: [2]c.clap_audio_buffer_t = undefined,

    /// A ramp per block, so what reaches the ring is checkable in principle and
    /// distinguishable from silence in practice.
    ///
    /// The harness counts the windows that were read and handed across the seam
    /// and does not read any of them back: past `Renderer.upload` the samples are
    /// in a GPU buffer this process cannot see, and the drawable is
    /// `framebufferOnly`, which is a property of the shipping renderer rather
    /// than something to relax for a test. So this proves the path ran, not what
    /// the pixels became. ADR 0013's #38 amendment records why that line is
    /// drawn there.
    fn wire(self: *Audio, block: u32) void {
        for (&self.input, 0..) |*channel, ch| {
            for (channel, 0..) |*sample, i| {
                sample.* = @floatFromInt(block * smoke_block_frames + @as(u32, @intCast(i)) + ch);
            }
        }

        for (&self.input, 0..) |*channel, i| self.input_channels[i] = channel;
        for (&self.output, 0..) |*channel, i| self.output_channels[i] = channel;

        self.buses[0] = std.mem.zeroes(c.clap_audio_buffer_t);
        self.buses[0].data32 = &self.input_channels;
        self.buses[0].channel_count = 2;

        self.buses[1] = std.mem.zeroes(c.clap_audio_buffer_t);
        self.buses[1].data32 = &self.output_channels;
        self.buses[1].channel_count = 2;
    }

    fn context(self: *Audio) c.clap_process_t {
        var ctx = std.mem.zeroes(c.clap_process_t);
        ctx.frames_count = smoke_block_frames;
        ctx.audio_inputs = &self.buses[0];
        ctx.audio_inputs_count = 1;
        ctx.audio_outputs = &self.buses[1];
        ctx.audio_outputs_count = 1;
        return ctx;
    }
};

/// One editor, opened into the host's window and torn down again.
///
/// The sequence a host drives, in the order CLAP specifies it, through the same
/// vtable a DAW reaches.
fn oneCycle(
    factory: *const c.clap_plugin_factory_t,
    parent: *anyopaque,
    tear_down_editor: bool,
) !void {
    const p = factory.create_plugin.?(factory, &smoke_host, plugin.id);
    if (p == null) return error.CreatePluginFailed;

    if (!p.*.init.?(p)) {
        p.*.destroy.?(p);
        return error.PluginInitFailed;
    }
    // Owed from here regardless of what fails below, exactly as a host owes it.
    defer p.*.destroy.?(p);

    // Activated before the editor opens, so the render thread reads a window of
    // audio rather than a window of the silence an unactivated instance holds.
    // The rate is also what `Editor.window` follows, so this is what makes the
    // read a 960-sample one rather than a no-op.
    if (!p.*.activate.?(p, smoke_sample_rate, 1, smoke_block_frames)) return error.ActivateFailed;

    // A host owes `deactivate` before `destroy`, and `plugin.destroy` asserts
    // it. Nine `return error` paths sit between here and the explicit teardown
    // below, and without this unwind every one of them would reach the deferred
    // `destroy` still active: the assertion would fire and a legible
    // `NoGuiExtension` would surface as a panic several frames up. This file
    // plays the host, so it owes the contract on the failing paths too, and
    // this is exactly the "cannot say what it was doing when it died" outcome
    // the header argues against.
    var active = true;
    defer if (active) p.*.deactivate.?(p);

    if (!p.*.start_processing.?(p)) return error.StartProcessingFailed;

    // Registered after `deactivate`'s, so it runs before it. `deactivate`
    // asserts `!processing` for the same reason `destroy` asserts `!active`.
    var processing = true;
    defer if (processing) p.*.stop_processing.?(p);

    var audio: Audio = .{};
    for (0..smoke_blocks) |block| {
        audio.wire(@intCast(block));
        const ctx = audio.context();
        if (p.*.process.?(p, &ctx) != c.CLAP_PROCESS_CONTINUE) return error.ProcessFailed;
    }

    const raw = p.*.get_extension.?(p, &c.CLAP_EXT_GUI) orelse return error.NoGuiExtension;
    const editor: *const c.clap_plugin_gui_t = @ptrCast(@alignCast(raw));

    if (!editor.create.?(p, &c.CLAP_WINDOW_API_COCOA, false)) return error.GuiCreateFailed;

    var width: u32 = 0;
    var height: u32 = 0;
    if (!editor.get_size.?(p, &width, &height)) return error.GetSizeFailed;
    if (width != gui.default_size.width or height != gui.default_size.height) return error.WrongSize;

    // Built through the accessor rather than by naming the union member, which
    // is the whole reason `clap.setCocoaView` exists.
    var window = std.mem.zeroes(c.clap_window_t);
    window.api = &c.CLAP_WINDOW_API_COCOA;
    clap.setCocoaView(&window, parent);

    // The only call here that can fail for reasons outside this process: it
    // acquires the device, compiles the shader, builds the pipeline, and hangs
    // the layer off the view. Its diagnostic arrives through `clap.log` above.
    if (!editor.set_parent.?(p, &window)) return error.SetParentFailed;

    // `show` starts the display link, which draws on CoreVideo's thread rather
    // than on this one. Nothing has been drawn by the time it returns, and
    // waiting for a frame is therefore the whole point rather than a courtesy:
    // before this wait existed, `show` and `hide` ran back to back and the
    // render path was never entered once in a passing run.
    if (!editor.show.?(p)) return error.ShowFailed;

    const instance = plugin.editorOf(p);
    const before = instance.framesPresented();
    try waitForFrames(instance, before + 1);

    // The samples reached the seam, which is a claim `windowsTorn() == 0` cannot
    // make: see `Editor.uploaded`. No extra wait is needed and the ordering is
    // what makes it sound. `Editor.tick` calls `readWindow` before
    // `Renderer.frame` and counts the frame after both, so a `framesPresented`
    // that has moved at all proves a `readWindow` ran to completion. If it ran
    // and uploaded nothing, it returned early.
    if (instance.windowsUploaded() == 0) {
        say("  a frame was presented without a window ever being read", .{});
        return error.NoWindowUploaded;
    }

    // A resize while the loop is running, which is the one interleaving the
    // mailbox exists for and the one that cannot be reached from a unit test.
    // The frames after it went through `Renderer.resize` on the render thread.
    //
    // Audio is driven through the same span, so the producer is running while
    // the consumer reads rather than being stationary from the moment the editor
    // opened. **That is not a test of the ring's memory ordering** (#44): a
    // weakened release store's visibility window is nanoseconds against a window
    // that lags 20 ms. What it buys is that `uploaded` sees changing windows.
    const uploaded_before_resize = instance.windowsUploaded();
    if (!editor.set_size.?(p, 1280, 720)) return error.SetSizeFailed;
    for (0..smoke_blocks) |block| {
        audio.wire(@intCast(smoke_blocks + block));
        const ctx = audio.context();
        if (p.*.process.?(p, &ctx) != c.CLAP_PROCESS_CONTINUE) return error.ProcessFailed;
    }
    try waitForFrames(instance, instance.framesPresented() + 2);

    // A loop that read once and then stopped presents frames forever and draws
    // the same window forever, which by eye is a trace that never moves.
    if (instance.windowsUploaded() <= uploaded_before_resize) {
        say("  uploads stopped after {d} windows", .{uploaded_before_resize});
        return error.UploadsStopped;
    }

    // Down as well as up, because a shrink is where a stale larger surface is
    // most likely to survive unnoticed: everything still fits, so nothing reads
    // out of bounds and nothing looks obviously wrong. Going straight to the
    // minimum also exercises the smallest geometry the seam permits, which is
    // the case the backend's own arithmetic is floored for.
    if (!editor.set_size.?(p, gui.min_size.width, gui.min_size.height)) return error.SetSizeFailed;
    try waitForFrames(instance, instance.framesPresented() + 2);

    // A height no display has, which is what a host actually sends. Dragging an
    // editor's bottom edge above its top makes REAPER 7.78 pass 4294967295,
    // being -1 computed as a signed CGFloat and handed to a `u32` parameter.
    //
    // **Until now that path was exercised only by a human dragging a window.**
    // It runs through `Editor.setSize`, `clampSize` and `clampAxis` exactly as
    // the host's own value does, and what it guards is a surface sized from
    // something other than the clamped result: unguarded, this once reached
    // Metal as a request for a 960x131070 drawable. Under `smoke-leaks` it now
    // runs 400 times rather than never.
    if (!editor.set_size.?(p, 1280, std.math.maxInt(u32))) return error.SetSizeFailed;
    try waitForFrames(instance, instance.framesPresented() + 2);

    // Back to something ordinary, so the reopen below starts from a geometry
    // the rest of this function's expectations were written against.
    if (!editor.set_size.?(p, gui.default_size.width, gui.default_size.height)) return error.SetSizeFailed;
    try waitForFrames(instance, instance.framesPresented() + 2);

    // An editor destroyed and reopened on a still-activated plugin, which is what
    // Logic does on every open of the plugin window because clap-wrapper's AUv2
    // view destroys rather than hides. `Editor.destroy` deliberately keeps
    // `history` and `window`, and until now nothing checked it: clearing either
    // would leave this second editor reading nothing for the rest of the
    // activation, with no symptom but a trace that never moved.
    editor.destroy.?(p);
    if (!editor.create.?(p, &c.CLAP_WINDOW_API_COCOA, false)) return error.GuiCreateFailed;
    if (!editor.set_parent.?(p, &window)) return error.SetParentFailed;
    if (!editor.show.?(p)) return error.ShowFailed;

    // Teardown reset the counters, so this is the second editor's own claim
    // rather than the first one's leftovers.
    try waitForFrames(instance, 1);
    if (instance.windowsUploaded() == 0) {
        say("  a reopened editor presented a frame without reading a window", .{});
        return error.ReopenedEditorStalled;
    }

    // The interleaving this harness exists to reach, and the one the whole
    // lifetime decision in `Instance.history` was made for: the host deactivates
    // while the editor is open and the display link is running, which is what a
    // DAW does when a track is disabled. Nothing here can prove the absence of a
    // use-after-free, but the version that frees the ring on this line is a
    // version this loop can catch, and it runs 400 times under `leaks`.
    p.*.stop_processing.?(p);
    processing = false;
    p.*.deactivate.?(p);
    active = false;

    // The loop has to survive it. A window of zero means the render thread reads
    // nothing and draws what it last held, rather than stopping.
    //
    // One frame first, to absorb a tick that was already inside `readWindow`
    // holding a non-zero `want` when `deactivate`'s release store landed. The
    // count is captured after that, so what follows is about ticks that started
    // on this side of it.
    try waitForFrames(instance, instance.framesPresented() + 1);
    const uploaded_after_deactivate = instance.windowsUploaded();
    try waitForFrames(instance, instance.framesPresented() + 2);

    // The mirror of `LoopRanWhileHidden` below, on the other mechanism: a window
    // of zero has to mean the render thread stops reading, not merely that it
    // reads something harmless.
    if (instance.windowsUploaded() != uploaded_after_deactivate) {
        say("  {d} windows uploaded after deactivate", .{
            instance.windowsUploaded() - uploaded_after_deactivate,
        });
        return error.UploadedWhileDeactivated;
    }

    // Windows the producer lapped mid-copy, and a claim worth something now that
    // `NoWindowUploaded` above proves reads happened at all. The margin is
    // enormous and the audio thread here is this thread, so anything but zero
    // means the read is wrong rather than unlucky.
    if (instance.windowsTorn() != 0) {
        say("  {d} torn windows across the cycle", .{instance.windowsTorn()});
        return error.WindowTorn;
    }

    if (!editor.hide.?(p)) return error.HideFailed;

    // Hiding stops the loop. Asserting that it stayed stopped is what keeps
    // `hide` from silently becoming a no-op, which would cost every host with a
    // closed editor a GPU frame every vsync.
    const at_hide = instance.framesPresented();
    try sleepFor(.fromMilliseconds(50));
    if (instance.framesPresented() != at_hide) return error.LoopRanWhileHidden;

    if (tear_down_editor) editor.destroy.?(p);
}

/// Block until the editor has presented `target` frames, or give up.
///
/// Polls rather than waiting on a condition variable, because the counter is
/// written by CoreVideo's thread and this is a smoke test: a millisecond of
/// latency costs nothing and a second synchronisation primitive is one more
/// thing that can be the reason a run hangs.
fn waitForFrames(editor: *const gui.Editor, target: u64) !void {
    var waited_us: u64 = 0;
    while (editor.framesPresented() < target) {
        if (waited_us >= frame_timeout_us) {
            say("  waited {d}ms for frame {d}, saw {d}", .{
                frame_timeout_us / std.time.us_per_ms,
                target,
                editor.framesPresented(),
            });
            return error.NoFramePresented;
        }
        try sleepFor(.fromMicroseconds(frame_poll_us));
        waited_us += frame_poll_us;
    }
}
