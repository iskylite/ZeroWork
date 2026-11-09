const std = @import("std");
pub fn format(a: std.mem.Allocator, bytes: u64) ![]u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    var scale: u64 = 1;
    var index: usize = 0;
    while (index + 1 < units.len and bytes / scale >= 1024) : (index += 1) scale *= 1024;
    if (bytes % scale == 0) return std.fmt.allocPrint(a, "{d} {s}", .{ bytes / scale, units[index] });
    return std.fmt.allocPrint(a, "{d:.2} {s}", .{ @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(scale)), units[index] });
}
