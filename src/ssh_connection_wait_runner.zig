//! Actual SSH loopback cancellation/timeout runner. Never starts a process,
//! shell or PTY; its test server only exchanges the corresponding packets.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const c = @import("generated_ssh_session");
const realtime = @import("platform/realtime.zig");

const Canceller = struct {
    token: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
    at_ns: *std.atomic.Value(i64),
    fn run(self: @This()) void {
        while (!self.done.load(.acquire)) {
            var descriptor = [_]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&descriptor, 1, 25) > 0) {
                var byte: u8 = 0;
                if (std.c.read(0, @ptrCast(&byte), 1) != 1) return;
                self.at_ns.store(@intCast(realtime.monotonicNs()), .release);
                self.token.store(true, .release);
                return;
            }
        }
    }
};

const Prompt = struct {
    calls: usize = 0,
    delay_ms: c_int = 0,
    fn answer(raw: *anyopaque, _: []const u8, buffer: []u8) ?[]const u8 {
        const self: *Prompt = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.delay_ms != 0) {
            var unused: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&unused, 0, self.delay_ms);
        }
        const value = "fixture-answer";
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const stage = args.next() orelse return error.MissingStage;
    const mode = args.next() orelse return error.MissingMode;
    const cancelling = std.mem.eql(u8, mode, "cancel");
    const succeeding = std.mem.eql(u8, mode, "success");
    var library = try ssh.Library.init();
    defer library.deinit();
    const fd = c.zw_ssh_socket_connect("127.0.0.1", port, 1000);
    if (fd < 0) return error.ConnectFailed;
    var untransferred_fd = fd;
    defer if (untransferred_fd >= 0) c.zw_ssh_socket_close(untransferred_fd);
    var token: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    var cancelled_at: std.atomic.Value(i64) = .init(0);
    const thread = if (cancelling) try std.Thread.spawn(.{}, Canceller.run, .{Canceller{ .token = &token, .done = &done, .at_ns = &cancelled_at }}) else null;
    defer if (thread) |value| value.join();
    defer done.store(true, .release);
    var prompts: Prompt = .{ .delay_ms = if (std.mem.eql(u8, stage, "keyboard-delay")) 250 else 0 };
    const started = realtime.monotonicNs();
    var session: ?ssh.Session = null;
    var failure: ?anyerror = null;
    untransferred_fd = -1;
    session = ssh.Session.connectOverFd(&library, .{
        .host = "127.0.0.1",
        .port = port,
        .user = "fixture",
        .auth = if (std.mem.startsWith(u8, stage, "agent")) .agent else if (std.mem.startsWith(u8, stage, "keyboard")) .keyboard_interactive else .{ .password = "fixture-password" },
        .keyboard_prompt = .{ .ctx = &prompts, .callback = Prompt.answer },
        .open_shell = std.mem.eql(u8, stage, "channel") or std.mem.eql(u8, stage, "pty") or std.mem.startsWith(u8, stage, "shell"),
        .host_key_decision = .trust_once,
        .connect_timeout_ms = if (cancelling) 3000 else 180,
        .cancel_token = &token,
    }, fd) catch |err| blk: {
        failure = err;
        break :blk null;
    };
    const finished = realtime.monotonicNs();
    done.store(true, .release);
    defer if (session) |*value| value.close();
    if (succeeding) {
        if (failure != null or session == null or session.?.state != .active) return error.CreationDidNotComplete;
        const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        if (std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)) & nonblock == 0) return error.NativeSocketBlocking;
        if (std.mem.eql(u8, stage, "shell-success") and session.?.channel == null) return error.ShellMissing;
        if (std.mem.eql(u8, stage, "keyboard-delay") and prompts.calls != 1) return error.PromptWasReplayed;
        session.?.close();
        session = null;
        if (std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)) != -1 or std.c._errno().* != @as(c_int, @backingInt(std.c.E.BADF))) return error.OwnedFdNotClosed;
        std.debug.print("PASS stage={s} mode=success active_nonblocking=true fd_closed=true prompts={d}\n", .{ stage, prompts.calls });
        return;
    }
    if (session != null or failure != @as(?anyerror, if (cancelling) error.Cancelled else error.ConnectionTimedOut)) return error.UnexpectedConnectionOutcome;
    if (std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)) != -1 or std.c._errno().* != @as(c_int, @backingInt(std.c.E.BADF))) return error.OwnedFdNotClosed;
    const elapsed_ms = @divTrunc(finished - started, std.time.ns_per_ms);
    const cancel_ns = cancelled_at.load(.acquire);
    const cancel_latency_ms = if (cancel_ns > 0) @divTrunc(finished - cancel_ns, std.time.ns_per_ms) else -1;
    if (cancelling and (cancel_ns <= 0 or cancel_latency_ms > 500)) return error.CancellationWasSlow;
    if (!cancelling and (elapsed_ms < 150 or elapsed_ms > 1500)) return error.TimeoutWasIncorrect;
    if (std.mem.eql(u8, stage, "keyboard-response") and prompts.calls != 1) return error.PromptWasReplayed;
    std.debug.print("PASS stage={s} mode={s} failure={s} elapsed_ms={d} cancel_latency_ms={d} fd_closed=true prompts={d}\n", .{ stage, mode, @errorName(failure.?), elapsed_ms, cancel_latency_ms, prompts.calls });
}
