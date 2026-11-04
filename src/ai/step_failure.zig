//! Readable diagnostics for calls that ended before execution began.
const std = @import("std");
const events = @import("step_events.zig");

pub const Description = struct {
    summary: []u8,
    detail: []u8,
    pub fn deinit(self: Description, a: std.mem.Allocator) void {
        a.free(self.summary);
        a.free(self.detail);
    }
};

pub fn explanation(code: []const u8) []const u8 {
    const mappings = .{
        .{ "ShellContextExitedWithoutCompletion", "该 Shell 已返回父层，但本条命令没有收到完整结束事件，结果仍待核实。请在原终端查看结果；不要自动重发。" },
        .{ "ShellContextRequired", "当前位于内层 Shell，尚未确认命令的目标环境。请让 AI 重新检查当前终端后再执行。" },
        .{ "ShellContextChanged", "当前 Shell 层级已经变化，本次命令未发送。请重新读取当前 Shell 状态后再执行，避免命令落到错误的主机或用户环境。" },
        .{ "ShellContextLimit", "本次终端已达到可保留的 Shell 实例上限。请结束不再需要的会话，或建立新的终端会话。" },
        .{ "UnsupportedShell", "当前 Shell 暂不支持原地接入。请手动进入 bash 或 zsh，停在空提示符后执行 @shell attach。" },
        .{ "UnsupportedMultiplexer", "当前处于 tmux/screen 环境，暂不支持层级接入。请在普通 SSH、su、bash 或容器交互 Shell 中使用 @shell attach。" },
        .{ "ShellHooksConflict", "当前 Shell 已有不兼容的命令事件钩子，接入未完成。可进入干净的 bash --noprofile --norc 或 zsh -f，再执行 @shell attach；原会话保持可用。" },
        .{ "ShellAttachUnconfirmed", "尚未收到当前 Shell 的接入回执。请确认已进入 bash/zsh 的空提示符，再执行 @shell attach；不要在密码输入或前台程序中执行。" },
        .{ "ShellAttachmentStale", "读取终端后又出现了新的输入或输出，本次接入未开始。请重新读取当前终端和会话状态，确认仍是空 Shell 提示符后再申请接入。" },
        .{ "ShellIntegrationPending", "正在加载当前 Shell 的会话内集成，请等待接入结束后再执行命令。" },
        .{ "ShellPromptNotObserved", "尚未确认当前 Shell 已准备好接收命令。通过 SSH、su 或容器进入的内层 Shell 可能需要重新接入；请确认处于 Bash/Zsh 的空提示符后输入 @shell attach。不要在密码输入或前台程序中执行；结果不明的命令请先核实，不要重发。" },
        .{ "TerminalBusy", "终端正在由其他操作控制，本次命令未发送。请等待操作结束，或接管终端。" },
        .{ "RecordingNotClosed", "该录制仍在进行，当前工具只能读取已结束的历史录制。请改用当前会话的实时终端读取工具；无需为读取当前输出而关闭会话。" },
        .{ "ToolApprovalRejected", "用户拒绝了本次工具操作。" },
        .{ "ToolApprovalRequired", "本次操作尚未取得所需确认。" },
        .{ "ToolExecutionDenied", "当前权限策略禁止执行本次命令。" },
        .{ "IntegrationUnavailable", "当前终端缺少可用的 Shell 集成，无法确认命令输入与完成边界。" },
        .{ "InputConflict", "终端存在未完成的输入、粘贴或编辑状态，无法提交新的命令。" },
        .{ "requires_plan_change", "本次操作与当前运行方式不匹配，尚未执行。请让 AI 调整运行方式后重试。" },
        .{ "CancelledBeforeDispatch", "操作在派发前取消，命令未发送。" },
        .{ "ToolNotInRequest", "AI 请求的工具当前不可用，本次操作未执行。" },
        .{ "InvalidArguments", "工具参数不符合要求，本次操作未执行。" },
        .{ "InvalidToolArguments", "AI 提供的工具参数不完整或格式错误，本次操作未执行。" },
    };
    inline for (mappings) |entry| if (std.mem.eql(u8, code, entry[0])) return entry[1];
    return "工具请求未能完成，请查看下方原始错误与调用参数。";
}

// Host blocks can hold JSON as structured/text strings, and stringify of the
// native union produces a structured key. Keep the exact body below as well.
fn errorCode(a: std.mem.Allocator, value: std.json.Value, depth: u8) ?[]const u8 {
    if (depth > 8) return null;
    switch (value) {
        .object => |object| {
            if (object.get("error_code")) |code| if (code == .string) return code.string;
            for ([_][]const u8{ "content", "structured", "text" }) |key| if (object.get(key)) |child| {
                if (errorCode(a, child, depth + 1)) |code| return code;
            };
        },
        .array => |array| for (array.items) |child| {
            if (errorCode(a, child, depth + 1)) |code| return code;
        },
        .string => |text| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return null;
            return errorCode(a, parsed, depth + 1);
        },
        else => {},
    }
    return null;
}

pub fn describe(a: std.mem.Allocator, step: events.Step) !Description {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const raw = std.mem.trim(u8, step.detail, " \t\r\n");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, raw, .{}) catch null;
    const code = if (parsed) |value| errorCode(scratch, value, 0) orelse "ToolRequestFailed" else if (raw.len > 0 and std.mem.indexOfAny(u8, raw, " \t\r\n{[") == null) raw else "ToolRequestFailed";
    const status = if (step.phase == .cancelled) "已取消 · 未执行" else if (std.mem.eql(u8, code, "ToolApprovalRejected")) "用户已拒绝 · 未执行" else "请求失败 · 未执行";
    const summary = try std.fmt.allocPrint(a, "{s} · {s}", .{ status, code });
    errdefer a.free(summary);
    var name_buffer: [64]u8 = undefined;
    const name = @import("plugin_tools.zig").decodeName(&name_buffer, step.name) catch step.name;
    const detail = try std.fmt.allocPrint(a, "工具：{s}\n状态：{s}\n错误码：{s}\n原因：{s}\n\n调用参数 / 命令：\n{s}\n\n原始错误：\n{s}", .{ name, status, code, explanation(code), step.command, if (raw.len == 0) "未提供错误详情" else raw });
    return .{ .summary = summary, .detail = detail };
}

test "AI step failure retains nested host errors arguments and readable causes" {
    const a = std.testing.allocator;
    var step: events.Step = .{ .call_id = @constCast("one"), .name = @constCast("host.run_in_terminal"), .command = @constCast("{\"command\":\"pwd\"}"), .detail = @constCast("{\"status\":\"rejected\",\"content\":[{\"structured\":\"{\\\"error_code\\\":\\\"ShellPromptNotObserved\\\"}\"}]}"), .phase = .rejected, .started_ms = 1 };
    const value = try describe(a, step);
    defer value.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, value.summary, "ShellPromptNotObserved") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.summary, "用户已拒绝") == null);
    try std.testing.expect(std.mem.indexOf(u8, value.detail, "内层 Shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.detail, step.command) != null);
    try std.testing.expect(std.mem.indexOf(u8, value.detail, step.detail) != null);
    step.detail = @constCast("RecordingNotClosed");
    const other = try describe(a, step);
    defer other.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, other.detail, "实时终端读取工具") != null);
}
