//! Bundled, local content. The host owns window attachment and session identity.
const std = @import("std");
const registry = @import("../../host/plugin_registry.zig");
const session = @import("../../host/session_host.zig");
const contract = @import("../../host/plugin_ui_contract.zig");
const Store = @import("store.zig").Store;
const Documents = @import("document_sessions.zig").Sessions;

pub const id = "notes";
pub const payload = "{}";

pub const Plugin = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data: std.Io.Dir,
    store: ?Store = null,
    documents: ?Documents = null,
    pending: std.ArrayList(session.Accepted) = .empty,

    pub fn deinit(self: *Plugin) void {
        if (self.documents) |*documents| documents.deinit();
        if (self.store) |*store| store.deinit();
        self.pending.deinit(self.allocator);
    }

    pub fn openStore(self: *Plugin) !*Store {
        if (self.store == null) self.store = try Store.init(self.allocator, self.io, self.data);
        return &self.store.?;
    }

    pub fn documentSessions(self: *Plugin) !*Documents {
        const store = try self.openStore();
        if (self.documents == null) self.documents = Documents.init(self.allocator, store);
        return &self.documents.?;
    }

    pub fn manifest(self: *Plugin) registry.PluginManifest {
        return .{
            .id = id,
            .display_name = "笔记",
            .order = 25,
            .icons = .{ .settings = "notebook", .protocol = "notebook", .tab = "notebook" },
            .quick_create = .{ .validate_payload = validate },
            .session_factory = .{ .context = self, .vtable = &factory, .poll = poll },
            .workspace_kind = id,
            .content_renderer = id,
        };
    }

    pub fn renderer(self: *Plugin) contract.RendererDefinition {
        return .{ .kind = id, .context = self, .mount = mount };
    }

    fn from(raw: *anyopaque) *Plugin {
        return @ptrCast(@alignCast(raw));
    }

    fn validate(value: []const u8) !void {
        if (!std.mem.eql(u8, value, payload)) return error.InvalidNotesPayload;
    }

    fn create(raw: *anyopaque, request: session.CreateRequest) !void {
        const self = from(raw);
        if (request.purpose != .interactive or request.spec != .plugin) return error.InvalidNotesSession;
        try validate(request.spec.plugin.payload);
        _ = try self.documentSessions();
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

    fn mount(raw: ?*anyopaque, request: contract.ContentMount) !contract.RendererInstance {
        const self = from(raw orelse return error.NotesUnavailable);
        const documents = try self.documentSessions();
        return @import("view.zig").mount(request, &self.store.?, documents);
    }

    const factory: session.Adapter.VTable = .{
        .create = create,
        .cancel = cancel,
        .close = close,
        .release_stale = stale,
    };
};
