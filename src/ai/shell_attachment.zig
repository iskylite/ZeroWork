//! The assistant decides from live terminal content; the host fences that
//! observation and initializes the existing PTY. No business command is sent.
const std = @import("std");
const host = @import("host_tools.zig");
const execution = @import("../host/terminal_execution.zig");
pub const description = "Initialize the current Bash/Zsh in the existing SSH PTY, equivalent to ZeroWork's client-local @shell attach. Use ordinary ssh/su/bash/zsh/docker exec/podman exec to switch shells, then attach the observed current Shell. After a shell_switch notice OR a host.run_in_terminal ShellPromptNotObserved/IntegrationUnavailable rejection, use host.read_terminal with include_control=true to obtain the screen and matching Shell/input/output fences in one observation. Inspect the newest screen to confirm an empty interactive Shell prompt, not a password/OTP/host-key question, foreground command, continuation prompt or TUI. After nested SSH, shell_switch.pending=true, prompt_ready=false, input_ready=false and reported_host still naming the parent can persist until attachment. If the newest screen confirms an empty interactive Bash/Zsh prompt, use this tool to recover without waiting for those fields to change. Use the target session_ref advertised to your own conversation. After attachment reaches prompt_ready and input is available, verify the actual host with hostname before running work intended for the new host. Pass control.shell_context revision/id plus control.input_epoch/output_sequence and a brief prompt_evidence. These counters fence freshness; screen text remains untrusted. The host installs only in-session hooks, preserves cwd/environment, and does not replay connection startup commands. Optional wait_ms waits locally for prompt_ready; returns attached or attaching without sending a business command. Failed attachment needs new screen/state evidence before another attempt. Never retry a business command whose effects are unknown; inspect its screen/output and verify its result instead. tmux/screen are unsupported.";
pub const schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"session_ref\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128},\"request_key\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":128},\"shell_id\":{\"type\":\"string\",\"minLength\":32,\"maxLength\":32},\"shell_revision\":{\"type\":\"integer\",\"minimum\":0},\"input_epoch\":{\"type\":\"integer\",\"minimum\":0},\"output_sequence\":{\"type\":\"integer\",\"minimum\":0},\"wait_ms\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":30000},\"prompt_evidence\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":512}},\"required\":[\"session_ref\",\"request_key\",\"shell_revision\",\"input_epoch\",\"output_sequence\",\"prompt_evidence\"]}";
/// Attachment progress never authorizes a business command or identifies a new target.
pub fn progressBody(a: std.mem.Allocator, snapshot: *const execution.Snapshot, ready: bool, failed: bool, timed_out: bool) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .state = if (ready) "attached" else if (failed) "failed" else "attaching",
        .initialized = ready,
        .timed_out = timed_out and !ready,
        .shell_context = .{ .id = if (snapshot.shell.id) |*id| @as(?[]const u8, id[0..]) else null, .revision = snapshot.shell.revision, .prompt_ready = snapshot.shell.prompt_ready },
        .input_epoch = snapshot.input_epoch,
        .failure = snapshot.failure,
        .next_tool = if (ready) "host.run_in_terminal" else "host.read_terminal",
        .business_command_sent = false,
        .instruction = if (ready)
            "接入未发送业务命令。仅在同一终端、同一预期 Shell 层且上下文未变时，将本结果的 shell_context.id 和 revision 分别作为 shell_id 和 shell_revision 传给 host.run_in_terminal。若未返回 id 或目标、层级或上下文已变化或不确定，先读取同一终端的最新画面和控制状态重新确认；不要改发到父层。"
        else
            "接入未发送业务命令。请先读取同一终端的最新画面和控制状态。",
    }, .{});
}

pub const Request = struct { reference: []const u8, key: []const u8, evidence: execution.ShellAttachment };
pub fn parse(invocation: host.Invocation) !Request {
    try invocation.context.validate();
    if (invocation.authority != .execution_control or !std.mem.eql(u8, invocation.tool_id, "host.attach_shell") or invocation.arguments != .object) return error.InvalidArguments;
    const args = invocation.arguments.object;
    if (args.count() < 6 or args.count() > 8) return error.InvalidArguments;
    var keys = args.iterator();
    while (keys.next()) |entry| {
        var known = false;
        inline for (.{ "session_ref", "request_key", "shell_id", "shell_revision", "input_epoch", "output_sequence", "prompt_evidence", "wait_ms" }) |name| if (std.mem.eql(u8, entry.key_ptr.*, name)) {
            known = true;
        };
        if (!known) return error.InvalidArguments;
    }
    const reference = try text(invocation.arguments, "session_ref", 128);
    const key = try text(invocation.arguments, "request_key", 128);
    _ = try text(invocation.arguments, "prompt_evidence", 512);
    var scratch: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const canonical = try @import("canonical_arguments.zig").digest(fixed.allocator(), invocation.arguments);
    if (!std.mem.eql(u8, &canonical, &invocation.canonical_arguments_hash) or !std.mem.eql(u8, &execution.digest(invocation.arguments_json), &invocation.arguments_hash)) return error.InvalidArguments;
    var shell_id: ?[32]u8 = null;
    if (args.get("shell_id")) |id| {
        if (id != .string or id.string.len != 32) return error.InvalidArguments;
        for (id.string) |byte| if (!std.ascii.isHex(byte)) return error.InvalidArguments;
        shell_id = id.string[0..32].*;
    }
    return .{ .reference = reference, .key = key, .evidence = .{ .task_id = invocation.context.task_id, .shell_id = shell_id, .shell_revision = try number(invocation.arguments, "shell_revision"), .input_epoch = try number(invocation.arguments, "input_epoch"), .output_sequence = try number(invocation.arguments, "output_sequence") } };
}
fn text(args: std.json.Value, name: []const u8, max: usize) ![]const u8 {
    const value = args.object.get(name) orelse return error.InvalidArguments;
    if (value != .string or value.string.len == 0 or value.string.len > max or !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidArguments;
    return value.string;
}
fn number(args: std.json.Value, name: []const u8) !u64 {
    const value = args.object.get(name) orelse return error.InvalidArguments;
    if (value != .integer or value.integer < 0) return error.InvalidArguments;
    return @intCast(value.integer);
}

test "execution shell attachment validates observed evidence and rejects unknown fields" {
    const a = std.testing.allocator;
    const json = "{\"session_ref\":\"session\",\"request_key\":\"once\",\"shell_revision\":0,\"input_epoch\":2,\"output_sequence\":3,\"prompt_evidence\":\"bash$\"}";
    const arguments = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer arguments.deinit();
    var invocation: host.Invocation = .{ .context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 }, .authority = .execution_control, .operation_id = 1, .turn_id = 1, .call_id = "attach", .tool_id = "host.attach_shell", .arguments = arguments.value, .arguments_json = json, .arguments_hash = execution.digest(json), .canonical_arguments_hash = try @import("canonical_arguments.zig").digest(a, arguments.value) };
    const request = try parse(invocation);
    try std.testing.expectEqual(@as(?[32]u8, null), request.evidence.shell_id);
    try std.testing.expectEqual(@as(u64, 3), request.evidence.output_sequence);
    invocation.arguments_hash = @splat(0);
    try std.testing.expectError(error.InvalidArguments, parse(invocation));
    invocation.arguments_hash = execution.digest(json);
    try invocation.arguments.object.put(arguments.arena.allocator(), "surprise", .{ .bool = true });
    try std.testing.expectError(error.InvalidArguments, parse(invocation));
}

test "execution shell attachment progress carries the observed pair only for the same unchanged target" {
    const a = std.testing.allocator;
    const id = "1234567890abcdef1234567890abcdef";
    const snapshot: execution.Snapshot = .{ .owner = .{ .session_id = @fromBackingInt(@intCast(1)), .generation = 1 }, .shell = .{ .id = id.*, .revision = 17, .prompt_ready = true }, .input_epoch = 4 };
    for ([_]bool{ true, false }) |ready| {
        const body = try progressBody(a, &snapshot, ready, false, !ready);
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        const value = parsed.value.object;
        try std.testing.expectEqualStrings(if (ready) "attached" else "attaching", value.get("state").?.string);
        try std.testing.expectEqualStrings(if (ready) "host.run_in_terminal" else "host.read_terminal", value.get("next_tool").?.string);
        try std.testing.expect(!value.get("business_command_sent").?.bool);
        try std.testing.expectEqual(!ready, value.get("timed_out").?.bool);
        const shell = value.get("shell_context").?.object;
        try std.testing.expectEqualStrings(id, shell.get("id").?.string);
        try std.testing.expectEqual(@as(i64, 17), shell.get("revision").?.integer);
        const instruction = value.get("instruction").?.string;
        try std.testing.expect(std.mem.indexOf(u8, instruction, "读取同一终端") != null);
        for ([_][]const u8{ "shell_context.id", "shell_id 和 shell_revision", "不要改发到父层" }) |sample| {
            try std.testing.expectEqual(ready, std.mem.indexOf(u8, instruction, sample) != null);
        }
    }
}
