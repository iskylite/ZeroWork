//! Presentation helpers for real command observations. No terminal bytes.
const std = @import("std");
const vt = @import("../vt/snapshot.zig");

pub fn glyph(state: vt.CommandState) []const u8 {
    return switch (state) {
        .running => "•",
        .succeeded => "✓",
        .failed => "×",
        .unknown => "?",
    };
}

pub fn coversRow(command: vt.Command, row: u64) bool {
    const first = command.screen_row orelse return false;
    var last = command.input_end_row orelse first;
    if (last > first and command.input_end_col != null and command.input_end_col.? == 0) last -= 1;
    return row >= first and row <= last;
}

pub fn duration(buffer: []u8, milliseconds: ?u64) ![]const u8 {
    const value = milliseconds orelse return "—";
    return if (value < 1000) std.fmt.bufPrint(buffer, "{d} ms", .{value}) else std.fmt.bufPrint(buffer, "{d:.1} s", .{@as(f64, @floatFromInt(value)) / 1000});
}

test "command annotations hide on every command continuation but not output" {
    const command: vt.Command = .{ .id = 1, .start_ms = 1, .screen_row = 4, .input_end_row = 7, .input_end_col = 0 };
    try std.testing.expect(coversRow(command, 4));
    try std.testing.expect(coversRow(command, 6));
    try std.testing.expect(!coversRow(command, 3));
    try std.testing.expect(!coversRow(command, 7));
    var unknown = command;
    unknown.screen_row = null;
    try std.testing.expect(!coversRow(unknown, 4));
}
