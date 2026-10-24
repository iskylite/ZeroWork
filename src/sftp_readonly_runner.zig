//! Production read-only SFTP service validation. Fixed operations are REALPATH
//! '.', READDIR '/', LSTAT and bounded READ '/etc/os-release'; no remote writes.
const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const readonly = @import("proto/ssh/sftp_readonly.zig");
const identity = @import("host/identity.zig");
const clock = @import("platform/realtime.zig");
const c = @import("generated_ssh_session");

const Native = struct {
    library: *const ssh.Library,
    host: [:0]const u8,
    port: u16,
    password: [:0]const u8,
    expected_fingerprint: []const u8,
    key: readonly.OperationKey,
    allow_connect: std.atomic.Value(bool) = .init(false),
    destroyed: std.atomic.Value(bool) = .init(false),
    fd: c_int = -1,
    fn trust(raw: *anyopaque, _: []const u8, _: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (info.status != .unknown or !std.mem.eql(u8, self.expected_fingerprint, info.fingerprint)) return .reject_unknown;
        std.debug.print("HOSTKEY algorithm={s} fingerprint={s} trust=unknown_once\n", .{ info.algorithm, info.fingerprint });
        return .trust_once;
    }
    fn connect(raw: *anyopaque, cancelled: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *@This() = @ptrCast(@alignCast(raw));
        while (!self.allow_connect.load(.acquire)) {
            if (cancelled.load(.acquire)) return error.Cancelled;
            pause();
        }
        const session = try ssh.Session.connect(self.library, .{
            .host = self.host,
            .port = self.port,
            .user = "root",
            .auth = .{ .password = self.password },
            .open_shell = false,
            .operation_key = self.key,
            .cancel_token = cancelled,
            .host_key_observer = .{ .ctx = self, .callback = trust },
            .connect_timeout_ms = 5000,
        });
        self.fd = session.socket_fd;
        if (session.channel != null) return error.UnexpectedShell;
        return session;
    }
    fn close(_: *anyopaque, session: ?*ssh.Session) ssh.ReleaseReceipt {
        return if (session) |live| live.closeReceipt() else .released;
    }
    fn destroy(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.destroyed.store(true, .release);
    }
};
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn key(owner: identity.SessionHandle, id: u64) readonly.OperationKey {
    return .{ .owner = .{ .session = owner }, .operation_id = id, .attempt_id = 1 };
}
fn awaitClose(service: *readonly.Service) !void {
    const deadline = clock.monotonicNs() + 30 * std.time.ns_per_s;
    while (service.closeReceipt() != .released) {
        if (clock.monotonicNs() >= deadline) return error.CleanupNotReleased;
        while (service.poll()) |value| {
            var result = value;
            result.deinit();
        }
        pause();
    }
}
fn finalResult(service: *readonly.Service, expected: readonly.OperationKey) !readonly.OwnedResult {
    const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        const value = service.poll() orelse {
            pause();
            continue;
        };
        var result = value;
        if (!result.value.key.eql(expected)) {
            result.deinit();
            return error.UnexpectedOperation;
        }
        if (result.value.final) return result;
        result.deinit();
    }
    return error.ResultTimedOut;
}
fn verifyFixture(service: *readonly.Service, owner: identity.SessionHandle, endpoint: readonly.EndpointRef) !void {
    const cases = [_]struct { path: []const u8, failure: readonly.Failure }{
        .{ .path = "/binary", .failure = .unsupported_binary },
        .{ .path = "/invalid", .failure = .unsupported_encoding },
        .{ .path = "/broken", .failure = .unsupported_encoding },
        .{ .path = "/denied", .failure = .permission_denied },
        .{ .path = "/missing", .failure = .not_found },
        .{ .path = "/device", .failure = .not_regular_file },
        .{ .path = "/change", .failure = .source_changed },
    };
    for (cases, 20..) |case, id| {
        const operation_key = key(owner, id);
        try service.submit(operation_key, .{ .endpoint = endpoint, .request_id = id, .path = case.path, .action = .{ .read_text = .{} } });
        var result = try finalResult(service, operation_key);
        defer result.deinit();
        if (result.value.cleanup != .released or result.value.body != .failure or result.value.body.failure != case.failure) return error.FailureMismatch;
        std.debug.print("EDGE path={s} failure={s} cleanup=released\n", .{ case.path, @tagName(case.failure) });
    }
    for ([_][]const u8{ "/empty", "/utf8" }, 30..) |path, id| {
        const operation_key = key(owner, id);
        try service.submit(operation_key, .{ .endpoint = endpoint, .request_id = id, .path = path, .action = .{ .read_text = .{ .max_bytes = 2 } } });
        var result = try finalResult(service, operation_key);
        defer result.deinit();
        if (result.value.cleanup != .released or result.value.body != .text) return error.TextEdgeMismatch;
        const text = result.value.body.text;
        if (text.text.len != 0 or text.truncated != (id == 31) or text.original_size != (if (id == 30) @as(u64, 0) else 6)) return error.TextEdgeMismatch;
        std.debug.print("EDGE path={s} utf8_bytes=0 original_size={any} truncated={}\n", .{ path, text.original_size, text.truncated });
    }
    const list_key = key(owner, 40);
    try service.submit(list_key, .{ .endpoint = endpoint, .request_id = 40, .path = "/many", .action = .{ .list = .{ .page_entries = 1, .max_entries = 2 } } });
    var limited = try finalResult(service, list_key);
    defer limited.deinit();
    if (limited.value.body != .failure or limited.value.body.failure != .entry_limit or limited.value.cleanup != .released) return error.EntryLimitMismatch;
    std.debug.print("EDGE list_max=2 failure=entry_limit cleanup=released\n", .{});

    const cancelled_key = key(owner, 41);
    try service.submit(cancelled_key, .{ .endpoint = endpoint, .request_id = 41, .path = "/cancel", .action = .{ .read_text = .{} } });
    std.debug.print("CANCEL_WAITING_FOR_READ_GATE\n", .{});
    // The fixture sends this byte only after the peer has received a READ and
    // held its reply. This is an actual pending native operation, not a timer.
    var byte: [1]u8 = undefined;
    if (std.c.read(0, @ptrCast(&byte), 1) != 1 or byte[0] != 'C') return error.CancelGateMissing;
    if (!service.cancel(cancelled_key)) return error.ActiveCancelNotAccepted;
    std.debug.print("CANCEL_ACCEPTED_WHILE_READ_BLOCKED\n", .{});
    var cancelled = try finalResult(service, cancelled_key);
    defer cancelled.deinit();
    if (cancelled.value.body != .cancelled or cancelled.value.cleanup != .released) return error.ActiveCancelNotReleased;
    const sibling_key = key(owner, 42);
    try service.submit(sibling_key, .{ .endpoint = endpoint, .request_id = 42, .path = "/etc/os-release", .action = .{ .read_text = .{} } });
    var sibling = try finalResult(service, sibling_key);
    defer sibling.deinit();
    if (sibling.value.body != .text or sibling.value.cleanup != .released) return error.SiblingChangedByCancel;
    std.debug.print("PASS fixture_errors=true active_cancel_cleanup=released sibling_read=true\n", .{});
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const host = args.next() orelse return error.MissingHost;
    const allowed_host = init.environ_map.get("ZEROWORK_VM_HOST") orelse "127.0.0.1";
    const port = try std.fmt.parseInt(u16, args.next() orelse "22", 10);
    const mode = args.next() orelse "vm";
    if (port == 0 or (!std.mem.eql(u8, host, allowed_host) and !std.mem.eql(u8, host, "127.0.0.1"))) return error.EndpointNotAuthorized;
    if (!std.mem.eql(u8, mode, "vm") and (!std.mem.eql(u8, mode, "fixture") or !std.mem.eql(u8, host, "127.0.0.1"))) return error.ModeNotAuthorized;
    const password = init.environ_map.get("ZEROWORK_VM_PASSWORD") orelse return error.MissingCredential;
    const expected = init.environ_map.get("ZEROWORK_SFTP_FINGERPRINT") orelse return error.MissingFingerprint;
    const host_z = try init.gpa.dupeSentinel(u8, host, 0);
    defer init.gpa.free(host_z);
    const password_z = try init.gpa.dupeSentinel(u8, password, 0);
    defer init.gpa.free(password_z);
    var library = try ssh.Library.init();
    defer library.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 7 };
    const endpoint: readonly.EndpointRef = .{ .binding_id = 8, .binding_generation = 2, .resource_owner = .{ .session = owner }, .origin_session = owner };
    var native: Native = .{ .library = &library, .host = host_z, .port = port, .password = password_z, .expected_fingerprint = expected, .key = key(owner, 1) };
    const service = try readonly.Service.start(init.gpa, endpoint, .{ .key = native.key, .ctx = &native, .connect_fn = Native.connect, .close_fn = Native.close, .deinit_fn = Native.destroy });
    defer {
        native.allow_connect.store(true, .release);
        service.requestClose();
        awaitClose(service) catch unreachable;
        service.deinit() catch unreachable;
    }
    // Cancellation is deterministic: the connector is still behind its gate.
    const cancel_key = key(owner, 7);
    try service.submit(cancel_key, .{ .endpoint = endpoint, .request_id = 6, .path = "/etc/os-release", .action = .{ .read_text = .{} } });
    if (!service.cancel(cancel_key)) return error.CancelNotAccepted;
    try service.submit(key(owner, 2), .{ .endpoint = endpoint, .request_id = 1, .path = ".", .action = .realpath });
    try service.submit(key(owner, 3), .{ .endpoint = endpoint, .request_id = 2, .directory_revision = 11, .path = "/", .action = .{ .list = .{ .page_entries = 8 } } });
    try service.submit(key(owner, 4), .{ .endpoint = endpoint, .request_id = 3, .path = "/etc/os-release", .action = .stat });
    const original_path = try init.gpa.dupe(u8, "/etc/os-release");
    const accepted = service.submit(key(owner, 5), .{ .endpoint = endpoint, .request_id = 4, .path = original_path, .action = .{ .read_text = .{} } });
    init.gpa.free(original_path);
    try accepted;
    try service.submit(key(owner, 6), .{ .endpoint = endpoint, .request_id = 5, .path = "/etc/os-release", .action = .{ .read_text = .{ .max_bytes = 7 } } });
    native.allow_connect.store(true, .release);
    var complete: [6]bool = @splat(false);
    var ready = false;
    var entries: usize = 0;
    var pages: usize = 0;
    var symlinks: usize = 0;
    const deadline = clock.monotonicNs() + 40 * std.time.ns_per_s;
    while (true) {
        var finished = ready;
        for (complete) |done| finished = finished and done;
        if (finished) break;
        if (clock.monotonicNs() >= deadline) return error.ServiceTimedOut;
        const value = service.poll() orelse {
            pause();
            continue;
        };
        var result = value;
        defer result.deinit();
        const response = result.value;
        if (!response.endpoint.eql(endpoint) or response.key.owner != .session or !response.key.owner.session.eql(owner)) return error.ResponseOwnerMismatch;
        if (response.final and response.request_id != 0 and response.cleanup != .released) return error.RequestCleanupNotReleased;
        switch (response.body) {
            .ready => {
                ready = true;
                std.debug.print("READY no_shell=true binding=8 generation=2\n", .{});
            },
            .realpath => |path| {
                if (response.request_id != 1 or path.len == 0 or path[0] != '/') return error.RealpathMismatch;
                std.debug.print("REALPATH requested=. resolved={s}\n", .{path});
            },
            .page => |page| {
                if (response.request_id != 2 or response.directory_revision != 11 or page.entries.len > 8 or page.index != pages) return error.PageMismatch;
                pages += 1;
                entries += page.entries.len;
                for (page.entries) |entry| {
                    if (entry.absolute_path.len == 0 or entry.absolute_path[0] != '/') return error.EntryPathMismatch;
                    if (entry.attributes.kind == .symlink) symlinks += 1;
                }
            },
            .stat => |attributes| {
                if (response.request_id != 3) return error.StatMismatch;
                std.debug.print("LSTAT requested=/etc/os-release kind={s} size={any}\n", .{ @tagName(attributes.kind), attributes.size });
            },
            .text => |text| {
                if (response.request_id == 4) {
                    if (text.truncated or text.text.len == 0 or std.mem.indexOf(u8, text.text, "ID=") == null) return error.TextMismatch;
                    std.debug.print("READ requested=/etc/os-release resolved={s} original_size={any} read_bytes={d} utf8_bytes={d} truncated=false\n", .{ response.resolved_path.?, text.original_size, text.read_bytes, text.text.len });
                } else if (response.request_id == 5) {
                    if (!text.truncated or text.text.len > 7 or text.read_bytes > 8) return error.ReadLimitMismatch;
                    std.debug.print("READ bounded_max=7 read_bytes={d} utf8_bytes={d} truncated=true\n", .{ text.read_bytes, text.text.len });
                } else return error.UnexpectedText;
            },
            .cancelled => if (response.request_id != 6 or !response.key.eql(cancel_key)) {
                return error.CancelOwnerMismatch;
            },
            .failure => |failure| {
                std.debug.print("FAIL request={d} reason={s}\n", .{ response.request_id, @tagName(failure) });
                return error.RequestFailed;
            },
            .closed => return error.ServiceClosedEarly,
        }
        if (response.final and response.request_id != 0) complete[response.request_id - 1] = true;
    }
    if (entries == 0 or pages < 2) return error.DirectoryNotPaged;
    std.debug.print("READDIR requested=/ entries={d} pages={d} symlinks={d} recursive_follow=false\n", .{ entries, pages, symlinks });
    if (std.mem.eql(u8, mode, "fixture")) try verifyFixture(service, owner, endpoint);
    service.requestClose();
    try awaitClose(service);
    if (!native.destroyed.load(.acquire) or native.fd < 0 or std.c.fcntl(native.fd, std.c.F.GETFL, @as(c_int, 0)) != -1 or std.c._errno().* != @as(c_int, @backingInt(std.c.E.BADF))) return error.FdNotReleased;
    std.debug.print("PASS readonly=true cancelled_original_key=true sibling_requests_completed=true paths_owned=true cleanup=released fd_closed=true\n", .{});
}
