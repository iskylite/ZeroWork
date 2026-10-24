const std = @import("std");
const permission = @import("permission.zig");
const tool_scope = @import("tool_scope.zig");

pub const Phase = enum { running, done, failed, aborted };
pub const ExecState = struct { handle: u32, phase: Phase, exit: ?i32, elapsed_ms: u32, summary: []const u8 };
pub const Card = union(enum) { text: []const u8, code: struct { lang: []const u8, body: []const u8 }, exec_plan: struct { cmd: []const u8, verdict: permission.Verdict, call_id: ?[]const u8 = null, tool: tool_scope.Tool = .run_command, owner: ?tool_scope.Owner = null, targets: tool_scope.Targets = .{} }, exec_state: ExecState, file_ref: struct { path: []const u8, head_bytes: u32 } };

pub fn estimateTokens(bytes: usize) usize {
    return (bytes + 3) / 4;
}
pub fn contextBudget(context_window: u32) usize {
    return @min(@as(usize, context_window) * 5 / 100, 4 * 1024);
}

test "card model estimates bounded context budget" {
    try std.testing.expectEqual(@as(usize, 1024), contextBudget(20_480));
    try std.testing.expectEqual(@as(usize, 3), estimateTokens(9));
    const execution: Card = .{ .exec_plan = .{ .cmd = "ls", .verdict = .allow_auto, .call_id = "call-1" } };
    try std.testing.expectEqualStrings("call-1", execution.exec_plan.call_id.?);
}
