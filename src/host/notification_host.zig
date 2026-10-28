//! Process-owned notification lifecycle. All calls are main-thread only.
//! Window registrations are removed before their contexts are destroyed.
const std = @import("std");
const config = @import("../config/config.zig");
const platform = @import("../platform/notifications.zig");
pub const notifications = @import("notification_coordinator.zig");
pub const ContentOwner = notifications.Owner;
const ConversationId = @import("identity.zig").ConversationId;
pub const WindowId = enum(u64) { _ };
pub const Window = struct {
    context: *anyopaque,
    owns: *const fn (*anyopaque, notifications.Target) bool,
    activate: *const fn (*anyopaque, notifications.Target) bool,
    activate_ai: ?*const fn (*anyopaque, ConversationId) bool = null,
    feedback: *const fn (*anyopaque, []const u8) void,
    owner_name: ?*const fn (*anyopaque, ContentOwner) []const u8 = null,
    result_presented: ?*const fn (*anyopaque, notifications.Kind, ContentOwner) bool = null,
    transfer_presented: ?*const fn (*anyopaque, u64) bool = null,
};
pub const ReconnectResult = enum { disconnected, recovered, failed };
pub const Details = struct { object: []const u8 = "", detail: []const u8 = "", incident_id: ?u64 = null };
pub const AiCompletion = struct {
    details: Details = .{},
    result: enum { succeeded, failed, cancelled, unverified },
    resources_released: bool = false,
    final_answer: bool = false,
};
pub const TransferCompletion = struct {
    details: Details = .{},
    result: enum { succeeded, failed, cancelled },
    resources_released: bool,
    notify_complete: bool,
};
const Registration = struct { id: WindowId, value: Window, focused: bool = true };
pub const ActionHandler = struct { context: *anyopaque, invoke: *const fn (*anyopaque, notifications.NotificationEvent) anyerror!void };
const RegisteredAction = struct { id: u64, owner: ContentOwner, kind: notifications.ActionKind, handler: ActionHandler };
const PermissionOrigin = struct { request_id: u64, window: WindowId };
const AiOrigin = struct { operation_id: u64, window: WindowId, conversation: ?ConversationId = null };
pub const Poll = struct { consumed: usize = 0, settings_changed: bool = false };

pub const Host = struct {
    allocator: std.mem.Allocator,
    driver: platform.Driver,
    coordinator: notifications.Coordinator,
    windows: std.ArrayList(Registration) = .empty,
    permissions: std.ArrayList(PermissionOrigin) = .empty,
    ai_origins: std.ArrayList(AiOrigin) = .empty,
    next_window: u64 = 1,
    actions: std.ArrayList(RegisteredAction) = .empty,
    bound_owners: std.ArrayList(notifications.NotificationOwner) = .empty,
    next_action: u64 = 1,
    next_event: u64 = 1,
    next_ai_operation: u64 = 1,
    next_feedback: u64 = 1,
    last_failure: ?platform.Failure = null,
    authorization_feedback: ?[]const u8 = null,

    pub fn create(allocator: std.mem.Allocator, saved: config.Notify) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .driver = try platform.Driver.init(allocator), .coordinator = undefined };
        errdefer self.driver.deinit();
        self.coordinator = try notifications.Coordinator.init(allocator, saved, self.driver.sink());
        return self;
    }
    pub fn createWithApi(allocator: std.mem.Allocator, saved: config.Notify, api: platform.Api) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .driver = try platform.Driver.initWithApi(allocator, api), .coordinator = undefined };
        errdefer self.driver.deinit();
        self.coordinator = try notifications.Coordinator.init(allocator, saved, self.driver.sink());
        return self;
    }
    pub fn destroy(self: *Host) void {
        self.driver.deinit();
        self.coordinator.deinit();
        self.windows.deinit(self.allocator);
        self.permissions.deinit(self.allocator);
        self.ai_origins.deinit(self.allocator);
        self.actions.deinit(self.allocator);
        self.bound_owners.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn registerWindow(self: *Host, value: Window) !WindowId {
        if (self.next_window == 0) return error.NotificationWindowIdentityExhausted;
        const id: WindowId = @fromBackingInt(self.next_window);
        try self.windows.append(self.allocator, .{ .id = id, .value = value });
        self.next_window = if (self.next_window == std.math.maxInt(u64)) 0 else self.next_window + 1;
        return id;
    }
    pub fn removeWindow(self: *Host, id: WindowId) void {
        for (self.windows.items, 0..) |item, index| if (item.id == id) {
            // Result facts survive their UI, but callbacks borrowed from that
            // window may not remain dispatchable after its Cx is destroyed.
            for (self.coordinator.notification_records.items) |record| if (record.event.owner.window_id == @backingInt(id)) self.ownerEnded(record.event.owner.content);
            var owner_index: usize = 0;
            while (owner_index < self.bound_owners.items.len) {
                if (self.bound_owners.items[owner_index].window_id == @backingInt(id)) {
                    self.ownerEnded(self.bound_owners.items[owner_index].content);
                } else owner_index += 1;
            }
            _ = self.windows.orderedRemove(index);
            return;
        };
    }
    /// Only successful application configuration publication calls this.
    /// A discarded/invalid draft and an old window redraw never update policy.
    pub fn updatePolicy(self: *Host, saved: config.Notify) !void {
        _ = try self.coordinator.updatePolicy(saved);
    }
    pub fn requestAuthorization(self: *Host, origin: WindowId) !void {
        _ = self.windowFor(origin) orelse return error.NotificationWindowClosed;
        try self.permissions.ensureUnusedCapacity(self.allocator, 1);
        const id = self.driver.requestAuthorization(.enable_system_notifications) catch |err| {
            self.authorization_feedback = if (err == error.AuthorizationRequestPending) "正在等待系统通知授权结果…" else "系统通知授权请求失败";
            return err;
        };
        self.authorization_feedback = "正在等待系统通知授权结果…";
        self.permissions.appendAssumeCapacity(.{ .request_id = id, .window = origin });
        if (@import("../platform/runtime_mode.zig").automation) std.debug.print("NOTIFICATION_PERMISSION_REQUESTED {{\"request_id\":{d},\"window\":{d}}}\n", .{ id, @backingInt(origin) });
    }
    pub fn reserveAiOperation(self: *Host, origin: WindowId) !u64 {
        return self.reserveAi(origin, null);
    }
    pub fn reserveAiConversation(self: *Host, origin: WindowId, conversation: ConversationId) !u64 {
        if (!conversation.valid()) return error.InvalidConversationIdentity;
        return self.reserveAi(origin, conversation);
    }
    fn reserveAi(self: *Host, origin: WindowId, conversation: ?ConversationId) !u64 {
        _ = self.windowFor(origin) orelse return error.NotificationWindowClosed;
        if (self.next_ai_operation == 0) return error.NotificationOperationIdentityExhausted;
        const id = self.next_ai_operation;
        try self.ai_origins.append(self.allocator, .{ .operation_id = id, .window = origin, .conversation = conversation });
        self.next_ai_operation = if (id == std.math.maxInt(u64)) 0 else id + 1;
        return id;
    }
    fn activateAi(self: *Host, target: notifications.Target) bool {
        for (self.ai_origins.items) |origin| if (origin.operation_id == target.operation_id) {
            const window = self.windowFor(origin.window) orelse return false;
            if (origin.conversation) |conversation| {
                const activate = window.activate_ai orelse return false;
                return activate(window.context, conversation);
            }
            // Compatibility for existing non-conversation API consumers.
            return window.activate(window.context, target);
        };
        return false;
    }
    pub fn refreshAuthorization(self: *Host) !void {
        _ = self.driver.refreshAuthorization() catch |err| switch (err) {
            error.AuthorizationQueryPending, error.AuthorizationRequestPending => return,
            else => return err,
        };
    }
    pub fn authorizationHelp(self: *const Host) []const u8 {
        if (!self.driver.capabilities.system_notifications) return switch (self.driver.capabilities.unavailable_reason) {
            .no_app_bundle => "系统通知不可用，请从 ZeroWork.app 启动。",
            .delegate_in_use => "系统通知暂不可用。",
            else => "当前无法使用系统通知。",
        };
        const value = self.driver.settings orelse return "正在查询系统通知授权…";
        return switch (value.authorization) {
            .unavailable => "当前无法查询系统通知授权。",
            .not_determined => "系统通知尚未授权。开启事件提醒时会请求授权。",
            .denied, .restricted => "系统通知已被拒绝，请在 macOS 系统设置中允许 ZeroWork 通知。",
            .authorized => if (value.alert == .disabled and value.notification_center == .disabled) "系统通知已授权，横幅和通知中心当前均关闭。" else "系统通知已获授权。",
            .provisional => "系统通知已获临时授权，将以安静方式呈现。",
        };
    }
    pub fn publishAi(self: *Host, owner: ContentOwner, operation_id: u64, turn_id: u64, completion: AiCompletion) !void {
        if (completion.result == .cancelled) return;
        try self.publishLegacy(.{
            .event_id = 0,
            .kind = .ai_ready,
            .owner = owner,
            .operation_id = operation_id,
            .attempt_or_turn_id = turn_id,
            .result = switch (completion.result) {
                .succeeded => .succeeded,
                .failed => .failed,
                .cancelled => .cancelled,
                .unverified => .unverified,
            },
            .summary = switch (completion.result) {
                .succeeded => "AI 助手本轮已结束",
                .failed => "AI 请求失败",
                .cancelled => "AI 请求已停止",
                .unverified => "AI 执行结果待核查",
            },
            .terminal_confirmed = true,
            .resources_released = completion.resources_released,
            .final_answer = completion.final_answer,
        }, .{ .object = completion.details.object, .detail = if (completion.details.detail.len != 0) completion.details.detail else switch (completion.result) {
            .succeeded => "本轮执行已结束，可在助手对话中查看结果。",
            .failed => "请求未完成，请查看助手对话中的错误详情。",
            .cancelled => "本次请求已停止。",
            .unverified => "执行结果尚未确认，请查看结果后核查。",
        } });
    }
    pub fn publishTransfer(self: *Host, owner: ContentOwner, job: u64, attempt: u64, completion: TransferCompletion) !void {
        if (completion.result == .cancelled) return;
        try self.publishLegacy(.{
            .event_id = 0,
            .kind = .transfer_done,
            .owner = owner,
            .operation_id = job,
            .attempt_or_turn_id = attempt,
            .result = switch (completion.result) {
                .succeeded => .succeeded,
                .failed => .failed,
                .cancelled => .cancelled,
            },
            .summary = switch (completion.result) {
                .succeeded => "文件传输已完成",
                .failed => "文件传输失败",
                .cancelled => "文件传输已取消",
            },
            .terminal_confirmed = true,
            .resources_released = completion.resources_released,
            .system_enabled = completion.notify_complete,
        }, .{ .object = completion.details.object, .detail = if (completion.details.detail.len != 0) completion.details.detail else switch (completion.result) {
            .succeeded => "传输任务已完成，可查看任务详情。",
            .failed => "传输未完成，请查看任务中的失败原因。",
            .cancelled => "传输已取消，可在任务中查看已传输内容。",
        } });
    }
    pub fn publishReconnect(self: *Host, owner: ContentOwner, operation_id: u64, attempt: u64, result: ReconnectResult) !void {
        return self.publishReconnectDetails(owner, operation_id, attempt, result, .{});
    }
    pub fn publishReconnectDetails(self: *Host, owner: ContentOwner, operation_id: u64, attempt: u64, result: ReconnectResult, details: Details) !void {
        try self.publishLegacy(.{
            .event_id = 0,
            .kind = .reconnect,
            .owner = owner,
            .operation_id = operation_id,
            .attempt_or_turn_id = attempt,
            .result = switch (result) {
                .disconnected => .disconnected,
                .recovered => .recovered,
                .failed => .failed,
            },
            .summary = switch (result) {
                .disconnected => "SSH 连接已断开",
                .recovered => "SSH 连接已恢复",
                .failed => "SSH 重连未成功",
            },
            .terminal_confirmed = true,
        }, .{ .object = details.object, .incident_id = details.incident_id, .detail = if (details.detail.len != 0) details.detail else switch (result) {
            .disconnected => "连接已中断，请查看连接状态。",
            .recovered => "SSH 连接已重新建立。",
            .failed => "未能重新建立连接，请查看连接日志。",
        } });
    }
    fn publishLegacy(self: *Host, value: notifications.Event, details: Details) !void {
        for (self.coordinator.records.items) |record| if (record.event.kind == value.kind and record.event.owner.eql(value.owner) and
            record.event.operation_id == value.operation_id and record.event.attempt_or_turn_id == value.attempt_or_turn_id and record.event.result == value.result) return;
        if (self.next_event == 0) return error.NotificationEventIdentityExhausted;
        var event = value;
        event.event_id = self.next_event;
        var already_presented = false;
        {
            const target: notifications.Target = .{ .owner = event.owner, .kind = event.kind, .operation_id = event.operation_id, .attempt_or_turn_id = event.attempt_or_turn_id };
            for (self.windows.items) |window| {
                if (!window.value.owns(window.value.context, target)) continue;
                if (window.value.result_presented) |is_presented| already_presented = is_presented(window.value.context, event.kind, event.owner);
                if (event.kind == .transfer_done) if (window.value.transfer_presented) |is_presented| {
                    already_presented = already_presented or is_presented(window.value.context, event.operation_id);
                };
                break;
            }
        }
        var app_focused = false;
        for (self.windows.items) |window| app_focused = app_focused or window.focused;
        event.system_enabled = event.system_enabled and !already_presented and !app_focused and
            (event.result == .succeeded or (event.kind == .reconnect and event.result == .failed));
        event.requires_attention = event.kind == .reconnect and event.result == .failed;
        if (event.kind == .reconnect) event.system_enabled = event.system_enabled and self.coordinator.policy.reconnect;
        // Legacy OS delivery must use the same confirmed incident grouping as
        // the in-app list; otherwise each shared shell submits its own alert.
        if (details.incident_id) |incident| for (self.coordinator.notification_records.items) |record| {
            if (record.listed and record.event.attention.incident_id == incident) {
                event.system_enabled = false;
                break;
            }
        };
        const clock = try localClock();
        const published = try self.coordinator.publish(event, clock);
        const target = self.coordinator.records.items[published.record_index].target();
        if (!published.duplicate) for (self.windows.items) |window| {
            if (!window.value.owns(window.value.context, target)) continue;
            const definition_id: []const u8 = switch (event.kind) {
                .transfer_done => "host.transfer_done",
                .reconnect => "host.reconnect",
                .ai_ready => "host.ai_ready",
            };
            var previous: ?*const notifications.NotificationRecord = null;
            if (event.kind == .reconnect) {
                for (self.coordinator.notification_records.items) |*record| {
                    if (std.mem.eql(u8, record.event.definition_id, definition_id) and sameSessionIdentity(record.event.owner.content, event.owner) and (event.result == .recovered or record.event.owner.content.eql(event.owner))) previous = record;
                }
            } else previous = self.coordinator.factFor(.{ .definition_id = definition_id, .owner = .{ .window_id = @backingInt(window.id), .content = event.owner }, .operation_id = event.operation_id, .attempt_id = event.attempt_or_turn_id, .event_revision = 1, .phase = .accepted, .title = event.summary });
            const actions = [_]notifications.NotificationAction{.{ .kind = .locate_owner, .label = switch (event.kind) {
                .transfer_done => "查看传输",
                .reconnect => "查看连接",
                .ai_ready => "查看对话",
            } }};
            const presentation = try self.coordinator.publishNotification(.{
                .definition_id = definition_id,
                .owner = if (previous) |record| record.event.owner else .{ .window_id = @backingInt(window.id), .content = event.owner },
                .operation_id = if (previous) |record| record.event.operation_id else event.operation_id,
                .attempt_id = if (previous) |record| record.event.attempt_id else event.attempt_or_turn_id,
                .event_revision = if (previous) |record| record.event.event_revision + 1 else 1,
                .phase = switch (event.result) {
                    .succeeded, .recovered => .succeeded,
                    .failed => .failed,
                    .cancelled => .cancelled,
                    .unverified => .outcome_unknown,
                    .disconnected => .accepted,
                    else => .verifying,
                },
                .severity = switch (event.result) {
                    .failed => .failure,
                    .unverified, .disconnected => .warning,
                    .succeeded, .recovered => .success,
                    else => .info,
                },
                .title = event.summary,
                .detail = bounded(details.detail, 4096),
                .object_name = bounded(details.object, 1024),
                .owner_name = if (window.value.owner_name) |resolve| bounded(resolve(window.value.context, event.owner), 256) else "",
                .actions = &actions,
                .system_enabled = event.system_enabled,
                .attention = .{
                    .kind = if (event.kind == .reconnect and event.result == .failed) .connection_stopped else if (event.result == .succeeded) .completion else .local,
                    .requires_action = event.kind == .reconnect and event.result == .failed,
                    .time_sensitive = event.kind == .reconnect and event.result == .failed,
                    .resolved = event.result == .recovered,
                    .source_visible = already_presented,
                    .app_focused = app_focused,
                    .incident_id = details.incident_id orelse if (previous) |record| record.event.attention.incident_id else null,
                },
            }, clock);
            if (already_presented) self.coordinator.dismissNotification(presentation.fact_id);
            break;
        };
        if (@import("../platform/runtime_mode.zig").automation) {
            const encoded_target = try platform.encodeTarget(self.coordinator.records.items[published.record_index].target());
            std.debug.print("NOTIFICATION_FACT {{\"event_id\":{d},\"kind\":\"{s}\",\"result\":\"{s}\",\"owner_kind\":{d},\"owner_id\":{d},\"owner_revision\":{d},\"operation_id\":{d},\"attempt_or_turn\":{d},\"system\":\"{s}\"}}\n", .{ event.event_id, @tagName(event.kind), @tagName(event.result), encoded_target.owner_kind, encoded_target.owner_id, encoded_target.owner_revision, encoded_target.operation_id, encoded_target.attempt_or_turn_id, @tagName(self.coordinator.records.items[published.record_index].system.disposition) });
        }
        self.next_event = if (self.next_event == std.math.maxInt(u64)) 0 else self.next_event + 1;
    }
    pub fn registerDefinition(self: *Host, definition: notifications.NotificationDefinition) !void {
        try self.coordinator.registerDefinition(definition);
    }
    pub fn publishRecordingStatus(self: *Host, window: WindowId, owner: @import("identity.zig").SessionHandle, failure: ?[]const u8) !void {
        var event: notifications.NotificationEvent = .{
            .definition_id = "host.recording_risk",
            .owner = .{ .window_id = @backingInt(window), .content = .{ .session = owner } },
            .operation_id = @backingInt(owner.session_id),
            .event_revision = 1,
            .phase = .failed,
            .severity = .failure,
            .title = "无法继续保存会话记录",
            .detail = failure orelse "会话记录保存已恢复。",
            .attention = .{ .kind = .application_risk, .requires_action = true, .time_sensitive = true },
            .actions = &.{.{ .kind = .locate_owner, .label = "查看来源" }},
        };
        if (self.coordinator.factFor(event)) |old| {
            if (old.event.attention.resolved == (failure == null)) return;
            event.event_revision = old.event.event_revision + 1;
            if (failure == null) {
                event.phase = .succeeded;
                event.attention.resolved = true;
                event.title = "会话记录保存已恢复";
            }
        } else if (failure == null) return;
        _ = try self.publish(event);
    }
    /// Public plugin facade validates current window/owner on first publication.
    /// An existing fact may finish after close without reviving that owner.
    pub fn publish(self: *Host, event: notifications.NotificationEvent) !notifications.NotificationPublication {
        const window = self.windowFor(@fromBackingInt(event.owner.window_id));
        const previous = self.coordinator.factFor(event);
        if (previous == null) {
            const current = window orelse return error.NotificationWindowClosed;
            const target: notifications.Target = .{ .owner = event.owner.content, .kind = .reconnect, .operation_id = event.operation_id, .attempt_or_turn_id = event.attempt_id };
            var bound = false;
            for (self.bound_owners.items) |owner| if (owner.eql(event.owner)) {
                bound = true;
                break;
            };
            if (!bound and !current.owns(current.context, target)) return error.StaleNotificationOwner;
        }
        for (event.actions) |action| if (action.kind != .locate_owner) {
            var registered = false;
            for (self.actions.items) |item| if (item.id == action.action_id and item.owner.eql(event.owner.content) and item.kind == action.kind) {
                registered = true;
                break;
            };
            if (!registered) return error.UnregisteredNotificationAction;
        };
        var gated = event;
        gated.attention.app_focused = false;
        for (self.windows.items) |registration| gated.attention.app_focused = gated.attention.app_focused or registration.focused;
        // The host owns source identity; plugins may publish just the event.
        if (gated.owner_name.len == 0) {
            if (previous) |record| gated.owner_name = record.event.owner_name;
            if (gated.owner_name.len == 0) if (window) |current| if (current.owner_name) |resolve| {
                gated.owner_name = bounded(resolve(current.context, event.owner.content), 256);
            };
        }
        for (self.windows.items) |registration| if (@backingInt(registration.id) == event.owner.window_id) {
            gated.system_enabled = event.system_enabled and !gated.attention.app_focused;
            if (registration.value.result_presented) |presented| gated.attention.source_visible = presented(registration.value.context, switch (event.attention.kind) {
                .task_blocked, .outcome_unknown => .ai_ready,
                .transfer_batch_stopped => .transfer_done,
                else => .reconnect,
            }, event.owner.content);
            break;
        };
        return self.coordinator.publishNotification(gated, try localClock());
    }
    /// Ordinary feedback stays at its source, including warnings/failures.
    /// Only typed impact facts may request global presentation.
    pub fn publishFeedback(self: *Host, window_id: WindowId, owner: ContentOwner, summary: []const u8) !void {
        return self.publishFeedbackSeverity(window_id, owner, summary, .info);
    }
    /// Compatibility entry for local receipts; severity is not global authority.
    pub fn publishFeedbackSeverity(self: *Host, window_id: WindowId, owner: ContentOwner, summary: []const u8, severity: notifications.Severity) !void {
        // The originating field, transcript or task owns ordinary receipts.
        // Global delivery requires structured impact, never an error level.
        _ = self;
        _ = window_id;
        _ = owner;
        _ = summary;
        _ = severity;
    }
    pub fn setWindowFocus(self: *Host, window_id: WindowId, focused: bool) void {
        for (self.windows.items) |*window| if (window.id == window_id) {
            window.focused = focused;
            return;
        };
    }
    pub fn registerAction(self: *Host, owner: ContentOwner, kind: notifications.ActionKind, handler: ActionHandler) !u64 {
        if (self.actions.items.len >= 128) return error.NotificationActionLimit;
        if (self.next_action == std.math.maxInt(u64)) return error.NotificationActionIdentityExhausted;
        const id = self.next_action;
        try self.actions.append(self.allocator, .{ .id = id, .owner = owner, .kind = kind, .handler = handler });
        self.next_action += 1;
        return id;
    }
    pub fn dispatchAction(self: *Host, fact_id: u64, action_index: usize) !void {
        const record = self.coordinator.recordFor(fact_id) orelse return error.UnknownNotificationEvent;
        if (action_index >= record.event.actions.len) return error.UnknownNotificationAction;
        const action = record.event.actions[action_index];
        if (action.kind == .locate_owner) {
            if (std.mem.startsWith(u8, record.event.definition_id, "host.ai_")) {
                if (!record.owner_ended and self.activateAi(.{ .owner = record.event.owner.content, .kind = .ai_ready, .operation_id = record.event.operation_id, .attempt_or_turn_id = record.event.attempt_id })) return;
                self.feedbackFor(null, "该提醒所属对话已不可用");
                return error.NotificationOwnerEnded;
            }
            if (!record.owner_ended) for (self.windows.items) |window| {
                if (window.value.activate(window.value.context, .{ .owner = record.event.owner.content, .kind = if (std.mem.eql(u8, record.event.definition_id, "host.transfer_done")) .transfer_done else if (std.mem.startsWith(u8, record.event.definition_id, "host.ai_")) .ai_ready else .reconnect, .operation_id = record.event.operation_id, .attempt_or_turn_id = record.event.attempt_id })) return;
            };
            self.feedbackFor(null, "该通知所属内容已不可用");
            return error.NotificationOwnerEnded;
        }
        if (record.owner_ended) return error.NotificationOwnerEnded;
        for (self.actions.items) |registered| if (registered.id == action.action_id and registered.owner.eql(record.event.owner.content) and registered.kind == action.kind) {
            try registered.handler.invoke(registered.handler.context, record.event);
            return;
        };
        return error.UnregisteredNotificationAction;
    }
    pub fn update(self: *Host, event: notifications.NotificationEvent) !notifications.NotificationPublication {
        return self.publish(event);
    }
    pub fn bindOwner(self: *Host, owner: notifications.NotificationOwner) !void {
        _ = self.windowFor(@fromBackingInt(owner.window_id)) orelse return error.NotificationWindowClosed;
        for (self.bound_owners.items) |prior| if (prior.content.eql(owner.content)) {
            if (!prior.eql(owner)) return error.NotificationOwnerWindowConflict;
            return;
        };
        if (self.bound_owners.items.len >= 256) return error.NotificationOwnerLimit;
        try self.bound_owners.append(self.allocator, owner);
    }
    pub fn ownerEnded(self: *Host, owner: ContentOwner) void {
        self.coordinator.ownerEnded(owner);
        self.revokeActions(owner);
        var i: usize = 0;
        while (i < self.bound_owners.items.len) {
            if (self.bound_owners.items[i].content.eql(owner)) {
                _ = self.bound_owners.orderedRemove(i);
            } else i += 1;
        }
    }
    pub fn revokeActions(self: *Host, owner: ContentOwner) void {
        var index: usize = 0;
        while (index < self.actions.items.len) {
            if (self.actions.items[index].owner.eql(owner)) _ = self.actions.orderedRemove(index) else index += 1;
        }
    }
    pub fn moveOwner(self: *Host, owner: ContentOwner, window_id: WindowId) void {
        self.coordinator.moveOwner(owner, @backingInt(window_id));
        for (self.bound_owners.items) |*bound| if (bound.content.eql(owner)) {
            bound.window_id = @backingInt(window_id);
        };
    }
    pub fn facade(self: *Host, owner: notifications.NotificationOwner) Facade {
        return .{ .host = self, .owner = owner };
    }
    pub fn poll(self: *Host) !Poll {
        var result: Poll = .{};
        while (result.consumed < 64) {
            const completion = (try self.driver.poll()) orelse break;
            result.consumed += 1;
            switch (completion) {
                .settings => |value| {
                    if (@import("../platform/runtime_mode.zig").automation) {
                        const encoded = std.json.Stringify.valueAlloc(self.allocator, .{
                            .request_id = value.request_id,
                            .explicit = value.explicit_request,
                            .current = value.current_settings,
                            .authorization = @tagName(value.value.authorization),
                            .failed = value.failure != null,
                            .error_code = if (value.failure) |failure| failure.code else @as(i64, 0),
                            .error_domain = if (value.failure != null) value.failure.?.domainText() else "",
                            .error_detail = if (value.failure != null) value.failure.?.detailText() else "",
                        }, .{}) catch null;
                        if (encoded) |bytes| {
                            defer self.allocator.free(bytes);
                            std.debug.print("NOTIFICATION_AUTHORIZATION {s}\n", .{bytes});
                        }
                    }
                    result.settings_changed = result.settings_changed or value.current_settings;
                    if (value.failure) |failure| self.last_failure = failure;
                    if (value.explicit_request) self.authorization_feedback = if (value.failure != null) "系统通知授权请求失败" else self.authorizationHelp();
                    if (value.explicit_request) for (self.permissions.items, 0..) |origin, index| {
                        if (origin.request_id != value.request_id) continue;
                        if (self.windowFor(origin.window)) |window| window.feedback(window.context, if (value.failure != null) "系统通知授权请求失败" else self.authorizationHelp());
                        _ = self.permissions.orderedRemove(index);
                        break;
                    };
                },
                .system => |value| {
                    if (@import("../platform/runtime_mode.zig").automation) std.debug.print("NOTIFICATION_SYSTEM_RESULT {{\"event_id\":{d},\"request_id\":{d},\"result\":\"{s}\",\"error_code\":{d}}}\n", .{ value.event_id, value.request_id, @tagName(value.result), if (value.failure) |failure| failure.code else @as(i64, 0) });
                    result.settings_changed = result.settings_changed or value.current_settings;
                    if (value.failure) |failure| self.last_failure = failure;
                    _ = try self.coordinator.reportSystemResult(value.event_id, value.target, switch (value.result) {
                        .scheduled => .scheduled,
                        .failed => .{ .failed = error.SystemNotificationSendFailed },
                    });
                    if (value.result == .failed) self.feedbackFor(value.target, "系统通知未能发送，任务结果已保留");
                },
                .activation => |value| {
                    if (@import("../platform/runtime_mode.zig").automation) std.debug.print("NOTIFICATION_ACTIVATION {{\"event_id\":{d},\"current_instance\":{},\"operation_id\":{d}}}\n", .{ value.event_id, value.current_instance, value.target.operation_id });
                    var activated = false;
                    if (value.current_instance) {
                        const original = self.coordinator.targetFor(value.event_id);
                        if (original != null and std.meta.eql(original.?, value.target)) {
                            if (value.target.kind == .ai_ready) {
                                activated = self.activateAi(value.target);
                            } else {
                                for (self.windows.items) |window| {
                                    if (window.value.activate(window.value.context, value.target)) {
                                        activated = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if (!activated) self.feedbackFor(null, "该通知所属内容已不可用");
                },
                .queue_failure => self.feedbackFor(null, "部分系统通知回执读取失败"),
            }
            if (self.driver.settings) |value| self.coordinator.reportAuthorization(value.authorization);
        }
        return result;
    }
    fn windowFor(self: *const Host, id: WindowId) ?Window {
        for (self.windows.items) |window| if (window.id == id) return window.value;
        return null;
    }
    fn feedbackFor(self: *Host, target: ?notifications.Target, message: []const u8) void {
        for (self.windows.items) |window| {
            if (target) |value| if (!window.value.owns(window.value.context, value)) continue;
            window.value.feedback(window.value.context, message);
            return;
        }
    }
};

const LocalTime = extern struct {
    seconds: c_int,
    minutes: c_int,
    hours: c_int,
    day: c_int,
    month: c_int,
    year: c_int,
    weekday: c_int,
    year_day: c_int,
    daylight: c_int,
    offset: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(*const c_long, *LocalTime) ?*LocalTime;
pub fn localClock() !notifications.Clock {
    var wall: std.c.timespec = undefined;
    var monotonic: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &wall) != 0 or std.c.clock_gettime(.MONOTONIC, &monotonic) != 0) return error.NotificationClockUnavailable;
    var seconds: c_long = @intCast(wall.sec);
    var local: LocalTime = undefined;
    if (localtime_r(&seconds, &local) == null or local.hours < 0 or local.hours > 23 or local.minutes < 0 or local.minutes > 59 or monotonic.sec < 0) return error.NotificationClockUnavailable;
    return .{ .local_minute = @intCast(local.hours * 60 + local.minutes), .monotonic_ms = @as(u64, @intCast(monotonic.sec)) * std.time.ms_per_s + @as(u64, @intCast(monotonic.nsec)) / std.time.ns_per_ms };
}

/// Owner-frozen notifications entry in the restricted plugin context.
pub const Facade = struct {
    host: *Host,
    owner: notifications.NotificationOwner,
    pub fn publish(self: Facade, value: notifications.NotificationEvent) !notifications.NotificationPublication {
        if (!value.owner.eql(self.owner)) return error.StaleNotificationOwner;
        return self.host.publish(value);
    }
    pub fn update(self: Facade, value: notifications.NotificationEvent) !notifications.NotificationPublication {
        return self.publish(value);
    }
};

fn bounded(text: []const u8, limit: usize) []const u8 {
    var len = @min(text.len, limit);
    while (len > 0 and !std.unicode.utf8ValidateSlice(text[0..len])) len -= 1;
    return text[0..len];
}

fn sameSessionIdentity(a: ContentOwner, b: ContentOwner) bool {
    if (a == .session and b == .session) return a.session.session_id == b.session.session_id;
    return a.eql(b);
}
