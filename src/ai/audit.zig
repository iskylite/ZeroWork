const std = @import("std");

pub const Entry = struct { timestamp_ms: i64, turn_id: u64, command: []const u8, verdict: []const u8, target: []const u8, call_id: ?[]const u8 = null };

pub const Log = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    pub fn init(allocator: std.mem.Allocator) Log {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Log) void {
        self.truncate(0);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn append(self: *Log, entry: Entry) !void {
        var owned = entry;
        owned.command = try self.allocator.dupe(u8, entry.command);
        errdefer self.allocator.free(owned.command);
        owned.verdict = try self.allocator.dupe(u8, entry.verdict);
        errdefer self.allocator.free(owned.verdict);
        owned.target = try self.allocator.dupe(u8, entry.target);
        errdefer self.allocator.free(owned.target);
        owned.call_id = if (entry.call_id) |id| try self.allocator.dupe(u8, id) else null;
        errdefer if (owned.call_id) |id| self.allocator.free(id);
        try self.entries.append(self.allocator, owned);
    }
    pub fn len(self: Log) usize {
        return self.entries.items.len;
    }

    pub fn truncate(self: *Log, length: usize) void {
        if (length >= self.entries.items.len) return;
        for (self.entries.items[length..]) |entry| {
            self.allocator.free(entry.command);
            self.allocator.free(entry.verdict);
            self.allocator.free(entry.target);
            if (entry.call_id) |id| self.allocator.free(id);
        }
        self.entries.items.len = length;
    }

    pub fn findCall(self: Log, call_id: []const u8) ?Entry {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entries.items[index];
            if (entry.call_id) |id| if (std.mem.eql(u8, id, call_id)) return entry;
        }
        return null;
    }
};

test "audit log records permission decisions" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();
    try log.append(.{ .timestamp_ms = 1, .turn_id = 2, .command = "ps", .verdict = "allow_auto", .target = "node" });
    try std.testing.expectEqual(@as(usize, 1), log.len());
}

test "audit log finds latest tool call entry" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();
    try log.append(.{ .timestamp_ms = 1, .turn_id = 2, .command = "first", .verdict = "tool_plan", .target = "provider", .call_id = "call-1" });
    try log.append(.{ .timestamp_ms = 2, .turn_id = 2, .command = "second", .verdict = "tool_done", .target = "provider", .call_id = "call-1" });
    try std.testing.expectEqualStrings("second", log.findCall("call-1").?.command);
}

test "audit owns strings after request snapshot and tool buffers change" {
    var log = Log.init(std.testing.allocator);
    defer log.deinit();
    var model = "model-a".*;
    var command = "printf".*;
    var verdict = "allow".*;
    var call = "call1".*;
    try log.append(.{ .timestamp_ms = 1, .turn_id = 1, .command = &command, .verdict = &verdict, .target = &model, .call_id = &call });
    @memset(&model, 'x');
    @memset(&command, 'x');
    @memset(&verdict, 'x');
    @memset(&call, 'x');
    const saved = log.findCall("call1").?;
    try std.testing.expectEqualStrings("model-a", saved.target);
    try std.testing.expectEqualStrings("printf", saved.command);
    try std.testing.expectEqualStrings("allow", saved.verdict);
    log.truncate(0);
    try std.testing.expectEqual(@as(usize, 0), log.len());
}
