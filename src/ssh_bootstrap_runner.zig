//! Controlled loopback only. Production SSH worker, private Bridge, Timeline
//! and manifest; fixture Permit applies only to this disposable owned target.
const std = @import("std");
pub const application_test_mode = true;
const ssh = @import("proto/ssh/session.zig");
const bootstrap = @import("proto/ssh/bootstrap.zig");
const Worker = @import("vt/ssh_worker.zig").SshWorker;
const execution = @import("host/terminal_execution.zig");
const identity = @import("host/identity.zig");
const publication = @import("vt/ssh_recording_manifest.zig");
const realtime = @import("platform/realtime.zig");
const a = std.heap.c_allocator;
fn now() i64 {
    return @intCast(@divTrunc(realtime.monotonicNs(), std.time.ns_per_ms));
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const resource_path = args.next() orelse return error.MissingResources;
    const directory_path = args.next() orelse return error.MissingIsolatedDirectory;
    const mode = args.next() orelse return error.MissingMode;
    if (port < 1024 or !std.mem.startsWith(u8, directory_path, "/tmp/")) return error.NonFixtureTarget;
    var library = try ssh.Library.init();
    defer library.deinit();
    const dir = try std.Io.Dir.cwd().openDir(init.io, directory_path, .{});
    defer dir.close(init.io);
    const resources = try std.Io.Dir.cwd().openDir(init.io, resource_path, .{ .follow_symlinks = false });
    defer resources.close(init.io);
    var package = try bootstrap.Package.load(a, init.io, resources);
    defer package.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(17), .generation = 1 };
    const task = identity.TaskId.generate();
    var plan = try bootstrap.Plan.prepare(owner, task, &package, .{ .os = "Darwin", .arch = "arm64", .shell_path = "/bin/zsh", .shell_version = "5.9" }, true);
    var ledger = try ssh.ResourceLedger.init(.{ .owner = .{ .session = owner }, .operation_id = 1, .attempt_id = 1 }, 1);
    const options: ssh.Options = .{ .host = "127.0.0.1", .port = port, .user = "bootstrap-fixture", .auth = .{ .password = "fixture-only" }, .host_key_decision = .trust_once, .operation_key = ledger.key, .resource_ledger = &ledger, .connect_timeout_ms = 5000, .keepalive_sec = 0 };
    if (std.mem.eql(u8, mode, "unapproved")) {
        _ = Worker.init(a, &library, options, .{ .bootstrap = &plan }) catch |err| {
            if (err != error.BootstrapDeploymentAuthorizationRequired) return err;
            std.debug.print("BOOTSTRAP_UNAPPROVED_ZERO_NETWORK\n", .{});
            return;
        };
        return error.UnapprovedBootstrapAccepted;
    }
    plan.permit = .{ .owner = owner, .task_id = task, .plan_hash = plan.hash(), .expires_at = now() + 120_000 };
    var parent: ?*Worker = null;
    defer if (parent) |worker| worker.deinit();
    var lease: ?@import("host/runtime_service.zig").SharedLease = null;
    defer if (lease) |value| value.release();
    if (std.mem.startsWith(u8, mode, "shared")) {
        var parent_options = options;
        parent_options.resource_ledger = null;
        parent_options.operation_key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(16) } }, .operation_id = 2, .attempt_id = 1 };
        parent = try Worker.init(a, &library, parent_options, .{ .auto_reconnect = false, .keepalive_sec = 0 });
        lease = try parent.?.reuseConnection();
    }
    const worker = Worker.init(a, &library, options, .{ .bootstrap = &plan, .shared_connection = lease, .auto_reconnect = false, .keepalive_sec = 0, .connect_timeout_ms = 5000 }) catch |err| {
        if (!std.mem.eql(u8, mode, "shared-control-reject") or err != error.ShellOpenFailed) return err;
        const until = now() + 6000;
        while (now() < until and !ledger.snapshot().released()) {
            try parent.?.step(5);
            pause();
        }
        if (!ledger.snapshot().released()) return error.FailedBootstrapResourcesRetained;
        try parent.?.pushInputFrom("printf 'SIBLING_%s\\n' STILL_ALIVE\n", .ordinary);
        for (0..30) |_| try parent.?.step(5);
        std.debug.print("BOOTSTRAP_REJECTED_CLEANLY sibling=alive directory={s} cleanup=released\n", .{plan.directory});
        return;
    };
    defer worker.deinit();
    const recording: publication.Options = .{ .recording_id = worker.recording_id, .archive_key = worker.archive_key, .generations = worker.recording_generations.items, .cast_path = "logs/history/bootstrap.cast", .started_ms = realtime.milliseconds(undefined), .display = .{ .title = "BootstrapV1 loopback", .host = "127.0.0.1", .user = "bootstrap-fixture" }, .timeline = &worker.timeline };
    try publication.reserve(a, init.io, dir, recording);
    if (std.mem.eql(u8, mode, "recording-unavailable")) {
        for (0..20) |_| try tick(worker, parent);
        const unavailable = try worker.executionSnapshot();
        if (unavailable.interactive_execution or unavailable.failure == null or !std.mem.eql(u8, unavailable.failure.?, "RecordingUnavailable")) return error.FalseRecordingReadiness;
        worker.executionRequest(.{ .execution_id = .generate(), .task_id = task, .expected_input_epoch = unavailable.input_epoch, .ownership_revision = 1, .command = "printf NEVER_UNRECORDED", .command_hash = execution.digest("printf NEVER_UNRECORDED") }) catch |err| {
            if (err != error.RecordingUnavailable) return err;
            if (worker.execution.?.last_execution != null or worker.input.pending() != 0) return error.RecordingGateSentInput;
            var release = worker.releaseConnection();
            const until = now() + 5000;
            while (release != .released and now() < until) {
                pause();
                release = worker.releaseConnection();
            }
            if (release != .released) return error.RecordingGateCleanupFailed;
            std.debug.print("BOOTSTRAP_RECORDING_UNAVAILABLE_ZERO_INPUT cleanup=released\n", .{});
            return;
        };
        return error.MissingRecordingWasAccepted;
    }
    try worker.configureExecutionRecording(init.io, dir, recording);
    try waitReady(worker, parent);
    if (std.mem.eql(u8, mode, "protocol-loss")) {
        const before = try worker.executionSnapshot();
        const execution_id = identity.ExecutionId.generate();
        const command = "read -r value; printf 'LOST_%s\\n' \"$value\"";
        try worker.executionRequest(.{ .execution_id = execution_id, .task_id = task, .expected_input_epoch = before.input_epoch, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) });
        const until = now() + 8000;
        var observed = false;
        while (now() < until) {
            try tick(worker, parent);
            const snapshot = try worker.executionSnapshot();
            if (snapshot.state == .outcome_unknown and snapshot.recording_settled) {
                if (!snapshot.submit_sent or !snapshot.remote_effect_unknown or snapshot.process != null or snapshot.interval_saved or snapshot.grant != null or snapshot.input_handed_off) return error.FalseProtocolLossReceipt;
                observed = true;
                break;
            }
        }
        if (!observed) return error.ProtocolLossNotObserved;
        try worker.pushInputFrom("lost-value\n", .ordinary);
        for (0..30) |_| try tick(worker, parent);
        var receipt = worker.releaseConnection();
        const close_until = now() + 5000;
        while (receipt != .released and now() < close_until) {
            pause();
            receipt = worker.releaseConnection();
        }
        if (receipt != .released) return error.ProtocolLossCleanupFailed;
        _ = try worker.execution_recording.?.persist(worker.io.stream_offset, realtime.milliseconds(undefined));
        std.debug.print("BOOTSTRAP_PROTOCOL_LOSS_UNKNOWN no_replay=true cleanup=released\n", .{});
        return;
    }
    const first = try run(worker, parent, task, "printf '\\033]777;zerowork-exec-v1;forged;end\\007'; printf 'BOOTSTRAP_REAL_%s\\n' \"$RANDOM\"; false", false);
    if (first.process == null or first.process.?.exit_code != 1 or !first.interval_saved or first.state != .interval_recorded) return error.WrongForegroundReceipt;
    const second = try run(worker, parent, task, "true", false);
    if (second.process.?.exit_code != 0 or second.start.?.event_sequence >= second.end.?.event_sequence) return error.ZeroOutputBoundaryCollapsed;
    const third = try run(worker, parent, task, "read -r value; printf 'HANDOFF_%s\\n' \"$value\"", true);
    if (!third.input_handed_off or !third.input_ready or third.process.?.exit_code != 0 or third.remote_effect_unknown) return error.HandoffInterruptedOriginal;
    const fourth = try run(worker, parent, task, "(sleep 0.1; printf 'BACKGROUND_WRITER\\n') & true", false);
    if (!fourth.interval_saved or (!fourth.process.?.background_jobs and !fourth.process.?.background_jobs_unknown)) return error.BackgroundFactsLost;
    var exact: execution.Request = .{ .execution_id = .generate(), .task_id = task, .expected_input_epoch = fourth.input_epoch, .ownership_revision = 1, .command = "printf NEVER_EXACT", .command_hash = execution.digest("printf NEVER_EXACT"), .output_scope = .exact };
    worker.executionRequest(exact) catch |err| {
        if (err != error.UnsupportedOutputScope) return err;
        exact.command = "rejected";
    };
    if (!std.mem.eql(u8, exact.command, "rejected")) return error.UnsupportedExactDispatched;
    var receipt = worker.releaseConnection();
    const deadline = now() + 5000;
    while (receipt != .released and now() < deadline) {
        pause();
        receipt = worker.releaseConnection();
    }
    if (receipt != .released or !ledger.snapshot().released()) return error.BootstrapResourcesNotReleased;
    if (parent) |other| {
        try other.pushInputFrom("printf 'SIBLING_%s\\n' STILL_ALIVE\n", .ordinary);
        for (0..20) |_| try other.step(5);
    }
    const final_revision = try worker.execution_recording.?.persist(worker.io.stream_offset, realtime.milliseconds(undefined));
    std.debug.print("BOOTSTRAP_OK mode={s} executions=4 revision={d} directory={s} manifest_sha256={s} cleanup=released\n", .{ mode, final_revision, plan.directory, std.fmt.bytesToHex(package.manifest_hash, .lower) });
}
fn tick(worker: *Worker, parent: ?*Worker) !void {
    try worker.step(5);
    if (parent) |other| try other.step(1);
    _ = worker.text.acknowledge(0);
}
fn waitReady(worker: *Worker, parent: ?*Worker) !void {
    const deadline = now() + 8000;
    while (now() < deadline) {
        try tick(worker, parent);
        const snapshot = try worker.executionSnapshot();
        if (snapshot.interactive_execution) return;
        if (snapshot.failure) |reason| {
            std.debug.print("READINESS {s}\n", .{reason});
        }
    }
    return error.BootstrapNeverReady;
}
fn run(worker: *Worker, parent: ?*Worker, task: identity.TaskId, command: []const u8, handoff: bool) !execution.Snapshot {
    try waitReady(worker, parent);
    const before = try worker.executionSnapshot();
    const id = identity.ExecutionId.generate();
    try worker.executionRequest(.{ .execution_id = id, .task_id = task, .expected_input_epoch = before.input_epoch, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) });
    const deadline = now() + 10_000;
    var handed = false;
    var renew_at = now() + 1000;
    while (now() < deadline) {
        try tick(worker, parent);
        var snapshot = try worker.executionSnapshot();
        if (snapshot.grant) |grant| if (now() >= renew_at) {
            try worker.executionRenew(grant);
            renew_at = now() + 1000;
        };
        if (handoff and !handed and snapshot.state == .running) {
            const grant = snapshot.grant.?;
            try worker.executionRevoke(grant, true);
            worker.executionRenew(grant) catch |err| {
                if (err != error.StaleFence) return err;
            };
            snapshot = try worker.executionSnapshot();
            if (!snapshot.input_ready) return error.HandoffInputNotDrained;
            try worker.pushInputFrom("human-value\n", .ordinary);
            handed = true;
        }
        if (snapshot.state == .interval_recorded) {
            var output = try worker.readExecutionOutput(id, a, 0, 65536);
            defer output.deinit(a);
            if (handoff and std.mem.indexOf(u8, output.bytes, "HANDOFF_human-value") == null) return error.HandoffOutputMissing;
            return snapshot;
        }
        if (snapshot.failure) |reason| {
            std.debug.print("EXECUTION_FAILURE state={s} accepted={} submitted={} reason={s}\n", .{ @tagName(snapshot.state), snapshot.command_accepted, snapshot.submit_sent, reason });
            return error.ExecutionFailed;
        }
    }
    return error.ExecutionTimedOut;
}
fn pause() void {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}
