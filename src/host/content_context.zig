//! Restricted content input/window facade. Host dispatches overlays/challenges
//! and reserved shortcuts before calling route; the renderer never receives App.
const std = @import("std");
const identity = @import("identity.zig");
pub const LeaseKind = enum { human_focus, automation };
pub const RevokeReason = enum { released, owner_changed, lost_focus, owner_closed, permission_changed, takeover, window_transfer };
var next_context_instance: std.atomic.Value(u64) = .init(1);
pub const TransferState = union(enum) { idle, pending: identity.WindowId, completed: identity.WindowId, failed: anyerror };
pub const Lease = struct { context_instance: u64, window_id: identity.WindowId, id: u64, owner: identity.SessionHandle, kind: LeaseKind, authorization_revision: u64 };
pub const Revocation = struct { lease: Lease, reason: RevokeReason };
pub const Input = union(enum) {
    key: struct { code: u32, down: bool, modifiers: u16 = 0 },
    text: []const u8,
    pointer: struct { x: f32, y: f32, buttons: u8, wheel_x: f32 = 0, wheel_y: f32 = 0 },
    release_all,
};
pub const Consumer = struct { context: *anyopaque, consume: *const fn (*anyopaque, Input) anyerror!void };
pub const WindowFacade = struct {
    context: *anyopaque,
    request_fullscreen: *const fn (*anyopaque, bool) anyerror!void,
    fullscreen_state: *const fn (*anyopaque) bool,
    transfer: *const fn (*anyopaque, identity.SessionHandle, identity.WindowId) anyerror!void,
    destinations: ?*const fn (*anyopaque, identity.SessionHandle, []identity.WindowId) usize = null,
};
pub const Context = struct {
    owner: identity.SessionHandle,
    window_id: identity.WindowId,
    window: WindowFacade,
    consumer: Consumer,
    focused: bool = false,
    content_focused: bool = false,
    closed: bool = false,
    authorized: bool = false,
    authorization_revision: u64 = 1,
    human: ?Lease = null,
    automation: ?Lease = null,
    next_lease: u64 = 1,
    context_instance: u64 = 0,
    transfer_state: TransferState = .idle,
    last_transfer_lease: ?Lease = null,
    last_human_event: u64 = 0,
    last_automation_event: u64 = 0,
    revocations: [16]Revocation = undefined,
    revocation_count: usize = 0,
    /// A full notification queue fails acquisition, rather than losing a lease
    /// revocation. drainRevocation is called by the host before new acquisition.
    pub fn acquire(self: *Context, kind: LeaseKind, authorization_revision: u64) !Lease {
        if (self.closed) return error.OwnerClosed;
        if (self.transfer_state == .pending) return error.WindowTransferPending;
        if (!self.focused) return error.WindowNotFocused;
        if (kind == .human_focus and !self.content_focused) return error.ContentNotFocused;
        if (!self.authorized or authorization_revision != self.authorization_revision) return error.InputDenied;
        if (self.revocation_count + @as(usize, @intFromBool(self.human != null)) + @as(usize, @intFromBool(self.automation != null)) >= self.revocations.len) return error.RevocationQueueFull;
        if (self.next_lease == std.math.maxInt(u64)) return error.LeaseIdentityExhausted;
        if (kind == .human_focus) {
            if (self.human) |lease| return lease;
            // Human takeover revokes automation explicitly; focusing the AI
            // panel alone never acquires a human content lease.
            self.revoke(.automation, .takeover);
        } else {
            if (self.human != null) return error.HumanInputActive;
            if (self.automation) |lease| return lease;
        }
        try self.ensureIdentity();
        const lease: Lease = .{ .context_instance = self.context_instance, .window_id = self.window_id, .id = self.next_lease, .owner = self.owner, .kind = kind, .authorization_revision = self.authorization_revision };
        self.next_lease += 1;
        if (kind == .human_focus) self.human = lease else self.automation = lease;
        return lease;
    }
    pub fn ensureIdentity(self: *Context) !void {
        if (self.context_instance == 0) {
            var next = next_context_instance.load(.monotonic);
            while (true) {
                if (next == std.math.maxInt(u64)) return error.ContextIdentityExhausted;
                if (next_context_instance.cmpxchgWeak(next, next + 1, .monotonic, .monotonic)) |actual| next = actual else break;
            }
            self.context_instance = next;
        }
    }
    /// Renderer registers only its own input receiver; the facade retains all
    /// ownership/authorization/lease gates around the callback.
    pub fn setConsumer(self: *Context, consumer: Consumer) !void {
        if (self.closed) return error.OwnerClosed;
        self.consumer = consumer;
    }
    pub fn release(self: *Context, lease: Lease) void {
        if (self.matches(lease)) self.revoke(lease.kind, .released);
    }
    pub fn setFocus(self: *Context, window_focused: bool, content_focused: bool) void {
        self.focused = window_focused;
        self.content_focused = content_focused;
        if (!window_focused) {
            self.revoke(.human_focus, .lost_focus);
            self.revoke(.automation, .lost_focus);
        }
        if (!content_focused) self.revoke(.human_focus, .lost_focus);
    }
    pub fn setAuthorization(self: *Context, authorized: bool, revision: u64) !void {
        if (revision < self.authorization_revision or revision == 0) return error.StaleAuthorization;
        if (revision != self.authorization_revision or !authorized) {
            self.revoke(.human_focus, .permission_changed);
            self.revoke(.automation, .permission_changed);
        }
        self.authorized = authorized;
        self.authorization_revision = revision;
    }
    pub fn close(self: *Context) void {
        if (self.closed) return;
        self.revoke(.human_focus, .owner_closed);
        self.revoke(.automation, .owner_closed);
        self.closed = true;
    }
    pub fn transferWindow(self: *Context, destination: identity.WindowId) !void {
        if (self.closed) return error.OwnerClosed;
        if (self.transfer_state == .pending) return error.WindowTransferPending;
        if (destination == self.window_id) return error.SameWindow;
        self.last_transfer_lease = self.human orelse self.automation;
        self.revoke(.human_focus, .window_transfer);
        self.revoke(.automation, .window_transfer);
        self.transfer_state = .{ .pending = destination };
        self.focused = false;
        self.content_focused = false;
        self.window.transfer(self.window.context, self.owner, destination) catch |err| {
            self.transfer_state = .{ .failed = err };
            return err;
        };
    }
    pub fn windowDestinations(self: *Context, out: []identity.WindowId) usize {
        if (self.closed) return 0;
        return if (self.window.destinations) |list| list(self.window.context, self.owner, out) else 0;
    }
    pub fn requestFullscreen(self: *Context, enabled: bool) !void {
        if (self.closed) return error.OwnerClosed;
        try self.window.request_fullscreen(self.window.context, enabled);
    }
    pub fn fullscreen(self: *const Context) bool {
        return !self.closed and self.window.fullscreen_state(self.window.context);
    }
    /// event_sequence is assigned by the host input dispatcher and increases
    /// once per physical or automation event. It prevents duplicate dispatch.
    /// host_consumed covers top-layer challenge/popover/reserved shortcuts.
    pub fn route(self: *Context, lease: Lease, event_sequence: u64, input: Input, host_consumed: bool) !bool {
        if (host_consumed) return false;
        if (self.closed or self.transfer_state == .pending or !self.focused or !self.authorized or !self.matches(lease)) return error.StaleInputLease;
        if (lease.kind == .human_focus and !self.content_focused) return error.ContentNotFocused;
        const last = if (lease.kind == .human_focus) &self.last_human_event else &self.last_automation_event;
        if (event_sequence == 0 or event_sequence <= last.*) return false;
        // Consume sequence even when the receiver fails: a caller must never
        // replay an uncertain key/button write after a transport error.
        last.* = event_sequence;
        try self.consumer.consume(self.consumer.context, input);
        return true;
    }
    pub fn drainRevocation(self: *Context) ?Revocation {
        if (self.revocation_count == 0) return null;
        const value = self.revocations[0];
        std.mem.copyForwards(Revocation, self.revocations[0 .. self.revocation_count - 1], self.revocations[1..self.revocation_count]);
        self.revocation_count -= 1;
        return value;
    }
    fn matches(self: *const Context, lease: Lease) bool {
        if (lease.context_instance == 0 or lease.context_instance != self.context_instance or lease.window_id != self.window_id) return false;
        if (!lease.owner.eql(self.owner) or lease.authorization_revision != self.authorization_revision) return false;
        const current = if (lease.kind == .human_focus) self.human else self.automation;
        return if (current) |value| value.id == lease.id else false;
    }
    fn revoke(self: *Context, kind: LeaseKind, reason: RevokeReason) void {
        const slot = if (kind == .human_focus) &self.human else &self.automation;
        if (slot.*) |lease| {
            // Acquire reserves a notification slot for every live lease.
            std.debug.assert(self.revocation_count < self.revocations.len);
            self.revocations[self.revocation_count] = .{ .lease = lease, .reason = reason };
            self.revocation_count += 1;
            slot.* = null;
            // Best effort remote key/button release; failure is not represented
            // as success, and can never keep the local lease alive.
            self.consumer.consume(self.consumer.context, .release_all) catch {};
        }
    }
};
pub const ContentContext = Context;
const TestDriver = struct {
    count: usize = 0,
    releases: usize = 0,
    full: bool = false,
    fn consume(ptr: *anyopaque, value: Input) !void {
        const self: *TestDriver = @ptrCast(@alignCast(ptr));
        if (value == .release_all) self.releases += 1 else self.count += 1;
    }
    fn request(ptr: *anyopaque, enabled: bool) !void {
        const self: *TestDriver = @ptrCast(@alignCast(ptr));
        self.full = enabled;
    }
    fn state(ptr: *anyopaque) bool {
        const self: *TestDriver = @ptrCast(@alignCast(ptr));
        return self.full;
    }
    fn transfer(_: *anyopaque, _: identity.SessionHandle, _: identity.WindowId) !void {}
};
test "AI focus is separate from human lease, takeover revokes and events dispatch once" {
    var driver: TestDriver = .{};
    var context: Context = .{ .owner = .{ .session_id = @fromBackingInt(1) }, .window_id = @fromBackingInt(1), .window = .{ .context = &driver, .request_fullscreen = TestDriver.request, .fullscreen_state = TestDriver.state, .transfer = TestDriver.transfer }, .consumer = .{ .context = &driver, .consume = TestDriver.consume } };
    try context.setAuthorization(true, 2);
    context.setFocus(true, false);
    const ai = try context.acquire(.automation, 2);
    try std.testing.expectError(error.ContentNotFocused, context.acquire(.human_focus, 2));
    try std.testing.expect(!try context.route(ai, 1, .{ .text = "a" }, true));
    try std.testing.expect(try context.route(ai, 1, .{ .text = "a" }, false));
    try std.testing.expect(!try context.route(ai, 1, .{ .text = "a" }, false));
    context.setFocus(true, true);
    const human = try context.acquire(.human_focus, 2);
    try std.testing.expectError(error.StaleInputLease, context.route(ai, 2, .{ .text = "b" }, false));
    try std.testing.expectEqual(RevokeReason.takeover, context.drainRevocation().?.reason);
    try context.transferWindow(@fromBackingInt(2));
    try std.testing.expectError(error.StaleInputLease, context.route(human, 3, .{ .text = "c" }, false));
    try std.testing.expectEqual(@as(usize, 1), driver.count);
    try std.testing.expectEqual(@as(usize, 2), driver.releases);
}

test "input focus authorization close and full revocation queue never leave stale authority" {
    var driver: TestDriver = .{};
    var context: Context = .{ .owner = .{ .session_id = @fromBackingInt(1) }, .window_id = @fromBackingInt(1), .window = .{ .context = &driver, .request_fullscreen = TestDriver.request, .fullscreen_state = TestDriver.state, .transfer = TestDriver.transfer }, .consumer = .{ .context = &driver, .consume = TestDriver.consume } };
    try context.setAuthorization(true, 2);
    context.setFocus(true, false);
    const blurred = try context.acquire(.automation, 2);
    context.setFocus(false, false);
    try std.testing.expectEqual(RevokeReason.lost_focus, context.drainRevocation().?.reason);
    try std.testing.expectError(error.StaleInputLease, context.route(blurred, 1, .{ .text = "a" }, false));
    context.setFocus(true, false);
    const denied = try context.acquire(.automation, 2);
    try context.setAuthorization(false, 3);
    try std.testing.expectEqual(RevokeReason.permission_changed, context.drainRevocation().?.reason);
    try std.testing.expectError(error.StaleInputLease, context.route(denied, 2, .{ .text = "b" }, false));
    try context.setAuthorization(true, 4);
    for (0..context.revocations.len) |_| {
        const lease = try context.acquire(.automation, 4);
        context.release(lease);
    }
    try std.testing.expectError(error.RevocationQueueFull, context.acquire(.automation, 4));
    _ = context.drainRevocation();
    const closing = try context.acquire(.automation, 4);
    context.close();
    context.close();
    try std.testing.expectEqual(@as(usize, context.revocations.len), context.revocation_count);
    try std.testing.expectError(error.StaleInputLease, context.route(closing, 3, .{ .text = "c" }, false));
    try std.testing.expectError(error.OwnerClosed, context.acquire(.automation, 4));
    try std.testing.expectEqual(@as(usize, 0), driver.count);
}

pub const ChildIntent = enum { create, edit };
pub const ChildResult = union(enum) { saved: struct { asset_id: identity.ConnectionId, revision: u64 }, cancelled, failed: []const u8 };
pub const ChildRequest = struct { request_id: u64, parent_editor_id: u64, draft_revision: u64, contribution_id: []const u8, intent: ChildIntent };
pub const ChildCompletion = struct { request: ChildRequest, result: ChildResult };
/// A host callback resolves the registered contribution and opens its editor
/// slot. Parents receive IDs and completion values, never plugin instances.
pub const EditorHost = struct {
    pub const capacity = 32;
    allocator: std.mem.Allocator,
    context: *anyopaque,
    open_registered: *const fn (*anyopaque, ChildRequest) anyerror!void,
    parents: std.ArrayList(struct {
        id: u64,
        revision: u64,
        delivery: ?struct { context: *anyopaque, callback: *const fn (*anyopaque, ChildCompletion) void } = null,
    }) = .empty,
    pending: std.ArrayList(ChildRequest) = .empty,
    next_request: u64 = 1,
    pub fn deinit(self: *EditorHost) void {
        for (self.pending.items) |item| self.allocator.free(item.contribution_id);
        self.pending.deinit(self.allocator);
        self.parents.deinit(self.allocator);
    }
    pub fn setParentRevision(self: *EditorHost, parent_editor_id: u64, revision: u64) !void {
        if (parent_editor_id == 0 or revision == 0) return error.InvalidEditor;
        for (self.parents.items) |*parent| if (parent.id == parent_editor_id) {
            if (revision < parent.revision) return error.StaleDraft;
            parent.revision = revision;
            return;
        };
        if (self.parents.items.len == capacity) return error.EditorQueueFull;
        try self.parents.append(self.allocator, .{ .id = parent_editor_id, .revision = revision });
    }
    pub fn setParentDelivery(self: *EditorHost, parent_editor_id: u64, context: *anyopaque, callback: *const fn (*anyopaque, ChildCompletion) void) !void {
        for (self.parents.items) |*parent| if (parent.id == parent_editor_id) {
            parent.delivery = .{ .context = context, .callback = callback };
            return;
        };
        return error.UnknownParentEditor;
    }
    pub fn completeRegistered(self: *EditorHost, request_id: u64, result: ChildResult) !bool {
        for (self.pending.items) |request| if (request.request_id == request_id) {
            for (self.parents.items) |parent| if (parent.id == request.parent_editor_id) {
                const delivery = parent.delivery orelse return error.ChildDeliveryUnavailable;
                return self.complete(request_id, result, delivery.context, delivery.callback);
            };
            return false;
        };
        return false;
    }
    pub fn destroyParent(self: *EditorHost, parent_editor_id: u64) void {
        for (self.parents.items, 0..) |parent, i| if (parent.id == parent_editor_id) {
            _ = self.parents.orderedRemove(i);
            break;
        };
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].parent_editor_id == parent_editor_id) {
                const removed = self.pending.orderedRemove(i);
                self.allocator.free(removed.contribution_id);
            } else i += 1;
        }
    }
    pub fn openChild(self: *EditorHost, parent_editor_id: u64, draft_revision: u64, contribution_id: []const u8, intent: ChildIntent) !u64 {
        if (!self.current(parent_editor_id, draft_revision)) return error.StaleDraft;
        if (self.pending.items.len == capacity) return error.EditorQueueFull;
        if (contribution_id.len == 0 or contribution_id.len > 256) return error.InvalidContribution;
        if (self.next_request == std.math.maxInt(u64)) return error.RequestIdentityExhausted;
        const owned = try self.allocator.dupe(u8, contribution_id);
        errdefer self.allocator.free(owned);
        try self.pending.ensureUnusedCapacity(self.allocator, 1);
        const request: ChildRequest = .{ .request_id = self.next_request, .parent_editor_id = parent_editor_id, .draft_revision = draft_revision, .contribution_id = owned, .intent = intent };
        // Reserve ID and record before callback. A callback may schedule async
        // work, but cannot complete synchronously until this call returns.
        self.next_request += 1;
        try self.open_registered(self.context, request);
        self.pending.appendAssumeCapacity(request);
        return request.request_id;
    }
    /// Completion is delivered synchronously, while request strings are valid.
    /// Returns false for old/deleted parent drafts; those never backfill state.
    pub fn complete(self: *EditorHost, request_id: u64, result: ChildResult, context: *anyopaque, deliver: *const fn (*anyopaque, ChildCompletion) void) !bool {
        for (self.pending.items, 0..) |request, i| if (request.request_id == request_id) {
            const removed = self.pending.orderedRemove(i);
            defer self.allocator.free(removed.contribution_id);
            if (!self.current(request.parent_editor_id, request.draft_revision)) return false;
            if (result == .saved and (@backingInt(result.saved.asset_id) == 0 or result.saved.revision == 0)) return error.InvalidSavedAsset;
            deliver(context, .{ .request = request, .result = result });
            return true;
        };
        return false;
    }
    fn current(self: *const EditorHost, id: u64, revision: u64) bool {
        for (self.parents.items) |parent| if (parent.id == id) return parent.revision == revision;
        return false;
    }
};
test "child editor completion cannot backfill a newer or destroyed parent" {
    const Driver = struct {
        delivered: usize = 0,
        fn open(_: *anyopaque, _: ChildRequest) !void {}
        fn deliver(ptr: *anyopaque, _: ChildCompletion) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.delivered += 1;
        }
    };
    var driver: Driver = .{};
    var editor: EditorHost = .{ .allocator = std.testing.allocator, .context = &driver, .open_registered = Driver.open };
    defer editor.deinit();
    try editor.setParentRevision(1, 1);
    const old = try editor.openChild(1, 1, "ssh.connection", .create);
    try editor.setParentRevision(1, 2);
    try std.testing.expect(!try editor.complete(old, .{ .saved = .{ .asset_id = @fromBackingInt(9), .revision = 1 } }, &driver, Driver.deliver));
    const current = try editor.openChild(1, 2, "ssh.connection", .edit);
    try std.testing.expect(try editor.complete(current, .cancelled, &driver, Driver.deliver));
    const destroyed = try editor.openChild(1, 2, "ssh.connection", .create);
    editor.destroyParent(1);
    try std.testing.expect(!try editor.complete(destroyed, .cancelled, &driver, Driver.deliver));
    try std.testing.expectEqual(@as(usize, 1), driver.delivered);
}

test "input leases never alias another context or a later mount in the same window" {
    var driver: TestDriver = .{};
    var first: Context = .{ .owner = .{ .session_id = @fromBackingInt(91) }, .window_id = @fromBackingInt(1), .window = .{ .context = &driver, .request_fullscreen = TestDriver.request, .fullscreen_state = TestDriver.state, .transfer = TestDriver.transfer }, .consumer = .{ .context = &driver, .consume = TestDriver.consume } };
    try first.setAuthorization(true, 2);
    first.setFocus(true, false);
    const old = try first.acquire(.automation, 2);
    var second = first;
    second.window_id = @fromBackingInt(2);
    second.context_instance = 0;
    second.next_lease = 1;
    second.automation = null;
    const fresh = try second.acquire(.automation, 2);
    try std.testing.expectEqual(old.id, fresh.id);
    try std.testing.expect(old.context_instance != fresh.context_instance);
    try std.testing.expectError(error.StaleInputLease, second.route(old, 1, .{ .text = "stale" }, false));
    first.close();
    try std.testing.expectError(error.StaleInputLease, first.route(old, 1, .{ .text = "closed" }, false));
    var returned = second;
    returned.window_id = first.window_id;
    returned.context_instance = 0;
    returned.next_lease = 1;
    returned.automation = null;
    const back = try returned.acquire(.automation, 2);
    try std.testing.expect(back.context_instance != old.context_instance);
    try std.testing.expectError(error.StaleInputLease, returned.route(old, 1, .{ .text = "return" }, false));
}
