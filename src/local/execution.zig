//! Worker-owned TerminalExecutionProtocol v1, independent from prompt editing.
//! No PTY output text is ever decoded as a completion or authorization event.
const std = @import("std");
const identity = @import("../host/identity.zig");
const wire = @import("../host/trusted_edit.zig");
pub const execution = @import("../host/terminal_execution.zig");
const Native = @import("trusted_edit.zig").Native;
extern fn zw_local_edit_nonce(*Native) [*:0]const u8;
extern fn zw_local_execution_poll_fd(*Native) c_int;
extern fn zw_local_execution_close(*Native) void;
extern fn zw_local_execution_read(*Native, c_int, [*]u8, usize, *usize) c_int;
extern fn zw_local_execution_write(*Native, [*]const u8, usize, *usize) c_int;
const SecretNative = opaque {};
extern fn zw_local_secret_create(*Native) ?*SecretNative;
extern fn zw_local_secret_destroy(*SecretNative) void;
extern fn zw_local_secret_read(*SecretNative, c_int, [*]u8, usize, *usize) c_int;
extern fn zw_local_secret_write(*SecretNative, [*]const u8, usize, *usize) c_int;
extern fn zw_local_secret_close(*SecretNative) void;
/// A worker-owned private channel. It must never be backed by ordinary PTY
/// input/output. Local retains its native default; SSH supplies its separately
/// authenticated no-PTY control channel after BootstrapV1 authorization.
pub const Transport = struct {
    context: *anyopaque,
    nonce: []const u8,
    read: *const fn (*anyopaque, []u8, *usize) c_int,
    write: *const fn (*anyopaque, []const u8, *usize) c_int,
    close: *const fn (*anyopaque) void,
};
pub const BoundaryKind = enum { start, end };
/// Reserved for a host-authorized PTY stream; never emitted by a shell helper.
pub const terminal_stream_wait_sequence = execution.stream_wait_sequence;
pub const Sink = struct {
    context: *anyopaque,
    output: *const fn (*anyopaque, []const u8, u64) void,
    boundary: ?*const fn (*anyopaque, BoundaryKind, execution.Boundary) void = null,
};
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    native: ?*Native,
    transport: ?Transport = null,
    secret_native: ?*SecretNative = null,
    secret_rx: std.ArrayList(u8) = .empty,
    reading_secret: bool = false,
    tx_secret_channel: bool = false,
    remote_ready: bool = false,
    snapshot: execution.Snapshot,
    lease: execution.Lease = .{},
    hello: bool = false,
    disabled: bool = false,
    last_received: u64 = 0,
    sequence: u64 = 0,
    rx: std.ArrayList(u8) = .empty,
    tx: std.ArrayList(u8) = .empty,
    tx_offset: usize = 0,
    tx_submit: bool = false,
    awaiting_submit_ack: bool = false,
    last_grant: ?execution.Grant = null,
    /// Authentication identity for read-only events. It survives a known user
    /// input handoff, but never grants input or authorizes a subsequent run.
    observation_grant: ?execution.Grant = null,
    command: ?[]u8 = null,
    captured: std.ArrayList(u8) = .empty,
    captured_start: u64 = 0,
    captured_total: u64 = 0,
    last_execution: ?identity.ExecutionId = null,
    command_hash: [32]u8 = @splat(0),
    start_token: [64]u8 = @splat(0),
    end_token: [64]u8 = @splat(0),
    start_frame: [104]u8 = undefined,
    end_frame: [104]u8 = undefined,
    start_frame_len: usize = 0,
    end_frame_len: usize = 0,
    start_registered: bool = false,
    end_registered: bool = false,
    start_seen: ?execution.Boundary = null,
    end_seen: ?execution.Boundary = null,
    start_recorded: bool = false,
    end_recorded: bool = false,
    shell_ready: bool = false,
    wake_pending: bool = false,
    raw_received: u64 = 0,
    output_pending: [256]u8 = undefined,
    output_pending_len: usize = 0,
    output_pending_start: u64 = 0,
    boundary_deadline: i64 = 0,
    started_monotonic: i64 = 0,
    output_observations_clear: bool = true,
    input_capability: bool = false,
    secret_capability: bool = false,
    tx_secret: bool = false,
    last_wait_sequence: u64 = 0,
    last_input_sequence: u64 = 0,
    last_input_hash: [32]u8 = @splat(0),
    input_expected_bytes: usize = 0,
    input_buffered_bytes: usize = 0,
    input_inflight: bool = false,
    tx_input: bool = false,
    input_deadline: i64 = 0,
    stream_buffer: [4096]u8 = undefined,
    stream_len: usize = 0,
    stream_offset: usize = 0,
    pub fn init(a: std.mem.Allocator, owner: identity.SessionHandle, native: *Native) Bridge {
        return .{ .allocator = a, .owner = owner, .native = native, .snapshot = .{ .owner = owner, .completion_source = .private_protocol } };
    }
    pub fn initTransport(a: std.mem.Allocator, owner: identity.SessionHandle, transport: Transport) Bridge {
        return .{ .allocator = a, .owner = owner, .native = null, .transport = transport, .snapshot = .{ .owner = owner, .completion_source = .private_protocol } };
    }
    fn nonce(self: *const Bridge) []const u8 {
        return if (self.transport) |t| t.nonce else std.mem.span(zw_local_edit_nonce(self.native.?));
    }
    fn readPrivate(self: *Bridge, pid: i32, bytes: []u8, count: *usize) c_int {
        return if (self.transport) |t| t.read(t.context, bytes, count) else zw_local_execution_read(self.native.?, pid, bytes.ptr, bytes.len, count);
    }
    fn writePrivate(self: *Bridge, bytes: []const u8, count: *usize) c_int {
        return if (self.transport) |t| t.write(t.context, bytes, count) else zw_local_execution_write(self.native.?, bytes.ptr, bytes.len, count);
    }
    pub fn deinit(self: *Bridge) void {
        if (self.command) |command| self.allocator.free(command);
        if (self.tx_secret) std.crypto.secureZero(u8, self.tx.items);
        self.captured.deinit(self.allocator);
        self.rx.deinit(self.allocator);
        self.secret_rx.deinit(self.allocator);
        self.tx.deinit(self.allocator);
        if (self.secret_native) |native| zw_local_secret_destroy(native);
    }
    pub fn pollFd(self: *const Bridge) c_int {
        return if (self.disabled or self.transport != null) -1 else zw_local_execution_poll_fd(self.native.?);
    }
    fn changed(self: *Bridge) void {
        self.snapshot.revision +|= 1;
        self.snapshot.input_epoch = self.lease.input_epoch;
        self.snapshot.grant = self.lease.holder;
        self.snapshot.lease_expires_at = self.lease.expires_at;
        self.snapshot.input_ready = self.lease.holder == null and !self.lease.draining;
        self.snapshot.local_released = self.snapshot.input_ready;
    }
    pub fn renew(self: *Bridge, grant: execution.Grant, now: i64) !void {
        try self.lease.renew(grant, now);
        self.changed();
    }
    /// This authorizes bytes to the running execution's PTY, not a claim that
    /// a particular child is waiting for, or will consume, those bytes.
    pub fn inputAvailability(self: *const Bridge) ?execution.InputWait {
        if (self.snapshot.input_wait) |wait| return wait;
        if (self.transport != null or !self.hello or self.disabled or self.lease.holder == null or self.snapshot.state != .running or self.snapshot.input_handed_off or self.snapshot.remote_effect_unknown) return null;
        return .{ .sequence = terminal_stream_wait_sequence, .kind = .terminal_stream };
    }
    pub fn streamInputPending(self: *const Bridge) bool {
        return self.stream_offset < self.stream_len;
    }
    pub fn streamInputBytes(self: *Bridge) []const u8 {
        return self.stream_buffer[self.stream_offset..self.stream_len];
    }
    pub fn streamInputWritten(self: *Bridge, count: usize) void {
        std.debug.assert(count <= self.stream_len - self.stream_offset);
        self.stream_offset += count;
        if (self.snapshot.input_receipt) |*receipt| {
            if (self.stream_offset == self.stream_len) {
                receipt.accepted_bytes = if (receipt.kind == .text) self.stream_offset else 0;
                receipt.stage = .written;
            }
        }
        if (!self.streamInputPending()) {
            self.stream_len = 0;
            self.stream_offset = 0;
            if (self.lease.draining and self.tx.items.len == self.tx_offset and !self.wake_pending and !self.awaiting_submit_ack) self.lease.draining = false;
        }
        self.changed();
    }
    pub fn streamInputFailed(self: *Bridge) void {
        if (self.snapshot.input_receipt) |*receipt| {
            receipt.stage = if (self.stream_offset == 0) .cancelled_unsent else .outcome_unknown;
            receipt.accepted_bytes = if (receipt.kind == .text) self.stream_offset else 0;
        }
        self.stream_len = 0;
        self.stream_offset = 0;
        self.lease.draining = self.wake_pending or self.awaiting_submit_ack;
        self.fail("TerminalInputWriteFailed", false);
    }
    pub fn sendInput(self: *Bridge, request: execution.InputRequest, now: i64) !execution.InputReceipt {
        if (self.transport != null or !self.hello or self.disabled or request.kind == .host_secret) return error.UnsupportedInteraction;
        try self.lease.check(request.grant, now);
        if (request.input_sequence == 0 or request.input_sequence > std.math.maxInt(i64) or request.wait_sequence == 0) return error.InvalidArguments;
        if (request.kind == .text) try execution.validateInput(request.text) else if (request.text.len != 0) return error.InvalidArguments;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(std.mem.asBytes(&request.grant.fence));
        hasher.update(std.mem.asBytes(&request.grant.input_epoch));
        hasher.update(std.mem.asBytes(&request.wait_sequence));
        hasher.update(@tagName(request.kind));
        hasher.update(request.text);
        const hash = hasher.finalResult();
        if (request.input_sequence == self.last_input_sequence) {
            if (!std.mem.eql(u8, &hash, &self.last_input_hash)) return error.InputConflict;
            return self.snapshot.input_receipt orelse error.InputConflict;
        }
        if (request.input_sequence < self.last_input_sequence or self.input_inflight or self.streamInputPending() or self.tx.items.len != self.tx_offset) return error.InputConflict;
        const wait = self.inputAvailability() orelse return error.InputNotExpected;
        if (wait.kind == .host_secret) return error.SecretMustUseHost;
        if (wait.kind == .controlled_line and !self.input_capability) return error.UnsupportedInteraction;
        if (self.snapshot.state != .running or self.snapshot.input_handed_off or self.snapshot.remote_effect_unknown or wait.sequence != request.wait_sequence) return error.InputNotExpected;
        if (request.text.len > wait.max_bytes or (wait.kind == .controlled_line and self.input_buffered_bytes + request.text.len > 4096)) return error.InputLimit;
        if (wait.kind == .terminal_stream) {
            const bytes = if (request.kind == .enter) "\r" else request.text;
            @memcpy(self.stream_buffer[0..bytes.len], bytes);
            self.stream_len = bytes.len;
            self.stream_offset = 0;
            self.last_input_sequence = request.input_sequence;
            self.last_input_hash = hash;
            const receipt: execution.InputReceipt = .{ .input_sequence = request.input_sequence, .wait_sequence = request.wait_sequence, .kind = request.kind, .stage = .queued };
            self.snapshot.input_receipt = receipt;
            self.changed();
            return receipt;
        }
        var fence: [32]u8 = undefined;
        var epoch: [32]u8 = undefined;
        var wait_sequence: [32]u8 = undefined;
        var input_sequence: [32]u8 = undefined;
        const id = std.fmt.bytesToHex(request.grant.execution_id.bytes, .lower);
        try self.send(&.{ "input", &id, dec(&fence, request.grant.fence), dec(&epoch, request.grant.input_epoch), dec(&wait_sequence, request.wait_sequence), dec(&input_sequence, request.input_sequence), @tagName(request.kind), request.text });
        self.last_input_sequence = request.input_sequence;
        self.last_input_hash = hash;
        self.input_expected_bytes = request.text.len;
        self.input_inflight = true;
        self.tx_input = true;
        self.input_deadline = now + 5000;
        const receipt: execution.InputReceipt = .{ .input_sequence = request.input_sequence, .wait_sequence = request.wait_sequence, .kind = request.kind, .stage = .queued };
        self.snapshot.input_receipt = receipt;
        self.changed();
        return receipt;
    }
    pub fn secret(self: *Bridge, action: execution.SecretAction, now: i64) !execution.InputReceipt {
        const request = switch (action) {
            .begin, .cancel => |value| value,
            .submit => |value| value.request,
        };
        if (self.transport != null or !self.secret_capability or !self.hello or self.disabled) return error.HostSecretUnavailable;
        try self.lease.check(request.grant, now);
        if (self.streamInputPending()) return error.InputConflict;
        if (request.kind != .host_secret or request.text.len != 0 or request.input_sequence == 0 or request.input_sequence > std.math.maxInt(i64)) return error.InvalidArguments;
        const wait = self.snapshot.input_wait orelse return error.InputNotExpected;
        if (wait.kind != .host_secret or wait.sequence != request.wait_sequence or self.snapshot.state != .running or self.snapshot.input_handed_off or self.snapshot.remote_effect_unknown) return error.InputNotExpected;
        if (action == .begin) {
            if (self.last_input_sequence == request.input_sequence) {
                const prior = self.snapshot.input_receipt orelse return error.InputConflict;
                if (prior.kind != .host_secret or prior.wait_sequence != request.wait_sequence) return error.InputConflict;
                return prior;
            }
            if (request.input_sequence < self.last_input_sequence or self.input_inflight or self.tx.items.len != self.tx_offset or (self.snapshot.input_receipt != null and self.snapshot.input_receipt.?.stage == .awaiting_host_secret)) return error.InputConflict;
            self.last_input_sequence = request.input_sequence;
            self.snapshot.input_receipt = .{ .input_sequence = request.input_sequence, .wait_sequence = request.wait_sequence, .kind = .host_secret, .stage = .awaiting_host_secret };
            self.changed();
            return self.snapshot.input_receipt.?;
        }
        const prior = self.snapshot.input_receipt orelse return error.InputConflict;
        if (prior.input_sequence != request.input_sequence or prior.wait_sequence != request.wait_sequence or prior.kind != .host_secret) return error.InputConflict;
        if (action == .cancel and prior.stage == .queued) {
            if (!self.cancelInput()) return self.snapshot.input_receipt orelse error.InputConflict;
            if (self.snapshot.input_receipt.?.stage == .outcome_unknown) return self.snapshot.input_receipt.?;
        } else if (prior.stage != .awaiting_host_secret) return prior;
        var fence: [32]u8 = undefined;
        var epoch: [32]u8 = undefined;
        var wait_sequence: [32]u8 = undefined;
        var input_sequence: [32]u8 = undefined;
        const id = std.fmt.bytesToHex(request.grant.execution_id.bytes, .lower);
        const fields = [_][]const u8{ &id, dec(&fence, request.grant.fence), dec(&epoch, request.grant.input_epoch), dec(&wait_sequence, request.wait_sequence), dec(&input_sequence, request.input_sequence) };
        if (action == .cancel) {
            try self.send(&.{ "secret_cancel", fields[0], fields[1], fields[2], fields[3], fields[4] });
            self.tx_secret_channel = true;
            self.snapshot.input_receipt.?.stage = .cancelled_unsent;
            self.snapshot.input_wait = null;
        } else {
            const bytes = action.submit.bytes;
            if (bytes.len == 0 or bytes.len > 4096 or self.tx.items.len != self.tx_offset) return error.InvalidSecret;
            try self.sendSensitive(&.{ "secret", fields[0], fields[1], fields[2], fields[3], fields[4], bytes });
            self.snapshot.input_receipt.?.stage = .queued;
            self.input_expected_bytes = 0;
            self.input_inflight = true;
            self.tx_input = true;
            self.input_deadline = now + 5000;
        }
        self.changed();
        return self.snapshot.input_receipt.?;
    }
    /// Cancel queued bytes before releasing a grant. A partially written frame
    /// cannot be completed after revocation; close that private protocol.
    fn cancelInput(self: *Bridge) bool {
        // Native PTY input is a byte stream. Once a prefix was written, retain
        // only that original tail and block other producers until it drains.
        if (self.streamInputPending() and self.stream_offset == 0) {
            self.stream_len = 0;
            if (self.snapshot.input_receipt) |*receipt| receipt.stage = .cancelled_unsent;
        }
        if (self.tx_input and self.tx_offset > 0 and self.tx_offset < self.tx.items.len) {
            if (self.snapshot.input_receipt) |*receipt| receipt.stage = .outcome_unknown;
            self.disable();
            return false;
        }
        const unsent = self.tx_input and self.tx_offset == 0;
        if (self.tx_input) {
            self.clearTransmit();
            self.tx_offset = 0;
            self.tx_input = false;
        }
        if (!unsent and self.input_inflight and self.snapshot.input_receipt != null and self.snapshot.input_receipt.?.stage == .queued and self.tx.items.len == 0) {
            // A completely sent input without a consumption receipt stays
            // uncertain; no second frame or replacement key is emitted.
            self.snapshot.remote_effect_unknown = true;
        }
        if (self.snapshot.input_receipt) |*receipt| {
            if (receipt.stage == .awaiting_host_secret) receipt.stage = .cancelled_unsent else if (self.input_inflight and receipt.stage == .queued) receipt.stage = if (unsent) .cancelled_unsent else .outcome_unknown;
        }
        self.input_inflight = false;
        return true;
    }
    fn releaseHelper(self: *Bridge, grant: execution.Grant) !void {
        if (!self.input_capability or self.transport != null or self.snapshot.input_wait == null) return;
        var fence: [32]u8 = undefined;
        var epoch: [32]u8 = undefined;
        const id = std.fmt.bytesToHex(grant.execution_id.bytes, .lower);
        const secret_wait = self.snapshot.input_wait != null and self.snapshot.input_wait.?.kind == .host_secret;
        try self.send(&.{ "input_release", &id, dec(&fence, grant.fence), dec(&epoch, grant.input_epoch) });
        self.tx_secret_channel = secret_wait;
        self.snapshot.input_wait = null;
    }
    pub fn wakeCompleted(self: *Bridge) void {
        self.wake_pending = false;
        self.snapshot.native_wake_written = true;
        if (self.lease.draining and self.tx.items.len == self.tx_offset and !self.streamInputPending()) self.lease.draining = false;
        self.changed();
    }
    pub fn ordinaryInput(self: *Bridge) !void {
        try self.lease.ordinaryInput();
        if (self.transport != null) self.remote_ready = false;
        self.changed();
    }
    pub fn observationGrant(self: *const Bridge) ?execution.Grant {
        return self.observation_grant;
    }
    pub fn observes(self: *const Bridge, grant: execution.Grant) bool {
        return if (self.observation_grant) |current| std.meta.eql(current, grant) else false;
    }
    pub fn begin(self: *Bridge, request: execution.Request, now: i64) !void {
        if (!self.hello or self.disabled or (self.transport != null and !self.snapshot.interactive_execution)) return error.IntegrationUnavailable;
        if (self.transport != null) {
            if (request.output_scope != .session_interval) return error.UnsupportedOutputScope;
            if (!self.remote_ready) return error.InputConflict;
        }
        if (self.observation_grant != null or (self.last_execution != null and !self.snapshot.recording_settled) or self.lease.holder != null or self.snapshot.state == .running or self.snapshot.state == .output_draining or self.snapshot.state == .recording_sealing) return error.OperationBusy;
        try execution.validateCommand(request.command);
        if (!std.mem.eql(u8, &execution.digest(request.command), &request.command_hash)) return error.CommandHashMismatch;
        const command = try self.allocator.dupe(u8, request.command);
        errdefer self.allocator.free(command);
        const grant = try self.lease.acquire(request, now);
        self.last_grant = grant;
        if (self.transport != null) self.remote_ready = false;
        self.tx_submit = false;
        self.awaiting_submit_ack = false;
        errdefer self.lease.revoke(false);
        if (self.command) |old| self.allocator.free(old);
        self.command = command;
        self.last_execution = request.execution_id;
        self.captured.clearRetainingCapacity();
        self.captured_start = 0;
        self.captured_total = 0;
        self.command_hash = request.command_hash;
        var random: [32]u8 = undefined;
        std.c.arc4random_buf(&random, random.len);
        self.start_token = std.fmt.bytesToHex(random, .lower);
        std.c.arc4random_buf(&random, random.len);
        self.end_token = std.fmt.bytesToHex(random, .lower);
        self.start_frame_len = (try std.fmt.bufPrint(&self.start_frame, "\x1b]777;zerowork-exec-v1;{s};start\x07", .{self.start_token})).len;
        self.end_frame_len = (try std.fmt.bufPrint(&self.end_frame, "\x1b]777;zerowork-exec-v1;{s};end\x07", .{self.end_token})).len;
        self.start_registered = false;
        self.end_registered = false;
        self.start_seen = null;
        self.end_seen = null;
        self.start_recorded = false;
        self.end_recorded = false;
        self.shell_ready = false;
        self.boundary_deadline = now + 5000;
        self.started_monotonic = now;
        self.output_observations_clear = true;
        self.input_inflight = false;
        self.tx_input = false;
        self.last_input_sequence = 0;
        self.last_input_hash = @splat(0);
        self.input_expected_bytes = 0;
        self.snapshot = .{ .owner = self.owner, .completion_source = .private_protocol, .execution_id = request.execution_id, .command_hash = request.command_hash, .execution_fence = grant.fence, .execution_input_epoch = grant.input_epoch, .state = .preparing, .started_at = @import("../platform/realtime.zig").milliseconds(undefined), .revision = self.snapshot.revision +| 1, .interactive_execution = true, .grant = grant, .input_epoch = self.lease.input_epoch, .input_ready = false, .local_released = false, .output_scope = request.output_scope };
        self.observation_grant = grant;
    }
    /// Called only after RecordingStartBarrier has durably succeeded.
    pub fn prepared(self: *Bridge, recording_id: [32]u8, generation: u64, revision: u64, now: i64) !void {
        const grant = self.lease.holder orelse return error.StaleFence;
        try self.lease.check(grant, now);
        if (self.snapshot.state != .preparing) return error.InvalidExecutionStage;
        var fence: [32]u8 = undefined;
        var epoch: [32]u8 = undefined;
        const id = std.fmt.bytesToHex(grant.execution_id.bytes, .lower);
        try self.send(&.{ "prepare", &id, dec(&fence, grant.fence), dec(&epoch, grant.input_epoch), &self.start_token, @tagName(self.snapshot.output_scope) });
        self.snapshot.recording_id = recording_id;
        self.snapshot.recording_generation = generation;
        self.snapshot.manifest_revision = revision;
        self.snapshot.state = .awaiting_start_boundary;
        self.changed();
    }
    pub fn startPaired(self: *const Bridge) bool {
        return self.start_registered and self.start_seen != null and self.shell_ready and !self.start_recorded;
    }
    pub fn endPaired(self: *const Bridge) bool {
        return self.end_registered and self.end_seen != null and self.snapshot.process != null and !self.end_recorded;
    }
    pub fn startCommitted(self: *Bridge, revision: u64, now: i64) !void {
        const grant = self.lease.holder orelse return error.StaleFence;
        try self.lease.check(grant, now);
        if (!self.startPaired()) return error.InvalidExecutionStage;
        self.start_recorded = true;
        self.snapshot.start = self.start_seen;
        self.snapshot.manifest_revision = revision;
        var fence: [32]u8 = undefined;
        var epoch: [32]u8 = undefined;
        const id = std.fmt.bytesToHex(grant.execution_id.bytes, .lower);
        const hash = std.fmt.bytesToHex(self.command_hash, .lower);
        try self.send(&.{ "buffer", &id, dec(&fence, grant.fence), dec(&epoch, grant.input_epoch), &self.end_token, self.command.?, &hash });
        self.snapshot.state = .awaiting_accept;
        self.boundary_deadline = now + 5000;
        self.changed();
    }
    pub fn endCommitted(self: *Bridge, revision: u64) void {
        self.end_recorded = true;
        self.snapshot.end = self.end_seen;
        self.snapshot.manifest_revision = revision;
        self.snapshot.state = .recording_sealing;
        self.changed();
    }
    pub fn sealed(self: *Bridge, revision: u64) void {
        std.debug.assert(self.snapshot.output_scope == .exact);
        self.recordingCompleted(revision, .sealed);
    }
    pub fn intervalRecorded(self: *Bridge, revision: u64) void {
        std.debug.assert(self.snapshot.output_scope == .session_interval);
        self.snapshot.interval_saved = true;
        self.recordingCompleted(revision, .interval_recorded);
    }
    fn recordingCompleted(self: *Bridge, revision: u64, state: execution.State) void {
        self.snapshot.manifest_revision = revision;
        self.snapshot.state = state;
        self.snapshot.recording_settled = true;
        self.observation_grant = null;
        if (self.lease.holder != null) self.lease.revoke((self.tx_offset > 0 and self.tx_offset < self.tx.items.len) or self.wake_pending or self.awaiting_submit_ack or self.streamInputPending());
        self.changed();
    }
    pub fn fail(self: *Bridge, reason: []const u8, degraded: bool) void {
        // A later session failure cannot rewrite an already persisted receipt
        // for a foreground execution whose observer has completed.
        if (self.snapshot.recording_settled and (self.snapshot.state == .sealed or self.snapshot.state == .interval_recorded)) return;
        const helper_wait = self.snapshot.input_wait;
        const helper_grant = if (helper_wait != null) self.lease.holder else null;
        if (!self.cancelInput()) return;
        self.observation_grant = null;
        self.snapshot.input_wait = null;
        self.input_inflight = false;
        self.tx_input = false;
        self.snapshot.failure = reason;
        self.snapshot.recording_failed = self.snapshot.recording_failed or degraded;
        self.snapshot.remote_effect_unknown = self.snapshot.submit_sent;
        self.snapshot.state = if (degraded) .recording_degraded else if (self.snapshot.submit_sent) .outcome_unknown else .cancelled_unsent;
        self.lease.revoke((self.tx_offset > 0 and self.tx_offset < self.tx.items.len) or self.wake_pending or self.awaiting_submit_ack or self.streamInputPending());
        if (!self.lease.draining) {
            self.clearTransmit();
            self.tx_offset = 0;
            self.tx_submit = false;
        }
        if (helper_grant) |grant| if (!self.disabled and !self.lease.draining) {
            self.snapshot.input_wait = helper_wait;
            self.releaseHelper(grant) catch {};
            self.snapshot.input_wait = null;
        };
        self.changed();
    }
    pub fn failureSettled(self: *Bridge, revision: u64, failed: bool) void {
        self.snapshot.manifest_revision = revision;
        self.snapshot.recording_settled = true;
        self.snapshot.recording_failed = self.snapshot.recording_failed or failed;
        self.changed();
    }
    pub fn revoke(self: *Bridge, grant: execution.Grant, takeover: bool, now: i64) !void {
        try self.lease.check(grant, now);
        if (!self.cancelInput()) return;
        const had_wait = self.snapshot.input_wait != null;
        if (takeover) {
            self.snapshot.input_handed_off = true;
            if (self.snapshot.submit_sent) {
                // The original exact submit may already be in flight. Keep
                // only its authenticated observation/drain path; do not send
                // shell revoke, which would discard the real finish hooks.
                self.lease.revoke((self.tx_offset > 0 and self.tx_offset < self.tx.items.len) or self.wake_pending or self.awaiting_submit_ack or self.streamInputPending());
                if (!self.lease.draining) {
                    self.clearTransmit();
                    self.tx_offset = 0;
                    self.tx_submit = false;
                }
                if (had_wait) try self.releaseHelper(grant);
                self.snapshot.input_wait = null;
                self.changed();
                return;
            }
        }
        self.fail(if (takeover) "HandedToUser" else "Stopped", false);
        if (!self.lease.draining and !self.tx_secret_channel) {
            const id = std.fmt.bytesToHex(grant.execution_id.bytes, .lower);
            var fence: [32]u8 = undefined;
            var epoch: [32]u8 = undefined;
            try self.send(&.{ "revoke", &id, dec(&fence, grant.fence), dec(&epoch, grant.input_epoch) });
            // A revoke frame carries no user input and cannot submit a buffer.
        }
        self.changed();
    }
    fn pollSecret(self: *Bridge, pid: i32, now: i64) !void {
        const native = self.secret_native orelse return;
        var bytes: [8192]u8 = undefined; // metadata/ack only; secret input is outbound
        for (0..8) |_| {
            var count: usize = 0;
            switch (zw_local_secret_read(native, pid, &bytes, bytes.len, &count)) {
                0 => break,
                1 => try self.secret_rx.appendSlice(self.allocator, bytes[0..count]),
                2 => {
                    if (self.input_inflight and self.snapshot.input_receipt != null and self.snapshot.input_receipt.?.kind == .host_secret) return error.SecretConsumptionUnknown;
                    if (self.snapshot.input_wait != null and self.snapshot.input_wait.?.kind == .host_secret) {
                        _ = self.cancelInput();
                        self.snapshot.input_wait = null;
                        self.changed();
                    }
                    break;
                },
                3 => continue,
                else => return error.SecretChannelLost,
            }
            if (self.secret_rx.items.len > wire.max_frame + 8) return error.InvalidFrame;
            std.mem.swap(std.ArrayList(u8), &self.rx, &self.secret_rx);
            self.reading_secret = true;
            defer {
                self.reading_secret = false;
                std.mem.swap(std.ArrayList(u8), &self.rx, &self.secret_rx);
            }
            try self.consume(now);
        }
    }
    pub fn poll(self: *Bridge, pid: i32, now: i64) void {
        if (self.disabled) return;
        if (self.observation_grant != null) self.snapshot.elapsed_ms = @intCast(@max(0, now - self.started_monotonic));
        if (self.input_inflight and now >= self.input_deadline) {
            self.disable();
            return;
        }
        if (self.lease.holder != null and now >= self.lease.expires_at) self.fail("LeaseExpired", false);
        if (self.observation_grant != null and self.snapshot.state != .running and self.snapshot.state != .preparing and self.snapshot.state != .recording_sealing and now >= self.boundary_deadline) self.fail("ProtocolTimeout", false);
        if (self.snapshot.state == .running) self.pollSecret(pid, now) catch {
            self.disable();
            return;
        };
        self.consume(now) catch {
            self.disable();
            return;
        };
        var bytes: [8192]u8 = undefined;
        for (0..32) |_| {
            var count: usize = 0;
            switch (self.readPrivate(pid, &bytes, &count)) {
                0 => break,
                1 => self.rx.appendSlice(self.allocator, bytes[0..count]) catch {
                    self.disable();
                    return;
                },
                3 => {
                    if (self.hello or self.sequence != 0) {
                        self.disable();
                        return;
                    }
                },
                else => {
                    self.disable();
                    return;
                },
            }
            if (self.rx.items.len > wire.max_frame + 8) {
                self.disable();
                return;
            }
            self.consume(now) catch {
                self.disable();
                return;
            };
        }
        self.pollSecret(pid, now) catch {
            self.disable();
            return;
        };
        self.consume(now) catch {
            self.disable();
            return;
        };
        if (self.tx_offset < self.tx.items.len) {
            var count: usize = 0;
            const write_status = if (self.tx_secret_channel) zw_local_secret_write(self.secret_native orelse {
                self.disable();
                return;
            }, self.tx.items[self.tx_offset..].ptr, self.tx.items.len - self.tx_offset, &count) else self.writePrivate(self.tx.items[self.tx_offset..], &count);
            if (write_status < 0) {
                self.disable();
                return;
            }
            if (count > 0 and self.tx_submit) {
                self.snapshot.submit_sent = true;
                self.snapshot.submit_native_bytes += count;
                self.awaiting_submit_ack = true;
                self.changed();
            }
            if (self.tx_secret and count > 0) std.crypto.secureZero(u8, self.tx.items[self.tx_offset..][0..count]);
            self.tx_offset += count;
            if (self.tx_offset == self.tx.items.len) {
                self.clearTransmit();
                self.tx_offset = 0;
                self.tx_submit = false;
                self.tx_input = false;
                if (self.lease.draining and !self.wake_pending and !self.awaiting_submit_ack and !self.streamInputPending()) {
                    self.lease.draining = false;
                    self.changed();
                }
            }
        }
    }
    fn disable(self: *Bridge) void {
        if (self.transport) |t| t.close(t.context) else zw_local_execution_close(self.native.?);
        if (self.secret_native) |native| zw_local_secret_close(native);
        if (self.input_inflight) if (self.snapshot.input_receipt) |*receipt| if (receipt.stage == .queued) {
            receipt.stage = if (self.tx_input and self.tx_offset == 0) .cancelled_unsent else .outcome_unknown;
        };
        self.clearTransmit();
        self.tx_offset = 0;
        self.tx_submit = false;
        self.tx_input = false;
        self.input_inflight = false;
        self.disabled = true;
        self.hello = false;
        self.lease.draining = self.wake_pending or self.awaiting_submit_ack or self.streamInputPending();
        self.fail("IntegrationLost", false);
        self.snapshot.interactive_execution = false;
    }
    fn consume(self: *Bridge, now: i64) !void {
        while (self.rx.items.len >= 8) {
            const length = try std.fmt.parseInt(usize, self.rx.items[0..8], 16);
            if (length > wire.max_frame) return error.InvalidFrame;
            if (self.rx.items.len < length + 8) return;
            var fields: [16][]const u8 = undefined;
            const values = try wire.decode(self.rx.items[8..][0..length], &fields);
            self.event(values, now) catch |err| {
                if (err == error.SecretAckPending) return;
                return err;
            };
            const remaining = self.rx.items.len - length - 8;
            std.mem.copyForwards(u8, self.rx.items[0..remaining], self.rx.items[length + 8 ..]);
            self.rx.items.len = remaining;
        }
    }
    fn event(self: *Bridge, values: []const []const u8, now: i64) !void {
        if (values.len < 6 or !eq(values[0], "1") or try number(values[1]) != @backingInt(self.owner.session_id) or try number(values[2]) != self.owner.generation or !eq(values[3], self.nonce())) return error.UntrustedFrame;
        const sequence = try number(values[4]);
        if (sequence <= self.last_received) return error.StaleFrame;
        const kind = values[5];
        // Native secret acknowledgement and ordinary END use distinct local
        // streams. Buffer ordinary facts until the earlier secret ack arrives.
        if (!self.reading_secret and self.input_inflight and self.snapshot.input_receipt != null and self.snapshot.input_receipt.?.kind == .host_secret) return error.SecretAckPending;
        if (self.reading_secret and !eq(kind, "input_wait") and !eq(kind, "input_consumed")) return error.UnsupportedEvent;
        self.last_received = sequence;
        const fields = values[6..];
        if (eq(kind, "hello")) {
            if (self.hello or fields.len != 2 or !eq(fields[0], "5.9")) return error.UnsupportedIntegration;
            const native_secret = self.transport == null and eq(fields[1], "independent_cloexec_boundary_interval_input_secret_v4");
            if (native_secret and self.secret_native == null) self.secret_native = zw_local_secret_create(self.native.?);
            self.secret_capability = native_secret and self.secret_native != null;
            self.input_capability = native_secret or (self.transport == null and eq(fields[1], "independent_cloexec_boundary_interval_input_v3"));
            const supported = if (self.transport != null) eq(fields[1], "ssh_cloexec_boundary_interval_v1") else self.input_capability or eq(fields[1], "independent_cloexec_boundary_interval_v2");
            if (!supported) return error.UnsupportedIntegration;
            self.hello = true;
            // Remote hello alone is not readiness; require actual ZLE idle.
            self.snapshot.interactive_execution = self.transport == null;
            self.snapshot.state = if (self.transport == null) .idle else .unavailable;
            self.changed();
            return;
        }
        if (!self.hello) return error.UntrustedFrame;
        if (eq(kind, "idle")) {
            if (self.transport == null or fields.len != 3 or !eq(fields[0], "empty_line") or !eq(fields[1], "no_pending") or !eq(fields[2], "shell_foreground")) return error.UnsupportedEvent;
            self.remote_ready = true;
            self.snapshot.interactive_execution = true;
            if (self.last_execution == null) self.snapshot.state = .idle;
            self.changed();
            return;
        }
        // A native submit already in flight may finish after revocation. Its
        // matching acknowledgment authorizes only the original protocol wake,
        // never a new input grant or a successful completion.
        if (self.lease.holder == null and self.awaiting_submit_ack and eq(kind, "submitted")) {
            const old = self.last_grant orelse return error.WrongExecution;
            const old_id = std.fmt.bytesToHex(old.execution_id.bytes, .lower);
            if (fields.len != 3 or !eq(fields[0], &old_id) or try number(fields[1]) != old.fence or try number(fields[2]) != old.input_epoch) return error.WrongExecution;
            self.awaiting_submit_ack = false;
            self.wake_pending = true;
            self.snapshot.submit_ack_sequence = sequence;
            self.lease.draining = true;
            self.changed();
            return;
        }
        // A known handoff retains the original observer identity, without
        // accepting any event which could authorize more input.
        const grant = self.observation_grant orelse return;
        if (self.lease.holder != null) try self.lease.check(grant, now);
        if (eq(kind, "revoked")) {
            self.fail("ShellRevoked", false);
            return;
        }
        const id = std.fmt.bytesToHex(grant.execution_id.bytes, .lower);
        if (fields.len < 1 or !eq(fields[0], &id)) return error.WrongExecution;
        if (eq(kind, "rejected")) {
            if (fields.len == 2 and std.mem.startsWith(u8, fields[1], "output_observation_")) self.observeOutput(try number(fields[1]["output_observation_".len..]));
            const reason = if (fields.len != 2) "InputConflict" else if (eq(fields[1], "output_observation_1")) "ConcurrentOutputObserved" else if (eq(fields[1], "output_observation_4")) "OutputProcessIdentityUnknown" else if (eq(fields[1], "output_observation_5")) "OutputDescriptorsUnknown" else if (eq(fields[1], "output_observation_6")) "OutputDescriptorIdentityUnknown" else if (eq(fields[1], "output_observation_7")) "OutputObservationDeadline" else if (std.mem.startsWith(u8, fields[1], "output_observation_")) "OutputObservationUnknown" else if (eq(fields[1], "stale_buffer")) "ShellBufferConflict" else if (eq(fields[1], "stale_submit")) "ShellSubmitConflict" else if (eq(fields[1], "incomplete_syntax")) "IncompleteSyntax" else "InputConflict";
            self.fail(reason, false);
            return;
        }
        if (fields.len < 2 or try number(fields[1]) != grant.fence) return error.StaleFence;
        if (eq(kind, "output_observation")) {
            if (fields.len != 3 or self.snapshot.state != .awaiting_start_boundary) return error.InvalidExecutionStage;
            self.observeOutput(try number(fields[2]));
        } else if (eq(kind, "input_wait")) {
            if (!self.input_capability or self.transport != null or fields.len != 6 or self.snapshot.state != .running or try number(fields[2]) != grant.input_epoch or try number(fields[5]) != 4096) return error.UnsupportedInteraction;
            const wait_kind: @TypeOf(@as(execution.InputWait, undefined).kind) = if (!self.reading_secret and eq(fields[4], "controlled_line")) .controlled_line else if (self.reading_secret and self.secret_capability and eq(fields[4], "host_secret")) .host_secret else return error.UnsupportedInteraction;
            if (self.lease.holder == null) return; // observer never grants input
            const wait_sequence = try number(fields[3]);
            if (wait_sequence == 0 or wait_sequence >= terminal_stream_wait_sequence or wait_sequence <= self.last_wait_sequence or self.snapshot.input_wait != null or self.input_inflight) return error.InputConflict;
            self.last_wait_sequence = wait_sequence;
            self.input_buffered_bytes = 0;
            self.snapshot.input_wait = .{ .sequence = wait_sequence, .kind = wait_kind };
        } else if (eq(kind, "input_consumed")) {
            if (!self.input_capability or self.transport != null or fields.len != 7 or self.snapshot.state != .running or try number(fields[2]) != grant.input_epoch) return error.UnsupportedInteraction;
            const prior = self.snapshot.input_receipt orelse return error.InputConflict;
            if ((prior.kind == .host_secret) != self.reading_secret) return error.UnsupportedEvent;
            if (try number(fields[3]) != prior.wait_sequence or try number(fields[4]) != prior.input_sequence or !eq(fields[5], @tagName(prior.kind)) or try number(fields[6]) != self.input_expected_bytes) return error.InputConflict;
            if (self.lease.holder == null and !self.input_inflight) return;
            if (!self.input_inflight or prior.stage != .queued) return error.InputConflict;
            self.input_inflight = false;
            self.snapshot.input_receipt = .{ .input_sequence = prior.input_sequence, .wait_sequence = prior.wait_sequence, .kind = prior.kind, .stage = .consumed, .accepted_bytes = self.input_expected_bytes };
            if (prior.kind == .enter or prior.kind == .host_secret) self.snapshot.input_wait = null else self.input_buffered_bytes += self.input_expected_bytes;
        } else if (eq(kind, "ready")) {
            if (fields.len != 3 or try number(fields[2]) != grant.input_epoch or self.snapshot.state != .awaiting_start_boundary) return error.InvalidExecutionStage;
            self.shell_ready = true;
        } else if (eq(kind, "boundary")) {
            if (fields.len != 4) return error.InvalidFrame;
            if (eq(fields[2], "start") and eq(fields[3], &self.start_token) and !self.start_registered) self.start_registered = true else if (eq(fields[2], "end") and eq(fields[3], &self.end_token) and !self.end_registered) self.end_registered = true else return error.InvalidBoundary;
        } else if (eq(kind, "accepted")) {
            if (self.lease.holder == null) return error.StaleFence;
            const hash = std.fmt.bytesToHex(self.command_hash, .lower);
            if (fields.len != 5 or self.snapshot.state != .awaiting_accept or try number(fields[2]) != grant.input_epoch or !eq(fields[3], &hash) or !eq(fields[4], self.command.?)) return error.BufferMismatch;
            self.snapshot.command_accepted = true;
            self.snapshot.accepted_sequence = sequence;
            var fence: [32]u8 = undefined;
            var epoch: [32]u8 = undefined;
            try self.send(&.{ "submit", &id, dec(&fence, grant.fence), dec(&epoch, grant.input_epoch), &hash });
            // A successful queue is not a program-consumption receipt. Once a
            // submit may reach the shell, a lost reply is always unknown.
            self.tx_submit = true;
            self.snapshot.submit_queued = true;
            self.snapshot.submit_sequence = self.sequence;
            self.snapshot.state = .awaiting_submit;
        } else if (eq(kind, "submitted")) {
            if (fields.len != 3 or self.snapshot.state != .awaiting_submit or try number(fields[2]) != grant.input_epoch) return error.InvalidExecutionStage;
            self.awaiting_submit_ack = false;
            self.snapshot.submit_ack_sequence = sequence;
            self.wake_pending = true;
        } else if (eq(kind, "started")) {
            if (fields.len != 2 or self.snapshot.state != .awaiting_submit) return error.InvalidExecutionStage;
            self.snapshot.state = .running;
        } else if (eq(kind, "finished")) {
            if (fields.len != 4 or self.snapshot.state != .running) return error.InvalidExecutionStage;
            const code = try number(fields[2]);
            if (code > 255) return error.InvalidFrame;
            self.snapshot.process = .{ .exit_code = @intCast(code), .foreground_finished = true, .background_jobs = eq(fields[3], "1"), .background_jobs_unknown = !eq(fields[3], "0") and !eq(fields[3], "1") };
            self.observeOutput(try number(fields[3]));
            self.snapshot.state = .output_draining;
            _ = self.cancelInput();
            self.snapshot.input_wait = null;
            self.input_inflight = false;
            self.boundary_deadline = now + 5000;
            if (self.snapshot.output_scope == .exact and (self.snapshot.process.?.background_jobs or self.snapshot.process.?.background_jobs_unknown)) self.fail(outputObservationReason(try number(fields[3])), false);
        } else return error.UnsupportedEvent;
        self.changed();
    }
    fn observeOutput(self: *Bridge, code: u64) void {
        if (code == 1) {
            self.output_observations_clear = false;
            self.snapshot.output_attribution = .concurrent_observed;
            self.snapshot.output_attribution_reason = outputObservationReason(code);
        } else if (code != 0) {
            self.output_observations_clear = false;
            if (self.snapshot.output_attribution != .concurrent_observed) {
                self.snapshot.output_attribution = .unverified;
                self.snapshot.output_attribution_reason = outputObservationReason(code);
            }
        } else if (self.output_observations_clear) {
            self.snapshot.output_attribution = .no_concurrent_owner_observed;
            self.snapshot.output_attribution_reason = null;
        }
    }
    fn clearTransmit(self: *Bridge) void {
        if (self.tx_secret) {
            std.crypto.secureZero(u8, self.tx.items);
            // ArrayList.clearRetainingCapacity poisons initialized bytes in
            // debug builds. Preserve the explicit sensitive-buffer zeroing.
            self.tx.items.len = 0;
        } else self.tx.clearRetainingCapacity();
        self.tx_secret = false;
        self.tx_secret_channel = false;
    }
    /// A sensitive frame is encoded into one bounded stack buffer. The generic
    /// encoder owns a temporary growable body and must never see secret bytes.
    fn sendSensitive(self: *Bridge, fields: []const []const u8) !void {
        if (self.tx.items.len != self.tx_offset or fields.len > 11) return error.InputConflict;
        var frame: [8192]u8 = undefined;
        defer std.crypto.secureZero(u8, &frame);
        var session: [32]u8 = undefined;
        var generation: [32]u8 = undefined;
        var sequence: [32]u8 = undefined;
        var length_buffer: [24]u8 = undefined;
        var all: [16][]const u8 = undefined;
        if (self.sequence == std.math.maxInt(u64)) return error.RevisionExhausted;
        const next_sequence = self.sequence + 1;
        all[0] = "1";
        all[1] = dec(&session, @backingInt(self.owner.session_id));
        all[2] = dec(&generation, self.owner.generation);
        all[3] = self.nonce();
        all[4] = dec(&sequence, next_sequence);
        @memcpy(all[5..][0..fields.len], fields);
        var position: usize = 8;
        for (all[0 .. fields.len + 5]) |value| {
            const prefix = try std.fmt.bufPrint(&length_buffer, "{d}:", .{value.len});
            if (prefix.len + value.len + 1 > frame.len - position) return error.FrameLimit;
            @memcpy(frame[position..][0..prefix.len], prefix);
            position += prefix.len;
            @memcpy(frame[position..][0..value.len], value);
            position += value.len;
            frame[position] = ',';
            position += 1;
        }
        _ = try std.fmt.bufPrint(frame[0..8], "{x:0>8}", .{position - 8});
        // No payload exists in an old allocation when capacity is grown.
        try self.tx.ensureUnusedCapacity(self.allocator, position);
        self.tx.appendSliceAssumeCapacity(frame[0..position]);
        self.tx_secret = true;
        self.tx_secret_channel = true;
        self.sequence = next_sequence;
    }
    fn send(self: *Bridge, fields: []const []const u8) !void {
        if (self.tx_secret) return error.InputConflict;
        if (self.tx.items.len - self.tx_offset > 128 * 1024) return error.ProtocolQueueFull;
        var session: [32]u8 = undefined;
        var generation: [32]u8 = undefined;
        var sequence: [32]u8 = undefined;
        var all: [16][]const u8 = undefined;
        self.sequence += 1;
        all[0] = "1";
        all[1] = dec(&session, @backingInt(self.owner.session_id));
        all[2] = dec(&generation, self.owner.generation);
        all[3] = self.nonce();
        all[4] = dec(&sequence, self.sequence);
        @memcpy(all[5..][0..fields.len], fields);
        const frame = try wire.encode(self.allocator, all[0 .. fields.len + 5]);
        defer self.allocator.free(frame);
        try self.tx.appendSlice(self.allocator, frame);
    }
    /// Bounded streaming filter. Both channel orders are accepted; stripping a
    /// host-minted token never by itself grants a completion receipt.
    pub fn output(self: *Bridge, bytes: []const u8, sink: Sink) void {
        var cursor: usize = 0;
        while (cursor < bytes.len) {
            if (self.output_pending_len == 0) {
                const next = if (self.start_frame_len == 0) bytes.len else if (std.mem.indexOfScalarPos(u8, bytes, cursor, 0x1b)) |index| index else bytes.len;
                if (next > cursor) {
                    sink.output(sink.context, bytes[cursor..next], self.raw_received);
                    self.raw_received += next - cursor;
                    cursor = next;
                    if (cursor == bytes.len) break;
                }
            }
            const byte = bytes[cursor];
            cursor += 1;
            if (self.output_pending_len == 0) self.output_pending_start = self.raw_received;
            self.raw_received += 1;
            self.output_pending[self.output_pending_len] = byte;
            self.output_pending_len += 1;
            while (self.output_pending_len > 0) {
                const pending = self.output_pending[0..self.output_pending_len];
                const start = self.start_frame[0..self.start_frame_len];
                const end = self.end_frame[0..self.end_frame_len];
                if (start.len > 0 and std.mem.eql(u8, pending, start)) {
                    if (self.start_seen == null) self.start_seen = .{ .raw_offset = self.raw_received, .sequence = 1 } else self.fail("DuplicateStartBoundary", false);
                    if (sink.boundary) |callback| if (self.start_seen) |position| callback(sink.context, .start, position);
                    self.output_pending_len = 0;
                    break;
                }
                if (end.len > 0 and std.mem.eql(u8, pending, end)) {
                    if (self.end_seen == null and self.start_seen != null) self.end_seen = .{ .raw_offset = self.output_pending_start, .sequence = 2 } else self.fail("UnexpectedEndBoundary", false);
                    if (sink.boundary) |callback| if (self.end_seen) |position| callback(sink.context, .end, position);
                    self.output_pending_len = 0;
                    break;
                }
                if ((start.len > 0 and std.mem.startsWith(u8, start, pending)) or (end.len > 0 and std.mem.startsWith(u8, end, pending))) break;
                // Flush a whole unmatched prefix, keeping only a possible ESC
                // suffix. Every emitted slice carries its original raw start.
                var keep: usize = 0;
                for (1..pending.len) |length| {
                    const suffix = pending[pending.len - length ..];
                    if ((start.len > 0 and std.mem.startsWith(u8, start, suffix)) or (end.len > 0 and std.mem.startsWith(u8, end, suffix))) keep = length;
                }
                const emit = pending.len - keep;
                sink.output(sink.context, pending[0..emit], self.output_pending_start);
                std.mem.copyForwards(u8, &self.output_pending, pending[emit..]);
                self.output_pending_start += emit;
                self.output_pending_len = keep;
                if (keep == 0) break;
            }
        }
    }
    pub fn capture(self: *Bridge, bytes: []const u8) void {
        if (self.observation_grant == null or self.start_seen == null or self.end_seen != null or bytes.len == 0) return;
        const max_bytes = 64 * 1024;
        self.captured_total += bytes.len;
        self.snapshot.output_received = self.captured_total;
        self.snapshot.revision +|= 1;
        if (bytes.len >= max_bytes) {
            self.captured.clearRetainingCapacity();
            self.captured.appendSlice(self.allocator, bytes[bytes.len - max_bytes ..]) catch {
                self.captured_start = self.captured_total;
                return;
            };
        } else {
            const remove = self.captured.items.len + bytes.len -| max_bytes;
            if (remove > 0) {
                std.mem.copyForwards(u8, self.captured.items, self.captured.items[remove..]);
                self.captured.items.len -= remove;
            }
            self.captured.appendSlice(self.allocator, bytes) catch {
                self.captured.clearRetainingCapacity();
                self.captured_start = self.captured_total;
                return;
            };
        }
        self.captured_start = self.captured_total - self.captured.items.len;
    }
    pub fn readOutput(self: *const Bridge, id: identity.ExecutionId, allocator: std.mem.Allocator, cursor: u64, max_bytes: usize) !execution.Output {
        const current = self.last_execution orelse return error.ExecutionNotFound;
        if (!current.eql(id)) return error.ExecutionNotFound;
        if (cursor > self.captured_total) return error.InvalidCursor;
        const start = @max(cursor, self.captured_start);
        const index: usize = @intCast(start - self.captured_start);
        const count = @min(max_bytes, self.captured.items.len - index);
        return .{ .bytes = try allocator.dupe(u8, self.captured.items[index..][0..count]), .start_cursor = start, .next_cursor = start + count, .gap = cursor < self.captured_start, .truncated = index + count < self.captured.items.len };
    }
    pub fn flushOutput(self: *Bridge, sink: Sink) void {
        if (self.output_pending_len != 0) sink.output(sink.context, self.output_pending[0..self.output_pending_len], self.output_pending_start);
        self.output_pending_len = 0;
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn outputObservationReason(code: u64) []const u8 {
    return switch (code) {
        1 => "BackgroundJobsObserved",
        4 => "OutputProcessIdentityUnknown",
        5 => "OutputDescriptorsUnknown",
        6 => "OutputDescriptorIdentityUnknown",
        7 => "OutputObservationDeadline",
        else => "BackgroundJobsUnknown",
    };
}
fn number(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10);
}
fn dec(buffer: []u8, value: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch unreachable;
}

test "execution native submit drain accepts only its old private acknowledgment without restoring the fence" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(921), .generation = 2 };
    var edit = try @import("trusted_edit.zig").Bridge.init(a, owner);
    defer edit.deinit();
    var bridge = Bridge.init(a, owner, edit.native);
    defer bridge.deinit();
    const grant: execution.Grant = .{ .execution_id = .generate(), .task_id = .generate(), .fence = 8, .input_epoch = 2, .ownership_revision = 1 };
    bridge.hello = true;
    bridge.last_grant = grant;
    bridge.lease = .{ .fence = 8, .input_epoch = 2, .holder = grant, .expires_at = 10000 };
    bridge.snapshot.state = .awaiting_submit;
    bridge.snapshot.submit_sent = true;
    bridge.snapshot.submit_native_bytes = 17;
    bridge.awaiting_submit_ack = true;
    bridge.fail("Stopped", false);
    try std.testing.expect(bridge.lease.holder == null and bridge.lease.draining and !bridge.snapshot.input_ready);
    const id = std.fmt.bytesToHex(grant.execution_id.bytes, .lower);
    const nonce = std.mem.span(zw_local_edit_nonce(edit.native));
    const fields: []const []const u8 = &.{ "1", "921", "2", nonce, "1", "submitted", &id, "8", "2" };
    try bridge.event(fields, 20);
    try std.testing.expect(bridge.wake_pending and !bridge.awaiting_submit_ack and bridge.lease.holder == null);
    try std.testing.expect(!bridge.snapshot.input_ready and bridge.snapshot.state == .outcome_unknown);
    bridge.wakeCompleted();
    try std.testing.expect(bridge.snapshot.input_ready and bridge.snapshot.local_released and bridge.snapshot.remote_effect_unknown);
    try std.testing.expect(bridge.snapshot.state == .outcome_unknown and bridge.snapshot.process == null);
    try std.testing.expectError(error.StaleFence, bridge.lease.check(grant, 20));
    try std.testing.expectError(error.StaleFrame, bridge.event(fields, 20));
    try bridge.event(&.{ "1", "921", "2", nonce, "2", "started", &id, "8" }, 20);
    try std.testing.expect(bridge.snapshot.state == .outcome_unknown and bridge.lease.holder == null);
}

test "execution user input handoff preserves authenticated read-only finish and output without authorizing new input" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(922), .generation = 1 };
    var edit = try @import("trusted_edit.zig").Bridge.init(a, owner);
    defer edit.deinit();
    var bridge = Bridge.init(a, owner, edit.native);
    defer bridge.deinit();
    const command = "true";
    const request: execution.Request = .{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) };
    bridge.hello = true;
    try bridge.begin(request, 1);
    const grant = bridge.lease.holder.?;
    bridge.snapshot.state = .running;
    bridge.snapshot.submit_sent = true;
    bridge.start_seen = .{ .raw_offset = 10, .sequence = 1, .event_sequence = 2 };
    try bridge.revoke(grant, true, 2);
    try std.testing.expect(bridge.snapshot.input_handed_off and bridge.snapshot.state == .running);
    try std.testing.expect(bridge.snapshot.grant == null and bridge.snapshot.input_ready and bridge.snapshot.local_released);
    try std.testing.expect(!bridge.snapshot.remote_effect_unknown and bridge.snapshot.failure == null and bridge.snapshot.process == null);
    try std.testing.expect(bridge.observes(grant) and bridge.tx.items.len == 0);
    try std.testing.expectError(error.StaleFence, bridge.renew(grant, 3));
    try bridge.ordinaryInput();
    var fresh = request;
    fresh.execution_id = .generate();
    fresh.expected_input_epoch = bridge.lease.input_epoch;
    try std.testing.expectError(error.OperationBusy, bridge.begin(fresh, 3));
    bridge.capture("observed after handoff");
    var output = try bridge.readOutput(request.execution_id, a, 0, 1024);
    defer output.deinit(a);
    try std.testing.expectEqualStrings("observed after handoff", output.bytes);
    const id = std.fmt.bytesToHex(grant.execution_id.bytes, .lower);
    const nonce = std.mem.span(zw_local_edit_nonce(edit.native));
    var fence: [32]u8 = undefined;
    try bridge.event(&.{ "1", "922", "1", nonce, "1", "finished", &id, dec(&fence, grant.fence), "7", "0" }, 20);
    try std.testing.expect(bridge.snapshot.process.?.exit_code == 7 and bridge.snapshot.process.?.foreground_finished);
    try std.testing.expect(bridge.snapshot.state == .output_draining and !bridge.snapshot.remote_effect_unknown);
    bridge.end_seen = .{ .raw_offset = 40, .sequence = 2, .event_sequence = 4 };
    bridge.end_registered = true;
    try std.testing.expect(bridge.endPaired());
    bridge.endCommitted(2);
    bridge.intervalRecorded(3);
    try std.testing.expect(bridge.snapshot.interval_saved and bridge.snapshot.state == .interval_recorded and bridge.snapshot.input_handed_off and !bridge.snapshot.remote_effect_unknown);
    // This fixture submitted only a command, never an interaction request.
    // Handoff must not manufacture a cancelled input receipt.
    try std.testing.expect(bridge.snapshot.input_receipt == null);
    bridge.fail("LaterSessionRecordingFailure", true);
    try std.testing.expect(bridge.snapshot.interval_saved and bridge.snapshot.state == .interval_recorded and bridge.snapshot.failure == null);
    try bridge.begin(fresh, 30);
    try std.testing.expect(bridge.snapshot.execution_fence > grant.fence and !bridge.snapshot.input_handed_off);
    bridge.snapshot.submit_sent = true;
    bridge.snapshot.state = .running;
    try bridge.revoke(bridge.lease.holder.?, true, 31);
    bridge.fail("IntegrationLost", false);
    try std.testing.expect(bridge.snapshot.input_handed_off and bridge.snapshot.remote_effect_unknown and bridge.snapshot.state == .outcome_unknown);
    try std.testing.expect(bridge.observationGrant() == null and bridge.snapshot.process == null and bridge.snapshot.end == null);
}

test "execution interval observations preserve unknown and concurrent facts across clean later snapshots" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(923), .generation = 1 };
    var edit = try @import("trusted_edit.zig").Bridge.init(a, owner);
    defer edit.deinit();
    var bridge = Bridge.init(a, owner, edit.native);
    defer bridge.deinit();
    const command = "true";
    const request: execution.Request = .{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) };
    bridge.hello = true;
    try bridge.begin(request, 1);
    try std.testing.expect(bridge.snapshot.output_scope == .session_interval);
    try bridge.prepared(@splat('a'), 1, 1, 2);
    try std.testing.expect(std.mem.indexOf(u8, bridge.tx.items, "16:session_interval,") != null);
    const id = std.fmt.bytesToHex(request.execution_id.bytes, .lower);
    const nonce = std.mem.span(zw_local_edit_nonce(edit.native));
    var fence: [32]u8 = undefined;
    const fence_text = dec(&fence, bridge.lease.holder.?.fence);
    try bridge.event(&.{ "1", "923", "1", nonce, "1", "output_observation", &id, fence_text, "4" }, 3);
    try std.testing.expect(bridge.snapshot.state == .awaiting_start_boundary and bridge.snapshot.failure == null and !bridge.snapshot.remote_effect_unknown);
    try std.testing.expect(bridge.snapshot.output_attribution == .unverified);
    try std.testing.expectEqualStrings("OutputProcessIdentityUnknown", bridge.snapshot.output_attribution_reason.?);
    bridge.snapshot.state = .running;
    try bridge.event(&.{ "1", "923", "1", nonce, "2", "finished", &id, fence_text, "7", "0" }, 4);
    try std.testing.expect(bridge.snapshot.state == .output_draining and bridge.snapshot.process.?.exit_code == 7);
    try std.testing.expect(bridge.snapshot.output_attribution == .unverified and !bridge.snapshot.remote_effect_unknown);
    bridge.observeOutput(1);
    bridge.observeOutput(0);
    bridge.observeOutput(4);
    try std.testing.expect(bridge.snapshot.output_attribution == .concurrent_observed);
    try std.testing.expectEqualStrings("BackgroundJobsObserved", bridge.snapshot.output_attribution_reason.?);
}

test "execution exact foreground receipt remains unknown when output observation cannot finish" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(924), .generation = 1 };
    var edit = try @import("trusted_edit.zig").Bridge.init(a, owner);
    defer edit.deinit();
    var bridge = Bridge.init(a, owner, edit.native);
    defer bridge.deinit();
    const request: execution.Request = .{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = "true", .command_hash = execution.digest("true"), .output_scope = .exact };
    bridge.hello = true;
    try bridge.begin(request, 1);
    try bridge.prepared(@splat('b'), 1, 1, 2);
    try std.testing.expect(std.mem.indexOf(u8, bridge.tx.items, "5:exact,") != null);
    bridge.snapshot.state = .running;
    bridge.snapshot.submit_sent = true;
    const id = std.fmt.bytesToHex(request.execution_id.bytes, .lower);
    const nonce = std.mem.span(zw_local_edit_nonce(edit.native));
    var fence: [32]u8 = undefined;
    try bridge.event(&.{ "1", "924", "1", nonce, "1", "finished", &id, dec(&fence, bridge.lease.holder.?.fence), "3", "4" }, 3);
    try std.testing.expect(bridge.snapshot.state == .outcome_unknown and bridge.snapshot.remote_effect_unknown);
    try std.testing.expect(bridge.snapshot.process.?.foreground_finished and bridge.snapshot.process.?.exit_code == 3 and bridge.snapshot.process.?.background_jobs_unknown);
    try std.testing.expect(!bridge.snapshot.interval_saved and bridge.snapshot.end == null);
}

test "execution controlled input capability and revocation discard unsent frames and never finish a partial tail" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(926), .generation = 1 };
    var edit = try @import("trusted_edit.zig").Bridge.init(a, owner);
    defer edit.deinit();
    var bridge = Bridge.init(a, owner, edit.native);
    defer bridge.deinit();
    const request: execution.Request = .{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = "zerowork_read", .command_hash = execution.digest("zerowork_read") };
    bridge.hello = true;
    try bridge.begin(request, 1);
    bridge.snapshot.state = .running;
    bridge.snapshot.submit_sent = true;
    bridge.snapshot.input_wait = .{ .sequence = 4 };
    const input: execution.InputRequest = .{ .grant = bridge.lease.holder.?, .wait_sequence = 4, .input_sequence = 1, .kind = .text, .text = "unsent-private-line" };
    try std.testing.expectError(error.UnsupportedInteraction, bridge.sendInput(input, 2));
    bridge.input_capability = true;
    _ = try bridge.sendInput(input, 2);
    try std.testing.expect(bridge.input_inflight and bridge.tx_input);
    try bridge.revoke(input.grant, true, 3);
    try std.testing.expect(bridge.snapshot.input_wait == null and bridge.lease.holder == null and bridge.snapshot.input_handed_off and !bridge.snapshot.remote_effect_unknown);
    const cancelled_input = bridge.snapshot.input_receipt orelse return error.MissingInputReceipt;
    try std.testing.expect(cancelled_input.stage == .cancelled_unsent and cancelled_input.input_sequence == input.input_sequence and cancelled_input.wait_sequence == input.wait_sequence and cancelled_input.kind == .text);
    try std.testing.expect(std.mem.indexOf(u8, bridge.tx.items, input.text) == null);
    try std.testing.expectError(error.StaleFence, bridge.sendInput(input, 4));
    var partial = Bridge.init(a, owner, edit.native);
    defer partial.deinit();
    partial.hello = true;
    partial.input_capability = true;
    try partial.begin(request, 10);
    partial.snapshot.state = .running;
    partial.snapshot.submit_sent = true;
    partial.snapshot.input_wait = .{ .sequence = 5 };
    _ = try partial.sendInput(.{ .grant = partial.lease.holder.?, .wait_sequence = 5, .input_sequence = 2, .kind = .text, .text = "partial-line" }, 11);
    partial.tx_offset = 1;
    partial.fail("LeaseExpired", false);
    try std.testing.expect(partial.disabled and partial.tx.items.len == 0 and partial.snapshot.remote_effect_unknown and partial.lease.holder == null and partial.snapshot.input_receipt.?.stage == .outcome_unknown);
}

test "execution secret queue is host only bounded and zeroed before an unsent cancel" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(927), .generation = 1 };
    var edit = try @import("trusted_edit.zig").Bridge.init(a, owner);
    defer edit.deinit();
    var bridge = Bridge.init(a, owner, edit.native);
    defer bridge.deinit();
    bridge.hello = true;
    bridge.input_capability = true;
    bridge.secret_capability = true;
    const command = "zerowork_secret_consume";
    try bridge.begin(.{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) }, 1);
    bridge.snapshot.state = .running;
    bridge.snapshot.submit_sent = true;
    bridge.snapshot.input_wait = .{ .sequence = 6, .kind = .host_secret };
    const request: execution.InputRequest = .{ .grant = bridge.lease.holder.?, .wait_sequence = 6, .input_sequence = 8, .kind = .host_secret };
    const waiting = try bridge.secret(.{ .begin = request }, 2);
    try std.testing.expect(waiting.stage == .awaiting_host_secret);
    var bytes: [512]u8 = @splat('S');
    defer std.crypto.secureZero(u8, &bytes);
    _ = try bridge.secret(.{ .submit = .{ .request = request, .bytes = &bytes } }, 3);
    const position = std.mem.indexOf(u8, bridge.tx.items, &bytes).?;
    const transmitted = bridge.tx.items.ptr;
    try std.testing.expect(bridge.tx_secret and bridge.tx_input and bridge.input_inflight);
    const cancelled = try bridge.secret(.{ .cancel = request }, 4);
    try std.testing.expect(cancelled.stage == .cancelled_unsent and bridge.snapshot.input_wait == null and !bridge.snapshot.remote_effect_unknown);
    try std.testing.expect(std.mem.allEqual(u8, transmitted[position + 16 ..][0 .. bytes.len - 16], 0));
    try std.testing.expect(std.mem.indexOf(u8, bridge.tx.items, &bytes) == null);
    try std.testing.expectError(error.InputNotExpected, bridge.secret(.{ .submit = .{ .request = request, .bytes = &bytes } }, 5));
}

test "execution terminal stream retains one partial native tail through takeover without consumption claims" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(928), .generation = 1 };
    var edit = try @import("trusted_edit.zig").Bridge.init(a, owner);
    defer edit.deinit();
    var bridge = Bridge.init(a, owner, edit.native);
    defer bridge.deinit();
    bridge.hello = true;
    const command = "builtin read -r REPLY";
    try bridge.begin(.{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) }, 1);
    bridge.snapshot.state = .running;
    bridge.snapshot.submit_sent = true;
    const grant = bridge.lease.holder.?;
    const request: execution.InputRequest = .{ .grant = grant, .wait_sequence = terminal_stream_wait_sequence, .input_sequence = 1, .kind = .text, .text = "ordinary-line" };
    try std.testing.expect(bridge.inputAvailability().?.kind == .terminal_stream);
    _ = try bridge.sendInput(request, 2);
    bridge.streamInputWritten(3);
    try std.testing.expect(bridge.snapshot.input_receipt.?.stage == .queued and bridge.snapshot.input_receipt.?.accepted_bytes == 0);
    try bridge.revoke(grant, true, 3);
    try std.testing.expect(bridge.lease.holder == null and bridge.lease.draining and bridge.snapshot.input_handed_off);
    try std.testing.expect(bridge.observationGrant() != null and bridge.inputAvailability() == null);
    try std.testing.expectError(error.TerminalControlled, bridge.ordinaryInput());
    try std.testing.expectEqualStrings("inary-line", bridge.streamInputBytes());
    try std.testing.expectError(error.StaleFence, bridge.sendInput(request, 4));
    bridge.streamInputWritten(bridge.streamInputBytes().len);
    try std.testing.expect(!bridge.lease.draining and !bridge.streamInputPending());
    try std.testing.expect(bridge.snapshot.input_receipt.?.stage == .written);
    try std.testing.expectEqual(request.text.len, bridge.snapshot.input_receipt.?.accepted_bytes);
    try bridge.ordinaryInput();
}

test "execution terminal stream cancels an unsent input on finish and preserves helper waits" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(929), .generation = 1 };
    var edit = try @import("trusted_edit.zig").Bridge.init(a, owner);
    defer edit.deinit();
    var bridge = Bridge.init(a, owner, edit.native);
    defer bridge.deinit();
    bridge.hello = true;
    const command = "builtin read -r REPLY";
    try bridge.begin(.{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) }, 1);
    bridge.snapshot.state = .running;
    bridge.snapshot.submit_sent = true;
    const grant = bridge.lease.holder.?;
    const request: execution.InputRequest = .{ .grant = grant, .wait_sequence = terminal_stream_wait_sequence, .input_sequence = 1, .kind = .text, .text = "must-not-replay" };
    _ = try bridge.sendInput(request, 2);
    _ = bridge.cancelInput();
    bridge.snapshot.state = .output_draining;
    try std.testing.expect(!bridge.streamInputPending() and bridge.snapshot.input_receipt.?.stage == .cancelled_unsent);
    try std.testing.expect(bridge.inputAvailability() == null);
    var next = request;
    next.input_sequence = 2;
    try std.testing.expectError(error.InputNotExpected, bridge.sendInput(next, 3));
    bridge.snapshot.state = .running;
    bridge.snapshot.input_wait = .{ .sequence = 1, .kind = .host_secret };
    try std.testing.expect(bridge.inputAvailability().?.kind == .host_secret);
    try std.testing.expectError(error.SecretMustUseHost, bridge.sendInput(next, 4));
}
