//! Main-thread adapter for the project-local UserNotifications bridge.
//! The native owner queues value copies, never callbacks into this Zig object.
const std = @import("std");
const notifications = @import("../host/notification_coordinator.zig");

pub const Handle = opaque {};
pub const RawCapabilities = extern struct {
    system_notifications: u32 = 0,
    authorization_request: u32 = 0,
    activation: u32 = 0,
    bell: u32 = 0,
    unavailable_reason: u32 = 0,
};
pub const RawTarget = extern struct {
    owner_kind: u32 = 0,
    kind: u32 = 0,
    owner_id: u64 = 0,
    owner_revision: u64 = 0,
    operation_id: u64 = 0,
    attempt_or_turn_id: u64 = 0,
    has_attempt_or_turn: u32 = 0,
};
pub const RawSettings = extern struct {
    authorization: u32 = 0,
    alert_setting: u32 = 0,
    center_setting: u32 = 0,
    sound_setting: u32 = 0,
};
pub const RawEvent = extern struct {
    kind: u32 = 0,
    result: u32 = 0,
    request_id: u64 = 0,
    event_id: u64 = 0,
    target: RawTarget = .{},
    settings: RawSettings = .{},
    current_instance: u32 = 0,
    granted: u32 = 0,
    dropped_events: u64 = 0,
    error_code: i64 = 0,
    error_domain: [64]u8 = @splat(0),
    error_detail: [192]u8 = @splat(0),
};

/// Injectable only to exercise asynchronous receipts without an OS prompt,
/// sound, notification, AppKit application or native window in unit tests.
pub const Api = struct {
    create: *const fn (*c_int) callconv(.c) ?*Handle,
    destroy: *const fn (*Handle) callconv(.c) void,
    capabilities: *const fn (*Handle, *RawCapabilities) callconv(.c) c_int,
    query_settings: *const fn (*Handle, u64) callconv(.c) c_int,
    request_authorization: *const fn (*Handle, u64, u32) callconv(.c) c_int,
    send: *const fn (*Handle, u64, u64, *const RawTarget, [*]const u8, usize) callconv(.c) c_int,
    poll: *const fn (*Handle, *RawEvent) callconv(.c) c_int,
    ring: *const fn (*Handle) callconv(.c) c_int,
};

extern fn zw_notifications_create(*c_int) ?*Handle;
extern fn zw_notifications_destroy(*Handle) void;
extern fn zw_notifications_capabilities(*Handle, *RawCapabilities) c_int;
extern fn zw_notifications_query_settings(*Handle, u64) c_int;
extern fn zw_notifications_request_authorization(*Handle, u64, u32) c_int;
extern fn zw_notifications_send(*Handle, u64, u64, *const RawTarget, [*]const u8, usize) c_int;
extern fn zw_notifications_poll(*Handle, *RawEvent) c_int;
extern fn zw_notifications_ring(*Handle) c_int;
const native_api: Api = .{
    .create = zw_notifications_create,
    .destroy = zw_notifications_destroy,
    .capabilities = zw_notifications_capabilities,
    .query_settings = zw_notifications_query_settings,
    .request_authorization = zw_notifications_request_authorization,
    .send = zw_notifications_send,
    .poll = zw_notifications_poll,
    .ring = zw_notifications_ring,
};

pub const UnavailableReason = enum { none, no_app_bundle, center_unavailable, delegate_in_use };
pub const Capabilities = struct {
    system_notifications: bool,
    authorization_request: bool,
    activation: bool,
    bell: bool,
    unavailable_reason: UnavailableReason,
};
pub const Setting = enum { unsupported, disabled, enabled };
pub const Settings = struct {
    authorization: notifications.Authorization,
    alert: Setting,
    notification_center: Setting,
    sound: Setting,
};
/// This typed action belongs only to a real user gesture. Driver creation,
/// refresh, Save, reset and policy updates never call requestAuthorization.
pub const PermissionAction = enum { enable_system_notifications };
pub const Failure = struct {
    code: i64,
    domain: [64]u8,
    detail: [192]u8,

    pub fn domainText(self: *const Failure) []const u8 {
        return std.mem.sliceTo(&self.domain, 0);
    }
    pub fn detailText(self: *const Failure) []const u8 {
        return std.mem.sliceTo(&self.detail, 0);
    }
};
pub const Completion = union(enum) {
    settings: struct { request_id: u64, value: Settings, current_settings: bool, explicit_request: bool, granted: bool, failure: ?Failure },
    system: struct { request_id: u64, event_id: u64, target: notifications.Target, result: enum { scheduled, failed }, settings: Settings, current_settings: bool, failure: ?Failure },
    activation: struct { event_id: u64, target: notifications.Target, current_instance: bool },
    queue_failure: struct { dropped_events: u64 },
};
const OperationKind = enum { query, permission, send };
const Operation = struct {
    request_id: u64,
    kind: OperationKind,
    event_id: u64 = 0,
    target: ?notifications.Target = null,
    finished: bool = false,
    settings_epoch: u64 = 0,
    accept_settings: bool = true,
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    api: Api,
    handle: ?*Handle,
    capabilities: Capabilities,
    settings: ?Settings = null,
    operations: std.ArrayList(Operation) = .empty,
    next_request_id: u64 = 1,
    settings_epoch: u64 = 0,

    /// Does a read-only authorization query when the app bundle supports it.
    /// It neither requests permission nor sends any system event or Bell.
    pub fn init(allocator: std.mem.Allocator) !Driver {
        return initWithApi(allocator, native_api);
    }
    pub fn initWithApi(allocator: std.mem.Allocator, api: Api) !Driver {
        var status: c_int = 0;
        const handle = api.create(&status) orelse {
            try check(status);
            return error.NativeNotificationCreateFailed;
        };
        errdefer api.destroy(handle);
        try check(status);
        var raw: RawCapabilities = .{};
        try check(api.capabilities(handle, &raw));
        var self: Driver = .{ .allocator = allocator, .api = api, .handle = handle, .capabilities = try decodeCapabilities(raw) };
        errdefer self.operations.deinit(allocator);
        if (self.capabilities.system_notifications) _ = try self.refreshAuthorization();
        return self;
    }
    /// Releases Zig state immediately. Native continuations only retain native
    /// self and drop their value receipts after close. No callback can use self.
    /// OS-accepted immediate notifications can remain in Notification Center.
    pub fn deinit(self: *Driver) void {
        if (self.handle) |handle| self.api.destroy(handle);
        self.handle = null;
        self.operations.deinit(self.allocator);
        self.operations = .empty;
    }
    pub fn sink(self: *Driver) notifications.Sink {
        return .{
            .context = self,
            .authorization = if (self.settings) |value| value.authorization else .unavailable,
            .notify = if (self.capabilities.system_notifications) enqueueSink else null,
            .ring = if (self.capabilities.bell) ringSink else null,
            .delivery_mode = .asynchronous,
        };
    }
    pub fn refreshAuthorization(self: *Driver) !u64 {
        const handle = self.handle orelse return error.NotificationDriverClosed;
        if (!self.capabilities.system_notifications) return error.NotificationUnavailable;
        if (self.inFlight(.query)) return error.AuthorizationQueryPending;
        if (self.inFlight(.permission)) return error.AuthorizationRequestPending;
        if (self.settings_epoch == std.math.maxInt(u64)) return error.NotificationSettingsEpochExhausted;
        const id = try self.reserve();
        try check(self.api.query_settings(handle, id));
        self.settings_epoch += 1;
        self.operations.appendAssumeCapacity(.{ .request_id = id, .kind = .query, .settings_epoch = self.settings_epoch });
        return id;
    }
    pub fn requestAuthorization(self: *Driver, action: PermissionAction) !u64 {
        const handle = self.handle orelse return error.NotificationDriverClosed;
        if (!self.capabilities.authorization_request) return error.NotificationUnavailable;
        if (self.inFlight(.permission)) return error.AuthorizationRequestPending;
        if (self.settings_epoch == std.math.maxInt(u64)) return error.NotificationSettingsEpochExhausted;
        const id = try self.reserve();
        try check(self.api.request_authorization(handle, id, switch (action) {
            .enable_system_notifications => 1,
        }));
        self.settings_epoch += 1;
        self.operations.appendAssumeCapacity(.{ .request_id = id, .kind = .permission, .settings_epoch = self.settings_epoch });
        return id;
    }
    pub fn send(self: *Driver, message: notifications.SystemMessage) !u64 {
        const handle = self.handle orelse return error.NotificationDriverClosed;
        if (!self.capabilities.system_notifications) return error.NotificationUnavailable;
        if (message.event_id == 0 or message.summary.len == 0 or
            !std.unicode.utf8ValidateSlice(message.summary) or std.mem.indexOfScalar(u8, message.summary, 0) != null) return error.InvalidNotificationMessage;
        const target = try encodeTarget(message.target);
        for (self.operations.items) |operation| {
            if (operation.kind == .send and operation.event_id == message.event_id) return error.DuplicateNotificationEvent;
        }
        const id = try self.reserve();
        try check(self.api.send(handle, id, message.event_id, &target, message.summary.ptr, message.summary.len));
        self.operations.appendAssumeCapacity(.{ .request_id = id, .kind = .send, .event_id = message.event_id, .target = message.target, .settings_epoch = self.settings_epoch, .accept_settings = !self.inFlight(.permission) });
        return id;
    }
    pub fn ring(self: *Driver) !void {
        const handle = self.handle orelse return error.NotificationDriverClosed;
        if (!self.capabilities.bell) return error.NotificationUnavailable;
        try check(self.api.ring(handle));
    }
    pub fn poll(self: *Driver) !?Completion {
        const handle = self.handle orelse return error.NotificationDriverClosed;
        var raw: RawEvent = .{};
        const result = self.api.poll(handle, &raw);
        if (result < 0) try check(-result);
        if (result == 0) return null;
        if (result != 1) return error.InvalidNativeNotificationCompletion;
        if (raw.kind == 5) {
            if (raw.result != 3 or raw.dropped_events == 0) return error.InvalidNativeNotificationCompletion;
            return .{ .queue_failure = .{ .dropped_events = raw.dropped_events } };
        }
        if (raw.kind == 4) {
            if (raw.result != 1 or raw.event_id == 0 or raw.current_instance > 1) return error.InvalidNativeNotificationCompletion;
            const target = try decodeTarget(raw.target);
            if (raw.current_instance == 1) {
                var found = false;
                for (self.operations.items) |operation| if (operation.kind == .send and operation.event_id == raw.event_id) {
                    if (!std.meta.eql(operation.target.?, target)) return error.NotificationIdentityConflict;
                    found = true;
                    break;
                };
                if (!found) return error.UnknownNotificationActivation;
            }
            return .{ .activation = .{ .event_id = raw.event_id, .target = target, .current_instance = raw.current_instance == 1 } };
        }
        const expected: OperationKind = switch (raw.kind) {
            1 => .query,
            2 => .permission,
            3 => .send,
            else => return error.InvalidNativeNotificationCompletion,
        };
        const operation = self.operationFor(raw.request_id) orelse return error.UnknownNotificationRequest;
        if (operation.finished) return error.DuplicateNativeNotificationCompletion;
        if (operation.kind != expected) return error.InvalidNativeNotificationCompletion;
        const value = try decodeSettings(raw.settings);
        const current_settings = operation.accept_settings and operation.settings_epoch == self.settings_epoch and (expected == .permission or !self.inFlight(.permission));
        const failed = raw.result == 3;
        const failure_value: ?Failure = if (failed) .{ .code = raw.error_code, .domain = raw.error_domain, .detail = raw.error_detail } else null;
        const completion: Completion = if (expected == .send) blk: {
            if (raw.result != 2 and !failed) return error.InvalidNativeNotificationCompletion;
            const target = try decodeTarget(raw.target);
            if (raw.event_id != operation.event_id or !std.meta.eql(target, operation.target.?)) return error.NotificationIdentityConflict;
            break :blk .{ .system = .{ .request_id = raw.request_id, .event_id = raw.event_id, .target = target, .result = if (failed) .failed else .scheduled, .settings = value, .current_settings = current_settings, .failure = failure_value } };
        } else blk: {
            if (raw.result != 1 and !failed or raw.granted > 1) return error.InvalidNativeNotificationCompletion;
            break :blk .{ .settings = .{ .request_id = raw.request_id, .value = value, .current_settings = current_settings, .explicit_request = expected == .permission, .granted = raw.granted == 1, .failure = failure_value } };
        };
        operation.finished = true;
        if (current_settings) self.settings = value;
        return completion;
    }
    fn reserve(self: *Driver) !u64 {
        if (self.next_request_id == 0) return error.NotificationRequestIdentityExhausted;
        try self.operations.ensureUnusedCapacity(self.allocator, 1);
        const id = self.next_request_id;
        self.next_request_id = if (id == std.math.maxInt(u64)) 0 else id + 1;
        return id;
    }
    fn operationFor(self: *Driver, request_id: u64) ?*Operation {
        for (self.operations.items) |*operation| if (operation.request_id == request_id) return operation;
        return null;
    }
    fn inFlight(self: *const Driver, kind: OperationKind) bool {
        for (self.operations.items) |operation| if (operation.kind == kind and !operation.finished) return true;
        return false;
    }
    fn enqueueSink(raw: *anyopaque, message: notifications.SystemMessage) !void {
        const self: *Driver = @ptrCast(@alignCast(raw));
        _ = try self.send(message);
    }
    fn ringSink(raw: *anyopaque, _: notifications.BellMessage) !void {
        const self: *Driver = @ptrCast(@alignCast(raw));
        try self.ring();
    }
};

pub fn encodeTarget(target: notifications.Target) !RawTarget {
    var raw: RawTarget = .{
        .kind = switch (target.kind) {
            .transfer_done => 1,
            .reconnect => 2,
            .ai_ready => 3,
        },
        .operation_id = target.operation_id,
        .attempt_or_turn_id = target.attempt_or_turn_id orelse 0,
        .has_attempt_or_turn = @intFromBool(target.attempt_or_turn_id != null),
    };
    switch (target.owner) {
        .session => |owner| {
            raw.owner_kind = 1;
            raw.owner_id = @backingInt(owner.session_id);
            raw.owner_revision = owner.generation;
        },
        .group => |owner| {
            raw.owner_kind = 2;
            raw.owner_id = @backingInt(owner.id);
            raw.owner_revision = owner.revision;
        },
        .history => |owner| {
            raw.owner_kind = 3;
            raw.owner_id = @backingInt(owner);
        },
    }
    _ = try decodeTarget(raw);
    return raw;
}
pub fn decodeTarget(raw: RawTarget) !notifications.Target {
    if (raw.owner_id == 0 or raw.operation_id == 0 or raw.has_attempt_or_turn > 1 or
        (raw.has_attempt_or_turn == 1 and raw.attempt_or_turn_id == 0) or
        (raw.has_attempt_or_turn == 0 and raw.attempt_or_turn_id != 0)) return error.InvalidNotificationIdentity;
    const owner: notifications.Owner = switch (raw.owner_kind) {
        1 => if (raw.owner_revision != 0) .{ .session = .{ .session_id = @fromBackingInt(raw.owner_id), .generation = raw.owner_revision } } else return error.InvalidNotificationIdentity,
        2 => if (raw.owner_revision != 0) .{ .group = .{ .id = @fromBackingInt(raw.owner_id), .revision = raw.owner_revision } } else return error.InvalidNotificationIdentity,
        3 => if (raw.owner_revision == 0) .{ .history = @fromBackingInt(raw.owner_id) } else return error.InvalidNotificationIdentity,
        else => return error.InvalidNotificationIdentity,
    };
    return .{
        .owner = owner,
        .kind = switch (raw.kind) {
            1 => .transfer_done,
            2 => .reconnect,
            3 => .ai_ready,
            else => return error.InvalidNotificationIdentity,
        },
        .operation_id = raw.operation_id,
        .attempt_or_turn_id = if (raw.has_attempt_or_turn == 1) raw.attempt_or_turn_id else null,
    };
}
fn decodeSettings(raw: RawSettings) !Settings {
    return .{
        .authorization = switch (raw.authorization) {
            0 => .unavailable,
            1 => .not_determined,
            2 => .denied,
            3 => .authorized,
            4 => .provisional,
            else => return error.InvalidNativeNotificationSettings,
        },
        .alert = try decodeSetting(raw.alert_setting),
        .notification_center = try decodeSetting(raw.center_setting),
        .sound = try decodeSetting(raw.sound_setting),
    };
}
fn decodeSetting(raw: u32) !Setting {
    return switch (raw) {
        0 => .unsupported,
        1 => .disabled,
        2 => .enabled,
        else => error.InvalidNativeNotificationSettings,
    };
}
fn decodeCapabilities(raw: RawCapabilities) !Capabilities {
    if (raw.system_notifications > 1 or raw.authorization_request > 1 or raw.activation > 1 or raw.bell > 1) return error.InvalidNativeNotificationCapabilities;
    return .{
        .system_notifications = raw.system_notifications == 1,
        .authorization_request = raw.authorization_request == 1,
        .activation = raw.activation == 1,
        .bell = raw.bell == 1,
        .unavailable_reason = switch (raw.unavailable_reason) {
            0 => .none,
            1 => .no_app_bundle,
            2 => .center_unavailable,
            3 => .delegate_in_use,
            else => return error.InvalidNativeNotificationCapabilities,
        },
    };
}
fn check(status: c_int) !void {
    return switch (status) {
        0 => {},
        1 => error.NotificationWrongThread,
        2 => error.InvalidNotificationArgument,
        3 => error.NotificationUnavailable,
        4 => error.NotificationDriverClosed,
        5 => error.NativeNotificationFailed,
        else => error.InvalidNativeNotificationStatus,
    };
}
