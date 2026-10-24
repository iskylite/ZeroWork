//! Append formatted text using the caller's existing array allocation.
const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    pub fn print(self: Writer, comptime format: []const u8, args: anytype) std.mem.Allocator.Error!void {
        var writer = std.Io.Writer.Allocating.fromArrayList(self.allocator, self.list);
        defer self.list.* = writer.toArrayList();
        writer.writer.print(format, args) catch return error.OutOfMemory;
    }
};

pub fn init(allocator: std.mem.Allocator, ptr: anytype) Writer {
    return .{ .allocator = allocator, .list = if (@typeInfo(@TypeOf(ptr.*)) == .pointer) ptr.* else ptr };
}
