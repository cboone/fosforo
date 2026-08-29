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
//! Three halves, split because their environmental requirements differ:
//!
//!     gpu     a Metal device, no window    runtime shader compilation,
//!                                          pipeline assembly, wrong selectors
//!     trace   a Metal device, no window    what the shader actually drew:
//!                                          the mapping, the rail, the resolve
//!     appkit  a window server and a device view embedding, teardown order,
//!                                          retain and release across cycles
//!
//! The first two are required in CI, because a hosted runner grants a device;
//! the third runs there under `continue-on-error`, because it may grant no
//! window server (ADR 0013).
//!
//! "Half" is now a misnomer three times over and is kept anyway, because
//! `zig build smoke-gpu` and `smoke-appkit` are the names in every document and
//! every CI job here, and renaming a build step to fix a noun would cost more
//! than the noun is worth.
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

const build_info = @import("build_info.zig");
const clap = @import("clap/c.zig");
const gpu = @import("gpu/iface.zig");
const gui = @import("clap/gui.zig");
const io = @import("platform/io.zig");
const measure = @import("gpu/measure.zig");
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

    // Before any half runs, so a CI log or a scrollback says which build produced
    // the result below it. This harness is the one check here that can go red for
    // reasons unrelated to the code (ADR 0013), which makes "which build was that?"
    // a question worth answering without being asked. It sits above the dispatch
    // rather than inside each half, which is why the third one inherited it.
    say("smoke: {s}", .{build_info.marker});

    if (std.mem.eql(u8, half, "gpu")) return report("gpu", gpuHalf());

    if (std.mem.eql(u8, half, "trace")) return report("trace", traceHalf());

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
        \\       fosforo-smoke trace
        \\       fosforo-smoke appkit [cycles]
        \\
        \\  gpu     acquire a device, compile the embedded shader, build the pipeline
        \\  trace   render into a texture and measure what the shader drew
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

/// Needs a device and nothing else, which is what makes it the half that can be
/// required in CI. Runtime shader compilation is precisely what
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
// The trace half
// ---------------------------------------------------------------------------

/// The geometry every case renders at, in whole backing pixels.
///
/// 960x540 because that is what #38 measured, so every number this half prints
/// is directly comparable to the table in that issue and to the rows quoted in
/// `AGENTS.md`. It is also a default editor on a 2x display, which is the
/// geometry a reader is most likely to be looking at.
const trace_width: u32 = 960;
const trace_height: u32 = 540;

/// Energy above which a pixel counts as lit.
///
/// One deposit is the beam's green, which is 1.0, and the accumulation is linear
/// and unclipped, so half of one deposit is an unambiguous floor. This is not
/// `measure-trace`'s 64-of-255: that tool reads an 8-bit picture through a
/// display's colour space, and this reads the float the shader wrote.
const trace_threshold: f32 = 0.5;

/// How many times a frame will be retried when every slot is still in flight.
///
/// Offscreen there is no display link pacing the loop, so a tight run of frames
/// hits the three-deep semaphore on the fourth and `no_frame_slot` is the
/// ordinary case rather than an overload signal: the slot comes back from a
/// completion handler, and the handler runs when the GPU is done. Everything else
/// `frame` can report is a failure here, because none of the machine conditions
/// behind them should arise on a renderer with no compositor and no window.
///
/// **The bound is attempts rather than time, and each attempt yields**, so this
/// is a bound on scheduler turns rather than on a duration. A frame at this
/// geometry completes in well under a millisecond, and a hundred thousand yields
/// is many seconds of slack on a loaded runner. That is the same reasoning
/// `frame_timeout_us` carries: the margin is for a busy machine, and anything
/// approaching this ceiling is the defect rather than the ceiling.
const trace_frame_attempts = 100_000;

/// Renders a window offscreen and holds what came back.
///
/// One instance per case, deliberately. The accumulation persists by design, so a
/// second case run through the same renderer would measure its own trace over the
/// previous one's fade; a fresh renderer starts from the cleared pair
/// `buildAccumulation` guarantees. The cost is a shader compile per case, which
/// is the most expensive thing `init` does, and it buys a measurement with
/// nothing carried into it.
const Probe = struct {
    renderer: gpu.Renderer,
    energy: []f32,
    picture: []u8,

    fn init(energy: []f32, picture: []u8) !Probe {
        var diags: gpu.Diagnostics = .{};
        const renderer = gpu.Renderer.initOffscreen(
            .{ .width = trace_width, .height = trace_height },
            &diags,
        ) catch |err| {
            say("  {s}", .{diags.message()});
            return err;
        };

        return .{ .renderer = renderer, .energy = energy, .picture = picture };
    }

    fn deinit(self: *Probe) void {
        self.renderer.deinit();
    }

    /// Upload a window, drive `frames` frames, and read both surfaces back.
    ///
    /// The frames run on a spawned thread because `upload` and `frame` assert
    /// they are not on the main one, and that assertion is not an obstacle to
    /// work around: it is ADR 0010's rule that the render path is unreachable
    /// from the thread that owns the view lifecycle. Constructing here and
    /// rendering there is the arrangement a host produces, so the harness adopts
    /// it rather than relaxing anything.
    ///
    /// `deposit` is how many of those frames draw the trace. The rest upload an
    /// empty window, which sets `window_len` to zero and makes `traceVertices`
    /// return null, so the trace draw is skipped and the decay runs alone. That
    /// is the shipping behaviour for an editor open on a plugin the host has not
    /// activated, reused rather than simulated.
    fn run(self: *Probe, window: []const f32, frames: u32, deposit: u32) !void {
        var worker: Worker = .{
            .renderer = &self.renderer,
            .window = window,
            .frames = frames,
            .deposit = deposit,
        };

        const thread = try std.Thread.spawn(.{}, Worker.entry, .{&worker});
        thread.join();
        try worker.result;

        try self.renderer.readback(.{ .energy = self.energy, .picture = self.picture });
    }

    fn image(self: *const Probe) measure.Image {
        return .{ .width = trace_width, .height = trace_height, .pixels = self.energy };
    }

    fn pixel(self: *const Probe, x: usize, y: usize) []const u8 {
        const at = (y * trace_width + x) * 4;
        return self.picture[at .. at + 4];
    }
};

const Worker = struct {
    renderer: *gpu.Renderer,
    window: []const f32,
    frames: u32,
    deposit: u32,
    result: anyerror!void = {},

    fn entry(self: *Worker) void {
        self.result = self.drive();
    }

    fn drive(self: *Worker) !void {
        self.renderer.upload(self.window);

        var i: u32 = 0;
        while (i < self.frames) : (i += 1) {
            if (i == self.deposit) self.renderer.upload(&[_]f32{});
            try driveFrame(self.renderer);
        }
    }
};

fn driveFrame(renderer: *gpu.Renderer) !void {
    var attempt: usize = 0;
    while (attempt < trace_frame_attempts) : (attempt += 1) {
        switch (renderer.frame()) {
            .presented => return,
            // The one outcome worth waiting out. Yielding rather than sleeping
            // because reaching for `std.Io` from a thread its single-threaded
            // instance did not spawn is a bigger claim than this needs (ADR
            // 0015), and `std.Thread.sleep` is gone in Zig 0.16. Yielding rather
            // than spinning because a bare `spinLoopHint` loop measured out at
            // roughly a millisecond over a hundred thousand turns, which is the
            // same order as the frame it is waiting for: it failed on the fourth
            // frame of every case, which reads exactly like a completion handler
            // that never fires and was not one.
            .no_frame_slot => std.Thread.yield() catch {},
            else => |outcome| {
                say("  frame reported {s} on a surface with no compositor", .{@tagName(outcome)});
                return error.FrameSkipped;
            },
        }
    }
    return error.FramesNeverPresented;
}

/// Needs a device and no window, on `gpuHalf`'s terms, and answers the question
/// that half cannot: not whether the pipeline assembled, but what it drew.
///
/// Every expectation here is computed in `gpu/measure.zig` from
/// `iface.trace_full_scale` and `iface.trace_rail`, so an assertion compares two
/// independent derivations of the mapping rather than the shader against itself.
/// Vertical tolerances are one backing pixel expressed as a sample value, which
/// is the display's own quantum and therefore cannot absorb any error the display
/// could show; the errors being hunted are one to three orders of magnitude
/// wider. Where an assertion can be exact it is exact, and the saturation and
/// period checks are both.
fn traceHalf() !void {
    say("  rendering shaders/scope.metal into a {d}x{d} texture and measuring it", .{
        trace_width,
        trace_height,
    });

    const allocator = std.heap.c_allocator;
    const pixels = @as(usize, trace_width) * trace_height;

    const energy = try allocator.alloc(f32, pixels * 4);
    defer allocator.free(energy);

    const picture = try allocator.alloc(u8, pixels * 4);
    defer allocator.free(picture);

    const window = try allocator.alloc(f32, trace_width);
    defer allocator.free(window);

    try checkSilence(energy, picture, window);
    try checkLevels(energy, picture, window);
    try checkSaturation(energy, picture, window);
    try checkSymmetry(energy, picture, window);
    try checkHorizontalMapping(energy, picture);
    try checkPeriods(energy, picture, window);
    try checkBeamIsOneColour(energy, picture, window);
    try checkResolve(energy, picture, window);
    try checkDecay(energy, picture, window);
}

/// A window of zeros draws one flat line through the centre.
fn checkSilence(energy: []f32, picture: []u8, window: []f32) !void {
    var probe = try Probe.init(energy, picture);
    defer probe.deinit();

    measure.constant(window, 0.0);
    try probe.run(window, 1, 1);

    const image = probe.image();
    if (!image.complete()) return error.ReadbackTruncated;

    const lit = measure.litColumns(image, trace_threshold);
    if (lit != trace_width) {
        say("  silence lit {d} of {d} columns", .{ lit, trace_width });
        return error.TraceNotDrawn;
    }

    const seen = measure.extremes(image, trace_threshold) orelse return error.TraceNotDrawn;

    // One row of slack, and it is the centre line rather than the signal. At an
    // even height the centre falls on an exact pixel boundary, so both candidate
    // rows exist and the rasterizer picks one; what would be worth investigating
    // is the line *flickering* between them, which is the tie-break going
    // unstable rather than this.
    if (seen.bottom - seen.top > 1) {
        say("  silence spans rows {d} to {d}", .{ seen.top, seen.bottom });
        return error.TraceNotFlat;
    }

    const implied = measure.impliedSample(seen.top, trace_height);
    say("  silence: row {d}, implying a sample of {d:.5}", .{ seen.top, implied });

    if (@abs(implied) > measure.pixelTolerance(trace_height)) return error.CentreLineWrong;
}

/// Each level lands where the constants say, inside one pixel.
fn checkLevels(energy: []f32, picture: []u8, window: []f32) !void {
    // Below the rail's threshold of 1.0889 throughout, so every one of these is
    // a test of the mapping rather than of the clamp. 1.05 is the last level
    // before clamping starts and is here to hold that line: if it ever reads as
    // railed, the margin between the two constants has gone.
    for ([_]f32{ 0.25, 0.5, 1.0, 1.05, -0.25, -0.5, -1.0 }) |level| {
        var probe = try Probe.init(energy, picture);
        defer probe.deinit();

        measure.constant(window, level);
        try probe.run(window, 1, 1);

        const image = probe.image();
        const seen = measure.extremes(image, trace_threshold) orelse return error.TraceNotDrawn;

        const implied = measure.impliedSample(seen.top, trace_height);
        const off = @abs(implied - level);
        say("  level {d: >6.3}: row {d: >3}, implying {d: >8.5}, off by {d:.5}", .{
            level,
            seen.top,
            implied,
            off,
        });

        if (off > measure.pixelTolerance(trace_height)) return error.LevelMisplaced;
    }
}

/// Every level at or above the rail lands on exactly the same row.
fn checkSaturation(energy: []f32, picture: []u8, window: []f32) !void {
    var railed: ?usize = null;

    // 1.111 is `1 / trace_full_scale`, where the trace would reach the drawable's
    // edge if nothing clamped. It is unreachable because `trace_rail` clamps
    // first, and everything from there up must be pixel-identical: that
    // saturation is the whole of what ADR 0017 means by refusing to say how far
    // over a signal is. Asserted from just above the 1.0889 threshold rather than
    // at it, because an equality exactly on the boundary would be a test of f32
    // rounding.
    for ([_]f32{ 1.111, 2.0, 8.0, 1000.0 }) |over| {
        var probe = try Probe.init(energy, picture);
        defer probe.deinit();

        measure.constant(window, over);
        try probe.run(window, 1, 1);

        const seen = measure.extremes(probe.image(), trace_threshold) orelse
            return error.TraceNotDrawn;

        if (railed) |first| {
            if (seen.top != first) {
                say("  {d} railed on row {d}, not {d}", .{ over, seen.top, first });
                return error.RailNotSaturated;
            }
        } else {
            railed = seen.top;
            const expected = measure.railRow(trace_height);
            say("  rail: row {d}, expected {d:.1}", .{ seen.top, expected });
            if (@abs(@as(f32, @floatFromInt(seen.top)) - expected) > 1.0) return error.RailMisplaced;
        }
    }
}

/// Positive is up, negative is down, and by the same distance.
fn checkSymmetry(energy: []f32, picture: []u8, window: []f32) !void {
    var rows: [2]f32 = undefined;

    for ([_]f32{ 0.5, -0.5 }, 0..) |level, i| {
        var probe = try Probe.init(energy, picture);
        defer probe.deinit();

        measure.constant(window, level);
        try probe.run(window, 1, 1);

        const seen = measure.extremes(probe.image(), trace_threshold) orelse
            return error.TraceNotDrawn;
        rows[i] = @floatFromInt(seen.top);
    }

    const centre = measure.centreRow(trace_height);
    const above = centre - rows[0];
    const below = rows[1] - centre;
    say("  symmetry: +0.5 sits {d:.1} above centre, -0.5 sits {d:.1} below", .{ above, below });

    // A Y flip would put both on the same side; an asymmetric clamp would leave
    // them at different distances. One pixel of slack covers the tie-break at the
    // centre and nothing else.
    if (above <= 0 or below <= 0) return error.TraceInverted;
    if (@abs(above - below) > 1.0) return error.TraceAsymmetric;
}

/// The first and last samples land on the drawable's edges.
fn checkHorizontalMapping(energy: []f32, picture: []u8) !void {
    var probe = try Probe.init(energy, picture);
    defer probe.deinit();

    // Three samples, because that is where the two candidate divisors are
    // furthest apart. `2i / (n - 1)` puts the last vertex on the right edge;
    // `2i / n` puts it two thirds of the way across, leaving 320 columns dark. No
    // tolerance carries that argument, which is the point of choosing a short
    // window over a full one, where the same error is a single column.
    var window = [_]f32{ -1.0, 0.0, 1.0 };
    try probe.run(&window, 1, 1);

    const image = probe.image();
    const span = measure.litSpan(image, trace_threshold) orelse return error.TraceNotDrawn;
    say("  three samples span columns {d} to {d} of {d}", .{ span.first, span.last, trace_width - 1 });

    // One column of slack at each end, for the diamond-exit rule: a line strip's
    // final endpoint need not light the pixel it lands on. Against an error of a
    // third of the width, one column is not a tolerance that could hide anything.
    if (span.first > 1) return error.TraceStartsLate;
    if (span.last < trace_width - 2) return error.TraceEndsEarly;

    // And the vertical, which the same window checks for free: the ramp runs from
    // -1 at the left to +1 at the right, so the corners are the extremes.
    const left = measure.topRow(image, span.first, trace_threshold).?;
    const right = measure.topRow(image, span.last, trace_threshold).?;
    if (right >= left) {
        say("  the ramp does not rise: column {d} is row {d}, column {d} is row {d}", .{
            span.first,
            left,
            span.last,
            right,
        });
        return error.TraceInverted;
    }
}

/// A sine of k cycles shows exactly k periods.
fn checkPeriods(energy: []f32, picture: []u8, window: []f32) !void {
    var doubling: [3]usize = undefined;

    for ([_]usize{ 1, 2, 4, 5, 8, 20 }) |cycles| {
        var probe = try Probe.init(energy, picture);
        defer probe.deinit();

        measure.sine(window, @floatFromInt(cycles), 0.8);
        try probe.run(window, 1, 1);

        const counted = measure.periods(probe.image(), trace_threshold);
        say("  {d: >2} cycles in, {d: >2} periods counted", .{ cycles, counted });

        // Strict equality. #38's first counter was off by exactly one at every
        // frequency and a ±1 tolerance reported all six as correct, which is what
        // "a tolerance wide enough to absorb a systematic error is a tolerance
        // that hides one" was written about.
        if (counted != cycles) return error.PeriodMiscounted;

        switch (cycles) {
            2 => doubling[0] = counted,
            4 => doubling[1] = counted,
            8 => doubling[2] = counted,
            else => {},
        }
    }

    // The ratio form, which is robust to phase, to the `n - 1` quibble, and to
    // miscounting a partial period at an edge in a way an absolute count is not.
    if (doubling[1] != doubling[0] * 2 or doubling[2] != doubling[1] * 2) {
        return error.PeriodRatioWrong;
    }
}

/// Every deposit is the same colour, so accumulated energy lies on one ray.
fn checkBeamIsOneColour(energy: []f32, picture: []u8, window: []f32) !void {
    var probe = try Probe.init(energy, picture);
    defer probe.deinit();

    measure.sine(window, 4.0, 0.8);
    try probe.run(window, 1, 1);

    const image = probe.image();

    // The premise `scripts/measure-trace`'s guard rests on and which nothing has
    // ever checked: every deposit is one colour and the decay multiplies the
    // whole vector, so a lit pixel is `c * beam` for some scalar `c` and green
    // predicts red and blue exactly. Taken from the brightest pixel rather than
    // from a restated literal, because the colour is a look constant #60 deletes
    // and a fourth copy of it here would have nothing tying it back.
    const peak_green = measure.maxChannel(image, 1);
    if (peak_green <= trace_threshold) return error.TraceNotDrawn;

    var reference: ?[2]f32 = null;
    var worst: f32 = 0;

    var y: usize = 0;
    while (y < trace_height) : (y += 1) {
        var x: usize = 0;
        while (x < trace_width) : (x += 1) {
            const g = image.channel(x, y, 1);
            if (g <= trace_threshold) continue;

            const ratio = [2]f32{ image.channel(x, y, 0) / g, image.channel(x, y, 2) / g };
            if (reference) |want| {
                worst = @max(worst, @abs(ratio[0] - want[0]));
                worst = @max(worst, @abs(ratio[1] - want[1]));
            } else {
                reference = ratio;
            }
        }
    }

    const want = reference orelse return error.TraceNotDrawn;
    say("  beam ray: red/green {d:.4}, blue/green {d:.4}, worst deviation {d:.5}", .{
        want[0],
        want[1],
        worst,
    });

    // Half-float precision, not a rendering tolerance: `RGBA16Float` holds about
    // three decimal digits, and both channels are compared after a division.
    if (worst > 1e-3) return error.BeamNotOneColour;

    // Green-dominant, which is what makes the green channel the trace's readout
    // and what `measure-trace` isolates on. #60 ends this along with the colour.
    if (want[0] >= 1.0 or want[1] >= 1.0) return error.BeamNotGreenDominant;
}

/// The resolve adds energy to a background at unit gain, and nothing else.
fn checkResolve(energy: []f32, picture: []u8, window: []f32) !void {
    var probe = try Probe.init(energy, picture);
    defer probe.deinit();

    measure.sine(window, 3.0, 0.8);
    try probe.run(window, 1, 1);

    const image = probe.image();

    // The background, read off the picture rather than restated from the shader.
    // Any pixel the beam missed carries it; the top-left corner is the safest,
    // since a sine at this amplitude never reaches the corners.
    const background = probe.pixel(0, 0);
    say("  background: RGBA({d}, {d}, {d}, {d})", .{
        background[0],
        background[1],
        background[2],
        background[3],
    });

    // The structural premise `find_drawable` uses to locate a drawable inside a
    // window capture: a dark ground with blue leading red and green, and red and
    // green equal. The exact bytes are not asserted here, because that would be a
    // fourth restatement of a literal already tied between the shader and
    // `scripts/measure-trace` by a test in the renderer, with nothing tying this
    // copy back. Printing them is what makes a change visible.
    if (background[0] != background[1]) return error.BackgroundNotNeutral;
    if (background[2] <= background[0]) return error.BackgroundNotBlueLeading;
    if (background[0] >= 16) return error.BackgroundNotDark;
    if (background[3] != 255) return error.BackgroundNotOpaque;

    var worst: i32 = 0;
    var lit: usize = 0;

    var y: usize = 0;
    while (y < trace_height) : (y += 1) {
        var x: usize = 0;
        while (x < trace_width) : (x += 1) {
            const got = probe.pixel(x, y);
            if (image.channel(x, y, 1) > trace_threshold) lit += 1;

            for (0..3) |channel| {
                const want = resolved(background[channel], image.channel(x, y, channel));
                const off = @as(i32, got[channel]) - @as(i32, want);
                if (@abs(off) > @abs(worst)) worst = off;
            }
        }
    }

    say("  resolve: {d} lit pixels, worst channel off by {d}", .{ lit, worst });
    if (lit == 0) return error.TraceNotDrawn;

    // **This is the assertion #55 would have failed.** That issue shipped a
    // resolve gain of `1 - decay`, which divides a moving trace by ten and
    // renders a sine as a black display; it passed 160 unit tests, both smoke
    // halves, the leak check, `clap-validator` and the validation layer, and was
    // found by eye. Comparing the two readbacks against each other is what makes
    // it visible, and it assumes nothing about how many segments covered a pixel,
    // which is the assumption a check against the beam's literal would need.
    //
    // One byte level of slack, for the rounding between a float the shader
    // computed and the unorm the format stores. Against a gain of a tenth, whole
    // channels move by a hundred levels.
    if (@abs(worst) > 1) return error.ResolveNotAnAdd;
}

/// What the resolve should make of one channel: the background plus the energy,
/// clipped by the format and quantized once.
fn resolved(background: u8, energy: f32) u8 {
    const linear = @as(f32, @floatFromInt(background)) / 255.0 + energy;
    return @intFromFloat(@round(std.math.clamp(linear, 0.0, 1.0) * 255.0));
}

/// The phosphor dims by the decay factor once per frame.
fn checkDecay(energy: []f32, picture: []u8, window: []f32) !void {
    var first: f32 = 0;

    for ([_]u32{ 1, 2, 3, 4, 5 }) |frames| {
        var probe = try Probe.init(energy, picture);
        defer probe.deinit();

        // One depositing frame, then frames that decay alone. Fresh renderers
        // rather than one driven further, so each measurement starts from the
        // cleared pair rather than from the previous case's fade.
        measure.constant(window, 0.5);
        try probe.run(window, frames, 1);

        const peak = measure.maxChannel(probe.image(), 1);
        if (frames == 1) {
            first = peak;
            say("  decay: one deposit peaks at {d:.4}", .{peak});

            // Reported rather than asserted, and deliberately. Whether a line
            // strip's shared vertices deposit twice under Metal's diamond-exit
            // rule is not documented anywhere this project can cite, so the
            // number is a finding rather than a claim: one deposit of the beam's
            // green would be 1.0, and anything above that is coverage counted
            // more than once.
            continue;
        }

        const quiet = frames - 1;
        const ratio = peak / first;
        const want = std.math.pow(f32, 0.90, @floatFromInt(quiet));
        say("  decay: after {d} quiet frames, {d:.4} of the deposit, expected {d:.4}", .{
            quiet,
            ratio,
            want,
        });

        // Two percent, which is half-float precision compounded over five frames
        // rather than a rendering tolerance. A decay of 1.0 would hold the ratio
        // at 1.0 and a decay applied twice would put it at 0.81 per frame; both
        // are tens of times outside this.
        if (@abs(ratio - want) > 0.02 * want) return error.DecayWrong;
    }
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
/// runner may refuse, so CI runs this without gating on it.
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
