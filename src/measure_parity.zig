//! Cross-language fixture consumed by scripts/test-measure-trace.py.
const std = @import("std");
const measure = @import("gpu/measure.zig");
const cases = @import("cases");

fn checkRow(row: cases.Row) !void {
    try std.testing.expectEqual(row.centre, measure.centreRow(row.height));
    try std.testing.expectApproxEqAbs(row.rail, measure.railRow(row.height), 0.0001);
    try std.testing.expectApproxEqAbs(
        row.bottom,
        @as(f32, @floatFromInt(row.height - 1)) - measure.railRow(row.height),
        0.0005,
    );
    try std.testing.expectEqual(row.band, measure.periodBand(row.height, row.peak));
}

fn checkPeriods(image: cases.Image) !void {
    var pixels: [16 * 16 * 4]f32 = @splat(0);
    for (image.top, 0..) |row, x| {
        if (row >= 0) pixels[(@as(usize, @intCast(row)) * image.top.len + x) * 4 + 1] = 1;
    }
    try std.testing.expectEqual(image.periods, measure.periods(.{
        .width = image.top.len,
        .height = image.height,
        .pixels = &pixels,
    }, 0.5));
}

test "derived rows and period runs agree with the script" {
    for (cases.rows) |row| try checkRow(row);

    // Each geometry assertion must reject an independently changed result.
    inline for (.{ "centre", "rail", "bottom", "band" }) |field| {
        var wrong = cases.rows[0];
        @field(wrong, field) += 0.5;
        const expected = if (std.mem.eql(u8, field, "rail") or std.mem.eql(u8, field, "bottom"))
            error.TestExpectedApproxEqAbs
        else
            error.TestExpectedEqual;
        try std.testing.expectError(expected, checkRow(wrong));
    }
    for (cases.images) |image| try checkPeriods(image);
    var wrong = cases.images[0];
    wrong.periods += 1;
    try std.testing.expectError(error.TestExpectedEqual, checkPeriods(wrong));
}

test {
    std.testing.refAllDecls(@This());
}
