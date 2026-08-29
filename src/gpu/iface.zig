//! The renderer seam.
//!
//! ADR 0005 forbids Metal types above this file, with one backend behind it and
//! no second one planned. That is a hygiene decision rather than a portability
//! one: it converts an eventual port from "excavate Metal calls out of a
//! renderer they have grown through" into "write a second backend against a
//! known handful of operations".
//!
//! The interface is shaped to this project's algorithm rather than to graphics
//! in general, which is what keeps it small. It also stays honest about what
//! exists: there is no texture creation here, because nothing calls it yet.
//! Operations arrive with the phase that has a caller for them, which is how
//! `resize` arrived: the display link gave the backend a second thread, and a
//! resizable editor gave that thread something to service. `upload` arrived the
//! same way: the history buffer gave the render thread something to read, and
//! the in-flight semaphore gave the buffers it fills a slot discipline that was
//! already in place before there was anything to put in them.

const std = @import("std");

/// Pixels, in the drawable's own terms rather than the window's. The caller
/// works in logical points and hands the scale factor over separately, because
/// only the backend knows what it wants to do with it.
pub const Size = struct { width: u32, height: u32 };

/// The native view the backend attaches its drawable surface to.
///
/// Deliberately opaque. On macOS this is an `NSView`, and what the backend
/// hangs off it is the backend's business: naming `CAMetalLayer` here would be
/// exactly the leak ADR 0005 exists to prevent, since a Metal layer is a Metal
/// type wearing QuartzCore's coat.
pub const NativeView = *anyopaque;

/// The longest window `upload` will take, in samples.
///
/// A bound rather than a size: a caller hands over whatever window it has and
/// this is where the backend stops copying. It exists because the buffers behind
/// the seam are allocated once, at `init`, and something has to say how large
/// once is.
///
/// Eight thousand one hundred and ninety-two covers a 20 ms window through
/// 409.6 kHz. Above that the window shortens rather than the rate being refused,
/// which is the right failure for a rate no audio device offers: a scope showing
/// 19 ms instead of 20 is a scope, and a plugin that will not load is not.
///
/// 32 KiB per buffer, and the backend holds one per frame in flight.
pub const max_window_samples: usize = 8192;

/// Where a sample of ±1.0 lands, as a fraction of the drawable's half-height.
///
/// **The vertical axis is absolute and the display never rescales itself to the
/// signal** (ADR 0017). This is the reference that statement is about: full scale
/// is ±1.0, it draws 5% of the height in from each edge, and nothing anywhere
/// adjusts it to fit what is playing.
///
/// The margin is the point rather than a courtesy. Full scale on the drawable's
/// exact edges leaves a peak at 0 dBFS pixel-identical to one at +6, because both
/// are at the top; the strip between this and `trace_rail` is what makes "at full
/// scale" and "over" two different pictures. It is worth +0.74 dB of headroom,
/// since the rail is reached at `trace_rail / trace_full_scale`, or 1.0889, which
/// also means phase 3's bandlimited reconstruction will draw the smaller half of
/// a typical 0.5 to 1.5 dBTP intersample overshoot inside the margin rather than
/// against the rail.
///
/// Not `1 / trace_full_scale`, which is 1.111 and +0.92 dB. That is where the
/// trace would reach the drawable's edge if nothing clamped it, and it is
/// unreachable precisely because `trace_rail` clamps first.
///
/// The consequence to know before reading a quiet signal: one backing pixel of
/// excursion needs `1 / (trace_full_scale * height / 2)`, which is about
/// -54 dBFS at the default editor on a 2x display and about -42 dBFS at the
/// smallest editor on a 1x one. Below that a sine reads as flat, and that is
/// arithmetic rather than a defect.
///
/// Restated in `scripts/measure-trace`, which inverts this mapping to report a
/// sample value from a row in a screenshot, and tied back here by a test in
/// `src/gpu/metal/renderer.zig` that reads the script as text.
pub const trace_full_scale: f32 = 0.9;

/// How far a sample may travel from the centre, whatever its value.
///
/// A sample beyond full scale is clamped here rather than left to the rasterizer,
/// and the rail sits inside the drawable rather than on its edge. Both halves are
/// load-bearing and neither is obvious.
///
/// Clamping, because clipping a line strip does not remove the trace, it removes
/// the peaks: segments crossing the boundary still draw up to it and segments
/// wholly beyond it do not, so an over-scale signal would read as a *quieter*
/// signal with gaps. A scope may say "at or above full scale" and may not say
/// "quieter than it is".
///
/// Inside the edge, because a one-pixel line whose centre lands on the drawable's
/// boundary has half its coverage diamond off-screen and may rasterize to
/// nothing, which would make a railed signal read as an absent one. One percent
/// is safe at every geometry `gui.clampSize` permits: the smallest editor is 270
/// points tall, so at a scale of 1 this leaves `(1 - 0.98) * 135`, or 2.7 backing
/// pixels. `src/clap/gui.zig` holds the test, because that is the file that knows
/// the minimum.
///
/// Restated in `scripts/measure-trace`, which reports the rail's rows so a peak
/// sitting on one can be read as "at or above" rather than as a value, and tied
/// back here alongside `trace_full_scale`.
pub const trace_rail: f32 = 0.98;

/// Every way starting a renderer can fail. Each is a real machine condition
/// rather than a programming error, so each is reported rather than asserted.
pub const Error = error{
    /// No usable GPU. Covers both a device that could not be obtained at all and
    /// one that was obtained but would not hand out a command queue, since a
    /// caller can do nothing different about the two. `Diagnostics` carries
    /// which it was.
    ///
    /// Worth checking first when a host that sandboxes plugins fails where
    /// another does not.
    NoDevice,
    /// The shader source did not compile. See `Diagnostics` for what went wrong.
    ShaderCompilationFailed,
    /// The shaders compiled but could not be assembled into a pipeline state.
    PipelineCreationFailed,
    /// A drawable surface could not be created or attached to the view.
    SurfaceCreationFailed,
    /// A buffer could not be allocated. Memory pressure rather than anything
    /// about this machine's GPU, and the only member here that a second run
    /// might not reproduce.
    ///
    /// Two buffers now answer to this and they are not the same shape. The
    /// per-frame window buffers are a fixed 32 KiB each, sized from
    /// `max_window_samples`, and nothing a user does makes them larger. The
    /// readback staging buffer `readback` blits into scales with the geometry
    /// `initOffscreen` was given, so it fails the way `TextureAllocationFailed`
    /// does; it is here rather than there because what failed is a buffer, and
    /// keeping the two sets sorted by resource kind is what makes either name
    /// useful when one turns up in a log.
    BufferAllocationFailed,
    /// The accumulation textures could not be allocated.
    ///
    /// Separate from `BufferAllocationFailed` rather than folded into it,
    /// because the two describe failures of different shapes. The window
    /// buffers are a fixed 32 KiB each, sized from a constant this file
    /// publishes, and nothing a user does can make them larger. These scale
    /// with the editor's geometry, at several megabytes for an ordinary window
    /// and considerably more for a large one, so this is the first failure here
    /// that someone can provoke by dragging a window edge.
    ///
    /// The offscreen colour target `initOffscreen` builds answers to this too,
    /// and it is worth saying why it is not `SurfaceCreationFailed`, which would
    /// read as the symmetric choice since that target *is* that renderer's
    /// surface. What failed decides the name rather than what the thing is for:
    /// it is a texture sized from the caller's geometry, reached from `resize`
    /// on that path as well, which is this member's own description.
    /// `SurfaceCreationFailed` stays the layer's, where nothing is allocated.
    TextureAllocationFailed,
    /// `readback` was asked for the pixels of a renderer attached to a view.
    ///
    /// A real condition rather than a programming error, and the distinction is
    /// the whole reason this member exists rather than an assertion. A renderer
    /// built by `init` presents into a drawable the backend deliberately makes
    /// write-only, and ADR 0013 refuses to relax that so a check can run: the
    /// storage mode of the shipping surface is not something a test may change.
    /// So there is genuinely nothing to read here, and saying so is the seam
    /// declining rather than the renderer being reconfigured.
    ///
    /// `initOffscreen` is the constructor whose renderers answer this.
    SurfaceNotReadable,
};

/// What became of one tick.
///
/// `frame` reports this rather than returning nothing, because a skipped frame
/// and a presented one are indistinguishable from outside and the difference is
/// the whole question a smoke test is asking. ADR 0013 records the gap this
/// closes: a build in which `nextDrawable` returned nil on every call drew
/// nothing, and passed every check this project had.
///
/// Not an error set. Every value but the first is a normal outcome under load
/// rather than a fault, and modelling them as errors would push a caller toward
/// escalating something whose only correct response is to let the tick go.
pub const Outcome = enum {
    /// Encoded, presented, and committed.
    presented,

    /// The compositor was holding every drawable. Normal under load, and the
    /// reason the render loop must not treat a skip as a failure.
    no_drawable,

    /// Every frame slot was still in flight on the GPU, so this tick was
    /// dropped rather than waited out.
    ///
    /// Distinct from `no_drawable` because it means something different about
    /// the machine: the compositor is holding drawables in one case and the GPU
    /// has not finished with them in the other. A run of these is the signal
    /// that the render is too expensive for the display's refresh rate, which
    /// is worth telling apart from a busy compositor when phase 3 makes that a
    /// live question.
    no_frame_slot,

    /// The command queue would not produce a buffer, which is memory pressure
    /// or device loss rather than anything this frame did.
    no_command_buffer,

    /// The buffer would not produce an encoder, on the same reasoning.
    no_encoder,

    /// The backend has no accumulation to draw into, so the tick was dropped.
    ///
    /// The one skip here that is about this plugin's own resources rather than
    /// about the machine being busy, and the only one that persists: the others
    /// describe a moment, this describes a state that lasts until a resize
    /// succeeds in rebuilding what a previous one could not. A run of these
    /// means an allocation failed, which at ordinary editor sizes means the
    /// machine is out of GPU memory rather than that anything here is wrong.
    no_accumulation,

    /// Whether this tick put anything on screen. The distinctions above are for
    /// a human reading a log; this is what a caller counts.
    pub fn drew(self: Outcome) bool {
        return self == .presented;
    }
};

/// A fixed buffer the backend writes a human-readable line into.
///
/// This exists so a Metal compiler diagnostic can reach the host's log without
/// the gpu layer importing the log or the clap layer importing Metal. Both
/// directions would be a layering violation, and the message is the difference
/// between "the editor did not open" and a file and line number.
///
/// Every caller but one reads this only after a failure. `probe` is the
/// exception and fills it in on success too, with what it found, because a
/// smoke test reporting "ok" without naming the device it acquired is asserting
/// something nobody can check. So the buffer carries a description rather than
/// strictly a failure, and `message()` staying empty-when-unset is what lets
/// both kinds of caller read it unconditionally.
///
/// Fixed rather than allocated: the failure paths this serves are the ones
/// where the least should be assumed about the process, and truncating a
/// compiler error still leaves the first and most useful line intact.
pub const Diagnostics = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    /// Truncates rather than failing. A clipped diagnostic beats a missing one.
    pub fn set(self: *Diagnostics, text: []const u8) void {
        self.len = @min(text.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], text[0..self.len]);
    }

    /// Empty when nothing was recorded, so a caller can log it unconditionally.
    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Where an offscreen render's pixels land.
///
/// Two buffers rather than one, because they answer different questions and one
/// cannot be derived from the other. `energy` is what the beam deposited, linear
/// and unclipped, which is the only form in which the geometry can be measured
/// once #58 makes brightness a function of segment length. `picture` is what a
/// viewer would see, quantized and clipped, which is the only form in which the
/// resolve's own arithmetic can be checked at all. #55 shipped a resolve that
/// divided every moving trace by ten; a check reading `energy` alone would have
/// passed it, since the accumulation was correct and only the read of it was not.
///
/// Both are plain scalars in this file's own vocabulary. Nothing here names a
/// texture, a pixel format, or a component order: the backend swizzles out of
/// whatever its drawable uses, so a caller counts from red.
///
/// Sized `width * height * 4` by the caller, from the `Size` it handed
/// `initOffscreen`. Short buffers are filled as far as they go rather than
/// refused, on `upload`'s precedent and for its reason: this is the boundary
/// declining to trust a length, in the one direction where being wrong would be
/// an overrun.
pub const Readback = struct {
    /// Linear RGBA from the accumulation, four floats per pixel, row-major from
    /// the top-left. Not clipped: where the beam crosses its own path this runs
    /// past 1.0, which is what the accumulation is floating point for.
    energy: []f32,
    /// The resolved picture, four bytes per pixel, RGBA, row-major from the
    /// top-left. Alpha is whatever the resolve wrote.
    picture: []u8,
};

/// The one backend. Aliased rather than dispatched through a vtable, because
/// paying for indirection with a single implementation would buy nothing that
/// the comptime check below does not buy for free.
///
/// **Ten operations.** Five of them the editor drives: `init`, `deinit`,
/// `resize`, `upload`, and `frame`. The rest are described below in the order
/// they arrived, which is what the ordinals are for.
///
/// This opening count has now been wrong twice, in the same direction and for the
/// same reason. It undercounted by one before `upload` arrived, having missed
/// `resize`; it then said "six" while the paragraphs under it went on to a tenth,
/// because each new operation was appended without anyone re-reading the first
/// line. The comptime block below is the list that cannot drift; this is prose
/// that has to be kept beside it by hand, and the failure mode is not that it
/// looks stale but that it stays internally consistent while being wrong.
///
/// `liveWindowBuffers` and `liveAccumulationTextures` are the seventh and
/// eighth, and are the same kind of thing as `probe`: questions about the
/// backend rather than instructions to it. Both exist because the leak check
/// was measured and cannot see the resource in question, while it catches a
/// leaked command queue in the same run, so the backend has to answer for those
/// two itself.
///
/// They are two operations rather than one because they count different things
/// and were measured separately, which is the rule ADR 0013 set after the first
/// of them: a resource that is not a buffer gets its own planted leak before
/// anything is assumed about it. The second measurement found a worse answer
/// than the first, since peak RSS catches a leaked window buffer and does not
/// move at all for a leaked texture.
///
/// `probe` is the sixth, and it has one caller: `src/smoke.zig`. It does
/// everything `init` does except attach a surface, which makes it the half of
/// starting a renderer that needs no window and can therefore run unattended.
/// That is a real backend capability rather than a testing hook. "Can this
/// machine start this backend at all, and if not, why" is a question any second
/// backend would have to answer too, and answering it here is what lets a
/// runtime shader compilation failure be caught by CI rather than by whoever
/// next opens the editor.
///
/// `initOffscreen` and `readback` are the ninth and tenth, and they are a pair:
/// the first is a second constructor, the second is only answerable by what it
/// builds. Together they say "render into a surface you own, and hand the pixels
/// back", which is `probe`'s kind of thing rather than a hook — a second backend
/// would have to answer it, and neither names anything Metal owns.
///
/// The distinction they turn on is worth stating here, because it is the one
/// ADR 0013 refused to blur. A renderer built by `init` presents into a
/// drawable, and that drawable is write-only by choice; relaxing it so a check
/// could read a frame would change the shipping renderer in every host on every
/// frame. A renderer built by `initOffscreen` presents into nothing and draws
/// into a texture it allocated itself, which is a different surface rather than
/// the same surface reconfigured. What the two share is everything in between:
/// the same pipelines, the same uniforms, the same bindings, the same `upload`,
/// and the same `frame`, which branches only where it acquires a colour
/// attachment and whether it presents one. That is `probe`'s discipline of
/// sharing rather than paraphrasing, applied to a frame instead of a pipeline,
/// and it is what makes a result here a statement about the shipping path.
///
/// The one honest difference is the `Size`. `init` takes logical points and a
/// scale factor because a view has one; `initOffscreen` takes whole backing
/// pixels, because there is no view to read a scale from and inventing one would
/// put a rounding between a caller and the geometry it is measuring.
pub const Renderer = @import("metal/renderer.zig").Renderer;

// ADR 0005 asks a reviewer to treat a Metal type named above this seam as a
// defect. This is that review, mechanized. Every parameter and return type
// below is drawn from this file's own vocabulary, so a backend that started
// taking an `objc.Object` or handing back an `MTLDevice` stops compiling
// instead of quietly passing.
comptime {
    assertSignature("init", @TypeOf(Renderer.init), fn (NativeView, Size, f64, *Diagnostics) Error!Renderer);
    assertSignature("deinit", @TypeOf(Renderer.deinit), fn (*Renderer) void);
    // Both `[render-thread]`, and the reason `Size` is in this file's
    // vocabulary rather than the backend's: a resize crosses from the host's
    // main thread to the render thread through a mailbox above this seam, so
    // the size has to be expressible without naming anything Metal owns.
    assertSignature("resize", @TypeOf(Renderer.resize), fn (*Renderer, Size, f64) void);
    // `[render-thread]` as well, and the reason its parameter is a plain slice
    // of samples: what crosses here is the signal, not the geometry drawn from
    // it. A vertex type would be this seam describing a line strip, which is one
    // phase's way of drawing a trace rather than the trace itself, and phase 3
    // replaces it with oriented quads. `[]const f32` names nothing Metal owns
    // and needs nothing added to this file's vocabulary.
    //
    // #38 is the phase that could have falsified that and did not. The trace is
    // drawn with no `MTLVertexDescriptor` at all, from a plain array indexed by
    // `[[vertex_id]]`, so the claim held all the way down to the GPU rather than
    // only as far as this line.
    assertSignature("upload", @TypeOf(Renderer.upload), fn (*Renderer, []const f32) void);
    assertSignature("frame", @TypeOf(Renderer.frame), fn (*Renderer) Outcome);
    assertSignature("probe", @TypeOf(Renderer.probe), fn (*Diagnostics) Error!void);
    // `[main-thread]`, and its `Size` is in whole backing pixels rather than the
    // points `init` takes. There is no view here whose scale factor could be
    // read, and a nominal one would make every measurement taken through this
    // constructor a measurement of `backingPixels`' rounding as much as of the
    // shader. That arithmetic is tested where it lives.
    assertSignature("initOffscreen", @TypeOf(Renderer.initOffscreen), fn (Size, *Diagnostics) Error!Renderer);
    // `[main-thread]`. Takes the buffers rather than returning them, so the seam
    // allocates nothing and the caller owns the lifetime, and takes them as
    // scalars so nothing about a texture or a pixel format crosses.
    assertSignature("readback", @TypeOf(Renderer.readback), fn (*Renderer, Readback) Error!void);
    // `[thread-safe]`, and a plain count because that is all a caller can do
    // anything with: naming what is being counted would name a Metal type.
    assertSignature("liveWindowBuffers", @TypeOf(Renderer.liveWindowBuffers), fn () usize);
    assertSignature("liveAccumulationTextures", @TypeOf(Renderer.liveAccumulationTextures), fn () usize);
}

fn assertSignature(comptime name: []const u8, comptime Found: type, comptime Want: type) void {
    if (Found != Want) @compileError(
        "the renderer backend's `" ++ name ++ "` is " ++ @typeName(Found) ++
            ", but the seam declares " ++ @typeName(Want),
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Nothing here constructs a `Renderer`. Doing so would acquire a GPU, and
// `zig build test` runs in CI on a runner whose Metal support is not something
// this project should depend on (ADR 0009). The backend is verified by running
// the plugin in a host; what is testable without one is tested here.

test "only a presented frame counts as having drawn" {
    // The distinctions between the skips are for a human reading a log; this is
    // what `Editor` counts, and what `src/smoke.zig` asserts against. A skip
    // miscounted as a draw would let a build that renders nothing pass the one
    // check written to catch exactly that (ADR 0013).
    try testing.expect(Outcome.presented.drew());

    for ([_]Outcome{
        .no_drawable,
        .no_frame_slot,
        .no_command_buffer,
        .no_encoder,
        .no_accumulation,
    }) |skipped| {
        try testing.expect(!skipped.drew());
    }
}

test "every outcome is either a draw or a skip" {
    // Walks the enum rather than listing it, so a value added later has to be
    // classified here instead of silently defaulting to one side.
    var drew: usize = 0;
    inline for (@typeInfo(Outcome).@"enum".fields) |field| {
        if (@field(Outcome, field.name).drew()) drew += 1;
    }
    try testing.expectEqual(@as(usize, 1), drew);
}

test "diagnostics start empty and can be read unconditionally" {
    const diags: Diagnostics = .{};
    try testing.expectEqualStrings("", diags.message());
}

test "a diagnostic longer than the buffer is truncated rather than overflowing" {
    const capacity = @typeInfo(@FieldType(Diagnostics, "buffer")).array.len;

    var diags: Diagnostics = .{};
    diags.set("x" ** (capacity * 2));

    try testing.expectEqual(capacity, diags.message().len);
}

test "setting a diagnostic twice replaces it rather than appending" {
    var diags: Diagnostics = .{};
    diags.set("program_source:30:1: error: unknown type name");
    diags.set("no device");

    try testing.expectEqualStrings("no device", diags.message());
}
