//! Immutable user-facing facts extracted only from trusted host execution results.
//! Missing receipts stay missing; a successful observation never proves completion.
const std = @import("std");
const identity = @import("../host/identity.zig");
const terminal = @import("../host/terminal_execution.zig");
const host = @import("host_tools.zig");
const plugin = @import("plugin_tools.zig");

/// Model-only projection. The original Result remains in the ledger and UI
/// store; preserve outcome/recording/input facts while omitting dispatch internals.
pub fn modelContent(a: std.mem.Allocator, name: []const u8, text: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, name, "host.run_in_terminal") and !std.mem.eql(u8, name, "host.get_execution") and !std.mem.eql(u8, name, "host.wait_execution")) return text;
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return text;
    defer parsed.deinit();
    if (parsed.value != .object) return text;
    var root = parsed.value;
    const snapshot = root.object.getPtr("snapshot") orelse return text;
    if (snapshot.* != .object) return text;
    var compact: std.json.ObjectMap = .empty;
    defer compact.deinit(a);
    for ([_][]const u8{ "owner", "execution_id", "state", "revision", "submit_sent", "process", "completion_source", "elapsed_ms", "output_received", "interactive_execution", "input_ready", "input_wait", "input_receipt", "input_handed_off", "local_released", "remote_effect_unknown", "recording_id", "recording_settled", "recording_failed", "interval_saved", "output_scope", "output_attribution", "output_attribution_reason", "failure" }) |key| {
        if (snapshot.object.get(key)) |value| try compact.put(a, key, value);
    }
    var shell: std.json.ObjectMap = .empty;
    defer shell.deinit(a);
    if (snapshot.object.get("shell")) |original| if (original == .object) {
        for ([_][]const u8{ "id", "parent_id", "revision", "depth", "kind", "suspended", "prompt_ready", "reported_host", "reported_user" }) |key| if (original.object.get(key)) |value| {
            try shell.put(a, key, if (value == .string) .{ .string = std.mem.trimEnd(u8, value.string, "\x00") } else value);
        };
        try compact.put(a, "shell", .{ .object = shell });
    };
    const grant = snapshot.object.get("grant");
    try compact.put(a, "has_input_grant", .{ .bool = if (grant) |value| value != .null else false });
    snapshot.* = .{ .object = compact };
    return std.json.Stringify.valueAlloc(a, root, .{});
}

pub const ActionTarget = struct {
    conversation_id: identity.ConversationId,
    task_id: identity.TaskId,
    session: identity.SessionHandle,
    execution_id: identity.ExecutionId,
    pub fn reference(self: ActionTarget) [35]u8 {
        var result: [35]u8 = undefined;
        @memcpy(result[0..3], "x1:");
        @memcpy(result[3..], &std.fmt.bytesToHex(self.execution_id.bytes, .lower));
        return result;
    }
};
pub const Projection = struct {
    conversation_id: identity.ConversationId,
    task_id: identity.TaskId,
    call_status: plugin.Status,
    input_result: bool = false,
    input_receipt: ?terminal.InputReceipt = null,
    not_dispatched: bool = false,
    execution_id: ?identity.ExecutionId = null,
    source_revision: u64 = 0,
    target: ?identity.SessionHandle = null,
    target_label: []const u8 = "",
    command: ?[]const u8 = null,
    state: ?terminal.State = null,
    process: ?terminal.ProcessReceipt = null,
    completion_source: terminal.CompletionSource = .unknown,
    recording_id: ?identity.RecordingId = null,
    terminal_output: []const u8 = "",
    shell_framing_only: bool = false,
    output_available: bool = false,
    output_cursor: u64 = 0,
    output_error: ?[]const u8 = null,
    output_retained: bool = false,
    output_from_earlier: bool = false,
    output_gap: bool = false,
    output_truncated: bool = false,
    elapsed_ms: ?u64 = null,
    stop_requested: bool = false,
    input_handed_off: bool = false,
    has_input_grant: bool = false,
    local_released: bool = false,
    remote_effect_unknown: bool = false,
    recording_failed: bool = false,
    recording_settled: bool = false,
    output_scope: terminal.OutputScope = .exact,
    output_attribution: terminal.OutputAttribution = .unverified,
    output_attribution_reason: ?[]const u8 = null,
    interval_saved: bool = false,
    failure: ?[]const u8 = null,

    pub fn actionTarget(self: Projection) ?ActionTarget {
        if (!self.conversation_id.valid() or !self.task_id.valid()) return null;
        return .{ .conversation_id = self.conversation_id, .task_id = self.task_id, .session = self.target orelse return null, .execution_id = self.execution_id orelse return null };
    }
    pub fn active(self: Projection) bool {
        if (self.call_status != .succeeded or self.remote_effect_unknown) return false;
        if (self.process) |process| if (process.foreground_finished) return false;
        return switch (self.state orelse return false) {
            .preparing, .awaiting_start_boundary, .awaiting_accept, .awaiting_submit, .running => true,
            else => false,
        };
    }
    pub fn canStop(self: Projection) bool {
        return self.actionTarget() != null and self.active() and !self.stop_requested and !self.input_handed_off;
    }
    pub fn canTakeover(self: Projection) bool {
        return self.actionTarget() != null and self.active() and self.has_input_grant and !self.input_handed_off;
    }
    pub fn sealed(self: Projection) bool {
        const process = self.process orelse return false;
        return self.output_scope == .exact and self.state == .sealed and self.recording_settled and self.recording_id != null and !self.recording_failed and !self.remote_effect_unknown and process.foreground_finished and !process.background_jobs and !process.background_jobs_unknown;
    }
    pub fn intervalRecorded(self: Projection) bool {
        const process = self.process orelse return false;
        return self.output_scope == .session_interval and self.state == .interval_recorded and self.interval_saved and self.recording_settled and self.recording_id != null and !self.recording_failed and !self.remote_effect_unknown and process.foreground_finished;
    }
    pub fn attributionLabel(self: Projection) []const u8 {
        return switch (self.output_attribution) {
            .unverified => "输出归属未确认",
            .no_concurrent_owner_observed => "未观察到并发写入 · 输出归属未确认",
            .concurrent_observed => "观察到并发写入 · 输出可能混有其他程序内容",
        };
    }
    pub fn statusLabel(self: Projection) []const u8 {
        if (self.input_result) {
            if (self.call_status == .rejected) return "输入未提交 · 已拒绝";
            if (self.call_status == .cancelled_unsent) return "输入未提交 · 已取消";
            if (self.remote_effect_unknown or self.call_status == .outcome_unknown) return "输入结果待核实";
            if (self.call_status == .failed) return "输入提交失败";
            return switch ((self.input_receipt orelse return "输入状态待核实").stage) {
                .awaiting_host_secret => "等待安全输入",
                .queued => "输入已排队",
                .written => "输入已写入终端",
                .consumed => "输入已消费",
                .cancelled_unsent => "输入未提交 · 已取消",
                .outcome_unknown => "输入结果待核实",
            };
        }
        if (self.call_status == .rejected) return "未执行 · 已拒绝";
        if (self.call_status == .cancelled_unsent) return "未派发 · 已取消";
        if (self.remote_effect_unknown or self.state == .outcome_unknown or self.call_status == .outcome_unknown) return "结果待核实";
        if (self.not_dispatched) return "未执行 · 调用失败";
        if (self.stop_requested and self.active()) return "停止已请求 · 等待执行结果";
        if (self.input_handed_off and self.active()) return "用户已接管 · 命令继续运行";
        // A process receipt describes the command result independently of output
        // collection and recording. Saving a recording never proves execution.
        if (self.process) |process| if (process.foreground_finished) {
            if (process.signal != null or (process.exit_code != null and process.exit_code.? != 0)) return "命令执行失败";
            return if (process.exit_code == 0) "命令已结束" else "命令已结束 · 退出状态未知";
        };
        return switch (self.state orelse return if (self.call_status == .failed) "调用失败" else "执行状态待核实") {
            .unavailable => "执行不可用",
            .idle => "终端空闲",
            .preparing, .awaiting_start_boundary, .awaiting_accept => "准备执行",
            .awaiting_submit => "正在提交命令",
            .running => "运行中",
            .process_finished, .sealed, .interval_recorded, .recording_degraded => "执行状态待核实",
            .output_draining, .recording_sealing => "正在处理执行结果",
            .cancelled_unsent => "未派发 · 已取消",
            .handed_off => "输入权已交给用户",
            .outcome_unknown => "结果待核实",
        };
    }
    pub fn processLabel(self: Projection, buffer: []u8) !?[]const u8 {
        const process = self.process orelse return null;
        if (!process.foreground_finished) return null;
        if (process.signal) |signal| return try std.fmt.bufPrint(buffer, "结束信号 {d}", .{signal});
        if (process.exit_code) |code| return try std.fmt.bufPrint(buffer, "退出码 {d}", .{code});
        return "命令已结束 · 未提供退出码";
    }
    pub fn phase(self: Projection) @import("step_events.zig").Phase {
        if (self.call_status == .rejected) return .rejected;
        if (self.state == .cancelled_unsent or self.call_status == .cancelled_unsent) return .cancelled;
        if (self.active() or self.state == .handed_off) return .running;
        if (self.process) |process| {
            if (process.foreground_finished and process.exit_code == 0 and process.signal == null and !self.remote_effect_unknown) return .succeeded;
        }
        return .failed;
    }
    pub fn outputLabel(self: Projection) ?[]const u8 {
        if (self.input_result) return null;
        if (self.terminal_output.len != 0) {
            if (self.output_retained) return "以下是原执行已采集的输出，后续进度待核实。";
            if (self.output_error != null) return "本次未能读取新增内容，以下是此前采集的输出。";
            if (self.output_from_earlier) return "本次未返回新增内容，以下是此前采集的输出。";
            return null;
        }
        if (self.not_dispatched or self.state == .cancelled_unsent or self.call_status == .cancelled_unsent) return "命令未派发，没有执行输出。";
        if (self.output_retained) return "未保留可显示的输出，后续进度待核实。";
        if (self.output_gap or self.output_truncated) return "本次未返回可显示的输出，采集范围有缺失。";
        if (self.output_error != null or !self.output_available) return "未取得输出，无法确认命令是否产生了输出。";
        if (self.output_cursor != 0) return "这个位置之后暂无新增输出。";
        if (self.shell_framing_only) return "采集区间只有 Shell 控制信息，没有实际命令输出。";
        if (self.process) |process| if (process.foreground_finished and (self.sealed() or self.intervalRecorded())) return "本次采集区间没有输出。";
        if (self.active() or self.state == .handed_off) return "运行中，暂未采集到输出。";
        return "暂未采集到输出，采集是否完整待核实。";
    }
    pub fn outputWarning(self: Projection) ?[]const u8 {
        if (self.process) |process| if (process.background_jobs) return "检测到后台任务，前台命令结束后仍可能继续运行。";
        if (self.output_scope != .session_interval) return null;
        if (self.output_attribution == .concurrent_observed) return "检测到其他程序可能写入终端，输出可能包含其他程序的内容。";
        const reason = self.output_attribution_reason orelse return null;
        if (std.mem.eql(u8, reason, "BackgroundJobsObserved")) return "检测到后台任务，前台命令结束后仍可能继续运行。";
        if (std.mem.eql(u8, reason, "OutputObservationDeadline")) return "未能确认输出来源，请结合原终端核实结果。";
        if (std.mem.eql(u8, reason, "BackgroundJobsUnknown")) return "未能确认后台任务状态，请查看原终端。";
        // Generic PTY capability limits belong in details. In particular,
        // background_jobs_unknown alone is set for ordinary SSH executions.
        return null;
    }
    pub fn clone(self: Projection, allocator: std.mem.Allocator) !Projection {
        var copy = self;
        copy.target_label = try allocator.dupe(u8, self.target_label);
        copy.command = if (self.command) |text| try allocator.dupe(u8, text) else null;
        copy.terminal_output = try allocator.dupe(u8, self.terminal_output);
        copy.output_attribution_reason = if (self.output_attribution_reason) |text| try allocator.dupe(u8, text) else null;
        copy.failure = if (self.failure) |text| try allocator.dupe(u8, text) else null;
        copy.output_error = if (self.output_error) |text| try allocator.dupe(u8, text) else null;
        return copy;
    }
    pub fn retainedBytes(self: Projection) usize {
        return self.target_label.len + (if (self.command) |text| text.len else 0) + self.terminal_output.len + (if (self.output_attribution_reason) |text| text.len else 0) + (if (self.failure) |text| text.len else 0) + (if (self.output_error) |text| text.len else 0);
    }
};

pub fn isRun(name: []const u8) bool {
    var decoded: [64]u8 = undefined;
    const logical = plugin.decodeName(&decoded, name) catch name;
    return std.mem.eql(u8, logical, "host.run_in_terminal");
}
pub fn batchStatus(result: @import("tool_loop.zig").TargetResult) []const u8 {
    if (result.signal != null or (result.exit != null and result.exit.? != 0)) return "命令执行失败";
    if (result.exit == 0) return "命令已结束";
    if (result.remote_effect_unknown or !result.local_released) return "远端执行结果待核实";
    return switch (result.status) {
        .rejected, .skipped => "命令未派发",
        .timed_out => "调用超时 · 命令是否结束待核实",
        else => "未确认命令退出状态",
    };
}

pub fn batchOutputLabel(result: @import("tool_loop.zig").TargetResult) ?[]const u8 {
    if (result.stdout.len != 0 or result.stderr.len != 0) return null;
    if (result.truncated or result.retained_truncated or result.next_output_cursor != null) return "本次未返回可显示的输出，采集范围有缺失。";
    if (result.signal != null or result.exit != null) return "本次采集区间没有输出。";
    if (result.status == .rejected or result.status == .skipped) return "命令未派发，没有执行输出。";
    return "未取得输出，无法确认命令是否产生了输出。";
}

pub fn isInput(name: []const u8) bool {
    var decoded: [64]u8 = undefined;
    const logical = plugin.decodeName(&decoded, name) catch name;
    return std.mem.eql(u8, logical, "host.send_execution_input");
}
pub fn supports(name: []const u8) bool {
    var decoded: [64]u8 = undefined;
    const logical = plugin.decodeName(&decoded, name) catch name;
    for ([_][]const u8{ "host.run_in_terminal", "host.get_execution", "host.wait_execution", "host.stop_execution", "host.send_execution_input" }) |id| if (std.mem.eql(u8, logical, id)) return true;
    return false;
}
const Snapshot = struct {
    shell: struct {
        id: ?[32]u8 = null,
        kind: @FieldType(terminal.ShellContext, "kind") = .unknown,
    } = .{},
    output_received: ?u64 = null,
    owner: ?identity.SessionHandle = null,
    execution_id: ?identity.ExecutionId = null,
    state: ?[]const u8 = null,
    process: ?terminal.ProcessReceipt = null,
    completion_source: terminal.CompletionSource = .unknown,
    recording_id: ?[32]u8 = null,
    elapsed_ms: ?u64 = null,
    input_handed_off: bool = false,
    grant: ?struct { execution_id: ?identity.ExecutionId = null } = null,
    local_released: bool = false,
    remote_effect_unknown: bool = false,
    recording_failed: bool = false,
    recording_settled: bool = false,
    output_scope: terminal.OutputScope = .exact,
    output_attribution: terminal.OutputAttribution = .unverified,
    output_attribution_reason: ?[]const u8 = null,
    interval_saved: bool = false,
    failure: ?[]const u8 = null,
};
const Wire = struct {
    error_code: ?[]const u8 = null,
    state: ?[]const u8 = null,
    execution_ref: ?[]const u8 = null,
    execution_task_id: ?identity.TaskId = null,
    source_revision: u64 = 0,
    execution_id: ?identity.ExecutionId = null,
    snapshot: ?Snapshot = null,
    execution_receipt: ?std.json.Value = null,
    input_receipt: ?terminal.InputReceipt = null,
    recording_ref: ?[]const u8 = null,
    output: ?[]const u8 = null,
    output_available: bool = false,
    output_cursor: u64 = 0,
    output_error: ?[]const u8 = null,
    output_retained: bool = false,
    stop_requested: bool = false,
    gap: bool = false,
    truncated: bool = false,
};

// The SSH capture starts after the command-start OSC, so input echo before
// that boundary is already excluded. Only recognize the closing OSC and the
// exact default Zsh end-of-line marker. Control bytes can be command output too.
fn onlyShellFraming(output: []const u8, shell: @FieldType(Snapshot, "shell"), exit_code: u8) bool {
    const osc_start = std.mem.lastIndexOf(u8, output, "\x1b]") orelse return false;
    const suffix = output[osc_start + 2 ..];
    const terminator: usize = if (std.mem.endsWith(u8, suffix, "\x07")) 1 else if (std.mem.endsWith(u8, suffix, "\x1b\\")) 2 else return false;
    var parts = std.mem.splitScalar(u8, suffix[0 .. suffix.len - terminator], ';');
    const protocol = parts.first();
    if (!std.mem.eql(u8, protocol, "133") and !std.mem.eql(u8, protocol, "633")) return false;
    if (!std.mem.eql(u8, parts.next() orelse return false, "D")) return false;
    const reported = std.fmt.parseInt(u8, parts.next() orelse return false, 10) catch return false;
    if (reported != exit_code) return false;
    if (shell.id) |id| {
        const context = parts.next() orelse return false;
        if (!std.mem.startsWith(u8, context, "zw_ctx=") or !std.mem.eql(u8, context["zw_ctx=".len..], &id)) return false;
    }
    if (parts.next() != null) return false;
    if (osc_start == 0) return true;
    if (shell.kind != .zsh) return false;
    const before = output[0..osc_start];
    const prefix = "\x1b[1m\x1b[7m";
    const suffix_style = "\x1b[27m\x1b[1m\x1b[0m";
    if (!std.mem.startsWith(u8, before, prefix)) return false;
    const marker = before[prefix.len..];
    if (marker.len == 0 or (marker[0] != '%' and marker[0] != '#')) return false;
    if (!std.mem.startsWith(u8, marker[1..], suffix_style)) return false;
    const padding = marker[1 + suffix_style.len ..];
    const restore_column = "\r \r";
    if (padding.len <= restore_column.len or !std.mem.endsWith(u8, padding, restore_column)) return false;
    for (padding[0 .. padding.len - restore_column.len]) |byte| if (byte != ' ') return false;
    return true;
}

pub fn parse(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8, status: plugin.Status, receipt: host.Receipt, content: []const u8) !?Projection {
    if (!supports(name)) return null;
    var result: Projection = .{ .conversation_id = receipt.conversation_id, .task_id = receipt.task_id, .call_status = status, .input_result = isInput(name), .remote_effect_unknown = receipt.remote_effect_unknown };
    if (!result.input_result) {
        const args = std.json.parseFromSliceLeaky(struct { command: ?[]const u8 = null }, allocator, arguments, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
        if (args) |value| result.command = value.command;
    }
    const wire = std.json.parseFromSliceLeaky(Wire, allocator, content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return result;
    if (wire.execution_ref) |reference| if (std.mem.startsWith(u8, reference, "x1:")) {
        result.execution_id = identity.ExecutionId.parse(reference[3..]) catch null;
    };
    if (result.input_result) {
        // An input operation attests only its own receipt. It does not observe
        // process completion, terminal output, or current execution authority.
        result.input_receipt = wire.input_receipt;
        result.failure = wire.error_code;
        return result;
    }
    if (wire.snapshot) |snapshot| {
        if (snapshot.execution_id) |id| {
            if (result.execution_id) |ref_id| {
                if (!id.eql(ref_id)) result.execution_id = null;
            } else result.execution_id = id;
        }
        if (snapshot.owner) |owner| if (@backingInt(owner.session_id) != 0 and owner.generation != 0) {
            result.target = owner;
        };
        result.state = if (snapshot.state) |state| std.meta.stringToEnum(terminal.State, state) else null;
        result.process = snapshot.process;
        result.completion_source = snapshot.completion_source;
        result.elapsed_ms = snapshot.elapsed_ms;
        result.input_handed_off = snapshot.input_handed_off;
        result.has_input_grant = if (snapshot.grant) |grant| grant.execution_id != null and result.execution_id != null and grant.execution_id.?.eql(result.execution_id.?) else false;
        result.local_released = snapshot.local_released;
        result.remote_effect_unknown = result.remote_effect_unknown or snapshot.remote_effect_unknown;
        result.recording_failed = snapshot.recording_failed;
        result.recording_settled = snapshot.recording_settled;
        result.output_scope = snapshot.output_scope;
        result.output_attribution = snapshot.output_attribution;
        result.output_attribution_reason = snapshot.output_attribution_reason;
        result.interval_saved = snapshot.interval_saved;
        result.failure = snapshot.failure;
        if (snapshot.recording_id) |id| result.recording_id = identity.RecordingId.parse(&id) catch null;
        result.source_revision = wire.source_revision;
        if (result.execution_id != null) if (wire.execution_task_id) |task| {
            if (task.valid()) result.task_id = task;
        };
    } else if (wire.execution_receipt) |raw| recovered: {
        // Journal stages describe an operation outcome, not output ownership.
        // Only a validated durable receipt can restore these execution facts.
        const persisted = std.json.parseFromValueLeaky(terminal.PublicReceipt, allocator, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch break :recovered;
        persisted.validate() catch break :recovered;
        if (wire.execution_id) |id| if (!id.eql(persisted.execution_id)) {
            result.execution_id = null;
            break :recovered;
        };
        if (result.execution_id) |id| if (!id.eql(persisted.execution_id)) {
            result.execution_id = null;
            break :recovered;
        };
        result.execution_id = persisted.execution_id;
        result.process = persisted.process;
        result.completion_source = persisted.completion_source;
        result.state = if (persisted.interval_saved) .interval_recorded else if (persisted.sealed) .sealed else null;
        result.local_released = persisted.local_released;
        result.input_handed_off = persisted.input_handed_off;
        result.remote_effect_unknown = result.remote_effect_unknown or persisted.remote_effect_unknown;
        result.recording_failed = persisted.recording_failed;
        result.recording_settled = persisted.recording_settled;
        result.output_scope = persisted.output_scope;
        result.output_attribution = persisted.output_attribution;
        result.output_attribution_reason = persisted.output_attribution_reason;
        result.interval_saved = persisted.interval_saved;
        if (persisted.recording_id) |id| result.recording_id = identity.RecordingId.parse(&id) catch null;
        // PublicReceipt intentionally has no SessionHandle or current grant.
        // Missing target identity must keep all terminal controls unavailable.
    }
    if (result.state == null) if (wire.state) |state| {
        if (std.mem.eql(u8, state, "cancelled_unsent") or std.mem.eql(u8, state, "rejected")) result.state = .cancelled_unsent;
    };
    if (wire.recording_ref) |reference| {
        const id = identity.RecordingId.parse(reference) catch null;
        if (result.recording_id) |prior| {
            if (id == null or !prior.eql(id.?)) result.recording_id = null;
        } else result.recording_id = id;
    }
    if (result.failure == null) result.failure = wire.error_code;
    result.terminal_output = wire.output orelse "";
    result.output_available = wire.output_available;
    result.output_cursor = wire.output_cursor;
    result.output_error = wire.output_error;
    result.output_retained = wire.output_retained;
    result.output_gap = wire.gap;
    result.output_truncated = wire.truncated;
    result.stop_requested = wire.stop_requested;
    if (wire.snapshot) |snapshot| {
        if (result.completion_source == .shell_reported and result.intervalRecorded() and
            result.output_available and result.output_cursor == 0 and result.output_error == null and
            !result.output_retained and !result.output_gap and !result.output_truncated and
            snapshot.output_received == result.terminal_output.len)
        {
            if (result.process.?.exit_code) |code| {
                if (onlyShellFraming(result.terminal_output, snapshot.shell, code)) {
                    result.shell_framing_only = true;
                    result.terminal_output = "";
                }
            }
        }
    }
    return result;
}

/// The host loop can reject/cancel before a HostResult exists. Keep this a new
/// execution card, but never infer executable identities from model arguments.
pub fn parseFailure(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8, body: ?[]const u8, dispatched: bool) !?Projection {
    if (!supports(name)) return null;
    const ErrorBody = struct {
        conversation_id: identity.ConversationId = .{},
        task_id: identity.TaskId = .{},
        status: ?[]const u8 = null,
        error_code: ?[]const u8 = null,
        remote_effect_unknown: bool = false,
    };
    const source = if (body) |bytes| std.json.parseFromSliceLeaky(ErrorBody, allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch ErrorBody{} else ErrorBody{};
    const cancelled = source.error_code != null and std.mem.eql(u8, source.error_code.?, "CancelledBeforeDispatch");
    const status: plugin.Status = if (cancelled) .cancelled_unsent else if (source.status) |text| if (std.mem.eql(u8, text, "cancelled")) .cancelled_unsent else if (std.mem.eql(u8, text, "unknown")) .outcome_unknown else std.meta.stringToEnum(plugin.Status, text) orelse .failed else .failed;
    var result: Projection = .{ .conversation_id = source.conversation_id, .task_id = source.task_id, .call_status = status, .input_result = isInput(name), .not_dispatched = !dispatched, .remote_effect_unknown = source.remote_effect_unknown or status == .outcome_unknown, .failure = source.error_code };
    if (!result.input_result) {
        const args = std.json.parseFromSliceLeaky(struct { command: ?[]const u8 = null }, allocator, arguments, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
        if (args) |value| result.command = value.command;
    }
    return result;
}

pub fn fromStep(allocator: std.mem.Allocator, step: @import("step_events.zig").Step) !?Projection {
    if (!supports(step.name) or step.ended_ms == null or step.detail.len == 0) return null;
    const Envelope = struct {
        status: plugin.Status,
        receipt: host.Receipt,
        content: []const struct { structured: ?[]const u8 = null },
    };
    const value = std.json.parseFromSliceLeaky(Envelope, allocator, step.detail, .{ .ignore_unknown_fields = true }) catch {
        if (step.activity_started_ms != null or (step.phase != .rejected and step.phase != .failed)) return null;
        const failure = std.json.parseFromSliceLeaky(struct {
            side_effect_started: ?bool = null,
            error_code: ?[]const u8 = null,
        }, allocator, step.detail, .{ .ignore_unknown_fields = true }) catch return null;
        if (failure.side_effect_started != false or failure.error_code == null) return null;
        return parseFailure(allocator, step.name, step.command, step.detail, false);
    };
    if (value.content.len != 1) return null;
    const structured = value.content[0].structured orelse return null;
    return parse(allocator, step.name, step.command, value.status, value.receipt, structured);
}

test "SSH framing-only output requires a complete observed interval and preserves real output" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const receipt: host.Receipt = .{ .conversation_id = .generate(), .task_id = .generate(), .operation_id = 1, .binding_revision = 1 };
    const shell_id = "0123456789abcdef0123456789abcdef";
    const zsh_marker = "\x1b[1m\x1b[7m%\x1b[27m\x1b[1m\x1b[0m  \r \r";
    const closing = "\x1b]133;D;1;zw_ctx=" ++ shell_id ++ "\x07";
    const silent = zsh_marker ++ closing;
    const WireCase = struct {
        output: []const u8 = silent,
        output_cursor: u64 = 0,
        gap: bool = false,
        truncated: bool = false,
        retained: bool = false,
        count: ?u64 = null,
        framed: bool = false,
    };
    const cases = [_]WireCase{
        .{ .framed = true },
        .{ .output = closing, .framed = true },
        .{ .output = "\x1b]133;D;1;zw_ctx=" ++ shell_id ++ "\x1b\\", .framed = true },
        .{ .output = "%" ++ silent },
        .{ .output = "\n" ++ silent },
        .{ .output = "\x1b[2J" ++ silent },
        .{ .output = zsh_marker ++ "\x1b]133;D;0;zw_ctx=" ++ shell_id ++ "\x07" },
        .{ .output = zsh_marker ++ "\x1b]133;D;1;zw_ctx=ffffffffffffffffffffffffffffffff\x07" },
        .{ .output_cursor = 1 },
        .{ .gap = true },
        .{ .truncated = true },
        .{ .retained = true },
        .{ .count = silent.len + 1 },
    };
    for (cases) |case| {
        const content = try std.json.Stringify.valueAlloc(arena.allocator(), .{
            .snapshot = .{
                .completion_source = .shell_reported,
                .state = .interval_recorded,
                .output_scope = .session_interval,
                .interval_saved = true,
                .recording_settled = true,
                .recording_id = shell_id,
                .process = .{ .foreground_finished = true, .exit_code = 1 },
                .shell = .{ .kind = .zsh, .id = shell_id },
                .output_received = case.count orelse case.output.len,
            },
            .output = case.output,
            .output_cursor = case.output_cursor,
            .gap = case.gap,
            .truncated = case.truncated,
            .output_retained = case.retained,
            .output_available = true,
        }, .{});
        const projection = (try parse(arena.allocator(), "host.run_in_terminal", "{}", .succeeded, receipt, content)).?;
        try std.testing.expectEqual(case.framed, projection.shell_framing_only);
        try std.testing.expectEqualStrings(if (case.framed) "" else case.output, projection.terminal_output);
        var buffer: [32]u8 = undefined;
        try std.testing.expectEqualStrings("退出码 1", (try projection.processLabel(&buffer)).?);
        if (case.framed) try std.testing.expectEqualStrings("采集区间只有 Shell 控制信息，没有实际命令输出。", projection.outputLabel().?);
    }
}

test "execution interval projection preserves saved observation attribution and foreground exit independently" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const receipt: host.Receipt = .{ .conversation_id = .generate(), .task_id = .generate(), .operation_id = 1, .binding_revision = 1 };
    const id: identity.ExecutionId = .generate();
    const recording: identity.RecordingId = .generate();
    inline for ([_]terminal.OutputAttribution{ .unverified, .no_concurrent_owner_observed, .concurrent_observed }) |attribution| {
        const snapshot: terminal.Snapshot = .{
            .owner = .{ .session_id = @fromBackingInt(101), .generation = 9 },
            .execution_id = id,
            .state = .interval_recorded,
            .process = .{ .exit_code = 7, .foreground_finished = true, .background_jobs = true, .background_jobs_unknown = true },
            .recording_id = std.fmt.bytesToHex(recording.bytes, .lower),
            .recording_settled = true,
            .output_scope = .session_interval,
            .output_attribution = attribution,
            .output_attribution_reason = "BackgroundJobsObserved",
            .interval_saved = true,
        };
        const content = try std.json.Stringify.valueAlloc(aa, .{ .snapshot = snapshot, .output = "OBSERVED_PTY_BYTES", .output_available = true }, .{});
        const result = (try parse(aa, "host.run_in_terminal", "{}", .succeeded, receipt, content)).?;
        try std.testing.expect(result.intervalRecorded() and !result.sealed());
        try std.testing.expectEqual(.session_interval, result.output_scope);
        try std.testing.expectEqual(attribution, result.output_attribution);
        try std.testing.expectEqualStrings("BackgroundJobsObserved", result.output_attribution_reason.?);
        try std.testing.expectEqualStrings("命令执行失败", result.statusLabel());
        try std.testing.expectEqual(@as(?u8, 7), result.process.?.exit_code);
        try std.testing.expectEqualStrings("OBSERVED_PTY_BYTES", result.terminal_output);
        try std.testing.expect(result.actionTarget() != null and !result.canStop() and !result.canTakeover());
        const copy = try result.clone(aa);
        try std.testing.expect(copy.output_attribution_reason.?.ptr != result.output_attribution_reason.?.ptr);
        try std.testing.expectEqual(result.retainedBytes(), copy.retainedBytes());
        try std.testing.expectEqualStrings(result.output_attribution_reason.?, copy.output_attribution_reason.?);
        var failed_recording = result;
        failed_recording.state = .recording_degraded;
        failed_recording.recording_failed = true;
        failed_recording.interval_saved = false;
        try std.testing.expect(!failed_recording.intervalRecorded());
        try std.testing.expectEqualStrings("命令执行失败", failed_recording.statusLabel());
        try std.testing.expectEqual(@as(?u8, 7), failed_recording.process.?.exit_code);
        var disconnected = result;
        disconnected.state = .outcome_unknown;
        disconnected.remote_effect_unknown = true;
        try std.testing.expect(!disconnected.intervalRecorded());
        try std.testing.expectEqualStrings("结果待核实", disconnected.statusLabel());
    }
    const legacy = (try parse(aa, "host.get_execution", "{}", .succeeded, receipt, "{\"snapshot\":{\"state\":\"running\"}}")).?;
    try std.testing.expectEqual(.exact, legacy.output_scope);
    try std.testing.expect(!legacy.interval_saved);
}

test "execution input projection keeps typed receipt separate from execution and private input bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call: host.Receipt = .{ .conversation_id = .generate(), .task_id = .generate(), .operation_id = 1, .binding_revision = 1 };
    const reference = "x1:0123456789abcdef0123456789abcdef";
    const receipt: terminal.InputReceipt = .{ .input_sequence = 5, .wait_sequence = 3, .kind = .host_secret, .stage = .consumed };
    const content = try std.json.Stringify.valueAlloc(a, .{
        .execution_ref = reference,
        .input_receipt = receipt,
        .host_secret_status = "secret_submitted",
        .snapshot = .{ .state = "sealed", .process = terminal.ProcessReceipt{ .exit_code = 0, .foreground_finished = true } },
        .output = "PRIVATE_INPUT_SENTINEL",
        .output_available = true,
    }, .{});
    const parsed = (try parse(a, "host__send_uexecution_uinput", "{\"text\":\"PRIVATE_INPUT_SENTINEL\",\"command\":\"PRIVATE_INPUT_SENTINEL\"}", .succeeded, call, content)).?;
    try std.testing.expect(parsed.input_result);
    try std.testing.expectEqualDeep(receipt, parsed.input_receipt.?);
    try std.testing.expectEqualStrings("输入已消费", parsed.statusLabel());
    try std.testing.expect(parsed.command == null and parsed.process == null and parsed.state == null and parsed.target == null);
    try std.testing.expect(parsed.actionTarget() == null and !parsed.sealed() and !parsed.intervalRecorded());
    try std.testing.expectEqualStrings("", parsed.terminal_output);
    try std.testing.expect(!parsed.output_available);
    const copy = try parsed.clone(a);
    try std.testing.expectEqualDeep(receipt, copy.input_receipt.?);
    var unknown = parsed;
    unknown.call_status = .outcome_unknown;
    unknown.failure = "InputAcknowledgementUnknown";
    try std.testing.expectEqualStrings("输入结果待核实", unknown.statusLabel());
    try std.testing.expectEqualStrings("InputAcknowledgementUnknown", unknown.failure.?);
}

test "execution projection preserves shell report source and never calls a terminal write consumption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const receipt: host.Receipt = .{ .conversation_id = .generate(), .task_id = .generate(), .operation_id = 1, .binding_revision = 1 };
    const observed = (try parse(a, "host.get_execution", "{}", .succeeded, receipt, "{\"snapshot\":{\"state\":\"running\",\"completion_source\":\"shell_reported\"}}")).?;
    try std.testing.expectEqual(terminal.CompletionSource.shell_reported, observed.completion_source);
    try std.testing.expect(observed.active() and !observed.intervalRecorded());
    const legacy = (try parse(a, "host.get_execution", "{}", .succeeded, receipt, "{\"snapshot\":{\"state\":\"running\"}}")).?;
    try std.testing.expectEqual(terminal.CompletionSource.unknown, legacy.completion_source);
    const written = (try parse(a, "host.send_execution_input", "{\"text\":\"ordinary\"}", .succeeded, receipt, "{\"input_receipt\":{\"input_sequence\":1,\"wait_sequence\":2,\"kind\":\"text\",\"stage\":\"written\",\"accepted_bytes\":8}}")).?;
    try std.testing.expectEqualStrings("输入已写入终端", written.statusLabel());
    try std.testing.expect(written.process == null and written.command == null and !written.active());
    try std.testing.expectEqualStrings("", written.terminal_output);
}

test "execution interval projection keeps command completion independent of recording and user takeover" {
    var result: Projection = .{
        .conversation_id = .generate(),
        .task_id = .generate(),
        .call_status = .succeeded,
        .execution_id = .generate(),
        .target = .{ .session_id = @fromBackingInt(101), .generation = 9 },
        .state = .running,
        .output_scope = .session_interval,
        .input_handed_off = true,
        .has_input_grant = true,
    };
    try std.testing.expect(result.active() and !result.canStop() and !result.canTakeover());
    try std.testing.expectEqualStrings("用户已接管 · 命令继续运行", result.statusLabel());
    result.state = .interval_recorded;
    result.process = .{ .foreground_finished = true, .exit_code = 0 };
    result.recording_id = .generate();
    result.recording_settled = true;
    try std.testing.expect(!result.intervalRecorded());
    try std.testing.expectEqualStrings("命令已结束", result.statusLabel());
    result.interval_saved = true;
    try std.testing.expect(result.intervalRecorded());
    try std.testing.expectEqualStrings("命令已结束", result.statusLabel());
    result.output_scope = .exact;
    try std.testing.expect(!result.intervalRecorded());
}

test "execution interval projection validates typed recovered journal receipt without fabricating terminal control" {
    const JournalRecord = @import("lifecycle_journal.zig").Record;
    const Fixture = struct {
        fn body(allocator: std.mem.Allocator, record: JournalRecord) ![]const u8 {
            return std.json.Stringify.valueAlloc(allocator, .{ .execution_id = record.execution, .state = record.stage, .execution_receipt = record.execution_receipt, .local_released = record.local_released, .remote_effect_unknown = record.remote_effect_unknown }, .{});
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .group = 7 }, .binding_revision = 1, .grant_revision = 1 };
    const call: host.Receipt = .{ .conversation_id = context.conversation_id, .task_id = context.task_id, .operation_id = 1, .binding_revision = 1 };
    const id: identity.ExecutionId = .generate();
    var record: JournalRecord = .{
        .context = context,
        .operation_ref = .generate(),
        .tool_id = "host.run_in_terminal",
        .request_key = "recovered-interval",
        .canonical_hash = @splat(3),
        .original_turn = 1,
        .original_call = "original-call",
        .stage = .succeeded,
        .execution = id,
        .execution_receipt = .{
            .execution_id = id,
            .command_hash = @splat(3),
            .input_fence = 7,
            .input_epoch = 2,
            .accepted_sequence = 3,
            .submit_sequence = 4,
            .submit_ack_sequence = 5,
            .submit_native_bytes = 156,
            .native_wake_written = true,
            .recording_id = "0123456789abcdef0123456789abcdef".*,
            .recording_generation = 1,
            .start = .{ .raw_offset = 100, .sequence = 1, .event_sequence = 4 },
            .end = .{ .raw_offset = 140, .sequence = 2, .event_sequence = 9 },
            .manifest_revision = 6,
            .process = .{ .exit_code = 0, .foreground_finished = true },
            .recording_settled = true,
            .output_scope = .session_interval,
            .output_attribution = .concurrent_observed,
            .output_attribution_reason = "BackgroundJobsObserved",
            .interval_saved = true,
            .local_released = true,
        },
    };
    const recovered = (try parse(a, "host.get_execution", "{}", .succeeded, call, try Fixture.body(a, record))).?;
    try std.testing.expect(recovered.intervalRecorded() and !recovered.sealed());
    try std.testing.expect(recovered.execution_id.?.eql(id));
    try std.testing.expectEqual(.session_interval, recovered.output_scope);
    try std.testing.expectEqual(.concurrent_observed, recovered.output_attribution);
    try std.testing.expectEqualStrings("BackgroundJobsObserved", recovered.output_attribution_reason.?);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", &std.fmt.bytesToHex(recovered.recording_id.?.bytes, .lower));
    try std.testing.expect(recovered.local_released and !recovered.remote_effect_unknown);
    try std.testing.expect(recovered.target == null and recovered.actionTarget() == null and !recovered.canStop() and !recovered.canTakeover());
    record.execution_receipt.?.process.?.exit_code = 7;
    const failed = (try parse(a, "host.get_execution", "{}", .succeeded, call, try Fixture.body(a, record))).?;
    try std.testing.expectEqualStrings("命令执行失败", failed.statusLabel());
    try std.testing.expectEqual(@as(?u8, 7), failed.process.?.exit_code);
    var exact = record;
    exact.execution_receipt.?.output_scope = .exact;
    exact.execution_receipt.?.interval_saved = false;
    exact.execution_receipt.?.sealed = true;
    const sealed = (try parse(a, "host.get_execution", "{}", .succeeded, call, try Fixture.body(a, exact))).?;
    try std.testing.expect(sealed.sealed() and !sealed.intervalRecorded() and sealed.actionTarget() == null);
    var unfinished = record;
    unfinished.execution_receipt.?.interval_saved = false;
    unfinished.execution_receipt.?.local_released = false;
    unfinished.execution_receipt.?.remote_effect_unknown = true;
    const unknown = (try parse(a, "host.get_execution", "{}", .succeeded, call, try Fixture.body(a, unfinished))).?;
    try std.testing.expect(unknown.state == null and !unknown.local_released and unknown.remote_effect_unknown);
    try std.testing.expectEqual(@as(?u8, 7), unknown.process.?.exit_code);
    var tampered = record;
    tampered.execution_receipt.?.end = null;
    const rejected = (try parse(a, "host.get_execution", "{}", .succeeded, call, try Fixture.body(a, tampered))).?;
    try std.testing.expect(rejected.state == null and rejected.process == null and rejected.recording_id == null and !rejected.interval_saved and !rejected.sealed());
    var mismatched = record;
    mismatched.execution = .generate();
    const conflict = (try parse(a, "host.get_execution", "{}", .succeeded, call, try Fixture.body(a, mismatched))).?;
    try std.testing.expect(conflict.execution_id == null and conflict.state == null and conflict.process == null);
    var missing = record;
    missing.execution_receipt = null;
    const legacy = (try parse(a, "host.get_execution", "{}", .succeeded, call, try Fixture.body(a, missing))).?;
    try std.testing.expect(legacy.state == null and legacy.process == null and legacy.execution_id == null and !legacy.sealed() and !legacy.intervalRecorded());
    const malformed = (try parse(a, "host.get_execution", "{}", .succeeded, call, "{\"state\":\"succeeded\",\"execution_receipt\":{\"sealed\":true}}")).?;
    try std.testing.expect(malformed.state == null and malformed.execution_id == null and !malformed.sealed());
    const snapshot_first = (try parse(a, "host.get_execution", "{}", .succeeded, call, "{\"snapshot\":{\"state\":\"running\",\"output_scope\":\"session_interval\"},\"execution_receipt\":{\"sealed\":true}}")).?;
    try std.testing.expectEqual(terminal.State.running, snapshot_first.state.?);
    try std.testing.expectEqual(.session_interval, snapshot_first.output_scope);
}

test "execution interval projection separates real uncertainty from generic PTY limits" {
    var result: Projection = .{
        .conversation_id = .generate(),
        .task_id = .generate(),
        .call_status = .succeeded,
        .state = .interval_recorded,
        .output_scope = .session_interval,
        .process = .{ .foreground_finished = true, .exit_code = 0, .background_jobs_unknown = true },
        .completion_source = .shell_reported,
        .output_attribution_reason = "OutputProcessIdentityUnknown",
    };
    try std.testing.expectEqualStrings("命令已结束", result.statusLabel());
    try std.testing.expect(result.outputWarning() == null);
    result.output_attribution = .no_concurrent_owner_observed;
    try std.testing.expect(result.outputWarning() == null);
    result.output_attribution = .concurrent_observed;
    try std.testing.expectEqualStrings("检测到其他程序可能写入终端，输出可能包含其他程序的内容。", result.outputWarning().?);
    result.output_attribution = .unverified;
    result.output_attribution_reason = "OutputObservationDeadline";
    try std.testing.expect(result.outputWarning() != null);
    result.output_attribution_reason = "BackgroundJobsUnknown";
    try std.testing.expect(result.outputWarning() != null);
    result.output_attribution_reason = null;
    result.process.?.background_jobs = true;
    try std.testing.expectEqualStrings("检测到后台任务，前台命令结束后仍可能继续运行。", result.outputWarning().?);
    result.recording_failed = true;
    result.state = .recording_degraded;
    try std.testing.expectEqualStrings("命令已结束", result.statusLabel());
    result.process.?.exit_code = null;
    try std.testing.expectEqualStrings("命令已结束 · 退出状态未知", result.statusLabel());
    result.process.?.exit_code = 0;
    result.process.?.signal = 15;
    try std.testing.expectEqualStrings("命令执行失败", result.statusLabel());
    result.process = null;
    try std.testing.expectEqualStrings("执行状态待核实", result.statusLabel());
}

test "efficiency model projection preserves outcome evidence without mutating original receipt" {
    const a = std.testing.allocator;
    const original = "{\"execution_ref\":\"x1:original\",\"output\":\"observed\",\"truncated\":false,\"snapshot\":{\"state\":\"running\",\"completion_source\":\"shell_reported\",\"remote_effect_unknown\":true,\"output_scope\":\"session_interval\",\"local_released\":false,\"submit_sequence\":100,\"input_receipt\":{\"input_sequence\":9,\"stage\":\"consumed\"},\"grant\":{\"task\":7}}}";
    const compact = try modelContent(a, "host.get_execution", original);
    defer a.free(compact);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, compact, .{});
    defer parsed.deinit();
    const snapshot = parsed.value.object.get("snapshot").?.object;
    try std.testing.expect(snapshot.get("remote_effect_unknown").?.bool);
    try std.testing.expect(snapshot.get("has_input_grant").?.bool);
    try std.testing.expectEqualStrings("consumed", snapshot.get("input_receipt").?.object.get("stage").?.string);
    try std.testing.expect(snapshot.get("grant") == null and snapshot.get("submit_sequence") == null);
    try std.testing.expectEqualStrings("shell_reported", snapshot.get("completion_source").?.string);
    try std.testing.expect(std.mem.indexOf(u8, original, "submit_sequence") != null);
}
