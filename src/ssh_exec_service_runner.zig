//! Real production Session + Exec mailbox driven by one owned IO thread.
//! The loopback peer acknowledges exec packets without starting a process.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const Exec = @import("proto/ssh/exec_bridge.zig").SshExecBridge;
const types = @import("ai/execbridge.zig");
const operation = @import("host/operation.zig");
const host = @import("host/session_host.zig");
const c = @import("generated_ssh_session");
const realtime = @import("platform/realtime.zig");

const Io = struct {
    exec: *Exec,
    session: *ssh.Session,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    pty_bytes: std.atomic.Value(usize) = .init(0),
    fn run(self: *Io) void {
        var buffer: [4096]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            self.exec.step() catch {
                self.failed.store(true, .release);
                return;
            };
            var reader = self.session.reader() catch {
                self.failed.store(true, .release);
                return;
            };
            for (0..4) |_| {
                switch (reader.read(&buffer) catch {
                    self.failed.store(true, .release);
                    return;
                }) {
                    .bytes => |count| _ = self.pty_bytes.fetchAdd(count, .release),
                    .would_block, .eof => break,
                }
            }
            pause(1);
        }
    }
};

fn pause(ms: c_int) void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, ms);
}
fn snapshot(service: *const types.ExecBridge, handle: types.ExecHandle) !types.OwnedResult {
    while (true) return service.snapshot(handle, std.heap.c_allocator) catch |err| {
        if (err == error.WorkerBusy) {
            pause(1);
            continue;
        }
        return err;
    };
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const mode = args.next() orelse return error.MissingMode;
    var library = try ssh.Library.init();
    defer library.deinit();
    const owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 2 };
    var journal = operation.Journal.init(std.heap.c_allocator);
    defer journal.deinit();
    const create_key = try journal.begin(.{ .session = owner }, 1);
    var ledger = try ssh.ResourceLedger.init(create_key, 1);
    var session = try ssh.Session.connect(&library, .{ .host = "127.0.0.1", .port = port, .user = "fixture", .auth = .{ .password = "fixture-password" }, .host_key_decision = .trust_once, .connect_timeout_ms = 1500, .open_shell = true, .operation_key = create_key, .resource_ledger = &ledger });
    defer session.close();
    const fd = session.socket_fd;
    var service = Exec.init(&session, std.heap.c_allocator);
    defer service.deinitLocal();
    // Fixture binding matches the real Session identity. Host registration/UI
    // projection is deliberately outside this narrow native service runner.
    const binding: host.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .exec, .binding_id = 3, .binding_generation = 2 };
    try service.bindService(binding);
    const facade = service.asBridge();
    const key = try journal.begin(.{ .session = owner }, 1);
    const command = try std.fmt.allocPrint(std.heap.c_allocator, "fixture-{s}", .{mode});
    defer std.heap.c_allocator.free(command);
    const opts: types.ExecOpts = .{ .key = key, .call_id = 1, .service_binding = binding, .capture_cap = if (std.mem.eql(u8, mode, "capture")) 4096 else 64 * 1024, .timeout_ms = if (std.mem.eql(u8, mode, "timeout")) 150 else 3000, .cwd = if (std.mem.eql(u8, mode, "cwd")) "/tmp/a'b\n$(not-a-command)" else null };
    const handle = try facade.exec(command, opts);
    const duplicate = try facade.exec(command, opts);
    if (handle.ptr != duplicate.ptr) return error.DuplicateCallWasQueued;
    if (std.mem.eql(u8, mode, "queued-cancel")) facade.cancel(handle);
    var io: Io = .{ .exec = &service, .session = &session };
    const thread = try std.Thread.spawn(.{}, Io.run, .{&io});
    var joined = false;
    defer {
        io.stop.store(true, .release);
        if (!joined) thread.join();
        service.close();
        if (session.closeReceipt() == .released) service.sessionReleased() catch {};
    }
    const started = realtime.monotonicNs();
    var cancelled = false;
    var saw_unknown = false;
    var result: types.ExecResult = undefined;
    while (true) {
        if (io.failed.load(.acquire)) return error.IoWorkerFailed;
        if (realtime.monotonicNs() - started > 8 * std.time.ns_per_s) return error.RunnerTimeout;
        var value = try snapshot(&facade, handle);
        defer value.deinit();
        const current = value.value;
        const cancel_mode = std.mem.eql(u8, mode, "cancel") or std.mem.eql(u8, mode, "close-unknown");
        if (!cancelled and ((cancel_mode and current.status == .running) or (std.mem.eql(u8, mode, "open-cancel") and current.status == .opening))) {
            facade.cancel(handle);
            cancelled = true;
        }
        if (facade.poll(handle)) |terminal| {
            if (std.mem.eql(u8, mode, "close-unknown")) {
                if (terminal.cleanup == .unknown) {
                    saw_unknown = true;
                    if (terminal.status != .cancelled or terminal.exit_code != null or terminal.effect != .unknown) return error.CancelWasMisreported;
                    if (session.state != .active or std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)) < 0) return error.ParentWasClosedForChild;
                    break;
                }
            } else if (terminal.cleanup == .released) {
                result = terminal;
                break;
            }
        }
        pause(1);
    }
    if (std.mem.eql(u8, mode, "close-unknown")) {
        io.stop.store(true, .release);
        thread.join();
        joined = true;
        if (session.closeReceipt() != .released) return error.FinalParentCleanupFailed;
        try service.sessionReleased();
        result = facade.poll(handle).?;
        if (result.cleanup != .released or result.effect != .unknown) return error.ParentReceiptWasNotApplied;
    } else {
        if (result.key == null or !result.key.?.eql(key) or result.call_id != 1 or result.service_binding == null or !result.service_binding.?.eql(binding)) return error.CallIdentityChanged;
        if (!std.mem.eql(u8, result.command, command)) return error.CommandWasNotFrozen;
        if (std.mem.eql(u8, mode, "capture")) {
            if (result.status != .completed or result.exit_code != 7 or !result.truncated or result.stdout.len + result.stderr.len != 4096 or result.stdout_bytes != 3 * 1024 * 1024 or result.stderr_bytes != 3 * 1024 * 1024) return error.CaptureWasNotDrained;
            for (result.stdout) |byte| if (byte != 'A') return error.StdoutCorrupted;
            for (result.stderr) |byte| if (byte != 'B') return error.StderrCorrupted;
        } else if (std.mem.eql(u8, mode, "no-exit")) {
            if (result.status != .completed or result.exit_code != null or result.effect != .unknown) return error.MissingExitBecameZero;
        } else if (std.mem.eql(u8, mode, "reject")) {
            if (result.status != .channel_rejected or result.exit_code != null or result.effect != .none) return error.RejectionWasMisreported;
        } else if (std.mem.eql(u8, mode, "cancel") or std.mem.eql(u8, mode, "timeout")) {
            if (result.status != (if (std.mem.eql(u8, mode, "cancel")) types.Status.cancelled else .timed_out) or result.exit_code != null or result.effect != .unknown) return error.InterruptionWasMisreported;
        } else if (std.mem.eql(u8, mode, "queued-cancel") or std.mem.eql(u8, mode, "open-cancel")) {
            if (result.status != .cancelled or result.exit_code != null or result.effect != .none) return error.UnsentExecWasMisreported;
        } else if (result.status != .completed or result.exit_code != 0) return error.ActualZeroExitMissing;
        // The original PTY remains live throughout every child lifecycle.
        const deadline = realtime.monotonicNs() + std.time.ns_per_s;
        const expected_pty: usize = if (std.mem.eql(u8, mode, "queued-cancel")) 17 else 33;
        while (io.pty_bytes.load(.acquire) < expected_pty and realtime.monotonicNs() < deadline) pause(1);
        if (io.pty_bytes.load(.acquire) < expected_pty or std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)) < 0) return error.PtyWasNotIndependent;
    }
    if (result.key == null or !result.key.?.eql(key) or result.call_id != 1 or result.service_binding == null or !result.service_binding.?.eql(binding)) return error.CallIdentityChanged;
    if (saw_unknown and io.pty_bytes.load(.acquire) < 33) return error.UnknownChildInterruptedPty;
    std.debug.print("PASS mode={s} status={s} exit={any} cleanup={s} effect={s} captured={d} stdout_bytes={d} stderr_bytes={d} truncated={any} pty_read={d} call_id={d} original_key=true unknown_before_parent={any} elapsed_ms={d}\n", .{ mode, @tagName(result.status), result.exit_code, @tagName(result.cleanup), @tagName(result.effect), result.stdout.len + result.stderr.len, result.stdout_bytes, result.stderr_bytes, result.truncated, io.pty_bytes.load(.acquire), result.call_id, saw_unknown, result.elapsed_ms });
    while (true) {
        const receipt = facade.closeCall(handle) catch |err| {
            if (err == error.WorkerBusy) {
                pause(1);
                continue;
            }
            return err;
        };
        if (receipt != .released) return error.TerminalCallWasNotRetired;
        break;
    }
}
