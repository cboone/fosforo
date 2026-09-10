//! What the numbers off a rendered trace had to be.
//!
//! Everything here is arithmetic over two slices, an array of floats and an
//! array of bytes. No Metal, no GPU, no allocator, no I/O, and nothing above
//! this file's own imports, which is what lets `zig build test` cover all of it
//! on a runner with no graphics support at all (ADR 0009). `src/smoke.zig`
//! drives the renderer and supplies the readbacks; `src/gpu/measure.zig` reads
//! features out of them; this decides whether those features are the ones the
//! constants demand.
//!
//! **The split is the point rather than tidiness, and the argument was already
//! won on the other half of the same analysis.** ADR 0013's #51 amendment moved
//! the feature extraction into `measure.zig` because #38's defect was in the
//! analysis and not in the shader: its first period counter read the topmost lit
//! pixel against the centre row, a steep segment crossing the centre lights every
//! row it spans, and every tone came back exactly one period low. That reasoning
//! stopped at the extraction and never reached the *expectations*, which is what
//! this file is. It was vindicated a second time before this file existed:
//! `realTimeDecay` composes its expectation per step rather than asking
//! `decayOver` for the whole span, because the span clamps at
//! `palette.max_elapsed_nanos` and predicts 0.7684 against a true 0.5451, and
//! that was a defect in the check rather than in the shader.
//!
//! **Two vacuity holes and one asymmetry, and only planting told them apart.**
//! `decay` and `realTimeDecay` used to divide by a first peak nothing checked,
//! and `nan > 0.02 * want` is *false*, so a run that drew nothing at all read as
//! a healthy fade; planted, that returns `void` where the test now demands a
//! refusal. `periodRatio` used to index an `undefined` array written only inside
//! a `switch` over a literal frequency list, which was sound exactly while that
//! list stood. Both are closed below with a test that fails without the fix.
//!
//! The third was filed as a hole and is not one. #92 said `expectClose` was
//! "undefined if a future caller passes zero"; it performed no division, and at
//! zero it reduced to exact equality, which is the right answer. Planting the old
//! spelling back made its test pass, which is what forced the diagnosis to be
//! rewritten rather than encoded: the real defect was that it read its scale from
//! one of its two arguments. See `expectClose`.
//!
//! **The judges print and the printing is gated.** A test binary has to stay
//! silent: `std.debug.print` from inside one interleaves with the runner's
//! stream, which the build runner reads as a failed step despite a zero exit
//! code. That is ADR 0013's own reason for the harness being an executable, and
//! `say` below is `src/clap/log.zig:109`'s idiom applied to it.
//!
//! Two conventions, both stated because neither is forced by anything. Geometry
//! is read off the image rather than from the harness's constants, so a test can
//! judge an 8x4 picture instead of allocating 8.3 MB per case. And no judge
//! knows how many frames produced what it is looking at: the driver counts
//! frames, and everything here is a claim about a readback.

const std = @import("std");
const builtin = @import("builtin");

const iface = @import("iface.zig");
const measure = @import("measure.zig");
const palette = @import("palette.zig");

/// Everything a judge says, on stderr, and nothing at all in a test binary.
///
/// `src/clap/log.zig:109`'s idiom, for that file's reason rather than by
/// analogy: every one of these lines would otherwise interleave with the test
/// runner's own stream, which the build runner reads as a failed step. The
/// consequence is that the format strings themselves have no automated
/// coverage; they are verified by `zig build smoke-trace`, whose transcript is
/// the artefact this half is judged by.
fn say(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmt ++ "\n", args);
}

/// Every way a judge can refuse.
///
/// One named set rather than the thirty ad-hoc `error.Foo` literals these were
/// before, because `report` in `src/smoke.zig` prints `@errorName`, so these
/// names are the harness's output and not an implementation detail. Renaming one
/// changes what a failing CI log says.
///
/// `FramesNeverPresented` and `FrameSkipped` are deliberately absent: they are
/// the driver's, raised while a frame is being asked for rather than while a
/// picture is being judged.
pub const Fault = error{
    ReadbackTruncated,
    ReadbackGeometryMismatch,
    TraceNotDrawn,
    TraceNotFlat,
    CentreLineWrong,
    LevelMisplaced,
    RailMisplaced,
    RailNotSaturated,
    TraceInverted,
    TraceAsymmetric,
    TraceStartsLate,
    TraceEndsEarly,
    EdgeColumnDark,
    ColumnDropped,
    BeamWidthWrong,
    BeamNotSymmetric,
    PeriodMiscounted,
    PeriodRatioWrong,
    DepositNotScalar,
    BackgroundNotNeutral,
    BackgroundNotBlueLeading,
    BackgroundNotDark,
    BackgroundNotOpaque,
    BackgroundNotThePaletteAtZero,
    ResolveNotTheTonemap,
    MovingTraceTooDim,
    MovingTraceNotTinted,
    DwellNeverReachesWhite,
    CoreNotWhite,
    DecayWrong,
    DecayNotInRealTime,
    DepositNotVelocityWeighted,
};

/// The resolved picture, as `measure.Image` is the accumulation.
///
/// Here rather than in `measure.zig` because that file is entirely `f32`
/// arithmetic and has no function that touches a byte; the two halves of the
/// seam's `Readback` are paired by whoever judges them, which is this file.
///
/// Four bytes per pixel, RGBA, row-major from the top-left, which is what the
/// seam publishes. Longer than the geometry is accepted and the tail ignored, on
/// `measure.Image`'s precedent and for its reason: one buffer is reused across a
/// run of cases.
pub const Picture = struct {
    width: usize,
    height: usize,
    bytes: []const u8,

    pub fn pixel(self: Picture, x: usize, y: usize) []const u8 {
        const at = (y * self.width + x) * 4;
        return self.bytes[at .. at + 4];
    }

    /// Whether this picture's declared geometry fits the buffer it was handed.
    ///
    /// Overflow-safe for the reason `measure.Image.complete` gives at length: the
    /// product is `usize` arithmetic, and a wrapped one in `--release=fast` would
    /// report an undersized buffer as complete, which is the opposite of what
    /// this is for.
    pub fn complete(self: Picture) bool {
        const pixels = std.math.mul(usize, self.width, self.height) catch return false;
        const bytes = std.math.mul(usize, pixels, 4) catch return false;
        return self.bytes.len >= bytes;
    }
};

// ---------------------------------------------------------------------------
// The constants the judgements are stated in
// ---------------------------------------------------------------------------

/// The fraction of one segment's core deposit above which a pixel counts as lit.
///
/// An iso-intensity contour of the beam's falloff: the biweight reaches half its
/// peak at `u = 0.5412`, so the lit band is 54% of the half-width either side of
/// the centreline. Every geometric measurement below is stated at that contour
/// rather than at the beam's full width, which makes this the constant that sets
/// the effective beam width for the whole file. It is not `measure-trace`'s
/// 64-of-255: that tool reads an 8-bit picture through a display's colour space,
/// and this reads the float the shader wrote.
///
/// **A fraction rather than an energy since #58, and the number did not change.**
/// It was an absolute 0.5 for two issues, which was the same contour only because
/// a segment deposited 1.0 at its core whatever it was doing. Velocity weighting
/// ended that: what one segment lays down is now `beamWeight` of its screen
/// length, from about 0.60 where the beam dwells to 0.0034 on a full-height rod,
/// so a fixed energy stops being a contour and becomes an absolute brightness
/// assertion smuggled into every geometric judgement. `horizontalMapping` is
/// where that bit first and hardest: three samples make every segment 538 px
/// long, so *nothing in it* cleared 0.5 and it failed `TraceNotDrawn` with a
/// correctly drawn ramp in front of it.
///
/// **A fraction of the frame's *peak* was tried first and is wrong**, which is
/// worth recording because it is the obvious form and it fails subtly. Under
/// velocity weighting brightness and height are correlated: `period` counts
/// columns reaching above a half-amplitude band, and the trace is *moving* where
/// it crosses that band, so it is dim there. At two cycles the crossing deposits
/// 0.635 against a frame peak of 1.544, so a contour at half the peak read it as
/// dark and the two runs fragmented into **eight**. A fraction of one segment's
/// own deposit has no such coupling, because it is the same fraction of whatever
/// that segment was going to deposit.
///
/// Read it through `litLevel`, which each judgement hands the length its own
/// signal produces. Absolute energy is `movingCore`'s, `resolve`'s, `decay`'s and
/// `velocityWeighting`'s, and none of them concludes anything about brightness
/// from this.
pub const trace_threshold: f32 = 0.5;

/// The peak energy below which a frame is held to have drawn nothing at all.
///
/// Separate from the contour above and not derivable from it. A `TraceNotDrawn`
/// judgement asks whether the draw happened, which is a question about the
/// pipeline rather than about the beam, and the contour now varies over two
/// orders of magnitude with the signal.
///
/// Far below anything a real case produces and far above the format's noise.
/// Sized against the judgements that consult it, `depositIsScalar` and both arms
/// of `velocityWeighting`: the dimmest peak among them is the full-scale zigzag
/// at four samples per point, near 0.005, which leaves 50x of margin.
/// `RGBA16Float`'s smallest subnormal is 6e-8, three orders the other way. It
/// says "the draw was skipped or the pipeline drew nothing", not "the trace is
/// dim", and it must never be tightened into the second claim.
pub const trace_drawn: f32 = 1e-4;

/// Half the beam's width, in backing pixels, at the harness's geometry.
///
/// `initOffscreen` has no view whose scale it could read and uses 1.0, so points
/// and backing pixels are the same number there. That is a real limit rather
/// than a convenience: this half always judges a 1.5-pixel half-width and never
/// the 3.0 a 2x host draws, and the rail clearance and the row spans are both
/// tightest at 2x. `src/gpu/iface.zig` carries the same warning at the constant.
pub const beam_half_width_px: f32 = iface.beam_width_points / 2.0;

/// The segment pitch a window of `samples` gives across a drawable `width` wide.
///
/// **The window convention this file judges against**, stated once here rather
/// than assumed at six call sites: every case but `horizontalMapping` drives a
/// window of exactly `image.width` samples, so the pitch is one backing pixel and
/// a flat trace's segments are the shortest the geometry can produce. A judgement
/// that needs the length passes the sample count it knows.
pub fn segmentPitch(width: usize, samples: usize) f32 {
    // **Fewer than two samples is not a short window, it is no segment at all**,
    // which is what `traceGeometry` refuses to produce for the same reason. The
    // guard is unreachable from this file's callers, which pass `image.width` or
    // the literal 3, and it is kept on `beamDensity`'s precedent: a reader should
    // not have to work out what the arithmetic does at the edge to see that a
    // degenerate call is answered.
    //
    // What it answers is worse than a crash, which is why it is a guard rather
    // than an assertion. At one sample `samples - 1` is zero, the float division
    // yields `inf` rather than trapping, `beamWeight` turns `inf` into a weight of
    // **zero**, and `litLevel` then returns a contour of zero — under which every
    // pixel holding any energy counts as lit and every count this file reports is
    // silently wrong. At zero samples the subtraction underflows a `usize`, which
    // traps in Debug and wraps in `--release=fast`.
    //
    // Returning the full width is the continuous answer rather than a sentinel:
    // two samples give one segment spanning the drawable, and that is exactly
    // `width`, so the degenerate case reads as the limit of the real one.
    if (samples < 2) return @floatFromInt(width);

    return @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(samples - 1));
}

/// The screen length of a segment whose two samples are `travel_px` apart.
///
/// Both legs, because a segment always advances one pitch horizontally however
/// flat it is. That is why a stationary beam's segments are the pitch long rather
/// than zero long, and why `measure.beamWeight`'s floor is never actually reached.
pub fn segmentLength(width: usize, travel_px: f32, samples: usize) f32 {
    return std.math.hypot(segmentPitch(width, samples), travel_px);
}

/// `trace_threshold` resolved for a segment of a given screen length.
///
/// One function rather than the expression at its call sites, because a call site
/// that reverted to the bare `trace_threshold` would still compile and would
/// still pass on every flat case, which is where the constant is nearest its old
/// value.
pub fn litLevel(segment_len_px: f32) f32 {
    return trace_threshold * measure.beamWeight(segment_len_px, beam_half_width_px);
}

/// The screen length of a sine's segments at a chosen point on its cycle.
///
/// `cosine` selects the point, as the cosine of the phase: 1.0 is the zero
/// crossing, where the beam is fastest and dimmest, and `sqrt(3)/2` is the
/// half-amplitude band `period` counts against. A sine has no single segment
/// length, so a judgement that thresholds one has to say which part of it the
/// threshold is for.
pub fn sineSegment(
    width: usize,
    height: usize,
    cycles: f32,
    amplitude: f32,
    samples: usize,
    cosine: f32,
) f32 {
    // The same degenerate case as `segmentPitch`, and it has to be caught here
    // too because this computes its own `span` rather than going through it. With
    // no segment there is no travel either, so the flat length is the answer.
    if (samples < 2) return segmentPitch(width, samples);

    const rows: f32 = @floatFromInt(height);
    const span: f32 = @floatFromInt(samples - 1);

    const amplitude_px = amplitude * iface.trace_full_scale * rows / 2.0;
    const travel = amplitude_px * 2.0 * std.math.pi * cycles / span * cosine;

    return segmentLength(width, travel, samples);
}

/// The interval between frames on the harness's synthetic clock.
///
/// One frame at the decay's own reference rate, which is not an arbitrary choice
/// of nominal rate. `palette.decay_tau_nanos` is anchored so that exactly this
/// interval yields exactly the 0.90 per frame #55 shipped, so **every number
/// this half printed before #56 it still prints**: the per-pixel resolve
/// prediction, the white point and the five decay ratios are unchanged, and so
/// are the figures quoted from them in `AGENTS.md` and ADR 0019.
///
/// **The model's constant rather than `std.time.ns_per_s / 60`**, which is the
/// same interval only by coincidence: the division truncates to 16,666,666 ns
/// where `decay_reference_frame_nanos` rounds to 16,666,667. A nanosecond is
/// nothing here, since `decayOver` returns a bit-identical `f32` for both, but a
/// second spelling of "one frame at the reference rate" is a second thing to
/// keep in step with the anchor.
pub const trace_frame_nanos: u64 = palette.decay_reference_frame_nanos;

/// What the phosphor keeps between two of the harness's frames.
///
/// 0.90, and the model is asked rather than told so that a `tau` moved without
/// this file being reopened changes the expectations here instead of leaving
/// them asserting the old look.
pub const trace_decay: f32 = palette.decayOver(trace_frame_nanos);

/// The frequencies `period` is asked about, and the three the ratio arm reads.
///
/// A named list rather than a literal in a `for`, because the ratio arm used to
/// pick 2, 4 and 8 out of it with a `switch` writing into an `undefined` array.
/// That was sound only while this exact list stood, and silently unsound the
/// moment it changed.
pub const period_cycles = [_]usize{ 1, 2, 4, 5, 8, 20 };

const doubling_at = [_]usize{ 1, 2, 4 };

comptime {
    // The ratio form needs three frequencies standing in 1:2:4, which is a
    // property of the list above rather than of the arithmetic below. Asserted
    // here so that reordering `period_cycles` is a compile error rather than an
    // arm quietly comparing three unrelated counts.
    if (period_cycles[doubling_at[1]] != period_cycles[doubling_at[0]] * 2 or
        period_cycles[doubling_at[2]] != period_cycles[doubling_at[1]] * 2)
    {
        @compileError("the doubling arm needs three frequencies in a 1:2:4 ratio");
    }
}

/// How much simulated wall time `realTimeDecay` fades across.
///
/// 96 ms rather than a round 100, so that both arms below divide it into whole
/// nanoseconds and span *exactly* the same interval: 12 steps of 8 ms and 6 of
/// 16 ms. An interval the two could only approximate would put a residual
/// difference into the measurement this check is reading a difference out of.
pub const decay_span_nanos: u64 = 96 * std.time.ns_per_ms;

/// One rate the phosphor is faded at, and how many steps it takes to span
/// `decay_span_nanos`.
pub const Arm = struct { interval_nanos: u64, steps: u64 };

/// The two rates, 125 Hz and 62.5 Hz, which bracket the rates this machine's
/// panel actually produces.
///
/// **The divisibility the docstring above argues for is asserted here rather
/// than argued.** It used to be `decay_span_nanos / interval` inside the loop,
/// an integer division whose exactness was a claim in prose; an interval that
/// did not divide evenly would truncate, and the two arms would silently stop
/// spanning the same simulated interval, which is the one property the whole
/// check rests on.
///
/// `@compileError` rather than `std.debug.assert`, because `--release=fast`
/// strips the latter and this is a claim about constants.
pub const decay_arms = arms: {
    const intervals = [_]u64{ 8 * std.time.ns_per_ms, 16 * std.time.ns_per_ms };
    var out: [intervals.len]Arm = undefined;
    for (intervals, &out) |interval, *slot| {
        if (decay_span_nanos % interval != 0) {
            @compileError("decay_span_nanos must divide every arm's interval exactly");
        }
        slot.* = .{ .interval_nanos = interval, .steps = decay_span_nanos / interval };
    }
    break :arms out;
};

/// `a` and `b` within `tolerance` relatively, or the caller's fault.
///
/// **Scaled by the larger of the two, and the defect that fixes is asymmetry
/// rather than zero.** #92 was filed saying this was "undefined if a future
/// caller passes zero", and working it turned out to be wrong twice over: the
/// old spelling was `@abs(a - b) > tolerance * @abs(b)`, which performs no
/// division at all, and at `b == 0` it reduces to exact equality, which is the
/// *right* answer for a relative tolerance since nothing is relatively close to
/// zero but zero. Both spellings agree there, which was established by planting
/// the old one and watching its test pass.
///
/// What the old spelling really got wrong is that it read its scale from one of
/// its two arguments, so `expectClose(x, y, t)` and `expectClose(y, x, t)` could
/// disagree: at `a = 2`, `b = 1` and a tolerance of 0.75 the old form refuses and
/// the new one accepts. A caller that swapped its measured and predicted values
/// would have got a different verdict for no reason it could see. Taking the
/// maximum is symmetric by construction and still leaves a zero scale only where
/// equality already holds.
fn expectClose(a: f32, b: f32, tolerance: f32, fault: Fault) Fault!void {
    if (@abs(a - b) > tolerance * @max(@abs(a), @abs(b))) return fault;
}

/// Refuse a readback shorter than the geometry it claims, before indexing it.
///
/// **Every judge that indexes calls this, and the uniformity is the point.**
/// Before #105 exactly two did: `silence`, which `traceHalf` runs first and
/// which therefore guarded the whole run by position rather than by design, and
/// `resolve`, where the check was added during the refactor for no stated
/// reason. Thirteen others indexed unguarded. That asymmetry read as a claim
/// that some judges need the check and others do not, and no such claim was
/// true.
///
/// **The crash it prevents is unreachable from the harness and reachable from a
/// test, which is what changed.** `traceHalf` allocates one pair of buffers at
/// exactly `trace_width * trace_height * 4` and `Probe` declares that same
/// geometry, so the shipping caller cannot produce a short readback. What #92
/// changed is that these are public functions a test can hand any `Image` to,
/// and the tests do exactly that. A Debug build would panic on the bounds rather
/// than corrupt anything, but `Fault.ReadbackTruncated` is in the error set to be
/// returned, and an error two of the fifteen entrypoints there were then could
/// return was nearly dead.
///
/// Longer than the geometry stays fine and the tail stays ignored, which is
/// `measure.Image`'s own documented contract and what lets one buffer serve a
/// run of smaller cases.
///
/// **Length alone is not enough, which the first version of this got wrong.**
/// Two buffers can each be long enough for the geometry *they* declare and still
/// disagree with each other, and the judges that read both loop over the image's
/// geometry while indexing the picture. At an image of 16x8 against a picture of
/// 8x8, `Picture.complete()` demands 256 bytes and `resolve` indexes to 284, so
/// both halves pass and the read still runs off the end. The geometries have to
/// agree, not merely each be honest about itself.
///
/// **The structural alternative was considered and not taken.** `iface.Readback`
/// models this correctly already: one geometry, two buffers. A `Picture` that
/// carried no geometry of its own, indexed through the image's, would make the
/// mismatch unrepresentable rather than merely refused. It is the better shape
/// and it costs every judge signature plus every test that hands a judge
/// an image alone, which is most of them. Recorded here so the next person to
/// touch this can weigh it with the reason rather than rediscovering it.
fn requireComplete(image: measure.Image, picture: ?Picture) Fault!void {
    if (!image.complete()) return Fault.ReadbackTruncated;
    if (picture) |shown| {
        if (!shown.complete()) return Fault.ReadbackTruncated;
        if (shown.width != image.width or shown.height != image.height) {
            return Fault.ReadbackGeometryMismatch;
        }
    }
}

// ---------------------------------------------------------------------------
// The judgements
// ---------------------------------------------------------------------------

pub const Silence = struct { lit: usize, centroid: f32, implied: f32 };

/// A window of zeros draws one flat line through the centre.
pub fn silence(image: measure.Image) Fault!Silence {
    try requireComplete(image, null);

    const contour = litLevel(segmentLength(image.width, 0.0, image.width));
    const lit = measure.litColumns(image, contour);
    if (lit != image.width) {
        say("  silence lit {d} of {d} columns", .{ lit, image.width });
        return Fault.TraceNotDrawn;
    }

    const seen = measure.extremes(image, contour) orelse return Fault.TraceNotDrawn;

    // **The bound is the beam's own depth, and it is parity-dependent.** Before
    // #57 this was one row of slack for the centre line falling on a pixel
    // boundary; a beam has width, so what is being checked is that the beam is
    // flat rather than that it is thin. At an even height the centreline sits on
    // the boundary and the profile straddles it symmetrically; at an odd one it
    // sits on a pixel centre and lights one more row. `1440x407` is already a
    // geometry this project tests, so the odd case is not hypothetical.
    const parity: usize = if (image.height % 2 == 0) 0 else 1;
    const deepest = 2 * @as(usize, @intFromFloat(@ceil(beam_half_width_px))) + parity;

    if (seen.bottom - seen.top > deepest) {
        say("  silence spans rows {d} to {d}", .{ seen.top, seen.bottom });
        return Fault.TraceNotFlat;
    }

    // **The centroid rather than the topmost lit row, and the difference is the
    // whole of what #38 left open here.** A symmetric profile centred on the
    // boundary between two rows weights them equally, so its energy-weighted
    // centre is that boundary exactly, and the mapping inverts it to exactly
    // zero. The `+0.0021` #38 measured in REAPER was never the geometry being
    // off by a fifth of a pixel; it was an estimator reading an edge. No
    // corrective bias was needed and none is applied.
    const centre = measure.centres(image) orelse return Fault.TraceNotDrawn;
    const implied = measure.impliedSampleAt(centre.top, image.height);
    say("  silence: centroid row {d:.3}, implying a sample of {d:.5}", .{ centre.top, implied });

    // A twentieth of a pixel rather than a whole one. `pixelTolerance` is what an
    // edge estimator needed; asserting the old bound here would pass on a beam
    // sitting a pixel high and is exactly the slack this check exists to remove.
    if (@abs(implied) > measure.pixelTolerance(image.height) / 20.0) return Fault.CentreLineWrong;

    return .{ .lit = lit, .centroid = centre.top, .implied = implied };
}

pub const Level = struct { centroid: f32, implied: f32, off: f32 };

/// One level lands where the constants say, inside one pixel.
///
/// The centroid, for the reason `silence` gives: a beam's top edge is biased
/// above its centre by the lit half-width, identically at every level, and a
/// systematic error with one sign is precisely what a one-pixel tolerance must
/// not be asked to absorb.
pub fn level(image: measure.Image, want: f32) Fault!Level {
    try requireComplete(image, null);
    const seen = measure.centres(image) orelse return Fault.TraceNotDrawn;

    const implied = measure.impliedSampleAt(seen.top, image.height);
    const off = @abs(implied - want);
    say("  level {d: >6.3}: centroid row {d: >7.2}, implying {d: >8.5}, off by {d:.5}", .{
        want,
        seen.top,
        implied,
        off,
    });

    if (off > measure.pixelTolerance(image.height)) return Fault.LevelMisplaced;
    return .{ .centroid = seen.top, .implied = implied, .off = off };
}

/// Every level at or above the rail lands on exactly the same row.
///
/// **A fold over the measured rows rather than a running comparison**, because
/// each arm needs its own renderer and the readback buffer is overwritten by the
/// next one. The driver collects the centroids; this decides. The transcript is
/// unchanged either way, since only the first arm prints on success and nothing
/// else prints between the first arm and the last.
///
/// `levels` is parallel to `rows` and is read only to name the offender in the
/// failure message.
pub fn saturation(levels: []const f32, rows: []const f32, height: usize) Fault!void {
    if (levels.len != rows.len or rows.len == 0) return Fault.RailNotSaturated;

    // 1.111 is `1 / trace_full_scale`, where the trace would reach the drawable's
    // edge if nothing clamped. It is unreachable because `trace_rail` clamps
    // first, and everything from there up must be pixel-identical: that
    // saturation is the whole of what ADR 0017 means by refusing to say how far
    // over a signal is.
    const expected = measure.railRow(height);
    say("  rail: centroid row {d:.3}, expected {d:.1}", .{ rows[0], expected });
    if (@abs(rows[0] - expected) > 0.1) return Fault.RailMisplaced;

    for (levels[1..], rows[1..]) |over, row| {
        // Bit-identical rather than within a tolerance, which the centroid makes
        // available and the edge estimator did not: these are the same clamped
        // geometry drawn twice, so anything but equality is a defect rather than
        // a rounding.
        if (row != rows[0]) {
            say("  {d} railed on centroid row {d:.3}, not {d:.3}", .{ over, row, rows[0] });
            return Fault.RailNotSaturated;
        }
    }
}

/// Positive is up, negative is down, and by the same distance.
///
/// **This is the check the edge estimator broke worst, and the reason is worth
/// keeping.** Both arms read `top`, so a beam of half-width `h` moved both edges
/// up: `above` grew by `h` and `below` shrank by it, and the quantity asserted
/// on here was `2h`. It failed at a half-width over half a pixel, for a reason
/// that had nothing to do with symmetry, and no tolerance wide enough to pass
/// would have been measuring anything. A centroid is unbiased in both
/// directions, so the two arms cancel and the slack drops to a tenth of a pixel.
///
/// A Y flip would put both on the same side; an asymmetric clamp would leave
/// them at different distances.
pub fn symmetry(rows: [2]f32, height: usize) Fault!void {
    const centre = measure.centreRow(height);
    const above = centre - rows[0];
    const below = rows[1] - centre;
    say("  symmetry: +0.5 sits {d:.2} above centre, -0.5 sits {d:.2} below", .{ above, below });

    if (above <= 0 or below <= 0) return Fault.TraceInverted;
    if (@abs(above - below) > 0.1) return Fault.TraceAsymmetric;
}

/// The first and last samples land on the drawable's edges.
pub fn horizontalMapping(image: measure.Image) Fault!measure.Span {
    try requireComplete(image, null);
    // **The contour, not an absolute energy, and this case is why that changed.**
    // Three samples put the segment pitch at a third of the drawable, so both
    // segments are about 538 px long and #58's weighting takes their peak to
    // 0.0028. Read against the old fixed 0.5 this failed `TraceNotDrawn` with a
    // perfectly drawn ramp in front of it; the geometry it is about was never in
    // question.
    const travel = measure.expectedRow(0.0, image.height) - measure.expectedRow(1.0, image.height);
    const contour = litLevel(segmentLength(image.width, travel, 3));
    const span = measure.litSpan(image, contour) orelse return Fault.TraceNotDrawn;
    say("  three samples span columns {d} to {d} of {d}", .{ span.first, span.last, image.width - 1 });

    // **Exactly the edge columns, with no slack, and #57 is what removed it.**
    // The one column either side used to be for the diamond-exit rule, under
    // which a line strip's final endpoint need not light the pixel it lands on. A
    // quad has area and does light it, which `edgeColumns` asserts at the level
    // that actually failed in #38; keeping a tolerance here after that would be
    // carrying a defect's allowance past the fix for it.
    if (span.first != 0) return Fault.TraceStartsLate;
    if (span.last != image.width - 1) return Fault.TraceEndsEarly;

    // And the vertical, which the same window checks for free: the ramp runs from
    // -1 at the left to +1 at the right, so the corners are the extremes.
    const left = measure.topRow(image, span.first, contour) orelse return Fault.TraceNotDrawn;
    const right = measure.topRow(image, span.last, contour) orelse return Fault.TraceNotDrawn;
    if (right >= left) {
        say("  the ramp does not rise: column {d} is row {d}, column {d} is row {d}", .{
            span.first,
            left,
            span.last,
            right,
        });
        return Fault.TraceInverted;
    }

    return span;
}

pub const Lit = struct { lit: usize, span: measure.Span };

/// A railed trace lights every column, including the two on the edges.
///
/// **#38's open question, asked of a single frame for the first time.** Its
/// level sweep found `level-1.089.wav` lighting 1914 of 1920 columns where every
/// other level lit all of them, and named the likely cause: the first and last
/// vertices sit at `x = ±1` exactly, where half a one-pixel line's coverage
/// diamond is off-screen and the rasterizer may light nothing.
///
/// Re-run against #55's accumulation the count came back clean at every level,
/// and #57's own comment refused to read that as the defect having gone: a lit
/// pixel survives roughly 28 frames of persistence, so a column this frame's
/// coverage dropped is still lit from an earlier one, and a screenshot of an
/// accumulated picture cannot tell an intermittent dropout from a fixed one.
///
/// This can, because the driver runs one deposit into a cleared accumulation.
/// And the answer is structural rather than measured: a quad has area, so the
/// first segment spans a whole pixel horizontally and contains that pixel's
/// centre, where a line's endpoint was a point that had to exit a diamond to
/// light anything.
///
/// **The round caps are not what does it, which planting established.** Cutting
/// them off entirely, butt joints with no extension along the segment, still
/// reads 960 of 960 here. So this check is weaker than it looks against the cap
/// geometry and exactly as strong as it should be against the thing that
/// actually failed.
pub fn edgeColumns(image: measure.Image) Fault!Lit {
    try requireComplete(image, null);
    const contour = litLevel(segmentLength(image.width, 0.0, image.width));
    const lit = measure.litColumns(image, contour);
    const span = measure.litSpan(image, contour) orelse return Fault.TraceNotDrawn;

    say("  railed: {d} of {d} columns lit, spanning {d} to {d}", .{
        lit,
        image.width,
        span.first,
        span.last,
    });

    if (span.first != 0 or span.last != image.width - 1) return Fault.EdgeColumnDark;
    if (lit != image.width) return Fault.ColumnDropped;

    return .{ .lit = lit, .span = span };
}

pub const Beam = struct { integral: f32, expected: f32, centre: f32 };

/// The beam has the width it was asked for, measured in pixels rather than in
/// clip space.
///
/// What is asserted is the cross-section's **integral**, not its lit extent. The
/// biweight integrates to `16/15` of the half-width, which is 1.6 pixels at the
/// harness's geometry, and an integral is robust where a thresholded width is
/// not: at these dimensions the lit band is under two pixels, so quantization is
/// the same size as the quantity, and a check on it would be measuring rounding.
///
/// **It is the only judge here that can see clip space mistaken for pixels.**
/// The drawable is 960x540, so expanding by a half-width in NDC rather than in
/// pixels makes the beam elliptical, 1.78 times wider one way than the other,
/// which every other check in this file reads as a slightly different row and
/// passes.
///
/// `row` is the driver's choice of cross-section, and the driver's docstring
/// says why it must be one a single steep segment crosses alone.
pub fn beamProfile(image: measure.Image, row: usize, weight: f32) Fault!Beam {
    try requireComplete(image, null);
    // A cross-section outside the drawable is the same class of caller mistake
    // as two readbacks disagreeing: the parameters and the declared geometry do
    // not describe one picture. It is not a *truncated* readback, and saying so
    // would put a misleading name in a failing transcript.
    if (row >= image.height) return Fault.ReadbackGeometryMismatch;
    var total: f32 = 0;
    var moment: f32 = 0;
    var x: usize = 0;
    while (x < image.width) : (x += 1) {
        const e = image.green(x, row);
        total += e;
        moment += e * @as(f32, @floatFromInt(x));
    }

    if (total <= 0) return Fault.TraceNotDrawn;

    // `16/15` is the integral of the biweight over its support, which is what
    // makes this a statement about that profile rather than about any curve of
    // roughly the right size.
    //
    // **Times the rod's own velocity weight since #58**, which is the whole of
    // what that issue does here and is what makes this a second instrument for
    // it. A cross-section is energy *per unit length*, and that is exactly the
    // quantity velocity weighting divides: the driver's rod is 437 px long, so it
    // deposits about 0.0034 of what a dwelling beam does and the integral falls
    // with it.
    //
    // **The weight is the caller's rather than derived here**, because this
    // judgement is also fed by `measure.rasterize`, whose model deposits an
    // unweighted profile. A test passes 1.0 and says so; the driver passes
    // `measure.beamWeight` of the rod its own window produced, computed from the
    // constants that place the step rather than from the picture, so the
    // comparison is still between two derivations.
    const want = beam_half_width_px * 16.0 / 15.0 * weight;
    const centre = moment / total;
    say("  beam: cross-section integrates to {d:.6}, expected {d:.6}, at a weight of {d:.6}, centred on column {d:.2}", .{
        total,
        want,
        weight,
        centre,
    });

    if (@abs(total - want) > want * 0.05) return Fault.BeamWidthWrong;

    // And it is symmetric about that centre, which is what a bowtie from a strip
    // whose corners run the wrong way, or a mirrored quad, would not be. Compared
    // as the two halves' energy rather than pixel by pixel, so it says nothing
    // about the profile's shape that the integral above has not already said.
    var left: f32 = 0;
    var right: f32 = 0;
    x = 0;
    while (x < image.width) : (x += 1) {
        const e = image.green(x, row);
        const d = @as(f32, @floatFromInt(x)) - centre;
        if (d < 0) left += e else if (d > 0) right += e;
    }

    if (@abs(left - right) > total * 0.05) return Fault.BeamNotSymmetric;

    return .{ .integral = total, .expected = want, .centre = centre };
}

/// A sine of k cycles shows exactly k periods.
///
/// Strict equality. #38's first counter was off by exactly one at every
/// frequency and a ±1 tolerance reported all six as correct, which is what "a
/// tolerance wide enough to absorb a systematic error is a tolerance that hides
/// one" was written about.
pub fn period(image: measure.Image, cycles: usize) Fault!usize {
    try requireComplete(image, null);
    // The band crossing rather than the turning point, because that is the
    // brightness this count has to be able to see: `measure.periods` reads
    // *height*, and under #58 the trace is dim exactly where it reaches the band.
    const at_band = sineSegment(image.width, image.height, @floatFromInt(cycles), 0.8, image.width, @sqrt(3.0) / 2.0);
    const counted = measure.periods(image, litLevel(at_band));
    say("  {d: >2} cycles in, {d: >2} periods counted", .{ cycles, counted });
    if (counted != cycles) return Fault.PeriodMiscounted;
    return counted;
}

/// Energy per unit length falls as one over a segment's screen length.
///
/// **ADR 0007's "single relationship" (#58), read at a cross-section.** A window
/// that steps from `+a` to `-a` at its midpoint draws one segment across the
/// centre row and puts its two flat runs far above and below, so `rowEnergy` at
/// that row is that segment's cross-section and nothing else's. That is energy
/// *per unit length*, which is the form the issue and the ADR are written in and
/// the quantity velocity weighting divides.
///
/// The expectation is `(16/15) * h * beamWeight(len)`: the biweight's own
/// integral times the weight the driver's geometry implies, both computed from
/// constants rather than from the picture.
pub fn velocityPerLength(image: measure.Image, row: usize, len: f32) Fault!f32 {
    try requireComplete(image, null);
    if (row >= image.height) return Fault.ReadbackGeometryMismatch;
    if (measure.maxChannel(image, 1) <= trace_drawn) return Fault.TraceNotDrawn;

    const total = measure.rowEnergy(image, row);
    const want = beam_half_width_px * 16.0 / 15.0 * measure.beamWeight(len, beam_half_width_px);

    say("  velocity: a {d: >6.1} px segment deposits {d:.6} per unit length, expected {d:.6}", .{
        len,
        total,
        want,
    });

    if (@abs(total - want) > want * 0.05) return Fault.DepositNotVelocityWeighted;
    return total;
}

/// A segment's *total* deposit does not depend on its screen length at all.
///
/// The other end of the same physics, and the pairing is the point. One arm reads
/// energy per unit length, which falls as `1 / len`; this reads the total, which
/// does not move. A defect that got the exponent wrong would have to satisfy both,
/// and `h / len` with the floor term removed satisfies only the first.
///
/// `instances` and `density` are the driver's, because they are what the frame
/// actually drew: `measure.segmentEnergy` is one segment's worth, and a frame is
/// that times the segment count times `TraceUniforms.density`. Ten percent,
/// because this is a claim about the profile's two-dimensional integral as well
/// as about the weight, and it absorbs the half-cap each end of the window loses
/// off the drawable.
pub fn velocityTotal(image: measure.Image, len: f32, instances: f32, density: f32) Fault!f32 {
    try requireComplete(image, null);
    if (measure.maxChannel(image, 1) <= trace_drawn) return Fault.TraceNotDrawn;

    const total = measure.totalEnergy(image);
    const want = instances * density * measure.segmentEnergy(len, beam_half_width_px);

    say("  velocity: {d: >4.0} segments at a {d: >6.1} px slope deposit {d: >7.1} in total, expected {d: >7.1}", .{
        instances,
        len,
        total,
        want,
    });

    if (@abs(total - want) > want * 0.10) return Fault.DepositNotVelocityWeighted;
    return total;
}

/// And the totals agree with each other, which needs no model at all.
///
/// The assertion the issue actually asks for. `segmentEnergy`'s own spread is
/// 1.8%, from its two limits, so five percent is that plus half-float. Unweighted
/// the same arms span a factor of 197.
pub fn velocityInvariance(totals: []const f32) Fault!void {
    if (totals.len < 2) return Fault.DepositNotVelocityWeighted;

    var low: f32 = std.math.floatMax(f32);
    var high: f32 = 0;
    for (totals) |t| {
        low = @min(low, t);
        high = @max(high, t);
    }

    const spread = high / low;
    say("  velocity: the {d} totals span {d:.4}, against 197 unweighted", .{ totals.len, spread });

    if (spread > 1.05) return Fault.DepositNotVelocityWeighted;
}

/// The ratio form, which is robust to phase, to the `n - 1` quibble, and to
/// miscounting a partial period at an edge in a way an absolute count is not.
///
/// `counted` is parallel to `period_cycles`, and the three positions read are
/// fixed by `doubling_at` with a comptime assertion that they stand in 1:2:4.
/// That replaces an `undefined` array written only inside a `switch` over a
/// literal frequency list, which was sound exactly while that list stood.
pub fn periodRatio(counted: []const usize) Fault!void {
    if (counted.len != period_cycles.len) return Fault.PeriodRatioWrong;

    const a = counted[doubling_at[0]];
    const b = counted[doubling_at[1]];
    const c = counted[doubling_at[2]];
    if (b != a * 2 or c != b * 2) return Fault.PeriodRatioWrong;
}

/// Every deposit is a scalar, so the accumulation's four channels move together.
///
/// **The assertion that keeps `measure.Image.green` honest**, and the only thing
/// anywhere that does. Since #60 the deposit carries no colour: `trace_fragment`
/// returns `float4(1.0)` and the palette owns the look, so green is the energy
/// only because every other channel is the same number. `resolve_fragment` reads
/// green and so does the analyser; if a later weighting made one channel differ,
/// every green-channel measurement in this project would change meaning at once
/// and nothing else would fail.
///
/// It replaces `checkBeamIsOneColour`, which asserted a *ray* through colour
/// space and was right until the deposit stopped being a colour. The loop is the
/// same loop; what it compares is not.
pub fn depositIsScalar(image: measure.Image, contour: f32) Fault!f32 {
    try requireComplete(image, null);
    const peak_green = measure.maxChannel(image, 1);
    if (peak_green <= trace_drawn) return Fault.TraceNotDrawn;

    var worst: f32 = 0;
    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            const g = image.channel(x, y, 1);
            if (g <= contour) continue;

            // Alpha included. It accumulates and decays exactly like the other
            // three, which is what `mtl.blend_factor_one`'s docstring left open
            // and #60 answered; leaving it out would be leaving the one channel
            // nothing else reads unchecked.
            for (0..4) |channel| worst = @max(worst, @abs(image.channel(x, y, channel) - g));
        }
    }

    say("  deposit: {d} channels agree to {d:.5} at every lit pixel", .{ 4, worst });

    // Half-float precision rather than a rendering tolerance: `RGBA16Float` holds
    // about three decimal digits, and these are sums of identical values through
    // identical blend arithmetic, so anything above that is a real difference.
    if (worst > 1e-3) return Fault.DepositNotScalar;
    return worst;
}

pub const Resolve = struct { lit: usize, worst: i32, background: [4]u8 };

/// The resolve is the curve and the palette, and nothing else.
pub fn resolve(image: measure.Image, picture: Picture, contour: f32) Fault!Resolve {
    try requireComplete(image, picture);

    // The same table the shader is reading, built by the same function that
    // filled the texture. That is what makes this comparison exact rather than
    // close: the model and the GPU share the table and differ only in the
    // arithmetic around it, which is the part being checked.
    var table: [palette.palette_floats]f32 = undefined;
    palette.buildPalette(&table);

    // The background, read off the picture rather than restated from the shader.
    // Any pixel the beam missed carries it; the top-left corner is the safest,
    // since a sine at this amplitude never reaches the corners.
    const background = picture.pixel(0, 0);
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
    if (background[0] != background[1]) return Fault.BackgroundNotNeutral;
    if (background[2] <= background[0]) return Fault.BackgroundNotBlueLeading;
    if (background[0] >= 16) return Fault.BackgroundNotDark;
    if (background[3] != 255) return Fault.BackgroundNotOpaque;

    // **#60's own open question, answered as an assertion rather than as prose.**
    // The issue asked whether the background stays a literal beside the palette
    // or becomes the palette's value at zero energy. It is the latter, and this
    // is what makes that a fact about the running shader rather than a claim
    // about how the table was built: there is no background term in
    // `resolve_fragment` at all, so if these disagree the gradient's first entry
    // is not what reaches an unlit pixel.
    const at_zero = palette.resolved(&table, palette.shipped_palette, trace_decay, 0.0);
    for (0..3) |channel| {
        if (background[channel] != at_zero[channel]) return Fault.BackgroundNotThePaletteAtZero;
    }

    var worst: i32 = 0;
    var lit: usize = 0;

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            const got = picture.pixel(x, y);
            if (image.channel(x, y, 1) > contour) lit += 1;

            // **Every channel predicted from one number**, which is stronger
            // than comparing each against its own energy: it asserts the
            // picture's chroma follows from the intensity alone, which is the
            // palette's whole claim and the thing a per-channel comparison could
            // not see.
            const want = palette.resolved(
                &table,
                palette.shipped_palette,
                trace_decay,
                image.channel(x, y, 1),
            );
            for (0..3) |channel| {
                const off = @as(i32, got[channel]) - @as(i32, want[channel]);
                if (@abs(off) > @abs(worst)) worst = off;
            }
        }
    }

    say("  resolve: {d} lit pixels, worst channel off by {d}", .{ lit, worst });
    if (lit == 0) return Fault.TraceNotDrawn;

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
    //
    // **The slack means more now than it did, and it is still one level.** Since
    // #60 the drawable is `BGRA8Unorm_sRGB`, so this compares the model's own
    // evaluation of the transfer function against the render-output stage's, and
    // those need not round the same way at a boundary: the slope near black is
    // 12.92 x 255, which puts one level at 3.0e-4 of linear energy. Widening this
    // pre-emptively would be widening the one assertion that would have caught
    // #55. Read the printed number first.
    //
    // **#57 spent most of the slack that was here and did not need more.** It was
    // off by zero across 518,400 pixels with 2412 lit; a beam with a falloff
    // lights 4853 and puts most of the new ones in the gradient's toe, where the
    // sRGB curve is 3294.6 bytes per unit linear and a rounding boundary is a
    // whole level. The worst channel is now off by one. If it ever reaches two,
    // the question to ask is whether the toe moved, not whether the tonemap did.
    if (@abs(worst) > 1) return Fault.ResolveNotTheTonemap;

    return .{
        .lit = lit,
        .worst = worst,
        .background = .{ background[0], background[1], background[2], background[3] },
    };
}

/// The moving end of the ten-to-one range: one deposit, read off the picture
/// rather than modelled, so this is the one assertion here that a model wrong in
/// the same way as the shader could not satisfy.
pub fn movingCore(image: measure.Image, picture: Picture) Fault!void {
    try requireComplete(image, picture);
    const tint = palette.tints_srgb[@intFromEnum(palette.shipped_palette)];
    const lead = palette.shipped_palette.dominant();

    const at = measure.peakPixel(image, 1) orelse return Fault.TraceNotDrawn;
    const got = picture.pixel(at.x, at.y);
    say("  hot core: one deposit reads RGB({d}, {d}, {d})", .{ got[0], got[1], got[2] });

    // Half of full range, as a bound rather than a tune: the shipped curve gives
    // 189 here, and stating 128 is what lets the curve be retuned without
    // rewriting the assertion. It names #55's measured 53, which is the number
    // this refuses to ship again.
    if (got[lead] < 128) return Fault.MovingTraceTooDim;

    // And tinted rather than white, which is the other half of the claim: at one
    // deposit the gradient has barely begun running toward white.
    //
    // The gap is taken in `i32` on `resolve`'s precedent, and here that is
    // load-bearing rather than tidy: these are bytes, so the obvious
    // `got[channel] + 24 > got[lead]` is `u8` arithmetic that overflows at 232
    // and above. That is not a corner, it is exactly the near-white pixel this
    // assertion exists to reject, and it fails in whichever direction is worse
    // for the build you are in. Debug panics with `integer overflow` instead of
    // naming the defect; ReleaseFast wraps 278 to 22, compares it against 255,
    // and lets the white trace through.
    // **The first of these two arms cannot fire for the shipped palette, and
    // that was established by planting rather than by reading.** Every gradient's
    // largest tint component is exactly 1.0 and green's other two are below it,
    // so `tint[channel] < 1.0` holds for both non-lead channels and the second
    // arm already refuses everything the first would, `gap` of zero and negative
    // included. Removing the first changes no verdict any test here reaches. It
    // stays because it is the arm that survives a palette whose non-lead tint
    // reaches 1.0, where the second goes quiet, and a defensive arm that is dead
    // for today's constant is worth its line as long as it says so.
    for (0..3) |channel| {
        if (channel == lead) continue;
        const gap = @as(i32, got[lead]) - @as(i32, got[channel]);
        if (gap <= 0) return Fault.MovingTraceNotTinted;
        if (tint[channel] < 1.0 and gap < 24) return Fault.MovingTraceNotTinted;
    }
}

/// The dwelt end: the same window deposited every frame, which is what a stopped
/// transport does.
pub fn dwellCore(image: measure.Image, picture: Picture) Fault!void {
    try requireComplete(image, picture);
    const peak = measure.maxChannel(image, 1);
    const white = palette.whitePoint(trace_decay);
    say("  hot core: thirty deposits peak at {d:.3}, white point {d:.3}", .{ peak, white });
    if (peak < white) return Fault.DwellNeverReachesWhite;

    const at = measure.peakPixel(image, 1) orelse return Fault.TraceNotDrawn;
    const got = picture.pixel(at.x, at.y);
    say("  hot core: the dwelt pixel reads RGB({d}, {d}, {d})", .{ got[0], got[1], got[2] });

    // White, and exactly white rather than nearly: the gradient's last entry is
    // 1.0 in every channel by construction, so anything short of 255 means the
    // curve did not reach the top of it.
    for (0..3) |channel| {
        if (got[channel] != 255) return Fault.CoreNotWhite;
    }
}

/// The phosphor dims by the decay factor once per frame.
///
/// `peaks[i]` is the peak energy after `i + 1` frames, of which one deposited,
/// so `peaks[0]` is the deposit and every entry after it has faded `i` times.
///
/// **A fold rather than a running comparison, and that closed a vacuity hole.**
/// This used to divide by a first peak nothing checked. A blank readback gives
/// `0 / 0`, and `nan > 0.02 * want` is *false*, so a run in which nothing was
/// drawn at all passed as a healthy fade. The guard below is what makes the
/// assertion mean anything, and it is asserted by a test that fails without it.
pub fn decay(peaks: []const f32) Fault!void {
    if (peaks.len == 0) return Fault.TraceNotDrawn;

    const first = peaks[0];

    // Reported rather than asserted, and deliberately. It used to read exactly
    // 1.0000, which settled a question this project could not cite an answer to:
    // whether a line strip's shared vertices deposit twice under Metal's
    // diamond-exit rule. They did not.
    //
    // **#57 replaced the primitive that question was about, and the answer with
    // it.** Quads overlap at every joint by construction, so this is now about
    // 2.61 at one sample per point, and that is the design rather than a
    // suspicion: a pixel the beam sweeps over more than once in a frame receives
    // more than one deposit. It stays a finding rather than an assertion because
    // the value tracks the sample density, which is a property of the session and
    // not of the shader; `TraceUniforms.density` is what keeps it bounded.
    say("  decay: one deposit peaks at {d:.4}", .{first});
    if (!(first > 0)) return Fault.TraceNotDrawn;

    for (peaks[1..], 1..) |peak, quiet| {
        const ratio = peak / first;
        const want = std.math.pow(f32, trace_decay, @floatFromInt(quiet));
        say("  decay: after {d} quiet frames, {d:.4} of the deposit, expected {d:.4}", .{
            quiet,
            ratio,
            want,
        });

        // Two percent, which is half-float precision compounded over five frames
        // rather than a rendering tolerance. A decay of 1.0 would hold the ratio
        // at 1.0 and a decay applied twice would put it at 0.81 per frame; both
        // are tens of times outside this.
        if (@abs(ratio - want) > 0.02 * want) return Fault.DecayWrong;
    }
}

/// One rate's measurement: the deposit's peak, and the peak left after the arm's
/// steps have faded it.
pub const RealTimeArm = struct { deposited: f32, faded: f32 };

/// The same elapsed time fades the phosphor by the same amount however many
/// frames it was delivered in.
///
/// **The whole of #56, and the one check here that could not exist before it.**
/// Every other case in this half measures a single frame, or a run of frames at
/// one rate; this one is a claim about how successive frames differ, which is why
/// #56's body expected to be verified by pinning a display to 60 Hz in System
/// Settings, capturing after a fixed wall-clock interval, and comparing
/// brightness by eye. `Renderer.frame` taking a clock reading rather than reading
/// one is what turns that procedure into an assertion.
///
/// The falsification is not subtle, which is the point of the design: with a
/// per-frame factor the arms would land on `0.9^12 = 0.2824` and `0.9^6 = 0.5314`,
/// a factor of 1.88 apart against a tolerance of two percent.
///
/// Two assertions rather than one, because they fail for different reasons. The
/// arms agreeing with **each other** is frame-rate independence, which is what
/// the issue asked for. Each agreeing with `palette.decayOver` is the model and
/// the shader agreeing about `tau`, which a pair of arms that were both wrong in
/// the same way would pass.
pub fn realTimeDecay(measured: []const RealTimeArm) Fault!void {
    if (measured.len != decay_arms.len) return Fault.DecayNotInRealTime;

    var predicted: [decay_arms.len]f32 = undefined;
    var ratios: [decay_arms.len]f32 = undefined;

    for (decay_arms, measured, &predicted, &ratios) |arm, got, *want_slot, *ratio_slot| {
        // **Composed per step rather than asked of the span directly**, and the
        // difference is not pedantry: `palette.max_elapsed_nanos` is 41.7 ms, so
        // `decayOver(decay_span_nanos)` would clamp and predict 0.7684 against a
        // true 0.5451. That the clamp is invisible here is the point: it bounds
        // one frame's interval, and a fade delivered in frames never reaches it.
        //
        // It also makes the two arms' expectations two independent derivations
        // that have to coincide, which is checked below rather than assumed.
        const want = std.math.pow(f32, palette.decayOver(arm.interval_nanos), @floatFromInt(arm.steps));
        want_slot.* = want;

        // The same hole `decay` had, closed the same way and for the same reason.
        if (!(got.deposited > 0)) return Fault.TraceNotDrawn;
        const ratio = got.faded / got.deposited;
        ratio_slot.* = ratio;

        say("  real time: {d} frames {d} ms apart, {d:.4} left after {d} ms, expected {d:.4}", .{
            arm.steps,
            arm.interval_nanos / std.time.ns_per_ms,
            ratio,
            decay_span_nanos / std.time.ns_per_ms,
            want,
        });

        if (@abs(ratio - want) > 0.02 * want) return Fault.DecayNotInRealTime;
    }

    // The two predictions are `exp(-96 ms / tau)` reached from 8 ms twelve times
    // and from 16 ms six times. They are equal in exact arithmetic, so anything
    // above `f32` noise here is `decayOver` not being an exponential.
    try expectClose(predicted[0], predicted[1], 1e-4, Fault.DecayNotInRealTime);

    const spread = @abs(ratios[0] - ratios[1]) / predicted[0];
    say("  real time: the two rates differ by {d:.2}%", .{spread * 100.0});

    // Tighter than either arm's own tolerance, and it can be: both are the same
    // fade over the same interval, so what separates them is half-float rounding
    // compounded over twelve multiplies against six rather than any difference in
    // what was asked for.
    if (spread > 0.01) return Fault.DecayNotInRealTime;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    // The expectations half of `zig build smoke-trace`, whose only caller is an
    // executable this binary never compiles, so without these its public surface
    // would be checked by the one build step that needs a GPU (#95). `Fault` is
    // absent because it is an error set, and `std.meta.declarations` raises a
    // compile error on anything that is not a struct, enum, union or opaque.
    testing.refAllDecls(@This());
    testing.refAllDecls(Picture);
    testing.refAllDecls(Arm);
    testing.refAllDecls(Silence);
    testing.refAllDecls(Level);
    testing.refAllDecls(Lit);
    testing.refAllDecls(Beam);
    testing.refAllDecls(Resolve);
    testing.refAllDecls(RealTimeArm);
}

// Ten defects were planted against this half at #51 and recorded in a table in
// `docs/plans/done/2026-08-29-verify-the-shader-offscreen-against-the-constants.md`.
// Each was verified once, by hand, against a GPU, and written down in prose;
// nothing re-ran them, so a refactor could make a judge vacuous and nothing would
// notice. Every one of them expressible as a synthetic readback is a test below,
// named for the row it encodes, and each is paired with the good input in the
// same block so that a judge which refused everything would fail too.

/// One image's worth of scratch, plus the window that draws into it.
///
/// Heap rather than stack, on `measure.zig`'s precedent and for its reason: the
/// vertical cases need a real height, because `measure.pixelTolerance` is one
/// backing pixel expressed as a sample value and the planted errors below are
/// stated in sample values. At 36 rows a whole pixel is 0.06 of full scale and
/// every level plant in the table would pass; at 540 it is 0.0041 and they are
/// five to a hundred times outside it. The *width* is free, so it is small.
const Canvas = struct {
    pixels: []f32,
    window: []f32,
    width: usize,
    height: usize,

    fn init(width: usize, height: usize) !Canvas {
        return .{
            .pixels = try testing.allocator.alloc(f32, width * height * 4),
            // One sample per column, which is what puts a sample in every column
            // and makes `litColumns` reach the width.
            .window = try testing.allocator.alloc(f32, width),
            .width = width,
            .height = height,
        };
    }

    fn deinit(self: Canvas) void {
        testing.allocator.free(self.pixels);
        testing.allocator.free(self.window);
    }

    fn image(self: Canvas) measure.Image {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }

    fn flat(self: Canvas, value: f32) measure.Image {
        measure.constant(self.window, value);
        return measure.rasterize(self.pixels, self.width, self.height, self.window);
    }

    fn wave(self: Canvas, cycles: f32, amplitude: f32) measure.Image {
        measure.sine(self.window, cycles, amplitude);
        return measure.rasterize(self.pixels, self.width, self.height, self.window);
    }

    fn dark(self: Canvas) measure.Image {
        @memset(self.pixels, 0);
        return self.image();
    }

    /// Set one pixel's four channels to the same energy, which is what the shader
    /// deposits and what `depositIsScalar` exists to keep true.
    fn deposit(self: Canvas, x: usize, y: usize, energy: f32) void {
        const at = (y * self.width + x) * 4;
        for (0..4) |channel| self.pixels[at + channel] = energy;
    }

    /// `measure.rasterize` writes green alone, which is all the analysis reads.
    /// Anything judging the *picture* needs the other three, because the resolve
    /// reads green and the judge compares four channels against a prediction.
    fn splat(self: Canvas) void {
        var i: usize = 0;
        while (i < self.width * self.height) : (i += 1) {
            const g = self.pixels[i * 4 + 1];
            for (0..4) |channel| self.pixels[i * 4 + channel] = g;
        }
    }
};

/// Paint the picture an accumulation should resolve to, optionally wrong.
///
/// `gain` of 1.0 is the shipping resolve. #55 shipped `1 - decay`, which is the
/// row of the plant table this exists to reproduce; a `p` other than the shipped
/// palette is the other kind of wrong, a picture whose chroma does not follow
/// from its intensity.
fn paint(bytes: []u8, image: measure.Image, p: palette.Palette, gain: f32) void {
    var table: [palette.palette_floats]f32 = undefined;
    palette.buildPalette(&table);

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            const rgb = palette.resolved(&table, p, trace_decay, image.channel(x, y, 1) * gain);
            const at = (y * image.width + x) * 4;
            bytes[at + 0] = rgb[0];
            bytes[at + 1] = rgb[1];
            bytes[at + 2] = rgb[2];
            bytes[at + 3] = 255;
        }
    }
}

fn pictureFor(image: measure.Image, p: palette.Palette, gain: f32) !Picture {
    const bytes = try testing.allocator.alloc(u8, image.width * image.height * 4);
    paint(bytes, image, p, gain);
    return .{ .width = image.width, .height = image.height, .bytes = bytes };
}

fn freePicture(picture: Picture) void {
    testing.allocator.free(@constCast(picture.bytes));
}

// ---------------------------------------------------------------------------

test "silence is flat, centred, and lights every column" {
    const canvas = try Canvas.init(64, 540);
    defer canvas.deinit();

    const got = try silence(canvas.flat(0.0));

    try testing.expectEqual(@as(usize, 64), got.lit);
    // The centroid of a symmetric profile straddling the boundary between two
    // rows is that boundary exactly, which is what #38's `+0.0021` was not.
    try testing.expectApproxEqAbs(measure.centreRow(540), got.centroid, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), got.implied, 1e-4);
}

test "silence refuses a line off the centre, a line that is not flat, and no line at all" {
    const canvas = try Canvas.init(64, 540);
    defer canvas.deinit();

    // **Chosen to sit between the two bounds, which is what makes this a test of
    // the twentieth of a pixel rather than of being off-centre at all.** A whole
    // backing pixel at this height is 0.0041 of full scale and a twentieth of one
    // is 0.00021, so 0.001 is refused by the bound this judge states and accepted
    // by the one `pixelTolerance` gives. Planted at 0.01, widening the bound
    // twentyfold changed nothing and the arm asserted only that the sign of the
    // error was detectable.
    try testing.expectError(Fault.CentreLineWrong, silence(canvas.flat(0.001)));

    // A sine lights every column too, so this is refused for its depth rather
    // than for being absent, which is the distinction the two faults draw.
    try testing.expectError(Fault.TraceNotFlat, silence(canvas.wave(3.0, 0.5)));

    // **One column short, which is what "divide x by `sample_count` rather than
    // `sample_count - 1`" cost at a full window.** #51 planted it and this judge
    // reported "silence lit 959 of 960 columns"; the broad net fires before the
    // three-sample probe that makes the same error 320 columns wide.
    _ = canvas.flat(0.0);
    for (0..540) |y| canvas.pixels[(y * 64 + 63) * 4 + 1] = 0.0;
    try testing.expectError(Fault.TraceNotDrawn, silence(canvas.image()));

    try testing.expectError(Fault.TraceNotDrawn, silence(canvas.dark()));
}

test "every judge that indexes a readback refuses a short one" {
    const canvas = try Canvas.init(16, 8);
    defer canvas.deinit();

    _ = canvas.dark();
    canvas.deposit(8, 4, 2.6133);
    const whole = canvas.image();

    // One pixel short of the geometry it declares, which is the shape a
    // truncated readback would have and the shape nothing but a caller mistake
    // can produce.
    const short: measure.Image = .{
        .width = whole.width,
        .height = whole.height,
        .pixels = whole.pixels[0 .. whole.pixels.len - 4],
    };

    try testing.expectError(Fault.ReadbackTruncated, silence(short));
    try testing.expectError(Fault.ReadbackTruncated, level(short, 0.0));
    try testing.expectError(Fault.ReadbackTruncated, horizontalMapping(short));
    try testing.expectError(Fault.ReadbackTruncated, edgeColumns(short));
    try testing.expectError(Fault.ReadbackTruncated, beamProfile(short, 4, 1.0));
    try testing.expectError(Fault.ReadbackTruncated, period(short, 1));
    try testing.expectError(Fault.ReadbackTruncated, depositIsScalar(short, trace_threshold));

    // The three that read the picture too are refused on either half, which is
    // what `Picture.complete()` was written for and what nothing called until
    // now.
    const painted = try pictureFor(whole, palette.shipped_palette, 1.0);
    defer freePicture(painted);
    const clipped: Picture = .{
        .width = painted.width,
        .height = painted.height,
        .bytes = painted.bytes[0 .. painted.bytes.len - 4],
    };

    try testing.expectError(Fault.ReadbackTruncated, resolve(short, painted, trace_threshold));
    try testing.expectError(Fault.ReadbackTruncated, resolve(whole, clipped, trace_threshold));
    try testing.expectError(Fault.ReadbackTruncated, movingCore(short, painted));
    try testing.expectError(Fault.ReadbackTruncated, movingCore(whole, clipped));
    try testing.expectError(Fault.ReadbackTruncated, dwellCore(short, painted));
    try testing.expectError(Fault.ReadbackTruncated, dwellCore(whole, clipped));

    // A cross-section outside the drawable is the same class of mistake, and
    // the only one of these a complete readback can still carry.
    try testing.expectError(Fault.ReadbackGeometryMismatch, beamProfile(whole, whole.height, 1.0));

    // **Two readbacks that are each complete and disagree with each other.**
    // Length alone does not close this: the judges that read both loop over the
    // image's geometry while indexing the picture, so at 16x8 against 8x8
    // `Picture.complete()` demands 256 bytes and `resolve` indexes to 284. Both
    // halves pass and the read still runs off the end, which is why the
    // geometries have to agree rather than each merely be honest about itself.
    // Sized to exactly what it declares, 256 bytes, so that this is the case the
    // paragraph above describes rather than a wider buffer that would merely
    // read the wrong pixels. Planted, the two behave differently and only this
    // one runs off the end.
    const narrow: Picture = .{
        .width = whole.width / 2,
        .height = whole.height,
        .bytes = painted.bytes[0 .. (whole.width / 2) * whole.height * 4],
    };
    try testing.expect(narrow.complete());
    try testing.expectError(Fault.ReadbackGeometryMismatch, resolve(whole, narrow, trace_threshold));
    try testing.expectError(Fault.ReadbackGeometryMismatch, movingCore(whole, narrow));
    try testing.expectError(Fault.ReadbackGeometryMismatch, dwellCore(whole, narrow));

    // **The negative control, and it is not decoration.** Every arm above
    // asserts a refusal, so a judge that refused everything would pass all of
    // them. A buffer *longer* than its geometry is explicitly fine, which is
    // `measure.Image`'s own contract and what lets one allocation serve a run of
    // smaller cases; if this were refused too, the arms above would be measuring
    // nothing.
    const roomy = try testing.allocator.alloc(f32, whole.pixels.len * 2);
    defer testing.allocator.free(roomy);
    @memset(roomy, 0);
    @memcpy(roomy[0..whole.pixels.len], whole.pixels);
    _ = try depositIsScalar(.{ .width = whole.width, .height = whole.height, .pixels = roomy }, trace_threshold);
}

test "every level plant in the table is refused, and the level itself is not" {
    const canvas = try Canvas.init(32, 540);
    defer canvas.deinit();

    // The negative control first: a judge that refused everything would pass
    // every arm below and assert nothing.
    for ([_]f32{ 0.25, 0.5, 1.0, 1.05, -0.25, -0.5, -1.0 }) |want| {
        const got = try level(canvas.flat(want), want);
        try testing.expect(got.off <= measure.pixelTolerance(540));
    }

    // The three `LevelMisplaced` rows of #51's plant table, as the values that
    // issue measured: a vertex stage that swaps `full_scale` and `rail` reads
    // 0.250 as 0.27366, one that applies `full_scale` twice reads 0.22428, and
    // one that negates y reads -0.24897.
    for ([_]f32{ 0.27366, 0.22428, -0.24897 }) |wrong| {
        try testing.expectError(Fault.LevelMisplaced, level(canvas.flat(wrong), 0.25));
    }

    try testing.expectError(Fault.TraceNotDrawn, level(canvas.dark(), 0.25));
}

test "the rail saturates, and dropping the clamp is what stops it" {
    const rail = measure.railRow(540);

    try saturation(&.{ 1.111, 2.0, 8.0, 1000.0 }, &.{ rail, rail, rail, rail }, 540);

    // "Drop the `clamp`" in the plant table, which reported "rail on row 0,
    // expected 4.9".
    try testing.expectError(
        Fault.RailMisplaced,
        saturation(&.{ 1.111, 2.0, 8.0, 1000.0 }, &.{ 0.0, 0.0, 0.0, 0.0 }, 540),
    );

    // And a rail that keeps climbing above the threshold, which is the claim
    // ADR 0017 makes and the one a single arm could not see.
    try testing.expectError(
        Fault.RailNotSaturated,
        saturation(&.{ 1.111, 2.0, 8.0, 1000.0 }, &.{ rail, rail, rail - 3.0, rail }, 540),
    );
}

test "symmetry sees a negated axis and an uneven clamp as different faults" {
    const centre = measure.centreRow(540);

    try symmetry(.{ centre - 121.5, centre + 121.5 }, 540);

    // "The same, with the level and rail checks skipped" in the plant table,
    // which reported "+0.5 sits -121.5 above centre".
    try testing.expectError(
        Fault.TraceInverted,
        symmetry(.{ centre + 121.5, centre - 121.5 }, 540),
    );

    try testing.expectError(
        Fault.TraceAsymmetric,
        symmetry(.{ centre - 121.5, centre + 110.5 }, 540),
    );
}

test "a three-sample ramp reaches both edges, and the wrong divisor stops short" {
    const canvas = try Canvas.init(96, 540);
    defer canvas.deinit();

    var rising = [_]f32{ -1.0, 0.0, 1.0 };
    const got = try horizontalMapping(
        measure.rasterize(canvas.pixels, 96, 540, &rising),
    );
    try testing.expectEqual(@as(usize, 0), got.first);
    try testing.expectEqual(@as(usize, 95), got.last);

    // "Divide x by `sample_count` rather than `sample_count - 1`", at the probe
    // that makes it 320 columns wide rather than one. Two thirds of 95 is 63.
    const image = canvas.dark();
    for (0..64) |x| {
        canvas.pixels[((512 - x * 8) * 96 + x) * 4 + 1] = 1.0;
    }
    try testing.expectError(Fault.TraceEndsEarly, horizontalMapping(image));

    var falling = [_]f32{ 1.0, 0.0, -1.0 };
    try testing.expectError(
        Fault.TraceInverted,
        horizontalMapping(measure.rasterize(canvas.pixels, 96, 540, &falling)),
    );

    try testing.expectError(Fault.TraceNotDrawn, horizontalMapping(canvas.dark()));
}

test "a railed trace lights every column, and a dropped one is not an edge fault" {
    const canvas = try Canvas.init(64, 540);
    defer canvas.deinit();

    const railed = iface.trace_rail / iface.trace_full_scale;
    const got = try edgeColumns(canvas.flat(railed));
    try testing.expectEqual(@as(usize, 64), got.lit);

    // An interior column dropped: the span still reaches both edges, so this
    // must be `ColumnDropped` and not the edge fault. #38's own finding was the
    // other way round, which is why the two are separate.
    _ = canvas.flat(railed);
    for (0..540) |y| canvas.pixels[(y * 64 + 30) * 4 + 1] = 0.0;
    try testing.expectError(Fault.ColumnDropped, edgeColumns(canvas.image()));

    _ = canvas.flat(railed);
    for (0..540) |y| canvas.pixels[(y * 64 + 0) * 4 + 1] = 0.0;
    try testing.expectError(Fault.EdgeColumnDark, edgeColumns(canvas.image()));

    try testing.expectError(Fault.TraceNotDrawn, edgeColumns(canvas.dark()));
}

test "a window too short to hold a segment yields no infinity and no zero contour" {
    // **The failure this guards is silent rather than loud**, which is why the
    // test asserts on the contour and not only on the pitch. Unguarded, one sample
    // sends `segmentPitch` to `inf`, `beamWeight` turns that into a weight of zero,
    // and `litLevel` returns a contour of zero, under which `measure.litColumns`
    // reports every column lit and every geometric judgement here passes while
    // measuring nothing.
    for ([_]usize{ 0, 1, 2 }) |samples| {
        const pitch = segmentPitch(960, samples);
        try testing.expect(std.math.isFinite(pitch));
        try testing.expect(pitch > 0);

        const contour = litLevel(segmentLength(960, 0.0, samples));
        try testing.expect(std.math.isFinite(contour));
        try testing.expect(contour > 0);

        const sine = sineSegment(960, 540, 2.0, 0.8, samples, 1.0);
        try testing.expect(std.math.isFinite(sine));
        try testing.expect(sine > 0);
    }

    // And the guard is the limit of the real case rather than a sentinel: two
    // samples give one segment spanning the drawable, which is the width.
    try testing.expectEqual(@as(f32, 960.0), segmentPitch(960, 2));
    try testing.expectEqual(segmentPitch(960, 2), segmentPitch(960, 1));
}

test "the beam's cross-section integrates to the biweight, in pixels not clip space" {
    const canvas = try Canvas.init(64, 8);
    defer canvas.deinit();

    // Centred on a pixel boundary, which is where the harness measures it and
    // why it reads 1.5796 rather than 1.6000.
    _ = canvas.dark();
    beamRow(canvas, 4, 31.5, beam_half_width_px);
    const got = try beamProfile(canvas.image(), 4, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 1.6), got.expected, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 31.5), got.centre, 0.01);

    // **Expanded in clip space rather than in pixels.** At 960x540 that makes
    // the beam 1.78 times wider one way than the other, which every other judge
    // here reads as a slightly different row and passes.
    _ = canvas.dark();
    beamRow(canvas, 4, 31.5, beam_half_width_px * 960.0 / 540.0);
    try testing.expectError(Fault.BeamWidthWrong, beamProfile(canvas.image(), 4, 1.0));

    // A profile with the right integral and the wrong shape, which is what a
    // strip whose corners run the wrong way draws.
    _ = canvas.dark();
    for ([_]f32{ 0.1, 0.9, 0.5, 0.1 }, 30..) |value, x| {
        canvas.pixels[(4 * 64 + x) * 4 + 1] = value;
    }
    try testing.expectError(Fault.BeamNotSymmetric, beamProfile(canvas.image(), 4, 1.0));

    try testing.expectError(Fault.TraceNotDrawn, beamProfile(canvas.dark(), 4, 1.0));
}

fn beamRow(canvas: Canvas, row: usize, centre: f32, half: f32) void {
    var x: usize = 0;
    while (x < canvas.width) : (x += 1) {
        const d = @abs(@as(f32, @floatFromInt(x)) - centre);
        if (d >= half) continue;
        const u = d / half;
        const falloff = 1.0 - u * u;
        canvas.pixels[(row * canvas.width + x) * 4 + 1] = falloff * falloff;
    }
}

test "periods are counted under strict equality, which a one-off tolerance would hide" {
    const canvas = try Canvas.init(960, 540);
    defer canvas.deinit();

    // The accept arm is #38's own case: `measure.rasterize` lights every row a
    // steep segment spans, so the centre crossing is exactly the shape that made
    // the original counter read one low.
    const image = canvas.wave(4.0, 0.8);
    try testing.expectEqual(@as(usize, 4), try period(image, 4));

    // A count one low, which is what #38 measured at every frequency and what a
    // ±1 tolerance called "ok" six times over.
    try testing.expectError(Fault.PeriodMiscounted, period(image, 5));
}

test "the doubling arm reads three counts and refuses a ratio that is not two" {
    try periodRatio(&.{ 1, 2, 4, 5, 8, 20 });

    // 8 miscounted as 9 while 2 and 4 stay right, which the absolute arm would
    // also catch and which this one catches without knowing the frequencies.
    try testing.expectError(Fault.PeriodRatioWrong, periodRatio(&.{ 1, 2, 4, 5, 9, 20 }));

    // A list of the wrong length is refused rather than indexed, which is what
    // replaced an `undefined` array written only inside a `switch`.
    try testing.expectError(Fault.PeriodRatioWrong, periodRatio(&.{ 1, 2, 4 }));
}

test "a deposit is a scalar, and one channel out of step is what that forbids" {
    const canvas = try Canvas.init(8, 4);
    defer canvas.deinit();

    _ = canvas.dark();
    canvas.deposit(4, 2, 2.6133);
    try testing.expectApproxEqAbs(@as(f32, 0.0), try depositIsScalar(canvas.image(), trace_threshold), 1e-6);

    // The claim that replaced `checkBeamIsOneColour` at #60: green is the energy
    // only because the other three are the same number. A weighting that moved
    // one would change the meaning of every green-channel measurement in this
    // project at once, and nothing else anywhere would fail.
    canvas.pixels[(2 * 8 + 4) * 4 + 2] = 2.5;
    try testing.expectError(Fault.DepositNotScalar, depositIsScalar(canvas.image(), trace_threshold));

    try testing.expectError(Fault.TraceNotDrawn, depositIsScalar(canvas.dark(), trace_threshold));
}

test "the resolve is the tonemap, and #55's gain is what that refuses" {
    const canvas = try Canvas.init(8, 4);
    defer canvas.deinit();

    _ = canvas.dark();
    canvas.deposit(4, 2, 2.6133);
    const image = canvas.image();

    {
        const picture = try pictureFor(image, palette.shipped_palette, 1.0);
        defer freePicture(picture);

        const got = try resolve(image, picture, trace_threshold);
        try testing.expectEqual(@as(usize, 1), got.lit);
        try testing.expectEqual(@as(i32, 0), got.worst);
        try testing.expectEqualSlices(u8, &palette.background_bytes, got.background[0..3]);
    }

    // **The row this whole half exists for.** #55 shipped a resolve gain of
    // `1 - decay`, which divides a moving trace by ten and renders a sine as a
    // black display. It passed 160 unit tests, both smoke halves, the leak
    // check, `clap-validator` and the validation layer, and was found by eye.
    {
        const picture = try pictureFor(image, palette.shipped_palette, 1.0 - trace_decay);
        defer freePicture(picture);
        try testing.expectError(Fault.ResolveNotTheTonemap, resolve(image, picture, trace_threshold));
    }

    // Chroma that does not follow from intensity, which is the palette's whole
    // claim and the thing a per-channel comparison could not see. Every gradient
    // starts at the same background, so this passes all four background checks
    // and fails on the lit pixel alone.
    {
        const picture = try pictureFor(image, .amber, 1.0);
        defer freePicture(picture);
        try testing.expectError(Fault.ResolveNotTheTonemap, resolve(image, picture, trace_threshold));
    }
}

test "a run in which nothing was drawn is refused rather than reported as clean" {
    const canvas = try Canvas.init(8, 4);
    defer canvas.deinit();

    // The guard `if (lit == 0)` exists for, which no test reached before this
    // one. Every pixel carries the background, every channel matches the
    // prediction exactly, and the picture is still not of anything.
    const image = canvas.dark();
    const picture = try pictureFor(image, palette.shipped_palette, 1.0);
    defer freePicture(picture);

    try testing.expectError(Fault.TraceNotDrawn, resolve(image, picture, trace_threshold));
}

test "the background is the palette at zero, and four ways of not being it" {
    const canvas = try Canvas.init(8, 4);
    defer canvas.deinit();

    _ = canvas.dark();
    canvas.deposit(4, 2, 2.6133);
    const image = canvas.image();

    const cases = [_]struct { bytes: [4]u8, fault: Fault }{
        // "Reorder the background literal's channels" in the plant table, which
        // reported `background RGBA(8, 5, 5, 255)`.
        .{ .bytes = .{ 8, 5, 5, 255 }, .fault = Fault.BackgroundNotNeutral },
        .{ .bytes = .{ 5, 5, 5, 255 }, .fault = Fault.BackgroundNotBlueLeading },
        .{ .bytes = .{ 20, 20, 30, 255 }, .fault = Fault.BackgroundNotDark },
        .{ .bytes = .{ 5, 5, 8, 254 }, .fault = Fault.BackgroundNotOpaque },
        // Dark, neutral, blue-leading and opaque, and still not what the
        // gradient's first entry puts on an unlit pixel. This is #60's own open
        // question asserted rather than argued.
        //
        // Five levels off rather than one, deliberately: at one level the
        // per-pixel loop below would refuse it anyway, within its own slack, and
        // removing this check would trade one fault for another instead of
        // letting the picture through. Planted, that is the difference between
        // an arm that discriminates and one that does not.
        .{ .bytes = .{ 10, 10, 14, 255 }, .fault = Fault.BackgroundNotThePaletteAtZero },
    };

    for (cases) |case| {
        const picture = try pictureFor(image, palette.shipped_palette, 1.0);
        defer freePicture(picture);

        const bytes = @constCast(picture.bytes);
        @memcpy(bytes[0..4], &case.bytes);
        try testing.expectError(case.fault, resolve(image, picture, trace_threshold));
    }
}

test "one deposit is bright and tinted, and #55's dim trace is neither" {
    const canvas = try Canvas.init(8, 4);
    defer canvas.deinit();

    _ = canvas.dark();
    canvas.deposit(4, 2, 2.6133);
    const image = canvas.image();

    {
        const picture = try pictureFor(image, palette.shipped_palette, 1.0);
        defer freePicture(picture);
        try movingCore(image, picture);
    }

    // Green 53 of 255 is what #55 rendered, which reads as a black display. The
    // bound is 128 rather than the shipped curve's 189, so retuning the curve
    // does not mean rewriting the assertion.
    {
        const picture = try pictureFor(image, palette.shipped_palette, 1.0 - trace_decay);
        defer freePicture(picture);
        try testing.expectError(Fault.MovingTraceTooDim, movingCore(image, picture));
    }

    // A white pixel at one deposit, which is the other way #55 measured of
    // getting the range wrong, and the case the `i32` gap arithmetic exists for:
    // in `u8` this comparison overflows at 232 and above, which is exactly here.
    {
        const picture = try pictureFor(image, palette.shipped_palette, 100.0);
        defer freePicture(picture);
        try testing.expectError(Fault.MovingTraceNotTinted, movingCore(image, picture));
    }

    {
        const empty = canvas.dark();
        const picture = try pictureFor(empty, palette.shipped_palette, 1.0);
        defer freePicture(picture);
        try testing.expectError(Fault.TraceNotDrawn, movingCore(empty, picture));
    }
}

test "a dwelt trace reaches the white point and is exactly white there" {
    const canvas = try Canvas.init(8, 4);
    defer canvas.deinit();

    _ = canvas.dark();
    canvas.deposit(4, 2, 24.188);
    const image = canvas.image();

    {
        const picture = try pictureFor(image, palette.shipped_palette, 1.0);
        defer freePicture(picture);
        try dwellCore(image, picture);
    }

    // Short of the white point, which is what a unit resolve gain on a moving
    // trace looks like from this end.
    {
        _ = canvas.dark();
        canvas.deposit(4, 2, 4.0);
        const dim = canvas.image();
        const picture = try pictureFor(dim, palette.shipped_palette, 1.0);
        defer freePicture(picture);
        try testing.expectError(Fault.DwellNeverReachesWhite, dwellCore(dim, picture));
    }

    // Past the white point in energy and short of it in the picture, which is
    // the resolve failing rather than the accumulation. Exactly 255 rather than
    // nearly, because the gradient's last entry is 1.0 by construction.
    {
        _ = canvas.dark();
        canvas.deposit(4, 2, 24.188);
        const hot = canvas.image();
        const picture = try pictureFor(hot, palette.shipped_palette, 2.6133 / 24.188);
        defer freePicture(picture);
        try testing.expectError(Fault.CoreNotWhite, dwellCore(hot, picture));
    }
}

test "the phosphor fades by the decay factor, and both table rows say it did not" {
    const first: f32 = 2.6133;
    var good: [5]f32 = undefined;
    for (&good, 0..) |*slot, quiet| {
        slot.* = first * std.math.pow(f32, trace_decay, @floatFromInt(quiet));
    }
    try decay(&good);

    // "`decay_per_frame` of 1.0" in the plant table, which reported "1.0000 of
    // the deposit, expected 0.9000".
    try testing.expectError(Fault.DecayWrong, decay(&.{ first, first, first, first, first }));

    // "Bind `target` rather than `source` to the decay pass", which reported
    // "0.0000 of the deposit, expected 0.9000". The defect itself is caught by
    // the compiler; this is its symptom, which the judge has to refuse too.
    try testing.expectError(Fault.DecayWrong, decay(&.{ first, 0.0, 0.0, 0.0, 0.0 }));
}

test "a decay measured off a blank readback is refused, where nan used to pass" {
    // **The vacuity hole this fold was written to close.** Dividing by a first
    // peak of zero gives `nan`, and `nan > 0.02 * want` is *false*, so every arm
    // passed and a run that drew nothing at all reported a healthy fade.
    try testing.expectError(Fault.TraceNotDrawn, decay(&.{ 0.0, 0.0, 0.0, 0.0, 0.0 }));
    try testing.expectError(Fault.TraceNotDrawn, decay(&.{}));

    const blank: [decay_arms.len]RealTimeArm = @splat(.{ .deposited = 0.0, .faded = 0.0 });
    try testing.expectError(Fault.TraceNotDrawn, realTimeDecay(&blank));
}

test "the same elapsed time fades the same however many frames delivered it" {
    var good: [decay_arms.len]RealTimeArm = undefined;
    for (decay_arms, &good) |arm, *slot| {
        const kept = std.math.pow(f32, palette.decayOver(arm.interval_nanos), @floatFromInt(arm.steps));
        slot.* = .{ .deposited = 2.6133, .faded = 2.6133 * kept };
    }
    try realTimeDecay(&good);

    // **The falsification, and it is not subtle.** With a per-frame factor the
    // arms land on `0.9^12 = 0.2824` and `0.9^6 = 0.5314`, a factor of 1.88
    // apart against a tolerance of two percent.
    var per_frame: [decay_arms.len]RealTimeArm = undefined;
    for (decay_arms, &per_frame) |arm, *slot| {
        const kept = std.math.pow(f32, 0.9, @floatFromInt(arm.steps));
        slot.* = .{ .deposited = 2.6133, .faded = 2.6133 * kept };
    }
    try testing.expectError(Fault.DecayNotInRealTime, realTimeDecay(&per_frame));

    // **Both arms wrong in the same way, which is the case the second assertion
    // exists for and the one the spread between them cannot see.** Halving each
    // arm's interval fades both as if `tau` were twice what the model says:
    // `decayOver(4 ms)^12` and `decayOver(8 ms)^6` are the same number, so the
    // arms agree with each other exactly and neither agrees with
    // `palette.decayOver`. Planted, removing the per-arm comparison leaves the
    // spread check passing this, which is what makes the two assertions two.
    var wrong_tau: [decay_arms.len]RealTimeArm = undefined;
    for (decay_arms, &wrong_tau) |arm, *slot| {
        const kept = std.math.pow(
            f32,
            palette.decayOver(arm.interval_nanos / 2),
            @floatFromInt(arm.steps),
        );
        slot.* = .{ .deposited = 2.6133, .faded = 2.6133 * kept };
    }
    try testing.expectError(Fault.DecayNotInRealTime, realTimeDecay(&wrong_tau));

    try testing.expectError(Fault.DecayNotInRealTime, realTimeDecay(&.{}));
}

test "both arms span the same interval in whole steps" {
    // The property `decay_span_nanos`' docstring argues for, which is a
    // `@compileError` above and therefore cannot fail here; what this asserts is
    // that the table it produces is the one the prose names, 12 steps of 8 ms
    // and 6 of 16 ms.
    try testing.expectEqual(@as(usize, 2), decay_arms.len);
    try testing.expectEqual(@as(u64, 12), decay_arms[0].steps);
    try testing.expectEqual(@as(u64, 6), decay_arms[1].steps);

    for (decay_arms) |arm| {
        try testing.expectEqual(decay_span_nanos, arm.steps * arm.interval_nanos);
    }
}

test "a relative tolerance reads the same whichever way its arguments are passed" {
    try expectClose(1.0, 1.0001, 1e-3, Fault.DecayWrong);
    try testing.expectError(Fault.DecayWrong, expectClose(1.0, 1.5, 1e-3, Fault.DecayWrong));

    // **The one arm that separates the two spellings.** Scaling by `@abs(b)`
    // alone refuses this pair and scaling by the larger accepts it, so this is
    // what fails if the old form is ever restored. Every other arm here agrees
    // under both, including zero, which is why the issue's own diagnosis needed
    // correcting rather than encoding.
    try expectClose(2.0, 1.0, 0.75, Fault.DecayWrong);

    // Symmetry over a sweep rather than at a point, because which pairs disagree
    // is exactly what a spot check would miss.
    const values = [_]f32{ 0.0, 1e-9, 0.5, 1.0, 2.0, 100.0 };
    for (values) |a| {
        for (values) |b| {
            const forward = if (expectClose(a, b, 0.75, Fault.DecayWrong)) true else |_| false;
            const backward = if (expectClose(b, a, 0.75, Fault.DecayWrong)) true else |_| false;
            try testing.expectEqual(forward, backward);
        }
    }

    // Zero is pinned rather than claimed: nothing is relatively close to zero but
    // zero, and both spellings have always agreed about that.
    try expectClose(0.0, 0.0, 1e-3, Fault.DecayWrong);
    try testing.expectError(Fault.DecayWrong, expectClose(1e-9, 0.0, 1e-3, Fault.DecayWrong));
    try testing.expectError(Fault.DecayWrong, expectClose(0.0, 1e-9, 1e-3, Fault.DecayWrong));
}

test "a picture geometry too large to size is incomplete rather than overflowing" {
    // The same hazard `measure.Image.complete` documents, on the byte side.
    // Without the overflow-safe form this test panics with `integer overflow` in
    // Debug, and `--release=fast` wraps and calls an empty buffer complete.
    const huge: Picture = .{ .width = 1 << 32, .height = 1 << 32, .bytes = &.{} };
    try testing.expect(!huge.complete());

    const wide: Picture = .{ .width = 1 << 61, .height = 1, .bytes = &.{} };
    try testing.expect(!wide.complete());

    // And a judge refuses it rather than indexing, which is what makes the guard
    // reachable from the judgement side rather than only from this assertion.
    const canvas = try Canvas.init(16, 8);
    defer canvas.deinit();
    try testing.expectError(Fault.ReadbackTruncated, resolve(canvas.dark(), huge, trace_threshold));

    // The negative control: an ordinary picture is complete.
    var bytes: [16 * 8 * 4]u8 = @splat(0);
    const ordinary: Picture = .{ .width = 16, .height = 8, .bytes = &bytes };
    try testing.expect(ordinary.complete());
}
