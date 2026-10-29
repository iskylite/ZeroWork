//! Immutable user-facing facts extracted only from trusted host execution results.
//! Missing receipts stay missing; a successful observation never proves completion.
const std = @import("std");
const identity = @import("../host/identity.zig");
const terminal = @import("../host/terminal_execution.zig");
const host = @import("host_tools.zig");
const plugin = @import("plugin_tools.zig");

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
    not_dispatched: bool = false,
    execution_id: ?identity.ExecutionId = null,
    target: ?identity.SessionHandle = null,
    target_label: []const u8 = "",
    command: ?[]const u8 = null,
    state: ?terminal.State = null,
    process: ?terminal.ProcessReceipt = null,
    recording_id: ?identity.RecordingId = null,
    terminal_output: []const u8 = "",
    output_available: bool = false,
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
        if (self.call_status == .rejected) return "未执行 · 已拒绝";
        if (self.call_status == .cancelled_unsent) return "未派发 · 已取消";
        if (self.remote_effect_unknown or self.state == .outcome_unknown) return "结果待核实";
        if (self.not_dispatched) return "未执行 · 调用失败";
        if (self.stop_requested and self.active()) return "停止已请求 · 等待执行结果";
        if (self.input_handed_off and self.active()) return "用户已接管 · 命令继续运行";
        return switch (self.state orelse return if (self.call_status == .failed) "调用失败" else "执行状态待核实") {
            .unavailable => "执行不可用",
            .idle => "终端空闲",
            .preparing, .awaiting_start_boundary, .awaiting_accept => "准备执行",
            .awaiting_submit => "正在提交命令",
            .running => "运行中",
            .process_finished => "前台已结束",
            .output_draining => if (self.output_scope == .session_interval) "正在读取观测片段" else "正在收齐输出",
            .recording_sealing => if (self.output_scope == .session_interval) "正在保存观测片段" else "正在封存记录",
            .sealed => if (self.recording_failed) "记录保存失败" else if (!self.sealed()) "封存结果待核实" else if (self.process.?.signal != null or (self.process.?.exit_code != null and self.process.?.exit_code.? != 0)) "已结束 · 执行失败" else if (self.process.?.exit_code == 0) "已完成 · 记录已封存" else "前台已结束 · 记录已封存",
            .interval_recorded => if (self.recording_failed) "记录保存失败" else if (!self.intervalRecorded()) "观测片段保存待核实" else if (self.process.?.signal != null or (self.process.?.exit_code != null and self.process.?.exit_code.? != 0)) "前台已结束 · 执行失败" else "前台已结束 · 观测片段已保存",
            .cancelled_unsent => "未派发 · 已取消",
            .handed_off => "输入权已交给用户",
            .outcome_unknown => "结果待核实",
            .recording_degraded => "记录保存失败",
        };
    }
    pub fn clone(self: Projection, allocator: std.mem.Allocator) !Projection {
        var copy = self;
        copy.target_label = try allocator.dupe(u8, self.target_label);
        copy.command = if (self.command) |text| try allocator.dupe(u8, text) else null;
        copy.terminal_output = try allocator.dupe(u8, self.terminal_output);
        copy.output_attribution_reason = if (self.output_attribution_reason) |text| try allocator.dupe(u8, text) else null;
        copy.failure = if (self.failure) |text| try allocator.dupe(u8, text) else null;
        return copy;
    }
    pub fn retainedBytes(self: Projection) usize {
        return self.target_label.len + (if (self.command) |text| text.len else 0) + self.terminal_output.len + (if (self.output_attribution_reason) |text| text.len else 0) + (if (self.failure) |text| text.len else 0);
    }
};

pub fn isRun(name: []const u8) bool {
    var decoded: [64]u8 = undefined;
    const logical = plugin.decodeName(&decoded, name) catch name;
    return std.mem.eql(u8, logical, "host.run_in_terminal");
}
pub fn supports(name: []const u8) bool {
    var decoded: [64]u8 = undefined;
    const logical = plugin.decodeName(&decoded, name) catch name;
    for ([_][]const u8{ "host.run_in_terminal", "host.get_execution", "host.wait_execution", "host.stop_execution", "host.send_execution_input" }) |id| if (std.mem.eql(u8, logical, id)) return true;
    return false;
}
const Snapshot = struct {
    owner: ?identity.SessionHandle = null,
    execution_id: ?identity.ExecutionId = null,
    state: ?[]const u8 = null,
    process: ?terminal.ProcessReceipt = null,
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
    execution_ref: ?[]const u8 = null,
    execution_id: ?identity.ExecutionId = null,
    snapshot: ?Snapshot = null,
    execution_receipt: ?std.json.Value = null,
    recording_ref: ?[]const u8 = null,
    output: ?[]const u8 = null,
    output_available: bool = false,
    stop_requested: bool = false,
    gap: bool = false,
    truncated: bool = false,
};

pub fn parse(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8, status: plugin.Status, receipt: host.Receipt, content: []const u8) !?Projection {
    if (!supports(name)) return null;
    var result: Projection = .{ .conversation_id = receipt.conversation_id, .task_id = receipt.task_id, .call_status = status, .remote_effect_unknown = receipt.remote_effect_unknown };
    const args = std.json.parseFromSliceLeaky(struct { command: ?[]const u8 = null }, allocator, arguments, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
    if (args) |value| result.command = value.command;
    const wire = std.json.parseFromSliceLeaky(Wire, allocator, content, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return result;
    if (wire.execution_ref) |reference| if (std.mem.startsWith(u8, reference, "x1:")) {
        result.execution_id = identity.ExecutionId.parse(reference[3..]) catch null;
    };
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
    if (wire.recording_ref) |reference| {
        const id = identity.RecordingId.parse(reference) catch null;
        if (result.recording_id) |prior| {
            if (id == null or !prior.eql(id.?)) result.recording_id = null;
        } else result.recording_id = id;
    }
    if (result.failure == null) result.failure = wire.error_code;
    result.terminal_output = wire.output orelse "";
    result.output_available = wire.output_available;
    result.output_gap = wire.gap;
    result.output_truncated = wire.truncated;
    result.stop_requested = wire.stop_requested;
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
    var result: Projection = .{ .conversation_id = source.conversation_id, .task_id = source.task_id, .call_status = status, .not_dispatched = !dispatched, .remote_effect_unknown = source.remote_effect_unknown or status == .outcome_unknown, .failure = source.error_code };
    const args = std.json.parseFromSliceLeaky(struct { command: ?[]const u8 = null }, allocator, arguments, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
    if (args) |value| result.command = value.command;
    return result;
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
        try std.testing.expectEqualStrings("前台已结束 · 执行失败", result.statusLabel());
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
        try std.testing.expectEqualStrings("记录保存失败", failed_recording.statusLabel());
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

test "execution interval projection never upgrades missing saved evidence or user takeover into completion" {
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
    try std.testing.expectEqualStrings("观测片段保存待核实", result.statusLabel());
    result.interval_saved = true;
    try std.testing.expect(result.intervalRecorded());
    try std.testing.expectEqualStrings("前台已结束 · 观测片段已保存", result.statusLabel());
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
    try std.testing.expectEqualStrings("前台已结束 · 执行失败", failed.statusLabel());
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
