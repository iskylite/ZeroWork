//! Decimal token counts shared by assistant usage and model context labels.
const std = @import("std");

pub fn format(buffer: []u8, value: u64) ![]const u8 {
    const unit: u64, const suffix: []const u8 = if (value >= 1_000_000_000)
        .{ 1_000_000_000, "B" }
    else if (value >= 1_000_000)
        .{ 1_000_000, "M" }
    else if (value >= 1_000)
        .{ 1_000, "K" }
    else
        return std.fmt.bufPrint(buffer, "{d}", .{value});
    return std.fmt.bufPrint(buffer, "{d:.1}{s}", .{ @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(unit)), suffix });
}

test "AI token counts use decimal K M B units and preserve small counts" {
    var buffer: [32]u8 = undefined;
    for ([_]struct { value: u64, expected: []const u8 }{
        .{ .value = 0, .expected = "0" },
        .{ .value = 999, .expected = "999" },
        .{ .value = 1_000, .expected = "1.0K" },
        .{ .value = 2_560, .expected = "2.6K" },
        .{ .value = 1_000_000, .expected = "1.0M" },
        .{ .value = 1_250_000, .expected = "1.3M" },
        .{ .value = 1_000_000_000, .expected = "1.0B" },
        .{ .value = 2_560_000_000, .expected = "2.6B" },
    }) |case| try std.testing.expectEqualStrings(case.expected, try format(&buffer, case.value));
}
