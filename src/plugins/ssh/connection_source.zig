//! Provider-owned legacy remote configuration codec. Public dispatch retains
//! an Envelope; only the remote engines interpret endpoint/auth/route fields.
const std = @import("std");
const hosts = @import("../../config/hosts.zig");
const config = @import("../../config/config.zig");
const session = @import("../../host/session_host.zig");
const Snapshot = @import("../../ui/session_lifecycle.zig").Snapshot;
const credentials = @import("../../config/credential_store.zig");

/// Envelopes deliberately contain references rather than plaintext. Resolve
/// them only at this provider-owned boundary, before freezing engine/UI input.
pub const CredentialReader = struct {
    allocator: std.mem.Allocator,
    loaded: std.ArrayList([]u8) = .empty,

    pub fn resolve(self: *CredentialReader, host: hosts.HostConfig) !hosts.HostConfig {
        var result = host;
        inline for (.{ .{ "password", "password_ref" }, .{ "key_passphrase", "key_passphrase_ref" }, .{ "totp_secret", "totp_secret_ref" } }) |fields| {
            if (@field(result, fields[0]) == null) if (@field(result, fields[1])) |reference| {
                const secret = try credentials.get(self.allocator, reference);
                errdefer {
                    std.crypto.secureZero(u8, secret);
                    self.allocator.free(secret);
                }
                try self.loaded.append(self.allocator, secret);
                @field(result, fields[0]) = secret;
            };
        }
        return result;
    }

    pub fn deinit(self: *CredentialReader) void {
        for (self.loaded.items) |secret| {
            std.crypto.secureZero(u8, secret);
            self.allocator.free(secret);
        }
        self.loaded.deinit(self.allocator);
    }
};
pub const Source = struct {
    host: hosts.HostConfig,
    global_config: config.Config,
    route_hosts: []const hosts.HostConfig,
    host_id: u64,
    source_index: usize,
    initial_input: []const u8,
};
pub const SourceSnapshot = Snapshot(Source);
pub const FileSource = Source;
pub const WindowConnection = SourceSnapshot;
/// Optional provider-private engine snapshot for the common new-window path.
/// Generic envelopes never enter the legacy remote configuration decoder.
pub fn freezeWindowSource(allocator: std.mem.Allocator, host: hosts.HostConfig, global_config: config.Config, registry: []const hosts.HostConfig, host_id: u64, source_index: usize) !?SourceSnapshot {
    if (!host.isLegacy()) return null;
    return try freezeSource(allocator, host, global_config, registry, host_id, source_index, "");
}
pub fn freezeSource(allocator: std.mem.Allocator, host: hosts.HostConfig, global_config: config.Config, registry: []const hosts.HostConfig, host_id: u64, source_index: usize, input: []const u8) !SourceSnapshot {
    try host.validate();
    if (!host.isLegacy()) return error.UnsupportedProtocol;
    if (host.route.len == 0 and host.jump_chain.len != 0) return error.UnmigratedRoute;
    if (@backingInt(host.connection_id) == 0 and host.protocol != .ssh) return error.InvalidTemporaryProtocol;
    var route: [8]hosts.HostConfig = undefined;
    var reader: CredentialReader = .{ .allocator = allocator };
    defer reader.deinit();
    for (host.route, 0..) |id, index| {
        if (@backingInt(id) == 0) return error.InvalidIdentity;
        if (id == host.connection_id) return error.RouteCycle;
        for (host.route[0..index]) |previous| if (previous == id) return error.DuplicateRoute;
        var matched: ?hosts.HostConfig = null;
        for (registry) |candidate| {
            if (candidate.connection_id != id) continue;
            if (matched != null) return error.DuplicateConnectionId;
            matched = candidate;
        }
        const hop = matched orelse return error.MissingRouteReference;
        try hop.validate();
        if (!std.mem.eql(u8, hop.protocolId(), "ssh")) return error.InvalidRouteProtocol;
        if (hop.route.len != 0 or hop.jump_chain.len != 0) return error.NestedRouteUnsupported;
        route[index] = try reader.resolve(hop);
    }
    const source: Source = .{ .host = try reader.resolve(host), .global_config = global_config, .route_hosts = route[0..host.route.len], .host_id = host_id, .source_index = source_index, .initial_input = input };
    var hops: [8]session.RouteHop = undefined;
    try sourceSpec(source, &hops, "").validate();
    return SourceSnapshot.init(allocator, source);
}

test "remote saved credentials rehydrate reference-only envelopes before another connection" {
    const a = std.testing.allocator;
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    const reference = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const backend = memory.backend();
    try backend.add(backend.context, try credentials.scopeService(), reference, "fixture-saved-password");
    const original: hosts.HostConfig = .{ .connection_id = @fromBackingInt(1), .name = "saved", .host = "fixture.invalid", .user = "fixture", .auth_mode = .password, .password_ref = reference };
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const envelopes = @import("../../config/connection_envelope.zig");
    const envelope = try envelopes.fromLegacy(arena.allocator(), original);
    try std.testing.expect(std.mem.indexOf(u8, envelope.payload, "fixture-saved-password") == null);
    const decoded = try envelopes.decodeLegacy(arena.allocator(), envelope);
    try std.testing.expect(decoded.password == null);
    for (0..2) |_| {
        var source = try freezeSource(a, decoded, .{}, &.{}, 1, 0, "");
        defer source.deinit();
        var route: [8]session.RouteHop = undefined;
        const spec = sourceSpec(source.value, &route, "");
        try std.testing.expectEqualStrings("fixture-saved-password", spec.saved.immutable_config.auth.password);
    }
    var reader: CredentialReader = .{ .allocator = a };
    defer reader.deinit();
    const editable = try reader.resolve(decoded);
    try std.testing.expectEqualStrings("fixture-saved-password", editable.password.?);
    memory.denied = true;
    try std.testing.expectError(error.CredentialDenied, freezeSource(a, decoded, .{}, &.{}, 1, 0, ""));
}

pub fn auth(host: hosts.HostConfig) session.AuthOptions {
    return switch (host.auth_mode) {
        .agent => .agent,
        .private_key => .{ .private_key = .{ .path = host.identity_file orelse "", .passphrase = host.key_passphrase } },
        .password => if (host.password) |value| .{ .password = value } else .password_prompt,
    };
}

fn endpoint(host: hosts.HostConfig) session.Endpoint {
    return .{ .host = host.host, .port = host.port, .user = host.user };
}

pub fn sourceSpec(source: Source, route_buffer: *[8]session.RouteHop, private_options: []const u8) session.SessionCreateSpec {
    for (source.route_hosts, 0..) |host, index| route_buffer[index] = .{
        .owner = host.owner(),
        .display_name = host.name,
        .protocol = if (host.protocol == .ssh) .ssh else .sftp,
        .endpoint = endpoint(host),
        .auth = auth(host),
        .totp_secret = host.totp_secret,
        .strict_host_key_checking = host.strict_host_key_checking,
    };
    const route = route_buffer[0..source.route_hosts.len];
    if (@backingInt(source.host.connection_id) == 0) return .{ .temporary_ssh = .{ .structured_endpoint = endpoint(source.host), .auth_options = auth(source.host), .totp_secret = source.host.totp_secret, .strict_host_key_checking = source.host.strict_host_key_checking, .route_snapshot = route } };
    return .{ .saved = .{
        .connection_id = source.host.connection_id,
        .config_revision = source.host.revision,
        .protocol = if (source.host.protocol == .ssh) .ssh else .sftp,
        .immutable_config = .{ .endpoint = endpoint(source.host), .auth = auth(source.host), .totp_secret = source.host.totp_secret, .strict_host_key_checking = source.host.strict_host_key_checking, .terminal_type = if (source.host.terminal_type_explicit) source.host.terminal_type else source.global_config.ssh.term, .startup_commands = source.host.startup_commands, .auto_shell_integration = source.host.auto_shell_integration orelse source.global_config.ssh.auto_shell_integration, .keepalive_sec = if (source.host.keepalive) source.global_config.ssh.keepalive_sec else 0, .compression = if (source.host.compression_explicit) source.host.compression else source.global_config.ssh.compression },
        .route_snapshot = route,
        .private_options = private_options,
    } };
}
