//! The Metal backend, and the only file in the project allowed to name a Metal
//! type. Everything above it goes through `src/gpu/iface.zig` (ADR 0005).
//!
//! What it does today is decay a persistent accumulation texture, deposit the
//! sample window into it as a single aliased line strip one device pixel wide,
//! and resolve that accumulation over a dim background into the drawable. The
//! persistence is phase 3's step 2 (#55); what is still crude is deliberate and
//! is the rest of that phase. The decay factor is a per-frame constant until #56
//! measures elapsed time, the beam stays a line strip until #57 makes it
//! geometry, and the resolve is an add until #60 puts a tonemap and a palette
//! there. Drawing something ugly first is what lets each of those be judged on
//! how it looks rather than on whether the signal path works at all.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const iface = @import("../iface.zig");
const platform = @import("../../platform/objc.zig");
const io = @import("../../platform/io.zig");
const shader = @import("shader.zig");

const CGRect = platform.CGRect;
const CGSize = platform.CGSize;

/// The bytes this build was compiled from, and what every test at the foot of
/// this file talks about.
///
/// Compiled at runtime rather than linked as a `.metallib` (ADR 0009), which is
/// what keeps `zig build` free of the Metal toolchain and what makes reloading
/// possible at all. `shader.zig` owns where it comes from; this file owns what is
/// done with it.
///
/// **Still the embedded copy after #61, deliberately.** A debug build may compile
/// something else at runtime, and the tests below would say nothing about a file
/// that can change between a build and a frame. What they pin is the agreement
/// between this file's constants and the shader the build shipped: the whole of
/// the shipping path in a release, and the starting point in a debug build.
/// **Nothing anywhere validates a hot-reloaded shader's binding indices**, which
/// gets `buildPipeline`'s missing-function check and nothing else.
const shader_source = shader.embedded;

/// Metal's own enum values, restated because its headers are Objective-C and
/// `translate-c` cannot read them.
///
/// This is the same position `src/clap/c.zig` is in for CLAP's object-like
/// macros, minus the surviving header symbol that lets that file prove its
/// restatements agree. There is nothing to check these against, so the comment
/// has to carry the risk. It is a small risk in practice: these are ABI values
/// baked into every shipped Metal binary, Apple cannot renumber them, and a
/// wrong one shows up immediately as a black or garbled drawable rather than
/// as anything subtle.
const mtl = struct {
    /// `MTLPixelFormatBGRA8Unorm`. Phase 3 moves to the sRGB variant when the
    /// tonemap needs its palette maths in linear light; for a flat colour the
    /// two are indistinguishable, and choosing now would decide it in the wrong
    /// phase.
    const pixel_format_bgra8_unorm: u64 = 80;

    /// `MTLPixelFormatRGBA16Float`, the accumulation's format.
    ///
    /// Floating point is required rather than preferred (ADR 0007). An 8-bit
    /// blend toward black stalls once a value is small enough that multiplying
    /// it by the decay factor rounds back to the same integer, and what that
    /// leaves is a ghost trail that never clears. Float has no such floor, and
    /// it accumulates past 1.0 where the beam dwells, which is the input the
    /// tonemap wants.
    const pixel_format_rgba16_float: u64 = 115;

    const load_action_dont_care: u64 = 0;
    const load_action_clear: u64 = 2;
    const store_action_store: u64 = 1;

    /// `MTLTextureUsage`, which is an option set rather than an enum.
    ///
    /// **The descriptor's default is `ShaderRead` alone**, so omitting the
    /// render-target bit is not a performance mistake, it is a nil encoder on
    /// every frame and a permanently black editor. That failure surfaces as
    /// `NoFramePresented` out of the smoke harness, which names the symptom and
    /// not the cause, so it is worth knowing before it happens rather than
    /// after.
    const texture_usage_shader_read: u64 = 0x1;
    const texture_usage_render_target: u64 = 0x4;

    /// `MTLStorageModePrivate`. GPU-only, which is what these are: nothing on
    /// the CPU ever reads or writes them.
    ///
    /// A different enum from `resource_storage_mode_shared` below, which is
    /// `MTLResourceOptions` with the storage mode packed into bits 4 and up.
    /// Both spell "shared" as zero, and that coincidence is exactly what makes
    /// the two confusable.
    ///
    /// `Memoryless` is the trap worth naming, because it is the obvious choice
    /// on a tile-based GPU and it is precisely wrong here: its contents do not
    /// survive the render pass, which is the negation of the persistence these
    /// textures exist to provide.
    const storage_mode_private: u64 = 2;

    /// `MTLPrimitiveTypeLineStrip` and `MTLPrimitiveTypeTriangle`. These two were
    /// read out of `MTLRenderCommandEncoder.h` rather than recalled, which is
    /// worth saying in a block whose header admits it has nothing to check itself
    /// against: two independent attempts to remember the line strip's value
    /// produced 5 and 1, and the enum runs point, line, line strip, triangle,
    /// triangle strip from zero.
    const primitive_type_line_strip: u64 = 2;
    const primitive_type_triangle: u64 = 3;

    /// `MTLBlendFactorOne` and `MTLBlendOperationAdd`, which together are the
    /// whole of "additive": source plus destination, unweighted.
    ///
    /// Applied to alpha as well as to RGB so the pipeline has one story rather
    /// than two. `resolve_fragment` reads `.rgb` and the accumulation's alpha
    /// carries no meaning today, which is worth saying so #60 does not inherit
    /// a channel it has to guess the intent of.
    const blend_factor_one: u64 = 1;
    const blend_operation_add: u64 = 0;

    /// `MTLResourceStorageModeShared`, which is the storage mode's zero rather
    /// than a flag: `MTLResourceOptions` packs the storage mode into bits 4 and
    /// up, so shared is the whole option word being zero.
    ///
    /// The right mode for a buffer the CPU rewrites every frame and the GPU
    /// reads once. On Apple Silicon there is one physical pool behind it, so
    /// "shared" costs no copy; `Managed` exists for discrete GPUs this project
    /// does not target (ADR 0001) and `Private` could not be written into from
    /// here at all.
    const resource_storage_mode_shared: u64 = 0;
};

/// `MTLClearColor`, four doubles by value.
const ClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

/// Zero energy, which is what a fresh accumulation texture holds.
///
/// **Not `background`, and the difference is not cosmetic.** The accumulation
/// holds energy and the background is a colour. Clearing to the background
/// would add its value every frame against a decay that removes a fraction of
/// what is there, so the steady state is `background / (1 - decay)`: a bright
/// grey field rather than a dim one, reached within a second and never
/// recovered from.
const cleared: ClearColor = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };

/// The format the accumulation is allocated and rendered in, named once so the
/// descriptor and the pipelines that draw into it cannot disagree. A pipeline
/// whose colour-attachment format differs from the texture bound at encode time
/// is a draw-time validation failure, which `probe` never reaches.
const accumulation_pixel_format = mtl.pixel_format_rgba16_float;

/// The drawable's format, named for the same reason and used by both the layer
/// and the one pipeline that renders into it. Two named formats used at every
/// site is what makes a test asserting they differ unnecessary: there is nothing
/// left to drift.
const drawable_pixel_format = mtl.pixel_format_bgra8_unorm;

/// How much of the phosphor survives one frame.
///
/// **Provisional, and per frame rather than per second, which is a defect #56
/// fixes rather than a value it tunes.** The look therefore depends on the
/// refresh rate: 0.90 falls to 5% in 28 frames, about 237 ms at 120 Hz and
/// 474 ms at 60. That is deliberate. The development machine's panel drifts
/// between 48 and 120 Hz on its own, so the frame-rate dependence is visible
/// here rather than hidden, which is the right way for a placeholder to behave.
///
/// It reaches the shader as a uniform rather than as an MSL literal, unlike
/// `trace_fragment`'s colour. The colour is a look constant that #60 deletes;
/// this is a value #56 has to compute per frame from a measured elapsed time,
/// so the binding is needed either way and a Zig-side constant is one a test can
/// hold a range on.
const decay_per_frame: f32 = 0.90;

/// The drawable's size in whole backing pixels.
///
/// Distinct from `iface.Size`, which is logical points everywhere above this
/// file, and deliberately backend-local: reusing the seam's type here would make
/// "size" mean two different things in one function signature.
///
/// It exists because a second surface is about to have to line up with the
/// drawable exactly. `backingPixels` rounds once, and the layer is handed a
/// `CGSize` built from the result, so there is nothing left for CoreAnimation to
/// round differently. Phase 3's accumulation textures are allocated from the
/// same number, which is what makes a fragment shader's integer read of one
/// in-bounds against the other.
const Pixels = struct { width: u32, height: u32 };

/// Everything a pipeline state needs that is not the library it comes from.
///
/// The function names are here so `buildPipeline` can report which pair a
/// library failed to supply rather than reporting a generic failure. **The pixel
/// format is here because it is a third coupling with no compiler behind it**:
/// a pipeline built against one format and encoded against a texture of another
/// is a draw-time validation failure, inside a DAW, on the render thread, with
/// nothing this project can print. Keeping it beside the function names is what
/// makes the two impossible to change independently.
const Pass = struct {
    vertex: [:0]const u8,
    fragment: [:0]const u8,
    pixel_format: u64,
    blending: enum { off, additive } = .off,
};

const decay_pass: Pass = .{
    .vertex = "fullscreen_vertex",
    .fragment = "decay_fragment",
    .pixel_format = accumulation_pixel_format,
};

/// The one blended pass, and the reason blending exists here at all: energy has
/// to add rather than replace, or a beam crossing its own path would overwrite
/// what it already deposited instead of climbing past it.
const trace_pass: Pass = .{
    .vertex = "trace_vertex",
    .fragment = "trace_fragment",
    .pixel_format = accumulation_pixel_format,
    .blending = .additive,
};

const resolve_pass: Pass = .{
    .vertex = "fullscreen_vertex",
    .fragment = "resolve_fragment",
    .pixel_format = drawable_pixel_format,
};

/// Every pair the shader has to define, walked rather than listed by the test at
/// the foot of this file, so a pass is checked by being added here.
const passes = [_]Pass{ decay_pass, trace_pass, resolve_pass };

/// Where `frame` binds the trace's two vertex arguments.
///
/// Deliberately not in `mtl` above: these are not Metal's numbers, they are this
/// project's, and `[[buffer(0)]]` and `[[buffer(1)]]` in `shaders/scope.metal`
/// are the other half of them. Nothing links the two declarations, which is why
/// the test at the foot of this file searches the embedded source for the
/// indices named here. Bind at one index and read at another and Metal reports
/// an unbound buffer at draw time, inside a DAW, on the render thread, with
/// nothing this project can print.
const window_buffer_index: u64 = 0;
const uniform_buffer_index: u64 = 1;

/// Where the two fullscreen passes find the accumulation and their uniforms.
///
/// Both zero, and colliding with `window_buffer_index` above only in appearance:
/// Metal keeps fragment textures, fragment buffers and vertex buffers in three
/// separate index spaces, so these three zeroes name three different slots.
///
/// All three zeroes are checked at the foot of this file by reading the index
/// out of the declaration that carries it, rather than by searching for the
/// attribute alone. That distinction is what makes the check mean anything:
/// `buffer(0)` appears in this shader whatever these constants say.
const accumulation_texture_index: u64 = 0;
const accum_uniform_index: u64 = 0;

/// What the trace's vertex function needs beyond the samples themselves.
///
/// `extern`, so this is the C layout MSL's own `TraceUniforms` computes. Scalars
/// only, deliberately: MSL aligns `float2` to 8 bytes and `float4` to 16, so a
/// vector member would introduce padding this side would have to reproduce by
/// hand. The layout test at the foot of this file is the only thing that would
/// notice a field added to one declaration and not the other, and the symptom of
/// that is a plausible-looking trace at the wrong scale rather than a failure.
///
/// Handed over by `setVertexBytes:`, which copies into the command buffer's own
/// transient storage at encode time. So this needs none of the slot discipline
/// `Renderer.window` exists to describe: there is no buffer for the GPU to be
/// mid-read of. A fourth `MTLBuffer` would also be a fourth resource `leaks`
/// cannot see, which is a cost this project has already measured once.
const TraceUniforms = extern struct {
    /// Vertices in the strip, and the divisor the x mapping uses. Never below
    /// two; `traceVertices` is what establishes that.
    sample_count: u32,
    full_scale: f32 = iface.trace_full_scale,
    rail: f32 = iface.trace_rail,
};

/// The pipeline states one render pass runs, in the order `frame` encodes them.
///
/// One struct rather than two fields because they are taken together and given
/// back together, on `buildWindows`' precedent: `buildPipelines` returns both or
/// neither, and `releasePipelines` is the one place either is released.
///
/// The reason it is not two calls to the old `buildPipeline` is the library
/// rather than the states. `newLibraryWithSource:` hands the source to
/// `MTLCompilerService.xpc` out of process, and compiling the same embedded
/// string twice to pull four functions out of it would double that for nothing.
///
/// **How much that is depends entirely on Metal's cache, which was measured
/// rather than assumed.** A source the machine has compiled before comes back in
/// 0.04 ms, because the cache is keyed on the source and survives across
/// processes; a source it has not takes 34 to 43 ms, and 57 to 68 ms if it is
/// also the first compile in this process. The three pipeline states are 0.2 to
/// 0.8 ms either way, so the library is the whole of the cost. This docstring
/// used to call the compile "the most expensive thing `init` does", which is
/// true on a cold cache and wrong in the steady state, where the accumulation
/// textures dominate and `set_parent` waits 0.14 ms on this. The figure that
/// still matters is the miss, because that is what every hot reload pays.
const Pipelines = struct {
    decay: objc.Object,
    trace: objc.Object,
    resolve: objc.Object,
};

/// What both fullscreen passes read besides the texture they are handed.
///
/// `extern` for C layout, scalars only for the reason `TraceUniforms` gives, and
/// passed by `setFragmentBytes:` rather than living in a buffer, so there is no
/// fourth resource for a slot discipline to cover and nothing for a leak check
/// to be blind to.
///
/// One field today, and a struct rather than a bare float because #56 replaces
/// the constant with a value computed per frame and #60 is likely to want a
/// companion. A second field then costs a layout test line rather than a new
/// binding.
const AccumUniforms = extern struct {
    decay: f32 = decay_per_frame,
};

/// How far the CPU may run ahead of the GPU, in frames.
///
/// Three is the conventional choice and is also `CAMetalLayer`'s own maximum:
/// two leaves the CPU waiting on the GPU at the smallest hiccup, and four buys
/// nothing but latency. Both bounds are set, because they bound different
/// things. The drawable pool limits how many presented frames can be
/// outstanding; the semaphore limits how far ahead the CPU may encode, which is
/// what phase 2's per-frame dynamic buffers will actually need in order to know
/// which slot of a ring is free.
const max_frames_in_flight = 3;

/// Acquires the system default device. Follows the Create Rule, so the caller
/// owns what comes back and has to release it.
extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

/// libdispatch. Declared rather than translated for the same reason Metal's
/// enums are restated: the headers are full of macros and attributes that
/// `translate-c` has no use for, and these three functions are a stable ABI.
///
/// **Not one of the primitives ADR 0015 governs.** `std` did not hide this one,
/// and `std.Io.Semaphore` could not replace it in any case: it offers `wait` and
/// `waitUncancelable` and no try-wait at all, both routed through `Io.Mutex` and
/// `Io.Condition` to `futexWait`. The wait below is deliberately bounded, for the
/// reason `dispatch_time_now` gives, so a blocking-only semaphore is the one
/// shape this call site cannot use.
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sema: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sema: *anyopaque) isize;

/// `DISPATCH_TIME_NOW`. The wait below is a try-wait rather than a block, and
/// the difference is a hang rather than a stutter.
///
/// Blocking here looked like the right backpressure, and it is what the
/// canonical Metal pattern does, but that pattern assumes a render loop thread
/// the program owns. This is CoreVideo's callback thread, and `Editor.tick`
/// holds the gate across the whole call. A GPU that never signalled a
/// completion handler would leave this wait unbounded, the gate never released,
/// and `Gate.close` spinning on the host's main thread for as long as the
/// process lived: an editor that will not close, in someone else's DAW.
///
/// Not waiting costs nothing that matters. If no slot is free at this instant
/// the GPU is behind, and dropping the tick is what the loop would do a moment
/// later anyway. It also returns the display-link callback promptly, which
/// CoreVideo would rather have than a callback that runs long.
const dispatch_time_now: u64 = 0;

/// The block `addCompletedHandler:` takes, which is how a slot comes back.
///
/// The semaphore is captured as an `objc.c.id` rather than as a raw pointer,
/// which is not a formality. `zig-objc` retains `id`-typed captures when the
/// runtime copies the block to the heap, and `addCompletedHandler:` does copy
/// it. That retain is what makes `deinit` safe: releasing the semaphore while a
/// command buffer is still executing would otherwise leave a queued handler
/// signalling freed memory. The obvious alternative, draining every slot before
/// releasing, would reintroduce on the teardown path exactly the unbounded wait
/// that `dispatch_time_now` exists to keep off the render path.
const Completion = objc.Block(struct { sema: objc.c.id }, .{objc.c.id}, void);

/// Window buffers taken and not yet given back.
///
/// **This exists because `leaks` cannot see one, which was measured rather than
/// assumed.** Dropping the release in `deinit` and running the harness 60 times
/// produces a report `scripts/smoke-leak-check` calls clean, while the same
/// omission applied to the command queue is caught immediately as
/// `AGXG17XFamilyCommandQueue`. The leak is real: peak RSS across 200 cycles
/// goes from 47.7 MB to 57.7 MB. `leaks` walks the malloc heap, and a Metal
/// buffer's storage is not in it.
///
/// So the one resource this file holds that the project's leak check is blind to
/// carries its own count. Process-wide rather than per-renderer, because that is
/// what makes it answer the question worth asking across an editor being opened
/// and closed several hundred times rather than within any one of them.
var live_windows: std.atomic.Value(usize) = .init(0);

/// Accumulation textures taken and not yet given back.
///
/// **The same blindness as `live_windows` above, measured separately, and one
/// instrument worse.** ADR 0013 set the rule after #38 that a Metal resource
/// which is not a buffer must be checked against `leaks` with a planted leak
/// before `smoke-leaks` is assumed to cover it, precisely because a pipeline
/// state turned out to be visible where a buffer was not and neither result
/// predicted a third kind. A texture was measured and it is invisible.
///
/// Dropping one of the two releases and running 20 cycles reports 283 leaks for
/// 18,560 bytes against a clean 288 for 18,816: the leaking run reported
/// *fewer* bytes, none of the 250 leaked classes is a texture under any name,
/// and the leak is real at roughly 46 MB per cycle.
///
/// The part that does not follow from the buffer case is peak RSS. A leaked
/// `MTLBuffer` moved it from 47.7 MB to 57.7 MB and was caught that way; a
/// leaked texture does not move it at all, 44.3 MB against 44.1 MB clean at 40
/// cycles while leaking nearly two gigabytes. Shared storage is in the process's
/// resident set and `MTLStorageModePrivate` is not, so **the counter below is
/// not the better of two instruments here, it is the only one.**
///
/// **What it catches and what it cannot, both measured by planting them.** It
/// catches an allocation that is never handed back: removing the release from
/// `replaceAccumulation` fails `smoke-appkit` with 20 textures outstanding
/// across 10 cycles. That is the realistic failure and it is the one
/// `live_windows` never had to cover, since window buffers are allocated once
/// and these are rebuilt on every resize that moves the pixel count.
///
/// It does **not** catch a `releaseAccumulation` that stops sending `release`,
/// because the count comes back either way; planting that passes cleanly. The
/// same hole exists for `live_windows` and is worse here, since RSS backstops
/// that one and backstops nothing for this. What keeps it small is that there
/// is exactly one release site, so the failure it misses is somebody editing
/// this function to release less than it counts.
var live_textures: std.atomic.Value(usize) = .init(0);

/// What has happened to the shader on disk, process-wide.
///
/// Process-wide rather than per-renderer for `live_windows`' reason, and one more
/// besides: the question a caller wants answered is "did my edit reach the GPU",
/// and every open editor in the process answers it at once.
///
/// Zero and immovable in a release build, where nothing reads a file. A caller
/// telling that apart from a watcher that never fired reads `path_resolved`.
var shader_reloads: std.atomic.Value(u64) = .init(0);
var shader_rejected: std.atomic.Value(u64) = .init(0);
var shader_fallbacks: std.atomic.Value(u64) = .init(0);
var shader_path_resolved: std.atomic.Value(bool) = .init(false);

/// Say something once about the shader on disk, on the watcher's own thread.
///
/// `std.debug.print`, which is wrong in most of this project and right here for
/// reasons that do not transfer. This runs on neither the audio thread, nor the
/// render thread, nor the host's main thread, so ADR 0010's no-lock, no-syscall
/// rule does not reach it and it may take the stderr lock. It is also already the
/// channel a developer is told to read, by launching the host from a terminal.
///
/// A `clap.log` route would be the alternative and is worse three ways: the log
/// lives above the seam, the gpu layer importing it is the layering violation
/// `iface.Diagnostics` exists to avoid, and the message would arrive at the next
/// once-a-second `Editor.report` rather than when the file was saved.
///
/// Gated on `shader.live`, which folds in `builtin.is_test` for the reason
/// `clap/log.zig` disables its own mirror there: printing from inside a test
/// binary interleaves with the runner's stream and the build runner reads that as
/// a failed step.
fn sayShader(comptime fmt: []const u8, args: anytype) void {
    if (comptime !shader.live) return;
    std.debug.print("[fosforo] shader: " ++ fmt ++ "\n", args);
}

/// Whether this thread has ever been inside the render path.
///
/// **A threadlocal rather than an atomic, and that is the whole design.** Several
/// open editors mean several display-link threads, so a single process-wide slot
/// would hold whichever one marked itself last and would miss the others. A
/// threadlocal marks each one independently and costs a store per tick.
///
/// Set and never cleared, so it reads as "this thread draws frames" rather than
/// "this thread is drawing one right now". That is the stronger claim and the one
/// worth having: it catches work added to `resize` or `upload` just as well as
/// work added to `frame`.
threadlocal var on_render_thread: bool = false;

/// [render-thread] Claim this thread as one that draws.
///
/// Called beside `platform.assertNotMainThread` at all three render-path entry
/// points rather than folded into it, because the two say different things and
/// hiding either inside the other would cost a reader the reason for it.
fn markRenderThread() void {
    if (builtin.mode != .Debug) return;
    on_render_thread = true;
}

/// The other half of the rule ADR 0010 states, from the side nothing guarded.
///
/// `platform.assertNotMainThread` exists so the render path is *unreachable* from
/// the main thread. Nothing said the inverse, and #61 made the inverse matter: a
/// cache-missing shader compile takes about 40 ms, and `Editor.tick` holds its
/// `Gate` across its whole body, so a compile that reached a display-link thread
/// would busy-spin the host's main thread for that long whenever an editor closed
/// during one. The whole watcher exists to keep it off that thread, and until this
/// nothing would have noticed it drifting back: the harness cannot see 40 ms in a
/// tick against a two-second frame timeout, which ADR 0013 records.
///
/// Debug builds only, on `assertMainThread`'s reasoning. It costs a release build
/// nothing and it fires on the machine of whoever introduced the problem.
fn assertNotRenderThread() void {
    if (builtin.mode != .Debug) return;
    std.debug.assert(!on_render_thread);
}

fn signalCompleted(block: *const Completion.Context, buffer: objc.c.id) callconv(.c) void {
    _ = buffer;
    if (block.sema) |sema| _ = dispatch_semaphore_signal(@ptrCast(sema));
}

/// A single-slot mailbox carrying one finished set of pipeline states from the
/// watcher thread to the render thread.
///
/// `Pending` in `src/clap/gui.zig` is the shape, and the place the reasoning
/// already lives: one producer, one consumer, drained at the top of a tick before
/// anything it invalidates is read (ADR 0010). This is that one layer down.
///
/// **It cannot be `Pending`'s single atomic swap, and the reason is the payload's
/// size rather than a difference of opinion.** `Pending` packs a size and a scale
/// into one `u64`, so a post is a store and a drain is a swap with no torn read
/// to reason about. A `Pipelines` is three object pointers, so the payload sits
/// beside the word and the word is what orders access to it.
const Mailbox = struct {
    /// Written `.release` by whichever side made the transition and read
    /// `.acquire` by the other, which is what *publishes* `staged` rather than
    /// merely announcing it.
    state: std.atomic.Value(State) = .init(.empty),

    /// Written only by the watcher, and only while `state` is `.empty`. Read only
    /// by the render thread, and only while `state` is `.full`. Those two windows
    /// provably cannot overlap, which is the whole of why this needs no lock.
    staged: Pipelines = undefined,

    const State = enum(u32) { empty, full };

    /// [watcher-thread] Whether there is room to publish into.
    ///
    /// **Asked before the compile rather than after it**, which is what makes the
    /// already-full case free: an editor hidden for an hour costs four `stat`
    /// calls a second and no XPC round trips at all. A watcher that compiled
    /// first would throw the result away and pay 40 ms for it every poll.
    ///
    /// The answer cannot go stale in the unsafe direction, because only the
    /// render thread performs full -> empty: a slot seen empty stays empty until
    /// this thread fills it.
    fn vacant(self: *const Mailbox) bool {
        return self.state.load(.acquire) == .empty;
    }

    /// [watcher-thread] Hand a finished set over.
    fn publish(self: *Mailbox, pipelines: Pipelines) void {
        std.debug.assert(self.state.load(.monotonic) == .empty);
        self.staged = pipelines;
        self.state.store(.full, .release);
    }

    /// [render-thread, and [main-thread] once the watcher is joined] Take the
    /// set, if there is one.
    ///
    /// **The copy happens before the state moves, and reversing those two lines
    /// is the defect this comment exists to prevent.** `Pending.take` is a single
    /// swap because its payload *is* the word; here the word only guards the
    /// payload, so emptying the slot first would let the watcher start writing
    /// `staged` while this thread was still reading it, and what came out would
    /// be three pointers drawn from two different compiles. That is not a crash,
    /// it is a picture that is subtly wrong. The release store below is what
    /// orders the watcher's next write after this read.
    fn take(self: *Mailbox) ?Pipelines {
        if (self.state.load(.acquire) != .full) return null;

        const taken = self.staged;
        self.state.store(.empty, .release);
        return taken;
    }
};

/// Watches the shader file and compiles it somewhere the render thread is not.
///
/// **Why a thread at all**, given this project has never had one: compiling a
/// source Metal has not seen takes about 40 ms (measured; see `Pipelines`), which
/// is five vsyncs at 120 Hz. `Editor.tick` holds its `Gate` across its whole
/// body, so a compile inside a tick is not merely a dropped frame, it is up to
/// 40 ms of busy-spin on the host's main thread whenever an editor closes during
/// one. #59 defers the same question about its own upsampling, so what this
/// establishes is reusable rather than one-off.
///
/// Debug builds only, one per `Renderer`, which means one per open editor. A
/// process-wide watcher would need a registry of live renderers to fan out to,
/// which is worse than N threads parked in a futex; the cost worth naming is that
/// eight open editors means eight compiles per save.
const Watcher = if (shader.live) struct {
    thread: ?std.Thread = null,
    started: bool = false,

    /// The stop flag **and** the futex word, which is what makes the wake
    /// race-free rather than lucky. The kernel re-checks the word under its own
    /// lock before parking, so a `halting` that lands between this thread's last
    /// check and its wait returns immediately instead of sleeping the interval
    /// out. Split into a `bool` and a separate word and the classic missed wakeup
    /// is back, at a quarter second on the host's main thread every time an
    /// editor closes.
    halt: std.atomic.Value(u32) = .init(running),

    mailbox: Mailbox = .{},

    /// Owned by the watcher thread alone, and a field rather than a local because
    /// 64 KiB is worth allocating once per editor rather than once per poll.
    buf: shader.Buffer = .{},

    /// What the file looked like last time this looked. Null until the first
    /// successful stat, so the file as it stands when an editor opens is not
    /// treated as an edit: `init` already compiled it.
    seen: ?shader.Stamp = null,

    const running: u32 = 0;
    const halting: u32 = 1;

    /// Four times a second, which is under the ~40 ms a compile costs and far
    /// under the time it takes to notice a change by eye. A `stat` is cheap
    /// enough that the interval is chosen for latency rather than for cost.
    const poll_ms = 250;

    /// [render-thread] Start on the first frame, and never again.
    ///
    /// **Not in `init`, and this is not a preference.** `Renderer.init` returns
    /// by value (the seam pins that signature) and `gui.Editor` copies the result
    /// into a field, so `&self` inside `init` is the address of a temporary. The
    /// first `frame` is the earliest moment this object has the address the
    /// render thread will keep using.
    ///
    /// Two properties fall out and both are wanted. An editor created and never
    /// shown never ticks, so it never watches. And the spawn lands once inside a
    /// frame budget rather than on `set_parent`, where a host is already waiting.
    ///
    /// A failed spawn is survivable and is not reported through `Diagnostics`,
    /// which this thread has no way to reach a caller with. A debug build that
    /// renders without hot reload is strictly better than an editor that will not
    /// open, so it says so once and leaves `thread` null forever.
    fn start(self: *Watcher, device: objc.Object) void {
        if (self.started) return;
        self.started = true;

        var path_buf: shader.PathBuffer = undefined;
        if (shader.resolvePath(&path_buf) == null) return;

        self.thread = std.Thread.spawn(.{}, run, .{ self, device }) catch |err| {
            sayShader("the watcher thread would not start ({t}); reload is off for this editor", .{err});
            return;
        };
    }

    /// [main-thread] Ask the watcher to finish, and wait until it has.
    ///
    /// The worst case is one compile, because `newLibraryWithSource:` cannot be
    /// interrupted: Metal offers no cancellation and the work is out of process.
    /// That is symmetric with a cost the host already pays on `set_parent`, it
    /// needs a save and an editor closing to overlap within one compile, and it
    /// is debug-only. The expected case is zero, since the thread is parked in
    /// the futex more than 99% of the time.
    fn stop(self: *Watcher) void {
        const thread = self.thread orelse return;

        // The flag before the wake, never after. A wake that arrived first would
        // wake a thread with nothing to find, which would park again for a full
        // interval. The `.release` pairs with `stopping`'s `.acquire`.
        self.halt.store(halting, .release);
        io.get().futexWake(u32, &self.halt.raw, 1);

        thread.join();
        self.thread = null;
    }

    fn stopping(self: *const Watcher) bool {
        return self.halt.load(.acquire) != running;
    }

    /// [watcher-thread] Wait out one poll interval, or until `stop` says
    /// otherwise.
    ///
    /// `error.Canceled` cannot fire, for the reason `src/smoke.zig` records about
    /// `sleep`: `Threaded.Thread.current` is a threadlocal only threads the
    /// runtime itself spawns ever set, and this one came from `std.Thread.spawn`,
    /// so the syscall region takes the uncancelable branch. It is swallowed
    /// rather than propagated because the loop re-reads the flag on the next
    /// line, so a cancelled, spurious and timed-out wake are one event here.
    fn park(self: *Watcher) void {
        io.get().futexWaitTimeout(u32, &self.halt.raw, running, .{
            .duration = .{ .raw = .fromMilliseconds(poll_ms), .clock = .awake },
        }) catch {};
    }

    /// [render-thread] Take a finished set if the watcher left one.
    fn drain(self: *Watcher) ?Pipelines {
        return self.mailbox.take();
    }

    fn run(self: *Watcher, device: objc.Object) void {
        // The baseline is taken here rather than on the first poll, and the
        // difference is a whole poll interval of an editor's life during which an
        // edit would be recorded rather than acted on. `init` compiled this file
        // moments ago, so what is wanted is "changed since then", and taking the
        // stamp now rather than 250 ms from now is what makes that true.
        var path_buf: shader.PathBuffer = undefined;
        if (shader.resolvePath(&path_buf)) |path| {
            self.seen = shader.stamp(path) catch null;
        }

        while (true) {
            self.park();
            if (self.stopping()) return;

            // Its own pool per poll. `platform.nsString` returns an autoreleased
            // object and a spawned thread has no pool and no run loop to drain
            // one, so without this the runtime logs "autoreleased with no pool in
            // place" and leaks every string this loop makes.
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();

            self.poll(device);
        }
    }

    /// [watcher-thread] One look at the file.
    fn poll(self: *Watcher, device: objc.Object) void {
        // Before the stat, so a hidden editor costs nothing. Skipping without
        // advancing `seen` is what makes it lossless: the change is still
        // outstanding and the next poll picks it up.
        if (!self.mailbox.vacant()) return;

        var path_buf: shader.PathBuffer = undefined;
        const path = shader.resolvePath(&path_buf) orelse return;
        const now = shader.stamp(path) catch return;

        // Null only when the baseline stat in `run` failed, which means the file
        // was unreadable when this editor opened. Recording rather than reloading
        // is right there too: `buildPipelines` already fell back and said so, and
        // a file that has since appeared is a change this will see next time.
        const previous = self.seen orelse {
            self.seen = now;
            return;
        };
        if (!previous.differs(now)) return;

        // **Advanced before the compile, and on every outcome including failure.**
        // Without that a broken file prints the same diagnostic four times a
        // second forever; with it, it prints once per save and recovers when the
        // file is fixed.
        self.seen = now;

        shader.read(&self.buf, path) catch |err| {
            _ = shader_fallbacks.fetchAdd(1, .release);
            sayShader("cannot read {s} ({t}); keeping the shader now running", .{ path, err });
            return;
        };

        var diags: iface.Diagnostics = .{};
        const pipelines = buildPipelinesFromSource(device, self.buf.source(), &diags) catch {
            _ = shader_rejected.fetchAdd(1, .release);
            sayShader("{s}; keeping the shader now running", .{diags.message()});
            return;
        };

        // Said out loud, because the alternative is watching a picture for a
        // change that may legitimately be invisible. An edit to a constant nobody
        // can see by eye is exactly the kind this is for, and "did that take?" is
        // otherwise unanswerable without another edit that does show.
        _ = shader_reloads.fetchAdd(1, .release);
        sayShader("recompiled {d} bytes from {s}", .{ self.buf.len, path });

        self.mailbox.publish(pipelines);
    }
} else struct {
    // Release builds get a type with the same shape and no behaviour, so the two
    // call sites in `frame` and `deinit` need no `if (shader.live)` around them
    // and cannot drift from each other.
    fn start(_: *Watcher, _: objc.Object) void {}
    fn stop(_: *Watcher) void {}
    fn drain(_: *Watcher) ?Pipelines {
        return null;
    }
};

pub const Renderer = struct {
    device: objc.Object,
    queue: objc.Object,
    pipelines: Pipelines,
    layer: objc.Object,

    /// Counts free frame slots. Waited on at the top of every frame and
    /// signalled from the GPU's completion handler.
    in_flight: objc.Object,

    /// One window buffer per frame the CPU may run ahead, so a frame never
    /// writes into a buffer the GPU is still reading.
    ///
    /// This is the ring the semaphore was built to protect, arriving with its
    /// first caller. `slot` picks the one this frame owns, and it advances only
    /// after a successful wait, which is what makes the choice safe: a wait that
    /// succeeded proves at most `max_frames_in_flight - 1` frames are still
    /// outstanding, so the buffer that many encodes back has completed.
    windows: [max_frames_in_flight]objc.Object,
    slot: usize = 0,

    /// The most recent window `upload` was handed, and the reason the copy into
    /// `windows[slot]` happens in `frame` rather than in `upload`.
    ///
    /// A per-frame buffer is only safe to write once its slot is known free, and
    /// the slot is taken by the try-wait at the top of `frame`. An `upload`
    /// called before that holds no slot, so writing the GPU buffer there would
    /// be writing one the GPU may still be reading whenever the wait goes on to
    /// fail. That shows as tearing under load rather than as a crash, which is
    /// the kind of defect that gets diagnosed as "the GPU is flaky".
    ///
    /// Staging costs one 32 KiB copy per tick and buys two things beyond that
    /// ordering. `upload` borrows nothing, so no caller has to keep a slice
    /// alive across two calls. And a skipped upload is trivially correct: a torn
    /// window leaves this holding the last good one, and `frame` draws that
    /// again rather than binding a buffer several encodes stale.
    window: [iface.max_window_samples]f32 = @splat(0),
    window_len: usize = 0,

    /// The drawable's current size in whole backing pixels.
    ///
    /// The first thing this backend has ever remembered about its own geometry.
    /// `resize` used to forward both arguments to the layer and keep neither,
    /// which was right while the drawable was the only surface: nothing else
    /// needed the number, and the layer already had it.
    ///
    /// Phase 3's accumulation textures are what change that. They are sized from
    /// this, reallocated when it moves, and read by a fragment shader at integer
    /// coordinates against the drawable, so the two have to be the same number
    /// rather than two roundings of one expression. It is also the `H` the
    /// half-pixel centre-line bias in `AGENTS.md` was declined for wanting.
    pixels: Pixels,

    /// The ping-pong pair the beam deposits into, or nothing when the last
    /// attempt to allocate them failed.
    ///
    /// Optional because a failed reallocation is a real machine condition
    /// rather than a programming error, and because it is the first one here a
    /// user can provoke: these scale with the editor's geometry, and
    /// `gui.max_size` at a backing scale of 2 describes a pair of textures
    /// totalling four gibibytes. `frame` skips the tick when this is null and a
    /// later resize restores it.
    ///
    /// The alternative, storing a nil texture and messaging it, is worse than a
    /// skipped frame rather than equivalent to one: messaging nil is a silent
    /// no-op returning nil, so the encoding calls would quietly do nothing and
    /// the frame would go on to present a drawable that was never written.
    accum: ?[2]objc.Object = null,

    /// Which half of the pair holds this frame's starting energy.
    ///
    /// Advanced once per committed frame and never on a skipped one, which is
    /// what makes every early return in `frame` leave the accumulation intact
    /// rather than half-updated.
    accum_source: u1 = 0,

    /// Recompiles the shader off this thread when the file changes.
    ///
    /// Zero-sized and inert outside a debug build. Started by the first `frame`
    /// rather than by `init`, for the reason `Watcher.start` gives, and stopped
    /// by `deinit` before anything it compiles against is released.
    watcher: Watcher = .{},

    /// [main-thread] Builds everything the GPU needs and hangs a layer off the
    /// host's view.
    ///
    /// Everything transient here is autoreleased, so the pool is not a
    /// nicety. Without one the objects accumulate until whatever pool the host
    /// happens to have open drains, which inside a DAW is not a schedule this
    /// plugin controls.
    pub fn init(
        view: iface.NativeView,
        size: iface.Size,
        scale: f64,
        diags: *iface.Diagnostics,
    ) iface.Error!Renderer {
        platform.assertMainThread();

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const device = objc.Object.fromId(MTLCreateSystemDefaultDevice() orelse {
            diags.set("Metal reported no default device");
            return error.NoDevice;
        });
        errdefer device.release();

        const queue = device.msgSend(objc.Object, "newCommandQueue", .{});
        if (queue.value == null) {
            diags.set("the Metal device would not create a command queue");
            return error.NoDevice;
        }
        errdefer queue.release();

        const pipelines = try buildPipelines(device, diags);
        errdefer releasePipelines(pipelines);

        const in_flight = objc.Object.fromId(dispatch_semaphore_create(max_frames_in_flight) orelse {
            diags.set("libdispatch would not create the in-flight-frames semaphore");
            return error.NoDevice;
        });
        errdefer in_flight.release();

        // `releaseWindows` rather than a bare release loop, because these are
        // counted: `buildWindows` reported them the moment it handed the whole
        // ring over. Releasing them here without saying so would leave
        // `liveWindowBuffers` permanently three high after a failed `init`,
        // which is worse than the leak it exists to catch. The count would then
        // never return to zero and the harness would report a leak on every
        // later run, or hide a real one behind the offset.
        const windows = try buildWindows(device, diags);
        errdefer releaseWindows(windows);

        // Computed once and handed on rather than recomputed at each call site,
        // which is the whole discipline `backingPixels` exists to enforce.
        const pixels = backingPixels(size, scale);

        const accum = try buildAccumulation(device, queue, pixels, diags);
        errdefer releaseAccumulation(accum);

        // Last, so it is the one acquisition needing no `errdefer`.
        const layer = try attachLayer(view, device, size, pixels, scale, diags);

        return .{
            .device = device,
            .queue = queue,
            .pipelines = pipelines,
            .layer = layer,
            .in_flight = in_flight,
            .windows = windows,
            .pixels = pixels,
            .accum = accum,
        };
    }

    /// [main-thread] Everything `init` does that needs neither a surface nor a
    /// size, released again before it returns.
    ///
    /// The half of starting a renderer that needs no window, and so the half
    /// that can run on a machine with a GPU and nothing else. It shares
    /// `buildPipelines` with `init` rather than paraphrasing it, which is what
    /// makes a pass here mean the shipping path compiled the shader, and not
    /// merely that some shader compiled.
    ///
    /// **The accumulation textures are deliberately not allocated here**, and
    /// the `buildWindows` precedent does not carry over. Those have a size the
    /// seam publishes, so this allocates the real thing; a texture's size comes
    /// from the editor's geometry, and inventing a nominal one would be this
    /// function paraphrasing `init` after all. What allocating them would catch
    /// is caught anyway: `newRenderPipelineStateWithDescriptor:` validates a
    /// pipeline's colour-attachment format, so a wrong
    /// `pixel_format_rgba16_float` fails here through `buildPipelines` on every
    /// push, in the one CI job that runs Metal.
    ///
    /// That covers strictly more than `zig build validate-shaders` does, which is
    /// worth knowing because the two look interchangeable. `metal -fsyntax-only`
    /// parses and type-checks and never links a pipeline state, and
    /// `newRenderPipelineStateWithDescriptor:` is exactly where a vertex function
    /// whose buffer arguments the pipeline cannot satisfy fails.
    ///
    /// Writes what it found into `diags` on success as well as on failure. A
    /// smoke test that reports "ok" without naming the device it acquired is
    /// asserting something nobody can check, and the device's name is bytes by
    /// the time it crosses the seam.
    pub fn probe(diags: *iface.Diagnostics) iface.Error!void {
        platform.assertMainThread();

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const device = objc.Object.fromId(MTLCreateSystemDefaultDevice() orelse {
            diags.set("Metal reported no default device");
            return error.NoDevice;
        });
        defer device.release();

        const queue = device.msgSend(objc.Object, "newCommandQueue", .{});
        if (queue.value == null) {
            diags.set("the Metal device would not create a command queue");
            return error.NoDevice;
        }
        defer queue.release();

        const pipelines = try buildPipelines(device, diags);
        releasePipelines(pipelines);

        // Taken and given straight back, which keeps this function's first
        // sentence true. It is the cheapest of the four acquisitions and the
        // least likely to fail, but leaving it out would mean `smoke-gpu`
        // reported a healthy backend on a machine where starting one allocates
        // memory it cannot get.
        const windows = try buildWindows(device, diags);
        releaseWindows(windows);

        diags.set(platform.utf8(device.msgSend(objc.Object, "name", .{})));
    }

    /// [main-thread] Releases everything `init` took ownership of.
    ///
    /// Must run before the view is released, since the layer is still attached
    /// to it. `gui.Editor` guarantees that by ordering its teardown, and also
    /// guarantees no tick is in flight by the time this runs.
    ///
    /// The semaphore is released without draining it first. Frames may still be
    /// executing on the GPU, and each one's completion handler holds its own
    /// retain, so the last handler to run is what actually frees it.
    ///
    /// The window buffers are released on the same reasoning, reached a
    /// different way: a render command encoder retains the resources it binds
    /// until its command buffer completes, so a buffer this frame is reading is
    /// held by that command buffer rather than by the count released here. The
    /// alternative, draining every slot first, would put back on the teardown
    /// path exactly the unbounded wait `dispatch_time_now` keeps off the render
    /// path.
    pub fn deinit(self: *Renderer) void {
        platform.assertMainThread();

        // First, and before any release below. The watcher compiles against
        // `self.device`, which this function gives back six lines down, so a join
        // that ran last could leave `newLibraryWithSource:` holding a device that
        // had already been released. `gui.Editor.destroy` closed its gate before
        // reaching here, so no tick can be inside the swap either, which is what
        // makes reading the thread handle from this thread sound.
        self.watcher.stop();

        if (self.accum) |pair| releaseAccumulation(pair);
        releaseWindows(self.windows);
        self.in_flight.release();
        self.layer.release();

        // The staged set as well as the live one, and through the same function,
        // so `releasePipelines` stays the one release site. An editor closed
        // within a poll interval of a save would otherwise leak three pipeline
        // states, and that is the one leak on this path `leaks` can actually see.
        //
        // The atomics inside `take` are redundant here and kept anyway: the
        // watcher is joined, so nothing can race this, and going through the same
        // function is what stops a second, subtly different drain existing.
        if (self.watcher.drain()) |staged| releasePipelines(staged);
        releasePipelines(self.pipelines);

        self.queue.release();
        self.device.release();
        self.* = undefined;
    }

    /// [render-thread] Point the drawable at a new size and backing scale.
    ///
    /// Called from the top of a tick, after the mailbox has been drained and
    /// before anything reads the resources it is about to replace. That
    /// ordering is the whole point of the mailbox (ADR 0010): the host's
    /// resize callback arrives on the main thread, and doing this there would
    /// be reallocating out from under a frame this thread is midway through.
    ///
    /// Phase 3's accumulation textures are reallocated here, which is why this
    /// takes the size rather than reading it back off the layer, and why the
    /// layer work is a separate function rather than this function's body.
    pub fn resize(self: *Renderer, size: iface.Size, scale: f64) void {
        platform.assertNotMainThread();
        markRenderThread();

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const pixels = backingPixels(size, scale);
        self.applyLayerGeometry(pixels, scale);

        // A scale can change without the pixel count changing, and
        // `Editor.onDisplayChanged` posts the current size with a freshly read
        // scale unconditionally, so without this a redundant post throws the
        // phosphor away and reallocates tens of megabytes for nothing. A drag
        // delivers a size on very nearly every tick, which is what makes this a
        // cost decision worth making rather than a micro-optimisation.
        if (self.accum != null and std.meta.eql(pixels, self.pixels)) return;

        self.pixels = pixels;
        self.replaceAccumulation(pixels);
    }

    /// [render-thread] Throw the accumulation away and build it at a new size.
    ///
    /// The old pair is released before the new one is taken, which is safe for
    /// a reason worth stating rather than inheriting: a command buffer created
    /// through `-[MTLCommandQueue commandBuffer]` retains every resource it
    /// references until it completes, attachments included. `release` here
    /// therefore drops this object's claim and not the GPU's, so a frame still
    /// executing keeps the textures it is reading. That is a stronger fact than
    /// the "an encoder retains what it binds" `deinit` leans on, because a
    /// render target is attached rather than bound.
    ///
    /// **The accumulated energy does not survive, and should not.** Its content
    /// describes a geometry that no longer exists, so carrying it across would
    /// mean stretching a picture of the signal rather than redrawing one. What
    /// this looks like in a host is a trail that vanishes while a window is
    /// being dragged and rebuilds when it stops, which reads as a defect and is
    /// the design.
    ///
    /// Failure leaves `accum` null and reports nothing, because the render
    /// thread has nowhere to report to (ADR 0010). The signal that survives is
    /// `frame` returning `.no_accumulation` to a caller that counts it.
    fn replaceAccumulation(self: *Renderer, pixels: Pixels) void {
        if (self.accum) |pair| releaseAccumulation(pair);
        self.accum = null;

        var diags: iface.Diagnostics = .{};
        self.accum = buildAccumulation(self.device, self.queue, pixels, &diags) catch null;
    }

    /// [render-thread] Point the layer at a new drawable size and scale.
    ///
    /// Split out of `resize` so the CoreAnimation transaction is provably closed
    /// before anything else runs. A `defer` fires at *function* exit, so leaving
    /// this inline and appending texture reallocation below it would hold a
    /// transaction open across a multi-megabyte allocation, on a thread that is
    /// not the main one. That is not obviously harmful and is obviously not what
    /// anyone intends, which is the kind of thing worth making structural rather
    /// than remembering.
    ///
    /// Inside a transaction at all because these are CoreAnimation properties
    /// being set from somewhere that is not the main thread: it makes the pair
    /// land as one change and skips the implicit animation CoreAnimation would
    /// otherwise attach to each.
    fn applyLayerGeometry(self: *Renderer, pixels: Pixels, scale: f64) void {
        const transaction = objc.getClass("CATransaction").?;
        transaction.msgSend(void, "begin", .{});
        defer transaction.msgSend(void, "commit", .{});
        transaction.msgSend(void, "setDisableActions:", .{true});

        self.layer.msgSend(void, "setContentsScale:", .{scale});
        self.layer.msgSend(void, "setDrawableSize:", .{drawableSize(pixels)});
    }

    /// [render-thread] Hand over the window the next frame should draw.
    ///
    /// Called from the same tick as `frame` and just before it, after the
    /// mailbox has been drained, so the window is never read against geometry a
    /// resize is about to replace.
    ///
    /// The samples land in CPU staging rather than in a GPU buffer, for the
    /// ordering reason `Renderer.window` sets out: no slot is held yet. Nothing
    /// here allocates, blocks, or sends a message, which is why there is no
    /// autorelease pool and why this adds no wait to a thread that may not have
    /// one (ADR 0010).
    ///
    /// A window longer than `max_window_samples` is truncated rather than
    /// refused. The seam publishes that bound and the caller clamps to it
    /// already; this is the backend declining to trust that, in the one
    /// direction where being wrong would be a buffer overrun.
    pub fn upload(self: *Renderer, window: []const f32) void {
        platform.assertNotMainThread();
        markRenderThread();

        const n = @min(window.len, iface.max_window_samples);
        @memcpy(self.window[0..n], window[0..n]);
        self.window_len = n;
    }

    /// [render-thread] Draw and present one frame.
    ///
    /// Driven by the display link, which is why it takes no arguments: what it
    /// draws arrived through `upload` and everything else about a frame is
    /// already this object's. A frame that cannot be drawn is skipped rather
    /// than escalated, and the caller has nothing to decide.
    ///
    /// It does report what happened, which is a different thing from failing.
    /// Nobody outside can otherwise distinguish a loop presenting frames from
    /// one skipping every single tick, and those look identical from the far
    /// side of a flat colour. ADR 0013 names that gap; this is the signal that
    /// closes it.
    pub fn frame(self: *Renderer) iface.Outcome {
        platform.assertNotMainThread();
        markRenderThread();

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        // The shader swap comes first, above both returns below, and those are
        // two different mistakes rather than one.
        //
        // **Above `.no_accumulation`** because that is the one skip here that
        // *persists*: `iface.Outcome` records that it lasts until a resize
        // succeeds, where the others describe a moment. A drain beneath it would
        // stop for as long as an allocation failure lasted, the watcher would sit
        // on a full slot refusing to recompile, and every later edit would do
        // nothing with no explanation.
        //
        // **Above the slot wait** because `.no_frame_slot` is what a loaded GPU
        // returns, and a run of them is exactly when someone is editing the
        // shader that caused it. Gating the fix on the problem stopping is
        // backwards, and the swap needs no slot: it touches no drawable, no
        // window buffer and no accumulation.
        //
        // This is state between ticks rather than part of a frame, which is the
        // same argument `Editor.tick` makes one layer up for its own mailbox.
        self.watcher.start(self.device);
        if (self.watcher.drain()) |fresh| {
            const outgoing = self.pipelines;
            self.pipelines = fresh;

            // Safe here and only here, on the rule `replaceAccumulation` already
            // leans on: a command buffer created through `-[MTLCommandQueue
            // commandBuffer]` retains every resource it references until it
            // completes, so this drops this object's claim and not the GPU's.
            // Every buffer still holding the outgoing set took its reference at
            // encode time in an earlier `frame`, and this one is not created
            // until further down.
            //
            // **What would break it**: releasing from the watcher thread instead,
            // which is the whole reason the mailbox exists; or a future that
            // reaches for `MTLIndirectCommandBuffer` or a pipeline state resident
            // in an argument buffer, neither of which takes that reference for
            // you.
            releasePipelines(outgoing);
        }

        // Taken once rather than re-read at each of the three binds below. The
        // swap above is the only thing that replaces it and runs on this thread
        // before this line, so re-reading would be safe today; a copy is what
        // keeps it safe by construction, because the failure it prevents is a
        // decay pass from one library and a resolve from another.
        const pipelines = self.pipelines;

        // Before the semaphore, so a tick with nowhere to draw takes no slot and
        // leaves the staged window alone. Checked every frame rather than once,
        // because a resize can fail at any point in an editor's life and a later
        // one can put this back.
        const accum = self.accum orelse return .no_accumulation;

        // Taken before the `defer` below is registered, deliberately: a failed
        // wait acquired nothing, and signalling on the way out would hand back
        // a slot that was never held and let the semaphore climb past its
        // starting value.
        const sema: *anyopaque = @ptrCast(self.in_flight.value.?);
        if (dispatch_semaphore_wait(sema, dispatch_time_now) != 0) return .no_frame_slot;

        // Every early return below has to give the slot back. This is the
        // classic way the pattern fails: three skipped frames in a row would
        // otherwise drain the semaphore to zero, and every later frame would be
        // refused a slot it could never get, stopping the render loop for good
        // rather than for a moment.
        var handed_off = false;
        defer if (!handed_off) {
            _ = dispatch_semaphore_signal(sema);
        };

        // Only here, once the wait has succeeded, is a slot known free. The
        // advance and the copy are both below that line rather than above it,
        // which is the whole ordering `Renderer.window` exists to describe.
        //
        // Advancing on every successful wait rather than on every presented
        // frame keeps the argument short: the wait proves at most
        // `max_frames_in_flight - 1` frames are outstanding, those hold the
        // slots immediately behind this one, and the one this now points at was
        // last used `max_frames_in_flight` encodes ago and has completed.
        self.slot = (self.slot + 1) % max_frames_in_flight;
        self.writeWindow();

        // Nil under load, and that is normal rather than an error: the
        // compositor is holding every drawable and the right answer is to let
        // this tick go. Treating it as a failure is how a render loop turns a
        // busy moment into a visible stall.
        const drawable = self.layer.msgSend(objc.Object, "nextDrawable", .{});
        if (drawable.value == null) return .no_drawable;

        // The half the beam deposits into this frame, and the half it reads.
        // They swap only once the command buffer below is committed, which is
        // what leaves the pair untouched on every early return between here and
        // there: the source still holds valid energy and the target holds stale
        // data the next frame's decay draw overwrites completely.
        const source = accum[self.accum_source];
        const target = accum[self.accum_source ^ 1];

        // Both can be nil under memory pressure or device loss, and both are
        // skipped on the same reasoning as `nextDrawable` above.
        //
        // The hazard is not a crash. Messaging nil is a no-op that returns nil,
        // so the encoding calls below would quietly do nothing. It is the two
        // calls after them: a command buffer that exists but had nothing
        // encoded into it still presents and commits, handing the compositor a
        // drawable whose contents were never written. That shows as one frame
        // of whatever the texture happened to hold, which is a worse outcome
        // than the dropped frame skipping produces.
        const buffer = self.queue.msgSend(objc.Object, "commandBuffer", .{});
        if (buffer.value == null) return .no_command_buffer;

        const encoder = buffer.msgSend(objc.Object, "renderCommandEncoderWithDescriptor:", .{
            accumulationPass(target),
        });
        if (encoder.value == null) return .no_encoder;

        const accum_uniforms: AccumUniforms = .{};

        // Two pipelines, one encoder, one render pass, decay first. This
        // hardware is tile-based deferred, so both draws run against tile memory
        // and are written out once by the store action. A second encoder here
        // would end the pass, store the whole attachment and reload it, which is
        // two round trips through the framebuffer for an identical picture.
        //
        // That argument is why the *resolve* is a second pass and these two are
        // not: it has a different attachment, and the accumulation has to be
        // stored before anything can read it as a texture.
        //
        // A fullscreen triangle, which is cheaper than a quad and needs no
        // vertex buffer: the vertex function derives its positions from the
        // vertex id alone.
        encoder.msgSend(void, "setRenderPipelineState:", .{pipelines.decay});
        encoder.msgSend(void, "setFragmentTexture:atIndex:", .{ source, accumulation_texture_index });
        encoder.msgSend(void, "setFragmentBytes:length:atIndex:", .{
            &accum_uniforms,
            @as(u64, @sizeOf(AccumUniforms)),
            accum_uniform_index,
        });
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
            mtl.primitive_type_triangle,
            @as(u64, 0),
            @as(u64, 3),
        });

        // Only the draw is skipped, never the frame. The decay above was
        // encoded and this tick goes on to present it, so `.presented` stays the
        // truthful answer, and that direction matters as much as the familiar
        // one: an early return here would report a frame that did reach the
        // screen as one that did not, and `src/smoke.zig`'s `waitForFrames`
        // would time out waiting for it. Skipping it is also not theoretical.
        // `window_len` is zero until the first upload, so an editor opened on a
        // plugin the host has not activated sits here for as long as that lasts.
        if (traceVertices(self.window_len)) |count| {
            encoder.msgSend(void, "setRenderPipelineState:", .{pipelines.trace});

            // An encoder retains what it binds until its command buffer
            // completes, which is the retain `deinit` leans on. A frame that
            // binds nothing is also a frame whose buffer the GPU never reads, so
            // that argument survives the guard above intact.
            encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
                self.windows[self.slot],
                @as(u64, 0),
                window_buffer_index,
            });

            // Copied into the command buffer at encode time, so this local dying
            // with `frame` is not a lifetime to reason about. Built from the same
            // `count` the draw below uses rather than reading `window_len` a
            // second time: the vertex count and the divisor the shader maps x
            // with have to be one number, and two reads is how they stop being.
            const uniforms: TraceUniforms = .{ .sample_count = count };
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{
                &uniforms,
                @as(u64, @sizeOf(TraceUniforms)),
                uniform_buffer_index,
            });

            encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
                mtl.primitive_type_line_strip,
                @as(u64, 0),
                @as(u64, count),
            });
        }

        encoder.msgSend(void, "endEncoding", .{});

        // Pass two, onto the drawable. A second descriptor and a second encoder,
        // because the attachment is different; `DontCare` because the fullscreen
        // triangle covers every pixel, which is also what retired the load
        // action's clear and the `background` colour that went with it.
        const resolve_pass_descriptor = drawablePass();
        const resolve_attachment = colorAttachment(resolve_pass_descriptor);
        resolve_attachment.msgSend(void, "setTexture:", .{drawable.msgSend(objc.Object, "texture", .{})});

        const resolver = buffer.msgSend(objc.Object, "renderCommandEncoderWithDescriptor:", .{
            resolve_pass_descriptor,
        });
        // Returned without committing, deliberately. The `defer` hands the slot
        // back, no completion handler was registered, and `accum_source` has not
        // advanced, so pass one's encoded-but-never-executed work leaves the
        // accumulation exactly where it was.
        if (resolver.value == null) return .no_encoder;

        resolver.msgSend(void, "setRenderPipelineState:", .{pipelines.resolve});
        resolver.msgSend(void, "setFragmentTexture:atIndex:", .{ target, accumulation_texture_index });
        resolver.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
            mtl.primitive_type_triangle,
            @as(u64, 0),
            @as(u64, 3),
        });
        resolver.msgSend(void, "endEncoding", .{});

        // The slot now belongs to this command buffer, and comes back when the
        // GPU is finished with it. Registered before `commit`, because after it
        // the buffer may already have completed.
        var completion = Completion.init(.{ .sema = self.in_flight.value }, signalCompleted);
        buffer.msgSend(void, "addCompletedHandler:", .{&completion});
        handed_off = true;

        buffer.msgSend(void, "presentDrawable:", .{drawable});
        buffer.msgSend(void, "commit", .{});

        // Only now, and the asymmetry with `slot` above is deliberate. `slot`
        // advances on a successful wait, because a successful wait is what
        // proves the buffer is free. This advances on a commit, because a commit
        // is what proves the target was written. Two invariants, two points.
        self.accum_source ^= 1;

        return .presented;
    }

    /// [thread-safe] Window buffers this process has taken and not given back.
    ///
    /// Zero whenever no editor is open, and the only check in this project that
    /// can see a leaked one at all: see `live_windows` for the measurement that
    /// establishes `leaks` cannot. `src/smoke.zig` is the caller, on `probe`'s
    /// precedent, and like `probe` this is a question any second backend would
    /// have to answer rather than a hook shaped to this one's tests.
    pub fn liveWindowBuffers() usize {
        return live_windows.load(.acquire);
    }

    /// [thread-safe] Accumulation textures this process has taken and not given
    /// back.
    ///
    /// Zero whenever no editor is open, and the **only** check in this project
    /// that can see a leaked one at all. `leaks` cannot, and unlike the window
    /// buffers neither can peak RSS: see `live_textures` for both measurements.
    /// A second backend would have to answer this question too, which is what
    /// keeps it a seam operation rather than a hook shaped to this one's tests.
    pub fn liveAccumulationTextures() usize {
        return live_textures.load(.acquire);
    }

    /// [thread-safe] What this process has done about the shader on disk.
    ///
    /// The one observable of hot reload, and it exists for the reason ADR 0013
    /// gives for `framesPresented`: the thing the feature changes is the picture,
    /// and the picture is precisely what nothing here can see. All zero and
    /// `path_resolved = false` in a release build, permanently, because nothing there
    /// reads a file.
    ///
    /// **The counters cannot tell a swap that used the new bytes from one that
    /// recompiled the old ones**, which is why `src/smoke.zig` pairs them with a
    /// fixture only the new bytes could produce a diagnostic for.
    pub fn shaderStats() iface.ShaderStats {
        return .{
            .path_resolved = shader_path_resolved.load(.acquire),
            .reloads = shader_reloads.load(.acquire),
            .rejected = shader_rejected.load(.acquire),
            .fallbacks = shader_fallbacks.load(.acquire),
        };
    }

    /// [render-thread] Copy staging into this frame's buffer.
    ///
    /// Split out of `frame` only so the ordering rule has somewhere to be
    /// stated once: the caller must already hold the slot. It is not safe from
    /// anywhere else.
    ///
    /// `contents` is a mapped pointer on a shared-storage buffer rather than a
    /// call that can fail, so the null check is defensive against a buffer that
    /// is somehow not the one `buildWindows` made. Skipping the copy leaves the
    /// previous window in place, which is the same outcome a torn read produces
    /// and is preferable to writing through null.
    fn writeWindow(self: *Renderer) void {
        const target = self.windows[self.slot];
        const contents = target.msgSend(?*anyopaque, "contents", .{}) orelse return;

        const dst: [*]f32 = @ptrCast(@alignCast(contents));
        @memcpy(dst[0..self.window_len], self.window[0..self.window_len]);
    }
};

/// Vertices in this frame's line strip, or nothing when there is no line.
///
/// Three separate reasons land on the same threshold and each would fail
/// differently. A strip needs two endpoints before it has a segment. Metal
/// rejects a `vertexCount` of zero outright, which under the validation layer is
/// a terminated process rather than a dropped draw. And `trace_vertex` divides by
/// `sample_count - 1`, which is zero at one sample. A window of one is reachable
/// rather than hypothetical: `gui.windowSamples` returns it for every rate from
/// 50 to 99 Hz, and `activate` accepts rates from 1 Hz up.
///
/// The narrowing cast is load-bearing rather than defensive. `upload` is the only
/// writer of `window_len` and clamps to `max_window_samples` already, so this
/// cannot truncate; what it does is produce the `uint` MSL reads. Re-clamping
/// here would state that bound in a third place.
fn traceVertices(window_len: usize) ?u32 {
    if (window_len < 2) return null;
    return @intCast(window_len);
}

/// The per-frame window buffers, all of them or none.
///
/// Separate from `init` because its undo is not the one-line `errdefer` the
/// acquisitions around it use: a failure partway through leaves buffers already
/// taken, and the count of those is what has to be released.
///
/// Shared storage, because the CPU rewrites these every frame and the GPU reads
/// each once. Sized from the seam's bound rather than from the drawable, which
/// is what keeps `resize` out of this entirely: a window's length follows the
/// sample rate, and nothing about it changes when a window is dragged.
fn buildWindows(device: objc.Object, diags: *iface.Diagnostics) iface.Error![max_frames_in_flight]objc.Object {
    var windows: [max_frames_in_flight]objc.Object = undefined;

    var taken: usize = 0;
    errdefer for (windows[0..taken]) |buffer| buffer.release();

    while (taken < max_frames_in_flight) : (taken += 1) {
        const buffer = device.msgSend(objc.Object, "newBufferWithLength:options:", .{
            @as(u64, iface.max_window_samples * @sizeOf(f32)),
            @as(u64, mtl.resource_storage_mode_shared),
        });
        if (buffer.value == null) {
            diags.set("the Metal device would not allocate a per-frame window buffer");
            return error.BufferAllocationFailed;
        }
        windows[taken] = buffer;
    }

    // Counted only once the whole ring is in hand, which pairs with
    // `releaseWindows` giving the whole ring back. A partial failure released
    // what it took through the `errdefer` above and reports nothing here,
    // because it is handing back buffers this count never included.
    _ = live_windows.fetchAdd(max_frames_in_flight, .release);

    return windows;
}

/// The accumulation pair, allocated and cleared, or neither.
///
/// Both or none, on `buildWindows`' shape and for its reason: a failure partway
/// through has to hand back what it already took.
///
/// **The clear is part of this function rather than a step beside it**, so that
/// "an allocated accumulation holds defined data" is a property of one call
/// instead of a property of a call sequence somebody has to keep in order.
/// `newTextureWithDescriptor:` does not contract that it returns zeroed memory,
/// and the consequence of trusting the zero fill Apple Silicon happens to
/// perform is not a transient smudge: an `RGBA16F` full of arbitrary bits is
/// very likely full of NaNs, and a NaN multiplied by any decay factor is a NaN
/// forever. That is a permanently ruined screen, not a first frame worth
/// ignoring.
fn buildAccumulation(
    device: objc.Object,
    queue: objc.Object,
    pixels: Pixels,
    diags: *iface.Diagnostics,
) iface.Error![2]objc.Object {
    const descriptor = objc.getClass("MTLTextureDescriptor").?.msgSend(
        objc.Object,
        "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
        .{ accumulation_pixel_format, @as(u64, pixels.width), @as(u64, pixels.height), false },
    );
    if (descriptor.value == null) {
        diags.set("Metal would not describe an accumulation texture");
        return error.TextureAllocationFailed;
    }

    // Both bits, and the render-target one is the whole ballgame: without it
    // `renderCommandEncoderWithDescriptor:` returns nil rather than failing
    // loudly. See the constants for what that looks like from the outside.
    descriptor.msgSend(void, "setUsage:", .{mtl.texture_usage_render_target | mtl.texture_usage_shader_read});
    descriptor.msgSend(void, "setStorageMode:", .{mtl.storage_mode_private});

    var pair: [2]objc.Object = undefined;

    var taken: usize = 0;
    errdefer for (pair[0..taken]) |texture| texture.release();

    while (taken < pair.len) : (taken += 1) {
        const texture = device.msgSend(objc.Object, "newTextureWithDescriptor:", .{descriptor});
        if (texture.value == null) {
            diags.set("the Metal device would not allocate an accumulation texture");
            return error.TextureAllocationFailed;
        }
        pair[taken] = texture;
    }

    try clearAccumulation(queue, pair, diags);

    // Counted only once the whole pair is in hand, which pairs with
    // `releaseAccumulation` giving the whole pair back. A partial failure
    // released what it took through the `errdefer` above and reports nothing
    // here, because it is handing back textures this count never included.
    _ = live_textures.fetchAdd(pair.len, .release);

    return pair;
}

/// Zero both textures, on the GPU, without waiting for it.
///
/// Two render passes that clear and store and draw nothing, which is the
/// cheapest way to write a known value into a private texture: no blit, no
/// staging buffer, and nothing the CPU has to be able to see.
///
/// **Both, rather than only the one the next frame reads.** The second is a
/// target before it is ever a source, so clearing it is arguably redundant
/// today; it stops being redundant the moment anything changes which index is
/// read first, and the invariant is worth more than the microsecond.
///
/// Committed and not waited on. Nothing here may add an unbounded wait, because
/// `Editor.tick` holds the gate across its whole body and `Gate.close` spins on
/// the host's main thread; queue ordering already guarantees this lands before
/// the frame that reads it, which is all the ordering that is needed.
///
/// **It fails closed, and that is the whole reason it returns an error.** A nil
/// command buffer or a nil encoder is rare, and `frame` already treats both as
/// real machine conditions rather than programming errors. Skipping the clear
/// on one would hand back a pair whose contents are whatever the driver left
/// there, and `buildAccumulation` would go on to report it as allocated and
/// cleared. Uninitialized `RGBA16F` is very likely a NaN, `NaN * decay` is a NaN
/// forever, and nothing later in the frame can recover from it: that is the
/// permanently ruined screen this function exists to prevent, reached by the one
/// path that skipped it. Refusing instead leaves `accum` null and costs a
/// skipped frame until a resize succeeds, which is recoverable.
fn clearAccumulation(queue: objc.Object, pair: [2]objc.Object, diags: *iface.Diagnostics) iface.Error!void {
    const buffer = queue.msgSend(objc.Object, "commandBuffer", .{});
    if (buffer.value == null) {
        diags.set("the command queue would not produce a buffer to clear the accumulation");
        return error.TextureAllocationFailed;
    }

    for (pair) |texture| {
        const pass = objc.getClass("MTLRenderPassDescriptor").?
            .msgSend(objc.Object, "renderPassDescriptor", .{});
        const attachment = colorAttachment(pass);
        attachment.msgSend(void, "setTexture:", .{texture});
        attachment.msgSend(void, "setLoadAction:", .{mtl.load_action_clear});
        attachment.msgSend(void, "setStoreAction:", .{mtl.store_action_store});
        attachment.msgSend(void, "setClearColor:", .{cleared});

        const encoder = buffer.msgSend(objc.Object, "renderCommandEncoderWithDescriptor:", .{pass});
        if (encoder.value == null) {
            diags.set("an accumulation texture could not be cleared");
            return error.TextureAllocationFailed;
        }
        encoder.msgSend(void, "endEncoding", .{});
    }

    buffer.msgSend(void, "commit", .{});
}

/// Give the pair back, and say so.
///
/// The one release site, on `releaseWindows`' precedent and for its reason: a
/// second bare release loop somewhere else would leave the count drifting from
/// the releases with nothing to notice.
///
/// **This carries an obligation `live_windows` never had.** Window buffers are
/// allocated once in `init` and released once in `deinit`, so their count moves
/// twice in a renderer's life. These are reallocated on every resize that
/// changes the pixel count, which in a drag is most ticks, so the resize path
/// has to decrement too. It does, because `replaceAccumulation` reaches it
/// rather than releasing by hand.
fn releaseAccumulation(pair: [2]objc.Object) void {
    for (pair) |texture| texture.release();
    _ = live_textures.fetchSub(pair.len, .release);
}

/// Give a whole ring back, and say so.
///
/// The one place window buffers are released, which is what stops the count
/// drifting from the releases: `probe` takes a ring and hands it straight back,
/// and a second bare release loop there would have left the count high forever.
fn releaseWindows(windows: [max_frames_in_flight]objc.Object) void {
    for (windows) |buffer| buffer.release();
    _ = live_windows.fetchSub(max_frames_in_flight, .release);
}

/// Compile the embedded source once and assemble every pass's pipeline state
/// from it, all of them or none.
///
/// One library rather than one per pass, which is the expensive half of this
/// call: see `Pipelines`. The compile's failure carries the `NSError`'s text into
/// `diags`, because a Metal compiler diagnostic names a file, a line, and the
/// mistake, and losing it would leave a developer with nothing but an editor that
/// refused to open.
fn buildPipelines(device: objc.Object, diags: *iface.Diagnostics) iface.Error!Pipelines {
    // **The editor opens whatever is on disk**, which is the invariant that can
    // otherwise ruin a day: a debug build whose shader file has a typo in it, or
    // has been moved away, must still start. So the disk copy is tried and the
    // embedded one is the answer whenever it does not work, for either reason.
    //
    // This lives here, above `init` and `probe` rather than at either call site,
    // because ADR 0013 rests on `probe` *sharing* this function rather than
    // paraphrasing it. That is also what makes the fallback testable without a
    // window, since `zig build smoke-gpu` reaches exactly this path.
    if (comptime shader.live) {
        // A stack buffer rather than a field, because this is called from three
        // threads and none of them may allocate. 64 KiB against an 8 MiB
        // main-thread stack and a 16 MiB spawned one, for a file currently eight.
        var buf: shader.Buffer = .{};

        if (readShader(&buf)) |source| {
            if (buildPipelinesFromSource(device, source, diags)) |pipelines| {
                _ = shader_reloads.fetchAdd(1, .release);
                return pipelines;
            } else |_| {
                // Counted separately from the read failure above, because they
                // are different mistakes: one is a path that is wrong, the other
                // is a shader that is. `diags` already carries the compiler's own
                // text, naming a line and the error.
                _ = shader_rejected.fetchAdd(1, .release);
                sayShader("{s}; using the copy built into this binary", .{diags.message()});
                _ = shader_fallbacks.fetchAdd(1, .release);
            }
        }
    }

    return buildPipelinesFromSource(device, shader_source, diags);
}

/// Read the watched file, or null if there is not one this build can use.
///
/// **Says so once rather than every time.** Silently would be defensible and is
/// worse: an editor that opens showing yesterday's shader with no explanation is
/// the kind of thing that gets blamed on the GPU. Once, because the watcher asks
/// this four times a second and a missing file is a state that persists.
fn readShader(buf: *shader.Buffer) ?[:0]const u8 {
    var path_buf: shader.PathBuffer = undefined;
    const path = shader.resolvePath(&path_buf) orelse return null;
    shader_path_resolved.store(true, .release);

    shader.read(buf, path) catch |err| {
        if (shader_fallbacks.fetchAdd(1, .release) == 0) {
            sayShader("cannot read {s} ({t}); using the copy built into this binary", .{ path, err });
        }
        return null;
    };

    return buf.source();
}

/// The same, from a source this file did not embed.
///
/// A separate function rather than a parameter with a default, which Zig does not
/// have. Everything above still calls `buildPipelines`, so `shader_source` is
/// named in one place and ADR 0013's "`probe` shares rather than paraphrases"
/// property holds by construction rather than by two call sites agreeing.
///
/// `MTLDevice` is documented safe to message from any thread, which is what lets
/// the watcher compile off both the main thread and the render thread. Nothing
/// here touches AppKit, a `Renderer`, or any shared state, so it needs no thread
/// assertion of its own.
///
/// `[:0]const u8` rather than `[*:0]const u8` so the parameter's type is
/// `shader_source`'s type and the wrapper above is a pass-through.
fn buildPipelinesFromSource(
    device: objc.Object,
    source: [:0]const u8,
    diags: *iface.Diagnostics,
) iface.Error!Pipelines {
    // The one place this is enforced, because it is the one call that is slow.
    // `init` and `probe` reach it from the main thread and the watcher from its
    // own; a display-link thread reaching it is the defect the watcher exists to
    // prevent, and nothing else here can see it.
    assertNotRenderThread();

    var err: ?*anyopaque = null;

    const library = device.msgSend(objc.Object, "newLibraryWithSource:options:error:", .{
        platform.nsString(source.ptr),
        @as(?*anyopaque, null),
        &err,
    });
    if (library.value == null) {
        describe(err, diags, "the shader source did not compile");
        return error.ShaderCompilationFailed;
    }
    defer library.release();

    const decay = try buildPipeline(device, library, decay_pass, diags);
    errdefer decay.release();

    const trace = try buildPipeline(device, library, trace_pass, diags);
    errdefer trace.release();

    const resolve = try buildPipeline(device, library, resolve_pass, diags);

    return .{ .decay = decay, .trace = trace, .resolve = resolve };
}

/// Give every pass's state back, and the one place either is released.
///
/// `releaseWindows`' shape, for `releaseWindows`' reason: `probe` takes a set and
/// hands it straight back, and a second bare release loop there is how the two
/// sites drift.
fn releasePipelines(pipelines: Pipelines) void {
    pipelines.resolve.release();
    pipelines.trace.release();
    pipelines.decay.release();
}

/// One pass's state, pulled out of an already-compiled library.
fn buildPipeline(
    device: objc.Object,
    library: objc.Object,
    comptime pass: Pass,
    diags: *iface.Diagnostics,
) iface.Error!objc.Object {
    const vertex = library.msgSend(objc.Object, "newFunctionWithName:", .{platform.nsString(pass.vertex)});
    const fragment = library.msgSend(objc.Object, "newFunctionWithName:", .{platform.nsString(pass.fragment)});
    defer vertex.release();
    defer fragment.release();

    // A library that compiled but lacks a function means the shader was edited
    // and one of the names above was not, which is a mismatch worth naming
    // precisely rather than reporting as a generic pipeline failure.
    if (vertex.value == null or fragment.value == null) {
        diags.set("the shader compiled but does not define " ++ pass.vertex ++ " and " ++ pass.fragment);
        return error.PipelineCreationFailed;
    }

    const descriptor = objc.getClass("MTLRenderPipelineDescriptor").?
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer descriptor.release();

    descriptor.msgSend(void, "setVertexFunction:", .{vertex});
    descriptor.msgSend(void, "setFragmentFunction:", .{fragment});

    const attachment = colorAttachment(descriptor);

    // The format the state is compiled against, and the reason `Pass` carries
    // it. The prediction the comment here used to make came true exactly as
    // written: the additive trace now lands on an accumulation texture rather
    // than on the drawable, so it is additive against the right surface and the
    // background is no longer underneath it to tint the result.
    attachment.msgSend(void, "setPixelFormat:", .{pass.pixel_format});

    if (pass.blending == .additive) {
        attachment.msgSend(void, "setBlendingEnabled:", .{true});
        attachment.msgSend(void, "setRgbBlendOperation:", .{mtl.blend_operation_add});
        attachment.msgSend(void, "setAlphaBlendOperation:", .{mtl.blend_operation_add});
        attachment.msgSend(void, "setSourceRGBBlendFactor:", .{mtl.blend_factor_one});
        attachment.msgSend(void, "setDestinationRGBBlendFactor:", .{mtl.blend_factor_one});
        attachment.msgSend(void, "setSourceAlphaBlendFactor:", .{mtl.blend_factor_one});
        attachment.msgSend(void, "setDestinationAlphaBlendFactor:", .{mtl.blend_factor_one});
    }

    var err: ?*anyopaque = null;
    const pipeline = device.msgSend(objc.Object, "newRenderPipelineStateWithDescriptor:error:", .{
        descriptor,
        &err,
    });
    if (pipeline.value == null) {
        describe(err, diags, "the " ++ pass.fragment ++ " pipeline state could not be built");
        return error.PipelineCreationFailed;
    }

    return pipeline;
}

/// Create the layer and make the host's view host it.
///
/// `setLayer:` before `setWantsLayer:`, which is what makes the view
/// layer-hosting rather than layer-backed. Reversing the two lets AppKit
/// install a layer of its own first, and the Metal layer then becomes a
/// sublayer that does not track the view's geometry.
/// Takes both units on purpose. The layer's `frame` is logical points, because
/// it is a view's geometry; its `drawableSize` is backing pixels, because it is
/// a texture's. Deriving one from the other here would put a second rounding
/// rule beside `backingPixels`, which is the thing that file-level comment
/// exists to prevent.
fn attachLayer(
    view: iface.NativeView,
    device: objc.Object,
    size: iface.Size,
    pixels: Pixels,
    scale: f64,
    diags: *iface.Diagnostics,
) iface.Error!objc.Object {
    // `+layer` hands back an autoreleased object and this one outlives the
    // pool, so it is retained here and released in `deinit`.
    const layer = objc.getClass("CAMetalLayer").?.msgSend(objc.Object, "layer", .{});
    if (layer.value == null) {
        diags.set("CAMetalLayer would not create a layer");
        return error.SurfaceCreationFailed;
    }
    _ = layer.retain();
    errdefer layer.release();

    const bounds: CGRect = .{ .size = logicalSize(size) };

    layer.msgSend(void, "setDevice:", .{device});
    layer.msgSend(void, "setPixelFormat:", .{drawable_pixel_format});
    // Nothing reads back from the drawable, which lets Metal choose a cheaper
    // storage mode. Phase 3's accumulation textures are separate from it.
    layer.msgSend(void, "setFramebufferOnly:", .{true});
    // Stated rather than inherited. Three is already the default, and it is the
    // other half of the frame bound the semaphore sets: writing it down is what
    // keeps the two from drifting apart if one is ever tuned.
    layer.msgSend(void, "setMaximumDrawableCount:", .{@as(u64, max_frames_in_flight)});
    layer.msgSend(void, "setContentsScale:", .{scale});
    layer.msgSend(void, "setDrawableSize:", .{drawableSize(pixels)});
    layer.msgSend(void, "setFrame:", .{bounds});

    const host_view = objc.Object.fromId(view);
    host_view.msgSend(void, "setLayer:", .{layer});
    host_view.msgSend(void, "setWantsLayer:", .{true});

    return layer;
}

/// A render pass writing into one half of the accumulation.
///
/// `DontCare` rather than `Load` or `Clear` because the decay draw covers every
/// pixel with an opaque write, so whatever the target held is overwritten in
/// full. On a tile-based GPU that means the tile is never loaded, which is the
/// cheapest of the three and the only one that is not doing work twice.
fn accumulationPass(target: objc.Object) objc.Object {
    const pass = objc.getClass("MTLRenderPassDescriptor").?
        .msgSend(objc.Object, "renderPassDescriptor", .{});
    const attachment = colorAttachment(pass);
    attachment.msgSend(void, "setTexture:", .{target});
    attachment.msgSend(void, "setLoadAction:", .{mtl.load_action_dont_care});
    attachment.msgSend(void, "setStoreAction:", .{mtl.store_action_store});
    return pass;
}

/// A render pass writing into the drawable, whose texture the caller sets.
///
/// `DontCare` for the same reason, and that is what retired the clear colour
/// this file used to hold in step with the shader by hand: the resolve covers
/// every pixel and emits the background itself where no energy has landed, so
/// there is no longer a second place for it to be wrong.
fn drawablePass() objc.Object {
    const pass = objc.getClass("MTLRenderPassDescriptor").?
        .msgSend(objc.Object, "renderPassDescriptor", .{});
    const attachment = colorAttachment(pass);
    attachment.msgSend(void, "setLoadAction:", .{mtl.load_action_dont_care});
    attachment.msgSend(void, "setStoreAction:", .{mtl.store_action_store});
    return pass;
}

/// The layer's `colorAttachments[0]`, which Objective-C reaches through
/// subscripting rather than a named accessor.
fn colorAttachment(descriptor: objc.Object) objc.Object {
    return descriptor.msgSend(objc.Object, "colorAttachments", .{})
        .msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(u64, 0)});
}

fn logicalSize(size: iface.Size) CGSize {
    return .{
        .width = @floatFromInt(size.width),
        .height = @floatFromInt(size.height),
    };
}

/// Logical points to whole backing pixels. Cocoa hands out points, so this is
/// the one place the scale factor is applied and **the one place the result
/// becomes an integer**.
///
/// Both halves of that matter, and the second one is new. Getting the scale
/// wrong is a blurry render rather than a failure, which is why it was already
/// worth stating once. Rounding it twice is worse than either: `Pending.Packed`
/// quantizes the scale to 1/256ths, so a scale that is not exactly 1 or 2
/// produces a fractional pixel count, and if this file truncated where
/// `CAMetalLayer` rounded, an accumulation texture sized from here would be a
/// pixel narrower than the drawable sized from there. A fragment reading one at
/// the other's coordinates would then be out of bounds, which MSL does not
/// define as a benign zero.
///
/// Saturating rather than `@intFromFloat`, which is illegal behaviour out of
/// range, on `gui.windowSamples`' precedent and for its reason: nothing in the
/// type system stops a caller handing over a scale this cannot represent, and
/// the answer to one has to be a number rather than a panic.
///
/// Floored at one pixel per axis. Metal rejects a zero-dimension texture, and
/// the smallest editor `gui.clampSize` permits at the smallest scale
/// `Pending.Packed` can encode still rounds to at least one, so this guards a
/// case the callers already exclude rather than one they produce. The test at
/// the foot of this file is what ties those two bounds together.
fn backingPixels(size: iface.Size, scale: f64) Pixels {
    const logical = logicalSize(size);
    return .{
        .width = @max(1, std.math.lossyCast(u32, @round(logical.width * scale))),
        .height = @max(1, std.math.lossyCast(u32, @round(logical.height * scale))),
    };
}

/// The same pixels as a `CGSize`, which is what `setDrawableSize:` takes.
///
/// Separate from `backingPixels` so the integer is what travels and the float is
/// only ever the last step. Handing the layer a size built from whole pixels is
/// what makes the drawable and everything sized beside it agree by construction.
fn drawableSize(pixels: Pixels) CGSize {
    return .{
        .width = @floatFromInt(pixels.width),
        .height = @floatFromInt(pixels.height),
    };
}

/// Copy an `NSError`'s description into `diags`, falling back to a fixed line
/// when the call failed without producing one, which hosts and drivers do.
fn describe(err: ?*anyopaque, diags: *iface.Diagnostics, fallback: []const u8) void {
    const object = objc.Object.fromId(err orelse {
        diags.set(fallback);
        return;
    });

    const text = platform.utf8(object.msgSend(objc.Object, "localizedDescription", .{}));
    diags.set(if (text.len > 0) text else fallback);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// No test constructs a `Renderer` or sends a message. Acquiring a GPU would
// make `zig build test` depend on the runner having one, which is the
// non-hermetic build ADR 0009 exists to avoid. What is left is arithmetic and
// the embedded source, and both are worth pinning.

test {
    // Zig analyses function bodies only when something references them, so
    // without this the message sends below are parsed and never type-checked
    // until `gui.zig` first calls them. Referencing them here is what turns a
    // wrong selector signature into a compile error in the file that owns it.
    //
    // `setVertexBytes:length:atIndex:` is the newest thing leaning on that, and
    // the lean is total: nothing in `zig build test` reaches `frame`, so this
    // block is the only place its signature is checked at all.
    testing.refAllDecls(@This());
    testing.refAllDecls(Renderer);
}

test "the shader source is embedded and terminated for the C string API" {
    try testing.expect(shader_source.len > 0);
    try testing.expectEqual(@as(u8, 0), shader_source[shader_source.len]);
}

test "the embedded shader defines the functions every pipeline asks for" {
    // Cheap insurance against renaming one side and not the other, walked rather
    // than listed so a third pass is covered by being added to `passes`. It
    // proves only that the names appear, which is all a string can prove; `zig
    // build validate-shaders` proves the file compiles and `zig build smoke-gpu`
    // proves a pipeline state can be built from it.
    for (passes) |pass| {
        try testing.expect(std.mem.indexOf(u8, shader_source, pass.vertex) != null);
        try testing.expect(std.mem.indexOf(u8, shader_source, pass.fragment) != null);
    }
}

/// The index MSL attaches to the first parameter matching `needle`, by reading
/// the `[[<kind>(N)]]` that follows it.
///
/// Searching for the bare attribute is what this replaces, and the difference is
/// the whole point. `buffer(0)` appears in this shader whatever the Zig side
/// says, so a test that only asks whether the string is present passes when two
/// indices are swapped, or when one declaration drifts and another happens to
/// still use the number. Anchoring on the declaration ties an index to the
/// parameter that has to carry it.
fn bindingIndexAfter(comptime needle: []const u8, comptime kind: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, shader_source, needle) orelse return null;
    const rest = shader_source[start..];

    const opener = "[[" ++ kind ++ "(";
    const at = std.mem.indexOf(u8, rest, opener) orelse return null;
    const digits = rest[at + opener.len ..];
    const end = std.mem.indexOfScalar(u8, digits, ')') orelse return null;

    return std.fmt.parseInt(u64, digits[0..end], 10) catch null;
}

test "every binding the encoder sets is read at the same index in the shader" {
    // The other half of five constants MSL states as literals inside attributes,
    // against a coupling with no compiler behind it at all: binding at one index
    // and reading at another is a validation failure that surfaces inside a DAW,
    // on the render thread, with nothing printable.
    //
    // Anchored on each declaration rather than on the attribute alone, which is
    // what makes it non-vacuous. Fragment textures, fragment buffers and vertex
    // buffers are three separate index spaces, so three of these are zero and a
    // bare search for `buffer(0)` proves nothing about any of them.
    try testing.expectEqual(
        @as(?u64, window_buffer_index),
        bindingIndexAfter("device const float *samples", "buffer"),
    );
    try testing.expectEqual(
        @as(?u64, uniform_buffer_index),
        bindingIndexAfter("TraceUniforms &", "buffer"),
    );
    try testing.expectEqual(
        @as(?u64, accum_uniform_index),
        bindingIndexAfter("AccumUniforms &", "buffer"),
    );

    // Both fragments that read the accumulation, named separately because each
    // is a binding the encoder sets and either could drift alone.
    try testing.expectEqual(
        @as(?u64, accumulation_texture_index),
        bindingIndexAfter("access::read> source", "texture"),
    );
    try testing.expectEqual(
        @as(?u64, accumulation_texture_index),
        bindingIndexAfter("access::read> energy", "texture"),
    );
}

test "the binding reader finds nothing rather than guessing" {
    // The failure this has to avoid is answering `null` for a declaration that
    // moved and having that read as a pass. `expectEqual` against an optional
    // covers it, and this pins the two ways `null` is reached.
    try testing.expectEqual(@as(?u64, null), bindingIndexAfter("no such parameter", "buffer"));
    try testing.expectEqual(@as(?u64, null), bindingIndexAfter("AccumUniforms &", "sampler"));
}

/// The bare number following `needle`, for a Python assignment like `RAIL = 0.98`.
fn scalarAfter(comptime source: []const u8, comptime needle: []const u8) ?f64 {
    const start = std.mem.indexOf(u8, source, needle) orelse return null;
    const rest = source[start + needle.len ..];

    const end = std.mem.indexOfNone(u8, rest, "0123456789.+-eE") orelse rest.len;
    if (end == 0) return null;

    return std.fmt.parseFloat(f64, rest[0..end]) catch null;
}

/// Exactly `n` comma-separated numbers from the first `opener` following `anchor`.
///
/// Two needles rather than one, because the MSL side cannot be reached with a
/// single search. `float3(0.02, 0.02, 0.03)` sits inside a `return float4(...)`,
/// and the first `(` after a fragment's name opens its *parameter list*; while
/// anchoring on `float3(` alone would be the vacuous search `bindingIndexAfter`
/// exists to avoid, since nothing ties that spelling to the function meant.
///
/// Exactly `n`, not at least `n`: a fourth component appearing in a Python tuple
/// has to fail rather than be ignored, which is the same reason the layout tests
/// above pin `@sizeOf` instead of checking that the fields they know about exist.
fn scalarsAfter(
    comptime source: []const u8,
    comptime anchor: []const u8,
    comptime opener: []const u8,
    comptime n: usize,
) ?[n]f64 {
    const at = std.mem.indexOf(u8, source, anchor) orelse return null;
    const rest = source[at + anchor.len ..];

    const open = std.mem.indexOf(u8, rest, opener) orelse return null;
    const body = rest[open + opener.len ..];
    const close = std.mem.indexOfScalar(u8, body, ')') orelse return null;

    var out: [n]f64 = undefined;
    var fields = std.mem.splitScalar(u8, body[0..close], ',');
    for (&out) |*value| {
        const field = std.mem.trim(u8, fields.next() orelse return null, " \t\n");
        value.* = std.fmt.parseFloat(f64, field) catch return null;
    }
    if (fields.next() != null) return null;

    return out;
}

test "the screenshot tool still holds this project's numbers" {
    // `scripts/measure-trace` is the only instrument that answers what the pixels
    // became, which is the gap #51 exists to close and which nothing automated
    // here can see. It restates four constants it does not own: two from the seam
    // and two from this shader, in a third language, with nothing linking any of
    // them. A constant that moved would leave it reporting confident numbers
    // against the old mapping, which is the failure the layout tests above are
    // also about and is worse here, because these numbers get published.
    //
    // Embedded inside the test rather than at file scope, so a plain `zig build`
    // never analyses it: `build.zig` registers this import on the test module
    // alone, and no shipping artifact carries a Python script's bytes.
    const script = @embedFile("measure-trace");

    // The seam's two, compared at f32 rather than f64. `trace_full_scale` is an
    // f32 holding the nearest representable 0.9, and widening that to f64 gives
    // 0.899999976..., which is not the 0.9 `parseFloat` returns from the text.
    // Narrowing the parsed value is the comparison that means what it looks like.
    const full_scale = scalarAfter(script, "FULL_SCALE = ") orelse return error.NotFound;
    const rail = scalarAfter(script, "RAIL = ") orelse return error.NotFound;
    try testing.expectEqual(iface.trace_full_scale, @as(f32, @floatCast(full_scale)));
    try testing.expectEqual(iface.trace_rail, @as(f32, @floatCast(rail)));

    // The shader's two. Both sides spell these the same way, so the parsed f64s
    // are bit-identical and no narrowing is needed.
    //
    // The script's crop depends on the first: it locates this plugin's surface
    // inside a window capture by looking for exactly the background, and the
    // guard that refuses a recompressed capture depends on both, because it
    // predicts red and blue from green along the ray they define.
    const background = scalarsAfter(script, "BACKGROUND = ", "(", 3) orelse return error.NotFound;
    const beam = scalarsAfter(script, "BEAM = ", "(", 3) orelse return error.NotFound;

    const written = scalarsAfter(
        shader_source,
        "fragment float4 " ++ resolve_pass.fragment,
        "float3(",
        3,
    ) orelse return error.NotFound;
    const deposited = scalarsAfter(
        shader_source,
        "fragment float4 " ++ trace_pass.fragment,
        "float4(",
        4,
    ) orelse return error.NotFound;

    try testing.expectEqualSlices(f64, &written, &background);
    try testing.expectEqualSlices(f64, deposited[0..3], &beam);

    // The deposit's alpha, which the script has no copy of and does not need: it
    // is here so the four-component read above cannot silently start matching a
    // three-component one that happens to sit where a `float4(` was.
    try testing.expectEqual(@as(f64, 1.0), deposited[3]);
}

test "the script reader finds nothing rather than guessing" {
    // Same reasoning as the binding reader's own negative test, and the same
    // hazard: a needle that stopped matching must fail rather than answer `null`
    // and have that read as a pass. Three ways `null` is reached, one per stage.
    const script = @embedFile("measure-trace");

    try testing.expectEqual(@as(?f64, null), scalarAfter(script, "NO_SUCH_CONSTANT = "));
    try testing.expectEqual(@as(?[3]f64, null), scalarsAfter(script, "NO_SUCH_TUPLE", "(", 3));

    // A constant that exists, read at the wrong arity. This is what stops a field
    // being added to one of the tuples and going unnoticed.
    try testing.expectEqual(@as(?[4]f64, null), scalarsAfter(script, "BEAM = ", "(", 4));
}

test "the accumulation's uniforms are laid out the way the shader reads them" {
    // MSL computes its own offsets from its own `AccumUniforms`, and nothing
    // links the two declarations. What this catches is a field added or
    // reordered on one side, whose symptom is a plausible picture at the wrong
    // brightness rather than anything that fails.
    try testing.expectEqual(@as(usize, 4), @sizeOf(AccumUniforms));
    try testing.expectEqual(@as(usize, 4), @alignOf(AccumUniforms));
    try testing.expectEqual(@as(usize, 0), @offsetOf(AccumUniforms, "decay"));
    try testing.expect(@sizeOf(AccumUniforms) <= 4096);
}

test "a frame both dims what is there and shows what is left" {
    // The range is the whole claim, and it is what makes two of this issue's
    // planted defects fail here rather than needing an eye. At 1.0 nothing
    // decays and the picture saturates; at 0.0 nothing persists and this change
    // reduces to the trace it replaced.
    try testing.expect(decay_per_frame > 0.0);
    try testing.expect(decay_per_frame < 1.0);
}

test "the uniforms carry the file's constants rather than a second copy of them" {
    // The defaults are the whole mechanism by which the shader learns both
    // numbers, so a `frame` that filled them in by hand would compile and draw
    // at whatever it chose. Same reasoning as the `TraceUniforms` test above.
    const uniforms: AccumUniforms = .{};

    try testing.expectEqual(decay_per_frame, uniforms.decay);
}

test "every pass names the format it is compiled against" {
    // Not an assertion that the constants say what they say: it is that the
    // trace deposits into the same surface the decay writes, and that exactly
    // one pass targets the drawable. Getting either wrong is a draw-time
    // validation failure `probe` never reaches, because it builds pipeline
    // states and never encodes against a texture.
    try testing.expectEqual(decay_pass.pixel_format, trace_pass.pixel_format);
    try testing.expectEqual(accumulation_pixel_format, trace_pass.pixel_format);
    try testing.expectEqual(drawable_pixel_format, resolve_pass.pixel_format);

    // And that the deposit is the only blended one. Additive on the resolve
    // would add the drawable's previous contents to every frame.
    var additive: usize = 0;
    for (passes) |pass| {
        if (pass.blending == .additive) additive += 1;
    }
    try testing.expectEqual(@as(usize, 1), additive);
    try testing.expect(trace_pass.blending == .additive);
}

test "a window shorter than one segment draws no trace" {
    try testing.expectEqual(@as(?u32, null), traceVertices(0));
    try testing.expectEqual(@as(?u32, null), traceVertices(1));
    try testing.expectEqual(@as(?u32, 2), traceVertices(2));
}

test "the trace draws one vertex per sample" {
    // 960 is `gui.windowSamples(48_000)`, which `src/clap/gui.zig` pins against
    // the default editor width; the bound is what `upload` truncates to.
    try testing.expectEqual(@as(?u32, 960), traceVertices(960));
    try testing.expectEqual(@as(?u32, iface.max_window_samples), traceVertices(iface.max_window_samples));
}

test "the trace's uniforms are laid out the way the shader reads them" {
    // MSL computes its own offsets from its own `TraceUniforms` and nothing links
    // the two declarations. What this catches is a field added or reordered on
    // one side only, whose symptom is a trace at a plausible wrong scale rather
    // than anything that fails. Apple's ceiling for `setVertexBytes:` is 4 KiB,
    // and being far under it is the reason this is not a fourth buffer.
    try testing.expectEqual(@as(usize, 12), @sizeOf(TraceUniforms));
    try testing.expectEqual(@as(usize, 4), @alignOf(TraceUniforms));
    try testing.expectEqual(@as(usize, 0), @offsetOf(TraceUniforms, "sample_count"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(TraceUniforms, "full_scale"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(TraceUniforms, "rail"));
    try testing.expect(@sizeOf(TraceUniforms) <= 4096);
}

test "the trace's uniforms carry the seam's scale rather than a second copy of it" {
    // The defaults are the whole mechanism by which the shader learns the
    // vertical scale, so a `frame` that filled them in by hand would compile and
    // draw at whatever it chose.
    const uniforms: TraceUniforms = .{ .sample_count = 2 };

    try testing.expectEqual(iface.trace_full_scale, uniforms.full_scale);
    try testing.expectEqual(iface.trace_rail, uniforms.rail);
}

test "the drawable is sized in backing pixels and the layer in points" {
    const size: iface.Size = .{ .width = 960, .height = 540 };

    try testing.expectEqual(CGSize{ .width = 960, .height = 540 }, logicalSize(size));
    try testing.expectEqual(Pixels{ .width = 1920, .height = 1080 }, backingPixels(size, 2));
    try testing.expectEqual(Pixels{ .width = 960, .height = 540 }, backingPixels(size, 1));
}

test "the layer is handed the same whole pixels everything else is sized from" {
    // The property that keeps a fragment's integer read of one surface in bounds
    // against another: whatever `backingPixels` decided is what reaches
    // `setDrawableSize:`, with no second rounding in between. Phase 3's
    // accumulation textures are the other consumer, and this is the only thing
    // asserting the two cannot disagree.
    const size: iface.Size = .{ .width = 960, .height = 540 };

    inline for (.{ 1.0, 1.5, 2.0 }) |scale| {
        const pixels = backingPixels(size, scale);
        try testing.expectEqual(
            CGSize{
                .width = @floatFromInt(pixels.width),
                .height = @floatFromInt(pixels.height),
            },
            drawableSize(pixels),
        );
    }
}

test "a fractional backing scale rounds once rather than truncating" {
    // 1.5 is reachable: `Pending.Packed` carries the scale in 1/256ths, so
    // anything a display reports that is not exactly 1 or 2 arrives here as a
    // fraction. 540 * 1.5 is exact; 271 * 1.5 is 406.5 and is the case that
    // separates rounding from truncation.
    try testing.expectEqual(
        Pixels{ .width = 1440, .height = 810 },
        backingPixels(.{ .width = 960, .height = 540 }, 1.5),
    );
    try testing.expectEqual(
        Pixels{ .width = 1440, .height = 407 },
        backingPixels(.{ .width = 960, .height = 271 }, 1.5),
    );
}

test "the smallest editor the seam permits still asks for at least one pixel" {
    // 480x270 is `gui.min_size` and 1/256 is the smallest scale `Pending.Packed`
    // can encode, restated as literals because the backend must not import the
    // clap layer. Metal rejects a zero-dimension texture, so this is the
    // arithmetic that says the floor in `backingPixels` guards a case the
    // callers already exclude rather than one they produce.
    const smallest = backingPixels(.{ .width = 480, .height = 270 }, 1.0 / 256.0);

    try testing.expect(smallest.width >= 1);
    try testing.expect(smallest.height >= 1);
}

test "a scale no integer can hold is saturated rather than illegal" {
    // `@intFromFloat` is undefined behaviour out of range and `lossyCast` is
    // not. Nothing should reach this, since `Pending` refuses a degenerate
    // scale and `View.backingScale` falls back to 1.0, but the seam's own
    // habit is to refuse rather than assert at a boundary it does not own.
    const huge = backingPixels(.{ .width = 960, .height = 540 }, 1e300);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), huge.width);

    const nonsense = backingPixels(.{ .width = 960, .height = 540 }, std.math.nan(f64));
    try testing.expect(nonsense.width >= 1);
}
