//! Window-owned content facades. The workspace receives a factory; renderers
//! see only their owner's input/window context and frame sink.
const std = @import("std");
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const content = @import("../host/content_context.zig");
const frames = @import("../host/frame_texture_sink.zig");
const contract = @import("../host/plugin_ui_contract.zig");
const Entry = struct { input: content.Context, frames: frames.Sink, retired: bool = false };
pub const Host = struct {
    cx: *ui.Cx,
    window_id: identity.WindowId,
    window: content.WindowFacade,
    backend: frames.Backend,
    entries: std.ArrayList(*Entry) = .empty,
    closed: bool = false,
    /// Construct on the window main thread. Supply backendFor(app.sharedImageStore())
    /// and callbacks bound to the native window; plugins never receive either.
    pub fn init(cx: *ui.Cx, window_id: identity.WindowId, window: content.WindowFacade, backend: frames.Backend) !*Host {
        return cx.bindState(Host, .{ .cx = cx, .window_id = window_id, .window = window, .backend = backend });
    }
    pub fn deinit(self: *Host) void {
        for (self.entries.items) |entry| {
            entry.input.close();
            entry.frames.close() catch {};
            self.cx.allocator.destroy(entry);
        }
        self.entries.deinit(self.cx.allocator);
        self.closed = true;
    }
    pub fn factory(self: *Host) contract.ContentServicesFactory {
        return .{ .context = self, .create = create };
    }
    fn create(ptr: *anyopaque, owner: identity.SessionHandle) !contract.ContentServices {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.ContentHostClosed;
        for (self.entries.items) |entry| if (!entry.retired and entry.input.owner.eql(owner)) return .{ .content_context = &entry.input, .frame_sink = &entry.frames };
        if (self.entries.items.len == 128) return error.ContentOwnerLimit;
        const entry = try self.cx.allocator.create(Entry);
        errdefer self.cx.allocator.destroy(entry);
        entry.* = .{ .input = .{ .owner = owner, .window_id = self.window_id, .window = self.window, .consumer = .{ .context = self, .consume = unavailable } }, .frames = frames.Sink.init(owner, self.backend) };
        try entry.input.ensureIdentity();
        try self.entries.append(self.cx.allocator, entry);
        return .{ .content_context = &entry.input, .frame_sink = &entry.frames };
    }
    fn unavailable(_: *anyopaque, _: content.Input) !void {
        return error.InputConsumerUnavailable;
    }
    /// Host authority controls input; renderer registration alone never grants it.
    pub fn authorize(self: *Host, owner: identity.SessionHandle, allowed: bool, revision: u64) !void {
        for (self.entries.items) |entry| if (!entry.retired and entry.input.owner.eql(owner)) {
            try entry.input.setAuthorization(allowed, revision);
            return;
        };
        return error.UnknownContentOwner;
    }
    /// Invoke from the existing window frame pump after global input routing.
    /// content_focused must be false when the AI panel/challenge owns focus.
    pub fn tick(self: *Host, window_focused: bool, active_owner: ?identity.SessionHandle, content_focused: bool) !void {
        for (self.entries.items) |entry| {
            if (entry.retired) continue;
            const active = if (active_owner) |owner| owner.eql(entry.input.owner) else false;
            entry.input.setFocus(window_focused and active, content_focused and active);
            if (try entry.frames.drain()) self.cx.requestRedraw();
        }
    }
    /// Call after renderer unmount and producer join. Teardown never leaves a
    /// GPU texture or input lease attached to a discarded owner.
    pub fn release(self: *Host, owner: identity.SessionHandle) !void {
        for (self.entries.items) |entry| if (!entry.retired and entry.input.owner.eql(owner)) {
            entry.input.close();
            try entry.frames.close();
            // Tombstones keep old facade references valid until their Cx dies.
            entry.retired = true;
            return;
        };
    }
};
