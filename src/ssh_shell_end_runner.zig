//! Loopback-only production SSH/VT worker and IO-thread shell EOF driver.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const SshWorker = @import("vt/ssh_worker.zig").SshWorker;
const Thread = @import("vt/ssh_worker_thread.zig").Thread;
const operation = @import("host/operation.zig");
const realtime = @import("platform/realtime.zig");
const frame = @import("vt/text_frame.zig");

fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const mode = args.next() orelse return error.MissingMode;
    const network = std.mem.eql(u8, mode, "network");
    const allocator = std.heap.c_allocator;
    var library = try ssh.Library.init();
    defer library.deinit();
    var journal = operation.Journal.init(allocator);
    defer journal.deinit();
    const key = try journal.begin(.{ .session = .{ .session_id = @fromBackingInt(91) } }, 1);
    var ledger = try ssh.ResourceLedger.init(key, 1);
    const worker = try SshWorker.init(allocator, &library, .{
        .host = "127.0.0.1",
        .port = port,
        .user = "fixture",
        .auth = .{ .password = "fixture-password" },
        .host_key_decision = .trust_once,
        .operation_key = key,
        .attempt_id = 1,
        .resource_ledger = &ledger,
    }, .{ .auto_reconnect = true, .reconnect_max = 1, .reconnect_backoff = .{ 1, 1, 1, 1, 1 }, .connect_timeout_ms = 1500, .keepalive_sec = 0 });
    const original_vt = worker.vt.terminal;
    const original_fd = worker.session.socket_fd;
    const thread = try Thread.start(allocator, worker);
    defer thread.deinit();
    const scratch = try allocator.alloc(u8, @import("vt/text_slot.zig").TextSlot.default_capacity);
    defer allocator.free(scratch);
    var generation: u64 = 0;
    var ready = false;
    var tail = false;
    var second_ready = false;
    var sent = false;
    var successor: ?operation.OperationKey = null;
    var ended_at: ?i128 = null;
    const deadline = realtime.monotonicNs() + 6 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        if (try worker.textSlot().take(generation, scratch)) |value| {
            generation = value.generation;
            const decoded = frame.decode(value.text) orelse return error.BadTerminalFrame;
            ready = ready or std.mem.indexOf(u8, decoded.text, "first-ready") != null;
            tail = tail or std.mem.indexOf(u8, decoded.text, "shell-final-tail") != null;
            second_ready = second_ready or std.mem.indexOf(u8, decoded.text, "second-ready") != null;
        }
        if (ready and !sent) {
            try worker.pushInput("END\n");
            sent = true;
        }
        const notice = thread.reconnectSnapshot();
        if (notice.phase == .waiting and notice.cleanup == .released) {
            if (!network) {
                std.debug.print("MISCLASSIFIED failure={s} tail={}\n", .{ @errorName(notice.failure.?), tail });
                return error.NormalShellEnteredReconnect;
            }
            if (!thread.hasFailed() or notice.failure == null) return error.NetworkLossWasNotFailure;
            if (successor != null) return error.DuplicateReconnect;
            var owner = key.owner.session;
            owner.generation += 1;
            const next = try journal.begin(.{ .session = owner }, 2);
            try thread.requestReconnect(key, next);
            successor = next;
        }
        if (network and notice.phase == .ready) {
            if (successor == null or !notice.key.?.eql(successor.?) or worker.vt.terminal != original_vt) return error.ReconnectIdentityChanged;
            if (!thread.markAttached(successor.?)) return error.AttachRejected;
        }
        if (network and successor != null and notice.phase == .active and second_ready) {
            if (thread.hasFailed()) return error.ReconnectedWorkerFailed;
            std.debug.print("PASS mode=network phase=active generation=2 same_vt=true original_tail={}\n", .{tail});
            return;
        }
        if (notice.phase == .ended and notice.cleanup == .released) {
            if (network or thread.hasFailed() or notice.failure != null or !notice.key.?.eql(key)) return error.NormalEndWasFailure;
            const expected: ?i32 = if (std.mem.eql(u8, mode, "unknown")) null else if (std.mem.eql(u8, mode, "exit7")) 7 else 0;
            if (notice.exit_code != expected) {
                std.debug.print("BAD_EXIT expected={any} actual={any}\n", .{ expected, notice.exit_code });
                return error.ExitStatusWasMisreported;
            }
            if (!tail) return error.TailWasLost;
            if (std.c.fcntl(original_fd, std.c.F.GETFL, @as(c_int, 0)) >= 0 or !ledger.snapshot().released()) return error.ResourcesNotReleased;
            try expectReadOnly(worker);
            if (ended_at == null) ended_at = realtime.monotonicNs();
            if (realtime.monotonicNs() - ended_at.? >= 1200 * std.time.ns_per_ms) {
                std.debug.print("PASS mode={s} phase=ended exit={any} failure=null released=true tail=true generation=1 no_grant=true read_only=true held_ms=1200\n", .{ mode, notice.exit_code });
                return;
            }
        }
        pause();
    }
    const current = thread.reconnectSnapshot();
    std.debug.print("TIMEOUT phase={s} failure={any} ready={} tail={}\n", .{ @tagName(current.phase), current.failure, ready, tail });
    return error.ShellEndTimeout;
}

fn expectReadOnly(worker: *SshWorker) !void {
    if (worker.allowsBufferedOrdinaryInput() or worker.inputSnapshot().queued != 0) return error.EndedShellStillBuffers;
    worker.pushInputFrom("late", .ordinary) catch |err| {
        if (err != error.SessionClosed) return err;
        worker.pushInput("application") catch |application_error| {
            if (application_error != error.SessionClosed) return application_error;
            return;
        };
        return error.EndedShellAcceptedApplication;
    };
    return error.EndedShellAcceptedInput;
}
