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
    if (std.mem.startsWith(u8, mode, "startup-")) return configuredStartup(init, port, directory_path, mode);
    if (std.mem.eql(u8, mode, "reconnect-startup")) return configuredReconnect(init, port, directory_path);
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
        worker.executionRequest(.{ .execution_id = .generate(), .task_id = task, .expected_input_epoch = snapshot.input_epoch, .expected_shell_id = snapshot.shell.id, .expected_shell_revision = snapshot.shell.revision, .ownership_revision = 1, .command = "printf NEVER_UNRECORDED", .command_hash = execution.digest("printf NEVER_UNRECORDED") }) catch |err| {
            if (err != error.RecordingUnavailable) return err;
            try release(worker, &ledger);
            std.debug.print("SHELL_EXECUTION_PASS mode=recording-unavailable user_commands=0\n", .{});
            return;
        };
        return error.MissingRecordingWasAccepted;
    }
    try worker.configureExecutionRecording(init.io, dir, recording);
    try waitReady(worker);
    if (std.mem.eql(u8, mode, "attach-evidence")) {
        try attachEvidence(worker, task);
        try release(worker, &ledger);
        std.debug.print("SHELL_EXECUTION_PASS mode=attach-evidence late_remote_output_rejected=true no_stale_initializer=true input_fence=true fresh_retry=true same_pty=true\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "attach-timeout")) {
        try attachTimeout(worker, task);
        try release(worker, &ledger);
        std.debug.print("SHELL_EXECUTION_PASS mode=attach-timeout nonce_barrier=true retry_same_pty=true no_payload_echo=true\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "nested")) {
        try nestedShells(worker, task, port);
        try release(worker, &ledger);
        std.debug.print("SHELL_EXECUTION_PASS mode=nested manual_attach=true three_layers=true observed_attach=true parent_restored=true stale_rejected=true parent_observer=true actual_nested_ssh=true\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "history-reopen")) {
        try historyReopen(init, worker, &ledger, task, dir);
        return;
    }
    if (std.mem.eql(u8, mode, "execution-rotation")) {
        try executionRotation(init, worker, &ledger, task, dir, recording);
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
    if (std.mem.eql(u8, mode, "stop")) {
        _ = try run(worker, task, "sleep 30", .{ .stop = true, .exit_code = 130 });
        // macOS Bash 3.2 reports interrupted builtin read as 1; Zsh uses 130.
        _ = try run(worker, task, "read -r answer", .{ .stop = true, .exit_code = 130, .alternate_exit_code = 1 });
        _ = try run(worker, task, "printf 'AFTER_STOP_%s\\n' ready", .{ .expected = "AFTER_STOP_ready", .exit_code = 0 });
        if (worker.vt.terminal != original_vt or worker.session.socket_fd != original_fd) return error.SessionWasReplaced;
        try release(worker, &ledger);
        std.debug.print("SHELL_EXECUTION_PASS mode=stop external_and_builtin_interrupted=true same_session=true\n", .{});
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

fn waitShell(worker: *Worker, previous: ?[32]u8, expected: ?[32]u8) !execution.Snapshot {
    const deadline = now() + 15_000;
    while (now() < deadline) {
        try worker.step(10);
        const value = try worker.executionSnapshot();
        const matches = if (expected) |id| std.meta.eql(value.shell.id, @as(?[32]u8, id)) else value.shell.id != null and !std.meta.eql(value.shell.id, previous);
        if (matches and value.input_ready) return value;
        try @import("ai/retry.zig").wait(1, null);
    }
    const last = try worker.executionSnapshot();
    std.debug.print("nested wait failure shell={any} pending={} failure={?s}\n", .{ last.shell, worker.startup_pending.load(.acquire), last.failure });
    return error.NestedShellNotReady;
}
// This isolated fixture starts known empty prompts. Exercise the same fresh
// screen/state evidence admission used by AI attachment after ordinary entry.
fn attachFixtureShell(worker: *Worker, task: identity.TaskId, prompt: []const u8, after_output: u64) !void {
    try worker.attachShell(try observeFixtureShell(worker, task, prompt, after_output));
}
fn observeFixtureShell(worker: *Worker, task: identity.TaskId, prompt: []const u8, after_output: u64) !execution.ShellAttachment {
    const deadline = now() + 5000;
    while (now() < deadline) {
        try tick(worker);
        const screen = try worker.searchText(a);
        defer a.free(screen);
        const trimmed = std.mem.trimEnd(u8, screen, " \t\r\n");
        const line = trimmed[if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |index| index + 1 else 0..];
        const empty_prompt = if (std.mem.eql(u8, prompt, "bash-")) std.mem.indexOf(u8, line, prompt) != null and (std.mem.endsWith(u8, line, "$") or std.mem.endsWith(u8, line, "#")) else std.mem.endsWith(u8, line, prompt);
        if (!empty_prompt or worker.vt.snapshot().output_sequence <= after_output or worker.input.pending() != 0 or worker.io.write_len != 0) continue;
        const snapshot = try worker.executionSnapshot();
        return .{ .task_id = task, .shell_id = snapshot.shell.id, .shell_revision = snapshot.shell.revision, .input_epoch = snapshot.input_epoch, .output_sequence = worker.vt.snapshot().output_sequence };
    }
    return error.FixturePromptNotObserved;
}

fn attachEvidence(worker: *Worker, task: identity.TaskId) !void {
    const original_fd = worker.session.socket_fd;
    const original_terminal = worker.vt.terminal;
    var before_output = worker.vt.snapshot().output_sequence;
    try worker.pushInputFrom("bash --noprofile --norc -i\r", .ordinary);
    _ = try observeFixtureShell(worker, task, "bash-", before_output);
    before_output = worker.vt.snapshot().output_sequence;
    try worker.pushInputFrom("(sleep 1; printf 'LATE_EVIDENCE_%s\\n' actual) &\r", .ordinary);
    const observed = try observeFixtureShell(worker, task, "bash-", before_output);
    try worker.attachShell(observed);
    if (worker.pushInputFrom("NEVER_DURING_ATTACH\r", .ordinary)) |_| return error.AttachmentGateBypassed else |err| if (err != error.TerminalControlled) return err;
    // Real peer output reaches the SSH stream after admission, while no
    // worker step has had a chance to begin the initializer's native write.
    try @import("ai/retry.zig").wait(1200, null);
    const deadline = now() + 5000;
    while (now() < deadline and worker.startup_pending.load(.acquire)) try tick(worker);
    if (worker.startup_pending.load(.acquire) or worker.shell_initializer_index != 0 or worker.input.pending() != 0) return error.StaleInitializerWasSent;
    if (!std.mem.eql(u8, (try worker.executionSnapshot()).failure orelse "", "ShellAttachmentStale")) return error.LateOutputDidNotReject;
    before_output = worker.vt.snapshot().output_sequence;
    try worker.pushInputFrom("\r", .ordinary);
    try attachFixtureShell(worker, task, "bash-", before_output);
    _ = try waitShell(worker, null, null);
    const current = try worker.executionSnapshot();
    const fresh: execution.ShellAttachment = .{ .task_id = task, .shell_id = current.shell.id, .shell_revision = current.shell.revision, .input_epoch = current.input_epoch, .output_sequence = worker.vt.snapshot().output_sequence };
    var wrong_shell = fresh;
    wrong_shell.shell_revision += 1;
    if (worker.attachShell(wrong_shell)) |_| return error.StaleShellEvidenceAccepted else |err| if (err != error.ShellContextChanged) return err;
    try worker.pushInputFrom("\r", .ordinary);
    if (worker.attachShell(fresh)) |_| return error.StaleInputEvidenceAccepted else |err| if (err != error.ShellAttachmentStale) return err;
    try waitReady(worker);
    _ = try run(worker, task, "printf 'EVIDENCE_RETRY_%s\\n' ok", .{ .expected = "EVIDENCE_RETRY_ok", .exit_code = 0 });
    if (worker.session.socket_fd != original_fd or worker.vt.terminal != original_terminal) return error.EvidenceRecoveryReplacedSession;
}
fn nestedShells(worker: *Worker, task: identity.TaskId, port: u16) !void {
    const root = (try worker.executionSnapshot()).shell.id orelse return error.NoRootShellIdentity;
    _ = try run(worker, task, "export ZW_PARENT=outer; cd /tmp; printf 'NESTED_PARENT_%s\\n' \"$ZW_PARENT\"", .{ .expected = "NESTED_PARENT_outer", .exit_code = 0 });
    try worker.pushInputFrom("bash --noprofile --norc -i\r", .ordinary);
    // This controlled fixture deliberately starts a clean Bash. Only the user
    // action supplies this admission boundary in the native product.
    for (0..20) |_| {
        try worker.step(10);
        try @import("ai/retry.zig").wait(1, null);
    }
    if ((try worker.executionSnapshot()).input_ready) return error.UnintegratedChildWasReady;
    try worker.attachCurrentShell();
    const first = try waitShell(worker, root, null);
    _ = try run(worker, task, "export ZW_INNER=kept; printf 'NESTED_INNER_%s_%s\\n' \"$ZW_PARENT\" \"$PWD\"", .{ .expected = "NESTED_INNER_outer_/tmp", .exit_code = 0 });
    try worker.attachCurrentShell();
    const same = try waitShell(worker, null, first.shell.id);
    if (same.shell.depth != first.shell.depth) return error.ReattachAddedLayer;
    const before_child = worker.vt.snapshot().output_sequence;
    try worker.pushInputFrom("bash --noprofile --norc -i\r", .ordinary);
    try attachFixtureShell(worker, task, "bash-", before_child);
    const second = try waitShell(worker, first.shell.id, null);
    if (second.shell.depth != first.shell.depth + 1) return error.NestedDepthWrong;
    _ = try run(worker, task, "printf 'NESTED_THIRD_%s_%s\\n' \"$ZW_INNER\" \"$PWD\"", .{ .expected = "NESTED_THIRD_kept_/tmp", .exit_code = 0 });
    const stale = execution.Request{ .execution_id = .generate(), .task_id = task, .expected_input_epoch = second.input_epoch, .expected_shell_id = second.shell.id, .expected_shell_revision = second.shell.revision, .ownership_revision = 1, .command = "echo NEVER_STALE_LAYER", .command_hash = execution.digest("echo NEVER_STALE_LAYER") };
    try worker.pushInputFrom("exit\r", .ordinary);
    _ = try waitShell(worker, null, first.shell.id);
    if (worker.executionRequest(stale)) |_| return error.StaleChildCommandAccepted else |err| if (err != error.ShellContextChanged) return err;
    _ = try run(worker, task, "printf 'NESTED_RETURN_%s\\n' \"$ZW_INNER\"", .{ .expected = "NESTED_RETURN_kept", .exit_code = 0 });
    try worker.pushInputFrom("exit\r", .ordinary);
    _ = try waitShell(worker, null, root);
    const ssh_entry = try std.fmt.allocPrint(a, "ssh -i \"$HOME/nested-test-key\" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -p {d} shell-fixture@127.0.0.1\r", .{port});
    defer a.free(ssh_entry);
    const before_ssh = worker.vt.snapshot().output_sequence;
    try worker.pushInputFrom(ssh_entry, .ordinary);
    try attachFixtureShell(worker, task, "fixture>", before_ssh);
    _ = try waitShell(worker, root, null);
    _ = try run(worker, task, "export ZW_REMOTE=remote; cd /tmp; printf 'NESTED_SSH_%s\\n' \"$ZW_REMOTE\"", .{ .expected = "NESTED_SSH_remote", .exit_code = 0 });
    _ = try run(worker, task, "printf 'NESTED_SSH_KEEP_%s_%s\\n' \"$ZW_REMOTE\" \"$PWD\"", .{ .expected = "NESTED_SSH_KEEP_remote_/tmp", .exit_code = 0 });
    try worker.pushInputFrom("exit\r", .ordinary);
    _ = try waitShell(worker, null, root);
    // An AI-issued entry remains an active parent observer while child
    // commands execute, then receives its own completion on child exit.
    const before = try worker.executionSnapshot();
    const parent_execution = identity.ExecutionId.generate();
    const before_ai = worker.vt.snapshot().output_sequence;
    try worker.executionRequest(.{ .execution_id = parent_execution, .task_id = task, .expected_input_epoch = before.input_epoch, .expected_shell_id = before.shell.id, .expected_shell_revision = before.shell.revision, .ownership_revision = 1, .command = "bash --noprofile --norc -i", .command_hash = execution.digest("bash --noprofile --norc -i") });
    try attachFixtureShell(worker, task, "bash-", before_ai);
    _ = try waitShell(worker, root, null);
    const suspended = try worker.executionSnapshotFor(parent_execution);
    if (!suspended.shell.suspended or suspended.process != null or suspended.grant != null) return error.ParentObserverWasLost;
    _ = try run(worker, task, "printf 'NESTED_AI_CHILD_%s\\n' \"$ZW_PARENT\"", .{ .expected = "NESTED_AI_CHILD_outer", .exit_code = 0 });
    try worker.pushInputFrom("exit\r", .ordinary);
    _ = try waitShell(worker, null, root);
    const deadline = now() + 5000;
    while (now() < deadline) {
        try worker.step(10);
        const result = try worker.executionSnapshotFor(parent_execution);
        if (result.interval_saved and result.process != null and result.process.?.exit_code == 0) return;
        try @import("ai/retry.zig").wait(1, null);
    }
    return error.ParentObserverNotSettled;
}

fn attachTimeout(worker: *Worker, task: identity.TaskId) !void {
    const original_fd = worker.session.socket_fd;
    const original_terminal = worker.vt.terminal;
    const before = worker.vt.snapshot().output_sequence;
    try worker.pushInputFrom("bash --noprofile --norc -i\r", .ordinary);
    try attachFixtureShell(worker, task, "bash-", before);
    const deadline = now() + 15_000;
    var expired = false;
    while (now() < deadline) {
        try tick(worker);
        if (!expired and worker.shell_initializer_index == 2 and worker.shell_execution.?.initialization_ack == 1) {
            // Force loss of the payload ACK after the 8 KiB batch is queued,
            // before the final eval is admitted. The real transport drains it.
            worker.shell_initializer_deadline = 0;
            expired = true;
        }
        if (expired and !worker.startup_pending.load(.acquire)) break;
    }
    if (!expired or worker.startup_pending.load(.acquire)) return error.AttachAbortDidNotRestore;
    if (!worker.shell_execution.?.initialization_restored or worker.input.pending() != 0 or worker.io.write_len != 0) return error.AttachAbortWasPremature;
    if (worker.session.socket_fd != original_fd or worker.vt.terminal != original_terminal) return error.AttachAbortReplacedSession;
    if (!std.mem.eql(u8, (try worker.executionSnapshot()).failure orelse "", "ShellInitializationTimedOut")) return error.AttachAbortLostFailure;
    const last_output = worker.vt.snapshot().output_sequence;
    try worker.pushInputFrom("printf 'POST_ABORT_%s\\n' ordinary\r", .ordinary);
    const echo_deadline = now() + 3000;
    var observed = false;
    while (now() < echo_deadline) {
        try tick(worker);
        const screen = try worker.searchText(a);
        defer a.free(screen);
        if (std.mem.indexOf(u8, screen, "_zwP+=") != null or std.mem.indexOf(u8, screen, "_zwR()") != null) return error.AbortedPayloadEscaped;
        if (std.mem.indexOf(u8, screen, "POST_ABORT_ordinary") != null) {
            observed = true;
            break;
        }
    }
    if (!observed) return error.AttachAbortLostOrdinaryInput;
    try attachFixtureShell(worker, task, "bash-", last_output);
    _ = try waitShell(worker, null, null);
    _ = try run(worker, task, "printf 'REATTACH_%s\\n' ok", .{ .expected = "REATTACH_ok", .exit_code = 0 });
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

fn executionRotation(init: std.process.Init, worker: *Worker, ledger: *ssh.ResourceLedger, task: identity.TaskId, dir: std.Io.Dir, recording: publication.Options) !void {
    const original_vt = worker.vt.terminal;
    const original_fd = worker.session.socket_fd;
    const first = try run(worker, task, "ZW_ROTATION_PID=$$; ZW_ROTATION_STATE=kept; printf 'ARCHIVED_%s\\n%70000s\\nARCHIVED_%s\\n' first '' last", .{ .expected = "ARCHIVED_first", .exit_code = 0 });
    for (1..136) |_| {
        const current = try run(worker, task, "test \"$ZW_ROTATION_PID:$ZW_ROTATION_STATE\" = \"$$:kept\"", .{ .exit_code = 0 });
        if (!current.owner.eql(first.owner) or current.recording_generation != first.recording_generation or !std.meta.eql(current.shell.id, first.shell.id)) return error.SessionWasReplaced;
    }
    if (worker.session.socket_fd != original_fd or worker.vt.terminal != original_vt) return error.SessionWasReplaced;
    const parent_path = try @import("vt/recording_manifest.zig").pathForCast(a, recording.cast_path);
    defer a.free(parent_path);
    const parent = try @import("vt/recording_manifest.zig").load(a, init.io, dir, parent_path);
    defer parent.deinit();
    const first_id = std.fmt.bytesToHex(first.execution_id.?.bytes, .lower);
    for (parent.value.execution_ranges) |range| {
        if (std.mem.eql(u8, range.execution_id, &first_id)) return error.ArchivedRangeStillActive;
    }
    // Force the old output out of the live ring before reading the archive.
    for (0..worker.timeline.max_events) |_| try worker.timeline.append(realtime.milliseconds(undefined), worker.io.stream_offset, "");
    try queryRotatedExecution(init.io, dir, first);
    try release(worker, ledger);
    _ = try worker.execution_recording.?.persist(worker.io.stream_offset, realtime.milliseconds(undefined));
    try queryRotatedExecution(init.io, dir, first);
    std.debug.print("SHELL_EXECUTION_PASS mode=execution-rotation executions=136 same_session=true same_shell=true archived_query_live=true archived_query_closed=true\n", .{});
}

fn queryRotatedExecution(io: std.Io, dir: std.Io.Dir, first: execution.Snapshot) !void {
    const host = @import("ai/host_tools.zig");
    const queries = @import("ai/host_terminal_queries.zig");
    const Access = @import("ui/ai_recording_query_access.zig").Access;
    const owner = first.owner;
    const context: host.Context = .{
        .conversation_id = .generate(),
        .task_id = .generate(),
        .binding = .{ .session = @backingInt(owner.session_id) },
        .binding_revision = 1,
        .grant_revision = 1,
    };
    const id = first.recording_id.?;
    var access = try Access.init(a, .{ .allocator = a, .io = io, .dir = dir }, context);
    defer access.deinit();
    try access.captureRecordingIdentity(owner, id, first.recording_generation);
    const reference = try queries.recordingRef(a, context, id, first.recording_generation);
    defer a.free(reference);
    const command_ref = try queries.executionCommandRef(a, context.conversation_id, owner, first.execution_id.?);
    defer a.free(command_ref);
    const arguments = try std.json.Stringify.valueAlloc(a, .{ .recording_ref = reference, .range_kind = "command", .command_ref = command_ref }, .{});
    defer a.free(arguments);
    var next = try a.dupe(u8, arguments);
    defer a.free(next);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    for (1..64) |operation| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, next, .{});
        defer parsed.deinit();
        var result = try access.execute(.{ .context = context, .authority = .conversation_context, .operation_id = operation, .turn_id = 1, .call_id = "execution-rotation", .tool_id = "host.read_terminal", .arguments = parsed.value, .arguments_json = next, .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) }, a);
        defer result.deinit(a);
        const response = try std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{});
        defer response.deinit();
        if (response.value.object.get("output")) |chunk| try output.appendSlice(a, chunk.string);
        const cursor = response.value.object.get("next_cursor") orelse return error.ArchivedExecutionOutputMissing;
        if (cursor == .null) {
            if (output.items.len < 70_000 or std.mem.indexOf(u8, output.items, "ARCHIVED_first") == null or std.mem.indexOf(u8, output.items, "ARCHIVED_last") == null) return error.ArchivedExecutionOutputMissing;
            const process = response.value.object.get("process_receipt") orelse return error.ArchivedExecutionReceiptMissing;
            if (process.object.get("exit_code").?.integer != 0) return error.ArchivedExecutionReceiptMissing;
            return;
        }
        const continuation = try std.json.Stringify.valueAlloc(a, .{ .recording_ref = reference, .range_kind = "cursor", .cursor = cursor.string }, .{});
        a.free(next);
        next = continuation;
    }
    return error.ArchivedExecutionPaginationDidNotFinish;
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
    const accepted = try app.create(.{ .connection_id = @fromBackingInt(77), .revision = 1, .name = "init-recovery", .host = "127.0.0.1", .port = port, .user = "shell-fixture", .auth_mode = .password, .password = "fixture-only", .startup_commands = &.{"echo CONFIGURED_STARTUP"} }, 1, 0, "echo NEVER_REPLAY_INITIAL\n");
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
                    live.executionRequest(.{ .execution_id = ai_id, .task_id = .generate(), .expected_input_epoch = snapshot.input_epoch, .expected_shell_id = snapshot.shell.id, .expected_shell_revision = snapshot.shell.revision, .ownership_revision = 1, .command = ai_command, .command_hash = execution.digest(ai_command) }) catch |err| switch (err) {
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
                        std.debug.print("SHELL_EXECUTION_PASS mode={s} same_tab=true automatic_retries=1 confirmed_bypass={} settings_unchanged=true ordinary_input=true startup_per_shell=true reconnected_ai_recorded={}\n", .{ mode, confirmed, ai_finished });
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
const Checks = struct { expected: []const u8 = "", extra: []const u8 = "", exit_code: u8, alternate_exit_code: ?u8 = null, stream: bool = false, input: bool = false, handoff: bool = false, stop: bool = false };
fn run(worker: *Worker, task: identity.TaskId, command: []const u8, checks: Checks) !execution.Snapshot {
    try waitReady(worker);
    const id = identity.ExecutionId.generate();
    const admission_deadline = now() + 3000;
    while (true) {
        const before = try worker.executionSnapshot();
        // D (finished) and the next A/B (empty prompt) can be separate packets.
        // InputConflict is a pre-write rejection, so only that admission may be
        // retried. Never retry an accepted request or clear a user's draft.
        worker.executionRequest(.{ .execution_id = id, .task_id = task, .expected_input_epoch = before.input_epoch, .expected_shell_id = before.shell.id, .expected_shell_revision = before.shell.revision, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) }) catch |err| {
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
        if (checks.stop and input_stage == 0 and snapshot.state == .running) {
            try worker.executionRevoke(snapshot.grant.?, false);
            input_stage = 1;
        }
        if (snapshot.state == .interval_recorded) {
            const expected_exit = snapshot.process != null and (snapshot.process.?.exit_code == checks.exit_code or (checks.alternate_exit_code != null and snapshot.process.?.exit_code == checks.alternate_exit_code));
            if (snapshot.completion_source != .shell_reported or !expected_exit or !snapshot.interval_saved or snapshot.output_scope != .session_interval) return error.FalseCompletionReceipt;
            if (snapshot.start == null or snapshot.end == null or snapshot.start.?.event_sequence >= snapshot.end.?.event_sequence) return error.MissingOrderedBoundaries;
            if (checks.stream and !streamed) return error.StreamWasNotVisibleBeforeFinish;
            if (checks.stop and input_stage != 1) return error.StopWasNotRequested;
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
    try worker.executionRequest(.{ .execution_id = .generate(), .task_id = task, .expected_input_epoch = before.input_epoch, .expected_shell_id = before.shell.id, .expected_shell_revision = before.shell.revision, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command) });
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

fn configuredStartup(init: std.process.Init, port: u16, directory: []const u8, mode: []const u8) !void {
    const interactive = std.mem.eql(u8, mode, "startup-interactive");
    const timeout = std.mem.eql(u8, mode, "startup-timeout");
    const commands: []const []const u8 = if (interactive)
        &.{ "read -r ZW_REPLY; printf 'ANSWER_%s\\n' \"$ZW_REPLY\"", "printf FORBIDDEN_NEXT" }
    else if (timeout)
        &.{"printf FORBIDDEN_STARTUP"}
    else
        &.{ "cd /tmp", "export ZW_STARTUP_SEQ=ok", "printf 'STARTUP_%s/%s\\n' \"$PWD\" \"$ZW_STARTUP_SEQ\"" };
    var library = try ssh.Library.init();
    defer library.deinit();
    var ledger = try ssh.ResourceLedger.init(.{ .owner = .{ .session = .{ .session_id = @fromBackingInt(71) } }, .operation_id = 1, .attempt_id = 1 }, 1);
    const worker = try Worker.init(a, &library, .{ .host = "127.0.0.1", .port = port, .user = "shell-fixture", .auth = .{ .password = "fixture-only" }, .host_key_decision = .trust_once, .operation_key = ledger.key, .resource_ledger = &ledger, .connect_timeout_ms = 5000, .keepalive_sec = 0 }, .{ .auto_reconnect = false, .startup_commands = commands, .initial_input = if (interactive or timeout) "" else "printf 'INITIAL_%s\\n' once\n", .wait_for_attachment = true, .keepalive_sec = 0 });
    defer worker.deinit();
    const dir = try std.Io.Dir.cwd().openDir(init.io, directory, .{});
    defer dir.close(init.io);
    const recording: publication.Options = .{ .recording_id = worker.recording_id, .archive_key = worker.archive_key, .generations = worker.recording_generations.items, .cast_path = "logs/startup.cast", .started_ms = realtime.milliseconds(undefined), .display = .{ .title = "Startup commands", .host = "127.0.0.1", .user = "shell-fixture" }, .timeline = &worker.timeline };
    try publication.reserve(a, init.io, dir, recording);
    try worker.configureExecutionRecording(init.io, dir, recording);
    worker.markAttached();
    var stopped = false;
    var resumed = false;
    const deadline = now() + 18_000;
    while (now() < deadline) {
        try tick(worker);
        const snapshot = try worker.executionSnapshot();
        if ((interactive or timeout) and !worker.startup_pending.load(.acquire)) {
            if (snapshot.failure) |failure| {
                if (std.mem.eql(u8, failure, "StartupPromptTimedOut")) stopped = true;
            }
            if (stopped and !resumed and (interactive or snapshot.shell.prompt_ready == true)) {
                try worker.pushInputFrom(if (interactive) "answer\n" else "printf 'MANUAL_%s\\n' ready\n", .ordinary);
                resumed = true;
            }
        }
        const text = try worker.searchText(a);
        defer a.free(text);
        if (std.mem.indexOf(u8, text, "FORBIDDEN_") != null) return error.StartupCommandLeaked;
        const ready = if (interactive) stopped and resumed and std.mem.indexOf(u8, text, "ANSWER_answer") != null else if (timeout) stopped and resumed and std.mem.indexOf(u8, text, "MANUAL_ready") != null else std.mem.indexOf(u8, text, "STARTUP_/tmp/ok") != null and std.mem.indexOf(u8, text, "INITIAL_once") != null;
        if (ready) {
            std.debug.print("SHELL_EXECUTION_PASS {s} stopped={any} resumed={any}\n", .{ mode, stopped, resumed });
            return;
        }
    }
    return error.StartupAcceptanceTimedOut;
}

fn configuredReconnect(init: std.process.Init, port: u16, directory: []const u8) !void {
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
    config.ssh.auto_reconnect = false;
    const path = try std.fmt.allocPrint(a, "{s}/hosts.toml", .{directory});
    defer a.free(path);
    const workspace = try Workspace.init(a, cx, scope, init.io, &config, path, nodes[0], nodes[1], nodes[2], nodes[3]);
    const app = try Application.init(a, workspace);
    try scope.onCleanup(Application, app, Application.deinit);
    app.install();
    _ = try workspace.registry.add(.{ .name = "reconnect-startup", .host = "127.0.0.1", .port = port, .user = "shell-fixture", .auth_mode = .password, .password = "fixture-only", .startup_commands = &.{"cd /tmp; export ZW_STARTUP=one; printf 'STARTUP_%s\\n' one"} });
    const accepted = try app.create(workspace.registry.hosts[0], 1, 0, "printf 'INITIAL_%s\\n' once\n");
    const id = app.legacyForHandle(accepted.handle) orelse return error.MissingTab;
    const tab = workspace.sessionTab(id).?;
    const original_root = tab.root;
    var original_worker: ?*Worker = null;
    var probed: u64 = 0;
    var exited: u64 = 0;
    var retried: u64 = 0;
    const started = now();
    const deadline = started + 25_000;
    while (now() < deadline) {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
        _ = try app.safeTick();
        if (workspace.pendingAuthentication()) |challenge| try workspace.submitAuthentication(challenge.identity, .trust_once);
        if (workspace.sessionTab(id) != tab or tab.root != original_root) return error.ReconnectReplacedPane;
        const runtime = tab.runtime orelse continue;
        const native: *@import("ui/session_runtime.zig").SessionRuntime = @ptrCast(@alignCast(runtime.context));
        // A headless Cx has no native frame loop to consume published frames.
        // Drain presentation so a real shell EOF can publish its final frame.
        _ = native.worker.text.acknowledge(0);
        if (original_worker) |worker| {
            if (worker != native.worker) return error.ReconnectReplacedWorker;
        } else original_worker = native.worker;
        const handle = app.ownerForLegacy(id) orelse return error.LostMapping;
        const state = runtime.reconnectSnapshot() orelse continue;
        const generation = handle.generation;
        if (generation > 3) return error.UnexpectedReconnect;
        if (state.phase == .ended and state.cleanup == .released and retried < generation) {
            if (generation == 1) {
                config.ssh.auto_shell_integration = false;
                workspace.registry.hosts[0].startup_commands = &.{"cd /tmp; export ZW_STARTUP=two; printf 'STARTUP_%s\\n' two"};
            } else {
                // A host override must take precedence over the disabled global.
                workspace.registry.hosts[0].auto_shell_integration = true;
                workspace.registry.hosts[0].startup_commands = &.{"cd /tmp; export ZW_STARTUP=three; printf 'STARTUP_%s\\n' three"};
            }
            try app.requestSshReconnect(id);
            retried = generation;
        }
        if (state.phase == .active and state.shell_initialized and probed < generation) {
            if (native.worker.startup_pending.load(.acquire) or native.worker.input.pending() != 0) continue;
            const binding = switch (app.sessions.queryService(handle, .terminal)) {
                .available => |value| value,
                else => continue,
            };
            const live = runtime.bindTerminalService(binding) catch continue;
            const snapshot = live.executionSnapshot() catch continue;
            if (snapshot.interactive_execution != (generation != 2)) return error.StaleInitializationPolicy;
            // Reading the environment from the new shell proves startup execution,
            // rather than merely checking that input was queued by the client.
            runtime.pushInputFrom("printf 'ENV_%s_%s\\n' \"$ZW_STARTUP\" \"$PWD\"\r", .ordinary) catch continue;
            probed = generation;
        }
        if (probed == generation and exited < generation) {
            const screen = runtime.searchText(a) catch continue;
            defer a.free(screen);
            const expected = switch (generation) {
                1 => "ENV_one_/tmp",
                2 => "ENV_two_/tmp",
                else => "ENV_three_/tmp",
            };
            if (std.mem.indexOf(u8, screen, expected) == null) continue;
            std.debug.print("CONFIGURED_SHELL_READY generation={d} integration={} elapsed_ms={d}\n", .{ generation, generation != 2, now() - started });
            if (generation == 3) {
                const close = try app.requestCloseLegacy(id);
                const until = now() + 5000;
                while (now() < until) {
                    _ = try app.safeTick();
                    if (app.sessions.queryState(close.owner.session).?.lifecycle == .closed and workspace.sessionTab(id) == null) {
                        std.debug.print("SHELL_EXECUTION_PASS mode=reconnect-startup generations=3 same_pane=true same_worker=true startup_per_shell=true current_settings=true host_override=true\n", .{});
                        return;
                    }
                    var fds: [1]std.c.pollfd = undefined;
                    _ = std.c.poll(&fds, 0, 2);
                }
                return error.ConfiguredReconnectCloseTimeout;
            }
            runtime.pushInputFrom("exit\r", .ordinary) catch continue;
            exited = generation;
        }
        var fds: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&fds, 0, 2);
    }
    return error.ConfiguredReconnectTimedOut;
}
