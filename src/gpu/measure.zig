//! Reading a rendered trace back as numbers.
//!
//! Everything here is arithmetic over an array of floats. No Metal, no GPU, no
//! allocator, no I/O, and nothing above this file's own imports, which is what
//! lets `zig build test` cover all of it on a runner with no graphics support at
//! all (ADR 0009). `src/smoke.zig` supplies the pixels; this decides what they
//! mean, and `src/gpu/metal/renderer.zig` is not in the picture either way.
//!
//! **The split is the point rather than tidiness.** #38 measured the vertical
//! mapping with a throwaway probe and its first period counter was wrong: it
//! counted upward zero crossings against the centre row using the topmost lit
//! pixel per column, and a steep segment crossing the centre lights every row it
//! spans, so the topmost pixel read as "above" whatever the sample was and every
//! tone came back exactly one period low. A ±1 tolerance called all six "ok".
//! The defect was in the analysis and not in the shader, and an analysis that
//! runs only against a GPU is one nothing tests. So it lives here, and the tests
//! at the foot of this file rasterize their own images and know the answers.
//!
//! Two conventions, both stated because neither is forced by anything.
//! Pixels are RGBA, four floats each, row-major from the top-left, which is what
//! the seam's `Readback` publishes. Rows count down from zero at the top, which
//! is Metal's window space and the opposite of the trace's own sign.

const std = @import("std");

const iface = @import("iface.zig");

/// A readback, with the shape the arithmetic below needs to index it.
///
/// Borrows rather than owns: the caller allocated `pixels` and outlives this.
pub const Image = struct {
    width: usize,
    height: usize,
    /// `width * height * 4` floats. Longer is accepted and the tail ignored,
    /// which is what lets one buffer be reused across a run of smaller cases.
    pixels: []const f32,

    /// The green channel, which is where a trace is read.
    ///
    /// **#60 was expected to end this convention and did not**, which is worth
    /// stating because the reason it survived is now a constraint rather than an
    /// accident. This reads the *accumulation*, and since #60 the deposit is a
    /// scalar carried in all four channels, so green is the energy and any other
    /// channel would do; `checkDepositIsScalar` in `src/smoke.zig` is what keeps
    /// that true. On the *picture* side the same name still works for a different
    /// reason: every gradient in `src/gpu/palette.zig` has its largest tint
    /// component at exactly 1.0, so that channel stays an affine readout of the
    /// tonemapped value.
    ///
    /// Green rather than luminance was never an aesthetic choice and still is
    /// not: the background has more blue than green, so a luminance threshold
    /// would find the background lit everywhere.
    pub fn green(self: Image, x: usize, y: usize) f32 {
        return self.pixels[(y * self.width + x) * 4 + 1];
    }

    pub fn channel(self: Image, x: usize, y: usize, c: usize) f32 {
        return self.pixels[(y * self.width + x) * 4 + c];
    }

    /// Whether this image's declared geometry fits the buffer it was handed.
    ///
    /// Checked rather than assumed because a short readback truncates rather
    /// than refusing, on `upload`'s precedent, so a caller that sized its buffer
    /// wrongly gets a partly-filled image rather than an error. Without this the
    /// symptom is an index out of bounds deep inside a loop.
    pub fn complete(self: Image) bool {
        return self.pixels.len >= self.width * self.height * 4;
    }
};

/// The topmost lit row in a column, or nothing when the column is dark.
///
/// "Topmost" is the smallest row index, which is the *highest* point of the
/// trace in that column. Under persistence it is the highest point over the
/// whole fade rather than this frame's sample, which is #55 changing what the
/// measurement means; the harness drives a single deposit frame from a cleared
/// accumulation precisely so that distinction does not arise.
pub fn topRow(image: Image, x: usize, threshold: f32) ?usize {
    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        if (image.green(x, y) > threshold) return y;
    }
    return null;
}

/// The bottommost lit row in a column, or nothing when the column is dark.
pub fn bottomRow(image: Image, x: usize, threshold: f32) ?usize {
    var y: usize = image.height;
    while (y > 0) {
        y -= 1;
        if (image.green(x, y) > threshold) return y;
    }
    return null;
}

/// Columns with at least one lit pixel.
pub fn litColumns(image: Image, threshold: f32) usize {
    var lit: usize = 0;
    var x: usize = 0;
    while (x < image.width) : (x += 1) {
        if (topRow(image, x, threshold) != null) lit += 1;
    }
    return lit;
}

/// The highest and lowest rows the trace reaches anywhere, or nothing when the
/// image is dark.
pub const Extremes = struct {
    /// Smallest row index reached, so the trace's positive peak.
    top: usize,
    /// Largest row index reached, so its negative trough.
    bottom: usize,
};

pub fn extremes(image: Image, threshold: f32) ?Extremes {
    var found: ?Extremes = null;

    var x: usize = 0;
    while (x < image.width) : (x += 1) {
        const top = topRow(image, x, threshold) orelse continue;
        const bottom = bottomRow(image, x, threshold).?;

        if (found) |*seen| {
            seen.top = @min(seen.top, top);
            seen.bottom = @max(seen.bottom, bottom);
        } else {
            found = .{ .top = top, .bottom = bottom };
        }
    }

    return found;
}

/// Where the beam's centre sits in a column, as a fractional row.
///
/// **The estimator every vertical assertion is stated in, and #57 is why it had
/// to exist.** A one-pixel line has no interior, so `topRow` *was* the trace's
/// position. A beam with width and a falloff does have one, and `topRow` then
/// reads the threshold contour's upper edge, which sits above the centreline by
/// the lit half-width — systematically, and with the same sign at every level.
/// `pixelTolerance` is one backing pixel by construction and cannot absorb that,
/// and widening it would be the exact thing this file's header refuses: a
/// tolerance wide enough to hide a systematic error is a tolerance that hides one.
///
/// The energy-weighted mean is exact rather than approximate, because the profile
/// is symmetric about the centreline and the accumulation is linear. Weighted by
/// energy directly, not by a thresholded mask.
///
/// **Summed over the whole column rather than over the lit rows, which is both
/// cheaper to justify and more accurate.** The biweight has compact support, so
/// an unlit pixel holds exactly 0.0 and contributes exactly nothing; including
/// them costs one multiply-add each and removes a bias. Thresholding first
/// roughly doubles the residual error at an adversarial sub-pixel offset, from
/// 0.054 rows to 0.112, and worse, makes it depend on where between two pixel
/// centres the beam happens to fall — a bias that varies with the signal, in an
/// instrument whose whole purpose is to have none.
///
/// Returns nothing when the column carries no energy at all, which is what
/// distinguishes a dark column from one centred on row zero.
pub fn centroidRow(image: Image, x: usize) ?f32 {
    var weight: f32 = 0;
    var moment: f32 = 0;

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        const energy = image.green(x, y);
        if (energy <= 0) continue;

        weight += energy;
        moment += energy * @as(f32, @floatFromInt(y));
    }

    if (weight <= 0) return null;
    return moment / weight;
}

/// The highest and lowest centres the trace reaches anywhere.
///
/// `extremes`' counterpart, and what replaces it wherever the question is where
/// the trace *is* rather than which pixels are lit. Both bounds are taken over
/// column centroids, so a beam of any width contributes its centre rather than
/// its edge and the two bounds are biased identically — which is what makes
/// `checkSymmetry` in `src/smoke.zig` an assertion about symmetry again rather
/// than about the beam's width.
pub const Centres = struct {
    /// Smallest centroid reached, so the trace's positive peak.
    top: f32,
    /// Largest centroid reached, so its negative trough.
    bottom: f32,
};

pub fn centres(image: Image) ?Centres {
    var found: ?Centres = null;

    var x: usize = 0;
    while (x < image.width) : (x += 1) {
        const centre = centroidRow(image, x) orelse continue;

        if (found) |*seen| {
            seen.top = @min(seen.top, centre);
            seen.bottom = @max(seen.bottom, centre);
        } else {
            found = .{ .top = centre, .bottom = centre };
        }
    }

    return found;
}

/// The leftmost and rightmost lit columns, or nothing when the image is dark.
///
/// The horizontal mapping's readout. `2i / (n - 1)` puts the last vertex exactly
/// on the right edge and `2i / n` puts it a column short, which is a difference
/// of one column at a full window and of a third of the width at three samples.
/// So this is checked with a short window, where the two divisors are hundreds of
/// columns apart and no tolerance has to carry the argument.
pub const Span = struct { first: usize, last: usize };

pub fn litSpan(image: Image, threshold: f32) ?Span {
    var found: ?Span = null;

    var x: usize = 0;
    while (x < image.width) : (x += 1) {
        if (topRow(image, x, threshold) == null) continue;
        if (found) |*seen| seen.last = x else found = .{ .first = x, .last = x };
    }

    return found;
}

/// The largest value any pixel holds in one channel.
///
/// Unclipped, because the accumulation is floating point and a beam crossing its
/// own path deposits twice. That headroom is the thing #60 wants and it is also
/// the only way to measure decay: the ratio of this across a run of frames is
/// what the phosphor kept over the elapsed time they spanned, and taking it as a
/// ratio is what makes the measurement independent of how many segments happened
/// to cover the brightest pixel.
///
/// **Per elapsed time rather than per frame since #56**, which is why
/// `checkDecayIsInRealTime` can read the same ratio out of two runs at different
/// frame rates and compare them. The instrument did not change; what a frame
/// count means did.
pub fn maxChannel(image: Image, c: usize) f32 {
    var peak: f32 = 0;

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            peak = @max(peak, image.channel(x, y, c));
        }
    }

    return peak;
}

/// The sample value a row implies, inverting the shader's mapping.
///
/// The row's *centre* rather than its edge, since a pixel is a square and the
/// mapping is about points: `[[position]]` in a fragment is window space with
/// pixel centres at half-integers, and a row therefore stands for `row + 0.5`.
///
/// **`scripts/measure-trace` used to omit that term and no longer does**, which
/// #57 forced rather than tidied. The two were half a pixel apart, and that was
/// defensible while every assertion here was stated in a one-pixel band; the
/// centroid took this side's tolerance to a twentieth of a pixel, at which point
/// the offset was ten times the tolerance and the two instruments disagreed about
/// captures they had both measured correctly.
pub fn impliedSample(row: usize, height: usize) f32 {
    return impliedSampleAt(@floatFromInt(row), height);
}

/// The same inversion, from a fractional row.
///
/// What `centroidRow` feeds, and the reason it is a separate entry point rather
/// than a cast at the call site is that the `+ 0.5` above has to apply to both or
/// the two readouts sit half a pixel apart. `impliedSample` delegates here so
/// there is one copy of the arithmetic rather than two that agree today.
///
/// **This is where silence stops reading `+0.0021`.** At an even height the
/// centreline falls on the boundary between two rows: at 540 it is window-space
/// `y = 270.0`, equidistant from the centres of rows 269 and 270, so a symmetric
/// profile weights them equally and the centroid is exactly `269.5`. That plus
/// the half is 270.0, which is exactly half the height, so this returns exactly
/// zero. #38 measured the `+0.0021` an edge estimator gives here and declined a
/// corrective bias partly on the grounds that this step would re-answer the
/// question; it did, and the answer is that no bias was ever needed — the
/// geometry was right and the instrument was reading its edge.
pub fn impliedSampleAt(row: f32, height: usize) f32 {
    const centred = (row + 0.5) / @as(f32, @floatFromInt(height));
    return (1.0 - 2.0 * centred) / iface.trace_full_scale;
}

/// The row a sample should land on, as a continuous position.
///
/// The whole of the shader's vertical mapping restated on this side, from the
/// seam's own constants, so an assertion compares two independent derivations
/// rather than the shader against itself. Fractional deliberately: a rasterizer
/// picks a row from this and the rule it uses is Metal's rather than ours, which
/// is exactly why the assertions are stated as a distance in samples and not as
/// an expected integer.
pub fn expectedRow(sample: f32, height: usize) f32 {
    const y = std.math.clamp(
        sample * iface.trace_full_scale,
        -iface.trace_rail,
        iface.trace_rail,
    );
    return (1.0 - y) / 2.0 * @as(f32, @floatFromInt(height)) - 0.5;
}

/// One backing pixel of travel, expressed as a sample value.
///
/// The tolerance every vertical assertion is stated in, and the reason they can
/// be stated with a tolerance at all: this is the display's own quantum, so it
/// cannot absorb any error larger than the smallest change the instrument is
/// able to show. The errors it has to catch are one to three orders of magnitude
/// wider — `full_scale` applied twice moves a peak by a tenth of the drawable —
/// which is the test that "a tolerance wide enough to absorb a systematic error
/// is a tolerance that hides one" was written to demand.
///
/// It is also this display's visibility floor from the other direction: a sine
/// smaller than this moves the trace less than a pixel and reads as flat.
pub fn pixelTolerance(height: usize) f32 {
    return 2.0 / (iface.trace_full_scale * @as(f32, @floatFromInt(height)));
}

/// Where the rail puts a clamped sample, as a continuous row position.
pub fn railRow(height: usize) f32 {
    return (1.0 - iface.trace_rail) / 2.0 * @as(f32, @floatFromInt(height)) - 0.5;
}

/// The row a sample of zero lands on, as a continuous position.
pub fn centreRow(height: usize) f32 {
    return @as(f32, @floatFromInt(height)) / 2.0 - 0.5;
}

/// Periods of a periodic trace, counted as excursions above a half-amplitude
/// band.
///
/// **Not zero crossings, and the difference is the one finding #38 paid for.**
/// A crossing counter reads the topmost lit pixel in each column and asks which
/// side of the centre it is on; a steep segment crossing the centre lights every
/// row it spans, so its topmost pixel sits well above the centre and the
/// crossing is counted early. Every tone came back exactly one period low, and a
/// ±1 tolerance reported all six as correct.
///
/// A band at half the measured peak amplitude is immune to that, because the
/// only columns it admits are ones where the trace genuinely reaches half its
/// height. The steepest segment this display can draw spans a fraction of that:
/// at twenty periods across a 960-sample window, consecutive samples differ by
/// about an eighth of the amplitude, so a crossing column reaches nowhere near
/// the band. The test at the foot of this file rasterizes exactly that case.
///
/// Two passes and no allocation: the first finds the peak, the second counts
/// runs. Returns zero for a dark image.
pub fn periods(image: Image, threshold: f32) usize {
    const peak = (extremes(image, threshold) orelse return 0).top;

    const centre = centreRow(image.height);
    const band = (centre + @as(f32, @floatFromInt(peak))) / 2.0;

    var count: usize = 0;
    var inside = false;

    var x: usize = 0;
    while (x < image.width) : (x += 1) {
        const above = if (topRow(image, x, threshold)) |row|
            @as(f32, @floatFromInt(row)) <= band
        else
            false;

        if (above and !inside) count += 1;
        inside = above;
    }

    return count;
}

/// Columns whose topmost lit row is the image's highest, which is the flat top
/// of a railed signal.
///
/// **Reported rather than asserted on, and the reason is a measurement.** The
/// width of a flat top is not a readout of anything: an unclipped sine at 1.089
/// has a *narrower* top than one at 1.000, because a larger sine moves faster
/// through its peak in screen terms and that effect is bigger than the eight
/// pixels of actual clamping. Only the peak's position saturates. This exists so
/// the harness can print the number, not so anything can conclude from it.
pub fn plateauWidth(image: Image, threshold: f32) usize {
    const peak = (extremes(image, threshold) orelse return 0).top;

    var width: usize = 0;
    var x: usize = 0;
    while (x < image.width) : (x += 1) {
        if (topRow(image, x, threshold)) |row| {
            if (row == peak) width += 1;
        }
    }
    return width;
}

// ---------------------------------------------------------------------------
// Where the picture is brightest
// ---------------------------------------------------------------------------

pub const Point = struct { x: usize, y: usize };

/// Where the brightest pixel of one channel is, or nothing when the image is
/// dark.
///
/// `maxChannel` answers how bright and this answers where, which is what a check
/// on the resolved picture needs: the picture is bytes and the energy is floats,
/// so the only way to read the two at one point is to find the point first.
///
/// The comparison is strictly against zero rather than seeded from the first
/// pixel, which is what makes the null real: this reads the *accumulation*,
/// where an undeposited pixel holds exactly zero, so a cleared surface has no
/// brightest pixel rather than an arbitrary one. Seeding from the first pixel
/// returns `(0, 0)` for a blank image, and `checkHotCore`'s `TraceNotDrawn` then
/// never fires and the case reports itself as a dim trace instead.
pub fn peakPixel(image: Image, c: usize) ?Point {
    var found: ?Point = null;
    var peak: f32 = 0;

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            const value = image.channel(x, y, c);
            if (value > peak) {
                peak = value;
                found = .{ .x = x, .y = y };
            }
        }
    }

    return found;
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

/// A window holding one value throughout, so every column lands on one row.
pub fn constant(out: []f32, value: f32) void {
    @memset(out, value);
}

/// A window ramping linearly from `from` to `to`.
///
/// The probe for the horizontal mapping when it is paired with a short window:
/// `2i / (n - 1)` and `2i / n` differ by a column at the right edge and by a
/// third of the width at three samples, which is what makes the divisor
/// checkable without a tolerance.
pub fn ramp(out: []f32, from: f32, to: f32) void {
    if (out.len == 0) return;
    if (out.len == 1) {
        out[0] = from;
        return;
    }

    const span = @as(f32, @floatFromInt(out.len - 1));
    for (out, 0..) |*slot, i| {
        const t = @as(f32, @floatFromInt(i)) / span;
        slot.* = from + (to - from) * t;
    }
}

/// A window holding exactly `cycles` periods of a sine, starting at zero.
///
/// Whole cycles across `n - 1` intervals rather than across `n` samples, because
/// that is where the shader puts the last vertex: `2i / (n - 1)` lands sample
/// `n - 1` on the right edge, so a window built over `n` would end a fraction of
/// a period short and the last peak would sit off the edge on half the counts.
pub fn sine(out: []f32, cycles: f32, amplitude: f32) void {
    if (out.len < 2) {
        @memset(out, 0);
        return;
    }

    const span = @as(f32, @floatFromInt(out.len - 1));
    for (out, 0..) |*slot, i| {
        const phase = 2.0 * std.math.pi * cycles * @as(f32, @floatFromInt(i)) / span;
        slot.* = amplitude * @sin(phase);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Rasterize a window the way the shader does, so a test knows its own answers.
///
/// **Deliberately reproduces the behaviour that broke #38's first counter**: a
/// segment lights every row it spans, so a steep crossing column is lit from one
/// sample's row to the next's. An analyser tested against one-pixel-per-column
/// images would pass while being wrong about exactly the case that matters.
///
/// Not the shader and not a claim to be: it is a model of the beam, used to test
/// the analysis. What the shader actually draws is what `zig build smoke-trace`
/// measures.
///
/// **#57 gave it a width and a falloff, and that was not optional.** Left as a
/// one-pixel line, every test below would have gone on validating `centroidRow`
/// against the primitive it was written to replace: an estimator that reads a
/// beam's centre would look correct on images that have no interior to read.
///
/// The profile is the biweight the shader deposits, applied to the distance from
/// a pixel's centre to the column's segment rather than to a point, which is the
/// one-dimensional form of the shader's distance-to-segment. That keeps the
/// property the centroid depends on — symmetry about the centreline — without
/// reproducing the oriented quad, which this file has no business knowing about.
fn rasterize(pixels: []f32, width: usize, height: usize, window: []const f32) Image {
    @memset(pixels, 0);
    const image: Image = .{ .width = width, .height = height, .pixels = pixels };

    var previous: ?f32 = null;
    for (window, 0..) |sample, i| {
        const x_ndc = 2.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(window.len - 1)) - 1.0;
        const column = @min(
            width - 1,
            @as(usize, @intFromFloat(@round((x_ndc + 1.0) / 2.0 * @as(f32, @floatFromInt(width - 1))))),
        );

        const row_f = expectedRow(sample, height);
        const from = if (previous) |p| @min(p, row_f) else row_f;
        const to = if (previous) |p| @max(p, row_f) else row_f;

        // Every row the segment reaches, plus the skirt either side. Clamped to
        // the image, which is what stops the three-sample ramp — whose endpoints
        // sit on the rail — indexing off the top and bottom.
        const first: usize = @intFromFloat(@max(0.0, @floor(from - model_half_width)));
        const last: usize = @min(
            height - 1,
            @as(usize, @intFromFloat(@max(0.0, @ceil(to + model_half_width)))),
        );

        var y = first;
        while (y <= last) : (y += 1) {
            const centre = @as(f32, @floatFromInt(y));
            const d = @max(0.0, @max(from - centre, centre - to));
            const u = @min(d / model_half_width, 1.0);
            const falloff = 1.0 - u * u;

            const slot = &pixels[(y * width + column) * 4 + 1];
            slot.* = @max(slot.*, falloff * falloff);
        }
        previous = row_f;
    }

    return image;
}

/// The beam's half-width in this model, in pixels.
///
/// `iface.beam_width_points / 2` at a scale of one, which is the geometry
/// `Renderer.initOffscreen` runs and therefore the one every number in
/// `src/smoke.zig` is stated at. Held here rather than imported so this file's
/// tests describe the analysis at a geometry they choose, the way they already
/// choose 960x540.
const model_half_width: f32 = iface.beam_width_points / 2.0;

/// Scratch for one rasterized image.
///
/// Heap rather than stack, because the geometry the interesting cases need is
/// the geometry the harness uses: 960x540 in RGBA floats is 8.3 MB, which is
/// past a thread's default stack and would show up as a crash in the test runner
/// rather than as anything legible.
fn scratch(width: usize, height: usize) ![]f32 {
    return testing.allocator.alloc(f32, width * height * 4);
}

test "a row and the sample it implies invert each other" {
    const height: usize = 540;

    for ([_]f32{ 0.0, 0.25, -0.25, 0.5, -0.5, 1.0, -1.0 }) |sample| {
        const row = expectedRow(sample, height);
        const back = impliedSample(@intFromFloat(@round(row)), height);
        try testing.expect(@abs(back - sample) <= pixelTolerance(height));
    }
}

test "every level at or above the rail lands on one row" {
    const height: usize = 540;

    // 1.111 is `1 / trace_full_scale`, which is where the trace would reach the
    // drawable's edge if nothing clamped and is unreachable because this does.
    // Everything from there up must be pixel-identical: that saturation is the
    // whole of what ADR 0017 means by refusing to say how far over a signal is.
    for ([_]f32{ 1.111, 2.0, 8.0, 1000.0 }) |over| {
        try testing.expectEqual(railRow(height), expectedRow(over, height));
    }

    // The threshold itself is `trace_rail / trace_full_scale`, 1.0889, and it is
    // asserted from just above rather than at it. Multiplying that ratio back by
    // `trace_full_scale` in f32 does not always land on `trace_rail` exactly, so
    // an equality *at* the boundary would be a test of float rounding rather
    // than of the clamp. A tenth of a percent over is unambiguous and is still
    // three orders of magnitude inside the errors this file exists to catch.
    const threshold = iface.trace_rail / iface.trace_full_scale;
    try testing.expectEqual(railRow(height), expectedRow(threshold * 1.001, height));

    // And the direction that would make the above vacuous: full scale is *not*
    // on the rail, or the margin the two constants exist to create is gone.
    try testing.expect(expectedRow(1.0, height) > railRow(height) + 1.0);
}

test "the rail sits inside the drawable at every geometry the editor permits" {
    // The smallest editor is 270 points tall, at a backing scale of 1.
    try testing.expect(railRow(270) >= 1.0);
    try testing.expect(railRow(540) >= 1.0);
}

test "one pixel of tolerance is the display's own quantum" {
    // The visibility floor from `trace_full_scale`'s doc comment, stated there as
    // `1 / (trace_full_scale * height / 2)`.
    try testing.expectApproxEqAbs(
        @as(f32, 1.0) / (iface.trace_full_scale * 540.0 / 2.0),
        pixelTolerance(540),
        1e-9,
    );

    // Far under the errors it has to catch. `full_scale` applied twice takes a
    // sample of 1.0 to where 0.9 belongs, which is this many pixels away.
    const doubled = @abs(expectedRow(1.0, 540) - expectedRow(0.9 * 1.0, 540));
    try testing.expect(doubled > 20.0);
}

test "a dark image yields nothing rather than a guess" {
    var pixels: [16 * 8 * 4]f32 = @splat(0);
    const image: Image = .{ .width = 16, .height = 8, .pixels = &pixels };

    try testing.expectEqual(@as(?usize, null), topRow(image, 0, 0.5));
    try testing.expectEqual(@as(?usize, null), bottomRow(image, 0, 0.5));
    try testing.expectEqual(@as(usize, 0), litColumns(image, 0.5));
    try testing.expectEqual(@as(?Extremes, null), extremes(image, 0.5));
    try testing.expectEqual(@as(?Span, null), litSpan(image, 0.5));
    try testing.expectEqual(@as(usize, 0), periods(image, 0.5));
    try testing.expectEqual(@as(usize, 0), plateauWidth(image, 0.5));
    try testing.expectEqual(@as(f32, 0), maxChannel(image, 1));
    try testing.expectEqual(@as(?Point, null), peakPixel(image, 1));
}

test "an image shorter than its declared geometry is reported as incomplete" {
    var pixels: [4]f32 = @splat(0);
    const image: Image = .{ .width = 16, .height = 8, .pixels = &pixels };
    try testing.expect(!image.complete());

    var full: [16 * 8 * 4]f32 = @splat(0);
    try testing.expect((Image{ .width = 16, .height = 8, .pixels = &full }).complete());
}

test "a flat window lights every column, centred on the centre line" {
    const width: usize = 128;
    const height: usize = 64;

    var pixels: [width * height * 4]f32 = undefined;
    var window: [width]f32 = undefined;
    constant(&window, 0.0);

    const image = rasterize(&pixels, width, height, &window);

    try testing.expectEqual(width, litColumns(image, 0.5));

    // **This test used to assert `top == bottom`, and #57 is what made that
    // false.** A beam with width lights more than one row by construction, so the
    // property worth asserting moved from how many rows are lit to where their
    // energy is centred. Every column carries the same centroid, and it is the
    // centre line, which is the same claim the old form was making about a
    // one-pixel line and is now making about a beam.
    const seen = centres(image).?;
    try testing.expectApproxEqAbs(seen.top, seen.bottom, 1e-4);

    // Exactly zero rather than within a pixel, because 64 is even: the centreline
    // falls between two rows, a symmetric profile weights them equally, and the
    // centroid lands on the boundary. This is #38's `+0.0021` not happening.
    try testing.expectApproxEqAbs(
        @as(f32, 0.0),
        impliedSampleAt(seen.top, height),
        1e-5,
    );

    // And the beam does have an interior, so the assertion above is not being
    // satisfied by the old one-pixel image in disguise.
    const lit = extremes(image, 0.5).?;
    try testing.expect(lit.bottom > lit.top);
}

test "the centroid recovers the row the mapping asks for, at every level" {
    const width: usize = 128;
    const height: usize = 64;

    var pixels: [width * height * 4]f32 = undefined;
    var window: [width]f32 = undefined;

    // Every level the harness checks, plus zero, against `expectedRow` — which is
    // the mapping derived independently on this side rather than the rasterizer
    // asked what it just did.
    //
    // **A twentieth of a pixel, where `pixelTolerance` is a whole one.** That gap
    // is the entire case for the estimator: the row a beam's *edge* falls on is a
    // quantity the profile and the sub-pixel phase both move, and it is what every
    // vertical assertion used to be stated in.
    for ([_]f32{ 0.0, 0.25, -0.25, 0.5, -0.5, 1.0, -1.0 }) |sample| {
        constant(&window, sample);
        const image = rasterize(&pixels, width, height, &window);

        const centre = centroidRow(image, width / 2).?;
        try testing.expectApproxEqAbs(expectedRow(sample, height), centre, 0.06);
    }

    // A dark column is nothing rather than row zero, which is the distinction a
    // sum with no guard would lose.
    constant(&window, 0.0);
    const image = rasterize(&pixels, width, height, &window);
    try testing.expect(centroidRow(image, width / 2) != null);

    var dark: [width * height * 4]f32 = @splat(0);
    const blank: Image = .{ .width = width, .height = height, .pixels = &dark };
    try testing.expectEqual(@as(?f32, null), centroidRow(blank, 0));
    try testing.expectEqual(@as(?Centres, null), centres(blank));
}

test "periods are counted exactly, including where a crossing spans many rows" {
    const width: usize = 960;
    const height: usize = 540;

    const pixels = try scratch(width, height);
    defer testing.allocator.free(pixels);

    var window: [width]f32 = undefined;

    // The last of these is the case that broke #38's first counter. At twenty
    // periods a crossing segment spans about twenty-five rows, so a counter
    // reading the topmost lit pixel against the centre row sees the crossing
    // early and reports nineteen. Strict equality here is the guard: a ±1
    // tolerance would call that correct, which is exactly what happened.
    for ([_]usize{ 1, 2, 4, 5, 8, 20 }) |cycles| {
        sine(&window, @floatFromInt(cycles), 0.8);
        const image = rasterize(pixels, width, height, &window);
        try testing.expectEqual(cycles, periods(image, 0.5));
    }
}

test "doubling a frequency doubles the period count" {
    const width: usize = 960;
    const height: usize = 540;

    const pixels = try scratch(width, height);
    defer testing.allocator.free(pixels);

    var window: [width]f32 = undefined;

    // The ratio form, which is robust to phase, to the `n - 1` quibble, and to
    // miscounting a partial period at an edge in a way an absolute count is not.
    var previous: usize = 0;
    for ([_]usize{ 2, 4, 8 }) |cycles| {
        sine(&window, @floatFromInt(cycles), 0.8);
        const image = rasterize(pixels, width, height, &window);
        const counted = periods(image, 0.5);

        if (previous != 0) try testing.expectEqual(previous * 2, counted);
        previous = counted;
    }
}

test "a sine below the visibility floor reads as flat" {
    const width: usize = 128;
    const height: usize = 64;

    var pixels: [width * height * 4]f32 = undefined;
    var window: [width]f32 = undefined;

    // A tenth of one pixel of travel. This is arithmetic rather than a defect,
    // and the harness has to know it so a level sweep stops where the display
    // does instead of reporting the floor as a failure.
    sine(&window, 4.0, pixelTolerance(height) / 10.0);
    const image = rasterize(&pixels, width, height, &window);

    // One row of slack, not zero, and the reason is the centre line rather than
    // the signal. At an even height the centre falls on an exact pixel boundary,
    // so a signal an order of magnitude under one pixel still has both candidate
    // rows available and the tie-break can pick either. That is the benign twin
    // of the rail's edge case: it is why silence at 1920x1080 draws on row 539
    // rather than 540, and why a flat line that *flickers* between two rows
    // during playback would be the thing worth investigating.
    const seen = extremes(image, 0.5).?;
    try testing.expect(seen.bottom - seen.top <= 1);
}

test "a three-sample ramp reaches both edges" {
    const width: usize = 96;
    const height: usize = 64;

    var pixels: [width * height * 4]f32 = undefined;
    var window: [3]f32 = undefined;
    ramp(&window, -1.0, 1.0);

    try testing.expectEqual(@as(f32, -1.0), window[0]);
    try testing.expectEqual(@as(f32, 0.0), window[1]);
    try testing.expectEqual(@as(f32, 1.0), window[2]);

    // The model rasterizer maps `2i / (n - 1)`, so three samples span the full
    // width. That is the property the offscreen harness checks against the real
    // shader, where a divisor of `n` would leave the right third dark.
    const image = rasterize(&pixels, width, height, &window);
    const span = litSpan(image, 0.5).?;
    try testing.expectEqual(@as(usize, 0), span.first);
    try testing.expectEqual(width - 1, span.last);

    // What the wrong divisor would give, computed rather than asserted, so the
    // margin the harness relies on is written down: `2i / n` puts the last vertex
    // at `(n - 1) / n` of the way across, a third of the width short at n = 3.
    const wrong_last = (width - 1) * 2 / 3;
    try testing.expect(span.last - wrong_last > width / 4);
}

test "a lit span and a peak channel are read off the same image" {
    const width: usize = 64;
    const height: usize = 32;

    var pixels: [width * height * 4]f32 = @splat(0);
    const image: Image = .{ .width = width, .height = height, .pixels = &pixels };

    // Two lit pixels, of different brightness, in known columns.
    pixels[(5 * width + 10) * 4 + 1] = 1.0;
    pixels[(7 * width + 40) * 4 + 1] = 2.5;

    const span = litSpan(image, 0.5).?;
    try testing.expectEqual(@as(usize, 10), span.first);
    try testing.expectEqual(@as(usize, 40), span.last);

    // Unclipped, which is what makes the decay ratio measurable at all.
    try testing.expectEqual(@as(f32, 2.5), maxChannel(image, 1));
    try testing.expectEqual(@as(f32, 0.0), maxChannel(image, 0));

    // The brighter of the two, not the first one found: the dim pixel is earlier
    // in scan order, so a search seeded from whatever it saw first reports it.
    try testing.expectEqual(Point{ .x = 40, .y = 7 }, peakPixel(image, 1).?);
    try testing.expectEqual(@as(?Point, null), peakPixel(image, 0));
}

test "a sine window holds whole cycles across the drawn span" {
    var window: [961]f32 = undefined;
    sine(&window, 2.0, 1.0);

    // First and last vertex are both on the right edge of a whole period, which
    // is what the `n - 1` span buys and what keeps a peak from falling off the
    // edge on half the counts.
    try testing.expectApproxEqAbs(@as(f32, 0.0), window[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), window[window.len - 1], 1e-5);
}

test "a plateau is measured but says nothing about level" {
    const width: usize = 960;
    const height: usize = 540;

    const pixels = try scratch(width, height);
    defer testing.allocator.free(pixels);

    var window: [width]f32 = undefined;

    // The measurement recorded in #51's comment: an unclipped sine at 1.089 had
    // a *narrower* top than one at 1.000, because it moved faster through its peak
    // than the eight pixels of clamping widened it.
    //
    // **#57 reversed that, which is the strongest possible argument for the thing
    // this test's name has always claimed.** At a one-pixel line the widths were
    // 17 at the rail against a larger figure at full scale; with a beam they are
    // 27 at the rail against 17 at full scale, because `plateauWidth` counts
    // columns sharing the topmost lit row and a clamped peak presents a flat edge
    // that many more columns share. Same signals, same analyser, opposite
    // ordering, and the only thing that changed was the primitive.
    //
    // So the ordering is not asserted, in either direction. What is asserted is
    // that both are positive, which is all `plateauWidth` is ever allowed to be
    // read as saying. It is reported by `scripts/measure-trace` and concluded
    // from nowhere.
    sine(&window, 2.0, 1.0);
    const at_full = plateauWidth(rasterize(pixels, width, height, &window), 0.5);

    sine(&window, 2.0, iface.trace_rail / iface.trace_full_scale);
    const at_rail = plateauWidth(rasterize(pixels, width, height, &window), 0.5);

    try testing.expect(at_full > 0);
    try testing.expect(at_rail > 0);
}
