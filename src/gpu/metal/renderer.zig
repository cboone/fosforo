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
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sema: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sema: *anyopaque) isize;

/// `DISPATCH_TIME_FOREVER`. Blocking the display-link thread is the intended
/// backpressure: CoreVideo drops the ticks that arrive while we are waiting,
/// which is exactly the right response to a GPU that has fallen behind.
const dispatch_time_forever: u64 = ~@as(u64, 0);

/// The block `addCompletedHandler:` takes, which is how a slot comes back.
///
/// The semaphore is captured as an `objc.c.id` rather than as a raw pointer,
/// which is not a formality. `zig-objc` retains `id`-typed captures when the
/// runtime copies the block to the heap, and `addCompletedHandler:` does copy
/// it. That retain is what makes `deinit` safe: releasing the semaphore while a
/// command buffer is still executing would otherwise leave a queued handler
/// signalling freed memory, and the alternative fix, draining every slot before
/// releasing, can hang the host's main thread on a wedged GPU.
const Completion = objc.Block(struct { sema: objc.c.id }, .{objc.c.id}, void);

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

        const layer = try attachLayer(view, device, size, scale, diags);

        return .{
            .device = device,
            .queue = queue,
            .pipeline = pipeline,
            .layer = layer,
            .in_flight = in_flight,
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
    pub fn deinit(self: *Renderer) void {
        platform.assertMainThread();

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

    /// [render-thread] Draw and present one frame.
    ///
    /// Driven by the display link, which is why it takes no arguments and
    /// reports nothing: a frame that cannot be drawn is skipped, not escalated.
    pub fn frame(self: *Renderer) void {
        platform.assertNotMainThread();

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const sema: *anyopaque = @ptrCast(self.in_flight.value.?);
        _ = dispatch_semaphore_wait(sema, dispatch_time_forever);

        // Every early return below has to give the slot back. This is the
        // classic way the pattern fails: three skipped frames in a row would
        // otherwise drain the semaphore to zero, and the next wait would block
        // forever on a signal that is never coming, stopping the render loop
        // for good rather than for a moment.
        var handed_off = false;
        defer if (!handed_off) {
            _ = dispatch_semaphore_signal(sema);
        };

        // Nil under load, and that is normal rather than an error: the
        // compositor is holding every drawable and the right answer is to let
        // this tick go. Treating it as a failure is how a render loop turns a
        // busy moment into a visible stall.
        const drawable = self.layer.msgSend(objc.Object, "nextDrawable", .{});
        if (drawable.value == null) return;

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
        if (buffer.value == null) return;

        const encoder = buffer.msgSend(objc.Object, "renderCommandEncoderWithDescriptor:", .{pass});
        if (encoder.value == null) return;

        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline});
        // A fullscreen triangle, which is cheaper than a quad and needs no
        // vertex buffer: the vertex function derives its positions from the
        // vertex id alone.
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
    }
};

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
