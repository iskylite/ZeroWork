//! Owned loopback acceptance. The fixture adapter issues real domain handles;
//! all network IO uses production FileBindingHost/SourceFactory/SFTP service.
const std = @import("std");
const capture = @import("host/ai_remote_file_snapshot.zig");
const files = @import("host/file_binding_host.zig");
const routes = @import("host/file_route_factory.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");

const Adapter = struct {
    file_host: ?*files.FileBindingHost = null,
    ssh_mode: bool = false,
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(raw: *anyopaque, owner: sessions.SessionHandle, key: sessions.OperationKey) !sessions.CloseReceipt {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        return if (self.file_host) |host| switch (try host.requestClose(owner, key)) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        } else .released;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = if (self.ssh_mode) .ssh else .sftp, .workspace_kind = if (self.ssh_mode) .terminal else .file, .services = plugins.requiredServices(if (self.ssh_mode) .ssh else .sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
const Trust = struct {
    fingerprint: []const u8,
    owner: sessions.SessionHandle,
    key: ?sessions.OperationKey = null,
    called: usize = 0,
    fn observe(raw: *anyopaque, host: []const u8, _: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Trust = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, host, "127.0.0.1") or !std.mem.eql(u8, info.fingerprint, self.fingerprint) or info.operation_key == null or info.operation_key.?.owner != .session or !info.operation_key.?.owner.session.eql(self.owner)) return .reject_unknown;
        self.key = info.operation_key;
        self.called += 1;
        return .trust_once;
    }
};
fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn assert(value: bool) !void {
    if (!value) return error.AcceptanceAssertion;
}
fn waitReader(host: *files.FileBindingHost, reader: *capture.Reader, live: ?capture.Context) !void {
    const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        _ = try host.safeTick();
        _ = reader.poll(live);
        if (reader.terminal and reader.cleanupReceipt() == .released) return;
        pause();
    }
    return error.ReaderTimeout;
}
fn read(allocator: std.mem.Allocator, host: *files.FileBindingHost, context: capture.Context, path: []const u8, action: capture.Action) !capture.ResultRef {
    const reader = try capture.Reader.start(allocator, host, context, path, action);
    try waitReader(host, reader, context);
    const result = reader.take() orelse return error.MissingCapture;
    try reader.deinit();
    try assert(result.value().?.metadata.source.eql(context.source.session));
    try assert(result.value().?.metadata.source_revision == context.source.revision);
    try assert(std.mem.eql(u8, result.value().?.metadata.requested_path, path));
    try assert(result.value().?.metadata.operation.owner.session.eql(context.source.session));
    try assert(result.value().?.metadata.captured_at_ms > 0);
    if (result.value().?.body != .failure) {
        const projection = try @import("ui/ai_file_tool_result.zig").project(allocator, result.value().?, 65536);
        defer projection.deinit(allocator);
        try assert(projection.stdout.len + projection.stderr.len <= 65536);
        try assert(std.unicode.utf8ValidateSlice(projection.stdout));
        if (result.value().?.body == .text) {
            try assert(std.mem.startsWith(u8, result.value().?.body.text.bytes, projection.stdout));
            try assert(projection.truncated == (result.value().?.body.text.truncated or projection.stdout.len < result.value().?.body.text.bytes.len));
        }
    }
    return result;
}
fn expectFailure(allocator: std.mem.Allocator, host: *files.FileBindingHost, context: capture.Context, path: []const u8, failure: files.readonly.Failure) !void {
    var reference = try read(allocator, host, context, path, .{ .read = .{} });
    defer reference.release();
    const value = reference.value().?;
    try assert(value.body == .failure and value.body.failure == .remote and value.body.failure.remote == failure);
}
fn stdinGate() !void {
    var byte: [1]u8 = undefined;
    if (std.c.read(0, &byte, 1) != 1) return error.MissingOwnedReadGate;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const requested_mode = args.next() orelse return error.MissingMode;
    const auxiliary = std.mem.startsWith(u8, requested_mode, "aux-");
    const mode = if (auxiliary) requested_mode[4..] else requested_mode;
    const known_hosts = args.next() orelse return error.MissingTrustPath;
    const fingerprint = args.next() orelse return error.MissingFingerprint;
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    var library = try ssh.Library.init();
    defer library.deinit();
    var adapter: Adapter = .{ .ssh_mode = auxiliary };
    var domain = try sessions.SessionHost.init(init.gpa, &.{adapter.interface()});
    defer domain.deinit();
    const accepted = try domain.create(.{ .saved = .{ .connection_id = @fromBackingInt(77), .config_revision = 6, .protocol = if (auxiliary) .ssh else .sftp, .immutable_config = .{ .endpoint = .{ .host = "127.0.0.1", .port = port, .user = "fixture" }, .auth = .{ .password = "fixture-password" }, .strict_host_key_checking = false } } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    try assert(try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(if (auxiliary) .ssh else .sftp)));
    try assert(try domain.attached(accepted.handle, .{ .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .tab_id = @fromBackingInt(1) }));
    const reserved = if (auxiliary) try domain.beginAuxiliaryReadonly(accepted.handle) else null;
    const logical: files.Bindings = if (reserved) |start| .{ .directory = start.bindings.directory, .file_read = start.bindings.file_read } else .{ .directory = domain.queryService(accepted.handle, .directory).available, .file_read = domain.queryService(accepted.handle, .file_read).available };
    if (auxiliary) try assert(!domain.bindingIsLive(logical.directory) and !domain.bindingIsLive(logical.file_read));
    var trust: Trust = .{ .fingerprint = fingerprint, .owner = accepted.handle };
    var factory: routes.SourceFactory = .{ .library = &library, .known_hosts_path = known_hosts, .host_key_observer = .{ .ctx = &trust, .callback = Trust.observe }, .timeout_ms = 3000 };
    var host = try files.FileBindingHost.init(init.gpa, &domain, factory.interface());
    adapter.file_host = &host;
    var closed = false;
    defer if (!closed) {
        host.requestCloseAll();
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (host.safeTick() catch false) {
            if (clock.monotonicNs() > deadline) break;
            pause();
        }
        host.deinit() catch {};
    };
    if (reserved) |start| {
        _ = try host.attachAuxiliary(accepted.handle, start);
    } else {
        _ = try host.attach(accepted.handle, logical);
    }
    const connect_deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (host.state(logical.directory).?.phase != .ready) {
        _ = try host.safeTick();
        if (clock.monotonicNs() > connect_deadline) return error.ConnectTimeout;
        pause();
    }
    try assert(domain.bindingIsLive(logical.directory) and domain.bindingIsLive(logical.file_read));
    try assert(trust.called == 1 and trust.key.?.eql(host.state(logical.directory).?.open_key));
    const context: capture.Context = .{ .scope = .{ .owner = .{ .session = @backingInt(accepted.handle.session_id) }, .members = .{ .ids = .{@backingInt(accepted.handle.session_id)} ++ @as([15]u64, @splat(0)), .len = 1 } }, .source = .{ .session = accepted.handle, .revision = 17, .bindings = logical } };

    if (std.mem.eql(u8, mode, "bounds")) {
        var listing = try read(init.gpa, &host, context, "/", .{ .list = .{ .max_entries = 8 } });
        try assert(listing.value().?.body == .listing and listing.value().?.body.listing.truncated and listing.value().?.body.listing.entries.len == 8);
        try assert(std.mem.eql(u8, listing.value().?.metadata.actual_path.?, "/"));
        listing.release();
        var full = try read(init.gpa, &host, context, "/", .{ .list = .{} });
        try assert(full.value().?.body == .listing and !full.value().?.body.listing.truncated and full.value().?.body.listing.entries.len == 21);
        full.release();
        var small = try read(init.gpa, &host, context, "/large", .{ .read = .{} });
        try assert(small.value().?.body == .text and small.value().?.body.text.returned_bytes == 4096 and small.value().?.body.text.read_bytes == 4097 and small.value().?.body.text.truncated and small.value().?.body.text.original_size == 70000);
        var retained = small.retain();
        small.release();
        try assert(retained.value().?.body.text.bytes.len == 4096);
        retained.release();
        var maximum = try read(init.gpa, &host, context, "/large", .{ .read = .{ .max_bytes = 65536 } });
        try assert(maximum.value().?.body.text.returned_bytes == 65536 and maximum.value().?.body.text.read_bytes == 65537 and maximum.value().?.body.text.truncated);
        maximum.release();
        var exact = try read(init.gpa, &host, context, "/exact", .{ .read = .{ .max_bytes = 65536 } });
        try assert(exact.value().?.body.text.returned_bytes == 65536 and exact.value().?.body.text.read_bytes == 65536 and !exact.value().?.body.text.truncated);
        exact.release();
        var utf8 = try read(init.gpa, &host, context, "/utf8", .{ .read = .{ .max_bytes = 2 } });
        try assert(utf8.value().?.body.text.returned_bytes == 0 and utf8.value().?.body.text.read_bytes == 3 and utf8.value().?.body.text.truncated and utf8.value().?.body.text.original_size == 6);
        utf8.release();
        try expectFailure(init.gpa, &host, context, "/binary", .unsupported_binary);
        try expectFailure(init.gpa, &host, context, "/invalid", .unsupported_encoding);
        try expectFailure(init.gpa, &host, context, "/device", .not_regular_file);
        try expectFailure(init.gpa, &host, context, "/change", .source_changed);
        try expectFailure(init.gpa, &host, context, "/denied", .permission_denied);
        try expectFailure(init.gpa, &host, context, "/missing", .not_found);
    } else if (std.mem.eql(u8, mode, "close-pending")) {
        const reader = try capture.Reader.start(init.gpa, &host, context, "/cancel", .{ .read = .{} });
        try stdinGate();
        reader.cancel();
        // The UI close gate must keep this original reader and host alive
        // while the peer is still holding the real native READ response.
        if (reader.deinit()) |_| return error.PrematureReaderRelease else |err| try assert(err == error.Busy);
        _ = reader.poll(null);
        try assert(!reader.terminal and reader.take() == null and host.pending.items.len == 1);
        std.debug.print("CANCEL_ACCEPTED_WHILE_READ_BLOCKED\n", .{});
        try waitReader(&host, reader, null);
        var result = reader.take() orelse return error.MissingCapture;
        try assert(result.value().?.body == .failure and result.value().?.body.failure == .cancelled);
        try assert(reader.retired and host.pending.items.len == 0);
        result.release();
        try reader.deinit();
    } else if (std.mem.eql(u8, mode, "cancel") or std.mem.eql(u8, mode, "late-source") or std.mem.eql(u8, mode, "member-removed")) {
        const reader = try capture.Reader.start(init.gpa, &host, context, "/cancel", .{ .read = .{} });
        // Python writes only after the real server has entered native READ.
        try stdinGate();
        var live = context;
        if (std.mem.eql(u8, mode, "cancel")) reader.cancel() else if (std.mem.eql(u8, mode, "late-source")) live.source.revision += 1 else live.scope.members.len = 0;
        _ = reader.poll(live);
        try assert(!reader.terminal);
        std.debug.print("CANCEL_ACCEPTED_WHILE_READ_BLOCKED\n", .{});
        try waitReader(&host, reader, live);
        var result = reader.take().?;
        try assert(result.value().?.body == .failure and (if (std.mem.eql(u8, mode, "cancel")) result.value().?.body.failure == .cancelled else result.value().?.body.failure == .source_changed));
        result.release();
        try reader.deinit();
        var sibling = try read(init.gpa, &host, context, "/empty", .{ .read = .{} });
        try assert(sibling.value().?.body == .text and sibling.value().?.body.text.bytes.len == 0);
        sibling.release();
    } else if (std.mem.eql(u8, mode, "oom")) {
        var failing = std.testing.FailingAllocator.init(init.gpa, .{});
        const reader = try capture.Reader.start(failing.allocator(), &host, context, "/large", .{ .read = .{} });
        failing.fail_index = failing.alloc_index;
        try waitReader(&host, reader, context);
        var result = reader.take().?;
        try assert(result.value().?.body == .failure and result.value().?.body.failure == .out_of_memory);
        result.release();
        try reader.deinit();
        try assert(failing.allocated_bytes == failing.freed_bytes);
    } else if (std.mem.eql(u8, mode, "tool-shutdown")) {
        const reader = try capture.Reader.start(init.gpa, &host, context, "/large", .{ .read = .{} });
        // App teardown relinquishes only the consumer; the original host
        // still owns this exact pending operation until its real close.
        try assert(host.pending.items.len == 1);
        reader.detachForHostShutdown();
        try assert(host.pending.items.len == 1);
    } else if (std.mem.eql(u8, mode, "queued-cancel")) {
        const reader = try capture.Reader.start(init.gpa, &host, context, "/empty", .{ .read = .{} });
        try waitReader(&host, reader, context);
        reader.cancel();
        var result = reader.take().?;
        try assert(result.value().?.body == .failure and result.value().?.body.failure == .cancelled);
        result.release();
        try reader.deinit();
    } else return error.InvalidMode;

    // Reader business terminals must have retired their original operation;
    // service-open and attached parent remain real until their own close.
    if (!std.mem.eql(u8, mode, "tool-shutdown")) try assert(host.pending.items.len == 0);
    const close_key = try domain.requestClose(accepted.handle, .{});
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (host.bindings.items.len != 0) {
        _ = try host.requestClose(accepted.handle, close_key);
        _ = try host.safeTick();
        if (clock.monotonicNs() > deadline) return error.CleanupTimeout;
        pause();
    }
    try host.deinit();
    closed = true;
    std.debug.print("PASS mode={s} original_session={d} generation={d} source_revision=17 actual_file_bindings=true cleanup=released native_shell=false\n", .{ mode, @backingInt(accepted.handle.session_id), accepted.handle.generation });
}
