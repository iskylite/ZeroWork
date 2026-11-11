//! Window-owned content facades. The workspace receives a factory; renderers
//! see only their owner's input/window context and frame sink.
const std = @import("std");
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const content = @import("../host/content_context.zig");
const frames = @import("../host/frame_texture_sink.zig");
const contract = @import("../host/plugin_ui_contract.zig");
const sessions = @import("../host/session_host.zig");
const Entry = struct { input: content.Context, frames: frames.Sink, retired: bool = false };
pub const Host = struct {
    cx: *ui.Cx,
    window_id: identity.WindowId,
    window: content.WindowFacade,
    backend: frames.Backend,
    entries: std.ArrayList(*Entry) = .empty,
    closed: bool = false,
    sessions: ?*sessions.SessionHost = null,
    web_services: ?contract.ContentServicesFactory = null,
    frame_budget: ?*frames.Budget = null,
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
    pub fn setSessionHost(self: *Host, host: *sessions.SessionHost) void {
        self.sessions = host;
    }
    pub fn setFrameBudget(self: *Host, budget: *frames.Budget) void {
        self.frame_budget = budget;
    }
    fn create(ptr: *anyopaque, owner: identity.SessionHandle) !contract.ContentServices {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.ContentHostClosed;
        if (self.sessions) |host| if (!host.allowsContent(owner)) return error.ContentPresentationForbidden;
        const service_access = if (self.sessions) |host| try host.serviceAccess(owner) else null;
        var result = if (self.web_services) |provider| try provider.create(provider.context, owner) else contract.ContentServices{};
        result.service_access = service_access;
        for (self.entries.items) |entry| if (!entry.retired and entry.input.owner.eql(owner)) {
            result.content_context = &entry.input;
            result.frame_sink = &entry.frames;
            return result;
        };
        if (self.entries.items.len == 128) return error.ContentOwnerLimit;
        const limits = if (self.sessions) |host| if (host.manifestFor(owner)) |manifest| manifest.frame_limits else null else null;
        const sink = if (limits) |declared|
            frames.Sink.initWithBudget(owner, self.backend, self.frame_budget orelse return error.FrameBudgetUnavailable, declared)
        else
            frames.Sink.init(owner, self.backend);
        const entry = try self.cx.allocator.create(Entry);
        errdefer self.cx.allocator.destroy(entry);
        entry.* = .{ .input = .{ .owner = owner, .window_id = self.window_id, .window = self.window, .consumer = .{ .context = self, .consume = unavailable } }, .frames = sink };
        try entry.input.ensureIdentity();
        try self.entries.append(self.cx.allocator, entry);
        result.content_context = &entry.input;
        result.frame_sink = &entry.frames;
        return result;
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
    /// Generic typed input bridge. The caller has already validated approval,
    /// owner and policy; it receives the actual mutually exclusive lease.
    pub fn acquireAutomation(self: *Host, owner: identity.SessionHandle, revision: u64, cancel: ?*const std.atomic.Value(bool), stopped: ?*const std.atomic.Value(bool), expires_at_ms: u64) !content.AutomationGrant {
        if (self.closed) return error.ContentHostClosed;
        for (self.entries.items) |entry| if (!entry.retired and entry.input.owner.eql(owner)) {
            // Never revoke human authority in order to manufacture an AI grant.
            if (entry.input.human != null) return error.HumanInputActive;
            entry.input.expireAutomation();
            while (entry.input.drainRevocation() != null) {}
            try entry.input.setAuthorization(true, revision);
            return entry.input.acquireAutomation(revision, cancel, stopped, expires_at_ms);
        };
        return error.UnknownContentOwner;
    }
    /// Synchronize native focus before lease acquisition as well as frame polling.
    /// content_focused must be false when the AI panel/challenge owns focus.
    pub fn syncFocus(self: *Host, window_focused: bool, active_owner: ?identity.SessionHandle, content_focused: bool) void {
        for (self.entries.items) |entry| {
            if (entry.retired) continue;
            const active = if (active_owner) |owner| owner.eql(entry.input.owner) else false;
            entry.input.setFocus(window_focused and active, content_focused and active);
            entry.input.expireAutomation();
        }
    }
    /// Invoke from the existing window frame pump after global input routing.
    pub fn tick(self: *Host, window_focused: bool, active_owner: ?identity.SessionHandle, content_focused: bool) !void {
        self.syncFocus(window_focused, active_owner, content_focused);
        for (self.entries.items) |entry| {
            if (entry.retired) continue;
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
