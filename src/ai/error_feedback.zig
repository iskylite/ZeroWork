const std = @import("std");
const error_model = @import("error.zig");

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
    if (budgetFailureMessage(err)) |message| return message;
    if (http_status != 0) return diagnostic;
    return switch (err) {
        error.ToolOutcomeUnknown => "远端写入结果待核实，请先核查原目标",
        error.Timeout => "模型长时间未返回新内容，已保留收到的答复和附件",
        error.RequestRejected, error.RateLimited => "服务暂不可用或请求受限，请在冷却结束后重试",
        error.MissingApiKey, error.ProviderFailure => "服务请求失败，请检查 AI 设置",
        else => diagnostic,
    };
}

test "AI recovery distinguishes retained tool capacity from transport failure and keeps diagnostic codes" {
    const message = recoveryReason(error.ToolResultStoreCapacity, "请求失败 · ToolResultStoreCapacity", 0);
    try std.testing.expect(std.mem.indexOf(u8, message, "工具结果缓存") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "不会重放") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "连接") == null);
    try std.testing.expectEqualStrings("请求失败 · StreamCallbackFailed", recoveryReason(error.StreamCallbackFailed, "请求失败 · StreamCallbackFailed", 0));
    try std.testing.expectEqualStrings("HTTP 422 · 服务端拒绝请求参数", recoveryReason(error.ProviderFailure, "HTTP 422 · 服务端拒绝请求参数", 422));
    try std.testing.expectEqualStrings("远端写入结果待核实，请先核查原目标", recoveryReason(error.ToolOutcomeUnknown, "请求失败 · ToolOutcomeUnknown", 0));
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
