//! Bundled standalone AI session connection. The page owns its conversation
//! rail and inspector; the main window attaches the assistant surface into the
//! published center slot so no runtime is duplicated here.
const std = @import("std");
const registry = @import("../../host/plugin_registry.zig");
const session = @import("../../host/session_host.zig");
const contract = @import("../../host/plugin_ui_contract.zig");
const bridge = @import("../../ui/ai_standalone_bridge.zig");

pub const id = "ai";
pub const payload = "{}";

pub const Plugin = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(session.Accepted) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*Plugin {
        const self = try allocator.create(Plugin);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *Plugin) void {
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn manifest(self: *Plugin) registry.PluginManifest {
        return .{
            .id = id,
            .display_name = "AI Agent",
            .order = 60,
            .icons = .{ .settings = "sparkles", .protocol = "sparkles", .tab = "sparkles" },
            .quick_create = .{ .validate_payload = validate },
            .session_factory = .{ .context = self, .vtable = &factory, .poll = poll },
            .workspace_kind = id,
            .content_renderer = id,
            .workspace_chrome = .{ .show_host_sidebar = false },
            .integration = .{ .ai = false },
        };
    }

    pub fn renderer(self: *Plugin) contract.RendererDefinition {
        return .{ .kind = id, .context = self, .mount = mountContent };
    }

    fn from(raw: *anyopaque) *Plugin {
        return @ptrCast(@alignCast(raw));
    }

    fn validate(value: []const u8) !void {
        if (!std.mem.eql(u8, value, payload)) return error.InvalidAiPayload;
    }

    fn create(raw: *anyopaque, request: session.CreateRequest) !void {
        const self = from(raw);
        if (request.purpose != .interactive or request.spec != .plugin) return error.InvalidAiSession;
        try validate(request.spec.plugin.payload);
        try self.pending.append(self.allocator, .{ .handle = request.handle, .operation = request.key });
    }

    fn poll(raw: *anyopaque, host: *session.SessionHost) !bool {
        const self = from(raw);
        var changed = false;
        while (self.pending.items.len != 0) {
            const attempt = self.pending.items[0];
            changed = (try host.readyPlugin(attempt.handle, attempt.operation, &.{})) or changed;
            self.remove(attempt.operation);
        }
        return changed;
    }

    fn remove(self: *Plugin, key: session.OperationKey) void {
        for (self.pending.items, 0..) |attempt, index| if (attempt.operation.eql(key)) {
            _ = self.pending.orderedRemove(index);
            return;
        };
    }

    fn cancel(raw: *anyopaque, key: session.OperationKey) session.CloseReceipt {
        from(raw).remove(key);
        return .released;
    }

    fn close(_: *anyopaque, _: session.SessionHandle, _: session.OperationKey) !session.CloseReceipt {
        return .released;
    }

    fn stale(raw: *anyopaque, _: session.SessionHandle, key: session.OperationKey) void {
        from(raw).remove(key);
    }

    fn mountContent(raw: ?*anyopaque, request: contract.ContentMount) !contract.RendererInstance {
        _ = from(raw orelse return error.AiUnavailable);
        return @import("view.zig").mount(request);
    }

    const factory: session.Adapter.VTable = .{
        .create = create,
        .cancel = cancel,
        .close = close,
        .release_stale = stale,
    };
};
