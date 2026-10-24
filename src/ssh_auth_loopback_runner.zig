//! Test-only authenticated loopback transport. Never opens a PTY or shell.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const challenge = @import("proto/ssh/auth_challenge.zig");
const c = @import("generated_ssh_session");
const realtime = @import("platform/realtime.zig");
extern fn libssh2_userauth_last_result(*c.LIBSSH2_SESSION, *c_int, [*]u8, usize, *usize) c_int;

const Driver = struct {
    bridge: *challenge.InteractiveBridge,
    cancel: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
    port: u16,
    mode: []const u8,
    count: usize = 0,
    failure: ?anyerror = null,

    fn run(self: *Driver) void {
        self.answer() catch |err| {
            self.failure = err;
            self.bridge.cancel();
        };
    }
    fn answer(self: *Driver) !void {
        var previous: u64 = 0;
        const deadline = realtime.monotonicNs() + 10 * std.time.ns_per_s;
        while (!self.done.load(.acquire)) {
            if (realtime.monotonicNs() > deadline) return error.DriverTimeout;
            if (self.bridge.snapshot()) |snapshot| {
                if (snapshot.identity.request_id > previous and (snapshot.state == .input or snapshot.state == .failed)) {
                    if (!std.mem.eql(u8, snapshot.endpoint().host, "127.0.0.1") or snapshot.port != self.port or snapshot.identity.hop_index != 1 or snapshot.identity.key.operation_id != 21 or snapshot.identity.key.attempt_id != 3 or snapshot.source_owner.?.revision != 5 or snapshot.presentation_config_revision != 17) return error.ChallengeMetadataMismatch;
                    if (std.mem.eql(u8, self.mode, "cancel")) {
                        self.cancel.store(true, .release);
                        self.bridge.cancel();
                        self.count += 1;
                        return;
                    }
                    switch (snapshot.kind) {
                        .password => try self.bridge.submit(snapshot.identity, .{ .answers = &.{"fixture-password"} }),
                        .private_key_passphrase => try self.bridge.submit(snapshot.identity, .{ .answers = &.{"fixture-key-passphrase"} }),
                        .keyboard_interactive => {
                            if (snapshot.prompt_count != 2 or !snapshot.promptAt(0).echo or snapshot.promptAt(1).echo or !std.mem.eql(u8, snapshot.promptAt(0).text, "Account:") or !std.mem.eql(u8, snapshot.promptAt(1).text, "Recovery phrase:")) return error.PromptGroupMismatch;
                            try self.bridge.submit(snapshot.identity, .{ .answers = &.{ "operator", "arbitrary-length-response" } });
                        },
                        else => return error.UnexpectedChallenge,
                    }
                    previous = snapshot.identity.request_id;
                    self.count += 1;
                }
            }
            var fd: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&fd, 0, 1);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const mode = args.next() orelse return error.MissingMode;
    const key_path_raw = args.next();
    var library = try ssh.Library.init();
    defer library.deinit();
    if (std.mem.eql(u8, mode, "cache")) {
        try verifyCache(port);
        std.debug.print("PASS cache partial/short-destination/local-error/success-reset\n", .{});
        return;
    }
    const key_path = if (key_path_raw) |raw| try std.heap.page_allocator.dupeSentinel(u8, raw, 0) else null;
    defer if (key_path) |path| std.heap.page_allocator.free(path);
    var bridge: challenge.InteractiveBridge = .{};
    defer bridge.cancel();
    var cancel: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    var driver: Driver = .{ .bridge = &bridge, .cancel = &cancel, .done = &done, .port = port, .mode = mode };
    const thread = try std.Thread.spawn(.{}, Driver.run, .{&driver});
    var joined = false;
    defer if (!joined) {
        done.store(true, .release);
        bridge.cancel();
        thread.join();
    };
    const start = realtime.monotonicNs();
    const options: ssh.Options = .{
        .host = "127.0.0.1",
        .port = port,
        .user = "operator",
        .auth = if (std.mem.eql(u8, mode, "key")) .{ .private_key = .{ .path = key_path orelse return error.MissingKeyPath } } else if (std.mem.eql(u8, mode, "agent")) .agent else if (std.mem.eql(u8, mode, "cancel")) .keyboard_interactive else if (std.mem.eql(u8, mode, "malformed")) .{ .password = "rejected-fixture-password" } else .password_prompt,
        .open_shell = false,
        .host_key_decision = .trust_once,
        .connect_timeout_ms = 3000,
        .source_owner = .{ .id = @fromBackingInt(41), .revision = 5 },
        .operation_key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(11), .generation = 2 } }, .operation_id = 21, .attempt_id = 3 },
        .attempt_id = 3,
        .hop_index = 1,
        .hop_count = 2,
        .auth_interaction = .{ .bridge = &bridge, .presentation = .protected_form, .presentation_config_revision = 17 },
        .cancel_token = &cancel,
    };
    var failure: ?anyerror = null;
    var session: ?ssh.Session = ssh.Session.connect(&library, options) catch |err| blk: {
        failure = err;
        break :blk null;
    };
    defer if (session) |*value| value.close();
    done.store(true, .release);
    thread.join();
    joined = true;
    if (driver.failure) |err| return err;
    if (std.mem.eql(u8, mode, "cancel")) {
        if (failure == null or failure.? != error.Cancelled or session != null or driver.count != 1) return error.CancellationFailed;
        const elapsed_ms = @divTrunc(realtime.monotonicNs() - start, std.time.ns_per_ms);
        if (elapsed_ms > 1000) return error.CancellationWasSlow;
        std.debug.print("PASS cancel elapsed_ms={d} no-late-auth\n", .{elapsed_ms});
        return;
    }
    if (std.mem.eql(u8, mode, "malformed")) {
        if (failure == null or failure.? != error.InvalidAuthenticationResult or session != null) return error.MalformedResultAccepted;
        std.debug.print("PASS malformed failure has no accepted partial\n", .{});
        return;
    }
    if (failure) |err| return err;
    const accepted = session.?.accepted_auth_methods;
    if (!accepted.contains(.keyboard_interactive)) return error.AcceptedMethodsMismatch;
    if (std.mem.eql(u8, mode, "no-partial")) {
        if (accepted.count() != 1 or driver.count != 2) return error.FalsePartialInferred;
    } else if (std.mem.eql(u8, mode, "key")) {
        if (!accepted.contains(.private_key) or accepted.count() != 2 or driver.count != 2) return error.KeyPartialMissing;
    } else if (std.mem.eql(u8, mode, "agent")) {
        if (!accepted.contains(.agent) or accepted.count() != 2 or driver.count != 1) return error.AgentPartialMissing;
    } else if (!accepted.contains(.password) or accepted.count() != 2 or driver.count != 2) return error.PasswordPartialMissing;
    std.debug.print("PASS {s} accepted_count={d} scoped_challenges={d}\n", .{ mode, accepted.count(), driver.count });
}

fn verifyCache(port: u16) !void {
    const fd = c.zw_ssh_socket_connect("127.0.0.1", port, 3000);
    if (fd < 0) return error.ConnectFailed;
    defer c.zw_ssh_socket_close(fd);
    const session = c.zw_libssh2_session_create() orelse return error.SessionCreateFailed;
    defer c.zw_libssh2_session_disconnect_free(session);
    c.zw_libssh2_session_set_timeout(session, 3000);
    if (c.zw_ssh_socket_set_blocking(fd) != 0 or c.zw_libssh2_session_handshake(session, fd) != 0) return error.HandshakeFailed;
    var methods: [1024]u8 = undefined;
    var length: usize = 0;
    var partial: c_int = 0;
    if (c.zw_libssh2_auth_methods(session, "operator", &methods, methods.len, &length) != 0) return error.MethodListFailed;
    if (c.zw_libssh2_auth_password(session, "operator", "stage-one") == 0) return error.PartialBecameSuccess;
    if (libssh2_userauth_last_result(session, &partial, &methods, methods.len, &length) != 1 or partial != 1) return error.PartialNotRecorded;
    var small: [1]u8 = undefined;
    if (libssh2_userauth_last_result(session, &partial, &small, small.len, &length) != -1 or partial != 0 or length != 0) return error.UnboundedResult;
    if (c.zw_libssh2_auth_private_key(session, "operator", "/nonexistent/zerowork-test-key", null) == 0) return error.MissingKeyAccepted;
    if (libssh2_userauth_last_result(session, &partial, &methods, methods.len, &length) != 0 or partial != 0 or length != 0) return error.StalePartialAfterLocalError;
    if (c.zw_libssh2_auth_password(session, "operator", "stage-two") != 0) return error.FinalAuthenticationFailed;
    if (libssh2_userauth_last_result(session, &partial, &methods, methods.len, &length) != 0 or partial != 0 or length != 0) return error.StalePartialAfterSuccess;
}
