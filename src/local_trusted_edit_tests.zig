//! Isolated real /bin/zsh integration; no user startup files or window.
const std = @import("std");
const trusted = @import("local/trusted_edit.zig");
const pty = @import("local/pty.zig");
const native = @import("local/native.zig");
const a = std.testing.allocator;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;
fn pause() void {
    const delay: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
}
const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    old: ?[:0]u8,
    bridge: trusted.Bridge,
    session: pty.Session,
    output: std.ArrayList(u8) = .empty,
    fn init() !Fixture {
        return initWithStartup("");
    }
    fn initWithStartup(startup: []const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "PROMPT=''\nRPROMPT=''\n" });
        const zshrc = try std.mem.concat(a, u8, &.{ startup, "\nbindkey -e\nexport LC_ALL=en_US.UTF-8\n_zw_test_pending() { print -r -- $PENDING > \"$ZDOTDIR/pending\"; zle -U Q; print -r -- $KEYS_QUEUED_COUNT >> \"$ZDOTDIR/pending\"; _zw_edit_request replace 991 $_zw_token $_zw_revision \"$BUFFER\" $CURSOR invalid-replacement; }\nzle -N _zw_test_pending\nbindkey '^Xp' _zw_test_pending\n" });
        defer a.free(zshrc);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshrc", .data = zshrc });
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        errdefer a.free(path);
        const old = if (std.c.getenv("ZDOTDIR")) |v| try a.dupeSentinel(u8, std.mem.span(v), 0) else null;
        _ = setenv("ZDOTDIR", path.ptr, 1);
        errdefer {
            if (old) |v| {
                _ = setenv("ZDOTDIR", v.ptr, 1);
                a.free(v);
            } else _ = unsetenv("ZDOTDIR");
        }
        const owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(591) };
        var bridge = try trusted.Bridge.init(a, owner);
        errdefer bridge.deinit();
        var failure: native.Failure = .{};
        const session = try pty.Session.start(a, owner, .{ .owner = .{ .session = owner }, .operation_id = 1, .attempt_id = 1 }, .{ .bootstrap = bridge.bootstrap() }, &failure);
        return .{ .tmp = tmp, .path = path, .old = old, .bridge = bridge, .session = session };
    }
    fn deinit(self: *Fixture) void {
        const until = native.zw_local_monotonic_ms() + 6500;
        while (self.session.cleanup != .released and native.zw_local_monotonic_ms() < until) {
            self.tick() catch {};
            _ = self.session.closeStep(self.session.owner) catch {};
            pause();
        }
        self.session.deinit() catch {};
        self.bridge.deinit();
        self.output.deinit(a);
        if (self.old) |v| {
            _ = setenv("ZDOTDIR", v.ptr, 1);
            a.free(v);
        } else _ = unsetenv("ZDOTDIR");
        a.free(self.path);
        self.tmp.cleanup();
    }
    fn tick(self: *Fixture) !void {
        self.bridge.poll(try self.session.pid(), @intCast(native.zw_local_monotonic_ms()));
        self.bridge.synchronizeInput();
        var bytes: [8192]u8 = undefined;
        for (0..16) |_| switch (try self.session.readOutput(self.session.owner, &bytes)) {
            .bytes => |n| try self.output.appendSlice(a, bytes[0..n]),
            else => break,
        };
    }
    fn write(self: *Fixture, text: []const u8) !void {
        var offset: usize = 0;
        const until = native.zw_local_monotonic_ms() + 2000;
        while (offset < text.len and native.zw_local_monotonic_ms() < until) switch (try self.session.write(self.session.owner, text[offset..])) {
            .bytes => |n| offset += n,
            .would_block => pause(),
        };
        try std.testing.expectEqual(text.len, offset);
    }
    fn waitBuffer(self: *Fixture, text: []const u8) !void {
        const until = native.zw_local_monotonic_ms() + 3000;
        while (native.zw_local_monotonic_ms() < until) {
            try self.tick();
            if (self.bridge.snapshot) |s| if (!self.bridge.input_dirty and std.mem.eql(u8, s.buffer, text) and s.editable()) return;
            pause();
        }
        std.debug.print("ZSH output: {s}\nhello={} disabled={}\n", .{ self.output.items, self.bridge.hello, self.bridge.disabled });
        return error.SnapshotTimeout;
    }
    fn request(self: *Fixture, operation: u64, kind: trusted.edit.Kind, replacement: []const u8) !trusted.edit.Outcome {
        const s = self.bridge.snapshot.?;
        try self.bridge.request(.{ .operation = operation, .token = s.token, .revision = s.revision, .kind = kind, .replacement = replacement, .lease = s.lease }, @intCast(native.zw_local_monotonic_ms()));
        const until = native.zw_local_monotonic_ms() + 2000;
        while (native.zw_local_monotonic_ms() < until) {
            try self.tick();
            if (self.bridge.outcome) |outcome| {
                self.bridge.outcome = null;
                return outcome;
            }
            pause();
        }
        return error.AckTimeout;
    }
};

test "slow real shell startup remains untrusted then authenticates, executes and releases" {
    var f = try Fixture.initWithStartup("/bin/sleep 3\n");
    var active = true;
    defer if (active) f.deinit();
    const directory = try a.dupe(u8, std.mem.span(f.bridge.bootstrap()));
    defer a.free(directory);
    const until = native.zw_local_monotonic_ms() + 2500;
    while (native.zw_local_monotonic_ms() < until) {
        try f.tick();
        try std.testing.expect(!f.bridge.hello and !f.bridge.disabled and f.bridge.snapshot == null);
        try std.testing.expectError(error.TrustedEditUnavailable, f.bridge.request(.{ .operation = 1, .kind = .begin, .token = 1, .revision = 0 }, @intCast(native.zw_local_monotonic_ms())));
        pause();
    }
    try f.waitBuffer("");
    try std.testing.expect((try f.request(1, .begin, "")).applied);
    try std.testing.expect((try f.request(2, .end, "")).applied);
    // A real command enters ZLE through the same trusted replacement primitive
    // as command completion; it executes only after explicit terminal Enter.
    const command = try std.fmt.allocPrint(a, "printf delayed-ok > '{s}/delayed-marker'", .{f.path});
    defer a.free(command);
    try std.testing.expect((try f.request(3, .replace, command)).applied);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(std.testing.io, "delayed-marker", .{}));
    try f.write("\r");
    try f.waitBuffer("");
    const marker = try f.tmp.dir.openFile(std.testing.io, "delayed-marker", .{});
    marker.close(std.testing.io);
    try f.write("exit\r");
    const exit_until = native.zw_local_monotonic_ms() + 3000;
    var exited = false;
    while (native.zw_local_monotonic_ms() < exit_until) {
        try f.tick();
        if (try f.session.pollExit()) |_| {
            exited = true;
            break;
        }
        pause();
    }
    try std.testing.expect(exited);
    try std.testing.expect(!f.bridge.hello and f.bridge.snapshot == null);
    try std.testing.expectEqual(native.Cleanup.released, try f.session.closeStep(f.session.owner));
    f.deinit();
    active = false;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openDirAbsolute(std.testing.io, directory, .{}));
}

test "unrelated same-user socket peer cannot authenticate during delayed shell startup" {
    var f = try Fixture.initWithStartup("/bin/sleep 3\n");
    defer f.deinit();
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var address: std.c.sockaddr.un = .{ .path = @splat(0) };
    const path = try std.fmt.bufPrint(&address.path, "{s}/control", .{std.mem.span(f.bridge.bootstrap())});
    try std.testing.expect(path.len < address.path.len);
    try std.testing.expectEqual(@as(c_int, 0), std.c.connect(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))));
    try f.tick();
    try std.testing.expect(!f.bridge.hello and !f.bridge.disabled and f.bridge.snapshot == null and f.bridge.connected_at == 0);
    // Rejection must leave the real owning shell able to connect later.
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        try f.tick();
        if (f.bridge.hello and f.bridge.snapshot != null and !f.bridge.input_dirty) return;
        pause();
    }
    return error.AuthenticatedShellTimeout;
}

test "real shell prompt reconnect restores trust after worker delay" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.waitBuffer("");
    const token = f.bridge.snapshot.?.token;
    f.bridge.markInput();
    try f.write("sleep 0.1\r");
    // Let line-finish send revocation and preexec close the old connection
    // before this worker next drains its bytes. The next prompt reconnects.
    for (0..80) |_| pause();
    f.bridge.synchronizeInput();
    try f.waitBuffer("");
    try std.testing.expect(f.bridge.snapshot.?.token > token);
    try std.testing.expect((try f.request(1, .begin, "")).applied);
}

test "cancelling an edit preserves authenticated transport and recovers only after real Ctrl-C prompt" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.waitBuffer("");
    const token = f.bridge.snapshot.?.token;
    for (0..20) |_| pause();
    f.bridge.revoke(.integration_lost);
    try std.testing.expect(f.bridge.hello and f.bridge.snapshot == null and f.bridge.input_dirty);
    try std.testing.expectError(error.TrustedEditUnavailable, f.bridge.request(.{ .operation = 1, .kind = .begin, .token = token, .revision = 0 }, @intCast(native.zw_local_monotonic_ms())));
    try f.write("\x03");
    try f.waitBuffer("");
    try std.testing.expect(f.bridge.snapshot.?.token > token);
    const until = native.zw_local_monotonic_ms() + 2200;
    while (native.zw_local_monotonic_ms() < until) {
        try f.tick();
        try std.testing.expect(!f.bridge.disabled);
        pause();
    }
    try std.testing.expect((try f.request(1, .begin, "")).applied);
}
test "real ZLE unicode atomic replacement, lease, native history and Enter" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.waitBuffer("");
    try f.write("echo '中文👩‍💻é' # original");
    try f.waitBuffer("echo '中文👩‍💻é' # original");
    const replacement = "printf '\\nZW_ONLY_AFTER_ENTER\\n' # 中文👩‍💻é";
    try std.testing.expect((try f.request(1, .replace, replacement)).applied);
    try f.waitBuffer(replacement);
    // The replaced line has not been accepted: a shell-side marker file is
    // tested below after a separate explicit Enter.
    try f.write("\x15");
    try f.waitBuffer("");
    const begin = try f.request(2, .begin, "");
    try std.testing.expect(begin.applied and begin.lease == 2);
    try std.testing.expect((try f.request(3, .end, "")).applied);
    try std.testing.expectEqual(@as(u64, 0), f.bridge.snapshot.?.lease);
    const command = try std.fmt.allocPrint(a, "cd '{s}' && printf done > marker", .{f.path});
    defer a.free(command);
    try std.testing.expect((try f.request(4, .replace, command)).applied);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(std.testing.io, "marker", .{}));
    try f.write("\r");
    try f.waitBuffer("");
    const marker = try f.tmp.dir.openFile(std.testing.io, "marker", .{});
    marker.close(std.testing.io);
    try f.write("\x1b[A");
    try f.waitBuffer(command);
}

test "Darwin ZLE exposes pending terminal bytes and queued widget input" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.waitBuffer("");
    try f.write("\x18pZ");
    try f.waitBuffer("QZ");
    const file = try f.tmp.dir.openFile(std.testing.io, "pending", .{});
    defer file.close(std.testing.io);
    var bytes: [128]u8 = undefined;
    const n = try file.readPositionalAll(std.testing.io, &bytes, 0);
    var lines = std.mem.tokenizeAny(u8, bytes[0..n], "\r\n");
    const pending = try std.fmt.parseInt(u64, lines.next().?, 10);
    const queued = try std.fmt.parseInt(u64, lines.next().?, 10);
    try std.testing.expect(pending > 0);
    try std.testing.expect(queued > 0);
}

test "unchanged native input regains trust only after private observation barrier" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.waitBuffer("");
    const revision = f.bridge.snapshot.?.revision;
    f.bridge.markInput();
    try f.write("\x1b[C");
    f.bridge.synchronizeInput();
    const until = native.zw_local_monotonic_ms() + 2000;
    while (f.bridge.input_dirty and native.zw_local_monotonic_ms() < until) {
        try f.tick();
        pause();
    }
    try std.testing.expect(!f.bridge.input_dirty);
    try std.testing.expectEqual(revision, f.bridge.snapshot.?.revision);
    try std.testing.expectEqualStrings("", f.bridge.snapshot.?.buffer);
}

const LocalWorker = struct {
    adapter: *@import("local/adapter.zig").LocalAdapter,
    sessions: @import("host/session_host.zig").SessionHost,
    service: ?@import("host/terminal_service.zig").Service = null,
    slot_generation: u64 = 0,
    scratch: []u8,
    fn init() !LocalWorker {
        const adapter = try @import("local/adapter.zig").LocalAdapter.init(a, .{});
        errdefer adapter.deinit() catch unreachable;
        return .{ .adapter = adapter, .sessions = try @import("host/session_host.zig").SessionHost.init(a, &.{adapter.adapter()}), .scratch = try a.alloc(u8, @import("vt/text_slot.zig").TextSlot.default_capacity) };
    }
    fn tick(self: *LocalWorker) !void {
        _ = try self.adapter.drain(&self.sessions);
        if (self.service) |service| {
            const slot = service.textSlot() catch |err| {
                if (err == error.WorkerBusy) return;
                return err;
            };
            if (try slot.take(self.slot_generation, self.scratch)) |frame| self.slot_generation = frame.generation;
            var bytes: [4096]u8 = undefined;
            while (true) switch (try service.readOutput(&bytes)) {
                .bytes => {},
                else => break,
            };
        }
    }
    fn deinit(self: *LocalWorker) void {
        const until = native.zw_local_monotonic_ms() + 8000;
        while (self.adapter.shutdownStep() != .released) {
            self.tick() catch {};
            if (native.zw_local_monotonic_ms() >= until) @panic("trusted worker cleanup timeout");
            pause();
        }
        self.adapter.deinit() catch unreachable;
        self.sessions.deinit();
        a.free(self.scratch);
    }
    fn editable(self: *LocalWorker, after_token: u64) !trusted.edit.Snapshot {
        const until = native.zw_local_monotonic_ms() + 3000;
        while (native.zw_local_monotonic_ms() < until) {
            try self.tick();
            if (self.service.?.trustedSnapshot(a) catch |err| {
                if (err == error.WorkerBusy) {
                    pause();
                    continue;
                }
                return err;
            }) |snapshot| {
                if (snapshot.editable() and snapshot.token > after_token) return snapshot;
                var old = snapshot;
                old.deinit(a);
            }
            pause();
        }
        return error.WorkerTrustedPromptTimeout;
    }
};

test "worker service restores empty prompt trust after Enter without another PTY input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "PROMPT=''\nRPROMPT=''\n" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    const old = if (std.c.getenv("ZDOTDIR")) |v| try a.dupeSentinel(u8, std.mem.span(v), 0) else null;
    _ = setenv("ZDOTDIR", path.ptr, 1);
    defer {
        if (old) |v| {
            _ = setenv("ZDOTDIR", v.ptr, 1);
            a.free(v);
        } else _ = unsetenv("ZDOTDIR");
    }
    var worker = try LocalWorker.init();
    defer worker.deinit();
    const accepted = try worker.sessions.create(.{ .local = .{ .initial_cwd = path } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    const ready_until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < ready_until) {
        try worker.tick();
        if (worker.sessions.queryService(accepted.handle, .terminal) == .available) {
            worker.service = try worker.adapter.terminalService(worker.sessions.queryService(accepted.handle, .terminal).available);
            break;
        }
        pause();
    }
    try std.testing.expect(worker.service != null);
    var first = try worker.editable(0);
    defer first.deinit(a);
    const until = native.zw_local_monotonic_ms() + 2000;
    while (true) {
        if (native.zw_local_monotonic_ms() >= until) return error.WriteTimeout;
        const status = worker.service.?.status() catch |err| {
            if (err == error.WorkerBusy) {
                pause();
                continue;
            }
            return err;
        };
        _ = worker.service.?.write(.{ .input_sequence = 1, .mode_revision = status.mode_revision, .bytes = "sleep 0.1\r" }) catch |err| {
            if (err == error.WorkerBusy) {
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    // No extra key, timer-based trust reset or UI prediction is allowed here.
    var second = try worker.editable(first.token);
    defer second.deinit(a);
    try std.testing.expectEqualStrings("", second.buffer);
    const request_until = native.zw_local_monotonic_ms() + 2000;
    while (true) {
        if (native.zw_local_monotonic_ms() >= request_until) return error.BeginTimeout;
        worker.service.?.trustedRequest(.{ .operation = 1, .token = second.token, .revision = second.revision, .kind = .begin }) catch |err| {
            if (err == error.WorkerBusy) {
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    const ack_until = native.zw_local_monotonic_ms() + 2000;
    while (native.zw_local_monotonic_ms() < ack_until) {
        try worker.tick();
        if (worker.service.?.trustedOutcome() catch |err| {
            if (err == error.WorkerBusy) {
                pause();
                continue;
            }
            return err;
        }) |outcome| {
            try std.testing.expect(outcome.applied and outcome.lease == 1);
            return;
        }
        pause();
    }
    return error.BeginTimeout;
}
