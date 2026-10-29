//! Versioned private-shell execution facts. A lease controls local input only;
//! neither TTL nor a terminal prompt proves foreground completion.
const std = @import("std");
const identity = @import("identity.zig");
pub const version = 1;
pub const ttl_ms = 15_000;
pub const renew_ms = 5_000;
pub const max_command = 65_534;
pub const State = enum { unavailable, idle, preparing, awaiting_start_boundary, awaiting_accept, awaiting_submit, running, process_finished, output_draining, recording_sealing, sealed, interval_recorded, cancelled_unsent, handed_off, outcome_unknown, recording_degraded };
/// `exact` retains the earlier strict contract for compatibility. New product
/// requests record a same-PTY interval and never imply exclusive writer identity.
pub const OutputScope = enum { exact, session_interval };
pub const OutputAttribution = enum { unverified, no_concurrent_owner_observed, concurrent_observed };
pub const Grant = struct {
    execution_id: identity.ExecutionId,
    task_id: identity.TaskId,
    fence: u64,
    input_epoch: u64,
    ownership_revision: u64,
};
/// Only the explicitly installed shell helper can attest this wait. Ordinary
/// prompt text, termios and a running child never create an input capability.
pub const InputKind = enum { text, enter, host_secret };
pub const InputWait = struct {
    sequence: u64,
    kind: enum { controlled_line, host_secret } = .controlled_line,
    max_bytes: u16 = 4096,
};
pub const InputRequest = struct {
    grant: Grant,
    wait_sequence: u64,
    input_sequence: u64,
    kind: InputKind,
    text: []const u8 = "",
};
/// Host-only boundary: bytes are obtained from a temporary secure reference,
/// never from a model tool argument or an ordinary terminal input queue.
pub const SecretAction = union(enum) {
    begin: InputRequest,
    submit: struct { request: InputRequest, bytes: []const u8 },
    cancel: InputRequest,
};
pub const InputReceipt = struct {
    input_sequence: u64,
    wait_sequence: u64,
    kind: InputKind,
    stage: enum { awaiting_host_secret, queued, consumed, cancelled_unsent, outcome_unknown },
    accepted_bytes: usize = 0,
};
pub const Request = struct {
    execution_id: identity.ExecutionId,
    task_id: identity.TaskId,
    expected_input_epoch: u64,
    ownership_revision: u64,
    /// Already normalized bytes displayed by approval and bound to its hash.
    command: []const u8,
    command_hash: [32]u8,
    output_scope: OutputScope = .session_interval,
};
pub const Output = struct {
    bytes: []u8,
    start_cursor: u64,
    next_cursor: u64,
    gap: bool,
    truncated: bool,
    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};
pub const ProcessReceipt = struct { exit_code: ?u8 = null, signal: ?u8 = null, foreground_finished: bool = false, background_jobs: bool = false, background_jobs_unknown: bool = false };
pub const Boundary = struct { raw_offset: u64, sequence: u64, event_sequence: u64 = 0 };
pub const Snapshot = struct {
    owner: identity.SessionHandle,
    execution_id: ?identity.ExecutionId = null,
    command_hash: [32]u8 = @splat(0),
    execution_fence: u64 = 0,
    execution_input_epoch: u64 = 0,
    accepted_sequence: u64 = 0,
    submit_sequence: u64 = 0,
    submit_ack_sequence: u64 = 0,
    submit_native_bytes: u64 = 0,
    native_wake_written: bool = false,
    submit_queued: bool = false,
    state: State = .unavailable,
    revision: u64 = 1,
    started_at: i64 = 0,
    elapsed_ms: u64 = 0,
    output_received: u64 = 0,
    interactive_execution: bool = false,
    input_wait: ?InputWait = null,
    input_receipt: ?InputReceipt = null,
    input_epoch: u64 = 0,
    lease_expires_at: i64 = 0,
    grant: ?Grant = null,
    /// Input ownership was returned to the user. Foreground/output observation
    /// continues under the original execution identity until its real end.
    input_handed_off: bool = false,
    input_ready: bool = true,
    local_released: bool = true,
    remote_effect_unknown: bool = false,
    command_accepted: bool = false,
    submit_sent: bool = false,
    process: ?ProcessReceipt = null,
    start: ?Boundary = null,
    end: ?Boundary = null,
    recording_id: ?[32]u8 = null,
    recording_generation: u64 = 0,
    manifest_revision: u64 = 0,
    recording_settled: bool = false,
    recording_failed: bool = false,
    output_scope: OutputScope = .exact,
    output_attribution: OutputAttribution = .unverified,
    output_attribution_reason: ?[]const u8 = null,
    /// Saving the observed interval does not establish complete command output.
    interval_saved: bool = false,
    failure: ?[]const u8 = null,
};
/// Non-secret immutable/monotonic facts persisted beside the execution's
/// original journal key. Native-written never means foreground-consumed.
pub const PublicReceipt = struct {
    execution_id: identity.ExecutionId,
    command_hash: [32]u8,
    input_receipt: ?InputReceipt = null,
    input_fence: u64,
    input_epoch: u64,
    accepted_sequence: u64 = 0,
    submit_sequence: u64 = 0,
    submit_ack_sequence: u64 = 0,
    submit_native_bytes: u64 = 0,
    native_wake_written: bool = false,
    recording_id: ?[32]u8 = null,
    recording_generation: u64 = 0,
    start: ?Boundary = null,
    end: ?Boundary = null,
    manifest_revision: u64 = 0,
    process: ?ProcessReceipt = null,
    recording_settled: bool = false,
    recording_failed: bool = false,
    sealed: bool = false,
    output_scope: OutputScope = .exact,
    output_attribution: OutputAttribution = .unverified,
    output_attribution_reason: ?[]const u8 = null,
    interval_saved: bool = false,
    local_released: bool = false,
    input_handed_off: bool = false,
    remote_effect_unknown: bool = false,
    pub fn fromSnapshot(value: Snapshot) ?PublicReceipt {
        const id = value.execution_id orelse return null;
        if (value.execution_fence == 0) return null;
        return .{ .execution_id = id, .command_hash = value.command_hash, .input_receipt = value.input_receipt, .input_fence = value.execution_fence, .input_epoch = value.execution_input_epoch, .accepted_sequence = value.accepted_sequence, .submit_sequence = value.submit_sequence, .submit_ack_sequence = value.submit_ack_sequence, .submit_native_bytes = value.submit_native_bytes, .native_wake_written = value.native_wake_written, .recording_id = value.recording_id, .recording_generation = value.recording_generation, .start = value.start, .end = value.end, .manifest_revision = value.manifest_revision, .process = value.process, .recording_settled = value.recording_settled, .recording_failed = value.recording_failed, .sealed = value.state == .sealed, .output_scope = value.output_scope, .output_attribution = value.output_attribution, .output_attribution_reason = value.output_attribution_reason, .interval_saved = value.interval_saved, .local_released = value.local_released, .input_handed_off = value.input_handed_off, .remote_effect_unknown = value.remote_effect_unknown };
    }
    pub fn validate(self: PublicReceipt) !void {
        if (!self.execution_id.valid() or self.input_fence == 0) return error.InvalidExecutionReceipt;
        if (self.input_receipt) |receipt| {
            if (receipt.input_sequence == 0 or receipt.wait_sequence == 0 or receipt.accepted_bytes > 4096 or ((receipt.kind == .enter or receipt.kind == .host_secret) and receipt.accepted_bytes != 0) or ((receipt.stage == .awaiting_host_secret or receipt.stage == .queued or receipt.stage == .cancelled_unsent) and receipt.accepted_bytes != 0)) return error.InvalidExecutionReceipt;
        }
        if (self.output_attribution_reason) |reason| if (reason.len > 96 or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidExecutionReceipt;
        if (self.submit_native_bytes > 0 and (self.accepted_sequence == 0 or self.submit_sequence == 0)) return error.InvalidExecutionReceipt;
        if (self.native_wake_written and (self.submit_native_bytes == 0 or self.submit_ack_sequence == 0)) return error.InvalidExecutionReceipt;
        if (self.recording_id) |id| {
            var raw: [16]u8 = undefined;
            _ = std.fmt.hexToBytes(&raw, &id) catch return error.InvalidExecutionReceipt;
            if (self.recording_generation == 0) return error.InvalidExecutionReceipt;
        }
        if (self.end) |end| {
            const start = self.start orelse return error.InvalidExecutionReceipt;
            if (end.raw_offset < start.raw_offset or end.sequence <= start.sequence or end.event_sequence <= start.event_sequence) return error.InvalidExecutionReceipt;
        }
        if (self.sealed and (self.start == null or self.end == null or !self.recording_settled or self.recording_failed or !self.local_released or self.remote_effect_unknown or self.process == null or !self.process.?.foreground_finished or (self.process.?.background_jobs or self.process.?.background_jobs_unknown))) return error.InvalidExecutionReceipt;
        if (self.sealed and (self.output_scope != .exact or self.interval_saved)) return error.InvalidExecutionReceipt;
        if (self.interval_saved and (self.output_scope != .session_interval or self.sealed or self.accepted_sequence == 0 or self.submit_sequence == 0 or self.submit_ack_sequence == 0 or self.submit_native_bytes == 0 or !self.native_wake_written or self.start == null or self.end == null or self.recording_id == null or self.manifest_revision == 0 or !self.recording_settled or self.recording_failed or !self.local_released or self.remote_effect_unknown or self.process == null or !self.process.?.foreground_finished)) return error.InvalidExecutionReceipt;
    }
    pub fn validateTransition(self: PublicReceipt, prior: PublicReceipt) !void {
        try self.validate();
        if (prior.input_receipt) |old| {
            const next = self.input_receipt orelse return error.ExecutionReceiptRegression;
            if (next.input_sequence < old.input_sequence or next.wait_sequence < old.wait_sequence) return error.ExecutionReceiptRegression;
            if (next.input_sequence == old.input_sequence and (next.kind != old.kind or next.wait_sequence != old.wait_sequence or ((old.stage == .consumed or old.stage == .cancelled_unsent or old.stage == .outcome_unknown) and !std.meta.eql(next, old)))) return error.ExecutionReceiptRegression;
        }
        if (self.output_scope != prior.output_scope or (prior.interval_saved and !self.interval_saved)) return error.ExecutionReceiptRegression;
        if (prior.output_attribution == .concurrent_observed and self.output_attribution != .concurrent_observed) return error.ExecutionReceiptRegression;
        if (prior.interval_saved and (self.output_attribution != prior.output_attribution or !sameReason(self.output_attribution_reason, prior.output_attribution_reason))) return error.ExecutionReceiptRegression;
        if (prior.input_handed_off and !self.input_handed_off) return error.ExecutionReceiptRegression;
        if (!self.execution_id.eql(prior.execution_id) or !std.mem.eql(u8, &self.command_hash, &prior.command_hash) or self.input_fence != prior.input_fence or self.input_epoch != prior.input_epoch or self.accepted_sequence < prior.accepted_sequence or self.submit_sequence < prior.submit_sequence or self.submit_ack_sequence < prior.submit_ack_sequence or self.submit_native_bytes < prior.submit_native_bytes or self.manifest_revision < prior.manifest_revision or (prior.native_wake_written and !self.native_wake_written) or (prior.recording_settled and !self.recording_settled) or (prior.recording_failed and !self.recording_failed) or (prior.sealed and !self.sealed) or (prior.local_released and !self.local_released) or (prior.remote_effect_unknown and !self.remote_effect_unknown)) return error.ExecutionReceiptRegression;
        if (prior.recording_id != null and (!std.meta.eql(prior.recording_id, self.recording_id) or prior.recording_generation != self.recording_generation)) return error.ExecutionReceiptRegression;
        if (prior.start != null and !std.meta.eql(prior.start, self.start)) return error.ExecutionReceiptRegression;
        if (prior.end != null and !std.meta.eql(prior.end, self.end)) return error.ExecutionReceiptRegression;
        if (prior.process != null and !std.meta.eql(prior.process, self.process)) return error.ExecutionReceiptRegression;
    }
};
fn sameReason(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |value| return if (right) |other| std.mem.eql(u8, value, other) else false;
    return right == null;
}
pub const Lease = struct {
    fence: u64 = 0,
    input_epoch: u64 = 0,
    holder: ?Grant = null,
    expires_at: i64 = 0,
    /// Native in-flight data must finish under its original bytes/receipt.
    draining: bool = false,
    pub fn acquire(self: *Lease, request: Request, now: i64) !Grant {
        if (self.holder != null or self.draining) return error.OperationBusy;
        if (request.expected_input_epoch != self.input_epoch) return error.InputConflict;
        if (!request.execution_id.valid() or !request.task_id.valid() or request.ownership_revision == 0) return error.InvalidIdentity;
        self.fence = try identity.advance(@max(@as(u64, 1), self.fence));
        const grant: Grant = .{ .execution_id = request.execution_id, .task_id = request.task_id, .fence = self.fence, .input_epoch = self.input_epoch, .ownership_revision = request.ownership_revision };
        self.holder = grant;
        self.expires_at = now + ttl_ms;
        return grant;
    }
    pub fn check(self: *const Lease, grant: Grant, now: i64) !void {
        const current = self.holder orelse return error.StaleFence;
        if (!std.meta.eql(current, grant) or now >= self.expires_at) return error.StaleFence;
    }
    pub fn renew(self: *Lease, grant: Grant, now: i64) !void {
        try self.check(grant, now);
        self.expires_at = now + ttl_ms;
    }
    pub fn revoke(self: *Lease, in_flight: bool) void {
        self.holder = null;
        self.fence +|= 1;
        self.input_epoch +|= 1;
        self.draining = in_flight;
        self.expires_at = 0;
    }
    pub fn ordinaryInput(self: *Lease) !void {
        if (self.holder != null or self.draining) return error.TerminalControlled;
        self.input_epoch = try identity.advance(@max(@as(u64, 1), self.input_epoch));
    }
};

test "input handoff receipt is monotonic without claiming foreground completion" {
    const id = identity.ExecutionId.generate();
    var snapshot: Snapshot = .{ .owner = .{ .session_id = @fromBackingInt(7), .generation = 2 }, .execution_id = id, .execution_fence = 4, .execution_input_epoch = 8, .state = .running, .local_released = false, .input_ready = false };
    const prior = PublicReceipt.fromSnapshot(snapshot).?;
    snapshot.input_handed_off = true;
    snapshot.local_released = true;
    snapshot.input_ready = true;
    const handed = PublicReceipt.fromSnapshot(snapshot).?;
    try handed.validateTransition(prior);
    try std.testing.expect(!handed.sealed and !handed.recording_settled and handed.process == null and !handed.remote_effect_unknown);
    var regressed = handed;
    regressed.input_handed_off = false;
    try std.testing.expectError(error.ExecutionReceiptRegression, regressed.validateTransition(handed));
}
test "observed interval receipt saves real foreground facts without exact output claims" {
    const id = identity.ExecutionId.generate();
    const recording = std.fmt.bytesToHex(identity.RecordingId.generate().bytes, .lower);
    const snapshot: Snapshot = .{ .owner = .{ .session_id = @fromBackingInt(7), .generation = 2 }, .execution_id = id, .execution_fence = 4, .execution_input_epoch = 8, .state = .interval_recorded, .command_accepted = true, .submit_sent = true, .accepted_sequence = 1, .submit_sequence = 2, .submit_ack_sequence = 3, .submit_native_bytes = 5, .native_wake_written = true, .start = .{ .raw_offset = 0, .sequence = 1, .event_sequence = 1 }, .end = .{ .raw_offset = 10, .sequence = 2, .event_sequence = 2 }, .recording_id = recording, .recording_generation = 1, .manifest_revision = 3, .process = .{ .exit_code = 7, .foreground_finished = true, .background_jobs_unknown = true }, .recording_settled = true, .output_scope = .session_interval, .output_attribution = .unverified, .output_attribution_reason = "OutputProcessIdentityUnknown", .interval_saved = true };
    const receipt = PublicReceipt.fromSnapshot(snapshot).?;
    try receipt.validate();
    try std.testing.expect(!receipt.sealed and receipt.interval_saved and !receipt.remote_effect_unknown);
    try std.testing.expectEqual(@as(?u8, 7), receipt.process.?.exit_code);
    var false_exact = receipt;
    false_exact.sealed = true;
    try std.testing.expectError(error.InvalidExecutionReceipt, false_exact.validate());
    var missing_end = receipt;
    missing_end.end = null;
    try std.testing.expectError(error.InvalidExecutionReceipt, missing_end.validate());
    var regressed = receipt;
    regressed.interval_saved = false;
    try std.testing.expectError(error.ExecutionReceiptRegression, regressed.validateTransition(receipt));
    regressed = receipt;
    regressed.output_attribution = .no_concurrent_owner_observed;
    try std.testing.expectError(error.ExecutionReceiptRegression, regressed.validateTransition(receipt));
}
pub fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
/// CRLF is the sole normalization. No unsafe byte is silently removed.
pub fn normalizeCommand(a: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len > max_command * 2 or !std.unicode.utf8ValidateSlice(input)) return error.InvalidCommand;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte == '\r') {
            if (index + 1 >= input.len or input[index + 1] != '\n') return error.InvalidCommand;
            index += 1;
            try out.append(a, '\n');
        } else try out.append(a, byte);
    }
    try validateCommand(out.items);
    return out.toOwnedSlice(a);
}
pub fn validateCommand(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > max_command or !std.unicode.utf8ValidateSlice(bytes) or std.mem.trim(u8, bytes, " \t\n").len == 0) return error.InvalidCommand;
    // zsh -n accepts an EOF-terminated unfinished heredoc. Until the native
    // parser negotiates an exact heredoc delimiter receipt, conservatively
    // refuse every << token (including tokens joined by escaped newlines).
    var previous: u8 = 0;
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] == '\\' and index + 1 < bytes.len and bytes[index + 1] == '\n') {
            index += 1;
            continue;
        }
        if (previous == '<' and bytes[index] == '<') return error.UnsupportedSyntax;
        previous = bytes[index];
    }
    var iterator = (try std.unicode.Utf8View.init(bytes)).iterator();
    while (iterator.nextCodepoint()) |cp| if ((cp < 32 and cp != 9 and cp != 10) or cp == 127 or (cp >= 128 and cp <= 159)) return error.InvalidCommand;
}
pub fn validateInput(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > 4096 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidInput;
    var iterator = (try std.unicode.Utf8View.init(bytes)).iterator();
    while (iterator.nextCodepoint()) |cp| if (cp < 32 or cp == 127 or (cp >= 128 and cp <= 159)) return error.InvalidInput;
}
test "command normalization rejects controls without silent deletion" {
    const a = std.testing.allocator;
    const normalized = try normalizeCommand(a, "printf 中文\r\ntrue");
    defer a.free(normalized);
    try std.testing.expectEqualStrings("printf 中文\ntrue", normalized);
    for ([_][]const u8{ " \n", "echo\rfalse", "echo\x1b[0m", "echo\x7f", "echo\xc2\x85", "echo\x00" }) |bad| try std.testing.expectError(error.InvalidCommand, normalizeCommand(a, bad));
    for ([_][]const u8{ "x\n", "x\t", "x\r", "x\x1b", "x\xc2\x85" }) |bad| try std.testing.expectError(error.InvalidInput, validateInput(bad));
}
test "lease expiry revoke and epochs never authorize an old producer" {
    var lease: Lease = .{};
    const request: Request = .{ .execution_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .expected_input_epoch = 0, .ownership_revision = 1, .command = "true", .command_hash = digest("true") };
    const grant = try lease.acquire(request, 100);
    try std.testing.expectError(error.TerminalControlled, lease.ordinaryInput());
    try lease.check(grant, 100 + ttl_ms - 1);
    try std.testing.expectError(error.StaleFence, lease.check(grant, 100 + ttl_ms));
    lease.revoke(true);
    try std.testing.expectError(error.TerminalControlled, lease.ordinaryInput());
    lease.draining = false;
    try lease.ordinaryInput();
    try std.testing.expectError(error.StaleFence, lease.check(grant, 200));
    try std.testing.expectError(error.InputConflict, lease.acquire(request, 200));
}

test "heredoc without parser completeness receipt is refused before transport" {
    try std.testing.expectError(error.UnsupportedSyntax, validateCommand("cat <<EOF\nunterminated"));
    try std.testing.expectError(error.UnsupportedSyntax, validateCommand("cat <\\\n<EOF\nunterminated"));
}
