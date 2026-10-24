//! Independent no-shell file connections using the same native Route as the
//! formal SSH worker. Entry policy is explicit; no active PTY is borrowed.
const std = @import("std");
const files = @import("file_binding_host.zig");
const sessions = @import("session_host.zig");
const identity = @import("identity.zig");
const ssh = @import("../proto/ssh/session.zig");
const Route = @import("../proto/ssh/jump_transport.zig").Route;
const known = @import("../proto/ssh/host_key_store.zig");
const progress = @import("../proto/ssh/connection_progress.zig");
const Snapshot = @import("../ui/session_lifecycle.zig").Snapshot;
const allocator = std.heap.c_allocator;
const Forward = @import("../proto/ssh/forward_service.zig").Service;

pub const EntryKind = enum { sftp_workspace, ssh_file_tool };
/// Application-level factory for a shared FileBindingHost. Entry policy comes
/// from the frozen create spec, never the currently selected tab or route size.
pub const SourceFactory = struct {
    library: *const ssh.Library,
    known_hosts_path: []const u8,
    host_key_observer: ?ssh.HostKeyObserver = null,
    auth_interaction: ?ssh.AuthInteraction = null,
    progress_observer: ?progress.Observer = null,
    timeout_ms: u32 = 15_000,
    /// Optional stable facades for an original no-shell background owner.
    /// Only Route's existing Relay may drive an upstream facade.
    forward_services: []const ?*Forward = &.{},

    pub fn interface(self: *SourceFactory) files.Factory {
        return .{ .context = self, .prepare = prepare, .discard = RouteFactory.discard };
    }

    fn prepare(raw: *anyopaque, source: files.Source) !files.readonly.Connector {
        const self: *SourceFactory = @ptrCast(@alignCast(raw));
        var factory: RouteFactory = .{
            .library = self.library,
            .known_hosts_path = self.known_hosts_path,
            .entry_kind = switch (source.spec.pluginId()) {
                .local, .external => return error.UnsupportedProtocol,
                .ssh => .ssh_file_tool,
                .sftp => .sftp_workspace,
            },
            .host_key_observer = self.host_key_observer,
            .auth_interaction = self.auth_interaction,
            .progress_observer = self.progress_observer,
            .timeout_ms = self.timeout_ms,
            .forward_services = self.forward_services,
        };
        // RouteFactory copies the complete policy and Source into its Native
        // owner before returning; no connector borrows this stack factory.
        return RouteFactory.prepare(&factory, source);
    }
};

pub const RouteFactory = struct {
    library: *const ssh.Library,
    known_hosts_path: []const u8,
    entry_kind: EntryKind,
    // Borrowed interaction/observer owners must outlive the file connection.
    host_key_observer: ?ssh.HostKeyObserver = null,
    auth_interaction: ?ssh.AuthInteraction = null,
    progress_observer: ?progress.Observer = null,
    timeout_ms: u32 = 15_000,
    forward_services: []const ?*Forward = &.{},

    pub fn interface(self: *RouteFactory) files.Factory {
        return .{ .context = self, .prepare = prepare, .discard = discard };
    }
    fn prepare(raw: *anyopaque, source: files.Source) !files.readonly.Connector {
        const self: *RouteFactory = @ptrCast(@alignCast(raw));
        try validateEntry(source, self.entry_kind);
        if (!self.library.active) return error.LibraryNotInitialized;
        if (!std.fs.path.isAbsolute(self.known_hosts_path)) return error.InvalidTrustStorePath;
        if (self.timeout_ms == 0) return error.InvalidTimeout;
        var frozen = try Snapshot(files.Source).init(allocator, source);
        errdefer frozen.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const path = try arena.allocator().dupe(u8, self.known_hosts_path);
        if (self.forward_services.len != 0 and self.forward_services.len != routeOf(source.spec).len + 1) return error.InvalidForwardRoute;
        var policy = self.*;
        policy.forward_services = try arena.allocator().dupe(?*Forward, self.forward_services);
        const context = try allocator.create(Native);
        errdefer allocator.destroy(context);
        context.* = .{ .source = frozen, .policy = policy, .arena = arena, .path = path, .ledger = try ssh.ResourceLedger.init(source.open_key, routeOf(source.spec).len + 1) };
        return .{ .key = source.open_key, .ctx = context, .connect_fn = Native.connect, .close_fn = Native.close, .deinit_fn = Native.destroy };
    }
    fn discard(_: *anyopaque, connector: files.readonly.Connector) void {
        Native.destroy(connector.ctx);
    }
};

fn testSource() files.Source {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 7 };
    return .{
        .owner = owner,
        .create_key = .{ .owner = .{ .session = owner }, .operation_id = 37, .attempt_id = 4 },
        .open_key = .{ .owner = .{ .session = owner }, .operation_id = 38, .attempt_id = 4 },
        .spec = .{ .saved = .{ .connection_id = @fromBackingInt(77), .config_revision = 6, .protocol = .ssh, .immutable_config = .{ .endpoint = .{ .host = "target.example", .user = "target-user" }, .auth = .{ .password = "target-secret" }, .strict_host_key_checking = false, .startup_commands = &.{"SHOULD_NOT_EXECUTE"} }, .route_snapshot = &.{.{ .owner = .{ .id = @fromBackingInt(41), .revision = 8 }, .endpoint = .{ .host = "hop.example", .user = "hop-user" }, .auth = .{ .password = "hop-secret" }, .strict_host_key_checking = true }} } },
    };
}

test "route file factory workspace policy rejects route before library or native IO" {
    var library: ssh.Library = .{ .active = false };
    var factory: RouteFactory = .{ .library = &library, .known_hosts_path = "/tmp/unused-known-hosts", .entry_kind = .sftp_workspace };
    var source = testSource();
    source.spec.saved.protocol = .sftp;
    try std.testing.expectError(error.ProxyJumpTransportUnavailable, factory.interface().prepare(&factory, source));
    factory.entry_kind = .ssh_file_tool;
    try std.testing.expectError(error.UnsupportedEntrySource, factory.interface().prepare(&factory, source));
    source.spec = .{ .local = .{} };
    try std.testing.expectError(error.UnsupportedProtocol, factory.interface().prepare(&factory, source));
}

test "shared file factory keeps SSH routes and rejects workspace routes before IO" {
    var library: ssh.Library = .{ .active = false };
    var factory: SourceFactory = .{ .library = &library, .known_hosts_path = "/tmp/unused-known-hosts" };
    const api = factory.interface();
    var source = testSource();
    // The same routed source is eligible only for the SSH file-tool entry.
    try std.testing.expectError(error.LibraryNotInitialized, api.prepare(api.context, source));
    source.spec.saved.protocol = .sftp;
    try std.testing.expectError(error.ProxyJumpTransportUnavailable, api.prepare(api.context, source));
    source.spec.saved.route_snapshot = &.{};
    try std.testing.expectError(error.LibraryNotInitialized, api.prepare(api.context, source));
    source.spec = .{ .local = .{} };
    try std.testing.expectError(error.UnsupportedProtocol, api.prepare(api.context, source));
}

test "shared file factory connector owns policy after stack dispatch returns" {
    var library: ssh.Library = .{ .active = true };
    var factory: SourceFactory = .{ .library = &library, .known_hosts_path = "/tmp/frozen-trust", .timeout_ms = 9_000 };
    const api = factory.interface();
    var source = testSource();
    const connector = try api.prepare(api.context, source);
    defer api.discard(api.context, connector);
    source.spec.saved.protocol = .sftp;
    factory.timeout_ms = 1;
    factory.known_hosts_path = "/tmp/replaced-trust";
    const native: *Native = @ptrCast(@alignCast(connector.ctx));
    var cancelled: std.atomic.Value(bool) = .init(false);
    const options = try native.options(&cancelled);
    try std.testing.expectEqual(@as(usize, 2), options.len);
    try std.testing.expectEqual(EntryKind.ssh_file_tool, native.policy.entry_kind);
    try std.testing.expectEqualStrings("/tmp/frozen-trust", native.path);
    for (options) |option| {
        try std.testing.expectEqual(@as(u32, 9_000), option.connect_timeout_ms);
        try std.testing.expect(option.operation_key.?.eql(connector.key));
        try std.testing.expect(!option.open_shell);
    }
}

test "route file factory copies every source hop and keeps native options no shell on one original owner" {
    var library: ssh.Library = .{ .active = true };
    var factory: RouteFactory = .{ .library = &library, .known_hosts_path = "/tmp/unused-known-hosts", .entry_kind = .ssh_file_tool };
    var target_host = "target.example".*;
    var target_password = "target-secret".*;
    var hop_host = "hop.example".*;
    var hop_path = "/frozen/hop/key".*;
    var hops = [_]sessions.RouteHop{.{ .owner = .{ .id = @fromBackingInt(41), .revision = 8 }, .endpoint = .{ .host = &hop_host, .user = "hop-user" }, .auth = .{ .private_key = .{ .path = &hop_path, .passphrase = "hop-passphrase" } }, .strict_host_key_checking = true }};
    var source = testSource();
    source.spec.saved.immutable_config.endpoint.host = &target_host;
    source.spec.saved.immutable_config.auth = .{ .password = &target_password };
    source.spec.saved.route_snapshot = &hops;
    const connector = try factory.interface().prepare(&factory, source);
    defer connector.deinit_fn(connector.ctx);
    target_host[0] = 'X';
    target_password[0] = 'X';
    hop_host[0] = 'X';
    hop_path[0] = 'X';
    hops[0].owner.?.revision = 9;
    hops[0].strict_host_key_checking = false;
    factory.timeout_ms = 1;
    const native: *Native = @ptrCast(@alignCast(connector.ctx));
    var cancelled: std.atomic.Value(bool) = .init(false);
    const options = try native.options(&cancelled);
    try std.testing.expectEqual(@as(usize, 2), options.len);
    try std.testing.expectEqualStrings("hop.example", options[0].host);
    try std.testing.expectEqualStrings("/frozen/hop/key", options[0].auth.private_key.path);
    try std.testing.expectEqualStrings("target.example", options[1].host);
    try std.testing.expectEqualStrings("target-secret", options[1].auth.password);
    try std.testing.expect(options[0].strict_host_key_checking and !options[1].strict_host_key_checking);
    try std.testing.expectEqual(@as(u64, 8), options[0].source_owner.?.revision);
    try std.testing.expectEqual(@as(u64, 6), options[1].source_owner.?.revision);
    for (options, 0..) |option, index| {
        try std.testing.expect(!option.open_shell);
        try std.testing.expect(option.operation_key.?.eql(source.open_key));
        try std.testing.expect(option.resource_ledger == &native.ledger);
        try std.testing.expect(option.cancel_token == &cancelled);
        try std.testing.expectEqual(@as(usize, 2), option.hop_count);
        try std.testing.expectEqual(index, option.hop_index);
        try std.testing.expectEqual(@as(u32, 15_000), option.connect_timeout_ms);
    }
    try std.testing.expect(native.ledger.snapshot().released());
}

test "route file factory rejects foreign operation generation without acquiring native resources" {
    var library: ssh.Library = .{ .active = false };
    var factory: RouteFactory = .{ .library = &library, .known_hosts_path = "/tmp/unused-known-hosts", .entry_kind = .ssh_file_tool };
    var source = testSource();
    source.open_key.owner.session.generation += 1;
    try std.testing.expectError(error.InvalidOperationOwner, factory.interface().prepare(&factory, source));
}

test "route file factory already cancelled connection has released ledger and performs no filesystem or native IO" {
    var library: ssh.Library = .{ .active = true };
    var factory: RouteFactory = .{ .library = &library, .known_hosts_path = "/does-not-exist/no-write/known_hosts", .entry_kind = .ssh_file_tool };
    const connector = try factory.interface().prepare(&factory, testSource());
    defer connector.deinit_fn(connector.ctx);
    var cancelled: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, connector.connect_fn(connector.ctx, &cancelled));
    const native: *Native = @ptrCast(@alignCast(connector.ctx));
    try std.testing.expect(native.io == null and native.store == null and native.route == null);
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, connector.close_fn(connector.ctx, null));
    try std.testing.expect(native.ledger.snapshot().released());
    try std.testing.expectError(error.ConnectorAlreadyStarted, connector.connect_fn(connector.ctx, &cancelled));
}

test "route file factory unknown cleanup never destroys a retained route owner" {
    var library: ssh.Library = .{ .active = true };
    var factory: RouteFactory = .{ .library = &library, .known_hosts_path = "/tmp/unused-known-hosts", .entry_kind = .ssh_file_tool };
    const source = testSource();
    const connector = try factory.interface().prepare(&factory, source);
    defer connector.deinit_fn(connector.ctx);
    const native: *Native = @ptrCast(@alignCast(connector.ctx));
    try std.testing.expect(native.ledger.record(source.open_key, 0, .transport, .owned));
    try std.testing.expect(native.ledger.record(source.open_key, 0, .transport, .unknown));
    try std.testing.expectEqual(ssh.ReleaseReceipt.unknown, connector.close_fn(connector.ctx, null));
    try std.testing.expect(!native.ledger.snapshot().released());
    // The fixture supplies the later real-owner receipt; merely polling above
    // did not change the record or free the context.
    try std.testing.expect(native.ledger.record(source.open_key, 0, .transport, .released));
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, connector.close_fn(connector.ctx, null));
}

fn routeOf(spec: sessions.SessionCreateSpec) []const sessions.RouteHop {
    return switch (spec) {
        .saved => |saved| saved.route_snapshot,
        .temporary_ssh => |temporary| temporary.route_snapshot,
        .local, .plugin => &.{},
    };
}
fn validateEntry(source: files.Source, entry_kind: EntryKind) !void {
    try source.spec.validate();
    if (source.spec == .local or source.spec == .plugin) return error.UnsupportedProtocol;
    if (!source.ownsOperation(source.create_key) or !source.ownsOperation(source.open_key)) return error.InvalidOperationOwner;
    const routed = routeOf(source.spec).len != 0;
    switch (entry_kind) {
        .sftp_workspace => {
            if (routed) return error.ProxyJumpTransportUnavailable;
            if (source.spec.pluginId() != .sftp) return error.UnsupportedEntrySource;
        },
        .ssh_file_tool => if (source.spec.pluginId() != .ssh) return error.UnsupportedEntrySource,
    }
}

const Native = struct {
    source: Snapshot(files.Source),
    policy: RouteFactory,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    ledger: ssh.ResourceLedger,
    io: ?std.Io.Threaded = null,
    store: ?known.HostKeyStore = null,
    route: ?*Route = null,
    started: bool = false,

    /// Runs only on readonly.Service's sole IO owner, exactly once.
    fn connect(raw: *anyopaque, cancelled: *const std.atomic.Value(bool)) !ssh.Session {
        const self: *Native = @ptrCast(@alignCast(raw));
        if (self.started) return error.ConnectorAlreadyStarted;
        self.started = true;
        if (cancelled.load(.acquire)) return error.Cancelled;
        self.io = .init(allocator, .{});
        self.store = try known.HostKeyStore.load(self.io.?.io(), std.Io.Dir.cwd(), allocator, self.path);
        const plan = try self.options(cancelled);
        if (plan.len == 1) return ssh.Session.connect(self.policy.library, plan[0]);
        // This is the exact multi-hop transport consumed by SshWorker.init.
        // All options disable shell; parent Route hops only open direct-tcpip.
        const route = try Route.connect(allocator, self.policy.library, plan);
        self.route = route;
        // Every fallible initialization has completed. A failed Route.connect
        // rollback must never retain pointers to facades its caller may free.
        if (self.policy.forward_services.len != 0) route.bindForwards(self.policy.forward_services);
        return route.takeTarget();
    }
    fn options(self: *Native, cancelled: *const std.atomic.Value(bool)) ![]ssh.Options {
        const source = self.source.value;
        const hops = routeOf(source.spec);
        const result = try self.arena.allocator().alloc(ssh.Options, hops.len + 1);
        for (hops, 0..) |hop, index| result[index] = try self.option(hop.endpoint, hop.auth, hop.owner, hop.strict_host_key_checking, hop.display_name, index, hops.len + 1, cancelled);
        const remote: sessions.RemoteConfig = switch (source.spec) {
            .saved => |saved| saved.immutable_config,
            .temporary_ssh => |temporary| .{ .endpoint = temporary.structured_endpoint, .auth = temporary.auth_options, .strict_host_key_checking = temporary.strict_host_key_checking },
            .local, .plugin => return error.UnsupportedProtocol,
        };
        const source_owner: ?identity.AssetOwner = switch (source.spec) {
            .saved => |saved| .{ .id = saved.connection_id, .revision = saved.config_revision },
            else => null,
        };
        result[hops.len] = try self.option(remote.endpoint, remote.auth, source_owner, remote.strict_host_key_checking, "", hops.len, hops.len + 1, cancelled);
        result[hops.len].keepalive_sec = remote.keepalive_sec;
        result[hops.len].compression = remote.compression;
        return result;
    }
    fn option(self: *Native, endpoint: sessions.Endpoint, auth: sessions.AuthOptions, owner: ?identity.AssetOwner, strict: bool, name: []const u8, index: usize, count: usize, cancelled: *const std.atomic.Value(bool)) !ssh.Options {
        const a = self.arena.allocator();
        const frozen_auth: ssh.Auth = switch (auth) {
            .agent => .agent,
            .password_prompt => .password_prompt,
            .keyboard_interactive => .keyboard_interactive,
            .password => |password| .{ .password = try a.dupeSentinel(u8, password, 0) },
            .private_key => |key| .{ .private_key = .{ .path = try a.dupeSentinel(u8, key.path, 0), .passphrase = if (key.passphrase) |pass| try a.dupeSentinel(u8, pass, 0) else null } },
        };
        return .{
            .host = try a.dupeSentinel(u8, endpoint.host, 0),
            .port = endpoint.port,
            .user = try a.dupeSentinel(u8, endpoint.user, 0),
            .auth = frozen_auth,
            .source_owner = owner,
            .strict_host_key_checking = strict,
            .display_name = name,
            .operation_key = self.source.value.open_key,
            .resource_ledger = &self.ledger,
            .host_key_store = if (self.store) |*store| store else null,
            .host_key_observer = self.policy.host_key_observer,
            .auth_interaction = self.policy.auth_interaction,
            .progress_observer = self.policy.progress_observer,
            .cancel_token = cancelled,
            .attempt_id = self.source.value.open_key.attempt_id orelse 0,
            .hop_index = index,
            .hop_count = count,
            .connect_timeout_ms = self.policy.timeout_ms,
            .open_shell = false,
        };
    }
    /// Target first, then any failed downstream Session retained by the ledger,
    /// then parent relays/tunnels/hops. An uncertain owner is never destroyed.
    fn close(raw: *anyopaque, session: ?*ssh.Session) files.readonly.ReleaseReceipt {
        const self: *Native = @ptrCast(@alignCast(raw));
        if (session) |target| {
            const receipt = target.closeReceipt();
            if (receipt != .released) return receipt;
        }
        const retained = self.ledger.drainRetained();
        if (retained != .released and self.ledger.snapshot().retained_count != 0) return retained;
        if (self.route) |route| {
            const receipt = route.closeReceipt();
            if (receipt != .released) return receipt;
            route.deinit();
            self.route = null;
        }
        return self.ledger.drainRetained();
    }
    fn destroy(raw: *anyopaque) void {
        const self: *Native = @ptrCast(@alignCast(raw));
        std.debug.assert(self.route == null and self.ledger.snapshot().released());
        if (self.store) |*store| store.deinit();
        if (self.io) |*io| io.deinit();
        self.arena.deinit();
        self.source.deinit();
        allocator.destroy(self);
    }
};
