//! Cooperative shell events on the existing SSH PTY. These are observations,
//! not a private control channel or proof of the foreground process identity.
const std = @import("std");
const execution = @import("../host/terminal_execution.zig");
const identity = @import("../host/identity.zig");
const Queue = @import("input_queue.zig").InputQueue;
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    snapshot: execution.Snapshot,
    lease: execution.Lease = .{},
    command: ?[]u8 = null,
    captured: std.ArrayList(u8) = .empty,
    capture_start: u64 = 0,
    capture_total: u64 = 0,
    raw_received: u64 = 0,
    initialization_nonce: ?[32]u8 = null,
    initialization_expected: u64 = 0,
    initialization_ack: u64 = 0,
    initialization_ack_size: u64 = 0,
    initialization_restored: bool = false,
    initialization_echo: @import("shell_integration.zig").EchoFilter = .{},
    prompt_seen: bool = false,
    prompt_clean: bool = false,
    debug_start: bool = false,
    active: bool = false,
    start_pending: bool = false,
    end_pending: bool = false,
    queued_start: usize = 0,
    queued_end: ?usize = null,
    queued_length: usize = 0,
    start_deadline: i64 = 0,
    input_end: ?usize = null,
    input_start: usize = 0,
    input_bytes: usize = 0,
    last_input_sequence: u64 = 0,
    last_input_hash: [32]u8 = @splat(0),
    wait_sequence: u64 = 0,
    osc: [8192]u8 = undefined,
    osc_len: usize = 0,
    parse_state: enum { text, escape, osc, osc_escape, discard } = .text,
    const max_capture = 1024 * 1024;
    pub const Sink = struct {
        context: *anyopaque,
        output: *const fn (*anyopaque, []const u8, u64) void,
        boundary: *const fn (*anyopaque, execution.Boundary) execution.Boundary,
    };
    pub fn init(a: std.mem.Allocator, owner: identity.SessionHandle) Bridge {
        return .{ .allocator = a, .snapshot = .{ .owner = owner, .completion_source = .shell_reported, .input_ready = false, .failure = "ShellIntegrationPending" } };
    }
    pub fn deinit(self: *Bridge) void {
        if (self.command) |value| self.allocator.free(value);
        self.captured.deinit(self.allocator);
    }
    fn changed(self: *Bridge) void {
        self.snapshot.revision +|= 1;
        self.snapshot.input_epoch = self.lease.input_epoch;
        self.snapshot.grant = self.lease.holder;
        self.snapshot.lease_expires_at = self.lease.expires_at;
        self.snapshot.local_released = self.lease.holder == null and !self.lease.draining;
        // Handoff releases local keys while the foreground is still running.
        // A fresh AI command additionally waits for the next shell prompt.
        self.snapshot.input_ready = self.snapshot.local_released and
            (self.snapshot.input_handed_off or (!self.active and self.prompt_clean));
    }
    pub fn ordinaryInput(self: *Bridge) !void {
        try self.lease.ordinaryInput();
        self.prompt_clean = false;
        self.changed();
    }
    pub fn begin(self: *Bridge, request: execution.Request, now: i64) !void {
        if (!self.snapshot.interactive_execution) return error.IntegrationUnavailable;
        if (!self.prompt_clean or self.active) return error.InputConflict;
        if (self.snapshot.execution_id != null and !self.snapshot.recording_settled) return error.OperationBusy;
        if (request.output_scope != .session_interval) return error.UnsupportedOutputScope;
        try execution.validateCommand(request.command);
        // A key stream cannot safely represent a multi-line editor buffer or
        // TAB (readline completion) without shell-specific editing capability.
        if (std.mem.indexOfAny(u8, request.command, "\n\t") != null or request.command.len > 4094) return error.UnsupportedSyntax;
        if (!std.mem.eql(u8, &execution.digest(request.command), &request.command_hash)) return error.CommandHashMismatch;
        if (self.debug_start and std.mem.startsWith(u8, std.mem.trimStart(u8, request.command, " "), "(")) return error.UnsupportedSyntax;
        const command = try self.allocator.alloc(u8, request.command.len + 1);
        errdefer self.allocator.free(command);
        @memcpy(command[0..request.command.len], request.command);
        command[request.command.len] = '\n';
        const grant = try self.lease.acquire(request, now);
        if (self.command) |old| self.allocator.free(old);
        self.command = command;
        self.captured.clearRetainingCapacity();
        self.capture_start = 0;
        self.capture_total = 0;
        self.queued_end = null;
        self.start_deadline = 0;
        self.input_end = null;
        self.last_input_sequence = 0;
        self.start_pending = false;
        self.end_pending = false;
        self.active = true;
        self.prompt_clean = false;
        const revision = self.snapshot.revision;
        self.snapshot = .{ .owner = self.snapshot.owner, .completion_source = .shell_reported, .execution_id = request.execution_id, .command_hash = request.command_hash, .execution_fence = grant.fence, .execution_input_epoch = grant.input_epoch, .state = .preparing, .revision = revision, .interactive_execution = true, .local_released = false, .input_ready = false, .output_scope = .session_interval, .output_attribution = .unverified, .output_attribution_reason = "OutputProcessIdentityUnknown" };
        self.changed();
    }
    pub fn prepared(self: *Bridge, recording_id: [32]u8, generation: u64, revision: u64) void {
        self.snapshot.recording_id = recording_id;
        self.snapshot.recording_generation = generation;
        self.snapshot.manifest_revision = revision;
        self.snapshot.state = .awaiting_submit;
        self.changed();
    }
    pub fn enqueue(self: *Bridge, queue: *Queue) !void {
        if (self.snapshot.state != .awaiting_submit or self.snapshot.submit_sequence != 0 or self.queued_end != null or self.lease.holder == null) return;
        const command = self.command orelse return error.InvalidCommand;
        self.queued_start = queue.read_index.load(.acquire);
        try queue.push(command);
        self.queued_length = command.len;
        self.queued_end = queue.write_index.load(.acquire);
        self.snapshot.accepted_sequence = 1; // host admission, not shell acceptance
        self.snapshot.submit_sequence = 2;
        self.snapshot.submit_queued = true;
        self.changed();
    }
    pub fn written(self: *Bridge, queue: *const Queue, now: i64) void {
        const read = queue.read_index.load(.acquire);
        if (self.queued_end) |end| {
            const sent = @min(read -% self.queued_start, self.queued_length);
            if (sent != self.snapshot.submit_native_bytes) {
                self.snapshot.submit_native_bytes = sent;
                self.snapshot.submit_sent = sent != 0;
                self.changed();
            }
            if (read == end) {
                self.queued_end = null;
                self.snapshot.submit_queued = false;
                if (self.snapshot.start == null and self.start_deadline == 0) self.start_deadline = now + 5000;
                self.lease.draining = false;
                self.changed();
            }
        }
        if (self.input_end) |end| if (read == end) {
            self.input_end = null;
            if (self.snapshot.input_receipt) |*receipt| {
                receipt.stage = .written;
                receipt.accepted_bytes = self.input_bytes;
            }
            self.lease.draining = false;
            self.changed();
        };
        if (self.active and self.snapshot.start == null and self.start_deadline != 0 and now >= self.start_deadline) self.fail("ShellStartMissing");
        if (self.lease.holder != null and now >= self.lease.expires_at) self.handoff(queue, false);
        if (self.snapshot.started_at != 0 and self.snapshot.process == null) self.snapshot.elapsed_ms = @intCast(@max(0, now - self.snapshot.started_at));
    }
    pub fn renew(self: *Bridge, grant: execution.Grant, now: i64) !void {
        try self.lease.renew(grant, now);
        self.changed();
    }
    pub fn revoke(self: *Bridge, grant: execution.Grant, takeover: bool, queue: *Queue, write_inflight: bool, now: i64) !void {
        try self.lease.check(grant, now);
        if (!takeover and self.snapshot.submit_sent) return error.UnsupportedInteraction;
        // Only untouched, not-yet-native bytes can be cancelled. Once a native
        // call started, finish its exact buffer before admitting user keys.
        if (self.queued_end != null and self.snapshot.submit_native_bytes == 0 and !write_inflight) {
            try queue.consume(queue.pending());
            self.queued_end = null;
            self.snapshot.submit_queued = false;
        }
        if (self.input_end != null and queue.read_index.load(.acquire) == self.input_start and !write_inflight) {
            try queue.consume(queue.pending());
            self.input_end = null;
            if (self.snapshot.input_receipt) |*receipt| receipt.stage = .cancelled_unsent;
        }
        self.handoff(queue, write_inflight);
    }
    fn handoff(self: *Bridge, queue: *const Queue, write_inflight: bool) void {
        self.snapshot.input_handed_off = true;
        self.snapshot.input_wait = null;
        self.lease.revoke(write_inflight or queue.pending() != 0);
        if (!self.snapshot.submit_sent and self.queued_end == null) {
            self.active = false;
            self.snapshot.state = .cancelled_unsent;
            self.prompt_clean = true;
        } else if (self.snapshot.process == null) self.snapshot.state = .handed_off;
        self.changed();
    }
    pub fn sendInput(self: *Bridge, request: execution.InputRequest, queue: *Queue, now: i64) !execution.InputReceipt {
        try self.lease.check(request.grant, now);
        if (request.kind == .host_secret) return error.HostSecretUnavailable;
        if (request.input_sequence == 0 or request.wait_sequence == 0) return error.InvalidArguments;
        if (request.kind == .text) try execution.validateInput(request.text) else if (request.text.len != 0) return error.InvalidArguments;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(std.mem.asBytes(&request.wait_sequence));
        hash.update(@tagName(request.kind));
        hash.update(request.text);
        const digest = hash.finalResult();
        if (request.input_sequence == self.last_input_sequence) {
            if (!std.mem.eql(u8, &digest, &self.last_input_hash)) return error.InputConflict;
            return self.snapshot.input_receipt orelse error.InputConflict;
        }
        const wait = self.snapshot.input_wait orelse return error.InputNotExpected;
        if (request.input_sequence < self.last_input_sequence or request.wait_sequence != wait.sequence or self.input_end != null or queue.pending() != 0) return error.InputConflict;
        if (self.snapshot.state != .running or self.snapshot.input_handed_off or !self.active) return error.InputNotExpected;
        self.input_start = queue.read_index.load(.acquire);
        try queue.push(if (request.kind == .enter) "\n" else request.text);
        self.input_end = queue.write_index.load(.acquire);
        self.input_bytes = request.text.len;
        self.last_input_sequence = request.input_sequence;
        self.last_input_hash = digest;
        const receipt: execution.InputReceipt = .{ .input_sequence = request.input_sequence, .wait_sequence = request.wait_sequence, .kind = request.kind, .stage = .queued };
        self.snapshot.input_receipt = receipt;
        self.changed();
        return receipt;
    }
    pub fn fail(self: *Bridge, reason: []const u8) void {
        self.snapshot.interactive_execution = false;
        self.prompt_clean = false;
        if (self.snapshot.execution_id != null and self.snapshot.process == null) {
            self.snapshot.state = if (self.snapshot.submit_sent) .outcome_unknown else .cancelled_unsent;
            self.snapshot.remote_effect_unknown = self.snapshot.submit_sent;
            self.snapshot.failure = reason;
        } else if (self.snapshot.execution_id == null) {
            self.snapshot.failure = reason;
        } else if (!self.snapshot.recording_settled) {
            self.snapshot.state = .recording_degraded;
            self.snapshot.recording_failed = true;
            self.snapshot.failure = reason;
        }
        self.snapshot.input_wait = null;
        if (self.snapshot.input_receipt) |*receipt| if (receipt.stage == .queued) {
            receipt.stage = .outcome_unknown;
        };
        self.active = false;
        self.lease.revoke(self.queued_end != null or self.input_end != null);
        self.changed();
    }
    pub fn settled(self: *Bridge, revision: u64, failed: bool) void {
        self.snapshot.manifest_revision = revision;
        self.snapshot.recording_settled = true;
        self.snapshot.recording_failed = failed;
        self.changed();
    }
    pub fn recorded(self: *Bridge, revision: u64) void {
        self.snapshot.interval_saved = true;
        self.snapshot.state = .interval_recorded;
        self.settled(revision, false);
    }
    pub fn capture(self: *Bridge, bytes: []const u8) void {
        if (!self.active or self.snapshot.start == null or self.snapshot.end != null) return;
        self.capture_total +|= bytes.len;
        if (bytes.len >= max_capture) {
            self.captured.clearRetainingCapacity();
            self.captured.appendSlice(self.allocator, bytes[bytes.len - max_capture ..]) catch {
                self.captureLost();
                return;
            };
        } else {
            const drop = (self.captured.items.len + bytes.len) -| max_capture;
            if (drop != 0) {
                std.mem.copyForwards(u8, self.captured.items, self.captured.items[drop..]);
                self.captured.items.len -= drop;
            }
            self.captured.appendSlice(self.allocator, bytes) catch {
                self.captureLost();
                return;
            };
        }
        self.capture_start = self.capture_total - self.captured.items.len;
        self.snapshot.output_received = self.capture_total;
    }
    fn captureLost(self: *Bridge) void {
        self.captured.clearRetainingCapacity();
        self.capture_start = self.capture_total;
        self.snapshot.output_received = self.capture_total;
    }
    pub fn readOutput(self: *Bridge, id: identity.ExecutionId, a: std.mem.Allocator, cursor: u64, maximum: usize) !execution.Output {
        if (self.snapshot.execution_id == null or !self.snapshot.execution_id.?.eql(id)) return error.ExecutionNotFound;
        const start = @min(@max(cursor, self.capture_start), self.capture_total);
        const length = @min(@as(usize, @intCast(self.capture_total - start)), @min(maximum, 64 * 1024));
        const offset: usize = @intCast(start - self.capture_start);
        return .{ .bytes = try a.dupe(u8, self.captured.items[offset .. offset + length]), .start_cursor = start, .next_cursor = start + length, .gap = cursor < self.capture_start or cursor > self.capture_total, .truncated = start + length < self.capture_total };
    }
    pub fn output(self: *Bridge, bytes: []const u8, sink: Sink, now: i64) void {
        const ready = self.initialization_echo.feed(bytes) orelse return;
        self.outputReady(ready.bytes, sink, now);
        if (ready.remainder.len != 0) self.outputReady(ready.remainder, sink, now);
    }
    pub fn flushInitializationEcho(self: *Bridge, sink: Sink, now: i64) void {
        const bytes = self.initialization_echo.finish();
        if (bytes.len != 0) self.outputReady(bytes, sink, now);
    }
    fn outputReady(self: *Bridge, bytes: []const u8, sink: Sink, now: i64) void {
        const base = self.raw_received;
        var forwarded: usize = 0;
        for (bytes, 0..) |byte, index| {
            var complete = false;
            switch (self.parse_state) {
                .text => if (byte == 0x1b) {
                    self.parse_state = .escape;
                },
                .escape => {
                    self.parse_state = if (byte == ']') .osc else if (byte == 0x1b) .escape else .text;
                    self.osc_len = 0;
                },
                .osc => if (byte == 7) {
                    complete = true;
                    self.parse_state = .text;
                } else if (byte == 0x1b) {
                    self.parse_state = .osc_escape;
                } else if (self.osc_len < self.osc.len) {
                    self.osc[self.osc_len] = byte;
                    self.osc_len += 1;
                } else {
                    self.parse_state = .discard;
                },
                .osc_escape => {
                    complete = byte == '\\';
                    self.parse_state = .text;
                },
                .discard => if (byte == 7) {
                    self.parse_state = .text;
                } else if (byte == 0x1b) {
                    self.parse_state = .escape;
                },
            }
            if (complete) {
                sink.output(sink.context, bytes[forwarded .. index + 1], base + forwarded);
                forwarded = index + 1;
                self.event(self.osc[0..self.osc_len], base + forwarded, sink, now);
            }
        }
        if (forwarded < bytes.len) sink.output(sink.context, bytes[forwarded..], base + forwarded);
        self.raw_received = base + bytes.len;
    }
    fn event(self: *Bridge, frame: []const u8, offset: u64, sink: Sink, now: i64) void {
        if (frame.len < 5 or (frame.len > 5 and frame[5] != ';') or (!std.mem.startsWith(u8, frame, "133;") and !std.mem.startsWith(u8, frame, "633;"))) return;
        switch (frame[4]) {
            'P' => {
                const nonce = self.initialization_nonce orelse return;
                if (std.mem.startsWith(u8, frame, "133;P;zw_restored=")) {
                    if (std.mem.eql(u8, frame[18..], &nonce)) self.initialization_restored = true;
                    return;
                }
                if (!std.mem.startsWith(u8, frame, "133;P;zw_init=")) return;
                var parts = std.mem.splitScalar(u8, frame[14..], ';');
                if (!std.mem.eql(u8, parts.next() orelse return, &nonce)) return;
                const sequence = std.fmt.parseInt(u64, parts.next() orelse return, 10) catch return;
                const size = std.fmt.parseInt(u64, parts.next() orelse return, 10) catch return;
                if (parts.next() != null or sequence == 0 or sequence != self.initialization_expected or size > 128) return;
                self.initialization_ack = sequence;
                self.initialization_ack_size = size;
            },
            'A' => {
                if (self.active) self.fail("ShellCompletionMissing");
                if (std.mem.indexOf(u8, frame, "zw_start=debug") != null) self.debug_start = true;
                self.prompt_seen = true;
            },
            'B' => {
                if (!self.prompt_seen or self.active) return;
                self.prompt_seen = false;
                self.prompt_clean = true;
                self.snapshot.interactive_execution = true;
                if (self.snapshot.execution_id == null) {
                    self.snapshot.failure = null;
                    self.snapshot.state = .idle;
                }
                self.changed();
            },
            'C' => {
                self.prompt_clean = false;
                self.prompt_seen = false;
                if (!self.active or self.snapshot.start != null) {
                    self.changed();
                    return;
                }
                if (self.snapshot.submit_sequence == 0) {
                    self.fail("UnexpectedShellStart");
                    return;
                }
                const boundary: execution.Boundary = .{ .raw_offset = offset, .sequence = 1 };
                self.snapshot.start = sink.boundary(sink.context, boundary);
                self.start_pending = true;
                self.snapshot.started_at = now;
                if (!self.snapshot.input_handed_off) {
                    self.snapshot.state = .running;
                    self.wait_sequence +|= 1;
                    self.snapshot.input_wait = .{ .sequence = self.wait_sequence, .kind = .terminal_stream };
                }
                self.changed();
            },
            'D' => {
                if (!self.active) return;
                if (self.snapshot.start == null) {
                    self.fail("ShellStartMissing");
                    return;
                }
                var parts = std.mem.splitScalar(u8, if (frame.len > 6 and frame[5] == ';') frame[6..] else "", ';');
                const code = std.fmt.parseInt(u8, parts.first(), 10) catch {
                    self.fail("ShellExitStatusMissing");
                    return;
                };
                const boundary: execution.Boundary = .{ .raw_offset = offset, .sequence = 2 };
                self.snapshot.end = sink.boundary(sink.context, boundary);
                self.end_pending = true;
                self.snapshot.process = .{ .exit_code = code, .foreground_finished = true, .background_jobs_unknown = true };
                self.snapshot.elapsed_ms = @intCast(@max(0, now - self.snapshot.started_at));
                self.snapshot.state = .process_finished;
                self.snapshot.input_wait = null;
                self.active = false;
                self.lease.revoke(self.queued_end != null or self.input_end != null);
                self.changed();
            },
            else => {},
        }
    }
};

const Harness = struct {
    bridge: *Bridge,
    sequence: u64 = 0,
    fn sink(self: *Harness) Bridge.Sink {
        return .{ .context = self, .output = output, .boundary = boundary };
    }
    fn output(raw: *anyopaque, bytes: []const u8, _: u64) void {
        const self: *Harness = @ptrCast(@alignCast(raw));
        self.bridge.capture(bytes);
    }
    fn boundary(raw: *anyopaque, value: execution.Boundary) execution.Boundary {
        const self: *Harness = @ptrCast(@alignCast(raw));
        self.sequence += 1;
        var result = value;
        result.event_sequence = self.sequence;
        return result;
    }
    fn request(command: []const u8) execution.Request {
        return .{ .execution_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .expected_input_epoch = 0, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) };
    }
};

test "SSH shell events preserve same execution and never resend after native write" {
    var bridge = Bridge.init(std.testing.allocator, .{ .session_id = @fromBackingInt(1) });
    defer bridge.deinit();
    var harness = Harness{ .bridge = &bridge };
    var queue = try Queue.init(std.testing.allocator, 8192);
    defer queue.deinit(std.testing.allocator);
    bridge.output("\x1b]133;A\x07\x1b]133;B\x07", harness.sink(), 1);
    try bridge.begin(Harness.request("printf hello"), 2);
    bridge.prepared(@splat('a'), 1, 1);
    try bridge.enqueue(&queue);
    const length = queue.pending();
    try queue.consume(length);
    bridge.written(&queue, 3);
    try bridge.enqueue(&queue);
    try std.testing.expectEqual(@as(usize, 0), queue.pending());
    try std.testing.expectEqual(length, bridge.snapshot.submit_native_bytes);
    bridge.output("\x1b]133;C\x07hello\x1b]133;D;7\x07\x1b]133;A\x07\x1b]133;B\x07", harness.sink(), 4);
    try std.testing.expectEqual(@as(?u8, 7), bridge.snapshot.process.?.exit_code);
    try std.testing.expectEqual(execution.CompletionSource.shell_reported, bridge.snapshot.completion_source);
    try std.testing.expect(!bridge.snapshot.native_wake_written and !bridge.snapshot.command_accepted);
    try std.testing.expectError(error.OperationBusy, bridge.begin(Harness.request("true"), 5));
    const output = try bridge.readOutput(bridge.snapshot.execution_id.?, std.testing.allocator, 0, 4096);
    defer std.testing.allocator.free(output.bytes);
    try std.testing.expect(std.mem.startsWith(u8, output.bytes, "hello"));
}

test "SSH shell stream input written receipt and takeover keep observer" {
    var bridge = Bridge.init(std.testing.allocator, .{ .session_id = @fromBackingInt(1) });
    defer bridge.deinit();
    var harness = Harness{ .bridge = &bridge };
    var queue = try Queue.init(std.testing.allocator, 8192);
    defer queue.deinit(std.testing.allocator);
    bridge.output("\x1b]133;A\x07\x1b]133;B\x07", harness.sink(), 1);
    try bridge.begin(Harness.request("read answer"), 2);
    bridge.prepared(@splat('a'), 1, 1);
    try bridge.enqueue(&queue);
    try queue.consume(queue.pending());
    bridge.written(&queue, 3);
    bridge.output("\x1b]133;C\x07", harness.sink(), 4);
    const grant = bridge.lease.holder.?;
    const input: execution.InputRequest = .{ .grant = grant, .wait_sequence = bridge.snapshot.input_wait.?.sequence, .input_sequence = 1, .kind = .text, .text = "yes" };
    _ = try bridge.sendInput(input, &queue, 5);
    try queue.consume(3);
    bridge.written(&queue, 6);
    try std.testing.expectEqual(.written, bridge.snapshot.input_receipt.?.stage);
    try std.testing.expectEqual(@as(usize, 3), bridge.snapshot.input_receipt.?.accepted_bytes);
    try bridge.revoke(grant, true, &queue, false, 7);
    try std.testing.expect(bridge.active and bridge.snapshot.input_handed_off and bridge.snapshot.process == null);
    try std.testing.expectError(error.StaleFence, bridge.sendInput(input, &queue, 8));
    bridge.output("answer\x1b]133;D;0\x07", harness.sink(), 9);
    try std.testing.expectEqual(@as(?u8, 0), bridge.snapshot.process.?.exit_code);
    try std.testing.expectEqual(.written, bridge.snapshot.input_receipt.?.stage);
}

test "SSH malformed or missing shell events never prove completion" {
    var bridge = Bridge.init(std.testing.allocator, .{ .session_id = @fromBackingInt(1) });
    defer bridge.deinit();
    var harness = Harness{ .bridge = &bridge };
    var queue = try Queue.init(std.testing.allocator, 8192);
    defer queue.deinit(std.testing.allocator);
    bridge.output("\x1b]133;Afoo\x07\x1b]133;B\x07", harness.sink(), 1);
    try std.testing.expect(!bridge.snapshot.interactive_execution);
    bridge.output("\x1b]133;A;zw_start=debug\x07\x1b]133;B\x07", harness.sink(), 1);
    try std.testing.expectError(error.UnsupportedSyntax, bridge.begin(Harness.request("(exit 7)"), 2));
    try bridge.begin(Harness.request("true"), 2);
    bridge.prepared(@splat('a'), 1, 1);
    try bridge.enqueue(&queue);
    try queue.consume(queue.pending());
    bridge.written(&queue, 3);
    bridge.output("\x1b]133;D;0\x07", harness.sink(), 4);
    try std.testing.expectEqual(.outcome_unknown, bridge.snapshot.state);
    try std.testing.expect(bridge.snapshot.process == null and bridge.snapshot.start == null);
}

test "SSH pending input takeover cancels only untouched bytes" {
    var bridge = Bridge.init(std.testing.allocator, .{ .session_id = @fromBackingInt(1) });
    defer bridge.deinit();
    var harness = Harness{ .bridge = &bridge };
    var queue = try Queue.init(std.testing.allocator, 8192);
    defer queue.deinit(std.testing.allocator);
    bridge.output("\x1b]133;A\x07\x1b]133;B\x07", harness.sink(), 1);
    try bridge.begin(Harness.request("read answer"), 2);
    bridge.prepared(@splat('a'), 1, 1);
    try bridge.enqueue(&queue);
    try queue.consume(queue.pending());
    bridge.written(&queue, 3);
    bridge.output("\x1b]133;C\x07", harness.sink(), 4);
    const grant = bridge.lease.holder.?;
    _ = try bridge.sendInput(.{ .grant = grant, .wait_sequence = bridge.snapshot.input_wait.?.sequence, .input_sequence = 1, .kind = .text, .text = "never written" }, &queue, 5);
    try bridge.revoke(grant, true, &queue, false, 6);
    try std.testing.expectEqual(@as(usize, 0), queue.pending());
    try std.testing.expectEqual(.cancelled_unsent, bridge.snapshot.input_receipt.?.stage);
    try std.testing.expect(bridge.active);
}

test "SSH initialization ACK checks nonce sequence size and split frames" {
    var bridge = Bridge.init(std.testing.allocator, .{ .session_id = @fromBackingInt(1) });
    defer bridge.deinit();
    var harness = Harness{ .bridge = &bridge };
    bridge.initialization_nonce = @splat('a');
    bridge.initialization_expected = 2;
    bridge.output("\x1b]133;P;zw_init=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;2;128\x07", harness.sink(), 1);
    bridge.output("\x1b]133;P;zw_init=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;1;128\x07", harness.sink(), 1);
    bridge.output("\x1b]133;P;zw_init=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;2;129\x07", harness.sink(), 1);
    try std.testing.expectEqual(@as(u64, 0), bridge.initialization_ack);
    bridge.output("\x1b]133;P;zw_init=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;", harness.sink(), 1);
    bridge.output("2;128\x1b", harness.sink(), 1);
    bridge.output("\\", harness.sink(), 1);
    try std.testing.expectEqual(@as(u64, 2), bridge.initialization_ack);
    try std.testing.expectEqual(@as(u64, 128), bridge.initialization_ack_size);
    try std.testing.expect(!bridge.snapshot.interactive_execution);
    bridge.output("\x1b]133;P;zw_restored=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x07", harness.sink(), 1);
    try std.testing.expect(!bridge.initialization_restored);
    bridge.output("\x1b]133;P;zw_restored=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\x07", harness.sink(), 1);
    try std.testing.expect(bridge.initialization_restored);
}

test "SSH missing start report times out without adding Enter or replay" {
    var bridge = Bridge.init(std.testing.allocator, .{ .session_id = @fromBackingInt(1) });
    defer bridge.deinit();
    var harness = Harness{ .bridge = &bridge };
    var queue = try Queue.init(std.testing.allocator, 8192);
    defer queue.deinit(std.testing.allocator);
    bridge.output("\x1b]133;A\x07\x1b]133;B\x07", harness.sink(), 1);
    try bridge.begin(Harness.request("printf 'incomplete"), 2);
    bridge.prepared(@splat('a'), 1, 1);
    try bridge.enqueue(&queue);
    try queue.consume(queue.pending());
    bridge.written(&queue, 3);
    bridge.written(&queue, 5003);
    try std.testing.expectEqual(.outcome_unknown, bridge.snapshot.state);
    try std.testing.expectEqualStrings("ShellStartMissing", bridge.snapshot.failure.?);
    try std.testing.expect(bridge.snapshot.process == null and bridge.snapshot.start == null and bridge.snapshot.remote_effect_unknown);
    try bridge.enqueue(&queue);
    try std.testing.expectEqual(@as(usize, 0), queue.pending());
}
