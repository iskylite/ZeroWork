//! Persisted BMC input only. Runtime credentials, tokens and resolved routes do
//! not belong to this schema. Parsing is strict so secret-shaped extra fields
//! cannot survive an encode/decode round trip.
const std = @import("std");
const resolver = @import("../../host/connection_config_resolver.zig");
const identity = @import("../../host/identity.zig");

pub const protocol_id = "bmc_ikvm";
pub const workspace_kind = "bmc_ikvm.kvm";
pub const payload_version: u32 = 1;
pub const max_payload_bytes = 16 * 1024;
pub const Hop = struct { asset_id: u64 };
pub const Access = union(enum) { direct, ssh_route: struct { hops: []const Hop } };
pub const Scale = enum { fit, original };
pub const Endpoint = struct { host: []const u8, https_port: u16 = 443 };
pub const Payload = struct {
    endpoint: Endpoint,
    username: []const u8,
    credential_ref: ?[]const u8 = null,
    access: Access = .direct,
    display: struct { scale: Scale = .fit, read_only_requested: bool = false } = .{},
};

pub fn validCredentialReference(reference: []const u8) bool {
    if (reference.len != 68 or !std.mem.startsWith(u8, reference, "zw1_")) return false;
    for (reference[4..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn validate(value: Payload) !void {
    const host = value.endpoint.host;
    if (host.len == 0 or host.len > 253 or value.endpoint.https_port == 0 or
        !std.unicode.utf8ValidateSlice(host) or std.mem.indexOfAny(u8, host, " \t\r\n\x00/\\?#@%") != null) return error.InvalidEndpoint;
    // Bracketed IPv6 is accepted, arbitrary colon-bearing names are not.
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        const bare = if (host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
        _ = std.Io.net.IpAddress.parse(bare, value.endpoint.https_port) catch return error.InvalidEndpoint;
    } else {
        const dns = std.mem.trimEnd(u8, host, ".");
        if (dns.len == 0) return error.InvalidEndpoint;
        var labels = std.mem.splitScalar(u8, dns, '.');
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63 or !std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) return error.InvalidEndpoint;
            for (label) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidEndpoint;
        }
    }
    if (std.mem.trim(u8, value.username, " \t").len == 0 or value.username.len > 256 or !std.unicode.utf8ValidateSlice(value.username) or std.mem.indexOfAny(u8, value.username, "\x00\r\n") != null) return error.InvalidUsername;
    if (value.credential_ref) |reference| if (!validCredentialReference(reference)) return error.InvalidCredentialReference;
    switch (value.access) {
        .direct => {},
        .ssh_route => |route| {
            if (route.hops.len == 0) return error.MissingSshReference;
            if (route.hops.len > 8) return error.TooManyJumps;
            for (route.hops, 0..) |hop, i| {
                if (hop.asset_id == 0) return error.InvalidSshReference;
                for (route.hops[0..i]) |previous| if (previous.asset_id == hop.asset_id) return error.DuplicateRoute;
            }
        },
    }
}

pub const ParsedPayload = struct {
    parsed: std.json.Parsed(Payload),
    pub fn deinit(self: *ParsedPayload) void {
        self.parsed.deinit();
        self.* = undefined;
    }
    pub fn value(self: *const ParsedPayload) Payload {
        return self.parsed.value;
    }
};
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !ParsedPayload {
    if (bytes.len > max_payload_bytes) return error.PayloadTooLarge;
    const parsed = try std.json.parseFromSlice(Payload, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return .{ .parsed = parsed };
}
pub fn validatePayload(bytes: []const u8) !void {
    var parsed = try parse(std.heap.page_allocator, bytes);
    defer parsed.deinit();
}
pub fn freezeRoute(value: Payload, configs: resolver.Resolver, a: std.mem.Allocator) !resolver.FrozenRoute {
    try validate(value);
    var ids: [8]identity.ConnectionId = undefined;
    const hops = switch (value.access) {
        .direct => &.{},
        .ssh_route => |route| route.hops,
    };
    for (hops, 0..) |hop, i| ids[i] = @fromBackingInt(hop.asset_id);
    return configs.freezeRoute(ids[0..hops.len], a);
}
