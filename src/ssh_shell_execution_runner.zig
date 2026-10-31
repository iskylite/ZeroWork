//! Loopback-only production Worker/VT/recording acceptance. No remote helper,
//! SFTP, private control channel, or replacement shell is available in the peer.
const std = @import("std");
pub const application_test_mode = true;
const ssh = @import("proto/ssh/session.zig");
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
    const directory_path = args.next() orelse return error.MissingIsolatedDirectory;
    const mode = args.next() orelse return error.MissingMode;
    if (port < 1024 or !std.mem.startsWith(u8, directory_path, "/tmp/")) return error.NonFixtureTarget;
    if (std.mem.startsWith(u8, mode, "init-retry-")) return initializationRecovery(init, port, directory_path, mode);
    var library = try ssh.Library.init();
    defer library.deinit();
    const dir = try std.Io.Dir.cwd().openDir(init.io, directory_path, .{});
    defer dir.close(init.io);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(27), .generation = 1 };
    const task = identity.TaskId.generate();
    var ledger = try ssh.ResourceLedger.init(.{ .owner = .{ .session = owner }, .operation_id = 1, .attempt_id = 1 }, 1);
    const worker = try Worker.init(a, &library, .{ .host = "127.0.0.1", .port = port, .user = "shell-fixture", .auth = .{ .password = "fixture-only" }, .host_key_decision = .trust_once, .operation_key = ledger.key, .resource_ledger = &ledger, .connect_timeout_ms = 5000, .keepalive_sec = 0 }, .{ .auto_reconnect = false, .auto_shell_integration = !std.mem.startsWith(u8, mode, "disabled"), .keepalive_sec = 0, .connect_timeout_ms = 5000 });
    defer worker.deinit();
    const original_vt = worker.vt.terminal;
    const original_fd = worker.session.socket_fd;
    const recording: publication.Options = .{ .recording_id = worker.recording_id, .archive_key = worker.archive_key, .generations = worker.recording_generations.items, .cast_path = "logs/history/shell-execution.cast", .started_ms = realtime.milliseconds(undefined), .display = .{ .title = "Same-shell execution loopback", .host = "127.0.0.1", .user = "shell-fixture" }, .timeline = &worker.timeline };
    try publication.reserve(a, init.io, dir, recording);
    if (std.mem.eql(u8, mode, "disabled")) {
        try worker.configureExecutionRecording(init.io, dir, recording);
        for (0..60) |_| try tick(worker);
        if ((try worker.executionSnapshot()).interactive_execution) return error.UnintegratedShellWasReady;
        try worker.pushInputFrom("printf 'DISABLED_%s\\n' ordinary\n", .ordinary);
        const deadline = now() + 3000;
        var observed = false;
        while (now() < deadline) {
            try tick(worker);
            const screen = try worker.searchText(a);
            defer a.free(screen);
            if (std.mem.indexOf(u8, screen, "DISABLED_ordinary") != null) {
                observed = true;
                break;
            }
        }
        if (!observed) return error.OrdinaryInputWasDisabled;
        try release(worker, &ledger);
        std.debug.print("SHELL_EXECUTION_PASS mode=disabled initialization=false ordinary_input=true\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "recording-unavailable")) {
        for (0..30) |_| try tick(worker);
        const snapshot = try worker.executionSnapshot();
        if (snapshot.interactive_execution) return error.FalseRecordingReadiness;
        worker.executionRequest(.{ .execution_id = .generate(), .task_id = task, .expected_input_epoch = snapshot.input_epoch, .ownership_revision = 1, .command = "printf NEVER_UNRECORDED", .command_hash = execution.digest("printf NEVER_UNRECORDED") }) catch |err| {
            if (err != error.RecordingUnavailable) return err;
            try release(worker, &ledger);
            std.debug.print("SHELL_EXECUTION_PASS mode=recording-unavailable user_commands=0\n", .{});
            return;
        };
        return error.MissingRecordingWasAccepted;
    }
    try worker.configureExecutionRecording(init.io, dir, recording);
    try waitReady(worker);
    if (std.mem.eql(u8, mode, "history-reopen")) {
        try historyReopen(init, worker, &ledger, task, dir);
        return;
    }
    {
        const screen = try worker.searchText(a);
        defer a.free(screen);
        if (std.mem.indexOf(u8, screen, "_zwR()") != null or std.mem.indexOf(u8, screen, "_zwP=") != null) return error.InitializerEchoLeakedToVt;
        std.debug.print("INITIALIZER_ECHO_PASS vt=true\n", .{});
    }
    if (std.mem.eql(u8, mode, "disconnect")) {
        try disconnected(worker, task);
        std.debug.print("SHELL_EXECUTION_PASS mode=disconnect unknown=true no_replay=true\n", .{});
        return;
    }
    _ = try run(worker, task, "cd /tmp; ZW_PERSIST=kept; zw_fixture_fn() { printf 'FN_%s\\n' preserved; }; printf 'PID_%s\\n' \"$$\"", .{ .expected = "PID_", .exit_code = 0 });
    _ = try run(worker, task, "printf 'STATE_%s:%s\\n' \"$PWD\" \"$ZW_PERSIST\"; zw_fixture_fn; false", .{ .expected = "STATE_/tmp:kept", .extra = "FN_preserved", .exit_code = 1 });
    _ = try run(worker, task, "true", .{ .exit_code = 0 });
    _ = try run(worker, task, "printf 'STREAM_%s\\n' first; sleep 0.3; printf 'STREAM_%s\\n' last", .{ .expected = "STREAM_last", .stream = true, .exit_code = 0 });
    _ = try run(worker, task, "read -r answer; printf 'ANSWER_%s\\n' \"$answer\"", .{ .expected = "ANSWER_fixture-answer", .input = true, .exit_code = 0 });
    const handoff = try run(worker, task, "read -r answer; printf 'HANDOFF_%s\\n' \"$answer\"", .{ .expected = "HANDOFF_human-answer", .handoff = true, .exit_code = 0 });
    if (!handoff.input_handed_off or handoff.remote_effect_unknown) return error.HandoffInterruptedObserver;
    const last = try run(worker, task, "printf 'PERSIST_%s\\n' \"$ZW_PERSIST\"; zw_fixture_fn", .{ .expected = "PERSIST_kept", .extra = "FN_preserved", .exit_code = 0 });
    if (worker.vt.terminal != original_vt or worker.session.socket_fd != original_fd or !last.owner.eql(owner)) return error.SessionWasReplaced;
    try release(worker, &ledger);
    _ = try worker.execution_recording.?.persist(worker.io.stream_offset, realtime.milliseconds(undefined));
    const cast = try dir.readFileAlloc(init.io, "logs/history/shell-execution.cast", a, .limited(8 * 1024 * 1024));
    defer a.free(cast);
    if (std.mem.indexOf(u8, cast, "_zwR()") != null or std.mem.indexOf(u8, cast, "_zwP=") != null) return error.InitializerEchoLeakedToRecording;
    std.debug.print("INITIALIZER_ECHO_PASS recording=true\n", .{});
    std.debug.print("SHELL_EXECUTION_PASS mode={s} executions=7 same_session=true source=shell_reported interval_saved=true\n", .{mode});
}

fn historyReopen(init: std.process.Init, worker: *Worker, ledger: *ssh.ResourceLedger, task: identity.TaskId, dir: std.Io.Dir) !void {
    const first = try run(worker, task, "true", .{ .exit_code = 0 });
    const second = try run(worker, task, "true", .{ .exit_code = 0 });
    try waitReady(worker);
    try worker.pushInputFrom("true\r", .ordinary);
    const deadline = now() + 4000;
    var count: usize = 0;
    while (now() < deadline) {
        try tick(worker);
        count = 0;
        for (worker.timeline.command_history.items) |item| if (item.value.command != null and std.mem.eql(u8, item.value.command.?, "true") and item.value.end_ms != null) {
            count += 1;
        };
        if (count == 3) break;
    }
    if (count != 3) return error.RepeatedCommandHistoryMissing;
    try release(worker, ledger);
    _ = try worker.execution_recording.?.persist(worker.io.stream_offset, realtime.milliseconds(undefined));
    var archive: @import("vt/session_archive.zig").Archive = .{ .allocator = a, .io = init.io, .dir = dir };
    var catalog = try archive.loadCatalog(a);
    defer catalog.deinit();
    if (catalog.entries.items.len != 1) return error.HistoryArchiveMissing;
    const descriptor = catalog.entries.items[0];
    const job = try @import("ui/history_archive.zig").Job.start(archive, descriptor.archive_key, descriptor.manifest_revision, 1);
    defer job.deinit();
    job.thread.?.join();
    job.thread = null;
    if (job.failure != null) return error.HistoryArchiveLoadFailed;
    var reopened: usize = 0;
    for (job.document.?.timeline.commands.items) |command| if (command.command != null and std.mem.eql(u8, command.command.?, "true")) {
        if (reopened == 0 and (command.ai_execution_id == null or !command.ai_execution_id.?.eql(first.execution_id.?))) return error.FirstAiSourceLost;
        if (reopened == 1 and (command.ai_execution_id == null or !command.ai_execution_id.?.eql(second.execution_id.?))) return error.SecondAiSourceLost;
        if (reopened == 2 and command.ai_execution_id != null) return error.ManualCommandMarkedAi;
        if (command.exit_code != 0 or command.elapsed_ms == null or command.end_ms == null or job.document.?.timeline.commandFrame(command.id) == null) return error.HistoryExecutionFactsMissing;
        reopened += 1;
    };
    if (reopened != 3) return error.ReopenedHistoryIncomplete;
    std.debug.print("SHELL_EXECUTION_PASS mode=history-reopen repeated=3 ai=2 manual=1 manifest=true archive_reopened=true\n", .{});
}

fn initializationRecovery(init: std.process.Init, port: u16, directory: []const u8, mode: []const u8) !void {
    const ui = @import("ui");
    const Workspace = @import("ui/workspace.zig").Workspace;
    const Application = @import("ui/application_host.zig").ApplicationHost;
    const cx = try ui.Cx.init(a, init.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(1100, 720);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    var nodes: [4]*ui.Node = undefined;
    for (&nodes) |*node| {
        node.* = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        try cx.root.?.appendChild(a, node.*);
    }
    var config: @import("config/config.zig").Config = .{};
    config.ssh.auto_reconnect = false; // init recovery has its own one-attempt budget
    const path = try std.fmt.allocPrint(a, "{s}/hosts.toml", .{directory});
    defer a.free(path);
    const workspace = try Workspace.init(a, cx, scope, init.io, &config, path, nodes[0], nodes[1], nodes[2], nodes[3]);
    const app = try Application.init(a, workspace);
    try scope.onCleanup(Application, app, Application.deinit);
    app.install();
    const accepted = try app.create(.{ .connection_id = @fromBackingInt(77), .revision = 1, .name = "init-recovery", .host = "127.0.0.1", .port = port, .user = "shell-fixture", .auth_mode = .password, .password = "fixture-only", .startup_commands = &.{"echo NEVER_REPLAY_STARTUP"} }, 1, 0, "echo NEVER_REPLAY_INITIAL\n");
    const id = app.legacyForHandle(accepted.handle) orelse return error.MissingTab;
    const original = workspace.sessionTab(id).?;
    const original_tab = original.tab_id;
    const original_root = original.root;
    const expect_confirmation = std.mem.eql(u8, mode, "init-retry-fail");
    var confirmed = false;
    var sent = false;
    var confirmation_observed = false;
    var confirmation_at: i64 = 0;
    const ai_id = identity.ExecutionId.generate();
    const ai_command = "cd /tmp; ZW_RECONNECTED=kept; printf 'RECONNECTED_%s\\n' \"$ZW_RECONNECTED\"; false";
    var ai_started = false;
    var ai_finished = false;
    const deadline = now() + 30_000;
    while (now() < deadline) {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
        var poll_fds: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&poll_fds, 0, 2);
        _ = try app.safeTick();
        if (workspace.pendingAuthentication()) |challenge| try workspace.submitAuthentication(challenge.identity, .trust_once);
        const tab = workspace.sessionTab(id) orelse return error.LostOriginalTab;
        if (tab.tab_id != original_tab or tab.root != original_root) return error.RecoveryReplacedTab;
        if (!config.ssh.auto_shell_integration or tab.host_snapshot.?.value.auto_shell_integration != null) return error.RecoveryChangedSettings;
        const runtime = tab.runtime orelse continue;
        const state = runtime.reconnectSnapshot() orelse continue;
        const handle = app.ownerForLegacy(id) orelse return error.LostMapping;
        if (handle.generation > 3) return error.InitializationRetryLoop;
        if (tab.shell_init_confirmation_required) {
            if (!expect_confirmation or handle.generation != 2 or (state.failure == null or state.failure.? != error.ShellInitializationFailed)) return error.EarlyInitializationConfirmation;
            if (state.cleanup != .released) continue;
            if (!confirmation_observed) {
                confirmation_observed = true;
                confirmation_at = now();
            }
            // Leaving the failure unconfirmed never disables settings or starts
            // another connection. Then invoke the real native notice action.
            if (now() - confirmation_at < 200) continue;
            const notice = tab.remote_notice orelse return error.MissingRecoveryNotice;
            const button = notice.without_initialization;
            if (button.style.display == .none) return error.MissingExplicitBypassAction;
            button.behavior.events.on_click.?.invoke();
            confirmed = true;
        }
        if (state.phase == .active and state.shell_initialized and !sent) {
            if (handle.generation != (if (expect_confirmation) @as(u64, 3) else 2)) return error.WrongRecoveryGeneration;
            if (expect_confirmation and !confirmed) return error.UnconfirmedBypass;
            const binding = switch (app.sessions.queryService(handle, .terminal)) {
                .available => |value| value,
                else => continue,
            };
            const live = runtime.bindTerminalService(binding) catch |err| switch (err) {
                error.WorkerBusy => continue,
                else => return err,
            };
            const snapshot = live.executionSnapshot() catch |err| switch (err) {
                error.WorkerBusy => continue,
                else => return err,
            };
            if (!snapshot.owner.eql(handle)) return error.ReconnectedExecutionOwnerStale;
            if (expect_confirmation) {
                if (snapshot.interactive_execution) return error.ConfirmedBypassInstalledHooks;
            } else {
                if (!snapshot.interactive_execution) continue;
                if (!ai_started) {
                    if (!snapshot.input_ready) continue;
                    live.executionRequest(.{ .execution_id = ai_id, .task_id = .generate(), .expected_input_epoch = snapshot.input_epoch, .ownership_revision = 1, .command = ai_command, .command_hash = execution.digest(ai_command) }) catch |err| switch (err) {
                        error.WorkerBusy => continue,
                        else => return err,
                    };
                    ai_started = true;
                    continue;
                }
                if (snapshot.state != .interval_recorded) continue;
                if (snapshot.recording_generation != 2 or snapshot.process == null or snapshot.process.?.exit_code != 1 or !snapshot.interval_saved or !snapshot.recording_settled) return error.ReconnectedExecutionFactsInvalid;
                ai_finished = true;
            }
            runtime.pushInputFrom("printf 'RECOVERY_%s\\n' ordinary\r", .ordinary) catch |err| switch (err) {
                error.WorkerBusy => continue,
                else => return err,
            };
            sent = true;
        }
        if (sent) {
            const screen = runtime.searchText(a) catch |err| switch (err) {
                error.WorkerBusy => continue,
                else => return err,
            };
            defer a.free(screen);
            if (std.mem.indexOf(u8, screen, "RECOVERY_ordinary") != null) {
                const close = try app.requestCloseLegacy(id);
                const until = now() + 5000;
                while (now() < until) {
                    _ = try app.safeTick();
                    if (app.sessions.queryState(close.owner.session).?.lifecycle == .closed and workspace.sessionTab(id) == null) {
                        std.debug.print("SHELL_EXECUTION_PASS mode={s} same_tab=true automatic_retries=1 confirmed_bypass={} settings_unchanged=true ordinary_input=true no_startup_replay=true reconnected_ai_recorded={}\n", .{ mode, confirmed, ai_finished });
                        return;
                    }
                    var fds: [1]std.c.pollfd = undefined;
                    _ = std.c.poll(&fds, 0, 2);
                }
                return error.RecoveryCloseTimeout;
            }
        }
    }
    return error.InitializationRecoveryTimedOut;
}

fn tick(worker: *Worker) !void {
    try worker.step(5);
    _ = worker.text.acknowledge(0);
}
fn waitReady(worker: *Worker) !void {
    const deadline = now() + 10_000;
    while (now() < deadline) {
        try tick(worker);
        const snapshot = try worker.executionSnapshot();
        if (snapshot.interactive_execution and snapshot.input_ready) return;
    }
    const snapshot = try worker.executionSnapshot();
    std.debug.print("READINESS state={s} failure={?s}\n", .{ @tagName(snapshot.state), snapshot.failure });
    return error.ShellNeverReady;
}
const Checks = struct { expected: []const u8 = "", extra: []const u8 = "", exit_code: u8, stream: bool = false, input: bool = false, handoff: bool = false };
fn run(worker: *Worker, task: identity.TaskId, command: []const u8, checks: Checks) !execution.Snapshot {
    try waitReady(worker);
    const id = identity.ExecutionId.generate();
    const admission_deadline = now() + 3000;
    while (true) {
        const before = try worker.executionSnapshot();
        // D (finished) and the next A/B (empty prompt) can be separate packets.
        // InputConflict is a pre-write rejection, so only that admission may be
        // retried. Never retry an accepted request or clear a user's draft.
        worker.executionRequest(.{ .execution_id = id, .task_id = task, .expected_input_epoch = before.input_epoch, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) }) catch |err| {
            if (err == error.InputConflict and now() < admission_deadline) {
                try tick(worker);
                continue;
            }
            return err;
        };
        break;
    }
    const deadline = now() + 10_000;
    var input_stage: u8 = 0;
    var streamed = false;
    var renew_at = now() + 1000;
    while (now() < deadline) {
        try tick(worker);
        var snapshot = try worker.executionSnapshot();
        if (execution.PublicReceipt.fromSnapshot(snapshot)) |receipt| try receipt.validate();
        if (snapshot.grant) |grant| if (now() >= renew_at) {
            try worker.executionRenew(grant);
            renew_at = now() + 1000;
        };
        if (checks.stream and snapshot.state == .running) {
            var output = try worker.readExecutionOutput(id, a, 0, 65536);
            defer output.deinit(a);
            if (std.mem.indexOf(u8, output.bytes, "STREAM_first") != null and std.mem.indexOf(u8, output.bytes, "STREAM_last") == null) streamed = true;
        }
        if (checks.input and snapshot.state == .running and snapshot.input_wait != null) {
            const wait = snapshot.input_wait.?;
            if (wait.kind != .terminal_stream) return error.FalseConsumerAttestation;
            if (input_stage == 0) {
                _ = try worker.executionInput(.{ .grant = snapshot.grant.?, .wait_sequence = wait.sequence, .input_sequence = 1, .kind = .text, .text = "fixture-answer" });
                input_stage = 1;
            } else if (input_stage == 1 and snapshot.input_receipt != null and snapshot.input_receipt.?.stage == .written) {
                _ = try worker.executionInput(.{ .grant = snapshot.grant.?, .wait_sequence = wait.sequence, .input_sequence = 2, .kind = .enter });
                input_stage = 2;
            }
        }
        if (checks.handoff and input_stage == 0 and snapshot.state == .running) {
            const grant = snapshot.grant.?;
            try worker.executionRevoke(grant, true);
            worker.executionRenew(grant) catch |err| {
                if (err != error.StaleFence) return err;
                input_stage = 1;
            };
            if (input_stage != 1) return error.RevokedGrantWasRenewed;
        }
        if (checks.handoff and input_stage == 1) {
            snapshot = try worker.executionSnapshot();
            if (snapshot.input_ready) {
                try worker.pushInputFrom("human-answer\n", .ordinary);
                input_stage = 2;
            }
        }
        if (snapshot.state == .interval_recorded) {
            if (snapshot.completion_source != .shell_reported or snapshot.process == null or snapshot.process.?.exit_code != checks.exit_code or !snapshot.interval_saved or snapshot.output_scope != .session_interval) return error.FalseCompletionReceipt;
            if (snapshot.start == null or snapshot.end == null or snapshot.start.?.event_sequence >= snapshot.end.?.event_sequence) return error.MissingOrderedBoundaries;
            if (checks.stream and !streamed) return error.StreamWasNotVisibleBeforeFinish;
            if (checks.input and (input_stage != 2 or snapshot.input_receipt == null or snapshot.input_receipt.?.stage != .written)) return error.MissingNativeWriteReceipt;
            var output = try worker.readExecutionOutput(id, a, 0, 65536);
            defer output.deinit(a);
            if (std.mem.indexOf(u8, output.bytes, checks.expected) == null or std.mem.indexOf(u8, output.bytes, checks.extra) == null) {
                std.debug.print("OUTPUT_MISSING expected={s} bytes={s}\n", .{ checks.expected, output.bytes });
                return error.ExpectedOutputMissing;
            }
            return snapshot;
        }
        if (snapshot.failure) |reason| {
            std.debug.print("EXECUTION_FAILURE state={s} reason={s}\n", .{ @tagName(snapshot.state), reason });
            return error.ExecutionFailed;
        }
    }
    const timeout = try worker.executionSnapshot();
    std.debug.print("EXECUTION_TIMEOUT state={s} failure={?s} pending={d} written={d} accepted={} submit={} source={s}\n", .{ @tagName(timeout.state), timeout.failure, worker.input.pending(), timeout.submit_native_bytes, timeout.command_accepted, timeout.submit_sent, @tagName(timeout.completion_source) });
    return error.ExecutionTimedOut;
}
fn disconnected(worker: *Worker, task: identity.TaskId) !void {
    const before = try worker.executionSnapshot();
    const command = "printf 'DISCONNECT_%s\\n' armed; sleep 30";
    try worker.executionRequest(.{ .execution_id = .generate(), .task_id = task, .expected_input_epoch = before.input_epoch, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) });
    const deadline = now() + 8000;
    while (now() < deadline) {
        tick(worker) catch {};
        const snapshot = try worker.executionSnapshot();
        if (snapshot.state == .outcome_unknown) {
            if (!snapshot.submit_sent or !snapshot.remote_effect_unknown or snapshot.process != null or snapshot.interval_saved or snapshot.grant != null) return error.FalseDisconnectReceipt;
            return;
        }
    }
    return error.DisconnectWasNotUnknown;
}
fn release(worker: *Worker, ledger: *ssh.ResourceLedger) !void {
    var receipt = worker.releaseConnection();
    const deadline = now() + 5000;
    while (receipt != .released and now() < deadline) {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
        receipt = worker.releaseConnection();
    }
    if (receipt != .released or !ledger.snapshot().released()) return error.ShellResourcesNotReleased;
}
