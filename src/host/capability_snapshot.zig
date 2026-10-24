//! One projection for menu/status/shortcut and execution gates. Unsupported
//! session actions hide; supported but unavailable actions retain their reason.
const std = @import("std");
const identity = @import("identity.zig");
const services = @import("plugin_services.zig");
pub const ServiceState = struct { key: services.ServiceKey, declared: bool, available: bool, authorized: bool, reason: []const u8 = "", revision: u64 };
pub const Scope = enum { application, session };
pub const Visibility = enum { hide_unsupported, always };
pub const Action = struct { action_id: []const u8, scope: Scope, required_services: []const services.ServiceKey = &.{}, visibility_policy: Visibility = .hide_unsupported };
pub const Projection = struct { visible: bool, enabled: bool, reason: []const u8, revision: u64 };
pub const Snapshot = struct {
    owner: identity.SessionHandle,
    revision: u64,
    services: []const ServiceState,
    closed: bool = false,
    pub fn project(self: Snapshot, action: Action) Projection {
        var result: Projection = .{ .visible = true, .enabled = true, .reason = "", .revision = self.revision };
        if (action.scope == .application) return result;
        for (action.required_services) |key| {
            var found: ?ServiceState = null;
            for (self.services) |service| if (service.key.eql(key)) {
                found = service;
                break;
            };
            if (found == null or !found.?.declared) return .{ .visible = action.visibility_policy == .always, .enabled = false, .reason = "此会话不支持该功能", .revision = self.revision };
            const service = found.?;
            if (!service.available or !service.authorized) {
                result.enabled = false;
                if (result.reason.len == 0) result.reason = if (service.reason.len != 0) service.reason else if (!service.authorized) "未获授权" else "服务暂不可用";
            }
        }
        if (self.closed) return .{ .visible = result.visible, .enabled = false, .reason = "会话已结束", .revision = self.revision };
        return result;
    }
    /// Hidden UI never grants authority. All callers including programmatic
    /// actions pass the observed owner and revision again at dispatch time.
    pub fn validate(self: Snapshot, action: Action, owner: identity.SessionHandle, observed_revision: u64) !void {
        if (!self.owner.eql(owner)) return error.StaleCapabilityOwner;
        if (self.revision != observed_revision) return error.StaleCapabilityRevision;
        const projection = self.project(action);
        if (!projection.enabled) return error.CapabilityUnavailable;
    }
};
pub const CapabilitySnapshot = Snapshot;
test "one snapshot hides unsupported actions and denies stale shortcuts" {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    const states = [_]ServiceState{ .{ .key = .{ .name = "lifecycle" }, .declared = true, .available = true, .authorized = true, .revision = 1 }, .{ .key = .{ .name = "input" }, .declared = true, .available = true, .authorized = false, .reason = "只读", .revision = 2 } };
    const snapshot: Snapshot = .{ .owner = owner, .revision = 2, .services = &states };
    const terminal: Action = .{ .action_id = "terminal.broadcast", .scope = .session, .required_services = &.{.{ .name = "terminal" }} };
    try std.testing.expect(!snapshot.project(terminal).visible);
    var closed_snapshot = snapshot;
    closed_snapshot.closed = true;
    try std.testing.expect(!closed_snapshot.project(terminal).visible);
    try std.testing.expectError(error.CapabilityUnavailable, closed_snapshot.validate(terminal, owner, 2));
    try std.testing.expectError(error.CapabilityUnavailable, snapshot.validate(terminal, owner, 2));
    const input: Action = .{ .action_id = "content.input", .scope = .session, .required_services = &.{.{ .name = "input" }} };
    try std.testing.expect(snapshot.project(input).visible);
    try std.testing.expectEqualStrings("只读", snapshot.project(input).reason);
    try std.testing.expectError(error.StaleCapabilityRevision, snapshot.validate(input, owner, 1));
    const global: Action = .{ .action_id = "transfer.manager", .scope = .application };
    try std.testing.expect(snapshot.project(global).enabled);
}
