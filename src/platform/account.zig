const std = @import("std");
/// Freeze the user's real account home, ignoring application overrides and
/// mutable environment strings.
pub fn home(allocator: std.mem.Allocator) ![]u8 {
    var record: std.c.passwd = undefined;
    var result: ?*std.c.passwd = null;
    var buffer: [16 * 1024]u8 = undefined;
    if (std.c.getpwuid_r(std.c.getuid(), &record, &buffer, buffer.len, &result) != 0 or result == null) return error.HomeUnavailable;
    const value = std.mem.span(record.dir orelse return error.HomeUnavailable);
    if (value.len == 0 or value[0] != '/') return error.HomeUnavailable;
    return allocator.dupe(u8, value);
}
