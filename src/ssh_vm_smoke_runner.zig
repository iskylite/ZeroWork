//! Narrow deployment check using the production Session and isolated trust.
//! The only remote input is printf + test -t + exit; no remote file writes.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const known = @import("proto/ssh/host_key_store.zig");
const auth = @import("proto/ssh/auth_challenge.zig");
const operation = @import("host/operation.zig");
const c = @import("generated_ssh_session");
const realtime = @import("platform/realtime.zig");

const Driver = struct {
    bridge: *auth.InteractiveBridge,
    token: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
    key: operation.OperationKey,
    password: []const u8,
    host: []const u8,
    port: u16,
    host_keys: usize = 0,
    passwords: usize = 0,
    failure: ?anyerror = null,
    fn run(self: *Driver) void {
        self.answer() catch |err| {
            self.failure = err;
            self.token.store(true, .release);
            self.bridge.cancel();
        };
    }
    fn answer(self: *Driver) !void {
        var previous: u64 = 0;
        const deadline = realtime.monotonicNs() + 15 * std.time.ns_per_s;
        while (!self.done.load(.acquire)) {
            if (realtime.monotonicNs() >= deadline) return error.DriverTimeout;
            if (self.bridge.snapshot()) |snapshot| {
                if (snapshot.state == .input and snapshot.identity.request_id > previous) {
                    if (!snapshot.identity.key.eql(self.key) or snapshot.identity.hop_index != 0 or !std.mem.eql(u8, snapshot.endpoint().host, self.host) or snapshot.port != self.port) return error.ChallengeOwnerMismatch;
                    switch (snapshot.kind) {
                        .host_key_unknown => {
                            try self.bridge.submit(snapshot.identity, .trust_once);
                            self.host_keys += 1;
                        },
                        .password => {
                            if (snapshot.prompt_count != 1 or snapshot.promptAt(0).echo) return error.PasswordChallengeMismatch;
                            try self.bridge.submit(snapshot.identity, .{ .answers = &.{self.password} });
                            self.passwords += 1;
                        },
                        else => return error.UnexpectedChallenge,
                    }
                    previous = snapshot.identity.request_id;
                }
            }
            var unused: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&unused, 0, 2);
        }
    }
};

const Trust = struct {
    bridge: *auth.InteractiveBridge,
    token: *std.atomic.Value(bool),
    key: operation.OperationKey,
    path: []const u8,
    failure: ?anyerror = null,
    fn observe(raw: *anyopaque, host: []const u8, port: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Trust = @ptrCast(@alignCast(raw));
        return self.request(host, port, info) catch |err| {
            self.failure = err;
            return .reject_unknown;
        };
    }
    fn request(self: *Trust, host: []const u8, port: u16, info: ssh.HostKeyInfo) !ssh.HostKeyDecision {
        if (info.status != .unknown or info.raw_key.len == 0 or info.verification == null or info.store_path == null or !std.mem.eql(u8, info.store_path.?, self.path)) return error.HostKeyMetadataMismatch;
        const public_key = try known.PublicKey.fromRaw(info.raw_key);
        const fingerprint = known.fingerprint(public_key);
        if (!std.mem.eql(u8, fingerprint.slice(), info.fingerprint)) return error.HostKeyFingerprintMismatch;
        const request_id = try self.bridge.offerChallenge(.{
            .key = self.key,
            .hop_index = 0,
            .kind = .host_key_unknown,
            .endpoint_identity = .{ .host = host, .port = port, .user = "root" },
            .prompts = &.{},
            .presentation_config_revision = 1,
        });
        var response = try self.bridge.waitResponseCancellable(request_id, 10_000, self.token);
        defer response.deinit();
        if (response.decision != .trust_once) return error.UnexpectedTrustDecision;
        try self.bridge.complete(request_id);
        return .trust_once;
    }
};

fn pause(fd: c_int) void {
    var descriptor = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    _ = std.c.poll(&descriptor, 1, 20);
}

fn verifyPty(session: *ssh.Session, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    // The echoed source contains %s, so it cannot itself satisfy either marker.
    const command = "printf '\\nzerowork-zig-%s\\n' ok; if test -t 0; then printf 'zerowork-pty-%s\\n' yes; else printf 'zerowork-pty-%s\\n' no; fi; exit\n";
    var writer = try session.writer();
    var reader = try session.reader();
    const deadline = realtime.monotonicNs() + 5 * std.time.ns_per_s;
    var written: usize = 0;
    while (written < command.len) {
        if (realtime.monotonicNs() >= deadline) return error.PtyWriteTimeout;
        const count = try writer.write(command[written..]);
        written += count;
        if (count == 0) pause(session.socket_fd);
    }
    var output: [64 * 1024]u8 = undefined;
    var used: usize = 0;
    var eof = false;
    while (used < output.len) {
        if (realtime.monotonicNs() >= deadline) return error.PtyReadTimeout;
        switch (try reader.read(output[used..])) {
            .bytes => |count| used += count,
            .would_block => pause(session.socket_fd),
            .eof => {
                eof = true;
                break;
            },
        }
    }
    if (!eof or std.mem.indexOf(u8, output[0..used], "\nzerowork-zig-ok\r\n") == null or std.mem.indexOf(u8, output[0..used], "\nzerowork-pty-yes\r\n") == null or c.zw_libssh2_channel_exit_status(@ptrCast(session.channel.?.handle)) != 0) return error.PtyCommandVerificationFailed;
    const output_path = try std.fmt.allocPrint(allocator, "{s}.pty-output.txt", .{path});
    defer allocator.free(output_path);
    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, output[0..used]);
    std.debug.print("PTY printf=zerowork-zig-ok stdin_is_tty=true eof=true exit_status=0 output_bytes={d}\n", .{used});
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingIsolatedTrustPath;
    if (!std.mem.startsWith(u8, path, "/tmp/zerowork-vm-") or !std.mem.endsWith(u8, path, "/known_hosts")) return error.IsolationRequired;
    const host = args.next() orelse return error.MissingHost;
    const allowed_host = init.environ_map.get("ZEROWORK_VM_HOST") orelse "127.0.0.1";
    const port = if (args.next()) |raw| try std.fmt.parseInt(u16, raw, 10) else @as(u16, 22);
    if (port == 0 or (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, allowed_host))) return error.EndpointNotAuthorized;
    const password = init.environ_map.get("ZEROWORK_VM_PASSWORD") orelse return error.MissingCredential;
    var journal = operation.Journal.init(init.gpa);
    defer journal.deinit();
    var library = try ssh.Library.init();
    defer library.deinit();
    var store = try known.HostKeyStore.load(init.io, std.Io.Dir.cwd(), init.gpa, path);
    defer store.deinit();
    if (store.records.items.len != 0 or store.currentRevision().file_hash != null) return error.FixtureMustBeEmpty;
    for ([_]bool{ false, true }, 1..) |open_shell, attempt| {
        const key = try journal.begin(.app, attempt);
        var bridge: auth.InteractiveBridge = .{};
        defer bridge.cancel();
        var token: std.atomic.Value(bool) = .init(false);
        var done: std.atomic.Value(bool) = .init(false);
        var driver: Driver = .{ .bridge = &bridge, .token = &token, .done = &done, .key = key, .password = password, .host = host, .port = port };
        var trust: Trust = .{ .bridge = &bridge, .token = &token, .key = key, .path = path };
        const thread = try std.Thread.spawn(.{}, Driver.run, .{&driver});
        var joined = false;
        defer if (!joined) {
            done.store(true, .release);
            bridge.cancel();
            thread.join();
        };
        var session = ssh.Session.connect(&library, .{
            .host = host,
            .port = port,
            .user = "root",
            .auth = .password_prompt,
            .open_shell = open_shell,
            .host_key_store = &store,
            .host_key_observer = .{ .ctx = &trust, .callback = Trust.observe },
            .operation_key = key,
            .auth_interaction = .{ .bridge = &bridge },
            .cancel_token = &token,
            .connect_timeout_ms = 5000,
        }) catch |err| {
            const socket_errno = c.zw_ssh_socket_last_error();
            done.store(true, .release);
            bridge.cancel();
            thread.join();
            joined = true;
            if (trust.failure) |reason| std.debug.print("trust_bridge_failure={s}\n", .{@errorName(reason)});
            if (driver.failure) |reason| std.debug.print("driver_failure={s}\n", .{@errorName(reason)});
            std.debug.print("CONNECT_FAILED host={s}:{d} reason={s} socket_errno={d}\n", .{ host, port, @errorName(err), socket_errno });
            return err;
        };
        defer session.close();
        const host_key = session.hostKey() orelse return error.HostKeyMissing;
        if (host_key.acceptance != .unknown_once or !session.accepted_auth_methods.contains(.password)) return error.TrustOrAuthenticationMismatch;
        if (open_shell) try verifyPty(&session, init.io, init.gpa, path) else {
            if (session.channel != null) return error.DetectionOpenedShell;
            if (session.reader()) |_| return error.DetectionOpenedTerminal else |err| if (err != error.ShellUnavailable) return err;
        }
        const fd = session.socket_fd;
        std.debug.print("HOSTKEY algorithm={s} fingerprint={s} trust=unknown_once raw_bytes={d}\n", .{ host_key.algorithm, host_key.fingerprint, host_key.raw_key.len });
        session.close();
        if (std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)) != -1 or std.c._errno().* != @as(c_int, @backingInt(std.c.E.BADF))) return error.FdNotClosed;
        done.store(true, .release);
        thread.join();
        joined = true;
        if (driver.failure) |err| return err;
        if (driver.host_keys != 1 or driver.passwords != 1) return error.ChallengeCountMismatch;
        if (trust.failure) |err| return err;
        _ = try journal.completeReleased(key, "VM smoke transport closed");
        std.debug.print("PASS mode={s} authenticated=true channel={s} fd_closed=true\n", .{ if (open_shell) "pty" else "no-shell", if (open_shell) "pty" else "none" });
    }
    if (store.records.items.len != 0) return error.OnceTrustPersisted;
    if (std.Io.Dir.cwd().openFile(init.io, path, .{})) |file| {
        file.close(init.io);
        return error.OnceTrustCreatedFile;
    } else |err| if (err != error.FileNotFound) return err;
    std.debug.print("PASS isolated_known_hosts_absent=true records=0\n", .{});
}
