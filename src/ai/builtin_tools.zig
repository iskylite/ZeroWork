//! Local display commands. They never write bytes to a terminal's shell.
const std = @import("std");
const host = @import("host_tools.zig");
pub const id = "host.run_builtin";
pub const contribution: host.Contribution = .{ .authority = .conversation_context, .definition = .{
    .id = id,
    .description = "Run a ZeroWork local display command in the authorized terminal's document. @dots displays the donation QR card; @help displays the built-in command catalog. These are application commands, not shell executables: never send them to run_command or host.run_in_terminal. Other built-ins must be entered manually. No remote input is sent and no shell readiness is required.",
    .schema =
    \\{"type":"object","additionalProperties":false,"properties":{"session_ref":{"type":"string","minLength":1,"maxLength":128},"command":{"type":"string","enum":["@dots","@help"]}},"required":["session_ref","command"]}
    ,
} };
pub const Request = struct { reference: []const u8, command: []const u8 };
pub fn parse(value: std.json.Value) !Request {
    if (value != .object or value.object.count() != 2) return error.InvalidArguments;
    const reference = value.object.get("session_ref") orelse return error.InvalidArguments;
    const command = value.object.get("command") orelse return error.InvalidArguments;
    if (reference != .string or command != .string or reference.string.len == 0 or reference.string.len > 128) return error.InvalidArguments;
    if (!std.mem.eql(u8, command.string, "@dots") and !std.mem.eql(u8, command.string, "@help")) return error.InvalidArguments;
    return .{ .reference = reference.string, .command = command.string };
}
pub fn result(invocation: host.Invocation, allocator: std.mem.Allocator, command: []const u8) !host.Result {
    const body = try std.json.Stringify.valueAlloc(allocator, .{ .state = "displayed", .command = command, .shell_input_sent = false }, .{});
    errdefer allocator.free(body);
    const blocks = try allocator.alloc(host.Block, 1);
    blocks[0] = .{ .structured = body };
    return .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision, .side_effect_started = true } };
}

test "builtin display tool rejects shell commands and extra arguments" {
    const a = std.testing.allocator;
    inline for (.{ "@dots", "@help", "@dots; whoami", "pwd", "@up" }) |command| {
        const json = try std.json.Stringify.valueAlloc(a, .{ .session_ref = "s1:fixture", .command = command }, .{});
        defer a.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer parsed.deinit();
        if (comptime std.mem.eql(u8, command, "@dots") or std.mem.eql(u8, command, "@help")) {
            try std.testing.expectEqualStrings(command, (try parse(parsed.value)).command);
        } else try std.testing.expectError(error.InvalidArguments, parse(parsed.value));
    }
}
