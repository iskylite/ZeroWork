const std = @import("std");
pub const bins: u32 = 4;
pub const Pen = struct { pixel: f32, bin: u32 };
pub fn windowsPen(value: f32) Pen {
    if (!std.math.isFinite(value)) return .{ .pixel = value, .bin = 0 };
    const quantized = @floor(value * bins + 0.5) / bins;
    const pixel = @floor(quantized);
    return .{ .pixel = pixel, .bin = @intFromFloat(@min(bins - 1, @max(0, @round((quantized - pixel) * bins)))) };
}
test "Windows phase keys are bounded through continuous movement" {
    for (0..10000) |i| {
        const value = @as(f32, @floatFromInt(i)) / 997 - 3;
        const pen = windowsPen(value);
        try std.testing.expect(pen.bin < bins);
        try std.testing.expectApproxEqAbs(value, pen.pixel + @as(f32, @floatFromInt(pen.bin)) / bins, 0.125001);
    }
}

test "Windows phase rounding follows the positive half-bin bias across zero" {
    const below = windowsPen(-0.125);
    try std.testing.expectEqual(@as(f32, 0), below.pixel);
    try std.testing.expectEqual(@as(u32, 0), below.bin);
    const carry = windowsPen(0.875);
    try std.testing.expectEqual(@as(f32, 1), carry.pixel);
    try std.testing.expectEqual(@as(u32, 0), carry.bin);
    try std.testing.expectEqual(@as(u32, 0), windowsPen(std.math.nan(f32)).bin);
}
