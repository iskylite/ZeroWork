const std = @import("std");
const error_model = @import("error.zig");

pub fn localFailureLabel(label: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, label, "JournalLimit")) return "本地聊天记录存储已达上限，暂时无法保存新内容；请先备份记录，再导出或整理历史会话";
    if (std.mem.eql(u8, label, "JournalConflict")) return "本地聊天记录文件已变化，已暂停写入；请重新打开应用后继续";
    if (std.mem.eql(u8, label, "TurnChanged")) return "当前回复轮次已结束或变化，消息仍在待处理列表中，请再次发送";
    if (std.mem.eql(u8, label, "SubmissionUnconfirmed")) return "上一条消息的发送结果待核对，已保留本次输入";
    if (std.mem.eql(u8, label, "ExplicitSkillNotFound")) return "未找到指定技能。请输入 /skill 技能名，在下一行填写任务。";
    if (std.mem.eql(u8, label, "ExplicitSkillDisabled")) return "指定技能已停用，请在 AI 设置中启用后重试。";
    if (std.mem.eql(u8, label, "ExplicitSkillUnavailable")) return "指定技能或版本在当前对话中不可用，请检查技能设置后重新选择。";
    if (std.mem.eql(u8, label, "ExplicitSkillReadFailed")) return "无法读取指定技能，请检查技能包或重新导入。";
    if (std.mem.eql(u8, label, "ExplicitSkillContextLimit")) return "当前模型窗口没有足够空间加载指定技能。";
    return null;
}

pub const Feedback = struct {
    info: ?error_model.Info = null,
    retry_available: bool = false,
    pub fn show(self: *Feedback, info: error_model.Info) void {
        self.info = info;
        self.retry_available = info.retryable or error_model.retryable(info.kind);
    }
    pub fn dismiss(self: *Feedback) void {
        self.info = null;
        self.retry_available = false;
    }
};

/// Local admission failures must not be presented as a connection/stream loss.
pub fn budgetFailureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ContextFixedOverhead => "工具定义、系统提示及当前输入等固定开销与回复预留已超过当前模型窗口，压缩对话无法解决；请检查模型窗口设置或更换更大窗口的模型，原始输入和附件已保留",
        error.InvalidContextWindow => "模型上下文窗口未知或无效，请在 AI 设置中填写服务商支持的窗口大小后重试；原始输入和附件已保留",
        error.ContextCompactionFailed => "上下文压缩失败，原始上下文、输入和附件已保留；已停止自动重试，可手动重试压缩或更换模型",
        error.UnknownImageBudget, error.InvalidImageTokenReservation => "图片预算配置无效，已保留答复和工具结果，请检查模型的图片预算设置",
        error.ToolContextBudget, error.ContextBudgetExceeded => "上下文已超过当前模型窗口（含图片的保守预留，非实际 Token 用量），已保留答复和工具结果，请压缩上下文或新建会话",
        error.ToolTranscriptLimit => "对话上下文已达保留上限，已完成工具不会重放，请新建会话继续",
        error.ToolResultStoreCapacity => "工具结果缓存已达上限，已完成调用不会重放，请新建 AI 会话继续",
        error.RequestTooLarge, error.ToolRequestTooLarge => "请求内容超过传输上限，已保留答复和工具结果，请减少附件或压缩上下文",
        else => null,
    };
}

/// Preserve the actual failure category. A local result-retention failure can
/// follow a successful remote action and must never be called a network loss.
pub fn recoveryReason(err: anyerror, diagnostic: []const u8, http_status: u16) []const u8 {
    if (localFailureLabel(@errorName(err))) |message| return message;
    if (budgetFailureMessage(err)) |message| return message;
    if (executionFailureMessage(err)) |message| return message;
    if (http_status != 0) return diagnostic;
    return switch (err) {
        error.Timeout => "模型长时间未返回新内容，已保留收到的答复和附件",
        error.ProviderMissingDone => "模型回复提前结束，请重试答复。",
        error.StreamCallbackFailed => "ZeroWork 处理模型回复时出错，请重试答复。",
        error.HtmlResponse, error.InvalidModelResponse => diagnostic,
        error.ResponseTooLarge => "模型返回的内容超过大小上限，请缩小问题范围后重试。",
        error.InsecureEndpoint => "模型服务地址需要使用 HTTPS，请检查 AI 设置。",
        error.UnsupportedThinking, error.UnsupportedEffort, error.UnsupportedToolProtocol, error.UnsupportedImageProtocol, error.ProviderProtocolMismatch => "当前服务与所选模型功能不兼容，请检查模型设置或更换模型。",
        error.InvalidToolDefinition, error.InvalidToolMessage, error.InvalidToolArguments, error.InvalidToolCall, error.MissingToolName, error.MissingToolCallId, error.ToolIdChanged, error.ToolNameChanged, error.DuplicateToolCall, error.ToolArgumentsTooLarge => "工具调用信息不完整或格式有误，本轮已中断。",
        error.UnknownHostName, error.ConnectionRefused, error.ConnectionResetByPeer, error.NetworkUnreachable, error.ConnectionTimedOut => "与模型服务通信时出错，请检查网络连接后重试。",
        error.RequestRejected, error.RateLimited => "服务暂不可用或请求受限，请在冷却结束后重试",
        error.ProviderFailure => "模型服务未能完成这次请求，请检查 AI 设置后重试。",
        else => @import("../ui/feedback_message.zig").knownMessage(@errorName(err)) orelse "本轮遇到未能识别的问题，请在对话中查看错误详情。",
    };
}

pub fn recoveryTitle(failure: ?anyerror) []const u8 {
    return switch (failure orelse return "请求失败") {
        error.ContextFixedOverhead => "模型窗口不足",
        error.Timeout, error.SharedTaskTimeout => "请求超时",
        error.AiPolicyChanged, error.AiGrantChanged, error.AiBindingChanged, error.ConversationEnded, error.ConversationEnding, error.ConversationNotFound, error.MissingAssistantOwner, error.TaskAuthorityUnavailable, error.ChildTaskAuthorityChanged, error.ToolResultScopeChanged, error.RecordingScopeChanged, error.ScopeChanged => "本轮已中断",
        else => "请求失败",
    };
}

fn executionFailureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.AiPolicyChanged => "ZeroWork 设置在运行期间发生变化，本轮已停止使用原设置执行。",
        error.AiGrantChanged => "本轮使用的工具授权已变更，需要按当前授权重新规划。",
        error.AiBindingChanged, error.BindingChanged, error.ToolOwnerChanged => "对话绑定的终端或会话组已变更，本轮无法继续使用原目标。",
        error.ConversationEnded, error.ConversationEnding => "这段 AI 对话已结束或正在关闭，本轮已停止。",
        error.ConversationNotFound => "找不到这次任务所属的 AI 对话，本轮已中断。",
        error.MissingAssistantOwner, error.GroupRemoved, error.StaleSession => "这次任务原来使用的终端或会话组已不可用，本轮已中断。",
        error.TaskAuthorityUnavailable => "ZeroWork 已找不到本轮的工具执行权限，本轮已中断。",
        error.ChildTaskAuthorityChanged, error.ParentBindingChanged, error.NoActiveParentTask => "子任务已无法沿用原来的会话或授权，本轮已中断。",
        error.ToolResultScopeChanged => "刚收到的工具结果与当前任务对不上，ZeroWork 停止了本轮。",
        error.RecordingScopeChanged => "ZeroWork 无法重新确认本轮可读取的终端记录，本轮已中断。",
        error.InvalidHostAuthority, error.InvalidBindingHandoff, error.StaleNotice, error.ScopeChanged => "ZeroWork 无法确认本轮仍可使用原来的操作目标或工具权限，已停止继续执行。",
        error.WorkspaceChanged => "本轮使用的工作目录已变更，请确认当前目录后重新发送。",
        error.ToolResultRevoked => "部分工具结果的读取权限已失效，包含这些结果的请求已中断。",
        error.ToolOutcomeUnknown => "部分工具执行结果待核实，已保留收到的内容",
        error.Cancelled, error.CancelledBeforeDispatch => "本轮已取消。",
        error.TransitionPending => "对话正在切换绑定，本轮暂时无法继续。",
        error.ContextUnavailable, error.ToolHostUnavailable, error.ToolScopeUnavailable => "ZeroWork 无法取得本轮所需的会话或工具，本轮已中断。",
        error.SharedTaskTimeout => "主任务和子任务已用完共用的运行时间，本轮已停止。",
        error.TaskAlreadyFinished => "这次任务已经结束，无法继续执行。",
        error.TaskPersistenceFailed => "ZeroWork 无法保存任务进度，本轮已中断。",
        error.ModelSlotQueueFull => "等待模型的任务太多，请稍后重试。",
        error.UpdateInProgress => "ZeroWork 正在准备更新，本轮无法继续。",
        else => null,
    };
}

test "AI journal failures and stale queued turns explain retained records" {
    try std.testing.expect(std.mem.indexOf(u8, localFailureLabel("JournalLimit").?, "本地聊天记录") != null);
    try std.testing.expect(std.mem.indexOf(u8, localFailureLabel("TurnChanged").?, "待处理列表") != null);
    try std.testing.expectEqualStrings(localFailureLabel("JournalConflict").?, recoveryReason(error.JournalConflict, "JournalConflict", 0));
    try std.testing.expect(localFailureLabel("Timeout") == null);
}

test "AI recovery distinguishes retained tool capacity from transport failure and keeps diagnostic codes" {
    const message = recoveryReason(error.ToolResultStoreCapacity, "请求失败 · ToolResultStoreCapacity", 0);
    try std.testing.expect(std.mem.indexOf(u8, message, "工具结果缓存") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "不会重放") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "连接") == null);
    try std.testing.expectEqualStrings("ZeroWork 处理模型回复时出错，请重试答复。", recoveryReason(error.StreamCallbackFailed, "请求失败 · StreamCallbackFailed", 0));
    try std.testing.expectEqualStrings("HTTP 422 · 服务端拒绝请求参数", recoveryReason(error.ProviderFailure, "HTTP 422 · 服务端拒绝请求参数", 422));
    try std.testing.expectEqualStrings("部分工具执行结果待核实，已保留收到的内容", recoveryReason(error.ToolOutcomeUnknown, "请求失败 · ToolOutcomeUnknown", 0));
}

test "AI recovery explains authority failures and reserves unknown codes for details" {
    try std.testing.expectEqualStrings("ZeroWork 设置在运行期间发生变化，本轮已停止使用原设置执行。", recoveryReason(error.AiPolicyChanged, "AiPolicyChanged", 0));
    try std.testing.expectEqualStrings("对话绑定的终端或会话组已变更，本轮无法继续使用原目标。", recoveryReason(error.AiBindingChanged, "AiBindingChanged", 0));
    try std.testing.expectEqualStrings("这段 AI 对话已结束或正在关闭，本轮已停止。", recoveryReason(error.ConversationEnded, "ConversationEnded", 0));
    try std.testing.expectEqualStrings("ZeroWork 无法确认本轮仍可使用原来的操作目标或工具权限，已停止继续执行。", recoveryReason(error.ScopeChanged, "ScopeChanged", 0));
    try std.testing.expectEqualStrings("本轮遇到未能识别的问题，请在对话中查看错误详情。", recoveryReason(error.FutureFailureCode, "FutureFailureCode", 0));
}

test "local image and context budget failures explain retained facts instead of claiming a stream loss" {
    for ([_]anyerror{ error.UnknownImageBudget, error.InvalidImageTokenReservation, error.ToolContextBudget, error.ContextBudgetExceeded, error.ToolTranscriptLimit, error.RequestTooLarge, error.ToolRequestTooLarge }) |err| {
        const message = budgetFailureMessage(err).?;
        try std.testing.expect(std.mem.indexOf(u8, message, "连接") == null);
        try std.testing.expect(std.mem.indexOf(u8, message, "保留") != null);
    }
    try std.testing.expect(budgetFailureMessage(error.Timeout) == null);
}
test "error feedback exposes retry only for retryable errors" {
    var f: Feedback = .{};
    f.show(.{ .kind = .network, .message = "offline" });
    try std.testing.expect(f.retry_available);
    f.show(.{ .kind = .provider_missing, .message = "configure provider" });
    try std.testing.expect(!f.retry_available);
}

test "AI context budget failures distinguish fixed overhead and missing model windows" {
    const overhead = budgetFailureMessage(error.ContextFixedOverhead).?;
    try std.testing.expect(std.mem.indexOf(u8, overhead, "压缩对话无法解决") != null);
    try std.testing.expect(std.mem.indexOf(u8, overhead, "压缩失败") == null);
    try std.testing.expect(std.mem.indexOf(u8, overhead, "新建会话") == null);
    try std.testing.expect(!@import("retry.zig").isRetryable(error.ContextFixedOverhead));
    try std.testing.expect(std.mem.indexOf(u8, budgetFailureMessage(error.InvalidContextWindow).?, "AI 设置") != null);
}
