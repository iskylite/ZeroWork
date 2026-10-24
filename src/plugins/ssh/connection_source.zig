//! Provider-owned legacy remote configuration codec. Public dispatch retains
//! an Envelope; only the remote engines interpret endpoint/auth/route fields.
const std = @import("std");
const hosts = @import("../../config/hosts.zig");
const config = @import("../../config/config.zig");
const session = @import("../../host/session_host.zig");
const Snapshot = @import("../../ui/session_lifecycle.zig").Snapshot;
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
        route[index] = hop;
    }
    const source: Source = .{ .host = host, .global_config = global_config, .route_hosts = route[0..host.route.len], .host_id = host_id, .source_index = source_index, .initial_input = input };
    var hops: [8]session.RouteHop = undefined;
    try sourceSpec(source, &hops, "").validate();
    return SourceSnapshot.init(allocator, source);
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
        .immutable_config = .{ .endpoint = endpoint(source.host), .auth = auth(source.host), .totp_secret = source.host.totp_secret, .strict_host_key_checking = source.host.strict_host_key_checking, .terminal_type = if (source.host.terminal_type_explicit) source.host.terminal_type else source.global_config.ssh.term, .startup_commands = source.host.startup_commands, .keepalive_sec = if (source.host.keepalive) source.global_config.ssh.keepalive_sec else 0, .compression = if (source.host.compression_explicit) source.host.compression else source.global_config.ssh.compression },
        .route_snapshot = route,
        .private_options = private_options,
    } };
}
