//! Restricted, owner-frozen plugin controller context. These are explicit
//! capabilities, not an App/root/window pointer or a sandbox boundary.
const std = @import("std");
const identity = @import("identity.zig");
const operation = @import("operation.zig");
const configs = @import("connection_config_resolver.zig");
const transport = @import("transport_factory.zig");
const notifications = @import("notification_host.zig");
const challenges = @import("challenge_host.zig");
const operations = @import("operation_store.zig");
const content = @import("content_context.zig");
const frames = @import("frame_texture_sink.zig");
pub const Preferences = struct {
    context: *anyopaque,
    plugin_id: []const u8,
    read_value: *const fn (*anyopaque, []const u8, []const u8) ?[]const u8,
    /// Borrowed for this synchronous call. Copy values frozen by a controller.
    pub fn read(self: Preferences, key: []const u8) ?[]const u8 {
        return self.read_value(self.context, self.plugin_id, key);
    }
};
pub const Target = struct { window_id: identity.WindowId, workspace_id: identity.WorkspaceId };
pub const Presentation = struct { input: ?*content.Context = null, frame_sink: ?*frames.Sink = null };
pub const Tasks = struct {
    cancel: *const std.atomic.Value(bool),
    operations: ?*operations.Store = null,
    pub fn cancelled(self: Tasks) bool {
        return self.cancel.load(.acquire);
    }
};
pub const AuditEvent = struct { operation_id: u64, code: []const u8, safe_summary: []const u8 };
pub const Audit = struct { context: *anyopaque, record: *const fn (*anyopaque, identity.SessionHandle, AuditEvent) anyerror!void };
pub const Trust = struct {
    /// SSH trust and TLS trust never share key spaces. No TLS implementation is
    /// implied by the presence of the SSH verifier.
    ssh_host_keys: ?*@import("../proto/ssh/connection_policy.zig").HostKeyStore = null,
};
pub const HostContext = struct {
    owner: identity.SessionHandle,
    operation: operation.OperationKey,
    target: Target,
    connection_configs: ?configs.Resolver = null,
    transports: ?transport.Factory = null,
    credentials: ?transport.Credentials = null,
    trust: Trust = .{},
    tasks: ?Tasks = null,
    notifications: ?notifications.Facade = null,
    challenges: ?*challenges.Host = null,
    presentation: Presentation = .{},
    audit: ?Audit = null,
    preferences: ?Preferences = null,
    /// Cloning this value never clones a connection. All runtime transports
    /// are obtained via openOwned for the original owner.
    pub fn requireOwner(self: HostContext, owner: identity.SessionHandle) !void {
        if (!self.owner.eql(owner)) return error.StaleHostContext;
    }
};
pub const Factory = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, identity.SessionHandle, operation.OperationKey, Target) anyerror!HostContext,
};
