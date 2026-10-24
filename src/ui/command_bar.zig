const std = @import("std");
const builtin = @import("builtin_commands.zig");
const SessionRuntime = @import("../host/runtime_service.zig").Runtime;

pub const Execution = union(enum) { none, replay, saved_log: []const u8, passthrough: []const u8, unsupported };

pub fn executeResult(result: Model.Result, runtime: ?*SessionRuntime, io: std.Io, dir: std.Io.Dir) !Execution {
    _ = runtime;
    _ = io;
    _ = dir;
    return switch (result) {
        .idle => .none,
        .passthrough => |line| .{ .passthrough = line },
        .builtin => |command| switch (command) {
            .log => .replay,
            else => .unsupported,
        },
    };
}

/// UI-thread command bar state. Zenit Input.on_submit supplies the submitted line;
/// this model keeps parsing/execution routing independent from node ownership.
pub const Model = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    last_result: Result = .idle,

    pub const Result = union(enum) {
        idle,
        builtin: builtin.Command,
        passthrough: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Model) void {
        switch (self.last_result) {
            .passthrough => |value| self.allocator.free(value),
            .builtin => |command| switch (command) {
                .log => |path| if (path) |value| self.allocator.free(value),
                else => {},
            },
            else => {},
        }
        self.text.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Model, bytes: []const u8) !void {
        try self.text.appendSlice(self.allocator, bytes);
    }

    pub fn clear(self: *Model) void {
        self.text.clearRetainingCapacity();
    }

    /// Copies the submitted value before parsing because Zenit's callback slice is ephemeral.
    pub fn submit(self: *Model) !Result {
        const line = try self.allocator.dupe(u8, self.text.items);
        defer self.allocator.free(line);
        self.clear();
        const command = builtin.parse(line);
        self.last_result = switch (command) {
            .not_command => |value| .{ .passthrough = try self.allocator.dupe(u8, value) },
            .log => |path| .{ .builtin = .{ .log = if (path) |value| try self.allocator.dupe(u8, value) else null } },
            else => .{ .builtin = command },
        };
        return self.last_result;
    }
};

test "command bar copies passthrough before clearing input" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.append("echo ready");
    const result = try model.submit();
    try std.testing.expectEqualStrings("echo ready", result.passthrough);
    try std.testing.expectEqual(@as(usize, 0), model.text.items.len);
}

test "command bar classifies @log for Zenit submit handler" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.append("@log");
    const result = try model.submit();
    try std.testing.expect(result.builtin == .log);
    try std.testing.expect(result.builtin.log == null);
}
