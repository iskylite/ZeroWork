//! Test-only production wizard probe driver. Only connects to fixture loopback.
const std = @import("std");
const probe = @import("ui/wizard_probe.zig");
const wizard = @import("ui/wizard.zig");
const hosts = @import("config/hosts.zig");
const ssh = @import("proto/ssh/session.zig");
const operations = @import("host/operation.zig");
const realtime = @import("platform/realtime.zig");

const Consumer = struct {
    controller: *probe.Controller,
    key: operations.OperationKey = undefined,
    port: u16,
    hop_port: ?u16,
    cancel_at_password: bool,
    host_keys: usize = 0,
    passwords: usize = 0,
    failure: ?anyerror = null,
    last_request_id: u64 = 0,

    fn consume(raw: *anyopaque, job: *probe.Job) void {
        const self: *Consumer = @ptrCast(@alignCast(raw));
        self.answer(job) catch |err| {
            self.failure = err;
            job.cancel();
        };
    }

    fn answer(self: *Consumer, job: *probe.Job) !void {
        if (!job.key.eql(self.key) or job.key.owner != .app) return error.ForeignOperation;
        const request = self.controller.pendingAuthentication() orelse return;
        if (request.state != .input and request.state != .failed) return;
        const is_hop = self.hop_port != null and request.identity.hop_index == 0;
        const expected_port = if (is_hop) self.hop_port.? else self.port;
        if (!request.identity.key.eql(self.key) or request.identity.hop_index > @intFromBool(self.hop_port != null) or request.port != expected_port or !std.mem.eql(u8, request.endpoint().host, "127.0.0.1") or request.source_owner == null or @backingInt(request.source_owner.?.id) != (if (is_hop) @as(u64, 41) else 77) or request.source_owner.?.revision != (if (is_hop) @as(u64, 8) else 6) or request.presentation_config_revision != 9) return error.ForeignAuthChallenge;
        if (request.identity.request_id <= self.last_request_id) return error.RequestIdentityReused;
        self.last_request_id = request.identity.request_id;
        const host = self.controller.authenticationHostFor(request.identity) orelse return error.MissingFrozenHost;
        if (host.password != null or host.key_passphrase != null or host.totp_secret != null or host.port != expected_port or !std.meta.eql(host.owner(), request.source_owner.?)) return error.WrongFrozenHost;
        const host_key = self.controller.authenticationHostKey(request.identity) orelse return error.MissingHostKeyDetails;
        if (host_key.port != expected_port or host_key.fingerprint_len == 0 or host_key.operation_key == null or !host_key.operation_key.?.eql(self.key) or host_key.hop_index != request.identity.hop_index) return error.ForeignHostKey;
        if (request.kind == .host_key_unknown) {
            if (host_key.generation != request.identity.request_id) return error.RequestIdentityReused;
            try self.controller.submitAuthentication(request.identity, .trust_once);
            self.host_keys += 1;
        } else {
            if (request.kind != .password or request.prompt_count != 1 or host_key.generation >= request.identity.request_id) return error.ForeignAuthChallenge;
            self.passwords += 1;
            if (self.cancel_at_password) {
                if (!self.controller.cancelAuthentication(request.identity)) return error.CancelRejected;
            } else {
                try self.controller.submitAuthentication(request.identity, .{ .answers = &.{"fixture-password"} });
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const mode = args.next() orelse return error.MissingMode;
    const store_path = args.next() orelse return error.MissingIsolatedStorePath;
    const hop_port = if (args.next()) |value| try std.fmt.parseInt(u16, value, 10) else null;
    const sftp = std.mem.startsWith(u8, mode, "sftp-");
    const interactive = std.mem.eql(u8, mode, "interactive") or std.mem.eql(u8, mode, "cancel") or std.mem.eql(u8, mode, "interactive-route");
    const password_prompt = interactive or std.mem.eql(u8, mode, "unavailable-password");
    var library = try ssh.Library.init();
    defer library.deinit();
    var journal = operations.Journal.init(std.heap.page_allocator);
    defer journal.deinit();
    var controller = probe.Controller.init(std.heap.page_allocator, &journal);
    defer controller.deinit();
    var consumer: Consumer = .{ .controller = &controller, .port = port, .hop_port = hop_port, .cancel_at_password = std.mem.eql(u8, mode, "cancel") };
    if (interactive) controller.setInteractionSink(.{ .context = &consumer, .consume = Consumer.consume });
    var value: wizard.Draft = .{
        .protocol = if (sftp) .sftp else .ssh,
        .draft_id = 17,
        .revision = 4,
        .source_owner = .{ .id = @fromBackingInt(77), .revision = 6 },
        .name = "isolated-probe-target",
        .host = "127.0.0.1",
        .port = port,
        .user = "operator",
        .auth = .password,
        .password = if (password_prompt) null else "fixture-password",
        .startup_commands = &.{"THIS_STARTUP_MUST_NEVER_BE_SENT"},
    };
    const hop: hosts.HostConfig = .{
        .connection_id = @fromBackingInt(41),
        .revision = 8,
        .name = "isolated-probe-hop",
        .host = "127.0.0.1",
        .port = hop_port orelse 1,
        .user = "operator",
        .auth_mode = .password,
        .password = if (password_prompt) null else "fixture-password",
        .strict_host_key_checking = true,
    };
    if (hop_port != null) value.route = &.{hop.connection_id};
    var settings: @import("config/config.zig").Config = .{};
    settings.config_revision = 9;
    settings.ssh.connect_timeout_sec = 3;
    const job = try controller.startWithTrustStore(value, if (hop_port != null) &.{hop} else &.{}, settings, 3, &library, store_path);
    consumer.key = job.key;
    const expected_key = job.key;
    const deadline = realtime.monotonicNs() + 8 * std.time.ns_per_s;
    var progress_seen: usize = 0;
    const result: probe.Outcome = while (true) {
        const projection = controller.connectionProgress(expected_key) orelse return error.MissingProbeProgress;
        if (!projection.key.eql(expected_key) or projection.draft_id != 17 or projection.draft_revision != 4 or projection.generation != 3 or projection.hop_count != (if (hop_port != null) @as(usize, 2) else 1)) return error.ForeignProbeProgress;
        progress_seen = @max(progress_seen, projection.journal.count);
        if (projection.journal.attempt != expected_key.attempt_id.?) return error.ForeignProbeProgress;
        for (projection.journal.entries[0..projection.journal.count]) |entry| if (entry.hop >= projection.hop_count or entry.phase == .shell) return error.ProbeOpenedShell;
        switch (try controller.poll(job)) {
            .finished => |outcome| break outcome,
            .pending => {},
        }
        if (realtime.monotonicNs() >= deadline) return error.ProbeTimeout;
        var wait_fd: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&wait_fd, 0, 1);
    };
    if (consumer.failure) |err| return err;
    if (!result.key.eql(expected_key) or result.key.owner != .app or result.key.attempt_id == null or result.draft_id != 17 or result.draft_revision != 4 or result.generation != 3 or result.purpose != .@"test" or result.source_owner == null or @backingInt(result.source_owner.?.id) != 77 or result.source_owner.?.revision != 6 or result.cleanup != .released or !journal.isTerminal(expected_key)) return error.OutcomeIdentityMismatch;
    const unavailable = std.mem.startsWith(u8, mode, "unavailable-");
    if (unavailable) {
        if (result.failure == null or result.failure.? != error.InteractionUnavailable) return error.MissingInteractionDidNotFail;
        if (result.elapsed_ms > 1500) return error.MissingInteractionWaited;
    } else if (std.mem.eql(u8, mode, "cancel")) {
        if (result.failure == null or result.failure.? != error.Cancelled or consumer.passwords != 1) return error.CancelDidNotRelease;
    } else if (sftp and !std.mem.eql(u8, mode, "sftp-known")) {
        const expected: anyerror = if (std.mem.eql(u8, mode, "sftp-subsystem-denied")) error.SftpSubsystemDenied else if (std.mem.eql(u8, mode, "sftp-not-directory")) error.NotDirectory else error.PermissionDenied;
        if (result.failure == null or result.failure.? != expected) return error.UnexpectedSftpProbeResult;
    } else if (result.failure) |err| return err;
    const expected_challenges: usize = if (hop_port != null) 2 else 1;
    if (interactive and consumer.host_keys != expected_challenges) return error.SinkWasNotPolled;
    if ((std.mem.eql(u8, mode, "interactive") or std.mem.eql(u8, mode, "interactive-route")) and consumer.passwords != expected_challenges) return error.PasswordSinkWasNotPolled;
    const final_projection = controller.connectionProgress(expected_key) orelse return error.MissingProbeProgress;
    if (!final_projection.finished or !final_projection.worker_finished or final_projection.cleanup != .released or !final_projection.resources.released() or progress_seen == 0) return error.ProbeProgressFinishedEarly;
    const resources = result.resources orelse return error.MissingResourceLedger;
    if (resources.key == null or !resources.key.?.eql(expected_key) or !resources.released() or resources.hop_count != (if (hop_port != null) @as(usize, 2) else 1)) return error.ResourceOwnerMismatch;
    var released_resources: usize = 0;
    for (0..resources.hop_count) |index| {
        if (resources.entry(index, .transport).state != .released or resources.entry(index, .session).state != .released or resources.entry(index, .shell).state != .absent) return error.NativeResourceNotReleased;
        for (resources.resources[index]) |resource| {
            if (resource.state == .released) released_resources += 1;
        }
    }
    if (hop_port != null) {
        const target_release = resources.entry(1, .transport).released_sequence;
        const relay_release = resources.entry(0, .relay_worker).released_sequence;
        const socket_release = resources.entry(0, .relay_socket).released_sequence;
        const tunnel_release = resources.entry(0, .tunnel).released_sequence;
        const session_release = resources.entry(0, .session).released_sequence;
        const parent_release = resources.entry(0, .transport).released_sequence;
        if (!(target_release < relay_release and relay_release < socket_release and socket_release < tunnel_release and tunnel_release < session_release and session_release < parent_release)) return error.ReverseReleaseOrderMismatch;
    }
    var event_count: usize = 0;
    while (journal.take()) |owned| {
        var event = owned;
        defer event.deinit();
        if (!event.value.key.eql(expected_key)) return error.ForeignReceipt;
        const expected: operations.EventKind = if (event_count == 0) (if (result.failure == null) .completed else .failed) else .cleanup_released;
        if (event.value.kind != expected) return error.ReceiptOrderMismatch;
        event_count += 1;
    }
    if (event_count != 2) return error.MissingCleanupReceipt;
    try controller.retire(job);
    if (controller.connectionProgress(expected_key) != null) return error.RetiredProgressStillLive;
    if (controller.jobs.items.len != 0 or journal.records.items.len != 0) return error.UnretiredOwner;
    std.debug.print("PASS {s} app_operation={d} attempt={d} cleanup=released retired=true host_key_decisions={d} password_decisions={d} resource_receipts={d} reverse_release=true typed_public_api=true progress_events={d} elapsed_ms={d}\n", .{ mode, expected_key.operation_id, expected_key.attempt_id.?, consumer.host_keys, consumer.passwords, released_resources, progress_seen, result.elapsed_ms });
}
