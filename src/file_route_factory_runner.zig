//! Controlled loopback acceptance for the production route-aware file factory.
//! Only REALPATH, READDIR and bounded READ; no remote shell, exec or writes.
const std = @import("std");
const files = @import("host/file_binding_host.zig");
const factory_mod = @import("host/file_route_factory.zig");
const sessions = @import("host/session_host.zig");
const identity = @import("host/identity.zig");
const operations = @import("host/operation.zig");
const ssh = @import("proto/ssh/session.zig");
const auth = @import("proto/ssh/auth_challenge.zig");
const progress = @import("proto/ssh/connection_progress.zig");
const clock = @import("platform/realtime.zig");

fn pause() void {
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn finish(service: *files.readonly.Service) !void {
    service.requestClose();
    const deadline = clock.monotonicNs() + 15 * std.time.ns_per_s;
    while (service.closeReceipt() != .released) {
        while (service.poll()) |value| {
            var result = value;
            result.deinit();
        }
        if (clock.monotonicNs() > deadline) return error.CleanupNotReleased;
        pause();
    }
}
const Trust = struct {
    key: operations.OperationKey,
    ports: []const u16,
    fingerprint: []const u8,
    reject_target: bool,
    count: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(bool) = .init(false),
    fn observe(raw: *anyopaque, host: []const u8, port: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Trust = @ptrCast(@alignCast(raw));
        const target = info.hop_index + 1 == self.ports.len;
        if (info.hop_index >= self.ports.len or !std.mem.eql(u8, host, "127.0.0.1") or self.ports[info.hop_index] != port or info.operation_key == null or !info.operation_key.?.eql(self.key) or info.source_owner == null or @backingInt(info.source_owner.?.id) != (if (target) @as(u64, 77) else 41 + info.hop_index) or info.source_owner.?.revision != (if (target) @as(u64, 6) else 8 + info.hop_index) or !std.mem.eql(u8, info.fingerprint, self.fingerprint)) {
            self.failure.store(true, .release);
            return .reject_unknown;
        }
        _ = self.count.fetchAdd(1, .release);
        return if (self.reject_target and target) .reject_unknown else .trust_once;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    const path = args.next() orelse return error.MissingTrustPath;
    const fingerprint = args.next() orelse return error.MissingFingerprint;
    if (!std.mem.startsWith(u8, path, "/") or !std.mem.endsWith(u8, path, "/known_hosts")) return error.IsolatedStoreRequired;
    const target_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    var ports: [9]u16 = undefined;
    var hop_count: usize = 0;
    while (args.next()) |port| {
        if (hop_count == 8) return error.TooManyHops;
        ports[hop_count] = try std.fmt.parseInt(u16, port, 10);
        hop_count += 1;
    }
    ports[hop_count] = target_port;
    if (hop_count == 0) return error.RouteRequired;
    const workspace = std.mem.eql(u8, mode, "workspace-blocked");
    const cancel_auth = std.mem.eql(u8, mode, "cancel-auth");
    const interactive = cancel_auth or std.mem.eql(u8, mode, "two-hop");
    const auth_fail = std.mem.eql(u8, mode, "auth-fail");
    const key_reject = std.mem.eql(u8, mode, "hostkey-reject");
    const known_route = std.mem.eql(u8, mode, "known-route");
    const target_changed = std.mem.eql(u8, mode, "target-changed-nonstrict");
    const hop_changed = std.mem.eql(u8, mode, "hop-changed-strict");
    if (!workspace and !cancel_auth and !interactive and !auth_fail and !key_reject and !known_route and !target_changed and !hop_changed and !std.mem.eql(u8, mode, "one-hop")) return error.InvalidMode;
    var library = try ssh.Library.init();
    defer library.deinit();
    var journal = operations.Journal.init(init.gpa);
    defer journal.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 7 };
    const create_key = try journal.begin(.{ .session = owner }, 4);
    const open_key = try journal.begin(.{ .session = owner }, 4);
    var trust: Trust = .{ .key = open_key, .ports = ports[0 .. hop_count + 1], .fingerprint = fingerprint, .reject_target = key_reject };
    var authentication: auth.InteractiveBridge = .{};
    var request_counter: auth.RequestCounter = .{};
    authentication.request_counter = &request_counter;
    var progress_journal: progress.Journal = .{};
    progress_journal.begin(4);
    var factory: factory_mod.SourceFactory = .{ .library = &library, .known_hosts_path = path, .host_key_observer = .{ .ctx = &trust, .callback = Trust.observe }, .auth_interaction = if (interactive) .{ .bridge = &authentication, .presentation_config_revision = 19, .timeout_ms = 3000 } else null, .progress_observer = progress_journal.observer(), .timeout_ms = 3000 };
    var source_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer source_arena.deinit();
    const a = source_arena.allocator();
    const hops = try a.alloc(sessions.RouteHop, hop_count);
    for (hops, 0..) |*hop, index| hop.* = .{ .owner = .{ .id = @fromBackingInt(41 + index), .revision = 8 + index }, .display_name = try std.fmt.allocPrint(a, "frozen-hop-{d}", .{index}), .endpoint = .{ .host = try a.dupe(u8, "127.0.0.1"), .port = ports[index], .user = try std.fmt.allocPrint(a, "hop-user-{d}", .{index}) }, .auth = if (interactive) .password_prompt else .{ .password = try std.fmt.allocPrint(a, "hop-secret-{d}", .{index}) }, .strict_host_key_checking = true };
    const host = try a.dupe(u8, "127.0.0.1");
    const target_password = try a.dupe(u8, "target-secret");
    const source: files.Source = .{ .owner = owner, .create_key = create_key, .open_key = open_key, .spec = .{ .saved = .{ .connection_id = @fromBackingInt(77), .config_revision = 6, .protocol = if (workspace) .sftp else .ssh, .immutable_config = .{ .endpoint = .{ .host = host, .port = target_port, .user = "target-user" }, .auth = if (interactive) .password_prompt else .{ .password = target_password }, .strict_host_key_checking = false, .startup_commands = &.{"SHOULD_NOT_EXECUTE"} }, .route_snapshot = hops } } };
    const connector = factory.interface().prepare(&factory, source) catch |err| {
        if (workspace and err == error.ProxyJumpTransportUnavailable) {
            std.debug.print("PASS workspace-blocked no_network=true original_route={d}\n", .{hop_count});
            return;
        }
        return err;
    };
    if (workspace) return error.WorkspaceRouteWasAllowed;
    // Mutation after prepare must not change endpoints or credentials used by
    // the worker. Each peer independently checks its original username/secret.
    @memset(host, 'X');
    @memset(target_password, 'X');
    for (hops) |*hop| {
        @memset(@constCast(hop.endpoint.host), 'X');
        if (hop.auth == .password) @memset(@constCast(hop.auth.password), 'X');
        hop.strict_host_key_checking = false;
        hop.owner.?.revision += 1;
    }
    const endpoint: files.readonly.EndpointRef = .{ .binding_id = 8, .binding_generation = owner.generation, .resource_owner = .{ .session = owner }, .origin_session = owner, .connection_snapshot_id = create_key.operation_id };
    const service = try files.readonly.Service.start(init.gpa, endpoint, connector);
    var disposed = false;
    defer if (!disposed) {
        finish(service) catch unreachable;
        service.deinit() catch unreachable;
    };
    const read_key = try journal.begin(.{ .session = owner }, 4);
    const list_key = try journal.begin(.{ .session = owner }, 4);
    const path_key = try journal.begin(.{ .session = owner }, 4);
    try service.submit(read_key, .{ .endpoint = endpoint, .request_id = read_key.operation_id, .path = "/entry", .action = .{ .read_text = .{ .max_bytes = 64 } } });
    try service.submit(list_key, .{ .endpoint = endpoint, .request_id = list_key.operation_id, .path = "/", .action = .{ .list = .{ .page_entries = 8 } } });
    try service.submit(path_key, .{ .endpoint = endpoint, .request_id = path_key.operation_id, .path = ".", .action = .realpath });
    var ready = false;
    var read_done = false;
    var list_done = false;
    var path_done = false;
    var failed = false;
    var cancelled = false;
    var auth_count: usize = 0;
    var last_auth_id: u64 = 0;
    var entries: usize = 0;
    var pages: usize = 0;
    const deadline = clock.monotonicNs() + 20 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        if (authentication.snapshot()) |request| if (request.state == .input and request.identity.request_id != last_auth_id) {
            const index = request.identity.hop_index;
            if (!request.identity.key.eql(open_key) or index > hop_count or request.port != ports[index] or request.source_owner == null or @backingInt(request.source_owner.?.id) != (if (index == hop_count) @as(u64, 77) else 41 + index) or request.presentation_config_revision != 19 or request.kind != .password) return error.ForeignAuthentication;
            last_auth_id = request.identity.request_id;
            auth_count += 1;
            if (cancel_auth and index == hop_count) {
                service.requestClose();
                cancelled = true;
            } else {
                const answer = if (index == hop_count) "target-secret" else try std.fmt.allocPrint(a, "hop-secret-{d}", .{index});
                try authentication.submit(request.identity, .{ .answers = &.{answer} });
            }
        };
        while (service.poll()) |value| {
            var result = value;
            defer result.deinit();
            const response = result.value;
            if (!response.endpoint.eql(endpoint)) return error.ForeignEndpoint;
            switch (response.body) {
                .ready => {
                    if (!response.key.eql(open_key)) return error.ForeignOperation;
                    ready = true;
                },
                .text => |text| {
                    if (!response.key.eql(read_key) or response.cleanup != .released or text.text.len != 64 or !std.mem.startsWith(u8, text.text, "NAME=")) return error.ReadMismatch;
                    read_done = true;
                },
                .page => |page| {
                    if (!response.key.eql(list_key) or page.index != pages) return error.ListMismatch;
                    entries += page.entries.len;
                    pages += 1;
                    if (response.final) list_done = true;
                },
                .realpath => |resolved| {
                    if (!response.key.eql(path_key) or !std.mem.eql(u8, resolved, "/root")) return error.RealpathMismatch;
                    path_done = true;
                },
                .failure => failed = true,
                .cancelled, .closed => {},
                else => return error.UnexpectedResult,
            }
        }
        if (ready and read_done and list_done and path_done) {
            service.requestClose();
            break;
        }
        if ((failed or cancelled) and service.closeReceipt() == .released) break;
        pause();
    }
    try finish(service);
    try service.deinit();
    disposed = true;
    if (trust.failure.load(.acquire)) return error.ForeignTrustChallenge;
    if (cancel_auth) {
        if (!cancelled or ready or auth_count != hop_count + 1) return error.CancelDidNotStopTargetAuthentication;
    } else if (auth_fail or key_reject or hop_changed) {
        if (!failed or ready) return error.TargetFailureWasNotPropagated;
    } else if (!ready or !read_done or !list_done or !path_done or failed or entries != 21 or pages != 3) return error.FileOperationsIncomplete;
    const phases = progress_journal.snapshot();
    if (phases.count == 0) return error.ProgressMissing;
    for (phases.entries[0..phases.count]) |event| if (event.phase == .shell) return error.ShellPhaseWasStarted;
    const expected_observers = if (known_route or target_changed) @as(usize, 0) else if (hop_changed) @as(usize, 1) else hop_count + 1;
    if (trust.count.load(.acquire) != expected_observers) return error.HopTrustWasSkipped;
    std.debug.print("PASS mode={s} original_owner=101 generation=7 create={d} file_open={d} hops={d} target_shell=false auth_prompts={d} readonly_entries={d} pages={d} cleanup=released\n", .{ mode, create_key.operation_id, open_key.operation_id, hop_count, auth_count, entries, pages });
}
