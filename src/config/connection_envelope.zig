//! Public, provider-owned connection storage. Payload bytes are opaque to the host.
const std = @import("std");
const hosts = @import("hosts.zig");
pub const identity = hosts.identity;
pub const Envelope = struct {
    id: identity.ConnectionId = @fromBackingInt(0),
    protocol_id: []const u8,
    revision: u64 = 1,
    name: []const u8,
    group_id: ?identity.AssetGroupId = null,
    payload_version: u32 = 1,
    payload: []const u8,

    pub fn validate(self: Envelope) !void {
        if (self.protocol_id.len == 0 or self.payload_version == 0 or self.revision == 0) return error.InvalidEnvelope;
        if (std.mem.trim(u8, self.name, " \t\r\n").len == 0) return error.MissingName;
        if (!std.unicode.utf8ValidateSlice(self.name) or std.mem.indexOfAny(u8, self.name, "\x00\r\n") != null) return error.InvalidEnvelope;
        if (std.mem.indexOfAny(u8, self.protocol_id, "\x00 \t\r\n") != null) return error.InvalidEnvelope;
    }
    /// Allocate into the caller's owned arena/transaction.
    pub fn clone(self: Envelope, allocator: std.mem.Allocator) !Envelope {
        var result = self;
        result.protocol_id = try allocator.dupe(u8, self.protocol_id);
        result.name = try allocator.dupe(u8, self.name);
        result.payload = try allocator.dupe(u8, self.payload);
        return result;
    }
};
pub const ConnectionEnvelope = Envelope;

/// Compatibility codec only. Existing plaintext credentials stay in the legacy
/// record; the public payload contains no literal login secrets.
pub fn fromLegacy(allocator: std.mem.Allocator, host: hosts.HostConfig) !Envelope {
    var value = host;
    value.asset_group_id = null;
    value.group = null;
    value.password = null;
    value.key_passphrase = null;
    value.totp_secret = null;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    if (host.isLegacy()) try hosts.Registry.formatOne(value, &writer.writer);
    return .{ .id = host.connection_id, .revision = host.revision, .name = try allocator.dupe(u8, host.name), .group_id = host.asset_group_id, .protocol_id = try allocator.dupe(u8, host.protocolId()), .payload_version = host.payload_version, .payload = try allocator.dupe(u8, host.plugin_payload orelse writer.written()) };
}

/// Saving a temporary SSH/SFTP target copies configuration, never its one-use
/// credentials or runtime references. The original frozen session is untouched.
pub fn fromTemporaryHost(allocator: std.mem.Allocator, host: hosts.HostConfig) !Envelope {
    if (@backingInt(host.connection_id) != 0) return error.ConnectionAlreadySaved;
    if (!host.isLegacy()) return error.UnsupportedProtocol;
    var value = host;
    value.password_ref = null;
    value.key_passphrase_ref = null;
    value.totp_secret_ref = null;
    value.plugin_payload = null;
    return fromLegacy(allocator, value);
}

pub fn decodeLegacy(allocator: std.mem.Allocator, envelope: Envelope) !hosts.HostConfig {
    try envelope.validate();
    if (!std.mem.eql(u8, envelope.protocol_id, "ssh") and !std.mem.eql(u8, envelope.protocol_id, "sftp")) return error.UnsupportedProtocol;
    if (envelope.payload_version != 1) return error.UnsupportedPayloadVersion;
    var registry = try hosts.Registry.parse(allocator, envelope.payload);
    defer registry.deinit();
    if (registry.hosts.len != 1) return error.InvalidPayload;
    var result = try hosts.cloneConfig(allocator, registry.hosts[0]);
    if (!std.mem.eql(u8, result.protocolId(), envelope.protocol_id)) return error.ProtocolMismatch;
    result.connection_id = envelope.id;
    result.revision = envelope.revision;
    result.name = try allocator.dupe(u8, envelope.name);
    result.asset_group_id = envelope.group_id;
    return result;
}

/// One-version migration is explicit and idempotent; unknown future data is
/// never decoded or overwritten by defaults.
pub fn migrate(allocator: std.mem.Allocator, envelope: Envelope) !Envelope {
    try envelope.validate();
    if (envelope.payload_version > 1) return error.UnsupportedPayloadVersion;
    return envelope.clone(allocator);
}

test "legacy codec strips secrets, preserves fields and refuses unknown provider/version" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: hosts.HostConfig = .{ .name = "offline", .host = "offline.invalid", .user = "u", .auth_mode = .password, .password = "sensitive", .compression = true, .unknown_fields = &.{"future_field = [1, 2]"} };
    const envelope = try fromLegacy(a, original);
    try std.testing.expect(std.mem.indexOf(u8, envelope.payload, "sensitive") == null);
    const decoded = try decodeLegacy(a, envelope);
    try std.testing.expect(decoded.compression);
    try std.testing.expectEqualStrings("future_field = [1, 2]", decoded.unknown_fields[0]);
    var unknown = envelope;
    unknown.protocol_id = "future.protocol";
    try std.testing.expectError(error.UnsupportedProtocol, decodeLegacy(a, unknown));
    unknown = envelope;
    unknown.payload_version = 2;
    try std.testing.expectError(error.UnsupportedPayloadVersion, decodeLegacy(a, unknown));
}

test "temporary connection draft preserves SSH and SFTP settings without secrets or references" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]hosts.Protocol{ .ssh, .sftp }) |protocol| {
        const original: hosts.HostConfig = .{
            .protocol = protocol,
            .name = "frozen temporary target",
            .host = "frozen.example",
            .port = 2222,
            .user = "operator",
            .auth_mode = .password,
            .password = "one-use-password",
            .password_ref = "one-use-password-reference",
            .totp_secret = "JBSWY3DPEHPK3PXP",
            .totp_secret_ref = "one-use-totp-reference",
            .plugin_payload = "stale-runtime-payload",
            .strict_host_key_checking = false,
            .compression = true,
            .keepalive = false,
            .terminal_type = "screen-256color",
            .scrollback = 1234,
            .route = &.{@fromBackingInt(41)},
            .startup_commands = &.{"cd /srv"},
        };
        const envelope = try fromTemporaryHost(allocator, original);
        const decoded = try decodeLegacy(allocator, envelope);
        try std.testing.expectEqual(@as(u64, 0), @backingInt(envelope.id));
        try std.testing.expectEqualStrings(@tagName(protocol), envelope.protocol_id);
        try std.testing.expectEqualStrings(original.name, decoded.name);
        try std.testing.expectEqualStrings(original.host, decoded.host);
        try std.testing.expectEqual(original.port, decoded.port);
        try std.testing.expectEqualStrings(original.user, decoded.user);
        try std.testing.expectEqual(original.auth_mode, decoded.auth_mode);
        try std.testing.expectEqual(original.strict_host_key_checking, decoded.strict_host_key_checking);
        try std.testing.expect(decoded.compression and !decoded.keepalive);
        try std.testing.expectEqualStrings(original.terminal_type, decoded.terminal_type);
        try std.testing.expectEqual(original.scrollback, decoded.scrollback);
        try std.testing.expectEqualSlices(identity.ConnectionId, original.route, decoded.route);
        try std.testing.expectEqualStrings(original.startup_commands[0], decoded.startup_commands[0]);
        try std.testing.expect(decoded.password == null and decoded.password_ref == null);
        try std.testing.expect(decoded.totp_secret == null and decoded.totp_secret_ref == null);
        try std.testing.expect(std.mem.indexOf(u8, envelope.payload, "one-use") == null);
        try std.testing.expect(std.mem.indexOf(u8, envelope.payload, "stale-runtime") == null);
        try std.testing.expectEqualStrings("one-use-password", original.password.?);
        try std.testing.expectEqualStrings("one-use-password-reference", original.password_ref.?);
    }
    var key: hosts.HostConfig = .{ .name = "key target", .host = "key.example", .user = "operator", .auth_mode = .private_key, .identity_file = "/tmp/id_ed25519", .key_passphrase = "one-use-passphrase", .key_passphrase_ref = "one-use-key-reference" };
    const decoded = try decodeLegacy(allocator, try fromTemporaryHost(allocator, key));
    try std.testing.expectEqualStrings(key.identity_file.?, decoded.identity_file.?);
    try std.testing.expect(decoded.key_passphrase == null and decoded.key_passphrase_ref == null);
    try std.testing.expectEqualStrings("one-use-passphrase", key.key_passphrase.?);
    key.connection_id = @fromBackingInt(9);
    try std.testing.expectError(error.ConnectionAlreadySaved, fromTemporaryHost(allocator, key));
    key.connection_id = @fromBackingInt(0);
    key.protocol_id = "local";
    try std.testing.expectError(error.UnsupportedProtocol, fromTemporaryHost(allocator, key));
}

/// AssetStore compatibility carrier for generic providers. Only the codec
/// understands the legacy HostConfig shape; public consumers use protocolId.
pub fn toHostConfig(allocator: std.mem.Allocator, envelope: Envelope) !hosts.HostConfig {
    try envelope.validate();
    if (std.mem.eql(u8, envelope.protocol_id, "ssh") or std.mem.eql(u8, envelope.protocol_id, "sftp")) return decodeLegacy(allocator, envelope);
    return .{ .connection_id = envelope.id, .revision = envelope.revision, .name = try allocator.dupe(u8, envelope.name), .asset_group_id = envelope.group_id, .host = "", .user = "", .protocol_id = try allocator.dupe(u8, envelope.protocol_id), .payload_version = envelope.payload_version, .plugin_payload = try allocator.dupe(u8, envelope.payload) };
}

pub const toRecord = toHostConfig;
