//! A proposal for one original authentication request. This never submits a
//! response and never finds credentials through the currently selected asset.
const std = @import("std");
const auth = @import("auth_challenge.zig");
const hosts = @import("../../config/hosts.zig");
const totp = @import("totp.zig");
const realtime = @import("../../platform/realtime.zig");

pub const Time = struct { unix_seconds: u64, monotonic_ns: i128 };
pub const Clock = struct {
    context: ?*anyopaque = null,
    read: *const fn (?*anyopaque) Time = system,
    pub fn now(self: Clock) Time {
        return self.read(self.context);
    }
    fn system(_: ?*anyopaque) Time {
        const ms = realtime.milliseconds(undefined);
        return .{ .unix_seconds = @intCast(@max(0, @divTrunc(ms, std.time.ms_per_s))), .monotonic_ns = realtime.monotonicNs() };
    }
};
pub const Suggestion = struct {
    identity: auth.RequestIdentity,
    code: totp.Code,
    window: u64,
    expires_at_ns: ?i128,
    pub fn validAt(self: Suggestion, time: Time) bool {
        return time.unix_seconds / totp.period_seconds == self.window and
            (if (self.expires_at_ns) |expiry| time.monotonic_ns < expiry else true);
    }
    pub fn deinit(self: *Suggestion) void {
        self.code.deinit();
    }
};

pub fn eligible(snapshot: *const auth.Snapshot) bool {
    if (snapshot.kind != .keyboard_interactive or snapshot.presentation != .otp_modal or snapshot.prompt_count != 1) return false;
    const prompt = snapshot.promptAt(0);
    return prompt.kind == .one_time_code and !prompt.echo and (snapshot.state == .input or snapshot.state == .failed);
}

pub fn suggest(snapshot: *const auth.Snapshot, request: auth.RequestIdentity, frozen_host: hosts.HostConfig, enabled: bool, time: Time) !?Suggestion {
    if (!enabled or !snapshot.identity.eql(request) or !eligible(snapshot)) return null;
    if (snapshot.expires_at_ns) |expiry| if (time.monotonic_ns >= expiry) return null;
    const endpoint = snapshot.endpoint();
    if (endpoint.port != frozen_host.port or !std.mem.eql(u8, endpoint.host, frozen_host.host) or !std.mem.eql(u8, endpoint.user, frozen_host.user)) return null;
    if (snapshot.source_owner) |source| if (@backingInt(frozen_host.connection_id) == 0 or !std.meta.eql(source, frozen_host.owner())) return null;
    const seed = frozen_host.totp_secret orelse return null;
    return .{ .identity = request, .code = try totp.generate(seed, time.unix_seconds), .window = time.unix_seconds / totp.period_seconds, .expires_at_ns = snapshot.expires_at_ns };
}

/// Independent file/SOCKS connections retain this typed create spec. Select
/// credentials by the original hop position, never by current asset names.
pub fn suggestForSpec(snapshot: *const auth.Snapshot, request: auth.RequestIdentity, spec: @import("../../host/session_host.zig").SessionCreateSpec, enabled: bool, time: Time) !?Suggestion {
    const sessions = @import("../../host/session_host.zig");
    const hops = switch (spec) {
        .local, .plugin => return null,
        .saved => |value| value.route_snapshot,
        .temporary_ssh => |value| value.route_snapshot,
    };
    var source_owner: ?@import("../../host/identity.zig").AssetOwner = null;
    const remote: sessions.RemoteConfig = if (request.hop_index < hops.len) blk: {
        const hop = hops[request.hop_index];
        source_owner = hop.owner;
        break :blk .{ .endpoint = hop.endpoint, .totp_secret = hop.totp_secret };
    } else if (request.hop_index == hops.len) switch (spec) {
        .saved => |value| blk: {
            source_owner = .{ .id = value.connection_id, .revision = value.config_revision };
            break :blk value.immutable_config;
        },
        .temporary_ssh => |value| .{ .endpoint = value.structured_endpoint, .totp_secret = value.totp_secret },
        .local, .plugin => return null,
    } else return null;
    return suggest(snapshot, request, .{ .connection_id = if (source_owner) |owner| owner.id else @fromBackingInt(0), .revision = if (source_owner) |owner| owner.revision else 1, .name = remote.endpoint.host, .host = remote.endpoint.host, .user = remote.endpoint.user, .port = remote.endpoint.port, .totp_secret = remote.totp_secret }, enabled, time);
}
