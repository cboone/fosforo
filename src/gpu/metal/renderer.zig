//! The Metal backend, and the only file in the project allowed to name a Metal
//! type. Everything above it goes through `src/gpu/iface.zig` (ADR 0005).
//!
//! What it does today is clear a drawable to a dim colour. That is the whole
//! deliverable of phase 1: the point is not the picture, it is that a shader
//! compiled from an embedded string at runtime ran on the GPU inside someone
//! else's DAW. The decay, additive trace, and tonemap arrive in phase 3.

const std = @import("std");
const objc = @import("objc");
const iface = @import("../iface.zig");
const platform = @import("../../platform/objc.zig");

const CGRect = platform.CGRect;
const CGSize = platform.CGSize;

/// The shader source, compiled at runtime rather than linked as a `.metallib`
/// (ADR 0009), which is what keeps `zig build` free of the Metal toolchain.
///
/// Reached through the import table rather than by relative path: `@embedFile`
/// cannot escape the module root, and `shaders/` sits beside `src/` rather than
/// inside it. `build.zig` puts it there.
const shader_source = @embedFile("scope.metal");

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

    const load_action_clear: u64 = 2;
    const store_action_store: u64 = 1;
    const primitive_type_triangle: u64 = 3;

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

/// Kept in step with `clear_fragment` in `shaders/scope.metal`.
///
/// Both run: the load action clears, and then the fullscreen triangle covers
/// what it cleared. That is redundant on purpose. The clear alone would produce
/// an identical picture while proving nothing, and the entire point of this
/// phase is that the fragment shader executed.
const background: ClearColor = .{ .red = 0.02, .green = 0.02, .blue = 0.03, .alpha = 1.0 };

const vertex_function = "fullscreen_vertex";
const fragment_function = "clear_fragment";

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

fn signalCompleted(block: *const Completion.Context, buffer: objc.c.id) callconv(.c) void {
    _ = buffer;
    if (block.sema) |sema| _ = dispatch_semaphore_signal(@ptrCast(sema));
}

pub const Renderer = struct {
    device: objc.Object,
    queue: objc.Object,
    pipeline: objc.Object,
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

        const pipeline = try buildPipeline(device, diags);
        errdefer pipeline.release();

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

        const layer = try attachLayer(view, device, size, scale, diags);

        return .{
            .device = device,
            .queue = queue,
            .pipeline = pipeline,
            .layer = layer,
            .in_flight = in_flight,
            .windows = windows,
        };
    }

    /// [main-thread] Everything `init` does except attach a surface, released
    /// again before it returns.
    ///
    /// The half of starting a renderer that needs no window, and so the half
    /// that can run on a machine with a GPU and nothing else. It shares
    /// `buildPipeline` with `init` rather than paraphrasing it, which is what
    /// makes a pass here mean the shipping path compiled the shader, and not
    /// merely that some shader compiled.
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

        const pipeline = try buildPipeline(device, diags);
        pipeline.release();

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

        releaseWindows(self.windows);
        self.in_flight.release();
        self.layer.release();
        self.pipeline.release();
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
    /// takes the size rather than reading it back off the layer.
    ///
    /// Inside a transaction because these are CoreAnimation properties being
    /// set from somewhere that is not the main thread: it makes the pair land
    /// as one change and skips the implicit animation CoreAnimation would
    /// otherwise attach to each.
    pub fn resize(self: *Renderer, size: iface.Size, scale: f64) void {
        platform.assertNotMainThread();

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const transaction = objc.getClass("CATransaction").?;
        transaction.msgSend(void, "begin", .{});
        defer transaction.msgSend(void, "commit", .{});
        transaction.msgSend(void, "setDisableActions:", .{true});

        self.layer.msgSend(void, "setContentsScale:", .{scale});
        self.layer.msgSend(void, "setDrawableSize:", .{drawableSize(size, scale)});
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

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

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

        const pass = objc.getClass("MTLRenderPassDescriptor").?
            .msgSend(objc.Object, "renderPassDescriptor", .{});
        const attachment = colorAttachment(pass);
        attachment.msgSend(void, "setTexture:", .{drawable.msgSend(objc.Object, "texture", .{})});
        attachment.msgSend(void, "setLoadAction:", .{mtl.load_action_clear});
        attachment.msgSend(void, "setStoreAction:", .{mtl.store_action_store});
        attachment.msgSend(void, "setClearColor:", .{background});

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

        const encoder = buffer.msgSend(objc.Object, "renderCommandEncoderWithDescriptor:", .{pass});
        if (encoder.value == null) return .no_encoder;

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline});

        // Bound although the shader currently declares no such argument, which
        // Metal permits and which is deliberate rather than an oversight. It
        // makes the upload a path rather than a write into memory the GPU never
        // sees, and it is the retain `deinit` leans on: an encoder holds the
        // resources it binds until its command buffer completes. #38 adds the
        // vertex function that reads it.
        encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{
            self.windows[self.slot],
            @as(u64, 0),
            @as(u64, 0),
        });

        // A fullscreen triangle, which is cheaper than a quad and needs no
        // vertex buffer: the vertex function derives its positions from the
        // vertex id alone. Drawing the window itself is #38.
        encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:", .{
            mtl.primitive_type_triangle,
            @as(u64, 0),
            @as(u64, 3),
        });
        encoder.msgSend(void, "endEncoding", .{});

        // The slot now belongs to this command buffer, and comes back when the
        // GPU is finished with it. Registered before `commit`, because after it
        // the buffer may already have completed.
        var completion = Completion.init(.{ .sema = self.in_flight.value }, signalCompleted);
        buffer.msgSend(void, "addCompletedHandler:", .{&completion});
        handed_off = true;

        buffer.msgSend(void, "presentDrawable:", .{drawable});
        buffer.msgSend(void, "commit", .{});

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

/// Give a whole ring back, and say so.
///
/// The one place window buffers are released, which is what stops the count
/// drifting from the releases: `probe` takes a ring and hands it straight back,
/// and a second bare release loop there would have left the count high forever.
fn releaseWindows(windows: [max_frames_in_flight]objc.Object) void {
    for (windows) |buffer| buffer.release();
    _ = live_windows.fetchSub(max_frames_in_flight, .release);
}

/// Compile the embedded source and assemble a pipeline state from it.
///
/// Both failures carry the `NSError`'s text into `diags`. A Metal compiler
/// diagnostic names a file, a line, and the mistake; losing it would leave a
/// developer with nothing but an editor that refused to open.
fn buildPipeline(device: objc.Object, diags: *iface.Diagnostics) iface.Error!objc.Object {
    var err: ?*anyopaque = null;

    const library = device.msgSend(objc.Object, "newLibraryWithSource:options:error:", .{
        platform.nsString(shader_source),
        @as(?*anyopaque, null),
        &err,
    });
    if (library.value == null) {
        describe(err, diags, "the shader source did not compile");
        return error.ShaderCompilationFailed;
    }
    defer library.release();

    const vertex = library.msgSend(objc.Object, "newFunctionWithName:", .{platform.nsString(vertex_function)});
    const fragment = library.msgSend(objc.Object, "newFunctionWithName:", .{platform.nsString(fragment_function)});
    defer vertex.release();
    defer fragment.release();

    // A library that compiled but lacks a function means the shader was edited
    // and one of the names above was not, which is a mismatch worth naming
    // precisely rather than reporting as a generic pipeline failure.
    if (vertex.value == null or fragment.value == null) {
        diags.set("the shader compiled but does not define " ++ vertex_function ++ " and " ++ fragment_function);
        return error.PipelineCreationFailed;
    }

    const descriptor = objc.getClass("MTLRenderPipelineDescriptor").?
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer descriptor.release();

    descriptor.msgSend(void, "setVertexFunction:", .{vertex});
    descriptor.msgSend(void, "setFragmentFunction:", .{fragment});
    colorAttachment(descriptor).msgSend(void, "setPixelFormat:", .{mtl.pixel_format_bgra8_unorm});

    err = null;
    const pipeline = device.msgSend(objc.Object, "newRenderPipelineStateWithDescriptor:error:", .{
        descriptor,
        &err,
    });
    if (pipeline.value == null) {
        describe(err, diags, "the render pipeline state could not be built");
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
fn attachLayer(
    view: iface.NativeView,
    device: objc.Object,
    size: iface.Size,
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
    layer.msgSend(void, "setPixelFormat:", .{mtl.pixel_format_bgra8_unorm});
    // Nothing reads back from the drawable, which lets Metal choose a cheaper
    // storage mode. Phase 3's accumulation textures are separate from it.
    layer.msgSend(void, "setFramebufferOnly:", .{true});
    // Stated rather than inherited. Three is already the default, and it is the
    // other half of the frame bound the semaphore sets: writing it down is what
    // keeps the two from drifting apart if one is ever tuned.
    layer.msgSend(void, "setMaximumDrawableCount:", .{@as(u64, max_frames_in_flight)});
    layer.msgSend(void, "setContentsScale:", .{scale});
    layer.msgSend(void, "setDrawableSize:", .{drawableSize(size, scale)});
    layer.msgSend(void, "setFrame:", .{bounds});

    const host_view = objc.Object.fromId(view);
    host_view.msgSend(void, "setLayer:", .{layer});
    host_view.msgSend(void, "setWantsLayer:", .{true});

    return layer;
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

/// Backing pixels. Cocoa hands out logical points, so this is the one place the
/// scale factor is applied, and getting it wrong is a blurry render rather than
/// a failure, which is exactly why it is worth stating in one place.
fn drawableSize(size: iface.Size, scale: f64) CGSize {
    const logical = logicalSize(size);
    return .{ .width = logical.width * scale, .height = logical.height * scale };
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
    testing.refAllDecls(@This());
    testing.refAllDecls(Renderer);
}

test "the shader source is embedded and terminated for the C string API" {
    try testing.expect(shader_source.len > 0);
    try testing.expectEqual(@as(u8, 0), shader_source[shader_source.len]);
}

test "the embedded shader defines the functions the pipeline asks for" {
    // Cheap insurance against renaming one side and not the other. It proves
    // only that the names appear, which is all a string can prove; `zig build
    // validate-shaders` is what proves the file compiles.
    try testing.expect(std.mem.indexOf(u8, shader_source, vertex_function) != null);
    try testing.expect(std.mem.indexOf(u8, shader_source, fragment_function) != null);
}

test "the drawable is sized in backing pixels and the layer in points" {
    const size: iface.Size = .{ .width = 960, .height = 540 };

    try testing.expectEqual(CGSize{ .width = 960, .height = 540 }, logicalSize(size));
    try testing.expectEqual(CGSize{ .width = 1920, .height = 1080 }, drawableSize(size, 2));
    try testing.expectEqual(CGSize{ .width = 960, .height = 540 }, drawableSize(size, 1));
}
