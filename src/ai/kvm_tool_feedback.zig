//! KVM result wording shared by tool responses and native result cards.
const std = @import("std");
const api = @import("plugin_tools.zig");

pub const Feedback = struct {
    label: []const u8,
    message: []const u8,
    next_step: []const u8,
};
const Code = enum {
    ObservationExpired,
    ObservationInvalidated,
    ObservationNotFound,
    FreshObservationRequired,
    HumanInputActive,
    RemoteInputUnavailable,
    StaleAutomationAuthority,
    StaleInputLease,
    InputDenied,
    AutomationStepBudgetExceeded,
    AutomationLeaseExpired,
    AutomationInterrupted,
    AutomationRunUnavailable,
    AutomationTaskActive,
    WindowNotFocused,
    WindowTransferPending,
    StaleHostContext,
    PluginWindowUnavailable,
    ContentHostClosed,
    UnknownContentOwner,
    RevocationQueueFull,
    ToolPermissionDenied,
    AutomationLeaseActive,
    AutomationBudgetExceeded,
    QueueFull,
    AutomationOperationInFlight,
    InputOutcomeUnknown,
    RemoteInputUnconfirmed,
    OperationConflict,
    OperationExpired,
    UnknownOperation,
    OwnerClosed,
    StaleBinding,
    StaleFrame,
    FrameUnavailable,
    FrameGeometryPending,
    ImageEncodingPending,
    OperationPending,
    PostActionFramePending,
    ObservationWaitTimedOut,
    FrameBudgetExceeded,
    FrameLeaseLimit,
    CoordinateOutOfBounds,
    InvalidRegion,
    InvalidOutputSize,
    InvalidObservationAge,
    ImageTooLarge,
    InvalidDrag,
    InvalidClick,
    InvalidWheel,
    UnsupportedKeysym,
    UnsupportedKey,
    UnsupportedText,
    InvalidTextLength,
    InvalidToolArguments,
    InputClockUnavailable,
};
fn f(label: []const u8, message: []const u8, next_step: []const u8) Feedback {
    return .{ .label = label, .message = message, .next_step = next_step };
}
pub fn failure(code: []const u8) ?Feedback {
    const value = std.meta.stringToEnum(Code, code) orelse return null;
    return switch (value) {
        .ObservationExpired => f("画面观察超时", "画面观察已超过有效期。", "请重新截图，依据当前画面和新的 observation_id 决定操作；不要重放过期动作。"),
        .ObservationInvalidated, .StaleFrame => f("画面观察已失效", "连接、控制状态或画面信息已变化，原观察不能继续使用。", "请检查当前连接与控制状态，重新截图后再决定操作。"),
        .ObservationNotFound => f("未找到画面观察", "指定的画面观察不存在或已被清除。", "请重新截图，使用本次返回的 observation_id。"),
        .FreshObservationRequired => f("需要重新截图", "上次操作后尚未取得可供下一次操作使用的新观察。", "请等待前次操作结束，再截图确认当前画面后决定下一步。"),
        .HumanInputActive => f("人工操作中", "人工输入通道正在使用，自动输入已被拦截。", "请等待人工操作结束；恢复自动操作前重新截图，不要自动重放输入。"),
        .RemoteInputUnavailable => f("远程输入不可用", "远程连接未就绪或尚未取得控制权。", "请检查连接并取得远程控制，重新截图后再决定操作。"),
        .StaleAutomationAuthority, .StaleInputLease, .InputDenied, .ToolPermissionDenied => f("自动操作授权已失效", "当前自动操作授权无效或已撤销。", "请通过正常授权流程取得当前授权，重新截图后再决定操作。"),
        .AutomationLeaseActive, .AutomationTaskActive => f("其他自动任务正在控制", "远程输入通道已由另一个自动任务占用。", "请等待该任务释放控制，或由用户明确接管；不要重复发送输入。"),
        .AutomationBudgetExceeded, .AutomationStepBudgetExceeded, .AutomationLeaseExpired => f("自动操作额度已用尽", "本次自动操作已达到次数或时长上限。", "请先检查已执行的操作；继续任务需通过正常流程取得新授权并重新截图。"),
        .AutomationInterrupted, .AutomationRunUnavailable => f("自动控制已中断", "当前任务的自动输入授权已结束或被接管。", "请检查前次操作与当前画面；继续任务需通过正常授权流程，不要自动重放输入。"),
        .WindowNotFocused => f("目标窗口未激活", "目标 KVM 窗口当前未激活，不能取得自动输入授权。", "请激活目标窗口并确认当前会话，再重新截图后决定操作。"),
        .WindowTransferPending => f("目标窗口正在转移", "目标会话正在窗口之间转移，暂时无法取得输入授权。", "请等待窗口转移完成，确认当前目标后重新截图。"),
        .StaleHostContext, .PluginWindowUnavailable, .ContentHostClosed, .UnknownContentOwner => f("目标会话不可用", "原会话或承载它的窗口已关闭、替换或不可用。", "请重新打开或选择目标会话，检查连接与授权后重新观察。"),
        .RevocationQueueFull => f("授权状态待释放", "待处理的授权释放记录已达到上限。", "请等待本地授权释放完成后再请求操作；不要重复发送输入。"),
        .QueueFull => f("输入队列已满", "当前没有可用的自动输入队列位置。", "请查询已有操作状态并等待队列释放，再重新观察；不要自动重放输入。"),
        .AutomationOperationInFlight, .OperationPending => f("前次输入尚未结束", "已有输入操作仍在排队或发送。", "请查询前次 operation_status，等待其结束后重新截图；不要发送或重放新的输入。"),
        .InputOutcomeUnknown, .RemoteInputUnconfirmed => f("前次输入结果待核实", "前次输入可能已到达远端，当前状态尚未确认。", "请核对前次操作回执与当前画面；必要时由用户接管，不要重放不确定的输入。"),
        .OperationConflict => f("操作标识冲突", "同一个操作标识已对应不同的输入内容。", "请核对原操作回执与请求内容；不要更换标识来重放原动作。"),
        .OperationExpired => f("操作标识已失效", "该操作标识已被消耗，不能作为新操作再次使用。", "请检查历史回执并重新观察；仅为依据当前状态决定的新动作创建新请求。"),
        .UnknownOperation => f("未找到操作记录", "指定的操作不在当前可查询记录中。", "请核对当前会话和 operation_id；记录缺失不能作为重放依据。"),
        .OwnerClosed => f("会话已关闭", "原 KVM 会话已经关闭。", "请先打开目标会话，待连接就绪后重新观察。"),
        .StaleBinding => f("会话连接已失效", "工具引用的会话连接已被替换或失效。", "请重新选择当前目标会话，检查连接和授权后重新观察。"),
        .FrameUnavailable => f("画面尚未就绪", "当前没有可用的完整远程画面。", "请等待视频连接与完整画面就绪，再请求截图；不要重放输入。"),
        .FrameGeometryPending => f("等待完整画面", "远程画面尺寸正在变化，完整的新画面尚未到达。", "请等待新尺寸的完整画面，再请求截图；不要重放输入。"),
        .ImageEncodingPending => f("截图准备中", "远程画面正在编码，尚未生成可返回的截图。", "请在本次截图等待期限内等待编码完成；不要发送输入。"),
        .PostActionFramePending => f("等待操作后画面", "前次输入之后的新画面尚未到达，暂时无法确认远端效果。", "请在有限期限内等待新画面并重新截图；不要重放前次输入。"),
        .ObservationWaitTimedOut => f("等待画面超时", "本次截图等待已结束，仍未取得符合要求的画面。", "请检查视频连接及前次操作状态；需要时发起新的截图请求，不要重放输入。"),
        .FrameBudgetExceeded, .FrameLeaseLimit => f("截图资源暂不可用", "截图所需的内存额度或画面读取名额不足。", "请等待现有截图任务释放资源后再请求截图；此问题不需要重新授权。"),
        .CoordinateOutOfBounds, .InvalidRegion => f("画面坐标超出范围", "输入坐标或截图区域超出了对应画面的边界。", "请按返回图片的实际尺寸检查并修正坐标或区域；不要重复原参数。"),
        .InvalidOutputSize, .ImageTooLarge => f("截图尺寸不合法", "请求的输出尺寸无效或超出了截图限制。", "请减小或修正截图尺寸后重新请求。"),
        .InvalidObservationAge => f("观察有效期参数不合法", "请求的观察有效期不在允许范围内。", "请将 max_age_ms 设为 1 至 15000 毫秒后重新请求。"),
        .UnsupportedKeysym, .UnsupportedKey => f("按键不受支持", "请求的按键编码不受当前远程输入支持。", "请检查 keysym，改用受支持的按键；不要重复原参数。"),
        .UnsupportedText, .InvalidTextLength => f("输入文本不受支持", "文本包含不支持的字符或长度超出限制。", "请使用 1 至 256 字节的可打印 US ASCII 文本；换行请使用独立按键操作。"),
        .InvalidDrag, .InvalidClick, .InvalidWheel, .InvalidToolArguments => f("调用参数不合法", "请求参数不符合工具允许的类型、范围或动作约束。", "请检查工具参数定义并修正请求；重新授权不能解决参数错误。"),
        .InputClockUnavailable => f("输入时钟不可用", "无法可靠校验输入有效期，本次输入已被拦截。", "请检查本地运行状态，待时钟恢复后重新观察；不要自动重放输入。"),
    };
}
fn matches(name: []const u8, id: []const u8) bool {
    if (std.mem.eql(u8, name, id)) return true;
    var buffer: [64]u8 = undefined;
    const decoded = api.decodeName(&buffer, name) catch return false;
    return std.mem.eql(u8, decoded, id);
}
pub fn isTool(name: []const u8) bool {
    return matches(name, "bmc_ikvm.screenshot") or isInput(name) or matches(name, "bmc_ikvm.operation_status");
}
pub fn isInput(name: []const u8) bool {
    return matches(name, "bmc_ikvm.keyboard") or matches(name, "bmc_ikvm.pointer");
}
pub fn isPending(code: []const u8) bool {
    return std.mem.eql(u8, code, "ImageEncodingPending") or std.mem.eql(u8, code, "OperationPending") or std.mem.eql(u8, code, "PostActionFramePending") or std.mem.eql(u8, code, "FrameGeometryPending") or std.mem.eql(u8, code, "FrameUnavailable");
}
pub fn fromError(a: std.mem.Allocator, name: []const u8, code: []const u8) !?Feedback {
    if (!isTool(name)) return null;
    var info = failure(code) orelse return null;
    info.label = try std.fmt.allocPrint(a, "{s}{s}", .{ info.label, if (isInput(name)) " · 未发送" else "" });
    return info;
}
pub fn project(a: std.mem.Allocator, name: []const u8, bytes: []const u8) !?Feedback {
    if (!isTool(name)) return null;
    const parsed = std.json.parseFromSlice(struct { error_code: ?[]const u8 = null, state: ?[]const u8 = null }, a, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer parsed.deinit();
    if (parsed.value.error_code) |code| return fromError(a, name, code);
    const state = parsed.value.state orelse return null;
    const info = if (std.mem.eql(u8, state, "queued"))
        f("输入已排队", "输入仅进入本地队列，尚不能确认已发送到远端。", "请查询 operation_status，等待已有输入结束，再重新截图确认效果。")
    else if (std.mem.eql(u8, state, "sent"))
        f("输入已发送 · 效果待确认", "输入包已发送，尚未确认远端界面是否产生预期变化。", "请重新截图确认远端效果；不要重复发送原输入。")
    else if (std.mem.eql(u8, state, "cancelled_unsent"))
        f("输入已取消 · 未发送", "输入在发送前已取消。", "请检查取消原因；继续操作前重新观察，不要自动重放。")
    else if (std.mem.eql(u8, state, "partial_unknown"))
        f("输入结果待核实", "部分输入可能已到达远端，不能确认完整操作结果。", "请核对操作回执并重新截图；必要时由用户接管，禁止重放不确定输入。")
    else
        return null;
    var result = info;
    result.label = try a.dupe(u8, info.label);
    return result;
}

/// Used only for a known failure before the generic dispatch boundary.
pub fn preflightBody(a: std.mem.Allocator, name: []const u8, code: []const u8, session_ids: []const u64) !?[]u8 {
    if (!isTool(name)) return null;
    const info = failure(code) orelse return null;
    return try std.json.Stringify.valueAlloc(a, .{ .status = "rejected", .state = "rejected", .error_code = code, .stage = "preflight", .session_ids = session_ids, .message = info.message, .dispatch = false, .image_generated = false, .remote_effect_verified = false, .side_effect_started = false, .remote_effect_unknown = false, .next_step = info.next_step, .automatic_action_replay_allowed = false }, .{});
}

/// Only the screenshot read may be retried. Once its bounded host wait ends,
/// publish a terminal result instead of leaving a final card in `waiting`.
pub fn finishWait(a: std.mem.Allocator, name: []const u8, result: *api.ToolResult, waited: bool) !void {
    if (!matches(name, "bmc_ikvm.screenshot") or result.observation_retry_ms == null) return;
    const Body = struct { error_code: []const u8 };
    const original = try std.json.parseFromSlice(Body, a, result.blocks[0].structured, .{ .ignore_unknown_fields = true });
    defer original.deinit();
    const code = if (waited) "ObservationWaitTimedOut" else original.value.error_code;
    const info = failure(code) orelse return error.InvalidToolResult;
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .error_code = code, .cause_code = if (waited) @as(?[]const u8, original.value.error_code) else null, .state = if (waited) "timed_out" else "failed", .message = info.message, .dispatch = false, .image_generated = false, .remote_effect_verified = false, .retry_read_only = true, .next_step = info.next_step, .automatic_action_replay_allowed = false }, .{});
    errdefer a.free(bytes);
    const blocks = try a.alloc(api.ContentBlock, 1);
    blocks[0] = .{ .structured = bytes };
    const receipt = result.receipt;
    result.deinit(a);
    result.* = .{ .status = .failed, .blocks = blocks, .receipt = receipt };
}

test "BMC AI feedback covers failure reasons and keeps parameter recovery distinct from authority recovery" {
    inline for (@typeInfo(Code).@"enum".field_names) |field| {
        const info = failure(field).?;
        try std.testing.expect(info.label.len > 0 and info.message.len > 0 and info.next_step.len > 0);
    }
    try std.testing.expect(std.mem.indexOf(u8, failure("CoordinateOutOfBounds").?.next_step, "修正坐标") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure("QueueFull").?.next_step, "等待队列") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure("InputOutcomeUnknown").?.next_step, "不要重放") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure("StaleAutomationAuthority").?.next_step, "授权流程") != null);
    try std.testing.expect(try project(std.testing.allocator, "other__tool", "{\"state\":\"sent\"}") == null);
}
