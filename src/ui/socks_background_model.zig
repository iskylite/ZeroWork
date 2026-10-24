//! Presentation follows registered no-shell owners and actual listener receipts.
const std = @import("std");
const identity = @import("../host/identity.zig");
const sessions = @import("../host/session_host.zig");
const operations = @import("../host/operation.zig");
pub const Runtime = @import("../host/socks_background_runtime.zig");
pub const Routes = @import("../host/socks_route_host.zig");
pub const Phase = enum { connecting, starting, listening, paused, failed, closing, cleanup_unknown };
pub const Row = struct {
    owner: identity.SessionHandle,
    source: identity.AssetOwner,
    name: []const u8,
    phase: Phase,
    local_port: ?u16,
    connections: u32,
    failure: ?anyerror,
};
pub const Source = struct {
    host_id: u64,
    asset: identity.AssetOwner,
    name: []const u8,
    options: Routes.StartOptions,
};
pub const Hooks = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, u64, identity.AssetOwner) anyerror!sessions.Accepted,
    snapshots: *const fn (*anyopaque, std.mem.Allocator) anyerror![]Runtime.Snapshot,
    listener: *const fn (*anyopaque, identity.SessionHandle) ?Routes.Snapshot,
    start: *const fn (*anyopaque, identity.SessionHandle, Routes.StartOptions) anyerror!operations.OperationKey,
    close_listener: *const fn (*anyopaque, identity.SessionHandle) sessions.CloseReceipt,
    close_owner: *const fn (*anyopaque, identity.SessionHandle) anyerror!operations.OperationKey,
    reconnect: *const fn (*anyopaque, identity.SessionHandle) anyerror!void,
};
const Entry = struct {
    source: Source,
    owner: identity.SessionHandle,
    attempted: ?identity.SessionHandle = null,
    stopping: bool = false,
    seen: bool = false,
    failure: ?anyerror = null,
};
pub const Model = struct {
    allocator: std.mem.Allocator,
    hooks: Hooks,
    entries: std.ArrayList(Entry) = .empty,
    rows: std.ArrayList(Row) = .empty,

    pub fn init(allocator: std.mem.Allocator, hooks: Hooks) Model {
        return .{ .allocator = allocator, .hooks = hooks };
    }
    pub fn deinit(self: *Model) void {
        for (self.entries.items) |entry| self.allocator.free(entry.source.name);
        self.entries.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn hasAsset(self: *const Model, asset: identity.AssetOwner) bool {
        for (self.entries.items) |entry| if (entry.source.asset.id == asset.id) return true;
        return false;
    }
    pub fn startSaved(self: *Model, source: Source) !identity.SessionHandle {
        return self.startSavedWith(source, self.hooks.context, self.hooks.create);
    }
    /// Creation belongs to the requesting window. Only the accepted immutable
    /// source and owner enter this application-owned model.
    pub fn startSavedWith(self: *Model, source: Source, context: *anyopaque, create_fn: *const fn (*anyopaque, u64, identity.AssetOwner) anyerror!sessions.Accepted) !identity.SessionHandle {
        if (self.hasAsset(source.asset)) return error.BackgroundAlreadyActive;
        if (!source.options.listener.bind127 and !source.options.listener.exposure_confirmed) return error.ExposureConfirmationRequired;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const name = try self.allocator.dupe(u8, source.name);
        errdefer self.allocator.free(name);
        const accepted = try create_fn(context, source.host_id, source.asset);
        var owned = source;
        owned.name = name;
        self.entries.appendAssumeCapacity(.{ .source = owned, .owner = accepted.handle });
        return accepted.handle;
    }
    pub fn refresh(self: *Model) !bool {
        const values = try self.hooks.snapshots(self.hooks.context, self.allocator);
        defer self.allocator.free(values);
        try self.rows.ensureTotalCapacity(self.allocator, values.len);
        self.rows.clearRetainingCapacity();
        for (values) |value| {
            if (value.lifecycle == .closed) continue;
            const entry = self.findSession(value.owner.session_id) orelse continue;
            if (!std.meta.eql(value.source, entry.source.asset) or value.owner.generation < entry.owner.generation) continue;
            entry.seen = true;
            if (!entry.owner.eql(value.owner)) entry.stopping = false;
            entry.owner = value.owner;
            const may_start = !entry.stopping and value.lifecycle == .ready and value.phase == .ready;
            if (may_start and (entry.attempted == null or !entry.attempted.?.eql(value.owner))) {
                entry.attempted = value.owner;
                entry.failure = null;
                const previous = self.hooks.listener(self.hooks.context, value.owner);
                const retained = if (previous) |live| live.owner.eql(value.owner) and live.cleanup != .released else false;
                if (!retained) {
                    if (self.hooks.start(self.hooks.context, value.owner, entry.source.options)) |_| {} else |err| {
                        entry.failure = err;
                    }
                }
            }
            const observed = self.hooks.listener(self.hooks.context, value.owner);
            const listener = if (observed) |live| if (live.owner.eql(value.owner)) live else null else null;
            const phase = projectedPhase(value, listener, entry.stopping, entry.failure);
            self.rows.appendAssumeCapacity(.{
                .owner = value.owner,
                .source = value.source,
                .name = entry.source.name,
                .phase = phase,
                .local_port = if (listener) |live| if (live.owner.eql(value.owner) and live.local_port != 0 and live.cleanup != .released) live.local_port else null else null,
                .connections = if (listener) |live| if (live.owner.eql(value.owner) and live.cleanup != .released) live.stats.connections_active else 0 else 0,
                .failure = failureFor(entry.failure, value.failure, listener),
            });
        }
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            if (!entry.seen) continue;
            var present = false;
            for (values) |value| if (value.owner.session_id == entry.owner.session_id and value.lifecycle != .closed) {
                present = true;
                break;
            };
            if (!present) {
                self.allocator.free(entry.source.name);
                _ = self.entries.orderedRemove(i);
            }
        }
        return self.rows.items.len != 0;
    }
    pub fn stop(self: *Model, owner: identity.SessionHandle) !void {
        const entry = self.current(owner) orelse return error.StaleBackgroundOwner;
        if (entry.stopping) return;
        // Accept against the captured owner now; never carry an old stop
        // gesture to a replacement generation in a later snapshot refresh.
        _ = self.hooks.close_listener(self.hooks.context, owner);
        _ = try self.hooks.close_owner(self.hooks.context, owner);
        entry.stopping = true;
    }
    pub fn reconnect(self: *Model, owner: identity.SessionHandle) !void {
        const entry = self.current(owner) orelse return error.StaleBackgroundOwner;
        if (entry.stopping) return error.BackgroundClosing;
        try self.hooks.reconnect(self.hooks.context, owner);
    }
    pub fn currentRow(self: *const Model, owner: identity.SessionHandle) ?Row {
        for (self.rows.items) |row| if (row.owner.eql(owner)) return row;
        return null;
    }
    fn current(self: *Model, owner: identity.SessionHandle) ?*Entry {
        _ = self.currentRow(owner) orelse return null;
        const entry = self.findSession(owner.session_id) orelse return null;
        return if (entry.owner.eql(owner)) entry else null;
    }
    fn findSession(self: *Model, id: identity.SessionId) ?*Entry {
        for (self.entries.items) |*entry| if (entry.owner.session_id == id) return entry;
        return null;
    }
};
fn failureFor(local: ?anyerror, runtime_failure: ?anyerror, listener: ?Routes.Snapshot) ?anyerror {
    if (local) |err| return err;
    if (runtime_failure) |err| return err;
    if (listener) |live| return live.failure;
    return null;
}
pub fn projectedPhase(value: Runtime.Snapshot, listener: ?Routes.Snapshot, stopping: bool, failure: ?anyerror) Phase {
    if (value.lifecycle == .cleanup_unknown or value.phase == .cleanup_unknown or value.cleanup == .unknown) return .cleanup_unknown;
    if (listener) |live| if (live.owner.eql(value.owner) and (live.phase == .cleanup_unknown or live.cleanup == .unknown)) return .cleanup_unknown;
    if (stopping or value.lifecycle == .closing or value.phase == .closing) return .closing;
    if (failure != null or value.phase == .failed or value.lifecycle == .failed) return .failed;
    if (value.lifecycle == .ended or value.phase == .paused) return .paused;
    if (value.lifecycle != .ready or value.phase != .ready) return .connecting;
    const live = listener orelse return .starting;
    if (!live.owner.eql(value.owner)) return .starting;
    return switch (live.phase) {
        .ready => if (live.local_port != 0 and live.cleanup != .released) .listening else .starting,
        .connecting => .starting,
        .paused => .paused,
        .failed => .failed,
        .closing => .closing,
        .cleanup_unknown => .cleanup_unknown,
        .closed => if (live.failure != null) .failed else .paused,
    };
}
pub fn phaseLabel(phase: Phase) []const u8 {
    return switch (phase) {
        .connecting => "连接中",
        .starting => "开启监听中",
        .listening => "后台监听",
        .paused => "已暂停",
        .failed => "连接失败",
        .closing => "正在停止",
        .cleanup_unknown => "清理待确认",
    };
}
