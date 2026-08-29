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
    /// Green rather than luminance, and that is not an aesthetic choice: the
    /// background has more blue than green, so a luminance threshold would find
    /// the background lit everywhere. It is also why `trace_fragment`'s
    /// provisional colour is green-dominant and why #60 ends this convention
    /// along with the colour.
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

/// The sample value a row implies, inverting the shader's mapping.
///
/// The row's *centre* rather than its edge, since a pixel is a square and the
/// mapping is about points: `[[position]]` in a fragment is window space with
/// pixel centres at half-integers, and a row therefore stands for `row + 0.5`.
/// `scripts/measure-trace` omits that term, which puts the two half a pixel
/// apart; both are inside the one-pixel band every assertion here is stated in,
/// and reconciling them is not this file's business.
pub fn impliedSample(row: usize, height: usize) f32 {
    const centred = (@as(f32, @floatFromInt(row)) + 0.5) / @as(f32, @floatFromInt(height));
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
/// Not the shader and not a claim to be: it is a model of a line strip, used to
/// test the analysis. What the shader actually draws is what `zig build
/// smoke-trace` measures.
fn rasterize(pixels: []f32, width: usize, height: usize, window: []const f32) Image {
    @memset(pixels, 0);
    const image: Image = .{ .width = width, .height = height, .pixels = pixels };

    var previous: ?usize = null;
    for (window, 0..) |sample, i| {
        const x_ndc = 2.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(window.len - 1)) - 1.0;
        const column = @min(
            width - 1,
            @as(usize, @intFromFloat(@round((x_ndc + 1.0) / 2.0 * @as(f32, @floatFromInt(width - 1))))),
        );

        const row_f = expectedRow(sample, height);
        const row = @min(height - 1, @as(usize, @intFromFloat(@max(0.0, @round(row_f)))));

        const from = if (previous) |p| @min(p, row) else row;
        const to = if (previous) |p| @max(p, row) else row;

        var y = from;
        while (y <= to) : (y += 1) {
            pixels[(y * width + column) * 4 + 1] = 1.0;
        }
        previous = row;
    }

    return image;
}

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
    try testing.expectEqual(@as(usize, 0), periods(image, 0.5));
    try testing.expectEqual(@as(usize, 0), plateauWidth(image, 0.5));
}

test "an image shorter than its declared geometry is reported as incomplete" {
    var pixels: [4]f32 = @splat(0);
    const image: Image = .{ .width = 16, .height = 8, .pixels = &pixels };
    try testing.expect(!image.complete());

    var full: [16 * 8 * 4]f32 = @splat(0);
    try testing.expect((Image{ .width = 16, .height = 8, .pixels = &full }).complete());
}

test "a flat window lights every column on one row" {
    const width: usize = 128;
    const height: usize = 64;

    var pixels: [width * height * 4]f32 = undefined;
    var window: [width]f32 = undefined;
    constant(&window, 0.0);

    const image = rasterize(&pixels, width, height, &window);

    try testing.expectEqual(width, litColumns(image, 0.5));

    const seen = extremes(image, 0.5).?;
    try testing.expectEqual(seen.top, seen.bottom);
    try testing.expect(@abs(impliedSample(seen.top, height)) <= pixelTolerance(height));
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
    try testing.expect(topRow(image, 0, 0.5) != null);
    try testing.expect(topRow(image, width - 1, 0.5) != null);
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

    // The measurement recorded in #51's comment: an unclipped sine at 1.089 has
    // a narrower top than one at 1.000, because it moves faster through its peak
    // than the eight pixels of clamping widen it. So the two are not ordered by
    // level, which is why nothing asserts on this number.
    sine(&window, 2.0, 1.0);
    const at_full = plateauWidth(rasterize(pixels, width, height, &window), 0.5);

    sine(&window, 2.0, iface.trace_rail / iface.trace_full_scale);
    const at_rail = plateauWidth(rasterize(pixels, width, height, &window), 0.5);

    try testing.expect(at_full > 0);
    try testing.expect(at_rail > 0);
    try testing.expect(at_rail < at_full);
}
