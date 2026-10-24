//! No window, network, build/root imports or user data. Run with:
//! zig test src/local_process_tests.zig src/local/darwin_process.c -lc
const std = @import("std");
const pty = @import("local/pty.zig");
const exec = @import("local/exec.zig");
const native = @import("local/native.zig");
const identity = @import("host/identity.zig");
const operation = @import("host/operation.zig");
const allocator = std.testing.allocator;
test {
    _ = @import("local/path_input.zig");
}
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;

fn owner(id: u64) identity.SessionHandle {
    return .{ .session_id = @fromBackingInt(id) };
}
fn key(id: u64) operation.OperationKey {
    return .{ .owner = .{ .session = owner(id) }, .operation_id = id, .attempt_id = 1 };
}
fn pause() void {
    const delay: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
}
const Sandbox = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    old_zdotdir: ?[:0]u8,

    fn init() !Sandbox {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "setopt NO_RCS\nPROMPT=''\nRPROMPT=''\n" });
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(path);
        const old = if (std.c.getenv("ZDOTDIR")) |value| try allocator.dupeSentinel(u8, std.mem.span(value), 0) else null;
        errdefer if (old) |value| allocator.free(value);
        if (setenv("ZDOTDIR", path.ptr, 1) != 0) return error.SetEnvironmentFailed;
        return .{ .tmp = tmp, .path = path, .old_zdotdir = old };
    }
    fn deinit(self: *Sandbox) void {
        if (self.old_zdotdir) |value| {
            _ = setenv("ZDOTDIR", value.ptr, 1);
            allocator.free(value);
        } else _ = unsetenv("ZDOTDIR");
        allocator.free(self.path);
        self.tmp.cleanup();
    }
};
fn writeAll(session: *pty.Session, text: []const u8) !void {
    var sent: usize = 0;
    const until = native.zw_local_monotonic_ms() + 3000;
    while (sent < text.len) {
        if (native.zw_local_monotonic_ms() >= until) return error.WriteTimeout;
        switch (try session.write(session.owner, text[sent..])) {
            .bytes => |count| sent += count,
            .would_block => pause(),
        }
    }
}
fn drain(session: *pty.Session, output: *std.ArrayList(u8)) !bool {
    var buffer: [4096]u8 = undefined;
    for (0..16) |_| switch (try session.readOutput(session.owner, &buffer)) {
        .bytes => |count| try output.appendSlice(allocator, buffer[0..count]),
        .would_block => return false,
        .eof => return true,
    };
    return false;
}
fn waitText(session: *pty.Session, output: *std.ArrayList(u8), text: []const u8) !void {
    const until = native.zw_local_monotonic_ms() + 4000;
    while (native.zw_local_monotonic_ms() < until) {
        _ = try drain(session, output);
        _ = try session.pollExit();
        if (std.mem.indexOf(u8, output.items, text) != null) return;
        pause();
    }
    std.debug.print("local PTY output: {s}\n", .{output.items});
    return error.OutputTimeout;
}
fn finishSession(session: *pty.Session) !void {
    if (session.process == null) return;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const until = native.zw_local_monotonic_ms() + 6500;
    while (session.cleanup != .released and native.zw_local_monotonic_ms() < until) {
        _ = try drain(session, &output);
        _ = try session.closeStep(session.owner);
        pause();
    }
    try std.testing.expectEqual(native.Cleanup.released, session.cleanup);
    try session.deinit();
}
fn completeCommand(command: *exec.Command) !exec.Result {
    const until = native.zw_local_monotonic_ms() + 6500;
    while (native.zw_local_monotonic_ms() < until) {
        const result = try command.poll();
        if (result.cleanup == .released) return result;
        pause();
    }
    return error.CommandTimeout;
}
fn finishCommand(command: *exec.Command) !void {
    if (command.process == null) return;
    if (command.cleanup != .released) {
        try command.cancel(command.owner);
        _ = try completeCommand(command);
    }
    try command.deinit();
}

test "real login PTYs have independent owners, cwd, winsize, EAGAIN and reaped tail output" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var failure: pty.Failure = .{};
    var first = try pty.Session.start(allocator, owner(1), key(1), .{ .initial_cwd = sandbox.path }, &failure);
    defer finishSession(&first) catch @panic("first PTY cleanup incomplete");
    var second = try pty.Session.start(allocator, owner(2), key(2), .{}, &failure);
    defer finishSession(&second) catch @panic("second PTY cleanup incomplete");
    try std.testing.expect(try first.pid() != try second.pid());
    try std.testing.expectEqualStrings(sandbox.path, try first.initialCwd());
    const home = try second.initialCwd();
    try std.testing.expect(home.len > 0 and home[0] == '/');
    try std.testing.expect(!std.mem.eql(u8, sandbox.path, home));
    try std.testing.expectError(error.CleanupIncomplete, first.deinit());
    try std.testing.expectError(error.StaleSession, first.write(try owner(1).nextGeneration(), "wrong"));
    try first.resize(owner(1), 2, 101, 37);
    try std.testing.expectEqual(@as(u16, 101), (try first.dimensions()).cols);
    try std.testing.expectEqual(@as(u16, 37), (try first.dimensions()).rows);
    try std.testing.expectError(error.StaleGeometry, first.resize(owner(1), 1, 80, 24));

    var first_output: std.ArrayList(u8) = .empty;
    defer first_output.deinit(allocator);
    var second_output: std.ArrayList(u8) = .empty;
    defer second_output.deinit(allocator);
    try writeAll(&first, "stty -echo; printf '\\101\\114\\120\\110\\101\\012'; stty size\r");
    try writeAll(&second, "stty -echo; printf '\\102\\105\\124\\101\\012'\r");
    try waitText(&first, &first_output, "ALPHA");
    try waitText(&first, &first_output, "37 101");
    try waitText(&second, &second_output, "BETA");
    try std.testing.expect(std.mem.indexOf(u8, first_output.items, "BETA") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_output.items, "ALPHA") == null);
    const cwd = (try first.currentCwd(allocator)).?;
    defer allocator.free(cwd);
    try std.testing.expectEqualStrings(sandbox.path, cwd);
    const foreground_value = first.foreground();
    if (foreground_value == null) std.debug.print("foreground unavailable errno={d}, output={s}\n", .{ native.zw_local_last_error(), first_output.items });
    try std.testing.expect(foreground_value != null);
    const foreground = foreground_value.?;
    try std.testing.expectEqual(try first.pid(), foreground.session_id);
    try std.testing.expect(foreground.process_group > 0);
    var scratch: [256]u8 = undefined;
    var would_block = false;
    const quiet_until = native.zw_local_monotonic_ms() + 1000;
    while (native.zw_local_monotonic_ms() < quiet_until) {
        switch (try first.readOutput(owner(1), &scratch)) {
            .bytes => |count| try first_output.appendSlice(allocator, scratch[0..count]),
            .would_block => {
                would_block = true;
                break;
            },
            .eof => return error.PrematureEof,
        }
        pause();
    }
    try std.testing.expect(would_block);

    const child_pid = try first.pid();
    try writeAll(&first, "printf '\\124\\101\\111\\114\\012'; exit 7\r");
    const until = native.zw_local_monotonic_ms() + 4000;
    var eof = false;
    var exited: ?pty.Exit = null;
    // Continue consuming while polling exit: a producer may be backpressured.
    // Neither EOF nor exit alone is allowed to discard the final output.
    while (native.zw_local_monotonic_ms() < until) {
        eof = try drain(&first, &first_output);
        exited = try first.pollExit();
        if (eof and exited != null) break;
        pause();
    }
    try std.testing.expect(eof);
    try std.testing.expectEqual(@as(u8, 7), exited.?.exited);
    try std.testing.expect(std.mem.indexOf(u8, first_output.items, "TAIL") != null);
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c_int, -1), std.c.waitpid(child_pid, &status, std.c.W.NOHANG));
}

test "PTY close signals only owned foreground/background groups and preserves another session" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var failure: pty.Failure = .{};
    var first = try pty.Session.start(allocator, owner(3), key(3), .{ .initial_cwd = sandbox.path }, &failure);
    defer finishSession(&first) catch @panic("cancelled PTY cleanup incomplete");
    var second = try pty.Session.start(allocator, owner(4), key(4), .{ .initial_cwd = sandbox.path }, &failure);
    defer finishSession(&second) catch @panic("unrelated PTY cleanup incomplete");
    try writeAll(&first, "stty -echo; sleep 60 & sleep 60\r");
    const until = native.zw_local_monotonic_ms() + 4000;
    var actual_foreground: ?native.Foreground = null;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    while (native.zw_local_monotonic_ms() < until) {
        _ = try drain(&first, &output);
        if (first.foreground()) |value| if (value.process_group != try first.pid()) {
            actual_foreground = value;
            break;
        };
        pause();
    }
    if (actual_foreground == null) std.debug.print("job output: {s}, foreground={any}\n", .{ output.items, first.foreground() });
    try std.testing.expect(actual_foreground != null);
    try std.testing.expectError(error.StaleSession, first.closeStep(owner(4)));
    _ = try first.closeStep(owner(3));
    try std.testing.expectError(error.SessionClosing, first.write(owner(3), "no further input"));
    try finishSession(&first);
    var second_output: std.ArrayList(u8) = .empty;
    defer second_output.deinit(allocator);
    try writeAll(&second, "stty -echo; printf '\\123\\125\\122\\126\\111\\126\\105\\012'\r");
    try waitText(&second, &second_output, "SURVIVE");
    try std.testing.expect((try second.pollExit()) == null);
}

test "independent local exec captures stdout/stderr/cwd and waits for true cleanup" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    try sandbox.tmp.dir.createDir(std.testing.io, "cwd space 'quote", .default_dir);
    const cwd = try sandbox.tmp.dir.realPathFileAlloc(std.testing.io, "cwd space 'quote", allocator);
    defer allocator.free(cwd);
    var failure: pty.Failure = .{};
    var command = try exec.Command.start(allocator, owner(5), key(5), 9, "printf 'OUT:'; pwd; printf ERR >&2; printf TAIL; exit 9", cwd, .{}, &failure);
    defer finishCommand(&command) catch @panic("exec cleanup incomplete");
    try std.testing.expectError(error.StaleSession, command.cancel(owner(6)));
    const result = try completeCommand(&command);
    try std.testing.expectEqual(@as(u64, 9), result.call_id);
    try std.testing.expect(result.owner.eql(owner(5)));
    try std.testing.expectEqual(@as(u8, 9), result.exit.?.exited);
    try std.testing.expectEqualStrings("ERR", result.stderr);
    const expected = try std.fmt.allocPrint(allocator, "OUT:{s}\nTAIL", .{cwd});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expect(!result.cancelled and !result.truncated);
}

test "exec output cap and timeout cancel the original process group with receipts" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var failure: pty.Failure = .{};
    var capped = try exec.Command.start(allocator, owner(7), key(7), 1, "yes abcdefghijklmnop", sandbox.path, .{ .capture_bytes = 127, .timeout_ms = 2000 }, &failure);
    defer finishCommand(&capped) catch @panic("capped exec cleanup incomplete");
    const limited = try completeCommand(&capped);
    try std.testing.expect(limited.truncated and limited.cancelled);
    try std.testing.expectEqual(@as(usize, 127), limited.stdout.len + limited.stderr.len);
    try std.testing.expectEqual(native.Cleanup.released, limited.cleanup);
    var timed = try exec.Command.start(allocator, owner(8), key(8), 2, "sleep 60", sandbox.path, .{ .timeout_ms = 30 }, &failure);
    defer finishCommand(&timed) catch @panic("timed exec cleanup incomplete");
    const result = try completeCommand(&timed);
    try std.testing.expect(result.timed_out and result.cancelled);
    try std.testing.expectEqual(native.Cleanup.released, result.cleanup);
}

test "invalid cwd never falls back and start failures report released resources" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    const missing = try std.fmt.allocPrint(allocator, "{s}/does-not-exist", .{sandbox.path});
    defer allocator.free(missing);
    var failure: pty.Failure = .{};
    const before = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try std.testing.expect(before >= 0);
    _ = std.c.close(before);
    for (0..3) |_| {
        try std.testing.expectError(error.StartFailed, pty.Session.start(allocator, owner(9), key(9), .{ .initial_cwd = missing }, &failure));
        try std.testing.expectEqual(native.Stage.cwd, failure.stage);
        try std.testing.expect(failure.error_number != 0);
        try std.testing.expectEqual(operation.Cleanup.released, failure.hostFailure().cleanup);
    }
    const after = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try std.testing.expect(after >= 0);
    defer _ = std.c.close(after);
    try std.testing.expectEqual(before, after);
    try std.testing.expectError(error.WrongOwner, pty.Session.start(allocator, owner(9), key(10), .{}, &failure));
}

test "exec timeout still owns remaining output children after the direct shell exits" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var failure: pty.Failure = .{};
    var command = try exec.Command.start(allocator, owner(11), key(11), 3, "sleep 60 & printf TAIL; exit 0", sandbox.path, .{ .timeout_ms = 50 }, &failure);
    defer finishCommand(&command) catch @panic("remaining exec child cleanup incomplete");
    const result = try completeCommand(&command);
    try std.testing.expectEqualStrings("TAIL", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit.?.exited);
    try std.testing.expect(result.timed_out and result.cancelled);
    try std.testing.expectEqual(native.Cleanup.released, result.cleanup);
}

test "verified local groups escalate HUP then TERM then KILL before cleanup release" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var failure: pty.Failure = .{};
    var command = try exec.Command.start(allocator, owner(12), key(12), 4, "trap '' HUP TERM; printf READY; while :; do sleep 60; done", sandbox.path, .{ .timeout_ms = 0 }, &failure);
    defer finishCommand(&command) catch @panic("signal escalation cleanup incomplete");
    const until = native.zw_local_monotonic_ms() + 3000;
    while (native.zw_local_monotonic_ms() < until and command.stdout.items.len == 0) {
        _ = try command.poll();
        pause();
    }
    try std.testing.expectEqualStrings("READY", command.stdout.items);
    const cancelled_at = native.zw_local_monotonic_ms();
    try command.cancel(owner(12));
    const result = try completeCommand(&command);
    try std.testing.expect(native.zw_local_monotonic_ms() - cancelled_at >= 4000);
    try std.testing.expectEqual(@as(u8, 9), result.exit.?.signal);
    try std.testing.expectEqual(native.Cleanup.released, result.cleanup);
}
