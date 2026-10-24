//! Application-owned window identity and request correlation. Native window
//! creation/close is performed by the UI adapter after these requests succeed.
const std = @import("std");
const identity = @import("identity.zig");

pub const Role = enum { workspace, transfer_manager };
pub const Window = struct {
    id: identity.WindowId,
    workspace: ?identity.WorkspaceId,
    role: Role,
    visible: bool = true,
    closing: bool = false,
    close_request: ?u64 = null,
};
pub const Close = struct { window: identity.WindowId, workspace: identity.WorkspaceId, request: u64 };
pub const Create = union(enum) { pending: u64, focus: identity.WindowId };
const Pending = struct { request: u64, role: Role };
pub const Host = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    window_ids: identity.Allocator(identity.WindowId) = .{},
    workspace_ids: identity.Allocator(identity.WorkspaceId) = .{},
    next_request: u64 = 1,

    pub fn deinit(self: *Host) void {
        self.windows.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }
    pub fn requestCreate(self: *Host, role: Role) !Create {
        if (role == .transfer_manager) {
            for (self.windows.items) |*window| if (window.role == role) {
                if (window.closing) return error.WindowClosing;
                window.visible = true;
                return .{ .focus = window.id };
            };
            for (self.pending.items) |pending| if (pending.role == role) return .{ .pending = pending.request };
        }
        if (self.next_request == std.math.maxInt(u64)) return error.IdentityExhausted;
        const request = self.next_request;
        try self.pending.append(self.allocator, .{ .request = request, .role = role });
        self.next_request += 1;
        return .{ .pending = request };
    }
    fn pendingIndex(self: *const Host, request: u64) ?usize {
        for (self.pending.items, 0..) |pending, index| if (pending.request == request) return index;
        return null;
    }
    pub fn ready(self: *Host, request: u64) !Window {
        const index = self.pendingIndex(request) orelse return error.StaleRequest;
        const pending = self.pending.items[index];
        // Reserve memory before consuming identities or removing the request.
        try self.windows.ensureUnusedCapacity(self.allocator, 1);
        var window_ids = self.window_ids;
        var workspace_ids = self.workspace_ids;
        const window: Window = .{
            .id = try window_ids.allocate(),
            .workspace = if (pending.role == .workspace) try workspace_ids.allocate() else null,
            .role = pending.role,
        };
        self.window_ids = window_ids;
        self.workspace_ids = workspace_ids;
        self.windows.appendAssumeCapacity(window);
        _ = self.pending.orderedRemove(index);
        return window;
    }
    pub fn failed(self: *Host, request: u64) !void {
        const index = self.pendingIndex(request) orelse return error.StaleRequest;
        _ = self.pending.orderedRemove(index);
    }
    pub fn find(self: *Host, id: identity.WindowId) ?*Window {
        for (self.windows.items) |*window| if (window.id == id) return window;
        return null;
    }
    /// Tool-window dismissal owns no transfer tasks and never invokes a
    /// workspace close chain. Reopening focuses this same registered instance.
    pub fn dismissTool(self: *Host, id: identity.WindowId) !void {
        const window = self.find(id) orelse return error.WindowClosed;
        if (window.role != .transfer_manager) return error.RequiresWorkspaceClose;
        window.visible = false;
    }
    pub fn beginClose(self: *Host, id: identity.WindowId) !Close {
        const window = self.find(id) orelse return error.WindowClosed;
        const workspace = window.workspace orelse return error.ToolWindowOnly;
        if (window.closing) return error.WindowClosing;
        if (self.next_request == std.math.maxInt(u64)) return error.IdentityExhausted;
        const request = self.next_request;
        self.next_request += 1;
        window.closing = true;
        window.close_request = request;
        return .{ .window = id, .workspace = workspace, .request = request };
    }
    pub fn cancelClose(self: *Host, ticket: Close) !void {
        const window = self.find(ticket.window) orelse return error.WindowClosed;
        if (window.workspace != ticket.workspace or window.close_request != ticket.request) return error.StaleClose;
        window.closing = false;
        window.close_request = null;
    }
    /// Invoke only after every frozen workspace owner acknowledges cleanup.
    pub fn completeClose(self: *Host, ticket: Close) !void {
        for (self.windows.items, 0..) |window, index| {
            if (window.id != ticket.window) continue;
            if (window.workspace != ticket.workspace or window.close_request != ticket.request or !window.closing) return error.StaleClose;
            _ = self.windows.orderedRemove(index);
            return;
        }
        return error.WindowClosed;
    }
};

test "window creation completion belongs to original request and failed request never retargets" {
    var host: Host = .{ .allocator = std.testing.allocator };
    defer host.deinit();
    const a = (try host.requestCreate(.workspace)).pending;
    const b = (try host.requestCreate(.workspace)).pending;
    try host.failed(a);
    try std.testing.expectError(error.StaleRequest, host.ready(a));
    const window = try host.ready(b);
    try std.testing.expect(window.workspace != null);
    try std.testing.expectEqual(@as(usize, 1), host.windows.items.len);
    try std.testing.expectError(error.StaleRequest, host.ready(b));
    const close = try host.beginClose(window.id);
    var wrong = close;
    wrong.workspace = @fromBackingInt(99);
    try std.testing.expectError(error.StaleClose, host.completeClose(wrong));
    try host.cancelClose(close);
    try std.testing.expectError(error.StaleClose, host.completeClose(close));
    const retry = try host.beginClose(window.id);
    try std.testing.expectError(error.StaleClose, host.completeClose(close));
    try host.completeClose(retry);
    const next = try host.ready((try host.requestCreate(.workspace)).pending);
    try std.testing.expect(next.id != window.id);
    try std.testing.expect(next.workspace != window.workspace);
}

test "transfer manager creation is coalesced and dismissal preserves application window identity" {
    var host: Host = .{ .allocator = std.testing.allocator };
    defer host.deinit();
    const first = (try host.requestCreate(.transfer_manager)).pending;
    try std.testing.expectEqual(first, (try host.requestCreate(.transfer_manager)).pending);
    const tool = try host.ready(first);
    const workspace = try host.ready((try host.requestCreate(.workspace)).pending);
    try std.testing.expect(tool.workspace == null);
    try std.testing.expectError(error.ToolWindowOnly, host.beginClose(tool.id));
    try std.testing.expectError(error.RequiresWorkspaceClose, host.dismissTool(workspace.id));
    try host.dismissTool(tool.id);
    try std.testing.expect(!host.find(tool.id).?.visible);
    try std.testing.expectEqual(tool.id, (try host.requestCreate(.transfer_manager)).focus);
    try std.testing.expect(host.find(tool.id).?.visible);
    try std.testing.expect(host.find(workspace.id) != null);
}
