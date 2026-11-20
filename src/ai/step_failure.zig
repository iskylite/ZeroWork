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
        .{ "not_dispatched_due_to_new_input", "收到新的引导消息，已跳过旧计划中的本次调用，工具未执行。" },
        .{ "ShellContextExitedWithoutCompletion", "该 Shell 已返回父层，但本条命令没有收到完整结束事件，结果仍待核实。请在原终端查看结果；不要自动重发。" },
        .{ "ShellContextRequired", "命令未发送。请让 AI 重新读取同一终端，确认仍是原目标内层 Shell，再使用读到的 Shell 标识与版本提交。" },
        .{ "ShellContextChanged", "当前 Shell 层级已经变化，本次命令未发送。请重新读取当前 Shell 状态后再执行，避免命令落到错误的主机或用户环境。" },
        .{ "ShellContextLimit", "本次终端已达到可保留的 Shell 实例上限。请结束不再需要的会话，或建立新的终端会话。" },
        .{ "UnsupportedShell", "当前 Shell 暂不支持原地接入。请手动进入 bash 或 zsh，停在空提示符后执行 @shell attach。" },
        .{ "UnsupportedMultiplexer", "当前处于 tmux/screen 环境，暂不支持层级接入。请在普通 SSH、su、bash 或容器交互 Shell 中使用 @shell attach。" },
        .{ "ShellHooksConflict", "当前 Shell 已有不兼容的命令事件钩子，接入未完成。可进入干净的 bash --noprofile --norc 或 zsh -f，再执行 @shell attach；原会话保持可用。" },
        .{ "ShellAttachUnconfirmed", "尚未收到当前 Shell 的接入回执。请确认已进入 bash/zsh 的空提示符，再执行 @shell attach；不要在密码输入或前台程序中执行。" },
        .{ "ShellAttachmentStale", "读取终端后又出现了新的输入或输出，本次接入未开始。请重新读取当前终端和会话状态，确认仍是空 Shell 提示符后再申请接入。" },
        .{ "ShellIntegrationPending", "正在加载当前 Shell 的会话内集成，请等待接入结束后再执行命令。" },
        .{ "ReconnectConnectionLost", "重连建立的连接已再次断开，终端命令无法继续执行。" },
        .{ "ReconnectSuperseded", "此重连回执对应的会话代次已被后续代次取代。请查询当前会话状态。" },
        .{ "ReconnectPtyNotReady", "SSH 已连接，终端尚未就绪。可用同一个操作引用继续等待。" },
        .{ "ReconnectPtyUnsupported", "SSH 已连接，当前终端不支持交互式命令执行。" },
        .{ "ReconnectWaitTimedOut", "SSH 重连仍在进行。可用同一个操作引用继续等待。" },
        .{ "ReconnectTargetChanged", "原命令的目标会话已断线，本次调用不能将该命令改发给其他成员。" },
        .{ "ReconnectTargetUnavailable", "目标成员已断线或重连尚未就绪，命令未发送。" },
        .{ "SshHandshakeReceiveFailed", "SSH 握手期间未收到预期的响应，连接未建立。" },
        .{ "ShellPromptNotObserved", "尚未确认当前 Shell 已准备好接收命令。通过 SSH、su 或容器进入的内层 Shell 可能需要重新接入；请确认处于 Bash/Zsh 的空提示符后输入 @shell attach。不要在密码输入或前台程序中执行；结果不明的命令请先核实，不要重发。" },
        .{ "TerminalBusy", "终端正在由其他操作控制，本次命令未发送。请等待操作结束，或接管终端。" },
        .{ "RecordingNotClosed", "该录制仍在进行，当前工具只能读取已结束的历史录制。请改用当前会话的实时终端读取工具；无需为读取当前输出而关闭会话。" },
        .{ "RecordingExecutionCapacity", "录制执行记录已满，本条命令未发送。查询正在运行的命令时，使用原执行引用读取进度。" },
        .{ "SessionClosed", "原终端连接已结束，后续进度待核实。" },
        .{ "SessionReconnected", "原终端连接已被替换，后续进度待核实。" },
        .{ "ToolApprovalRejected", "用户拒绝了本次工具操作。" },
        .{ "ToolApprovalRequired", "本次操作尚未取得所需确认。" },
        .{ "BoostChildrenPending", "仍有子任务未结束，收齐交付后再提交终验。" },
        .{ "BoostAlreadyVerified", "本轮已提交终验，请查看结果。" },
        .{ "BoostRoundLimit", "已达到轮次上限，请进入终验。" },
        .{ "ChallengeReportPending", "前序任务尚未成功交付，复审未开始。" },
        .{ "InvalidVerification", "请逐项填写原始要求、检查结果和依据。" },
        .{ "ChildAwaitingUser", "子任务正在等待用户处理，请保留子任务并等待用户决定。" },
        .{ "TaskAlreadyFinished", "这次任务已经结束，无法继续执行。" },
        .{ "ToolApprovalChanged", "操作条件已变化，原确认已失效。该操作尚未执行。" },
        .{ "ScopeChanged", "原来的操作目标或授权范围已变化，该操作尚未执行。请检查当前范围后重新规划这一步。" },
        .{ "StaleToolAuthority", "目标终端或工具能力已变化，该操作尚未执行。请刷新目标后重新规划这一步。" },
        .{ "AssistantOwnerChanged", "对话的执行目标已变化，该操作尚未执行。请按当前会话重新规划这一步。" },
        .{ "TargetOutsideAssistant", "该终端已不在当前任务范围内，该操作尚未执行。" },
        .{ "WorkspaceChanged", "工作目录已变化，该操作尚未执行。请按当前目录重新规划这一步。" },
        .{ "TargetNotAuthorized", "本次调用的目标或任务授权未通过校验。请重新读取当前会话与授权范围后再执行。" },
        .{ "ToolExecutionDenied", "当前权限策略禁止执行本次命令。" },
        .{ "IntegrationUnavailable", "当前终端缺少可用的 Shell 集成，无法确认命令输入与完成边界。" },
        .{ "InputConflict", "命令未发送。请检查同一终端的输入状态，等待队列处理完成或请用户处理草稿，再决定是否提交；不要原样重试。" },
        .{ "TerminalInputConflictChanged", "命令未发送。确认期间终端、Shell 或暂存输入已变化，未清除内容。请重新查看同一终端后再决定。" },
        .{ "requires_plan_change", "本次操作与当前运行方式不匹配，尚未执行。请让 AI 调整运行方式后重试。" },
        .{ "CancelledBeforeDispatch", "操作在派发前取消，命令未发送。" },
        .{ "ToolNotInRequest", "AI 请求的工具当前不可用，本次操作未执行。" },
        .{ "InvalidArguments", "工具参数不符合要求，本次操作未执行。" },
        .{ "InvalidParent", "无法进入目标文件的父目录，请核对实际执行的主机和路径。" },
        .{ "SshFileAbsolutePathRequired", "当前终端位于内层 Shell 或正在切换，请使用 SSH 连接主机上的绝对路径。" },
        .{ "LocalFileAuthorityNotGranted", "子任务没有获得可用的 Mac 文件权限。请指定已授权的 Local 或 SSH 工作区终端，或关闭该子任务的文件权限。" },
        .{ "InheritanceScopeProjectionRequired", "子任务未派发。无法把完整的父会话历史授予所选目标；如果任务不需要父会话历史，请用 context_mode=independent 并只提供必要材料，不要扩大目标授权。" },
        .{ "InvalidInheritanceSnapshot", "子任务未派发。当前没有可用的父会话历史快照；不需要历史时请改为独立上下文并提供必要材料。" },
        .{ "ChildTaskLimit", "已达到子任务数量上限，本次未派发；请等待现有任务结束后再试。" },
        .{ "ChildRequestConflict", "请求标识已属于不同的子任务内容。本次未派发；请核对原任务和当前请求。" },
        .{ "ChildNeedsVerification", "本次子任务未派发。先核实原任务的未知效果，不要直接重跑。" },
        .{ "EarlierToolOutcomeUnknown", "前一次工具调用的结果待核实。请先查询原调用的状态，不要自动重发。" },
        .{ "InvalidSearchPattern", "搜索词必须是有效的单行文本，且不超过 256 个 UTF-8 字节。" },
        .{ "InvalidToolArguments", "AI 提供的工具参数不完整或格式错误，本次操作未执行。" },
    };
    inline for (mappings) |entry| if (std.mem.eql(u8, code, entry[0])) return entry[1];
    return "工具请求未能完成，请查看下方原始错误与调用参数。";
}

// Host blocks can hold JSON as structured/text strings, and stringify of the
// native union produces a structured key. Keep the exact body below as well.
fn safeErrorCode(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn errorCode(a: std.mem.Allocator, value: std.json.Value, depth: u8) ?[]const u8 {
    if (depth > 8) return null;
    switch (value) {
        .object => |object| {
            if (object.get("error_code")) |code| if (code == .string and safeErrorCode(code.string)) return code.string;
            for ([_][]const u8{ "targets", "content", "structured", "text" }) |key| if (object.get(key)) |child| {
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

fn argumentIssue(a: std.mem.Allocator, value: std.json.Value, depth: u8) ?std.json.Value {
    if (depth > 8) return null;
    switch (value) {
        .object => |object| {
            if (object.get("argument_issue")) |issue| return issue;
            for ([_][]const u8{ "targets", "content", "structured", "text" }) |key| if (object.get(key)) |child| {
                if (argumentIssue(a, child, depth + 1)) |issue| return issue;
            };
        },
        .array => |array| for (array.items) |child| {
            if (argumentIssue(a, child, depth + 1)) |issue| return issue;
        },
        .string => |raw| {
            const nested = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return null;
            return argumentIssue(a, nested, depth + 1);
        },
        else => {},
    }
    return null;
}

fn argumentExplanation(a: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    const issue = argumentIssue(a, value, 0) orelse return null;
    if (issue != .object) return null;
    const rule = issue.object.get("rule") orelse return null;
    if (rule != .string) return null;
    const field = if (issue.object.get("field")) |name| (if (name == .string) name.string else "调用参数") else "调用参数";
    if (std.mem.eql(u8, rule.string, "jsonSyntax")) return "工具参数不是有效的 JSON。请用 JSON 对象传参；本次操作未执行。";
    if (std.mem.eql(u8, rule.string, "singleLine")) return try std.fmt.allocPrint(a, "{s} 只能是一行文本，本次操作未执行。", .{field});
    if (std.mem.eql(u8, rule.string, "type")) if (issue.object.get("expected")) |expected| {
        if (expected == .string and std.mem.eql(u8, expected.string, "object")) return "工具参数应为 JSON 对象，而不是一个字符串或路径；本次操作未执行。";
    };
    if (std.mem.eql(u8, rule.string, "required")) return try std.fmt.allocPrint(a, "缺少必填字段 {s}，本次操作未执行。", .{field});
    if (std.mem.eql(u8, rule.string, "additionalProperties")) return try std.fmt.allocPrint(a, "工具不接受字段 {s}，本次操作未执行。", .{field});
    const constraints = .{
        .{ "type", "应为 JSON 类型" },
        .{ "enum", "应从以下值中选择" },
        .{ "minimum", "最小为" },
        .{ "maximum", "最大为" },
        .{ "minLength", "最少字符数为" },
        .{ "maxLength", "最多字符数为" },
        .{ "maxBytes", "最多 UTF-8 字节数为" },
        .{ "minItems", "最少条目数为" },
        .{ "maxItems", "最多条目数为" },
    };
    const expected = issue.object.get("expected") orelse return null;
    inline for (constraints) |constraint| {
        if (std.mem.eql(u8, rule.string, constraint[0])) {
            const limit = try std.json.Stringify.valueAlloc(a, expected, .{});
            return try std.fmt.allocPrint(a, "{s} {s} {s}，本次操作未执行。", .{ field, constraint[1], limit });
        }
    }
    return null;
}

fn childAuthorityExplanation(a: std.mem.Allocator, value: std.json.Value, depth: u8) ?[]const u8 {
    if (depth > 8) return null;
    switch (value) {
        .object => |object| {
            if (object.get("details")) |details| if (details == .object) if (details.object.get("reason")) |reason| if (reason == .string) {
                if (std.mem.eql(u8, reason.string, "missing_workspace_target")) return "这次委派未启动：要让子任务访问 Mac 文件，请在 session_refs 选一个已授权的 Local 或 SSH 工作区终端；如果子任务只处理已提供的材料，可以关闭文件权限。";
                if (std.mem.eql(u8, reason.string, "parent_file_authority")) return "这次委派未启动：子任务请求的 Mac 文件权限超过了当前任务拥有的权限。请选择已有权限，或改为不访问文件。";
            };
            for ([_][]const u8{ "content", "structured", "text" }) |key| if (object.get(key)) |child| {
                if (childAuthorityExplanation(a, child, depth + 1)) |message| return message;
            };
        },
        .array => |array| for (array.items) |child| {
            if (childAuthorityExplanation(a, child, depth + 1)) |message| return message;
        },
        .string => |raw| {
            const nested = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return null;
            return childAuthorityExplanation(a, nested, depth + 1);
        },
        else => {},
    }
    return null;
}

fn effectUnknown(value: std.json.Value, depth: u8) bool {
    if (depth > 8 or value != .object) return false;
    const status = value.object.get("status") orelse .null;
    if (status == .string and std.mem.eql(u8, status.string, "outcome_unknown")) return true;
    const unknown = value.object.get("remote_effect_unknown") orelse .null;
    if (unknown == .bool and unknown.bool) return true;
    if (value.object.get("receipt")) |receipt| if (effectUnknown(receipt, depth + 1)) return true;
    if (value.object.get("targets")) |targets| if (targets == .array) {
        for (targets.array.items) |target| if (effectUnknown(target, depth + 1)) return true;
    };
    return false;
}

pub fn describe(a: std.mem.Allocator, step: events.Step) !Description {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const raw = std.mem.trim(u8, step.detail, " \t\r\n");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, raw, .{}) catch null;
    const code = if (parsed) |value| errorCode(scratch, value, 0) orelse "ToolRequestFailed" else if (safeErrorCode(raw)) raw else "ToolRequestFailed";
    var name_buffer: [64]u8 = undefined;
    const name = @import("plugin_tools.zig").decodeName(&name_buffer, step.name) catch step.name;
    const reconnect_failed = if (parsed) |value| reconnectFailure(scratch, value, name) else false;
    const is_unknown = if (parsed) |value| effectUnknown(value, 0) else false;
    const status = if (is_unknown) "执行结果待核实" else if (std.mem.eql(u8, code, "not_dispatched_due_to_new_input")) "因新消息跳过 · 未执行" else if (step.phase == .cancelled) "已取消 · 未执行" else if (std.mem.eql(u8, code, "ToolApprovalRejected")) "用户已拒绝 · 未执行" else if (std.mem.eql(u8, code, "ReconnectPtyNotReady")) "SSH 已连接 · 终端尚未就绪" else if (std.mem.eql(u8, code, "ReconnectPtyUnsupported")) "SSH 已连接 · 终端不支持交互执行" else if (std.mem.eql(u8, code, "ReconnectWaitTimedOut")) "等待超时 · SSH 正在重连" else if (std.mem.eql(u8, code, "ReconnectSuperseded")) "重连回执已被取代" else if (reconnect_failed) "SSH 重连失败" else if (step.phase == .rejected) "请求未执行" else "工具调用失败";
    const summary = if (std.mem.eql(u8, code, "not_dispatched_due_to_new_input")) try a.dupe(u8, status) else try std.fmt.allocPrint(a, "{s} · {s}", .{ status, code });
    errdefer a.free(summary);
    const argument_explanation = if (parsed) |value| try argumentExplanation(scratch, value) else null;
    const child_explanation = if (std.mem.eql(u8, code, "LocalFileAuthorityNotGranted")) if (parsed) |value| childAuthorityExplanation(scratch, value, 0) else null else null;
    const detail = try std.fmt.allocPrint(a, "工具：{s}\n状态：{s}\n错误码：{s}\n原因：{s}", .{ name, status, code, if (is_unknown) "无法确认本次工具是否已产生影响。请先查询原操作的状态，不要重新发起。" else argument_explanation orelse child_explanation orelse explanation(code) });
    return .{ .summary = summary, .detail = detail };
}

fn reconnectFailure(a: std.mem.Allocator, value: std.json.Value, name: []const u8) bool {
    if (!std.mem.eql(u8, name, "host.wait_session_ready") and !std.mem.eql(u8, name, "host.reconnect_session")) return false;
    const content = if (value == .object) value.object.get("content") orelse return false else return false;
    if (content != .array or content.array.items.len != 1) return false;
    const block = content.array.items[0];
    const body = if (block == .object) block.object.get("structured") orelse return false else return false;
    if (body != .string) return false;
    const receipt = std.json.parseFromSliceLeaky(struct { state: []const u8, previous_session_ref: []const u8 }, a, body.string, .{ .ignore_unknown_fields = true }) catch return false;
    return std.mem.eql(u8, receipt.state, "failed");
}

test "tool diagnostics AI step failure displays nested error and omits raw arguments by default" {
    const a = std.testing.allocator;
    var step: events.Step = .{ .call_id = @constCast("one"), .name = @constCast("host.run_in_terminal"), .command = @constCast("{\"command\":\"pwd\"}"), .detail = @constCast("{\"status\":\"rejected\",\"content\":[{\"structured\":\"{\\\"error_code\\\":\\\"ShellPromptNotObserved\\\"}\"}]}"), .phase = .rejected, .started_ms = 1 };
    const value = try describe(a, step);
    defer value.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, value.summary, "ShellPromptNotObserved") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.summary, "用户已拒绝") == null);
    try std.testing.expect(std.mem.indexOf(u8, value.detail, "内层 Shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.detail, step.command) == null);
    try std.testing.expect(std.mem.indexOf(u8, value.detail, step.detail) == null);
    step.detail = @constCast("RecordingNotClosed");
    const other = try describe(a, step);
    defer other.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, other.detail, "实时终端读取工具") != null);
}

test "tool diagnostics AI step failure reads routed target receipts without exposing the original payload" {
    const a = std.testing.allocator;
    const raw = "{\"targets\":[{\"status\":\"cancelled_unsent\",\"content\":[{\"type\":\"structured\",\"text\":\"{\\\"error_code\\\":\\\"requires_plan_change\\\",\\\"next_tool\\\":\\\"host__run_uin_uterminal\\\",\\\"side_effect_started\\\":false}\"}]}]}";
    const value = try describe(a, .{ .call_id = @constCast("routed"), .name = @constCast("run_command"), .command = @constCast("pwd"), .detail = @constCast(raw), .phase = .cancelled, .started_ms = 1 });
    defer value.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, value.summary, "requires_plan_change") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.summary, "未执行") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.detail, "运行方式不匹配") != null);
    try std.testing.expect(std.mem.indexOf(u8, value.detail, raw) == null);
    try std.testing.expect(std.mem.indexOf(u8, value.summary, "ToolRequestFailed") == null);
    try std.testing.expect(std.mem.indexOf(u8, explanation("TargetNotAuthorized"), "授权未通过校验") != null);
}

test "tool diagnostics steering skip has a readable nonfailure summary" {
    const a = std.testing.allocator;
    const raw = "{\"status\":\"rejected\",\"error_code\":\"not_dispatched_due_to_new_input\"}";
    const description = try describe(a, .{ .call_id = @constCast("skipped"), .name = @constCast("host.read_terminal"), .command = @constCast("{}"), .detail = @constCast(raw), .phase = .skipped, .started_ms = 1 });
    defer description.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, description.summary, "因新消息跳过 · 未执行"));
    try std.testing.expect(std.mem.indexOf(u8, description.detail, "收到新的引导消息") != null);
    try std.testing.expect(std.mem.indexOf(u8, description.detail, raw) == null);
}

test "tool diagnostics AI step failure does not misrepresent unknown effect or display arguments" {
    const a = std.testing.allocator;
    const description = try describe(a, .{ .call_id = @constCast("one"), .name = @constCast("host.agent_tasks"), .command = @constCast("sensitive"), .detail = @constCast("{\"status\":\"outcome_unknown\",\"error_code\":\"ChildStartupFailed\",\"secret\":\"sensitive\"}"), .phase = .failed, .started_ms = 1 });
    defer description.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, description.summary, "执行结果待核实") != null);
    try std.testing.expect(std.mem.indexOf(u8, description.detail, "不要重新发起") != null);
    try std.testing.expect(std.mem.indexOf(u8, description.detail, "未执行") == null);
    try std.testing.expect(std.mem.indexOf(u8, description.detail, "sensitive") == null);
}
