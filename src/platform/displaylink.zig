//! The render loop's clock, in both senses: `CVDisplayLink`, which decides when
//! a frame happens, and the monotonic reading the result is measured against.
//!
//! CoreVideo calls back on a thread of its own, at the refresh rate of one
//! specific display, which is what makes frames paced by vsync rather than by
//! whatever timer the host happens to run its UI on.
//!
//! Deliberately knows nothing about Metal and nothing about AppKit. It takes a
//! display id and a callback and hands back something that can be started,
//! stopped, and retargeted; who decides which display, and what happens on a
//! tick, both live above it.
//!
//! **`CVDisplayLink` is deprecated as of macOS 15.** It is kept anyway. The
//! replacements, `CAMetalDisplayLink` and `-[NSView displayLinkWithTarget:
//! selector:]`, are macOS 14 and later, and this project's deployment target is
//! 11.0 in four places (`build.zig`, `cmake/CMakeLists.txt`, `macos/Info.plist`
//! and `packaging/distribution.xml`), under ADR 0001, which is the decision
//! rather than a fifth site. Raising that is a deliberate decision that wants an ADR,
//! not a side effect of picking a clock. Nothing warns in the meantime: the
//! declarations below are Zig's, so no deprecated header attribute is ever read.

const std = @import("std");

const io = @import("io.zig");

/// A `CGDirectDisplayID`. Opaque to callers, who get one from the view.
pub const DisplayID = u32;

const CVReturn = i32;
const cv_return_success: CVReturn = 0;

const CVDisplayLinkRef = *anyopaque;
const CVOptionFlags = u64;

/// CoreVideo's output callback, as the ABI sees it.
///
/// The two `const CVTimeStamp *` parameters are declared opaque rather than
/// restated. Every parameter here is pointer-sized, so this is ABI-identical to
/// the real signature, and `CVTimeStamp` is 80 bytes with a nested `CVSMPTETime`
/// that nothing in this project reads.
///
/// **This comment used to say that phase 3's frame-rate-independent decay would
/// be the caller that changed it. That work is #56, it has landed, and it went
/// the other way** — the decay reads `monotonicNanos()` below. The reasoning is
/// here rather than in the issue because it is the kind of thing that looks
/// arbitrary a year later, and here is where someone would come looking.
///
/// **Exponential decay composes.** `exp(-(a + b) / tau)` is
/// `exp(-a / tau) * exp(-b / tau)`, so the total fade across an interval depends
/// only on how long it was and not on how it was cut into frames. Both clocks are
/// monotonic and both cover the whole interval, so both sum to the same wall
/// time. What `output_time` buys is a better *subdivision* on a frame that misses
/// its deadline: a phase error of at most one refresh period against a 158 ms time
/// constant, absorbed by the next interval rather than accumulated.
/// `src/gpu/palette.zig` holds that property as a test.
///
/// Against that, restating the struct means laying out 80 bytes by hand with no
/// header to check them against, and threading a timestamp through `create`'s
/// comptime callback into `Editor.tick`. A wrong field offset does not fail: it
/// yields a plausible `dt` and a phosphor that fades at the wrong speed, which is
/// the hardest kind of wrong to notice and the kind this project keeps naming.
///
/// So the rule this comment cited still holds and now cuts the other way: types
/// arrive with the phase that has a caller for them, and the phase that would
/// have had one measured what it would buy and declined. Revisit only with a
/// reason that survives the composition argument above.
const OutputCallback = *const fn (
    link: CVDisplayLinkRef,
    now: ?*const anyopaque,
    output_time: ?*const anyopaque,
    flags_in: CVOptionFlags,
    flags_out: ?*CVOptionFlags,
    context: ?*anyopaque,
) callconv(.c) CVReturn;

extern "c" fn CVDisplayLinkCreateWithCGDisplay(
    display: DisplayID,
    out: *?CVDisplayLinkRef,
) CVReturn;
extern "c" fn CVDisplayLinkSetOutputCallback(
    link: CVDisplayLinkRef,
    callback: OutputCallback,
    context: ?*anyopaque,
) CVReturn;
extern "c" fn CVDisplayLinkSetCurrentCGDisplay(link: CVDisplayLinkRef, display: DisplayID) CVReturn;
extern "c" fn CVDisplayLinkStart(link: CVDisplayLinkRef) CVReturn;
extern "c" fn CVDisplayLinkStop(link: CVDisplayLinkRef) CVReturn;
extern "c" fn CVDisplayLinkRelease(link: CVDisplayLinkRef) void;

/// The display the menu bar is on. The fallback for a view that is not in a
/// window yet, or is in one that no screen claims.
pub extern "c" fn CGMainDisplayID() DisplayID;

/// Nanoseconds on a monotonic clock.
///
/// `awake` is `CLOCK_UPTIME_RAW` on macOS: monotonic, unadjustable, and not
/// advanced while the machine is asleep, which is what makes it the right clock
/// for "how many frames did that second actually contain". Measuring the loop
/// against a clock that wandered would report a rate that says nothing.
///
/// Zig 0.16 moved every clock behind an `Io` instance, and this reads the one
/// `platform/io.zig` owns rather than declaring `clock_gettime_nsec_np` here.
/// That was measured before it was chosen and it costs nothing (ADR 0015). It
/// stays in this file because the only thing that reads it is the render loop
/// this file paces.
///
/// **#56 gave it a caller that is not debug-only**, which is the one thing about
/// it that changed. It used to be reached solely from `Editor.report` and was
/// stripped from a release build with it; the decay reads it every frame, so a
/// `--release=fast` binary now imports `clock_gettime_nsec_np` and is 176 bytes
/// larger. `Io.Threaded`'s symbols are still absent from that binary, which is
/// the thing ADR 0015 was actually worried about, and this is still the only
/// clock anything here reads.
///
/// The cast is lossless in the only direction that exists: `Io.Timestamp` counts
/// signed `i96` nanoseconds, and `awake` counts from boot, so the value is
/// non-negative and nowhere near 64 bits.
pub fn monotonicNanos() u64 {
    return @intCast(std.Io.Clock.awake.now(io.get()).nanoseconds);
}

pub const DisplayLink = struct {
    link: CVDisplayLinkRef,

    /// [main-thread] Build a link against one display and point it at `tick`.
    ///
    /// `tick` is a **comptime** parameter, which is what lets `context` be the
    /// caller's own pointer rather than half of a pair the caller would have to
    /// find somewhere stable to keep. CoreVideo carries exactly one `void *`,
    /// and taking the function at comptime spends it on the thing that actually
    /// varies between callers.
    ///
    /// Returns null rather than an error: every failure here means this machine
    /// would not give us a display link, and a caller can do nothing different
    /// about which one it was.
    pub fn create(
        display: DisplayID,
        comptime tick: fn (context: *anyopaque) void,
        context: *anyopaque,
    ) ?DisplayLink {
        const trampoline = struct {
            fn call(
                link: CVDisplayLinkRef,
                now: ?*const anyopaque,
                output_time: ?*const anyopaque,
                flags_in: CVOptionFlags,
                flags_out: ?*CVOptionFlags,
                ctx: ?*anyopaque,
            ) callconv(.c) CVReturn {
                _ = link;
                _ = now;
                _ = output_time;
                _ = flags_in;
                _ = flags_out;

                if (ctx) |c| tick(c);

                // Anything other than success and CoreVideo stops calling us,
                // silently. A frame this plugin chose to skip is not a reason
                // to end the render loop.
                return cv_return_success;
            }
        }.call;

        var link: ?CVDisplayLinkRef = null;
        if (CVDisplayLinkCreateWithCGDisplay(display, &link) != cv_return_success) return null;
        const created = link orelse return null;

        if (CVDisplayLinkSetOutputCallback(created, trampoline, context) != cv_return_success) {
            CVDisplayLinkRelease(created);
            return null;
        }

        return .{ .link = created };
    }

    /// [main-thread] Ticks begin arriving on CoreVideo's own thread from here.
    pub fn start(self: DisplayLink) bool {
        return CVDisplayLinkStart(self.link) == cv_return_success;
    }

    /// [main-thread] Idempotent, and safe on a link that never started.
    ///
    /// Note what this does **not** promise: CoreVideo does not document whether
    /// a callback already in flight has returned by the time this does. Anything
    /// that frees what a tick touches has to establish that separately. See
    /// `Editor.destroy`.
    pub fn stop(self: DisplayLink) void {
        _ = CVDisplayLinkStop(self.link);
    }

    /// [main-thread] Retarget to a different display, which is what a window
    /// dragged to another monitor needs: refresh rates differ, and a link still
    /// paced to the display the editor is no longer on is a render loop running
    /// at the wrong speed.
    pub fn setDisplay(self: DisplayLink, display: DisplayID) void {
        _ = CVDisplayLinkSetCurrentCGDisplay(self.link, display);
    }

    /// [main-thread] Stop first, then give up ownership.
    pub fn destroy(self: DisplayLink) void {
        self.stop();
        CVDisplayLinkRelease(self.link);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// No test creates a display link. Doing so would start a real thread inside a
// test binary with no window server, which is a different environment from the
// one this code runs in, and would leave the runner's exit racing a callback.
// The loop is verified by opening the editor in a host.

test {
    // Forces the extern declarations and the trampoline above to be
    // type-checked here rather than at the first call site in `gui.zig`. Zig
    // analyses a function body only when something references it, and a display
    // link nothing had instantiated yet would otherwise be, in effect,
    // uncompiled.
    testing.refAllDecls(@This());
    testing.refAllDecls(DisplayLink);
}

// The clock is the one thing in this file a test can reach, and since #56 it is
// on the release hot path: the decay reads it every frame, so a units mistake
// here changes how fast the phosphor fades and nothing else in the project
// would see it. `palette.decayOver` takes `dt` as a parameter and would agree
// with a wrong clock about anything.
//
// A thousand readings measured **26,792 ns** on this machine, against a 41.67 ns
// tick on a 24 MHz timebase, so the strict advance clears its floor by nearly
// three orders of magnitude, and a clock truncated to milliseconds fails it.
//
// **The scale is checked against a second clock rather than against a constant,
// and that was measured rather than chosen.** The first version of this test
// bounded the span by one second, on the reasoning that a `* 1000` error would
// eat the margin. It does not: a thousand readings is 26.8 µs, so scaling by a
// thousand yields 26.8 ms and passes a one-second ceiling with room to spare.
// The plant proved it, passing where the other two failed. A ceiling tight
// enough to catch it would sit near 10 ms, which is 373x over the measured loop
// and one scheduler preemption away from a false red on a loaded runner.
//
// `Clock.real` is a different clock and is unaffected by anything wrong with
// this wrapper, so the *ratio* is what carries the claim. Both clocks measure
// one interval, so a preemption moves them together and cancels; a scale error
// moves only one, by three orders of magnitude, against a 100x bound. The
// shipping code still reads one clock and only one, which is what the docstring
// above claims; this is a test reaching for a second on purpose.
//
// What it still cannot prove: that the unit is nanoseconds, and that this is
// the clock that stops while the machine sleeps. Both are properties of the
// declaration this wraps and are argued in its docstring.
test "the render clock advances rather than repeating, and never runs backwards" {
    const reference_before = std.Io.Clock.real.now(io.get()).nanoseconds;
    const first = monotonicNanos();
    var previous = first;

    for (0..1000) |_| {
        const now = monotonicNanos();
        try testing.expect(now >= previous);
        previous = now;
    }

    const reference_after = std.Io.Clock.real.now(io.get()).nanoseconds;

    // It counts from boot, so a stub returning zero is caught here rather than
    // by the monotonicity above, which any constant satisfies.
    try testing.expect(first > 0);
    try testing.expect(previous > first);

    // Checked before the cast, because `real` is settable and a backwards NTP
    // step inside a 27 µs window would otherwise be a panic rather than a red.
    const reference_delta = reference_after - reference_before;
    try testing.expect(reference_delta > 0);

    const reference_span: u64 = @intCast(reference_delta);
    const span = previous - first;
    try testing.expect(span < reference_span * 100);
    try testing.expect(span * 100 > reference_span);
}
