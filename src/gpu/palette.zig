//! The display's colour contract, in Zig.
//!
//! Everything `resolve_fragment` does to a pixel of accumulated energy, restated
//! on this side: the curve that compresses it, the gradient it is looked up in,
//! and the transfer function the drawable stores it through. Arithmetic only, and
//! nothing above this file's own imports, so `zig build test` covers all of it on
//! a runner with no graphics support at all (ADR 0009).
//!
//! **Two callers, and that is the whole reason this is a file rather than a
//! section of `src/gpu/measure.zig`.** The backend uploads `buildPalette`'s table
//! into the texture the shader reads; the harness composes the same table with
//! the same curve to predict what the picture should be. A closed-form palette in
//! MSL would have to be written twice, in two languages, agreeing by inspection.
//! One table read by both agrees by construction, which is `probe`'s argument
//! about sharing `buildPipelines` rather than paraphrasing it, applied to a
//! colour.
//!
//! What is *not* shared is the arithmetic around it. The shader computes the
//! curve and the interpolation in MSL and this file computes them in Zig, so a
//! comparison of the two is a comparison of two independent derivations. The
//! table is the input to both, not the answer.

const std = @import("std");

// ---------------------------------------------------------------------------
// The drawable's transfer function
// ---------------------------------------------------------------------------

/// Where sRGB's linear segment ends, on the linear side.
///
/// Below this the encode is a plain multiply by `srgb_slope` and nothing is
/// raised to a power. That matters here beyond tidiness: the background sits deep
/// inside this segment, so the value the shader writes for it is an exact
/// division rather than an inverted power, and the round trip lands on an integer
/// instead of near one.
const srgb_knee_linear: f32 = 0.0031308;

/// The same knee from the encoded side. `12.92 * 0.0031308` is `0.04044994`, so
/// the two are the same point stated in the two directions; both are written out
/// because rederiving either from the other invites a rounding argument.
const srgb_knee_encoded: f32 = 0.04045;

/// The linear segment's slope, and the number the background literal is divided
/// by in `shaders/scope.metal`.
const srgb_slope: f32 = 12.92;

const srgb_gamma: f32 = 2.4;
const srgb_scale: f32 = 1.055;
const srgb_offset: f32 = 0.055;

/// Linear light to what an sRGB drawable stores, per IEC 61966-2-1.
///
/// **Restated here rather than applied here.** The shipping path does not call
/// this: `drawable_pixel_format` is `BGRA8Unorm_sRGB`, so the render-output stage
/// applies the encode in hardware and the shader writes linear values. This is
/// the model's copy, and the whole point of the model is that it was derived
/// independently of the thing it checks.
///
/// The consequence for every assertion downstream, worth stating where the
/// arithmetic is rather than where it bites: the slope at the bottom is
/// `srgb_slope * 255`, which is 3294.6 bytes per unit of linear signal, so **one
/// 8-bit level is 3.0e-4 of linear energy near black**. That is why the resolve's
/// byte comparison is stated to a level or two and not to a fraction, and why
/// `checkResolve`'s tolerance is a measurement rather than a preference.
pub fn srgbEncode(linear: f32) f32 {
    const c = std.math.clamp(linear, 0.0, 1.0);
    if (c <= srgb_knee_linear) return srgb_slope * c;
    return srgb_scale * std.math.pow(f32, c, 1.0 / srgb_gamma) - srgb_offset;
}

/// The inverse, for reading a stored byte back as the linear value that produced
/// it. `scripts/measure-trace` does the same thing to a screenshot, which is why
/// this exists on both sides.
pub fn srgbDecode(encoded: f32) f32 {
    const s = std.math.clamp(encoded, 0.0, 1.0);
    if (s <= srgb_knee_encoded) return s / srgb_slope;
    return std.math.pow(f32, (s + srgb_offset) / srgb_scale, srgb_gamma);
}

/// A linear value as the byte an 8-bit sRGB drawable stores for it.
///
/// Rounds to nearest, which is what the hardware does. **Do not build an exact
/// assertion on a linear value that lands near a `.5` boundary**: Apple's
/// float-to-unorm conversion is documented to bias low by 1/127500 of full scale,
/// and the hardware evaluates the power through an approximation rather than
/// through `std.math.pow`. Linear 0.5 encodes to 187.516, one sixtieth of a byte
/// above the boundary, and is exactly the kind of probe that would flake.
pub fn srgbByte(linear: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(srgbEncode(linear), 0.0, 1.0) * 255.0));
}

// ---------------------------------------------------------------------------
// The palette
// ---------------------------------------------------------------------------

/// The gradients the resolve looks a colour up in.
///
/// One row of the lookup texture each, selected by `palette_row` in
/// `shaders/scope.metal`. A literal rather than a parameter because nothing can
/// author or automate a choice until phase 5; a debug build switches between them
/// by editing that digit and saving, which is what #61 bought.
pub const Palette = enum(u32) {
    /// P31, and the colour phase 2's trace already drew.
    green = 0,
    /// P3, the amber terminal phosphor.
    amber = 1,
    /// P11, the storage-tube blue.
    blue = 2,
    /// No tint at all, for reading a picture rather than looking at one.
    neutral = 3,

    /// The channel that carries the tonemapped value exactly.
    ///
    /// Every tint below has its largest component at exactly 1.0, so
    /// `mix(tint, 1, w)` leaves that channel at 1 for any `w` and the palette
    /// reduces to `bg + (1 - bg) * t` there. **That is the property the whole
    /// measurement chain rests on**, and it is why this is a method rather than a
    /// fact someone has to notice: `Image.green` reads the accumulation, but
    /// `scripts/measure-trace` reads a *picture* and has to invert it, and the
    /// channel it inverts on depends on which gradient is selected.
    pub fn dominant(self: Palette) usize {
        return switch (self) {
            .green => 1,
            .amber, .neutral => 0,
            .blue => 2,
        };
    }
};

pub const palette_count: usize = @typeInfo(Palette).@"enum".fields.len;

/// Entries per gradient.
///
/// **Two hundred and fifty-six only works because the lookup interpolates**, and
/// the difference is not marginal. Green is affine in the tonemapped value while
/// the sRGB toe runs at 3294.6 bytes per unit linear, so one entry of 1/255 is
/// thirteen bytes at the dark end: nearest-neighbour is 6.4 bytes wrong at this
/// size, and interpolating between neighbours is 0.004. Measured against the
/// closed form at 20001 points, per channel, for all four gradients.
pub const palette_entries: usize = 256;

/// Floats in the whole table, which is what the texture holds and what
/// `buildPalette` fills. RGBA, so the alpha lane is written and ignored.
pub const palette_floats: usize = palette_count * palette_entries * 4;

/// How sharply a gradient runs to white, and therefore how tight the hot core is.
///
/// At four the whitening is confined to the top fifth of the range: the white
/// weight is 0.06 at t = 0.5 and 0.66 at t = 0.9. At two the whole picture
/// whitens and the tint stops meaning anything.
pub const core_exponent: usize = 4;

/// The drawable's colour where no energy has landed, as the bytes it shows.
///
/// **Bytes rather than a linear triple, because bytes are what depends on it.**
/// `scripts/measure-trace` finds this drawable inside a whole-window capture by
/// looking for exactly RGB(5, 5, 8) with blue three above red and green. Stating
/// the linear value instead would make the byte a derivation the Python side
/// could get wrong in silence, and the constants test would compare two agreeing
/// linear numbers while the crop looked for black.
///
/// It is no longer a literal in the shader at all: it is entry zero of every
/// gradient, which is #60's own question about whether the background stays a
/// literal, answered by construction.
pub const background_bytes = [3]u8{ 5, 5, 8 };

/// The same three in the linear light the shader writes.
///
/// An exact division rather than an inverted power, because bytes 0 to 10 are all
/// inside sRGB's linear segment: `12.92 * (5 / (255 * 12.92)) * 255` is 5.000,
/// half a byte from either rounding boundary. That margin is the reason the
/// background is spelled this way at all — Apple's float-to-unorm conversion is
/// documented to bias low by 1/127500 of full scale, so a literal that landed near
/// a `.5` boundary would be a coin flip rather than a constant.
pub fn backgroundLinear(channel: usize) f32 {
    return @as(f32, @floatFromInt(background_bytes[channel])) / (255.0 * srgb_slope);
}

/// The four phosphors, **authored in sRGB and decoded once** by `buildPalette`.
///
/// Authored rather than stored linear so the numbers in this file are the numbers
/// a person picks, and so one derivation stays executable: the first row is
/// phase 2's own `float4(0.30, 1.0, 0.45, 1.0)`, which was a *display-encoded*
/// triple because the drawable applied no transfer function. Mixing those numbers
/// in linear light would ship a paler, whiter green — bytes (149, 255, 179)
/// instead of (76, 255, 115) — while calling it unchanged. The test below is that
/// sentence as an assertion.
///
/// **Each has its largest component at exactly 1.0.** See `Palette.dominant`;
/// changing that changes the meaning of every channel readout in this project at
/// once, and fails nothing but the one test written for it.
pub const tints_srgb = [palette_count][3]f32{
    .{ 0.30, 1.00, 0.45 },
    .{ 1.00, 0.69, 0.00 },
    .{ 0.35, 0.60, 1.00 },
    .{ 1.00, 1.00, 1.00 },
};

/// One gradient's colour at a tonemapped value, in linear light.
///
/// `background` at zero and exactly white at one, both by construction, with no
/// overshoot for the format to clip. Monotone in every channel: the derivative is
/// `(1 - bg)(tint + (n + 1)(1 - tint) t^n)`, non-negative for a tint in [0, 1].
///
/// The fourth power is a multiply chain rather than `pow`, which costs nothing
/// here and matters where this arithmetic is mirrored: the shader is compiled
/// with fast math on, and keeping the whole resolve free of transcendentals is
/// what leaves the hardware's sRGB encode as the only cross-language
/// approximation a byte comparison has to absorb.
pub fn paletteEntry(tint_srgb: [3]f32, t: f32) [3]f32 {
    // The chain below is the exponent, spelled out. Pinned rather than trusted,
    // because changing the constant and not the arithmetic would quietly leave
    // the two disagreeing and every number here would still look plausible.
    comptime std.debug.assert(core_exponent == 4);

    const clamped = std.math.clamp(t, 0.0, 1.0);
    const squared = clamped * clamped;
    const white_weight = squared * squared;

    var out: [3]f32 = undefined;
    for (&out, tint_srgb, 0..) |*slot, tint, channel| {
        const background = backgroundLinear(channel);

        // A tint component of exactly 1.0 stays exactly 1.0 for every weight,
        // which is what makes the dominant channel an exact readout of `t`. The
        // shader mixes the same way for the same reason.
        const linear = srgbDecode(tint);
        const hue = linear + (1.0 - linear) * white_weight;

        slot.* = background + (1.0 - background) * hue * clamped;
    }
    return out;
}

/// Fill the lookup the resolve reads, one gradient per row.
///
/// Row-major, RGBA, which is the layout `MTLTexture.replaceRegion:` wants for a
/// `palette_entries` x `palette_count` texture. `RGBA32Float` rather than the
/// accumulation's half, so the table the GPU reads and the table this file
/// interpolates hold bit-identical values and the model is exact rather than
/// close.
pub fn buildPalette(out: []f32) void {
    std.debug.assert(out.len >= palette_floats);

    const span = @as(f32, @floatFromInt(palette_entries - 1));
    for (0..palette_count) |row| {
        for (0..palette_entries) |i| {
            const t = @as(f32, @floatFromInt(i)) / span;
            const rgb = paletteEntry(tints_srgb[row], t);
            const at = (row * palette_entries + i) * 4;
            out[at + 0] = rgb[0];
            out[at + 1] = rgb[1];
            out[at + 2] = rgb[2];
            out[at + 3] = 1.0;
        }
    }
}

/// Look a colour up the way `resolve_fragment` does, interpolating between
/// neighbours.
///
/// **The interpolation is written out here and in the shader rather than left to
/// a sampler**, which is what makes this a model and not a guess. A linear-filtered
/// sampler would put a half-texel convention between the two sides that nothing
/// could check, and it would also put a `sampler` in the shader, which the
/// negative assertion in `src/gpu/metal/renderer.zig` refuses for an unrelated
/// reason: `bindingIndexAfter` scans to end of file, so a sampler anywhere below
/// the accumulation's uniforms fails a test whose message names those uniforms.
pub fn paletteAt(table: []const f32, palette: Palette, t: f32) [3]f32 {
    const row = @intFromEnum(palette);
    const clamped = std.math.clamp(t, 0.0, 1.0);

    const x = clamped * @as(f32, @floatFromInt(palette_entries - 1));

    // Both annotated `usize`, and that is not decoration. `@min` narrows its
    // result to the smallest type that can hold it, so `@min(n, palette_entries -
    // 1)` against a comptime 255 infers `u8` and `lo + 1` then overflows at the
    // last entry — which is exactly `t = 1`, the white end every gradient is
    // asserted at.
    const lo: usize = @min(@as(usize, @intFromFloat(@floor(x))), palette_entries - 1);
    const hi: usize = @min(lo + 1, palette_entries - 1);
    const f = x - @floor(x);

    var out: [3]f32 = undefined;
    for (&out, 0..) |*slot, c| {
        const a = table[(row * palette_entries + lo) * 4 + c];
        const b = table[(row * palette_entries + hi) * 4 + c];
        slot.* = a + (b - a) * f;
    }
    return out;
}

// ---------------------------------------------------------------------------
// The tonemap
// ---------------------------------------------------------------------------

/// How much of the phosphor survives one frame, restated from
/// `src/gpu/metal/renderer.zig`.
///
/// Its copy is the one the shader is handed; this is the model's, and a test
/// there compares them. It is here rather than imported because this file
/// deliberately reaches nothing but the seam, which is what lets `zig build test`
/// cover it on a runner with no graphics support at all.
pub const decay_per_frame: f32 = 0.90;

/// The fraction of a dwelling beam's steady state that reads pure white.
///
/// **The white point is derived from the decay rather than chosen, and that is
/// the whole reason this constant is a fraction.** A beam that never moves
/// re-deposits into the same pixel every frame and converges on
/// `1 / (1 - decay)`; anchoring white to that makes the look independent of how
/// long the phosphor holds. A fixed white point in energy would not be: once #56
/// makes the decay `exp(-dt / tau)` the steady state tracks the refresh rate, so
/// the same picture would read twice as hot at 120 Hz as at 60. Measured across
/// 48, 60, 120 and 240 Hz, deriving it holds a single deposit at green 188 to 190
/// and the steady state at 255 throughout.
///
/// Below one, and that is not a safety margin. Reinhard reaches its white point
/// exactly at `e = w` while the steady state is only approached, so a white point
/// set at the asymptote itself would never arrive: the core would be pale green
/// forever. At 0.8 a dwelt pixel goes white after sixteen frames.
///
/// **Provisional, and #58 settles it rather than a tuning session.** Measured in
/// REAPER against a 100 Hz sine: the picture peaked at 2.2 and 3.0 deposits on
/// two successive frames, against roughly 1 for a fast crossing. **No white point
/// can carve a visible core out of a 2:1 range** — set it high and nothing reaches
/// white, set it low and everything does, and dropping this to 0.2 moved fifty
/// pixels of thirty-two thousand. Velocity weighting widens that ratio by an order
/// of magnitude, at which point there is a range to map. The value here is what
/// the paragraph above argues for on its own terms; it is not tuned to a picture,
/// because the picture cannot yet distinguish one value from another.
pub const white_headroom: f32 = 0.8;

/// The gradient `shaders/scope.metal` selects, restated for the same reason
/// `decay_per_frame` is, and pinned to the shader's `palette_row` by the
/// constants test.
pub const shipped_palette: Palette = .green;

/// Where the tonemap saturates, in deposits.
///
/// **The brightness axis's rail**, and the same kind of object as
/// `iface.trace_rail` on the vertical one: at or above this the display says "at
/// or above" and refuses to say how far. ADR 0017's reasoning, applied to the
/// second axis.
pub fn whitePoint(decay: f32) f32 {
    // Clamped rather than branched, so the shader can be written the same way
    // without a conditional. A decay of exactly 1 is a phosphor that never fades,
    // whose steady state is unbounded; the clamp sends the white point to 8e5,
    // which makes the shoulder term vanish and leaves plain Reinhard rather than
    // a division by zero. That case is unreachable through `decay_per_frame` and
    // is reachable through a hot-reloaded shader reading an unbound buffer, which
    // is what it is guarded for.
    return white_headroom / @max(1.0 - decay, 1e-6);
}

/// Unbounded linear energy compressed into [0, 1].
///
/// Extended Reinhard: monotone, defined on the whole non-negative line, and equal
/// to exactly one at `white` rather than approaching one asymptotically.
///
/// **Plain Reinhard is the obvious choice and is wrong here.** The attainable
/// domain is `(0, 1 / (1 - decay)]`, which is ten at the shipped factor, because
/// a line strip's x is monotone in `vertex_id` so one frame cannot deposit twice
/// on a pixel. Plain Reinhard returns 0.909 at ten and needs an energy of 167 to
/// reach byte 255, seventeen times anything this display can produce, so a palette
/// running to white never arrives and the hot core is pale green. `1 - exp(-e)`
/// fails from the other side: it saturates by five and resolves nothing above it,
/// which #58 makes worse by widening the domain.
///
/// A rational function rather than a curve with an exponent in it, which is not
/// only taste: `buildPipelinesFromSource` passes no `MTLCompileOptions`, so the
/// shader is compiled with fast math, and keeping the resolve free of
/// transcendentals leaves the hardware's sRGB encode as the only cross-language
/// approximation a byte comparison has to absorb. Measured: worst channel off by
/// zero across 518,400 pixels.
pub fn tonemap(energy: f32, white: f32) f32 {
    const shoulder = 1.0 / (white * white);
    return @min(energy * (1.0 + energy * shoulder) / (1.0 + energy), 1.0);
}

/// What the resolve should make of one pixel's energy, as the bytes the drawable
/// stores.
///
/// The whole of the shader's brightness mapping restated on this side, on
/// `expectedRow`'s precedent for the vertical one, so an assertion compares two
/// independent derivations rather than the shader against itself. It reads the
/// same table the GPU does, which is what makes the palette half exact rather
/// than close: the interpolation is written out in both places and there is no
/// sampler with a half-texel convention between them.
pub fn resolved(table: []const f32, palette: Palette, decay: f32, energy: f32) [3]u8 {
    const rgb = paletteAt(table, palette, tonemap(energy, whitePoint(decay)));
    return .{ srgbByte(rgb[0]), srgbByte(rgb[1]), srgbByte(rgb[2]) };
}

/// The tonemapped value a byte of the dominant channel implies.
///
/// The exact inverse of `bg + (1 - bg) * t` in that channel, which every gradient
/// holds because its largest tint component is exactly 1.0. `scripts/measure-trace`
/// does the same thing to a screenshot; this is here so the property is asserted
/// where it can be tested without a capture.
pub fn dominantToTonemapped(palette: Palette, byte: u8) f32 {
    const background = backgroundLinear(palette.dominant());
    const linear = srgbDecode(@as(f32, @floatFromInt(byte)) / 255.0);
    return (linear - background) / (1.0 - background);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the sRGB transfer function round-trips across the whole byte range" {
    // Both directions, over every byte a drawable can store, because the encode
    // is what the model predicts and the decode is what `scripts/measure-trace`
    // undoes on a capture. An error in either is an error in a published number.
    var byte: u16 = 0;
    while (byte <= 255) : (byte += 1) {
        const encoded = @as(f32, @floatFromInt(byte)) / 255.0;
        const linear = srgbDecode(encoded);
        try testing.expectApproxEqAbs(encoded, srgbEncode(linear), 1e-5);
        try testing.expectEqual(@as(u8, @intCast(byte)), srgbByte(linear));
    }
}

test "the two segments meet at the knee" {
    // The piecewise definition is only a function if the halves agree there, and
    // the two constants are written out separately rather than derived from each
    // other, so this is the one thing keeping them consistent.
    try testing.expectApproxEqAbs(srgb_knee_encoded, srgbEncode(srgb_knee_linear), 1e-6);
    try testing.expectApproxEqAbs(srgb_knee_linear, srgbDecode(srgb_knee_encoded), 1e-6);

    // Approached from below it is a plain multiply, and from above a power.
    try testing.expectApproxEqAbs(
        srgbEncode(srgb_knee_linear - 1e-7),
        srgbEncode(srgb_knee_linear + 1e-7),
        1e-5,
    );
}

test "the ends land on the right bytes and the function is monotone" {
    try testing.expectEqual(@as(f32, 0.0), srgbEncode(0.0));

    // **Not exactly 1.0, and the byte is what is asserted instead.** At full
    // scale the power is 1, so the formula reduces to `srgb_scale -
    // srgb_offset`, and `1.055 - 0.055` in f32 is 0.99999994 rather than one.
    // That is six parts in a hundred million, or 0.000015 of a byte, and it
    // rounds to 255 with half a byte to spare. Asserting the float would be
    // asserting a property of binary32 rather than of the transfer function,
    // which is the same trap the plan's note about linear 0.5 describes from the
    // other end.
    try testing.expectApproxEqAbs(@as(f32, 1.0), srgbEncode(1.0), 1e-6);

    try testing.expectEqual(@as(u8, 0), srgbByte(0.0));
    try testing.expectEqual(@as(u8, 255), srgbByte(1.0));

    // Out of range clamps rather than extrapolating, because the accumulation is
    // unclipped and the resolve's own clamp is what this models.
    try testing.expectEqual(@as(u8, 255), srgbByte(4.0));
    try testing.expectEqual(@as(u8, 0), srgbByte(-1.0));

    var previous: f32 = -1.0;
    var i: usize = 0;
    while (i <= 4096) : (i += 1) {
        const encoded = srgbEncode(@as(f32, @floatFromInt(i)) / 4096.0);
        try testing.expect(encoded >= previous);
        previous = encoded;
    }
}

test "the background's linear value is the byte it has to show" {
    // The spelling `float3(5.0, 5.0, 8.0) / (255.0 * 12.92)` in the shader, in
    // arithmetic. Both components are inside the linear segment, whose ceiling is
    // byte 10, so this is an exact division and the round trip lands on the
    // integer rather than near it. `scripts/measure-trace` finds the drawable
    // inside a window capture by looking for exactly RGB(5, 5, 8), which is why
    // the byte is the thing stated and the linear value is the derivation.
    try testing.expectEqual(@as(u8, 5), srgbByte(5.0 / (255.0 * srgb_slope)));
    try testing.expectEqual(@as(u8, 8), srgbByte(8.0 / (255.0 * srgb_slope)));

    // What the phase 2 literal would have stored had it been left alone, which is
    // the failure this replaces: 7.8 times brighter, and `find_drawable` looking
    // for a background that is no longer there.
    try testing.expectEqual(@as(u8, 39), srgbByte(0.02));
    try testing.expectEqual(@as(u8, 48), srgbByte(0.03));
}

/// A palette table for a test, freed by the caller.
/// A palette table for a test, freed by the caller.
fn paletteScratch() ![]f32 {
    const table = try testing.allocator.alloc(f32, palette_floats);
    buildPalette(table);
    return table;
}

test "every gradient starts at the background and ends at white" {
    const table = try paletteScratch();
    defer testing.allocator.free(table);

    for (std.enums.values(Palette)) |palette| {
        const at_zero = paletteAt(table, palette, 0.0);
        for (at_zero, background_bytes) |value, byte| {
            try testing.expectEqual(byte, srgbByte(value));
        }

        // Exactly white, by construction rather than by clipping. An overshoot
        // would be invisible here and would show as a hue shift at the top, since
        // the channels would clip at different values of `t`.
        const at_one = paletteAt(table, palette, 1.0);
        for (at_one) |value| {
            try testing.expectApproxEqAbs(@as(f32, 1.0), value, 1e-5);
            try testing.expectEqual(@as(u8, 255), srgbByte(value));
        }
    }
}

test "each gradient's dominant channel is an exact readout of the tonemapped value" {
    // **The property the whole measurement chain rests on.** With the largest
    // tint component at exactly 1.0 the palette reduces to `bg + (1 - bg) * t` in
    // that channel, so `scripts/measure-trace` can invert intensity from one
    // channel of a screenshot and predict the other two. A re-tint that broke it
    // would change the meaning of every channel readout in this project at once,
    // and this is the only thing that would notice.
    const table = try paletteScratch();
    defer testing.allocator.free(table);

    for (std.enums.values(Palette)) |palette| {
        const c = palette.dominant();
        const background = @as(f32, @floatFromInt(background_bytes[c])) / (255.0 * srgb_slope);

        var i: usize = 0;
        while (i <= 256) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / 256.0;
            const affine = background + (1.0 - background) * t;
            try testing.expectApproxEqAbs(affine, paletteAt(table, palette, t)[c], 1e-6);
        }

        // And it really is the largest, which is what makes it the best-conditioned
        // estimator rather than merely an exact one.
        for (tints_srgb[@intFromEnum(palette)], 0..) |component, other| {
            if (other == c) continue;
            try testing.expect(component <= tints_srgb[@intFromEnum(palette)][c]);
        }
    }
}

test "every gradient is monotone in every channel" {
    const table = try paletteScratch();
    defer testing.allocator.free(table);

    for (std.enums.values(Palette)) |palette| {
        var previous = [3]f32{ -1.0, -1.0, -1.0 };
        var i: usize = 0;
        while (i <= 8192) : (i += 1) {
            const rgb = paletteAt(table, palette, @as(f32, @floatFromInt(i)) / 8192.0);
            for (rgb, &previous) |value, *seen| {
                try testing.expect(value >= seen.*);
                seen.* = value;
            }
        }
    }
}

test "the green gradient is phase 2's colour, decoded rather than reused" {
    // The derivation made executable. `float4(0.30, 1.0, 0.45, 1.0)` went into a
    // drawable that applied no transfer function, so those numbers were already
    // display-encoded and the bytes they showed were (76, 255, 115). Decoding
    // them is what keeps the colour; reusing them as linear tint would ship
    // (149, 255, 179), a visibly paler green, while calling it unchanged.
    // Phase 2's literal is `tints_srgb[0]`, unchanged, so the check is that
    // decoding it reproduces the bytes that shader showed.
    try testing.expectEqualSlices(f32, &.{ 0.30, 1.00, 0.45 }, &tints_srgb[@intFromEnum(Palette.green)]);

    const shown = [3]u8{ 76, 255, 115 };
    for (tints_srgb[@intFromEnum(Palette.green)], shown) |component, byte| {
        try testing.expectEqual(byte, srgbByte(srgbDecode(component)));

        // The failure this replaces, from the other side: reusing the encoded
        // number as a linear tint makes every non-saturated channel brighter.
        if (component < 1.0) try testing.expect(srgbByte(component) > byte);
    }

    // (149, 255, 179) is what that mistake would have shipped, and naming it is
    // what makes "a paler, whiter green" a measurement rather than an adjective.
    try testing.expectEqual(@as(u8, 149), srgbByte(0.30));
    try testing.expectEqual(@as(u8, 179), srgbByte(0.45));
}

test "interpolating the table tracks the closed form to a fraction of a byte" {
    // **This is why the table interpolates.** Nearest-neighbour at 256 entries is
    // 6.4 bytes wrong, because the dominant channel is affine in `t` while the
    // sRGB toe runs at 3294.6 bytes per unit linear, so one entry is thirteen
    // bytes at the dark end. The bound below is two orders of magnitude inside
    // the resolve's own byte tolerance, which is what makes the model exact
    // enough to be the thing a picture is compared against.
    const table = try paletteScratch();
    defer testing.allocator.free(table);

    for (std.enums.values(Palette)) |palette| {
        var worst: f32 = 0;
        var i: usize = 0;
        while (i <= 20000) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / 20000.0;
            const exact = paletteEntry(tints_srgb[@intFromEnum(palette)], t);
            const looked_up = paletteAt(table, palette, t);
            for (exact, looked_up) |a, b| {
                worst = @max(worst, @abs(srgbEncode(a) - srgbEncode(b)) * 255.0);
            }
        }
        try testing.expect(worst < 0.05);
    }
}

test "the table has a row per palette and the rows differ" {
    const table = try paletteScratch();
    defer testing.allocator.free(table);

    // Alpha is written even though nothing reads it, because a partly-filled
    // texture is the kind of thing that looks right until something samples the
    // lane nobody thought about.
    for (0..palette_count * palette_entries) |texel| {
        try testing.expectEqual(@as(f32, 1.0), table[texel * 4 + 3]);
    }

    // Mid-range, where the tints have not yet washed out to white.
    const green = paletteAt(table, .green, 0.5);
    const amber = paletteAt(table, .amber, 0.5);
    const blue = paletteAt(table, .blue, 0.5);
    const neutral = paletteAt(table, .neutral, 0.5);

    try testing.expect(green[1] > green[0] and green[1] > green[2]);
    try testing.expect(amber[0] > amber[1] and amber[1] > amber[2]);
    try testing.expect(blue[2] > blue[1] and blue[1] > blue[0]);

    // **The neutral gradient is neutral above the background, not from zero**,
    // and the residual is exactly the background's own blue lead fading out.
    // `bg + (1 - bg) t` is `t + bg(1 - t)`, so blue leads red by
    // `(bg_b - bg_r)(1 - t)` and nothing else. That lead is not an imperfection
    // to be tuned away: it is what `find_drawable` keys on to locate this
    // drawable inside a window capture, so it has to survive at t = 0 in every
    // gradient including this one.
    try testing.expectEqual(neutral[0], neutral[1]);

    const lead = @as(f32, @floatFromInt(background_bytes[2] - background_bytes[0])) / (255.0 * srgb_slope);
    try testing.expectApproxEqAbs(lead * 0.5, neutral[2] - neutral[0], 1e-7);
    try testing.expectApproxEqAbs(lead, paletteAt(table, .neutral, 0.0)[2] - paletteAt(table, .neutral, 0.0)[0], 1e-7);
    try testing.expectApproxEqAbs(@as(f32, 0.0), paletteAt(table, .neutral, 1.0)[2] - paletteAt(table, .neutral, 1.0)[0], 1e-7);
}
