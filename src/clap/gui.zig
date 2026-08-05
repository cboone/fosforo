//! The editor's lifecycle, as CLAP's `clap.gui` extension drives it, and the
//! seam between the host's main thread and the render thread.
//!
//! Most of this file runs on the host's main thread. `tick` does not: it is the
//! display link's callback, and everything it reaches has to be safe against a
//! main thread that may be resizing or tearing down the editor at the same
//! moment. That boundary is the whole subject of ADR 0010, and `Pending` below
//! is the entirety of the protocol across it.
//!
//! The split against `platform/view.zig`, `platform/displaylink.zig`, and
//! `gpu/` is deliberate and load-bearing for the tests: this file holds the
//! decisions (which windowing API is acceptable, how large the editor may be,
//! what order teardown happens in, what crosses between threads), and the
//! modules below it hold the AppKit, CoreVideo, and Metal calls. That is what
//! lets `zig build test` exercise the state machine and the mailbox without an
//! `NSApplication`, a window server, or a GPU (ADR 0009).
//!
//! The vtable itself lives in `plugin.zig`, alongside the ones for
//! `clap.audio-ports` and `clap.state`, because it needs the `*Instance` that
//! this file deliberately knows nothing about.

const std = @import("std");
const builtin = @import("builtin");
const clap = @import("c.zig");
const log_mod = @import("log.zig");
const gpu = @import("../gpu/iface.zig");
const display_link = @import("../platform/displaylink.zig");
const view_mod = @import("../platform/view.zig");

const c = clap.c;

/// The editor's size on first open, in logical points.
///
/// Cocoa is a logical-pixel API, so this is points rather than backing pixels
/// and the same number produces the same apparent size on a Retina display as
/// on anything else. 16:9 because a scope's horizontal axis is time and wants
/// the room; half of 1920x1080 because that sits on a laptop display without
/// taking it over.
///
/// A default, not a constraint. The ratio is deliberately **not** enforced:
/// the argument for it is that a time axis wants room, and locking 16:9 is
/// exactly what would stop someone buying more of it by making the editor short
/// and wide.
pub const default_size: gpu.Size = .{ .width = 960, .height = 540 };

/// The smallest editor `adjust_size` will agree to.
///
/// Half the default on each axis, so the relationship between the two is
/// legible. The floor is a design one rather than a machine one: Metal would
/// happily draw a 40x20 drawable, but phase 5's cursor readouts are what stop
/// being usable first, and they need somewhere to live.
pub const min_size: gpu.Size = .{ .width = 480, .height = 270 };

/// The largest editor this plugin will agree to, in logical points.
///
/// A machine limit rather than a design one, and the mirror of `min_size`'s
/// reasoning. Metal's maximum texture dimension is 16384 on Apple Silicon, and
/// the backing scale AppKit reports is at most 2, so 8192 points is the largest
/// editor whose drawable is certain to be allocatable. It is also far larger
/// than any display sold, so no real request is refused by it.
///
/// This exists because a size arriving from a host is a trust boundary, and
/// gets the treatment `activate` and `process` already give theirs: refuse
/// rather than assert. Without an upper bound a single bad number from a host
/// becomes a drawable Metal cannot allocate, on a thread with no way to report
/// it.
pub const max_size: gpu.Size = .{ .width = 8192, .height = 8192 };

/// A single-slot mailbox carrying a size and a backing scale from the host's
/// main thread to the render thread.
///
/// This is the one genuine threading seam in the design (ADR 0010). The host's
/// resize callback arrives on the main thread and has to reallocate resources
/// the render thread is actively using; the answer is that it reallocates
/// nothing and leaves a note, which the render thread reads at the top of its
/// next tick, before it touches anything the note invalidates.
///
/// Everything is packed into one `u64` so a post is a single atomic store and a
/// drain is a single atomic swap. There is no torn read to reason about and no
/// lock for the main thread to be caught holding.
///
/// **Last write wins, and that is the correct semantics rather than a
/// simplification.** A window drag produces one post per frame and the render
/// thread only ever wants the newest; a queue would faithfully deliver a
/// backlog of sizes the editor no longer has.
pub const Pending = struct {
    slot: std.atomic.Value(u64) = .init(empty),

    /// All-zero is the empty state, which needs no separate flag: Metal rejects
    /// a zero-sized drawable, so a post carrying a zero dimension conveys
    /// nothing and is correctly indistinguishable from no post at all.
    const empty: u64 = 0;

    const Packed = packed struct(u64) {
        width: u16,
        height: u16,
        /// Backing pixels per logical point, in 1/256ths.
        ///
        /// Exact for the 1.0 and 2.0 that AppKit actually reports, and within
        /// 1/512 of anything else, which is far below a pixel on any drawable
        /// this will ever size. Fixed point rather than a second atomic,
        /// because splitting the size and the scale across two words would let
        /// the render thread act on a size from one display and a scale from
        /// another.
        scale_256: u16,
        _: u16 = 0,
    };

    const scale_step = 256;

    /// What the render thread gets back.
    pub const Update = struct {
        size: gpu.Size,
        scale: f64,
    };

    /// [main-thread] Leave a note. Saturates rather than wrapping, and drops a
    /// degenerate size rather than encoding one.
    pub fn post(self: *Pending, size: gpu.Size, scale: f64) void {
        if (size.width == 0 or size.height == 0) return;

        const scale_256 = std.math.lossyCast(u16, @round(scale * scale_step));
        if (scale_256 == 0) return;

        const message: Packed = .{
            .width = std.math.lossyCast(u16, size.width),
            .height = std.math.lossyCast(u16, size.height),
            .scale_256 = scale_256,
        };

        self.slot.store(@bitCast(message), .release);
    }

    /// [render-thread] Take the note, if there is one, leaving the mailbox
    /// empty. A size is therefore acted on exactly once no matter how many
    /// times it was posted.
    pub fn take(self: *Pending) ?Update {
        const raw = self.slot.swap(empty, .acquire);
        if (raw == empty) return null;

        const message: Packed = @bitCast(raw);
        return .{
            .size = .{ .width = message.width, .height = message.height },
            .scale = @as(f64, @floatFromInt(message.scale_256)) / scale_step,
        };
    }
};

/// The host's side of `clap.gui`, looked up once.
///
/// Only one call is needed and it is the one that makes a minimum size real.
/// CLAP has no field anywhere for a smallest editor: `clap_gui_resize_hints_t`
/// carries resizability and an aspect ratio and nothing else, and `adjust_size`
/// answers a question the host has to remember to ask. REAPER 7.78 does ask,
/// and applies the answer to the plugin's view, and then shrinks its own window
/// past it anyway, which leaves the drawable pinned at the minimum inside a
/// window that keeps closing over it.
///
/// `request_resize` is the only way back. It is the plugin asking the host to
/// size the client area, and it is what turns a clamp the host ignored into a
/// window that will not go smaller.
pub const HostGui = struct {
    ext: ?*const c.clap_host_gui_t = null,
    host: ?*const c.clap_host_t = null,

    /// [main-thread] Host extensions are unreachable until `clap_plugin.init`.
    ///
    /// An absent extension is survivable rather than an error, on the same
    /// reasoning `log.Log` applies: a host that does not implement it leaves
    /// the editor working, with a minimum it can enforce for its own view and
    /// not for the host's window.
    pub fn init(host: *const c.clap_host_t) HostGui {
        const get_extension = host.get_extension orelse return .{ .host = host };
        const ptr = get_extension(host, &c.CLAP_EXT_GUI) orelse return .{ .host = host };

        // A host that answers the id still owes a populated vtable, and one
        // that hands back a struct with a null `request_resize` is easier to
        // survive than to diagnose from a crash report.
        const ext: *const c.clap_host_gui_t = @ptrCast(@alignCast(ptr));
        if (ext.request_resize == null) return .{ .host = host };

        return .{ .ext = ext, .host = host };
    }

    /// [main-thread] Ask the host to resize the client area.
    ///
    /// A false return is normal: the header says the host does not have to
    /// honour it, and a host that refuses leaves the editor exactly as it was.
    pub fn requestResize(self: HostGui, size: gpu.Size) bool {
        const ext = self.ext orelse return false;
        return ext.request_resize.?(self.host, size.width, size.height);
    }
};

/// One instance's editor. Inert until the host calls `create`, and inert again
/// after `destroy`, which is what makes both safe to call more than once.
pub const Editor = struct {
    /// Whether the host has called `create` and not yet `destroy`. Tracked
    /// separately from `view`, because an editor is legitimately created and
    /// not yet parented, and the two states answer different questions.
    created: bool = false,

    /// Whether the host has explicitly hidden the editor, rather than whether
    /// it has explicitly shown it.
    ///
    /// The polarity is load-bearing. CLAP specifies that a host calls `show`,
    /// and REAPER does, but clap-wrapper's AUv2 view has both of its
    /// `gui->show()` calls commented out, so the Audio Unit reaches
    /// `set_parent` and is then never shown. Gating the render loop on a
    /// positive `visible` meant the display link was created and never started,
    /// and the editor in Logic drew nothing at all. Defaulting to "not hidden"
    /// makes an embedded editor render in both hosts, and leaves `hide` as the
    /// only thing that stops it.
    hidden: bool = false,

    /// The editor's size and backing scale as the main thread understands them.
    /// The render thread never reads these; it reads whatever `Pending` last
    /// carried across.
    current: gpu.Size = default_size,
    scale: f64 = 1.0,

    view: ?view_mod.View = null,
    renderer: ?gpu.Renderer = null,
    link: ?display_link.DisplayLink = null,

    pending: Pending = .{},

    /// Handed to the view, which stores a pointer to it. Only meaningful while
    /// `view` is non-null, and only valid because an `Editor` lives inside the
    /// heap-allocated `Instance` and therefore does not move.
    delegate: view_mod.Delegate = undefined,

    /// Guards the render path against a teardown running beside it.
    gate: Gate = .{},

    /// Frames the render thread has actually put on screen.
    ///
    /// Written by the render thread and read by anything else, so it is atomic
    /// rather than a plain counter. It exists because "the loop is running" and
    /// "the loop is drawing" are different claims, and until this counter there
    /// was no way to check the second: the deliverable is a flat colour, so a
    /// renderer skipping every tick is invisible. ADR 0013 records that gap and
    /// `src/smoke.zig` is what now asserts against it.
    presented: std.atomic.Value(u64) = .init(0),

    /// Debug builds only. Reports the rate the loop is observed to run at,
    /// which is the only way to tell a healthy loop from a stopped one when the
    /// picture is a flat colour.
    meter: Meter = .{},
    log: ?*const log_mod.Log = null,
    host_gui: ?*const HostGui = null,

    /// Guards against re-entering the resize path from inside itself.
    ///
    /// `request_resize` may be serviced synchronously, in which case the host
    /// resizes the view before returning and AppKit delivers `setFrameSize:`
    /// while this is still on the stack. The second pass would agree with the
    /// first and stop, so the flag is not load-bearing for correctness; it is
    /// there so a host that answers a request with a size that is *also* out of
    /// bounds cannot bounce between the two.
    resizing: bool = false,

    /// [main-thread] The only place the host's windowing API is judged, shared
    /// by `is_api_supported` and `create` so the two cannot disagree.
    ///
    /// Floating windows are refused outright. The header records that embedding
    /// is supported by every host to date and is the case a plugin must
    /// support, and a floating window would need a second lifecycle with its
    /// own `set_transient` and `suggest_title` handling for no gain here.
    pub fn isApiSupported(api: [*c]const u8, is_floating: bool) bool {
        if (is_floating or api == null) return false;
        return std.mem.eql(u8, std.mem.span(api), &c.CLAP_WINDOW_API_COCOA);
    }

    /// [main-thread] Allocates nothing that needs a GPU.
    ///
    /// CLAP describes this as allocating the editor's resources, and it would
    /// be defensible to acquire the Metal device here for the sake of failing
    /// early. It is deferred to `set_parent` instead, where the view exists and
    /// its backing scale is knowable, which also keeps this callback reachable
    /// from a test binary with no GPU.
    pub fn create(self: *Editor, api: [*c]const u8, is_floating: bool) bool {
        if (!isApiSupported(api, is_floating)) return false;

        // A second `create` without a `destroy` is a host bug. Refusing is
        // better than quietly leaking the first editor's view and layer.
        if (self.created) return false;

        self.created = true;
        return true;
    }

    /// [main-thread] Release everything, in the reverse of the order it was
    /// built: the render loop first, then the renderer, whose layer is still
    /// attached to the view, and the view last.
    ///
    /// Safe when `create` failed, when `set_parent` never happened, and when
    /// called twice. A host is supposed to call this exactly once, but the cost
    /// of surviving one that does not is a handful of null checks.
    pub fn destroy(self: *Editor) void {
        // Order matters, and each step closes a different half of the race.
        //
        // The gate first. Any tick that has not yet entered the render path is
        // turned away from here on, and `close` does not return until one that
        // already had has left.
        //
        // This is the step CoreVideo will not do for us. `CVDisplayLinkStop`
        // is not documented to wait for a callback already in flight, and both
        // WebKit and Chromium guard it rather than bet on the answer. The cost
        // of not betting is at most one frame, once, when an editor closes.
        self.gate.close();

        // Then the link, after which CoreVideo will not call back at all.
        if (self.link) |l| l.destroy();
        self.link = null;

        if (self.renderer) |*renderer| renderer.deinit();
        self.renderer = null;

        if (self.view) |v| v.destroy();
        self.view = null;

        self.pending = .{};
        self.meter = .{};
        self.presented = .init(0);
        self.current = default_size;
        self.scale = 1.0;
        self.hidden = false;
        self.created = false;

        // Reopened last, so the editor is reusable: a host may `create` and
        // `set_parent` the same one again. Safe here and nowhere else, because
        // the display link is gone and no tick can exist to slip through.
        self.gate = .{};
    }

    /// [main-thread] Embed the editor in the host's window.
    ///
    /// Order matters three times over. The view is attached to the parent
    /// *before* its backing scale is read, because a view has no window until
    /// it is in one and the scale would otherwise be a guess. The renderer is
    /// built after that, because it is the first step that can fail for reasons
    /// outside this process. And the display link is built last, because there
    /// is no sense pacing frames for a renderer that does not exist.
    pub fn setParent(
        self: *Editor,
        window: *const c.clap_window_t,
        diags: *gpu.Diagnostics,
    ) !void {
        if (!self.created) return error.NotCreated;
        if (self.view != null) return error.AlreadyParented;

        // Every member of `clap_window`'s union is pointer-sized, so reading the
        // cocoa member of a window the host filled in as something else yields a
        // plausible-looking pointer that is not an `NSView`, and the first
        // message sent to it is the crash. Nothing about the earlier `create`
        // call constrains what arrives here, so this is a trust boundary and
        // gets the same treatment `activate` and `process` give theirs: refuse.
        //
        // Judged by the same predicate that gates `create`, so the two cannot
        // disagree about what this plugin can embed in. `is_floating` is false
        // because reaching `set_parent` at all means the host chose embedding.
        if (!isApiSupported(window.api, false)) return error.WrongWindowApi;

        // Reached through the accessor and never through the union field
        // directly: `unnamed_0` is a name translate-c generates and nothing
        // guarantees across Zig versions.
        const parent = clap.cocoaView(window) orelse return error.NoParentView;

        self.delegate = .{
            .context = self,
            .resized = onResized,
            .display_changed = onDisplayChanged,
        };

        const v = view_mod.View.create(self.current.width, self.current.height, &self.delegate) orelse
            return error.ViewCreationFailed;
        errdefer v.destroy();

        // Published before `attach`, because attaching moves the view into a
        // window and AppKit reports that synchronously through the delegate.
        // A callback that found `self.view` still null would silently drop the
        // first display it ever learned about.
        self.view = v;
        errdefer self.view = null;

        v.attach(parent);

        self.scale = v.backingScale();
        self.renderer = try gpu.Renderer.init(v.handle(), self.current, self.scale, diags);
        errdefer {
            self.renderer.?.deinit();
            self.renderer = null;
        }

        self.link = display_link.DisplayLink.create(v.displayID(), tick, self) orelse
            return error.DisplayLinkCreationFailed;

        // A host that reopens an editor may parent it while it is already
        // showing rather than calling `show` again, so the loop starts from
        // whichever of the two arrives last.
        if (!self.hidden) self.startLoop();
    }

    /// [main-thread] CLAP's `show` and `hide`. Hiding frees nothing: it is
    /// expected to be reversible, and the host may re-show the same editor.
    ///
    /// It does stop the loop, which is not merely an optimisation. A host with
    /// several instances loaded and one editor open should not be paying for
    /// the others' frames, and "no audio dropouts with several instances open"
    /// is one of the things this issue has to hold up.
    pub fn setHidden(self: *Editor, hidden: bool) bool {
        if (!self.created) return false;

        self.hidden = hidden;
        if (self.view) |v| v.setHidden(hidden);

        if (hidden) self.stopLoop() else self.startLoop();
        return true;
    }

    /// [main-thread] Apply a size the host asked for.
    ///
    /// Clamped rather than refused. A host is expected to call `adjust_size`
    /// first and most do, but one that skips it and gets a refusal is left with
    /// its window at the new size and the editor at the old one, which is a
    /// worse mismatch than the one clamping produces. `get_size` is how a host
    /// learns what it actually got.
    ///
    /// Routed through the view rather than posting directly, so a resize the
    /// host requested and a resize the host performed itself arrive by exactly
    /// one path. Two paths is how the layer and the drawable end up disagreeing
    /// about which was last.
    ///
    /// Does not require `create`, for the same reason `get_size` does not: this
    /// is bookkeeping about how large an editor would be, and a host is
    /// entitled to negotiate that before asking for one. Answering `get_size`
    /// while refusing `set_size` would be an inconsistency a host has no way to
    /// discover except by trying.
    pub fn setSize(self: *Editor, width: u32, height: u32) bool {
        const clamped = clampSize(width, height);
        if (self.view) |v| {
            v.setSize(clamped.width, clamped.height);
            // The view is now the clamped size, so `setFrameSize:` above saw no
            // discrepancy and asked for nothing. The discrepancy is between the
            // clamp and what the *host* asked for, and this is the only place
            // that knows both.
            self.pushBack(.{ .width = width, .height = height }, clamped);
        } else {
            // No view yet, so nothing will call back. Record it so the view is
            // created at this size when `set_parent` arrives.
            self.current = clamped;
        }
        return true;
    }

    /// [main-thread] Ask the host to correct a size this editor would not adopt.
    ///
    /// Only when the two differ, so a host sizing the editor legally is never
    /// argued with. Without this the clamp protects the drawable and nothing
    /// else: REAPER honours `adjust_size` for the plugin's view and keeps
    /// shrinking its own window regardless, which reads to a user as an editor
    /// with no minimum at all, its contents clipped by a window closing over
    /// them.
    fn pushBack(self: *Editor, requested: gpu.Size, clamped: gpu.Size) void {
        if (requested.width == clamped.width and requested.height == clamped.height) return;
        if (self.resizing) return;

        const host_gui = self.host_gui orelse return;

        self.resizing = true;
        defer self.resizing = false;

        const accepted = host_gui.requestResize(clamped);

        // Kept rather than removed with the instrumentation that found it. This
        // fires only when a host proposes a size the editor will not adopt, so
        // it is quiet in normal use, and it is the only place the host's answer
        // to a bound is visible. A host that stops honouring this, or starts
        // proposing sizes far below the minimum rather than a pixel or two
        // under, shows up here and nowhere else.
        if (self.log) |l| l.print(
            c.CLAP_LOG_DEBUG,
            "host asked for {d}x{d}, requested {d}x{d} instead: accepted={}",
            .{ requested.width, requested.height, clamped.width, clamped.height, accepted },
        );
    }

    /// [main-thread] The closest size this editor would actually adopt.
    ///
    /// Each axis is clamped independently, so a tall narrow request answers
    /// with a tall narrow size rather than being snapped back to the default's
    /// proportions.
    pub fn adjustSize(self: *const Editor, width: u32, height: u32) gpu.Size {
        _ = self;
        return clampSize(width, height);
    }

    /// [main-thread] The size the editor is now, which is what a host reads
    /// back after `set_size`.
    pub fn size(self: *const Editor) gpu.Size {
        return self.current;
    }

    /// [render-thread] One frame, as the display link calls for it.
    ///
    /// The mailbox is drained before anything is drawn, which is the ordering
    /// ADR 0010 asks for: the resources a resize invalidates are replaced
    /// before this frame reads them, rather than underneath a frame already in
    /// progress.
    fn tick(context: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(context));

        if (!self.gate.enter()) return;
        defer self.gate.leave();

        const renderer = if (self.renderer) |*r| r else return;

        if (self.pending.take()) |update| renderer.resize(update.size, update.scale);

        // Counted, not merely performed. Monotonic and never reset, so a caller
        // that samples it twice can tell the loop advanced without having to
        // coordinate with teardown over when zero means "not started".
        if (renderer.frame().drew()) _ = self.presented.fetchAdd(1, .release);

        self.report();
    }

    /// [thread-safe] Frames put on screen since this editor was created.
    ///
    /// The one observable that distinguishes a render loop doing its job from
    /// one ticking and drawing nothing. `src/smoke.zig` is the caller.
    pub fn framesPresented(self: *const Editor) u64 {
        return self.presented.load(.acquire);
    }

    /// [main-thread] Start and stop the display link. Both are no-ops before
    /// `set_parent`, which is the state every test leaves the editor in.
    fn startLoop(self: *Editor) void {
        const l = self.link orelse return;
        _ = l.start();
    }

    fn stopLoop(self: *Editor) void {
        const l = self.link orelse return;
        l.stop();

        // The meter's window is wall time, so one that spans a hidden editor
        // would report the stall as a slow second and read as a defect in the
        // loop. Restarting it means the first number after `show` describes the
        // loop rather than the pause before it.
        self.meter = .{};
    }

    /// [render-thread] Debug builds only.
    ///
    /// The deliverable of this phase is a flat colour, so a loop running at
    /// 120 Hz and a loop that stopped ten seconds ago produce identical
    /// pictures. This line is the difference, and it carries the drawable size
    /// too, which is what makes a resize observable rather than inferred.
    fn report(self: *Editor) void {
        if (builtin.mode != .Debug) return;

        const rate = self.meter.observe(display_link.monotonicNanos()) orelse return;
        const l = self.log orelse return;

        l.print(c.CLAP_LOG_DEBUG, "rendering at {d:.1} Hz, {d}x{d} at {d:.2}x", .{
            rate,
            self.current.width,
            self.current.height,
            self.scale,
        });
    }

    // -----------------------------------------------------------------------
    // The view's delegate. All [main-thread].
    // -----------------------------------------------------------------------

    /// The view resized, whether because the host called `set_size` or because
    /// it resized its own window and the autoresizing mask carried it.
    ///
    /// Clamped, and not merely for symmetry with `setSize`. AppKit will hand
    /// over a degenerate size in the ordinary course of events: an autoresizing
    /// subview whose superview shrinks by more than the subview's own width has
    /// its frame floored at zero, which arrives here as 0x0. Taking that
    /// literally would leave `get_size` reporting a size the editor told the
    /// host it does not support, and would be the size the view is rebuilt at
    /// if the host re-parents. Clamping keeps one invariant: `current` is
    /// always a size this editor claims to support.
    fn onResized(context: *anyopaque, width: u32, height: u32) void {
        const self: *Editor = @ptrCast(@alignCast(context));

        const clamped = clampSize(width, height);
        self.current = clamped;
        self.pending.post(clamped, self.scale);

        // The host resized the parent and let the autoresizing mask carry it,
        // which is the path a window drag takes and the one that never consults
        // `adjust_size` about the result.
        self.pushBack(.{ .width = width, .height = height }, clamped);
    }

    /// The backing scale, the window, or the display changed. Which of the
    /// three it was is not worth distinguishing: all three mean the assumptions
    /// behind the drawable and the frame pacing are stale.
    fn onDisplayChanged(context: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(context));

        const v = self.view orelse return;

        self.scale = v.backingScale();
        self.pending.post(self.current, self.scale);

        if (self.link) |l| l.setDisplay(v.displayID());
    }
};

/// A one-way gate the render thread passes through and teardown closes.
///
/// This exists because `CVDisplayLinkStop` does not promise what a caller
/// freeing resources actually needs to know. It stops future callbacks; it says
/// nothing about one already running. Without an answer, `destroy` would be
/// releasing a Metal device that a tick might be one instruction away from
/// sending a message to, which is a crash inside someone else's DAW that only
/// happens when an editor closes at exactly the wrong moment.
///
/// One word carries both halves, which is what makes it correct: a tick claims
/// its place and learns whether the gate was open in the same atomic operation,
/// so there is no window between checking and entering for `close` to slip
/// into.
///
/// Deliberately not a mutex. Zig 0.16 has no blocking mutex that does not want
/// an `Io` instance, and reaching for a pthread here would put a platform
/// dependency in the one file whose whole design is that it has none.
const Gate = struct {
    /// Bit 0 is the closed flag; everything above it counts ticks inside.
    state: std.atomic.Value(u32) = .init(0),

    const closed: u32 = 1;
    const one_tick: u32 = 2;

    /// [render-thread] Claim a place inside, or find the gate shut.
    ///
    /// The increment happens either way and is undone on refusal, because
    /// reading the flag first and incrementing second is exactly the race this
    /// type exists to close.
    fn enter(self: *Gate) bool {
        const previous = self.state.fetchAdd(one_tick, .acquire);
        if (previous & closed != 0) {
            _ = self.state.fetchSub(one_tick, .release);
            return false;
        }
        return true;
    }

    /// [render-thread] Give the place back.
    fn leave(self: *Gate) void {
        _ = self.state.fetchSub(one_tick, .release);
    }

    /// [main-thread] Shut the gate and wait for anyone inside to leave.
    ///
    /// Spins rather than sleeping. The wait is bounded by one tick, it happens
    /// once when an editor closes, and the alternative is a condition variable
    /// this file would have to reach outside itself for.
    fn close(self: *Gate) void {
        _ = self.state.fetchOr(closed, .acquire);

        while (self.state.load(.acquire) != closed) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }
};

/// Each axis independently, so 300x900 answers 480x900 rather than 480x270.
fn clampSize(width: u32, height: u32) gpu.Size {
    return .{
        .width = clampAxis(width, min_size.width, max_size.width),
        .height = clampAxis(height, min_size.height, max_size.height),
    };
}

/// One axis, defending against a host that sent something impossible.
///
/// **A dimension above `i32`'s range is a negative number that wrapped**, and
/// this is not hypothetical: REAPER 7.78 sends exactly that while the user
/// drags an editor's bottom edge up past its top, arriving here as 4294967295
/// and 4294967274, which are -1 and -22. CLAP types these as `u32`, AppKit
/// computes them as signed `CGFloat`, and nothing in between catches the
/// conversion.
///
/// Such a value is collapsed to the **minimum** rather than the maximum. No
/// display is two billion points across, so the number is not a real request in
/// either reading, and of the two the negative one is certainly what happened:
/// a drag that went past zero. Snapping to the smallest legal editor is what
/// that gesture meant.
///
/// Left unguarded this reached Metal. A height of 4294967295 saturated to 65535
/// crossing the mailbox and asked for a 960x131070 drawable, eighty times
/// Metal's texture limit, from a render loop that had no way to refuse.
fn clampAxis(value: u32, lo: u32, hi: u32) u32 {
    if (value > std.math.maxInt(i32)) return lo;
    return std.math.clamp(value, lo, hi);
}

/// Frames observed per second, sampled about once a second.
///
/// Split out from `Editor` because it is arithmetic over a clock and nothing
/// else, which makes it the one part of the render thread's work that can be
/// tested exactly.
const Meter = struct {
    started_ns: u64 = 0,
    frames: u32 = 0,

    const window_ns: u64 = std.time.ns_per_s;

    /// Returns a rate once a window has elapsed, and null on every other call.
    ///
    /// Takes the time rather than reading it, which is what keeps the one piece
    /// of the render thread's work that is pure arithmetic testable exactly.
    fn observe(self: *Meter, now_ns: u64) ?f64 {
        // The first call establishes the baseline instead of measuring against
        // one, and is not itself counted: it marks the instant the window opens
        // rather than a frame inside it. `CLOCK_UPTIME_RAW` is nanoseconds
        // since boot, so treating a zero baseline as real would divide the
        // frame count by the machine's entire uptime.
        if (self.started_ns == 0) {
            self.started_ns = now_ns;
            self.frames = 0;
            return null;
        }

        self.frames += 1;

        const elapsed = now_ns -| self.started_ns;
        if (elapsed < window_ns) return null;

        const rate = @as(f64, @floatFromInt(self.frames)) *
            @as(f64, @floatFromInt(std.time.ns_per_s)) /
            @as(f64, @floatFromInt(elapsed));

        self.started_ns = now_ns;
        self.frames = 0;
        return rate;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Every test here stops short of `setParent`, which is the one method that
// reaches AppKit, CoreVideo, and Metal. That boundary is why this file exists
// separately from the platform modules: the decisions and the whole of the
// thread protocol are testable on a machine with no window server, and the
// calls are verified by opening the editor in a host.

test "only embedded cocoa is accepted" {
    try testing.expect(Editor.isApiSupported(&c.CLAP_WINDOW_API_COCOA, false));

    // A floating cocoa window is refused as firmly as a foreign API.
    try testing.expect(!Editor.isApiSupported(&c.CLAP_WINDOW_API_COCOA, true));
    try testing.expect(!Editor.isApiSupported(&c.CLAP_WINDOW_API_WIN32, false));
    try testing.expect(!Editor.isApiSupported(&c.CLAP_WINDOW_API_X11, false));
    try testing.expect(!Editor.isApiSupported(null, false));
}

test "an editor is created, reports its size, and tears down" {
    var editor: Editor = .{};

    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    try testing.expect(editor.created);
    try testing.expectEqual(default_size, editor.size());

    editor.destroy();
    try testing.expect(!editor.created);
}

test "create refuses an API it cannot embed in, leaving the editor inert" {
    var editor: Editor = .{};

    try testing.expect(!editor.create(&c.CLAP_WINDOW_API_WIN32, false));
    try testing.expect(!editor.create(&c.CLAP_WINDOW_API_COCOA, true));
    try testing.expect(!editor.created);
}

test "a second create without a destroy is refused rather than leaking the first" {
    var editor: Editor = .{};
    defer editor.destroy();

    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    try testing.expect(!editor.create(&c.CLAP_WINDOW_API_COCOA, false));
}

test "destroy survives being called twice, and on an editor never created" {
    var never: Editor = .{};
    never.destroy();
    never.destroy();
    try testing.expect(!never.created);

    var created: Editor = .{};
    _ = created.create(&c.CLAP_WINDOW_API_COCOA, false);
    created.destroy();
    created.destroy();
    try testing.expect(!created.created);
}

test "show and hide track visibility and are refused before create" {
    var editor: Editor = .{};

    // Nothing to show yet. Returning false is more useful to a host than
    // silently succeeding on an editor that does not exist.
    try testing.expect(!editor.setHidden(false));

    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    defer editor.destroy();

    // No display link, so starting and stopping the loop are no-ops. That they
    // can be reached without one is the property under test: a host is entitled
    // to show an editor it has not parented yet.
    try testing.expect(editor.setHidden(false));
    try testing.expect(!editor.hidden);

    try testing.expect(editor.setHidden(true));
    try testing.expect(editor.hidden);
}

test "destroy is safe on an editor that was shown but never parented" {
    var editor: Editor = .{};
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    try testing.expect(editor.setHidden(false));

    // The teardown barrier runs whether or not a link was ever created, so an
    // uncontended gate is the whole cost in this path.
    editor.destroy();
    try testing.expect(editor.link == null);

    // Reopened, because a host may create and parent the same editor again.
    try testing.expect(editor.gate.enter());
    editor.gate.leave();
}

test "a closed gate turns ticks away and leaves the count where it found it" {
    var gate: Gate = .{};

    try testing.expect(gate.enter());
    gate.leave();

    // Uncontended, so this returns without waiting for anything.
    gate.close();

    // Every refused entry has to undo its own claim. One that did not would
    // leave the count non-zero, and the next `close` would spin forever on a
    // tick that no longer exists.
    try testing.expect(!gate.enter());
    try testing.expect(!gate.enter());
    try testing.expectEqual(Gate.closed, gate.state.load(.acquire));

    gate.close();
}

test "close waits for a tick that is already inside" {
    var gate: Gate = .{};
    try testing.expect(gate.enter());

    // The state a tick mid-frame leaves behind: closed, and still occupied.
    _ = gate.state.fetchOr(Gate.closed, .acquire);
    try testing.expectEqual(Gate.closed | Gate.one_tick, gate.state.load(.acquire));

    // `close` would spin here rather than returning, which is the property
    // under test and also why it cannot be called until the tick leaves.
    gate.leave();
    gate.close();
    try testing.expectEqual(Gate.closed, gate.state.load(.acquire));
}

test "each axis is clamped against the minimum independently" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));

    // A tall narrow request keeps its height rather than being snapped back to
    // the default's proportions, which is what `preserve_aspect_ratio` being
    // false has to mean in practice.
    try testing.expectEqual(gpu.Size{ .width = 480, .height = 900 }, editor.adjustSize(300, 900));
    try testing.expectEqual(gpu.Size{ .width = 1600, .height = 270 }, editor.adjustSize(1600, 4));
    try testing.expectEqual(min_size, editor.adjustSize(0, 0));
    try testing.expectEqual(min_size, editor.adjustSize(1, 1));

    // Anything at or above the minimum passes through untouched.
    try testing.expectEqual(default_size, editor.adjustSize(default_size.width, default_size.height));
    try testing.expectEqual(min_size, editor.adjustSize(min_size.width, min_size.height));
}

test "set_size before a view is parented records the size the view will be built at" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));

    try testing.expect(editor.setSize(1280, 720));
    try testing.expectEqual(gpu.Size{ .width = 1280, .height = 720 }, editor.size());

    // Clamped, not refused: a host that skipped `adjust_size` still gets an
    // editor, and `get_size` is how it finds out what it got.
    try testing.expect(editor.setSize(10, 10));
    try testing.expectEqual(min_size, editor.size());
}

test "sizing is negotiable before create, the way get_size already is" {
    var editor: Editor = .{};

    // A host that asks how large the editor would be, before asking for one,
    // gets a consistent answer from all three rather than an answer from
    // `get_size` and a refusal from the other two.
    try testing.expectEqual(default_size, editor.size());
    try testing.expectEqual(min_size, editor.adjustSize(1, 1));

    try testing.expect(editor.setSize(1280, 720));
    try testing.expectEqual(gpu.Size{ .width = 1280, .height = 720 }, editor.size());
}

/// Counts `request_resize` calls and records the last size asked for, so the
/// pushback can be tested without a host.
const TestHostGui = struct {
    var calls: u32 = 0;
    var last: gpu.Size = .{ .width = 0, .height = 0 };

    fn requestResize(host: [*c]const c.clap_host_t, width: u32, height: u32) callconv(.c) bool {
        _ = host;
        calls += 1;
        last = .{ .width = width, .height = height };
        return true;
    }

    const ext: c.clap_host_gui_t = .{
        .resize_hints_changed = null,
        .request_resize = requestResize,
        .request_show = null,
        .request_hide = null,
        .closed = null,
    };

    fn reset() void {
        calls = 0;
        last = .{ .width = 0, .height = 0 };
    }
};

const test_host_gui: HostGui = .{ .ext = &TestHostGui.ext, .host = null };

test "a size the editor will not adopt is pushed back to the host" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    editor.host_gui = &test_host_gui;

    // REAPER honours `adjust_size` for the plugin's view and then shrinks its
    // own window past it regardless, which leaves the drawable pinned at the
    // minimum inside a window closing over it. `request_resize` is the only
    // mechanism CLAP offers to answer that.
    TestHostGui.reset();
    Editor.onResized(&editor, 200, 100);
    try testing.expectEqual(@as(u32, 1), TestHostGui.calls);
    try testing.expectEqual(min_size, TestHostGui.last);

    // And the editor's own record is the clamp, not what the host asked for.
    try testing.expectEqual(min_size, editor.size());
}

test "a legal size is never argued with" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    editor.host_gui = &test_host_gui;

    // The push-back fires only on a discrepancy. A host sizing the editor
    // within bounds must not be answered back, or every ordinary drag turns
    // into an argument between the two.
    TestHostGui.reset();
    Editor.onResized(&editor, 1280, 720);
    Editor.onResized(&editor, min_size.width, min_size.height);
    Editor.onResized(&editor, max_size.width, max_size.height);
    try testing.expectEqual(@as(u32, 0), TestHostGui.calls);
}

test "the push-back cannot re-enter itself" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));
    editor.host_gui = &test_host_gui;

    // A host that services `request_resize` synchronously delivers
    // `setFrameSize:` while the first call is still on the stack. The guard is
    // what stops a host answering an out-of-bounds size with another one from
    // bouncing between the two.
    TestHostGui.reset();
    editor.resizing = true;
    Editor.onResized(&editor, 10, 10);
    try testing.expectEqual(@as(u32, 0), TestHostGui.calls);

    editor.resizing = false;
    Editor.onResized(&editor, 10, 10);
    try testing.expectEqual(@as(u32, 1), TestHostGui.calls);
}

test "an editor with no host gui extension still clamps its own view" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));

    // A host that does not implement the extension leaves `host_gui` null. The
    // minimum then holds for the drawable and not for the host's window, which
    // is a degradation rather than a failure.
    Editor.onResized(&editor, 200, 100);
    try testing.expectEqual(min_size, editor.size());
}

test "a dimension that wrapped past zero collapses to the minimum" {
    // Not hypothetical. REAPER 7.78 sends exactly these while the user drags an
    // editor's bottom edge up past its top: 4294967295 and 4294967274 are -1
    // and -22, computed as signed CGFloat and delivered through CLAP's u32.
    const wrapped_minus_1: u32 = 4294967295;
    const wrapped_minus_22: u32 = 4294967274;

    try testing.expectEqual(min_size, clampSize(wrapped_minus_1, wrapped_minus_1));

    // Only the axis that went negative collapses. A drag that ran the height
    // past zero says nothing about the width the user still wants.
    try testing.expectEqual(
        gpu.Size{ .width = 960, .height = min_size.height },
        clampSize(960, wrapped_minus_22),
    );
}

test "an absurd size is bounded rather than passed to Metal" {
    // A height of 4294967295 saturated to 65535 crossing the mailbox and asked
    // for a 960x131070 drawable, eighty times Metal's texture limit, from a
    // thread with no way to refuse it.
    try testing.expectEqual(max_size, clampSize(100_000, 100_000));
    try testing.expectEqual(max_size.width, clampSize(std.math.maxInt(i32), 540).width);

    // Everything a real display could ask for passes through untouched.
    try testing.expectEqual(gpu.Size{ .width = 7680, .height = 4320 }, clampSize(7680, 4320));
}

test "a clamped size always survives the mailbox intact" {
    // The two bounds have to agree: `Pending` packs each axis into a `u16`, so
    // any size `clampSize` admits must fit without the saturation in `post`
    // silently changing it.
    try testing.expect(max_size.width <= std.math.maxInt(u16));
    try testing.expect(max_size.height <= std.math.maxInt(u16));

    var pending: Pending = .{};
    pending.post(clampSize(std.math.maxInt(u32), std.math.maxInt(u32)), 2.0);
    try testing.expectEqual(min_size, pending.take().?.size);

    pending.post(clampSize(100_000, 100_000), 2.0);
    try testing.expectEqual(max_size, pending.take().?.size);
}

test "an editor renders once parented, without waiting for a host to call show" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));

    // clap-wrapper's AUv2 view has both of its `gui->show()` calls commented
    // out, so the Audio Unit is parented and never shown. Gating the loop on a
    // positive `visible` left the display link created and never started, and
    // the editor in Logic drew nothing at all.
    try testing.expect(!editor.hidden);

    // `hide` is still the thing that stops it, and is still reversible.
    try testing.expect(editor.setHidden(true));
    try testing.expect(editor.hidden);
    try testing.expect(editor.setHidden(false));
    try testing.expect(!editor.hidden);
}

test "a degenerate size from AppKit is clamped rather than recorded" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));

    // An autoresizing subview whose superview shrinks past its width has its
    // frame floored at zero by AppKit, which arrives here as 0x0. Recording it
    // would leave `get_size` reporting a size the editor told the host it does
    // not support, and would be the size the view is rebuilt at on re-parent.
    Editor.onResized(&editor, 0, 0);
    try testing.expectEqual(min_size, editor.size());

    // And the mailbox never carries it either, from either direction: the
    // clamp above, and `post` dropping a zero regardless.
    try testing.expectEqual(min_size, editor.pending.take().?.size);
}

test "a posted resize is taken exactly once" {
    var pending: Pending = .{};

    try testing.expect(pending.take() == null);

    pending.post(.{ .width = 1280, .height = 720 }, 2.0);

    const update = pending.take().?;
    try testing.expectEqual(gpu.Size{ .width = 1280, .height = 720 }, update.size);
    try testing.expectEqual(@as(f64, 2.0), update.scale);

    // Drained. A size acted on twice would mean phase 3 reallocating textures
    // it had already reallocated.
    try testing.expect(pending.take() == null);
}

test "the last post wins, which is what a window drag produces" {
    var pending: Pending = .{};

    // One post per frame for the length of a drag. Only the newest describes
    // the editor the user is now looking at.
    pending.post(.{ .width = 700, .height = 400 }, 1.0);
    pending.post(.{ .width = 800, .height = 450 }, 1.0);
    pending.post(.{ .width = 900, .height = 500 }, 1.0);

    const update = pending.take().?;
    try testing.expectEqual(gpu.Size{ .width = 900, .height = 500 }, update.size);
    try testing.expect(pending.take() == null);
}

test "a degenerate post is dropped rather than encoded" {
    var pending: Pending = .{};

    // Metal rejects a zero-sized drawable, so each of these conveys nothing.
    // Dropping them is what lets all-zero double as the empty state.
    pending.post(.{ .width = 0, .height = 540 }, 2.0);
    try testing.expect(pending.take() == null);

    pending.post(.{ .width = 960, .height = 0 }, 2.0);
    try testing.expect(pending.take() == null);

    pending.post(.{ .width = 960, .height = 540 }, 0);
    try testing.expect(pending.take() == null);
}

test "a dropped post leaves an earlier one intact" {
    var pending: Pending = .{};

    pending.post(.{ .width = 960, .height = 540 }, 2.0);
    pending.post(.{ .width = 0, .height = 0 }, 2.0);

    // The degenerate post is discarded rather than clearing the mailbox, so the
    // render thread still learns about the resize that did happen.
    const update = pending.take().?;
    try testing.expectEqual(gpu.Size{ .width = 960, .height = 540 }, update.size);
}

test "an out-of-range size saturates rather than wrapping" {
    var pending: Pending = .{};

    // 65536 truncated to `u16` would be zero, which the mailbox reads as empty:
    // an absurd size would silently become a dropped resize instead of a
    // clamped one.
    pending.post(.{ .width = 100_000, .height = 70_000 }, 1.0);

    const update = pending.take().?;
    try testing.expectEqual(@as(u32, std.math.maxInt(u16)), update.size.width);
    try testing.expectEqual(@as(u32, std.math.maxInt(u16)), update.size.height);
}

test "the scale round trips exactly at the values AppKit reports" {
    var pending: Pending = .{};

    for ([_]f64{ 1.0, 2.0, 3.0, 1.5 }) |scale| {
        pending.post(default_size, scale);
        try testing.expectEqual(scale, pending.take().?.scale);
    }
}

test "an unusual scale round trips within a fraction of a pixel" {
    var pending: Pending = .{};

    // Fixed point in 1/256ths, so the worst case is half a step. Over a 4096
    // pixel drawable that is eight thousandths of a pixel.
    pending.post(.{ .width = 4096, .height = 4096 }, 1.7734375 + 0.001);

    const scale = pending.take().?.scale;
    try testing.expect(@abs(scale - 1.7734375) <= 0.5 / 256.0);
}

test "the meter reports a rate only once a window has elapsed" {
    var meter: Meter = .{};

    // `CLOCK_UPTIME_RAW` counts from boot, so the first reading is a baseline
    // rather than a measurement. Treating it as one would divide the frame
    // count by the machine's whole uptime.
    const boot: u64 = 900 * std.time.ns_per_s;
    try testing.expect(meter.observe(boot) == null);

    // 125 Hz rather than 120, so the period divides a second exactly and the
    // test measures the meter rather than integer division.
    const period = std.time.ns_per_s / 125;
    var now = boot;
    for (0..124) |_| {
        now += period;
        try testing.expect(meter.observe(now) == null);
    }

    // The frame that lands exactly on the window's edge closes it, and the
    // baseline call is not among the 125 counted.
    now += period;
    try testing.expectEqual(@as(f64, 125), meter.observe(now).?);

    // The window restarts rather than accumulating, so a loop that stalls after
    // a healthy second reports the stall rather than an average that hides it.
    try testing.expect(meter.observe(now + std.time.ns_per_s / 2) == null);
}

/// A window the host would hand to `set_parent`, carrying no view.
///
/// Zeroed rather than built field by field, because naming the union member
/// would mean spelling `unnamed_0` here, and the whole point of
/// `clap.cocoaView` is that the generated name appears in exactly one place.
fn testWindow(api: [*c]const u8) c.clap_window_t {
    var window = std.mem.zeroes(c.clap_window_t);
    window.api = api;
    return window;
}

test "set_parent refuses an editor that was never created" {
    var editor: Editor = .{};
    var diags: gpu.Diagnostics = .{};

    // Refused before the window is read at all, which is what makes a fixture
    // carrying no view safe to hand over.
    const window = testWindow(&c.CLAP_WINDOW_API_COCOA);
    try testing.expectError(error.NotCreated, editor.setParent(&window, &diags));
}

test "set_parent refuses a window carrying no view" {
    var editor: Editor = .{};
    defer editor.destroy();
    try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));

    var diags: gpu.Diagnostics = .{};
    const window = testWindow(&c.CLAP_WINDOW_API_COCOA);

    try testing.expectError(error.NoParentView, editor.setParent(&window, &diags));
    try testing.expect(editor.view == null);
}

test "set_parent refuses a window whose api is not the one create accepted" {
    // Every member of the union is pointer-sized, so a window the host filled in
    // as x11 or win32 would hand over a plausible pointer that is not an
    // NSView. The api has to be judged before the union is read, not after.
    for ([_][*c]const u8{
        &c.CLAP_WINDOW_API_WIN32,
        &c.CLAP_WINDOW_API_X11,
        &c.CLAP_WINDOW_API_WAYLAND,
        &c.CLAP_WINDOW_API_UIKIT,
        null,
    }) |api| {
        var editor: Editor = .{};
        defer editor.destroy();
        try testing.expect(editor.create(&c.CLAP_WINDOW_API_COCOA, false));

        var diags: gpu.Diagnostics = .{};
        const window = testWindow(api);

        try testing.expectError(error.WrongWindowApi, editor.setParent(&window, &diags));
        try testing.expect(editor.view == null);
    }
}
