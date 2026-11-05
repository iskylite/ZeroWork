//! Display provenance only. Never included in provider message image blocks.
const std = @import("std");
pub const Source = struct {
    owner: @import("../host/identity.zig").SessionHandle,
    cwd: ?[]const u8 = null,
    transport: enum { local, ssh } = .local,
    pub fn clone(self: Source, a: std.mem.Allocator) !Source {
        return .{ .owner = self.owner, .cwd = if (self.cwd) |cwd| try a.dupe(u8, cwd) else null, .transport = self.transport };
    }
    pub fn deinit(self: *Source, a: std.mem.Allocator) void {
        if (self.cwd) |cwd| a.free(cwd);
        self.* = undefined;
    }
};
