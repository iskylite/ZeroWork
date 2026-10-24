//! An owned, bounded snapshot backing the existing context-provider contract.
//! Keeping it after tab changes never retargets a newer live session.
const std = @import("std");
const identity = @import("../host/identity.zig");
const context = @import("../ai/context.zig");
const Lines = @import("../vt/viewport.zig").Lines;

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    source_revision: u64,
    lines: Lines,
    cwd_owned: ?[]u8,
    uid_label: []u8,

    pub fn deinit(self: *Snapshot) void {
        self.lines.deinit(self.allocator);
        if (self.cwd_owned) |cwd| self.allocator.free(cwd);
        self.allocator.free(self.uid_label);
    }
    pub fn provider(self: *Snapshot) context.SessionContextProvider {
        return .{ .ctx = self, .read_lines = readLines, .cwd = getCwd, .identity = getIdentity };
    }
    fn readLines(raw: *anyopaque, max_lines: u32, allocator: std.mem.Allocator) !context.ContextBlock {
        const self: *Snapshot = @ptrCast(@alignCast(raw));
        const count = @min(@as(usize, max_lines), self.lines.lines.len);
        const lines = try allocator.alloc([]u8, count);
        var written: usize = 0;
        errdefer {
            for (lines[0..written]) |line| allocator.free(line);
            allocator.free(lines);
        }
        for (self.lines.lines[self.lines.lines.len - count ..], 0..) |line, i| {
            lines[i] = try allocator.dupe(u8, line);
            written += 1;
        }
        return .{ .lines = lines, .cwd = self.cwd_owned, .shell = "/bin/zsh", .truncated = self.lines.truncated or count < self.lines.lines.len };
    }
    fn getCwd(raw: *anyopaque) ?[]const u8 {
        return @as(*Snapshot, @ptrCast(@alignCast(raw))).cwd_owned;
    }
    fn getIdentity(raw: *anyopaque) context.SessionIdentity {
        const self: *Snapshot = @ptrCast(@alignCast(raw));
        return .{ .host = "localhost", .user = self.uid_label, .hops = 0 };
    }
};
